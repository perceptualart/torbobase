// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Task Integration
// Bridges CronScheduler with TaskQueue and ProactiveAgent.
// Handles task creation, result recording, and notification dispatch.

import Foundation

// MARK: - Cron Task Integration

actor CronTaskIntegration {
    static let shared = CronTaskIntegration()

    // MARK: - Execute Scheduled Task

    /// Execute a cron task through the TaskQueue/ProactiveAgent pipeline.
    /// Returns the result string on success, or throws on failure.
    func executeScheduledTask(_ cronTask: CronTask) async -> (success: Bool, result: String?, error: String?, duration: TimeInterval) {
        let startTime = Date()

        // Create a TaskQueue task for the ProactiveAgent to pick up
        let queueTask = await TaskQueue.shared.createTask(
            title: "Cron: \(cronTask.name)",
            description: """
            Scheduled task '\(cronTask.name)' triggered by cron expression: \(cronTask.cronExpression)

            \(cronTask.prompt)
            """,
            assignedTo: cronTask.agentID,
            assignedBy: "cron/\(cronTask.id)",
            priority: .normal
        )

        TorboLog.info("Queued '\(cronTask.name)' as task \(queueTask.id.prefix(8))", subsystem: "CronInteg")

        // Poll for completion with timeout
        let timeoutSeconds = 600  // 10 minute max
        let pollInterval: UInt64 = 5 * 1_000_000_000
        let deadline = startTime.addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            if let completed = await TaskQueue.shared.taskByID(queueTask.id) {
                switch completed.status {
                case .completed:
                    let duration = Date().timeIntervalSince(startTime)
                    return (true, completed.result, nil, duration)
                case .failed:
                    let duration = Date().timeIntervalSince(startTime)
                    return (false, nil, completed.error ?? "Unknown error", duration)
                case .cancelled:
                    let duration = Date().timeIntervalSince(startTime)
                    return (false, nil, "Task was cancelled", duration)
                case .pending, .inProgress:
                    try? await Task.sleep(nanoseconds: pollInterval)
                    continue
                }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (false, nil, "Task timed out after \(timeoutSeconds)s", duration)
    }

    // MARK: - Record Execution Result

    /// Record a cron execution result and publish events.
    func recordResult(cronTaskID: String, success: Bool, result: String?, error: String?,
                      duration: TimeInterval) async {
        // Record in scheduler's execution history
        await CronScheduler.shared.recordExecution(
            scheduleID: cronTaskID,
            success: success,
            duration: duration,
            result: result,
            error: error
        )

        let elapsed = Int(duration)

        // Publish event
        if success {
            let taskName = await CronScheduler.shared.getTask(id: cronTaskID)?.name ?? cronTaskID
            await EventBus.shared.publish("system.cron.fired",
                payload: ["task_id": cronTaskID, "task_name": taskName, "elapsed": "\(elapsed)"],
                source: "CronTaskIntegration")
        } else {
            let taskName = await CronScheduler.shared.getTask(id: cronTaskID)?.name ?? cronTaskID
            await EventBus.shared.publish("system.cron.error",
                payload: ["task_id": cronTaskID, "task_name": taskName,
                          "error": error ?? "Unknown", "elapsed": "\(elapsed)"],
                source: "CronTaskIntegration")
        }

        // Store as conversation message for iOS client
        let taskName = await CronScheduler.shared.getTask(id: cronTaskID)?.name ?? "Unknown"
        let agentID = await CronScheduler.shared.getTask(id: cronTaskID)?.agentID ?? "sid"
        let content: String
        if success {
            content = "[Cron: \(taskName)] \(result ?? "Completed")"
        } else {
            content = "[Cron: \(taskName)] Error: \(error ?? "Unknown error")"
        }

        let message = ConversationMessage(
            role: "assistant",
            content: content,
            model: "cron-scheduler",
            clientIP: nil,
            agentID: agentID
        )
        await ConversationStore.shared.appendMessage(message)
    }

    // MARK: - Missed Execution Recovery

    /// Check all schedules for missed executions and optionally catch up.
    func recoverMissedExecutions() async {
        let tasks = await CronScheduler.shared.listTasks()
        var recovered = 0

        for task in tasks where task.enabled {
            let missed = await CronScheduler.shared.getMissedExecutions(scheduleID: task.id)
            guard !missed.isEmpty else { continue }

            let catchUp = task.catchUp ?? true
            if catchUp {
                TorboLog.info("'\(task.name)' has \(missed.count) missed execution(s) — catching up", subsystem: "CronInteg")
                // Run once to catch up (not all missed — just run the task now)
                let result = await executeScheduledTask(task)
                await recordResult(cronTaskID: task.id, success: result.success,
                                   result: result.result, error: result.error,
                                   duration: result.duration)
                recovered += 1
            } else {
                TorboLog.info("'\(task.name)' has \(missed.count) missed execution(s) — skipped (catchUp=false)", subsystem: "CronInteg")
            }
        }

        if recovered > 0 {
            TorboLog.info("Recovered \(recovered) missed scheduled task(s)", subsystem: "CronInteg")
        }
    }

    // MARK: - Create From Template

    /// Create a new cron task from a template.
    func createFromTemplate(_ template: CronTemplate, agentID: String? = nil) async -> CronTask? {
        await CronScheduler.shared.createTask(
            name: template.name,
            cronExpression: template.cronExpression,
            agentID: agentID ?? template.agentID,
            prompt: template.prompt
        )
    }

    // MARK: - Bulk Operations

    /// Enable or disable all schedules.
    func setAllEnabled(_ enabled: Bool) async {
        let tasks = await CronScheduler.shared.listTasks()
        for task in tasks {
            _ = await CronScheduler.shared.updateTask(
                id: task.id, name: nil, cronExpression: nil,
                agentID: nil, prompt: nil, enabled: enabled
            )
        }
        TorboLog.info("Set all \(tasks.count) schedule(s) to enabled=\(enabled)", subsystem: "CronInteg")
    }
}
