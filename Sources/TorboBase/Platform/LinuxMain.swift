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
        let port = UInt16(ProcessInfo.processInfo.environment["TORBO_PORT"] ?? "4200") ?? 4200
        let host = ProcessInfo.processInfo.environment["TORBO_HOST"] ?? "0.0.0.0"

        // Update AppState with configured port
        await MainActor.run { AppState.shared.serverPort = port }

        // Import API keys from environment variables (standard Docker pattern)
        let envKeyMappings: [(env: String, provider: String)] = [
            ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"),
            ("OPENAI_API_KEY", "OPENAI_API_KEY"),
            ("XAI_API_KEY", "XAI_API_KEY"),
            ("GOOGLE_API_KEY", "GOOGLE_API_KEY"),
            ("ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY"),
        ]
        var importedKeys = 0
        for mapping in envKeyMappings {
            if let value = ProcessInfo.processInfo.environment[mapping.env], !value.isEmpty {
                KeychainManager.set(value, for: "apikey.\(mapping.provider)")
                importedKeys += 1
            }
        }
        if importedKeys > 0 {
            TorboLog.info("Imported \(importedKeys) API key(s) from environment", subsystem: "Main")
        }

        // Import access level from environment
        if let levelStr = ProcessInfo.processInfo.environment["TORBO_ACCESS_LEVEL"],
           let levelInt = Int(levelStr),
           let level = AccessLevel(rawValue: levelInt) {
            await MainActor.run { AppState.shared.accessLevel = level }
            TorboLog.info("Access level set to \(level.name) from environment", subsystem: "Main")
        }

        // Import server token from environment (or auto-generate)
        if let token = ProcessInfo.processInfo.environment["TORBO_TOKEN"], !token.isEmpty {
            KeychainManager.serverToken = token
            TorboLog.info("Server token set from environment", subsystem: "Main")
        }

        TorboLog.info("Starting server on \(host):\(port)", subsystem: "Main")
        TorboLog.info("Set TORBO_PORT and TORBO_HOST to change", subsystem: "Main")

        // Initialize subsystems
        TorboLog.info("Initializing memory system...", subsystem: "Main")
        await MemoryIndex.shared.initialize()
        await StreamStore.shared.initialize()
        await EntityGraph.shared.initialize()
        await UserIdentity.shared.initialize()
        await GovernanceEngine.shared.initialize()

        TorboLog.info("Initializing conversation search...", subsystem: "Main")
        await ConversationSearch.shared.initialize()
        Task { await ConversationSearch.shared.backfillFromStore() }

        TorboLog.info("Initializing skills...", subsystem: "Main")
        await SkillsManager.shared.initialize()

        TorboLog.info("Initializing agent configs...", subsystem: "Main")
        _ = await AgentConfigManager.shared.listAgents()

        // Initialize cloud services (Supabase auth + Stripe billing)
        TorboLog.info("Initializing cloud services...", subsystem: "Main")
        await SupabaseAuth.shared.initialize()
        await StripeManager.shared.initialize()
        if await SupabaseAuth.shared.isEnabled {
            TorboLog.info("Cloud auth: ENABLED (Supabase)", subsystem: "Main")
        }
        if await StripeManager.shared.isEnabled {
            TorboLog.info("Stripe billing: ENABLED", subsystem: "Main")
        }

        // Start the gateway server — this is the critical call that was missing
        TorboLog.info("Starting gateway server...", subsystem: "Main")
        await GatewayServer.shared.start(appState: AppState.shared)
        TorboLog.info("Gateway running on port \(port)", subsystem: "Main")
        TorboLog.info("Dashboard: http://127.0.0.1:\(port)/dashboard", subsystem: "Main")
        let masked = String(AppConfig.serverToken.prefix(4)) + "****"
        TorboLog.info("Bearer token: \(masked)", subsystem: "Main")

        // Start background services
        TorboLog.info("Starting proactive agent...", subsystem: "Main")
        await ProactiveAgent.shared.start()

        TorboLog.info("Starting memory army...", subsystem: "Main")
        await MemoryArmy.shared.start()

        TorboLog.info("Starting cron scheduler...", subsystem: "Main")
        await CronScheduler.shared.initialize()

        TorboLog.info("Starting LoA Memory Engine...", subsystem: "Main")
        await LoAMemoryEngine.shared.initialize()
        await LoADistillation.shared.registerCronJob()

        TorboLog.info("Starting LifeOS predictor...", subsystem: "Main")
        await LifeOSPredictor.shared.start()

        TorboLog.info("Starting HomeKit monitor...", subsystem: "Main")
        await HomeKitMonitor.shared.start()

        TorboLog.info("Starting commitments engine...", subsystem: "Main")
        await CommitmentsStore.shared.initialize()
        await CommitmentsFollowUp.shared.start()

        TorboLog.info("Starting morning briefing scheduler...", subsystem: "Main")
        await MorningBriefing.shared.initialize()

        TorboLog.info("Starting ambient monitor...", subsystem: "Main")
        await HomeKitSOCReceiver.shared.start()
        await AmbientMonitor.shared.start()

        // Initialize Agent IAM — migrate existing agents on first boot
        TorboLog.info("Initializing Agent IAM...", subsystem: "Main")
        await AgentIAMMigration.migrateIfNeeded()

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
        if await SupabaseAuth.shared.isEnabled {
            TorboLog.info("Auth:      POST http://\(host):\(port)/v1/auth/magic-link", subsystem: "Main")
            TorboLog.info("Billing:   GET  http://\(host):\(port)/v1/billing/status", subsystem: "Main")
        }

        // Graceful shutdown on SIGINT/SIGTERM
        // On Linux, DispatchSource signal handlers + dispatchMain() can crash
        // with the Swift async runtime. Use simple signal handlers instead.
        signal(SIGINT) { _ in _Exit(0) }
        signal(SIGTERM) { _ in _Exit(0) }

        // Keep the async main alive using structured concurrency
        while true {
            try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
        }
    }
}
#endif
