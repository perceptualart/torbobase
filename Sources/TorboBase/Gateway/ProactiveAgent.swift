import Foundation

// MARK: - Proactive Agent — Background Task Executor

actor ProactiveAgent {
    static let shared = ProactiveAgent()

    private var isRunning = false
    private var checkInterval: TimeInterval = 30  // Check for tasks every 30s
    private var activeCrewTasks: [String: String] = [:]  // crewID -> taskID currently executing

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[ProactiveAgent] Started — checking for tasks every \(Int(checkInterval))s")
        Task { await runLoop() }
    }

    func stop() {
        isRunning = false
        print("[ProactiveAgent] Stopped")
    }

    // MARK: - Main Loop

    private func runLoop() async {
        while isRunning {
            await checkAndExecuteTasks()
            try? await Task.sleep(nanoseconds: UInt64(checkInterval) * 1_000_000_000)
        }
    }

    private func checkAndExecuteTasks() async {
        let pending = await TaskQueue.shared.pendingTasks()
        guard !pending.isEmpty else { return }

        // Get unique crew members with pending tasks
        let crewIDs = Set(pending.map { $0.assignedTo })

        for crewID in crewIDs {
            // Skip if this crew is already executing a task
            if activeCrewTasks[crewID] != nil { continue }

            // Claim next task for this crew
            guard let task = await TaskQueue.shared.claimTask(crewID: crewID) else { continue }
            activeCrewTasks[crewID] = task.id

            print("[ProactiveAgent] \(crewID) starting task: '\(task.title)'")

            // Execute in background
            Task {
                await self.executeTask(task, crewID: crewID)
            }
        }
    }

    // MARK: - Task Execution

    private func executeTask(_ task: TaskQueue.CrewTask, crewID: String) async {
        let startTime = Date()

        // Build the prompt for the crew member
        let prompt = buildTaskPrompt(task)

        // Get the model and API config for this crew member
        let tier = classifyTaskTier(task.title, task.description ?? "")
        let modelConfig = crewModelConfig(crewID, tier: tier)
        print("[ProactiveAgent] \(crewID) task tier: \(tier) -> model: \(modelConfig.model)")

        // Execute through the LLM with tool access
        do {
            let result = try await executeWithTools(
                prompt: prompt,
                crewID: crewID,
                model: modelConfig.model,
                provider: modelConfig.provider,
                maxRounds: 30
            )

            let elapsed = Int(Date().timeIntervalSince(startTime))
            await TaskQueue.shared.completeTask(id: task.id, result: result)
            print("[ProactiveAgent] \(crewID) completed '\(task.title)' in \(elapsed)s")

        } catch {
            await TaskQueue.shared.failTask(id: task.id, error: error.localizedDescription)
            print("[ProactiveAgent] \(crewID) failed '\(task.title)': \(error.localizedDescription)")
        }

        // Free up the crew member
        activeCrewTasks[crewID] = nil
    }

    private func buildTaskPrompt(_ task: TaskQueue.CrewTask) -> String {
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

    private func crewModelConfig(_ crewID: String, tier: TaskTier = .complex) -> ModelConfig {
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
            switch crewID {
            case "mira":
                return ModelConfig(model: "gpt-4o", provider: "openai", apiKeyName: "openai_api_key")
            default:
                return ModelConfig(model: "claude-sonnet-4-5-20250929", provider: "anthropic", apiKeyName: "anthropic_api_key")
            }
        }
    }

    // MARK: - Tool Execution Loop

    private func executeWithTools(prompt: String, crewID: String, model: String, provider: String, maxRounds: Int) async throws -> String {
        // Route through Base itself — uses the same multi-provider gateway
        // This means ANY model works: Anthropic, OpenAI, Google, local Ollama
        let accessLevel = await MainActor.run {
            AppState.shared.accessLevel(for: crewID)
        }

        // Get auth token
        let token = await MainActor.run { AppState.shared.serverToken }

        // Build messages
        var messages: [[String: Any]] = [
            ["role": "system", "content": "You are a skilled AI assistant working on the Torbo Base project. Execute tasks autonomously using your available tools.\n\nCRITICAL RULES:\n1. NEVER modify existing core files (GatewayServer.swift, Capabilities.swift, AppState.swift, TorboBaseApp.swift, KeychainManager.swift, PairingManager.swift, ConversationStore.swift, TaskQueue.swift, ProactiveAgent.swift). The write_file tool will block you.\n2. ALWAYS create NEW files for new features. Name them clearly (e.g. PrivacyFilter.swift, ScreenCapture.swift).\n3. After writing any file, run swift build to verify it compiles. If it fails, fix your file — do NOT touch other files.\n4. Read existing code to understand patterns, but implement in NEW files using extensions.\n5. The project is at ~/Documents/torbo master/torbo base/. The app is at ~/Documents/torbo master/torbo app/.\n6. Use tools — don't describe what you would do."],
            ["role": "user", "content": prompt]
        ]

        // Non-streaming tool loop through Base gateway
        for round in 0..<maxRounds {
            // Get tool definitions for this crew's access level
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

            let url = URL(string: "http://127.0.0.1:\(await MainActor.run { AppState.shared.serverPort })/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(crewID, forHTTPHeaderField: "x-torbo-agent-id")
            request.timeoutInterval = 600
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown"
                print("[ProactiveAgent] Gateway error (\(httpResponse.statusCode)): \(errorBody.prefix(200))")
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
                print("[ProactiveAgent] \(crewID) round \(round + 1): executing \(toolCalls.count) tool(s)")
                let toolResults = await ToolProcessor.shared.executeBuiltInTools(toolCalls, accessLevel: accessLevel)
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
