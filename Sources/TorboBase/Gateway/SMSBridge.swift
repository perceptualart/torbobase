// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — SMS Bridge (Twilio)
// SMSBridge.swift — SMS messaging via Twilio Programmable SMS API
// Webhook-based: receives inbound SMS, sends replies via Twilio Messages API.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor SMSBridge {
    static let shared = SMSBridge()

    private let session: URLSession
    private var accountSID: String = ""
    private var authToken: String = ""
    private var phoneNumber: String = "" // Twilio phone number (E.164 format)

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Configuration

    func configure(accountSID: String, authToken: String, phoneNumber: String) {
        self.accountSID = accountSID
        self.authToken = authToken
        self.phoneNumber = phoneNumber
    }

    var isEnabled: Bool { !accountSID.isEmpty && !authToken.isEmpty && !phoneNumber.isEmpty }

    // MARK: - Send SMS

    func send(_ text: String, to recipient: String) async {
        guard isEnabled else { return }

        let formatted = BridgeFormatter.format(text, for: .sms)
        let chunks = BridgeFormatter.truncate(formatted, for: .sms)

        for chunk in chunks {
            let sendURL = "https://api.twilio.com/2010-04-01/Accounts/\(accountSID)/Messages.json"
            guard let url = URL(string: sendURL) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            // Basic auth: accountSID:authToken
            let credentials = "\(accountSID):\(authToken)"
            if let credData = credentials.data(using: .utf8) {
                request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }

            let bodyStr = "To=\(urlEncode(recipient))&From=\(urlEncode(phoneNumber))&Body=\(urlEncode(chunk))"
            request.httpBody = Data(bodyStr.utf8)

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                    let errorBody = String(data: data, encoding: .utf8) ?? ""
                    TorboLog.error("SMS send failed: HTTP \(http.statusCode) — \(errorBody.prefix(200))", subsystem: "SMS")
                }
            } catch {
                TorboLog.error("SMS send error: \(error)", subsystem: "SMS")
            }
        }
    }

    func notify(_ message: String) async {
        TorboLog.info("SMS notification: \(message.prefix(80))", subsystem: "SMS")
    }

    // MARK: - Incoming Webhook Handler

    /// Handle incoming SMS from POST /v1/sms/webhook (Twilio webhook)
    /// Twilio sends form-encoded data: From, To, Body, MessageSid, etc.
    func handleWebhook(_ params: [String: String]) async -> String {
        guard let body = params["Body"], !body.isEmpty,
              let from = params["From"], !from.isEmpty else {
            return twimlResponse("No message body received.")
        }

        TorboLog.info("SMS from \(from): \(body.prefix(100))", subsystem: "SMS")

        let channelKey = "sms:\(from)"
        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: body)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }
        let model = await MainActor.run { AppState.shared.ollamaModels.first ?? "qwen2.5:7b" }

        let chatBody: [String: Any] = [
            "model": model,
            "messages": history,
            "stream": false
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            return twimlResponse("Internal error.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("sms", forHTTPHeaderField: "x-torbo-platform")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: chatBody)

        do {
            let (responseData, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return twimlResponse("Sorry, I couldn't process that.")
            }
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
            let formatted = BridgeFormatter.format(content, for: .sms)
            return twimlResponse(formatted)
        } catch {
            TorboLog.error("Chat error: \(error)", subsystem: "SMS")
            return twimlResponse("Sorry, something went wrong.")
        }
    }

    // MARK: - Helpers

    private func twimlResponse(_ message: String) -> String {
        // Twilio expects TwiML XML response
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Message>\(escaped)</Message></Response>"
    }

    private func urlEncode(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }
}
