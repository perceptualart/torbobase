// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Security)
import Security
#endif
import Foundation

// MARK: - Access Level

enum AccessLevel: Int, CaseIterable, Codable {
    case off = 0
    case chatOnly = 1
    case readFiles = 2
    case writeFiles = 3
    case execute = 4
    case fullAccess = 5

    var name: String {
        switch self {
        case .off: return "OFF"
        case .chatOnly: return "CHAT"
        case .readFiles: return "READ"
        case .writeFiles: return "WRITE"
        case .execute: return "EXEC"
        case .fullAccess: return "FULL"
        }
    }

    var description: String {
        switch self {
        case .off: return "Agent Privileges: None — kill switch active"
        case .chatOnly: return "Agent Privileges: Chat only"
        case .readFiles: return "Agent Privileges: Read files"
        case .writeFiles: return "Agent Privileges: Read + Write files"
        case .execute: return "Agent Privileges: Read, Write + Execute"
        case .fullAccess: return "Agent Privileges: Unrestricted"
        }
    }

    #if canImport(SwiftUI)
    var color: Color {
        switch self {
        case .off: return .gray
        case .chatOnly: return .green
        case .readFiles: return .cyan
        case .writeFiles: return .yellow
        case .execute: return .orange
        case .fullAccess: return .red
        }
    }
    #endif

    var icon: String {
        switch self {
        case .off: return "poweroff"
        case .chatOnly: return "bubble.left"
        case .readFiles: return "doc.text.magnifyingglass"
        case .writeFiles: return "doc.badge.plus"
        case .execute: return "terminal"
        case .fullAccess: return "exclamationmark.shield"
        }
    }
}

// MARK: - Audit Log

struct AuditEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let clientIP: String
    let method: String
    let path: String
    let requiredLevel: AccessLevel
    let granted: Bool
    let detail: String

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}

// MARK: - Conversation Message

struct ConversationMessage: Identifiable, Codable {
    let id: UUID
    let role: String      // "user" or "assistant"
    let content: String
    let model: String
    let timestamp: Date
    let clientIP: String?

    init(role: String, content: String, model: String = "", clientIP: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.model = model
        self.timestamp = Date()
        self.clientIP = clientIP
    }
}

// MARK: - Session

struct ConversationSession: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    var lastActivity: Date
    var messageCount: Int
    var model: String
    var title: String

    init(model: String = "unknown") {
        self.id = UUID()
        self.startedAt = Date()
        self.lastActivity = Date()
        self.messageCount = 0
        self.model = model
        self.title = "New Session"
    }
}

// MARK: - Model Info

struct ModelInfo: Identifiable {
    var id: String { name }
    let name: String
    let size: String
    let quantization: String
    let modified: Date?
    let family: String
    let parameterSize: String
}

// MARK: - Cloud Provider

enum CloudProvider: String, CaseIterable, Codable {
    case anthropic = "Anthropic (Claude)"
    case openai = "OpenAI (GPT)"
    case google = "Google (Gemini)"
    case xai = "xAI (Grok)"
    case elevenlabs = "ElevenLabs (TTS)"

    var keyName: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .google: return "GOOGLE_API_KEY"
        case .xai: return "XAI_API_KEY"
        case .elevenlabs: return "ELEVENLABS_API_KEY"
        }
    }

    var baseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .google: return "https://generativelanguage.googleapis.com"
        case .xai: return "https://api.x.ai"
        case .elevenlabs: return "https://api.elevenlabs.io"
        }
    }
}

// MARK: - Telegram Config

struct TelegramConfig: Codable {
    var botToken: String
    var chatId: String
    var enabled: Bool

    static var stored: TelegramConfig {
        get {
            let defaults = UserDefaults.standard
            let chatId = defaults.string(forKey: "torboTelegramChatId") ?? ""
            let enabled = defaults.bool(forKey: "torboTelegramEnabled")
            // Bot token lives in Keychain
            let botToken = KeychainManager.telegramBotToken
            return TelegramConfig(botToken: botToken, chatId: chatId, enabled: enabled)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.chatId, forKey: "torboTelegramChatId")
            defaults.set(newValue.enabled, forKey: "torboTelegramEnabled")
            // Bot token goes to Keychain
            KeychainManager.telegramBotToken = newValue.botToken
        }
    }
}

// MARK: - Version

enum TorboVersion {
    static let current = "3.0.0"
    static let build = "3"
    static let display = "v\(current)"
    static let full = "v\(current) (\(build))"
}

// MARK: - App Config

enum AppConfig {
    private static let defaults = UserDefaults.standard

    /// One-time migration of UserDefaults from ORB-era to Torbo-era.
    /// The bundle ID changed from "ai.orb.base" to "ai.torbo.base", so
    /// UserDefaults.standard now points to a different domain. We must
    /// explicitly read from the old domain using UserDefaults(suiteName:).
    static func migrateFromORBIfNeeded() {
        guard !defaults.bool(forKey: "torbo_config_migrated") else { return }

        // Old domain from previous bundle ID
        let oldDefaults = UserDefaults(suiteName: "ai.orb.base")
        // Also check ORBBase domain (used by some earlier builds)
        let oldDefaults2 = UserDefaults(suiteName: "ORBBase")

        let mappings: [(old: String, new: String)] = [
            ("orbAccessLevel",      "torboAccessLevel"),
            ("orbServerPort",       "torboServerPort"),
            ("orbSandboxPaths",     "torboSandboxPaths"),
            ("orbRateLimit",        "torboRateLimit"),
            ("orbSetupCompleted",   "torboSetupCompleted"),
            ("orbSystemPrompt",     "torboSystemPrompt"),
            ("orbSystemPromptEnabled", "torboSystemPromptEnabled"),
            ("orbTelegramChatId",   "torboTelegramChatId"),
            ("orbTelegramEnabled",  "torboTelegramEnabled"),
            ("orb_paired_devices",  "torbo_paired_devices"),
        ]

        var migrated = 0
        for m in mappings {
            if defaults.object(forKey: m.new) == nil {
                // Try old ai.orb.base domain first, then ORBBase domain
                let old = oldDefaults?.object(forKey: m.old) ?? oldDefaults2?.object(forKey: m.old)
                if let old {
                    defaults.set(old, forKey: m.new)
                    migrated += 1
                    TorboLog.info("Migrated: \(m.old) → \(m.new)", subsystem: "Config")
                }
            }
        }

        if migrated > 0 {
            TorboLog.info("Migrated \(migrated) UserDefaults key(s) from ORB → Torbo", subsystem: "Config")
        }

        defaults.set(true, forKey: "torbo_config_migrated")
    }

    static var accessLevel: Int {
        get { defaults.integer(forKey: "torboAccessLevel") }
        set { defaults.set(newValue, forKey: "torboAccessLevel") }
    }

    static var serverPort: UInt16 {
        get {
            let v = UInt16(defaults.integer(forKey: "torboServerPort"))
            return v == 0 ? 4200 : v
        }
        set { defaults.set(Int(newValue), forKey: "torboServerPort") }
    }

    static var serverToken: String {
        get { KeychainManager.serverToken }
        set { KeychainManager.serverToken = newValue }
    }

    static var sandboxPaths: [String] {
        get {
            defaults.stringArray(forKey: "torboSandboxPaths") ?? [
                "~/Desktop", "~/Documents", "~/Downloads"
            ]
        }
        set { defaults.set(newValue, forKey: "torboSandboxPaths") }
    }

    static var allowedCORSOrigins: [String] {
        get {
            defaults.stringArray(forKey: "torboAllowedCORSOrigins") ?? [
                "http://localhost:18790", "http://127.0.0.1:18790"
            ]
        }
        set { defaults.set(newValue, forKey: "torboAllowedCORSOrigins") }
    }

    static var allowedCommands: [String] {
        get {
            defaults.stringArray(forKey: "torboAllowedCommands") ?? [
                "ls", "cat", "head", "tail", "wc", "grep", "find", "echo", "date",
                "pwd", "whoami", "uname", "file", "stat", "md5", "shasum", "diff",
                "sort", "uniq", "tr", "cut", "awk", "sed", "jq", "curl", "git",
                "swift", "python3", "node", "npm", "brew"
            ]
        }
        set { defaults.set(newValue, forKey: "torboAllowedCommands") }
    }

    static var ssrfProtectionEnabled: Bool {
        get {
            if defaults.object(forKey: "torboSSRFProtection") == nil { return true }
            return defaults.bool(forKey: "torboSSRFProtection")
        }
        set { defaults.set(newValue, forKey: "torboSSRFProtection") }
    }

    static var rateLimit: Int {
        get {
            let v = defaults.integer(forKey: "torboRateLimit")
            return v == 0 ? 60 : v
        }
        set { defaults.set(newValue, forKey: "torboRateLimit") }
    }

    static var setupCompleted: Bool {
        get { defaults.bool(forKey: "torboSetupCompleted") }
        set { defaults.set(newValue, forKey: "torboSetupCompleted") }
    }

    static var cloudAPIKeys: [String: String] {
        get { KeychainManager.getAllAPIKeys() }
        set { KeychainManager.setAllAPIKeys(newValue) }
    }

    static var telegramConfig: TelegramConfig {
        get { TelegramConfig.stored }
        set { TelegramConfig.stored = newValue }
    }

    static var systemPrompt: String {
        get { defaults.string(forKey: "torboSystemPrompt") ?? "" }
        set { defaults.set(newValue, forKey: "torboSystemPrompt") }
    }

    static var systemPromptEnabled: Bool {
        get { defaults.bool(forKey: "torboSystemPromptEnabled") }
        set { defaults.set(newValue, forKey: "torboSystemPromptEnabled") }
    }

    static var memoryEnabled: Bool {
        get {
            if defaults.object(forKey: "torboMemoryEnabled") == nil { return true }
            return defaults.bool(forKey: "torboMemoryEnabled")
        }
        set { defaults.set(newValue, forKey: "torboMemoryEnabled") }
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        #else
        if let fh = FileHandle(forReadingAtPath: "/dev/urandom") {
            let data = fh.readData(ofLength: 32)
            fh.closeFile()
            if data.count == 32 { bytes = Array(data) }
        }
        #endif
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - App State

// ObservableObject (Combine) is used instead of @Observable (Observation framework)
// for macOS 13 (Ventura) compatibility. @Observable requires macOS 14+.
// On Linux (no Combine), AppState is a plain class — headless mode doesn't need UI observation.
#if canImport(Combine)
import Combine
/// Alias so AppState can conditionally conform to ObservableObject.
protocol _TorboObservable: ObservableObject {}
#else
protocol _TorboObservable: AnyObject {}
#endif

final class AppState: _TorboObservable {
    static let shared = AppState()
    let appStartedAt = Date()

    /// Human-readable uptime string
    var uptimeString: String {
        let elapsed = Int(Date().timeIntervalSince(appStartedAt))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        return "\(h)h \(m)m"
    }

    /// Helper: notify Combine subscribers that a property will change (no-op on Linux).
    private func willChangeUI() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }

    // Access control — willChangeUI() triggers SwiftUI update, didSet persists the change
    var accessLevel: AccessLevel {
        willSet { willChangeUI() }
        didSet { AppConfig.accessLevel = accessLevel.rawValue }
    }

    /// ProactiveAgent toggle — controls autonomous task execution
    var proactiveAgentEnabled: Bool = false {
        willSet { willChangeUI() }
        didSet {
            UserDefaults.standard.set(proactiveAgentEnabled, forKey: "proactiveAgentEnabled")
            if proactiveAgentEnabled {
                Task { await ProactiveAgent.shared.start() }
            } else {
                Task { await ProactiveAgent.shared.stop() }
            }
        }
    }

    /// Per-agent access levels — synced from AgentConfigManager
    var agentAccessLevels: [String: AccessLevel] = ["sid": .fullAccess] {
        willSet { willChangeUI() }
    }

    func accessLevel(for agentID: String) -> AccessLevel {
        if accessLevel == .off { return .off }
        let agentLevel = agentAccessLevels[agentID] ?? .chatOnly
        return AccessLevel(rawValue: min(agentLevel.rawValue, accessLevel.rawValue)) ?? .chatOnly
    }

    /// Sync agent access levels from AgentConfigManager
    func refreshAgentLevels() {
        Task {
            let levels = await AgentConfigManager.shared.agentAccessLevels
            await MainActor.run {
                var mapped: [String: AccessLevel] = [:]
                for (id, raw) in levels {
                    mapped[id] = AccessLevel(rawValue: raw) ?? .chatOnly
                }
                self.agentAccessLevels = mapped
            }
        }
    }

    // Server
    var serverRunning = false { willSet { willChangeUI() } }
    var serverPort: UInt16 = AppConfig.serverPort { willSet { willChangeUI() } }
    var serverError: String? { willSet { willChangeUI() } }
    var serverToken: String { willSet { willChangeUI() } }

    // Ollama
    var ollamaRunning = false { willSet { willChangeUI() } }
    var ollamaInstalled = false { willSet { willChangeUI() } }
    var ollamaModels: [String] = [] { willSet { willChangeUI() } }
    var modelDetails: [ModelInfo] = [] { willSet { willChangeUI() } }
    var pullingModel: String? = nil { willSet { willChangeUI() } }
    var pullProgress: Double = 0 { willSet { willChangeUI() } }

    // Clients
    var connectedClients: Int = 0 { willSet { willChangeUI() } }
    var activeClientIPs: Set<String> = [] { willSet { willChangeUI() } }

    // Audit
    var auditLog: [AuditEntry] = [] { willSet { willChangeUI() } }
    var totalRequests: Int = 0 { willSet { willChangeUI() } }
    var blockedRequests: Int = 0 { willSet { willChangeUI() } }

    // Rate limiting
    var rateLimit: Int = AppConfig.rateLimit { willSet { willChangeUI() } }

    // Global capability toggles — categories set to false are disabled for ALL agents
    var globalCapabilities: [String: Bool] = {
        if let data = UserDefaults.standard.data(forKey: "torboGlobalCapabilities"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            return dict
        }
        return [:]
    }() {
        willSet { willChangeUI() }
        didSet {
            if let data = try? JSONSerialization.data(withJSONObject: globalCapabilities) {
                UserDefaults.standard.set(data, forKey: "torboGlobalCapabilities")
            }
        }
    }

    // Parallel execution
    var maxConcurrentTasks: Int = 3 {
        willSet { willChangeUI() }
        didSet {
            let clamped = max(1, min(maxConcurrentTasks, 10))
            if clamped != maxConcurrentTasks { maxConcurrentTasks = clamped }
            Task { await ParallelExecutor.shared.updateMaxSlots(clamped) }
        }
    }

    // Logging
    var logLevel: String = "info" {
        willSet { willChangeUI() }
        didSet { TorboLog.minimumLevel = LogLevel.from(logLevel) }
    }

    // Conversations
    var sessions: [ConversationSession] = [] { willSet { willChangeUI() } }
    var recentMessages: [ConversationMessage] = [] { willSet { willChangeUI() } }

    // Setup
    var setupCompleted: Bool = AppConfig.setupCompleted { willSet { willChangeUI() } }

    // Cloud providers
    var cloudAPIKeys: [String: String] = AppConfig.cloudAPIKeys { willSet { willChangeUI() } }

    // Telegram
    var telegramConfig: TelegramConfig = AppConfig.telegramConfig { willSet { willChangeUI() } }
    var telegramConnected: Bool = false { willSet { willChangeUI() } }

    // Discord
    var discordBotToken: String? { willSet { willChangeUI() } }
    var discordChannelID: String? { willSet { willChangeUI() } }

    // Slack
    var slackBotToken: String? { willSet { willChangeUI() } }
    var slackChannelID: String? { willSet { willChangeUI() } }
    var slackBotUserID: String? { willSet { willChangeUI() } }

    // WhatsApp
    var whatsappAccessToken: String? { willSet { willChangeUI() } }
    var whatsappPhoneNumberID: String? { willSet { willChangeUI() } }
    var whatsappVerifyToken: String? { willSet { willChangeUI() } }

    // Signal
    var signalPhoneNumber: String? { willSet { willChangeUI() } }
    var signalAPIURL: String? { willSet { willChangeUI() } }

    // System prompt
    var systemPromptEnabled: Bool = AppConfig.systemPromptEnabled {
        willSet { willChangeUI() }
        didSet { AppConfig.systemPromptEnabled = systemPromptEnabled }
    }
    var systemPrompt: String = AppConfig.systemPrompt {
        willSet { willChangeUI() }
        didSet { AppConfig.systemPrompt = systemPrompt }
    }

    // System stats
    var cpuUsage: Double = 0 { willSet { willChangeUI() } }
    var memoryUsage: Double = 0 { willSet { willChangeUI() } }
    var diskFree: String = "" { willSet { willChangeUI() } }

    // Navigation
    var currentTab: DashboardTab = .home { willSet { willChangeUI() } }

    // Computed
    var localIP: String {
        Self.getLocalIP() ?? "127.0.0.1"
    }

    var menuBarIcon: String {
        if accessLevel == .off { return "circle.slash" }
        if !serverRunning { return "circle" }
        if connectedClients > 0 { return "circle.fill" }
        return "circle.inset.filled"
    }

    var statusSummary: String {
        if accessLevel == .off { return "Gateway OFF" }
        if !serverRunning { return "Server offline" }
        if connectedClients > 0 { return "\(connectedClients) client\(connectedClients == 1 ? "" : "s") · Level \(accessLevel.rawValue)" }
        return "Ready · Level \(accessLevel.rawValue)"
    }

    private init() {
        // Run migrations before reading any config
        AppConfig.migrateFromORBIfNeeded()
        KeychainManager.migrateFromKeychainToFileStore()

        let saved = AppConfig.accessLevel
        // If access level was never explicitly set (defaults returns 0 = .off),
        // use .chatOnly as a safe default rather than silently disabling the gateway
        if UserDefaults.standard.object(forKey: "torboAccessLevel") == nil {
            self.accessLevel = .chatOnly
        } else {
            self.accessLevel = AccessLevel(rawValue: saved) ?? .chatOnly
        }
        self.serverToken = AppConfig.serverToken

    }

    func addAuditEntry(_ entry: AuditEntry) {
        auditLog.insert(entry, at: 0)
        if auditLog.count > 500 { auditLog.removeLast() }
        totalRequests += 1
        if !entry.granted { blockedRequests += 1 }
    }

    /// The level before kill switch was activated
    var previousLevel: AccessLevel = .chatOnly

    func killSwitch() {
        if accessLevel == .off {
            // Reconnect — restore previous level
            accessLevel = previousLevel
        } else {
            // Kill — save current level and go to OFF
            previousLevel = accessLevel
            accessLevel = .off
        }
    }

    func regenerateToken() {
        serverToken = KeychainManager.regenerateServerToken()
    }

    func addMessage(_ msg: ConversationMessage) {
        recentMessages.append(msg)
        if recentMessages.count > 200 { recentMessages.removeFirst() }
        // Persist to disk
        Task { await ConversationStore.shared.appendMessage(msg) }
    }

    /// Load persisted conversations on launch
    func loadPersistedData() {
        Task {
            let messages = await ConversationStore.shared.loadRecentMessages(count: 200)
            let sessions = await ConversationStore.shared.loadSessions()
            await MainActor.run {
                if self.recentMessages.isEmpty {
                    self.recentMessages = messages
                }
                if self.sessions.isEmpty {
                    self.sessions = sessions
                }
            }
        }
    }

    /// Total messages including on-disk
    var totalMessageCount: Int {
        get async {
            await ConversationStore.shared.messageCount()
        }
    }

    func updateSystemStats() {
        // CPU usage approximation
        _ = ProcessInfo.processInfo.systemUptime
        cpuUsage = min(100, Double(ProcessInfo.processInfo.activeProcessorCount) / Double(ProcessInfo.processInfo.processorCount) * 100)

        // Memory
        let totalMem = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalMem) / (1024 * 1024 * 1024)
        memoryUsage = totalGB

        // Disk free
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let free = attrs[.systemFreeSize] as? Int64 {
            let freeGB = Double(free) / (1024 * 1024 * 1024)
            diskFree = String(format: "%.1f GB", freeGB)
        }
    }

    private static func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            #if os(macOS)
            guard name == "en0" || name == "en1" else { continue }
            #else
            guard name == "eth0" || name == "en0" else { continue }
            #endif
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            #if os(macOS)
            let saLen = socklen_t(iface.ifa_addr.pointee.sa_len)
            #else
            let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            #endif
            if getnameinfo(iface.ifa_addr, saLen,
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
                #if os(macOS)
                if name == "en0" { break }
                #else
                if name == "eth0" { break }
                #endif
            }
        }
        return address
    }
}

// MARK: - Dashboard Tabs

enum DashboardTab: String, CaseIterable {
    case home = "Home"
    case agents = "Agents"
    case skills = "Skills"
    case models = "Models"
    case spaces = "Spaces"
    case security = "Security"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "circle.hexagongrid.fill"
        case .agents: return "person.2.fill"
        case .skills: return "puzzlepiece.fill"
        case .models: return "cube.fill"
        case .spaces: return "bubble.left.and.bubble.right.fill"
        case .security: return "shield.checkered"
        case .settings: return "gearshape.fill"
        }
    }
}
