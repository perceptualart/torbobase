// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow Data Models
// Graph-based workflow representation for the Visual Workflow Designer.
// Nodes (trigger, agent, decision, action, approval) connected by edges.
import Foundation

// MARK: - Visual Workflow

struct VisualWorkflow: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    var enabled: Bool
    var nodes: [VisualNode]
    var connections: [NodeConnection]
    var createdAt: Date
    var lastModifiedAt: Date
    var lastRunAt: Date?
    var runCount: Int

    init(id: String = UUID().uuidString, name: String, description: String = "",
         enabled: Bool = true, nodes: [VisualNode] = [], connections: [NodeConnection] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.enabled = enabled
        self.nodes = nodes
        self.connections = connections
        self.createdAt = Date()
        self.lastModifiedAt = Date()
        self.lastRunAt = nil
        self.runCount = 0
    }

    /// All trigger nodes in this workflow
    var triggers: [VisualNode] { nodes.filter { $0.kind == .trigger } }

    /// Find a node by ID
    func node(_ id: String) -> VisualNode? { nodes.first { $0.id == id } }

    /// Find all nodes connected downstream from a given node
    func downstream(of nodeID: String) -> [NodeConnection] {
        connections.filter { $0.fromNodeID == nodeID }
    }

    /// Find all nodes connected upstream to a given node
    func upstream(of nodeID: String) -> [NodeConnection] {
        connections.filter { $0.toNodeID == nodeID }
    }

    /// Validate the workflow structure
    func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        // Must have at least one trigger
        if triggers.isEmpty {
            errors.append(.init(nodeID: nil, message: "Workflow has no trigger node"))
        }

        // All non-trigger nodes must have at least one incoming connection
        for node in nodes where node.kind != .trigger {
            if upstream(of: node.id).isEmpty {
                errors.append(.init(nodeID: node.id, message: "'\(node.label)' has no incoming connection"))
            }
        }

        // Decision nodes must have at least one outgoing connection
        for node in nodes where node.kind == .decision {
            if downstream(of: node.id).isEmpty {
                errors.append(.init(nodeID: node.id, message: "Decision '\(node.label)' has no outgoing paths"))
            }
        }

        // Check for cycles (simple DFS)
        if hasCycle() {
            errors.append(.init(nodeID: nil, message: "Workflow contains a cycle"))
        }

        return errors
    }

    private func hasCycle() -> Bool {
        var visited = Set<String>()
        var stack = Set<String>()

        func dfs(_ nodeID: String) -> Bool {
            if stack.contains(nodeID) { return true }
            if visited.contains(nodeID) { return false }
            visited.insert(nodeID)
            stack.insert(nodeID)
            for conn in downstream(of: nodeID) {
                if dfs(conn.toNodeID) { return true }
            }
            stack.remove(nodeID)
            return false
        }

        for node in nodes {
            if dfs(node.id) { return true }
        }
        return false
    }

    struct ValidationError: Codable {
        let nodeID: String?
        let message: String
    }
}

// MARK: - Visual Node

struct VisualNode: Codable, Identifiable {
    let id: String
    var kind: NodeKind
    var label: String
    var positionX: Double
    var positionY: Double
    var config: NodeConfig

    init(id: String = UUID().uuidString, kind: NodeKind, label: String,
         positionX: Double = 0, positionY: Double = 0, config: NodeConfig = .empty) {
        self.id = id
        self.kind = kind
        self.label = label
        self.positionX = positionX
        self.positionY = positionY
        self.config = config
    }
}

// MARK: - Node Kind

enum NodeKind: String, Codable, CaseIterable {
    case trigger
    case agent
    case decision
    case action
    case approval

    var displayName: String {
        switch self {
        case .trigger:  return "Trigger"
        case .agent:    return "Agent"
        case .decision: return "Decision"
        case .action:   return "Action"
        case .approval: return "Approval"
        }
    }

    var iconName: String {
        switch self {
        case .trigger:  return "bolt.fill"
        case .agent:    return "brain"
        case .decision: return "arrow.triangle.branch"
        case .action:   return "gearshape.fill"
        case .approval: return "hand.raised.fill"
        }
    }

    var tintColorHex: String {
        switch self {
        case .trigger:  return "#F59E0B"  // amber
        case .agent:    return "#8B5CF6"  // purple
        case .decision: return "#3B82F6"  // blue
        case .action:   return "#10B981"  // green
        case .approval: return "#EF4444"  // red
        }
    }
}

// MARK: - Node Config (type-safe wrapper using JSON)

struct NodeConfig: Codable {
    var values: [String: ConfigValue]

    static let empty = NodeConfig(values: [:])

    subscript(key: String) -> ConfigValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func string(_ key: String) -> String? {
        if case .string(let v) = values[key] { return v }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case .number(let v) = values[key] { return v }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let v) = values[key] { return v }
        return nil
    }

    func integer(_ key: String) -> Int? {
        if let d = double(key) { return Int(d) }
        return nil
    }

    mutating func set(_ key: String, _ value: String) { values[key] = .string(value) }
    mutating func set(_ key: String, _ value: Double) { values[key] = .number(value) }
    mutating func set(_ key: String, _ value: Bool) { values[key] = .bool(value) }
}

enum ConfigValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(ConfigValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported config value type"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b):   try container.encode(b)
        }
    }
}

// MARK: - Trigger Types

enum TriggerKind: String, Codable, CaseIterable {
    case schedule     // Cron expression
    case webhook      // Incoming HTTP webhook
    case telegram     // Telegram message keyword
    case email        // Email filter
    case fileChange   // File system change
    case manual       // Manual execution

    var displayName: String {
        switch self {
        case .schedule:   return "Schedule (Cron)"
        case .webhook:    return "Webhook"
        case .telegram:   return "Telegram Message"
        case .email:      return "Email"
        case .fileChange: return "File Change"
        case .manual:     return "Manual"
        }
    }

    /// Config keys required for this trigger type
    var configKeys: [(key: String, label: String, placeholder: String)] {
        switch self {
        case .schedule:   return [("cron", "Cron Expression", "0 */1 * * *"), ("timezone", "Timezone", "UTC")]
        case .webhook:    return [("path", "Webhook Path", "/hook/my-workflow")]
        case .telegram:   return [("keyword", "Trigger Keyword", "urgent")]
        case .email:      return [("filter", "Subject Filter", "Invoice"), ("from", "From Filter", "")]
        case .fileChange: return [("path", "Watch Path", "~/Documents"), ("pattern", "File Pattern", "*.pdf")]
        case .manual:     return []
        }
    }
}

// MARK: - Action Types

enum ActionKind: String, Codable, CaseIterable {
    case sendMessage    // Send to a messaging platform
    case writeFile      // Write file to disk
    case runCommand     // Execute shell command
    case callWebhook    // Call external webhook
    case sendEmail      // Send email
    case broadcast      // Broadcast to channel

    var displayName: String {
        switch self {
        case .sendMessage:  return "Send Message"
        case .writeFile:    return "Write File"
        case .runCommand:   return "Run Command"
        case .callWebhook:  return "Call Webhook"
        case .sendEmail:    return "Send Email"
        case .broadcast:    return "Broadcast"
        }
    }

    var configKeys: [(key: String, label: String, placeholder: String)] {
        switch self {
        case .sendMessage:  return [("platform", "Platform", "telegram"), ("target", "Chat/Channel ID", ""), ("message", "Message Template", "{{result}}")]
        case .writeFile:    return [("path", "File Path", "~/Documents/output.txt"), ("content", "Content Template", "{{result}}")]
        case .runCommand:   return [("command", "Command", "echo 'done'")]
        case .callWebhook:  return [("url", "Webhook URL", "https://"), ("method", "HTTP Method", "POST"), ("body", "Body Template", "{{result}}")]
        case .sendEmail:    return [("to", "Recipient", ""), ("subject", "Subject", ""), ("body", "Body Template", "{{result}}")]
        case .broadcast:    return [("channel", "Channel ID", ""), ("message", "Message Template", "{{result}}")]
        }
    }
}

// MARK: - Node Connection

struct NodeConnection: Codable, Identifiable {
    let id: String
    let fromNodeID: String
    let toNodeID: String
    var label: String?          // "true" / "false" for decision branches, nil otherwise

    init(id: String = UUID().uuidString, from: String, to: String, label: String? = nil) {
        self.id = id
        self.fromNodeID = from
        self.toNodeID = to
        self.label = label
    }
}

// MARK: - Execution Models

struct WorkflowExecution: Codable, Identifiable {
    let id: String
    let workflowID: String
    let workflowName: String
    var status: ExecutionStatus
    var triggeredBy: String         // "schedule", "webhook", "manual", etc.
    var nodeStates: [String: NodeExecutionState]   // nodeID → state
    var context: [String: String]   // Accumulated context flowing through the graph
    let startedAt: Date
    var completedAt: Date?
    var error: String?

    init(workflowID: String, workflowName: String, triggeredBy: String) {
        self.id = UUID().uuidString
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.status = .running
        self.triggeredBy = triggeredBy
        self.nodeStates = [:]
        self.context = [:]
        self.startedAt = Date()
    }

    var elapsed: TimeInterval { (completedAt ?? Date()).timeIntervalSince(startedAt) }
}

enum ExecutionStatus: String, Codable {
    case running
    case completed
    case failed
    case cancelled
    case waitingApproval
    case timedOut
}

struct NodeExecutionState: Codable {
    var status: NodeStatus
    var result: String?
    var error: String?
    var startedAt: Date?
    var completedAt: Date?
}

enum NodeStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case skipped          // Decision branch not taken
    case waitingApproval
}

// MARK: - Workflow Store

actor VisualWorkflowStore {
    static let shared = VisualWorkflowStore()

    private var workflows: [String: VisualWorkflow] = [:]
    private let storePath: String

    init() {
        storePath = PlatformPaths.dataDir + "/visual_workflows.json"
        let loaded = Self.loadFromDisk(path: storePath)
        workflows = loaded
        if !loaded.isEmpty {
            TorboLog.info("Loaded \(loaded.count) visual workflow(s)", subsystem: "VWorkflow")
        }
    }

    private nonisolated static func loadFromDisk(path: String) -> [String: VisualWorkflow] {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([VisualWorkflow].self, from: data) else { return [:] }
        var map: [String: VisualWorkflow] = [:]
        for wf in list { map[wf.id] = wf }
        return map
    }

    // MARK: - CRUD

    func save(_ workflow: VisualWorkflow) {
        var wf = workflow
        wf.lastModifiedAt = Date()
        workflows[wf.id] = wf
        persist()
    }

    func get(_ id: String) -> VisualWorkflow? { workflows[id] }

    func list() -> [VisualWorkflow] {
        Array(workflows.values).sorted { $0.lastModifiedAt > $1.lastModifiedAt }
    }

    func delete(_ id: String) {
        workflows.removeValue(forKey: id)
        persist()
    }

    func updateEnabled(_ id: String, enabled: Bool) {
        guard var wf = workflows[id] else { return }
        wf.enabled = enabled
        wf.lastModifiedAt = Date()
        workflows[id] = wf
        persist()
    }

    func markRun(_ id: String) {
        guard var wf = workflows[id] else { return }
        wf.lastRunAt = Date()
        wf.runCount += 1
        workflows[id] = wf
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(workflows.values)) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        } catch {
            TorboLog.error("Failed to write visual_workflows.json: \(error)", subsystem: "VWorkflow")
        }
    }
}
