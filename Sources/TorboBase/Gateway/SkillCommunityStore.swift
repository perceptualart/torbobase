// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Community Store
// SQLite persistence for the federated skill sharing network.
// Separate database (skill_community.db) to avoid interference with LoA.

import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Persistent storage for community skills, knowledge, peers, and preferences.
actor SkillCommunityStore {
    static let shared = SkillCommunityStore()

    private var db: OpaquePointer?
    private let dbPath: String
    private var isReady = false

    init() {
        let appSupport = PlatformPaths.appSupportDir
        let dir = appSupport.appendingPathComponent("TorboBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("skill_community.db").path
    }

    // MARK: - Lifecycle

    func initialize() async {
        guard !isReady else { return }

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            TorboLog.error("Failed to open community database: \(dbPath)", subsystem: "Community")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        createTables()
        isReady = true
        TorboLog.info("Community store initialized at \(dbPath)", subsystem: "Community")
    }

    private func createTables() {
        // Node identity (single row)
        exec("""
            CREATE TABLE IF NOT EXISTS node_identity (
                node_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                public_key TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)

        // Published skills catalog
        exec("""
            CREATE TABLE IF NOT EXISTS published_skills (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                version TEXT NOT NULL,
                author TEXT NOT NULL,
                author_node_id TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT 'puzzlepiece',
                tags TEXT NOT NULL DEFAULT '[]',
                package_hash TEXT NOT NULL,
                signature TEXT NOT NULL,
                published_at TEXT NOT NULL,
                rating REAL NOT NULL DEFAULT 0.0,
                rating_count INTEGER NOT NULL DEFAULT 0,
                download_count INTEGER NOT NULL DEFAULT 0,
                contributors INTEGER NOT NULL DEFAULT 0,
                knowledge_count INTEGER NOT NULL DEFAULT 0
            )
        """)

        // Version history
        exec("""
            CREATE TABLE IF NOT EXISTS skill_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                skill_id TEXT NOT NULL,
                version TEXT NOT NULL,
                changelog TEXT NOT NULL DEFAULT '',
                package_hash TEXT NOT NULL,
                signature TEXT NOT NULL,
                published_at TEXT NOT NULL
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sv_skill ON skill_versions(skill_id)")

        // Ratings
        exec("""
            CREATE TABLE IF NOT EXISTS skill_ratings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                skill_id TEXT NOT NULL,
                node_id TEXT NOT NULL,
                rating INTEGER NOT NULL,
                review TEXT,
                created_at TEXT NOT NULL,
                UNIQUE(skill_id, node_id)
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sr_skill ON skill_ratings(skill_id)")

        // Knowledge contributions (the wiki-LLM layer)
        exec("""
            CREATE TABLE IF NOT EXISTS knowledge_contributions (
                id TEXT PRIMARY KEY,
                skill_id TEXT NOT NULL,
                text TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'tip',
                confidence REAL NOT NULL DEFAULT 0.8,
                content_hash TEXT NOT NULL,
                signature TEXT NOT NULL,
                author_node_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                upvotes INTEGER NOT NULL DEFAULT 0,
                downvotes INTEGER NOT NULL DEFAULT 0,
                synced INTEGER NOT NULL DEFAULT 0
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_kc_skill ON knowledge_contributions(skill_id)")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_kc_hash ON knowledge_contributions(content_hash)")

        // Sharing preferences
        exec("""
            CREATE TABLE IF NOT EXISTS sharing_prefs (
                skill_id TEXT PRIMARY KEY,
                share_knowledge INTEGER NOT NULL DEFAULT 0,
                receive_knowledge INTEGER NOT NULL DEFAULT 1
            )
        """)

        // Peer nodes
        exec("""
            CREATE TABLE IF NOT EXISTS peer_nodes (
                node_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                last_seen TEXT NOT NULL,
                skill_count INTEGER NOT NULL DEFAULT 0,
                knowledge_count INTEGER NOT NULL DEFAULT 0
            )
        """)
    }

    // MARK: - Node Identity

    func getIdentity() -> NodeIdentity? {
        let sql = "SELECT node_id, display_name, public_key, created_at FROM node_identity LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return NodeIdentity(
            nodeID: String(cString: sqlite3_column_text(stmt, 0)),
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            publicKey: String(cString: sqlite3_column_text(stmt, 2)),
            createdAt: String(cString: sqlite3_column_text(stmt, 3))
        )
    }

    func saveIdentity(_ identity: NodeIdentity) {
        let sql = """
            INSERT OR REPLACE INTO node_identity (node_id, display_name, public_key, created_at)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (identity.nodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (identity.displayName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (identity.publicKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (identity.createdAt as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    // MARK: - Published Skills

    func savePublishedSkill(_ skill: PublishedSkill) {
        let sql = """
            INSERT OR REPLACE INTO published_skills
            (id, name, description, version, author, author_node_id, icon, tags,
             package_hash, signature, published_at, rating, rating_count,
             download_count, contributors, knowledge_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let tagsJSON = (try? JSONSerialization.data(withJSONObject: skill.tags))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (skill.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (skill.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (skill.description as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (skill.version as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (skill.author as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (skill.authorNodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (skill.icon as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (tagsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (skill.packageHash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 10, (skill.signature as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 11, (skill.publishedAt as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 12, skill.rating)
        sqlite3_bind_int(stmt, 13, Int32(skill.ratingCount))
        sqlite3_bind_int(stmt, 14, Int32(skill.downloadCount))
        sqlite3_bind_int(stmt, 15, Int32(skill.contributors))
        sqlite3_bind_int(stmt, 16, Int32(skill.knowledgeCount))
        sqlite3_step(stmt)
    }

    func getPublishedSkill(_ id: String) -> PublishedSkill? {
        let sql = "SELECT * FROM published_skills WHERE id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return publishedSkillFromRow(stmt)
    }

    func browsePublishedSkills(query: String? = nil, tag: String? = nil,
                                page: Int = 1, limit: Int = 20,
                                sort: String = "newest") -> [String: Any] {
        var conditions: [String] = []
        var params: [String] = []

        if let query, !query.isEmpty {
            conditions.append("(name LIKE ? OR description LIKE ?)")
            params.append("%\(query)%")
            params.append("%\(query)%")
        }
        if let tag, !tag.isEmpty {
            conditions.append("tags LIKE ?")
            params.append("%\"\(tag)\"%")
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let orderBy: String
        switch sort {
        case "rating": orderBy = "rating DESC"
        case "downloads": orderBy = "download_count DESC"
        case "oldest": orderBy = "published_at ASC"
        default: orderBy = "published_at DESC"
        }

        let offset = (max(1, page) - 1) * limit
        let sql = "SELECT * FROM published_skills \(whereClause) ORDER BY \(orderBy) LIMIT ? OFFSET ?"
        let countSQL = "SELECT COUNT(*) FROM published_skills \(whereClause)"

        // Count
        var totalCount = 0
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            for (i, param) in params.enumerated() {
                sqlite3_bind_text(countStmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
            }
            if sqlite3_step(countStmt) == SQLITE_ROW {
                totalCount = Int(sqlite3_column_int(countStmt, 0))
            }
        }
        sqlite3_finalize(countStmt)

        // Results
        var skills: [[String: Any]] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, param) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
            }
            sqlite3_bind_int(stmt, Int32(params.count + 1), Int32(limit))
            sqlite3_bind_int(stmt, Int32(params.count + 2), Int32(offset))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let skill = publishedSkillFromRow(stmt) {
                    skills.append(skill.toDict())
                }
            }
        }
        sqlite3_finalize(stmt)

        return ["skills": skills, "total": totalCount, "page": page, "limit": limit]
    }

    func deletePublishedSkill(_ id: String) {
        execBind("DELETE FROM published_skills WHERE id = ?", params: [id])
        execBind("DELETE FROM skill_versions WHERE skill_id = ?", params: [id])
        execBind("DELETE FROM skill_ratings WHERE skill_id = ?", params: [id])
        execBind("DELETE FROM knowledge_contributions WHERE skill_id = ?", params: [id])
        execBind("DELETE FROM sharing_prefs WHERE skill_id = ?", params: [id])
    }

    // MARK: - Skill Versions

    func saveVersion(_ version: SkillVersion) {
        let sql = """
            INSERT INTO skill_versions (skill_id, version, changelog, package_hash, signature, published_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (version.skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (version.version as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (version.changelog as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (version.packageHash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (version.signature as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (version.publishedAt as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func getVersions(forSkill skillID: String) -> [SkillVersion] {
        let sql = "SELECT skill_id, version, changelog, package_hash, signature, published_at FROM skill_versions WHERE skill_id = ? ORDER BY published_at DESC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [SkillVersion] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(SkillVersion(
                skillID: String(cString: sqlite3_column_text(stmt, 0)),
                version: String(cString: sqlite3_column_text(stmt, 1)),
                changelog: String(cString: sqlite3_column_text(stmt, 2)),
                packageHash: String(cString: sqlite3_column_text(stmt, 3)),
                signature: String(cString: sqlite3_column_text(stmt, 4)),
                publishedAt: String(cString: sqlite3_column_text(stmt, 5))
            ))
        }
        return results
    }

    // MARK: - Ratings

    func saveRating(_ rating: SkillRating) {
        let sql = """
            INSERT OR REPLACE INTO skill_ratings (skill_id, node_id, rating, review, created_at)
            VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (rating.skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (rating.nodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(rating.rating))
        if let review = rating.review {
            sqlite3_bind_text(stmt, 4, (review as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, (rating.createdAt as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)

        // Recalculate average
        recalculateRating(skillID: rating.skillID)
    }

    func getRatings(forSkill skillID: String) -> [SkillRating] {
        let sql = "SELECT skill_id, node_id, rating, review, created_at FROM skill_ratings WHERE skill_id = ? ORDER BY created_at DESC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [SkillRating] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let review: String? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 3)) : nil
            results.append(SkillRating(
                skillID: String(cString: sqlite3_column_text(stmt, 0)),
                nodeID: String(cString: sqlite3_column_text(stmt, 1)),
                rating: Int(sqlite3_column_int(stmt, 2)),
                review: review,
                createdAt: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return results
    }

    private func recalculateRating(skillID: String) {
        let sql = "SELECT AVG(rating), COUNT(*) FROM skill_ratings WHERE skill_id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let avg = sqlite3_column_double(stmt, 0)
            let count = sqlite3_column_int(stmt, 1)
            execBind("UPDATE published_skills SET rating = ?, rating_count = ? WHERE id = ?",
                     doubles: [avg], ints: [Int(count)], texts: [skillID])
        }
    }

    // MARK: - Knowledge Contributions

    func saveKnowledge(_ contribution: KnowledgeContribution) {
        let sql = """
            INSERT OR IGNORE INTO knowledge_contributions
            (id, skill_id, text, category, confidence, content_hash, signature,
             author_node_id, created_at, upvotes, downvotes, synced)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (contribution.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (contribution.skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (contribution.text as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (contribution.category.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, contribution.confidence)
        sqlite3_bind_text(stmt, 6, (contribution.contentHash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (contribution.signature as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (contribution.authorNodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (contribution.createdAt as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 10, Int32(contribution.upvotes))
        sqlite3_bind_int(stmt, 11, Int32(contribution.downvotes))
        sqlite3_bind_int(stmt, 12, contribution.synced ? 1 : 0)
        sqlite3_step(stmt)

        // Update knowledge count on the skill
        let countSQL = "SELECT COUNT(*) FROM knowledge_contributions WHERE skill_id = ?"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (contribution.skillID as NSString).utf8String, -1, nil)
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(countStmt, 0))
                execBind("UPDATE published_skills SET knowledge_count = ? WHERE id = ?",
                         ints: [count], texts: [contribution.skillID])
            }
        }
        sqlite3_finalize(countStmt)
    }

    func getKnowledge(forSkill skillID: String, page: Int = 1, limit: Int = 50) -> [[String: Any]] {
        let offset = (max(1, page) - 1) * limit
        let sql = """
            SELECT id, skill_id, text, category, confidence, content_hash, signature,
                   author_node_id, created_at, upvotes, downvotes, synced
            FROM knowledge_contributions WHERE skill_id = ?
            ORDER BY (upvotes - downvotes) DESC, created_at DESC LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [[String: Any]] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(knowledgeFromRow(stmt).toDict())
        }
        return results
    }

    func topKnowledge(forSkill skillID: String, topK: Int = 10) -> [KnowledgeContribution] {
        let sql = """
            SELECT id, skill_id, text, category, confidence, content_hash, signature,
                   author_node_id, created_at, upvotes, downvotes, synced
            FROM knowledge_contributions WHERE skill_id = ? AND (upvotes - downvotes) >= 0
            ORDER BY (upvotes - downvotes) DESC, confidence DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [KnowledgeContribution] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(topK))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(knowledgeFromRow(stmt))
        }
        return results
    }

    func pendingKnowledgeForSync(limit: Int = 50) -> [KnowledgeContribution] {
        let sql = """
            SELECT id, skill_id, text, category, confidence, content_hash, signature,
                   author_node_id, created_at, upvotes, downvotes, synced
            FROM knowledge_contributions WHERE synced = 0 LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [KnowledgeContribution] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(knowledgeFromRow(stmt))
        }
        return results
    }

    func markKnowledgeSynced(ids: [String]) {
        for id in ids {
            execBind("UPDATE knowledge_contributions SET synced = 1 WHERE id = ?", params: [id])
        }
    }

    func voteKnowledge(id: String, upvote: Bool) {
        let col = upvote ? "upvotes" : "downvotes"
        execBind("UPDATE knowledge_contributions SET \(col) = \(col) + 1 WHERE id = ?", params: [id])
    }

    func knowledgeExistsWithHash(_ hash: String) -> Bool {
        let sql = "SELECT 1 FROM knowledge_contributions WHERE content_hash = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Count knowledge contributions from a specific node for a skill in the last hour.
    func recentKnowledgeCount(skillID: String, nodeID: String) -> Int {
        let oneHourAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let sql = "SELECT COUNT(*) FROM knowledge_contributions WHERE skill_id = ? AND author_node_id = ? AND created_at > ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (nodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (oneHourAgo as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Sharing Preferences

    func getPrefs(forSkill skillID: String) -> SkillSharingPrefs {
        let sql = "SELECT skill_id, share_knowledge, receive_knowledge FROM sharing_prefs WHERE skill_id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SkillSharingPrefs(skillID: skillID, shareKnowledge: false, receiveKnowledge: true)
        }
        sqlite3_bind_text(stmt, 1, (skillID as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return SkillSharingPrefs(
                skillID: String(cString: sqlite3_column_text(stmt, 0)),
                shareKnowledge: sqlite3_column_int(stmt, 1) != 0,
                receiveKnowledge: sqlite3_column_int(stmt, 2) != 0
            )
        }
        return SkillSharingPrefs(skillID: skillID, shareKnowledge: false, receiveKnowledge: true)
    }

    func savePrefs(_ prefs: SkillSharingPrefs) {
        let sql = """
            INSERT OR REPLACE INTO sharing_prefs (skill_id, share_knowledge, receive_knowledge)
            VALUES (?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (prefs.skillID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, prefs.shareKnowledge ? 1 : 0)
        sqlite3_bind_int(stmt, 3, prefs.receiveKnowledge ? 1 : 0)
        sqlite3_step(stmt)
    }

    func allPrefs() -> [SkillSharingPrefs] {
        let sql = "SELECT skill_id, share_knowledge, receive_knowledge FROM sharing_prefs"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [SkillSharingPrefs] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(SkillSharingPrefs(
                skillID: String(cString: sqlite3_column_text(stmt, 0)),
                shareKnowledge: sqlite3_column_int(stmt, 1) != 0,
                receiveKnowledge: sqlite3_column_int(stmt, 2) != 0
            ))
        }
        return results
    }

    // MARK: - Peer Nodes

    func savePeer(_ peer: PeerNode) {
        let sql = """
            INSERT OR REPLACE INTO peer_nodes
            (node_id, display_name, host, port, last_seen, skill_count, knowledge_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (peer.nodeID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (peer.displayName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (peer.host as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(peer.port))
        sqlite3_bind_text(stmt, 5, (peer.lastSeen as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 6, Int32(peer.skillCount))
        sqlite3_bind_int(stmt, 7, Int32(peer.knowledgeCount))
        sqlite3_step(stmt)
    }

    func allPeers() -> [PeerNode] {
        let sql = "SELECT node_id, display_name, host, port, last_seen, skill_count, knowledge_count FROM peer_nodes ORDER BY last_seen DESC"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var results: [PeerNode] = []

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(PeerNode(
                nodeID: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                host: String(cString: sqlite3_column_text(stmt, 2)),
                port: Int(sqlite3_column_int(stmt, 3)),
                lastSeen: String(cString: sqlite3_column_text(stmt, 4)),
                skillCount: Int(sqlite3_column_int(stmt, 5)),
                knowledgeCount: Int(sqlite3_column_int(stmt, 6))
            ))
        }
        return results
    }

    func removeStalePeers(olderThan hours: Int = 24) {
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(hours * 3600)))
        execBind("DELETE FROM peer_nodes WHERE last_seen < ?", params: [cutoff])
    }

    // MARK: - Stats

    func communityStats() -> [String: Any] {
        var stats: [String: Any] = [:]

        stats["published_skills"] = countTable("published_skills")
        stats["knowledge_entries"] = countTable("knowledge_contributions")
        stats["peer_nodes"] = countTable("peer_nodes")
        stats["ratings"] = countTable("skill_ratings")

        // Skills with sharing enabled
        let shareSQL = "SELECT COUNT(*) FROM sharing_prefs WHERE share_knowledge = 1"
        var shareStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, shareSQL, -1, &shareStmt, nil) == SQLITE_OK,
           sqlite3_step(shareStmt) == SQLITE_ROW {
            stats["skills_sharing"] = Int(sqlite3_column_int(shareStmt, 0))
        }
        sqlite3_finalize(shareStmt)

        // Unsynced knowledge
        let unsyncedSQL = "SELECT COUNT(*) FROM knowledge_contributions WHERE synced = 0"
        var unsyncedStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, unsyncedSQL, -1, &unsyncedStmt, nil) == SQLITE_OK,
           sqlite3_step(unsyncedStmt) == SQLITE_ROW {
            stats["unsynced_knowledge"] = Int(sqlite3_column_int(unsyncedStmt, 0))
        }
        sqlite3_finalize(unsyncedStmt)

        return stats
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            TorboLog.error("SQL error: \(errmsg) — \(sql.prefix(100))", subsystem: "Community")
        }
    }

    private func execBind(_ sql: String, params: [String] = [], doubles: [Double] = [], ints: [Int] = [], texts: [String] = []) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var idx: Int32 = 1
        for param in params {
            sqlite3_bind_text(stmt, idx, (param as NSString).utf8String, -1, nil)
            idx += 1
        }
        for d in doubles {
            sqlite3_bind_double(stmt, idx, d)
            idx += 1
        }
        for i in ints {
            sqlite3_bind_int(stmt, idx, Int32(i))
            idx += 1
        }
        for t in texts {
            sqlite3_bind_text(stmt, idx, (t as NSString).utf8String, -1, nil)
            idx += 1
        }
        sqlite3_step(stmt)
    }

    private func countTable(_ table: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(table)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func publishedSkillFromRow(_ stmt: OpaquePointer?) -> PublishedSkill? {
        guard let stmt else { return nil }
        let tagsStr = String(cString: sqlite3_column_text(stmt, 7))
        let tags = (try? JSONSerialization.jsonObject(with: Data(tagsStr.utf8)) as? [String]) ?? []

        return PublishedSkill(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            description: String(cString: sqlite3_column_text(stmt, 2)),
            version: String(cString: sqlite3_column_text(stmt, 3)),
            author: String(cString: sqlite3_column_text(stmt, 4)),
            authorNodeID: String(cString: sqlite3_column_text(stmt, 5)),
            icon: String(cString: sqlite3_column_text(stmt, 6)),
            tags: tags,
            packageHash: String(cString: sqlite3_column_text(stmt, 8)),
            signature: String(cString: sqlite3_column_text(stmt, 9)),
            publishedAt: String(cString: sqlite3_column_text(stmt, 10)),
            rating: sqlite3_column_double(stmt, 11),
            ratingCount: Int(sqlite3_column_int(stmt, 12)),
            downloadCount: Int(sqlite3_column_int(stmt, 13)),
            contributors: Int(sqlite3_column_int(stmt, 14)),
            knowledgeCount: Int(sqlite3_column_int(stmt, 15))
        )
    }

    private func knowledgeFromRow(_ stmt: OpaquePointer?) -> KnowledgeContribution {
        KnowledgeContribution(
            id: String(cString: sqlite3_column_text(stmt!, 0)),
            skillID: String(cString: sqlite3_column_text(stmt!, 1)),
            text: String(cString: sqlite3_column_text(stmt!, 2)),
            category: KnowledgeCategory(rawValue: String(cString: sqlite3_column_text(stmt!, 3))) ?? .tip,
            confidence: sqlite3_column_double(stmt!, 4),
            contentHash: String(cString: sqlite3_column_text(stmt!, 5)),
            signature: String(cString: sqlite3_column_text(stmt!, 6)),
            authorNodeID: String(cString: sqlite3_column_text(stmt!, 7)),
            createdAt: String(cString: sqlite3_column_text(stmt!, 8)),
            upvotes: Int(sqlite3_column_int(stmt!, 9)),
            downvotes: Int(sqlite3_column_int(stmt!, 10)),
            synced: sqlite3_column_int(stmt!, 11) != 0
        )
    }
}
