// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — HomeKit Ambient Intelligence Monitor

import Foundation

/// Polls HomeKitSOCReceiver state and generates alerts for:
/// - LIGHTS_LEFT_ON: Lights on past lights-out hour
/// - LOCK_UNLOCKED: Doors unlocked past lock-check hour
/// - HVAC_ANOMALY: Temperature outside configured range
/// - DEVICE_OFFLINE: Device unreachable beyond threshold
actor HomeKitMonitor {
    static let shared = HomeKitMonitor()
    private let pollInterval: TimeInterval = 300 // 5 minutes
    private var config = AmbientConfig.default
    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private let agentID = "CC-AMBIENT-1"

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await AmbientAlertManager.shared.initialize()
        loadConfig()
        pollTask = Task { [weak self] in
            while let s = self, await s.getIsRunning() {
                await s.runMonitorCycle()
                try? await Task.sleep(nanoseconds: UInt64(300 * 1_000_000_000))
            }
        }
        TorboLog.info("HomeKit monitor started (polling every \(Int(pollInterval))s)", subsystem: "HomeKit")
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        TorboLog.info("HomeKit monitor stopped", subsystem: "HomeKit")
    }

    func getIsRunning() -> Bool { isRunning }

    func updateConfig(_ newConfig: AmbientConfig) {
        config = newConfig
        persistConfig()
    }

    func getConfig() -> AmbientConfig { config }

    // MARK: - Monitor Cycle

    private func runMonitorCycle() async {
        #if os(macOS)
        let state = await HomeKitSOCReceiver.shared.latestState
        guard let update = state, !update.devices.isEmpty else { return }
        let devices = update.devices

        await checkLightsLeftOn(devices)
        await checkLockState(devices)
        await checkHVACAnomaly(devices)
        await checkDeviceOffline()
        #endif
    }

    // MARK: - Monitors

    private func checkLightsLeftOn(_ devices: [HomeKitDeviceState]) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lightsOutHour || hour < 5 else { return }

        for device in devices where device.type == .light {
            if device.isOn == true {
                let msg = "\(device.name) is still on after \(config.lightsOutHour):00"
                let dup = await AmbientAlertManager.shared.isDuplicate(
                    type: "LIGHTS_LEFT_ON", deviceID: device.id,
                    cooldownMinutes: config.alertCooldownMinutes)
                if !dup {
                    let alert = AmbientAlert(
                        id: UUID().uuidString, type: "LIGHTS_LEFT_ON", priority: 1,
                        message: msg, timestamp: Date().timeIntervalSince1970, agent: agentID)
                    await AmbientAlertManager.shared.addAlert(alert)
                }
            }
        }
    }

    private func checkLockState(_ devices: [HomeKitDeviceState]) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lockCheckHour || hour < 5 else { return }

        for device in devices where device.type == .lock {
            if device.isLocked == false {
                let msg = "\(device.name) is unlocked"
                let dup = await AmbientAlertManager.shared.isDuplicate(
                    type: "LOCK_UNLOCKED", deviceID: device.id,
                    cooldownMinutes: config.alertCooldownMinutes)
                if !dup {
                    let alert = AmbientAlert(
                        id: UUID().uuidString, type: "LOCK_UNLOCKED", priority: 2,
                        message: msg, timestamp: Date().timeIntervalSince1970, agent: agentID)
                    await AmbientAlertManager.shared.addAlert(alert)
                }
            }
        }
    }

    private func checkHVACAnomaly(_ devices: [HomeKitDeviceState]) async {
        for device in devices where device.type == .thermostat {
            if let temp = device.currentTemp {
                if temp < config.tempLowF {
                    let msg = "\(device.name) reads \(String(format: "%.1f", temp))\u{00B0}F (below \(String(format: "%.0f", config.tempLowF))\u{00B0}F)"
                    let dup = await AmbientAlertManager.shared.isDuplicate(
                        type: "HVAC_ANOMALY", deviceID: device.id,
                        cooldownMinutes: config.alertCooldownMinutes)
                    if !dup {
                        let alert = AmbientAlert(
                            id: UUID().uuidString, type: "HVAC_ANOMALY", priority: 2,
                            message: msg, timestamp: Date().timeIntervalSince1970, agent: agentID)
                        await AmbientAlertManager.shared.addAlert(alert)
                    }
                } else if temp > config.tempHighF {
                    let msg = "\(device.name) reads \(String(format: "%.1f", temp))\u{00B0}F (above \(String(format: "%.0f", config.tempHighF))\u{00B0}F)"
                    let dup = await AmbientAlertManager.shared.isDuplicate(
                        type: "HVAC_ANOMALY", deviceID: device.id,
                        cooldownMinutes: config.alertCooldownMinutes)
                    if !dup {
                        let alert = AmbientAlert(
                            id: UUID().uuidString, type: "HVAC_ANOMALY", priority: 2,
                            message: msg, timestamp: Date().timeIntervalSince1970, agent: agentID)
                        await AmbientAlertManager.shared.addAlert(alert)
                    }
                }
            }
        }
    }

    private func checkDeviceOffline() async {
        #if os(macOS)
        let lastSeen = await HomeKitSOCReceiver.shared.deviceLastSeen
        let threshold = TimeInterval(config.offlineThresholdMinutes * 60)
        let now = Date()

        for (deviceID, lastDate) in lastSeen {
            if now.timeIntervalSince(lastDate) > threshold {
                let msg = "Device \(deviceID) offline for >\(config.offlineThresholdMinutes) minutes"
                let dup = await AmbientAlertManager.shared.isDuplicate(
                    type: "DEVICE_OFFLINE", deviceID: deviceID,
                    cooldownMinutes: config.alertCooldownMinutes)
                if !dup {
                    let alert = AmbientAlert(
                        id: UUID().uuidString, type: "DEVICE_OFFLINE", priority: 1,
                        message: msg, timestamp: Date().timeIntervalSince1970, agent: agentID)
                    await AmbientAlertManager.shared.addAlert(alert)
                }
            }
        }
        #endif
    }

    // MARK: - Config Persistence

    private var configFilePath: String {
        PlatformPaths.dataDir + "/homekit_monitor_config.json"
    }

    private func persistConfig() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        do {
            let data = try enc.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            TorboLog.error("Failed to persist HomeKit monitor config: \(error)", subsystem: "HomeKit")
        }
    }

    private func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configFilePath) else { return }
        do {
            config = try JSONDecoder().decode(AmbientConfig.self, from: data)
            TorboLog.info("Loaded HomeKit monitor config", subsystem: "HomeKit")
        } catch {
            TorboLog.warn("Failed to load HomeKit monitor config: \(error)", subsystem: "HomeKit")
        }
    }
}
