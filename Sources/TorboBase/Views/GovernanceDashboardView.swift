// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Governance & Observability Dashboard (SwiftUI)
// Real-time agent activity feed, cost tracking, approval queue, anomaly alerts.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - Main Governance Dashboard View

struct GovernanceDashboardView: View {
    @State private var selectedTab: GovernanceTab = .overview
    @State private var decisions: [[String: Any]] = []
    @State private var stats: [String: Any] = [:]
    @State private var pendingApprovals: [[String: Any]] = []
    @State private var anomalies: [[String: Any]] = []
    @State private var policies: [[String: Any]] = []
    @State private var selectedDecisionID: String?
    @State private var decisionTrace: [String: Any]?
    @State private var isLoading = false
    @State private var lastRefresh = Date()
    @State private var autoRefresh = true
    @State private var exportFormat: String = "json"

    enum GovernanceTab: String, CaseIterable {
        case overview = "Overview"
        case decisions = "Decisions"
        case approvals = "Approvals"
        case costs = "Costs"
        case anomalies = "Anomalies"
        case policies = "Policies"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            // Tab bar
            tabBar

            // Content
            ScrollView {
                switch selectedTab {
                case .overview: overviewPanel
                case .decisions: decisionsPanel
                case .approvals: approvalsPanel
                case .costs: costsPanel
                case .anomalies: anomaliesPanel
                case .policies: policiesPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.95))
        .task { await refresh() }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("GOVERNANCE")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .tracking(3)
                Text("Observability & Audit Trail")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()

            // Auto-refresh toggle
            Toggle(isOn: $autoRefresh) {
                Text("Auto-refresh")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Refresh button
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)

            // Export button
            Menu {
                Button("Export JSON") { Task { await exportAudit(format: "json") } }
                Button("Export CSV") { Task { await exportAudit(format: "csv") } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(GovernanceTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .bold : .medium))
                            .foregroundStyle(selectedTab == tab ? .cyan : .white.opacity(0.5))

                        // Badge for pending approvals
                        if tab == .approvals && !pendingApprovals.isEmpty {
                            Text("\(pendingApprovals.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }

                        // Badge for anomalies
                        if tab == .anomalies && !anomalies.isEmpty {
                            Text("\(anomalies.count)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }

                        Rectangle()
                            .fill(selectedTab == tab ? Color.cyan : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.06))
        }
    }

    // MARK: - Overview Panel

    private var overviewPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Stat cards
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 12) {
                statCard(label: "TOTAL DECISIONS", value: "\(stats["totalDecisions"] as? Int ?? 0)", color: .cyan)
                statCard(label: "TOTAL COST", value: "$\(String(format: "%.2f", stats["totalCost"] as? Double ?? 0))", color: .green)
                statCard(label: "PENDING APPROVALS", value: "\(stats["pendingApprovals"] as? Int ?? 0)", color: .orange)
                statCard(label: "BLOCKED ACTIONS", value: "\(stats["blockedActions"] as? Int ?? 0)", color: .red)
                statCard(label: "ANOMALIES", value: "\(stats["anomalyCount"] as? Int ?? 0)", color: .yellow)
            }

            // Confidence & approval rate
            HStack(spacing: 12) {
                statCard(label: "AVG CONFIDENCE", value: String(format: "%.0f%%", (stats["avgConfidence"] as? Double ?? 0) * 100), color: .purple)
                statCard(label: "APPROVAL RATE", value: String(format: "%.0f%%", (stats["approvalRate"] as? Double ?? 0) * 100), color: .green)
            }

            // Recent activity feed
            Text("RECENT ACTIVITY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2)
                .padding(.top, 8)

            ForEach(Array(decisions.prefix(10).enumerated()), id: \.offset) { _, decision in
                decisionRow(decision)
            }
        }
        .padding(20)
    }

    // MARK: - Decisions Panel

    private var decisionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DECISION LOG")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2)

            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                decisionRow(decision)
                    .onTapGesture {
                        selectedDecisionID = decision["id"] as? String
                        Task { await loadDecisionTrace(id: selectedDecisionID ?? "") }
                    }
            }

            if decisions.isEmpty {
                emptyState(icon: "doc.text.magnifyingglass", text: "No decisions logged yet")
            }
        }
        .padding(20)
        .sheet(item: Binding(
            get: { selectedDecisionID.map { DecisionDetailID(id: $0) } },
            set: { selectedDecisionID = $0?.id }
        )) { item in
            decisionDetailSheet(id: item.id)
        }
    }

    // MARK: - Approvals Panel

    private var approvalsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PENDING APPROVALS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2)

            if pendingApprovals.isEmpty {
                emptyState(icon: "checkmark.shield", text: "No pending approvals")
            }

            ForEach(Array(pendingApprovals.enumerated()), id: \.offset) { _, approval in
                approvalCard(approval)
            }
        }
        .padding(20)
    }

    // MARK: - Costs Panel

    private var costsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("COST TRACKING")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2)

            // Total cost
            let totalCost = stats["totalCost"] as? Double ?? 0
            HStack {
                Text("Total Spend")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("$\(String(format: "%.4f", totalCost))")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Cost by agent
            if let costByAgent = stats["costByAgent"] as? [String: Double], !costByAgent.isEmpty {
                Text("BY AGENT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(2)

                ForEach(costByAgent.sorted(by: { $0.value > $1.value }), id: \.key) { agent, cost in
                    HStack {
                        Circle()
                            .fill(agentColor(agent))
                            .frame(width: 8, height: 8)
                        Text(agent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text("$\(String(format: "%.4f", cost))")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.8))

                        // Bar chart
                        let maxCost = costByAgent.values.max() ?? 1
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(agentColor(agent).opacity(0.4))
                                .frame(width: geo.size.width * (cost / maxCost))
                        }
                        .frame(width: 100, height: 12)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Cost by day
            if let costByDay = stats["costByDay"] as? [String: Double], !costByDay.isEmpty {
                Text("BY DAY (LAST 30 DAYS)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(2)
                    .padding(.top, 8)

                ForEach(costByDay.sorted(by: { $0.key > $1.key }).prefix(14), id: \.key) { day, cost in
                    HStack {
                        Text(day)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("$\(String(format: "%.4f", cost))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.8))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Anomalies Panel

    private var anomaliesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ANOMALIES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(2)
                Spacer()
                Button("Scan Now") {
                    Task { await runAnomalyDetection() }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.cyan)
            }

            if anomalies.isEmpty {
                emptyState(icon: "shield.checkered", text: "No anomalies detected")
            }

            ForEach(Array(anomalies.enumerated()), id: \.offset) { _, anomaly in
                anomalyCard(anomaly)
            }
        }
        .padding(20)
    }

    // MARK: - Policies Panel

    private var policiesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GOVERNANCE POLICIES")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(2)

            ForEach(Array(policies.enumerated()), id: \.offset) { _, policy in
                policyCard(policy)
            }

            if policies.isEmpty {
                emptyState(icon: "doc.badge.gearshape", text: "No policies configured")
            }
        }
        .padding(20)
    }

    // MARK: - Components

    private func statCard(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(2)
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func decisionRow(_ d: [String: Any]) -> some View {
        HStack(spacing: 10) {
            // Risk level indicator
            let risk = d["riskLevel"] as? String ?? "LOW"
            Circle()
                .fill(riskColor(risk))
                .frame(width: 8, height: 8)

            // Agent
            Text(d["agentID"] as? String ?? "-")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 60, alignment: .leading)

            // Action
            Text(d["action"] as? String ?? "-")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()

            // Policy result badge
            let policy = d["policyResult"] as? String ?? "allowed"
            Text(policy.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(policyResultColor(policy))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(policyResultColor(policy).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Cost
            let cost = d["cost"] as? Double ?? 0
            if cost > 0 {
                Text("$\(String(format: "%.4f", cost))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.7))
            }

            // Timestamp
            Text(formatTimestamp(d["timestamp"] as? String ?? ""))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func approvalCard(_ a: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(a["agentID"] as? String ?? "-")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.cyan)
                Spacer()
                let risk = a["riskLevel"] as? String ?? "HIGH"
                Text(risk)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(riskColor(risk))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(riskColor(risk).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(a["action"] as? String ?? "-")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))

            if let reasoning = a["reasoning"] as? String, !reasoning.isEmpty {
                Text(reasoning)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await approveDecision(id: a["decisionID"] as? String ?? "") }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Approve")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await rejectDecision(id: a["decisionID"] as? String ?? "") }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Reject")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()

                let cost = a["estimatedCost"] as? Double ?? 0
                if cost > 0 {
                    Text("Est: $\(String(format: "%.4f", cost))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private func anomalyCard(_ a: [String: Any]) -> some View {
        HStack(spacing: 12) {
            let severity = a["severity"] as? String ?? "LOW"
            Image(systemName: severity == "HIGH" || severity == "CRITICAL" ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(riskColor(severity))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(a["type"] as? String ?? "-")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(a["agentID"] as? String ?? "-")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.7))
                }
                Text(a["description"] as? String ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
            Spacer()

            Text(severity)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(riskColor(severity))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(riskColor(severity).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func policyCard(_ p: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill((p["enabled"] as? Bool ?? false) ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(p["name"] as? String ?? "-")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                let risk = p["riskLevel"] as? String ?? "LOW"
                Text(risk)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(riskColor(risk))
            }

            Text(p["description"] as? String ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 12) {
                Text("Pattern: \(p["actionPattern"] as? String ?? "*")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                if p["requireApproval"] as? Bool == true {
                    Text("REQUIRES APPROVAL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                let maxCost = p["maxCostPerAction"] as? Double ?? 0
                if maxCost > 0 {
                    Text("Max: $\(String(format: "%.2f", maxCost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.6))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func decisionDetailSheet(id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Decision Detail")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Close") { selectedDecisionID = nil }
                    .foregroundStyle(.cyan)
            }
            .padding(.bottom, 8)

            if let trace = decisionTrace {
                if let decision = trace["decision"] as? [String: Any] {
                    detailRow("ID", decision["id"] as? String ?? "-")
                    detailRow("Agent", decision["agentID"] as? String ?? "-")
                    detailRow("Action", decision["action"] as? String ?? "-")
                    detailRow("Reasoning", decision["reasoning"] as? String ?? "-")
                    detailRow("Confidence", String(format: "%.1f%%", (decision["confidence"] as? Double ?? 0) * 100))
                    detailRow("Cost", "$\(String(format: "%.4f", decision["cost"] as? Double ?? 0))")
                    detailRow("Risk", decision["riskLevel"] as? String ?? "-")
                    detailRow("Policy", decision["policyResult"] as? String ?? "-")
                    detailRow("Outcome", decision["outcome"] as? String ?? "-")
                }

                if let checks = trace["policyChecks"] as? [String] {
                    Text("Policy Checks")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                    ForEach(checks, id: \.self) { check in
                        Text(check)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                if let related = trace["relatedDecisions"] as? [[String: Any]], !related.isEmpty {
                    Text("Related Decisions (\(related.count))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                    ForEach(Array(related.prefix(5).enumerated()), id: \.offset) { _, r in
                        Text("\(r["action"] as? String ?? "-") — \(r["outcome"] as? String ?? "")")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(white: 0.08))
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.2))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func riskColor(_ risk: String) -> Color {
        switch risk.uppercased() {
        case "CRITICAL": return .red
        case "HIGH": return .orange
        case "MEDIUM": return .yellow
        case "LOW": return .green
        default: return .gray
        }
    }

    private func policyResultColor(_ result: String) -> Color {
        switch result.lowercased() {
        case "allowed": return .green
        case "flagged": return .yellow
        case "blocked": return .red
        default: return .gray
        }
    }

    private func agentColor(_ agent: String) -> Color {
        switch agent.lowercased() {
        case "sid": return .cyan
        case "orion": return .orange
        case "mira": return .purple
        case "ada": return .green
        default: return .blue
        }
    }

    private func formatTimestamp(_ ts: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: ts) else { return ts.prefix(19).description }
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }

    // MARK: - Data Loading

    private func refresh() async {
        let engine = GovernanceEngine.shared
        await engine.initialize()

        let s = await engine.getStats()
        let d = engine.getDecisions(limit: 50, offset: 0)
        let p = await engine.listPendingApprovals()
        let a = engine.getAnomalies()
        let pol = engine.getPolicies()

        await MainActor.run {
            stats = s.toDict()
            decisions = d.map { $0.toDict() }
            pendingApprovals = p.map { $0.toDict() }
            anomalies = a.map { $0.toDict() }
            policies = pol.map { $0.toDict() }
            lastRefresh = Date()
        }
    }

    private func loadDecisionTrace(id: String) async {
        let engine = GovernanceEngine.shared
        if let trace = engine.explainDecision(id: id) {
            await MainActor.run {
                decisionTrace = trace.toDict()
            }
        }
    }

    private func approveDecision(id: String) async {
        let engine = GovernanceEngine.shared
        _ = engine.approve(decisionID: id)
        await refresh()
    }

    private func rejectDecision(id: String) async {
        let engine = GovernanceEngine.shared
        _ = engine.reject(decisionID: id)
        await refresh()
    }

    private func runAnomalyDetection() async {
        let engine = GovernanceEngine.shared
        _ = await engine.detectAnomalies()
        await refresh()
    }

    private func exportAudit(format: String) async {
        let engine = GovernanceEngine.shared
        let data = await engine.exportAuditTrail(format: format)
        let ext = format == "csv" ? "csv" : "json"
        let filename = "torbo-governance-export.\(ext)"

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = format == "csv" ? [.commaSeparatedText] : [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                TorboLog.info("Exported governance audit to \(url.path)", subsystem: "Governance")
            } catch {
                TorboLog.error("Export failed: \(error)", subsystem: "Governance")
            }
        }
    }
}

// Helper for sheet binding
private struct DecisionDetailID: Identifiable {
    let id: String
}

#endif
