// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
import Foundation

// MARK: - TaskQueue API Routes

extension GatewayServer {

    func handleTaskQueueRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // POST /v1/tasks — create a task
        if method == "POST" && path == "/v1/tasks" {
            guard let body = req.jsonBody,
                  let title = body["title"] as? String,
                  let description = body["description"] as? String,
                  let assignedTo = body["assigned_to"] as? String else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Missing title, description, or assigned_to\"}".utf8))
            }
            let assignedBy = body["assigned_by"] as? String ?? "unknown"
            let priorityRaw = body["priority"] as? Int ?? 1
            let priority = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal

            let task = await TaskQueue.shared.createTask(
                title: title, description: description,
                assignedTo: assignedTo, assignedBy: assignedBy,
                priority: priority
            )
            let json: [String: Any] = [
                "id": task.id, "title": task.title,
                "assigned_to": task.assignedTo, "status": task.status.rawValue
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // GET /v1/tasks — list all tasks (optional ?agent=sid&status=pending)
        if method == "GET" && path == "/v1/tasks" {
            let agent = req.queryParam("agent")
            let statusFilter = req.queryParam("status")

            var result = await TaskQueue.shared.allTasks()
            if let a = agent { result = result.filter { $0.assignedTo == a } }
            if let s = statusFilter, let status = TaskQueue.TaskStatus(rawValue: s) {
                result = result.filter { $0.status == status }
            }

            let items: [[String: Any]] = result.map { t in
                [
                    "id": t.id, "title": t.title, "description": t.description,
                    "assigned_to": t.assignedTo, "assigned_by": t.assignedBy,
                    "status": t.status.rawValue, "priority": t.priority.rawValue,
                    "result": t.result ?? "", "error": t.error ?? ""
                ]
            }
            let json: [String: Any] = ["tasks": items, "count": items.count]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // POST /v1/tasks/claim — agent claims next pending task
        if method == "POST" && path == "/v1/tasks/claim" {
            guard let body = req.jsonBody,
                  let agentID = body["agent_id"] as? String ?? body["crew_id"] as? String else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Missing agent_id\"}".utf8))
            }
            if let task = await TaskQueue.shared.claimTask(agentID: agentID) {
                let json: [String: Any] = [
                    "id": task.id, "title": task.title, "description": task.description,
                    "status": task.status.rawValue
                ]
                let data = try? JSONSerialization.data(withJSONObject: json)
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
            }
            return HTTPResponse(statusCode: 204, headers: ["Content-Type": "application/json"], body: Data("{\"message\":\"No pending tasks for \(agentID)\"}".utf8))
        }

        // POST /v1/tasks/:id/complete — mark task done
        if method == "POST" && path.hasPrefix("/v1/tasks/") && path.hasSuffix("/complete") {
            let components = path.split(separator: "/")
            guard components.count == 4,
                  let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Invalid request\"}".utf8))
            }
            let taskID = String(components[2])
            let result = body["result"] as? String ?? "Done"
            await TaskQueue.shared.completeTask(id: taskID, result: result)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"completed\"}".utf8))
        }

        // POST /v1/tasks/:id/fail — mark task failed
        if method == "POST" && path.hasPrefix("/v1/tasks/") && path.hasSuffix("/fail") {
            let components = path.split(separator: "/")
            guard components.count == 4,
                  let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Invalid request\"}".utf8))
            }
            let taskID = String(components[2])
            let error = body["error"] as? String ?? "Unknown error"
            await TaskQueue.shared.failTask(id: taskID, error: error)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"failed\"}".utf8))
        }

        // GET /v1/tasks/summary — quick overview
        if method == "GET" && path == "/v1/tasks/summary" {
            let summary = await TaskQueue.shared.summary()
            let data = Data("{\"summary\":\"\(summary)\"}".utf8)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        // POST /v1/tasks/delegate — delegate task to agent
        if method == "POST" && path == "/v1/tasks/delegate" {
            guard let body = req.jsonBody,
                  let from = body["from"] as? String,
                  let to = body["to"] as? String,
                  let title = body["title"] as? String,
                  let description = body["description"] as? String else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Missing from, to, title, or description\"}".utf8))
            }
            let priorityRaw = body["priority"] as? Int ?? 1
            let priority = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal
            let task = await TaskQueue.shared.delegate(from: from, to: to, title: title, description: description, priority: priority)
            let json: [String: Any] = ["id": task.id, "title": task.title, "delegated_to": to]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        return nil  // Not a task queue route
    }
}
