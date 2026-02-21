// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient Alert Manager
import Foundation

actor AmbientAlertManager {
    static let shared = AmbientAlertManager()
    private var alerts: [AmbientAlert] = []
    private let maxAlerts = 500
    private var alertsFilePath: String { PlatformPaths.dataDir + "/ambient_alerts.json" }

    func initialize() {
        loadAlerts()
        TorboLog.info("Loaded \(alerts.count) ambient alert(s)", subsystem: "Ambient")
    }

    func addAlert(_ alert: AmbientAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > maxAlerts { alerts = Array(alerts.prefix(maxAlerts)) }
        saveAlerts()
        TorboLog.info("[\(alert.type)] \(alert.message)", subsystem: "Ambient")
    }

    func isDuplicate(type: String, deviceID: String?, cooldownMinutes: Int) -> Bool {
        let cutoff = Date().timeIntervalSince1970 - Double(cooldownMinutes * 60)
        return alerts.contains { a in
            a.type == type && a.timestamp > cutoff && !a.dismissed
            && (deviceID == nil || a.message.contains(deviceID ?? ""))
        }
    }

    func getAlerts(type: String? = nil, limit: Int = 50) -> [AmbientAlert] {
        var result = alerts
        if let type { result = result.filter { $0.type == type } }
        return Array(result.prefix(limit))
    }

    func activeAlerts() -> [AmbientAlert] { alerts.filter { !$0.dismissed } }

    func dismiss(id: String) -> Bool {
        guard let idx = alerts.firstIndex(where: { $0.id == id }) else { return false }
        alerts[idx].dismissed = true
        saveAlerts()
        return true
    }

    func dismissAll() {
        for i in alerts.indices { alerts[i].dismissed = true }
        saveAlerts()
    }

    func pruneOlderThan(hours: Int) {
        let cutoff = Date().timeIntervalSince1970 - Double(hours * 3600)
        let before = alerts.count
        alerts.removeAll { $0.timestamp < cutoff }
        if alerts.count < before {
            saveAlerts()
            TorboLog.info("Pruned \(before - alerts.count) alert(s) older than \(hours)h", subsystem: "Ambient")
        }
    }

    var count: Int { alerts.count }
    var activeCount: Int { alerts.filter { !$0.dismissed }.count }

    private func loadAlerts() {
        let path = alertsFilePath
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else { return }
        do { alerts = try JSONDecoder().decode([AmbientAlert].self, from: data) }
        catch { TorboLog.error("Failed to load ambient alerts: \(error)", subsystem: "Ambient") }
    }

    private func saveAlerts() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(alerts)
            try data.write(to: URL(fileURLWithPath: alertsFilePath), options: .atomic)
        } catch {
            TorboLog.error("Failed to save ambient alerts: \(error)", subsystem: "Ambient")
        }
    }
}
