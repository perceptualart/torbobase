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

    /// Resolved command path (expands ~ and checks PATH)
    var resolvedCommand: String {
        let expanded = NSString(string: command).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return expanded }
        return command // Let Process resolve via PATH
    }
}

/// Top-level config file structure
/// File: ~/Library/Application Support/TorboBase/mcp_servers.json
struct MCPConfigFile: Codable {
    let mcpServers: [String: MCPServerConfig]
}

// MARK: - Config Loader

enum MCPConfigLoader {
    /// Default config file path
    static var configPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TorboBase/mcp_servers.json").path
    }

    /// Load MCP server configs from disk
    static func load(from path: String? = nil) -> [String: MCPServerConfig] {
        let filePath = path ?? configPath
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[MCP] No config file at \(filePath)")
            return [:]
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let config = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            print("[MCP] Loaded \(config.mcpServers.count) server(s) from config")
            return config.mcpServers
        } catch {
            print("[MCP] Failed to parse config: \(error)")
            return [:]
        }
    }

    /// Create a template config file if none exists
    static func createTemplateIfNeeded() {
        let path = configPath
        guard !FileManager.default.fileExists(atPath: path) else { return }

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let template: [String: Any] = [
            "mcpServers": [
                "_example_filesystem": [
                    "command": "npx",
                    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"],
                    "env": [:] as [String: String]
                ] as [String: Any]
            ] as [String: Any]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: template, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("[MCP] Created template config at \(path)")
        }
    }
}
