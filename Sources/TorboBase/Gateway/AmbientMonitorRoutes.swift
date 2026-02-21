// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient Monitor REST API

import Foundation

extension GatewayServer {
    func handleAmbientRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path; let method = req.method
        if method == "GET" && path == "/ambient/alerts" {
            let alerts = await AmbientMonitor.shared.getAlerts()
            return HTTPResponse.json(["alerts": alerts, "count": alerts.count])
        }
        if method == "POST" && path == "/ambient/config" {
            guard let body = req.jsonBody else { return HTTPResponse.badRequest("Missing JSON body") }
            await AmbientMonitor.shared.updateConfig(from: body)
            return HTTPResponse.json(["status": "updated", "config": await AmbientMonitor.shared.getConfig()])
        }
        if method == "GET" && path == "/ambient/config" { return HTTPResponse.json(await AmbientMonitor.shared.getConfig()) }
        if method == "GET" && path == "/ambient/stats" { return HTTPResponse.json(await AmbientMonitor.shared.stats()) }
        if method == "POST" && path == "/ambient/start" { await AmbientMonitor.shared.start(); return HTTPResponse.json(["status": "started"]) }
        if method == "POST" && path == "/ambient/stop" { await AmbientMonitor.shared.stop(); return HTTPResponse.json(["status": "stopped"]) }
        if method == "DELETE" && path.hasPrefix("/ambient/alerts/") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 3 else { return nil }
            if await AmbientMonitor.shared.dismissAlert(id: parts[2]) { return HTTPResponse.json(["status": "dismissed", "id": parts[2]]) }
            return HTTPResponse.notFound()
        }
        return nil
    }
}
