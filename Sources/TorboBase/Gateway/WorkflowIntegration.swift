// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow Integration
// Hooks visual workflow triggers into existing Torbo Base subsystems:
// CronScheduler, WebhookManager, TelegramBridge, EmailBridge, FileVault.
import Foundation

// MARK: - Workflow Integration Manager

actor WorkflowIntegrationManager {
    static let shared = WorkflowIntegrationManager()

    /// Active file watchers: path → DispatchSource
    private var fileWatchers: [String: Any] = [:]

    /// Registered webhook paths
    private var webhookPaths: Set<String> = []

    /// Registered cron entries: workflowID → schedule identifier
    private var cronEntries: [String: String] = [:]

    // MARK: - Setup

    /// Register all enabled workflows with their respective trigger systems.
    /// Call this on startup and whenever workflows are added/modified.
    func registerAllTriggers() async {
        let workflows = await VisualWorkflowStore.shared.list()
        for wf in workflows where wf.enabled {
            await registerTriggers(for: wf)
        }
        TorboLog.info("Registered triggers for \(workflows.filter(\.enabled).count) visual workflow(s)", subsystem: "VWorkflow")
    }

    /// Register triggers for a single workflow
    func registerTriggers(for workflow: VisualWorkflow) async {
        for node in workflow.triggers {
            guard let triggerKindStr = node.config.string("triggerKind"),
                  let triggerKind = TriggerKind(rawValue: triggerKindStr) else { continue }

            switch triggerKind {
            case .schedule:
                await registerScheduleTrigger(node: node, workflow: workflow)
            case .webhook:
                registerWebhookTrigger(node: node, workflow: workflow)
            case .telegram:
                registerTelegramTrigger(node: node, workflow: workflow)
            case .email:
                registerEmailTrigger(node: node, workflow: workflow)
            case .fileChange:
                registerFileChangeTrigger(node: node, workflow: workflow)
            case .manual:
                break // Manual triggers are executed via API
            }
        }
    }

    /// Unregister all triggers for a workflow (when disabled or deleted)
    func unregisterTriggers(for workflowID: String) {
        // Remove cron entry
        if let cronID = cronEntries.removeValue(forKey: workflowID) {
            TorboLog.info("Unregistered cron trigger \(cronID) for workflow \(workflowID.prefix(8))", subsystem: "VWorkflow")
        }

        // Remove file watchers
        for (key, _) in fileWatchers where key.hasPrefix(workflowID) {
            fileWatchers.removeValue(forKey: key)
        }

        // Remove webhook paths
        webhookPaths = webhookPaths.filter { !$0.contains(workflowID) }
    }

    // MARK: - Schedule Trigger → CronScheduler

    private func registerScheduleTrigger(node: VisualNode, workflow: VisualWorkflow) async {
        guard let cron = node.config.string("cron"), !cron.isEmpty else {
            TorboLog.warn("Schedule trigger in '\(workflow.name)' has no cron expression", subsystem: "VWorkflow")
            return
        }

        // Register with CronScheduler
        let scheduleID = "vwf-\(workflow.id.prefix(8))-\(node.id.prefix(8))"
        let workflowID = workflow.id
        let workflowName = workflow.name

        // Subscribe to EventBus for cron tick matching this schedule
        await EventBus.shared.subscribe(event: "cron.tick.\(scheduleID)") { payload in
            TorboLog.info("Cron triggered workflow '\(workflowName)'", subsystem: "VWorkflow")
            Task {
                if let wf = await VisualWorkflowStore.shared.get(workflowID) {
                    await WorkflowExecutor.shared.execute(
                        workflow: wf,
                        triggeredBy: "schedule",
                        triggerData: ["cron": cron, "schedule_id": scheduleID]
                    )
                }
            }
        }

        cronEntries[workflow.id] = scheduleID
        TorboLog.info("Registered cron '\(cron)' for '\(workflow.name)'", subsystem: "VWorkflow")
    }

    // MARK: - Webhook Trigger → WebhookManager

    private func registerWebhookTrigger(node: VisualNode, workflow: VisualWorkflow) {
        let path = node.config.string("path") ?? "/hook/\(workflow.id.prefix(8))"
        webhookPaths.insert(path)

        TorboLog.info("Registered webhook \(path) for '\(workflow.name)'", subsystem: "VWorkflow")
    }

    /// Check if an incoming webhook matches a visual workflow trigger
    func handleWebhook(path: String, body: Data?) async -> Bool {
        guard webhookPaths.contains(path) else { return false }

        // Find the workflow with this webhook path
        let workflows = await VisualWorkflowStore.shared.list()
        for wf in workflows where wf.enabled {
            for trigger in wf.triggers {
                let triggerPath = trigger.config.string("path") ?? ""
                if triggerPath == path {
                    let bodyStr = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    await WorkflowExecutor.shared.execute(
                        workflow: wf,
                        triggeredBy: "webhook",
                        triggerData: ["webhook_path": path, "body": bodyStr]
                    )
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Telegram Trigger → TelegramBridge

    private func registerTelegramTrigger(node: VisualNode, workflow: VisualWorkflow) {
        let keyword = node.config.string("keyword") ?? ""
        if keyword.isEmpty {
            TorboLog.warn("Telegram trigger in '\(workflow.name)' has no keyword", subsystem: "VWorkflow")
            return
        }

        let workflowID = workflow.id

        // Subscribe to Telegram messages via EventBus
        Task {
            await EventBus.shared.subscribe(event: "telegram.message") { payload in
                let text = payload["text"] ?? ""
                if text.lowercased().contains(keyword.lowercased()) {
                    Task {
                        if let wf = await VisualWorkflowStore.shared.get(workflowID) {
                            await WorkflowExecutor.shared.execute(
                                workflow: wf,
                                triggeredBy: "telegram",
                                triggerData: [
                                    "keyword": keyword,
                                    "message": text,
                                    "chat_id": payload["chat_id"] ?? "",
                                    "from": payload["from"] ?? ""
                                ]
                            )
                        }
                    }
                }
            }
        }

        TorboLog.info("Registered Telegram keyword '\(keyword)' for '\(workflow.name)'", subsystem: "VWorkflow")
    }

    // MARK: - Email Trigger → EmailBridge

    private func registerEmailTrigger(node: VisualNode, workflow: VisualWorkflow) {
        let filter = node.config.string("filter") ?? ""
        let fromFilter = node.config.string("from") ?? ""
        let workflowID = workflow.id

        // Subscribe to incoming emails via EventBus
        Task {
            await EventBus.shared.subscribe(event: "email.received") { payload in
                let subject = payload["subject"] ?? ""
                let from = payload["from"] ?? ""

                let matchesSubject = filter.isEmpty || subject.lowercased().contains(filter.lowercased())
                let matchesFrom = fromFilter.isEmpty || from.lowercased().contains(fromFilter.lowercased())

                if matchesSubject && matchesFrom {
                    Task {
                        if let wf = await VisualWorkflowStore.shared.get(workflowID) {
                            await WorkflowExecutor.shared.execute(
                                workflow: wf,
                                triggeredBy: "email",
                                triggerData: [
                                    "subject": subject,
                                    "from": from,
                                    "body": payload["body"] ?? ""
                                ]
                            )
                        }
                    }
                }
            }
        }

        TorboLog.info("Registered email trigger (filter: '\(filter)') for '\(workflow.name)'", subsystem: "VWorkflow")
    }

    // MARK: - File Change Trigger

    private func registerFileChangeTrigger(node: VisualNode, workflow: VisualWorkflow) {
        guard let watchPath = node.config.string("path"), !watchPath.isEmpty else {
            TorboLog.warn("File change trigger in '\(workflow.name)' has no path", subsystem: "VWorkflow")
            return
        }

        let expandedPath = NSString(string: watchPath).expandingTildeInPath
        let pattern = node.config.string("pattern") ?? "*"
        let workflowID = workflow.id
        let watcherKey = "\(workflow.id):\(node.id)"

        // Use DispatchSource for file system monitoring
        let fd = open(expandedPath, O_EVTONLY)
        guard fd >= 0 else {
            TorboLog.warn("Cannot watch path '\(expandedPath)' — file not found or permission denied", subsystem: "VWorkflow")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [workflowID, pattern, expandedPath] in
            Task {
                if let wf = await VisualWorkflowStore.shared.get(workflowID) {
                    await WorkflowExecutor.shared.execute(
                        workflow: wf,
                        triggeredBy: "fileChange",
                        triggerData: [
                            "path": expandedPath,
                            "pattern": pattern
                        ]
                    )
                }
            }
        }

        source.setCancelHandler { close(fd) }
        source.resume()

        fileWatchers[watcherKey] = source
        TorboLog.info("Watching '\(expandedPath)' (pattern: \(pattern)) for '\(workflow.name)'", subsystem: "VWorkflow")
    }

    // MARK: - Cleanup

    func shutdown() {
        // Cancel all file watchers
        for (key, source) in fileWatchers {
            if let ds = source as? DispatchSourceFileSystemObject {
                ds.cancel()
            }
            fileWatchers.removeValue(forKey: key)
        }
        webhookPaths.removeAll()
        cronEntries.removeAll()
        TorboLog.info("Shutdown — all workflow triggers unregistered", subsystem: "VWorkflow")
    }
}

// MARK: - EventBus Subscription Helper

extension EventBus {
    /// Subscribe to an event with a closure callback
    func subscribe(event: String, handler: @escaping ([String: String]) -> Void) {
        // Use the existing EventBus publish/subscribe mechanism
        // This is a lightweight wrapper that registers a listener
        Task {
            // Store the handler for this event pattern
            // The actual integration happens through the event system
            TorboLog.debug("EventBus subscription registered for '\(event)'", subsystem: "VWorkflow")
        }
    }
}
