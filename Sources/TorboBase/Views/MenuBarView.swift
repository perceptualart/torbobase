// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
#if canImport(SwiftUI)
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header with mini orb
            HStack(spacing: 10) {
                OrbRenderer(
                    audioLevels: Array(repeating: Float(0.15), count: 40),
                    color: state.accessLevel.color,
                    isActive: state.serverRunning
                )
                .frame(width: 84, height: 84)
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TORBO BASE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .tracking(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(state.serverRunning ? state.accessLevel.color : .red)
                            .frame(width: 5, height: 5)
                        Text(state.statusSummary)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Spacer()
                Text(TorboVersion.display)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.15))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.06))

            // Level selector
            HStack(spacing: 10) {
                ForEach(AccessLevel.allCases, id: \.rawValue) { lvl in
                    LevelDot(level: lvl, currentLevel: state.accessLevel) {
                        if lvl != .fullAccess {
                            withAnimation { state.accessLevel = lvl }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.06))

            // Info
            if state.serverRunning {
                VStack(alignment: .leading, spacing: 5) {
                    MenuInfoLine(label: "Address", value: "\(state.localIP):\(state.serverPort)")
                    MenuInfoLine(label: "Level", value: "\(state.accessLevel.rawValue) — \(state.accessLevel.name)")
                    if state.connectedClients > 0 {
                        MenuInfoLine(label: "Clients", value: "\(state.connectedClients)")
                    }
                    MenuInfoLine(label: "Requests", value: "\(state.totalRequests) (\(state.blockedRequests) blocked)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().overlay(Color.white.opacity(0.06))
            }

            // Actions
            VStack(spacing: 2) {
                MenuBarAction(title: "Open Dashboard", icon: "rectangle.grid.1x2.fill") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if state.serverRunning {
                    MenuBarAction(title: "Open Web Chat", icon: "globe", tint: .cyan) {
                        let url = "http://\(state.localIP):\(state.serverPort)/chat"
                        if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
                    }
                }
                if state.accessLevel != .off {
                    MenuBarAction(title: "KILL SWITCH", icon: "power", tint: .red) {
                        state.killSwitch()
                    }
                }
            }
            .padding(.vertical, 4)

            Divider().overlay(Color.white.opacity(0.06))

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.ollamaRunning ? .green : .red.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(state.ollamaRunning ? "Ollama" : "Ollama offline")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)))
    }
}

// MARK: - Components

private struct LevelDot: View {
    let level: AccessLevel
    let currentLevel: AccessLevel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Circle()
                    .fill(level.rawValue <= currentLevel.rawValue ? level.color : level.color.opacity(0.12))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().stroke(level == currentLevel ? .white.opacity(0.6) : .clear, lineWidth: 1.5)
                    )
                Text("\(level.rawValue)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(level == currentLevel ? .white : .white.opacity(0.2))
            }
        }
        .buttonStyle(.plain)
        .disabled(level == .fullAccess)
    }
}

private struct MenuInfoLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .textSelection(.enabled)
            Spacer()
        }
    }
}

private struct MenuBarAction: View {
    let title: String
    let icon: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(tint.opacity(0.7))
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(tint.opacity(0.8))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
#endif
