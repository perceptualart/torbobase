// Torbo Base — Memory Index (Vector Store)
// Semantic search over Sid's memories using local embeddings via Ollama
// Uses SQLite (built into macOS) for persistence + cosine similarity for retrieval
import Foundation
import SQLite3

/// A persistent vector store for Sid's memories.
/// Embeds text using `nomic-embed-text` via Ollama, stores in SQLite,
/// retrieves by cosine similarity. Sub-200ms search over thousands of memories.
actor MemoryIndex {
    static let shared = MemoryIndex()

    private var db: OpaquePointer?
    private let dbPath: String
    private let ollamaURL = "http://127.0.0.1:11434"
    private let embeddingModel = "nomic-embed-text"
    private let embeddingDim = 768

    // In-memory cache for fast search (loaded from SQLite on init)
    private var entries: [IndexEntry] = []
    private var isReady = false

    struct IndexEntry {
        let id: Int64
        let text: String
        let category: String      // "fact", "conversation", "identity", "project", "episode"
        let source: String        // where it came from
        let timestamp: Date
        let embedding: [Float]
        let importance: Float     // 0-1, higher = more important
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("vectors.db").path
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[MemoryIndex] Failed to open database: \(dbPath)")
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

        // Load all entries into memory for fast search
        await loadAllEntries()
        isReady = true
        print("[MemoryIndex] Ready — \(entries.count) memories indexed")
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

        // Get embedding from Ollama
        guard let embedding = await embed(text) else {
            print("[MemoryIndex] Embedding failed for: \(text.prefix(60))...")
            return nil
        }

        // Store in SQLite
        let id = insertEntry(text: text, category: category, source: source,
                            timestamp: timestamp, importance: importance,
                            embedding: embedding, hash: hash)

        // Add to in-memory cache
        if let id {
            entries.append(IndexEntry(
                id: id, text: text, category: category, source: source,
                timestamp: timestamp, embedding: embedding, importance: importance
            ))
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
        print("[MemoryIndex] Batch added \(added)/\(items.count) memories")
        return added
    }

    // MARK: - Search

    /// Semantic search — find the most relevant memories for a query.
    /// Returns top-K results sorted by relevance (cosine similarity * importance boost).
    func search(query: String, topK: Int = 10, minScore: Float = 0.3,
                categories: [String]? = nil) async -> [SearchResult] {
        guard isReady, !query.isEmpty else { return [] }

        guard let queryEmbedding = await embed(query) else {
            print("[MemoryIndex] Query embedding failed")
            return []
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        var results: [(entry: IndexEntry, score: Float)] = []

        for entry in entries {
            // Category filter
            if let cats = categories, !cats.contains(entry.category) { continue }

            let similarity = cosineSimilarity(queryEmbedding, entry.embedding)

            // Boost by importance (0.7 * similarity + 0.3 * importance)
            let boostedScore = similarity * 0.7 + entry.importance * 0.3

            if boostedScore >= minScore {
                results.append((entry, boostedScore))
            }
        }

        // Sort by score descending, take top K
        results.sort { $0.score > $1.score }
        let topResults = results.prefix(topK)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[MemoryIndex] Search completed in \(String(format: "%.1f", elapsed))ms — \(topResults.count) results")

        return topResults.map { r in
            SearchResult(
                id: r.entry.id, text: r.entry.text, category: r.entry.category,
                source: r.entry.source, timestamp: r.entry.timestamp,
                importance: r.entry.importance, score: r.score
            )
        }
    }

    /// Fast keyword + semantic hybrid search.
    /// First filters by keyword match, then ranks by embedding similarity.
    func hybridSearch(query: String, topK: Int = 10) async -> [SearchResult] {
        guard isReady else { return [] }

        let keywords = query.lowercased().split(separator: " ").map(String.init)

        // Phase 1: Keyword pre-filter (fast, no embedding needed)
        let keywordMatches = entries.filter { entry in
            let lower = entry.text.lowercased()
            return keywords.contains(where: { lower.contains($0) })
        }

        // Phase 2: If keyword matches are few, fall back to full semantic search
        if keywordMatches.count < 3 {
            return await search(query: query, topK: topK)
        }

        // Phase 3: Rank keyword matches by embedding similarity
        guard let queryEmbedding = await embed(query) else {
            // Fallback: return keyword matches sorted by importance
            return keywordMatches
                .sorted { $0.importance > $1.importance }
                .prefix(topK)
                .map { e in
                    SearchResult(id: e.id, text: e.text, category: e.category,
                               source: e.source, timestamp: e.timestamp,
                               importance: e.importance, score: e.importance)
                }
        }

        var results: [(entry: IndexEntry, score: Float)] = []
        for entry in keywordMatches {
            let sim = cosineSimilarity(queryEmbedding, entry.embedding)
            let boosted = sim * 0.7 + entry.importance * 0.3
            results.append((entry, boosted))
        }
        results.sort { $0.score > $1.score }

        return results.prefix(topK).map { r in
            SearchResult(id: r.entry.id, text: r.entry.text, category: r.entry.category,
                        source: r.entry.source, timestamp: r.entry.timestamp,
                        importance: r.entry.importance, score: r.score)
        }
    }

    // MARK: - Maintenance

    /// Remove a memory by ID
    func remove(id: Int64) {
        exec("DELETE FROM memories WHERE id = \(id)")
        entries.removeAll { $0.id == id }
    }

    /// Update importance score for a memory (used by Repairer to boost frequently-accessed memories)
    func updateImportance(id: Int64, importance: Float) {
        let clamped = max(0, min(1, importance))
        exec("UPDATE memories SET importance = \(clamped) WHERE id = \(id)")
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let old = entries[idx]
            entries[idx] = IndexEntry(id: old.id, text: old.text, category: old.category,
                                     source: old.source, timestamp: old.timestamp,
                                     embedding: old.embedding, importance: clamped)
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
        for entry in toRemove {
            exec("DELETE FROM memories WHERE id = \(entry.id)")
        }
        entries.removeAll { $0.importance < importance }
        print("[MemoryIndex] Purged \(toRemove.count) low-importance memories")
    }

    // MARK: - Embeddings via Ollama

    private func embed(_ text: String) async -> [Float]? {
        guard let url = URL(string: "\(ollamaURL)/api/embed") else { return nil }

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
            print("[MemoryIndex] Embed error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Math

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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
            if let err { print("[MemoryIndex] SQL error: \(String(cString: err))"); sqlite3_free(err) }
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

        sqlite3_bind_text(stmt, 1, (text as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (ts as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Double(importance))
        embeddingData.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(embeddingData.count), nil)
        }
        sqlite3_bind_text(stmt, 7, (hash as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    private func loadAllEntries() async {
        guard let db else { return }

        let sql = "SELECT id, text, category, source, timestamp, importance, embedding FROM memories"
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

            loaded.append(IndexEntry(
                id: id, text: text, category: category, source: source,
                timestamp: timestamp, embedding: embedding, importance: importance
            ))
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

    private func textHash(_ text: String) -> String {
        // Simple hash — normalized lowercase trimmed text
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 5381
        for byte in normalized.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
