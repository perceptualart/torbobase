// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — HomeKit Ambient Intelligence Types
import Foundation

enum HomeKitDeviceType: String, Codable, Sendable {
    case light, lock, thermostat, sensor, generic
}

struct HomeKitDeviceState: Codable, Sendable {
    let id: String
    let name: String
    let type: HomeKitDeviceType
    let reachable: Bool
    let isOn: Bool?
    let isLocked: Bool?
    let currentTemp: Double?
    let targetTemp: Double?
    let mode: String?
}

struct HomeKitStateUpdate: Codable, Sendable {
    let type: String
    let devices: [HomeKitDeviceState]
    let activeScenes: [String]
    let timestamp: Double
}

struct AmbientAlert: Codable, Sendable, Identifiable {
    let id: String
    let type: String
    let priority: Int
    let message: String
    let timestamp: Double
    let agent: String
    var dismissed: Bool = false
    enum CodingKeys: String, CodingKey {
        case id, type, priority, message, timestamp, agent, dismissed
    }
}

struct AmbientConfig: Codable, Sendable {
    var lightsOutHour: Int = 23
    var lockCheckHour: Int = 0
    var tempLowF: Double = 60.0
    var tempHighF: Double = 82.0
    var offlineThresholdMinutes: Int = 15
    var alertCooldownMinutes: Int = 30
    static let `default` = AmbientConfig()
}
