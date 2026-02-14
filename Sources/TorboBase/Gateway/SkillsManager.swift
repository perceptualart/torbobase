// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skills System
// Modular capability packages that extend SiD's abilities.
// Each skill is a directory in ~/Library/Application Support/TorboBase/skills/
import Foundation

// MARK: - Skill Model

struct Skill: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    var version: String
    var author: String
    var icon: String
    var requiredAccessLevel: Int
    var enabled: Bool
    var promptFile: String?
    var toolsFile: String?
    var mcpConfigFile: String?
    var tags: [String]

    // Runtime — not persisted in skill.json
    var promptContent: String?
    var toolDefinitions: [[String: Any]]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, author, icon
        case requiredAccessLevel = "required_access_level"
        case enabled
        case promptFile = "prompt_file"
        case toolsFile = "tools_file"
        case mcpConfigFile = "mcp_config_file"
        case tags
    }

    /// Dictionary representation for API responses
    func toDict() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "description": description,
            "version": version,
            "author": author,
            "icon": icon,
            "required_access_level": requiredAccessLevel,
            "enabled": enabled,
            "tags": tags,
            "has_prompt": promptContent != nil && !promptContent!.isEmpty,
            "has_tools": toolDefinitions != nil && !toolDefinitions!.isEmpty,
            "has_mcp": mcpConfigFile != nil
        ]
    }
}

// MARK: - Skills Manager

actor SkillsManager {
    static let shared = SkillsManager()

    private let skillsDir: URL
    private var skills: [String: Skill] = [:]
    private let decoder = JSONDecoder()

    init() {
        let appSupport = PlatformPaths.appSupportDir
        skillsDir = appSupport.appendingPathComponent("TorboBase/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    func initialize() async {
        // Create built-in skills if the directory is empty
        await createBuiltInSkillsIfNeeded()
        // Scan and load all skills
        await scanSkills()
        TorboLog.info("Loaded \(skills.count) skill(s)", subsystem: "Skills")
    }

    // MARK: - Scan & Load

    func scanSkills() async {
        skills.removeAll()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillJsonURL = item.appendingPathComponent("skill.json")
            guard let data = try? Data(contentsOf: skillJsonURL),
                  var skill = try? decoder.decode(Skill.self, from: data) else { continue }

            // Load prompt content
            if let promptFile = skill.promptFile {
                let promptURL = item.appendingPathComponent(promptFile)
                skill.promptContent = try? String(contentsOf: promptURL, encoding: .utf8)
            }

            // Load tool definitions
            if let toolsFile = skill.toolsFile {
                let toolsURL = item.appendingPathComponent(toolsFile)
                if let toolsData = try? Data(contentsOf: toolsURL),
                   let toolsJSON = try? JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]] {
                    skill.toolDefinitions = toolsJSON
                }
            }

            skills[skill.id] = skill
        }
    }

    // MARK: - API

    func listSkills() -> [[String: Any]] {
        skills.values.sorted(by: { $0.name < $1.name }).map { $0.toDict() }
    }

    func getSkill(_ id: String) -> Skill? {
        skills[id]
    }

    func setEnabled(skillId: String, enabled: Bool) {
        guard var skill = skills[skillId] else { return }
        skill.enabled = enabled
        skills[skillId] = skill
        // Persist the enabled state to skill.json
        persistSkillConfig(skill)
    }

    func enabledSkills(forAccessLevel level: Int) -> [Skill] {
        skills.values.filter { $0.enabled && $0.requiredAccessLevel <= level }
    }

    /// Build the combined prompt addition from all enabled skills at the given access level.
    /// If allowedSkillIDs is non-empty, only include those skills. Empty = all enabled skills.
    func skillsPromptBlock(forAccessLevel level: Int, allowedSkillIDs: [String] = []) -> String {
        var active = enabledSkills(forAccessLevel: level)
        if !allowedSkillIDs.isEmpty {
            active = active.filter { allowedSkillIDs.contains($0.id) }
        }
        guard !active.isEmpty else { return "" }

        var parts: [String] = ["<skills>"]
        for skill in active {
            if let prompt = skill.promptContent, !prompt.isEmpty {
                parts.append("[\(skill.name)]")
                parts.append(prompt)
                parts.append("")
            }
        }
        parts.append("</skills>")
        return parts.joined(separator: "\n")
    }

    /// Get additional tool definitions from enabled skills
    func skillToolDefinitions(forAccessLevel level: Int) -> [[String: Any]] {
        enabledSkills(forAccessLevel: level).flatMap { $0.toolDefinitions ?? [] }
    }

    // MARK: - Install / Remove

    func installSkill(from sourceDir: URL) -> Bool {
        let fm = FileManager.default
        let skillJsonURL = sourceDir.appendingPathComponent("skill.json")
        guard let data = try? Data(contentsOf: skillJsonURL),
              let skill = try? decoder.decode(Skill.self, from: data) else { return false }

        let destDir = skillsDir.appendingPathComponent(skill.id)
        try? fm.removeItem(at: destDir)
        do {
            try fm.copyItem(at: sourceDir, to: destDir)
            Task { await scanSkills() }
            return true
        } catch {
            TorboLog.error("Install failed: \(error)", subsystem: "Skills")
            return false
        }
    }

    func removeSkill(_ id: String) {
        let dir = skillsDir.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dir)
        skills.removeValue(forKey: id)
    }

    // MARK: - Persistence

    private func persistSkillConfig(_ skill: Skill) {
        let dir = skillsDir.appendingPathComponent(skill.id)
        let skillJsonURL = dir.appendingPathComponent("skill.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(skill)
            try data.write(to: skillJsonURL, options: .atomic)
        } catch {
            TorboLog.error("Failed to save skill config '\(skill.id)': \(error)", subsystem: "Skills")
        }
    }

    // MARK: - Built-In Skills

    private func createBuiltInSkillsIfNeeded() async {
        let fm = FileManager.default
        // Check if at least one built-in skill exists
        let webResearcherDir = skillsDir.appendingPathComponent("web-researcher")
        guard !fm.fileExists(atPath: webResearcherDir.path) else { return }

        TorboLog.info("Creating built-in skills...", subsystem: "Skills")
        createWebResearcherSkill()
        createCodeReviewerSkill()
        createDocumentWriterSkill()
    }

    private func createWebResearcherSkill() {
        let dir = skillsDir.appendingPathComponent("web-researcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = Skill(
            id: "web-researcher",
            name: "Web Researcher",
            description: "Deep web research with source tracking and citation generation",
            version: "1.0.0",
            author: "Torbo",
            icon: "magnifyingglass",
            requiredAccessLevel: 1,
            enabled: true,
            promptFile: "prompt.md",
            toolsFile: nil,
            mcpConfigFile: nil,
            tags: ["research", "web", "citations"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: dir.appendingPathComponent("skill.json")) }

        let prompt = """
        # Web Researcher Skill

        When the user asks you to research a topic, follow this process:

        1. **Search Phase**: Use web_search to find relevant sources. Run 2-3 searches with different query angles.
        2. **Fetch Phase**: Use web_fetch to retrieve the most promising results. Read the full content.
        3. **Synthesis**: Combine information from multiple sources into a clear, structured response.
        4. **Citations**: Always cite your sources. Include URLs and note when information was retrieved.

        Research guidelines:
        - Cross-reference claims across multiple sources
        - Note conflicting information and explain the discrepancy
        - Distinguish between facts, opinions, and speculation
        - Provide dates for time-sensitive information
        - If asked for "recent" or "latest" information, prioritize the most current sources
        """
        try? prompt.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
    }

    private func createCodeReviewerSkill() {
        let dir = skillsDir.appendingPathComponent("code-reviewer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = Skill(
            id: "code-reviewer",
            name: "Code Reviewer",
            description: "Code analysis for bugs, security issues, performance, and style",
            version: "1.0.0",
            author: "Torbo",
            icon: "checkmark.shield",
            requiredAccessLevel: 2,
            enabled: true,
            promptFile: "prompt.md",
            toolsFile: nil,
            mcpConfigFile: nil,
            tags: ["code", "review", "security", "bugs"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: dir.appendingPathComponent("skill.json")) }

        let prompt = """
        # Code Reviewer Skill

        When asked to review code, analyze it across these dimensions:

        1. **Correctness**: Logic errors, off-by-one errors, null/nil handling, edge cases
        2. **Security**: Injection vulnerabilities, auth issues, data exposure, input validation
        3. **Performance**: Unnecessary allocations, N+1 queries, blocking calls, memory leaks
        4. **Style**: Naming conventions, code organization, readability, documentation gaps
        5. **Architecture**: Coupling, cohesion, SOLID violations, testability

        Review format:
        - Start with a 1-2 sentence overall assessment
        - List issues by severity: Critical > Warning > Suggestion
        - For each issue, explain WHY it's a problem and show the fix
        - End with what's done well (if anything)

        Be direct. Don't pad criticism with unnecessary praise.
        """
        try? prompt.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
    }

    private func createDocumentWriterSkill() {
        let dir = skillsDir.appendingPathComponent("document-writer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = Skill(
            id: "document-writer",
            name: "Document Writer",
            description: "Long-form document generation with outline planning and revision passes",
            version: "1.0.0",
            author: "Torbo",
            icon: "doc.text",
            requiredAccessLevel: 1,
            enabled: true,
            promptFile: "prompt.md",
            toolsFile: nil,
            mcpConfigFile: nil,
            tags: ["writing", "documents", "long-form"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: dir.appendingPathComponent("skill.json")) }

        let prompt = """
        # Document Writer Skill

        When asked to write a document, follow this process:

        1. **Outline First**: Before writing, propose an outline with sections and key points. Wait for approval unless told to go ahead.
        2. **Section by Section**: Write each section as a complete, standalone piece. Don't rush.
        3. **Transitions**: Ensure smooth flow between sections.
        4. **Revision Pass**: After completing the first draft, review for:
           - Consistency in tone and terminology
           - Logical flow and argument structure
           - Redundancy and filler removal
           - Clarity of key points

        Writing guidelines:
        - Match the tone to the document type (formal for reports, conversational for blog posts)
        - Use concrete examples and specifics over vague generalities
        - Front-load key information — don't bury the lead
        - Keep paragraphs focused on one idea each
        - Use headers, lists, and formatting to improve scannability
        """
        try? prompt.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
    }
}
