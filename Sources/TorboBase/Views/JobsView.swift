// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Jobs: Interactive Node Graph
// Blender-inspired view showing everything the system is doing.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

// MARK: - Job Node Model

struct JobNode: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let type: NodeType
    let status: NodeStatus
    let agentID: String?
    let startedAt: Date?
    let dependencies: [String]

    enum NodeType: String {
        case task       // Active tasks from TaskQueue
        case workflow   // Multi-step workflows
        case service    // Running services (bridges, MCP, etc.)
        case scheduled  // Cron jobs
        case memory     // MemoryArmy activity
    }

    enum NodeStatus: String {
        case running, pending, completed, failed, idle
    }

    var color: Color {
        switch type {
        case .task:      return .blue
        case .workflow:  return .purple
        case .service:   return .green
        case .scheduled: return .yellow
        case .memory:    return .cyan
        }
    }

    var statusColor: Color {
        switch status {
        case .running:   return .green
        case .pending:   return .white.opacity(0.4)
        case .completed: return .green.opacity(0.5)
        case .failed:    return .red
        case .idle:      return .white.opacity(0.2)
        }
    }
}

// MARK: - Jobs View

struct JobsView: View {
    @EnvironmentObject private var state: AppState

    @State private var nodes: [JobNode] = []
    @State private var selectedNodeID: String?
    @State private var magnification: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var refreshTimer: Timer?

    // Draggable node positions
    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var activeDrag: [String: CGSize] = [:]

    // Info popovers
    @State private var infoSection: String?

    // Pan gesture state
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    // Stats
    @State private var activeTaskCount = 0
    @State private var serviceCount = 0
    @State private var cronCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header + stats bar
            jobsHeader

            Divider().overlay(Color.white.opacity(0.06))

            HStack(spacing: 0) {
                // Main node graph area
                nodeGraphView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Detail panel (when node selected)
                if let selectedID = selectedNodeID,
                   let node = nodes.first(where: { $0.id == selectedID }) {
                    Divider().overlay(Color.white.opacity(0.06))
                    nodeDetailPanel(node)
                        .frame(width: 280)
                }
            }
        }
        .task {
            await refreshNodes()
            // Poll every 2 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshNodes()
            }
        }
    }

    // MARK: - Header

    private var jobsHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Jobs")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(activeTaskCount) active tasks · \(serviceCount) services · \(cronCount) cron jobs")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()

            // Zoom controls
            HStack(spacing: 4) {
                Button { magnification = max(0.5, magnification - 0.1) } label: {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))

                Text(String(format: "%.0f%%", magnification * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 40)

                Button { magnification = min(2.0, magnification + 0.1) } label: {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))

                Button { magnification = 1.0; offset = .zero } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.3))
            }

            Button {
                Task {
                    await TaskQueue.shared.purgeTasks(status: nil)
                    await refreshNodes()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Node Graph (Draggable ZStack)

    private var nodeGraphView: some View {
        GeometryReader { geo in
            ZStack {
                // Background — tap to deselect
                Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1))
                    .onTapGesture { selectedNodeID = nil }

                // Dependency connection lines
                Canvas { context, size in
                    for node in nodes where !node.dependencies.isEmpty {
                        let toPos = currentPosition(for: node.id, in: geo.size)
                        for depID in node.dependencies {
                            let fromPos = currentPosition(for: depID, in: geo.size)
                            var path = Path()
                            let midY = (fromPos.y + toPos.y) / 2
                            path.move(to: fromPos)
                            path.addQuadCurve(to: toPos, control: CGPoint(x: (fromPos.x + toPos.x) / 2, y: midY - 30))
                            context.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 1)
                        }
                    }
                }

                // Section labels
                sectionLabels(in: geo.size)

                // Draggable node cards
                ForEach(nodes) { node in
                    nodeCard(node)
                        .frame(width: 200)
                        .position(currentPosition(for: node.id, in: geo.size))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    activeDrag[node.id] = value.translation
                                }
                                .onEnded { value in
                                    let base = nodePositions[node.id] ?? defaultPosition(for: node, in: geo.size)
                                    nodePositions[node.id] = CGPoint(
                                        x: base.x + value.translation.width,
                                        y: base.y + value.translation.height
                                    )
                                    activeDrag[node.id] = nil
                                }
                        )
                }
            }
            .scaleEffect(magnification)
            .offset(panOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        panOffset = CGSize(
                            width: lastPanOffset.width + value.translation.width,
                            height: lastPanOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastPanOffset = panOffset
                    }
            )
        }
    }

    // Section labels positioned at the left edge of each row
    private func sectionLabels(in size: CGSize) -> some View {
        let sections: [(title: String, icon: String, row: Int)] = [
            ("SERVICES", "server.rack", 0),
            ("ACTIVE TASKS", "bolt.fill", 1),
            ("WORKFLOWS", "arrow.triangle.branch", 2),
            ("SCHEDULED", "clock.fill", 3),
            ("MEMORY", "brain.fill", 3),
            ("QUEUED", "tray.full.fill", 4),
            ("COMPLETED", "checkmark.circle", 5),
        ]
        let rowHeight: CGFloat = 80
        let startY: CGFloat = 40

        return ZStack(alignment: .topLeading) {
            ForEach(sections, id: \.title) { section in
                let hasNodes = sectionHasNodes(section.title)
                if hasNodes {
                    nodeSectionHeader(title: section.title, icon: section.icon)
                        .position(x: 70, y: startY + CGFloat(section.row) * rowHeight - 20)
                }
            }
        }
    }

    private func sectionHasNodes(_ title: String) -> Bool {
        switch title {
        case "SERVICES":     return nodes.contains { $0.type == .service }
        case "ACTIVE TASKS": return nodes.contains { $0.type == .task && $0.status == .running }
        case "WORKFLOWS":    return nodes.contains { $0.type == .workflow }
        case "SCHEDULED":    return nodes.contains { $0.type == .scheduled }
        case "MEMORY":       return nodes.contains { $0.type == .memory }
        case "QUEUED":       return nodes.contains { $0.type == .task && $0.status == .pending }
        case "COMPLETED":    return nodes.contains { $0.status == .completed || $0.status == .failed }
        default:             return false
        }
    }

    private func nodeSectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(1)
            Button {
                infoSection = infoSection == title ? nil : title
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .popover(isPresented: .init(
                get: { infoSection == title },
                set: { if !$0 { infoSection = nil } }
            )) {
                Text(sectionDescription(title))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(12)
                    .frame(width: 260)
            }
        }
    }

    private func sectionDescription(_ title: String) -> String {
        switch title {
        case "SERVICES":     return "Long-running processes: gateway server, Ollama, LoA memory system"
        case "ACTIVE TASKS": return "Tasks currently being executed by agents via TaskQueue"
        case "WORKFLOWS":    return "Multi-step task chains managed by WorkflowEngine"
        case "SCHEDULED":    return "Recurring cron jobs — use the API or ask an agent to schedule"
        case "MEMORY":       return "Library of Alexandria workers: indexing, searching, repairing"
        case "QUEUED":       return "Tasks waiting to be claimed by an available agent"
        case "COMPLETED":    return "Recently finished tasks (last 10)"
        default:             return ""
        }
    }

    // MARK: - Node Positioning

    private func defaultPosition(for node: JobNode, in size: CGSize) -> CGPoint {
        let rowHeight: CGFloat = 80
        let startX: CGFloat = 200
        let colWidth: CGFloat = 220
        let startY: CGFloat = 40

        // Determine row and index within row
        let row: Int
        let indexInRow: Int
        switch node.type {
        case .service:
            row = 0
            indexInRow = nodes.filter { $0.type == .service }.firstIndex(where: { $0.id == node.id }) ?? 0
        case .task:
            if node.status == .running {
                row = 1
                indexInRow = nodes.filter { $0.type == .task && $0.status == .running }.firstIndex(where: { $0.id == node.id }) ?? 0
            } else if node.status == .pending {
                row = 4
                indexInRow = nodes.filter { $0.type == .task && $0.status == .pending }.firstIndex(where: { $0.id == node.id }) ?? 0
            } else {
                row = 5
                indexInRow = nodes.filter { $0.status == .completed || $0.status == .failed }.firstIndex(where: { $0.id == node.id }) ?? 0
            }
        case .workflow:
            row = 2
            indexInRow = nodes.filter { $0.type == .workflow }.firstIndex(where: { $0.id == node.id }) ?? 0
        case .scheduled:
            row = 3
            indexInRow = nodes.filter { $0.type == .scheduled }.firstIndex(where: { $0.id == node.id }) ?? 0
        case .memory:
            row = 3
            let scheduledCount = nodes.filter { $0.type == .scheduled }.count
            indexInRow = scheduledCount + (nodes.filter { $0.type == .memory }.firstIndex(where: { $0.id == node.id }) ?? 0)
        }

        return CGPoint(
            x: startX + CGFloat(indexInRow) * colWidth,
            y: startY + CGFloat(row) * rowHeight
        )
    }

    private func currentPosition(for nodeID: String, in size: CGSize) -> CGPoint {
        let node = nodes.first { $0.id == nodeID }
        let base = nodePositions[nodeID] ?? (node.map { defaultPosition(for: $0, in: size) } ?? CGPoint(x: 200, y: 200))
        if let drag = activeDrag[nodeID] {
            return CGPoint(x: base.x + drag.width, y: base.y + drag.height)
        }
        return base
    }

    private func nodeCard(_ node: JobNode) -> some View {
        let isSelected = selectedNodeID == node.id
        return HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(node.statusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    node.status == .running ?
                    Circle().stroke(node.statusColor, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .opacity(0.4) : nil
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(node.subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
            }

            Spacer()

            // Type badge
            Text(node.type.rawValue)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(node.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(node.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? node.color.opacity(0.08) : Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? node.color.opacity(0.3) : Color.white.opacity(0.04), lineWidth: 1)
        )
        .onTapGesture {
            selectedNodeID = selectedNodeID == node.id ? nil : node.id
        }
    }

    // MARK: - Node Detail Panel

    private func nodeDetailPanel(_ node: JobNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 8) {
                    Circle().fill(node.statusColor).frame(width: 10, height: 10)
                    Text(node.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }

                // Info rows
                infoRow("Type", node.type.rawValue.capitalized, node.color)
                infoRow("Status", node.status.rawValue.capitalized, node.statusColor)

                if let agent = node.agentID {
                    infoRow("Agent", agent, .white.opacity(0.6))
                }
                if let started = node.startedAt {
                    infoRow("Started", relativeTime(started), .white.opacity(0.5))
                }

                if !node.dependencies.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEPENDENCIES")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                        ForEach(node.dependencies, id: \.self) { dep in
                            Text(dep)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                if !node.subtitle.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DETAILS")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(node.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.3))
    }

    private func infoRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    // MARK: - Data Refresh

    private func refreshNodes() async {
        var newNodes: [JobNode] = []

        // TaskQueue — active + pending tasks
        let allTasks = await TaskQueue.shared.allTasks()
        for task in allTasks {
            let nodeStatus: JobNode.NodeStatus
            switch task.status {
            case .inProgress: nodeStatus = .running
            case .pending:    nodeStatus = .pending
            case .completed:  nodeStatus = .completed
            case .failed:     nodeStatus = .failed
            default:          nodeStatus = .idle
            }
            newNodes.append(JobNode(
                id: "task-\(task.id)",
                title: task.title,
                subtitle: task.description,
                type: .task,
                status: nodeStatus,
                agentID: task.assignedTo,
                startedAt: task.startedAt,
                dependencies: task.dependsOn
            ))
        }

        // WorkflowEngine — active workflows
        let workflows = await WorkflowEngine.shared.activeWorkflows()
        for wf in workflows {
            let completedSteps = wf.taskIDs.count
            let progress = "\(completedSteps)/\(wf.steps.count) steps"
            newNodes.append(JobNode(
                id: "wf-\(wf.id)",
                title: wf.name,
                subtitle: progress,
                type: .workflow,
                status: wf.status == .running ? .running : .pending,
                agentID: wf.createdBy,
                startedAt: wf.startedAt,
                dependencies: []
            ))
        }

        // CronScheduler — scheduled tasks
        let cronTasks = await CronScheduler.shared.listTasks()
        for cron in cronTasks {
            let nextRun = cron.nextRun.map { "Next: \(relativeTime($0))" } ?? "No schedule"
            newNodes.append(JobNode(
                id: "cron-\(cron.id)",
                title: cron.name,
                subtitle: nextRun,
                type: .scheduled,
                status: cron.enabled ? .idle : .pending,
                agentID: cron.agentID,
                startedAt: cron.lastRun,
                dependencies: []
            ))
        }

        // Services — gateway, bridges, MCP
        newNodes.append(JobNode(
            id: "svc-gateway", title: "Gateway Server",
            subtitle: "Port \(state.serverPort)",
            type: .service, status: state.serverRunning ? .running : .failed,
            agentID: nil, startedAt: state.appStartedAt, dependencies: []
        ))

        if state.ollamaRunning {
            newNodes.append(JobNode(
                id: "svc-ollama", title: "Ollama",
                subtitle: "\(state.ollamaModels.count) models",
                type: .service, status: .running,
                agentID: nil, startedAt: nil, dependencies: []
            ))
        }

        // Memory services
        newNodes.append(JobNode(
            id: "svc-memory", title: "LoA Memory Army",
            subtitle: "Librarian · Searcher · Repairer · Watcher",
            type: .memory, status: .running,
            agentID: nil, startedAt: state.appStartedAt, dependencies: []
        ))

        // Update state
        nodes = newNodes
        activeTaskCount = newNodes.filter { $0.type == .task && $0.status == .running }.count
        serviceCount = newNodes.filter { $0.type == .service && $0.status == .running }.count
        cronCount = newNodes.filter { $0.type == .scheduled }.count
    }
}
#endif
