// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Channel Manager
// ChannelManager.swift — Orchestrates all messaging bridges
// Unified interface for multi-channel messaging (11 channels)

import Foundation

// MARK: - Channel Configuration (stored in channels.json)

struct ChannelConfig: Codable {
    // Discord
    var discordBotToken: String?
    var discordChannelID: String?

    // Slack
    var slackBotToken: String?
    var slackChannelID: String?
    var slackBotUserID: String?

    // WhatsApp Business
    var whatsappAccessToken: String?
    var whatsappPhoneNumberID: String?
    var whatsappVerifyToken: String?

    // Signal (via signal-cli REST API)
    var signalPhoneNumber: String?
    var signalAPIURL: String?

    // iMessage (via AppleScript on macOS)
    var imessageEnabled: Bool?
    var imessageRecipient: String?

    // Email (IMAP/SMTP or macOS Mail.app)
    var emailFromAddress: String?
    var emailSmtpHost: String?
    var emailSmtpPort: Int?
    var emailSmtpUser: String?
    var emailSmtpPass: String?

    // Microsoft Teams
    var teamsAppID: String?
    var teamsAppSecret: String?

    // Google Chat
    var googleChatServiceAccountKey: String?

    // Matrix
    var matrixHomeserver: String?
    var matrixAccessToken: String?
    var matrixBotUserID: String?

    // SMS (Twilio)
    var twilioAccountSID: String?
    var twilioAuthToken: String?
    var twilioPhoneNumber: String?

    static var empty: ChannelConfig { ChannelConfig() }
}

// MARK: - Channel Manager

actor ChannelManager {
    static let shared = ChannelManager()

    enum Channel: String, CaseIterable {
        case telegram
        case discord
        case slack
        case whatsapp
        case signal
        case imessage
        case email
        case teams
        case googlechat
        case matrix
        case sms
    }

    private var activeChannels: Set<Channel> = []
    private let configPath = PlatformPaths.dataDir + "/channels.json"

    // MARK: - Initialization

    func initialize() async {
        let config = loadConfig()
        TorboLog.info("Initializing messaging bridges...", subsystem: "Channels")

        // Telegram (already handled by TelegramBridge in startup)
        let telegramEnabled = await MainActor.run {
            !AppState.shared.telegramConfig.botToken.isEmpty
        }
        if telegramEnabled { activeChannels.insert(.telegram) }

        // Discord
        if let token = config.discordBotToken, !token.isEmpty,
           let channel = config.discordChannelID, !channel.isEmpty {
            await MainActor.run {
                AppState.shared.discordBotToken = token
                AppState.shared.discordChannelID = channel
            }
            Task { await DiscordBridge.shared.startPolling() }
            activeChannels.insert(.discord)
            TorboLog.info("Discord bridge started", subsystem: "Channels")
        }

        // Slack
        if let token = config.slackBotToken, !token.isEmpty,
           let channel = config.slackChannelID, !channel.isEmpty {
            await MainActor.run {
                AppState.shared.slackBotToken = token
                AppState.shared.slackChannelID = channel
                AppState.shared.slackBotUserID = config.slackBotUserID
            }
            Task { await SlackBridge.shared.startPolling() }
            activeChannels.insert(.slack)
            TorboLog.info("Slack bridge started", subsystem: "Channels")
        }

        // WhatsApp (webhook-based)
        if let token = config.whatsappAccessToken, !token.isEmpty,
           let phoneID = config.whatsappPhoneNumberID, !phoneID.isEmpty {
            await MainActor.run {
                AppState.shared.whatsappAccessToken = token
                AppState.shared.whatsappPhoneNumberID = phoneID
                AppState.shared.whatsappVerifyToken = config.whatsappVerifyToken
            }
            activeChannels.insert(.whatsapp)
            TorboLog.info("WhatsApp bridge ready (webhook-based)", subsystem: "Channels")
        }

        // Signal (via signal-cli REST)
        if let phone = config.signalPhoneNumber, !phone.isEmpty,
           let apiURL = config.signalAPIURL, !apiURL.isEmpty {
            await MainActor.run {
                AppState.shared.signalPhoneNumber = phone
                AppState.shared.signalAPIURL = apiURL
            }
            Task { await SignalBridge.shared.startPolling() }
            activeChannels.insert(.signal)
            TorboLog.info("Signal bridge started", subsystem: "Channels")
        }

        // iMessage (macOS only)
        #if os(macOS)
        if config.imessageEnabled == true {
            await iMessageBridge.shared.configure(
                enabled: true,
                recipient: config.imessageRecipient ?? ""
            )
            Task { await iMessageBridge.shared.startPolling() }
            activeChannels.insert(.imessage)
            TorboLog.info("iMessage bridge started", subsystem: "Channels")
        }
        #endif

        // Email
        if let fromAddr = config.emailFromAddress, !fromAddr.isEmpty {
            var emailCfg = EmailBridge.EmailConfig()
            emailCfg.fromAddress = fromAddr
            emailCfg.smtpHost = config.emailSmtpHost ?? ""
            emailCfg.smtpPort = config.emailSmtpPort ?? 587
            emailCfg.smtpUser = config.emailSmtpUser ?? ""
            emailCfg.smtpPass = config.emailSmtpPass ?? ""
            await EmailBridge.shared.configure(emailCfg)
            Task { await EmailBridge.shared.startPolling() }
            activeChannels.insert(.email)
            TorboLog.info("Email bridge started", subsystem: "Channels")
        }

        // Microsoft Teams
        if let appID = config.teamsAppID, !appID.isEmpty,
           let appSecret = config.teamsAppSecret, !appSecret.isEmpty {
            await TeamsBridge.shared.configure(appID: appID, appSecret: appSecret)
            activeChannels.insert(.teams)
            TorboLog.info("Teams bridge ready (webhook-based)", subsystem: "Channels")
        }

        // Google Chat
        if let key = config.googleChatServiceAccountKey, !key.isEmpty {
            await GoogleChatBridge.shared.configure(serviceAccountKey: key)
            activeChannels.insert(.googlechat)
            TorboLog.info("Google Chat bridge ready (webhook-based)", subsystem: "Channels")
        }

        // Matrix
        if let hs = config.matrixHomeserver, !hs.isEmpty,
           let token = config.matrixAccessToken, !token.isEmpty {
            await MatrixBridge.shared.configure(
                homeserver: hs,
                accessToken: token,
                botUserID: config.matrixBotUserID ?? ""
            )
            Task { await MatrixBridge.shared.startPolling() }
            activeChannels.insert(.matrix)
            TorboLog.info("Matrix bridge started", subsystem: "Channels")
        }

        // SMS (Twilio)
        if let sid = config.twilioAccountSID, !sid.isEmpty,
           let authToken = config.twilioAuthToken, !authToken.isEmpty,
           let phone = config.twilioPhoneNumber, !phone.isEmpty {
            await SMSBridge.shared.configure(
                accountSID: sid, authToken: authToken, phoneNumber: phone
            )
            activeChannels.insert(.sms)
            TorboLog.info("SMS bridge ready (webhook-based)", subsystem: "Channels")
        }

        TorboLog.info("Active: \(activeChannels.map { $0.rawValue }.sorted().joined(separator: ", ")) (\(activeChannels.count) channel(s))", subsystem: "Channels")
    }

    // MARK: - Broadcast

    /// Send a message to all active channels
    func broadcast(_ message: String) async {
        for channel in activeChannels {
            switch channel {
            case .telegram:
                await TelegramBridge.shared.send(message)
            case .discord:
                await DiscordBridge.shared.send(message)
            case .slack:
                await SlackBridge.shared.send(message)
            case .whatsapp:
                break // WhatsApp needs a recipient phone — skip for broadcast
            case .signal:
                await SignalBridge.shared.send(message)
            case .imessage:
                await iMessageBridge.shared.notify(message)
            case .email:
                await EmailBridge.shared.notify(message)
            case .teams:
                await TeamsBridge.shared.notify(message)
            case .googlechat:
                await GoogleChatBridge.shared.notify(message)
            case .matrix:
                await MatrixBridge.shared.notify(message)
            case .sms:
                await SMSBridge.shared.notify(message)
            }
        }
    }

    /// Send a notification to all channels
    func notifyAll(_ message: String) async {
        for channel in activeChannels {
            switch channel {
            case .telegram: await TelegramBridge.shared.notify(message)
            case .discord: await DiscordBridge.shared.notify(message)
            case .slack: await SlackBridge.shared.notify(message)
            case .whatsapp: break
            case .signal: await SignalBridge.shared.notify(message)
            case .imessage: await iMessageBridge.shared.notify(message)
            case .email: await EmailBridge.shared.notify(message)
            case .teams: await TeamsBridge.shared.notify(message)
            case .googlechat: await GoogleChatBridge.shared.notify(message)
            case .matrix: await MatrixBridge.shared.notify(message)
            case .sms: await SMSBridge.shared.notify(message)
            }
        }
    }

    // MARK: - Status

    func status() -> [String: Any] {
        let channels = Channel.allCases.map { channel -> [String: Any] in
            ["name": channel.rawValue, "active": activeChannels.contains(channel)]
        }
        return [
            "active_count": activeChannels.count,
            "channels": channels
        ]
    }

    // MARK: - Config Persistence

    func loadConfig() -> ChannelConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(ChannelConfig.self, from: data) else {
            createTemplateConfig()
            return .empty
        }
        return config
    }

    private func createTemplateConfig() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let template = ChannelConfig(
            discordBotToken: "",
            discordChannelID: "",
            slackBotToken: "",
            slackChannelID: "",
            slackBotUserID: "",
            whatsappAccessToken: "",
            whatsappPhoneNumberID: "",
            whatsappVerifyToken: "orb_verify_\(UUID().uuidString.prefix(8))",
            signalPhoneNumber: "",
            signalAPIURL: "http://localhost:8080"
        )

        if let data = try? JSONEncoder().encode(template) {
            do {
                try data.write(to: URL(fileURLWithPath: configPath))
                TorboLog.info("Created template config at \(configPath)", subsystem: "Channels")
            } catch {
                TorboLog.error("Failed to write channel config: \(error)", subsystem: "Channels")
            }
        }
    }

    func saveConfig(_ config: ChannelConfig) {
        if let data = try? JSONEncoder().encode(config) {
            do {
                try data.write(to: URL(fileURLWithPath: configPath))
            } catch {
                TorboLog.error("Failed to write channel config: \(error)", subsystem: "Channels")
            }
        }
    }
}
