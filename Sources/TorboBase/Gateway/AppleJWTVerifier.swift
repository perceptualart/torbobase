// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Apple Sign-In JWT (RS256) verification using Security.framework
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Types

struct AppleJWTClaims: Sendable {
    let sub: String         // Stable Apple user ID (e.g. "001234.abc...")
    let email: String?      // Optional — user may hide email
    let aud: String         // Audience (should be bundle ID)
    let iss: String         // Issuer (should be "https://appleid.apple.com")
    let exp: TimeInterval   // Expiration (unix timestamp)
    let iat: TimeInterval   // Issued at (unix timestamp)
}

enum AppleJWTError: Error, CustomStringConvertible {
    case malformedToken
    case unsupportedAlgorithm
    case kidNotFound
    case jwksFetchFailed
    case invalidSignature
    case expired
    case wrongIssuer
    case wrongAudience
    case payloadDecodeFailed
    case secKeyCreationFailed
    case offlineNoCache

    var description: String {
        switch self {
        case .malformedToken:        return "Malformed token"
        case .unsupportedAlgorithm:  return "Unsupported algorithm (expected RS256)"
        case .kidNotFound:           return "Key ID not found in Apple JWKS"
        case .jwksFetchFailed:       return "Failed to fetch Apple JWKS"
        case .invalidSignature:      return "Invalid signature"
        case .expired:               return "Token expired"
        case .wrongIssuer:           return "Wrong issuer"
        case .wrongAudience:         return "Wrong audience"
        case .payloadDecodeFailed:   return "Payload decode failed"
        case .secKeyCreationFailed:  return "SecKey creation failed"
        case .offlineNoCache:        return "Offline with no cached keys"
        }
    }
}

// MARK: - JWKS Key

private struct JWKSKey {
    let kid: String
    let n: String   // RSA modulus (base64url)
    let e: String   // RSA exponent (base64url)
}

// MARK: - Verifier Actor

actor AppleJWTVerifier {
    static let shared = AppleJWTVerifier()

    private static let expectedIssuer = "https://appleid.apple.com"
    private static let expectedAudience = "com.torbo.Torbo"
    private static let jwksURL = "https://appleid.apple.com/auth/keys"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    private var cachedKeys: [String: JWKSKey] = [:]
    private var lastFetchTime: Date?

    // MARK: - Public API

    func verify(_ token: String) async throws -> AppleJWTClaims {
        // 1. Split JWT into parts
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AppleJWTError.malformedToken }

        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        // 2. Decode header to get kid + alg
        guard let headerData = base64URLDecode(headerB64),
              let headerJSON = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let kid = headerJSON["kid"] as? String,
              let alg = headerJSON["alg"] as? String else {
            throw AppleJWTError.malformedToken
        }
        guard alg == "RS256" else { throw AppleJWTError.unsupportedAlgorithm }

        // 3. Get the matching JWK
        let jwk = try await getKey(kid: kid)

        // 4. Verify RS256 signature
        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)
        guard let signatureData = base64URLDecode(signatureB64) else {
            throw AppleJWTError.malformedToken
        }
        try verifyRS256(signingInput: signingInput, signature: signatureData, jwk: jwk)

        // 5. Decode and validate claims
        guard let payloadData = base64URLDecode(payloadB64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw AppleJWTError.payloadDecodeFailed
        }

        guard let sub = payload["sub"] as? String,
              let aud = payload["aud"] as? String,
              let iss = payload["iss"] as? String,
              let exp = payload["exp"] as? TimeInterval,
              let iat = payload["iat"] as? TimeInterval else {
            throw AppleJWTError.payloadDecodeFailed
        }

        // Validate claims
        guard iss == Self.expectedIssuer else { throw AppleJWTError.wrongIssuer }
        guard aud == Self.expectedAudience else { throw AppleJWTError.wrongAudience }
        guard exp > Date().timeIntervalSince1970 else { throw AppleJWTError.expired }

        let email = payload["email"] as? String

        return AppleJWTClaims(sub: sub, email: email, aud: aud, iss: iss, exp: exp, iat: iat)
    }

    // MARK: - JWKS Fetch + Cache

    private func getKey(kid: String) async throws -> JWKSKey {
        // Check cache (within TTL)
        if let cached = cachedKeys[kid],
           let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < Self.cacheTTL {
            return cached
        }

        // kid miss or stale cache — refresh
        try await fetchJWKS()

        guard let key = cachedKeys[kid] else {
            throw AppleJWTError.kidNotFound
        }
        return key
    }

    private func fetchJWKS() async throws {
        guard let url = URL(string: Self.jwksURL) else {
            throw AppleJWTError.jwksFetchFailed
        }

        let data: Data
        let response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await URLSession.shared.data(from: url)
            #else
            (data, response) = try await URLSession.shared.data(from: url)
            #endif
        } catch {
            // Offline — use stale cache if available
            if !cachedKeys.isEmpty {
                TorboLog.warn("JWKS fetch failed, using stale cache (\(cachedKeys.count) keys)", subsystem: "AppleJWT")
                return
            }
            throw AppleJWTError.offlineNoCache
        }

        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            if !cachedKeys.isEmpty {
                TorboLog.warn("JWKS fetch returned \(httpResp.statusCode), using stale cache", subsystem: "AppleJWT")
                return
            }
            throw AppleJWTError.jwksFetchFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [[String: Any]] else {
            if !cachedKeys.isEmpty {
                TorboLog.warn("JWKS parse failed, using stale cache", subsystem: "AppleJWT")
                return
            }
            throw AppleJWTError.jwksFetchFailed
        }

        var newKeys: [String: JWKSKey] = [:]
        for keyDict in keys {
            guard let kid = keyDict["kid"] as? String,
                  let kty = keyDict["kty"] as? String, kty == "RSA",
                  let n = keyDict["n"] as? String,
                  let e = keyDict["e"] as? String else { continue }
            newKeys[kid] = JWKSKey(kid: kid, n: n, e: e)
        }

        if !newKeys.isEmpty {
            cachedKeys = newKeys
            lastFetchTime = Date()
            TorboLog.info("Cached \(newKeys.count) Apple JWKS key(s)", subsystem: "AppleJWT")
        }
    }

    // MARK: - RS256 Verification

    private func verifyRS256(signingInput: Data, signature: Data, jwk: JWKSKey) throws {
        #if canImport(Security)
        // Build DER-encoded SubjectPublicKeyInfo from JWK n/e
        guard let modulusData = base64URLDecode(jwk.n),
              let exponentData = base64URLDecode(jwk.e) else {
            throw AppleJWTError.secKeyCreationFailed
        }

        let derKey = buildRSAPublicKeyDER(modulus: modulusData, exponent: exponentData)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulusData.count * 8
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derKey as CFData, attributes as CFDictionary, &error) else {
            TorboLog.error("SecKey creation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")", subsystem: "AppleJWT")
            throw AppleJWTError.secKeyCreationFailed
        }

        // SHA-256 digest of signing input
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        signingInput.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(signingInput.count), &digest)
        }
        let digestData = Data(digest)

        // Verify with PKCS1v15 SHA256
        let verified = SecKeyVerifySignature(
            secKey,
            .rsaSignatureDigestPKCS1v15SHA256,
            digestData as CFData,
            signature as CFData,
            &error
        )

        if !verified {
            throw AppleJWTError.invalidSignature
        }
        #else
        // Linux: no Security.framework — reject
        throw AppleJWTError.invalidSignature
        #endif
    }

    // MARK: - DER Encoding

    /// Build a DER-encoded RSA public key (SubjectPublicKeyInfo) from raw modulus + exponent.
    /// Format: SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE { INTEGER n, INTEGER e } } }
    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        // RSA OID: 1.2.840.113549.1.1.1
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let null: [UInt8] = [0x05, 0x00]

        let modulusInteger = derInteger(modulus)
        let exponentInteger = derInteger(exponent)

        // Inner SEQUENCE: { INTEGER n, INTEGER e }
        let innerSequence = derSequence(modulusInteger + exponentInteger)

        // BIT STRING wrapping the inner sequence (prepend 0x00 unused-bits byte)
        let bitStringContent = Data([0x00]) + innerSequence
        let bitString = derTag(0x03, bitStringContent)

        // Algorithm SEQUENCE: { OID, NULL }
        let algorithmSequence = derSequence(Data(rsaOID) + Data(null))

        // Outer SEQUENCE: { algorithmSequence, bitString }
        return derSequence(algorithmSequence + bitString)
    }

    private func derInteger(_ data: Data) -> Data {
        var bytes = Array(data)
        // Strip leading zeros (but keep at least one byte)
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        // If high bit set, prepend 0x00 (positive integer)
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTag(0x02, Data(bytes))
    }

    private func derSequence(_ content: Data) -> Data {
        derTag(0x30, content)
    }

    private func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        let length = content.count
        if length < 128 {
            result.append(UInt8(length))
        } else if length < 256 {
            result.append(contentsOf: [0x81, UInt8(length)])
        } else {
            result.append(contentsOf: [0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
        result.append(content)
        return result
    }

    // MARK: - Base64URL

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
