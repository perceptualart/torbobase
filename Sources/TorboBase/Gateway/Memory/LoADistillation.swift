// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — LoA Distillation Engine
// Background job that reads recent conversation turns, extracts structured
// knowledge via local LLM, and writes it to the LoA Memory Engine.
// Runs every 15 minutes.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Background distillation: reads conversation history, extracts structured
/// knowledge (facts, people, decisions, open items, patterns, signals),
/// and writes to the LoA Memory Engine with deduplication.
actor LoADistillation {
    static let shared = LoADistillation()

    private let extractionModel = "qwen2.5:7b"
    private let maxTurnsPerRun = 40
    private var lastProcessedCount: Int = 0
    private var isRunning = false
    private var cronJobRegistered = false

    // MARK: - Cron Registration

    /// Register the distillation job and start the background loop.
    func registerCronJob() async {
        guard !cronJobRegistered else { return }
        cronJobRegistered = true
        startDistillationLoop()
        TorboLog.info("Distillation job registered — runs every 15 minutes", subsystem: "LoA·Distill")
    }

    /// Internal timer loop — runs distillation every 15 minutes
    private func startDistillationLoop() {
        Task {
            // Initial delay: wait 2 minutes after startup for other systems to initialize
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)

            while !Task.isCancelled {
                await self.runDistillation()
                // Sleep 15 minutes
                try? await Task.sleep(nanoseconds: 900 * 1_000_000_000)
            }
        }
    }

    // MARK: - Main Distillation Cycle

    /// Run a single distillation cycle.
    func runDistillation() async {
        guard !isRunning else {
            TorboLog.debug("Distillation already running, skipping", subsystem: "LoA·Distill")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let startTime = Date()

        // 1. Load recent conversation messages
        let allMessages = await ConversationStore.shared.loadMessages()
        let totalCount = allMessages.count

        guard totalCount > lastProcessedCount else {
            TorboLog.debug("No new messages since last distillation (\(totalCount) total)", subsystem: "LoA·Distill")
            return
        }

        let newMessages = Array(allMessages.suffix(from: lastProcessedCount))
        let messagesToProcess = Array(newMessages.suffix(maxTurnsPerRun))
        lastProcessedCount = totalCount

        guard !messagesToProcess.isEmpty else { return }

        TorboLog.info("Distilling \(messagesToProcess.count) new messages...", subsystem: "LoA·Distill")

        // 2. Format conversation turns for the extraction prompt
        let conversationText = formatConversation(messagesToProcess)

        // 3. Send to LLM for structured extraction
        guard let extracted = await extractKnowledge(from: conversationText) else {
            TorboLog.warn("Extraction returned nil — Ollama may be offline", subsystem: "LoA·Distill")
            return
        }

        // 4. Write extracted knowledge to LoA
        var factsWritten = 0
        var peopleWritten = 0
        var patternsWritten = 0
        var loopsWritten = 0
        var signalsWritten = 0

        if let facts = extracted["facts"] as? [[String: Any]] {
            for fact in facts {
                guard let category = fact["category"] as? String,
                      let key = fact["key"] as? String,
                      let value = fact["value"] as? String else { continue }
                let confidence = fact["confidence"] as? Double ?? 0.7
                if await LoAMemoryEngine.shared.writeFact(
                    category: category, key: key, value: value,
                    confidence: confidence, source: "distillation"
                ) != nil {
                    factsWritten += 1
                }
            }
        }

        if let people = extracted["people"] as? [[String: Any]] {
            for person in people {
                guard let name = person["name"] as? String else { continue }
                if await LoAMemoryEngine.shared.upsertPerson(
                    name: name,
                    relationship: person["relationship"] as? String,
                    sentiment: person["sentiment"] as? String,
                    notes: person["notes"] as? String
                ) != nil {
                    peopleWritten += 1
                }
            }
        }

        if let patterns = extracted["patterns"] as? [[String: Any]] {
            for pattern in patterns {
                guard let patternType = pattern["type"] as? String,
                      let description = pattern["description"] as? String else { continue }
                let confidence = pattern["confidence"] as? Double ?? 0.5
                if await LoAMemoryEngine.shared.upsertPattern(
                    patternType: patternType, description: description, confidence: confidence
                ) != nil {
                    patternsWritten += 1
                }
            }
        }

        if let loops = extracted["open_loops"] as? [[String: Any]] {
            for loop in loops {
                guard let topic = loop["topic"] as? String else { continue }
                let priority = loop["priority"] as? Int ?? 0
                if await LoAMemoryEngine.shared.upsertOpenLoop(
                    topic: topic, priority: priority
                ) != nil {
                    loopsWritten += 1
                }
            }
        }

        if let signals = extracted["signals"] as? [[String: Any]] {
            for signal in signals {
                guard let signalType = signal["type"] as? String,
                      let value = signal["value"] as? String else { continue }
                if await LoAMemoryEngine.shared.logSignal(
                    signalType: signalType, value: value
                ) != nil {
                    signalsWritten += 1
                }
            }
        }

        // 5. Run decay cycle
        await LoAMemoryEngine.shared.runDecay()

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
        let total = factsWritten + peopleWritten + patternsWritten + loopsWritten + signalsWritten
        TorboLog.info("Distillation complete in \(elapsed)s — \(total) items (facts:\(factsWritten) people:\(peopleWritten) patterns:\(patternsWritten) loops:\(loopsWritten) signals:\(signalsWritten))", subsystem: "LoA·Distill")
    }

    // MARK: - Conversation Formatting

    private func formatConversation(_ messages: [ConversationMessage]) -> String {
        var lines: [String] = []
        for msg in messages {
            let role = msg.role.uppercased()
            let content = String(msg.content.prefix(1000))
            lines.append("[\(role)] \(content)")
        }
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(6000))
    }

    // MARK: - LLM Extraction

    private func extractKnowledge(from conversation: String) async -> [String: Any]? {
        let prompt = """
        You are a knowledge extraction system for a personal AI assistant. Analyze this conversation \
        and extract structured information worth remembering long-term.

        Extract these categories:

        1. **facts** — objective information: preferences, biographical details, work info, opinions, decisions. \
        Each needs: category (preference/biographical/work/technical/health/financial), key (short identifier), \
        value (the fact), confidence (0.0-1.0).

        2. **people** — any person mentioned by name. Include: name, relationship (if stated), \
        sentiment (positive/negative/neutral), notes.

        3. **patterns** — recurring behaviors, habits, themes. Include: type (habit/schedule/preference/communication), \
        description, confidence (0.0-1.0).

        4. **open_loops** — unresolved items: tasks not completed, questions unanswered, things to do later. \
        Include: topic, priority (0-5, 5=urgent).

        5. **signals** — emotional/health indicators: stress, energy, mood, sleep. \
        Include: type (stress/energy/mood/sleep/health), value (brief description).

        Return ONLY valid JSON:
        {
            "facts": [{"category": "...", "key": "...", "value": "...", "confidence": 0.8}],
            "people": [{"name": "...", "relationship": "...", "sentiment": "...", "notes": "..."}],
            "patterns": [{"type": "...", "description": "...", "confidence": 0.6}],
            "open_loops": [{"topic": "...", "priority": 2}],
            "signals": [{"type": "...", "value": "..."}]
        }

        If a category has nothing to extract, use an empty array.
        Only extract NEW, specific, useful information. Skip greetings and filler.

        CONVERSATION:
        \(conversation)
        """

        guard let response = await queryOllama(model: extractionModel, prompt: prompt, format: "json") else {
            return nil
        }

        guard let data = response.data(using: .utf8) else { return nil }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedData = cleaned.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] {
            return obj
        }

        TorboLog.warn("Failed to parse extraction response", subsystem: "LoA·Distill")
        return nil
    }

    // MARK: - Ollama Interface

    private func queryOllama(model: String, prompt: String, format: String? = nil) async -> String? {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 1024]
        ]
        if let format { body["format"] = format }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else { return nil }
            return response
        } catch {
            TorboLog.error("Ollama query failed: \(error.localizedDescription)", subsystem: "LoA·Distill")
            return nil
        }
    }
}
