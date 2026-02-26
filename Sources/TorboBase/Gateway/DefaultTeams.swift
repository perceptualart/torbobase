// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Default Agent Teams
// Pre-configured teams that ship with Torbo Base.
// Installed on first launch if no teams exist.

import Foundation

// MARK: - Default Teams

enum DefaultTeams {

    /// Pre-configured team definitions.
    /// These are installed on first launch when no teams exist on disk.
    static let templates: [AgentTeam] = [
        researchTeam,
        codeReviewTeam,
        contentCreationTeam
    ]

    // MARK: - Research Team

    /// Research Team: Coordinator breaks down research questions, web-researcher gathers data,
    /// document-writer synthesizes findings into a report.
    static let researchTeam = AgentTeam(
        id: "research-team",
        name: "Research Team",
        coordinatorAgentID: "sid",
        memberAgentIDs: ["orion", "mira"],
        description: "Multi-agent research team. SiD coordinates, Orion provides strategic analysis, Mira handles web research and data gathering. Best for complex research tasks that benefit from multiple perspectives."
    )

    // MARK: - Code Review Team

    /// Code Review Team: Coordinator assigns code for review — one agent reviews logic/style,
    /// another analyzes security.
    static let codeReviewTeam = AgentTeam(
        id: "code-review-team",
        name: "Code Review Team",
        coordinatorAgentID: "sid",
        memberAgentIDs: ["orion", "ada"],
        description: "Code review team. SiD coordinates the review, Orion analyzes architecture and logic, aDa checks for patterns and consistency. Best for thorough multi-angle code reviews."
    )

    // MARK: - Content Creation Team

    /// Content Creation Team: Coordinator plans the content, writer drafts, editor polishes,
    /// fact-checker verifies claims.
    static let contentCreationTeam = AgentTeam(
        id: "content-creation-team",
        name: "Content Creation Team",
        coordinatorAgentID: "sid",
        memberAgentIDs: ["orion", "mira", "ada"],
        description: "Full content creation pipeline. SiD coordinates and plans, Orion provides strategic framing, Mira handles research and fact-checking, aDa ensures clarity and consistency. Best for articles, reports, and documentation."
    )

    // MARK: - Installation

    /// Install default teams if none exist. Called on first launch.
    static func installIfNeeded() async {
        let existing = await TeamCoordinator.shared.listTeams()
        guard existing.isEmpty else { return }

        TorboLog.info("Installing \(templates.count) default team(s)", subsystem: "Teams")
        for template in templates {
            let _ = await TeamCoordinator.shared.createTeam(template)
        }
        TorboLog.info("Default teams installed", subsystem: "Teams")
    }

    /// Reset to defaults — removes all teams and reinstalls templates.
    static func resetToDefaults() async {
        let existing = await TeamCoordinator.shared.listTeams()
        for team in existing {
            let _ = await TeamCoordinator.shared.deleteTeam(team.id)
        }
        for template in templates {
            let _ = await TeamCoordinator.shared.createTeam(template)
        }
        TorboLog.info("Teams reset to defaults", subsystem: "Teams")
    }
}
