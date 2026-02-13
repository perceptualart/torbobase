// Torbo Base — Task Queue Tool
import Foundation

// MARK: - Task Queue Tool

actor TaskQueueTool {
    static let shared = TaskQueueTool()
    
    /// Tool definition for creating a task
    static let createTaskToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_task",
            "description": "Create a new task and assign it to a crew member. Use this to delegate work or track objectives. Returns task ID and details.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Short title for the task (e.g., 'Implement screen capture tool')"
                    ] as [String: Any],
                    "description": [
                        "type": "string",
                        "description": "Detailed description of what needs to be done"
                    ] as [String: Any],
                    "assigned_to": [
                        "type": "string",
                        "description": "Crew member ID to assign this task to (sid, orion, mira, ada)"
                    ] as [String: Any],
                    "priority": [
                        "type": "string",
                        "enum": ["low", "normal", "high", "critical"],
                        "description": "Task priority level (default: normal)"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["title", "description", "assigned_to"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for listing tasks
    static let listTasksToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "list_tasks",
            "description": "List tasks from the queue. Can filter by status (pending/active/completed) or by assignee. Returns formatted task list with IDs, titles, and status.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filter": [
                        "type": "string",
                        "enum": ["all", "pending", "active", "completed", "mine"],
                        "description": "Filter tasks by status or 'mine' to see your assigned tasks (default: all)"
                    ] as [String: Any],
                    "assigned_to": [
                        "type": "string",
                        "description": "Optional: Filter by crew member ID (sid, orion, mira, ada)"
                    ] as [String: Any]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for completing a task
    static let completeTaskToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "complete_task",
            "description": "Mark a task as completed with a result summary. Use this when you finish work on a task.",
            "parameters": [
                "type": "object",
                "properties": [
                    "task_id": [
                        "type": "string",
                        "description": "ID of the task to complete (get from list_tasks)"
                    ] as [String: Any],
                    "result": [
                        "type": "string",
                        "description": "Summary of what was accomplished"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["task_id", "result"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    private let queue = TaskQueue.shared
    
    /// Create a new task
    func createTask(title: String, description: String, assignedTo: String, assignedBy: String, priority: String = "normal") async -> String {
        // Map priority string to enum
        let taskPriority: TaskQueue.TaskPriority
        switch priority.lowercased() {
        case "low":
            taskPriority = .low
        case "high":
            taskPriority = .high
        case "critical":
            taskPriority = .critical
        default:
            taskPriority = .normal
        }
        
        let task = await queue.createTask(
            title: title,
            description: description,
            assignedTo: assignedTo,
            assignedBy: assignedBy,
            priority: taskPriority
        )
        
        let priorityIcon = priorityString(taskPriority)
        return """
        ✅ Task created successfully
        
        ID: \(task.id)
        Title: \(task.title)
        Assigned to: \(task.assignedTo)
        Priority: \(priorityIcon) \(priority)
        Status: pending
        
        The task has been added to the queue. \(task.assignedTo) can claim it when ready.
        """
    }
    
    /// List tasks with optional filtering
    func listTasks(filter: String = "all", assignedTo: String? = nil, requestingCrew: String) async -> String {
        var tasks: [TaskQueue.CrewTask] = []
        
        // Apply filtering
        if filter.lowercased() == "mine" {
            tasks = await queue.tasksForCrew(requestingCrew)
        } else if let assignee = assignedTo {
            tasks = await queue.tasksForCrew(assignee)
        } else {
            switch filter.lowercased() {
            case "pending":
                tasks = await queue.pendingTasks()
            case "active":
                tasks = await queue.activeTasks()
            case "completed":
                tasks = await queue.recentCompleted(limit: 20)
            default:
                tasks = await queue.allTasks()
            }
        }
        
        if tasks.isEmpty {
            return "No tasks found matching the filter criteria."
        }
        
        // Group by status for better readability
        let pending = tasks.filter { $0.status == .pending }
        let active = tasks.filter { $0.status == .inProgress }
        let completed = tasks.filter { $0.status == .completed }
        let failed = tasks.filter { $0.status == .failed }
        
        var output = "# Task Queue\n\n"
        output += "Summary: \(pending.count) pending, \(active.count) active, \(completed.count) completed\n\n"
        
        // Show pending tasks
        if !pending.isEmpty {
            output += "## 📋 Pending (\(pending.count))\n"
            for task in pending {
                let ago = timeAgo(from: task.createdAt)
                let priorityIcon = priorityString(task.priority)
                output += """
                • [\(task.id.prefix(8))] \(priorityIcon) \(task.title)
                  → \(task.assignedTo) | by \(task.assignedBy) | \(ago)
                  \(task.description)
                
                """
            }
            output += "\n"
        }
        
        // Show active tasks
        if !active.isEmpty {
            output += "## ⚡ Active (\(active.count))\n"
            for task in active {
                let elapsed = task.startedAt.map { timeAgo(from: $0) } ?? "?"
                let priorityIcon = priorityString(task.priority)
                output += """
                • [\(task.id.prefix(8))] \(priorityIcon) \(task.title)
                  → \(task.assignedTo) | started \(elapsed)
                  \(task.description)
                
                """
            }
            output += "\n"
        }
        
        // Show completed tasks
        if !completed.isEmpty {
            output += "## ✅ Completed (\(completed.count))\n"
            for task in completed {
                let ago = task.completedAt.map { timeAgo(from: $0) } ?? "?"
                output += """
                • [\(task.id.prefix(8))] \(task.title)
                  → \(task.assignedTo) | completed \(ago)
                  Result: \(task.result ?? "No result provided")
                
                """
            }
            output += "\n"
        }
        
        // Show failed tasks
        if !failed.isEmpty {
            output += "## ❌ Failed (\(failed.count))\n"
            for task in failed {
                let ago = task.completedAt.map { timeAgo(from: $0) } ?? "?"
                output += """
                • [\(task.id.prefix(8))] \(task.title)
                  → \(task.assignedTo) | failed \(ago)
                  Error: \(task.error ?? "Unknown error")
                
                """
            }
        }
        
        return output
    }
    
    /// Complete a task
    func completeTask(taskId: String, result: String, completingCrew: String) async -> String {
        // Verify task exists
        guard let task = await queue.taskByID(taskId) else {
            return "❌ Task not found: \(taskId)"
        }
        
        // Verify crew member is assigned to this task
        if task.assignedTo != completingCrew {
            return "⚠️ Warning: This task is assigned to \(task.assignedTo), not you (\(completingCrew)). Completing anyway..."
        }
        
        // Check if already completed
        if task.status == .completed {
            return "ℹ️ Task '\(task.title)' was already marked as completed."
        }
        
        // Complete the task
        await queue.completeTask(id: taskId, result: result)
        
        let elapsed = task.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let timeStr = elapsed > 0 ? " in \(formatDuration(elapsed))" : ""
        
        return """
        ✅ Task completed successfully\(timeStr)
        
        ID: \(taskId)
        Title: \(task.title)
        Result: \(result)
        
        The task has been marked as completed in the queue.
        """
    }
    
    // MARK: - Helpers
    
    private func priorityString(_ priority: TaskQueue.TaskPriority) -> String {
        switch priority {
        case .low: return "🔵"
        case .normal: return "⚪"
        case .high: return "🟡"
        case .critical: return "🔴"
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }
}
