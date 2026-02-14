// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Structured Logging
// Lightweight leveled logger — replaces raw print() with filterable, structured output.
// No external dependencies. Pure Swift.

import Foundation

/// Log severity levels, ordered from most to least verbose.
enum LogLevel: Int, Comparable, Sendable {
    case debug = 0   // Detailed diagnostic info (disabled by default)
    case info = 1    // Normal operational messages
    case warn = 2    // Potential issues that don't prevent operation
    case error = 3   // Errors that affect functionality

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }

    /// Parse a log level from a string (for settings).
    static func from(_ string: String) -> LogLevel {
        switch string.lowercased() {
        case "debug": return .debug
        case "info":  return .info
        case "warn", "warning": return .warn
        case "error": return .error
        default: return .info
        }
    }
}

/// Structured logger for Torbo Base.
///
/// Usage:
/// ```
/// TorboLog.info("Server started on port 8080", subsystem: "Gateway")
/// TorboLog.warn("Ollama not responding", subsystem: "LoA·Watcher")
/// TorboLog.error("Database open failed: \(error)", subsystem: "LoA·Index")
/// TorboLog.debug("Request body: \(body)", subsystem: "Gateway")
/// ```
///
/// Messages below `minimumLevel` are silently discarded.
/// Uses `@autoclosure` so string interpolation is skipped when the level is filtered out.
///
/// Phase 3 gave the system a voice. Phase 4 taught it honesty.
/// A machine that tells you the truth — even when the truth is an error.
enum TorboLog {
    /// Minimum log level to output. Messages below this level are silently discarded.
    /// Default: `.info` (debug messages hidden unless explicitly enabled).
    static var minimumLevel: LogLevel = .info

    /// Log a debug message (verbose diagnostic info, hidden by default).
    static func debug(_ msg: @autoclosure () -> String, subsystem: String = "") {
        log(.debug, msg(), subsystem: subsystem)
    }

    /// Log an informational message (normal operations).
    static func info(_ msg: @autoclosure () -> String, subsystem: String = "") {
        log(.info, msg(), subsystem: subsystem)
    }

    /// Log a warning (potential issue, non-fatal).
    static func warn(_ msg: @autoclosure () -> String, subsystem: String = "") {
        log(.warn, msg(), subsystem: subsystem)
    }

    /// Log an error (something broke).
    static func error(_ msg: @autoclosure () -> String, subsystem: String = "") {
        log(.error, msg(), subsystem: subsystem)
    }

    private static func log(_ level: LogLevel, _ msg: String, subsystem: String) {
        guard level >= minimumLevel else { return }
        let prefix = subsystem.isEmpty ? "" : "[\(subsystem)] "
        print("[\(level.tag)] \(prefix)\(msg)")
    }
}
