// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent IAM API Routes
// REST API for managing agent identities, permissions, access logs, and anomaly detection.
// All routes are under /v1/iam/ and require appropriate access levels.

import Foundation

enum AgentIAMRoutes {

    /// Route all /v1/iam/* requests. Called from GatewayServer.processRequest().
    static func handleRequest(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // GET /v1/iam/dashboard — serve web dashboard
        if method == "GET" && path == "/v1/iam/dashboard" {
            let html = AgentIAMDashboardHTML.page()
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            )
        }

        // GET /v1/iam/stats — IAM statistics
        if method == "GET" && path == "/v1/iam/stats" {
            let stats = await AgentIAMEngine.shared.getStats()
            return jsonResponse(stats)
        }

        // GET /v1/iam/agents — list all agents
        if method == "GET" && path == "/v1/iam/agents" {
            let owner = req.queryParam("owner")
            let agents = await AgentIAMEngine.shared.listAgents(owner: owner)
            return jsonResponse(["agents": agents.map { $0.asDictionary }])
        }

        // GET /v1/iam/agents/{id} — get agent details
        if method == "GET" && path.hasPrefix("/v1/iam/agents/") && !path.hasSuffix("/permissions") {
            let id = extractAgentID(from: path)
            guard !id.isEmpty else { return errorResponse(400, "Missing agent ID") }

            if let agent = await AgentIAMEngine.shared.getAgent(id) {
                return jsonResponse(agent.asDictionary)
            }
            return errorResponse(404, "Agent not found")
        }

        // POST /v1/iam/agents/{id}/permissions — grant permission
        if method == "POST" && path.hasSuffix("/permissions") && path.hasPrefix("/v1/iam/agents/") {
            let id = extractAgentID(from: path, removingSuffix: "/permissions")
            guard !id.isEmpty else { return errorResponse(400, "Missing agent ID") }
            guard let body = req.jsonBody else { return errorResponse(400, "Invalid JSON body") }

            guard let resource = body["resource"] as? String, !resource.isEmpty else {
                return errorResponse(400, "Missing 'resource' field")
            }

            let actionsArray: [String]
            if let arr = body["actions"] as? [String] {
                actionsArray = arr
            } else if let str = body["actions"] as? String {
                actionsArray = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                return errorResponse(400, "Missing 'actions' field (array or comma-separated string)")
            }

            let grantedBy = body["grantedBy"] as? String ?? "api"

            await AgentIAMEngine.shared.grantPermission(
                agentID: id, resource: resource, actions: Set(actionsArray), grantedBy: grantedBy
            )

            return jsonResponse(["status": "granted", "agentID": id, "resource": resource, "actions": actionsArray])
        }

        // DELETE /v1/iam/agents/{id}/permissions — revoke permission(s)
        if method == "DELETE" && path.hasSuffix("/permissions") && path.hasPrefix("/v1/iam/agents/") {
            let id = extractAgentID(from: path, removingSuffix: "/permissions")
            guard !id.isEmpty else { return errorResponse(400, "Missing agent ID") }

            if let resource = req.queryParam("resource") {
                // Revoke specific resource permission
                await AgentIAMEngine.shared.revokePermission(agentID: id, resource: resource)
                return jsonResponse(["status": "revoked", "agentID": id, "resource": resource])
            } else {
                // Revoke ALL permissions
                await AgentIAMEngine.shared.revokeAllPermissions(agentID: id)
                return jsonResponse(["status": "all_revoked", "agentID": id])
            }
        }

        // GET /v1/iam/access-log — query access logs
        if method == "GET" && path == "/v1/iam/access-log" {
            let agentID = req.queryParam("agent")
            let resource = req.queryParam("resource")
            let limit = Int(req.queryParam("limit") ?? "100") ?? 100
            let offset = Int(req.queryParam("offset") ?? "0") ?? 0

            let logs = await AgentIAMEngine.shared.getAccessLog(
                agentID: agentID, resource: resource, limit: min(limit, 1000), offset: offset
            )

            return jsonResponse([
                "logs": logs.map { $0.asDictionary },
                "count": logs.count,
                "limit": min(limit, 1000),
                "offset": offset
            ] as [String: Any])
        }

        // GET /v1/iam/anomalies — detect anomalies
        if method == "GET" && path == "/v1/iam/anomalies" {
            let anomalies = await AgentIAMEngine.shared.detectAnomalies()
            return jsonResponse([
                "anomalies": anomalies.map { $0.asDictionary },
                "count": anomalies.count
            ] as [String: Any])
        }

        // GET /v1/iam/search?resource={pattern} — find agents with access
        if method == "GET" && path == "/v1/iam/search" {
            guard let resource = req.queryParam("resource"), !resource.isEmpty else {
                return errorResponse(400, "Missing 'resource' query parameter")
            }

            let agents = await AgentIAMEngine.shared.findAgentsWithAccess(resource: resource)
            return jsonResponse([
                "resource": resource,
                "agents": agents.map { $0.asDictionary },
                "count": agents.count
            ] as [String: Any])
        }

        // GET /v1/iam/risk-scores — all risk scores
        if method == "GET" && path == "/v1/iam/risk-scores" {
            let scores = await AgentIAMEngine.shared.getRiskScores()
            return jsonResponse(["scores": scores])
        }

        // POST /v1/iam/prune — prune old access logs
        if method == "POST" && path == "/v1/iam/prune" {
            let days = Int(req.queryParam("days") ?? "30") ?? 30
            await AgentIAMEngine.shared.pruneOldLogs(olderThanDays: days)
            return jsonResponse(["status": "pruned", "olderThanDays": days])
        }

        // POST /v1/iam/migrate — trigger migration
        if method == "POST" && path == "/v1/iam/migrate" {
            await AgentIAMEngine.shared.autoMigrateExistingAgents()
            return jsonResponse(["status": "migration_complete"])
        }

        return nil // Not an IAM route
    }

    // MARK: - Helpers

    /// Extract agent ID from path like "/v1/iam/agents/sid" or "/v1/iam/agents/sid/permissions"
    private static func extractAgentID(from path: String, removingSuffix suffix: String? = nil) -> String {
        var cleanPath = path
        if let suffix { cleanPath = cleanPath.replacingOccurrences(of: suffix, with: "") }
        let parts = cleanPath.components(separatedBy: "/")
        // Path: ["", "v1", "iam", "agents", "agent-id"]
        guard parts.count >= 5 else { return "" }
        return parts[4]
    }

    private static func jsonResponse(_ body: Any) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return errorResponse(500, "JSON serialization failed")
        }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    private static func errorResponse(_ code: Int, _ message: String) -> HTTPResponse {
        let body: [String: Any] = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{\"error\":\"\(message)\"}".utf8)
        return HTTPResponse(
            statusCode: code,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }
}
