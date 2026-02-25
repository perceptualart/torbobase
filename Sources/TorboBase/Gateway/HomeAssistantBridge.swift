// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Home Assistant Bridge
// HomeAssistantBridge.swift — REST + WebSocket API client for Home Assistant
// Entity discovery, control, state monitoring, and natural language mapping.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor HomeAssistantBridge {
    static let shared = HomeAssistantBridge()

    private var host: String = ""
    private var port: Int = 8123
    private var accessToken: String = ""
    private var useTLS: Bool = false
    private let session: URLSession
    private var isMonitoring = false
    private var wsTask: URLSessionWebSocketTask?
    private var entityCache: [String: HAEntity] = [:]
    private var lastCacheRefresh: Date = .distantPast

    struct HAEntity: Codable {
        let entityID: String
        let state: String
        let attributes: [String: AnyCodable]
        let lastChanged: String?
        let lastUpdated: String?

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case state
            case attributes
            case lastChanged = "last_changed"
            case lastUpdated = "last_updated"
        }

        func toDict() -> [String: Any] {
            var d: [String: Any] = [
                "entity_id": entityID,
                "state": state
            ]
            if let lc = lastChanged { d["last_changed"] = lc }
            if let lu = lastUpdated { d["last_updated"] = lu }
            var attrs: [String: Any] = [:]
            for (k, v) in attributes { attrs[k] = v.value }
            d["attributes"] = attrs
            return d
        }
    }

    // Simple wrapper for heterogeneous JSON values
    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) { self.value = value }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let v = try? container.decode(String.self) { value = v }
            else if let v = try? container.decode(Double.self) { value = v }
            else if let v = try? container.decode(Bool.self) { value = v }
            else if let v = try? container.decode(Int.self) { value = v }
            else { value = try container.decode(String.self) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let v = value as? String { try container.encode(v) }
            else if let v = value as? Double { try container.encode(v) }
            else if let v = value as? Bool { try container.encode(v) }
            else if let v = value as? Int { try container.encode(v) }
            else { try container.encode(String(describing: value)) }
        }
    }

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Configuration

    func configure(host: String, port: Int = 8123, accessToken: String, useTLS: Bool = false) {
        self.host = host
        self.port = port
        self.accessToken = accessToken
        self.useTLS = useTLS
    }

    var isEnabled: Bool { !host.isEmpty && !accessToken.isEmpty }

    private var baseURL: String {
        let scheme = useTLS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    // MARK: - REST API

    /// List all entities with current state
    func listEntities(domain: String? = nil) async -> [[String: Any]] {
        guard let data = await apiGet("/api/states") else { return [] }
        guard let entities = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var results = entities
        if let domain {
            results = results.filter {
                ($0["entity_id"] as? String)?.hasPrefix(domain + ".") == true
            }
        }

        // Update cache
        for entity in results {
            if let eid = entity["entity_id"] as? String {
                entityCache[eid] = HAEntity(
                    entityID: eid,
                    state: entity["state"] as? String ?? "unknown",
                    attributes: [:],
                    lastChanged: entity["last_changed"] as? String,
                    lastUpdated: entity["last_updated"] as? String
                )
            }
        }
        lastCacheRefresh = Date()

        return results.map { entity in
            let eid = entity["entity_id"] as? String ?? ""
            let state = entity["state"] as? String ?? ""
            let attrs = entity["attributes"] as? [String: Any] ?? [:]
            let friendlyName = attrs["friendly_name"] as? String ?? eid
            return [
                "entity_id": eid,
                "state": state,
                "friendly_name": friendlyName,
                "last_changed": entity["last_changed"] ?? "",
                "domain": eid.split(separator: ".").first.map(String.init) ?? ""
            ] as [String: Any]
        }
    }

    /// Get state of a specific entity
    func getState(entityID: String) async -> [String: Any]? {
        guard let data = await apiGet("/api/states/\(entityID)") else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Control an entity (turn on, turn off, set value, etc.)
    func callService(domain: String, service: String, entityID: String, data serviceData: [String: Any] = [:]) async -> Bool {
        var body = serviceData
        body["entity_id"] = entityID

        let result = await apiPost("/api/services/\(domain)/\(service)", body: body)
        guard result else { return false }
        TorboLog.info("HA: \(domain).\(service) → \(entityID)", subsystem: "HomeAssistant")

        await EventBus.shared.publish("homeassistant.service_call",
            payload: ["domain": domain, "service": service, "entity_id": entityID],
            source: "HomeAssistantBridge")

        return result
    }

    /// Get state history for an entity
    func getHistory(entityID: String, hours: Int = 24) async -> [[String: Any]] {
        let dateFormatter = ISO8601DateFormatter()
        let startTime = dateFormatter.string(from: Date().addingTimeInterval(-Double(hours * 3600)))
        guard let data = await apiGet("/api/history/period/\(startTime)?filter_entity_id=\(entityID)") else { return [] }
        guard let historyArrays = try? JSONSerialization.jsonObject(with: data) as? [[[String: Any]]],
              let history = historyArrays.first else { return [] }
        return history
    }

    /// Natural language → HA service call mapping
    func executeNaturalLanguage(_ command: String) async -> [String: Any] {
        let lower = command.lowercased()

        // Parse intent
        let (domain, service, entityHint) = parseCommand(lower)
        guard !domain.isEmpty else {
            return ["success": false, "error": "Could not understand command: \(command)"]
        }

        // Find matching entity
        if entityCache.isEmpty || Date().timeIntervalSince(lastCacheRefresh) > 300 {
            let _ = await listEntities()
        }

        let matchedEntity = findEntity(hint: entityHint, domain: domain)
        guard let entityID = matchedEntity else {
            return ["success": false, "error": "No matching \(domain) entity found for '\(entityHint)'"]
        }

        let success = await callService(domain: domain, service: service, entityID: entityID)
        return [
            "success": success,
            "domain": domain,
            "service": service,
            "entity_id": entityID,
            "command": command
        ]
    }

    // MARK: - WebSocket State Monitoring

    func startMonitoring() async {
        guard isEnabled, !isMonitoring else { return }
        isMonitoring = true
        let wsScheme = useTLS ? "wss" : "ws"
        let wsURL = "\(wsScheme)://\(host):\(port)/api/websocket"
        guard let url = URL(string: wsURL) else { return }

        TorboLog.info("Starting HA WebSocket monitoring at \(wsURL)", subsystem: "HomeAssistant")
        wsTask = session.webSocketTask(with: url)
        wsTask?.resume()

        // Authenticate
        let authMsg: [String: Any] = ["type": "auth", "access_token": accessToken]
        if let data = try? JSONSerialization.data(withJSONObject: authMsg),
           let str = String(data: data, encoding: .utf8) {
            try? await wsTask?.send(.string(str))
        }

        // Subscribe to state changes
        let subMsg: [String: Any] = ["id": 1, "type": "subscribe_events", "event_type": "state_changed"]
        if let data = try? JSONSerialization.data(withJSONObject: subMsg),
           let str = String(data: data, encoding: .utf8) {
            try? await wsTask?.send(.string(str))
        }

        // Listen for events
        Task {
            while isMonitoring {
                do {
                    let message = try await wsTask?.receive()
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        await handleWSEvent(json)
                    }
                } catch {
                    if isMonitoring {
                        TorboLog.error("WS error: \(error)", subsystem: "HomeAssistant")
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func handleWSEvent(_ json: [String: Any]) async {
        guard let eventType = json["type"] as? String, eventType == "event",
              let event = json["event"] as? [String: Any],
              let eventData = event["data"] as? [String: Any],
              let entityID = eventData["entity_id"] as? String,
              let newState = eventData["new_state"] as? [String: Any] else { return }

        let state = newState["state"] as? String ?? ""
        let attrs = newState["attributes"] as? [String: Any] ?? [:]
        let friendlyName = attrs["friendly_name"] as? String ?? entityID

        // Update cache
        entityCache[entityID] = HAEntity(
            entityID: entityID,
            state: state,
            attributes: [:],
            lastChanged: newState["last_changed"] as? String,
            lastUpdated: newState["last_updated"] as? String
        )

        // Publish state change to EventBus
        await EventBus.shared.publish("homeassistant.state_changed",
            payload: ["entity_id": entityID, "state": state, "friendly_name": friendlyName],
            source: "HomeAssistantBridge")
    }

    // MARK: - API Helpers

    private func apiGet(_ path: String) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            TorboLog.error("HA API GET \(path) failed: \(error)", subsystem: "HomeAssistant")
            return nil
        }
    }

    private func apiPost(_ path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(path)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode >= 200 && http.statusCode < 300
        } catch {
            TorboLog.error("HA API POST \(path) failed: \(error)", subsystem: "HomeAssistant")
            return false
        }
    }

    // MARK: - NLU Helpers

    private func parseCommand(_ command: String) -> (domain: String, service: String, entityHint: String) {
        // Turn on/off patterns
        if command.contains("turn on") || command.contains("switch on") {
            let hint = command.replacingOccurrences(of: "turn on|switch on|the|please", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if command.contains("light") { return ("light", "turn_on", hint) }
            if command.contains("fan") { return ("fan", "turn_on", hint) }
            return ("switch", "turn_on", hint)
        }
        if command.contains("turn off") || command.contains("switch off") {
            let hint = command.replacingOccurrences(of: "turn off|switch off|the|please", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if command.contains("light") { return ("light", "turn_off", hint) }
            if command.contains("fan") { return ("fan", "turn_off", hint) }
            return ("switch", "turn_off", hint)
        }
        // Lock/unlock
        if command.contains("lock") { return ("lock", command.contains("unlock") ? "unlock" : "lock", command) }
        // Temperature
        if command.contains("temperature") || command.contains("thermostat") || command.contains("heat") {
            return ("climate", "set_temperature", command)
        }
        // Scene
        if command.contains("scene") || command.contains("activate") {
            return ("scene", "turn_on", command)
        }
        return ("", "", command)
    }

    private func findEntity(hint: String, domain: String) -> String? {
        let hintWords = Set(hint.lowercased().split(separator: " ").map(String.init))
        var bestMatch: (entityID: String, score: Int)?

        for (eid, _) in entityCache where eid.hasPrefix(domain + ".") {
            let entityWords = Set(eid.replacingOccurrences(of: "_", with: " ")
                .lowercased().split(separator: " ").map(String.init))
            let overlap = hintWords.intersection(entityWords).count
            if overlap > 0 && (bestMatch == nil || overlap > bestMatch!.score) {
                bestMatch = (eid, overlap)
            }
        }
        return bestMatch?.entityID
    }
}
