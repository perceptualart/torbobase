// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — LifeOS REST API Routes
// GET /lifeos/meeting-prep/:date — get prep docs for meetings on date
// GET /lifeos/predicted-tasks — get suggested automations
// POST /lifeos/predicted-tasks/:id/accept — convert suggestion to cron job
// GET /lifeos/deadlines — get detected deadlines
// GET /lifeos/stats — LifeOS system stats

import Foundation

// MARK: - LifeOS API Routes

extension GatewayServer {

    /// Handle all /v1/lifeos/* routes. Returns nil if not a lifeos route.
    func handleLifeOSRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        guard path.hasPrefix("/v1/lifeos") else { return nil }

        let pathParts = path.split(separator: "/").map(String.init)
        // pathParts[0] = "v1", pathParts[1] = "lifeos", pathParts[2+] = sub-route

        // GET /v1/lifeos/stats — system overview
        if method == "GET" && path == "/v1/lifeos/stats" {
            let stats = await LifeOSPredictor.shared.stats()
            return HTTPResponse.json(stats)
        }

        // GET /v1/lifeos/meeting-prep — all briefings
        if method == "GET" && path == "/v1/lifeos/meeting-prep" {
            let briefings = await LifeOSPredictor.shared.getBriefings()
            let items = briefings.map { $0.toDict() }
            return HTTPResponse.json(["briefings": items, "count": items.count])
        }

        // GET /v1/lifeos/meeting-prep/:date — briefings for a specific date (YYYY-MM-DD)
        if method == "GET" && pathParts.count == 4 && pathParts[2] == "meeting-prep" {
            let dateStr = pathParts[3]
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"

            guard let targetDate = df.date(from: dateStr) else {
                return HTTPResponse.badRequest("Invalid date format. Use YYYY-MM-DD (e.g. 2026-02-20)")
            }

            let briefings = await LifeOSPredictor.shared.getBriefings(for: targetDate)
            let items = briefings.map { $0.toDict() }
            return HTTPResponse.json([
                "date": dateStr,
                "briefings": items,
                "count": items.count
            ])
        }

        // GET /v1/lifeos/predicted-tasks — all suggested automations
        if method == "GET" && path == "/v1/lifeos/predicted-tasks" {
            let predictions = await LifeOSPredictor.shared.getPredictions()
            let items = predictions.map { $0.toDict() }
            return HTTPResponse.json(["predictions": items, "count": items.count])
        }

        // POST /v1/lifeos/predicted-tasks/:id/accept — convert to cron job
        if method == "POST" && pathParts.count == 5 &&
           pathParts[2] == "predicted-tasks" && pathParts[4] == "accept" {
            let predictionID = pathParts[3]

            guard let cronTask = await LifeOSPredictor.shared.acceptPrediction(id: predictionID) else {
                return HTTPResponse(
                    statusCode: 404,
                    headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Prediction not found or already accepted\"}".utf8)
                )
            }

            let df = ISO8601DateFormatter()
            var response: [String: Any] = [
                "status": "accepted",
                "cron_task_id": cronTask.id,
                "cron_task_name": cronTask.name,
                "cron_expression": cronTask.cronExpression,
                "enabled": cronTask.enabled
            ]
            if let nextRun = cronTask.nextRun {
                response["next_run"] = df.string(from: nextRun)
            }

            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data)
        }

        // GET /v1/lifeos/deadlines — all detected deadlines
        if method == "GET" && path == "/v1/lifeos/deadlines" {
            let deadlines = await LifeOSPredictor.shared.getDeadlines()
            let items = deadlines.map { $0.toDict() }
            return HTTPResponse.json(["deadlines": items, "count": items.count])
        }

        return nil
    }
}
