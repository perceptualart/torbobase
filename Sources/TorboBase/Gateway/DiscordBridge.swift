// Torbo Base — Discord Bridge
// DiscordBridge.swift — Bidirectional messaging with Discord via Bot API
// Polls for messages, forwards to gateway, sends responses back

import Foundation

actor DiscordBridge {
    static let shared = DiscordBridge()

    private let session: URLSession
    private var isPolling = false
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

        // Discord has 2000 char limit — split if needed
        let chunks = splitMessage(text, maxLength: 1900)
        for chunk in chunks {
            let url = URL(string: "\(baseURL)/channels/\(channel)/messages")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = ["content": chunk]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    print("[Discord] Send failed: HTTP \(http.statusCode)")
                }
            } catch {
                print("[Discord] Send error: \(error.localizedDescription)")
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
            print("[Discord] Disabled — no bot token or channel ID configured")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        print("[Discord] Starting message polling on channel \(await channelID)")

        while isPolling {
            do {
                try await pollMessages()
            } catch {
                print("[Discord] Poll error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2s
        }
    }

    func stopPolling() {
        isPolling = false
        print("[Discord] Stopped polling")
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
            print("[Discord] Received: \(content.prefix(100))")
            await handleIncomingMessage(content)
        }

        // If we got messages but didn't set lastMessageID, set to newest
        if lastMessageID == nil, let newest = messages.first, let id = newest["id"] as? String {
            lastMessageID = id
        }
    }

    // MARK: - Incoming Message Handler

    private func handleIncomingMessage(_ text: String) async {
        // Log to AppState
        let userMsg = ConversationMessage(role: "user", content: text, model: "discord", clientIP: "discord")
        await MainActor.run { AppState.shared.addMessage(userMsg) }

        // Route through gateway
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
                await send("⚠️ Failed to get response from gateway")
                return
            }

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "discord")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content)
        } catch {
            await send("⚠️ Error: \(error.localizedDescription)")
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
