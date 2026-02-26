// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI

#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// Holds the SwiftUI OpenWindowAction so AppDelegate can trigger it.
/// SwiftUI creates MenuBarExtra immediately on launch — its label view's
/// .onAppear captures the action. AppDelegate.applicationDidFinishLaunching
/// then uses it to open the dashboard window.
enum WindowOpener {
    static var openWindow: OpenWindowAction?
}

@main
struct TorboBaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    // ObservedObject instead of @State — AppState is an ObservableObject singleton
    @ObservedObject private var appState = AppState.shared
    @State private var eulaAccepted = Legal.eulaAccepted
    @State private var setupCompleted = AppConfig.setupCompleted

    var body: some Scene {
        // Menu bar — always present
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            // The label is rendered IMMEDIATELY on launch (unlike the content
            // popup, which only appears when the user clicks the menu bar icon).
            // We use .onAppear on a background EmptyView inside an overlay
            // to capture the openWindow action as early as possible.
            Label("Torbo Base", systemImage: appState.menuBarIcon)
                .background {
                    // This fires during initial layout — guaranteed before
                    // applicationDidFinishLaunching completes its async work.
                    WindowOpenerView()
                }
        }
        .menuBarExtraStyle(.window)

        // Main window — shows setup wizard or dashboard
        Window("Torbo Base", id: "dashboard") {
            Group {
                if !eulaAccepted {
                    EULAView {
                        eulaAccepted = true
                    }
                } else if !setupCompleted {
                    SetupWizardView {
                        setupCompleted = true
                    }
                    .environmentObject(appState)
                } else {
                    DashboardView()
                        .environmentObject(appState)
                }
            }
            .frame(minWidth: 720, minHeight: 560)
            .preferredColorScheme(.dark)
            .onAppear {
                // Belt-and-suspenders: style the window once SwiftUI renders content
                DispatchQueue.main.async {
                    AppDelegate.styleAndShowWindow()
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 640)

        // Canvas — floating workspace window
        Window("Canvas", id: "canvas") {
            CanvasWindow()
                .frame(minWidth: 400, minHeight: 300)
                .onAppear {
                    DispatchQueue.main.async {
                        AppDelegate.styleCanvasWindow()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 640)
    }
}

/// Invisible view attached to the MenuBarExtra label.
/// Its sole purpose is to capture the OpenWindowAction early in launch.
private struct WindowOpenerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowOpener.openWindow = openWindow
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Style and bring the dashboard window to front.
    /// Called from both AppDelegate retries AND the SwiftUI .onAppear callback
    /// to guarantee the window is visible regardless of creation timing.
    static func styleAndShowWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.title == "Torbo Base"
            || $0.identifier?.rawValue.contains("dashboard") == true
            // Also match untitled SwiftUI windows that are the right size
            || ($0.title.isEmpty && $0.frame.width >= 700 && $0.contentView != nil
                && String(describing: type(of: $0.contentView!)).contains("NSHostingView"))
        }) else { return }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Dark title bar
        window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Style the canvas window — dark theme, position to the right of main window
    static func styleCanvasWindow() {
        guard let canvas = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("canvas") == true
        }) else { return }

        canvas.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        canvas.titlebarAppearsTransparent = true
        canvas.titleVisibility = .hidden
        canvas.makeKeyAndOrderFront(nil)

        // Position to the right of the main dashboard window
        if let main = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains("dashboard") == true
        }) {
            let mainFrame = main.frame
            let canvasOrigin = NSPoint(x: mainFrame.maxX + 8, y: mainFrame.origin.y)
            canvas.setFrameOrigin(canvasOrigin)
            // Match main window height
            let canvasSize = NSSize(width: canvas.frame.width, height: mainFrame.height)
            canvas.setContentSize(canvasSize)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Migrate any secrets from UserDefaults → Keychain (one-time)
        KeychainManager.migrateFromUserDefaults()

        // Load persisted conversations
        AppState.shared.loadPersistedData()

        // Show as regular app (not just menu bar) so the window is visible.
        // This must be set BEFORE trying to show any windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open the dashboard window using the SwiftUI OpenWindowAction.
        // The MenuBarExtra label's WindowOpenerView captures openWindow during
        // initial layout (before this method runs). We call it here + with retries
        // to handle any timing edge cases. Once the Window scene creates its
        // NSWindow, styleAndShowWindow() makes it key and brings it to front.
        DispatchQueue.main.async {
            WindowOpener.openWindow?(id: "dashboard")
            Self.styleAndShowWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WindowOpener.openWindow?(id: "dashboard")
            Self.styleAndShowWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            WindowOpener.openWindow?(id: "dashboard")
            Self.styleAndShowWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.styleAndShowWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Self.styleAndShowWindow() }

        Task {
            await OllamaManager.shared.ensureRunning()
            await OllamaManager.shared.checkAndUpdate()
            await GatewayServer.shared.start(appState: AppState.shared)

            // Initialize Governance Engine
            await GovernanceEngine.shared.initialize()
            TorboLog.info("Governance engine initialized", subsystem: "App")

            // Initialize Agent IAM — migrate existing agents on first boot
            await AgentIAMMigration.migrateIfNeeded()
            TorboLog.info("Agent IAM initialized", subsystem: "App")

            TorboLog.info("Gateway running on port \(AppState.shared.serverPort)", subsystem: "App")
            TorboLog.info("Access level: \(AppState.shared.accessLevel.rawValue) (\(AppState.shared.accessLevel.name))", subsystem: "App")
            TorboLog.info("Dashboard: http://127.0.0.1:\(AppState.shared.serverPort)/dashboard", subsystem: "App")
            let masked = String(AppConfig.serverToken.prefix(4)) + "****"
            TorboLog.info("Bearer token: \(masked)", subsystem: "App")

            // Start ProactiveAgent — background task executor
            // ProactiveAgent starts via AppState.proactiveAgentEnabled toggle
            let agentEnabled = UserDefaults.standard.bool(forKey: "proactiveAgentEnabled")
            if agentEnabled {
                await ProactiveAgent.shared.start()
            }
            // Default: OFF until toggled

            // Install default agent teams on first launch
            await DefaultTeams.installIfNeeded()

            // Start ambient intelligence subsystems
            TorboLog.info("Starting ambient monitor...", subsystem: "App")
            await HomeKitSOCReceiver.shared.start()
            await AmbientMonitor.shared.start()
            TorboLog.info("Ambient monitor online", subsystem: "App")

            // Start HomeKit ambient intelligence
            await HomeKitMonitor.shared.start()
            TorboLog.info("HomeKit monitor online", subsystem: "App")

            // Mic permission deferred to first voice activation — avoids spawning
            // audio IO threads at startup that can corrupt Swift metadata cache (PAC trap).
            TorboLog.info("Audio engine: deferred until voice activation", subsystem: "App")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending messages to disk
        Task { await ConversationStore.shared.flushMessages() }
        Task { await AmbientMonitor.shared.stop() }
        Task { await HomeKitSOCReceiver.shared.stop() }
        Task { await GatewayServer.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }
}

#endif
