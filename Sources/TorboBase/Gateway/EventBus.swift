// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Event Bus with SQLite Audit Trail

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

struct BusEvent {
    let name: String
    let payload: [String: String]
    let source: String
    let timestamp: Date

    func toDict() -> [String: Any] {
        ["name": name, "payload": payload, "source": source,
         "timestamp": timestamp.timeIntervalSince1970]
    }
}

actor EventBus {
    static let shared = EventBus()

    private var recentBuffer: [BusEvent] = []
    private var sseClients: [String: (pattern: String, writer: ResponseWriter)] = [:]
    private var db: OpaquePointer?
    private let dbPath: String = PlatformPaths.dataDir + "/audit_events.sqlite"

    /// Topic prefixes that qualify as critical and get persisted to SQLite
    private let criticalPrefixes = [
        "system.security", "agent.access", "memory.forget",
        "system.error", "auth.failure", "system.shutdown"
    ]

    func initialize() {
        openDatabase()
        TorboLog.info("Event bus initialized with audit trail", subsystem: "EventBus")
    }

    // MARK: - SQLite Audit Trail

    private func openDatabase() {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            TorboLog.error("Failed to open audit database at \(dbPath)", subsystem: "EventBus")
            return
        }

        let createSQL = """
            CREATE TABLE IF NOT EXISTS audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                topic TEXT NOT NULL,
                payload_json TEXT,
                source TEXT NOT NULL DEFAULT 'system',
                severity TEXT NOT NULL DEFAULT 'info',
                timestamp REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_audit_topic ON audit_events(topic);
            CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_events(timestamp);
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createSQL, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            TorboLog.error("Audit table creation failed: \(msg)", subsystem: "EventBus")
            sqlite3_free(errMsg)
        }
    }

    private func isCritical(_ name: String) -> Bool {
        criticalPrefixes.contains { name.hasPrefix($0) }
    }

    private func severityFor(_ name: String) -> String {
        if name.contains("security") || name.contains("failure") { return "critical" }
        if name.contains("error") { return "error" }
        if name.contains("access") || name.contains("forget") { return "warning" }
        return "info"
    }

    private func persistCriticalEvent(_ event: BusEvent) {
        guard let db else { return }

        let sql = "INSERT INTO audit_events (topic, payload_json, source, severity, timestamp) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let payloadJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: event.payload),
           let json = String(data: data, encoding: .utf8) {
            payloadJSON = json
        } else {
            payloadJSON = "{}"
        }

        sqlite3_bind_text(stmt, 1, (event.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (payloadJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (event.source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (severityFor(event.name) as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, event.timestamp.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            TorboLog.error("Failed to persist audit event: \(event.name)", subsystem: "EventBus")
        }
    }

    // MARK: - Publish

    @discardableResult
    func publish(_ name: String, payload: [String: String] = [:], source: String = "system") -> BusEvent {
        let event = BusEvent(name: name, payload: payload, source: source, timestamp: Date())
        recentBuffer.append(event)
        if recentBuffer.count > 1000 { recentBuffer.removeFirst(recentBuffer.count - 1000) }

        // Persist critical events to SQLite audit trail
        if isCritical(name) {
            persistCriticalEvent(event)
        }

        // Push to SSE clients
        if let data = try? JSONSerialization.data(withJSONObject: event.toDict()),
           let json = String(data: data, encoding: .utf8) {
            for (_, client) in sseClients {
                if client.pattern == "*" || name.hasPrefix(client.pattern.replacingOccurrences(of: "*", with: "")) {
                    client.writer.sendSSEChunk(json)
                }
            }
        }

        return event
    }

    // MARK: - SSE Clients

    func addSSEClient(id: String, pattern: String, writer: ResponseWriter) {
        sseClients[id] = (pattern: pattern, writer: writer)
    }

    func removeSSEClient(id: String) {
        sseClients.removeValue(forKey: id)
    }

    // MARK: - Queries

    func recentEvents(limit: Int, pattern: String? = nil) -> [BusEvent] {
        var events = recentBuffer
        if let p = pattern, p != "*" {
            events = events.filter { $0.name.hasPrefix(p.replacingOccurrences(of: "*", with: "")) }
        }
        return Array(events.suffix(limit))
    }

    func criticalEvents(limit: Int, name: String? = nil) -> [[String: Any]] {
        guard let db else { return [] }

        var sql = "SELECT id, topic, payload_json, source, severity, timestamp FROM audit_events"
        if let name, !name.isEmpty {
            sql += " WHERE topic LIKE ?"
        }
        sql += " ORDER BY timestamp DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        if let name, !name.isEmpty {
            let pattern = name.replacingOccurrences(of: "*", with: "%")
            sqlite3_bind_text(stmt, paramIdx, (pattern as NSString).utf8String, -1, nil)
            paramIdx += 1
        }
        sqlite3_bind_int(stmt, paramIdx, Int32(min(limit, 1000)))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let topic = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let payloadStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "{}"
            let source = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let severity = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let ts = sqlite3_column_double(stmt, 5)

            let payload: Any
            if let data = payloadStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                payload = parsed
            } else {
                payload = payloadStr
            }

            results.append([
                "id": id, "topic": topic, "payload": payload,
                "source": source, "severity": severity, "timestamp": ts
            ])
        }
        return results
    }

    func stats() -> [String: Any] {
        var auditCount = 0
        if let db {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM audit_events", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { auditCount = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        return [
            "total_events": recentBuffer.count,
            "sse_clients": sseClients.count,
            "buffer_size": recentBuffer.count,
            "audit_trail_count": auditCount
        ]
    }
}
