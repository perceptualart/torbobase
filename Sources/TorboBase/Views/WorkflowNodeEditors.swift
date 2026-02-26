// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Workflow Node Configuration Editors
// Sheet-based editors for each node type in the Visual Workflow Designer.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Node Editor Sheet

struct WorkflowNodeEditorSheet: View {
    let node: VisualNode
    let onSave: (VisualNode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedNode: VisualNode
    @State private var agentList: [String] = []

    init(node: VisualNode, onSave: @escaping (VisualNode) -> Void) {
        self.node = node
        self.onSave = onSave
        _editedNode = State(initialValue: node)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: node.kind.iconName)
                    .foregroundStyle(Color(hex: node.kind.tintColorHex))
                Text("Edit \(node.kind.displayName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.white.opacity(0.5))
                Button("Save") { onSave(editedNode); dismiss() }
                    .foregroundStyle(.blue)
                    .fontWeight(.semibold)
            }
            .padding(16)
            .background(Color(white: 0.08))

            Divider().overlay(Color.white.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Label field (all nodes)
                    labelField

                    Divider().overlay(Color.white.opacity(0.06))

                    // Type-specific editor
                    switch editedNode.kind {
                    case .trigger:  triggerEditor
                    case .agent:    agentEditor
                    case .decision: decisionEditor
                    case .action:   actionEditor
                    case .approval: approvalEditor
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 500)
        .background(Color(white: 0.10))
        .task { await loadAgents() }
    }

    // MARK: - Common Fields

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Label")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            TextField("Node label", text: $editedNode.label)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Trigger Editor

    private var triggerEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRIGGER TYPE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            Picker("Type", selection: triggerKindBinding) {
                ForEach(TriggerKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.menu)

            if let triggerKind = TriggerKind(rawValue: editedNode.config.string("triggerKind") ?? "manual") {
                ForEach(triggerKind.configKeys, id: \.key) { cfg in
                    configField(key: cfg.key, label: cfg.label, placeholder: cfg.placeholder)
                }

                if triggerKind == .schedule {
                    cronHelp
                }
            }
        }
    }

    private var triggerKindBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("triggerKind") ?? "manual" },
            set: { editedNode.config.set("triggerKind", $0) }
        )
    }

    private var cronHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cron Examples")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Group {
                Text("*/5 * * * *  — Every 5 minutes")
                Text("0 9 * * 1-5  — 9am weekdays")
                Text("0 18 * * *   — 6pm daily")
                Text("0 */1 * * *  — Every hour")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Agent Editor

    private var agentEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            Picker("Agent", selection: agentIDBinding) {
                ForEach(agentList, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            .pickerStyle(.menu)

            Text("PROMPT OVERRIDE (Optional)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            TextEditor(text: promptBinding)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.1))
                )

            Text("Use {{context}} or {{result}} to inject upstream data.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private var agentIDBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("agentID") ?? "sid" },
            set: { editedNode.config.set("agentID", $0) }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("prompt") ?? "" },
            set: { editedNode.config.set("prompt", $0) }
        )
    }

    // MARK: - Decision Editor

    private var decisionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONDITION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            TextField("Condition expression", text: conditionBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            VStack(alignment: .leading, spacing: 4) {
                Text("Available Expressions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Group {
                    expressionHelp("contains('urgent')", "Context contains 'urgent'")
                    expressionHelp("equals('yes')", "Last result equals 'yes'")
                    expressionHelp("length > 100", "Combined context > 100 chars")
                    expressionHelp("not_empty", "Context has data")
                    expressionHelp("true / false", "Always true or false")
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 20) {
                Label("True Path", systemImage: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Label("False Path", systemImage: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    private var conditionBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("condition") ?? "true" },
            set: { editedNode.config.set("condition", $0) }
        )
    }

    private func expressionHelp(_ expr: String, _ desc: String) -> some View {
        HStack {
            Text(expr)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.blue.opacity(0.7))
                .frame(width: 160, alignment: .leading)
            Text(desc)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Action Editor

    private var actionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACTION TYPE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            Picker("Action", selection: actionKindBinding) {
                ForEach(ActionKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .pickerStyle(.menu)

            if let actionKind = ActionKind(rawValue: editedNode.config.string("actionKind") ?? "sendMessage") {
                ForEach(actionKind.configKeys, id: \.key) { cfg in
                    if cfg.key == "body" || cfg.key == "content" || cfg.key == "message" {
                        multilineConfigField(key: cfg.key, label: cfg.label, placeholder: cfg.placeholder)
                    } else {
                        configField(key: cfg.key, label: cfg.label, placeholder: cfg.placeholder)
                    }
                }
            }

            Text("Use {{result}} for previous node output, {{context}} for all context.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private var actionKindBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("actionKind") ?? "sendMessage" },
            set: { editedNode.config.set("actionKind", $0) }
        )
    }

    // MARK: - Approval Editor

    private var approvalEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APPROVAL MESSAGE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            TextEditor(text: approvalMessageBinding)
                .font(.system(size: 11))
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.1))
                )

            Text("TIMEOUT (seconds)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)

            HStack {
                TextField("300", text: timeoutBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("seconds (0 = no auto-approve)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }

            HStack(spacing: 8) {
                ForEach(["60", "300", "600", "3600"], id: \.self) { preset in
                    Button(presetLabel(preset)) {
                        editedNode.config.set("timeout", Double(preset) ?? 300)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var approvalMessageBinding: Binding<String> {
        Binding(
            get: { editedNode.config.string("message") ?? "Approve this step?" },
            set: { editedNode.config.set("message", $0) }
        )
    }

    private var timeoutBinding: Binding<String> {
        Binding(
            get: { String(Int(editedNode.config.double("timeout") ?? 300)) },
            set: { editedNode.config.set("timeout", Double($0) ?? 300) }
        )
    }

    private func presetLabel(_ seconds: String) -> String {
        switch seconds {
        case "60": return "1m"
        case "300": return "5m"
        case "600": return "10m"
        case "3600": return "1h"
        default: return seconds
        }
    }

    // MARK: - Helpers

    private func configField(key: String, label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            TextField(placeholder, text: configBinding(key))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func multilineConfigField(key: String, label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            TextEditor(text: configBinding(key))
                .font(.system(size: 11))
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.1))
                )
        }
    }

    private func configBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { editedNode.config.string(key) ?? "" },
            set: { editedNode.config.set(key, $0) }
        )
    }

    private func loadAgents() async {
        let agents = await AgentConfigManager.shared.listAgents()
        agentList = agents.map(\.id)
    }
}

#endif
