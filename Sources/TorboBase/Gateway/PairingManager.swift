// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Thread-Safe Token Store
// GatewayServer is an actor and can't call @MainActor PairingManager synchronously.
// This reads paired device tokens from encrypted KeychainManager store.
enum PairedDeviceStore {
    /// Token expiry: 30 days without activity
    static let tokenExpiryInterval: TimeInterval = 30 * 24 * 60 * 60

    static func isAuthorized(token: String) -> Bool {
        let devices = KeychainManager.loadPairedDevices()
        guard let device = devices.first(where: { $0.token == token }) else { return false }
        // Check staleness — reject tokens unused for 30+ days
        let referenceDate = device.lastSeen ?? device.pairedAt
        let age = Date().timeIntervalSince(referenceDate)
        if age > tokenExpiryInterval {
            TorboLog.warn("Rejected expired device token for '\(device.name)' (idle \(Int(age / 86400))d)", subsystem: "Pairing")
            return false
        }
        return true
    }

    /// Resolve device ID from a Bearer token (for sync tracking)
    static func deviceID(forToken token: String) -> String? {
        let devices = KeychainManager.loadPairedDevices()
        return devices.first(where: { $0.token == token })?.id
    }
}

// MARK: - User Account

struct UserAccount: Codable {
    let userID: String          // From backend (e.g. "usr_abc123")
    let email: String           // From backend
    let pairedAt: Date          // When this Base was associated
    var lastValidated: Date     // Last time token was validated with backend
}

// MARK: - Paired Device

struct PairedDevice: Codable, Identifiable {
    let id: String          // UUID for this device
    let name: String        // e.g. "User's iPhone"
    let token: String       // Bearer token issued to this device
    let pairedAt: Date
    var lastSeen: Date?
    var userID: String?     // Set when paired via /pair/auth (nil for code/auto-pair)

    var isRecent: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) < 300 // 5 min
    }
}

// MARK: - Pairing Manager

#if canImport(Combine)
typealias _PairingManagerBase = ObservableObject
#else
protocol _PairingManagerBase: AnyObject {}
#endif

@MainActor
final class PairingManager: _PairingManagerBase {
    static let shared = PairingManager()

    // Published state
    #if canImport(Combine)
    @Published var pairingCode: String = ""
    @Published var pairingActive: Bool = false
    @Published var pairedDevices: [PairedDevice] = []
    @Published var qrString: String = ""
    @Published var userAccount: UserAccount?
    #else
    var pairingCode: String = ""
    var pairingActive: Bool = false
    var pairedDevices: [PairedDevice] = []
    var qrString: String = ""
    var userAccount: UserAccount?
    #endif

    // Bonjour (macOS only — NetService not available on Linux)
    #if os(macOS)
    private var netService: NetService?
    #endif
    private let bonjourType = "_torbo-base._tcp."

    // Code expiration
    private var codeTimer: Timer?
    private static let codeLifetime: TimeInterval = 300 // 5 minutes

    // Persistence — uses encrypted KeychainManager store

    private init() {
        migrateFromORBIfNeeded()
        migrateFromUserDefaults()
        loadDevices()
        loadUserAccount()
    }

    /// One-time migration: copy paired devices from old "orb_paired_devices" key.
    /// Bundle ID changed (ai.orb.base → ai.torbo.base) so old data is in a different domain.
    private func migrateFromORBIfNeeded() {
        // Check if old ORB data exists in legacy suites
        let oldData = UserDefaults(suiteName: "ai.orb.base")?.data(forKey: "orb_paired_devices")
                   ?? UserDefaults(suiteName: "ORBBase")?.data(forKey: "orb_paired_devices")
        guard let oldData else { return }
        // If no devices in encrypted store yet, migrate from old ORB data
        if KeychainManager.loadPairedDevices().isEmpty,
           let devices = try? JSONDecoder().decode([PairedDevice].self, from: oldData) {
            KeychainManager.savePairedDevices(devices)
            TorboLog.info("Migrated \(devices.count) paired devices from ORB → encrypted store", subsystem: "Pairing")
        }
        // Clean up old suites
        UserDefaults(suiteName: "ai.orb.base")?.removeObject(forKey: "orb_paired_devices")
        UserDefaults(suiteName: "ORBBase")?.removeObject(forKey: "orb_paired_devices")
    }

    /// Migrate devices from plaintext UserDefaults to encrypted KeychainManager
    private func migrateFromUserDefaults() {
        KeychainManager.migratePairedDevicesFromUserDefaults()
    }

    // MARK: - Bonjour Publishing

    func startAdvertising(port: UInt16) {
        #if os(macOS)
        let machineName = Host.current().localizedName ?? "Mac"
        let serviceName = "Torbo Base (\(machineName))"

        netService = NetService(
            domain: "",        // default domain
            type: bonjourType,
            name: serviceName,
            port: Int32(port)
        )

        // TXT record — minimal broadcast (no version or machine name for security)
        let txt: [String: Data] = [
            "platform": Data("macos".utf8)
        ]
        netService?.setTXTRecord(NetService.data(fromTXTRecord: txt))
        netService?.publish()
        TorboLog.info("Bonjour: advertising \(serviceName) on port \(port)", subsystem: "Pairing")
        #else
        TorboLog.info("Bonjour not available on this platform — skipping advertising", subsystem: "Pairing")
        #endif
    }

    func stopAdvertising() {
        #if os(macOS)
        netService?.stop()
        netService = nil
        TorboLog.info("Bonjour: stopped advertising", subsystem: "Pairing")
        #endif
    }

    // MARK: - Code Generation

    /// Generate a fresh 6-character pairing code and QR string
    func generateCode(host: String, port: UInt16) {
        // Random 6-char alphanumeric (uppercase)
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // No I/O/0/1 for clarity
        pairingCode = String((0..<6).map { _ in chars.randomElement()! })
        pairingActive = true

        // QR payload: torbo://pair?host=X&port=X&code=X
        qrString = "torbo://pair?host=\(host)&port=\(port)&code=\(pairingCode)"

        TorboLog.info("Code generated: \(pairingCode) — expires in \(Self.codeLifetime)s", subsystem: "Pairing")

        // Auto-expire
        codeTimer?.invalidate()
        codeTimer = Timer.scheduledTimer(withTimeInterval: Self.codeLifetime, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.expireCode()
            }
        }
    }

    /// Invalidate the current code
    func expireCode() {
        pairingCode = ""
        pairingActive = false
        qrString = ""
        codeTimer?.invalidate()
        codeTimer = nil
        TorboLog.info("Code expired", subsystem: "Pairing")
    }

    // MARK: - Pairing

    /// Validate a code and pair a device. Returns (token, deviceId) on success.
    func pair(code: String, deviceName: String) -> (token: String, deviceId: String)? {
        guard pairingActive,
              !pairingCode.isEmpty,
              code.uppercased() == pairingCode else {
            TorboLog.warn("Code mismatch or expired", subsystem: "Pairing")
            return nil
        }

        // Generate permanent token for this device
        let token = generateToken()
        let deviceId = UUID().uuidString

        let device = PairedDevice(
            id: deviceId,
            name: deviceName,
            token: token,
            pairedAt: Date(),
            lastSeen: Date()
        )

        pairedDevices.append(device)
        saveDevices()

        // Expire the code (single-use)
        expireCode()

        TorboLog.info("Paired '\(deviceName)' → \(deviceId)", subsystem: "Pairing")
        return (token, deviceId)
    }

    /// Auto-pair a device without a code (for trusted networks like Tailscale).
    /// Creates a new paired device and returns its token + deviceId.
    func autoPair(deviceName: String) -> (token: String, deviceId: String) {
        let token = generateToken()
        let deviceId = UUID().uuidString

        let device = PairedDevice(
            id: deviceId,
            name: deviceName,
            token: token,
            pairedAt: Date(),
            lastSeen: Date()
        )

        pairedDevices.append(device)
        saveDevices()

        TorboLog.info("Auto-paired '\(deviceName)' → \(deviceId)", subsystem: "Pairing")
        return (token, deviceId)
    }

    /// Verify a token is valid. Updates lastSeen.
    func verifyToken(_ token: String) -> Bool {
        if let idx = pairedDevices.firstIndex(where: { $0.token == token }) {
            pairedDevices[idx].lastSeen = Date()
            saveDevices()
            return true
        }
        return false
    }

    /// Check if a Bearer token belongs to a paired device
    func isAuthorized(token: String) -> Bool {
        pairedDevices.contains(where: { $0.token == token })
    }

    /// Remove a paired device
    func unpair(deviceId: String) {
        pairedDevices.removeAll(where: { $0.id == deviceId })
        saveDevices()
        TorboLog.info("Removed device \(deviceId)", subsystem: "Pairing")
    }

    // MARK: - Authenticated Pairing

    /// Pair a device using a backend auth token. Validates with the backend,
    /// creates a paired device with the user's ID, and stores the user account.
    /// The auth token is validated once and never stored.
    func authPair(authToken: String, deviceName: String) async throws -> (token: String, deviceId: String, userID: String, email: String) {
        let result = try await AuthClient.shared.validate(token: authToken)

        let token = generateToken()
        let deviceId = UUID().uuidString

        let device = PairedDevice(
            id: deviceId,
            name: deviceName,
            token: token,
            pairedAt: Date(),
            lastSeen: Date(),
            userID: result.userID
        )

        pairedDevices.append(device)
        saveDevices()

        let account = UserAccount(
            userID: result.userID,
            email: result.email,
            pairedAt: Date(),
            lastValidated: Date()
        )
        userAccount = account
        saveUserAccount()

        TorboLog.info("Auth-paired '\(deviceName)' for user \(result.email) → \(deviceId)", subsystem: "Pairing")
        return (token, deviceId, result.userID, result.email)
    }

    /// Remove the user account association from this Base installation.
    /// Optionally removes all paired devices as well.
    func unpairUser(wipeData: Bool) {
        userAccount = nil
        KeychainManager.clearUserAccount()
        TorboLog.info("User account unlinked from this Base", subsystem: "Pairing")

        if wipeData {
            pairedDevices.removeAll()
            saveDevices()
            TorboLog.info("All paired devices removed (wipe_data)", subsystem: "Pairing")
        }
    }

    // MARK: - User Account Persistence

    private func loadUserAccount() {
        userAccount = KeychainManager.loadUserAccount()
        if let account = userAccount {
            TorboLog.info("Loaded user account: \(account.email)", subsystem: "Pairing")
        }
    }

    private func saveUserAccount() {
        guard let account = userAccount else { return }
        KeychainManager.saveUserAccount(account)
    }

    // MARK: - Token Generation

    private func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        #else
        // Linux: read from /dev/urandom
        if let fh = FileHandle(forReadingAtPath: "/dev/urandom") {
            let data = fh.readData(ofLength: 32)
            fh.closeFile()
            if data.count == 32 { bytes = Array(data) }
        }
        #endif
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Persistence (encrypted via KeychainManager)

    private func loadDevices() {
        let devices = KeychainManager.loadPairedDevices()
        guard !devices.isEmpty else { return }
        pairedDevices = devices
        TorboLog.info("Loaded \(devices.count) paired device(s) from encrypted store", subsystem: "Pairing")
    }

    private func saveDevices() {
        KeychainManager.savePairedDevices(pairedDevices)
    }
}
