// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Email Bridge
// EmailBridge.swift — Two-way email messaging via IMAP/SMTP or macOS Mail.app
// Polls for incoming emails and sends replies.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor EmailBridge {
    static let shared = EmailBridge()

    private var isPolling = false
    private var processedIDs: Set<String> = []
    private let session = URLSession.shared

    // MARK: - Configuration

    struct EmailConfig {
        var smtpHost: String = ""
        var smtpPort: Int = 587
        var smtpUser: String = ""
        var smtpPass: String = ""
        var imapHost: String = ""
        var imapPort: Int = 993
        var imapUser: String = ""
        var imapPass: String = ""
        var fromAddress: String = ""
    }

    private var config = EmailConfig()

    func configure(_ cfg: EmailConfig) {
        config = cfg
    }

    private var isEnabled: Bool {
        !config.fromAddress.isEmpty
    }

    // MARK: - Send Email

    func send(_ text: String, to recipient: String, subject: String = "Re: Torbo Base") async {
        let formatted = BridgeFormatter.format(text, for: .email)

        #if os(macOS)
        // Prefer AppleScript on macOS for simplicity
        await sendViaAppleScript(formatted, to: recipient, subject: subject)
        #else
        await sendViaSMTP(formatted, to: recipient, subject: subject)
        #endif
    }

    func notify(_ message: String) async {
        // Email notifications need a configured recipient
        guard isEnabled else { return }
        TorboLog.info("Email notification: \(message.prefix(80))", subsystem: "Email")
    }

    #if os(macOS)
    private func sendViaAppleScript(_ body: String, to recipient: String, subject: String) async {
        let sanitized = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let recipientSanitized = recipient.replacingOccurrences(of: "\"", with: "\\\"")
        let subjectSanitized = subject.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
            tell application "Mail"
                set newMessage to make new outgoing message with properties {subject:"\(subjectSanitized)", content:"\(sanitized)", visible:false}
                tell newMessage
                    make new to recipient at end of to recipients with properties {address:"\(recipientSanitized)"}
                end tell
                send newMessage
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                TorboLog.info("Email sent to \(recipient)", subsystem: "Email")
            } else {
                TorboLog.error("AppleScript email send failed", subsystem: "Email")
            }
        } catch {
            TorboLog.error("Send error: \(error)", subsystem: "Email")
        }
    }
    #endif

    private func sendViaSMTP(_ body: String, to recipient: String, subject: String) async {
        // Use system sendmail/msmtp as SMTP fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sendmail")
        process.arguments = ["-t"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let headers = """
            From: \(config.fromAddress)
            To: \(recipient)
            Subject: \(subject)
            Content-Type: text/html; charset=UTF-8

            \(body)
            """
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(headers.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                TorboLog.info("Email sent to \(recipient) via sendmail", subsystem: "Email")
            }
        } catch {
            TorboLog.error("SMTP send error: \(error)", subsystem: "Email")
        }
    }

    // MARK: - Polling

    func startPolling() async {
        guard isEnabled else {
            TorboLog.warn("Email bridge disabled — no from address configured", subsystem: "Email")
            return
        }
        guard !isPolling else { return }
        isPolling = true
        TorboLog.info("Starting email polling (60s interval)", subsystem: "Email")

        while isPolling {
            await pollInbox()
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
        }
    }

    func stopPolling() {
        isPolling = false
        TorboLog.info("Stopped email polling", subsystem: "Email")
    }

    private func pollInbox() async {
        #if os(macOS)
        // Use AppleScript to check for unread messages
        let raw = await EmailManager.shared.checkEmail(limit: 10)
        for line in raw.split(separator: "\n").map(String.init) {
            guard line.contains("ID:") && line.contains("FROM:") && line.contains("SUBJECT:") else { continue }
            let parts = parseEmailLine(line)
            guard let eid = parts["ID"], !processedIDs.contains(eid) else { continue }
            processedIDs.insert(eid)
            if processedIDs.count > 500 { processedIDs = Set(processedIDs.suffix(250)) }

            let from = parts["FROM"] ?? ""
            let subject = parts["SUBJECT"] ?? ""
            TorboLog.info("New email from \(from): \(subject.prefix(80))", subsystem: "Email")

            // Read full email body
            let body = await EmailManager.shared.readEmail(id: eid)
            await handleIncomingEmail(body: body, from: from, subject: subject, emailID: eid)
        }
        #endif
    }

    private func parseEmailLine(_ line: String) -> [String: String] {
        var r: [String: String] = [:]
        for seg in line.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let ci = seg.firstIndex(of: ":") {
                r[String(seg[seg.startIndex..<ci]).trimmingCharacters(in: .whitespaces)] =
                    String(seg[seg.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return r
    }

    private func handleIncomingEmail(body: String, from: String, subject: String, emailID: String) async {
        let channelKey = "email:\(subject.lowercased().prefix(50))"
        let messageText = "Email from \(from) — Subject: \(subject)\n\n\(body)"

        await BridgeConversationContext.shared.addMessage(channelKey: channelKey, role: "user", content: messageText)
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
        request.setValue("email", forHTTPHeaderField: "x-torbo-platform")
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
            await send(content, to: from, subject: "Re: \(subject)")
        } catch {
            TorboLog.error("Chat error for email: \(error)", subsystem: "Email")
        }
    }
}
