// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Retry Utility
// Generic async retry with exponential backoff + jitter.
// Prevents thundering herd and handles transient failures gracefully.

import Foundation

/// Generic async retry with exponential backoff and jitter.
///
/// Usage:
/// ```swift
/// let result = try await RetryUtility.withRetry(maxAttempts: 3) {
///     try await someFlakyCalling()
/// }
/// ```
enum RetryUtility {

    /// Execute an async operation with retries on failure.
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default: 3, includes initial attempt)
    ///   - baseDelay: Starting delay in seconds (default: 1.0)
    ///   - maxDelay: Maximum delay cap in seconds (default: 30.0)
    ///   - operation: The async throwing closure to execute
    /// - Returns: The operation's return value on success
    /// - Throws: The last error if all attempts fail
    static func withRetry<T: Sendable>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var currentDelay = baseDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                if attempt == maxAttempts {
                    TorboLog.error("All \(maxAttempts) attempts failed: \(error.localizedDescription)", subsystem: "Retry")
                    break
                }

                // Exponential backoff with ±25% jitter
                let jitter = currentDelay * Double.random(in: -0.25...0.25)
                let delay = min(currentDelay + jitter, maxDelay)

                TorboLog.warn("Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription). Retrying in \(String(format: "%.1f", delay))s...", subsystem: "Retry")

                // L-14: Explicitly check cancellation before sleeping to avoid unnecessary delay
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Exponential increase for next iteration
                currentDelay = min(currentDelay * 2, maxDelay)
            }
        }

        throw lastError ?? NSError(domain: "RetryUtility", code: -1, userInfo: [NSLocalizedDescriptionKey: "All retry attempts failed"])
    }

    /// Fire-and-forget retry — logs errors but doesn't throw.
    /// Useful for non-critical operations like metrics reporting or cache updates.
    static func withRetryQuiet(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await withRetry(maxAttempts: maxAttempts, baseDelay: baseDelay, operation: operation)
        } catch {
            TorboLog.error("Quiet retry exhausted: \(error.localizedDescription)", subsystem: "Retry")
        }
    }
}
