// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Tomorrow Prep
// If tomorrow has an early meeting (before 10am), queues a midnight research task
// via CronScheduler to research attendees, pull relevant email threads, and
// prepare a briefing document.

import Foundation

actor TomorrowPrep {
    static let shared = TomorrowPrep()

    /// Check if tomorrow has an early meeting and queue a research task if so.
    /// Returns true if a prep task was queued.
    func prepareIfNeeded(review: DayReview) async -> Bool {
        guard let earliest = review.earliestMeetingTomorrow else {
            TorboLog.debug("No meetings tomorrow — skipping prep", subsystem: "WindDown")
            return false
        }

        // Parse start time — only prep for meetings before 10:00
        let parts = earliest.startTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let hour = parts[0]

        guard hour < 10 else {
            TorboLog.debug("Earliest meeting at \(earliest.startTime) — not early enough for overnight prep", subsystem: "WindDown")
            return false
        }

        // Build the research prompt
        let prompt = buildResearchPrompt(meeting: earliest, review: review)

        // Queue via CronScheduler as a one-shot task at midnight
        let task = await CronScheduler.shared.createTask(
            name: "Tomorrow Prep: \(earliest.title)",
            cronExpression: "0 0 * * *",  // Midnight tonight
            agentID: "sid",
            prompt: prompt
        )

        if let task {
            TorboLog.info("Queued overnight prep for '\(earliest.title)' at \(earliest.startTime) — cron task \(task.id)", subsystem: "WindDown")

            // Also create a direct TaskQueue task for immediate processing
            // in case the ProactiveAgent picks it up before midnight
            let _ = await TaskQueue.shared.createTask(
                title: "Tomorrow Prep: \(earliest.title)",
                description: prompt,
                assignedTo: "sid",
                assignedBy: "wind-down",
                priority: .normal
            )

            return true
        } else {
            TorboLog.error("Failed to create prep cron task", subsystem: "WindDown")
            return false
        }
    }

    // MARK: - Research Prompt

    private func buildResearchPrompt(meeting: DayReview.EventSummary, review: DayReview) -> String {
        var parts: [String] = []

        parts.append("TOMORROW PREP — Research task for upcoming meeting.")
        parts.append("")
        parts.append("Meeting: \(meeting.title)")
        parts.append("Time: \(meeting.startTime)–\(meeting.endTime)")
        if let location = meeting.location, !location.isEmpty {
            parts.append("Location: \(location)")
        }
        if let attendees = meeting.attendees, !attendees.isEmpty {
            parts.append("Notes/Attendees: \(attendees)")
        }

        parts.append("")
        parts.append("Tasks:")
        parts.append("1. Search email (using check_email tool) for threads related to this meeting topic or attendees from the past 7 days.")
        parts.append("2. If attendee names are available, search memory (loa_recall) for what you know about each person.")
        parts.append("3. Check if there are any pending tasks related to this meeting topic.")
        parts.append("4. Compile a short briefing (max 200 words) with:")
        parts.append("   - Key context from recent emails")
        parts.append("   - What you know about attendees")
        parts.append("   - Any open items or action items relevant to this meeting")
        parts.append("   - Suggested talking points")
        parts.append("")
        parts.append("Save the briefing using loa_teach with category 'episode' and entities including the meeting title.")
        parts.append("This briefing will be recalled automatically before the meeting via memory search.")

        // Add context about other tomorrow events for broader awareness
        if review.calendarTomorrow.count > 1 {
            parts.append("")
            parts.append("Other events tomorrow for context:")
            for event in review.calendarTomorrow where event.title != meeting.title {
                parts.append("- \(event.startTime): \(event.title)")
            }
        }

        return parts.joined(separator: "\n")
    }
}
