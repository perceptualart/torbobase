// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Bridge Group Filter
// Determines whether the bot should process a message in group chats.
// Prevents the bot from responding to every message in group channels —
// only responds when mentioned or in direct/private conversations.

import Foundation

/// Filters incoming messages to determine if the bot should respond.
/// In group chats, requires an @mention or keyword trigger.
/// In DMs/private chats, always responds.
enum BridgeGroupFilter {

    /// Result of processing a message through the filter.
    struct FilterResult {
        let shouldProcess: Bool
        let cleanedText: String  // Text with bot mention stripped
    }

    // MARK: - Public API

    /// Check if a message should be processed by the bot.
    ///
    /// - Parameters:
    ///   - text: The raw message text
    ///   - platform: Which messaging platform
    ///   - isDirectMessage: Whether this is a DM (private chat) vs group
    ///   - botIdentifier: The bot's username/ID on the platform (for mention detection)
    ///   - payload: Optional raw platform payload for additional context
    /// - Returns: FilterResult with shouldProcess flag and cleaned text
    static func filter(
        text: String,
        platform: BridgePlatform,
        isDirectMessage: Bool,
        botIdentifier: String = "",
        payload: [String: Any]? = nil
    ) -> FilterResult {
        // Always process direct messages
        if isDirectMessage {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        // Platform-specific group filtering
        switch platform {
        case .telegram:
            return filterTelegram(text: text, botUsername: botIdentifier)
        case .discord:
            return filterDiscord(text: text, botID: botIdentifier, payload: payload)
        case .slack:
            return filterSlack(text: text, botID: botIdentifier)
        case .signal:
            // Signal doesn't have reliable mention detection — process all
            return FilterResult(shouldProcess: true, cleanedText: text)
        case .whatsapp:
            return filterWhatsApp(text: text)
        case .imessage, .email, .sms:
            // Inherently 1:1 — always process
            return FilterResult(shouldProcess: true, cleanedText: text)
        case .teams:
            // Teams uses @mention in entities — handled by TeamsBridge before reaching filter
            if containsTriggerKeyword(text) {
                return FilterResult(shouldProcess: true, cleanedText: text)
            }
            return FilterResult(shouldProcess: false, cleanedText: text)
        case .googlechat:
            // Google Chat uses annotations for mentions — handled by GoogleChatBridge
            if containsTriggerKeyword(text) {
                return FilterResult(shouldProcess: true, cleanedText: text)
            }
            return FilterResult(shouldProcess: false, cleanedText: text)
        case .matrix:
            // Check for @bot:server mention in body
            if !botIdentifier.isEmpty && text.contains(botIdentifier) {
                let cleaned = text.replacingOccurrences(of: botIdentifier, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return FilterResult(shouldProcess: true, cleanedText: cleaned)
            }
            if containsTriggerKeyword(text) {
                return FilterResult(shouldProcess: true, cleanedText: text)
            }
            return FilterResult(shouldProcess: false, cleanedText: text)
        }
    }

    // MARK: - Platform Filters

    /// Telegram: Check for @botUsername mention or /command
    private static func filterTelegram(text: String, botUsername: String) -> FilterResult {
        // Check for @mention
        if !botUsername.isEmpty {
            let mention = "@\(botUsername)"
            if text.contains(mention) {
                let cleaned = text.replacingOccurrences(of: mention, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return FilterResult(shouldProcess: true, cleanedText: cleaned)
            }
        }

        // Check for /commands (always process these)
        if text.hasPrefix("/") {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        // Check for keyword triggers
        if containsTriggerKeyword(text) {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        return FilterResult(shouldProcess: false, cleanedText: text)
    }

    /// Discord: Check for @mention in message or mentions array
    private static func filterDiscord(text: String, botID: String, payload: [String: Any]?) -> FilterResult {
        // Check mentions array in Discord payload
        if let mentions = payload?["mentions"] as? [[String: Any]] {
            for mention in mentions {
                if let id = mention["id"] as? String, id == botID {
                    // Strip <@botID> from text
                    let cleaned = text
                        .replacingOccurrences(of: "<@\(botID)>", with: "")
                        .replacingOccurrences(of: "<@!\(botID)>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return FilterResult(shouldProcess: true, cleanedText: cleaned)
                }
            }
        }

        // Fallback: check for text mentions
        if !botID.isEmpty && (text.contains("<@\(botID)>") || text.contains("<@!\(botID)>")) {
            let cleaned = text
                .replacingOccurrences(of: "<@\(botID)>", with: "")
                .replacingOccurrences(of: "<@!\(botID)>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FilterResult(shouldProcess: true, cleanedText: cleaned)
        }

        // Check keyword triggers
        if containsTriggerKeyword(text) {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        return FilterResult(shouldProcess: false, cleanedText: text)
    }

    /// Slack: Check for <@BOT_ID> mention
    private static func filterSlack(text: String, botID: String) -> FilterResult {
        if !botID.isEmpty && text.contains("<@\(botID)>") {
            let cleaned = text
                .replacingOccurrences(of: "<@\(botID)>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FilterResult(shouldProcess: true, cleanedText: cleaned)
        }

        // Check keyword triggers
        if containsTriggerKeyword(text) {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        return FilterResult(shouldProcess: false, cleanedText: text)
    }

    /// WhatsApp: Keyword trigger in groups
    private static func filterWhatsApp(text: String) -> FilterResult {
        // Check keyword triggers for group messages
        if containsTriggerKeyword(text) {
            return FilterResult(shouldProcess: true, cleanedText: text)
        }

        return FilterResult(shouldProcess: false, cleanedText: text)
    }

    // MARK: - Keyword Triggers

    /// Default trigger keywords that activate the bot in group chats.
    /// These are case-insensitive prefixes.
    private static let triggerKeywords = [
        "torbo", "sid", "hey sid", "hey torbo",
        "@torbo", "@sid"
    ]

    /// Check if the message starts with a trigger keyword.
    private static func containsTriggerKeyword(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return triggerKeywords.contains { lower.hasPrefix($0) }
    }
}
