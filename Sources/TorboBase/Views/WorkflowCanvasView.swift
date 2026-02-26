// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow Canvas (SwiftUI)
// Drag-and-drop canvas for building visual workflows.
// Nodes are placed on an infinite canvas with zoom/pan. Connect nodes by dragging between ports.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Workflow Canvas View

struct WorkflowCanvasView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var vm = WorkflowCanvasVM()

    var body: some View {
        HStack(spacing: 0) {
            // Left: Workflow list
            workflowListPanel
                .frame(width: 220)

            Divider().overlay(Color.white.opacity(0.06))

            // Center: Canvas
            if let workflow = vm.selectedWorkflow {
                VStack(spacing: 0) {
                    canvasToolbar(workflow)
                    ZStack {
                        canvasArea(workflow)
                        if vm.showNodePalette {
                            nodePalette
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                }
            } else {
                emptyState
            }
        }
        .background(Color.black)
        .task { await vm.loadWorkflows() }
    }

    // MARK: - Workflow List Panel

    private var workflowListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("WORKFLOWS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(2)
                Spacer()
                Button { vm.createNewWorkflow() } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.06))

            // Template section
            DisclosureGroup(isExpanded: $vm.showTemplates) {
                ForEach(vm.templates, id: \.name) { template in
                    Button {
                        vm.createFromTemplate(template)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue.opacity(0.7))
                            Text(template.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Text("Templates")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().overlay(Color.white.opacity(0.06))

            // Workflow list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vm.workflows, id: \.id) { wf in
                        workflowRow(wf)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            Spacer()
        }
        .background(Color(white: 0.08))
    }

    private func workflowRow(_ wf: VisualWorkflow) -> some View {
        let isSelected = vm.selectedWorkflow?.id == wf.id
        return Button {
            vm.selectWorkflow(wf)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(wf.enabled ? .green : .gray)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wf.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
                        .lineLimit(1)
                    Text("\(wf.nodes.count) nodes")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                if wf.runCount > 0 {
                    Text("\(wf.runCount)x")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate") { vm.duplicateWorkflow(wf) }
            Button(wf.enabled ? "Disable" : "Enable") { vm.toggleEnabled(wf) }
            Divider()
            Button("Delete", role: .destructive) { vm.deleteWorkflow(wf) }
        }
    }

    // MARK: - Canvas Toolbar

    private func canvasToolbar(_ workflow: VisualWorkflow) -> some View {
        HStack(spacing: 12) {
            // Workflow name (editable)
            TextField("Workflow Name", text: Binding(
                get: { vm.selectedWorkflow?.name ?? "" },
                set: { vm.updateWorkflowName($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: 300)

            Spacer()

            // Palette toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.showNodePalette.toggle()
                }
            } label: {
                Label("Nodes", systemImage: "square.grid.3x3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(vm.showNodePalette ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(vm.showNodePalette ? 0.1 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Validate
            Button {
                vm.validateWorkflow()
            } label: {
                Label(vm.validationErrors.isEmpty ? "Valid" : "\(vm.validationErrors.count) errors",
                      systemImage: vm.validationErrors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(vm.validationErrors.isEmpty ? .green : .orange)
            }
            .buttonStyle(.plain)

            // Run
            Button {
                Task { await vm.executeWorkflow() }
            } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(!vm.validationErrors.isEmpty)

            // Zoom controls
            HStack(spacing: 4) {
                Button { vm.zoom(by: -0.1) } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Text("\(Int(vm.canvasScale * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36)

                Button { vm.zoom(by: 0.1) } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // Save indicator
            if vm.hasUnsavedChanges {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.06))
    }

    // MARK: - Canvas Area

    private func canvasArea(_ workflow: VisualWorkflow) -> some View {
        GeometryReader { geo in
            ZStack {
                // Grid background
                canvasGrid(size: geo.size)

                // Connections layer
                ForEach(workflow.connections, id: \.id) { conn in
                    connectionLine(conn, workflow: workflow)
                }

                // Active connection (being drawn)
                if let start = vm.connectionStart, let end = vm.connectionDragPoint {
                    Path { path in
                        let s = canvasPoint(start)
                        path.move(to: s)
                        path.addLine(to: end)
                    }
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                // Nodes layer
                ForEach(workflow.nodes, id: \.id) { node in
                    nodeView(node, workflow: workflow)
                        .position(canvasPoint(CGPoint(x: node.positionX, y: node.positionY)))
                }
            }
            .scaleEffect(vm.canvasScale)
            .offset(vm.canvasOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if vm.selectedNodeID == nil && vm.connectionStart == nil {
                            vm.canvasOffset = CGSize(
                                width: vm.canvasOffsetStart.width + value.translation.width,
                                height: vm.canvasOffsetStart.height + value.translation.height
                            )
                        }
                    }
                    .onEnded { _ in
                        vm.canvasOffsetStart = vm.canvasOffset
                    }
            )
            .onTapGesture {
                vm.selectedNodeID = nil
                vm.showNodeEditor = false
            }
        }
        .background(Color(white: 0.04))
        .clipped()
        .sheet(isPresented: $vm.showNodeEditor) {
            if let nodeID = vm.selectedNodeID,
               let node = vm.selectedWorkflow?.node(nodeID) {
                WorkflowNodeEditorSheet(node: node) { updated in
                    vm.updateNode(updated)
                }
            }
        }
    }

    private func canvasGrid(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let spacing: CGFloat = 30 * vm.canvasScale
            let offset = vm.canvasOffset
            let cols = Int(canvasSize.width / spacing) + 2
            let rows = Int(canvasSize.height / spacing) + 2
            let startX = offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = offset.height.truncatingRemainder(dividingBy: spacing)

            for col in 0..<cols {
                for row in 0..<rows {
                    let x = startX + CGFloat(col) * spacing
                    let y = startY + CGFloat(row) * spacing
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(.white.opacity(0.06))
                    )
                }
            }
        }
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        point // Scale/offset is applied at the ZStack level
    }

    // MARK: - Connection Lines

    private func connectionLine(_ conn: NodeConnection, workflow: VisualWorkflow) -> some View {
        let fromNode = workflow.node(conn.fromNodeID)
        let toNode = workflow.node(conn.toNodeID)
        let isActive = vm.activeNodeIDs.contains(conn.fromNodeID) || vm.activeNodeIDs.contains(conn.toNodeID)

        return ZStack {
            if let from = fromNode, let to = toNode {
                Path { path in
                    let start = CGPoint(x: from.positionX + 80, y: from.positionY + 25)
                    let end = CGPoint(x: to.positionX - 10, y: to.positionY + 25)
                    let midX = (start.x + end.x) / 2

                    path.move(to: start)
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: midX, y: start.y),
                        control2: CGPoint(x: midX, y: end.y)
                    )
                }
                .stroke(
                    isActive ? Color.green : Color.white.opacity(0.2),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 1.5)
                )

                // Label
                if let label = conn.label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(label == "true" ? .green : .red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .position(x: (from.positionX + to.positionX) / 2 + 40,
                                  y: (from.positionY + to.positionY) / 2 + 25)
                }
            }
        }
    }

    // MARK: - Node View

    private func nodeView(_ node: VisualNode, workflow: VisualWorkflow) -> some View {
        let isSelected = vm.selectedNodeID == node.id
        let isActive = vm.activeNodeIDs.contains(node.id)
        let hexColor = Color(hex: node.kind.tintColorHex)

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: node.kind.iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hexColor)
                Text(node.kind.displayName.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(hexColor.opacity(0.8))
                    .tracking(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(hexColor.opacity(0.15))

            // Body
            VStack(alignment: .leading, spacing: 4) {
                Text(node.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)

                // Config preview
                if let detail = nodeConfigPreview(node) {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 160)
        .background(Color(white: isSelected ? 0.16 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.green : (isSelected ? hexColor : Color.white.opacity(0.1)),
                        lineWidth: isActive ? 2 : (isSelected ? 1.5 : 0.5))
        )
        .shadow(color: isActive ? .green.opacity(0.3) : .clear, radius: 8)
        .gesture(
            DragGesture()
                .onChanged { value in
                    vm.moveNode(node.id, to: CGPoint(
                        x: node.positionX + value.translation.width / vm.canvasScale,
                        y: node.positionY + value.translation.height / vm.canvasScale
                    ))
                }
                .onEnded { _ in
                    vm.commitNodePosition(node.id)
                }
        )
        .onTapGesture(count: 2) {
            vm.selectedNodeID = node.id
            vm.showNodeEditor = true
        }
        .onTapGesture {
            vm.selectedNodeID = node.id
        }
        .contextMenu {
            Button("Edit") {
                vm.selectedNodeID = node.id
                vm.showNodeEditor = true
            }
            Button("Duplicate") { vm.duplicateNode(node) }
            Divider()
            Button("Connect From This") { vm.startConnection(from: node.id) }
            Divider()
            Button("Delete", role: .destructive) { vm.deleteNode(node.id) }
        }
    }

    private func nodeConfigPreview(_ node: VisualNode) -> String? {
        switch node.kind {
        case .trigger:
            if let kind = node.config.string("triggerKind") { return kind }
        case .agent:
            if let id = node.config.string("agentID") { return "Agent: \(id)" }
        case .decision:
            if let cond = node.config.string("condition") { return cond }
        case .action:
            if let kind = node.config.string("actionKind") { return kind }
        case .approval:
            if let timeout = node.config.double("timeout") { return "Timeout: \(Int(timeout))s" }
        }
        return nil
    }

    // MARK: - Node Palette

    private var nodePalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADD NODE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(2)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(NodeKind.allCases, id: \.self) { kind in
                Button {
                    vm.addNode(kind: kind)
                    withAnimation { vm.showNodePalette = false }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: kind.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: kind.tintColorHex))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                            Text(paletteDescription(kind))
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 200)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 12)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func paletteDescription(_ kind: NodeKind) -> String {
        switch kind {
        case .trigger:  return "Start the workflow"
        case .agent:    return "Process with AI agent"
        case .decision: return "Conditional branching"
        case .action:   return "Perform an action"
        case .approval: return "Wait for human approval"
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.15))
            Text("Select a workflow or create a new one")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
            Button("New Workflow") { vm.createNewWorkflow() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.04))
    }
}

// MARK: - View Model

@MainActor
class WorkflowCanvasVM: ObservableObject {
    @Published var workflows: [VisualWorkflow] = []
    @Published var selectedWorkflow: VisualWorkflow?
    @Published var selectedNodeID: String?
    @Published var showNodePalette = false
    @Published var showNodeEditor = false
    @Published var showTemplates = false
    @Published var validationErrors: [VisualWorkflow.ValidationError] = []
    @Published var hasUnsavedChanges = false
    @Published var activeNodeIDs: Set<String> = []
    @Published var templates: [VisualWorkflow] = []

    // Canvas state
    @Published var canvasScale: CGFloat = 1.0
    @Published var canvasOffset: CGSize = .zero
    var canvasOffsetStart: CGSize = .zero

    // Connection drawing
    @Published var connectionStart: CGPoint?
    @Published var connectionDragPoint: CGPoint?

    // Node position tracking
    private var originalPositions: [String: CGPoint] = [:]

    func loadWorkflows() async {
        workflows = await VisualWorkflowStore.shared.list()
        templates = WorkflowTemplateLibrary.allTemplates()
    }

    func selectWorkflow(_ wf: VisualWorkflow) {
        selectedWorkflow = wf
        selectedNodeID = nil
        validationErrors = wf.validate()
        canvasScale = 1.0
        canvasOffset = .zero
        canvasOffsetStart = .zero
        activeNodeIDs = []
    }

    func createNewWorkflow() {
        let wf = VisualWorkflow(name: "New Workflow")
        Task {
            await VisualWorkflowStore.shared.save(wf)
            await loadWorkflows()
            selectWorkflow(wf)
        }
    }

    func createFromTemplate(_ template: VisualWorkflow) {
        var wf = template
        wf = VisualWorkflow(
            name: template.name,
            description: template.description,
            nodes: template.nodes.map { n in
                VisualNode(kind: n.kind, label: n.label,
                           positionX: n.positionX, positionY: n.positionY, config: n.config)
            },
            connections: [] // Re-create connections with new IDs
        )
        // Rebuild connections using node index mapping
        var indexMap: [String: String] = [:]
        for (idx, original) in template.nodes.enumerated() {
            if idx < wf.nodes.count {
                indexMap[original.id] = wf.nodes[idx].id
            }
        }
        wf.connections = template.connections.compactMap { conn in
            guard let newFrom = indexMap[conn.fromNodeID],
                  let newTo = indexMap[conn.toNodeID] else { return nil }
            return NodeConnection(from: newFrom, to: newTo, label: conn.label)
        }

        Task {
            await VisualWorkflowStore.shared.save(wf)
            await loadWorkflows()
            selectWorkflow(wf)
        }
    }

    func duplicateWorkflow(_ wf: VisualWorkflow) {
        var copy = wf
        copy = VisualWorkflow(name: wf.name + " (copy)", description: wf.description,
                              nodes: wf.nodes, connections: wf.connections)
        Task {
            await VisualWorkflowStore.shared.save(copy)
            await loadWorkflows()
        }
    }

    func deleteWorkflow(_ wf: VisualWorkflow) {
        Task {
            await VisualWorkflowStore.shared.delete(wf.id)
            if selectedWorkflow?.id == wf.id { selectedWorkflow = nil }
            await loadWorkflows()
        }
    }

    func toggleEnabled(_ wf: VisualWorkflow) {
        Task {
            await VisualWorkflowStore.shared.updateEnabled(wf.id, enabled: !wf.enabled)
            await loadWorkflows()
        }
    }

    func updateWorkflowName(_ name: String) {
        guard var wf = selectedWorkflow else { return }
        wf.name = name
        selectedWorkflow = wf
        hasUnsavedChanges = true
        saveDebounced()
    }

    // MARK: - Node Operations

    func addNode(kind: NodeKind) {
        guard var wf = selectedWorkflow else { return }
        let node = VisualNode(
            kind: kind,
            label: kind.displayName,
            positionX: 200 + Double(wf.nodes.count) * 200,
            positionY: 150
        )
        wf.nodes.append(node)
        selectedWorkflow = wf
        selectedNodeID = node.id
        hasUnsavedChanges = true
        saveDebounced()
    }

    func updateNode(_ updated: VisualNode) {
        guard var wf = selectedWorkflow else { return }
        if let idx = wf.nodes.firstIndex(where: { $0.id == updated.id }) {
            wf.nodes[idx] = updated
            selectedWorkflow = wf
            hasUnsavedChanges = true
            validationErrors = wf.validate()
            saveDebounced()
        }
    }

    func deleteNode(_ nodeID: String) {
        guard var wf = selectedWorkflow else { return }
        wf.nodes.removeAll { $0.id == nodeID }
        wf.connections.removeAll { $0.fromNodeID == nodeID || $0.toNodeID == nodeID }
        selectedWorkflow = wf
        if selectedNodeID == nodeID { selectedNodeID = nil }
        hasUnsavedChanges = true
        validationErrors = wf.validate()
        saveDebounced()
    }

    func duplicateNode(_ node: VisualNode) {
        guard var wf = selectedWorkflow else { return }
        let copy = VisualNode(
            kind: node.kind,
            label: node.label + " (copy)",
            positionX: node.positionX + 40,
            positionY: node.positionY + 40,
            config: node.config
        )
        wf.nodes.append(copy)
        selectedWorkflow = wf
        hasUnsavedChanges = true
        saveDebounced()
    }

    func moveNode(_ nodeID: String, to point: CGPoint) {
        guard var wf = selectedWorkflow else { return }
        if let idx = wf.nodes.firstIndex(where: { $0.id == nodeID }) {
            if originalPositions[nodeID] == nil {
                originalPositions[nodeID] = CGPoint(x: wf.nodes[idx].positionX, y: wf.nodes[idx].positionY)
            }
            wf.nodes[idx].positionX = point.x
            wf.nodes[idx].positionY = point.y
            selectedWorkflow = wf
        }
    }

    func commitNodePosition(_ nodeID: String) {
        originalPositions.removeValue(forKey: nodeID)
        hasUnsavedChanges = true
        saveDebounced()
    }

    // MARK: - Connections

    func startConnection(from nodeID: String) {
        if let node = selectedWorkflow?.node(nodeID) {
            connectionStart = CGPoint(x: node.positionX + 80, y: node.positionY + 25)
        }
    }

    func addConnection(from: String, to: String, label: String? = nil) {
        guard var wf = selectedWorkflow else { return }
        // Prevent duplicates
        if wf.connections.contains(where: { $0.fromNodeID == from && $0.toNodeID == to }) { return }
        let conn = NodeConnection(from: from, to: to, label: label)
        wf.connections.append(conn)
        selectedWorkflow = wf
        hasUnsavedChanges = true
        validationErrors = wf.validate()
        saveDebounced()
    }

    // MARK: - Canvas Controls

    func zoom(by delta: CGFloat) {
        canvasScale = max(0.3, min(3.0, canvasScale + delta))
    }

    func validateWorkflow() {
        guard let wf = selectedWorkflow else { return }
        validationErrors = wf.validate()
    }

    func executeWorkflow() async {
        guard let wf = selectedWorkflow, validationErrors.isEmpty else { return }
        activeNodeIDs = Set(wf.triggers.map(\.id))
        _ = await WorkflowExecutor.shared.execute(workflow: wf)
        activeNodeIDs = []
    }

    // MARK: - Save

    private var saveTask: Task<Void, Never>?

    func saveDebounced() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled, let wf = selectedWorkflow else { return }
            await VisualWorkflowStore.shared.save(wf)
            hasUnsavedChanges = false
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}

#endif
