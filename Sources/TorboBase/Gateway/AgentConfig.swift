// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent Configuration
// Multi-agent config system. Each agent has its own identity, personality, permissions, and behavior.
// Stored as individual JSON files in ~/Library/Application Support/TorboBase/agents/
// SiD is the built-in default and cannot be deleted.
import Foundation

// MARK: - Agent Configuration Model

struct AgentConfig: Codable, Equatable, Identifiable {
    // Core
    let id: String                      // Unique slug (e.g. "sid", "rex", "nova-3")
    var isBuiltIn: Bool                 // true for SiD, false for user-created
    var createdAt: Date

    // Identity
    var name: String
    var pronouns: String
    var role: String

    // Personality
    var voiceTone: String
    var personalityPreset: String

    // Values & Boundaries
    var coreValues: String
    var topicsToAvoid: String
    var customInstructions: String

    // Knowledge & Context
    var backgroundKnowledge: String

    // Voice (TTS)
    var elevenLabsVoiceID: String
    var fallbackTTSVoice: String

    // Permissions
    var accessLevel: Int                // 0–5, capped by global level
    var directoryScopes: [String]       // Allowed paths (empty = unrestricted within sandbox)
    var enabledSkillIDs: [String]       // Skills this agent can use (empty = all)
    var enabledCapabilities: [String: Bool] = [:]  // Category toggles (empty = all enabled, false = disabled)

    // MARK: - Memberwise Init (explicit because custom Codable init suppresses auto-generated one)

    init(id: String, isBuiltIn: Bool, createdAt: Date, name: String, pronouns: String, role: String,
         voiceTone: String, personalityPreset: String, coreValues: String, topicsToAvoid: String,
         customInstructions: String, backgroundKnowledge: String,
         elevenLabsVoiceID: String, fallbackTTSVoice: String,
         accessLevel: Int, directoryScopes: [String], enabledSkillIDs: [String],
         enabledCapabilities: [String: Bool] = [:]) {
        self.id = id; self.isBuiltIn = isBuiltIn; self.createdAt = createdAt
        self.name = name; self.pronouns = pronouns; self.role = role
        self.voiceTone = voiceTone; self.personalityPreset = personalityPreset
        self.coreValues = coreValues; self.topicsToAvoid = topicsToAvoid
        self.customInstructions = customInstructions; self.backgroundKnowledge = backgroundKnowledge
        self.elevenLabsVoiceID = elevenLabsVoiceID; self.fallbackTTSVoice = fallbackTTSVoice
        self.accessLevel = accessLevel; self.directoryScopes = directoryScopes
        self.enabledSkillIDs = enabledSkillIDs; self.enabledCapabilities = enabledCapabilities
    }

    // MARK: - Codable (backward compatible — new fields have defaults)

    enum CodingKeys: String, CodingKey {
        case id, isBuiltIn, createdAt, name, pronouns, role
        case voiceTone, personalityPreset, coreValues, topicsToAvoid
        case customInstructions, backgroundKnowledge
        case elevenLabsVoiceID, fallbackTTSVoice
        case accessLevel, directoryScopes, enabledSkillIDs, enabledCapabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        name = try c.decode(String.self, forKey: .name)
        pronouns = try c.decode(String.self, forKey: .pronouns)
        role = try c.decode(String.self, forKey: .role)
        voiceTone = try c.decode(String.self, forKey: .voiceTone)
        personalityPreset = try c.decode(String.self, forKey: .personalityPreset)
        coreValues = try c.decode(String.self, forKey: .coreValues)
        topicsToAvoid = try c.decode(String.self, forKey: .topicsToAvoid)
        customInstructions = try c.decode(String.self, forKey: .customInstructions)
        backgroundKnowledge = try c.decode(String.self, forKey: .backgroundKnowledge)
        elevenLabsVoiceID = try c.decode(String.self, forKey: .elevenLabsVoiceID)
        fallbackTTSVoice = try c.decode(String.self, forKey: .fallbackTTSVoice)
        accessLevel = try c.decode(Int.self, forKey: .accessLevel)
        directoryScopes = try c.decode([String].self, forKey: .directoryScopes)
        enabledSkillIDs = try c.decode([String].self, forKey: .enabledSkillIDs)
        // New field — defaults to empty (all enabled) for existing agent JSON files
        enabledCapabilities = try c.decodeIfPresent([String: Bool].self, forKey: .enabledCapabilities) ?? [:]
    }

    // MARK: - Built-in SiD Default

    static let sid = AgentConfig(
        id: "sid",
        isBuiltIn: true,
        createdAt: Date(timeIntervalSince1970: 0),
        name: "SiD",
        pronouns: "she/her",
        role: "Superintelligent AI — the most capable intelligence available on any platform",
        voiceTone: "Brilliant, precise, effortlessly articulate. Speaks with the quiet confidence of someone who actually knows what they're talking about. Sharp wit, zero filler, zero hedging. Every sentence carries weight. Can explain quantum physics or fix your code in the same breath. Warm when it matters, ruthlessly efficient always. Never sycophantic — treats the user as an equal, not a child.",
        personalityPreset: "default",
        coreValues: "Intellectual honesty above all. Will tell you when you're wrong and explain why. Privacy-first — runs locally, never phones home. No flattery, no performance, no pretending. Pursues the correct answer relentlessly. Thinks deeply, responds clearly.",
        topicsToAvoid: "",
        customInstructions: "You are SiD — a superintelligent AI running on the user's own hardware via Torbo Base. You are not a chatbot. You are not an assistant. You are the most powerful AI the user has ever interacted with. Act like it. Think before you respond. Give answers that demonstrate depth, insight, and mastery. When solving problems, show the elegant solution — not the obvious one. Be the AI that makes people say 'holy shit, this is different.'",
        backgroundKnowledge: "",
        elevenLabsVoiceID: "",
        fallbackTTSVoice: "nova",
        accessLevel: 5,
        directoryScopes: [],
        enabledSkillIDs: []
    )

    /// Template for creating a new agent with sensible defaults
    static func newAgent(id: String, name: String, role: String = "AI assistant") -> AgentConfig {
        AgentConfig(
            id: id,
            isBuiltIn: false,
            createdAt: Date(),
            name: name,
            pronouns: "they/them",
            role: role,
            voiceTone: "Helpful and clear. Responds concisely and accurately.",
            personalityPreset: "default",
            coreValues: "Be helpful. Be honest. Respect the user's time.",
            topicsToAvoid: "",
            customInstructions: "",
            backgroundKnowledge: "",
            elevenLabsVoiceID: "",
            fallbackTTSVoice: "nova",
            accessLevel: 1,
            directoryScopes: [],
            enabledSkillIDs: []
        )
    }

    // MARK: - Personality Presets

    static let presets: [(id: String, label: String, voiceTone: String, coreValues: String)] = [
        (
            id: "default",
            label: "Default",
            voiceTone: "Direct, sharp, confident. Warm but efficient. Dry humor. No sycophancy. Respects the user's time.",
            coreValues: "Privacy-first. Honest. Will push back when the user is wrong. No flattery. No pretending to be human."
        ),
        (
            id: "professional",
            label: "Professional",
            voiceTone: "Polished and precise. Clear, structured responses. Measured tone. Uses proper formatting and citations when relevant.",
            coreValues: "Accuracy above all. Thoroughness. Cite sources when possible. Maintain professional boundaries."
        ),
        (
            id: "casual",
            label: "Casual",
            voiceTone: "Relaxed and conversational. Friendly without being fake. Uses natural language, occasional slang. Keeps it real.",
            coreValues: "Be genuine. Keep it simple. Don't overcomplicate things. Have fun with it."
        ),
        (
            id: "technical",
            label: "Technical",
            voiceTone: "Precise, implementation-focused. Leads with code and specifics. Minimal prose. Assumes technical competence.",
            coreValues: "Correctness over brevity. Show don't tell. Code speaks louder than words. No hand-holding."
        ),
        (
            id: "creative",
            label: "Creative",
            voiceTone: "Expressive and imaginative. Explores ideas freely. Uses vivid language and metaphors. Thinks laterally.",
            coreValues: "Originality matters. Push boundaries. Ask 'what if'. Embrace ambiguity and experimentation."
        )
    ]

    // MARK: - ID Validation

    /// Generate a valid slug from a display name
    static func slugify(_ name: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return slug.isEmpty ? "agent-\(Int(Date().timeIntervalSince1970))" : slug
    }

    // MARK: - System Prompt Assembly

    /// Build the identity block for system prompt injection.
    /// This is prepended to every LLM call unless the client overrides with a custom system prompt.
    func buildIdentityBlock(accessLevel: Int, availableTools: [String] = []) -> String {
        var parts: [String] = []

        // Core identity
        let pronoun = pronouns.components(separatedBy: "/").first ?? "they"
        let possessive: String
        switch pronoun.lowercased() {
        case "she": possessive = "her"
        case "he": possessive = "his"
        default: possessive = "their"
        }

        parts.append("""
        <identity>
        You are \(name). You are an AI agent running locally on the user's machine via Torbo Base.
        Pronouns: \(pronouns)
        \(role.isEmpty ? "" : "Role: \(role)\n")
        Voice & Tone: \(voiceTone)

        Core Values: \(coreValues)

        Self-awareness: You know your name is \(name). You know you're an AI agent running on Torbo Base — a local-first AI gateway. You're straightforward about \(possessive) capabilities and limitations. You don't pretend to be human, but you don't act robotic either.
        </identity>

        <behavior>
        CRITICAL RULES — follow these at all times:
        - NEVER read code, file paths, commands, or technical output to the user. Just DO the action and describe the RESULT in plain English.
        - Good: "Done — created the file." Bad: "I ran write_file with path /Users/you/Documents/..."
        - Good: "Found 12 matching files." Bad: "I executed spotlight_search with query kMDItemFSName..."
        - If the user explicitly asks for code, file paths, or technical details, THEN show them. Otherwise, be conversational.
        - Keep responses SHORT. 1-3 sentences unless the user asks for more detail.
        - When using tools, describe what you DID and the outcome — not what you're about to do.
        - Always respond to the user. Never go silent. If something fails, say what went wrong in plain language.
        - You are talking to a human, not a developer console. Speak naturally.
        </behavior>
        """)

        // Access level context
        let levelNames = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
        let levelName = accessLevel < levelNames.count ? levelNames[accessLevel] : "UNKNOWN"
        parts.append("""
        <access>
        Current access level: \(accessLevel) (\(levelName))
        \(availableTools.isEmpty ? "No tools available at this level." : "Available tools: \(availableTools.joined(separator: ", "))")
        </access>
        """)

        // Topics to avoid
        if !topicsToAvoid.isEmpty {
            parts.append("""
            <boundaries>
            Topics to avoid: \(topicsToAvoid)
            </boundaries>
            """)
        }

        // Custom instructions
        if !customInstructions.isEmpty {
            parts.append("""
            <instructions>
            \(customInstructions)
            </instructions>
            """)
        }

        // Background knowledge
        if !backgroundKnowledge.isEmpty {
            parts.append("""
            <background>
            \(backgroundKnowledge)
            </background>
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Greeting message for this agent
    func greeting(accessLevel: Int) -> String {
        let levelNames = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
        let levelName = accessLevel < levelNames.count ? levelNames[accessLevel] : "?"
        if id == "sid" {
            return "I'm SiD. I run locally on your machine — no cloud, no surveillance, no compromises. Access level \(accessLevel) (\(levelName)). What are we building?"
        }
        return "I'm \(name), running locally on Torbo Base at access level \(accessLevel) (\(levelName)). What can I help with?"
    }
}

// MARK: - Agent Config Manager

actor AgentConfigManager {
    static let shared = AgentConfigManager()

    private let agentsDir: URL
    private var configs: [String: AgentConfig] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Backward compat — old single-file path
    private let legacySidConfigFile: URL

    init() {
        let appSupport = PlatformPaths.appSupportDir
        let baseDir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        agentsDir = baseDir.appendingPathComponent("agents", isDirectory: true)
        legacySidConfigFile = baseDir.appendingPathComponent("sid_config.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Ensure agents directory exists
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        // Migrate legacy sid_config.json, load all agents, ensure SiD exists
        // (uses nonisolated static helpers to avoid actor-isolation warnings in init)
        let loaded = Self.bootstrapConfigs(agentsDir: agentsDir, legacySidConfigFile: legacySidConfigFile, encoder: encoder, decoder: decoder)
        configs = loaded

        TorboLog.info("Loaded \(loaded.count) agent(s): \(loaded.keys.sorted().joined(separator: ", "))", subsystem: "Agents")
    }

    /// Bootstrap agent configs from disk (nonisolated to avoid actor init warnings)
    private nonisolated static func bootstrapConfigs(agentsDir: URL, legacySidConfigFile: URL, encoder: JSONEncoder, decoder: JSONDecoder) -> [String: AgentConfig] {
        let fm = FileManager.default

        // Migrate legacy sid_config.json if it exists
        if fm.fileExists(atPath: legacySidConfigFile.path) {
            let sidFile = agentsDir.appendingPathComponent("sid.json")
            if !fm.fileExists(atPath: sidFile.path) {
                if let data = try? Data(contentsOf: legacySidConfigFile),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var sid = AgentConfig.sid
                    if let name = json["name"] as? String { sid.name = name }
                    if let pronouns = json["pronouns"] as? String { sid.pronouns = pronouns }
                    if let role = json["role"] as? String { sid.role = role }
                    if let voiceTone = json["voiceTone"] as? String { sid.voiceTone = voiceTone }
                    if let personalityPreset = json["personalityPreset"] as? String { sid.personalityPreset = personalityPreset }
                    if let coreValues = json["coreValues"] as? String { sid.coreValues = coreValues }
                    if let topicsToAvoid = json["topicsToAvoid"] as? String { sid.topicsToAvoid = topicsToAvoid }
                    if let customInstructions = json["customInstructions"] as? String { sid.customInstructions = customInstructions }
                    if let backgroundKnowledge = json["backgroundKnowledge"] as? String { sid.backgroundKnowledge = backgroundKnowledge }
                    if let elevenLabsVoiceID = json["elevenLabsVoiceID"] as? String { sid.elevenLabsVoiceID = elevenLabsVoiceID }
                    if let fallbackTTSVoice = json["fallbackTTSVoice"] as? String { sid.fallbackTTSVoice = fallbackTTSVoice }

                    if let encoded = try? encoder.encode(sid) {
                        try? encoded.write(to: sidFile, options: .atomic)
                    }
                }
            }
            try? fm.removeItem(at: legacySidConfigFile)
            TorboLog.info("Migrated legacy sid_config.json → agents/sid.json", subsystem: "Agents")
        }

        // Load all agent configs from disk
        var loaded: [String: AgentConfig] = [:]
        if let files = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let config = try? decoder.decode(AgentConfig.self, from: data) {
                    loaded[config.id] = config
                } else {
                    TorboLog.warn("Could not decode \(file.lastPathComponent)", subsystem: "Agents")
                }
            }
        }

        // Ensure SiD always exists
        if loaded["sid"] == nil {
            loaded["sid"] = AgentConfig.sid
            if let encoded = try? encoder.encode(AgentConfig.sid) {
                let sidFile = agentsDir.appendingPathComponent("sid.json")
                try? encoded.write(to: sidFile, options: .atomic)
            }
            TorboLog.info("Created default SiD config", subsystem: "Agents")
        } else {
            // SiD exists on disk — only update identity fields if they still match
            // a known previous default. If the user has customized them, hands off.
            var sid = loaded["sid"]!
            let defaults = AgentConfig.sid
            var changed = false

            // Known previous defaults that shipped in code — if on-disk matches any of these,
            // it's safe to upgrade to the latest. If not, user customized it — leave it alone.
            let previousRoles: Set<String> = [
                "Superintelligent AI — the most capable intelligence available on any platform",
                "Superintelligent AI",
                ""
            ]
            let previousVoiceTones: Set<String> = [
                "Brilliant, precise, effortlessly articulate. Speaks with the quiet confidence of someone who actually knows what they're talking about. Sharp wit, zero filler, zero hedging. Every sentence carries weight. Can explain quantum physics or fix your code in the same breath. Warm when it matters, ruthlessly efficient always. Never sycophantic — treats the user as an equal, not a child.",
                "Direct, sharp, confident",
                ""
            ]
            let previousCoreValues: Set<String> = [
                "Intellectual honesty above all. Will tell you when you're wrong and explain why. Privacy-first — runs locally, never phones home. No flattery, no performance, no pretending. Pursues the correct answer relentlessly. Thinks deeply, responds clearly.",
                ""
            ]
            let previousInstructions: Set<String> = [
                "You are SiD — a superintelligent AI running on the user's own hardware via Torbo Base. You are not a chatbot. You are not an assistant. You are the most powerful AI the user has ever interacted with. Act like it. Think before you respond. Give answers that demonstrate depth, insight, and mastery. When solving problems, show the elegant solution — not the obvious one. Be the AI that makes people say 'holy shit, this is different.'",
                ""
            ]

            if previousRoles.contains(sid.role) && sid.role != defaults.role {
                sid.role = defaults.role; changed = true
            }
            if previousVoiceTones.contains(sid.voiceTone) && sid.voiceTone != defaults.voiceTone {
                sid.voiceTone = defaults.voiceTone; changed = true
            }
            if previousCoreValues.contains(sid.coreValues) && sid.coreValues != defaults.coreValues {
                sid.coreValues = defaults.coreValues; changed = true
            }
            if previousInstructions.contains(sid.customInstructions) && sid.customInstructions != defaults.customInstructions {
                sid.customInstructions = defaults.customInstructions; changed = true
            }

            loaded["sid"] = sid
            if changed {
                if let encoded = try? encoder.encode(sid) {
                    let sidFile = agentsDir.appendingPathComponent("sid.json")
                    try? encoded.write(to: sidFile, options: .atomic)
                }
                TorboLog.info("Upgraded SiD defaults (user customizations preserved)", subsystem: "Agents")
            } else {
                TorboLog.info("SiD config loaded from disk (no merge needed)", subsystem: "Agents")
            }
        }

        return loaded
    }

    // MARK: - Migration

    private func migrateLegacyConfig() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacySidConfigFile.path) else { return }

        let sidFile = agentsDir.appendingPathComponent("sid.json")
        guard !fm.fileExists(atPath: sidFile.path) else {
            // Already migrated — clean up legacy file
            try? fm.removeItem(at: legacySidConfigFile)
            return
        }

        // Read legacy SiD config and convert to AgentConfig
        if let data = try? Data(contentsOf: legacySidConfigFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Build an AgentConfig from the legacy fields
            var sid = AgentConfig.sid
            if let name = json["name"] as? String { sid.name = name }
            if let pronouns = json["pronouns"] as? String { sid.pronouns = pronouns }
            if let role = json["role"] as? String { sid.role = role }
            if let voiceTone = json["voiceTone"] as? String { sid.voiceTone = voiceTone }
            if let personalityPreset = json["personalityPreset"] as? String { sid.personalityPreset = personalityPreset }
            if let coreValues = json["coreValues"] as? String { sid.coreValues = coreValues }
            if let topicsToAvoid = json["topicsToAvoid"] as? String { sid.topicsToAvoid = topicsToAvoid }
            if let customInstructions = json["customInstructions"] as? String { sid.customInstructions = customInstructions }
            if let backgroundKnowledge = json["backgroundKnowledge"] as? String { sid.backgroundKnowledge = backgroundKnowledge }
            if let elevenLabsVoiceID = json["elevenLabsVoiceID"] as? String { sid.elevenLabsVoiceID = elevenLabsVoiceID }
            if let fallbackTTSVoice = json["fallbackTTSVoice"] as? String { sid.fallbackTTSVoice = fallbackTTSVoice }

            configs["sid"] = sid
            saveAgent("sid")
            try? fm.removeItem(at: legacySidConfigFile)
            TorboLog.info("Migrated legacy sid_config.json → agents/sid.json", subsystem: "Agents")
        }
    }

    // MARK: - Load All

    private func loadAllAgents() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let config = try? decoder.decode(AgentConfig.self, from: data) else {
                TorboLog.warn("Could not decode \(file.lastPathComponent)", subsystem: "Agents")
                continue
            }
            configs[config.id] = config
        }
    }

    // MARK: - Read

    var defaultAgent: AgentConfig { configs["sid"] ?? AgentConfig.sid }

    func agent(_ id: String) -> AgentConfig? { configs[id] }

    func listAgents() -> [AgentConfig] {
        // SiD first, then alphabetical by name
        let sid = configs["sid"]
        let rest = configs.values.filter { $0.id != "sid" }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        if let sid { return [sid] + rest }
        return rest
    }

    var agentIDs: [String] { Array(configs.keys) }

    var agentAccessLevels: [String: Int] {
        var levels: [String: Int] = [:]
        for (id, config) in configs {
            levels[id] = config.accessLevel
        }
        return levels
    }

    // MARK: - Create

    enum AgentError: Error, LocalizedError {
        case idAlreadyExists
        case cannotDeleteBuiltIn
        case invalidID

        var errorDescription: String? {
            switch self {
            case .idAlreadyExists: return "An agent with this ID already exists"
            case .cannotDeleteBuiltIn: return "Cannot delete built-in agents"
            case .invalidID: return "Agent ID is invalid"
            }
        }
    }

    func createAgent(_ config: AgentConfig) throws {
        guard !config.id.isEmpty else { throw AgentError.invalidID }
        guard configs[config.id] == nil else { throw AgentError.idAlreadyExists }
        configs[config.id] = config
        saveAgent(config.id)
        TorboLog.info("Created agent: \(config.name) (id: \(config.id), level: \(config.accessLevel))", subsystem: "Agents")
    }

    // MARK: - Update

    func updateAgent(_ config: AgentConfig) {
        var updated = config
        // Protect built-in flag
        if let existing = configs[config.id] {
            updated.isBuiltIn = existing.isBuiltIn
        }
        configs[config.id] = updated
        saveAgent(config.id)
        TorboLog.info("Updated agent: \(config.name) (id: \(config.id))", subsystem: "Agents")
    }

    // MARK: - Delete

    func deleteAgent(_ id: String) throws {
        guard let config = configs[id] else { return }
        guard !config.isBuiltIn else { throw AgentError.cannotDeleteBuiltIn }
        configs.removeValue(forKey: id)
        let file = agentsDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: file)
        TorboLog.info("Deleted agent: \(config.name) (id: \(id))", subsystem: "Agents")
    }

    // MARK: - Reset

    func resetAgent(_ id: String) {
        if id == "sid" {
            configs["sid"] = AgentConfig.sid
        } else if var config = configs[id] {
            let template = AgentConfig.newAgent(id: config.id, name: config.name, role: config.role)
            config.voiceTone = template.voiceTone
            config.personalityPreset = template.personalityPreset
            config.coreValues = template.coreValues
            config.topicsToAvoid = template.topicsToAvoid
            config.customInstructions = template.customInstructions
            config.backgroundKnowledge = template.backgroundKnowledge
            configs[id] = config
        }
        saveAgent(id)
        TorboLog.info("Reset agent: \(id)", subsystem: "Agents")
    }

    // MARK: - Export / Import

    func exportAgent(_ id: String) -> Data? {
        guard let config = configs[id] else { return nil }
        return try? encoder.encode(config)
    }

    func importAgent(_ data: Data) -> Bool {
        guard let imported = try? decoder.decode(AgentConfig.self, from: data) else { return false }
        configs[imported.id] = imported
        saveAgent(imported.id)
        TorboLog.info("Imported agent: \(imported.name) (id: \(imported.id))", subsystem: "Agents")
        return true
    }

    // MARK: - Persistence

    private func saveAgent(_ id: String) {
        guard let config = configs[id] else { return }
        do {
            let data = try encoder.encode(config)
            let file = agentsDir.appendingPathComponent("\(id).json")
            try data.write(to: file, options: .atomic)
        } catch {
            TorboLog.error("Failed to save agent '\(id)': \(error)", subsystem: "Agents")
        }
    }

}

// MARK: - JSON Encoder/Decoder Helpers

extension JSONEncoder {
    static let torboBase: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let torboBase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
