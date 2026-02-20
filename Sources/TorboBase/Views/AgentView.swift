// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agents Panel
// Multi-agent management: list all agents, create new ones, edit personality/permissions per agent.
// SiD is the built-in default and cannot be deleted.
#if canImport(SwiftUI)
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var state: AppState
    @State private var agents: [AgentConfig] = []
    @State private var selectedAgentID: String? = "sid"
    @State private var editConfig: AgentConfig = AgentConfig.newAgent(id: "sid", name: "SiD")
    @State private var isLoading = true
    @State private var showCreateSheet = false
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var expandedCategories: Set<String> = []
    @State private var importError: String?
    @State private var showImportError = false

    // View mode: settings vs chat
    @State private var viewMode: AgentViewMode = .settings

    enum AgentViewMode: String, CaseIterable {
        case chat = "Chat"
        case settings = "Settings"
    }

    // Section expansion (all collapsed by default)
    @State private var permissionsExpanded = false
    @State private var voiceExpanded = false
    @State private var capabilitiesExpanded = false
    @State private var personalityExpanded = false
    @State private var activityExpanded = false
    @State private var tokenBudgetExpanded = false

    // Token usage data
    @State private var tokenDaily: Int = 0
    @State private var tokenWeekly: Int = 0
    @State private var tokenMonthly: Int = 0
    @State private var tokenCost30d: Double = 0
    @State private var tokenHistory: [(date: String, tokens: Int)] = []

    // Per-agent task data
    @State private var agentTasks: [TaskQueue.AgentTask] = []
    @State private var agentActiveTasks: [String] = []
    @State private var previousAgentLevel: Int = 1

    // Auto-save debounce
    @State private var saveTask: Task<Void, Never>?

    // Create agent form
    @State private var newAgentName = ""
    @State private var newAgentRole = "AI assistant"
    @State private var newAgentPreset = "default"

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Agent List (Left)
            agentListPanel
                .frame(width: 240)

            Divider()
                .background(Color.white.opacity(0.06))

            // MARK: - Agent Detail (Right)
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                agentDetailPanel
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await loadAgents() }
        .sheet(isPresented: $showCreateSheet) { createAgentSheet }
        .alert("Delete Agent?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteSelectedAgent() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \"\(editConfig.name)\" and all its settings.")
        }
        .alert("Reset to Defaults?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { Task { await resetSelectedAgent() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all customization for \"\(editConfig.name)\" to defaults.")
        }
        .alert("Import Failed", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    // MARK: - Agent List Panel

    private var agentListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AGENTS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1)
                Spacer()
                Text("\(agents.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Agent list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(agents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().background(Color.white.opacity(0.06))

            // Create + Import buttons
            HStack(spacing: 0) {
                Button {
                    showCreateSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("Create")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 20).background(Color.white.opacity(0.06))

                Button {
                    importAgent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                        Text("Import")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.cyan)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.black.opacity(0.2))
    }

    private func agentRow(_ agent: AgentConfig) -> some View {
        let isSelected = selectedAgentID == agent.id
        return Button {
            selectedAgentID = agent.id
            editConfig = agent
            Task {
                agentTasks = await TaskQueue.shared.tasksForAgent(agent.id)
                agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
            }
        } label: {
            HStack(spacing: 10) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.cyan.opacity(0.2) : Color.white.opacity(0.06))
                    Text(String(agent.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? .cyan : .white.opacity(0.5))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                        if agent.isBuiltIn {
                            Text("BUILT-IN")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.6))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.cyan.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(agent.role.isEmpty ? "Agent" : agent.role)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }

                Spacer()

                // Access level badge
                let levelNames = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
                let lvl = min(agent.accessLevel, 5)
                Text(levelNames[lvl])
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(AccessLevel(rawValue: lvl)?.color ?? .gray)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background((AccessLevel(rawValue: lvl)?.color ?? .gray).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Agent Detail Panel

    private var agentDetailPanel: some View {
        VStack(spacing: 0) {
            // Header with view mode toggle
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(editConfig.name)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            // Status indicator
                            let isActive = agentActiveTasks.contains(where: { $0.hasPrefix(editConfig.id) })
                            let isOff = editConfig.accessLevel == 0
                            Circle()
                                .fill(isOff ? Color.red : (isActive ? Color.green : Color.white.opacity(0.15)))
                                .frame(width: 8, height: 8)
                            if isOff {
                                Text("OFF")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.red.opacity(0.7))
                            } else if isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green.opacity(0.7))
                            }
                        }
                        Text(editConfig.isBuiltIn ? "Built-in agent — cannot be deleted" : "Custom agent — id: \(editConfig.id)")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        // Chat / Settings toggle
                        Picker("", selection: $viewMode) {
                            ForEach(AgentViewMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)

                        Divider().frame(height: 20).background(Color.white.opacity(0.06))

                        // Per-agent kill switch
                        Toggle(isOn: Binding(
                            get: { editConfig.accessLevel > 0 },
                            set: { enabled in
                                if enabled {
                                    // Restore to CHAT (1) as minimum when re-enabling
                                    editConfig.accessLevel = max(previousAgentLevel, 1)
                                } else {
                                    previousAgentLevel = editConfig.accessLevel
                                    editConfig.accessLevel = 0
                                    // Cancel all running tasks for this agent
                                    Task {
                                        for task in agentTasks where task.status == .inProgress || task.status == .pending {
                                            await TaskQueue.shared.cancelTask(id: task.id)
                                            await ParallelExecutor.shared.cancel(taskID: task.id)
                                        }
                                        agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                                        agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
                                    }
                                }
                                debouncedSave()
                            }
                        )) {
                            Text(editConfig.accessLevel > 0 ? "Enabled" : "Killed")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(editConfig.accessLevel > 0 ? .green.opacity(0.7) : .red.opacity(0.7))
                        }
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                        .tint(.green)

                        Divider().frame(height: 20).background(Color.white.opacity(0.06))

                        Button("Export") { exportSelectedAgent() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.cyan.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.cyan.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button("Reset") { showResetConfirm = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        if !editConfig.isBuiltIn {
                            Button("Delete") { showDeleteConfirm = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red.opacity(0.6))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }

            // View mode switch: Chat or Settings
            if viewMode == .chat {
                AgentChatView(agentID: editConfig.id, agentName: editConfig.name)
                    .environmentObject(state)
            } else {
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                VStack(spacing: 16) {

                    // MARK: - Activity & Tasks
                    sectionCard(title: "Activity", icon: "chart.bar.fill", isExpanded: $activityExpanded) {
                        let pending = agentTasks.filter { $0.status == .pending }
                        let running = agentTasks.filter { $0.status == .inProgress }
                        let completed = agentTasks.filter { $0.status == .completed }
                        let failed = agentTasks.filter { $0.status == .failed }

                        HStack(spacing: 12) {
                            agentStatPill(value: "\(running.count)", label: "Running", color: .green)
                            agentStatPill(value: "\(pending.count)", label: "Queued", color: .cyan)
                            agentStatPill(value: "\(completed.count)", label: "Done", color: .white.opacity(0.4))
                            agentStatPill(value: "\(failed.count)", label: "Failed", color: failed.isEmpty ? .white.opacity(0.2) : .red)
                        }

                        // Task controls
                        if !running.isEmpty || !pending.isEmpty {
                            HStack(spacing: 8) {
                                // Stop all running tasks
                                Button {
                                    Task {
                                        for task in running {
                                            await ParallelExecutor.shared.cancel(taskID: task.id)
                                            await TaskQueue.shared.cancelTask(id: task.id)
                                        }
                                        agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                                        agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 9))
                                        Text("Stop")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(running.isEmpty ? .white.opacity(0.15) : .red.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(running.isEmpty ? Color.white.opacity(0.02) : Color.red.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .disabled(running.isEmpty)

                                // Clear queued tasks
                                Button {
                                    Task {
                                        for task in pending {
                                            await TaskQueue.shared.cancelTask(id: task.id)
                                        }
                                        agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark.circle")
                                            .font(.system(size: 9))
                                        Text("Clear Queue")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(pending.isEmpty ? .white.opacity(0.15) : .orange.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(pending.isEmpty ? Color.white.opacity(0.02) : Color.orange.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .disabled(pending.isEmpty)

                                Spacer()
                            }
                        }

                        // Running tasks with progress + cancel
                        if !running.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(running, id: \.id) { task in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                            Text(task.title)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.7))
                                                .lineLimit(1)
                                            Spacer()
                                            if let started = task.startedAt {
                                                Text(relativeTime(started))
                                                    .font(.system(size: 9, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.2))
                                            }
                                            Button {
                                                Task {
                                                    await ParallelExecutor.shared.cancel(taskID: task.id)
                                                    await TaskQueue.shared.cancelTask(id: task.id)
                                                    agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                                                    agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
                                                }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundStyle(.red.opacity(0.5))
                                                    .padding(4)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        // Elapsed time progress bar
                                        if let started = task.startedAt {
                                            let elapsed = Date().timeIntervalSince(started)
                                            let fraction = min(elapsed / 120.0, 1.0) // 2-min visual cap
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(Color.white.opacity(0.04))
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(Color.green.opacity(0.3))
                                                        .frame(width: geo.size.width * fraction)
                                                }
                                            }
                                            .frame(height: 3)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.green.opacity(0.04))
                                    .cornerRadius(4)
                                }
                            }
                        }

                        // Queued tasks
                        if !pending.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("QUEUED")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.2))
                                ForEach(pending.prefix(5), id: \.id) { task in
                                    HStack(spacing: 6) {
                                        Circle().fill(Color.cyan.opacity(0.3)).frame(width: 4, height: 4)
                                        Text(task.title)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.4))
                                            .lineLimit(1)
                                        Spacer()
                                        Button {
                                            Task {
                                                await TaskQueue.shared.cancelTask(id: task.id)
                                                agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 7))
                                                .foregroundStyle(.white.opacity(0.15))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if pending.count > 5 {
                                    Text("+ \(pending.count - 5) more")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.2))
                                }
                            }
                        }

                        // Completed task history
                        if !completed.isEmpty || !failed.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HISTORY")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.2))
                                ForEach((completed + failed).sorted(by: { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }).prefix(8), id: \.id) { task in
                                    HStack(spacing: 6) {
                                        Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(task.status == .completed ? .green.opacity(0.5) : .red.opacity(0.5))
                                        Text(task.title)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.35))
                                            .lineLimit(1)
                                        Spacer()
                                        if let done = task.completedAt {
                                            Text(relativeTime(done))
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.15))
                                        }
                                    }
                                }
                            }
                        }

                        if agentTasks.isEmpty {
                            Text("No tasks assigned to this agent")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }

                    // MARK: - Permissions (expanded by default is useful — but user asked collapsed)
                    sectionCard(title: "Permissions", icon: "lock.shield", isExpanded: $permissionsExpanded) {
                        fieldRow(label: "Access Level") {
                            Picker("", selection: $editConfig.accessLevel) {
                                Text("OFF (0)").tag(0)
                                Text("CHAT (1)").tag(1)
                                Text("READ (2)").tag(2)
                                Text("WRITE (3)").tag(3)
                                Text("EXEC (4)").tag(4)
                                Text("FULL (5)").tag(5)
                            }
                            .pickerStyle(.segmented)
                        }
                        fieldRow(label: "Directory Scopes (one per line, empty = unrestricted)") {
                            TextEditor(text: Binding(
                                get: { editConfig.directoryScopes.joined(separator: "\n") },
                                set: { editConfig.directoryScopes = $0.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
                            ))
                                .font(.system(size: 13, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 40)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // MARK: - Token Budget
                    sectionCard(title: "Token Budget", icon: "gauge.with.dots.needle.33percent", isExpanded: $tokenBudgetExpanded) {
                        // Usage summary
                        HStack(spacing: 12) {
                            tokenUsagePill(label: "Today", used: tokenDaily, limit: editConfig.dailyTokenLimit)
                            tokenUsagePill(label: "Week", used: tokenWeekly, limit: editConfig.weeklyTokenLimit)
                            tokenUsagePill(label: "Month", used: tokenMonthly, limit: editConfig.monthlyTokenLimit)
                            VStack(spacing: 2) {
                                Text(String(format: "$%.2f", tokenCost30d))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green)
                                Text("30d cost")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.04))
                            .cornerRadius(6)
                        }

                        // 7-day usage chart
                        if !tokenHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("LAST 7 DAYS")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.2))
                                HStack(alignment: .bottom, spacing: 4) {
                                    let maxTokens = max(tokenHistory.map(\.tokens).max() ?? 1, 1)
                                    ForEach(Array(tokenHistory.enumerated()), id: \.offset) { _, day in
                                        VStack(spacing: 2) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.cyan.opacity(0.4))
                                                .frame(height: max(CGFloat(day.tokens) / CGFloat(maxTokens) * 60, 2))
                                            Text(day.date)
                                                .font(.system(size: 7, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.2))
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                .frame(height: 80)
                            }
                        }

                        // Budget settings
                        fieldRow(label: "Daily Limit (0 = unlimited)") {
                            TextField("", value: $editConfig.dailyTokenLimit, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .frame(width: 120)
                        }
                        fieldRow(label: "Weekly Limit") {
                            TextField("", value: $editConfig.weeklyTokenLimit, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .frame(width: 120)
                        }
                        fieldRow(label: "Monthly Limit") {
                            TextField("", value: $editConfig.monthlyTokenLimit, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .frame(width: 120)
                        }
                        Toggle("Hard stop at budget (agent refuses requests)", isOn: $editConfig.hardStopOnBudget)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .toggleStyle(.switch)
                            .tint(.red)
                            .scaleEffect(0.8, anchor: .leading)

                        Button("Refresh Usage") {
                            Task { await refreshTokenUsage() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.6))
                    }

                    // MARK: - Voice (below Permissions per spec)
                    sectionCard(title: "Voice", icon: "waveform", isExpanded: $voiceExpanded) {
                        fieldRow(label: "ElevenLabs Voice ID") {
                            TextField("Voice ID or leave empty", text: $editConfig.elevenLabsVoiceID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        fieldRow(label: "Fallback TTS Voice") {
                            Picker("", selection: $editConfig.fallbackTTSVoice) {
                                Text("alloy").tag("alloy")
                                Text("echo").tag("echo")
                                Text("fable").tag("fable")
                                Text("onyx").tag("onyx")
                                Text("nova").tag("nova")
                                Text("shimmer").tag("shimmer")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 400)
                        }
                    }

                    // MARK: - Capabilities (collapsed)
                    sectionCard(title: "Capabilities", icon: "cpu", isExpanded: $capabilitiesExpanded) {
                        let agentLevel = AccessLevel(rawValue: editConfig.accessLevel) ?? .chatOnly
                        let globalCaps = AppState.shared.globalCapabilities
                        ForEach(CapabilityCategory.allCases, id: \.self) { category in
                            let tools = CapabilityRegistry.byCategory[category] ?? []
                            let availableTools = tools.filter { tool in
                                agentLevel.rawValue >= tool.minimumAccessLevel.rawValue
                            }
                            #if !os(macOS)
                            let platformTools = availableTools.filter { !$0.macOnly }
                            #else
                            let platformTools = availableTools
                            #endif
                            if !platformTools.isEmpty {
                                let isGloballyDisabled = globalCaps[category.rawValue] == false
                                let isExpanded = expandedCategories.contains(category.rawValue)
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 10) {
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.3))
                                            .frame(width: 12)
                                        Image(systemName: category.icon)
                                            .font(.system(size: 13))
                                            .foregroundStyle(isGloballyDisabled ? .red.opacity(0.5) : .cyan)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(category.label)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.white.opacity(isGloballyDisabled ? 0.3 : 0.9))
                                            Text("\(platformTools.count) tool\(platformTools.count == 1 ? "" : "s")\(isGloballyDisabled ? " · Globally disabled" : "")")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.3))
                                        }
                                        Spacer()
                                        if isGloballyDisabled {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.red.opacity(0.5))
                                        } else {
                                            Toggle("", isOn: Binding(
                                                get: { editConfig.enabledCapabilities[category.rawValue] != false },
                                                set: { enabled in
                                                    if enabled {
                                                        editConfig.enabledCapabilities.removeValue(forKey: category.rawValue)
                                                    } else {
                                                        editConfig.enabledCapabilities[category.rawValue] = false
                                                    }
                                                }
                                            ))
                                            .toggleStyle(.switch)
                                            .labelsHidden()
                                            .scaleEffect(0.8)
                                            .tint(.cyan)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if isExpanded {
                                                expandedCategories.remove(category.rawValue)
                                            } else {
                                                expandedCategories.insert(category.rawValue)
                                            }
                                        }
                                    }
                                    if isExpanded {
                                        VStack(alignment: .leading, spacing: 3) {
                                            ForEach(platformTools, id: \.toolName) { tool in
                                                HStack(spacing: 8) {
                                                    Text(tool.toolName)
                                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                        .foregroundStyle(.cyan.opacity(0.7))
                                                    Text("—")
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.white.opacity(0.15))
                                                    Text(tool.description)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.white.opacity(0.4))
                                                    Spacer()
                                                }
                                            }
                                        }
                                        .padding(.leading, 44)
                                        .padding(.vertical, 4)
                                        .transition(.opacity)
                                    }
                                }
                            }
                        }
                    }

                    // MARK: - Personality (merged: identity + personality + values + knowledge)
                    sectionCard(title: "Personality & Identity", icon: "theatermasks", isExpanded: $personalityExpanded) {
                        // Personality preset pills
                        HStack(spacing: 8) {
                            ForEach(AgentConfig.presets, id: \.id) { preset in
                                Button(preset.label) {
                                    editConfig.voiceTone = preset.voiceTone
                                    editConfig.coreValues = preset.coreValues
                                    editConfig.personalityPreset = preset.id
                                    debouncedSave()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: editConfig.personalityPreset == preset.id ? .bold : .medium))
                                .foregroundStyle(editConfig.personalityPreset == preset.id ? .black : .white.opacity(0.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(editConfig.personalityPreset == preset.id ? Color.cyan : Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .padding(.bottom, 4)

                        fieldRow(label: "Name") {
                            TextField("Agent name", text: $editConfig.name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        HStack(spacing: 16) {
                            fieldRow(label: "Pronouns") {
                                Picker("", selection: $editConfig.pronouns) {
                                    Text("she/her").tag("she/her")
                                    Text("he/him").tag("he/him")
                                    Text("they/them").tag("they/them")
                                }
                                .pickerStyle(.segmented)
                            }
                            fieldRow(label: "Role") {
                                TextField("AI assistant, Engineer...", text: $editConfig.role)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 14))
                                    .padding(8)
                                    .background(Color.white.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        fieldRow(label: "Voice & Tone") {
                            TextEditor(text: $editConfig.voiceTone)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 50)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        fieldRow(label: "Core Values") {
                            TextEditor(text: $editConfig.coreValues)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 50)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        fieldRow(label: "Topics to Avoid") {
                            TextEditor(text: $editConfig.topicsToAvoid)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 30)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        fieldRow(label: "Custom Instructions") {
                            TextEditor(text: $editConfig.customInstructions)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 50)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        fieldRow(label: "Background Knowledge") {
                            TextEditor(text: $editConfig.backgroundKnowledge)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 60)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            } // ScrollView
            } // else (settings mode)
        }
        .onChange(of: editConfig.accessLevel) { _ in debouncedSave() }
        .onChange(of: editConfig.name) { _ in debouncedSave() }
        .onChange(of: editConfig.role) { _ in debouncedSave() }
        .onChange(of: editConfig.pronouns) { _ in debouncedSave() }
        .onChange(of: editConfig.voiceTone) { _ in debouncedSave() }
        .onChange(of: editConfig.coreValues) { _ in debouncedSave() }
        .onChange(of: editConfig.topicsToAvoid) { _ in debouncedSave() }
        .onChange(of: editConfig.customInstructions) { _ in debouncedSave() }
        .onChange(of: editConfig.backgroundKnowledge) { _ in debouncedSave() }
        .onChange(of: editConfig.elevenLabsVoiceID) { _ in debouncedSave() }
        .onChange(of: editConfig.fallbackTTSVoice) { _ in debouncedSave() }
        .onChange(of: editConfig.personalityPreset) { _ in debouncedSave() }
        .onChange(of: editConfig.dailyTokenLimit) { _ in debouncedSave() }
        .onChange(of: editConfig.weeklyTokenLimit) { _ in debouncedSave() }
        .onChange(of: editConfig.monthlyTokenLimit) { _ in debouncedSave() }
        .onChange(of: editConfig.hardStopOnBudget) { _ in debouncedSave() }
        .onChange(of: selectedAgentID) { _ in Task { await refreshTokenUsage() } }
    }

    @ViewBuilder
    private func tokenUsagePill(label: String, used: Int, limit: Int) -> some View {
        let pct = limit > 0 ? min(Double(used) / Double(limit), 1.0) : 0
        let isWarning = pct >= 0.8
        let isOver = pct >= 1.0
        VStack(spacing: 2) {
            Text(formatTokenCount(used))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(isOver ? .red : (isWarning ? .orange : .white.opacity(0.7)))
            if limit > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isOver ? Color.red.opacity(0.6) : (isWarning ? Color.orange.opacity(0.5) : Color.cyan.opacity(0.4)))
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(height: 3)
                Text("\(Int(pct * 100))% of \(formatTokenCount(limit))")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
            }
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isOver ? Color.red.opacity(0.04) : Color.white.opacity(0.02))
        .cornerRadius(6)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func refreshTokenUsage() async {
        let id = editConfig.id
        tokenDaily = await TokenTracker.shared.dailyUsage(agentID: id)
        tokenWeekly = await TokenTracker.shared.weeklyUsage(agentID: id)
        tokenMonthly = await TokenTracker.shared.monthlyUsage(agentID: id)
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        tokenCost30d = await TokenTracker.shared.estimatedCost(agentID: id, since: monthAgo)
        tokenHistory = await TokenTracker.shared.dailyHistory(agentID: id, days: 7)
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await saveConfig()
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    @ViewBuilder
    private func agentStatPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.04))
        .cornerRadius(6)
    }

    // MARK: - Create Agent Sheet

    private var createAgentSheet: some View {
        VStack(spacing: 20) {
            Text("Create Agent")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                fieldRow(label: "Name") {
                    TextField("e.g. Rex, Nova, Atlas...", text: $newAgentName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                fieldRow(label: "Role") {
                    TextField("AI assistant, Code reviewer, Writing partner...", text: $newAgentRole)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                fieldRow(label: "Personality") {
                    Picker("", selection: $newAgentPreset) {
                        ForEach(AgentConfig.presets, id: \.id) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text("Default access level: CHAT (1). You can change this after creation.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }

            HStack(spacing: 12) {
                Button("Cancel") { showCreateSheet = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Create") { Task { await createAgent() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(newAgentName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(newAgentName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(Color(white: 0.1))
    }

    // MARK: - Data Operations

    private func loadAgents() async {
        agents = await AgentConfigManager.shared.listAgents()
        if let first = agents.first(where: { $0.id == selectedAgentID }) ?? agents.first {
            selectedAgentID = first.id
            editConfig = first
        }
        // Load per-agent task data
        if let id = selectedAgentID {
            agentTasks = await TaskQueue.shared.tasksForAgent(id)
            agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
        }
        isLoading = false
    }

    private func saveConfig() async {
        await AgentConfigManager.shared.updateAgent(editConfig)
        await MainActor.run { state.refreshAgentLevels() }
        await loadAgents()
    }

    private func createAgent() async {
        let name = newAgentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = AgentConfig.slugify(name)

        var config = AgentConfig.newAgent(id: id, name: name, role: newAgentRole)
        // Apply selected preset
        if let preset = AgentConfig.presets.first(where: { $0.id == newAgentPreset }) {
            config.voiceTone = preset.voiceTone
            config.coreValues = preset.coreValues
            config.personalityPreset = preset.id
        }

        do {
            try await AgentConfigManager.shared.createAgent(config)
            await MainActor.run { state.refreshAgentLevels() }
            selectedAgentID = id
            editConfig = config
            newAgentName = ""
            newAgentRole = "AI assistant"
            newAgentPreset = "default"
            showCreateSheet = false
            await loadAgents()
        } catch {
            TorboLog.error("Create failed: \(error.localizedDescription)", subsystem: "AgentView")
        }
    }

    private func deleteSelectedAgent() async {
        guard let id = selectedAgentID else { return }
        do {
            try await AgentConfigManager.shared.deleteAgent(id)
            await MainActor.run { state.refreshAgentLevels() }
            selectedAgentID = "sid"
            await loadAgents()
        } catch {
            TorboLog.error("Delete failed: \(error.localizedDescription)", subsystem: "AgentView")
        }
    }

    private func resetSelectedAgent() async {
        guard let id = selectedAgentID else { return }
        await AgentConfigManager.shared.resetAgent(id)
        await loadAgents()
    }

    private func importAgent() {
        let panel = NSOpenPanel()
        panel.title = "Import Agent"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try Data(contentsOf: url)
                let success = await AgentConfigManager.shared.importAgent(data)
                if success {
                    await MainActor.run { state.refreshAgentLevels() }
                    await loadAgents()
                } else {
                    await MainActor.run {
                        importError = "Invalid agent config format"
                        showImportError = true
                    }
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
    }

    private func exportSelectedAgent() {
        guard let id = selectedAgentID else { return }
        Task {
            guard let data = await AgentConfigManager.shared.exportAgent(id) else { return }
            await MainActor.run {
                let panel = NSSavePanel()
                panel.title = "Export Agent"
                panel.nameFieldStringValue = "\(id).json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - UI Helpers

    @ViewBuilder
    private func sectionCard<C: View>(title: String, icon: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.cyan)
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .tracking(1)
                }
            }
            .accentColor(.white.opacity(0.3))
        }
        .padding(20)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func fieldRow(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }
}
#endif
