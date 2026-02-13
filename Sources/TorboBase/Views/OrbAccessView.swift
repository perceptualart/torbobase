// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// The Torbo replaces the dial — a living, breathing access control interface
// v2: Giant orb + rainbow slider + network health
#if canImport(SwiftUI)
import SwiftUI

/// The Torbo access control — giant orb with rainbow slider beneath.
struct OrbAccessView: View {
    @Binding var level: AccessLevel
    var onKillSwitch: () -> Void = {}
    var serverRunning: Bool = false

    @State private var confirmingFull = false
    @State private var simulatedLevels: [Float] = Array(repeating: 0.15, count: 40)
    @State private var sliderDragging = false

    var body: some View {
        VStack(spacing: 16) {
            // The Torbo — massive, alive, the hero
            ZStack {
                // Ambient glow behind orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [orbColor.opacity(0.25), orbColor.opacity(0.05), .clear],
                            center: .center,
                            startRadius: 40,
                            endRadius: 180
                        )
                    )
                    .frame(width: 340, height: 340)
                    .blur(radius: 30)

                OrbRenderer(
                    audioLevels: simulatedLevels,
                    color: orbColor,
                    isActive: level != .off && serverRunning
                )
                .frame(width: 280, height: 280)
                .opacity(level == .off ? 0.3 : 1.0)
                .contentShape(Circle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.2)) { onKillSwitch() }
                }

                // Level overlay
                VStack(spacing: 2) {
                    Text(level == .off ? "OFF" : "\(level.rawValue)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: orbColor.opacity(0.5), radius: 8)
                    Text(level.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .allowsHitTesting(false)
            }

            // Description
            Text(level.description)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(height: 18)

            // Rainbow slider
            RainbowAccessSlider(level: $level, confirmingFull: $confirmingFull)
                .frame(height: 48)
                .padding(.horizontal, 8)

            // Kill switch
            Button(action: {
                withAnimation(.spring(response: 0.2)) { onKillSwitch() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: level == .off ? "bolt.fill" : "power")
                        .font(.system(size: 11, weight: .bold))
                    Text(level == .off ? "CONNECT" : "KILL SWITCH")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(level == .off ? Color.cyan.opacity(0.7) : Color.red.opacity(0.7))
                        .shadow(color: level == .off ? .cyan.opacity(0.3) : .red.opacity(0.3), radius: 6)
                )
            }
            .buttonStyle(.plain)
        }
        .task {
            while !Task.isCancelled {
                updateSimulatedLevels()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        .alert("Enable Full Access?", isPresented: $confirmingFull) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Full Access", role: .destructive) {
                withAnimation(.spring(response: 0.3)) { level = .fullAccess }
            }
        } message: {
            Text("This gives LLMs unrestricted access to your system including shell commands with no filtering. Use with extreme caution.")
        }
    }

    private var orbColor: Color {
        switch level {
        case .off: return Color(hue: 0, saturation: 0, brightness: 0.3)
        case .chatOnly: return Color(hue: 0.35, saturation: 0.85, brightness: 0.9)     // Green
        case .readFiles: return Color(hue: 0.52, saturation: 0.9, brightness: 1.0)      // Cyan
        case .writeFiles: return Color(hue: 0.14, saturation: 0.9, brightness: 1.0)     // Gold/Yellow
        case .execute: return Color(hue: 0.07, saturation: 0.95, brightness: 1.0)       // Orange
        case .fullAccess: return Color(hue: 0.0, saturation: 0.9, brightness: 1.0)      // Red
        }
    }

    private func updateSimulatedLevels() {
        let t = Date.timeIntervalSinceReferenceDate
        let baseLevel: Float = level == .off ? 0.08 : (serverRunning ? 0.18 : 0.12)
        let variation: Float = level == .off ? 0.02 : (serverRunning ? 0.08 : 0.04)
        simulatedLevels = (0..<40).map { i in
            let phase = Float(t * 0.5 + Double(i) * 0.15)
            return baseLevel + sin(phase) * variation + sin(phase * 2.3) * variation * 0.5
        }
    }
}

// MARK: - Rainbow Access Slider

/// A horizontal slider with a soft blurry GYOR rainbow bar.
/// Green (safe) on left → Yellow → Orange → Red (danger) on right.
struct RainbowAccessSlider: View {
    @Binding var level: AccessLevel
    @Binding var confirmingFull: Bool
    @State private var dragOffset: CGFloat? = nil

    private let levelCount: CGFloat = 6 // 0-5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbX = positionForLevel(level, width: w)

            ZStack(alignment: .leading) {
                // Rainbow track — soft, blurry, beautiful
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: 0.0, saturation: 0, brightness: 0.25),   // Off/gray
                                Color(hue: 0.35, saturation: 0.7, brightness: 0.7), // Green
                                Color(hue: 0.50, saturation: 0.7, brightness: 0.7), // Cyan
                                Color(hue: 0.15, saturation: 0.8, brightness: 0.8), // Yellow
                                Color(hue: 0.07, saturation: 0.85, brightness: 0.85), // Orange
                                Color(hue: 0.0, saturation: 0.85, brightness: 0.8),  // Red
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 8)
                    .blur(radius: 2)
                    .padding(.horizontal, 14)

                // Sharper overlay track for clarity
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: 0.0, saturation: 0, brightness: 0.2).opacity(0.6),
                                Color(hue: 0.35, saturation: 0.6, brightness: 0.6).opacity(0.6),
                                Color(hue: 0.50, saturation: 0.6, brightness: 0.6).opacity(0.6),
                                Color(hue: 0.15, saturation: 0.7, brightness: 0.7).opacity(0.6),
                                Color(hue: 0.07, saturation: 0.75, brightness: 0.75).opacity(0.6),
                                Color(hue: 0.0, saturation: 0.75, brightness: 0.7).opacity(0.6),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 4)
                    .padding(.horizontal, 14)

                // Level tick marks
                ForEach(0..<6, id: \.self) { i in
                    let lv = AccessLevel(rawValue: i)!
                    let x = positionForLevel(lv, width: w)

                    VStack(spacing: 3) {
                        // Tick
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i <= level.rawValue ? lv.color.opacity(0.8) : .white.opacity(0.15))
                            .frame(width: 2, height: i == level.rawValue ? 14 : 8)

                        // Label
                        Text(lv.name)
                            .font(.system(size: 8, weight: i == level.rawValue ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(i == level.rawValue ? lv.color : .white.opacity(0.25))
                    }
                    .position(x: x, y: geo.size.height / 2 + 4)
                    .contentShape(Rectangle().size(width: w / levelCount, height: geo.size.height))
                    .onTapGesture {
                        selectLevel(i)
                    }
                }

                // Thumb
                Circle()
                    .fill(level.color)
                    .frame(width: 20, height: 20)
                    .shadow(color: level.color.opacity(0.6), radius: 6)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.3), lineWidth: 1.5)
                    )
                    .position(x: dragOffset ?? thumbX, y: geo.size.height / 2 - 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                let clamped = max(14, min(w - 14, val.location.x))
                                dragOffset = clamped
                                let newLevel = levelFromPosition(clamped, width: w)
                                if newLevel != level {
                                    selectLevel(newLevel.rawValue)
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.2)) {
                                    dragOffset = nil
                                }
                            }
                    )
            }
        }
    }

    private func positionForLevel(_ lv: AccessLevel, width: CGFloat) -> CGFloat {
        let usable = width - 28 // padding
        return 14 + usable * (CGFloat(lv.rawValue) / (levelCount - 1))
    }

    private func levelFromPosition(_ x: CGFloat, width: CGFloat) -> AccessLevel {
        let usable = width - 28
        let normalized = (x - 14) / usable
        let index = Int(round(normalized * (levelCount - 1)))
        let clamped = max(0, min(5, index))
        return AccessLevel(rawValue: clamped)!
    }

    private func selectLevel(_ i: Int) {
        guard let newLevel = AccessLevel(rawValue: i) else { return }
        if newLevel == .fullAccess {
            confirmingFull = true
        } else {
            withAnimation(.spring(response: 0.3)) { level = newLevel }
        }
    }
}

// MARK: - System Status Panel

private struct HealthSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.2))
            .tracking(1)
    }
}

/// Live system status for all connected services — grouped by category.
/// Renamed from "Network Health" to "System Status" to avoid implying
/// that the user's internet is down when local services aren't running.
struct NetworkHealthView: View {
    @Environment(AppState.self) private var state
    @State private var localChecks: [HealthCheck] = []
    @State private var remoteChecks: [HealthCheck] = []
    @State private var cloudChecks: [HealthCheck] = []
    @State private var isChecking = false
    @State private var lastCheckTime: Date?

    struct HealthCheck: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        var status: Status
        var latency: String
        var detail: String

        enum Status { case ok, warning, error, checking }

        var color: Color {
            switch status {
            case .ok: return .green
            case .warning: return .yellow
            case .error: return .red
            case .checking: return .white.opacity(0.3)
            }
        }

        var statusIcon: String {
            switch status {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .checking: return "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HealthSectionHeader(title: "SYSTEM STATUS")
                Spacer()
                if let time = lastCheckTime {
                    Text(time, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                }
                Button {
                    Task { await runChecks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .rotationEffect(.degrees(isChecking ? 360 : 0))
                        .animation(isChecking ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isChecking)
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }

            if localChecks.isEmpty && remoteChecks.isEmpty && cloudChecks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.5)
                        .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                let columns = [GridItem(.flexible()), GridItem(.flexible())]

                // Local Services
                if !localChecks.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("LOCAL SERVICES")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                            .tracking(0.5)
                    }
                    .padding(.top, 2)

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(localChecks) { check in
                            healthCheckRow(check)
                        }
                    }
                }

                // Remote Access
                if !remoteChecks.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("REMOTE ACCESS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                            .tracking(0.5)
                    }
                    .padding(.top, 4)

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(remoteChecks) { check in
                            healthCheckRow(check)
                        }
                    }
                }

                // Cloud Providers
                if !cloudChecks.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("CLOUD PROVIDERS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                            .tracking(0.5)
                    }
                    .padding(.top, 4)

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(cloudChecks) { check in
                            healthCheckRow(check)
                        }
                    }
                }
            }
        }
        .task {
            await runChecks()
            // Auto-refresh every 30 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await runChecks()
            }
        }
    }

    @ViewBuilder
    private func healthCheckRow(_ check: HealthCheck) -> some View {
        HStack(spacing: 6) {
            Image(systemName: check.statusIcon)
                .font(.system(size: 9))
                .foregroundStyle(check.color)
                .frame(width: 12)
            Image(systemName: check.icon)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 12)
            Text(check.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer()
            if !check.latency.isEmpty {
                Text(check.latency)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
        .cornerRadius(4)
        .help(check.detail)
    }

    private func runChecks() async {
        isChecking = true

        var local: [HealthCheck] = []
        var remote: [HealthCheck] = []
        var cloud: [HealthCheck] = []

        // ── Local Services ──

        local.append(HealthCheck(
            name: "Gateway",
            icon: "server.rack",
            status: state.serverRunning ? .ok : .error,
            latency: state.serverRunning ? ":\(state.serverPort)" : "",
            detail: state.serverRunning ? "Listening on port \(state.serverPort)" : "Server not running"
        ))

        let ollamaResult = await pingURL("http://127.0.0.1:11434/api/tags")
        local.append(HealthCheck(
            name: "Ollama",
            icon: "cube.fill",
            status: ollamaResult.ok ? .ok : .error,
            latency: ollamaResult.ok ? "\(ollamaResult.ms)ms" : "",
            detail: ollamaResult.ok ? "\(state.ollamaModels.count) models loaded" : "Not responding — start Ollama"
        ))

        let hasEmbedding = state.ollamaModels.contains(where: { $0.contains("nomic-embed") })
        local.append(HealthCheck(
            name: "Embeddings",
            icon: "brain",
            status: hasEmbedding ? .ok : .warning,
            latency: "",
            detail: hasEmbedding ? "nomic-embed-text ready" : "Run: ollama pull nomic-embed-text"
        ))

        let memoryResult = await pingURL("http://127.0.0.1:\(state.serverPort)/v1/memory/stats",
                                          bearer: state.serverToken)
        local.append(HealthCheck(
            name: "Memory",
            icon: "brain.head.profile",
            status: memoryResult.ok ? .ok : .warning,
            latency: memoryResult.ok ? "\(memoryResult.ms)ms" : "",
            detail: memoryResult.ok ? "Memory Army active" : "Memory system not responding"
        ))

        // ── Remote Access ──

        let tailscaleResult = await checkTailscale()
        remote.append(HealthCheck(
            name: "Tailscale",
            icon: "network",
            status: tailscaleResult.status,
            latency: tailscaleResult.latency,
            detail: tailscaleResult.detail
        ))

        // ── Cloud Providers ──

        for provider in [("OpenAI", "OPENAI_API_KEY"), ("Anthropic", "ANTHROPIC_API_KEY"), ("Google", "GOOGLE_API_KEY"), ("xAI", "XAI_API_KEY")] {
            let hasKey = !(state.cloudAPIKeys[provider.1] ?? "").isEmpty
            if hasKey {
                cloud.append(HealthCheck(
                    name: provider.0,
                    icon: "cloud.fill",
                    status: .ok,
                    latency: "key ✓",
                    detail: "\(provider.0) API key configured"
                ))
            }
        }

        let hasEL = !(state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty
        if hasEL {
            cloud.append(HealthCheck(
                name: "ElevenLabs",
                icon: "waveform",
                status: .ok,
                latency: "key ✓",
                detail: "TTS via ElevenLabs"
            ))
        }

        await MainActor.run {
            localChecks = local
            remoteChecks = remote
            cloudChecks = cloud
            lastCheckTime = Date()
            isChecking = false
        }
    }

    // MARK: - Ping Helpers

    struct PingResult {
        let ok: Bool
        let ms: Int
    }

    private func pingURL(_ urlStr: String, bearer: String? = nil) async -> PingResult {
        guard let url = URL(string: urlStr) else { return PingResult(ok: false, ms: 0) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        if let token = bearer {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return PingResult(ok: (200..<300).contains(code), ms: ms)
        } catch {
            return PingResult(ok: false, ms: 0)
        }
    }

    struct TailscaleResult {
        let status: HealthCheck.Status
        let latency: String
        let detail: String
    }

    private func checkTailscale() async -> TailscaleResult {
        // Check if tailscale CLI exists
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tailscale"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Use the path `which` found (works on both Intel and Apple Silicon)
                let whichOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let tailscalePath = whichOutput.isEmpty ? "/usr/local/bin/tailscale" : whichOutput

                // tailscale exists — check status
                let statusProc = Process()
                statusProc.executableURL = URL(fileURLWithPath: tailscalePath)
                statusProc.arguments = ["status", "--json"]
                let statusPipe = Pipe()
                statusProc.standardOutput = statusPipe
                statusProc.standardError = Pipe()

                do {
                    try statusProc.run()
                    statusProc.waitUntilExit()
                    let data = statusPipe.fileHandleForReading.readDataToEndOfFile()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let backendState = json["BackendState"] as? String ?? "Unknown"
                        if backendState == "Running" {
                            let selfIP = (json["TailscaleIPs"] as? [String])?.first ?? ""
                            let peerMap = json["Peer"] as? [String: Any]
                            let peerCount = peerMap?.count ?? 0
                            let detail = peerCount > 0
                                ? "Connected · \(peerCount) peer\(peerCount == 1 ? "" : "s")"
                                : "Connected · no peers yet"
                            return TailscaleResult(
                                status: .ok,
                                latency: selfIP.isEmpty ? "" : String(selfIP.prefix(15)),
                                detail: detail
                            )
                        } else {
                            return TailscaleResult(status: .warning, latency: "", detail: "Tailscale state: \(backendState) — run `tailscale up`")
                        }
                    }
                } catch {}

                return TailscaleResult(status: .warning, latency: "", detail: "Tailscale installed but status unknown")
            }
        } catch {}

        return TailscaleResult(status: .error, latency: "", detail: "Not installed — optional for remote access")
    }
}
#endif
