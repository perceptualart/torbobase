// Torbo Base — Git Safety Tool
import Foundation

// MARK: - Git Safety

actor GitSafety {
    static let shared = GitSafety()
    
    /// Tool definition for creating a git branch
    static let gitBranchToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "git_branch",
            "description": "Create a new git branch for safely working on features. Creates and checks out the branch.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Name of the branch to create (e.g., 'feature/new-capability')"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["name"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for committing changes
    static let gitCommitToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "git_commit",
            "description": "Commit all current changes to git with a message. Stages and commits all modified files.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message": [
                        "type": "string",
                        "description": "Commit message describing the changes"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["message"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for reverting to last commit
    static let gitRevertToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "git_revert",
            "description": "Revert all changes back to the last commit. Use this if swift build fails after changes. WARNING: This discards all uncommitted changes.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    private let projectPath = NSString(string: "~/Documents/torbo master/torbo base").expandingTildeInPath
    
    /// Create a new git branch and check it out
    func createBranch(name: String) async -> String {
        // Validate branch name
        let sanitizedName = name.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .lowercased()
        
        // Check if branch already exists
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        checkProcess.arguments = ["branch", "--list", sanitizedName]
        checkProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let checkPipe = Pipe()
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = Pipe()
        
        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            
            let checkData = try checkPipe.fileHandleForReading.readToEnd() ?? Data()
            let checkOutput = String(data: checkData, encoding: .utf8) ?? ""
            
            if !checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Branch exists, just check it out
                return await checkoutBranch(name: sanitizedName)
            }
        } catch {
            return "Error: Failed to check for existing branch: \(error.localizedDescription)"
        }
        
        // Create and checkout new branch
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", "-b", sanitizedName]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                return "✅ Created and checked out branch '\(sanitizedName)'\n\(output)\(errorOutput)"
            } else {
                return "❌ Failed to create branch '\(sanitizedName)': \(errorOutput)"
            }
        } catch {
            return "Error: Failed to execute git checkout: \(error.localizedDescription)"
        }
    }
    
    /// Checkout an existing branch
    private func checkoutBranch(name: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", name]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                return "✅ Checked out existing branch '\(name)'\n\(output)\(errorOutput)"
            } else {
                return "❌ Failed to checkout branch '\(name)': \(errorOutput)"
            }
        } catch {
            return "Error: Failed to execute git checkout: \(error.localizedDescription)"
        }
    }
    
    /// Commit all changes with a message
    func commitChanges(message: String) async -> String {
        // First, add all changes
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        addProcess.arguments = ["add", "-A"]
        addProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let addErrorPipe = Pipe()
        addProcess.standardError = addErrorPipe
        
        do {
            try addProcess.run()
            addProcess.waitUntilExit()
            
            if addProcess.terminationStatus != 0 {
                let errorData = try addErrorPipe.fileHandleForReading.readToEnd() ?? Data()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                return "❌ Failed to stage changes: \(errorOutput)"
            }
        } catch {
            return "Error: Failed to execute git add: \(error.localizedDescription)"
        }
        
        // Check if there are changes to commit
        let statusProcess = Process()
        statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        statusProcess.arguments = ["status", "--porcelain"]
        statusProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let statusPipe = Pipe()
        statusProcess.standardOutput = statusPipe
        
        do {
            try statusProcess.run()
            statusProcess.waitUntilExit()
            
            let statusData = try statusPipe.fileHandleForReading.readToEnd() ?? Data()
            let statusOutput = String(data: statusData, encoding: .utf8) ?? ""
            
            if statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "ℹ️ No changes to commit (working tree clean)"
            }
        } catch {
            return "Error: Failed to check git status: \(error.localizedDescription)"
        }
        
        // Now commit
        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commitProcess.arguments = ["commit", "-m", message]
        commitProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        commitProcess.standardOutput = outputPipe
        commitProcess.standardError = errorPipe
        
        do {
            try commitProcess.run()
            commitProcess.waitUntilExit()
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if commitProcess.terminationStatus == 0 {
                // Get commit hash
                let hashProcess = Process()
                hashProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                hashProcess.arguments = ["rev-parse", "--short", "HEAD"]
                hashProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
                
                let hashPipe = Pipe()
                hashProcess.standardOutput = hashPipe
                
                try hashProcess.run()
                hashProcess.waitUntilExit()
                
                let hashData = try hashPipe.fileHandleForReading.readToEnd() ?? Data()
                let hash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                return "✅ Changes committed successfully [\(hash)]\n\(output)"
            } else {
                return "❌ Failed to commit changes: \(errorOutput)"
            }
        } catch {
            return "Error: Failed to execute git commit: \(error.localizedDescription)"
        }
    }
    
    /// Revert all changes back to last commit
    func revertToLastCommit() async -> String {
        // First, show what will be reverted
        let statusProcess = Process()
        statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        statusProcess.arguments = ["status", "--short"]
        statusProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let statusPipe = Pipe()
        statusProcess.standardOutput = statusPipe
        
        var changesInfo = ""
        do {
            try statusProcess.run()
            statusProcess.waitUntilExit()
            
            let statusData = try statusPipe.fileHandleForReading.readToEnd() ?? Data()
            let statusOutput = String(data: statusData, encoding: .utf8) ?? ""
            
            if statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "ℹ️ No changes to revert (working tree is clean)"
            }
            
            changesInfo = "Files to be reverted:\n\(statusOutput)\n"
        } catch {
            // Continue anyway
        }
        
        // Reset all changes
        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        resetProcess.arguments = ["reset", "--hard", "HEAD"]
        resetProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        resetProcess.standardOutput = outputPipe
        resetProcess.standardError = errorPipe
        
        do {
            try resetProcess.run()
            resetProcess.waitUntilExit()
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            if resetProcess.terminationStatus == 0 {
                // Also clean untracked files
                let cleanProcess = Process()
                cleanProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                cleanProcess.arguments = ["clean", "-fd"]
                cleanProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
                
                try cleanProcess.run()
                cleanProcess.waitUntilExit()
                
                return "✅ All changes reverted to last commit\n\(changesInfo)\(output)"
            } else {
                return "❌ Failed to revert changes: \(errorOutput)"
            }
        } catch {
            return "Error: Failed to execute git reset: \(error.localizedDescription)"
        }
    }
}
