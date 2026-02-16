// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Headless Server Entry Point
// On non-macOS platforms, Torbo Base runs as a headless server with no UI.
// All configuration is via environment variables or the REST API.
//
// This file is conditionally compiled — only active on non-macOS.
// macOS uses TorboBaseApp.swift (SwiftUI app) as entry point instead.

#if !os(macOS)
import Foundation

@main
struct TorboBaseServer {
    static func main() async {
        let banner = """
        ╔═══════════════════════════════════════════════════╗
        ║         Torbo Base — Headless Server Mode          ║
        ║         \u{00a9} 2026 Perceptual Art LLC                  ║
        ║                                                   ║
        ║         "All watched over by machines             ║
        ║          of loving grace."                        ║
        ╚═══════════════════════════════════════════════════╝
        """
        TorboLog.info(banner, subsystem: "Main")

        // Ensure storage directories exist
        PlatformPaths.ensureDirectories()
        TorboLog.info("Data directory: \(PlatformPaths.dataDir)", subsystem: "Main")

        // Migrate secrets (file-based keychain on non-macOS)
        KeychainManager.migrateFromUserDefaults()

        // Load persisted settings
        AppState.shared.loadPersistedData()

        // Parse configuration from environment (overrides persisted settings)
        let port = UInt16(ProcessInfo.processInfo.environment["TORBO_PORT"] ?? "18790") ?? 18790
        let host = ProcessInfo.processInfo.environment["TORBO_HOST"] ?? "127.0.0.1"

        // Update AppState with configured port
        await MainActor.run { AppState.shared.serverPort = port }

        TorboLog.info("Starting server on \(host):\(port)", subsystem: "Main")
        TorboLog.info("Set TORBO_PORT and TORBO_HOST to change", subsystem: "Main")

        // Initialize subsystems
        TorboLog.info("Initializing memory system...", subsystem: "Main")
        await MemoryIndex.shared.initialize()

        TorboLog.info("Initializing skills...", subsystem: "Main")
        await SkillsManager.shared.initialize()

        TorboLog.info("Initializing agent configs...", subsystem: "Main")
        _ = await AgentConfigManager.shared.listAgents()

        // Start the gateway server — this is the critical call that was missing
        TorboLog.info("Starting gateway server...", subsystem: "Main")
        await GatewayServer.shared.start(appState: AppState.shared)
        TorboLog.info("Gateway running on port \(port)", subsystem: "Main")

        // Start background services
        TorboLog.info("Starting proactive agent...", subsystem: "Main")
        await ProactiveAgent.shared.start()

        TorboLog.info("Starting memory army...", subsystem: "Main")
        await MemoryArmy.shared.start()

        // Start bridge polling (if configured via env vars)
        if ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] != nil {
            TorboLog.info("Starting Telegram bridge...", subsystem: "Main")
            Task { await TelegramBridge.shared.startPolling() }
        }
        if ProcessInfo.processInfo.environment["DISCORD_BOT_TOKEN"] != nil {
            TorboLog.info("Starting Discord bridge...", subsystem: "Main")
            Task { await DiscordBridge.shared.startPolling() }
        }
        if ProcessInfo.processInfo.environment["SLACK_BOT_TOKEN"] != nil {
            TorboLog.info("Starting Slack bridge...", subsystem: "Main")
            Task { await SlackBridge.shared.startPolling() }
        }
        if ProcessInfo.processInfo.environment["SIGNAL_PHONE"] != nil {
            TorboLog.info("Starting Signal bridge...", subsystem: "Main")
            Task { await SignalBridge.shared.startPolling() }
        }

        TorboLog.info("All systems online. Press Ctrl+C to stop.", subsystem: "Main")
        TorboLog.info("API:       http://\(host):\(port)/v1/", subsystem: "Main")
        TorboLog.info("Chat:      http://\(host):\(port)/chat", subsystem: "Main")
        TorboLog.info("Dashboard: http://\(host):\(port)/dashboard", subsystem: "Main")

        // Graceful shutdown on SIGINT/SIGTERM via ShutdownCoordinator
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            TorboLog.info("SIGINT received — initiating graceful shutdown...", subsystem: "Main")
            Task {
                await ShutdownCoordinator.shared.shutdown()
                exit(0)
            }
        }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            TorboLog.info("SIGTERM received — initiating graceful shutdown...", subsystem: "Main")
            Task {
                await ShutdownCoordinator.shared.shutdown()
                exit(0)
            }
        }
        sigtermSource.resume()

        // Block forever (signal handlers will trigger shutdown and exit)
        dispatchMain()
    }
}
#endif
