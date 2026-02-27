// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Full-Text Conversation Search
// SQLite FTS5 index for searching across all past conversations.
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Full-text search engine for conversation history.
/// Uses SQLite FTS5 with porter stemming for fast, relevant search.
/// Data stored at: <dataDir>/search/conversation_fts.db
actor ConversationSearch {
    static let shared = ConversationSearch()

    private var db: OpaquePointer?
    private let dbPath: String
    private var isInitialized = false

    init() {
        let searchDir = PlatformPaths.dataDir + "/search"
        dbPath = searchDir + "/conversation_fts.db"
        try? FileManager.default.createDirectory(
            atPath: searchDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Initialization

    func initialize() {
        guard !isInitialized else { return }

        var localDB: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &localDB, flags, nil) == SQLITE_OK else {
            TorboLog.error("Failed to open search DB at \(dbPath)", subsystem: "Search")
            return
        }
        db = localDB

        // WAL mode for concurrent reads
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        // Content table (source of truth)
        exec("""
            CREATE TABLE IF NOT EXISTS messages (
                message_id TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                agent TEXT NOT NULL DEFAULT 'sid',
                content TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT '',
                timestamp TEXT NOT NULL
            )
        """)

        // FTS5 virtual table (content-sync pattern)
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS conversation_fts USING fts5(
                content, role, agent, session_id,
                content='messages',
                content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        // Triggers for automatic sync
        exec("""
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO conversation_fts(rowid, content, role, agent, session_id)
                VALUES (new.rowid, new.content, new.role, new.agent, new.session_id);
            END
        """)
        exec("""
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO conversation_fts(conversation_fts, rowid, content, role, agent, session_id)
                VALUES ('delete', old.rowid, old.content, old.role, old.agent, old.session_id);
            END
        """)
        exec("""
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO conversation_fts(conversation_fts, rowid, content, role, agent, session_id)
                VALUES ('delete', old.rowid, old.content, old.role, old.agent, old.session_id);
                INSERT INTO conversation_fts(rowid, content, role, agent, session_id)
                VALUES (new.rowid, new.content, new.role, new.agent, new.session_id);
            END
        """)

        isInitialized = true
        let count = messageCount()
        TorboLog.info("Search index ready (\(count) messages indexed)", subsystem: "Search")
    }

    // MARK: - Indexing

    /// Index a single message (called from message pipeline)
    func indexMessage(id: String, role: String, agent: String, content: String, sessionID: String, timestamp: Date) {
        guard db != nil else { return }

        let iso = ISO8601DateFormatter()
        let ts = iso.string(from: timestamp)

        // INSERT OR IGNORE to avoid duplicates
        let sql = "INSERT OR IGNORE INTO messages (message_id, role, agent, content, session_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (role as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (agent as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (sessionID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (ts as NSString).utf8String, -1, nil)

        sqlite3_step(stmt)
    }

    /// Batch-check which message UUIDs already exist in the index (for sync dedup)
    func existingMessageIDs(from ids: [String]) -> Set<String> {
        guard db != nil, !ids.isEmpty else { return [] }

        var existing = Set<String>()
        // Build parameterized IN clause
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT message_id FROM messages WHERE message_id IN (\(placeholders))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (id as NSString).utf8String, -1, nil)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                existing.insert(String(cString: cStr))
            }
        }
        return existing
    }

    // MARK: - Backfill

    /// Backfill index from existing ConversationStore data
    func backfillFromStore() async {
        guard db != nil else { return }

        let existing = messageCount()
        let messages = await ConversationStore.shared.loadMessages()

        guard messages.count > existing else {
            TorboLog.info("Backfill: index up to date (\(existing) messages)", subsystem: "Search")
            return
        }

        TorboLog.info("Backfilling \(messages.count - existing) messages into search index...", subsystem: "Search")

        // Derive session IDs from 30-minute temporal gaps
        var currentSessionID = UUID().uuidString
        var lastTimestamp: Date?
        let sessionGap: TimeInterval = 30 * 60 // 30 minutes

        for msg in messages {
            if let last = lastTimestamp, msg.timestamp.timeIntervalSince(last) > sessionGap {
                currentSessionID = UUID().uuidString
            }
            lastTimestamp = msg.timestamp

            indexMessage(
                id: msg.id.uuidString,
                role: msg.role,
                agent: msg.agentID ?? "sid",
                content: msg.content,
                sessionID: currentSessionID,
                timestamp: msg.timestamp
            )
        }

        let total = messageCount()
        TorboLog.info("Backfill complete: \(total) messages indexed", subsystem: "Search")
    }

    // MARK: - Search

    /// Search result with context
    struct SearchHit {
        let messageID: String
        let role: String
        let agent: String
        let content: String
        let sessionID: String
        let timestamp: String
        let snippet: String
        let rank: Double
    }

    /// Full-text search across conversations
    func search(query: String, agent: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 20, offset: Int = 0) -> [SearchHit] {
        guard db != nil, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        // Build the query with optional filters
        var sql = """
            SELECT m.message_id, m.role, m.agent, m.content, m.session_id, m.timestamp,
                   snippet(conversation_fts, 0, '→', '←', '...', 40) as snip,
                   rank
            FROM conversation_fts f
            JOIN messages m ON m.rowid = f.rowid
            WHERE conversation_fts MATCH ?
        """
        var params: [String] = [sanitized]

        if let agent = agent, !agent.isEmpty {
            sql += " AND m.agent = ?"
            params.append(agent)
        }

        let iso = ISO8601DateFormatter()
        if let from = from {
            sql += " AND m.timestamp >= ?"
            params.append(iso.string(from: from))
        }
        if let to = to {
            sql += " AND m.timestamp <= ?"
            params.append(iso.string(from: to))
        }

        sql += " ORDER BY rank LIMIT ? OFFSET ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            TorboLog.error("Search query failed: \(err)", subsystem: "Search")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
        }
        sqlite3_bind_int(stmt, Int32(params.count + 1), Int32(limit))
        sqlite3_bind_int(stmt, Int32(params.count + 2), Int32(offset))

        var results: [SearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hit = SearchHit(
                messageID: col(stmt, 0),
                role: col(stmt, 1),
                agent: col(stmt, 2),
                content: col(stmt, 3),
                sessionID: col(stmt, 4),
                timestamp: col(stmt, 5),
                snippet: col(stmt, 6),
                rank: sqlite3_column_double(stmt, 7)
            )
            results.append(hit)
        }

        return results
    }

    /// Search and return session-level results (grouped by session)
    func searchSessions(query: String, limit: Int = 10) -> [[String: Any]] {
        guard db != nil, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        let sql = """
            SELECT m.session_id,
                   MIN(m.timestamp) as first_msg,
                   MAX(m.timestamp) as last_msg,
                   COUNT(*) as hit_count,
                   GROUP_CONCAT(DISTINCT m.agent) as agents,
                   MIN(rank) as best_rank
            FROM conversation_fts f
            JOIN messages m ON m.rowid = f.rowid
            WHERE conversation_fts MATCH ?
            GROUP BY m.session_id
            ORDER BY best_rank
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sanitized as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let session: [String: Any] = [
                "session_id": col(stmt, 0),
                "first_message": col(stmt, 1),
                "last_message": col(stmt, 2),
                "hit_count": Int(sqlite3_column_int(stmt, 3)),
                "agents": col(stmt, 4).components(separatedBy: ","),
                "rank": sqlite3_column_double(stmt, 5)
            ]
            results.append(session)
        }

        return results
    }

    /// Enrich search results with surrounding context (1 message before, 1 after)
    func enrichWithContext(_ hits: [SearchHit]) -> [[String: Any]] {
        guard db != nil else { return [] }

        return hits.map { hit in
            var dict = hitToDict(hit)

            // Get surrounding messages in the same session
            let contextSQL = """
                SELECT role, agent, content, timestamp FROM messages
                WHERE session_id = ? AND message_id != ?
                AND timestamp BETWEEN datetime(?, '-5 minutes') AND datetime(?, '+5 minutes')
                ORDER BY timestamp
                LIMIT 4
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, contextSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (hit.sessionID as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (hit.messageID as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (hit.timestamp as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (hit.timestamp as NSString).utf8String, -1, nil)

                var context: [[String: String]] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    context.append([
                        "role": col(stmt, 0),
                        "agent": col(stmt, 1),
                        "content": String(col(stmt, 2).prefix(200)),
                        "timestamp": col(stmt, 3)
                    ])
                }
                sqlite3_finalize(stmt)
                dict["context"] = context
            }

            return dict
        }
    }

    // MARK: - Stats

    func messageCount() -> Int {
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM messages"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    func stats() -> [String: Any] {
        guard db != nil else { return ["status": "not_initialized"] }

        var result: [String: Any] = [
            "total_messages": messageCount(),
            "db_path": dbPath
        ]

        // Unique agents
        let agentSQL = "SELECT DISTINCT agent FROM messages"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, agentSQL, -1, &stmt, nil) == SQLITE_OK {
            var agents: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                agents.append(col(stmt, 0))
            }
            sqlite3_finalize(stmt)
            result["agents"] = agents
        }

        // Unique sessions
        let sessionSQL = "SELECT COUNT(DISTINCT session_id) FROM messages"
        if sqlite3_prepare_v2(db, sessionSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                result["session_count"] = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }

        // Date range
        let rangeSQL = "SELECT MIN(timestamp), MAX(timestamp) FROM messages"
        if sqlite3_prepare_v2(db, rangeSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                result["earliest"] = col(stmt, 0)
                result["latest"] = col(stmt, 1)
            }
            sqlite3_finalize(stmt)
        }

        // DB file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            result["db_size_bytes"] = size
            if size < 1024 * 1024 {
                result["db_size"] = String(format: "%.1f KB", Double(size) / 1024)
            } else {
                result["db_size"] = String(format: "%.1f MB", Double(size) / (1024 * 1024))
            }
        }

        return result
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            TorboLog.error("SQL exec failed: \(msg)", subsystem: "Search")
            sqlite3_free(err)
        }
    }

    private func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, idx) {
            return String(cString: cStr)
        }
        return ""
    }

    /// Sanitize FTS5 query to prevent injection of special operators
    private func sanitizeFTSQuery(_ input: String) -> String {
        var q = input

        // Remove FTS5 special characters
        let specials: [Character] = ["*", "\"", "(", ")", "{", "}", "^", "~", "+"]
        q = String(q.filter { !specials.contains($0) })

        // Remove FTS5 operators (case-insensitive)
        let operators = ["AND", "OR", "NOT", "NEAR"]
        let words = q.components(separatedBy: .whitespaces)
        let filtered = words.filter { word in
            !operators.contains(word.uppercased())
        }
        q = filtered.joined(separator: " ")

        // Collapse multiple spaces
        while q.contains("  ") {
            q = q.replacingOccurrences(of: "  ", with: " ")
        }

        return q.trimmingCharacters(in: .whitespaces)
    }

    func hitToDict(_ hit: SearchHit) -> [String: Any] {
        return [
            "message_id": hit.messageID,
            "role": hit.role,
            "agent": hit.agent,
            "content": hit.content,
            "session_id": hit.sessionID,
            "timestamp": hit.timestamp,
            "snippet": hit.snippet,
            "rank": hit.rank
        ]
    }
}
