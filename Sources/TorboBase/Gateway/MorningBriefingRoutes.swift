// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Morning Briefing REST API

import Foundation

extension GatewayServer {

    func handleBriefingRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        if method == "POST" && path == "/lifeos/briefing-config" {
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing JSON body")
            }
            await MorningBriefing.shared.updateFromJSON(body)
            let config = await MorningBriefing.shared.getConfig()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            return HTTPResponse.json(["status": "updated"])
        }

        if method == "GET" && path == "/lifeos/briefing-config" {
            let config = await MorningBriefing.shared.getConfig()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            return HTTPResponse.json(["error": "Failed to serialize config"])
        }

        if method == "POST" && path == "/lifeos/briefing/run" {
            let briefing = await MorningBriefing.shared.executeBriefing()
            if let briefing {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(briefing) {
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
                }
                return HTTPResponse.json(["status": "delivered", "date": briefing.date])
            }
            return HTTPResponse.json(["status": "skipped", "reason": "Already delivered today"])
        }

        if method == "GET" && path == "/lifeos/briefing/stats" {
            let stats = await MorningBriefing.shared.stats()
            let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        if method == "GET" && path == "/lifeos/briefing/today" {
            let dateStr = briefingTodayDateString()
            if let briefing = await MorningBriefing.shared.getBriefing(date: dateStr) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(briefing) {
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
                }
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                               body: Data("{\"error\":\"No briefing for today yet\"}".utf8))
        }

        if method == "GET" && path == "/lifeos/briefing/history" {
            let limit = Int(req.queryParam("limit") ?? "30") ?? 30
            let dates = await MorningBriefing.shared.listBriefings(limit: limit)
            return HTTPResponse.json(["briefings": dates, "count": dates.count])
        }

        if method == "GET" && path.hasPrefix("/lifeos/briefing/") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 3 else { return nil }
            let dateStr = parts[2]
            guard dateStr.count == 10, dateStr.contains("-") else { return nil }
            if let briefing = await MorningBriefing.shared.getBriefing(date: dateStr) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(briefing) {
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
                }
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                               body: Data("{\"error\":\"No briefing found\"}".utf8))
        }

        return nil
    }

    private func briefingTodayDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}
