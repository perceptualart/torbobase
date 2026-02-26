// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Workflow Templates
// Pre-built visual workflow templates that users can instantiate with one click.
import Foundation

// MARK: - Template Library

enum WorkflowTemplateLibrary {
    static func allTemplates() -> [VisualWorkflow] {
        [emailTriage, meetingPrep, invoiceProcessing, priceMonitor, dailySummary]
    }

    static func template(named name: String) -> VisualWorkflow? {
        allTemplates().first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - 1. Email Triage

    static var emailTriage: VisualWorkflow {
        let trigger = VisualNode(id: "t1", kind: .trigger, label: "New Email",
                                 positionX: 60, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("triggerKind", "email")
            c.set("filter", "")
            c.set("from", "")
            return c
        }())

        let classifier = VisualNode(id: "a1", kind: .agent, label: "Classify Email",
                                    positionX: 280, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Classify this email as 'urgent' or 'normal'. Reply with ONLY one word: urgent or normal.\n\nEmail:\n{{context}}")
            return c
        }())

        let decision = VisualNode(id: "d1", kind: .decision, label: "Is Urgent?",
                                  positionX: 500, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("condition", "contains('urgent')")
            return c
        }())

        let notify = VisualNode(id: "ac1", kind: .action, label: "Send Alert",
                                positionX: 720, positionY: 60, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "sendMessage")
            c.set("platform", "telegram")
            c.set("target", "")
            c.set("message", "URGENT EMAIL: {{result}}")
            return c
        }())

        let autoReply = VisualNode(id: "a2", kind: .agent, label: "Draft Auto-Reply",
                                   positionX: 720, positionY: 240, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Write a polite acknowledgment reply to this email. Keep it brief and professional.\n\nEmail:\n{{context}}")
            return c
        }())

        return VisualWorkflow(
            name: "Email Triage",
            description: "Automatically classify incoming emails. Route urgent ones to Telegram, auto-reply to normal ones.",
            nodes: [trigger, classifier, decision, notify, autoReply],
            connections: [
                NodeConnection(from: "t1", to: "a1"),
                NodeConnection(from: "a1", to: "d1"),
                NodeConnection(from: "d1", to: "ac1", label: "true"),
                NodeConnection(from: "d1", to: "a2", label: "false"),
            ]
        )
    }

    // MARK: - 2. Meeting Prep

    static var meetingPrep: VisualWorkflow {
        let trigger = VisualNode(id: "t1", kind: .trigger, label: "30min Before Meeting",
                                 positionX: 60, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("triggerKind", "schedule")
            c.set("cron", "*/30 * * * *")
            return c
        }())

        let research = VisualNode(id: "a1", kind: .agent, label: "Research Attendees",
                                  positionX: 300, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "orion")
            c.set("prompt", "Research the attendees and topics for the upcoming meeting. Summarize key talking points, recent news about attendees' companies, and suggested questions.")
            return c
        }())

        let summary = VisualNode(id: "a2", kind: .agent, label: "Create Briefing",
                                 positionX: 540, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Create a concise meeting prep briefing from this research. Format as bullet points with sections: Key Points, Background, Suggested Questions.\n\n{{context}}")
            return c
        }())

        let send = VisualNode(id: "ac1", kind: .action, label: "Send to Telegram",
                              positionX: 780, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "sendMessage")
            c.set("platform", "telegram")
            c.set("target", "")
            c.set("message", "Meeting Prep:\n\n{{result}}")
            return c
        }())

        return VisualWorkflow(
            name: "Meeting Prep",
            description: "Research attendees and create a briefing document 30 minutes before each meeting.",
            nodes: [trigger, research, summary, send],
            connections: [
                NodeConnection(from: "t1", to: "a1"),
                NodeConnection(from: "a1", to: "a2"),
                NodeConnection(from: "a2", to: "ac1"),
            ]
        )
    }

    // MARK: - 3. Invoice Processing

    static var invoiceProcessing: VisualWorkflow {
        let trigger = VisualNode(id: "t1", kind: .trigger, label: "New Invoice PDF",
                                 positionX: 60, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("triggerKind", "fileChange")
            c.set("path", "~/Documents/Invoices")
            c.set("pattern", "*.pdf")
            return c
        }())

        let extract = VisualNode(id: "a1", kind: .agent, label: "Extract Data",
                                 positionX: 280, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Extract the following from this invoice: vendor name, invoice number, date, total amount, line items. Format as JSON.")
            return c
        }())

        let approval = VisualNode(id: "ap1", kind: .approval, label: "Approve Payment",
                                  positionX: 500, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("message", "Review extracted invoice data and approve for processing:\n\n{{context}}")
            c.set("timeout", 3600.0)  // 1 hour
            return c
        }())

        let write = VisualNode(id: "ac1", kind: .action, label: "Save to CSV",
                               positionX: 720, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "writeFile")
            c.set("path", "~/Documents/invoice_log.csv")
            c.set("content", "{{result}}")
            return c
        }())

        return VisualWorkflow(
            name: "Invoice Processing",
            description: "Watch for new invoice PDFs, extract data with AI, get approval, then log to spreadsheet.",
            nodes: [trigger, extract, approval, write],
            connections: [
                NodeConnection(from: "t1", to: "a1"),
                NodeConnection(from: "a1", to: "ap1"),
                NodeConnection(from: "ap1", to: "ac1"),
            ]
        )
    }

    // MARK: - 4. Price Monitor

    static var priceMonitor: VisualWorkflow {
        let trigger = VisualNode(id: "t1", kind: .trigger, label: "Every Hour",
                                 positionX: 60, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("triggerKind", "schedule")
            c.set("cron", "0 */1 * * *")
            return c
        }())

        let fetch = VisualNode(id: "a1", kind: .agent, label: "Check Prices",
                               positionX: 280, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Check the current price and compare with previous. Report the percentage change. If the change is greater than 5%, say 'ALERT: price changed by X%'. Otherwise say 'stable'.")
            return c
        }())

        let decision = VisualNode(id: "d1", kind: .decision, label: "Changed > 5%?",
                                  positionX: 500, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("condition", "contains('alert')")
            return c
        }())

        let alert = VisualNode(id: "ac1", kind: .action, label: "Send Alert",
                               positionX: 720, positionY: 80, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "sendMessage")
            c.set("platform", "telegram")
            c.set("target", "")
            c.set("message", "Price Alert: {{result}}")
            return c
        }())

        let log = VisualNode(id: "ac2", kind: .action, label: "Log Price",
                             positionX: 720, positionY: 220, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "writeFile")
            c.set("path", "~/Documents/price_log.txt")
            c.set("content", "{{result}}\n")
            return c
        }())

        return VisualWorkflow(
            name: "Price Monitor",
            description: "Check prices every hour. Alert via Telegram if price changes more than 5%.",
            nodes: [trigger, fetch, decision, alert, log],
            connections: [
                NodeConnection(from: "t1", to: "a1"),
                NodeConnection(from: "a1", to: "d1"),
                NodeConnection(from: "d1", to: "ac1", label: "true"),
                NodeConnection(from: "d1", to: "ac2", label: "false"),
            ]
        )
    }

    // MARK: - 5. Daily Summary

    static var dailySummary: VisualWorkflow {
        let trigger = VisualNode(id: "t1", kind: .trigger, label: "6pm Daily",
                                 positionX: 60, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("triggerKind", "schedule")
            c.set("cron", "0 18 * * *")
            return c
        }())

        let summarize = VisualNode(id: "a1", kind: .agent, label: "Summarize Day",
                                   positionX: 300, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("agentID", "sid")
            c.set("prompt", "Generate a daily summary report. Include: tasks completed today, pending items, key decisions made, and tomorrow's priorities. Keep it concise and actionable.")
            return c
        }())

        let email = VisualNode(id: "ac1", kind: .action, label: "Email Report",
                               positionX: 540, positionY: 150, config: {
            var c = NodeConfig.empty
            c.set("actionKind", "sendEmail")
            c.set("to", "")
            c.set("subject", "Daily Summary — {{date}}")
            c.set("body", "{{result}}")
            return c
        }())

        return VisualWorkflow(
            name: "Daily Summary",
            description: "At 6pm daily, generate a summary of the day's activities and email the report.",
            nodes: [trigger, summarize, email],
            connections: [
                NodeConnection(from: "t1", to: "a1"),
                NodeConnection(from: "a1", to: "ac1"),
            ]
        )
    }
}
