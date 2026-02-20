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

// MARK: - Cloud User Manager

actor CloudUserManager {
    static let shared = CloudUserManager()

    // Track active user sessions for stats
    private var activeSessions: [String: Date] = [:]  // userID → lastActive
    private let sessionTimeout: TimeInterval = 1800    // 30 minutes

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
        ]
    }
}
