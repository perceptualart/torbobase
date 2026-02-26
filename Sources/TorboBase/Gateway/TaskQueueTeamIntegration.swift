// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — TaskQueue ↔ Team Coordinator Integration
// Bridges the existing TaskQueue/ProactiveAgent flow with the Agent Teams system.
// When a task is assigned to a team, it routes through TeamCoordinator instead of ProactiveAgent.

import Foundation

// MARK: - Team Task Router

/// Routes incoming tasks to either the standard ProactiveAgent flow or TeamCoordinator,
/// depending on whether the task is assigned to a team.
actor TeamTaskRouter {
    static let shared = TeamTaskRouter()

    /// Team ID assignments: maps task patterns or explicit team IDs to teams
    private var teamAssignments: [String: String] = [:]  // taskID -> teamID

    // MARK: - Task Routing

    /// Check if a task description should be handled by a team.
    /// Returns the team ID if a team is assigned, nil for standard agent flow.
    func teamForTask(title: String, description: String) async -> AgentTeam? {
        let teams = await TeamCoordinator.shared.listTeams()

        // Check if description explicitly references a team
        let text = (title + " " + description).lowercased()
        for team in teams {
            if text.contains("team:\(team.id)") || text.contains("team: \(team.id)") {
                return team
            }
            if text.contains(team.name.lowercased()) && text.contains("team") {
                return team
            }
        }

        return nil
    }

    /// Execute a task through the team system.
    /// Creates the team task, runs it through TeamCoordinator, and returns the result.
    func executeViaTeam(team: AgentTeam, title: String, description: String) async -> String? {
        TorboLog.info("Routing '\(title)' to team '\(team.name)'", subsystem: "TeamRouter")

        let fullDescription = "\(title)\n\n\(description)"
        let result = await TeamCoordinator.shared.executeTeamTask(teamID: team.id, taskDescription: fullDescription)

        return result?.aggregatedResult
    }

    /// Create a TaskQueue task that will be picked up and routed to a team.
    func createTeamTask(title: String, description: String, teamID: String, createdBy: String = "user",
                        priority: TaskQueue.TaskPriority = .normal) async -> TaskQueue.AgentTask? {
        guard let team = await TeamCoordinator.shared.team(teamID) else {
            TorboLog.error("Team \(teamID.prefix(8)) not found for task creation", subsystem: "TeamRouter")
            return nil
        }

        // Create task assigned to the coordinator — it will be intercepted
        let task = await TaskQueue.shared.createTask(
            title: "[Team: \(team.name)] \(title)",
            description: description,
            assignedTo: team.coordinatorAgentID,
            assignedBy: createdBy,
            priority: priority
        )

        // Track this task as team-routed
        teamAssignments[task.id] = teamID

        return task
    }

    /// Check if a claimed task should be redirected to a team.
    /// Called by ProactiveAgent before standard execution.
    func shouldRouteToTeam(taskID: String) -> String? {
        return teamAssignments[taskID]
    }

    /// Clean up after team task completes.
    func taskCompleted(taskID: String) {
        teamAssignments.removeValue(forKey: taskID)
    }
}

// MARK: - ProactiveAgent Team Extension

/// Extension methods for ProactiveAgent to check team routing.
/// These are called from the existing ProactiveAgent.executeTask flow.
extension TeamTaskRouter {

    /// Intercept a task and run it through the team system if applicable.
    /// Returns the result string if handled by a team, nil if it should proceed normally.
    func interceptForTeam(task: TaskQueue.AgentTask) async -> String? {
        // Check explicit team assignment
        if let teamID = teamAssignments[task.id] {
            guard let team = await TeamCoordinator.shared.team(teamID) else {
                taskCompleted(taskID: task.id)
                return nil
            }

            TorboLog.info("Intercepted task '\(task.title)' for team '\(team.name)'", subsystem: "TeamRouter")
            let result = await TeamCoordinator.shared.executeTeamTask(teamID: teamID, taskDescription: task.description)
            taskCompleted(taskID: task.id)
            return result?.aggregatedResult
        }

        // Check if task title/description matches a team pattern
        if let team = await teamForTask(title: task.title, description: task.description) {
            TorboLog.info("Auto-routing task '\(task.title)' to team '\(team.name)'", subsystem: "TeamRouter")
            let result = await TeamCoordinator.shared.executeTeamTask(teamID: team.id, taskDescription: task.description)
            return result?.aggregatedResult
        }

        return nil  // Not a team task — proceed with normal ProactiveAgent flow
    }
}

// MARK: - Convenience: Direct Team Execution

extension TeamCoordinator {

    /// Quick-execute: create and run a team task in one call.
    /// Returns the aggregated result string.
    func quickExecute(teamID: String, task: String) async -> String? {
        let result = await executeTeamTask(teamID: teamID, taskDescription: task)
        return result?.aggregatedResult
    }

    /// Execute with a team name (looks up the team by name).
    func executeByName(teamName: String, task: String) async -> String? {
        let teams = listTeams()
        guard let team = teams.first(where: { $0.name.lowercased() == teamName.lowercased() }) else {
            TorboLog.error("Team '\(teamName)' not found", subsystem: "Teams")
            return nil
        }
        return await quickExecute(teamID: team.id, task: task)
    }
}
