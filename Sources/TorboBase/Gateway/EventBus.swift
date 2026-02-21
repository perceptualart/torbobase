// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Event Bus (stub — full implementation pending)

import Foundation

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

    func initialize() {
        TorboLog.info("Event bus initialized", subsystem: "EventBus")
    }

    @discardableResult
    func publish(_ name: String, payload: [String: String] = [:], source: String = "system") -> BusEvent {
        let event = BusEvent(name: name, payload: payload, source: source, timestamp: Date())
        recentBuffer.append(event)
        if recentBuffer.count > 1000 { recentBuffer.removeFirst(recentBuffer.count - 1000) }

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

    func addSSEClient(id: String, pattern: String, writer: ResponseWriter) {
        sseClients[id] = (pattern: pattern, writer: writer)
    }

    func removeSSEClient(id: String) {
        sseClients.removeValue(forKey: id)
    }

    func recentEvents(limit: Int, pattern: String? = nil) -> [BusEvent] {
        var events = recentBuffer
        if let p = pattern, p != "*" {
            events = events.filter { $0.name.hasPrefix(p.replacingOccurrences(of: "*", with: "")) }
        }
        return Array(events.suffix(limit))
    }

    func criticalEvents(limit: Int, name: String? = nil) -> [[String: Any]] {
        // Stub — critical events would come from SQLite audit trail
        return []
    }

    func stats() -> [String: Any] {
        ["total_events": recentBuffer.count,
         "sse_clients": sseClients.count,
         "buffer_size": recentBuffer.count]
    }
}
