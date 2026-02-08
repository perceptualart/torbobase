// ORB Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
import Foundation
import Network

// MARK: - Gateway Server

actor GatewayServer {
    static let shared = GatewayServer()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private weak var appState: AppState?
    private let ollamaURL = "http://127.0.0.1:11434"
    private var requestLog: [String: [Date]] = [:]

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

            // Start Telegram polling if configured
            Task {
                await TelegramBridge.shared.startPolling()
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

    /// Check if we've received the full HTTP request (headers + body based on Content-Length)
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

    private func processRequest(_ data: Data, on conn: NWConnection) async {
        guard let request = HTTPRequest.parse(data) else {
            send(HTTPResponse.badRequest("Malformed request"), on: conn)
            return
        }
        let clientIP = conn.endpoint.debugDescription
        if let response = await route(request, clientIP: clientIP, conn: conn) {
            send(response, on: conn)
        }
        // If nil, response was already streamed directly to conn
    }

    private func route(_ req: HTTPRequest, clientIP: String, conn: NWConnection? = nil) async -> HTTPResponse? {
        // CORS preflight
        if req.method == "OPTIONS" { return HTTPResponse.cors() }

        // Health check
        if req.method == "GET" && (req.path == "/" || req.path == "/health") {
            return HTTPResponse.json([
                "status": "ok",
                "service": "orb-base",
                "version": ORBVersion.current
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

        let currentLevel = await MainActor.run { stateRef?.accessLevel ?? .off }

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
            if let body = req.jsonBody, body["stream"] as? Bool == true, let conn {
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
                await streamChatCompletion(req, clientIP: clientIP, conn: conn)
                return nil // Already streamed
            }
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.proxyChatCompletion(req, clientIP: clientIP)
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

        default:
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

    private func streamChatCompletion(_ req: HTTPRequest, clientIP: String, conn: NWConnection) async {
        guard var body = req.jsonBody else {
            send(.badRequest("Invalid JSON body"), on: conn); return
        }
        let model = (body["model"] as? String) ?? "qwen2.5:7b"
        if body["model"] == nil { body["model"] = model }

        await injectSystemPrompt(into: &body)
        await MemoryRouter.shared.enrichRequest(&body)
        body["stream"] = true

        // Log user message (handles both string and array/vision content)
        if let messages = body["messages"] as? [[String: Any]],
           let last = messages.last(where: { $0["role"] as? String == "user" }),
           let content = extractTextContent(from: last["content"]) {
            let userMsg = ConversationMessage(role: "user", content: content, model: model, clientIP: clientIP)
            let s = appState
            await MainActor.run { s?.addMessage(userMsg) }
        }

        // Route cloud models through their streaming APIs
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") {
            await streamCloudCompletion(body: body, model: model, clientIP: clientIP, conn: conn)
            return
        }

        // Stream from Ollama
        guard let url = URL(string: "\(ollamaURL)/v1/chat/completions") else {
            send(.serverError("Bad Ollama URL"), on: conn); return
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 300
        do { urlReq.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { send(.badRequest("JSON encode error"), on: conn); return }

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            if httpResp?.statusCode != 200 {
                let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Ollama", code: httpResp?.statusCode ?? 500)
                send(.serverError(errMsg), on: conn); return
            }

            sendStreamHeaders(on: conn)

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
                    sendSSEChunk(jsonStr, on: conn)

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

            sendSSEDone(on: conn)

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
            send(.serverError("Streaming error: \(error.localizedDescription)"), on: conn)
        }
    }

    // MARK: - Cloud Streaming

    private func streamCloudCompletion(body: [String: Any], model: String, clientIP: String, conn: NWConnection) async {
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }
        var fullContent = ""

        if model.hasPrefix("gpt") {
            // OpenAI native SSE — forward directly
            guard let apiKey = keys["OPENAI_API_KEY"], !apiKey.isEmpty else {
                send(.serverError("No OpenAI API key configured"), on: conn); return
            }
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                send(.serverError("Bad URL"), on: conn); return
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
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: "OpenAI", code: httpResp?.statusCode ?? 500)
                    send(.serverError(errMsg), on: conn); return
                }
                sendStreamHeaders(on: conn)
                var buffer = ""
                for try await byte in bytes {
                    let char = Character(UnicodeScalar(byte))
                    if char == "\n" {
                        let line = buffer.trimmingCharacters(in: .whitespaces)
                        buffer = ""
                        guard !line.isEmpty else { continue }
                        let jsonStr = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
                        if jsonStr == "[DONE]" { break }
                        sendSSEChunk(jsonStr, on: conn)
                        if let data = jsonStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullContent += content
                        }
                    } else { buffer.append(char) }
                }
                sendSSEDone(on: conn)
            } catch {
                send(.serverError("OpenAI stream error: \(error.localizedDescription)"), on: conn); return
            }

        } else if model.hasPrefix("claude") {
            // Anthropic SSE
            guard let apiKey = keys["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
                send(.serverError("No Anthropic API key configured"), on: conn); return
            }
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                send(.serverError("Bad URL"), on: conn); return
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
                    send(.serverError(errMsg), on: conn); return
                }
                sendStreamHeaders(on: conn)
                var buffer = ""
                let completionId = "chatcmpl-orb-\(UUID().uuidString.prefix(8))"
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
                                    sendSSEChunk(chunkStr, on: conn)
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
                                    sendSSEChunk(chunkStr, on: conn)
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
                                sendSSEChunk(chunkStr, on: conn)
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
                                    sendSSEChunk(chunkStr, on: conn)
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
                                    sendSSEChunk(chunkStr, on: conn)
                                }
                            }
                        }
                    } else { buffer.append(char) }
                }
                sendSSEDone(on: conn)
            } catch {
                send(.serverError("Anthropic stream error: \(error.localizedDescription)"), on: conn); return
            }

        } else if model.hasPrefix("gemini") {
            // Gemini SSE via streamGenerateContent
            guard let apiKey = keys["GOOGLE_API_KEY"], !apiKey.isEmpty else {
                send(.serverError("No Google API key configured"), on: conn); return
            }
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
            guard let url = URL(string: urlStr) else {
                send(.serverError("Bad Gemini URL"), on: conn); return
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
                    send(.serverError(errMsg), on: conn); return
                }
                sendStreamHeaders(on: conn)
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
                                sendSSEChunk(chunkStr, on: conn)
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
                    sendSSEChunk(chunkStr, on: conn)
                }
                sendSSEDone(on: conn)
            } catch {
                send(.serverError("Gemini stream error: \(error.localizedDescription)"), on: conn); return
            }
        } else {
            // Unknown cloud model — fall back to non-streaming
            var nonStreamBody = body
            nonStreamBody["stream"] = false
            let response = await routeToCloud(body: nonStreamBody, model: model, clientIP: clientIP)
            send(response, on: conn); return
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

    private func proxyChatCompletion(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        guard var body = req.jsonBody else {
            return HTTPResponse.badRequest("Invalid JSON body")
        }
        let model = (body["model"] as? String) ?? "qwen2.5:7b"
        if body["model"] == nil { body["model"] = model }

        // Inject system prompt if configured
        await injectSystemPrompt(into: &body)
        await MemoryRouter.shared.enrichRequest(&body)

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
                return ToolProcessor.builtInToolNames.contains(name)
            }
            let clientCalls = toolCalls.filter {
                let name = ($0["function"] as? [String: Any])?["name"] as? String ?? ""
                return !ToolProcessor.builtInToolNames.contains(name)
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
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") {
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
                    "id": json["id"] ?? "chatcmpl-orb",
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
            "version": ORBVersion.current,
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

    private nonisolated func send(_ response: HTTPResponse, on conn: NWConnection) {
        let data = response.serialize()
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Send HTTP headers for a streaming (SSE) response, keeping the connection open
    private nonisolated func sendStreamHeaders(on conn: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
    }

    /// Send a single SSE chunk
    private nonisolated func sendSSEChunk(_ data: String, on conn: NWConnection) {
        let chunk = "data: \(data)\n\n"
        conn.send(content: Data(chunk.utf8), completion: .contentProcessed { _ in })
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

    /// Send the final SSE done marker and close
    private nonisolated func sendSSEDone(on conn: NWConnection) {
        let done = "data: [DONE]\n\n"
        conn.send(content: Data(done.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
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
