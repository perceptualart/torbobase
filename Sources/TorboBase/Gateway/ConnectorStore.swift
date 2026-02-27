// ConnectorStore.swift — Persistence layer for connector enabled state + config values
// Torbo Base

import Foundation

actor ConnectorStore {
    static let shared = ConnectorStore()

    // MARK: - Persisted State

    private struct PersistedState: Codable {
        var enabledConnectors: Set<String> = []
        var configValues: [String: [String: String]] = [:]  // connectorID → { fieldID: value } (non-secret only)
    }

    private var state = PersistedState()
    private let configPath: String

    private init() {
        configPath = PlatformPaths.dataDir + "/connectors.json"
        loadFromDisk()
    }

    // MARK: - Enabled State

    func isEnabled(_ connectorID: String) -> Bool {
        state.enabledConnectors.contains(connectorID)
    }

    func allEnabled() -> Set<String> {
        state.enabledConnectors
    }

    func enable(_ connectorID: String) {
        state.enabledConnectors.insert(connectorID)
        persist()
    }

    func disable(_ connectorID: String) {
        state.enabledConnectors.remove(connectorID)
        persist()
    }

    func setEnabled(_ connectorID: String, _ enabled: Bool) {
        if enabled {
            enable(connectorID)
        } else {
            disable(connectorID)
        }
    }

    // MARK: - Config Values

    func setConfig(_ connectorID: String, key: String, value: String) {
        guard let connector = ConnectorCatalog.connector(connectorID) else { return }
        let field = connector.configFields.first { $0.id == key }

        if let field = field, field.isSecret {
            // Store secrets in KeychainManager
            let keychainKey = "connector.\(connectorID).\(key)"
            _ = KeychainManager.set(value, for: keychainKey)
        } else {
            // Store non-secret values in JSON
            var connectorConfig = state.configValues[connectorID] ?? [:]
            connectorConfig[key] = value
            state.configValues[connectorID] = connectorConfig
            persist()
        }
    }

    func getConfig(_ connectorID: String, key: String) -> String? {
        guard let connector = ConnectorCatalog.connector(connectorID) else { return nil }
        let field = connector.configFields.first { $0.id == key }

        if let field = field, field.isSecret {
            let keychainKey = "connector.\(connectorID).\(key)"
            return KeychainManager.get(keychainKey)
        } else {
            return state.configValues[connectorID]?[key]
        }
    }

    func getAllConfig(_ connectorID: String) -> [String: String] {
        guard let connector = ConnectorCatalog.connector(connectorID) else { return [:] }
        var result: [String: String] = [:]
        for field in connector.configFields {
            if let value = getConfig(connectorID, key: field.id) {
                result[field.id] = value
            }
        }
        return result
    }

    func clearConfig(_ connectorID: String) {
        guard let connector = ConnectorCatalog.connector(connectorID) else { return }
        // Clear secrets from keychain
        for field in connector.configFields where field.isSecret {
            let keychainKey = "connector.\(connectorID).\(field.id)"
            _ = KeychainManager.delete(keychainKey)
        }
        // Clear non-secret config
        state.configValues.removeValue(forKey: connectorID)
        persist()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: configPath) else { return }
        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            TorboLog.error("Failed to load connectors.json: \(error)", subsystem: "Connectors")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL(fileURLWithPath: configPath))
        } catch {
            TorboLog.error("Failed to save connectors.json: \(error)", subsystem: "Connectors")
        }
    }
}
