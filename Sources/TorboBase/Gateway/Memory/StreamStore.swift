// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — StreamStore (Unified Event Stream)
// The River — every meaningful system event flows through here.
// An append-only timeline of messages, tool calls, memories, and system events.
// SQLite-backed with in-memory recent buffer for fast access.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The River: a unified, append-only event stream for all system activity.
/// Every conversation, tool call, memory extraction, and system event
/// becomes a StreamEvent — discrete particles on invisible threads
/// that form coherent meaning from the right viewpoint.
actor StreamStore {
    static let shared = StreamStore()

    // MARK: - Types

    struct StreamEvent: Sendable {
        let id: Int64
        let timestamp: Date
        let kind: EventKind
        let channelKey: String        // "telegram:123", "discord:456", "web:session-id", "system"
        let userID: String?           // Canonical user ID (from UserIdentity)
        let agentID: String           // "sid", "custom-agent", "system"
        let content: String
        let metadata: [String: String]
        let parentID: Int64?          // For threading (tool result → tool call, reply → message)

        func toDict() -> [String: Any] {
            var d: [String: Any] = [
                "id": id,
                "timestamp": timestamp.timeIntervalSince1970,
                "kind": kind.rawValue,
                "channel_key": channelKey,
                "agent_id": agentID,
                "content": content
            ]
            if let userID { d["user_id"] = userID }
            if !metadata.isEmpty { d["metadata"] = metadata }
            if let parentID { d["parent_id"] = parentID }
            return d
        }
    }

    enum EventKind: String, Sendable, CaseIterable {
        case message        // User or assistant message
        case toolCall       // Tool invocation
        case toolResult     // Tool output
        case memory         // Memory extracted/modified/forgotten
        case system         // Startup, shutdown, config change, error
        case bridge         // Bridge connect/disconnect, platform events
        case research       // Deep research progress events
        case browserAction  // Browser agent actions
    }

    // MARK: - Storage

    private var db: OpaquePointer?
    private let dbPath: String

    /// In-memory buffer of recent events for fast access (max 2000)
    private var recentBuffer: [StreamEvent] = []
    private let maxBufferSize = 2000

    /// Retention: events older than this are eligible for compaction
    private let retentionDays: Int = 30

    // MARK: - Init

    init() {
        let dir = PlatformPaths.appSupportDir.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("stream.db").path
    }

    /// Per-user initializer for cloud multi-tenant isolation
    init(dbPath customPath: String) {
        let dir = (customPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = customPath
    }

    // MARK: - Lifecycle

    func initialize() {
        guard db == nil else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open stream database: \(dbPath)", subsystem: "Stream")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        exec("""
            CREATE TABLE IF NOT EXISTS stream (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                channel_key TEXT NOT NULL,
                user_id TEXT,
                agent_id TEXT NOT NULL DEFAULT 'sid',
                content TEXT NOT NULL,
                metadata_json TEXT DEFAULT '{}',
                parent_id INTEGER REFERENCES stream(id)
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_stream_time ON stream(timestamp DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_stream_channel ON stream(channel_key, timestamp DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_stream_kind ON stream(kind, timestamp DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_stream_user ON stream(user_id, timestamp DESC)")

        // Load recent events into buffer
        loadRecentBuffer()

        let count = recentBuffer.count
        TorboLog.info("Ready — \(count) recent events buffered", subsystem: "Stream")
    }

    // MARK: - Append

    /// Append a new event to the stream. Returns the event ID.
    @discardableResult
    func append(kind: EventKind, channelKey: String, agentID: String = "sid",
                content: String, metadata: [String: String] = [:],
                parentID: Int64? = nil, userID: String? = nil) -> Int64 {
        guard let db else { return -1 }

        let sql = """
            INSERT INTO stream (timestamp, kind, channel_key, user_id, agent_id, content, metadata_json, parent_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let now = Date()

        let metadataJSON: String
        if metadata.isEmpty {
            metadataJSON = "{}"
        } else if let data = try? JSONSerialization.data(withJSONObject: metadata),
                  let json = String(data: data, encoding: .utf8) {
            metadataJSON = json
        } else {
            metadataJSON = "{}"
        }

        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (channelKey as NSString).utf8String, -1, SQLITE_TRANSIENT)

        if let userID {
            sqlite3_bind_text(stmt, 4, (userID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_bind_text(stmt, 5, (agentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, (content as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, (metadataJSON as NSString).utf8String, -1, SQLITE_TRANSIENT)

        if let parentID {
            sqlite3_bind_int64(stmt, 8, parentID)
        } else {
            sqlite3_bind_null(stmt, 8)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            TorboLog.error("Failed to append stream event: \(kind.rawValue)", subsystem: "Stream")
            return -1
        }

        let eventID = sqlite3_last_insert_rowid(db)

        // Add to in-memory buffer
        let event = StreamEvent(
            id: eventID, timestamp: now, kind: kind, channelKey: channelKey,
            userID: userID, agentID: agentID, content: content,
            metadata: metadata, parentID: parentID
        )
        recentBuffer.append(event)
        if recentBuffer.count > maxBufferSize {
            recentBuffer.removeFirst(recentBuffer.count - maxBufferSize)
        }

        return eventID
    }

    // MARK: - Query

    /// Query events with optional filters.
    func query(channelKey: String? = nil, kinds: [EventKind]? = nil,
               userID: String? = nil, since: Date? = nil,
               limit: Int = 50) -> [StreamEvent] {
        guard let db else { return [] }

        var conditions: [String] = []
        var bindings: [(Int32, Any)] = []
        var bindIndex: Int32 = 1

        if let channelKey {
            conditions.append("channel_key = ?")
            bindings.append((bindIndex, channelKey))
            bindIndex += 1
        }
        if let kinds, !kinds.isEmpty {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("kind IN (\(placeholders))")
            for kind in kinds {
                bindings.append((bindIndex, kind.rawValue))
                bindIndex += 1
            }
        }
        if let userID {
            conditions.append("user_id = ?")
            bindings.append((bindIndex, userID))
            bindIndex += 1
        }
        if let since {
            conditions.append("timestamp >= ?")
            bindings.append((bindIndex, since.timeIntervalSince1970))
            bindIndex += 1
        }

        var sql = "SELECT id, timestamp, kind, channel_key, user_id, agent_id, content, metadata_json, parent_id FROM stream"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC LIMIT \(min(limit, 500))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, value) in bindings {
            if let s = value as? String {
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if let d = value as? Double {
                sqlite3_bind_double(stmt, idx, d)
            }
        }

        var results: [StreamEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = readEvent(from: stmt) {
                results.append(event)
            }
        }
        return results
    }

    /// Get recent context for a channel — last N events (messages + tool calls + results).
    func recentContext(channelKey: String, limit: Int = 30) -> [StreamEvent] {
        // Try in-memory buffer first for speed
        let channelEvents = recentBuffer.filter { $0.channelKey == channelKey }
        if channelEvents.count >= limit {
            return Array(channelEvents.suffix(limit))
        }

        // Fall back to SQLite
        return query(
            channelKey: channelKey,
            kinds: [.message, .toolCall, .toolResult],
            limit: limit
        ).reversed() // query returns DESC, we want chronological
    }

    /// Get a text summary of recent channel activity.
    func channelSummary(channelKey: String) -> String {
        let events = recentContext(channelKey: channelKey, limit: 20)
        guard !events.isEmpty else { return "" }

        var lines: [String] = []
        for event in events {
            switch event.kind {
            case .message:
                let role = event.metadata["role"] ?? (event.agentID == "system" ? "system" : "assistant")
                let preview = String(event.content.prefix(200))
                lines.append("[\(role)] \(preview)")
            case .toolCall:
                let tool = event.metadata["tool_name"] ?? "unknown"
                lines.append("[tool: \(tool)]")
            case .toolResult:
                let tool = event.metadata["tool_name"] ?? "unknown"
                let preview = String(event.content.prefix(100))
                lines.append("[result: \(tool)] \(preview)")
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Total event count.
    var count: Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM stream", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Event count by kind.
    func countByKind() -> [String: Int] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        let sql = "SELECT kind, COUNT(*) FROM stream GROUP BY kind"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let kindPtr = sqlite3_column_text(stmt, 0) {
                let kind = String(cString: kindPtr)
                let c = Int(sqlite3_column_int64(stmt, 1))
                counts[kind] = c
            }
        }
        return counts
    }

    // MARK: - Retention / Compaction

    /// Purge events older than retention period. Returns number of events purged.
    @discardableResult
    func purgeOldEvents() -> Int {
        guard let db else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let sql = "DELETE FROM stream WHERE timestamp < ? AND kind NOT IN ('memory', 'system')"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        sqlite3_step(stmt)

        let deleted = Int(sqlite3_changes(db))
        if deleted > 0 {
            TorboLog.info("Purged \(deleted) events older than \(retentionDays) days", subsystem: "Stream")
        }
        return deleted
    }

    /// Get stats for the stream.
    func stats() -> [String: Any] {
        let kindCounts = countByKind()
        return [
            "total_events": count,
            "buffered_events": recentBuffer.count,
            "retention_days": retentionDays,
            "events_by_kind": kindCounts
        ]
    }

    // MARK: - Private Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { TorboLog.error("SQL error: \(String(cString: err))", subsystem: "Stream"); sqlite3_free(err) }
        }
    }

    private func readEvent(from stmt: OpaquePointer?) -> StreamEvent? {
        guard let stmt else { return nil }

        let id = sqlite3_column_int64(stmt, 0)
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))

        guard let kindPtr = sqlite3_column_text(stmt, 2),
              let kind = EventKind(rawValue: String(cString: kindPtr)),
              let channelPtr = sqlite3_column_text(stmt, 3),
              let agentPtr = sqlite3_column_text(stmt, 5),
              let contentPtr = sqlite3_column_text(stmt, 6) else {
            return nil
        }

        let channelKey = String(cString: channelPtr)
        let agentID = String(cString: agentPtr)
        let content = String(cString: contentPtr)

        let userID: String?
        if let userPtr = sqlite3_column_text(stmt, 4) {
            userID = String(cString: userPtr)
        } else {
            userID = nil
        }

        var metadata: [String: String] = [:]
        if let metaPtr = sqlite3_column_text(stmt, 7) {
            let metaJSON = String(cString: metaPtr)
            if let data = metaJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                metadata = dict
            }
        }

        let parentID: Int64?
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL {
            parentID = sqlite3_column_int64(stmt, 8)
        } else {
            parentID = nil
        }

        return StreamEvent(
            id: id, timestamp: timestamp, kind: kind, channelKey: channelKey,
            userID: userID, agentID: agentID, content: content,
            metadata: metadata, parentID: parentID
        )
    }

    private func loadRecentBuffer() {
        guard let db else { return }

        let sql = """
            SELECT id, timestamp, kind, channel_key, user_id, agent_id, content, metadata_json, parent_id
            FROM stream ORDER BY timestamp DESC LIMIT \(maxBufferSize)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var events: [StreamEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = readEvent(from: stmt) {
                events.append(event)
            }
        }
        // Reverse to chronological order
        recentBuffer = events.reversed()
    }
}
