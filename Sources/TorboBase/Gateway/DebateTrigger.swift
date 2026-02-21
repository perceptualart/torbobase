// Copyright 2026 Perceptual Art LLC. All rights reserved.
// DebateTrigger.swift — NLP-lite phrase scoring to detect decision questions.

import Foundation

enum DebateTrigger {

    private static let strongPhrases: [String] = [
        "should i", "should we", "help me decide", "help me choose",
        "pros and cons", "what do you think about", "what would you recommend",
        "which is better", "which should", "what should i", "what should we",
        "is it worth", "would you recommend", "compared to",
        "trade-offs", "tradeoffs", "advantages and disadvantages",
        "weigh in on", "give me your take on", "debate this"
    ]

    private static let mediumPhrases: [String] = [
        "what are the options", "how should i approach",
        "or should i", "alternatively", "on the other hand",
        "versus", " vs ", " v. ", "better choice",
        "pick between", "choose between", "deciding between"
    ]

    private static let weakPhrases: [String] = [
        "what if", "do you think", "would it make sense",
        "your opinion", "any thoughts", "perspective on"
    ]

    /// Returns a confidence score (0.0–1.0) indicating how likely the message
    /// is a decision question worth debating.
    static func confidence(for message: String) -> Double {
        let lower = message.lowercased()
        var score = 0.0

        for phrase in strongPhrases where lower.contains(phrase) {
            score += 0.5
        }
        for phrase in mediumPhrases where lower.contains(phrase) {
            score += 0.3
        }
        for phrase in weakPhrases where lower.contains(phrase) {
            score += 0.15
        }

        // Question mark boost
        if lower.contains("?") { score += 0.1 }

        // Length boost — longer messages tend to be more substantive
        if lower.count > 80 { score += 0.1 }

        return min(score, 1.0)
    }

    /// Returns true if the message should trigger a multi-agent debate.
    static func shouldDebate(_ message: String, threshold: Double = 0.8) -> Bool {
        confidence(for: message) >= threshold
    }
}
