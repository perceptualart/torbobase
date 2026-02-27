// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Backend auth token validation client
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor AuthClient {
    static let shared = AuthClient()

    struct ValidationResult {
        let userID: String
        let email: String
        let expiresAt: Date?
    }

    enum AuthError: Error {
        case invalidToken       // Backend says token is invalid (401)
        case expiredToken       // Backend says token is expired (403)
        case backendUnreachable // Network error or 5xx
        case invalidResponse    // Malformed JSON from backend
    }

    /// Validate an auth token with the Torbo backend.
    /// Posts the token to /auth/validate and returns the associated user info.
    func validate(token: String) async throws -> ValidationResult {
        let backendURL = AppConfig.authBackendURL
        guard let url = URL(string: backendURL + "/auth/validate") else {
            throw AuthError.backendUnreachable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let payload = ["token": token]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw AuthError.invalidResponse
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            TorboLog.error("Backend unreachable: \(error.localizedDescription)", subsystem: "Auth")
            throw AuthError.backendUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.backendUnreachable
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw AuthError.invalidToken
        case 403:
            throw AuthError.expiredToken
        default:
            TorboLog.error("Backend returned \(httpResponse.statusCode)", subsystem: "Auth")
            throw AuthError.backendUnreachable
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = json["user_id"] as? String,
              let email = json["email"] as? String else {
            throw AuthError.invalidResponse
        }

        var expiresAt: Date?
        if let expiresStr = json["expires_at"] as? String {
            expiresAt = ISO8601DateFormatter().date(from: expiresStr)
        }

        TorboLog.info("Validated auth token for \(email) (user: \(userID))", subsystem: "Auth")
        return ValidationResult(userID: userID, email: email, expiresAt: expiresAt)
    }
}
