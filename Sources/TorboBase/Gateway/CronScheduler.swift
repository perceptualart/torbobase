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
    var cronExpression: String           // Standard 5-field: minute hour day month weekday (or @keyword)
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
    var timezone: String?                // nil = system timezone
    var catchUp: Bool?                   // nil = true — run missed executions on startup
    var executionHistory: [ScheduleExecution]?  // Last 50 executions
    var category: String?                // Schedule category for grouping
    var tags: [String]?                  // Freeform tags
    var maxRetries: Int?                 // Max retries on failure (nil = 0)
    var retryCount: Int?                 // Current consecutive failure count
    var pausedUntil: Date?              // If set, schedule is paused until this time
    var isDefault: Bool?                 // true = installed from template, not user-created

    /// Resolved cron expression (keywords expanded to 5-field format).
    var resolvedExpression: String {
        CronParser.resolveKeyword(cronExpression)
    }

    /// Whether missed executions should be caught up (defaults to true).
    var effectiveCatchUp: Bool { catchUp ?? true }

    /// Execution log (never nil for callers).
    var executionLog: [ScheduleExecution] { executionHistory ?? [] }

    /// Human-readable schedule description.
    var scheduleDescription: String {
        CronParser.describe(cronExpression)
    }

    /// Whether the schedule is currently paused.
    var isPaused: Bool {
        if let until = pausedUntil { return until > Date() }
        return false
    }

    /// Effective max retries (default 0).
    var effectiveMaxRetries: Int { maxRetries ?? 0 }

    /// Success rate as a percentage (0-100). Returns nil if no history.
    var successRate: Int? {
        let log = executionLog
        guard !log.isEmpty else { return nil }
        return Int(Double(log.filter(\.success).count) / Double(log.count) * 100)
    }

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
        case timezone
        case catchUp = "catch_up"
        case executionHistory = "execution_history"
        case category, tags
        case maxRetries = "max_retries"
        case retryCount = "retry_count"
        case pausedUntil = "paused_until"
        case isDefault = "is_default"
    }
}

// MARK: - Schedule Execution Record

struct ScheduleExecution: Codable {
    let timestamp: Date
    let success: Bool
    let duration: TimeInterval
    let result: String?
    let error: String?
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

    /// Parse a 5-field cron expression string (or @keyword shorthand).
    /// Returns nil if the expression is invalid.
    static func parse(_ expression: String) -> CronExpression? {
        let resolved = CronParser.resolveKeyword(expression)
        let fields = resolved.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
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

    func initialize() async {
        loadTasks()
        installDefaultSchedules()
        recalculateAllNextRuns()

        // Check for missed executions while server was down
        let missedCount = checkAllMissedExecutions()
        if missedCount > 0 {
            TorboLog.info("\(missedCount) schedule(s) have missed executions — recovering", subsystem: "Cron")
            await CronTaskIntegration.shared.recoverMissedExecutions()
        }

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

    func createTask(name: String, cronExpression: String, agentID: String, prompt: String,
                    timezone: String? = nil, catchUp: Bool? = nil, category: String? = nil,
                    tags: [String]? = nil, maxRetries: Int? = nil, isDefault: Bool? = nil) -> CronTask? {
        // Resolve keywords and validate
        let resolved = CronParser.resolveKeyword(cronExpression)
        guard CronExpression.parse(resolved) != nil else {
            TorboLog.error("Invalid cron expression: '\(cronExpression)'", subsystem: "Cron")
            return nil
        }

        let now = Date()
        let nextRun = CronExpression.parse(resolved)?.nextRunAfter(now)

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
            updatedAt: now,
            timezone: timezone,
            catchUp: catchUp,
            executionHistory: [],
            category: category,
            tags: tags,
            maxRetries: maxRetries,
            isDefault: isDefault
        )

        tasks[task.id] = task
        saveTasks()
        TorboLog.info("Created '\(name)' [\(cronExpression)] → \(agentID) (next: \(nextRun?.description ?? "none"))", subsystem: "Cron")
        return task
    }

    func updateTask(id: String, name: String? = nil, cronExpression: String? = nil,
                    agentID: String? = nil, prompt: String? = nil, enabled: Bool? = nil,
                    timezone: String?? = nil, catchUp: Bool?? = nil) -> CronTask? {
        guard var task = tasks[id] else { return nil }

        if let cron = cronExpression {
            let resolved = CronParser.resolveKeyword(cron)
            guard CronExpression.parse(resolved) != nil else {
                TorboLog.error("Invalid cron expression on update: '\(cron)'", subsystem: "Cron")
                return nil
            }
            task.cronExpression = cron
        }

        if let name = name { task.name = name }
        if let agent = agentID { task.agentID = agent }
        if let prompt = prompt { task.prompt = prompt }
        if let enabled = enabled { task.enabled = enabled }
        if let tz = timezone { task.timezone = tz }
        if let cu = catchUp { task.catchUp = cu }
        task.updatedAt = Date()

        // Recalculate next run
        let resolved = task.resolvedExpression
        if task.enabled, let parsed = CronExpression.parse(resolved) {
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

        for (id, var task) in tasks {
            guard task.enabled,
                  let nextRun = task.nextRun,
                  nextRun <= now,
                  !runningTasks.contains(id) else { continue }

            // Check if paused
            if task.isPaused {
                continue
            }

            // Auto-resume if pause expired
            if task.pausedUntil != nil && !task.isPaused {
                task.pausedUntil = nil
                tasks[id] = task
                saveTasks()
            }

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

        // Execute through the integration layer (TaskQueue → ProactiveAgent)
        let result = await CronTaskIntegration.shared.executeScheduledTask(task)

        let duration = result.duration

        // Record execution in history
        recordExecution(scheduleID: id, success: result.success, duration: duration,
                        result: result.result, error: result.error)

        // Update task with latest results
        if var updated = tasks[id] {
            updated.lastResult = result.result
            updated.lastError = result.error
            updated.updatedAt = Date()

            // Handle retry logic on failure
            if !result.success && updated.effectiveMaxRetries > 0 {
                let currentRetries = updated.retryCount ?? 0
                if currentRetries < updated.effectiveMaxRetries {
                    updated.retryCount = currentRetries + 1
                    // Schedule retry in 5 minutes instead of normal next-run
                    updated.nextRun = Date().addingTimeInterval(300)
                    TorboLog.info("'\(updated.name)' retry \(currentRetries + 1)/\(updated.effectiveMaxRetries) in 5m", subsystem: "Cron")
                } else {
                    // Max retries exhausted — reset and use normal schedule
                    updated.retryCount = 0
                    let resolved = updated.resolvedExpression
                    if let parsed = CronExpression.parse(resolved) {
                        updated.nextRun = parsed.nextRunAfter(Date())
                    }
                    TorboLog.warn("'\(updated.name)' exhausted \(updated.effectiveMaxRetries) retries", subsystem: "Cron")
                }
            } else {
                // Success or no retries configured — reset retry count
                updated.retryCount = 0
                let resolved = updated.resolvedExpression
                if let parsed = CronExpression.parse(resolved) {
                    updated.nextRun = parsed.nextRunAfter(Date())
                }
            }

            tasks[id] = updated
        }

        runningTasks.remove(id)
        saveTasks()

        let elapsed = Int(duration)

        if let error = result.error {
            TorboLog.error("'\(task.name)' failed in \(elapsed)s: \(error)", subsystem: "Cron")
            Task {
                await EventBus.shared.publish("system.cron.error",
                    payload: ["task_id": id, "task_name": task.name, "error": error, "elapsed": "\(elapsed)"],
                    source: "CronScheduler")
            }
        } else {
            TorboLog.info("'\(task.name)' completed in \(elapsed)s", subsystem: "Cron")
            Task {
                await EventBus.shared.publish("system.cron.fired",
                    payload: ["task_id": id, "task_name": task.name, "elapsed": "\(elapsed)"],
                    source: "CronScheduler")
            }
        }

        // Store result as a conversation message for the iOS client to pick up
        let resultContent = result.result ?? result.error ?? "No result"
        let message = ConversationMessage(
            role: "assistant",
            content: "[Cron: \(task.name)] \(resultContent)",
            model: "cron-scheduler",
            clientIP: nil,
            agentID: task.agentID
        )
        await ConversationStore.shared.appendMessage(message)
    }

    // MARK: - Execution History

    /// Record a completed execution in the schedule's history (keeps last 50).
    func recordExecution(scheduleID: String, success: Bool, duration: TimeInterval,
                         result: String?, error: String?) {
        guard var task = tasks[scheduleID] else { return }

        let execution = ScheduleExecution(
            timestamp: Date(),
            success: success,
            duration: duration,
            result: result.map { String($0.prefix(500)) },  // Truncate long results
            error: error
        )

        var history = task.executionHistory ?? []
        history.append(execution)

        // Keep last 50
        if history.count > 50 {
            history = Array(history.suffix(50))
        }

        task.executionHistory = history
        tasks[scheduleID] = task
        saveTasks()
    }

    /// Get execution history for a schedule.
    func getExecutionHistory(scheduleID: String, limit: Int = 50) -> [ScheduleExecution] {
        guard let task = tasks[scheduleID] else { return [] }
        let history = task.executionLog
        if limit >= history.count { return history }
        return Array(history.suffix(limit))
    }

    // MARK: - Missed Execution Detection

    /// Check a single schedule for missed executions since its last run.
    /// Returns dates that should have executed but didn't.
    func getMissedExecutions(scheduleID: String) -> [Date] {
        guard let task = tasks[scheduleID], task.enabled else { return [] }

        let resolved = task.resolvedExpression
        guard let parsed = CronExpression.parse(resolved) else { return [] }

        // If never run, check from creation time
        let since = task.lastRun ?? task.createdAt
        let now = Date()

        // Don't look back more than 24 hours to avoid flooding
        let lookback = max(since, now.addingTimeInterval(-86400))

        var missed: [Date] = []
        var cursor = lookback
        while let next = parsed.nextRunAfter(cursor), next < now {
            missed.append(next)
            cursor = next
            if missed.count >= 100 { break }  // Safety cap
        }

        return missed
    }

    /// Check all schedules for missed executions. Returns count of schedules with misses.
    private func checkAllMissedExecutions() -> Int {
        var count = 0
        for (_, task) in tasks where task.enabled {
            let resolved = task.resolvedExpression
            guard let parsed = CronExpression.parse(resolved) else { continue }

            let since = task.lastRun ?? task.createdAt
            let now = Date()
            let lookback = max(since, now.addingTimeInterval(-86400))

            if let next = parsed.nextRunAfter(lookback), next < now {
                count += 1
            }
        }
        return count
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

    // MARK: - Default Schedule Installation

    /// Install default schedules from templates on first run.
    /// Only installs if no schedules exist yet. All defaults are created disabled
    /// so the user can review and enable the ones they want.
    func installDefaultSchedules() {
        guard tasks.isEmpty else {
            TorboLog.info("Schedules already exist — skipping default installation", subsystem: "Cron")
            return
        }

        let defaults: [(template: CronTemplate, category: String)] = [
            (CronTemplates.morningBriefing, "daily"),
            (CronTemplates.eveningWindDown, "daily"),
            (CronTemplates.hourlyPriceCheck, "monitoring"),
            (CronTemplates.weeklyReport, "reporting"),
            (CronTemplates.backupReminder, "maintenance"),
        ]

        for (tpl, cat) in defaults {
            let resolved = CronParser.resolveKeyword(tpl.cronExpression)
            let now = Date()
            let nextRun = CronExpression.parse(resolved)?.nextRunAfter(now)

            let task = CronTask(
                id: generateID(),
                name: tpl.name,
                cronExpression: tpl.cronExpression,
                agentID: tpl.agentID,
                prompt: tpl.prompt,
                enabled: false,  // Disabled by default — user opts in
                lastRun: nil,
                nextRun: nextRun,
                lastResult: nil,
                lastError: nil,
                runCount: 0,
                createdAt: now,
                updatedAt: now,
                category: cat,
                isDefault: true
            )
            tasks[task.id] = task
        }

        saveTasks()
        TorboLog.info("Installed \(defaults.count) default schedule(s) (all disabled — enable in dashboard)", subsystem: "Cron")
    }

    // MARK: - Clone

    /// Clone an existing schedule with a new name.
    func cloneSchedule(id: String, newName: String? = nil) -> CronTask? {
        guard let original = tasks[id] else { return nil }
        let now = Date()
        let nextRun = CronExpression.parse(original.resolvedExpression)?.nextRunAfter(now)

        let clone = CronTask(
            id: generateID(),
            name: newName ?? "\(original.name) (Copy)",
            cronExpression: original.cronExpression,
            agentID: original.agentID,
            prompt: original.prompt,
            enabled: false,  // Clones start disabled
            lastRun: nil,
            nextRun: nextRun,
            lastResult: nil,
            lastError: nil,
            runCount: 0,
            createdAt: now,
            updatedAt: now,
            timezone: original.timezone,
            catchUp: original.catchUp,
            executionHistory: nil,
            category: original.category,
            tags: original.tags,
            maxRetries: original.maxRetries
        )

        tasks[clone.id] = clone
        saveTasks()
        TorboLog.info("Cloned '\(original.name)' → '\(clone.name)'", subsystem: "Cron")
        return clone
    }

    // MARK: - Pause / Resume

    /// Pause a schedule until a specific time (or indefinitely if nil).
    func pauseSchedule(id: String, until: Date? = nil) -> CronTask? {
        guard var task = tasks[id] else { return nil }
        task.pausedUntil = until ?? Date.distantFuture
        task.updatedAt = Date()
        tasks[id] = task
        saveTasks()
        if let until = until {
            TorboLog.info("Paused '\(task.name)' until \(until)", subsystem: "Cron")
        } else {
            TorboLog.info("Paused '\(task.name)' indefinitely", subsystem: "Cron")
        }
        return task
    }

    /// Resume a paused schedule.
    func resumeSchedule(id: String) -> CronTask? {
        guard var task = tasks[id] else { return nil }
        task.pausedUntil = nil
        task.updatedAt = Date()

        // Recalculate next run
        if task.enabled, let parsed = CronExpression.parse(task.resolvedExpression) {
            task.nextRun = parsed.nextRunAfter(Date())
        }

        tasks[id] = task
        saveTasks()
        TorboLog.info("Resumed '\(task.name)'", subsystem: "Cron")
        return task
    }

    // MARK: - History Management

    /// Clear execution history for a schedule.
    func clearHistory(scheduleID: String) -> Bool {
        guard var task = tasks[scheduleID] else { return false }
        task.executionHistory = []
        tasks[scheduleID] = task
        saveTasks()
        TorboLog.info("Cleared history for '\(task.name)'", subsystem: "Cron")
        return true
    }

    // MARK: - Export / Import

    /// Export all schedules as JSON data.
    func exportSchedules() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(Array(tasks.values))
    }

    /// Import schedules from JSON data. Returns count of imported schedules.
    func importSchedules(data: Data, replaceExisting: Bool = false) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let imported = try? decoder.decode([CronTask].self, from: data) else {
            TorboLog.error("Failed to decode import data", subsystem: "Cron")
            return 0
        }

        if replaceExisting {
            tasks.removeAll()
        }

        var count = 0
        let now = Date()
        for var task in imported {
            // Assign new IDs to avoid collisions
            let newID = generateID()
            task = CronTask(
                id: newID,
                name: task.name,
                cronExpression: task.cronExpression,
                agentID: task.agentID,
                prompt: task.prompt,
                enabled: task.enabled,
                lastRun: nil,
                nextRun: CronExpression.parse(task.resolvedExpression)?.nextRunAfter(now),
                lastResult: nil,
                lastError: nil,
                runCount: 0,
                createdAt: now,
                updatedAt: now,
                timezone: task.timezone,
                catchUp: task.catchUp,
                executionHistory: nil,
                category: task.category,
                tags: task.tags,
                maxRetries: task.maxRetries
            )
            tasks[newID] = task
            count += 1
        }

        saveTasks()
        TorboLog.info("Imported \(count) schedule(s)", subsystem: "Cron")
        return count
    }

    // MARK: - Category Queries

    /// Get all unique categories.
    func categories() -> [String] {
        Array(Set(tasks.values.compactMap(\.category))).sorted()
    }

    /// Get schedules grouped by category.
    func schedulesGroupedByCategory() -> [(category: String, schedules: [CronTask])] {
        var groups: [String: [CronTask]] = [:]
        for task in tasks.values {
            let cat = task.category ?? "uncategorized"
            groups[cat, default: []].append(task)
        }
        return groups.map { (category: $0.key, schedules: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }

    // MARK: - Bulk Operations

    /// Enable all schedules.
    func enableAll() {
        for (id, var task) in tasks {
            task.enabled = true
            if let parsed = CronExpression.parse(task.resolvedExpression) {
                task.nextRun = parsed.nextRunAfter(Date())
            }
            task.updatedAt = Date()
            tasks[id] = task
        }
        saveTasks()
        TorboLog.info("Enabled all \(tasks.count) schedule(s)", subsystem: "Cron")
    }

    /// Disable all schedules.
    func disableAll() {
        for (id, var task) in tasks {
            task.enabled = false
            task.nextRun = nil
            task.updatedAt = Date()
            tasks[id] = task
        }
        saveTasks()
        TorboLog.info("Disabled all \(tasks.count) schedule(s)", subsystem: "Cron")
    }

    /// Delete all schedules.
    func deleteAll() -> Int {
        let count = tasks.count
        tasks.removeAll()
        saveTasks()
        TorboLog.info("Deleted all \(count) schedule(s)", subsystem: "Cron")
        return count
    }

    // MARK: - Stats

    func stats() -> [String: Any] {
        let enabled = tasks.values.filter { $0.enabled }.count
        let totalRuns = tasks.values.reduce(0) { $0 + $1.runCount }
        let running = runningTasks.count
        let nextDue = tasks.values
            .filter { $0.enabled && $0.nextRun != nil }
            .min(by: { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) })

        // Aggregate execution history stats
        let allHistory = tasks.values.flatMap(\.executionLog)
        let successCount = allHistory.filter(\.success).count
        let failCount = allHistory.count - successCount
        let avgDuration = allHistory.isEmpty ? 0 : allHistory.map(\.duration).reduce(0, +) / Double(allHistory.count)

        var result: [String: Any] = [
            "total": tasks.count,
            "enabled": enabled,
            "running": running,
            "total_runs": totalRuns,
            "history_entries": allHistory.count,
            "success_count": successCount,
            "failure_count": failCount,
            "avg_duration_seconds": Int(avgDuration)
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

    // MARK: - Next Runs Preview

    /// Preview the next N run times for a schedule.
    func nextRuns(scheduleID: String, count: Int = 5) -> [Date] {
        guard let task = tasks[scheduleID], task.enabled else { return [] }
        return CronParser.nextRuns(task.cronExpression, count: count)
    }

    /// Preview the next N run times for an arbitrary expression.
    func nextRunsForExpression(_ expression: String, count: Int = 5) -> [Date] {
        CronParser.nextRuns(expression, count: count)
    }

    // MARK: - Helpers

    private func generateID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "cron_" + String((0..<8).map { _ in chars.randomElement()! })
    }
}
