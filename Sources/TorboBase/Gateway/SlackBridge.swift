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

        let url = URL(string: "\(baseURL)/chat.postMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "channel": channel,
            "text": text,
            "unfurl_links": false
        ]
        if let ts = threadTS { body["thread_ts"] = ts }
        // Slack has 4000 char limit for text; blocks can do more
        if text.count > 3900 {
            body["text"] = String(text.prefix(3900)) + "\n...[truncated]"
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, !ok {
                let error = json["error"] as? String ?? "Unknown"
                print("[Slack] Send failed: \(error)")
            }
        } catch {
            print("[Slack] Send error: \(error.localizedDescription)")
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
            print("[Slack] Disabled — no bot token or channel ID configured")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        print("[Slack] Starting message polling on channel \(await channelID)")

        // Set initial timestamp to now to avoid processing old messages
        lastTimestamp = String(Date().timeIntervalSince1970)

        while isPolling {
            do {
                try await pollMessages()
            } catch {
                print("[Slack] Poll error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000) // Poll every 3s (Slack rate limits)
        }
    }

    func stopPolling() {
        isPolling = false
        print("[Slack] Stopped polling")
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
            print("[Slack] Received from \(user): \(text.prefix(100))")
            await handleIncomingMessage(text, threadTS: ts)
        }
    }

    // MARK: - Incoming Message Handler

    private func handleIncomingMessage(_ text: String, threadTS: String? = nil) async {
        let userMsg = ConversationMessage(role: "user", content: text, model: "slack", clientIP: "slack")
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
                await send("⚠️ Failed to get response", threadTS: threadTS)
                return
            }

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "slack")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content, threadTS: threadTS)
        } catch {
            await send("⚠️ Error: \(error.localizedDescription)", threadTS: threadTS)
        }
    }
}
