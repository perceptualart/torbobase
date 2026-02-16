// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Calendar Integration
// CalendarManager.swift — Access macOS calendar events via EventKit
// Enables agents to: list events, create events, check availability

import Foundation
#if canImport(EventKit)
import EventKit
#endif

// MARK: - Calendar Event (simplified)

struct CalendarEvent {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool
    let calendarName: String

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var durationMinutes: Int { Int(duration / 60) }

    func toDict() -> [String: Any] {
        let df = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "start": df.string(from: startDate),
            "end": df.string(from: endDate),
            "is_all_day": isAllDay,
            "calendar": calendarName,
            "duration_minutes": durationMinutes
        ]
        if let loc = location { dict["location"] = loc }
        if let notes = notes { dict["notes"] = String(notes.prefix(500)) }
        return dict
    }
}

// MARK: - Calendar Manager

#if canImport(EventKit)

actor CalendarManager {
    static let shared = CalendarManager()

    private let eventStore = EKEventStore()
    private var hasAccess = false

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        if hasAccess { return true }

        do {
            let granted: Bool
            if #available(macOS 14, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .event) { result, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: result)
                        }
                    }
                }
            }
            hasAccess = granted
            if granted {
                TorboLog.info("Access granted", subsystem: "Calendar")
            } else {
                TorboLog.warn("Access denied — user must grant in System Preferences", subsystem: "Calendar")
            }
            return granted
        } catch {
            TorboLog.error("Access error: \(error)", subsystem: "Calendar")
            return false
        }
    }

    // MARK: - List Events

    /// Get calendar events within a date range
    func listEvents(from startDate: Date, to endDate: Date, calendarName: String? = nil) async -> [CalendarEvent] {
        guard await requestAccess() else { return [] }

        let calendars: [EKCalendar]?
        if let name = calendarName {
            calendars = eventStore.calendars(for: .event).filter { $0.title.lowercased() == name.lowercased() }
        } else {
            calendars = nil  // All calendars
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        return events.map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                location: event.location,
                notes: event.notes,
                isAllDay: event.isAllDay,
                calendarName: event.calendar?.title ?? "Unknown"
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    /// Get today's events
    func todayEvents() async -> [CalendarEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return await listEvents(from: start, to: end)
    }

    /// Get events for the next N days
    func upcomingEvents(days: Int = 7) async -> [CalendarEvent] {
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        return await listEvents(from: start, to: end)
    }

    // MARK: - Check Availability

    /// Check if a time slot is free
    func isAvailable(from startDate: Date, to endDate: Date) async -> Bool {
        let events = await listEvents(from: startDate, to: endDate)
        return events.isEmpty
    }

    /// Find free slots in a date range
    func findFreeSlots(from startDate: Date, to endDate: Date, minDuration: TimeInterval = 1800) async -> [[String: Any]] {
        let events = await listEvents(from: startDate, to: endDate)
        let df = ISO8601DateFormatter()

        var slots: [[String: Any]] = []
        var current = startDate

        for event in events {
            if event.isAllDay { continue }
            if event.startDate > current {
                let gap = event.startDate.timeIntervalSince(current)
                if gap >= minDuration {
                    slots.append([
                        "start": df.string(from: current),
                        "end": df.string(from: event.startDate),
                        "duration_minutes": Int(gap / 60)
                    ])
                }
            }
            if event.endDate > current {
                current = event.endDate
            }
        }

        // Check remaining time after last event
        if endDate > current {
            let gap = endDate.timeIntervalSince(current)
            if gap >= minDuration {
                slots.append([
                    "start": df.string(from: current),
                    "end": df.string(from: endDate),
                    "duration_minutes": Int(gap / 60)
                ])
            }
        }

        return slots
    }

    // MARK: - Create Event

    /// Create a new calendar event
    func createEvent(title: String, startDate: Date, endDate: Date,
                      location: String? = nil, notes: String? = nil,
                      calendarName: String? = nil, isAllDay: Bool = false) async -> (success: Bool, id: String?, error: String?) {
        guard await requestAccess() else {
            return (false, nil, "Calendar access not granted")
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay

        if let loc = location { event.location = loc }
        if let n = notes { event.notes = n }

        // Find calendar
        if let name = calendarName {
            event.calendar = eventStore.calendars(for: .event)
                .first { $0.title.lowercased() == name.lowercased() }
        }
        if event.calendar == nil {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            TorboLog.info("Created event: '\(title)' at \(startDate)", subsystem: "Calendar")
            return (true, event.eventIdentifier, nil)
        } catch {
            TorboLog.error("Failed to create event: \(error)", subsystem: "Calendar")
            return (false, nil, error.localizedDescription)
        }
    }

    // MARK: - Delete Event

    func deleteEvent(id: String) async -> Bool {
        guard await requestAccess() else { return false }
        guard let event = eventStore.event(withIdentifier: id) else { return false }

        do {
            try eventStore.remove(event, span: .thisEvent)
            TorboLog.info("Deleted event: '\(event.title ?? "?")'", subsystem: "Calendar")
            return true
        } catch {
            TorboLog.error("Failed to delete event: \(error)", subsystem: "Calendar")
            return false
        }
    }

    // MARK: - List Calendars

    func listCalendars() async -> [[String: Any]] {
        guard await requestAccess() else { return [] }

        return eventStore.calendars(for: .event).map { cal in
            [
                "title": cal.title,
                "type": cal.type.rawValue,
                "source": cal.source?.title ?? "Unknown",
                "color": cal.cgColor?.components?.description ?? "",
                "is_immutable": cal.isImmutable
            ] as [String: Any]
        }
    }

    // MARK: - Tool Response Formatting

    /// Format events for agent consumption
    func formatEvents(_ events: [CalendarEvent]) -> String {
        if events.isEmpty { return "No events found." }

        let df = DateFormatter()
        df.dateFormat = "E MMM d, h:mm a"
        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "h:mm a"

        return events.enumerated().map { i, event in
            let start = df.string(from: event.startDate)
            let end = timeOnly.string(from: event.endDate)
            var line = "[\(i+1)] \(event.title) — \(start) to \(end)"
            if event.isAllDay { line = "[\(i+1)] \(event.title) — All Day" }
            if let loc = event.location { line += " (\(loc))" }
            line += " [\(event.calendarName)]"
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Stats

    func stats() async -> [String: Any] {
        let today = await todayEvents()
        let upcoming = await upcomingEvents(days: 7)
        let calendars = await listCalendars()

        return [
            "has_access": hasAccess,
            "calendars": calendars.count,
            "today_events": today.count,
            "week_events": upcoming.count
        ]
    }
}

#else

// MARK: - Linux stub — Calendar not available

actor CalendarManager {
    static let shared = CalendarManager()

    private static let unavailableMsg = "[CalendarManager] Calendar not available on this platform"

    func requestAccess() async -> Bool {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return false
    }

    func listEvents(from startDate: Date, to endDate: Date, calendarName: String? = nil) async -> [CalendarEvent] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return []
    }

    func todayEvents() async -> [CalendarEvent] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return []
    }

    func upcomingEvents(days: Int = 7) async -> [CalendarEvent] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return []
    }

    func isAvailable(from startDate: Date, to endDate: Date) async -> Bool {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return true  // Assume available when calendar is unavailable
    }

    func findFreeSlots(from startDate: Date, to endDate: Date, minDuration: TimeInterval = 1800) async -> [[String: Any]] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return []
    }

    func createEvent(title: String, startDate: Date, endDate: Date,
                      location: String? = nil, notes: String? = nil,
                      calendarName: String? = nil, isAllDay: Bool = false) async -> (success: Bool, id: String?, error: String?) {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return (false, nil, "Calendar not available on this platform")
    }

    func deleteEvent(id: String) async -> Bool {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return false
    }

    func listCalendars() async -> [[String: Any]] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return []
    }

    func formatEvents(_ events: [CalendarEvent]) -> String {
        // Linux stub — no events to format
        return "Calendar not available on Linux"
    }

    func stats() async -> [String: Any] {
        TorboLog.info(Self.unavailableMsg, subsystem: "Calendar")
        return [
            "has_access": false,
            "calendars": 0,
            "today_events": 0,
            "week_events": 0
        ]
    }
}

#endif
