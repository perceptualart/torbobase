// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Scheduler REST API
// Full CRUD, execution history, validation, templates, and next-runs preview.

import Foundation

// MARK: - Cron Scheduler API Routes

extension GatewayServer {

    /// Handle all /v1/cron/* routes. Returns nil if not a cron route.
    func handleCronSchedulerRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method

        // — Top-level routes —

        // GET /v1/cron/tasks — list all scheduled tasks
        if method == "GET" && path == "/v1/cron/tasks" {
            let tasks = await CronScheduler.shared.listTasks()
            let items = tasks.map { cronTaskJSON($0) }
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
            let timezone = body["timezone"] as? String
            let catchUp = body["catch_up"] as? Bool

            // Validate cron expression (keywords + 5-field)
            let validation = CronParser.validate(cronExpression)
            guard validation.isValid else {
                return HTTPResponse.badRequest("Invalid cron expression: \(HTTPResponse.jsonEscape(validation.error ?? "unknown error"))")
            }

            guard let task = await CronScheduler.shared.createTask(
                name: name,
                cronExpression: cronExpression,
                agentID: agentID,
                prompt: prompt,
                timezone: timezone,
                catchUp: catchUp
            ) else {
                return HTTPResponse.badRequest("Failed to create scheduled task")
            }

            let data = (try? JSONSerialization.data(withJSONObject: cronTaskJSON(task))) ?? Data()
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data)
        }

        // POST /v1/cron/validate — validate a cron expression
        if method == "POST" && path == "/v1/cron/validate" {
            guard let body = req.jsonBody,
                  let expression = body["expression"] as? String else {
                return HTTPResponse.badRequest("Missing required field: expression")
            }

            let validation = CronParser.validate(expression)
            let df = ISO8601DateFormatter()
            var response: [String: Any] = [
                "valid": validation.isValid,
                "expression": validation.expression
            ]
            if let desc = validation.description { response["description"] = desc }
            if let err = validation.error { response["error"] = err }

            // Include next 5 runs if valid
            if validation.isValid {
                let nextRuns = CronParser.nextRuns(expression, count: 5)
                response["next_runs"] = nextRuns.map { df.string(from: $0) }
            }

            return HTTPResponse.json(response)
        }

        // GET /v1/cron/templates — list available templates
        if method == "GET" && path == "/v1/cron/templates" {
            let templates = CronTemplates.all.map { tpl -> [String: Any] in
                [
                    "id": tpl.id,
                    "name": tpl.name,
                    "cron_expression": tpl.cronExpression,
                    "description": tpl.description,
                    "category": tpl.category,
                    "schedule_description": tpl.scheduleDescription
                ]
            }
            return HTTPResponse.json(["templates": templates, "count": templates.count])
        }

        // POST /v1/cron/templates/{id}/create — create task from template
        if method == "POST" && path.hasPrefix("/v1/cron/templates/") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 5, parts[4] == "create" else { return nil }
            let templateID = parts[3]

            guard let template = CronTemplates.template(byID: templateID) else {
                return HTTPResponse.notFound()
            }

            let body = req.jsonBody
            let agentID = body?["agent_id"] as? String

            guard let task = await CronTaskIntegration.shared.createFromTemplate(template, agentID: agentID) else {
                return HTTPResponse.badRequest("Failed to create task from template")
            }

            let data = (try? JSONSerialization.data(withJSONObject: cronTaskJSON(task))) ?? Data()
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: data)
        }

        // — Dynamic path routes: /v1/cron/tasks/{id}... —
        guard path.hasPrefix("/v1/cron/tasks/") else { return nil }

        let pathParts = path.split(separator: "/").map(String.init)
        guard pathParts.count >= 4 else { return nil }
        let taskID = pathParts[3]

        // Skip known top-level paths that aren't task IDs
        if taskID == "stats" { return nil }

        // POST /v1/cron/tasks/{id}/run — run task immediately
        if method == "POST" && pathParts.count == 5 && pathParts[4] == "run" {
            let result = await CronScheduler.shared.runNow(id: taskID)
            if result.success {
                return HTTPResponse.json(["status": "running", "message": result.message])
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                               body: Data("{\"error\":\"\(HTTPResponse.jsonEscape(result.message))\"}".utf8))
        }

        // POST /v1/cron/tasks/{id}/trigger — alias for run
        if method == "POST" && pathParts.count == 5 && pathParts[4] == "trigger" {
            let result = await CronScheduler.shared.runNow(id: taskID)
            if result.success {
                return HTTPResponse.json(["status": "triggered", "message": result.message])
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                               body: Data("{\"error\":\"\(HTTPResponse.jsonEscape(result.message))\"}".utf8))
        }

        // GET /v1/cron/tasks/{id}/history — execution history
        if method == "GET" && pathParts.count == 5 && pathParts[4] == "history" {
            let limit = Int(req.queryParam("limit") ?? "") ?? 50
            let history = await CronScheduler.shared.getExecutionHistory(scheduleID: taskID, limit: limit)
            let df = ISO8601DateFormatter()
            let items: [[String: Any]] = history.map { exec in
                var dict: [String: Any] = [
                    "timestamp": df.string(from: exec.timestamp),
                    "success": exec.success,
                    "duration_seconds": Int(exec.duration)
                ]
                if let result = exec.result { dict["result"] = result }
                if let error = exec.error { dict["error"] = error }
                return dict
            }
            return HTTPResponse.json(["history": items, "count": items.count, "schedule_id": taskID])
        }

        // GET /v1/cron/tasks/{id}/next-runs — preview next execution times
        if method == "GET" && pathParts.count == 5 && pathParts[4] == "next-runs" {
            let count = Int(req.queryParam("count") ?? "") ?? 5
            let runs = await CronScheduler.shared.nextRuns(scheduleID: taskID, count: min(count, 20))
            let df = ISO8601DateFormatter()
            return HTTPResponse.json([
                "schedule_id": taskID,
                "next_runs": runs.map { df.string(from: $0) },
                "count": runs.count
            ])
        }

        // GET /v1/cron/tasks/{id} — get single task with full details
        if method == "GET" && pathParts.count == 4 {
            guard let task = await CronScheduler.shared.getTask(id: taskID) else {
                return HTTPResponse.notFound()
            }
            var dict = cronTaskJSON(task)

            // Include execution history summary
            let history = task.executionLog
            if !history.isEmpty {
                let successRate = Double(history.filter(\.success).count) / Double(history.count) * 100
                dict["execution_summary"] = [
                    "total_executions": history.count,
                    "success_rate": Int(successRate),
                    "last_execution": history.last.map { exec -> [String: Any] in
                        let df = ISO8601DateFormatter()
                        return [
                            "timestamp": df.string(from: exec.timestamp),
                            "success": exec.success,
                            "duration_seconds": Int(exec.duration)
                        ]
                    } as Any
                ]
            }

            // Include missed execution count
            let missed = await CronScheduler.shared.getMissedExecutions(scheduleID: taskID)
            if !missed.isEmpty {
                dict["missed_executions"] = missed.count
            }

            return HTTPResponse.json(dict)
        }

        // PUT /v1/cron/tasks/{id} — update task
        if method == "PUT" && pathParts.count == 4 {
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing request body")
            }

            // Validate cron expression if provided
            if let cron = body["cron_expression"] as? String {
                let validation = CronParser.validate(cron)
                if !validation.isValid {
                    return HTTPResponse.badRequest("Invalid cron expression: \(HTTPResponse.jsonEscape(validation.error ?? "unknown"))")
                }
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

            return HTTPResponse.json(cronTaskJSON(task))
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

    // MARK: - JSON Serialization Helper

    /// Serialize a CronTask to a JSON-compatible dictionary.
    private func cronTaskJSON(_ task: CronTask) -> [String: Any] {
        let df = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": task.id,
            "name": task.name,
            "cron_expression": task.cronExpression,
            "resolved_expression": task.resolvedExpression,
            "description": task.scheduleDescription,
            "agent_id": task.agentID,
            "prompt": task.prompt,
            "enabled": task.enabled,
            "run_count": task.runCount,
            "catch_up": task.effectiveCatchUp,
            "created_at": df.string(from: task.createdAt),
            "updated_at": df.string(from: task.updatedAt)
        ]
        if let lastRun = task.lastRun { dict["last_run"] = df.string(from: lastRun) }
        if let nextRun = task.nextRun { dict["next_run"] = df.string(from: nextRun) }
        if let result = task.lastResult { dict["last_result"] = result }
        if let error = task.lastError { dict["last_error"] = error }
        if let tz = task.timezone { dict["timezone"] = tz }
        return dict
    }
}
