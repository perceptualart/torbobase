// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Scheduler Dashboard
// SwiftUI view for managing scheduled tasks: CRUD, expression builder, history viewer.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

// MARK: - Cron Scheduler Dashboard

struct CronSchedulerView: View {
    @EnvironmentObject private var state: AppState

    @State private var schedules: [CronTask] = []
    @State private var selectedScheduleID: String?
    @State private var showingCreateSheet = false
    @State private var showingTemplateSheet = false
    @State private var isLoading = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HSplitView {
                scheduleList
                    .frame(minWidth: 320)
                detailPanel
                    .frame(minWidth: 400)
            }
        }
        .background(Color.black.opacity(0.95))
        .onAppear { startRefresh() }
        .onDisappear { refreshTimer?.invalidate() }
        .sheet(isPresented: $showingCreateSheet) {
            CronCreateSheet { newTask in
                if let task = newTask {
                    schedules.append(task)
                    selectedScheduleID = task.id
                }
            }
        }
        .sheet(isPresented: $showingTemplateSheet) {
            CronTemplateSheet { newTask in
                if let task = newTask {
                    schedules.append(task)
                    selectedScheduleID = task.id
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundColor(.yellow)
                Text("Cron Scheduler")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                let enabled = schedules.filter(\.enabled).count
                let paused = schedules.filter { $0.isPaused }.count
                Text("\(schedules.count) schedules (\(enabled) active\(paused > 0 ? ", \(paused) paused" : ""))")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))

                Menu {
                    Button("Enable All") { bulkEnable() }
                    Button("Disable All") { bulkDisable() }
                    Divider()
                    Button("Install Defaults") { installDefaults() }
                    Divider()
                    Button("Delete All", role: .destructive) { bulkDeleteAll() }
                } label: {
                    Label("Bulk", systemImage: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 60)

                Button(action: { showingTemplateSheet = true }) {
                    Label("Templates", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: { showingCreateSheet = true }) {
                    Label("New Schedule", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Stats row
            if !schedules.isEmpty {
                HStack(spacing: 16) {
                    let totalRuns = schedules.reduce(0) { $0 + $1.runCount }
                    let allHistory = schedules.flatMap(\.executionLog)
                    let successCount = allHistory.filter(\.success).count

                    statsChip(label: "Total Runs", value: "\(totalRuns)", color: .white)
                    if !allHistory.isEmpty {
                        let rate = Int(Double(successCount) / Double(allHistory.count) * 100)
                        statsChip(label: "Success", value: "\(rate)%", color: rate >= 90 ? .green : rate >= 70 ? .yellow : .red)
                    }
                    let cats = Set(schedules.compactMap(\.category))
                    statsChip(label: "Categories", value: "\(cats.count)", color: .cyan)

                    if let nextDue = schedules.filter({ $0.enabled && $0.nextRun != nil })
                        .min(by: { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }),
                       let nextRun = nextDue.nextRun {
                        let interval = nextRun.timeIntervalSinceNow
                        let timeStr = interval < 60 ? "<1m" : interval < 3600 ? "\(Int(interval/60))m" : "\(Int(interval/3600))h"
                        statsChip(label: "Next Due", value: timeStr, color: .yellow)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
        .background(Color.black)
    }

    private func statsChip(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Schedule List

    private var scheduleList: some View {
        List(selection: $selectedScheduleID) {
            if schedules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.3))
                    Text("No Schedules")
                        .foregroundColor(.white.opacity(0.5))
                    Text("Create a schedule or use a template to get started.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 60)
            } else {
                let grouped = groupedSchedules
                ForEach(grouped, id: \.category) { group in
                    Section(header: Text(group.category.capitalized)
                        .font(.caption.bold())
                        .foregroundColor(.yellow.opacity(0.7))) {
                        ForEach(group.schedules) { schedule in
                            ScheduleRow(schedule: schedule, isSelected: selectedScheduleID == schedule.id)
                                .tag(schedule.id)
                                .contextMenu {
                                    Button("Run Now") { triggerSchedule(schedule.id) }
                                    Button("Clone") { cloneSchedule(schedule.id) }
                                    Divider()
                                    Button(schedule.enabled ? "Disable" : "Enable") {
                                        toggleSchedule(schedule.id)
                                    }
                                    if schedule.isPaused {
                                        Button("Resume") { resumeSchedule(schedule.id) }
                                    } else {
                                        Button("Pause (1h)") { pauseSchedule(schedule.id, hours: 1) }
                                        Button("Pause (24h)") { pauseSchedule(schedule.id, hours: 24) }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { deleteSchedule(schedule.id) }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var groupedSchedules: [(category: String, schedules: [CronTask])] {
        var groups: [String: [CronTask]] = [:]
        for schedule in schedules {
            let cat = schedule.category ?? "uncategorized"
            groups[cat, default: []].append(schedule)
        }
        return groups.map { (category: $0.key, schedules: $0.value) }
            .sorted { $0.category < $1.category }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        Group {
            if let id = selectedScheduleID, let schedule = schedules.first(where: { $0.id == id }) {
                ScheduleDetailView(schedule: schedule,
                                   onTrigger: { triggerSchedule(id) },
                                   onToggle: { toggleSchedule(id) },
                                   onDelete: { deleteSchedule(id) })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.2))
                    Text("Select a schedule")
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func startRefresh() {
        loadSchedules()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            loadSchedules()
        }
    }

    private func loadSchedules() {
        Task {
            let loaded = await CronScheduler.shared.listTasks()
            await MainActor.run { schedules = loaded }
        }
    }

    private func triggerSchedule(_ id: String) {
        Task {
            _ = await CronScheduler.shared.runNow(id: id)
            loadSchedules()
        }
    }

    private func toggleSchedule(_ id: String) {
        Task {
            if let task = await CronScheduler.shared.getTask(id: id) {
                _ = await CronScheduler.shared.updateTask(id: id, enabled: !task.enabled)
                loadSchedules()
            }
        }
    }

    private func deleteSchedule(_ id: String) {
        Task {
            _ = await CronScheduler.shared.deleteTask(id: id)
            if selectedScheduleID == id { selectedScheduleID = nil }
            loadSchedules()
        }
    }

    private func cloneSchedule(_ id: String) {
        Task {
            if let cloned = await CronScheduler.shared.cloneSchedule(id: id) {
                await MainActor.run {
                    schedules.append(cloned)
                    selectedScheduleID = cloned.id
                }
            }
            loadSchedules()
        }
    }

    private func pauseSchedule(_ id: String, hours: Int) {
        Task {
            let until = Date().addingTimeInterval(TimeInterval(hours * 3600))
            _ = await CronScheduler.shared.pauseSchedule(id: id, until: until)
            loadSchedules()
        }
    }

    private func resumeSchedule(_ id: String) {
        Task {
            _ = await CronScheduler.shared.resumeSchedule(id: id)
            loadSchedules()
        }
    }

    private func bulkEnable() {
        Task {
            await CronScheduler.shared.enableAll()
            loadSchedules()
        }
    }

    private func bulkDisable() {
        Task {
            await CronScheduler.shared.disableAll()
            loadSchedules()
        }
    }

    private func bulkDeleteAll() {
        Task {
            _ = await CronScheduler.shared.deleteAll()
            selectedScheduleID = nil
            loadSchedules()
        }
    }

    private func installDefaults() {
        Task {
            await CronScheduler.shared.installDefaultSchedules()
            loadSchedules()
        }
    }
}

// MARK: - Schedule Row

private struct ScheduleRow: View {
    let schedule: CronTask
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(schedule.isPaused ? Color.orange : schedule.enabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(schedule.name)
                        .font(.system(.body, design: .default))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if schedule.isPaused {
                        Text("PAUSED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(3)
                    }
                    if schedule.isDefault == true {
                        Text("DEFAULT")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 6) {
                    Text(schedule.cronExpression)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.8))

                    Text(schedule.scheduleDescription)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Next run or paused until
            if schedule.isPaused, let until = schedule.pausedUntil, until != .distantFuture {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Paused")
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.5))
                    Text(relativeTime(until))
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.7))
                }
            } else if let nextRun = schedule.nextRun {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Next")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                    Text(relativeTime(nextRun))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Run count badge
            if schedule.runCount > 0 {
                Text("\(schedule.runCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "overdue" }
        if interval < 60 { return "<1m" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Schedule Detail View

private struct ScheduleDetailView: View {
    let schedule: CronTask
    let onTrigger: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var nextRuns: [Date] = []
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title and controls
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.name)
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text(schedule.scheduleDescription)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Spacer()
                    Toggle("Enabled", isOn: .constant(schedule.enabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onTapGesture { onToggle() }
                }

                // Cron expression
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cron Expression", systemImage: "terminal")
                            .font(.caption.bold())
                            .foregroundColor(.yellow)
                        Text(schedule.cronExpression)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(.white)
                        if schedule.cronExpression != schedule.resolvedExpression {
                            Text("Resolved: \(schedule.resolvedExpression)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .groupBoxStyle(DarkGroupBoxStyle())

                // Paused banner
                if schedule.isPaused {
                    HStack {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.orange)
                        Text("Schedule is paused")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                        if let until = schedule.pausedUntil, until != .distantFuture {
                            Text("until \(formatDateFull(until))")
                                .font(.caption)
                                .foregroundColor(.orange.opacity(0.7))
                        } else {
                            Text("indefinitely")
                                .font(.caption)
                                .foregroundColor(.orange.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                // Task details
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Task", systemImage: "text.bubble")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                        Text(schedule.prompt)
                            .font(.body)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(6)

                        HStack(spacing: 12) {
                            Label(schedule.agentID, systemImage: "person.circle")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))
                            if let tz = schedule.timezone {
                                Label(tz, systemImage: "globe")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let cat = schedule.category {
                                Label(cat.capitalized, systemImage: "folder")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Label(schedule.effectiveCatchUp ? "Catch-up enabled" : "Skip missed",
                                  systemImage: schedule.effectiveCatchUp ? "arrow.clockwise" : "forward")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))
                        }

                        if schedule.effectiveMaxRetries > 0 {
                            HStack(spacing: 6) {
                                Label("Max retries: \(schedule.effectiveMaxRetries)", systemImage: "arrow.counterclockwise")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                if let retries = schedule.retryCount, retries > 0 {
                                    Text("(\(retries) pending)")
                                        .font(.caption)
                                        .foregroundColor(.yellow.opacity(0.7))
                                }
                            }
                        }

                        if let tags = schedule.tags, !tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.5))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .groupBoxStyle(DarkGroupBoxStyle())

                // Stats row
                HStack(spacing: 20) {
                    StatBox(label: "Total Runs", value: "\(schedule.runCount)")
                    if let rate = schedule.successRate {
                        StatBox(label: "Success Rate", value: "\(rate)%")
                    }
                    if let lastRun = schedule.lastRun {
                        StatBox(label: "Last Run", value: formatDate(lastRun))
                    }
                    if let nextRun = schedule.nextRun {
                        StatBox(label: "Next Run", value: formatDate(nextRun))
                    }
                }

                // Last result/error
                if let lastResult = schedule.lastResult {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Last Result", systemImage: "checkmark.circle")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                            Text(lastResult)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(5)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .groupBoxStyle(DarkGroupBoxStyle())
                }

                if let lastError = schedule.lastError {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Last Error", systemImage: "xmark.circle")
                                .font(.caption.bold())
                                .foregroundColor(.red)
                            Text(lastError)
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.8))
                                .lineLimit(5)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .groupBoxStyle(DarkGroupBoxStyle())
                }

                // Next 5 runs preview
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Upcoming Executions", systemImage: "calendar.badge.clock")
                            .font(.caption.bold())
                            .foregroundColor(.yellow)
                        ForEach(Array(nextRuns.prefix(5).enumerated()), id: \.offset) { _, date in
                            HStack {
                                Text(formatDateFull(date))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.7))
                                Spacer()
                                Text(relativeTime(date))
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        if nextRuns.isEmpty {
                            Text("No upcoming executions")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .groupBoxStyle(DarkGroupBoxStyle())

                // Execution history
                if !schedule.executionLog.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Execution History", systemImage: "list.bullet.rectangle")
                                    .font(.caption.bold())
                                    .foregroundColor(.cyan)
                                Spacer()
                                let total = schedule.executionLog.count
                                let successes = schedule.executionLog.filter(\.success).count
                                Text("\(successes)/\(total) succeeded")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.4))
                            }

                            ForEach(Array(schedule.executionLog.suffix(10).reversed().enumerated()), id: \.offset) { _, exec in
                                HStack(spacing: 8) {
                                    Image(systemName: exec.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(exec.success ? .green : .red)
                                        .font(.caption)
                                    Text(formatDateFull(exec.timestamp))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                    Spacer()
                                    Text("\(Int(exec.duration))s")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .groupBoxStyle(DarkGroupBoxStyle())
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: onTrigger) {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!schedule.enabled)

                    Spacer()

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .onAppear { loadNextRuns() }
        .onChange(of: schedule.id) { _ in loadNextRuns() }
    }

    private func loadNextRuns() {
        Task {
            let runs = await CronScheduler.shared.nextRuns(scheduleID: schedule.id, count: 5)
            await MainActor.run { nextRuns = runs }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDateFull(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "overdue" }
        if interval < 60 { return "in <1m" }
        if interval < 3600 { return "in \(Int(interval / 60))m" }
        if interval < 86400 { return "in \(Int(interval / 3600))h" }
        return "in \(Int(interval / 86400))d"
    }
}

// MARK: - Stat Box

private struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Dark GroupBox Style

private struct DarkGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            configuration.content
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Create Sheet

private struct CronCreateSheet: View {
    let onComplete: (CronTask?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cronExpression = "0 * * * *"
    @State private var prompt = ""
    @State private var agentID = "sid"
    @State private var timezone = ""
    @State private var catchUp = true
    @State private var selectedPattern = 5  // "Every hour" index in commonPatterns
    @State private var validationMessage = ""
    @State private var isValid = true
    @State private var previewRuns: [Date] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Schedule")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Cancel") { dismiss(); onComplete(nil) }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding()
            .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.caption.bold()).foregroundColor(.white.opacity(0.6))
                        TextField("Morning Briefing", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Quick pattern selector
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Schedule Pattern").font(.caption.bold()).foregroundColor(.white.opacity(0.6))
                        Picker("Pattern", selection: $selectedPattern) {
                            ForEach(Array(CronParser.commonPatterns.enumerated()), id: \.offset) { index, pattern in
                                Text(pattern.label).tag(index)
                            }
                            Text("Custom").tag(-1)
                        }
                        .onChange(of: selectedPattern) { idx in
                            if idx >= 0, idx < CronParser.commonPatterns.count {
                                cronExpression = CronParser.commonPatterns[idx].expression
                                validateExpression()
                            }
                        }
                    }

                    // Cron expression
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cron Expression").font(.caption.bold()).foregroundColor(.white.opacity(0.6))
                        TextField("*/5 * * * *", text: $cronExpression)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: cronExpression) { _ in
                                selectedPattern = -1
                                validateExpression()
                            }

                        HStack {
                            Image(systemName: isValid ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundColor(isValid ? .green : .red)
                                .font(.caption)
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundColor(isValid ? .green.opacity(0.8) : .red.opacity(0.8))
                        }

                        // Field reference
                        Text("minute(0-59) hour(0-23) day(1-31) month(1-12) weekday(0-6)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))

                        Text("Keywords: @hourly @daily @weekly @monthly @yearly")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                    }

                    // Next runs preview
                    if !previewRuns.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Next 5 Executions").font(.caption.bold()).foregroundColor(.yellow.opacity(0.7))
                            ForEach(Array(previewRuns.enumerated()), id: \.offset) { _, date in
                                let formatter = DateFormatter()
                                let _ = formatter.dateFormat = "EEE, MMM d yyyy 'at' h:mm a"
                                Text(formatter.string(from: date))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }

                    // Task prompt
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Task Prompt").font(.caption.bold()).foregroundColor(.white.opacity(0.6))
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                    }

                    // Agent
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent").font(.caption.bold()).foregroundColor(.white.opacity(0.6))
                        TextField("sid", text: $agentID)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Options
                    HStack {
                        Toggle("Catch up missed executions", isOn: $catchUp)
                            .font(.caption)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Schedule") {
                    createSchedule()
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .disabled(name.isEmpty || prompt.isEmpty || !isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 680)
        .background(Color(white: 0.12))
        .onAppear { validateExpression() }
    }

    private func validateExpression() {
        let result = CronParser.validate(cronExpression)
        isValid = result.isValid
        validationMessage = result.isValid
            ? (result.description ?? "Valid")
            : (result.error ?? "Invalid expression")
        previewRuns = isValid ? CronParser.nextRuns(cronExpression, count: 5) : []
    }

    private func createSchedule() {
        Task {
            let task = await CronScheduler.shared.createTask(
                name: name,
                cronExpression: cronExpression,
                agentID: agentID,
                prompt: prompt,
                catchUp: catchUp
            )
            await MainActor.run {
                dismiss()
                onComplete(task)
            }
        }
    }
}

// MARK: - Template Sheet

private struct CronTemplateSheet: View {
    let onComplete: (CronTask?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schedule Templates")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Cancel") { dismiss(); onComplete(nil) }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding()
            .background(Color.black)

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(CronTemplates.categories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.capitalized)
                                .font(.caption.bold())
                                .foregroundColor(.yellow.opacity(0.7))
                                .padding(.horizontal)

                            ForEach(CronTemplates.templates(forCategory: category)) { template in
                                TemplateCard(template: template) {
                                    applyTemplate(template)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 520)
        .background(Color(white: 0.12))
    }

    private func applyTemplate(_ template: CronTemplate) {
        Task {
            let task = await CronTaskIntegration.shared.createFromTemplate(template)
            await MainActor.run {
                dismiss()
                onComplete(task)
            }
        }
    }
}

// MARK: - Template Card

private struct TemplateCard: View {
    let template: CronTemplate
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.body.bold())
                    .foregroundColor(.white)
                Text(template.description)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(template.cronExpression)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.yellow.opacity(0.7))
                    Text(template.scheduleDescription)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            Spacer()
            Button("Use") { onApply() }
                .buttonStyle(.bordered)
                .tint(.yellow)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

#endif
