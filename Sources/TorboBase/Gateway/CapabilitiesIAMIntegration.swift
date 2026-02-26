// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Capabilities IAM Integration
// Bridges the capability system with the IAM engine. Maps tool names and file operations
// to IAM resource patterns, checks permissions before execution, and logs all access.

import Foundation

enum CapabilitiesIAM {

    // MARK: - Tool → Resource Mapping

    /// Map a tool name to an IAM resource pattern.
    /// Tool names from Capabilities.swift map to "tool:{name}" resources in IAM.
    static func resourceForTool(_ toolName: String) -> String {
        "tool:\(toolName)"
    }

    /// Map a file path to an IAM resource pattern.
    /// File paths map to "file:{path}" resources in IAM.
    static func resourceForFile(_ path: String) -> String {
        "file:\(path)"
    }

    /// Map an action to its IAM equivalent.
    /// Tools use "use", files use "read"/"write"/"execute".
    static func actionForToolUse() -> String { "use" }
    static func actionForFileRead() -> String { "read" }
    static func actionForFileWrite() -> String { "write" }
    static func actionForExecution() -> String { "execute" }

    // MARK: - Permission Checks

    /// Check if an agent can use a specific tool.
    /// Returns true if allowed, false if denied.
    /// Access is always logged regardless of result.
    static func canUseTool(agentID: String, toolName: String) async -> Bool {
        let resource = resourceForTool(toolName)
        let action = actionForToolUse()
        return await AgentIAMEngine.shared.checkAndLog(
            agentID: agentID, resource: resource, action: action
        )
    }

    /// Check if an agent can read a specific file.
    static func canReadFile(agentID: String, path: String) async -> Bool {
        let resource = resourceForFile(path)
        return await AgentIAMEngine.shared.checkAndLog(
            agentID: agentID, resource: resource, action: actionForFileRead()
        )
    }

    /// Check if an agent can write to a specific file.
    static func canWriteFile(agentID: String, path: String) async -> Bool {
        let resource = resourceForFile(path)
        return await AgentIAMEngine.shared.checkAndLog(
            agentID: agentID, resource: resource, action: actionForFileWrite()
        )
    }

    /// Check if an agent can execute code.
    static func canExecuteCode(agentID: String) async -> Bool {
        return await AgentIAMEngine.shared.checkAndLog(
            agentID: agentID, resource: "tool:execute_code", action: actionForExecution()
        )
    }

    /// Check if an agent can run a shell command.
    static func canRunCommand(agentID: String) async -> Bool {
        return await AgentIAMEngine.shared.checkAndLog(
            agentID: agentID, resource: "tool:run_command", action: actionForExecution()
        )
    }

    // MARK: - Bulk Tool Check

    /// Check which tools from a list an agent is permitted to use.
    /// Returns the filtered list of allowed tool names.
    static func filterAllowedTools(agentID: String, tools: [String]) async -> [String] {
        var allowed: [String] = []
        for tool in tools {
            let resource = resourceForTool(tool)
            let permitted = await AgentIAMEngine.shared.checkPermission(
                agentID: agentID, resource: resource, action: actionForToolUse()
            )
            if permitted { allowed.append(tool) }
        }
        return allowed
    }

    // MARK: - Pre-Execution Wrapper

    /// Wrapper for tool execution that checks IAM before proceeding.
    /// Use this in the gateway tool execution path to enforce IAM.
    ///
    /// Example integration in Capabilities.swift:
    /// ```
    /// let allowed = await CapabilitiesIAM.checkBeforeToolExecution(
    ///     agentID: agentID, toolName: "web_search"
    /// )
    /// if !allowed.permitted {
    ///     return ["error": allowed.reason ?? "Permission denied by IAM"]
    /// }
    /// // ... proceed with tool execution
    /// ```
    struct CheckResult {
        let permitted: Bool
        let reason: String?
    }

    static func checkBeforeToolExecution(agentID: String, toolName: String) async -> CheckResult {
        // Ensure agent is registered in IAM
        await AgentIAMEngine.shared.registerAgent(id: agentID)

        let resource = resourceForTool(toolName)
        let action = actionForToolUse()
        let allowed = await AgentIAMEngine.shared.checkPermission(
            agentID: agentID, resource: resource, action: action
        )

        let reason = allowed ? nil : "Agent '\(agentID)' lacks permission for \(action) on '\(resource)'"

        await AgentIAMEngine.shared.logAccess(
            agentID: agentID, resource: resource, action: action,
            allowed: allowed, reason: reason
        )

        return CheckResult(permitted: allowed, reason: reason)
    }

    /// Pre-execution check for file operations.
    static func checkBeforeFileOperation(agentID: String, path: String, write: Bool) async -> CheckResult {
        await AgentIAMEngine.shared.registerAgent(id: agentID)

        let resource = resourceForFile(path)
        let action = write ? actionForFileWrite() : actionForFileRead()
        let allowed = await AgentIAMEngine.shared.checkPermission(
            agentID: agentID, resource: resource, action: action
        )

        let reason = allowed ? nil : "Agent '\(agentID)' lacks permission for \(action) on '\(resource)'"

        await AgentIAMEngine.shared.logAccess(
            agentID: agentID, resource: resource, action: action,
            allowed: allowed, reason: reason
        )

        return CheckResult(permitted: allowed, reason: reason)
    }

    // MARK: - Access Level Sync

    /// Sync an agent's access level from AgentConfig to IAM permissions.
    /// Called when an agent's access level changes.
    static func syncAccessLevel(agentID: String, accessLevel: Int) async {
        // Revoke existing permissions
        await AgentIAMEngine.shared.revokeAllPermissions(agentID: agentID)

        // Grant new permissions based on access level
        let permissions = AgentIAMEngine.permissionsForAccessLevel(accessLevel)
        for (resource, actions) in permissions {
            await AgentIAMEngine.shared.grantPermission(
                agentID: agentID, resource: resource, actions: actions, grantedBy: "access_level_sync"
            )
        }

        // Recalculate risk score
        _ = await AgentIAMEngine.shared.calculateRiskScore(agentID: agentID)

        TorboLog.info("Synced IAM permissions for '\(agentID)' to access level \(accessLevel)", subsystem: "IAM")
    }

    // MARK: - Category Mapping

    /// Map a CapabilityCategory to a set of tool names for bulk IAM operations.
    static func toolsForCategory(_ category: CapabilityCategory) -> [String] {
        CapabilityRegistry.all
            .filter { $0.category == category }
            .map { $0.toolName }
    }

    /// Grant all tools in a category to an agent.
    static func grantCategory(agentID: String, category: CapabilityCategory, grantedBy: String = "system") async {
        let tools = toolsForCategory(category)
        for tool in tools {
            await AgentIAMEngine.shared.grantPermission(
                agentID: agentID, resource: resourceForTool(tool), actions: ["use"], grantedBy: grantedBy
            )
        }
    }

    /// Revoke all tools in a category from an agent.
    static func revokeCategory(agentID: String, category: CapabilityCategory) async {
        let tools = toolsForCategory(category)
        for tool in tools {
            await AgentIAMEngine.shared.revokePermission(agentID: agentID, resource: resourceForTool(tool))
        }
    }
}
