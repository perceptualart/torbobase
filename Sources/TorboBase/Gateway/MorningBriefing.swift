// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Morning Briefing Engine
// Assembles daily briefings from weather, calendar, email, stocks, news, and ambient alerts.
// Sends to configured agent for writing, delivers via SOC sync, stores as JSON.

import Foundation

// MARK: - Briefing Configuration

struct BriefingConfig: Codable {
    var enabled: Bool = true
    var timeHour: Int = 7
    var timeMinute: Int = 0
    var agentID: String = "sid"
    var maxWords: Int = 200
    var sections: BriefingSections = BriefingSections()
    var location: BriefingLocation? = nil
    var watchedTickers: [String] = ["AAPL", "GOOGL", "MSFT", "TSLA"]
    var newsKeywords: [String] = ["AI", "technology", "space"]
    var stockThreshold: Double = 2.0
}

struct BriefingSections: Codable {
    var weather: Bool = true
    var calendar: Bool = true
    var email: Bool = true
    var stocks: Bool = true
    var news: Bool = true
    var alerts: Bool = true
}

struct BriefingLocation: Codable {
    var latitude: Double
    var longitude: Double
    var name: String?
}

// MARK: - Briefing Data Models

struct BriefingData {
    var weather: String?
    var calendarEvents: String?
    var importantEmails: String?
    var stockMoves: String?
    var newsHeadlines: String?
    var pendingAlerts: String?
}

struct CompletedBriefing: Codable {
    let date: String
    let briefingText: String
    let sections: [String]
    let deliveredAt: Date
    let agentID: String
}

// MARK: - Morning Briefing Actor

actor MorningBriefing {
    static let shared = MorningBriefing()

    private var config: BriefingConfig = BriefingConfig()
    private var lastBriefingDate: String?
    private var timerTask: Task<Void, Never>?

    // MARK: - Initialization

    func initialize() {
        loadConfig()
        startScheduler()
        TorboLog.info("Morning Briefing initialized", subsystem: "Briefing")
    }

    // MARK: - Configuration

    func getConfig() -> BriefingConfig { config }

    func updateFromJSON(_ json: [String: Any]) {
        if let enabled = json["enabled"] as? Bool { config.enabled = enabled }
        if let hour = json["timeHour"] as? Int { config.timeHour = max(0, min(23, hour)) }
        if let minute = json["timeMinute"] as? Int { config.timeMinute = max(0, min(59, minute)) }
        if let agent = json["agentID"] as? String { config.agentID = agent }
        if let words = json["maxWords"] as? Int { config.maxWords = max(50, min(500, words)) }
        if let threshold = json["stockThreshold"] as? Double { config.stockThreshold = threshold }
        if let tickers = json["watchedTickers"] as? [String] { config.watchedTickers = tickers }
        if let keywords = json["newsKeywords"] as? [String] { config.newsKeywords = keywords }

        if let loc = json["location"] as? [String: Any],
           let lat = loc["latitude"] as? Double,
           let lon = loc["longitude"] as? Double {
            config.location = BriefingLocation(latitude: lat, longitude: lon, name: loc["name"] as? String)
        }

        if let sections = json["sections"] as? [String: Any] {
            if let w = sections["weather"] as? Bool { config.sections.weather = w }
            if let c = sections["calendar"] as? Bool { config.sections.calendar = c }
            if let e = sections["email"] as? Bool { config.sections.email = e }
            if let s = sections["stocks"] as? Bool { config.sections.stocks = s }
            if let n = sections["news"] as? Bool { config.sections.news = n }
            if let a = sections["alerts"] as? Bool { config.sections.alerts = a }
        }

        saveConfig()
        TorboLog.info("Briefing config updated", subsystem: "Briefing")
    }

    // MARK: - Scheduler (60-second check loop)

    private func startScheduler() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await checkAndDeliver()
            }
        }
    }

    private func checkAndDeliver() async {
        guard config.enabled else { return }
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        guard hour == config.timeHour && minute == config.timeMinute else { return }
        let today = Self.todayDateString()
        guard lastBriefingDate != today else { return }
        TorboLog.info("Briefing triggered", subsystem: "Briefing")
        _ = await executeBriefing()
    }

    // MARK: - Execute Full Pipeline

    func executeBriefing() async -> CompletedBriefing? {
        let today = Self.todayDateString()
        guard lastBriefingDate != today else {
            TorboLog.info("Already delivered for \(today)", subsystem: "Briefing")
            return nil
        }

        TorboLog.info("Assembling briefing for \(today)...", subsystem: "Briefing")

        let data = await assembleBriefingData()
        let briefingText = await writeBriefing(data: data)

        var includedSections: [String] = []
        if data.weather != nil { includedSections.append("weather") }
        if data.calendarEvents != nil { includedSections.append("calendar") }
        if data.importantEmails != nil { includedSections.append("email") }
        if data.stockMoves != nil { includedSections.append("stocks") }
        if data.newsHeadlines != nil { includedSections.append("news") }
        if data.pendingAlerts != nil { includedSections.append("alerts") }

        let briefing = CompletedBriefing(
            date: today,
            briefingText: briefingText,
            sections: includedSections,
            deliveredAt: Date(),
            agentID: config.agentID
        )

        storeBriefing(briefing)
        await deliverBriefing(briefing)
        lastBriefingDate = today
        TorboLog.info("Delivered for \(today) (\(briefingText.count) chars)", subsystem: "Briefing")
        return briefing
    }

    // MARK: - Data Assembly

    private func assembleBriefingData() async -> BriefingData {
        var data = BriefingData()
        let cfg = config

        async let w: String? = cfg.sections.weather ? fetchWeather() : nil
        async let c: String? = cfg.sections.calendar ? fetchCalendarEvents() : nil
        async let e: String? = cfg.sections.email ? fetchImportantEmails() : nil
        async let s: String? = cfg.sections.stocks ? fetchStockMoves() : nil
        async let n: String? = cfg.sections.news ? fetchNews() : nil
        async let a: String? = cfg.sections.alerts ? fetchPendingAlerts() : nil

        data.weather = await w
        data.calendarEvents = await c
        data.importantEmails = await e
        data.stockMoves = await s
        data.newsHeadlines = await n
        data.pendingAlerts = await a
        return data
    }

    // MARK: - Data Fetchers

    private func fetchWeather() async -> String? {
        guard let loc = config.location else { return nil }
        let urlStr = "https://api.open-meteo.com/v1/forecast?latitude=\(loc.latitude)&longitude=\(loc.longitude)&current=temperature_2m,weathercode,windspeed_10m&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=1"
        guard let url = URL(string: urlStr) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            var result = ""
            if let current = json["current"] as? [String: Any] {
                let temp = current["temperature_2m"] as? Double ?? 0
                let wind = current["windspeed_10m"] as? Double ?? 0
                let code = current["weathercode"] as? Int ?? 0
                result += "Current: \(Self.weatherCondition(code)), \(Int(temp))C, wind \(Int(wind)) km/h"
            }
            if let daily = json["daily"] as? [String: Any],
               let maxTemps = daily["temperature_2m_max"] as? [Double],
               let minTemps = daily["temperature_2m_min"] as? [Double],
               let precip = daily["precipitation_probability_max"] as? [Int] {
                if let high = maxTemps.first, let low = minTemps.first {
                    result += ". High \(Int(high))C, Low \(Int(low))C"
                }
                if let rain = precip.first, rain > 0 {
                    result += ". \(rain)% chance of rain"
                }
            }
            let locationName = loc.name ?? "your location"
            return result.isEmpty ? nil : "Weather for \(locationName): \(result)"
        } catch {
            TorboLog.warn("Weather fetch failed: \(error)", subsystem: "Briefing")
            return nil
        }
    }

    private func fetchCalendarEvents() async -> String? {
        let events = await CalendarManager.shared.todayEvents()
        guard !events.isEmpty else { return nil }
        let lines = events.prefix(8).map { event -> String in
            var line = "- \(event.title)"
            let df = DateFormatter()
            df.dateFormat = "h:mm a"
            line += " at \(df.string(from: event.startDate))"
            if let loc = event.location, !loc.isEmpty { line += " (\(loc))" }
            return line
        }
        return "Today's calendar (\(events.count) events):\n" + lines.joined(separator: "\n")
    }

    private func fetchImportantEmails() async -> String? {
        #if os(macOS)
        let raw = await EmailManager.shared.checkEmail(limit: 5, mailbox: "INBOX")
        guard !raw.isEmpty, raw != "No emails found" else { return nil }
        return "Recent emails:\n\(raw)"
        #else
        return nil
        #endif
    }

    private func fetchStockMoves() async -> String? {
        guard !config.watchedTickers.isEmpty else { return nil }
        var moves: [String] = []
        for ticker in config.watchedTickers.prefix(10) {
            if let move = await fetchSingleStock(ticker) { moves.append(move) }
        }
        return moves.isEmpty ? nil : "Stock moves:\n" + moves.joined(separator: "\n")
    }

    private func fetchSingleStock(_ ticker: String) async -> String? {
        let safeTicker = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticker
        let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(safeTicker)?range=2d&interval=1d"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["chart"] as? [String: Any],
                  let results = chart["result"] as? [[String: Any]],
                  let result = results.first,
                  let indicators = result["indicators"] as? [String: Any],
                  let quotes = indicators["quote"] as? [[String: Any]],
                  let quote = quotes.first,
                  let closes = quote["close"] as? [Double?] else { return nil }
            let validCloses = closes.compactMap { $0 }
            guard validCloses.count >= 2 else { return nil }
            let prev = validCloses[validCloses.count - 2]
            let current = validCloses[validCloses.count - 1]
            guard prev > 0 else { return nil }
            let change = ((current - prev) / prev) * 100
            guard abs(change) >= config.stockThreshold else { return nil }
            let direction = change > 0 ? "+" : ""
            return "- \(ticker): \(direction)\(String(format: "%.1f", change))% ($\(String(format: "%.2f", current)))"
        } catch { return nil }
    }

    private func fetchNews() async -> String? {
        guard !config.newsKeywords.isEmpty else { return nil }
        let query = config.newsKeywords.joined(separator: "+")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://news.google.com/rss/search?q=\(encoded)&hl=en-US&gl=US&ceid=US:en"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let xml = String(data: data, encoding: .utf8) else { return nil }
            var headlines: [String] = []
            let items = xml.components(separatedBy: "<item>")
            for item in items.dropFirst().prefix(5) {
                if let titleStart = item.range(of: "<title>"),
                   let titleEnd = item.range(of: "</title>") {
                    var title = String(item[titleStart.upperBound..<titleEnd.lowerBound])
                    title = title.replacingOccurrences(of: "<![CDATA[", with: "")
                    title = title.replacingOccurrences(of: "]]>", with: "")
                    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { headlines.append("- \(title)") }
                }
            }
            return headlines.isEmpty ? nil : "Top news:\n" + headlines.joined(separator: "\n")
        } catch {
            TorboLog.warn("News fetch failed: \(error)", subsystem: "Briefing")
            return nil
        }
    }

    private func fetchPendingAlerts() async -> String? {
        let alerts = await AmbientAlertManager.shared.activeAlerts()
        guard !alerts.isEmpty else { return nil }
        let cutoff = Date().timeIntervalSince1970 - 86400
        let relevant = alerts.filter { $0.timestamp >= cutoff }
        guard !relevant.isEmpty else { return nil }
        let lines = relevant.prefix(5).map { "- [\($0.type)] \($0.message)" }
        return "Pending alerts (\(relevant.count)):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Briefing Writer

    private func writeBriefing(data: BriefingData) async -> String {
        var prompt = "Write a natural, conversational morning briefing. Max \(config.maxWords) words. Warm but efficient tone.\n\n"
        if let weather = data.weather { prompt += "WEATHER:\n\(weather)\n\n" }
        if let cal = data.calendarEvents { prompt += "CALENDAR:\n\(cal)\n\n" }
        if let email = data.importantEmails { prompt += "EMAIL:\n\(email)\n\n" }
        if let stocks = data.stockMoves { prompt += "STOCKS:\n\(stocks)\n\n" }
        if let news = data.newsHeadlines { prompt += "NEWS:\n\(news)\n\n" }
        if let alerts = data.pendingAlerts { prompt += "ALERTS:\n\(alerts)\n\n" }
        prompt += "Write a single flowing briefing. No headers or bullet points. Start with a greeting."

        let port = await MainActor.run { AppState.shared.serverPort }
        let urlStr = "http://127.0.0.1:\(port)/v1/chat/completions"
        guard let url = URL(string: urlStr) else {
            return Self.fallbackBriefing(data: data)
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(config.agentID, forHTTPHeaderField: "x-torbo-agent-id")
            let body: [String: Any] = [
                "messages": [["role": "user", "content": prompt]],
                "stream": false
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60
            let (responseData, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.isEmpty {
                return content
            }
        } catch {
            TorboLog.warn("Agent call failed: \(error)", subsystem: "Briefing")
        }
        return Self.fallbackBriefing(data: data)
    }

    // MARK: - Storage

    private func storeBriefing(_ briefing: CompletedBriefing) {
        let dir = PlatformPaths.briefingsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filePath = dir + "/\(briefing.date).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(briefing)
            try data.write(to: URL(fileURLWithPath: filePath))
            TorboLog.info("Stored at \(filePath)", subsystem: "Briefing")
        } catch {
            TorboLog.error("Failed to store briefing: \(error)", subsystem: "Briefing")
        }
    }

    // MARK: - Delivery

    private func deliverBriefing(_ briefing: CompletedBriefing) async {
        let message = ConversationMessage(
            role: "assistant",
            content: "[MORNING_BRIEFING:\(briefing.date)] \(briefing.briefingText)",
            model: "briefing-engine",
            clientIP: nil,
            agentID: briefing.agentID
        )
        await ConversationStore.shared.appendMessage(message)
        TorboLog.info("Delivered via SOC sync", subsystem: "Briefing")
    }

    // MARK: - Query API

    func getBriefing(date: String) async -> CompletedBriefing? {
        let filePath = PlatformPaths.briefingsDir + "/\(date).json"
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompletedBriefing.self, from: data)
    }

    func listBriefings(limit: Int) async -> [String] {
        let dir = PlatformPaths.briefingsDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .map { $0.replacingOccurrences(of: ".json", with: "") }
            .sorted(by: >)
            .prefix(limit)
            .map { $0 }
    }

    func stats() async -> [String: Any] {
        let dir = PlatformPaths.briefingsDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".json") } ?? []
        return [
            "enabled": config.enabled,
            "scheduledTime": String(format: "%02d:%02d", config.timeHour, config.timeMinute),
            "agentID": config.agentID,
            "totalBriefings": files.count,
            "lastDelivered": lastBriefingDate ?? "never",
            "sections": [
                "weather": config.sections.weather,
                "calendar": config.sections.calendar,
                "email": config.sections.email,
                "stocks": config.sections.stocks,
                "news": config.sections.news,
                "alerts": config.sections.alerts
            ]
        ]
    }

    // MARK: - Persistence

    private func loadConfig() {
        let path = PlatformPaths.briefingConfigFile
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        if let loaded = try? JSONDecoder().decode(BriefingConfig.self, from: data) {
            config = loaded
        }
    }

    private func saveConfig() {
        let path = PlatformPaths.briefingConfigFile
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            TorboLog.error("Failed to save briefing config: \(error)", subsystem: "Briefing")
        }
    }

    // MARK: - Helpers

    static func todayDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private static func weatherCondition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2, 3: return "Partly cloudy"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }

    private static func fallbackBriefing(data: BriefingData) -> String {
        var parts: [String] = ["Good morning! Here's your daily briefing:"]
        if let w = data.weather { parts.append(w) }
        if let c = data.calendarEvents { parts.append(c) }
        if let e = data.importantEmails { parts.append(e) }
        if let s = data.stockMoves { parts.append(s) }
        if let n = data.newsHeadlines { parts.append(n) }
        if let a = data.pendingAlerts { parts.append(a) }
        return parts.joined(separator: "\n\n")
    }
}
