// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — LifeOS Predictive Task Completion Engine
// Works ahead of the user — sees what's coming and prepares without being asked.
// Calendar watcher, meeting prep, task prediction, deadline detection.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Meeting Briefing Model

struct MeetingBriefing: Codable, Identifiable {
    let id: String
    let eventTitle: String
    let eventStart: Date
    let attendees: [String]
    let briefing: String
    let emailContext: String?
    let newsContext: String?
    var alertSent: Bool
    let createdAt: Date

    func toDict() -> [String: Any] {
        let df = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": id,
            "event_title": eventTitle,
            "event_start": df.string(from: eventStart),
            "attendees": attendees,
            "briefing": briefing,
            "alert_sent": alertSent,
            "created_at": df.string(from: createdAt)
        ]
        if let email = emailContext { dict["email_context"] = email }
        if let news = newsContext { dict["news_context"] = news }
        return dict
    }
}

// MARK: - Predicted Task Model

struct PredictedTask: Codable, Identifiable {
    let id: String
    let name: String
    let suggestedCron: String
    let reasoning: String
    let confidence: Double        // 0.0-1.0
    var accepted: Bool
    var cronTaskID: String?       // ID of created cron task if accepted
    let detectedPattern: String   // e.g. "Runs every Monday at 9am"
    let createdAt: Date

    func toDict() -> [String: Any] {
        let df = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "suggested_cron": suggestedCron,
            "reasoning": reasoning,
            "confidence": confidence,
            "accepted": accepted,
            "detected_pattern": detectedPattern,
            "created_at": df.string(from: createdAt)
        ]
        if let cronID = cronTaskID { dict["cron_task_id"] = cronID }
        return dict
    }
}

// MARK: - Deadline Model

struct DetectedDeadline: Codable, Identifiable {
    let id: String
    let source: String           // "email"
    let snippet: String          // The text that triggered detection
    let parsedDate: Date?        // Best-effort date extraction
    let urgency: String          // "asap", "this_week", "next_week", "specific_date"
    let senderOrContext: String
    var reminderCreated: Bool
    let createdAt: Date

    func toDict() -> [String: Any] {
        let df = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": id,
            "source": source,
            "snippet": snippet,
            "urgency": urgency,
            "sender_or_context": senderOrContext,
            "reminder_created": reminderCreated,
            "created_at": df.string(from: createdAt)
        ]
        if let date = parsedDate { dict["parsed_date"] = df.string(from: date) }
        return dict
    }
}

// MARK: - LifeOS Predictor Engine

actor LifeOSPredictor {
    static let shared = LifeOSPredictor()

    private var isRunning = false
    private var briefings: [String: MeetingBriefing] = [:]   // keyed by id
    private var predictions: [String: PredictedTask] = [:]
    private var deadlines: [String: DetectedDeadline] = [:]
    private var preparedEventIDs: Set<String> = []           // events already prepped

    private let meetingPrepDir: String
    private let predictionsFile: String
    private let deadlinesFile: String

    init() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        meetingPrepDir = home + "/Library/Application Support/TorboBase/meeting-prep"
        predictionsFile = PlatformPaths.dataDir + "/lifeos_predictions.json"
        deadlinesFile = PlatformPaths.dataDir + "/lifeos_deadlines.json"
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        ensureDirectories()
        loadState()
        TorboLog.info("LifeOS Predictor started", subsystem: "LifeOS")

        // Calendar watcher — every hour, scan next 24 hours
        Task { await calendarWatcherLoop() }

        // Deadline detector — every 2 hours, scan recent emails
        Task { await deadlineDetectorLoop() }

        // Task prediction — every 6 hours, analyze cron patterns
        Task { await taskPredictionLoop() }
    }

    func stop() {
        isRunning = false
        saveState()
        TorboLog.info("LifeOS Predictor stopped", subsystem: "LifeOS")
    }

    // MARK: - Calendar Watcher Loop (hourly)

    private func calendarWatcherLoop() async {
        while isRunning {
            await scanUpcomingMeetings()
            try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000) // 1 hour
        }
    }

    /// Scan next 24 hours of calendar events, prep meetings that are ~2 hours away
    private func scanUpcomingMeetings() async {
        let now = Date()
        let in24h = Calendar.current.date(byAdding: .hour, value: 24, to: now) ?? now

        let events = await CalendarManager.shared.listEvents(from: now, to: in24h)
        if events.isEmpty { return }

        TorboLog.info("Calendar scan: \(events.count) event(s) in next 24h", subsystem: "LifeOS")

        for event in events {
            // Skip all-day events and already-prepped events
            guard !event.isAllDay else { continue }
            guard !preparedEventIDs.contains(event.id) else { continue }

            // Prep meetings that are 1.5-3 hours away (targeting ~2h window)
            let hoursUntil = event.startDate.timeIntervalSince(now) / 3600
            guard hoursUntil >= 1.5 && hoursUntil <= 3.0 else { continue }

            // Extract attendee names from event title and notes
            let attendees = extractAttendees(from: event)
            guard !attendees.isEmpty else { continue }

            TorboLog.info("Preparing briefing for '\(event.title)' in \(String(format: "%.1f", hoursUntil))h", subsystem: "LifeOS")

            await prepareMeetingBriefing(event: event, attendees: attendees)
            preparedEventIDs.insert(event.id)
        }

        // Prune old event IDs (older than 48h)
        let cutoff = Calendar.current.date(byAdding: .hour, value: -48, to: now) ?? now
        briefings = briefings.filter { $0.value.eventStart > cutoff }
        saveState()
    }

    // MARK: - Meeting Prep Engine

    private func prepareMeetingBriefing(event: CalendarEvent, attendees: [String]) async {
        var attendeeResearch: [String] = []
        var emailContext: [String] = []
        var newsContext: [String] = []

        // 1. Research attendees via web search
        for attendee in attendees {
            let research = await searchAttendee(attendee)
            if !research.isEmpty {
                attendeeResearch.append("**\(attendee):** \(research)")
            }
        }

        // 2. Pull relevant email threads mentioning attendee names
        #if os(macOS)
        for attendee in attendees {
            let emails = await searchEmailsForAttendee(attendee)
            if !emails.isEmpty {
                emailContext.append("Emails mentioning \(attendee):\n\(emails)")
            }
        }
        #endif

        // 3. Check if any attendee's company is in recent news
        for attendee in attendees {
            let news = await searchNewsForAttendee(attendee)
            if !news.isEmpty {
                newsContext.append(news)
            }
        }

        // 4. Generate 100-word briefing via LLM
        let briefingText = await generateBriefing(
            event: event,
            attendees: attendees,
            research: attendeeResearch,
            emails: emailContext,
            news: newsContext
        )

        // 5. Store briefing
        let briefing = MeetingBriefing(
            id: generateID("brief"),
            eventTitle: event.title,
            eventStart: event.startDate,
            attendees: attendees,
            briefing: briefingText,
            emailContext: emailContext.isEmpty ? nil : emailContext.joined(separator: "\n\n"),
            newsContext: newsContext.isEmpty ? nil : newsContext.joined(separator: "\n\n"),
            alertSent: false,
            createdAt: Date()
        )
        briefings[briefing.id] = briefing

        // 6. Write to disk
        saveBriefingToDisk(briefing)

        // 7. Create alert via ConversationStore (visible to all clients)
        let hoursUntil = Int(event.startDate.timeIntervalSince(Date()) / 3600)
        let alertMsg = "Your meeting '\(event.title)' is in ~\(hoursUntil) hours. I've prepared a briefing on \(attendees.joined(separator: ", "))."
        await postLifeOSAlert(alertMsg)

        // Mark alert as sent
        briefings[briefing.id]?.alertSent = true
        saveState()

        TorboLog.info("Briefing ready for '\(event.title)' — \(attendees.count) attendee(s)", subsystem: "LifeOS")

        // Publish to event bus
        let briefingID = briefing.id
        let eventTitle = event.title
        let attendeeCount = attendees.count
        Task {
            await EventBus.shared.publish("lifeos.briefing.ready",
                payload: ["briefing_id": briefingID, "event_title": eventTitle, "attendee_count": "\(attendeeCount)"],
                source: "LifeOS")
        }
    }

    /// Extract attendee names from event title, notes, and location
    private func extractAttendees(from event: CalendarEvent) -> [String] {
        var names: [String] = []
        let combined = [event.title, event.notes ?? "", event.location ?? ""].joined(separator: " ")

        // Pattern: "Meeting with John Smith" or "Call with Jane Doe"
        let withPattern = try? NSRegularExpression(pattern: "(?:meeting|call|sync|chat|1:1|1-on-1|coffee|lunch|dinner)\\s+with\\s+([A-Z][a-z]+(?:\\s+[A-Z][a-z]+)+)", options: .caseInsensitive)
        if let matches = withPattern?.matches(in: combined, range: NSRange(combined.startIndex..., in: combined)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: combined) {
                    names.append(String(combined[range]))
                }
            }
        }

        // Pattern: names in notes field (comma-separated or newline-separated names with Title Case)
        if let notes = event.notes, !notes.isEmpty {
            let namePattern = try? NSRegularExpression(pattern: "\\b([A-Z][a-z]{1,15}\\s+[A-Z][a-z]{1,20})\\b")
            if let nameMatches = namePattern?.matches(in: notes, range: NSRange(notes.startIndex..., in: notes)) {
                for match in nameMatches {
                    if let range = Range(match.range(at: 1), in: notes) {
                        let name = String(notes[range])
                        // Filter out common false positives
                        let falsePositives = ["Meeting Room", "Conference Room", "Google Meet", "Microsoft Teams", "Zoom Call"]
                        if !falsePositives.contains(name) && !names.contains(name) {
                            names.append(name)
                        }
                    }
                }
            }
        }

        return Array(Set(names)).sorted()
    }

    /// Search for attendee info via DuckDuckGo
    private func searchAttendee(_ name: String) async -> String {
        let query = "\(name) professional background"
        let searchURL = "https://html.duckduckgo.com/html/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"

        guard let url = URL(string: searchURL) else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return "" }
            let html = String(data: data, encoding: .utf8) ?? ""
            let snippets = extractDDGSnippets(html: html, limit: 2)
            return snippets.joined(separator: " ")
        } catch {
            TorboLog.debug("Web search failed for '\(name)': \(error)", subsystem: "LifeOS")
            return ""
        }
    }

    /// Pull recent emails mentioning an attendee name
    private func searchEmailsForAttendee(_ name: String) async -> String {
        #if os(macOS)
        let safeName = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Mail"
            set foundMessages to {}
            set searchResults to messages of mailbox "INBOX" whose subject contains "\(safeName)" or sender contains "\(safeName)"
            set msgCount to count of searchResults
            if msgCount is 0 then return ""
            set maxMsgs to 3
            if msgCount < maxMsgs then set maxMsgs to msgCount
            repeat with i from 1 to maxMsgs
                set msg to item i of searchResults
                set msgInfo to "FROM: " & sender of msg & " | SUBJECT: " & subject of msg & " | DATE: " & (date received of msg as string)
                set end of foundMessages to msgInfo
            end repeat
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to "\\n"
            set output to foundMessages as string
            set AppleScript's text item delimiters to oldDelimiters
            return output
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let startTime = Date()
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > 15 {
                    process.terminate()
                    return ""
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let data = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
        #else
        return ""
        #endif
    }

    /// Search for recent news about an attendee or their company
    private func searchNewsForAttendee(_ name: String) async -> String {
        let query = "\(name) company news 2026"
        let searchURL = "https://html.duckduckgo.com/html/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"

        guard let url = URL(string: searchURL) else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return "" }
            let html = String(data: data, encoding: .utf8) ?? ""
            let snippets = extractDDGSnippets(html: html, limit: 2)
            return snippets.isEmpty ? "" : "Recent news: \(snippets.joined(separator: " "))"
        } catch {
            return ""
        }
    }

    /// Generate a concise ~100 word briefing via local LLM
    private func generateBriefing(event: CalendarEvent, attendees: [String], research: [String], emails: [String], news: [String]) async -> String {
        var prompt = "Write a concise 100-word meeting briefing.\n\n"
        prompt += "Meeting: \(event.title)\n"
        prompt += "Attendees: \(attendees.joined(separator: ", "))\n"
        if let location = event.location { prompt += "Location: \(location)\n" }
        if let notes = event.notes { prompt += "Notes: \(String(notes.prefix(300)))\n" }

        if !research.isEmpty {
            prompt += "\nAttendee Research:\n\(research.joined(separator: "\n"))\n"
        }
        if !emails.isEmpty {
            prompt += "\nRecent Email Context:\n\(emails.joined(separator: "\n"))\n"
        }
        if !news.isEmpty {
            prompt += "\nRecent News:\n\(news.joined(separator: "\n"))\n"
        }

        prompt += "\nWrite a brief, actionable meeting prep note. Include: who you're meeting, key context, and any talking points. Keep it under 100 words."

        // Use local Ollama for the briefing
        let body: [String: Any] = [
            "model": "qwen2.5:7b",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.3, "num_predict": 200]
        ]

        guard let url = URL(string: OllamaManager.baseURL + "/api/generate") else {
            return "Meeting with \(attendees.joined(separator: ", ")) — \(event.title). Review attendee backgrounds before the call."
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String, !response.isEmpty {
                return String(response.prefix(600))
            }
        } catch {
            TorboLog.debug("LLM briefing generation failed: \(error)", subsystem: "LifeOS")
        }

        // Fallback briefing
        return "Meeting: \(event.title). Attendees: \(attendees.joined(separator: ", ")). Review context and prepare talking points."
    }

    // MARK: - Deadline Detector Loop (every 2 hours)

    private func deadlineDetectorLoop() async {
        while isRunning {
            await scanEmailsForDeadlines()
            try? await Task.sleep(nanoseconds: 7200 * 1_000_000_000) // 2 hours
        }
    }

    /// Scan recent emails for deadline language
    private func scanEmailsForDeadlines() async {
        #if os(macOS)
        let emailContent = await EmailManager.shared.checkEmail(limit: 20, mailbox: "INBOX")

        // Parse email IDs from check_email output
        let lines = emailContent.split(separator: "\n").map(String.init)
        var emailIDs: [String] = []
        for line in lines {
            if let range = line.range(of: "ID: ") {
                let afterID = line[range.upperBound...]
                if let pipeRange = afterID.range(of: " | ") {
                    emailIDs.append(String(afterID[..<pipeRange.lowerBound]))
                }
            }
        }

        // Read each email and scan for deadline patterns
        let deadlinePatterns: [(pattern: String, urgency: String)] = [
            ("\\b(ASAP|as soon as possible|immediately|right away|urgent)\\b", "asap"),
            ("\\bby (this |end of )?friday\\b", "this_week"),
            ("\\bby (this |end of )?(monday|tuesday|wednesday|thursday)\\b", "this_week"),
            ("\\bdue (this|next) week\\b", "this_week"),
            ("\\bdue next week\\b", "next_week"),
            ("\\bby next (monday|tuesday|wednesday|thursday|friday)\\b", "next_week"),
            ("\\bdeadline[: ]", "specific_date"),
            ("\\bdue (date|by|on)[: ]", "specific_date"),
            ("\\bno later than\\b", "specific_date"),
            ("\\bmust be (completed|done|finished|submitted) by\\b", "specific_date"),
            ("\\bend of (day|business|week|month)\\b", "this_week")
        ]

        for emailID in emailIDs.prefix(10) {
            // Skip already-detected deadlines for this email
            let alreadyScanned = deadlines.values.contains { $0.senderOrContext.contains("email:\(emailID)") }
            if alreadyScanned { continue }

            let content = await EmailManager.shared.readEmail(id: emailID)
            let cleanContent = content.lowercased()

            for (pattern, urgency) in deadlinePatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let matches = regex.matches(in: cleanContent, range: NSRange(cleanContent.startIndex..., in: cleanContent))

                for match in matches {
                    if let range = Range(match.range, in: cleanContent) {
                        // Extract context around the match (up to 100 chars before and after)
                        let matchStart = cleanContent.index(range.lowerBound, offsetBy: -min(100, cleanContent.distance(from: cleanContent.startIndex, to: range.lowerBound)), limitedBy: cleanContent.startIndex) ?? cleanContent.startIndex
                        let matchEnd = cleanContent.index(range.upperBound, offsetBy: min(100, cleanContent.distance(from: range.upperBound, to: cleanContent.endIndex)), limitedBy: cleanContent.endIndex) ?? cleanContent.endIndex
                        let snippet = String(cleanContent[matchStart..<matchEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

                        // Extract sender from the email line
                        let senderLine = lines.first { $0.contains("ID: \(emailID)") } ?? ""
                        let sender: String
                        if let fromRange = senderLine.range(of: "FROM: "),
                           let pipeRange = senderLine[fromRange.upperBound...].range(of: " | ") {
                            sender = String(senderLine[fromRange.upperBound..<pipeRange.lowerBound])
                        } else {
                            sender = "unknown"
                        }

                        let deadline = DetectedDeadline(
                            id: generateID("dl"),
                            source: "email",
                            snippet: String(snippet.prefix(300)),
                            parsedDate: parseDeadlineDate(from: snippet, urgency: urgency),
                            urgency: urgency,
                            senderOrContext: "email:\(emailID) from \(sender)",
                            reminderCreated: false,
                            createdAt: Date()
                        )
                        deadlines[deadline.id] = deadline

                        // Publish deadline detection event
                        let dlID = deadline.id
                        let dlUrgency = urgency
                        let dlSender = sender
                        Task {
                            await EventBus.shared.publish("lifeos.prediction.made",
                                payload: ["deadline_id": dlID, "urgency": dlUrgency, "source": "email", "sender": dlSender],
                                source: "LifeOS")
                        }

                        // Create alert for urgent deadlines
                        if urgency == "asap" || urgency == "this_week" {
                            let urgencyLabel = urgency == "asap" ? "URGENT" : "This Week"
                            await postLifeOSAlert("[\(urgencyLabel)] Deadline detected from \(sender): \"\(String(snippet.prefix(80)))...\"")
                        }

                        break // One deadline per email per pattern is enough
                    }
                }
            }
        }

        saveState()
        let newCount = deadlines.values.filter { Calendar.current.isDateInToday($0.createdAt) }.count
        if newCount > 0 {
            TorboLog.info("Deadline scan: \(newCount) new deadline(s) detected", subsystem: "LifeOS")
        }
        #endif
    }

    /// Best-effort date parsing from deadline language
    private func parseDeadlineDate(from text: String, urgency: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        switch urgency {
        case "asap":
            return now // Due immediately
        case "this_week":
            // End of this business week (Friday 5pm)
            var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = 6 // Friday
            comps.hour = 17
            return calendar.date(from: comps)
        case "next_week":
            guard let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: now) else { return nil }
            var comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: nextWeek)
            comps.weekday = 6
            comps.hour = 17
            return calendar.date(from: comps)
        default:
            return nil // Can't determine specific date
        }
    }

    // MARK: - Task Prediction Loop (every 6 hours)

    private func taskPredictionLoop() async {
        // Wait 30 seconds on startup to let cron scheduler initialize
        try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)

        while isRunning {
            await analyzeTaskPatterns()
            try? await Task.sleep(nanoseconds: 21600 * 1_000_000_000) // 6 hours
        }
    }

    /// Analyze completed cron tasks and manual patterns to suggest automations
    private func analyzeTaskPatterns() async {
        let cronTasks = await CronScheduler.shared.listTasks()
        guard !cronTasks.isEmpty else { return }

        // Build a history map: (taskName, dayOfWeek, hour) -> runCount
        var patternMap: [String: [(weekday: Int, hour: Int, count: Int)]] = [:]

        for task in cronTasks where task.runCount >= 3 {
            guard let expr = CronExpression.parse(task.cronExpression) else { continue }

            // Detect simple patterns: specific day+hour combinations
            if expr.daysOfWeek.count <= 2 && expr.hours.count <= 2 {
                for day in expr.daysOfWeek {
                    for hour in expr.hours {
                        let key = task.prompt.prefix(50).lowercased()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        var entries = patternMap[String(key)] ?? []
                        entries.append((weekday: day, hour: hour, count: task.runCount))
                        patternMap[String(key)] = entries
                    }
                }
            }
        }

        // Look for manually triggered tasks (via run_now) that happen at consistent times
        let recentTasks = await TaskQueue.shared.recentCompleted(limit: 50)
        var manualPatterns: [String: [Date]] = [:]
        for task in recentTasks {
            guard task.assignedBy != "cron",
                  let completedAt = task.completedAt else { continue }
            let key = task.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            var dates = manualPatterns[key] ?? []
            dates.append(completedAt)
            manualPatterns[key] = dates
        }

        // Detect weekly patterns from manual tasks
        for (taskName, dates) in manualPatterns where dates.count >= 3 {
            // Skip if we already have a prediction for this
            let alreadyPredicted = predictions.values.contains {
                $0.name.lowercased().contains(taskName.prefix(20).lowercased())
            }
            if alreadyPredicted { continue }

            // Check if runs cluster on same weekday
            let calendar = Calendar.current
            var weekdayCounts: [Int: Int] = [:]
            var hourCounts: [Int: Int] = [:]

            for date in dates {
                let weekday = calendar.component(.weekday, from: date) - 1 // 0=Sunday
                let hour = calendar.component(.hour, from: date)
                weekdayCounts[weekday, default: 0] += 1
                hourCounts[hour, default: 0] += 1
            }

            // If 60%+ runs are on the same weekday, suggest a cron
            if let (topDay, topDayCount) = weekdayCounts.max(by: { $0.value < $1.value }),
               Double(topDayCount) / Double(dates.count) >= 0.6 {
                let topHour = hourCounts.max(by: { $0.value < $1.value })?.key ?? 9
                let cronExpr = "0 \(topHour) * * \(topDay)"
                let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                let dayName = topDay < dayNames.count ? dayNames[topDay] : "?"
                let confidence = Double(topDayCount) / Double(dates.count)

                let prediction = PredictedTask(
                    id: generateID("pred"),
                    name: "Auto-schedule: \(taskName.prefix(60))",
                    suggestedCron: cronExpr,
                    reasoning: "You've run '\(taskName.prefix(40))' \(dates.count) times. \(topDayCount) of those were on \(dayName) around \(topHour):00.",
                    confidence: confidence,
                    accepted: false,
                    cronTaskID: nil,
                    detectedPattern: "Every \(dayName) at \(topHour):00",
                    createdAt: Date()
                )
                predictions[prediction.id] = prediction

                TorboLog.info("Pattern detected: '\(taskName.prefix(40))' -> \(dayName) \(topHour):00 (confidence: \(String(format: "%.0f%%", confidence * 100)))", subsystem: "LifeOS")
            }
        }

        saveState()
    }

    // MARK: - Accept Predicted Task -> Convert to Cron

    func acceptPrediction(id: String) async -> CronTask? {
        guard var prediction = predictions[id], !prediction.accepted else { return nil }

        let cronTask = await CronScheduler.shared.createTask(
            name: prediction.name,
            cronExpression: prediction.suggestedCron,
            agentID: "sid",
            prompt: "Execute the task: \(prediction.name)"
        )

        guard let task = cronTask else { return nil }

        prediction.accepted = true
        prediction.cronTaskID = task.id
        predictions[id] = prediction
        saveState()

        TorboLog.info("Prediction accepted: '\(prediction.name)' -> cron task \(task.id)", subsystem: "LifeOS")
        return task
    }

    // MARK: - Query Methods

    func getBriefings(for date: Date? = nil) -> [MeetingBriefing] {
        let calendar = Calendar.current
        if let target = date {
            return briefings.values.filter { calendar.isDate($0.eventStart, inSameDayAs: target) }
                .sorted { $0.eventStart < $1.eventStart }
        }
        return Array(briefings.values).sorted { $0.eventStart < $1.eventStart }
    }

    func getPredictions() -> [PredictedTask] {
        Array(predictions.values).sorted { $0.confidence > $1.confidence }
    }

    func getDeadlines() -> [DetectedDeadline] {
        Array(deadlines.values).sorted { ($0.parsedDate ?? .distantFuture) < ($1.parsedDate ?? .distantFuture) }
    }

    func stats() -> [String: Any] {
        [
            "running": isRunning,
            "briefings_count": briefings.count,
            "predictions_count": predictions.count,
            "deadlines_count": deadlines.count,
            "prepared_events": preparedEventIDs.count,
            "accepted_predictions": predictions.values.filter { $0.accepted }.count,
            "urgent_deadlines": deadlines.values.filter { $0.urgency == "asap" }.count
        ]
    }

    // MARK: - Alerts

    /// Post a LifeOS alert as a conversation message (visible to all clients)
    private func postLifeOSAlert(_ message: String) async {
        let msg = ConversationMessage(
            role: "assistant",
            content: "[LifeOS] \(message)",
            model: "lifeos-predictor",
            clientIP: nil,
            agentID: "sid"
        )
        await ConversationStore.shared.appendMessage(msg)
        TorboLog.info(String(message.prefix(100)), subsystem: "LifeOS")
    }

    // MARK: - Persistence

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(atPath: meetingPrepDir, withIntermediateDirectories: true)
    }

    private func saveBriefingToDisk(_ briefing: MeetingBriefing) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: briefing.eventStart)
        let dir = meetingPrepDir + "/\(dateStr)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let safeTitle = briefing.eventTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(60)
        let filePath = dir + "/\(safeTitle).md"

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"

        var content = "# Meeting Briefing: \(briefing.eventTitle)\n\n"
        content += "**Time:** \(timeFmt.string(from: briefing.eventStart))\n"
        content += "**Attendees:** \(briefing.attendees.joined(separator: ", "))\n\n"
        content += "---\n\n"
        content += briefing.briefing + "\n"

        if let emails = briefing.emailContext {
            content += "\n---\n\n## Recent Email Context\n\n\(emails)\n"
        }
        if let news = briefing.newsContext {
            content += "\n---\n\n## Recent News\n\n\(news)\n"
        }

        content += "\n---\n*Generated by Torbo Base LifeOS at \(ISO8601DateFormatter().string(from: briefing.createdAt))*\n"

        do {
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            TorboLog.info("Briefing saved: \(filePath)", subsystem: "LifeOS")
        } catch {
            TorboLog.error("Failed to write briefing: \(error)", subsystem: "LifeOS")
        }
    }

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Save predictions
        do {
            let data = try encoder.encode(Array(predictions.values))
            try data.write(to: URL(fileURLWithPath: predictionsFile), options: .atomic)
        } catch {
            TorboLog.error("Failed to save predictions: \(error)", subsystem: "LifeOS")
        }

        // Save deadlines
        do {
            let data = try encoder.encode(Array(deadlines.values))
            try data.write(to: URL(fileURLWithPath: deadlinesFile), options: .atomic)
        } catch {
            TorboLog.error("Failed to save deadlines: \(error)", subsystem: "LifeOS")
        }
    }

    private func loadState() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: URL(fileURLWithPath: predictionsFile)),
           let loaded = try? decoder.decode([PredictedTask].self, from: data) {
            for item in loaded { predictions[item.id] = item }
            TorboLog.info("Loaded \(predictions.count) prediction(s)", subsystem: "LifeOS")
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: deadlinesFile)),
           let loaded = try? decoder.decode([DetectedDeadline].self, from: data) {
            for item in loaded { deadlines[item.id] = item }
            TorboLog.info("Loaded \(deadlines.count) deadline(s)", subsystem: "LifeOS")
        }
    }

    // MARK: - Helpers

    private func generateID(_ prefix: String) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "\(prefix)_" + String((0..<8).map { _ in chars.randomElement()! })
    }

    /// Extract text snippets from DuckDuckGo HTML results
    private func extractDDGSnippets(html: String, limit: Int) -> [String] {
        var snippets: [String] = []
        let snippetPattern = try? NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>([^<]+)</", options: .caseInsensitive)
        if let matches = snippetPattern?.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            for match in matches.prefix(limit) {
                if let range = Range(match.range(at: 1), in: html) {
                    let text = String(html[range])
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&#x27;", with: "'")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        snippets.append(String(text.prefix(200)))
                    }
                }
            }
        }
        return snippets
    }
}
