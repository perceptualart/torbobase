// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skills Dashboard Panel
// View and manage installed skills — enable/disable, install, remove.
#if canImport(SwiftUI)
import SwiftUI

struct SkillsView: View {
    @EnvironmentObject private var state: AppState
    @State private var skills: [[String: Any]] = []
    @State private var registrySkills: [[String: Any]] = []
    @State private var isLoading = true
    @State private var showRemoveConfirm = false
    @State private var skillToRemove: String? = nil
    @State private var showCommunity = false
    @State private var selectedCategory: String? = nil
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skills")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Modular capabilities that extend what Torbo can do")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Button {
                        showCommunity = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .bold))
                            Text("Community")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button {
                        installSkillFromFolder()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Install Skill")
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
                .padding(.bottom, 24)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(40)
                } else {
                    // Category filter chips
                    let categories = Array(Set(registrySkills.compactMap { $0["category"] as? String })).sorted()
                    if !categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                categoryChip("All", selected: selectedCategory == nil) {
                                    selectedCategory = nil
                                }
                                ForEach(categories, id: \.self) { cat in
                                    categoryChip(cat.capitalized, selected: selectedCategory == cat) {
                                        selectedCategory = selectedCategory == cat ? nil : cat
                                    }
                                }
                            }
                            .padding(.horizontal, 32)
                        }
                        .padding(.bottom, 12)
                    }

                    // Search
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.3))
                        TextField("Search skills...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)

                    // Skill cards
                    let filtered = filteredSkills
                    if filtered.isEmpty {
                        Text("No skills match your search")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(40)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(filtered.enumerated()), id: \.offset) { _, skill in
                                skillCard(skill)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .task { await loadSkills() }
        .sheet(isPresented: $showCommunity) {
            SkillCommunityView()
                .environmentObject(state)
                .frame(minWidth: 700, minHeight: 500)
        }
        .alert("Remove Skill?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                if let id = skillToRemove {
                    Task {
                        await SkillsManager.shared.removeSkill(id)
                        await loadSkills()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the skill and its files.")
        }
    }

    // MARK: - Skill Card

    @ViewBuilder
    private func skillCard(_ skill: [String: Any]) -> some View {
        let id = skill["id"] as? String ?? ""
        let name = skill["name"] as? String ?? "Unknown"
        let desc = skill["description"] as? String ?? ""
        let version = skill["version"] as? String ?? "1.0.0"
        let author = skill["author"] as? String ?? ""
        let icon = skill["icon"] as? String ?? "puzzlepiece"
        let installed = skill["installed"] as? Bool ?? false
        let enabled = skill["enabled"] as? Bool ?? false
        let tags = skill["tags"] as? [String] ?? []
        let category = skill["category"] as? String ?? ""

        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(installed ? .white.opacity(0.6) : .white.opacity(0.2))
                .frame(width: 40, height: 40)
                .background(installed ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("v\(version)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                    if !author.isEmpty && author != "Torbo" {
                        Text("by \(author)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    if !category.isEmpty {
                        Text(category)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    ForEach(tags.prefix(5), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.top, 2)
            }

            Spacer()

            // Actions
            if installed {
                VStack(spacing: 8) {
                    Toggle("", isOn: Binding<Bool>(
                        get: { enabled },
                        set: { newValue in
                            Task {
                                await SkillsManager.shared.setEnabled(skillId: id, enabled: newValue)
                                await loadSkills()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(.white.opacity(0.5))
                    .scaleEffect(0.8)

                    Button {
                        skillToRemove = id
                        showRemoveConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Available")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(16)
        .background(installed ? Color.white.opacity(0.03) : Color.white.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(installed ? Color.white.opacity(0.08) : Color.white.opacity(0.04), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func accessBadge(level: Int) -> some View {
        let names = ["OFF", "CHAT", "READ", "WRITE", "EXEC", "FULL"]
        let colors: [Color] = [.gray, .green, .cyan, .yellow, .orange, .red]
        let name = level < names.count ? names[level] : "?"
        let color = level < colors.count ? colors[level] : .gray

        Text("Level \(level) \(name)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Category Chip

    @ViewBuilder
    private func categoryChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filtering

    private var filteredSkills: [[String: Any]] {
        var result = registrySkills
        if let cat = selectedCategory {
            result = result.filter { ($0["category"] as? String) == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                let name = ($0["name"] as? String ?? "").lowercased()
                let desc = ($0["description"] as? String ?? "").lowercased()
                let tags = ($0["tags"] as? [String] ?? []).joined(separator: " ").lowercased()
                return name.contains(q) || desc.contains(q) || tags.contains(q)
            }
        }
        // Installed first, then alphabetical
        return result.sorted {
            let a = $0["installed"] as? Bool ?? false
            let b = $1["installed"] as? Bool ?? false
            if a != b { return a }
            return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
        }
    }

    // MARK: - Data

    private func loadSkills() async {
        skills = await SkillsManager.shared.listSkills()
        let installedIDs = Set(skills.compactMap { $0["id"] as? String })

        // Load full registry catalog
        let browseResult = await SkillsRegistry.shared.browse(page: 1, limit: 200)
        if let entries = browseResult["skills"] as? [[String: Any]] {
            registrySkills = entries.map { entry in
                var e = entry
                let id = e["id"] as? String ?? ""
                e["installed"] = installedIDs.contains(id)
                // Merge enabled status from installed skills
                if let installed = skills.first(where: { $0["id"] as? String == id }) {
                    e["enabled"] = installed["enabled"] as? Bool ?? false
                    e["version"] = installed["version"] as? String ?? e["version"]
                }
                return e
            }
        }

        // Also ensure SkillsRegistry is initialized
        if registrySkills.isEmpty {
            await SkillsRegistry.shared.initialize()
            let retry = await SkillsRegistry.shared.browse(page: 1, limit: 200)
            if let entries = retry["skills"] as? [[String: Any]] {
                registrySkills = entries.map { entry in
                    var e = entry
                    let id = e["id"] as? String ?? ""
                    e["installed"] = installedIDs.contains(id)
                    return e
                }
            }
        }

        isLoading = false
    }

    // MARK: - Install

    private func installSkillFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Select a Skill Folder"
        panel.message = "Choose a folder containing a skill.json file"
        panel.prompt = "Install"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let success = await SkillsManager.shared.installSkill(from: url)
                if success {
                    await loadSkills()
                }
            }
        }
    }
}
#endif
