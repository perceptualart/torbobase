// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Terminal View
// Dashboard tab with multi-tab interactive terminal sessions.
// Supports tabbed view, tiled grid view, and pop-out canvas windows.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

// MARK: - Terminal Manager

@MainActor
class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionID: UUID?

    enum ViewMode: String {
        case tabs
        case tiled
    }
    @Published var viewMode: ViewMode = .tabs

    var activeSession: TerminalSession? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    func createSession() {
        let session = TerminalSession()
        sessions.append(session)
        activeSessionID = session.id
        session.start()
    }

    func closeSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].stop()
        sessions.remove(at: idx)

        // Switch to adjacent tab
        if activeSessionID == id {
            if !sessions.isEmpty {
                let newIdx = min(idx, sessions.count - 1)
                activeSessionID = sessions[newIdx].id
            } else {
                activeSessionID = nil
            }
        }
    }

    func popOutSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        TerminalCanvasStore.shared.attachSession(id: id)
        WindowOpener.openWindow?(id: "terminal-canvas")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Terminal Canvas Store (for pop-out window)

@MainActor
final class TerminalCanvasStore: ObservableObject {
    static let shared = TerminalCanvasStore()
    @Published var sessionID: UUID?

    var session: TerminalSession? {
        guard let id = sessionID else { return nil }
        return TerminalManager.shared.sessions.first { $0.id == id }
    }

    func attachSession(id: UUID) {
        sessionID = id
    }
}

// MARK: - Terminal Canvas Window

struct TerminalCanvasWindow: View {
    @ObservedObject private var store = TerminalCanvasStore.shared
    @ObservedObject private var manager = TerminalManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))

                if let session = store.session {
                    Circle()
                        .fill(session.isRunning ? Color.green : Color.red.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(session.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("Terminal")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                // Session picker
                if manager.sessions.count > 1 {
                    Picker("", selection: Binding(
                        get: { store.sessionID ?? UUID() },
                        set: { store.sessionID = $0 }
                    )) {
                        ForEach(manager.sessions) { s in
                            Text(s.title).tag(s.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().overlay(Color.white.opacity(0.06))

            // Terminal content
            if let session = store.session {
                TerminalWebView(session: session)
                    .id(session.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.15))
                    Text("No session attached")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Terminal View (Dashboard Tab)

struct TerminalView: View {
    @StateObject private var manager = TerminalManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar / toolbar
            toolbar

            // Content
            switch manager.viewMode {
            case .tabs:
                tabbedContent
            case .tiled:
                tiledContent
            }
        }
        .onAppear {
            if manager.sessions.isEmpty {
                manager.createSession()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 0) {
            if manager.viewMode == .tabs {
                // Tab buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(manager.sessions) { session in
                            tabButton(for: session)
                        }
                    }
                    .padding(.leading, 8)
                }
            } else {
                // Tiled mode label
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Tiled — \(manager.sessions.count) terminal\(manager.sessions.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.leading, 12)
            }

            Spacer(minLength: 0)

            // View mode toggle
            HStack(spacing: 2) {
                viewModeButton(icon: "rectangle.stack", mode: .tabs, label: "Tabs")
                viewModeButton(icon: "square.grid.2x2", mode: .tiled, label: "Tiled")
            }
            .padding(2)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Canvas pop-out button
            if let session = manager.activeSession {
                Button {
                    manager.popOutSession(session.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 10))
                        Text("Canvas")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Open in Canvas window")
            }

            // New tab button
            Button {
                manager.createSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)))
    }

    private func viewModeButton(icon: String, mode: TerminalManager.ViewMode, label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                manager.viewMode = mode
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(manager.viewMode == mode ? .white : .white.opacity(0.35))
                .frame(width: 24, height: 22)
                .background(manager.viewMode == mode ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Tabbed Content

    private var tabbedContent: some View {
        Group {
            if let session = manager.activeSession {
                TerminalWebView(session: session)
                    .id(session.id)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Tiled Content

    private var tiledContent: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let cols = tiledColumns(for: manager.sessions.count, width: geo.size.width)
                    let rows = Int(ceil(Double(manager.sessions.count) / Double(cols)))
                    let cellWidth = (geo.size.width - CGFloat(cols - 1)) / CGFloat(cols)
                    let cellHeight = (geo.size.height - CGFloat(rows - 1)) / CGFloat(rows)

                    VStack(spacing: 1) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 1) {
                                ForEach(0..<cols, id: \.self) { col in
                                    let idx = row * cols + col
                                    if idx < manager.sessions.count {
                                        tiledCell(for: manager.sessions[idx])
                                            .frame(width: cellWidth, height: cellHeight)
                                    } else {
                                        Color.clear
                                            .frame(width: cellWidth, height: cellHeight)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func tiledColumns(for count: Int, width: CGFloat) -> Int {
        switch count {
        case 1: return 1
        case 2: return 2
        case 3: return width > 900 ? 3 : 2
        case 4: return 2
        default: return min(3, Int(ceil(sqrt(Double(count)))))
        }
    }

    private func tiledCell(for session: TerminalSession) -> some View {
        let isActive = session.id == manager.activeSessionID
        return VStack(spacing: 0) {
            // Mini title bar
            HStack(spacing: 5) {
                Circle()
                    .fill(session.isRunning ? Color.green : Color.red.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)

                // Pop-out
                Button {
                    manager.popOutSession(session.id)
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)

                // Close
                Button {
                    manager.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(isActive ? 0.06 : 0.02))

            TerminalWebView(session: session)
                .id(session.id)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isActive ? Color(red: 0.66, green: 0.33, blue: 0.97).opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onTapGesture {
            manager.activeSessionID = session.id
        }
    }

    // MARK: - Tab Button

    private func tabButton(for session: TerminalSession) -> some View {
        let isActive = session.id == manager.activeSessionID

        return Button {
            manager.activeSessionID = session.id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isRunning ? Color.green : Color.red.opacity(0.6))
                    .frame(width: 7, height: 7)

                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.5))
                    .lineLimit(1)

                if isActive {
                    Button {
                        manager.closeSession(session.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Color(red: 0.66, green: 0.33, blue: 0.97))
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.15))

            Text("No Terminal Sessions")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            Button {
                manager.createSession()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Terminal")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.66, green: 0.33, blue: 0.97))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
