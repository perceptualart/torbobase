// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Tier Enforcement
// Checks user plan tier before routing any request.
// Enforces message limits, feature gates, and access levels.
//
// Tiers:
//   free_base — Self-hosted. No limits, full access. Not used in cloud.
//   torbo     — $5/month. All agents, voices, tools, HomeKit. Standard limits.
//   torbo_max — $10/month. Everything + admin panel + priority + advanced tools.

import Foundation

// MARK: - Tier Check Result

enum TierCheckResult: Sendable {
    case allowed
    case denied(reason: String, upgradeRequired: PlanTier)
    case rateLimited(reason: String, retryAfterSeconds: Int)
}

// MARK: - Tier Enforcer

enum TierEnforcer {

    // MARK: - Pre-Request Check

    /// Check if a request is allowed for the given user context.
    /// Call this BEFORE routing any authenticated request.
    static func check(
        ctx: CloudRequestContext,
        path: String,
        agentID: String,
        accessLevel: Int
    ) -> TierCheckResult {
        let tier = ctx.tier

        // free_base is self-hosted — no cloud enforcement applies
        if tier == .freeBase { return .allowed }

        // 1. Check access level cap
        if accessLevel > tier.maxAccessLevel {
            return .denied(
                reason: "Your \(tier.displayName) plan supports access level \(tier.maxAccessLevel) max. Upgrade to Torbo Max for full access.",
                upgradeRequired: .torboMax
            )
        }

        // 2. Advanced tools — only Torbo Max
        if !tier.hasAdvancedTools {
            let advancedPaths = ["/v1/code/execute", "/v1/docker/", "/v1/browser/",
                                 "/exec/shell"]
            for advPath in advancedPaths {
                if path.hasPrefix(advPath) {
                    return .denied(
                        reason: "Advanced tools (code sandbox, Docker, browser automation) require Torbo Max.",
                        upgradeRequired: .torboMax
                    )
                }
            }
        }

        // 3. Admin panel endpoints — only Torbo Max
        //    Dashboard config, security audit, system prompt, token budgets, kill switches
        if !tier.hasAdminPanel {
            let adminPaths = ["/v1/dashboard", "/v1/config", "/v1/audit",
                              "/v1/security", "/control/level"]
            for adminPath in adminPaths {
                if path.hasPrefix(adminPath) {
                    return .denied(
                        reason: "The admin panel requires Torbo Max. Self-hosted users get admin access for free.",
                        upgradeRequired: .torboMax
                    )
                }
            }
        }

        return .allowed
    }

    // MARK: - Message Rate Check

    /// Check if a user can send a message (daily limit).
    /// Call this BEFORE processing a chat completion request.
    static func checkMessageLimit(ctx: CloudRequestContext) async -> TierCheckResult {
        // Self-hosted has no limits
        if ctx.tier == .freeBase { return .allowed }

        let (allowed, remaining) = await SupabaseAuth.shared.trackMessage(userID: ctx.userID)

        if !allowed {
            let limit = ctx.tier.dailyMessageLimit
            return .rateLimited(
                reason: "Daily message limit reached (\(limit) messages). Upgrade to Torbo Max for higher limits, or wait until midnight UTC.",
                retryAfterSeconds: secondsUntilMidnightUTC()
            )
        }

        if remaining <= 10 && ctx.tier == .torbo {
            TorboLog.info("User \(ctx.userID) approaching daily limit: \(remaining) remaining", subsystem: "TierEnforcer")
        }

        return .allowed
    }

    // MARK: - Voice Check

    /// Check if a user can use the requested voice
    static func checkVoice(ctx: CloudRequestContext, voiceID: String?) -> TierCheckResult {
        // All tiers get all voices (Piper on-device + ElevenLabs when online)
        return .allowed
    }

    // MARK: - Admin Panel Check

    /// Check if a user has admin panel access.
    /// Used by iOS app to decide whether to render the admin/settings tab.
    /// Returns true for:
    ///   - torbo_max subscribers
    ///   - Any user connected to a local (self-hosted) Base instance
    static func hasAdminAccess(tier: PlanTier, isLocalBase: Bool) -> Bool {
        if isLocalBase { return true }      // Self-hosted always gets admin
        return tier.hasAdminPanel           // Cloud: only torbo_max
    }

    // MARK: - Build Tier Error Response

    /// Format a tier denial as an HTTP-style JSON response body
    static func errorResponse(_ result: TierCheckResult) -> [String: Any] {
        switch result {
        case .allowed:
            return [:]
        case .denied(let reason, let upgrade):
            return [
                "error": "tier_limit",
                "message": reason,
                "upgrade_to": upgrade.rawValue,
                "upgrade_name": upgrade.displayName,
                "upgrade_price": "$\(String(format: "%.0f", upgrade.monthlyPrice))/month",
                "trial_days": upgrade.trialDays,
            ]
        case .rateLimited(let reason, let retryAfter):
            return [
                "error": "rate_limited",
                "message": reason,
                "retry_after_seconds": retryAfter,
                "upgrade_to": PlanTier.torboMax.rawValue,
                "upgrade_name": PlanTier.torboMax.displayName,
            ]
        }
    }

    // MARK: - Helpers

    private static func secondsUntilMidnightUTC() -> Int {
        let cal = Calendar(identifier: .gregorian)
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? utcCal.timeZone
        let now = Date()
        guard let tomorrow = utcCal.date(byAdding: .day, value: 1, to: utcCal.startOfDay(for: now)) else {
            return 3600  // fallback: 1 hour
        }
        return max(1, Int(tomorrow.timeIntervalSince(now)))
    }
}
