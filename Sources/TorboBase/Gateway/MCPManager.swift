// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — MCP Client Runtime
// MCPManager.swift — Spawns MCP servers, discovers tools, routes tool calls
// Model Context Protocol (stdio transport): https://modelcontextprotocol.io

import Foundation

// MARK: - MCP Tool Definition

/// A tool discovered from an MCP server
struct MCPTool {
    let serverName: String       // Which MCP server owns this tool
    let name: String             // Tool name (e.g. "read_file")
    let description: String      // Human-readable description
    let inputSchema: [String: Any]  // JSON Schema for parameters
}

// MARK: - MCP Server Connection

/// Represents a running MCP server process
actor MCPServerConnection {
    let name: String
    let config: MCPServerConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextID: Int = 1
    private var tools: [MCPTool] = []
    private var isInitialized = false
    private var responseBuffer = Data()
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
    }

    /// Start the server process and complete the MCP handshake
    func start() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.resolvedCommand)
        proc.arguments = config.args ?? []

        // Sanitized environment — only pass safe base vars + explicitly declared config vars
        // Prevents leaking OPENAI_API_KEY, AWS_SECRET_KEY, etc. to MCP servers
        let parentEnv = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        let safeKeys: Set<String> = ["PATH", "HOME", "TERM", "LANG", "USER", "SHELL", "TMPDIR", "LC_ALL", "LC_CTYPE"]
        for key in safeKeys {
            if let val = parentEnv[key] { env[key] = val }
        }
        if let extra = config.env {
            for (k, v) in extra { env[k] = v }
        }
        // Ensure npx/node/python can be found (app bundles may have minimal PATH)
        let basePath = "/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/Caskroom/miniforge/base/bin:/usr/bin:/bin"
        env["PATH"] = basePath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Log stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                TorboLog.info("\(str.trimmingCharacters(in: .whitespacesAndNewlines))", subsystem: "MCP/\(self.name)/stderr")
            }
        }

        do {
            try proc.run()
            TorboLog.info("Started '\(name)' (pid: \(proc.processIdentifier), cmd: \(config.resolvedCommand))", subsystem: "MCP")
        } catch {
            TorboLog.error("Failed to start '\(name)': \(error) (cmd: \(config.resolvedCommand), exists: \(FileManager.default.fileExists(atPath: config.resolvedCommand)))", subsystem: "MCP")
            throw error
        }

        // Start reading stdout (non-blocking via readabilityHandler)
        startReading()

        // Initialize handshake
        let initResult = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": "TorboBase",
                "version": "1.0.0"
            ] as [String: Any]
        ] as [String: Any])

        if let serverInfo = initResult["serverInfo"] as? [String: Any] {
            TorboLog.info("Server '\(name)' initialized: \(serverInfo["name"] ?? "?") v\(serverInfo["version"] ?? "?")", subsystem: "MCP")
        }

        // Send initialized notification
        sendNotification(method: "notifications/initialized")
        isInitialized = true

        // Discover tools
        try await discoverTools()
    }

    /// Discover available tools from this server
    private func discoverTools() async throws {
        let result = try await sendRequest(method: "tools/list", params: nil)
        guard let toolsArray = result["tools"] as? [[String: Any]] else {
            TorboLog.info("Server '\(name)' returned no tools", subsystem: "MCP")
            return
        }

        tools = toolsArray.compactMap { def in
            guard let toolName = def["name"] as? String else { return nil }
            let desc = def["description"] as? String ?? ""
            let schema = def["inputSchema"] as? [String: Any] ?? ["type": "object"]
            return MCPTool(serverName: name, name: toolName, description: desc, inputSchema: schema)
        }

        TorboLog.info("Server '\(name)' provides \(tools.count) tool(s): \(tools.map { $0.name }.joined(separator: ", "))", subsystem: "MCP")
    }

    /// Call a tool on this server
    func callTool(name toolName: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest(method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments
        ] as [String: Any])

        // Extract text content from MCP response
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if item["type"] as? String == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            let isError = result["isError"] as? Bool ?? false
            let resultText = texts.joined(separator: "\n")
            if isError {
                return "[MCP Error] \(resultText)"
            }
            return resultText
        }

        return "[MCP] No text content in response"
    }

    /// Get discovered tools
    func getTools() -> [MCPTool] { tools }

    /// Stop the server
    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it 3s to exit gracefully, then force-kill
            let pid = proc.processIdentifier
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if proc.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        TorboLog.info("Stopped server '\(name)'", subsystem: "MCP")
    }

    // MARK: - JSON-RPC Communication

    private func sendRequest(method: String, params: [String: Any]?, timeoutSeconds: Int = 30) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params { msg["params"] = params }

        let data = try JSONSerialization.data(withJSONObject: msg)
        guard var line = String(data: data, encoding: .utf8) else {
            throw MCPError.encodingFailed
        }
        line += "\n"

        guard let pipe = stdinPipe else { throw MCPError.notConnected }
        pipe.fileHandleForWriting.write(Data(line.utf8))

        // Wait for response with matching ID, with timeout
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation

            // Schedule a timeout that cancels the pending response
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                guard let self else { return }
                if let pending = await self.removePendingResponse(for: id) {
                    pending.resume(throwing: MCPError.timeout)
                }
            }
        }
        return result
    }

    /// Remove and return a pending response continuation (actor-isolated helper for timeout)
    private func removePendingResponse(for id: Int) -> CheckedContinuation<[String: Any], Error>? {
        pendingResponses.removeValue(forKey: id)
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params { msg["params"] = params }

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        stdinPipe?.fileHandleForWriting.write(Data(line.utf8))
    }

    /// Start reading stdout using readabilityHandler (non-blocking, runs on a background queue)
    /// This avoids blocking the actor with synchronous availableData calls
    /// Mutable buffer holder for readabilityHandler closure (Sendable-safe)
    private final class ReadBuffer: @unchecked Sendable {
        var data = Data()
    }

    private func startReading() {
        guard let pipe = stdoutPipe else { return }
        let buffer = ReadBuffer()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return } // EOF

            buffer.data.append(chunk)

            // Process complete JSON-RPC lines
            while let newlineIndex = buffer.data.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.data[buffer.data.startIndex..<newlineIndex]
                buffer.data = Data(buffer.data[buffer.data.index(after: newlineIndex)...])

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                // Dispatch response handling to the actor
                Task {
                    await self.handleMessage(json)
                }
            }
        }
    }

    /// Handle an incoming JSON-RPC message (actor-isolated)
    private func handleMessage(_ json: [String: Any]) {
        // Check if this is a response (has "id")
        if let id = json["id"] as? Int {
            if let continuation = pendingResponses.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "Unknown error"
                    let code = error["code"] as? Int ?? -1
                    continuation.resume(throwing: MCPError.serverError(code: code, message: msg))
                } else if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: [:])
                }
            }
        }
        // Notifications (no id) — handle list_changed
        else if let method = json["method"] as? String {
            if method == "notifications/tools/list_changed" {
                TorboLog.info("Server '\(name)' tools changed — re-discovering", subsystem: "MCP")
                Task { try? await discoverTools() }
            }
        }
    }
}

// MARK: - MCP Manager (Singleton)

/// Manages all MCP server connections and provides unified tool access
actor MCPManager {
    static let shared = MCPManager()

    private var servers: [String: MCPServerConnection] = [:]
    private var allTools: [MCPTool] = []

    /// Start all configured MCP servers
    func initialize() async {
        MCPConfigLoader.createTemplateIfNeeded()
        let configs = MCPConfigLoader.load()

        guard !configs.isEmpty else {
            TorboLog.info("No servers configured", subsystem: "MCP")
            return
        }

        let activeConfigs = configs.filter { !$0.key.hasPrefix("_") }
        TorboLog.info("Starting \(activeConfigs.count) server(s) (skipping \(configs.count - activeConfigs.count) disabled)...", subsystem: "MCP")

        for (name, config) in activeConfigs {
            // Validate command against allowlist
            let commandBasename = URL(fileURLWithPath: config.resolvedCommand).lastPathComponent
            let userAllowed = Set(MCPConfigLoader.loadAllowedCommands())
            let fullAllowlist = MCPDefaults.allowedCommands.union(userAllowed)
            if !fullAllowlist.contains(commandBasename) && !fullAllowlist.contains(config.command) {
                TorboLog.warn("Command '\(config.command)' (\(commandBasename)) not in allowlist — skipping '\(name)'. Add it to allowedCommands in mcp_servers.json to permit.", subsystem: "MCP")
                continue
            }

            TorboLog.info("Initializing '\(name)' (cmd: \(config.resolvedCommand))...", subsystem: "MCP")

            let conn = MCPServerConnection(name: name, config: config)
            servers[name] = conn

            do {
                try await conn.start()
                let tools = await conn.getTools()
                allTools.append(contentsOf: tools)
                TorboLog.info("'\(name)' ready with \(tools.count) tool(s)", subsystem: "MCP")
            } catch {
                TorboLog.error("'\(name)' failed: \(error)", subsystem: "MCP")
                await conn.stop()
                servers.removeValue(forKey: name)
            }
        }

        TorboLog.info("Ready: \(servers.count) server(s), \(allTools.count) total tool(s)", subsystem: "MCP")
    }

    /// Refresh — reload config and restart servers
    func refresh() async {
        await stopAll()
        allTools = []
        servers = [:]
        await initialize()
    }

    /// Stop all servers
    func stopAll() async {
        for (_, server) in servers {
            await server.stop()
        }
        servers = [:]
        allTools = []
    }

    /// Get all MCP tool names (for registration with ToolProcessor)
    func toolNames() -> Set<String> {
        Set(allTools.map { "mcp_\($0.serverName)_\($0.name)" })
    }

    /// Get tool definitions in OpenAI function-calling format
    func toolDefinitions() -> [[String: Any]] {
        allTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": "mcp_\(tool.serverName)_\(tool.name)",
                    "description": "[MCP/\(tool.serverName)] \(tool.description)",
                    "parameters": tool.inputSchema
                ] as [String: Any]
            ] as [String: Any]
        }
    }

    /// Check if a tool name belongs to an MCP server
    func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix("mcp_")
    }

    /// Execute an MCP tool call
    func executeTool(name fullName: String, arguments: [String: Any]) async -> String {
        // Parse: mcp_{serverName}_{toolName}
        let parts = fullName.dropFirst(4) // Remove "mcp_"
        guard let underscoreIndex = parts.firstIndex(of: "_") else {
            return "[MCP Error] Invalid tool name format: \(fullName)"
        }
        let serverName = String(parts[parts.startIndex..<underscoreIndex])
        let toolName = String(parts[parts.index(after: underscoreIndex)...])

        guard let server = servers[serverName] else {
            return "[MCP Error] Server '\(serverName)' not connected"
        }

        do {
            let result = try await server.callTool(name: toolName, arguments: arguments)
            TorboLog.info("\(serverName)/\(toolName) executed successfully (\(result.count) chars)", subsystem: "MCP")
            return result
        } catch {
            TorboLog.error("\(serverName)/\(toolName) failed: \(error)", subsystem: "MCP")
            return "[MCP Error] \(error.localizedDescription)"
        }
    }

    /// Get connected server count and tool count
    func status() -> (servers: Int, tools: Int) {
        (servers.count, allTools.count)
    }
}

// MARK: - MCP Errors

enum MCPError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case serverError(code: Int, message: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP server not connected"
        case .encodingFailed: return "Failed to encode JSON-RPC message"
        case .serverError(let code, let msg): return "MCP server error (\(code)): \(msg)"
        case .timeout: return "MCP request timed out"
        }
    }
}
