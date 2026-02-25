// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — EntityGraph (Knowledge Graph)
// Typed relationships between entities — "Michael created Torbo", "Torbo runs on macOS".
// SQLite-backed with in-memory cache for fast traversal.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// A knowledge graph storing typed relationships between entities.
/// Enables rich context about topics: "What do I know about the connections between X and Y?"
actor EntityGraph {
    static let shared = EntityGraph()

    // MARK: - Types

    struct Relationship: Sendable {
        let id: Int64
        let subjectEntity: String     // "Michael"
        let predicate: String         // "created", "lives_in", "works_on", "likes"
        let objectEntity: String      // "Torbo Base"
        let confidence: Float         // 0-1
        let source: String            // memory ID or "agent_taught"
        let timestamp: Date
    }

    // MARK: - Storage

    private var db: OpaquePointer?
    private let dbPath: String

    /// In-memory cache: entity name (lowercased) → relationships involving that entity
    private var entityCache: [String: [Relationship]] = [:]
    private var isReady = false

    // MARK: - Init

    init() {
        let dir = PlatformPaths.appSupportDir.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("entity_graph.db").path
    }

    /// Per-user initializer for cloud multi-tenant isolation
    init(dbPath customPath: String) {
        let dir = (customPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = customPath
    }

    // MARK: - Lifecycle

    func initialize() {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open entity graph database: \(dbPath)", subsystem: "EntityGraph")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        exec("""
            CREATE TABLE IF NOT EXISTS relationships (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                subject TEXT NOT NULL,
                predicate TEXT NOT NULL,
                object TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 0.8,
                source TEXT NOT NULL DEFAULT 'extracted',
                timestamp REAL NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_rel_subject ON relationships(subject)")
        exec("CREATE INDEX IF NOT EXISTS idx_rel_object ON relationships(object)")
        exec("CREATE INDEX IF NOT EXISTS idx_rel_predicate ON relationships(predicate)")

        loadCache()
        isReady = true

        let count = entityCache.values.reduce(0) { $0 + $1.count } / 2 // Each rel counted twice
        TorboLog.info("Ready — \(count) relationships loaded", subsystem: "EntityGraph")
    }

    // MARK: - Add

    /// Add a new relationship. Returns the relationship ID.
    @discardableResult
    func add(subject: String, predicate: String, object: String,
             confidence: Float = 0.8, source: String = "extracted") -> Int64 {
        guard let db else { return -1 }

        // Check for duplicate (same subject-predicate-object)
        if isDuplicate(subject: subject, predicate: predicate, object: object) {
            return -1
        }

        let sql = "INSERT INTO relationships (subject, predicate, object, confidence, source, timestamp) VALUES (?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let now = Date()

        sqlite3_bind_text(stmt, 1, (subject as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (predicate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (object as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, Double(confidence))
        sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            TorboLog.error("Failed to add relationship: \(subject) \(predicate) \(object)", subsystem: "EntityGraph")
            return -1
        }

        let relID = sqlite3_last_insert_rowid(db)
        let rel = Relationship(id: relID, subjectEntity: subject, predicate: predicate,
                               objectEntity: object, confidence: confidence,
                               source: source, timestamp: now)

        // Update cache
        let subKey = subject.lowercased()
        let objKey = object.lowercased()
        entityCache[subKey, default: []].append(rel)
        if subKey != objKey {
            entityCache[objKey, default: []].append(rel)
        }

        return relID
    }

    // MARK: - Query

    /// All relationships where entity is subject OR object.
    func query(entity: String) -> [Relationship] {
        return entityCache[entity.lowercased()] ?? []
    }

    /// Entities related to a given entity via a specific predicate.
    func related(to entity: String, via predicate: String) -> [String] {
        let rels = query(entity: entity)
        var results: [String] = []
        let lower = entity.lowercased()
        for rel in rels where rel.predicate.lowercased() == predicate.lowercased() {
            if rel.subjectEntity.lowercased() == lower {
                results.append(rel.objectEntity)
            } else {
                results.append(rel.subjectEntity)
            }
        }
        return results
    }

    /// BFS from entity up to N hops — for rich context about a topic.
    func subgraph(entity: String, depth: Int = 2) -> [Relationship] {
        var visited: Set<String> = []
        var queue: [String] = [entity.lowercased()]
        var results: [Relationship] = []
        var currentDepth = 0

        while currentDepth < depth && !queue.isEmpty {
            var nextQueue: [String] = []
            for ent in queue {
                guard !visited.contains(ent) else { continue }
                visited.insert(ent)

                let rels = entityCache[ent] ?? []
                for rel in rels {
                    results.append(rel)
                    let subKey = rel.subjectEntity.lowercased()
                    let objKey = rel.objectEntity.lowercased()
                    if !visited.contains(subKey) { nextQueue.append(subKey) }
                    if !visited.contains(objKey) { nextQueue.append(objKey) }
                }
            }
            queue = nextQueue
            currentDepth += 1
        }

        // Deduplicate by ID
        var seen: Set<Int64> = []
        return results.filter { seen.insert($0.id).inserted }
    }

    /// All known entity names.
    var knownEntities: [String] {
        Array(entityCache.keys)
    }

    /// Total relationship count.
    var count: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM relationships", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Stats for API.
    func stats() -> [String: Any] {
        return [
            "total_relationships": count,
            "unique_entities": entityCache.count,
            "cache_entries": entityCache.values.reduce(0) { $0 + $1.count }
        ]
    }

    // MARK: - Maintenance

    /// Remove duplicate relationships (same subject-predicate-object, keep highest confidence).
    func deduplicateRelationships() -> Int {
        guard let db else { return 0 }

        let sql = """
            DELETE FROM relationships WHERE id NOT IN (
                SELECT MIN(id) FROM relationships
                GROUP BY LOWER(subject), LOWER(predicate), LOWER(object)
            )
        """
        exec(sql)
        let deleted = Int(sqlite3_changes(db))
        if deleted > 0 {
            TorboLog.info("Deduplicated \(deleted) relationships", subsystem: "EntityGraph")
            loadCache() // Rebuild cache after dedup
        }
        return deleted
    }

    // MARK: - Private

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { TorboLog.error("SQL error: \(String(cString: err))", subsystem: "EntityGraph"); sqlite3_free(err) }
        }
    }

    private func isDuplicate(subject: String, predicate: String, object: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT COUNT(*) FROM relationships WHERE LOWER(subject) = LOWER(?) AND LOWER(predicate) = LOWER(?) AND LOWER(object) = LOWER(?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (subject as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (predicate as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (object as NSString).utf8String, -1, SQLITE_TRANSIENT)

        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) > 0
    }

    private func loadCache() {
        guard let db else { return }
        entityCache.removeAll()

        let sql = "SELECT id, subject, predicate, object, confidence, source, timestamp FROM relationships"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            guard let subPtr = sqlite3_column_text(stmt, 1),
                  let predPtr = sqlite3_column_text(stmt, 2),
                  let objPtr = sqlite3_column_text(stmt, 3),
                  let srcPtr = sqlite3_column_text(stmt, 5) else { continue }

            let rel = Relationship(
                id: id,
                subjectEntity: String(cString: subPtr),
                predicate: String(cString: predPtr),
                objectEntity: String(cString: objPtr),
                confidence: Float(sqlite3_column_double(stmt, 4)),
                source: String(cString: srcPtr),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            )

            entityCache[rel.subjectEntity.lowercased(), default: []].append(rel)
            let objKey = rel.objectEntity.lowercased()
            if objKey != rel.subjectEntity.lowercased() {
                entityCache[objKey, default: []].append(rel)
            }
        }
    }
}
