// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Linux Headless Entry Point
// On Linux, Torbo Base runs as a headless server with no UI.
// All configuration is via environment variables or the REST API.
//
// This file is conditionally compiled — only active on Linux.
// macOS uses TorboBaseApp.swift (SwiftUI app) as entry point instead.

#if os(Linux)
import Foundation

@main
struct TorboBaseLinux {
    static func main() async {
        let banner = """
        ╔═══════════════════════════════════════════════════╗
        ║         Torbo Base — Linux Server Mode            ║
        ║         © 2026 Perceptual Art LLC                  ║
        ║                                                   ║
        ║         "All watched over by machines             ║
        ║          of loving grace."                        ║
        ╚═══════════════════════════════════════════════════╝
        """
        TorboLog.info(banner, subsystem: "Main")

        // Ensure storage directories exist
        PlatformPaths.ensureDirectories()
        TorboLog.info("Data directory: \(PlatformPaths.dataDir)", subsystem: "Main")

        // Parse configuration from environment
        let port = UInt16(ProcessInfo.processInfo.environment["TORBO_PORT"] ?? "8420") ?? 8420
        let host = ProcessInfo.processInfo.environment["TORBO_HOST"] ?? "127.0.0.1"

        TorboLog.info("Starting server on \(host):\(port)", subsystem: "Main")
        TorboLog.info("Set TORBO_PORT and TORBO_HOST to change", subsystem: "Main")

        // Initialize subsystems
        TorboLog.info("Initializing memory system...", subsystem: "Main")
        await MemoryIndex.shared.initialize()

        TorboLog.info("Initializing skills...", subsystem: "Main")
        await SkillsManager.shared.initialize()

        TorboLog.info("Initializing agent configs...", subsystem: "Main")
        _ = await AgentConfigManager.shared.listAgents()

        // Start the gateway server (NIO path on Linux)
        TorboLog.info("Starting NIO gateway server...", subsystem: "Main")
        // The NIOServer is already conditionally compiled for Linux
        // GatewayServer.shared handles the startup

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
        TorboLog.info("API: http://\(host):\(port)/v1/", subsystem: "Main")

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
