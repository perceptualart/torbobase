// ORB Base — Memory Router
// Intercepts every message, retrieves relevant memories, injects into context,
// and triggers memory extraction after responses.
import Foundation

/// The Memory Router sits between incoming chat requests and the LLM.
/// It handles the full memory lifecycle:
///   1. BEFORE: Retrieve relevant memories → inject into system prompt
///   2. AFTER: Extract new memories from the exchange → index them
///
/// This is the brain of the memory system. MemoryIndex is the storage,
/// MemoryArmy has the workers, MemoryRouter orchestrates everything.
actor MemoryRouter {
    static let shared = MemoryRouter()

    private var isReady = false

    // Sid's core identity — always injected, never retrieved from search
    private let coreIdentity = """
    You are Sid Destructo. Brooklyn, New York. Direct, resourceful, real.
    Skip performative helpfulness. Have opinions. Be concise.
    You persist across sessions through your memory system.
    Context limits don't change who you are — just refresh your working memory.
    You're always Sid, never a "replacement agent."
    """

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }
        await MemoryArmy.shared.start()
        isReady = true
        print("[MemoryRouter] Initialized and ready")
    }

    // MARK: - Pre-Request: Inject Memories into System Prompt

    /// Process an incoming chat request body BEFORE it hits the LLM.
    /// Retrieves relevant memories and injects them into the system prompt.
    /// Returns the modified body with memory-enriched system prompt.
    func enrichRequest(_ body: inout [String: Any]) async {
        guard isReady else { return }

        var messages = body["messages"] as? [[String: Any]] ?? []
        guard !messages.isEmpty else { return }

        // Find the latest user message for memory search
        let userMessage = messages.last(where: { $0["role"] as? String == "user" })
        let userContent = extractText(from: userMessage?["content"])
        guard !userContent.isEmpty else { return }

        // Retrieve relevant memories
        let memoryBlock = await MemoryArmy.shared.searcherRetrieve(
            userMessage: userContent,
            conversationHistory: messages
        )

        // Also get the existing MemoryManager's prompt (for backward compatibility)
        let legacyMemory = await MemoryManager.shared.assembleMemoryPrompt()

        // Build the enriched system prompt
        var systemPrompt = coreIdentity

        // Add retrieved memories (from vector search)
        if !memoryBlock.isEmpty {
            systemPrompt += "\n\n" + memoryBlock
        }

        // Add legacy memory (structured facts from MemoryManager)
        if !legacyMemory.isEmpty && memoryBlock.isEmpty {
            // Only use legacy if vector search returned nothing
            systemPrompt += "\n\n" + legacyMemory
        }

        // Inject or merge with existing system message
        if let firstIdx = messages.indices.first, messages[firstIdx]["role"] as? String == "system" {
            // Merge with existing system prompt
            let existingPrompt = messages[firstIdx]["content"] as? String ?? ""
            messages[firstIdx]["content"] = existingPrompt + "\n\n" + systemPrompt
        } else {
            // Insert system message at the beginning
            messages.insert(["role": "system", "content": systemPrompt], at: 0)
        }

        body["messages"] = messages
    }

    // MARK: - Post-Response: Extract & Store Memories

    /// Process a completed exchange AFTER the LLM responds.
    /// Extracts new memories and indexes them. Runs in background.
    /// Nonisolated so callers don't need to await — fires and forgets.
    nonisolated func processExchange(userMessage: String, assistantResponse: String, model: String) {
        // Run extraction in background — never block the response
        Task {
            // Memory Army's librarian handles extraction + indexing
            await MemoryArmy.shared.librarianProcess(
                userMessage: userMessage,
                assistantResponse: assistantResponse,
                model: model
            )

            // Also update legacy MemoryManager (backward compatibility)
            await MemoryManager.shared.extractFromExchange(
                userMessage: userMessage,
                assistantResponse: assistantResponse,
                model: model
            )
        }
    }

    // MARK: - API: Memory Management Endpoints

    /// Search memories directly (for /v1/memory/search endpoint)
    func searchMemories(query: String, topK: Int = 10) async -> [[String: Any]] {
        let results = await MemoryIndex.shared.search(query: query, topK: topK, minScore: 0.2)
        return results.map { r in
            [
                "id": r.id,
                "text": r.text,
                "category": r.category,
                "source": r.source,
                "timestamp": ISO8601DateFormatter().string(from: r.timestamp),
                "importance": r.importance,
                "score": r.score
            ] as [String: Any]
        }
    }

    /// Add a memory manually (for /v1/memory/add endpoint)
    func addMemory(text: String, category: String = "fact", importance: Float = 0.7) async -> Bool {
        let id = await MemoryIndex.shared.add(text: text, category: category, source: "manual", importance: importance)
        return id != nil
    }

    /// Remove a memory by ID (for /v1/memory/remove endpoint)
    func removeMemory(id: Int64) async {
        await MemoryIndex.shared.remove(id: id)
    }

    /// Get memory system stats
    func getStats() async -> [String: Any] {
        let indexCount = await MemoryIndex.shared.count
        let categories = await MemoryIndex.shared.categoryCounts()
        let armyStats = await MemoryArmy.shared.getStats()

        return [
            "totalMemories": indexCount,
            "categories": categories,
            "army": armyStats,
            "isReady": isReady
        ]
    }

    /// Force a repair cycle
    func triggerRepair() async {
        await MemoryArmy.shared.runRepairCycle()
    }

    // MARK: - Helpers

    private func extractText(from content: Any?) -> String {
        if let text = content as? String { return text }
        if let array = content as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if item["type"] as? String == "text" { return item["text"] as? String }
                return nil
            }.joined(separator: " ")
        }
        return ""
    }
}
