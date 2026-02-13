// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Conversation persistence — stores messages and sessions to disk
import Foundation

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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        messagesFile = storageDir.appendingPathComponent("messages.jsonl")
        sessionsFile = storageDir.appendingPathComponent("sessions.json")

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        print("[Store] Data directory: \(storageDir.path)")
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

    /// Force write any pending messages to disk
    func flushMessages() {
        guard !pendingMessages.isEmpty else { return }

        let toWrite = pendingMessages
        pendingMessages.removeAll()
        writeTask = nil

        // Append as JSONL (one JSON object per line)
        var lines = ""
        for msg in toWrite {
            if let data = try? encoder.encode(msg),
               let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }

        guard !lines.isEmpty else { return }

        if FileManager.default.fileExists(atPath: messagesFile.path) {
            // Append to existing file
            if let handle = try? FileHandle(forWritingTo: messagesFile) {
                handle.seekToEndOfFile()
                if let data = lines.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            // Create new file
            try? lines.write(to: messagesFile, atomically: true, encoding: .utf8)
        }

        print("[Store] Flushed \(toWrite.count) messages to disk")
    }

    /// Load all messages from disk
    func loadMessages() -> [ConversationMessage] {
        guard FileManager.default.fileExists(atPath: messagesFile.path) else { return [] }

        do {
            let content = try String(contentsOf: messagesFile, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            var messages: [ConversationMessage] = []
            for line in lines {
                if let data = line.data(using: .utf8),
                   let msg = try? decoder.decode(ConversationMessage.self, from: data) {
                    messages.append(msg)
                }
            }
            print("[Store] Loaded \(messages.count) messages from disk")
            return messages
        } catch {
            print("[Store] Failed to load messages: \(error)")
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
            print("[Store] Failed to save sessions: \(error)")
        }
    }

    /// Load sessions from disk
    func loadSessions() -> [ConversationSession] {
        guard FileManager.default.fileExists(atPath: sessionsFile.path) else { return [] }
        do {
            let data = try Data(contentsOf: sessionsFile)
            return try decoder.decode([ConversationSession].self, from: data)
        } catch {
            print("[Store] Failed to load sessions: \(error)")
            return []
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
        print("[Store] Cleared all conversation data")
    }

    /// Export conversations as a JSON file, returns the file URL
    func exportConversations() -> URL? {
        let messages = loadMessages()
        let sessions = loadSessions()

        let export: [String: Any] = [
            "version": "2.0.0",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "messageCount": messages.count,
            "sessionCount": sessions.count
        ]

        // Write combined export
        let exportFile = storageDir.appendingPathComponent("torbo-base-export-\(dateStamp()).json")

        struct ExportData: Codable {
            let version: String
            let exportedAt: Date
            let messages: [ConversationMessage]
            let sessions: [ConversationSession]
        }

        let data = ExportData(
            version: "2.0.0",
            exportedAt: Date(),
            messages: messages,
            sessions: sessions
        )

        do {
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: exportFile, options: .atomic)
            print("[Store] Exported to \(exportFile.path)")
            return exportFile
        } catch {
            print("[Store] Export failed: \(error)")
            return nil
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
