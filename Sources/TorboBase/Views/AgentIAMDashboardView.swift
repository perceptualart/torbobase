// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent IAM Dashboard
// SwiftUI dashboard for managing agent identities, permissions, access logs, and anomaly detection.

#if canImport(SwiftUI)
import SwiftUI

struct AgentIAMDashboardView: View {
    @State private var agents: [AgentIdentity] = []
    @State private var selectedAgentID: String?
    @State private var accessLogs: [IAMAccessLog] = []
    @State private var anomalies: [AccessAnomaly] = []
    @State private var riskScores: [String: Float] = [:]
    @State private var searchText = ""
    @State private var resourceSearchText = ""
    @State private var resourceSearchResults: [AgentIdentity] = []
    @State private var showingPermissionEditor = false
    @State private var stats: [String: Any] = [:]
    @State private var selectedTab: IAMTab = .agents

    enum IAMTab: String, CaseIterable {
        case agents = "Agents"
        case accessLog = "Access Log"
        case anomalies = "Anomalies"
        case search = "Search"

        var icon: String {
            switch self {
            case .agents: return "person.2.fill"
            case .accessLog: return "list.bullet.rectangle"
            case .anomalies: return "exclamationmark.triangle.fill"
            case .search: return "magnifyingglass"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(IAMTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                // Stats summary
                if let totalAgents = stats["totalAgents"] as? Int {
                    Text("\(totalAgents) agents")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let anomalyCount = stats["activeAnomalies"] as? Int, anomalyCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("\(anomalyCount)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            switch selectedTab {
            case .agents: agentsTab
            case .accessLog: accessLogTab
            case .anomalies: anomaliesTab
            case .search: searchTab
            }
        }
        .task { await refreshAll() }
    }

    // MARK: - Agents Tab

    private var agentsTab: some View {
        HSplitView {
            // Agent list
            VStack(spacing: 0) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter agents...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))

                Divider()

                List(selection: $selectedAgentID) {
                    ForEach(filteredAgents, id: \.id) { agent in
                        AgentIAMRow(agent: agent)
                            .tag(agent.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 250, maxWidth: 350)

            // Agent detail
            if let agentID = selectedAgentID, let agent = agents.first(where: { $0.id == agentID }) {
                AgentIAMDetailView(
                    agent: agent,
                    accessLogs: accessLogs.filter { $0.agentID == agentID },
                    onRefresh: { await refreshAll() },
                    onRevokeAll: {
                        Task {
                            await AgentIAMEngine.shared.revokeAllPermissions(agentID: agentID)
                            await refreshAll()
                        }
                    }
                )
            } else {
                VStack {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("Select an agent to view IAM details")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Access Log Tab

    private var accessLogTab: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Access Log")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(accessLogs.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log table
            List {
                ForEach(Array(accessLogs.enumerated()), id: \.offset) { _, log in
                    HStack(spacing: 8) {
                        // Status indicator
                        Circle()
                            .fill(log.allowed ? Color.green : Color.red)
                            .frame(width: 8, height: 8)

                        // Agent
                        Text(log.agentID)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 80, alignment: .leading)

                        // Action
                        Text(log.action)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .frame(width: 60, alignment: .leading)

                        // Resource
                        Text(log.resource)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        Spacer()

                        // Reason (if denied)
                        if let reason = log.reason {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundColor(.red.opacity(0.8))
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .trailing)
                        }

                        // Timestamp
                        Text(formatTime(log.timestamp))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Anomalies Tab

    private var anomaliesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Anomaly Detection")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Scan Now") {
                    Task { await refreshAnomalies() }
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if anomalies.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green.opacity(0.5))
                    Text("No anomalies detected")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(anomalies.enumerated()), id: \.offset) { _, anomaly in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                severityBadge(anomaly.severity)
                                Text(anomaly.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(anomaly.agentID)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.accentColor)
                            }
                            Text(anomaly.description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(formatTime(anomaly.detectedAt))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Which agents can access this resource?", text: $resourceSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        Task { await searchByResource() }
                    }
                Button("Search") {
                    Task { await searchByResource() }
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Search helper text
            if resourceSearchText.isEmpty && resourceSearchResults.isEmpty {
                VStack(spacing: 12) {
                    Text("Resource Search")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Find which agents have access to a specific resource")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        searchExample("file:/Documents/*", "Agents with file access")
                        searchExample("tool:web_search", "Agents that can search the web")
                        searchExample("tool:run_command", "Agents with command execution")
                        searchExample("*", "Agents with wildcard access")
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resourceSearchResults.isEmpty && !resourceSearchText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("No agents have access to '\(resourceSearchText)'")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(resourceSearchResults, id: \.id) { agent in
                        AgentIAMRow(agent: agent)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var filteredAgents: [AgentIdentity] {
        if searchText.isEmpty { return agents }
        return agents.filter {
            $0.id.localizedCaseInsensitiveContains(searchText) ||
            $0.owner.localizedCaseInsensitiveContains(searchText) ||
            $0.purpose.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func refreshAll() async {
        agents = await AgentIAMEngine.shared.listAgents()
        accessLogs = await AgentIAMEngine.shared.getAccessLog(limit: 500)
        anomalies = await AgentIAMEngine.shared.detectAnomalies()
        riskScores = await AgentIAMEngine.shared.getRiskScores()
        stats = await AgentIAMEngine.shared.getStats()
    }

    private func refreshAnomalies() async {
        anomalies = await AgentIAMEngine.shared.detectAnomalies()
    }

    private func searchByResource() async {
        guard !resourceSearchText.isEmpty else { return }
        resourceSearchResults = await AgentIAMEngine.shared.findAgentsWithAccess(resource: resourceSearchText)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func severityBadge(_ severity: String) -> some View {
        let color: Color = {
            switch severity {
            case "critical": return .red
            case "high": return .orange
            case "medium": return .yellow
            case "low": return .blue
            default: return .gray
            }
        }()

        return Text(severity.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }

    private func searchExample(_ resource: String, _ desc: String) -> some View {
        HStack {
            Text(resource)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.accentColor)
            Text("—")
                .foregroundColor(.secondary)
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Agent Row

struct AgentIAMRow: View {
    let agent: AgentIdentity

    var body: some View {
        HStack(spacing: 8) {
            // Risk indicator
            Circle()
                .fill(riskColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.id)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                HStack(spacing: 6) {
                    Text("\(agent.permissions.count) permissions")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if !agent.owner.isEmpty {
                        Text(agent.owner)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Risk score
            Text(String(format: "%.0f%%", agent.riskScore * 100))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(riskColor)
        }
        .padding(.vertical, 2)
    }

    private var riskColor: Color {
        if agent.riskScore > 0.7 { return .red }
        if agent.riskScore > 0.4 { return .orange }
        if agent.riskScore > 0.2 { return .yellow }
        return .green
    }
}

// MARK: - Agent Detail View

struct AgentIAMDetailView: View {
    let agent: AgentIdentity
    let accessLogs: [IAMAccessLog]
    let onRefresh: () async -> Void
    let onRevokeAll: () -> Void

    @State private var showingGrantSheet = false
    @State private var newResource = ""
    @State private var newActions: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.id)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                        if !agent.purpose.isEmpty {
                            Text(agent.purpose)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text("Owner: \(agent.owner.isEmpty ? "local" : agent.owner)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("Created: \(formatDate(agent.createdAt))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    riskScoreGauge
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Permissions section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Permissions (\(agent.permissions.count))")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Grant") { showingGrantSheet = true }
                            .font(.system(size: 11))
                        Button("Revoke All") { onRevokeAll() }
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    if agent.permissions.isEmpty {
                        Text("No permissions granted")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(agent.permissions.enumerated()), id: \.offset) { _, perm in
                            HStack(spacing: 8) {
                                Text(perm.resource)
                                    .font(.system(size: 11, design: .monospaced))
                                ForEach(perm.actions.sorted(), id: \.self) { action in
                                    Text(action)
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(actionColor(action))
                                        .cornerRadius(3)
                                }
                                Spacer()
                                Text("by \(perm.grantedBy)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    Task {
                                        await AgentIAMEngine.shared.revokePermission(agentID: agent.id, resource: perm.resource)
                                        await onRefresh()
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }

                // Recent access log
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Access (\(accessLogs.count))")
                        .font(.system(size: 13, weight: .semibold))

                    if accessLogs.isEmpty {
                        Text("No access history")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(accessLogs.prefix(20).enumerated()), id: \.offset) { _, log in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(log.allowed ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(log.action)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                Text(log.resource)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatTime(log.timestamp))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingGrantSheet) {
            grantPermissionSheet
        }
    }

    private var riskScoreGauge: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                    .frame(width: 50, height: 50)
                Circle()
                    .trim(from: 0, to: CGFloat(agent.riskScore))
                    .stroke(riskColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.0f", agent.riskScore * 100))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(riskColor)
            }
            Text("Risk")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private var grantPermissionSheet: some View {
        VStack(spacing: 16) {
            Text("Grant Permission to \(agent.id)")
                .font(.system(size: 14, weight: .semibold))

            TextField("Resource (e.g. file:*, tool:web_search)", text: $newResource)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                ForEach(["read", "write", "execute", "use"], id: \.self) { action in
                    Toggle(action, isOn: Binding(
                        get: { newActions.contains(action) },
                        set: { if $0 { newActions.insert(action) } else { newActions.remove(action) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                }
            }

            HStack {
                Button("Cancel") { showingGrantSheet = false }
                Spacer()
                Button("Grant") {
                    guard !newResource.isEmpty, !newActions.isEmpty else { return }
                    Task {
                        await AgentIAMEngine.shared.grantPermission(
                            agentID: agent.id, resource: newResource, actions: newActions, grantedBy: "user"
                        )
                        newResource = ""
                        newActions = []
                        showingGrantSheet = false
                        await onRefresh()
                    }
                }
                .disabled(newResource.isEmpty || newActions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var riskColor: Color {
        if agent.riskScore > 0.7 { return .red }
        if agent.riskScore > 0.4 { return .orange }
        if agent.riskScore > 0.2 { return .yellow }
        return .green
    }

    private func actionColor(_ action: String) -> Color {
        switch action {
        case "execute": return .red
        case "write": return .orange
        case "read": return .blue
        case "use": return .green
        case "*": return .purple
        default: return .gray
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
#endif
