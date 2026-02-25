// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Matrix Bridge
// MatrixBridge.swift — Matrix protocol via Client-Server API
// Polling via /sync with incremental since token.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor MatrixBridge {
    static let shared = MatrixBridge()

    private let session: URLSession
    private var homeserver: String = ""
    private var accessToken: String = ""
    private var botUserID: String = ""
    private var sinceToken: String = ""
    private var isPolling = false
    private var joinedRooms: Set<String> = []

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 35 // Slightly longer than long-poll timeout
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Configuration

    func configure(homeserver: String, accessToken: String, botUserID: String) {
        self.homeserver = homeserver.hasSuffix("/") ? String(homeserver.dropLast()) : homeserver
        self.accessToken = accessToken
        self.botUserID = botUserID
    }

    var isEnabled: Bool { !homeserver.isEmpty && !accessToken.isEmpty }

    // MARK: - Send Message

    func send(_ text: String, roomID: String) async {
        let formatted = BridgeFormatter.format(text, for: .matrix)
        let chunks = BridgeFormatter.truncate(formatted, for: .matrix)

        for chunk in chunks {
            let txnID = UUID().uuidString
            let sendURL = "\(homeserver)/_matrix/client/v3/rooms/\(roomID)/send/m.room.message/\(txnID)"
            guard let url = URL(string: sendURL) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            // Send HTML-formatted message with plain text fallback
            let htmlBody = chunk.replacingOccurrences(of: "\n", with: "<br>")
            let body: [String: Any] = [
                "msgtype": "m.text",
                "body": BridgeFormatter.format(chunk, for: .signal), // Plain text fallback
                "format": "org.matrix.custom.html",
                "formatted_body": htmlBody
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    TorboLog.error("Matrix send failed: HTTP \(http.statusCode)", subsystem: "Matrix")
                }
            } catch {
                TorboLog.error("Matrix send error: \(error)", subsystem: "Matrix")
            }
        }
    }

    func notify(_ message: String) async {
        for roomID in joinedRooms {
            await send("Torbo Base — \(message)", roomID: roomID)
        }
    }

    // MARK: - Polling via /sync

    func startPolling() async {
        guard isEnabled else {
            TorboLog.warn("Matrix disabled — not configured", subsystem: "Matrix")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        TorboLog.info("Starting Matrix /sync polling against \(homeserver)", subsystem: "Matrix")

        while isPolling {
            do {
                try await syncOnce()
            } catch {
                TorboLog.error("Sync error: \(error)", subsystem: "Matrix")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped Matrix polling", subsystem: "Matrix")
    }

    private func syncOnce() async throws {
        var syncURL = "\(homeserver)/_matrix/client/v3/sync?timeout=30000"
        if !sinceToken.isEmpty {
            syncURL += "&since=\(sinceToken)"
        } else {
            // First sync — only get future events
            syncURL += "&filter={\"room\":{\"timeline\":{\"limit\":0}}}"
        }

        guard let url = URL(string: syncURL) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Update since token
        if let nextBatch = json["next_batch"] as? String {
            sinceToken = nextBatch
        }

        // Process room events
        guard let rooms = json["rooms"] as? [String: Any],
              let join = rooms["join"] as? [String: [String: Any]] else { return }

        for (roomID, roomData) in join {
            joinedRooms.insert(roomID)
            guard let timeline = roomData["timeline"] as? [String: Any],
                  let events = timeline["events"] as? [[String: Any]] else { continue }

            for event in events {
                guard let eventType = event["type"] as? String, eventType == "m.room.message",
                      let content = event["content"] as? [String: Any],
                      let body = content["body"] as? String,
                      let sender = event["sender"] as? String,
                      sender != botUserID,
                      !body.isEmpty else { continue }

                // Group filter — check for @mention
                let isDirectMessage = joinedRooms.count <= 2 // Heuristic for DMs
                let filterResult = BridgeGroupFilter.filter(
                    text: body, platform: .matrix,
                    isDirectMessage: isDirectMessage,
                    botIdentifier: botUserID
                )
                guard filterResult.shouldProcess else { continue }

                TorboLog.info("Matrix from \(sender): \(body.prefix(100))", subsystem: "Matrix")
                await handleIncomingMessage(filterResult.cleanedText, from: sender, roomID: roomID)
            }
        }
    }

    private func handleIncomingMessage(_ text: String, from sender: String, roomID: String) async {
        let channelKey = "matrix:\(roomID)"

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

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("matrix", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else { return }
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
            await send(content, roomID: roomID)
        } catch {
            TorboLog.error("Chat error: \(error)", subsystem: "Matrix")
        }
    }
}
