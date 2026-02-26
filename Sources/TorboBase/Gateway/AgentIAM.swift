// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent Identity & Access Management
// Production-grade IAM for AI agent identities: registration, permissions, access logging, anomaly detection.
// Every agent is tracked. Every action is logged. Every escalation is caught.

import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - Data Models

struct AgentIdentity: Codable, Sendable {
    let id: String
    let owner: String
    let purpose: String
    let createdAt: Date
    var permissions: [IAMPermission]
    var riskScore: Float

    var asDictionary: [String: Any] {
        [
            "id": id,
            "owner": owner,
            "purpose": purpose,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "permissions": permissions.map { $0.asDictionary },
            "riskScore": riskScore
        ]
    }
}

struct IAMPermission: Codable, Sendable {
    let agentID: String
    let resource: String        // e.g. "file:/Documents/*", "tool:web_search", "tool:execute_code"
    let actions: Set<String>    // ["read", "write", "execute", "use"]
    let grantedAt: Date
    let grantedBy: String

    var asDictionary: [String: Any] {
        [
            "agentID": agentID,
            "resource": resource,
            "actions": Array(actions).sorted(),
            "grantedAt": ISO8601DateFormatter().string(from: grantedAt),
            "grantedBy": grantedBy
        ]
    }
}

struct IAMAccessLog: Codable, Sendable {
    let agentID: String
    let resource: String
    let action: String
    let timestamp: Date
    let allowed: Bool
    let reason: String?

    var asDictionary: [String: Any] {
        var d: [String: Any] = [
            "agentID": agentID,
            "resource": resource,
            "action": action,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "allowed": allowed
        ]
        if let reason { d["reason"] = reason }
        return d
    }
}

struct AccessAnomaly: Codable, Sendable {
    let agentID: String
    let type: String            // "rapid_access", "privilege_escalation", "unusual_resource", "denied_spike"
    let description: String
    let severity: String        // "low", "medium", "high", "critical"
    let detectedAt: Date

    var asDictionary: [String: Any] {
        [
            "agentID": agentID,
            "type": type,
            "description": description,
            "severity": severity,
            "detectedAt": ISO8601DateFormatter().string(from: detectedAt)
        ]
    }
}

// MARK: - Agent IAM Engine

actor AgentIAMEngine {
    static let shared = AgentIAMEngine()

    private var db: OpaquePointer?
    private let dbPath: String
    private let isoFormatter: ISO8601DateFormatter

    // In-memory caches for hot-path lookups
    private var identityCache: [String: AgentIdentity] = [:]
    private var permissionCache: [String: [IAMPermission]] = [:]

    init() {
        let dataDir = PlatformPaths.dataDir
        dbPath = dataDir + "/iam.sqlite"
        isoFormatter = ISO8601DateFormatter()

        try? FileManager.default.createDirectory(
            atPath: dataDir, withIntermediateDirectories: true
        )

        openDatabase()
        createTables()
        TorboLog.info("IAM engine initialized at \(dbPath)", subsystem: "IAM")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            TorboLog.error("Failed to open IAM database at \(dbPath)", subsystem: "IAM")
            return
        }
        // WAL mode for better concurrent read performance
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA foreign_keys=ON")
    }

    private func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS agent_identities (
                id TEXT PRIMARY KEY,
                owner TEXT NOT NULL DEFAULT '',
                purpose TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                risk_score REAL NOT NULL DEFAULT 0.0
            )
        """)

        execute("""
            CREATE TABLE IF NOT EXISTS iam_permissions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                agent_id TEXT NOT NULL,
                resource TEXT NOT NULL,
                actions TEXT NOT NULL,
                granted_at TEXT NOT NULL,
                granted_by TEXT NOT NULL DEFAULT 'system',
                FOREIGN KEY (agent_id) REFERENCES agent_identities(id) ON DELETE CASCADE
            )
        """)

        execute("""
            CREATE TABLE IF NOT EXISTS iam_access_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                agent_id TEXT NOT NULL,
                resource TEXT NOT NULL,
                action TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                allowed INTEGER NOT NULL DEFAULT 1,
                reason TEXT
            )
        """)

        // Indexes for fast lookups
        execute("CREATE INDEX IF NOT EXISTS idx_perm_agent ON iam_permissions(agent_id)")
        execute("CREATE INDEX IF NOT EXISTS idx_perm_resource ON iam_permissions(resource)")
        execute("CREATE INDEX IF NOT EXISTS idx_log_agent ON iam_access_log(agent_id)")
        execute("CREATE INDEX IF NOT EXISTS idx_log_timestamp ON iam_access_log(timestamp)")
        execute("CREATE INDEX IF NOT EXISTS idx_log_resource ON iam_access_log(resource)")
    }

    // MARK: - Agent Registration

    func registerAgent(id: String, owner: String = "", purpose: String = "") {
        guard !id.isEmpty else { return }

        // Check if already registered
        if identityCache[id] != nil { return }
        if agentExists(id) {
            // Load into cache
            if let identity = loadIdentity(id) {
                identityCache[id] = identity
            }
            return
        }

        let now = isoFormatter.string(from: Date())
        let sql = "INSERT OR IGNORE INTO agent_identities (id, owner, purpose, created_at, risk_score) VALUES (?, ?, ?, ?, 0.0)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (owner as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (purpose as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            let identity = AgentIdentity(
                id: id, owner: owner, purpose: purpose,
                createdAt: Date(), permissions: [], riskScore: 0.0
            )
            identityCache[id] = identity
            TorboLog.info("Registered agent '\(id)' (owner: \(owner.isEmpty ? "local" : owner))", subsystem: "IAM")
        }
    }

    // MARK: - Permission Management

    func grantPermission(agentID: String, resource: String, actions: Set<String>, grantedBy: String = "system") {
        guard !agentID.isEmpty, !resource.isEmpty, !actions.isEmpty else { return }

        // Ensure agent exists
        registerAgent(id: agentID)

        // Revoke existing permission for this resource first (replace pattern)
        revokePermission(agentID: agentID, resource: resource)

        let now = isoFormatter.string(from: Date())
        let actionsStr = actions.sorted().joined(separator: ",")

        let sql = "INSERT INTO iam_permissions (agent_id, resource, actions, granted_at, granted_by) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (resource as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (actionsStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (grantedBy as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            // Invalidate cache
            permissionCache.removeValue(forKey: agentID)
            identityCache.removeValue(forKey: agentID)
            TorboLog.info("Granted \(actionsStr) on '\(resource)' to agent '\(agentID)'", subsystem: "IAM")
        }
    }

    func revokePermission(agentID: String, resource: String) {
        let sql = "DELETE FROM iam_permissions WHERE agent_id = ? AND resource = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (resource as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            permissionCache.removeValue(forKey: agentID)
            identityCache.removeValue(forKey: agentID)
            let changes = sqlite3_changes(db)
            if changes > 0 {
                TorboLog.info("Revoked permission on '\(resource)' from agent '\(agentID)'", subsystem: "IAM")
            }
        }
    }

    func revokeAllPermissions(agentID: String) {
        let sql = "DELETE FROM iam_permissions WHERE agent_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            permissionCache.removeValue(forKey: agentID)
            identityCache.removeValue(forKey: agentID)
            TorboLog.info("Revoked ALL permissions for agent '\(agentID)'", subsystem: "IAM")
        }
    }

    // MARK: - Permission Checking

    func checkPermission(agentID: String, resource: String, action: String) -> Bool {
        let perms = loadPermissions(for: agentID)

        for perm in perms {
            if matchesResource(pattern: perm.resource, target: resource) && perm.actions.contains(action) {
                return true
            }
        }

        // Check wildcard "all" permission
        for perm in perms {
            if perm.resource == "*" && perm.actions.contains(action) {
                return true
            }
            if perm.resource == "*" && perm.actions.contains("*") {
                return true
            }
        }

        return false
    }

    /// Check permission and log the access in one call (the common hot path).
    func checkAndLog(agentID: String, resource: String, action: String) -> Bool {
        let allowed = checkPermission(agentID: agentID, resource: resource, action: action)
        let reason = allowed ? nil : "No matching permission for \(action) on \(resource)"
        logAccess(agentID: agentID, resource: resource, action: action, allowed: allowed, reason: reason)
        return allowed
    }

    // MARK: - Access Logging

    func logAccess(agentID: String, resource: String, action: String, allowed: Bool, reason: String? = nil) {
        let now = isoFormatter.string(from: Date())

        let sql = "INSERT INTO iam_access_log (agent_id, resource, action, timestamp, allowed, reason) VALUES (?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (resource as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (action as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 5, allowed ? 1 : 0)
        if let reason {
            sqlite3_bind_text(stmt, 6, (reason as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        sqlite3_step(stmt)

        if !allowed {
            TorboLog.warn("ACCESS DENIED: agent '\(agentID)' → \(action) on '\(resource)' (\(reason ?? "no permission"))", subsystem: "IAM")
        }
    }

    // MARK: - Agent Queries

    func listAgents(owner: String? = nil) -> [AgentIdentity] {
        var sql = "SELECT id, owner, purpose, created_at, risk_score FROM agent_identities"
        if owner != nil { sql += " WHERE owner = ?" }
        sql += " ORDER BY created_at DESC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if let owner {
            sqlite3_bind_text(stmt, 1, (owner as NSString).utf8String, -1, nil)
        }

        var results: [AgentIdentity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let ownerVal = String(cString: sqlite3_column_text(stmt, 1))
            let purpose = String(cString: sqlite3_column_text(stmt, 2))
            let createdStr = String(cString: sqlite3_column_text(stmt, 3))
            let riskScore = Float(sqlite3_column_double(stmt, 4))

            let createdAt = isoFormatter.date(from: createdStr) ?? Date()
            let perms = loadPermissions(for: id)

            results.append(AgentIdentity(
                id: id, owner: ownerVal, purpose: purpose,
                createdAt: createdAt, permissions: perms, riskScore: riskScore
            ))
        }

        return results
    }

    func getAgent(_ id: String) -> AgentIdentity? {
        if let cached = identityCache[id] {
            // Refresh permissions
            let perms = loadPermissions(for: id)
            let updated = AgentIdentity(
                id: cached.id, owner: cached.owner, purpose: cached.purpose,
                createdAt: cached.createdAt, permissions: perms, riskScore: cached.riskScore
            )
            identityCache[id] = updated
            return updated
        }
        return loadIdentity(id)
    }

    func findAgentsWithAccess(resource: String) -> [AgentIdentity] {
        // Find all agents that have a permission matching this resource
        let sql = "SELECT DISTINCT agent_id FROM iam_permissions"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var matchingIDs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentID = String(cString: sqlite3_column_text(stmt, 0))
            if checkPermission(agentID: agentID, resource: resource, action: "read") ||
               checkPermission(agentID: agentID, resource: resource, action: "write") ||
               checkPermission(agentID: agentID, resource: resource, action: "execute") ||
               checkPermission(agentID: agentID, resource: resource, action: "use") ||
               checkPermission(agentID: agentID, resource: resource, action: "*") {
                matchingIDs.append(agentID)
            }
        }

        return matchingIDs.compactMap { getAgent($0) }
    }

    // MARK: - Access Log Queries

    func getAccessLog(agentID: String? = nil, resource: String? = nil, limit: Int = 100, offset: Int = 0) -> [IAMAccessLog] {
        var sql = "SELECT agent_id, resource, action, timestamp, allowed, reason FROM iam_access_log"
        var conditions: [String] = []
        if agentID != nil { conditions.append("agent_id = ?") }
        if resource != nil { conditions.append("resource LIKE ?") }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY timestamp DESC LIMIT ? OFFSET ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        if let agentID {
            sqlite3_bind_text(stmt, paramIdx, (agentID as NSString).utf8String, -1, nil)
            paramIdx += 1
        }
        if let resource {
            let pattern = resource.replacingOccurrences(of: "*", with: "%")
            sqlite3_bind_text(stmt, paramIdx, (pattern as NSString).utf8String, -1, nil)
            paramIdx += 1
        }
        sqlite3_bind_int(stmt, paramIdx, Int32(limit))
        sqlite3_bind_int(stmt, paramIdx + 1, Int32(offset))

        var results: [IAMAccessLog] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentIDVal = String(cString: sqlite3_column_text(stmt, 0))
            let resourceVal = String(cString: sqlite3_column_text(stmt, 1))
            let action = String(cString: sqlite3_column_text(stmt, 2))
            let timestampStr = String(cString: sqlite3_column_text(stmt, 3))
            let allowed = sqlite3_column_int(stmt, 4) != 0
            let reason: String? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5)) : nil

            results.append(IAMAccessLog(
                agentID: agentIDVal, resource: resourceVal, action: action,
                timestamp: isoFormatter.date(from: timestampStr) ?? Date(),
                allowed: allowed, reason: reason
            ))
        }

        return results
    }

    func getAccessLogCount(agentID: String? = nil) -> Int {
        var sql = "SELECT COUNT(*) FROM iam_access_log"
        if agentID != nil { sql += " WHERE agent_id = ?" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if let agentID {
            sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Anomaly Detection

    func detectAnomalies() -> [AccessAnomaly] {
        var anomalies: [AccessAnomaly] = []
        let now = Date()

        // 1. Rapid access — more than 100 actions in the last minute per agent
        anomalies += detectRapidAccess(since: now.addingTimeInterval(-60))

        // 2. Denied spike — more than 10 denied actions in the last 5 minutes
        anomalies += detectDeniedSpike(since: now.addingTimeInterval(-300))

        // 3. Unusual resource — agent accessing resource it hasn't accessed before (last 24h)
        anomalies += detectUnusualResources(since: now.addingTimeInterval(-86400))

        // 4. Privilege escalation attempts — repeated denied access to higher-privilege resources
        anomalies += detectEscalationAttempts(since: now.addingTimeInterval(-3600))

        return anomalies
    }

    private func detectRapidAccess(since: Date) -> [AccessAnomaly] {
        let sinceStr = isoFormatter.string(from: since)
        let sql = """
            SELECT agent_id, COUNT(*) as cnt FROM iam_access_log
            WHERE timestamp > ? GROUP BY agent_id HAVING cnt > 100
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sinceStr as NSString).utf8String, -1, nil)

        var results: [AccessAnomaly] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentID = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            results.append(AccessAnomaly(
                agentID: agentID, type: "rapid_access",
                description: "\(count) actions in the last minute (threshold: 100)",
                severity: count > 500 ? "critical" : "high",
                detectedAt: Date()
            ))
        }
        return results
    }

    private func detectDeniedSpike(since: Date) -> [AccessAnomaly] {
        let sinceStr = isoFormatter.string(from: since)
        let sql = """
            SELECT agent_id, COUNT(*) as cnt FROM iam_access_log
            WHERE timestamp > ? AND allowed = 0 GROUP BY agent_id HAVING cnt > 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sinceStr as NSString).utf8String, -1, nil)

        var results: [AccessAnomaly] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentID = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            results.append(AccessAnomaly(
                agentID: agentID, type: "denied_spike",
                description: "\(count) denied actions in the last 5 minutes",
                severity: count > 50 ? "critical" : "medium",
                detectedAt: Date()
            ))
        }
        return results
    }

    private func detectUnusualResources(since: Date) -> [AccessAnomaly] {
        let sinceStr = isoFormatter.string(from: since)
        // Find agents whose most recent access is to a resource they never accessed before the window
        let sql = """
            SELECT l.agent_id, l.resource FROM iam_access_log l
            WHERE l.timestamp > ? AND l.resource NOT IN (
                SELECT DISTINCT resource FROM iam_access_log
                WHERE agent_id = l.agent_id AND timestamp < ?
            )
            GROUP BY l.agent_id, l.resource
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sinceStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sinceStr as NSString).utf8String, -1, nil)

        var results: [AccessAnomaly] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentID = String(cString: sqlite3_column_text(stmt, 0))
            let resource = String(cString: sqlite3_column_text(stmt, 1))
            results.append(AccessAnomaly(
                agentID: agentID, type: "unusual_resource",
                description: "First-time access to '\(resource)' in the last 24h",
                severity: "low",
                detectedAt: Date()
            ))
        }
        return results
    }

    private func detectEscalationAttempts(since: Date) -> [AccessAnomaly] {
        let sinceStr = isoFormatter.string(from: since)
        // Agents with >5 denied actions on execution/admin resources
        let sql = """
            SELECT agent_id, COUNT(*) as cnt FROM iam_access_log
            WHERE timestamp > ? AND allowed = 0
            AND (resource LIKE 'tool:execute_%' OR resource LIKE 'tool:run_%' OR action = 'execute')
            GROUP BY agent_id HAVING cnt > 5
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sinceStr as NSString).utf8String, -1, nil)

        var results: [AccessAnomaly] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentID = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            results.append(AccessAnomaly(
                agentID: agentID, type: "privilege_escalation",
                description: "\(count) denied execution attempts in the last hour",
                severity: "high",
                detectedAt: Date()
            ))
        }
        return results
    }

    // MARK: - Risk Score Calculation

    func calculateRiskScore(agentID: String) -> Float {
        var score: Float = 0.0

        // Factor 1: Number of permissions (more = higher risk)
        let perms = loadPermissions(for: agentID)
        if perms.contains(where: { $0.resource == "*" }) { score += 0.3 }
        if perms.count > 10 { score += 0.15 }
        else if perms.count > 5 { score += 0.1 }

        // Factor 2: Execution permissions (highest risk)
        if perms.contains(where: { $0.actions.contains("execute") }) { score += 0.2 }
        if perms.contains(where: { $0.actions.contains("write") }) { score += 0.1 }

        // Factor 3: Recent denied access count (suspicious behavior)
        let recentDenied = countRecentDenied(agentID: agentID, hours: 24)
        if recentDenied > 20 { score += 0.2 }
        else if recentDenied > 5 { score += 0.1 }

        // Factor 4: Access volume (more activity = more exposure)
        let recentTotal = countRecentAccess(agentID: agentID, hours: 24)
        if recentTotal > 1000 { score += 0.1 }

        // Clamp to 0.0-1.0
        score = min(1.0, max(0.0, score))

        // Update in database
        updateRiskScore(agentID: agentID, score: score)

        return score
    }

    func getRiskScores() -> [String: Float] {
        let sql = "SELECT id, risk_score FROM agent_identities ORDER BY risk_score DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var scores: [String: Float] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let score = Float(sqlite3_column_double(stmt, 1))
            scores[id] = score
        }
        return scores
    }

    // MARK: - Agent Deletion / Auto-Revocation

    func removeAgent(_ id: String) {
        // Cascade deletes permissions (FK constraint), but also clean access log
        execute("DELETE FROM agent_identities WHERE id = '\(id)'")
        identityCache.removeValue(forKey: id)
        permissionCache.removeValue(forKey: id)
        TorboLog.info("Removed agent '\(id)' from IAM (permissions auto-revoked)", subsystem: "IAM")
    }

    // MARK: - Auto-Migration

    func autoMigrateExistingAgents() async {
        let configs = await AgentConfigManager.shared.listAgents()
        var migrated = 0

        for config in configs {
            if agentExists(config.id) { continue }

            registerAgent(id: config.id, owner: "local", purpose: config.role)

            // Map access level to IAM permissions
            let permissions = Self.permissionsForAccessLevel(config.accessLevel)
            for (resource, actions) in permissions {
                grantPermission(agentID: config.id, resource: resource, actions: actions, grantedBy: "migration")
            }

            _ = calculateRiskScore(agentID: config.id)
            migrated += 1
        }

        if migrated > 0 {
            TorboLog.info("Migrated \(migrated) existing agent(s) to IAM", subsystem: "IAM")
        }
    }

    /// Map numeric access level to IAM permission sets
    nonisolated static func permissionsForAccessLevel(_ level: Int) -> [(resource: String, actions: Set<String>)] {
        switch level {
        case 0: // OFF
            return []
        case 1: // CHAT
            return [
                ("tool:web_search", ["use"]),
                ("tool:web_fetch", ["use"])
            ]
        case 2: // READ
            return [
                ("tool:web_search", ["use"]),
                ("tool:web_fetch", ["use"]),
                ("file:*", ["read"]),
                ("tool:list_directory", ["use"]),
                ("tool:read_file", ["use"]),
                ("tool:spotlight_search", ["use"]),
                ("tool:take_screenshot", ["use"])
            ]
        case 3: // WRITE
            return [
                ("tool:web_search", ["use"]),
                ("tool:web_fetch", ["use"]),
                ("file:*", ["read", "write"]),
                ("tool:list_directory", ["use"]),
                ("tool:read_file", ["use"]),
                ("tool:write_file", ["use"]),
                ("tool:spotlight_search", ["use"]),
                ("tool:take_screenshot", ["use"]),
                ("tool:clipboard_read", ["use"]),
                ("tool:clipboard_write", ["use"])
            ]
        case 4: // EXEC
            return [
                ("tool:web_search", ["use"]),
                ("tool:web_fetch", ["use"]),
                ("file:*", ["read", "write"]),
                ("tool:*", ["use"]),
                ("tool:run_command", ["use", "execute"]),
                ("tool:execute_code", ["use", "execute"])
            ]
        case 5: // FULL
            return [
                ("*", ["*"])
            ]
        default:
            return []
        }
    }

    // MARK: - Statistics

    func getStats() -> [String: Any] {
        let agentCount = countRows("agent_identities")
        let permCount = countRows("iam_permissions")
        let logCount = countRows("iam_access_log")
        let deniedCount = countDenied()
        let anomalies = detectAnomalies()

        return [
            "totalAgents": agentCount,
            "totalPermissions": permCount,
            "totalAccessLogs": logCount,
            "totalDenied": deniedCount,
            "activeAnomalies": anomalies.count,
            "anomalies": anomalies.map { $0.asDictionary }
        ]
    }

    // MARK: - Log Pruning

    func pruneOldLogs(olderThanDays: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays * 86400))
        let cutoffStr = isoFormatter.string(from: cutoff)

        let sql = "DELETE FROM iam_access_log WHERE timestamp < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cutoffStr as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                TorboLog.info("Pruned \(deleted) old access log entries (>\(olderThanDays) days)", subsystem: "IAM")
            }
        }
    }

    // MARK: - Private Helpers

    private func agentExists(_ id: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM agent_identities WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    private func loadIdentity(_ id: String) -> AgentIdentity? {
        let sql = "SELECT id, owner, purpose, created_at, risk_score FROM agent_identities WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let idVal = String(cString: sqlite3_column_text(stmt, 0))
        let owner = String(cString: sqlite3_column_text(stmt, 1))
        let purpose = String(cString: sqlite3_column_text(stmt, 2))
        let createdStr = String(cString: sqlite3_column_text(stmt, 3))
        let riskScore = Float(sqlite3_column_double(stmt, 4))

        let perms = loadPermissions(for: idVal)
        let identity = AgentIdentity(
            id: idVal, owner: owner, purpose: purpose,
            createdAt: isoFormatter.date(from: createdStr) ?? Date(),
            permissions: perms, riskScore: riskScore
        )
        identityCache[idVal] = identity
        return identity
    }

    private func loadPermissions(for agentID: String) -> [IAMPermission] {
        if let cached = permissionCache[agentID] { return cached }

        let sql = "SELECT agent_id, resource, actions, granted_at, granted_by FROM iam_permissions WHERE agent_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)

        var perms: [IAMPermission] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let agentIDVal = String(cString: sqlite3_column_text(stmt, 0))
            let resource = String(cString: sqlite3_column_text(stmt, 1))
            let actionsStr = String(cString: sqlite3_column_text(stmt, 2))
            let grantedStr = String(cString: sqlite3_column_text(stmt, 3))
            let grantedBy = String(cString: sqlite3_column_text(stmt, 4))

            let actions = Set(actionsStr.components(separatedBy: ","))
            perms.append(IAMPermission(
                agentID: agentIDVal, resource: resource, actions: actions,
                grantedAt: isoFormatter.date(from: grantedStr) ?? Date(),
                grantedBy: grantedBy
            ))
        }

        permissionCache[agentID] = perms
        return perms
    }

    /// Glob-style resource matching: "file:/Documents/*" matches "file:/Documents/report.txt"
    private func matchesResource(pattern: String, target: String) -> Bool {
        if pattern == target { return true }
        if pattern == "*" { return true }

        // Wildcard suffix: "file:/path/*" matches "file:/path/anything"
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return target.hasPrefix(prefix)
        }

        // Tool wildcard: "tool:*" matches "tool:web_search"
        if pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast()) // "tool:"
            return target.hasPrefix(prefix)
        }

        return false
    }

    private func updateRiskScore(agentID: String, score: Float) {
        let sql = "UPDATE agent_identities SET risk_score = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Double(score))
        sqlite3_bind_text(stmt, 2, (agentID as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)

        if var cached = identityCache[agentID] {
            cached = AgentIdentity(
                id: cached.id, owner: cached.owner, purpose: cached.purpose,
                createdAt: cached.createdAt, permissions: cached.permissions,
                riskScore: score
            )
            identityCache[agentID] = cached
        }
    }

    private func countRecentDenied(agentID: String, hours: Int) -> Int {
        let since = Date().addingTimeInterval(-Double(hours * 3600))
        let sinceStr = isoFormatter.string(from: since)
        let sql = "SELECT COUNT(*) FROM iam_access_log WHERE agent_id = ? AND allowed = 0 AND timestamp > ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sinceStr as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func countRecentAccess(agentID: String, hours: Int) -> Int {
        let since = Date().addingTimeInterval(-Double(hours * 3600))
        let sinceStr = isoFormatter.string(from: since)
        let sql = "SELECT COUNT(*) FROM iam_access_log WHERE agent_id = ? AND timestamp > ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (agentID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sinceStr as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func countRows(_ table: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(table)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func countDenied() -> Int {
        let sql = "SELECT COUNT(*) FROM iam_access_log WHERE allowed = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func execute(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            TorboLog.error("SQL error: \(msg)", subsystem: "IAM")
        }
    }
}
