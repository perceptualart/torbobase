// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Full Sync API (Base ↔ iOS)
import Foundation

// MARK: - Per-Device Sync State

actor SyncState {
    static let shared = SyncState()

    struct DeviceSyncInfo: Codable {
        let deviceID: String
        var lastPullTimestamp: Date
        var lastPushTimestamp: Date
        var messagesPushed: Int
        var messagesPulled: Int
    }

    private var devices: [String: DeviceSyncInfo] = [:]
    private let stateFile: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = PlatformPaths.appSupportDir
        let dir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        stateFile = dir.appendingPathComponent("sync_state.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        do {
            let data = try Data(contentsOf: stateFile)
            devices = try decoder.decode([String: DeviceSyncInfo].self, from: data)
        } catch {
            TorboLog.error("Failed to load sync state: \(error)", subsystem: "Sync")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(devices)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            TorboLog.error("Failed to save sync state: \(error)", subsystem: "Sync")
        }
    }

    func info(for deviceID: String) -> DeviceSyncInfo? {
        devices[deviceID]
    }

    func recordPull(deviceID: String, count: Int) {
        var info = devices[deviceID] ?? DeviceSyncInfo(
            deviceID: deviceID, lastPullTimestamp: Date(), lastPushTimestamp: .distantPast,
            messagesPushed: 0, messagesPulled: 0
        )
        info.lastPullTimestamp = Date()
        info.messagesPulled += count
        devices[deviceID] = info
        save()
    }

    func recordPush(deviceID: String, count: Int) {
        var info = devices[deviceID] ?? DeviceSyncInfo(
            deviceID: deviceID, lastPullTimestamp: .distantPast, lastPushTimestamp: Date(),
            messagesPushed: 0, messagesPulled: 0
        )
        info.lastPushTimestamp = Date()
        info.messagesPushed += count
        devices[deviceID] = info
        save()
    }
}

// MARK: - Sync API Routes

extension GatewayServer {

    func handleSyncRoute(_ req: HTTPRequest, clientIP: String) async -> HTTPResponse? {
        let path = req.path
        let method = req.method
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let serverTime = iso.string(from: Date())

        // Resolve device ID from Bearer token
        let token: String? = {
            guard let auth = req.headers["authorization"] ?? req.headers["Authorization"] else { return nil }
            return auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        }()
        let deviceID = token.flatMap { PairedDeviceStore.deviceID(forToken: $0) }

        // GET /v1/sync/status — health + per-device sync state + category counts
        if method == "GET" && path == "/v1/sync/status" {
            let msgCount = await ConversationStore.shared.messageCount()
            let sessionCount = await ConversationStore.shared.loadSessions().count
            let agentCount = await AgentConfigManager.shared.listAgents().count
            let serviceCount = KeychainManager.getAllAPIKeys().filter({ !$0.value.isEmpty }).count

            var json: [String: Any] = [
                "status": "ok",
                "server_time": serverTime,
                "messages_on_server": msgCount,
                "sessions_on_server": sessionCount,
                "counts": [
                    "messages": msgCount,
                    "sessions": sessionCount,
                    "agents": agentCount,
                    "services": serviceCount
                ] as [String: Any]
            ]

            if let did = deviceID {
                json["device_id"] = did
                if let info = await SyncState.shared.info(for: did) {
                    json["last_pull"] = iso.string(from: info.lastPullTimestamp)
                    json["last_push"] = iso.string(from: info.lastPushTimestamp)
                    json["messages_pulled"] = info.messagesPulled
                    json["messages_pushed"] = info.messagesPushed
                }
            }

            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // GET /v1/sync/conversations — list sessions with optional filters
        if method == "GET" && path == "/v1/sync/conversations" {
            var sessions = await ConversationStore.shared.loadSessions()

            // Filter by agent_id
            if let agentFilter = req.queryParam("agent_id") {
                sessions = sessions.filter { $0.agentID == agentFilter }
            }

            // Filter by since timestamp
            if let sinceStr = req.queryParam("since"), let sinceDate = iso.date(from: sinceStr) {
                sessions = sessions.filter { $0.lastActivity >= sinceDate }
            }

            // Sort by most recent first
            sessions.sort { $0.lastActivity > $1.lastActivity }

            // Pagination
            let limit = min(Int(req.queryParam("limit") ?? "100") ?? 100, 1000)
            let offset = Int(req.queryParam("offset") ?? "0") ?? 0
            let paged = Array(sessions.dropFirst(offset).prefix(limit))

            let items: [[String: Any]] = paged.map { s in
                [
                    "id": s.id.uuidString,
                    "started_at": iso.string(from: s.startedAt),
                    "last_activity": iso.string(from: s.lastActivity),
                    "message_count": s.messageCount,
                    "model": s.model,
                    "title": s.title,
                    "agent_id": s.agentID
                ]
            }

            let json: [String: Any] = [
                "conversations": items,
                "count": items.count,
                "total": sessions.count,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // GET /v1/sync/messages — delta sync (messages since timestamp)
        if method == "GET" && path == "/v1/sync/messages" {
            guard let sinceStr = req.queryParam("since"), let sinceDate = iso.date(from: sinceStr) else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing required 'since' query parameter (ISO8601)\"}".utf8))
            }

            var messages = await ConversationStore.shared.loadMessages()

            // Filter by timestamp
            messages = messages.filter { $0.timestamp >= sinceDate }

            // Filter by agent_id
            if let agentFilter = req.queryParam("agent_id") {
                messages = messages.filter { $0.agentID == agentFilter || (agentFilter == "sid" && $0.agentID == nil) }
            }

            // Sort chronologically
            messages.sort { $0.timestamp < $1.timestamp }

            // Limit (cap at 1000)
            let limit = min(Int(req.queryParam("limit") ?? "500") ?? 500, 1000)
            let hasMore = messages.count > limit
            let paged = Array(messages.prefix(limit))

            let items: [[String: Any]] = paged.map { m in
                [
                    "id": m.id.uuidString,
                    "role": m.role,
                    "content": m.content,
                    "model": m.model,
                    "timestamp": iso.string(from: m.timestamp),
                    "agent_id": m.agentID ?? "sid"
                ]
                // clientIP intentionally stripped for privacy
            }

            // Track pull in sync state
            if let did = deviceID {
                await SyncState.shared.recordPull(deviceID: did, count: paged.count)
            }

            let json: [String: Any] = [
                "messages": items,
                "count": items.count,
                "has_more": hasMore,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // POST /v1/sync/messages — receive batch from iOS
        if method == "POST" && path == "/v1/sync/messages" {
            guard let body = req.jsonBody,
                  let rawMessages = body["messages"] as? [[String: Any]] else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing 'messages' array in body\"}".utf8))
            }

            guard rawMessages.count <= 100 else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Max 100 messages per request\"}".utf8))
            }

            // Collect incoming IDs for batch dedup
            var incomingIDs: [String] = []
            for raw in rawMessages {
                if let idStr = raw["id"] as? String {
                    incomingIDs.append(idStr)
                }
            }

            // Batch check which already exist
            let existingIDs = await ConversationSearch.shared.existingMessageIDs(from: incomingIDs)

            var accepted = 0
            var duplicates = 0
            var errors = 0

            for raw in rawMessages {
                guard let idStr = raw["id"] as? String,
                      let uuid = UUID(uuidString: idStr),
                      let role = raw["role"] as? String,
                      let content = raw["content"] as? String else {
                    errors += 1
                    continue
                }

                // Skip duplicates
                if existingIDs.contains(idStr) {
                    duplicates += 1
                    continue
                }

                let model = raw["model"] as? String ?? ""
                let agentID = raw["agent_id"] as? String ?? "sid"

                // Parse timestamp
                let timestamp: Date
                if let tsStr = raw["timestamp"] as? String, let parsed = iso.date(from: tsStr) {
                    timestamp = parsed
                } else {
                    timestamp = Date()
                }

                let msg = ConversationMessage(
                    id: uuid, role: role, content: content,
                    model: model, timestamp: timestamp, agentID: agentID
                )

                await MainActor.run {
                    AppState.shared.addMessage(msg)
                }
                accepted += 1
            }

            // Track push in sync state
            if let did = deviceID, accepted > 0 {
                await SyncState.shared.recordPush(deviceID: did, count: accepted)
            }

            TorboLog.info("Sync push: \(accepted) accepted, \(duplicates) duplicates, \(errors) errors", subsystem: "Sync")

            let json: [String: Any] = [
                "accepted": accepted,
                "duplicates": duplicates,
                "errors": errors,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // POST /v1/sync/conversation — create or update session from iOS
        if method == "POST" && path == "/v1/sync/conversation" {
            guard let body = req.jsonBody,
                  let idStr = body["id"] as? String,
                  let uuid = UUID(uuidString: idStr) else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing or invalid 'id' (UUID)\"}".utf8))
            }

            let model = body["model"] as? String ?? "unknown"
            let title = body["title"] as? String ?? "New Session"
            let agentID = body["agent_id"] as? String ?? "sid"
            let messageCount = body["message_count"] as? Int ?? 0

            // Parse dates
            let startedAt: Date
            if let ts = body["started_at"] as? String, let d = iso.date(from: ts) {
                startedAt = d
            } else {
                startedAt = Date()
            }

            let lastActivity: Date
            if let ts = body["last_activity"] as? String, let d = iso.date(from: ts) {
                lastActivity = d
            } else {
                lastActivity = Date()
            }

            // Load existing sessions and check for merge
            var sessions = await ConversationStore.shared.loadSessions()
            var status = "created"

            if let idx = sessions.firstIndex(where: { $0.id == uuid }) {
                // Merge: higher lastActivity wins, higher messageCount wins
                var existing = sessions[idx]
                if lastActivity > existing.lastActivity {
                    existing.lastActivity = lastActivity
                }
                if messageCount > existing.messageCount {
                    existing.messageCount = messageCount
                }
                if !title.isEmpty && title != "New Session" {
                    existing.title = title
                }
                if !model.isEmpty && model != "unknown" {
                    existing.model = model
                }
                sessions[idx] = existing
                status = "updated"
            } else {
                // Create new session with provided UUID
                let session = ConversationSession(
                    id: uuid, startedAt: startedAt, lastActivity: lastActivity,
                    messageCount: messageCount, model: model, title: title, agentID: agentID
                )
                sessions.append(session)
            }

            await ConversationStore.shared.saveSessions(sessions)

            // Also update in-memory sessions on MainActor
            let finalStatus = status
            let finalSessions = sessions
            await MainActor.run {
                AppState.shared.sessions = finalSessions
            }

            TorboLog.info("Sync session \(status): \(uuid.uuidString)", subsystem: "Sync")

            let json: [String: Any] = [
                "status": finalStatus,
                "id": uuid.uuidString,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // =====================================================================
        // MARK: — Agents Sync
        // =====================================================================

        // GET /v1/sync/agents — return all agent configs
        if method == "GET" && path == "/v1/sync/agents" {
            let agents = await AgentConfigManager.shared.listAgents()

            // Optional ?since=ISO8601 filter
            let sinceDate: Date? = {
                guard let s = req.queryParam("since") else { return nil }
                return iso.date(from: s)
            }()

            let syncEncoder = JSONEncoder()
            syncEncoder.dateEncodingStrategy = .iso8601
            syncEncoder.keyEncodingStrategy = .convertToSnakeCase

            var items: [[String: Any]] = []
            for agent in agents {
                if let since = sinceDate, let mod = agent.lastModifiedAt, mod < since { continue }
                if let data = try? syncEncoder.encode(agent),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    items.append(dict)
                }
            }

            let json: [String: Any] = [
                "agents": items,
                "count": items.count,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // POST /v1/sync/agents — push agents from iOS (batch create/update)
        if method == "POST" && path == "/v1/sync/agents" {
            guard let body = req.jsonBody,
                  let rawAgents = body["agents"] as? [[String: Any]] else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing 'agents' array in body\"}".utf8))
            }

            let syncDecoder = JSONDecoder()
            syncDecoder.dateDecodingStrategy = .iso8601
            syncDecoder.keyDecodingStrategy = .convertFromSnakeCase

            var accepted = 0, updated = 0, skipped = 0, errors = 0

            for raw in rawAgents {
                guard let rawData = try? JSONSerialization.data(withJSONObject: raw),
                      let incoming = try? syncDecoder.decode(AgentConfig.self, from: rawData) else {
                    errors += 1
                    continue
                }

                if let existing = await AgentConfigManager.shared.agent(incoming.id) {
                    // Compare lastModifiedAt — later wins
                    let existingMod = existing.lastModifiedAt ?? .distantPast
                    let incomingMod = incoming.lastModifiedAt ?? .distantPast
                    if incomingMod > existingMod {
                        await AgentConfigManager.shared.updateAgent(incoming)
                        updated += 1
                    } else {
                        skipped += 1
                    }
                } else {
                    // New agent — create
                    do {
                        try await AgentConfigManager.shared.createAgent(incoming)
                        accepted += 1
                    } catch {
                        errors += 1
                    }
                }
            }

            TorboLog.info("Sync agents push: \(accepted) created, \(updated) updated, \(skipped) skipped, \(errors) errors", subsystem: "Sync")

            let json: [String: Any] = [
                "accepted": accepted,
                "updated": updated,
                "skipped": skipped,
                "errors": errors,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // PUT /v1/sync/agents/{id} — update single agent
        if method == "PUT" && path.hasPrefix("/v1/sync/agents/") {
            let agentID = String(path.dropFirst("/v1/sync/agents/".count))
            guard !agentID.isEmpty else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing agent ID in path\"}".utf8))
            }

            guard let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing JSON body\"}".utf8))
            }

            let syncDecoder = JSONDecoder()
            syncDecoder.dateDecodingStrategy = .iso8601
            syncDecoder.keyDecodingStrategy = .convertFromSnakeCase

            guard let rawData = try? JSONSerialization.data(withJSONObject: body),
                  let incoming = try? syncDecoder.decode(AgentConfig.self, from: rawData) else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Invalid agent config JSON\"}".utf8))
            }

            guard let existing = await AgentConfigManager.shared.agent(agentID) else {
                return HTTPResponse(statusCode: 404, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Agent not found\"}".utf8))
            }

            // Compare lastModifiedAt — later wins
            let existingMod = existing.lastModifiedAt ?? .distantPast
            let incomingMod = incoming.lastModifiedAt ?? .distantPast

            if incomingMod > existingMod {
                await AgentConfigManager.shared.updateAgent(incoming)
                let json: [String: Any] = ["status": "updated", "agent_id": agentID, "server_time": serverTime]
                let data = try? JSONSerialization.data(withJSONObject: json)
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
            } else {
                let json: [String: Any] = ["status": "skipped", "reason": "server_version_newer", "agent_id": agentID, "server_time": serverTime]
                let data = try? JSONSerialization.data(withJSONObject: json)
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
            }
        }

        // =====================================================================
        // MARK: — Settings Sync
        // =====================================================================

        // GET /v1/sync/settings — all syncable settings
        if method == "GET" && path == "/v1/sync/settings" {
            let settings: [String: Any] = await MainActor.run {
                let s = AppState.shared
                return [
                    "access_level": s.accessLevel.rawValue,
                    "rate_limit": s.rateLimit,
                    "max_concurrent_tasks": s.maxConcurrentTasks,
                    "system_prompt_enabled": s.systemPromptEnabled,
                    "system_prompt": s.systemPrompt,
                    "memory_enabled": AppConfig.memoryEnabled,
                    "proactive_agent_enabled": s.proactiveAgentEnabled,
                    "voice_engine": s.voiceEngineType,
                    "elevenlabs_voice_id": s.elevenLabsVoiceID,
                    "auto_listen": s.autoListen,
                    "silence_threshold": s.silenceThreshold,
                    "log_level": s.logLevel,
                    "sandbox_paths": AppConfig.sandboxPaths,
                    "global_capabilities": s.globalCapabilities
                ] as [String: Any]
            }

            let json: [String: Any] = [
                "settings": settings,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // PUT /v1/sync/settings — update settings from iOS (partial update)
        if method == "PUT" && path == "/v1/sync/settings" {
            guard let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing JSON body\"}".utf8))
            }

            var applied: [String] = []

            await MainActor.run {
                let s = AppState.shared

                if let v = body["access_level"] as? Int, let level = AccessLevel(rawValue: v) {
                    s.accessLevel = level; applied.append("access_level")
                }
                if let v = body["rate_limit"] as? Int {
                    s.rateLimit = v; AppConfig.rateLimit = v; applied.append("rate_limit")
                }
                if let v = body["max_concurrent_tasks"] as? Int {
                    s.maxConcurrentTasks = v; applied.append("max_concurrent_tasks")
                }
                if let v = body["system_prompt_enabled"] as? Bool {
                    s.systemPromptEnabled = v; applied.append("system_prompt_enabled")
                }
                if let v = body["system_prompt"] as? String {
                    s.systemPrompt = v; applied.append("system_prompt")
                }
                if let v = body["memory_enabled"] as? Bool {
                    AppConfig.memoryEnabled = v; applied.append("memory_enabled")
                }
                if let v = body["proactive_agent_enabled"] as? Bool {
                    s.proactiveAgentEnabled = v; applied.append("proactive_agent_enabled")
                }
                if let v = body["voice_engine"] as? String {
                    s.voiceEngineType = v; applied.append("voice_engine")
                }
                if let v = body["elevenlabs_voice_id"] as? String {
                    s.elevenLabsVoiceID = v; applied.append("elevenlabs_voice_id")
                }
                if let v = body["auto_listen"] as? Bool {
                    s.autoListen = v; applied.append("auto_listen")
                }
                if let v = body["silence_threshold"] as? Double {
                    s.silenceThreshold = v; applied.append("silence_threshold")
                }
                if let v = body["log_level"] as? String {
                    s.logLevel = v; applied.append("log_level")
                }
                if let v = body["sandbox_paths"] as? [String] {
                    AppConfig.sandboxPaths = v; applied.append("sandbox_paths")
                }
                if let v = body["global_capabilities"] as? [String: Bool] {
                    s.globalCapabilities = v; applied.append("global_capabilities")
                }
            }

            if !applied.isEmpty {
                Task { await EventBus.shared.publish("sync.settings.changed", payload: ["keys": applied.joined(separator: ",")], source: "base") }
            }

            TorboLog.info("Sync settings: applied \(applied.count) key(s): \(applied.joined(separator: ", "))", subsystem: "Sync")

            let json: [String: Any] = [
                "applied": applied,
                "count": applied.count,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // =====================================================================
        // MARK: — Services & Credentials Sync
        // =====================================================================

        // GET /v1/sync/services — all service configs + credentials
        if method == "GET" && path == "/v1/sync/services" {
            let apiKeys = KeychainManager.getAllAPIKeys()
            let telegramCfg = TelegramConfig.stored
            let channelCfg = await ChannelManager.shared.loadConfig()

            var channels: [String: Any] = [:]

            // Telegram
            channels["telegram"] = [
                "enabled": telegramCfg.enabled,
                "bot_token": telegramCfg.botToken,
                "chat_id": telegramCfg.chatId
            ] as [String: Any]

            // Discord
            channels["discord"] = [
                "enabled": channelCfg.discordBotToken != nil && !(channelCfg.discordBotToken?.isEmpty ?? true),
                "bot_token": channelCfg.discordBotToken ?? "",
                "channel_id": channelCfg.discordChannelID ?? ""
            ] as [String: Any]

            // Slack
            channels["slack"] = [
                "enabled": channelCfg.slackBotToken != nil && !(channelCfg.slackBotToken?.isEmpty ?? true),
                "bot_token": channelCfg.slackBotToken ?? "",
                "channel_id": channelCfg.slackChannelID ?? "",
                "bot_user_id": channelCfg.slackBotUserID ?? ""
            ] as [String: Any]

            // WhatsApp
            channels["whatsapp"] = [
                "enabled": channelCfg.whatsappAccessToken != nil && !(channelCfg.whatsappAccessToken?.isEmpty ?? true),
                "access_token": channelCfg.whatsappAccessToken ?? "",
                "phone_number_id": channelCfg.whatsappPhoneNumberID ?? "",
                "verify_token": channelCfg.whatsappVerifyToken ?? ""
            ] as [String: Any]

            // Signal
            channels["signal"] = [
                "enabled": channelCfg.signalPhoneNumber != nil && !(channelCfg.signalPhoneNumber?.isEmpty ?? true),
                "phone_number": channelCfg.signalPhoneNumber ?? "",
                "api_url": channelCfg.signalAPIURL ?? ""
            ] as [String: Any]

            // iMessage
            channels["imessage"] = [
                "enabled": channelCfg.imessageEnabled ?? false,
                "recipient": channelCfg.imessageRecipient ?? ""
            ] as [String: Any]

            // Email
            channels["email"] = [
                "enabled": channelCfg.emailFromAddress != nil && !(channelCfg.emailFromAddress?.isEmpty ?? true),
                "from_address": channelCfg.emailFromAddress ?? "",
                "smtp_host": channelCfg.emailSmtpHost ?? "",
                "smtp_port": channelCfg.emailSmtpPort ?? 587,
                "smtp_user": channelCfg.emailSmtpUser ?? ""
            ] as [String: Any]

            // Teams
            channels["teams"] = [
                "enabled": channelCfg.teamsAppID != nil && !(channelCfg.teamsAppID?.isEmpty ?? true),
                "app_id": channelCfg.teamsAppID ?? ""
            ] as [String: Any]

            // Google Chat
            channels["googlechat"] = [
                "enabled": channelCfg.googleChatServiceAccountKey != nil && !(channelCfg.googleChatServiceAccountKey?.isEmpty ?? true)
            ] as [String: Any]

            // Matrix
            channels["matrix"] = [
                "enabled": channelCfg.matrixHomeserver != nil && !(channelCfg.matrixHomeserver?.isEmpty ?? true),
                "homeserver": channelCfg.matrixHomeserver ?? "",
                "bot_user_id": channelCfg.matrixBotUserID ?? ""
            ] as [String: Any]

            // SMS
            channels["sms"] = [
                "enabled": channelCfg.twilioAccountSID != nil && !(channelCfg.twilioAccountSID?.isEmpty ?? true),
                "phone_number": channelCfg.twilioPhoneNumber ?? ""
            ] as [String: Any]

            let json: [String: Any] = [
                "api_keys": apiKeys,
                "channels": channels,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // PUT /v1/sync/services — update API keys and channel configs from iOS
        if method == "PUT" && path == "/v1/sync/services" {
            guard let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing JSON body\"}".utf8))
            }

            var applied: [String] = []

            // API Keys — merge incoming with existing
            if let incomingKeys = body["api_keys"] as? [String: String] {
                var current = KeychainManager.getAllAPIKeys()
                for (key, value) in incomingKeys {
                    current[key] = value
                }
                KeychainManager.setAllAPIKeys(current)
                await MainActor.run { AppState.shared.cloudAPIKeys = KeychainManager.getAllAPIKeys() }
                applied.append("api_keys")
            }

            // Telegram
            if let tg = body["telegram"] as? [String: Any] ?? (body["channels"] as? [String: Any])?["telegram"] as? [String: Any] {
                var cfg = TelegramConfig.stored
                if let v = tg["bot_token"] as? String { cfg.botToken = v }
                if let v = tg["chat_id"] as? String { cfg.chatId = v }
                if let v = tg["enabled"] as? Bool { cfg.enabled = v }
                TelegramConfig.stored = cfg
                await MainActor.run { AppState.shared.telegramConfig = cfg }
                applied.append("telegram")
            }

            // Channel config — load, merge, save
            if let channelsDict = body["channels"] as? [String: Any] {
                var cfg = await ChannelManager.shared.loadConfig()

                if let d = channelsDict["discord"] as? [String: Any] {
                    if let v = d["bot_token"] as? String { cfg.discordBotToken = v }
                    if let v = d["channel_id"] as? String { cfg.discordChannelID = v }
                    applied.append("discord")
                }
                if let d = channelsDict["slack"] as? [String: Any] {
                    if let v = d["bot_token"] as? String { cfg.slackBotToken = v }
                    if let v = d["channel_id"] as? String { cfg.slackChannelID = v }
                    if let v = d["bot_user_id"] as? String { cfg.slackBotUserID = v }
                    applied.append("slack")
                }
                if let d = channelsDict["whatsapp"] as? [String: Any] {
                    if let v = d["access_token"] as? String { cfg.whatsappAccessToken = v }
                    if let v = d["phone_number_id"] as? String { cfg.whatsappPhoneNumberID = v }
                    if let v = d["verify_token"] as? String { cfg.whatsappVerifyToken = v }
                    applied.append("whatsapp")
                }
                if let d = channelsDict["signal"] as? [String: Any] {
                    if let v = d["phone_number"] as? String { cfg.signalPhoneNumber = v }
                    if let v = d["api_url"] as? String { cfg.signalAPIURL = v }
                    applied.append("signal")
                }
                if let d = channelsDict["imessage"] as? [String: Any] {
                    if let v = d["enabled"] as? Bool { cfg.imessageEnabled = v }
                    if let v = d["recipient"] as? String { cfg.imessageRecipient = v }
                    applied.append("imessage")
                }
                if let d = channelsDict["email"] as? [String: Any] {
                    if let v = d["from_address"] as? String { cfg.emailFromAddress = v }
                    if let v = d["smtp_host"] as? String { cfg.emailSmtpHost = v }
                    if let v = d["smtp_port"] as? Int { cfg.emailSmtpPort = v }
                    if let v = d["smtp_user"] as? String { cfg.emailSmtpUser = v }
                    if let v = d["smtp_pass"] as? String { cfg.emailSmtpPass = v }
                    applied.append("email")
                }
                if let d = channelsDict["teams"] as? [String: Any] {
                    if let v = d["app_id"] as? String { cfg.teamsAppID = v }
                    if let v = d["app_secret"] as? String { cfg.teamsAppSecret = v }
                    applied.append("teams")
                }
                if let d = channelsDict["googlechat"] as? [String: Any] {
                    if let v = d["service_account_key"] as? String { cfg.googleChatServiceAccountKey = v }
                    applied.append("googlechat")
                }
                if let d = channelsDict["matrix"] as? [String: Any] {
                    if let v = d["homeserver"] as? String { cfg.matrixHomeserver = v }
                    if let v = d["access_token"] as? String { cfg.matrixAccessToken = v }
                    if let v = d["bot_user_id"] as? String { cfg.matrixBotUserID = v }
                    applied.append("matrix")
                }
                if let d = channelsDict["sms"] as? [String: Any] {
                    if let v = d["account_sid"] as? String { cfg.twilioAccountSID = v }
                    if let v = d["auth_token"] as? String { cfg.twilioAuthToken = v }
                    if let v = d["phone_number"] as? String { cfg.twilioPhoneNumber = v }
                    applied.append("sms")
                }

                await ChannelManager.shared.saveConfig(cfg)
            }

            if !applied.isEmpty {
                Task { await EventBus.shared.publish("sync.services.changed", payload: ["keys": applied.joined(separator: ",")], source: "base") }
            }

            TorboLog.info("Sync services: applied \(applied.count) section(s): \(applied.joined(separator: ", "))", subsystem: "Sync")

            let json: [String: Any] = [
                "applied": applied,
                "count": applied.count,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // =====================================================================
        // MARK: — User Profile Sync
        // =====================================================================

        // GET /v1/sync/profile — return user profile
        if method == "GET" && path == "/v1/sync/profile" {
            let profile = await ConversationStore.shared.loadProfile()
            let profileDict: [String: Any] = [
                "name": profile.name,
                "created_at": iso.string(from: profile.createdAt),
                "last_modified_at": iso.string(from: profile.lastModifiedAt)
            ]
            let json: [String: Any] = [
                "profile": profileDict,
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        // PUT /v1/sync/profile — update user profile
        if method == "PUT" && path == "/v1/sync/profile" {
            guard let body = req.jsonBody else {
                return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                    body: Data("{\"error\":\"Missing JSON body\"}".utf8))
            }

            var profile = await ConversationStore.shared.loadProfile()

            if let name = body["name"] as? String {
                profile.name = name
            }
            profile.lastModifiedAt = Date()

            await ConversationStore.shared.saveProfile(profile)
            await MainActor.run { AppState.shared.userProfile = profile }

            TorboLog.info("Sync profile updated: \(profile.name)", subsystem: "Sync")

            let json: [String: Any] = [
                "status": "updated",
                "profile": [
                    "name": profile.name,
                    "created_at": iso.string(from: profile.createdAt),
                    "last_modified_at": iso.string(from: profile.lastModifiedAt)
                ] as [String: Any],
                "server_time": serverTime
            ]
            let data = try? JSONSerialization.data(withJSONObject: json)
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data ?? Data())
        }

        return nil // Not a sync route
    }
}
