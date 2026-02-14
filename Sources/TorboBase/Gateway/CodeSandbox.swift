// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Code Interpreter Sandbox
// CodeSandbox.swift — Secure execution environment for Python and Node.js
// Gives agents real computational power: data analysis, math, plotting, file generation

import Foundation

// MARK: - Sandbox Configuration

struct SandboxConfig {
    var timeout: TimeInterval = 30          // Max execution time (seconds)
    var maxOutputSize: Int = 100_000        // Max stdout/stderr chars
    var maxFileSize: Int = 10_000_000       // Max generated file size (10MB)
    var allowNetwork: Bool = false          // Network access (disabled by default)
    var workingDirectory: String?           // Custom working dir (default: temp)
}

// MARK: - Execution Result

struct CodeExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let generatedFiles: [GeneratedFile]
    let executionTime: TimeInterval
    let language: String
    let truncated: Bool                     // True if output was truncated

    struct GeneratedFile {
        let name: String
        let path: String
        let size: Int
        let mimeType: String
    }

    var isSuccess: Bool { exitCode == 0 }

    /// Format as a tool response
    var toolResponse: String {
        var parts: [String] = []

        if !stdout.isEmpty {
            parts.append("Output:\n\(stdout)")
        }
        if !stderr.isEmpty && exitCode != 0 {
            parts.append("Errors:\n\(stderr)")
        }
        if !generatedFiles.isEmpty {
            let fileList = generatedFiles.map { "  - \($0.name) (\(formatBytes($0.size)))" }.joined(separator: "\n")
            parts.append("Generated files:\n\(fileList)")
        }
        parts.append("Exit code: \(exitCode) | Time: \(String(format: "%.1f", executionTime))s")

        if truncated {
            parts.append("[Output truncated to \(formatBytes(stdout.count))]")
        }

        return parts.joined(separator: "\n\n")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Code Sandbox

actor CodeSandbox {
    static let shared = CodeSandbox()

    enum Language: String {
        case python
        case javascript
        case bash

        var command: String {
            switch self {
            case .python: return "python3"
            case .javascript: return "node"
            case .bash: return "bash"
            }
        }

        var fileExtension: String {
            switch self {
            case .python: return ".py"
            case .javascript: return ".js"
            case .bash: return ".sh"
            }
        }
    }

    private let baseDir: String
    private var executionCount = 0

    init() {
        let appSupport = PlatformPaths.appSupportDir
        baseDir = appSupport.appendingPathComponent("TorboBase/sandbox").path

        // Ensure sandbox directory exists
        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        TorboLog.info("Initialized at \(baseDir)", subsystem: "Sandbox")
    }

    // MARK: - Execute Code

    /// Execute code in a sandboxed environment
    func execute(code: String, language: Language = .python, config: SandboxConfig = SandboxConfig()) async -> CodeExecutionResult {
        let startTime = Date()
        executionCount += 1
        let execID = "\(executionCount)_\(UUID().uuidString.prefix(8))"

        // Create temp directory for this execution
        let workDir = config.workingDirectory ?? "\(baseDir)/exec_\(execID)"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        // Write code to file with restricted permissions (user-only read/write)
        let codeFile = "\(workDir)/code\(language.fileExtension)"
        try? code.write(toFile: codeFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeFile)

        // Find the interpreter
        let interpreterPath = findInterpreter(language)
        guard let interpreter = interpreterPath else {
            return CodeExecutionResult(
                exitCode: 127,
                stdout: "",
                stderr: "\(language.command) not found. Please install \(language.rawValue).",
                generatedFiles: [],
                executionTime: Date().timeIntervalSince(startTime),
                language: language.rawValue,
                truncated: false
            )
        }

        TorboLog.info("Executing \(language.rawValue) code (exec \(execID), timeout: \(Int(config.timeout))s)", subsystem: "Sandbox")

        // Build the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)

        // For Python, add useful flags
        switch language {
        case .python:
            process.arguments = ["-u", codeFile]  // -u for unbuffered output
        case .javascript:
            process.arguments = [codeFile]
        case .bash:
            process.arguments = [codeFile]
        }

        // Environment: inherit system but restrict
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = workDir
        env["TMPDIR"] = workDir
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        // Add common paths for Python packages
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")

        // For Python: add matplotlib non-interactive backend for headless plotting
        env["MPLBACKEND"] = "Agg"

        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Track files before execution
        let filesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? [])

        // Execute with timeout
        var stdoutData = Data()
        var stderrData = Data()
        var didTimeout = false

        do {
            try process.run()

            // Set up async reading
            let readTask = Task {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            // Timeout handler
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(config.timeout) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                    didTimeout = true
                    // Give 2 more seconds then force kill
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()
            await readTask.value

        } catch {
            return CodeExecutionResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to execute: \(error.localizedDescription)",
                generatedFiles: [],
                executionTime: Date().timeIntervalSince(startTime),
                language: language.rawValue,
                truncated: false
            )
        }

        // Process output
        var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        var truncated = false

        if stdout.count > config.maxOutputSize {
            stdout = String(stdout.prefix(config.maxOutputSize))
            truncated = true
        }
        if stderr.count > config.maxOutputSize {
            stderr = String(stderr.prefix(config.maxOutputSize))
        }

        if didTimeout {
            stderr += "\n[Execution timed out after \(Int(config.timeout))s]"
        }

        // Find generated files (new files in working directory)
        let filesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? [])
        let newFiles = filesAfter.subtracting(filesBefore).subtracting(["code\(language.fileExtension)"])

        let generatedFiles = newFiles.compactMap { fileName -> CodeExecutionResult.GeneratedFile? in
            let filePath = "\(workDir)/\(fileName)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let size = attrs[.size] as? Int else { return nil }
            guard size <= config.maxFileSize else { return nil }  // Skip oversized files
            return CodeExecutionResult.GeneratedFile(
                name: fileName,
                path: filePath,
                size: size,
                mimeType: mimeType(for: fileName)
            )
        }

        let result = CodeExecutionResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            generatedFiles: generatedFiles,
            executionTime: Date().timeIntervalSince(startTime),
            language: language.rawValue,
            truncated: truncated
        )

        TorboLog.info("\(language.rawValue) execution complete — exit: \(result.exitCode), " +
              "stdout: \(stdout.count) chars, files: \(generatedFiles.count), " +
              "time: \(String(format: "%.1f", result.executionTime))s", subsystem: "Sandbox")

        // Schedule cleanup (keep files for 5 minutes — shorter to reduce exposure)
        Task {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            try? FileManager.default.removeItem(atPath: workDir)
            TorboLog.info("Cleaned up exec_\(execID)", subsystem: "Sandbox")
        }

        return result
    }

    // MARK: - Quick Execute (convenience)

    /// Execute Python code and return just the output string
    func executePython(_ code: String, timeout: TimeInterval = 30) async -> String {
        var config = SandboxConfig()
        config.timeout = timeout
        let result = await execute(code: code, language: .python, config: config)
        return result.toolResponse
    }

    /// Execute JavaScript/Node code
    func executeJavaScript(_ code: String, timeout: TimeInterval = 30) async -> String {
        var config = SandboxConfig()
        config.timeout = timeout
        let result = await execute(code: code, language: .javascript, config: config)
        return result.toolResponse
    }

    // MARK: - File Serving

    /// Get a generated file's data for serving via HTTP
    func getFile(path: String) -> Data? {
        // Security: only serve files from our sandbox directory
        guard path.hasPrefix(baseDir) else {
            TorboLog.warn("Rejected file access outside sandbox: \(path)", subsystem: "Sandbox")
            return nil
        }
        return FileManager.default.contents(atPath: path)
    }

    /// List all generated files across recent executions
    func listGeneratedFiles() -> [[String: Any]] {
        guard let execDirs = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else { return [] }

        var files: [[String: Any]] = []
        for dir in execDirs where dir.hasPrefix("exec_") {
            let dirPath = "\(baseDir)/\(dir)"
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in contents where !file.hasSuffix(".py") && !file.hasSuffix(".js") && !file.hasSuffix(".sh") {
                let filePath = "\(dirPath)/\(file)"
                let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
                files.append([
                    "name": file,
                    "path": filePath,
                    "size": (attrs?[.size] as? Int) ?? 0,
                    "mime_type": mimeType(for: file),
                    "execution": dir
                ])
            }
        }
        return files
    }

    // MARK: - Cleanup

    /// Clean up old execution directories
    func cleanup(olderThan interval: TimeInterval = 300) {
        guard let execDirs = try? FileManager.default.contentsOfDirectory(atPath: baseDir) else { return }
        let cutoff = Date().addingTimeInterval(-interval)

        for dir in execDirs where dir.hasPrefix("exec_") {
            let dirPath = "\(baseDir)/\(dir)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dirPath),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? FileManager.default.removeItem(atPath: dirPath)
            }
        }
    }

    /// Get sandbox stats
    func stats() -> [String: Any] {
        let execDirs = (try? FileManager.default.contentsOfDirectory(atPath: baseDir))?.filter { $0.hasPrefix("exec_") } ?? []
        var totalSize = 0
        for dir in execDirs {
            let dirPath = "\(baseDir)/\(dir)"
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) {
                for file in contents {
                    let filePath = "\(dirPath)/\(file)"
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                       let size = attrs[.size] as? Int {
                        totalSize += size
                    }
                }
            }
        }
        return [
            "total_executions": executionCount,
            "active_directories": execDirs.count,
            "total_disk_usage_bytes": totalSize,
            "sandbox_path": baseDir
        ]
    }

    // MARK: - Helpers

    private func findInterpreter(_ language: Language) -> String? {
        let searchPaths = [
            "/usr/local/bin/\(language.command)",
            "/opt/homebrew/bin/\(language.command)",
            "/usr/bin/\(language.command)",
            "/bin/\(language.command)"
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try `which`
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [language.command]
        let pipe = Pipe()
        which.standardOutput = pipe
        do {
            try which.run()
            which.waitUntilExit()
        } catch {
            TorboLog.debug("Process failed to start: \(error)", subsystem: "Sandbox")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            return p
        }

        return nil
    }

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "txt": return "text/plain"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "mp4": return "video/mp4"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
