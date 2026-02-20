// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
// Capabilities — Tool registry, definitions, and execution engines
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import AppKit
#endif

// MARK: - Capability Registry
// Central registry of all tools organized by category.
// Controls which tools are available to each agent via per-agent and global toggles.

enum CapabilityCategory: String, Codable, CaseIterable {
    case web = "Web"
    case files = "Files"
    case execution = "Execution"
    case calendar = "Calendar"
    case automation = "Automation"
    case screen = "Screen"
    case clipboard = "Clipboard"
    case system = "System"
    case search = "Search"
    case notifications = "Notifications"
    case network = "Network"
    case scripting = "Scripting"
    case memory = "Memory"
    case images = "Images"
    case browser = "Browser"

    var icon: String {
        switch self {
        case .web: return "globe"
        case .files: return "folder"
        case .execution: return "terminal"
        case .calendar: return "calendar"
        case .automation: return "cursorarrow.click.2"
        case .screen: return "camera.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .system: return "cpu"
        case .search: return "magnifyingglass"
        case .notifications: return "bell"
        case .network: return "network"
        case .scripting: return "applescript"
        case .memory: return "brain"
        case .images: return "photo"
        case .browser: return "safari"
        }
    }

    var label: String { rawValue }
}

struct CapabilityDefinition {
    let toolName: String
    let category: CapabilityCategory
    let minimumAccessLevel: AccessLevel
    let description: String
    let macOnly: Bool
}

enum CapabilityRegistry {
    static let all: [CapabilityDefinition] = [
        // Web
        CapabilityDefinition(toolName: "web_search", category: .web, minimumAccessLevel: .chatOnly, description: "Search the web", macOnly: false),
        CapabilityDefinition(toolName: "web_fetch", category: .web, minimumAccessLevel: .chatOnly, description: "Fetch web page content", macOnly: false),
        // Files
        CapabilityDefinition(toolName: "read_file", category: .files, minimumAccessLevel: .readFiles, description: "Read file contents", macOnly: false),
        CapabilityDefinition(toolName: "list_directory", category: .files, minimumAccessLevel: .readFiles, description: "List directory contents", macOnly: false),
        CapabilityDefinition(toolName: "write_file", category: .files, minimumAccessLevel: .writeFiles, description: "Write to files", macOnly: false),
        // Execution
        CapabilityDefinition(toolName: "run_command", category: .execution, minimumAccessLevel: .execute, description: "Run shell commands", macOnly: false),
        // Calendar
        CapabilityDefinition(toolName: "list_events", category: .calendar, minimumAccessLevel: .readFiles, description: "List calendar events", macOnly: false),
        CapabilityDefinition(toolName: "create_event", category: .calendar, minimumAccessLevel: .writeFiles, description: "Create calendar events", macOnly: false),
        CapabilityDefinition(toolName: "check_availability", category: .calendar, minimumAccessLevel: .readFiles, description: "Check free time slots", macOnly: false),
        // Automation (macOS)
        CapabilityDefinition(toolName: "open_file", category: .automation, minimumAccessLevel: .execute, description: "Open files, apps, URLs", macOnly: true),
        CapabilityDefinition(toolName: "mouse_control", category: .automation, minimumAccessLevel: .execute, description: "Control mouse cursor", macOnly: true),
        CapabilityDefinition(toolName: "keyboard_control", category: .automation, minimumAccessLevel: .execute, description: "Type text and keystrokes", macOnly: true),
        CapabilityDefinition(toolName: "window_management", category: .automation, minimumAccessLevel: .execute, description: "Manage app windows", macOnly: true),
        // Screen (macOS)
        CapabilityDefinition(toolName: "take_screenshot", category: .screen, minimumAccessLevel: .readFiles, description: "Capture screenshots", macOnly: true),
        CapabilityDefinition(toolName: "get_screen_info", category: .screen, minimumAccessLevel: .readFiles, description: "Get screen information", macOnly: true),
        CapabilityDefinition(toolName: "screen_record", category: .screen, minimumAccessLevel: .execute, description: "Record screen video", macOnly: true),
        // Clipboard (macOS)
        CapabilityDefinition(toolName: "clipboard_read", category: .clipboard, minimumAccessLevel: .readFiles, description: "Read clipboard contents", macOnly: true),
        CapabilityDefinition(toolName: "clipboard_write", category: .clipboard, minimumAccessLevel: .writeFiles, description: "Write to clipboard", macOnly: true),
        // System
        CapabilityDefinition(toolName: "process_list", category: .system, minimumAccessLevel: .readFiles, description: "List running processes", macOnly: false),
        CapabilityDefinition(toolName: "process_kill", category: .system, minimumAccessLevel: .execute, description: "Kill a process", macOnly: false),
        CapabilityDefinition(toolName: "system_monitor", category: .system, minimumAccessLevel: .readFiles, description: "CPU/memory/disk stats", macOnly: false),
        CapabilityDefinition(toolName: "volume_control", category: .system, minimumAccessLevel: .execute, description: "Control system volume", macOnly: true),
        // Search (macOS)
        CapabilityDefinition(toolName: "spotlight_search", category: .search, minimumAccessLevel: .readFiles, description: "Search via Spotlight", macOnly: true),
        CapabilityDefinition(toolName: "finder_reveal", category: .search, minimumAccessLevel: .readFiles, description: "Reveal file in Finder", macOnly: true),
        // Notifications (macOS)
        CapabilityDefinition(toolName: "send_notification", category: .notifications, minimumAccessLevel: .writeFiles, description: "Send system notification", macOnly: true),
        // Network
        CapabilityDefinition(toolName: "network_status", category: .network, minimumAccessLevel: .chatOnly, description: "Check network connectivity", macOnly: false),
        CapabilityDefinition(toolName: "browser_open", category: .network, minimumAccessLevel: .execute, description: "Open URL in browser", macOnly: true),
        // Scripting (macOS)
        CapabilityDefinition(toolName: "applescript_run", category: .scripting, minimumAccessLevel: .execute, description: "Run AppleScript", macOnly: true),
        // Images (DALL-E)
        CapabilityDefinition(toolName: "generate_image", category: .images, minimumAccessLevel: .chatOnly, description: "Generate images via DALL-E", macOnly: false),
        // Memory (Library of Alexandria)
        CapabilityDefinition(toolName: "loa_recall", category: .memory, minimumAccessLevel: .chatOnly, description: "Search memory bank", macOnly: false),
        CapabilityDefinition(toolName: "loa_teach", category: .memory, minimumAccessLevel: .chatOnly, description: "Store new knowledge", macOnly: false),
        CapabilityDefinition(toolName: "loa_forget", category: .memory, minimumAccessLevel: .chatOnly, description: "Remove stored knowledge", macOnly: false),
        CapabilityDefinition(toolName: "loa_entities", category: .memory, minimumAccessLevel: .chatOnly, description: "List known entities", macOnly: false),
        CapabilityDefinition(toolName: "loa_timeline", category: .memory, minimumAccessLevel: .chatOnly, description: "Browse memory timeline", macOnly: false),
        // Code Execution
        CapabilityDefinition(toolName: "execute_code", category: .execution, minimumAccessLevel: .execute, description: "Run code in sandbox", macOnly: false),
        CapabilityDefinition(toolName: "execute_code_docker", category: .execution, minimumAccessLevel: .execute, description: "Run code in Docker", macOnly: false),
        // Browser Automation
        CapabilityDefinition(toolName: "browser_navigate", category: .browser, minimumAccessLevel: .execute, description: "Navigate browser to URL", macOnly: false),
        CapabilityDefinition(toolName: "browser_screenshot", category: .browser, minimumAccessLevel: .readFiles, description: "Screenshot a web page", macOnly: false),
        CapabilityDefinition(toolName: "browser_extract", category: .browser, minimumAccessLevel: .readFiles, description: "Extract content from page", macOnly: false),
        CapabilityDefinition(toolName: "browser_interact", category: .browser, minimumAccessLevel: .execute, description: "Click/type on web page", macOnly: false),
        // Knowledge Search
        CapabilityDefinition(toolName: "search_documents", category: .search, minimumAccessLevel: .readFiles, description: "Search document embeddings", macOnly: false),
        // Workflows
        CapabilityDefinition(toolName: "create_workflow", category: .execution, minimumAccessLevel: .execute, description: "Create multi-step workflow", macOnly: false),
    ]

    static let byName: [String: CapabilityDefinition] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.toolName, $0) })
    }()

    static let byCategory: [CapabilityCategory: [CapabilityDefinition]] = {
        Dictionary(grouping: all, by: { $0.category })
    }()
}

// MARK: - Web Search (DuckDuckGo + scraping fallback)

actor WebSearchEngine {
    static let shared = WebSearchEngine()

    /// The tool definition clients can include in their tools array
    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "web_search",
            "description": "Search the web for current information. Use this when you need up-to-date information, news, or facts you don't know.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The search query"
                    ]
                ],
                "required": ["query"]
            ]
        ] as [String: Any]
    ]

    /// Execute a web search and return formatted results
    func search(query: String, maxResults: Int = 5) async -> String {
        // Try DuckDuckGo HTML search (no API key needed)
        if let results = await duckDuckGoSearch(query: query, maxResults: maxResults) {
            return results
        }
        return "Web search failed. No results found for: \(query)"
    }

    /// DuckDuckGo HTML search — scrapes the lite version
    private func duckDuckGoSearch(query: String, maxResults: Int) async -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let results = parseDDGResults(html: html, maxResults: maxResults)
            if results.isEmpty { return nil }
            return results
        } catch {
            TorboLog.error("DuckDuckGo error: \(error)", subsystem: "Tools")
            return nil
        }
    }

    /// Parse DuckDuckGo HTML lite results
    private func parseDDGResults(html: String, maxResults: Int) -> String {
        var results: [(title: String, snippet: String, url: String)] = []

        // Split by result blocks and extract URL + snippet from each

        let blocks = html.components(separatedBy: "class=\"result results_links")

        for block in blocks.prefix(maxResults + 1) {
            // Extract URL from result__a href
            if let aRange = block.range(of: #"class="result__a"[^>]*href="([^"]*)"#, options: .regularExpression),
               let hrefRange = block[aRange].range(of: #"href="([^"]*)"#, options: .regularExpression) {
                let hrefStr = String(block[hrefRange])
                let rawURL = hrefStr.replacingOccurrences(of: "href=\"", with: "").replacingOccurrences(of: "\"", with: "")

                // Decode DDG redirect URL
                var finalURL = rawURL
                if rawURL.contains("uddg="), let uddgRange = rawURL.range(of: "uddg=") {
                    let encoded = String(rawURL[uddgRange.upperBound...]).components(separatedBy: "&").first ?? ""
                    finalURL = encoded.removingPercentEncoding ?? encoded
                }

                // Extract title text between >...</a>
                var title = ""
                if let titleStart = block.range(of: "class=\"result__a\""),
                   let gtRange = block[titleStart.upperBound...].range(of: ">"),
                   let endRange = block[gtRange.upperBound...].range(of: "</a>") {
                    title = String(block[gtRange.upperBound..<endRange.lowerBound])
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Extract snippet
                var snippet = ""
                if let snippetStart = block.range(of: "class=\"result__snippet\""),
                   let gtRange2 = block[snippetStart.upperBound...].range(of: ">"),
                   let endRange2 = block[gtRange2.upperBound...].range(of: "</a>") {
                    snippet = String(block[gtRange2.upperBound..<endRange2.lowerBound])
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&#x27;", with: "'")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !title.isEmpty || !snippet.isEmpty {
                    results.append((title: title, snippet: snippet, url: finalURL))
                }
            }
        }

        if results.isEmpty { return "" }

        var output = "Web search results for query:\n\n"
        for (i, r) in results.prefix(maxResults).enumerated() {
            output += "[\(i + 1)] \(r.title)\n"
            if !r.snippet.isEmpty { output += "\(r.snippet)\n" }
            output += "URL: \(r.url)\n\n"
        }
        return output
    }

    /// The tool definition for web_fetch (read a URL)
    static let webFetchToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "web_fetch",
            "description": "Fetch and read the contents of a web page URL. Use this to read articles, documentation, or any web page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The URL to fetch"
                    ]
                ],
                "required": ["url"]
            ]
        ] as [String: Any]
    ]

    /// Fetch and extract text from a URL (for follow-up reads)
    func fetchPage(url: String, maxChars: Int = 4000) async -> String {
        guard let pageURL = URL(string: url) else { return "Invalid URL" }

        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return "Could not decode page" }

            // Strip HTML tags and extract text
            let text = html
                .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return String(text.prefix(maxChars))
        } catch {
            return "Failed to fetch page: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool Call Processing

/// Intercepts tool calls from model responses and executes built-in tools
actor ToolProcessor {
    static let shared = ToolProcessor()

    /// Core built-in tools that the gateway can execute server-side
    /// Derived from CapabilityRegistry + legacy tools not yet in the registry.
    static let coreToolNames: Set<String> = {
        // All tools from the registry
        var names = Set(CapabilityRegistry.all.map { $0.toolName })
        // Legacy tools that have execution handlers but aren't in the capability registry
        // (these are always available when their access level is met, not toggleable)
        names.formUnion(["generate_image", "search_documents", "create_workflow",
                         "execute_code", "execute_code_docker",
                         "browser_navigate", "browser_screenshot", "browser_extract", "browser_interact",
                         "loa_recall", "loa_teach", "loa_forget", "loa_entities", "loa_timeline"])
        return names
    }()

    /// All tool names the gateway handles (core + MCP)
    static var builtInToolNames: Set<String> {
        // Core tools + MCP tools checked dynamically via canExecute()
        return coreToolNames
    }

    /// Check if a tool name is one we can execute (core or MCP)
    static func canExecute(_ toolName: String) -> Bool {
        coreToolNames.contains(toolName) || toolName.hasPrefix("mcp_")
    }

    /// Check if a response contains tool calls for tools we can execute
    func hasBuiltInToolCalls(_ responseBody: [String: Any]) -> Bool {
        guard let choices = responseBody["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else { return false }

        return toolCalls.contains { call in
            let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
            return Self.canExecute(name)
        }
    }

    /// Execute built-in tool calls (core + MCP) and return results
    func executeBuiltInTools(_ toolCalls: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []

        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }

            guard Self.canExecute(name) else { continue }

            let argsStr = function["arguments"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

            var content = ""
            if name.hasPrefix("mcp_") {
                // Route to MCP server
                content = await MCPManager.shared.executeTool(name: name, arguments: args)
            } else {
                switch name {
                case "web_search":
                    let query = args["query"] as? String ?? ""
                    content = await WebSearchEngine.shared.search(query: query)
                case "web_fetch":
                    let url = args["url"] as? String ?? ""
                    if let ssrfError = AccessControl.validateURLForSSRF(url) {
                        content = "Blocked: \(ssrfError)"
                    } else {
                        content = await WebSearchEngine.shared.fetchPage(url: url)
                    }
                case "generate_image":
                    let prompt = args["prompt"] as? String ?? ""
                    let size = args["size"] as? String ?? "1024x1024"
                    content = await ImageGenerator.shared.generate(prompt: prompt, size: size)
                case "search_documents":
                    let query = args["query"] as? String ?? ""
                    let topK = args["top_k"] as? Int ?? 5
                    let results = await DocumentStore.shared.search(query: query, topK: topK)
                    if results.isEmpty {
                        content = "No relevant documents found for: \(query)"
                    } else {
                        content = results.enumerated().map { i, r in
                            "[\(i+1)] \(r.documentName) (chunk \(r.chunkIndex), score: \(String(format: "%.2f", r.score))):\n\(r.text)"
                        }.joined(separator: "\n\n")
                    }
                case "create_workflow":
                    let desc = args["description"] as? String ?? ""
                    let priorityRaw = args["priority"] as? Int ?? 1
                    let priority = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal
                    let workflow = await WorkflowEngine.shared.createWorkflow(
                        description: desc, createdBy: "agent", priority: priority
                    )
                    let stepSummary = workflow.steps.enumerated().map { idx, step in
                        "  \(idx + 1). \(step.title) → \(step.assignedTo)"
                    }.joined(separator: "\n")
                    content = "Workflow '\(workflow.name)' created (ID: \(workflow.id.prefix(8))) with \(workflow.steps.count) steps:\n\(stepSummary)\n\nStatus: \(workflow.status.rawValue)"
                case "execute_code":
                    let code = args["code"] as? String ?? ""
                    let langStr = args["language"] as? String ?? "python"
                    let timeout = min(args["timeout"] as? Int ?? 30, 120)
                    let codeWarning = SafetyWarnings.checkCodeExecution(language: langStr, code: code)
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var config = SandboxConfig()
                    config.timeout = TimeInterval(timeout)
                    let execResult = await CodeSandbox.shared.execute(code: code, language: language, config: config)
                    content = execResult.toolResponse
                    if let codeWarning { content = codeWarning.formatted + "\n\n" + content }
                case "list_events":
                    let days = args["days"] as? Int ?? 7
                    let calendarName = args["calendar"] as? String
                    let now = Date()
                    let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
                    let events = await CalendarManager.shared.listEvents(from: now, to: end, calendarName: calendarName)
                    content = await CalendarManager.shared.formatEvents(events)
                case "create_event":
                    let title = args["title"] as? String ?? "Untitled Event"
                    let startStr = args["start"] as? String ?? ""
                    let df = ISO8601DateFormatter()
                    guard let startDate = df.date(from: startStr) else {
                        content = "Error: Invalid start date format. Use ISO 8601 (e.g. 2025-01-15T10:00:00Z)"
                        break
                    }
                    let endDate: Date
                    if let endStr = args["end"] as? String, let end = df.date(from: endStr) {
                        endDate = end
                    } else {
                        let durMin = args["duration_minutes"] as? Int ?? 60
                        endDate = startDate.addingTimeInterval(TimeInterval(durMin * 60))
                    }
                    let location = args["location"] as? String
                    let notes = args["notes"] as? String
                    let calName = args["calendar"] as? String
                    let result = await CalendarManager.shared.createEvent(
                        title: title, startDate: startDate, endDate: endDate,
                        location: location, notes: notes, calendarName: calName
                    )
                    content = result.success ? "Event '\(title)' created successfully" : "Error: \(result.error ?? "Unknown")"
                case "check_availability":
                    let days = args["days"] as? Int ?? 1
                    let minDur = args["min_duration_minutes"] as? Int ?? 30
                    let now = Date()
                    let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
                    let slots = await CalendarManager.shared.findFreeSlots(from: now, to: end, minDuration: TimeInterval(minDur * 60))
                    if slots.isEmpty {
                        content = "No free slots of \(minDur)+ minutes found in the next \(days) day(s)."
                    } else {
                        content = "Free slots (\(slots.count)):\n" + slots.enumerated().map { i, slot in
                            "[\(i+1)] \(slot["start"] ?? "?") to \(slot["end"] ?? "?") (\(slot["duration_minutes"] ?? "?") min)"
                        }.joined(separator: "\n")
                    }
                // Browser automation tools
                case "browser_navigate":
                    let url = args["url"] as? String ?? ""
                    let result = await BrowserAutomation.shared.execute(action: .navigate, params: ["url": url])
                    content = result.toolResponse
                case "browser_screenshot":
                    let url = args["url"] as? String ?? ""
                    let fullPage = args["full_page"] as? Bool ?? false
                    let result = await BrowserAutomation.shared.execute(action: .screenshot, params: ["url": url, "fullPage": fullPage])
                    content = result.toolResponse
                case "browser_extract":
                    let url = args["url"] as? String ?? ""
                    let selector = args["selector"] as? String ?? "body"
                    let result = await BrowserAutomation.shared.execute(action: .extract, params: ["url": url, "selector": selector])
                    content = result.toolResponse
                case "browser_interact":
                    let url = args["url"] as? String ?? ""
                    let actionStr = args["action"] as? String ?? "click"
                    let selector = args["selector"] as? String ?? ""
                    let value = args["value"] as? String ?? ""
                    let browserAction: BrowserAction
                    switch actionStr {
                    case "click": browserAction = .click
                    case "type": browserAction = .type
                    case "select": browserAction = .select
                    case "scroll": browserAction = .scroll
                    case "evaluate": browserAction = .evaluate
                    default: browserAction = .click
                    }
                    var params: [String: Any] = ["url": url, "selector": selector]
                    if browserAction == .type { params["text"] = value }
                    else if browserAction == .select { params["value"] = value }
                    else if browserAction == .scroll { params["direction"] = value }
                    else if browserAction == .evaluate { params["javascript"] = value }
                    let result = await BrowserAutomation.shared.execute(action: browserAction, params: params)
                    content = result.toolResponse
                // Docker sandbox
                case "execute_code_docker":
                    let code = args["code"] as? String ?? ""
                    let langStr = args["language"] as? String ?? "python"
                    let timeout = min(args["timeout"] as? Int ?? 60, 120)
                    let dockerCodeWarning = SafetyWarnings.checkCodeExecution(language: langStr, code: code)
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var dockerConfig = DockerConfig()
                    dockerConfig.timeout = TimeInterval(timeout)
                    if let memLimit = args["memory_limit"] as? String { dockerConfig.memoryLimit = memLimit }
                    if let allowNet = args["allow_network"] as? Bool, allowNet { dockerConfig.networkMode = "bridge" }
                    let execResult = await DockerSandbox.shared.execute(code: code, language: language, config: dockerConfig)
                    content = execResult.toolResponse
                    if let dockerCodeWarning { content = dockerCodeWarning.formatted + "\n\n" + content }
                default:
                    content = "Unknown tool: \(name)"
                }
            }

            results.append([
                "role": "tool",
                "tool_call_id": id,
                "content": content
            ])
        }
        return results
    }
}

// MARK: - Voice: Text-to-Speech

actor TTSEngine {
    static let shared = TTSEngine()

    /// Synthesize speech from text. Tries ElevenLabs first, then OpenAI TTS.
    func synthesize(text: String, voice: String?, model: String?, keys: [String: String]) async -> (Data, String)? {
        // Try ElevenLabs first
        if let elevenKey = keys["ELEVENLABS_API_KEY"], !elevenKey.isEmpty {
            if let result = await elevenLabsTTS(text: text, voice: voice, apiKey: elevenKey) {
                return result
            }
        }

        // Fall back to OpenAI TTS
        if let openAIKey = keys["OPENAI_API_KEY"], !openAIKey.isEmpty {
            if let result = await openAITTS(text: text, voice: voice, model: model, apiKey: openAIKey) {
                return result
            }
        }

        return nil
    }

    private func elevenLabsTTS(text: String, voice: String?, apiKey: String) async -> (Data, String)? {
        let voiceId = voice ?? "21m00Tcm4TlvDq8ikWAM" // Rachel default
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ] as [String: Any]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                TorboLog.error("ElevenLabs error: \((response as? HTTPURLResponse)?.statusCode ?? 0)", subsystem: "Tools")
                return nil
            }
            return (data, "audio/mpeg")
        } catch {
            TorboLog.error("ElevenLabs error: \(error)", subsystem: "Tools")
            return nil
        }
    }

    private func openAITTS(text: String, voice: String?, model: String?, apiKey: String) async -> (Data, String)? {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model ?? "tts-1",
            "input": text,
            "voice": voice ?? "alloy",
            "response_format": "mp3"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                TorboLog.error("OpenAI TTS error: \((response as? HTTPURLResponse)?.statusCode ?? 0)", subsystem: "Tools")
                return nil
            }
            return (data, "audio/mpeg")
        } catch {
            TorboLog.error("OpenAI TTS error: \(error)", subsystem: "Tools")
            return nil
        }
    }
}

// MARK: - Voice: Speech-to-Text

actor STTEngine {
    static let shared = STTEngine()

    /// Transcribe audio data. Tries local Whisper (Ollama) first, then OpenAI.
    func transcribe(audioData: Data, filename: String, mimeType: String, keys: [String: String]) async -> String? {
        // Try OpenAI Whisper API
        if let openAIKey = keys["OPENAI_API_KEY"], !openAIKey.isEmpty {
            if let result = await openAIWhisper(audioData: audioData, filename: filename, apiKey: openAIKey) {
                return result
            }
        }

        return nil
    }

    /// Appends an ASCII string to Data — safe for multipart boundary strings.
    private func asciiData(_ string: String) -> Data {
        // ASCII strings always encode to UTF-8 successfully
        string.data(using: .utf8) ?? Data()
    }

    private func openAIWhisper(audioData: Data, filename: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else { return nil }

        // Build multipart form data
        let boundary = "TorboBase-\(UUID().uuidString)"
        var body = Data()

        // File field
        body.append(asciiData("--\(boundary)\r\n"))
        body.append(asciiData("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"))
        body.append(asciiData("Content-Type: audio/mpeg\r\n\r\n"))
        body.append(audioData)
        body.append(asciiData("\r\n"))

        // Model field
        body.append(asciiData("--\(boundary)\r\n"))
        body.append(asciiData("Content-Disposition: form-data; name=\"model\"\r\n\r\n"))
        body.append(asciiData("whisper-1\r\n"))

        // Response format
        body.append(asciiData("--\(boundary)\r\n"))
        body.append(asciiData("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"))
        body.append(asciiData("json\r\n"))

        body.append(asciiData("--\(boundary)--\r\n"))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                TorboLog.error("Whisper error: \((response as? HTTPURLResponse)?.statusCode ?? 0)", subsystem: "Tools")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text
            }
            return nil
        } catch {
            TorboLog.error("Whisper error: \(error)", subsystem: "Tools")
            return nil
        }
    }
}

// MARK: - Image Generation (DALL-E)

actor ImageGenerator {
    static let shared = ImageGenerator()

    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_image",
            "description": "Generate an image using DALL-E 3. Returns a URL to the generated image.",
            "parameters": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Image description prompt"],
                    "size": ["type": "string", "enum": ["1024x1024", "1024x1792", "1792x1024"], "description": "Image size (default: 1024x1024)"]
                ] as [String: Any],
                "required": ["prompt"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    func generate(prompt: String, size: String = "1024x1024") async -> String {
        let keys = await MainActor.run { AppState.shared.cloudAPIKeys }
        guard let openAIKey = keys["OPENAI_API_KEY"], !openAIKey.isEmpty else {
            return "Error: Image generation requires an OpenAI API key"
        }

        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            return "Error: Bad URL"
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "dall-e-3",
            "prompt": prompt,
            "n": 1,
            "size": size,
            "quality": "standard"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return "Image generation error: \(message)"
                }
                return "Image generation failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArr = json["data"] as? [[String: Any]],
               let first = dataArr.first {
                let imageURL = first["url"] as? String ?? ""
                let revisedPrompt = first["revised_prompt"] as? String ?? prompt
                return "Image generated successfully.\nURL: \(imageURL)\nRevised prompt: \(revisedPrompt)"
            }
            return "Image generation returned unexpected format"
        } catch {
            return "Image generation error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Content Extraction Helper

/// Extracts text content from OpenAI message content, handling both
/// string content and array content (vision/multimodal messages)
func extractTextContent(from content: Any?) -> String? {
    if let str = content as? String { return str }
    if let arr = content as? [[String: Any]] {
        return arr.compactMap { block -> String? in
            if block["type"] as? String == "text" { return block["text"] as? String }
            if block["type"] as? String == "image_url" { return "[image]" }
            return nil
        }.joined(separator: " ")
    }
    return nil
}

// MARK: - Anthropic Tool Conversion

/// Convert OpenAI-format tools to Anthropic format
func convertToolsToAnthropic(_ tools: [[String: Any]]) -> [[String: Any]] {
    return tools.compactMap { tool -> [String: Any]? in
        guard let function = tool["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }
        var anthropicTool: [String: Any] = ["name": name]
        if let desc = function["description"] as? String { anthropicTool["description"] = desc }
        if let params = function["parameters"] as? [String: Any] { anthropicTool["input_schema"] = params }
        return anthropicTool
    }
}

/// Convert OpenAI-format messages with tool_calls/tool results to Anthropic format
func convertMessagesToAnthropic(_ messages: [[String: Any]]) -> (messages: [[String: Any]], system: String?) {
    var anthropicMessages: [[String: Any]] = []
    var systemPrompt: String? = nil

    for msg in messages {
        let role = msg["role"] as? String ?? "user"

        if role == "system" {
            systemPrompt = extractTextContent(from: msg["content"])
            continue
        }

        if role == "tool" {
            // Tool result → Anthropic uses role: "user" with tool_result content block
            let toolCallId = msg["tool_call_id"] as? String ?? ""
            let content = extractTextContent(from: msg["content"]) ?? ""
            anthropicMessages.append([
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": toolCallId, "content": content]
                ] as [[String: Any]]
            ])
            continue
        }

        if role == "assistant", let toolCalls = msg["tool_calls"] as? [[String: Any]] {
            // Assistant with tool_calls → Anthropic uses content blocks
            var contentBlocks: [[String: Any]] = []
            if let text = extractTextContent(from: msg["content"]), !text.isEmpty {
                contentBlocks.append(["type": "text", "text": text])
            }
            for call in toolCalls {
                if let id = call["id"] as? String,
                   let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    let argsStr = function["arguments"] as? String ?? "{}"
                    let input = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                    contentBlocks.append(["type": "tool_use", "id": id, "name": name, "input": input])
                }
            }
            anthropicMessages.append(["role": "assistant", "content": contentBlocks])
            continue
        }

        // Regular message — handle vision content arrays
        if let contentArray = msg["content"] as? [[String: Any]] {
            // Convert OpenAI image_url blocks to Anthropic image blocks
            var anthropicContent: [[String: Any]] = []
            for block in contentArray {
                let blockType = block["type"] as? String ?? ""
                if blockType == "text" {
                    anthropicContent.append(block)
                } else if blockType == "image_url",
                          let imageURL = block["image_url"] as? [String: Any],
                          let url = imageURL["url"] as? String {
                    // Handle base64 data URIs
                    if url.hasPrefix("data:") {
                        let parts = url.components(separatedBy: ",")
                        if parts.count == 2 {
                            let mediaType = parts[0]
                                .replacingOccurrences(of: "data:", with: "")
                                .replacingOccurrences(of: ";base64", with: "")
                            anthropicContent.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": parts[1]
                                ] as [String: Any]
                            ])
                        }
                    } else {
                        // URL-based image
                        anthropicContent.append([
                            "type": "image",
                            "source": ["type": "url", "url": url] as [String: Any]
                        ])
                    }
                }
            }
            anthropicMessages.append(["role": role == "assistant" ? "assistant" : "user", "content": anthropicContent])
        } else {
            // Simple text message
            let content = extractTextContent(from: msg["content"]) ?? ""
            anthropicMessages.append(["role": role == "assistant" ? "assistant" : "user", "content": content])
        }
    }

    return (anthropicMessages, systemPrompt)
}

// Note: Anthropic streaming tool_use conversion is handled inline in GatewayManager.streamCloudCompletion()

// MARK: - Gemini Tool Conversion

/// Convert OpenAI-format tools to Gemini format
func convertToolsToGemini(_ tools: [[String: Any]]) -> [[String: Any]] {
    let functionDeclarations = tools.compactMap { tool -> [String: Any]? in
        guard let function = tool["function"] as? [String: Any],
              let name = function["name"] as? String else { return nil }
        var decl: [String: Any] = ["name": name]
        if let desc = function["description"] as? String { decl["description"] = desc }
        if let params = function["parameters"] as? [String: Any] { decl["parameters"] = params }
        return decl
    }
    return [["functionDeclarations": functionDeclarations]]
}

/// Convert OpenAI messages to Gemini format, handling tool calls and vision
func convertMessagesToGemini(_ messages: [[String: Any]]) -> (contents: [[String: Any]], system: [String: Any]?) {
    var contents: [[String: Any]] = []
    var systemInstruction: [String: Any]? = nil

    for msg in messages {
        let role = msg["role"] as? String ?? "user"

        if role == "system" {
            let text = extractTextContent(from: msg["content"]) ?? ""
            systemInstruction = ["parts": [["text": text]]]
            continue
        }

        if role == "tool" {
            // Tool result
            let name = msg["name"] as? String ?? "function"
            let content = extractTextContent(from: msg["content"]) ?? ""
            let response: [String: Any] = ["name": name, "response": ["result": content]]
            contents.append(["role": "user", "parts": [["functionResponse": response]]])
            continue
        }

        let geminiRole = (role == "assistant") ? "model" : "user"

        // Handle tool_calls in assistant messages
        if role == "assistant", let toolCalls = msg["tool_calls"] as? [[String: Any]] {
            var parts: [[String: Any]] = []
            if let text = extractTextContent(from: msg["content"]), !text.isEmpty {
                parts.append(["text": text])
            }
            for call in toolCalls {
                if let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    let argsStr = function["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                    parts.append(["functionCall": ["name": name, "args": args]])
                }
            }
            contents.append(["role": geminiRole, "parts": parts])
            continue
        }

        // Handle vision content arrays
        if let contentArray = msg["content"] as? [[String: Any]] {
            var parts: [[String: Any]] = []
            for block in contentArray {
                let blockType = block["type"] as? String ?? ""
                if blockType == "text", let text = block["text"] as? String {
                    parts.append(["text": text])
                } else if blockType == "image_url",
                          let imageURL = block["image_url"] as? [String: Any],
                          let url = imageURL["url"] as? String {
                    if url.hasPrefix("data:") {
                        let dataParts = url.components(separatedBy: ",")
                        if dataParts.count == 2 {
                            let mimeType = dataParts[0]
                                .replacingOccurrences(of: "data:", with: "")
                                .replacingOccurrences(of: ";base64", with: "")
                            parts.append(["inlineData": ["mimeType": mimeType, "data": dataParts[1]]])
                        }
                    }
                }
            }
            contents.append(["role": geminiRole, "parts": parts])
        } else {
            let text = extractTextContent(from: msg["content"]) ?? ""
            contents.append(["role": geminiRole, "parts": [["text": text]]])
        }
    }

    return (contents, systemInstruction)
}



// MARK: - System Access Tools

extension ToolProcessor {
    /// Tool definitions for all tools (filtered by access level)
    /// Built-in tools (web_search, web_fetch) are available at ALL levels.
    /// System access tools (files, commands) are gated by higher levels.
    /// search_documents tool definition
    static let searchDocumentsToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "search_documents",
            "description": "Search through ingested documents (PDFs, code files, text) using semantic search. Returns relevant passages from the user's document library.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query — what you're looking for in the documents"],
                    "top_k": ["type": "integer", "description": "Number of results to return (default: 5)"]
                ] as [String: Any],
                "required": ["query"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    /// create_workflow tool — lets agents decompose multi-step requests into workflows
    static let createWorkflowToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_workflow",
            "description": "Create a multi-step workflow that decomposes a complex task into sequential steps assigned to different agents. Each step's output becomes context for the next step. Use this when a request requires research, writing, reviewing, or multiple distinct phases.",
            "parameters": [
                "type": "object",
                "properties": [
                    "description": ["type": "string", "description": "Natural language description of the workflow (e.g. 'Research AI trends, write a report, then review it')"],
                    "priority": ["type": "integer", "description": "Priority level: 0=low, 1=normal, 2=high, 3=critical (default: 1)"]
                ] as [String: Any],
                "required": ["description"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    /// execute_code tool — sandboxed code execution
    static let executeCodeToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "execute_code",
            "description": "Execute code in a sandboxed environment. Supports Python (with numpy, pandas, matplotlib) and JavaScript (Node.js). Use this for calculations, data analysis, generating charts, file processing, or any task that benefits from actual code execution. Output includes stdout, stderr, and any generated files.",
            "parameters": [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "The code to execute"],
                    "language": ["type": "string", "enum": ["python", "javascript"], "description": "Programming language (default: python)"],
                    "timeout": ["type": "integer", "description": "Maximum execution time in seconds (default: 30, max: 120)"]
                ] as [String: Any],
                "required": ["code"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // Calendar tools
    static let listEventsToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "list_events",
            "description": "List calendar events for the next N days. Returns event titles, times, locations, and calendar names.",
            "parameters": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "Number of days to look ahead (default: 7)"],
                    "calendar": ["type": "string", "description": "Filter by calendar name (optional)"]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let createEventToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_event",
            "description": "Create a new calendar event. Provide title, start date/time, and optionally end date/time or duration.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event title"],
                    "start": ["type": "string", "description": "Start date/time in ISO 8601 format"],
                    "end": ["type": "string", "description": "End date/time in ISO 8601 (or use duration_minutes)"],
                    "duration_minutes": ["type": "integer", "description": "Duration in minutes (default: 60, used if end not provided)"],
                    "location": ["type": "string", "description": "Event location (optional)"],
                    "notes": ["type": "string", "description": "Event notes (optional)"],
                    "calendar": ["type": "string", "description": "Calendar name (optional, uses default)"]
                ] as [String: Any],
                "required": ["title", "start"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let checkAvailabilityToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "check_availability",
            "description": "Check calendar availability and find free time slots. Returns available time windows.",
            "parameters": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "Number of days to check (default: 1)"],
                    "min_duration_minutes": ["type": "integer", "description": "Minimum free slot duration in minutes (default: 30)"]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // Browser automation tools
    static let browserNavigateToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_navigate",
            "description": "Navigate to a URL in a headless browser and get the page title and URL. Use this to visit and verify web pages.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to navigate to"]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let browserScreenshotToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_screenshot",
            "description": "Take a screenshot of a web page. Returns a PNG image file.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to screenshot"],
                    "full_page": ["type": "boolean", "description": "Capture the full scrollable page (default: false)"]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let browserExtractToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_extract",
            "description": "Extract text content and links from a web page using a headless browser. More powerful than web_fetch — handles JavaScript-rendered content, SPAs, and dynamic pages.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to extract content from"],
                    "selector": ["type": "string", "description": "CSS selector to target specific content (default: 'body')"]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let browserInteractToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_interact",
            "description": "Interact with a web page — click elements, fill forms, select options. Use CSS selectors to target elements.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The URL to interact with"],
                    "action": ["type": "string", "enum": ["click", "type", "select", "scroll", "evaluate"], "description": "The interaction type"],
                    "selector": ["type": "string", "description": "CSS selector for the target element"],
                    "value": ["type": "string", "description": "Text to type, option to select, scroll direction, or JS code to evaluate"]
                ] as [String: Any],
                "required": ["url", "action"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    /// execute_code_docker tool — Docker-sandboxed code execution
    static let executeCodeDockerToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "execute_code_docker",
            "description": "Execute code in an isolated Docker container for maximum security. Supports Python (with numpy, pandas, matplotlib), JavaScript (Node.js), and Bash. Use this for untrusted code or when extra isolation is needed. Falls back to process sandbox if Docker is unavailable.",
            "parameters": [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "The code to execute"],
                    "language": ["type": "string", "enum": ["python", "javascript", "bash"], "description": "Programming language (default: python)"],
                    "timeout": ["type": "integer", "description": "Maximum execution time in seconds (default: 60, max: 120)"],
                    "memory_limit": ["type": "string", "description": "Container memory limit (default: '256m')"],
                    "allow_network": ["type": "boolean", "description": "Allow network access from container (default: false)"]
                ] as [String: Any],
                "required": ["code"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // MARK: - LoA (Library of Alexandria) Memory Tool Definitions

    static let loaRecallToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "loa_recall",
            "description": "Search your memory bank (Library of Alexandria) for previously stored knowledge. Returns matching entries ranked by relevance.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to search for in memory"],
                    "top_k": ["type": "integer", "description": "Maximum results to return (default: 10)"]
                ] as [String: Any],
                "required": ["query"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let loaTeachToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "loa_teach",
            "description": "Store new knowledge in your memory bank. Use this to remember facts, preferences, instructions, or anything the user wants you to retain across conversations.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The knowledge to store"],
                    "category": ["type": "string", "enum": ["fact", "preference", "instruction", "person", "project", "event"], "description": "Category of knowledge (default: fact)"],
                    "importance": ["type": "number", "description": "Importance from 0.0 to 1.0 (default: 0.7)"],
                    "entities": ["type": "array", "items": ["type": "string"], "description": "Related entity names (people, projects, etc.)"]
                ] as [String: Any],
                "required": ["text"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let loaForgetToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "loa_forget",
            "description": "Remove knowledge from your memory bank. Searches for matching entries and removes them.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to forget — matches will be removed from memory"]
                ] as [String: Any],
                "required": ["query"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let loaEntitiesToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "loa_entities",
            "description": "List all known entities (people, projects, topics) in your memory bank with mention counts.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let loaTimelineToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "loa_timeline",
            "description": "Browse memory entries chronologically. View what was stored in a given time range.",
            "parameters": [
                "type": "object",
                "properties": [
                    "range": ["type": "string", "enum": ["today", "yesterday", "week", "month", "year"], "description": "Time range to browse (default: week)"],
                    "top_k": ["type": "integer", "description": "Maximum entries to return (default: 20)"]
                ] as [String: Any],
                "required": []
            ] as [String: Any]
        ] as [String: Any]
    ]

    /// Map tool names to their static definition dicts
    private static func toolDefinitionDict(for toolName: String) -> [String: Any]? {
        switch toolName {
        // Web
        case "web_search": return WebSearchEngine.toolDefinition
        case "web_fetch": return WebSearchEngine.webFetchToolDefinition
        // Files
        case "read_file": return SystemAccessEngine.readFileToolDefinition
        case "write_file": return SystemAccessEngine.writeFileToolDefinition
        case "list_directory": return SystemAccessEngine.listDirectoryToolDefinition
        // Execution
        case "run_command": return SystemAccessEngine.runCommandToolDefinition
        // Calendar
        case "list_events": return listEventsToolDefinition
        case "create_event": return createEventToolDefinition
        case "check_availability": return checkAvailabilityToolDefinition
        // GUI Automation (macOS)
        #if os(macOS)
        case "open_file": return GUIAutomationEngine.openToolDefinition
        case "take_screenshot": return GUIAutomationEngine.screenshotToolDefinition
        case "mouse_control": return GUIAutomationEngine.mouseToolDefinition
        case "keyboard_control": return GUIAutomationEngine.keyboardToolDefinition
        case "window_management": return GUIAutomationEngine.windowToolDefinition
        case "get_screen_info": return GUIAutomationEngine.screenInfoToolDefinition
        // New macOS tools (Phase 2)
        case "clipboard_read": return SystemToolsEngine.clipboardReadDefinition
        case "clipboard_write": return SystemToolsEngine.clipboardWriteDefinition
        case "process_list": return SystemToolsEngine.processListDefinition
        case "process_kill": return SystemToolsEngine.processKillDefinition
        case "system_monitor": return SystemToolsEngine.systemMonitorDefinition
        case "volume_control": return SystemToolsEngine.volumeControlDefinition
        case "finder_reveal": return SystemToolsEngine.finderRevealDefinition
        case "spotlight_search": return SystemToolsEngine.spotlightSearchDefinition
        case "send_notification": return SystemToolsEngine.sendNotificationDefinition
        case "network_status": return SystemToolsEngine.networkStatusDefinition
        case "browser_open": return SystemToolsEngine.browserOpenDefinition
        case "applescript_run": return SystemToolsEngine.applescriptRunDefinition
        case "screen_record": return SystemToolsEngine.screenRecordDefinition
        #endif
        // Legacy tools (cross-platform)
        case "generate_image": return ImageGenerator.toolDefinition
        case "loa_recall": return loaRecallToolDefinition
        case "loa_teach": return loaTeachToolDefinition
        case "loa_forget": return loaForgetToolDefinition
        case "loa_entities": return loaEntitiesToolDefinition
        case "loa_timeline": return loaTimelineToolDefinition
        case "execute_code": return executeCodeToolDefinition
        case "execute_code_docker": return executeCodeDockerToolDefinition
        case "browser_navigate": return browserNavigateToolDefinition
        case "browser_screenshot": return browserScreenshotToolDefinition
        case "browser_extract": return browserExtractToolDefinition
        case "browser_interact": return browserInteractToolDefinition
        case "search_documents": return searchDocumentsToolDefinition
        case "create_workflow": return createWorkflowToolDefinition
        default: return nil
        }
    }

    /// Check if a tool's category is enabled for the given agent + global overrides
    private static func isCategoryEnabled(_ category: CapabilityCategory, agentCapabilities: [String: Bool], globalCapabilities: [String: Bool]) -> Bool {
        // Global override takes precedence — if globally disabled, no agent can use it
        if globalCapabilities[category.rawValue] == false { return false }
        // Agent-level toggle — empty dict means all enabled (backward compatible)
        if agentCapabilities[category.rawValue] == false { return false }
        return true
    }

    /// Filtered tool definitions: access level + platform + agent capabilities + global overrides
    static func toolDefinitions(for level: AccessLevel, agentCapabilities: [String: Bool] = [:], globalCapabilities: [String: Bool] = [:]) -> [[String: Any]] {
        var tools: [[String: Any]] = []

        for cap in CapabilityRegistry.all {
            // Access level gate
            guard level.rawValue >= cap.minimumAccessLevel.rawValue else { continue }
            // Platform gate
            #if !os(macOS)
            if cap.macOnly { continue }
            #endif
            // Category toggle gate
            guard isCategoryEnabled(cap.category, agentCapabilities: agentCapabilities, globalCapabilities: globalCapabilities) else { continue }
            // Get the definition dict
            if let def = toolDefinitionDict(for: cap.toolName) {
                tools.append(def)
            }
        }

        return tools
    }

    /// Tool definitions including MCP tools (async — queries MCPManager)
    static func toolDefinitionsWithMCP(for level: AccessLevel, agentID: String = "sid") async -> [[String: Any]] {
        // Load agent's capability toggles
        let agentConfig = await AgentConfigManager.shared.agent(agentID)
        let agentCaps = agentConfig?.enabledCapabilities ?? [:]
        let globalCaps = await MainActor.run { AppState.shared.globalCapabilities }

        var tools = toolDefinitions(for: level, agentCapabilities: agentCaps, globalCapabilities: globalCaps)

        // Append all MCP server tools (available at chatOnly and above)
        let mcpTools = await MCPManager.shared.toolDefinitions()
        if !mcpTools.isEmpty {
            tools.append(contentsOf: mcpTools)
        }
        return tools
    }

    /// Execute system access tools (called from the tool loop)
    func executeBuiltInTools(_ toolCalls: [[String: Any]], accessLevel: AccessLevel, agentID: String = "sid") async -> [[String: Any]] {
        let systemToolNames: Set<String> = ["read_file", "write_file", "list_directory", "run_command"]
        // Load agent directory scopes for path enforcement
        let scopes = await SystemAccessEngine.agentDirectoryScopes(for: agentID)
        var results: [[String: Any]] = []

        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }

            let argsStr = function["arguments"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

            // Handle MCP tools (prefixed with mcp_)
            if name.hasPrefix("mcp_") {
                let content = await MCPManager.shared.executeTool(name: name, arguments: args)
                results.append(["role": "tool", "tool_call_id": id, "content": content])
                continue
            }

            // Handle core built-in tools (excluding system tools which are handled below)
            if Self.coreToolNames.contains(name) && !systemToolNames.contains(name) {
                var content = ""
                switch name {
                case "web_search":
                    let query = args["query"] as? String ?? ""
                    content = await WebSearchEngine.shared.search(query: query)
                case "web_fetch":
                    let url = args["url"] as? String ?? ""
                    if let ssrfError = AccessControl.validateURLForSSRF(url) {
                        content = "Blocked: \(ssrfError)"
                    } else {
                        content = await WebSearchEngine.shared.fetchPage(url: url)
                    }
                case "generate_image":
                    let prompt = args["prompt"] as? String ?? ""
                    let size = args["size"] as? String ?? "1024x1024"
                    content = await ImageGenerator.shared.generate(prompt: prompt, size: size)
                case "search_documents":
                    let query = args["query"] as? String ?? ""
                    let topK = args["top_k"] as? Int ?? 5
                    let docResults = await DocumentStore.shared.search(query: query, topK: topK)
                    if docResults.isEmpty {
                        content = "No relevant documents found for: \(query)"
                    } else {
                        content = docResults.enumerated().map { i, r in
                            "[\(i+1)] \(r.documentName) (chunk \(r.chunkIndex), score: \(String(format: "%.2f", r.score))):\n\(r.text)"
                        }.joined(separator: "\n\n")
                    }
                case "create_workflow":
                    let desc = args["description"] as? String ?? ""
                    let priorityRaw = args["priority"] as? Int ?? 1
                    let prio = TaskQueue.TaskPriority(rawValue: priorityRaw) ?? .normal
                    let wf = await WorkflowEngine.shared.createWorkflow(
                        description: desc, createdBy: "agent", priority: prio
                    )
                    let stepSummary = wf.steps.enumerated().map { idx, step in
                        "  \(idx + 1). \(step.title) → \(step.assignedTo)"
                    }.joined(separator: "\n")
                    content = "Workflow '\(wf.name)' created (ID: \(wf.id.prefix(8))) with \(wf.steps.count) steps:\n\(stepSummary)\n\nStatus: \(wf.status.rawValue)"
                case "execute_code":
                    let code = args["code"] as? String ?? ""
                    let langStr = args["language"] as? String ?? "python"
                    let timeout = min(args["timeout"] as? Int ?? 30, 120)
                    let codeWarning2 = SafetyWarnings.checkCodeExecution(language: langStr, code: code)
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var cfg = SandboxConfig()
                    cfg.timeout = TimeInterval(timeout)
                    let execResult = await CodeSandbox.shared.execute(code: code, language: language, config: cfg)
                    content = execResult.toolResponse
                    if let codeWarning2 { content = codeWarning2.formatted + "\n\n" + content }
                case "list_events":
                    let days = args["days"] as? Int ?? 7
                    let calName = args["calendar"] as? String
                    let now = Date()
                    let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
                    let evts = await CalendarManager.shared.listEvents(from: now, to: end, calendarName: calName)
                    content = await CalendarManager.shared.formatEvents(evts)
                case "create_event":
                    let title = args["title"] as? String ?? "Untitled Event"
                    let startStr = args["start"] as? String ?? ""
                    let isoDF = ISO8601DateFormatter()
                    guard let startDate = isoDF.date(from: startStr) else {
                        content = "Error: Invalid start date format. Use ISO 8601"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    let endDate: Date
                    if let endStr = args["end"] as? String, let end = isoDF.date(from: endStr) {
                        endDate = end
                    } else {
                        let durMin = args["duration_minutes"] as? Int ?? 60
                        endDate = startDate.addingTimeInterval(TimeInterval(durMin * 60))
                    }
                    let loc = args["location"] as? String
                    let nts = args["notes"] as? String
                    let cn = args["calendar"] as? String
                    let res = await CalendarManager.shared.createEvent(
                        title: title, startDate: startDate, endDate: endDate,
                        location: loc, notes: nts, calendarName: cn
                    )
                    content = res.success ? "Event '\(title)' created" : "Error: \(res.error ?? "Unknown")"
                case "check_availability":
                    let days = args["days"] as? Int ?? 1
                    let minDur = args["min_duration_minutes"] as? Int ?? 30
                    let now = Date()
                    let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
                    let slots = await CalendarManager.shared.findFreeSlots(from: now, to: end, minDuration: TimeInterval(minDur * 60))
                    if slots.isEmpty {
                        content = "No free slots found"
                    } else {
                        content = "Free slots:\n" + slots.enumerated().map { i, slot in
                            "[\(i+1)] \(slot["start"] ?? "") to \(slot["end"] ?? "") (\(slot["duration_minutes"] ?? "?") min)"
                        }.joined(separator: "\n")
                    }
                // Browser automation tools
                case "browser_navigate":
                    let url = args["url"] as? String ?? ""
                    let browserResult = await BrowserAutomation.shared.execute(action: .navigate, params: ["url": url])
                    content = browserResult.toolResponse
                case "browser_screenshot":
                    let url = args["url"] as? String ?? ""
                    let fullPage = args["full_page"] as? Bool ?? false
                    let browserResult = await BrowserAutomation.shared.execute(action: .screenshot, params: ["url": url, "fullPage": fullPage])
                    content = browserResult.toolResponse
                case "browser_extract":
                    let url = args["url"] as? String ?? ""
                    let selector = args["selector"] as? String ?? "body"
                    let browserResult = await BrowserAutomation.shared.execute(action: .extract, params: ["url": url, "selector": selector])
                    content = browserResult.toolResponse
                case "browser_interact":
                    let url = args["url"] as? String ?? ""
                    let actionStr = args["action"] as? String ?? "click"
                    let selector = args["selector"] as? String ?? ""
                    let value = args["value"] as? String ?? ""
                    let browserAction: BrowserAction
                    switch actionStr {
                    case "click": browserAction = .click
                    case "type": browserAction = .type
                    case "select": browserAction = .select
                    case "scroll": browserAction = .scroll
                    case "evaluate": browserAction = .evaluate
                    default: browserAction = .click
                    }
                    var bParams: [String: Any] = ["url": url, "selector": selector]
                    if browserAction == .type { bParams["text"] = value }
                    else if browserAction == .select { bParams["value"] = value }
                    else if browserAction == .scroll { bParams["direction"] = value }
                    else if browserAction == .evaluate { bParams["javascript"] = value }
                    let browserResult = await BrowserAutomation.shared.execute(action: browserAction, params: bParams)
                    content = browserResult.toolResponse
                // Docker sandbox
                case "execute_code_docker":
                    let code = args["code"] as? String ?? ""
                    let langStr = args["language"] as? String ?? "python"
                    let timeout = min(args["timeout"] as? Int ?? 60, 120)
                    let dockerCodeWarning2 = SafetyWarnings.checkCodeExecution(language: langStr, code: code)
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var dockerCfg = DockerConfig()
                    dockerCfg.timeout = TimeInterval(timeout)
                    if let memLimit = args["memory_limit"] as? String { dockerCfg.memoryLimit = memLimit }
                    if let allowNet = args["allow_network"] as? Bool, allowNet { dockerCfg.networkMode = "bridge" }
                    let execResult = await DockerSandbox.shared.execute(code: code, language: language, config: dockerCfg)
                    content = execResult.toolResponse
                    if let dockerCodeWarning2 { content = dockerCodeWarning2.formatted + "\n\n" + content }
                // LoA (Library of Alexandria) — Memory Tools
                case "loa_recall":
                    let q = args["query"] as? String ?? ""
                    let topK = args["top_k"] as? Int ?? 10
                    let loaResults = await MemoryIndex.shared.hybridSearch(query: q, topK: topK)
                    if loaResults.isEmpty {
                        content = "The Library has no scrolls matching: \(q)"
                    } else {
                        content = "📜 Library of Alexandria — \(loaResults.count) scrolls found:\n\n" +
                            loaResults.enumerated().map { i, r in
                                "[\(i+1)] (\(r.category), importance: \(String(format: "%.1f", r.importance)), score: \(String(format: "%.2f", r.score)))\n\(r.text)"
                            }.joined(separator: "\n\n")
                    }
                case "loa_teach":
                    let text = args["text"] as? String ?? ""
                    let category = args["category"] as? String ?? "fact"
                    let importance = Float(args["importance"] as? Double ?? 0.7)
                    let entities = args["entities"] as? [String] ?? []
                    guard !text.isEmpty else {
                        content = "Cannot teach an empty scroll."
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    let taughtID = await MemoryIndex.shared.addWithEntities(
                        text: text, category: category, source: "agent_taught",
                        importance: importance, entities: entities
                    )
                    content = taughtID != nil ? "📜 Scroll added to the Library: \"\(String(text.prefix(100)))\"" : "Failed to add scroll — is Ollama running?"
                case "loa_forget":
                    let q = args["query"] as? String ?? ""
                    guard !q.isEmpty else {
                        content = "What should the Library forget? Provide a query."
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    let matches = await MemoryIndex.shared.hybridSearch(query: q, topK: 5)
                    if matches.isEmpty {
                        content = "No matching scrolls found for: \(q)"
                    } else {
                        let ids = matches.map { $0.id }
                        await MemoryIndex.shared.removeBatch(ids: ids)
                        content = "📜 Removed \(ids.count) scrolls from the Library matching: \(q)\n" +
                            matches.map { "  - \($0.text.prefix(80))..." }.joined(separator: "\n")
                    }
                case "loa_entities":
                    let allEntries = await MemoryIndex.shared.allEntries
                    var entityCounts: [String: Int] = [:]
                    for entry in allEntries {
                        for entity in entry.entities {
                            entityCounts[entity, default: 0] += 1
                        }
                    }
                    let sorted = entityCounts.sorted { $0.value > $1.value }
                    if sorted.isEmpty {
                        content = "The Library has no tagged entities yet."
                    } else {
                        content = "📜 Library of Alexandria — Known Entities (\(sorted.count)):\n\n" +
                            sorted.prefix(50).map { "\($0.key) (\($0.value) mentions)" }.joined(separator: "\n")
                    }
                case "loa_timeline":
                    let rangeStr = args["range"] as? String ?? "week"
                    let topK = args["top_k"] as? Int ?? 20
                    let now = Date()
                    let cal = Calendar.current
                    let from: Date
                    switch rangeStr {
                    case "today": from = cal.startOfDay(for: now)
                    case "yesterday":
                        from = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now) ?? now)
                    case "week": from = cal.date(byAdding: .day, value: -7, to: now) ?? now
                    case "month": from = cal.date(byAdding: .month, value: -1, to: now) ?? now
                    case "year": from = cal.date(byAdding: .year, value: -1, to: now) ?? now
                    default: from = cal.date(byAdding: .day, value: -7, to: now) ?? now
                    }
                    let timeResults = await MemoryIndex.shared.temporalSearch(from: from, to: now, topK: topK)
                    if timeResults.isEmpty {
                        content = "No scrolls found in the \(rangeStr) timeline."
                    } else {
                        let fmt = DateFormatter()
                        fmt.dateStyle = .medium
                        fmt.timeStyle = .short
                        content = "📜 Library of Alexandria — Timeline (\(rangeStr)):\n\n" +
                            timeResults.map { r in
                                "[\(fmt.string(from: r.timestamp))] (\(r.category)) \(r.text)"
                            }.joined(separator: "\n\n")
                    }
                // GUI automation tools (macOS only)
                #if os(macOS)
                case "open_file":
                    let target = args["target"] as? String ?? ""
                    let application = args["application"] as? String
                    let background = args["background"] as? Bool ?? false
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ open_file requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.openTarget(target, application: application, background: background)
                case "take_screenshot":
                    let mode = args["mode"] as? String ?? "fullscreen"
                    let region = args["region"] as? [String: Int]
                    let filename = args["filename"] as? String
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ take_screenshot requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.takeScreenshot(mode: mode, region: region, filename: filename)
                case "mouse_control":
                    let action2 = args["action"] as? String ?? "click"
                    let mx = args["x"] as? Int ?? 0
                    let my = args["y"] as? Int ?? 0
                    let endX = args["end_x"] as? Int
                    let endY = args["end_y"] as? Int
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ mouse_control requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.mouseControl(action: action2, x: mx, y: my, endX: endX, endY: endY)
                case "keyboard_control":
                    let kbAction = args["action"] as? String ?? "type"
                    let kbText = args["text"] as? String ?? ""
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ keyboard_control requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.keyboardControl(action: kbAction, text: kbText)
                case "window_management":
                    let wmAction = args["action"] as? String ?? "list"
                    let wmApp = args["app"] as? String
                    let wmX = args["x"] as? Int
                    let wmY = args["y"] as? Int
                    let wmW = args["width"] as? Int
                    let wmH = args["height"] as? Int
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ window_management requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.windowManagement(action: wmAction, app: wmApp, x: wmX, y: wmY, width: wmW, height: wmH)
                case "get_screen_info":
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ get_screen_info requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await GUIAutomationEngine.shared.getScreenInfo()
                // New system tools (macOS only)
                case "clipboard_read":
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ clipboard_read requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.clipboardRead()
                case "clipboard_write":
                    let text = args["text"] as? String ?? ""
                    guard accessLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                        content = "❌ clipboard_write requires write access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.clipboardWrite(text: text)
                case "process_list":
                    let limit = args["limit"] as? Int ?? 20
                    let filter = args["filter"] as? String
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ process_list requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.processList(limit: limit, filter: filter)
                case "process_kill":
                    let pid = args["pid"] as? Int ?? 0
                    let signal = args["signal"] as? String ?? "TERM"
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ process_kill requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.processKill(pid: pid, signal: signal)
                case "system_monitor":
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ system_monitor requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.systemMonitor()
                case "volume_control":
                    let vcAction = args["action"] as? String ?? "get"
                    let vcLevel = args["level"] as? Int
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ volume_control requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.volumeControl(action: vcAction, level: vcLevel)
                case "finder_reveal":
                    let frPath = args["path"] as? String ?? ""
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ finder_reveal requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    if !scopes.isEmpty && !SystemAccessEngine.isPathAllowed(frPath, scopes: scopes) {
                        content = "BLOCKED: Path '\(frPath)' is outside this agent's allowed directories."
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.finderReveal(path: frPath)
                case "spotlight_search":
                    let ssQuery = args["query"] as? String ?? ""
                    var ssDir = args["directory"] as? String
                    let ssLimit = args["limit"] as? Int ?? 20
                    guard accessLevel.rawValue >= AccessLevel.readFiles.rawValue else {
                        content = "❌ spotlight_search requires read access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    if !scopes.isEmpty {
                        if let dir = ssDir {
                            if !SystemAccessEngine.isPathAllowed(dir, scopes: scopes) {
                                content = "BLOCKED: Directory '\(dir)' is outside this agent's allowed directories."
                                results.append(["role": "tool", "tool_call_id": id, "content": content])
                                continue
                            }
                        } else {
                            ssDir = scopes.first // restrict to first scope when no dir specified
                        }
                    }
                    content = await SystemToolsEngine.shared.spotlightSearch(query: ssQuery, directory: ssDir, limit: ssLimit)
                case "send_notification":
                    let snTitle = args["title"] as? String ?? ""
                    let snMessage = args["message"] as? String ?? ""
                    let snSubtitle = args["subtitle"] as? String
                    let snSound = args["sound"] as? Bool ?? true
                    guard accessLevel.rawValue >= AccessLevel.writeFiles.rawValue else {
                        content = "❌ send_notification requires write access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.sendNotification(title: snTitle, message: snMessage, subtitle: snSubtitle, sound: snSound)
                case "network_status":
                    content = await SystemToolsEngine.shared.networkStatus()
                case "browser_open":
                    let boURL = args["url"] as? String ?? ""
                    let boBrowser = args["browser"] as? String
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ browser_open requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.browserOpen(url: boURL, browser: boBrowser)
                case "applescript_run":
                    let asScript = args["script"] as? String ?? ""
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ applescript_run requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    var asResult = await SystemToolsEngine.shared.applescriptRun(script: asScript)
                    if !scopes.isEmpty {
                        asResult += "\n⚠️ Note: AppleScript runs unrestricted. Directory scope enforcement applies to file tools only."
                    }
                    content = asResult
                case "screen_record":
                    let srDuration = args["duration"] as? Int ?? 5
                    let srFilename = args["filename"] as? String
                    guard accessLevel.rawValue >= AccessLevel.execute.rawValue else {
                        content = "❌ screen_record requires execute access level"
                        results.append(["role": "tool", "tool_call_id": id, "content": content])
                        continue
                    }
                    content = await SystemToolsEngine.shared.screenRecord(duration: srDuration, filename: srFilename)
                #endif
                default:
                    content = "Unknown tool: \(name)"
                }
                results.append(["role": "tool", "tool_call_id": id, "content": content])
                continue
            }

            // Handle system access tools
            if systemToolNames.contains(name) {
                var content: String
                var fileWarning: SafetyWarning? = nil
                switch name {
                case "read_file":
                    let path = args["path"] as? String ?? ""
                    let maxChars = args["max_chars"] as? Int ?? 50000
                    fileWarning = SafetyWarnings.checkFileOperation(path: path, operation: "read", scopes: scopes)
                    content = await SystemAccessEngine.shared.readFile(path: path, maxChars: maxChars, scopes: scopes, accessLevel: accessLevel)
                case "write_file":
                    let path = args["path"] as? String ?? ""
                    let fileContent = args["content"] as? String ?? ""
                    let append = args["append"] as? Bool ?? false
                    fileWarning = SafetyWarnings.checkFileOperation(path: path, operation: "write", scopes: scopes)
                    content = await SystemAccessEngine.shared.writeFile(path: path, content: fileContent, append: append, scopes: scopes, accessLevel: accessLevel)
                case "list_directory":
                    let path = args["path"] as? String ?? ""
                    let recursive = args["recursive"] as? Bool ?? false
                    content = await SystemAccessEngine.shared.listDirectory(path: path, recursive: recursive, scopes: scopes, accessLevel: accessLevel)
                case "run_command":
                    let command = args["command"] as? String ?? ""
                    let workDir = args["working_directory"] as? String
                    let timeout = args["timeout"] as? Int ?? 30
                    content = await SystemAccessEngine.shared.runCommand(command: command, workingDirectory: workDir, timeout: timeout, accessLevel: accessLevel)
                default:
                    content = "Unknown tool: \(name)"
                }
                if let fileWarning { content = fileWarning.formatted + "\n\n" + content }
                TorboLog.info("Executed 1 built-in tool(s) (level: \(accessLevel.name))", subsystem: "Tools")
                results.append(["role": "tool", "tool_call_id": id, "content": content])
                continue
            }

            // Unknown tool — skip
            results.append(["role": "tool", "tool_call_id": id, "content": "Unknown tool: \(name)"])
        }
        return results
    }
}

// MARK: - Filesystem & Shell Access

actor SystemAccessEngine {
    static let shared = SystemAccessEngine()

    static let readFileToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "read_file",
            "description": "Read the contents of a file at the given path.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path to read"],
                    "max_chars": ["type": "integer", "description": "Max characters (default: 50000)"]
                ] as [String: Any],
                "required": ["path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let writeFileToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "write_file",
            "description": "Write content to a file. Creates parent directories if needed.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path to write"],
                    "content": ["type": "string", "description": "Content to write"],
                    "append": ["type": "boolean", "description": "Append instead of overwrite (default: false)"]
                ] as [String: Any],
                "required": ["path", "content"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let listDirectoryToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "list_directory",
            "description": "List files and directories at the given path.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Directory path to list"],
                    "recursive": ["type": "boolean", "description": "List recursively up to 2 levels (default: false)"]
                ] as [String: Any],
                "required": ["path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let runCommandToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run_command",
            "description": "Execute a shell command via /bin/zsh and return output.",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Shell command to execute"],
                    "working_directory": ["type": "string", "description": "Working directory (default: home)"],
                    "timeout": ["type": "integer", "description": "Timeout in seconds (default: 30, max: 300)"]
                ] as [String: Any],
                "required": ["command"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // MARK: - Core File Protection

    /// Files that cannot be modified via write_file
    /// These are core infrastructure — changes require manual review
    static let coreFileLocklist: [String] = [
        "GatewayServer.swift",
        "Capabilities.swift",
        "AppState.swift",
        "TorboBaseApp.swift",
        "KeychainManager.swift",
        "PairingManager.swift",
        "ConversationStore.swift",
        "TaskQueue.swift",
        "TaskQueueRoutes.swift",
        "ProactiveAgent.swift",
        "AudioManager.swift",
        "AudioSessionManager.swift",
        "GatewayManager.swift",
        "SidPersonality.swift",
        "RootView.swift",
        "ContentView.swift",
        "ChatView.swift"
    ]

    static func isCoreFile(_ path: String) -> Bool {
        let filename = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).lastPathComponent
        return coreFileLocklist.contains(filename)
    }

    // MARK: - Command Safety

    enum CommandThreat { case safe, moderate, destructive, blocked }

    static let protectedPaths = ["/System", "/Library", "/usr", "/bin", "/sbin", "/Applications"]

    /// Agent directory scopes — loaded dynamically from AgentConfigManager
    /// Empty array = unrestricted within sandbox
    static func agentDirectoryScopes(for agentID: String) async -> [String] {
        if let agent = await AgentConfigManager.shared.agent(agentID) {
            return agent.directoryScopes
        }
        return []  // Default: unrestricted
    }

    private static let destructivePatterns = [
        "rm ", "rmdir", "mv ", "git push", "git reset --hard",
        "git clean", "git checkout -- .", "chmod", "chown", "sudo",
        "kill ", "killall", "pkill", "shutdown", "reboot"
    ]

    private static let safePatterns = [
        "ls", "cat ", "head ", "tail ", "grep ", "find ",
        "which ", "file ", "wc ", "diff ", "uptime", "whoami",
        "pwd", "echo ", "git status", "git log", "git diff",
        "swift build", "swift --version", "xcodebuild",
        "ps ", "df ", "du "
    ]

    /// Shell metacharacters that indicate command chaining / injection attempts
    private static let shellInjectionPatterns = [
        "$(", "`",         // Command substitution
        "&&", "||", ";",   // Command chaining
        "|",               // Piping (could bypass blocklist)
        "\n",              // Newline injection
        "\\x", "\\u",     // Hex/unicode escape injection
    ]

    /// Commands that can execute arbitrary code even without blocked command names
    private static let codeExecutionCommands = [
        "eval ", "exec ", "source ",
        "python ", "python3 ", "ruby ", "perl ", "node ", "php ",
        "bash ", "zsh ", "sh ", "dash ",
        "osascript ", "open -a terminal",
        "xargs ", "env ",
        "curl ", "wget ",   // Data exfiltration risk
    ]

    static func classifyCommand(_ command: String, accessLevel: AccessLevel = .chatOnly) -> CommandThreat {
        // VIP (fullAccess) agents bypass all command restrictions except fork bombs
        let vip = accessLevel == .fullAccess

        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()

        // Block fork bombs, root deletion, etc. — even for VIP
        if cmd.contains("sudo rm -rf /") || cmd.contains(":(){ :|:& };:") || cmd == "rm -rf /" { return .blocked }

        // VIP agents get unrestricted shell access
        if vip { return .safe }

        // Block shell injection / chaining attempts
        for pattern in shellInjectionPatterns {
            if cmd.contains(pattern) {
                // Allow safe piping for read-only commands (e.g., "ls | grep foo")
                if pattern == "|" {
                    let parts = cmd.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    let allSafe = parts.allSatisfy { part in safePatterns.contains { part.hasPrefix($0.lowercased()) } }
                    if allSafe { continue }
                }
                return .destructive
            }
        }

        // Block code execution commands (eval, python, bash, etc.)
        for pattern in codeExecutionCommands {
            if cmd.hasPrefix(pattern) { return .destructive }
        }

        // Standard destructive pattern check
        for p in destructivePatterns { if cmd.contains(p.lowercased()) { return .destructive } }

        // Safe pattern check
        for p in safePatterns { if cmd.hasPrefix(p.lowercased()) { return .safe } }

        return .moderate
    }

    static func isProtectedPath(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return protectedPaths.contains { expanded.hasPrefix($0) }
    }

    /// Sensitive paths that should NEVER be readable by agents — even at full access
    private static let sensitiveReadPaths = [
        "/.ssh/", "/keychain.json", "/keychain.enc", "/.gnupg/", "/.aws/credentials",
        "/.config/torbobase/keychain.json", "/.config/torbobase/keychain.enc", "/.env"
    ]

    /// Check if a path is a sensitive file that should be blocked from reading
    static func isSensitiveReadPath(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        let home = NSHomeDirectory()
        for sensitive in sensitiveReadPaths {
            if expanded == home + sensitive || expanded.contains(sensitive) { return true }
        }
        return false
    }

    /// Check if a path is within the allowed directory scopes for an agent.
    /// Returns true if the path is allowed, false if blocked.
    /// Empty scopes = unrestricted (within other safety checks).
    static func isPathAllowed(_ path: String, scopes: [String]) -> Bool {
        guard !scopes.isEmpty else { return true }  // No scopes = unrestricted
        let expanded = NSString(string: path).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardized.path
        for scope in scopes {
            let scopeExpanded = NSString(string: scope).expandingTildeInPath
            let scopeResolved = URL(fileURLWithPath: scopeExpanded).standardized.path
            if resolved == scopeResolved || resolved.hasPrefix(scopeResolved + "/") { return true }
        }
        return false
    }

    func backupFile(at path: String) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else { return nil }
        let backupDir = NSHomeDirectory() + "/.torbo-backup"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = URL(fileURLWithPath: expanded).lastPathComponent
        let backupPath = "\(backupDir)/\(timestamp)_\(filename)"
        do {
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: expanded, toPath: backupPath)
            TorboLog.info("Backed up \(path) -> \(backupPath)", subsystem: "Tools")
            return backupPath
        } catch { return nil }
    }

    // MARK: - Execution

    func readFile(path: String, maxChars: Int = 50000, scopes: [String] = [], accessLevel: AccessLevel = .chatOnly) -> String {
        let p = NSString(string: path).expandingTildeInPath
        let vip = accessLevel == .fullAccess
        // VIP (level 5) bypasses all path restrictions
        if !vip {
            // Block sensitive paths (SSH keys, API keys, credentials)
            if Self.isSensitiveReadPath(p) {
                TorboLog.warn("BLOCKED read of sensitive path: \(path)", subsystem: "Tools")
                return "BLOCKED: Access to sensitive system files is not permitted."
            }
            // Block protected system paths
            if Self.isProtectedPath(p) { return "BLOCKED: protected system path" }
            // Enforce agent directory scopes
            if !Self.isPathAllowed(p, scopes: scopes) {
                return "BLOCKED: Path '\(path)' is outside this agent's allowed directories."
            }
        }
        guard FileManager.default.fileExists(atPath: p) else { return "Error: File not found at '\(path)'" }
        do {
            let content = try String(contentsOfFile: p, encoding: .utf8)
            return content.count > maxChars ? String(content.prefix(maxChars)) + "\n[truncated]" : content
        } catch { return "Error: \(error.localizedDescription)" }
    }

    func writeFile(path: String, content: String, append: Bool = false, scopes: [String] = [], accessLevel: AccessLevel = .chatOnly) -> String {
        let p = NSString(string: path).expandingTildeInPath
        let vip = accessLevel == .fullAccess
        if !vip {
            if Self.isProtectedPath(p) { return "BLOCKED: protected system path" }
            if Self.isCoreFile(p) {
                TorboLog.warn("BLOCKED write to core file: \(path)", subsystem: "Tools")
                return "BLOCKED: \(URL(fileURLWithPath: p).lastPathComponent) is a core infrastructure file. Create a NEW file instead, or ask MM to modify it manually."
            }
            // Block writes to sensitive paths
            if Self.isSensitiveReadPath(p) {
                TorboLog.warn("BLOCKED write to sensitive path: \(path)", subsystem: "Tools")
                return "BLOCKED: Cannot write to sensitive system files."
            }
            // Enforce agent directory scopes
            if !Self.isPathAllowed(p, scopes: scopes) {
                return "BLOCKED: Path '\(path)' is outside this agent's allowed directories."
            }
        }
        if FileManager.default.fileExists(atPath: p) { _ = backupFile(at: p) }
        let url = URL(fileURLWithPath: p)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, FileManager.default.fileExists(atPath: p) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                guard let contentData = content.data(using: .utf8) else {
                    handle.closeFile()
                    return "Error: content contains characters that cannot be encoded as UTF-8"
                }
                handle.write(contentData)
                handle.closeFile()
                return "Appended \(content.count) chars to \(path)"
            }
            try content.write(toFile: p, atomically: true, encoding: .utf8)
            return "Wrote \(content.count) chars to \(path)"
        } catch { return "Error: \(error.localizedDescription)" }
    }

    func listDirectory(path: String, recursive: Bool = false, scopes: [String] = [], accessLevel: AccessLevel = .chatOnly) -> String {
        let p = NSString(string: path).expandingTildeInPath
        let vip = accessLevel == .fullAccess
        if !vip {
            // Block protected system paths
            if Self.isProtectedPath(p) { return "BLOCKED: protected system path" }
            // Block sensitive paths
            if Self.isSensitiveReadPath(p) { return "BLOCKED: Access to sensitive system files is not permitted." }
            // Enforce agent directory scopes
            if !Self.isPathAllowed(p, scopes: scopes) {
                return "BLOCKED: Path '\(path)' is outside this agent's allowed directories."
            }
        }
        guard FileManager.default.fileExists(atPath: p) else { return "Error: not found" }
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: p).sorted()
            var result = "Contents of \(path):\n"
            for item in items {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(item), isDirectory: &isDir)
                result += isDir.boolValue ? "  \(item)/\n" : "  \(item)\n"
            }
            return result
        } catch { return "Error: \(error.localizedDescription)" }
    }

    func runCommand(command: String, workingDirectory: String? = nil, timeout: Int = 30, accessLevel: AccessLevel = .chatOnly) async -> String {
        let threat = Self.classifyCommand(command, accessLevel: accessLevel)
        switch threat {
        case .blocked: return "BLOCKED: Too dangerous."
        case .destructive: return "CONFIRMATION REQUIRED: \(command)"
        case .moderate: TorboLog.info("Moderate command: \(command)", subsystem: "Tools")
        case .safe: break
        }
        let workDir = workingDirectory.map { NSString(string: $0).expandingTildeInPath } ?? NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let timeoutTask = Task { try await Task.sleep(nanoseconds: UInt64(min(max(timeout,1),300)) * 1_000_000_000); if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            timeoutTask.cancel()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var result = out
            if !err.isEmpty { result += (result.isEmpty ? "" : "\n") + "STDERR: " + err }
            if result.isEmpty { result = "(no output)" }
            if process.terminationStatus != 0 { result += "\n[exit code: \(process.terminationStatus)]" }
            return result.count > 50000 ? String(result.prefix(50000)) + "\n[truncated]" : result
        } catch { return "Error: \(error.localizedDescription)" }
    }
}

// MARK: - GUI Automation Engine (macOS)
// Gives SiD hands and eyes — open files/apps, take screenshots,
// control mouse/keyboard, manage windows.

#if os(macOS)
actor GUIAutomationEngine {
    static let shared = GUIAutomationEngine()

    // MARK: - Tool Definitions

    static let openToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "open_file",
            "description": "Open a file, application, or URL on macOS. Uses the system 'open' command. Can open files in their default app, launch apps by name, or open URLs in the default browser.",
            "parameters": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "File path, app name, or URL to open. For apps use the name (e.g. 'Safari', 'Xcode'). For URLs include the scheme (e.g. 'https://example.com')."],
                    "application": ["type": "string", "description": "Optional: specific application to open the target with (e.g. 'TextEdit' to open a file in TextEdit)"],
                    "background": ["type": "boolean", "description": "Open in background without bringing to front (default: false)"]
                ] as [String: Any],
                "required": ["target"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let screenshotToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "take_screenshot",
            "description": "Take a screenshot of the macOS screen. Returns the file path to the saved screenshot image. Requires Screen Recording permission in System Settings > Privacy & Security.",
            "parameters": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["fullscreen", "window", "region"], "description": "Screenshot mode: 'fullscreen' captures entire screen, 'window' captures the frontmost window, 'region' captures a specific rectangle (default: fullscreen)"],
                    "region": ["type": "object", "description": "Required for 'region' mode: {x, y, width, height} in screen coordinates",
                        "properties": [
                            "x": ["type": "integer"],
                            "y": ["type": "integer"],
                            "width": ["type": "integer"],
                            "height": ["type": "integer"]
                        ] as [String: Any]
                    ],
                    "filename": ["type": "string", "description": "Custom filename (saved to ~/Desktop/ by default). If not specified, uses 'screenshot-{timestamp}.png'"]
                ] as [String: Any],
                "required": []
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let mouseToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "mouse_control",
            "description": "Control the mouse cursor on macOS. Move, click, double-click, right-click, or drag. Uses cliclick. Requires Accessibility permission in System Settings > Privacy & Security.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["move", "click", "doubleclick", "rightclick", "drag", "tripleclick"], "description": "Mouse action to perform"],
                    "x": ["type": "integer", "description": "X coordinate (pixels from left edge of screen)"],
                    "y": ["type": "integer", "description": "Y coordinate (pixels from top edge of screen)"],
                    "end_x": ["type": "integer", "description": "End X coordinate (for drag action only)"],
                    "end_y": ["type": "integer", "description": "End Y coordinate (for drag action only)"]
                ] as [String: Any],
                "required": ["action", "x", "y"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let keyboardToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "keyboard_control",
            "description": "Control the keyboard on macOS. Type text or send key combinations (shortcuts). Uses cliclick. Requires Accessibility permission in System Settings > Privacy & Security.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["type", "keystroke"], "description": "'type' to type text character by character, 'keystroke' to press a key combination (e.g. cmd+c, cmd+shift+s, return, tab)"],
                    "text": ["type": "string", "description": "For 'type': the text to type. For 'keystroke': the key combo using cliclick syntax — modifiers: cmd, ctrl, alt, shift, fn. Keys: return, tab, space, delete, escape, up, down, left, right, f1-f12. Examples: 'cmd+c', 'cmd+shift+s', 'return', 'tab'"]
                ] as [String: Any],
                "required": ["action", "text"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let windowToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "window_management",
            "description": "Manage windows on macOS via AppleScript. List open windows, focus/activate apps, resize or move windows, minimize or fullscreen.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list", "focus", "resize", "move", "minimize", "fullscreen", "close"], "description": "Window action to perform"],
                    "app": ["type": "string", "description": "Application name (required for focus, resize, move, minimize, fullscreen, close)"],
                    "x": ["type": "integer", "description": "X position (for move action)"],
                    "y": ["type": "integer", "description": "Y position (for move action)"],
                    "width": ["type": "integer", "description": "Window width (for resize action)"],
                    "height": ["type": "integer", "description": "Window height (for resize action)"]
                ] as [String: Any],
                "required": ["action"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let screenInfoToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "get_screen_info",
            "description": "Get information about the current macOS screen: resolution, visible windows, frontmost application, mouse position.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // MARK: - Tool Execution

    /// Open a file, app, or URL
    func openTarget(_ target: String, application: String? = nil, background: Bool = false) async -> String {
        var args = [String]()
        if background { args.append("-g") }
        if let app = application, !app.isEmpty {
            args.append("-a")
            args.append(app)
        }
        // Detect if target is an app name (no path separator, no scheme)
        let isAppName = !target.contains("/") && !target.contains("://") && !target.contains(".")
        if isAppName && application == nil {
            args.append("-a")
            args.append(target)
        } else {
            args.append(target)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                return "✅ Opened: \(target)" + (application != nil ? " (with \(application!))" : "")
            } else {
                return "❌ Failed to open '\(target)': \(err)"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    /// Take a screenshot
    func takeScreenshot(mode: String = "fullscreen", region: [String: Int]? = nil, filename: String? = nil) async -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let name = filename ?? "screenshot-\(timestamp).png"
        let path = NSHomeDirectory() + "/Desktop/" + name

        var args = [String]()
        args.append("-x") // No sound

        switch mode {
        case "window":
            args.append("-w") // Interactive window selection
        case "region":
            if let r = region, let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] {
                args.append("-R")
                args.append("\(x),\(y),\(w),\(h)")
            }
        default:
            break // fullscreen is default
        }
        args.append(path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let size = attrs?[.size] as? Int ?? 0
                return "✅ Screenshot saved: \(path) (\(size / 1024)KB)"
            } else {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return "❌ Screenshot failed: \(err.isEmpty ? "Check Screen Recording permission in System Settings > Privacy & Security" : err)"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    /// Control the mouse via cliclick
    func mouseControl(action: String, x: Int, y: Int, endX: Int? = nil, endY: Int? = nil) async -> String {
        // Find cliclick
        let cliclick = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cliclick") ? "/opt/homebrew/bin/cliclick" : "/usr/local/bin/cliclick"
        guard FileManager.default.fileExists(atPath: cliclick) else {
            return "❌ cliclick not found. Install with: brew install cliclick"
        }

        var cliArgs = [String]()
        switch action {
        case "move":
            cliArgs.append("m:\(x),\(y)")
        case "click":
            cliArgs.append("c:\(x),\(y)")
        case "doubleclick":
            cliArgs.append("dc:\(x),\(y)")
        case "tripleclick":
            cliArgs.append("tc:\(x),\(y)")
        case "rightclick":
            cliArgs.append("rc:\(x),\(y)")
        case "drag":
            guard let ex = endX, let ey = endY else {
                return "❌ Drag requires end_x and end_y"
            }
            cliArgs.append("dd:\(x),\(y)")
            cliArgs.append("du:\(ex),\(ey)")
        default:
            return "❌ Unknown mouse action: \(action). Use: move, click, doubleclick, rightclick, tripleclick, drag"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliclick)
        process.arguments = cliArgs
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "✅ Mouse \(action) at (\(x), \(y))" + (action == "drag" ? " → (\(endX!), \(endY!))" : "")
            } else {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return "❌ Mouse control failed: \(err.isEmpty ? "Check Accessibility permission" : err)"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    /// Control the keyboard via cliclick
    func keyboardControl(action: String, text: String) async -> String {
        let cliclick = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cliclick") ? "/opt/homebrew/bin/cliclick" : "/usr/local/bin/cliclick"
        guard FileManager.default.fileExists(atPath: cliclick) else {
            return "❌ cliclick not found. Install with: brew install cliclick"
        }

        var cliArgs = [String]()
        switch action {
        case "type":
            cliArgs.append("t:\(text)")
        case "keystroke":
            // Map friendly key names to cliclick key: syntax
            // cliclick uses kp: for key press (keystroke with modifiers)
            let mapped = mapKeystroke(text)
            cliArgs.append(contentsOf: mapped)
        default:
            return "❌ Unknown keyboard action: \(action). Use: type, keystroke"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliclick)
        process.arguments = cliArgs
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "✅ Keyboard \(action): \(text)"
            } else {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return "❌ Keyboard control failed: \(err.isEmpty ? "Check Accessibility permission" : err)"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }

    /// Map human-readable keystrokes to cliclick format
    private func mapKeystroke(_ input: String) -> [String] {
        // cliclick uses kp: for key press with modifiers
        // Format: kp:key-name (with optional modifier prefix via kd:/ku:)
        let parts = input.lowercased().split(separator: "+").map(String.init)
        var modifiers = [String]()
        var key = ""

        for part in parts {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": modifiers.append("cmd")
            case "ctrl", "control": modifiers.append("ctrl")
            case "alt", "option": modifiers.append("alt")
            case "shift": modifiers.append("shift")
            case "fn": modifiers.append("fn")
            default: key = part.trimmingCharacters(in: .whitespaces)
            }
        }

        // Map key names to cliclick key codes
        let keyMap: [String: String] = [
            "return": "return", "enter": "return",
            "tab": "tab", "space": "space",
            "delete": "delete", "backspace": "delete",
            "escape": "escape", "esc": "escape",
            "up": "arrow-up", "down": "arrow-down",
            "left": "arrow-left", "right": "arrow-right",
            "home": "home", "end": "end",
            "pageup": "page-up", "pagedown": "page-down",
            "f1": "f1", "f2": "f2", "f3": "f3", "f4": "f4",
            "f5": "f5", "f6": "f6", "f7": "f7", "f8": "f8",
            "f9": "f9", "f10": "f10", "f11": "f11", "f12": "f12",
        ]
        let mappedKey = keyMap[key] ?? key

        // Build cliclick command sequence
        var commands = [String]()
        // Press modifiers down
        for mod in modifiers { commands.append("kd:\(mod)") }
        // Press key
        commands.append("kp:\(mappedKey)")
        // Release modifiers
        for mod in modifiers.reversed() { commands.append("ku:\(mod)") }
        return commands
    }

    /// Manage windows via AppleScript
    func windowManagement(action: String, app: String? = nil, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil) async -> String {
        switch action {
        case "list":
            return await runAppleScript("""
                set windowList to ""
                tell application "System Events"
                    set allProcesses to every process whose visible is true
                    repeat with proc in allProcesses
                        set appName to name of proc
                        try
                            set wins to every window of proc
                            repeat with win in wins
                                set winName to name of win
                                set winPos to position of win
                                set winSize to size of win
                                set windowList to windowList & appName & " | " & winName & " | pos:" & (item 1 of winPos) & "," & (item 2 of winPos) & " | size:" & (item 1 of winSize) & "x" & (item 2 of winSize) & linefeed
                            end repeat
                        end try
                    end repeat
                end tell
                return windowList
                """)
        case "focus":
            guard let app = app, !app.isEmpty else { return "❌ 'app' is required for focus" }
            return await runAppleScript("""
                tell application "\(app)" to activate
                return "✅ Focused: \(app)"
                """)
        case "resize":
            guard let app = app, let w = width, let h = height else { return "❌ 'app', 'width', 'height' required for resize" }
            return await runAppleScript("""
                tell application "System Events"
                    tell process "\(app)"
                        set size of front window to {\(w), \(h)}
                    end tell
                end tell
                return "✅ Resized \(app) to \(w)x\(h)"
                """)
        case "move":
            guard let app = app, let px = x, let py = y else { return "❌ 'app', 'x', 'y' required for move" }
            return await runAppleScript("""
                tell application "System Events"
                    tell process "\(app)"
                        set position of front window to {\(px), \(py)}
                    end tell
                end tell
                return "✅ Moved \(app) to (\(px), \(py))"
                """)
        case "minimize":
            guard let app = app else { return "❌ 'app' required for minimize" }
            return await runAppleScript("""
                tell application "System Events"
                    tell process "\(app)"
                        try
                            click button 3 of front window
                        end try
                    end tell
                end tell
                return "✅ Minimized \(app)"
                """)
        case "fullscreen":
            guard let app = app else { return "❌ 'app' required for fullscreen" }
            return await runAppleScript("""
                tell application "System Events"
                    tell process "\(app)"
                        try
                            set value of attribute "AXFullScreen" of front window to true
                        end try
                    end tell
                end tell
                return "✅ Fullscreen: \(app)"
                """)
        case "close":
            guard let app = app else { return "❌ 'app' required for close" }
            return await runAppleScript("""
                tell application "\(app)"
                    try
                        close front window
                    end try
                end tell
                return "✅ Closed front window of \(app)"
                """)
        default:
            return "❌ Unknown window action: \(action). Use: list, focus, resize, move, minimize, fullscreen, close"
        }
    }

    /// Get screen information
    func getScreenInfo() async -> String {
        // Get screen resolution, frontmost app, mouse position
        let screenInfo = await runAppleScript("""
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            return frontApp
            """)

        // Get mouse position via cliclick
        let cliclick = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cliclick") ? "/opt/homebrew/bin/cliclick" : "/usr/local/bin/cliclick"
        var mousePos = "unknown"
        if FileManager.default.fileExists(atPath: cliclick) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliclick)
            process.arguments = ["p"]
            let stdout = Pipe()
            process.standardOutput = stdout
            try? process.run()
            process.waitUntilExit()
            mousePos = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        }

        // Get screen resolution via system_profiler (fast JSON query)
        let resProcess = Process()
        resProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        resProcess.arguments = ["SPDisplaysDataType", "-json"]
        let resStdout = Pipe()
        resProcess.standardOutput = resStdout
        try? resProcess.run()
        resProcess.waitUntilExit()
        let resData = resStdout.fileHandleForReading.readDataToEndOfFile()
        var resolution = "unknown"
        if let json = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
           let displays = json["SPDisplaysDataType"] as? [[String: Any]],
           let gpu = displays.first,
           let ndrvs = gpu["spdisplays_ndrvs"] as? [[String: Any]],
           let display = ndrvs.first,
           let res = display["_spdisplays_resolution"] as? String {
            resolution = res
        }

        // Get visible window list
        let windowList = await windowManagement(action: "list")

        return """
            📺 Screen Info:
            • Resolution: \(resolution)
            • Frontmost App: \(screenInfo)
            • Mouse Position: \(mousePos)
            • Visible Windows:
            \(windowList)
            """
    }

    /// Execute AppleScript helper
    private func runAppleScript(_ script: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return out.isEmpty ? "✅ Done" : out
            } else {
                return "❌ AppleScript error: \(err.isEmpty ? out : err)"
            }
        } catch {
            return "❌ Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - System Tools Engine (macOS)
// New tools: clipboard, process management, system monitor, volume, Finder, Spotlight,
// notifications, network, browser, AppleScript, screen recording

actor SystemToolsEngine {
    static let shared = SystemToolsEngine()

    // MARK: - Tool Definitions

    static let clipboardReadDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "clipboard_read",
            "description": "Read the current contents of the system clipboard (text only).",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let clipboardWriteDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "clipboard_write",
            "description": "Write text to the system clipboard.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Text to copy to clipboard"]
                ] as [String: Any],
                "required": ["text"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let processListDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "process_list",
            "description": "List running processes with CPU and memory usage. Returns top processes sorted by CPU usage.",
            "parameters": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max processes to return (default: 20)"],
                    "filter": ["type": "string", "description": "Filter by process name (case-insensitive substring match)"]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let processKillDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "process_kill",
            "description": "Terminate a running process by PID. Cannot kill system-critical processes (PID 0, 1) or the gateway itself.",
            "parameters": [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "Process ID to terminate"],
                    "signal": ["type": "string", "enum": ["TERM", "KILL", "HUP"], "description": "Signal to send (default: TERM)"]
                ] as [String: Any],
                "required": ["pid"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let systemMonitorDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "system_monitor",
            "description": "Get system resource stats: CPU cores, memory (total/used/free), disk space, uptime, and load average.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let volumeControlDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "volume_control",
            "description": "Get or set the system audio volume. Volume range: 0-100.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["get", "set", "mute", "unmute"], "description": "Action to perform (default: get)"],
                    "level": ["type": "integer", "description": "Volume level 0-100 (required for 'set' action)"]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let finderRevealDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "finder_reveal",
            "description": "Reveal a file or folder in Finder (opens Finder and selects the item).",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to reveal"]
                ] as [String: Any],
                "required": ["path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let spotlightSearchDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "spotlight_search",
            "description": "Search for files using macOS Spotlight (mdfind). Fast indexed search across the entire filesystem.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search query (Spotlight query syntax, e.g. 'kind:pdf budget 2026' or 'kMDItemFSName == *.swift')"],
                    "directory": ["type": "string", "description": "Limit search to a directory (optional)"],
                    "limit": ["type": "integer", "description": "Max results (default: 20)"]
                ] as [String: Any],
                "required": ["query"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let sendNotificationDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "send_notification",
            "description": "Send a macOS system notification (banner/alert).",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Notification title"],
                    "message": ["type": "string", "description": "Notification body text"],
                    "subtitle": ["type": "string", "description": "Optional subtitle"],
                    "sound": ["type": "boolean", "description": "Play notification sound (default: true)"]
                ] as [String: Any],
                "required": ["title", "message"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let networkStatusDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "network_status",
            "description": "Check current network connectivity status: WiFi, Ethernet, interface, IP addresses.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let browserOpenDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_open",
            "description": "Open a URL in the default web browser or a specific browser app.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "URL to open"],
                    "browser": ["type": "string", "description": "Browser app name (e.g. 'Safari', 'Google Chrome'). Uses default browser if omitted."]
                ] as [String: Any],
                "required": ["url"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let applescriptRunDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "applescript_run",
            "description": "Execute an AppleScript. Powerful macOS automation — can control apps, UI elements, system settings. Use responsibly.",
            "parameters": [
                "type": "object",
                "properties": [
                    "script": ["type": "string", "description": "AppleScript code to execute"]
                ] as [String: Any],
                "required": ["script"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let screenRecordDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "screen_record",
            "description": "Record the screen for a specified duration. Saves to a file and returns the path.",
            "parameters": [
                "type": "object",
                "properties": [
                    "duration": ["type": "integer", "description": "Recording duration in seconds (default: 5, max: 60)"],
                    "filename": ["type": "string", "description": "Output filename (default: auto-generated)"]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]

    // MARK: - Execution Handlers

    func clipboardRead() -> String {
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string) {
            return "Clipboard contents:\n\(text)"
        }
        return "Clipboard is empty or contains non-text data."
    }

    func clipboardWrite(text: String) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return "✓ Copied \(text.count) characters to clipboard."
    }

    func processList(limit: Int = 20, filter: String? = nil) async -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,pcpu,pmem,comm", "-r"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return "Failed to read process list" }
            var lines = output.components(separatedBy: "\n")
            let header = lines.removeFirst()
            if let filter = filter, !filter.isEmpty {
                lines = lines.filter { $0.lowercased().contains(filter.lowercased()) }
            }
            let limited = Array(lines.prefix(limit)).filter { !$0.isEmpty }
            return "\(header)\n\(limited.joined(separator: "\n"))\n(\(limited.count) processes shown)"
        } catch {
            return "❌ Failed to list processes: \(error.localizedDescription)"
        }
    }

    func processKill(pid: Int, signal: String = "TERM") -> String {
        // Safety: block critical PIDs
        let myPID = ProcessInfo.processInfo.processIdentifier
        if pid <= 1 {
            return "❌ Cannot kill system-critical process (PID \(pid))"
        }
        if pid == Int(myPID) {
            return "❌ Cannot kill the gateway process itself"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/kill")
        let sig: String
        switch signal.uppercased() {
        case "KILL", "9": sig = "-9"
        case "HUP", "1": sig = "-1"
        default: sig = "-15" // TERM
        }
        proc.arguments = [sig, String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return "✓ Sent \(signal) to PID \(pid)"
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? "Unknown error"
                return "❌ Failed to kill PID \(pid): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            return "❌ Failed to kill PID \(pid): \(error.localizedDescription)"
        }
    }

    func systemMonitor() -> String {
        let info = ProcessInfo.processInfo
        let totalMem = info.physicalMemory
        let totalMemGB = Double(totalMem) / (1024 * 1024 * 1024)
        let cores = info.processorCount
        let activeCores = info.activeProcessorCount
        let uptime = info.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let mins = (Int(uptime) % 3600) / 60

        var disk = "Unknown"
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            let freeGB = Double(freeBytes) / (1024 * 1024 * 1024)
            let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)
            let usedGB = totalGB - freeGB
            disk = String(format: "%.1f GB used / %.1f GB total (%.1f GB free)", usedGB, totalGB, freeGB)
        }

        // Get vm_stat for memory pressure
        var memDetail = ""
        let vmProc = Process()
        vmProc.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let vmPipe = Pipe()
        vmProc.standardOutput = vmPipe
        vmProc.standardError = Pipe()
        if let _ = try? vmProc.run() {
            vmProc.waitUntilExit()
            let data = vmPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse pages free/active/inactive/wired
                let pageSize: Double = 16384 // Apple Silicon default
                let lines = output.components(separatedBy: "\n")
                var values: [String: Double] = [:]
                for line in lines {
                    let parts = line.components(separatedBy: ":")
                    if parts.count == 2 {
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        let val = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                        if let pages = Double(val) {
                            values[key] = pages * pageSize / (1024 * 1024 * 1024) // to GB
                        }
                    }
                }
                let free = values["Pages free"] ?? 0
                let active = values["Pages active"] ?? 0
                let inactive = values["Pages inactive"] ?? 0
                let wired = values["Pages wired down"] ?? 0
                memDetail = String(format: "Memory: %.1fGB free, %.1fGB active, %.1fGB inactive, %.1fGB wired", free, active, inactive, wired)
            }
        }

        return """
        System Monitor:
        CPU: \(cores) cores (\(activeCores) active)
        RAM: \(String(format: "%.1f", totalMemGB)) GB total
        \(memDetail)
        Disk: \(disk)
        Uptime: \(days)d \(hours)h \(mins)m
        OS: \(info.operatingSystemVersionString)
        """
    }

    func volumeControl(action: String = "get", level: Int? = nil) -> String {
        switch action {
        case "set":
            guard let level = level else { return "❌ Volume level required for 'set' action" }
            let clamped = max(0, min(100, level))
            let script = "set volume output volume \(clamped)"
            return runOsascript(script) ?? "✓ Volume set to \(clamped)%"
        case "mute":
            return runOsascript("set volume with output muted") ?? "✓ Muted"
        case "unmute":
            return runOsascript("set volume without output muted") ?? "✓ Unmuted"
        default: // "get"
            if let output = runOsascriptWithOutput("output volume of (get volume settings) & \",\" & output muted of (get volume settings)") {
                let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
                if parts.count >= 2 {
                    return "Volume: \(parts[0])%, Muted: \(parts[1].trimmingCharacters(in: .whitespaces))"
                }
                return "Volume info: \(output)"
            }
            return "❌ Could not read volume"
        }
    }

    func finderReveal(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return "❌ File not found: \(path)"
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "✓ Revealed in Finder: \(path)"
    }

    func spotlightSearch(query: String, directory: String? = nil, limit: Int = 20) async -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var args = [query]
        if let directory = directory {
            args = ["-onlyin", directory] + args
        }
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return "Failed to read search results" }
            let results = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            let limited = Array(results.prefix(limit))
            if limited.isEmpty {
                return "No files found matching: \(query)"
            }
            return "Found \(results.count) file(s):\n\(limited.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))\(results.count > limit ? "\n... and \(results.count - limit) more" : "")"
        } catch {
            return "❌ Spotlight search failed: \(error.localizedDescription)"
        }
    }

    func sendNotification(title: String, message: String, subtitle: String? = nil, sound: Bool = true) -> String {
        var script = "display notification \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
        if let subtitle = subtitle {
            script += " subtitle \"\(subtitle.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        if sound {
            script += " sound name \"Submarine\""
        }
        return runOsascript(script) ?? "✓ Notification sent: \(title)"
    }

    func networkStatus() -> String {
        var lines: [String] = ["Network Status:"]

        // Get active interfaces
        let ifProc = Process()
        ifProc.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        ifProc.arguments = ["-l"]
        let ifPipe = Pipe()
        ifProc.standardOutput = ifPipe
        ifProc.standardError = Pipe()
        if let _ = try? ifProc.run() {
            ifProc.waitUntilExit()
            let data = ifPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                lines.append("Interfaces: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // Get IP addresses
        let ipProc = Process()
        ipProc.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let ipPipe = Pipe()
        ipProc.standardOutput = ipPipe
        ipProc.standardError = Pipe()
        if let _ = try? ipProc.run() {
            ipProc.waitUntilExit()
            let data = ipPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let ipLines = output.components(separatedBy: "\n")
                var currentIface = ""
                for line in ipLines {
                    if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                        currentIface = line.components(separatedBy: ":").first ?? ""
                    }
                    if line.contains("inet ") && !line.contains("127.0.0.1") {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                        if parts.count >= 2 {
                            lines.append("  \(currentIface): \(parts[1])")
                        }
                    }
                }
            }
        }

        // WiFi SSID
        let wifiProc = Process()
        wifiProc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        wifiProc.arguments = ["-getairportnetwork", "en0"]
        let wifiPipe = Pipe()
        wifiProc.standardOutput = wifiPipe
        wifiProc.standardError = Pipe()
        if let _ = try? wifiProc.run() {
            wifiProc.waitUntilExit()
            let data = wifiPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                lines.append("WiFi: \(output)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func browserOpen(url: String, browser: String? = nil) -> String {
        if let browser = browser {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", browser, url]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0 ? "✓ Opened \(url) in \(browser)" : "❌ Could not open \(browser)"
            } catch {
                return "❌ Failed: \(error.localizedDescription)"
            }
        } else {
            guard let nsURL = URL(string: url) else { return "❌ Invalid URL: \(url)" }
            NSWorkspace.shared.open(nsURL)
            return "✓ Opened \(url) in default browser"
        }
    }

    func applescriptRun(script: String) -> String {
        // Safety: block dangerous patterns
        let dangerous = ["do shell script \"rm ", "do shell script \"sudo", "do shell script \"mkfs",
                         "delete every", "empty trash", "keystroke \"\" using {command down, option down"]
        for pattern in dangerous {
            if script.lowercased().contains(pattern.lowercased()) {
                return "❌ Blocked: Script contains potentially dangerous operation"
            }
        }
        if let output = runOsascriptWithOutput(script) {
            return "AppleScript result:\n\(output)"
        }
        return "❌ AppleScript execution failed"
    }

    func screenRecord(duration: Int = 5, filename: String? = nil) async -> String {
        let dur = max(1, min(duration, 60))
        let fname = filename ?? "screen_recording_\(Int(Date().timeIntervalSince1970)).mov"
        let outputPath = NSTemporaryDirectory() + fname
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-V", String(dur), outputPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: outputPath) {
                return "✓ Screen recorded for \(dur)s → \(outputPath)"
            } else {
                return "❌ Recording failed — file not created (Screen Recording permission may be needed)"
            }
        } catch {
            return "❌ Screen recording failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func runOsascript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: errData, encoding: .utf8) ?? "Unknown error"
                return "❌ AppleScript error: \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil // success, no output needed
        } catch {
            return "❌ Failed to run osascript: \(error.localizedDescription)"
        }
    }

    private func runOsascriptWithOutput(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                return nil
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
#endif
