// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Telegram integration — forward conversations and send notifications
import Foundation

actor TelegramBridge {
    static let shared = TelegramBridge()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Send a message to the configured Telegram chat
    func send(_ text: String) async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty, !config.chatId.isEmpty else { return }

        let url = URL(string: "https://api.telegram.org/bot\(config.botToken)/sendMessage")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id": config.chatId,
            "text": text,
            "parse_mode": "Markdown"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                print("[Telegram] Sent message")
            } else {
                print("[Telegram] Failed to send")
            }
        } catch {
            print("[Telegram] Error: \(error.localizedDescription)")
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

    /// Start polling for incoming Telegram messages (Clawdbot-style)
    func startPolling() async {
        let config = AppConfig.telegramConfig
        guard config.enabled, !config.botToken.isEmpty, !config.chatId.isEmpty else { return }

        var offset: Int = 0
        print("[Telegram] Started polling for messages")

        while true {
            do {
                let url = URL(string: "https://api.telegram.org/bot\(config.botToken)/getUpdates?offset=\(offset)&timeout=30")!
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
                            // Process incoming Telegram message — route to Ollama
                            await handleIncomingMessage(text)
                        }
                    }
                }
            } catch {
                print("[Telegram] Polling error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Handle incoming Telegram message — route to Ollama and reply
    private func handleIncomingMessage(_ text: String) async {
        // Log user message
        let userMsg = ConversationMessage(role: "user", content: text, model: "telegram", clientIP: "telegram")
        await MainActor.run { AppState.shared.addMessage(userMsg) }

        // Route to Ollama
        let model = await MainActor.run { AppState.shared.ollamaModels.first ?? "qwen2.5:7b" }
        guard let url = URL(string: "http://127.0.0.1:11434/v1/chat/completions") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": text]],
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
                // Log assistant message
                let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "telegram")
                await MainActor.run { AppState.shared.addMessage(assistantMsg) }
                // Reply on Telegram
                await send(content)
            }
        } catch {
            await send("❌ Error: \(error.localizedDescription)")
        }
    }
}
