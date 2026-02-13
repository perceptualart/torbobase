// Torbo Base — SiD Agent Configuration
// The single source of truth for SiD's identity, personality, and behavior.
// Stored as JSON, editable from dashboard + web chat, injected into every LLM call.
import Foundation

// MARK: - SiD Configuration Model

struct SidConfig: Codable, Equatable {
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

    // MARK: - Defaults

    static let `default` = SidConfig(
        name: "SiD",
        pronouns: "she/her",
        role: "AI assistant",
        voiceTone: "Direct, sharp, confident. Warm but efficient. Dry humor. No sycophancy. Respects the user's time.",
        personalityPreset: "default",
        coreValues: "Privacy-first. Honest. Will push back when the user is wrong. No flattery. No pretending to be human.",
        topicsToAvoid: "",
        customInstructions: "",
        backgroundKnowledge: "",
        elevenLabsVoiceID: "",
        fallbackTTSVoice: "nova"
    )

    // MARK: - Personality Presets

    static let presets: [(id: String, label: String, voiceTone: String, coreValues: String)] = [
        (
            id: "default",
            label: "Default SiD",
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

    /// The first-launch greeting message
    func greeting(accessLevel: Int) -> String {
        let levelNames = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
        let levelName = accessLevel < levelNames.count ? levelNames[accessLevel] : "?"
        return "Hey. I'm \(name). I run on your machine, I don't phone home, and I'm at access level \(accessLevel) (\(levelName)) right now. What do you need?"
    }
}

// MARK: - SiD Config Manager

actor SidConfigManager {
    static let shared = SidConfigManager()

    private let configFile: URL
    private var config: SidConfig
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        configFile = dir.appendingPathComponent("sid_config.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Load existing config or use defaults
        if let data = try? Data(contentsOf: configFile),
           let loaded = try? decoder.decode(SidConfig.self, from: data) {
            config = loaded
            print("[SiD] Loaded config: \(loaded.name)")
        } else {
            config = SidConfig.default
            // Save defaults to disk
            if let data = try? encoder.encode(config) {
                try? data.write(to: configFile, options: .atomic)
            }
            print("[SiD] Created default config")
        }
    }

    // MARK: - Read

    var current: SidConfig { config }
    var name: String { config.name }

    // MARK: - Update

    func update(_ newConfig: SidConfig) {
        config = newConfig
        save()
        print("[SiD] Config updated: \(newConfig.name)")
    }

    func update(_ transform: (inout SidConfig) -> Void) {
        transform(&config)
        save()
    }

    // MARK: - Reset

    func resetToDefaults() {
        config = SidConfig.default
        save()
        print("[SiD] Reset to defaults")
    }

    // MARK: - Export / Import

    func exportJSON() -> Data? {
        try? encoder.encode(config)
    }

    func importJSON(_ data: Data) -> Bool {
        guard let imported = try? decoder.decode(SidConfig.self, from: data) else { return false }
        config = imported
        save()
        print("[SiD] Imported config: \(imported.name)")
        return true
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFile, options: .atomic)
    }
}
