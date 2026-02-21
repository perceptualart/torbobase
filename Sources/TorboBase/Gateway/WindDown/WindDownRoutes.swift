// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Wind-Down API Routes
// Configuration and control endpoints for the Evening Wind-Down system.

import Foundation

/// API routes for the Wind-Down system.
/// Called from GatewayServer's route handler.
enum WindDownRoutes {

    /// Handle all /v1/winddown/* routes.
    /// Returns (statusCode, responseBody) or nil if not a winddown route.
    static func handle(method: String, path: String, body: [String: Any]?) async -> (Int, [String: Any])? {
        switch (method, path) {

        // GET /v1/winddown/config — Get current wind-down configuration
        case ("GET", "/v1/winddown/config"):
            let config = await WindDownScheduler.shared.getConfig()
            return (200, config)

        // PUT /v1/winddown/config — Update wind-down configuration
        case ("PUT", "/v1/winddown/config"):
            guard let body else {
                return (400, ["error": "Request body required"])
            }
            await WindDownScheduler.shared.updateConfig(from: body)
            let config = await WindDownScheduler.shared.getConfig()
            return (200, ["status": "updated", "config": config])

        // POST /v1/winddown/run — Trigger wind-down immediately
        case ("POST", "/v1/winddown/run"):
            let result = await WindDownScheduler.shared.runNow()
            return (200, result)

        // GET /v1/winddown/stats — Wind-down scheduler stats
        case ("GET", "/v1/winddown/stats"):
            let stats = await WindDownScheduler.shared.stats()
            return (200, stats)

        // GET /v1/winddown/briefings — List recent briefings
        case ("GET", "/v1/winddown/briefings"):
            let briefings = await WindDownDelivery.shared.listBriefings()
            return (200, ["briefings": briefings, "count": briefings.count])

        // GET /v1/winddown/briefings/latest — Get most recent briefing
        case ("GET", "/v1/winddown/briefings/latest"):
            if let briefing = await WindDownDelivery.shared.latestBriefing() {
                return (200, briefing)
            }
            return (404, ["error": "No briefings yet"])

        default:
            // Check for date-specific briefing: GET /v1/winddown/briefings/2026-02-20
            if method == "GET" && path.hasPrefix("/v1/winddown/briefings/") {
                let date = String(path.dropFirst("/v1/winddown/briefings/".count))
                if !date.isEmpty && date != "latest" {
                    if let briefing = await WindDownDelivery.shared.briefing(for: date) {
                        return (200, briefing)
                    }
                    return (404, ["error": "No briefing for \(date)"])
                }
            }
            return nil
        }
    }
}
