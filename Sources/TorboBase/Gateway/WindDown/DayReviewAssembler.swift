// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Day Review Assembler
// Pulls calendar events, emails, tasks, ambient alerts, and tomorrow's calendar
// into a structured review payload for the WindDown Writer.

import Foundation

/// Raw data collected from the user's day, ready for LLM summarization.
struct DayReview: Codable {
    let date: String                          // ISO date: "2026-02-20"
    let calendarToday: [EventSummary]
    let calendarTomorrow: [EventSummary]
    let emailsSent: Int
    let emailsReceived: Int
    let emailHighlights: [String]             // Subject lines of notable emails
    let tasksCompleted: [String]              // Titles
    let tasksPending: [String]                // Titles
    let tasksFailed: [String]                 // Titles
    let ambientAlerts: [String]               // Alert messages fired today
    let earliestMeetingTomorrow: EventSummary?

    struct EventSummary: Codable {
        let title: String
        let startTime: String                 // "HH:mm"
        let endTime: String                   // "HH:mm"
        let location: String?
        let attendees: String?                // From notes field if available
        let isAllDay: Bool
    }
}

// MARK: - Assembler

actor DayReviewAssembler {
    static let shared = DayReviewAssembler()

    /// Collect all data sources for today's review.
    func assemble() async -> DayReview {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: todayEnd) ?? todayEnd

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        // 1. Calendar: today's events
        let todayEvents = await CalendarManager.shared.listEvents(from: todayStart, to: todayEnd)
        let calendarToday = todayEvents.map { event in
            DayReview.EventSummary(
                title: event.title,
                startTime: timeFormatter.string(from: event.startDate),
                endTime: timeFormatter.string(from: event.endDate),
                location: event.location,
                attendees: event.notes,
                isAllDay: event.isAllDay
            )
        }

        // 2. Calendar: tomorrow's events
        let tomorrowEvents = await CalendarManager.shared.listEvents(from: todayEnd, to: tomorrowEnd)
        let calendarTomorrow = tomorrowEvents.map { event in
            DayReview.EventSummary(
                title: event.title,
                startTime: timeFormatter.string(from: event.startDate),
                endTime: timeFormatter.string(from: event.endDate),
                location: event.location,
                attendees: event.notes,
                isAllDay: event.isAllDay
            )
        }

        // 3. Earliest meeting tomorrow (non-all-day, before noon)
        let earliestMeeting = tomorrowEvents
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first
            .map { event in
                DayReview.EventSummary(
                    title: event.title,
                    startTime: timeFormatter.string(from: event.startDate),
                    endTime: timeFormatter.string(from: event.endDate),
                    location: event.location,
                    attendees: event.notes,
                    isAllDay: false
                )
            }

        // 4. Emails — pull recent from Mail.app
        let (emailsSent, emailsReceived, emailHighlights) = await assembleEmailStats()

        // 5. Tasks — completed, pending, failed from today
        let (completed, pending, failed) = await assembleTaskStats(since: todayStart)

        // 6. Ambient alerts fired today
        let alertMessages = await assembleAlertStats(since: todayStart)

        let review = DayReview(
            date: dateString,
            calendarToday: calendarToday,
            calendarTomorrow: calendarTomorrow,
            emailsSent: emailsSent,
            emailsReceived: emailsReceived,
            emailHighlights: emailHighlights,
            tasksCompleted: completed,
            tasksPending: pending,
            tasksFailed: failed,
            ambientAlerts: alertMessages,
            earliestMeetingTomorrow: earliestMeeting
        )

        TorboLog.info("Assembled day review: \(calendarToday.count) events today, \(calendarTomorrow.count) tomorrow, \(completed.count) tasks done, \(pending.count) pending", subsystem: "WindDown")
        return review
    }

    // MARK: - Email Stats

    private func assembleEmailStats() async -> (sent: Int, received: Int, highlights: [String]) {
        #if os(macOS)
        let raw = await EmailManager.shared.checkEmail(limit: 50, mailbox: "INBOX")
        let lines = raw.split(separator: "\n").map(String.init)

        var subjects: [String] = []
        var received = 0
        for line in lines {
            guard line.contains("SUBJECT:") else { continue }
            received += 1
            // Extract subject
            let segments = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            for segment in segments {
                if segment.hasPrefix("SUBJECT:") {
                    let subject = String(segment.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !subject.isEmpty {
                        subjects.append(subject)
                    }
                }
            }
        }

        // Check sent mail
        let sentRaw = await EmailManager.shared.checkEmail(limit: 50, mailbox: "Sent Messages")
        let sentCount = sentRaw.split(separator: "\n").filter { $0.contains("SUBJECT:") }.count

        // Keep only first 5 notable subjects
        return (sentCount, received, Array(subjects.prefix(5)))
        #else
        return (0, 0, [])
        #endif
    }

    // MARK: - Task Stats

    private func assembleTaskStats(since: Date) async -> (completed: [String], pending: [String], failed: [String]) {
        let allTasks = await TaskQueue.shared.allTasks()

        let completed = allTasks
            .filter { $0.status == .completed && ($0.completedAt ?? .distantPast) >= since }
            .map(\.title)

        let pending = allTasks
            .filter { $0.status == .pending || $0.status == .inProgress }
            .map(\.title)

        let failed = allTasks
            .filter { $0.status == .failed && ($0.completedAt ?? .distantPast) >= since }
            .map(\.title)

        return (completed, pending, failed)
    }

    // MARK: - Alert Stats

    private func assembleAlertStats(since: Date) async -> [String] {
        // Pull alerts from the AmbientAlertManager
        var messages: [String] = []
        let alerts = await AmbientAlertManager.shared.getAlerts(limit: 200)
        for alert in alerts {
            if alert.timestamp >= since.timeIntervalSince1970 {
                messages.append(alert.message)
            }
        }
        return messages
    }
}
