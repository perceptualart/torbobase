// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Secure Keychain storage for API keys and tokens
import Foundation
#if canImport(Security)
import Security
#endif

/// Thread-safe Keychain wrapper for storing sensitive data.
/// All API keys and tokens go here — never in UserDefaults.
enum KeychainManager {

    private static let service = "ai.torbo.base"

#if canImport(Security)

    // MARK: - Core Operations (macOS/iOS Keychain)

    /// Store a value securely in Keychain
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Don't store empty strings
        guard !value.isEmpty else { return true }

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] Failed to store '\(key)': \(status)")
        }
        return status == errSecSuccess
    }

    /// Retrieve a value from Keychain
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from Keychain
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

#else

    // MARK: - Core Operations (Linux fallback: file-based storage)
    // Store keys in ~/.config/torbobase/keychain.json
    // Simple JSON file with key-value pairs — not truly encrypted but functional for Linux servers

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
        let url = URL(fileURLWithPath: storagePath)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Store a value in the file-based keychain
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

    /// Retrieve a value from the file-based keychain
    static func get(_ key: String) -> String? {
        let store = loadStore()
        return store[key]
    }

    /// Delete a value from the file-based keychain
    @discardableResult
    static func delete(_ key: String) -> Bool {
        var store = loadStore()
        store.removeValue(forKey: key)
        saveStore(store)
        return true
    }

#endif

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

    // MARK: - Migration from UserDefaults

    /// One-time migration of secrets from UserDefaults to Keychain
    static func migrateFromUserDefaults() {
        #if !os(Linux)
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
            cleaned.botToken = "" // Token now in Keychain
            if let cleanData = try? JSONEncoder().encode(cleaned) {
                defaults.set(cleanData, forKey: "torboTelegramConfig")
            }
        }

        if migrated {
            print("[Keychain] Migrated secrets from UserDefaults to Keychain")
        }
        #else
        print("[Keychain] Migration from UserDefaults not available on Linux")
        #endif
    }
}
