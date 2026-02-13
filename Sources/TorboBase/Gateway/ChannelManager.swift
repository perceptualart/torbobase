// Torbo Base — Channel Manager
// ChannelManager.swift — Orchestrates all messaging bridges
// Unified interface for multi-channel messaging (Telegram, Discord, Slack, WhatsApp, Signal)

import Foundation

// MARK: - Channel Configuration (stored in AppState)

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
    var signalAPIURL: String?       // e.g., http://localhost:8080

    // iMessage (via AppleScript on macOS)
    var imessageEnabled: Bool?
    var imessageRecipient: String?  // Phone or email to watch

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
    }

    private var activeChannels: Set<Channel> = []
    private let configPath = NSHomeDirectory() + "/Library/Application Support/TorboBase/channels.json"

    // MARK: - Initialization

    func initialize() async {
        let config = loadConfig()
        print("[Channels] Initializing messaging bridges...")

        // Telegram (already handled by TelegramBridge in startup)
        // Just track its status
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
            print("[Channels] Discord bridge started")
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
            print("[Channels] Slack bridge started")
        }

        // WhatsApp (webhook-based — needs external webhook forwarding)
        if let token = config.whatsappAccessToken, !token.isEmpty,
           let phoneID = config.whatsappPhoneNumberID, !phoneID.isEmpty {
            await MainActor.run {
                AppState.shared.whatsappAccessToken = token
                AppState.shared.whatsappPhoneNumberID = phoneID
                AppState.shared.whatsappVerifyToken = config.whatsappVerifyToken
            }
            activeChannels.insert(.whatsapp)
            print("[Channels] WhatsApp bridge ready (webhook-based)")
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
            print("[Channels] Signal bridge started")
        }

        print("[Channels] Active: \(activeChannels.map { $0.rawValue }.sorted().joined(separator: ", ")) (\(activeChannels.count) channel(s))")
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
                break // iMessage needs a recipient — skip for broadcast
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
            case .imessage: break
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

    private func loadConfig() -> ChannelConfig {
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
            try? data.write(to: URL(fileURLWithPath: configPath))
            print("[Channels] Created template config at \(configPath)")
        }
    }

    func saveConfig(_ config: ChannelConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }
}
