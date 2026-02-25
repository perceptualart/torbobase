// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — UserIdentity (Cross-Platform User Resolution)
// Maps platform IDs to canonical user identities so the same person
// on Telegram, Discord, and web chat is recognized as one individual.
// Privacy by design: stores only platform IDs and display names — no email,
// no phone lookups, nothing leaves the user's machine.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Cross-platform user identity resolution.
/// The same person on Telegram, Discord, Slack, and web chat
/// gets a single canonical ID so memories and context transfer.
actor UserIdentity {
    static let shared = UserIdentity()

    // MARK: - Types

    struct User: Sendable {
        let id: String                  // UUID, canonical
        var platformIDs: [PlatformID]   // All known platform accounts
        var displayName: String         // Best-known name
        var firstSeen: Date
        var lastSeen: Date
    }

    struct PlatformID: Sendable {
        let platform: String            // "telegram", "discord", "slack", etc.
        let platformUserID: String      // The platform's ID for this user
        let username: String?           // Display name on that platform
    }

    // MARK: - Storage

    private var db: OpaquePointer?
    private let dbPath: String
    private var isReady = false

    /// In-memory cache: platform:platformUserID → canonical user ID
    private var platformLookup: [String: String] = [:]

    /// In-memory cache: canonical ID → User
    private var userCache: [String: User] = [:]

    // MARK: - Init

    init() {
        let dir = PlatformPaths.appSupportDir.appendingPathComponent("TorboBase/memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("users.db").path
    }

    // MARK: - Lifecycle

    func initialize() {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open user identity database: \(dbPath)", subsystem: "UserIdentity")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        exec("""
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS platform_ids (
                user_id TEXT NOT NULL REFERENCES users(id),
                platform TEXT NOT NULL,
                platform_user_id TEXT NOT NULL,
                username TEXT,
                PRIMARY KEY (platform, platform_user_id)
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_platform_user ON platform_ids(user_id)")

        loadCache()
        isReady = true

        TorboLog.info("Ready — \(userCache.count) users, \(platformLookup.count) platform IDs", subsystem: "UserIdentity")
    }

    // MARK: - Resolution

    /// Resolve a platform user to a canonical identity.
    /// If the platform ID is known, returns the existing user.
    /// If unknown, creates a new canonical user.
    func resolve(platform: String, platformUserID: String, username: String? = nil) -> User {
        let lookupKey = "\(platform):\(platformUserID)"

        // Check if we already know this platform ID
        if let canonicalID = platformLookup[lookupKey],
           var user = userCache[canonicalID] {
            // Update last seen
            user.lastSeen = Date()
            userCache[canonicalID] = user
            updateLastSeen(id: canonicalID)
            return user
        }

        // New platform ID — create a new canonical user
        let canonicalID = UUID().uuidString
        let now = Date()
        let displayName = username ?? "\(platform):\(platformUserID)"

        let user = User(
            id: canonicalID,
            platformIDs: [PlatformID(platform: platform, platformUserID: platformUserID, username: username)],
            displayName: displayName,
            firstSeen: now,
            lastSeen: now
        )

        // Persist
        insertUser(user)
        insertPlatformID(userID: canonicalID, platform: platform, platformUserID: platformUserID, username: username)

        // Cache
        userCache[canonicalID] = user
        platformLookup[lookupKey] = canonicalID

        TorboLog.info("New user: \(displayName) (\(platform):\(platformUserID)) → \(canonicalID.prefix(8))", subsystem: "UserIdentity")
        return user
    }

    // MARK: - Linking

    /// Manually link a platform account to an existing canonical user.
    /// Used when a user says "my Telegram is the same as my Discord".
    func link(userID: String, platform: String, platformUserID: String, username: String? = nil) {
        guard var user = userCache[userID] else {
            TorboLog.warn("Cannot link — user \(userID.prefix(8)) not found", subsystem: "UserIdentity")
            return
        }

        let lookupKey = "\(platform):\(platformUserID)"

        // Check if this platform ID is already linked to someone else
        if let existingID = platformLookup[lookupKey], existingID != userID {
            TorboLog.warn("Platform ID \(lookupKey) already linked to user \(existingID.prefix(8))", subsystem: "UserIdentity")
            return
        }

        // Add the link
        insertPlatformID(userID: userID, platform: platform, platformUserID: platformUserID, username: username)
        platformLookup[lookupKey] = userID

        user.platformIDs.append(PlatformID(platform: platform, platformUserID: platformUserID, username: username))
        userCache[userID] = user

        TorboLog.info("Linked \(platform):\(platformUserID) to user \(user.displayName)", subsystem: "UserIdentity")
    }

    // MARK: - Query

    /// Get a user by canonical ID.
    func user(for canonicalID: String) -> User? {
        return userCache[canonicalID]
    }

    /// Get canonical user ID for a platform user.
    func canonicalID(platform: String, platformUserID: String) -> String? {
        return platformLookup["\(platform):\(platformUserID)"]
    }

    /// All known users.
    func allUsers() -> [User] {
        return Array(userCache.values).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Stats for API.
    func stats() -> [String: Any] {
        return [
            "total_users": userCache.count,
            "total_platform_ids": platformLookup.count,
            "platforms": Dictionary(grouping: platformLookup.keys) {
                $0.components(separatedBy: ":").first ?? "unknown"
            }.mapValues { $0.count }
        ]
    }

    // MARK: - Private

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err { TorboLog.error("SQL error: \(String(cString: err))", subsystem: "UserIdentity"); sqlite3_free(err) }
        }
    }

    private func insertUser(_ user: User) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO users (id, display_name, first_seen, last_seen) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (user.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (user.displayName as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, user.firstSeen.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, user.lastSeen.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func insertPlatformID(userID: String, platform: String, platformUserID: String, username: String?) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO platform_ids (user_id, platform, platform_user_id, username) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (userID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (platform as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (platformUserID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let username {
            sqlite3_bind_text(stmt, 4, (username as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_step(stmt)
    }

    private func updateLastSeen(id: String) {
        guard let db else { return }
        let sql = "UPDATE users SET last_seen = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func loadCache() {
        guard let db else { return }

        // Load users
        let userSQL = "SELECT id, display_name, first_seen, last_seen FROM users"
        var userStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, userSQL, -1, &userStmt, nil) == SQLITE_OK {
            while sqlite3_step(userStmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(userStmt, 0),
                      let namePtr = sqlite3_column_text(userStmt, 1) else { continue }

                let id = String(cString: idPtr)
                let name = String(cString: namePtr)
                let firstSeen = Date(timeIntervalSince1970: sqlite3_column_double(userStmt, 2))
                let lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(userStmt, 3))

                userCache[id] = User(id: id, platformIDs: [], displayName: name,
                                     firstSeen: firstSeen, lastSeen: lastSeen)
            }
            sqlite3_finalize(userStmt)
        }

        // Load platform IDs
        let platSQL = "SELECT user_id, platform, platform_user_id, username FROM platform_ids"
        var platStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, platSQL, -1, &platStmt, nil) == SQLITE_OK {
            while sqlite3_step(platStmt) == SQLITE_ROW {
                guard let userIDPtr = sqlite3_column_text(platStmt, 0),
                      let platPtr = sqlite3_column_text(platStmt, 1),
                      let platUserPtr = sqlite3_column_text(platStmt, 2) else { continue }

                let userID = String(cString: userIDPtr)
                let platform = String(cString: platPtr)
                let platUserID = String(cString: platUserPtr)
                let username = sqlite3_column_text(platStmt, 3).map { String(cString: $0) }

                let lookupKey = "\(platform):\(platUserID)"
                platformLookup[lookupKey] = userID

                // Add to user's platform IDs
                if var user = userCache[userID] {
                    user.platformIDs.append(PlatformID(platform: platform, platformUserID: platUserID, username: username))
                    userCache[userID] = user
                }
            }
            sqlite3_finalize(platStmt)
        }
    }
}
