// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Evening Wind-Down Scheduler
// Orchestrates the nightly wind-down: assembles the day review, writes the briefing,
// delivers to iOS, and queues tomorrow prep if needed.
// Default trigger: 9:00 PM local time, user-configurable.

import Foundation

// MARK: - Wind-Down Configuration

struct WindDownConfig: Codable {
    var enabled: Bool
    var hour: Int                  // 0-23, default 21 (9 PM)
    var minute: Int                // 0-59, default 0
    var agentID: String            // Which agent writes the briefing
    var earlyMeetingThresholdHour: Int  // Meetings before this hour trigger overnight prep (default 10)

    static let `default` = WindDownConfig(
        enabled: true,
        hour: 21,
        minute: 0,
        agentID: "sid",
        earlyMeetingThresholdHour: 10
    )

    var cronExpression: String {
        "\(minute) \(hour) * * *"
    }

    func toDict() -> [String: Any] {
        [
            "enabled": enabled,
            "hour": hour,
            "minute": minute,
            "agent_id": agentID,
            "early_meeting_threshold_hour": earlyMeetingThresholdHour,
            "cron_expression": cronExpression,
            "display_time": String(format: "%d:%02d %@", hour > 12 ? hour - 12 : hour, minute, hour >= 12 ? "PM" : "AM")
        ]
    }
}

// MARK: - Wind-Down Scheduler

actor WindDownScheduler {
    static let shared = WindDownScheduler()

    private var config = WindDownConfig.default
    private var schedulerTask: Task<Void, Never>?
    private var lastRunDate: String?           // ISO date string to prevent double-runs
    private var cronTaskID: String?            // ID of the CronScheduler task

    private var configFilePath: String { PlatformPaths.dataDir + "/winddown_config.json" }

    // MARK: - Lifecycle

    func initialize() {
        loadConfig()

        if config.enabled {
            startSchedulerLoop()
            TorboLog.info("Evening wind-down scheduled at \(String(format: "%02d:%02d", config.hour, config.minute))", subsystem: "WindDown")
        } else {
            TorboLog.info("Evening wind-down is disabled", subsystem: "WindDown")
        }
    }

    func shutdown() {
        schedulerTask?.cancel()
        schedulerTask = nil
        TorboLog.info("Wind-down scheduler stopped", subsystem: "WindDown")
    }

    // MARK: - Configuration

    func getConfig() -> [String: Any] {
        config.toDict()
    }

    func updateConfig(from body: [String: Any]) {
        if let enabled = body["enabled"] as? Bool { config.enabled = enabled }
        if let hour = body["hour"] as? Int { config.hour = max(0, min(23, hour)) }
        if let minute = body["minute"] as? Int { config.minute = max(0, min(59, minute)) }
        if let agent = body["agent_id"] as? String, !agent.isEmpty { config.agentID = agent }
        if let threshold = body["early_meeting_threshold_hour"] as? Int {
            config.earlyMeetingThresholdHour = max(0, min(23, threshold))
        }

        persistConfig()

        // Restart the scheduler loop with new timing
        schedulerTask?.cancel()
        if config.enabled {
            startSchedulerLoop()
            TorboLog.info("Wind-down rescheduled to \(String(format: "%02d:%02d", config.hour, config.minute))", subsystem: "WindDown")
        } else {
            TorboLog.info("Wind-down disabled", subsystem: "WindDown")
        }
    }

    // MARK: - Manual Trigger

    /// Run the wind-down now, regardless of schedule.
    func runNow() async -> [String: Any] {
        TorboLog.info("Manual wind-down triggered", subsystem: "WindDown")
        let result = await executeWindDown()
        return result
    }

    // MARK: - Scheduler Loop

    private func startSchedulerLoop() {
        schedulerTask?.cancel()
        schedulerTask = Task {
            TorboLog.debug("Wind-down scheduler loop started", subsystem: "WindDown")
            while !Task.isCancelled {
                let now = Date()
                let calendar = Calendar.current
                let currentHour = calendar.component(.hour, from: now)
                let currentMinute = calendar.component(.minute, from: now)

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let todayString = dateFormatter.string(from: now)

                // Check if it's time to run and we haven't already run today
                if currentHour == config.hour &&
                   currentMinute == config.minute &&
                   lastRunDate != todayString {
                    lastRunDate = todayString
                    TorboLog.info("Wind-down triggered for \(todayString)", subsystem: "WindDown")
                    let _ = await executeWindDown()
                }

                // Sleep for 30 seconds — check twice per minute
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    // MARK: - Core Execution

    private func executeWindDown() async -> [String: Any] {
        let startTime = Date()

        // 1. Assemble the day review
        let review = await DayReviewAssembler.shared.assemble()

        // 2. Write the briefing via agent
        let briefing = await WindDownWriter.shared.compose(review: review)

        // 3. Check if tomorrow needs prep
        let tomorrowPrepQueued = await TomorrowPrep.shared.prepareIfNeeded(review: review)

        // 4. Deliver: store locally + push to iOS
        await WindDownDelivery.shared.deliver(
            briefing: briefing,
            review: review,
            tomorrowPrepQueued: tomorrowPrepQueued
        )

        let elapsed = Int(Date().timeIntervalSince(startTime))
        TorboLog.info("Wind-down complete in \(elapsed)s (prep queued: \(tomorrowPrepQueued))", subsystem: "WindDown")

        return [
            "status": "completed",
            "date": review.date,
            "briefing": briefing,
            "tomorrow_prep_queued": tomorrowPrepQueued,
            "earliest_meeting": review.earliestMeetingTomorrow?.title as Any,
            "stats": [
                "events_today": review.calendarToday.count,
                "events_tomorrow": review.calendarTomorrow.count,
                "emails_received": review.emailsReceived,
                "emails_sent": review.emailsSent,
                "tasks_completed": review.tasksCompleted.count,
                "tasks_pending": review.tasksPending.count,
                "elapsed_seconds": elapsed
            ] as [String: Any]
        ]
    }

    // MARK: - Stats

    func stats() -> [String: Any] {
        var result = config.toDict()
        result["last_run_date"] = lastRunDate ?? "never"
        return result
    }

    // MARK: - Persistence

    private func persistConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath), options: .atomic)
        } catch {
            TorboLog.error("Failed to persist wind-down config: \(error)", subsystem: "WindDown")
        }
    }

    private func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configFilePath) else { return }
        do {
            config = try JSONDecoder().decode(WindDownConfig.self, from: data)
            TorboLog.info("Loaded wind-down config from disk", subsystem: "WindDown")
        } catch {
            TorboLog.warn("Failed to load wind-down config, using defaults: \(error)", subsystem: "WindDown")
        }
    }
}
