// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Chambers: Multi-Agent Rooms
// Black background, dancing orbs, agents debating. Epic.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

struct ChamberView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var manager = ChamberManager.shared
    @ObservedObject private var voiceEngine = VoiceEngine.shared
    @ObservedObject private var tts = TTSManager.shared

    @State private var selectedChamberID: String?
    @State private var showCreateSheet = false
    @State private var viewMode: ChamberViewMode = .voice
    @State private var inputText = ""
    @State private var agents: [AgentConfig] = []
    @State private var sendTask: Task<Void, Never>?
    @State private var lastVoiceTrigger: Int = 0
    @State private var showAddAgentPopover = false
    @State private var isInterrupted = false

    enum ChamberViewMode: String, CaseIterable {
        case voice = "Voice"
        case chat = "Chat"
        case settings = "Settings"
    }

    private var isChamberVoiceActive: Bool {
        voiceEngine.isActive && voiceEngine.chamberMode
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — Chamber list
            chamberListPanel
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)

            Divider().background(Color.white.opacity(0.06))

            // Right panel — Chamber detail
            if let chamberID = selectedChamberID,
               let chamber = manager.chambers.first(where: { $0.id == chamberID }) {
                chamberDetailPanel(chamber)
                    .frame(maxWidth: .infinity)
            } else {
                emptyChamberPlaceholder
                    .frame(maxWidth: .infinity)
            }
        }
        .task {
            agents = await AgentConfigManager.shared.listAgents()
            if selectedChamberID == nil {
                selectedChamberID = manager.chambers.first?.id
            }
        }
        .sheet(isPresented: $showCreateSheet) { createChamberSheet }
        // Voice-to-chamber: intercept voice transcripts and route through chamber pipeline
        .onChange(of: voiceEngine.voiceChatTrigger) { newTrigger in
            guard newTrigger != lastVoiceTrigger else { return }
            guard voiceEngine.chamberMode else { return }
            lastVoiceTrigger = newTrigger
            let userText = voiceEngine.lastUserTranscript
            guard !userText.isEmpty else { return }

            if let chamberID = selectedChamberID,
               let chamber = manager.chambers.first(where: { $0.id == chamberID }) {
                sendTask?.cancel()
                isInterrupted = false

                sendTask = Task {
                    // Stop mic so agents don't hear each other through speakers
                    voiceEngine.autoListen = false
                    voiceEngine.speech.stopListening()

                    await manager.sendChamberMessage(userText, chamberID: chamber.id) { agentID, agentName, response in
                        guard !isInterrupted && !Task.isCancelled else { return }
                        guard !response.isEmpty else { return }

                        applyAgentVoice(agentID)

                        if !voiceEngine.isMuted {
                            tts.speak(response)
                            // Wait for this agent to finish before next agent starts
                            await waitForTTSWithBargeIn()
                        }
                    }

                    // All agents done — restore mic and resume listening
                    voiceEngine.autoListen = true
                    manager.respondingAgentID = nil

                    if isChamberVoiceActive && !voiceEngine.isMicMuted && !isInterrupted {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if voiceEngine.isActive && voiceEngine.state != .listening {
                            voiceEngine.listen()
                        }
                    }
                }
            }
        }
        .onDisappear {
            pauseChamberSession()
        }
        .onChange(of: state.currentTab) { newTab in
            if newTab != .chambers {
                pauseChamberSession()
            }
        }
    }

    // MARK: - Chamber List Panel

    private var chamberListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CHAMBERS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1)
                Spacer()
                Text("\(manager.chambers.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(manager.chambers) { chamber in
                        chamberRow(chamber)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().background(Color.white.opacity(0.06))

            Button {
                showCreateSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 12))
                    Text("Create Chamber").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .background(Color.black.opacity(0.2))
    }

    private func chamberRow(_ chamber: Chamber) -> some View {
        let isSelected = selectedChamberID == chamber.id
        return Button {
            selectedChamberID = chamber.id
            manager.activeChamberID = chamber.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chamber.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(chamber.name)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                    Text("\(chamber.agentIDs.count) agents · \(chamber.discussionStyle.rawValue)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chamber Detail Panel

    private func chamberDetailPanel(_ chamber: Chamber) -> some View {
        VStack(spacing: 0) {
            // Mode picker
            HStack {
                Picker("", selection: $viewMode) {
                    ForEach(ChamberViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                // Delete chamber
                Button {
                    manager.deleteChamber(id: chamber.id)
                    selectedChamberID = manager.chambers.first?.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("Delete").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().overlay(Color.white.opacity(0.06))

            switch viewMode {
            case .voice:
                voiceModeView(chamber)
            case .chat:
                chatModeView(chamber)
            case .settings:
                settingsModeView(chamber)
            }
        }
    }

    // MARK: - Voice Mode — THE EPIC VIEW

    private func voiceModeView(_ chamber: Chamber) -> some View {
        VStack(spacing: 0) {
            // Black background with orbs — tap anywhere to interrupt speaking
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: manager.respondingAgentID == nil)) { _ in
                ZStack {
                    Color.black

                    // Arrange orbs based on count
                    orbArrangement(chamber)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if tts.isSpeaking || manager.respondingAgentID != nil {
                    interruptSpeaking()
                }
            }

            // Voice control bar
            chamberVoiceBar(chamber)

            // Input bar
            chamberInputBar(chamber)
        }
    }

    // MARK: - Voice Control Bar (like AgentView)

    private func chamberVoiceBar(_ chamber: Chamber) -> some View {
        HStack(spacing: 10) {
            // State dot + label
            Circle()
                .fill(chamberVoiceStateColor)
                .frame(width: 8, height: 8)

            Text(chamberVoiceStateText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 120, alignment: .leading)

            // Live audio level meter
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isChamberVoiceActive)) { _ in
                chamberAudioLevelMeter
            }
            .frame(maxWidth: .infinity)

            // Power button — toggle voice for chamber
            Button {
                if isChamberVoiceActive {
                    voiceEngine.chamberMode = false
                    voiceEngine.deactivate()
                } else {
                    voiceEngine.chamberMode = true
                    let firstAgent = chamber.agentIDs.first ?? "sid"
                    if voiceEngine.isActive {
                        // Already active from AgentView — switch to chamber mode and start listening
                        voiceEngine.activeAgentID = firstAgent
                        voiceEngine.listen()
                    } else {
                        voiceEngine.activate(agentID: firstAgent)
                        // activate() auto-listens after 300ms, but ensure it happens
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if voiceEngine.state == .idle && voiceEngine.isActive {
                                voiceEngine.listen()
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: isChamberVoiceActive ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isChamberVoiceActive ? .green : .red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Toggle chamber voice")

            // Mic button
            Button {
                if isChamberVoiceActive {
                    voiceEngine.isMicMuted.toggle()
                    if !voiceEngine.isMicMuted && voiceEngine.state != .listening {
                        voiceEngine.listen()
                    }
                } else {
                    voiceEngine.chamberMode = true
                    let firstAgent = chamber.agentIDs.first ?? "sid"
                    if voiceEngine.isActive {
                        voiceEngine.activeAgentID = firstAgent
                        voiceEngine.listen()
                    } else {
                        voiceEngine.activate(agentID: firstAgent)
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if voiceEngine.state == .idle && voiceEngine.isActive {
                                voiceEngine.listen()
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: voiceEngine.isMicMuted ? "mic.slash.fill" : (voiceEngine.state == .listening ? "mic.fill" : "mic"))
                    .font(.system(size: 16))
                    .foregroundStyle(
                        !isChamberVoiceActive ? .white.opacity(0.3) :
                        voiceEngine.isMicMuted ? .red : .green
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle mic")

            // Speaker mute
            Button { voiceEngine.isMuted.toggle() } label: {
                Image(systemName: voiceEngine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(voiceEngine.isMuted ? .red : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Toggle speaker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    private var chamberVoiceStateColor: Color {
        guard isChamberVoiceActive else { return .white.opacity(0.3) }
        if manager.respondingAgentID != nil { return .orange }
        switch voiceEngine.state {
        case .idle: return .white.opacity(0.3)
        case .listening: return .green
        case .thinking: return .cyan
        case .speaking: return .orange
        }
    }

    private var chamberVoiceStateText: String {
        guard isChamberVoiceActive else { return "Voice Off" }
        if let respondingID = manager.respondingAgentID {
            let name = agents.first(where: { $0.id == respondingID })?.name ?? respondingID
            return "\(name) speaking..."
        }
        switch voiceEngine.state {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }

    private var chamberAudioLevelMeter: some View {
        GeometryReader { geo in
            let levels: [Float] = isChamberVoiceActive ? voiceEngine.currentAudioLevels : Array(repeating: Float(0), count: 40)
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

    // MARK: - Orb Layout

    private func orbPosition(index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let r = Double(radius)
        let cx = Double(center.x)
        let cy = Double(center.y)
        switch count {
        case 1:
            return center
        case 2:
            let xOff = r * (index == 0 ? -1.0 : 1.0)
            return CGPoint(x: cx + xOff, y: cy)
        case 3:
            let angle = Double(index) * (2.0 * .pi / 3.0) - .pi / 2.0
            return CGPoint(x: cx + cos(angle) * r, y: cy + sin(angle) * r)
        case 4:
            let row = index / 2
            let col = index % 2
            let sp = r * 0.8
            return CGPoint(
                x: cx + (col == 0 ? -sp : sp),
                y: cy + (row == 0 ? -sp * 0.6 : sp * 0.6)
            )
        default:
            let angle = Double(index) * (2.0 * .pi / Double(count)) - .pi / 2.0
            return CGPoint(x: cx + cos(angle) * r, y: cy + sin(angle) * r)
        }
    }

    @ViewBuilder
    private func singleOrb(agentID: String, index: Int, count: Int, center: CGPoint, radius: CGFloat) -> some View {
        let agent = agents.first(where: { $0.id == agentID })
        let name = agent?.name ?? agentID
        let isSpeaking = manager.respondingAgentID == agentID
        let accessLevel = agent?.accessLevel ?? 1
        let orbSize: CGFloat = count <= 4 ? 240 : 180
        let pos = orbPosition(index: index, count: count, center: center, radius: radius)
        let levels: [Float] = isSpeaking ? tts.audioLevels : Array(repeating: Float(0.08), count: 40)
        let orbColor = AccessLevel(rawValue: accessLevel)?.color ?? Color.cyan
        let displaySize = isSpeaking ? orbSize * 1.1 : orbSize
        let modelName = agent?.preferredModel.isEmpty == false ? agent!.preferredModel : "Default"

        VStack(spacing: 6) {
            OrbRenderer(
                audioLevels: levels,
                color: orbColor,
                isActive: true
            )
            .frame(width: displaySize, height: displaySize)
            .animation(.easeInOut(duration: 0.3), value: isSpeaking)

            Text(name)
                .font(.system(size: 28, weight: isSpeaking ? .bold : .medium, design: .monospaced))
                .foregroundStyle(isSpeaking ? .white : .white.opacity(0.5))

            Text(modelName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .lineLimit(1)
        }
        .position(pos)
    }

    private func orbArrangement(_ chamber: Chamber) -> some View {
        let count = chamber.agentIDs.count
        return GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 20)
            let radius = min(geo.size.width, geo.size.height) * 0.3

            ForEach(Array(chamber.agentIDs.enumerated()), id: \.element) { index, agentID in
                singleOrb(agentID: agentID, index: index, count: count, center: center, radius: radius)
            }
        }
    }

    // MARK: - Chat Mode

    private func chatModeView(_ chamber: Chamber) -> some View {
        VStack(spacing: 0) {
            // Message list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(manager.messages) { msg in
                        chamberMessageBubble(msg)
                    }
                }
                .padding(20)
            }

            Divider().overlay(Color.white.opacity(0.06))
            chamberInputBar(chamber)
        }
    }

    private func chamberMessageBubble(_ msg: ChamberMessage) -> some View {
        let isUser = msg.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if !isUser {
                        Circle()
                            .fill(Color(hue: agentOrbHue(msg.agentID) ?? 0.5, saturation: 0.7, brightness: 0.9))
                            .frame(width: 6, height: 6)
                    }
                    Text(msg.agentName)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isUser ? .cyan.opacity(0.6) : .white.opacity(0.5))
                }
                Text(msg.content.isEmpty && msg.isStreaming ? "..." : msg.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.cyan.opacity(0.08) : Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isUser ? Color.cyan.opacity(0.15) : Color.white.opacity(0.04), lineWidth: 1)
                    )
            }
            if !isUser { Spacer(minLength: 80) }
        }
    }

    // MARK: - Settings Mode

    private func settingsModeView(_ chamber: Chamber) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Discussion style
                VStack(alignment: .leading, spacing: 8) {
                    Text("DISCUSSION STYLE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    Picker("", selection: Binding(
                        get: { chamber.discussionStyle },
                        set: { manager.updateDiscussionStyle(chamberID: chamber.id, style: $0) }
                    )) {
                        ForEach(DiscussionStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(chamber.discussionStyle.info)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }

                // Members
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("MEMBERS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Text("\(chamber.agentIDs.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    ForEach(chamber.agentIDs, id: \.self) { agentID in
                        let agent = agents.first(where: { $0.id == agentID })
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hue: agentOrbHue(agentID) ?? 0.5, saturation: 0.7, brightness: 0.9))
                                .frame(width: 8, height: 8)
                            Text(agent?.name ?? agentID)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(agent?.role ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                            Spacer()
                            Button {
                                manager.removeAgent(chamberID: chamber.id, agentID: agentID)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.red.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help("Remove from chamber")
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(6)
                    }

                    HStack(spacing: 12) {
                        Button {
                            showAddAgentPopover = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 12))
                                Text("Add Agent").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.cyan.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showAddAgentPopover, arrowEdge: .bottom) {
                            addAgentPopover(chamber)
                        }

                        Button {} label: {
                            HStack(spacing: 4) {
                                Image(systemName: "person.badge.plus").font(.system(size: 12))
                                Text("Invite Human").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.2))
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                        .help("Coming soon")
                    }
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(24)
        }
    }

    // MARK: - Input Bar

    private func chamberInputBar(_ chamber: Chamber) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Message chamber...")
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
                    .frame(minHeight: 36, maxHeight: 80)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))

            Button {
                sendToChamber(chamber)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.1) : Color.cyan)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.02))
    }

    private func sendToChamber(_ chamber: Chamber) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isInterrupted = false

        sendTask?.cancel()
        sendTask = Task {
            // Stop mic during speaking so agents don't hear each other
            if isChamberVoiceActive {
                voiceEngine.autoListen = false
                voiceEngine.speech.stopListening()
            }

            await manager.sendChamberMessage(text, chamberID: chamber.id) { agentID, agentName, response in
                guard !isInterrupted && !Task.isCancelled else { return }
                guard !response.isEmpty else { return }

                applyAgentVoice(agentID)

                if !voiceEngine.isMuted {
                    tts.speak(response)
                    await waitForTTSWithBargeIn()
                }
            }

            // Restore auto-listen after all agents done
            if isChamberVoiceActive {
                voiceEngine.autoListen = true
                if !voiceEngine.isMicMuted && !isInterrupted {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if voiceEngine.isActive && voiceEngine.state != .listening {
                        voiceEngine.listen()
                    }
                }
            }
        }
    }

    /// Apply a specific agent's voice settings to TTSManager before speaking
    private func applyAgentVoice(_ agentID: String) {
        let agent = agents.first(where: { $0.id == agentID })
        let engine = agent?.voiceEngine ?? "torbo"
        tts.engine = engine
        tts.agentID = agentID
        // Always keep a valid ElevenLabs voice ID for torbo→ElevenLabs fallback
        let voiceID = agent?.elevenLabsVoiceID ?? ""
        tts.elevenLabsVoiceID = voiceID.isEmpty ? TTSManager.defaultElevenLabsVoice : voiceID
        tts.systemVoiceIdentifier = agent?.systemVoiceIdentifier ?? ""
    }

    /// Pause the chamber session — stop TTS, cancel tasks, deactivate voice
    private func pauseChamberSession() {
        isInterrupted = true
        sendTask?.cancel()
        sendTask = nil
        tts.stop()
        voiceEngine.autoListen = true
        manager.respondingAgentID = nil
        if voiceEngine.chamberMode {
            voiceEngine.chamberMode = false
            voiceEngine.deactivate()
        }
    }

    /// Interrupt the speaking cycle — stop TTS, cancel pending, resume listening
    private func interruptSpeaking() {
        isInterrupted = true
        tts.stop()
        sendTask?.cancel()
        sendTask = nil
        manager.respondingAgentID = nil
        voiceEngine.autoListen = true

        // Resume listening to the user after a brief settle
        if isChamberVoiceActive && !voiceEngine.isMicMuted {
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if voiceEngine.isActive && voiceEngine.state != .listening {
                    voiceEngine.listen()
                }
            }
        }
    }

    /// Wait for TTS to finish speaking (tap the screen to interrupt)
    private func waitForTTSWithBargeIn() async {
        var waitCount = 0
        while tts.isSpeaking && !Task.isCancelled && !isInterrupted && waitCount < 600 {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms poll
            waitCount += 1
        }
    }

    // MARK: - Create Chamber Sheet

    @State private var newChamberName = ""
    @State private var newChamberAgents: Set<String> = []

    private var createChamberSheet: some View {
        VStack(spacing: 20) {
            Text("Create Chamber")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 12) {
                Text("NAME")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("e.g. Strategy Room", text: $newChamberName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("SELECT AGENTS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))

                ForEach(agents) { agent in
                    Button {
                        if newChamberAgents.contains(agent.id) {
                            newChamberAgents.remove(agent.id)
                        } else {
                            newChamberAgents.insert(agent.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: newChamberAgents.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(newChamberAgents.contains(agent.id) ? .cyan : .white.opacity(0.3))
                            Text(agent.name)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { showCreateSheet = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Create") {
                    let _ = manager.createChamber(
                        name: newChamberName,
                        agentIDs: Array(newChamberAgents)
                    )
                    selectedChamberID = manager.chambers.last?.id
                    newChamberName = ""
                    newChamberAgents = []
                    showCreateSheet = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(newChamberName.isEmpty || newChamberAgents.count < 2 ? Color.gray.opacity(0.3) : Color.white.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(newChamberName.isEmpty || newChamberAgents.count < 2)
            }
        }
        .padding(32)
        .frame(width: 420)
        .background(Color(white: 0.1))
    }

    // MARK: - Empty Placeholder

    private var emptyChamberPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.1))
            Text("No chamber selected")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
            Text("Create a chamber to start multi-agent conversations")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.2))
            Button("Create Chamber") { showCreateSheet = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add Agent Popover

    private func addAgentPopover(_ chamber: Chamber) -> some View {
        let available = agents.filter { agent in !chamber.agentIDs.contains(agent.id) }
        return VStack(alignment: .leading, spacing: 4) {
            if available.isEmpty {
                Text("All agents are already in this chamber")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(12)
            } else {
                Text("ADD AGENT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(available) { agent in
                    Button {
                        manager.addAgent(chamberID: chamber.id, agentID: agent.id)
                        showAddAgentPopover = false
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hue: agentOrbHue(agent.id) ?? 0.5, saturation: 0.7, brightness: 0.9))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8))
                                if !agent.role.isEmpty {
                                    Text(agent.role)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.3))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 200)
        .background(Color(white: 0.12))
    }

    // MARK: - Helpers

    private func agentOrbHue(_ agentID: String) -> Double? {
        switch agentID.lowercased() {
        case "sid":   return 0.9
        case "ada":   return 0.55
        case "mira":  return 0.45
        case "orion": return 0.75
        case "x":     return 0.0
        default:
            let hash = agentID.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
            return Double(abs(hash) % 1000) / 1000.0
        }
    }
}
#endif
