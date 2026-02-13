// Torbo Base — Screen Capture Integration
// Extension to wire ScreenCapture into ToolProcessor
import Foundation

extension ToolProcessor {
    /// Add screen capture to tool definitions when access level is FULL
    static func screenCaptureToolDefinition(for level: AccessLevel) -> [String: Any]? {
        guard level == .fullAccess else { return nil }
        return ScreenCapture.toolDefinition
    }
}

// Extend the existing toolDefinitions method to include capture_screen
extension ToolProcessor {
    /// Extended tool definitions including screen capture for FULL access
    static func allToolDefinitions(for level: AccessLevel) -> [[String: Any]] {
        var tools = toolDefinitions(for: level)
        if let screenCaptureTool = screenCaptureToolDefinition(for: level) {
            tools.append(screenCaptureTool)
        }
        return tools
    }
}

// Extend executeBuiltInTools to handle capture_screen
extension ToolProcessor {
    /// Execute screen capture and system tools
    func executeAllBuiltInTools(_ toolCalls: [[String: Any]], accessLevel: AccessLevel) async -> [[String: Any]] {
        var results = await executeBuiltInTools(toolCalls, accessLevel: accessLevel)
        
        // Handle capture_screen calls
        for call in toolCalls {
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            
            if name == "capture_screen" && accessLevel == .fullAccess {
                let content = await ScreenCapture.shared.captureScreen()
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
