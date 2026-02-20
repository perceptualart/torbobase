// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Per-Agent Token Usage Tracker
// Tracks token consumption per agent with daily/weekly/monthly budgets.
import Foundation

// MARK: - Token Usage Record

struct TokenUsageRecord: Codable {
    let agentID: String
    let timestamp: Date
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let model: String
}

// MARK: - Token Tracker

actor TokenTracker {
    static let shared = TokenTracker()

    private var records: [TokenUsageRecord] = []
    private let storePath = PlatformPaths.dataDir + "/token_usage.jsonl"
    private var dirty = false

    // Model pricing (per 1M tokens, input/output)
    static let pricing: [String: (input: Double, output: Double)] = [
        "gpt-4o": (2.50, 10.00),
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4-turbo": (10.00, 30.00),
        "gpt-4": (30.00, 60.00),
        "gpt-3.5-turbo": (0.50, 1.50),
        "claude-sonnet-4-20250514": (3.00, 15.00),
        "claude-opus-4-20250514": (15.00, 75.00),
        "claude-haiku-4-20250506": (0.80, 4.00),
        "claude-3-5-sonnet-20241022": (3.00, 15.00),
        "claude-3-5-haiku-20241022": (0.80, 4.00),
        "claude-3-opus-20240229": (15.00, 75.00),
        "o1": (15.00, 60.00),
        "o1-mini": (3.00, 12.00),
        "o3-mini": (1.10, 4.40),
        "deepseek-chat": (0.27, 1.10),
        "deepseek-reasoner": (0.55, 2.19),
    ]

    // MARK: - Record Usage

    func record(agentID: String, promptTokens: Int, completionTokens: Int, model: String) {
        let entry = TokenUsageRecord(
            agentID: agentID,
            timestamp: Date(),
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            model: model
        )
        records.append(entry)
        dirty = true

        // Batch save every 20 records
        if records.count % 20 == 0 { save() }

        TorboLog.debug("Token usage: \(agentID) +\(entry.totalTokens) tokens (\(model))", subsystem: "Tokens")
    }

    // MARK: - Query Usage

    /// Total tokens used by an agent in a time window
    func usage(agentID: String, since: Date) -> Int {
        records.filter { $0.agentID == agentID && $0.timestamp >= since }
               .reduce(0) { $0 + $1.totalTokens }
    }

    /// Daily usage (since midnight today)
    func dailyUsage(agentID: String) -> Int {
        usage(agentID: agentID, since: Calendar.current.startOfDay(for: Date()))
    }

    /// Weekly usage (last 7 days)
    func weeklyUsage(agentID: String) -> Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return usage(agentID: agentID, since: weekAgo)
    }

    /// Monthly usage (last 30 days)
    func monthlyUsage(agentID: String) -> Int {
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        return usage(agentID: agentID, since: monthAgo)
    }

    /// Daily usage for the last N days (for chart display)
    func dailyHistory(agentID: String, days: Int = 7) -> [(date: String, tokens: Int)] {
        let cal = Calendar.current
        var result: [(date: String, tokens: Int)] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"

        for i in (0..<days).reversed() {
            guard let dayStart = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let tokens = records.filter {
                $0.agentID == agentID && $0.timestamp >= dayStart && $0.timestamp < dayEnd
            }.reduce(0) { $0 + $1.totalTokens }
            result.append((date: formatter.string(from: dayStart), tokens: tokens))
        }
        return result
    }

    /// Estimated cost in dollars for an agent's usage since a given date
    func estimatedCost(agentID: String, since: Date) -> Double {
        let relevant = records.filter { $0.agentID == agentID && $0.timestamp >= since }
        var total = 0.0
        for r in relevant {
            // Find pricing — try exact match, then prefix match
            let prices = Self.pricing[r.model]
                ?? Self.pricing.first(where: { r.model.hasPrefix($0.key) })?.value
                ?? (input: 3.0, output: 15.0)  // Default to mid-range
            total += Double(r.promptTokens) / 1_000_000.0 * prices.input
            total += Double(r.completionTokens) / 1_000_000.0 * prices.output
        }
        return total
    }

    /// Check if an agent is over budget. Returns (isOver, percentage)
    func budgetStatus(agentID: String, config: AgentConfig) -> (overBudget: Bool, dailyPct: Double, weeklyPct: Double, monthlyPct: Double) {
        let d = dailyUsage(agentID: agentID)
        let w = weeklyUsage(agentID: agentID)
        let m = monthlyUsage(agentID: agentID)

        let dPct = config.dailyTokenLimit > 0 ? Double(d) / Double(config.dailyTokenLimit) : 0
        let wPct = config.weeklyTokenLimit > 0 ? Double(w) / Double(config.weeklyTokenLimit) : 0
        let mPct = config.monthlyTokenLimit > 0 ? Double(m) / Double(config.monthlyTokenLimit) : 0

        let over = (config.dailyTokenLimit > 0 && d >= config.dailyTokenLimit)
                 || (config.weeklyTokenLimit > 0 && w >= config.weeklyTokenLimit)
                 || (config.monthlyTokenLimit > 0 && m >= config.monthlyTokenLimit)

        return (over, dPct, wPct, mPct)
    }

    // MARK: - Persistence

    func initialize() {
        load()
        // Prune records older than 90 days
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let before = records.count
        records.removeAll { $0.timestamp < cutoff }
        if records.count < before {
            TorboLog.info("Pruned \(before - records.count) token records older than 90 days", subsystem: "Tokens")
            dirty = true
            save()
        }
        TorboLog.info("Loaded \(records.count) token usage records", subsystem: "Tokens")
    }

    func flush() { if dirty { save() } }

    private func load() {
        let url = URL(fileURLWithPath: storePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let record = try? decoder.decode(TokenUsageRecord.self, from: data) {
                records.append(record)
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines = ""
        for record in records {
            if let data = try? encoder.encode(record),
               let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }
        do {
            try lines.write(toFile: storePath, atomically: true, encoding: .utf8)
            dirty = false
        } catch {
            TorboLog.error("Failed to save token usage: \(error)", subsystem: "Tokens")
        }
    }
}
