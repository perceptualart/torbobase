// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Proactive Agent — Background Task Executor

actor ProactiveAgent {
    static let shared = ProactiveAgent()

    private var isRunning = false
    private var checkInterval: TimeInterval = 30  // Check for tasks every 30s

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Sync maxConcurrentTasks from AppState on startup
        Task {
            let maxTasks = AppState.shared.maxConcurrentTasks
            await ParallelExecutor.shared.updateMaxSlots(maxTasks)
        }

        TorboLog.info("Started — checking for tasks every \(Int(checkInterval))s", subsystem: "Agent")
        Task { await runLoop() }
    }

    func stop() {
        isRunning = false
        TorboLog.info("Stopped", subsystem: "Agent")
    }

    // MARK: - Main Loop

    private func runLoop() async {
        while isRunning {
            await checkAndExecuteTasks()
            try? await Task.sleep(nanoseconds: UInt64(checkInterval) * 1_000_000_000)
        }
    }

    private func checkAndExecuteTasks() async {
        let executor = ParallelExecutor.shared

        // Claim tasks while we have open slots
        while await executor.canAcceptTask {
            var claimed = false

            // Try to claim tasks for any registered agent, starting with SiD
            let agentIDs = await AgentConfigManager.shared.agentIDs
            for agentID in agentIDs {
                if let task = await TaskQueue.shared.claimTask(agentID: agentID) {
                    // Skip if this task is already executing
                    if await executor.isExecuting(taskID: task.id) { continue }

                    let agentName = await AgentConfigManager.shared.agent(agentID)?.name ?? agentID
                    TorboLog.info("\(agentName) starting task: '\(task.title)'", subsystem: "Agent")

                    // Publish agent started event
                    let taskID = task.id
                    let taskTitle = task.title
                    await EventBus.shared.publish("system.agent.started",
                        payload: ["agent_id": agentID, "agent_name": agentName, "task_id": taskID, "task_title": taskTitle],
                        source: "ProactiveAgent")

                    // Dispatch to executor — runs in its own Swift Task
                    await executor.execute(taskID: task.id) { [self] in
                        await self.executeTask(task, agentID: agentID)
                    }
                    claimed = true
                    break // Re-check canAcceptTask before claiming another
                }
            }

            if !claimed { break } // No tasks available to claim
        }
    }

    // MARK: - Task Execution

    private func executeTask(_ task: TaskQueue.AgentTask, agentID: String) async {
        let startTime = Date()

        // Build the prompt for the agent
        let prompt = buildTaskPrompt(task)

        // Get the model and API config for this agent
        let tier = classifyTaskTier(task.title, task.description)
        let modelConfig = agentModelConfig(agentID, tier: tier)
        TorboLog.info("\(agentID) task tier: \(tier) -> model: \(modelConfig.model)", subsystem: "Agent")

        // Execute through the LLM with tool access
        do {
            let result = try await executeWithTools(
                prompt: prompt,
                agentID: agentID,
                model: modelConfig.model,
                provider: modelConfig.provider,
                maxRounds: 30
            )

            let elapsed = Int(Date().timeIntervalSince(startTime))
            await TaskQueue.shared.completeTask(id: task.id, result: result)
            TorboLog.info("\(agentID) completed '\(task.title)' in \(elapsed)s", subsystem: "Agent")

            await EventBus.shared.publish("system.agent.completed",
                payload: ["agent_id": agentID, "task_id": task.id, "task_title": task.title, "elapsed": "\(elapsed)"],
                source: "ProactiveAgent")

        } catch {
            await TaskQueue.shared.failTask(id: task.id, error: error.localizedDescription)
            TorboLog.error("\(agentID) failed '\(task.title)': \(error.localizedDescription)", subsystem: "Agent")

            await EventBus.shared.publish("system.agent.error",
                payload: ["agent_id": agentID, "task_id": task.id, "task_title": task.title, "error": error.localizedDescription],
                source: "ProactiveAgent")
        }
        // Slot is auto-freed by ParallelExecutor when this closure returns
    }

    private func buildTaskPrompt(_ task: TaskQueue.AgentTask) -> String {
        var prompt = """
        You have been assigned a task by \(task.assignedBy).

        TASK: \(task.title)
        DESCRIPTION: \(task.description)
        PRIORITY: \(task.priority.rawValue) (0=low, 1=normal, 2=high, 3=critical)
        """

        // Inject workflow context from completed dependencies
        if let context = task.context, !context.isEmpty {
            prompt += "\n\n--- CONTEXT FROM PREVIOUS STEPS ---\n"
            prompt += "This task is part of a multi-step workflow. Here are the results from prior steps that you should build upon:\n\n"
            prompt += context
            prompt += "\n--- END CONTEXT ---"
        }

        if let wfID = task.workflowID, let step = task.stepIndex {
            prompt += "\n\nThis is step \(step + 1) of a workflow (ID: \(wfID.prefix(8))). Your output will be passed as context to subsequent steps."
        }

        prompt += "\n\nExecute this task using your available tools. Read files to understand the codebase, write files to make changes, run commands to build and test. When done, provide a clear summary of what you did and the results."
        prompt += "\n\nDo NOT ask questions — execute the task autonomously. If you encounter blockers, document them and report what you accomplished."

        return prompt
    }

    // MARK: - Model Config

    struct ModelConfig {
        let model: String
        let provider: String
        let apiKeyName: String
    }

    /// Task complexity tiers — determines local vs cloud routing
    enum TaskTier {
        case simple   // Read files, write docs, list dirs, simple edits
        case medium   // Write code, create specs, moderate reasoning
        case complex  // Multi-file debugging, architecture, hard problems
    }

    private func classifyTaskTier(_ title: String, _ description: String) -> TaskTier {
        let text = (title + " " + description).lowercased()
        let complexKeywords = ["debug", "fix", "diagnose", "architect", "redesign", "refactor", "complex", "critical", "deep dive", "analyze"]
        let simpleKeywords = ["list", "read", "create doc", "write doc", "summary", "spec", "document", "markdown", ".md"]
        
        for k in complexKeywords { if text.contains(k) { return .complex } }
        for k in simpleKeywords { if text.contains(k) { return .simple } }
        return .medium
    }

    private func agentModelConfig(_ agentID: String, tier: TaskTier = .complex) -> ModelConfig {
        // Local-first: use Ollama when possible to save money and reduce latency
        // Fall back to cloud for complex reasoning and tool-heavy tasks
        switch tier {
        case .simple:
            // Fast local model — free, instant
            return ModelConfig(model: "qwen2.5-coder:7b", provider: "ollama", apiKeyName: "")
        case .medium:
            // Larger local model — still free, good quality
            return ModelConfig(model: "qwen2.5:14b", provider: "ollama", apiKeyName: "")
        case .complex:
            // Cloud model — best reasoning, costs money
            return ModelConfig(model: "claude-sonnet-4-6", provider: "anthropic", apiKeyName: "anthropic_api_key")
        }
    }

    // MARK: - Tool Execution Loop

    private func executeWithTools(prompt: String, agentID: String, model: String, provider: String, maxRounds: Int) async throws -> String {
        // Route through Base itself — uses the same multi-provider gateway
        // This means ANY model works: Anthropic, OpenAI, Google, local Ollama
        let accessLevel = await MainActor.run {
            AppState.shared.accessLevel(for: agentID)
        }

        // Get auth token
        let token = await MainActor.run { AppState.shared.serverToken }

        // Build messages
        var messages: [[String: Any]] = [
            ["role": "system", "content": "You are a skilled AI assistant working on the Torbo Base project. Execute tasks autonomously using your available tools.\n\nCRITICAL RULES:\n1. NEVER modify existing core files (GatewayServer.swift, Capabilities.swift, AppState.swift, TorboBaseApp.swift, KeychainManager.swift, PairingManager.swift, ConversationStore.swift, TaskQueue.swift, ProactiveAgent.swift). The write_file tool will block you.\n2. ALWAYS create NEW files for new features. Name them clearly (e.g. PrivacyFilter.swift, ScreenCapture.swift).\n3. After writing any file, run swift build to verify it compiles. If it fails, fix your file — do NOT touch other files.\n4. Read existing code to understand patterns, but implement in NEW files using extensions.\n5. Use the working directory or locate the project root by finding Package.swift.\n6. Use tools — don't describe what you would do."],
            ["role": "user", "content": prompt]
        ]

        // Non-streaming tool loop through Base gateway
        for round in 0..<maxRounds {
            // Get tool definitions for this agent's access level
            let tools = ToolProcessor.toolDefinitions(for: accessLevel)

            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": false
            ]
            if !tools.isEmpty {
                body["tools"] = tools
                body["tool_choice"] = "auto"
            }

            let port = await MainActor.run { AppState.shared.serverPort }
            guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
                TorboLog.error("Invalid gateway URL", subsystem: "Agent")
                return "Error: Invalid gateway URL"
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")
            request.timeoutInterval = 600
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown"
                TorboLog.error("Gateway error (\(httpResponse.statusCode)): \(errorBody.prefix(200))", subsystem: "Agent")
                throw NSError(domain: "ProactiveAgent", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gateway error \(httpResponse.statusCode)"])
            }

            // Parse response — Base returns OpenAI-compatible format
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                // Might be Anthropic native format passed through
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let content = json["content"] as? [[String: Any]] {
                    var textParts: [String] = []
                    for block in content {
                        if (block["type"] as? String) == "text", let text = block["text"] as? String {
                            textParts.append(text)
                        }
                    }
                    if !textParts.isEmpty { return textParts.joined(separator: "\n") }
                }
                throw NSError(domain: "ProactiveAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse response"])
            }

            // Check for tool calls (OpenAI format — Base handles conversion)
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                TorboLog.info("\(agentID) round \(round + 1): executing \(toolCalls.count) tool(s)", subsystem: "Agent")
                let toolResults = await ToolProcessor.shared.executeBuiltInTools(toolCalls, accessLevel: accessLevel, agentID: agentID)
                messages.append(message)
                for result in toolResults { messages.append(result) }
                continue
            }

            // No tool calls — final response
            if let content = message["content"] as? String {
                return content
            }
            return "Task completed (no text response)"
        }

        return "Task reached maximum tool rounds (\(maxRounds)). Partial progress made."
    }
}
