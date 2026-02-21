// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Internal Event Bus
// Publish/subscribe architecture replacing polling loops with clean event-driven flow.
// Synchronous, zero latency, no external dependencies. Pure Swift EventEmitter.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Event Model

/// A single event flowing through the bus.
struct BusEvent: Sendable {
    let id: String
    let name: String              // Dotted name: "ambient.stock.alert", "system.cron.fired"
    let payload: [String: String] // Flat string map for simplicity + Sendable safety
    let timestamp: Double         // Unix epoch
    let source: String            // Which subsystem published this

    /// Category prefix: "ambient", "user", "system", "lifeos"
    var category: String {
        String(name.prefix(while: { $0 != "." }))
    }

    func toDict() -> [String: Any] {
        [
            "id": id,
            "event": name,
            "payload": payload,
            "timestamp": timestamp,
            "source": source
        ]
    }

    func toJSON() -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: toDict(), options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Subscription

/// A registered subscriber with a wildcard pattern.
struct EventSubscription: Sendable {
    let id: String
    let pattern: String           // e.g. "ambient.*", "system.cron.*", "*"
    let handler: @Sendable (BusEvent) async -> Void

    /// Match a dotted event name against this subscription's pattern.
    /// Supports:
    ///   - Exact match: "ambient.stock.alert"
    ///   - Wildcard suffix: "ambient.*" matches "ambient.stock.alert"
    ///   - Global wildcard: "*" matches everything
    func matches(_ eventName: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == eventName { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return eventName == prefix || eventName.hasPrefix(prefix + ".")
        }
        return false
    }
}

// MARK: - SSE Client

/// A connected SSE client waiting for events.
struct SSEClient: Sendable {
    let id: String
    let pattern: String           // Filter pattern (same wildcard rules as subscriptions)
    let writer: any ResponseWriter
    let connectedAt: Double

    func matches(_ eventName: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == eventName { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return eventName == prefix || eventName.hasPrefix(prefix + ".")
        }
        return false
    }
}

// MARK: - Critical Events (persisted to SQLite)

/// Events that get written to SQLite for audit trail.
private let criticalEventPatterns: Set<String> = [
    "user.stress.detected",
    "user.commitment.made",
    "ambient.homekit.anomaly",
    "system.agent.error",
    "lifeos.relationship.flagged"
]

private func isCriticalEvent(_ name: String) -> Bool {
    criticalEventPatterns.contains(name)
}

// MARK: - Event Bus Actor

/// The central nervous system. All monitors and services publish here,
/// all subscribers receive here. No polling. No latency. Just events.
actor EventBus {
    static let shared = EventBus()

    // MARK: - State

    /// Ring buffer of the last 1000 events (in-memory)
    private var ringBuffer: [BusEvent] = []
    private let ringBufferCapacity = 1000

    /// Active subscriptions
    private var subscriptions: [String: EventSubscription] = [:]

    /// Connected SSE clients
    private var sseClients: [String: SSEClient] = [:]

    /// SQLite handle for critical event persistence
    private var db: OpaquePointer?
    private let dbPath: String

    /// Stats
    private var totalPublished: Int = 0
    private var totalSubscriptions: Int = 0

    // MARK: - Init

    init() {
        let dir = PlatformPaths.dataDir + "/events"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = dir + "/audit.db"
    }

    /// Initialize SQLite for critical event persistence.
    func initialize() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open event audit DB: \(dbPath)", subsystem: "EventBus")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        exec("""
            CREATE TABLE IF NOT EXISTS critical_events (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                payload TEXT NOT NULL,
                timestamp REAL NOT NULL,
                source TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_event_name ON critical_events(name)")
        exec("CREATE INDEX IF NOT EXISTS idx_event_ts ON critical_events(timestamp DESC)")

        let count = countCriticalEvents()
        TorboLog.info("Ready — \(count) critical events in audit trail", subsystem: "EventBus")
    }

    // MARK: - Publish

    /// Fire an event. All matching subscribers are notified. SSE clients receive the event.
    /// Critical events are persisted to SQLite.
    @discardableResult
    func publish(_ name: String, payload: [String: String] = [:], source: String = "") -> BusEvent {
        let event = BusEvent(
            id: UUID().uuidString,
            name: name,
            payload: payload,
            timestamp: Date().timeIntervalSince1970,
            source: source
        )

        // Ring buffer
        ringBuffer.append(event)
        if ringBuffer.count > ringBufferCapacity {
            ringBuffer.removeFirst(ringBuffer.count - ringBufferCapacity)
        }

        totalPublished += 1

        // Critical event persistence
        if isCriticalEvent(name) {
            persistCriticalEvent(event)
        }

        // Notify subscribers (fire-and-forget async)
        let matchingSubs = subscriptions.values.filter { $0.matches(name) }
        for sub in matchingSubs {
            let handler = sub.handler
            Task { await handler(event) }
        }

        // Push to SSE clients
        if let json = event.toJSON() {
            let matchingClients = sseClients.values.filter { $0.matches(name) }
            for client in matchingClients {
                client.writer.sendSSEChunk(json)
            }
        }

        TorboLog.debug("[\(name)] from \(source.isEmpty ? "unknown" : source)", subsystem: "EventBus")

        return event
    }

    // MARK: - Subscribe

    /// Subscribe to events matching a wildcard pattern. Returns subscription ID for unsubscribe.
    @discardableResult
    func subscribe(pattern: String, handler: @escaping @Sendable (BusEvent) async -> Void) -> String {
        let id = UUID().uuidString
        let sub = EventSubscription(id: id, pattern: pattern, handler: handler)
        subscriptions[id] = sub
        totalSubscriptions += 1
        TorboLog.debug("Subscribed [\(pattern)] → \(id.prefix(8))", subsystem: "EventBus")
        return id
    }

    // MARK: - Unsubscribe

    /// Remove a subscription by ID.
    func unsubscribe(id: String) {
        if subscriptions.removeValue(forKey: id) != nil {
            TorboLog.debug("Unsubscribed \(id.prefix(8))", subsystem: "EventBus")
        }
    }

    // MARK: - SSE Client Management

    /// Register an SSE client. Events matching the pattern are pushed as SSE chunks.
    func addSSEClient(id: String, pattern: String, writer: any ResponseWriter) {
        let client = SSEClient(
            id: id,
            pattern: pattern,
            writer: writer,
            connectedAt: Date().timeIntervalSince1970
        )
        sseClients[id] = client
        TorboLog.info("SSE client connected [\(pattern)] → \(id.prefix(8))", subsystem: "EventBus")
    }

    /// Remove an SSE client on disconnect.
    func removeSSEClient(id: String) {
        if sseClients.removeValue(forKey: id) != nil {
            TorboLog.info("SSE client disconnected \(id.prefix(8))", subsystem: "EventBus")
        }
    }

    // MARK: - Query

    /// Get the last N events from the ring buffer, optionally filtered by pattern.
    func recentEvents(limit: Int = 100, pattern: String? = nil) -> [BusEvent] {
        var events = ringBuffer
        if let pattern {
            let tempSub = EventSubscription(id: "", pattern: pattern, handler: { _ in })
            events = events.filter { tempSub.matches($0.name) }
        }
        return Array(events.suffix(limit).reversed())
    }

    /// Get critical events from SQLite, optionally filtered by name.
    func criticalEvents(limit: Int = 100, name: String? = nil) -> [[String: Any]] {
        guard let db else { return [] }

        var results: [[String: Any]] = []
        var stmt: OpaquePointer?
        let sql: String
        if let name {
            sql = "SELECT id, name, payload, timestamp, source FROM critical_events WHERE name = ? ORDER BY timestamp DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sql = "SELECT id, name, payload, timestamp, source FROM critical_events ORDER BY timestamp DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let evName = String(cString: sqlite3_column_text(stmt, 1))
            let payloadStr = String(cString: sqlite3_column_text(stmt, 2))
            let ts = sqlite3_column_double(stmt, 3)
            let source = String(cString: sqlite3_column_text(stmt, 4))

            let payload = (try? JSONSerialization.jsonObject(
                with: Data(payloadStr.utf8)
            ) as? [String: String]) ?? [:]

            results.append([
                "id": id,
                "event": evName,
                "payload": payload,
                "timestamp": ts,
                "source": source
            ])
        }
        return results
    }

    /// Stats for the event bus.
    func stats() -> [String: Any] {
        [
            "total_published": totalPublished,
            "buffer_size": ringBuffer.count,
            "buffer_capacity": ringBufferCapacity,
            "active_subscriptions": subscriptions.count,
            "total_subscriptions": totalSubscriptions,
            "sse_clients": sseClients.count,
            "critical_events": countCriticalEvents()
        ]
    }

    // MARK: - SQLite Helpers

    private func persistCriticalEvent(_ event: BusEvent) {
        guard let db else { return }

        let payloadJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: event.payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            payloadJSON = str
        } else {
            payloadJSON = "{}"
        }

        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO critical_events (id, name, payload, timestamp, source) VALUES (?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (event.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (event.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (payloadJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, event.timestamp)
        sqlite3_bind_text(stmt, 5, (event.source as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            TorboLog.error("Failed to persist critical event: \(event.name)", subsystem: "EventBus")
        }
    }

    private func countCriticalEvents() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM critical_events", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { TorboLog.error("SQL error: \(String(cString: err))", subsystem: "EventBus"); sqlite3_free(err) }
        }
    }
}
