// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Signal Bridge
// SignalBridge.swift — Signal messaging via signal-cli REST API
// Requires signal-cli running as REST server: https://github.com/bbernhard/signal-cli-rest-api

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor SignalBridge {
    static let shared = SignalBridge()

    private let session: URLSession
    private var isPolling = false
    private var lastTimestamp: Int64 = 0

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    private var phoneNumber: String {
        get async { await MainActor.run { AppState.shared.signalPhoneNumber ?? "" } }
    }
    private var apiURL: String {
        get async { await MainActor.run { AppState.shared.signalAPIURL ?? "http://localhost:8080" } }
    }
    private var isEnabled: Bool {
        get async {
            let phone = await phoneNumber
            let api = await apiURL
            return !phone.isEmpty && !api.isEmpty
        }
    }

    // MARK: - Send Message

    func send(_ text: String, to recipient: String? = nil) async {
        guard await isEnabled else { return }
        let api = await apiURL
        let phone = await phoneNumber

        guard let url = URL(string: "\(api)/v2/send") else {
            TorboLog.error("Invalid API URL: \(api)", subsystem: "Signal")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Format for Signal and split into platform-safe chunks
        let formatted = BridgeFormatter.format(text, for: .signal)
        let chunks = BridgeFormatter.truncate(formatted, for: .signal)

        // Send to configured phone if no recipient specified
        let target = recipient ?? phone
        for chunk in chunks {
            let body: [String: Any] = [
                "message": chunk,
                "number": phone,
                "recipients": [target]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 201 && http.statusCode != 200 {
                    TorboLog.error("Send failed: HTTP \(http.statusCode)", subsystem: "Signal")
                }
            } catch {
                TorboLog.error("Send error: \(error.localizedDescription)", subsystem: "Signal")
            }
        }
    }

    func notify(_ message: String) async {
        await send("🔮 Torbo Base — \(message)")
    }

    // MARK: - Polling

    func startPolling() async {
        guard await isEnabled else {
            TorboLog.warn("Disabled — no phone number or API URL configured", subsystem: "Signal")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        lastTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let url = await apiURL
        TorboLog.info("Starting message polling via \(url)", subsystem: "Signal")

        while isPolling {
            do {
                try await pollMessages()
            } catch {
                TorboLog.error("Poll error: \(error.localizedDescription)", subsystem: "Signal")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped polling", subsystem: "Signal")
    }

    private func pollMessages() async throws {
        let api = await apiURL
        let phone = await phoneNumber

        guard let url = URL(string: "\(api)/v1/receive/\(phone)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        guard let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for message in messages {
            guard let envelope = message["envelope"] as? [String: Any],
                  let dataMessage = envelope["dataMessage"] as? [String: Any],
                  let text = dataMessage["message"] as? String,
                  let timestamp = dataMessage["timestamp"] as? Int64,
                  let source = envelope["source"] as? String,
                  !text.isEmpty else { continue }

            // Skip old messages
            guard timestamp > lastTimestamp else { continue }
            lastTimestamp = timestamp

            TorboLog.info("Received from \(source): \(text.prefix(100))", subsystem: "Signal")
            await handleIncomingMessage(text, from: source)
        }
    }

    // MARK: - Incoming Handler

    private func handleIncomingMessage(_ text: String, from sender: String) async {
        let channelKey = "signal:\(sender)"

        // Group filter — Signal DMs are direct context
        let filterResult = BridgeGroupFilter.filter(text: text, platform: .signal, isDirectMessage: true, botIdentifier: "")
        guard filterResult.shouldProcess else { return }
        let filteredText = filterResult.cleanedText

        // Add user message to conversation context
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: filteredText)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        let userMsg = ConversationMessage(role: "user", content: filteredText, model: "signal", clientIP: "signal/\(sender)")
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
        request.setValue("signal", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                await send("Failed to process message", to: sender)
                return
            }

            // Add assistant response to conversation context
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "signal/\(sender)")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content, to: sender)
        } catch {
            await send("Error: \(error.localizedDescription)", to: sender)
        }
    }
}
