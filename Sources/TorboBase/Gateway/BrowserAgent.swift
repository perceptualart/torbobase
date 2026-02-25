// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Browser Agent
// CDP-powered autonomous web browsing with vision LLM guidance.
// Screenshots the page, sends to LLM, executes actions, loops.
// Tool: browser_agent

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor BrowserAgent {
    static let shared = BrowserAgent()

    /// Max steps per session
    private let maxSteps = 50
    /// Default step limit
    private let defaultSteps = 20
    /// Session timeout: 5 minutes
    private let sessionTimeout: TimeInterval = 300

    // MARK: - Execute

    /// Send an autonomous browser agent to accomplish a goal on a website.
    func execute(startURL: String, goal: String, maxStepsOverride: Int? = nil, apiKeys: [String: String] = [:]) async -> String {
        // Validate URL
        if let ssrfError = AccessControl.validateURLForSSRF(startURL) {
            return "Blocked: \(ssrfError)"
        }

        let stepLimit = min(maxStepsOverride ?? defaultSteps, maxSteps)
        let currentURL = startURL
        var actionLog: [String] = []
        var screenshots: [FileVault.VaultEntry] = []

        await EventBus.shared.publish("browser_agent.started",
            payload: ["url": startURL, "goal": goal],
            source: "BrowserAgent")

        // Navigate to starting URL
        let navResult = await BrowserAutomation.shared.execute(action: .navigate, params: ["url": startURL])
        if navResult.toolResponse.hasPrefix("Error") {
            return "Error: Failed to navigate to \(startURL): \(navResult.toolResponse)"
        }

        for step in 0..<stepLimit {
            // Take screenshot
            let screenshotResult = await BrowserAutomation.shared.execute(
                action: .screenshot,
                params: ["url": currentURL, "fullPage": false]
            )

            // Extract screenshot path from result
            let screenshotPath = extractFilePath(from: screenshotResult.toolResponse)

            // Read screenshot data for LLM vision
            let screenshotDescription: String
            if let path = screenshotPath, FileManager.default.fileExists(atPath: path) {
                // Store screenshot in FileVault for delivery
                if let entry = await FileVault.shared.store(sourceFilePath: path, originalName: "step_\(step).png", mimeType: "image/png") {
                    screenshots.append(entry)
                }

                // Get page extract for context (since we may not have vision)
                let extractResult = await BrowserAutomation.shared.execute(
                    action: .extract,
                    params: ["url": currentURL, "selector": "body"]
                )
                screenshotDescription = String(extractResult.toolResponse.prefix(4000))
            } else {
                // No screenshot — extract text content
                let extractResult = await BrowserAutomation.shared.execute(
                    action: .extract,
                    params: ["url": currentURL, "selector": "body"]
                )
                screenshotDescription = String(extractResult.toolResponse.prefix(4000))
            }

            // Ask LLM what to do next
            let actionHistory = actionLog.suffix(5).joined(separator: "\n")
            let systemPrompt = """
            You are a browser automation agent. You see a web page and must decide what action to take to accomplish the goal.

            Current URL: \(currentURL)
            Goal: \(goal)
            Step: \(step + 1)/\(stepLimit)

            Previous actions:
            \(actionHistory.isEmpty ? "(none)" : actionHistory)

            Available actions:
            - click(selector) — click an element (use CSS selectors)
            - type(selector, text) — type text into an input field
            - scroll(direction) — scroll up or down
            - wait — wait for page to load
            - extract(selector) — extract text from an element
            - done(summary) — task is complete, provide summary of what was accomplished

            Respond with EXACTLY ONE action in this format:
            ACTION: action_name
            SELECTOR: css_selector (if applicable)
            VALUE: text_or_direction (if applicable)
            REASON: brief explanation
            """

            let response = await callLLM(system: systemPrompt, user: "Page content:\n\(screenshotDescription)", apiKeys: apiKeys)

            // Parse LLM response
            let action = parseLLMAction(response)

            guard let actionType = action["action"] else {
                actionLog.append("Step \(step + 1): Could not parse LLM action")
                continue
            }

            // Check for "done"
            if actionType == "done" {
                let summary = action["value"] ?? "Goal completed"
                actionLog.append("Step \(step + 1): DONE — \(summary)")
                break
            }

            // Execute the action
            let selector = action["selector"] ?? ""
            let value = action["value"] ?? ""

            let browserAction: BrowserAction
            var params: [String: Any] = ["url": currentURL, "selector": selector]

            switch actionType {
            case "click":
                browserAction = .click
            case "type":
                browserAction = .type
                params["text"] = value
            case "scroll":
                browserAction = .scroll
                params["direction"] = value
            case "wait":
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                actionLog.append("Step \(step + 1): Waited 2s")
                continue
            case "extract":
                let extractResult = await BrowserAutomation.shared.execute(action: .extract, params: params)
                actionLog.append("Step \(step + 1): Extracted from \(selector) — \(String(extractResult.toolResponse.prefix(200)))")
                continue
            default:
                actionLog.append("Step \(step + 1): Unknown action: \(actionType)")
                continue
            }

            let result = await BrowserAutomation.shared.execute(action: browserAction, params: params)
            let reason = action["reason"] ?? ""
            actionLog.append("Step \(step + 1): \(actionType)(\(selector)) — \(reason) — \(result.toolResponse.prefix(100))")

            // Small delay between actions
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Build result
        var result = "Browser Agent completed (\(actionLog.count) steps)\n"
        result += "Goal: \(goal)\n"
        result += "URL: \(currentURL)\n\n"
        result += "Action log:\n"
        for log in actionLog {
            result += "  \(log)\n"
        }

        // Add screenshot links
        if !screenshots.isEmpty {
            let baseURL = FileVault.resolveBaseURL(port: 8420)
            result += "\nScreenshots:\n"
            for (i, entry) in screenshots.enumerated() {
                let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
                result += "  Step \(i + 1): \(url)\n"
            }
        }

        await EventBus.shared.publish("browser_agent.completed",
            payload: ["url": currentURL, "steps": "\(actionLog.count)"],
            source: "BrowserAgent")

        return result
    }

    // MARK: - Helpers

    private func extractFilePath(from response: String) -> String? {
        // Look for file path patterns in screenshot response
        let lines = response.split(separator: "\n").map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(".png") || trimmed.hasSuffix(".jpg") {
                if trimmed.hasPrefix("/") { return trimmed }
                if trimmed.contains("/tmp/") || trimmed.contains("/var/") {
                    if let start = trimmed.range(of: "/") {
                        return String(trimmed[start.lowerBound...])
                    }
                }
            }
        }
        return nil
    }

    private func parseLLMAction(_ response: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = response.split(separator: "\n").map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("ACTION:") {
                result["action"] = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased()
            } else if trimmed.uppercased().hasPrefix("SELECTOR:") {
                result["selector"] = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("VALUE:") {
                result["value"] = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("REASON:") {
                result["reason"] = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    // MARK: - LLM

    private func callLLM(system: String, user: String, apiKeys: [String: String]) async -> String {
        let ollamaResult = await callOllama(system: system, user: user)
        if !ollamaResult.isEmpty { return ollamaResult }

        if let key = apiKeys["ANTHROPIC_API_KEY"] ?? KeychainManager.get("apikey.ANTHROPIC_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "anthropic", apiKey: key)
        }
        if let key = apiKeys["OPENAI_API_KEY"] ?? KeychainManager.get("apikey.OPENAI_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "openai", apiKey: key)
        }
        return "ACTION: done\nVALUE: No LLM available to guide browser agent"
    }

    private func callOllama(system: String, user: String) async -> String {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": "qwen2.5:7b", "system": system, "prompt": String(user.prefix(8000)), "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String { return response }
        } catch {}
        return ""
    }

    private func callCloud(system: String, user: String, provider: String, apiKey: String) async -> String {
        if provider == "anthropic" {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": "claude-sonnet-4-20250514", "max_tokens": 1024,
                "system": system, "messages": [["role": "user", "content": String(user.prefix(8000))]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String { return text }
            } catch {}
        } else {
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 60
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [["role": "system", "content": system], ["role": "user", "content": String(user.prefix(8000))]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let text = msg["content"] as? String { return text }
            } catch {}
        }
        return ""
    }

    // MARK: - Tool Definition

    static let browserAgentToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "browser_agent",
            "description": "Send an autonomous browser agent to accomplish a goal on any website. The agent navigates, clicks, types, fills forms, extracts data, and takes screenshots. It sees the page content and decides what actions to take. Max 50 steps, 5 minute timeout.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Starting URL to navigate to"],
                    "goal": ["type": "string", "description": "What the agent should accomplish on the website"],
                    "max_steps": ["type": "integer", "description": "Maximum number of actions (default: 20, max: 50)"]
                ] as [String: Any],
                "required": ["url", "goal"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
