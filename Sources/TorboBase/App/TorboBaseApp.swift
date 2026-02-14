// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy

#if canImport(SwiftUI) && os(macOS)
import SwiftUI

@main
struct TorboBaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState.shared
    @State private var eulaAccepted = Legal.eulaAccepted
    @State private var setupCompleted = AppConfig.setupCompleted

    var body: some Scene {
        // Menu bar — always present
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Label("Torbo Base", systemImage: appState.menuBarIcon)
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
                    .environment(appState)
                } else {
                    DashboardView()
                        .environment(appState)
                }
            }
            .frame(minWidth: 720, minHeight: 560)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 640)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Migrate any secrets from UserDefaults → Keychain (one-time)
        KeychainManager.migrateFromUserDefaults()

        // Load persisted conversations
        AppState.shared.loadPersistedData()

        // Show as regular app (not just menu bar) so the window is visible
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open the dashboard window — retry to handle SwiftUI window creation race
        func activateMainWindow() {
            if let window = NSApp.windows.first(where: { $0.title == "Torbo Base" || $0.identifier?.rawValue == "dashboard" }) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                // Dark title bar
                window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        DispatchQueue.main.async { activateMainWindow() }
        // Retry in case SwiftUI hasn't created the window yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { activateMainWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { activateMainWindow() }

        Task {
            await OllamaManager.shared.ensureRunning()
            await OllamaManager.shared.checkAndUpdate()
            await GatewayServer.shared.start(appState: AppState.shared)
            TorboLog.info("Gateway running on port \(AppState.shared.serverPort)", subsystem: "App")
            TorboLog.info("Access level: \(AppState.shared.accessLevel.rawValue) (\(AppState.shared.accessLevel.name))", subsystem: "App")

            // Start ProactiveAgent — background task executor
            // ProactiveAgent starts via AppState.proactiveAgentEnabled toggle
            let agentEnabled = UserDefaults.standard.bool(forKey: "proactiveAgentEnabled")
            if agentEnabled {
                await ProactiveAgent.shared.start()
            }
            // Default: OFF until toggled
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending messages to disk
        Task { await ConversationStore.shared.flushMessages() }
        Task { await GatewayServer.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running in menu bar
    }
}

#else
// Linux / non-macOS headless entry point
import Foundation

@main
struct TorboBaseApp {
    static func main() async {
        TorboLog.info("Starting in headless mode...", subsystem: "App")

        // Migrate secrets (Linux uses file-based keychain)
        KeychainManager.migrateFromUserDefaults()

        // Load persisted data
        AppState.shared.loadPersistedData()

        // Start gateway server
        await GatewayServer.shared.start(appState: AppState.shared)
        TorboLog.info("Gateway running on port \(AppState.shared.serverPort)", subsystem: "App")
        TorboLog.info("Access level: \(AppState.shared.accessLevel.rawValue) (\(AppState.shared.accessLevel.name))", subsystem: "App")

        // Start ProactiveAgent if enabled
        let agentEnabled = UserDefaults.standard.bool(forKey: "proactiveAgentEnabled")
        if agentEnabled {
            await ProactiveAgent.shared.start()
        }

        // Keep the process alive — wait for signal
        TorboLog.info("Running... Press Ctrl+C to stop.", subsystem: "App")

        // Set up signal handlers for graceful shutdown
        signal(SIGINT) { _ in
            TorboLog.info("Shutting down...", subsystem: "App")
            Task {
                await GatewayServer.shared.stop()
                await ConversationStore.shared.flushMessages()
                exit(0)
            }
        }
        signal(SIGTERM) { _ in
            Task {
                await GatewayServer.shared.stop()
                await ConversationStore.shared.flushMessages()
                exit(0)
            }
        }

        // Block main thread indefinitely
        dispatchMain()
    }
}
#endif
