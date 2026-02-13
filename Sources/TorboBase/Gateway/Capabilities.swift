// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Capabilities — Web Search, TTS, STT for the gateway
import Foundation

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
            print("[WebSearch] DuckDuckGo error: \(error)")
            return nil
        }
    }

    /// Parse DuckDuckGo HTML lite results
    private func parseDDGResults(html: String, maxResults: Int) -> String {
        var results: [(title: String, snippet: String, url: String)] = []

        // DDG lite uses <a class="result__a"> for titles and <a class="result__snippet"> for snippets
        // Also handles the simpler format with result__url
        let resultPattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>([^<]*(?:<[^>]*>[^<]*)*)</a>"#

        // Simpler approach: split by result blocks
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
    static let coreToolNames: Set<String> = ["web_search", "web_fetch", "generate_image", "search_documents", "create_workflow", "execute_code", "execute_code_docker", "browser_navigate", "browser_screenshot", "browser_extract", "browser_interact", "list_events", "create_event", "check_availability"]

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
                    content = await WebSearchEngine.shared.fetchPage(url: url)
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
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var config = SandboxConfig()
                    config.timeout = TimeInterval(timeout)
                    let execResult = await CodeSandbox.shared.execute(code: code, language: language, config: config)
                    content = execResult.toolResponse
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
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var dockerConfig = DockerConfig()
                    dockerConfig.timeout = TimeInterval(timeout)
                    if let memLimit = args["memory_limit"] as? String { dockerConfig.memoryLimit = memLimit }
                    if let allowNet = args["allow_network"] as? Bool, allowNet { dockerConfig.networkMode = "bridge" }
                    let execResult = await DockerSandbox.shared.execute(code: code, language: language, config: dockerConfig)
                    content = execResult.toolResponse
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
                print("[TTS] ElevenLabs error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return (data, "audio/mpeg")
        } catch {
            print("[TTS] ElevenLabs error: \(error)")
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
                print("[TTS] OpenAI TTS error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return (data, "audio/mpeg")
        } catch {
            print("[TTS] OpenAI TTS error: \(error)")
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

    private func openAIWhisper(audioData: Data, filename: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else { return nil }

        // Build multipart form data
        let boundary = "TorboBase-\(UUID().uuidString)"
        var body = Data()

        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                print("[STT] Whisper error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text
            }
            return nil
        } catch {
            print("[STT] Whisper error: \(error)")
            return nil
        }
    }
}

// MARK: - Image Generation (DALL-E)

actor ImageGenerator {
    static let shared = ImageGenerator()

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
    /// Tool definitions for all tools (filtered by crew access level)
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

    static func toolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        // Built-in tools: available to all agents (even chatOnly)
        tools.append(WebSearchEngine.toolDefinition)
        tools.append(WebSearchEngine.webFetchToolDefinition)
        tools.append(createWorkflowToolDefinition)
        // Browser automation: available at readFiles and above
        if level.rawValue >= AccessLevel.readFiles.rawValue {
            tools.append(browserNavigateToolDefinition)
            tools.append(browserExtractToolDefinition)
            tools.append(browserScreenshotToolDefinition)
        }
        // Document search & calendar: available at readFiles and above
        if level.rawValue >= AccessLevel.readFiles.rawValue {
            tools.append(searchDocumentsToolDefinition)
            tools.append(listEventsToolDefinition)
            tools.append(checkAvailabilityToolDefinition)
        }
        // System access tools: gated by access level
        if level.rawValue >= AccessLevel.readFiles.rawValue {
            tools.append(SystemAccessEngine.readFileToolDefinition)
            tools.append(SystemAccessEngine.listDirectoryToolDefinition)
        }
        if level.rawValue >= AccessLevel.writeFiles.rawValue {
            tools.append(SystemAccessEngine.writeFileToolDefinition)
            tools.append(createEventToolDefinition)
            tools.append(browserInteractToolDefinition)  // Interaction requires write access
        }
        if level.rawValue >= AccessLevel.execute.rawValue {
            tools.append(SystemAccessEngine.runCommandToolDefinition)
            tools.append(executeCodeToolDefinition)
            tools.append(executeCodeDockerToolDefinition)
        }
        return tools
    }

    /// Tool definitions including MCP tools (async — queries MCPManager)
    static func toolDefinitionsWithMCP(for level: AccessLevel) async -> [[String: Any]] {
        var tools = toolDefinitions(for: level)
        // Append all MCP server tools (available at chatOnly and above)
        let mcpTools = await MCPManager.shared.toolDefinitions()
        if !mcpTools.isEmpty {
            tools.append(contentsOf: mcpTools)
        }
        return tools
    }

    /// Execute system access tools (called from the tool loop)
    func executeBuiltInTools(_ toolCalls: [[String: Any]], accessLevel: AccessLevel) async -> [[String: Any]] {
        let systemToolNames: Set<String> = ["read_file", "write_file", "list_directory", "run_command"]
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

            // Handle core built-in tools
            if Self.coreToolNames.contains(name) {
                var content = ""
                switch name {
                case "web_search":
                    let query = args["query"] as? String ?? ""
                    content = await WebSearchEngine.shared.search(query: query)
                case "web_fetch":
                    let url = args["url"] as? String ?? ""
                    content = await WebSearchEngine.shared.fetchPage(url: url)
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
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var cfg = SandboxConfig()
                    cfg.timeout = TimeInterval(timeout)
                    let execResult = await CodeSandbox.shared.execute(code: code, language: language, config: cfg)
                    content = execResult.toolResponse
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
                    let language = CodeSandbox.Language(rawValue: langStr) ?? .python
                    var dockerCfg = DockerConfig()
                    dockerCfg.timeout = TimeInterval(timeout)
                    if let memLimit = args["memory_limit"] as? String { dockerCfg.memoryLimit = memLimit }
                    if let allowNet = args["allow_network"] as? Bool, allowNet { dockerCfg.networkMode = "bridge" }
                    let execResult = await DockerSandbox.shared.execute(code: code, language: language, config: dockerCfg)
                    content = execResult.toolResponse
                default:
                    content = "Unknown tool: \(name)"
                }
                results.append(["role": "tool", "tool_call_id": id, "content": content])
                continue
            }

            // Handle system access tools
            if systemToolNames.contains(name) {
                let content: String
                switch name {
                case "read_file":
                    let path = args["path"] as? String ?? ""
                    let maxChars = args["max_chars"] as? Int ?? 50000
                    content = await SystemAccessEngine.shared.readFile(path: path, maxChars: maxChars)
                case "write_file":
                    let path = args["path"] as? String ?? ""
                    let fileContent = args["content"] as? String ?? ""
                    let append = args["append"] as? Bool ?? false
                    content = await SystemAccessEngine.shared.writeFile(path: path, content: fileContent, append: append)
                case "list_directory":
                    let path = args["path"] as? String ?? ""
                    let recursive = args["recursive"] as? Bool ?? false
                    content = await SystemAccessEngine.shared.listDirectory(path: path, recursive: recursive)
                case "run_command":
                    let command = args["command"] as? String ?? ""
                    let workDir = args["working_directory"] as? String
                    let timeout = args["timeout"] as? Int ?? 30
                    content = await SystemAccessEngine.shared.runCommand(command: command, workingDirectory: workDir, timeout: timeout)
                default:
                    content = "Unknown tool: \(name)"
                }
                print("[ToolLoop] Executed 1 built-in tool(s) for crew: unknown (level: \(accessLevel.name))")
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

    /// Files that NO crew member can modify via write_file
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

    static let crewDirectoryScopes: [String: [String]] = [
        "sid": [],
        "orion": ["~/Documents/torbo master", "~/Documents/projects", "~/.torbo-backup"],
        "mira": ["~/Documents/torbo master/torbo app", "~/Documents/torbo master/website", "~/Downloads"],
        "ada": ["~/Documents/torbo master", "~/Library/Application Support/TorboBase", "~/.torbo-backup"]
    ]

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

    static func classifyCommand(_ command: String) -> CommandThreat {
        let cmd = command.trimmingCharacters(in: .whitespaces).lowercased()
        if cmd.contains("sudo rm -rf /") || cmd.contains(":(){ :|:& };:") || cmd == "rm -rf /" { return .blocked }
        for p in destructivePatterns { if cmd.contains(p.lowercased()) { return .destructive } }
        for p in safePatterns { if cmd.hasPrefix(p.lowercased()) { return .safe } }
        return .moderate
    }

    static func isProtectedPath(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return protectedPaths.contains { expanded.hasPrefix($0) }
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
            print("[Safety] Backed up \(path) -> \(backupPath)")
            return backupPath
        } catch { return nil }
    }

    // MARK: - Execution

    func readFile(path: String, maxChars: Int = 50000) -> String {
        let p = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: p) else { return "Error: File not found at '\(path)'" }
        do {
            let content = try String(contentsOfFile: p, encoding: .utf8)
            return content.count > maxChars ? String(content.prefix(maxChars)) + "\n[truncated]" : content
        } catch { return "Error: \(error.localizedDescription)" }
    }

    func writeFile(path: String, content: String, append: Bool = false) -> String {
        let p = NSString(string: path).expandingTildeInPath
        if Self.isProtectedPath(p) { return "BLOCKED: protected system path" }
        if Self.isCoreFile(p) {
            print("[Safety] BLOCKED write to core file: \(path)")
            return "BLOCKED: \(URL(fileURLWithPath: p).lastPathComponent) is a core infrastructure file. Create a NEW file instead, or ask MM to modify it manually."
        }
        if FileManager.default.fileExists(atPath: p) { _ = backupFile(at: p) }
        let url = URL(fileURLWithPath: p)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, FileManager.default.fileExists(atPath: p) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(content.data(using: .utf8)!)
                handle.closeFile()
                return "Appended \(content.count) chars to \(path)"
            }
            try content.write(toFile: p, atomically: true, encoding: .utf8)
            return "Wrote \(content.count) chars to \(path)"
        } catch { return "Error: \(error.localizedDescription)" }
    }

    func listDirectory(path: String, recursive: Bool = false) -> String {
        let p = NSString(string: path).expandingTildeInPath
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

    func runCommand(command: String, workingDirectory: String? = nil, timeout: Int = 30) async -> String {
        let threat = Self.classifyCommand(command)
        switch threat {
        case .blocked: return "BLOCKED: Too dangerous."
        case .destructive: return "CONFIRMATION REQUIRED: \(command)"
        case .moderate: print("[Safety] Moderate command: \(command)")
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
