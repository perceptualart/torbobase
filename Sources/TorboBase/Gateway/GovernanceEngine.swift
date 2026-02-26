// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Governance & Observability Engine
// Logs every AI decision, tracks costs, provides audit trails, and enables human-in-the-loop approvals.
// SQLite-backed persistence with in-memory cache for real-time dashboard performance.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

// MARK: - Data Models

/// Risk level for actions requiring approval gates
enum RiskLevel: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var name: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        case .critical: return "CRITICAL"
        }
    }
}

/// A logged AI decision with full trace
struct GovernanceDecision: Codable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let agentID: String
    let action: String
    let reasoning: String
    let confidence: Double
    let outcome: String
    let cost: Double
    let riskLevel: RiskLevel
    let policyResult: String       // "allowed", "flagged", "blocked"
    let approved: Bool?            // nil = no approval needed, true/false = approved/rejected
    let approvedBy: String?
    let approvedAt: Date?
    let metadata: [String: String] // Extensible key-value pairs
    let taskID: String?
    let userID: String?

    func toDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "agentID": agentID,
            "action": action,
            "reasoning": reasoning,
            "confidence": confidence,
            "outcome": outcome,
            "cost": cost,
            "riskLevel": riskLevel.name,
            "policyResult": policyResult,
            "metadata": metadata
        ]
        if let approved { d["approved"] = approved }
        if let approvedBy { d["approvedBy"] = approvedBy }
        if let approvedAt { d["approvedAt"] = ISO8601DateFormatter().string(from: approvedAt) }
        if let taskID { d["taskID"] = taskID }
        if let userID { d["userID"] = userID }
        return d
    }
}

/// Result of checking an action against governance policies
struct PolicyResult: Sendable {
    enum Status: String, Sendable { case allowed, flagged, blocked }
    let status: Status
    let reason: String
    let matchedRules: [String]

    func toDict() -> [String: Any] {
        ["status": status.rawValue, "reason": reason, "matchedRules": matchedRules]
    }
}

/// Full decision trace for explainability
struct DecisionTrace: Sendable {
    let decision: GovernanceDecision
    let relatedDecisions: [GovernanceDecision]  // Same agent, same task
    let policyChecks: [String]
    let costBreakdown: [String: Double]

    func toDict() -> [String: Any] {
        [
            "decision": decision.toDict(),
            "relatedDecisions": relatedDecisions.map { $0.toDict() },
            "policyChecks": policyChecks,
            "costBreakdown": costBreakdown
        ]
    }
}

/// Detected anomaly in agent behavior
struct Anomaly: Codable, Sendable {
    let id: String
    let detectedAt: Date
    let agentID: String
    let type: String               // "cost_spike", "unusual_action", "high_frequency", "low_confidence"
    let severity: RiskLevel
    let description: String
    let dataPoints: [String: Double]

    func toDict() -> [String: Any] {
        [
            "id": id,
            "detectedAt": ISO8601DateFormatter().string(from: detectedAt),
            "agentID": agentID,
            "type": type,
            "severity": severity.name,
            "description": description,
            "dataPoints": dataPoints
        ]
    }
}

/// Governance policy rule
struct PolicyRule: Codable, Sendable {
    let id: String
    var name: String
    var enabled: Bool
    var riskLevel: RiskLevel
    var actionPattern: String      // Regex or glob pattern to match actions
    var requireApproval: Bool
    var maxCostPerAction: Double   // 0 = no limit
    var blockedAgents: [String]    // Agent IDs blocked from this action
    var description: String

    func toDict() -> [String: Any] {
        [
            "id": id, "name": name, "enabled": enabled,
            "riskLevel": riskLevel.name, "actionPattern": actionPattern,
            "requireApproval": requireApproval, "maxCostPerAction": maxCostPerAction,
            "blockedAgents": blockedAgents, "description": description
        ]
    }
}

/// Aggregate governance stats
struct GovernanceStats: Sendable {
    let totalDecisions: Int
    let totalCost: Double
    let pendingApprovals: Int
    let blockedActions: Int
    let anomalyCount: Int
    let costByAgent: [String: Double]
    let costByDay: [String: Double]
    let decisionsByAgent: [String: Int]
    let decisionsByAction: [String: Int]
    let avgConfidence: Double
    let approvalRate: Double          // % of approval requests that were approved

    func toDict() -> [String: Any] {
        [
            "totalDecisions": totalDecisions,
            "totalCost": totalCost,
            "pendingApprovals": pendingApprovals,
            "blockedActions": blockedActions,
            "anomalyCount": anomalyCount,
            "costByAgent": costByAgent,
            "costByDay": costByDay,
            "decisionsByAgent": decisionsByAgent,
            "decisionsByAction": decisionsByAction,
            "avgConfidence": avgConfidence,
            "approvalRate": approvalRate
        ]
    }
}

/// Pending approval request
struct ApprovalRequest: Sendable {
    let decisionID: String
    let agentID: String
    let action: String
    let reasoning: String
    let riskLevel: RiskLevel
    let estimatedCost: Double
    let requestedAt: Date

    func toDict() -> [String: Any] {
        [
            "decisionID": decisionID,
            "agentID": agentID,
            "action": action,
            "reasoning": reasoning,
            "riskLevel": riskLevel.name,
            "estimatedCost": estimatedCost,
            "requestedAt": ISO8601DateFormatter().string(from: requestedAt)
        ]
    }
}

// MARK: - Governance Engine

actor GovernanceEngine {
    static let shared = GovernanceEngine()

    private var db: OpaquePointer?
    private let dbPath: String
    private var isReady = false

    // In-memory caches for dashboard performance
    private var recentDecisions: [GovernanceDecision] = []
    private var pendingApprovals: [String: ApprovalRequest] = [:]  // decisionID → request
    private var approvalContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var policies: [PolicyRule] = []
    private var anomalies: [Anomaly] = []
    private var costAccumulator: [String: Double] = [:]   // agentID → total cost
    private var decisionCounts: [String: Int] = [:]        // agentID → count
    private var hourlyActionCounts: [String: [Date]] = [:] // agentID → timestamps (for frequency detection)

    private let maxRecentDecisions = 500
    private let maxAnomalies = 200
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        let dir = URL(fileURLWithPath: PlatformPaths.dataDir).appendingPathComponent("governance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("governance.db").path
    }

    // MARK: - Initialize

    func initialize() async {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open governance database: \(dbPath)", subsystem: "Governance")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        // Decisions table
        exec("""
            CREATE TABLE IF NOT EXISTS decisions (
                id TEXT PRIMARY KEY,
                timestamp TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                action TEXT NOT NULL,
                reasoning TEXT NOT NULL DEFAULT '',
                confidence REAL NOT NULL DEFAULT 0.5,
                outcome TEXT NOT NULL DEFAULT '',
                cost REAL NOT NULL DEFAULT 0.0,
                risk_level INTEGER NOT NULL DEFAULT 0,
                policy_result TEXT NOT NULL DEFAULT 'allowed',
                approved INTEGER,
                approved_by TEXT,
                approved_at TEXT,
                metadata TEXT NOT NULL DEFAULT '{}',
                task_id TEXT,
                user_id TEXT
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_decisions_agent ON decisions(agent_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_decisions_timestamp ON decisions(timestamp DESC)")
        exec("CREATE INDEX IF NOT EXISTS idx_decisions_action ON decisions(action)")
        exec("CREATE INDEX IF NOT EXISTS idx_decisions_risk ON decisions(risk_level)")
        exec("CREATE INDEX IF NOT EXISTS idx_decisions_approved ON decisions(approved)")

        // Policies table
        exec("""
            CREATE TABLE IF NOT EXISTS policies (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                risk_level INTEGER NOT NULL DEFAULT 0,
                action_pattern TEXT NOT NULL DEFAULT '*',
                require_approval INTEGER NOT NULL DEFAULT 0,
                max_cost_per_action REAL NOT NULL DEFAULT 0.0,
                blocked_agents TEXT NOT NULL DEFAULT '[]',
                description TEXT NOT NULL DEFAULT ''
            )
        """)

        // Anomalies table
        exec("""
            CREATE TABLE IF NOT EXISTS anomalies (
                id TEXT PRIMARY KEY,
                detected_at TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                type TEXT NOT NULL,
                severity INTEGER NOT NULL DEFAULT 0,
                description TEXT NOT NULL,
                data_points TEXT NOT NULL DEFAULT '{}'
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_anomalies_agent ON anomalies(agent_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_anomalies_detected ON anomalies(detected_at DESC)")

        // Cost tracking table (aggregated per agent per day)
        exec("""
            CREATE TABLE IF NOT EXISTS cost_tracking (
                agent_id TEXT NOT NULL,
                day TEXT NOT NULL,
                total_cost REAL NOT NULL DEFAULT 0.0,
                request_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (agent_id, day)
            )
        """)

        // Load caches
        loadRecentDecisions()
        loadPolicies()
        loadAnomalies()
        loadCostAccumulator()

        // Install default policies if empty
        if policies.isEmpty {
            installDefaultPolicies()
        }

        isReady = true
        TorboLog.info("Governance engine initialized — \(recentDecisions.count) decisions, \(policies.count) policies, \(anomalies.count) anomalies", subsystem: "Governance")
    }

    // MARK: - Log Decision

    /// Log an AI decision to the governance audit trail
    func logDecision(
        agent agentID: String,
        action: String,
        reasoning: String = "",
        confidence: Double = 0.5,
        outcome: String = "",
        cost: Double = 0.0,
        riskLevel: RiskLevel = .low,
        taskID: String? = nil,
        userID: String? = nil,
        metadata: [String: String] = [:]
    ) async -> String {
        let id = UUID().uuidString
        let now = Date()
        let policyResult = checkPolicy(action: action, agentID: agentID, cost: cost)

        let decision = GovernanceDecision(
            id: id, timestamp: now, agentID: agentID,
            action: action, reasoning: reasoning, confidence: confidence,
            outcome: outcome, cost: cost, riskLevel: riskLevel,
            policyResult: policyResult.status.rawValue,
            approved: policyResult.status == .blocked ? false : nil,
            approvedBy: nil, approvedAt: nil,
            metadata: metadata, taskID: taskID, userID: userID
        )

        // Persist to SQLite
        insertDecision(decision)

        // Update in-memory caches
        recentDecisions.insert(decision, at: 0)
        if recentDecisions.count > maxRecentDecisions {
            recentDecisions = Array(recentDecisions.prefix(maxRecentDecisions))
        }

        // Track costs
        costAccumulator[agentID, default: 0] += cost
        decisionCounts[agentID, default: 0] += 1
        trackDailyCost(agentID: agentID, cost: cost)

        // Track action frequency for anomaly detection
        hourlyActionCounts[agentID, default: []].append(now)

        // Log
        if policyResult.status == .blocked {
            TorboLog.warn("Decision BLOCKED: \(action) by \(agentID) — \(policyResult.reason)", subsystem: "Governance")
        } else if policyResult.status == .flagged {
            TorboLog.info("Decision FLAGGED: \(action) by \(agentID) — \(policyResult.reason)", subsystem: "Governance")
        } else {
            TorboLog.debug("Decision logged: \(action) by \(agentID) (cost: $\(String(format: "%.4f", cost)))", subsystem: "Governance")
        }

        return id
    }

    // MARK: - Approval Gates

    /// Request human approval for a high-risk action.
    /// Suspends until a human approves or rejects via the dashboard/API.
    /// Returns true if approved, false if rejected or timed out.
    func requireApproval(for action: String, agentID: String, reasoning: String = "", riskLevel: RiskLevel = .high, estimatedCost: Double = 0.0) async -> Bool {
        let decisionID = UUID().uuidString
        let request = ApprovalRequest(
            decisionID: decisionID, agentID: agentID,
            action: action, reasoning: reasoning,
            riskLevel: riskLevel, estimatedCost: estimatedCost,
            requestedAt: Date()
        )

        pendingApprovals[decisionID] = request
        TorboLog.info("Approval requested: \(action) by \(agentID) [risk: \(riskLevel.name)] — waiting...", subsystem: "Governance")

        // Suspend until approved/rejected or timeout (5 minutes)
        let approved: Bool = await withCheckedContinuation { continuation in
            approvalContinuations[decisionID] = continuation

            // Timeout after 5 minutes — auto-reject
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
                if let cont = await self.timeoutApproval(decisionID) {
                    cont.resume(returning: false)
                }
            }
        }

        // Log the decision
        _ = await logDecision(
            agent: agentID, action: action, reasoning: reasoning,
            confidence: 0.5, outcome: approved ? "approved" : "rejected",
            cost: estimatedCost, riskLevel: riskLevel
        )

        return approved
    }

    /// Called when timeout fires — removes and returns continuation if still pending
    private func timeoutApproval(_ decisionID: String) -> CheckedContinuation<Bool, Never>? {
        guard pendingApprovals.removeValue(forKey: decisionID) != nil else { return nil }
        let cont = approvalContinuations.removeValue(forKey: decisionID)
        if cont != nil {
            TorboLog.warn("Approval timed out: \(decisionID)", subsystem: "Governance")
        }
        return cont
    }

    /// Approve a pending decision (called from dashboard/API)
    func approve(decisionID: String, approvedBy: String = "admin") -> Bool {
        guard pendingApprovals.removeValue(forKey: decisionID) != nil else { return false }
        if let continuation = approvalContinuations.removeValue(forKey: decisionID) {
            continuation.resume(returning: true)
        }
        // Update the stored decision
        updateApprovalStatus(decisionID: decisionID, approved: true, approvedBy: approvedBy)
        TorboLog.info("Approval GRANTED: \(decisionID) by \(approvedBy)", subsystem: "Governance")
        return true
    }

    /// Reject a pending decision (called from dashboard/API)
    func reject(decisionID: String, rejectedBy: String = "admin") -> Bool {
        guard pendingApprovals.removeValue(forKey: decisionID) != nil else { return false }
        if let continuation = approvalContinuations.removeValue(forKey: decisionID) {
            continuation.resume(returning: false)
        }
        updateApprovalStatus(decisionID: decisionID, approved: false, approvedBy: rejectedBy)
        TorboLog.info("Approval REJECTED: \(decisionID) by \(rejectedBy)", subsystem: "Governance")
        return true
    }

    /// List pending approvals
    func listPendingApprovals() -> [ApprovalRequest] {
        Array(pendingApprovals.values).sorted { $0.requestedAt > $1.requestedAt }
    }

    // MARK: - Policy Enforcement

    /// Check an action against all governance policies
    func checkPolicy(action: String, agentID: String = "", cost: Double = 0.0) -> PolicyResult {
        var matchedRules: [String] = []
        var worstStatus: PolicyResult.Status = .allowed
        var reason = ""

        for policy in policies where policy.enabled {
            // Check action pattern match
            guard actionMatches(action, pattern: policy.actionPattern) else { continue }

            matchedRules.append(policy.name)

            // Check blocked agents
            if policy.blockedAgents.contains(agentID) {
                worstStatus = .blocked
                reason = "Agent '\(agentID)' blocked by policy '\(policy.name)'"
                break
            }

            // Check cost limit
            if policy.maxCostPerAction > 0 && cost > policy.maxCostPerAction {
                worstStatus = .blocked
                reason = "Cost $\(String(format: "%.4f", cost)) exceeds limit $\(String(format: "%.4f", policy.maxCostPerAction)) in policy '\(policy.name)'"
                break
            }

            // Check if approval required
            if policy.requireApproval && worstStatus == .allowed {
                worstStatus = .flagged
                reason = "Requires approval per policy '\(policy.name)'"
            }

            // Bump to flagged for high/critical risk policies
            if policy.riskLevel >= .high && worstStatus == .allowed {
                worstStatus = .flagged
                reason = "High-risk action matched policy '\(policy.name)'"
            }
        }

        return PolicyResult(status: worstStatus, reason: reason, matchedRules: matchedRules)
    }

    /// Simple glob-style action matching (* = wildcard)
    private func actionMatches(_ action: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        let lowAction = action.lowercased()
        let lowPattern = pattern.lowercased()

        if lowPattern.hasPrefix("*") && lowPattern.hasSuffix("*") {
            let inner = String(lowPattern.dropFirst().dropLast())
            return lowAction.contains(inner)
        } else if lowPattern.hasPrefix("*") {
            return lowAction.hasSuffix(String(lowPattern.dropFirst()))
        } else if lowPattern.hasSuffix("*") {
            return lowAction.hasPrefix(String(lowPattern.dropLast()))
        }
        return lowAction == lowPattern
    }

    // MARK: - Decision Explainability

    /// Get the full decision trace for a specific decision
    func explainDecision(id: String) -> DecisionTrace? {
        guard let decision = recentDecisions.first(where: { $0.id == id }) ?? fetchDecision(id: id) else {
            return nil
        }

        // Find related decisions (same agent + same task or recent)
        let related: [GovernanceDecision]
        if let taskID = decision.taskID {
            related = recentDecisions.filter { $0.taskID == taskID && $0.id != id }
        } else {
            related = recentDecisions.filter {
                $0.agentID == decision.agentID && $0.id != id &&
                abs($0.timestamp.timeIntervalSince(decision.timestamp)) < 300
            }.prefix(10).map { $0 }
        }

        // Build policy check log
        let policyChecks = policies.filter { $0.enabled }.map { policy -> String in
            let matches = actionMatches(decision.action, pattern: policy.actionPattern)
            return "\(policy.name): \(matches ? "MATCHED" : "no match") [\(policy.actionPattern)]"
        }

        // Cost breakdown
        let agentTotal = costAccumulator[decision.agentID] ?? 0
        let costBreakdown: [String: Double] = [
            "this_action": decision.cost,
            "agent_total": agentTotal,
            "agent_average": agentTotal / Double(max(1, decisionCounts[decision.agentID] ?? 1))
        ]

        return DecisionTrace(
            decision: decision,
            relatedDecisions: Array(related.prefix(10)),
            policyChecks: policyChecks,
            costBreakdown: costBreakdown
        )
    }

    // MARK: - Cost Tracking

    /// Track a cost event for an agent
    func trackCost(agent agentID: String, amount: Double) async {
        costAccumulator[agentID, default: 0] += amount
        trackDailyCost(agentID: agentID, cost: amount)
        TorboLog.debug("Cost tracked: \(agentID) +$\(String(format: "%.4f", amount)) (total: $\(String(format: "%.4f", costAccumulator[agentID] ?? 0)))", subsystem: "Governance")
    }

    private func trackDailyCost(agentID: String, cost: Double) {
        guard cost > 0 else { return }
        let today = dayFormatter.string(from: Date())
        exec("""
            INSERT INTO cost_tracking (agent_id, day, total_cost, request_count)
            VALUES ('\(escapeSql(agentID))', '\(today)', \(cost), 1)
            ON CONFLICT(agent_id, day) DO UPDATE SET
                total_cost = total_cost + \(cost),
                request_count = request_count + 1
        """)
    }

    // MARK: - Anomaly Detection

    /// Scan for anomalies in recent agent behavior
    func detectAnomalies() async -> [Anomaly] {
        var detected: [Anomaly] = []
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        for (agentID, timestamps) in hourlyActionCounts {
            // Clean old timestamps
            hourlyActionCounts[agentID] = timestamps.filter { $0 > oneHourAgo }
            let recentCount = hourlyActionCounts[agentID]?.count ?? 0

            // High frequency detection: > 100 actions/hour
            if recentCount > 100 {
                let anomaly = Anomaly(
                    id: UUID().uuidString, detectedAt: now, agentID: agentID,
                    type: "high_frequency", severity: .medium,
                    description: "Agent '\(agentID)' made \(recentCount) decisions in the last hour (threshold: 100)",
                    dataPoints: ["actions_per_hour": Double(recentCount), "threshold": 100]
                )
                detected.append(anomaly)
            }
        }

        // Cost spike detection: agent's recent cost > 3x their average
        for (agentID, totalCost) in costAccumulator {
            let count = decisionCounts[agentID] ?? 1
            let avgCost = totalCost / Double(max(count, 1))
            let recentCosts = recentDecisions.filter { $0.agentID == agentID }.prefix(10)
            let recentAvg = recentCosts.isEmpty ? 0 : recentCosts.reduce(0.0) { $0 + $1.cost } / Double(recentCosts.count)

            if avgCost > 0 && recentAvg > avgCost * 3 && recentAvg > 0.01 {
                let anomaly = Anomaly(
                    id: UUID().uuidString, detectedAt: now, agentID: agentID,
                    type: "cost_spike", severity: .high,
                    description: "Agent '\(agentID)' recent avg cost ($\(String(format: "%.4f", recentAvg))) is 3x+ above lifetime avg ($\(String(format: "%.4f", avgCost)))",
                    dataPoints: ["recent_avg": recentAvg, "lifetime_avg": avgCost, "multiplier": recentAvg / avgCost]
                )
                detected.append(anomaly)
            }
        }

        // Low confidence detection: agent repeatedly making low-confidence decisions
        for agentID in Set(recentDecisions.prefix(100).map(\.agentID)) {
            let agentDecisions = recentDecisions.filter { $0.agentID == agentID }.prefix(20)
            let lowConf = agentDecisions.filter { $0.confidence < 0.3 }
            if lowConf.count > 5 {
                let avgConf = agentDecisions.reduce(0.0) { $0 + $1.confidence } / Double(agentDecisions.count)
                let anomaly = Anomaly(
                    id: UUID().uuidString, detectedAt: now, agentID: agentID,
                    type: "low_confidence", severity: .medium,
                    description: "Agent '\(agentID)' has \(lowConf.count)/\(agentDecisions.count) recent low-confidence decisions (avg: \(String(format: "%.2f", avgConf)))",
                    dataPoints: ["low_confidence_count": Double(lowConf.count), "avg_confidence": avgConf]
                )
                detected.append(anomaly)
            }
        }

        // Persist new anomalies
        for anomaly in detected {
            insertAnomaly(anomaly)
            anomalies.insert(anomaly, at: 0)
        }
        if anomalies.count > maxAnomalies {
            anomalies = Array(anomalies.prefix(maxAnomalies))
        }

        if !detected.isEmpty {
            TorboLog.warn("Detected \(detected.count) anomalies", subsystem: "Governance")
        }

        return detected
    }

    // MARK: - Audit Trail Export

    /// Export the full audit trail in JSON or CSV format
    func exportAuditTrail(format: String = "json", limit: Int = 10000) async -> Data {
        let decisions = fetchDecisions(limit: limit, offset: 0)

        if format.lowercased() == "csv" {
            return exportCSV(decisions)
        } else {
            return exportJSON(decisions)
        }
    }

    private func exportJSON(_ decisions: [GovernanceDecision]) -> Data {
        let dicts = decisions.map { $0.toDict() }
        let export: [String: Any] = [
            "exported_at": isoFormatter.string(from: Date()),
            "total_records": dicts.count,
            "decisions": dicts
        ]
        return (try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private func exportCSV(_ decisions: [GovernanceDecision]) -> Data {
        var csv = "id,timestamp,agentID,action,reasoning,confidence,outcome,cost,riskLevel,policyResult,approved,approvedBy,taskID,userID\n"
        for d in decisions {
            let ts = isoFormatter.string(from: d.timestamp)
            let reasoning = d.reasoning.replacingOccurrences(of: "\"", with: "\"\"")
            let outcome = d.outcome.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(d.id),\(ts),\(d.agentID),\"\(d.action)\",\"\(reasoning)\",\(d.confidence),\"\(outcome)\",\(d.cost),\(d.riskLevel.name),\(d.policyResult),\(d.approved.map { String($0) } ?? ""),\(d.approvedBy ?? ""),\(d.taskID ?? ""),\(d.userID ?? "")\n"
        }
        return Data(csv.utf8)
    }

    // MARK: - Stats

    /// Get aggregate governance statistics
    func getStats() async -> GovernanceStats {
        let totalDecisions = recentDecisions.count + countAllDecisions()
        let totalCost = costAccumulator.values.reduce(0, +)
        let pending = pendingApprovals.count
        let blocked = recentDecisions.filter { $0.policyResult == "blocked" }.count
        let anomalyCount = anomalies.count

        var costByAgent: [String: Double] = [:]
        var decisionsByAgent: [String: Int] = [:]
        var decisionsByAction: [String: Int] = [:]
        var totalConfidence: Double = 0
        var confCount = 0

        for d in recentDecisions {
            costByAgent[d.agentID, default: 0] += d.cost
            decisionsByAgent[d.agentID, default: 0] += 1
            decisionsByAction[d.action, default: 0] += 1
            totalConfidence += d.confidence
            confCount += 1
        }

        // Cost by day from SQLite
        let costByDay = fetchCostByDay()

        // Approval rate
        let approvalDecisions = recentDecisions.filter { $0.approved != nil }
        let approvedCount = approvalDecisions.filter { $0.approved == true }.count
        let approvalRate = approvalDecisions.isEmpty ? 1.0 : Double(approvedCount) / Double(approvalDecisions.count)

        return GovernanceStats(
            totalDecisions: totalDecisions,
            totalCost: totalCost,
            pendingApprovals: pending,
            blockedActions: blocked,
            anomalyCount: anomalyCount,
            costByAgent: costByAgent,
            costByDay: costByDay,
            decisionsByAgent: decisionsByAgent,
            decisionsByAction: decisionsByAction,
            avgConfidence: confCount > 0 ? totalConfidence / Double(confCount) : 0,
            approvalRate: approvalRate
        )
    }

    // MARK: - Policy Management

    func getPolicies() -> [PolicyRule] { policies }

    func updatePolicies(_ newPolicies: [PolicyRule]) {
        // Clear and replace
        exec("DELETE FROM policies")
        for policy in newPolicies {
            insertPolicy(policy)
        }
        policies = newPolicies
        TorboLog.info("Updated \(newPolicies.count) governance policies", subsystem: "Governance")
    }

    func addPolicy(_ policy: PolicyRule) {
        insertPolicy(policy)
        policies.append(policy)
        TorboLog.info("Added policy: \(policy.name)", subsystem: "Governance")
    }

    // MARK: - Query Methods

    /// Get recent decisions with pagination
    func getDecisions(limit: Int = 50, offset: Int = 0) -> [GovernanceDecision] {
        if offset == 0 && limit <= recentDecisions.count {
            return Array(recentDecisions.prefix(limit))
        }
        return fetchDecisions(limit: limit, offset: offset)
    }

    /// Get a specific decision by ID
    func getDecision(id: String) -> GovernanceDecision? {
        recentDecisions.first(where: { $0.id == id }) ?? fetchDecision(id: id)
    }

    /// Get anomalies
    func getAnomalies() -> [Anomaly] { anomalies }

    // MARK: - SQLite Helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            // Suppress "duplicate column" errors from migrations
            if !msg.contains("duplicate column") {
                TorboLog.error("SQL error: \(msg) — \(sql.prefix(120))", subsystem: "Governance")
            }
        }
    }

    private func escapeSql(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private func insertDecision(_ d: GovernanceDecision) {
        guard let db else { return }
        let sql = "INSERT INTO decisions (id, timestamp, agent_id, action, reasoning, confidence, outcome, cost, risk_level, policy_result, approved, approved_by, approved_at, metadata, task_id, user_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let ts = isoFormatter.string(from: d.timestamp)
        let metaJSON = (try? JSONSerialization.data(withJSONObject: d.metadata)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        sqlite3_bind_text(stmt, 1, (d.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (ts as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (d.agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (d.action as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (d.reasoning as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, d.confidence)
        sqlite3_bind_text(stmt, 7, (d.outcome as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 8, d.cost)
        sqlite3_bind_int(stmt, 9, Int32(d.riskLevel.rawValue))
        sqlite3_bind_text(stmt, 10, (d.policyResult as NSString).utf8String, -1, nil)
        if let approved = d.approved { sqlite3_bind_int(stmt, 11, approved ? 1 : 0) }
        else { sqlite3_bind_null(stmt, 11) }
        if let by = d.approvedBy { sqlite3_bind_text(stmt, 12, (by as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 12) }
        if let at = d.approvedAt { sqlite3_bind_text(stmt, 13, (isoFormatter.string(from: at) as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_text(stmt, 14, (metaJSON as NSString).utf8String, -1, nil)
        if let tid = d.taskID { sqlite3_bind_text(stmt, 15, (tid as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 15) }
        if let uid = d.userID { sqlite3_bind_text(stmt, 16, (uid as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 16) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            TorboLog.error("Failed to insert decision \(d.id)", subsystem: "Governance")
        }
    }

    private func updateApprovalStatus(decisionID: String, approved: Bool, approvedBy: String) {
        guard let db else { return }
        let sql = "UPDATE decisions SET approved = ?, approved_by = ?, approved_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = isoFormatter.string(from: Date())
        sqlite3_bind_int(stmt, 1, approved ? 1 : 0)
        sqlite3_bind_text(stmt, 2, (approvedBy as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (decisionID as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)

        // Update in-memory cache too
        if let idx = recentDecisions.firstIndex(where: { $0.id == decisionID }) {
            let old = recentDecisions[idx]
            recentDecisions[idx] = GovernanceDecision(
                id: old.id, timestamp: old.timestamp, agentID: old.agentID,
                action: old.action, reasoning: old.reasoning, confidence: old.confidence,
                outcome: approved ? "approved" : "rejected", cost: old.cost, riskLevel: old.riskLevel,
                policyResult: old.policyResult, approved: approved, approvedBy: approvedBy,
                approvedAt: Date(), metadata: old.metadata, taskID: old.taskID, userID: old.userID
            )
        }
    }

    private func insertPolicy(_ p: PolicyRule) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO policies (id, name, enabled, risk_level, action_pattern, require_approval, max_cost_per_action, blocked_agents, description) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let agentsJSON = (try? JSONSerialization.data(withJSONObject: p.blockedAgents)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (p.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (p.name as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, p.enabled ? 1 : 0)
        sqlite3_bind_int(stmt, 4, Int32(p.riskLevel.rawValue))
        sqlite3_bind_text(stmt, 5, (p.actionPattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 6, p.requireApproval ? 1 : 0)
        sqlite3_bind_double(stmt, 7, p.maxCostPerAction)
        sqlite3_bind_text(stmt, 8, (agentsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (p.description as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            TorboLog.error("Failed to insert policy \(p.id)", subsystem: "Governance")
        }
    }

    private func insertAnomaly(_ a: Anomaly) {
        guard let db else { return }
        let sql = "INSERT INTO anomalies (id, detected_at, agent_id, type, severity, description, data_points) VALUES (?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let ts = isoFormatter.string(from: a.detectedAt)
        let dpJSON = (try? JSONSerialization.data(withJSONObject: a.dataPoints)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        sqlite3_bind_text(stmt, 1, (a.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (ts as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (a.agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (a.type as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 5, Int32(a.severity.rawValue))
        sqlite3_bind_text(stmt, 6, (a.description as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (dpJSON as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            TorboLog.error("Failed to insert anomaly \(a.id)", subsystem: "Governance")
        }
    }

    // MARK: - Load from SQLite

    private func loadRecentDecisions() {
        recentDecisions = fetchDecisions(limit: maxRecentDecisions, offset: 0)
    }

    private func fetchDecisions(limit: Int, offset: Int) -> [GovernanceDecision] {
        guard let db else { return [] }
        let sql = "SELECT id, timestamp, agent_id, action, reasoning, confidence, outcome, cost, risk_level, policy_result, approved, approved_by, approved_at, metadata, task_id, user_id FROM decisions ORDER BY timestamp DESC LIMIT ? OFFSET ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        var results: [GovernanceDecision] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let decision = decisionFromRow(stmt) {
                results.append(decision)
            }
        }
        return results
    }

    private func fetchDecision(id: String) -> GovernanceDecision? {
        guard let db else { return nil }
        let sql = "SELECT id, timestamp, agent_id, action, reasoning, confidence, outcome, cost, risk_level, policy_result, approved, approved_by, approved_at, metadata, task_id, user_id FROM decisions WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return decisionFromRow(stmt)
        }
        return nil
    }

    private func decisionFromRow(_ stmt: OpaquePointer?) -> GovernanceDecision? {
        guard let stmt else { return nil }
        guard let idPtr = sqlite3_column_text(stmt, 0),
              let tsPtr = sqlite3_column_text(stmt, 1),
              let agentPtr = sqlite3_column_text(stmt, 2),
              let actionPtr = sqlite3_column_text(stmt, 3) else { return nil }

        let id = String(cString: idPtr)
        let tsStr = String(cString: tsPtr)
        let agentID = String(cString: agentPtr)
        let action = String(cString: actionPtr)

        let reasoning = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let confidence = sqlite3_column_double(stmt, 5)
        let outcome = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
        let cost = sqlite3_column_double(stmt, 7)
        let riskLevelRaw = Int(sqlite3_column_int(stmt, 8))
        let policyResult = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "allowed"

        let approved: Bool? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : (sqlite3_column_int(stmt, 10) != 0)
        let approvedBy = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        let approvedAtStr = sqlite3_column_text(stmt, 12).map { String(cString: $0) }

        let metaStr = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? "{}"
        let metadata = (try? JSONSerialization.jsonObject(with: Data(metaStr.utf8)) as? [String: String]) ?? [:]

        let taskID = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        let userID = sqlite3_column_text(stmt, 15).map { String(cString: $0) }

        let timestamp = isoFormatter.date(from: tsStr) ?? Date()
        let approvedAt = approvedAtStr.flatMap { isoFormatter.date(from: $0) }
        let riskLevel = RiskLevel(rawValue: riskLevelRaw) ?? .low

        return GovernanceDecision(
            id: id, timestamp: timestamp, agentID: agentID,
            action: action, reasoning: reasoning, confidence: confidence,
            outcome: outcome, cost: cost, riskLevel: riskLevel,
            policyResult: policyResult, approved: approved,
            approvedBy: approvedBy, approvedAt: approvedAt,
            metadata: metadata, taskID: taskID, userID: userID
        )
    }

    private func loadPolicies() {
        guard let db else { return }
        let sql = "SELECT id, name, enabled, risk_level, action_pattern, require_approval, max_cost_per_action, blocked_agents, description FROM policies ORDER BY name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        policies = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1) else { continue }

            let id = String(cString: idPtr)
            let name = String(cString: namePtr)
            let enabled = sqlite3_column_int(stmt, 2) != 0
            let riskLevel = RiskLevel(rawValue: Int(sqlite3_column_int(stmt, 3))) ?? .low
            let actionPattern = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "*"
            let requireApproval = sqlite3_column_int(stmt, 5) != 0
            let maxCost = sqlite3_column_double(stmt, 6)
            let agentsStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"
            let blockedAgents = (try? JSONSerialization.jsonObject(with: Data(agentsStr.utf8)) as? [String]) ?? []
            let description = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""

            policies.append(PolicyRule(
                id: id, name: name, enabled: enabled, riskLevel: riskLevel,
                actionPattern: actionPattern, requireApproval: requireApproval,
                maxCostPerAction: maxCost, blockedAgents: blockedAgents,
                description: description
            ))
        }
    }

    private func loadAnomalies() {
        guard let db else { return }
        let sql = "SELECT id, detected_at, agent_id, type, severity, description, data_points FROM anomalies ORDER BY detected_at DESC LIMIT \(maxAnomalies)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        anomalies = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let tsPtr = sqlite3_column_text(stmt, 1),
                  let agentPtr = sqlite3_column_text(stmt, 2),
                  let typePtr = sqlite3_column_text(stmt, 3) else { continue }

            let descStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let dpStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "{}"
            let dataPoints = (try? JSONSerialization.jsonObject(with: Data(dpStr.utf8)) as? [String: Double]) ?? [:]

            anomalies.append(Anomaly(
                id: String(cString: idPtr),
                detectedAt: isoFormatter.date(from: String(cString: tsPtr)) ?? Date(),
                agentID: String(cString: agentPtr),
                type: String(cString: typePtr),
                severity: RiskLevel(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .low,
                description: descStr,
                dataPoints: dataPoints
            ))
        }
    }

    private func loadCostAccumulator() {
        guard let db else { return }
        let sql = "SELECT agent_id, SUM(total_cost), SUM(request_count) FROM cost_tracking GROUP BY agent_id"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let agentPtr = sqlite3_column_text(stmt, 0) else { continue }
            let agentID = String(cString: agentPtr)
            costAccumulator[agentID] = sqlite3_column_double(stmt, 1)
            decisionCounts[agentID] = Int(sqlite3_column_int(stmt, 2))
        }
    }

    private func fetchCostByDay() -> [String: Double] {
        guard let db else { return [:] }
        let sql = "SELECT day, SUM(total_cost) FROM cost_tracking WHERE day >= date('now', '-30 days') GROUP BY day ORDER BY day"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayPtr = sqlite3_column_text(stmt, 0) else { continue }
            result[String(cString: dayPtr)] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    private func countAllDecisions() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM decisions"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Default Policies

    private func installDefaultPolicies() {
        let defaults: [PolicyRule] = [
            PolicyRule(
                id: "file-deletion", name: "File Deletion Guard",
                enabled: true, riskLevel: .high,
                actionPattern: "*delete*file*", requireApproval: true,
                maxCostPerAction: 0, blockedAgents: [],
                description: "Require human approval before deleting files"
            ),
            PolicyRule(
                id: "shell-execution", name: "Shell Execution Monitor",
                enabled: true, riskLevel: .medium,
                actionPattern: "run_command*", requireApproval: false,
                maxCostPerAction: 0, blockedAgents: [],
                description: "Flag shell command executions for audit"
            ),
            PolicyRule(
                id: "high-cost-action", name: "High Cost Guard",
                enabled: true, riskLevel: .high,
                actionPattern: "*", requireApproval: false,
                maxCostPerAction: 1.0, blockedAgents: [],
                description: "Block any single action costing more than $1.00"
            ),
            PolicyRule(
                id: "code-execution", name: "Code Execution Guard",
                enabled: true, riskLevel: .critical,
                actionPattern: "execute_code*", requireApproval: true,
                maxCostPerAction: 0, blockedAgents: [],
                description: "Require approval for code execution in sandboxes"
            ),
            PolicyRule(
                id: "system-access", name: "System Access Monitor",
                enabled: true, riskLevel: .medium,
                actionPattern: "*system*", requireApproval: false,
                maxCostPerAction: 0, blockedAgents: [],
                description: "Monitor all system-level access for audit trail"
            ),
            PolicyRule(
                id: "web-request", name: "External Web Request Monitor",
                enabled: true, riskLevel: .low,
                actionPattern: "web_*", requireApproval: false,
                maxCostPerAction: 0.50, blockedAgents: [],
                description: "Track external web requests, block if cost exceeds $0.50"
            )
        ]

        for policy in defaults {
            insertPolicy(policy)
        }
        policies = defaults
        TorboLog.info("Installed \(defaults.count) default governance policies", subsystem: "Governance")
    }
}
