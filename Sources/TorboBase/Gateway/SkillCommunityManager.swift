// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Community Manager
// Orchestrates skill publishing, peer discovery, knowledge sharing, and sync.
// The brain of the federated skill network and wiki-LLM knowledge layer.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates the community skill network: publishing, installing, knowledge flow, peer sync.
actor SkillCommunityManager {
    static let shared = SkillCommunityManager()

    private let store = SkillCommunityStore.shared
    private var syncTask: Task<Void, Never>?
    private var identity: NodeIdentity?
    private let syncInterval: TimeInterval = 15 * 60 // 15 minutes
    private let maxKnowledgePerHour = 10

    // MARK: - Lifecycle

    func initialize() async {
        await store.initialize()
        identity = await ensureIdentity()
        TorboLog.info("Community manager initialized — node: \(identity?.nodeID ?? "unknown")", subsystem: "Community")
    }

    /// Ensure this node has a persistent identity.
    private func ensureIdentity() async -> NodeIdentity {
        if let existing = await store.getIdentity() {
            return existing
        }

        let keys = SkillIntegrityVerifier.ensureKeyPair()
        let now = ISO8601DateFormatter().string(from: Date())
        let hostname = ProcessInfo.processInfo.hostName
        let displayName = hostname.components(separatedBy: ".").first ?? hostname

        let newIdentity = NodeIdentity(
            nodeID: keys.nodeID,
            displayName: displayName,
            publicKey: keys.publicKey,
            createdAt: now
        )
        await store.saveIdentity(newIdentity)
        return newIdentity
    }

    // MARK: - Identity

    func getIdentity() async -> NodeIdentity? {
        if identity == nil {
            identity = await store.getIdentity()
        }
        return identity
    }

    // MARK: - Publishing

    /// Publish a local skill to the community network.
    func publishSkill(skillID: String, changelog: String = "Initial release") async -> PublishedSkill? {
        guard let identity = await getIdentity() else {
            TorboLog.error("Cannot publish: no node identity", subsystem: "Community")
            return nil
        }

        // Export the skill as a .tbskill package
        let packageURL: URL
        do {
            packageURL = try SkillPackageManager.export(skillID: skillID)
        } catch {
            TorboLog.error("Cannot publish '\(skillID)': export failed — \(error)", subsystem: "Community")
            return nil
        }

        // Hash and sign the package
        let hash: String
        do {
            hash = try SkillIntegrityVerifier.hashPackage(at: packageURL)
        } catch {
            TorboLog.error("Cannot publish '\(skillID)': hash failed — \(error)", subsystem: "Community")
            return nil
        }
        let signature = SkillIntegrityVerifier.sign(string: hash)

        // Get skill metadata from the manifest
        let manifest: SkillManifest
        do {
            manifest = try SkillPackageManager.validate(at: packageURL)
        } catch {
            TorboLog.error("Cannot publish '\(skillID)': validation failed — \(error)", subsystem: "Community")
            return nil
        }

        let now = ISO8601DateFormatter().string(from: Date())

        // Check if already published (update version)
        let existingVersion: String?
        if let existing = await store.getPublishedSkill(skillID) {
            existingVersion = existing.version
        } else {
            existingVersion = nil
        }

        let published = PublishedSkill(
            id: skillID,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            author: identity.displayName,
            authorNodeID: identity.nodeID,
            icon: manifest.icon,
            tags: manifest.tags,
            packageHash: hash,
            signature: signature,
            publishedAt: now,
            rating: 0.0,
            ratingCount: 0,
            downloadCount: 0,
            contributors: 0,
            knowledgeCount: 0
        )

        await store.savePublishedSkill(published)

        // Save version entry
        let version = SkillVersion(
            skillID: skillID,
            version: manifest.version,
            changelog: changelog,
            packageHash: hash,
            signature: signature,
            publishedAt: now
        )
        await store.saveVersion(version)

        // Create default sharing prefs (share off, receive on)
        let prefs = SkillSharingPrefs(skillID: skillID, shareKnowledge: false, receiveKnowledge: true)
        await store.savePrefs(prefs)

        // Cache the .tbskill in skill_packages/
        cachePackage(packageURL, skillID: skillID, version: manifest.version)

        if let existingVersion {
            TorboLog.info("Updated '\(skillID)' v\(existingVersion) → v\(manifest.version)", subsystem: "Community")
        } else {
            TorboLog.info("Published '\(skillID)' v\(manifest.version)", subsystem: "Community")
        }

        // Announce to known peers (fire-and-forget)
        Task { await announceToPeers() }

        return published
    }

    // MARK: - Install from Community

    /// Install a skill from the community (from peer or cached package).
    func installCommunitySkill(skillID: String, fromPeer peerNodeID: String? = nil) async -> String? {
        guard let published = await store.getPublishedSkill(skillID) else {
            TorboLog.warn("Skill '\(skillID)' not found in community catalog", subsystem: "Community")
            return nil
        }

        // Try to find cached package first
        let cachedPath = packageCachePath(skillID: skillID, version: published.version)
        var packageURL: URL

        if FileManager.default.fileExists(atPath: cachedPath.path) {
            packageURL = cachedPath
        } else if let peerNodeID, let peer = await findPeer(peerNodeID) {
            // Download from peer
            guard let downloaded = await downloadPackageFromPeer(skillID: skillID, peer: peer) else {
                TorboLog.warn("Failed to download '\(skillID)' from peer \(peerNodeID)", subsystem: "Community")
                return nil
            }
            packageURL = downloaded
        } else {
            TorboLog.warn("No package available for '\(skillID)'", subsystem: "Community")
            return nil
        }

        // Verify hash
        do {
            let hash = try SkillIntegrityVerifier.hashPackage(at: packageURL)
            guard hash == published.packageHash else {
                TorboLog.error("Hash mismatch for '\(skillID)' — expected \(published.packageHash.prefix(8)), got \(hash.prefix(8))", subsystem: "Community")
                return nil
            }
        } catch {
            TorboLog.error("Cannot verify '\(skillID)': \(error)", subsystem: "Community")
            return nil
        }

        // Verify signature (best-effort: only enforce if we have the publisher's key)
        if published.authorNodeID == identity?.nodeID,
           let pubKey = identity?.publicKey,
           !SkillIntegrityVerifier.verify(string: published.packageHash, signature: published.signature, publicKey: pubKey) {
            TorboLog.error("Signature verification failed for '\(skillID)'", subsystem: "Community")
            return nil
        }

        // Import via SkillPackageManager
        do {
            let installedID = try SkillPackageManager.importPackage(from: packageURL)

            // Create default sharing prefs
            let prefs = SkillSharingPrefs(skillID: installedID, shareKnowledge: false, receiveKnowledge: true)
            await store.savePrefs(prefs)

            // Increment download count
            var updated = published
            updated.downloadCount += 1
            await store.savePublishedSkill(updated)

            TorboLog.info("Installed community skill '\(installedID)'", subsystem: "Community")
            return installedID
        } catch {
            TorboLog.error("Failed to install '\(skillID)': \(error)", subsystem: "Community")
            return nil
        }
    }

    // MARK: - Knowledge Contribution

    /// Contribute a domain knowledge entry for a skill.
    func contributeKnowledge(skillID: String, text: String,
                             category: KnowledgeCategory = .tip,
                             confidence: Double = 0.8) async -> Bool {
        guard let identity = await getIdentity() else { return false }

        // Check sharing prefs
        let prefs = await store.getPrefs(forSkill: skillID)
        guard prefs.shareKnowledge else {
            TorboLog.debug("Knowledge sharing disabled for '\(skillID)'", subsystem: "Community")
            return false
        }

        // Rate limit: max 10 per skill per hour per node
        let recentCount = await store.recentKnowledgeCount(skillID: skillID, nodeID: identity.nodeID)
        guard recentCount < maxKnowledgePerHour else {
            TorboLog.warn("Rate limit hit: \(recentCount) contributions for '\(skillID)' in last hour", subsystem: "Community")
            return false
        }

        // Hash for dedup
        let contentHash = SkillIntegrityVerifier.sha256Hash(text)

        // Check for duplicate
        let exists = await store.knowledgeExistsWithHash(contentHash)
        if exists {
            TorboLog.debug("Duplicate knowledge skipped (hash: \(contentHash.prefix(8)))", subsystem: "Community")
            return false
        }

        // Sign
        let signature = SkillIntegrityVerifier.sign(string: contentHash)

        let contribution = KnowledgeContribution(
            id: UUID().uuidString,
            skillID: skillID,
            text: text,
            category: category,
            confidence: confidence,
            contentHash: contentHash,
            signature: signature,
            authorNodeID: identity.nodeID,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            upvotes: 0,
            downvotes: 0,
            synced: false
        )

        await store.saveKnowledge(contribution)
        TorboLog.info("Knowledge contributed for '\(skillID)': \(text.prefix(60))...", subsystem: "Community")
        return true
    }

    /// Get formatted community knowledge block for prompt injection.
    func communityKnowledgeBlock(forSkill skillID: String, maxTokens: Int = 500) async -> String {
        let prefs = await store.getPrefs(forSkill: skillID)
        guard prefs.receiveKnowledge else { return "" }

        let entries = await store.topKnowledge(forSkill: skillID, topK: 15)
        guard !entries.isEmpty else { return "" }

        var lines: [String] = []
        var estimatedTokens = 0

        for entry in entries {
            let line = "[\(entry.category.rawValue)] \(entry.text)"
            let tokens = line.count / 4 // rough estimate
            if estimatedTokens + tokens > maxTokens { break }
            lines.append(line)
            estimatedTokens += tokens
        }

        guard !lines.isEmpty else { return "" }

        let skillName = (await store.getPublishedSkill(skillID))?.name ?? skillID
        return "<community-knowledge skill=\"\(skillName)\">\n" +
               lines.joined(separator: "\n") +
               "\n</community-knowledge>"
    }

    // MARK: - Ratings

    func rateSkill(skillID: String, rating: Int, review: String? = nil) async {
        guard let identity = await getIdentity() else { return }
        let clamped = max(1, min(5, rating))

        let skillRating = SkillRating(
            skillID: skillID,
            nodeID: identity.nodeID,
            rating: clamped,
            review: review,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        await store.saveRating(skillRating)
    }

    // MARK: - Sync

    func startPeriodicSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(15 * 60 * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.syncKnowledge()
            }
        }
        TorboLog.info("Periodic sync started (every 15 min)", subsystem: "Community")
    }

    func stopPeriodicSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Push unsynced knowledge to peers, pull from peers.
    func syncKnowledge() async {
        let pending = await store.pendingKnowledgeForSync(limit: 50)
        if !pending.isEmpty {
            TorboLog.info("Syncing \(pending.count) knowledge entries to peers", subsystem: "Community")
            // Push to known peers
            let peers = await store.allPeers()
            for peer in peers {
                await pushKnowledgeToPeer(contributions: pending, peer: peer)
            }
            // Mark as synced
            await store.markKnowledgeSynced(ids: pending.map(\.id))
        }

        // Clean up stale peers
        await store.removeStalePeers(olderThan: 48)
    }

    // MARK: - Peer Discovery

    /// Discover peers via Bonjour and known Tailscale hosts.
    func discoverPeers() async {
        // Probe known peers to check liveness
        let existingPeers = await store.allPeers()
        for peer in existingPeers {
            await probePeer(host: peer.host, port: peer.port)
        }
    }

    /// Handle an incoming peer announcement.
    func handlePeerAnnouncement(_ data: [String: Any]) async {
        guard let nodeID = data["node_id"] as? String,
              let host = data["host"] as? String,
              let port = data["port"] as? Int else { return }

        // Don't add self
        if nodeID == identity?.nodeID { return }

        let peer = PeerNode(
            nodeID: nodeID,
            displayName: data["display_name"] as? String ?? "",
            host: host,
            port: port,
            lastSeen: ISO8601DateFormatter().string(from: Date()),
            skillCount: data["skill_count"] as? Int ?? 0,
            knowledgeCount: data["knowledge_count"] as? Int ?? 0
        )
        await store.savePeer(peer)
        TorboLog.info("Peer discovered: \(peer.displayName) (\(host):\(port))", subsystem: "Community")
    }

    /// Import knowledge entries received from a peer (P2P sync).
    func importKnowledgeFromPeer(entries: [[String: Any]]) async -> Int {
        var imported = 0
        for entry in entries {
            guard let skillID = entry["skill_id"] as? String,
                  let text = entry["text"] as? String,
                  let categoryStr = entry["category"] as? String,
                  let category = KnowledgeCategory(rawValue: categoryStr),
                  let contentHash = entry["content_hash"] as? String else { continue }

            // Check sharing prefs for receiving
            let prefs = await store.getPrefs(forSkill: skillID)
            guard prefs.receiveKnowledge else { continue }

            // Dedup
            let exists = await store.knowledgeExistsWithHash(contentHash)
            if exists { continue }

            let contribution = KnowledgeContribution(
                id: entry["id"] as? String ?? UUID().uuidString,
                skillID: skillID,
                text: text,
                category: category,
                confidence: entry["confidence"] as? Double ?? 0.7,
                contentHash: contentHash,
                signature: entry["signature"] as? String ?? "",
                authorNodeID: entry["author_node_id"] as? String ?? "unknown",
                createdAt: entry["created_at"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                upvotes: entry["upvotes"] as? Int ?? 0,
                downvotes: entry["downvotes"] as? Int ?? 0,
                synced: true // Already received from peer
            )
            await store.saveKnowledge(contribution)
            imported += 1
        }
        if imported > 0 {
            TorboLog.info("Imported \(imported) knowledge entries from peer", subsystem: "Community")
        }
        return imported
    }

    // MARK: - Stats & Browse

    func communityStats() async -> [String: Any] {
        var stats = await store.communityStats()
        if let id = identity {
            stats["node_id"] = id.nodeID
            stats["display_name"] = id.displayName
        }
        return stats
    }

    func browseSkills(query: String? = nil, tag: String? = nil,
                      page: Int = 1, limit: Int = 20, sort: String = "newest") async -> [String: Any] {
        return await store.browsePublishedSkills(query: query, tag: tag, page: page, limit: limit, sort: sort)
    }

    func getSkillDetail(skillID: String) async -> [String: Any]? {
        guard let skill = await store.getPublishedSkill(skillID) else { return nil }
        let versions = await store.getVersions(forSkill: skillID)
        let ratings = await store.getRatings(forSkill: skillID)
        let knowledge = await store.getKnowledge(forSkill: skillID, page: 1, limit: 10)

        return [
            "skill": skill.toDict(),
            "versions": versions.map { $0.toDict() },
            "ratings": ratings.map { $0.toDict() },
            "knowledge": knowledge,
            "knowledge_count": await store.topKnowledge(forSkill: skillID, topK: 1000).count
        ] as [String: Any]
    }

    // MARK: - Prefs

    func getPrefs(forSkill skillID: String) async -> SkillSharingPrefs {
        return await store.getPrefs(forSkill: skillID)
    }

    func setPrefs(_ prefs: SkillSharingPrefs) async {
        await store.savePrefs(prefs)
    }

    func allPrefs() async -> [SkillSharingPrefs] {
        return await store.allPrefs()
    }

    // MARK: - Peers

    func allPeers() async -> [PeerNode] {
        return await store.allPeers()
    }

    // MARK: - Knowledge CRUD

    func getKnowledge(forSkill skillID: String, page: Int = 1, limit: Int = 50) async -> [[String: Any]] {
        return await store.getKnowledge(forSkill: skillID, page: page, limit: limit)
    }

    func voteKnowledge(id: String, upvote: Bool) async {
        await store.voteKnowledge(id: id, upvote: upvote)
    }

    // MARK: - Package Serving

    /// Get the cached .tbskill package URL for serving to peers.
    func packageURL(forSkill skillID: String) async -> URL? {
        guard let published = await store.getPublishedSkill(skillID) else { return nil }
        let path = packageCachePath(skillID: skillID, version: published.version)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Private Helpers

    private func cachePackage(_ source: URL, skillID: String, version: String) {
        let dest = packageCachePath(skillID: skillID, version: version)
        let dir = dest.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    private func packageCachePath(skillID: String, version: String) -> URL {
        let appSupport = PlatformPaths.appSupportDir
        return appSupport
            .appendingPathComponent("TorboBase/skill_packages", isDirectory: true)
            .appendingPathComponent("\(skillID)-\(version).tbskill")
    }

    private func findPeer(_ nodeID: String) async -> PeerNode? {
        let peers = await store.allPeers()
        return peers.first { $0.nodeID == nodeID }
    }

    private func announceToPeers() async {
        guard let identity else { return }
        let stats = await store.communityStats()
        let peers = await store.allPeers()

        let announcement: [String: Any] = [
            "node_id": identity.nodeID,
            "display_name": identity.displayName,
            "host": "127.0.0.1", // Will be replaced by peer's observed IP
            "port": 4200, // Default Torbo Base port
            "skill_count": stats["published_skills"] ?? 0,
            "knowledge_count": stats["knowledge_entries"] ?? 0
        ]

        for peer in peers {
            guard let url = URL(string: "http://\(peer.host):\(peer.port)/v1/community/announce") else { continue }
            await RetryUtility.withRetryQuiet(maxAttempts: 2, baseDelay: 0.5) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: announcement)
                request.timeoutInterval = 5

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw NSError(domain: "Community", code: -1)
                }
            }
        }
    }

    private func pushKnowledgeToPeer(contributions: [KnowledgeContribution], peer: PeerNode) async {
        guard let url = URL(string: "http://\(peer.host):\(peer.port)/v1/community/skills/bulk/knowledge/import") else { return }

        let entries: [[String: Any]] = contributions.map { $0.toDict() }

        await RetryUtility.withRetryQuiet(maxAttempts: 2, baseDelay: 1.0) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["entries": entries])
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "Community", code: -1)
            }
        }
    }

    private func downloadPackageFromPeer(skillID: String, peer: PeerNode) async -> URL? {
        guard let url = URL(string: "http://\(peer.host):\(peer.port)/v1/community/skills/\(skillID)/package") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty else { return nil }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbskill-download-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("\(skillID).tbskill")
            try data.write(to: fileURL)
            return fileURL
        } catch {
            TorboLog.warn("Download from peer failed: \(error)", subsystem: "Community")
            return nil
        }
    }

    private func probePeer(host: String, port: Int) async {
        guard let url = URL(string: "http://\(host):\(port)/v1/community/identity") else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodeID = json["node_id"] as? String else { return }

            let peer = PeerNode(
                nodeID: nodeID,
                displayName: json["display_name"] as? String ?? "",
                host: host,
                port: port,
                lastSeen: ISO8601DateFormatter().string(from: Date()),
                skillCount: json["skill_count"] as? Int ?? 0,
                knowledgeCount: json["knowledge_count"] as? Int ?? 0
            )
            await store.savePeer(peer)
        } catch {
            // Peer not reachable — that's fine
        }
    }
}
