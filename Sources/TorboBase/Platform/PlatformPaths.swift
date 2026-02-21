// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Platform Paths
// Cross-platform path resolution for macOS and Linux.
// macOS: ~/Library/Application Support/TorboBase/
// Linux: ~/.config/torbobase/ (XDG Base Directory Specification)

import Foundation

/// Cross-platform data directory resolution.
/// Centralizes all path computation so every module uses consistent locations.
enum PlatformPaths {

    // MARK: - Base Directories

    /// The macOS Application Support URL. Safe fallback to home directory if the system
    /// call somehow returns empty (never happens in practice, but we don't crash).
    static var appSupportDir: URL {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        // Fallback — should never execute on macOS/iOS
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/Library/Application Support")
    }

    /// Primary data directory for Torbo Base.
    /// - macOS: `~/Library/Application Support/TorboBase/`
    /// - Linux: `~/.config/torbobase/`
    static var dataDir: String {
        #if os(macOS)
        return appSupportDir.appendingPathComponent("TorboBase", isDirectory: true).path
        #else
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (home + "/.config")
        return xdgConfig + "/torbobase"
        #endif
    }

    /// Configuration directory (same as dataDir on Linux, separate on macOS for keychain).
    static var configDir: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.config/torbobase"
    }

    // MARK: - Subdirectories

    /// Agent configurations directory.
    static var agentsDir: String { dataDir + "/agents" }

    /// Skills directory.
    static var skillsDir: String { dataDir + "/skills" }

    /// Memory database directory.
    static var memoryDir: String { dataDir + "/memory" }

    /// Documents (RAG) directory.
    static var documentsDir: String { dataDir + "/documents" }

    /// Evening briefings storage directory.
    static var briefingsDir: String { dataDir + "/briefings" }

    // MARK: - Files

    /// Task queue persistence file.
    static var tasksFile: String { dataDir + "/task_queue.json" }

    /// Workflow persistence file.
    static var workflowsFile: String { dataDir + "/workflows.json" }

    /// Scheduled events persistence file.
    static var schedulesFile: String { dataDir + "/schedules.json" }

    /// Cron scheduled tasks persistence file.
    static var cronTasksFile: String { dataDir + "/scheduled_tasks.json" }

    /// Webhook definitions file.
    static var webhooksFile: String { dataDir + "/webhooks.json" }

    /// Encrypted keychain file.
    static var keychainFile: String { configDir + "/keychain.enc" }

    /// MCP server configurations.
    static var mcpConfigFile: String { dataDir + "/mcp_servers.json" }

    // MARK: - Initialization

    /// Ensure all required directories exist.
    static func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [dataDir, configDir, agentsDir, skillsDir, memoryDir, documentsDir, briefingsDir]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // Secure the config directory (600 = owner rw only)
        chmod(configDir, 0o700)
    }

    // MARK: - Utility

    /// Expand ~ in a path to the home directory.
    static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~") {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            return home + path.dropFirst()
        }
        return path
    }

}
