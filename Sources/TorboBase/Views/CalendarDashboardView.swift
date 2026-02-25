// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Calendar + Active Jobs Overlay
// The user's day at a glance: events, tasks, deadlines, commitments.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

struct CalendarDashboardView: View {
    @EnvironmentObject private var state: AppState

    @State private var viewMode: CalendarMode = .day
    @State private var selectedDate = Date()
    @State private var events: [CalendarEventItem] = []
    @State private var activeTasks: [TaskItem] = []
    @State private var commitments: [CommitmentItem] = []

    enum CalendarMode: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
    }

    // Lightweight wrappers to avoid leaking Gateway types into SwiftUI
    struct CalendarEventItem: Identifiable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let isAllDay: Bool
        let calendarName: String
    }

    struct TaskItem: Identifiable {
        let id: String
        let title: String
        let agentID: String
        let status: String
        let startedAt: Date?
    }

    struct CommitmentItem: Identifiable {
        let id: String
        let text: String
        let dueDate: Date?
        let status: String
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            calendarHeader

            Divider().overlay(Color.white.opacity(0.06))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch viewMode {
                    case .day:
                        dayView
                    case .week:
                        weekView
                    case .month:
                        monthView
                    }
                }
                .padding(24)
            }
        }
        .task {
            await refreshData()
        }
        .onChange(of: selectedDate) { _ in
            Task { await refreshData() }
        }
    }

    // MARK: - Header

    private var calendarHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(dateLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            // Navigation
            HStack(spacing: 8) {
                Button { navigateDate(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))

                Button { selectedDate = Date() } label: {
                    Text("Today").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { navigateDate(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }

            Picker("", selection: $viewMode) {
                ForEach(CalendarMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Day View

    private var dayView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Today's events
            if !todayEvents.isEmpty {
                sectionHeader("EVENTS", icon: "calendar", count: todayEvents.count)
                ForEach(todayEvents) { event in
                    eventCard(event)
                }
            }

            // Active tasks interspersed
            if !activeTasks.isEmpty {
                sectionHeader("ACTIVE JOBS", icon: "bolt.fill", count: activeTasks.count)
                ForEach(activeTasks) { task in
                    taskCard(task)
                }
            }

            // Commitments due today
            let dueToday = commitments.filter { isDueToday($0.dueDate) }
            if !dueToday.isEmpty {
                sectionHeader("DUE TODAY", icon: "exclamationmark.circle", count: dueToday.count)
                ForEach(dueToday) { commitment in
                    commitmentCard(commitment)
                }
            }

            // Upcoming commitments
            let upcoming = commitments.filter { !isDueToday($0.dueDate) }
            if !upcoming.isEmpty {
                sectionHeader("UPCOMING", icon: "clock", count: upcoming.count)
                ForEach(upcoming.prefix(5)) { commitment in
                    commitmentCard(commitment)
                }
            }

            if todayEvents.isEmpty && activeTasks.isEmpty && commitments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.1))
                    Text("Nothing scheduled")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        }
    }

    // MARK: - Week View

    private var weekView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let weekDays = weekDates()
            HStack(alignment: .top, spacing: 8) {
                ForEach(weekDays, id: \.self) { date in
                    let dayEvents = events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: date) }
                    let isToday = Calendar.current.isDateInToday(date)

                    VStack(alignment: .leading, spacing: 6) {
                        // Day header
                        VStack(spacing: 2) {
                            Text(dayOfWeek(date))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 16, weight: isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? .cyan : .white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isToday ? Color.cyan.opacity(0.06) : Color.clear)
                        .cornerRadius(6)

                        // Events for this day
                        ForEach(dayEvents) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(timeString(event.startDate))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.5))
                                Text(event.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(2)
                            }
                            .padding(6)
                            .background(Color.cyan.opacity(0.06))
                            .cornerRadius(4)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Month View

    private var monthView: some View {
        let calendar = Calendar.current
        let monthDates = monthGridDates()

        return VStack(spacing: 4) {
            // Weekday headers
            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                }
            }

            // Date grid
            let rows = monthDates.count / 7
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let date = monthDates[row * 7 + col]
                        let isCurrentMonth = calendar.component(.month, from: date) == calendar.component(.month, from: selectedDate)
                        let isToday = calendar.isDateInToday(date)
                        let hasEvents = events.contains { calendar.isDate($0.startDate, inSameDayAs: date) }

                        VStack(spacing: 2) {
                            Text("\(calendar.component(.day, from: date))")
                                .font(.system(size: 12, weight: isToday ? .bold : .regular))
                                .foregroundStyle(isToday ? .cyan : (isCurrentMonth ? .white.opacity(0.6) : .white.opacity(0.15)))
                            if hasEvents {
                                Circle().fill(Color.cyan.opacity(0.5)).frame(width: 4, height: 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(isToday ? Color.cyan.opacity(0.06) : Color.clear)
                        .cornerRadius(4)
                        .onTapGesture {
                            selectedDate = date
                            viewMode = .day
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private func eventCard(_ event: CalendarEventItem) -> some View {
        HStack(spacing: 12) {
            // Time
            VStack(spacing: 2) {
                Text(event.isAllDay ? "All Day" : timeString(event.startDate))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                if !event.isAllDay {
                    Text(timeString(event.endDate))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if let loc = event.location, !loc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 9))
                        Text(loc)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                }
                Text(event.calendarName)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }

            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cyan.opacity(0.08), lineWidth: 1)
        )
    }

    private func taskCard(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(task.status == "running" ? Color.green : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(task.agentID) · \(task.status)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
            if let started = task.startedAt {
                Text(relativeTime(started))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func commitmentCard(_ commitment: CommitmentItem) -> some View {
        HStack(spacing: 10) {
            let isOverdue = commitment.dueDate.map { $0 < Date() } ?? false
            Image(systemName: isOverdue ? "exclamationmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(isOverdue ? .red : .white.opacity(0.3))
            VStack(alignment: .leading, spacing: 2) {
                Text(commitment.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                if let due = commitment.dueDate {
                    Text("Due: \(dateString(due))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(isOverdue ? .red.opacity(0.7) : .white.opacity(0.3))
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(1)
            Text("\(count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    // MARK: - Data

    private var todayEvents: [CalendarEventItem] {
        events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func refreshData() async {
        // Calendar events
        let calEvents = await CalendarManager.shared.upcomingEvents(days: 30)
        events = calEvents.map { evt in
            CalendarEventItem(
                id: evt.id, title: evt.title,
                startDate: evt.startDate, endDate: evt.endDate,
                location: evt.location, isAllDay: evt.isAllDay,
                calendarName: evt.calendarName
            )
        }

        // Active tasks
        let tasks = await TaskQueue.shared.allTasks()
        activeTasks = tasks.filter { $0.status == .inProgress || $0.status == .pending }.map { t in
            TaskItem(
                id: t.id, title: t.title, agentID: t.assignedTo,
                status: t.status == .inProgress ? "running" : "pending",
                startedAt: t.startedAt
            )
        }

        // Commitments
        let commits = await CommitmentsStore.shared.allOpen()
        commitments = commits.map { c in
            CommitmentItem(
                id: "\(c.id)", text: c.text,
                dueDate: c.dueDate, status: c.status.rawValue
            )
        }
    }

    // MARK: - Helpers

    private var dateLabel: String {
        let f = DateFormatter()
        switch viewMode {
        case .day:
            f.dateFormat = "EEEE, MMMM d, yyyy"
        case .week:
            f.dateFormat = "'Week of' MMM d"
        case .month:
            f.dateFormat = "MMMM yyyy"
        }
        return f.string(from: selectedDate)
    }

    private func navigateDate(_ direction: Int) {
        let cal = Calendar.current
        switch viewMode {
        case .day:
            selectedDate = cal.date(byAdding: .day, value: direction, to: selectedDate) ?? selectedDate
        case .week:
            selectedDate = cal.date(byAdding: .weekOfYear, value: direction, to: selectedDate) ?? selectedDate
        case .month:
            selectedDate = cal.date(byAdding: .month, value: direction, to: selectedDate) ?? selectedDate
        }
    }

    private func weekDates() -> [Date] {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: selectedDate)?.start else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func monthGridDates() -> [Date] {
        let cal = Calendar.current
        guard let monthInterval = cal.dateInterval(of: .month, for: selectedDate) else { return [] }
        let firstDay = monthInterval.start
        let weekday = cal.component(.weekday, from: firstDay)
        guard let gridStart = cal.date(byAdding: .day, value: -(weekday - 1), to: firstDay) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func dayOfWeek(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func isDueToday(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Calendar.current.isDateInToday(date)
    }
}
#endif
