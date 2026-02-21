// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — LoA Memory Engine
// A persistent, structured knowledge store that gives all Torbo agents
// a shared, evolving understanding of the user.
//
// Five core tables: facts, people, patterns, open_loops, signals
// SQLite-backed, auto-initializing, with confidence decay.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The Library of Alexandria Memory Engine — structured knowledge persistence
/// for all Torbo agents. Unlike the vector-based MemoryIndex, this stores
/// typed, queryable records: facts, people, patterns, open loops, and signals.
actor LoAMemoryEngine {
    static let shared = LoAMemoryEngine()

    private var db: OpaquePointer?
    private let dbPath: String
    private var isReady = false

    /// Confidence floor — facts below this threshold are archived
    private let archiveThreshold: Double = 0.2
    /// Days before unreinforced facts begin to decay
    private let decayAgeDays: Int = 90
    /// Weekly decay rate for stale facts
    private let decayRate: Double = 0.10

    init() {
        dbPath = PlatformPaths.dataDir + "/loa.db"
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }

        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open LoA database: \(dbPath)", subsystem: "LoA·Engine")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA foreign_keys=ON")

        createSchema()
        isReady = true

        let counts = factCountsByCategory()
        let total = counts.values.reduce(0, +)
        TorboLog.info("Ready — \(total) facts across \(counts.count) categories, db: \(dbPath)", subsystem: "LoA·Engine")
    }

    func shutdown() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        isReady = false
        TorboLog.info("LoA Memory Engine shut down", subsystem: "LoA·Engine")
    }

    // MARK: - Schema

    private func createSchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                category TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 0.8,
                source TEXT NOT NULL DEFAULT 'user',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                expires_at TEXT
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_facts_category ON facts(category)")
        exec("CREATE INDEX IF NOT EXISTS idx_facts_key ON facts(key)")
        exec("CREATE INDEX IF NOT EXISTS idx_facts_confidence ON facts(confidence DESC)")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_facts_cat_key ON facts(category, key)")

        exec("""
            CREATE TABLE IF NOT EXISTS people (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                relationship TEXT,
                last_contact TEXT,
                sentiment TEXT,
                notes TEXT,
                updated_at TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_people_name ON people(name)")

        exec("""
            CREATE TABLE IF NOT EXISTS patterns (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_type TEXT NOT NULL,
                description TEXT NOT NULL,
                frequency INTEGER NOT NULL DEFAULT 1,
                last_observed TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 0.5
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_patterns_type ON patterns(pattern_type)")
        exec("CREATE INDEX IF NOT EXISTS idx_patterns_confidence ON patterns(confidence DESC)")

        exec("""
            CREATE TABLE IF NOT EXISTS open_loops (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                topic TEXT NOT NULL,
                first_mentioned TEXT NOT NULL,
                mention_count INTEGER NOT NULL DEFAULT 1,
                last_mentioned TEXT NOT NULL,
                resolved INTEGER NOT NULL DEFAULT 0,
                priority INTEGER NOT NULL DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_loops_resolved ON open_loops(resolved)")
        exec("CREATE INDEX IF NOT EXISTS idx_loops_priority ON open_loops(priority DESC)")

        exec("""
            CREATE TABLE IF NOT EXISTS signals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                signal_type TEXT NOT NULL,
                value TEXT NOT NULL,
                observed_at TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_signals_type ON signals(signal_type)")
        exec("CREATE INDEX IF NOT EXISTS idx_signals_observed ON signals(observed_at DESC)")
    }

    // MARK: - Facts

    @discardableResult
    func writeFact(category: String, key: String, value: String,
                   confidence: Double, source: String = "user") -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let conf = max(0, min(1, confidence))

        let upsertSQL = """
            INSERT INTO facts (category, key, value, confidence, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(category, key) DO UPDATE SET
                value = excluded.value,
                confidence = MAX(confidence, excluded.confidence),
                source = excluded.source,
                updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK else {
            logSQLError("writeFact prepare")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, conf)
        sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            logSQLError("writeFact step")
            return nil
        }

        let rowID = sqlite3_last_insert_rowid(db)
        TorboLog.debug("Fact written: [\(category)] \(key) = \(value.prefix(60)) (conf: \(String(format: "%.2f", conf)))", subsystem: "LoA·Engine")
        return rowID
    }

    @discardableResult
    func writeTimeSensitiveFact(category: String, key: String, value: String,
                                confidence: Double, source: String = "user",
                                expiresAt: Date) -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let conf = max(0, min(1, confidence))
        let expiry = ISO8601DateFormatter().string(from: expiresAt)

        let sql = """
            INSERT INTO facts (category, key, value, confidence, source, created_at, updated_at, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(category, key) DO UPDATE SET
                value = excluded.value,
                confidence = MAX(confidence, excluded.confidence),
                source = excluded.source,
                updated_at = excluded.updated_at,
                expires_at = excluded.expires_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, conf)
        sqlite3_bind_text(stmt, 5, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, (expiry as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Context Search (Fuzzy across all tables)

    func searchContext(topic: String) -> [[String: Any]] {
        guard isReady, let db else { return [] }

        let searchTerm = "%\(topic)%"
        var results: [(item: [String: Any], relevance: Double)] = []
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // Search facts
        let factSQL = "SELECT id, category, key, value, confidence, source, created_at, updated_at FROM facts WHERE (key LIKE ? OR value LIKE ? OR category LIKE ?) AND confidence >= ? ORDER BY confidence DESC LIMIT 20"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, factSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, archiveThreshold)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let conf = sqlite3_column_double(stmt, 4)
                let item: [String: Any] = [
                    "type": "fact",
                    "id": sqlite3_column_int64(stmt, 0),
                    "category": String(cString: sqlite3_column_text(stmt, 1)),
                    "key": String(cString: sqlite3_column_text(stmt, 2)),
                    "value": String(cString: sqlite3_column_text(stmt, 3)),
                    "confidence": conf,
                    "source": String(cString: sqlite3_column_text(stmt, 5)),
                    "updated_at": String(cString: sqlite3_column_text(stmt, 7))
                ]
                results.append((item, conf))
            }
            sqlite3_finalize(stmt)
        }

        // Search people
        let peopleSQL = "SELECT id, name, relationship, sentiment, notes, updated_at FROM people WHERE name LIKE ? OR relationship LIKE ? OR notes LIKE ? LIMIT 10"
        if sqlite3_prepare_v2(db, peopleSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)

            while sqlite3_step(stmt) == SQLITE_ROW {
                var item: [String: Any] = [
                    "type": "person",
                    "id": sqlite3_column_int64(stmt, 0),
                    "name": String(cString: sqlite3_column_text(stmt, 1))
                ]
                if let ptr = sqlite3_column_text(stmt, 2) { item["relationship"] = String(cString: ptr) }
                if let ptr = sqlite3_column_text(stmt, 3) { item["sentiment"] = String(cString: ptr) }
                if let ptr = sqlite3_column_text(stmt, 4) { item["notes"] = String(cString: ptr) }
                item["updated_at"] = String(cString: sqlite3_column_text(stmt, 5))
                results.append((item, 0.9))
            }
            sqlite3_finalize(stmt)
        }

        // Search patterns
        let patternSQL = "SELECT id, pattern_type, description, frequency, confidence FROM patterns WHERE description LIKE ? OR pattern_type LIKE ? ORDER BY confidence DESC LIMIT 10"
        if sqlite3_prepare_v2(db, patternSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let conf = sqlite3_column_double(stmt, 4)
                let item: [String: Any] = [
                    "type": "pattern",
                    "id": sqlite3_column_int64(stmt, 0),
                    "pattern_type": String(cString: sqlite3_column_text(stmt, 1)),
                    "description": String(cString: sqlite3_column_text(stmt, 2)),
                    "frequency": Int(sqlite3_column_int(stmt, 3)),
                    "confidence": conf
                ]
                results.append((item, conf))
            }
            sqlite3_finalize(stmt)
        }

        // Search open loops
        let loopsSQL = "SELECT id, topic, mention_count, last_mentioned, priority FROM open_loops WHERE topic LIKE ? AND resolved = 0 ORDER BY priority DESC, mention_count DESC LIMIT 10"
        if sqlite3_prepare_v2(db, loopsSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let priority = Int(sqlite3_column_int(stmt, 4))
                let item: [String: Any] = [
                    "type": "open_loop",
                    "id": sqlite3_column_int64(stmt, 0),
                    "topic": String(cString: sqlite3_column_text(stmt, 1)),
                    "mention_count": Int(sqlite3_column_int(stmt, 2)),
                    "last_mentioned": String(cString: sqlite3_column_text(stmt, 3)),
                    "priority": priority
                ]
                results.append((item, Double(priority) / 10.0 + 0.5))
            }
            sqlite3_finalize(stmt)
        }

        // Search signals (recent only)
        let signalSQL = "SELECT id, signal_type, value, observed_at FROM signals WHERE signal_type LIKE ? OR value LIKE ? ORDER BY observed_at DESC LIMIT 10"
        if sqlite3_prepare_v2(db, signalSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (searchTerm as NSString).utf8String, -1, SQLITE_TRANSIENT)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let item: [String: Any] = [
                    "type": "signal",
                    "id": sqlite3_column_int64(stmt, 0),
                    "signal_type": String(cString: sqlite3_column_text(stmt, 1)),
                    "value": String(cString: sqlite3_column_text(stmt, 2)),
                    "observed_at": String(cString: sqlite3_column_text(stmt, 3))
                ]
                results.append((item, 0.6))
            }
            sqlite3_finalize(stmt)
        }

        results.sort { $0.relevance > $1.relevance }
        return results.map { $0.item }
    }

    // MARK: - People

    func getPerson(name: String) -> [String: Any]? {
        guard isReady, let db else { return nil }

        let sql = "SELECT id, name, relationship, last_contact, sentiment, notes, updated_at FROM people WHERE LOWER(name) = LOWER(?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var person: [String: Any] = [
            "id": sqlite3_column_int64(stmt, 0),
            "name": String(cString: sqlite3_column_text(stmt, 1))
        ]
        if let ptr = sqlite3_column_text(stmt, 2) { person["relationship"] = String(cString: ptr) }
        if let ptr = sqlite3_column_text(stmt, 3) { person["last_contact"] = String(cString: ptr) }
        if let ptr = sqlite3_column_text(stmt, 4) { person["sentiment"] = String(cString: ptr) }
        if let ptr = sqlite3_column_text(stmt, 5) { person["notes"] = String(cString: ptr) }
        person["updated_at"] = String(cString: sqlite3_column_text(stmt, 6))

        return person
    }

    @discardableResult
    func upsertPerson(name: String, relationship: String? = nil,
                      lastContact: String? = nil, sentiment: String? = nil,
                      notes: String? = nil) -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let checkSQL = "SELECT id, relationship, last_contact, sentiment, notes FROM people WHERE LOWER(name) = LOWER(?)"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(checkStmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)

        let exists = sqlite3_step(checkStmt) == SQLITE_ROW
        let existingID = exists ? sqlite3_column_int64(checkStmt, 0) : 0
        let existingRel = exists ? (sqlite3_column_text(checkStmt, 1).map { String(cString: $0) }) : nil
        let existingContact = exists ? (sqlite3_column_text(checkStmt, 2).map { String(cString: $0) }) : nil
        let existingSentiment = exists ? (sqlite3_column_text(checkStmt, 3).map { String(cString: $0) }) : nil
        let existingNotes = exists ? (sqlite3_column_text(checkStmt, 4).map { String(cString: $0) }) : nil
        sqlite3_finalize(checkStmt)

        if exists {
            let finalRel = relationship ?? existingRel
            let finalContact = lastContact ?? existingContact
            let finalSentiment = sentiment ?? existingSentiment
            let finalNotes = notes ?? existingNotes

            let updateSQL = "UPDATE people SET relationship = ?, last_contact = ?, sentiment = ?, notes = ?, updated_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            if let rel = finalRel {
                sqlite3_bind_text(stmt, 1, (rel as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 1) }
            if let contact = finalContact {
                sqlite3_bind_text(stmt, 2, (contact as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 2) }
            if let sent = finalSentiment {
                sqlite3_bind_text(stmt, 3, (sent as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 3) }
            if let n = finalNotes {
                sqlite3_bind_text(stmt, 4, (n as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_text(stmt, 5, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 6, existingID)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return existingID
        } else {
            let insertSQL = "INSERT INTO people (name, relationship, last_contact, sentiment, notes, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let rel = relationship {
                sqlite3_bind_text(stmt, 2, (rel as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 2) }
            if let contact = lastContact {
                sqlite3_bind_text(stmt, 3, (contact as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 3) }
            if let sent = sentiment {
                sqlite3_bind_text(stmt, 4, (sent as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 4) }
            if let n = notes {
                sqlite3_bind_text(stmt, 5, (n as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_text(stmt, 6, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
    }

    // MARK: - Open Loops

    func getOpenLoops() -> [[String: Any]] {
        guard isReady, let db else { return [] }

        let sql = "SELECT id, topic, first_mentioned, mention_count, last_mentioned, priority FROM open_loops WHERE resolved = 0 ORDER BY priority DESC, mention_count DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var loops: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            loops.append([
                "id": sqlite3_column_int64(stmt, 0),
                "topic": String(cString: sqlite3_column_text(stmt, 1)),
                "first_mentioned": String(cString: sqlite3_column_text(stmt, 2)),
                "mention_count": Int(sqlite3_column_int(stmt, 3)),
                "last_mentioned": String(cString: sqlite3_column_text(stmt, 4)),
                "priority": Int(sqlite3_column_int(stmt, 5))
            ])
        }
        return loops
    }

    @discardableResult
    func upsertOpenLoop(topic: String, priority: Int = 0) -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let checkSQL = "SELECT id, mention_count FROM open_loops WHERE LOWER(topic) = LOWER(?) AND resolved = 0"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(checkStmt, 1, (topic as NSString).utf8String, -1, SQLITE_TRANSIENT)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingID = sqlite3_column_int64(checkStmt, 0)
            let currentCount = sqlite3_column_int(checkStmt, 1)
            sqlite3_finalize(checkStmt)

            let updateSQL = "UPDATE open_loops SET mention_count = ?, last_mentioned = ?, priority = MAX(priority, ?) WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, currentCount + 1)
            sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(priority))
            sqlite3_bind_int64(stmt, 4, existingID)
            sqlite3_step(stmt)
            return existingID
        }
        sqlite3_finalize(checkStmt)

        let insertSQL = "INSERT INTO open_loops (topic, first_mentioned, mention_count, last_mentioned, resolved, priority) VALUES (?, ?, 1, ?, 0, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (topic as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(priority))

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func resolveLoop(id: Int64) -> Bool {
        guard isReady, let db else { return false }
        let sql = "UPDATE open_loops SET resolved = 1 WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Signals

    @discardableResult
    func logSignal(signalType: String, value: String) -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let sql = "INSERT INTO signals (signal_type, value, observed_at) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (signalType as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        TorboLog.debug("Signal logged: \(signalType) = \(value)", subsystem: "LoA·Engine")
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Patterns

    func getPatterns() -> [[String: Any]] {
        guard isReady, let db else { return [] }

        let sql = "SELECT id, pattern_type, description, frequency, last_observed, confidence FROM patterns ORDER BY confidence DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var patterns: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            patterns.append([
                "id": sqlite3_column_int64(stmt, 0),
                "pattern_type": String(cString: sqlite3_column_text(stmt, 1)),
                "description": String(cString: sqlite3_column_text(stmt, 2)),
                "frequency": Int(sqlite3_column_int(stmt, 3)),
                "last_observed": String(cString: sqlite3_column_text(stmt, 4)),
                "confidence": sqlite3_column_double(stmt, 5)
            ])
        }
        return patterns
    }

    @discardableResult
    func upsertPattern(patternType: String, description: String,
                       confidence: Double = 0.5) -> Int64? {
        guard isReady, let db else { return nil }

        let now = isoNow()
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        let checkSQL = "SELECT id, frequency, confidence FROM patterns WHERE LOWER(pattern_type) = LOWER(?) AND LOWER(description) = LOWER(?)"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(checkStmt, 1, (patternType as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(checkStmt, 2, (description as NSString).utf8String, -1, SQLITE_TRANSIENT)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingID = sqlite3_column_int64(checkStmt, 0)
            let freq = sqlite3_column_int(checkStmt, 1)
            let existingConf = sqlite3_column_double(checkStmt, 2)
            sqlite3_finalize(checkStmt)

            let newConf = min(0.99, existingConf + 0.05)
            let updateSQL = "UPDATE patterns SET frequency = ?, last_observed = ?, confidence = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, freq + 1)
            sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, newConf)
            sqlite3_bind_int64(stmt, 4, existingID)
            sqlite3_step(stmt)
            return existingID
        }
        sqlite3_finalize(checkStmt)

        let insertSQL = "INSERT INTO patterns (pattern_type, description, frequency, last_observed, confidence) VALUES (?, ?, 1, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (patternType as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (description as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, max(0, min(1, confidence)))

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Decay System

    func runDecay() {
        guard isReady, let db else { return }

        let fmt = ISO8601DateFormatter()
        let now = Date()
        let nowStr = fmt.string(from: now)

        // 1. Expire time-sensitive facts past their deadline
        let expireSQL = "UPDATE facts SET confidence = 0 WHERE expires_at IS NOT NULL AND expires_at < ? AND confidence > 0"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, expireSQL, -1, &stmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, (nowStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            let expired = sqlite3_changes(db)
            if expired > 0 {
                TorboLog.info("Expired \(expired) time-sensitive facts", subsystem: "LoA·Engine")
            }
            sqlite3_finalize(stmt)
        }

        // 2. Decay old unreinforced facts
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -decayAgeDays, to: now) else { return }
        let cutoffStr = fmt.string(from: cutoff)

        let decaySQL = "SELECT id, confidence, updated_at FROM facts WHERE updated_at < ? AND confidence > ?"
        if sqlite3_prepare_v2(db, decaySQL, -1, &stmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, (cutoffStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, archiveThreshold)

            var decayUpdates: [(id: Int64, newConf: Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let conf = sqlite3_column_double(stmt, 1)
                let updatedStr = String(cString: sqlite3_column_text(stmt, 2))

                if let updatedDate = fmt.date(from: updatedStr) {
                    let daysSinceUpdate = now.timeIntervalSince(updatedDate) / 86400
                    let weeksSinceCutoff = max(0, (daysSinceUpdate - Double(decayAgeDays)) / 7.0)
                    let totalDecay = decayRate * weeksSinceCutoff
                    let newConf = max(0, conf - totalDecay)
                    if newConf != conf {
                        decayUpdates.append((id, newConf))
                    }
                }
            }
            sqlite3_finalize(stmt)

            if !decayUpdates.isEmpty {
                let updateSQL = "UPDATE facts SET confidence = ? WHERE id = ?"
                if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                    for (id, newConf) in decayUpdates {
                        sqlite3_reset(stmt)
                        sqlite3_bind_double(stmt, 1, newConf)
                        sqlite3_bind_int64(stmt, 2, id)
                        sqlite3_step(stmt)
                    }
                    sqlite3_finalize(stmt)
                    TorboLog.info("Decayed \(decayUpdates.count) stale facts", subsystem: "LoA·Engine")
                }
            }
        }
    }

    // MARK: - Health

    func health() -> [String: Any] {
        let counts = factCountsByCategory()
        let total = counts.values.reduce(0, +)
        let peopleCount = tableCount("people")
        let patternsCount = tableCount("patterns")
        let openLoopsCount = queryCount("SELECT COUNT(*) FROM open_loops WHERE resolved = 0")
        let signalsCount = tableCount("signals")

        return [
            "status": "ok",
            "engine": "loa-memory-engine",
            "db_path": dbPath,
            "facts": [
                "total": total,
                "by_category": counts
            ],
            "people": peopleCount,
            "patterns": patternsCount,
            "open_loops": openLoopsCount,
            "signals": signalsCount
        ]
    }

    func factCountsByCategory() -> [String: Int] {
        guard isReady, let db else { return [:] }

        let sql = "SELECT category, COUNT(*) FROM facts WHERE confidence >= ? GROUP BY category"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, archiveThreshold)

        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let category = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            counts[category] = count
        }
        return counts
    }

    // MARK: - SQLite Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                TorboLog.error("SQL error: \(String(cString: err))", subsystem: "LoA·Engine")
                sqlite3_free(err)
            }
        }
    }

    private func tableCount(_ table: String) -> Int {
        queryCount("SELECT COUNT(*) FROM \(table)")
    }

    private func queryCount(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func logSQLError(_ context: String) {
        if let db {
            let msg = String(cString: sqlite3_errmsg(db))
            TorboLog.error("\(context): \(msg)", subsystem: "LoA·Engine")
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
