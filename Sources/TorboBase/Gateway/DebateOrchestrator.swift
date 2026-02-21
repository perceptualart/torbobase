// Copyright 2026 Perceptual Art LLC. All rights reserved.
// DebateOrchestrator.swift — Fan out decision questions to multiple agents,
// collect perspectives, synthesize with SiD.

import Foundation

// MARK: - Data Models

struct DebatePerspective: Codable {
    let agentID: String
    let agentName: String
    let role: String
    let perspective: String
    let stance: String   // "for", "against", "nuanced"
}

struct DebateResult: Codable {
    let id: String
    let question: String
    let perspectives: [DebatePerspective]
    let synthesis: String
    let recommendation: String
    let confidence: Double
    let timestamp: Double
    let durationMs: Int
}

// MARK: - Orchestrator

actor DebateOrchestrator {
    static let shared = DebateOrchestrator()

    private struct Panelist {
        let id: String
        let name: String
        let role: String
        let systemPrompt: String
    }

    private let panelists: [Panelist] = [
        Panelist(id: "orion", name: "Orion", role: "Strategic Advisor",
                 systemPrompt: "You are Orion, a strategic advisor. Analyze the question from a practical, strategic perspective. Consider long-term consequences, risks, and opportunities. Be direct and opinionated. Keep your response under 100 words."),
        Panelist(id: "ada", name: "aDa", role: "Technical Analyst",
                 systemPrompt: "You are aDa, a technical analyst. Analyze the question from a technical, data-driven perspective. Consider feasibility, complexity, and evidence. Be precise and analytical. Keep your response under 100 words."),
        Panelist(id: "mira", name: "Mira", role: "Creative Thinker",
                 systemPrompt: "You are Mira, a creative thinker. Analyze the question from an unconventional, creative perspective. Consider human factors, emotional impact, and alternatives others might miss. Be imaginative but grounded. Keep your response under 100 words.")
    ]

    /// Run a full multi-agent debate on the given question.
    func runDebate(question: String, model: String? = nil, triggerConfidence: Double = 0.0) async -> DebateResult {
        let startTime = Date()
        let debateID = UUID().uuidString.prefix(8).lowercased()

        TorboLog.info("Starting debate \(debateID): \(question.prefix(60))…", subsystem: "Debate")

        // Fan out to all panelists in parallel
        let perspectives: [DebatePerspective] = await withTaskGroup(of: DebatePerspective?.self) { group in
            for panelist in panelists {
                group.addTask { [self] in
                    await self.askPanelist(panelist, question: question, model: model)
                }
            }
            var results: [DebatePerspective] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        // Synthesize with SiD
        let (synthesis, recommendation) = await synthesize(question: question, perspectives: perspectives, model: model)
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        TorboLog.info("Debate \(debateID) complete in \(durationMs)ms — \(perspectives.count) perspectives", subsystem: "Debate")

        return DebateResult(
            id: String(debateID),
            question: question,
            perspectives: perspectives,
            synthesis: synthesis,
            recommendation: recommendation,
            confidence: triggerConfidence,
            timestamp: Date().timeIntervalSince1970,
            durationMs: durationMs
        )
    }

    // MARK: - Private

    private func askPanelist(_ panelist: Panelist, question: String, model: String?) async -> DebatePerspective? {
        let messages: [[String: Any]] = [
            ["role": "system", "content": panelist.systemPrompt],
            ["role": "user", "content": question]
        ]

        guard let response = await callLLM(messages: messages, model: model) else {
            TorboLog.warn("Panelist \(panelist.name) failed to respond", subsystem: "Debate")
            return nil
        }

        let stance = detectStance(response)

        return DebatePerspective(
            agentID: panelist.id,
            agentName: panelist.name,
            role: panelist.role,
            perspective: response,
            stance: stance
        )
    }

    private func synthesize(question: String, perspectives: [DebatePerspective], model: String?) async -> (String, String) {
        guard !perspectives.isEmpty else {
            return ("No perspectives were gathered.", "Unable to provide a recommendation.")
        }

        var prompt = "You are SiD, the lead intelligence. Multiple agents have weighed in on this question:\n\n"
        prompt += "Question: \(question)\n\n"
        for p in perspectives {
            prompt += "— \(p.agentName) (\(p.role), stance: \(p.stance)):\n\(p.perspective)\n\n"
        }
        prompt += "Write a 150-word synthesis that:\n1. Acknowledges each perspective\n2. Identifies the key tension or trade-off\n3. Ends with a clear, actionable recommendation starting with 'Recommendation:'\n\nBe decisive. Don't hedge."

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are SiD, the synthesis intelligence. Be clear, concise, and decisive."],
            ["role": "user", "content": prompt]
        ]

        guard let response = await callLLM(messages: messages, model: model) else {
            return ("Synthesis failed.", "Unable to synthesize.")
        }

        // Extract recommendation from response
        let recommendation: String
        if let range = response.range(of: "Recommendation:", options: .caseInsensitive) {
            recommendation = String(response[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Take last sentence as recommendation
            let sentences = response.components(separatedBy: ". ")
            recommendation = (sentences.last ?? response).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (response, recommendation)
    }

    private func detectStance(_ text: String) -> String {
        let lower = text.lowercased()
        let forSignals = ["recommend", "absolutely", "definitely", "yes", "go for it", "strongly suggest", "best option", "clearly the"]
        let againstSignals = ["avoid", "wouldn't recommend", "don't", "risky", "caution", "against", "not worth", "bad idea"]

        let forCount = forSignals.filter { lower.contains($0) }.count
        let againstCount = againstSignals.filter { lower.contains($0) }.count

        if forCount > againstCount { return "for" }
        if againstCount > forCount { return "against" }
        return "nuanced"
    }

    /// Call the best available LLM provider.
    private func callLLM(messages: [[String: Any]], model: String?) async -> String? {
        // Try providers in order: Anthropic → OpenAI → xAI → Google → Ollama
        let providers: [(key: String, urlBase: String, transform: Bool)] = [
            ("ANTHROPIC_API_KEY", "https://api.anthropic.com/v1/messages", true),
            ("OPENAI_API_KEY", "https://api.openai.com/v1/chat/completions", false),
            ("XAI_API_KEY", "https://api.x.ai/v1/chat/completions", false),
            ("GOOGLE_API_KEY", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", false),
        ]

        for provider in providers {
            if let key = KeychainManager.get("apikey." + provider.key) ?? KeychainManager.get(provider.key), !key.isEmpty {
                if provider.transform {
                    return await callAnthropic(messages: messages, apiKey: key, model: model)
                } else {
                    return await callOpenAICompatible(url: provider.urlBase, messages: messages, apiKey: key, model: model, isGoogle: provider.key == "GOOGLE_API_KEY")
                }
            }
        }

        // Fallback: local Ollama
        return await callOllama(messages: messages, model: model)
    }

    private func callAnthropic(messages: [[String: Any]], apiKey: String, model: String?) async -> String? {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Convert OpenAI format → Anthropic format
        var systemText = ""
        var anthropicMessages: [[String: Any]] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""
            if role == "system" {
                systemText += content + "\n"
            } else {
                anthropicMessages.append(["role": role, "content": content])
            }
        }

        var body: [String: Any] = [
            "model": model ?? "claude-sonnet-4-20250514",
            "max_tokens": 300,
            "messages": anthropicMessages
        ]
        if !systemText.isEmpty {
            body["system"] = systemText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = json

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = parsed["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return nil }

        return text
    }

    private func callOpenAICompatible(url: String, messages: [[String: Any]], apiKey: String, model: String?, isGoogle: Bool) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let defaultModel = isGoogle ? "gemini-2.0-flash" : "gpt-4o-mini"
        let body: [String: Any] = [
            "model": model ?? defaultModel,
            "messages": messages,
            "max_tokens": 300
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = json

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }

        return text
    }

    private func callOllama(messages: [[String: Any]], model: String?) async -> String? {
        let base = OllamaManager.baseURL
        guard let url = URL(string: "\(base)/api/chat") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model ?? "llama3.2:3b",
            "messages": messages,
            "stream": false
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = json

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = parsed["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }

        return text
    }

    /// Encode a DebateResult as a JSON-friendly dictionary.
    func encodeResult(_ result: DebateResult) -> [String: Any] {
        let perspectives = result.perspectives.map { p in
            ["agentID": p.agentID, "agentName": p.agentName, "role": p.role,
             "perspective": p.perspective, "stance": p.stance] as [String: Any]
        }
        return [
            "id": result.id,
            "question": result.question,
            "perspectives": perspectives,
            "synthesis": result.synthesis,
            "recommendation": result.recommendation,
            "confidence": result.confidence,
            "timestamp": result.timestamp,
            "durationMs": result.durationMs
        ]
    }
}
