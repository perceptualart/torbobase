// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Expression Parser & Utilities
// High-level cron utilities: keyword resolution, validation, human-readable descriptions,
// and next-N-runs preview. Works with the CronExpression struct in CronScheduler.swift.

import Foundation

// MARK: - Cron Parser Utilities

enum CronParser {

    // MARK: - Special Keywords

    /// Map of special cron keywords to their 5-field equivalents.
    static let keywords: [String: String] = [
        "@yearly":   "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
        "@monthly":  "0 0 1 * *",
        "@weekly":   "0 0 * * 0",
        "@daily":    "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@hourly":   "0 * * * *",
    ]

    /// Resolve special keywords (@hourly, @daily, etc.) into standard 5-field cron expressions.
    /// If the expression is already a 5-field string, returns it unchanged.
    static func resolveKeyword(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        return keywords[trimmed] ?? expression
    }

    // MARK: - Validation

    struct ValidationResult {
        let isValid: Bool
        let expression: String      // The resolved expression (keywords expanded)
        let error: String?          // Human-readable error if invalid
        let description: String?    // Human-readable description if valid
    }

    /// Validate a cron expression and return detailed results.
    static func validate(_ expression: String) -> ValidationResult {
        let resolved = resolveKeyword(expression)

        let fields = resolved.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map(String.init)

        guard fields.count == 5 else {
            return ValidationResult(
                isValid: false, expression: resolved,
                error: "Expected 5 fields (minute hour day month weekday), got \(fields.count)",
                description: nil
            )
        }

        // Validate each field
        let fieldNames = ["minute", "hour", "day-of-month", "month", "day-of-week"]
        let fieldRanges = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]

        for (i, field) in fields.enumerated() {
            if let error = validateField(field, name: fieldNames[i],
                                         min: fieldRanges[i].0, max: fieldRanges[i].1) {
                return ValidationResult(isValid: false, expression: resolved,
                                        error: error, description: nil)
            }
        }

        // Full parse check
        guard CronExpression.parse(resolved) != nil else {
            return ValidationResult(isValid: false, expression: resolved,
                                    error: "Expression parses but produces no valid times",
                                    description: nil)
        }

        return ValidationResult(
            isValid: true, expression: resolved, error: nil,
            description: describe(resolved)
        )
    }

    private static func validateField(_ field: String, name: String, min: Int, max: Int) -> String? {
        let parts = field.split(separator: ",").map(String.init)
        for part in parts {
            if part == "*" { continue }

            if part.contains("/") {
                let stepParts = part.split(separator: "/").map(String.init)
                guard stepParts.count == 2 else {
                    return "\(name): invalid step '\(part)' — expected format */N or M-N/S"
                }
                guard let step = Int(stepParts[1]), step > 0 else {
                    return "\(name): step value must be a positive integer, got '\(stepParts[1])'"
                }
                if stepParts[0] != "*" && !stepParts[0].contains("-") {
                    if let val = Int(stepParts[0]) {
                        if val < min || val > max {
                            return "\(name): value \(val) out of range (\(min)-\(max))"
                        }
                    } else {
                        return "\(name): invalid start value '\(stepParts[0])'"
                    }
                }
                continue
            }

            if part.contains("-") {
                let rangeParts = part.split(separator: "-").map(String.init)
                guard rangeParts.count == 2,
                      let start = Int(rangeParts[0]),
                      let end = Int(rangeParts[1]) else {
                    return "\(name): invalid range '\(part)' — expected M-N"
                }
                if start < min || start > max {
                    return "\(name): range start \(start) out of range (\(min)-\(max))"
                }
                if end < min || end > max {
                    return "\(name): range end \(end) out of range (\(min)-\(max))"
                }
                if start > end {
                    return "\(name): range start (\(start)) must be <= end (\(end))"
                }
                continue
            }

            // Handle day-of-week names
            if name == "day-of-week" {
                let upper = part.uppercased()
                if ["SUN","MON","TUE","WED","THU","FRI","SAT"].contains(upper) { continue }
            }

            guard let val = Int(part) else {
                return "\(name): '\(part)' is not a valid number"
            }
            if val < min || val > max {
                return "\(name): value \(val) out of range (\(min)-\(max))"
            }
        }
        return nil
    }

    // MARK: - Human-Readable Description

    /// Generate a human-readable description of a cron expression.
    static func describe(_ expression: String) -> String {
        let resolved = resolveKeyword(expression)
        let fields = resolved.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map(String.init)
        guard fields.count == 5 else { return "Invalid expression" }

        let minute = fields[0]
        let hour = fields[1]
        let dom = fields[2]
        let month = fields[3]
        let dow = fields[4]

        // Common patterns — check specific first
        if minute == "* " || (minute == "*" && hour == "*" && dom == "*" && month == "*" && dow == "*") {
            // Check the actual simple patterns
        }

        // Every minute
        if minute == "*" && hour == "*" && dom == "*" && month == "*" && dow == "*" {
            return "Every minute"
        }

        // Every N minutes
        if minute.hasPrefix("*/"), hour == "*", dom == "*", month == "*", dow == "*" {
            if let n = Int(minute.dropFirst(2)) {
                return n == 1 ? "Every minute" : "Every \(n) minutes"
            }
        }

        // Every hour at minute M
        if hour == "*" && dom == "*" && month == "*" && dow == "*" {
            if let m = Int(minute) {
                return m == 0 ? "Every hour" : "Every hour at minute \(m)"
            }
        }

        // Build description for complex expressions
        var parts: [String] = []

        // Time component
        let timeDesc = describeTime(minute: minute, hour: hour)

        // Day-of-week component
        let dowDesc = describeDaysOfWeek(dow)

        // Day-of-month component
        let domDesc = describeDaysOfMonth(dom)

        // Month component
        let monthDesc = describeMonths(month)

        // Assemble
        if dom == "*" && dow == "*" && month == "*" {
            // Daily pattern
            parts.append("Daily")
            parts.append(timeDesc)
        } else if dom == "*" && month == "*" && dow != "*" {
            // Weekly pattern
            parts.append(dowDesc)
            parts.append(timeDesc)
        } else if dow == "*" && month == "*" && dom != "*" {
            // Monthly pattern
            parts.append("Monthly on \(domDesc)")
            parts.append(timeDesc)
        } else {
            // Complex pattern
            if month != "*" { parts.append(monthDesc) }
            if dom != "*" { parts.append("on \(domDesc)") }
            if dow != "*" { parts.append(dowDesc) }
            parts.append(timeDesc)
        }

        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func describeTime(minute: String, hour: String) -> String {
        if minute == "*" && hour == "*" { return "every minute" }
        if minute.hasPrefix("*/") {
            let n = String(minute.dropFirst(2))
            let hourPart = hour == "*" ? "" : " during hour \(hour)"
            return "every \(n) minutes\(hourPart)"
        }
        if hour == "*" {
            return "every hour at :\(minute.count == 1 ? "0" + minute : minute)"
        }

        // Specific time
        if let h = Int(hour), let m = Int(minute) {
            let ampm = h >= 12 ? "PM" : "AM"
            let displayHour = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            return "at \(displayHour):\(String(format: "%02d", m)) \(ampm)"
        }

        // Range/list hours
        return "at \(formatField(hour, unit: "hour")):\(minute.count == 1 ? "0" + minute : minute)"
    }

    private static func describeDaysOfWeek(_ field: String) -> String {
        if field == "*" { return "" }
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        if field == "1-5" || field == "MON-FRI" { return "Weekdays" }
        if field == "0,6" || field == "SAT,SUN" { return "Weekends" }

        let parts = field.split(separator: ",").map(String.init)
        let names = parts.compactMap { part -> String? in
            if let n = Int(part), n >= 0, n <= 6 { return dayNames[n] }
            if part.contains("-") {
                let range = part.split(separator: "-").map(String.init)
                if let s = Int(range.first ?? ""), let e = Int(range.last ?? ""),
                   s >= 0, s <= 6, e >= 0, e <= 6 {
                    return "\(dayNames[s])-\(dayNames[e])"
                }
            }
            // Named days
            let upper = part.uppercased()
            let nameMap = ["SUN": "Sunday", "MON": "Monday", "TUE": "Tuesday",
                           "WED": "Wednesday", "THU": "Thursday", "FRI": "Friday", "SAT": "Saturday"]
            return nameMap[upper]
        }

        if names.count == 1 { return "Every \(names[0])" }
        return names.joined(separator: ", ")
    }

    private static func describeDaysOfMonth(_ field: String) -> String {
        if field == "*" { return "" }
        if let n = Int(field) { return "the \(ordinal(n))" }
        return "day \(field)"
    }

    private static func describeMonths(_ field: String) -> String {
        if field == "*" { return "" }
        let monthNames = ["", "January", "February", "March", "April", "May", "June",
                          "July", "August", "September", "October", "November", "December"]
        if let n = Int(field), n >= 1, n <= 12 { return "In \(monthNames[n])" }
        return "Month \(field)"
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        let tens = n % 100
        if tens >= 11 && tens <= 13 {
            suffix = "th"
        } else {
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    private static func formatField(_ field: String, unit: String) -> String {
        if field.hasPrefix("*/") { return "every \(field.dropFirst(2)) \(unit)s" }
        return field
    }

    // MARK: - Next Runs Preview

    /// Calculate the next N execution times for a cron expression.
    static func nextRuns(_ expression: String, count: Int = 5, after: Date = Date(),
                         timeZone: TimeZone? = nil) -> [Date] {
        let resolved = resolveKeyword(expression)
        guard let parsed = CronExpression.parse(resolved) else { return [] }

        var runs: [Date] = []

        // Apply timezone offset if specified
        let tz = timeZone ?? .current
        let offset = TimeInterval(tz.secondsFromGMT(for: after) - TimeZone.current.secondsFromGMT(for: after))

        let adjustedStart = after.addingTimeInterval(-offset)

        var cursor = adjustedStart
        for _ in 0..<count {
            guard let next = parsed.nextRunAfter(cursor) else { break }
            runs.append(next.addingTimeInterval(offset))
            cursor = next
        }
        return runs
    }

    // MARK: - Expression Builder Helpers

    /// Common cron patterns for the UI expression builder.
    static let commonPatterns: [(label: String, expression: String)] = [
        ("Every minute",           "* * * * *"),
        ("Every 5 minutes",        "*/5 * * * *"),
        ("Every 15 minutes",       "*/15 * * * *"),
        ("Every 30 minutes",       "*/30 * * * *"),
        ("Every hour",             "0 * * * *"),
        ("Every 2 hours",          "0 */2 * * *"),
        ("Every 6 hours",          "0 */6 * * *"),
        ("Daily at midnight",      "0 0 * * *"),
        ("Daily at 8 AM",          "0 8 * * *"),
        ("Daily at 6 PM",          "0 18 * * *"),
        ("Weekdays at 9 AM",       "0 9 * * 1-5"),
        ("Every Monday at 9 AM",   "0 9 * * 1"),
        ("Every Friday at 5 PM",   "0 17 * * 5"),
        ("1st of month at 9 AM",   "0 9 1 * *"),
        ("Every Sunday at noon",   "0 12 * * 0"),
    ]
}
