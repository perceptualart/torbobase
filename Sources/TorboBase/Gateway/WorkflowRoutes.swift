// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow API Routes
// REST API endpoints for the Visual Workflow Designer.
// Handles CRUD, execution, approval, templates, and history.
import Foundation

// MARK: - Workflow Route Handler

enum WorkflowDesignerRoutes {

    /// Handle a visual workflow API request. Returns nil if the path doesn't match.
    static func handle(method: String, path: String, body: Data?, queryParams: [String: String]) async -> HTTPRouteResult? {
        // Strip prefix
        let subpath: String
        if path.hasPrefix("/v1/visual-workflows") {
            subpath = String(path.dropFirst("/v1/visual-workflows".count))
        } else {
            return nil
        }

        switch (method, subpath) {

        // MARK: List Workflows
        case ("GET", ""), ("GET", "/"):
            let workflows = await VisualWorkflowStore.shared.list()
            let items: [[String: Any]] = workflows.map { wf in
                [
                    "id": wf.id,
                    "name": wf.name,
                    "description": wf.description,
                    "enabled": wf.enabled,
                    "node_count": wf.nodes.count,
                    "connection_count": wf.connections.count,
                    "run_count": wf.runCount,
                    "created_at": ISO8601DateFormatter().string(from: wf.createdAt),
                    "last_modified_at": ISO8601DateFormatter().string(from: wf.lastModifiedAt),
                    "last_run_at": wf.lastRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                ]
            }
            return .json(["workflows": items, "count": items.count])

        // MARK: Create Workflow
        case ("POST", ""), ("POST", "/"):
            guard let body = body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let name = json["name"] as? String else {
                return .error(400, "Missing 'name' in request body")
            }
            let description = json["description"] as? String ?? ""
            let wf = VisualWorkflow(name: name, description: description)
            await VisualWorkflowStore.shared.save(wf)
            TorboLog.info("Created visual workflow '\(name)' (\(wf.id.prefix(8)))", subsystem: "VWorkflow")
            return .json(["id": wf.id, "name": wf.name, "status": "created"])

        // MARK: Get Workflow
        case ("GET", _) where subpath.hasPrefix("/") && !subpath.contains("/", after: 1):
            let id = String(subpath.dropFirst())
            guard let wf = await VisualWorkflowStore.shared.get(id) else {
                return .error(404, "Workflow not found")
            }
            return .jsonData(encodeWorkflow(wf))

        // MARK: Update Workflow
        case ("PUT", _) where subpath.hasPrefix("/") && !subpath.contains("/", after: 1):
            let id = String(subpath.dropFirst())
            guard let body = body else { return .error(400, "Missing body") }
            guard var wf = await VisualWorkflowStore.shared.get(id) else {
                return .error(404, "Workflow not found")
            }

            // Decode the full workflow or partial update
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let updated = try? decoder.decode(VisualWorkflow.self, from: body) {
                // Full replacement (preserve ID and dates)
                var merged = updated
                merged = VisualWorkflow(id: id, name: updated.name, description: updated.description,
                                        enabled: updated.enabled, nodes: updated.nodes, connections: updated.connections)
                await VisualWorkflowStore.shared.save(merged)
                return .json(["id": id, "status": "updated"])
            }

            // Partial update via JSON fields
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let name = json["name"] as? String { wf.name = name }
                if let desc = json["description"] as? String { wf.description = desc }
                if let enabled = json["enabled"] as? Bool { wf.enabled = enabled }
                await VisualWorkflowStore.shared.save(wf)
                return .json(["id": id, "status": "updated"])
            }

            return .error(400, "Invalid body format")

        // MARK: Delete Workflow
        case ("DELETE", _) where subpath.hasPrefix("/") && !subpath.contains("/", after: 1):
            let id = String(subpath.dropFirst())
            await VisualWorkflowStore.shared.delete(id)
            TorboLog.info("Deleted visual workflow \(id.prefix(8))", subsystem: "VWorkflow")
            return .json(["status": "deleted"])

        // MARK: Execute Workflow
        case ("POST", _) where subpath.hasSuffix("/execute"):
            let id = extractID(from: subpath, suffix: "/execute")
            guard let wf = await VisualWorkflowStore.shared.get(id) else {
                return .error(404, "Workflow not found")
            }
            let errors = wf.validate()
            if !errors.isEmpty {
                let msgs = errors.map(\.message)
                return .error(400, "Validation failed: \(msgs.joined(separator: "; "))")
            }
            // Parse trigger data from body
            var triggerData: [String: String] = [:]
            if let body = body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                for (k, v) in json {
                    triggerData[k] = "\(v)"
                }
            }
            let execution = await WorkflowExecutor.shared.execute(
                workflow: wf, triggeredBy: "manual", triggerData: triggerData
            )
            return .json([
                "execution_id": execution.id,
                "workflow_id": wf.id,
                "status": execution.status.rawValue,
                "elapsed": execution.elapsed
            ])

        // MARK: Execution History
        case ("GET", _) where subpath.hasSuffix("/executions"):
            let id = extractID(from: subpath, suffix: "/executions")
            let limit = Int(queryParams["limit"] ?? "50") ?? 50
            let history = await WorkflowExecutor.shared.executionHistory(workflowID: id, limit: limit)
            let items: [[String: Any]] = history.map { exec in
                [
                    "id": exec.id,
                    "workflow_id": exec.workflowID,
                    "status": exec.status.rawValue,
                    "triggered_by": exec.triggeredBy,
                    "started_at": ISO8601DateFormatter().string(from: exec.startedAt),
                    "completed_at": exec.completedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "elapsed": exec.elapsed,
                    "error": exec.error ?? ""
                ]
            }
            return .json(["executions": items, "count": items.count])

        // MARK: Approve Execution
        case ("POST", _) where subpath.contains("/approve/"):
            let parts = subpath.split(separator: "/").map(String.init)
            // Expected: /{workflowID}/approve/{executionID}
            guard parts.count >= 3 else { return .error(400, "Invalid path") }
            let executionID = parts[parts.count - 1]
            // Find the pending node
            var nodeID: String?
            if let body = body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                nodeID = json["node_id"] as? String
            }
            // Try to find any pending approval for this execution
            let pending = await WorkflowExecutor.shared.pendingApprovalsList()
            let match = pending.first { $0.executionID == executionID }
            let resolveNodeID = nodeID ?? match?.nodeID ?? ""
            if resolveNodeID.isEmpty {
                return .error(404, "No pending approval found for this execution")
            }
            let approved = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])?["approved"] as? Bool ?? true
            let resolved = await WorkflowExecutor.shared.resolveApproval(
                executionID: executionID, nodeID: resolveNodeID, approved: approved
            )
            if resolved {
                return .json(["status": approved ? "approved" : "denied"])
            } else {
                return .error(404, "No pending approval found")
            }

        // MARK: List Templates
        case ("GET", "/templates"), ("GET", "/templates/"):
            let templates = WorkflowTemplateLibrary.allTemplates()
            let items: [[String: Any]] = templates.map { t in
                [
                    "name": t.name,
                    "description": t.description,
                    "node_count": t.nodes.count
                ]
            }
            return .json(["templates": items])

        // MARK: Create From Template
        case ("POST", _) where subpath.hasPrefix("/from-template/"):
            let templateName = String(subpath.dropFirst("/from-template/".count))
                .removingPercentEncoding ?? ""
            guard let template = WorkflowTemplateLibrary.template(named: templateName) else {
                return .error(404, "Template '\(templateName)' not found")
            }
            // Create new workflow from template with fresh IDs
            var wf = VisualWorkflow(
                name: template.name,
                description: template.description,
                nodes: template.nodes.map { n in
                    VisualNode(kind: n.kind, label: n.label,
                               positionX: n.positionX, positionY: n.positionY, config: n.config)
                },
                connections: []
            )
            // Rebuild connections with new node IDs
            var idMap: [String: String] = [:]
            for (idx, orig) in template.nodes.enumerated() {
                if idx < wf.nodes.count { idMap[orig.id] = wf.nodes[idx].id }
            }
            wf.connections = template.connections.compactMap { conn in
                guard let newFrom = idMap[conn.fromNodeID],
                      let newTo = idMap[conn.toNodeID] else { return nil }
                return NodeConnection(from: newFrom, to: newTo, label: conn.label)
            }
            await VisualWorkflowStore.shared.save(wf)
            TorboLog.info("Created workflow from template '\(templateName)' (\(wf.id.prefix(8)))", subsystem: "VWorkflow")
            return .json(["id": wf.id, "name": wf.name, "status": "created"])

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func extractID(from subpath: String, suffix: String) -> String {
        let stripped = subpath.replacingOccurrences(of: suffix, with: "")
        return stripped.hasPrefix("/") ? String(stripped.dropFirst()) : stripped
    }

    private static func encodeWorkflow(_ wf: VisualWorkflow) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(wf)) ?? Data()
    }
}

// MARK: - Route Result

enum HTTPRouteResult {
    case json([String: Any])
    case jsonData(Data)
    case error(Int, String)
    case html(String)

    var statusCode: Int {
        switch self {
        case .json, .jsonData, .html: return 200
        case .error(let code, _): return code
        }
    }

    func responseData() -> Data {
        switch self {
        case .json(let dict):
            return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        case .jsonData(let data):
            return data
        case .error(_, let msg):
            return (try? JSONSerialization.data(withJSONObject: ["error": msg])) ?? Data()
        case .html(let content):
            return content.data(using: .utf8) ?? Data()
        }
    }

    var contentType: String {
        switch self {
        case .html: return "text/html"
        default: return "application/json"
        }
    }
}

// MARK: - String Extension

private extension String {
    func contains(_ char: Character, after index: Int) -> Bool {
        let start = self.index(self.startIndex, offsetBy: min(index, self.count))
        return self[start...].contains(char)
    }
}
