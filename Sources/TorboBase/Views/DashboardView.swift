// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Main dashboard — dark, gorgeous, the Torbo at the center of everything
#if canImport(SwiftUI)
import SwiftUI
import CoreImage.CIFilterBuiltins

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var pairing = PairingManager.shared
    @State private var showUpdateConfirm = false
    @State private var isUpdating = false
    @State private var updateResult: String?

    var body: some View {

        HStack(spacing: 0) {
            // MARK: - Sidebar
            VStack(spacing: 0) {
                // Brand — the orb IS the brand
                VStack(spacing: 8) {
                    OrbRenderer(
                        audioLevels: Array(repeating: Float(0.15), count: 40),
                        color: state.accessLevel.color,
                        isActive: state.serverRunning
                    )
                    .frame(width: 160, height: 160)
                    .allowsHitTesting(false)

                    Text("TORBO BASE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(2.0)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .zIndex(1)

                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.horizontal, 12)

                // Navigation
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        sidebarSection(nil, tabs: [.home, .agents, .chambers, .conversations, .connectors])
                        sidebarSection("Automation", tabs: [.jobs, .workflows, .scheduler, .skills])
                        sidebarSection("System", tabs: [.models, .security, .iam, .governance, .teams, .calendar])
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .clipped()

                Spacer(minLength: 0)

                // Bottom — Settings + Status
                VStack(spacing: 8) {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.horizontal, 12)

                    SidebarButton(title: "Settings", icon: DashboardTab.settings.icon, isSelected: state.currentTab == .settings, info: DashboardTab.settings.info) {
                        withAnimation(.easeInOut(duration: 0.2)) { state.currentTab = .settings }
                    }
                    .padding(.horizontal, 12)

                    // Status bar
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.serverRunning ? .green : .red)
                            .frame(width: 6, height: 6)
                        Text(state.serverRunning ? "Online" : "Offline")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer()
                        Text(TorboVersion.display)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                        Button {
                            showUpdateConfirm = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdating)
                        .help("Update TORBO BASE")
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 14)
            }
            .frame(width: 220)
            .background(Color(nsColor: NSColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1)))
            .alert("Update TORBO BASE", isPresented: $showUpdateConfirm) {
                Button("Yes") { performUpdate() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Pull the latest version and rebuild?")
            }
            .alert("Update Result", isPresented: .init(
                get: { updateResult != nil },
                set: { if !$0 { updateResult = nil } }
            )) {
                Button("OK") { updateResult = nil }
            } message: {
                Text(updateResult ?? "")
            }

            // MARK: - Content area
            Group {
                switch state.currentTab {
                case .home:
                    HomeView()
                case .agents:
                    AgentsView()
                case .conversations:
                    ConversationsView()
                case .chambers:
                    ChamberView()
                case .connectors:
                    ConnectorsView()
                case .jobs:
                    JobsView()
                case .calendar:
                    CalendarDashboardView()
                case .skills:
                    SkillsView()
                case .models:
                    ModelsView()
                case .security:
                    SecurityView()
                case .iam:
                    AgentIAMDashboardView()
                case .governance:
                    GovernanceDashboardView()
                case .teams:
                    AgentTeamsView()
                case .scheduler:
                    CronSchedulerView()
                case .workflows:
                    WorkflowCanvasView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
        }
        .preferredColorScheme(.dark)
        .task {
            // Update system stats periodically
            while !Task.isCancelled {
                state.updateSystemStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Sidebar section with optional header
    @ViewBuilder
    private func sidebarSection(_ header: String?, tabs: [DashboardTab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(1.0)
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
            ForEach(tabs, id: \.self) { tab in
                SidebarButton(title: tab.rawValue, icon: tab.icon, isSelected: state.currentTab == tab, info: tab.info) {
                    withAnimation(.easeInOut(duration: 0.2)) { state.currentTab = tab }
                }
            }
        }
    }

    /// Resolve the project root directory from the running executable.
    /// In a `swift build` layout, the binary lives in `.build/release/TorboBase` or `.build/debug/TorboBase`.
    private nonisolated static var projectDir: String {
        if let exe = Bundle.main.executableURL {
            // Walk up from .build/{config}/TorboBase → project root
            let buildDir = exe.deletingLastPathComponent() // .build/release
            let dotBuild = buildDir.deletingLastPathComponent() // .build
            let root = dotBuild.deletingLastPathComponent() // project root
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                return root.path
            }
        }
        // Fallback: well-known path
        return NSString("~/Documents/ORB MASTER/Torbo Base").expandingTildeInPath
    }

    private func performUpdate() {
        isUpdating = true
        Task.detached {
            let dir = Self.projectDir
            let pullResult = Self.runShell("git -C '\(dir)' pull origin main")
            guard pullResult.status == 0 else {
                await MainActor.run {
                    isUpdating = false
                    updateResult = "Git pull failed:\n\(pullResult.output)"
                }
                return
            }
            let buildResult = Self.runShell("cd '\(dir)' && swift build -c release")
            await MainActor.run {
                isUpdating = false
                if buildResult.status == 0 {
                    updateResult = "Update complete. Restart TORBO BASE to apply."
                } else {
                    updateResult = "Build failed:\n\(String(buildResult.output.suffix(300)))"
                }
            }
        }
    }

    private nonisolated static func runShell(_ command: String) -> (output: String, status: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (output: "Failed to launch: \(error.localizedDescription)", status: -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output: output, status: process.terminationStatus)
    }
}

// MARK: - Home View (The Orb + Overview)

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var pairing = PairingManager.shared
    @State private var auditExpanded = false
    @State private var hasPlayedGreeting = UserDefaults.standard.bool(forKey: "torboFirstGreetingDone")
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "torboWelcomeDismissed")

    var body: some View {

        ScrollView {
            VStack(spacing: 20) {
                // The Torbo — hero with rainbow slider
                OrbAccessView(
                    level: $state.accessLevel,
                    onKillSwitch: { state.killSwitch() },
                    serverRunning: state.serverRunning
                )
                .padding(.top, 8)
                .padding(.horizontal, 20)

                // Welcome card for new users
                if showWelcome {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Welcome to TORBO BASE")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { showWelcome = false }
                                UserDefaults.standard.set(true, forKey: "torboWelcomeDismissed")
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            welcomeStep(icon: "circle.hexagongrid.fill", text: "Click the orb or drag the slider to set your access level")
                            welcomeStep(icon: "person.2.fill", text: "Go to Agents to create and customize AI agents")
                            welcomeStep(icon: "mic.fill", text: "Tap the orb to start a voice conversation")
                            welcomeStep(icon: "person.3.sequence.fill", text: "Use Chambers to put multiple agents in a room together")
                            welcomeStep(icon: "info.circle", text: "Look for the \(Image(systemName: "info.circle")) icon next to any sidebar item for details on what it does")
                        }

                        Text("You can dismiss this card — it won't come back.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .cornerRadius(10)
                    .padding(.horizontal, 24)
                }

                // Stats row
                HStack(spacing: 12) {
                    StatCard(label: "Requests", value: "\(state.totalRequests)", color: .white.opacity(0.6))
                    StatCard(label: "Blocked", value: "\(state.blockedRequests)", color: .red)
                    StatCard(label: "Clients", value: "\(state.connectedClients)", color: .green)
                    StatCard(label: "Models", value: "\(state.ollamaModels.count)", color: .white.opacity(0.5))
                }
                .padding(.horizontal, 24)

                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 24)

                // Network Health
                NetworkHealthView()
                    .padding(.horizontal, 24)

                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 24)

                // Quick Actions
                HStack(spacing: 8) {
                    Button {
                        let url = "http://\(state.localIP):\(state.serverPort)/chat"
                        if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
                    } label: {
                        Label("Web Chat", systemImage: "globe")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.serverRunning)

                    Button {
                        let url = "http://\(state.localIP):\(state.serverPort)/chat"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy URL", systemImage: "link")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.serverRunning)

                    Button {
                        let url = "http://\(state.localIP):\(state.serverPort)/v1/chat/completions"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy API", systemImage: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.serverRunning)

                    Spacer()
                }
                .padding(.horizontal, 24)

                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 24)

                // Connection + Pairing
                HStack(alignment: .top, spacing: 20) {
                    // Connection info
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "CONNECTION")

                        InfoRow(label: "Address", value: "\(state.localIP):\(state.serverPort)")
                        InfoRow(label: "Level", value: "\(state.accessLevel.rawValue) — \(state.accessLevel.name)")

                        HStack(spacing: 6) {
                            Text("Token")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(maskToken(state.serverToken))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(state.serverToken, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .help("Copy token")
                            Button {
                                state.regenerateToken()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .help("Regenerate")
                        }

                        if !state.ollamaModels.isEmpty {
                            HStack(spacing: 4) {
                                Text("Models")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                                Text(state.ollamaModels.prefix(3).joined(separator: ", "))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Pairing section
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "PAIR DEVICE")
                        pairingContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)

                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 24)

                // User Account Info
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "ACCOUNT")
                    HStack(spacing: 16) {
                        InfoRow(label: "User", value: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
                        InfoRow(label: "Host", value: Host.current().localizedName ?? "Unknown")
                    }
                    HStack(spacing: 16) {
                        InfoRow(label: "Agents", value: "\(state.agentAccessLevels.count)")
                        InfoRow(label: "Uptime", value: state.uptimeString)
                    }
                }
                .padding(.horizontal, 24)

                Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 24)

                // Audit log — collapsed by default
                DisclosureGroup(isExpanded: $auditExpanded) {
                    if state.auditLog.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.title3).foregroundStyle(.white.opacity(0.15))
                                Text("No activity yet")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.2))
                            }
                            .padding(.vertical, 24)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 1) {
                            ForEach(state.auditLog.prefix(20)) { entry in
                                AuditRow(entry: entry)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } label: {
                    HStack {
                        SectionHeader(title: "AUDIT LOG")
                        Spacer()
                        if !state.auditLog.isEmpty {
                            Text("\(state.totalRequests) total · \(state.blockedRequests) blocked")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }
                }
                .tint(.white.opacity(0.3))
                .padding(.horizontal, 24)

                Spacer(minLength: 16)
            }
            .padding(.vertical, 12)
        }
        .task {
            guard !hasPlayedGreeting else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            hasPlayedGreeting = true
            UserDefaults.standard.set(true, forKey: "torboFirstGreetingDone")
            VoiceEngine.shared.activate(agentID: "sid")
            // Placeholder greeting — replace with final script
            TTSManager.shared.speak("Hello! I'm SiD, your AI assistant. Welcome to Torbo Base.")
        }
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingContent: some View {
        if pairing.pairingActive {
            VStack(spacing: 12) {
                if let qrImage = generateQRCode(from: pairing.qrString) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                Text(pairing.pairingCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(.white)
                Text("Enter in Torbo app → Settings → Torbo Base")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Button("Cancel") { pairing.expireCode() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
        } else {
            VStack(spacing: 8) {
                Button {
                    pairing.generateCode(host: state.localIP, port: state.serverPort)
                } label: {
                    Label("Generate Code", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.serverRunning)

                // Paired devices
                ForEach(pairing.pairedDevices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: "iphone").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                        Text(device.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        if device.isRecent {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                        }
                        Button { pairing.unpair(deviceId: device.id) } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 10)).foregroundStyle(.red.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(4)
                }
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: scale)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private func maskToken(_ token: String) -> String {
        if token.count < 8 { return "••••••••" }
        return String(token.prefix(4)) + "••••" + String(token.suffix(4))
    }

    private func welcomeStep(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineSpacing(2)
        }
    }
}

// MARK: - Models View

struct ModelsView: View {
    @EnvironmentObject private var state: AppState
    @State private var modelToInstall: String = ""
    @State private var showInstallGuide = false
    @State private var pullError: String?

    private let recommendedModels = [
        ("llama3.2:3b", "3B params — fast, good for chat", "2.0 GB"),
        ("llama3.1:8b", "8B params — balanced performance", "4.7 GB"),
        ("qwen2.5:7b", "7B params — excellent multilingual", "4.4 GB"),
        ("mistral:7b", "7B params — fast reasoning", "4.1 GB"),
        ("codellama:13b", "13B params — code specialist", "7.4 GB"),
        ("deepseek-coder-v2:16b", "16B params — advanced coding", "8.9 GB"),
        ("llama3.1:70b", "70B params — maximum intelligence", "40 GB"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Models")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Local & cloud LLMs")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Button {
                        showInstallGuide.toggle()
                    } label: {
                        Label("Install Guide", systemImage: "questionmark.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task { await OllamaManager.shared.checkAndUpdate() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Ollama status
                if !state.ollamaRunning {
                    ollamaNotRunningBanner
                }

                // Pull model
                HStack(spacing: 8) {
                    TextField("Model name (e.g. llama3.2:3b)", text: $modelToInstall)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)

                    Button {
                        guard !modelToInstall.isEmpty else { return }
                        Task { await pullModel(modelToInstall) }
                    } label: {
                        Label("Pull", systemImage: "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(modelToInstall.isEmpty)
                }

                // Pull progress
                if let pulling = state.pullingModel {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView(value: state.pullProgress, total: 100)
                                .tint(.white.opacity(0.5))
                            Text(String(format: "%.0f%%", state.pullProgress))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text("Pulling \(pulling)...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }

                // Pull error
                if let error = pullError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Button { pullError = nil } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.2), lineWidth: 1))
                }

                // Cloud API models
                if !cloudModels.isEmpty {
                    SectionHeader(title: "CLOUD MODELS")
                    VStack(spacing: 2) {
                        ForEach(cloudModels, id: \.0) { model in
                            HStack(spacing: 10) {
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(model.2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.0)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.8))
                                    Text(model.1)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                Spacer()
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.02))
                            .cornerRadius(6)
                        }
                    }
                }

                // Installed local models (deduplicated)
                if !uniqueOllamaModels.isEmpty {
                    SectionHeader(title: "LOCAL MODELS")
                    VStack(spacing: 2) {
                        ForEach(uniqueOllamaModels, id: \.self) { model in
                            HStack(spacing: 10) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.5))
                                Text(model)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                                Spacer()
                                Button {
                                    Task { await deleteModel(model) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .help("Delete model")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(6)
                        }
                    }
                }

                // Recommended models
                SectionHeader(title: "RECOMMENDED")
                VStack(spacing: 2) {
                    ForEach(recommendedModels, id: \.0) { model in
                        HStack(spacing: 10) {
                            Image(systemName: "cube")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.3))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.0)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(model.1)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            Spacer()
                            Text(model.2)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.25))
                            if !state.ollamaModels.contains(where: { $0.hasPrefix(model.0.components(separatedBy: ":").first ?? "") }) {
                                Button {
                                    Task { await pullModel(model.0) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white.opacity(0.4))
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(6)
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .sheet(isPresented: $showInstallGuide) {
            LLMInstallGuideView()
        }
    }

    /// Deduplicated local model list
    private var uniqueOllamaModels: [String] {
        var seen = Set<String>()
        return state.ollamaModels.filter { seen.insert($0).inserted }
    }

    /// Cloud models based on configured API keys
    private var cloudModels: [(String, String, Color)] {
        var models: [(String, String, Color)] = []
        let keys = state.cloudAPIKeys
        if let k = keys["ANTHROPIC_API_KEY"], !k.isEmpty {
            models.append(("claude-opus-4-6", "Anthropic", .white.opacity(0.5)))
            models.append(("claude-sonnet-4-6-20260217", "Anthropic", .white.opacity(0.5)))
            models.append(("claude-sonnet-4-5-20250929", "Anthropic", .white.opacity(0.5)))
            models.append(("claude-haiku-4-5-20251001", "Anthropic", .white.opacity(0.5)))
        }
        if let k = keys["OPENAI_API_KEY"], !k.isEmpty {
            models.append(("gpt-4o", "OpenAI", .green))
            models.append(("gpt-4o-mini", "OpenAI", .green))
        }
        if let k = keys["GOOGLE_API_KEY"], !k.isEmpty {
            models.append(("gemini-2.5-pro-preview-06-05", "Google", .white.opacity(0.5)))
            models.append(("gemini-2.0-flash", "Google", .white.opacity(0.5)))
        }
        if let k = keys["XAI_API_KEY"], !k.isEmpty {
            models.append(("grok-4-latest", "xAI", .orange))
            models.append(("grok-3", "xAI", .orange))
            models.append(("grok-3-fast", "xAI", .orange))
        }
        return models
    }

    @ViewBuilder
    private var ollamaNotRunningBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ollama is not running")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Start Ollama to manage and use local models")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button {
                Task { await OllamaManager.shared.ensureRunning() }
            } label: {
                Text("Start")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }

    private func pullModel(_ name: String) async {
        await MainActor.run { state.pullingModel = name; state.pullProgress = 0; pullError = nil }
        guard let url = URL(string: OllamaManager.baseURL + "/api/pull") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            var buffer = ""
            for try await byte in bytes {
                let char = Character(UnicodeScalar(byte))
                if char == "\n" {
                    // Parse NDJSON line
                    if let data = buffer.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let status = json["status"] as? String ?? ""
                        let total = json["total"] as? Double ?? 0
                        let completed = json["completed"] as? Double ?? 0

                        if total > 0 {
                            let pct = (completed / total) * 100.0
                            await MainActor.run { state.pullProgress = pct }
                        } else if status == "success" {
                            await MainActor.run { state.pullProgress = 100 }
                        }
                    }
                    buffer = ""
                } else {
                    buffer.append(char)
                }
            }
            await MainActor.run { state.pullProgress = 100; state.pullingModel = nil }
            await OllamaManager.shared.checkAndUpdate()
        } catch {
            TorboLog.error("Pull error: \(error)", subsystem: "Ollama")
            await MainActor.run {
                state.pullingModel = nil
                pullError = "Failed to pull \(name): \(error.localizedDescription). Is Ollama running?"
            }
        }
    }

    private func deleteModel(_ name: String) async {
        guard let url = URL(string: OllamaManager.baseURL + "/api/delete") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        _ = try? await URLSession.shared.data(for: req)
        await OllamaManager.shared.checkAndUpdate()
    }
}

// MARK: - Conversations View

struct SpacesView: View {
    @EnvironmentObject private var state: AppState
    @State private var expandedDays: Set<String> = []
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversations")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Conversation history organized by day")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Text("\(filteredMessages.count) messages")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }

                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                    TextField("Search conversations…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

                if filteredMessages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.1))
                        Text(searchText.isEmpty ? "No conversations yet" : "No results for \"\(searchText)\"")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.3))
                        if searchText.isEmpty {
                            Text("Messages will appear here when clients connect and chat")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    // Group messages by day
                    ForEach(messagesByDay, id: \.0) { day, messages in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedDays.contains(day) || !searchText.isEmpty },
                            set: { if $0 { expandedDays.insert(day) } else { expandedDays.remove(day) } }
                        )) {
                            VStack(spacing: 4) {
                                ForEach(messages) { msg in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: msg.role == "user" ? "person.fill" : "cube.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(msg.role == "user" ? .white.opacity(0.5) : .white.opacity(0.4))
                                            .frame(width: 16)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(msg.role.capitalized)
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(msg.role == "user" ? .white.opacity(0.5) : .white.opacity(0.4))
                                                if !msg.model.isEmpty {
                                                    Text("· \(msg.model)")
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundStyle(.white.opacity(0.2))
                                                }
                                                Spacer()
                                                Text(msg.timestamp, style: .time)
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.white.opacity(0.2))
                                            }
                                            Text(msg.content)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.6))
                                                .lineLimit(searchText.isEmpty ? 4 : 8)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(msg.role == "user" ? 0.02 : 0.04))
                                    .cornerRadius(6)
                                }
                            }
                        } label: {
                            HStack {
                                Text(day)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                Spacer()
                                Text("\(messages.count) msgs")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                        }
                        .tint(.white.opacity(0.3))
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }

    /// Messages filtered by search text
    private var filteredMessages: [ConversationMessage] {
        let source = state.recentMessages.suffix(100)
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(source)
        }
        let query = searchText.lowercased()
        return source.filter {
            $0.content.lowercased().contains(query)
            || $0.role.lowercased().contains(query)
            || $0.model.lowercased().contains(query)
        }
    }

    /// Group recent messages by day label (Today, Yesterday, or date)
    private var messagesByDay: [(String, [ConversationMessage])] {
        let cal = Calendar.current
        var groups: [(String, [ConversationMessage])] = []
        var current: (String, [ConversationMessage])? = nil

        for msg in filteredMessages.reversed() {
            let dayLabel: String
            if cal.isDateInToday(msg.timestamp) {
                dayLabel = "Today"
            } else if cal.isDateInYesterday(msg.timestamp) {
                dayLabel = "Yesterday"
            } else {
                let f = DateFormatter()
                f.dateFormat = "MMM d, yyyy"
                dayLabel = f.string(from: msg.timestamp)
            }

            if current?.0 == dayLabel {
                current?.1.append(msg)
            } else {
                if let c = current { groups.append(c) }
                current = (dayLabel, [msg])
            }
        }
        if let c = current { groups.append(c) }
        return groups
    }
}

// MARK: - Security View

struct SecurityView: View {
    @EnvironmentObject private var state: AppState
    @State private var capabilitiesExpanded = false
    @State private var auditExpanded = false

    /// H9: Detect non-local IPs from audit log
    private var nonLocalIPs: [String]? {
        let localPrefixes = ["127.0.0.1", "::1", "localhost"]
        let remoteIPs = Set(state.auditLog.compactMap { entry -> String? in
            let ip = entry.clientIP
            guard !ip.isEmpty else { return nil }
            if localPrefixes.contains(where: { ip.hasPrefix($0) }) { return nil }
            return ip
        })
        return remoteIPs.isEmpty ? nil : Array(remoteIPs).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Active protections, threat monitoring, and audit")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }

                // Security status cards
                HStack(spacing: 12) {
                    SecurityMetricCard(
                        icon: "shield.checkered", label: "Access Level",
                        value: "\(state.accessLevel.rawValue) — \(state.accessLevel.name)",
                        color: state.accessLevel.color
                    )
                    SecurityMetricCard(
                        icon: "hand.raised.fill", label: "Threats Blocked",
                        value: "\(state.blockedRequests)",
                        color: state.blockedRequests > 0 ? .red : .green
                    )
                    SecurityMetricCard(
                        icon: "lock.fill", label: "Encryption",
                        value: "AES-256",
                        color: .white.opacity(0.6)
                    )
                    SecurityMetricCard(
                        icon: "network", label: "Binding",
                        value: "localhost",
                        color: .green
                    )
                }

                // H9: Non-local access warning
                if let remoteIPs = nonLocalIPs, !remoteIPs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Non-Local Access Detected")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.orange)
                            Text("Connections from: \(remoteIPs.joined(separator: ", "))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                }

                // Active protections
                SectionHeader(title: "ACTIVE PROTECTIONS")
                VStack(spacing: 2) {
                    SecurityProtectionRow(name: "Token Authentication", status: true, detail: "Bearer token required on all API routes")
                    SecurityProtectionRow(name: "Network Binding", status: true, detail: "0.0.0.0 (LAN — required for phone pairing) + bearer auth")
                    SecurityProtectionRow(name: "API Key Encryption", status: true, detail: "AES-256-CBC at rest")
                    SecurityProtectionRow(name: "Path Traversal Block", status: true, detail: "Sensitive files protected")
                    SecurityProtectionRow(name: "Shell Injection Guard", status: true, detail: "Metachar + command blocklist")
                    SecurityProtectionRow(name: "CORS Restriction", status: true, detail: "localhost only")
                    SecurityProtectionRow(name: "Email Content Sandboxing", status: true, detail: "External email marked as untrusted")
                    SecurityProtectionRow(name: "SSRF Protection", status: AppConfig.ssrfProtectionEnabled, detail: "Private IPs blocked on all tool paths")
                    SecurityProtectionRow(name: "Rate Limiting", status: state.rateLimit > 0, detail: state.rateLimit > 0 ? "\(state.rateLimit) req/min" : "Disabled")
                    SecurityProtectionRow(name: "Token Expiry", status: true, detail: "Paired device tokens expire after 30 days idle")
                    SecurityProtectionRow(name: "Webhook Secrets", status: true, detail: "Auto-generated HMAC secrets on all webhooks")
                    SecurityProtectionRow(name: "Conversation Encryption", status: true, detail: "AES-256 per-message encryption at rest")
                }

                Divider().overlay(Color.white.opacity(0.06))

                // Rate limiting
                SectionHeader(title: "RATE LIMITING")
                HStack {
                    Text("Max requests/minute:")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("", value: $state.rateLimit, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(4)
                        .frame(width: 60)
                        .onChange(of: state.rateLimit) { val in
                            AppConfig.rateLimit = val
                        }
                }

                // M6: Key rotation reminder
                if let ageDays = KeychainManager.tokenAgeDays, ageDays > 90 {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Token Rotation Recommended")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.yellow)
                            Text("Server token is \(ageDays) days old. Consider regenerating in Settings.")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.yellow.opacity(0.06))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
                }

                Divider().overlay(Color.white.opacity(0.06))

                // Global capabilities — collapsed by default
                DisclosureGroup(isExpanded: $capabilitiesExpanded) {
                    VStack(spacing: 2) {
                        ForEach(CapabilityCategory.allCases, id: \.self) { category in
                            let tools = CapabilityRegistry.byCategory[category] ?? []
                            HStack(spacing: 10) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(state.globalCapabilities[category.rawValue] == false ? .red.opacity(0.5) : .white.opacity(0.5))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(category.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(state.globalCapabilities[category.rawValue] == false ? 0.3 : 0.8))
                                    Text(tools.map { $0.toolName }.joined(separator: ", "))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.2))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { state.globalCapabilities[category.rawValue] != false },
                                    set: { enabled in
                                        if enabled {
                                            state.globalCapabilities.removeValue(forKey: category.rawValue)
                                        } else {
                                            state.globalCapabilities[category.rawValue] = false
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .scaleEffect(0.7)
                                .tint(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.02))
                            .cornerRadius(4)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.5))
                        Text("Disabled categories are hidden from ALL agents, overriding per-agent settings.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                } label: {
                    SectionHeader(title: "GLOBAL CAPABILITIES")
                }
                .tint(.white.opacity(0.3))

                Divider().overlay(Color.white.opacity(0.06))

                // Audit log — collapsed by default
                DisclosureGroup(isExpanded: $auditExpanded) {
                    if state.auditLog.isEmpty {
                        Text("No activity recorded")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.2))
                            .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(state.auditLog) { entry in
                                AuditRow(entry: entry)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } label: {
                    HStack {
                        SectionHeader(title: "FULL AUDIT LOG")
                        Spacer()
                        Text("\(state.auditLog.count) entries")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                .tint(.white.opacity(0.3))

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }
}

// MARK: - Security Helper Views

private struct SecurityMetricCard: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.15), lineWidth: 1))
    }
}

private struct SecurityProtectionRow: View {
    let name: String
    let status: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status ? Color.green : Color.red.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
        .cornerRadius(4)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var newPath = ""
    @State private var newOrigin = ""
    @State private var newCommand = ""
    @State private var showClearConfirm = false
    @State private var storageSize = "Calculating..."
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var portText = String(AppConfig.serverPort)
    @State private var portNeedsRestart = false
    @State private var keySaveTask: Task<Void, Never>?

    // All sections collapsed by default
    @State private var serverExpanded = false
    @State private var apiKeysExpanded = false
    @State private var voiceExpanded = false
    @State private var telegramExpanded = false
    @State private var discordExpanded = false
    @State private var slackExpanded = false
    @State private var whatsappExpanded = false
    @State private var emailExpanded = false
    @State private var moreBridgesExpanded = false
    @State private var signalExpanded = false
    @State private var imessageExpanded = false
    @State private var sandboxExpanded = false
    @State private var corsExpanded = false
    @State private var commandsExpanded = false
    @State private var ssrfExpanded = false
    @State private var systemPromptExpanded = false
    @State private var conversationExpanded = false
    @State private var memoryExpanded = false
    @State private var memoryEnabled = AppConfig.memoryEnabled
    @State private var memoryStats: [String: Any] = [:]

    private let systemPromptPresets: [(String, String)] = [
        ("Concise", "You are a helpful assistant. Be concise and direct. Avoid unnecessary preamble."),
        ("Coder", "You are an expert software engineer. Write clean, efficient code. Explain your reasoning briefly."),
        ("Creative", "You are a creative writing partner. Be imaginative, vivid, and original. Push boundaries."),
        ("Torbo", "You are Torbo, an AI assistant created by Perceptual Art. You are running on a local Torbo Base gateway. Be helpful, knowledgeable, and respect the user's privacy."),
    ]

    var body: some View {

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("All sections collapsed — expand what you need")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }

                // MARK: Memory (Library of Alexandria)
                DisclosureGroup(isExpanded: $memoryExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $memoryEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Memory System")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                Text("When OFF, no memories are stored or retrieved. Existing memories are preserved but inactive.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: memoryEnabled) { enabled in
                            AppConfig.memoryEnabled = enabled
                        }

                        if memoryEnabled {
                            let totalMemories = memoryStats["totalMemories"] as? Int ?? 0
                            let categories = memoryStats["categories"] as? [String: Int] ?? [:]

                            HStack(spacing: 16) {
                                VStack(spacing: 2) {
                                    Text("\(totalMemories)")
                                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Text("Total Scrolls")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)

                                VStack(spacing: 2) {
                                    Text("\(categories.count)")
                                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.4))
                                    Text("Categories")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)
                            }

                            if !categories.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(categories.sorted(by: { $0.value > $1.value }), id: \.key) { cat, count in
                                        HStack(spacing: 6) {
                                            Text(cat)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.5))
                                            Spacer()
                                            Text("\(count)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.3))
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                    }
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.02))
                                .cornerRadius(6)
                            }

                            Text("LoA (Library of Alexandria) automatically extracts, indexes, and retrieves memories from conversations. Memories are stored locally in SQLite with vector embeddings.")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("MEMORY (LIBRARY OF ALEXANDRIA)", systemImage: "brain.head.profile")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: Server
                DisclosureGroup(isExpanded: $serverExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Port:")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                            TextField("", text: $portText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(4)
                                .frame(width: 70)
                                .onSubmit { applyPort() }
                            if portNeedsRestart {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 9))
                                    Text("Restart to apply")
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(.orange.opacity(0.7))
                                Button("Restart Now") {
                                    Task {
                                        await GatewayServer.shared.stop()
                                        state.serverPort = AppConfig.serverPort
                                        await GatewayServer.shared.start(appState: state)
                                        portNeedsRestart = false
                                    }
                                }
                                .font(.system(size: 10, weight: .medium))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            } else {
                                Text("Default: 4200")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                            Spacer()
                        }
                        Toggle(isOn: $launchAtLogin) {
                            Text("Launch at login")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { enabled in
                            LaunchAtLogin.setEnabled(enabled)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("SERVER", systemImage: "server.rack")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: Cloud API Keys
                DisclosureGroup(isExpanded: $apiKeysExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional — for routing to cloud models through Torbo Base")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        ForEach(CloudProvider.allCases, id: \.self) { provider in
                            HStack(spacing: 8) {
                                Text(provider.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 140, alignment: .leading)
                                SecureField("API Key", text: cloudKeyBinding(for: provider))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("CLOUD API KEYS", systemImage: "key.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: Voice & Image
                DisclosureGroup(isExpanded: $voiceExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("For text-to-speech (ElevenLabs preferred) and image generation (DALL-E via OpenAI)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        HStack(spacing: 8) {
                            Text("ElevenLabs")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 140, alignment: .leading)
                            SecureField("API Key", text: elevenlabsKeyBinding)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(4)
                        }
                        Text("TTS: ElevenLabs if configured, falls back to OpenAI. STT: OpenAI Whisper. Images: OpenAI DALL-E.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("VOX & IMAGE", systemImage: "waveform")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: Messaging Integrations
                DisclosureGroup(isExpanded: $telegramExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Telegram", isOn: telegramEnabledBinding)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        if state.telegramConfig.enabled {
                            HStack(spacing: 8) {
                                Text("Bot Token:")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 80, alignment: .leading)
                                SecureField("token", text: telegramTokenBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.06)).cornerRadius(4)
                            }
                            HStack(spacing: 8) {
                                Text("Chat ID:")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 80, alignment: .leading)
                                TextField("chat id", text: telegramChatBinding)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.06)).cornerRadius(4)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("TELEGRAM", systemImage: "paperplane.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $discordExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        channelConfigRow(label: "Bot Token", value: Binding(
                            get: { state.discordBotToken ?? "" },
                            set: { state.discordBotToken = $0.isEmpty ? nil : $0 }
                        ), secure: true)
                        channelConfigRow(label: "Channel ID", value: Binding(
                            get: { state.discordChannelID ?? "" },
                            set: { state.discordChannelID = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("DISCORD", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $slackExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        channelConfigRow(label: "Bot Token", value: Binding(
                            get: { state.slackBotToken ?? "" },
                            set: { state.slackBotToken = $0.isEmpty ? nil : $0 }
                        ), secure: true)
                        channelConfigRow(label: "Channel ID", value: Binding(
                            get: { state.slackChannelID ?? "" },
                            set: { state.slackChannelID = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("SLACK", systemImage: "number")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $whatsappExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WhatsApp Business Cloud API")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        channelConfigRow(label: "Access Token", value: Binding(
                            get: { state.whatsappAccessToken ?? "" },
                            set: { state.whatsappAccessToken = $0.isEmpty ? nil : $0 }
                        ), secure: true)
                        channelConfigRow(label: "Phone # ID", value: Binding(
                            get: { state.whatsappPhoneNumberID ?? "" },
                            set: { state.whatsappPhoneNumberID = $0.isEmpty ? nil : $0 }
                        ))
                        channelConfigRow(label: "Verify Token", value: Binding(
                            get: { state.whatsappVerifyToken ?? "" },
                            set: { state.whatsappVerifyToken = $0.isEmpty ? nil : $0 }
                        ))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("WHATSAPP", systemImage: "phone.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $emailExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Uses AppleScript to send via Mail.app (macOS only)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Email bridge is available via the email_send agent tool.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.top, 8)
                } label: {
                    Label("EMAIL", systemImage: "envelope.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // Optional bridges — behind expand button
                DisclosureGroup(isExpanded: $moreBridgesExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        DisclosureGroup(isExpanded: $signalExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Requires signal-cli REST API running locally")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.3))
                                channelConfigRow(label: "Phone #", value: Binding(
                                    get: { state.signalPhoneNumber ?? "" },
                                    set: { state.signalPhoneNumber = $0.isEmpty ? nil : $0 }
                                ))
                                channelConfigRow(label: "API URL", value: Binding(
                                    get: { state.signalAPIURL ?? "" },
                                    set: { state.signalAPIURL = $0.isEmpty ? nil : $0 }
                                ))
                            }
                            .padding(.top, 8)
                        } label: {
                            Label("SIGNAL", systemImage: "lock.shield.fill")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .accentColor(.white.opacity(0.3))

                        optionalBridgeStub("IMESSAGE", icon: "message.fill", note: "Coming soon — requires SIP/Automation entitlement")
                        optionalBridgeStub("HOME ASSISTANT", icon: "house.fill", note: "Coming soon — HTTP webhook integration")
                        optionalBridgeStub("GOOGLE CHAT", icon: "bubble.left.fill", note: "Coming soon — Google Workspace API")
                        optionalBridgeStub("MATRIX", icon: "grid", note: "Coming soon — Matrix/Element protocol")
                        optionalBridgeStub("TEAMS", icon: "person.2.fill", note: "Coming soon — Microsoft Graph API")
                        optionalBridgeStub("SMS", icon: "text.bubble.fill", note: "Coming soon — Twilio or carrier API")
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                        Text("7 MORE BRIDGES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.25))
                }
                .accentColor(.white.opacity(0.25))

                // MARK: Sandbox & Security
                DisclosureGroup(isExpanded: $sandboxExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Directories agents can read/write. This is the single source of truth for all file access scoping.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                        VStack(spacing: 2) {
                            ForEach(AppConfig.sandboxPaths, id: \.self) { path in
                                HStack {
                                    Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                    Spacer()
                                    Button {
                                        var paths = AppConfig.sandboxPaths
                                        paths.removeAll(where: { $0 == path })
                                        AppConfig.sandboxPaths = paths
                                    } label: {
                                        Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(.red.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.white.opacity(0.02)).cornerRadius(4)
                            }
                        }
                        HStack {
                            TextField("Add path...", text: $newPath)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.06)).cornerRadius(4)
                            Button {
                                guard !newPath.isEmpty else { return }
                                var paths = AppConfig.sandboxPaths
                                paths.append(newPath)
                                AppConfig.sandboxPaths = paths
                                newPath = ""
                            } label: {
                                Image(systemName: "plus.circle").font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("SANDBOX PATHS", systemImage: "folder.badge.gearshape")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $corsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Origins allowed to make cross-origin requests. Sensitive endpoints (/exec, /v1/fetch, /v1/browser) never include CORS headers.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                        VStack(spacing: 2) {
                            ForEach(AppConfig.allowedCORSOrigins, id: \.self) { origin in
                                HStack {
                                    Image(systemName: "network").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                                    Text(origin).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                    Spacer()
                                    Button {
                                        var origins = AppConfig.allowedCORSOrigins
                                        origins.removeAll(where: { $0 == origin })
                                        AppConfig.allowedCORSOrigins = origins
                                    } label: {
                                        Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(.red.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.white.opacity(0.02)).cornerRadius(4)
                            }
                        }
                        HStack {
                            TextField("Add origin (e.g. http://localhost:3000)...", text: $newOrigin)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.06)).cornerRadius(4)
                            Button {
                                guard !newOrigin.isEmpty else { return }
                                var origins = AppConfig.allowedCORSOrigins
                                if !origins.contains(newOrigin) { origins.append(newOrigin) }
                                AppConfig.allowedCORSOrigins = origins
                                newOrigin = ""
                            } label: {
                                Image(systemName: "plus.circle").font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("CORS ALLOWED ORIGINS", systemImage: "globe")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $commandsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Commands allowed for sandboxed execution (/exec). Full access (/exec/shell) is unrestricted.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                        VStack(spacing: 2) {
                            let commands = AppConfig.allowedCommands
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                                ForEach(commands, id: \.self) { cmd in
                                    HStack(spacing: 4) {
                                        Text(cmd).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                                        Button {
                                            var cmds = AppConfig.allowedCommands
                                            cmds.removeAll(where: { $0 == cmd })
                                            AppConfig.allowedCommands = cmds
                                        } label: {
                                            Image(systemName: "xmark").font(.system(size: 7)).foregroundStyle(.red.opacity(0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.white.opacity(0.04)).cornerRadius(4)
                                }
                            }
                        }
                        HStack {
                            TextField("Add command...", text: $newCommand)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.06)).cornerRadius(4)
                            Button {
                                guard !newCommand.isEmpty else { return }
                                var cmds = AppConfig.allowedCommands
                                if !cmds.contains(newCommand) { cmds.append(newCommand) }
                                AppConfig.allowedCommands = cmds
                                newCommand = ""
                            } label: {
                                Image(systemName: "plus.circle").font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("ALLOWED COMMANDS", systemImage: "terminal.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                DisclosureGroup(isExpanded: $ssrfExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { AppConfig.ssrfProtectionEnabled },
                            set: { AppConfig.ssrfProtectionEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Block requests to private/internal IPs")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("Prevents /v1/fetch from accessing localhost, LAN, and cloud metadata endpoints.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("SSRF PROTECTION", systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: System Prompt
                DisclosureGroup(isExpanded: $systemPromptExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $state.systemPromptEnabled) {
                            Text("Inject system prompt into all conversations")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if state.systemPromptEnabled {
                            TextEditor(text: $state.systemPrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 80, maxHeight: 160)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                                .overlay(alignment: .topLeading) {
                                    if state.systemPrompt.isEmpty {
                                        Text("Enter a system prompt that will be prepended to every conversation...")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.2))
                                            .padding(12)
                                            .allowsHitTesting(false)
                                    }
                                }

                            HStack(spacing: 6) {
                                Text("Presets:")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.3))
                                ForEach(systemPromptPresets, id: \.0) { preset in
                                    Button(preset.0) {
                                        state.systemPrompt = preset.1
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("SYSTEM PROMPT", systemImage: "text.bubble.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))

                // MARK: Conversation Storage
                DisclosureGroup(isExpanded: $conversationExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Torbo Base keeps the last 200 messages in memory for fast access. Full history is persisted to disk and can be exported or cleared. Messages are stored locally — never sent to any external service.")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(state.recentMessages.count) messages in memory")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(storageSize)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            Spacer()
                            Button {
                                Task {
                                    if let url = await ConversationStore.shared.exportConversations() {
                                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                                    }
                                }
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                showClearConfirm = true
                            } label: {
                                Label("Clear All", systemImage: "trash")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("CONVERSATION STORAGE", systemImage: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .accentColor(.white.opacity(0.3))
                .alert("Clear All Conversations?", isPresented: $showClearConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        Task { await ConversationStore.shared.clearAll() }
                        state.recentMessages.removeAll()
                        state.sessions.removeAll()
                    }
                } message: {
                    Text("This permanently deletes all stored conversation history. This cannot be undone.")
                }

                // MARK: Legal & Principles
                SectionHeader(title: "LEGAL & PRINCIPLES")
                VStack(alignment: .leading, spacing: 8) {
                    legalLinkRow(icon: "shield.checkmark.fill", title: "Our Principles", subtitle: "The Torbo Constitution", color: .white.opacity(0.5), path: "/legal/torbo-constitution.html")
                    legalLinkRow(icon: "doc.text.fill", title: "Terms of Service", subtitle: "Service agreement", color: .white.opacity(0.5), path: "/legal/terms-of-service.html")
                    legalLinkRow(icon: "lock.fill", title: "Privacy Policy", subtitle: "How we handle your data", color: .green, path: "/legal/privacy-policy.html")
                    legalLinkRow(icon: "exclamationmark.triangle.fill", title: "Acceptable Use", subtitle: "Usage guidelines", color: .yellow, path: "/legal/acceptable-use-policy.html")
                }

                // MARK: About
                SectionHeader(title: "ABOUT")
                Text(Legal.aboutText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .task {
            storageSize = "On disk: " + (await ConversationStore.shared.storageSizeFormatted())
            memoryStats = await MemoryRouter.shared.getStats()
        }
    }

    private func cloudKeyBinding(for provider: CloudProvider) -> Binding<String> {
        Binding(
            get: { state.cloudAPIKeys[provider.keyName] ?? "" },
            set: { newValue in
                state.cloudAPIKeys[provider.keyName] = newValue
                keySaveTask?.cancel()
                keySaveTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    AppConfig.cloudAPIKeys = state.cloudAPIKeys
                }
            }
        )
    }

    private var elevenlabsKeyBinding: Binding<String> {
        Binding(
            get: { state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "" },
            set: { newValue in
                state.cloudAPIKeys["ELEVENLABS_API_KEY"] = newValue
                keySaveTask?.cancel()
                keySaveTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    AppConfig.cloudAPIKeys = state.cloudAPIKeys
                }
            }
        )
    }

    private var telegramEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.telegramConfig.enabled },
            set: { state.telegramConfig.enabled = $0; AppConfig.telegramConfig = state.telegramConfig }
        )
    }

    private var telegramTokenBinding: Binding<String> {
        Binding(
            get: { state.telegramConfig.botToken },
            set: { state.telegramConfig.botToken = $0; AppConfig.telegramConfig = state.telegramConfig }
        )
    }

    private var telegramChatBinding: Binding<String> {
        Binding(
            get: { state.telegramConfig.chatId },
            set: { state.telegramConfig.chatId = $0; AppConfig.telegramConfig = state.telegramConfig }
        )
    }

    @ViewBuilder
    private func channelConfigRow(label: String, value: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 90, alignment: .leading)
            if secure {
                SecureField(label.lowercased(), text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
            } else {
                TextField(label.lowercased(), text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
            }
        }
    }

    private func optionalBridgeStub(_ name: String, icon: String, note: String) -> some View {
        HStack(spacing: 8) {
            Label(name, systemImage: icon)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
            Spacer()
            Text(note)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.15))
        }
        .padding(.vertical, 4)
    }

    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024, port <= 65535 else {
            portText = String(state.serverPort)
            return
        }
        if port != state.serverPort {
            AppConfig.serverPort = port
            portNeedsRestart = true
        }
    }

    private func legalLinkRow(icon: String, title: String, subtitle: String, color: Color, path: String) -> some View {
        Button {
            let urlStr = "http://\(state.localIP):\(state.serverPort)\(path)"
            if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LLM Install Guide

struct LLMInstallGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install Your Own LLM")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Run language models locally on your Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(Color.white.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Step 1
                    installStep(number: 1, title: "Install Ollama", content: """
                    Ollama is the engine that runs LLMs locally on your Mac.

                    Option A — Download from ollama.com:
                    1. Visit https://ollama.com/download
                    2. Download the macOS app
                    3. Drag to Applications and open

                    Option B — Install via Homebrew:
                    brew install ollama
                    """)

                    // Step 2
                    installStep(number: 2, title: "Pull a Model", content: """
                    Once Ollama is running, open Terminal and pull a model:

                    ollama pull llama3.2:3b     # Small, fast (2 GB)
                    ollama pull qwen2.5:7b      # Balanced (4.4 GB)
                    ollama pull llama3.1:8b      # Great all-rounder (4.7 GB)
                    ollama pull codellama:13b    # For coding (7.4 GB)

                    Or use the Models tab in Torbo Base to pull directly.
                    """)

                    // Step 3
                    installStep(number: 3, title: "Connect Torbo", content: """
                    Torbo Base automatically detects Ollama and your models.

                    1. Make sure Ollama is running (check menu bar)
                    2. Torbo Base will show "Ollama ●" in the sidebar
                    3. Your models appear in the Models tab
                    4. Connect your iPhone via the Pair Device section
                    """)

                    // Step 4
                    installStep(number: 4, title: "Advanced: Custom Models", content: """
                    Create custom models with a Modelfile:

                    FROM llama3.1:8b
                    SYSTEM "You are a helpful coding assistant."
                    PARAMETER temperature 0.7

                    Save as Modelfile, then:
                    ollama create my-coder -f Modelfile
                    """)

                    // Hardware guide
                    installStep(number: 5, title: "Hardware Guide", content: """
                    Model size vs RAM requirements:

                    • 3B params → 4 GB RAM (any Mac)
                    • 7-8B params → 8 GB RAM (M1/M2/M3)
                    • 13B params → 16 GB RAM
                    • 34B params → 32 GB RAM
                    • 70B params → 64 GB RAM (M2/M3 Max/Ultra)

                    Apple Silicon Macs run LLMs using the unified memory
                    architecture — no GPU required.
                    """)
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func installStep(number: Int, title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.3)))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 30)
        }
    }
}

// MARK: - Shared Components

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.2))
            .tracking(1)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.06))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.1), lineWidth: 1))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .textSelection(.enabled)
        }
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var info: String? = nil
    let action: () -> Void

    @State private var showInfo = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                if info != nil {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(isSelected ? 0.3 : 0.15))
                        .onTapGesture {
                            showInfo.toggle()
                        }
                        .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.7))
                                    Text(title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                Text(info ?? "")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(width: 260)
                            .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)))
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AuditRow: View {
    let entry: AuditEntry
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.granted ? Color.green : Color.red)
                .frame(width: 5, height: 5)
            Text(entry.timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
            Text(entry.method)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text(entry.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer()
            Text(entry.detail)
                .font(.system(size: 10))
                .foregroundStyle(entry.granted ? .white.opacity(0.3) : .red.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(entry.granted ? Color.white.opacity(0.02) : Color.red.opacity(0.04))
    }
}

// MARK: - Preview

#Preview {
    DashboardView()
        .environmentObject(AppState.shared)
        .frame(width: 800, height: 700)
}

// MARK: - Launch at Login

#if canImport(ServiceManagement)
import ServiceManagement
#endif

enum LaunchAtLogin {
    static var isEnabled: Bool {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        #endif
        return false
    }

    static func setEnabled(_ enabled: Bool) {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                TorboLog.error("Error: \(error)", subsystem: "LaunchAtLogin")
            }
        }
        #endif
    }
}

// MARK: - Agent Power Button (persists on all windows)

/// Pause/resume the active voice agent — visible on every tab.
struct AgentPowerButton: View {
    @ObservedObject private var voiceEngine = VoiceEngine.shared

    private var isActive: Bool { voiceEngine.isActive }

    var body: some View {
        Button {
            if isActive {
                voiceEngine.deactivate()
            } else {
                voiceEngine.activate(agentID: voiceEngine.activeAgentID)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                if isActive {
                    Text(voiceEngine.activeAgentID.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(isActive ? .green : .white.opacity(0.35))
            .padding(.horizontal, isActive ? 10 : 8)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.4))
                    .overlay(Capsule().stroke(isActive ? Color.green.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "Pause \(voiceEngine.activeAgentID)" : "Resume agent")
    }
}
#endif
