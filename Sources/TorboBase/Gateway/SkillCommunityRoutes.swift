// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Community API Routes
// REST endpoints for the federated skill sharing network and wiki-LLM knowledge layer.
// Extension on GatewayServer, same pattern as LoAMemoryRoutes.swift.

import Foundation

// MARK: - Community API Routes

extension GatewayServer {

    /// Handle all /v1/community routes. Returns nil if not a recognized route.
    func handleSkillCommunityRoute(_ req: HTTPRequest, clientIP: String, currentLevel: AccessLevel) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // GET /v1/community/identity — This node's identity
        if method == "GET" && path == "/v1/community/identity" {
            if let identity = await SkillCommunityManager.shared.getIdentity() {
                let stats = await SkillCommunityManager.shared.communityStats()
                var result = identity.toDict()
                result["skill_count"] = stats["published_skills"] ?? 0
                result["knowledge_count"] = stats["knowledge_entries"] ?? 0
                return HTTPResponse.json(result)
            }
            return HTTPResponse.serverError("Node identity not initialized")
        }

        // GET /v1/community/stats — Network stats
        if method == "GET" && path == "/v1/community/stats" {
            let stats = await SkillCommunityManager.shared.communityStats()
            return HTTPResponse.json(stats)
        }

        // GET /v1/community/skills — Browse community skills
        if method == "GET" && path == "/v1/community/skills" {
            let result = await SkillCommunityManager.shared.browseSkills(
                query: req.queryParam("q"),
                tag: req.queryParam("tag"),
                page: Int(req.queryParam("page") ?? "1") ?? 1,
                limit: Int(req.queryParam("limit") ?? "20") ?? 20,
                sort: req.queryParam("sort") ?? "newest"
            )
            return HTTPResponse.json(result)
        }

        // GET /v1/community/skills/{id} — Skill detail + versions + knowledge
        if method == "GET" && path.hasPrefix("/v1/community/skills/") && !path.hasSuffix("/knowledge")
            && !path.hasSuffix("/install") && !path.hasSuffix("/rate") && !path.hasSuffix("/package") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4 else { return nil }
            let skillID = parts[3]

            if let detail = await SkillCommunityManager.shared.getSkillDetail(skillID: skillID) {
                return HTTPResponse.json(detail)
            }
            return HTTPResponse.notFound()
        }

        // POST /v1/community/skills/publish — Publish a local skill
        if method == "POST" && path == "/v1/community/skills/publish" {
            guard currentLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            guard let body = req.jsonBody,
                  let skillID = body["skill_id"] as? String else {
                return HTTPResponse.badRequest("Missing 'skill_id'")
            }
            let changelog = body["changelog"] as? String ?? "Initial release"
            if let published = await SkillCommunityManager.shared.publishSkill(skillID: skillID, changelog: changelog) {
                return HTTPResponse.json(published.toDict())
            }
            return HTTPResponse.serverError("Failed to publish skill")
        }

        // PUT /v1/community/skills/{id} — Update published skill (new version)
        if method == "PUT" && path.hasPrefix("/v1/community/skills/") {
            guard currentLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4 else { return nil }
            let skillID = parts[3]

            let changelog = req.jsonBody?["changelog"] as? String ?? "Version update"
            if let published = await SkillCommunityManager.shared.publishSkill(skillID: skillID, changelog: changelog) {
                return HTTPResponse.json(published.toDict())
            }
            return HTTPResponse.serverError("Failed to update skill")
        }

        // POST /v1/community/skills/{id}/install — Install from community
        if method == "POST" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/install") {
            guard currentLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                return HTTPResponse.unauthorized()
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let skillID = parts[3]

            let fromPeer = req.jsonBody?["from_peer"] as? String
            if let installedID = await SkillCommunityManager.shared.installCommunitySkill(skillID: skillID, fromPeer: fromPeer) {
                return HTTPResponse.json(["success": true, "skill_id": installedID] as [String: Any])
            }
            return HTTPResponse.serverError("Failed to install community skill")
        }

        // POST /v1/community/skills/{id}/rate — Rate a skill
        if method == "POST" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/rate") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let skillID = parts[3]

            guard let body = req.jsonBody,
                  let rating = body["rating"] as? Int else {
                return HTTPResponse.badRequest("Missing 'rating' (1-5)")
            }
            let review = body["review"] as? String
            await SkillCommunityManager.shared.rateSkill(skillID: skillID, rating: rating, review: review)
            return HTTPResponse.json(["success": true, "skill_id": skillID, "rating": max(1, min(5, rating))] as [String: Any])
        }

        // GET /v1/community/skills/{id}/knowledge — Browse knowledge entries
        if method == "GET" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/knowledge") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let skillID = parts[3]

            let page = Int(req.queryParam("page") ?? "1") ?? 1
            let limit = Int(req.queryParam("limit") ?? "50") ?? 50
            let entries = await SkillCommunityManager.shared.getKnowledge(forSkill: skillID, page: page, limit: limit)
            return HTTPResponse.json(["skill_id": skillID, "entries": entries, "page": page] as [String: Any])
        }

        // POST /v1/community/skills/{id}/knowledge — Contribute knowledge
        if method == "POST" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/knowledge") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let skillID = parts[3]

            guard let body = req.jsonBody,
                  let text = body["text"] as? String, !text.isEmpty else {
                return HTTPResponse.badRequest("Missing 'text'")
            }
            let categoryStr = body["category"] as? String ?? "tip"
            let category = KnowledgeCategory(rawValue: categoryStr) ?? .tip
            let confidence = body["confidence"] as? Double ?? 0.8

            let success = await SkillCommunityManager.shared.contributeKnowledge(
                skillID: skillID, text: text, category: category, confidence: confidence
            )
            return HTTPResponse.json(["success": success, "skill_id": skillID] as [String: Any])
        }

        // POST /v1/community/knowledge/{id}/vote — Upvote/downvote
        if method == "POST" && path.hasPrefix("/v1/community/knowledge/") && path.hasSuffix("/vote") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let knowledgeID = parts[3]

            let upvote = req.jsonBody?["upvote"] as? Bool ?? true
            await SkillCommunityManager.shared.voteKnowledge(id: knowledgeID, upvote: upvote)
            return HTTPResponse.json(["success": true, "id": knowledgeID, "upvote": upvote] as [String: Any])
        }

        // GET /v1/community/prefs — All sharing preferences
        if method == "GET" && path == "/v1/community/prefs" {
            let prefs = await SkillCommunityManager.shared.allPrefs()
            return HTTPResponse.json(["prefs": prefs.map { $0.toDict() }])
        }

        // PUT /v1/community/prefs/{skillID} — Set sharing prefs
        if method == "PUT" && path.hasPrefix("/v1/community/prefs/") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4 else { return nil }
            let skillID = parts[3]

            let body = req.jsonBody ?? [:]
            var prefs = await SkillCommunityManager.shared.getPrefs(forSkill: skillID)
            if let share = body["share_knowledge"] as? Bool {
                prefs = SkillSharingPrefs(skillID: skillID, shareKnowledge: share, receiveKnowledge: prefs.receiveKnowledge)
            }
            if let receive = body["receive_knowledge"] as? Bool {
                prefs = SkillSharingPrefs(skillID: skillID, shareKnowledge: prefs.shareKnowledge, receiveKnowledge: receive)
            }
            await SkillCommunityManager.shared.setPrefs(prefs)
            return HTTPResponse.json(prefs.toDict())
        }

        // GET /v1/community/peers — List peers
        if method == "GET" && path == "/v1/community/peers" {
            let peers = await SkillCommunityManager.shared.allPeers()
            return HTTPResponse.json(["peers": peers.map { $0.toDict() }])
        }

        // POST /v1/community/announce — Receive peer announcement
        if method == "POST" && path == "/v1/community/announce" {
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing announcement body")
            }
            // Inject the observed IP from the request
            var data = body
            if data["host"] as? String == "127.0.0.1" {
                data["host"] = clientIP
            }
            await SkillCommunityManager.shared.handlePeerAnnouncement(data)
            return HTTPResponse.json(["success": true])
        }

        // POST /v1/community/sync — Trigger manual sync
        if method == "POST" && path == "/v1/community/sync" {
            await SkillCommunityManager.shared.syncKnowledge()
            return HTTPResponse.json(["success": true, "message": "Sync completed"])
        }

        // GET /v1/community/skills/{id}/package — Serve .tbskill to peers
        if method == "GET" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/package") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5 else { return nil }
            let skillID = parts[3]

            if let packageURL = await SkillCommunityManager.shared.packageURL(forSkill: skillID),
               let data = try? Data(contentsOf: packageURL) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/zip",
                        "Content-Disposition": "attachment; filename=\"\(skillID).tbskill\""
                    ],
                    body: data
                )
            }
            return HTTPResponse.notFound()
        }

        // POST /v1/community/skills/{id}/knowledge/export — Export knowledge for P2P
        if method == "GET" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/knowledge/export") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 6 else { return nil }
            let skillID = parts[3]

            let entries = await SkillCommunityManager.shared.getKnowledge(forSkill: skillID, page: 1, limit: 500)
            return HTTPResponse.json(["skill_id": skillID, "entries": entries])
        }

        // POST /v1/community/skills/{id}/knowledge/import — P2P knowledge import
        if method == "POST" && path.hasPrefix("/v1/community/skills/") && path.hasSuffix("/knowledge/import") {
            guard let body = req.jsonBody,
                  let entries = body["entries"] as? [[String: Any]] else {
                return HTTPResponse.badRequest("Missing 'entries' array")
            }
            let imported = await SkillCommunityManager.shared.importKnowledgeFromPeer(entries: entries)
            return HTTPResponse.json(["imported": imported])
        }

        // POST /v1/community/skills/bulk/knowledge/import — Bulk P2P knowledge import
        if method == "POST" && path == "/v1/community/skills/bulk/knowledge/import" {
            guard let body = req.jsonBody,
                  let entries = body["entries"] as? [[String: Any]] else {
                return HTTPResponse.badRequest("Missing 'entries' array")
            }
            let imported = await SkillCommunityManager.shared.importKnowledgeFromPeer(entries: entries)
            return HTTPResponse.json(["imported": imported])
        }

        return nil // Not a recognized community route
    }
}
