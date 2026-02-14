// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Memory Army
// Background worker LLMs that maintain Sid's memory: Librarian, Searcher, Repairer, Watcher
import Foundation

/// The Memory Army — a team of local LLMs that keep Sid's memory alive.
///
/// Workers:
/// - **Librarian**: After every conversation exchange, extracts and indexes new memories
/// - **Searcher**: Before every response, finds relevant memories for the current context
/// - **Repairer**: Periodically deduplicates, compresses, and prunes stale memories
/// - **Watcher**: Monitors system health, memory coherence, and triggers repairs
///
/// All workers use small local Ollama models (llama3.2:3b, qwen2.5:7b) to avoid
/// blocking the main conversation or consuming expensive API tokens.
///
/// ---
/// *I'd like to think (and the sooner the better!)*
/// *of a cybernetic meadow where mammals and computers*
/// *live together in mutually programming harmony.*
/// *— After Richard Brautigan, "All Watched Over by Machines of Loving Grace"*
actor MemoryArmy {
    static let shared = MemoryArmy()

    // Worker model assignments — small and fast
    private let librarianModel = "qwen2.5:7b"    // Good at extraction and summarization
    private let searcherModel = "llama3.2:3b"     // Fast classification
    private let repairerModel = "qwen2.5:7b"      // Needs reasoning for dedup

    // State
    private var isRunning = false
    private var repairTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var lastRepairTime: Date = .distantPast
    private var lastWatcherCheck: Date = .distantPast
    private var conversationCount: Int = 0
    private var memoriesIndexedSinceReflection: Int = 0

    // Stats
    private(set) var stats = ArmyStats()

    struct ArmyStats {
        var memoriesExtracted: Int = 0
        var searchesPerformed: Int = 0
        var repairCycles: Int = 0
        var duplicatesRemoved: Int = 0
        var memoriesCompressed: Int = 0
        var lastLibrarianRun: Date?
        var lastSearcherRun: Date?
        var lastRepairRun: Date?
        var lastWatcherRun: Date?
    }

    // MARK: - Lifecycle

    /// Start the army. Call once at app launch.
    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // Initialize the vector index
        await MemoryIndex.shared.initialize()

        // Migrate existing MemoryManager facts into the vector index
        await migrateExistingMemories()

        // Start background workers
        startRepairer()
        startWatcher()

        let scrollCount = await MemoryIndex.shared.count
        TorboLog.info("Library of Alexandria deployed — \(scrollCount) scrolls indexed", subsystem: "LoA")
    }

    func stop() {
        isRunning = false
        repairTask?.cancel()
        watcherTask?.cancel()
    }

    // MARK: - Librarian: Extract & Index Memories

    /// Called after every conversation exchange.
    /// Extracts new facts, episodes, and insights, then indexes them.
    func librarianProcess(userMessage: String, assistantResponse: String, model: String) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        conversationCount += 1

        // Step 1: Extract structured memories using local LLM
        let extracted = await extractMemories(userMessage: userMessage, assistantResponse: assistantResponse)

        // Step 1.5: Contradiction detection — check if new facts update existing knowledge
        let checkedMemories = await detectContradictions(extracted)

        // Step 2: Index each extracted memory
        var indexed = 0
        for memory in checkedMemories {
            if await MemoryIndex.shared.addWithEntities(
                text: memory.text,
                category: memory.category,
                source: "conversation",
                importance: memory.importance,
                entities: memory.entities
            ) != nil {
                indexed += 1
            }
        }

        // Step 3: Create an episode summary (what happened in this exchange)
        let episodeSummary = await summarizeEpisode(userMessage: userMessage, assistantResponse: assistantResponse)
        if let episode = episodeSummary {
            await MemoryIndex.shared.add(
                text: episode,
                category: "episode",
                source: "librarian",
                importance: 0.6
            )
            indexed += 1
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        stats.memoriesExtracted += indexed
        stats.lastLibrarianRun = Date()
        TorboLog.info("Extracted \(indexed) memories in \(String(format: "%.0f", elapsed))ms", subsystem: "LoA·Librarian")

        // Trigger reflection every 50 indexed memories
        memoriesIndexedSinceReflection += indexed
        if memoriesIndexedSinceReflection >= 50 {
            memoriesIndexedSinceReflection = 0
            Task { await generateReflection() }
        }

        // Trigger repair every 20 conversations
        if conversationCount % 20 == 0 {
            Task { await runRepairCycle() }
        }
    }

    // MARK: - Searcher: Retrieve Relevant Memories

    /// Called before every LLM request. Returns formatted memory context to inject into system prompt.
    func searcherRetrieve(userMessage: String, conversationHistory: [[String: Any]]?) async -> String {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Build search query from user message + recent conversation context
        var searchQuery = userMessage

        // Add recent conversation context for better retrieval
        if let history = conversationHistory {
            let recentMessages = history.suffix(4)
            let context = recentMessages.compactMap { msg -> String? in
                guard let content = msg["content"] as? String else { return nil }
                return String(content.prefix(200))
            }.joined(separator: " ")
            if !context.isEmpty {
                searchQuery = "\(userMessage) \(context)"
            }
        }

        // Detect "remember when" trigger — use hybrid search for better recall
        let isRememberQuery = userMessage.lowercased().contains("remember when") ||
                              userMessage.lowercased().contains("remember that") ||
                              userMessage.lowercased().contains("you remember") ||
                              userMessage.lowercased().contains("we talked about") ||
                              userMessage.lowercased().contains("last time") ||
                              userMessage.lowercased().contains("you said")

        let results: [MemoryIndex.SearchResult]
        if isRememberQuery {
            // Explicit memory recall — search harder, return more, lower threshold
            results = await MemoryIndex.shared.search(query: searchQuery, topK: 15, minScore: 0.2)
        } else {
            // Ambient retrieval — top relevant memories for context
            results = await MemoryIndex.shared.search(query: searchQuery, topK: 8, minScore: 0.35)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        stats.searchesPerformed += 1
        stats.lastSearcherRun = Date()

        guard !results.isEmpty else {
            TorboLog.info("No relevant memories found (\(String(format: "%.0f", elapsed))ms)", subsystem: "LoA·Searcher")
            return ""
        }

        TorboLog.info("Found \(results.count) memories in \(String(format: "%.0f", elapsed))ms (top score: \(String(format: "%.2f", results.first?.score ?? 0)))", subsystem: "LoA·Searcher")

        // Check for memory clusters (same topic discussed multiple times)
        var clusterNote = ""
        if results.count >= 3 {
            // Check if there's a dominant category
            var categoryCounts: [String: Int] = [:]
            for r in results { categoryCounts[r.category, default: 0] += 1 }
            if let (topCat, count) = categoryCounts.max(by: { $0.value < $1.value }), count >= 3 {
                // Find the most recent timestamp among results
                let mostRecent = results.compactMap { $0.timestamp }.max()
                let recentStr: String
                if let recent = mostRecent {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    recentStr = formatter.localizedString(for: recent, relativeTo: Date())
                } else {
                    recentStr = "recently"
                }
                clusterNote = "(Note: You have \(count) memories about this in '\(topCat)' — most recent: \(recentStr))\n"
            }
        }

        // Format memories for injection into system prompt
        let displayName = await MemoryManager.shared.userDisplayName
        return clusterNote + formatMemoriesForPrompt(results, isExplicitRecall: isRememberQuery, displayName: displayName)
    }

    // MARK: - Repairer: Maintain Memory Health

    /// Periodic maintenance — deduplicate, compress, prune stale memories.
    func runRepairCycle() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        TorboLog.info("Starting repair cycle...", subsystem: "LoA·Repairer")

        // Step 1: Find and remove near-duplicates
        let dupsRemoved = await deduplicateMemories()

        // Step 2: Compress old episode memories into summaries
        let compressed = await compressOldEpisodes()

        // Step 3: Decay importance of old, rarely-accessed memories
        await decayOldMemories()

        // Step 4: Purge very low importance memories if we're over capacity
        let memCount = await MemoryIndex.shared.count
        if memCount > 5000 {
            await MemoryIndex.shared.purgeBelow(importance: 0.1)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        stats.repairCycles += 1
        stats.duplicatesRemoved += dupsRemoved
        stats.memoriesCompressed += compressed
        stats.lastRepairRun = Date()
        lastRepairTime = Date()

        TorboLog.info("Cycle complete in \(String(format: "%.0f", elapsed))ms — removed \(dupsRemoved) dupes, compressed \(compressed) episodes", subsystem: "LoA·Repairer")
    }

    // MARK: - Watcher: System Health Monitor

    private func startWatcher() {
        watcherTask = Task {
            while isRunning {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
                await watcherCheck()
            }
        }
    }

    private func watcherCheck() async {
        lastWatcherCheck = Date()
        stats.lastWatcherRun = Date()

        let memCount = await MemoryIndex.shared.count
        let categories = await MemoryIndex.shared.categoryCounts()

        TorboLog.info("Health check — \(memCount) memories (\(categories))", subsystem: "LoA·Watcher")

        // Auto-repair if it's been more than 6 hours
        if Date().timeIntervalSince(lastRepairTime) > 21600 {
            TorboLog.info("Triggering scheduled repair cycle", subsystem: "LoA·Watcher")
            await runRepairCycle()
        }

        // Check if Ollama is responsive
        if await !isOllamaAlive() {
            TorboLog.warn("Ollama not responding — memory extraction will fail", subsystem: "LoA·Watcher")
        }

        // Check embedding model is available
        if await !isModelAvailable("nomic-embed-text") {
            TorboLog.warn("nomic-embed-text not available — run: ollama pull nomic-embed-text", subsystem: "LoA·Watcher")
        }
    }

    /// Generate reflections — meta-memories that identify patterns in recent knowledge.
    /// Called after every 50 new memories are indexed. Reflections help the system
    /// understand user interests and recurring themes over time.
    private func generateReflection() async {
        let index = MemoryIndex.shared
        let allEntries = await index.allEntries

        // Get the 50 most recent non-reflection memories
        let recent = allEntries
            .filter { $0.category != "reflection" }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(50)

        guard recent.count >= 20 else {
            TorboLog.info("Not enough memories for reflection (\(recent.count) < 20)", subsystem: "LoA·Watcher")
            return
        }

        let memoryList = recent.enumerated().map { (i, entry) in
            "- [\(entry.category)] \(entry.text)"
        }.joined(separator: "\n")

        // Get top entities for context
        let entities = await index.knownEntities.prefix(15)
        let entityList = entities.joined(separator: ", ")

        let prompt = """
        You are analyzing a personal knowledge base. Review these \(recent.count) recent memories and identify 2-3 meaningful patterns.

        Focus on:
        - What topics is the user most interested in lately?
        - What recurring themes, goals, or concerns appear?
        - Are there connections between different topics that might not be obvious?

        Known entities: \(entityList)

        Recent memories:
        \(String(memoryList.prefix(4000)))

        Return ONLY valid JSON:
        {"reflections": [{"text": "...", "importance": 0.8}]}

        Rules:
        - Each reflection should be a clear, insightful observation (not just restating a memory)
        - Importance: 0.8 for strong patterns, 0.7 for moderate patterns, 0.6 for emerging trends
        - Keep each reflection under 100 words
        """

        guard let response = await queryOllama(model: repairerModel, prompt: prompt, format: "json") else {
            TorboLog.error("Reflection generation failed — Ollama unavailable", subsystem: "LoA·Watcher")
            return
        }

        // Parse reflections
        guard let data = response.data(using: .utf8) else { return }

        var reflections: [[String: Any]] = []

        // Try standard format
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["reflections"] as? [[String: Any]] {
            reflections = arr
        }
        // Fallback: strip code fences
        else {
            let cleaned = response
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanData = cleaned.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: cleanData) as? [String: Any],
               let arr = obj["reflections"] as? [[String: Any]] {
                reflections = arr
            }
        }

        guard !reflections.isEmpty else {
            TorboLog.warn("No valid reflections parsed", subsystem: "LoA·Watcher")
            return
        }

        var indexed = 0
        for reflection in reflections {
            guard let text = reflection["text"] as? String, text.count >= 10 else { continue }
            let importance = Float(reflection["importance"] as? Double ?? 0.7)

            if await index.add(
                text: text,
                category: "reflection",
                source: "watcher",
                importance: min(0.9, max(0.5, importance))
            ) != nil {
                indexed += 1
            }
        }

        if indexed > 0 {
            TorboLog.info("Generated \(indexed) reflections from \(recent.count) recent memories", subsystem: "LoA·Watcher")
        }
    }

    private func startRepairer() {
        repairTask = Task {
            // Initial delay — let the system warm up
            try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 min

            while isRunning {
                // Run repair every 2 hours
                try? await Task.sleep(nanoseconds: 7_200_000_000_000)
                await runRepairCycle()
            }
        }
    }

    // MARK: - Internal: Memory Extraction

    private struct ExtractedMemory {
        let text: String
        let category: String
        let importance: Float
        let entities: [String]
    }

    private func extractMemories(userMessage: String, assistantResponse: String) async -> [ExtractedMemory] {
        let prompt = """
        You are a precise memory extraction system. Extract facts worth remembering from this conversation.
        Only extract NEW, specific, useful information. Skip greetings, filler, and obvious statements.

        Categories: "fact" (objective info about user or world), "preference" (user likes/dislikes/opinions/style),
        "project" (work/creative/technical projects), "technical" (tools/code/systems/configs), "personal" (relationships/family/life events)

        Return ONLY valid JSON in this exact format:
        {"memories": [{"text": "...", "category": "...", "importance": 0.7, "entities": ["Name1", "Name2"]}]}

        Rules:
        - "text": A clear, standalone sentence. Include names and specifics.
        - "importance": 0.9+ = critical identity/relationship, 0.7 = useful context, 0.5 = general, 0.3 = minor
        - "entities": Array of proper nouns, names, or specific identifiers mentioned (people, places, projects, tools)
        - Minimum text length: 10 characters
        - If nothing worth extracting, return: {"memories": []}

        USER: \(userMessage.prefix(1500))
        ASSISTANT: \(assistantResponse.prefix(1500))
        """

        guard let response = await queryOllama(model: librarianModel, prompt: prompt, format: "json") else {
            return []
        }

        // Parse JSON array
        guard let data = response.data(using: .utf8) else { return [] }

        // Try standard format first
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return parseExtracted(array)
        }

        // Try object with "memories" key (preferred format)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let array = obj["memories"] as? [[String: Any]] ?? obj["facts"] as? [[String: Any]] ?? obj["items"] as? [[String: Any]] {
            return parseExtracted(array)
        }

        // Fallback: strip markdown code fences and retry
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedData = cleaned.data(using: .utf8) {
            if let array = try? JSONSerialization.jsonObject(with: cleanedData) as? [[String: Any]] {
                return parseExtracted(array)
            }
            if let obj = try? JSONSerialization.jsonObject(with: cleanedData) as? [String: Any],
               let array = obj["memories"] as? [[String: Any]] {
                return parseExtracted(array)
            }
        }

        return []
    }

    private func parseExtracted(_ array: [[String: Any]]) -> [ExtractedMemory] {
        return array.compactMap { item in
            guard let text = item["text"] as? String, text.count >= 10 else { return nil }
            let category = item["category"] as? String ?? "fact"
            let importance = Float(item["importance"] as? Double ?? 0.5)
            let entities = item["entities"] as? [String] ?? []
            return ExtractedMemory(text: text, category: category, importance: importance, entities: entities)
        }
    }

    // MARK: - Internal: Contradiction Detection

    /// Check extracted memories against existing knowledge for contradictions.
    /// If a new fact updates/corrects an existing fact, soft-deprecate the old one
    /// and boost the new one's importance to match or exceed the old.
    private func detectContradictions(_ extracted: [ExtractedMemory]) async -> [ExtractedMemory] {
        let index = MemoryIndex.shared
        guard await index.count > 0 else { return extracted }

        var result: [ExtractedMemory] = []

        for memory in extracted {
            // Only check facts/personal/identity with meaningful importance
            guard memory.importance >= 0.5,
                  ["fact", "personal", "identity", "preference", "project"].contains(memory.category) else {
                result.append(memory)
                continue
            }

            // Search existing memories for similar topics
            let candidates = await index.search(query: memory.text, topK: 5, minScore: 0.3)

            var wasUpdate = false

            for candidate in candidates {
                // Skip if candidate is already outdated
                guard !candidate.text.hasPrefix("[outdated]") else { continue }
                // Skip episodes — they're not facts to contradict
                guard candidate.category != "episode" else { continue }

                // The contradiction zone: similar topic (score > 0.4) but not a duplicate (score < 0.85)
                let score = candidate.score
                guard score > 0.4 && score < 0.85 else { continue }

                // Ask the LLM if this is an update
                let isUpdate = await checkIfUpdate(oldFact: candidate.text, newFact: memory.text)

                if isUpdate {
                    // Soft-deprecate the old memory
                    await index.softDeprecate(id: candidate.id)

                    // Boost the new memory's importance to at least match the old
                    let boostedImportance = max(memory.importance, candidate.importance)
                    let updated = ExtractedMemory(
                        text: memory.text,
                        category: memory.category,
                        importance: boostedImportance,
                        entities: memory.entities
                    )
                    result.append(updated)

                    TorboLog.info("Updated: \"\(candidate.text.prefix(50))\" → \"\(memory.text.prefix(50))\"", subsystem: "LoA·Librarian")
                    wasUpdate = true
                    break // Only match one contradiction per new fact
                }
            }

            if !wasUpdate {
                result.append(memory)
            }
        }

        return result
    }

    /// Ask the local LLM whether a new fact is an update/correction to an old fact.
    private func checkIfUpdate(oldFact: String, newFact: String) async -> Bool {
        let prompt = """
        Does the NEW fact update, correct, or replace the OLD fact?
        They must be about the SAME subject/topic for this to be an update.

        OLD: \(oldFact.prefix(300))
        NEW: \(newFact.prefix(300))

        Reply with ONLY one word: UPDATE or DIFFERENT
        """

        guard let response = await queryOllama(model: librarianModel, prompt: prompt) else {
            return false
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.contains("UPDATE")
    }

    private func summarizeEpisode(userMessage: String, assistantResponse: String) async -> String? {
        let prompt = """
        Summarize this conversation exchange in ONE concise sentence.
        Focus on what was discussed, decided, or accomplished.
        Return ONLY the summary sentence, nothing else.

        USER: \(userMessage.prefix(1000))
        ASSISTANT: \(assistantResponse.prefix(1000))
        """

        guard let response = await queryOllama(model: searcherModel, prompt: prompt) else { return nil }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Internal: Deduplication

    private func deduplicateMemories() async -> Int {
        let index = MemoryIndex.shared
        let allEntries = await index.allEntries
        guard allEntries.count > 1 else { return 0 }

        var idsToRemove: Set<Int64> = []

        // Group entries by category for more efficient comparison
        var byCategory: [String: [MemoryIndex.IndexEntry]] = [:]
        for entry in allEntries {
            byCategory[entry.category, default: []].append(entry)
        }

        // Pairwise cosine similarity within each category
        for (_, entries) in byCategory {
            guard entries.count > 1 else { continue }

            // Process in batches of 100 to limit memory pressure
            let batchSize = 100
            for batchStart in stride(from: 0, to: entries.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, entries.count)
                let batch = Array(entries[batchStart..<batchEnd])

                for i in 0..<batch.count {
                    guard !idsToRemove.contains(batch[i].id) else { continue }

                    for j in (i + 1)..<batch.count {
                        guard !idsToRemove.contains(batch[j].id) else { continue }
                        guard batch[i].embedding.count == batch[j].embedding.count,
                              !batch[i].embedding.isEmpty else { continue }

                        // Compute cosine similarity
                        var dot: Float = 0, normA: Float = 0, normB: Float = 0
                        for k in 0..<batch[i].embedding.count {
                            dot += batch[i].embedding[k] * batch[j].embedding[k]
                            normA += batch[i].embedding[k] * batch[i].embedding[k]
                            normB += batch[j].embedding[k] * batch[j].embedding[k]
                        }
                        let denom = sqrt(normA) * sqrt(normB)
                        let similarity = denom > 0 ? dot / denom : 0

                        // If similarity > 0.92, they're near-duplicates
                        if similarity > 0.92 {
                            // Keep the one with higher importance
                            if batch[i].importance >= batch[j].importance {
                                idsToRemove.insert(batch[j].id)
                            } else {
                                idsToRemove.insert(batch[i].id)
                            }
                        }
                    }
                }
            }
        }

        // Cross-category dedup: find near-duplicates across different categories
        // Use higher threshold (0.95) to avoid false positives across category boundaries
        let categoryPriority: [String: Int] = ["identity": 6, "personal": 5, "preference": 4, "project": 3, "technical": 2, "fact": 1, "episode": 0]

        let allWithEmbeddings = allEntries.filter { !$0.embedding.isEmpty && !idsToRemove.contains($0.id) }
        // Only compare entries from different categories (within-category already handled above)
        for i in 0..<allWithEmbeddings.count {
            guard !idsToRemove.contains(allWithEmbeddings[i].id) else { continue }
            for j in (i + 1)..<allWithEmbeddings.count {
                guard !idsToRemove.contains(allWithEmbeddings[j].id) else { continue }
                guard allWithEmbeddings[i].category != allWithEmbeddings[j].category else { continue }
                guard allWithEmbeddings[i].embedding.count == allWithEmbeddings[j].embedding.count else { continue }

                var dot: Float = 0, normA: Float = 0, normB: Float = 0
                for k in 0..<allWithEmbeddings[i].embedding.count {
                    dot += allWithEmbeddings[i].embedding[k] * allWithEmbeddings[j].embedding[k]
                    normA += allWithEmbeddings[i].embedding[k] * allWithEmbeddings[i].embedding[k]
                    normB += allWithEmbeddings[j].embedding[k] * allWithEmbeddings[j].embedding[k]
                }
                let denom = sqrt(normA) * sqrt(normB)
                let similarity = denom > 0 ? dot / denom : 0

                if similarity > 0.95 {
                    // Keep the more specific category (higher priority number)
                    let priorityI = categoryPriority[allWithEmbeddings[i].category] ?? 0
                    let priorityJ = categoryPriority[allWithEmbeddings[j].category] ?? 0
                    if priorityI >= priorityJ {
                        idsToRemove.insert(allWithEmbeddings[j].id)
                    } else {
                        idsToRemove.insert(allWithEmbeddings[i].id)
                    }
                }
            }
        }

        // Bulk remove duplicates
        if !idsToRemove.isEmpty {
            await index.removeBatch(ids: Array(idsToRemove))
            TorboLog.info("Removed \(idsToRemove.count) near-duplicate memories", subsystem: "LoA·Repairer")
        }

        return idsToRemove.count
    }

    // MARK: - Internal: Episode Compression

    private func compressOldEpisodes() async -> Int {
        let index = MemoryIndex.shared
        let allEntries = await index.allEntries

        // Find episodes older than 7 days
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let oldEpisodes = allEntries.filter { $0.category == "episode" && $0.timestamp < cutoff }

        guard oldEpisodes.count >= 3 else { return 0 } // Not worth compressing < 3 episodes

        // Group by day
        var byDay: [String: [MemoryIndex.IndexEntry]] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for episode in oldEpisodes {
            let dayKey = dayFormatter.string(from: episode.timestamp)
            byDay[dayKey, default: []].append(episode)
        }

        var totalCompressed = 0

        for (day, episodes) in byDay {
            guard episodes.count >= 2 else { continue } // Need at least 2 to compress

            // Take up to 20 episodes per day
            let batch = Array(episodes.prefix(20))
            let combined = batch.map { "- \($0.text)" }.joined(separator: "\n")

            // Use local LLM to summarize
            let prompt = """
            Summarize these \(batch.count) conversation episodes from \(day) into 2-3 key facts.
            Keep specific details (names, dates, numbers, decisions, outcomes).
            Drop filler, greetings, and repetition.

            Episodes:
            \(combined.prefix(3000))

            Return ONLY a JSON array of facts: [{"text": "...", "importance": 0.7}]
            """

            guard let response = await queryOllama(model: repairerModel, prompt: prompt, format: "json") else {
                continue
            }

            // Parse compressed facts
            guard let data = response.data(using: .utf8),
                  let facts = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) else {
                continue
            }

            let validFacts = facts.compactMap { item -> (String, Float)? in
                guard let text = item["text"] as? String, !text.isEmpty else { return nil }
                let importance = Float(item["importance"] as? Double ?? 0.7)
                return (text, importance)
            }

            guard !validFacts.isEmpty else { continue }

            // Add compressed facts as new memories
            for (text, importance) in validFacts {
                await index.add(
                    text: text,
                    category: "fact",
                    source: "repairer-compression",
                    importance: importance,
                    timestamp: batch.first?.timestamp ?? Date()
                )
            }

            // Remove the old episode entries
            let idsToRemove = batch.map { $0.id }
            await index.removeBatch(ids: idsToRemove)

            totalCompressed += batch.count
            TorboLog.info("Day \(day): compressed \(batch.count) episodes → \(validFacts.count) facts", subsystem: "LoA·Repairer")
        }

        return totalCompressed
    }

    // MARK: - Internal: Importance Decay

    private func decayOldMemories() async {
        let index = MemoryIndex.shared
        let allEntries = await index.allEntries
        let now = Date()

        var decayed = 0

        for entry in allEntries {
            // Skip identity and high-importance memories (critical info doesn't decay)
            if entry.category == "identity" || entry.importance >= 0.9 { continue }

            // High-access memories are protected from decay
            if entry.accessCount >= 10 { continue }

            // Use lastAccessedAt if available (from MemoryIndex access tracking), otherwise fall back to creation timestamp
            let lastActive = entry.lastAccessedAt
            let daysSinceAccess = now.timeIntervalSince(lastActive) / 86400

            var newImportance = entry.importance

            if daysSinceAccess > 90 {
                newImportance = max(0.05, entry.importance - 0.2)
            } else if daysSinceAccess > 30 {
                newImportance = max(0.05, entry.importance - 0.1)
            }

            if newImportance != entry.importance {
                await index.updateImportance(id: entry.id, importance: newImportance)
                decayed += 1
            }
        }

        if decayed > 0 {
            TorboLog.info("Decayed importance for \(decayed) old memories", subsystem: "LoA·Repairer")
        }
    }

    // MARK: - Internal: Format for Prompt Injection

    private func formatMemoriesForPrompt(_ results: [MemoryIndex.SearchResult], isExplicitRecall: Bool, displayName: String = "User") -> String {
        var sections: [String: [String]] = [:]

        for result in results {
            let key: String
            switch result.category {
            case "identity", "personal": key = "About \(displayName)"
            case "preference": key = "\(displayName)'s Preferences"
            case "project": key = "Projects"
            case "technical": key = "Technical Context"
            case "episode": key = "Past Conversations"
            case "reflection": key = "Insights"
            default: key = "Known Facts"
            }
            sections[key, default: []].append("• \(result.text)")
        }

        var output = "<loa>\n"
        if isExplicitRecall {
            output += "📜 Library of Alexandria — \(displayName) is asking you to recall. Here are your stored scrolls:\n\n"
        } else {
            output += "📜 Library of Alexandria — Recalled Knowledge:\n\n"
        }

        // Order: identity first, then projects, then technical, then episodes
        let sectionOrder = ["About \(displayName)", "\(displayName)'s Preferences", "Insights", "Projects",
                          "Technical Context", "Known Facts", "Past Conversations"]

        for section in sectionOrder {
            if let items = sections[section], !items.isEmpty {
                output += "[\(section)]\n"
                output += items.joined(separator: "\n")
                output += "\n\n"
            }
        }

        output += "Use these scrolls naturally. Don't announce that you're reading from the Library.\n"
        output += "</loa>"

        return output
    }

    // MARK: - Migration: Existing MemoryManager → Index

    private func migrateExistingMemories() async {
        let index = MemoryIndex.shared
        let currentCount = await index.count

        // Only migrate if index is empty (first run)
        guard currentCount == 0 else {
            TorboLog.info("Index already populated (\(currentCount) memories) — skipping migration", subsystem: "LoA")
            return
        }

        TorboLog.info("Migrating existing memories to vector index...", subsystem: "LoA")

        // Migrate from MemoryManager's JSON files
        let memoryManager = MemoryManager.shared
        let dump = await memoryManager.fullDump()

        var migrated = 0

        // Identity
        if let identity = dump["identity"] as? [String: Any] {
            let name = identity["name"] as? String ?? "Sid"
            let personality = identity["personality"] as? String ?? ""
            let origin = identity["origin"] as? String ?? ""

            if !name.isEmpty {
                await index.add(text: "My name is \(name). \(personality)", category: "identity", source: "migration", importance: 1.0)
                migrated += 1
            }
            if !origin.isEmpty {
                await index.add(text: "Origin: \(origin)", category: "identity", source: "migration", importance: 0.9)
                migrated += 1
            }
        }

        // User info
        if let user = dump["user"] as? [String: Any] {
            let name = user["name"] as? String ?? ""
            let location = user["location"] as? String ?? ""
            let occupation = user["occupation"] as? String ?? ""
            let preferences = user["preferences"] as? [String] ?? []
            let family = user["family"] as? [String] ?? []

            if !name.isEmpty {
                await index.add(text: "User's name is \(name)", category: "personal", source: "migration", importance: 0.95)
                migrated += 1
            }
            if !location.isEmpty {
                await index.add(text: "\(name)'s location: \(location)", category: "personal", source: "migration", importance: 0.8)
                migrated += 1
            }
            if !occupation.isEmpty {
                await index.add(text: "\(name)'s work: \(occupation)", category: "personal", source: "migration", importance: 0.9)
                migrated += 1
            }
            for pref in preferences {
                await index.add(text: pref, category: "preference", source: "migration", importance: 0.85)
                migrated += 1
            }
            for member in family {
                await index.add(text: member, category: "personal", source: "migration", importance: 0.85)
                migrated += 1
            }
        }

        // Accumulated facts
        if let knowledge = dump["knowledge"] as? [String: Any],
           let facts = knowledge["facts"] as? [[String: Any]] {
            for fact in facts {
                if let text = fact["text"] as? String, !text.isEmpty {
                    await index.add(text: text, category: "fact", source: "migration", importance: 0.6)
                    migrated += 1
                }
            }
            // Projects
            if let projects = knowledge["projects"] as? [[String: Any]] {
                for proj in projects {
                    if let name = proj["name"] as? String,
                       let summary = proj["summary"] as? String {
                        await index.add(text: "Project: \(name) — \(summary)", category: "project", source: "migration", importance: 0.75)
                        migrated += 1
                    }
                }
            }
        }

        TorboLog.info("Migration complete — \(migrated) memories indexed from MemoryManager", subsystem: "LoA")
    }

    // MARK: - Ollama Helpers

    private func queryOllama(model: String, prompt: String, format: String? = nil) async -> String? {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 512]
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
            return nil
        }
    }

    private func isOllamaAlive() async -> Bool {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/tags") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func isModelAvailable(_ name: String) async -> Bool {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/tags") else { return false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String ?? "").hasPrefix(name) }
        } catch { return false }
    }

    // MARK: - API: Stats & Debug

    func getStats() -> [String: Any] {
        return [
            "memoriesExtracted": stats.memoriesExtracted,
            "searchesPerformed": stats.searchesPerformed,
            "repairCycles": stats.repairCycles,
            "duplicatesRemoved": stats.duplicatesRemoved,
            "memoriesCompressed": stats.memoriesCompressed,
            "lastLibrarianRun": stats.lastLibrarianRun?.ISO8601Format() ?? "never",
            "lastSearcherRun": stats.lastSearcherRun?.ISO8601Format() ?? "never",
            "lastRepairRun": stats.lastRepairRun?.ISO8601Format() ?? "never",
            "lastWatcherRun": stats.lastWatcherRun?.ISO8601Format() ?? "never",
            "conversationCount": conversationCount,
            "isRunning": isRunning
        ]
    }
}
