// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Integrity Verifier
// Ed25519 signing and SHA-256 hashing for community skill packages and knowledge.
// Uses CryptoKit (macOS) or swift-crypto (Linux), same pattern as KeychainManager.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Cryptographic primitives for skill package integrity and community identity.
enum SkillIntegrityVerifier {

    // MARK: - Key Storage Keys

    private static let privateKeyKeychainKey = "community.ed25519.private"
    private static let publicKeyKeychainKey = "community.ed25519.public"
    private static let nodeIDKeychainKey = "community.node.id"

    // MARK: - Key Pair Generation

    /// Generate and persist an Ed25519 key pair for this node.
    /// If keys already exist, returns the existing public key.
    /// Private key stored via KeychainManager.
    @discardableResult
    static func ensureKeyPair() -> (publicKey: String, nodeID: String) {
        // Return existing if available
        if let existingPub = KeychainManager.get(publicKeyKeychainKey),
           let existingID = KeychainManager.get(nodeIDKeychainKey),
           !existingPub.isEmpty, !existingID.isEmpty {
            return (existingPub, existingID)
        }

        // Generate new key pair
        #if canImport(CryptoKit)
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateHex = privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let publicHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateHex = privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let publicHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: random hex (no real signing)
        let privateHex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let publicHex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        #endif

        let nodeID = UUID().uuidString

        KeychainManager.set(privateHex, for: privateKeyKeychainKey)
        KeychainManager.set(publicHex, for: publicKeyKeychainKey)
        KeychainManager.set(nodeID, for: nodeIDKeychainKey)

        TorboLog.info("Generated Ed25519 key pair for node \(nodeID)", subsystem: "Community")
        return (publicHex, nodeID)
    }

    // MARK: - Signing

    /// Sign data with this node's Ed25519 private key.
    /// Returns hex-encoded signature, or empty string on failure.
    static func sign(data: Data) -> String {
        guard let privateHex = KeychainManager.get(privateKeyKeychainKey), !privateHex.isEmpty else {
            TorboLog.warn("No private key available for signing", subsystem: "Community")
            return ""
        }

        guard let privateKeyData = hexToData(privateHex) else { return "" }

        #if canImport(CryptoKit)
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: data)
            return signature.map { String(format: "%02x", $0) }.joined()
        } catch {
            TorboLog.error("Ed25519 signing failed: \(error)", subsystem: "Community")
            return ""
        }
        #elseif canImport(Crypto)
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let signature = try privateKey.signature(for: data)
            return signature.map { String(format: "%02x", $0) }.joined()
        } catch {
            TorboLog.error("Ed25519 signing failed: \(error)", subsystem: "Community")
            return ""
        }
        #else
        return ""
        #endif
    }

    /// Sign a string (UTF-8 encoded).
    static func sign(string: String) -> String {
        sign(data: Data(string.utf8))
    }

    // MARK: - Verification

    /// Verify an Ed25519 signature against a public key.
    static func verify(data: Data, signature signatureHex: String, publicKey publicKeyHex: String) -> Bool {
        guard let signatureData = hexToData(signatureHex),
              let publicKeyData = hexToData(publicKeyHex) else { return false }

        #if canImport(CryptoKit)
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            return publicKey.isValidSignature(signatureData, for: data)
        } catch {
            return false
        }
        #elseif canImport(Crypto)
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            return publicKey.isValidSignature(signatureData, for: data)
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Verify a string signature.
    static func verify(string: String, signature: String, publicKey: String) -> Bool {
        verify(data: Data(string.utf8), signature: signature, publicKey: publicKey)
    }

    // MARK: - Hashing

    /// SHA-256 hash of data, returned as hex string.
    static func sha256Hash(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(CommonCrypto)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: not cryptographically secure
        return String(data.hashValue, radix: 16)
        #endif
    }

    /// SHA-256 hash of a string (UTF-8).
    static func sha256Hash(_ string: String) -> String {
        sha256Hash(Data(string.utf8))
    }

    /// SHA-256 hash of a file at the given path.
    static func hashPackage(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hash(data)
    }

    // MARK: - Helpers

    /// Convert hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { return nil }
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
