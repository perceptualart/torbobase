// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Parallel Executor
// Slot-based concurrent task execution for ProactiveAgent.
// Replaces the single-task serial bottleneck with configurable concurrency.

import Foundation

/// Manages concurrent task execution slots for the ProactiveAgent.
/// Each slot runs an independent tool execution loop inside its own Swift Task.
/// Task dependencies are respected — TaskQueue.claimTask() only returns tasks
/// whose dependencies have all completed, so the executor doesn't need to check.
actor ParallelExecutor {
    static let shared = ParallelExecutor()

    /// Active execution slots: taskID → Swift Task handle
    private var activeSlots: [String: Task<Void, Never>] = [:]

    /// Maximum concurrent task slots (configurable via AppState)
    var maxSlots: Int = 3

    /// Check if the executor can accept another task.
    var canAcceptTask: Bool {
        activeSlots.count < maxSlots
    }

    /// Number of currently active tasks.
    var activeCount: Int {
        activeSlots.count
    }

    /// IDs of currently executing tasks.
    var activeTaskIDs: [String] {
        Array(activeSlots.keys)
    }

    /// Check if a specific task is currently executing.
    func isExecuting(taskID: String) -> Bool {
        activeSlots[taskID] != nil
    }

    /// Execute a task in a new slot. The provided closure runs the full
    /// tool execution loop for the task.
    ///
    /// - Parameters:
    ///   - taskID: The task's unique ID (used to track the slot)
    ///   - work: Async closure that performs the actual task execution
    func execute(taskID: String, work: @escaping @Sendable () async -> Void) {
        guard canAcceptTask else {
            TorboLog.warn("All \(maxSlots) slots full — cannot accept task \(taskID.prefix(8))", subsystem: "Executor")
            return
        }

        let task = Task {
            await work()
            // Auto-remove from slots when done
            self.onTaskComplete(taskID: taskID)
        }

        activeSlots[taskID] = task
        TorboLog.info("Task \(taskID.prefix(8)) started — \(activeSlots.count)/\(maxSlots) slots active", subsystem: "Executor")
    }

    /// Called when a task completes (success or failure). Removes the slot.
    private func onTaskComplete(taskID: String) {
        activeSlots.removeValue(forKey: taskID)
        TorboLog.info("Task \(taskID.prefix(8)) completed — \(activeSlots.count)/\(maxSlots) slots active", subsystem: "Executor")
    }

    /// Cancel a specific task by ID.
    func cancel(taskID: String) {
        if let task = activeSlots.removeValue(forKey: taskID) {
            task.cancel()
            TorboLog.info("Task \(taskID.prefix(8)) cancelled", subsystem: "Executor")
        }
    }

    /// Cancel all running tasks.
    func cancelAll() {
        for (id, task) in activeSlots {
            task.cancel()
            TorboLog.info("Cancelled task \(id.prefix(8))", subsystem: "Executor")
        }
        activeSlots.removeAll()
    }

    /// Update max slots from AppState.
    func updateMaxSlots(_ newMax: Int) {
        maxSlots = Swift.max(1, Swift.min(newMax, 10))  // Clamp to 1-10
        TorboLog.info("Max slots updated to \(maxSlots)", subsystem: "Executor")
    }
}
