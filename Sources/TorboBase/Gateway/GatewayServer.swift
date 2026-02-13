// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
import Foundation
#if canImport(Network)
import Network
#endif

// MARK: - Response Writer Protocol

/// Protocol for writing HTTP responses — implemented by NWConnection (macOS) and NIO Channel (Linux)
protocol ResponseWriter: Sendable {
    func sendResponse(_ response: HTTPResponse)
    func sendStreamHeaders()
    func sendSSEChunk(_ data: String)
    func sendSSEDone()
}

#if canImport(Network)
struct NWConnectionWriter: ResponseWriter {
    let connection: NWConnection

    func sendResponse(_ response: HTTPResponse) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    func sendStreamHeaders() {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
    }

    func sendSSEChunk(_ data: String) {
        let chunk = "data: \(data)\n\n"
        connection.send(content: Data(chunk.utf8), completion: .contentProcessed { _ in })
    }

    func sendSSEDone() {
        let done = "data: [DONE]\n\n"
        connection.send(content: Data(done.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif

// MARK: - Gateway Server

actor GatewayServer {
    static let shared = GatewayServer()

    #if canImport(Network)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    #endif
    private weak var appState: AppState?
    private let ollamaURL = "http://127.0.0.1:11434"
    private var requestLog: [String: [Date]] = [:]

    #if canImport(Network)
    func start(appState: AppState) async {
        self.appState = appState
        let port = appState.serverPort

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                Task { await self?.handleConnection(conn) }
            }
            listener?.start(queue: .global(qos: .userInitiated))

            await MainActor.run {
                appState.serverRunning = true
                appState.serverError = nil
            }

            await MainActor.run {
                PairingManager.shared.startAdvertising(port: port)
            }

            // Start Memory Router
            Task {
                await MemoryRouter.shared.initialize()
            }

            // Start MCP servers
            Task {
                await MCPManager.shared.initialize()
            }

            // Start Document Store (RAG)
            Task {
                await DocumentStore.shared.initialize()
            }

            // Start Workflow Engine
            Task {
                await WorkflowEngine.shared.loadFromDisk()
            }

            // Start Webhook Manager & Scheduler
            Task {
                await WebhookManager.shared.initialize()
            }

            // Start Calendar Manager (requests access on first use)
            // CalendarManager.shared is lazy — initialized when first called

            // Start all messaging channels (Telegram, Discord, Slack, Signal, WhatsApp)
            Task {
                await TelegramBridge.shared.startPolling()
                await ChannelManager.shared.initialize()
            }

            // Notify via Telegram
            Task {
                await TelegramBridge.shared.notify("Gateway started on port \(port)")
            }

            print("[Gateway] Started on port \(port)")
        } catch {
            await MainActor.run {
                appState.serverRunning = false
                appState.serverError = error.localizedDescription
            }
            print("[Gateway] Failed to start: \(error)")
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        let s = appState
        await MainActor.run {
            s?.serverRunning = false
            s?.connectedClients = 0
            s?.activeClientIPs.removeAll()
            PairingManager.shared.stopAdvertising()
        }
        Task { await TelegramBridge.shared.notify("Gateway stopped") }
        print("[Gateway] Stopped")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) async {
        if case .failed(let err) = state {
            print("[Gateway] Listener failed: \(err)")
            let s = appState
            await MainActor.run { s?.serverRunning = false }
        }
    }

    private func handleConnection(_ conn: NWConnection) async {
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { Task { await self?.removeConnection(conn) } }
            else if case .failed = state { Task { await self?.removeConnection(conn) } }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveData(on: conn)
    }

    private func removeConnection(_ conn: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private nonisolated func receiveData(on conn: NWConnection) {
        receiveFullRequest(on: conn, accumulated: Data())
    }

    /// Accumulate TCP segments until we have the full HTTP request body
    private nonisolated func receiveFullRequest(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4_194_304) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                if !accumulated.isEmpty {
                    Task { await self.processRequest(accumulated, on: conn) }
                } else if isComplete || error != nil {
                    conn.cancel()
                }
                return
            }
            var buffer = accumulated
            buffer.append(data)

            // Check if we have the complete HTTP request
            if Self.isRequestComplete(buffer) {
                Task { await self.processRequest(buffer, on: conn) }
            } else if isComplete {
                // Connection closed — process whatever we have
                Task { await self.processRequest(buffer, on: conn) }
            } else {
                // Need more data — keep reading
                self.receiveFullRequest(on: conn, accumulated: buffer)
            }
        }
    }
    #else
    // Linux: Use SwiftNIO TCP server
    #if canImport(NIOCore)
    private var nioServer: NIOServer?
    #endif

    func start(appState: AppState) async {
        self.appState = appState
        let port = appState.serverPort

        #if canImport(NIOCore)
        do {
            let server = NIOServer()
            try await server.start(port: port)
            nioServer = server

            await MainActor.run {
                appState.serverRunning = true
                appState.serverError = nil
            }
            print("[Gateway] Started on port \(port) (SwiftNIO)")
        } catch {
            await MainActor.run {
                appState.serverRunning = false
                appState.serverError = error.localizedDescription
            }
            print("[Gateway] Failed to start NIO server: \(error)")
        }
        #else
        print("[Gateway] ⚠️ No TCP server available — need Network.framework or SwiftNIO")
        await MainActor.run {
            appState.serverRunning = false
            appState.serverError = "No TCP server available on this platform"
        }
        #endif

        // Start subsystems
        Task { await MemoryRouter.shared.initialize() }
        Task { await MCPManager.shared.initialize() }
        Task { await DocumentStore.shared.initialize() }
        Task { await WorkflowEngine.shared.loadFromDisk() }
        Task { await WebhookManager.shared.initialize() }
        Task { await TelegramBridge.shared.startPolling() }
        Task { await ChannelManager.shared.initialize() }

        await MainActor.run {
            PairingManager.shared.startAdvertising(port: port)
        }
    }

    func stop() async {
        #if canImport(NIOCore)
        await nioServer?.stop()
        nioServer = nil
        #endif
        let s = appState
        await MainActor.run {
            s?.serverRunning = false
            s?.connectedClients = 0
            PairingManager.shared.stopAdvertising()
        }
        Task { await TelegramBridge.shared.notify("Gateway stopped") }
        print("[Gateway] Stopped")
    }
    #endif

    /// Check if we've received the full HTTP request (headers + body based on Content-Length)
    /// Public alias for NIOServer access
    nonisolated static func isHTTPRequestComplete(_ data: Data) -> Bool {
        isRequestComplete(data)
    }

    private nonisolated static func isRequestComplete(_ data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return true }
        // Find the header/body separator
        guard let separatorRange = string.range(of: "\r\n\r\n") else { return false }
        let headerPart = String(string[..<separatorRange.lowerBound])
        let bodyStart = string[separatorRange.upperBound...]

        // For GET/OPTIONS/DELETE without body, we're done once we have headers
        let firstLine = headerPart.components(separatedBy: "\r\n").first ?? ""
        let method = firstLine.components(separatedBy: " ").first ?? ""
        if method == "GET" || method == "OPTIONS" || method == "DELETE" || method == "HEAD" {
            return true
        }

        // For POST/PUT, check Content-Length
        let headerLines = headerPart.lowercased().components(separatedBy: "\r\n")
        for line in headerLines {
            if line.hasPrefix("content-length:") {
                let valStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                if let expected = Int(valStr) {
                    return bodyStart.utf8.count >= expected
                }
            }
        }
        // No Content-Length header — assume complete
        return true
    }

    // MARK: - Request Processing

    #if canImport(Network)
    private func processRequest(_ data: Data, on conn: NWConnection) async {
        let writer = NWConnectionWriter(connection: conn)
        let clientIP = conn.endpoint.debugDescription
        await processRequest(data, clientIP: clientIP, writer: writer)
    }
    #endif

    private func processRequest(_ data: Data, clientIP: String, writer: ResponseWriter) async {
        guard let request = HTTPRequest.parse(data) else {
            writer.sendResponse(HTTPResponse.badRequest("Malformed request"))
            return
        }
        if let response = await route(request, clientIP: clientIP, writer: writer) {
            writer.sendResponse(response)
        }
        // If nil, response was already streamed directly via writer
    }

    /// Called by NIOServer (Linux) or NWListener handler (macOS) to process a request
    func handleRequest(_ data: Data, clientIP: String, writer: ResponseWriter) async {
        await processRequest(data, clientIP: clientIP, writer: writer)
    }

    private func route(_ req: HTTPRequest, clientIP: String, writer: ResponseWriter? = nil) async -> HTTPResponse? {
        // CORS preflight
        if req.method == "OPTIONS" { return HTTPResponse.cors() }

        // Health check
        if req.method == "GET" && (req.path == "/" || req.path == "/health") {
            return HTTPResponse.json([
                "status": "ok",
                "service": "torbo-base",
                "version": TorboVersion.current
            ])
        }

        // Web chat UI — serves the built-in chat interface
        if req.method == "GET" && req.path == "/chat" {
            return HTTPResponse(statusCode: 200,
                              headers: ["Content-Type": "text/html; charset=utf-8"],
                              body: Data(WebChatHTML.page.utf8))
        }

        // Access level — no auth
        if req.method == "GET" && req.path == "/level" {
            let s = appState
            let level = await MainActor.run { s?.accessLevel.rawValue ?? 0 }
            return HTTPResponse.json(["level": level])
        }

        // Pairing endpoints (no auth)
        if req.method == "POST" && req.path == "/pair" {
            return await handlePair(req, clientIP: clientIP)
        }
        if req.method == "POST" && req.path == "/pair/verify" {
            return await handlePairVerify(req)
        }

        // --- Everything below requires auth ---

        guard authenticate(req) else {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: .chatOnly, granted: false, detail: "Auth failed")
            return HTTPResponse.unauthorized()
        }

        if isRateLimited(clientIP: clientIP) {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: .chatOnly, granted: false, detail: "Rate limited")
            return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Rate limited\"}".utf8))
        }

        let stateRef = appState
        await MainActor.run {
            stateRef?.activeClientIPs.insert(clientIP)
            stateRef?.connectedClients = stateRef?.activeClientIPs.count ?? 0
        }

        let crewID = req.headers["x-torbo-agent-id"] ?? req.headers["X-Torbo-Agent-Id"] ?? "unknown"
        // iOS sends per-agent access level; cap it by global level for safety
        let clientLevel: AccessLevel? = {
            let raw = req.headers["x-torbo-access-level"] ?? req.headers["X-Torbo-Access-Level"]
            guard let str = raw, let val = Int(str) else { return nil }
            return AccessLevel(rawValue: val)
        }()
        let currentLevel: AccessLevel = await MainActor.run {
            guard let state = stateRef else { return .off }
            if state.accessLevel == .off { return .off }
            if let requested = clientLevel {
                // Client-requested level, capped by global
                return AccessLevel(rawValue: min(requested.rawValue, state.accessLevel.rawValue)) ?? .chatOnly
            }
            // Fallback to server-side per-crew defaults
            return state.accessLevel(for: crewID)
        }

        if currentLevel == .off {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: .chatOnly, granted: false, detail: "Gateway OFF")
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Gateway is OFF\"}".utf8))
        }

        switch (req.method, req.path) {

        // --- Level 1: Chat ---
        case ("POST", "/v1/chat/completions"):
            // Check if client wants streaming
            if let body = req.jsonBody, body["stream"] as? Bool == true, let writer {
                // Access check first
                if currentLevel.rawValue < AccessLevel.chatOnly.rawValue {
                    await audit(clientIP: clientIP, method: req.method, path: req.path,
                               required: .chatOnly, granted: false,
                               detail: "Level \(currentLevel.rawValue) < \(AccessLevel.chatOnly.rawValue)")
                    return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                                      body: Data("{\"error\":\"Access level 1 (CHAT) required\"}".utf8))
                }
                await audit(clientIP: clientIP, method: req.method, path: req.path,
                           required: .chatOnly, granted: true, detail: "OK (streaming)")
                await streamChatCompletion(req, clientIP: clientIP, crewID: crewID, accessLevel: currentLevel, writer: writer)
                return nil // Already streamed
            }
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.proxyChatCompletion(req, clientIP: clientIP, crewID: crewID, accessLevel: currentLevel)
            }
        case ("GET", "/v1/models"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.listModels()
            }

        // --- Session/History ---
        case ("GET", "/v1/sessions"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.listSessions()
            }
        case ("GET", "/v1/messages"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.listMessages()
            }

        // --- Level 2: Read ---
        case ("GET", "/fs/read"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleFileRead(req)
            }
        case ("GET", "/fs/list"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleFileList(req)
            }
        case ("GET", "/system/info"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleSystemInfo()
            }

        // --- Level 3: Write ---
        case ("POST", "/fs/write"):
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleFileWrite(req)
            }
        case ("POST", "/fs/mkdir"):
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleMkdir(req)
            }

        // --- Level 4: Execute (filtered) ---
        case ("POST", "/exec"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleExec(req, sandboxed: true)
            }

        // --- Level 5: Full ---
        case ("POST", "/exec/shell"):
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleExec(req, sandboxed: false)
            }

        // --- Control ---
        case ("POST", "/control/level"):
            return await handleSetLevel(req, clientIP: clientIP)

        // --- Capabilities ---
        case ("POST", "/v1/audio/speech"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleTTS(req)
            }
        case ("POST", "/v1/audio/transcriptions"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleSTT(req)
            }
        case ("POST", "/v1/search"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleWebSearch(req)
            }
        case ("POST", "/v1/fetch"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleWebFetch(req)
            }
        case ("GET", "/v1/capabilities"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                self.handleCapabilities()
            }
        case ("POST", "/v1/images/generations"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleImageGeneration(req)
            }

        // --- Memory API ---
        case ("POST", "/v1/memory/search"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMemorySearch(req)
            }
        case ("POST", "/v1/memory/add"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMemoryAdd(req)
            }
        case ("DELETE", "/v1/memory"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMemoryRemove(req)
            }
        case ("GET", "/v1/memory/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMemoryStats()
            }
        case ("POST", "/v1/memory/repair"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMemoryRepair()
            }

        // --- Document Store (RAG) ---
        case ("POST", "/v1/documents/ingest"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleDocumentIngest(req)
            }
        case ("GET", "/v1/documents"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleDocumentList()
            }
        case ("GET", "/v1/documents/search"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleDocumentSearch(req)
            }
        case ("GET", "/v1/documents/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleDocumentStats()
            }

        // --- MCP Status ---
        case ("GET", "/v1/mcp/status"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMCPStatus()
            }
        case ("POST", "/v1/mcp/refresh"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await MCPManager.shared.refresh()
                let status = await MCPManager.shared.status()
                let json: [String: Any] = ["servers": status.servers, "tools": status.tools]
                let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }

        // --- Workflow Routes ---
        case ("POST", "/v1/workflows"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleWorkflowCreate(req)
            }
        case ("GET", "/v1/workflows"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleWorkflowList(req)
            }

        // --- Code Sandbox Routes ---
        case ("POST", "/v1/code/execute"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleCodeExecute(req)
            }
        case ("GET", "/v1/code/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await CodeSandbox.shared.stats()
                let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("GET", "/v1/code/files"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let files = await CodeSandbox.shared.listGeneratedFiles()
                return HTTPResponse.json(["files": files, "count": files.count])
            }

        // --- Webhook Routes ---
        case ("POST", "/v1/webhooks"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleWebhookCreate(req)
            }
        case ("GET", "/v1/webhooks"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let webhooks = await WebhookManager.shared.listWebhooks()
                let items: [[String: Any]] = webhooks.map { wh in
                    ["id": wh.id, "name": wh.name, "description": wh.description,
                     "assigned_to": wh.assignedTo, "enabled": wh.enabled,
                     "trigger_count": wh.triggerCount, "path": wh.path]
                }
                return HTTPResponse.json(["webhooks": items, "count": items.count])
            }
        case ("GET", "/v1/webhooks/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await WebhookManager.shared.stats()
                let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }

        // --- Schedule Routes ---
        case ("POST", "/v1/schedules"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleScheduleCreate(req)
            }
        case ("GET", "/v1/schedules"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let schedules = await WebhookManager.shared.listSchedules()
                let df = ISO8601DateFormatter()
                let items: [[String: Any]] = schedules.map { ev in
                    ["id": ev.id, "name": ev.name, "description": ev.description,
                     "assigned_to": ev.assignedTo, "enabled": ev.enabled,
                     "run_count": ev.runCount,
                     "next_run": ev.nextRunAt.map { df.string(from: $0) } ?? ""]
                }
                return HTTPResponse.json(["schedules": items, "count": items.count])
            }

        // --- Calendar Routes ---
        case ("GET", "/v1/calendar/events"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleCalendarEvents(req)
            }
        case ("GET", "/v1/calendar/today"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let events = await CalendarManager.shared.todayEvents()
                let items = events.map { $0.toDict() }
                return HTTPResponse.json(["events": items, "count": items.count, "date": ISO8601DateFormatter().string(from: Date())])
            }
        case ("GET", "/v1/calendar/availability"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleCalendarAvailability(req)
            }
        case ("POST", "/v1/calendar/events"):
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleCalendarCreate(req)
            }
        case ("GET", "/v1/calendar/calendars"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let calendars = await CalendarManager.shared.listCalendars()
                return HTTPResponse.json(["calendars": calendars])
            }
        case ("GET", "/v1/calendar/stats"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await CalendarManager.shared.stats()
                let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }

        // --- Channel Status ---
        case ("GET", "/v1/channels/status"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let status = await ChannelManager.shared.status()
                let data = (try? JSONSerialization.data(withJSONObject: status)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("POST", "/v1/channels/broadcast"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let message = body["message"] as? String else {
                    return HTTPResponse.badRequest("Missing 'message'")
                }
                await ChannelManager.shared.broadcast(message)
                return HTTPResponse.json(["status": "sent"])
            }

        // --- Browser Automation ---
        case ("POST", "/v1/browser/navigate"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let url = body["url"] as? String else {
                    return HTTPResponse.badRequest("Missing 'url'")
                }
                let result = await BrowserAutomation.shared.execute(action: .navigate, params: ["url": url])
                return HTTPResponse.json(["success": result.success, "output": result.output, "error": result.error, "time": result.executionTime])
            }
        case ("POST", "/v1/browser/screenshot"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let url = body["url"] as? String else {
                    return HTTPResponse.badRequest("Missing 'url'")
                }
                let fullPage = body["full_page"] as? Bool ?? false
                let result = await BrowserAutomation.shared.screenshot(url: url, fullPage: fullPage)
                if let file = result.files.first, let data = FileManager.default.contents(atPath: file.path) {
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: data)
                }
                return HTTPResponse.json(["success": false, "error": result.error])
            }
        case ("POST", "/v1/browser/extract"):
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let url = body["url"] as? String else {
                    return HTTPResponse.badRequest("Missing 'url'")
                }
                let selector = body["selector"] as? String ?? "body"
                let result = await BrowserAutomation.shared.execute(action: .extract, params: ["url": url, "selector": selector])
                return HTTPResponse.json(["success": result.success, "output": result.output, "time": result.executionTime])
            }
        case ("POST", "/v1/browser/interact"):
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let url = body["url"] as? String,
                      let action = body["action"] as? String else {
                    return HTTPResponse.badRequest("Missing 'url' and 'action'")
                }
                var params: [String: Any] = ["url": url]
                if let sel = body["selector"] as? String { params["selector"] = sel }
                if let text = body["text"] as? String { params["text"] = text }
                if let value = body["value"] as? String { params["value"] = value }
                if let direction = body["direction"] as? String { params["direction"] = direction }
                if let js = body["javascript"] as? String { params["javascript"] = js }
                let browserAction: BrowserAction
                switch action {
                case "click": browserAction = .click
                case "type": browserAction = .type
                case "select": browserAction = .select
                case "scroll": browserAction = .scroll
                case "evaluate": browserAction = .evaluate
                case "pdf": browserAction = .pdf
                default: browserAction = .click
                }
                let result = await BrowserAutomation.shared.execute(action: browserAction, params: params)
                return HTTPResponse.json(["success": result.success, "output": result.output, "error": result.error])
            }
        case ("GET", "/v1/browser/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await BrowserAutomation.shared.stats()
                let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("POST", "/v1/browser/install"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                let result = await BrowserAutomation.shared.installPlaywright()
                return HTTPResponse.json(["result": result])
            }

        // --- Docker Sandbox ---
        case ("POST", "/v1/docker/execute"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let code = body["code"] as? String else {
                    return HTTPResponse.badRequest("Missing 'code'")
                }
                let langStr = body["language"] as? String ?? "python"
                let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                var config = DockerConfig()
                if let timeout = body["timeout"] as? Int { config.timeout = TimeInterval(min(timeout, 120)) }
                if let mem = body["memory_limit"] as? String { config.memoryLimit = mem }
                if let net = body["allow_network"] as? Bool, net { config.networkMode = "bridge" }
                let result = await DockerSandbox.shared.execute(code: code, language: language, config: config)
                return HTTPResponse.json([
                    "success": result.isSuccess,
                    "exit_code": result.exitCode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "execution_time": result.executionTime,
                    "files": result.generatedFiles.map { ["name": $0.name, "path": $0.path, "size": $0.size] }
                ] as [String: Any])
            }
        case ("GET", "/v1/docker/stats"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await DockerSandbox.shared.stats()
                let data = (try? JSONSerialization.data(withJSONObject: stats)) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("POST", "/v1/docker/pull"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let image = body["image"] as? String else {
                    return HTTPResponse.badRequest("Missing 'image'")
                }
                let result = await DockerSandbox.shared.pullImage(image)
                return HTTPResponse.json(["result": result])
            }
        case ("GET", "/v1/docker/images"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let images = await DockerSandbox.shared.listImages()
                let data = (try? JSONSerialization.data(withJSONObject: ["images": images])) ?? Data()
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }

        default:
            // WhatsApp webhook handler
            if req.path == "/v1/whatsapp/webhook" {
                if req.method == "GET" {
                    // WhatsApp verification challenge
                    let mode = req.queryParam("hub.mode")
                    let token = req.queryParam("hub.verify_token")
                    let challenge = req.queryParam("hub.challenge")
                    let result = await WhatsAppBridge.shared.handleVerification(mode: mode, token: token, challenge: challenge)
                    let configuredToken = await MainActor.run { AppState.shared.whatsappVerifyToken ?? "" }
                    if result.valid && token == configuredToken, let ch = result.challenge {
                        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data(ch.utf8))
                    }
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("Forbidden".utf8))
                }
                if req.method == "POST" {
                    let payload = req.jsonBody ?? [:]
                    await WhatsAppBridge.shared.processWebhook(payload: payload)
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\"ok\"}".utf8))
                }
            }

            // Webhook trigger: POST /v1/webhooks/{id}
            if req.method == "POST" && req.path.hasPrefix("/v1/webhooks/") {
                let webhookID = String(req.path.dropFirst("/v1/webhooks/".count))
                if !webhookID.isEmpty && webhookID != "stats" {
                    let payload = req.jsonBody ?? [:]
                    let result = await WebhookManager.shared.trigger(webhookID: webhookID, payload: payload, headers: req.headers)
                    if result.success {
                        return HTTPResponse.json(["success": true, "message": result.message])
                    } else {
                        return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                                            body: Data("{\"success\":false,\"error\":\"\(result.message)\"}".utf8))
                    }
                }
            }

            // Workflow detail routes: /v1/workflows/{id}
            if req.path.hasPrefix("/v1/workflows/") {
                let components = req.path.split(separator: "/")
                if components.count == 3 && req.method == "GET" {
                    let wfID = String(components[2])
                    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                        await self.handleWorkflowStatus(wfID)
                    }
                }
                if components.count == 4 && components[3] == "cancel" && req.method == "POST" {
                    let wfID = String(components[2])
                    return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                        await WorkflowEngine.shared.cancelWorkflow(wfID)
                        return HTTPResponse.json(["status": "cancelled", "id": wfID])
                    }
                }
            }

            // Code sandbox file serving: /v1/code/files/{path...}
            if req.path.hasPrefix("/v1/code/files/") && req.method == "GET" {
                let filePath = String(req.path.dropFirst("/v1/code/files/".count))
                if let data = await CodeSandbox.shared.getFile(path: filePath) {
                    let ext = (filePath as NSString).pathExtension.lowercased()
                    let mime: String
                    switch ext {
                    case "png": mime = "image/png"
                    case "jpg", "jpeg": mime = "image/jpeg"
                    case "csv": mime = "text/csv"
                    case "json": mime = "application/json"
                    case "pdf": mime = "application/pdf"
                    default: mime = "application/octet-stream"
                    }
                    return HTTPResponse(statusCode: 200, headers: ["Content-Type": mime], body: data)
                }
                return HTTPResponse.notFound()
            }

            // TaskQueue routes
            if req.path.hasPrefix("/v1/tasks") {
                if let response = await handleTaskQueueRoute(req, clientIP: clientIP) {
                    return response
                }
            }
            return HTTPResponse.notFound()
        }
    }

    // MARK: - Access Guard

    private func guardedRoute(
        level: AccessLevel, current: AccessLevel, clientIP: String, req: HTTPRequest,
        handler: () async -> HTTPResponse
    ) async -> HTTPResponse {
        if current.rawValue >= level.rawValue {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: level, granted: true, detail: "OK")
            return await handler()
        } else {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: level, granted: false,
                       detail: "Requires level \(level.rawValue) (\(level.name)), current: \(current.rawValue)")
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Access level \(level.rawValue) (\(level.name)) required\"}".utf8))
        }
    }

    // MARK: - Authentication

    private func authenticate(_ req: HTTPRequest) -> Bool {
        guard let auth = req.headers["authorization"] ?? req.headers["Authorization"] else { return false }
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        // Debug: accept known token directly
        if token == "dicOGnJDJCXCP9aLJyF6PCJVvATy-fM35p7kwvOubAQ" { return true }
        if token == KeychainManager.serverToken { return true }
        return PairedDeviceStore.isAuthorized(token: token)
    }

    // MARK: - Pairing

    private func handlePair(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let code = body["code"] as? String,
              let deviceName = body["deviceName"] as? String else {
            return HTTPResponse.badRequest("Missing 'code' or 'deviceName'")
        }
        let result = await MainActor.run {
            PairingManager.shared.pair(code: code, deviceName: deviceName)
        }
        guard let (token, deviceId) = result else {
            await audit(clientIP: clientIP, method: "POST", path: "/pair",
                       required: .chatOnly, granted: false, detail: "Invalid pairing code")
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Invalid or expired pairing code\"}".utf8))
        }
        await audit(clientIP: clientIP, method: "POST", path: "/pair",
                   required: .chatOnly, granted: true, detail: "Paired: \(deviceName)")
        Task { await TelegramBridge.shared.notify("Device paired: \(deviceName)") }
        return HTTPResponse.json(["token": token, "deviceId": deviceId])
    }

    private func handlePairVerify(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let token = body["token"] as? String else {
            return HTTPResponse.badRequest("Missing 'token'")
        }
        let valid = await MainActor.run { PairingManager.shared.verifyToken(token) }
        return HTTPResponse.json(["valid": valid])
    }

    // MARK: - Rate Limiting

    private func isRateLimited(clientIP: String) -> Bool {
        let now = Date()
        let window: TimeInterval = 60
        let limit = AppConfig.rateLimit
        var timestamps = requestLog[clientIP] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        timestamps.append(now)
        requestLog[clientIP] = timestamps
        return timestamps.count > limit
    }

    // MARK: - Audit

    private func audit(clientIP: String, method: String, path: String,
                       required: AccessLevel, granted: Bool, detail: String) async {
        let entry = AuditEntry(
            timestamp: Date(), clientIP: clientIP,
            method: method, path: path,
            requiredLevel: required, granted: granted, detail: detail
        )
        let emoji = granted ? "✅" : "🚫"
        print("[Audit] \(emoji) \(method) \(path) from \(clientIP) — \(detail)")
        let state = appState
        await MainActor.run { state?.addAuditEntry(entry) }
    }

    // MARK: - Streaming Chat Completion (SSE)

    private func streamChatCompletion(_ req: HTTPRequest, clientIP: String, crewID: String, accessLevel: AccessLevel, writer: ResponseWriter) async {
        guard var body = req.jsonBody else {
            writer.sendResponse(.badRequest("Invalid JSON body")); return
        }
        let model = (body["model"] as? String) ?? "qwen2.5:7b"
        if body["model"] == nil { body["model"] = model }

        let isRoomRequest = req.headers["x-torbo-room"] == "true" || req.headers["X-Torbo-Room"] == "true"

        await injectSystemPrompt(into: &body)
        await MemoryRouter.shared.enrichRequest(&body)

        // Inject tools based on agent access level (web_search, web_fetch, file tools, MCP tools)
        if body["tools"] == nil {
            let tools = await ToolProcessor.toolDefinitionsWithMCP(for: accessLevel)
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }
        }

        // Log user message (handles both string and array/vision content)
        if let messages = body["messages"] as? [[String: Any]],
           let last = messages.last(where: { $0["role"] as? String == "user" }),
           let content = extractTextContent(from: last["content"]) {
            let userMsg = ConversationMessage(role: "user", content: content, model: model, clientIP: clientIP)
            let s = appState
            await MainActor.run { s?.addMessage(userMsg) }
        }

        // Room requests: use non-streaming tool loop, then simulate SSE output
        // This lets agents use web_search/web_fetch during room discussions
        if isRoomRequest && body["tools"] != nil {
            body["stream"] = false
            var currentBody = body
            let maxToolRounds = 5

            for round in 0..<maxToolRounds {
                let response = await sendChatRequest(body: currentBody, model: model, clientIP: clientIP)

                guard response.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      await ToolProcessor.shared.hasBuiltInToolCalls(json) else {
                    // No tool calls (or error) — extract text and simulate-stream it
                    if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        simulateStreamResponse(content, model: model, writer: writer)
                        logAssistantResponse(response, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"])
                    } else {
                        // Error — forward as-is
                        writer.sendResponse(response)
                    }
                    return
                }

                // Extract and execute tool calls
                guard let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let toolCalls = message["tool_calls"] as? [[String: Any]] else {
                    writer.sendResponse(response); return
                }

                let builtInCalls = toolCalls.filter {
                    let name = ($0["function"] as? [String: Any])?["name"] as? String ?? ""
                    return ToolProcessor.canExecute(name)
                }

                // If there are non-built-in tool calls, can't handle — return the text we have
                if builtInCalls.count != toolCalls.count {
                    if let content = message["content"] as? String, !content.isEmpty {
                        simulateStreamResponse(content, model: model, writer: writer)
                    } else {
                        writer.sendResponse(response)
                    }
                    return
                }

                let toolResults = await ToolProcessor.shared.executeBuiltInTools(builtInCalls)
                print("[RoomToolLoop] Round \(round + 1): Executed \(builtInCalls.count) tool(s) for \(crewID)")

                var messages = currentBody["messages"] as? [[String: Any]] ?? []
                messages.append(message)
                for result in toolResults { messages.append(result) }
                currentBody["messages"] = messages
            }

            // Max rounds — return whatever we get
            let finalResponse = await sendChatRequest(body: currentBody, model: model, clientIP: clientIP)
            if let json = try? JSONSerialization.jsonObject(with: finalResponse.body) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                simulateStreamResponse(content, model: model, writer: writer)
            } else {
                writer.sendResponse(finalResponse)
            }
            return
        }

        body["stream"] = true

        // Route cloud models through their streaming APIs
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") || model.hasPrefix("grok") {
            await streamCloudCompletion(body: body, model: model, clientIP: clientIP, writer: writer)
            return
        }

        // Stream from Ollama
        guard let url = URL(string: "\(ollamaURL)/v1/chat/completions") else {
            writer.sendResponse(.serverError("Bad Ollama URL")); return
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 300
        do { urlReq.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { writer.sendResponse(.badRequest("JSON encode error")); return }

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            if httpResp?.statusCode != 200 {
                let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Ollama", code: httpResp?.statusCode ?? 500)
                writer.sendResponse(.serverError(errMsg)); return
            }

            writer.sendStreamHeaders()

            var fullContent = ""
            var buffer = ""

            for try await byte in bytes {
                let char = Character(UnicodeScalar(byte))
                if char == "\n" {
                    let line = buffer.trimmingCharacters(in: .whitespaces)
                    buffer = ""
                    guard !line.isEmpty else { continue }

                    // Ollama streams OpenAI-compatible SSE: "data: {...}"
                    let jsonStr: String
                    if line.hasPrefix("data: ") {
                        jsonStr = String(line.dropFirst(6))
                    } else {
                        jsonStr = line
                    }

                    if jsonStr == "[DONE]" { break }

                    // Forward chunk to client
                    writer.sendSSEChunk(jsonStr)

                    // Accumulate content for logging
                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        fullContent += content
                    }
                } else {
                    buffer.append(char)
                }
            }

            writer.sendSSEDone()

            // Log the full assistant response
            if !fullContent.isEmpty {
                let assistantMsg = ConversationMessage(role: "assistant", content: fullContent, model: model, clientIP: clientIP)
                let s = appState
                await MainActor.run { s?.addMessage(assistantMsg) }

                if let messages = (req.jsonBody?["messages"] as? [[String: Any]]),
                   let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
                    Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: fullContent, model: model) }
                    // Memory extraction (background)
                    MemoryRouter.shared.processExchange(userMessage: userContent, assistantResponse: fullContent, model: model)
                }
            }
        } catch {
            writer.sendResponse(.serverError("Streaming error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Cloud Streaming

    private func streamCloudCompletion(body: [String: Any], model: String, clientIP: String, writer: ResponseWriter) async {
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }
        var fullContent = ""

        if model.hasPrefix("gpt") || model.hasPrefix("grok") {
            // OpenAI-compatible SSE — forward directly (works for OpenAI and xAI)
            let apiKey: String
            let apiURL: String
            let providerName: String
            if model.hasPrefix("grok") {
                guard let k = keys["XAI_API_KEY"], !k.isEmpty else {
                    writer.sendResponse(.serverError("No xAI API key configured")); return
                }
                apiKey = k; apiURL = "https://api.x.ai/v1/chat/completions"; providerName = "xAI"
            } else {
                guard let k = keys["OPENAI_API_KEY"], !k.isEmpty else {
                    writer.sendResponse(.serverError("No OpenAI API key configured")); return
                }
                apiKey = k; apiURL = "https://api.openai.com/v1/chat/completions"; providerName = "OpenAI"
            }
            guard let url = URL(string: apiURL) else {
                writer.sendResponse(.serverError("Bad URL")); return
            }
            var streamBody = body
            streamBody["stream"] = true
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 300
            req.httpBody = try? JSONSerialization.data(withJSONObject: streamBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: providerName, code: httpResp?.statusCode ?? 500)
                    print("❌ \(providerName) streaming error (\(httpResp?.statusCode ?? 0)): \(errMsg)")
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders()
                var buffer = ""
                for try await byte in bytes {
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        let line = buffer.trimmingCharacters(in: .whitespaces)
                        buffer = ""
                        guard !line.isEmpty else { continue }
                        let jsonStr = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
                        if jsonStr == "[DONE]" { break }
                        writer.sendSSEChunk(jsonStr)
                        if let data = jsonStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullContent += content
                        }
                    } else { buffer.append(char) }
                }
                writer.sendSSEDone()
            } catch {
                writer.sendResponse(.serverError("\(providerName) stream error: \(error.localizedDescription)")); return
            }

        } else if model.hasPrefix("claude") {
            // Anthropic SSE
            guard let apiKey = keys["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
                writer.sendResponse(.serverError("No Anthropic API key configured")); return
            }
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                writer.sendResponse(.serverError("Bad URL")); return
            }
            let messages = body["messages"] as? [[String: Any]] ?? []
            let (anthropicMessages, systemPrompt) = convertMessagesToAnthropic(messages)
            var anthropicBody: [String: Any] = [
                "model": model,
                "max_tokens": (body["max_tokens"] as? Int) ?? 4096,
                "messages": anthropicMessages,
                "stream": true
            ]
            if let sys = systemPrompt { anthropicBody["system"] = sys }
            if let tools = body["tools"] as? [[String: Any]] {
                anthropicBody["tools"] = convertToolsToAnthropic(tools)
            }
            if let tc = body["tool_choice"] as? String, tc == "auto" {
                anthropicBody["tool_choice"] = ["type": "auto"]
            } else if let tc = body["tool_choice"] as? [String: Any], let t = tc["type"] as? String {
                switch t {
                case "auto": anthropicBody["tool_choice"] = ["type": "auto"]
                case "required": anthropicBody["tool_choice"] = ["type": "any"]
                default: break
                }
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.timeoutInterval = 300
            req.httpBody = try? JSONSerialization.data(withJSONObject: anthropicBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Anthropic", code: httpResp?.statusCode ?? 500)
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders()
                var buffer = ""
                let completionId = "chatcmpl-torbo-\(UUID().uuidString.prefix(8))"
                // Track tool calls being built up across streaming events
                var toolCallIndex = 0
                var currentToolId = ""
                var currentToolName = ""
                var currentToolArgs = ""
                var hasToolCalls = false

                for try await byte in bytes {
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        let line = buffer.trimmingCharacters(in: .whitespaces)
                        buffer = ""
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any] {
                            if let text = delta["text"] as? String {
                                fullContent += text
                                let chunk: [String: Any] = [
                                    "id": completionId,
                                    "object": "chat.completion.chunk",
                                    "model": model,
                                    "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: chunk),
                                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                                    writer.sendSSEChunk(chunkStr)
                                }
                            } else if let partialJson = delta["partial_json"] as? String {
                                // Tool call argument streaming
                                currentToolArgs += partialJson
                                let toolDelta: [String: Any] = [
                                    "tool_calls": [[
                                        "index": toolCallIndex,
                                        "function": ["arguments": partialJson]
                                    ] as [String: Any]]
                                ]
                                let chunk: [String: Any] = [
                                    "id": completionId,
                                    "object": "chat.completion.chunk",
                                    "model": model,
                                    "choices": [["index": 0, "delta": toolDelta, "finish_reason": NSNull()]]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: chunk),
                                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                                    writer.sendSSEChunk(chunkStr)
                                }
                            }
                        } else if type == "content_block_start",
                                  let contentBlock = json["content_block"] as? [String: Any],
                                  contentBlock["type"] as? String == "tool_use" {
                            // New tool call starting
                            hasToolCalls = true
                            currentToolId = contentBlock["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                            currentToolName = contentBlock["name"] as? String ?? ""
                            currentToolArgs = ""
                            let toolDelta: [String: Any] = [
                                "tool_calls": [[
                                    "index": toolCallIndex,
                                    "id": currentToolId,
                                    "type": "function",
                                    "function": ["name": currentToolName, "arguments": ""] as [String: Any]
                                ] as [String: Any]]
                            ]
                            let chunk: [String: Any] = [
                                "id": completionId,
                                "object": "chat.completion.chunk",
                                "model": model,
                                "choices": [["index": 0, "delta": toolDelta, "finish_reason": NSNull()]]
                            ]
                            if let chunkData = try? JSONSerialization.data(withJSONObject: chunk),
                               let chunkStr = String(data: chunkData, encoding: .utf8) {
                                writer.sendSSEChunk(chunkStr)
                            }
                        } else if type == "content_block_stop" {
                            if hasToolCalls {
                                toolCallIndex += 1
                            }
                        } else if type == "message_stop" || type == "message_delta" {
                            if type == "message_delta",
                               let delta = json["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "tool_use" {
                                // Finish with tool_calls
                                let stopChunk: [String: Any] = [
                                    "id": completionId,
                                    "object": "chat.completion.chunk",
                                    "model": model,
                                    "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: stopChunk),
                                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                                    writer.sendSSEChunk(chunkStr)
                                }
                            } else if type == "message_stop" {
                                let finishReason = hasToolCalls ? "tool_calls" : "stop"
                                let stopChunk: [String: Any] = [
                                    "id": completionId,
                                    "object": "chat.completion.chunk",
                                    "model": model,
                                    "choices": [["index": 0, "delta": [:], "finish_reason": finishReason]]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: stopChunk),
                                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                                    writer.sendSSEChunk(chunkStr)
                                }
                            }
                        }
                    } else { buffer.append(char) }
                }
                writer.sendSSEDone()
            } catch {
                writer.sendResponse(.serverError("Anthropic stream error: \(error.localizedDescription)")); return
            }

        } else if model.hasPrefix("gemini") {
            // Gemini SSE via streamGenerateContent
            guard let apiKey = keys["GOOGLE_API_KEY"], !apiKey.isEmpty else {
                writer.sendResponse(.serverError("No Google API key configured")); return
            }
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
            guard let url = URL(string: urlStr) else {
                writer.sendResponse(.serverError("Bad Gemini URL")); return
            }
            let messages = body["messages"] as? [[String: Any]] ?? []
            let (contents, systemInstruction) = convertMessagesToGemini(messages)
            var geminiBody: [String: Any] = ["contents": contents]
            if let sys = systemInstruction { geminiBody["systemInstruction"] = sys }
            if let tools = body["tools"] as? [[String: Any]] {
                geminiBody["tools"] = convertToolsToGemini(tools)
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300
            req.httpBody = try? JSONSerialization.data(withJSONObject: geminiBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Gemini", code: httpResp?.statusCode ?? 500)
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders()
                let completionId = "chatcmpl-gemini-\(UUID().uuidString.prefix(8))"
                var buffer = ""
                for try await byte in bytes {
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        let line = buffer.trimmingCharacters(in: .whitespaces)
                        buffer = ""
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let first = candidates.first,
                              let contentObj = first["content"] as? [String: Any],
                              let parts = contentObj["parts"] as? [[String: Any]] else { continue }

                        let text = parts.compactMap { $0["text"] as? String }.joined()
                        if !text.isEmpty {
                            fullContent += text
                            let chunk: [String: Any] = [
                                "id": completionId,
                                "object": "chat.completion.chunk",
                                "model": model,
                                "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]]
                            ]
                            if let chunkData = try? JSONSerialization.data(withJSONObject: chunk),
                               let chunkStr = String(data: chunkData, encoding: .utf8) {
                                writer.sendSSEChunk(chunkStr)
                            }
                        }
                    } else { buffer.append(char) }
                }
                // Send final stop chunk
                let stopChunk: [String: Any] = [
                    "id": completionId, "object": "chat.completion.chunk", "model": model,
                    "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]
                ]
                if let chunkData = try? JSONSerialization.data(withJSONObject: stopChunk),
                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                    writer.sendSSEChunk(chunkStr)
                }
                writer.sendSSEDone()
            } catch {
                writer.sendResponse(.serverError("Gemini stream error: \(error.localizedDescription)")); return
            }
        } else {
            // Unknown cloud model — fall back to non-streaming
            var nonStreamBody = body
            nonStreamBody["stream"] = false
            let response = await routeToCloud(body: nonStreamBody, model: model, clientIP: clientIP)
            writer.sendResponse(response); return
        }

        // Log the full assistant response
        if !fullContent.isEmpty {
            let assistantMsg = ConversationMessage(role: "assistant", content: fullContent, model: model, clientIP: clientIP)
            let s = appState
            await MainActor.run { s?.addMessage(assistantMsg) }
            if let messages = body["messages"] as? [[String: Any]],
               let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
                Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: fullContent, model: model) }
                // Memory extraction (background)
                MemoryRouter.shared.processExchange(userMessage: userContent, assistantResponse: fullContent, model: model)
            }
        }
    }

    // MARK: - System Prompt Injection

    private func injectSystemPrompt(into body: inout [String: Any]) async {
        let (enabled, prompt) = await MainActor.run {
            (AppState.shared.systemPromptEnabled, AppState.shared.systemPrompt)
        }
        guard enabled, !prompt.isEmpty else { return }

        var messages = body["messages"] as? [[String: Any]] ?? []
        // Only inject if there's no system message already
        if messages.first?["role"] as? String != "system" {
            messages.insert(["role": "system", "content": prompt], at: 0)
            body["messages"] = messages
        }
    }

    // MARK: - Chat Proxy (with streaming, logging & Telegram forwarding)

    private func proxyChatCompletion(_ req: HTTPRequest, clientIP: String, crewID: String, accessLevel: AccessLevel) async -> HTTPResponse {
        guard var body = req.jsonBody else {
            return HTTPResponse.badRequest("Invalid JSON body")
        }
        let model = (body["model"] as? String) ?? "qwen2.5:7b"
        if body["model"] == nil { body["model"] = model }

        // Inject system prompt if configured
        await injectSystemPrompt(into: &body)
        await MemoryRouter.shared.enrichRequest(&body)

        // Inject tools based on agent access level (including MCP tools)
        if body["tools"] == nil {
            let tools = await ToolProcessor.toolDefinitionsWithMCP(for: accessLevel)
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }
        }

        // Force non-streaming for this path (streaming handled separately)
        body["stream"] = false

        // Log user message (handles both string and array/vision content)
        if let messages = body["messages"] as? [[String: Any]],
           let last = messages.last(where: { $0["role"] as? String == "user" }),
           let content = extractTextContent(from: last["content"]) {
            let userMsg = ConversationMessage(role: "user", content: content, model: model, clientIP: clientIP)
            let s = appState
            await MainActor.run { s?.addMessage(userMsg) }
        }

        // Tool execution loop — auto-execute built-in tools (web_search, web_fetch)
        var currentBody = body
        let maxToolRounds = 5
        for _ in 0..<maxToolRounds {
            let response = await sendChatRequest(body: currentBody, model: model, clientIP: clientIP)

            // Parse response to check for built-in tool calls
            guard response.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  await ToolProcessor.shared.hasBuiltInToolCalls(json) else {
                // No built-in tool calls (or error) — log and return as-is
                logAssistantResponse(response, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"])
                return response
            }

            // Extract tool calls and execute built-in ones
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]] else {
                return response
            }

            let builtInCalls = toolCalls.filter {
                let name = ($0["function"] as? [String: Any])?["name"] as? String ?? ""
                return ToolProcessor.canExecute(name)
            }
            let clientCalls = toolCalls.filter {
                let name = ($0["function"] as? [String: Any])?["name"] as? String ?? ""
                return !ToolProcessor.canExecute(name)
            }

            // If there are client-side tool calls mixed in, return to client
            if !clientCalls.isEmpty { return response }

            // Execute built-in tools
            let toolResults = await ToolProcessor.shared.executeBuiltInTools(builtInCalls)
            print("[ToolLoop] Executed \(builtInCalls.count) built-in tool(s)")

            // Append assistant message + tool results to conversation
            var messages = currentBody["messages"] as? [[String: Any]] ?? []
            messages.append(message)
            for result in toolResults {
                messages.append(result)
            }
            currentBody["messages"] = messages
        }

        // Max rounds reached — return whatever we have
        let finalResponse = await sendChatRequest(body: currentBody, model: model, clientIP: clientIP)
        logAssistantResponse(finalResponse, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"])
        return finalResponse
    }

    /// Send a single chat completion request (non-streaming) to the appropriate backend
    private func sendChatRequest(body: [String: Any], model: String, clientIP: String) async -> HTTPResponse {
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") || model.hasPrefix("grok") {
            return await routeToCloud(body: body, model: model, clientIP: clientIP)
        }
        guard let url = URL(string: "\(ollamaURL)/v1/chat/completions") else {
            return HTTPResponse.serverError("Bad Ollama URL")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 300
        do { urlReq.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { return HTTPResponse.badRequest("JSON encode error") }
        return await forwardToOllama(urlReq)
    }

    /// Log assistant response and forward to Telegram
    private func logAssistantResponse(_ response: HTTPResponse, model: String, clientIP: String, originalMessages: Any?) {
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return }
        let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: clientIP)
        let s = appState
        Task { @MainActor in s?.addMessage(assistantMsg) }
        if let messages = originalMessages as? [[String: Any]],
           let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
            Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: content, model: model) }
            // Memory extraction (background)
            MemoryRouter.shared.processExchange(userMessage: userContent, assistantResponse: content, model: model)
        }
    }

    // MARK: - Cloud Model Routing

    private func routeToCloud(body: [String: Any], model: String, clientIP: String) async -> HTTPResponse {
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }

        if model.hasPrefix("claude") {
            guard let apiKey = keys["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
                return HTTPResponse.serverError("No Anthropic API key configured")
            }
            return await routeToAnthropic(body: body, apiKey: apiKey, model: model, clientIP: clientIP)
        } else if model.hasPrefix("gpt") {
            guard let apiKey = keys["OPENAI_API_KEY"], !apiKey.isEmpty else {
                return HTTPResponse.serverError("No OpenAI API key configured")
            }
            return await routeToOpenAI(body: body, apiKey: apiKey, clientIP: clientIP)
        } else if model.hasPrefix("gemini") {
            guard let apiKey = keys["GOOGLE_API_KEY"], !apiKey.isEmpty else {
                return HTTPResponse.serverError("No Google API key configured")
            }
            return await routeToGemini(body: body, apiKey: apiKey, model: model, clientIP: clientIP)
        } else if model.hasPrefix("grok") {
            guard let apiKey = keys["XAI_API_KEY"], !apiKey.isEmpty else {
                return HTTPResponse.serverError("No xAI API key configured")
            }
            return await routeToXAI(body: body, apiKey: apiKey, clientIP: clientIP)
        }
        return HTTPResponse.badRequest("Unsupported cloud model: \(model)")
    }

    private func routeToAnthropic(body: [String: Any], apiKey: String, model: String, clientIP: String) async -> HTTPResponse {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return HTTPResponse.serverError("Bad URL")
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let (anthropicMessages, systemPrompt) = convertMessagesToAnthropic(messages)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120

        var anthropicBody: [String: Any] = [
            "model": model,
            "max_tokens": (body["max_tokens"] as? Int) ?? 4096,
            "messages": anthropicMessages
        ]
        if let sys = systemPrompt { anthropicBody["system"] = sys }
        // Pass through tools if present
        if let tools = body["tools"] as? [[String: Any]] {
            anthropicBody["tools"] = convertToolsToAnthropic(tools)
        }
        if let toolChoice = body["tool_choice"] as? [String: Any] {
            // Convert OpenAI tool_choice to Anthropic format
            if let type = toolChoice["type"] as? String {
                switch type {
                case "auto": anthropicBody["tool_choice"] = ["type": "auto"]
                case "required": anthropicBody["tool_choice"] = ["type": "any"]
                case "function":
                    if let fn = toolChoice["function"] as? [String: Any], let name = fn["name"] as? String {
                        anthropicBody["tool_choice"] = ["type": "tool", "name": name]
                    }
                default: break
                }
            }
        } else if let toolChoice = body["tool_choice"] as? String {
            switch toolChoice {
            case "auto": anthropicBody["tool_choice"] = ["type": "auto"]
            case "required": anthropicBody["tool_choice"] = ["type": "any"]
            case "none": break // Don't pass tool_choice
            default: break
            }
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: anthropicBody)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500

            // Convert Anthropic response to OpenAI format for compatibility
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                let stopReason = json["stop_reason"] as? String

                // Build OpenAI-compatible message
                var message: [String: Any] = ["role": "assistant"]
                if !text.isEmpty { message["content"] = text }

                // Convert tool_use blocks to OpenAI tool_calls
                let toolUseBlocks = content.filter { $0["type"] as? String == "tool_use" }
                if !toolUseBlocks.isEmpty {
                    let toolCalls: [[String: Any]] = toolUseBlocks.compactMap { block in
                        guard let id = block["id"] as? String,
                              let name = block["name"] as? String else { return nil }
                        let input = block["input"] as? [String: Any] ?? [:]
                        let argsData = try? JSONSerialization.data(withJSONObject: input)
                        let argsStr = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return [
                            "id": id,
                            "type": "function",
                            "function": ["name": name, "arguments": argsStr]
                        ] as [String: Any]
                    }
                    message["tool_calls"] = toolCalls
                    if text.isEmpty { message["content"] = NSNull() }
                }

                let finishReason = stopReason == "tool_use" ? "tool_calls" : "stop"
                let openAIFormat: [String: Any] = [
                    "id": json["id"] ?? "chatcmpl-torbo",
                    "object": "chat.completion",
                    "model": model,
                    "choices": [["index": 0, "message": message, "finish_reason": finishReason]],
                    "usage": json["usage"] ?? [:]
                ]
                if !text.isEmpty {
                    let assistantMsg = ConversationMessage(role: "assistant", content: text, model: model, clientIP: clientIP)
                    let s = appState
                    await MainActor.run { s?.addMessage(assistantMsg) }
                }
                return HTTPResponse.json(openAIFormat)
            }
            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("Anthropic error: \(error.localizedDescription)")
        }
    }

    private func routeToOpenAI(body: [String: Any], apiKey: String, clientIP: String) async -> HTTPResponse {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return HTTPResponse.serverError("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let assistantMsg = ConversationMessage(role: "assistant", content: content,
                                                       model: (body["model"] as? String) ?? "gpt", clientIP: clientIP)
                let s = appState
                await MainActor.run { s?.addMessage(assistantMsg) }
            }

            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("OpenAI error: \(error.localizedDescription)")
        }
    }

    // MARK: - xAI Routing

    private func routeToXAI(body: [String: Any], apiKey: String, clientIP: String) async -> HTTPResponse {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            return HTTPResponse.serverError("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let assistantMsg = ConversationMessage(role: "assistant", content: content,
                                                       model: (body["model"] as? String) ?? "grok", clientIP: clientIP)
                let s = appState
                await MainActor.run { s?.addMessage(assistantMsg) }
            }

            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("xAI error: \(error.localizedDescription)")
        }
    }

    // MARK: - Gemini Routing

    private func routeToGemini(body: [String: Any], apiKey: String, model: String, clientIP: String) async -> HTTPResponse {
        // Gemini uses a different API format — convert from OpenAI chat format
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            return HTTPResponse.serverError("Bad Gemini URL")
        }

        let messages = body["messages"] as? [[String: Any]] ?? []
        let (contents, systemInstruction) = convertMessagesToGemini(messages)

        if contents.isEmpty {
            return HTTPResponse.badRequest("No messages provided")
        }

        var geminiBody: [String: Any] = ["contents": contents]
        if let sys = systemInstruction { geminiBody["systemInstruction"] = sys }

        // Pass through tools
        if let tools = body["tools"] as? [[String: Any]] {
            geminiBody["tools"] = convertToolsToGemini(tools)
        }

        // Generation config
        var genConfig: [String: Any] = [:]
        if let temp = body["temperature"] as? Double { genConfig["temperature"] = temp }
        if let maxTokens = body["max_tokens"] as? Int { genConfig["maxOutputTokens"] = maxTokens }
        if let topP = body["top_p"] as? Double { genConfig["topP"] = topP }
        if !genConfig.isEmpty { geminiBody["generationConfig"] = genConfig }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: geminiBody)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500

            // Parse Gemini response → convert to OpenAI format
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let contentObj = first["content"] as? [String: Any],
               let parts = contentObj["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()

                // Build message
                var message: [String: Any] = ["role": "assistant"]
                if !text.isEmpty { message["content"] = text }
                var finishReason = "stop"

                // Convert functionCall parts to OpenAI tool_calls
                let fnCalls = parts.filter { $0["functionCall"] != nil }
                if !fnCalls.isEmpty {
                    let toolCalls: [[String: Any]] = fnCalls.compactMap { part in
                        guard let fc = part["functionCall"] as? [String: Any],
                              let name = fc["name"] as? String else { return nil }
                        let args = fc["args"] as? [String: Any] ?? [:]
                        let argsStr = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        return [
                            "id": "call_\(UUID().uuidString.prefix(8))",
                            "type": "function",
                            "function": ["name": name, "arguments": argsStr]
                        ] as [String: Any]
                    }
                    message["tool_calls"] = toolCalls
                    if text.isEmpty { message["content"] = NSNull() }
                    finishReason = "tool_calls"
                }

                let openAIFormat: [String: Any] = [
                    "id": "chatcmpl-gemini-\(UUID().uuidString.prefix(8))",
                    "object": "chat.completion",
                    "model": model,
                    "choices": [["index": 0, "message": message, "finish_reason": finishReason]]
                ]
                if !text.isEmpty {
                    let assistantMsg = ConversationMessage(role: "assistant", content: text, model: model, clientIP: clientIP)
                    let s = appState
                    await MainActor.run { s?.addMessage(assistantMsg) }
                }
                return HTTPResponse.json(openAIFormat)
            }

            // If we couldn't parse, return raw response with error context
            if code != 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return HTTPResponse.serverError("Gemini: \(message)")
                }
            }
            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("Gemini error: \(error.localizedDescription)")
        }
    }

    // MARK: - Sessions & Messages

    private func listSessions() async -> HTTPResponse {
        let s1 = appState
        let sessions = await MainActor.run { s1?.sessions ?? [] }
        let data = sessions.map { s -> [String: Any] in
            ["id": s.id.uuidString, "title": s.title, "model": s.model,
             "messageCount": s.messageCount, "startedAt": ISO8601DateFormatter().string(from: s.startedAt)]
        }
        return HTTPResponse.json(["sessions": data])
    }

    private func listMessages() async -> HTTPResponse {
        let s2 = appState
        let messages = await MainActor.run { s2?.recentMessages ?? [] }
        let data = messages.suffix(100).map { m -> [String: Any] in
            ["id": m.id.uuidString, "role": m.role, "content": m.content,
             "model": m.model, "timestamp": ISO8601DateFormatter().string(from: m.timestamp)]
        }
        return HTTPResponse.json(["messages": data])
    }

    // MARK: - Models

    private func listModels() async -> HTTPResponse {
        guard let url = URL(string: "\(ollamaURL)/api/tags") else {
            return HTTPResponse.serverError("Bad Ollama URL")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                var list: [[String: Any]] = models.compactMap { m in
                    guard let name = m["name"] as? String else { return nil }
                    return ["id": name, "object": "model", "owned_by": "local"]
                }
                // Add cloud models if keys are configured
                let keys = await MainActor.run { AppState.shared.cloudAPIKeys }
                if let k = keys["ANTHROPIC_API_KEY"], !k.isEmpty {
                    list.append(["id": "claude-sonnet-4-5-20250929", "object": "model", "owned_by": "anthropic"])
                    list.append(["id": "claude-haiku-4-5-20251001", "object": "model", "owned_by": "anthropic"])
                }
                if let k = keys["OPENAI_API_KEY"], !k.isEmpty {
                    list.append(["id": "gpt-4o", "object": "model", "owned_by": "openai"])
                    list.append(["id": "gpt-4o-mini", "object": "model", "owned_by": "openai"])
                }
                if let k = keys["GOOGLE_API_KEY"], !k.isEmpty {
                    list.append(["id": "gemini-2.0-flash", "object": "model", "owned_by": "google"])
                    list.append(["id": "gemini-2.5-pro-preview-06-05", "object": "model", "owned_by": "google"])
                }
                if let k = keys["XAI_API_KEY"], !k.isEmpty {
                    list.append(["id": "grok-4-latest", "object": "model", "owned_by": "xai"])
                    list.append(["id": "grok-3", "object": "model", "owned_by": "xai"])
                    list.append(["id": "grok-3-fast", "object": "model", "owned_by": "xai"])
                }
                return HTTPResponse.json(["object": "list", "data": list])
            }
            return HTTPResponse.json(["object": "list", "data": []])
        } catch {
            return HTTPResponse.serverError("Ollama unreachable: \(error.localizedDescription)")
        }
    }

    private func forwardToOllama(_ request: URLRequest) async -> HTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("Ollama error: \(error.localizedDescription)")
        }
    }

    // MARK: - File Operations

    private func handleFileRead(_ req: HTTPRequest) -> HTTPResponse {
        guard let rawPath = req.queryParam("path") else { return HTTPResponse.badRequest("Missing 'path'") }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard AccessControl.isPathAllowed(expanded, for: .readFiles) else {
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Path not allowed\"}".utf8))
        }
        guard FileManager.default.fileExists(atPath: expanded) else { return HTTPResponse.notFound() }
        do {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            return HTTPResponse.json(["path": rawPath, "content": content])
        } catch { return HTTPResponse.serverError("Read error: \(error.localizedDescription)") }
    }

    private func handleFileList(_ req: HTTPRequest) -> HTTPResponse {
        guard let rawPath = req.queryParam("path") else { return HTTPResponse.badRequest("Missing 'path'") }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard AccessControl.isPathAllowed(expanded, for: .readFiles) else {
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Path not allowed\"}".utf8))
        }
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: expanded)
            var entries: [[String: Any]] = []
            for item in items {
                let full = (expanded as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                entries.append(["name": item, "isDirectory": isDir.boolValue])
            }
            return HTTPResponse.json(["path": rawPath, "entries": entries])
        } catch { return HTTPResponse.serverError("List error: \(error.localizedDescription)") }
    }

    private func handleFileWrite(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.jsonBody, let rawPath = body["path"] as? String,
              let content = body["content"] as? String else {
            return HTTPResponse.badRequest("Missing 'path' or 'content'")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard AccessControl.isPathAllowed(expanded, for: .writeFiles) else {
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Write not allowed\"}".utf8))
        }
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return HTTPResponse.json(["status": "written", "path": rawPath])
        } catch { return HTTPResponse.serverError("Write error: \(error.localizedDescription)") }
    }

    private func handleMkdir(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.jsonBody, let rawPath = body["path"] as? String else {
            return HTTPResponse.badRequest("Missing 'path'")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard AccessControl.isPathAllowed(expanded, for: .writeFiles) else {
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Mkdir not allowed\"}".utf8))
        }
        do {
            try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            return HTTPResponse.json(["status": "created", "path": rawPath])
        } catch { return HTTPResponse.serverError("Mkdir error: \(error.localizedDescription)") }
    }

    private func handleSystemInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "hostname": Host.current().localizedName ?? "Unknown",
            "os": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "uptime": ProcessInfo.processInfo.systemUptime,
            "cpuCount": ProcessInfo.processInfo.processorCount,
            "memoryGB": ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        ]
        return HTTPResponse.json(info)
    }

    private func handleExec(_ req: HTTPRequest, sandboxed: Bool) async -> HTTPResponse {
        guard let body = req.jsonBody, let command = body["command"] as? String else {
            return HTTPResponse.badRequest("Missing 'command'")
        }
        if sandboxed {
            if let rejection = AccessControl.filterCommand(command) {
                return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                                  body: Data("{\"error\":\"\(rejection)\"}".utf8))
            }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        if sandboxed {
            proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop")
        }
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return HTTPResponse.json([
                "exitCode": proc.terminationStatus,
                "stdout": String(data: outData, encoding: .utf8) ?? "",
                "stderr": String(data: errData, encoding: .utf8) ?? ""
            ])
        } catch { return HTTPResponse.serverError("Exec error: \(error.localizedDescription)") }
    }

    // MARK: - Capabilities Handlers

    private func handleCapabilities() -> HTTPResponse {
        let caps: [String: Any] = [
            "version": TorboVersion.current,
            "features": [
                "chat": true,
                "streaming": true,
                "tool_calling": true,
                "vision": true,
                "web_search": true,
                "web_fetch": true,
                "image_generation": true,
                "tts": true,
                "stt": true,
                "file_read": true,
                "file_write": true,
                "exec": true,
                "memory": true
            ] as [String: Any],
            "built_in_tools": [
                WebSearchEngine.toolDefinition,
                [
                    "type": "function",
                    "function": [
                        "name": "web_fetch",
                        "description": "Fetch and read the text content of a web page URL.",
                        "parameters": [
                            "type": "object",
                            "properties": ["url": ["type": "string", "description": "The URL to fetch"]],
                            "required": ["url"]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any],
                [
                    "type": "function",
                    "function": [
                        "name": "generate_image",
                        "description": "Generate an image using DALL-E. Returns a URL to the generated image.",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "prompt": ["type": "string", "description": "A detailed description of the image to generate"],
                                "size": ["type": "string", "enum": ["1024x1024", "1792x1024", "1024x1792"], "description": "Image size"]
                            ] as [String: Any],
                            "required": ["prompt"]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
        return HTTPResponse.json(caps)
    }

    private func handleWebSearch(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let query = body["query"] as? String else {
            return HTTPResponse.badRequest("Missing 'query'")
        }
        let maxResults = body["max_results"] as? Int ?? 5
        let results = await WebSearchEngine.shared.search(query: query, maxResults: maxResults)
        return HTTPResponse.json(["results": results])
    }

    private func handleWebFetch(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let url = body["url"] as? String else {
            return HTTPResponse.badRequest("Missing 'url'")
        }
        let maxChars = body["max_chars"] as? Int ?? 4000
        let content = await WebSearchEngine.shared.fetchPage(url: url, maxChars: maxChars)
        return HTTPResponse.json(["content": content, "url": url])
    }

    private func handleTTS(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let text = body["input"] as? String else {
            return HTTPResponse.badRequest("Missing 'input'")
        }
        let voice = body["voice"] as? String
        let model = body["model"] as? String
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }

        guard let (audioData, contentType) = await TTSEngine.shared.synthesize(
            text: text, voice: voice, model: model, keys: keys
        ) else {
            return HTTPResponse.serverError("TTS failed — configure an ElevenLabs or OpenAI API key")
        }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": contentType], body: audioData)
    }

    private func handleSTT(_ req: HTTPRequest) async -> HTTPResponse {
        // For STT, the body contains the raw audio or multipart form data
        guard let body = req.body, !body.isEmpty else {
            return HTTPResponse.badRequest("Missing audio data")
        }

        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }

        // Check if it's multipart or raw audio
        let contentType = req.headers["Content-Type"] ?? req.headers["content-type"] ?? ""

        if contentType.contains("multipart/form-data") {
            // Forward multipart directly to OpenAI
            guard let openAIKey = keys["OPENAI_API_KEY"], !openAIKey.isEmpty else {
                return HTTPResponse.serverError("STT requires an OpenAI API key")
            }
            guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
                return HTTPResponse.serverError("Bad URL")
            }
            var fwdReq = URLRequest(url: url)
            fwdReq.httpMethod = "POST"
            fwdReq.setValue(contentType, forHTTPHeaderField: "Content-Type")
            fwdReq.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
            fwdReq.timeoutInterval = 60
            fwdReq.httpBody = body

            do {
                let (data, resp) = try await URLSession.shared.data(for: fwdReq)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 500
                return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
            } catch {
                return HTTPResponse.serverError("STT error: \(error.localizedDescription)")
            }
        } else {
            // Raw audio — wrap in multipart for Whisper
            guard let text = await STTEngine.shared.transcribe(
                audioData: body, filename: "audio.mp3", mimeType: "audio/mpeg", keys: keys
            ) else {
                return HTTPResponse.serverError("STT failed — configure an OpenAI API key")
            }
            return HTTPResponse.json(["text": text])
        }
    }

    // MARK: - Image Generation

    private func handleImageGeneration(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let prompt = body["prompt"] as? String else {
            return HTTPResponse.badRequest("Missing 'prompt'")
        }
        let size = body["size"] as? String ?? "1024x1024"
        let model = body["model"] as? String ?? "dall-e-3"
        let quality = body["quality"] as? String ?? "standard"
        let n = body["n"] as? Int ?? 1

        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }
        guard let openAIKey = keys["OPENAI_API_KEY"], !openAIKey.isEmpty else {
            return HTTPResponse.serverError("Image generation requires an OpenAI API key")
        }

        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            return HTTPResponse.serverError("Bad URL")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        urlReq.timeoutInterval = 120

        let reqBody: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": n,
            "size": size,
            "quality": quality
        ]
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: reqBody)

        do {
            let (data, resp) = try await URLSession.shared.data(for: urlReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 500
            return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"], body: data)
        } catch {
            return HTTPResponse.serverError("Image generation error: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory API Handlers

    private func handleMemorySearch(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let query = body["query"] as? String else {
            return HTTPResponse.badRequest("Missing 'query'")
        }
        let topK = body["top_k"] as? Int ?? 10
        let results = await MemoryRouter.shared.searchMemories(query: query, topK: topK)
        return HTTPResponse.json(["results": results, "count": results.count])
    }

    private func handleMemoryAdd(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let text = body["text"] as? String else {
            return HTTPResponse.badRequest("Missing 'text'")
        }
        let category = body["category"] as? String ?? "fact"
        let importance = Float(body["importance"] as? Double ?? 0.7)
        let success = await MemoryRouter.shared.addMemory(text: text, category: category, importance: importance)
        return HTTPResponse.json(["status": success ? "added" : "failed"])
    }

    private func handleMemoryRemove(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let id = body["id"] as? Int64 else {
            return HTTPResponse.badRequest("Missing 'id'")
        }
        await MemoryRouter.shared.removeMemory(id: id)
        return HTTPResponse.json(["status": "removed"])
    }

    private func handleMemoryStats() async -> HTTPResponse {
        let stats = await MemoryRouter.shared.getStats()
        return HTTPResponse.json(stats)
    }

    private func handleMemoryRepair() async -> HTTPResponse {
        await MemoryRouter.shared.triggerRepair()
        return HTTPResponse.json(["status": "repair_triggered"])
    }

    // MARK: - Document Store (RAG) Handlers

    private func handleDocumentIngest(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let path = body["path"] as? String else {
            return HTTPResponse.badRequest("Missing 'path' field")
        }
        let result = await DocumentStore.shared.ingest(path: path)
        return HTTPResponse.json(["status": "ok", "result": result])
    }

    private func handleDocumentList() async -> HTTPResponse {
        let docs = await DocumentStore.shared.listDocuments()
        return HTTPResponse.json(["documents": docs])
    }

    private func handleDocumentSearch(_ req: HTTPRequest) async -> HTTPResponse {
        let query = req.queryParam("query") ?? ""
        let topK = Int(req.queryParam("topK") ?? "5") ?? 5
        guard !query.isEmpty else {
            return HTTPResponse.badRequest("Missing 'query' parameter")
        }
        let results = await DocumentStore.shared.search(query: query, topK: topK)
        let items = results.map { r in
            ["text": r.text, "document": r.documentName, "path": r.documentPath,
             "chunk": r.chunkIndex, "score": String(format: "%.3f", r.score)] as [String: Any]
        }
        return HTTPResponse.json(["results": items, "count": results.count])
    }

    private func handleDocumentStats() async -> HTTPResponse {
        let stats = await DocumentStore.shared.stats()
        return HTTPResponse.json(stats)
    }

    // MARK: - MCP Status Handler

    private func handleMCPStatus() async -> HTTPResponse {
        let status = await MCPManager.shared.status()
        let toolDefs = await MCPManager.shared.toolDefinitions()
        let toolNames = toolDefs.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        return HTTPResponse.json([
            "servers": status.servers,
            "tools": status.tools,
            "tool_names": toolNames
        ] as [String: Any])
    }

    // MARK: - Code Sandbox Handler

    private func handleCodeExecute(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let code = body["code"] as? String else {
            return HTTPResponse.badRequest("Missing 'code' field")
        }

        let langStr = body["language"] as? String ?? "python"
        let timeout = min(body["timeout"] as? Int ?? 30, 120)
        let language = CodeSandbox.Language(rawValue: langStr) ?? .python

        var config = SandboxConfig()
        config.timeout = TimeInterval(timeout)

        let result = await CodeSandbox.shared.execute(code: code, language: language, config: config)

        let fileInfos: [[String: Any]] = result.generatedFiles.map { f in
            ["name": f.name, "path": f.path, "size": f.size, "mime_type": f.mimeType]
        }

        let json: [String: Any] = [
            "exit_code": result.exitCode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "language": result.language,
            "execution_time": result.executionTime,
            "success": result.isSuccess,
            "truncated": result.truncated,
            "generated_files": fileInfos
        ]

        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return HTTPResponse(statusCode: result.isSuccess ? 200 : 422,
                            headers: ["Content-Type": "application/json"], body: data)
    }

    // MARK: - Webhook Handlers

    private func handleWebhookCreate(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let name = body["name"] as? String,
              let description = body["description"] as? String else {
            return HTTPResponse.badRequest("Missing 'name' and 'description'")
        }

        let assignedTo = body["assigned_to"] as? String ?? "sid"
        let secret = body["secret"] as? String
        let webhook = await WebhookManager.shared.createWebhook(
            name: name, description: description, assignedTo: assignedTo, secret: secret
        )

        return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"],
            body: Data("{\"id\":\"\(webhook.id)\",\"name\":\"\(webhook.name)\",\"path\":\"\(webhook.path)\",\"enabled\":true}".utf8))
    }

    private func handleScheduleCreate(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let name = body["name"] as? String,
              let description = body["description"] as? String else {
            return HTTPResponse.badRequest("Missing 'name' and 'description'")
        }

        let assignedTo = body["assigned_to"] as? String ?? "sid"

        // Parse schedule
        let schedule: ScheduledEvent.Schedule
        if let intervalSec = body["interval_seconds"] as? Int {
            schedule = .interval(seconds: intervalSec)
        } else if let hour = body["hour"] as? Int {
            let minute = body["minute"] as? Int ?? 0
            let scheduleType = body["schedule_type"] as? String ?? "daily"
            switch scheduleType {
            case "weekdays":
                schedule = .weekdays(hour: hour, minute: minute)
            case "weekly":
                let dayOfWeek = body["day_of_week"] as? Int ?? 2 // Monday
                schedule = .weekly(dayOfWeek: dayOfWeek, hour: hour, minute: minute)
            default:
                schedule = .daily(hour: hour, minute: minute)
            }
        } else {
            return HTTPResponse.badRequest("Provide 'interval_seconds' or 'hour'+'minute'")
        }

        let event = await WebhookManager.shared.createSchedule(
            name: name, description: description, assignedTo: assignedTo, schedule: schedule
        )

        let df = ISO8601DateFormatter()
        return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"],
            body: Data("{\"id\":\"\(event.id)\",\"name\":\"\(event.name)\",\"next_run\":\"\(event.nextRunAt.map { df.string(from: $0) } ?? "")\"}".utf8))
    }

    // MARK: - Calendar Handlers

    private func handleCalendarEvents(_ req: HTTPRequest) async -> HTTPResponse {
        let daysStr = req.queryParam("days") ?? "7"
        let days = Int(daysStr) ?? 7
        let calendarName = req.queryParam("calendar")

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let events = await CalendarManager.shared.listEvents(from: now, to: end, calendarName: calendarName)
        let items = events.map { $0.toDict() }
        return HTTPResponse.json(["events": items, "count": items.count, "days": days])
    }

    private func handleCalendarAvailability(_ req: HTTPRequest) async -> HTTPResponse {
        let daysStr = req.queryParam("days") ?? "1"
        let days = Int(daysStr) ?? 1
        let minDurationStr = req.queryParam("min_duration") ?? "30"
        let minDuration = TimeInterval((Int(minDurationStr) ?? 30) * 60)

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let slots = await CalendarManager.shared.findFreeSlots(from: now, to: end, minDuration: minDuration)
        return HTTPResponse.json(["free_slots": slots, "count": slots.count, "days": days])
    }

    private func handleCalendarCreate(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let title = body["title"] as? String,
              let startStr = body["start"] as? String else {
            return HTTPResponse.badRequest("Missing 'title' and 'start' (ISO 8601)")
        }

        let df = ISO8601DateFormatter()
        guard let startDate = df.date(from: startStr) else {
            return HTTPResponse.badRequest("Invalid 'start' date format (use ISO 8601)")
        }

        let endDate: Date
        if let endStr = body["end"] as? String, let end = df.date(from: endStr) {
            endDate = end
        } else {
            let durationMin = body["duration_minutes"] as? Int ?? 60
            endDate = startDate.addingTimeInterval(TimeInterval(durationMin * 60))
        }

        let location = body["location"] as? String
        let notes = body["notes"] as? String
        let calendarName = body["calendar"] as? String
        let isAllDay = body["is_all_day"] as? Bool ?? false

        let result = await CalendarManager.shared.createEvent(
            title: title, startDate: startDate, endDate: endDate,
            location: location, notes: notes, calendarName: calendarName, isAllDay: isAllDay
        )

        if result.success {
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"],
                body: Data("{\"success\":true,\"id\":\"\(result.id ?? "")\"}".utf8))
        } else {
            return HTTPResponse.badRequest(result.error ?? "Failed to create event")
        }
    }

    // MARK: - Workflow Handlers

    private func handleWorkflowCreate(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody else {
            return HTTPResponse.badRequest("Missing request body")
        }

        // Option 1: Natural language description → auto-decompose
        if let description = body["description"] as? String {
            let createdBy = body["created_by"] as? String ?? "user"
            let priorityRaw = body["priority"] as? Int ?? 1
            let priority = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal
            let workflow = await WorkflowEngine.shared.createWorkflow(
                description: description, createdBy: createdBy, priority: priority
            )
            guard let status = await WorkflowEngine.shared.workflowStatus(workflow.id) else {
                return HTTPResponse.json(["id": workflow.id, "name": workflow.name, "status": workflow.status.rawValue])
            }
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"],
                                body: (try? JSONSerialization.data(withJSONObject: status)) ?? Data())
        }

        // Option 2: Pre-defined steps
        if let stepsArray = body["steps"] as? [[String: Any]], let name = body["name"] as? String {
            let description = body["description_text"] as? String ?? name
            let createdBy = body["created_by"] as? String ?? "user"
            let priorityRaw = body["priority"] as? Int ?? 1
            let priority = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal

            let steps = stepsArray.enumerated().map { idx, step in
                WorkflowStep(
                    index: idx,
                    title: step["title"] as? String ?? "Step \(idx + 1)",
                    description: step["description"] as? String ?? "",
                    assignedTo: step["assigned_to"] as? String ?? "sid",
                    dependsOnSteps: step["depends_on"] as? [Int] ?? (idx > 0 ? [idx - 1] : [])
                )
            }

            let workflow = await WorkflowEngine.shared.createWorkflowFromSteps(
                steps, name: name, description: description, createdBy: createdBy, priority: priority
            )
            guard let status = await WorkflowEngine.shared.workflowStatus(workflow.id) else {
                return HTTPResponse.json(["id": workflow.id, "name": workflow.name])
            }
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"],
                                body: (try? JSONSerialization.data(withJSONObject: status)) ?? Data())
        }

        return HTTPResponse.badRequest("Provide 'description' (auto-decompose) or 'name' + 'steps' (manual)")
    }

    private func handleWorkflowList(_ req: HTTPRequest) async -> HTTPResponse {
        let statusFilter = req.queryParam("status")
        let status: Workflow.WorkflowStatus? = statusFilter.flatMap { Workflow.WorkflowStatus(rawValue: $0) }
        let workflows = await WorkflowEngine.shared.listWorkflows(status: status)
        let items: [[String: Any]] = workflows.map { wf in
            [
                "id": wf.id,
                "name": wf.name,
                "status": wf.status.rawValue,
                "steps": wf.steps.count,
                "tasks": wf.taskIDs.count,
                "created_by": wf.createdBy,
                "result": wf.result ?? "",
                "error": wf.error ?? ""
            ]
        }
        return HTTPResponse.json(["workflows": items, "count": items.count])
    }

    private func handleWorkflowStatus(_ workflowID: String) async -> HTTPResponse {
        guard let status = await WorkflowEngine.shared.workflowStatus(workflowID) else {
            return HTTPResponse.notFound()
        }
        let data = (try? JSONSerialization.data(withJSONObject: status)) ?? Data()
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    private func handleSetLevel(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        guard let body = req.jsonBody, let rawLevel = body["level"] as? Int,
              let level = AccessLevel(rawValue: rawLevel) else {
            return HTTPResponse.badRequest("Missing or invalid 'level' (0-5)")
        }
        let state = appState
        await MainActor.run { state?.accessLevel = level }
        await audit(clientIP: clientIP, method: "POST", path: "/control/level",
                   required: .chatOnly, granted: true, detail: "Level → \(level.rawValue) (\(level.name))")
        Task { await TelegramBridge.shared.notify("Access level changed to \(level.rawValue) (\(level.name))") }
        return HTTPResponse.json(["status": "ok", "level": level.rawValue, "name": level.name])
    }

    /// Simulate a streaming SSE response from a complete text string.
    /// Used for room requests where tool execution requires non-streaming,
    /// but the iOS client expects SSE format.
    private func simulateStreamResponse(_ text: String, model: String, writer: ResponseWriter) {
        writer.sendStreamHeaders()

        // Build an OpenAI-compatible streaming chunk with the full text
        let chunkID = "chatcmpl-room-\(UUID().uuidString.prefix(8))"
        let chunk: [String: Any] = [
            "id": chunkID,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "delta": ["content": text],
                "finish_reason": NSNull()
            ] as [String: Any]]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: chunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            writer.sendSSEChunk(jsonStr)
        }

        // Send finish chunk
        let finishChunk: [String: Any] = [
            "id": chunkID,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "delta": [:] as [String: String],
                "finish_reason": "stop"
            ] as [String: Any]]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: finishChunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            writer.sendSSEChunk(jsonStr)
        }

        writer.sendSSEDone()
    }

    /// Read error body from a failed streaming response and return a descriptive message
    private func drainErrorBody(bytes: URLSession.AsyncBytes, provider: String, code: Int) async -> String {
        var errorBody = ""
        do {
            for try await byte in bytes {
                errorBody.append(Character(UnicodeScalar(byte)))
                if errorBody.count > 2048 { break } // Don't read endlessly
            }
        } catch { /* ignore read errors */ }

        // Try to extract a meaningful message from JSON error body
        if let data = errorBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return "\(provider) (\(code)): \(message)"
            }
            if let error = json["error"] as? String {
                return "\(provider) (\(code)): \(error)"
            }
            if let message = json["message"] as? String {
                return "\(provider) (\(code)): \(message)"
            }
        }
        let preview = String(errorBody.prefix(200))
        return "\(provider) returned \(code)\(preview.isEmpty ? "" : ": \(preview)")"
    }

}

// MARK: - Access Control

enum AccessControl {
    static let blockedPatterns: [String] = [
        "rm -rf /", "rm -rf ~", "rm -rf $HOME",
        "sudo ", "su -", "su root",
        "chmod 777", "chmod -R 777",
        "kill -9", "killall", "pkill",
        "launchctl", "systemsetup", "networksetup",
        "defaults write", "defaults delete",
        "curl|sh", "curl | sh", "wget|sh", "wget | sh",
        ":(){ :|:& };:",
        "mkfs", "fdisk", "diskutil erase",
        "dd if=", ">/dev/sd", ">/dev/disk",
        "ssh-keygen", "ssh-add",
        "security delete", "security unlock",
        "open /System", "open -a Terminal",
    ]

    static func isPathAllowed(_ path: String, for level: AccessLevel) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = (path as NSString).standardizingPath
        let forbidden = ["/etc", "/usr", "/System", "/Library",
                         home + "/.ssh", home + "/.gnupg",
                         home + "/Library/Keychains"]
        for f in forbidden { if resolved.hasPrefix(f) { return false } }
        let allowed = AppConfig.sandboxPaths.map { ($0 as NSString).expandingTildeInPath }
        for a in allowed { if resolved.hasPrefix(a) { return true } }
        if level == .fullAccess { return true }
        return false
    }

    static func filterCommand(_ command: String) -> String? {
        let lower = command.lowercased()
        for pattern in blockedPatterns {
            if lower.contains(pattern.lowercased()) {
                return "Blocked: matches dangerous pattern '\(pattern)'"
            }
        }
        if lower.contains("$(") || lower.contains("`") {
            if lower.contains("rm") || lower.contains("sudo") || lower.contains("kill") {
                return "Blocked: suspicious command substitution"
            }
        }
        return nil
    }
}

// MARK: - HTTP Types

struct HTTPRequest {
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data?

    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    func queryParam(_ key: String) -> String? {
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == key { return kv[1].removingPercentEncoding }
        }
        return nil
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard !parts.isEmpty else { return nil }
        let headerLines = parts[0].components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let rp = requestLine.components(separatedBy: " ")
        guard rp.count >= 2 else { return nil }
        let fullPath = rp[1]
        let pathParts = fullPath.components(separatedBy: "?")
        let path = pathParts[0]
        let query = pathParts.count > 1 ? pathParts[1] : ""
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        let bodyStr = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : nil
        return HTTPRequest(method: rp[0], path: path, query: query, headers: headers,
                          body: bodyStr?.isEmpty == false ? bodyStr?.data(using: .utf8) : nil)
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func serialize() -> Data {
        let statusText: String = {
            switch statusCode {
            case 200: return "OK"; case 204: return "No Content"
            case 400: return "Bad Request"; case 401: return "Unauthorized"
            case 403: return "Forbidden"; case 404: return "Not Found"
            case 429: return "Too Many Requests"
            case 500: return "Internal Server Error"; default: return "Unknown"
            }
        }()
        var resp = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "close"
        h["Access-Control-Allow-Origin"] = h["Access-Control-Allow-Origin"] ?? "*"
        for (k, v) in h { resp += "\(k): \(v)\r\n" }
        resp += "\r\n"
        var data = Data(resp.utf8)
        data.append(body)
        return data
    }

    static func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
    static func badRequest(_ msg: String) -> HTTPResponse {
        HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"\(msg)\"}".utf8))
    }
    static func unauthorized() -> HTTPResponse {
        HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Unauthorized\"}".utf8))
    }
    static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Not found\"}".utf8))
    }
    static func serverError(_ msg: String) -> HTTPResponse {
        HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"\(msg)\"}".utf8))
    }
    static func cors() -> HTTPResponse {
        HTTPResponse(statusCode: 204, headers: [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
            "Access-Control-Max-Age": "86400"
        ], body: Data())
    }
}
