// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Wind-Down Writer
// Sends the assembled day review to an agent with a summarization prompt.
// Returns a concise evening briefing (max 150 words).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor WindDownWriter {
    static let shared = WindDownWriter()

    /// Generate the evening briefing text from a day review.
    func compose(review: DayReview) async -> String {
        var prompt = buildPrompt(review: review)

        // Inject open commitments into the briefing prompt
        let commitmentsSection = await CommitmentsFollowUp.shared.windDownSection()
        if !commitmentsSection.isEmpty {
            prompt += "\n\n" + commitmentsSection
        }

        // Route through the local gateway so the agent gets full tool access,
        // memory context, and identity. Use SiD by default.
        let agentID = "sid"
        let briefing = await callAgent(prompt: prompt, agentID: agentID)

        if briefing.isEmpty {
            TorboLog.warn("Writer returned empty briefing, using fallback", subsystem: "WindDown")
            return buildFallbackBriefing(review: review)
        }

        TorboLog.info("Briefing composed: \(briefing.count) chars", subsystem: "WindDown")
        return briefing
    }

    // MARK: - Prompt Construction

    private func buildPrompt(review: DayReview) -> String {
        var parts: [String] = []

        parts.append("You are writing an evening wind-down briefing. Be warm, concise, and useful. Maximum 150 words.")
        parts.append("")
        parts.append("## Today (\(review.date))")

        // Calendar
        if !review.calendarToday.isEmpty {
            parts.append("### Events Today")
            for event in review.calendarToday {
                var line = "- \(event.startTime)–\(event.endTime): \(event.title)"
                if let loc = event.location, !loc.isEmpty { line += " (\(loc))" }
                parts.append(line)
            }
        } else {
            parts.append("No calendar events today.")
        }

        // Email
        parts.append("### Email")
        parts.append("Received: \(review.emailsReceived) | Sent: \(review.emailsSent)")
        if !review.emailHighlights.isEmpty {
            parts.append("Notable subjects: \(review.emailHighlights.joined(separator: "; "))")
        }

        // Tasks
        parts.append("### Tasks")
        if !review.tasksCompleted.isEmpty {
            parts.append("Completed: \(review.tasksCompleted.joined(separator: ", "))")
        }
        if !review.tasksPending.isEmpty {
            parts.append("Still pending: \(review.tasksPending.joined(separator: ", "))")
        }
        if !review.tasksFailed.isEmpty {
            parts.append("Failed: \(review.tasksFailed.joined(separator: ", "))")
        }
        if review.tasksCompleted.isEmpty && review.tasksPending.isEmpty {
            parts.append("No tracked tasks today.")
        }

        // Alerts
        if !review.ambientAlerts.isEmpty {
            parts.append("### Alerts Fired Today")
            for alert in review.ambientAlerts.prefix(5) {
                parts.append("- \(alert)")
            }
        }

        // Tomorrow preview
        parts.append("")
        parts.append("## Tomorrow")
        if !review.calendarTomorrow.isEmpty {
            for event in review.calendarTomorrow {
                var line = "- \(event.startTime)–\(event.endTime): \(event.title)"
                if let loc = event.location, !loc.isEmpty { line += " (\(loc))" }
                parts.append(line)
            }
        } else {
            parts.append("No events scheduled.")
        }

        parts.append("")
        parts.append("Instructions: Summarize today briefly. Flag anything unresolved — especially overdue commitments. Preview tomorrow. Keep it under 150 words. No bullet points — write in short paragraphs. Sign off warmly.")

        return parts.joined(separator: "\n")
    }

    // MARK: - Agent Call

    private func callAgent(prompt: String, agentID: String) async -> String {
        let port = AppConfig.serverPort
        let token = AppConfig.serverToken

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            TorboLog.error("Invalid gateway URL", subsystem: "WindDown")
            return ""
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(agentID, forHTTPHeaderField: "x-torbo-agent-id")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            TorboLog.error("Failed to serialize agent request", subsystem: "WindDown")
            return ""
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                TorboLog.error("Agent returned status \(status)", subsystem: "WindDown")
                return ""
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                TorboLog.error("Failed to parse agent response", subsystem: "WindDown")
                return ""
            }

            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            TorboLog.error("Agent call failed: \(error.localizedDescription)", subsystem: "WindDown")
            return ""
        }
    }

    // MARK: - Fallback

    private func buildFallbackBriefing(review: DayReview) -> String {
        var lines: [String] = []
        lines.append("Evening Briefing — \(review.date)")
        lines.append("")

        if !review.calendarToday.isEmpty {
            lines.append("Today had \(review.calendarToday.count) event(s).")
        }
        lines.append("Email: \(review.emailsReceived) received, \(review.emailsSent) sent.")

        if !review.tasksCompleted.isEmpty {
            lines.append("\(review.tasksCompleted.count) task(s) completed.")
        }
        if !review.tasksPending.isEmpty {
            lines.append("\(review.tasksPending.count) task(s) still pending.")
        }

        if !review.calendarTomorrow.isEmpty {
            lines.append("")
            lines.append("Tomorrow: \(review.calendarTomorrow.count) event(s).")
            if let first = review.calendarTomorrow.first {
                lines.append("First up: \(first.title) at \(first.startTime).")
            }
        }

        return lines.joined(separator: "\n")
    }
}
