// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Google Chat Bridge
// GoogleChatBridge.swift — Google Chat via webhook / Chat API
// Webhook-based: receives event payloads, replies via spaces API.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor GoogleChatBridge {
    static let shared = GoogleChatBridge()

    private let session: URLSession
    private var serviceAccountKey: String = ""
    private var accessToken: String = ""
    private var tokenExpiry: Date = .distantPast

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Configuration

    func configure(serviceAccountKey: String) {
        self.serviceAccountKey = serviceAccountKey
    }

    var isEnabled: Bool { !serviceAccountKey.isEmpty }

    // MARK: - Send Message

    func send(_ text: String, spaceName: String) async {
        let formatted = BridgeFormatter.format(text, for: .googlechat)
        let chunks = BridgeFormatter.truncate(formatted, for: .googlechat)

        for chunk in chunks {
            let sendURL = "https://chat.googleapis.com/v1/\(spaceName)/messages"
            guard let url = URL(string: sendURL) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            let body: [String: Any] = ["text": chunk]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    TorboLog.error("Google Chat send failed: HTTP \(http.statusCode)", subsystem: "GoogleChat")
                }
            } catch {
                TorboLog.error("Google Chat send error: \(error)", subsystem: "GoogleChat")
            }
        }
    }

    func notify(_ message: String) async {
        TorboLog.info("Google Chat notification: \(message.prefix(80))", subsystem: "GoogleChat")
    }

    // MARK: - Incoming Webhook Handler

    /// Handle incoming Google Chat event from POST /v1/googlechat/webhook
    func handleWebhook(_ payload: [String: Any]) async -> [String: Any] {
        let eventType = payload["type"] as? String ?? ""

        // Handle ADDED_TO_SPACE
        if eventType == "ADDED_TO_SPACE" {
            return ["text": "Hello! I'm Torbo Base. Mention me to start a conversation."]
        }

        // Only process MESSAGE events
        guard eventType == "MESSAGE" else {
            return ["status": "ignored"]
        }

        guard let message = payload["message"] as? [String: Any],
              let text = message["text"] as? String, !text.isEmpty else {
            return ["status": "ignored", "reason": "empty text"]
        }

        let sender = (message["sender"] as? [String: Any])?["displayName"] as? String ?? "unknown"
        let spaceName = (payload["space"] as? [String: Any])?["name"] as? String ?? ""
        let spaceType = (payload["space"] as? [String: Any])?["type"] as? String ?? "DM"

        // Group filter — check for @mention in annotations
        if spaceType == "ROOM" {
            let annotations = message["annotations"] as? [[String: Any]] ?? []
            let mentioned = annotations.contains { a in
                a["type"] as? String == "USER_MENTION" &&
                (a["userMention"] as? [String: Any])?["type"] as? String == "BOT"
            }
            guard mentioned else { return ["status": "ignored", "reason": "not mentioned"] }
        }

        TorboLog.info("Google Chat from \(sender): \(text.prefix(100))", subsystem: "GoogleChat")

        let channelKey = "googlechat:\(spaceName)"
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: text)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }
        let model = await MainActor.run { AppState.shared.ollamaModels.first ?? "qwen2.5:7b" }

        let chatBody: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": false
        ]

        guard let chatURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            return ["text": "Internal error"]
        }
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("googlechat", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                return ["text": "Sorry, I couldn't process that."]
            }
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
            // Return synchronous reply for Google Chat webhook
            let formatted = BridgeFormatter.format(content, for: .googlechat)
            return ["text": formatted]
        } catch {
            TorboLog.error("Chat error: \(error)", subsystem: "GoogleChat")
            return ["text": "Sorry, something went wrong."]
        }
    }
}
