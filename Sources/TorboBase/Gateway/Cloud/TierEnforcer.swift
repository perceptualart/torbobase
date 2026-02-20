// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Tier Enforcement
// Checks user plan tier before routing any request.
// Enforces message limits, agent access, feature gates, and access levels.

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

        // 1. Check access level cap
        if accessLevel > tier.maxAccessLevel {
            return .denied(
                reason: "Your \(tier.displayName) plan supports access level \(tier.maxAccessLevel) max. This request requires level \(accessLevel).",
                upgradeRequired: accessLevel <= PlanTier.pro.maxAccessLevel ? .pro : .premium
            )
        }

        // 2. Check agent access
        if !tier.allowedAgents.isEmpty && !tier.allowedAgents.contains(agentID) {
            return .denied(
                reason: "Agent '\(agentID)' requires a Pro or Premium plan. Free tier only includes SiD.",
                upgradeRequired: .pro
            )
        }

        // 3. Check feature gates based on path
        if path.hasPrefix("/v1/audio/speech") && path.contains("elevenlabs") && !tier.hasElevenLabsVoice {
            return .denied(
                reason: "ElevenLabs voices require a Pro or Premium plan.",
                upgradeRequired: .pro
            )
        }

        // Tools access (file ops, exec, etc.)
        if !tier.hasTools {
            let toolPaths = ["/fs/", "/exec", "/v1/code/execute", "/v1/docker/",
                             "/v1/browser/", "/v1/webhooks", "/v1/schedules"]
            for toolPath in toolPaths {
                if path.hasPrefix(toolPath) {
                    return .denied(
                        reason: "Tools (file access, code execution, etc.) require a Pro or Premium plan.",
                        upgradeRequired: .pro
                    )
                }
            }
        }

        // HomeKit (future) — premium only
        if path.hasPrefix("/v1/homekit") && !tier.hasHomeKit {
            return .denied(
                reason: "HomeKit integration requires a Premium plan.",
                upgradeRequired: .premium
            )
        }

        return .allowed
    }

    // MARK: - Message Rate Check

    /// Check if a user can send a message (daily limit).
    /// Call this BEFORE processing a chat completion request.
    static func checkMessageLimit(ctx: CloudRequestContext) async -> TierCheckResult {
        let (allowed, remaining) = await SupabaseAuth.shared.trackMessage(userID: ctx.userID)

        if !allowed {
            let limit = ctx.tier.dailyMessageLimit
            return .rateLimited(
                reason: "Daily message limit reached (\(limit) messages). Resets at midnight UTC.",
                retryAfterSeconds: secondsUntilMidnightUTC()
            )
        }

        if remaining <= 5 && ctx.tier == .free {
            TorboLog.info("User \(ctx.userID) approaching daily limit: \(remaining) remaining", subsystem: "TierEnforcer")
        }

        return .allowed
    }

    // MARK: - Voice Check

    /// Check if a user can use the requested voice
    static func checkVoice(ctx: CloudRequestContext, voiceID: String?) -> TierCheckResult {
        // If no voice ID specified, or using on-device TTS, always allowed
        guard let voiceID = voiceID, !voiceID.isEmpty else { return .allowed }

        // On-device voices are always allowed
        let onDeviceVoices = ["samantha", "daniel", "karen", "moira", "tessa", "alex"]
        if onDeviceVoices.contains(voiceID.lowercased()) { return .allowed }

        // ElevenLabs voices require Pro+
        if !ctx.tier.hasElevenLabsVoice {
            return .denied(
                reason: "ElevenLabs voices require a Pro or Premium plan. On-device voices are available on all plans.",
                upgradeRequired: .pro
            )
        }

        return .allowed
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
                "upgrade_price": "$\(String(format: "%.2f", upgrade.monthlyPrice))/month"
            ]
        case .rateLimited(let reason, let retryAfter):
            return [
                "error": "rate_limited",
                "message": reason,
                "retry_after_seconds": retryAfter
            ]
        }
    }

    // MARK: - Helpers

    private static func secondsUntilMidnightUTC() -> Int {
        let cal = Calendar(identifier: .gregorian)
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        guard let tomorrow = utcCal.date(byAdding: .day, value: 1, to: utcCal.startOfDay(for: now)) else {
            return 3600  // fallback: 1 hour
        }
        return max(1, Int(tomorrow.timeIntervalSince(now)))
    }
}
