// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Scheduler
// Full cron expression scheduling: parse standard 5-field cron, calculate next_run,
// execute tasks through the LLM pipeline, store results, push to connected clients.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Cron Task Model

struct CronTask: Codable, Identifiable {
    let id: String
    var name: String
    var cronExpression: String           // Standard 5-field: minute hour day month weekday
    var agentID: String                  // Which agent executes this
    var prompt: String                   // What the agent should do
    var enabled: Bool
    var lastRun: Date?
    var nextRun: Date?
    var lastResult: String?
    var lastError: String?
    var runCount: Int
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case cronExpression = "cron_expression"
        case agentID = "agent_id"
        case prompt, enabled
        case lastRun = "last_run"
        case nextRun = "next_run"
        case lastResult = "last_result"
        case lastError = "last_error"
        case runCount = "run_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Cron Expression Parser

/// Parses standard 5-field cron expressions: minute hour day-of-month month day-of-week
/// Supports: numbers, ranges (1-5), steps (*/5), lists (1,3,5), wildcards (*)
struct CronExpression {
    let minutes: Set<Int>       // 0-59
    let hours: Set<Int>         // 0-23
    let daysOfMonth: Set<Int>   // 1-31
    let months: Set<Int>        // 1-12
    let daysOfWeek: Set<Int>    // 0-6 (0=Sunday) or 1-7 (1=Sunday — both accepted)

    /// Parse a 5-field cron expression string.
    /// Returns nil if the expression is invalid.
    static func parse(_ expression: String) -> CronExpression? {
        let fields = expression.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }

        guard let minutes = parseField(fields[0], min: 0, max: 59),
              let hours = parseField(fields[1], min: 0, max: 23),
              let daysOfMonth = parseField(fields[2], min: 1, max: 31),
              let months = parseField(fields[3], min: 1, max: 12),
              let daysOfWeek = parseDayOfWeekField(fields[4]) else {
            return nil
        }

        return CronExpression(
            minutes: minutes, hours: hours,
            daysOfMonth: daysOfMonth, months: months,
            daysOfWeek: daysOfWeek
        )
    }

    /// Calculate the next run time after `after` date.
    func nextRunAfter(_ after: Date) -> Date? {
        let calendar = Calendar.current
        // Start from the next whole minute
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        components.second = 0

        guard var current = calendar.date(from: components) else { return nil }
        // Move to the next minute
        current = calendar.date(byAdding: .minute, value: 1, to: current) ?? current

        // Search forward up to 2 years (enough for any cron pattern)
        let maxIterations = 525960  // ~1 year in minutes
        for _ in 0..<maxIterations {
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: current)
            guard let month = comps.month, let day = comps.day,
                  let hour = comps.hour, let minute = comps.minute,
                  let weekday = comps.weekday else {
                return nil
            }

            // Calendar weekday: 1=Sunday, 2=Monday ... 7=Saturday
            // Cron weekday: 0=Sunday, 1=Monday ... 6=Saturday
            let cronWeekday = weekday - 1

            if months.contains(month) &&
               daysOfMonth.contains(day) &&
               daysOfWeek.contains(cronWeekday) &&
               hours.contains(hour) &&
               minutes.contains(minute) {
                return current
            }

            // Optimization: skip ahead smartly
            if !months.contains(month) {
                // Jump to next matching month
                if let nextDate = advanceToNextMonth(from: current, months: months, calendar: calendar) {
                    current = nextDate
                    continue
                }
                return nil
            }
            if !daysOfMonth.contains(day) || !daysOfWeek.contains(cronWeekday) {
                // Jump to next day
                current = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current)) ?? current
                continue
            }
            if !hours.contains(hour) {
                // Jump to next hour
                var next = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
                let nextComps = calendar.dateComponents([.year, .month, .day, .hour], from: next)
                next = calendar.date(from: nextComps) ?? next  // Zero out minutes
                current = next
                continue
            }
            // Minutes don't match — advance one minute
            current = calendar.date(byAdding: .minute, value: 1, to: current) ?? current
        }
        return nil
    }

    // MARK: - Field Parsing

    private static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        let parts = field.split(separator: ",").map(String.init)

        for part in parts {
            if let values = parsePart(part, min: min, max: max) {
                result.formUnion(values)
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func parsePart(_ part: String, min: Int, max: Int) -> Set<Int>? {
        // Wildcard: *
        if part == "*" {
            return Set(min...max)
        }

        // Step: */N or M-N/S
        if part.contains("/") {
            let stepParts = part.split(separator: "/").map(String.init)
            guard stepParts.count == 2, let step = Int(stepParts[1]), step > 0 else { return nil }

            let rangeStart: Int
            let rangeEnd: Int

            if stepParts[0] == "*" {
                rangeStart = min
                rangeEnd = max
            } else if stepParts[0].contains("-") {
                let rangeParts = stepParts[0].split(separator: "-").map(String.init)
                guard rangeParts.count == 2,
                      let start = Int(rangeParts[0]),
                      let end = Int(rangeParts[1]),
                      start >= min, end <= max, start <= end else { return nil }
                rangeStart = start
                rangeEnd = end
            } else {
                guard let start = Int(stepParts[0]), start >= min, start <= max else { return nil }
                rangeStart = start
                rangeEnd = max
            }

            var values = Set<Int>()
            var current = rangeStart
            while current <= rangeEnd {
                values.insert(current)
                current += step
            }
            return values
        }

        // Range: M-N
        if part.contains("-") {
            let rangeParts = part.split(separator: "-").map(String.init)
            guard rangeParts.count == 2,
                  let start = Int(rangeParts[0]),
                  let end = Int(rangeParts[1]),
                  start >= min, end <= max, start <= end else { return nil }
            return Set(start...end)
        }

        // Single value
        if let value = Int(part), value >= min, value <= max {
            return Set([value])
        }

        return nil
    }

    /// Day-of-week field: accepts 0-7 (both 0 and 7 = Sunday), plus standard named days
    private static func parseDayOfWeekField(_ field: String) -> Set<Int>? {
        // Replace named days with numbers
        var processed = field.uppercased()
        let dayNames = ["SUN": "0", "MON": "1", "TUE": "2", "WED": "3", "THU": "4", "FRI": "5", "SAT": "6"]
        for (name, num) in dayNames {
            processed = processed.replacingOccurrences(of: name, with: num)
        }

        guard var result = parseField(processed, min: 0, max: 7) else { return nil }
        // Normalize: 7 → 0 (both mean Sunday)
        if result.contains(7) {
            result.remove(7)
            result.insert(0)
        }
        return result
    }

    // MARK: - Helpers

    private func advanceToNextMonth(from date: Date, months: Set<Int>, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month], from: date)
        for _ in 0..<24 { // Max 2 years forward
            comps.month = (comps.month ?? 1) + 1
            if (comps.month ?? 1) > 12 {
                comps.month = 1
                comps.year = (comps.year ?? 2026) + 1
            }
            if months.contains(comps.month ?? 1) {
                comps.day = 1
                comps.hour = 0
                comps.minute = 0
                return calendar.date(from: comps)
            }
        }
        return nil
    }
}

// MARK: - Cron Scheduler Actor

/// Manages scheduled cron tasks: persistence, scheduling loop, execution, and result storage.
/// Integrates with the existing TaskQueue/ProactiveAgent pipeline for execution
/// and ConversationStore for result persistence.
actor CronScheduler {
    static let shared = CronScheduler()

    private var tasks: [String: CronTask] = [:]
    private var schedulerTask: Task<Void, Never>?
    private var runningTasks: Set<String> = []  // IDs currently executing
    private let storePath: String

    init() {
        storePath = PlatformPaths.cronTasksFile
    }

    // MARK: - Initialization

    func initialize() {
        loadTasks()
        recalculateAllNextRuns()
        startSchedulerLoop()
        TorboLog.info("Initialized: \(tasks.count) cron task(s) (\(tasks.values.filter { $0.enabled }.count) enabled)", subsystem: "Cron")
    }

    func shutdown() {
        schedulerTask?.cancel()
        schedulerTask = nil
        saveTasks()
        TorboLog.info("Scheduler stopped", subsystem: "Cron")
    }

    // MARK: - CRUD

    func createTask(name: String, cronExpression: String, agentID: String, prompt: String) -> CronTask? {
        // Validate cron expression
        guard CronExpression.parse(cronExpression) != nil else {
            TorboLog.error("Invalid cron expression: '\(cronExpression)'", subsystem: "Cron")
            return nil
        }

        let now = Date()
        let nextRun = CronExpression.parse(cronExpression)?.nextRunAfter(now)

        let task = CronTask(
            id: generateID(),
            name: name,
            cronExpression: cronExpression,
            agentID: agentID,
            prompt: prompt,
            enabled: true,
            lastRun: nil,
            nextRun: nextRun,
            lastResult: nil,
            lastError: nil,
            runCount: 0,
            createdAt: now,
            updatedAt: now
        )

        tasks[task.id] = task
        saveTasks()
        TorboLog.info("Created '\(name)' [\(cronExpression)] → \(agentID) (next: \(nextRun?.description ?? "none"))", subsystem: "Cron")
        return task
    }

    func updateTask(id: String, name: String?, cronExpression: String?, agentID: String?, prompt: String?, enabled: Bool?) -> CronTask? {
        guard var task = tasks[id] else { return nil }

        if let cron = cronExpression {
            guard CronExpression.parse(cron) != nil else {
                TorboLog.error("Invalid cron expression on update: '\(cron)'", subsystem: "Cron")
                return nil
            }
            task.cronExpression = cron
        }

        if let name = name { task.name = name }
        if let agent = agentID { task.agentID = agent }
        if let prompt = prompt { task.prompt = prompt }
        if let enabled = enabled { task.enabled = enabled }
        task.updatedAt = Date()

        // Recalculate next run
        if task.enabled, let parsed = CronExpression.parse(task.cronExpression) {
            task.nextRun = parsed.nextRunAfter(Date())
        } else if !task.enabled {
            task.nextRun = nil
        }

        tasks[id] = task
        saveTasks()
        TorboLog.info("Updated '\(task.name)' [\(task.cronExpression)]", subsystem: "Cron")
        return task
    }

    func deleteTask(id: String) -> Bool {
        guard tasks.removeValue(forKey: id) != nil else { return false }
        saveTasks()
        TorboLog.info("Deleted cron task \(id)", subsystem: "Cron")
        return true
    }

    func getTask(id: String) -> CronTask? {
        tasks[id]
    }

    func listTasks() -> [CronTask] {
        Array(tasks.values).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Immediate Execution

    /// Run a task immediately, bypassing the cron schedule.
    func runNow(id: String) async -> (success: Bool, message: String) {
        guard let task = tasks[id] else {
            return (false, "Task not found")
        }
        guard !runningTasks.contains(id) else {
            return (false, "Task is already running")
        }

        TorboLog.info("Manual run: '\(task.name)'", subsystem: "Cron")
        await executeTask(id)
        return (true, "Task '\(task.name)' executed")
    }

    // MARK: - Scheduler Loop

    private func startSchedulerLoop() {
        schedulerTask?.cancel()
        schedulerTask = Task {
            TorboLog.info("Scheduler loop started — checking every 60s", subsystem: "Cron")
            while !Task.isCancelled {
                await checkAndRunDueTasks()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func checkAndRunDueTasks() async {
        let now = Date()

        for (id, task) in tasks {
            guard task.enabled,
                  let nextRun = task.nextRun,
                  nextRun <= now,
                  !runningTasks.contains(id) else { continue }

            TorboLog.info("Due: '\(task.name)' — executing", subsystem: "Cron")
            await executeTask(id)
        }
    }

    // MARK: - Task Execution

    private func executeTask(_ id: String) async {
        guard var task = tasks[id] else { return }

        runningTasks.insert(id)
        let startTime = Date()

        // Mark as running
        task.lastRun = startTime
        task.runCount += 1
        task.lastError = nil
        tasks[id] = task

        // Create a TaskQueue task for the ProactiveAgent pipeline to execute
        let queueTask = await TaskQueue.shared.createTask(
            title: "Cron: \(task.name)",
            description: """
            Scheduled task '\(task.name)' triggered by cron expression: \(task.cronExpression)

            \(task.prompt)
            """,
            assignedTo: task.agentID,
            assignedBy: "cron/\(id)",
            priority: .normal
        )

        // Wait for the task to complete (poll with timeout)
        let timeoutSeconds = 600  // 10 minute max
        let pollInterval: UInt64 = 5 * 1_000_000_000  // 5 seconds
        let deadline = startTime.addingTimeInterval(TimeInterval(timeoutSeconds))

        var finalResult: String?
        var finalError: String?

        while Date() < deadline {
            if let completed = await TaskQueue.shared.taskByID(queueTask.id) {
                switch completed.status {
                case .completed:
                    finalResult = completed.result
                    break
                case .failed:
                    finalError = completed.error ?? "Unknown error"
                    break
                case .cancelled:
                    finalError = "Task was cancelled"
                    break
                case .pending, .inProgress:
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
                break
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        if finalResult == nil && finalError == nil {
            finalError = "Task timed out after \(timeoutSeconds)s"
        }

        // Update task with results
        task.lastResult = finalResult
        task.lastError = finalError
        task.updatedAt = Date()

        // Calculate next run
        if let parsed = CronExpression.parse(task.cronExpression) {
            task.nextRun = parsed.nextRunAfter(Date())
        }

        tasks[id] = task
        runningTasks.remove(id)
        saveTasks()

        let elapsed = Int(Date().timeIntervalSince(startTime))

        if let error = finalError {
            TorboLog.error("'\(task.name)' failed in \(elapsed)s: \(error)", subsystem: "Cron")
        } else {
            TorboLog.info("'\(task.name)' completed in \(elapsed)s", subsystem: "Cron")
        }

        // Store result as a conversation message for the iOS client to pick up
        let resultContent = finalResult ?? finalError ?? "No result"
        let message = ConversationMessage(
            role: "assistant",
            content: "[Cron: \(task.name)] \(resultContent)",
            model: "cron-scheduler",
            clientIP: nil,
            agentID: task.agentID
        )
        await ConversationStore.shared.appendMessage(message)
    }

    // MARK: - Persistence

    private func saveTasks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Array(tasks.values))
            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        } catch {
            TorboLog.error("Failed to write cron tasks: \(error)", subsystem: "Cron")
        }
    }

    private func loadTasks() {
        let url = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([CronTask].self, from: data) else {
            TorboLog.error("Failed to decode cron tasks from disk", subsystem: "Cron")
            return
        }
        for task in loaded {
            tasks[task.id] = task
        }
        TorboLog.info("Loaded \(tasks.count) cron tasks from disk", subsystem: "Cron")
    }

    private func recalculateAllNextRuns() {
        let now = Date()
        for (id, var task) in tasks {
            if task.enabled, let parsed = CronExpression.parse(task.cronExpression) {
                task.nextRun = parsed.nextRunAfter(now)
                tasks[id] = task
            }
        }
    }

    // MARK: - Stats

    func stats() -> [String: Any] {
        let enabled = tasks.values.filter { $0.enabled }.count
        let totalRuns = tasks.values.reduce(0) { $0 + $1.runCount }
        let running = runningTasks.count
        let nextDue = tasks.values
            .filter { $0.enabled && $0.nextRun != nil }
            .min(by: { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) })

        var result: [String: Any] = [
            "total": tasks.count,
            "enabled": enabled,
            "running": running,
            "total_runs": totalRuns
        ]

        if let next = nextDue {
            let df = ISO8601DateFormatter()
            result["next_due"] = [
                "name": next.name,
                "next_run": next.nextRun.map { df.string(from: $0) } ?? ""
            ]
        }

        return result
    }

    // MARK: - Helpers

    private func generateID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "cron_" + String((0..<8).map { _ in chars.randomElement()! })
    }
}
