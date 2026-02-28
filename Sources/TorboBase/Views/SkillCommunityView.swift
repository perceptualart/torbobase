// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Community Dashboard
// Browse, publish, and manage community skills + knowledge contributions.
#if canImport(SwiftUI)
import SwiftUI

struct SkillCommunityView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTab = 0
    @State private var isLoading = true

    // Browse tab
    @State private var communitySkills: [[String: Any]] = []
    @State private var searchQuery = ""
    @State private var totalSkills = 0

    // My Published tab
    @State private var publishedSkills: [[String: Any]] = []

    // Knowledge tab
    @State private var knowledgeEntries: [[String: Any]] = []
    @State private var selectedKnowledgeSkill = ""

    // Peers tab
    @State private var peers: [[String: Any]] = []

    // Settings tab
    @State private var prefs: [[String: Any]] = []

    // Stats
    @State private var stats: [String: Any] = [:]
    @State private var nodeID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                tabBar
                tabContent
            }
        }
        .task { await loadData() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Community")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("Share skills, contribute knowledge, connect with peers")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            // Sync button
            Button {
                Task { await triggerSync() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .bold))
                    Text("Sync")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 16)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Browse", icon: "globe", index: 0)
            tabButton("Published", icon: "square.and.arrow.up", index: 1)
            tabButton("Knowledge", icon: "book", index: 2)
            tabButton("Peers", icon: "network", index: 3)
            tabButton("Settings", icon: "gearshape", index: 4)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selectedTab == index ? .white : .white.opacity(0.3))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedTab == index ? Color.white.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 0: browseTab
        case 1: publishedTab
        case 2: knowledgeTab
        case 3: peersTab
        case 4: settingsTab
        default: browseTab
        }
    }

    // MARK: - Browse Tab

    private var browseTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search community skills...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .onSubmit { Task { await searchSkills() } }
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(40)
            } else if communitySkills.isEmpty {
                emptyState(icon: "globe", title: "No community skills yet",
                          subtitle: "Publish a skill to get started")
            } else {
                // Stats bar
                HStack {
                    Text("\(totalSkills) skill\(totalSkills == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    if let peerCount = stats["peer_nodes"] as? Int, peerCount > 0 {
                        Text("\(peerCount) peer\(peerCount == 1 ? "" : "s") connected")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }

                ForEach(Array(communitySkills.enumerated()), id: \.offset) { _, skill in
                    communitySkillCard(skill)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    // MARK: - Published Tab

    private var publishedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if publishedSkills.isEmpty {
                emptyState(icon: "square.and.arrow.up", title: "No published skills",
                          subtitle: "Publish a skill from the Skills panel to share it")
            } else {
                ForEach(Array(publishedSkills.enumerated()), id: \.offset) { _, skill in
                    publishedSkillCard(skill)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    // MARK: - Knowledge Tab

    private var knowledgeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if knowledgeEntries.isEmpty {
                emptyState(icon: "book", title: "No knowledge contributions",
                          subtitle: "Contribute domain knowledge to help the community")
            } else {
                ForEach(Array(knowledgeEntries.enumerated()), id: \.offset) { _, entry in
                    knowledgeCard(entry)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    // MARK: - Peers Tab

    private var peersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Node ID: \(nodeID.prefix(8))...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Button {
                    Task { await SkillCommunityManager.shared.discoverPeers() }
                } label: {
                    Text("Discover")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }

            if peers.isEmpty {
                emptyState(icon: "network", title: "No peers discovered",
                          subtitle: "Other Torbo Base instances on your network will appear here")
            } else {
                ForEach(Array(peers.enumerated()), id: \.offset) { _, peer in
                    peerCard(peer)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    // MARK: - Settings Tab

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Knowledge Sharing")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Text("Control which skills share and receive community knowledge")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 8)

            if prefs.isEmpty {
                emptyState(icon: "gearshape", title: "No sharing preferences",
                          subtitle: "Publish or install a community skill to configure sharing")
            } else {
                ForEach(Array(prefs.enumerated()), id: \.offset) { idx, pref in
                    prefsCard(pref, index: idx)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    // MARK: - Cards

    @ViewBuilder
    private func communitySkillCard(_ skill: [String: Any]) -> some View {
        let name = skill["name"] as? String ?? "Unknown"
        let desc = skill["description"] as? String ?? ""
        let icon = skill["icon"] as? String ?? "puzzlepiece"
        let version = skill["version"] as? String ?? ""
        let author = skill["author"] as? String ?? ""
        let rating = skill["rating"] as? Double ?? 0
        let ratingCount = skill["rating_count"] as? Int ?? 0
        let downloads = skill["download_count"] as? Int ?? 0
        let knowledgeCount = skill["knowledge_count"] as? Int ?? 0
        let skillID = skill["id"] as? String ?? ""

        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("v\(version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                    if !author.isEmpty {
                        Text("by \(author)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if ratingCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow.opacity(0.7))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("(\(ratingCount))")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }
                    if downloads > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("\(downloads)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    if knowledgeCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "book")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("\(knowledgeCount)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .padding(.top, 2)
            }

            Spacer()

            // Install button
            Button {
                Task {
                    let _ = await SkillCommunityManager.shared.installCommunitySkill(skillID: skillID)
                    await loadData()
                }
            } label: {
                Text("Install")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func publishedSkillCard(_ skill: [String: Any]) -> some View {
        let name = skill["name"] as? String ?? "Unknown"
        let version = skill["version"] as? String ?? ""
        let icon = skill["icon"] as? String ?? "puzzlepiece"
        let downloads = skill["download_count"] as? Int ?? 0
        let knowledgeCount = skill["knowledge_count"] as? Int ?? 0

        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text("v\(version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("\(downloads) downloads")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("\(knowledgeCount) knowledge")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func knowledgeCard(_ entry: [String: Any]) -> some View {
        let text = entry["text"] as? String ?? ""
        let category = entry["category"] as? String ?? "tip"
        let upvotes = entry["upvotes"] as? Int ?? 0
        let downvotes = entry["downvotes"] as? Int ?? 0
        let netVotes = entry["net_votes"] as? Int ?? (upvotes - downvotes)
        let entryID = entry["id"] as? String ?? ""

        HStack(alignment: .top, spacing: 12) {
            // Vote buttons
            VStack(spacing: 4) {
                Button {
                    Task { await SkillCommunityManager.shared.voteKnowledge(id: entryID, upvote: true) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)

                Text("\(netVotes)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(netVotes > 0 ? .green.opacity(0.6) : .white.opacity(0.3))

                Button {
                    Task { await SkillCommunityManager.shared.voteKnowledge(id: entryID, upvote: false) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                // Category badge
                Text(category.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(categoryColor(category))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor(category).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func peerCard(_ peer: [String: Any]) -> some View {
        let name = peer["display_name"] as? String ?? "Unknown"
        let host = peer["host"] as? String ?? ""
        let port = peer["port"] as? Int ?? 0
        let skillCount = peer["skill_count"] as? Int ?? 0
        let knowledgeCount = peer["knowledge_count"] as? Int ?? 0

        HStack(spacing: 12) {
            Circle()
                .fill(.green.opacity(0.5))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text("\(host):\(port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 9))
                    Text("\(skillCount)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.3))

                HStack(spacing: 2) {
                    Image(systemName: "book")
                        .font(.system(size: 9))
                    Text("\(knowledgeCount)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func prefsCard(_ pref: [String: Any], index: Int) -> some View {
        let skillID = pref["skill_id"] as? String ?? ""
        let share = pref["share_knowledge"] as? Bool ?? false
        let receive = pref["receive_knowledge"] as? Bool ?? true

        HStack(spacing: 16) {
            Text(skillID)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Share")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Toggle("", isOn: Binding<Bool>(
                        get: { share },
                        set: { newValue in
                            Task { await updatePrefs(skillID: skillID, share: newValue, receive: receive) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.white.opacity(0.5))
                    .scaleEffect(0.7)
                }
                HStack(spacing: 6) {
                    Text("Receive")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Toggle("", isOn: Binding<Bool>(
                        get: { receive },
                        set: { newValue in
                            Task { await updatePrefs(skillID: skillID, share: share, receive: newValue) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.white.opacity(0.5))
                    .scaleEffect(0.7)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.15))
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(60)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "technique": return .blue
        case "gotcha": return .orange
        case "reference": return .cyan
        case "correction": return .red
        case "tip": return .green
        default: return .gray
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        // Load identity
        if let identity = await SkillCommunityManager.shared.getIdentity() {
            nodeID = identity.nodeID
        }

        // Load stats
        stats = await SkillCommunityManager.shared.communityStats()

        // Load browse
        let browseResult = await SkillCommunityManager.shared.browseSkills()
        communitySkills = browseResult["skills"] as? [[String: Any]] ?? []
        totalSkills = browseResult["total"] as? Int ?? 0

        // Published = those authored by this node
        publishedSkills = communitySkills.filter { ($0["author_node_id"] as? String) == nodeID }

        // Load peers
        let peerList = await SkillCommunityManager.shared.allPeers()
        peers = peerList.map { $0.toDict() }

        // Load prefs
        let prefsList = await SkillCommunityManager.shared.allPrefs()
        prefs = prefsList.map { $0.toDict() }

        isLoading = false
    }

    private func searchSkills() async {
        let query = searchQuery.isEmpty ? nil : searchQuery
        let browseResult = await SkillCommunityManager.shared.browseSkills(query: query)
        communitySkills = browseResult["skills"] as? [[String: Any]] ?? []
        totalSkills = browseResult["total"] as? Int ?? 0
    }

    private func triggerSync() async {
        await SkillCommunityManager.shared.syncKnowledge()
        await loadData()
    }

    private func updatePrefs(skillID: String, share: Bool, receive: Bool) async {
        let newPrefs = SkillSharingPrefs(skillID: skillID, shareKnowledge: share, receiveKnowledge: receive)
        await SkillCommunityManager.shared.setPrefs(newPrefs)
        let prefsList = await SkillCommunityManager.shared.allPrefs()
        prefs = prefsList.map { $0.toDict() }
    }
}
#endif
