// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Commitments Detector
// Two-tier detection: fast regex pre-filter + local LLM extraction via Ollama.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of commitment extraction from a user message.
struct ExtractedCommitment: Sendable {
    let text: String
    let dueText: String?
    let dueDate: Date?
    let priority: String  // "high", "medium", "low"
}

/// Resolution intent detected in a user message ("done", "forget it", etc.)
struct ResolutionIntent: Sendable {
    let action: Commitment.Status  // .resolved or .dismissed
    let triggerText: String
}

/// Two-tier commitment detection: fast regex pre-filter + LLM extraction.
enum CommitmentsDetector {

    // MARK: - Tier 1: Fast Regex Pre-Filter (nonisolated, sync)

    /// Quick check whether a message likely contains a commitment.
    /// Cheap enough to run on every message.
    nonisolated static func likelyContainsCommitment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "i'll ", "i will ", "i'm going to ", "i am going to ",
            "i need to ", "i have to ", "i must ", "i should ",
            "i promise ", "i commit to ", "i plan to ",
            "remind me to ", "don't let me forget ",
            "by tomorrow", "by friday", "by monday", "by next week",
            "by end of day", "by eod", "by tonight",
            "deadline", "due date"
        ]
        return patterns.contains(where: { lower.contains($0) })
    }

    /// Quick check for resolution language ("done", "finished", "forget it", etc.)
    nonisolated static func detectResolution(_ text: String) -> ResolutionIntent? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "Done" patterns
        let donePatterns = [
            "i did it", "i finished", "that's done", "it's done",
            "completed it", "i've done", "already done", "took care of",
            "handled it", "all done", "mission accomplished"
        ]
        for p in donePatterns {
            if lower.contains(p) {
                return ResolutionIntent(action: .resolved, triggerText: p)
            }
        }

        // "Forget it" patterns
        let dismissPatterns = [
            "forget it", "never mind", "nevermind", "skip it",
            "don't worry about", "not going to", "cancelled",
            "no longer need", "scratch that", "drop it"
        ]
        for p in dismissPatterns {
            if lower.contains(p) {
                return ResolutionIntent(action: .dismissed, triggerText: p)
            }
        }

        return nil
    }

    // MARK: - Tier 2: LLM Extraction (async, uses Ollama)

    /// Extract structured commitments from a user message using local LLM.
    static func extractCommitments(from text: String) async -> [ExtractedCommitment] {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let prompt = """
        You are a commitment extractor. Analyze this message and extract any promises, \
        plans, or commitments the user is making. Return JSON only.

        Today's date: \(today)

        Message: "\(text)"

        Return a JSON array of commitments. Each commitment has:
        - "text": what the user committed to (short, clear phrase)
        - "due_text": when it's due in the user's words (or null)
        - "due_date": ISO 8601 date if determinable (or null)
        - "priority": "high", "medium", or "low"

        If no commitments found, return [].

        Examples:
        "I'll finish the report by Friday" → [{"text":"finish the report","due_text":"by Friday","due_date":"2026-02-20","priority":"medium"}]
        "I need to call mom tomorrow" → [{"text":"call mom","due_text":"tomorrow","due_date":"2026-02-21","priority":"medium"}]
        "What's the weather?" → []

        JSON only, no explanation:
        """

        let body: [String: Any] = [
            "model": "llama3.2:3b",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 512]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: OllamaManager.baseURL + "/api/generate") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                return []
            }

            return parseExtractedCommitments(responseText)
        } catch {
            TorboLog.debug("Commitment extraction failed: \(error.localizedDescription)", subsystem: "Commitments")
            return []
        }
    }

    // MARK: - Parsing

    private static func parseExtractedCommitments(_ text: String) -> [ExtractedCommitment] {
        // Strip markdown code fences if present
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let isoFmt = ISO8601DateFormatter()
        // Also try date-only format
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        return array.compactMap { item -> ExtractedCommitment? in
            guard let commitText = item["text"] as? String, !commitText.isEmpty else { return nil }
            let dueText = item["due_text"] as? String
            let priority = item["priority"] as? String ?? "medium"

            var dueDate: Date?
            if let dueDateStr = item["due_date"] as? String {
                dueDate = isoFmt.date(from: dueDateStr) ?? dateFmt.date(from: dueDateStr)
            }

            return ExtractedCommitment(text: commitText, dueText: dueText, dueDate: dueDate, priority: priority)
        }
    }
}
