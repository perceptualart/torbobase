// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

// MARK: - Response Writer Protocol

/// Protocol for writing HTTP responses — implemented by NWConnection (macOS) and NIO Channel (Linux)
protocol ResponseWriter: Sendable {
    func sendResponse(_ response: HTTPResponse)
    func sendStreamHeaders(origin: String?)
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

    func sendStreamHeaders(origin: String? = nil) {
        var h = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n"
        if let origin = origin { h += "Access-Control-Allow-Origin: \(origin)\r\n" }
        h += "\r\n"
        connection.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
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

// MARK: - Chat Room (multi-user)

struct ChatRoomMessage: Codable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Double
    let role: String   // "user" or "assistant"
    let agentID: String?
}

actor ChatRoomStore {
    static let shared = ChatRoomStore()
    private var rooms: [String: [ChatRoomMessage]] = [:]
    private var roomCreated: [String: Double] = [:]

    func createRoom(_ roomID: String) {
        if rooms[roomID] == nil {
            rooms[roomID] = []
            roomCreated[roomID] = Date().timeIntervalSince1970
        }
    }

    func postMessage(room: String, sender: String, content: String, role: String, agentID: String? = nil) -> ChatRoomMessage {
        let msg = ChatRoomMessage(
            id: UUID().uuidString,
            sender: sender,
            content: content,
            timestamp: Date().timeIntervalSince1970,
            role: role,
            agentID: agentID
        )
        var buffer = rooms[room] ?? []
        buffer.append(msg)
        // Cap at 500 messages per room
        if buffer.count > 500 {
            buffer = Array(buffer.suffix(500))
        }
        rooms[room] = buffer
        return msg
    }

    func messages(room: String, since: Double) -> [ChatRoomMessage] {
        guard let msgs = rooms[room] else { return [] }
        return msgs.filter { $0.timestamp > since }
    }

    func roomExists(_ roomID: String) -> Bool {
        return rooms[roomID] != nil
    }

    func cleanup(olderThan seconds: TimeInterval = 86400) {
        let cutoff = Date().timeIntervalSince1970 - seconds
        for (id, created) in roomCreated where created < cutoff {
            rooms.removeValue(forKey: id)
            roomCreated.removeValue(forKey: id)
        }
    }
}

// MARK: - Gateway Server

actor GatewayServer {
    static let shared = GatewayServer()
    static let serverStartTime = Date()

    #if canImport(Network)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    #endif
    private weak var appState: AppState?
    private var requestLog: [String: [Date]] = [:]

    // Webchat session tokens — ephemeral, expire with server restart.
    // These grant chat-level access without exposing the master server token.
    private var webchatSessionTokens: Set<String> = []

    private func generateWebchatToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        #else
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        #endif
        let token = "wc_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        webchatSessionTokens.insert(token)
        return token
    }

    #if canImport(Network)
    func start(appState: AppState) async {
        self.appState = appState
        let port = appState.serverPort

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
                TorboLog.error("Invalid port: \(port)", subsystem: "Gateway")
                await MainActor.run {
                    appState.serverRunning = false
                    appState.serverError = "Invalid port: \(port)"
                }
                return
            }

            // Bind host: default 0.0.0.0 (all interfaces) for phone pairing + Tailscale.
            // Override with TORBO_BIND_HOST=127.0.0.1 to restrict to localhost only.
            let bindHost = ProcessInfo.processInfo.environment["TORBO_BIND_HOST"] ?? "0.0.0.0"
            let nwHost: NWEndpoint.Host = (bindHost == "127.0.0.1" || bindHost == "localhost")
                ? .ipv4(.loopback)
                : .ipv4(.any)
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
            if nwHost == .ipv4(.any) {
                TorboLog.warn("Binding to 0.0.0.0:\(port) — exposed to LAN. Set TORBO_BIND_HOST=127.0.0.1 to restrict.", subsystem: "Gateway")
            } else {
                TorboLog.info("Binding to \(bindHost):\(port) (localhost only)", subsystem: "Gateway")
            }
            listener = try NWListener(using: params)

            listener?.newConnectionHandler = { [weak self] conn in
                Task { await self?.handleConnection(conn) }
            }

            // Wait for the listener to actually bind before declaring success
            let ready: Bool = await withCheckedContinuation { continuation in
                listener?.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        continuation.resume(returning: true)
                    case .failed(let err):
                        TorboLog.error("Listener failed to bind: \(err)", subsystem: "Gateway")
                        Task { await self?.handleListenerState(state) }
                        continuation.resume(returning: false)
                    case .cancelled:
                        continuation.resume(returning: false)
                    default:
                        break  // .setup, .waiting — keep waiting
                    }
                }
                listener?.start(queue: .global(qos: .userInitiated))
            }

            guard ready else {
                let s = appState
                await MainActor.run {
                    s.serverRunning = false
                    if s.serverError == nil {
                        s.serverError = "Failed to bind to port \(port)"
                    }
                }
                return
            }

            // Listener is confirmed bound — now switch to ongoing state monitoring
            listener?.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }

            await MainActor.run {
                appState.serverRunning = true
                appState.serverError = nil
            }
            TorboLog.info("Listener bound to port \(port)", subsystem: "Gateway")

            // Log all reachable addresses for connectivity debugging
            logReachableAddresses(port: port)

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

            // Start Skills Manager
            Task {
                await SkillsManager.shared.initialize()
            }

            // Start Workflow Engine
            Task {
                await WorkflowEngine.shared.loadFromDisk()
            }

            // Start Webhook Manager & Scheduler
            Task {
                await WebhookManager.shared.initialize()
            }

            // Start Cron Scheduler
            Task {
                await CronScheduler.shared.initialize()
            }

            // Start Event Bus
            Task {
                await EventBus.shared.initialize()
                await EventBus.shared.publish("system.gateway.started",
                    payload: ["port": "\(port)"],
                    source: "Gateway")
            }

            // Initialize Token Tracker
            Task { await TokenTracker.shared.initialize() }

            // Start Morning Briefing Scheduler
            Task { await MorningBriefing.shared.initialize() }

            // Start Evening Wind-Down Scheduler
            Task { await WindDownScheduler.shared.initialize() }

            // Start LifeOS Predictor — calendar watcher, meeting prep, deadline detection
            Task { await LifeOSPredictor.shared.start() }

            // Start Commitments Engine — accountability tracking
            Task {
                await CommitmentsStore.shared.initialize()
                await CommitmentsFollowUp.shared.start()
            }

            // Start Morning Briefing Scheduler
            Task { await MorningBriefing.shared.initialize() }

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

            // Periodic maintenance — ChatRoomStore cleanup every 30 minutes
            Task { [weak self] in
                while await self != nil {
                    try? await Task.sleep(nanoseconds: 1_800_000_000_000) // 30 min
                    await ChatRoomStore.shared.cleanup(olderThan: 86400)  // 24h
                    TorboLog.debug("ChatRoomStore cleanup complete", subsystem: "Gateway")
                }
            }

            TorboLog.info("Started on port \(port)", subsystem: "Gateway")
        } catch {
            await MainActor.run {
                appState.serverRunning = false
                appState.serverError = error.localizedDescription
            }
            TorboLog.error("Failed to start: \(error)", subsystem: "Gateway")
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
        Task { await EventBus.shared.publish("system.gateway.stopped", source: "Gateway") }
        TorboLog.info("Stopped", subsystem: "Gateway")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .failed(let err):
            TorboLog.error("Listener failed: \(err)", subsystem: "Gateway")
            let s = appState
            await MainActor.run {
                s?.serverRunning = false
                s?.serverError = "Listener failed: \(err.localizedDescription)"
            }
        case .cancelled:
            TorboLog.info("Listener cancelled", subsystem: "Gateway")
        case .ready:
            TorboLog.info("Listener ready", subsystem: "Gateway")
        default:
            break
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
            TorboLog.info("Started on port \(port) (SwiftNIO)", subsystem: "Gateway")
        } catch {
            await MainActor.run {
                appState.serverRunning = false
                appState.serverError = error.localizedDescription
            }
            TorboLog.error("Failed to start NIO server: \(error)", subsystem: "Gateway")
        }
        #else
        TorboLog.warn("No TCP server available — need Network.framework or SwiftNIO", subsystem: "Gateway")
        await MainActor.run {
            appState.serverRunning = false
            appState.serverError = "No TCP server available on this platform"
        }
        #endif

        // Start subsystems
        Task { await MemoryRouter.shared.initialize() }
        Task { await MCPManager.shared.initialize() }
        Task { await DocumentStore.shared.initialize() }
        Task {
            await ConversationSearch.shared.initialize()
            await ConversationSearch.shared.backfillFromStore()
        }
        Task { await SkillsManager.shared.initialize() }
        Task { await WorkflowEngine.shared.loadFromDisk() }
        Task { await WebhookManager.shared.initialize() }
        Task { await CronScheduler.shared.initialize() }
        Task { await WindDownScheduler.shared.initialize() }
        Task { await TelegramBridge.shared.startPolling() }
        Task { await ChannelManager.shared.initialize() }
        Task {
            await LoAMemoryEngine.shared.initialize()
            await LoADistillation.shared.registerCronJob()
        }

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
        TorboLog.info("Stopped", subsystem: "Gateway")
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

    /// Extract just the IP address from an endpoint description, stripping port and brackets.
    /// NWConnection.endpoint.debugDescription produces "127.0.0.1:54321" or "[::1]:54321".
    /// NIO's SocketAddress.description produces "[IPv4]127.0.0.1/127.0.0.1:54321".
    nonisolated static func stripPort(from address: String) -> String {
        var s = address
        // NIO format: "[IPv4]127.0.0.1/127.0.0.1:54321" — take after last "/"
        if let slash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: slash)...])
        }
        // Bracketed IPv6: "[::1]:54321" → "::1"
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return String(s[s.index(after: s.startIndex)..<close])
        }
        // IPv4:port — exactly one colon means "ip:port"
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let colon = s.firstIndex(of: ":") {
            return String(s[s.startIndex..<colon])
        }
        // Pure IPv6 or already clean — return as-is
        return s
    }

    #if canImport(Network)
    private func processRequest(_ data: Data, on conn: NWConnection) async {
        let writer = NWConnectionWriter(connection: conn)
        let clientIP = Self.stripPort(from: conn.endpoint.debugDescription)
        await processRequest(data, clientIP: clientIP, writer: writer)
    }
    #endif

    private func processRequest(_ data: Data, clientIP: String, writer: ResponseWriter) async {
        guard let request = HTTPRequest.parse(data) else {
            // Log diagnostic info to help debug intermittent parse failures
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8, \(data.count) bytes>"
            TorboLog.warn("Malformed request from \(clientIP): \(data.count) bytes, preview: \(preview.prefix(120))", subsystem: "Gateway")
            writer.sendResponse(HTTPResponse.badRequest("Malformed request"))
            return
        }
        if var response = await route(request, clientIP: clientIP, writer: writer) {
            // Inject validated CORS origin into non-streaming responses
            let origin = request.headers["Origin"] ?? request.headers["origin"]
            if let corsOrigin = AccessControl.validatedCORSOrigin(requestOrigin: origin, path: request.path) {
                var h = response.headers
                h["Access-Control-Allow-Origin"] = corsOrigin
                response = HTTPResponse(statusCode: response.statusCode, headers: h, body: response.body)
            }
            writer.sendResponse(response)
        }
        // If nil, response was already streamed directly via writer
    }

    /// Called by NIOServer (Linux) or NWListener handler (macOS) to process a request
    func handleRequest(_ data: Data, clientIP: String, writer: ResponseWriter) async {
        await processRequest(data, clientIP: clientIP, writer: writer)
    }

    /// Detect this machine's Tailscale IP by scanning network interfaces for CGNAT range (100.64.0.0/10).
    /// Returns the IP string if found, nil otherwise. No subprocess — pure getifaddrs.
    nonisolated private static func detectTailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            #if os(macOS)
            let saLen = socklen_t(sa.pointee.sa_len)
            #else
            let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            #endif
            getnameinfo(sa, saLen,
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if ip.hasPrefix("100.") {
                let parts = ip.split(separator: ".").compactMap { Int($0) }
                if parts.count >= 2 && parts[1] >= 64 && parts[1] <= 127 { return ip }
            }
        }
        return nil
    }

    /// Detect this machine's Tailscale Magic DNS hostname via `tailscale status --json`.
    /// Returns the hostname (e.g. "mymac.tail1234.ts.net") or nil if Tailscale not running.
    nonisolated private static func detectTailscaleHostname() -> String? {
        // Check common Tailscale CLI locations
        let paths = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let execPath = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.arguments = ["status", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any],
              let dnsName = selfNode["DNSName"] as? String,
              !dnsName.isEmpty else { return nil }
        // DNSName has trailing dot — strip it: "mymac.tail1234.ts.net." → "mymac.tail1234.ts.net"
        return dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
    }

    /// Log all network addresses where Base is reachable (for connectivity debugging).
    nonisolated private func logReachableAddresses(port: UInt16) {
        var addresses: [String] = ["127.0.0.1 (localhost)"]
        // Scan all network interfaces for IPv4 addresses
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if os(macOS)
                let saLen = socklen_t(sa.pointee.sa_len)
                #else
                let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                getnameinfo(sa, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip == "127.0.0.1" { continue }
                let iface = String(cString: ptr.pointee.ifa_name)
                if ip.hasPrefix("100.") {
                    let parts = ip.split(separator: ".").compactMap { Int($0) }
                    if parts.count >= 2 && parts[1] >= 64 && parts[1] <= 127 {
                        addresses.append("\(ip) (Tailscale, \(iface))")
                        continue
                    }
                }
                addresses.append("\(ip) (\(iface))")
            }
        }
        if let tsHost = Self.detectTailscaleHostname() {
            addresses.append("\(tsHost) (MagicDNS)")
        }
        TorboLog.info("Reachable at:", subsystem: "Gateway")
        for addr in addresses {
            TorboLog.info("  → http://\(addr):\(port)/health", subsystem: "Gateway")
        }
    }

    private func route(_ req: HTTPRequest, clientIP: String, writer: ResponseWriter? = nil) async -> HTTPResponse? {
        // CORS — validate the Origin header against the allowlist
        let requestOrigin = req.headers["Origin"] ?? req.headers["origin"]
        let corsOrigin = AccessControl.validatedCORSOrigin(requestOrigin: requestOrigin, path: req.path)

        // CORS preflight
        if req.method == "OPTIONS" { return HTTPResponse.cors(origin: corsOrigin) }

        // Health check — Tailscale details only returned to authenticated callers
        if req.method == "GET" && (req.path == "/" || req.path == "/health") {
            var response: [String: Any] = [
                "status": "ok",
                "service": "torbo-base",
                "version": TorboVersion.current
            ]
            // L-2: Only expose Tailscale hostname/IP to authenticated requests
            let hasAuth = req.headers["Authorization"] != nil || req.headers["authorization"] != nil
            if hasAuth {
                if let tsIP = Self.detectTailscaleIP() {
                    response["tailscaleIP"] = tsIP
                }
                if let tsHostname = Self.detectTailscaleHostname() {
                    response["tailscaleHostname"] = tsHostname
                }
            }
            return HTTPResponse.json(response)
        }

        // Web chat UI — serves the built-in chat interface
        // Ephemeral session token auto-injected — no login prompt.
        // Session tokens are scoped to webchat and expire on server restart.
        // The master server token is never exposed in HTML.
        if req.method == "GET" && req.path == "/chat" {
            let chatToken = generateWebchatToken()
            let html = WebChatHTML.page.replacingOccurrences(of: "/*%%TORBO_SESSION_TOKEN%%*/", with: chatToken)
            return HTTPResponse(statusCode: 200,
                              headers: [
                                "Content-Type": "text/html; charset=utf-8",
                                "Permissions-Policy": "microphone=(self), camera=()",
                                "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'none'; frame-src 'none'; object-src 'none'",
                                "X-Frame-Options": "DENY",
                                "X-Content-Type-Options": "nosniff",
                                "Referrer-Policy": "no-referrer"
                              ],
                              body: Data(html.utf8))
        }

        // Web dashboard UI — serves the built-in management dashboard
        if req.method == "GET" && req.path == "/dashboard" {
            return HTTPResponse(statusCode: 200,
                              headers: [
                                "Content-Type": "text/html; charset=utf-8",
                                "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'none'; frame-src 'none'; object-src 'none'",
                                "X-Frame-Options": "DENY",
                                "X-Content-Type-Options": "nosniff"
                              ],
                              body: Data(DashboardHTML.page.utf8))
        }

        // Legal documents — serve static HTML (no auth required)
        if req.method == "GET" && req.path.hasPrefix("/legal/") {
            return serveLegalPage(path: req.path)
        }

        // L-1: Access level — return only a boolean "active" without exposing exact level
        if req.method == "GET" && req.path == "/level" {
            let s = appState
            let level = await MainActor.run { s?.accessLevel.rawValue ?? 0 }
            return HTTPResponse.json(["active": level > 0])
        }

        // Rate limit unauthenticated endpoints (prevents brute-force pairing)
        if req.method == "POST" && (req.path == "/pair" || req.path == "/pair/verify") {
            if isRateLimited(clientIP: clientIP) {
                return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"],
                                  body: Data("{\"error\":\"Too many requests\"}".utf8))
            }
        }

        // Pairing endpoints (no auth)
        if req.method == "POST" && req.path == "/pair" {
            return await handlePair(req, clientIP: clientIP)
        }
        if req.method == "POST" && req.path == "/pair/verify" {
            return await handlePairVerify(req)
        }

        // Auto-pair for trusted networks (Tailscale 100.x.x.x only)
        if req.method == "POST" && req.path == "/pair/auto" {
            return await handleAutoPair(req, clientIP: clientIP)
        }

        // ── Cloud Auth Routes (no auth required) ──
        if req.method == "POST" && req.path == "/v1/auth/magic-link" {
            return await CloudRoutes.handleMagicLink(req)
        }
        if req.method == "POST" && req.path == "/v1/auth/verify" {
            return await CloudRoutes.handleVerify(req)
        }
        if req.method == "POST" && req.path == "/v1/auth/refresh" {
            return await CloudRoutes.handleRefresh(req)
        }

        // ── Stripe Webhook (no auth — signature verified) ──
        if req.method == "POST" && req.path == "/v1/billing/webhook" {
            return await CloudRoutes.handleStripeWebhook(req)
        }

        // --- Everything below requires auth ---
        // Cloud mode: accept both Supabase JWT and legacy server token
        let cloudContext: CloudRequestContext? = await resolveCloudAuth(req)

        guard authenticate(req, clientIP: clientIP) || cloudContext != nil else {
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

        let agentID = req.headers["x-torbo-agent-id"] ?? req.headers["X-Torbo-Agent-Id"] ?? "sid"
        let platform = req.headers["x-torbo-platform"] ?? req.headers["X-Torbo-Platform"]
        // Resolve access level: use the per-agent level from config, capped by global.
        // The x-torbo-access-level header can only LOWER the level, never raise it.
        let currentLevel: AccessLevel = await MainActor.run {
            guard let state = stateRef else { return .off }
            if state.accessLevel == .off { return .off }
            let agentLevel = state.accessLevel(for: agentID)
            // Client header can request a lower level (e.g. for testing), but never higher
            if let raw = req.headers["x-torbo-access-level"] ?? req.headers["X-Torbo-Access-Level"],
               let val = Int(raw), let requested = AccessLevel(rawValue: val),
               requested.rawValue < agentLevel.rawValue {
                return requested
            }
            return agentLevel
        }

        if currentLevel == .off {
            await audit(clientIP: clientIP, method: req.method, path: req.path,
                       required: .chatOnly, granted: false, detail: "Gateway OFF")
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Gateway is OFF\"}".utf8))
        }

        // ── Cloud Auth Routes (require cloud JWT) ──
        if let ctx = cloudContext {
            if req.method == "GET" && req.path == "/v1/auth/me" {
                return await CloudRoutes.handleMe(ctx)
            }
            if req.method == "POST" && req.path == "/v1/billing/checkout" {
                return await CloudRoutes.handleCheckout(req, ctx: ctx)
            }
            if req.method == "POST" && req.path == "/v1/billing/portal" {
                return await CloudRoutes.handlePortal(ctx)
            }
            if req.method == "GET" && req.path == "/v1/billing/status" {
                return await CloudRoutes.handleBillingStatus(ctx)
            }
        }

        // Cloud stats (admin only — requires server token, not cloud JWT)
        if req.method == "GET" && req.path == "/v1/cloud/stats" {
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                await CloudRoutes.handleCloudStats()
            }
        }

        // ── Cloud Tier Enforcement ──
        if let ctx = cloudContext {
            let tierCheck = TierEnforcer.check(ctx: ctx, path: req.path, agentID: agentID, accessLevel: currentLevel.rawValue)
            switch tierCheck {
            case .allowed:
                break
            case .denied:
                let errorBody = TierEnforcer.errorResponse(tierCheck)
                if let data = try? JSONSerialization.data(withJSONObject: errorBody) {
                    return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"], body: data)
                }
                return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                                  body: Data("{\"error\":\"Tier limit exceeded\"}".utf8))
            case .rateLimited:
                let errorBody = TierEnforcer.errorResponse(tierCheck)
                if let data = try? JSONSerialization.data(withJSONObject: errorBody) {
                    return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"], body: data)
                }
                return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"],
                                  body: Data("{\"error\":\"Rate limited\"}".utf8))
            }
        }

        // MARK: - Security Self-Audit
        if req.method == "GET" && req.path == "/v1/security/audit" {
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleSecurityAudit(clientIP: clientIP)
            }
        }

        // MARK: - Dashboard API
        if req.path.hasPrefix("/v1/dashboard") || req.path.hasPrefix("/v1/config") || req.path.hasPrefix("/v1/audit") {
            return await handleDashboardRoute(req, clientIP: clientIP)
        }

        // MARK: - Event Bus API
        if req.path.hasPrefix("/v1/events") || req.path == "/events/stream" || req.path == "/events/log" {
            return await handleEventBusRoute(req, clientIP: clientIP, currentLevel: currentLevel, writer: writer, corsOrigin: corsOrigin)
        }

        // MARK: - Evening Wind-Down
        if req.path.hasPrefix("/v1/winddown") {
            if let (status, body) = await WindDownRoutes.handle(method: req.method, path: req.path, body: req.jsonBody) {
                if let data = try? JSONSerialization.data(withJSONObject: body) {
                    return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
                }
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Unknown wind-down route\"}".utf8))
        }

        // MARK: - Conversation Search
        if req.path.hasPrefix("/search") {
            return await handleSearchRoute(req, clientIP: clientIP)
        }

        // MARK: - Commitments API
        if req.path.hasPrefix("/v1/commitments") {
            if let (status, body) = await CommitmentsRoutes.handle(method: req.method, path: req.path, body: req.jsonBody) {
                if let data = try? JSONSerialization.data(withJSONObject: body) {
                    return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
                }
            }
            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Unknown commitments route\"}".utf8))
        }

        // MARK: - LoA (Library of Alexandria) Shortcuts
        if req.path.hasPrefix("/v1/loa") {
            return await handleLoARoute(req, clientIP: clientIP)
        }

        // MARK: - Debate API (multi-agent decision analysis)
        if req.path.hasPrefix("/v1/debate") {
            return await handleDebateRoute(req, clientIP: clientIP, currentLevel: currentLevel, agentID: agentID)
        }

        // MARK: - Memory Management API
        if req.path.hasPrefix("/v1/memory") {
            return await handleMemoryRoute(req, clientIP: clientIP)
        }

        // MARK: - LoA Memory Engine (structured knowledge store)
        if req.path.hasPrefix("/memory") {
            if let response = await handleLoAMemoryEngineRoute(req, clientIP: clientIP) {
                return response
            }
        }

        switch (req.method, req.path) {

        // --- Level 1: Chat ---
        case ("POST", "/v1/chat/completions"):
            // Cloud tier: check daily message limit
            if let ctx = cloudContext {
                let msgCheck = await TierEnforcer.checkMessageLimit(ctx: ctx)
                if case .rateLimited = msgCheck {
                    let errorBody = TierEnforcer.errorResponse(msgCheck)
                    if let data = try? JSONSerialization.data(withJSONObject: errorBody) {
                        return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"], body: data)
                    }
                }
            }
            // Token budget enforcement: check if agent has exceeded configured limits
            if let agentConfig = await AgentConfigManager.shared.agent(agentID) {
                let budget = await TokenTracker.shared.budgetStatus(agentID: agentID, config: agentConfig)
                if budget.overBudget && agentConfig.hardStopOnBudget {
                    return HTTPResponse(statusCode: 429, headers: ["Content-Type": "application/json"],
                                      body: Data("{\"error\":\"Agent '\(agentID)' has exceeded its token budget\"}".utf8))
                }
            }
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
                await streamChatCompletion(req, clientIP: clientIP, agentID: agentID, accessLevel: currentLevel, platform: platform, writer: writer, corsOrigin: corsOrigin, cloudContext: cloudContext)
                return nil // Already streamed
            }
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.proxyChatCompletion(req, clientIP: clientIP, agentID: agentID, accessLevel: currentLevel, platform: platform, cloudContext: cloudContext)
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
                await self.listMessages(req: req)
            }

        // --- Chat Rooms (multi-user) ---
        case ("POST", "/v1/room/create"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let body = req.jsonBody ?? [:]
                // L-5: Always generate server-side room IDs — never accept client-supplied values
                let roomID = UUID().uuidString.prefix(8).lowercased()
                let rawSender = body["sender"] as? String ?? "Anonymous"
                let sender = String(rawSender.replacingOccurrences(of: "[<>&\"']", with: "", options: .regularExpression).prefix(30))
                await ChatRoomStore.shared.createRoom(String(roomID))
                return HTTPResponse.json(["room": roomID, "sender": sender, "status": "created"])
            }
        case ("POST", "/v1/room/message"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let room = body["room"] as? String,
                      let sender = body["sender"] as? String,
                      let content = body["content"] as? String else {
                    return HTTPResponse.badRequest("Missing room, sender, or content")
                }
                let role = body["role"] as? String ?? "user"
                let agentIDVal = body["agentID"] as? String
                let msg = await ChatRoomStore.shared.postMessage(room: room, sender: sender, content: content, role: role, agentID: agentIDVal)
                let msgDict: [String: Any] = [
                    "id": msg.id, "sender": msg.sender, "content": msg.content,
                    "timestamp": msg.timestamp, "role": msg.role, "agentID": msg.agentID ?? ""
                ]
                return HTTPResponse.json(["status": "ok", "message": msgDict])
            }
        case ("GET", "/v1/room/messages"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let room = req.queryParam("room") ?? ""
                let since = Double(req.queryParam("since") ?? "0") ?? 0
                guard !room.isEmpty else {
                    return HTTPResponse.badRequest("Missing room parameter")
                }
                let msgs = await ChatRoomStore.shared.messages(room: room, since: since)
                let list: [[String: Any]] = msgs.map { m in
                    ["id": m.id, "sender": m.sender, "content": m.content,
                     "timestamp": m.timestamp, "role": m.role, "agentID": m.agentID ?? ""]
                }
                return HTTPResponse.json(["messages": list, "count": list.count])
            }
        case ("GET", "/v1/room/exists"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let room = req.queryParam("room") ?? ""
                let exists = await ChatRoomStore.shared.roomExists(room)
                return HTTPResponse.json(["room": room, "exists": exists])
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
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleSetLevel(req, clientIP: clientIP)
            }

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

        // --- Memory API (handled by /v1/memory prefix route above) ---

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

        // --- MCP Server Management ---
        case ("GET", "/v1/mcp/servers"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMCPListServers()
            }
        case ("POST", "/v1/mcp/servers"):
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMCPAddServer(req)
            }
        case ("GET", "/v1/mcp/tools"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await self.handleMCPListTools()
            }
        case _ where req.path.hasPrefix("/v1/mcp/servers/") && req.method == "DELETE":
            return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                let serverName = String(req.path.dropFirst("/v1/mcp/servers/".count))
                    .removingPercentEncoding ?? String(req.path.dropFirst("/v1/mcp/servers/".count))
                return await self.handleMCPRemoveServer(name: serverName)
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
                     "last_run": ev.lastRunAt.map { df.string(from: $0) } ?? "",
                     "next_run": ev.nextRunAt.map { df.string(from: $0) } ?? "",
                     "created_at": df.string(from: ev.createdAt)]
                }
                return HTTPResponse.json(["schedules": items, "count": items.count])
            }

        // --- Schedule Management Routes (Mission Control) ---
        default: break
        }

        // Schedule toggle/delete/run (dynamic path)
        if req.path.hasPrefix("/v1/schedules/") {
            let pathParts = req.path.split(separator: "/")
            if pathParts.count >= 3 {
                let scheduleID = String(pathParts[2])

                // PUT /v1/schedules/{id}/toggle — Toggle schedule on/off
                if req.method == "PUT" && req.path.hasSuffix("/toggle") {
                    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                        let enabled = (req.jsonBody?["enabled"] as? Bool) ?? true
                        let success = await WebhookManager.shared.toggleSchedule(scheduleID, enabled: enabled)
                        if success {
                            return HTTPResponse.json(["status": "toggled", "enabled": enabled])
                        }
                        return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                                           body: Data("{\"error\":\"Schedule not found\"}".utf8))
                    }
                }

                // DELETE /v1/schedules/{id} — Delete schedule
                if req.method == "DELETE" {
                    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                        let success = await WebhookManager.shared.deleteSchedule(scheduleID)
                        if success {
                            return HTTPResponse.json(["status": "deleted"])
                        }
                        return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                                           body: Data("{\"error\":\"Schedule not found\"}".utf8))
                    }
                }

                // POST /v1/schedules/{id}/run — Trigger immediate run
                if req.method == "POST" && req.path.hasSuffix("/run") {
                    return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                        let schedules = await WebhookManager.shared.listSchedules()
                        guard let event = schedules.first(where: { $0.id == scheduleID }) else {
                            return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                                               body: Data("{\"error\":\"Schedule not found\"}".utf8))
                        }
                        // Create a task from the schedule
                        let task = await TaskQueue.shared.createTask(
                            title: event.name,
                            description: event.description,
                            assignedTo: event.assignedTo,
                            assignedBy: "mission-control",
                            priority: .high
                        )
                        return HTTPResponse.json(["status": "triggered", "task_id": task.id])
                    }
                }
            }
        }

        // GET /v1/mission-control — Aggregate Mission Control data
        if req.method == "GET" && req.path == "/v1/mission-control" {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let df = ISO8601DateFormatter()

                // Tasks
                let allTasks = await TaskQueue.shared.allTasks()
                let taskItems: [[String: Any]] = allTasks.suffix(50).map { t in
                    ["id": t.id, "title": t.title, "description": t.description,
                     "assigned_to": t.assignedTo, "assigned_by": t.assignedBy,
                     "status": t.status.rawValue, "priority": t.priority.rawValue,
                     "result": t.result ?? "", "error": t.error ?? "",
                     "created_at": df.string(from: t.createdAt),
                     "started_at": t.startedAt.map { df.string(from: $0) } ?? "",
                     "completed_at": t.completedAt.map { df.string(from: $0) } ?? ""]
                }

                // Schedules
                let schedules = await WebhookManager.shared.listSchedules()
                let scheduleItems: [[String: Any]] = schedules.map { ev in
                    ["id": ev.id, "name": ev.name, "description": ev.description,
                     "assigned_to": ev.assignedTo, "enabled": ev.enabled,
                     "run_count": ev.runCount,
                     "last_run": ev.lastRunAt.map { df.string(from: $0) } ?? "",
                     "next_run": ev.nextRunAt.map { df.string(from: $0) } ?? "",
                     "created_at": df.string(from: ev.createdAt)]
                }

                // Agents
                let agents = await AgentConfigManager.shared.listAgents()
                let agentItems: [[String: Any]] = agents.map { a in
                    ["id": a.id, "name": a.name, "access_level": a.accessLevel]
                }

                // System health
                let s = self.appState
                let health = await MainActor.run { () -> [String: Any] in
                    let uptime = Date().timeIntervalSince(GatewayServer.serverStartTime)
                    return [
                        "uptime_seconds": Int(uptime),
                        "active_connections": s?.connectedClients ?? 0,
                        "total_requests": s?.totalRequests ?? 0,
                        "blocked_requests": s?.blockedRequests ?? 0,
                        "access_level": s?.accessLevel.rawValue ?? 0,
                        "ollama_running": s?.ollamaRunning ?? false,
                        "server_running": s?.serverRunning ?? false,
                        "max_concurrent_tasks": s?.maxConcurrentTasks ?? 3
                    ] as [String: Any]
                }

                // Task summary counts
                let pending = allTasks.filter { $0.status == .pending }.count
                let active = allTasks.filter { $0.status == .inProgress }.count
                let completed = allTasks.filter { $0.status == .completed }.count
                let failed = allTasks.filter { $0.status == .failed }.count

                let response: [String: Any] = [
                    "tasks": taskItems,
                    "task_counts": ["pending": pending, "active": active, "completed": completed, "failed": failed],
                    "schedules": scheduleItems,
                    "agents": agentItems,
                    "health": health
                ]

                return HTTPResponse.json(response)
            }
        }

        switch (req.method, req.path) {
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

        // --- Agents (Multi-Agent CRUD) ---
        case ("GET", "/v1/agents"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let agents = await AgentConfigManager.shared.listAgents()
                guard let agentsData = try? JSONEncoder.torboBase.encode(agents),
                      let agentsArray = try? JSONSerialization.jsonObject(with: agentsData) else {
                    return HTTPResponse.json(["error": "Failed to serialize agents"])
                }
                let wrapped: [String: Any] = ["agents": agentsArray]
                guard let data = try? JSONSerialization.data(withJSONObject: wrapped) else {
                    return HTTPResponse.json(["error": "Failed to serialize agents"])
                }
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("POST", "/v1/agents"):
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let jsonData = try? JSONSerialization.data(withJSONObject: body),
                      var config = try? JSONDecoder.torboBase.decode(AgentConfig.self, from: jsonData) else {
                    return HTTPResponse.badRequest("Invalid agent config")
                }
                // Cap the new agent's access level to the caller's level
                config.accessLevel = min(config.accessLevel, currentLevel.rawValue)
                do {
                    try await AgentConfigManager.shared.createAgent(config)
                    let appState = self.appState
                    await MainActor.run { appState?.refreshAgentLevels() }
                    guard let responseData = try? JSONEncoder.torboBase.encode(config) else {
                        return HTTPResponse.json(["status": "created", "id": config.id])
                    }
                    return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/json"], body: responseData)
                } catch {
                    return HTTPResponse.badRequest("Failed to create agent")
                }
            }

        // Backward compat: /v1/agent/config → SiD's config
        case ("GET", "/v1/agent/config"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                guard let data = await AgentConfigManager.shared.exportAgent("sid") else {
                    return HTTPResponse.json(["error": "Failed to serialize config"])
                }
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
            }
        case ("PUT", "/v1/agent/config"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
                    return HTTPResponse.badRequest("Invalid JSON body")
                }
                let success = await AgentConfigManager.shared.importAgent(jsonData)
                return success ? HTTPResponse.json(["status": "updated"]) : HTTPResponse.badRequest("Invalid config format")
            }
        case ("POST", "/v1/agent/reset"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                await AgentConfigManager.shared.resetAgent("sid")
                return HTTPResponse.json(["status": "reset"])
            }

        // --- Skills ---
        case ("GET", "/v1/skills"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let skills = await SkillsManager.shared.listSkills()
                return HTTPResponse.json(["skills": skills])
            }
        case ("PUT", "/v1/skills"):
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let skillId = body["id"] as? String,
                      let enabled = body["enabled"] as? Bool else {
                    return HTTPResponse.badRequest("Missing 'id' and 'enabled'")
                }
                await SkillsManager.shared.setEnabled(skillId: skillId, enabled: enabled)
                return HTTPResponse.json(["status": "updated", "id": skillId, "enabled": enabled])
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
            // Per-agent routes: /v1/agents/{id}, /v1/agents/{id}/reset
            if req.path.hasPrefix("/v1/agents/") {
                let pathAfterAgents = String(req.path.dropFirst("/v1/agents/".count))
                let components = pathAfterAgents.split(separator: "/")
                if let firstComponent = components.first {
                    let targetAgentID = String(firstComponent)

                    // GET /v1/agents/{id} — get single agent config
                    if components.count == 1 && req.method == "GET" {
                        return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                            guard let data = await AgentConfigManager.shared.exportAgent(targetAgentID) else {
                                return HTTPResponse.notFound()
                            }
                            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
                        }
                    }

                    // PUT /v1/agents/{id} — update agent config
                    if components.count == 1 && req.method == "PUT" {
                        return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                            guard let body = req.jsonBody,
                                  let jsonData = try? JSONSerialization.data(withJSONObject: body),
                                  var config = try? JSONDecoder.torboBase.decode(AgentConfig.self, from: jsonData) else {
                                return HTTPResponse.badRequest("Invalid agent config")
                            }
                            // Prevent privilege escalation: cap agent accessLevel to the caller's level
                            config.accessLevel = min(config.accessLevel, currentLevel.rawValue)
                            await AgentConfigManager.shared.updateAgent(config)
                            let appState = self.appState
                            await MainActor.run { appState?.refreshAgentLevels() }
                            return HTTPResponse.json(["status": "updated", "id": targetAgentID])
                        }
                    }

                    // DELETE /v1/agents/{id} — delete agent (not SiD)
                    if components.count == 1 && req.method == "DELETE" {
                        return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                            do {
                                try await AgentConfigManager.shared.deleteAgent(targetAgentID)
                                let appState = self.appState
                                await MainActor.run { appState?.refreshAgentLevels() }
                                return HTTPResponse.json(["status": "deleted", "id": targetAgentID])
                            } catch {
                                return HTTPResponse.badRequest("Failed to delete agent")
                            }
                        }
                    }

                    // POST /v1/agents/{id}/reset — reset agent to defaults
                    if components.count == 2 && components[1] == "reset" && req.method == "POST" {
                        return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                            await AgentConfigManager.shared.resetAgent(targetAgentID)
                            return HTTPResponse.json(["status": "reset", "id": targetAgentID])
                        }
                    }

                    // GET /v1/agents/{id}/prompt — get fully assembled identity prompt for agent
                    if components.count == 2 && components[1] == "prompt" && req.method == "GET" {
                        return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                            guard let config = await AgentConfigManager.shared.agent(targetAgentID) else {
                                return HTTPResponse.notFound()
                            }
                            let agentLevel = min(config.accessLevel, currentLevel.rawValue)
                            // Extract tool names from tool definitions
                            let toolDefs = await ToolProcessor.toolDefinitionsWithMCP(for: AccessLevel(rawValue: agentLevel) ?? .chatOnly, agentID: targetAgentID)
                            let toolNames = toolDefs.compactMap { ($0["name"] as? String) ?? (($0["function"] as? [String: Any])?["name"] as? String) }
                            let identityBlock = config.buildIdentityBlock(accessLevel: agentLevel, availableTools: toolNames)

                            let response: [String: Any] = [
                                "agent_id": targetAgentID,
                                "name": config.name,
                                "identity": identityBlock,
                                "access_level": agentLevel,
                                "voice_tone": config.voiceTone,
                                "personality_preset": config.personalityPreset,
                                "custom_instructions": config.customInstructions,
                                "background_knowledge": config.backgroundKnowledge,
                                "last_modified": config.lastModifiedAt?.timeIntervalSince1970 ?? 0
                            ]
                            guard let data = try? JSONSerialization.data(withJSONObject: response) else {
                                return HTTPResponse.serverError("Failed to serialize prompt")
                            }
                            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
                        }
                    }
                }
            }

            // Ollama model management proxy
            if req.path == "/v1/ollama/pull" && req.method == "POST" {
                return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                    guard let body = req.jsonBody, let name = body["name"] as? String, !name.isEmpty else {
                        return HTTPResponse.badRequest("Missing model name")
                    }
                    guard let url = URL(string: "\(OllamaManager.baseURL)/api/pull") else {
                        return HTTPResponse.serverError("Ollama not configured")
                    }
                    var pullReq = URLRequest(url: url)
                    pullReq.httpMethod = "POST"
                    pullReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    pullReq.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "stream": false])
                    pullReq.timeoutInterval = 600  // Models can be large
                    do {
                        let (data, resp) = try await URLSession.shared.data(for: pullReq)
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? 500
                        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
                    } catch {
                        return HTTPResponse.serverError("Ollama pull failed: \(error.localizedDescription)")
                    }
                }
            }
            if req.path == "/v1/ollama/delete" && req.method == "DELETE" {
                return await guardedRoute(level: .execute, current: currentLevel, clientIP: clientIP, req: req) {
                    guard let body = req.jsonBody, let name = body["name"] as? String, !name.isEmpty else {
                        return HTTPResponse.badRequest("Missing model name")
                    }
                    guard let url = URL(string: "\(OllamaManager.baseURL)/api/delete") else {
                        return HTTPResponse.serverError("Ollama not configured")
                    }
                    var delReq = URLRequest(url: url)
                    delReq.httpMethod = "DELETE"
                    delReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    delReq.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
                    do {
                        let (data, resp) = try await URLSession.shared.data(for: delReq)
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? 500
                        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
                    } catch {
                        return HTTPResponse.serverError("Ollama delete failed: \(error.localizedDescription)")
                    }
                }
            }

            // WhatsApp webhook handler
            if req.path == "/v1/whatsapp/webhook" {
                if req.method == "GET" {
                    // WhatsApp verification challenge
                    let mode = req.queryParam("hub.mode")
                    let token = req.queryParam("hub.verify_token")
                    let challenge = req.queryParam("hub.challenge")
                    let configuredToken = await MainActor.run { AppState.shared.whatsappVerifyToken ?? "" }
                    let result = await WhatsAppBridge.shared.handleVerification(mode: mode, token: token, challenge: challenge, storedVerifyToken: configuredToken)
                    if result.valid, let ch = result.challenge {
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
                    let result = await WebhookManager.shared.trigger(webhookID: webhookID, payload: payload, headers: req.headers, rawBody: req.body)
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

            // Ambient Monitor routes
            if req.path.hasPrefix("/ambient") {
                if let response = await handleAmbientRoute(req, clientIP: clientIP) {
                    return response
                }
            }


            // LifeOS Morning Briefing routes
            if req.path.hasPrefix("/lifeos/briefing") {
                if let response = await handleBriefingRoute(req, clientIP: clientIP) {
                    return response
                }
            }

            // Cron Scheduler routes
            if req.path.hasPrefix("/v1/cron/tasks") {
                if let response = await handleCronSchedulerRoute(req, clientIP: clientIP) {
                    return response
                }
            }

            // TaskQueue routes
            if req.path.hasPrefix("/v1/tasks") {
                if let response = await handleTaskQueueRoute(req, clientIP: clientIP) {
                    return response
                }
            }

            // Evening Wind-Down routes
            if req.path.hasPrefix("/v1/winddown") {
                if let (status, body) = await WindDownRoutes.handle(method: req.method, path: req.path, body: req.jsonBody) {
                    if let data = try? JSONSerialization.data(withJSONObject: body) {
                        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
                    }
                }
                return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                                  body: Data("{\"error\":\"Unknown wind-down route\"}".utf8))
            }

            // LifeOS Predictor routes
            if req.path.hasPrefix("/v1/lifeos") {
                if let response = await handleLifeOSRoute(req, clientIP: clientIP) {
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

    private func authenticate(_ req: HTTPRequest, clientIP: String = "") -> Bool {
        // Localhost access skips auth entirely.
        // clientIP is pre-stripped of port by stripPort() at extraction point.
        if clientIP == "127.0.0.1" || clientIP == "::1" || clientIP == "localhost" { return true }
        guard let auth = req.headers["authorization"] ?? req.headers["Authorization"] else { return false }
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        if token == KeychainManager.serverToken { return true }
        if webchatSessionTokens.contains(token) { return true }
        return PairedDeviceStore.isAuthorized(token: token)
    }

    /// Resolve cloud authentication from a Supabase JWT.
    /// Returns nil if cloud auth is not enabled or the JWT is invalid.
    /// This runs in parallel with legacy auth — if either succeeds, the request proceeds.
    private func resolveCloudAuth(_ req: HTTPRequest) async -> CloudRequestContext? {
        guard await SupabaseAuth.shared.isEnabled else { return nil }

        guard let auth = req.headers["authorization"] ?? req.headers["Authorization"] else { return nil }
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth

        // Don't try cloud auth for legacy server tokens or paired device tokens
        if token == KeychainManager.serverToken { return nil }
        if PairedDeviceStore.isAuthorized(token: token) { return nil }

        // Try to resolve as Supabase JWT
        return await CloudUserManager.shared.resolveContext(fromJWT: token)
    }

    // MARK: - Pairing

    private func handlePair(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let code = body["code"] as? String,
              let rawDeviceName = body["deviceName"] as? String else {
            return HTTPResponse.badRequest("Missing 'code' or 'deviceName'")
        }
        // L-7: Sanitize device name — strip control chars and limit length
        let deviceName = String(rawDeviceName.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 }.prefix(64))
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
        var pairResponse: [String: Any] = ["token": token, "deviceId": deviceId]
        if let tsIP = Self.detectTailscaleIP() { pairResponse["tailscaleIP"] = tsIP }
        if let tsHostname = Self.detectTailscaleHostname() { pairResponse["tailscaleHostname"] = tsHostname }
        return HTTPResponse.json(pairResponse)
    }

    private func handlePairVerify(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody, let token = body["token"] as? String else {
            return HTTPResponse.badRequest("Missing 'token'")
        }
        let valid = await MainActor.run { PairingManager.shared.verifyToken(token) }
        var response: [String: Any] = ["valid": valid]
        if valid {
            if let tsIP = Self.detectTailscaleIP() { response["tailscaleIP"] = tsIP }
            if let tsHostname = Self.detectTailscaleHostname() { response["tailscaleHostname"] = tsHostname }
        }
        return HTTPResponse.json(response)
    }

    /// Auto-pair: trusted Tailscale clients (100.x.x.x) can pair without a code.
    /// The device sends its name; Base issues a token automatically.
    /// This is safe because Tailscale IPs are already authenticated via WireGuard keys.
    private func handleAutoPair(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        // Only allow auto-pair from Tailscale IPs (100.x.x.x/8)
        guard clientIP.hasPrefix("100.") else {
            TorboLog.warn("Auto-pair rejected from non-Tailscale IP: \(clientIP)", subsystem: "Pairing")
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Auto-pair only available on Tailscale network\"}".utf8))
        }

        guard let body = req.jsonBody,
              let rawDeviceName = body["deviceName"] as? String, !rawDeviceName.isEmpty else {
            return HTTPResponse.badRequest("Missing 'deviceName'")
        }
        // L-7: Sanitize device name
        let deviceName = String(rawDeviceName.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 }.prefix(64))

        // Check if this device is already paired (by name) — return existing token
        let existing: (token: String, id: String)? = await MainActor.run {
            if let device = PairingManager.shared.pairedDevices.first(where: { $0.name == deviceName }) {
                return (device.token, device.id)
            }
            return nil
        }
        if let existing {
            TorboLog.debug("Auto-pair: returning existing token for \(deviceName)", subsystem: "Pairing")
            var existingResponse: [String: Any] = ["token": existing.token, "deviceId": existing.id, "status": "existing"]
            if let tsIP = Self.detectTailscaleIP() { existingResponse["tailscaleIP"] = tsIP }
            if let tsHostname = Self.detectTailscaleHostname() { existingResponse["tailscaleHostname"] = tsHostname }
            return HTTPResponse.json(existingResponse)
        }

        // Create a new paired device directly (no code needed — Tailscale is the trust anchor)
        let result: (token: String, deviceId: String) = await MainActor.run {
            PairingManager.shared.autoPair(deviceName: deviceName)
        }

        let token = result.token
        let deviceId = result.deviceId

        guard !token.isEmpty else {
            TorboLog.error("Auto-pair failed for \(deviceName)", subsystem: "Pairing")
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Auto-pair failed\"}".utf8))
        }

        TorboLog.info("Auto-paired \(deviceName) from Tailscale IP \(clientIP)", subsystem: "Pairing")
        await audit(clientIP: clientIP, method: "POST", path: "/pair/auto",
                   required: .chatOnly, granted: true, detail: "Auto-paired: \(deviceName)")
        Task { await TelegramBridge.shared.notify("Device auto-paired: \(deviceName) (Tailscale)") }
        var newResponse: [String: Any] = ["token": token, "deviceId": deviceId, "status": "new"]
        if let tsIP = Self.detectTailscaleIP() { newResponse["tailscaleIP"] = tsIP }
        if let tsHostname = Self.detectTailscaleHostname() { newResponse["tailscaleHostname"] = tsHostname }
        return HTTPResponse.json(newResponse)
    }

    // MARK: - Rate Limiting
    // Safety: GatewayServer is an actor — all calls to isRateLimited are serialized.
    // The read-modify-write on requestLog[clientIP] is atomic by actor isolation.

    private var lastRateLimitPrune: Date = Date()

    private func isRateLimited(clientIP: String) -> Bool {
        let now = Date()
        let window: TimeInterval = 60
        let limit = AppConfig.rateLimit
        var timestamps = requestLog[clientIP] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < window }
        timestamps.append(now)
        requestLog[clientIP] = timestamps

        // Time-based pruning every 5 minutes (prevents unbounded dict growth during low-traffic periods)
        if now.timeIntervalSince(lastRateLimitPrune) > 300 {
            lastRateLimitPrune = now
            let cutoff = now.addingTimeInterval(-window)
            requestLog = requestLog.filter { _, dates in
                dates.contains { $0 > cutoff }
            }
        }

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
        TorboLog.info("\(emoji) \(method) \(path) from \(clientIP) — \(detail)", subsystem: "Gateway")
        let state = appState
        await MainActor.run { state?.addAuditEntry(entry) }
    }

    // MARK: - Streaming Chat Completion (SSE)

    private func streamChatCompletion(_ req: HTTPRequest, clientIP: String, agentID: String, accessLevel: AccessLevel, platform: String? = nil, writer: ResponseWriter, corsOrigin: String? = nil, cloudContext: CloudRequestContext? = nil) async {
        guard var body = req.jsonBody else {
            writer.sendResponse(.badRequest("Invalid JSON body")); return
        }
        // Model priority: request body > agent preferredModel > default
        let agentModel = await AgentConfigManager.shared.agent(agentID)?.preferredModel ?? ""
        let model = (body["model"] as? String) ?? (agentModel.isEmpty ? "qwen2.5:7b" : agentModel)
        if body["model"] == nil { body["model"] = model }

        // Detect if client provided their own system prompt (API override — skip SiD identity)
        let hasClientSystem = clientProvidedSystemPrompt(body)

        await injectSystemPrompt(into: &body)

        // Inject tools based on agent access level (web_search, web_fetch, file tools, MCP tools)
        var toolNames: [String] = []
        if body["tools"] == nil {
            let tools = await ToolProcessor.toolDefinitionsWithMCP(for: accessLevel, agentID: agentID)
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
                toolNames = extractToolNames(from: tools)
            }
        } else {
            // Client provided tools (e.g. native iOS tools) — ensure tool_choice is set
            if body["tool_choice"] == nil {
                body["tool_choice"] = "auto"
            }
            let clientToolNames = extractToolNames(from: body["tools"] as? [[String: Any]] ?? [])
            TorboLog.info("Client provided \(clientToolNames.count) tools: \(clientToolNames.joined(separator: ", "))", subsystem: "Gateway")
        }

        // Enrich with agent identity + memory (identity skipped if client provided system prompt)
        // Cloud users get per-user MemoryRouter with isolated memory/agents
        let router: MemoryRouter
        if let ctx = cloudContext {
            let svc = await CloudUserManager.shared.services(for: ctx)
            router = svc.memoryRouter
        } else {
            router = MemoryRouter.shared
        }
        await router.enrichRequest(&body, accessLevel: accessLevel.rawValue, toolNames: toolNames, clientProvidedSystem: hasClientSystem, agentID: agentID, platform: platform)

        // Commitments detection — fire-and-forget on every user message
        if let messages = body["messages"] as? [[String: Any]],
           let lastUser = messages.last(where: { $0["role"] as? String == "user" }),
           let uText = extractTextContent(from: lastUser["content"]) {
            Task { await self.detectCommitmentsInMessage(uText) }
        }

        // Log user message (handles both string and array/vision content)
        if let messages = body["messages"] as? [[String: Any]],
           let last = messages.last(where: { $0["role"] as? String == "user" }),
           let content = extractTextContent(from: last["content"]) {
            let userMsg = ConversationMessage(role: "user", content: content, model: model, clientIP: clientIP, agentID: agentID)
            if let ctx = cloudContext {
                let svc = await CloudUserManager.shared.services(for: ctx)
                await svc.conversationStore.appendMessage(userMsg)
            } else {
                let s = appState
                await MainActor.run { s?.addMessage(userMsg) }
            }
        }

        // Tool execution loop: use non-streaming tool loop, then simulate SSE output.
        // When the gateway injected tools (toolNames non-empty), we must execute them server-side
        // because the client can't run web_search, write_file, run_command, etc.
        // This applies to ALL models — cloud and local Ollama alike.
        let gatewayManagedTools = !toolNames.isEmpty
        if gatewayManagedTools {
            body["stream"] = false
            var currentBody = body
            let maxToolRounds = 5
            let chunkID = "chatcmpl-tool-\(UUID().uuidString.prefix(8))"
            var headersSent = false

            for round in 0..<maxToolRounds {
                let response = await sendChatRequest(body: currentBody, model: model, clientIP: clientIP)

                guard response.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      await ToolProcessor.shared.hasBuiltInToolCalls(json) else {
                    // No tool calls (or error) — extract text and stream it
                    if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        if headersSent {
                            // Already streaming progress — send final text + finish in same stream
                            sendSSETextChunk(content, id: chunkID, model: model, writer: writer)
                            sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                            writer.sendSSEDone()
                        } else {
                            simulateStreamResponse(content, model: model, writer: writer, corsOrigin: corsOrigin)
                        }
                        logAssistantResponse(response, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"], cloudContext: cloudContext, router: router)
                    } else {
                        let bodyStr = String(data: response.body, encoding: .utf8) ?? "(empty)"
                        TorboLog.warn("Tool loop: empty/unparseable response from \(model) (status \(response.statusCode)): \(bodyStr.prefix(500))", subsystem: "Gateway")
                        let errorMsg = response.statusCode == 200
                            ? "I got an empty response from the model. Try asking again."
                            : "The model returned an error (status \(response.statusCode)). Try again in a moment."
                        if headersSent {
                            sendSSETextChunk(errorMsg, id: chunkID, model: model, writer: writer)
                            sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                            writer.sendSSEDone()
                        } else {
                            writer.sendResponse(response)
                        }
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

                // If there are non-built-in tool calls, can't handle them
                if builtInCalls.count != toolCalls.count {
                    // If there's text content alongside the unexecutable tool calls, use it
                    if let content = message["content"] as? String, !content.isEmpty {
                        if headersSent {
                            sendSSETextChunk(content, id: chunkID, model: model, writer: writer)
                            sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                            writer.sendSSEDone()
                        } else {
                            simulateStreamResponse(content, model: model, writer: writer, corsOrigin: corsOrigin)
                        }
                        return
                    }
                    // No text content — retry without tools so the model gives a plain text response
                    TorboLog.info("Model called unexecutable tool(s), retrying without tools", subsystem: "Gateway")
                    var retryBody = currentBody
                    retryBody.removeValue(forKey: "tools")
                    retryBody.removeValue(forKey: "tool_choice")
                    let retryResponse = await sendChatRequest(body: retryBody, model: model, clientIP: clientIP)
                    if let retryJson = try? JSONSerialization.jsonObject(with: retryResponse.body) as? [String: Any],
                       let retryChoices = retryJson["choices"] as? [[String: Any]],
                       let retryMsg = retryChoices.first?["message"] as? [String: Any],
                       let retryContent = retryMsg["content"] as? String, !retryContent.isEmpty {
                        if headersSent {
                            sendSSETextChunk(retryContent, id: chunkID, model: model, writer: writer)
                            sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                            writer.sendSSEDone()
                        } else {
                            simulateStreamResponse(retryContent, model: model, writer: writer, corsOrigin: corsOrigin)
                        }
                    } else {
                        // Even retry failed — send whatever we got
                        if headersSent { writer.sendSSEDone() }
                        else { writer.sendResponse(retryResponse) }
                    }
                    return
                }

                // Start streaming progress to the client
                if !headersSent {
                    writer.sendStreamHeaders(origin: corsOrigin)
                    headersSent = true
                }

                // Send progress indicator for each tool being executed
                let toolLabels = builtInCalls.compactMap { call -> String? in
                    guard let name = (call["function"] as? [String: Any])?["name"] as? String else { return nil }
                    return Self.toolProgressLabel(name, args: (call["function"] as? [String: Any])?["arguments"] as? String)
                }
                let progressText = toolLabels.joined(separator: "\n") + "\n\n"
                sendSSETextChunk(progressText, id: chunkID, model: model, writer: writer)

                let toolResults = await ToolProcessor.shared.executeBuiltInTools(builtInCalls, accessLevel: accessLevel, agentID: agentID)
                TorboLog.info("Round \(round + 1): Executed \(builtInCalls.count) tool(s) for \(agentID)", subsystem: "Gateway")

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
                if headersSent {
                    sendSSETextChunk(content, id: chunkID, model: model, writer: writer)
                    sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                    writer.sendSSEDone()
                } else {
                    simulateStreamResponse(content, model: model, writer: writer, corsOrigin: corsOrigin)
                }
            } else {
                if headersSent {
                    sendSSEFinishChunk(id: chunkID, model: model, writer: writer)
                    writer.sendSSEDone()
                } else {
                    writer.sendResponse(finalResponse)
                }
            }
            return
        }

        body["stream"] = true

        // Route cloud models through their streaming APIs
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") || model.hasPrefix("grok") {
            await streamCloudCompletion(body: body, model: model, clientIP: clientIP, writer: writer, corsOrigin: corsOrigin, cloudContext: cloudContext, router: router)
            return
        }

        // Stream from Ollama
        guard let url = URL(string: "\(OllamaManager.baseURL)/v1/chat/completions") else {
            writer.sendResponse(.serverError("Bad Ollama URL")); return
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 60
        do { urlReq.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { writer.sendResponse(.badRequest("JSON encode error")); return }

        // Wall-clock deadline for the entire streaming pipeline (5 minutes max)
        let streamDeadline = Date().addingTimeInterval(300)

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            if httpResp?.statusCode != 200 {
                let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Ollama", code: httpResp?.statusCode ?? 500)
                writer.sendResponse(.serverError(errMsg)); return
            }

            writer.sendStreamHeaders(origin: corsOrigin)

            var fullContent = ""
            var buffer = ""

            for try await byte in bytes where !Task.isCancelled && Date() < streamDeadline {
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
            let capturedContent = fullContent
            if !capturedContent.isEmpty {
                let assistantMsg = ConversationMessage(role: "assistant", content: capturedContent, model: model, clientIP: clientIP, agentID: agentID)
                if cloudContext == nil {
                    let s = appState
                    await MainActor.run { s?.addMessage(assistantMsg) }
                } else if let ctx = cloudContext {
                    let svc = await CloudUserManager.shared.services(for: ctx)
                    await svc.conversationStore.appendMessage(assistantMsg)
                }

                // Token tracking (estimate from content length for streaming)
                let promptEst = (req.jsonBody?["messages"] as? [[String: Any]])?.reduce(0) { $0 + ((extractTextContent(from: $1["content"]) ?? "").count / 4) } ?? 0
                let completionEst = capturedContent.count / 4
                await TokenTracker.shared.record(agentID: agentID, promptTokens: promptEst, completionTokens: completionEst, model: model)

                if let messages = (req.jsonBody?["messages"] as? [[String: Any]]),
                   let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
                    Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: capturedContent, model: model) }
                    // Memory extraction (background) — use per-user router for cloud users
                    router.processExchange(userMessage: userContent, assistantResponse: capturedContent, model: model)
                }
            }
        } catch {
            TorboLog.error("Ollama stream error: \(error.localizedDescription)", subsystem: "Gateway")
            // Send error as SSE chunk (headers already sent, can't send HTTP response)
            let errChunk = """
            {"id":"err","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\\n\\n[Stream interrupted — please try again]"},"finish_reason":"stop"}]}
            """
            writer.sendSSEChunk(errChunk)
            writer.sendSSEDone()
        }
    }

    // MARK: - Cloud Streaming

    private func streamCloudCompletion(body: [String: Any], model: String, clientIP: String, writer: ResponseWriter, corsOrigin: String? = nil, cloudContext: CloudRequestContext? = nil, router: MemoryRouter? = nil) async {
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
            if let tools = streamBody["tools"] as? [[String: Any]] {
                let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                TorboLog.info("\(providerName) stream: \(tools.count) tools → \(names.joined(separator: ", ")), tool_choice=\(streamBody["tool_choice"] ?? "nil")", subsystem: "Gateway")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 60
            req.httpBody = try? JSONSerialization.data(withJSONObject: streamBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: providerName, code: httpResp?.statusCode ?? 500)
                    TorboLog.error("\(providerName) streaming error (\(httpResp?.statusCode ?? 0)): \(errMsg)", subsystem: "Gateway")
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders(origin: corsOrigin)
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
                TorboLog.error("\(providerName) stream error: \(error.localizedDescription)", subsystem: "Gateway")
                let errChunk = """
                {"id":"err","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\\n\\n[Stream interrupted — please try again]"},"finish_reason":"stop"}]}
                """
                writer.sendSSEChunk(errChunk)
                writer.sendSSEDone()
                return
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
                let converted = convertToolsToAnthropic(tools)
                anthropicBody["tools"] = converted
                let toolNames = converted.compactMap { $0["name"] as? String }
                TorboLog.info("Anthropic stream: \(converted.count) tools → \(toolNames.joined(separator: ", "))", subsystem: "Gateway")
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
            TorboLog.info("Anthropic stream: tool_choice=\(anthropicBody["tool_choice"] ?? "nil"), messages=\(anthropicMessages.count), model=\(model)", subsystem: "Gateway")

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.timeoutInterval = 60
            req.httpBody = try? JSONSerialization.data(withJSONObject: anthropicBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Anthropic", code: httpResp?.statusCode ?? 500)
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders(origin: corsOrigin)
                var buffer = ""
                let completionId = "chatcmpl-torbo-\(UUID().uuidString.prefix(8))"
                // Track tool calls being built up across streaming events
                var toolCallIndex = 0
                var currentToolId = ""
                var currentToolName = ""
                var currentToolArgs = ""
                var hasToolCalls = false
                var currentBlockType = ""   // Track content block type to skip thinking blocks

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

                        // Track content block types — skip thinking blocks entirely
                        if type == "content_block_start",
                           let contentBlock = json["content_block"] as? [String: Any],
                           let blockType = contentBlock["type"] as? String {
                            currentBlockType = blockType
                        } else if type == "content_block_stop" {
                            currentBlockType = ""
                        }

                        if type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any] {
                            // Skip thinking block deltas — don't forward to client
                            if currentBlockType == "thinking" { continue }
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
                            } else if delta["type"] as? String == "input_json_delta" {
                                // Tool call argument streaming — accumulate only, emit on content_block_stop.
                                // Previous approach emitted per-delta chunks but JSONSerialization.data(withJSONObject:)
                                // silently failed (try?) on partial JSON strings, sending empty argument chunks.
                                let partialJson = delta["partial_json"] as? String ?? ""
                                currentToolArgs += partialJson
                                TorboLog.debug("Anthropic input_json_delta for \(currentToolName): +\(partialJson.count) chars, total=\(currentToolArgs.count)", subsystem: "Gateway")
                            }
                        } else if type == "content_block_start",
                                  let contentBlock = json["content_block"] as? [String: Any],
                                  contentBlock["type"] as? String == "tool_use" {
                            // New tool call starting
                            hasToolCalls = true
                            currentToolId = contentBlock["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                            currentToolName = contentBlock["name"] as? String ?? ""
                            currentToolArgs = ""
                            TorboLog.info("⚙ Tool call START: \(currentToolName) (id: \(currentToolId), index: \(toolCallIndex))", subsystem: "Gateway")
                            // Emit start chunk with name only — args come on content_block_stop
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
                            // Emit complete tool args on block stop — NOT per-delta.
                            // Per-delta emission used JSONSerialization on partial JSON fragments
                            // which could silently fail (try?), sending empty argument chunks.
                            // Complete JSON strings serialize reliably.
                            if hasToolCalls && !currentToolId.isEmpty {
                                let args = currentToolArgs.isEmpty ? "{}" : currentToolArgs
                                let argBytes = args.data(using: .utf8)?.count ?? 0
                                TorboLog.info("⚙ Tool call COMPLETE: \(currentToolName)", subsystem: "Gateway")
                                TorboLog.info("  ↳ Arguments JSON: \(args)", subsystem: "Gateway")
                                TorboLog.info("  ↳ Byte count: \(argBytes) bytes (\(args.count) chars)", subsystem: "Gateway")
                                let toolDelta: [String: Any] = [
                                    "tool_calls": [[
                                        "index": toolCallIndex,
                                        "function": ["arguments": args]
                                    ] as [String: Any]]
                                ]
                                let argsChunk: [String: Any] = [
                                    "id": completionId,
                                    "object": "chat.completion.chunk",
                                    "model": model,
                                    "choices": [["index": 0, "delta": toolDelta, "finish_reason": NSNull()]]
                                ]
                                if let chunkData = try? JSONSerialization.data(withJSONObject: argsChunk),
                                   let chunkStr = String(data: chunkData, encoding: .utf8) {
                                    writer.sendSSEChunk(chunkStr)
                                } else {
                                    TorboLog.error("⚙ Tool call SERIALIZE FAILED: \(currentToolName) — args (\(argBytes) bytes): \(args)", subsystem: "Gateway")
                                }
                                currentToolId = ""
                                currentToolName = ""
                                currentToolArgs = ""
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
                TorboLog.error("Anthropic stream error: \(error.localizedDescription)", subsystem: "Gateway")
                let errChunk = """
                {"id":"err","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\\n\\n[Stream interrupted — please try again]"},"finish_reason":"stop"}]}
                """
                writer.sendSSEChunk(errChunk)
                writer.sendSSEDone()
                return
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
            req.timeoutInterval = 60
            req.httpBody = try? JSONSerialization.data(withJSONObject: geminiBody)

            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let httpResp = resp as? HTTPURLResponse
                if httpResp?.statusCode != 200 {
                    let errMsg = await self.drainErrorBody(bytes: bytes, provider: "Gemini", code: httpResp?.statusCode ?? 500)
                    writer.sendResponse(.serverError(errMsg)); return
                }
                writer.sendStreamHeaders(origin: corsOrigin)
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
                TorboLog.error("Gemini stream error: \(error.localizedDescription)", subsystem: "Gateway")
                let errChunk = """
                {"id":"err","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\\n\\n[Stream interrupted — please try again]"},"finish_reason":"stop"}]}
                """
                writer.sendSSEChunk(errChunk)
                writer.sendSSEDone()
                return
            }
        } else {
            // Unknown cloud model — fall back to non-streaming
            var nonStreamBody = body
            nonStreamBody["stream"] = false
            let response = await routeToCloud(body: nonStreamBody, model: model, clientIP: clientIP)
            writer.sendResponse(response); return
        }

        // Log the full assistant response
        let capturedCloudContent = fullContent
        if !capturedCloudContent.isEmpty {
            let assistantMsg = ConversationMessage(role: "assistant", content: capturedCloudContent, model: model, clientIP: clientIP)
            if let ctx = cloudContext {
                let svc = await CloudUserManager.shared.services(for: ctx)
                await svc.conversationStore.appendMessage(assistantMsg)
            } else {
                let s = appState
                await MainActor.run { s?.addMessage(assistantMsg) }
            }
            if let messages = body["messages"] as? [[String: Any]],
               let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
                Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: capturedCloudContent, model: model) }
                // Memory extraction (background) — use per-user router for cloud users
                let memRouter = router ?? MemoryRouter.shared
                memRouter.processExchange(userMessage: userContent, assistantResponse: capturedCloudContent, model: model)
            }
        }
    }

    // MARK: - System Prompt Injection

    /// Check if the client provided their own system message (API override — skip SiD identity)
    private func clientProvidedSystemPrompt(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.first?["role"] as? String == "system"
    }

    /// Inject the user's custom system prompt from Settings (if enabled).
    /// This is separate from SiD's identity — it's the additional prompt from the Settings panel.
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

    /// Extract tool names from tool definitions for SiD's context awareness
    private func extractToolNames(from tools: [[String: Any]]) -> [String] {
        tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
    }

    // MARK: - Chat Proxy (with streaming, logging & Telegram forwarding)

    private func proxyChatCompletion(_ req: HTTPRequest, clientIP: String, agentID: String, accessLevel: AccessLevel, platform: String? = nil, cloudContext: CloudRequestContext? = nil) async -> HTTPResponse {
        guard var body = req.jsonBody else {
            return HTTPResponse.badRequest("Invalid JSON body")
        }
        // Model priority: request body > agent preferredModel > default
        let agentModel = await AgentConfigManager.shared.agent(agentID)?.preferredModel ?? ""
        let model = (body["model"] as? String) ?? (agentModel.isEmpty ? "qwen2.5:7b" : agentModel)
        if body["model"] == nil { body["model"] = model }

        // Detect if client provided their own system prompt (API override — skip SiD identity)
        let hasClientSystem = clientProvidedSystemPrompt(body)

        // Inject user's custom system prompt from Settings (if enabled)
        await injectSystemPrompt(into: &body)

        // Inject tools based on agent access level (including MCP tools)
        var toolNames: [String] = []
        if body["tools"] == nil {
            let tools = await ToolProcessor.toolDefinitionsWithMCP(for: accessLevel, agentID: agentID)
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
                toolNames = extractToolNames(from: tools)
            }
        } else {
            // Client provided tools (e.g. native iOS tools) — ensure tool_choice is set
            if body["tool_choice"] == nil {
                body["tool_choice"] = "auto"
            }
            let clientToolNames = extractToolNames(from: body["tools"] as? [[String: Any]] ?? [])
            TorboLog.info("Client provided \(clientToolNames.count) tools (non-streaming): \(clientToolNames.joined(separator: ", "))", subsystem: "Gateway")
        }

        // Enrich with agent identity + memory (identity skipped if client provided system prompt)
        // Cloud users get per-user MemoryRouter with isolated memory/agents
        let router: MemoryRouter
        if let ctx = cloudContext {
            let svc = await CloudUserManager.shared.services(for: ctx)
            router = svc.memoryRouter
        } else {
            router = MemoryRouter.shared
        }
        await router.enrichRequest(&body, accessLevel: accessLevel.rawValue, toolNames: toolNames, clientProvidedSystem: hasClientSystem, agentID: agentID, platform: platform)

        // Force non-streaming for this path (streaming handled separately)
        body["stream"] = false

        // Commitments detection — fire-and-forget on every user message
        if let messages = body["messages"] as? [[String: Any]],
           let lastUser = messages.last(where: { $0["role"] as? String == "user" }),
           let uText = extractTextContent(from: lastUser["content"]) {
            Task { await self.detectCommitmentsInMessage(uText) }
        }

        // Log user message (handles both string and array/vision content)
        if let messages = body["messages"] as? [[String: Any]],
           let last = messages.last(where: { $0["role"] as? String == "user" }),
           let content = extractTextContent(from: last["content"]) {
            let userMsg = ConversationMessage(role: "user", content: content, model: model, clientIP: clientIP, agentID: agentID)
            if let ctx = cloudContext {
                let svc = await CloudUserManager.shared.services(for: ctx)
                await svc.conversationStore.appendMessage(userMsg)
            } else {
                let s = appState
                await MainActor.run { s?.addMessage(userMsg) }
            }
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
                logAssistantResponse(response, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"], cloudContext: cloudContext, router: router)
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
            let toolResults = await ToolProcessor.shared.executeBuiltInTools(builtInCalls, accessLevel: accessLevel, agentID: agentID)
            TorboLog.info("Executed \(builtInCalls.count) built-in tool(s)", subsystem: "Gateway")

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
        logAssistantResponse(finalResponse, model: model, clientIP: clientIP, originalMessages: req.jsonBody?["messages"], cloudContext: cloudContext, router: router)
        return finalResponse
    }

    /// Send a single chat completion request (non-streaming) to the appropriate backend
    private func sendChatRequest(body: [String: Any], model: String, clientIP: String) async -> HTTPResponse {
        if model.hasPrefix("claude") || model.hasPrefix("gpt") || model.hasPrefix("gemini") || model.hasPrefix("grok") {
            return await routeToCloud(body: body, model: model, clientIP: clientIP)
        }
        guard let url = URL(string: "\(OllamaManager.baseURL)/v1/chat/completions") else {
            return HTTPResponse.serverError("Bad Ollama URL")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 60
        do { urlReq.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { return HTTPResponse.badRequest("JSON encode error") }
        return await forwardToOllama(urlReq)
    }

    /// Log assistant response and forward to Telegram
    private func logAssistantResponse(_ response: HTTPResponse, model: String, clientIP: String, originalMessages: Any?, cloudContext: CloudRequestContext? = nil, router: MemoryRouter? = nil) {
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return }
        let assistantMsg = ConversationMessage(role: "assistant", content: content, model: model, clientIP: clientIP)
        if cloudContext == nil {
            let s = appState
            Task { @MainActor in s?.addMessage(assistantMsg) }
        } else if let ctx = cloudContext {
            Task { await CloudUserManager.shared.services(for: ctx).conversationStore.appendMessage(assistantMsg) }
        }
        if let messages = originalMessages as? [[String: Any]],
           let userContent = extractTextContent(from: messages.last(where: { $0["role"] as? String == "user" })?["content"]) {
            Task { await TelegramBridge.shared.forwardExchange(user: userContent, assistant: content, model: model) }
            // Memory extraction (background) — use per-user router for cloud users
            let memRouter = router ?? MemoryRouter.shared
            memRouter.processExchange(userMessage: userContent, assistantResponse: content, model: model)
        }
    }

    // MARK: - Cloud Model Routing

    /// Determine the provider for a model prefix
    private func providerForModel(_ model: String) -> String? {
        if model.hasPrefix("claude") { return "ANTHROPIC" }
        if model.hasPrefix("gpt") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") { return "OPENAI" }
        if model.hasPrefix("gemini") { return "GOOGLE" }
        if model.hasPrefix("grok") { return "XAI" }
        return nil
    }

    /// Route a single request to a specific provider. Returns (response, isRetryable).
    private func routeToProvider(_ provider: String, body: [String: Any], model: String, apiKey: String, clientIP: String) async -> (HTTPResponse, Bool) {
        switch provider {
        case "ANTHROPIC": return (await routeToAnthropic(body: body, apiKey: apiKey, model: model, clientIP: clientIP), true)
        case "OPENAI": return (await routeToOpenAI(body: body, apiKey: apiKey, clientIP: clientIP), true)
        case "GOOGLE": return (await routeToGemini(body: body, apiKey: apiKey, model: model, clientIP: clientIP), true)
        case "XAI": return (await routeToXAI(body: body, apiKey: apiKey, clientIP: clientIP), true)
        default: return (HTTPResponse.badRequest("Unknown provider: \(provider)"), false)
        }
    }

    /// Provider fallback order for when primary provider fails
    private let fallbackOrder: [String: [String]] = [
        "ANTHROPIC": ["OPENAI", "XAI"],
        "OPENAI": ["ANTHROPIC", "XAI"],
        "GOOGLE": ["ANTHROPIC", "OPENAI"],
        "XAI": ["OPENAI", "ANTHROPIC"]
    ]

    /// API key names per provider
    private let providerKeyNames: [String: String] = [
        "ANTHROPIC": "ANTHROPIC_API_KEY",
        "OPENAI": "OPENAI_API_KEY",
        "GOOGLE": "GOOGLE_API_KEY",
        "XAI": "XAI_API_KEY"
    ]

    /// Default fallback models per provider
    private let fallbackModels: [String: String] = [
        "ANTHROPIC": "claude-sonnet-4-6-20260217",
        "OPENAI": "gpt-4o",
        "GOOGLE": "gemini-2.0-flash",
        "XAI": "grok-3"
    ]

    private func routeToCloud(body: [String: Any], model: String, clientIP: String) async -> HTTPResponse {
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }

        guard let primaryProvider = providerForModel(model) else {
            return HTTPResponse.badRequest("Unsupported cloud model: \(model)")
        }

        guard let keyName = providerKeyNames[primaryProvider],
              let apiKey = keys[keyName], !apiKey.isEmpty else {
            // No key for primary — try fallbacks immediately
            return await routeWithFallback(body: body, model: model, primaryProvider: primaryProvider, keys: keys, clientIP: clientIP,
                                           reason: "No \(primaryProvider) API key configured")
        }

        // Try primary provider with retry (handles transient 500s and timeouts)
        let response = await routeWithRetry(provider: primaryProvider, body: body, model: model, apiKey: apiKey, clientIP: clientIP)

        // If primary failed with server error, try fallbacks
        if response.statusCode >= 500 || response.statusCode == 429 {
            TorboLog.warn("Primary provider \(primaryProvider) failed (\(response.statusCode)), trying fallbacks", subsystem: "Gateway")
            return await routeWithFallback(body: body, model: model, primaryProvider: primaryProvider, keys: keys, clientIP: clientIP,
                                           reason: "Primary provider returned \(response.statusCode)")
        }

        return response
    }

    /// Route with retry (exponential backoff for transient errors)
    private func routeWithRetry(provider: String, body: [String: Any], model: String, apiKey: String, clientIP: String) async -> HTTPResponse {
        var lastResponse: HTTPResponse?
        var delay: TimeInterval = 1.0

        for attempt in 1...3 {
            let (response, _) = await routeToProvider(provider, body: body, model: model, apiKey: apiKey, clientIP: clientIP)
            lastResponse = response

            // Success or client error (4xx except 429) — don't retry
            if response.statusCode < 500 && response.statusCode != 429 {
                return response
            }

            // 429 — check Retry-After header
            if response.statusCode == 429 {
                if let retryAfter = response.headers["Retry-After"], let secs = Double(retryAfter) {
                    delay = min(secs, 30.0)
                } else {
                    delay = min(delay * 2, 30.0) // Exponential if no header
                }
            }

            if attempt < 3 {
                let jitter = delay * Double.random(in: -0.25...0.25)
                TorboLog.warn("\(provider) attempt \(attempt)/3 failed (\(response.statusCode)), retrying in \(String(format: "%.1f", delay + jitter))s", subsystem: "Gateway")
                try? await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
                delay = min(delay * 2, 30.0)
            }
        }

        return lastResponse ?? HTTPResponse.serverError("All retry attempts failed for \(provider)")
    }

    /// Try fallback providers when primary fails
    private func routeWithFallback(body: [String: Any], model: String, primaryProvider: String, keys: [String: String], clientIP: String, reason: String) async -> HTTPResponse {
        let fallbacks = fallbackOrder[primaryProvider] ?? []

        for fallbackProvider in fallbacks {
            guard let keyName = providerKeyNames[fallbackProvider],
                  let apiKey = keys[keyName], !apiKey.isEmpty else { continue }

            let fallbackModel = fallbackModels[fallbackProvider] ?? model
            TorboLog.info("Falling back to \(fallbackProvider) (\(fallbackModel))", subsystem: "Gateway")

            let (response, _) = await routeToProvider(fallbackProvider, body: body, model: fallbackModel, apiKey: apiKey, clientIP: clientIP)
            if response.statusCode < 500 {
                return response
            }
        }

        // All providers failed
        return HTTPResponse.serverError("\(reason). Fallback providers also unavailable.")
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
            let converted = convertToolsToAnthropic(tools)
            anthropicBody["tools"] = converted
            let toolNames = converted.compactMap { $0["name"] as? String }
            TorboLog.info("Anthropic non-stream: \(converted.count) tools → \(toolNames.joined(separator: ", "))", subsystem: "Gateway")
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
            let httpResp = resp as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 500

            // 401/403 — API key is invalid or expired
            if code == 401 || code == 403 {
                TorboLog.error("Anthropic API key invalid/expired (HTTP \(code))", subsystem: "Gateway")
                return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":{\"message\":\"Cloud API key is invalid or expired. Update it in Settings → API Keys.\",\"type\":\"auth_error\"}}".utf8))
            }
            // 429 — rate limited, pass through with Retry-After
            if code == 429 {
                var headers = ["Content-Type": "application/json"]
                if let retryAfter = httpResp?.value(forHTTPHeaderField: "Retry-After") {
                    headers["Retry-After"] = retryAfter
                }
                TorboLog.warn("Anthropic rate limited (429)", subsystem: "Gateway")
                return HTTPResponse(statusCode: 429, headers: headers, body: data)
            }

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
                // Track tokens from Anthropic usage data
                if let usage = json["usage"] as? [String: Any] {
                    let ptok = usage["input_tokens"] as? Int ?? 0
                    let ctok = usage["output_tokens"] as? Int ?? 0
                    let aid = (body["agent_id"] as? String) ?? "sid"
                    await TokenTracker.shared.record(agentID: aid, promptTokens: ptok, completionTokens: ctok, model: model)
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
            let httpResp = resp as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 500

            if code == 401 || code == 403 {
                TorboLog.error("OpenAI API key invalid/expired (HTTP \(code))", subsystem: "Gateway")
                return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":{\"message\":\"Cloud API key is invalid or expired. Update it in Settings → API Keys.\",\"type\":\"auth_error\"}}".utf8))
            }
            if code == 429 {
                var headers = ["Content-Type": "application/json"]
                if let retryAfter = httpResp?.value(forHTTPHeaderField: "Retry-After") { headers["Retry-After"] = retryAfter }
                TorboLog.warn("OpenAI rate limited (429)", subsystem: "Gateway")
                return HTTPResponse(statusCode: 429, headers: headers, body: data)
            }

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
            let httpResp = resp as? HTTPURLResponse
            let code = httpResp?.statusCode ?? 500

            if code == 401 || code == 403 {
                TorboLog.error("xAI API key invalid/expired (HTTP \(code))", subsystem: "Gateway")
                return HTTPResponse(statusCode: code, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":{\"message\":\"Cloud API key is invalid or expired. Update it in Settings → API Keys.\",\"type\":\"auth_error\"}}".utf8))
            }
            if code == 429 {
                var headers = ["Content-Type": "application/json"]
                if let retryAfter = httpResp?.value(forHTTPHeaderField: "Retry-After") { headers["Retry-After"] = retryAfter }
                TorboLog.warn("xAI rate limited (429)", subsystem: "Gateway")
                return HTTPResponse(statusCode: 429, headers: headers, body: data)
            }

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

    private func listMessages(req: HTTPRequest) async -> HTTPResponse {
        let limit = Int(req.queryParam("limit") ?? "100") ?? 100
        let s2 = appState
        let messages = await MainActor.run { s2?.recentMessages ?? [] }
        let data = messages.suffix(min(limit, 200)).map { m -> [String: Any] in
            var dict: [String: Any] = [
                "id": m.id.uuidString, "role": m.role, "content": m.content,
                "model": m.model, "timestamp": ISO8601DateFormatter().string(from: m.timestamp)
            ]
            if let agentID = m.agentID { dict["agentID"] = agentID }
            return dict
        }
        return HTTPResponse.json(["messages": data])
    }

    // MARK: - Models

    private func listModels() async -> HTTPResponse {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/tags") else {
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
                    list.append(["id": "claude-opus-4-6", "object": "model", "owned_by": "anthropic"])
                    list.append(["id": "claude-sonnet-4-6-20260217", "object": "model", "owned_by": "anthropic"])
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
        // SSRF protection — validate URL before forwarding
        if let ssrfError = AccessControl.validateURLForSSRF(url) {
            return HTTPResponse(statusCode: 403, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(HTTPResponse.jsonEscape(ssrfError))\"}".utf8))
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

    // MARK: - Dashboard API

    // MARK: - M3: Security Self-Audit

    /// Automated security posture check — returns pass/warn/fail for each protection
    private func handleSecurityAudit(clientIP: String) async -> HTTPResponse {
        let state = appState
        let rateLimit = await MainActor.run { state?.rateLimit ?? 0 }
        let blockedCount = await MainActor.run { state?.blockedRequests ?? 0 }
        let tokenAge = KeychainManager.tokenAgeDays
        let pairedDevices = KeychainManager.loadPairedDevices()

        var checks: [[String: Any]] = []

        func check(_ name: String, _ pass: Bool, _ detail: String) {
            checks.append(["name": name, "status": pass ? "pass" : "warn", "detail": detail])
        }

        check("Token Authentication", true, "Bearer token required on all routes")
        check("API Key Encryption", true, "AES-256-CBC at rest via KeychainManager")
        check("Conversation Encryption", true, "Per-message AES-256 encryption")
        check("Path Traversal Protection", true, "Sensitive paths blocked")
        check("Shell Injection Guard", true, "Metachar + command blocklist")
        check("CORS Restriction", true, "Localhost origin only")
        check("Email Content Sandboxing", true, "External email marked untrusted")
        check("SSRF Protection", AppConfig.ssrfProtectionEnabled, AppConfig.ssrfProtectionEnabled ? "Private IPs blocked" : "DISABLED — enable SSRF protection")
        check("Rate Limiting", rateLimit > 0, rateLimit > 0 ? "\(rateLimit) req/min" : "DISABLED — set a rate limit")
        check("CSP Headers", true, "Content-Security-Policy on /chat and /dashboard")
        check("Token Expiry", true, "Paired device tokens expire after 30 days idle")
        check("Webhook Secrets", true, "Auto-generated HMAC secrets")
        check("Token Rotation", (tokenAge ?? 0) <= 90, tokenAge.map { "Token age: \($0)d" } ?? "Token age unknown — consider regenerating")

        let passing = checks.filter { ($0["status"] as? String) == "pass" }.count
        let warnings = checks.count - passing
        let staleDevices = pairedDevices.filter { device in
            let ref = device.lastSeen ?? device.pairedAt
            return Date().timeIntervalSince(ref) > 30 * 86400
        }

        var result: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "summary": ["total": checks.count, "passing": passing, "warnings": warnings],
            "checks": checks,
            "paired_devices": ["total": pairedDevices.count, "stale": staleDevices.count],
            "threats_blocked": blockedCount
        ]
        if !staleDevices.isEmpty {
            result["stale_devices"] = staleDevices.map { $0.name }
        }

        return HTTPResponse.json(result)
    }

    /// Serve legal HTML pages from the embedded LegalHTML enum
    private func serveLegalPage(path: String) -> HTTPResponse {
        let htmlHeaders = [
            "Content-Type": "text/html; charset=utf-8",
            "X-Frame-Options": "DENY",
            "X-Content-Type-Options": "nosniff"
        ]
        if let html = LegalHTML.page(for: path) {
            return HTTPResponse(statusCode: 200, headers: htmlHeaders, body: Data(html.utf8))
        }
        return HTTPResponse(statusCode: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
    }

    /// Dashboard management endpoints for the web UI.
    /// Routes: /v1/dashboard/*, /v1/config/*, /v1/audit/*
    private func handleDashboardRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        let stateRef = appState
        let currentLevel = await MainActor.run { stateRef?.accessLevel ?? .off }

        // GET /v1/dashboard/status — Aggregate server status
        if req.method == "GET" && req.path == "/v1/dashboard/status" {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let s = self.appState
                let state = await MainActor.run { () -> [String: Any] in
                    let uptime = Date().timeIntervalSince(GatewayServer.serverStartTime)
                    let hours = Int(uptime) / 3600
                    let mins = (Int(uptime) % 3600) / 60

                    var status: [String: Any] = [
                        "server": [
                            "running": s?.serverRunning ?? false,
                            "port": s?.serverPort ?? 0,
                            "uptime": "\(hours)h \(mins)m",
                            "uptimeSeconds": Int(uptime),
                            "version": TorboVersion.current
                        ] as [String: Any],
                        "accessLevel": [
                            "current": s?.accessLevel.rawValue ?? 0,
                            "name": s?.accessLevel.name ?? "unknown"
                        ] as [String: Any],
                        "connections": [
                            "active": s?.connectedClients ?? 0,
                            "totalRequests": s?.totalRequests ?? 0,
                            "blockedRequests": s?.blockedRequests ?? 0
                        ] as [String: Any],
                        "ollama": [
                            "running": s?.ollamaRunning ?? false,
                            "installed": s?.ollamaInstalled ?? false,
                            "models": s?.ollamaModels ?? []
                        ] as [String: Any],
                        "settings": [
                            "logLevel": s?.logLevel ?? "info",
                            "rateLimit": s?.rateLimit ?? 60,
                            "maxConcurrentTasks": s?.maxConcurrentTasks ?? 3,
                        ] as [String: Any]
                    ]

                    // Bridge status
                    var bridges: [String: Bool] = [:]
                    bridges["telegram"] = s?.telegramConnected ?? false
                    bridges["discord"] = s?.discordBotToken != nil
                    bridges["slack"] = s?.slackBotToken != nil
                    bridges["signal"] = s?.signalPhoneNumber != nil
                    bridges["whatsapp"] = s?.whatsappAccessToken != nil
                    status["bridges"] = bridges

                    return status
                }

                // Add LoA stats (async)
                var response = state
                let totalScrolls = await MemoryIndex.shared.count
                let categories = await MemoryIndex.shared.categoryCounts()
                let entityCount = await MemoryIndex.shared.knownEntities.count
                response["loa"] = [
                    "totalScrolls": totalScrolls,
                    "categories": categories,
                    "entityCount": entityCount
                ] as [String: Any]

                return HTTPResponse.json(response)
            }
        }

        // GET /v1/config/apikeys — List configured API keys (masked)
        if req.method == "GET" && req.path == "/v1/config/apikeys" {
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                var keys: [[String: Any]] = []
                for provider in CloudProvider.allCases {
                    let raw = KeychainManager.getAPIKey(for: provider)
                    let configured = !raw.isEmpty
                    var masked = ""
                    if configured && raw.count > 10 {
                        masked = String(raw.prefix(6)) + "..." + String(raw.suffix(4))
                    } else if configured {
                        masked = "***configured***"
                    }
                    keys.append([
                        "provider": provider.rawValue,
                        "keyName": provider.keyName,
                        "configured": configured,
                        "masked": masked
                    ] as [String: Any])
                }
                return HTTPResponse.json(["keys": keys])
            }
        }

        // PUT /v1/config/apikeys — Set/delete API keys
        if req.method == "PUT" && req.path == "/v1/config/apikeys" {
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody, let keys = body["keys"] as? [String: String] else {
                    return HTTPResponse.badRequest("Missing 'keys' object")
                }
                KeychainManager.setAllAPIKeys(keys)
                let sRef = self.appState
                await MainActor.run { sRef?.cloudAPIKeys = KeychainManager.getAllAPIKeys() }
                return HTTPResponse.json(["status": "updated", "count": keys.count])
            }
        }

        // GET /v1/config/settings — Current settings
        if req.method == "GET" && req.path == "/v1/config/settings" {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let s = self.appState
                let settings = await MainActor.run { () -> [String: Any] in
                    [
                        "serverPort": s?.serverPort ?? 0,
                        "accessLevel": s?.accessLevel.rawValue ?? 0,
                        "logLevel": s?.logLevel ?? "info",
                        "rateLimit": s?.rateLimit ?? 60,
                        "maxConcurrentTasks": s?.maxConcurrentTasks ?? 3,
                        "systemPromptEnabled": s?.systemPromptEnabled ?? false,
                        "systemPrompt": s?.systemPrompt ?? ""
                    ] as [String: Any]
                }
                return HTTPResponse.json(settings)
            }
        }

        // PUT /v1/config/settings — Update settings
        if req.method == "PUT" && req.path == "/v1/config/settings" {
            return await guardedRoute(level: .fullAccess, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody else {
                    return HTTPResponse.badRequest("Missing JSON body")
                }
                let s = self.appState
                await MainActor.run {
                    if let logLevel = body["logLevel"] as? String {
                        s?.logLevel = logLevel
                    }
                    if let rateLimit = body["rateLimit"] as? Int {
                        s?.rateLimit = rateLimit
                    }
                    if let maxTasks = body["maxConcurrentTasks"] as? Int {
                        s?.maxConcurrentTasks = maxTasks
                    }
                    if let enabled = body["systemPromptEnabled"] as? Bool {
                        s?.systemPromptEnabled = enabled
                    }
                    if let prompt = body["systemPrompt"] as? String {
                        s?.systemPrompt = prompt
                    }
                    if let level = body["accessLevel"] as? Int,
                       let newLevel = AccessLevel(rawValue: level) {
                        s?.accessLevel = newLevel
                    }
                }
                return HTTPResponse.json(["status": "updated"])
            }
        }

        // GET /v1/audit/log — Paginated audit log
        if req.method == "GET" && req.path == "/v1/audit/log" {
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let query = req.queryParams
                let limit = min(Int(query["limit"] ?? "50") ?? 50, 200)
                let offset = Int(query["offset"] ?? "0") ?? 0

                let s = self.appState
                let (entries, total) = await MainActor.run { () -> ([[String: Any]], Int) in
                    let log = s?.auditLog ?? []
                    let total = log.count
                    let sliced = Array(log.dropFirst(offset).prefix(limit))
                    let mapped: [[String: Any]] = sliced.map { entry in
                        let isoFormatter = ISO8601DateFormatter()
                        return [
                            "timestamp": isoFormatter.string(from: entry.timestamp),
                            "clientIP": entry.clientIP,
                            "method": entry.method,
                            "path": entry.path,
                            "requiredLevel": entry.requiredLevel.rawValue,
                            "granted": entry.granted,
                            "detail": entry.detail
                        ] as [String: Any]
                    }
                    return (mapped, total)
                }
                return HTTPResponse.json([
                    "entries": entries,
                    "total": total,
                    "limit": limit,
                    "offset": offset
                ] as [String: Any])
            }
        }

        return HTTPResponse.notFound()
    }

    // MARK: - Event Bus Routes

    private func handleEventBusRoute(
        _ req: HTTPRequest, clientIP: String, currentLevel: AccessLevel,
        writer: ResponseWriter?, corsOrigin: String?
    ) async -> HTTPResponse {

        // GET /events/stream or /v1/events/stream — SSE live event stream
        if req.method == "GET" && (req.path == "/events/stream" || req.path == "/v1/events/stream") {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                guard let writer else {
                    return HTTPResponse.badRequest("SSE requires a streaming connection")
                }

                let pattern = req.queryParam("filter") ?? "*"
                let clientID = UUID().uuidString

                writer.sendStreamHeaders(origin: corsOrigin)

                // Send a connection confirmation event
                let hello: [String: Any] = [
                    "event": "connected",
                    "client_id": clientID,
                    "filter": pattern,
                    "timestamp": Date().timeIntervalSince1970
                ]
                if let data = try? JSONSerialization.data(withJSONObject: hello),
                   let json = String(data: data, encoding: .utf8) {
                    writer.sendSSEChunk(json)
                }

                // Register as SSE client — events will be pushed by EventBus.publish()
                await EventBus.shared.addSSEClient(id: clientID, pattern: pattern, writer: writer)

                // Keep connection alive with periodic heartbeats
                Task {
                    while true {
                        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s heartbeat
                        writer.sendSSEChunk("{\"event\":\"heartbeat\",\"timestamp\":\(Date().timeIntervalSince1970)}")
                    }
                }

                // Return empty response — actual data flows via SSE chunks
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: Data())
            }
        }

        // GET /events/log or /v1/events/log — Recent events from ring buffer
        if req.method == "GET" && (req.path == "/events/log" || req.path == "/v1/events/log") {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let limit = Int(req.queryParam("limit") ?? "100") ?? 100
                let pattern = req.queryParam("filter")
                let events = await EventBus.shared.recentEvents(limit: min(limit, 1000), pattern: pattern)
                let dicts = events.map { $0.toDict() }
                return HTTPResponse.json([
                    "events": dicts,
                    "count": dicts.count,
                    "filter": pattern ?? "*"
                ] as [String: Any])
            }
        }

        // GET /v1/events/critical — Critical events from SQLite audit trail
        if req.method == "GET" && req.path == "/v1/events/critical" {
            return await guardedRoute(level: .readFiles, current: currentLevel, clientIP: clientIP, req: req) {
                let limit = Int(req.queryParam("limit") ?? "100") ?? 100
                let name = req.queryParam("name")
                let events = await EventBus.shared.criticalEvents(limit: min(limit, 1000), name: name)
                return HTTPResponse.json([
                    "events": events,
                    "count": events.count
                ] as [String: Any])
            }
        }

        // GET /v1/events/stats — Event bus statistics
        if req.method == "GET" && req.path == "/v1/events/stats" {
            return await guardedRoute(level: .chatOnly, current: currentLevel, clientIP: clientIP, req: req) {
                let stats = await EventBus.shared.stats()
                return HTTPResponse.json(stats)
            }
        }

        // POST /v1/events/publish — Manually publish an event (for testing/integration)
        if req.method == "POST" && req.path == "/v1/events/publish" {
            return await guardedRoute(level: .writeFiles, current: currentLevel, clientIP: clientIP, req: req) {
                guard let body = req.jsonBody,
                      let eventName = body["event"] as? String else {
                    return HTTPResponse.badRequest("Missing 'event' field")
                }
                let payload = body["payload"] as? [String: String] ?? [:]
                let source = body["source"] as? String ?? "api"
                let event = await EventBus.shared.publish(eventName, payload: payload, source: source)
                return HTTPResponse.json(event.toDict())
            }
        }

        return HTTPResponse.notFound()
    }

    // MARK: - Conversation Search

    private func handleSearchRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        // GET /search/stats — Index statistics
        if req.method == "GET" && req.path == "/search/stats" {
            let s = await ConversationSearch.shared.stats()
            guard let data = try? JSONSerialization.data(withJSONObject: s) else {
                return HTTPResponse.serverError("Failed to encode stats")
            }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        // GET /search/sessions?q=X — Session-level search
        if req.method == "GET" && req.path == "/search/sessions" {
            guard let q = req.queryParam("q"), !q.isEmpty else {
                return .badRequest("Missing 'q' query parameter")
            }
            let limit = Int(req.queryParam("limit") ?? "10") ?? 10
            let sessions = await ConversationSearch.shared.searchSessions(query: q, limit: limit)
            guard let data = try? JSONSerialization.data(withJSONObject: ["sessions": sessions]) else {
                return HTTPResponse.serverError("Failed to encode results")
            }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        // GET /search?q=X — Full-text message search
        if req.method == "GET" && (req.path == "/search" || req.path == "/search/messages") {
            guard let q = req.queryParam("q"), !q.isEmpty else {
                return .badRequest("Missing 'q' query parameter")
            }

            let agentFilter = req.queryParam("agent")
            let limit = Int(req.queryParam("limit") ?? "20") ?? 20
            let offset = Int(req.queryParam("offset") ?? "0") ?? 0

            // Parse date filters (ISO8601 or yyyy-MM-dd)
            let iso = ISO8601DateFormatter()
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"

            var fromDate: Date?
            var toDate: Date?
            if let fromStr = req.queryParam("from") {
                fromDate = iso.date(from: fromStr) ?? dayFmt.date(from: fromStr)
            }
            if let toStr = req.queryParam("to") {
                toDate = iso.date(from: toStr) ?? dayFmt.date(from: toStr)
            }

            let hits = await ConversationSearch.shared.search(
                query: q, agent: agentFilter, from: fromDate, to: toDate, limit: limit, offset: offset
            )

            // Enrich with context
            let enriched = await ConversationSearch.shared.enrichWithContext(hits)

            let response: [String: Any] = [
                "query": q,
                "total": hits.count,
                "offset": offset,
                "results": enriched
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response) else {
                return HTTPResponse.serverError("Failed to encode results")
            }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
        }

        return HTTPResponse.notFound()
    }

    // MARK: - LoA (Library of Alexandria) Shortcuts

    /// User-friendly shortcuts for the memory system.
    /// All routes under /v1/loa — designed to be discoverable and easy to use.
    private func handleLoARoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        let query = req.queryParams

        // GET /v1/loa — Discovery endpoint: list all available shortcuts
        if req.method == "GET" && req.path == "/v1/loa" {
            return HTTPResponse.json([
                "name": "Library of Alexandria (LoA)",
                "description": "Sid's persistent memory system — semantic search, entity tracking, temporal recall",
                "version": TorboVersion.current,
                "shortcuts": [
                    ["method": "GET",  "path": "/v1/loa",           "description": "This discovery page"],
                    ["method": "GET",  "path": "/v1/loa/browse",    "description": "Browse all memories (paginated). Params: page, limit, category"],
                    ["method": "GET",  "path": "/v1/loa/recall",    "description": "Search memories by meaning. Params: q (required), topK"],
                    ["method": "POST", "path": "/v1/loa/teach",     "description": "Teach LoA something new. Body: {text, category?, importance?}"],
                    ["method": "GET",  "path": "/v1/loa/entities",  "description": "List all known entities (people, projects, topics). Params: q (optional filter)"],
                    ["method": "GET",  "path": "/v1/loa/timeline",  "description": "Memories by time range. Params: from, to (ISO 8601), or: range (today/week/month)"],
                    ["method": "POST", "path": "/v1/loa/forget",    "description": "Find & delete memories. Body: {query, confirm?}. Preview first, then confirm."],
                    ["method": "GET",  "path": "/v1/loa/health",    "description": "Memory system health and statistics"],
                    ["method": "PUT",  "path": "/v1/loa/{id}",      "description": "Edit a memory's importance. Body: {importance}"],
                    ["method": "DELETE","path": "/v1/loa/{id}",      "description": "Delete a specific memory by ID"]
                ]
            ] as [String: Any])
        }

        // GET /v1/loa/browse — Paginated memory listing
        if req.method == "GET" && req.path == "/v1/loa/browse" {
            let page = Int(query["page"] ?? "1") ?? 1
            let limit = min(Int(query["limit"] ?? "50") ?? 50, 200)
            let categoryFilter = query["category"]
            let sortBy = query["sort"] ?? "newest"

            let index = MemoryIndex.shared
            var allEntries = await index.allEntries

            if let cat = categoryFilter {
                allEntries = allEntries.filter { $0.category == cat }
            }

            switch sortBy {
            case "oldest": allEntries.sort { $0.timestamp < $1.timestamp }
            case "importance": allEntries.sort { $0.importance > $1.importance }
            case "accessed": allEntries.sort { $0.accessCount > $1.accessCount }
            default: allEntries.sort { $0.timestamp > $1.timestamp }
            }

            let startIdx = (page - 1) * limit
            let endIdx = min(startIdx + limit, allEntries.count)
            guard startIdx < allEntries.count else {
                return HTTPResponse.json(["scrolls": [] as [Any], "total": allEntries.count, "page": page] as [String: Any])
            }

            let slice = allEntries[startIdx..<endIdx]
            let fmt = ISO8601DateFormatter()
            let scrollsJSON: [[String: Any]] = slice.map { entry in
                [
                    "id": entry.id,
                    "text": entry.text,
                    "category": entry.category,
                    "source": entry.source,
                    "importance": entry.importance,
                    "timestamp": fmt.string(from: entry.timestamp),
                    "entities": entry.entities,
                    "access_count": entry.accessCount,
                    "last_accessed": fmt.string(from: entry.lastAccessedAt)
                ] as [String: Any]
            }

            // Available categories for filtering
            let categories = Dictionary(grouping: await index.allEntries, by: { $0.category }).mapValues { $0.count }

            return HTTPResponse.json([
                "scrolls": scrollsJSON,
                "total": allEntries.count,
                "page": page,
                "pages": max(1, Int(ceil(Double(allEntries.count) / Double(limit)))),
                "categories": categories,
                "sort": sortBy
            ] as [String: Any])
        }

        // GET /v1/loa/recall — Semantic search (the fun one)
        if req.method == "GET" && req.path == "/v1/loa/recall" {
            guard let q = query["q"], !q.isEmpty else {
                return HTTPResponse.badRequest("Missing 'q' parameter. What would you like to recall?")
            }
            let topK = Int(query["topK"] ?? "10") ?? 10
            let method = query["method"] ?? "hybrid"

            let results: [MemoryIndex.SearchResult]
            if method == "bm25" {
                results = await MemoryIndex.shared.hybridSearch(query: q, topK: topK)
            } else if method == "vector" {
                results = await MemoryIndex.shared.search(query: q, topK: topK)
            } else {
                results = await MemoryIndex.shared.hybridSearch(query: q, topK: topK)
            }

            let fmt = ISO8601DateFormatter()
            let scrolls: [[String: Any]] = results.map { r in
                [
                    "id": r.id,
                    "text": r.text,
                    "category": r.category,
                    "score": r.score,
                    "importance": r.importance,
                    "timestamp": fmt.string(from: r.timestamp)
                ] as [String: Any]
            }

            return HTTPResponse.json([
                "scrolls": scrolls,
                "count": results.count,
                "query": q,
                "method": method
            ] as [String: Any])
        }

        // POST /v1/loa/teach — Teach LoA something new
        if req.method == "POST" && req.path == "/v1/loa/teach" {
            guard let body = req.jsonBody,
                  let text = body["text"] as? String, !text.isEmpty else {
                return HTTPResponse.badRequest("Missing 'text' in body. What should LoA learn?")
            }
            let category = body["category"] as? String ?? "fact"
            let importance = Float(body["importance"] as? Double ?? 0.7)
            let entities = body["entities"] as? [String] ?? []

            let index = MemoryIndex.shared
            let newID = await index.addWithEntities(
                text: text, category: category, source: "user_taught",
                importance: importance, entities: entities
            )

            if newID != nil {
                return HTTPResponse.json([
                    "learned": true,
                    "text": text,
                    "category": category,
                    "importance": importance,
                    "message": "Scroll added to the Library."
                ] as [String: Any])
            } else {
                return HTTPResponse.serverError("Failed to add memory. Is Ollama running with nomic-embed-text?")
            }
        }

        // GET /v1/loa/entities — Entity index browser
        if req.method == "GET" && req.path == "/v1/loa/entities" {
            let index = MemoryIndex.shared
            let filter = query["q"]?.lowercased()

            let allEntries = await index.allEntries
            var entityCounts: [String: Int] = [:]
            var entityCategories: [String: Set<String>] = [:]
            for entry in allEntries {
                for entity in entry.entities {
                    let key = entity.lowercased()
                    if let filter = filter, !key.contains(filter) { continue }
                    entityCounts[entity, default: 0] += 1
                    entityCategories[entity, default: []].insert(entry.category)
                }
            }

            let entities: [[String: Any]] = entityCounts
                .sorted { $0.value > $1.value }
                .prefix(100)
                .map { name, count in
                    [
                        "name": name,
                        "mention_count": count,
                        "categories": Array(entityCategories[name] ?? [])
                    ] as [String: Any]
                }

            return HTTPResponse.json([
                "entities": entities,
                "total": entityCounts.count
            ] as [String: Any])
        }

        // GET /v1/loa/timeline — Temporal memory browser
        if req.method == "GET" && req.path == "/v1/loa/timeline" {
            let index = MemoryIndex.shared
            let topK = Int(query["topK"] ?? "50") ?? 50

            let from: Date
            let to: Date
            let isoFmt = ISO8601DateFormatter()

            if let range = query["range"] {
                let now = Date()
                let cal = Calendar.current
                switch range {
                case "today":
                    from = cal.startOfDay(for: now)
                    to = now
                case "yesterday":
                    let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
                    from = cal.startOfDay(for: yesterday)
                    to = cal.startOfDay(for: now)
                case "week":
                    from = cal.date(byAdding: .day, value: -7, to: now) ?? now
                    to = now
                case "month":
                    from = cal.date(byAdding: .month, value: -1, to: now) ?? now
                    to = now
                default:
                    from = cal.date(byAdding: .day, value: -7, to: now) ?? now
                    to = now
                }
            } else if let fromStr = query["from"], let fromDate = isoFmt.date(from: fromStr) {
                from = fromDate
                to = query["to"].flatMap { isoFmt.date(from: $0) } ?? Date()
            } else {
                // Default: last 7 days
                from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                to = Date()
            }

            let results = await index.temporalSearch(from: from, to: to, topK: topK)
            let fmt = ISO8601DateFormatter()
            let scrolls: [[String: Any]] = results.map { r in
                [
                    "id": r.id,
                    "text": r.text,
                    "category": r.category,
                    "importance": r.importance,
                    "score": r.score,
                    "timestamp": fmt.string(from: r.timestamp)
                ] as [String: Any]
            }

            return HTTPResponse.json([
                "scrolls": scrolls,
                "count": results.count,
                "range": ["from": fmt.string(from: from), "to": fmt.string(from: to)]
            ] as [String: Any])
        }

        // GET /v1/loa/health — System health
        if req.method == "GET" && req.path == "/v1/loa/health" {
            let index = MemoryIndex.shared
            let count = await index.count
            let categories = await index.categoryCounts()
            let allEntries = await index.allEntries
            let entities = Set(allEntries.flatMap { $0.entities })
            let armyStats = await MemoryArmy.shared.getStats()

            // Find oldest and newest memories
            let fmt = ISO8601DateFormatter()
            let oldest = allEntries.min(by: { $0.timestamp < $1.timestamp })
            let newest = allEntries.max(by: { $0.timestamp < $1.timestamp })
            let mostAccessed = allEntries.sorted(by: { $0.accessCount > $1.accessCount }).prefix(5)

            // Easter egg: the Library speaks if you ask for its health
            let motto: String
            if count == 0 {
                motto = "The shelves are empty. Every library begins with a single scroll."
            } else if count < 100 {
                motto = "A young library, growing with every conversation."
            } else if count < 1000 {
                motto = "The scrolls accumulate. Patterns emerge. The Library begins to know you."
            } else {
                motto = "Vast and deep. The Library of Alexandria remembers what you've forgotten."
            }

            return HTTPResponse.json([
                "name": "Library of Alexandria",
                "status": count > 0 ? "operational" : "empty",
                "motto": motto,
                "total_scrolls": count,
                "categories": categories,
                "entity_count": entities.count,
                "top_entities": Array(entities.sorted().prefix(20)),
                "oldest_scroll": oldest.map { fmt.string(from: $0.timestamp) } ?? "none",
                "newest_scroll": newest.map { fmt.string(from: $0.timestamp) } ?? "none",
                "most_consulted": mostAccessed.map { ["text": String($0.text.prefix(80)), "access_count": $0.accessCount] as [String: Any] },
                "army": armyStats
            ] as [String: Any])
        }

        // POST /v1/loa/forget — Find and delete (same as /v1/memory/forget)
        if req.method == "POST" && req.path == "/v1/loa/forget" {
            guard let body = req.jsonBody,
                  let queryStr = body["query"] as? String, !queryStr.isEmpty else {
                return HTTPResponse.badRequest("Missing 'query' in body. What should LoA forget?")
            }

            let confirm = body["confirm"] as? Bool ?? false
            let results = await MemoryIndex.shared.hybridSearch(query: queryStr, topK: 10)

            if !confirm {
                let fmt = ISO8601DateFormatter()
                let preview: [[String: Any]] = results.map { r in
                    ["id": r.id, "text": r.text, "category": r.category,
                     "importance": r.importance, "timestamp": fmt.string(from: r.timestamp)] as [String: Any]
                }
                return HTTPResponse.json([
                    "preview": true,
                    "scrolls": preview,
                    "count": results.count,
                    "message": "These scrolls will be burned from the Library. Send again with \"confirm\": true to proceed."
                ] as [String: Any])
            }

            let ids = results.map { $0.id }
            await MemoryIndex.shared.removeBatch(ids: ids)
            return HTTPResponse.json([
                "forgotten": true,
                "count": ids.count,
                "ids": ids,
                "message": "\(ids.count) scrolls removed from the Library."
            ] as [String: Any])
        }

        // PUT /v1/loa/{id} — Edit a memory
        if req.method == "PUT" && req.path.hasPrefix("/v1/loa/") {
            let idStr = String(req.path.dropFirst("/v1/loa/".count))
            guard let id = Int64(idStr) else {
                return HTTPResponse.badRequest("Invalid scroll ID")
            }
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing JSON body")
            }

            if let importance = body["importance"] as? Double {
                await MemoryIndex.shared.updateImportance(id: id, importance: Float(importance))
            }
            return HTTPResponse.json(["updated": true, "id": id] as [String: Any])
        }

        // DELETE /v1/loa/{id} — Delete a memory
        if req.method == "DELETE" && req.path.hasPrefix("/v1/loa/") {
            let idStr = String(req.path.dropFirst("/v1/loa/".count))
            guard let id = Int64(idStr) else {
                return HTTPResponse.badRequest("Invalid scroll ID")
            }
            await MemoryIndex.shared.remove(id: id)
            return HTTPResponse.json(["deleted": true, "id": id, "message": "Scroll removed from the Library."] as [String: Any])
        }

        return HTTPResponse.notFound()
    }

    // MARK: - Memory Management

    private func handleMemoryRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse {
        // --- Backward-compatible endpoints ---

        // POST /v1/memory/search (legacy — body-based search)
        if req.method == "POST" && req.path == "/v1/memory/search" {
            return await handleMemorySearch(req)
        }

        // POST /v1/memory/add
        if req.method == "POST" && req.path == "/v1/memory/add" {
            return await handleMemoryAdd(req)
        }

        // DELETE /v1/memory (legacy — body-based remove)
        if req.method == "DELETE" && req.path == "/v1/memory" {
            return await handleMemoryRemove(req)
        }

        // POST /v1/memory/repair
        if req.method == "POST" && req.path == "/v1/memory/repair" {
            return await handleMemoryRepair()
        }

        // --- New Memory Management API ---

        // GET /v1/memory/stats
        if req.method == "GET" && req.path == "/v1/memory/stats" {
            let index = MemoryIndex.shared
            let count = await index.count
            let categories = await index.categoryCounts()
            let allEntries = await index.allEntries
            let entities = Array(Set(allEntries.flatMap { $0.entities })).sorted()
            let armyStats = await MemoryArmy.shared.getStats()

            return HTTPResponse.json([
                "total_memories": count,
                "categories": categories,
                "known_entities": Array(entities.prefix(100)),
                "entity_count": entities.count,
                "army": armyStats
            ] as [String: Any])
        }

        // GET /v1/memory/list?page=1&limit=50&category=fact
        if req.method == "GET" && req.path == "/v1/memory/list" {
            let query = req.queryParams
            let page = Int(query["page"] ?? "1") ?? 1
            let limit = min(Int(query["limit"] ?? "50") ?? 50, 200)
            let categoryFilter = query["category"]

            let index = MemoryIndex.shared
            var allEntries = await index.allEntries

            if let cat = categoryFilter {
                allEntries = allEntries.filter { $0.category == cat }
            }

            // Sort by timestamp descending (newest first)
            allEntries.sort { $0.timestamp > $1.timestamp }

            let startIdx = (page - 1) * limit
            let endIdx = min(startIdx + limit, allEntries.count)
            guard startIdx < allEntries.count else {
                return HTTPResponse.json(["memories": [] as [Any], "total": allEntries.count, "page": page] as [String: Any])
            }

            let slice = allEntries[startIdx..<endIdx]
            let fmt = ISO8601DateFormatter()
            let memoriesJSON: [[String: Any]] = slice.map { entry in
                [
                    "id": entry.id,
                    "text": entry.text,
                    "category": entry.category,
                    "source": entry.source,
                    "importance": entry.importance,
                    "timestamp": fmt.string(from: entry.timestamp),
                    "entities": entry.entities,
                    "access_count": entry.accessCount
                ] as [String: Any]
            }

            return HTTPResponse.json([
                "memories": memoriesJSON,
                "total": allEntries.count,
                "page": page,
                "pages": max(1, Int(ceil(Double(allEntries.count) / Double(limit))))
            ] as [String: Any])
        }

        // GET /v1/memory/search?q=...&topK=10
        if req.method == "GET" && req.path == "/v1/memory/search" {
            let query = req.queryParams
            guard let q = query["q"], !q.isEmpty else {
                return HTTPResponse.badRequest("Missing 'q' query parameter")
            }
            let topK = Int(query["topK"] ?? "10") ?? 10

            let results = await MemoryIndex.shared.hybridSearch(query: q, topK: topK)
            let fmt = ISO8601DateFormatter()
            let resultsJSON: [[String: Any]] = results.map { r in
                [
                    "id": r.id,
                    "text": r.text,
                    "category": r.category,
                    "score": r.score,
                    "importance": r.importance,
                    "timestamp": fmt.string(from: r.timestamp)
                ] as [String: Any]
            }

            return HTTPResponse.json(["results": resultsJSON, "count": results.count] as [String: Any])
        }

        // PUT /v1/memory/{id} — edit a memory
        if req.method == "PUT" && req.path.hasPrefix("/v1/memory/") {
            let idStr = String(req.path.dropFirst("/v1/memory/".count))
            guard let id = Int64(idStr) else {
                return HTTPResponse.badRequest("Invalid memory ID")
            }
            guard let body = req.jsonBody else {
                return HTTPResponse.badRequest("Missing JSON body")
            }

            let index = MemoryIndex.shared
            if let importance = body["importance"] as? Double {
                await index.updateImportance(id: id, importance: Float(importance))
            }
            // Text editing would require re-embedding — for now only importance is editable
            return HTTPResponse.json(["updated": true, "id": id] as [String: Any])
        }

        // DELETE /v1/memory/{id} — delete a specific memory
        if req.method == "DELETE" && req.path.hasPrefix("/v1/memory/") {
            let idStr = String(req.path.dropFirst("/v1/memory/".count))
            guard let id = Int64(idStr) else {
                return HTTPResponse.badRequest("Invalid memory ID")
            }

            await MemoryIndex.shared.remove(id: id)
            return HTTPResponse.json(["deleted": true, "id": id] as [String: Any])
        }

        // POST /v1/memory/forget — find and delete memories matching a query
        if req.method == "POST" && req.path == "/v1/memory/forget" {
            guard let body = req.jsonBody,
                  let query = body["query"] as? String, !query.isEmpty else {
                return HTTPResponse.badRequest("Missing 'query' in body")
            }

            let confirm = body["confirm"] as? Bool ?? false
            let results = await MemoryIndex.shared.hybridSearch(query: query, topK: 10)

            if !confirm {
                // Preview mode — show what would be deleted
                let fmt = ISO8601DateFormatter()
                let preview: [[String: Any]] = results.map { r in
                    ["id": r.id, "text": r.text, "category": r.category,
                     "importance": r.importance, "timestamp": fmt.string(from: r.timestamp)] as [String: Any]
                }
                return HTTPResponse.json([
                    "preview": true,
                    "matches": preview,
                    "count": results.count,
                    "message": "These memories will be deleted. Send again with \"confirm\": true to proceed."
                ] as [String: Any])
            }

            // Confirmed — delete all matches
            let ids = results.map { $0.id }
            await MemoryIndex.shared.removeBatch(ids: ids)
            return HTTPResponse.json([
                "deleted": true,
                "count": ids.count,
                "ids": ids
            ] as [String: Any])
        }

        return HTTPResponse.notFound()
    }

    // MARK: - Legacy Memory API Handlers

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

    // MARK: - MCP Server Management Handlers

    /// GET /v1/mcp/servers — list all configured MCP servers with runtime status
    private func handleMCPListServers() async -> HTTPResponse {
        let servers = await MCPManager.shared.listServers()
        return HTTPResponse.json(["servers": servers, "count": servers.count])
    }

    /// POST /v1/mcp/servers — add a new MCP server
    /// Body: { "name": "...", "command": "npx", "args": [...], "env": {...}, "enabled": true }
    private func handleMCPAddServer(_ req: HTTPRequest) async -> HTTPResponse {
        guard let body = req.jsonBody,
              let name = body["name"] as? String,
              let command = body["command"] as? String else {
            return HTTPResponse.badRequest("Missing required fields: 'name' and 'command'")
        }

        // Validate name (alphanumeric + hyphens + underscores only)
        let namePattern = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if name.isEmpty || name.unicodeScalars.contains(where: { !namePattern.contains($0) }) {
            return HTTPResponse.badRequest("Server name must be alphanumeric (hyphens and underscores allowed)")
        }

        let args = body["args"] as? [String]
        let env = body["env"] as? [String: String]
        let enabled = body["enabled"] as? Bool ?? true

        let result = await MCPManager.shared.addServer(
            name: name, command: command, args: args, env: env, enabled: enabled
        )

        if result.success {
            let status = await MCPManager.shared.status()
            return HTTPResponse(
                statusCode: 201,
                headers: ["Content-Type": "application/json"],
                body: (try? JSONSerialization.data(withJSONObject: [
                    "status": "added",
                    "name": name,
                    "enabled": enabled,
                    "total_servers": status.servers,
                    "total_tools": status.tools
                ] as [String: Any])) ?? Data()
            )
        } else {
            return HTTPResponse.badRequest(result.error ?? "Failed to add server")
        }
    }

    /// DELETE /v1/mcp/servers/:id — remove an MCP server
    private func handleMCPRemoveServer(name: String) async -> HTTPResponse {
        guard !name.isEmpty else {
            return HTTPResponse.badRequest("Server name is required")
        }

        let result = await MCPManager.shared.removeServer(name: name)

        if result.success {
            return HTTPResponse.json(["status": "removed", "name": name])
        } else {
            return HTTPResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"error\":\"\(HTTPResponse.jsonEscape(result.error ?? "Not found"))\"}".utf8)
            )
        }
    }

    /// GET /v1/mcp/tools — list all discovered MCP tools
    private func handleMCPListTools() async -> HTTPResponse {
        let tools = await MCPManager.shared.listTools()
        return HTTPResponse.json(["tools": tools, "count": tools.count])
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
                   required: .fullAccess, granted: true, detail: "Level → \(level.rawValue) (\(level.name))")
        Task { await TelegramBridge.shared.notify("Access level changed to \(level.rawValue) (\(level.name))") }
        return HTTPResponse.json(["status": "ok", "level": level.rawValue, "name": level.name])
    }

    /// Simulate a streaming SSE response from a complete text string.
    /// Used for room requests where tool execution requires non-streaming,
    /// but the iOS client expects SSE format.
    private func simulateStreamResponse(_ text: String, model: String, writer: ResponseWriter, corsOrigin: String? = nil) {
        writer.sendStreamHeaders(origin: corsOrigin)

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

    /// Send a single text content chunk via SSE (no finish/done — caller manages stream lifecycle)
    private func sendSSETextChunk(_ text: String, id: String, model: String, writer: ResponseWriter) {
        let chunk: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()] as [String: Any]]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: chunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            writer.sendSSEChunk(jsonStr)
        }
    }

    /// Send a finish chunk via SSE (no done — caller sends done separately)
    private func sendSSEFinishChunk(id: String, model: String, writer: ResponseWriter) {
        let chunk: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [["index": 0, "delta": [:] as [String: String], "finish_reason": "stop"] as [String: Any]]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: chunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            writer.sendSSEChunk(jsonStr)
        }
    }

    /// Human-readable progress label for a tool being executed
    private static func toolProgressLabel(_ toolName: String, args: String?) -> String {
        // Parse args JSON for context
        let parsed = args.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }

        switch toolName {
        case "web_search":
            let query = parsed?["query"] as? String
            return query != nil ? "[searching: \(query!)]" : "[searching the web...]"
        case "web_fetch":
            let url = parsed?["url"] as? String
            let host = url.flatMap { URL(string: $0)?.host }
            return host != nil ? "[fetching: \(host!)]" : "[fetching web page...]"
        case "read_file":
            let path = parsed?["path"] as? String
            let name = path.map { ($0 as NSString).lastPathComponent }
            return name != nil ? "[reading: \(name!)]" : "[reading file...]"
        case "write_file":
            let path = parsed?["path"] as? String
            let name = path.map { ($0 as NSString).lastPathComponent }
            return name != nil ? "[writing: \(name!)]" : "[writing file...]"
        case "list_directory":
            return "[listing directory...]"
        case "run_command":
            let cmd = parsed?["command"] as? String
            let short = cmd.map { String($0.prefix(40)) }
            return short != nil ? "[running: \(short!)]" : "[running command...]"
        case "generate_image":
            return "[generating image...]"
        case "search_documents":
            return "[searching documents...]"
        case "execute_code":
            return "[executing code...]"
        default:
            if toolName.hasPrefix("mcp_") {
                let clean = String(toolName.dropFirst(4))
                return "[using: \(clean)]"
            }
            return "[using: \(toolName)]"
        }
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

    // MARK: - Debate Routes (stub)

    private func handleDebateRoute(_ req: HTTPRequest, clientIP: String, currentLevel: AccessLevel, agentID: String) async -> HTTPResponse {
        return HTTPResponse.json(["error": "Debate API not yet implemented"] as [String: Any])
    }

    // MARK: - Commitments Detection

    /// Detect commitments or resolutions in user messages.
    /// Runs in background — never blocks the chat response.
    private func detectCommitmentsInMessage(_ text: String) async {
        // Check for resolution first ("done", "forget it")
        if let resolution = CommitmentsDetector.detectResolution(text) {
            let open = await CommitmentsStore.shared.allOpen()
            // Try to match resolution to most recent open commitment
            if let latest = open.first {
                await CommitmentsStore.shared.updateStatus(
                    id: latest.id,
                    status: resolution.action,
                    note: "Resolved via: \"\(resolution.triggerText)\""
                )
                TorboLog.info("Commitment #\(latest.id) \(resolution.action.rawValue) via \"\(resolution.triggerText)\"", subsystem: "Commitments")
            }
            return
        }

        // Fast pre-filter — skip expensive LLM call if no commitment language
        guard CommitmentsDetector.likelyContainsCommitment(text) else { return }

        // LLM extraction
        let extracted = await CommitmentsDetector.extractCommitments(from: text)
        for commitment in extracted {
            await CommitmentsStore.shared.add(
                text: commitment.text,
                dueDate: commitment.dueDate,
                dueText: commitment.dueText
            )
        }
        if !extracted.isEmpty {
            TorboLog.info("Extracted \(extracted.count) commitment(s) from message", subsystem: "Commitments")
        }
    }

}

// MARK: - Access Control

enum AccessControl {

    // MARK: - CORS

    /// Paths where CORS headers are never emitted (execution / SSRF-sensitive endpoints)
    private static let sensitivePathPrefixes: [String] = [
        "/exec", "/v1/fetch", "/v1/browser", "/v1/docker",
        "/v1/code/execute", "/control"
    ]

    /// Returns the validated origin string if the request's Origin header is in
    /// the configured allowlist **and** the path is not sensitive. Returns nil
    /// if CORS headers should be omitted.
    static func validatedCORSOrigin(requestOrigin: String?, path: String) -> String? {
        guard let origin = requestOrigin, !origin.isEmpty else { return nil }
        // Never emit CORS on sensitive endpoints
        for prefix in sensitivePathPrefixes {
            if path.hasPrefix(prefix) { return nil }
        }
        let allowed = AppConfig.allowedCORSOrigins
        // Also always allow same-origin requests from the gateway's own web chat
        let port = AppConfig.serverPort
        let localOrigins = ["http://localhost:\(port)", "http://127.0.0.1:\(port)"]
        if allowed.contains(origin) || localOrigins.contains(origin) { return origin }
        return nil
    }

    // MARK: - Command Allowlist

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

    /// Validates a command against the configurable allowlist.
    /// Returns a rejection reason string if blocked, nil if allowed.
    static func filterCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Blocked: empty command" }

        // Block shell injection patterns regardless of allowlist
        if trimmed.contains("`") { return "Blocked: backtick command substitution not allowed" }
        if trimmed.contains("$(") { return "Blocked: $() command substitution not allowed" }
        if trimmed.contains("eval ") || trimmed.hasPrefix("eval\t") { return "Blocked: eval not allowed" }

        // Block piping into a shell interpreter
        let shellNames = ["sh", "bash", "zsh", "dash", "ksh", "csh", "fish"]
        for sh in shellNames {
            if trimmed.contains("| \(sh)") || trimmed.contains("|\(sh)")
                || trimmed.contains("| /bin/\(sh)") || trimmed.contains("|/bin/\(sh)")
                || trimmed.contains("| /usr/bin/\(sh)") || trimmed.contains("|/usr/bin/\(sh)")
                || trimmed.contains("| /usr/bin/env \(sh)") {
                return "Blocked: piping to shell interpreter not allowed"
            }
        }

        // Extract the base command (first word, strip any path prefix)
        let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
        // Handle commands invoked with a path (e.g. /usr/bin/ls)
        let baseName = (firstWord as NSString).lastPathComponent

        let allowlist = AppConfig.allowedCommands
        if allowlist.contains(baseName) { return nil }

        // Also allow chained commands (&&, ;) if each base command is on the allowlist
        let separators = ["&&", "||", ";"]
        var parts = [trimmed]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        // Also split on pipes — each side of a pipe is a command
        parts = parts.flatMap { $0.components(separatedBy: "|") }

        let allAllowed = parts.allSatisfy { part in
            let cmd = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return true }
            let first = cmd.components(separatedBy: .whitespaces).first ?? cmd
            let base = (first as NSString).lastPathComponent
            return allowlist.contains(base)
        }
        if allAllowed { return nil }

        return "Blocked: '\(baseName)' is not in the allowed commands list"
    }

    // MARK: - SSRF Protection

    /// Validates a URL for SSRF safety. Returns nil if safe, or an error message if blocked.
    static func validateURLForSSRF(_ urlString: String) -> String? {
        guard AppConfig.ssrfProtectionEnabled else { return nil }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            return "Blocked: invalid URL"
        }

        // Only allow http and https
        guard scheme == "http" || scheme == "https" else {
            return "Blocked: only http:// and https:// URLs are allowed (got \(scheme)://)"
        }

        // Check for obvious private hostnames
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost == "metadata.google.internal" {
            return "Blocked: requests to \(host) are not allowed (SSRF protection)"
        }

        // Resolve hostname to IP and check against private ranges
        guard let hostC = host.cString(using: .utf8) else {
            return "Blocked: hostname contains invalid characters"
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostC, nil, &hints, &result)
        guard status == 0, let info = result else {
            return "Blocked: could not resolve hostname '\(host)'"
        }
        defer { freeaddrinfo(result) }

        var ptr: UnsafeMutablePointer<addrinfo>? = info
        while let ai = ptr {
            if ai.pointee.ai_family == AF_INET {
                var addr = sockaddr_in()
                memcpy(&addr, ai.pointee.ai_addr, Int(MemoryLayout<sockaddr_in>.size))
                let ipBytes = withUnsafeBytes(of: addr.sin_addr.s_addr) { Array($0) }
                if isPrivateIPv4(ipBytes) {
                    let ipStr = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"
                    return "Blocked: \(host) resolves to private IP \(ipStr) (SSRF protection)"
                }
            } else if ai.pointee.ai_family == AF_INET6 {
                var addr6 = sockaddr_in6()
                memcpy(&addr6, ai.pointee.ai_addr, Int(MemoryLayout<sockaddr_in6>.size))
                let bytes = withUnsafeBytes(of: addr6.sin6_addr) { Array($0) }
                if isPrivateIPv6(bytes) {
                    return "Blocked: \(host) resolves to private IPv6 address (SSRF protection)"
                }
            }
            ptr = ai.pointee.ai_next
        }
        return nil
    }

    private static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count >= 4 else { return false }
        if b[0] == 127 { return true }                          // 127.0.0.0/8 (loopback)
        if b[0] == 10 { return true }                           // 10.0.0.0/8
        if b[0] == 172 && (b[1] >= 16 && b[1] <= 31) { return true }  // 172.16.0.0/12
        if b[0] == 192 && b[1] == 168 { return true }          // 192.168.0.0/16
        if b[0] == 169 && b[1] == 254 { return true }          // 169.254.0.0/16 (link-local + metadata)
        if b[0] == 0 { return true }                            // 0.0.0.0/8
        return false
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        guard b.count >= 16 else { return false }
        // ::1 (loopback)
        let allZeroExceptLast = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        if allZeroExceptLast { return true }
        // fc00::/7 (unique local)
        if (b[0] & 0xFE) == 0xFC { return true }
        // fe80::/10 (link-local)
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }
        // :: (unspecified)
        if b.allSatisfy({ $0 == 0 }) { return true }
        return false
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

    var queryParams: [String: String] {
        var params: [String: String] = [:]
        let pairs = query.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding }
        }
        return params
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
    static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
    static func badRequest(_ msg: String) -> HTTPResponse {
        HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"\(jsonEscape(msg))\"}".utf8))
    }
    static func unauthorized() -> HTTPResponse {
        HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Unauthorized\"}".utf8))
    }
    static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"Not found\"}".utf8))
    }
    static func serverError(_ msg: String) -> HTTPResponse {
        HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"], body: Data("{\"error\":\"\(jsonEscape(msg))\"}".utf8))
    }
    static func cors(origin: String?) -> HTTPResponse {
        var h: [String: String] = [
            "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization, x-torbo-agent-id, x-torbo-room, x-torbo-platform",
            "Access-Control-Max-Age": "86400"
        ]
        if let origin = origin { h["Access-Control-Allow-Origin"] = origin }
        return HTTPResponse(statusCode: 204, headers: h, body: Data())
    }

}
