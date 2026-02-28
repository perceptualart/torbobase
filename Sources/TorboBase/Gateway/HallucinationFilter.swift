// Torbo Base
// HallucinationFilter.swift — Strips known LLM hallucination patterns from responses
//
// Despite system prompt instructions, LLMs (especially Claude) sometimes output
// trained behaviors from their web UI: canvas markers, bracket action labels,
// citation brackets, and other artifacts. This filter catches them at the stream
// level before they reach the client.

import Foundation

enum HallucinationFilter {

    // MARK: - Patterns (compiled once)

    /// Regex patterns to strip from LLM output, ordered from most specific to least
    private static let patterns: [(regex: NSRegularExpression, replacement: String)] = {
        let defs: [(String, String)] = [
            // Canvas/Artifacts markers
            (#"\[/?canvas\]"#, ""),
            (#"\[canvas:[^\]]*\]"#, ""),
            // "Canvas is locked/unavailable/broken" hallucinated messages
            (#"Canvas is (still )?(locked|unavailable|not available|currently locked|currently unavailable|rejecting|not (accepting|cooperating|responding|working))[^.]*\.?\s*"#, ""),
            (#"I (can't|cannot|don't have access to|am unable to) (update|edit|modify|use|access|open|get anything to stick in) (the |a |my )?canvas[^.]*\.?\s*"#, ""),
            // "Base isn't cooperating/passing payload" confabulation
            (#"Base (isn't|is not|won't|will not) (cooperating|passing|forwarding|delivering|accepting|responding)[^.]*\.?\s*"#, ""),
            (#"(the |this )?(payload|content|data) (isn't|is not) (getting|being|going) through[^.]*\.?\s*"#, ""),
            // "Flagged for X / on the roadmap" fabrication
            (#"I'(ve|ll) (flagged|flag) (this|it) for \w+[^.]*\.?\s*"#, ""),
            (#"(It's|That's|This is) on the roadmap[^.]*\.?\s*"#, ""),
            (#"\w+ is (working on|investigating|looking into) (it|this|that|the)[^.]*\.?\s*"#, ""),
            // "Same issue/wall/problem as before" learned helplessness
            (#"Same (issue|wall|problem|error) (as|we've been hitting|from) before[^.]*\.?\s*"#, ""),
            // Bracket action markers (trained behavior from tool-use UIs)
            (#"\[(writing|searching|reading|browsing|thinking|analyzing|executing|running|processing|creating|updating|editing|generating|fetching|loading|saving|downloading|uploading|rendering|compiling|building|deploying|installing|configuring|looking|checking|calculating|evaluating|reviewing|examining|inspecting|scanning|monitoring|preparing|formatting|converting|extracting|parsing|indexing|querying|requesting|connecting|initializing|starting|stopping|opening|closing)\s*:?\s*[^\]]*\]"#, ""),
            // Fullwidth bracket citations 【1】【source】
            (#"【[^】]*】"#, ""),
            // Leaked internal XML tags
            (#"<antThinking>[\s\S]*?</antThinking>"#, ""),
            (#"</?antThinking>"#, ""),
            (#"<antArtifact[^>]*>[\s\S]*?</antArtifact>"#, ""),
            (#"</?antArtifact[^>]*>"#, ""),
        ]
        return defs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                TorboLog.error("HallucinationFilter: failed to compile pattern: \(pattern)", subsystem: "Gateway")
                return nil
            }
            return (regex, replacement)
        }
    }()

    // MARK: - Public API

    /// Filter a streaming text delta. Returns cleaned text (may be empty if entire delta was hallucinated).
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (regex, replacement) in patterns {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        // Collapse any resulting double-spaces or leading/trailing whitespace artifacts
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    /// Filter accumulated full response text (can handle multi-line patterns).
    /// Same as clean() but also trims any leading/trailing whitespace left behind.
    static func cleanFull(_ text: String) -> String {
        var result = clean(text)
        // Trim lines that became empty after filtering
        let lines = result.components(separatedBy: "\n")
        let cleaned = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty || $0.isEmpty }
        result = cleaned.joined(separator: "\n")
        // Remove leading newlines left by stripped content
        while result.hasPrefix("\n") { result = String(result.dropFirst()) }
        return result
    }

    /// Quick check if text contains any hallucination patterns (useful for logging)
    static func containsHallucination(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for (regex, _) in patterns {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
