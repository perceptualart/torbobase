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
    private var readTask: Task<Void, Never>?

    init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
    }

    /// Start the server process and complete the MCP handshake
    func start() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.resolvedCommand)
        proc.arguments = config.args ?? []

        // Merge environment
        var env = ProcessInfo.processInfo.environment
        if let extra = config.env {
            for (k, v) in extra { env[k] = v }
        }
        // Ensure npx/node can be found
        if env["PATH"] != nil {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        }
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
                print("[MCP/\(self.name)/stderr] \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try proc.run()
            print("[MCP] Started server '\(name)' (pid: \(proc.processIdentifier))")
        } catch {
            print("[MCP] Failed to start '\(name)': \(error)")
            throw error
        }

        // Start reading stdout in background
        readTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop()
        }

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
            print("[MCP] Server '\(name)' initialized: \(serverInfo["name"] ?? "?") v\(serverInfo["version"] ?? "?")")
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
            print("[MCP] Server '\(name)' returned no tools")
            return
        }

        tools = toolsArray.compactMap { def in
            guard let toolName = def["name"] as? String else { return nil }
            let desc = def["description"] as? String ?? ""
            let schema = def["inputSchema"] as? [String: Any] ?? ["type": "object"]
            return MCPTool(serverName: name, name: toolName, description: desc, inputSchema: schema)
        }

        print("[MCP] Server '\(name)' provides \(tools.count) tool(s): \(tools.map { $0.name }.joined(separator: ", "))")
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
        readTask?.cancel()
        stdinPipe?.fileHandleForWriting.closeFile()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it 3s to exit
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        print("[MCP] Stopped server '\(name)'")
    }

    // MARK: - JSON-RPC Communication

    private func sendRequest(method: String, params: [String: Any]?) async throws -> [String: Any] {
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

        // Wait for response with matching ID
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
        }
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

    /// Read stdout line by line and dispatch responses
    private func readLoop() async {
        guard let pipe = stdoutPipe else { return }
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — process exited
                try? await Task.sleep(nanoseconds: 100_000_000)
                if process?.isRunning != true { break }
                continue
            }

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

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
                        print("[MCP] Server '\(name)' tools changed — re-discovering")
                        Task { try? await discoverTools() }
                    }
                }
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
            print("[MCP] No servers configured")
            return
        }

        for (name, config) in configs {
            // Skip template entries
            if name.hasPrefix("_") { continue }

            let conn = MCPServerConnection(name: name, config: config)
            servers[name] = conn

            do {
                try await conn.start()
                let tools = await conn.getTools()
                allTools.append(contentsOf: tools)
            } catch {
                print("[MCP] Failed to initialize server '\(name)': \(error)")
                await conn.stop()
                servers.removeValue(forKey: name)
            }
        }

        print("[MCP] Ready: \(servers.count) server(s), \(allTools.count) total tool(s)")
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
            print("[MCP] \(serverName)/\(toolName) executed successfully (\(result.count) chars)")
            return result
        } catch {
            print("[MCP] \(serverName)/\(toolName) failed: \(error)")
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
