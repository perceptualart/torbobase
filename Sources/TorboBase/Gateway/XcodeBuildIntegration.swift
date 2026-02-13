// Torbo Base — Xcode Build Tool Integration
// Extension to wire XcodeBuildTool into ToolProcessor
import Foundation

extension ToolProcessor {
    /// Add Xcode build to tool definitions when access level is FULL
    static func xcodeBuildToolDefinition(for level: AccessLevel) -> [String: Any]? {
        guard level == .fullAccess else { return nil }
        return XcodeBuildTool.toolDefinition
    }
}

// Extend allToolDefinitions to include Xcode build
extension ToolProcessor {
    /// Extended tool definitions including Xcode build for FULL access
    static func enhancedToolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        var tools = allToolDefinitions(for: level)
        if let xcodeBuildTool = xcodeBuildToolDefinition(for: level) {
            tools.append(xcodeBuildTool)
        }
        return tools
    }
}

// Extend executeAllBuiltInTools to handle xcode_build_deploy
extension ToolProcessor {
    /// Execute Xcode build and all other system tools
    func executeEnhancedBuiltInTools(_ toolCalls: [[String: Any]], accessLevel: AccessLevel) async -> [[String: Any]] {
        var results = await executeAllBuiltInTools(toolCalls, accessLevel: accessLevel)
        
        // Handle xcode_build_deploy calls
        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            
            if name == "xcode_build_deploy" && accessLevel == .fullAccess {
                let content = await XcodeBuildTool.shared.buildAndDeploy()
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
