// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Per-Agent Chat Interface
// Full-featured native chat window embedded in each agent's dashboard panel.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String          // "user", "assistant", "system", "tool"
    var content: String
    let timestamp: Date
    var toolCalls: [ToolCallDisplay]?
    var isStreaming: Bool

    struct ToolCallDisplay: Identifiable {
        let id = UUID()
        let name: String
        var arguments: String
        var result: String?
        var isRunning: Bool
    }
}

// MARK: - Agent Chat View

struct AgentChatView: View {
    let agentID: String
    let agentName: String
    var showHeader: Bool = true
    var sessionID: UUID? = nil
    var onSwitchToVoice: (() -> Void)?
    var aboveInput: AnyView? = nil
    @EnvironmentObject private var state: AppState

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showExportPanel = false
    @State private var streamTask: Task<Void, Never>?
    @State private var currentSessionID: UUID = UUID()
    @State private var saveTask: Task<Void, Never>?

    // Voice-to-chat bridge
    @ObservedObject private var voiceEngine = VoiceEngine.shared
    @State private var lastVoiceTrigger: Int = 0
    @State private var voiceAssistantIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Chat header (optional)
            if showHeader {
                chatHeader
                Divider().background(Color.white.opacity(0.06))
            }

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                        if isLoading && (messages.isEmpty || messages.last?.role != "assistant") {
                            typingIndicator
                        }
                    }
                    .padding(20)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // Voice control bar — matches Chambers layout
            chatVoiceBar

            // Injected content above input (e.g. GAIN/GATE sliders)
            if let aboveInput { aboveInput }

            // Input area
            inputArea
        }
        // Voice-to-chat: inject user message when voice transcript is finalized
        .onChange(of: voiceEngine.voiceChatTrigger) { newTrigger in
            guard newTrigger != lastVoiceTrigger else { return }
            guard voiceEngine.activeAgentID == agentID else { return }
            lastVoiceTrigger = newTrigger
            let userText = voiceEngine.lastUserTranscript
            guard !userText.isEmpty else { return }

            // Add user message
            messages.append(ChatMessage(role: "user", content: userText, timestamp: Date(), isStreaming: false))

            // Add streaming assistant placeholder
            messages.append(ChatMessage(role: "assistant", content: "", timestamp: Date(), isStreaming: true))
            voiceAssistantIndex = messages.count - 1
        }
        // Voice-to-chat: update assistant message as response streams in
        .onChange(of: voiceEngine.lastAssistantResponse) { newValue in
            guard let idx = voiceAssistantIndex, idx < messages.count else { return }
            guard voiceEngine.activeAgentID == agentID else { return }
            messages[idx].content = newValue
        }
        // Voice-to-chat: finalize when speaking finishes
        .onChange(of: voiceEngine.state) { newState in
            guard let idx = voiceAssistantIndex, idx < messages.count else { return }
            if newState == .idle || newState == .listening {
                messages[idx].isStreaming = false
                voiceAssistantIndex = nil
            }
        }
        // Persistence: load on appear (finds most recent session when no explicit sessionID)
        .task(id: sessionID ?? currentSessionID) {
            let sid: UUID
            if let explicit = sessionID {
                sid = explicit
            } else if let recent = await ConversationStore.shared.mostRecentSessionID(forAgent: agentID) {
                sid = recent
            } else {
                sid = currentSessionID
            }
            currentSessionID = sid
            let loaded = await ConversationStore.shared.loadAgentChat(agentID: agentID, sessionID: sid)
            if !loaded.isEmpty {
                messages = loaded.map {
                    ChatMessage(role: $0.role, content: $0.content, timestamp: $0.timestamp, isStreaming: false)
                }
            }
        }
        // Persistence: debounced save on message changes
        .onChange(of: messages.count) { _ in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s debounce
                guard !Task.isCancelled else { return }
                let toSave = messages.filter { !$0.isStreaming }.map {
                    AgentChatMessage(role: $0.role, content: $0.content, timestamp: $0.timestamp)
                }
                guard !toSave.isEmpty else { return }
                await ConversationStore.shared.saveAgentChat(
                    agentID: agentID, sessionID: currentSessionID, messages: toSave
                )
                await ConversationStore.shared.ensureSessionExists(
                    agentID: agentID, sessionID: currentSessionID, messageCount: toSave.count
                )
            }
        }
        .onChange(of: isLoading) { loading in
            guard !loading else { return }
            // Stream just finished — save finalized messages
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms settle
                guard !Task.isCancelled else { return }
                let toSave = messages.filter { !$0.isStreaming }.map {
                    AgentChatMessage(role: $0.role, content: $0.content, timestamp: $0.timestamp)
                }
                guard !toSave.isEmpty else { return }
                await ConversationStore.shared.saveAgentChat(
                    agentID: agentID, sessionID: currentSessionID, messages: toSave
                )
                await ConversationStore.shared.ensureSessionExists(
                    agentID: agentID, sessionID: currentSessionID, messageCount: toSave.count
                )
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.15))
                Text(String(agentName.prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Chat with \(agentName)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(messages.filter { $0.role != "system" }.count) messages")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            // Canvas button
            Button {
                WindowOpener.openWindow?(id: "canvas")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 11))
                    Text("Canvas")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.cyan.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.cyan.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            // Export button
            Button {
                exportConversation()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                    Text("Export")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            // Clear button
            Button {
                messages.removeAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.red.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Chat Bubble

    private func bubbleBackground(isUser: Bool, isTool: Bool) -> Color {
        if isUser { return Color.cyan.opacity(0.08) }
        if isTool { return Color.orange.opacity(0.06) }
        return Color.white.opacity(0.03)
    }

    private func bubbleStroke(isUser: Bool, isTool: Bool) -> Color {
        if isUser { return Color.cyan.opacity(0.15) }
        if isTool { return Color.orange.opacity(0.1) }
        return Color.white.opacity(0.04)
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
        let isUser = msg.role == "user"
        let isTool = msg.role == "tool"

        HStack {
            if isUser { Spacer(minLength: 80) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Role label
                HStack(spacing: 4) {
                    if !isUser {
                        Circle()
                            .fill(isTool ? Color.orange : Color.cyan)
                            .frame(width: 6, height: 6)
                    }
                    Text(isUser ? "You" : (isTool ? "Tool" : agentName))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isUser ? .cyan.opacity(0.6) : (isTool ? .orange.opacity(0.6) : .white.opacity(0.4)))
                    Text(formatTime(msg.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.15))
                }

                // Message content with markdown
                if !msg.content.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        Text(renderMarkdown(msg.content))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)

                        // Speaker icon on assistant messages — tap to speak via TTS
                        if !isUser && !isTool && !msg.isStreaming {
                            Button {
                                TTSManager.shared.speak(msg.content)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.25))
                                    .padding(.leading, 6)
                                    .padding(.top, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground(isUser: isUser, isTool: isTool))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(bubbleStroke(isUser: isUser, isTool: isTool), lineWidth: 1)
                    )
                }

                // "Open in Canvas" buttons for code blocks in assistant messages
                if !isUser && !isTool && !msg.isStreaming {
                    let codeBlocks = extractCodeBlocks(msg.content)
                    ForEach(Array(codeBlocks.enumerated()), id: \.offset) { idx, block in
                        Button {
                            let ext = block.language.isEmpty ? "txt" : block.language
                            CanvasStore.shared.write(title: "code.\(ext)", content: block.code)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.on.rectangle.angled")
                                    .font(.system(size: 9))
                                Text(block.language.isEmpty ? "Open in Canvas" : "\(block.language) → Canvas")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(.cyan.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.cyan.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Tool calls display
                if let tools = msg.toolCalls {
                    ForEach(tools) { tool in
                        toolCallView(tool)
                    }
                }

                // Streaming indicator
                if msg.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("streaming...")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.4))
                    }
                }
            }

            if !isUser { Spacer(minLength: 80) }
        }
    }

    // MARK: - Tool Call Display

    private func toolCallView(_ tool: ChatMessage.ToolCallDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: tool.isRunning ? "gearshape.2" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(tool.isRunning ? .orange : .green)
                Text(tool.name)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.8))
                if tool.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }
            if !tool.arguments.isEmpty {
                Text(tool.arguments)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(3)
            }
            if let result = tool.result, !result.isEmpty {
                Text(result)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.5))
                    .lineLimit(5)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.cyan.opacity(0.3)).frame(width: 6, height: 6)
            Text("\(agentName) is thinking...")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
            ProgressView()
                .scaleEffect(0.5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Voice Control Bar

    private var isVoiceActiveForAgent: Bool {
        voiceEngine.isActive && voiceEngine.activeAgentID == agentID
    }

    private var chatVoiceBar: some View {
        HStack(spacing: 10) {
            // State dot + label
            Circle()
                .fill(chatVoiceStateColor)
                .frame(width: 8, height: 8)
            Text(chatVoiceStateText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 80, alignment: .leading)

            // Live audio level meter
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isVoiceActiveForAgent)) { _ in
                GeometryReader { geo in
                    let levels: [Float] = isVoiceActiveForAgent ? voiceEngine.currentAudioLevels : Array(repeating: Float(0), count: 40)
                    let barCount = min(40, Int(geo.size.width / 3))
                    let stride = max(1, levels.count / max(barCount, 1))

                    HStack(spacing: 1) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let idx = min(i * stride, levels.count - 1)
                            let level = CGFloat(levels[idx])
                            RoundedRectangle(cornerRadius: 1)
                                .fill(level > 0.3 ? Color.green : (level > 0.15 ? Color.cyan.opacity(0.6) : Color.white.opacity(0.15)))
                                .frame(width: 2, height: max(2, level * geo.size.height * 0.9))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 20)
            }
            .frame(maxWidth: .infinity)

            // Power button
            Button {
                if isVoiceActiveForAgent {
                    voiceEngine.deactivate()
                } else {
                    voiceEngine.activate(agentID: agentID)
                }
            } label: {
                Image(systemName: isVoiceActiveForAgent ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isVoiceActiveForAgent ? .green : .red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Toggle voice")

            // Mic button
            Button {
                if voiceEngine.isActive {
                    voiceEngine.isMicMuted.toggle()
                    if !voiceEngine.isMicMuted && voiceEngine.state != .listening {
                        voiceEngine.listen()
                    } else if voiceEngine.isMicMuted && voiceEngine.state == .listening {
                        voiceEngine.speech.stopListening()
                        voiceEngine.transition(to: .idle, reason: "mic muted")
                    }
                } else {
                    voiceEngine.activate(agentID: agentID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        voiceEngine.listen()
                    }
                }
            } label: {
                Image(systemName: voiceEngine.isMicMuted ? "mic.slash.fill" : (voiceEngine.state == .listening ? "mic.fill" : "mic"))
                    .font(.system(size: 16))
                    .foregroundStyle(
                        !isVoiceActiveForAgent ? .white.opacity(0.3) :
                        voiceEngine.isMicMuted ? .red : .green
                    )
            }
            .buttonStyle(.plain)
            .help(voiceEngine.isMicMuted ? "Unmute mic" : "Mute mic")

            // Speaker button
            Button {
                voiceEngine.isMuted.toggle()
            } label: {
                Image(systemName: voiceEngine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        !isVoiceActiveForAgent ? .white.opacity(0.3) :
                        voiceEngine.isMuted ? .red : .green
                    )
            }
            .buttonStyle(.plain)
            .help(voiceEngine.isMuted ? "Unmute speaker" : "Mute speaker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    private var chatVoiceStateColor: Color {
        guard isVoiceActiveForAgent else { return .white.opacity(0.3) }
        switch voiceEngine.state {
        case .idle: return .white.opacity(0.3)
        case .listening: return .green
        case .thinking: return .cyan
        case .speaking: return .orange
        }
    }

    private var chatVoiceStateText: String {
        guard isVoiceActiveForAgent else { return "Voice Off" }
        switch voiceEngine.state {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // File attachment button
            Button {
                attachFile()
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(8)
            }
            .buttonStyle(.plain)

            // Text input
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Message \(agentName)...")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .onSubmit { sendMessage() }

            // Mic button — switches to voice mode
            if let switchToVoice = onSwitchToVoice {
                Button {
                    switchToVoice()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Switch to voice mode")
            }

            // Send button
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading
                        ? Color.white.opacity(0.1) : Color.cyan
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        // Add user message
        let userMsg = ChatMessage(role: "user", content: text, timestamp: Date(), isStreaming: false)
        messages.append(userMsg)
        inputText = ""
        isLoading = true

        // Stream response from gateway
        streamTask?.cancel()
        streamTask = Task {
            await streamResponse(userMessage: text)
        }
    }

    private func streamResponse(userMessage: String) async {
        let port = state.serverPort
        let token = KeychainManager.serverToken

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            appendError("Invalid server URL")
            return
        }

        // Build messages array for the API
        var apiMessages: [[String: String]] = []
        for msg in messages where msg.role == "user" || msg.role == "assistant" {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "messages": apiMessages,
            "stream": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            appendError("Failed to encode request")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")
        request.httpBody = bodyData

        // Add streaming assistant message
        let assistantMsg = ChatMessage(role: "assistant", content: "", timestamp: Date(), isStreaming: true)
        var assistantIndex = 0
        await MainActor.run {
            messages.append(assistantMsg)
            assistantIndex = messages.count - 1
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await updateMessage(at: assistantIndex, content: "Error: Invalid response", streaming: false)
                await MainActor.run { isLoading = false }
                return
            }

            if httpResponse.statusCode != 200 {
                var errorBody = ""
                for try await line in bytes.lines { errorBody += line }
                await updateMessage(at: assistantIndex, content: "Error \(httpResponse.statusCode): \(errorBody)", streaming: false)
                await MainActor.run { isLoading = false }
                return
            }

            // Parse SSE stream
            var accumulated = ""
            var toolCalls: [ChatMessage.ToolCallDisplay] = []

            for try await line in bytes.lines {
                guard !Task.isCancelled else { break }

                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }

                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }

                // Content delta
                if let content = delta["content"] as? String {
                    accumulated += content
                    await updateMessage(at: assistantIndex, content: accumulated, streaming: true, tools: toolCalls)
                }

                // Tool call deltas
                if let tcArray = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcArray {
                        let name = (tc["function"] as? [String: Any])?["name"] as? String ?? ""
                        let args = (tc["function"] as? [String: Any])?["arguments"] as? String ?? ""
                        if !name.isEmpty {
                            toolCalls.append(ChatMessage.ToolCallDisplay(
                                name: name, arguments: args, result: nil, isRunning: true
                            ))
                            await updateMessage(at: assistantIndex, content: accumulated, streaming: true, tools: toolCalls)
                        }
                    }
                }

                // Check for tool results in metadata
                if let meta = json["tool_result"] as? [String: Any] {
                    let toolName = meta["name"] as? String ?? ""
                    let result = meta["content"] as? String ?? ""
                    if let idx = toolCalls.lastIndex(where: { $0.name == toolName }) {
                        toolCalls[idx].result = String(result.prefix(500))
                        toolCalls[idx].isRunning = false
                        await updateMessage(at: assistantIndex, content: accumulated, streaming: true, tools: toolCalls)
                    }
                }
            }

            // Finalize
            for i in toolCalls.indices { toolCalls[i].isRunning = false }
            await updateMessage(at: assistantIndex, content: accumulated, streaming: false, tools: toolCalls.isEmpty ? nil : toolCalls)

        } catch {
            if !Task.isCancelled {
                let current = assistantIndex < messages.count ? messages[assistantIndex].content : ""
                let errorNote = current.isEmpty ? "Error: \(error.localizedDescription)" : current + "\n\n[Stream interrupted: \(error.localizedDescription)]"
                await updateMessage(at: assistantIndex, content: errorNote, streaming: false)
            }
        }

        await MainActor.run { isLoading = false }
    }

    @MainActor
    private func updateMessage(at index: Int, content: String, streaming: Bool, tools: [ChatMessage.ToolCallDisplay]? = nil) {
        guard index < messages.count else { return }
        messages[index].content = content
        messages[index].isStreaming = streaming
        if let tools { messages[index].toolCalls = tools }
        if let proxy = scrollProxy {
            scrollToBottom(proxy: proxy)
        }
    }

    private func appendError(_ text: String) {
        Task { @MainActor in
            messages.append(ChatMessage(role: "assistant", content: "Error: \(text)", timestamp: Date(), isStreaming: false))
            isLoading = false
        }
    }

    // MARK: - File Attachment

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.title = "Attach File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // For images, encode as base64
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                let data = try Data(contentsOf: url)
                let b64 = data.base64EncodedString()
                let mimeType = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : "image/jpeg")
                inputText += "\n[Attached image: \(url.lastPathComponent)]\n![image](data:\(mimeType);base64,\(b64.prefix(100))...)"
                // Store full data in message for API
                messages.append(ChatMessage(
                    role: "user",
                    content: "[Attached: \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))]",
                    timestamp: Date(),
                    isStreaming: false
                ))
            } else {
                // Text files — include content
                let content = try String(contentsOf: url, encoding: .utf8)
                let preview = String(content.prefix(2000))
                inputText += "\n```\n// \(url.lastPathComponent)\n\(preview)\n```"
            }
        } catch {
            inputText += "\n[Failed to read file: \(error.localizedDescription)]"
        }
    }

    // MARK: - Export

    private func exportConversation() {
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = "\(agentID)-chat-\(dateStamp()).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var export = "# Chat with \(agentName)\n"
        export += "Exported: \(Date())\n\n---\n\n"
        for msg in messages {
            let label = msg.role == "user" ? "**You**" : "**\(agentName)**"
            export += "\(label) (\(formatTime(msg.timestamp)))\n\n\(msg.content)\n\n---\n\n"
        }

        try? export.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    private func renderMarkdown(_ text: String) -> AttributedString {
        // Try to parse as markdown for rich display
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }

    // MARK: - Code Block Extraction

    private struct CodeBlock {
        let language: String
        let code: String
    }

    /// Extracts fenced code blocks (```lang\n...\n```) from markdown text.
    private func extractCodeBlocks(_ text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        let lines = text.components(separatedBy: "\n")
        var inBlock = false
        var lang = ""
        var code: [String] = []

        for line in lines {
            if !inBlock && line.hasPrefix("```") {
                inBlock = true
                lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
            } else if inBlock && line.hasPrefix("```") {
                inBlock = false
                let joined = code.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(CodeBlock(language: lang, code: joined))
                }
            } else if inBlock {
                code.append(line)
            }
        }
        return blocks
    }
}
#endif
