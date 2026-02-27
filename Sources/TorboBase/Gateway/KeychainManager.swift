// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Secure file-based storage for API keys and tokens
// Data is encrypted at rest using a machine-derived key
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(IOKit)
import IOKit
#endif
#if canImport(Crypto)
import Crypto
#endif

/// Secure key-value storage for sensitive data.
/// Uses encrypted file-based storage (~/.config/torbobase/keychain.enc) on all platforms.
/// File permissions are set to owner-only (600) for security.
/// Data is encrypted at rest using AES-256-CBC with a machine-derived key.
enum KeychainManager {

    private static let service = "ai.torbo.base"

    // MARK: - File-based storage (all platforms)

    private static var storageDir: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.config/torbobase"
    }

    /// Encrypted storage path
    private static var storagePath: String {
        storageDir + "/keychain.enc"
    }

    /// Legacy unencrypted path — used for migration
    private static var legacyStoragePath: String {
        storageDir + "/keychain.json"
    }

    // MARK: - Encryption

    /// Cached encryption key — derived once per process lifetime.
    private static var _cachedEncryptionKey: Data?

    /// Derive a 256-bit encryption key from machine-specific data.
    /// Uses SHA-256 hash of (hardware UUID + salt + username) so the encrypted
    /// file is tied to this machine and user. Cached after first derivation.
    private static var encryptionKey: Data {
        if let cached = _cachedEncryptionKey { return cached }
        var seed = "torbo-base-keychain-v1"
        // Add machine-specific entropy
        if let hwUUID = getMachineUUID() { seed += hwUUID }
        seed += NSUserName()
        seed += NSHomeDirectory()
        // SHA-256 to get a 32-byte key
        let seedData = Data(seed.utf8)
        #if canImport(CommonCrypto)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        seedData.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(seedData.count), &hash)
        }
        let key = Data(hash)
        #elseif canImport(Crypto)
        let digest = SHA256.hash(data: seedData)
        let key = Data(digest)
        #else
        // Fallback: use seed bytes directly (truncated/padded to 32)
        var keyBytes = Array(seedData.prefix(32))
        while keyBytes.count < 32 { keyBytes.append(0) }
        let key = Data(keyBytes)
        #endif
        _cachedEncryptionKey = key
        return key
    }

    /// Cached machine UUID — IOKit is only called once per process lifetime.
    private static var _cachedMachineUUID: String?
    private static var _uuidFetched = false

    /// Get the machine's hardware UUID (macOS) using IOKit directly.
    /// Cached after first call to avoid repeated IOKit calls on the main thread
    /// (which caused SIGSEGV crashes during SwiftUI layout passes).
    private static func getMachineUUID() -> String? {
        if _uuidFetched { return _cachedMachineUUID }
        #if os(macOS) && canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            _uuidFetched = true
            return nil
        }
        defer { IOObjectRelease(service) }
        if let uuidCF = IORegistryEntryCreateCFProperty(service,
                                                         "IOPlatformUUID" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() {
            _cachedMachineUUID = uuidCF as? String
            _uuidFetched = true
            return _cachedMachineUUID
        }
        _uuidFetched = true
        return nil
        #else
        _cachedMachineUUID = ProcessInfo.processInfo.hostName
        _uuidFetched = true
        return _cachedMachineUUID
        #endif
    }

    /// Public encrypt for other subsystems (conversation storage, etc.)
    static func encryptData(_ plaintext: Data) -> Data? { encrypt(plaintext) }
    /// Public decrypt for other subsystems
    static func decryptData(_ ciphertext: Data) -> Data? { decrypt(ciphertext) }

    /// Encrypt data — AES-256-CBC on macOS (CommonCrypto), AES-256-GCM on Linux (swift-crypto)
    private static func encrypt(_ plaintext: Data) -> Data? {
        let key = encryptionKey
        #if canImport(CommonCrypto)
        // macOS: AES-256-CBC via CommonCrypto
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        guard SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else { return nil }

        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesEncrypted = 0

        let status = key.withUnsafeBytes { keyPtr in
            plaintext.withUnsafeBytes { dataPtr in
                CCCrypt(CCOperation(kCCEncrypt),
                       CCAlgorithm(kCCAlgorithmAES),
                       CCOptions(kCCOptionPKCS7Padding),
                       keyPtr.baseAddress, kCCKeySizeAES256,
                       iv,
                       dataPtr.baseAddress, plaintext.count,
                       &buffer, bufferSize,
                       &numBytesEncrypted)
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(iv) + Data(buffer.prefix(numBytesEncrypted))
        #elseif canImport(Crypto)
        // Linux: AES-256-GCM via swift-crypto
        do {
            let symmetricKey = SymmetricKey(data: key)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return sealedBox.combined
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Decrypt data — AES-256-CBC on macOS (CommonCrypto), AES-256-GCM on Linux (swift-crypto)
    private static func decrypt(_ ciphertext: Data) -> Data? {
        let key = encryptionKey
        #if canImport(CommonCrypto)
        // macOS: AES-256-CBC via CommonCrypto
        guard ciphertext.count > kCCBlockSizeAES128 else { return nil }

        let iv = ciphertext.prefix(kCCBlockSizeAES128)
        let encrypted = ciphertext.dropFirst(kCCBlockSizeAES128)

        let bufferSize = encrypted.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted = 0

        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                encrypted.withUnsafeBytes { dataPtr in
                    CCCrypt(CCOperation(kCCDecrypt),
                           CCAlgorithm(kCCAlgorithmAES),
                           CCOptions(kCCOptionPKCS7Padding),
                           keyPtr.baseAddress, kCCKeySizeAES256,
                           ivPtr.baseAddress,
                           dataPtr.baseAddress, encrypted.count,
                           &buffer, bufferSize,
                           &numBytesDecrypted)
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return Data(buffer.prefix(numBytesDecrypted))
        #elseif canImport(Crypto)
        // Linux: AES-256-GCM via swift-crypto
        do {
            let symmetricKey = SymmetricKey(data: key)
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Storage

    private static func loadStore() -> [String: String] {
        // Try encrypted file first
        let encURL = URL(fileURLWithPath: storagePath)
        if let encData = try? Data(contentsOf: encURL),
           let decrypted = decrypt(encData),
           let dict = try? JSONDecoder().decode([String: String].self, from: decrypted) {
            return dict
        }
        // Fall back to legacy unencrypted file (auto-migrates on next save)
        let legacyURL = URL(fileURLWithPath: legacyStoragePath)
        if let data = try? Data(contentsOf: legacyURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            // Auto-migrate: save encrypted, delete plaintext
            saveStore(dict)
            try? FileManager.default.removeItem(at: legacyURL)
            TorboLog.info("Migrated plaintext keychain.json → encrypted keychain.enc", subsystem: "Keychain")
            return dict
        }
        return [:]
    }

    private static func saveStore(_ store: [String: String]) {
        let dirURL = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // Secure the directory (700 = owner rwx only)
        chmod(storageDir, 0o700)
        let url = URL(fileURLWithPath: storagePath)
        if let jsonData = try? JSONEncoder().encode(store),
           let encrypted = encrypt(jsonData) {
            try? encrypted.write(to: url, options: .atomic)
            // Secure the file (600 = owner rw only)
            chmod(storagePath, 0o600)
        }
    }

    // MARK: - Core Operations

    /// Store a value securely
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        var store = loadStore()
        if value.isEmpty {
            store.removeValue(forKey: key)
        } else {
            store[key] = value
        }
        saveStore(store)
        return true
    }

    /// Retrieve a value
    static func get(_ key: String) -> String? {
        loadStore()[key]
    }

    /// Delete a value
    @discardableResult
    static func delete(_ key: String) -> Bool {
        var store = loadStore()
        store.removeValue(forKey: key)
        saveStore(store)
        return true
    }

    /// Check if a key exists
    static func exists(_ key: String) -> Bool {
        get(key) != nil
    }

    // MARK: - Convenience: API Keys

    /// Store a cloud provider API key
    static func setAPIKey(_ value: String, for provider: CloudProvider) {
        set(value, for: "apikey.\(provider.keyName)")
    }

    /// Retrieve a cloud provider API key
    static func getAPIKey(for provider: CloudProvider) -> String {
        get("apikey.\(provider.keyName)") ?? ""
    }

    /// Get all stored API keys as a dictionary (for AppState compatibility)
    static func getAllAPIKeys() -> [String: String] {
        var result: [String: String] = [:]
        for provider in CloudProvider.allCases {
            let val = getAPIKey(for: provider)
            if !val.isEmpty {
                result[provider.keyName] = val
            }
        }
        return result
    }

    /// Save all API keys from a dictionary in a single load/save cycle.
    /// Previously called setAPIKey() per provider (5 × loadStore + saveStore).
    /// Now does one loadStore + one saveStore to avoid main-thread I/O storms.
    static func setAllAPIKeys(_ keys: [String: String]) {
        var store = loadStore()
        for provider in CloudProvider.allCases {
            let fullKey = "apikey.\(provider.keyName)"
            let val = keys[provider.keyName] ?? ""
            if val.isEmpty {
                store.removeValue(forKey: fullKey)
            } else {
                store[fullKey] = val
            }
        }
        saveStore(store)
    }

    // MARK: - Convenience: Server Token

    private static let serverTokenKey = "server.token"

    /// Get or generate the server bearer token
    static var serverToken: String {
        get {
            if let existing = get(serverTokenKey), !existing.isEmpty {
                return existing
            }
            let token = AppConfig.generateToken()
            set(token, for: serverTokenKey)
            // Record creation date for rotation tracking
            if get(serverTokenCreatedKey) == nil {
                set(ISO8601DateFormatter().string(from: Date()), for: serverTokenCreatedKey)
            }
            return token
        }
        set {
            set(newValue, for: serverTokenKey)
        }
    }

    /// Regenerate the server token
    static func regenerateServerToken() -> String {
        let token = AppConfig.generateToken()
        set(token, for: serverTokenKey)
        set(ISO8601DateFormatter().string(from: Date()), for: serverTokenCreatedKey)
        return token
    }

    /// M6: Track when the server token was created/last rotated
    private static let serverTokenCreatedKey = "server.token.created"

    static var serverTokenCreatedDate: Date? {
        guard let str = get(serverTokenCreatedKey) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    /// Days since the server token was last rotated (nil if unknown)
    static var tokenAgeDays: Int? {
        guard let created = serverTokenCreatedDate else { return nil }
        return Calendar.current.dateComponents([.day], from: created, to: Date()).day
    }

    // MARK: - Convenience: Telegram

    private static let telegramTokenKey = "telegram.botToken"

    static var telegramBotToken: String {
        get { get(telegramTokenKey) ?? "" }
        set { set(newValue, for: telegramTokenKey) }
    }

    // MARK: - Convenience: User Account

    private static let userAccountKey = "user.account"

    /// Store the authenticated user account securely (encrypted at rest)
    static func saveUserAccount(_ account: UserAccount) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(account) {
            set(data.base64EncodedString(), for: userAccountKey)
        }
    }

    /// Load the authenticated user account from encrypted store
    static func loadUserAccount() -> UserAccount? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let b64 = get(userAccountKey),
              let data = Data(base64Encoded: b64),
              let account = try? decoder.decode(UserAccount.self, from: data) else {
            return nil
        }
        return account
    }

    /// Clear the user account association
    static func clearUserAccount() {
        delete(userAccountKey)
    }

    // MARK: - Convenience: Paired Devices

    private static let pairedDevicesKey = "paired.devices"

    /// Store paired devices securely (encrypted at rest)
    static func savePairedDevices(_ devices: [PairedDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            set(data.base64EncodedString(), for: pairedDevicesKey)
        }
    }

    /// Load paired devices from encrypted store
    static func loadPairedDevices() -> [PairedDevice] {
        guard let b64 = get(pairedDevicesKey),
              let data = Data(base64Encoded: b64),
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    /// Check if a bearer token belongs to a paired device (non-MainActor safe)
    static func isPairedDeviceToken(_ token: String) -> Bool {
        loadPairedDevices().contains(where: { $0.token == token })
    }

    /// Migrate paired devices from UserDefaults to encrypted store
    static func migratePairedDevicesFromUserDefaults() {
        let defaults = UserDefaults.standard
        let devicesKey = "torbo_paired_devices"
        guard let data = defaults.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: data),
              !devices.isEmpty else { return }
        // Only migrate if not already in encrypted store
        if loadPairedDevices().isEmpty {
            savePairedDevices(devices)
            TorboLog.info("Migrated \(devices.count) paired device(s) to encrypted store", subsystem: "Keychain")
        }
        // Remove from UserDefaults
        defaults.removeObject(forKey: devicesKey)
    }

    // MARK: - One-time migration from macOS Keychain to file store

    /// Reads any remaining items from macOS Keychain, writes them to the file store,
    /// then deletes the old Keychain items. After this, Keychain is never touched again.
    static func migrateFromKeychainToFileStore() {
        #if canImport(Security)
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "torbo_migrated_to_filestore") else { return }

        let keysToMigrate = [
            serverTokenKey,
            "apikey.ANTHROPIC_API_KEY",
            "apikey.OPENAI_API_KEY",
            "apikey.XAI_API_KEY",
            "apikey.GOOGLE_API_KEY",
            "apikey.ELEVENLABS_API_KEY",
            telegramTokenKey,
        ]

        var migrated = 0
        for key in keysToMigrate {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            // If user denied, abort — don't keep prompting. Try again next launch.
            if status == errSecUserCanceled || status == errSecAuthFailed
                || status == errSecInteractionNotAllowed {
                TorboLog.warn("User denied access, aborting migration", subsystem: "Keychain")
                return
            }

            if status == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                // Write to file store (only if not already there)
                if get(key) == nil || get(key)?.isEmpty == true {
                    set(value, for: key)
                    migrated += 1
                }
            }
        }

        // Clean up old Keychain items
        for key in keysToMigrate {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        if migrated > 0 {
            TorboLog.info("Migrated \(migrated) item(s) to file-based storage", subsystem: "Keychain")
        }

        defaults.set(true, forKey: "torbo_migrated_to_filestore")
        #endif
    }

    // MARK: - Migration from UserDefaults

    /// One-time migration of secrets from UserDefaults to secure storage
    static func migrateFromUserDefaults() {
        let defaults = UserDefaults.standard
        var migrated = false

        // Migrate server token
        if let oldToken = defaults.string(forKey: "torboServerToken"), !oldToken.isEmpty {
            if get(serverTokenKey) == nil {
                set(oldToken, for: serverTokenKey)
                migrated = true
            }
            defaults.removeObject(forKey: "torboServerToken")
        }

        // Migrate API keys
        if let oldKeys = defaults.dictionary(forKey: "torboCloudAPIKeys") as? [String: String] {
            for (key, value) in oldKeys where !value.isEmpty {
                if get("apikey.\(key)") == nil {
                    set(value, for: "apikey.\(key)")
                    migrated = true
                }
            }
            defaults.removeObject(forKey: "torboCloudAPIKeys")
        }

        // Migrate Telegram bot token
        if let data = defaults.data(forKey: "torboTelegramConfig"),
           let config = try? JSONDecoder().decode(TelegramConfig.self, from: data),
           !config.botToken.isEmpty {
            if get(telegramTokenKey) == nil {
                set(config.botToken, for: telegramTokenKey)
                migrated = true
            }
            // Re-save config without the token in UserDefaults
            var cleaned = config
            cleaned.botToken = ""
            if let cleanData = try? JSONEncoder().encode(cleaned) {
                defaults.set(cleanData, forKey: "torboTelegramConfig")
            }
        }

        if migrated {
            TorboLog.info("Migrated secrets from UserDefaults to file store", subsystem: "Keychain")
        }
    }
}
