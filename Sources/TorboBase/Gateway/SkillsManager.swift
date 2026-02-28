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
            "has_prompt": !(promptContent?.isEmpty ?? true),
            "has_tools": !(toolDefinitions?.isEmpty ?? true),
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
        // Start MCP servers defined in skill configs
        await loadSkillMCPServers()
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

    /// Get additional tool definitions from enabled skills.
    /// Tool names are prefixed with `skill_{skillID}_` to namespace them (like `mcp_` prefix).
    /// If allowedSkillIDs is non-empty, only include those skills. Empty = all enabled skills.
    func skillToolDefinitions(forAccessLevel level: Int, allowedSkillIDs: [String] = []) -> [[String: Any]] {
        var active = enabledSkills(forAccessLevel: level)
        if !allowedSkillIDs.isEmpty {
            active = active.filter { allowedSkillIDs.contains($0.id) }
        }
        var result: [[String: Any]] = []
        for skill in active {
            guard let tools = skill.toolDefinitions else { continue }
            for var tool in tools {
                // Namespace the tool name: skill_{skillID}_{originalName}
                if let fn = tool["function"] as? [String: Any],
                   let originalName = fn["name"] as? String {
                    var mutableFn = fn
                    mutableFn["name"] = "skill_\(skill.id)_\(originalName)"
                    tool["function"] = mutableFn
                    tool["type"] = "function"
                }
                result.append(tool)
            }
        }
        return result
    }

    /// Execute a skill tool by parsing the prefixed name and dispatching.
    /// If the skill has an MCP config, delegates to MCPManager.
    /// Otherwise returns an error (tool definitions are prompt-only guidance).
    func executeSkillTool(skillID: String, toolName: String, arguments: [String: Any],
                          accessLevel: Int, agentID: String) async -> String {
        guard let skill = skills[skillID] else {
            return "Error: skill '\(skillID)' not found"
        }
        guard skill.enabled else {
            return "Error: skill '\(skillID)' is disabled"
        }
        guard skill.requiredAccessLevel <= accessLevel else {
            return "Error: insufficient access level for skill '\(skillID)'"
        }
        // If skill has MCP config, its tools are already registered via MCPManager
        // with scoped names — they'd be dispatched via the mcp_ prefix handler instead.
        // This path handles skills with tools.json but no MCP backend.
        return "Error: skill '\(skillID)' tool '\(toolName)' has no execution backend. Tool definitions provide prompt guidance only."
    }

    /// Get community knowledge block for a skill (Phase 1: stub, Phase 2: wired to SkillCommunityManager).
    func communityKnowledgeBlock(forSkill skillID: String) async -> String {
        await SkillCommunityManager.shared.communityKnowledgeBlock(forSkill: skillID)
    }

    // MARK: - Skill MCP Servers

    /// Load and start MCP servers defined in per-skill mcp_config.json files.
    /// Servers are registered with skill-scoped names: skill_{skillID}_{serverName}
    /// so their tools get namespaced via MCPManager's existing mcp_ prefix.
    func loadSkillMCPServers() async {
        for skill in skills.values where skill.enabled {
            guard let mcpFile = skill.mcpConfigFile else { continue }
            let configURL = skillsDir.appendingPathComponent(skill.id).appendingPathComponent(mcpFile)
            guard FileManager.default.fileExists(atPath: configURL.path) else { continue }

            do {
                let data = try Data(contentsOf: configURL)
                let config = try JSONDecoder().decode(MCPConfigFile.self, from: data)
                for (serverName, serverConfig) in config.mcpServers where serverConfig.isEnabled {
                    let scopedName = "skill_\(skill.id)_\(serverName)"
                    await MCPManager.shared.startServer(name: scopedName, config: serverConfig)
                    TorboLog.info("Started MCP server '\(scopedName)' for skill '\(skill.name)'", subsystem: "Skills")
                }
            } catch {
                TorboLog.error("Failed to load MCP config for skill '\(skill.id)': \(error)", subsystem: "Skills")
            }
        }
    }

    // MARK: - Skill Learnings

    /// Build a prompt block with learnings from previous skill usage.
    /// Retrieves skill-tagged memories from LoA (Library of Alexandria).
    func skillLearningsBlock(forSkillIDs skillIDs: [String], maxTokens: Int = 300) async -> String {
        guard !skillIDs.isEmpty else { return "" }

        var lines: [String] = []
        var estimatedTokens = 0

        for skillID in skillIDs {
            // Search by entity tag "skill:{id}" — learnings are tagged with this during extraction
            let results = await MemoryIndex.shared.searchByEntity(name: "skill:\(skillID)", topK: 10)
            let learnings = results.filter { $0.category == "skill_learning" }

            for learning in learnings {
                let tokens = learning.text.count / 4
                if estimatedTokens + tokens > maxTokens { break }
                lines.append("- \(learning.text)")
                estimatedTokens += tokens
            }
        }

        guard !lines.isEmpty else { return "" }
        return "<skill-learnings>\nInsights from previous skill usage:\n\(lines.joined(separator: "\n"))\n</skill-learnings>"
    }

    // MARK: - Skill Learning Promotion

    /// Tracks which memory IDs have already been contributed to avoid re-submitting.
    private var contributedMemoryIDs = Set<Int64>()

    /// Promote high-quality personal skill learnings into the community knowledge pool.
    /// Called from the TIDE cycle (every 15 min). Quality thresholds + dedup + rate limiting make repeated calls safe.
    func promoteSkillLearnings() async {
        let learnings = await MemoryIndex.shared.entriesByCategory("skill_learning")
        guard !learnings.isEmpty else { return }

        var promoted = 0
        for learning in learnings {
            // Skip already-contributed
            guard !contributedMemoryIDs.contains(learning.id) else { continue }

            // Quality gates — learning must prove itself useful before sharing
            guard learning.importance >= 0.7,
                  learning.accessCount >= 3,
                  learning.confidence >= 0.7 else { continue }

            // Extract skill ID from entity tags (format: "skill:{id}")
            guard let skillEntity = learning.entities.first(where: { $0.hasPrefix("skill:") }) else { continue }
            let skillID = String(skillEntity.dropFirst(6)) // drop "skill:"

            // Classify into KnowledgeCategory
            let category = classifyLearning(learning.text)

            // Contribute — this checks prefs.shareKnowledge, rate limits, and dedup internally
            let success = await SkillCommunityManager.shared.contributeKnowledge(
                skillID: skillID,
                text: learning.text,
                category: category,
                confidence: Double(learning.confidence)
            )

            // Mark as contributed regardless of success (prefs off, rate limit, dedup are all permanent-ish)
            contributedMemoryIDs.insert(learning.id)

            if success { promoted += 1 }
        }

        if promoted > 0 {
            TorboLog.info("Promoted \(promoted) skill learning(s) to community knowledge", subsystem: "Skills")
        }
    }

    /// Classify a learning text into a KnowledgeCategory using keyword heuristics.
    private func classifyLearning(_ text: String) -> KnowledgeCategory {
        let lower = text.lowercased()

        // Gotcha — pitfalls, warnings, mistakes
        if lower.contains("don't") || lower.contains("do not") || lower.contains("avoid")
            || lower.contains("careful") || lower.contains("pitfall") || lower.contains("gotcha")
            || lower.contains("mistake") || lower.contains("warning") || lower.contains("beware") {
            return .gotcha
        }

        // Correction — fixes for misconceptions
        if lower.contains("actually") || lower.contains("incorrect") || lower.contains("wrong")
            || lower.contains("correc") || lower.contains("not true") || lower.contains("misconception") {
            return .correction
        }

        // Technique — how-to, patterns, approaches
        if lower.contains("how to") || lower.contains("pattern") || lower.contains("approach")
            || lower.contains("technique") || lower.contains("method") || lower.contains("workflow")
            || lower.contains("step") || lower.contains("process") {
            return .technique
        }

        // Reference — specs, codes, standards, versions
        if lower.contains("version") || lower.contains("spec") || lower.contains("standard")
            || lower.contains("rfc") || lower.contains("api") || lower.contains("documentation")
            || lower.contains("reference") {
            return .reference
        }

        // Default: tip
        return .tip
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
