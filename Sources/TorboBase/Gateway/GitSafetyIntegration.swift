// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Git Safety Tool Integration
// Extension to wire GitSafety tools into ToolProcessor
// macOS only — depends on enhancedToolDefinitions from XcodeBuildIntegration
#if os(macOS)
import Foundation

extension ToolProcessor {
    /// Add Git Safety tools to tool definitions when access level is FULL
    static func gitSafetyToolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        guard level == .fullAccess else { return [] }
        return [
            GitSafety.gitBranchToolDefinition,
            GitSafety.gitCommitToolDefinition,
            GitSafety.gitRevertToolDefinition
        ]
    }
}

// Extend tool definitions to include Git Safety tools
extension ToolProcessor {
    /// Extended tool definitions including Git Safety tools for FULL access
    static func enhancedToolDefinitionsWithGit(for level: AccessLevel) -> [[String: Any]] {
        var tools = enhancedToolDefinitions(for: level)
        tools.append(contentsOf: gitSafetyToolDefinitions(for: level))
        return tools
    }
}

// Extend executeEnhancedBuiltInTools to handle git operations
extension ToolProcessor {
    /// Execute Git Safety tools and all other system tools
    func executeEnhancedToolsWithGit(_ toolCalls: [[String: Any]], accessLevel: AccessLevel) async -> [[String: Any]] {
        var results = await executeEnhancedBuiltInTools(toolCalls, accessLevel: accessLevel)
        
        // Handle git tool calls
        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            
            var content: String?
            
            if accessLevel == .fullAccess {
                switch name {
                case "git_branch":
                    if let args = function["arguments"] as? [String: Any],
                       let branchName = args["name"] as? String {
                        content = await GitSafety.shared.createBranch(name: branchName)
                    } else {
                        content = "Error: Missing 'name' parameter for git_branch"
                    }
                    
                case "git_commit":
                    if let args = function["arguments"] as? [String: Any],
                       let message = args["message"] as? String {
                        content = await GitSafety.shared.commitChanges(message: message)
                    } else {
                        content = "Error: Missing 'message' parameter for git_commit"
                    }
                    
                case "git_revert":
                    content = await GitSafety.shared.revertToLastCommit()
                    
                default:
                    continue
                }
            }
            
            if let content = content {
                results.append([
                    "role": "tool",
                    "tool_call_id": id,
                    "content": content
                ])
            }
        }
        
        return results
    }
}
#endif
