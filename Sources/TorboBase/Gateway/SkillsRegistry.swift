// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skills Registry
// SkillsRegistry.swift — Skill discovery, search, install, and auto-creation
// Local registry index with built-in starter skills and user-created skills.

import Foundation

actor SkillsRegistry {
    static let shared = SkillsRegistry()

    /// Registry entry metadata (lighter than full Skill struct)
    struct RegistryEntry: Codable {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let icon: String
        let tags: [String]
        let category: String
        var installed: Bool

        func toDict() -> [String: Any] {
            ["id": id, "name": name, "description": description, "version": version,
             "author": author, "icon": icon, "tags": tags, "category": category,
             "installed": installed]
        }
    }

    private var registry: [RegistryEntry] = []
    private let registryPath: String

    init() {
        registryPath = PlatformPaths.dataDir + "/skills_registry.json"
    }

    func initialize() async {
        loadRegistry()
        if registry.isEmpty {
            createBuiltInRegistry()
            saveRegistry()
        }
        // Sync installed status with SkillsManager
        let installed = await SkillsManager.shared.listSkills()
        let installedIDs = Set(installed.compactMap { $0["id"] as? String })
        for i in registry.indices {
            registry[i].installed = installedIDs.contains(registry[i].id)
        }
        TorboLog.info("Skills registry: \(registry.count) entries, \(registry.filter { $0.installed }.count) installed", subsystem: "SkillsRegistry")
    }

    // MARK: - Browse

    func browse(tag: String? = nil, page: Int = 1, limit: Int = 20) -> [String: Any] {
        var results = registry
        if let tag, !tag.isEmpty {
            results = results.filter { $0.tags.contains(tag.lowercased()) }
        }

        let total = results.count
        let start = max(0, (page - 1) * limit)
        let end = min(start + limit, total)
        let pageResults = start < end ? Array(results[start..<end]) : []

        let allTags = Set(registry.flatMap { $0.tags }).sorted()
        let allCategories = Set(registry.map { $0.category }).sorted()

        return [
            "skills": pageResults.map { $0.toDict() },
            "total": total,
            "page": page,
            "limit": limit,
            "tags": allTags,
            "categories": allCategories
        ] as [String: Any]
    }

    // MARK: - Search

    func search(query: String) -> [[String: Any]] {
        guard !query.isEmpty else { return registry.map { $0.toDict() } }
        let lower = query.lowercased()
        let words = lower.split(separator: " ").map(String.init)

        return registry
            .filter { entry in
                let text = "\(entry.name) \(entry.description) \(entry.tags.joined(separator: " ")) \(entry.category)".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .map { $0.toDict() }
    }

    // MARK: - Install

    func install(skillID: String) async -> Bool {
        guard let entry = registry.first(where: { $0.id == skillID }) else { return false }

        // Create a skill directory with the registry metadata
        let appSupport = PlatformPaths.appSupportDir
        let skillDir = appSupport.appendingPathComponent("TorboBase/skills/\(skillID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let skill = Skill(
            id: entry.id,
            name: entry.name,
            description: entry.description,
            version: entry.version,
            author: entry.author,
            icon: entry.icon,
            requiredAccessLevel: 1,
            enabled: true,
            promptFile: "prompt.md",
            toolsFile: nil,
            mcpConfigFile: nil,
            tags: entry.tags
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skill) else { return false }
        do {
            try data.write(to: skillDir.appendingPathComponent("skill.json"), options: .atomic)
            // Create a basic prompt file
            let prompt = "# \(entry.name)\n\n\(entry.description)\n"
            try prompt.write(to: skillDir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        } catch {
            TorboLog.error("Failed to install skill \(skillID): \(error)", subsystem: "SkillsRegistry")
            return false
        }

        // Refresh SkillsManager
        await SkillsManager.shared.scanSkills()

        // Update registry installed status
        if let idx = registry.firstIndex(where: { $0.id == skillID }) {
            registry[idx].installed = true
        }

        TorboLog.info("Installed skill: \(entry.name)", subsystem: "SkillsRegistry")
        return true
    }

    // MARK: - Auto-Create

    func createSkill(name: String, description: String, prompt: String, tags: [String]) async -> [String: Any] {
        let id = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)

        let appSupport = PlatformPaths.appSupportDir
        let skillDir = appSupport.appendingPathComponent("TorboBase/skills/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let skill = Skill(
            id: id,
            name: name,
            description: description,
            version: "1.0.0",
            author: "auto-generated",
            icon: "sparkles",
            requiredAccessLevel: 1,
            enabled: true,
            promptFile: "prompt.md",
            toolsFile: nil,
            mcpConfigFile: nil,
            tags: tags
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skill) else {
            return ["success": false, "error": "Failed to encode skill"]
        }

        do {
            try data.write(to: skillDir.appendingPathComponent("skill.json"), options: .atomic)
            let promptContent = prompt.isEmpty ? "# \(name)\n\n\(description)\n" : prompt
            try promptContent.write(to: skillDir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }

        // Add to registry
        let entry = RegistryEntry(
            id: id, name: name, description: description, version: "1.0.0",
            author: "auto-generated", icon: "sparkles", tags: tags,
            category: "custom", installed: true
        )
        registry.append(entry)
        saveRegistry()

        await SkillsManager.shared.scanSkills()
        TorboLog.info("Created skill: \(name) (\(id))", subsystem: "SkillsRegistry")

        return ["success": true, "id": id, "name": name] as [String: Any]
    }

    // MARK: - Persistence

    private func loadRegistry() {
        guard let data = FileManager.default.contents(atPath: registryPath),
              let entries = try? JSONDecoder().decode([RegistryEntry].self, from: data) else { return }
        registry = entries
    }

    private func saveRegistry() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(registry) else { return }
        let dir = (registryPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: URL(fileURLWithPath: registryPath), options: .atomic)
        } catch {
            TorboLog.error("Failed to save registry: \(error)", subsystem: "SkillsRegistry")
        }
    }

    // MARK: - Built-In Registry

    private func createBuiltInRegistry() {
        registry = [
            RegistryEntry(id: "web-researcher", name: "Web Researcher", description: "Deep web research with source tracking and citation generation", version: "1.0.0", author: "Torbo", icon: "magnifyingglass", tags: ["research", "web", "citations"], category: "research", installed: false),
            RegistryEntry(id: "code-reviewer", name: "Code Reviewer", description: "Code analysis for bugs, security issues, performance, and style", version: "1.0.0", author: "Torbo", icon: "checkmark.shield", tags: ["code", "review", "security"], category: "development", installed: false),
            RegistryEntry(id: "document-writer", name: "Document Writer", description: "Long-form document generation with outline planning", version: "1.0.0", author: "Torbo", icon: "doc.text", tags: ["writing", "documents"], category: "writing", installed: false),
            RegistryEntry(id: "data-analyst", name: "Data Analyst", description: "Data analysis, visualization suggestions, and statistical insights", version: "1.0.0", author: "Torbo", icon: "chart.bar", tags: ["data", "analysis", "statistics"], category: "analysis", installed: false),
            RegistryEntry(id: "api-tester", name: "API Tester", description: "Test REST APIs with structured request/response analysis", version: "1.0.0", author: "Torbo", icon: "network", tags: ["api", "testing", "http"], category: "development", installed: false),
            RegistryEntry(id: "email-drafter", name: "Email Drafter", description: "Professional email composition with tone matching", version: "1.0.0", author: "Torbo", icon: "envelope", tags: ["email", "writing", "communication"], category: "writing", installed: false),
            RegistryEntry(id: "meeting-prep", name: "Meeting Prep", description: "Meeting preparation with agenda, talking points, and follow-ups", version: "1.0.0", author: "Torbo", icon: "calendar.badge.clock", tags: ["meetings", "productivity", "planning"], category: "productivity", installed: false),
            RegistryEntry(id: "debug-assistant", name: "Debug Assistant", description: "Systematic debugging with root cause analysis", version: "1.0.0", author: "Torbo", icon: "ant", tags: ["debugging", "code", "troubleshooting"], category: "development", installed: false),
            RegistryEntry(id: "sql-helper", name: "SQL Helper", description: "SQL query writing, optimization, and schema design", version: "1.0.0", author: "Torbo", icon: "cylinder", tags: ["sql", "database", "queries"], category: "development", installed: false),
            RegistryEntry(id: "git-workflow", name: "Git Workflow", description: "Git operations, branching strategies, and merge conflict resolution", version: "1.0.0", author: "Torbo", icon: "arrow.triangle.branch", tags: ["git", "version-control", "workflow"], category: "development", installed: false),
            RegistryEntry(id: "summarizer", name: "Summarizer", description: "Condense long documents, articles, and conversations into key points", version: "1.0.0", author: "Torbo", icon: "text.justify.left", tags: ["summary", "reading", "condensing"], category: "productivity", installed: false),
            RegistryEntry(id: "translator", name: "Translator", description: "Multi-language translation with cultural context", version: "1.0.0", author: "Torbo", icon: "globe", tags: ["translation", "languages", "localization"], category: "communication", installed: false),
            RegistryEntry(id: "brainstormer", name: "Brainstormer", description: "Creative ideation with structured brainstorming frameworks", version: "1.0.0", author: "Torbo", icon: "lightbulb", tags: ["ideas", "creativity", "brainstorming"], category: "creative", installed: false),
            RegistryEntry(id: "project-planner", name: "Project Planner", description: "Project planning with milestones, dependencies, and risk assessment", version: "1.0.0", author: "Torbo", icon: "checklist", tags: ["planning", "projects", "management"], category: "productivity", installed: false),
            RegistryEntry(id: "tech-writer", name: "Technical Writer", description: "Technical documentation, API docs, and README generation", version: "1.0.0", author: "Torbo", icon: "doc.plaintext", tags: ["documentation", "technical", "writing"], category: "writing", installed: false),
            RegistryEntry(id: "security-auditor", name: "Security Auditor", description: "Security vulnerability scanning and compliance checking", version: "1.0.0", author: "Torbo", icon: "lock.shield", tags: ["security", "audit", "compliance"], category: "security", installed: false),
            RegistryEntry(id: "regex-builder", name: "Regex Builder", description: "Build, test, and explain regular expressions", version: "1.0.0", author: "Torbo", icon: "textformat.abc", tags: ["regex", "patterns", "text"], category: "development", installed: false),
            RegistryEntry(id: "shell-scripter", name: "Shell Scripter", description: "Shell script generation with best practices and error handling", version: "1.0.0", author: "Torbo", icon: "terminal", tags: ["shell", "bash", "scripting"], category: "development", installed: false),
            RegistryEntry(id: "ui-designer", name: "UI Designer", description: "UI/UX design feedback, mockup descriptions, and layout suggestions", version: "1.0.0", author: "Torbo", icon: "paintbrush", tags: ["design", "ui", "ux"], category: "creative", installed: false),
            RegistryEntry(id: "health-tracker", name: "Health Tracker", description: "Health and wellness tracking, habit building, and fitness guidance", version: "1.0.0", author: "Torbo", icon: "heart", tags: ["health", "fitness", "wellness"], category: "lifestyle", installed: false),
        ]
    }
}
