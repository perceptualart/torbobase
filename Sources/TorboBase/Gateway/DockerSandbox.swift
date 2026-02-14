// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Docker Sandbox
// DockerSandbox.swift — Container-based code execution for maximum isolation
// Falls back to process-based sandbox (CodeSandbox) if Docker is unavailable
// Supports: Python, Node.js, Bash execution in ephemeral containers

import Foundation

// MARK: - Docker Configuration

struct DockerConfig {
    var memoryLimit: String = "256m"       // Container memory limit
    var cpuLimit: Double = 1.0             // CPU cores
    var networkMode: String = "none"       // No network by default
    var timeout: TimeInterval = 60         // Max execution time
    var maxOutputSize: Int = 100_000       // Max output chars
    var imageName: String?                 // Custom image (auto-detected if nil)
    var enableGPU: Bool = false            // GPU passthrough (for ML workloads)
    var volumes: [(host: String, container: String, readOnly: Bool)] = []  // Mount points
}

// MARK: - Docker Sandbox

actor DockerSandbox {
    static let shared = DockerSandbox()

    private var isDockerAvailable: Bool?
    private var executionCount = 0
    private let baseDir: String

    // Pre-built images for common languages
    private let defaultImages: [CodeSandbox.Language: String] = [
        .python: "python:3.11-slim",
        .javascript: "node:20-slim",
        .bash: "alpine:latest"
    ]

    init() {
        let appSupport = PlatformPaths.appSupportDir
        baseDir = appSupport.appendingPathComponent("TorboBase/docker-sandbox").path
        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
    }

    // MARK: - Docker Detection

    /// Check if Docker is installed and running
    func checkDocker() async -> Bool {
        if let cached = isDockerAvailable { return cached }

        let result = await runProcess(
            command: "/usr/local/bin/docker",
            args: ["info", "--format", "{{.ServerVersion}}"],
            timeout: 5
        )

        let available = result.exitCode == 0 && !result.stdout.isEmpty
        isDockerAvailable = available

        if available {
            TorboLog.info("Available — version: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))", subsystem: "Docker")
        } else {
            TorboLog.warn("Not available — will use process sandbox", subsystem: "Docker")
        }

        return available
    }

    /// Reset Docker availability cache (in case Docker starts/stops)
    func resetCache() {
        isDockerAvailable = nil
    }

    // MARK: - Execute Code in Docker

    /// Execute code in a Docker container (falls back to process sandbox if Docker unavailable)
    func execute(
        code: String,
        language: CodeSandbox.Language = .python,
        config: DockerConfig = DockerConfig()
    ) async -> CodeExecutionResult {

        // Check Docker availability
        let dockerAvailable = await checkDocker()

        // Fallback to process sandbox
        guard dockerAvailable else {
            TorboLog.info("Falling back to process sandbox", subsystem: "Docker")
            var sandboxConfig = SandboxConfig()
            sandboxConfig.timeout = config.timeout
            sandboxConfig.maxOutputSize = config.maxOutputSize
            return await CodeSandbox.shared.execute(code: code, language: language, config: sandboxConfig)
        }

        let startTime = Date()
        executionCount += 1
        let execID = "\(executionCount)_\(UUID().uuidString.prefix(8))"

        // Create temp directory for this execution
        let workDir = "\(baseDir)/exec_\(execID)"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        // Write code to file
        let codeFile = "\(workDir)/code\(language.fileExtension)"
        try? code.write(toFile: codeFile, atomically: true, encoding: .utf8)

        // Determine Docker image
        let image = config.imageName ?? defaultImages[language] ?? "python:3.11-slim"

        // Build docker run command
        var dockerArgs = ["run", "--rm"]

        // Resource limits
        dockerArgs += ["--memory", config.memoryLimit]
        dockerArgs += ["--cpus", String(config.cpuLimit)]
        dockerArgs += ["--network", config.networkMode]

        // Security: read-only filesystem except /tmp and working dir
        dockerArgs += ["--read-only"]
        dockerArgs += ["--tmpfs", "/tmp:rw,noexec,nosuid,size=100m"]

        // No new privileges
        dockerArgs += ["--security-opt", "no-new-privileges"]

        // Drop all capabilities
        dockerArgs += ["--cap-drop", "ALL"]

        // PID limit to prevent fork bombs
        dockerArgs += ["--pids-limit", "50"]

        // Mount the code directory
        dockerArgs += ["-v", "\(workDir):/workspace:rw"]
        dockerArgs += ["-w", "/workspace"]

        // Additional volumes
        for vol in config.volumes {
            let ro = vol.readOnly ? ":ro" : ":rw"
            dockerArgs += ["-v", "\(vol.host):\(vol.container)\(ro)"]
        }

        // Environment
        dockerArgs += ["-e", "PYTHONDONTWRITEBYTECODE=1"]
        dockerArgs += ["-e", "PYTHONUNBUFFERED=1"]
        dockerArgs += ["-e", "MPLBACKEND=Agg"]
        dockerArgs += ["-e", "HOME=/workspace"]

        // GPU support
        if config.enableGPU {
            dockerArgs += ["--gpus", "all"]
        }

        // Image and command
        dockerArgs.append(image)

        switch language {
        case .python:
            // Install common packages if needed, then run
            let setupScript = """
            pip install -q numpy pandas matplotlib 2>/dev/null || true
            python3 -u /workspace/code.py
            """
            dockerArgs += ["/bin/sh", "-c", setupScript]
        case .javascript:
            dockerArgs += ["node", "/workspace/code.js"]
        case .bash:
            dockerArgs += ["/bin/sh", "/workspace/code.sh"]
        }

        TorboLog.info("Executing \(language.rawValue) in \(image) (exec \(execID))", subsystem: "Docker")

        // Find docker executable
        let dockerPath = findDocker()
        guard let docker = dockerPath else {
            return CodeExecutionResult(
                exitCode: 127,
                stdout: "",
                stderr: "docker executable not found",
                generatedFiles: [],
                executionTime: Date().timeIntervalSince(startTime),
                language: language.rawValue,
                truncated: false
            )
        }

        // Track files before execution
        let filesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? [])

        // Execute docker run
        let result = await runProcess(
            command: docker,
            args: dockerArgs,
            timeout: Int(config.timeout) + 10, // Extra time for container startup
            workDir: workDir
        )

        // Process output
        var stdout = result.stdout
        var stderr = result.stderr
        var truncated = false

        if stdout.count > config.maxOutputSize {
            stdout = String(stdout.prefix(config.maxOutputSize))
            truncated = true
        }
        if stderr.count > config.maxOutputSize {
            stderr = String(stderr.prefix(config.maxOutputSize))
        }

        // Find generated files
        let filesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? [])
        let newFiles = filesAfter.subtracting(filesBefore).subtracting(["code\(language.fileExtension)"])

        let generatedFiles = newFiles.compactMap { fileName -> CodeExecutionResult.GeneratedFile? in
            let filePath = "\(workDir)/\(fileName)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let size = attrs[.size] as? Int else { return nil }
            return CodeExecutionResult.GeneratedFile(
                name: fileName,
                path: filePath,
                size: size,
                mimeType: mimeType(for: fileName)
            )
        }

        let executionResult = CodeExecutionResult(
            exitCode: result.exitCode,
            stdout: stdout,
            stderr: stderr,
            generatedFiles: generatedFiles,
            executionTime: Date().timeIntervalSince(startTime),
            language: language.rawValue,
            truncated: truncated
        )

        TorboLog.info("\(language.rawValue) execution complete — exit: \(result.exitCode), " +
              "stdout: \(stdout.count) chars, files: \(generatedFiles.count), " +
              "time: \(String(format: "%.1f", executionResult.executionTime))s", subsystem: "Docker")

        // Schedule cleanup
        Task {
            try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            try? FileManager.default.removeItem(atPath: workDir)
        }

        return executionResult
    }

    // MARK: - Docker Image Management

    /// Pull a Docker image
    func pullImage(_ image: String) async -> String {
        guard let docker = findDocker() else { return "Docker not found" }

        let result = await runProcess(command: docker, args: ["pull", image], timeout: 300)
        if result.exitCode == 0 {
            return "Image '\(image)' pulled successfully"
        } else {
            return "Failed to pull '\(image)': \(result.stderr)"
        }
    }

    /// List available Docker images
    func listImages() async -> [[String: String]] {
        guard let docker = findDocker() else { return [] }

        let result = await runProcess(
            command: docker,
            args: ["images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"],
            timeout: 10
        )

        guard result.exitCode == 0 else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line -> [String: String]? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return ["name": parts[0], "size": parts[1], "created": parts[2]]
        }
    }

    // MARK: - Status

    func stats() async -> [String: Any] {
        let available = await checkDocker()
        var info: [String: Any] = [
            "docker_available": available,
            "total_executions": executionCount,
            "base_path": baseDir
        ]

        if available, let docker = findDocker() {
            let result = await runProcess(command: docker, args: ["info", "--format", "{{.ServerVersion}}"], timeout: 5)
            info["docker_version"] = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Count running containers
            let ps = await runProcess(command: docker, args: ["ps", "-q"], timeout: 5)
            let running = ps.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            info["running_containers"] = running
        }

        return info
    }

    // MARK: - Helpers

    private func findDocker() -> String? {
        let paths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }

        // Try `which docker`
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["docker"]
        let pipe = Pipe()
        which.standardOutput = pipe
        do {
            try which.run()
            which.waitUntilExit()
        } catch {
            TorboLog.debug("Process failed to start: \(error)", subsystem: "Docker")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty { return p }

        return nil
    }

    private func runProcess(command: String, args: [String], timeout: Int, workDir: String? = nil) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        if let wd = workDir {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutTask.cancel()

            return (
                process.terminationStatus,
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
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
        default: return "application/octet-stream"
        }
    }
}
