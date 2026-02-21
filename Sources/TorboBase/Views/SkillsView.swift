// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skills Dashboard Panel
// View and manage installed skills — enable/disable, install, remove.
#if canImport(SwiftUI)
import SwiftUI

struct SkillsView: View {
    @EnvironmentObject private var state: AppState
    @State private var skills: [[String: Any]] = []
    @State private var isLoading = true
    @State private var showRemoveConfirm = false
    @State private var skillToRemove: String? = nil

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
                } else if skills.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "puzzlepiece")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("No skills installed")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Skills will be created automatically on first launch.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(60)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                            skillCard(skill)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .task { await loadSkills() }
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
        let enabled = skill["enabled"] as? Bool ?? false
        let requiredLevel = skill["required_access_level"] as? Int ?? 1
        let tags = skill["tags"] as? [String] ?? []

        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(enabled ? .white.opacity(0.6) : .white.opacity(0.2))
                .frame(width: 40, height: 40)
                .background(enabled ? Color.white.opacity(0.06) : Color.white.opacity(0.03))
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

                HStack(spacing: 6) {
                    // Access level badge
                    accessBadge(level: requiredLevel)

                    // Tags
                    ForEach(tags, id: \.self) { tag in
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
            VStack(spacing: 8) {
                // Toggle
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

                // Remove
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

    // MARK: - Data

    private func loadSkills() async {
        skills = await SkillsManager.shared.listSkills()
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
