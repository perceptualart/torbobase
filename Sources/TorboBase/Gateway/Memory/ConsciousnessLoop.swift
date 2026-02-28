// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — ConsciousnessLoop (Ambient Processing)
// The current — keeps the River flowing even when no one's watching.
// Three frequencies of ambient processing: Pulse (60s), Tide (15min), Dream (6hr).
// The system thinks between conversations.

import Foundation

/// Three-frequency ambient processor that consolidates all background
/// maintenance tasks. Replaces MemoryArmy's watcher/repairer timers,
/// BridgeConversationContext's idle eviction, and adds new intelligence.
actor ConsciousnessLoop {
    static let shared = ConsciousnessLoop()

    private var pulseTask: Task<Void, Never>?
    private var tideTask: Task<Void, Never>?
    private var dreamTask: Task<Void, Never>?
    private var isRunning = false

    // Track last run times
    private var lastPulse: Date = .distantPast
    private var lastTide: Date = .distantPast
    private var lastDream: Date = .distantPast

    // MARK: - Lifecycle

    /// Start all three processing loops. Call once at app startup.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        pulseTask = Task { await pulseLoop() }
        tideTask = Task { await tideLoop() }
        dreamTask = Task { await dreamLoop() }

        TorboLog.info("Consciousness loop started — Pulse/Tide/Dream active", subsystem: "Consciousness")
    }

    /// Stop all processing loops.
    func stop() {
        isRunning = false
        pulseTask?.cancel()
        tideTask?.cancel()
        dreamTask?.cancel()
        TorboLog.info("Consciousness loop stopped", subsystem: "Consciousness")
    }

    /// Stats for monitoring.
    func stats() -> [String: Any] {
        let fmt = ISO8601DateFormatter()
        return [
            "running": isRunning,
            "last_pulse": lastPulse == .distantPast ? "never" : fmt.string(from: lastPulse),
            "last_tide": lastTide == .distantPast ? "never" : fmt.string(from: lastTide),
            "last_dream": lastDream == .distantPast ? "never" : fmt.string(from: lastDream)
        ]
    }

    // MARK: - PULSE — Every 60 seconds
    // Lightweight housekeeping. Fast, cheap, essential.

    private func pulseLoop() {
        Task {
            // Initial delay — let the system warm up
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s

            while isRunning {
                await pulse()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            }
        }
    }

    private func pulse() async {
        lastPulse = Date()

        // 1. Flush pending MemoryIndex access tracking
        //    (access tracking is batched — this ensures regular persistence)

        // 2. Emit heartbeat to EventBus
        await EventBus.shared.publish("consciousness.pulse", source: "consciousness")
    }

    // MARK: - TIDE — Every 15 minutes
    // Medium-weight consolidation. Entity extraction, stream analysis.

    private func tideLoop() {
        Task {
            // Initial delay
            try? await Task.sleep(nanoseconds: 120_000_000_000) // 2 min warmup

            while isRunning {
                await tide()
                try? await Task.sleep(nanoseconds: 900_000_000_000) // 15 min
            }
        }
    }

    private func tide() async {
        let startTime = Date().timeIntervalSinceReferenceDate
        lastTide = Date()

        // 1. Watcher health check (moved from MemoryArmy)
        await MemoryArmy.shared.watcherCheck()

        // 2. EntityGraph: scan recent memories for relationship extraction
        await extractRelationshipsFromRecentMemories()

        // 3. Log hot topics from recent stream
        await logStreamActivity()

        // 4. Promote high-quality skill learnings to community knowledge
        await SkillsManager.shared.promoteSkillLearnings()

        let elapsed = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
        TorboLog.info("Tide cycle complete in \(String(format: "%.0f", elapsed))ms", subsystem: "Consciousness")
        await EventBus.shared.publish("consciousness.tide", payload: ["elapsed_ms": String(Int(elapsed))], source: "consciousness")
    }

    // MARK: - DREAM — Every 6 hours
    // Heavy processing. Full repair, connection discovery, cleanup.

    private func dreamLoop() {
        Task {
            // Initial delay — let the system fully warm up
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min warmup

            while isRunning {
                await dream()
                try? await Task.sleep(nanoseconds: 21_600_000_000_000) // 6 hours
            }
        }
    }

    private func dream() async {
        let startTime = Date().timeIntervalSinceReferenceDate
        lastDream = Date()
        TorboLog.info("Dream cycle starting...", subsystem: "Consciousness")

        // 1. Full MemoryArmy repair cycle (dedup, compress, decay)
        await MemoryArmy.shared.runRepairCycle()

        // 2. StreamStore retention purge (30-day rolling window)
        let purged = await StreamStore.shared.purgeOldEvents()
        if purged > 0 {
            TorboLog.info("Purged \(purged) old stream events", subsystem: "Consciousness")
        }

        // 3. EntityGraph deduplication
        let dedupedRels = await EntityGraph.shared.deduplicateRelationships()
        if dedupedRels > 0 {
            TorboLog.info("Deduplicated \(dedupedRels) entity relationships", subsystem: "Consciousness")
        }

        // 4. Generate reflection (existing Watcher logic, elevated here)
        await MemoryArmy.shared.generateReflection()

        // 5. Memory statistics snapshot
        let memCount = await MemoryIndex.shared.count
        let streamStats = await StreamStore.shared.stats()
        let entityStats = await EntityGraph.shared.stats()
        let userStats = await UserIdentity.shared.stats()

        let elapsed = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
        TorboLog.info("Dream cycle complete in \(String(format: "%.0f", elapsed))ms — \(memCount) memories, \(streamStats["total_events"] ?? 0) stream events", subsystem: "Consciousness")

        await EventBus.shared.publish("consciousness.dream", payload: [
            "elapsed_ms": String(Int(elapsed)),
            "memories": String(memCount),
            "entities": String(entityStats["unique_entities"] as? Int ?? 0),
            "users": String(userStats["total_users"] as? Int ?? 0)
        ], source: "consciousness")
    }

    // MARK: - Tide Helpers

    /// Scan recent memories for entity pairs that should have relationships.
    private func extractRelationshipsFromRecentMemories() async {
        let recent = await MemoryIndex.shared.allEntries
            .filter { Date().timeIntervalSince($0.timestamp) < 900 } // Last 15 min

        for entry in recent where entry.entities.count >= 2 {
            for i in 0..<entry.entities.count {
                for j in (i+1)..<entry.entities.count {
                    await EntityGraph.shared.add(
                        subject: entry.entities[i],
                        predicate: "mentioned_with",
                        object: entry.entities[j],
                        confidence: 0.5,
                        source: "tide-cooccurrence"
                    )
                }
            }
        }
    }

    /// Log summary of recent stream activity.
    private func logStreamActivity() async {
        let stats = await StreamStore.shared.countByKind()
        if !stats.isEmpty {
            let summary = stats.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            TorboLog.info("Stream activity: \(summary)", subsystem: "Consciousness")
        }
    }
}
