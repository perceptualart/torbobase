// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Microsoft Teams Bridge
// TeamsBridge.swift — Teams messaging via Bot Framework REST API
// Webhook-based: receives activity payloads, replies via conversation endpoint.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor TeamsBridge {
    static let shared = TeamsBridge()

    private let session: URLSession
    private var botAppID: String = ""
    private var botAppSecret: String = ""
    private var accessToken: String = ""
    private var tokenExpiry: Date = .distantPast

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Configuration

    func configure(appID: String, appSecret: String) {
        botAppID = appID
        botAppSecret = appSecret
    }

    var isEnabled: Bool { !botAppID.isEmpty && !botAppSecret.isEmpty }

    // MARK: - OAuth Token

    private func ensureToken() async {
        guard Date() >= tokenExpiry else { return }
        guard let url = URL(string: "https://login.microsoftonline.com/botframework.com/oauth2/v2.0/token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyStr = "grant_type=client_credentials&client_id=\(botAppID)&client_secret=\(botAppSecret)&scope=https%3A%2F%2Fapi.botframework.com%2F.default"
        request.httpBody = Data(bodyStr.utf8)

        do {
            let (data, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Int else { return }
            accessToken = token
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            TorboLog.info("Refreshed Bot Framework token", subsystem: "Teams")
        } catch {
            TorboLog.error("Token refresh failed: \(error)", subsystem: "Teams")
        }
    }

    // MARK: - Send Message

    func send(_ text: String, serviceURL: String, conversationID: String) async {
        await ensureToken()
        let formatted = BridgeFormatter.format(text, for: .teams)
        let chunks = BridgeFormatter.truncate(formatted, for: .teams)

        for chunk in chunks {
            let replyURL = "\(serviceURL)v3/conversations/\(conversationID)/activities"
            guard let url = URL(string: replyURL) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = [
                "type": "message",
                "text": chunk
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    TorboLog.error("Send failed: HTTP \(http.statusCode)", subsystem: "Teams")
                }
            } catch {
                TorboLog.error("Send error: \(error)", subsystem: "Teams")
            }
        }
    }

    func notify(_ message: String) async {
        TorboLog.info("Teams notification: \(message.prefix(80))", subsystem: "Teams")
    }

    // MARK: - Incoming Webhook Handler

    /// Handle incoming Teams activity payload from POST /v1/teams/webhook
    func handleWebhook(_ payload: [String: Any]) async -> [String: Any] {
        guard let activityType = payload["type"] as? String, activityType == "message" else {
            return ["status": "ignored", "reason": "not a message"]
        }

        guard let text = payload["text"] as? String, !text.isEmpty else {
            return ["status": "ignored", "reason": "empty text"]
        }

        let serviceURL = payload["serviceUrl"] as? String ?? ""
        let conversation = payload["conversation"] as? [String: Any]
        let conversationID = conversation?["id"] as? String ?? ""
        let from = payload["from"] as? [String: Any]
        let senderName = from?["name"] as? String ?? "unknown"
        let isGroup = conversation?["isGroup"] as? Bool ?? false

        // Group filter — check for @mention
        if isGroup {
            let entities = payload["entities"] as? [[String: Any]] ?? []
            let mentioned = entities.contains { entity in
                entity["type"] as? String == "mention" &&
                (entity["mentioned"] as? [String: Any])?["id"] as? String == botAppID
            }
            guard mentioned else { return ["status": "ignored", "reason": "not mentioned in group"] }
        }

        // Strip @mention from text
        let cleanedText = text.replacingOccurrences(of: "<at>[^<]*</at>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return ["status": "ignored", "reason": "empty after mention strip"] }

        TorboLog.info("Teams message from \(senderName): \(cleanedText.prefix(100))", subsystem: "Teams")

        let channelKey = "teams:\(conversationID)"
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: cleanedText)
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
            return ["status": "error", "reason": "invalid chat URL"]
        }
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("teams", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return ["status": "error", "reason": "failed to parse LLM response"]
            }
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
            await send(content, serviceURL: serviceURL, conversationID: conversationID)
            return ["status": "ok"]
        } catch {
            TorboLog.error("Chat error: \(error)", subsystem: "Teams")
            return ["status": "error", "reason": error.localizedDescription]
        }
    }
}
