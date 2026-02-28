// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Memory Index (Vector Store)
// Semantic search over Sid's memories using local embeddings via Ollama
// Uses SQLite (built into macOS) for persistence + cosine similarity for retrieval
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// A persistent vector store for Sid's memories.
/// Embeds text using `nomic-embed-text` via Ollama, stores in SQLite,
/// retrieves by cosine similarity. Sub-200ms search over thousands of memories.
///
/// Every memory is a small act of faith — that something said today
/// might matter tomorrow. The Library remembers so we don't have to.
actor MemoryIndex {
    static let shared = MemoryIndex()

    private var db: OpaquePointer?
    private let dbPath: String
    private let embeddingModel = "nomic-embed-text"
    private let embeddingDim = 768

    // In-memory cache for fast search (loaded from SQLite on init)
    private var entries: [IndexEntry] = []
    private var isReady = false

    // BM25 index for keyword-based scoring (rebuilt on load and after changes)
    private var bm25 = BM25Index()

    /// Entity index: entity name (lowercased) -> set of memory IDs mentioning that entity
    private var entityIndex: [String: Set<Int64>] = [:]

    /// Track that memories were accessed (for importance decay decisions).
    /// Called periodically after searches to avoid per-query DB writes.
    private var searchesSinceLastAccessUpdate = 0

    /// Pending importance updates from access-based amplification (flushed to DB with access tracking)
    private var pendingImportanceUpdates: [Int64: Float] = [:]

    struct IndexEntry {
        let id: Int64
        let text: String
        let category: String      // "fact", "conversation", "identity", "project", "episode"
        let source: String        // where it came from
        let timestamp: Date
        let embedding: [Float]
        let importance: Float     // 0-1, higher = more important
        let entities: [String]
        var lastAccessedAt: Date
        var accessCount: Int
        var pinned: Bool          // Pinned memories exempt from decay
        var confidence: Float     // 0-1, reliability score
    }

    struct SearchResult {
        let id: Int64
        let text: String
        let category: String
        let source: String
        let timestamp: Date
        let importance: Float
        let score: Float          // cosine similarity
    }

    init() {
        let appSupport = PlatformPaths.appSupportDir
        let dir = appSupport.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("vectors.db").path
    }

    /// Per-user initializer for cloud multi-tenant isolation
    init(dbPath customPath: String) {
        let dir = (customPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = customPath
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open database: \(dbPath)", subsystem: "LoA·Index")
            return
        }

        // WAL mode for concurrent reads
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        // Create table
        exec("""
            CREATE TABLE IF NOT EXISTS memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'fact',
                source TEXT NOT NULL DEFAULT 'conversation',
                timestamp TEXT NOT NULL,
                importance REAL NOT NULL DEFAULT 0.5,
                embedding BLOB NOT NULL,
                text_hash TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_category ON memories(category)")
        exec("CREATE INDEX IF NOT EXISTS idx_hash ON memories(text_hash)")
        exec("CREATE INDEX IF NOT EXISTS idx_importance ON memories(importance DESC)")

        // Schema migration: add new columns if they don't exist
        exec("ALTER TABLE memories ADD COLUMN entities TEXT DEFAULT '[]'")
        exec("ALTER TABLE memories ADD COLUMN last_accessed_at TEXT DEFAULT NULL")
        exec("ALTER TABLE memories ADD COLUMN access_count INTEGER DEFAULT 0")

        // Phase 2 — The River: pinning, versioning, confidence
        exec("ALTER TABLE memories ADD COLUMN pinned INTEGER DEFAULT 0")
        exec("ALTER TABLE memories ADD COLUMN pinned_by TEXT")
        exec("ALTER TABLE memories ADD COLUMN pinned_at TEXT")
        exec("ALTER TABLE memories ADD COLUMN confidence REAL DEFAULT 0.8")

        // Memory version history table (fact versioning)
        exec("""
            CREATE TABLE IF NOT EXISTS memory_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_id INTEGER NOT NULL REFERENCES memories(id),
                previous_text TEXT NOT NULL,
                previous_importance REAL NOT NULL,
                changed_at TEXT NOT NULL,
                change_reason TEXT
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_versions_memory ON memory_versions(memory_id)")

        // Load all entries into memory for fast search
        await loadAllEntries()

        // Build BM25 inverted index for keyword scoring
        rebuildBM25()

        // Build entity index for entity-based lookups
        rebuildEntityIndex()

        isReady = true
        TorboLog.info("Ready — \(entries.count) memories indexed, BM25 \(bm25.termCount) terms", subsystem: "LoA·Index")
    }

    // MARK: - Indexing

    /// Add a memory to the index. Deduplicates by text hash.
    /// Returns the entry ID, or nil if duplicate or embedding failed.
    @discardableResult
    func add(text: String, category: String = "fact", source: String = "conversation",
             importance: Float = 0.5, timestamp: Date = Date()) async -> Int64? {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let hash = textHash(text)

        // Deduplicate
        if isDuplicate(hash: hash) {
            return nil
        }

        // Semantic pre-check: BM25 catches near-duplicates without expensive embedding
        if isLikelyDuplicate(text: text) {
            TorboLog.debug("Skipped likely duplicate (BM25): \(text.prefix(60))...", subsystem: "LoA·Index")
            return nil
        }

        // Get embedding from Ollama
        guard let embedding = await embed(text) else {
            TorboLog.error("Embedding failed for: \(text.prefix(60))...", subsystem: "LoA·Index")
            return nil
        }

        // Store in SQLite
        let id = insertEntry(text: text, category: category, source: source,
                            timestamp: timestamp, importance: importance,
                            embedding: embedding, hash: hash)

        // Add to in-memory cache + BM25 index
        if let id {
            entries.append(IndexEntry(
                id: id, text: text, category: category, source: source,
                timestamp: timestamp, embedding: embedding, importance: importance,
                entities: [], lastAccessedAt: Date(), accessCount: 0,
                pinned: false, confidence: 0.8
            ))
            bm25.addEntry(id: id, text: text)

            // Publish to event bus
            let memID = id
            let memCategory = category
            let memSource = source
            let preview = String(text.prefix(80))
            Task {
                await EventBus.shared.publish("system.memory.written",
                    payload: ["memory_id": "\(memID)", "category": memCategory, "source": memSource, "text_preview": preview],
                    source: "LoA")
            }
        }

        return id
    }

    /// Add multiple memories in batch (more efficient — batches embedding calls)
    func addBatch(_ items: [(text: String, category: String, source: String, importance: Float)]) async -> Int {
        var added = 0
        for item in items {
            if await add(text: item.text, category: item.category,
                        source: item.source, importance: item.importance) != nil {
                added += 1
            }
        }
        TorboLog.info("Batch added \(added)/\(items.count) memories", subsystem: "LoA·Index")
        return added
    }

    // MARK: - Search

    /// Semantic search — find the most relevant memories for a query.
    /// Returns top-K results sorted by relevance (cosine similarity * importance boost).
    func search(query: String, topK: Int = 10, minScore: Float = 0.3,
                categories: [String]? = nil) async -> [SearchResult] {
        guard isReady, !query.isEmpty else { return [] }

        guard let queryEmbedding = await embed(query) else {
            TorboLog.error("Query embedding failed", subsystem: "LoA·Index")
            return []
        }

        let startTime = Date().timeIntervalSinceReferenceDate

        var results: [(entry: IndexEntry, score: Float)] = []

        for entry in entries {
            // Category filter
            if let cats = categories, !cats.contains(entry.category) { continue }

            let similarity = cosineSimilarity(queryEmbedding, entry.embedding)

            // Score: similarity + importance + confidence + temporal boost + access boost
            let accessBoost = min(Float(entry.accessCount) * 0.005, 0.1)
            let boostedScore = similarity * 0.5 + entry.importance * 0.2 + entry.confidence * 0.2 + accessBoost

            var finalScore = boostedScore
            // Temporal boost: recent memories get a small boost, very old get a slight penalty
            let ageInDays = Date().timeIntervalSince(entry.timestamp) / 86400
            if ageInDays < 1 { finalScore += 0.1 }       // Less than 24 hours
            else if ageInDays < 7 { finalScore += 0.05 }  // Less than a week
            else if ageInDays > 30 { finalScore -= 0.03 }  // Older than a month

            if finalScore >= minScore {
                results.append((entry, finalScore))
            }
        }

        // Sort by score descending, take top K
        results.sort { $0.score > $1.score }
        let topResults = results.prefix(topK)

        let elapsed = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
        TorboLog.info("Search completed in \(String(format: "%.1f", elapsed))ms — \(topResults.count) results", subsystem: "LoA·Index")

        // Track access for returned results
        let resultIDs = topResults.map { $0.entry.id }
        trackAccess(ids: resultIDs)

        return topResults.map { r in
            SearchResult(
                id: r.entry.id, text: r.entry.text, category: r.entry.category,
                source: r.entry.source, timestamp: r.entry.timestamp,
                importance: r.entry.importance, score: r.score
            )
        }
    }

    /// Hybrid BM25 + vector search with Reciprocal Rank Fusion (RRF).
    /// Runs BM25 keyword scoring and semantic vector scoring in parallel,
    /// then blends results using RRF for better recall than either method alone.
    func hybridSearch(query: String, topK: Int = 10) async -> [SearchResult] {
        guard isReady, !query.isEmpty else { return [] }

        let startTime = Date().timeIntervalSinceReferenceDate

        // --- Phase 1: BM25 keyword scoring (instant, no embedding needed) ---
        let bm25Results = bm25.search(query: query, topK: topK * 3)

        // --- Phase 2: Vector semantic scoring ---
        guard let queryEmbedding = await embed(query) else {
            // Fallback: BM25 only (no embedding available)
            return Array(bm25Results.prefix(topK)).compactMap { result -> SearchResult? in
                guard let entry = entries.first(where: { $0.id == result.id }) else { return nil }
                return SearchResult(id: entry.id, text: entry.text, category: entry.category,
                                   source: entry.source, timestamp: entry.timestamp,
                                   importance: entry.importance, score: result.score)
            }
        }

        // Score all entries by vector similarity (we need ranks, not just top-K)
        var vectorScores: [(id: Int64, score: Float)] = []
        for entry in entries {
            let sim = cosineSimilarity(queryEmbedding, entry.embedding)
            let boosted = sim * 0.7 + entry.importance * 0.3
            if boosted > 0.15 { // Low threshold to gather candidates
                vectorScores.append((id: entry.id, score: boosted))
            }
        }
        vectorScores.sort { $0.score > $1.score }
        let vectorResults = Array(vectorScores.prefix(topK * 3))

        // --- Phase 3: Reciprocal Rank Fusion ---
        // RRF score = Σ 1/(k + rank) for each result set
        // k = 60 is standard (controls how much to favor top results)
        let rrfK: Float = 60

        // Build rank maps: entryID → rank (1-based)
        var bm25Ranks: [Int64: Int] = [:]
        for (rank, result) in bm25Results.enumerated() {
            bm25Ranks[result.id] = rank + 1
        }
        var vectorRanks: [Int64: Int] = [:]
        for (rank, result) in vectorResults.enumerated() {
            vectorRanks[result.id] = rank + 1
        }

        // Union of all candidate IDs
        let allCandidates = Set(bm25Ranks.keys).union(Set(vectorRanks.keys))

        // Compute RRF score for each candidate
        var rrfScores: [(id: Int64, score: Float)] = []
        for candidateID in allCandidates {
            var rrfScore: Float = 0
            if let rank = bm25Ranks[candidateID] {
                rrfScore += 1.0 / (rrfK + Float(rank))
            }
            if let rank = vectorRanks[candidateID] {
                rrfScore += 1.0 / (rrfK + Float(rank))
            }
            rrfScores.append((id: candidateID, score: rrfScore))
        }

        // Sort by RRF score descending
        rrfScores.sort { $0.score > $1.score }

        let elapsed = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
        TorboLog.info("Hybrid search (BM25+RRF) in \(String(format: "%.1f", elapsed))ms — \(bm25Results.count) BM25, \(vectorResults.count) vector, \(min(topK, rrfScores.count)) fused", subsystem: "LoA·Index")

        // Track access for returned results
        let resultIDs = rrfScores.prefix(topK).compactMap { score -> Int64? in
            entries.first(where: { $0.id == score.id })?.id
        }
        trackAccess(ids: resultIDs)

        // Map back to SearchResults
        return rrfScores.prefix(topK).compactMap { result in
            guard let entry = entries.first(where: { $0.id == result.id }) else { return nil }
            return SearchResult(id: entry.id, text: entry.text, category: entry.category,
                               source: entry.source, timestamp: entry.timestamp,
                               importance: entry.importance, score: result.score)
        }
    }

    // MARK: - Temporal Search

    /// Search memories within a date range, optionally filtered by category.
    func temporalSearch(from startDate: Date, to endDate: Date, topK: Int = 20,
                        categories: [String]? = nil) -> [SearchResult] {
        var results = entries.filter { entry in
            entry.timestamp >= startDate && entry.timestamp <= endDate &&
            (categories?.contains(entry.category) ?? true)
        }
        // Sort by importance descending
        results.sort { $0.importance > $1.importance }
        return Array(results.prefix(topK)).map { entry in
            SearchResult(id: entry.id, text: entry.text, category: entry.category,
                        source: entry.source, timestamp: entry.timestamp,
                        importance: entry.importance, score: entry.importance)
        }
    }

    /// Detect temporal intent in a query and return a date range if applicable.
    static func detectTemporalRange(in query: String) -> (from: Date, to: Date)? {
        let lower = query.lowercased()
        let calendar = Calendar.current
        let now = Date()

        if lower.contains("yesterday") {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            let start = calendar.startOfDay(for: yesterday)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return (start, end)
        }
        if lower.contains("today") {
            let start = calendar.startOfDay(for: now)
            return (start, now)
        }
        if lower.contains("last week") || lower.contains("past week") {
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return (start, now)
        }
        if lower.contains("last month") || lower.contains("past month") {
            guard let start = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return (start, now)
        }
        if lower.contains("this week") {
            guard let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return nil }
            return (start, now)
        }
        // Day names: "on monday", "on tuesday", etc.
        let dayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in dayNames.enumerated() {
            if lower.contains("on \(name)") || lower.contains("last \(name)") {
                // Find the most recent occurrence of that day
                let today = calendar.component(.weekday, from: now) // 1=Sun, 7=Sat
                var daysBack = today - (index + 1)
                if daysBack <= 0 { daysBack += 7 }
                guard let targetDay = calendar.date(byAdding: .day, value: -daysBack, to: now) else { return nil }
                let start = calendar.startOfDay(for: targetDay)
                guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return (start, end)
            }
        }

        return nil
    }

    // MARK: - Maintenance

    /// Remove a memory by ID
    func remove(id: Int64) {
        guard let db else { return }
        let sql = "DELETE FROM memories WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        entries.removeAll { $0.id == id }
        bm25.removeEntry(id: id)
    }

    /// Update importance score for a memory (used by Repairer to boost frequently-accessed memories)
    func updateImportance(id: Int64, importance: Float) {
        let clamped = max(0, min(1, importance))
        guard let db else { return }
        let sql = "UPDATE memories SET importance = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Double(clamped))
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let old = entries[idx]
            entries[idx] = IndexEntry(id: old.id, text: old.text, category: old.category,
                                     source: old.source, timestamp: old.timestamp,
                                     embedding: old.embedding, importance: clamped,
                                     entities: old.entities, lastAccessedAt: old.lastAccessedAt,
                                     accessCount: old.accessCount,
                                     pinned: old.pinned, confidence: old.confidence)
        }
    }

    /// Soft-deprecate a memory: reduce importance to 0.1 and prefix text with [outdated].
    /// Used by contradiction detection when a newer fact supersedes an older one.
    func softDeprecate(id: Int64) {
        guard let db else { return }
        // Update DB
        let sql = "UPDATE memories SET importance = 0.1, text = '[outdated] ' || text WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        // Update in-memory cache
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let old = entries[idx]
            let newText = old.text.hasPrefix("[outdated]") ? old.text : "[outdated] \(old.text)"
            entries[idx] = IndexEntry(id: old.id, text: newText, category: old.category,
                                     source: old.source, timestamp: old.timestamp,
                                     embedding: old.embedding, importance: 0.1,
                                     entities: old.entities, lastAccessedAt: old.lastAccessedAt,
                                     accessCount: old.accessCount,
                                     pinned: old.pinned, confidence: 0.2)
        }
    }

    /// Get total memory count
    var count: Int { entries.count }

    /// Get counts by category
    func categoryCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.category, default: 0] += 1
        }
        return counts
    }

    /// Purge memories below importance threshold
    func purgeBelow(importance: Float) {
        let toRemove = entries.filter { $0.importance < importance }
        guard let db, !toRemove.isEmpty else { return }
        let sql = "DELETE FROM memories WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for entry in toRemove {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, entry.id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        entries.removeAll { $0.importance < importance }
        TorboLog.info("Purged \(toRemove.count) low-importance memories", subsystem: "LoA·Index")
    }

    // MARK: - Pinning

    /// Pin a memory so it's exempt from decay and always included in context.
    func pin(id: Int64, by: String = "user") {
        guard let db else { return }
        let sql = "UPDATE memories SET pinned = 1, pinned_by = ?, pinned_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(stmt, 1, (by as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)

        // Update in-memory cache
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].pinned = true
        }
        TorboLog.info("Pinned memory #\(id) by \(by)", subsystem: "LoA·Index")
    }

    /// Unpin a memory, making it subject to normal decay again.
    func unpin(id: Int64) {
        guard let db else { return }
        let sql = "UPDATE memories SET pinned = 0, pinned_by = NULL, pinned_at = NULL WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)

        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].pinned = false
        }
        TorboLog.info("Unpinned memory #\(id)", subsystem: "LoA·Index")
    }

    /// All pinned memories, sorted by importance.
    func pinnedMemories() -> [IndexEntry] {
        return entries.filter { $0.pinned }.sorted { $0.importance > $1.importance }
    }

    // MARK: - Versioning

    /// Update a memory's text while preserving the old version in history.
    func updateWithVersion(id: Int64, newText: String, reason: String = "update") {
        guard let db else { return }

        // Find current text and importance
        guard let entry = entries.first(where: { $0.id == id }) else { return }

        // Save old version
        let versionSQL = "INSERT INTO memory_versions (memory_id, previous_text, previous_importance, changed_at, change_reason) VALUES (?, ?, ?, ?, ?)"
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, versionSQL, -1, &vStmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let now = ISO8601DateFormatter().string(from: Date())
            sqlite3_bind_int64(vStmt, 1, id)
            sqlite3_bind_text(vStmt, 2, (entry.text as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(vStmt, 3, Double(entry.importance))
            sqlite3_bind_text(vStmt, 4, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(vStmt, 5, (reason as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(vStmt)
            sqlite3_finalize(vStmt)
        }

        // Update the memory text
        let updateSQL = "UPDATE memories SET text = ?, text_hash = ? WHERE id = ?"
        var uStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &uStmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let hash = textHash(newText)
            sqlite3_bind_text(uStmt, 1, (newText as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(uStmt, 2, (hash as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(uStmt, 3, id)
            sqlite3_step(uStmt)
            sqlite3_finalize(uStmt)
        }

        TorboLog.info("Versioned memory #\(id) — reason: \(reason)", subsystem: "LoA·Index")
    }

    /// Get version history for a memory.
    struct MemoryVersion {
        let id: Int64
        let memoryID: Int64
        let previousText: String
        let previousImportance: Float
        let changedAt: String
        let changeReason: String?
    }

    func versions(for memoryID: Int64) -> [MemoryVersion] {
        guard let db else { return [] }
        let sql = "SELECT id, memory_id, previous_text, previous_importance, changed_at, change_reason FROM memory_versions WHERE memory_id = ? ORDER BY id DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, memoryID)

        var results: [MemoryVersion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let mID = sqlite3_column_int64(stmt, 1)
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let imp = Float(sqlite3_column_double(stmt, 3))
            let changedAt = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let reason = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

            results.append(MemoryVersion(id: id, memoryID: mID, previousText: text,
                                         previousImportance: imp, changedAt: changedAt,
                                         changeReason: reason))
        }
        return results
    }

    // MARK: - Confidence

    /// Update a memory's confidence score.
    func updateConfidence(id: Int64, confidence: Float) {
        guard let db else { return }
        let sql = "UPDATE memories SET confidence = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, Double(confidence))
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)

        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].confidence = confidence
        }
    }

    // MARK: - Embeddings via Ollama

    private func embed(_ text: String) async -> [Float]? {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/embed") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body: [String: Any] = [
            "model": embeddingModel,
            "input": text.prefix(2048) // nomic-embed-text context window
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let embeddings = json["embeddings"] as? [[Double]],
                  let first = embeddings.first else { return nil }

            return first.map { Float($0) }
        } catch {
            TorboLog.error("Embed error: \(error.localizedDescription)", subsystem: "LoA·Index")
            return nil
        }
    }

    // MARK: - Math

    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - SQLite Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { TorboLog.error("SQL error: \(String(cString: err))", subsystem: "LoA·Index"); sqlite3_free(err) }
        }
    }

    private func insertEntry(text: String, category: String, source: String,
                            timestamp: Date, importance: Float,
                            embedding: [Float], hash: String) -> Int64? {
        guard let db else { return nil }

        let sql = "INSERT INTO memories (text, category, source, timestamp, importance, embedding, text_hash) VALUES (?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let ts = ISO8601DateFormatter().string(from: timestamp)
        let embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

        // L-8: Use SQLITE_TRANSIENT so SQLite copies string data (NSString temporaries may release)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (category as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, (ts as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, Double(importance))
        _ = embeddingData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(embeddingData.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(stmt, 7, (hash as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    private func loadAllEntries() async {
        guard let db else { return }

        let sql = "SELECT id, text, category, source, timestamp, importance, embedding, entities, last_accessed_at, access_count, pinned, confidence FROM memories"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var loaded: [IndexEntry] = []
        let fmt = ISO8601DateFormatter()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let text = String(cString: sqlite3_column_text(stmt, 1))
            let category = String(cString: sqlite3_column_text(stmt, 2))
            let source = String(cString: sqlite3_column_text(stmt, 3))
            let tsStr = String(cString: sqlite3_column_text(stmt, 4))
            let importance = Float(sqlite3_column_double(stmt, 5))

            let blobPtr = sqlite3_column_blob(stmt, 6)
            let blobSize = sqlite3_column_bytes(stmt, 6)
            var embedding: [Float] = []
            if let ptr = blobPtr, blobSize > 0 {
                let count = Int(blobSize) / MemoryLayout<Float>.size
                embedding = Array(UnsafeBufferPointer(
                    start: ptr.assumingMemoryBound(to: Float.self), count: count
                ))
            }

            let timestamp = fmt.date(from: tsStr) ?? Date()

            // Parse entities (JSON array stored as text)
            var entities: [String] = []
            if let entitiesPtr = sqlite3_column_text(stmt, 7) {
                let entitiesStr = String(cString: entitiesPtr)
                if let data = entitiesStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    entities = parsed
                }
            }

            // Parse last_accessed_at
            var lastAccessedAt = timestamp
            if let accessPtr = sqlite3_column_text(stmt, 8) {
                let accessStr = String(cString: accessPtr)
                if let date = fmt.date(from: accessStr) {
                    lastAccessedAt = date
                }
            }

            let accessCount = Int(sqlite3_column_int(stmt, 9))
            let pinned = sqlite3_column_int(stmt, 10) != 0
            let confidence = Float(sqlite3_column_double(stmt, 11))

            loaded.append(IndexEntry(
                id: id, text: text, category: category, source: source,
                timestamp: timestamp, embedding: embedding, importance: importance,
                entities: entities, lastAccessedAt: lastAccessedAt, accessCount: accessCount,
                pinned: pinned, confidence: confidence > 0 ? confidence : 0.8
            ))
        }

        // M-23: Cap in-memory cache — keep highest-importance entries when exceeding limit
        let maxCacheEntries = 50_000
        if loaded.count > maxCacheEntries {
            loaded.sort { $0.importance > $1.importance }
            loaded = Array(loaded.prefix(maxCacheEntries))
            TorboLog.warn("Memory cache capped at \(maxCacheEntries) entries (total in DB: \(loaded.count))", subsystem: "LoA·Index")
        }

        entries = loaded
    }

    private func isDuplicate(hash: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT COUNT(*) FROM memories WHERE text_hash = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    /// Quick BM25-based duplicate check — catches near-duplicates without needing an embedding.
    /// Cheaper than a full vector search since BM25 is pure CPU.
    func isLikelyDuplicate(text: String) -> Bool {
        let bm25Results = bm25.search(query: text, topK: 3)
        for result in bm25Results {
            if result.score > 0.85 { return true }
        }
        return false
    }

    private func textHash(_ text: String) -> String {
        // L-9: SHA-256 hash for reliable deduplication (replaces DJB2)
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(normalized.utf8)
        #if canImport(CommonCrypto)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: FNV-1a 64-bit (better distribution than DJB2)
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
        #endif
    }

    // MARK: - BM25 Index Management

    /// Rebuild the BM25 inverted index from all in-memory entries.
    private func rebuildBM25() {
        bm25.build(entries: entries.map { (id: $0.id, text: $0.text) })
    }

    // MARK: - Bulk Access (for Repairer)

    /// All entries in the index (for deduplication and maintenance).
    var allEntries: [IndexEntry] { entries }

    /// Entries filtered by category, sorted by importance (highest first).
    func entriesByCategory(_ category: String) -> [IndexEntry] {
        entries.filter { $0.category == category }
            .sorted { $0.importance > $1.importance }
    }

    /// Bulk remove entries by ID (more efficient than individual removes).
    func removeBatch(ids: [Int64]) {
        guard !ids.isEmpty, let db else { return }
        let idSet = Set(ids)
        let sql = "DELETE FROM memories WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            bm25.removeEntry(id: id)
        }
        sqlite3_finalize(stmt)
        entries.removeAll { idSet.contains($0.id) }
    }

    // MARK: - Entity Index

    /// Rebuild the entity index from in-memory entries.
    private func rebuildEntityIndex() {
        entityIndex.removeAll()
        for entry in entries {
            for entity in entry.entities {
                let key = entity.lowercased()
                entityIndex[key, default: []].insert(entry.id)
            }
        }
        if !entityIndex.isEmpty {
            TorboLog.info("Entity index built — \(entityIndex.count) entities", subsystem: "LoA·Index")
        }
    }

    /// Find all memories mentioning a specific entity.
    func searchByEntity(name: String, topK: Int = 20) -> [SearchResult] {
        let key = name.lowercased()
        guard let ids = entityIndex[key] else { return [] }
        var results = entries.filter { ids.contains($0.id) }
        results.sort { $0.importance > $1.importance }
        return Array(results.prefix(topK)).map { entry in
            SearchResult(id: entry.id, text: entry.text, category: entry.category,
                        source: entry.source, timestamp: entry.timestamp,
                        importance: entry.importance, score: entry.importance)
        }
    }

    /// Get all known entity names (for autocomplete / display).
    var knownEntities: [String] {
        Array(entityIndex.keys.sorted())
    }

    // MARK: - Access Tracking

    func trackAccess(ids: [Int64]) {
        searchesSinceLastAccessUpdate += 1
        let shouldPersist = searchesSinceLastAccessUpdate >= 10

        let now = Date()
        for id in ids {
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].lastAccessedAt = now
                entries[idx].accessCount += 1

                // Importance amplification: frequently-accessed memories rise
                let newCount = entries[idx].accessCount
                if newCount == 5 || newCount == 15 || newCount == 30 || newCount == 50 {
                    let boost: Float = 0.05
                    let current = entries[idx].importance
                    let newImportance = min(0.95, current + boost)
                    if newImportance != current {
                        // importance is 'let', so rebuild the entry
                        let old = entries[idx]
                        entries[idx] = IndexEntry(id: old.id, text: old.text, category: old.category,
                                                 source: old.source, timestamp: old.timestamp,
                                                 embedding: old.embedding, importance: newImportance,
                                                 entities: old.entities, lastAccessedAt: old.lastAccessedAt,
                                                 accessCount: old.accessCount,
                                                 pinned: old.pinned, confidence: old.confidence)
                        pendingImportanceUpdates[id] = newImportance
                        TorboLog.info("Memory #\(id) promoted to importance \(String(format: "%.2f", newImportance)) (accessed \(newCount) times)", subsystem: "LoA·Index")
                    }
                }
            }
        }

        if shouldPersist, let db {
            searchesSinceLastAccessUpdate = 0
            let ts = ISO8601DateFormatter().string(from: now)
            let sql = "UPDATE memories SET last_accessed_at = ?, access_count = access_count + 1 WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, (ts as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // Flush pending importance updates
            if !pendingImportanceUpdates.isEmpty {
                let impSql = "UPDATE memories SET importance = ? WHERE id = ?"
                var impStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, impSql, -1, &impStmt, nil) == SQLITE_OK {
                    for (id, importance) in pendingImportanceUpdates {
                        sqlite3_reset(impStmt)
                        sqlite3_bind_double(impStmt, 1, Double(importance))
                        sqlite3_bind_int64(impStmt, 2, id)
                        sqlite3_step(impStmt)
                    }
                    sqlite3_finalize(impStmt)
                }
                pendingImportanceUpdates.removeAll()
            }
        }
    }

    // MARK: - Entity-Aware Indexing

    /// Add a memory with entity tags.
    @discardableResult
    func addWithEntities(text: String, category: String = "fact", source: String = "conversation",
                         importance: Float = 0.5, entities: [String] = [], timestamp: Date = Date()) async -> Int64? {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let hash = textHash(text)
        if isDuplicate(hash: hash) { return nil }

        // Semantic pre-check via BM25
        if isLikelyDuplicate(text: text) {
            TorboLog.debug("Skipped likely duplicate (BM25): \(text.prefix(60))...", subsystem: "LoA·Index")
            return nil
        }

        guard let embedding = await embed(text) else {
            TorboLog.error("Embedding failed for: \(text.prefix(60))...", subsystem: "LoA·Index")
            return nil
        }

        // Store in SQLite with entities
        let id = insertEntryWithEntities(text: text, category: category, source: source,
                                          timestamp: timestamp, importance: importance,
                                          embedding: embedding, hash: hash, entities: entities)

        if let id {
            entries.append(IndexEntry(
                id: id, text: text, category: category, source: source,
                timestamp: timestamp, embedding: embedding, importance: importance,
                entities: entities, lastAccessedAt: Date(), accessCount: 0,
                pinned: false, confidence: 0.8
            ))
            bm25.addEntry(id: id, text: text)
            // Update entity index
            for entity in entities {
                entityIndex[entity.lowercased(), default: []].insert(id)
            }
        }

        return id
    }

    private func insertEntryWithEntities(text: String, category: String, source: String,
                                          timestamp: Date, importance: Float,
                                          embedding: [Float], hash: String, entities: [String]) -> Int64? {
        guard let db else { return nil }

        let sql = "INSERT INTO memories (text, category, source, timestamp, importance, embedding, text_hash, entities) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let ts = ISO8601DateFormatter().string(from: timestamp)
        let embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let entitiesJSON = (try? JSONSerialization.data(withJSONObject: entities)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (ts as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Double(importance))
        _ = embeddingData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(embeddingData.count), nil)
        }
        sqlite3_bind_text(stmt, 7, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (entitiesJSON as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
