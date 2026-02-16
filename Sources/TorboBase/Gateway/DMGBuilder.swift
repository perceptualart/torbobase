// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — DMG Builder Tool
// macOS only — uses hdiutil, sips, iconutil
#if os(macOS)
import Foundation

// MARK: - DMG Builder

actor DMGBuilder {
    static let shared = DMGBuilder()
    
    /// Tool definition for building DMG
    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "build_dmg",
            "description": "Build a complete DMG installer for Torbo Base. Runs the build.sh script which compiles, signs, and packages the app into a distributable DMG. Includes automatic versioning from git tags.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    private let projectPath: String = {
        let binary = ProcessInfo.processInfo.arguments[0]
        var dir = URL(fileURLWithPath: binary).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }()

    private var buildScriptPath: String {
        (projectPath as NSString).appendingPathComponent("build.sh")
    }
    
    /// Build the DMG installer
    func buildDMG() async -> String {
        // First, get the version from git tags
        let version = await getVersionFromGit()
        
        // Check if build.sh exists
        if !FileManager.default.fileExists(atPath: buildScriptPath) {
            return await fallbackBuild(version: version)
        }
        
        // Run the build.sh script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [buildScriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        // Set environment variables
        var environment = ProcessInfo.processInfo.environment
        environment["VERSION"] = version
        process.environment = environment
        
        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            
            // Wait with timeout (600 seconds for full build)
            let startTime = Date()
            let timeout: TimeInterval = 600
            
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    process.terminate()
                    return "❌ Build timed out after 600 seconds"
                }
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
            
            // Get output after process completes
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                // Build succeeded
                var result = "✅ DMG Build Complete\n"
                result += "Version: \(version)\n\n"
                
                // Extract key information from output
                let lines = output.components(separatedBy: .newlines)
                var relevantLines: [String] = []
                
                for line in lines {
                    if line.contains("✓") || line.contains("DMG:") || 
                       line.contains("App size:") || line.contains("BUILD COMPLETE") {
                        relevantLines.append(line)
                    }
                }
                
                if !relevantLines.isEmpty {
                    result += relevantLines.joined(separator: "\n")
                } else {
                    // Show last 20 lines
                    result += lines.suffix(20).joined(separator: "\n")
                }
                
                // Check for DMG file
                let distPath = (projectPath as NSString).appendingPathComponent("dist")
                let dmgName = "TorboBase-\(version).dmg"
                let dmgPath = (distPath as NSString).appendingPathComponent(dmgName)
                
                if FileManager.default.fileExists(atPath: dmgPath) {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: dmgPath),
                       let fileSize = attributes[.size] as? UInt64 {
                        let sizeInMB = Double(fileSize) / 1_048_576.0
                        result += "\n\n📦 DMG File:"
                        result += "\n  Path: dist/\(dmgName)"
                        result += "\n  Size: \(String(format: "%.1f", sizeInMB)) MB"
                    }
                } else {
                    result += "\n\n⚠️ DMG file not found at expected path: \(dmgPath)"
                }
                
                return result
            } else {
                // Build failed
                var result = "❌ DMG Build Failed (exit code: \(process.terminationStatus))\n\n"
                
                let combinedOutput = output + errorOutput
                
                // Look for error patterns
                if combinedOutput.contains("error:") {
                    result += "Build Errors:\n"
                    let lines = combinedOutput.components(separatedBy: .newlines)
                    for line in lines where line.contains("error:") {
                        result += "  \(line.trimmingCharacters(in: .whitespaces))\n"
                    }
                } else {
                    // Show last 30 lines of output
                    let lines = combinedOutput.components(separatedBy: .newlines)
                    result += "Build Output (last 30 lines):\n"
                    for line in lines.suffix(30) where !line.isEmpty {
                        result += "  \(line)\n"
                    }
                }
                
                return result
            }
        } catch {
            return "❌ Failed to execute build script: \(error.localizedDescription)"
        }
    }
    
    /// Get version from git tags
    private func getVersionFromGit() async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["describe", "--tags", "--abbrev=0"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe() // Suppress errors
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
                let output = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                // Remove 'v' prefix if present
                if output.hasPrefix("v") {
                    return String(output.dropFirst())
                }
                return output.isEmpty ? TorboVersion.current : output
            }
        } catch {
            // Fall through to default
        }
        
        return TorboVersion.current
    }
    
    /// Fallback build method if build.sh doesn't exist
    private func fallbackBuild(version: String) async -> String {
        var result = "⚠️ build.sh not found, using fallback build method\n\n"
        
        // First, run swift build
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build", "-c", "release"]
        buildProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        buildProcess.standardOutput = outputPipe
        buildProcess.standardError = errorPipe
        
        do {
            result += "▸ Running swift build -c release...\n"
            try buildProcess.run()
            
            let startTime = Date()
            let timeout: TimeInterval = 300
            
            while buildProcess.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    buildProcess.terminate()
                    return result + "❌ Build timed out after 300 seconds"
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            
            _ = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            if buildProcess.terminationStatus != 0 {
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                return result + "❌ Swift build failed:\n\(errorOutput)"
            }
            
            result += "✓ Swift build completed\n\n"
            
            // Locate the binary
            let buildDir = (projectPath as NSString).appendingPathComponent(".build/release")
            
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: buildDir) else {
                return result + "❌ Could not access build directory"
            }
            
            // Find the TorboBase binary
            let binaryName = "TorboBase"
            let binaryPath = (buildDir as NSString).appendingPathComponent(binaryName)
            
            if !FileManager.default.fileExists(atPath: binaryPath) {
                return result + "❌ Binary not found at: \(binaryPath)\n\nAvailable files:\n" + files.joined(separator: "\n")
            }
            
            result += "✓ Binary found: \(binaryPath)\n"
            
            // Get binary size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: binaryPath),
               let fileSize = attributes[.size] as? UInt64 {
                let sizeInMB = Double(fileSize) / 1_048_576.0
                result += "  Size: \(String(format: "%.1f", sizeInMB)) MB\n"
            }
            
            result += "\n📝 Note: For full DMG creation with signing and packaging,\n"
            result += "   please ensure build.sh exists in the project root.\n"
            result += "   The binary is ready at: .build/release/TorboBase"
            
            return result
            
        } catch {
            return result + "❌ Build error: \(error.localizedDescription)"
        }
    }
}
#endif
