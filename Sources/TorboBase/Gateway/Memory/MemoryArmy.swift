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
actor MemoryArmy {
    static let shared = MemoryArmy()

    private let ollamaURL = "http://127.0.0.1:11434"

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

        print("[Army] Memory Army deployed — \(await MemoryIndex.shared.count) memories indexed")
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

        // Step 2: Index each extracted memory
        var indexed = 0
        for memory in extracted {
            if await MemoryIndex.shared.add(
                text: memory.text,
                category: memory.category,
                source: "conversation",
                importance: memory.importance
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
        print("[Librarian] Extracted \(indexed) memories in \(String(format: "%.0f", elapsed))ms")

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
            print("[Searcher] No relevant memories found (\(String(format: "%.0f", elapsed))ms)")
            return ""
        }

        print("[Searcher] Found \(results.count) memories in \(String(format: "%.0f", elapsed))ms (top score: \(String(format: "%.2f", results.first?.score ?? 0)))")

        // Format memories for injection into system prompt
        return formatMemoriesForPrompt(results, isExplicitRecall: isRememberQuery)
    }

    // MARK: - Repairer: Maintain Memory Health

    /// Periodic maintenance — deduplicate, compress, prune stale memories.
    func runRepairCycle() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("[Repairer] Starting repair cycle...")

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

        print("[Repairer] Cycle complete in \(String(format: "%.0f", elapsed))ms — removed \(dupsRemoved) dupes, compressed \(compressed) episodes")
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

        print("[Watcher] Health check — \(memCount) memories (\(categories))")

        // Auto-repair if it's been more than 6 hours
        if Date().timeIntervalSince(lastRepairTime) > 21600 {
            print("[Watcher] Triggering scheduled repair cycle")
            await runRepairCycle()
        }

        // Check if Ollama is responsive
        if await !isOllamaAlive() {
            print("[Watcher] ⚠️ Ollama not responding — memory extraction will fail")
        }

        // Check embedding model is available
        if await !isModelAvailable("nomic-embed-text") {
            print("[Watcher] ⚠️ nomic-embed-text not available — run: ollama pull nomic-embed-text")
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
    }

    private func extractMemories(userMessage: String, assistantResponse: String) async -> [ExtractedMemory] {
        let prompt = """
        You are a memory extraction system. Extract facts worth remembering from this conversation.
        Only extract NEW, specific, useful information. Skip greetings and filler.

        Categories: "fact" (about user/world), "preference" (user likes/dislikes/style),
        "project" (work/creative projects), "technical" (tools/code/systems), "personal" (relationships/life)

        Return ONLY a JSON array. Each item: {"text": "...", "category": "...", "importance": 0.0-1.0}
        importance: 0.9+ = critical identity/relationship info, 0.7 = useful project context,
        0.5 = general facts, 0.3 = minor details

        If nothing worth extracting, return: []

        USER: \(userMessage.prefix(1500))
        ASSISTANT: \(assistantResponse.prefix(1500))
        """

        guard let response = await queryOllama(model: librarianModel, prompt: prompt, format: "json") else {
            return []
        }

        // Parse JSON array
        guard let data = response.data(using: .utf8) else { return [] }

        // Try parsing as array directly
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return parseExtracted(array)
        }

        // Try parsing as object with array inside
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let array = obj["memories"] as? [[String: Any]] ?? obj["facts"] as? [[String: Any]] ?? obj["items"] as? [[String: Any]] {
                return parseExtracted(array)
            }
        }

        return []
    }

    private func parseExtracted(_ array: [[String: Any]]) -> [ExtractedMemory] {
        return array.compactMap { item in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            let category = item["category"] as? String ?? "fact"
            let importance = Float(item["importance"] as? Double ?? 0.5)
            return ExtractedMemory(text: text, category: category, importance: importance)
        }
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
        // Use the LLM to find semantic duplicates that hash-based dedup missed
        // For now, use a simple approach: compare short texts for high overlap
        let allResults = await MemoryIndex.shared.search(query: "", topK: 0, minScore: 0)
        // Can't search with empty query — skip for now, rely on hash dedup
        // TODO: Implement pairwise similarity scan in MemoryIndex
        return 0
    }

    // MARK: - Internal: Episode Compression

    private func compressOldEpisodes() async -> Int {
        // Compress episode memories older than 7 days into weekly summaries
        // For now, this is a placeholder — episodes are already concise
        // TODO: Batch old episodes by week, summarize each batch into one memory
        return 0
    }

    // MARK: - Internal: Importance Decay

    private func decayOldMemories() async {
        // Slowly decay importance of memories that haven't been accessed
        // Identity and critical memories are exempt
        // This happens naturally through the importance boost in search scoring
    }

    // MARK: - Internal: Format for Prompt Injection

    private func formatMemoriesForPrompt(_ results: [MemoryIndex.SearchResult], isExplicitRecall: Bool) -> String {
        var sections: [String: [String]] = [:]

        for result in results {
            let key: String
            switch result.category {
            case "identity", "personal": key = "About Michael"
            case "preference": key = "Michael's Preferences"
            case "project": key = "Projects"
            case "technical": key = "Technical Context"
            case "episode": key = "Past Conversations"
            default: key = "Known Facts"
            }
            sections[key, default: []].append("• \(result.text)")
        }

        var output = "<memory>\n"
        if isExplicitRecall {
            output += "Michael is asking you to recall something. Here are your most relevant memories:\n\n"
        } else {
            output += "Your relevant memories for this conversation:\n\n"
        }

        // Order: identity first, then projects, then technical, then episodes
        let sectionOrder = ["About Michael", "Michael's Preferences", "Projects",
                          "Technical Context", "Known Facts", "Past Conversations"]

        for section in sectionOrder {
            if let items = sections[section], !items.isEmpty {
                output += "[\(section)]\n"
                output += items.joined(separator: "\n")
                output += "\n\n"
            }
        }

        output += "Use these memories naturally. Don't announce that you're reading memory.\n"
        output += "</memory>"

        return output
    }

    // MARK: - Migration: Existing MemoryManager → Index

    private func migrateExistingMemories() async {
        let index = MemoryIndex.shared
        let currentCount = await index.count

        // Only migrate if index is empty (first run)
        guard currentCount == 0 else {
            print("[Army] Index already populated (\(currentCount) memories) — skipping migration")
            return
        }

        print("[Army] Migrating existing memories to vector index...")

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
                await index.add(text: "Michael's location: \(location)", category: "personal", source: "migration", importance: 0.8)
                migrated += 1
            }
            if !occupation.isEmpty {
                await index.add(text: "Michael's work: \(occupation)", category: "personal", source: "migration", importance: 0.9)
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

        // Migrate from clawd/memory/sid/ files if accessible
        await migrateSidFiles()

        print("[Army] Migration complete — \(migrated) memories indexed from MemoryManager")
    }

    /// Migrate the scattered markdown/JSON files from clawd/memory/sid/
    private func migrateSidFiles() async {
        let basePath = FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/clawd/memory/sid"
        let index = MemoryIndex.shared

        // identity/core.md — already covered by MemoryManager migration
        // identity/michael.md — extract key facts
        if let content = try? String(contentsOfFile: basePath + "/identity/michael.md") {
            let lines = content.components(separatedBy: "\n")
                .filter { $0.contains("**") || ($0.hasPrefix("- ") && $0.count > 5) }
                .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.count > 10 }

            for line in lines {
                await index.add(text: line, category: "personal", source: "sid-files", importance: 0.7)
            }
        }

        // knowledge/learned-facts.md
        if let content = try? String(contentsOfFile: basePath + "/knowledge/learned-facts.md") {
            let lines = content.components(separatedBy: "\n")
                .filter { $0.hasPrefix("- ") && $0.count > 10 }
                .map { $0.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces) }

            for line in lines {
                await index.add(text: line, category: "fact", source: "sid-files", importance: 0.6)
            }
        }

        // working/learning-journal.md
        if let content = try? String(contentsOfFile: basePath + "/working/learning-journal.md") {
            let insights = content.components(separatedBy: "\n")
                .filter { $0.hasPrefix("- ") && $0.count > 15 }
                .map { $0.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces) }
                .prefix(20)

            for insight in insights {
                await index.add(text: insight, category: "fact", source: "sid-journal", importance: 0.5)
            }
        }

        print("[Army] Migrated clawd/memory/sid/ files to vector index")
    }

    // MARK: - Ollama Helpers

    private func queryOllama(model: String, prompt: String, format: String? = nil) async -> String? {
        guard let url = URL(string: "\(ollamaURL)/api/generate") else { return nil }

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
        guard let url = URL(string: "\(ollamaURL)/api/tags") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func isModelAvailable(_ name: String) async -> Bool {
        guard let url = URL(string: "\(ollamaURL)/api/tags") else { return false }
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
