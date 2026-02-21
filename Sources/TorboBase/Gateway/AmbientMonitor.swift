// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient Event Monitoring Engine

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AmbientAlert: Codable {
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

struct AmbientConfig: Codable {
    var emailEnabled: Bool; var emailIntervalMinutes: Int; var emailVIPContacts: [String]
    var emailUrgentKeywords: [String]; var emailStaleReplyHours: Int
    var calendarEnabled: Bool; var calendarIntervalMinutes: Int; var calendarAlertMinutesBefore: Int
    var stockEnabled: Bool; var stockIntervalMinutes: Int; var stockTickers: [String]
    var stockThresholdPercent: Double; var stockMarketOpenHour: Int; var stockMarketCloseHour: Int
    var newsEnabled: Bool; var newsIntervalMinutes: Int; var newsKeywords: [String]
    static let `default` = AmbientConfig(
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
    private var config = AmbientConfig.default
    private var alerts: [AmbientAlert] = []
    private var isRunning = false
    private var alertedEmailIDs: Set<String> = []
    private var alertedEventIDs: Set<String> = []
    private var lastStockPrices: [String: Double] = [:]
    private var alertsFilePath: String { PlatformPaths.dataDir + "/ambient_alerts.json" }
    private var configFilePath: String { PlatformPaths.dataDir + "/ambient_config.json" }

    func start() {
        guard !isRunning else { return }
        isRunning = true; loadConfig(); loadAlerts()
        TorboLog.info("Ambient monitor started", subsystem: "Ambient")
        if config.emailEnabled { Task { await emailLoop() }; TorboLog.info("Email monitor: every \(config.emailIntervalMinutes)m", subsystem: "Ambient") }
        if config.calendarEnabled { Task { await calendarLoop() }; TorboLog.info("Calendar monitor: every \(config.calendarIntervalMinutes)m", subsystem: "Ambient") }
        if config.stockEnabled && !config.stockTickers.isEmpty { Task { await stockLoop() }; TorboLog.info("Stock monitor active", subsystem: "Ambient") }
        if config.newsEnabled && !config.newsKeywords.isEmpty { Task { await newsLoop() }; TorboLog.info("News monitor active", subsystem: "Ambient") }
    }
    func stop() { isRunning = false; TorboLog.info("Ambient monitor stopped", subsystem: "Ambient") }
    func getAlerts() -> [[String: Any]] { alerts.map { $0.toDict() } }
    func dismissAlert(id: String) -> Bool {
        if let idx = alerts.firstIndex(where: { $0.id == id }) { alerts.remove(at: idx); persistAlerts(); return true }; return false
    }
    func getConfig() -> [String: Any] { config.toDict() }
    func updateConfig(from body: [String: Any]) {
        if let e = body["email"] as? [String: Any] {
            if let v = e["enabled"] as? Bool { config.emailEnabled = v }
            if let v = e["interval_minutes"] as? Int { config.emailIntervalMinutes = max(1, v) }
            if let v = e["vip_contacts"] as? [String] { config.emailVIPContacts = v }
            if let v = e["urgent_keywords"] as? [String] { config.emailUrgentKeywords = v }
            if let v = e["stale_reply_hours"] as? Int { config.emailStaleReplyHours = max(1, v) }
        }
        if let c = body["calendar"] as? [String: Any] {
            if let v = c["enabled"] as? Bool { config.calendarEnabled = v }
            if let v = c["interval_minutes"] as? Int { config.calendarIntervalMinutes = max(1, v) }
            if let v = c["alert_minutes_before"] as? Int { config.calendarAlertMinutesBefore = max(1, v) }
        }
        if let s = body["stock"] as? [String: Any] {
            if let v = s["enabled"] as? Bool { config.stockEnabled = v }
            if let v = s["interval_minutes"] as? Int { config.stockIntervalMinutes = max(1, v) }
            if let v = s["tickers"] as? [String] { config.stockTickers = v.map { $0.uppercased() } }
            if let v = s["threshold_percent"] as? Double { config.stockThresholdPercent = max(0.1, v) }
            if let v = s["market_open_hour"] as? Int { config.stockMarketOpenHour = max(0, min(23, v)) }
            if let v = s["market_close_hour"] as? Int { config.stockMarketCloseHour = max(0, min(23, v)) }
        }
        if let n = body["news"] as? [String: Any] {
            if let v = n["enabled"] as? Bool { config.newsEnabled = v }
            if let v = n["interval_minutes"] as? Int { config.newsIntervalMinutes = max(1, v) }
            if let v = n["keywords"] as? [String] { config.newsKeywords = v }
        }
        persistConfig(); TorboLog.info("Config updated", subsystem: "Ambient")
    }
    func stats() -> [String: Any] {
        let byType: [String: Any] = ["email": alerts.filter { $0.type == .email }.count, "calendar": alerts.filter { $0.type == .calendar }.count, "stock": alerts.filter { $0.type == .stock }.count, "news": alerts.filter { $0.type == .news }.count]
        return ["running": isRunning, "alert_count": alerts.count, "alerts_by_type": byType, "config": config.toDict()]
    }
    private func addAlert(type: AmbientAlert.AlertType, priority: AmbientAlert.AlertPriority, message: String, agent: String = "ambient") {
        alerts.append(AmbientAlert(id: UUID().uuidString, type: type, priority: priority, message: message, timestamp: Date(), agent: agent))
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
        do { alerts = try dec.decode([AmbientAlert].self, from: d); TorboLog.info("Loaded \(alerts.count) alert(s)", subsystem: "Ambient") }
        catch { TorboLog.warn("Failed to load alerts: \(error)", subsystem: "Ambient") }
    }
    private func persistConfig() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        do { let d = try enc.encode(config); try FileManager.default.createDirectory(atPath: (configFilePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try d.write(to: URL(fileURLWithPath: configFilePath)) }
        catch { TorboLog.error("Failed to persist config: \(error)", subsystem: "Ambient") }
    }
    private func loadConfig() {
        guard let d = FileManager.default.contents(atPath: configFilePath) else { return }
        do { config = try JSONDecoder().decode(AmbientConfig.self, from: d) } catch { TorboLog.warn("Config load failed: \(error)", subsystem: "Ambient") }
    }
    private func emailLoop() async { while isRunning && config.emailEnabled { await checkEmail(); try? await Task.sleep(nanoseconds: UInt64(config.emailIntervalMinutes) * 60_000_000_000) } }
    private func checkEmail() async {
        #if os(macOS)
        let raw = await EmailManager.shared.checkEmail(limit: 20)
        for line in raw.split(separator: "\n").map(String.init) {
            guard line.contains("ID:") && line.contains("FROM:") && line.contains("SUBJECT:") else { continue }
            let parts = parseEmailLine(line); guard let eid = parts["ID"], !alertedEmailIDs.contains(eid) else { continue }
            let from = parts["FROM"] ?? ""; let subj = parts["SUBJECT"] ?? ""; let combo = (from + " " + subj).lowercased()
            if config.emailVIPContacts.contains(where: { from.lowercased().contains($0.lowercased()) }) { alertedEmailIDs.insert(eid); addAlert(type: .email, priority: .high, message: "VIP email from \(from): \(subj)") }
            else if config.emailUrgentKeywords.contains(where: { combo.contains($0.lowercased()) }) { alertedEmailIDs.insert(eid); addAlert(type: .email, priority: .high, message: "Urgent email from \(from): \(subj)") }
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
    private func calendarLoop() async { while isRunning && config.calendarEnabled { await checkCalendar(); try? await Task.sleep(nanoseconds: UInt64(config.calendarIntervalMinutes) * 60_000_000_000) } }
    private func checkCalendar() async {
        let now = Date()
        for event in await CalendarManager.shared.listEvents(from: now, to: now.addingTimeInterval(Double(config.calendarAlertMinutesBefore) * 60)) {
            guard !alertedEventIDs.contains(event.id) else { continue }
            let mins = Int(event.startDate.timeIntervalSince(now) / 60); guard mins >= 0 else { continue }
            alertedEventIDs.insert(event.id)
            var msg = "\(event.title) starts in \(mins) minute(s)"; if let l = event.location, !l.isEmpty { msg += " at \(l)" }
            addAlert(type: .calendar, priority: mins <= 10 ? .high : .normal, message: msg)
        }
        if alertedEventIDs.count > 200 { alertedEventIDs = Set(alertedEventIDs.suffix(100)) }
    }
    private func stockLoop() async {
        while isRunning && config.stockEnabled {
            let h = Calendar.current.component(.hour, from: Date()); let w = Calendar.current.component(.weekday, from: Date())
            if h >= config.stockMarketOpenHour && h < config.stockMarketCloseHour && w >= 2 && w <= 6 { await checkStocks() }
            try? await Task.sleep(nanoseconds: UInt64(config.stockIntervalMinutes) * 60_000_000_000)
        }
    }
    private func checkStocks() async {
        for t in config.stockTickers {
            guard let p = await fetchStockPrice(t) else { continue }
            if let last = lastStockPrices[t] {
                let pct = ((p - last) / last) * 100.0
                if abs(pct) >= config.stockThresholdPercent { addAlert(type: .stock, priority: abs(pct) >= config.stockThresholdPercent * 2 ? .high : .normal, message: "\(t) \(pct > 0 ? "UP" : "DOWN") \(String(format: "%.1f", abs(pct)))% — $\(String(format: "%.2f", p)) (was $\(String(format: "%.2f", last)))") }
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
    private func newsLoop() async { while isRunning && config.newsEnabled { await checkNews(); try? await Task.sleep(nanoseconds: UInt64(config.newsIntervalMinutes) * 60_000_000_000) } }
    private func checkNews() async {
        for kw in config.newsKeywords {
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
