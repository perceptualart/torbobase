// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — FileVault
// Secure file storage with HMAC-signed expiring download URLs.
// Every creative tool stores output here; every bridge delivers from here.
// The foundation: build once, deliver everywhere.

import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Crypto)
import Crypto
#endif

actor FileVault {
    static let shared = FileVault()

    // MARK: - Types

    struct VaultEntry: Codable, Sendable {
        let id: String
        let originalName: String
        let storagePath: String
        let mimeType: String
        let sizeBytes: Int
        let createdAt: Date
        let expiresAt: Date
        let accessToken: String
    }

    // MARK: - Configuration

    /// Max single file size: 100 MB
    private let maxFileSize = 100 * 1024 * 1024

    /// Max total vault size: 1 GB
    private let maxVaultSize = 1024 * 1024 * 1024

    /// Default expiration: 1 hour
    private let defaultExpiration: TimeInterval = 3600

    // MARK: - State

    private var entries: [String: VaultEntry] = [:]
    private var totalBytes: Int = 0
    private var cleanupTask: Task<Void, Never>?

    // MARK: - Paths

    private var vaultDir: String { PlatformPaths.fileVaultDir }

    // MARK: - Initialization

    func initialize() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
        chmod(vaultDir, 0o700)

        // Recover any files left from previous session (scan directory)
        recoverExistingFiles()

        // Start periodic cleanup
        cleanupTask = Task { [weak self = Optional(self)] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
                guard !Task.isCancelled else { break }
                // Note: self is Optional since we captured it; unwrap for actor method
                await FileVault.shared.cleanup()
            }
        }

        TorboLog.info("FileVault initialized at \(vaultDir)", subsystem: "FileVault")
    }

    /// Clean up on shutdown
    func shutdown() {
        cleanupTask?.cancel()
        cleanupTask = nil
        // Remove all expired files
        cleanup()
        TorboLog.info("FileVault shut down (\(entries.count) entries remaining)", subsystem: "FileVault")
    }

    // MARK: - Store

    /// Store a file from disk path into the vault.
    /// Returns the VaultEntry on success, nil on failure.
    func store(sourceFilePath: String, originalName: String, mimeType: String, expiresIn: TimeInterval? = nil) -> VaultEntry? {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceFilePath) else {
            TorboLog.error("Source file not found: \(sourceFilePath)", subsystem: "FileVault")
            return nil
        }

        guard let data = fm.contents(atPath: sourceFilePath) else {
            TorboLog.error("Could not read source file: \(sourceFilePath)", subsystem: "FileVault")
            return nil
        }

        return store(data: data, originalName: originalName, mimeType: mimeType, expiresIn: expiresIn)
    }

    /// Store raw data into the vault.
    /// Returns the VaultEntry on success, nil on failure.
    func store(data: Data, originalName: String, mimeType: String, expiresIn: TimeInterval? = nil) -> VaultEntry? {
        guard data.count <= maxFileSize else {
            TorboLog.error("File too large (\(data.count) bytes > \(maxFileSize) max)", subsystem: "FileVault")
            return nil
        }

        // Enforce total vault size — clean up expired first
        cleanup()
        guard totalBytes + data.count <= maxVaultSize else {
            TorboLog.error("Vault full (\(totalBytes) + \(data.count) > \(maxVaultSize))", subsystem: "FileVault")
            return nil
        }

        let entryID = UUID().uuidString
        let expiration = expiresIn ?? defaultExpiration
        let now = Date()
        let expiresAt = now.addingTimeInterval(expiration)

        // Generate HMAC access token
        let token = generateToken(entryID: entryID, expiresAt: expiresAt)

        // Write file to vault directory (UUID name, no extension — prevents guessing)
        let storagePath = vaultDir + "/" + entryID
        let fm = FileManager.default
        guard fm.createFile(atPath: storagePath, contents: data) else {
            TorboLog.error("Failed to write vault file: \(storagePath)", subsystem: "FileVault")
            return nil
        }
        chmod(storagePath, 0o600)

        let entry = VaultEntry(
            id: entryID,
            originalName: sanitizeFilename(originalName),
            storagePath: storagePath,
            mimeType: mimeType,
            sizeBytes: data.count,
            createdAt: now,
            expiresAt: expiresAt,
            accessToken: token
        )

        entries[entryID] = entry
        totalBytes += data.count

        TorboLog.info("Stored \(originalName) (\(formatBytes(data.count))) expires in \(Int(expiration))s", subsystem: "FileVault")
        return entry
    }

    // MARK: - Retrieve

    /// Retrieve file data by ID + token. Returns (data, entry) or nil if invalid/expired.
    func retrieve(id: String, token: String) -> (Data, VaultEntry)? {
        guard let entry = entries[id] else {
            TorboLog.warn("Retrieve failed: entry \(id.prefix(8)) not found", subsystem: "FileVault")
            return nil
        }

        // Check expiration
        guard Date() < entry.expiresAt else {
            TorboLog.warn("Retrieve failed: entry \(id.prefix(8)) expired", subsystem: "FileVault")
            removeEntry(id)
            return nil
        }

        // Verify HMAC token
        let expectedToken = generateToken(entryID: entry.id, expiresAt: entry.expiresAt)
        guard constantTimeEqual(token, expectedToken) else {
            TorboLog.warn("Retrieve failed: invalid token for \(id.prefix(8))", subsystem: "FileVault")
            return nil
        }

        // Read file data
        guard let data = FileManager.default.contents(atPath: entry.storagePath) else {
            TorboLog.error("Retrieve failed: file missing at \(entry.storagePath)", subsystem: "FileVault")
            removeEntry(id)
            return nil
        }

        return (data, entry)
    }

    // MARK: - URLs

    /// Construct a download URL for a vault entry.
    func downloadURL(for entry: VaultEntry, baseURL: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(base)/v1/files/\(entry.id)?token=\(entry.accessToken)"
    }

    /// Resolve the base URL for constructing download links.
    /// Priority: TORBO_EXTERNAL_URL env var > Tailscale IP > localhost
    nonisolated static func resolveBaseURL(port: UInt16) -> String {
        // 1. Explicit env var (user-configured for tunnels, custom domains)
        if let externalURL = ProcessInfo.processInfo.environment["TORBO_EXTERNAL_URL"],
           !externalURL.isEmpty {
            return externalURL.hasSuffix("/") ? String(externalURL.dropLast()) : externalURL
        }

        // 2. Tailscale IP detection (same pattern as PairingManager)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if os(macOS)
                let saLen = socklen_t(sa.pointee.sa_len)
                #else
                let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                getnameinfo(sa, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip.hasPrefix("100.") {
                    let parts = ip.split(separator: ".").compactMap { Int($0) }
                    if parts.count >= 2 && parts[1] >= 64 && parts[1] <= 127 {
                        return "http://\(ip):\(port)"
                    }
                }
            }
        }

        // 3. Fallback: localhost
        return "http://127.0.0.1:\(port)"
    }

    // MARK: - Cleanup

    /// Remove expired entries and their files.
    func cleanup() {
        let now = Date()
        var removed = 0
        for (id, entry) in entries {
            if now >= entry.expiresAt {
                removeEntry(id)
                removed += 1
            }
        }
        if removed > 0 {
            TorboLog.info("Cleaned up \(removed) expired file(s), vault: \(formatBytes(totalBytes))", subsystem: "FileVault")
        }
    }

    // MARK: - Stats

    var stats: [String: Any] {
        [
            "entries": entries.count,
            "total_bytes": totalBytes,
            "total_human": formatBytes(totalBytes),
            "max_bytes": maxVaultSize,
            "vault_dir": vaultDir
        ]
    }

    /// Get an entry by ID (for bridge file delivery to check size/type without full retrieve)
    func entry(for id: String) -> VaultEntry? {
        entries[id]
    }

    // MARK: - Private Helpers

    private func removeEntry(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        totalBytes = max(0, totalBytes - entry.sizeBytes)
        try? FileManager.default.removeItem(atPath: entry.storagePath)
    }

    /// Recover files left from a previous session (orphaned vault files).
    /// We can't recover metadata, so we just clean them up.
    private func recoverExistingFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: vaultDir) else { return }
        var cleaned = 0
        for file in files {
            let path = vaultDir + "/" + file
            try? fm.removeItem(atPath: path)
            cleaned += 1
        }
        if cleaned > 0 {
            TorboLog.info("Cleaned \(cleaned) orphaned vault file(s) from previous session", subsystem: "FileVault")
        }
    }

    /// Generate HMAC-SHA256 token from entry ID + expiration.
    /// Uses machine-derived secret (same seed pattern as KeychainManager).
    private func generateToken(entryID: String, expiresAt: Date) -> String {
        let message = "\(entryID):\(Int(expiresAt.timeIntervalSince1970))"
        let messageData = Data(message.utf8)
        let key = Self.vaultSecret

        #if canImport(CommonCrypto)
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            messageData.withUnsafeBytes { msgPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyPtr.baseAddress, key.count,
                       msgPtr.baseAddress, messageData.count,
                       &hmac)
            }
        }
        return Data(hmac).map { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: SHA256 hash (less secure but functional)
        return sha256Hex(message + String(data: key, encoding: .utf8)!)
        #endif
    }

    /// Machine-derived secret for HMAC signing.
    /// Cached after first derivation — same pattern as KeychainManager.encryptionKey.
    private static var _cachedSecret: Data?
    private nonisolated static var vaultSecret: Data {
        if let cached = _cachedSecret { return cached }
        var seed = "torbo-filevault-hmac-v1"
        seed += NSUserName()
        seed += NSHomeDirectory()
        let seedData = Data(seed.utf8)
        #if canImport(CommonCrypto)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        seedData.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(seedData.count), &hash)
        }
        let secret = Data(hash)
        #elseif canImport(Crypto)
        let digest = SHA256.hash(data: seedData)
        let secret = Data(digest)
        #else
        var keyBytes = Array(seedData.prefix(32))
        while keyBytes.count < 32 { keyBytes.append(0) }
        let secret = Data(keyBytes)
        #endif
        _cachedSecret = secret
        return secret
    }

    /// Constant-time string comparison to prevent timing attacks on token verification.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    /// Sanitize filename — remove path components and dangerous characters.
    private func sanitizeFilename(_ name: String) -> String {
        let cleaned = (name as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        return String(cleaned.unicodeScalars.filter { allowed.contains($0) })
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / 1024 / 1024) MB"
    }

    // MARK: - MIME Type Detection

    /// Detect MIME type from file extension.
    nonisolated static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        // Images
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "tiff", "tif": return "image/tiff"
        // Video
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        // Audio
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        // Documents
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "txt", "md", "markdown": return "text/plain"
        case "html", "htm": return "text/html"
        // 3D Models
        case "obj": return "model/obj"
        case "stl": return "model/stl"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        // Archives
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        default: return "application/octet-stream"
        }
    }
}
