// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient Intelligence Monitor
// Combines event monitoring (email, calendar, stocks, news) with HomeKit
// ambient intelligence (lights, locks, HVAC, offline devices).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MonitorAlert: Codable {
    let id: String
    let type: AlertType
    let priority: AlertPriority
    let message: String
    let timestamp: Date
    let agent: String
    enum AlertType: String, Codable { case email, calendar, stock, news }
    enum AlertPriority: Int, Codable, Comparable {
        case low = 0, normal = 1, high = 2, critical = 3
        static func < (lhs: AlertPriority, rhs: AlertPriority) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    func toDict() -> [String: Any] {
        let df = ISO8601DateFormatter()
        return ["id": id, "type": type.rawValue, "priority": priority.rawValue, "message": message, "timestamp": df.string(from: timestamp), "agent": agent]
    }
}

struct MonitorConfig: Codable {
    var emailEnabled: Bool; var emailIntervalMinutes: Int; var emailVIPContacts: [String]
    var emailUrgentKeywords: [String]; var emailStaleReplyHours: Int
    var calendarEnabled: Bool; var calendarIntervalMinutes: Int; var calendarAlertMinutesBefore: Int
    var stockEnabled: Bool; var stockIntervalMinutes: Int; var stockTickers: [String]
    var stockThresholdPercent: Double; var stockMarketOpenHour: Int; var stockMarketCloseHour: Int
    var newsEnabled: Bool; var newsIntervalMinutes: Int; var newsKeywords: [String]
    static let `default` = MonitorConfig(
        emailEnabled: true, emailIntervalMinutes: 5, emailVIPContacts: [],
        emailUrgentKeywords: ["urgent", "asap", "emergency", "critical", "deadline", "immediate"],
        emailStaleReplyHours: 24, calendarEnabled: true, calendarIntervalMinutes: 10,
        calendarAlertMinutesBefore: 30, stockEnabled: false, stockIntervalMinutes: 15,
        stockTickers: [], stockThresholdPercent: 3.0, stockMarketOpenHour: 9,
        stockMarketCloseHour: 16, newsEnabled: false, newsIntervalMinutes: 30, newsKeywords: [])
    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        d["email"] = ["enabled": emailEnabled, "interval_minutes": emailIntervalMinutes, "vip_contacts": emailVIPContacts, "urgent_keywords": emailUrgentKeywords, "stale_reply_hours": emailStaleReplyHours] as [String: Any]
        d["calendar"] = ["enabled": calendarEnabled, "interval_minutes": calendarIntervalMinutes, "alert_minutes_before": calendarAlertMinutesBefore] as [String: Any]
        d["stock"] = ["enabled": stockEnabled, "interval_minutes": stockIntervalMinutes, "tickers": stockTickers, "threshold_percent": stockThresholdPercent, "market_open_hour": stockMarketOpenHour, "market_close_hour": stockMarketCloseHour] as [String: Any]
        d["news"] = ["enabled": newsEnabled, "interval_minutes": newsIntervalMinutes, "keywords": newsKeywords] as [String: Any]
        return d
    }
}

actor AmbientMonitor {
    static let shared = AmbientMonitor()

    // HomeKit ambient polling
    private let pollInterval: TimeInterval = 300
    private var config = AmbientConfig.default
    private var pollTask: Task<Void, Never>?
    private let agentID = "CC-AMBIENT-1"

    // Event monitoring (email, calendar, stocks, news)
    private var monitorConfig = MonitorConfig.default
    private var alerts: [MonitorAlert] = []
    private var alertedEmailIDs: Set<String> = []
    private var alertedEventIDs: Set<String> = []
    private var lastStockPrices: [String: Double] = [:]
    private var alertsFilePath: String { PlatformPaths.dataDir + "/ambient_alerts.json" }
    private var configFilePath: String { PlatformPaths.dataDir + "/ambient_config.json" }

    private var isRunning = false

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // Start event monitors (email, calendar, stocks, news)
        loadMonitorConfig(); loadAlerts()
        if monitorConfig.emailEnabled { Task { await emailLoop() }; TorboLog.info("Email monitor: every \(monitorConfig.emailIntervalMinutes)m", subsystem: "Ambient") }
        if monitorConfig.calendarEnabled { Task { await calendarLoop() }; TorboLog.info("Calendar monitor: every \(monitorConfig.calendarIntervalMinutes)m", subsystem: "Ambient") }
        if monitorConfig.stockEnabled && !monitorConfig.stockTickers.isEmpty { Task { await stockLoop() }; TorboLog.info("Stock monitor active", subsystem: "Ambient") }
        if monitorConfig.newsEnabled && !monitorConfig.newsKeywords.isEmpty { Task { await newsLoop() }; TorboLog.info("News monitor active", subsystem: "Ambient") }

        // Start HomeKit ambient polling
        await AmbientAlertManager.shared.initialize()
        pollTask = Task { [weak self] in
            while let self = self, await self.isRunning {
                await self.runMonitorCycle()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
        TorboLog.info("Ambient monitor started (polling every \(Int(pollInterval))s)", subsystem: "Ambient")
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        TorboLog.info("Ambient monitor stopped", subsystem: "Ambient")
    }

    // MARK: - HomeKit Ambient Config

    func updateConfig(_ newConfig: AmbientConfig) {
        config = newConfig
    }

    func getConfig() -> AmbientConfig { config }

    // MARK: - Event Monitor Config & Alerts

    func getMonitorAlerts() -> [[String: Any]] { alerts.map { $0.toDict() } }
    func dismissMonitorAlert(id: String) -> Bool {
        if let idx = alerts.firstIndex(where: { $0.id == id }) { alerts.remove(at: idx); persistAlerts(); return true }; return false
    }
    func getMonitorConfig() -> [String: Any] { monitorConfig.toDict() }
    func updateMonitorConfig(from body: [String: Any]) {
        if let e = body["email"] as? [String: Any] {
            if let v = e["enabled"] as? Bool { monitorConfig.emailEnabled = v }
            if let v = e["interval_minutes"] as? Int { monitorConfig.emailIntervalMinutes = max(1, v) }
            if let v = e["vip_contacts"] as? [String] { monitorConfig.emailVIPContacts = v }
            if let v = e["urgent_keywords"] as? [String] { monitorConfig.emailUrgentKeywords = v }
            if let v = e["stale_reply_hours"] as? Int { monitorConfig.emailStaleReplyHours = max(1, v) }
        }
        if let c = body["calendar"] as? [String: Any] {
            if let v = c["enabled"] as? Bool { monitorConfig.calendarEnabled = v }
            if let v = c["interval_minutes"] as? Int { monitorConfig.calendarIntervalMinutes = max(1, v) }
            if let v = c["alert_minutes_before"] as? Int { monitorConfig.calendarAlertMinutesBefore = max(1, v) }
        }
        if let s = body["stock"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { monitorConfig.stockEnabled = v }
            if let v = s["interval_minutes"] as? Int { monitorConfig.stockIntervalMinutes = max(1, v) }
            if let v = s["tickers"] as? [String] { monitorConfig.stockTickers = v.map { $0.uppercased() } }
            if let v = s["threshold_percent"] as? Double { monitorConfig.stockThresholdPercent = max(0.1, v) }
            if let v = s["market_open_hour"] as? Int { monitorConfig.stockMarketOpenHour = max(0, min(23, v)) }
            if let v = s["market_close_hour"] as? Int { monitorConfig.stockMarketCloseHour = max(0, min(23, v)) }
        }
        if let n = body["news"] as? [String: Any] {
            if let v = n["enabled"] as? Bool { monitorConfig.newsEnabled = v }
            if let v = n["interval_minutes"] as? Int { monitorConfig.newsIntervalMinutes = max(1, v) }
            if let v = n["keywords"] as? [String] { monitorConfig.newsKeywords = v }
        }
        persistMonitorConfig(); TorboLog.info("Monitor config updated", subsystem: "Ambient")
    }
    func stats() -> [String: Any] {
        let byType: [String: Any] = ["email": alerts.filter { $0.type == .email }.count, "calendar": alerts.filter { $0.type == .calendar }.count, "stock": alerts.filter { $0.type == .stock }.count, "news": alerts.filter { $0.type == .news }.count]
        return ["running": isRunning, "alert_count": alerts.count, "alerts_by_type": byType, "config": monitorConfig.toDict()]
    }

    // MARK: - HomeKit Monitor Cycle

    private func runMonitorCycle() async {
        guard let state = await HomeKitSOCReceiver.shared.latestState else { return }
        await checkLightsLeftOn(state: state)
        await checkLockState(state: state)
        await checkHVACAnomaly(state: state)
        await checkDeviceOffline(state: state)
        await AmbientAlertManager.shared.pruneOlderThan(hours: 72)
    }

    private func checkLightsLeftOn(state: HomeKitStateUpdate) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lightsOutHour || hour < 5 else { return }
        let hasGoodNight = state.activeScenes.contains { $0.localizedCaseInsensitiveContains("good night") }
        guard !hasGoodNight else { return }
        let lightsOn = state.devices.filter { $0.type == .light && $0.isOn == true && $0.reachable }
        for light in lightsOn {
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "LIGHTS_LEFT_ON", deviceID: light.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "LIGHTS_LEFT_ON", priority: 2,
                message: "\(light.name) is still on after \(config.lightsOutHour):00",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkLockState(state: HomeKitStateUpdate) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lockCheckHour && hour < 6 else { return }
        let unlockedLocks = state.devices.filter { $0.type == .lock && $0.isLocked == false && $0.reachable }
        for lock in unlockedLocks {
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "LOCK_UNLOCKED", deviceID: lock.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "LOCK_UNLOCKED", priority: 1,
                message: "\(lock.name) is unlocked after midnight",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkHVACAnomaly(state: HomeKitStateUpdate) async {
        let thermostats = state.devices.filter { $0.type == .thermostat && $0.reachable }
        for device in thermostats {
            guard let temp = device.currentTemp else { continue }
            let outOfRange = temp < config.tempLowF || temp > config.tempHighF
            guard outOfRange else { continue }
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "HVAC_ANOMALY", deviceID: device.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let direction = temp < config.tempLowF ? "below \(Int(config.tempLowF))°F" : "above \(Int(config.tempHighF))°F"
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "HVAC_ANOMALY", priority: 2,
                message: "\(device.name) reads \(Int(temp))°F — \(direction)",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkDeviceOffline(state: HomeKitStateUpdate) async {
        let thresholdSeconds = Double(config.offlineThresholdMinutes * 60)
        for device in state.devices where !device.reachable {
            guard let duration = await HomeKitSOCReceiver.shared.offlineDuration(deviceID: device.id),
                  duration >= thresholdSeconds else { continue }
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "DEVICE_OFFLINE", deviceID: device.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let mins = Int(duration / 60)
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "DEVICE_OFFLINE", priority: 3,
                message: "\(device.name) has been offline for \(mins) minutes",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    // MARK: - Event Monitor Internals

    private func addAlert(type: MonitorAlert.AlertType, priority: MonitorAlert.AlertPriority, message: String, agent: String = "ambient") {
        alerts.append(MonitorAlert(id: UUID().uuidString, type: type, priority: priority, message: message, timestamp: Date(), agent: agent))
        persistAlerts(); TorboLog.info("[\(type.rawValue)] \(priority) — \(message.prefix(80))", subsystem: "Ambient")
    }
    private func persistAlerts() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        do { let d = try enc.encode(alerts); try FileManager.default.createDirectory(atPath: (alertsFilePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try d.write(to: URL(fileURLWithPath: alertsFilePath)) }
        catch { TorboLog.error("Failed to persist alerts: \(error)", subsystem: "Ambient") }
    }
    private func loadAlerts() {
        guard let d = FileManager.default.contents(atPath: alertsFilePath) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do { alerts = try dec.decode([MonitorAlert].self, from: d); TorboLog.info("Loaded \(alerts.count) alert(s)", subsystem: "Ambient") }
        catch { TorboLog.warn("Failed to load alerts: \(error)", subsystem: "Ambient") }
    }
    private func persistMonitorConfig() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        do { let d = try enc.encode(monitorConfig); try FileManager.default.createDirectory(atPath: (configFilePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try d.write(to: URL(fileURLWithPath: configFilePath)) }
        catch { TorboLog.error("Failed to persist config: \(error)", subsystem: "Ambient") }
    }
    private func loadMonitorConfig() {
        guard let d = FileManager.default.contents(atPath: configFilePath) else { return }
        do { monitorConfig = try JSONDecoder().decode(MonitorConfig.self, from: d) } catch { TorboLog.warn("Config load failed: \(error)", subsystem: "Ambient") }
    }

    // MARK: - Email Monitor

    private func emailLoop() async { while isRunning && monitorConfig.emailEnabled { await checkEmail(); try? await Task.sleep(nanoseconds: UInt64(monitorConfig.emailIntervalMinutes) * 60_000_000_000) } }
    private func checkEmail() async {
        #if os(macOS)
        let raw = await EmailManager.shared.checkEmail(limit: 20)
        for line in raw.split(separator: "\n").map(String.init) {
            guard line.contains("ID:") && line.contains("FROM:") && line.contains("SUBJECT:") else { continue }
            let parts = parseEmailLine(line); guard let eid = parts["ID"], !alertedEmailIDs.contains(eid) else { continue }
            let from = parts["FROM"] ?? ""; let subj = parts["SUBJECT"] ?? ""; let combo = (from + " " + subj).lowercased()
            if monitorConfig.emailVIPContacts.contains(where: { from.lowercased().contains($0.lowercased()) }) { alertedEmailIDs.insert(eid); addAlert(type: .email, priority: .high, message: "VIP email from \(from): \(subj)") }
            else if monitorConfig.emailUrgentKeywords.contains(where: { combo.contains($0.lowercased()) }) { alertedEmailIDs.insert(eid); addAlert(type: .email, priority: .high, message: "Urgent email from \(from): \(subj)") }
        }
        if alertedEmailIDs.count > 500 { alertedEmailIDs = Set(alertedEmailIDs.suffix(250)) }
        #endif
    }
    private func parseEmailLine(_ line: String) -> [String: String] {
        var r: [String: String] = [:]
        for seg in line.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let ci = seg.firstIndex(of: ":") { r[String(seg[seg.startIndex..<ci]).trimmingCharacters(in: .whitespaces)] = String(seg[seg.index(after: ci)...]).trimmingCharacters(in: .whitespaces) }
        }; return r
    }

    // MARK: - Calendar Monitor

    private func calendarLoop() async { while isRunning && monitorConfig.calendarEnabled { await checkCalendar(); try? await Task.sleep(nanoseconds: UInt64(monitorConfig.calendarIntervalMinutes) * 60_000_000_000) } }
    private func checkCalendar() async {
        let now = Date()
        for event in await CalendarManager.shared.listEvents(from: now, to: now.addingTimeInterval(Double(monitorConfig.calendarAlertMinutesBefore) * 60)) {
            guard !alertedEventIDs.contains(event.id) else { continue }
            let mins = Int(event.startDate.timeIntervalSince(now) / 60); guard mins >= 0 else { continue }
            alertedEventIDs.insert(event.id)
            var msg = "\(event.title) starts in \(mins) minute(s)"; if let l = event.location, !l.isEmpty { msg += " at \(l)" }
            addAlert(type: .calendar, priority: mins <= 10 ? .high : .normal, message: msg)
        }
        if alertedEventIDs.count > 200 { alertedEventIDs = Set(alertedEventIDs.suffix(100)) }
    }

    // MARK: - Stock Monitor

    private func stockLoop() async {
        while isRunning && monitorConfig.stockEnabled {
            let h = Calendar.current.component(.hour, from: Date()); let w = Calendar.current.component(.weekday, from: Date())
            if h >= monitorConfig.stockMarketOpenHour && h < monitorConfig.stockMarketCloseHour && w >= 2 && w <= 6 { await checkStocks() }
            try? await Task.sleep(nanoseconds: UInt64(monitorConfig.stockIntervalMinutes) * 60_000_000_000)
        }
    }
    private func checkStocks() async {
        for t in monitorConfig.stockTickers {
            guard let p = await fetchStockPrice(t) else { continue }
            if let last = lastStockPrices[t] {
                let pct = ((p - last) / last) * 100.0
                if abs(pct) >= monitorConfig.stockThresholdPercent { addAlert(type: .stock, priority: abs(pct) >= monitorConfig.stockThresholdPercent * 2 ? .high : .normal, message: "\(t) \(pct > 0 ? "UP" : "DOWN") \(String(format: "%.1f", abs(pct)))% — $\(String(format: "%.2f", p)) (was $\(String(format: "%.2f", last)))") }
            }
            lastStockPrices[t] = p
        }
    }
    private func fetchStockPrice(_ ticker: String) async -> Double? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker)?range=1d&interval=1m") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do { let (data, resp) = try await URLSession.shared.data(for: req); guard let hr = resp as? HTTPURLResponse, hr.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["chart"] as? [String: Any], let r = c["result"] as? [[String: Any]], let m = r.first?["meta"] as? [String: Any], let p = m["regularMarketPrice"] as? Double else { return nil }; return p }
        catch { return nil }
    }

    // MARK: - News Monitor

    private func newsLoop() async { while isRunning && monitorConfig.newsEnabled { await checkNews(); try? await Task.sleep(nanoseconds: UInt64(monitorConfig.newsIntervalMinutes) * 60_000_000_000) } }
    private func checkNews() async {
        for kw in monitorConfig.newsKeywords {
            guard let hl = await fetchNewsHeadlines(kw) else { continue }
            for h in hl.prefix(3) { addAlert(type: .news, priority: .low, message: "[\(kw)] \(String(h.prefix(200)))") }
        }
    }
    private func fetchNewsHeadlines(_ keyword: String) async -> [String]? {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "https://html.duckduckgo.com/html/?q=\(enc)+news") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do { let (data, resp) = try await URLSession.shared.data(for: req); guard let hr = resp as? HTTPURLResponse, hr.statusCode == 200, let html = String(data: data, encoding: .utf8) else { return nil }
            var results: [String] = []
            for comp in html.components(separatedBy: "result__snippet").dropFirst().prefix(5) {
                guard let si = comp.firstIndex(of: ">") else { continue }; let after = comp.index(after: si); guard after < comp.endIndex else { continue }
                let rest = String(comp[after...]); guard let ei = rest.firstIndex(of: "<") else { continue }
                let cleaned = String(rest[rest.startIndex..<ei]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count > 20 { results.append(cleaned) }
            }; return results.isEmpty ? nil : results
        } catch { return nil }
    }
}
