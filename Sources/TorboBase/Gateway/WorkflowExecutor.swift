// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow Executor
// Actor-based execution engine for graph-based visual workflows.
// Traverses nodes, handles decision branching, approval gates, parallel paths, and timeouts.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Workflow Executor

actor WorkflowExecutor {
    static let shared = WorkflowExecutor()

    /// Active executions keyed by execution ID
    private var executions: [String: WorkflowExecution] = [:]

    /// Pending approvals: executionID → continuation
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Execution history (persisted)
    private var history: [WorkflowExecution] = []
    private let historyPath: String

    /// Default timeout for approval gates (5 minutes)
    private let defaultApprovalTimeout: TimeInterval = 300

    /// Max execution time for any single workflow (30 minutes)
    private let maxExecutionTime: TimeInterval = 1800

    init() {
        historyPath = PlatformPaths.dataDir + "/workflow_executions.json"
        history = Self.loadHistory(path: historyPath)
    }

    private nonisolated static func loadHistory(path: String) -> [WorkflowExecution] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WorkflowExecution].self, from: data)) ?? []
    }

    // MARK: - Execute Workflow

    /// Execute a visual workflow from its trigger nodes to completion
    @discardableResult
    func execute(workflow: VisualWorkflow, triggeredBy: String = "manual",
                 triggerData: [String: String] = [:]) async -> WorkflowExecution {
        var execution = WorkflowExecution(
            workflowID: workflow.id,
            workflowName: workflow.name,
            triggeredBy: triggeredBy
        )
        execution.context = triggerData

        // Initialize all node states as pending
        for node in workflow.nodes {
            execution.nodeStates[node.id] = NodeExecutionState(status: .pending)
        }

        executions[execution.id] = execution
        TorboLog.info("Starting '\(workflow.name)' (exec: \(execution.id.prefix(8)))", subsystem: "VWorkflow")

        // Mark the workflow as run
        await VisualWorkflowStore.shared.markRun(workflow.id)

        // Find trigger nodes and start execution from each
        let triggerNodes = workflow.triggers
        if triggerNodes.isEmpty {
            execution.status = .failed
            execution.error = "No trigger nodes found"
            execution.completedAt = Date()
            finishExecution(execution)
            return execution
        }

        // Execute from each trigger (supports multiple triggers)
        await withTaskGroup(of: Void.self) { group in
            for trigger in triggerNodes {
                group.addTask { [self] in
                    await self.executeFromNode(trigger.id, workflow: workflow, executionID: execution.id)
                }
            }
        }

        // Finalize
        if var exec = executions[execution.id] {
            let hasFailure = exec.nodeStates.values.contains { $0.status == .failed }
            let hasWaiting = exec.nodeStates.values.contains { $0.status == .waitingApproval }

            if hasFailure {
                exec.status = .failed
                exec.error = exec.nodeStates.values.first(where: { $0.status == .failed })?.error
            } else if hasWaiting {
                exec.status = .waitingApproval
            } else {
                exec.status = .completed
            }
            exec.completedAt = Date()
            finishExecution(exec)

            let elapsed = String(format: "%.1f", exec.elapsed)
            TorboLog.info("'\(workflow.name)' \(exec.status.rawValue) in \(elapsed)s", subsystem: "VWorkflow")
            return exec
        }

        return execution
    }

    // MARK: - Node Execution

    private func executeFromNode(_ nodeID: String, workflow: VisualWorkflow, executionID: String) async {
        guard var execution = executions[executionID],
              let node = workflow.node(nodeID) else { return }

        // Check if already processed
        if let state = execution.nodeStates[nodeID], state.status != .pending { return }

        // Mark running
        execution.nodeStates[nodeID] = NodeExecutionState(status: .running, startedAt: Date())
        executions[executionID] = execution

        // Execute the node
        let result = await executeNode(node, workflow: workflow, execution: execution)

        // Update state
        guard var exec = executions[executionID] else { return }
        var state = exec.nodeStates[nodeID] ?? NodeExecutionState(status: .running)
        state.completedAt = Date()

        switch result {
        case .success(let output):
            state.status = .completed
            state.result = output
            if let output = output {
                exec.context[nodeID] = output
            }

        case .failure(let error):
            state.status = .failed
            state.error = error
            exec.nodeStates[nodeID] = state
            executions[executionID] = exec
            TorboLog.error("Node '\(node.label)' failed: \(error)", subsystem: "VWorkflow")
            return

        case .skipped:
            state.status = .skipped

        case .waitingApproval:
            state.status = .waitingApproval
            exec.nodeStates[nodeID] = state
            executions[executionID] = exec

            // Wait for approval
            let approved = await waitForApproval(executionID: executionID, nodeID: nodeID, timeout: node.config.double("timeout") ?? defaultApprovalTimeout)

            guard var execAfterApproval = executions[executionID] else { return }
            if approved {
                state.status = .completed
                state.result = "Approved"
                state.completedAt = Date()
            } else {
                state.status = .failed
                state.error = "Approval denied or timed out"
                state.completedAt = Date()
                execAfterApproval.nodeStates[nodeID] = state
                executions[executionID] = execAfterApproval
                return
            }
            exec = execAfterApproval
        }

        exec.nodeStates[nodeID] = state
        executions[executionID] = exec

        // Find downstream connections and execute them
        let downstream = workflow.downstream(of: nodeID)

        if node.kind == .decision {
            // Decision node — route based on condition result
            let conditionResult = state.result ?? "false"
            let isTrue = ["true", "yes", "1"].contains(conditionResult.lowercased().trimmingCharacters(in: .whitespaces))

            let trueConnections = downstream.filter { $0.label == "true" }
            let falseConnections = downstream.filter { $0.label == "false" || $0.label == nil }

            let activeConnections = isTrue ? trueConnections : falseConnections
            let skippedConnections = isTrue ? falseConnections : trueConnections

            // Mark skipped branch
            for conn in skippedConnections {
                if var skipExec = executions[executionID] {
                    skipExec.nodeStates[conn.toNodeID] = NodeExecutionState(status: .skipped)
                    executions[executionID] = skipExec
                }
            }

            // Execute active branch(es) — could be parallel
            await withTaskGroup(of: Void.self) { group in
                for conn in activeConnections {
                    group.addTask { [self] in
                        await self.executeFromNode(conn.toNodeID, workflow: workflow, executionID: executionID)
                    }
                }
            }
        } else {
            // Non-decision node — execute all downstream in parallel
            await withTaskGroup(of: Void.self) { group in
                for conn in downstream {
                    group.addTask { [self] in
                        await self.executeFromNode(conn.toNodeID, workflow: workflow, executionID: executionID)
                    }
                }
            }
        }
    }

    private func executeNode(_ node: VisualNode, workflow: VisualWorkflow,
                              execution: WorkflowExecution) async -> NodeResult {
        switch node.kind {
        case .trigger:
            return await executeTriggerNode(node, execution: execution)
        case .agent:
            return await executeAgentNode(node, execution: execution)
        case .decision:
            return await executeDecisionNode(node, execution: execution)
        case .action:
            return await executeActionNode(node, execution: execution)
        case .approval:
            return .waitingApproval
        }
    }

    // MARK: - Trigger Node

    private func executeTriggerNode(_ node: VisualNode, execution: WorkflowExecution) async -> NodeResult {
        // Triggers just pass through — the trigger data is already in execution.context
        let triggerKind = node.config.string("triggerKind") ?? "manual"
        return .success("Triggered by \(triggerKind)")
    }

    // MARK: - Agent Node

    private func executeAgentNode(_ node: VisualNode, execution: WorkflowExecution) async -> NodeResult {
        let agentID = node.config.string("agentID") ?? "sid"
        let promptOverride = node.config.string("prompt")

        // Gather context from upstream nodes
        let upstreamConnections = execution.context
        let contextSummary = upstreamConnections.map { "\($0.key): \($0.value)" }.joined(separator: "\n")

        let prompt: String
        if let override = promptOverride, !override.isEmpty {
            prompt = override.replacingOccurrences(of: "{{context}}", with: contextSummary)
                .replacingOccurrences(of: "{{result}}", with: contextSummary)
        } else {
            prompt = "Process this input:\n\(contextSummary)"
        }

        // Create a task for the agent via TaskQueue
        let task = await TaskQueue.shared.createTask(
            title: "Workflow: \(node.label)",
            description: prompt,
            assignedTo: agentID,
            assignedBy: "workflow-\(execution.workflowID.prefix(8))",
            priority: .normal
        )

        // Wait for task completion (poll)
        let deadline = Date().addingTimeInterval(maxExecutionTime)
        while Date() < deadline {
            if let taskState = await TaskQueue.shared.taskByID(task.id) {
                switch taskState.status {
                case .completed:
                    return .success(taskState.result ?? "Completed")
                case .failed:
                    return .failure(taskState.error ?? "Agent task failed")
                case .cancelled:
                    return .failure("Agent task was cancelled")
                case .pending, .inProgress:
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2s
                }
            } else {
                return .failure("Task not found")
            }
        }

        return .failure("Agent task timed out after \(Int(maxExecutionTime))s")
    }

    // MARK: - Decision Node

    private func executeDecisionNode(_ node: VisualNode, execution: WorkflowExecution) async -> NodeResult {
        let condition = node.config.string("condition") ?? "true"

        // Gather context for evaluation
        let contextValues = execution.context

        // Simple condition evaluation
        let result = evaluateCondition(condition, context: contextValues)
        return .success(result ? "true" : "false")
    }

    /// Evaluate a simple condition expression against the current context
    private func evaluateCondition(_ condition: String, context: [String: String]) -> Bool {
        let trimmed = condition.trimmingCharacters(in: .whitespaces).lowercased()

        // Literal booleans
        if trimmed == "true" || trimmed == "yes" { return true }
        if trimmed == "false" || trimmed == "no" { return false }

        // contains('text') — checks if any context value contains the text
        if let match = trimmed.range(of: #"contains\s*\(\s*['"](.*?)['"]\s*\)"#, options: .regularExpression) {
            let needle = String(trimmed[match]).replacingOccurrences(of: "contains", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "() '\""))
            return context.values.contains { $0.lowercased().contains(needle) }
        }

        // length > N — checks if combined context length exceeds N
        if let match = trimmed.range(of: #"length\s*>\s*(\d+)"#, options: .regularExpression) {
            let numStr = String(trimmed[match]).filter { $0.isNumber }
            if let threshold = Int(numStr) {
                let totalLen = context.values.map(\.count).reduce(0, +)
                return totalLen > threshold
            }
        }

        // equals('text') — checks if last context value equals text
        if let match = trimmed.range(of: #"equals\s*\(\s*['"](.*?)['"]\s*\)"#, options: .regularExpression) {
            let needle = String(trimmed[match]).replacingOccurrences(of: "equals", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "() '\""))
            return Array(context.values).last?.lowercased() == needle.lowercased()
        }

        // not_empty — checks if any context has non-empty values
        if trimmed == "not_empty" || trimmed == "has_data" {
            return context.values.contains { !$0.isEmpty }
        }

        // Default: treat non-empty context as true
        return !context.isEmpty
    }

    // MARK: - Action Node

    private func executeActionNode(_ node: VisualNode, execution: WorkflowExecution) async -> NodeResult {
        guard let actionKindStr = node.config.string("actionKind"),
              let actionKind = ActionKind(rawValue: actionKindStr) else {
            return .failure("No action type configured")
        }

        // Resolve template variables in config
        let context = execution.context
        let lastResult = Array(context.values).last ?? ""

        func resolve(_ template: String?) -> String {
            guard let t = template else { return "" }
            return t.replacingOccurrences(of: "{{result}}", with: lastResult)
                .replacingOccurrences(of: "{{context}}", with: context.values.joined(separator: "\n"))
        }

        switch actionKind {
        case .sendMessage:
            let platform = node.config.string("platform") ?? "telegram"
            let target = node.config.string("target") ?? ""
            let message = resolve(node.config.string("message"))
            if message.isEmpty { return .failure("Empty message") }
            // Use EventBus to route to the appropriate bridge
            await EventBus.shared.publish("workflow.action.sendMessage",
                payload: ["platform": platform, "target": target, "message": message],
                source: "WorkflowExecutor")
            return .success("Message sent to \(platform):\(target)")

        case .writeFile:
            let path = resolve(node.config.string("path"))
            let content = resolve(node.config.string("content"))
            if path.isEmpty { return .failure("No file path specified") }
            do {
                let expandedPath = NSString(string: path).expandingTildeInPath
                try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
                return .success("Wrote \(content.count) chars to \(path)")
            } catch {
                return .failure("Write failed: \(error.localizedDescription)")
            }

        case .runCommand:
            let command = resolve(node.config.string("command"))
            if command.isEmpty { return .failure("No command specified") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    return .success(String(output.prefix(2000)))
                } else {
                    return .failure("Command exited with \(process.terminationStatus): \(String(output.prefix(500)))")
                }
            } catch {
                return .failure("Command failed: \(error.localizedDescription)")
            }

        case .callWebhook:
            let urlStr = resolve(node.config.string("url"))
            let method = node.config.string("method") ?? "POST"
            let body = resolve(node.config.string("body"))
            guard let url = URL(string: urlStr) else { return .failure("Invalid webhook URL") }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            if !body.isEmpty { request.httpBody = body.data(using: .utf8) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                if (200...299).contains(statusCode) {
                    return .success(String(responseBody.prefix(2000)))
                } else {
                    return .failure("Webhook returned \(statusCode)")
                }
            } catch {
                return .failure("Webhook call failed: \(error.localizedDescription)")
            }

        case .sendEmail:
            let to = node.config.string("to") ?? ""
            let subject = resolve(node.config.string("subject"))
            let emailBody = resolve(node.config.string("body"))
            await EventBus.shared.publish("workflow.action.sendEmail",
                payload: ["to": to, "subject": subject, "body": emailBody],
                source: "WorkflowExecutor")
            return .success("Email queued to \(to)")

        case .broadcast:
            let channel = node.config.string("channel") ?? ""
            let message = resolve(node.config.string("message"))
            await EventBus.shared.publish("workflow.action.broadcast",
                payload: ["channel": channel, "message": message],
                source: "WorkflowExecutor")
            return .success("Broadcast sent to channel \(channel)")
        }
    }

    // MARK: - Approval Gate

    private func waitForApproval(executionID: String, nodeID: String, timeout: TimeInterval) async -> Bool {
        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let key = "\(executionID):\(nodeID)"
            pendingApprovals[key] = cont

            // Timeout task
            Task { [weak self = self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                guard let self = self else { return }
                await self.timeoutApproval(key: key)
            }
        }
        return approved
    }

    private func timeoutApproval(key: String) {
        if let cont = pendingApprovals.removeValue(forKey: key) {
            cont.resume(returning: false)
            TorboLog.warn("Approval timed out: \(key)", subsystem: "VWorkflow")
        }
    }

    /// Called externally (e.g. from API route) to approve or deny a pending execution
    func resolveApproval(executionID: String, nodeID: String, approved: Bool) -> Bool {
        let key = "\(executionID):\(nodeID)"
        guard let cont = pendingApprovals.removeValue(forKey: key) else { return false }
        cont.resume(returning: approved)
        TorboLog.info("Approval \(approved ? "granted" : "denied"): \(key)", subsystem: "VWorkflow")
        return true
    }

    /// List pending approvals
    func pendingApprovalsList() -> [(executionID: String, nodeID: String)] {
        pendingApprovals.keys.compactMap { key in
            let parts = key.split(separator: ":")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    // MARK: - Queries

    func getExecution(_ id: String) -> WorkflowExecution? {
        executions[id] ?? history.first { $0.id == id }
    }

    func activeExecutions() -> [WorkflowExecution] {
        Array(executions.values).sorted { $0.startedAt > $1.startedAt }
    }

    func executionHistory(workflowID: String? = nil, limit: Int = 50) -> [WorkflowExecution] {
        var results = history
        if let wfID = workflowID { results = results.filter { $0.workflowID == wfID } }
        return Array(results.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    // MARK: - Cancel

    func cancelExecution(_ executionID: String) {
        guard var exec = executions[executionID] else { return }
        exec.status = .cancelled
        exec.completedAt = Date()
        finishExecution(exec)
        TorboLog.info("Cancelled execution \(executionID.prefix(8))", subsystem: "VWorkflow")
    }

    // MARK: - Resume (from saved state)

    func resumeExecution(_ executionID: String) async -> WorkflowExecution? {
        guard let exec = history.first(where: { $0.id == executionID }),
              exec.status == .waitingApproval,
              let workflow = await VisualWorkflowStore.shared.get(exec.workflowID) else {
            return nil
        }

        // Re-execute from pending nodes
        var resumed = exec
        resumed.status = .running
        executions[executionID] = resumed

        // Find nodes that were waiting and continue from there
        let pendingNodeIDs = exec.nodeStates.filter { $0.value.status == .waitingApproval }.map(\.key)
        for nodeID in pendingNodeIDs {
            let downstream = workflow.downstream(of: nodeID)
            for conn in downstream {
                await executeFromNode(conn.toNodeID, workflow: workflow, executionID: executionID)
            }
        }

        if let final = executions[executionID] {
            var finished = final
            finished.status = .completed
            finished.completedAt = Date()
            finishExecution(finished)
            return finished
        }
        return nil
    }

    // MARK: - Persistence

    private func finishExecution(_ execution: WorkflowExecution) {
        executions.removeValue(forKey: execution.id)
        history.append(execution)
        // Cap history at 500 entries
        if history.count > 500 { history = Array(history.suffix(500)) }
        persistHistory()
    }

    private func persistHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: historyPath), options: .atomic)
        } catch {
            TorboLog.error("Failed to write workflow_executions.json: \(error)", subsystem: "VWorkflow")
        }
    }
}

// MARK: - Node Result

enum NodeResult {
    case success(String?)
    case failure(String)
    case skipped
    case waitingApproval
}
