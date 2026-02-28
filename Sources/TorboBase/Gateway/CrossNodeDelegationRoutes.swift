// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cross-Node Delegation API Routes
// Authenticated endpoints for cross-node task delegation.
// Peer-to-peer endpoints (capabilities, submit, result) are handled
// directly in GatewayServer before the auth guard.
// Extension on GatewayServer, same pattern as SkillCommunityRoutes.swift.

import Foundation

// MARK: - Delegation API Routes (Authenticated)

extension GatewayServer {

    /// Handle authenticated /v1/delegation routes. Returns nil if not a recognized route.
    /// Note: Peer-to-peer endpoints (capabilities, submit, result) bypass auth and are
    /// handled directly in GatewayServer's route() method before the auth guard.
    func handleDelegationRoute(_ req: HTTPRequest, clientIP: String, currentLevel: AccessLevel) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // POST /v1/delegation/delegate — Local API to trigger cross-node delegation (requires writeFiles+)
        if method == "POST" && path == "/v1/delegation/delegate" {
            guard currentLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            guard let body = req.jsonBody,
                  let title = body["title"] as? String,
                  let description = body["description"] as? String else {
                return HTTPResponse.badRequest("Missing 'title' and 'description'")
            }

            let priority = body["priority"] as? Int ?? 1
            let requiredSkillIDs = body["required_skill_ids"] as? [String] ?? []
            let requiredAccessLevel = body["required_access_level"] as? Int ?? 2
            let context = body["context"] as? String

            do {
                let taskID = try await CrossNodeDelegation.shared.delegateTask(
                    title: title,
                    description: description,
                    priority: priority,
                    requiredSkillIDs: requiredSkillIDs,
                    requiredAccessLevel: requiredAccessLevel,
                    context: context
                )
                return HTTPResponse.json(["status": "delegated", "task_id": taskID])
            } catch {
                let errorMsg = (error as? DelegationError)?.errorDescription ?? error.localizedDescription
                let errBody: [String: Any] = ["status": "error", "error": errorMsg]
                let errData = (try? JSONSerialization.data(withJSONObject: errBody)) ?? Data()
                return HTTPResponse(statusCode: 422, headers: ["Content-Type": "application/json"], body: errData)
            }
        }

        // GET /v1/delegation/status — List outbound + inbound delegated tasks (requires readFiles+)
        if method == "GET" && path == "/v1/delegation/status" {
            guard currentLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            let outbound = await CrossNodeDelegation.shared.outboundStatus()
            let inbound = await CrossNodeDelegation.shared.inboundStatus()
            return HTTPResponse.json([
                "outbound": outbound,
                "inbound": inbound,
                "outbound_count": outbound.count,
                "inbound_count": inbound.count
            ] as [String: Any])
        }

        // GET /v1/delegation/peers — List peers with capabilities (requires readFiles+)
        if method == "GET" && path == "/v1/delegation/peers" {
            guard currentLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            let peers = await CrossNodeDelegation.shared.peersWithCapabilities()
            return HTTPResponse.json(["peers": peers, "count": peers.count] as [String: Any])
        }

        return nil // Not a delegation route
    }
}
