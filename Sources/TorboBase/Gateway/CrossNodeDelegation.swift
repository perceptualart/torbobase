// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Cross-Node Task Delegation
// Enables Node A to delegate tasks to Node B based on skill availability,
// with Ed25519 signed requests and results flowing back to the originator.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Data Models

/// What a node can do — advertised to peers.
struct NodeCapabilities: Codable, Sendable {
    let nodeID: String
    let displayName: String
    let skillIDs: [String]
    let agentIDs: [String]
    let maxAccessLevel: Int
    let acceptsDelegation: Bool
    let currentLoad: Int
    let maxConcurrentDelegated: Int
    let updatedAt: String

    func toDict() -> [String: Any] {
        [
            "node_id": nodeID,
            "display_name": displayName,
            "skill_ids": skillIDs,
            "agent_ids": agentIDs,
            "max_access_level": maxAccessLevel,
            "accepts_delegation": acceptsDelegation,
            "current_load": currentLoad,
            "max_concurrent_delegated": maxConcurrentDelegated,
            "updated_at": updatedAt
        ]
    }
}

/// A task traveling between nodes.
struct DelegatedTask: Codable, Sendable {
    let id: String
    let originNodeID: String
    let originHost: String
    let originPort: Int
    let title: String
    let description: String
    let priority: Int
    let requiredSkillIDs: [String]
    let requiredAccessLevel: Int
    let timeoutSeconds: Int
    let signature: String
    let createdAt: String
    let context: String?

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "origin_node_id": originNodeID,
            "origin_host": originHost,
            "origin_port": originPort,
            "title": title,
            "description": description,
            "priority": priority,
            "required_skill_ids": requiredSkillIDs,
            "required_access_level": requiredAccessLevel,
            "timeout_seconds": timeoutSeconds,
            "signature": signature,
            "created_at": createdAt
        ]
        if let context { dict["context"] = context }
        return dict
    }
}

/// Result sent back to the originator.
struct DelegatedTaskResult: Codable, Sendable {
    let taskID: String
    let executorNodeID: String
    let status: String
    let result: String?
    let error: String?
    let executionTimeSeconds: Int
    let signature: String
    let completedAt: String

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "task_id": taskID,
            "executor_node_id": executorNodeID,
            "status": status,
            "execution_time_seconds": executionTimeSeconds,
            "signature": signature,
            "completed_at": completedAt
        ]
        if let result { dict["result"] = result }
        if let error { dict["error"] = error }
        return dict
    }
}

// MARK: - Internal Tracking

struct OutboundDelegation: Codable, Sendable {
    let taskID: String
    let targetNodeID: String
    let targetHost: String
    let targetPort: Int
    let sentAt: Date
    let timeoutSeconds: Int
    var localTaskID: String
}

struct InboundDelegation: Codable, Sendable {
    let taskID: String
    let originNodeID: String
    let originHost: String
    let originPort: Int
    let receivedAt: Date
    var localTaskID: String
}

// MARK: - Cross-Node Delegation Actor

actor CrossNodeDelegation {
    static let shared = CrossNodeDelegation()

    private var outboundTasks: [String: OutboundDelegation] = [:]
    private var inboundTasks: [String: InboundDelegation] = [:]
    private var peerCapabilities: [String: NodeCapabilities] = [:]
    private var capabilityCacheTime: [String: Date] = [:]
    private var watchdogTask: Task<Void, Never>?

    private let cacheLifetime: TimeInterval = 300 // 5 minutes
    private let maxConcurrentDelegated = 2
    private let defaultTimeoutSeconds = 300

    init() {
        let (loaded, inbound) = Self.loadStateSync()
        outboundTasks = loaded
        inboundTasks = inbound
        if !loaded.isEmpty || !inbound.isEmpty {
            TorboLog.info("Loaded \(loaded.count) outbound + \(inbound.count) inbound delegated tasks", subsystem: "Delegation")
        }
    }

    // MARK: - Outbound Delegation

    /// Find the best peer, send the task, track outbound. Returns task ID or throws.
    func delegateTask(
        title: String,
        description: String,
        priority: Int = 1,
        requiredSkillIDs: [String] = [],
        requiredAccessLevel: Int = 2,
        context: String? = nil
    ) async throws -> String {
        guard let identity = await SkillCommunityManager.shared.getIdentity() else {
            throw DelegationError.noIdentity
        }

        guard let peer = await findBestPeer(requiredSkillIDs: requiredSkillIDs, requiredAccessLevel: requiredAccessLevel) else {
            throw DelegationError.noPeerAvailable
        }

        let taskID = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let signPayload = "\(taskID)|\(title)|\(identity.nodeID)"
        let signature = SkillIntegrityVerifier.sign(string: signPayload)

        let port = await MainActor.run { Int(AppState.shared.serverPort) }

        // Determine our reachable host — prefer Tailscale IP, fall back to LAN
        let originHost = GatewayServer.detectTailscaleIP() ?? "127.0.0.1"

        let task = DelegatedTask(
            id: taskID,
            originNodeID: identity.nodeID,
            originHost: originHost,
            originPort: port,
            title: title,
            description: description,
            priority: priority,
            requiredSkillIDs: requiredSkillIDs,
            requiredAccessLevel: requiredAccessLevel,
            timeoutSeconds: defaultTimeoutSeconds,
            signature: signature,
            createdAt: now,
            context: context
        )

        // Look up peer connection info
        let peers = await SkillCommunityManager.shared.allPeers()
        guard let peerNode = peers.first(where: { $0.nodeID == peer.nodeID }) else {
            throw DelegationError.invalidPeerURL
        }

        try await sendTaskToPeer(task: task, host: peerNode.host, port: peerNode.port)

        // Create local AgentTask to track the delegation
        let agentIDs = await AgentConfigManager.shared.agentIDs
        let assignedTo = agentIDs.first ?? "sid"
        let localTask = await TaskQueue.shared.createTask(
            title: "[Delegated] \(title)",
            description: "Delegated to node \(peer.displayName) (\(peer.nodeID.prefix(8))). Awaiting result.",
            assignedTo: assignedTo,
            assignedBy: "delegation:\(identity.nodeID)",
            priority: TaskQueue.TaskPriority(rawValue: priority) ?? .normal
        )

        // Mark as in-progress immediately (it's running remotely)
        await TaskQueue.shared.markDelegatedOutbound(id: localTask.id, targetNodeID: peer.nodeID)

        outboundTasks[taskID] = OutboundDelegation(
            taskID: taskID,
            targetNodeID: peer.nodeID,
            targetHost: peerNode.host,
            targetPort: peerNode.port,
            sentAt: Date(),
            timeoutSeconds: defaultTimeoutSeconds,
            localTaskID: localTask.id
        )
        persistState()

        TorboLog.info("Delegated '\(title)' to \(peer.displayName) (\(peer.nodeID.prefix(8)))", subsystem: "Delegation")

        await EventBus.shared.publish("delegation.sent",
            payload: ["task_id": taskID, "target_node": peer.nodeID, "title": title],
            source: "CrossNodeDelegation")

        return taskID
    }

    /// Find the best peer that has the required skills and capacity.
    func findBestPeer(requiredSkillIDs: [String], requiredAccessLevel: Int) async -> NodeCapabilities? {
        // Refresh stale caches
        let staleNodes = capabilityCacheTime.filter { Date().timeIntervalSince($0.value) > cacheLifetime }.map(\.key)
        if !staleNodes.isEmpty || peerCapabilities.isEmpty {
            await refreshPeerCapabilities()
        }

        let candidates = peerCapabilities.values.filter { cap in
            guard cap.acceptsDelegation else { return false }
            guard cap.maxAccessLevel >= requiredAccessLevel else { return false }
            guard cap.currentLoad < cap.maxConcurrentDelegated else { return false }
            // Check required skills
            if !requiredSkillIDs.isEmpty {
                let hasAll = requiredSkillIDs.allSatisfy { cap.skillIDs.contains($0) }
                guard hasAll else { return false }
            }
            return true
        }

        // Pick the one with lowest load
        return candidates.min(by: { $0.currentLoad < $1.currentLoad })
    }

    // MARK: - Inbound Task Handling

    /// Handle an incoming delegated task from a peer. Returns accept/reject response.
    func handleIncomingTask(data: [String: Any], senderIP: String) async -> [String: Any] {
        guard let taskID = data["id"] as? String,
              let originNodeID = data["origin_node_id"] as? String,
              let originHost = data["origin_host"] as? String,
              let originPort = data["origin_port"] as? Int,
              let title = data["title"] as? String,
              let description = data["description"] as? String,
              let signature = data["signature"] as? String else {
            return ["status": "rejected", "reason": "Missing required fields"]
        }

        let priority = data["priority"] as? Int ?? 1
        let requiredSkillIDs = data["required_skill_ids"] as? [String] ?? []
        let requiredAccessLevel = data["required_access_level"] as? Int ?? 2
        let context = data["context"] as? String

        // Verify signature using peer's public key
        let signPayload = "\(taskID)|\(title)|\(originNodeID)"
        let peerPublicKey = await lookupPeerPublicKey(nodeID: originNodeID)
        if let pubKey = peerPublicKey {
            guard SkillIntegrityVerifier.verify(string: signPayload, signature: signature, publicKey: pubKey) else {
                TorboLog.warn("Rejected delegated task '\(title)' — invalid signature from \(originNodeID.prefix(8))", subsystem: "Delegation")
                return ["status": "rejected", "reason": "Invalid signature"]
            }
        }

        // Check access level cap
        guard requiredAccessLevel <= maxAccessLevelForDelegation() else {
            return ["status": "rejected", "reason": "Access level \(requiredAccessLevel) exceeds maximum \(maxAccessLevelForDelegation())"]
        }

        // Check capacity
        let activeInbound = inboundTasks.count
        guard activeInbound < maxConcurrentDelegated else {
            return ["status": "rejected", "reason": "At capacity (\(activeInbound)/\(maxConcurrentDelegated))"]
        }

        // Check required skills
        if !requiredSkillIDs.isEmpty {
            let installedSkills = await SkillsManager.shared.listSkills().compactMap { $0["id"] as? String }
            let missingSkills = requiredSkillIDs.filter { !installedSkills.contains($0) }
            if !missingSkills.isEmpty {
                return ["status": "rejected", "reason": "Missing skills: \(missingSkills.joined(separator: ", "))"]
            }
        }

        // Create local AgentTask for execution
        let agentIDs = await AgentConfigManager.shared.agentIDs
        let assignedTo = agentIDs.first ?? "sid"
        let localTask = await TaskQueue.shared.createTask(
            title: title,
            description: description + (context != nil ? "\n\n--- DELEGATED CONTEXT ---\n\(context!)" : ""),
            assignedTo: assignedTo,
            assignedBy: "delegation:\(originNodeID)",
            priority: TaskQueue.TaskPriority(rawValue: priority) ?? .normal
        )

        // Mark as inbound delegation
        await TaskQueue.shared.markDelegatedInbound(id: localTask.id, fromNodeID: originNodeID)

        inboundTasks[taskID] = InboundDelegation(
            taskID: taskID,
            originNodeID: originNodeID,
            originHost: senderIP.isEmpty ? originHost : originHost, // Use declared host for result delivery
            originPort: originPort,
            receivedAt: Date(),
            localTaskID: localTask.id
        )
        persistState()

        TorboLog.info("Accepted delegated task '\(title)' from \(originNodeID.prefix(8))", subsystem: "Delegation")

        await EventBus.shared.publish("delegation.received",
            payload: ["task_id": taskID, "origin_node": originNodeID, "title": title],
            source: "CrossNodeDelegation")

        return ["status": "accepted", "task_id": taskID, "local_task_id": localTask.id]
    }

    // MARK: - Result Handling

    /// Handle a result received from the executor node.
    func handleTaskResult(data: [String: Any]) async -> [String: Any] {
        guard let taskID = data["task_id"] as? String,
              let executorNodeID = data["executor_node_id"] as? String,
              let status = data["status"] as? String,
              let signature = data["signature"] as? String else {
            return ["status": "error", "reason": "Missing required fields"]
        }

        let result = data["result"] as? String
        let error = data["error"] as? String
        let executionTime = data["execution_time_seconds"] as? Int ?? 0

        // Verify signature
        let signPayload = "\(taskID)|\(status)|\(executorNodeID)"
        let peerPublicKey = await lookupPeerPublicKey(nodeID: executorNodeID)
        if let pubKey = peerPublicKey {
            guard SkillIntegrityVerifier.verify(string: signPayload, signature: signature, publicKey: pubKey) else {
                TorboLog.warn("Rejected result for task \(taskID.prefix(8)) — invalid signature", subsystem: "Delegation")
                return ["status": "error", "reason": "Invalid signature"]
            }
        }

        guard let outbound = outboundTasks[taskID] else {
            TorboLog.warn("Received result for unknown outbound task \(taskID.prefix(8))", subsystem: "Delegation")
            return ["status": "error", "reason": "Unknown task"]
        }

        // Update local task
        if status == "completed" {
            await TaskQueue.shared.completeTask(id: outbound.localTaskID, result: result ?? "Completed by remote node")
            TorboLog.info("Delegation completed: task \(taskID.prefix(8)) in \(executionTime)s", subsystem: "Delegation")
        } else {
            await TaskQueue.shared.failTask(id: outbound.localTaskID, error: error ?? "Failed on remote node")
            TorboLog.warn("Delegation failed: task \(taskID.prefix(8)) — \(error ?? "unknown")", subsystem: "Delegation")
        }

        outboundTasks.removeValue(forKey: taskID)
        persistState()

        let eventName = status == "completed" ? "delegation.completed" : "delegation.failed"
        await EventBus.shared.publish(eventName,
            payload: ["task_id": taskID, "executor_node": executorNodeID, "execution_time": "\(executionTime)"],
            source: "CrossNodeDelegation")

        return ["status": "ok"]
    }

    /// Deliver the result of an inbound task back to the originator.
    func deliverResult(taskID: String, status: String, result: String?, error: String?) async {
        // Find the inbound delegation by local task ID
        guard let (delegationID, inbound) = inboundTasks.first(where: { $0.value.localTaskID == taskID }) else {
            return // Not an inbound delegation — nothing to deliver
        }

        guard let identity = await SkillCommunityManager.shared.getIdentity() else {
            TorboLog.error("Cannot deliver result — no node identity", subsystem: "Delegation")
            return
        }

        let signPayload = "\(inbound.taskID)|\(status)|\(identity.nodeID)"
        let signature = SkillIntegrityVerifier.sign(string: signPayload)
        let now = ISO8601DateFormatter().string(from: Date())
        let executionTime = Int(Date().timeIntervalSince(inbound.receivedAt))

        let taskResult = DelegatedTaskResult(
            taskID: inbound.taskID,
            executorNodeID: identity.nodeID,
            status: status,
            result: result,
            error: error,
            executionTimeSeconds: executionTime,
            signature: signature,
            completedAt: now
        )

        guard let url = URL(string: "http://\(inbound.originHost):\(inbound.originPort)/v1/delegation/result") else {
            TorboLog.error("Invalid origin URL for result delivery: \(inbound.originHost):\(inbound.originPort)", subsystem: "Delegation")
            return
        }

        let body = taskResult.toDict()

        await RetryUtility.withRetryQuiet(maxAttempts: 3, baseDelay: 1.0) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw DelegationError.resultDeliveryFailed
            }
        }

        inboundTasks.removeValue(forKey: delegationID)
        persistState()

        TorboLog.info("Delivered result for task \(inbound.taskID.prefix(8)) to \(inbound.originNodeID.prefix(8))", subsystem: "Delegation")
    }

    // MARK: - Peer Capabilities

    /// Refresh capabilities from all known peers.
    func refreshPeerCapabilities() async {
        let peers = await SkillCommunityManager.shared.allPeers()
        guard !peers.isEmpty else { return }

        for peer in peers {
            guard let url = URL(string: "http://\(peer.host):\(peer.port)/v1/delegation/capabilities") else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nodeID = json["node_id"] as? String else { continue }

                let cap = NodeCapabilities(
                    nodeID: nodeID,
                    displayName: json["display_name"] as? String ?? "",
                    skillIDs: json["skill_ids"] as? [String] ?? [],
                    agentIDs: json["agent_ids"] as? [String] ?? [],
                    maxAccessLevel: json["max_access_level"] as? Int ?? 2,
                    acceptsDelegation: json["accepts_delegation"] as? Bool ?? true,
                    currentLoad: json["current_load"] as? Int ?? 0,
                    maxConcurrentDelegated: json["max_concurrent_delegated"] as? Int ?? 2,
                    updatedAt: json["updated_at"] as? String ?? ""
                )
                peerCapabilities[nodeID] = cap
                capabilityCacheTime[nodeID] = Date()
            } catch {
                // Peer not reachable — skip
            }
        }

        TorboLog.info("Refreshed capabilities from \(peerCapabilities.count) peer(s)", subsystem: "Delegation")
    }

    /// Build this node's capabilities from local state.
    func getCapabilities() async -> NodeCapabilities {
        guard let identity = await SkillCommunityManager.shared.getIdentity() else {
            return NodeCapabilities(
                nodeID: "unknown", displayName: "unknown", skillIDs: [], agentIDs: [],
                maxAccessLevel: 0, acceptsDelegation: false, currentLoad: 0,
                maxConcurrentDelegated: 0, updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        }

        let skills = await SkillsManager.shared.listSkills().compactMap { $0["id"] as? String }
        let agentIDs = await AgentConfigManager.shared.agentIDs
        let activeTasks = await TaskQueue.shared.activeTasks().count
        let now = ISO8601DateFormatter().string(from: Date())

        return NodeCapabilities(
            nodeID: identity.nodeID,
            displayName: identity.displayName,
            skillIDs: skills,
            agentIDs: agentIDs,
            maxAccessLevel: maxAccessLevelForDelegation(),
            acceptsDelegation: true,
            currentLoad: activeTasks,
            maxConcurrentDelegated: maxConcurrentDelegated,
            updatedAt: now
        )
    }

    // MARK: - Watchdog

    func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.checkTimeouts()
            }
        }
        TorboLog.info("Delegation watchdog started (30s interval)", subsystem: "Delegation")
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func checkTimeouts() async {
        let now = Date()
        var timedOut: [String] = []

        for (taskID, outbound) in outboundTasks {
            let elapsed = now.timeIntervalSince(outbound.sentAt)
            if elapsed > TimeInterval(outbound.timeoutSeconds) {
                timedOut.append(taskID)
            }
        }

        for taskID in timedOut {
            if let outbound = outboundTasks[taskID] {
                await TaskQueue.shared.failTask(id: outbound.localTaskID, error: "Delegation timed out after \(outbound.timeoutSeconds)s")
                outboundTasks.removeValue(forKey: taskID)

                TorboLog.warn("Delegation timed out: task \(taskID.prefix(8)) to \(outbound.targetNodeID.prefix(8))", subsystem: "Delegation")

                await EventBus.shared.publish("delegation.timeout",
                    payload: ["task_id": taskID, "target_node": outbound.targetNodeID],
                    source: "CrossNodeDelegation")
            }
        }

        if !timedOut.isEmpty { persistState() }
    }

    // MARK: - Queries

    func outboundStatus() -> [[String: Any]] {
        outboundTasks.values.map { ob in
            [
                "task_id": ob.taskID,
                "target_node_id": ob.targetNodeID,
                "sent_at": ISO8601DateFormatter().string(from: ob.sentAt),
                "timeout_seconds": ob.timeoutSeconds,
                "local_task_id": ob.localTaskID,
                "elapsed_seconds": Int(Date().timeIntervalSince(ob.sentAt))
            ] as [String: Any]
        }
    }

    func inboundStatus() -> [[String: Any]] {
        inboundTasks.values.map { ib in
            [
                "task_id": ib.taskID,
                "origin_node_id": ib.originNodeID,
                "received_at": ISO8601DateFormatter().string(from: ib.receivedAt),
                "local_task_id": ib.localTaskID,
                "elapsed_seconds": Int(Date().timeIntervalSince(ib.receivedAt))
            ] as [String: Any]
        }
    }

    func peersWithCapabilities() -> [[String: Any]] {
        peerCapabilities.values.map { $0.toDict() }
    }

    // MARK: - Helpers

    private func maxAccessLevelForDelegation() -> Int {
        2 // readFiles — conservative default for delegated tasks
    }

    private func lookupPeerPublicKey(nodeID: String) async -> String? {
        // Peers share their public key via /v1/community/identity
        let peers = await SkillCommunityManager.shared.allPeers()
        guard let peer = peers.first(where: { $0.nodeID == nodeID }) else { return nil }

        guard let url = URL(string: "http://\(peer.host):\(peer.port)/v1/community/identity") else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pubKey = json["public_key"] as? String else { return nil }
            return pubKey
        } catch {
            return nil
        }
    }

    /// Send a task to a peer node via HTTP POST with retry.
    private func sendTaskToPeer(task: DelegatedTask, host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/v1/delegation/submit") else {
            throw DelegationError.invalidPeerURL
        }

        let body = task.toDict()

        try await RetryUtility.withRetry(maxAttempts: 3, baseDelay: 1.0) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
                throw DelegationError.peerRejected(errorBody)
            }
        }
    }

    // MARK: - Persistence

    private func persistState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let outboundData = try encoder.encode(Array(outboundTasks.values))
            let inboundData = try encoder.encode(Array(inboundTasks.values))
            let combined: [String: Any] = [
                "outbound": (try? JSONSerialization.jsonObject(with: outboundData)) ?? [],
                "inbound": (try? JSONSerialization.jsonObject(with: inboundData)) ?? []
            ]
            let data = try JSONSerialization.data(withJSONObject: combined)
            try data.write(to: URL(fileURLWithPath: PlatformPaths.delegatedTasksFile))
        } catch {
            TorboLog.error("Failed to persist delegation state: \(error)", subsystem: "Delegation")
        }
    }

    private nonisolated static func loadStateSync() -> ([String: OutboundDelegation], [String: InboundDelegation]) {
        let path = PlatformPaths.delegatedTasksFile
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([:], [:])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var outbound: [String: OutboundDelegation] = [:]
        var inbound: [String: InboundDelegation] = [:]

        if let outboundArr = json["outbound"],
           let outboundData = try? JSONSerialization.data(withJSONObject: outboundArr),
           let loaded = try? decoder.decode([OutboundDelegation].self, from: outboundData) {
            for item in loaded { outbound[item.taskID] = item }
        }

        if let inboundArr = json["inbound"],
           let inboundData = try? JSONSerialization.data(withJSONObject: inboundArr),
           let loaded = try? decoder.decode([InboundDelegation].self, from: inboundData) {
            for item in loaded { inbound[item.taskID] = item }
        }

        return (outbound, inbound)
    }
}

// MARK: - Errors

enum DelegationError: Error, LocalizedError {
    case noIdentity
    case noPeerAvailable
    case invalidPeerURL
    case peerRejected(String)
    case resultDeliveryFailed

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "Node identity not initialized"
        case .noPeerAvailable: return "No peer available with required capabilities"
        case .invalidPeerURL: return "Invalid peer URL"
        case .peerRejected(let reason): return "Peer rejected task: \(reason)"
        case .resultDeliveryFailed: return "Failed to deliver result to originator"
        }
    }
}
