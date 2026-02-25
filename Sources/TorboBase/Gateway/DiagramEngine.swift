// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Diagram Engine
// LLM-generated SVG and diagram rendering via Mermaid, Graphviz, D2.
// Tools: generate_svg, create_diagram

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor DiagramEngine {
    static let shared = DiagramEngine()

    private let timeout: TimeInterval = 60

    // MARK: - Generate SVG

    /// LLM generates SVG code from a description, then validates and sanitizes it.
    func generateSVG(description: String, style: String = "minimal", apiKeys: [String: String] = [:]) async -> String {
        // Ask LLM to generate SVG
        let systemPrompt = """
        You are an expert SVG artist. Generate clean, valid SVG code for the user's description.
        Style: \(style). Output ONLY the SVG code — no explanation, no markdown fences.
        Use viewBox for responsive sizing. Keep it under 50KB.
        """

        let svgCode = await callLLM(system: systemPrompt, user: description, apiKeys: apiKeys)

        guard !svgCode.isEmpty else {
            return "Error: LLM did not generate SVG code"
        }

        // Extract SVG from response (strip markdown fences if present)
        var svg = svgCode
        if let start = svg.range(of: "<svg"), let end = svg.range(of: "</svg>") {
            svg = String(svg[start.lowerBound...end.upperBound])
        }

        guard svg.contains("<svg") else {
            return "Error: Generated content does not contain valid SVG"
        }

        // Sanitize — remove script tags, javascript: URLs, on* event handlers
        svg = sanitizeSVG(svg)

        // Save to temp file
        let svgPath = NSTemporaryDirectory() + "torbo_svg_\(UUID().uuidString).svg"
        do {
            try svg.write(toFile: svgPath, atomically: true, encoding: .utf8)
        } catch {
            return "Error: Failed to write SVG file: \(error)"
        }

        // Store in FileVault
        let name = "diagram_\(UUID().uuidString.prefix(8)).svg"
        guard let entry = await FileVault.shared.store(sourceFilePath: svgPath, originalName: name, mimeType: "image/svg+xml") else {
            return "Error: Failed to store SVG in FileVault"
        }

        try? FileManager.default.removeItem(atPath: svgPath)

        // Optionally render to PNG
        var result = ""
        let pngPath = NSTemporaryDirectory() + "torbo_svg_\(UUID().uuidString).png"
        let magickResult = await runProcess(executable: "magick", arguments: [svgPath, pngPath])
        if magickResult.exitCode == 0, FileManager.default.fileExists(atPath: pngPath) {
            if let pngEntry = await FileVault.shared.store(sourceFilePath: pngPath, originalName: name.replacingOccurrences(of: ".svg", with: ".png"), mimeType: "image/png") {
                let baseURL = FileVault.resolveBaseURL(port: 8420)
                let pngURL = await FileVault.shared.downloadURL(for: pngEntry, baseURL: baseURL)
                result += "PNG: \(pngURL)\n"
            }
            try? FileManager.default.removeItem(atPath: pngPath)
        }

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        result += "SVG: \(url)"
        return "SVG generated successfully.\n\(result)"
    }

    // MARK: - Create Diagram

    /// LLM generates diagram syntax (Mermaid/Graphviz/D2), then renders it.
    func createDiagram(description: String, diagramType: String = "auto", engine: String = "mermaid", apiKeys: [String: String] = [:]) async -> String {
        let resolvedEngine = engine.lowercased()

        // Ask LLM to generate diagram syntax
        let syntaxType: String
        let renderCommand: (String) -> (String, [String])
        let fileExt: String

        switch resolvedEngine {
        case "graphviz", "dot":
            syntaxType = "Graphviz DOT"
            fileExt = "dot"
            renderCommand = { input in ("dot", ["-Tsvg", input, "-o"]) }
        case "d2":
            syntaxType = "D2"
            fileExt = "d2"
            renderCommand = { input in ("d2", [input]) }
        default: // mermaid
            syntaxType = "Mermaid"
            fileExt = "mmd"
            renderCommand = { input in ("mmdc", ["-i", input, "-o"]) }
        }

        let systemPrompt = """
        You are a diagramming expert. Generate \(syntaxType) syntax for the user's description.
        Diagram type hint: \(diagramType). Output ONLY the diagram code — no explanation, no markdown fences.
        """

        let syntax = await callLLM(system: systemPrompt, user: description, apiKeys: apiKeys)

        guard !syntax.isEmpty else {
            return "Error: LLM did not generate diagram syntax"
        }

        // Write syntax to temp file
        let inputPath = NSTemporaryDirectory() + "torbo_diagram_\(UUID().uuidString).\(fileExt)"
        let outputPath = NSTemporaryDirectory() + "torbo_diagram_\(UUID().uuidString).svg"

        do {
            try syntax.write(toFile: inputPath, atomically: true, encoding: .utf8)
        } catch {
            return "Error: Failed to write diagram source: \(error)"
        }

        // Render
        let (exe, baseArgs) = renderCommand(inputPath)
        var args = baseArgs
        args.append(outputPath)

        let result = await runProcess(executable: exe, arguments: args)

        // Clean up input
        try? FileManager.default.removeItem(atPath: inputPath)

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: outputPath) else {
            return "Error: Diagram rendering failed — \(result.stderr.prefix(500))\n\nGenerated syntax:\n\(syntax.prefix(1000))"
        }

        let name = "diagram_\(UUID().uuidString.prefix(8)).svg"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: "image/svg+xml") else {
            return "Error: Failed to store diagram in FileVault"
        }

        try? FileManager.default.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Diagram created (\(syntaxType)).\nDownload: \(url)"
    }

    // MARK: - SVG Sanitization

    private func sanitizeSVG(_ svg: String) -> String {
        var cleaned = svg
        // Remove script tags
        let scriptPattern = try? NSRegularExpression(pattern: "<script[^>]*>.*?</script>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        cleaned = scriptPattern?.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "") ?? cleaned
        // Remove javascript: URLs
        cleaned = cleaned.replacingOccurrences(of: "javascript:", with: "", options: .caseInsensitive)
        // Remove on* event handlers
        let onPattern = try? NSRegularExpression(pattern: "\\bon\\w+\\s*=\\s*[\"'][^\"']*[\"']", options: .caseInsensitive)
        cleaned = onPattern?.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "") ?? cleaned
        return cleaned
    }

    // MARK: - LLM Call

    private func callLLM(system: String, user: String, apiKeys: [String: String]) async -> String {
        // Try Ollama first (local), then cloud providers
        let ollamaResult = await callOllama(system: system, user: user)
        if !ollamaResult.isEmpty { return ollamaResult }

        // Fallback to Anthropic/OpenAI
        if let key = apiKeys["ANTHROPIC_API_KEY"] ?? KeychainManager.get("apikey.ANTHROPIC_API_KEY"), !key.isEmpty {
            return await callAnthropic(system: system, user: user, apiKey: key)
        }
        if let key = apiKeys["OPENAI_API_KEY"] ?? KeychainManager.get("apikey.OPENAI_API_KEY"), !key.isEmpty {
            return await callOpenAI(system: system, user: user, apiKey: key)
        }

        return ""
    }

    private func callOllama(system: String, user: String) async -> String {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": "qwen2.5:7b", "system": system, "prompt": user, "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String {
                return response
            }
        } catch {}
        return ""
    }

    private func callAnthropic(system: String, user: String, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return text
            }
        } catch {}
        return ""
    }

    private func callOpenAI(system: String, user: String, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let text = msg["content"] as? String {
                return text
            }
        } catch {}
        return ""
    }

    // MARK: - Process

    private func runProcess(executable: String, arguments: [String]) async -> PhotoEditor.ProcessResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            let searchPaths = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
            let fullPath = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0 + executable) }).map { $0 + executable } ?? executable
            proc.executableURL = URL(fileURLWithPath: fullPath)
            proc.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            do { try proc.run() } catch {
                continuation.resume(returning: PhotoEditor.ProcessResult(stdout: "", stderr: "Failed to launch \(executable): \(error)", exitCode: -1))
                return
            }
            let timeoutTask = DispatchWorkItem { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: timeoutTask)
            proc.waitUntilExit()
            timeoutTask.cancel()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            continuation.resume(returning: PhotoEditor.ProcessResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
        }
    }

    // MARK: - Tool Definitions

    static let generateSVGToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "generate_svg",
            "description": "Generate an SVG illustration from a text description. The LLM creates SVG code which is validated and sanitized.",
            "parameters": [
                "type": "object",
                "properties": [
                    "description": ["type": "string", "description": "Description of what to draw"],
                    "style": ["type": "string", "enum": ["minimal", "detailed", "flat", "line-art", "isometric"], "description": "Visual style (default: minimal)"]
                ] as [String: Any],
                "required": ["description"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let createDiagramToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_diagram",
            "description": "Create a diagram from a text description. Supports flowcharts, sequence diagrams, class diagrams, state diagrams, ER diagrams, gantt charts, mind maps, architecture diagrams, network diagrams.",
            "parameters": [
                "type": "object",
                "properties": [
                    "description": ["type": "string", "description": "Description of the diagram to create"],
                    "type": ["type": "string", "description": "Diagram type hint: flowchart, sequence, class, state, er, gantt, mindmap, architecture, network (default: auto-detect)"],
                    "engine": ["type": "string", "enum": ["mermaid", "graphviz", "d2"], "description": "Rendering engine (default: mermaid)"]
                ] as [String: Any],
                "required": ["description"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
