// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Governance API Routes
// All routes under /v1/governance/* — decisions, stats, approvals, policies, audit export, anomalies.

import Foundation

enum GovernanceRoutes {

    /// Handle all /v1/governance/* requests.
    /// Returns (statusCode, responseBody) or nil for unknown routes.
    static func handle(method: String, path: String, body: [String: Any]?, queryParams: [String: String]) async -> (Int, Any)? {
        let engine = GovernanceEngine.shared
        await engine.initialize()

        // GET /v1/governance/decisions?limit=50&offset=0
        if method == "GET" && path == "/v1/governance/decisions" {
            let limit = Int(queryParams["limit"] ?? "50") ?? 50
            let offset = Int(queryParams["offset"] ?? "0") ?? 0
            let decisions = await engine.getDecisions(limit: min(limit, 500), offset: max(offset, 0))
            return (200, [
                "decisions": decisions.map { $0.toDict() },
                "count": decisions.count,
                "limit": limit,
                "offset": offset
            ] as [String: Any])
        }

        // GET /v1/governance/decisions/{id}
        if method == "GET" && path.hasPrefix("/v1/governance/decisions/") {
            let id = String(path.dropFirst("/v1/governance/decisions/".count))
            guard !id.isEmpty else {
                return (400, ["error": "Missing decision ID"])
            }

            // Return full trace (explainability)
            if let trace = await engine.explainDecision(id: id) {
                return (200, trace.toDict())
            }
            return (404, ["error": "Decision not found"])
        }

        // GET /v1/governance/stats
        if method == "GET" && path == "/v1/governance/stats" {
            let stats = await engine.getStats()
            return (200, stats.toDict())
        }

        // POST /v1/governance/approve/{id}
        if method == "POST" && path.hasPrefix("/v1/governance/approve/") {
            let id = String(path.dropFirst("/v1/governance/approve/".count))
            guard !id.isEmpty else {
                return (400, ["error": "Missing decision ID"])
            }
            let approvedBy = body?["approvedBy"] as? String ?? "admin"
            let success = await engine.approve(decisionID: id, approvedBy: approvedBy)
            if success {
                return (200, ["status": "approved", "decisionID": id])
            }
            return (404, ["error": "Approval request not found or already resolved"])
        }

        // POST /v1/governance/reject/{id}
        if method == "POST" && path.hasPrefix("/v1/governance/reject/") {
            let id = String(path.dropFirst("/v1/governance/reject/".count))
            guard !id.isEmpty else {
                return (400, ["error": "Missing decision ID"])
            }
            let rejectedBy = body?["rejectedBy"] as? String ?? "admin"
            let success = await engine.reject(decisionID: id, rejectedBy: rejectedBy)
            if success {
                return (200, ["status": "rejected", "decisionID": id])
            }
            return (404, ["error": "Approval request not found or already resolved"])
        }

        // GET /v1/governance/approvals
        if method == "GET" && path == "/v1/governance/approvals" {
            let approvals = await engine.listPendingApprovals()
            return (200, [
                "approvals": approvals.map { $0.toDict() },
                "count": approvals.count
            ] as [String: Any])
        }

        // GET /v1/governance/policies
        if method == "GET" && path == "/v1/governance/policies" {
            let policies = await engine.getPolicies()
            return (200, [
                "policies": policies.map { $0.toDict() },
                "count": policies.count
            ] as [String: Any])
        }

        // PUT /v1/governance/policies
        if method == "PUT" && path == "/v1/governance/policies" {
            guard let policiesArray = body?["policies"] as? [[String: Any]] else {
                return (400, ["error": "Body must contain 'policies' array"])
            }

            var parsed: [PolicyRule] = []
            for p in policiesArray {
                guard let id = p["id"] as? String,
                      let name = p["name"] as? String else { continue }

                let riskLevel = parseRiskLevel(p["riskLevel"] as? String ?? "low")

                parsed.append(PolicyRule(
                    id: id, name: name,
                    enabled: p["enabled"] as? Bool ?? true,
                    riskLevel: riskLevel,
                    actionPattern: p["actionPattern"] as? String ?? "*",
                    requireApproval: p["requireApproval"] as? Bool ?? false,
                    maxCostPerAction: p["maxCostPerAction"] as? Double ?? 0,
                    blockedAgents: p["blockedAgents"] as? [String] ?? [],
                    description: p["description"] as? String ?? ""
                ))
            }

            await engine.updatePolicies(parsed)
            return (200, ["status": "updated", "count": parsed.count])
        }

        // GET /v1/governance/audit/export?format=json|csv
        if method == "GET" && path == "/v1/governance/audit/export" {
            let format = queryParams["format"] ?? "json"
            let limit = Int(queryParams["limit"] ?? "10000") ?? 10000
            let data = await engine.exportAuditTrail(format: format, limit: limit)

            let contentType = format == "csv" ? "text/csv" : "application/json"
            let ext = format == "csv" ? "csv" : "json"
            let filename = "torbo-governance-export.\(ext)"
            return (200, [
                "__raw_data": true,
                "__content_type": contentType,
                "__disposition": "attachment; filename=\"\(filename)\"",
                "__bytes": [UInt8](data)
            ] as [String: Any])
        }

        // GET /v1/governance/anomalies
        if method == "GET" && path == "/v1/governance/anomalies" {
            let anomalies = await engine.getAnomalies()
            return (200, [
                "anomalies": anomalies.map { $0.toDict() },
                "count": anomalies.count
            ] as [String: Any])
        }

        // POST /v1/governance/anomalies — trigger anomaly detection scan
        if method == "POST" && path == "/v1/governance/anomalies" {
            let detected = await engine.detectAnomalies()
            return (200, [
                "detected": detected.map { $0.toDict() },
                "count": detected.count
            ] as [String: Any])
        }

        // POST /v1/governance/decisions — manually log a decision (for external integrations)
        if method == "POST" && path == "/v1/governance/decisions" {
            guard let action = body?["action"] as? String, !action.isEmpty else {
                return (400, ["error": "Body must contain 'action' string"])
            }

            let agentID = body?["agentID"] as? String ?? body?["agent"] as? String ?? "unknown"
            let reasoning = body?["reasoning"] as? String ?? ""
            let confidence = body?["confidence"] as? Double ?? 0.5
            let outcome = body?["outcome"] as? String ?? ""
            let cost = body?["cost"] as? Double ?? 0.0
            let riskLevel = parseRiskLevel(body?["riskLevel"] as? String ?? "low")
            let taskID = body?["taskID"] as? String
            let userID = body?["userID"] as? String
            let metadata = body?["metadata"] as? [String: String] ?? [:]

            let id = await engine.logDecision(
                agent: agentID, action: action, reasoning: reasoning,
                confidence: confidence, outcome: outcome, cost: cost,
                riskLevel: riskLevel, taskID: taskID, userID: userID,
                metadata: metadata
            )

            return (201, ["id": id, "status": "logged"])
        }

        // GET /v1/governance — Discovery endpoint
        if method == "GET" && path == "/v1/governance" {
            return (200, [
                "service": "Torbo Base Governance Engine",
                "endpoints": [
                    ["method": "GET",  "path": "/v1/governance/decisions",       "description": "List decisions (paginated). Params: limit, offset"],
                    ["method": "GET",  "path": "/v1/governance/decisions/{id}",  "description": "Get decision detail with full trace"],
                    ["method": "POST", "path": "/v1/governance/decisions",       "description": "Log a decision. Body: {action, agentID, reasoning?, confidence?, cost?, riskLevel?}"],
                    ["method": "GET",  "path": "/v1/governance/stats",           "description": "Aggregate governance statistics"],
                    ["method": "GET",  "path": "/v1/governance/approvals",       "description": "List pending approval requests"],
                    ["method": "POST", "path": "/v1/governance/approve/{id}",    "description": "Approve a pending decision"],
                    ["method": "POST", "path": "/v1/governance/reject/{id}",     "description": "Reject a pending decision"],
                    ["method": "GET",  "path": "/v1/governance/policies",        "description": "List governance policies"],
                    ["method": "PUT",  "path": "/v1/governance/policies",        "description": "Replace all policies. Body: {policies: [...]}"],
                    ["method": "GET",  "path": "/v1/governance/anomalies",       "description": "List detected anomalies"],
                    ["method": "POST", "path": "/v1/governance/anomalies",       "description": "Trigger anomaly detection scan"],
                    ["method": "GET",  "path": "/v1/governance/audit/export",    "description": "Export audit trail. Params: format (json|csv), limit"]
                ] as [[String: String]]
            ] as [String: Any])
        }

        return nil
    }

    // MARK: - Helpers

    private static func parseRiskLevel(_ str: String) -> RiskLevel {
        switch str.lowercased() {
        case "critical": return .critical
        case "high": return .high
        case "medium": return .medium
        default: return .low
        }
    }
}
