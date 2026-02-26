// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent IAM Migration
// Scans existing agents from AgentConfigManager and registers them in the IAM engine
// with default permissions based on their current access level.
// Runs automatically on first boot (checked via migration flag file).

import Foundation

enum AgentIAMMigration {

    /// Migration flag file path — prevents re-running migration on subsequent boots
    private static var migrationFlagPath: String {
        PlatformPaths.dataDir + "/iam_migration_complete"
    }

    /// Check if migration has already been performed
    static var isMigrated: Bool {
        FileManager.default.fileExists(atPath: migrationFlagPath)
    }

    /// Run the full IAM migration. Safe to call multiple times — skips if already done.
    ///
    /// Performs:
    /// 1. Scans all agents from AgentConfigManager
    /// 2. Registers each in IAM with owner and purpose from their config
    /// 3. Maps their accessLevel to fine-grained IAM permissions
    /// 4. Handles directory scopes (per-agent file access restrictions)
    /// 5. Maps enabled capabilities to tool permissions
    /// 6. Calculates initial risk scores
    /// 7. Sets migration flag to prevent re-running
    static func migrateIfNeeded() async {
        guard !isMigrated else {
            TorboLog.debug("IAM migration already complete — skipping", subsystem: "IAM·Migration")
            return
        }

        TorboLog.info("Starting IAM migration for existing agents...", subsystem: "IAM·Migration")

        let configs = await AgentConfigManager.shared.listAgents()
        var migrated = 0

        for config in configs {
            await migrateAgent(config)
            migrated += 1
        }

        // Set migration flag
        FileManager.default.createFile(atPath: migrationFlagPath, contents: Data("migrated".utf8))

        TorboLog.info("IAM migration complete: \(migrated) agent(s) registered", subsystem: "IAM·Migration")
    }

    /// Migrate a single agent from AgentConfig to IAM
    private static func migrateAgent(_ config: AgentConfig) async {
        let iam = AgentIAMEngine.shared

        // 1. Register the agent
        await iam.registerAgent(
            id: config.id,
            owner: "local",
            purpose: config.role
        )

        // 2. Map access level to base permissions
        let basePermissions = AgentIAMEngine.permissionsForAccessLevel(config.accessLevel)
        for (resource, actions) in basePermissions {
            await iam.grantPermission(
                agentID: config.id, resource: resource, actions: actions, grantedBy: "migration"
            )
        }

        // 3. Handle directory scopes — restrict file access to specific paths
        if !config.directoryScopes.isEmpty {
            // Revoke the broad "file:*" permission if it was granted
            await iam.revokePermission(agentID: config.id, resource: "file:*")

            // Grant scoped file permissions
            for scope in config.directoryScopes {
                let resource = "file:\(scope)/*"
                var actions: Set<String> = ["read"]
                if config.accessLevel >= 3 { actions.insert("write") }
                await iam.grantPermission(
                    agentID: config.id, resource: resource, actions: actions, grantedBy: "migration_scope"
                )
            }
        }

        // 4. Handle capability toggles — revoke tools in disabled categories
        for (categoryRaw, enabled) in config.enabledCapabilities {
            if !enabled, let category = CapabilityCategory(rawValue: categoryRaw) {
                let tools = CapabilityRegistry.all.filter { $0.category == category }
                for tool in tools {
                    await iam.revokePermission(agentID: config.id, resource: "tool:\(tool.toolName)")
                }
            }
        }

        // 5. Handle skill restrictions — if enabledSkillIDs is non-empty, only those skills are allowed
        if !config.enabledSkillIDs.isEmpty {
            // This is informational — skills run through the LLM, not direct tool calls.
            // The IAM system tracks tool-level permissions; skill filtering remains in SkillsManager.
            TorboLog.debug("Agent '\(config.id)' has \(config.enabledSkillIDs.count) enabled skills", subsystem: "IAM·Migration")
        }

        // 6. Calculate initial risk score
        _ = await iam.calculateRiskScore(agentID: config.id)

        TorboLog.info("Migrated agent '\(config.id)' (level \(config.accessLevel), \(basePermissions.count) base perms)", subsystem: "IAM·Migration")
    }

    /// Force re-run migration (e.g. after agent config changes).
    /// Removes the migration flag and runs again.
    static func forceMigrate() async {
        try? FileManager.default.removeItem(atPath: migrationFlagPath)
        await migrateIfNeeded()
    }

    /// Sync a single agent's permissions when their access level changes.
    /// Called from AgentConfigManager when an agent is updated.
    static func syncAgent(_ config: AgentConfig) async {
        await CapabilitiesIAM.syncAccessLevel(
            agentID: config.id,
            accessLevel: config.accessLevel
        )

        // Re-apply directory scopes if any
        if !config.directoryScopes.isEmpty {
            await AgentIAMEngine.shared.revokePermission(agentID: config.id, resource: "file:*")
            for scope in config.directoryScopes {
                let resource = "file:\(scope)/*"
                var actions: Set<String> = ["read"]
                if config.accessLevel >= 3 { actions.insert("write") }
                await AgentIAMEngine.shared.grantPermission(
                    agentID: config.id, resource: resource, actions: actions, grantedBy: "scope_sync"
                )
            }
        }

        // Re-apply capability toggles
        for (categoryRaw, enabled) in config.enabledCapabilities {
            if !enabled, let category = CapabilityCategory(rawValue: categoryRaw) {
                let tools = CapabilityRegistry.all.filter { $0.category == category }
                for tool in tools {
                    await AgentIAMEngine.shared.revokePermission(agentID: config.id, resource: "tool:\(tool.toolName)")
                }
            }
        }
    }
}
