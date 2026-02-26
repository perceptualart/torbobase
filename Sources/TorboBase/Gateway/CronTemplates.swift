// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cron Schedule Templates
// Pre-built schedule templates for common automation patterns.

import Foundation

// MARK: - Cron Schedule Template

struct CronTemplate: Codable, Identifiable {
    let id: String
    let name: String
    let cronExpression: String
    let description: String
    let prompt: String
    let agentID: String
    let category: String

    /// Human-readable schedule description
    var scheduleDescription: String {
        CronParser.describe(cronExpression)
    }
}

// MARK: - Built-in Templates

enum CronTemplates {

    static let all: [CronTemplate] = [
        morningBriefing,
        eveningWindDown,
        hourlyPriceCheck,
        weeklyReport,
        backupReminder,
        newsDigest,
        systemHealthCheck,
        weeklyCleanup,
    ]

    static let morningBriefing = CronTemplate(
        id: "tpl_morning_briefing",
        name: "Morning Briefing",
        cronExpression: "0 8 * * *",
        description: "Start your day with a summary of calendar events, unread emails, weather, and top news.",
        prompt: """
        Good morning! Please prepare my daily briefing:
        1. Check my calendar for today's events and meetings
        2. Summarize any important unread emails
        3. Get the current weather forecast
        4. List the top 3 news headlines
        Present this as a concise morning briefing.
        """,
        agentID: "sid",
        category: "daily"
    )

    static let eveningWindDown = CronTemplate(
        id: "tpl_evening_winddown",
        name: "Evening Wind-Down",
        cronExpression: "0 18 * * *",
        description: "End your workday with a summary of accomplishments and tomorrow's priorities.",
        prompt: """
        Good evening! Please prepare my end-of-day summary:
        1. Summarize what was accomplished today (completed tasks, messages sent)
        2. List any unfinished tasks that should carry over
        3. Preview tomorrow's calendar
        4. Suggest priorities for tomorrow
        Keep it brief and actionable.
        """,
        agentID: "sid",
        category: "daily"
    )

    static let hourlyPriceCheck = CronTemplate(
        id: "tpl_price_check",
        name: "Hourly Price Check",
        cronExpression: "0 * * * *",
        description: "Check stock and cryptocurrency prices every hour during market hours.",
        prompt: """
        Check current prices for major indices and cryptocurrencies:
        - S&P 500, NASDAQ, Dow Jones
        - Bitcoin, Ethereum
        Report any significant moves (>1% change). Keep it to one paragraph.
        """,
        agentID: "sid",
        category: "monitoring"
    )

    static let weeklyReport = CronTemplate(
        id: "tpl_weekly_report",
        name: "Weekly Report",
        cronExpression: "0 9 * * 1",
        description: "Generate a weekly summary every Monday at 9 AM.",
        prompt: """
        Generate my weekly report:
        1. Summary of tasks completed this past week
        2. Key metrics or milestones reached
        3. Blockers or issues encountered
        4. Goals and priorities for this week
        Format as a clean markdown report.
        """,
        agentID: "sid",
        category: "reporting"
    )

    static let backupReminder = CronTemplate(
        id: "tpl_backup_reminder",
        name: "Backup Reminder",
        cronExpression: "0 20 * * *",
        description: "Daily reminder at 8 PM to back up important files.",
        prompt: """
        Reminder: Time for your daily backup check.
        - Verify that automated backups ran successfully
        - Check disk space on backup drives
        - Flag any files modified today that aren't covered by backup rules
        Provide a brief status report.
        """,
        agentID: "sid",
        category: "maintenance"
    )

    static let newsDigest = CronTemplate(
        id: "tpl_news_digest",
        name: "News Digest",
        cronExpression: "0 12 * * *",
        description: "Midday news digest covering tech, science, and business.",
        prompt: """
        Compile a midday news digest:
        1. Top 5 technology headlines
        2. Top 3 science/research developments
        3. Key business/market news
        Keep each item to 1-2 sentences. Focus on what's actually new and significant.
        """,
        agentID: "sid",
        category: "information"
    )

    static let systemHealthCheck = CronTemplate(
        id: "tpl_health_check",
        name: "System Health Check",
        cronExpression: "*/30 * * * *",
        description: "Check system health every 30 minutes: disk space, memory, running services.",
        prompt: """
        Run a quick system health check:
        1. Check disk space usage (warn if >80%)
        2. Check memory usage
        3. Verify key services are running
        4. Check for any error logs in the last 30 minutes
        Report only issues or anomalies. Say "All clear" if everything is normal.
        """,
        agentID: "sid",
        category: "monitoring"
    )

    static let weeklyCleanup = CronTemplate(
        id: "tpl_weekly_cleanup",
        name: "Weekly Cleanup",
        cronExpression: "0 3 * * 0",
        description: "Sunday 3 AM maintenance: clean temp files, optimize databases, rotate logs.",
        prompt: """
        Perform weekly maintenance:
        1. Clean temporary files older than 7 days
        2. Check for and remove orphaned data
        3. Report storage space before and after cleanup
        4. Flag any maintenance items that need manual attention
        Run quietly and report results.
        """,
        agentID: "sid",
        category: "maintenance"
    )

    // MARK: - Lookup

    static func template(byID id: String) -> CronTemplate? {
        all.first { $0.id == id }
    }

    static func templates(forCategory category: String) -> [CronTemplate] {
        all.filter { $0.category == category }
    }

    static var categories: [String] {
        Array(Set(all.map(\.category))).sorted()
    }
}
