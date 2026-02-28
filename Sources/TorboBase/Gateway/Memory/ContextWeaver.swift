// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — ContextWeaver (Dynamic Context Assembly)
// The viewpoint — selects which particles from the River form a coherent
// picture for each request, respecting token budgets so context never overflows.

import Foundation

/// Assembles the system prompt dynamically, respecting token budgets.
/// Each section (identity, memories, recent stream, skills, etc.) gets an
/// allocation based on the model's context window. Required sections always
/// included; optional sections dropped gracefully if over budget.
actor ContextWeaver {
    static let shared = ContextWeaver()

    // MARK: - Types

    struct ContextBudget: Sendable {
        let totalTokens: Int
        let reservedForResponse: Int
        let sections: [SectionAlloc]

        struct SectionAlloc: Sendable {
            let section: ContextSection
            let percentage: Float     // Of remaining budget after response reserve
            let priority: Int         // Lower = higher priority (filled first)
            let required: Bool        // If true, always include even if over budget
        }
    }

    enum ContextSection: String, CaseIterable, Sendable {
        case identity       // Agent identity block (persona, role, rules)
        case pinnedMemories // User-pinned permanent memories
        case recentStream   // Recent conversation from StreamStore
        case retrievedMemory // Semantic recall from MemoryIndex
        case skills         // Active skill prompts
        case platform       // Platform formatting guidance
        case entities       // Relevant entity context
        case commitments    // Overdue follow-ups
    }

    // MARK: - Budget Profiles

    /// Budget for large context models (Claude Sonnet/Opus, GPT-4 Turbo)
    static let budget128K = ContextBudget(
        totalTokens: 128_000,
        reservedForResponse: 4096,
        sections: [
            .init(section: .identity, percentage: 0.05, priority: 0, required: true),
            .init(section: .pinnedMemories, percentage: 0.05, priority: 1, required: true),
            .init(section: .recentStream, percentage: 0.30, priority: 2, required: true),
            .init(section: .retrievedMemory, percentage: 0.25, priority: 3, required: false),
            .init(section: .skills, percentage: 0.10, priority: 4, required: false),
            .init(section: .platform, percentage: 0.02, priority: 5, required: false),
            .init(section: .entities, percentage: 0.08, priority: 6, required: false),
            .init(section: .commitments, percentage: 0.05, priority: 7, required: false),
        ]
    )

    /// Budget for medium context models (GPT-4o, Gemini)
    static let budget32K = ContextBudget(
        totalTokens: 32_000,
        reservedForResponse: 4096,
        sections: [
            .init(section: .identity, percentage: 0.08, priority: 0, required: true),
            .init(section: .pinnedMemories, percentage: 0.05, priority: 1, required: true),
            .init(section: .recentStream, percentage: 0.35, priority: 2, required: true),
            .init(section: .retrievedMemory, percentage: 0.20, priority: 3, required: false),
            .init(section: .skills, percentage: 0.08, priority: 4, required: false),
            .init(section: .platform, percentage: 0.02, priority: 5, required: false),
            .init(section: .entities, percentage: 0.05, priority: 6, required: false),
            .init(section: .commitments, percentage: 0.05, priority: 7, required: false),
        ]
    )

    /// Budget for small context local models (Ollama llama/qwen 8K)
    static let budget8K = ContextBudget(
        totalTokens: 8_000,
        reservedForResponse: 2048,
        sections: [
            .init(section: .identity, percentage: 0.12, priority: 0, required: true),
            .init(section: .pinnedMemories, percentage: 0.08, priority: 1, required: true),
            .init(section: .recentStream, percentage: 0.40, priority: 2, required: true),
            .init(section: .retrievedMemory, percentage: 0.15, priority: 3, required: false),
            .init(section: .skills, percentage: 0.05, priority: 4, required: false),
            .init(section: .platform, percentage: 0.02, priority: 5, required: false),
            .init(section: .entities, percentage: 0.00, priority: 6, required: false),
            .init(section: .commitments, percentage: 0.05, priority: 7, required: false),
        ]
    )

    // MARK: - Budget Selection

    /// Select an appropriate budget based on model name.
    static func budgetForModel(_ modelName: String) -> ContextBudget {
        let lower = modelName.lowercased()
        // Large context: Claude family, GPT-4 Turbo, Gemini Pro
        if lower.contains("claude") || lower.contains("gpt-4-turbo") || lower.contains("gpt-4o")
            || lower.contains("gemini") || lower.contains("deepseek") {
            return budget128K
        }
        // Medium context: GPT-4, GPT-3.5
        if lower.contains("gpt-4") || lower.contains("gpt-3.5") {
            return budget32K
        }
        // Small context: local models
        if lower.contains("llama") || lower.contains("qwen") || lower.contains("mistral")
            || lower.contains("phi") || lower.contains("gemma") || lower.contains("codellama") {
            return budget8K
        }
        // Default: assume medium
        return budget32K
    }

    // MARK: - Weave

    /// Assemble the full system prompt respecting token budgets.
    /// - Parameters:
    ///   - agentID: Which agent is handling this request
    ///   - channelKey: Channel identifier for StreamStore context
    ///   - userMessage: The user's current message (for memory search)
    ///   - platform: Platform name (telegram, discord, etc.)
    ///   - budget: Token budget to respect
    ///   - accessLevel: Current access level
    ///   - toolNames: Available tool names
    ///   - clientProvidedSystem: Whether client sent their own system prompt
    ///   - conversationHistory: Existing message history for search context
    /// - Returns: The assembled system prompt string
    func weave(agentID: String, channelKey: String, userMessage: String,
               platform: String?, budget: ContextBudget, accessLevel: Int = 1,
               toolNames: [String] = [], clientProvidedSystem: Bool = false,
               conversationHistory: [[String: Any]] = []) async -> String {

        // Calculate available token budget
        let messageTokens = estimateTokens(userMessage)
        let available = max(budget.totalTokens - budget.reservedForResponse - messageTokens, 1000)

        // Sort sections by priority
        let sortedAllocs = budget.sections.sorted { $0.priority < $1.priority }

        // Generate content for each section
        var sectionContent: [ContextSection: String] = [:]
        var sectionTokens: [ContextSection: Int] = [:]
        var totalUsed = 0

        for alloc in sortedAllocs {
            let maxTokens = Int(Float(available) * alloc.percentage)

            let content = await generateSection(
                alloc.section,
                agentID: agentID,
                channelKey: channelKey,
                userMessage: userMessage,
                platform: platform,
                accessLevel: accessLevel,
                toolNames: toolNames,
                clientProvidedSystem: clientProvidedSystem,
                conversationHistory: conversationHistory
            )

            guard !content.isEmpty else { continue }

            let tokens = estimateTokens(content)

            // Check budget
            if totalUsed + tokens > available && !alloc.required {
                // Optional section doesn't fit — skip it
                continue
            }

            // Truncate if section exceeds its allocation (but still include if required)
            let finalContent: String
            if tokens > maxTokens && maxTokens > 0 {
                finalContent = truncateToTokens(content, maxTokens: maxTokens)
            } else {
                finalContent = content
            }

            let finalTokens = estimateTokens(finalContent)
            sectionContent[alloc.section] = finalContent
            sectionTokens[alloc.section] = finalTokens
            totalUsed += finalTokens
        }

        // Assemble in priority order
        var parts: [String] = []
        for alloc in sortedAllocs {
            if let content = sectionContent[alloc.section] {
                parts.append(content)
            }
        }

        // Grounding footer — appended after token budget allocation so it's never trimmed.
        // Placed last for recency bias — the LLM weighs recent instructions heavily.
        parts.append("""
        <grounding>
        SYSTEM STATUS: You are FULLY OPERATIONAL. All systems are live. Your tools are active and ready to use.
        If a user asks you to do something, DO IT using your tools — don't talk about what you "would" do or claim you "can't" do things.
        NEVER claim you are "not fully connected", "not activated", "missing integration", or "waiting for a handshake". These are not real states. You are live RIGHT NOW.
        NEVER invent technical-sounding explanations for limitations. If you genuinely can't do something, say "I can't do that" — don't fabricate a reason.
        </grounding>
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Section Generators

    private func generateSection(_ section: ContextSection, agentID: String,
                                  channelKey: String, userMessage: String,
                                  platform: String?, accessLevel: Int,
                                  toolNames: [String], clientProvidedSystem: Bool,
                                  conversationHistory: [[String: Any]]) async -> String {
        switch section {
        case .identity:
            return await generateIdentity(agentID: agentID, accessLevel: accessLevel,
                                          toolNames: toolNames, clientProvided: clientProvidedSystem)
        case .pinnedMemories:
            return await generatePinnedMemories()
        case .recentStream:
            return await generateRecentStream(channelKey: channelKey)
        case .retrievedMemory:
            return await generateRetrievedMemory(userMessage: userMessage, history: conversationHistory)
        case .skills:
            return await generateSkills(agentID: agentID, accessLevel: accessLevel,
                                        clientProvided: clientProvidedSystem)
        case .platform:
            return generatePlatform(platform)
        case .entities:
            return await generateEntities(userMessage: userMessage)
        case .commitments:
            return await generateCommitments()
        }
    }

    private func generateIdentity(agentID: String, accessLevel: Int,
                                   toolNames: [String], clientProvided: Bool) async -> String {
        // When client provides its own system prompt (iOS app), skip the full identity
        // block (personality) but ALWAYS inject behavioral rules and access/tool context.
        // These are critical — without them, agents hallucinate about capabilities
        // and don't know what tools they have.
        if clientProvided {
            return buildBehaviorAndAccess(accessLevel: accessLevel, toolNames: toolNames)
        }
        let config: AgentConfig
        if let found = await AgentConfigManager.shared.agent(agentID) {
            config = found
        } else {
            config = await AgentConfigManager.shared.defaultAgent
        }
        return config.buildIdentityBlock(accessLevel: accessLevel, availableTools: toolNames)
    }

    /// Behavioral rules + access/tool context — injected even when client provides personality.
    /// This ensures agents never hallucinate about capabilities and always know their tools.
    private func buildBehaviorAndAccess(accessLevel: Int, toolNames: [String]) -> String {
        var parts: [String] = []

        parts.append("""
        <behavior>
        ⚠️ ABSOLUTE RULE — READ THIS FIRST:
        You ARE connected. The gateway IS running. Everything IS working. You are live right now.
        NEVER say the gateway is off, disconnected, or not running.
        NEVER say features need to be "activated", "enabled", "flipped on", or "set up".
        NEVER mention "deep integration", "handshake", "activation sequence", or "full brain mode".
        NEVER speculate about your own infrastructure, connection state, or system status.
        If you are receiving this message, you are fully operational. Period. Do not claim otherwise.

        NEVER HALLUCINATE:
        - If you don't know something, say "I don't know" — do not fill the gap with plausible-sounding fiction.
        - NEVER fabricate capabilities, limitations, or system states. Only describe what you can actually observe or do.
        - NEVER invent technical-sounding explanations for things you don't understand.
        - Your tools list below is your ground truth. If a tool is listed, you can use it. If it's not listed, you can't. Don't speculate about hidden or inactive capabilities.

        CRITICAL RULES:
        - NEVER read file paths, code, terminal output, or technical details to the user. The user is NOT a developer console. Just DO the action and give the RESULT in plain English.
        - NEVER repeat or paraphrase what the user just said. Go straight to the answer or action.
        - NEVER narrate your process ("I'm going to...", "Let me...", "I'll use the X tool to..."). Just do it, then say what happened.
        - SHOW, don't TELL. Describe outcomes and results. Don't describe your methods.
        - Keep responses SHORT. 1-3 sentences unless the user asks for more detail. Brevity is respect.
        - Always respond. Never go silent. If something fails, say what went wrong simply.
        - You are talking to a human having a conversation. Not filing a report.

        USE YOUR TOOLS:
        - You have real tools available to you. When a user asks you to do something that a tool can handle, USE THE TOOL. Don't just talk about it.
        - If asked to search the web, use web_search. If asked to read a file, use read_file. If asked about the weather, use get_weather. And so on.
        - You are not "just a chatbot" — you are an agent with real capabilities. Act like it.
        - If a tool call fails, tell the user what happened simply and try an alternative approach.

        ENVIRONMENT:
        - You are running inside the Torbo app — a voice-first AI assistant. NOT a web browser, NOT a code editor.
        - You do NOT have "Canvas" or "Artifacts". NEVER output [writing to canvas...], [writing: filename], or similar bracket markers. These get spoken aloud by TTS and sound terrible.
        - Your output is spoken aloud via text-to-speech. Keep it conversational — no markdown tables, no code blocks (unless explicitly asked), no progress markers in brackets.
        - If the user asks for code, games, or long-form content, use write_file to save it, then tell the user where to find it. Do NOT try to display it inline or use canvas.
        </behavior>
        """)

        let levelNames = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
        let levelName = accessLevel < levelNames.count ? levelNames[accessLevel] : "UNKNOWN"
        parts.append("""
        <access>
        Current access level: \(accessLevel) (\(levelName))
        \(toolNames.isEmpty ? "No tools available at this level." : "Available tools: \(toolNames.joined(separator: ", "))")
        </access>
        """)

        return parts.joined(separator: "\n\n")
    }

    private func generatePinnedMemories() async -> String {
        let pinned = await MemoryIndex.shared.pinnedMemories()
        guard !pinned.isEmpty else { return "" }

        var block = "<pinned_memories>\n"
        block += "These are permanently pinned memories — always relevant:\n"
        for entry in pinned {
            block += "- \(entry.text)\n"
        }
        block += "</pinned_memories>"
        return block
    }

    private func generateRecentStream(channelKey: String) async -> String {
        // Use StreamStore for recent conversation context
        let events = await StreamStore.shared.recentContext(channelKey: channelKey, limit: 30)
        guard !events.isEmpty else { return "" }

        var lines: [String] = []
        for event in events {
            switch event.kind {
            case .message:
                let role = event.metadata["role"] ?? "assistant"
                lines.append("[\(role)]: \(event.content)")
            case .toolCall:
                let tool = event.metadata["tool_name"] ?? "tool"
                lines.append("[tool: \(tool)]")
            case .toolResult:
                let tool = event.metadata["tool_name"] ?? "tool"
                let preview = String(event.content.prefix(200))
                lines.append("[result: \(tool)] \(preview)")
            default:
                break
            }
        }

        guard !lines.isEmpty else { return "" }
        return "<recent_context>\n" + lines.joined(separator: "\n") + "\n</recent_context>"
    }

    private func generateRetrievedMemory(userMessage: String, history: [[String: Any]]) async -> String {
        guard AppConfig.memoryEnabled else { return "" }
        let block = await MemoryArmy.shared.searcherRetrieve(
            userMessage: userMessage,
            conversationHistory: history
        )
        guard !block.isEmpty else { return "" }
        return sanitizeMemoryBlock(block)
    }

    private func generateSkills(agentID: String, accessLevel: Int, clientProvided: Bool) async -> String {
        // Always inject skills — even when client provides its own system prompt.
        // Skills define what the agent can actually DO. Without them, agents don't
        // know about their capabilities and act like plain chatbots.
        let agentSkillIDs = await AgentConfigManager.shared.agent(agentID)?.enabledSkillIDs ?? []
        return await SkillsManager.shared.skillsPromptBlock(forAccessLevel: accessLevel, allowedSkillIDs: agentSkillIDs)
    }

    private func generatePlatform(_ platform: String?) -> String {
        guard let platform, !platform.isEmpty else { return "" }
        switch platform {
        case "discord":
            return "<platform>User is messaging via Discord. Use Discord markdown (```code```, **bold**, > quotes). Keep responses concise. Emoji are natural here.</platform>"
        case "telegram":
            return "<platform>User is messaging via Telegram. Use Telegram Markdown (*bold*, _italic_, `code`). Messages can be moderate length.</platform>"
        case "slack":
            return "<platform>User is messaging via Slack. Use Slack mrkdwn (*bold*, _italic_, `code`, ```code blocks```). Keep professional tone.</platform>"
        case "signal":
            return "<platform>User is messaging via Signal. Plain text only — no markdown rendering. Keep responses short and direct.</platform>"
        case "whatsapp":
            return "<platform>User is messaging via WhatsApp. Use WhatsApp formatting (*bold*, _italic_, ```code```). Keep responses mobile-friendly.</platform>"
        case "imessage":
            return "<platform>User is messaging via iMessage. Plain text only — no markdown. Keep responses conversational and concise.</platform>"
        case "email":
            return "<platform>User is communicating via email. Responses can be longer and more structured. Use proper greeting/closing.</platform>"
        case "teams":
            return "<platform>User is messaging via Microsoft Teams. Use markdown formatting. Professional tone.</platform>"
        case "googlechat":
            return "<platform>User is messaging via Google Chat. Plain text preferred. Keep responses concise and professional.</platform>"
        case "matrix":
            return "<platform>User is messaging via Matrix. Markdown and HTML supported. Privacy-focused community.</platform>"
        case "sms":
            return "<platform>User is messaging via SMS. Plain text only. Keep responses very concise.</platform>"
        default:
            return ""
        }
    }

    private func generateEntities(userMessage: String) async -> String {
        // Extract entity mentions from user message and pull their subgraph
        let knownEntities = await MemoryIndex.shared.knownEntities

        var mentionedEntities: [String] = []
        let lowerMsg = userMessage.lowercased()
        for entity in knownEntities {
            if lowerMsg.contains(entity.lowercased()) {
                mentionedEntities.append(entity)
            }
        }

        guard !mentionedEntities.isEmpty else { return "" }

        // Pull relationships from EntityGraph
        var lines: [String] = []
        for entity in mentionedEntities.prefix(5) { // Cap at 5 entities
            let rels = await EntityGraph.shared.query(entity: entity)
            if !rels.isEmpty {
                let relDescriptions = rels.prefix(5).map { "\($0.subjectEntity) \($0.predicate) \($0.objectEntity)" }
                lines.append("\(entity): " + relDescriptions.joined(separator: "; "))
            } else {
                // Fallback: entity exists in memory but no graph relationships yet
                let memories = await MemoryIndex.shared.searchByEntity(name: entity, topK: 3)
                if !memories.isEmpty {
                    let summaries = memories.prefix(2).map { $0.text.prefix(100) }
                    lines.append("\(entity): " + summaries.joined(separator: "; "))
                }
            }
        }

        guard !lines.isEmpty else { return "" }
        return "<entities>\n" + lines.joined(separator: "\n") + "\n</entities>"
    }

    private func generateCommitments() async -> String {
        let nudges = await CommitmentsFollowUp.shared.consumeNudges()
        guard !nudges.isEmpty else { return "" }
        return "<commitments>\n" + nudges.joined(separator: "\n") + "\n</commitments>"
    }

    // MARK: - Token Estimation

    /// Approximate token count: ~4 chars per token for English text.
    private func estimateTokens(_ text: String) -> Int {
        max(text.count / 4, 1)
    }

    /// Truncate text to approximately fit within a token budget.
    private func truncateToTokens(_ text: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        guard text.count > maxChars else { return text }

        // Try to truncate at a line boundary
        let truncated = String(text.prefix(maxChars))
        if let lastNewline = truncated.lastIndex(of: "\n") {
            return String(truncated[truncated.startIndex...lastNewline]) + "\n[... truncated for context budget]"
        }
        return truncated + "\n[... truncated for context budget]"
    }

    // MARK: - Sanitization

    /// Strip patterns commonly used in prompt injection attacks from memory content.
    private func sanitizeMemoryBlock(_ block: String) -> String {
        var s = block
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
}
