// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Conversation persistence — stores messages and sessions to disk
import Foundation

// MARK: - Agent Chat Message (Codable, per-agent persistence)

struct AgentChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date

    init(role: String, content: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// Manages persistent storage of conversations on disk.
/// Data lives in ~/Library/Application Support/TorboBase/
actor ConversationStore {
    static let shared = ConversationStore()

    private let storageDir: URL
    private let messagesFile: URL
    private let sessionsFile: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // In-memory buffer for batched writes
    private var pendingMessages: [ConversationMessage] = []
    private var writeTask: Task<Void, Never>?
    private let batchInterval: TimeInterval = 5.0 // Write every 5 seconds

    init() {
        let appSupport = PlatformPaths.appSupportDir
        storageDir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        messagesFile = storageDir.appendingPathComponent("messages.jsonl")
        sessionsFile = storageDir.appendingPathComponent("sessions.json")

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        TorboLog.info("Data directory: \(storageDir.path)", subsystem: "ConvStore")
    }

    /// Per-user initializer for cloud multi-tenant isolation
    init(storageDir customDir: URL) {
        storageDir = customDir
        messagesFile = customDir.appendingPathComponent("messages.jsonl")
        sessionsFile = customDir.appendingPathComponent("sessions.json")

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
    }

    // MARK: - Messages

    /// Append a message (buffered, writes in batches)
    func appendMessage(_ message: ConversationMessage) {
        pendingMessages.append(message)

        // Schedule a batched write if not already pending
        if writeTask == nil {
            writeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000))
                await self?.flushMessages()
            }
        }
    }

    /// Force write any pending messages to disk (encrypted at rest)
    func flushMessages() {
        guard !pendingMessages.isEmpty else { return }

        let toWrite = pendingMessages
        pendingMessages.removeAll()
        writeTask = nil

        // M5: Encrypt each message line independently (preserves append-only pattern)
        var lines = ""
        for msg in toWrite {
            if let data = try? encoder.encode(msg) {
                if let encrypted = KeychainManager.encryptData(data) {
                    lines += encrypted.base64EncodedString() + "\n"
                } else {
                    // Never fall back to plaintext — drop the message and log the failure
                    TorboLog.error("Encryption failed — dropping message to protect privacy", subsystem: "ConvStore")
                }
            }
        }

        guard !lines.isEmpty else { return }

        if FileManager.default.fileExists(atPath: messagesFile.path) {
            if let handle = try? FileHandle(forWritingTo: messagesFile) {
                handle.seekToEndOfFile()
                if let data = lines.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            do {
                try lines.write(to: messagesFile, atomically: true, encoding: .utf8)
            } catch {
                TorboLog.error("Failed to create messages file: \(error)", subsystem: "ConvStore")
            }
        }

        TorboLog.info("Flushed \(toWrite.count) messages to disk (encrypted)", subsystem: "ConvStore")
    }

    /// Load all messages from disk (handles encrypted + legacy plaintext lines)
    func loadMessages() -> [ConversationMessage] {
        guard FileManager.default.fileExists(atPath: messagesFile.path) else { return [] }

        do {
            let content = try String(contentsOf: messagesFile, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            var messages: [ConversationMessage] = []
            for line in lines {
                // Try encrypted line first (base64 → decrypt → JSON)
                if let b64Data = Data(base64Encoded: line),
                   let decrypted = KeychainManager.decryptData(b64Data),
                   let msg = try? decoder.decode(ConversationMessage.self, from: decrypted) {
                    messages.append(msg)
                }
                // Fallback: legacy plaintext JSON line
                else if let data = line.data(using: .utf8),
                        let msg = try? decoder.decode(ConversationMessage.self, from: data) {
                    messages.append(msg)
                }
            }
            TorboLog.info("Loaded \(messages.count) messages from disk", subsystem: "ConvStore")
            return messages
        } catch {
            TorboLog.error("Failed to load messages: \(error)", subsystem: "ConvStore")
            return []
        }
    }

    /// Load only the most recent N messages
    func loadRecentMessages(count: Int = 200) -> [ConversationMessage] {
        let all = loadMessages()
        return Array(all.suffix(count))
    }

    /// Get message count without loading everything
    func messageCount() -> Int {
        guard FileManager.default.fileExists(atPath: messagesFile.path),
              let content = try? String(contentsOf: messagesFile, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    // MARK: - Sessions

    /// Save sessions to disk
    func saveSessions(_ sessions: [ConversationSession]) {
        do {
            let data = try encoder.encode(sessions)
            try data.write(to: sessionsFile, options: .atomic)
        } catch {
            TorboLog.error("Failed to save sessions: \(error)", subsystem: "ConvStore")
        }
    }

    /// Load sessions from disk
    func loadSessions() -> [ConversationSession] {
        guard FileManager.default.fileExists(atPath: sessionsFile.path) else { return [] }
        do {
            let data = try Data(contentsOf: sessionsFile)
            return try decoder.decode([ConversationSession].self, from: data)
        } catch {
            TorboLog.error("Failed to load sessions: \(error)", subsystem: "ConvStore")
            return []
        }
    }

    // MARK: - User Profile

    private var profileFile: URL {
        storageDir.appendingPathComponent("profile.json")
    }

    /// Load user profile from disk
    func loadProfile() -> UserProfile {
        guard FileManager.default.fileExists(atPath: profileFile.path) else {
            return UserProfile()
        }
        do {
            let data = try Data(contentsOf: profileFile)
            return try decoder.decode(UserProfile.self, from: data)
        } catch {
            TorboLog.error("Failed to load profile: \(error)", subsystem: "ConvStore")
            return UserProfile()
        }
    }

    /// Save user profile to disk
    func saveProfile(_ profile: UserProfile) {
        do {
            let data = try encoder.encode(profile)
            try data.write(to: profileFile, options: .atomic)
        } catch {
            TorboLog.error("Failed to save profile: \(error)", subsystem: "ConvStore")
        }
    }

    // MARK: - Maintenance

    /// Get total storage size in bytes
    func storageSizeBytes() -> Int64 {
        var total: Int64 = 0
        for file in [messagesFile, sessionsFile] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// Human-readable storage size
    func storageSizeFormatted() -> String {
        let bytes = storageSizeBytes()
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Clear all stored conversations
    func clearAll() {
        pendingMessages.removeAll()
        writeTask?.cancel()
        writeTask = nil
        try? FileManager.default.removeItem(at: messagesFile)
        try? FileManager.default.removeItem(at: sessionsFile)
        TorboLog.info("Cleared all conversation data", subsystem: "ConvStore")
    }

    /// Export conversations as a JSON file, returns the file URL
    func exportConversations() -> URL? {
        let messages = loadMessages()
        let sessions = loadSessions()

        // Write combined export
        let exportFile = storageDir.appendingPathComponent("torbo-base-export-\(dateStamp()).json")

        struct ExportData: Codable {
            let version: String
            let exportedAt: Date
            let messages: [ConversationMessage]
            let sessions: [ConversationSession]
        }

        let data = ExportData(
            version: TorboVersion.current,
            exportedAt: Date(),
            messages: messages,
            sessions: sessions
        )

        do {
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: exportFile, options: .atomic)
            TorboLog.info("Exported to \(exportFile.path)", subsystem: "ConvStore")
            return exportFile
        } catch {
            TorboLog.error("Export failed: \(error)", subsystem: "ConvStore")
            return nil
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Per-Agent Chat Persistence

    private var agentChatsDir: URL {
        storageDir.appendingPathComponent("agent_chats", isDirectory: true)
    }

    private func ensureAgentChatsDir() {
        if !FileManager.default.fileExists(atPath: agentChatsDir.path) {
            try? FileManager.default.createDirectory(at: agentChatsDir, withIntermediateDirectories: true)
        }
    }

    /// Save chat messages for a specific agent + session
    func saveAgentChat(agentID: String, sessionID: UUID, messages: [AgentChatMessage]) {
        ensureAgentChatsDir()
        let file = agentChatsDir.appendingPathComponent("\(agentID)_\(sessionID.uuidString).json")
        do {
            let data = try encoder.encode(messages)
            try data.write(to: file, options: .atomic)
        } catch {
            TorboLog.error("Failed to save agent chat \(agentID)/\(sessionID): \(error)", subsystem: "ConvStore")
        }
    }

    /// Load chat messages for a specific agent + session
    func loadAgentChat(agentID: String, sessionID: UUID) -> [AgentChatMessage] {
        let file = agentChatsDir.appendingPathComponent("\(agentID)_\(sessionID.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode([AgentChatMessage].self, from: data)
        } catch {
            TorboLog.error("Failed to load agent chat \(agentID)/\(sessionID): \(error)", subsystem: "ConvStore")
            return []
        }
    }

    /// Find the most recent chat session ID for an agent by scanning agent_chats/ directory
    func mostRecentSessionID(forAgent agentID: String) -> UUID? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: agentChatsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let prefix = "\(agentID)_"
        var best: (uuid: UUID, date: Date)? = nil
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            let uuidStr = String(name.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: uuidStr) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (uuid, date)
            }
        }
        return best?.uuid
    }

    /// Ensure a session entry exists in sessions.json for a given agent + session
    func ensureSessionExists(agentID: String, sessionID: UUID, messageCount: Int) {
        var sessions = loadSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            // Update existing session
            sessions[idx].lastActivity = Date()
            sessions[idx].messageCount = messageCount
        } else {
            // Create new session entry with the exact UUID we're using
            let session = ConversationSession(
                id: sessionID, startedAt: Date(), lastActivity: Date(),
                messageCount: messageCount, model: "unknown",
                title: "Conversation", agentID: agentID
            )
            sessions.insert(session, at: 0)
        }
        saveSessions(sessions)
    }

    /// Update the title of a session
    func updateSessionTitle(agentID: String, sessionID: UUID, title: String) {
        var sessions = loadSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].title = title
            saveSessions(sessions)
        }
    }

    /// Load sessions filtered by agent ID
    func loadSessions(forAgent agentID: String) -> [ConversationSession] {
        let all = loadSessions()
        return all.filter { $0.agentID == agentID }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Load all sessions grouped by agent ID
    func loadSessionsGroupedByAgent() -> [String: [ConversationSession]] {
        let all = loadSessions()
        var grouped: [String: [ConversationSession]] = [:]
        for session in all {
            grouped[session.agentID, default: []].append(session)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.lastActivity > $1.lastActivity }
        }
        return grouped
    }
}
