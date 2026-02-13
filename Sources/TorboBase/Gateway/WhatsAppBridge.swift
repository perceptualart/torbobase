// Torbo Base — WhatsApp Bridge
// WhatsAppBridge.swift — WhatsApp Business Cloud API integration
// Uses webhook-based inbound + REST outbound messaging

import Foundation

actor WhatsAppBridge {
    static let shared = WhatsAppBridge()

    private let session: URLSession
    private let apiVersion = "v18.0"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    private var accessToken: String {
        get async { await MainActor.run { AppState.shared.whatsappAccessToken ?? "" } }
    }
    private var phoneNumberID: String {
        get async { await MainActor.run { AppState.shared.whatsappPhoneNumberID ?? "" } }
    }
    private var verifyToken: String {
        get async { await MainActor.run { AppState.shared.whatsappVerifyToken ?? "" } }
    }
    var isEnabled: Bool {
        get async {
            let token = await accessToken
            let phoneID = await phoneNumberID
            return !token.isEmpty && !phoneID.isEmpty
        }
    }

    // MARK: - Send Message

    func send(_ text: String, to recipientPhone: String) async {
        guard await isEnabled else { return }
        let token = await accessToken
        let phoneID = await phoneNumberID

        let url = URL(string: "https://graph.facebook.com/\(apiVersion)/\(phoneID)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messaging_product": "whatsapp",
            "to": recipientPhone,
            "type": "text",
            "text": ["body": String(text.prefix(4096))]  // WhatsApp 4096 char limit
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                print("[WhatsApp] Send failed (\(http.statusCode)): \(errBody.prefix(200))")
            }
        } catch {
            print("[WhatsApp] Send error: \(error.localizedDescription)")
        }
    }

    func notify(_ message: String, to phone: String) async {
        await send("🔮 Torbo Base — \(message)", to: phone)
    }

    // MARK: - Webhook Verification (GET)

    /// Handle WhatsApp webhook verification challenge
    func handleVerification(mode: String?, token: String?, challenge: String?) -> (valid: Bool, challenge: String?) {
        guard mode == "subscribe",
              let token = token,
              let challenge = challenge else {
            return (false, nil)
        }
        // Verify against our stored verify token (synchronous check)
        // Caller should compare with configured verifyToken
        return (true, challenge)
    }

    // MARK: - Webhook Payload Processing (POST)

    /// Process incoming WhatsApp webhook payload
    func processWebhook(payload: [String: Any]) async {
        guard let entry = payload["entry"] as? [[String: Any]] else { return }

        for entryItem in entry {
            guard let changes = entryItem["changes"] as? [[String: Any]] else { continue }

            for change in changes {
                guard let value = change["value"] as? [String: Any],
                      let messages = value["messages"] as? [[String: Any]] else { continue }

                for message in messages {
                    guard let type = message["type"] as? String, type == "text",
                          let text = (message["text"] as? [String: Any])?["body"] as? String,
                          let from = message["from"] as? String else { continue }

                    print("[WhatsApp] Received from +\(from): \(text.prefix(100))")
                    await handleIncomingMessage(text, from: from)
                }
            }
        }
    }

    // MARK: - Incoming Handler

    private func handleIncomingMessage(_ text: String, from phone: String) async {
        let userMsg = ConversationMessage(role: "user", content: text, model: "whatsapp", clientIP: "whatsapp/\(phone)")
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
                await send("Failed to process your message.", to: phone)
                return
            }

            let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: "whatsapp/\(phone)")
            await MainActor.run { AppState.shared.addMessage(assistantMsg) }
            await send(content, to: phone)
        } catch {
            await send("Error: \(error.localizedDescription)", to: phone)
        }
    }
}
