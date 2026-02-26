// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent Teams API Routes
// HTTP route handlers for the Agent Teams system.
// These are called from GatewayServer's route switch.

import Foundation

// MARK: - Agent Teams Route Handlers

/// Extension on GatewayServer to handle Agent Teams routes.
/// Add these cases to the main route switch in GatewayServer.swift:
///
/// ```swift
/// // --- Agent Teams Routes ---
/// case ("GET", "/v1/teams"):
///     return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsList(req)
///     }
/// case ("POST", "/v1/teams"):
///     return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsCreate(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/execute") && req.method == "POST":
///     return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsExecute(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/executions") && req.method == "GET":
///     return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsExecutionHistory(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/context") && req.method == "GET":
///     return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsGetContext(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.path.hasSuffix("/context") && req.method == "PUT":
///     return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsUpdateContext(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.method == "GET":
///     return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsGet(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.method == "PUT":
///     return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsUpdate(req)
///     }
/// case _ where req.path.hasPrefix("/v1/teams/") && req.method == "DELETE":
///     return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
///         await self.handleTeamsDelete(req)
///     }
/// ```

extension GatewayServer {

    // MARK: - GET /v1/teams — List all teams

    func handleTeamsList(_ req: HTTPRequest) async -> HTTPResponse {
        let teams = await TeamCoordinator.shared.listTeams()
        let items: [[String: Any]] = teams.map { team in
            [
                "id": team.id,
                "name": team.name,
                "coordinator": team.coordinatorAgentID,
                "members": team.memberAgentIDs,
                "description": team.description,
                "member_count": team.memberAgentIDs.count + 1,
                "created_at": ISO8601DateFormatter().string(from: team.createdAt),
                "last_used_at": team.lastUsedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ]
        }
        return HTTPResponse.json(["teams": items, "count": items.count])
    }

    // MARK: - POST /v1/teams — Create team

    func handleTeamsCreate(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody else {
            return HTTPResponse.badRequest("Missing request body")
        }

        guard let name = body["name"] as? String, !name.isEmpty else {
            return HTTPResponse.badRequest("'name' is required")
        }

        let coordinator = body["coordinator"] as? String ?? "sid"
        let members = body["members"] as? [String] ?? []
        let description = body["description"] as? String ?? ""

        if members.isEmpty {
            return HTTPResponse.badRequest("'members' array must contain at least one agent ID")
        }

        let team = AgentTeam(
            name: name,
            coordinatorAgentID: coordinator,
            memberAgentIDs: members,
            description: description
        )

        let created = await TeamCoordinator.shared.createTeam(team)

        let result: [String: Any] = [
            "id": created.id,
            "name": created.name,
            "coordinator": created.coordinatorAgentID,
            "members": created.memberAgentIDs,
            "description": created.description
        ]

        let data = (try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)) ?? Data()
        return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data)
    }

    // MARK: - GET /v1/teams/{id} — Get team

    func handleTeamsGet(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path)
        guard let team = await TeamCoordinator.shared.team(teamID) else {
            return HTTPResponse.notFound()
        }

        let result: [String: Any] = [
            "id": team.id,
            "name": team.name,
            "coordinator": team.coordinatorAgentID,
            "members": team.memberAgentIDs,
            "description": team.description,
            "created_at": ISO8601DateFormatter().string(from: team.createdAt),
            "last_used_at": team.lastUsedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        ]
        return HTTPResponse.json(result)
    }

    // MARK: - PUT /v1/teams/{id} — Update team

    func handleTeamsUpdate(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path)
        guard var team = await TeamCoordinator.shared.team(teamID) else {
            return HTTPResponse.notFound()
        }

        guard let body = req.jsonBody else {
            return HTTPResponse.badRequest("Missing request body")
        }

        if let name = body["name"] as? String { team.name = name }
        if let coordinator = body["coordinator"] as? String { team.coordinatorAgentID = coordinator }
        if let members = body["members"] as? [String] { team.memberAgentIDs = members }
        if let description = body["description"] as? String { team.description = description }

        await TeamCoordinator.shared.updateTeam(team)

        return HTTPResponse.json([
            "id": team.id,
            "name": team.name,
            "coordinator": team.coordinatorAgentID,
            "members": team.memberAgentIDs,
            "status": "updated"
        ])
    }

    // MARK: - DELETE /v1/teams/{id} — Delete team

    func handleTeamsDelete(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path)
        let deleted = await TeamCoordinator.shared.deleteTeam(teamID)
        if deleted {
            return HTTPResponse.json(["status": "deleted", "id": teamID])
        }
        return HTTPResponse.notFound()
    }

    // MARK: - POST /v1/teams/{id}/execute — Execute team task

    func handleTeamsExecute(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path, suffix: "/execute")
        guard let body = req.jsonBody,
              let description = body["description"] as? String, !description.isEmpty else {
            return HTTPResponse.badRequest("'description' is required")
        }

        guard await TeamCoordinator.shared.team(teamID) != nil else {
            return HTTPResponse.notFound()
        }

        let result = await TeamCoordinator.shared.executeTeamTask(teamID: teamID, taskDescription: description)

        if let result {
            let subtaskResults: [[String: Any]] = result.subtaskResults.map { key, value in
                ["subtask_id": key, "result": value]
            }
            let response: [String: Any] = [
                "status": "completed",
                "team_id": teamID,
                "aggregated_result": result.aggregatedResult,
                "subtask_results": subtaskResults,
                "completed_at": ISO8601DateFormatter().string(from: result.completedAt)
            ]
            return HTTPResponse.json(response)
        }

        return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"],
                           body: Data("{\"error\":\"Team execution failed\"}".utf8))
    }

    // MARK: - GET /v1/teams/{id}/executions — Execution history

    func handleTeamsExecutionHistory(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path, suffix: "/executions")
        let limit = Int(req.queryParam("limit") ?? "50") ?? 50
        let history = await TeamCoordinator.shared.getExecutionHistory(teamID: teamID, limit: limit)

        let items: [[String: Any]] = history.map { exec in
            [
                "id": exec.id,
                "team_id": exec.teamID,
                "description": exec.taskDescription,
                "subtask_count": exec.subtaskCount,
                "status": exec.status.rawValue,
                "result": exec.result ?? "",
                "error": exec.error ?? "",
                "started_at": ISO8601DateFormatter().string(from: exec.startedAt),
                "completed_at": exec.completedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "duration_seconds": exec.durationSeconds ?? 0
            ]
        }
        return HTTPResponse.json(["executions": items, "count": items.count])
    }

    // MARK: - GET /v1/teams/{id}/context — Get shared context

    func handleTeamsGetContext(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path, suffix: "/context")
        let context = await TeamCoordinator.shared.getAllSharedContext(teamID: teamID)
        return HTTPResponse.json(["team_id": teamID, "context": context.entries])
    }

    // MARK: - PUT /v1/teams/{id}/context — Update shared context

    func handleTeamsUpdateContext(_ req: HTTPRequest) async -> HTTPResponse {
        let teamID = extractTeamID(from: req.path, suffix: "/context")
        guard let body = req.jsonBody else {
            return HTTPResponse.badRequest("Missing request body")
        }

        // Accept either {"key": "...", "value": "..."} or {"entries": {"k": "v", ...}}
        if let key = body["key"] as? String, let value = body["value"] as? String {
            await TeamCoordinator.shared.updateSharedContext(teamID: teamID, key: key, value: value)
            return HTTPResponse.json(["status": "updated", "key": key])
        }

        if let entries = body["entries"] as? [String: String] {
            for (key, value) in entries {
                await TeamCoordinator.shared.updateSharedContext(teamID: teamID, key: key, value: value)
            }
            return HTTPResponse.json(["status": "updated", "keys": Array(entries.keys)])
        }

        if body["clear"] as? Bool == true {
            await TeamCoordinator.shared.clearSharedContext(teamID: teamID)
            return HTTPResponse.json(["status": "cleared"])
        }

        return HTTPResponse.badRequest("Provide 'key'+'value', 'entries' dict, or 'clear':true")
    }

    // MARK: - Helpers

    /// Extract team ID from path like /v1/teams/{id} or /v1/teams/{id}/execute
    private func extractTeamID(from path: String, suffix: String = "") -> String {
        var cleaned = path
        if !suffix.isEmpty && cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        // Remove /v1/teams/ prefix
        let prefix = "/v1/teams/"
        if cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        return cleaned.removingPercentEncoding ?? cleaned
    }
}
