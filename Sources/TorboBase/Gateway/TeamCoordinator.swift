// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Team Coordinator
// Orchestrates multi-agent teams: task decomposition, parallel execution,
// dependency resolution, shared context, and result aggregation.
// Uses ParallelExecutor for concurrent subtask execution.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Team Coordinator

actor TeamCoordinator {
    static let shared = TeamCoordinator()

    /// All registered teams
    private var teams: [String: AgentTeam] = [:]

    /// Active team tasks
    private var activeTasks: [String: TeamTask] = [:]

    /// Shared contexts per team
    private var sharedContexts: [String: TeamSharedContext] = [:]

    /// Execution history
    private var executionHistory: [TeamExecution] = []

    /// Persistence paths
    private let teamsStorePath: String
    private let historyStorePath: String

    init() {
        let baseDir = PlatformPaths.appSupportDir.appendingPathComponent("TorboBase", isDirectory: true)
        teamsStorePath = baseDir.appendingPathComponent("agent_teams.json").path
        historyStorePath = baseDir.appendingPathComponent("agent_teams_history.json").path

        // Load from disk
        let (loadedTeams, loadedHistory) = Self.bootstrap(teamsPath: teamsStorePath, historyPath: historyStorePath)
        teams = loadedTeams
        executionHistory = loadedHistory

        if !loadedTeams.isEmpty {
            TorboLog.info("Loaded \(loadedTeams.count) team(s): \(loadedTeams.values.map(\.name).joined(separator: ", "))", subsystem: "Teams")
        }
    }

    private nonisolated static func bootstrap(teamsPath: String, historyPath: String) -> ([String: AgentTeam], [TeamExecution]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var teamMap: [String: AgentTeam] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: teamsPath)),
           let loaded = try? decoder.decode([AgentTeam].self, from: data) {
            for team in loaded { teamMap[team.id] = team }
        }

        var history: [TeamExecution] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: historyPath)),
           let loaded = try? decoder.decode([TeamExecution].self, from: data) {
            history = loaded
        }

        return (teamMap, history)
    }

    // MARK: - Team Management

    func createTeam(_ team: AgentTeam) -> AgentTeam {
        teams[team.id] = team
        saveTeams()
        TorboLog.info("Created team '\(team.name)' — coordinator: \(team.coordinatorAgentID), members: \(team.memberAgentIDs.joined(separator: ", "))", subsystem: "Teams")
        return team
    }

    func updateTeam(_ team: AgentTeam) {
        teams[team.id] = team
        saveTeams()
        TorboLog.info("Updated team '\(team.name)'", subsystem: "Teams")
    }

    func deleteTeam(_ id: String) -> Bool {
        guard teams.removeValue(forKey: id) != nil else { return false }
        sharedContexts.removeValue(forKey: id)
        saveTeams()
        TorboLog.info("Deleted team \(id.prefix(8))", subsystem: "Teams")
        return true
    }

    func team(_ id: String) -> AgentTeam? {
        teams[id]
    }

    func listTeams() -> [AgentTeam] {
        Array(teams.values).sorted { $0.name < $1.name }
    }

    // MARK: - Team Task Execution

    /// Execute a complex task using a team of agents.
    /// 1. Coordinator decomposes the task into subtasks
    /// 2. Subtasks are assigned to specialist agents
    /// 3. Independent subtasks run in parallel via ParallelExecutor
    /// 4. Dependent subtasks wait for their dependencies
    /// 5. Coordinator aggregates all results
    func executeTeamTask(teamID: String, taskDescription: String) async -> TeamResult? {
        guard var team = teams[teamID] else {
            TorboLog.error("Team \(teamID.prefix(8)) not found", subsystem: "Teams")
            return nil
        }

        var task = TeamTask(teamID: teamID, description: taskDescription)
        task.status = .decomposing
        task.startedAt = Date()
        activeTasks[task.id] = task

        TorboLog.info("Team '\(team.name)' starting: \(taskDescription.prefix(80))", subsystem: "Teams")

        await EventBus.shared.publish("system.team.started",
            payload: ["team_id": teamID, "team_name": team.name, "task_id": task.id, "description": String(taskDescription.prefix(200))],
            source: "TeamCoordinator")

        // Step 1: Decompose task using coordinator agent
        let subtasks = await decomposeTask(description: taskDescription, coordinator: team.coordinatorAgentID, members: team.memberAgentIDs)

        if subtasks.isEmpty {
            task.status = .failed
            task.error = "Coordinator failed to decompose task"
            task.completedAt = Date()
            activeTasks[task.id] = task
            recordExecution(task)
            TorboLog.error("Team '\(team.name)' decomposition failed", subsystem: "Teams")
            return nil
        }

        // Step 2: Assign subtasks to members
        let assigned = assignSubtasks(subtasks: subtasks, members: team.memberAgentIDs)
        task.subtasks = assigned
        task.status = .running
        activeTasks[task.id] = task

        TorboLog.info("Team '\(team.name)' decomposed into \(assigned.count) subtask(s)", subsystem: "Teams")
        for st in assigned {
            TorboLog.info("  -> \(st.assignedTo): \(st.description.prefix(60))", subsystem: "Teams")
        }

        // Step 3: Execute subtasks respecting dependencies
        let subtaskResults = await executeSubtasksWithDependencies(subtasks: assigned, teamID: teamID)

        // Check for failures
        let failedCount = assigned.filter { subtaskResults[$0.id] == nil }.count
        if failedCount == assigned.count {
            task.status = .failed
            task.error = "All subtasks failed"
            task.completedAt = Date()
            activeTasks[task.id] = task
            recordExecution(task)
            TorboLog.error("Team '\(team.name)' all subtasks failed", subsystem: "Teams")
            return nil
        }

        // Step 4: Aggregate results using coordinator
        task.status = .aggregating
        activeTasks[task.id] = task

        let aggregated = await aggregateResults(subtaskResults: subtaskResults, originalTask: taskDescription, coordinator: team.coordinatorAgentID)

        let teamResult = TeamResult(subtaskResults: subtaskResults, aggregatedResult: aggregated)
        task.result = teamResult
        task.status = .completed
        task.completedAt = Date()

        // Update subtask statuses
        for i in task.subtasks.indices {
            if subtaskResults[task.subtasks[i].id] != nil {
                task.subtasks[i].status = .completed
                task.subtasks[i].result = subtaskResults[task.subtasks[i].id]
                task.subtasks[i].completedAt = Date()
            } else {
                task.subtasks[i].status = .failed
                task.subtasks[i].completedAt = Date()
            }
        }

        activeTasks[task.id] = task
        recordExecution(task)

        // Update team last used
        team.lastUsedAt = Date()
        teams[teamID] = team
        saveTeams()

        let elapsed = task.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        TorboLog.info("Team '\(team.name)' completed in \(elapsed)s — \(subtaskResults.count)/\(assigned.count) subtasks succeeded", subsystem: "Teams")

        await EventBus.shared.publish("system.team.completed",
            payload: ["team_id": teamID, "team_name": team.name, "task_id": task.id, "elapsed": "\(elapsed)", "subtasks": "\(subtaskResults.count)/\(assigned.count)"],
            source: "TeamCoordinator")

        return teamResult
    }

    // MARK: - Task Decomposition

    /// Use the coordinator agent to decompose a complex task into subtasks.
    func decomposeTask(description: String, coordinator: String, members: [String]) async -> [Subtask] {
        let memberList = members.joined(separator: ", ")
        let prompt = """
        You are a team coordinator. Break this task into subtasks that can be assigned to specialist agents.

        TASK: \(description)

        AVAILABLE AGENTS: \(memberList)

        Respond with a JSON array of subtasks. Each subtask should have:
        - "description": What to do (be specific and actionable)
        - "assigned_to": Which agent ID should handle it (from the available list)
        - "depends_on": Array of subtask indices (0-based) that must complete first. Use [] for independent tasks.

        Rules:
        - Maximize parallelism — only add dependencies when output from one subtask is truly needed by another
        - Each subtask should be self-contained enough for one agent to complete
        - Assign based on agent specialization when possible
        - Keep it to 2-6 subtasks (don't over-decompose)

        Respond ONLY with the JSON array, no other text. Example:
        [
            {"description": "Research current market trends", "assigned_to": "web-researcher", "depends_on": []},
            {"description": "Draft the analysis report", "assigned_to": "document-writer", "depends_on": [0]}
        ]
        """

        let response = await callCoordinatorLLM(agentID: coordinator, prompt: prompt)

        // Parse JSON response
        guard let jsonData = extractJSON(from: response),
              let subtaskDicts = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            TorboLog.warn("Failed to parse decomposition response — creating single subtask", subsystem: "Teams")
            // Fallback: single subtask assigned to first member
            let assignee = members.first ?? coordinator
            return [Subtask(description: description, assignedTo: assignee)]
        }

        var subtasks: [Subtask] = []
        var idByIndex: [Int: String] = [:]

        for (index, dict) in subtaskDicts.enumerated() {
            let desc = dict["description"] as? String ?? "Subtask \(index + 1)"
            let assignedTo = dict["assigned_to"] as? String ?? members.first ?? coordinator
            let depIndices = dict["depends_on"] as? [Int] ?? []

            // Map dependency indices to subtask IDs
            let depIDs = depIndices.compactMap { idByIndex[$0] }

            let subtask = Subtask(description: desc, assignedTo: assignedTo, dependencies: depIDs)
            idByIndex[index] = subtask.id
            subtasks.append(subtask)
        }

        return subtasks
    }

    // MARK: - Subtask Assignment

    /// Assign subtasks to team members, load-balancing when needed.
    func assignSubtasks(subtasks: [Subtask], members: [String]) -> [Subtask] {
        var assigned = subtasks

        // Validate assignments — if an agent isn't in the member list, reassign round-robin
        var memberLoad: [String: Int] = [:]
        for member in members { memberLoad[member] = 0 }

        for i in assigned.indices {
            if !members.contains(assigned[i].assignedTo) {
                // Assign to least-loaded member
                let leastLoaded = members.min { (memberLoad[$0] ?? 0) < (memberLoad[$1] ?? 0) } ?? members[0]
                assigned[i].assignedTo = leastLoaded
            }
            memberLoad[assigned[i].assignedTo, default: 0] += 1
        }

        return assigned
    }

    // MARK: - Parallel Execution with Dependencies

    /// Execute subtasks respecting dependency ordering.
    /// Independent subtasks run in parallel via ParallelExecutor.
    private func executeSubtasksWithDependencies(subtasks: [Subtask], teamID: String) async -> [String: String] {
        var results: [String: String] = [:]
        var remaining = Set(subtasks.map(\.id))
        var completed = Set<String>()
        let subtaskMap = Dictionary(uniqueKeysWithValues: subtasks.map { ($0.id, $0) })

        while !remaining.isEmpty {
            // Find subtasks whose dependencies are all satisfied
            let ready = remaining.filter { id in
                guard let st = subtaskMap[id] else { return false }
                return st.dependencies.allSatisfy { completed.contains($0) }
            }

            if ready.isEmpty {
                // Deadlock — dependencies can never be satisfied
                TorboLog.error("Dependency deadlock — \(remaining.count) subtasks stuck", subsystem: "Teams")
                break
            }

            // Execute all ready subtasks in parallel
            let batchResults = await executeSubtaskBatch(
                subtaskIDs: Array(ready),
                subtaskMap: subtaskMap,
                priorResults: results,
                teamID: teamID
            )

            for (id, result) in batchResults {
                results[id] = result
                completed.insert(id)
                remaining.remove(id)
            }

            // Mark failed subtasks (in ready set but not in results)
            for id in ready where batchResults[id] == nil {
                completed.insert(id)
                remaining.remove(id)
                TorboLog.warn("Subtask \(id.prefix(8)) failed — dependents will use partial context", subsystem: "Teams")
            }
        }

        return results
    }

    /// Execute a batch of independent subtasks in parallel.
    private func executeSubtaskBatch(subtaskIDs: [String], subtaskMap: [String: Subtask], priorResults: [String: String], teamID: String) async -> [String: String] {
        // Use a task group to run all subtasks concurrently
        return await withTaskGroup(of: (String, String?).self) { group in
            for id in subtaskIDs {
                guard let subtask = subtaskMap[id] else { continue }

                group.addTask {
                    let result = await self.executeSingleSubtask(subtask, priorResults: priorResults, teamID: teamID)
                    return (id, result)
                }
            }

            var batchResults: [String: String] = [:]
            for await (id, result) in group {
                if let result { batchResults[id] = result }
            }
            return batchResults
        }
    }

    /// Execute a single subtask through the gateway.
    private func executeSingleSubtask(_ subtask: Subtask, priorResults: [String: String], teamID: String) async -> String? {
        // Build context from dependencies
        var context = ""
        for depID in subtask.dependencies {
            if let depResult = priorResults[depID] {
                context += "Result from prior subtask:\n\(depResult)\n\n"
            }
        }

        // Include shared context
        if let sharedCtx = sharedContexts[teamID] {
            let entries = sharedCtx.entries.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            if !entries.isEmpty {
                context += "Shared team context:\n\(entries)\n\n"
            }
        }

        let prompt = """
        You have been assigned a subtask as part of a team effort.

        SUBTASK: \(subtask.description)
        \(context.isEmpty ? "" : "\nCONTEXT:\n\(context)")
        Execute this subtask thoroughly. Provide a clear, detailed result that other team members can build on.
        Do NOT ask questions — execute autonomously. If blocked, document what you accomplished and what remains.
        """

        // Execute through the gateway (same pattern as ProactiveAgent)
        do {
            let result = try await executeAgentCall(agentID: subtask.assignedTo, prompt: prompt)
            TorboLog.info("Subtask \(subtask.id.prefix(8)) (\(subtask.assignedTo)) completed", subsystem: "Teams")
            return result
        } catch {
            TorboLog.error("Subtask \(subtask.id.prefix(8)) (\(subtask.assignedTo)) failed: \(error.localizedDescription)", subsystem: "Teams")
            return nil
        }
    }

    // MARK: - Result Aggregation

    /// Use the coordinator agent to combine all subtask results into a coherent final answer.
    func aggregateResults(subtaskResults: [String: String], originalTask: String, coordinator: String) async -> String {
        let resultsSummary = subtaskResults.enumerated().map { idx, entry in
            "Subtask \(idx + 1) result:\n\(entry.value)"
        }.joined(separator: "\n\n---\n\n")

        let prompt = """
        You are a team coordinator. Your specialist agents have completed their subtasks.
        Now combine their results into a single, coherent response.

        ORIGINAL TASK: \(originalTask)

        SUBTASK RESULTS:
        \(resultsSummary)

        Synthesize these results into a comprehensive response that directly addresses the original task.
        Resolve any conflicts between subtask outputs. Present the final answer clearly and concisely.
        Do not mention "subtasks" or "team" — present it as a unified response.
        """

        do {
            let aggregated = try await executeAgentCall(agentID: coordinator, prompt: prompt)
            return aggregated
        } catch {
            TorboLog.error("Aggregation failed: \(error.localizedDescription) — returning raw results", subsystem: "Teams")
            return resultsSummary
        }
    }

    // MARK: - Shared Context

    func updateSharedContext(teamID: String, key: String, value: String) {
        var ctx = sharedContexts[teamID] ?? TeamSharedContext()
        ctx.set(key, value: value)
        sharedContexts[teamID] = ctx
    }

    func getSharedContext(teamID: String, key: String) -> String? {
        sharedContexts[teamID]?.get(key)
    }

    func getAllSharedContext(teamID: String) -> TeamSharedContext {
        sharedContexts[teamID] ?? TeamSharedContext()
    }

    func clearSharedContext(teamID: String) {
        sharedContexts[teamID] = TeamSharedContext()
    }

    // MARK: - Execution History

    func getExecutionHistory(teamID: String? = nil, limit: Int = 50) -> [TeamExecution] {
        let filtered: [TeamExecution]
        if let teamID {
            filtered = executionHistory.filter { $0.teamID == teamID }
        } else {
            filtered = executionHistory
        }
        return Array(filtered.suffix(limit))
    }

    private func recordExecution(_ task: TeamTask) {
        let execution = TeamExecution(task: task)
        executionHistory.append(execution)
        // Keep last 200 executions
        if executionHistory.count > 200 {
            executionHistory = Array(executionHistory.suffix(200))
        }
        saveHistory()
    }

    // MARK: - Active Task Queries

    func activeTask(_ id: String) -> TeamTask? {
        activeTasks[id]
    }

    func activeTasksForTeam(_ teamID: String) -> [TeamTask] {
        activeTasks.values.filter { $0.teamID == teamID && $0.status != .completed && $0.status != .failed }
    }

    // MARK: - LLM Execution

    /// Call an agent through the local gateway (same pattern as ProactiveAgent).
    private func executeAgentCall(agentID: String, prompt: String) async throws -> String {
        let token = await MainActor.run { AppState.shared.serverToken }
        let port = await MainActor.run { AppState.shared.serverPort }

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            throw TeamError.invalidGatewayURL
        }

        let messages: [[String: Any]] = [
            ["role": "user", "content": prompt]
        ]

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "messages": messages,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown"
            throw TeamError.gatewayError(httpResponse.statusCode, errorBody)
        }

        // Parse OpenAI-compatible response
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        // Try Anthropic native format
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }

        throw TeamError.parseError
    }

    /// Extract JSON array from a response that may contain surrounding text.
    private func extractJSON(from text: String) -> Data? {
        // Try direct parse first
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] != nil {
            return data
        }

        // Find JSON array in the response
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }

        let jsonStr = String(text[start...end])
        return jsonStr.data(using: .utf8)
    }

    /// Call coordinator LLM with a simple prompt (no tool loop).
    private func callCoordinatorLLM(agentID: String, prompt: String) async -> String {
        do {
            return try await executeAgentCall(agentID: agentID, prompt: prompt)
        } catch {
            TorboLog.error("Coordinator LLM call failed: \(error.localizedDescription)", subsystem: "Teams")
            return ""
        }
    }

    // MARK: - Persistence

    private func saveTeams() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(teams.values)) else { return }
        try? data.write(to: URL(fileURLWithPath: teamsStorePath), options: .atomic)
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(executionHistory) else { return }
        try? data.write(to: URL(fileURLWithPath: historyStorePath), options: .atomic)
    }

    // MARK: - Errors

    enum TeamError: Error, LocalizedError {
        case invalidGatewayURL
        case gatewayError(Int, String)
        case parseError
        case teamNotFound

        var errorDescription: String? {
            switch self {
            case .invalidGatewayURL: return "Invalid gateway URL"
            case .gatewayError(let code, let msg): return "Gateway error \(code): \(msg.prefix(100))"
            case .parseError: return "Failed to parse LLM response"
            case .teamNotFound: return "Team not found"
            }
        }
    }
}
