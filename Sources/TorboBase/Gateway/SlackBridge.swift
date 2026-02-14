// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Slack Bridge
// SlackBridge.swift — Bidirectional messaging with Slack via Bot API
// Uses conversations.history polling + chat.postMessage for responses

import Foundation

actor SlackBridge {
    static let shared = SlackBridge()

    private let session: URLSession
    private var isPolling = false
    private var lastTimestamp: String?     // Slack uses timestamps for pagination
    private let baseURL = "https://slack.com/api"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    private var botToken: String {
        get async { await MainActor.run { AppState.shared.slackBotToken ?? "" } }
    }
    private var channelID: String {
        get async { await MainActor.run { AppState.shared.slackChannelID ?? "" } }
    }
    private var botUserID: String {
        get async { await MainActor.run { AppState.shared.slackBotUserID ?? "" } }
    }
    private var isEnabled: Bool {
        get async {
            let token = await botToken
            let channel = await channelID
            return !token.isEmpty && !channel.isEmpty
        }
    }

    // MARK: - Send Message

    func send(_ text: String, threadTS: String? = nil) async {
        guard await isEnabled else { return }
        let token = await botToken
        let channel = await channelID

        guard let url = URL(string: "\(baseURL)/chat.postMessage") else {
            TorboLog.error("Invalid API URL", subsystem: "Slack")
            return
        }

        // Format for Slack and split into platform-safe chunks
        let formatted = BridgeFormatter.format(text, for: .slack)
        let chunks = BridgeFormatter.truncate(formatted, for: .slack)

        for chunk in chunks {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "channel": channel,
                "text": chunk,
                "unfurl_links": false
            ]
            if let ts = threadTS { body["thread_ts"] = ts }

            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, _) = try await session.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, !ok {
                    let error = json["error"] as? String ?? "Unknown"
                    TorboLog.error("Send failed: \(error)", subsystem: "Slack")
                }
            } catch {
                TorboLog.error("Send error: \(error.localizedDescription)", subsystem: "Slack")
            }
        }
    }

    func notify(_ message: String) async {
        await send("🔮 *Torbo Base* — \(message)")
    }

    func forwardExchange(user: String, assistant: String, model: String) async {
        let msg = "👤 *User:* \(user)\n🤖 *\(model):* \(String(assistant.prefix(3000)))"
        await send(msg)
    }

    // MARK: - Polling

    func startPolling() async {
        guard await isEnabled else {
            TorboLog.warn("Disabled — no bot token or channel ID configured", subsystem: "Slack")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        let channel = await channelID
        TorboLog.info("Starting message polling on channel \(channel)", subsystem: "Slack")

        // Set initial timestamp to now to avoid processing old messages
        lastTimestamp = String(Date().timeIntervalSince1970)

        while isPolling {
            do {
                try await pollMessages()
            } catch {
                TorboLog.error("Poll error: \(error.localizedDescription)", subsystem: "Slack")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000) // Poll every 3s (Slack rate limits)
        }
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped polling", subsystem: "Slack")
    }

    private func pollMessages() async throws {
        let token = await botToken
        let channel = await channelID
        let botID = await botUserID

        var urlStr = "\(baseURL)/conversations.history?channel=\(channel)&limit=10"
        if let ts = lastTimestamp {
            urlStr += "&oldest=\(ts)"
        }

        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let messages = json["messages"] as? [[String: Any]] else { return }

        // Process messages (oldest first)
        for message in messages.reversed() {
            guard let text = message["text"] as? String,
                  let ts = message["ts"] as? String,
                  !text.isEmpty else { continue }

            // Skip bot's own messages
            let user = message["user"] as? String ?? ""
            let subtype = message["subtype"] as? String
            if user == botID || subtype == "bot_message" { continue }

            lastTimestamp = ts
            TorboLog.info("Received from \(user): \(text.prefix(100))", subsystem: "Slack")
            await handleIncomingMessage(text, threadTS: ts)
        }
    }

    // MARK: - Incoming Message Handler

    private func handleIncomingMessage(_ text: String, threadTS: String? = nil) async {
        let channel = await channelID
        // Use thread TS as channel key for threaded conversations, fall back to channel ID
        let channelKey = "slack:\(threadTS ?? channel)"

        // Group filter — Slack channels are group contexts
        let botID = await botUserID
        let filterResult = BridgeGroupFilter.filter(text: text, platform: .slack, isDirectMessage: false, botIdentifier: botID)
        guard filterResult.shouldProcess else { return }
        let filteredText = filterResult.cleanedText

        // Add user message to conversation context
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: filteredText)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        let userMsg = ConversationMessage(role: "user", content: filteredText, model: "slack", clientIP: "slack")
        await MainActor.run { AppState.shared.addMessage(userMsg) }

        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }
        let model = await MainActor.run { AppState.shared.ollamaModels.first ?? "qwen2.5:7b" }

        let body: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": false
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("slack", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                await send("⚠️ Failed to get response", threadTS: threadTS)
                return
            }

            // Add assistant response to conversation context
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "slack")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content, threadTS: threadTS)
        } catch {
            await send("⚠️ Error: \(error.localizedDescription)", threadTS: threadTS)
        }
    }
}
