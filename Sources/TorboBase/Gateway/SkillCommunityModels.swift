// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Community Models
// Data models for the federated skill sharing network and wiki-LLM knowledge layer.

import Foundation

// MARK: - Node Identity

/// Persistent identity for this Torbo Base node in the community network.
struct NodeIdentity: Codable, Sendable {
    let nodeID: String          // UUID string, generated once
    var displayName: String     // User-chosen display name
    let publicKey: String       // Ed25519 public key (hex)
    let createdAt: String       // ISO8601

    func toDict() -> [String: Any] {
        ["node_id": nodeID, "display_name": displayName,
         "public_key": publicKey, "created_at": createdAt]
    }
}

// MARK: - Published Skill

/// A skill published to the community network (local, peer, or central registry).
struct PublishedSkill: Codable, Sendable {
    let id: String              // Same as local skill ID
    let name: String
    let description: String
    let version: String
    let author: String          // Display name of publisher
    let authorNodeID: String    // Publisher's node ID
    let icon: String
    let tags: [String]
    let packageHash: String     // SHA-256 of .tbskill file
    let signature: String       // Ed25519 signature of hash
    let publishedAt: String     // ISO8601
    var rating: Double          // Average 1-5 stars
    var ratingCount: Int        // Number of ratings
    var downloadCount: Int
    var contributors: Int       // Nodes that contributed knowledge
    var knowledgeCount: Int     // Total knowledge entries

    func toDict() -> [String: Any] {
        ["id": id, "name": name, "description": description,
         "version": version, "author": author, "author_node_id": authorNodeID,
         "icon": icon, "tags": tags, "package_hash": packageHash,
         "signature": signature, "published_at": publishedAt,
         "rating": rating, "rating_count": ratingCount,
         "download_count": downloadCount, "contributors": contributors,
         "knowledge_count": knowledgeCount]
    }
}

// MARK: - Skill Version

/// Version history entry for a published skill.
struct SkillVersion: Codable, Sendable {
    let skillID: String
    let version: String
    let changelog: String
    let packageHash: String
    let signature: String
    let publishedAt: String     // ISO8601

    func toDict() -> [String: Any] {
        ["skill_id": skillID, "version": version, "changelog": changelog,
         "package_hash": packageHash, "signature": signature,
         "published_at": publishedAt]
    }
}

// MARK: - Skill Rating

/// A 1-5 star rating from a node for a published skill.
struct SkillRating: Codable, Sendable {
    let skillID: String
    let nodeID: String
    let rating: Int             // 1-5
    let review: String?         // Optional review text
    let createdAt: String       // ISO8601

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "skill_id": skillID, "node_id": nodeID,
            "rating": rating, "created_at": createdAt
        ]
        if let review { dict["review"] = review }
        return dict
    }
}

// MARK: - Knowledge

/// Categories for community knowledge contributions.
enum KnowledgeCategory: String, Codable, Sendable, CaseIterable {
    case technique      // How to do something
    case gotcha         // Common mistake or pitfall
    case reference      // Factual reference (codes, standards, specs)
    case correction     // Correction of a common misconception
    case tip            // Quick tip or best practice

    var label: String {
        switch self {
        case .technique: return "Technique"
        case .gotcha: return "Gotcha"
        case .reference: return "Reference"
        case .correction: return "Correction"
        case .tip: return "Tip"
        }
    }
}

/// A single domain fact contributed while a skill was active.
/// The building block of the wiki-LLM knowledge layer.
struct KnowledgeContribution: Codable, Sendable {
    let id: String              // UUID
    let skillID: String
    let text: String
    let category: KnowledgeCategory
    let confidence: Double      // 0-1
    let contentHash: String     // SHA-256 of text (dedup key)
    let signature: String       // Ed25519 signature
    let authorNodeID: String
    let createdAt: String       // ISO8601
    var upvotes: Int
    var downvotes: Int
    var synced: Bool            // Has been pushed to peers/central

    var netVotes: Int { upvotes - downvotes }

    func toDict() -> [String: Any] {
        ["id": id, "skill_id": skillID, "text": text,
         "category": category.rawValue, "confidence": confidence,
         "content_hash": contentHash, "signature": signature,
         "author_node_id": authorNodeID, "created_at": createdAt,
         "upvotes": upvotes, "downvotes": downvotes,
         "net_votes": netVotes, "synced": synced]
    }
}

// MARK: - Peer Node

/// A discovered peer in the local network (Bonjour) or known Tailscale host.
struct PeerNode: Codable, Sendable {
    let nodeID: String
    var displayName: String
    var host: String            // IP or hostname
    var port: Int
    var lastSeen: String        // ISO8601
    var skillCount: Int
    var knowledgeCount: Int

    func toDict() -> [String: Any] {
        ["node_id": nodeID, "display_name": displayName,
         "host": host, "port": port, "last_seen": lastSeen,
         "skill_count": skillCount, "knowledge_count": knowledgeCount]
    }
}

// MARK: - Sharing Preferences

/// Per-skill opt-in toggles for knowledge sharing.
struct SkillSharingPrefs: Codable, Sendable {
    let skillID: String
    var shareKnowledge: Bool    // Contribute knowledge from this node
    var receiveKnowledge: Bool  // Accept knowledge from others

    func toDict() -> [String: Any] {
        ["skill_id": skillID, "share_knowledge": shareKnowledge,
         "receive_knowledge": receiveKnowledge]
    }
}
