// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Supabase Authentication
// Magic link email auth via Supabase GoTrue REST API.
// No SDK dependency — uses URLSession directly.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Crypto)
import Crypto
#endif

// MARK: - Cloud User

struct CloudUser: Codable, Sendable {
    let id: String           // Supabase auth.users UUID
    let email: String
    var planTier: PlanTier
    var stripeCustomerID: String?
    var stripeSubscriptionID: String?
    var subscriptionStatus: String?  // active, canceled, past_due, etc.
    var createdAt: String
    var lastActive: String
    var dailyMessageCount: Int
    var lastMessageDate: String      // YYYY-MM-DD for daily reset
}

// MARK: - Plan Tiers
//
// Three tiers:
//   free_base — Self-hosted on Mac. No account, no cloud. User provides own API keys.
//   torbo     — $5/month (1 month free trial). Cloud-hosted Base, all features.
//   torbo_max — $10/month (30 day free trial). Everything + admin panel + priority routing.

enum PlanTier: String, Codable, Sendable {
    case freeBase = "free_base"
    case torbo = "torbo"
    case torboMax = "torbo_max"

    var displayName: String {
        switch self {
        case .freeBase: return "Torbo Base"
        case .torbo: return "Torbo"
        case .torboMax: return "Torbo Max"
        }
    }

    /// Daily message limit for cloud users.
    /// free_base is self-hosted — limits are irrelevant (user owns the server).
    /// Cloud tiers: torbo has standard limits, torbo_max gets higher limits.
    var dailyMessageLimit: Int {
        switch self {
        case .freeBase: return Int.max   // self-hosted, no cloud limits
        case .torbo: return 500          // standard rate limit
        case .torboMax: return Int.max   // higher limits (effectively unlimited)
        }
    }

    /// Allowed agents. Empty = all agents allowed.
    /// All cloud tiers get all 4 agents (SiD, aDa, Mira, Orion).
    var allowedAgents: [String] {
        return []  // all agents on all tiers
    }

    var hasElevenLabsVoice: Bool {
        switch self {
        case .freeBase: return true   // self-hosted, user provides own ElevenLabs key
        case .torbo: return true      // included
        case .torboMax: return true   // included
        }
    }

    /// Piper on-device voices — always available
    var hasPiperVoice: Bool { true }

    var hasTools: Bool {
        switch self {
        case .freeBase: return true   // self-hosted, full access
        case .torbo: return true      // tools, HomeKit, Shortcuts included
        case .torboMax: return true   // plus advanced tools
        }
    }

    var hasHomeKit: Bool {
        switch self {
        case .freeBase: return true   // self-hosted, full access
        case .torbo: return true      // included
        case .torboMax: return true   // included
        }
    }

    /// Advanced tools: code sandbox, Docker execution, browser automation
    var hasAdvancedTools: Bool {
        switch self {
        case .freeBase: return true    // self-hosted, full access
        case .torbo: return false      // standard tools only
        case .torboMax: return true    // advanced tools unlocked
        }
    }

    var hasPriorityRouting: Bool {
        switch self {
        case .freeBase: return false   // self-hosted, routes to own providers
        case .torbo: return false      // standard routing
        case .torboMax: return true    // priority routing
        }
    }

    /// Admin panel access in Arkhe: dashboard, agent management, security,
    /// memory viewer/editor, system prompt editor, token budgets, activity monitor, kill switches.
    /// Self-hosted users always get admin (checked at iOS layer by detecting local Base).
    var hasAdminPanel: Bool {
        switch self {
        case .freeBase: return true    // self-hosted always gets admin
        case .torbo: return false      // no admin panel
        case .torboMax: return true    // admin panel unlocked
        }
    }

    /// Max access level.
    /// self-hosted: FULL (user controls their own server)
    /// torbo: WRITE (tools, HomeKit, but no exec/shell)
    /// torbo_max: FULL (advanced tools, admin panel)
    var maxAccessLevel: Int {
        switch self {
        case .freeBase: return 5   // FULL
        case .torbo: return 3      // up to WRITE
        case .torboMax: return 5   // FULL
        }
    }

    var monthlyPrice: Double {
        switch self {
        case .freeBase: return 0.0
        case .torbo: return 5.0
        case .torboMax: return 10.0
        }
    }

    /// Free trial days for new subscribers
    var trialDays: Int {
        switch self {
        case .freeBase: return 0
        case .torbo: return 30      // 1 month free trial
        case .torboMax: return 30   // 30 day free trial
        }
    }
}

// MARK: - JWT Claims

struct JWTClaims: Sendable {
    let sub: String          // user UUID
    let email: String
    let exp: Int             // expiration timestamp
    let iat: Int             // issued at
    let role: String         // authenticated, anon, etc.
    let sessionID: String?   // Supabase session ID
}

// MARK: - Supabase Auth Actor

actor SupabaseAuth {
    static let shared = SupabaseAuth()

    private var supabaseURL: String = ""
    private var supabaseAnonKey: String = ""
    private var supabaseServiceKey: String = ""
    private var jwtSecret: String = ""
    private var initialized = false

    // Cache user records for 5 minutes to avoid hitting Supabase on every request
    private var userCache: [String: (user: CloudUser, cachedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 300  // 5 minutes

    // MARK: - Initialization

    func initialize() {
        let env = ProcessInfo.processInfo.environment
        supabaseURL = env["SUPABASE_URL"] ?? ""
        supabaseAnonKey = env["SUPABASE_ANON_KEY"] ?? ""
        supabaseServiceKey = env["SUPABASE_SERVICE_KEY"] ?? ""
        jwtSecret = env["SUPABASE_JWT_SECRET"] ?? ""

        if supabaseURL.isEmpty || supabaseAnonKey.isEmpty {
            TorboLog.warn("Supabase not configured — cloud auth disabled", subsystem: "CloudAuth")
            return
        }
        if jwtSecret.isEmpty {
            TorboLog.warn("SUPABASE_JWT_SECRET not set — JWT validation will use Supabase API", subsystem: "CloudAuth")
        }

        initialized = true
        TorboLog.info("Supabase auth initialized: \(supabaseURL)", subsystem: "CloudAuth")
    }

    var isEnabled: Bool { initialized }

    // MARK: - Magic Link

    /// Send a magic link email via Supabase GoTrue
    func sendMagicLink(email: String) async -> (success: Bool, error: String?) {
        guard initialized else { return (false, "Cloud auth not configured") }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/magiclink") else {
            return (false, "Invalid Supabase URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["email": email]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (false, "Failed to encode request")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            if statusCode == 200 || statusCode == 204 {
                TorboLog.info("Magic link sent to \(email)", subsystem: "CloudAuth")
                return (true, nil)
            } else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                TorboLog.error("Magic link failed (\(statusCode)): \(errorMsg)", subsystem: "CloudAuth")
                return (false, "Failed to send magic link: \(errorMsg)")
            }
        } catch {
            TorboLog.error("Magic link request failed: \(error)", subsystem: "CloudAuth")
            return (false, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Token Verification

    /// Verify a magic link token and exchange it for a session
    func verifyToken(token: String, type: String = "magiclink") async -> (accessToken: String?, refreshToken: String?, user: CloudUser?, error: String?) {
        guard initialized else { return (nil, nil, nil, "Cloud auth not configured") }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/verify") else {
            return (nil, nil, nil, "Invalid Supabase URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "token": token,
            "type": type,
            "token_hash": token
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, nil, nil, "Failed to encode request")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            guard statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                return (nil, nil, nil, "Verification failed (\(statusCode)): \(errorMsg)")
            }

            let accessToken = json["access_token"] as? String
            let refreshToken = json["refresh_token"] as? String

            // Extract user info
            if let userDict = json["user"] as? [String: Any],
               let userID = userDict["id"] as? String,
               let email = userDict["email"] as? String {
                // Ensure user record exists in our database
                let user = await ensureUserRecord(userID: userID, email: email)
                return (accessToken, refreshToken, user, nil)
            }

            return (accessToken, refreshToken, nil, nil)
        } catch {
            return (nil, nil, nil, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Refresh Token

    /// Refresh an expired access token using the refresh token
    func refreshSession(refreshToken: String) async -> (accessToken: String?, refreshToken: String?, error: String?) {
        guard initialized else { return (nil, nil, "Cloud auth not configured") }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token") else {
            return (nil, nil, "Invalid Supabase URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, nil, "Failed to encode request")
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            guard statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                return (nil, nil, "Refresh failed (\(statusCode)): \(errorMsg)")
            }

            return (json["access_token"] as? String, json["refresh_token"] as? String, nil)
        } catch {
            return (nil, nil, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - JWT Validation (Local)

    /// Validate a JWT and extract claims without calling Supabase API.
    /// Uses HMAC-SHA256 with the JWT secret for signature verification.
    func validateJWT(_ token: String) -> JWTClaims? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        // Verify signature if JWT secret is configured
        if !jwtSecret.isEmpty {
            let signingInput = "\(headerB64).\(payloadB64)"
            guard let signingData = signingInput.data(using: .utf8),
                  let keyData = jwtSecret.data(using: .utf8) else { return nil }

            let expectedSig = hmacSHA256(data: signingData, key: keyData)
            guard let providedSig = base64URLDecode(signatureB64) else { return nil }

            // Constant-time comparison
            guard expectedSig.count == providedSig.count else { return nil }
            var result: UInt8 = 0
            for i in 0..<expectedSig.count {
                result |= expectedSig[i] ^ providedSig[i]
            }
            guard result == 0 else {
                TorboLog.warn("JWT signature mismatch", subsystem: "CloudAuth")
                return nil
            }
        }

        // Decode payload
        guard let payloadData = base64URLDecode(payloadB64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        guard let sub = payload["sub"] as? String,
              let exp = payload["exp"] as? Int else {
            return nil
        }

        // Check expiration
        if exp < Int(Date().timeIntervalSince1970) {
            TorboLog.debug("JWT expired for user \(sub)", subsystem: "CloudAuth")
            return nil
        }

        return JWTClaims(
            sub: sub,
            email: payload["email"] as? String ?? "",
            exp: exp,
            iat: payload["iat"] as? Int ?? 0,
            role: payload["role"] as? String ?? "authenticated",
            sessionID: payload["session_id"] as? String
        )
    }

    // MARK: - User via JWT (API call)

    /// Get user info from Supabase using an access token (API validation)
    func getUserFromToken(_ accessToken: String) async -> (userID: String?, email: String?, error: String?) {
        guard initialized else { return (nil, nil, "Cloud auth not configured") }

        guard let url = URL(string: "\(supabaseURL)/auth/v1/user") else {
            return (nil, nil, "Invalid Supabase URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            guard httpResponse?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userID = json["id"] as? String else {
                return (nil, nil, "Invalid token")
            }
            let email = json["email"] as? String
            return (userID, email, nil)
        } catch {
            return (nil, nil, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - User Record Management

    /// Ensure a user record exists in Supabase. Creates one if missing.
    func ensureUserRecord(userID: String, email: String) async -> CloudUser {
        // Check cache first
        if let cached = userCache[userID], Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            return cached.user
        }

        // Try to fetch from Supabase
        if let existing = await fetchUserRecord(userID: userID) {
            userCache[userID] = (existing, Date())
            return existing
        }

        // Create new user record
        let now = ISO8601DateFormatter().string(from: Date())
        let today = formatDate(Date())
        let newUser = CloudUser(
            id: userID,
            email: email,
            planTier: .torbo,  // New cloud signups start on Torbo (with free trial)
            stripeCustomerID: nil,
            stripeSubscriptionID: nil,
            subscriptionStatus: nil,
            createdAt: now,
            lastActive: now,
            dailyMessageCount: 0,
            lastMessageDate: today
        )

        await upsertUserRecord(newUser)
        userCache[userID] = (newUser, Date())
        TorboLog.info("Created cloud user: \(email) (\(userID))", subsystem: "CloudAuth")
        return newUser
    }

    /// Fetch user record from Supabase database
    func fetchUserRecord(userID: String) async -> CloudUser? {
        guard initialized, !supabaseServiceKey.isEmpty else { return nil }

        guard let url = URL(string: "\(supabaseURL)/rest/v1/cloud_users?id=eq.\(userID)&select=*") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseServiceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseServiceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            guard httpResponse?.statusCode == 200 else { return nil }

            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else { return nil }

            return parseUserRow(row)
        } catch {
            TorboLog.error("Failed to fetch user \(userID): \(error)", subsystem: "CloudAuth")
            return nil
        }
    }

    /// Upsert user record in Supabase database
    func upsertUserRecord(_ user: CloudUser) async {
        guard initialized, !supabaseServiceKey.isEmpty else { return }

        guard let url = URL(string: "\(supabaseURL)/rest/v1/cloud_users") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseServiceKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseServiceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")

        let row: [String: Any] = [
            "id": user.id,
            "email": user.email,
            "plan_tier": user.planTier.rawValue,
            "stripe_customer_id": user.stripeCustomerID as Any,
            "stripe_subscription_id": user.stripeSubscriptionID as Any,
            "subscription_status": user.subscriptionStatus as Any,
            "created_at": user.createdAt,
            "last_active": user.lastActive,
            "daily_message_count": user.dailyMessageCount,
            "last_message_date": user.lastMessageDate
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: row) else { return }
        request.httpBody = bodyData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            if let code = httpResponse?.statusCode, code >= 400 {
                TorboLog.error("Failed to upsert user \(user.id): HTTP \(code)", subsystem: "CloudAuth")
            }
        } catch {
            TorboLog.error("Failed to upsert user \(user.id): \(error)", subsystem: "CloudAuth")
        }
    }

    /// Update a user's plan tier (called from Stripe webhook handler)
    func updateUserTier(userID: String, tier: PlanTier, stripeCustomerID: String?, stripeSubscriptionID: String?, status: String?) async {
        if var user = await fetchUserRecord(userID: userID) {
            user.planTier = tier
            user.stripeCustomerID = stripeCustomerID
            user.stripeSubscriptionID = stripeSubscriptionID
            user.subscriptionStatus = status
            await upsertUserRecord(user)
            userCache[userID] = (user, Date())
            TorboLog.info("Updated user \(userID) to tier: \(tier.rawValue)", subsystem: "CloudAuth")
        }
    }

    /// Increment daily message count for a user. Returns (allowed, remaining).
    func trackMessage(userID: String) async -> (allowed: Bool, remaining: Int) {
        var user: CloudUser? = userCache[userID]?.user
        if user == nil {
            user = await fetchUserRecord(userID: userID)
        }
        guard var currentUser = user else {
            return (false, 0)
        }

        let today = formatDate(Date())
        if currentUser.lastMessageDate != today {
            currentUser.dailyMessageCount = 0
            currentUser.lastMessageDate = today
        }

        let limit = currentUser.planTier.dailyMessageLimit
        if currentUser.dailyMessageCount >= limit {
            return (false, 0)
        }

        currentUser.dailyMessageCount += 1
        currentUser.lastActive = ISO8601DateFormatter().string(from: Date())
        userCache[userID] = (currentUser, Date())

        // Persist every 10 messages to avoid hammering Supabase
        if currentUser.dailyMessageCount % 10 == 0 {
            await upsertUserRecord(currentUser)
        }

        return (true, limit - currentUser.dailyMessageCount)
    }

    /// Get cached user (for quick lookups)
    func cachedUser(_ userID: String) -> CloudUser? {
        guard let entry = userCache[userID] else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > cacheTTL { return nil }
        return entry.user
    }

    /// Invalidate cache for a user (call after Stripe webhook updates)
    func invalidateCache(userID: String) {
        userCache.removeValue(forKey: userID)
    }

    // MARK: - Helpers

    private func parseUserRow(_ row: [String: Any]) -> CloudUser {
        CloudUser(
            id: row["id"] as? String ?? "",
            email: row["email"] as? String ?? "",
            planTier: PlanTier(rawValue: row["plan_tier"] as? String ?? "torbo") ?? .torbo,
            stripeCustomerID: row["stripe_customer_id"] as? String,
            stripeSubscriptionID: row["stripe_subscription_id"] as? String,
            subscriptionStatus: row["subscription_status"] as? String,
            createdAt: row["created_at"] as? String ?? "",
            lastActive: row["last_active"] as? String ?? "",
            dailyMessageCount: row["daily_message_count"] as? Int ?? 0,
            lastMessageDate: row["last_message_date"] as? String ?? ""
        )
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func hmacSHA256(data: Data, key: Data) -> Data {
        #if canImport(CommonCrypto)
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        &hmac)
            }
        }
        return Data(hmac)
        #elseif canImport(Crypto)
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(signature)
        #else
        // Fallback — should never happen in production
        return Data()
        #endif
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
