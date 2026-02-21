// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base Cloud — Stripe Subscription Billing
// Handles checkout sessions, webhooks, and subscription lifecycle.
// No SDK — uses Stripe REST API directly via URLSession.

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

// MARK: - Stripe Price Configuration

enum StripePrices {
    // Set these from environment variables — they're your Stripe Price IDs
    static var torboPriceID: String {
        ProcessInfo.processInfo.environment["STRIPE_TORBO_PRICE_ID"] ?? ""
    }
    static var torboMaxPriceID: String {
        ProcessInfo.processInfo.environment["STRIPE_TORBO_MAX_PRICE_ID"] ?? ""
    }

    static func tierForPriceID(_ priceID: String) -> PlanTier? {
        if priceID == torboPriceID { return .torbo }
        if priceID == torboMaxPriceID { return .torboMax }
        return nil
    }
}

// MARK: - Stripe Manager

actor StripeManager {
    static let shared = StripeManager()

    private var secretKey: String = ""
    private var webhookSecret: String = ""
    private var initialized = false

    // MARK: - Initialization

    func initialize() {
        let env = ProcessInfo.processInfo.environment
        secretKey = env["STRIPE_SECRET_KEY"] ?? ""
        webhookSecret = env["STRIPE_WEBHOOK_SECRET"] ?? ""

        if secretKey.isEmpty {
            TorboLog.warn("Stripe not configured — billing disabled", subsystem: "Stripe")
            return
        }

        initialized = true
        TorboLog.info("Stripe billing initialized", subsystem: "Stripe")
    }

    var isEnabled: Bool { initialized }

    // MARK: - Checkout Session

    /// Create a Stripe Checkout session for a subscription upgrade
    func createCheckoutSession(
        userID: String,
        email: String,
        tier: PlanTier,
        successURL: String,
        cancelURL: String
    ) async -> (sessionURL: String?, error: String?) {
        guard initialized else { return (nil, "Billing not configured") }

        let priceID: String
        switch tier {
        case .torbo: priceID = StripePrices.torboPriceID
        case .torboMax: priceID = StripePrices.torboMaxPriceID
        case .freeBase: return (nil, "Torbo Base is free and self-hosted — no checkout needed")
        }

        guard !priceID.isEmpty else {
            return (nil, "Price ID not configured for \(tier.rawValue) tier")
        }

        guard let url = URL(string: "https://api.stripe.com/v1/checkout/sessions") else {
            return (nil, "Invalid Stripe URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(secretKey):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")

        var params = [
            "mode": "subscription",
            "customer_email": email,
            "client_reference_id": userID,
            "line_items[0][price]": priceID,
            "line_items[0][quantity]": "1",
            "success_url": successURL,
            "cancel_url": cancelURL,
            "metadata[user_id]": userID,
            "metadata[tier]": tier.rawValue,
            "subscription_data[metadata][user_id]": userID,
            "subscription_data[metadata][tier]": tier.rawValue,
        ]

        // Add free trial period
        let trialDays = tier.trialDays
        if trialDays > 0 {
            params["subscription_data[trial_period_days]"] = "\(trialDays)"
        }

        let body = params.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            guard statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionURL = json["url"] as? String else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                TorboLog.error("Checkout session failed (\(statusCode)): \(errorMsg)", subsystem: "Stripe")
                return (nil, "Failed to create checkout session")
            }

            let maskedEmail: String = {
                guard let at = email.firstIndex(of: "@") else { return "***" }
                return String(email.prefix(2)) + "***" + email[at...]
            }()
            TorboLog.info("Checkout session created for \(maskedEmail) → \(tier.rawValue)", subsystem: "Stripe")
            return (sessionURL, nil)
        } catch {
            TorboLog.error("Checkout session request failed: \(error)", subsystem: "Stripe")
            return (nil, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Customer Portal

    /// Create a Stripe Customer Portal session for managing subscriptions
    func createPortalSession(stripeCustomerID: String, returnURL: String) async -> (sessionURL: String?, error: String?) {
        guard initialized else { return (nil, "Billing not configured") }

        guard let url = URL(string: "https://api.stripe.com/v1/billing_portal/sessions") else {
            return (nil, "Invalid Stripe URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(secretKey):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")

        let params = [
            "customer": stripeCustomerID,
            "return_url": returnURL,
        ]
        let body = params.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            guard statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionURL = json["url"] as? String else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                TorboLog.error("Portal session failed (\(statusCode)): \(errorMsg)", subsystem: "Stripe")
                return (nil, "Failed to create portal session")
            }

            return (sessionURL, nil)
        } catch {
            return (nil, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Webhook Handling

    /// Verify Stripe webhook signature and parse the event
    func verifyWebhook(payload: Data, signature: String) -> (event: [String: Any]?, error: String?) {
        guard !webhookSecret.isEmpty else {
            return (nil, "Webhook secret not configured")
        }

        // Parse the Stripe-Signature header
        // Format: t=timestamp,v1=signature[,v1=signature...]
        var timestamp: String?
        var signatures: [String] = []

        for part in signature.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1])
            if key == "t" { timestamp = value }
            if key == "v1" { signatures.append(value) }
        }

        guard let ts = timestamp, !signatures.isEmpty else {
            return (nil, "Invalid signature header format")
        }

        // Check timestamp freshness (5 minute tolerance)
        if let tsInt = Int(ts) {
            let age = abs(Int(Date().timeIntervalSince1970) - tsInt)
            if age > 300 {
                return (nil, "Webhook timestamp too old (\(age)s)")
            }
        }

        // Compute expected signature
        let signedPayload = "\(ts).\(String(data: payload, encoding: .utf8) ?? "")"
        guard let signedData = signedPayload.data(using: .utf8),
              let keyData = webhookSecret.data(using: .utf8) else {
            return (nil, "Failed to prepare signature data")
        }

        let expectedSig = hmacSHA256(data: signedData, key: keyData)
        let expectedHex = expectedSig.map { String(format: "%02x", $0) }.joined()

        // Constant-time comparison against all provided v1 signatures
        var matched = false
        for sig in signatures {
            guard sig.count == expectedHex.count else { continue }
            var diff: UInt8 = 0
            let sigBytes = Array(sig.utf8)
            let expectedBytes = Array(expectedHex.utf8)
            for i in 0..<sigBytes.count {
                diff |= sigBytes[i] ^ expectedBytes[i]
            }
            if diff == 0 { matched = true }
        }

        guard matched else {
            return (nil, "Webhook signature mismatch")
        }

        // Parse the event JSON
        guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return (nil, "Failed to parse webhook payload")
        }

        return (event, nil)
    }

    /// Process a verified Stripe webhook event
    func handleWebhookEvent(_ event: [String: Any]) async {
        guard let eventType = event["type"] as? String,
              let data = event["data"] as? [String: Any],
              let object = data["object"] as? [String: Any] else {
            TorboLog.error("Invalid webhook event structure", subsystem: "Stripe")
            return
        }

        TorboLog.info("Stripe webhook: \(eventType)", subsystem: "Stripe")

        switch eventType {
        case "checkout.session.completed":
            await handleCheckoutCompleted(object)

        case "customer.subscription.created",
             "customer.subscription.updated":
            await handleSubscriptionUpdated(object)

        case "customer.subscription.deleted":
            await handleSubscriptionCanceled(object)

        case "invoice.payment_failed":
            await handlePaymentFailed(object)

        default:
            TorboLog.debug("Unhandled Stripe event: \(eventType)", subsystem: "Stripe")
        }
    }

    // MARK: - Event Handlers

    private func handleCheckoutCompleted(_ session: [String: Any]) async {
        guard let customerID = session["customer"] as? String,
              let userID = (session["metadata"] as? [String: Any])?["user_id"] as? String,
              let subscriptionID = session["subscription"] as? String else {
            TorboLog.error("Checkout completed but missing customer/user/subscription ID", subsystem: "Stripe")
            return
        }

        let tierStr = (session["metadata"] as? [String: Any])?["tier"] as? String ?? "torbo"
        let tier = PlanTier(rawValue: tierStr) ?? .torbo

        await SupabaseAuth.shared.updateUserTier(
            userID: userID,
            tier: tier,
            stripeCustomerID: customerID,
            stripeSubscriptionID: subscriptionID,
            status: "active"
        )
        TorboLog.info("Checkout completed: user \(userID) → \(tier.rawValue)", subsystem: "Stripe")
    }

    private func handleSubscriptionUpdated(_ subscription: [String: Any]) async {
        guard let subscriptionID = subscription["id"] as? String,
              let status = subscription["status"] as? String,
              let customerID = subscription["customer"] as? String else { return }

        let userID = (subscription["metadata"] as? [String: Any])?["user_id"] as? String

        // Determine tier from the subscription items
        var tier: PlanTier = .torbo
        if let items = subscription["items"] as? [String: Any],
           let data = items["data"] as? [[String: Any]],
           let firstItem = data.first,
           let price = firstItem["price"] as? [String: Any],
           let priceID = price["id"] as? String {
            tier = StripePrices.tierForPriceID(priceID) ?? .torbo
        }

        // Only set active tier if subscription is active
        let effectiveTier: PlanTier
        switch status {
        case "active", "trialing":
            effectiveTier = tier
        case "past_due":
            effectiveTier = tier  // Keep tier but mark status
        default:
            effectiveTier = .freeBase  // Subscription lapsed → downgrade
        }

        if let uid = userID {
            await SupabaseAuth.shared.updateUserTier(
                userID: uid,
                tier: effectiveTier,
                stripeCustomerID: customerID,
                stripeSubscriptionID: subscriptionID,
                status: status
            )
        } else {
            // Look up user by stripe customer ID
            TorboLog.warn("Subscription \(subscriptionID) updated but no user_id in metadata", subsystem: "Stripe")
        }
    }

    private func handleSubscriptionCanceled(_ subscription: [String: Any]) async {
        guard let userID = (subscription["metadata"] as? [String: Any])?["user_id"] as? String else {
            TorboLog.warn("Subscription canceled but no user_id in metadata", subsystem: "Stripe")
            return
        }

        let customerID = subscription["customer"] as? String
        let subscriptionID = subscription["id"] as? String

        await SupabaseAuth.shared.updateUserTier(
            userID: userID,
            tier: .freeBase,
            stripeCustomerID: customerID,
            stripeSubscriptionID: subscriptionID,
            status: "canceled"
        )
        TorboLog.info("Subscription canceled: user \(userID) → free_base", subsystem: "Stripe")
    }

    private func handlePaymentFailed(_ invoice: [String: Any]) async {
        guard let customerID = invoice["customer"] as? String else { return }
        TorboLog.warn("Payment failed for customer \(customerID)", subsystem: "Stripe")
        // Don't downgrade immediately — Stripe retries. The subscription.updated
        // event with status="past_due" handles the actual status change.
    }

    // MARK: - Subscription Query

    /// Get a customer's active subscription from Stripe
    func getSubscription(subscriptionID: String) async -> [String: Any]? {
        guard initialized else { return nil }

        guard let url = URL(string: "https://api.stripe.com/v1/subscriptions/\(subscriptionID)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Basic \(Data("\(secretKey):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            guard httpResponse?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
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
        return Data()
        #endif
    }
}
