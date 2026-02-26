// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent Teams Data Model
// Defines the structures for multi-agent team coordination.

import Foundation

// MARK: - Agent Team

struct AgentTeam: Codable, Identifiable {
    let id: String
    var name: String
    var coordinatorAgentID: String       // Lead agent that decomposes tasks
    var memberAgentIDs: [String]         // Specialist agents
    var description: String              // What this team does
    let createdAt: Date
    var lastUsedAt: Date?

    init(id: String = UUID().uuidString, name: String, coordinatorAgentID: String,
         memberAgentIDs: [String], description: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.coordinatorAgentID = coordinatorAgentID
        self.memberAgentIDs = memberAgentIDs
        self.description = description
        self.createdAt = createdAt
    }

    /// All agent IDs involved (coordinator + members)
    var allAgentIDs: [String] {
        [coordinatorAgentID] + memberAgentIDs
    }
}

// MARK: - Team Task

enum TeamTaskStatus: String, Codable {
    case pending
    case decomposing      // Coordinator is breaking down the task
    case running          // Subtasks are executing
    case aggregating      // Coordinator is combining results
    case completed
    case failed
    case cancelled
}

struct TeamTask: Codable, Identifiable {
    let id: String
    let teamID: String
    var description: String
    var subtasks: [Subtask]
    var status: TeamTaskStatus
    var result: TeamResult?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var error: String?

    init(teamID: String, description: String) {
        self.id = UUID().uuidString
        self.teamID = teamID
        self.description = description
        self.subtasks = []
        self.status = .pending
        self.result = nil
        self.createdAt = Date()
    }
}

// MARK: - Subtask

enum SubtaskStatus: String, Codable {
    case pending
    case blocked          // Waiting on dependencies
    case running
    case completed
    case failed
}

struct Subtask: Codable, Identifiable {
    let id: String
    var description: String
    var assignedTo: String               // Agent ID
    var status: SubtaskStatus
    var result: String?
    var dependencies: [String]           // Other subtask IDs that must complete first
    var error: String?
    var startedAt: Date?
    var completedAt: Date?

    init(description: String, assignedTo: String, dependencies: [String] = []) {
        self.id = UUID().uuidString
        self.description = description
        self.assignedTo = assignedTo
        self.status = dependencies.isEmpty ? .pending : .blocked
        self.dependencies = dependencies
    }
}

// MARK: - Team Result

struct TeamResult: Codable {
    let subtaskResults: [String: String]  // Subtask ID -> result
    let aggregatedResult: String
    let completedAt: Date

    init(subtaskResults: [String: String], aggregatedResult: String) {
        self.subtaskResults = subtaskResults
        self.aggregatedResult = aggregatedResult
        self.completedAt = Date()
    }
}

// MARK: - Team Execution Record

struct TeamExecution: Codable, Identifiable {
    let id: String
    let teamID: String
    let taskDescription: String
    let subtaskCount: Int
    let status: TeamTaskStatus
    let result: String?
    let error: String?
    let startedAt: Date
    let completedAt: Date?
    let durationSeconds: Int?

    init(task: TeamTask) {
        self.id = task.id
        self.teamID = task.teamID
        self.taskDescription = task.description
        self.subtaskCount = task.subtasks.count
        self.status = task.status
        self.result = task.result?.aggregatedResult
        self.error = task.error
        self.startedAt = task.startedAt ?? task.createdAt
        self.completedAt = task.completedAt
        if let start = task.startedAt, let end = task.completedAt {
            self.durationSeconds = Int(end.timeIntervalSince(start))
        } else {
            self.durationSeconds = nil
        }
    }
}

// MARK: - Shared Context

/// Thread-safe shared context store for team agents to exchange data during execution.
/// Keys are strings, values are JSON-encodable strings (agents serialize their own data).
struct TeamSharedContext: Codable {
    var entries: [String: String] = [:]

    mutating func set(_ key: String, value: String) {
        entries[key] = value
    }

    func get(_ key: String) -> String? {
        entries[key]
    }

    mutating func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }

    mutating func clear() {
        entries.removeAll()
    }
}
