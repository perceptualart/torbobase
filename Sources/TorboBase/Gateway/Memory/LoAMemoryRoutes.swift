// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — LoA Memory Engine REST API
// Mounts at /memory — provides structured knowledge CRUD for all agents.

import Foundation

// MARK: - LoA Memory Engine API Routes

extension GatewayServer {

    /// Handle all /memory routes. Returns nil if not a recognized route.
    func handleLoAMemoryEngineRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // GET /memory/health — engine status and fact counts
        if method == "GET" && path == "/memory/health" {
            let health = await LoAMemoryEngine.shared.health()
            return HTTPResponse.json(health)
        }

        // POST /memory/fact — write a fact with category + key + value + confidence
        if method == "POST" && path == "/memory/fact" {
            guard let body = req.jsonBody,
                  let category = body["category"] as? String,
                  let key = body["key"] as? String,
                  let value = body["value"] as? String else {
                return HTTPResponse.badRequest("Missing required fields: category, key, value")
            }

            let confidence = body["confidence"] as? Double ?? 0.8
            let source = body["source"] as? String ?? "api"

            if let expiresStr = body["expires_at"] as? String,
               let expiresAt = ISO8601DateFormatter().date(from: expiresStr) {
                let id = await LoAMemoryEngine.shared.writeTimeSensitiveFact(
                    category: category, key: key, value: value,
                    confidence: confidence, source: source, expiresAt: expiresAt
                )
                if let id {
                    return HTTPResponse.json(["status": "ok", "id": id, "expires_at": expiresStr])
                }
                return HTTPResponse.serverError("Failed to write time-sensitive fact")
            }

            let id = await LoAMemoryEngine.shared.writeFact(
                category: category, key: key, value: value,
                confidence: confidence, source: source
            )
            if let id {
                return HTTPResponse.json(["status": "ok", "id": id])
            }
            return HTTPResponse.serverError("Failed to write fact")
        }

        // GET /memory/context?topic=X — fuzzy search across all tables
        if method == "GET" && path == "/memory/context" {
            guard let topic = req.queryParam("topic"), !topic.isEmpty else {
                return HTTPResponse.badRequest("Missing required query parameter: topic")
            }

            let results = await LoAMemoryEngine.shared.searchContext(topic: topic)
            return HTTPResponse.json([
                "topic": topic,
                "results": results,
                "count": results.count
            ])
        }

        // GET /memory/person/:name — full profile for a contact
        if method == "GET" && path.hasPrefix("/memory/person/") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3 else { return HTTPResponse.badRequest("Missing person name") }
            let name = parts[2...].joined(separator: "/")
                .removingPercentEncoding ?? parts[2...].joined(separator: "/")

            guard let person = await LoAMemoryEngine.shared.getPerson(name: name) else {
                return HTTPResponse.notFound()
            }
            return HTTPResponse.json(person)
        }

        // POST /memory/person — upsert a person record
        if method == "POST" && path == "/memory/person" {
            guard let body = req.jsonBody,
                  let name = body["name"] as? String, !name.isEmpty else {
                return HTTPResponse.badRequest("Missing required field: name")
            }

            let id = await LoAMemoryEngine.shared.upsertPerson(
                name: name,
                relationship: body["relationship"] as? String,
                lastContact: body["last_contact"] as? String,
                sentiment: body["sentiment"] as? String,
                notes: body["notes"] as? String
            )

            if let id {
                return HTTPResponse.json(["status": "ok", "id": id, "name": name])
            }
            return HTTPResponse.serverError("Failed to upsert person")
        }

        // GET /memory/open-loops — all unresolved open loops
        if method == "GET" && path == "/memory/open-loops" {
            let loops = await LoAMemoryEngine.shared.getOpenLoops()
            return HTTPResponse.json([
                "open_loops": loops,
                "count": loops.count
            ])
        }

        // POST /memory/open-loop — create/update an open loop
        if method == "POST" && path == "/memory/open-loop" {
            guard let body = req.jsonBody,
                  let topic = body["topic"] as? String, !topic.isEmpty else {
                return HTTPResponse.badRequest("Missing required field: topic")
            }
            let priority = body["priority"] as? Int ?? 0
            let id = await LoAMemoryEngine.shared.upsertOpenLoop(topic: topic, priority: priority)
            if let id {
                return HTTPResponse.json(["status": "ok", "id": id, "topic": topic])
            }
            return HTTPResponse.serverError("Failed to upsert open loop")
        }

        // POST /memory/open-loop/:id/resolve — resolve an open loop
        if method == "POST" && path.hasPrefix("/memory/open-loop/") && path.hasSuffix("/resolve") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, let loopID = Int64(parts[2]) else {
                return HTTPResponse.badRequest("Invalid loop ID")
            }
            let success = await LoAMemoryEngine.shared.resolveLoop(id: loopID)
            if success {
                return HTTPResponse.json(["status": "resolved", "id": loopID])
            }
            return HTTPResponse.notFound()
        }

        // POST /memory/signal — log a behavioral signal
        if method == "POST" && path == "/memory/signal" {
            guard let body = req.jsonBody,
                  let signalType = body["signal_type"] as? String,
                  let value = body["value"] as? String else {
                return HTTPResponse.badRequest("Missing required fields: signal_type, value")
            }

            let id = await LoAMemoryEngine.shared.logSignal(signalType: signalType, value: value)
            if let id {
                return HTTPResponse.json(["status": "ok", "id": id, "signal_type": signalType])
            }
            return HTTPResponse.serverError("Failed to log signal")
        }

        // GET /memory/patterns — all learned patterns sorted by confidence
        if method == "GET" && path == "/memory/patterns" {
            let patterns = await LoAMemoryEngine.shared.getPatterns()
            return HTTPResponse.json([
                "patterns": patterns,
                "count": patterns.count
            ])
        }

        // POST /memory/pattern — create/update a pattern
        if method == "POST" && path == "/memory/pattern" {
            guard let body = req.jsonBody,
                  let patternType = body["pattern_type"] as? String,
                  let description = body["description"] as? String else {
                return HTTPResponse.badRequest("Missing required fields: pattern_type, description")
            }
            let confidence = body["confidence"] as? Double ?? 0.5
            let id = await LoAMemoryEngine.shared.upsertPattern(
                patternType: patternType, description: description, confidence: confidence
            )
            if let id {
                return HTTPResponse.json(["status": "ok", "id": id])
            }
            return HTTPResponse.serverError("Failed to upsert pattern")
        }

        return nil
    }
}
