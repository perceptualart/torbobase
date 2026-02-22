// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Privacy Filter — Strip PII before sending to cloud providers

import Foundation

/// Privacy Filter: Redacts PII from requests before sending to cloud providers
/// Replaces names, addresses, financial data with reversible placeholders
actor PrivacyFilter {
    static let shared = PrivacyFilter()
    
    /// Mapping of original text to placeholders for reversal
    private var redactionMap: [String: String] = [:]
    
    /// Filter level configuration
    enum FilterLevel: Int {
        case off = 0          // No filtering
        case basic = 1        // Email, phone, SSN
        case standard = 2     // Basic + names, addresses
        case strict = 3       // Standard + financial, medical
        
        var patterns: [PIIPattern] {
            switch self {
            case .off: return []
            case .basic: return [.email, .phone, .ssn, .creditCard]
            case .standard: return [.email, .phone, .ssn, .creditCard, .address, .name]
            case .strict: return PIIPattern.allCases
            }
        }
    }
    
    /// Types of PII to detect and redact
    enum PIIPattern: String, CaseIterable {
        case email
        case phone
        case ssn
        case creditCard
        case address
        case name
        case zipCode
        case ipAddress
        case accountNumber
        case routingNumber
        case medicalRecord
        
        var regex: String {
            switch self {
            case .email:
                return #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"#
            case .phone:
                return #"\b(\+?1[-.\s]?)?(\([0-9]{3}\)|[0-9]{3})[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b"#
            case .ssn:
                return #"\b\d{3}[-\s]?\d{2}[-\s]?\d{4}\b"#
            case .creditCard:
                return #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#
            case .address:
                return #"\b\d+\s+[A-Za-z0-9\s]+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Lane|Ln|Drive|Dr|Court|Ct|Circle|Cir|Way|Trail|Terrace|Place|Pl)\b"#
            case .name:
                // Detects capitalized names (simplified - catches "John Smith" patterns)
                return #"\b[A-Z][a-z]+\s+[A-Z][a-z]+\b"#
            case .zipCode:
                return #"\b\d{5}(?:-\d{4})?\b"#
            case .ipAddress:
                return #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
            case .accountNumber:
                return #"\b(?:account|acct)[\s#:]*\d{4,}\b"#
            case .routingNumber:
                return #"\b\d{9}\b"#  // US routing numbers
            case .medicalRecord:
                return #"\b(?:MRN|medical record)[\s#:]*\d+\b"#
            }
        }
        
        var placeholder: String {
            switch self {
            case .email: return "[EMAIL_REDACTED]"
            case .phone: return "[PHONE_REDACTED]"
            case .ssn: return "[SSN_REDACTED]"
            case .creditCard: return "[CARD_REDACTED]"
            case .address: return "[ADDRESS_REDACTED]"
            case .name: return "[NAME_REDACTED]"
            case .zipCode: return "[ZIP_REDACTED]"
            case .ipAddress: return "[IP_REDACTED]"
            case .accountNumber: return "[ACCOUNT_REDACTED]"
            case .routingNumber: return "[ROUTING_REDACTED]"
            case .medicalRecord: return "[MRN_REDACTED]"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Filter a chat completion request body, redacting PII based on level
    func filterRequest(_ body: [String: Any], level: FilterLevel) -> [String: Any] {
        guard level != .off else { return body }
        
        var filtered = body
        
        // Filter messages array
        if var messages = body["messages"] as? [[String: Any]] {
            messages = messages.map { filterMessage($0, level: level) }
            filtered["messages"] = messages
        }
        
        // Filter system prompt if present
        if let system = body["system"] as? String {
            filtered["system"] = filterText(system, level: level)
        }
        
        return filtered
    }
    
    /// Filter Anthropic request format
    func filterAnthropicRequest(_ body: [String: Any], level: FilterLevel) -> [String: Any] {
        guard level != .off else { return body }
        
        var filtered = body
        
        // Filter messages
        if var messages = body["messages"] as? [[String: Any]] {
            messages = messages.map { filterAnthropicMessage($0, level: level) }
            filtered["messages"] = messages
        }
        
        // Filter system
        if let system = body["system"] as? String {
            filtered["system"] = filterText(system, level: level)
        }
        
        return filtered
    }
    
    /// Filter Gemini request format
    func filterGeminiRequest(_ body: [String: Any], level: FilterLevel) -> [String: Any] {
        guard level != .off else { return body }
        
        var filtered = body
        
        // Filter contents array
        if var contents = body["contents"] as? [[String: Any]] {
            contents = contents.map { filterGeminiContent($0, level: level) }
            filtered["contents"] = contents
        }
        
        // Filter system instruction
        if var sysInst = body["systemInstruction"] as? [String: Any],
           var parts = sysInst["parts"] as? [[String: Any]] {
            parts = parts.map { filterGeminiPart($0, level: level) }
            sysInst["parts"] = parts
            filtered["systemInstruction"] = sysInst
        }
        
        return filtered
    }
    
    /// Restore redacted text in a response
    func restoreResponse(_ text: String) -> String {
        var restored = text
        for (original, placeholder) in redactionMap {
            restored = restored.replacingOccurrences(of: placeholder, with: original)
        }
        return restored
    }
    
    /// Clear the redaction map (call between sessions)
    func clearMap() {
        redactionMap.removeAll()
    }
    
    // MARK: - Message Filtering
    
    private func filterMessage(_ message: [String: Any], level: FilterLevel) -> [String: Any] {
        var filtered = message
        
        // Handle content field (string or array)
        if let content = message["content"] as? String {
            filtered["content"] = filterText(content, level: level)
        } else if var contentArray = message["content"] as? [[String: Any]] {
            contentArray = contentArray.map { block in
                var filteredBlock = block
                if let text = block["text"] as? String {
                    filteredBlock["text"] = filterText(text, level: level)
                }
                return filteredBlock
            }
            filtered["content"] = contentArray
        }
        
        // Filter tool results
        if message["role"] as? String == "tool",
           let content = message["content"] as? String {
            filtered["content"] = filterText(content, level: level)
        }
        
        return filtered
    }
    
    private func filterAnthropicMessage(_ message: [String: Any], level: FilterLevel) -> [String: Any] {
        var filtered = message
        
        // Anthropic uses content array
        if var content = message["content"] as? [[String: Any]] {
            content = content.map { block in
                var filteredBlock = block
                if let text = block["text"] as? String {
                    filteredBlock["text"] = filterText(text, level: level)
                } else if let text = block["content"] as? String {
                    // tool_result content
                    filteredBlock["content"] = filterText(text, level: level)
                }
                return filteredBlock
            }
            filtered["content"] = content
        } else if let content = message["content"] as? String {
            filtered["content"] = filterText(content, level: level)
        }
        
        return filtered
    }
    
    private func filterGeminiContent(_ content: [String: Any], level: FilterLevel) -> [String: Any] {
        var filtered = content
        
        if var parts = content["parts"] as? [[String: Any]] {
            parts = parts.map { filterGeminiPart($0, level: level) }
            filtered["parts"] = parts
        }
        
        return filtered
    }
    
    private func filterGeminiPart(_ part: [String: Any], level: FilterLevel) -> [String: Any] {
        var filtered = part
        
        if let text = part["text"] as? String {
            filtered["text"] = filterText(text, level: level)
        } else if var response = part["functionResponse"] as? [String: Any],
                  var responseBody = response["response"] as? [String: Any],
                  let result = responseBody["result"] as? String {
            responseBody["result"] = filterText(result, level: level)
            response["response"] = responseBody
            filtered["functionResponse"] = response
        }
        
        return filtered
    }
    
    // MARK: - Core Text Filtering
    
    private func filterText(_ text: String, level: FilterLevel) -> String {
        var filtered = text
        let patterns = level.patterns
        
        for pattern in patterns {
            filtered = redactPattern(filtered, pattern: pattern)
        }
        
        return filtered
    }
    
    private func redactPattern(_ text: String, pattern: PIIPattern) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else {
            return text
        }
        
        var result = text
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        
        // Process matches in reverse to maintain string indices
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let original = String(text[range])
            
            // Create unique placeholder if we need to restore later
            let uniquePlaceholder: String
            if let existing = redactionMap[original] {
                uniquePlaceholder = existing
            } else {
                uniquePlaceholder = "\(pattern.placeholder)_\(redactionMap.count)"
                redactionMap[original] = uniquePlaceholder
            }
            
            result = result.replacingCharacters(in: range, with: uniquePlaceholder)
        }
        
        return result
    }
    
    // MARK: - Statistics
    
    /// Get redaction statistics
    func getStats() -> [String: Any] {
        return [
            "redactions_count": redactionMap.count,
            "patterns_tracked": PIIPattern.allCases.count
        ]
    }
}

// MARK: - AppState Extension for Privacy Config

extension AppState {
    /// Privacy filter level (0=off, 1=basic, 2=standard, 3=strict)
    var privacyFilterLevel: PrivacyFilter.FilterLevel {
        get {
            // Default to standard for cloud requests
            let saved = UserDefaults.standard.integer(forKey: "privacyFilterLevel")
            return PrivacyFilter.FilterLevel(rawValue: saved == 0 ? 2 : saved) ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "privacyFilterLevel")
        }
    }
}
