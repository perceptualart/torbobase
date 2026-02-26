// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent Teams Management View
// Create, edit, test, and manage multi-agent teams.

import Foundation
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Agent Teams View

struct AgentTeamsView: View {
    @EnvironmentObject private var state: AppState
    @State private var teams: [AgentTeam] = []
    @State private var selectedTeamID: String?
    @State private var showCreateSheet = false
    @State private var showTestSheet = false
    @State private var executionHistory: [TeamExecution] = []
    @State private var isLoading = false

    var body: some View {
        HSplitView {
            // Left: Team List
            teamListPanel
                .frame(minWidth: 240, maxWidth: 300)

            // Right: Detail
            if let teamID = selectedTeamID, let team = teams.first(where: { $0.id == teamID }) {
                teamDetailPanel(team)
            } else {
                emptyState
            }
        }
        .onAppear { loadTeams() }
        .sheet(isPresented: $showCreateSheet) {
            CreateTeamSheet { newTeam in
                Task {
                    let created = await TeamCoordinator.shared.createTeam(newTeam)
                    await MainActor.run {
                        teams.append(created)
                        selectedTeamID = created.id
                    }
                }
            }
        }
        .sheet(isPresented: $showTestSheet) {
            if let teamID = selectedTeamID {
                TestTeamSheet(teamID: teamID)
            }
        }
    }

    // MARK: - Team List Panel

    private var teamListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Agent Teams")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Create new team")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.06))

            if teams.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No teams yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Create Team") { showCreateSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(teams) { team in
                            teamRow(team)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color.black.opacity(0.2))
    }

    private func teamRow(_ team: AgentTeam) -> some View {
        Button {
            selectedTeamID = team.id
            loadHistory(teamID: team.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(selectedTeamID == team.id ? .white : .secondary)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedTeamID == team.id ? .white : .primary)
                    Text("\(team.memberAgentIDs.count + 1) agents")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTeamID == team.id ? Color.blue.opacity(0.3) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a team")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Create or select a team to view details")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Team Detail Panel

    private func teamDetailPanel(_ team: AgentTeam) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(team.name)
                            .font(.system(size: 18, weight: .bold))
                        if !team.description.isEmpty {
                            Text(team.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    Button("Test Team") { showTestSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    Button(role: .destructive) {
                        Task {
                            let _ = await TeamCoordinator.shared.deleteTeam(team.id)
                            await MainActor.run {
                                teams.removeAll { $0.id == team.id }
                                selectedTeamID = nil
                            }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.7))
                    .help("Delete team")
                }

                Divider()

                // Coordinator
                sectionHeader("Coordinator", icon: "crown.fill")
                agentBadge(team.coordinatorAgentID, role: "Coordinator")

                // Members
                sectionHeader("Members", icon: "person.2.fill")
                FlowLayout(spacing: 6) {
                    ForEach(team.memberAgentIDs, id: \.self) { memberID in
                        agentBadge(memberID, role: "Member")
                    }
                }

                // Shared Context
                sectionHeader("Shared Context", icon: "doc.text.fill")
                SharedContextViewer(teamID: team.id)

                // Execution History
                sectionHeader("Execution History", icon: "clock.fill")
                if executionHistory.isEmpty {
                    Text("No executions yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 4) {
                        ForEach(executionHistory) { execution in
                            executionRow(execution)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.top, 4)
    }

    private func agentBadge(_ agentID: String, role: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(role == "Coordinator" ? Color.orange : Color.blue)
                .frame(width: 8, height: 8)
            Text(agentID)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text("(\(role))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func executionRow(_ execution: TeamExecution) -> some View {
        HStack {
            Circle()
                .fill(executionStatusColor(execution.status))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(execution.taskDescription.prefix(60))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(execution.status.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let duration = execution.durationSeconds {
                        Text("\(duration)s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(execution.subtaskCount) subtasks")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(execution.startedAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func executionStatusColor(_ status: TeamTaskStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .running, .decomposing, .aggregating: return .orange
        case .cancelled: return .gray
        case .pending: return .blue
        }
    }

    // MARK: - Data Loading

    private func loadTeams() {
        Task {
            let loaded = await TeamCoordinator.shared.listTeams()
            await MainActor.run { teams = loaded }
        }
    }

    private func loadHistory(teamID: String) {
        Task {
            let history = await TeamCoordinator.shared.getExecutionHistory(teamID: teamID)
            await MainActor.run { executionHistory = history }
        }
    }
}

// MARK: - Create Team Sheet

struct CreateTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var coordinatorID = "sid"
    @State private var memberIDs: [String] = []
    @State private var availableAgents: [String] = []
    @State private var newMemberID = ""

    let onCreate: (AgentTeam) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Agent Team")
                .font(.system(size: 15, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Team Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $description)
                    .textFieldStyle(.roundedBorder)

                // Coordinator picker
                HStack {
                    Text("Coordinator:")
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $coordinatorID) {
                        ForEach(availableAgents, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                }

                // Members
                Text("Members:")
                    .font(.system(size: 12, weight: .medium))

                ForEach(memberIDs, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            memberIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                }

                HStack {
                    Picker("Add member", selection: $newMemberID) {
                        Text("Select agent...").tag("")
                        ForEach(availableAgents.filter { !memberIDs.contains($0) && $0 != coordinatorID }, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()

                    Button("Add") {
                        if !newMemberID.isEmpty && !memberIDs.contains(newMemberID) {
                            memberIDs.append(newMemberID)
                            newMemberID = ""
                        }
                    }
                    .disabled(newMemberID.isEmpty)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                Spacer()
                Button("Create") {
                    let team = AgentTeam(
                        name: name,
                        coordinatorAgentID: coordinatorID,
                        memberAgentIDs: memberIDs,
                        description: description
                    )
                    onCreate(team)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || memberIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            Task {
                let agents = await AgentConfigManager.shared.agentIDs
                await MainActor.run { availableAgents = agents.sorted() }
            }
        }
    }
}

// MARK: - Test Team Sheet

struct TestTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    let teamID: String
    @State private var taskDescription = ""
    @State private var result = ""
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Test Team")
                .font(.system(size: 15, weight: .bold))

            TextEditor(text: $taskDescription)
                .font(.system(size: 12))
                .frame(height: 80)
                .border(Color.gray.opacity(0.3))
                .overlay(alignment: .topLeading) {
                    if taskDescription.isEmpty {
                        Text("Describe a task for the team...")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Team working...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !result.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result:")
                        .font(.system(size: 11, weight: .semibold))
                    ScrollView {
                        Text(result)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
                }
            }

            HStack {
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                Spacer()
                Button("Execute") {
                    guard !taskDescription.isEmpty else { return }
                    isRunning = true
                    result = ""
                    Task {
                        let r = await TeamCoordinator.shared.quickExecute(teamID: teamID, task: taskDescription)
                        await MainActor.run {
                            result = r ?? "No result returned"
                            isRunning = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(taskDescription.isEmpty || isRunning)
            }
        }
        .padding(20)
        .frame(width: 500)
        .frame(minHeight: 300)
    }
}

// MARK: - Shared Context Viewer

struct SharedContextViewer: View {
    let teamID: String
    @State private var context: TeamSharedContext = TeamSharedContext()
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if context.entries.isEmpty {
                Text("No shared context")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(context.entries.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue)
                        Text("=")
                            .foregroundStyle(.secondary)
                        Text(context.entries[key] ?? "")
                            .font(.system(size: 11))
                            .lineLimit(2)
                        Spacer()
                        Button {
                            Task {
                                await TeamCoordinator.shared.updateSharedContext(teamID: teamID, key: key, value: "")
                                await loadContext()
                            }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }

            // Add new entry
            HStack(spacing: 6) {
                TextField("Key", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                TextField("Value", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !newKey.isEmpty else { return }
                    Task {
                        await TeamCoordinator.shared.updateSharedContext(teamID: teamID, key: newKey, value: newValue)
                        await MainActor.run {
                            newKey = ""
                            newValue = ""
                        }
                        await loadContext()
                    }
                }
                .controlSize(.small)
                .disabled(newKey.isEmpty)
            }
        }
        .onAppear { Task { await loadContext() } }
    }

    private func loadContext() async {
        let ctx = await TeamCoordinator.shared.getAllSharedContext(teamID: teamID)
        await MainActor.run { context = ctx }
    }
}

// MARK: - Flow Layout (simple horizontal wrapping)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

#endif
