// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
import Foundation

// MARK: - Task Queue — Task Delegation & Parallel Execution

actor TaskQueue {
    static let shared = TaskQueue()

    enum TaskStatus: String, Codable {
        case pending
        case inProgress
        case completed
        case failed
        case cancelled
    }

    enum TaskPriority: Int, Codable, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3

        static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct AgentTask: Codable, Identifiable {
        let id: String
        let title: String
        let description: String
        let assignedTo: String      // agent ID
        let assignedBy: String      // who created it
        let priority: TaskPriority
        var status: TaskStatus
        var result: String?
        var error: String?
        let createdAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var subtasks: [String]      // IDs of child tasks

        // Workflow support
        var workflowID: String?         // ID of parent workflow (nil = standalone task)
        var parentTaskID: String?       // ID of parent task (for subtask hierarchy)
        var dependsOn: [String]         // Task IDs that must complete before this starts
        var stepIndex: Int?             // Order within workflow (0-based)
        var context: String?            // Context passed from previous task result

        init(title: String, description: String, assignedTo: String, assignedBy: String, priority: TaskPriority = .normal,
             workflowID: String? = nil, parentTaskID: String? = nil, dependsOn: [String] = [], stepIndex: Int? = nil) {
            self.id = UUID().uuidString
            self.title = title
            self.description = description
            self.assignedTo = assignedTo
            self.assignedBy = assignedBy
            self.priority = priority
            self.status = .pending
            self.result = nil
            self.error = nil
            self.createdAt = Date()
            self.startedAt = nil
            self.completedAt = nil
            self.subtasks = []
            self.workflowID = workflowID
            self.parentTaskID = parentTaskID
            self.dependsOn = dependsOn
            self.stepIndex = stepIndex
            self.context = nil
        }
    }

    // MARK: - Storage

    private var tasks: [String: AgentTask]
    private var taskOrder: [String]
    private let storePath: String

    init() {
        let path = PlatformPaths.tasksFile
        storePath = path
        // Bootstrap from disk using nonisolated static helper
        let (loadedTasks, loadedOrder) = Self.bootstrapTasks(from: path)
        tasks = loadedTasks
        taskOrder = loadedOrder
        if !loadedTasks.isEmpty {
            TorboLog.info("Loaded \(loadedTasks.count) tasks from disk", subsystem: "Tasks")
        }
    }

    /// Load and order tasks from disk (nonisolated for safe actor init)
    private nonisolated static func bootstrapTasks(from path: String) -> ([String: AgentTask], [String]) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return ([:], []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([AgentTask].self, from: data) else { return ([:], []) }
        var taskMap: [String: AgentTask] = [:]
        for task in loaded { taskMap[task.id] = task }
        // Sort by priority (higher first) then creation time (older first)
        let ordered = loaded.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.createdAt < b.createdAt
        }.map(\.id)
        return (taskMap, ordered)
    }

    // MARK: - Task Management

    func createTask(title: String, description: String, assignedTo: String, assignedBy: String, priority: TaskPriority = .normal) -> AgentTask {
        let task = AgentTask(title: title, description: description, assignedTo: assignedTo, assignedBy: assignedBy, priority: priority)
        tasks[task.id] = task
        insertOrdered(task.id)
        saveTasks()
        TorboLog.info("Created: '\(title)' -> \(assignedTo) (priority: \(priority))", subsystem: "Tasks")
        return task
    }

    func claimTask(agentID: String) -> AgentTask? {
        // Find highest priority pending task for this agent
        // Respects dependency ordering — tasks with unmet deps are skipped
        for taskID in taskOrder {
            guard var task = tasks[taskID],
                  task.assignedTo == agentID,
                  task.status == .pending else { continue }

            // Check dependencies — all must be completed
            if !task.dependsOn.isEmpty {
                let allDepsComplete = task.dependsOn.allSatisfy { depID in
                    tasks[depID]?.status == .completed
                }
                if !allDepsComplete {
                    // Check if any dep failed — if so, skip this task too
                    let anyDepFailed = task.dependsOn.contains { depID in
                        let s = tasks[depID]?.status
                        return s == .failed || s == .cancelled
                    }
                    if anyDepFailed {
                        task.status = .cancelled
                        task.error = "Dependency failed"
                        task.completedAt = Date()
                        tasks[taskID] = task
                        saveTasks()
                        TorboLog.warn("Auto-cancelled '\(task.title)' — dependency failed", subsystem: "Tasks")

                        // Check if this was part of a workflow
                        if let wfID = task.workflowID {
                            let taskID = task.id
                            Task { await WorkflowEngine.shared.onTaskFailed(taskID: taskID, workflowID: wfID) }
                        }
                    }
                    continue  // Skip — deps not met yet
                }

                // Inject context from completed dependencies
                let depContext = task.dependsOn.compactMap { depID -> String? in
                    guard let dep = tasks[depID], let result = dep.result else { return nil }
                    return "[\(dep.title)] Result:\n\(result)"
                }.joined(separator: "\n\n---\n\n")

                if !depContext.isEmpty {
                    task.context = depContext
                }
            }

            task.status = .inProgress
            task.startedAt = Date()
            tasks[taskID] = task
            saveTasks()
            TorboLog.info("\(agentID) claimed: '\(task.title)'" + (task.workflowID != nil ? " (workflow step \((task.stepIndex ?? 0) + 1))" : ""), subsystem: "Tasks")
            return task
        }
        return nil
    }

    func completeTask(id: String, result: String) {
        guard var task = tasks[id] else { return }
        task.status = .completed
        task.result = result
        task.completedAt = Date()
        tasks[id] = task
        saveTasks()
        let elapsed = task.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        TorboLog.info("Completed: '\(task.title)' in \(elapsed)s", subsystem: "Tasks")

        // Notify workflow engine if part of a workflow
        if let wfID = task.workflowID {
            Task { await WorkflowEngine.shared.onTaskCompleted(taskID: id, workflowID: wfID) }
        }
    }

    func failTask(id: String, error: String) {
        guard var task = tasks[id] else { return }
        task.status = .failed
        task.error = error
        task.completedAt = Date()
        tasks[id] = task
        saveTasks()
        TorboLog.error("Failed: '\(task.title)' — \(error)", subsystem: "Tasks")

        // Notify workflow engine if part of a workflow
        if let wfID = task.workflowID {
            Task { await WorkflowEngine.shared.onTaskFailed(taskID: id, workflowID: wfID) }
        }
    }

    func cancelTask(id: String) {
        guard var task = tasks[id] else { return }
        task.status = .cancelled
        task.completedAt = Date()
        tasks[id] = task
        saveTasks()
        TorboLog.info("Cancelled: '\(task.title)'", subsystem: "Tasks")
    }

    // MARK: - Queries

    func tasksForAgent(_ agentID: String) -> [AgentTask] {
        taskOrder.compactMap { tasks[$0] }.filter { $0.assignedTo == agentID }
    }

    func pendingTasks(for agentID: String? = nil) -> [AgentTask] {
        let all = taskOrder.compactMap { tasks[$0] }.filter { $0.status == .pending }
        if let agent = agentID { return all.filter { $0.assignedTo == agent } }
        return all
    }

    func activeTasks() -> [AgentTask] {
        taskOrder.compactMap { tasks[$0] }.filter { $0.status == .inProgress }
    }

    func recentCompleted(limit: Int = 10) -> [AgentTask] {
        Array(tasks.values
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(limit))
    }

    func allTasks() -> [AgentTask] {
        taskOrder.compactMap { tasks[$0] }
    }

    func taskByID(_ id: String) -> AgentTask? {
        tasks[id]
    }

    // MARK: - Workflow Task Creation

    func createWorkflowTask(title: String, description: String, assignedTo: String, assignedBy: String,
                             priority: TaskPriority = .normal, workflowID: String, dependsOn: [String] = [],
                             stepIndex: Int) -> AgentTask {
        let task = AgentTask(title: title, description: description, assignedTo: assignedTo, assignedBy: assignedBy,
                            priority: priority, workflowID: workflowID, dependsOn: dependsOn, stepIndex: stepIndex)
        tasks[task.id] = task
        insertOrdered(task.id)
        saveTasks()
        TorboLog.info("Created workflow step \(stepIndex + 1): '\(title)' -> \(assignedTo) (workflow: \(workflowID.prefix(8)))", subsystem: "Tasks")
        return task
    }

    // MARK: - Workflow Queries

    func tasksForWorkflow(_ workflowID: String) -> [AgentTask] {
        tasks.values
            .filter { $0.workflowID == workflowID }
            .sorted { ($0.stepIndex ?? 0) < ($1.stepIndex ?? 0) }
    }

    func workflowProgress(_ workflowID: String) -> (total: Int, completed: Int, failed: Int, active: Int) {
        let wfTasks = tasksForWorkflow(workflowID)
        let total = wfTasks.count
        let completed = wfTasks.filter { $0.status == .completed }.count
        let failed = wfTasks.filter { $0.status == .failed || $0.status == .cancelled }.count
        let active = wfTasks.filter { $0.status == .inProgress }.count
        return (total, completed, failed, active)
    }

    // MARK: - Delegation

    func delegate(from: String, to: String, title: String, description: String, priority: TaskPriority = .normal) -> AgentTask {
        let task = createTask(title: title, description: description, assignedTo: to, assignedBy: from, priority: priority)
        TorboLog.info("\(from) delegated '\(title)' to \(to)", subsystem: "Tasks")
        return task
    }

    // MARK: - Summary

    func summary() -> String {
        let pending = tasks.values.filter { $0.status == .pending }.count
        let active = tasks.values.filter { $0.status == .inProgress }.count
        let completed = tasks.values.filter { $0.status == .completed }.count
        let failed = tasks.values.filter { $0.status == .failed }.count
        return "Tasks: \(pending) pending, \(active) active, \(completed) completed, \(failed) failed"
    }

    // MARK: - Persistence

    private func saveTasks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(tasks.values)) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: storePath))
        } catch {
            TorboLog.error("Failed to write tasks.json: \(error)", subsystem: "Tasks")
        }
    }

    private func loadTasks() {
        let url = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([AgentTask].self, from: data) else { return }
        for task in loaded {
            tasks[task.id] = task
            insertOrdered(task.id)
        }
        TorboLog.info("Loaded \(tasks.count) tasks from disk", subsystem: "Tasks")
    }

    private func insertOrdered(_ id: String) {
        guard let task = tasks[id] else { return }
        // Insert by priority (higher first), then by creation time (older first)
        let idx = taskOrder.firstIndex { existingID in
            guard let existing = tasks[existingID] else { return false }
            if task.priority != existing.priority { return task.priority > existing.priority }
            return task.createdAt < existing.createdAt
        } ?? taskOrder.endIndex
        taskOrder.insert(id, at: idx)
    }
}
