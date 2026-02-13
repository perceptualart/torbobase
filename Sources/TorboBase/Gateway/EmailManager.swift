// Torbo Base — Email Manager
import Foundation

// MARK: - Email Manager

actor EmailManager {
    static let shared = EmailManager()
    
    /// Tool definition for checking emails
    static let checkEmailToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "check_email",
            "description": "Check for recent unread emails in Apple Mail. Returns a list of unread messages with IDs, senders, subjects, and timestamps. Use this to see what emails need attention.",
            "parameters": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of unread emails to return (default: 10, max: 50)"
                    ] as [String: Any],
                    "mailbox": [
                        "type": "string",
                        "description": "Mailbox to check (default: 'INBOX'). Can be 'INBOX', 'Sent', or other mailbox name."
                    ] as [String: Any]
                ] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for reading an email
    static let readEmailToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "read_email",
            "description": "Read the full content of a specific email by ID. Returns sender, subject, date, and complete message body. Get the email ID from check_email first.",
            "parameters": [
                "type": "object",
                "properties": [
                    "email_id": [
                        "type": "string",
                        "description": "Email ID to read (from check_email results)"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["email_id"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    /// Tool definition for drafting an email
    static let draftEmailToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "draft_email",
            "description": "Create a draft email in Apple Mail. The draft is saved but NOT sent automatically - MM can review and send it manually. Use this to compose responses or new messages.",
            "parameters": [
                "type": "object",
                "properties": [
                    "to": [
                        "type": "string",
                        "description": "Recipient email address(es), comma-separated if multiple"
                    ] as [String: Any],
                    "subject": [
                        "type": "string",
                        "description": "Email subject line"
                    ] as [String: Any],
                    "body": [
                        "type": "string",
                        "description": "Email message body (plain text)"
                    ] as [String: Any],
                    "cc": [
                        "type": "string",
                        "description": "Optional CC recipient(s), comma-separated"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["to", "subject", "body"] as [String]
            ] as [String: Any]
        ] as [String: Any]
    ]
    
    // MARK: - Email Operations
    
    /// Check for recent unread emails
    func checkEmail(limit: Int = 10, mailbox: String = "INBOX") async -> String {
        let actualLimit = min(max(1, limit), 50) // Clamp between 1 and 50
        
        let script = """
        tell application "Mail"
            set unreadMessages to messages of mailbox "\(mailbox)" whose read status is false
            set messageCount to count of unreadMessages
            set outputList to {}
            
            if messageCount is 0 then
                return "No unread emails in \(mailbox)"
            end if
            
            set limitCount to \(actualLimit)
            if messageCount < limitCount then
                set limitCount to messageCount
            end if
            
            repeat with i from 1 to limitCount
                set msg to item i of unreadMessages
                set msgID to id of msg as string
                set msgSubject to subject of msg
                set msgSender to sender of msg
                set msgDate to date received of msg
                
                set msgInfo to "ID: " & msgID & " | FROM: " & msgSender & " | SUBJECT: " & msgSubject & " | DATE: " & (msgDate as string)
                set end of outputList to msgInfo
            end repeat
            
            return "Found " & messageCount & " unread email(s) in \(mailbox) (showing " & limitCount & "):\\n" & my joinList(outputList, "\\n")
        end tell
        
        on joinList(theList, delimiter)
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to delimiter
            set theString to theList as string
            set AppleScript's text item delimiters to oldDelimiters
            return theString
        end joinList
        """
        
        return await runAppleScript(script)
    }
    
    /// Read a specific email by ID
    func readEmail(id: String) async -> String {
        let script = """
        tell application "Mail"
            try
                set targetMessage to first message whose id is \(id)
                
                set msgSubject to subject of targetMessage
                set msgSender to sender of targetMessage
                set msgDate to date received of targetMessage
                set msgContent to content of targetMessage
                set msgRead to read status of targetMessage
                
                -- Mark as read
                set read status of targetMessage to true
                
                set output to "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\\n"
                set output to output & "FROM: " & msgSender & "\\n"
                set output to output & "SUBJECT: " & msgSubject & "\\n"
                set output to output & "DATE: " & (msgDate as string) & "\\n"
                set output to output & "STATUS: " & (if msgRead then "Read" else "Unread (now marked as read)") & "\\n"
                set output to output & "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\\n\\n"
                set output to output & msgContent
                
                return output
            on error errMsg
                return "❌ Error reading email ID \(id): " & errMsg
            end try
        end tell
        """
        
        return await runAppleScript(script)
    }
    
    /// Draft a new email (saved but not sent)
    func draftEmail(to: String, subject: String, body: String, cc: String? = nil) async -> String {
        // Escape quotes in the email content
        let escapedSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        
        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
            
            tell newMessage
        """
        
        // Add recipients
        let recipients = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for recipient in recipients {
            script += """
            
                make new to recipient at end of to recipients with properties {address:"\(recipient)"}
            """
        }
        
        // Add CC recipients if provided
        if let cc = cc {
            let ccRecipients = cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for recipient in ccRecipients {
                script += """
                
                make new cc recipient at end of cc recipients with properties {address:"\(recipient)"}
                """
            }
        }
        
        script += """
        
            end tell
            
            return "✅ Draft created successfully\\nTO: \(to)\\nSUBJECT: \(subject)\\n\\nThe draft is open in Mail and ready for review. MM can edit and send it when ready."
        end tell
        """
        
        return await runAppleScript(script)
    }
    
    // MARK: - AppleScript Execution
    
    private func runAppleScript(_ script: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            
            // Wait with timeout (30 seconds for email operations)
            let startTime = Date()
            let timeout: TimeInterval = 30
            
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    process.terminate()
                    return "❌ Error: AppleScript timed out after 30 seconds. Is Mail running?"
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
            
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if process.terminationStatus == 0 {
                return output.isEmpty ? "✅ Operation completed (no output)" : output
            } else {
                var result = "❌ AppleScript error (exit code \(process.terminationStatus))"
                if !errorOutput.isEmpty {
                    result += ":\n\(errorOutput)"
                }
                if !output.isEmpty {
                    result += "\nOutput: \(output)"
                }
                return result
            }
        } catch {
            return "❌ Error: Failed to execute AppleScript: \(error.localizedDescription)"
        }
    }
}
