// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Memory System
// MemoryManager.swift — Persistent memory for Sid across all conversations
// Uses local Ollama for extraction (zero cloud cost)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sid's persistent memory — survives across all sessions and context limits.
/// Stored as JSON on disk, extracted by local Ollama after every exchange.
actor MemoryManager {
    static let shared = MemoryManager()

    private let storageDir: URL
    private let identityFile: URL
    private let userFile: URL
    private let knowledgeFile: URL
    private let workingFile: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    // In-memory cache
    private var identity: MemoryIdentity
    private var user: MemoryUser
    private var knowledge: MemoryKnowledge
    private var working: MemoryWorking

    /// Public accessor for the user's display name (first name, or "User" if empty)
    var userDisplayName: String {
        let name = user.name
        if name.isEmpty { return "User" }
        return name.components(separatedBy: " ").first ?? name
    }

    // Extraction queue — don't block the response
    private var extractionTask: Task<Void, Never>?

    init() {
        let appSupport = PlatformPaths.appSupportDir
        storageDir = appSupport.appendingPathComponent("TorboBase/memory", isDirectory: true)
        identityFile = storageDir.appendingPathComponent("identity.json")
        userFile = storageDir.appendingPathComponent("user.json")
        knowledgeFile = storageDir.appendingPathComponent("knowledge.json")
        workingFile = storageDir.appendingPathComponent("working.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Load from disk or create defaults
        identity = Self.load(identityFile, as: MemoryIdentity.self) ?? MemoryIdentity.default
        user = Self.load(userFile, as: MemoryUser.self) ?? MemoryUser.default
        knowledge = Self.load(knowledgeFile, as: MemoryKnowledge.self) ?? MemoryKnowledge.default
        working = Self.load(workingFile, as: MemoryWorking.self) ?? MemoryWorking.default

        let factCount = knowledge.facts.count
        let projCount = knowledge.projects.count
        TorboLog.info("Loaded — \(factCount) facts, \(projCount) projects", subsystem: "Memory")
    }

    // MARK: - System Prompt Assembly

    /// Build the memory block to inject into the system prompt
    func assembleMemoryPrompt() -> String {
        var parts: [String] = []

        // Identity
        parts.append("""
        <identity>
        Name: \(identity.name)
        Personality: \(identity.personality)
        Voice: \(identity.voiceStyle)
        Origin: \(identity.origin)
        </identity>
        """)

        // User knowledge
        if !user.name.isEmpty {
            var userBlock = "<user>\nName: \(user.name)"
            if !user.location.isEmpty { userBlock += "\nLocation: \(user.location)" }
            if !user.timezone.isEmpty { userBlock += "\nTimezone: \(user.timezone)" }
            if !user.occupation.isEmpty { userBlock += "\nWork: \(user.occupation)" }
            if !user.preferences.isEmpty { userBlock += "\nPreferences: \(user.preferences.joined(separator: "; "))" }
            if !user.family.isEmpty { userBlock += "\nFamily: \(user.family.joined(separator: "; "))" }
            userBlock += "\n</user>"
            parts.append(userBlock)
        }

        // Accumulated knowledge
        if !knowledge.facts.isEmpty {
            let recentFacts = knowledge.facts.suffix(50) // Cap at 50 most recent
            parts.append("<knowledge>\n\(recentFacts.map { "• \($0.text)" }.joined(separator: "\n"))\n</knowledge>")
        }

        // Active projects
        if !knowledge.projects.isEmpty {
            let active = knowledge.projects.filter { $0.status == "active" }
            if !active.isEmpty {
                parts.append("<projects>\n\(active.map { "• \($0.name): \($0.summary)" }.joined(separator: "\n"))\n</projects>")
            }
        }

        // Working context
        if !working.currentTopic.isEmpty || !working.recentTopics.isEmpty {
            var ctx = "<context>"
            if !working.currentTopic.isEmpty { ctx += "\nCurrent: \(working.currentTopic)" }
            if !working.recentTopics.isEmpty {
                ctx += "\nRecent: \(working.recentTopics.suffix(5).joined(separator: ", "))"
            }
            if !working.pendingTasks.isEmpty {
                ctx += "\nPending: \(working.pendingTasks.joined(separator: "; "))"
            }
            ctx += "\n</context>"
            parts.append(ctx)
        }

        if parts.isEmpty { return "" }

        return """
        <memory>
        You have persistent memory. These are things you know from past conversations.
        Use this knowledge naturally — don't announce that you're reading memory.
        \(parts.joined(separator: "\n\n"))
        </memory>
        """
    }

    /// Token estimate for memory prompt (rough: 1 token ≈ 4 chars)
    func estimatedTokens() -> Int {
        assembleMemoryPrompt().count / 4
    }

    // MARK: - Memory Extraction (runs after every exchange)

    /// Extract new facts from a conversation exchange using local Ollama.
    /// Runs in the background — never blocks the user's response.
    func extractFromExchange(userMessage: String, assistantResponse: String, model: String) {
        extractionTask?.cancel()
        extractionTask = Task {
            await performExtraction(userMessage: userMessage, assistantResponse: assistantResponse)
        }
    }

    private func performExtraction(userMessage: String, assistantResponse: String) async {
        // Use smallest fast local model for extraction
        let extractionModel = await pickExtractionModel()
        guard let extractionModel else {
            TorboLog.warn("No local model available for extraction", subsystem: "Memory")
            return
        }

        let prompt = """
        Extract facts worth remembering from this conversation exchange.
        Only extract NEW information — things that would be useful to know in future conversations.
        Skip greetings, filler, and things already obvious from context.

        Return ONLY a JSON object with these fields (omit empty arrays):
        {
          "facts": ["fact 1", "fact 2"],
          "user_preferences": ["preference"],
          "projects": [{"name": "X", "summary": "Y", "status": "active"}],
          "current_topic": "what they're working on right now",
          "pending_tasks": ["task 1"]
        }

        If there's nothing worth extracting, return: {"facts": []}

        USER: \(userMessage.prefix(2000))
        ASSISTANT: \(assistantResponse.prefix(2000))
        """

        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": extractionModel,
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.1, "num_predict": 512]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                TorboLog.error("Extraction failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)", subsystem: "Memory")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return }

            // Parse the extracted JSON
            guard let extractedData = response.data(using: .utf8),
                  let extracted = try? JSONSerialization.jsonObject(with: extractedData) as? [String: Any] else {
                TorboLog.error("Could not parse extraction response", subsystem: "Memory")
                return
            }

            await applyExtraction(extracted)
        } catch {
            TorboLog.error("Extraction error: \(error.localizedDescription)", subsystem: "Memory")
        }
    }

    private func applyExtraction(_ extracted: [String: Any]) async {
        let now = Date()
        var changed = false

        // New facts
        if let facts = extracted["facts"] as? [String] {
            for fact in facts where !fact.isEmpty {
                // Deduplicate — skip if we already know something very similar
                let dominated = knowledge.facts.contains { existing in
                    existing.text.lowercased() == fact.lowercased() ||
                    existing.text.lowercased().contains(fact.lowercased()) ||
                    fact.lowercased().contains(existing.text.lowercased())
                }
                if !dominated {
                    knowledge.facts.append(MemoryFact(text: fact, learnedAt: now, source: "conversation"))
                    changed = true
                }
            }
        }

        // User preferences
        if let prefs = extracted["user_preferences"] as? [String] {
            for pref in prefs where !pref.isEmpty && !user.preferences.contains(pref) {
                user.preferences.append(pref)
                changed = true
            }
        }

        // Projects
        if let projects = extracted["projects"] as? [[String: Any]] {
            for proj in projects {
                guard let name = proj["name"] as? String, !name.isEmpty else { continue }
                let summary = proj["summary"] as? String ?? ""
                let status = proj["status"] as? String ?? "active"
                if let idx = knowledge.projects.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    // Update existing
                    if !summary.isEmpty { knowledge.projects[idx].summary = summary }
                    knowledge.projects[idx].status = status
                    knowledge.projects[idx].lastMentioned = now
                } else {
                    knowledge.projects.append(MemoryProject(name: name, summary: summary, status: status, lastMentioned: now))
                }
                changed = true
            }
        }

        // Working context
        if let topic = extracted["current_topic"] as? String, !topic.isEmpty {
            working.currentTopic = topic
            if !working.recentTopics.contains(topic) {
                working.recentTopics.append(topic)
                if working.recentTopics.count > 20 { working.recentTopics.removeFirst() }
            }
            working.lastUpdated = now
            changed = true
        }

        if let tasks = extracted["pending_tasks"] as? [String] {
            for task in tasks where !task.isEmpty && !working.pendingTasks.contains(task) {
                working.pendingTasks.append(task)
                changed = true
            }
        }

        if changed {
            // Cap facts at 200 — drop oldest
            if knowledge.facts.count > 200 {
                knowledge.facts = Array(knowledge.facts.suffix(200))
            }
            save()
            TorboLog.info("Updated — \(knowledge.facts.count) facts, \(knowledge.projects.count) projects", subsystem: "Memory")
        }
    }

    /// Pick the best available local model for memory extraction
    private func pickExtractionModel() async -> String? {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/tags") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return nil }
            let names = models.compactMap { $0["name"] as? String }

            // Prefer small fast models for extraction
            let preferred = ["qwen2.5:7b", "qwen2.5:3b", "qwen2.5:14b", "llama3.2:3b", "llama3.1:8b", "phi3:mini", "gemma2:2b"]
            for model in preferred {
                if names.contains(where: { $0.hasPrefix(model.components(separatedBy: ":")[0]) }) {
                    let match = names.first { $0.hasPrefix(model.components(separatedBy: ":")[0]) }
                    if let match { return match }
                }
            }
            // Fallback to whatever's available
            return names.first
        } catch { return nil }
    }

    // MARK: - Direct Memory Updates (from API)

    func updateIdentity(_ updates: [String: String]) {
        if let v = updates["name"] { identity.name = v }
        if let v = updates["personality"] { identity.personality = v }
        if let v = updates["voiceStyle"] { identity.voiceStyle = v }
        if let v = updates["origin"] { identity.origin = v }
        save()
    }

    func updateUser(_ updates: [String: Any]) {
        if let v = updates["name"] as? String { user.name = v }
        if let v = updates["location"] as? String { user.location = v }
        if let v = updates["timezone"] as? String { user.timezone = v }
        if let v = updates["occupation"] as? String { user.occupation = v }
        if let v = updates["preferences"] as? [String] { user.preferences = v }
        if let v = updates["family"] as? [String] { user.family = v }
        save()
    }

    func addFact(_ text: String, source: String = "manual") {
        knowledge.facts.append(MemoryFact(text: text, learnedAt: Date(), source: source))
        if knowledge.facts.count > 200 { knowledge.facts.removeFirst() }
        save()
    }

    func removeFact(containing text: String) {
        knowledge.facts.removeAll { $0.text.localizedCaseInsensitiveContains(text) }
        save()
    }

    func clearWorkingContext() {
        working = MemoryWorking.default
        save()
    }

    func completePendingTask(_ task: String) {
        working.pendingTasks.removeAll { $0.localizedCaseInsensitiveContains(task) }
        save()
    }

    // MARK: - Full Memory Dump (for API)

    func fullDump() -> [String: Any] {
        var result: [String: Any] = [:]
        if let data = try? encoder.encode(identity), let json = try? JSONSerialization.jsonObject(with: data) { result["identity"] = json }
        if let data = try? encoder.encode(user), let json = try? JSONSerialization.jsonObject(with: data) { result["user"] = json }
        if let data = try? encoder.encode(knowledge), let json = try? JSONSerialization.jsonObject(with: data) { result["knowledge"] = json }
        if let data = try? encoder.encode(working), let json = try? JSONSerialization.jsonObject(with: data) { result["working"] = json }
        result["stats"] = [
            "factCount": knowledge.facts.count,
            "projectCount": knowledge.projects.count,
            "estimatedTokens": assembleMemoryPrompt().count / 4
        ]
        return result
    }

    // MARK: - Persistence

    private func save() {
        save(identity, to: identityFile)
        save(user, to: userFile)
        save(knowledge, to: knowledgeFile)
        save(working, to: workingFile)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            TorboLog.error("Failed to save \(url.lastPathComponent): \(error)", subsystem: "Memory")
        }
    }

    private static func load<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601Decoder.decode(type, from: data)
    }

    // MARK: - Compression (periodic maintenance)

    /// Compress old facts into summaries to keep memory lean.
    /// Call this periodically (e.g., daily or when facts > 150).
    func compressIfNeeded() async {
        guard knowledge.facts.count > 150 else { return }

        let extractionModel = await pickExtractionModel()
        guard let extractionModel else { return }

        // Take the oldest 100 facts and compress into ~20
        let oldFacts = Array(knowledge.facts.prefix(100))
        let factTexts = oldFacts.map { $0.text }.joined(separator: "\n")

        let prompt = """
        Compress these \(oldFacts.count) facts into the 20 most important ones.
        Merge related facts. Drop anything trivial or outdated.
        Return ONLY a JSON array of strings: ["fact 1", "fact 2", ...]

        FACTS:
        \(factTexts)
        """

        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": extractionModel, "prompt": prompt, "stream": false, "format": "json", "options": ["temperature": 0.1]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String,
                  let parsed = response.data(using: .utf8),
                  let compressed = try? JSONSerialization.jsonObject(with: parsed) as? [String] else { return }

            // Replace old facts with compressed versions, keep newer facts
            let newerFacts = Array(knowledge.facts.dropFirst(100))
            knowledge.facts = compressed.map { MemoryFact(text: $0, learnedAt: Date(), source: "compressed") } + newerFacts
            save()
            TorboLog.info("Compressed \(oldFacts.count) facts → \(compressed.count)", subsystem: "Memory")
        } catch {
            TorboLog.error("Compression error: \(error)", subsystem: "Memory")
        }
    }
}

// MARK: - Memory Models

struct MemoryIdentity: Codable {
    var name: String
    var personality: String
    var voiceStyle: String
    var origin: String

    static let `default` = MemoryIdentity(
        name: "Sid",
        personality: "Direct, resourceful. Not a corporate drone. Has opinions. Skip performative helpfulness — just help. Concise by default, thorough when it matters.",
        voiceStyle: "Short sentences, no filler words. 'Yeah. Done. Next?' not 'Certainly! I've completed that task!'",
        origin: ""
    )
}

struct MemoryUser: Codable {
    var name: String
    var location: String
    var timezone: String
    var occupation: String
    var preferences: [String]
    var family: [String]

    static let `default` = MemoryUser(
        name: "",
        location: "",
        timezone: TimeZone.current.identifier,
        occupation: "",
        preferences: [],
        family: []
    )
}

struct MemoryFact: Codable {
    var text: String
    var learnedAt: Date
    var source: String // "conversation", "manual", "compressed"
}

struct MemoryProject: Codable {
    var name: String
    var summary: String
    var status: String // "active", "completed", "paused"
    var lastMentioned: Date
}

struct MemoryKnowledge: Codable {
    var facts: [MemoryFact]
    var projects: [MemoryProject]

    static let `default` = MemoryKnowledge(
        facts: [],
        projects: [
            MemoryProject(name: "Torbo Base", summary: "macOS gateway server — routes LLM requests, manages API keys, runs Ollama", status: "active", lastMentioned: Date()),
        ]
    )
}

struct MemoryWorking: Codable {
    var currentTopic: String
    var recentTopics: [String]
    var pendingTasks: [String]
    var lastUpdated: Date

    static let `default` = MemoryWorking(
        currentTopic: "",
        recentTopics: [],
        pendingTasks: [],
        lastUpdated: Date()
    )
}

// MARK: - JSON Decoder Extension

extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
