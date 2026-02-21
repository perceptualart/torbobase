// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Wind-Down Delivery
// Pushes the evening briefing to iOS via SOC sync as EVENING_BRIEFING message type.
// Stores briefings locally in ~/Library/Application Support/TorboBase/briefings/

import Foundation
#if canImport(Network)
import Network
#endif

/// SOC sync message for evening briefings pushed to iOS.
struct EveningBriefingMessage: Codable {
    let type: String                   // "EVENING_BRIEFING"
    let date: String                   // "2026-02-20"
    let briefing: String               // The summarized text
    let hasTomorrowPrep: Bool          // Whether a research task was queued
    let earliestMeeting: String?       // Tomorrow's first meeting title
    let timestamp: Double              // Unix epoch

    static func create(date: String, briefing: String, hasTomorrowPrep: Bool, earliestMeeting: String?) -> EveningBriefingMessage {
        EveningBriefingMessage(
            type: "EVENING_BRIEFING",
            date: date,
            briefing: briefing,
            hasTomorrowPrep: hasTomorrowPrep,
            earliestMeeting: earliestMeeting,
            timestamp: Date().timeIntervalSince1970
        )
    }
}

// MARK: - Delivery Actor

actor WindDownDelivery {
    static let shared = WindDownDelivery()

    private var briefingsDir: String { PlatformPaths.dataDir + "/briefings" }

    /// Deliver the evening briefing: store locally + push to paired iOS devices.
    func deliver(briefing: String, review: DayReview, tomorrowPrepQueued: Bool) async {
        // 1. Store locally
        storeBriefing(date: review.date, briefing: briefing, review: review)

        // 2. Build SOC message
        let message = EveningBriefingMessage.create(
            date: review.date,
            briefing: briefing,
            hasTomorrowPrep: tomorrowPrepQueued,
            earliestMeeting: review.earliestMeetingTomorrow?.title
        )

        // 3. Push to all paired devices
        await pushToDevices(message: message)

        // 4. Store as conversation message so it shows up in chat history
        let convMessage = ConversationMessage(
            role: "assistant",
            content: "[Evening Briefing — \(review.date)]\n\n\(briefing)",
            model: "wind-down",
            clientIP: nil,
            agentID: "sid"
        )
        await ConversationStore.shared.appendMessage(convMessage)

        TorboLog.info("Briefing delivered for \(review.date)", subsystem: "WindDown")
    }

    // MARK: - Local Storage

    private func storeBriefing(date: String, briefing: String, review: DayReview) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: briefingsDir, withIntermediateDirectories: true)

        let filePath = briefingsDir + "/\(date).json"

        let payload: [String: Any] = [
            "date": date,
            "briefing": briefing,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "stats": [
                "events_today": review.calendarToday.count,
                "events_tomorrow": review.calendarTomorrow.count,
                "emails_received": review.emailsReceived,
                "emails_sent": review.emailsSent,
                "tasks_completed": review.tasksCompleted.count,
                "tasks_pending": review.tasksPending.count,
                "tasks_failed": review.tasksFailed.count,
                "alerts_fired": review.ambientAlerts.count
            ] as [String: Any]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            TorboLog.info("Briefing stored: \(filePath)", subsystem: "WindDown")
        } catch {
            TorboLog.error("Failed to store briefing: \(error)", subsystem: "WindDown")
        }
    }

    // MARK: - SOC Push

    private func pushToDevices(message: EveningBriefingMessage) async {
        guard let payload = try? JSONEncoder().encode(message) else {
            TorboLog.error("Failed to encode briefing message", subsystem: "WindDown")
            return
        }

        #if canImport(Network)
        // Push to each paired device via the SOC sync port
        let devices = KeychainManager.loadPairedDevices()
        guard !devices.isEmpty else {
            TorboLog.debug("No paired devices — skipping SOC push", subsystem: "WindDown")
            return
        }

        for device in devices {
            // Skip devices not seen recently (stale pairings)
            let referenceDate = device.lastSeen ?? device.pairedAt
            let age = Date().timeIntervalSince(referenceDate)
            guard age < PairedDeviceStore.tokenExpiryInterval else {
                TorboLog.debug("Skipping stale device '\(device.name)'", subsystem: "WindDown")
                continue
            }

            TorboLog.info("Pushing briefing to '\(device.name)'", subsystem: "WindDown")
            // The iOS app listens on the same SOC port for push messages from Base.
            // Deliver via the gateway's webhook system as a fallback.
            await pushViaWebhook(payload: payload, deviceToken: device.token)
        }
        #else
        TorboLog.debug("SOC push requires macOS (Network.framework)", subsystem: "WindDown")
        #endif
    }

    /// Deliver briefing via the gateway's internal webhook path.
    /// The iOS app polls /v1/briefings/latest with its device token.
    private func pushViaWebhook(payload: Data, deviceToken: String) async {
        // Store the latest briefing so iOS can poll for it
        let latestPath = briefingsDir + "/latest.json"
        do {
            try payload.write(to: URL(fileURLWithPath: latestPath), options: .atomic)
        } catch {
            TorboLog.error("Failed to write latest briefing: \(error)", subsystem: "WindDown")
        }
    }

    // MARK: - Briefing Retrieval (for API)

    func latestBriefing() -> [String: Any]? {
        let latestPath = briefingsDir + "/latest.json"
        guard let data = FileManager.default.contents(atPath: latestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    func briefing(for date: String) -> [String: Any]? {
        let filePath = briefingsDir + "/\(sanitizeDate(date)).json"
        guard let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    func listBriefings(limit: Int = 30) -> [[String: Any]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: briefingsDir) else { return [] }

        return files
            .filter { $0.hasSuffix(".json") && $0 != "latest.json" }
            .sorted(by: >)  // Most recent first
            .prefix(limit)
            .compactMap { filename -> [String: Any]? in
                let path = briefingsDir + "/\(filename)"
                guard let data = fm.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return json
            }
    }

    private func sanitizeDate(_ date: String) -> String {
        // Only allow digits and hyphens to prevent path traversal
        date.filter { $0.isNumber || $0 == "-" }
    }
}
