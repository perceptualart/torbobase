// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Multi-Agent Chamber Manager
// Ported from Torbo App RoomManager — rebranded as Chambers.
// Dispatches messages to multiple agents via HTTP with per-agent TTS callbacks.
#if os(macOS)
import Foundation

// MARK: - Discussion Style

enum DiscussionStyle: String, Codable, CaseIterable {
    case sequential     // Agents respond in roster order
    case roundRobin     // Rotating start position
    case random         // Random order each round
    case collaborative  // All agents see all prior responses

    var info: String {
        switch self {
        case .sequential:    return "Agents respond one by one in roster order. Predictable and structured."
        case .roundRobin:    return "Like sequential, but the starting agent rotates each round so no one always goes first."
        case .random:        return "Agents respond in a shuffled order each round. Keeps conversations dynamic."
        case .collaborative: return "Every agent sees all prior responses before replying. Best for brainstorming and deep analysis."
        }
    }
}

// MARK: - Chamber Model

struct Chamber: Codable, Identifiable {
    let id: String
    var name: String
    var agentIDs: [String]          // Ordered roster
    var discussionStyle: DiscussionStyle
    var description: String
    var icon: String
    let createdAt: Date
    var updatedAt: Date

    init(name: String, agentIDs: [String], style: DiscussionStyle = .sequential, description: String = "", icon: String = "person.3.fill") {
        self.id = UUID().uuidString
        self.name = name
        self.agentIDs = agentIDs
        self.discussionStyle = style
        self.description = description
        self.icon = icon
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Chamber Message

struct ChamberMessage: Identifiable {
    let id = UUID()
    let agentID: String
    let agentName: String
    let role: String    // "user" or "assistant"
    var content: String
    let timestamp: Date
    var isStreaming: Bool
}

// MARK: - Chamber Manager

@MainActor
final class ChamberManager: ObservableObject {
    static let shared = ChamberManager()

    @Published var chambers: [Chamber] = []
    @Published var activeChamberID: String?
    @Published var respondingAgentID: String?
    @Published var messages: [ChamberMessage] = []

    private var roundRobinOffset: [String: Int] = [:]
    private let persistenceURL = URL(fileURLWithPath: PlatformPaths.dataDir + "/chambers.json")

    private init() {
        loadChambers()
    }

    // MARK: - CRUD

    func createChamber(name: String, agentIDs: [String], style: DiscussionStyle = .sequential) -> Chamber {
        let chamber = Chamber(name: name, agentIDs: agentIDs, style: style)
        chambers.append(chamber)
        saveChambers()
        return chamber
    }

    func deleteChamber(id: String) {
        chambers.removeAll { $0.id == id }
        if activeChamberID == id { activeChamberID = nil }
        saveChambers()
    }

    func updateDiscussionStyle(chamberID: String, style: DiscussionStyle) {
        guard let idx = chambers.firstIndex(where: { $0.id == chamberID }) else { return }
        chambers[idx].discussionStyle = style
        chambers[idx].updatedAt = Date()
        saveChambers()
    }

    func addAgent(chamberID: String, agentID: String) {
        guard let idx = chambers.firstIndex(where: { $0.id == chamberID }) else { return }
        guard !chambers[idx].agentIDs.contains(agentID) else { return }
        chambers[idx].agentIDs.append(agentID)
        chambers[idx].updatedAt = Date()
        saveChambers()
    }

    func removeAgent(chamberID: String, agentID: String) {
        guard let idx = chambers.firstIndex(where: { $0.id == chamberID }) else { return }
        chambers[idx].agentIDs.removeAll { $0 == agentID }
        chambers[idx].updatedAt = Date()
        saveChambers()
    }

    // MARK: - Send Message

    /// Send a message to the chamber — dispatches to each agent per discussion style.
    /// `onAgentDone` fires after each agent responds (for immediate TTS).
    func sendChamberMessage(
        _ text: String,
        chamberID: String,
        onAgentDone: @escaping (String, String, String) async -> Void  // (agentID, agentName, response)
    ) async {
        guard let chamber = chambers.first(where: { $0.id == chamberID }) else { return }

        // Add user message
        let userMsg = ChamberMessage(agentID: "user", agentName: "You", role: "user", content: text, timestamp: Date(), isStreaming: false)
        messages.append(userMsg)

        // Determine agent order
        let orderedAgents = agentOrder(for: chamber)

        // Build system prompt with roundtable context
        let systemPrompt = chamberSystemPrompt(chamber: chamber)

        // Collect conversation history for collaborative mode
        var conversationContext: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        // Include recent messages (last 20)
        let recentMsgs = messages.suffix(20)
        for msg in recentMsgs {
            let role = msg.role == "user" ? "user" : "assistant"
            let prefix = msg.role == "assistant" ? "[\(msg.agentName)]: " : ""
            conversationContext.append(["role": role, "content": prefix + msg.content])
        }

        // Dispatch to each agent
        for agentID in orderedAgents {
            guard !Task.isCancelled else { break }

            respondingAgentID = agentID
            let agentName = await agentDisplayName(agentID)

            // Add streaming placeholder
            let placeholder = ChamberMessage(agentID: agentID, agentName: agentName, role: "assistant", content: "", timestamp: Date(), isStreaming: true)
            messages.append(placeholder)
            let msgIndex = messages.count - 1

            // HTTP POST to gateway
            let response = await streamAgentResponse(agentID: agentID, messages: conversationContext)

            // Strip self-attribution prefix
            let cleaned = stripSelfAttribution(response, agentName: agentName)

            // Update message
            if msgIndex < messages.count {
                messages[msgIndex].content = cleaned
                messages[msgIndex].isStreaming = false
            }

            // Add to context for collaborative mode
            conversationContext.append(["role": "assistant", "content": "[\(agentName)]: \(cleaned)"])

            // Set respondingAgentID right before TTS so the correct orb lights up
            respondingAgentID = agentID

            // Fire callback — caller awaits TTS finish before next agent starts
            await onAgentDone(agentID, agentName, cleaned)

            // Clear between agents so orbs visually reset before next one lights up
            respondingAgentID = nil

            // Brief pause between agents
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Advance round-robin offset
        if chamber.discussionStyle == .roundRobin {
            let current = roundRobinOffset[chamber.id] ?? 0
            roundRobinOffset[chamber.id] = (current + 1) % max(chamber.agentIDs.count, 1)
        }
    }

    // MARK: - Agent Order

    private func agentOrder(for chamber: Chamber) -> [String] {
        switch chamber.discussionStyle {
        case .sequential, .collaborative:
            return chamber.agentIDs
        case .roundRobin:
            let offset = roundRobinOffset[chamber.id] ?? 0
            let ids = chamber.agentIDs
            return Array(ids[offset...]) + Array(ids[..<offset])
        case .random:
            return chamber.agentIDs.shuffled()
        }
    }

    // MARK: - System Prompt

    private func chamberSystemPrompt(chamber: Chamber) -> String {
        let agentNames = chamber.agentIDs.joined(separator: ", ")
        return """
        [ROUNDTABLE]
        You are in a multi-agent discussion chamber called "\(chamber.name)".
        Participants: \(agentNames)
        Discussion style: \(chamber.discussionStyle.rawValue)

        Rules:
        - NEVER introduce yourself or say your name — your identity is already shown in the UI
        - Jump straight into your response — no "Hi, I'm X" or "As X, I think..."
        - Keep responses concise (2-4 sentences typically)
        - You may reference or build on what other agents said
        - Address other agents by name if responding to them
        - Don't repeat what others already covered
        - Be collaborative, not competitive
        - If you have nothing new to add, say so briefly
        """
    }

    // MARK: - HTTP Streaming

    private func streamAgentResponse(agentID: String, messages: [[String: String]]) async -> String {
        let port = AppState.shared.serverPort
        let token = KeychainManager.serverToken

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return "" }

        let body: [String: Any] = [
            "messages": messages,
            "stream": true
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return "" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")
        request.httpBody = bodyData

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { return "" }

            var accumulated = ""
            for try await line in bytes.lines {
                guard !Task.isCancelled else { break }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }

                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }

                accumulated += content

                // Update streaming message
                let msgIdx = self.messages.count - 1
                if msgIdx >= 0, self.messages[msgIdx].isStreaming {
                    self.messages[msgIdx].content = accumulated
                }
            }
            return accumulated
        } catch {
            TorboLog.error("Chamber stream error for \(agentID): \(error)", subsystem: "Chamber")
            return ""
        }
    }

    // MARK: - Helpers

    private func stripSelfAttribution(_ text: String, agentName: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "[AgentName]: " prefix
        let prefixes = ["\(agentName): ", "[\(agentName)]: ", "\(agentName.lowercased()): "]
        for prefix in prefixes {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        return result
    }

    private func agentDisplayName(_ agentID: String) async -> String {
        let config = await AgentConfigManager.shared.agent(agentID)
        return config?.name ?? agentID.capitalized
    }

    /// Parse @mention from text (returns agentID or nil)
    func parseMention(_ text: String, chamber: Chamber) async -> String? {
        let lower = text.lowercased()
        for agentID in chamber.agentIDs {
            let name = await agentDisplayName(agentID)
            if lower.contains("@\(name.lowercased())") || lower.contains("@\(agentID.lowercased())") {
                return agentID
            }
        }
        return nil
    }

    // MARK: - Persistence

    private func loadChambers() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            chambers = try JSONDecoder().decode([Chamber].self, from: data)
        } catch {
            TorboLog.error("Failed to load chambers: \(error)", subsystem: "Chamber")
        }
    }

    private func saveChambers() {
        do {
            let data = try JSONEncoder().encode(chambers)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            TorboLog.error("Failed to save chambers: \(error)", subsystem: "Chamber")
        }
    }
}
#endif
