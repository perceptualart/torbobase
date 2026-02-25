// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — iMessage Bridge
// iMessageBridge.swift — iMessage via AppleScript on macOS
// Polls Messages.app for new messages and sends replies via AppleScript.

import Foundation

actor iMessageBridge {
    static let shared = iMessageBridge()

    private var isPolling = false
    private var lastCheckDate = Date()
    private var processedIDs: Set<String> = []
    private let session = URLSession.shared

    // MARK: - Configuration

    private var imessageEnabled = false
    private var imessageRecipient = ""

    func configure(enabled: Bool, recipient: String) {
        imessageEnabled = enabled
        imessageRecipient = recipient
    }

    private var isEnabled: Bool {
        #if os(macOS)
        return imessageEnabled
        #else
        return false
        #endif
    }

    // MARK: - Send Message

    func send(_ text: String, to recipient: String) async {
        #if os(macOS)
        let formatted = BridgeFormatter.format(text, for: .imessage)
        let chunks = BridgeFormatter.truncate(formatted, for: .imessage)
        for chunk in chunks {
            await sendViaAppleScript(chunk, to: recipient)
        }
        #endif
    }

    func notify(_ message: String) async {
        #if os(macOS)
        guard !imessageRecipient.isEmpty else { return }
        await send("Torbo Base — \(message)", to: imessageRecipient)
        #endif
    }

    #if os(macOS)
    private func sendViaAppleScript(_ text: String, to recipient: String) async {
        let sanitized = sanitizeForAppleScript(text)
        let recipientSanitized = sanitizeForAppleScript(recipient)
        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant "\(recipientSanitized)" of targetService
                send "\(sanitized)" to targetBuddy
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                TorboLog.error("AppleScript send failed: \(errStr)", subsystem: "iMessage")
            }
        } catch {
            TorboLog.error("Send error: \(error)", subsystem: "iMessage")
        }
    }

    private func sanitizeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
    #endif

    // MARK: - Polling

    func startPolling() async {
        #if os(macOS)
        guard await isEnabled else {
            TorboLog.warn("iMessage disabled or not configured", subsystem: "iMessage")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        lastCheckDate = Date()
        TorboLog.info("Starting iMessage polling", subsystem: "iMessage")

        while isPolling {
            await pollMessages()
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        }
        #endif
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped iMessage polling", subsystem: "iMessage")
    }

    #if os(macOS)
    private func pollMessages() async {
        let script = """
            tell application "Messages"
                set recentMessages to {}
                repeat with aChat in chats
                    try
                        set lastMsg to last item of messages of aChat
                        set msgDate to date received of lastMsg
                        set msgText to text of lastMsg
                        set msgSender to handle of sender of lastMsg
                        set msgID to id of lastMsg
                        set end of recentMessages to (msgID & "|" & msgSender & "|" & msgText)
                    end try
                end repeat
                return recentMessages as text
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }

            for line in output.components(separatedBy: ", ") {
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 3 else { continue }
                let msgID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let sender = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let text = parts[2...].joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines)

                guard !processedIDs.contains(msgID), !text.isEmpty else { continue }
                processedIDs.insert(msgID)
                if processedIDs.count > 500 { processedIDs = Set(processedIDs.suffix(250)) }

                TorboLog.info("Received from \(sender): \(text.prefix(100))", subsystem: "iMessage")
                await handleIncomingMessage(text, from: sender)
            }
        } catch {
            TorboLog.error("Poll error: \(error)", subsystem: "iMessage")
        }
    }

    private func handleIncomingMessage(_ text: String, from sender: String) async {
        let channelKey = "imessage:\(sender)"

        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: text)
        let history = await BridgeConversationContext.shared.getHistory(channelKey: channelKey)

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
        request.setValue("imessage", forHTTPHeaderField: "x-torbo-platform")
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
            await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "assistant", content: content)
            await send(content, to: sender)
        } catch {
            TorboLog.error("Chat error: \(error)", subsystem: "iMessage")
        }
    }
    #endif
}
