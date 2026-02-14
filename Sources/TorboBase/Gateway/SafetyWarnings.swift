// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Safety Warnings
// Evaluates actions for potential risks and returns warnings to inform the user.
// NEVER blocks — always warns. User has the final say.
// Design: Freedom + Informed Consent. Guardrails, not lockouts.

import Foundation

/// Severity levels for safety warnings.
enum SafetyWarningLevel: String, Codable {
    case info     // FYI — something worth knowing
    case caution  // Moderate risk — proceed with awareness
    case danger   // High risk — user should think twice
}

/// A safety warning to be surfaced to the user before or during an action.
struct SafetyWarning: Codable {
    let level: SafetyWarningLevel
    let title: String
    let description: String
    let action: String  // What triggered the warning

    /// Formatted string for injection into tool results / LLM context
    var formatted: String {
        let emoji: String
        switch level {
        case .info:    emoji = "ℹ️"
        case .caution: emoji = "⚠️"
        case .danger:  emoji = "🚨"
        }
        return "[\(emoji) \(level.rawValue.uppercased()): \(title)] \(description)"
    }
}

/// Evaluates actions for potential safety risks.
/// Returns nil if no warning is needed — the action is safe.
/// Returns a SafetyWarning if the user should be informed before proceeding.
enum SafetyWarnings {

    // MARK: - MCP Server Commands

    /// Check if an MCP server command is safe to execute.
    static func checkMCPCommand(_ command: String) -> SafetyWarning? {
        let basename = URL(fileURLWithPath: command).lastPathComponent

        // Known dangerous commands
        let dangerous: Set<String> = ["bash", "sh", "zsh", "rm", "sudo", "su", "chmod", "chown", "dd", "mkfs"]
        if dangerous.contains(basename) {
            return SafetyWarning(
                level: .danger,
                title: "Dangerous MCP Command",
                description: "MCP server wants to run '\(basename)' — this command has full system access. Only allow if you trust the MCP server configuration.",
                action: "mcp_spawn:\(command)"
            )
        }

        // Not in default allowlist
        if !MCPDefaults.allowedCommands.contains(basename) {
            return SafetyWarning(
                level: .caution,
                title: "Non-Standard MCP Command",
                description: "MCP server wants to run '\(basename)' which is not in the default allowlist. Add it to allowedCommands in mcp_servers.json if you trust it.",
                action: "mcp_spawn:\(command)"
            )
        }

        return nil
    }

    // MARK: - File Operations

    /// Check if a file operation is safe.
    static func checkFileOperation(path: String, operation: String, scopes: [String]) -> SafetyWarning? {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardized.path

        // Deleting outside of temp directories
        if operation == "delete" || operation == "remove" {
            let safeDirs = ["/tmp", "/var/tmp", NSTemporaryDirectory()]
            let isTempFile = safeDirs.contains { resolved.hasPrefix($0) }
            let isBackupDir = resolved.contains(".torbo-backup")

            if !isTempFile && !isBackupDir {
                return SafetyWarning(
                    level: .caution,
                    title: "File Deletion",
                    description: "Deleting '\(URL(fileURLWithPath: resolved).lastPathComponent)' — this cannot be undone. Path: \(resolved)",
                    action: "file_delete:\(resolved)"
                )
            }
        }

        // Writing outside home directory
        let homeDir = NSHomeDirectory()
        if (operation == "write" || operation == "create") && !resolved.hasPrefix(homeDir) {
            return SafetyWarning(
                level: .danger,
                title: "Write Outside Home",
                description: "Writing to '\(resolved)' which is outside your home directory. This could affect system files.",
                action: "file_write:\(resolved)"
            )
        }

        // Writing to dotfiles or config
        if operation == "write" {
            let sensitivePatterns = [".ssh/", ".gnupg/", ".aws/", ".config/", ".env", "credentials", "token"]
            for pattern in sensitivePatterns {
                if resolved.contains(pattern) {
                    return SafetyWarning(
                        level: .caution,
                        title: "Sensitive File Modification",
                        description: "Modifying '\(URL(fileURLWithPath: resolved).lastPathComponent)' which may contain credentials or sensitive configuration.",
                        action: "file_write:\(resolved)"
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Code Execution

    /// Check if code to be executed contains potentially dangerous operations.
    static func checkCodeExecution(language: String, code: String) -> SafetyWarning? {
        let lower = code.lowercased()

        // Destructive shell commands
        let destructive = ["rm -rf", "rm -r /", "mkfs", "dd if=", "> /dev/sd", "format c:"]
        for pattern in destructive {
            if lower.contains(pattern) {
                return SafetyWarning(
                    level: .danger,
                    title: "Destructive Code",
                    description: "Code contains '\(pattern)' which could destroy data. Review carefully before running.",
                    action: "code_exec:\(language)"
                )
            }
        }

        // Piped downloads (curl | sh pattern)
        let pipedDownload = ["curl.*|.*sh", "wget.*|.*sh", "curl.*|.*bash", "curl.*|.*python"]
        for pattern in pipedDownload {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return SafetyWarning(
                    level: .danger,
                    title: "Piped Download Execution",
                    description: "Code downloads and executes remote content. This is a common attack vector.",
                    action: "code_exec:\(language)"
                )
            }
        }

        // Network access
        let networkPatterns = ["urllib", "requests.get", "requests.post", "http.client", "socket.connect",
                               "fetch(", "XMLHttpRequest", "net.createConnection", "axios"]
        for pattern in networkPatterns {
            if lower.contains(pattern.lowercased()) {
                return SafetyWarning(
                    level: .info,
                    title: "Network Access",
                    description: "Code makes network requests. Data may be sent to external servers.",
                    action: "code_exec:\(language)"
                )
            }
        }

        // File system access outside sandbox
        let fsAccess = ["open('/", "open(\"/", "os.remove", "shutil.rmtree", "fs.unlink", "fs.rmdir"]
        for pattern in fsAccess {
            if code.contains(pattern) {
                return SafetyWarning(
                    level: .caution,
                    title: "File System Access",
                    description: "Code accesses the file system. Ensure it only touches intended files.",
                    action: "code_exec:\(language)"
                )
            }
        }

        return nil
    }

    // MARK: - Webhook Targets

    /// Check if a webhook target URL is safe.
    static func checkWebhookTarget(url: String) -> SafetyWarning? {
        guard let parsed = URL(string: url) else {
            return SafetyWarning(
                level: .caution,
                title: "Invalid Webhook URL",
                description: "'\(url)' is not a valid URL.",
                action: "webhook_target:\(url)"
            )
        }

        // Non-HTTPS
        if parsed.scheme == "http" {
            return SafetyWarning(
                level: .caution,
                title: "Unencrypted Webhook",
                description: "Webhook target uses HTTP (not HTTPS). Data will be sent unencrypted.",
                action: "webhook_target:\(url)"
            )
        }

        // IP address instead of domain
        let host = parsed.host ?? ""
        let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        if host.range(of: ipPattern, options: .regularExpression) != nil && host != "127.0.0.1" {
            return SafetyWarning(
                level: .caution,
                title: "IP-Based Webhook",
                description: "Webhook targets an IP address (\(host)) instead of a domain name. Ensure you trust this destination.",
                action: "webhook_target:\(url)"
            )
        }

        return nil
    }

    // MARK: - Access Level Changes

    /// Check if an access level change is safe.
    static func checkAccessLevelChange(from current: Int, to new: Int) -> SafetyWarning? {
        // Escalating to high levels
        if new > current && new >= 4 {
            return SafetyWarning(
                level: .danger,
                title: "Access Level Escalation",
                description: "Escalating to level \(new) grants full system access including file operations, code execution, and MCP tools. Only do this if you understand the implications.",
                action: "access_level:\(current)->\(new)"
            )
        }

        if new > current && new == 3 {
            return SafetyWarning(
                level: .caution,
                title: "Access Level Increase",
                description: "Level 3 enables file operations and code execution. The agent can read/write files within configured scopes.",
                action: "access_level:\(current)->\(new)"
            )
        }

        return nil
    }

    // MARK: - Bridge Configuration

    /// Check if enabling a messaging bridge is safe.
    static func checkBridgeConfig(platform: String) -> SafetyWarning? {
        return SafetyWarning(
            level: .info,
            title: "Bridge Activation",
            description: "Enabling the \(platform) bridge. API tokens will be stored locally. Messages will be processed through the gateway.",
            action: "bridge_enable:\(platform)"
        )
    }
}
