// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Commitments Follow-Up Engine
// Periodic check for overdue commitments. Generates nudges for injection into
// the system prompt via MemoryRouter. Also generates the wind-down section.

import Foundation

/// Manages commitment follow-up: periodic checks, nudge generation, and wind-down integration.
actor CommitmentsFollowUp {
    static let shared = CommitmentsFollowUp()

    private var isRunning = false
    private var pendingNudges: [String] = []
    private var checkTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOverdue()
                // Check every 30 minutes
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)
            }
        }

        TorboLog.info("Follow-up engine started (30min cycle)", subsystem: "Commitments")
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
        isRunning = false
    }

    // MARK: - Periodic Check

    private func checkOverdue() async {
        let needsReminder = await CommitmentsStore.shared.overdueNeedingReminder()
        guard !needsReminder.isEmpty else { return }

        TorboLog.info("\(needsReminder.count) overdue commitment(s) need reminders", subsystem: "Commitments")

        for commitment in needsReminder {
            let nudge = generateNudge(for: commitment)
            pendingNudges.append(nudge)
            await CommitmentsStore.shared.recordReminder(id: commitment.id)
        }
    }

    // MARK: - Nudge Generation

    private func generateNudge(for commitment: Commitment) -> String {
        let daysOverdue: Int
        if let due = commitment.dueDate {
            daysOverdue = max(1, Int(Date().timeIntervalSince(due) / 86400))
        } else {
            daysOverdue = 0
        }

        let count = commitment.reminderCount

        // Escalating tone based on reminder count and days overdue
        if count == 0 {
            return "Gentle reminder: you said you'd \"\(commitment.text)\"" +
                (commitment.dueText != nil ? " (\(commitment.dueText!))" : "") +
                ". How's that going?"
        } else if count < 3 || daysOverdue < 3 {
            return "Following up: \"\(commitment.text)\" is \(daysOverdue) day(s) overdue. Want to tackle it today, or should we reschedule?"
        } else {
            return "This has been hanging: \"\(commitment.text)\" — \(daysOverdue) days overdue now. Should we mark it done, reschedule, or drop it?"
        }
    }

    // MARK: - Nudge Consumption (for MemoryRouter injection)

    /// Consume all pending nudges (returns and clears the queue).
    func consumeNudges() -> [String] {
        let nudges = pendingNudges
        pendingNudges.removeAll()
        return nudges
    }

    /// Peek at pending nudges without consuming.
    func peekNudges() -> [String] {
        return pendingNudges
    }

    // MARK: - Wind-Down Section (for WindDownWriter)

    /// Generate the commitments section for the evening briefing.
    func windDownSection() async -> String {
        let open = await CommitmentsStore.shared.allOpen()
        guard !open.isEmpty else { return "" }

        var parts: [String] = []
        parts.append("### Open Commitments")

        // Overdue
        let overdue = open.filter { $0.dueDate != nil && $0.dueDate! < Date() }
        if !overdue.isEmpty {
            parts.append("**Overdue:**")
            for c in overdue {
                let daysLate = Int(Date().timeIntervalSince(c.dueDate!) / 86400)
                parts.append("- \"\(c.text)\" — \(daysLate)d overdue" + (c.dueText != nil ? " (was due \(c.dueText!))" : ""))
            }
        }

        // Upcoming (has due date, not overdue)
        let upcoming = open.filter { $0.dueDate != nil && $0.dueDate! >= Date() }
        if !upcoming.isEmpty {
            parts.append("**Upcoming:**")
            for c in upcoming {
                parts.append("- \"\(c.text)\"" + (c.dueText != nil ? " — due \(c.dueText!)" : ""))
            }
        }

        // No deadline
        let noDue = open.filter { $0.dueDate == nil }
        if !noDue.isEmpty {
            parts.append("**No deadline:**")
            for c in noDue.prefix(5) {
                parts.append("- \"\(c.text)\"")
            }
            if noDue.count > 5 {
                parts.append("- ...and \(noDue.count - 5) more")
            }
        }

        return parts.joined(separator: "\n")
    }
}
