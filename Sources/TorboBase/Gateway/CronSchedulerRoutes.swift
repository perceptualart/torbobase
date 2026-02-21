// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Scheduler REST API
// Exposes CRUD + run-now endpoints for scheduled cron tasks.

import Foundation

// MARK: - Cron Scheduler API Routes

extension GatewayServer {

    /// Handle all /v1/cron/tasks routes. Returns nil if not a cron route.
    func handleCronSchedulerRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // GET /v1/cron/tasks — list all scheduled tasks
        if method == "GET" && path == "/v1/cron/tasks" {
            let tasks = await CronScheduler.shared.listTasks()
            let df = ISO8601DateFormatter()
            let items: [[String: Any]] = tasks.map { task in
                var dict: [String: Any] = [
                    "id": task.id,
                    "name": task.name,
                    "cron_expression": task.cronExpression,
                    "agent_id": task.agentID,
                    "prompt": task.prompt,
                    "enabled": task.enabled,
                    "run_count": task.runCount,
                    "created_at": df.string(from: task.createdAt),
                    "updated_at": df.string(from: task.updatedAt)
                ]
                if let lastRun = task.lastRun { dict["last_run"] = df.string(from: lastRun) }
                if let nextRun = task.nextRun { dict["next_run"] = df.string(from: nextRun) }
                if let result = task.lastResult { dict["last_result"] = result }
                if let error = task.lastError { dict["last_error"] = error }
                return dict
            }
            return HTTPResponse.json(["tasks": items, "count": items.count])
        }

        // GET /v1/cron/tasks/stats — scheduler statistics
        if method == "GET" && path == "/v1/cron/tasks/stats" {
            let stats = await CronScheduler.shared.stats()
            let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        // POST /v1/cron/tasks — create a new scheduled task
        if method == "POST" && path == "/v1/cron/tasks" {
            guard let body = req.jsonBody,
                  let name = body["name"] as? String,
                  let cronExpression = body["cron_expression"] as? String,
                  let prompt = body["prompt"] as? String else {
                return HTTPResponse.badRequest("Missing required fields: name, cron_expression, prompt")
            }

            let agentID = body["agent_id"] as? String ?? "sid"

            // Validate cron expression before creating
            guard CronExpression.parse(cronExpression) != nil else {
                return HTTPResponse.badRequest("Invalid cron expression: '\(HTTPResponse.jsonEscape(cronExpression))'. Use 5-field format: minute hour day month weekday")
            }

            guard let task = await CronScheduler.shared.createTask(
                name: name,
                cronExpression: cronExpression,
                agentID: agentID,
                prompt: prompt
            ) else {
                return HTTPResponse.badRequest("Failed to create scheduled task")
            }

            let df = ISO8601DateFormatter()
            var response: [String: Any] = [
                "id": task.id,
                "name": task.name,
                "cron_expression": task.cronExpression,
                "agent_id": task.agentID,
                "enabled": task.enabled,
                "created_at": df.string(from: task.createdAt)
            ]
            if let nextRun = task.nextRun {
                response["next_run"] = df.string(from: nextRun)
            }

            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data)
        }

        // Dynamic path routes: /v1/cron/tasks/{id}...
        guard path.hasPrefix("/v1/cron/tasks/") else { return nil }

        let pathParts = path.split(separator: "/").map(String.init)
        // Expected: ["v1", "cron", "tasks", "{id}"] or ["v1", "cron", "tasks", "{id}", "run"]
        guard pathParts.count >= 4 else { return nil }
        let taskID = pathParts[3]

        // POST /v1/cron/tasks/{id}/run — run task immediately
        if method == "POST" && pathParts.count == 5 && pathParts[4] == "run" {
            let result = await CronScheduler.shared.runNow(id: taskID)
            if result.success {
                return HTTPResponse.json(["status": "running", "message": result.message])
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                               body: Data("{\"error\":\"\(HTTPResponse.jsonEscape(result.message))\"}".utf8))
        }

        // GET /v1/cron/tasks/{id} — get single task
        if method == "GET" && pathParts.count == 4 {
            guard let task = await CronScheduler.shared.getTask(id: taskID) else {
                return HTTPResponse.notFound()
            }
            let df = ISO8601DateFormatter()
            var dict: [String: Any] = [
                "id": task.id,
                "name": task.name,
                "cron_expression": task.cronExpression,
                "agent_id": task.agentID,
                "prompt": task.prompt,
                "enabled": task.enabled,
                "run_count": task.runCount,
                "created_at": df.string(from: task.createdAt),
                "updated_at": df.string(from: task.updatedAt)
            ]
            if let lastRun = task.lastRun { dict["last_run"] = df.string(from: lastRun) }
            if let nextRun = task.nextRun { dict["next_run"] = df.string(from: nextRun) }
            if let result = task.lastResult { dict["last_result"] = result }
            if let error = task.lastError { dict["last_error"] = error }
            return HTTPResponse.json(dict)
        }

        // PUT /v1/cron/tasks/{id} — update task
        if method == "PUT" && pathParts.count == 4 {
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing request body")
            }

            let updated = await CronScheduler.shared.updateTask(
                id: taskID,
                name: body["name"] as? String,
                cronExpression: body["cron_expression"] as? String,
                agentID: body["agent_id"] as? String,
                prompt: body["prompt"] as? String,
                enabled: body["enabled"] as? Bool
            )

            guard let task = updated else {
                return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                                   body: Data("{\"error\":\"Task not found or invalid cron expression\"}".utf8))
            }

            let df = ISO8601DateFormatter()
            var dict: [String: Any] = [
                "id": task.id,
                "name": task.name,
                "cron_expression": task.cronExpression,
                "agent_id": task.agentID,
                "enabled": task.enabled,
                "updated_at": df.string(from: task.updatedAt)
            ]
            if let nextRun = task.nextRun { dict["next_run"] = df.string(from: nextRun) }
            return HTTPResponse.json(dict)
        }

        // DELETE /v1/cron/tasks/{id} — delete task
        if method == "DELETE" && pathParts.count == 4 {
            let success = await CronScheduler.shared.deleteTask(id: taskID)
            if success {
                return HTTPResponse.json(["status": "deleted", "id": taskID])
            }
            return HTTPResponse.notFound()
        }

        return nil
    }
}
