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

    @State private var showCreateSheet = false
    @State private var inputText = ""
    @State private var agents: [AgentConfig] = []
    @State private var sendTask: Task<Void, Never>?
    @State private var lastVoiceTrigger: Int = 0
    @State private var showAddAgentPopover = false
    @State private var isInterrupted = false
    @State private var liveTranscript: String = ""
    @State private var liveTranscriptAgent: String = ""

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
            if let chamberID = manager.activeChamberID,
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
            if manager.activeChamberID == nil {
                manager.activeChamberID = manager.chambers.first?.id
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

            // Anti-feedback: reject transcripts that match recent agent output (TTS bleeding into mic)
            let recentAgentTexts = manager.messages.suffix(5)
                .filter { $0.role == "assistant" }
                .map { $0.content.lowercased() }
            let userLower = userText.lowercased()
            var isFeedback = false
            for agentText in recentAgentTexts {
                if userLower.count > 10 && agentText.contains(String(userLower.prefix(20))) {
                    isFeedback = true
                    break
                }
            }
            if isFeedback {
                TorboLog.warn("Chamber: rejected feedback loop — transcript matches agent output", subsystem: "Chamber")
                return
            }

            if let chamberID = manager.activeChamberID,
               let chamber = manager.chambers.first(where: { $0.id == chamberID }) {
                // Barge-in cleanup: stop any in-progress agent speech before starting new round
                tts.stop()
                manager.respondingAgentID = nil
                sendTask?.cancel()
                isInterrupted = false
                liveTranscript = ""

                sendTask = Task {
                    // Disable auto-listen so transcript finalization doesn't re-trigger
                    voiceEngine.autoListen = false
                    // NOTE: Do NOT call speech.stopListening() — mic stays active for barge-in

                    await manager.sendChamberMessage(userText, chamberID: chamber.id) { agentID, agentName, response in
                        guard !isInterrupted && !Task.isCancelled else { return }
                        guard !response.isEmpty else { return }

                        liveTranscriptAgent = agentName
                        liveTranscript = response

                        applyAgentVoice(agentID)

                        if !voiceEngine.isMuted {
                            tts.speak(response)
                            await waitForTTSWithBargeIn()
                        }
                    }

                    // All agents done — clear transcript, restore mic
                    liveTranscript = ""
                    voiceEngine.autoListen = true
                    manager.respondingAgentID = nil

                    if isChamberVoiceActive && !voiceEngine.isMicMuted && !isInterrupted {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if voiceEngine.isActive && voiceEngine.state != .listening {
                            voiceEngine.listen()
                        }
                    }
                }
            }
        }
        // NOTE: No onDisappear/onChange tab cleanup — chamber session stays alive
        // across tab switches. Use the power button to explicitly stop.
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
        let isSelected = manager.activeChamberID == chamber.id
        return Button {
            manager.activeChamberID = chamber.id
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
                Picker("", selection: $manager.chamberViewMode) {
                    ForEach(ChamberViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                // Canvas button
                Button {
                    WindowOpener.openWindow?(id: "canvas")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 10))
                        Text("Canvas")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.cyan.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                // Delete chamber
                Button {
                    manager.deleteChamber(id: chamber.id)
                    manager.activeChamberID = manager.chambers.first?.id
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

            switch manager.chamberViewMode {
            case .voice:
                voiceModeView(chamber)
            case .chat:
                chatModeView(chamber)
            case .settings:
                settingsModeView(chamber)
            case .teams:
                AgentTeamsView()
            }
        }
    }

    // MARK: - Voice Mode — THE EPIC VIEW

    private func voiceModeView(_ chamber: Chamber) -> some View {
        VStack(spacing: 0) {
            // Black background with orbs — tap anywhere to interrupt speaking
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: manager.respondingAgentID == nil && !tts.isSpeaking && !isChamberVoiceActive)) { _ in
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

            // Live transcript — shows current agent's spoken text
            chamberTranscriptBar

            // Voice control bar
            chamberVoiceBar(chamber)

            // Input bar
            chamberInputBar(chamber)
        }
    }

    // MARK: - Live Transcript Bar

    private var chamberTranscriptBar: some View {
        Group {
            if !liveTranscript.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hue: Self.agentOrbHue(manager.respondingAgentID ?? ""), saturation: 0.7, brightness: 0.9))
                        .frame(width: 6, height: 6)
                    Text(liveTranscriptAgent)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(liveTranscript)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                            .id(liveTranscript) // auto-scroll to latest text
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
            }
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
                .frame(width: 80, alignment: .leading)

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
                    .foregroundStyle(
                        !isChamberVoiceActive ? .white.opacity(0.3) :
                        voiceEngine.isMuted ? .red : .green
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle speaker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
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

    // MARK: - Orb Layout (helpers moved to ChamberOrbView struct below)

    /// Compute (x, y, cellW, cellH) for each agent index in a grid layout.
    /// Returns positions as fractions of container size for a given agent count.
    private func agentCellLayout(index: Int, count: Int, width: CGFloat, height: CGFloat) -> (x: CGFloat, y: CGFloat, cellW: CGFloat, cellH: CGFloat) {
        // Row assignments: which row does each index go in, how many per row?
        let rowAssignments: [[Int]]
        switch count {
        case 1: rowAssignments = [[0]]
        case 2: rowAssignments = [[0, 1]]
        case 3: rowAssignments = [[0], [1, 2]]         // triangle: 1 top, 2 bottom
        case 4: rowAssignments = [[0, 1], [2, 3]]
        case 5: rowAssignments = [[0, 1, 2], [3, 4]]
        case 6: rowAssignments = [[0, 1, 2], [3, 4, 5]]
        default:
            // Generic: 3 columns
            var rows: [[Int]] = []
            var idx = 0
            while idx < count {
                let rowCount = min(3, count - idx)
                rows.append(Array(idx..<(idx + rowCount)))
                idx += rowCount
            }
            rowAssignments = rows
        }

        let numRows = CGFloat(rowAssignments.count)
        let cellH = height / numRows

        // Find which row this index is in
        for (rowIdx, row) in rowAssignments.enumerated() {
            if let colIdx = row.firstIndex(of: index) {
                let itemsInRow = CGFloat(row.count)
                let cellW = width / itemsInRow
                let x = (CGFloat(colIdx) + 0.5) * cellW
                let y = (CGFloat(rowIdx) + 0.5) * cellH
                return (x, y, cellW, cellH)
            }
        }
        // Fallback: center
        return (width / 2, height / 2, width, height)
    }

    private func orbArrangement(_ chamber: Chamber) -> some View {
        let count = chamber.agentIDs.count

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // Determine grid dimensions for sizing
            let maxCols: CGFloat = count <= 1 ? 1 : (count <= 2 ? 2 : (count <= 4 ? 2 : 3))
            let numRows: CGFloat = count <= 2 ? 1 : 2

            // Calculate orb size to fit: reserve space for name + model text below each orb
            let textReserve: CGFloat = 56
            let cellH = h / numRows
            let cellW = w / maxCols
            let maxOrbFromHeight = (cellH - textReserve) * 0.85
            let maxOrbFromWidth = cellW * 0.65
            let orbSize = max(50, min(maxOrbFromHeight, maxOrbFromWidth))

            // Font sizes scale with orb
            let nameSize = max(12, min(28, orbSize * 0.14))
            let modelSize = max(10, min(20, orbSize * 0.09))

            // Single flat ForEach keyed by agent ID — critical for SwiftUI identity
            ForEach(Array(chamber.agentIDs.enumerated()), id: \.element) { index, agentID in
                let layout = agentCellLayout(index: index, count: count, width: w, height: h)

                ChamberOrbView(agentID: agentID, orbSize: orbSize, nameSize: nameSize, modelSize: modelSize, agents: agents)
                    .frame(width: layout.cellW, height: layout.cellH)
                    .position(x: layout.x, y: layout.y)
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
                            .fill(Color(hue: Self.agentOrbHue(msg.agentID), saturation: 0.7, brightness: 0.9))
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

                // Responses per round
                VStack(alignment: .leading, spacing: 8) {
                    Text("RESPONSES PER ROUND")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

                    Picker("", selection: Binding(
                        get: { chamber.maxResponsesPerRound },
                        set: { newVal in
                            if let idx = manager.chambers.firstIndex(where: { $0.id == chamber.id }) {
                                manager.chambers[idx].maxResponsesPerRound = newVal
                                manager.chambers[idx].updatedAt = Date()
                            }
                        }
                    )) {
                        Text("All agents").tag(0)
                        ForEach(1...max(chamber.agentIDs.count, 1), id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Text(chamber.maxResponsesPerRound == 0 ? "Every agent responds each round." : "Only \(chamber.maxResponsesPerRound) agent\(chamber.maxResponsesPerRound == 1 ? "" : "s") respond per round. With Round Robin, this naturally rotates who speaks.")
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
                                .fill(Color(hue: Self.agentOrbHue(agentID), saturation: 0.7, brightness: 0.9))
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

    // MARK: - Audio Level Meter

    private var chamberAudioMeter: some View {
        GeometryReader { geo in
            let levels: [Float] = voiceEngine.currentAudioLevels
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
    }

    // MARK: - Input Bar

    private func chamberInputBar(_ chamber: Chamber) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            // File attachment button
            Button {
                // TODO: wire file attachment for chambers
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(8)
            }
            .buttonStyle(.plain)

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
                    .frame(minHeight: 36, maxHeight: 120)
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
        liveTranscript = ""
        sendTask = Task {
            // Disable auto-listen so transcript finalization doesn't re-trigger
            if isChamberVoiceActive {
                voiceEngine.autoListen = false
                // NOTE: Do NOT call speech.stopListening() — mic stays active for barge-in
            }

            await manager.sendChamberMessage(text, chamberID: chamber.id) { agentID, agentName, response in
                guard !isInterrupted && !Task.isCancelled else { return }
                guard !response.isEmpty else { return }

                liveTranscriptAgent = agentName
                liveTranscript = response

                applyAgentVoice(agentID)

                if !voiceEngine.isMuted {
                    tts.speak(response)
                    await waitForTTSWithBargeIn()
                }
            }

            // All agents done — clear transcript and restore mic
            liveTranscript = ""
            if isChamberVoiceActive {
                voiceEngine.autoListen = true
                if !voiceEngine.isMicMuted && !isInterrupted {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        var engine = agent?.voiceEngine ?? "torbo"

        // If engine is "torbo" (Piper) but no voice model exists for this agent, fall back
        if engine == "torbo" && !PiperTTSEngine.shared.hasVoice(for: agentID) {
            let hasEL = !(AppState.shared.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty
            engine = hasEL ? "elevenlabs" : "system"
            TorboLog.warn("No Piper voice for \(agentID) — falling back to \(engine)", subsystem: "TTS")
        }

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
                    manager.activeChamberID = manager.chambers.last?.id
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
                                .fill(Color(hue: Self.agentOrbHue(agent.id), saturation: 0.7, brightness: 0.9))
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

    static func agentOrbHue(_ agentID: String) -> Double {
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

// MARK: - ChamberOrbView — Independent observation scope per orb

/// Each orb is its own struct so SwiftUI creates independent observation scopes.
/// This fixes the bug where all orbs animate together because singleOrb() was a function
/// (not a View struct) and shared one evaluation context inside the TimelineView.
struct ChamberOrbView: View {
    let agentID: String
    let orbSize: CGFloat
    let nameSize: CGFloat
    let modelSize: CGFloat
    let agents: [AgentConfig]

    @ObservedObject private var manager = ChamberManager.shared
    @ObservedObject private var tts = TTSManager.shared

    private var agent: AgentConfig? { agents.first(where: { $0.id == agentID }) }
    private var isResponding: Bool { manager.respondingAgentID == agentID }
    private var isActivelySpeaking: Bool { isResponding && tts.isSpeaking }
    private var someoneSpeaking: Bool { manager.respondingAgentID != nil }

    private var avgAudioLevel: Double {
        let levels = tts.audioLevels
        guard !levels.isEmpty else { return 0 }
        return Double(levels.reduce(0, +)) / Double(levels.count)
    }

    var body: some View {
        let name = agent?.name ?? agentID
        let levels = orbAudioLevels()
        let hue = ChamberView.agentOrbHue(agentID)
        let orbColor = Color(hue: hue, saturation: 0.7, brightness: 0.9)
        let visualScale = orbVisualScale()
        let modelName = agent?.preferredModel.isEmpty == false ? agent!.preferredModel : "Default"
        let nameOp = orbNameOpacity()
        let dimming = orbDimming()

        VStack(spacing: 4) {
            Color.clear
                .frame(width: orbSize, height: orbSize)
                .overlay(
                    OrbRenderer(
                        audioLevels: levels,
                        color: orbColor,
                        isActive: isActivelySpeaking || isResponding || !someoneSpeaking,
                        orbRadius: orbSize * 0.42
                    )
                    .scaleEffect(visualScale)
                    .allowsHitTesting(false)
                )
                .opacity(dimming)

            Text(name)
                .font(.system(size: nameSize, weight: isResponding ? .bold : .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(nameOp))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(modelName)
                .font(.system(size: modelSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25 * dimming))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func orbAudioLevels() -> [Float] {
        if isActivelySpeaking {
            return tts.audioLevels.map { min($0 * 1.8, 1.0) }
        } else if isResponding {
            let t = Float(Date.timeIntervalSinceReferenceDate)
            let pulse = Float(0.15 + sin(t * 2.0) * 0.08 + sin(t * 3.7) * 0.04)
            return Array(repeating: pulse, count: 40)
        } else {
            return Array(repeating: Float(0.05), count: 40)
        }
    }

    private func orbVisualScale() -> CGFloat {
        if isActivelySpeaking {
            let avg = avgAudioLevel
            return 1.0 + CGFloat(min(avg * 0.4, 0.12))
        } else if isResponding {
            let t = Date.timeIntervalSinceReferenceDate
            return 1.0 + CGFloat(sin(t * 2.0) * 0.03)
        } else {
            return 1.0
        }
    }

    private func orbNameOpacity() -> Double {
        if isActivelySpeaking {
            return 0.8 + min(avgAudioLevel * 0.5, 0.2)
        } else if isResponding {
            return 0.7
        } else if someoneSpeaking {
            return 0.25
        } else {
            return 0.5
        }
    }

    private func orbDimming() -> Double {
        if isActivelySpeaking || isResponding {
            return 1.0
        } else if someoneSpeaking {
            return 0.2
        } else {
            return 0.8
        }
    }
}
#endif
