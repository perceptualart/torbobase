// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Deep Research Engine
// Autonomous multi-step research: plan → search → triage → read → extract → synthesize → finalize
// No CLI dependencies — uses existing WebSearchEngine + web fetching.
// Tool: deep_research

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor DeepResearchEngine {
    static let shared = DeepResearchEngine()

    // MARK: - Research

    /// Perform autonomous multi-step research on a topic.
    /// Depths: quick (3 searches), standard (8), deep (15)
    func research(topic: String, depth: String = "standard", apiKeys: [String: String] = [:]) async -> String {
        let searchCount: Int
        let readCount: Int

        switch depth.lowercased() {
        case "quick": searchCount = 3; readCount = 5
        case "deep": searchCount = 15; readCount = 20
        default: searchCount = 8; readCount = 12  // standard
        }

        await publishProgress("Starting research on: \(topic)")

        // STEP 1: PLAN — Generate search queries
        await publishProgress("Planning search strategy...")
        let queries = await planSearchQueries(topic: topic, count: searchCount, apiKeys: apiKeys)

        guard !queries.isEmpty else {
            return "Error: Could not generate search queries for topic"
        }

        // STEP 2: SEARCH — Execute all queries
        await publishProgress("Searching (\(queries.count) queries)...")
        var allResults: [(query: String, results: String)] = []

        for (i, query) in queries.enumerated() {
            let searchResult = await WebSearchEngine.shared.search(query: query)
            allResults.append((query: query, results: searchResult))
            if i % 3 == 0 {
                await publishProgress("Searched \(i + 1)/\(queries.count)...")
            }
        }

        // STEP 3: TRIAGE — Select URLs to read in detail
        await publishProgress("Triaging results...")
        let urlsToRead = await triageResults(topic: topic, searchResults: allResults, maxURLs: readCount, apiKeys: apiKeys)

        // STEP 4: READ — Fetch selected URLs
        await publishProgress("Reading \(urlsToRead.count) sources...")
        var pageContents: [(url: String, content: String)] = []

        for (i, url) in urlsToRead.enumerated() {
            let content = await WebSearchEngine.shared.fetchPage(url: url)
            if !content.isEmpty && !content.hasPrefix("Error") {
                // Truncate very long pages
                let trimmed = String(content.prefix(10000))
                pageContents.append((url: url, content: trimmed))
            }
            if i % 4 == 0 {
                await publishProgress("Read \(i + 1)/\(urlsToRead.count) pages...")
            }
        }

        guard !pageContents.isEmpty else {
            // Fall back to search results only
            return await synthesizeFromSearchResults(topic: topic, results: allResults, apiKeys: apiKeys)
        }

        // STEP 5: EXTRACT — Process each page for relevant facts
        await publishProgress("Extracting key information...")
        var extractedFacts: [(url: String, facts: String)] = []

        for page in pageContents {
            let facts = await extractFacts(topic: topic, url: page.url, content: page.content, apiKeys: apiKeys)
            if !facts.isEmpty {
                extractedFacts.append((url: page.url, facts: facts))
            }
        }

        // STEP 6: SYNTHESIZE — Produce comprehensive report
        await publishProgress("Synthesizing report...")
        let report = await synthesizeReport(topic: topic, facts: extractedFacts, apiKeys: apiKeys)

        // STEP 7: FINALIZE — Save to FileVault
        await publishProgress("Finalizing report...")
        let filename = "research_\(sanitizeFilename(topic))_\(UUID().uuidString.prefix(8)).md"
        let reportData = Data(report.utf8)

        guard let entry = await FileVault.shared.store(data: reportData, originalName: filename, mimeType: "text/markdown", expiresIn: 86400) else {
            // Return report inline if FileVault fails
            return report
        }

        // Store key findings in LoA memory
        await storeKeyFindings(topic: topic, report: report)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)

        await publishProgress("Research complete!")
        return "Research complete on: \(topic)\n\nFull report: \(url)\n\n" + extractSummary(from: report)
    }

    // MARK: - Steps

    private func planSearchQueries(topic: String, count: Int, apiKeys: [String: String]) async -> [String] {
        let systemPrompt = """
        Generate exactly \(count) diverse search queries to thoroughly research the topic.
        Cover different angles: definitions, recent developments, expert opinions, data/statistics, controversies, future outlook.
        Output one query per line. No numbering, no explanation.
        """

        let response = await callLLM(system: systemPrompt, user: topic, apiKeys: apiKeys)
        let queries = response.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 5 }

        if queries.isEmpty {
            // Fallback: generate basic queries from topic
            return [topic, "\(topic) latest news 2026", "\(topic) research review"]
        }

        return Array(queries.prefix(count))
    }

    private func triageResults(topic: String, searchResults: [(query: String, results: String)], maxURLs: Int, apiKeys: [String: String]) async -> [String] {
        // Extract URLs from search results
        var allURLs: [String] = []
        for result in searchResults {
            // Parse URLs from search result text (look for http:// or https://)
            let words = result.results.split(separator: " ").map(String.init) +
                        result.results.split(separator: "\n").map(String.init)
            for word in words {
                let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>,"))
                if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                    if !allURLs.contains(trimmed) {
                        allURLs.append(trimmed)
                    }
                }
            }
        }

        // If we don't have enough URLs from parsing, ask LLM to extract them
        if allURLs.count < 3 {
            let combined = searchResults.map { "Query: \($0.query)\nResults: \(String($0.results.prefix(2000)))" }.joined(separator: "\n\n---\n\n")
            let response = await callLLM(
                system: "Extract all URLs from these search results. Output one URL per line. No explanation.",
                user: combined.prefix(8000).description,
                apiKeys: apiKeys
            )
            let parsed = response.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("http") }
            allURLs.append(contentsOf: parsed)
        }

        // Deduplicate and limit
        var seen = Set<String>()
        var unique: [String] = []
        for url in allURLs {
            if !seen.contains(url) {
                seen.insert(url)
                unique.append(url)
            }
        }

        return Array(unique.prefix(maxURLs))
    }

    private func extractFacts(topic: String, url: String, content: String, apiKeys: [String: String]) async -> String {
        let systemPrompt = """
        Extract the most relevant facts, data points, quotes, and key information about "\(topic)" from this web page.
        Be specific — include numbers, dates, names, and direct quotes where available.
        Cite the source URL at the end: [Source: \(url)]
        Output as bullet points. Skip irrelevant content.
        """

        return await callLLM(system: systemPrompt, user: String(content.prefix(8000)), apiKeys: apiKeys)
    }

    private func synthesizeReport(topic: String, facts: [(url: String, facts: String)], apiKeys: [String: String]) async -> String {
        let factsBlock = facts.enumerated().map { i, f in
            "--- Source \(i + 1): \(f.url) ---\n\(f.facts)"
        }.joined(separator: "\n\n")

        let systemPrompt = """
        You are a research analyst. Synthesize the extracted information into a comprehensive, well-structured research report.

        Structure:
        # Research Report: \(topic)

        ## Executive Summary
        (2-3 sentences overview)

        ## Key Findings
        (3-5 bullet points of the most important discoveries)

        ## Detailed Analysis
        (Multiple sections with headers covering different aspects of the topic)
        (Use inline citations like [1], [2] referring to the source bibliography)

        ## Sources
        (Numbered list of all source URLs used)

        Write in a professional, objective tone. Be thorough but concise. Target 2000-5000 words.
        """

        return await callLLM(system: systemPrompt, user: factsBlock, apiKeys: apiKeys)
    }

    private func synthesizeFromSearchResults(topic: String, results: [(query: String, results: String)], apiKeys: [String: String]) async -> String {
        let combined = results.map { "Query: \($0.query)\nResults: \(String($0.results.prefix(2000)))" }.joined(separator: "\n\n")

        let systemPrompt = """
        Synthesize these search results into a research summary about "\(topic)".
        Include key findings, relevant data, and cite sources where visible.
        Structure with headers: Executive Summary, Key Findings, Details, Sources.
        """

        return await callLLM(system: systemPrompt, user: combined, apiKeys: apiKeys)
    }

    // MARK: - Progress

    private func publishProgress(_ message: String) async {
        await EventBus.shared.publish("research.progress",
            payload: ["message": message],
            source: "DeepResearch")
        TorboLog.info(message, subsystem: "Research")
    }

    // MARK: - LoA Integration

    private func storeKeyFindings(topic: String, report: String) async {
        // Extract first 500 chars of findings section for LoA
        let findings: String
        if let range = report.range(of: "## Key Findings") {
            let after = report[range.upperBound...]
            if let nextSection = after.range(of: "\n##") {
                findings = String(after[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                findings = String(after.prefix(500))
            }
        } else {
            findings = String(report.prefix(500))
        }

        let memoryText = "Research on \(topic): \(findings)"
        await MemoryIndex.shared.add(
            text: String(memoryText.prefix(2000)),
            category: "fact",
            source: "deep-research",
            importance: 0.6
        )
    }

    // MARK: - Helpers

    private func extractSummary(from report: String) -> String {
        // Extract executive summary and key findings for inline display
        var summary = ""

        if let execRange = report.range(of: "## Executive Summary") {
            let after = report[execRange.upperBound...]
            if let nextSection = after.range(of: "\n##") {
                summary += String(after[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                summary += String(after.prefix(500))
            }
        }

        if let findingsRange = report.range(of: "## Key Findings") {
            let after = report[findingsRange.upperBound...]
            if let nextSection = after.range(of: "\n##") {
                summary += "\n\n**Key Findings:**\n" + String(after[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return summary.isEmpty ? String(report.prefix(1000)) : summary
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return String(String(cleaned.unicodeScalars.filter { allowed.contains($0) }).prefix(40))
    }

    // MARK: - LLM Call

    private func callLLM(system: String, user: String, apiKeys: [String: String]) async -> String {
        // Try Ollama first
        let ollamaResult = await callOllama(system: system, user: user)
        if !ollamaResult.isEmpty { return ollamaResult }

        // Cloud fallback
        if let key = apiKeys["ANTHROPIC_API_KEY"] ?? KeychainManager.get("apikey.ANTHROPIC_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "anthropic", apiKey: key)
        }
        if let key = apiKeys["OPENAI_API_KEY"] ?? KeychainManager.get("apikey.OPENAI_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "openai", apiKey: key)
        }
        return ""
    }

    private func callOllama(system: String, user: String) async -> String {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = ["model": "qwen2.5:7b", "system": system, "prompt": String(user.prefix(16000)), "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String { return response }
        } catch {}
        return ""
    }

    private func callCloud(system: String, user: String, provider: String, apiKey: String) async -> String {
        if provider == "anthropic" {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let body: [String: Any] = [
                "model": "claude-sonnet-4-20250514", "max_tokens": 8192,
                "system": system, "messages": [["role": "user", "content": String(user.prefix(32000))]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String { return text }
            } catch {}
        } else {
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let body: [String: Any] = [
                "model": "gpt-4o",
                "messages": [["role": "system", "content": system], ["role": "user", "content": String(user.prefix(32000))]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let text = msg["content"] as? String { return text }
            } catch {}
        }
        return ""
    }

    // MARK: - Tool Definition

    static let deepResearchToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "deep_research",
            "description": "Perform autonomous multi-step deep research on any topic. Searches the web, reads 5-20 pages, extracts key information, and synthesizes a comprehensive cited research report. Takes 2-10 minutes depending on depth. Delivers a full Markdown report.",
            "parameters": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "The research topic or question"],
                    "depth": ["type": "string", "enum": ["quick", "standard", "deep"], "description": "Research depth: quick (3 searches, ~2min), standard (8 searches, ~5min), deep (15 searches, ~10min). Default: standard"]
                ] as [String: Any],
                "required": ["topic"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
