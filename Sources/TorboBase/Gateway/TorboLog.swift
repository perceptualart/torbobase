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
/// Logs are written to both stdout AND a daily-rotated log file for post-mortem debugging.
///
/// Phase 3 gave the system a voice. Phase 4 taught it honesty.
/// A machine that tells you the truth — even when the truth is an error.
enum TorboLog {
    /// Minimum log level to output. Messages below this level are silently discarded.
    /// Default: `.info` (debug messages hidden unless explicitly enabled).
    static var minimumLevel: LogLevel = .info

    // MARK: - File Logging

    /// Log directory: ~/Library/Application Support/TorboBase/logs/
    private static let logDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("TorboBase/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ISO 8601 timestamp formatter (thread-safe: DateFormatter is reference type but we only read after init)
    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Date-only formatter for log file names
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Current log file handle + date it was opened for
    private static var currentLogFile: (handle: FileHandle, date: String)?

    /// Maximum log files to keep (7 days)
    private static let maxLogFiles = 7

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
        let timestamp = timestampFormatter.string(from: Date())
        let prefix = subsystem.isEmpty ? "" : "[\(subsystem)] "
        let line = "\(timestamp) [\(level.tag)] \(prefix)\(msg)"

        // stdout
        print(line)

        // File persistence (best-effort, never crashes)
        writeToFile(line)
    }

    // MARK: - File I/O

    private static func writeToFile(_ line: String) {
        let today = dateFormatter.string(from: Date())

        // Rotate if day changed or first write
        if currentLogFile == nil || currentLogFile?.date != today {
            currentLogFile?.handle.closeFile()
            let filePath = logDir.appendingPathComponent("torbo-\(today).log")
            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: filePath) {
                handle.seekToEndOfFile()
                currentLogFile = (handle: handle, date: today)
                pruneOldLogs()
            } else {
                currentLogFile = nil
                return
            }
        }

        guard let handle = currentLogFile?.handle,
              let data = (line + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    /// Remove log files older than maxLogFiles days
    private static func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let logFiles = files.filter { $0.lastPathComponent.hasPrefix("torbo-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in logFiles.dropFirst(maxLogFiles) {
            try? fm.removeItem(at: file)
        }
    }
}
