// ORB Base — Xcode Build Tool
import Foundation

// MARK: - Xcode Build Tool

actor XcodeBuildTool {
    static let shared = XcodeBuildTool()
    
    /// Tool definition for Xcode build
    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "xcode_build_deploy",
            "description": "Build and deploy the ORB iOS app using xcodebuild. Compiles the project for the specified device. Returns build status and any errors.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Build and deploy the ORB iOS app
    func buildAndDeploy() async -> String {
        let projectPath = NSString(string: "~/Documents/orb master/orb app/ORB.xcodeproj").expandingTildeInPath
        let deviceID = "00008120-00103414227BC01E"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "-project", projectPath,
            "-scheme", "ORB_iOS",
            "-destination", "id=\(deviceID)",
            "build"
        ]
        
        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            
            // Wait with timeout (300 seconds)
            let startTime = Date()
            let timeout: TimeInterval = 300
            
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    process.terminate()
                    return "Error: Build timed out after 300 seconds"
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            // Get output after process completes
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                // Build succeeded
                var result = "✅ Build succeeded\n"
                
                // Extract useful info from output
                if output.contains("BUILD SUCCEEDED") {
                    result += "\nBuild completed successfully"
                }
                
                // Look for warnings
                let warningPattern = #/warning:.*/#
                let warnings = output.matches(of: warningPattern)
                if !warnings.isEmpty {
                    result += "\n\n⚠️ Warnings (\(warnings.count)):"
                    for (index, warning) in warnings.prefix(5).enumerated() {
                        result += "\n  \(index + 1). \(warning.output)"
                    }
                    if warnings.count > 5 {
                        result += "\n  ... and \(warnings.count - 5) more"
                    }
                }
                
                return result
            } else {
                // Build failed
                var result = "❌ Build failed with exit code \(process.terminationStatus)\n"
                
                // Extract errors
                let combinedOutput = output + errorOutput
                
                // Look for error patterns
                let errorPattern = #/error:.*/#
                let errors = combinedOutput.matches(of: errorPattern)
                
                if !errors.isEmpty {
                    result += "\n🔴 Errors (\(errors.count)):"
                    for (index, error) in errors.prefix(10).enumerated() {
                        result += "\n  \(index + 1). \(error.output)"
                    }
                    if errors.count > 10 {
                        result += "\n  ... and \(errors.count - 10) more"
                    }
                } else {
                    // If no specific errors found, show last lines of output
                    let lines = combinedOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if !lines.isEmpty {
                        result += "\n\nLast output lines:"
                        for line in lines.suffix(10) {
                            result += "\n  \(line)"
                        }
                    }
                }
                
                return result
            }
        } catch {
            return "Error: Failed to execute xcodebuild: \(error.localizedDescription)"
        }
    }
}
