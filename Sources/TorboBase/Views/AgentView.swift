// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agents Panel
// Multi-agent management: list all agents, create new ones, edit personality/permissions per agent.
// SiD is the built-in default and cannot be deleted.
#if canImport(SwiftUI)
import SwiftUI
import AVFoundation

struct AgentsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
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

    // View mode: chat (chat+voice unified), settings, or vox engine config
    @State private var viewMode: AgentViewMode = .chat
    @ObservedObject private var voiceEngine = VoiceEngine.shared
    @ObservedObject private var ttsManager = TTSManager.shared

    enum AgentViewMode: String, CaseIterable {
        case chat = "Chat"
        case settings = "Settings"
        case tasks = "Tasks"
        case voxEngine = "Vox Engine"
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
    @State private var isSwitchingAgent = false

    // Detail panel width tracking for responsive orb
    @State private var detailWidth: CGFloat = 400
    @State private var confirmingFull = false


    // Resizable panes
    @State private var listPaneWidth: CGFloat = 240
    @State private var dragStartWidth: CGFloat = 240
    @State private var chatHistoryHeight: CGFloat = 200
    @State private var chatDragStartHeight: CGFloat = 200

    // Vox Engine
    @State private var voxTestText = "Hello, I'm your AI assistant. How can I help you today?"
    @State private var showAddEngineSheet = false
    @State private var availableSystemVoices: [AVSpeechSynthesisVoice] = []

    // Audio monitoring
    @ObservedObject private var speechRecognizer = SpeechRecognizer.shared

    // Orb collapse (persisted)
    // orbCollapsed removed — orb always visible

    // Chat history / conversations
    @State private var chatHistoryExpanded = true
    @State private var recentSessions: [ConversationSession] = []
    @State private var activeSessionID: UUID?

    // Create agent form
    @State private var newAgentName = ""
    @State private var newAgentRole = "AI assistant"
    @State private var newAgentPreset = "default"

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Agent List (Left)
            agentListPanel
                .frame(width: listPaneWidth)

            // Draggable divider
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
                .overlay(
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    listPaneWidth = max(160, min(400, dragStartWidth + value.translation.width))
                                }
                                .onEnded { _ in
                                    dragStartWidth = listPaneWidth
                                }
                        )
                )

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
        .onChange(of: state.navigateToAgentID) { targetAgentID in
            guard let targetAgentID else { return }
            // Switch to the requested agent
            if let agent = agents.first(where: { $0.id == targetAgentID }) {
                isSwitchingAgent = true
                selectedAgentID = targetAgentID
                editConfig = agent
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    isSwitchingAgent = false
                }
                Task {
                    agentTasks = await TaskQueue.shared.tasksForAgent(targetAgentID)
                    agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
                }
            }
            // Load the requested session if provided
            if let sessionID = state.navigateToSessionID {
                activeSessionID = sessionID
                viewMode = .chat
            }
            // Clear navigation state so it doesn't re-trigger
            state.navigateToAgentID = nil
            state.navigateToSessionID = nil
        }
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
            .padding(.bottom, 8)

            // Create + Import buttons (directly below header)
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
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            // Agent list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(agents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, 8)
            }

            // Draggable horizontal divider above conversations
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .overlay(
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    chatHistoryHeight = max(60, min(400, chatDragStartHeight - value.translation.height))
                                }
                                .onEnded { _ in
                                    chatDragStartHeight = chatHistoryHeight
                                }
                        )
                )

            // Conversations (per-agent)
            chatHistorySection
                .frame(height: chatHistoryHeight)
        }
        .background(Color.black.opacity(0.2))
    }

    private func agentRow(_ agent: AgentConfig) -> some View {
        let isSelected = selectedAgentID == agent.id
        return Button {
            isSwitchingAgent = true
            activeSessionID = nil
            CanvasStore.shared.switchAgent(to: agent.id)
            selectedAgentID = agent.id
            editConfig = agent
            // Allow onChange to settle, then re-enable saving
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                isSwitchingAgent = false
            }
            Task {
                agentTasks = await TaskQueue.shared.tasksForAgent(agent.id)
                agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
            }
        } label: {
            HStack(spacing: 10) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.06))
                    Text(String(agent.name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .white.opacity(0.5))
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
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.06))
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
            .contentShape(Rectangle())
            .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Agent Detail Panel

    private var agentDetailPanel: some View {
        VStack(spacing: 0) {
            // Orb section (collapsible — only the orb graphic itself)
            orbSection
                .padding(.top, 0)
                .padding(.bottom, 8)

            // Model picker — always visible
            modelPickerSection
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            // Action bar: Chat/Settings toggle + buttons
            HStack(spacing: 8) {
                // Custom segmented control — avoids AppKitPopUpAdaptor crash
                HStack(spacing: 0) {
                    ForEach(AgentViewMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: viewMode == mode ? .semibold : .regular))
                                .foregroundStyle(viewMode == mode ? .white : .white.opacity(0.45))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(viewMode == mode ? Color.white.opacity(0.12) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(width: 340)

                Spacer()

                Button {
                    openWindow(id: "canvas")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 10))
                        Text("Canvas")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.cyan.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                }
                .buttonStyle(.plain)

                Button { exportSelectedAgent() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("Export")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                }
                .buttonStyle(.plain)

                Button { showResetConfirm = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                        Text("Reset")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                }
                .buttonStyle(.plain)

                if !editConfig.isBuiltIn {
                    Button { showDeleteConfirm = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Delete")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.red.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.06))

            // View mode switch: Chat, Settings, Tasks, or Vox Engine
            if viewMode == .chat {
                canvasPanel
            } else if viewMode == .voxEngine {
                voxEnginePanel
                    .sheet(isPresented: $showAddEngineSheet) {
                        VStack(spacing: 20) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("Add Voice Engine")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("Additional voice engines (Coqui, Bark, and more) are coming soon.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                                .multilineTextAlignment(.center)
                            Button("OK") { showAddEngineSheet = false }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(40)
                        .frame(width: 320, height: 220)
                        .background(Color(nsColor: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)))
                    }
            } else if viewMode == .tasks {
                tasksPanel
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
                            agentStatPill(value: "\(pending.count)", label: "Queued", color: .white.opacity(0.5))
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
                                        Circle().fill(Color.white.opacity(0.2)).frame(width: 4, height: 4)
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
                                                .fill(Color.white.opacity(0.25))
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
                        .foregroundStyle(.white.opacity(0.4))
                    }

                    // MARK: - Vox (Voice — below Permissions per spec)
                    sectionCard(title: "Vox", icon: "waveform", isExpanded: $voiceExpanded) {
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
                                            .foregroundStyle(isGloballyDisabled ? .red.opacity(0.5) : .white.opacity(0.5))
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
                                            .tint(.white.opacity(0.5))
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
                                                        .foregroundStyle(.white.opacity(0.5))
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
                                .background(editConfig.personalityPreset == preset.id ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
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
        .onChange(of: editConfig.preferredModel) { _ in debouncedSave() }
        .onChange(of: editConfig.enabledCapabilities) { _ in debouncedSave() }
        .onChange(of: editConfig.voiceEngine) { _ in debouncedSave() }
        .onChange(of: editConfig.systemVoiceIdentifier) { _ in debouncedSave() }
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
                            .fill(isOver ? Color.red.opacity(0.6) : (isWarning ? Color.orange.opacity(0.5) : Color.white.opacity(0.3)))
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
        guard !isSwitchingAgent else { return }
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

    // MARK: - Chat History Section

    private var chatHistorySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        chatHistoryExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: chatHistoryExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 12)
                        Text("CONVERSATIONS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .tracking(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // New conversation button
                Button {
                    Task { await startNewConversation() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(4)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New conversation")

                Text("\(recentSessions.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if chatHistoryExpanded {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if recentSessions.isEmpty {
                            Text("No conversations yet")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.2))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(recentSessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .task(id: selectedAgentID) {
            guard let agentID = selectedAgentID else { return }
            recentSessions = await ConversationStore.shared.loadSessions(forAgent: agentID)
        }
    }

    private func startNewConversation() async {
        guard let agentID = selectedAgentID else { return }
        let session = ConversationSession(agentID: agentID)
        var sessions = await ConversationStore.shared.loadSessions()
        sessions.insert(session, at: 0)
        await ConversationStore.shared.saveSessions(sessions)
        activeSessionID = session.id
        recentSessions = await ConversationStore.shared.loadSessions(forAgent: agentID)
    }

    private func sessionRow(_ session: ConversationSession) -> some View {
        let isActive = activeSessionID == session.id
        return Button {
            activeSessionID = session.id
            viewMode = .chat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isActive ? .cyan.opacity(0.6) : .white.opacity(0.25))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 11, weight: isActive ? .bold : .medium))
                        .foregroundStyle(isActive ? .white : .white.opacity(0.6))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(session.messageCount) msgs")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.15))
                        Text(relativeTime(session.lastActivity))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.cyan.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
                    .background(newAgentName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.3) : Color.white.opacity(0.2))
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
                        .foregroundStyle(.white.opacity(0.5))
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
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

    // MARK: - Canvas Panel (unified chat + voice)

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            // Error display
            if let err = speechRecognizer.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.04))
            }

            // Voice transcript overlay
            if isVoiceActive {
                VStack(spacing: 4) {
                    // User transcript (live while listening)
                    if voiceEngine.state == .listening && !speechRecognizer.transcript.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.cyan.opacity(0.5))
                            Text(speechRecognizer.transcript)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.04))
                    }

                    // Last user message
                    if !voiceEngine.lastUserTranscript.isEmpty && voiceEngine.state != .listening {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.3))
                            Text(voiceEngine.lastUserTranscript)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }

                    // Agent response / status
                    if voiceEngine.state == .thinking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                            Text("Thinking...")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.03))
                    } else if voiceEngine.state == .speaking || (!voiceEngine.lastAssistantResponse.isEmpty && voiceEngine.state == .idle) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                                .foregroundStyle(.green.opacity(0.5))
                            Text(voiceEngine.lastAssistantResponse)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(3)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.03))
                    }
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // Chat (embedded without header)
            AgentChatView(
                agentID: editConfig.id,
                agentName: editConfig.name,
                showHeader: false,
                sessionID: activeSessionID
            )
                .id("\(editConfig.id)_\(activeSessionID?.uuidString ?? "")")
                .environmentObject(state)
        }
    }

    // Live audio level meter — shows mic input or TTS output
    private var audioLevelMeter: some View {
        GeometryReader { geo in
            let levels: [Float] = isVoiceActive ? voiceEngine.currentAudioLevels : Array(repeating: Float(0), count: 40)
            let barCount = min(40, Int(geo.size.width / 3))
            let stride = max(1, levels.count / max(barCount, 1))

            HStack(spacing: 1) {
                ForEach(0..<barCount, id: \.self) { i in
                    let idx = min(i * stride, levels.count - 1)
                    let level = CGFloat(levels[idx])
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level > 0.3 ? Color.green : (level > 0.15 ? Color.cyan.opacity(0.6) : Color.white.opacity(0.15)))
                        .frame(width: 2, height: max(2, level * geo.size.height * 0.9))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 20)
    }

    private func applyAgentVoiceSettings() {
        ttsManager.engine = editConfig.voiceEngine
        ttsManager.agentID = editConfig.id
        // Always keep a valid ElevenLabs voice ID for torbo→ElevenLabs fallback
        ttsManager.elevenLabsVoiceID = editConfig.elevenLabsVoiceID.isEmpty ? TTSManager.defaultElevenLabsVoice : editConfig.elevenLabsVoiceID
        ttsManager.systemVoiceIdentifier = editConfig.systemVoiceIdentifier
    }

    // MARK: - Tasks Panel

    private var tasksPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Summary bar
                let pending = agentTasks.filter { $0.status == .pending }
                let running = agentTasks.filter { $0.status == .inProgress }
                let completed = agentTasks.filter { $0.status == .completed }
                let failed = agentTasks.filter { $0.status == .failed }

                HStack(spacing: 12) {
                    agentStatPill(value: "\(running.count)", label: "Running", color: .green)
                    agentStatPill(value: "\(pending.count)", label: "Queued", color: .white.opacity(0.5))
                    agentStatPill(value: "\(completed.count)", label: "Done", color: .white.opacity(0.4))
                    agentStatPill(value: "\(failed.count)", label: "Failed", color: failed.isEmpty ? .white.opacity(0.2) : .red)
                    Spacer()
                }

                // Bulk controls
                if !running.isEmpty || !pending.isEmpty {
                    HStack(spacing: 8) {
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
                                Image(systemName: "stop.fill").font(.system(size: 9))
                                Text("Stop All").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(running.isEmpty ? .white.opacity(0.15) : .red.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(running.isEmpty ? Color.white.opacity(0.02) : Color.red.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .disabled(running.isEmpty)

                        Button {
                            Task {
                                for task in pending {
                                    await TaskQueue.shared.cancelTask(id: task.id)
                                }
                                agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle").font(.system(size: 9))
                                Text("Clear Queue").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(pending.isEmpty ? .white.opacity(0.15) : .orange.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(pending.isEmpty ? Color.white.opacity(0.02) : Color.orange.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .disabled(pending.isEmpty)

                        Spacer()
                    }
                }

                // Running tasks
                if !running.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RUNNING")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.5))
                        ForEach(running, id: \.id) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.6)
                                    Text(task.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .lineLimit(2)
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
                                if let started = task.startedAt {
                                    let elapsed = Date().timeIntervalSince(started)
                                    let fraction = min(elapsed / 120.0, 1.0)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04))
                                            RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.3))
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUEUED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                        ForEach(pending, id: \.id) { task in
                            HStack(spacing: 6) {
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 4, height: 4)
                                Text(task.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
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
                                        .foregroundStyle(.white.opacity(0.2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // History (completed + failed)
                let history = (completed + failed).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HISTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                        ForEach(history.prefix(20), id: \.id) { task in
                            HStack(spacing: 6) {
                                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(task.status == .completed ? .green.opacity(0.5) : .red.opacity(0.5))
                                Text(task.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                                Spacer()
                                if let done = task.completedAt {
                                    Text(relativeTime(done))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.15))
                                }
                            }
                        }
                    }
                }

                // Empty state
                if agentTasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.1))
                        Text("No tasks")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(20)
        }
        .task {
            agentTasks = await TaskQueue.shared.tasksForAgent(editConfig.id)
            agentActiveTasks = await ParallelExecutor.shared.activeTaskIDs
        }
    }

    // MARK: - Vox Engine Panel (per-agent voice config)

    private var voxEnginePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Engine Selection
                voxSectionCard(title: "TTS Engine", icon: "speaker.wave.3.fill") {
                    HStack(spacing: 12) {
                        voxEngineButton(label: "TORBO", subtitle: "On-Device", engine: "torbo", color: .orange)
                        voxEngineButton(label: "System", subtitle: "AVSpeech", engine: "system", color: .cyan)
                        voxEngineButton(label: "ElevenLabs", subtitle: "Cloud AI", engine: "elevenlabs", color: .purple)

                        // Add Engine placeholder
                        Button {
                            showAddEngineSheet = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Add")
                                    .font(.system(size: 8, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.25))
                            .frame(width: 60, height: 48)
                            .background(Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Add voice engine")
                    }

                    // TORBO engine config
                    if editConfig.voiceEngine == "torbo" {
                        let piperEngine = PiperTTSEngine.shared
                        let hasVoice = piperEngine.hasCustomVoice(for: editConfig.id)
                        let hasFallback = piperEngine.hasVoice(for: editConfig.id)
                        let isAvailable = piperEngine.isAvailable

                        voxFieldRow(label: "Voice Status") {
                            HStack(spacing: 6) {
                                if isAvailable && hasVoice {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.system(size: 12))
                                    Text("Custom voice loaded")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.5))
                                } else if isAvailable && hasFallback {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundStyle(.orange)
                                        .font(.system(size: 12))
                                    Text("Using SiD fallback voice")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.5))
                                } else {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .font(.system(size: 12))
                                    Text("Piper not available — will use system voice")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }

                        if let modelName = PiperTTSEngine.agentModels[editConfig.id] {
                            voxFieldRow(label: "Model") {
                                Text(modelName + ".onnx")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }

                    if editConfig.voiceEngine == "elevenlabs" {
                        voxFieldRow(label: "ElevenLabs API Key") {
                            HStack {
                                let hasKey = !(state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty
                                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(hasKey ? .green : .orange)
                                    .font(.system(size: 12))
                                Text(hasKey ? "Configured" : "Not configured — set in Settings → Cloud APIs")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }

                        voxFieldRow(label: "Voice ID") {
                            TextField("e.g. 21m00Tcm4TlvDq8ikWAM", text: $editConfig.elevenLabsVoiceID)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Test button
                    HStack(spacing: 12) {
                        TextField("Test text...", text: $voxTestText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(8)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button {
                            ttsManager.engine = editConfig.voiceEngine
                            ttsManager.agentID = editConfig.id
                            if editConfig.voiceEngine == "elevenlabs" {
                                ttsManager.elevenLabsVoiceID = editConfig.elevenLabsVoiceID.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : editConfig.elevenLabsVoiceID
                            } else if editConfig.voiceEngine == "system" {
                                ttsManager.systemVoiceIdentifier = editConfig.systemVoiceIdentifier
                            }
                            ttsManager.speak(voxTestText)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: ttsManager.isSpeaking ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10))
                                Text(ttsManager.isSpeaking ? "Stop" : "Test")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    if ttsManager.isSpeaking {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.04))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.cyan.opacity(0.5))
                                    .frame(width: geo.size.width * CGFloat(ttsManager.audioLevel))
                            }
                        }
                        .frame(height: 4)
                    }
                }

                // System Voice Selection
                if editConfig.voiceEngine == "system" {
                    voxSectionCard(title: "System Voice", icon: "person.wave.2.fill") {
                        Picker("Voice", selection: $editConfig.systemVoiceIdentifier) {
                            Text("Default").tag("")
                            ForEach(availableSystemVoices, id: \.identifier) { voice in
                                Text("\(voice.name) (\(voice.language))")
                                    .tag(voice.identifier)
                            }
                        }
                        .labelsHidden()

                        HStack(spacing: 12) {
                            Text("Rate")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                            Slider(value: Binding(
                                get: { Double(ttsManager.rate) },
                                set: { ttsManager.rate = Float($0) }
                            ), in: 0.1...1.0)
                            Text(String(format: "%.2f", ttsManager.rate))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 40)
                        }
                    }
                }

                // Speech Recognition (global)
                voxSectionCard(title: "Speech Recognition", icon: "mic.fill") {
                    HStack(spacing: 12) {
                        Image(systemName: AudioEngine.shared.micPermissionGranted ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(AudioEngine.shared.micPermissionGranted ? .green : .red)
                        Text(AudioEngine.shared.micPermissionGranted ? "Microphone access granted" : "Microphone access denied")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        if !AudioEngine.shared.micPermissionGranted {
                            Button("Request") {
                                Task { await AudioEngine.shared.requestMicPermission() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Silence Threshold")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Slider(value: $state.silenceThreshold, in: 0...1)
                        HStack(spacing: 2) {
                            Text(state.silenceThreshold < 0.3 ? "Fast" : (state.silenceThreshold > 0.7 ? "Patient" : "Normal"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(width: 50)
                    }
                }

                // Advanced (global)
                voxSectionCard(title: "Advanced", icon: "slider.horizontal.3") {
                    Toggle("Auto-listen after response", isOn: $state.autoListen)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .toggleStyle(.switch)
                        .tint(.cyan)

                    HStack(spacing: 12) {
                        Text("Voice State")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(voiceEngine.state.rawValue.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(voxStateColor(voiceEngine.state))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(voxStateColor(voiceEngine.state).opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .onAppear {
            availableSystemVoices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
                .sorted { $0.name < $1.name }
        }
    }

    private func voxEngineButton(label: String, subtitle: String, engine: String, color: Color) -> some View {
        Button {
            editConfig.voiceEngine = engine
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(editConfig.voiceEngine == engine ? color : .white.opacity(0.5))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(editConfig.voiceEngine == engine ? color.opacity(0.08) : Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(editConfig.voiceEngine == engine ? color.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func voxStateColor(_ s: VoiceState) -> Color {
        switch s {
        case .idle: return .white.opacity(0.4)
        case .listening: return .green
        case .thinking: return .cyan
        case .speaking: return .orange
        }
    }

    @ViewBuilder
    private func voxSectionCard<C: View>(title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1)
            }
            content()
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
    private func voxFieldRow(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.5)
            content()
        }
    }

    private var voiceStateColor: Color {
        switch voiceEngine.state {
        case .idle: return .white.opacity(0.3)
        case .listening: return .green
        case .thinking: return .cyan
        case .speaking: return .orange
        }
    }

    private var voiceStateText: String {
        guard voiceEngine.isActive, voiceEngine.activeAgentID == editConfig.id else {
            return "Voice Off"
        }
        switch voiceEngine.state {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }

    // MARK: - Model Picker

    private var availableModels: [String] {
        var models: [String] = []
        // Local Ollama models
        models.append(contentsOf: state.ollamaModels)
        // Cloud models based on API keys
        let keys = state.cloudAPIKeys
        if let k = keys["ANTHROPIC_API_KEY"], !k.isEmpty {
            models.append(contentsOf: ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"])
        }
        if let k = keys["OPENAI_API_KEY"], !k.isEmpty {
            models.append(contentsOf: ["gpt-4o", "gpt-4o-mini"])
        }
        if let k = keys["GOOGLE_API_KEY"], !k.isEmpty {
            models.append(contentsOf: ["gemini-2.5-pro-preview-06-05", "gemini-2.0-flash"])
        }
        if let k = keys["XAI_API_KEY"], !k.isEmpty {
            models.append(contentsOf: ["grok-4-latest", "grok-3", "grok-3-fast"])
        }
        return models
    }

    private var modelPickerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.3))

            Text("MODEL")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(1)

            Picker("", selection: $editConfig.preferredModel) {
                Text("Default").tag("")
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Spacer()

            // Per-agent autonomy toggle
            Button { editConfig.autonomyEnabled.toggle() } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(editConfig.autonomyEnabled ? Color.green : Color.white.opacity(0.15))
                        .frame(width: 7, height: 7)
                        .shadow(color: editConfig.autonomyEnabled ? .green.opacity(0.6) : .clear, radius: 4)
                    Text("AUTO")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(editConfig.autonomyEnabled ? .green : .white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(editConfig.autonomyEnabled ? Color.green.opacity(0.15) : Color.white.opacity(0.04))
                )
                .overlay(Capsule().stroke(editConfig.autonomyEnabled ? Color.green.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Orb Section (per-agent orb + name + level picker)

    private var isVoiceActive: Bool { voiceEngine.isActive && voiceEngine.activeAgentID == editConfig.id }
    private var orbSize: CGFloat { min(detailWidth * 0.78, 560) }
    private var glowSize: CGFloat { orbSize * 1.3 }

    private var agentVoiceStateColor: Color {
        switch voiceEngine.state {
        case .idle:      return .gray
        case .listening: return .green
        case .thinking:  return .orange
        case .speaking:  return .cyan
        }
    }

    private var orbSection: some View {
        VStack(spacing: 0) {
            // Control panel — mic, agent name/status, speaker, power
            HStack(spacing: 12) {
                Button { voiceEngine.isMicMuted.toggle() } label: {
                    Image(systemName: voiceEngine.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(voiceEngine.isMicMuted ? .red : .white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Spacer()

                // Agent name + voice state (centered)
                HStack(spacing: 6) {
                    if isVoiceActive {
                        Circle()
                            .fill(agentVoiceStateColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(editConfig.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .tracking(2)
                    if isVoiceActive {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.3))
                        Text(voiceEngine.state.rawValue.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }

                Spacer()

                Button { voiceEngine.isMuted.toggle() } label: {
                    Image(systemName: voiceEngine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(voiceEngine.isMuted ? .red : .white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)

                // Power button — power up/down this agent
                Button {
                    if editConfig.accessLevel > 0 {
                        // Power down — save current level, set to OFF
                        previousAgentLevel = editConfig.accessLevel
                        editConfig.accessLevel = 0
                        if isVoiceActive { voiceEngine.deactivate() }
                        debouncedSave()
                    } else {
                        // Power up — restore previous level
                        editConfig.accessLevel = previousAgentLevel > 0 ? previousAgentLevel : 2
                        debouncedSave()
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(editConfig.accessLevel > 0 ? .green : .red.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(editConfig.accessLevel > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(editConfig.accessLevel > 0 ? "Power down agent" : "Power up agent")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            // Orb graphic
            ZStack {
                OrbRenderer(
                    audioLevels: voiceEngine.currentAudioLevels,
                    color: AccessLevel(rawValue: editConfig.accessLevel)?.color ?? .gray,
                    isActive: isVoiceActive || editConfig.accessLevel > 0,
                    orbRadius: orbSize * 0.38
                )
                .id("\(editConfig.id)-\(editConfig.accessLevel)")
                .onTapGesture {
                    if viewMode == .chat {
                        if isVoiceActive {
                            voiceEngine.handleOrbTap()
                        } else {
                            voiceEngine.activate(agentID: editConfig.id)
                            voiceEngine.listen()
                        }
                    }
                }

                // Level overlay on orb (hidden when voice is active)
                if !isVoiceActive {
                    VStack(spacing: 2) {
                        Text("\(editConfig.accessLevel)")
                            .font(.system(size: min(orbSize * 0.18, 36), weight: .ultraLight, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(AccessLevel(rawValue: editConfig.accessLevel)?.name ?? "OFF")
                            .font(.system(size: min(orbSize * 0.06, 10), weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                            .tracking(2)
                    }
                }
            }
            .frame(width: orbSize, height: orbSize)
            .background(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (AccessLevel(rawValue: editConfig.accessLevel)?.color ?? .gray).opacity(0.15),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: orbSize * 0.2,
                            endRadius: glowSize * 0.5
                        )
                    )
                    .frame(width: glowSize, height: glowSize)
                    .allowsHitTesting(false)
            )
            .frame(maxWidth: .infinity)

            // Tap-based level picker
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    if let level = AccessLevel(rawValue: i) {
                        Button {
                            if i == 5 && editConfig.accessLevel != 5 {
                                confirmingFull = true
                            } else {
                                if i == 0 { previousAgentLevel = editConfig.accessLevel }
                                editConfig.accessLevel = i
                                debouncedSave()
                            }
                        } label: {
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(i <= editConfig.accessLevel ? level.color : Color.white.opacity(0.06))
                                    .frame(height: i == editConfig.accessLevel ? 8 : 4)
                                Text(level.name)
                                    .font(.system(size: min(detailWidth * 0.02, 11), weight: .bold, design: .monospaced))
                                    .foregroundStyle(i == editConfig.accessLevel ? .white.opacity(0.8) : .white.opacity(0.25))
                                    .minimumScaleFactor(0.6)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .padding(.horizontal, 24)
        }
        .alert("Enable Full Access?", isPresented: $confirmingFull) {
            Button("Enable Full Access", role: .destructive) {
                editConfig.accessLevel = 5
                debouncedSave()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Full Access (Level 5) gives this agent unrestricted system access. Are you sure?")
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: DetailWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(DetailWidthKey.self) { detailWidth = $0 }
    }
}

private struct DetailWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
#endif
