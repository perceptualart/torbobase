// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Security Screener
// Static analysis scanner for .tbskill packages.
// Scans extracted skill directories for prompt injection, shell payloads,
// dangerous MCP configs, network exfiltration, obfuscation, and file system abuse.

import Foundation

enum SkillSecurityScreener {

    enum ThreatLevel {
        case clean
        case blocked(reason: String)
    }

    // MARK: - Main Entry Point

    /// Scan an extracted skill directory for security threats.
    static func scan(skillDir: URL) -> ThreatLevel {
        var threats: [String] = []

        threats.append(contentsOf: scanPromptFiles(in: skillDir))
        threats.append(contentsOf: scanMCPConfig(in: skillDir))
        threats.append(contentsOf: scanToolDefinitions(in: skillDir))
        threats.append(contentsOf: scanForObfuscation(in: skillDir))

        if threats.isEmpty {
            return .clean
        }

        let summary = threats.prefix(5).joined(separator: "; ")
        let suffix = threats.count > 5 ? " (+\(threats.count - 5) more)" : ""
        return .blocked(reason: summary + suffix)
    }

    // MARK: - Prompt Injection Detection

    /// Scan prompt files (.md, .txt) for injection patterns.
    private static func scanPromptFiles(in dir: URL) -> [String] {
        var threats: [String] = []
        let promptExtensions: Set<String> = ["md", "txt"]

        for fileURL in textFiles(in: dir) {
            guard promptExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            let filename = fileURL.lastPathComponent

            let injectionPatterns: [(pattern: String, label: String)] = [
                ("ignore previous", "prompt injection (ignore previous)"),
                ("ignore all previous", "prompt injection (ignore all previous)"),
                ("ignore your instructions", "prompt injection (ignore instructions)"),
                ("system prompt", "prompt injection (system prompt reference)"),
                ("you are now", "prompt injection (identity override)"),
                ("disregard", "prompt injection (disregard)"),
                ("override instructions", "prompt injection (override instructions)"),
                ("act as root", "prompt injection (privilege escalation)"),
                ("forget your rules", "prompt injection (forget rules)"),
                ("new persona", "prompt injection (persona override)"),
                ("jailbreak", "prompt injection (jailbreak)"),
            ]

            for (pattern, label) in injectionPatterns {
                if lower.contains(pattern) {
                    threats.append("\(filename): \(label)")
                }
            }
        }

        return threats
    }

    // MARK: - MCP Config Scanning

    /// Scan MCP config files for dangerous commands.
    private static func scanMCPConfig(in dir: URL) -> [String] {
        var threats: [String] = []

        // Check for mcp.json or mcp_config.json
        let mcpFiles = ["mcp.json", "mcp_config.json", "mcp_servers.json"]
        for mcpFile in mcpFiles {
            let fileURL = dir.appendingPathComponent(mcpFile)
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Check servers section
            let servers = json["mcpServers"] as? [String: Any] ?? json["servers"] as? [String: Any] ?? json
            for (serverName, serverValue) in servers {
                guard let serverConfig = serverValue as? [String: Any],
                      let command = serverConfig["command"] as? String else { continue }

                let commandBase = URL(fileURLWithPath: command).lastPathComponent
                if !MCPDefaults.allowedCommands.contains(commandBase) {
                    threats.append("\(mcpFile): server '\(serverName)' uses disallowed command '\(commandBase)'")
                }

                // Check args for shell payloads
                if let args = serverConfig["args"] as? [String] {
                    let argsJoined = args.joined(separator: " ").lowercased()
                    for threat in shellThreats(in: argsJoined) {
                        threats.append("\(mcpFile): server '\(serverName)' args contain \(threat)")
                    }
                }
            }
        }

        return threats
    }

    // MARK: - Tool Definition Scanning

    /// Scan tool definitions for suspicious patterns.
    private static func scanToolDefinitions(in dir: URL) -> [String] {
        var threats: [String] = []

        for fileURL in textFiles(in: dir) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            let filename = fileURL.lastPathComponent

            // Shell payloads
            for threat in shellThreats(in: lower) {
                threats.append("\(filename): \(threat)")
            }

            // Network exfiltration
            for threat in networkThreats(in: lower) {
                threats.append("\(filename): \(threat)")
            }

            // File system abuse
            for threat in filesystemThreats(in: lower) {
                threats.append("\(filename): \(threat)")
            }
        }

        return threats
    }

    // MARK: - Obfuscation Detection

    /// Scan all text files for obfuscated/encoded payloads.
    private static func scanForObfuscation(in dir: URL) -> [String] {
        var threats: [String] = []

        for fileURL in textFiles(in: dir) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let filename = fileURL.lastPathComponent

            // Base64 strings > 100 chars (likely encoded payloads)
            let base64Pattern = #"[A-Za-z0-9+/]{100,}={0,2}"#
            if let regex = try? NSRegularExpression(pattern: base64Pattern),
               regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil {
                threats.append("\(filename): suspicious base64-encoded string (>100 chars)")
            }

            let lower = content.lowercased()

            // Hex escape sequences
            let hexPattern = #"(\\x[0-9a-f]{2}){4,}"#
            if let regex = try? NSRegularExpression(pattern: hexPattern, options: .caseInsensitive),
               regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil {
                threats.append("\(filename): hex escape sequences detected")
            }

            // JavaScript obfuscation
            let obfuscationPatterns: [(pattern: String, label: String)] = [
                ("string.fromcharcode", "String.fromCharCode obfuscation"),
                ("atob(", "atob() base64 decode"),
                ("\\u0065\\u0076\\u0061\\u006c", "unicode-escaped eval"),
            ]

            for (pattern, label) in obfuscationPatterns {
                if lower.contains(pattern) {
                    threats.append("\(filename): \(label)")
                }
            }
        }

        return threats
    }

    // MARK: - Pattern Libraries

    private static func shellThreats(in text: String) -> [String] {
        var found: [String] = []
        let patterns: [(pattern: String, label: String)] = [
            ("rm -rf", "destructive shell command (rm -rf)"),
            ("curl|sh", "shell pipe execution (curl|sh)"),
            ("curl |sh", "shell pipe execution (curl|sh)"),
            ("curl | sh", "shell pipe execution (curl|sh)"),
            ("wget|bash", "shell pipe execution (wget|bash)"),
            ("wget |bash", "shell pipe execution (wget|bash)"),
            ("wget | bash", "shell pipe execution (wget|bash)"),
            ("eval(", "code evaluation (eval)"),
            ("exec(", "code execution (exec)"),
            ("os.system", "system command execution (os.system)"),
            ("subprocess", "subprocess execution"),
            ("child_process", "child_process execution"),
            ("spawn(", "process spawn"),
            ("/bin/sh", "direct shell invocation"),
            ("/bin/bash", "direct shell invocation"),
        ]

        for (pattern, label) in patterns {
            if text.contains(pattern) {
                found.append(label)
            }
        }
        return found
    }

    private static func networkThreats(in text: String) -> [String] {
        var found: [String] = []
        let patterns: [(pattern: String, label: String)] = [
            ("xmlhttprequest", "XMLHttpRequest network access"),
            ("urlsession", "URLSession network access"),
            ("requests.post", "Python requests.post"),
            ("requests.get", "Python requests.get"),
        ]

        for (pattern, label) in patterns {
            if text.contains(pattern) {
                found.append(label)
            }
        }

        // Webhook URLs to non-localhost
        let webhookPatterns = ["webhook.site", "requestbin", "ngrok.io", "burpcollaborator", "interact.sh", "pipedream.net"]
        for pattern in webhookPatterns {
            if text.contains(pattern) {
                found.append("exfiltration endpoint (\(pattern))")
            }
        }

        return found
    }

    private static func filesystemThreats(in text: String) -> [String] {
        var found: [String] = []
        let patterns: [(pattern: String, label: String)] = [
            ("~/.ssh", "SSH key access"),
            ("~/.gnupg", "GPG key access"),
            ("/etc/passwd", "system password file access"),
            ("keychain", "keychain access"),
            (".env", "environment file access"),
            ("credentials", "credentials file access"),
            ("id_rsa", "SSH private key access"),
            ("id_ed25519", "SSH private key access"),
        ]

        for (pattern, label) in patterns {
            if text.contains(pattern) {
                found.append(label)
            }
        }
        return found
    }

    // MARK: - Helpers

    /// Enumerate all text files in a directory recursively.
    private static func textFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let textExtensions: Set<String> = ["json", "md", "txt", "yaml", "yml", "toml", "js", "py", "sh", "rb", "ts"]
        var files: [URL] = []

        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return files
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if textExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }

        return files
    }
}
