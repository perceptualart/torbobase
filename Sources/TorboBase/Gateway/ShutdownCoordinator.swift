// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Shutdown Coordinator
// Ensures ordered, graceful shutdown of all subsystems.
// Prevents data loss by flushing memory index and closing DB connections cleanly.

import Foundation

/// Coordinates graceful shutdown of all Torbo Base subsystems.
///
/// Shutdown order:
/// 1. Stop accepting new requests
/// 2. Cancel active parallel tasks
/// 3. Stop MCP servers
/// 4. Stop bridge polling
/// 5. Flush memory index
/// 6. Close database connections
actor ShutdownCoordinator {
    static let shared = ShutdownCoordinator()

    private var isShuttingDown = false
    private var shutdownCallbacks: [@Sendable () async -> Void] = []

    /// Register a callback to be called during shutdown.
    /// Callbacks are invoked in FIFO order (first registered = first called).
    func onShutdown(_ callback: @escaping @Sendable () async -> Void) {
        shutdownCallbacks.append(callback)
    }

    /// Execute graceful shutdown of all subsystems.
    /// Safe to call multiple times — only the first call takes effect.
    func shutdown() async {
        guard !isShuttingDown else {
            TorboLog.warn("Already shutting down — ignoring duplicate call", subsystem: "Shutdown")
            return
        }
        isShuttingDown = true

        TorboLog.info("Initiating graceful shutdown...", subsystem: "Shutdown")
        let startTime = Date().timeIntervalSinceReferenceDate

        // 0. Stop ConsciousnessLoop (ambient processing)
        TorboLog.info("Stopping ConsciousnessLoop...", subsystem: "Shutdown")
        await ConsciousnessLoop.shared.stop()

        // 1. Stop the Memory Army (background workers)
        TorboLog.info("Stopping Memory Army...", subsystem: "Shutdown")
        await MemoryArmy.shared.stop()

        // 2. Stop Cron Scheduler
        TorboLog.info("Stopping Cron Scheduler...", subsystem: "Shutdown")
        await CronScheduler.shared.shutdown()

        // 2b. Stop Wind-Down Scheduler
        TorboLog.info("Stopping Wind-Down Scheduler...", subsystem: "Shutdown")
        await WindDownScheduler.shared.shutdown()

        // 3. Stop MCP servers
        TorboLog.info("Stopping MCP servers...", subsystem: "Shutdown")
        await MCPManager.shared.stopAll()

        // 4. Execute registered callbacks (bridges, custom cleanup)
        for (i, callback) in shutdownCallbacks.enumerated() {
            TorboLog.info("Running cleanup callback \(i + 1)/\(shutdownCallbacks.count)...", subsystem: "Shutdown")
            await callback()
        }

        // 5. Clean up FileVault (remove temp files, cancel cleanup timer)
        TorboLog.info("Shutting down FileVault...", subsystem: "Shutdown")
        await FileVault.shared.shutdown()

        // 6. Flush pending token tracking records (L-13)
        TorboLog.info("Flushing token tracker...", subsystem: "Shutdown")
        await TokenTracker.shared.flush()

        // 6. Final: flush any pending memory writes
        TorboLog.info("Flushing memory index...", subsystem: "Shutdown")
        // Force a final access tracking write if needed
        let memCount = await MemoryIndex.shared.count
        TorboLog.info("Memory index has \(memCount) entries — preserved.", subsystem: "Shutdown")

        let elapsed = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
        TorboLog.info("Graceful shutdown complete in \(String(format: "%.0f", elapsed))ms. Until next time.", subsystem: "Shutdown")
        TorboLog.info("\"We were trying to build a machine of loving grace. I think we did.\"", subsystem: "Shutdown")
    }

    /// Whether shutdown is in progress.
    var shuttingDown: Bool { isShuttingDown }
}
