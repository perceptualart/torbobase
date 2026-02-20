// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
// Telegram integration — forward conversations and send notifications
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor TelegramBridge {
    static let shared = TelegramBridge()

    private let session: URLSession
    private var shouldPoll = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Send a message to the configured Telegram chat
    func send(_ text: String) async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty, !config.chatId.isEmpty else { return }

        guard let url = URL(string: "https://api.telegram.org/bot\(config.botToken)/sendMessage") else {
            TorboLog.error("Invalid bot token URL", subsystem: "Telegram")
            return
        }
        let formatted = BridgeFormatter.format(text, for: .telegram)
        let chunks = BridgeFormatter.truncate(formatted, for: .telegram)

        for chunk in chunks {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "chat_id": config.chatId,
                "text": chunk,
                "parse_mode": "Markdown"
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    TorboLog.info("Sent message", subsystem: "Telegram")
                } else {
                    TorboLog.error("Failed to send", subsystem: "Telegram")
                }
            } catch {
                TorboLog.error("Error: \(error.localizedDescription)", subsystem: "Telegram")
            }
        }
    }

    /// Forward a conversation exchange
    func forwardExchange(user: String, assistant: String, model: String) async {
        let text = """
        🗣 *User:* \(escapeMarkdown(user))

        🤖 *\(escapeMarkdown(model)):* \(escapeMarkdown(String(assistant.prefix(500))))
        """
        await send(text)
    }

    /// Send a notification
    func notify(_ message: String) async {
        await send("🔔 *Torbo Base:* \(escapeMarkdown(message))")
    }

    private func escapeMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// Stop the polling loop gracefully.
    func stopPolling() {
        shouldPoll = false
        TorboLog.info("Polling stopped", subsystem: "Telegram")
    }

    /// Start polling for incoming Telegram messages via long-polling
    func startPolling() async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty, !config.chatId.isEmpty else { return }

        shouldPoll = true
        var offset: Int = 0
        var consecutiveErrors = 0
        TorboLog.info("Started polling for messages", subsystem: "Telegram")

        while shouldPoll {
            do {
                guard let url = URL(string: "https://api.telegram.org/bot\(config.botToken)/getUpdates?offset=\(offset)&timeout=30") else {
                    TorboLog.error("Invalid polling URL", subsystem: "Telegram")
                    return
                }
                let (data, _) = try await session.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok,
                   let results = json["result"] as? [[String: Any]] {
                    for update in results {
                        if let updateId = update["update_id"] as? Int {
                            offset = updateId + 1
                        }
                        if let message = update["message"] as? [String: Any],
                           let text = message["text"] as? String,
                           let chat = message["chat"] as? [String: Any],
                           let chatId = chat["id"] as? Int,
                           String(chatId) == config.chatId {
                            // Process incoming Telegram message — route through gateway
                            await handleIncomingMessage(text, chatID: String(chatId))
                        }
                    }
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

    /// Handle incoming Telegram message — route through local gateway (so SiD identity is injected)
    private func handleIncomingMessage(_ text: String, chatID: String) async {
        let channelKey = "telegram:\(chatID)"

        // Group filter — Telegram chatId match implies direct context
        let filterResult = BridgeGroupFilter.filter(text: text, platform: .telegram, isDirectMessage: true, botIdentifier: "")
        guard filterResult.shouldProcess else { return }
        let filteredText = filterResult.cleanedText

        // Add user message to conversation context
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: filteredText)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        // Route through the local Torbo Base gateway to get SiD identity + memory + tools
        let (port, token, model) = await MainActor.run {
            (AppState.shared.serverPort, AppState.shared.serverToken, AppState.shared.ollamaModels.first ?? "qwen2.5:7b")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("telegram", forHTTPHeaderField: "x-torbo-platform")
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
                // Add assistant response to conversation context
                await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
                await send(content)
            }
        } catch {
            TorboLog.error("Chat error: \(error.localizedDescription)", subsystem: "Telegram")
            await send("Sorry, something went wrong. Please try again.")
        }
    }
}
