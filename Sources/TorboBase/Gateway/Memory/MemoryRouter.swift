// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Memory Router
// Intercepts every message, retrieves relevant memories, injects into context,
// and triggers memory extraction after responses.
import Foundation

/// The Memory Router sits between incoming chat requests and the LLM.
/// It handles the full memory lifecycle:
///   1. BEFORE: Retrieve relevant memories → inject into system prompt
///   2. AFTER: Extract new memories from the exchange → index them
///
/// This is the brain of the memory system. MemoryIndex is the storage,
/// MemoryArmy has the workers, MemoryRouter orchestrates everything.
actor MemoryRouter {
    static let shared = MemoryRouter()

    // Configurable service references (global .shared by default, per-user for cloud)
    let memoryArmy: MemoryArmy
    let memoryIndex: MemoryIndex
    let agentConfigManager: AgentConfigManager

    private var isReady = false

    // Agent identity is loaded from AgentConfigManager at request time.
    // No hardcoded personality here — it's all in agents/{id}.json.

    init() {
        memoryArmy = .shared
        memoryIndex = .shared
        agentConfigManager = .shared
    }

    /// Per-user initializer for cloud multi-tenant isolation
    init(memoryArmy: MemoryArmy, memoryIndex: MemoryIndex, agentConfigManager: AgentConfigManager) {
        self.memoryArmy = memoryArmy
        self.memoryIndex = memoryIndex
        self.agentConfigManager = agentConfigManager
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }
        await memoryArmy.start()
        isReady = true
        TorboLog.info("Initialized and ready", subsystem: "MemoryRouter")
    }

    /// Lightweight initialize for per-user cloud instances
    func initializeForUser() async {
        guard !isReady else { return }
        await memoryArmy.startForUser()
        isReady = true
    }

    // MARK: - Pre-Request: Inject Memories into System Prompt

    /// Process an incoming chat request body BEFORE it hits the LLM.
    /// Builds the full system prompt: agent identity → access context → memory → user context → tools.
    /// If the client already provided a system message, the agent's identity is NOT injected (API override).
    /// - Parameters:
    ///   - body: The chat request body (modified in place)
    ///   - accessLevel: Current access level (for identity block)
    ///   - toolNames: Names of available tools at this access level
    ///   - clientProvidedSystem: Whether the original request had a system message (API override)
    ///   - agentID: Which agent is handling this request (loads per-agent identity)
    func enrichRequest(_ body: inout [String: Any], accessLevel: Int = 1, toolNames: [String] = [], clientProvidedSystem: Bool = false, agentID: String = "sid", platform: String? = nil) async {
        guard isReady else { return }

        var messages = body["messages"] as? [[String: Any]] ?? []
        guard !messages.isEmpty else { return }

        // Find the latest user message for memory search
        let userMessage = messages.last(where: { $0["role"] as? String == "user" })
        let userContent = extractText(from: userMessage?["content"])
        guard !userContent.isEmpty else { return }

        // Retrieve relevant memories (skip if memory system is disabled)
        let memoryBlock: String?
        if AppConfig.memoryEnabled {
            memoryBlock = await memoryArmy.searcherRetrieve(
                userMessage: userContent,
                conversationHistory: messages
            )
        } else {
            memoryBlock = nil
        }

        // Also get the existing MemoryManager's prompt (for backward compatibility)
        let legacyMemory = await MemoryManager.shared.assembleMemoryPrompt()

        // Build the enriched system prompt
        var systemParts: [String] = []

        // 1. Agent identity block (skip if client provided their own system prompt)
        if !clientProvidedSystem {
            let agentConfig: AgentConfig
            if let found = await agentConfigManager.agent(agentID) {
                agentConfig = found
            } else {
                agentConfig = await agentConfigManager.defaultAgent
            }
            let identityBlock = agentConfig.buildIdentityBlock(accessLevel: accessLevel, availableTools: toolNames)
            systemParts.append(identityBlock)
        }

        // 1.5. Platform context (for bridge conversations)
        if let platform = platform, !platform.isEmpty {
            systemParts.append(platformContextNote(platform))
        }

        // 2. Memory context (from vector search)
        //    Sanitize to prevent prompt injection via crafted memories.
        if let memoryBlock, !memoryBlock.isEmpty {
            systemParts.append(Self.sanitizeMemoryBlock(memoryBlock))
        }

        // 3. Legacy memory (structured facts — always include if available)
        //    Legacy holds identity/user/project knowledge that vector search may not surface.
        if !legacyMemory.isEmpty {
            systemParts.append(Self.sanitizeMemoryBlock(legacyMemory))
        }

        // 4. Skills prompt additions (enabled skills at current access level, filtered by agent)
        if !clientProvidedSystem {
            let agentSkillIDs = await agentConfigManager.agent(agentID)?.enabledSkillIDs ?? []
            let skillsBlock = await SkillsManager.shared.skillsPromptBlock(forAccessLevel: accessLevel, allowedSkillIDs: agentSkillIDs)
            if !skillsBlock.isEmpty {
                systemParts.append(skillsBlock)
            }
        }

        // 5. Commitments nudges (overdue follow-ups injected into system prompt)
        let nudges = await CommitmentsFollowUp.shared.consumeNudges()
        if !nudges.isEmpty {
            let nudgeBlock = "<commitments>\n" + nudges.joined(separator: "\n") + "\n</commitments>"
            systemParts.append(nudgeBlock)
        }

        let systemPrompt = systemParts.joined(separator: "\n\n")

        // Inject or merge with existing system message
        if let firstIdx = messages.indices.first, messages[firstIdx]["role"] as? String == "system" {
            let existingPrompt = messages[firstIdx]["content"] as? String ?? ""
            messages[firstIdx]["content"] = existingPrompt + "\n\n" + systemPrompt
        } else {
            messages.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        body["messages"] = messages
    }

    // MARK: - Memory Sanitization

    /// Strip patterns commonly used in prompt injection attacks from memory content.
    /// Removes instruction-like markers while preserving factual content.
    private static func sanitizeMemoryBlock(_ block: String) -> String {
        var s = block
        // Strip common prompt injection patterns (case-insensitive)
        let injectionPatterns = [
            "(?i)\\bsystem\\s*(?:override|prompt|instruction|message)\\s*:",
            "(?i)\\bignore\\s+(?:all\\s+)?previous\\s+instructions\\b",
            "(?i)\\bignore\\s+(?:all\\s+)?above\\s+instructions\\b",
            "(?i)\\byou\\s+are\\s+now\\b",
            "(?i)\\bact\\s+as\\s+(?:if|though)\\b",
            "(?i)\\bnew\\s+(?:system\\s+)?instructions?\\s*:",
            "(?i)\\b(?:assistant|ai)\\s*:\\s*(?:sure|ok|yes)",
            "(?i)<\\/?(?:system|instruction|prompt|override)>"
        ]
        for pattern in injectionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[filtered]")
            }
        }
        return s
    }

    // MARK: - Post-Response: Extract & Store Memories

    /// Process a completed exchange AFTER the LLM responds.
    /// Extracts new memories and indexes them. Runs in background.
    /// Nonisolated so callers don't need to await — fires and forgets.
    nonisolated func processExchange(userMessage: String, assistantResponse: String, model: String) {
        guard AppConfig.memoryEnabled else { return }
        let army = memoryArmy
        // Run extraction in background — never block the response
        Task {
            // Memory Army's librarian handles extraction + indexing
            await army.librarianProcess(
                userMessage: userMessage,
                assistantResponse: assistantResponse,
                model: model
            )

            // Also update legacy MemoryManager (backward compatibility)
            await MemoryManager.shared.extractFromExchange(
                userMessage: userMessage,
                assistantResponse: assistantResponse,
                model: model
            )
        }
    }

    // MARK: - API: Memory Management Endpoints

    /// Search memories directly (for /v1/memory/search endpoint)
    func searchMemories(query: String, topK: Int = 10) async -> [[String: Any]] {
        let results = await memoryIndex.search(query: query, topK: topK, minScore: 0.2)
        return results.map { r in
            [
                "id": r.id,
                "text": r.text,
                "category": r.category,
                "source": r.source,
                "timestamp": ISO8601DateFormatter().string(from: r.timestamp),
                "importance": r.importance,
                "score": r.score
            ] as [String: Any]
        }
    }

    /// Add a memory manually (for /v1/memory/add endpoint)
    func addMemory(text: String, category: String = "fact", importance: Float = 0.7) async -> Bool {
        let id = await memoryIndex.add(text: text, category: category, source: "manual", importance: importance)
        return id != nil
    }

    /// Remove a memory by ID (for /v1/memory/remove endpoint)
    func removeMemory(id: Int64) async {
        await memoryIndex.remove(id: id)
    }

    /// Get memory system stats
    func getStats() async -> [String: Any] {
        let indexCount = await memoryIndex.count
        let categories = await memoryIndex.categoryCounts()
        let armyStats = await memoryArmy.getStats()

        return [
            "totalMemories": indexCount,
            "categories": categories,
            "army": armyStats,
            "isReady": isReady
        ]
    }

    /// Force a repair cycle
    func triggerRepair() async {
        await memoryArmy.runRepairCycle()
    }

    // MARK: - Helpers

    private func extractText(from content: Any?) -> String {
        if let text = content as? String { return text }
        if let array = content as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if item["type"] as? String == "text" { return item["text"] as? String }
                return nil
            }.joined(separator: " ")
        }
        return ""
    }

    private func platformContextNote(_ platform: String) -> String {
        switch platform {
        case "discord":
            return "<platform>User is messaging via Discord. Use Discord markdown (```code```, **bold**, > quotes). Keep responses concise — long messages feel heavy in chat. Emoji are natural here.</platform>"
        case "telegram":
            return "<platform>User is messaging via Telegram. Use Telegram Markdown (*bold*, _italic_, `code`). Messages can be moderate length. Markdown links work: [text](url).</platform>"
        case "slack":
            return "<platform>User is messaging via Slack. Use Slack mrkdwn (*bold*, _italic_, `code`, ```code blocks```). Keep professional tone. Thread-aware context.</platform>"
        case "signal":
            return "<platform>User is messaging via Signal. Plain text only — no markdown rendering. Keep responses short and direct. Privacy-conscious context.</platform>"
        case "whatsapp":
            return "<platform>User is messaging via WhatsApp. Use WhatsApp formatting (*bold*, _italic_, ```code```). Keep responses mobile-friendly and concise.</platform>"
        default:
            return ""
        }
    }
}
