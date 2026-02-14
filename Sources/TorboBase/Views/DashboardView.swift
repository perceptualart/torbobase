// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
// Main dashboard — dark, gorgeous, the Torbo at the center of everything
#if canImport(SwiftUI)
import SwiftUI
import CoreImage.CIFilterBuiltins

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @ObservedObject private var pairing = PairingManager.shared

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            // Sidebar
            VStack(spacing: 0) {
                // Logo header
                VStack(spacing: 8) {
                    OrbRenderer(
                        audioLevels: Array(repeating: Float(0.15), count: 40),
                        color: state.accessLevel.color,
                        isActive: state.serverRunning
                    )
                    .frame(width: 80, height: 80)
                    .scaleEffect(0.6)
                    .allowsHitTesting(false)

                    Text("TORBO BASE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(3)
                }
                .padding(.vertical, 16)

                Divider().overlay(Color.white.opacity(0.06))

                // Nav items
                VStack(spacing: 2) {
                    ForEach(DashboardTab.allCases, id: \.self) { tab in
                        SidebarButton(
                            title: tab.rawValue,
                            icon: tab.icon,
                            isSelected: state.currentTab == tab
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                state.currentTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)

                Spacer()

                // Status footer
                VStack(spacing: 6) {
                    Divider().overlay(Color.white.opacity(0.06))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.serverRunning ? state.accessLevel.color : .red)
                            .frame(width: 6, height: 6)
                        Text(state.statusSummary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.ollamaRunning ? .green : .red.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(state.ollamaRunning ? "Ollama" : "Ollama offline")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Text(TorboVersion.display)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.15))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(minWidth: 160, maxWidth: 180)
            .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)))
        } detail: {
            // Content area
            Group {
                switch state.currentTab {
                case .home:
                    HomeView()
                case .agents:
                    AgentsView()
                case .skills:
                    SkillsView()
                case .models:
                    ModelsView()
                case .sessions:
                    SessionsView()
                case .security:
                    SecurityView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .task {
            // Update system stats periodically
            while !Task.isCancelled {
                state.updateSystemStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

// MARK: - Home View (The Orb + Overview)

struct HomeView: View {
    @Environment(AppState.self) private var state
    @ObservedObject private var pairing = PairingManager.shared

    var body: some View {
        @Bindable var state = state

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

                // Stats row
                HStack(spacing: 12) {
                    StatCard(label: "Requests", value: "\(state.totalRequests)", color: .cyan)
                    StatCard(label: "Blocked", value: "\(state.blockedRequests)", color: .red)
                    StatCard(label: "Clients", value: "\(state.connectedClients)", color: .green)
                    StatCard(label: "Models", value: "\(state.ollamaModels.count)", color: .purple)
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
                        let url = "http://\(state.localIP):\(state.serverPort)/chat?token=\(state.serverToken)"
                        if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
                    } label: {
                        Label("Web Chat", systemImage: "globe")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!state.serverRunning)

                    Button {
                        let url = "http://\(state.localIP):\(state.serverPort)/chat?token=\(state.serverToken)"
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

                // Audit log
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionHeader(title: "AUDIT LOG")
                        Spacer()
                        if !state.auditLog.isEmpty {
                            Text("\(state.totalRequests) total · \(state.blockedRequests) blocked")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.2))
                        }
                    }

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
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 16)
            }
            .padding(.vertical, 12)
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
}

// MARK: - Models View

struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var modelToInstall: String = ""
    @State private var showInstallGuide = false

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
                        Text("Manage your local LLMs")
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
                                .tint(.cyan)
                            Text(String(format: "%.0f%%", state.pullProgress))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text("Pulling \(pulling)...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(10)
                    .background(Color.cyan.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.1), lineWidth: 1))
                }

                // Installed models
                if !state.ollamaModels.isEmpty {
                    SectionHeader(title: "INSTALLED")
                    VStack(spacing: 2) {
                        ForEach(state.ollamaModels, id: \.self) { model in
                            HStack(spacing: 10) {
                                Image(systemName: "cube.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.cyan.opacity(0.7))
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
                                .foregroundStyle(.purple.opacity(0.5))
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
                                .foregroundStyle(.cyan.opacity(0.6))
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
        await MainActor.run { state.pullingModel = name; state.pullProgress = 0 }
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
            await MainActor.run { state.pullingModel = nil }
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

// MARK: - Sessions View

struct SessionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sessions")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Conversation history from connected clients")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Text("\(state.recentMessages.count) messages")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }

                if state.recentMessages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.1))
                        Text("No conversations yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Messages will appear here when clients connect and chat")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    VStack(spacing: 4) {
                        ForEach(state.recentMessages.suffix(50).reversed()) { msg in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: msg.role == "user" ? "person.fill" : "cube.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(msg.role == "user" ? .blue : .cyan)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(msg.role.capitalized)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(msg.role == "user" ? .blue : .cyan)
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
                                        .lineLimit(4)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(msg.role == "user" ? 0.02 : 0.04))
                            .cornerRadius(6)
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }
}

// MARK: - Security View

struct SecurityView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Access control, sandboxing, and audit")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }

                // Access level detail
                SectionHeader(title: "ACCESS LEVEL")
                VStack(spacing: 2) {
                    ForEach(AccessLevel.allCases, id: \.rawValue) { lvl in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(lvl == state.accessLevel ? lvl.color : lvl.color.opacity(0.2))
                                .frame(width: 10, height: 10)
                            Text("\(lvl.rawValue)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 16)
                            Text(lvl.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(lvl == state.accessLevel ? lvl.color : .white.opacity(0.4))
                                .frame(width: 50, alignment: .leading)
                            Text(lvl.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            Spacer()
                            if lvl == state.accessLevel {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(lvl.color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(lvl.color.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(lvl == state.accessLevel ? Color.white.opacity(0.04) : .clear)
                        .cornerRadius(4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if lvl != .fullAccess {
                                withAnimation { state.accessLevel = lvl }
                            }
                        }
                    }
                }

                // Sandbox paths
                SectionHeader(title: "SANDBOX PATHS")
                VStack(spacing: 2) {
                    ForEach(AppConfig.sandboxPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.cyan.opacity(0.5))
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(4)
                    }
                }

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
                        .onChange(of: state.rateLimit) { _, val in
                            AppConfig.rateLimit = val
                        }
                }

                // Global capability limits
                SectionHeader(title: "GLOBAL CAPABILITIES")
                VStack(spacing: 2) {
                    ForEach(CapabilityCategory.allCases, id: \.self) { category in
                        let tools = CapabilityRegistry.byCategory[category] ?? []
                        HStack(spacing: 10) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(state.globalCapabilities[category.rawValue] == false ? .red.opacity(0.5) : .cyan)
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
                            .tint(.cyan)
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

                // Audit log full view
                SectionHeader(title: "FULL AUDIT LOG")
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

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var newPath = ""
    @State private var showClearConfirm = false
    @State private var storageSize = "Calculating..."
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var portText = String(AppConfig.serverPort)
    @State private var portNeedsRestart = false

    private let systemPromptPresets: [(String, String)] = [
        ("Concise", "You are a helpful assistant. Be concise and direct. Avoid unnecessary preamble."),
        ("Coder", "You are an expert software engineer. Write clean, efficient code. Explain your reasoning briefly."),
        ("Creative", "You are a creative writing partner. Be imaginative, vivid, and original. Push boundaries."),
        ("Torbo", "You are Torbo, an AI assistant created by Perceptual Art. You are running on a local Torbo Base gateway. Be helpful, knowledgeable, and respect the user's privacy."),
    ]

    var body: some View {
        @Bindable var state = state

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Configure Torbo Base")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }

                // Server
                SectionHeader(title: "SERVER")
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
                .onChange(of: launchAtLogin) { _, enabled in
                    LaunchAtLogin.setEnabled(enabled)
                }

                // Cloud API Keys
                SectionHeader(title: "CLOUD API KEYS")
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

                // Voice / Image API Keys
                SectionHeader(title: "VOICE & IMAGE")
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
                Text("TTS: Uses ElevenLabs if configured, falls back to OpenAI. STT: Uses OpenAI Whisper. Images: Uses OpenAI DALL-E.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.2))

                // Telegram
                SectionHeader(title: "TELEGRAM INTEGRATION")
                Text("Forward conversations and notifications to Telegram")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))

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
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    HStack(spacing: 8) {
                        Text("Chat ID:")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 80, alignment: .leading)
                        TextField("chat id", text: telegramChatBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                }

                // Discord
                SectionHeader(title: "DISCORD")
                channelConfigRow(label: "Bot Token", value: Binding(
                    get: { state.discordBotToken ?? "" },
                    set: { state.discordBotToken = $0.isEmpty ? nil : $0 }
                ), secure: true)
                channelConfigRow(label: "Channel ID", value: Binding(
                    get: { state.discordChannelID ?? "" },
                    set: { state.discordChannelID = $0.isEmpty ? nil : $0 }
                ))

                // Slack
                SectionHeader(title: "SLACK")
                channelConfigRow(label: "Bot Token", value: Binding(
                    get: { state.slackBotToken ?? "" },
                    set: { state.slackBotToken = $0.isEmpty ? nil : $0 }
                ), secure: true)
                channelConfigRow(label: "Channel ID", value: Binding(
                    get: { state.slackChannelID ?? "" },
                    set: { state.slackChannelID = $0.isEmpty ? nil : $0 }
                ))

                // WhatsApp
                SectionHeader(title: "WHATSAPP")
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

                // Signal
                SectionHeader(title: "SIGNAL")
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

                // iMessage (macOS only)
                SectionHeader(title: "IMESSAGE")
                Text("Uses AppleScript — macOS only, no config needed")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))

                // Sandbox paths management
                SectionHeader(title: "SANDBOX PATHS")
                VStack(spacing: 2) {
                    ForEach(AppConfig.sandboxPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.cyan.opacity(0.4))
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
                    .foregroundStyle(.cyan.opacity(0.6))
                }

                // System Prompt
                SectionHeader(title: "SYSTEM PROMPT")
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

                        // Preset buttons
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

                Divider().overlay(Color.white.opacity(0.06))

                // Conversation Storage
                SectionHeader(title: "CONVERSATION STORAGE")
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

                // Legal
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
        }
    }

    private func cloudKeyBinding(for provider: CloudProvider) -> Binding<String> {
        Binding(
            get: { state.cloudAPIKeys[provider.keyName] ?? "" },
            set: { newValue in
                state.cloudAPIKeys[provider.keyName] = newValue
                AppConfig.cloudAPIKeys = state.cloudAPIKeys
            }
        )
    }

    private var elevenlabsKeyBinding: Binding<String> {
        Binding(
            get: { state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "" },
            set: { newValue in
                state.cloudAPIKeys["ELEVENLABS_API_KEY"] = newValue
                AppConfig.cloudAPIKeys = state.cloudAPIKeys
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
                    .background(Circle().fill(.cyan))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.white.opacity(0.08) : .clear)
            .cornerRadius(6)
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
        .environment(AppState.shared)
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
#endif
