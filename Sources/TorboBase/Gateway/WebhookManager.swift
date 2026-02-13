// Torbo Base — Webhook & Event Trigger System
// WebhookManager.swift — Receive webhooks, trigger tasks, schedule cron-style events
// Enables: GitHub push → SiD reviews code, email received → Mira drafts reply, etc.

import Foundation

// MARK: - Webhook Definition

struct WebhookDefinition: Codable, Identifiable {
    let id: String
    let name: String                        // Human-readable name
    let description: String                 // What this webhook does
    let assignedTo: String                  // Crew member to handle events
    let action: WebhookAction               // What to do when triggered
    var enabled: Bool
    var secret: String?                     // Shared secret for HMAC verification
    let createdAt: Date
    var lastTriggeredAt: Date?
    var triggerCount: Int

    enum WebhookAction: Codable {
        case createTask(priority: Int)      // Create a task in TaskQueue
        case createWorkflow(template: String) // Create a workflow from template
        case notify                          // Just log the event (no task)
    }

    /// The URL path for this webhook: /v1/webhooks/{id}
    var path: String { "/v1/webhooks/\(id)" }
}

// MARK: - Scheduled Event (Cron-style)

struct ScheduledEvent: Codable, Identifiable {
    let id: String
    let name: String
    let description: String                 // What the agent should do
    let assignedTo: String                  // Crew member
    let schedule: Schedule
    var enabled: Bool
    let createdAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?
    var runCount: Int

    enum Schedule: Codable {
        case interval(seconds: Int)          // Every N seconds
        case daily(hour: Int, minute: Int)   // Every day at HH:MM
        case weekdays(hour: Int, minute: Int) // Mon-Fri at HH:MM
        case weekly(dayOfWeek: Int, hour: Int, minute: Int) // Specific day of week
    }
}

// MARK: - Webhook Manager

actor WebhookManager {
    static let shared = WebhookManager()

    private var webhooks: [String: WebhookDefinition] = [:]
    private var scheduledEvents: [String: ScheduledEvent] = [:]
    private var schedulerTask: Task<Void, Never>?
    private let storePath = NSHomeDirectory() + "/Library/Application Support/TorboBase/webhooks.json"
    private let schedulePath = NSHomeDirectory() + "/Library/Application Support/TorboBase/schedules.json"

    // MARK: - Initialization

    func initialize() {
        loadWebhooks()
        loadSchedules()
        startScheduler()
        print("[Webhooks] Initialized: \(webhooks.count) webhook(s), \(scheduledEvents.count) schedule(s)")
    }

    // MARK: - Webhook CRUD

    func createWebhook(name: String, description: String, assignedTo: String,
                        action: WebhookDefinition.WebhookAction = .createTask(priority: 1),
                        secret: String? = nil) -> WebhookDefinition {
        let webhook = WebhookDefinition(
            id: UUID().uuidString.prefix(12).lowercased().replacingOccurrences(of: "-", with: ""),
            name: name,
            description: description,
            assignedTo: assignedTo,
            action: action,
            enabled: true,
            secret: secret,
            createdAt: Date(),
            lastTriggeredAt: nil,
            triggerCount: 0
        )
        webhooks[webhook.id] = webhook
        saveWebhooks()
        print("[Webhooks] Created '\(name)' → \(assignedTo) (ID: \(webhook.id))")
        return webhook
    }

    func deleteWebhook(_ id: String) -> Bool {
        guard webhooks.removeValue(forKey: id) != nil else { return false }
        saveWebhooks()
        print("[Webhooks] Deleted webhook \(id)")
        return true
    }

    func toggleWebhook(_ id: String, enabled: Bool) -> Bool {
        guard var webhook = webhooks[id] else { return false }
        webhook.enabled = enabled
        webhooks[id] = webhook
        saveWebhooks()
        return true
    }

    func listWebhooks() -> [WebhookDefinition] {
        Array(webhooks.values).sorted { $0.createdAt > $1.createdAt }
    }

    func getWebhook(_ id: String) -> WebhookDefinition? { webhooks[id] }

    // MARK: - Trigger Webhook

    /// Process an incoming webhook event
    func trigger(webhookID: String, payload: [String: Any], headers: [String: String] = [:]) async -> (success: Bool, message: String) {
        guard var webhook = webhooks[webhookID] else {
            return (false, "Webhook not found")
        }
        guard webhook.enabled else {
            return (false, "Webhook is disabled")
        }

        // Verify secret if configured
        if let secret = webhook.secret, !secret.isEmpty {
            let sig = headers["x-hub-signature-256"] ?? headers["x-webhook-signature"] ?? ""
            if sig.isEmpty {
                return (false, "Missing signature header")
            }
            // Basic secret check (in production, use HMAC-SHA256)
            if sig != secret && !sig.contains(secret) {
                print("[Webhooks] Signature mismatch for '\(webhook.name)'")
                return (false, "Invalid signature")
            }
        }

        // Update trigger stats
        webhook.lastTriggeredAt = Date()
        webhook.triggerCount += 1
        webhooks[webhookID] = webhook
        saveWebhooks()

        // Format payload for the agent
        let payloadStr: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            payloadStr = str
        } else {
            payloadStr = "\(payload)"
        }

        let taskDescription = """
        Webhook '\(webhook.name)' was triggered.
        Description: \(webhook.description)

        Payload:
        \(payloadStr.prefix(5000))
        """

        // Execute the action
        switch webhook.action {
        case .createTask(let priority):
            let prio = TaskQueue.TaskPriority(rawValue: priority) ?? .normal
            let task = await TaskQueue.shared.createTask(
                title: "Webhook: \(webhook.name)",
                description: taskDescription,
                assignedTo: webhook.assignedTo,
                assignedBy: "webhook/\(webhookID)",
                priority: prio
            )
            print("[Webhooks] '\(webhook.name)' triggered → task '\(task.id.prefix(8))' for \(webhook.assignedTo)")
            return (true, "Task created: \(task.id)")

        case .createWorkflow(let template):
            let workflow = await WorkflowEngine.shared.createWorkflow(
                description: "\(template)\n\nContext from webhook:\n\(payloadStr.prefix(2000))",
                createdBy: "webhook/\(webhookID)"
            )
            print("[Webhooks] '\(webhook.name)' triggered → workflow '\(workflow.id.prefix(8))'")
            return (true, "Workflow created: \(workflow.id)")

        case .notify:
            print("[Webhooks] '\(webhook.name)' triggered (notify only)")
            return (true, "Event logged")
        }
    }

    // MARK: - Scheduled Events CRUD

    func createSchedule(name: String, description: String, assignedTo: String,
                         schedule: ScheduledEvent.Schedule) -> ScheduledEvent {
        let event = ScheduledEvent(
            id: UUID().uuidString,
            name: name,
            description: description,
            assignedTo: assignedTo,
            schedule: schedule,
            enabled: true,
            createdAt: Date(),
            lastRunAt: nil,
            nextRunAt: calculateNextRun(schedule),
            runCount: 0
        )
        scheduledEvents[event.id] = event
        saveSchedules()
        print("[Scheduler] Created '\(name)' → \(assignedTo) (next run: \(event.nextRunAt?.description ?? "?"))")
        return event
    }

    func deleteSchedule(_ id: String) -> Bool {
        guard scheduledEvents.removeValue(forKey: id) != nil else { return false }
        saveSchedules()
        return true
    }

    func toggleSchedule(_ id: String, enabled: Bool) -> Bool {
        guard var event = scheduledEvents[id] else { return false }
        event.enabled = enabled
        if enabled { event.nextRunAt = calculateNextRun(event.schedule) }
        scheduledEvents[id] = event
        saveSchedules()
        return true
    }

    func listSchedules() -> [ScheduledEvent] {
        Array(scheduledEvents.values).sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }

    // MARK: - Scheduler Loop

    private func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task {
            print("[Scheduler] Started — checking every 30s")
            while !Task.isCancelled {
                await checkSchedules()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // Check every 30s
            }
        }
    }

    func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        print("[Scheduler] Stopped")
    }

    private func checkSchedules() async {
        let now = Date()

        for (id, var event) in scheduledEvents {
            guard event.enabled,
                  let nextRun = event.nextRunAt,
                  nextRun <= now else { continue }

            // Time to run this event
            print("[Scheduler] Running '\(event.name)' → \(event.assignedTo)")

            // Create a task for this scheduled event
            let _ = await TaskQueue.shared.createTask(
                title: "Scheduled: \(event.name)",
                description: event.description,
                assignedTo: event.assignedTo,
                assignedBy: "scheduler/\(id)",
                priority: .normal
            )

            // Update stats
            event.lastRunAt = now
            event.runCount += 1
            event.nextRunAt = calculateNextRun(event.schedule)
            scheduledEvents[id] = event
        }

        saveSchedules()
    }

    // MARK: - Schedule Calculation

    private func calculateNextRun(_ schedule: ScheduledEvent.Schedule) -> Date? {
        let now = Date()
        let calendar = Calendar.current

        switch schedule {
        case .interval(let seconds):
            return now.addingTimeInterval(TimeInterval(seconds))

        case .daily(let hour, let minute):
            var next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if next <= now {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
            return next

        case .weekdays(let hour, let minute):
            var next = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            if next <= now {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
            // Skip weekends
            while calendar.isDateInWeekend(next) {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
            return next

        case .weekly(let dayOfWeek, let hour, let minute):
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = dayOfWeek
            components.hour = hour
            components.minute = minute
            components.second = 0
            var next = calendar.date(from: components) ?? now
            if next <= now {
                next = calendar.date(byAdding: .weekOfYear, value: 1, to: next) ?? next
            }
            return next
        }
    }

    // MARK: - Persistence

    private func saveWebhooks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(webhooks.values)) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath))
    }

    private func loadWebhooks() {
        let url = URL(fileURLWithPath: storePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([WebhookDefinition].self, from: data) else { return }
        for wh in loaded { webhooks[wh.id] = wh }
    }

    private func saveSchedules() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(scheduledEvents.values)) else { return }
        try? data.write(to: URL(fileURLWithPath: schedulePath))
    }

    private func loadSchedules() {
        let url = URL(fileURLWithPath: schedulePath)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let loaded = try? decoder.decode([ScheduledEvent].self, from: data) else { return }
        for ev in loaded { scheduledEvents[ev.id] = ev }
    }

    // MARK: - Summary

    func stats() -> [String: Any] {
        let activeWebhooks = webhooks.values.filter { $0.enabled }.count
        let activeSchedules = scheduledEvents.values.filter { $0.enabled }.count
        let totalTriggers = webhooks.values.reduce(0) { $0 + $1.triggerCount }
        let totalRuns = scheduledEvents.values.reduce(0) { $0 + $1.runCount }

        return [
            "webhooks": ["total": webhooks.count, "active": activeWebhooks, "total_triggers": totalTriggers],
            "schedules": ["total": scheduledEvents.count, "active": activeSchedules, "total_runs": totalRuns]
        ]
    }
}
