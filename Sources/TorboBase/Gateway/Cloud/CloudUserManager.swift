// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Multi-User Isolation Manager
// Each cloud user gets isolated conversation history, memory/LoA, and agent configs.
// Data is namespaced by user ID under the base data directory.

import Foundation

// MARK: - Cloud Request Context

/// Attached to every authenticated cloud request — contains the resolved user info
struct CloudRequestContext: Sendable {
    let userID: String
    let email: String
    let tier: PlanTier
    let stripeCustomerID: String?
    let subscriptionStatus: String?

    /// User-specific data directory: {dataDir}/users/{userID}/
    var dataDir: String {
        PlatformPaths.dataDir + "/users/\(userID)"
    }

    var conversationsDir: String { dataDir + "/conversations" }
    var memoryDir: String { dataDir + "/memory" }
    var agentsDir: String { dataDir + "/agents" }
    var documentsDir: String { dataDir + "/documents" }
}

// MARK: - Per-User Service Container

/// Holds isolated service instances for a single cloud user.
/// Each user gets their own ConversationStore, MemoryIndex, MemoryArmy,
/// MemoryRouter, and AgentConfigManager — fully isolated from other users.
final class UserServices: Sendable {
    let userID: String
    let conversationStore: ConversationStore
    let memoryIndex: MemoryIndex
    let memoryArmy: MemoryArmy
    let memoryRouter: MemoryRouter
    let agentConfigManager: AgentConfigManager

    init(ctx: CloudRequestContext) {
        self.userID = ctx.userID

        // Per-user conversation store
        let convDir = URL(fileURLWithPath: ctx.conversationsDir, isDirectory: true)
        self.conversationStore = ConversationStore(storageDir: convDir)

        // Per-user memory index (SQLite vector DB)
        let dbPath = ctx.memoryDir + "/vectors.db"
        self.memoryIndex = MemoryIndex(dbPath: dbPath)

        // Per-user agents
        let agentsURL = URL(fileURLWithPath: ctx.agentsDir, isDirectory: true)
        self.agentConfigManager = AgentConfigManager(agentsDir: agentsURL)

        // Per-user MemoryArmy (uses per-user MemoryIndex)
        self.memoryArmy = MemoryArmy(memoryIndex: self.memoryIndex)

        // Per-user MemoryRouter (uses all per-user instances)
        self.memoryRouter = MemoryRouter(
            memoryArmy: self.memoryArmy,
            memoryIndex: self.memoryIndex,
            agentConfigManager: self.agentConfigManager
        )
    }
}

// MARK: - Cloud User Manager

actor CloudUserManager {
    static let shared = CloudUserManager()

    // Track active user sessions for stats
    private var activeSessions: [String: Date] = [:]  // userID → lastActive
    private let sessionTimeout: TimeInterval = 1800    // 30 minutes

    // Per-user service instances — cached with idle eviction
    private var userServices: [String: UserServices] = [:]
    private var serviceLastAccess: [String: Date] = [:]
    private let serviceEvictionInterval: TimeInterval = 3600  // 1 hour idle → evict
    private var evictionTask: Task<Void, Never>?

    // MARK: - Directory Setup

    /// Ensure all user-specific directories exist
    func ensureUserDirectories(_ ctx: CloudRequestContext) {
        let fm = FileManager.default
        let dirs = [ctx.dataDir, ctx.conversationsDir, ctx.memoryDir, ctx.agentsDir, ctx.documentsDir]
        for dir in dirs {
            if !fm.fileExists(atPath: dir) {
                do {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                } catch {
                    TorboLog.error("Failed to create user dir \(dir): \(error)", subsystem: "CloudUsers")
                }
            }
        }
    }

    // MARK: - Per-User Service Resolution

    /// Get or create isolated service instances for a cloud user.
    /// Instances are cached and lazily initialized.
    func services(for ctx: CloudRequestContext) async -> UserServices {
        serviceLastAccess[ctx.userID] = Date()

        if let existing = userServices[ctx.userID] {
            return existing
        }

        // Create new per-user services
        ensureUserDirectories(ctx)
        let svc = UserServices(ctx: ctx)

        // Initialize the memory system for this user
        await svc.memoryRouter.initializeForUser()

        userServices[ctx.userID] = svc
        let maskedEmail: String = {
            guard let at = ctx.email.firstIndex(of: "@") else { return "***" }
            return String(ctx.email.prefix(2)) + "***" + ctx.email[at...]
        }()
        TorboLog.info("Created services for user \(ctx.userID) (\(maskedEmail))", subsystem: "CloudUsers")

        // Start eviction timer if not running
        startEvictionTimerIfNeeded()

        return svc
    }

    // MARK: - Eviction

    private func startEvictionTimerIfNeeded() {
        guard evictionTask == nil else { return }
        evictionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
                await self?.evictIdleServices()
            }
        }
    }

    private func evictIdleServices() {
        let cutoff = Date().addingTimeInterval(-serviceEvictionInterval)
        var evicted: [String] = []
        for (userID, lastAccess) in serviceLastAccess {
            if lastAccess < cutoff {
                userServices.removeValue(forKey: userID)
                serviceLastAccess.removeValue(forKey: userID)
                evicted.append(userID)
            }
        }
        if !evicted.isEmpty {
            TorboLog.info("Evicted \(evicted.count) idle user service(s)", subsystem: "CloudUsers")
        }
    }

    // MARK: - Context Resolution

    /// Resolve a CloudRequestContext from a JWT token.
    /// Returns nil if the token is invalid or cloud auth is not enabled.
    func resolveContext(fromJWT token: String) async -> CloudRequestContext? {
        let auth = SupabaseAuth.shared

        // Validate JWT locally
        guard let claims = await auth.validateJWT(token) else {
            return nil
        }

        // Get or create user record
        let user = await auth.ensureUserRecord(userID: claims.sub, email: claims.email)

        // Track session
        activeSessions[user.id] = Date()

        // Ensure directories exist
        let ctx = CloudRequestContext(
            userID: user.id,
            email: user.email,
            tier: user.planTier,
            stripeCustomerID: user.stripeCustomerID,
            subscriptionStatus: user.subscriptionStatus
        )
        ensureUserDirectories(ctx)

        return ctx
    }

    // MARK: - User Data Paths

    /// Get the conversation file path for a user (JSONL format)
    static func conversationPath(userID: String) -> String {
        PlatformPaths.dataDir + "/users/\(userID)/conversations/messages.jsonl"
    }

    /// Get the sessions file path for a user
    static func sessionsPath(userID: String) -> String {
        PlatformPaths.dataDir + "/users/\(userID)/conversations/sessions.json"
    }

    /// Get the memory database path for a user
    static func memoryDBPath(userID: String) -> String {
        PlatformPaths.dataDir + "/users/\(userID)/memory/vectors.db"
    }

    /// Get the agents directory for a user
    static func agentsDir(userID: String) -> String {
        PlatformPaths.dataDir + "/users/\(userID)/agents"
    }

    // MARK: - Session Management

    /// Mark a user as active
    func touchSession(userID: String) {
        activeSessions[userID] = Date()
    }

    /// Clean up expired sessions
    func cleanExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-sessionTimeout)
        let expired = activeSessions.filter { $0.value < cutoff }
        for (id, _) in expired {
            activeSessions.removeValue(forKey: id)
        }
        if !expired.isEmpty {
            TorboLog.info("Cleaned \(expired.count) expired cloud sessions", subsystem: "CloudUsers")
        }
    }

    // MARK: - Stats

    func activeUserCount() -> Int {
        let cutoff = Date().addingTimeInterval(-sessionTimeout)
        return activeSessions.filter { $0.value >= cutoff }.count
    }

    func stats() -> [String: Any] {
        let cutoff = Date().addingTimeInterval(-sessionTimeout)
        let active = activeSessions.filter { $0.value >= cutoff }
        return [
            "active_users": active.count,
            "total_sessions_tracked": activeSessions.count,
            "cached_service_instances": userServices.count,
        ]
    }
}
