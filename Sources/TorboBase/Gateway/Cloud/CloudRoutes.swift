// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Authentication & Billing API Routes
// These route handlers are called from GatewayServer.route() for /v1/auth/* and /v1/billing/* paths.
// Kept in a separate file to minimize changes to GatewayServer.swift.

import Foundation

// MARK: - Cloud Route Handlers

/// Static route handlers for cloud authentication and billing endpoints.
/// These are called from GatewayServer.route() and return HTTPResponse directly.
enum CloudRoutes {

    // ────────────────────────────────────────────────
    // MARK: - Auth Routes (no auth required)
    // ────────────────────────────────────────────────

    /// POST /v1/auth/magic-link
    /// Body: { "email": "user@example.com" }
    /// Sends a magic link email via Supabase.
    static func handleMagicLink(_ req: HTTPRequest) async -> HTTPResponse {
        guard await SupabaseAuth.shared.isEnabled else {
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Cloud auth not configured\"}".utf8))
        }

        guard let body = req.jsonBody,
              let email = body["email"] as? String,
              !email.isEmpty else {
            return HTTPResponse.badRequest("Missing 'email' field")
        }

        // Basic email validation
        guard email.contains("@"), email.contains(".") else {
            return HTTPResponse.badRequest("Invalid email address")
        }

        // M-7: Always return success to prevent email enumeration
        // Log the actual result server-side but return uniform response to client
        let (success, error) = await SupabaseAuth.shared.sendMagicLink(email: email)
        if !success {
            TorboLog.warn("Magic link failed for request (not revealed to client): \(error ?? "unknown")", subsystem: "CloudAuth")
        }
        return HTTPResponse.json([
            "status": "sent",
            "message": "If an account exists for that email, a magic link has been sent."
        ])
    }

    /// POST /v1/auth/verify
    /// Body: { "token": "...", "type": "magiclink" }
    /// Exchanges a magic link token for a JWT session.
    static func handleVerify(_ req: HTTPRequest) async -> HTTPResponse {
        guard await SupabaseAuth.shared.isEnabled else {
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Cloud auth not configured\"}".utf8))
        }

        guard let body = req.jsonBody,
              let token = body["token"] as? String,
              !token.isEmpty else {
            return HTTPResponse.badRequest("Missing 'token' field")
        }

        let type = body["type"] as? String ?? "magiclink"

        let (accessToken, refreshToken, user, error) = await SupabaseAuth.shared.verifyToken(token: token, type: type)

        guard let accessToken = accessToken else {
            return HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(error ?? "Verification failed")\"}".utf8))
        }

        var response: [String: Any] = [
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": 3600,  // Supabase default: 1 hour, then refresh
        ]
        if let refreshToken = refreshToken {
            response["refresh_token"] = refreshToken
        }
        if let user = user {
            response["user"] = [
                "id": user.id,
                "email": user.email,
                "plan_tier": user.planTier.rawValue,
                "subscription_status": user.subscriptionStatus ?? "none",
            ] as [String: Any]
        }

        return HTTPResponse.json(response)
    }

    /// POST /v1/auth/refresh
    /// Body: { "refresh_token": "..." }
    /// Refreshes an expired access token.
    static func handleRefresh(_ req: HTTPRequest) async -> HTTPResponse {
        guard await SupabaseAuth.shared.isEnabled else {
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Cloud auth not configured\"}".utf8))
        }

        guard let body = req.jsonBody,
              let refreshToken = body["refresh_token"] as? String,
              !refreshToken.isEmpty else {
            return HTTPResponse.badRequest("Missing 'refresh_token' field")
        }

        let (accessToken, newRefreshToken, error) = await SupabaseAuth.shared.refreshSession(refreshToken: refreshToken)

        guard let accessToken = accessToken else {
            return HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(error ?? "Refresh failed")\"}".utf8))
        }

        var response: [String: Any] = [
            "access_token": accessToken,
            "token_type": "Bearer",
            "expires_in": 3600,
        ]
        if let newRefreshToken = newRefreshToken {
            response["refresh_token"] = newRefreshToken
        }

        return HTTPResponse.json(response)
    }

    // ────────────────────────────────────────────────
    // MARK: - User Profile (requires cloud auth)
    // ────────────────────────────────────────────────

    /// GET /v1/auth/me
    /// Returns the authenticated user's profile, tier, and usage stats.
    static func handleMe(_ ctx: CloudRequestContext) async -> HTTPResponse {
        var user = await SupabaseAuth.shared.cachedUser(ctx.userID)
        if user == nil {
            user = await SupabaseAuth.shared.fetchUserRecord(userID: ctx.userID)
        }

        var profile: [String: Any] = [
            "id": ctx.userID,
            "email": ctx.email,
            "plan_tier": ctx.tier.rawValue,
            "plan_name": ctx.tier.displayName,
            "subscription_status": ctx.subscriptionStatus ?? "none",
        ]

        if let user = user {
            let today = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: Date())
            }()

            let messagesUsed = user.lastMessageDate == today ? user.dailyMessageCount : 0
            let limit = ctx.tier.dailyMessageLimit

            profile["usage"] = [
                "daily_messages_used": messagesUsed,
                "daily_messages_limit": limit == Int.max ? -1 : limit,
                "daily_messages_remaining": limit == Int.max ? -1 : max(0, limit - messagesUsed),
            ] as [String: Any]

            profile["created_at"] = user.createdAt
            profile["last_active"] = user.lastActive
        }

        profile["features"] = [
            "agents": "all",  // All tiers get all 4 agents
            "piper_voice": ctx.tier.hasPiperVoice,
            "elevenlabs_voice": ctx.tier.hasElevenLabsVoice,
            "tools": ctx.tier.hasTools,
            "advanced_tools": ctx.tier.hasAdvancedTools,
            "homekit": ctx.tier.hasHomeKit,
            "priority_routing": ctx.tier.hasPriorityRouting,
            "admin_panel": ctx.tier.hasAdminPanel,
            "max_access_level": ctx.tier.maxAccessLevel,
        ] as [String: Any]

        return HTTPResponse.json(profile)
    }

    // ────────────────────────────────────────────────
    // MARK: - Billing Routes (requires cloud auth)
    // ────────────────────────────────────────────────

    /// POST /v1/billing/checkout
    /// Body: { "tier": "torbo" | "torbo_max" }
    /// Creates a Stripe checkout session and returns the URL.
    static func handleCheckout(_ req: HTTPRequest, ctx: CloudRequestContext) async -> HTTPResponse {
        guard await StripeManager.shared.isEnabled else {
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Billing not configured\"}".utf8))
        }

        guard let body = req.jsonBody,
              let tierStr = body["tier"] as? String,
              let tier = PlanTier(rawValue: tierStr) else {
            return HTTPResponse.badRequest("Missing or invalid 'tier' field. Use 'torbo' or 'torbo_max'.")
        }

        guard tier != .freeBase else {
            return HTTPResponse.badRequest("Torbo Base is free and self-hosted — no checkout needed.")
        }

        guard tier != ctx.tier else {
            return HTTPResponse.badRequest("You are already on the \(tier.displayName) plan.")
        }

        // Build success/cancel URLs
        let baseURL = ProcessInfo.processInfo.environment["CLOUD_BASE_URL"] ?? "https://cloud.torbo.app"
        let successURL = "\(baseURL)/billing/success?session_id={CHECKOUT_SESSION_ID}"
        let cancelURL = "\(baseURL)/billing/cancel"

        let (sessionURL, error) = await StripeManager.shared.createCheckoutSession(
            userID: ctx.userID,
            email: ctx.email,
            tier: tier,
            successURL: successURL,
            cancelURL: cancelURL
        )

        guard let sessionURL = sessionURL else {
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(error ?? "Failed to create checkout session")\"}".utf8))
        }

        return HTTPResponse.json([
            "checkout_url": sessionURL,
            "tier": tier.rawValue,
        ])
    }

    /// POST /v1/billing/portal
    /// Creates a Stripe customer portal session for managing subscription.
    static func handlePortal(_ ctx: CloudRequestContext) async -> HTTPResponse {
        guard await StripeManager.shared.isEnabled else {
            return HTTPResponse(statusCode: 503, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Billing not configured\"}".utf8))
        }

        guard let customerID = ctx.stripeCustomerID, !customerID.isEmpty else {
            return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"No active subscription. Use /v1/billing/checkout to subscribe.\"}".utf8))
        }

        let baseURL = ProcessInfo.processInfo.environment["CLOUD_BASE_URL"] ?? "https://cloud.torbo.app"
        let returnURL = "\(baseURL)/dashboard"

        let (sessionURL, error) = await StripeManager.shared.createPortalSession(
            stripeCustomerID: customerID,
            returnURL: returnURL
        )

        guard let sessionURL = sessionURL else {
            return HTTPResponse(statusCode: 500, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(error ?? "Failed to create portal session")\"}".utf8))
        }

        return HTTPResponse.json(["portal_url": sessionURL])
    }

    /// GET /v1/billing/status
    /// Returns the user's current billing status.
    static func handleBillingStatus(_ ctx: CloudRequestContext) async -> HTTPResponse {
        var status: [String: Any] = [
            "plan_tier": ctx.tier.rawValue,
            "plan_name": ctx.tier.displayName,
            "monthly_price": ctx.tier.monthlyPrice,
            "subscription_status": ctx.subscriptionStatus ?? "none",
        ]

        if let subID = (await SupabaseAuth.shared.cachedUser(ctx.userID))?.stripeSubscriptionID,
           !subID.isEmpty {
            status["stripe_subscription_id"] = subID
        }

        status["tiers"] = [
            ["tier": "free_base", "name": "Torbo Base", "price": 0,
             "features": "Self-hosted on Mac. Full access. User provides own API keys. No account needed.",
             "trial_days": 0],
            ["tier": "torbo", "name": "Torbo", "price": 5,
             "features": "Cloud-hosted. All 4 agents, Piper + ElevenLabs voices, tools, HomeKit, Shortcuts.",
             "trial_days": 30],
            ["tier": "torbo_max", "name": "Torbo Max", "price": 10,
             "features": "Everything in Torbo + admin panel (Arkhe), priority routing, higher rate limits, advanced tools.",
             "trial_days": 30],
        ] as [[String: Any]]

        return HTTPResponse.json(status)
    }

    // ────────────────────────────────────────────────
    // MARK: - Stripe Webhook (no auth — signature verified)
    // ────────────────────────────────────────────────

    /// POST /v1/billing/webhook
    /// Stripe sends subscription events here. Verified via webhook signature.
    static func handleStripeWebhook(_ req: HTTPRequest) async -> HTTPResponse {
        guard let signature = req.headers["stripe-signature"] ?? req.headers["Stripe-Signature"] else {
            return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"Missing Stripe-Signature header\"}".utf8))
        }

        let payload = req.body ?? Data()

        let (event, error) = await StripeManager.shared.verifyWebhook(payload: payload, signature: signature)

        guard let event = event else {
            TorboLog.warn("Stripe webhook rejected: \(error ?? "unknown")", subsystem: "Stripe")
            return HTTPResponse(statusCode: 400, headers: ["Content-Type": "application/json"],
                              body: Data("{\"error\":\"\(error ?? "Invalid webhook")\"}".utf8))
        }

        // Process the event asynchronously — return 200 immediately
        Task { await StripeManager.shared.handleWebhookEvent(event) }

        return HTTPResponse.json(["received": true])
    }

    // ────────────────────────────────────────────────
    // MARK: - Cloud Stats (admin only)
    // ────────────────────────────────────────────────

    /// GET /v1/cloud/stats
    /// Returns cloud deployment stats. Requires server token auth (admin).
    static func handleCloudStats() async -> HTTPResponse {
        let userStats = await CloudUserManager.shared.stats()
        let authEnabled = await SupabaseAuth.shared.isEnabled
        let billingEnabled = await StripeManager.shared.isEnabled

        var stats: [String: Any] = [
            "cloud_mode": true,
            "auth_enabled": authEnabled,
            "billing_enabled": billingEnabled,
            "uptime_seconds": Int(Date().timeIntervalSince(GatewayServer.serverStartTime)),
        ]

        for (k, v) in userStats {
            stats[k] = v
        }

        return HTTPResponse.json(stats)
    }
}
