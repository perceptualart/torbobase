import Foundation

// MARK: - Task Queue — Inter-Crew Delegation & Parallel Execution

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

    struct CrewTask: Codable, Identifiable {
        let id: String
        let title: String
        let description: String
        let assignedTo: String      // crew member ID
        let assignedBy: String      // who created it
        let priority: TaskPriority
        var status: TaskStatus
        var result: String?
        var error: String?
        let createdAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var subtasks: [String]      // IDs of child tasks

        init(title: String, description: String, assignedTo: String, assignedBy: String, priority: TaskPriority = .normal) {
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
        }
    }

    // MARK: - Storage

    private var tasks: [String: CrewTask] = [:]
    private var taskOrder: [String] = []  // ordered by priority then creation time
    private let storePath = NSHomeDirectory() + "/Library/Application Support/ORBBase/task_queue.json"

    init() {
        loadTasks()
    }

    // MARK: - Task Management

    func createTask(title: String, description: String, assignedTo: String, assignedBy: String, priority: TaskPriority = .normal) -> CrewTask {
        let task = CrewTask(title: title, description: description, assignedTo: assignedTo, assignedBy: assignedBy, priority: priority)
        tasks[task.id] = task
        insertOrdered(task.id)
        saveTasks()
        print("[TaskQueue] Created: '\(title)' -> \(assignedTo) (priority: \(priority))")
        return task
    }

    func claimTask(crewID: String) -> CrewTask? {
        // Find highest priority pending task for this crew member
        for taskID in taskOrder {
            guard var task = tasks[taskID],
                  task.assignedTo == crewID,
                  task.status == .pending else { continue }
            task.status = .inProgress
            task.startedAt = Date()
            tasks[taskID] = task
            saveTasks()
            print("[TaskQueue] \(crewID) claimed: '\(task.title)'")
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
        print("[TaskQueue] Completed: '\(task.title)' in \(elapsed)s")
    }

    func failTask(id: String, error: String) {
        guard var task = tasks[id] else { return }
        task.status = .failed
        task.error = error
        task.completedAt = Date()
        tasks[id] = task
        saveTasks()
        print("[TaskQueue] Failed: '\(task.title)' — \(error)")
    }

    func cancelTask(id: String) {
        guard var task = tasks[id] else { return }
        task.status = .cancelled
        task.completedAt = Date()
        tasks[id] = task
        saveTasks()
        print("[TaskQueue] Cancelled: '\(task.title)'")
    }

    // MARK: - Queries

    func tasksForCrew(_ crewID: String) -> [CrewTask] {
        taskOrder.compactMap { tasks[$0] }.filter { $0.assignedTo == crewID }
    }

    func pendingTasks(for crewID: String? = nil) -> [CrewTask] {
        let all = taskOrder.compactMap { tasks[$0] }.filter { $0.status == .pending }
        if let crew = crewID { return all.filter { $0.assignedTo == crew } }
        return all
    }

    func activeTasks() -> [CrewTask] {
        taskOrder.compactMap { tasks[$0] }.filter { $0.status == .inProgress }
    }

    func recentCompleted(limit: Int = 10) -> [CrewTask] {
        Array(tasks.values
            .filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(limit))
    }

    func allTasks() -> [CrewTask] {
        taskOrder.compactMap { tasks[$0] }
    }

    func taskByID(_ id: String) -> CrewTask? {
        tasks[id]
    }

    // MARK: - Delegation

    func delegate(from: String, to: String, title: String, description: String, priority: TaskPriority = .normal) -> CrewTask {
        let task = createTask(title: title, description: description, assignedTo: to, assignedBy: from, priority: priority)
        print("[TaskQueue] \(from) delegated '\(title)' to \(to)")
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
        try? data.write(to: URL(fileURLWithPath: storePath))
    }

    private func loadTasks() {
        let url = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([CrewTask].self, from: data) else { return }
        for task in loaded {
            tasks[task.id] = task
            insertOrdered(task.id)
        }
        print("[TaskQueue] Loaded \(tasks.count) tasks from disk")
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
