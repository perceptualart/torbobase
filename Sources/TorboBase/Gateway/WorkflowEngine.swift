// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Workflow Engine
// WorkflowEngine.swift — Decomposes natural language into multi-step agent pipelines
// Builds on TaskQueue + ProactiveAgent for execution

import Foundation

// MARK: - Workflow Definition

struct Workflow: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let createdBy: String           // Who initiated the workflow
    var status: WorkflowStatus
    let steps: [WorkflowStep]
    var taskIDs: [String]           // Task IDs created for each step
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: String?             // Final result summary
    var error: String?

    enum WorkflowStatus: String, Codable {
        case pending        // Created but not started
        case running        // Steps are executing
        case completed      // All steps finished successfully
        case failed         // One or more steps failed
        case cancelled      // Manually cancelled
        case paused         // Paused mid-execution
    }
}

struct WorkflowStep: Codable {
    let index: Int                  // Step order (0-based)
    let title: String               // Step title
    let description: String         // What this step should accomplish
    let assignedTo: String          // Agent ID
    let dependsOnSteps: [Int]       // Step indices this depends on (usually [index-1])
}

// MARK: - Workflow Engine

actor WorkflowEngine {
    static let shared = WorkflowEngine()

    private var workflows: [String: Workflow] = [:]
    private let storePath = NSHomeDirectory() + "/Library/Application Support/TorboBase/workflows.json"

    /// Default agent for workflow steps when none specified
    private let defaultAgentID = "sid"

    init() {}

    // MARK: - Create Workflow

    /// Create a workflow from a natural language description
    /// Uses a lightweight LLM call to decompose the intent into steps
    /// If agentID is provided, all steps are assigned to that agent; otherwise defaults to SiD
    func createWorkflow(description: String, createdBy: String = "user", priority: TaskQueue.TaskPriority = .normal, agentID: String? = nil) async -> Workflow {
        let assignee = agentID ?? defaultAgentID
        let steps = await decomposeIntoSteps(description, agentID: assignee)

        let workflowID = UUID().uuidString
        var workflow = Workflow(
            id: workflowID,
            name: generateWorkflowName(description),
            description: description,
            createdBy: createdBy,
            status: .pending,
            steps: steps,
            taskIDs: [],
            createdAt: Date()
        )

        // Create tasks for each step
        var taskIDs: [String] = []
        var stepToTaskID: [Int: String] = [:]

        for step in steps {
            // Map step dependencies to task IDs
            let depTaskIDs = step.dependsOnSteps.compactMap { stepToTaskID[$0] }

            let task = await TaskQueue.shared.createWorkflowTask(
                title: step.title,
                description: step.description,
                assignedTo: step.assignedTo,
                assignedBy: createdBy,
                priority: priority,
                workflowID: workflowID,
                dependsOn: depTaskIDs,
                stepIndex: step.index
            )

            taskIDs.append(task.id)
            stepToTaskID[step.index] = task.id
        }

        workflow.taskIDs = taskIDs
        workflow.status = .running
        workflow.startedAt = Date()
        workflows[workflowID] = workflow
        saveWorkflows()

        TorboLog.info("Created '\(workflow.name)' with \(steps.count) step(s) — ID: \(workflowID.prefix(8))", subsystem: "Workflow")
        for step in steps {
            TorboLog.info("  Step \(step.index + 1): \(step.title) → \(step.assignedTo)", subsystem: "Workflow")
        }

        return workflow
    }

    /// Create a workflow from pre-defined steps (no LLM decomposition needed)
    func createWorkflowFromSteps(_ steps: [WorkflowStep], name: String, description: String,
                                  createdBy: String = "user", priority: TaskQueue.TaskPriority = .normal) async -> Workflow {
        let workflowID = UUID().uuidString
        var workflow = Workflow(
            id: workflowID,
            name: name,
            description: description,
            createdBy: createdBy,
            status: .pending,
            steps: steps,
            taskIDs: [],
            createdAt: Date()
        )

        var taskIDs: [String] = []
        var stepToTaskID: [Int: String] = [:]

        for step in steps {
            let depTaskIDs = step.dependsOnSteps.compactMap { stepToTaskID[$0] }

            let task = await TaskQueue.shared.createWorkflowTask(
                title: step.title,
                description: step.description,
                assignedTo: step.assignedTo,
                assignedBy: createdBy,
                priority: priority,
                workflowID: workflowID,
                dependsOn: depTaskIDs,
                stepIndex: step.index
            )

            taskIDs.append(task.id)
            stepToTaskID[step.index] = task.id
        }

        workflow.taskIDs = taskIDs
        workflow.status = .running
        workflow.startedAt = Date()
        workflows[workflowID] = workflow
        saveWorkflows()

        TorboLog.info("Created '\(workflow.name)' with \(steps.count) step(s) — ID: \(workflowID.prefix(8))", subsystem: "Workflow")
        return workflow
    }

    // MARK: - Task Lifecycle Callbacks

    /// Called when a task in a workflow completes
    func onTaskCompleted(taskID: String, workflowID: String) async {
        guard var workflow = workflows[workflowID] else { return }

        let progress = await TaskQueue.shared.workflowProgress(workflowID)
        TorboLog.info("'\(workflow.name)' progress: \(progress.completed)/\(progress.total) complete" +
              (progress.active > 0 ? ", \(progress.active) active" : ""), subsystem: "Workflow")

        // Check if all tasks are done
        if progress.completed == progress.total {
            workflow.status = .completed
            workflow.completedAt = Date()

            // Collect final result from last step
            let lastTaskID = workflow.taskIDs.last ?? ""
            let lastTask = await TaskQueue.shared.taskByID(lastTaskID)
            workflow.result = lastTask?.result ?? "Workflow completed"

            workflows[workflowID] = workflow
            saveWorkflows()

            let elapsed = workflow.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            TorboLog.info("'\(workflow.name)' completed in \(elapsed)s", subsystem: "Workflow")
        }
    }

    /// Called when a task in a workflow fails
    func onTaskFailed(taskID: String, workflowID: String) async {
        guard var workflow = workflows[workflowID] else { return }

        let progress = await TaskQueue.shared.workflowProgress(workflowID)
        TorboLog.error("'\(workflow.name)' — step failed. \(progress.failed) failed, \(progress.completed) completed of \(progress.total)", subsystem: "Workflow")

        // If any step fails, mark workflow as failed (downstream deps will auto-cancel)
        if progress.failed > 0 && progress.active == 0 {
            workflow.status = .failed
            workflow.completedAt = Date()

            let failedTask = await TaskQueue.shared.taskByID(taskID)
            workflow.error = "Step '\(failedTask?.title ?? "?")' failed: \(failedTask?.error ?? "Unknown")"

            workflows[workflowID] = workflow
            saveWorkflows()
            TorboLog.error("'\(workflow.name)' failed", subsystem: "Workflow")
        }
    }

    // MARK: - Queries

    func getWorkflow(_ id: String) -> Workflow? { workflows[id] }

    func listWorkflows(status: Workflow.WorkflowStatus? = nil) -> [Workflow] {
        var result = Array(workflows.values).sorted { $0.createdAt > $1.createdAt }
        if let s = status { result = result.filter { $0.status == s } }
        return result
    }

    func activeWorkflows() -> [Workflow] {
        workflows.values.filter { $0.status == .running }.sorted { $0.createdAt > $1.createdAt }
    }

    func workflowStatus(_ id: String) async -> [String: Any]? {
        guard let workflow = workflows[id] else { return nil }
        let progress = await TaskQueue.shared.workflowProgress(id)
        let tasks = await TaskQueue.shared.tasksForWorkflow(id)

        let stepDetails: [[String: Any]] = tasks.map { task in
            [
                "step": (task.stepIndex ?? 0) + 1,
                "title": task.title,
                "assigned_to": task.assignedTo,
                "status": task.status.rawValue,
                "result_preview": String((task.result ?? "").prefix(200)),
                "error": task.error ?? ""
            ]
        }

        return [
            "id": workflow.id,
            "name": workflow.name,
            "description": workflow.description,
            "status": workflow.status.rawValue,
            "created_by": workflow.createdBy,
            "progress": [
                "total": progress.total,
                "completed": progress.completed,
                "failed": progress.failed,
                "active": progress.active
            ],
            "steps": stepDetails,
            "result": workflow.result ?? "",
            "error": workflow.error ?? "",
            "elapsed_seconds": workflow.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        ]
    }

    // MARK: - Cancel

    func cancelWorkflow(_ id: String) async {
        guard var workflow = workflows[id], workflow.status == .running else { return }

        for taskID in workflow.taskIDs {
            let task = await TaskQueue.shared.taskByID(taskID)
            if task?.status == .pending || task?.status == .inProgress {
                await TaskQueue.shared.cancelTask(id: taskID)
            }
        }

        workflow.status = .cancelled
        workflow.completedAt = Date()
        workflows[id] = workflow
        saveWorkflows()
        TorboLog.info("Cancelled '\(workflow.name)'", subsystem: "Workflow")
    }

    // MARK: - Step Decomposition

    /// Decompose a natural language description into workflow steps
    /// Uses pattern matching + heuristics (fast, no LLM needed for common patterns)
    private func decomposeIntoSteps(_ description: String, agentID: String) async -> [WorkflowStep] {
        // Try to decompose using explicit step markers
        let explicitSteps = parseExplicitSteps(description, agentID: agentID)
        if !explicitSteps.isEmpty {
            return explicitSteps
        }

        // Try comma/and separated tasks: "research X, write Y, and review Z"
        let commaSplit = parseCommaSeparated(description, agentID: agentID)
        if commaSplit.count >= 2 {
            return commaSplit
        }

        // Try "then" chain: "do X then do Y then do Z"
        let thenChain = parseThenChain(description, agentID: agentID)
        if thenChain.count >= 2 {
            return thenChain
        }

        // Try LLM decomposition for complex requests
        if let llmSteps = await llmDecompose(description, agentID: agentID), llmSteps.count >= 2 {
            return llmSteps
        }

        // Single step fallback
        return [WorkflowStep(index: 0, title: generateStepTitle(description), description: description,
                              assignedTo: agentID, dependsOnSteps: [])]
    }

    // MARK: - Pattern Parsing

    /// Parse numbered steps: "1. Do X  2. Do Y  3. Do Z"
    private func parseExplicitSteps(_ text: String, agentID: String) -> [WorkflowStep] {
        // Match patterns like "1. ", "1) ", "Step 1: "
        let patterns = [
            try? NSRegularExpression(pattern: #"(?:^|\n)\s*(\d+)[\.\)]\s*(.+?)(?=\n\s*\d+[\.\)]|\n*$)"#, options: [.dotMatchesLineSeparators]),
            try? NSRegularExpression(pattern: #"(?:^|\n)\s*[Ss]tep\s+(\d+)[:\s]+(.+?)(?=\n\s*[Ss]tep\s+\d+|\n*$)"#, options: [.dotMatchesLineSeparators])
        ].compactMap { $0 }

        for regex in patterns {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard matches.count >= 2 else { continue }

            return matches.enumerated().compactMap { idx, match in
                guard let range = Range(match.range(at: 2), in: text) else { return nil }
                let desc = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                return WorkflowStep(
                    index: idx,
                    title: generateStepTitle(desc),
                    description: desc,
                    assignedTo: agentID,
                    dependsOnSteps: idx > 0 ? [idx - 1] : []
                )
            }
        }

        return []
    }

    /// Parse comma/and separated: "research AI, write a report, review it"
    private func parseCommaSeparated(_ text: String, agentID: String) -> [WorkflowStep] {
        // Split on ", " and " and " but not inside quotes
        var parts: [String] = []
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split by ", and ", ", then ", ", "
        let segments = cleaned.components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " and then ") }
            .flatMap { $0.components(separatedBy: " then ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 5 }

        guard segments.count >= 2 else { return [] }

        // Handle " and " in the last segment
        if let last = segments.last, last.lowercased().hasPrefix("and ") {
            parts = Array(segments.dropLast()) + [String(last.dropFirst(4)).trimmingCharacters(in: .whitespaces)]
        } else {
            parts = segments
        }

        return parts.enumerated().map { idx, desc in
            return WorkflowStep(
                index: idx,
                title: generateStepTitle(desc),
                description: desc,
                assignedTo: agentID,
                dependsOnSteps: idx > 0 ? [idx - 1] : []
            )
        }
    }

    /// Parse "then" chains: "do X then do Y then do Z"
    private func parseThenChain(_ text: String, agentID: String) -> [WorkflowStep] {
        let parts = text.components(separatedBy: " then ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 5 }

        guard parts.count >= 2 else { return [] }

        return parts.enumerated().map { idx, desc in
            return WorkflowStep(
                index: idx,
                title: generateStepTitle(desc),
                description: desc,
                assignedTo: agentID,
                dependsOnSteps: idx > 0 ? [idx - 1] : []
            )
        }
    }

    /// Use a lightweight LLM call to decompose complex descriptions
    private func llmDecompose(_ description: String, agentID: String) async -> [WorkflowStep]? {
        let systemPrompt = """
        You are a workflow planner. Decompose the user's request into sequential steps.
        All steps are assigned to "\(agentID)" (the executing agent).

        Respond ONLY with a JSON array. Each element has:
        - "title": short step title (5-10 words)
        - "description": what this step should accomplish
        - "assigned_to": always "\(agentID)"
        - "depends_on": array of step indices (0-based) this depends on

        Example:
        [
          {"title": "Research AI trends", "description": "Search the web for latest AI trends", "assigned_to": "\(agentID)", "depends_on": []},
          {"title": "Write summary report", "description": "Write a comprehensive report based on the research", "assigned_to": "\(agentID)", "depends_on": [0]}
        ]
        """

        // Call through Base's own endpoint using a fast local model
        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }

        let body: [String: Any] = [
            "model": "qwen2.5:14b",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": description]
            ],
            "stream": false
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            TorboLog.warn("LLM decomposition failed — using heuristic fallback", subsystem: "Workflow")
            return nil
        }

        // Parse the response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }

        // Extract JSON from the response (might be wrapped in ```json ... ```)
        let jsonStr = extractJSON(from: content)
        guard let stepsData = jsonStr.data(using: .utf8),
              let stepsArray = try? JSONSerialization.jsonObject(with: stepsData) as? [[String: Any]] else {
            TorboLog.error("Failed to parse LLM step decomposition", subsystem: "Workflow")
            return nil
        }

        return stepsArray.enumerated().map { idx, step in
            let title = step["title"] as? String ?? "Step \(idx + 1)"
            let desc = step["description"] as? String ?? ""
            let assignee = step["assigned_to"] as? String ?? agentID
            let deps = step["depends_on"] as? [Int] ?? (idx > 0 ? [idx - 1] : [])

            return WorkflowStep(
                index: idx,
                title: title,
                description: desc,
                assignedTo: assignee,
                dependsOnSteps: deps
            )
        }
    }

    // MARK: - Helpers

    // Agent selection is handled by the caller or defaults to SiD

    private func generateStepTitle(_ description: String) -> String {
        let words = description.split(separator: " ").prefix(8).map(String.init)
        var title = words.joined(separator: " ")
        if description.split(separator: " ").count > 8 { title += "..." }
        return title
    }

    private func generateWorkflowName(_ description: String) -> String {
        let words = description.split(separator: " ").prefix(6).map(String.init)
        return words.joined(separator: " ") + (description.split(separator: " ").count > 6 ? "..." : "")
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON between ```json ... ``` or ``` ... ```
        if let start = text.range(of: "```json"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find raw JSON array
        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - Persistence

    private func saveWorkflows() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(workflows.values)) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: storePath))
        } catch {
            TorboLog.error("Failed to write workflows.json: \(error)", subsystem: "Workflows")
        }
    }

    /// Load persisted workflows from disk
    func loadFromDisk() {
        let url = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([Workflow].self, from: data) else { return }
        for wf in loaded { workflows[wf.id] = wf }
        TorboLog.info("Loaded \(workflows.count) workflow(s) from disk", subsystem: "Workflow")
    }
}
