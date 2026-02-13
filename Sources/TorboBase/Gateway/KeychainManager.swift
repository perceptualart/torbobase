// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Secure file-based storage for API keys and tokens
import Foundation
#if canImport(Security)
import Security
#endif

/// Secure key-value storage for sensitive data.
/// Uses file-based storage (~/.config/torbobase/keychain.json) on all platforms.
/// File permissions are set to owner-only (600) for security.
enum KeychainManager {

    private static let service = "ai.torbo.base"

    // MARK: - File-based storage (all platforms)

    private static var storageDir: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.config/torbobase"
    }

    private static var storagePath: String {
        storageDir + "/keychain.json"
    }

    private static func loadStore() -> [String: String] {
        let url = URL(fileURLWithPath: storagePath)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveStore(_ store: [String: String]) {
        let dirURL = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        // Secure the directory (700 = owner rwx only)
        chmod(storageDir, 0o700)
        let url = URL(fileURLWithPath: storagePath)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: url, options: .atomic)
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

    /// Save all API keys from a dictionary
    static func setAllAPIKeys(_ keys: [String: String]) {
        for provider in CloudProvider.allCases {
            let val = keys[provider.keyName] ?? ""
            setAPIKey(val, for: provider)
        }
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
        return token
    }

    // MARK: - Convenience: Telegram

    private static let telegramTokenKey = "telegram.botToken"

    static var telegramBotToken: String {
        get { get(telegramTokenKey) ?? "" }
        set { set(newValue, for: telegramTokenKey) }
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
                print("[Keychain→File] User denied access, aborting migration")
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
            print("[Keychain→File] Migrated \(migrated) item(s) to file-based storage")
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
            print("[KeychainManager] Migrated secrets from UserDefaults to file store")
        }
    }
}
