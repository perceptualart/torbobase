// Torbo Base — Signal Bridge
// SignalBridge.swift — Signal messaging via signal-cli REST API
// Requires signal-cli running as REST server: https://github.com/bbernhard/signal-cli-rest-api

import Foundation

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

        let url = URL(string: "\(api)/v2/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Send to configured phone if no recipient specified
        let target = recipient ?? phone
        let body: [String: Any] = [
            "message": String(text.prefix(4096)),
            "number": phone,
            "recipients": [target]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 201 && http.statusCode != 200 {
                print("[Signal] Send failed: HTTP \(http.statusCode)")
            }
        } catch {
            print("[Signal] Send error: \(error.localizedDescription)")
        }
    }

    func notify(_ message: String) async {
        await send("🔮 Torbo Base — \(message)")
    }

    // MARK: - Polling

    func startPolling() async {
        guard await isEnabled else {
            print("[Signal] Disabled — no phone number or API URL configured")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        lastTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        print("[Signal] Starting message polling via \(await apiURL)")

        while isPolling {
            do {
                try await pollMessages()
            } catch {
                print("[Signal] Poll error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func stopPolling() {
        isPolling = false
        print("[Signal] Stopped polling")
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

            print("[Signal] Received from \(source): \(text.prefix(100))")
            await handleIncomingMessage(text, from: source)
        }
    }

    // MARK: - Incoming Handler

    private func handleIncomingMessage(_ text: String, from sender: String) async {
        let userMsg = ConversationMessage(role: "user", content: text, model: "signal", clientIP: "signal/\(sender)")
        await MainActor.run { AppState.shared.addMessage(userMsg) }

        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }
        let model = await MainActor.run { AppState.shared.ollamaModels.first ?? "qwen2.5:7b" }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": text]],
            "stream": false
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "signal/\(sender)")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content, to: sender)
        } catch {
            await send("Error: \(error.localizedDescription)", to: sender)
        }
    }
}
