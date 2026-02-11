// ORB Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
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

    /// Built-in tools that the gateway can execute server-side
    static let builtInToolNames: Set<String> = ["web_search", "web_fetch", "generate_image"]

    /// Check if a response contains tool calls for built-in tools
    func hasBuiltInToolCalls(_ responseBody: [String: Any]) -> Bool {
        guard let choices = responseBody["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else { return false }

        return toolCalls.contains { call in
            let name = (call["function"] as? [String: Any])?["name"] as? String ?? ""
            return Self.builtInToolNames.contains(name)
        }
    }

    /// Execute built-in tool calls and return results
    func executeBuiltInTools(_ toolCalls: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []

        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }

            guard Self.builtInToolNames.contains(name) else { continue }

            let argsStr = function["arguments"] as? String ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

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
            default:
                content = "Unknown tool: \(name)"
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
        let boundary = "ORBBase-\(UUID().uuidString)"
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
    /// Tool definitions for system access (filtered by crew level)
    static func toolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        if level.rawValue >= AccessLevel.readFiles.rawValue {
            tools.append(SystemAccessEngine.readFileToolDefinition)
            tools.append(SystemAccessEngine.listDirectoryToolDefinition)
        }
        if level.rawValue >= AccessLevel.writeFiles.rawValue {
            tools.append(SystemAccessEngine.writeFileToolDefinition)
        }
        if level.rawValue >= AccessLevel.execute.rawValue {
            tools.append(SystemAccessEngine.runCommandToolDefinition)
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

            // Handle original built-in tools
            if Self.builtInToolNames.contains(name) {
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
        "ORBBaseApp.swift",
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
        "orion": ["~/Documents/orb master", "~/Documents/projects", "~/.orb-backup"],
        "mira": ["~/Documents/orb master/orb app", "~/Documents/orb master/website", "~/Downloads"],
        "ada": ["~/Documents/orb master", "~/Library/Application Support/ORBBase", "~/.orb-backup"]
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
        let backupDir = NSHomeDirectory() + "/.orb-backup"
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
