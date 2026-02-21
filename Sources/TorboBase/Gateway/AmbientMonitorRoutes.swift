// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient Monitor REST API

import Foundation

extension GatewayServer {
    func handleAmbientRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path; let method = req.method
        if method == "GET" && path == "/ambient/alerts" { let a = await AmbientMonitor.shared.getAlerts(); return HTTPResponse.json(["alerts": a, "count": a.count]) }
        if method == "POST" && path == "/ambient/config" { guard let b = req.jsonBody else { return HTTPResponse.badRequest("Missing JSON body") }; await AmbientMonitor.shared.updateConfig(from: b); return HTTPResponse.json(["status": "updated", "config": await AmbientMonitor.shared.getConfig()]) }
        if method == "GET" && path == "/ambient/config" { return HTTPResponse.json(await AmbientMonitor.shared.getConfig()) }
        if method == "GET" && path == "/ambient/stats" { return HTTPResponse.json(await AmbientMonitor.shared.stats()) }
        if method == "POST" && path == "/ambient/start" { await AmbientMonitor.shared.start(); return HTTPResponse.json(["status": "started"]) }
        if method == "POST" && path == "/ambient/stop" { await AmbientMonitor.shared.stop(); return HTTPResponse.json(["status": "stopped"]) }
        if method == "DELETE" && path.hasPrefix("/ambient/alerts/") { let p = path.split(separator: "/").map(String.init); guard p.count == 3 else { return nil }; if await AmbientMonitor.shared.dismissAlert(id: p[2]) { return HTTPResponse.json(["status": "dismissed", "id": p[2]]) }; return HTTPResponse.notFound() }
        return nil
    }
}
