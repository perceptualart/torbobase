// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Global Conversations View
// Shows all conversations with folder organization, CRUD, inline rename, and search.
#if canImport(SwiftUI)
import SwiftUI

struct ConversationsView: View {
    @EnvironmentObject private var state: AppState
    @State private var allSessions: [ConversationSession] = []
    @State private var folders: [ConversationFolder] = []
    @State private var agentNames: [String: String] = [:] // agentID → display name
    @State private var agents: [AgentConfig] = []
    @State private var searchText: String = ""
    @State private var isLoading = true
    @State private var selectedAgentID: String? = nil
    @State private var selectedSessionID: UUID? = nil

    // CRUD state
    @State private var showNewConversationMenu = false
    @State private var showNewFolderField = false
    @State private var newFolderName = ""
    @State private var editingSessionID: UUID? = nil
    @State private var editingTitle: String = ""
    @State private var editingFolderID: String? = nil
    @State private var editingFolderName: String = ""
    @State private var expandedFolders: Set<String> = []
    @State private var expandedAgents: Set<String> = []
    @State private var deleteConfirmSessionID: UUID? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — conversation list
            conversationListPanel
                .frame(width: 320)

            Divider().background(Color.white.opacity(0.06))

            // Right panel — inline chat or empty state
            if let agentID = selectedAgentID, let sessionID = selectedSessionID {
                AgentChatView(agentID: agentID, agentName: agentNames[agentID] ?? agentID, showHeader: true, sessionID: sessionID)
                    .id("\(agentID)_\(sessionID)")
                    .environmentObject(state)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.1))
                    Text("Select a conversation")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Choose a conversation from the list to view it here")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.15))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await loadData()
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationsChanged)) { _ in
            Task { await reloadData() }
        }
        .alert("Delete Conversation?", isPresented: Binding(
            get: { deleteConfirmSessionID != nil },
            set: { if !$0 { deleteConfirmSessionID = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmSessionID = nil }
            Button("Delete", role: .destructive) {
                if let id = deleteConfirmSessionID {
                    performDeleteSession(id)
                }
            }
        } message: {
            Text("This conversation will be permanently deleted. This cannot be undone.")
        }
    }

    // MARK: - Conversation List Panel

    private var conversationListPanel: some View {
        VStack(spacing: 0) {
            // Header with + buttons
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONVERSATIONS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .tracking(2)
                    Text("\(allSessions.count) conversations")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()

                // New folder button
                Button {
                    showNewFolderField = true
                    newFolderName = ""
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("New folder")

                // New conversation button
                Button {
                    showNewConversationMenu.toggle()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.cyan.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("New conversation")
                .popover(isPresented: $showNewConversationMenu, arrowEdge: .bottom) {
                    newConversationPopover
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider().background(Color.white.opacity(0.06))

            // Content
            if isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            } else if filteredSessions.isEmpty && folders.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.15))
                    Text(searchText.isEmpty ? "No conversations yet" : "No matches for \"\(searchText)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                    if searchText.isEmpty {
                        Text("Tap + to start a new conversation")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // New folder inline field
                        if showNewFolderField {
                            newFolderRow
                        }

                        // Folders first
                        ForEach(folders) { folder in
                            folderSection(folder)
                        }

                        // Unfiled conversations grouped by agent
                        let unfiled = unfiledGroups
                        if !unfiled.isEmpty {
                            if !folders.isEmpty {
                                HStack {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.06))
                                        .frame(height: 1)
                                    Text("UNFILED")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.2))
                                    Rectangle()
                                        .fill(Color.white.opacity(0.06))
                                        .frame(height: 1)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                            }

                            ForEach(unfiled, id: \.0) { agentID, sessions in
                                agentSection(agentID: agentID, sessions: sessions)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - New Conversation Popover

    private var newConversationPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEW CONVERSATION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if agents.isEmpty {
                Text("No agents available")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(12)
            } else {
                ForEach(agents) { agent in
                    Button {
                        createNewConversation(agentID: agent.id, agentName: agent.name)
                        showNewConversationMenu = false
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.cyan.opacity(0.1))
                                Text(String(agent.name.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.cyan.opacity(0.7))
                            }
                            .frame(width: 22, height: 22)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8))
                                if !agent.role.isEmpty {
                                    Text(agent.role)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.3))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 220)
        .background(Color(white: 0.12))
    }

    // MARK: - New Folder Row

    private var newFolderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow.opacity(0.6))

            TextField("Folder name...", text: $newFolderName, onCommit: {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Task {
                        let folder = await ConversationStore.shared.createFolder(name: name)
                        expandedFolders.insert(folder.id)
                        await reloadData()
                    }
                }
                showNewFolderField = false
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))

            Button {
                showNewFolderField = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.04))
    }

    // MARK: - Folder Section

    @ViewBuilder
    private func folderSection(_ folder: ConversationFolder) -> some View {
        let sessionsInFolder = filteredSessions.filter { $0.folderID == folder.id }
            .sorted { $0.lastActivity > $1.lastActivity }
        let isExpanded = expandedFolders.contains(folder.id)

        VStack(spacing: 0) {
            // Folder header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedFolders.remove(folder.id)
                    } else {
                        expandedFolders.insert(folder.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 12)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow.opacity(0.6))

                    if editingFolderID == folder.id {
                        TextField("", text: $editingFolderName, onCommit: {
                            let name = editingFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty {
                                Task {
                                    await ConversationStore.shared.renameFolder(id: folder.id, name: name)
                                    await reloadData()
                                }
                            }
                            editingFolderID = nil
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                    } else {
                        Text(folder.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    Text("\(sessionsInFolder.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename Folder") {
                    editingFolderID = folder.id
                    editingFolderName = folder.name
                }
                Button("Delete Folder", role: .destructive) {
                    Task {
                        await ConversationStore.shared.deleteFolder(id: folder.id)
                        await reloadData()
                    }
                }
            }

            // Folder contents
            if isExpanded {
                ForEach(sessionsInFolder) { session in
                    conversationRow(session, agentID: session.agentID, indented: true)
                }
            }
        }
    }

    // MARK: - Agent Section (for unfiled conversations)

    @ViewBuilder
    private func agentSection(agentID: String, sessions: [ConversationSession]) -> some View {
        let isExpanded = expandedAgents.contains(agentID)
        VStack(spacing: 0) {
            // Agent header — tappable to expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedAgents.remove(agentID)
                    } else {
                        expandedAgents.insert(agentID)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 12)

                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.1))
                        Text(String((agentNames[agentID] ?? agentID).prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                    }
                    .frame(width: 28, height: 28)

                    Text(agentNames[agentID] ?? agentID)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()

                    Text("\(sessions.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.02))

            // Session rows (collapsible)
            if isExpanded {
                ForEach(sessions) { session in
                    conversationRow(session, agentID: agentID, indented: false)
                }
            }
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ session: ConversationSession, agentID: String, indented: Bool) -> some View {
        let isSelected = selectedAgentID == agentID && selectedSessionID == session.id
        let isEditing = editingSessionID == session.id

        return Button {
            selectedAgentID = agentID
            selectedSessionID = session.id
        } label: {
            HStack(spacing: 12) {
                if let label = session.colorLabel {
                    Circle()
                        .fill(colorForLabel(label))
                        .frame(width: 6, height: 6)
                }
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .cyan.opacity(0.6) : .white.opacity(0.2))

                VStack(alignment: .leading, spacing: 3) {
                    if isEditing {
                        TextField("", text: $editingTitle, onCommit: {
                            let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !title.isEmpty {
                                Task {
                                    await ConversationStore.shared.renameSession(sessionID: session.id, title: title)
                                    await reloadData()
                                }
                            }
                            editingSessionID = nil
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.7))
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        if indented {
                            Text(agentNames[agentID] ?? agentID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.4))
                        }
                        Text("\(session.messageCount) msgs")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                        Text(relativeTime(session.lastActivity))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, indented ? 36 : 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.cyan.opacity(0.08) : Color.white.opacity(0.01))
        .contextMenu {
            Button("Rename") {
                editingSessionID = session.id
                editingTitle = session.title
            }

            Menu("Move to Folder") {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        Task {
                            await ConversationStore.shared.moveSessionToFolder(sessionID: session.id, folderID: folder.id)
                            await reloadData()
                        }
                    }
                }
                if session.folderID != nil {
                    Divider()
                    Button("Remove from Folder") {
                        Task {
                            await ConversationStore.shared.moveSessionToFolder(sessionID: session.id, folderID: nil)
                            await reloadData()
                        }
                    }
                }
            }

            Menu("Color Label") {
                Button("None") {
                    Task { await ConversationStore.shared.setSessionColor(sessionID: session.id, color: nil); await reloadData() }
                }
                Divider()
                ForEach(["red", "orange", "yellow", "green", "blue", "purple"], id: \.self) { color in
                    Button {
                        Task { await ConversationStore.shared.setSessionColor(sessionID: session.id, color: color); await reloadData() }
                    } label: {
                        Label(color.capitalized, systemImage: "circle.fill")
                    }
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                deleteConfirmSessionID = session.id
            }
        }
    }

    // MARK: - Data

    private var filteredSessions: [ConversationSession] {
        let query = searchText.lowercased()
        if query.isEmpty { return allSessions }
        return allSessions.filter {
            $0.title.lowercased().contains(query) ||
            (agentNames[$0.agentID]?.lowercased().contains(query) ?? false)
        }
    }

    private var unfiledGroups: [(String, [ConversationSession])] {
        let unfiled = filteredSessions.filter { $0.folderID == nil }
        var grouped: [String: [ConversationSession]] = [:]
        for session in unfiled {
            grouped[session.agentID, default: []].append(session)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.lastActivity > $1.lastActivity }
        }
        return grouped.sorted { ($0.value.first?.lastActivity ?? .distantPast) > ($1.value.first?.lastActivity ?? .distantPast) }
    }

    private func loadData() async {
        allSessions = await ConversationStore.shared.loadSessions()
        folders = await ConversationStore.shared.loadFolders()

        let configs = await AgentConfigManager.shared.listAgents()
        agents = configs
        var names: [String: String] = [:]
        for config in configs {
            names[config.id] = config.name
        }
        agentNames = names

        // Auto-expand all folders and agents on first load
        for folder in folders {
            expandedFolders.insert(folder.id)
        }
        for config in configs {
            expandedAgents.insert(config.id)
        }
    }

    private func reloadData() async {
        allSessions = await ConversationStore.shared.loadSessions()
        folders = await ConversationStore.shared.loadFolders()
    }

    private func createNewConversation(agentID: String, agentName: String) {
        Task {
            let session = await ConversationStore.shared.createSession(
                agentID: agentID, title: "New Conversation"
            )
            await reloadData()
            selectedAgentID = agentID
            selectedSessionID = session.id
            // Start editing the title right away
            editingSessionID = session.id
            editingTitle = "New Conversation"
        }
    }

    private func performDeleteSession(_ sessionID: UUID) {
        // If this was the selected session, clear selection
        if selectedSessionID == sessionID {
            selectedAgentID = nil
            selectedSessionID = nil
        }
        Task {
            await ConversationStore.shared.deleteSession(sessionID: sessionID)
            await reloadData()
        }
        deleteConfirmSessionID = nil
    }

    // MARK: - Helpers

    private func colorForLabel(_ label: String) -> Color {
        switch label {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .gray
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
#endif
