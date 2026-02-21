// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — MCP Server Configuration
// MCPConfig.swift — Loads and manages MCP server definitions
// Model Context Protocol: https://modelcontextprotocol.io

import Foundation

// MARK: - MCP Server Configuration

/// A single MCP server entry from the config file
struct MCPServerConfig: Codable {
    let command: String
    let args: [String]?
    let env: [String: String]?
    var enabled: Bool?

    /// Resolved command path (expands ~ and checks PATH)
    var resolvedCommand: String {
        let expanded = NSString(string: command).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return expanded }
        return command // Let Process resolve via PATH
    }

    /// Whether this server is enabled (defaults to true if field absent)
    var isEnabled: Bool {
        enabled ?? true
    }
}

/// Top-level config file structure
/// File: ~/Library/Application Support/TorboBase/mcp_servers.json
struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig]
    let allowedCommands: [String]?
}

/// Default allowed commands for MCP servers. User can expand via `allowedCommands` in config.
enum MCPDefaults {
    static let allowedCommands: Set<String> = ["npx", "node", "python3", "python", "uvx", "deno", "ruby", "docker"]
}

// MARK: - Config Loader

enum MCPConfigLoader {
    /// Default config file path
    static var configPath: String {
        let appSupport = PlatformPaths.appSupportDir
        return appSupport.appendingPathComponent("TorboBase/mcp_servers.json").path
    }

    /// Load MCP server configs from disk
    static func load(from path: String? = nil) -> [String: MCPServerConfig] {
        let filePath = path ?? configPath
        guard FileManager.default.fileExists(atPath: filePath) else {
            TorboLog.info("No config file at \(filePath)", subsystem: "MCP")
            return [:]
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let config = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            TorboLog.info("Loaded \(config.mcpServers.count) server(s) from config", subsystem: "MCP")
            return config.mcpServers
        } catch {
            TorboLog.error("Failed to parse config: \(error)", subsystem: "MCP")
            return [:]
        }
    }

    /// Load user-specified allowed commands from config
    static func loadAllowedCommands() -> [String] {
        let filePath = configPath
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let config = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return []
        }
        return config.allowedCommands ?? []
    }

    /// Load the full config file (for modifications)
    static func loadConfigFile() -> MCPConfigFile? {
        let filePath = configPath
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        return try? JSONDecoder().decode(MCPConfigFile.self, from: data)
    }

    /// Save the full config file to disk
    static func save(_ configFile: MCPConfigFile) -> Bool {
        let filePath = configPath
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        do {
            let data = try JSONEncoder().encode(configFile)
            // Re-serialize with pretty printing for readability
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try pretty.write(to: URL(fileURLWithPath: filePath))
            } else {
                try data.write(to: URL(fileURLWithPath: filePath))
            }
            TorboLog.info("Saved config (\(configFile.mcpServers.count) server(s))", subsystem: "MCP")
            return true
        } catch {
            TorboLog.error("Failed to save config: \(error)", subsystem: "MCP")
            return false
        }
    }

    /// Add a server to the config file. Returns true on success.
    static func addServer(name: String, config: MCPServerConfig) -> Bool {
        var configFile = loadConfigFile() ?? MCPConfigFile(mcpServers: [:], allowedCommands: nil)
        configFile.mcpServers[name] = config
        return save(configFile)
    }

    /// Remove a server from the config file. Returns true if found and removed.
    static func removeServer(name: String) -> Bool {
        guard var configFile = loadConfigFile() else { return false }
        guard configFile.mcpServers.removeValue(forKey: name) != nil else { return false }
        return save(configFile)
    }

    /// Create a template config file if none exists
    static func createTemplateIfNeeded() {
        let path = configPath
        guard !FileManager.default.fileExists(atPath: path) else { return }

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let home = NSHomeDirectory()
        let template: [String: Any] = [
            "mcpServers": [
                "filesystem": [
                    "command": "npx",
                    "args": ["-y", "@modelcontextprotocol/server-filesystem", "\(home)/Documents"],
                    "env": [:] as [String: String],
                    "enabled": false
                ] as [String: Any],
                "fetch": [
                    "command": "npx",
                    "args": ["-y", "@modelcontextprotocol/server-fetch"],
                    "env": [:] as [String: String],
                    "enabled": false
                ] as [String: Any],
                "notion": [
                    "command": "npx",
                    "args": ["-y", "@notionhq/notion-mcp-server"],
                    "env": [
                        "OPENAPI_MCP_HEADERS": "{\"Authorization\":\"Bearer YOUR_NOTION_API_KEY\",\"Notion-Version\":\"2022-06-28\"}"
                    ] as [String: String],
                    "enabled": false
                ] as [String: Any]
            ] as [String: Any],
            "allowedCommands": [] as [String]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
            TorboLog.info("Created template config at \(path) with 3 starter integrations (filesystem, fetch, notion)", subsystem: "MCP")
        }
    }
}
