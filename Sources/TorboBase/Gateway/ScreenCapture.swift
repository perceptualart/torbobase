// Torbo Base — Screen Capture Tool
import Foundation

// MARK: - Screen Capture Engine

actor ScreenCapture {
    static let shared = ScreenCapture()
    
    /// Tool definition for screen capture
    static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "capture_screen",
            "description": "Capture a screenshot of the entire screen and save it to /tmp/torbo_screen.png. Returns the path to the captured image.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Capture the screen and return the path to the saved image
    func captureScreen() async -> String {
        let outputPath = "/tmp/torbo_screen.png"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", outputPath]
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // Verify the file was created
                if FileManager.default.fileExists(atPath: outputPath) {
                    return "Screenshot captured successfully at: \(outputPath)"
                } else {
                    return "Error: Screenshot command succeeded but file not found at \(outputPath)"
                }
            } else {
                return "Error: Screenshot failed with exit code \(process.terminationStatus)"
            }
        } catch {
            return "Error: Failed to execute screencapture command: \(error.localizedDescription)"
        }
    }
}
