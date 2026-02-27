// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Global Conversations View
// Shows all conversations grouped by agent, with search and inline chat.
#if canImport(SwiftUI)
import SwiftUI

struct ConversationsView: View {
    @EnvironmentObject private var state: AppState
    @State private var groupedSessions: [String: [ConversationSession]] = [:]
    @State private var agentNames: [String: String] = [:] // agentID → display name
    @State private var searchText: String = ""
    @State private var isLoading = true
    @State private var selectedAgentID: String? = nil
    @State private var selectedSessionID: UUID? = nil

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
    }

    // MARK: - Conversation List Panel

    private var conversationListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONVERSATIONS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .tracking(2)
                    Text("\(totalCount) conversations across \(groupedSessions.count) agents")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
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
            } else if filteredGroups.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.15))
                    Text(searchText.isEmpty ? "No conversations yet" : "No matches for \"\(searchText)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredGroups, id: \.0) { agentID, sessions in
                            agentSection(agentID: agentID, sessions: sessions)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Data

    private var totalCount: Int {
        groupedSessions.values.reduce(0) { $0 + $1.count }
    }

    private var filteredGroups: [(String, [ConversationSession])] {
        let query = searchText.lowercased()
        var result: [(String, [ConversationSession])] = []

        for (agentID, sessions) in groupedSessions.sorted(by: { ($0.value.first?.lastActivity ?? .distantPast) > ($1.value.first?.lastActivity ?? .distantPast) }) {
            let filtered: [ConversationSession]
            if query.isEmpty {
                filtered = sessions
            } else {
                let name = agentNames[agentID]?.lowercased() ?? ""
                filtered = sessions.filter {
                    $0.title.lowercased().contains(query) || name.contains(query)
                }
            }
            if !filtered.isEmpty {
                result.append((agentID, filtered))
            }
        }
        return result
    }

    private func loadData() async {
        groupedSessions = await ConversationStore.shared.loadSessionsGroupedByAgent()

        // Load agent display names
        let configs = await AgentConfigManager.shared.listAgents()
        var names: [String: String] = [:]
        for config in configs {
            names[config.id] = config.name
        }
        agentNames = names
    }

    // MARK: - Agent Section

    @ViewBuilder
    private func agentSection(agentID: String, sessions: [ConversationSession]) -> some View {
        VStack(spacing: 0) {
            // Agent header
            HStack(spacing: 10) {
                // Avatar
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
            .background(Color.white.opacity(0.02))

            // Session rows
            ForEach(sessions) { session in
                conversationRow(session, agentID: agentID)
            }
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ session: ConversationSession, agentID: String) -> some View {
        let isSelected = selectedAgentID == agentID && selectedSessionID == session.id
        return Button {
            selectedAgentID = agentID
            selectedSessionID = session.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .cyan.opacity(0.6) : .white.opacity(0.2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.7))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(session.messageCount) messages")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))
                        Text(relativeTime(session.lastActivity))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.cyan.opacity(0.08) : Color.white.opacity(0.01))
    }

    // MARK: - Helpers

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
