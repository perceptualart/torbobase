// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Discord Bridge
// DiscordBridge.swift — Bidirectional messaging with Discord via Bot API
// Polls for messages, forwards to gateway, sends responses back

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor DiscordBridge {
    static let shared = DiscordBridge()

    private let session: URLSession
    private var isPolling = false
    private var shouldRun = false
    private var lastMessageID: String?
    private let baseURL = "https://discord.com/api/v10"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    private var botToken: String {
        get async { await MainActor.run { AppState.shared.discordBotToken ?? "" } }
    }
    private var channelID: String {
        get async { await MainActor.run { AppState.shared.discordChannelID ?? "" } }
    }
    private var isEnabled: Bool {
        get async {
            let token = await botToken
            let channel = await channelID
            return !token.isEmpty && !channel.isEmpty
        }
    }

    // MARK: - Send Message

    func send(_ text: String) async {
        guard await isEnabled else { return }
        let token = await botToken
        let channel = await channelID

        // Format for Discord and split into platform-safe chunks
        let formatted = BridgeFormatter.format(text, for: .discord)
        let chunks = BridgeFormatter.truncate(formatted, for: .discord)
        for chunk in chunks {
            guard let url = URL(string: "\(baseURL)/channels/\(channel)/messages") else {
                TorboLog.error("Invalid channel URL for channel: \(channel)", subsystem: "Discord")
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["content": chunk]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    TorboLog.error("Send failed: HTTP \(http.statusCode)", subsystem: "Discord")
                }
            } catch {
                TorboLog.error("Send error: \(error.localizedDescription)", subsystem: "Discord")
            }
        }
    }

    func notify(_ message: String) async {
        await send("🔮 **Torbo Base** — \(message)")
    }

    func forwardExchange(user: String, assistant: String, model: String) async {
        let msg = "👤 **User:** \(user)\n🤖 **\(model):** \(String(assistant.prefix(1500)))"
        await send(msg)
    }

    // MARK: - Polling

    func startPolling() async {
        guard await isEnabled else {
            TorboLog.warn("Disabled — no bot token or channel ID configured", subsystem: "Discord")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        shouldRun = true
        var reconnectAttempts = 0
        let channel = await channelID
        TorboLog.info("Starting message polling on channel \(channel)", subsystem: "Discord")

        while isPolling && shouldRun {
            do {
                try await pollMessages()
                reconnectAttempts = 0
            } catch {
                reconnectAttempts += 1
                TorboLog.error("Poll error (\(reconnectAttempts)): \(error.localizedDescription)", subsystem: "Discord")
                let backoff = min(Double(reconnectAttempts) * 2.0, 60.0)
                let jitter = backoff * Double.random(in: -0.25...0.25)
                try? await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2s
        }
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped polling", subsystem: "Discord")
    }

    /// Stop the Discord bridge gracefully.
    func stop() {
        shouldRun = false
        TorboLog.info("Bridge stopped", subsystem: "Discord")
    }

    private func pollMessages() async throws {
        let token = await botToken
        let channel = await channelID

        var urlStr = "\(baseURL)/channels/\(channel)/messages?limit=10"
        if let lastID = lastMessageID {
            urlStr += "&after=\(lastID)"
        }

        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

        guard let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        // Messages come newest-first, reverse for chronological order
        for message in messages.reversed() {
            guard let id = message["id"] as? String,
                  let content = message["content"] as? String,
                  let author = message["author"] as? [String: Any],
                  let authorBot = author["bot"] as? Bool, !authorBot, // Skip bot messages
                  !content.isEmpty else { continue }

            lastMessageID = id
            TorboLog.info("Received: \(content.prefix(100))", subsystem: "Discord")
            await handleIncomingMessage(content)
        }

        // If we got messages but didn't set lastMessageID, set to newest
        if lastMessageID == nil, let newest = messages.first, let id = newest["id"] as? String {
            lastMessageID = id
        }
    }

    // MARK: - Incoming Message Handler

    private func handleIncomingMessage(_ text: String) async {
        let channel = await channelID
        let channelKey = "discord:\(channel)"

        // Group filter — Discord channels are not DMs by default
        let filterResult = BridgeGroupFilter.filter(text: text, platform: .discord, isDirectMessage: false, botIdentifier: "")
        guard filterResult.shouldProcess else { return }
        let filteredText = filterResult.cleanedText

        // Add user message to conversation context
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: filteredText)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        // Log to AppState
        let userMsg = ConversationMessage(role: "user", content: filteredText, model: "discord", clientIP: "discord")
        await MainActor.run { AppState.shared.addMessage(userMsg) }

        // Route through gateway
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
        request.setValue("discord", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                await send("⚠️ Failed to get response from gateway")
                return
            }

            // Add assistant response to conversation context
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "discord")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content)
        } catch {
            TorboLog.error("Chat error: \(error.localizedDescription)", subsystem: "Discord")
            await send("Sorry, something went wrong. Please try again.")
        }
    }

    // MARK: - Helpers

    private func splitMessage(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: min(maxLength, remaining.count))
            chunks.append(String(remaining[..<end]))
            remaining = String(remaining[end...])
        }
        return chunks
    }
}
