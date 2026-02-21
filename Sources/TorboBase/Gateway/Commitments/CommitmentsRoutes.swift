// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Commitments Routes
// REST API for managing user commitments.
// GET /v1/commitments — all open
// GET /v1/commitments/overdue — overdue only
// GET /v1/commitments/all — all (incl. resolved)
// GET /v1/commitments/stats — statistics
// POST /v1/commitments — manual add
// GET /v1/commitments/:id — single commitment
// PATCH /v1/commitments/:id — update status

import Foundation

enum CommitmentsRoutes {

    static func handle(method: String, path: String, body: [String: Any]?) async -> (Int, [String: Any])? {
        let subpath = String(path.dropFirst("/v1/commitments".count))

        // GET /v1/commitments — all open commitments
        if method == "GET" && (subpath.isEmpty || subpath == "/") {
            let open = await CommitmentsStore.shared.allOpen()
            return (200, [
                "commitments": open.map { $0.toDict() },
                "count": open.count
            ])
        }

        // GET /v1/commitments/overdue
        if method == "GET" && subpath == "/overdue" {
            let overdue = await CommitmentsStore.shared.overdue()
            return (200, [
                "commitments": overdue.map { $0.toDict() },
                "count": overdue.count
            ])
        }

        // GET /v1/commitments/all
        if method == "GET" && subpath == "/all" {
            let limit = 100  // Could parse from query params
            let all = await CommitmentsStore.shared.all(limit: limit)
            return (200, [
                "commitments": all.map { $0.toDict() },
                "count": all.count
            ])
        }

        // GET /v1/commitments/stats
        if method == "GET" && subpath == "/stats" {
            let stats = await CommitmentsStore.shared.stats()
            return (200, stats)
        }

        // POST /v1/commitments — manual add
        if method == "POST" && (subpath.isEmpty || subpath == "/") {
            guard let body, let text = body["text"] as? String, !text.isEmpty else {
                return (400, ["error": "Missing 'text' field"])
            }

            var dueDate: Date?
            if let dueDateStr = body["due_date"] as? String {
                let fmt = ISO8601DateFormatter()
                dueDate = fmt.date(from: dueDateStr)
                if dueDate == nil {
                    let dateFmt = DateFormatter()
                    dateFmt.dateFormat = "yyyy-MM-dd"
                    dueDate = dateFmt.date(from: dueDateStr)
                }
            }
            let dueText = body["due_text"] as? String

            if let id = await CommitmentsStore.shared.add(text: text, dueDate: dueDate, dueText: dueText) {
                return (201, ["id": id, "text": text, "status": "open"])
            }
            return (500, ["error": "Failed to add commitment"])
        }

        // Routes with :id
        if subpath.hasPrefix("/") {
            let idStr = String(subpath.dropFirst())
            // Ensure it's a number (not "overdue", "all", "stats")
            if let id = Int64(idStr) {

                // GET /v1/commitments/:id
                if method == "GET" {
                    if let commitment = await CommitmentsStore.shared.get(id: id) {
                        return (200, commitment.toDict())
                    }
                    return (404, ["error": "Commitment not found"])
                }

                // PATCH /v1/commitments/:id — update status
                if method == "PATCH" {
                    guard let body, let statusStr = body["status"] as? String,
                          let status = Commitment.Status(rawValue: statusStr) else {
                        return (400, ["error": "Missing or invalid 'status' field. Valid: open, resolved, dismissed, failed"])
                    }
                    let note = body["note"] as? String
                    await CommitmentsStore.shared.updateStatus(id: id, status: status, note: note)
                    return (200, ["id": id, "status": statusStr, "updated": true])
                }
            }
        }

        return nil
    }
}
