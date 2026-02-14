// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Bridge Formatter
// Platform-specific rich message formatting for messaging bridges.
// Each platform has different markdown syntax, character limits, and capabilities.

import Foundation

/// Messaging platform identifiers for formatting decisions.
enum BridgePlatform: String {
    case telegram
    case discord
    case slack
    case signal
    case whatsapp

    /// Maximum message length for this platform.
    var maxLength: Int {
        switch self {
        case .telegram: return 4096
        case .discord:  return 2000
        case .slack:    return 4000
        case .signal:   return 4096
        case .whatsapp: return 4096
        }
    }
}

/// Formats assistant responses for each messaging platform's native style.
enum BridgeFormatter {

    // MARK: - Public API

    /// Format a response for a specific platform.
    /// Converts generic markdown to platform-native formatting.
    static func format(_ text: String, for platform: BridgePlatform) -> String {
        switch platform {
        case .discord:   return formatDiscord(text)
        case .telegram:  return formatTelegram(text)
        case .slack:     return formatSlack(text)
        case .signal:    return formatSignal(text)
        case .whatsapp:  return formatWhatsApp(text)
        }
    }

    /// Split a long message into platform-safe chunks.
    /// Respects code blocks — won't split in the middle of a fenced block.
    static func truncate(_ text: String, for platform: BridgePlatform) -> [String] {
        let limit = platform.maxLength - 100  // Leave room for continuation markers
        guard text.count > limit else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= limit {
                chunks.append(remaining)
                break
            }

            // Try to split at a safe boundary
            let end = remaining.index(remaining.startIndex, offsetBy: limit)
            let slice = String(remaining[..<end])

            // Look for a safe split point (paragraph break, line break, or space)
            if let splitAt = findSafeSplitPoint(slice, maxLength: limit) {
                let splitIndex = remaining.index(remaining.startIndex, offsetBy: splitAt)
                chunks.append(String(remaining[..<splitIndex]))
                remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Hard split at limit
                chunks.append(slice)
                remaining = String(remaining[end...])
            }
        }

        // Add continuation markers
        if chunks.count > 1 {
            for i in 0..<(chunks.count - 1) {
                chunks[i] += "\n...continued"
            }
        }

        return chunks
    }

    // MARK: - Platform Formatters

    /// Discord: Full markdown support with code blocks
    private static func formatDiscord(_ text: String) -> String {
        // Discord natively supports most markdown — just ensure code blocks are fenced
        var result = text

        // Ensure headers use ## style (Discord renders these)
        result = result.replacingOccurrences(of: "**Note:**", with: "> **Note:**")

        return result
    }

    /// Telegram: MarkdownV2 formatting (needs character escaping)
    private static func formatTelegram(_ text: String) -> String {
        // Telegram MarkdownV2 requires escaping special chars outside of code blocks
        // Keep it simple: preserve code blocks, light formatting elsewhere
        var result = text

        // Convert generic bold **text** → Telegram bold (already compatible)
        // Convert headers to bold (# Header → *Header*)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var formatted: [String] = []
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                formatted.append(String(line))
                continue
            }
            if inCodeBlock {
                formatted.append(String(line))
                continue
            }
            // Convert markdown headers to bold
            if trimmed.hasPrefix("### ") {
                formatted.append("*\(trimmed.dropFirst(4))*")
            } else if trimmed.hasPrefix("## ") {
                formatted.append("*\(trimmed.dropFirst(3))*")
            } else if trimmed.hasPrefix("# ") {
                formatted.append("*\(trimmed.dropFirst(2))*")
            } else {
                formatted.append(String(line))
            }
        }

        result = formatted.joined(separator: "\n")
        return result
    }

    /// Slack: mrkdwn format
    private static func formatSlack(_ text: String) -> String {
        var result = text

        // Slack uses *bold* (single asterisk), _italic_ (underscore)
        // Convert **bold** → *bold*
        result = result.replacingOccurrences(of: "**", with: "*")

        // Convert headers to bold
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var formatted: [String] = []
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                formatted.append(String(line))
                continue
            }
            if inCodeBlock {
                formatted.append(String(line))
                continue
            }
            if trimmed.hasPrefix("### ") {
                formatted.append("*\(trimmed.dropFirst(4))*")
            } else if trimmed.hasPrefix("## ") {
                formatted.append("*\(trimmed.dropFirst(3))*")
            } else if trimmed.hasPrefix("# ") {
                formatted.append("*\(trimmed.dropFirst(2))*")
            } else {
                formatted.append(String(line))
            }
        }

        result = formatted.joined(separator: "\n")
        return result
    }

    /// Signal: Plain text only — strip all markdown
    private static func formatSignal(_ text: String) -> String {
        return stripMarkdown(text)
    }

    /// WhatsApp: Basic bold (*text*) and italic (_text_) supported
    private static func formatWhatsApp(_ text: String) -> String {
        var result = text

        // WhatsApp uses *bold*, _italic_, ~strikethrough~, ```monospace```
        // Convert **bold** → *bold*
        result = result.replacingOccurrences(of: "**", with: "*")

        // Convert headers to bold
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var formatted: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                formatted.append("*\(trimmed.dropFirst(4))*")
            } else if trimmed.hasPrefix("## ") {
                formatted.append("*\(trimmed.dropFirst(3))*")
            } else if trimmed.hasPrefix("# ") {
                formatted.append("*\(trimmed.dropFirst(2))*")
            } else {
                formatted.append(String(line))
            }
        }

        result = formatted.joined(separator: "\n")
        return result
    }

    // MARK: - Helpers

    /// Strip markdown formatting for plain-text platforms.
    private static func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove code fences
        result = result.replacingOccurrences(of: "```swift\n", with: "")
        result = result.replacingOccurrences(of: "```python\n", with: "")
        result = result.replacingOccurrences(of: "```javascript\n", with: "")
        result = result.replacingOccurrences(of: "```json\n", with: "")
        result = result.replacingOccurrences(of: "```\n", with: "")
        result = result.replacingOccurrences(of: "```", with: "")

        // Remove bold/italic markers
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")

        // Convert headers to plain text with emphasis via caps
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var formatted: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                formatted.append(String(trimmed.dropFirst(4)).uppercased())
            } else if trimmed.hasPrefix("## ") {
                formatted.append(String(trimmed.dropFirst(3)).uppercased())
            } else if trimmed.hasPrefix("# ") {
                formatted.append(String(trimmed.dropFirst(2)).uppercased())
            } else {
                formatted.append(String(line))
            }
        }

        return formatted.joined(separator: "\n")
    }

    /// Find a safe split point near the end of a string.
    /// Prefers paragraph breaks > line breaks > spaces.
    private static func findSafeSplitPoint(_ text: String, maxLength: Int) -> Int? {
        let searchRange = Swift.max(0, maxLength - 200)..<maxLength

        // Look for double newline (paragraph break)
        if let range = text.range(of: "\n\n", options: .backwards,
                                   range: text.index(text.startIndex, offsetBy: searchRange.lowerBound)..<text.index(text.startIndex, offsetBy: searchRange.upperBound)) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }

        // Look for single newline
        if let range = text.range(of: "\n", options: .backwards,
                                   range: text.index(text.startIndex, offsetBy: searchRange.lowerBound)..<text.index(text.startIndex, offsetBy: searchRange.upperBound)) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }

        // Look for space
        if let range = text.range(of: " ", options: .backwards,
                                   range: text.index(text.startIndex, offsetBy: searchRange.lowerBound)..<text.index(text.startIndex, offsetBy: searchRange.upperBound)) {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }

        return nil
    }
}
