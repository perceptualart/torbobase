// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
// Telegram bridge — full bi-directional bot with multi-agent switching & commands

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor TelegramBridge {
    static let shared = TelegramBridge()

    private let session: URLSession
    private var shouldPoll = false

    /// Per-chat active agent ID (default: "sid")
    private var chatAgents: [String: String] = [:]

    /// Allowed chat IDs — empty means accept all chats
    private var allowedChatIDs: Set<String> = []

    /// Default agent from config (fallback before "sid")
    private var defaultAgent: String = "sid"

    /// Bot username fetched from Telegram API (for group @mention filtering)
    private var botUsername: String = ""

    /// Config file path (~/Library/Application Support/TorboBase/telegram.json)
    private let configPath: String

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60  // Longer than Telegram's 30s long-poll
        self.session = URLSession(configuration: cfg)

        let baseDir = PlatformPaths.appSupportDir.appendingPathComponent("TorboBase", isDirectory: true)
        self.configPath = baseDir.appendingPathComponent("telegram.json").path
    }

    // MARK: - Agent Selection

    /// Get the active agent for a chat
    func activeAgent(for chatID: String) -> String {
        chatAgents[chatID] ?? defaultAgent
    }

    // MARK: - Send Messages

    /// Send a message to a specific Telegram chat
    func sendToChat(_ text: String, chatID: String) async {
        let token = AppConfig.telegramConfig.botToken
        guard !token.isEmpty else { return }

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            TorboLog.error("Invalid bot URL", subsystem: "Telegram")
            return
        }

        let formatted = BridgeFormatter.format(text, for: .telegram)
        let chunks = BridgeFormatter.truncate(formatted, for: .telegram)

        for chunk in chunks {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "chat_id": chatID,
                "text": chunk,
                "parse_mode": "Markdown"
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    TorboLog.error("Send failed (HTTP \(http.statusCode))", subsystem: "Telegram")
                }
            } catch {
                TorboLog.error("Send error: \(error.localizedDescription)", subsystem: "Telegram")
            }
        }
    }

    /// Send a message to the configured default chat (notifications & forwarding)
    func send(_ text: String) async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty, !config.chatId.isEmpty else { return }
        await sendToChat(text, chatID: config.chatId)
    }

    /// Forward a conversation exchange to the default chat
    func forwardExchange(user: String, assistant: String, model: String) async {
        let text = """
        🗣 *User:* \(escapeMarkdown(user))

        🤖 *\(escapeMarkdown(model)):* \(escapeMarkdown(String(assistant.prefix(500))))
        """
        await send(text)
    }

    /// Send a notification to the default chat
    func notify(_ message: String) async {
        await send("🔔 *Torbo Base:* \(escapeMarkdown(message))")
    }

    private func escapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    // MARK: - Polling

    /// Stop the polling loop gracefully.
    func stopPolling() {
        shouldPoll = false
        TorboLog.info("Polling stopped", subsystem: "Telegram")
    }

    /// Start polling for incoming Telegram messages
    func startPolling() async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty else { return }

        // Load config (allowed IDs, default agent)
        loadTelegramConfig()
        writeTelegramConfigIfNeeded()

        // Fetch bot username for group @mention filtering
        await fetchBotUsername()

        shouldPoll = true
        var offset: Int = 0
        var consecutiveErrors = 0
        TorboLog.info("Bot started — polling (username: @\(botUsername))", subsystem: "Telegram")

        while shouldPoll {
            do {
                guard let url = URL(string:
                    "https://api.telegram.org/bot\(config.botToken)/getUpdates?offset=\(offset)&timeout=30"
                ) else {
                    TorboLog.error("Invalid polling URL", subsystem: "Telegram")
                    return
                }
                let (data, _) = try await session.data(from: url)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                guard let ok = json["ok"] as? Bool, ok else {
                    let errCode = json["error_code"] as? Int ?? 0
                    let errDesc = json["description"] as? String ?? "unknown"
                    // 404 = invalid bot token, 401 = unauthorized — stop polling
                    if errCode == 404 || errCode == 401 {
                        TorboLog.error("Bot token invalid (\(errCode): \(errDesc)) — stopping Telegram bridge. Check your bot token.", subsystem: "Telegram")
                        shouldPoll = false
                        return
                    }
                    TorboLog.warn("Telegram API error \(errCode): \(errDesc)", subsystem: "Telegram")
                    continue
                }
                guard let results = json["result"] as? [[String: Any]] else {
                    continue
                }

                for update in results {
                    if let updateId = update["update_id"] as? Int {
                        offset = updateId + 1
                    }

                    guard let message = update["message"] as? [String: Any],
                          let text = message["text"] as? String,
                          let chat = message["chat"] as? [String: Any],
                          let chatId = chat["id"] as? Int else {
                        continue
                    }

                    let chatIDStr = String(chatId)

                    // Allowed-list check (empty = accept all)
                    if !allowedChatIDs.isEmpty && !allowedChatIDs.contains(chatIDStr) {
                        continue
                    }

                    // DM vs group
                    let chatType = chat["type"] as? String ?? "private"
                    let isDM = chatType == "private"

                    // Sender name
                    let from = (message["from"] as? [String: Any])?["first_name"] as? String

                    // Group filter — require @mention or /command in groups
                    let filterResult = BridgeGroupFilter.filter(
                        text: text,
                        platform: .telegram,
                        isDirectMessage: isDM,
                        botIdentifier: botUsername
                    )
                    guard filterResult.shouldProcess else { continue }

                    await processMessage(filterResult.cleanedText, chatID: chatIDStr, from: from)
                }

                consecutiveErrors = 0
            } catch {
                consecutiveErrors += 1
                TorboLog.error("Polling error (\(consecutiveErrors)): \(error.localizedDescription)", subsystem: "Telegram")
                let backoff = min(Double(consecutiveErrors) * 2.0, 30.0)
                let jitter = backoff * Double.random(in: -0.25...0.25)
                try? await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
            }
        }
    }

    // MARK: - Message Processing

    /// Route incoming text — command or chat message
    private func processMessage(_ text: String, chatID: String, from: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Commands start with /
        if trimmed.hasPrefix("/") {
            let raw = trimmed.lowercased().split(separator: " ").first.map(String.init) ?? trimmed.lowercased()
            // Strip @botname suffix (e.g. /start@TorboBot → /start)
            let command = raw.split(separator: "@").first.map(String.init) ?? raw
            await handleCommand(command, chatID: chatID, from: from)
            return
        }

        // Regular message → LLM pipeline
        await handleIncomingMessage(trimmed, chatID: chatID)
    }

    // MARK: - Commands

    private func handleCommand(_ command: String, chatID: String, from: String?) async {
        switch command {
        case "/start":
            await cmdStart(chatID: chatID, from: from)
        case "/agents":
            await cmdAgents(chatID: chatID)
        case "/status":
            await cmdStatus(chatID: chatID)
        case "/help":
            await cmdHelp(chatID: chatID)
        case "/clear":
            await cmdClear(chatID: chatID)
        default:
            // Check if command matches any agent ID (e.g. /sid, /ada, /mira, /orion, or custom)
            let agentID = String(command.dropFirst())
            if !agentID.isEmpty, await AgentConfigManager.shared.agent(agentID) != nil {
                await cmdSwitchAgent(agentID, chatID: chatID)
            } else {
                await sendToChat("Unknown command. Type /help for available commands.", chatID: chatID)
            }
        }
    }

    private func cmdStart(chatID: String, from: String?) async {
        let name = from ?? "there"
        let agentName = await agentDisplayName(activeAgent(for: chatID))
        let msg = """
        Hey \(name) — welcome to *Torbo*.

        You're connected to Torbo Base, a local-first AI gateway. No cloud middlemen. Your conversations stay yours.

        You're talking to *\(agentName)*. Switch agents anytime:
        /sid — SiD (Superintelligent AI)
        /ada — aDa (CTO)
        /mira — Mira (Creative Director)
        /orion — Orion (Lead Architect)

        Type /help for all commands, or just start talking.
        """
        await sendToChat(msg, chatID: chatID)
    }

    private func cmdAgents(chatID: String) async {
        let agents = await AgentConfigManager.shared.listAgents()
        let current = activeAgent(for: chatID)

        var lines: [String] = ["*Available Agents:*\n"]
        for agent in agents {
            let marker = agent.id == current ? " ← active" : ""
            lines.append("• *\(agent.name)* (`/\(agent.id)`)\(marker)\n  \(String(agent.role.prefix(60)))")
        }
        lines.append("\nSwitch with `/agentname` (e.g. /sid)")
        await sendToChat(lines.joined(separator: "\n"), chatID: chatID)
    }

    private func cmdStatus(chatID: String) async {
        let (port, clients, models, ollamaRunning) = await MainActor.run {
            let s = AppState.shared
            return (s.serverPort, s.connectedClients, s.ollamaModels, s.ollamaRunning)
        }
        let activeModel = models.first ?? "none"
        let agent = activeAgent(for: chatID)
        let agentName = await agentDisplayName(agent)
        let channels = await BridgeConversationContext.shared.activeChannelCount

        let msg = """
        *Torbo Base Status*
        Server: port \(port)
        Ollama: \(ollamaRunning ? "running" : "stopped")
        Model: `\(activeModel)`
        Connected clients: \(clients)
        Active conversations: \(channels)
        Your agent: *\(agentName)* (`\(agent)`)
        """
        await sendToChat(msg, chatID: chatID)
    }

    private func cmdHelp(chatID: String) async {
        let msg = """
        *Torbo Bot Commands*

        /start — Welcome & intro
        /agents — List available agents
        /status — Server status & info
        /help — This message
        /clear — Clear conversation history

        *Switch Agent:*
        /sid — SiD (Superintelligent AI)
        /ada — aDa (CTO)
        /mira — Mira (Creative Director)
        /orion — Orion (Lead Architect)

        Or just type a message to talk.
        """
        await sendToChat(msg, chatID: chatID)
    }

    private func cmdSwitchAgent(_ agentID: String, chatID: String) async {
        if let agent = await AgentConfigManager.shared.agent(agentID) {
            chatAgents[chatID] = agentID
            await sendToChat("Switched to *\(agent.name)*. \(String(agent.role.prefix(80)))", chatID: chatID)
            TorboLog.info("Chat \(chatID) switched to agent: \(agentID)", subsystem: "Telegram")
        } else {
            await sendToChat("Agent `\(agentID)` not found. Type /agents to see available agents.", chatID: chatID)
        }
    }

    private func cmdClear(chatID: String) async {
        let channelKey = "telegram:\(chatID)"
        await BridgeConversationContext.shared.clearChannel(channelKey: channelKey)
        await sendToChat("Conversation cleared.", chatID: chatID)
    }

    // MARK: - Chat Message Routing

    /// Route a chat message through the local Torbo Base gateway
    private func handleIncomingMessage(_ text: String, chatID: String) async {
        let channelKey = "telegram:\(chatID)"
        let agentID = activeAgent(for: chatID)

        // Add to conversation context
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: text)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        // Get server info
        let (port, token, model) = await MainActor.run {
            let s = AppState.shared
            return (s.serverPort, s.serverToken, s.ollamaModels.first ?? "qwen2.5:7b")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120  // LLM calls can be slow
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("telegram", forHTTPHeaderField: "x-torbo-platform")
        req.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")

        let body: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
                await sendToChat(content, chatID: chatID)
            } else {
                await sendToChat("No response from the model. Try again.", chatID: chatID)
            }
        } catch {
            TorboLog.error("Chat routing error: \(error.localizedDescription)", subsystem: "Telegram")
            await sendToChat("Something went wrong. Please try again.", chatID: chatID)
        }
    }

    // MARK: - Helpers

    /// Fetch bot username from Telegram API (for group @mention detection)
    private func fetchBotUsername() async {
        let token = AppConfig.telegramConfig.botToken
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getMe") else { return }

        do {
            let (data, _) = try await session.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let username = result["username"] as? String {
                botUsername = username
                TorboLog.info("Bot identity: @\(username)", subsystem: "Telegram")
            }
        } catch {
            TorboLog.warn("Could not fetch bot identity: \(error.localizedDescription)", subsystem: "Telegram")
        }
    }

    /// Look up display name for an agent ID
    private func agentDisplayName(_ agentID: String) async -> String {
        if let agent = await AgentConfigManager.shared.agent(agentID) {
            return agent.name
        }
        return agentID
    }

    // MARK: - Config (telegram.json)

    /// Load telegram.json — allowed chat IDs and default agent
    private func loadTelegramConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let ids = json["allowedChatIDs"] as? [String], !ids.isEmpty {
            allowedChatIDs = Set(ids)
            TorboLog.info("Loaded \(ids.count) allowed chat ID(s)", subsystem: "Telegram")
        }

        if let agent = json["defaultAgent"] as? String, !agent.isEmpty {
            defaultAgent = agent
        }
    }

    /// Write telegram.json template if it doesn't exist
    private func writeTelegramConfigIfNeeded() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }

        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let template: [String: Any] = [
            "_note": "Telegram bridge config. Bot token is stored securely in Keychain — NOT in this file.",
            "tokenStorage": "keychain",
            "defaultAgent": "sid",
            "allowAllChats": true,
            "allowedChatIDs": [String]()
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: configPath))
            TorboLog.info("Created telegram.json config", subsystem: "Telegram")
        } catch {
            TorboLog.error("Failed to write telegram.json: \(error)", subsystem: "Telegram")
        }
    }
}
