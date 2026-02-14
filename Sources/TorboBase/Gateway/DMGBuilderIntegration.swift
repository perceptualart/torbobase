// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — DMG Builder Tool Integration
// Extension to wire DMGBuilder into ToolProcessor
import Foundation

extension ToolProcessor {
    /// Add DMG builder to tool definitions when access level is FULL
    static func dmgBuilderToolDefinition(for level: AccessLevel) -> [String: Any]? {
        guard level == .fullAccess else { return nil }
        return DMGBuilder.toolDefinition
    }
}

// Extend enhancedToolDefinitions to include DMG builder
extension ToolProcessor {
    /// Enhanced tool definitions including DMG builder for FULL access
    static func extendedToolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        var tools = enhancedToolDefinitions(for: level)
        if let dmgBuilderTool = dmgBuilderToolDefinition(for: level) {
            tools.append(dmgBuilderTool)
        }
        return tools
    }
}

// Extend executeEnhancedBuiltInTools to handle build_dmg
extension ToolProcessor {
    /// Execute DMG builder and all other system tools
    func executeExtendedBuiltInTools(_ toolCalls: [[String: Any]], accessLevel: AccessLevel) async -> [[String: Any]] {
        var results = await executeEnhancedBuiltInTools(toolCalls, accessLevel: accessLevel)
        
        // Handle build_dmg calls
        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            
            if name == "build_dmg" && accessLevel == .fullAccess {
                let content = await DMGBuilder.shared.buildDMG()
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
