// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Bridge File Delivery
// Uploads files natively to each bridge platform.
// Small files (<5MB): native upload (Telegram photo, Discord attachment, etc.)
// Large files (>=5MB): send FileVault download URL as text message.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor BridgeFileDelivery {
    static let shared = BridgeFileDelivery()

    /// Files under this size are uploaded natively to the platform
    private let nativeUploadLimit = 5 * 1024 * 1024 // 5 MB

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Unified Delivery

    /// Deliver a file through the appropriate bridge.
    /// Platform is detected from the channel key prefix (e.g. "telegram:123", "discord:456").
    /// For small files: uploads natively. For large files: sends download URL.
    func deliver(
        vaultEntry: FileVault.VaultEntry,
        data: Data,
        channelKey: String,
        caption: String? = nil,
        baseURL: String
    ) async {
        let downloadURL = await FileVault.shared.downloadURL(for: vaultEntry, baseURL: baseURL)
        let parts = channelKey.split(separator: ":", maxSplits: 1)
        let platform = String(parts.first ?? "")
        let channelID = parts.count > 1 ? String(parts.last!) : ""

        let useNative = data.count < nativeUploadLimit

        switch platform {
        case "telegram":
            if useNative {
                await telegramSendDocument(data: data, filename: vaultEntry.originalName, mimeType: vaultEntry.mimeType, chatID: channelID, caption: caption)
            } else {
                let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
                await TelegramBridge.shared.sendToChat(msg, chatID: channelID)
            }

        case "discord":
            if useNative {
                await discordSendAttachment(data: data, filename: vaultEntry.originalName, channelID: channelID, caption: caption)
            } else {
                let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
                await DiscordBridge.shared.sendToChannel(msg, channelID: channelID)
            }

        case "slack":
            if useNative {
                await slackUploadFile(data: data, filename: vaultEntry.originalName, channelID: channelID, caption: caption)
            } else {
                let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
                await SlackBridge.shared.sendToChannel(msg, channelID: channelID)
            }

        case "whatsapp":
            // WhatsApp: always send download URL (native upload requires phone number ID + media endpoint)
            let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
            await WhatsAppBridge.shared.sendToPhone(msg, phoneNumber: channelID)

        case "signal":
            // Signal: always send download URL
            let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
            await SignalBridge.shared.sendToRecipient(msg, recipient: channelID)

        case "email":
            // Email: always send download URL (MIME attachments would need full email re-architecture)
            let msg = formatDownloadMessage(name: vaultEntry.originalName, url: downloadURL, caption: caption)
            await EmailBridge.shared.sendFileNotification(msg, to: channelID)

        default:
            // Unknown platform — log and send URL as fallback
            TorboLog.warn("Unknown platform '\(platform)' for file delivery — sending URL", subsystem: "FileDelivery")
        }
    }

    // MARK: - Telegram Native Upload

    /// Upload file to Telegram using sendDocument multipart
    private func telegramSendDocument(data: Data, filename: String, mimeType: String, chatID: String, caption: String?) async {
        let token = AppConfig.telegramConfig.botToken
        guard !token.isEmpty else { return }

        let isImage = mimeType.hasPrefix("image/") && !mimeType.contains("svg")
        let endpoint = isImage ? "sendPhoto" : "sendDocument"
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(endpoint)") else { return }

        let boundary = "TorboBase-\(UUID().uuidString)"
        var body = Data()

        // chat_id field
        body.append(multipartField(name: "chat_id", value: chatID, boundary: boundary))

        // caption field
        if let caption = caption {
            body.append(multipartField(name: "caption", value: String(caption.prefix(1024)), boundary: boundary))
        }

        // file field
        let fieldName = isImage ? "photo" : "document"
        body.append(multipartFile(name: fieldName, filename: filename, mimeType: mimeType, data: data, boundary: boundary))

        // Close
        body.append(asciiData("--\(boundary)--\r\n"))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                TorboLog.error("Telegram upload failed (HTTP \(http.statusCode))", subsystem: "FileDelivery")
            } else {
                TorboLog.info("Uploaded \(filename) to Telegram chat \(chatID)", subsystem: "FileDelivery")
            }
        } catch {
            TorboLog.error("Telegram upload error: \(error.localizedDescription)", subsystem: "FileDelivery")
        }
    }

    // MARK: - Discord Native Upload

    /// Upload file to Discord using multipart attachment
    private func discordSendAttachment(data: Data, filename: String, channelID: String, caption: String?) async {
        let token = await MainActor.run { AppState.shared.discordBotToken ?? "" }
        guard !token.isEmpty, !channelID.isEmpty else { return }

        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelID)/messages") else { return }

        let boundary = "TorboBase-\(UUID().uuidString)"
        var body = Data()

        // JSON payload field (for content/caption)
        if let caption = caption {
            let payload: [String: Any] = ["content": String(caption.prefix(2000))]
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                body.append(asciiData("--\(boundary)\r\n"))
                body.append(asciiData("Content-Disposition: form-data; name=\"payload_json\"\r\n"))
                body.append(asciiData("Content-Type: application/json\r\n\r\n"))
                body.append(jsonData)
                body.append(asciiData("\r\n"))
            }
        }

        // File field
        let mimeType = FileVault.mimeType(for: filename)
        body.append(multipartFile(name: "files[0]", filename: filename, mimeType: mimeType, data: data, boundary: boundary))

        // Close
        body.append(asciiData("--\(boundary)--\r\n"))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                TorboLog.error("Discord upload failed (HTTP \(http.statusCode))", subsystem: "FileDelivery")
            } else {
                TorboLog.info("Uploaded \(filename) to Discord channel \(channelID)", subsystem: "FileDelivery")
            }
        } catch {
            TorboLog.error("Discord upload error: \(error.localizedDescription)", subsystem: "FileDelivery")
        }
    }

    // MARK: - Slack Native Upload

    /// Upload file to Slack using files.upload API
    private func slackUploadFile(data: Data, filename: String, channelID: String, caption: String?) async {
        let token = await MainActor.run { AppState.shared.slackBotToken ?? "" }
        guard !token.isEmpty else { return }

        guard let url = URL(string: "https://slack.com/api/files.upload") else { return }

        let boundary = "TorboBase-\(UUID().uuidString)"
        var body = Data()

        // channels field
        body.append(multipartField(name: "channels", value: channelID, boundary: boundary))

        // initial_comment field
        if let caption = caption {
            body.append(multipartField(name: "initial_comment", value: String(caption.prefix(4000)), boundary: boundary))
        }

        // filename field
        body.append(multipartField(name: "filename", value: filename, boundary: boundary))

        // file field
        let mimeType = FileVault.mimeType(for: filename)
        body.append(multipartFile(name: "file", filename: filename, mimeType: mimeType, data: data, boundary: boundary))

        // Close
        body.append(asciiData("--\(boundary)--\r\n"))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                TorboLog.error("Slack upload failed (HTTP \(http.statusCode))", subsystem: "FileDelivery")
            } else {
                TorboLog.info("Uploaded \(filename) to Slack channel \(channelID)", subsystem: "FileDelivery")
            }
        } catch {
            TorboLog.error("Slack upload error: \(error.localizedDescription)", subsystem: "FileDelivery")
        }
    }

    // MARK: - Helpers

    private func formatDownloadMessage(name: String, url: String, caption: String?) -> String {
        var msg = ""
        if let caption = caption { msg += caption + "\n\n" }
        msg += "📎 \(name)\n\(url)"
        return msg
    }

    /// Build a multipart text field
    private func multipartField(name: String, value: String, boundary: String) -> Data {
        var data = Data()
        data.append(asciiData("--\(boundary)\r\n"))
        data.append(asciiData("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"))
        data.append(asciiData("\(value)\r\n"))
        return data
    }

    /// Build a multipart file field
    private func multipartFile(name: String, filename: String, mimeType: String, data fileData: Data, boundary: String) -> Data {
        var data = Data()
        data.append(asciiData("--\(boundary)\r\n"))
        data.append(asciiData("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"))
        data.append(asciiData("Content-Type: \(mimeType)\r\n\r\n"))
        data.append(fileData)
        data.append(asciiData("\r\n"))
        return data
    }

    /// Safe ASCII data encoding (same pattern as Capabilities.swift)
    private func asciiData(_ string: String) -> Data {
        string.data(using: .utf8) ?? Data()
    }
}

// MARK: - Bridge Extensions for File Delivery

// Extend existing bridges with targeted send methods for file delivery routing.

extension DiscordBridge {
    /// Send a text message to a specific channel (used by file delivery for URL fallback)
    func sendToChannel(_ text: String, channelID: String) async {
        let token = await MainActor.run { AppState.shared.discordBotToken ?? "" }
        guard !token.isEmpty, !channelID.isEmpty else { return }

        guard let url = URL(string: "https://discord.com/api/v10/channels/\(channelID)/messages") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatted = BridgeFormatter.format(text, for: .discord)
        let chunks = BridgeFormatter.truncate(formatted, for: .discord)
        for chunk in chunks {
            let body: [String: Any] = ["content": chunk]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    TorboLog.error("Discord send failed (HTTP \(http.statusCode))", subsystem: "FileDelivery")
                }
            } catch {
                TorboLog.error("Discord send error: \(error)", subsystem: "FileDelivery")
            }
        }
    }
}

extension SlackBridge {
    /// Send a text message to a specific channel (used by file delivery for URL fallback)
    func sendToChannel(_ text: String, channelID: String) async {
        let token = await MainActor.run { AppState.shared.slackBotToken ?? "" }
        guard !token.isEmpty else { return }

        guard let url = URL(string: "https://slack.com/api/chat.postMessage") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatted = BridgeFormatter.format(text, for: .slack)
        let chunks = BridgeFormatter.truncate(formatted, for: .slack)
        for chunk in chunks {
            let body: [String: Any] = ["channel": channelID, "text": chunk]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (_, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    TorboLog.error("Slack send failed (HTTP \(http.statusCode))", subsystem: "FileDelivery")
                }
            } catch {
                TorboLog.error("Slack send error: \(error)", subsystem: "FileDelivery")
            }
        }
    }
}

extension WhatsAppBridge {
    /// Send a text message to a phone number (used by file delivery for URL fallback)
    func sendToPhone(_ text: String, phoneNumber: String) async {
        await send(text, to: phoneNumber)
    }
}

extension SignalBridge {
    /// Send a text message to a recipient (used by file delivery for URL fallback)
    func sendToRecipient(_ text: String, recipient: String) async {
        await send(text, to: recipient)
    }
}

extension EmailBridge {
    /// Send email with download link (file delivery fallback)
    func sendFileNotification(_ text: String, to recipient: String) async {
        await send(text, to: recipient, subject: "Torbo Base — File Ready")
    }
}
