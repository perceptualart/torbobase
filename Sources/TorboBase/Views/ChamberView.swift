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

    enum ChamberViewMode: String, CaseIterable {
        case voice = "Voice"
        case chat = "Chat"
        case settings = "Settings"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — Chamber list
            chamberListPanel
                .frame(width: 240)

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
            // Black background with orbs
            ZStack {
                Color.black

                // Arrange orbs based on count
                orbArrangement(chamber)

                // Status text
                VStack {
                    Spacer()
                    if let respondingID = manager.respondingAgentID {
                        let name = agents.first(where: { $0.id == respondingID })?.name ?? respondingID
                        Text("\(name) is speaking...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.bottom, 8)
                    }
                }
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Input bar
            chamberInputBar(chamber)
        }
    }

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
        let orbSize: CGFloat = count <= 4 ? 480 : 360
        let pos = orbPosition(index: index, count: count, center: center, radius: radius)
        let levels: [Float] = isSpeaking ? tts.audioLevels : Array(repeating: Float(0.08), count: 40)
        let orbColor = AccessLevel(rawValue: accessLevel)?.color ?? Color.cyan
        let displaySize = isSpeaking ? orbSize * 1.1 : orbSize

        ZStack {
            VStack(spacing: 12) {
                ZStack {
                    OrbRenderer(
                        audioLevels: levels,
                        color: orbColor,
                        isActive: true
                    )
                    .frame(width: displaySize, height: displaySize)
                    .animation(.easeInOut(duration: 0.3), value: isSpeaking)
                }

                Text(name)
                    .font(.system(size: 40, weight: isSpeaking ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(isSpeaking ? .white : .white.opacity(0.5))
            }

            // Thought bubble when speaking
            if isSpeaking, let lastMsg = manager.messages.last(where: { $0.agentID == agentID && $0.role == "assistant" }) {
                thoughtBubble(text: lastMsg.content, orbSize: displaySize)
                    .offset(x: displaySize * 0.45, y: -displaySize * 0.35)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .animation(.easeOut(duration: 0.25), value: isSpeaking)
            }
        }
        .position(pos)
        .onTapGesture {
            inputText = "@\(name) " + inputText
        }
    }

    private func thoughtBubble(text: String, orbSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                )
            // Tail dots
            HStack(spacing: 4) {
                Spacer()
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .frame(width: 10, height: 10)
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .frame(width: 6, height: 6)
                Spacer().frame(width: 20)
            }
            .offset(y: -2)
        }
        .frame(maxWidth: 240)
    }

    private func orbArrangement(_ chamber: Chamber) -> some View {
        let count = chamber.agentIDs.count
        return GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 - 40)
            let radius = min(geo.size.width, geo.size.height) * 0.35

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
                }

                // Agent roster
                VStack(alignment: .leading, spacing: 8) {
                    Text("AGENTS IN CHAMBER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))

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
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(6)
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    // MARK: - Input Bar

    private func chamberInputBar(_ chamber: Chamber) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Mic button
            Button {
                if voiceEngine.isActive && voiceEngine.state == .listening {
                    voiceEngine.stopSpeaking()
                    voiceEngine.deactivate()
                } else {
                    voiceEngine.activate(agentID: chamber.agentIDs.first ?? "sid")
                    voiceEngine.listen()
                }
            } label: {
                Image(systemName: voiceEngine.state == .listening ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(voiceEngine.state == .listening ? .green : .white.opacity(0.3))
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

        sendTask?.cancel()
        sendTask = Task {
            await manager.sendChamberMessage(text, chamberID: chamber.id) { agentID, agentName, response in
                // TTS for each agent response
                if state.voiceEnabled && !response.isEmpty {
                    tts.speak(response)
                }
            }
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
