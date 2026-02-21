// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Ambient HomeKit Monitor
// Polls HomeKit state every 5 minutes and generates alerts for anomalies.
import Foundation

actor AmbientMonitor {
    static let shared = AmbientMonitor()
    private let pollInterval: TimeInterval = 300
    private var config = AmbientConfig.default
    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private let agentID = "CC-AMBIENT-1"

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await AmbientAlertManager.shared.initialize()
        pollTask = Task { [weak self] in
            while let self = self, await self.isRunning {
                await self.runMonitorCycle()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
        TorboLog.info("Ambient monitor started (polling every \(Int(pollInterval))s)", subsystem: "Ambient")
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        TorboLog.info("Ambient monitor stopped", subsystem: "Ambient")
    }

    func updateConfig(_ newConfig: AmbientConfig) {
        config = newConfig
    }

    func getConfig() -> AmbientConfig { config }

    private func runMonitorCycle() async {
        guard let state = await HomeKitSOCReceiver.shared.latestState else { return }
        await checkLightsLeftOn(state: state)
        await checkLockState(state: state)
        await checkHVACAnomaly(state: state)
        await checkDeviceOffline(state: state)
        await AmbientAlertManager.shared.pruneOlderThan(hours: 72)
    }

    private func checkLightsLeftOn(state: HomeKitStateUpdate) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lightsOutHour || hour < 5 else { return }
        let hasGoodNight = state.activeScenes.contains { $0.localizedCaseInsensitiveContains("good night") }
        guard !hasGoodNight else { return }
        let lightsOn = state.devices.filter { $0.type == .light && $0.isOn == true && $0.reachable }
        for light in lightsOn {
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "LIGHTS_LEFT_ON", deviceID: light.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "LIGHTS_LEFT_ON", priority: 2,
                message: "\(light.name) is still on after \(config.lightsOutHour):00",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkLockState(state: HomeKitStateUpdate) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= config.lockCheckHour && hour < 6 else { return }
        let unlockedLocks = state.devices.filter { $0.type == .lock && $0.isLocked == false && $0.reachable }
        for lock in unlockedLocks {
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "LOCK_UNLOCKED", deviceID: lock.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "LOCK_UNLOCKED", priority: 1,
                message: "\(lock.name) is unlocked after midnight",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkHVACAnomaly(state: HomeKitStateUpdate) async {
        let thermostats = state.devices.filter { $0.type == .thermostat && $0.reachable }
        for device in thermostats {
            guard let temp = device.currentTemp else { continue }
            let outOfRange = temp < config.tempLowF || temp > config.tempHighF
            guard outOfRange else { continue }
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "HVAC_ANOMALY", deviceID: device.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let direction = temp < config.tempLowF ? "below \(Int(config.tempLowF))°F" : "above \(Int(config.tempHighF))°F"
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "HVAC_ANOMALY", priority: 2,
                message: "\(device.name) reads \(Int(temp))°F — \(direction)",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }

    private func checkDeviceOffline(state: HomeKitStateUpdate) async {
        let thresholdSeconds = Double(config.offlineThresholdMinutes * 60)
        for device in state.devices where !device.reachable {
            guard let duration = await HomeKitSOCReceiver.shared.offlineDuration(deviceID: device.id),
                  duration >= thresholdSeconds else { continue }
            let isDup = await AmbientAlertManager.shared.isDuplicate(
                type: "DEVICE_OFFLINE", deviceID: device.id, cooldownMinutes: config.alertCooldownMinutes)
            guard !isDup else { continue }
            let mins = Int(duration / 60)
            let alert = AmbientAlert(
                id: UUID().uuidString, type: "DEVICE_OFFLINE", priority: 3,
                message: "\(device.name) has been offline for \(mins) minutes",
                timestamp: Date().timeIntervalSince1970, agent: agentID)
            await AmbientAlertManager.shared.addAlert(alert)
        }
    }
}
