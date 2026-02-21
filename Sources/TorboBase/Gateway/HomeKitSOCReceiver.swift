// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — HomeKit SOC Sync Receiver
import Foundation
#if canImport(Network)
import Network
#endif

actor HomeKitSOCReceiver {
    static let shared = HomeKitSOCReceiver()
    static let socPort: UInt16 = 18790

    private(set) var latestState: HomeKitStateUpdate?
    private(set) var deviceLastSeen: [String: Date] = [:]
    private var isRunning = false

    #if canImport(Network)
    private var listener: NWListener?
    #endif

    func start() {
        guard !isRunning else { return }
        isRunning = true
        #if canImport(Network)
        startNWListener()
        #else
        TorboLog.warn("SOC receiver requires macOS (Network.framework)", subsystem: "SOC")
        #endif
    }

    func stop() {
        isRunning = false
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #endif
        TorboLog.info("SOC receiver stopped", subsystem: "SOC")
    }

    func handleStateUpdate(_ update: HomeKitStateUpdate) {
        let previousState = latestState
        latestState = update
        let now = Date()
        for device in update.devices {
            if device.reachable { deviceLastSeen[device.id] = now }
            if deviceLastSeen[device.id] == nil { deviceLastSeen[device.id] = now }
        }
        TorboLog.debug("HomeKit state: \(update.devices.count) devices, \(update.activeScenes.count) scenes", subsystem: "SOC")

        // Publish state update event
        let deviceCount = update.devices.count
        let sceneCount = update.activeScenes.count
        Task {
            await EventBus.shared.publish("ambient.homekit.state_update",
                payload: ["device_count": "\(deviceCount)", "scene_count": "\(sceneCount)"],
                source: "HomeKit")
        }

        // Detect anomalies: devices that went offline since last update
        if let prev = previousState {
            let prevReachable = Set(prev.devices.filter { $0.reachable }.map { $0.id })
            let nowUnreachable = update.devices.filter { !$0.reachable && prevReachable.contains($0.id) }
            for device in nowUnreachable {
                let devID = device.id
                let devName = device.name
                Task {
                    await EventBus.shared.publish("ambient.homekit.anomaly",
                        payload: ["device_id": devID, "device_name": devName, "anomaly": "device_went_offline"],
                        source: "HomeKit")
                }
            }
        }
    }

    func offlineDuration(deviceID: String) -> TimeInterval? {
        guard let state = latestState,
              let device = state.devices.first(where: { $0.id == deviceID }),
              !device.reachable,
              let lastSeen = deviceLastSeen[deviceID] else { return nil }
        return Date().timeIntervalSince(lastSeen)
    }

    #if canImport(Network)
    private func startNWListener() {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: Self.socPort) else {
            TorboLog.error("Invalid SOC port \(Self.socPort)", subsystem: "SOC")
            return
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: nwPort)
        do {
            let nwListener = try NWListener(using: params)
            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    TorboLog.info("SOC receiver listening on port \(Self.socPort)", subsystem: "SOC")
                case .failed(let error):
                    TorboLog.error("SOC listener failed: \(error)", subsystem: "SOC")
                default: break
                }
            }
            nwListener.newConnectionHandler = { connection in
                self.handleConnection(connection)
            }
            nwListener.start(queue: .global(qos: .utility))
            self.listener = nwListener
        } catch {
            TorboLog.error("Failed to start SOC listener: \(error)", subsystem: "SOC")
        }
    }

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data = data {
                Task { await self.processSOCMessage(data, connection: connection) }
            } else {
                connection.cancel()
            }
        }
    }

    private func processSOCMessage(_ data: Data, connection: NWConnection) {
        defer {
            let ack = Data("{\"status\":\"ok\"}".utf8)
            connection.send(content: ack, completion: .contentProcessed { _ in connection.cancel() })
        }
        let payload: Data
        if let str = String(data: data, encoding: .utf8),
           (str.hasPrefix("POST ") || str.hasPrefix("PUT ")),
           let range = data.range(of: Data("\r\n\r\n".utf8)),
           range.upperBound < data.count {
            payload = Data(data[range.upperBound...])
        } else {
            payload = data
        }
        guard !payload.isEmpty else { return }
        do {
            let update = try JSONDecoder().decode(HomeKitStateUpdate.self, from: payload)
            guard update.type == "HOMEKIT_STATE_UPDATE" else {
                TorboLog.warn("Unknown SOC message type: \(update.type)", subsystem: "SOC")
                return
            }
            handleStateUpdate(update)
        } catch {
            TorboLog.error("Failed to parse SOC message: \(error)", subsystem: "SOC")
        }
    }
    #endif
}
