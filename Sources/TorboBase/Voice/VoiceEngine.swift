// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Voice State Machine
// idle → listening → thinking → speaking
// Ported from Torbo App — replaced GatewayManager with direct HTTP to local gateway.
#if os(macOS)
import SwiftUI

// MARK: - Voice State

enum VoiceState: String {
    case idle
    case listening
    case thinking
    case speaking
}

// MARK: - Voice Engine

@MainActor
final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    // MARK: - Published State

    @Published var state: VoiceState = .idle
    @Published var isActive = false
    @Published var activeAgentID: String = "sid"
    @Published var lastUserTranscript: String = ""
    @Published var lastAssistantResponse: String = ""
    @Published var isMuted = false
    @Published var isMicMuted = false
    @Published var autoListen = true

    // Voice-to-chat bridge: triggers AgentChatView to inject messages
    @Published var voiceChatTrigger: Int = 0  // incremented when user transcript is ready

    // MARK: - Audio Levels (routed to orb)

    /// Published audio levels — updated at ~15Hz by internal timer so SwiftUI orb
    /// always receives smooth, regular updates regardless of voice state.
    @Published var currentAudioLevels: [Float] = Array(repeating: Float(0.15), count: 40)

    private var levelTimer: Task<Void, Never>?

    /// Start the ~15Hz level pump — call once at init
    private func startLevelPump() {
        levelTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 65_000_000)  // ~15Hz
                guard let self else { return }
                let levels: [Float]
                switch self.state {
                case .speaking:
                    levels = self.tts.audioLevels
                case .listening:
                    levels = self.speech.audioLevels
                case .thinking:
                    levels = self.simulatedThinkingLevels()
                case .idle:
                    if self.isActive {
                        levels = self.simulatedIdleLevels()
                    } else {
                        // Not active — use ambient mic level (like iOS)
                        let mic = self.audio.audioLevel
                        levels = Array(repeating: max(0.08, mic), count: 40)
                    }
                }
                self.currentAudioLevels = levels
            }
        }
    }

    // MARK: - Subsystems

    let tts = TTSManager.shared
    let speech = SpeechRecognizer.shared
    let audio = AudioEngine.shared

    // MARK: - Private

    private var streamTask: Task<Void, Never>?
    private var thinkingPhase: Double = 0
    private var idlePhase: Double = 0

    private init() {
        // Wire up speech recognizer callback
        speech.onTranscriptFinalized = { [weak self] text in
            Task { @MainActor in
                self?.handleTranscriptFinalized(text)
            }
        }
        // Start the ~15Hz level pump for smooth orb updates
        startLevelPump()

        // Start ambient mic monitoring for home orb reactivity (if permission already granted)
        Task {
            let micOK = await audio.requestMicPermission()
            if micOK {
                audio.prepareIfNeeded()
                audio.installInputTap()
                try? audio.startEngine()
                TorboLog.info("Voice: ambient mic monitoring started for orb", subsystem: "Voice")
            }
        }
    }

    // MARK: - Activation

    func activate(agentID: String = "sid") {
        guard !isActive else {
            // If already active but for a different agent, switch
            if activeAgentID != agentID {
                activeAgentID = agentID
                applyAgentVoiceConfig(agentID)
                TorboLog.info("Voice: switched to agent \(agentID)", subsystem: "Voice")
            }
            return
        }
        activeAgentID = agentID
        isActive = true
        state = .idle
        applyAgentVoiceConfig(agentID)
        TorboLog.info("Voice: activated for agent \(agentID)", subsystem: "Voice")

        // Ensure permissions are granted, then auto-listen
        Task {
            let micOK = await audio.requestMicPermission()
            let speechOK = await speech.requestAuthorization()
            TorboLog.info("Voice permissions — mic: \(micOK), speech: \(speechOK)", subsystem: "Voice")

            // Auto-listen after permissions are confirmed
            if autoListen && !isMicMuted && micOK && speechOK {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard state == .idle, isActive, !isMicMuted else { return }
                transition(to: .listening, reason: "auto-listen after activate")
            }
        }
    }

    /// Configure TTSManager from the agent's stored voice settings
    private func applyAgentVoiceConfig(_ agentID: String) {
        Task {
            if let config = await AgentConfigManager.shared.agent(agentID) {
                tts.engine = config.voiceEngine
                tts.elevenLabsVoiceID = config.elevenLabsVoiceID
                tts.systemVoiceIdentifier = config.systemVoiceIdentifier
                TorboLog.info("Voice: applied \(agentID) config — engine=\(config.voiceEngine), voice=\(config.elevenLabsVoiceID.prefix(8))", subsystem: "Voice")
            }
        }
    }

    func deactivate() {
        streamTask?.cancel()
        speech.stopListening()
        tts.stop()
        isActive = false
        transition(to: .idle, reason: "deactivated")
    }

    // MARK: - State Machine — THE only way state changes

    func transition(to newState: VoiceState, reason: String) {
        let oldState = state
        guard oldState != newState else { return }

        // Exit cleanup
        switch oldState {
        case .listening:
            speech.stopListening()
        case .speaking:
            tts.stop()
        case .thinking:
            // Cancel any pending stream
            break
        case .idle:
            break
        }

        state = newState
        TorboLog.info("Voice: \(oldState.rawValue) → \(newState.rawValue) (\(reason))", subsystem: "Voice")

        // Enter setup
        switch newState {
        case .listening:
            speech.startListening()
        case .speaking:
            // Speaking is triggered by processInput, not by entering state
            break
        case .thinking:
            break
        case .idle:
            if autoListen && isActive && !isMicMuted {
                // Auto-transition to listening after a brief pause
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard state == .idle, isActive, !isMicMuted else { return }
                    transition(to: .listening, reason: "auto-listen")
                }
            }
        }
    }

    // MARK: - Listen (manual trigger)

    func listen() {
        guard isActive else { return }
        if state == .speaking {
            // Barge-in: stop speaking, start listening
            tts.stop()
        }
        transition(to: .listening, reason: "manual")
    }

    // MARK: - Stop Speaking (tap to mute)

    func stopSpeaking() {
        if state == .speaking {
            tts.stop()
            transition(to: .idle, reason: "muted")
        }
    }

    // MARK: - Transcript Finalized

    private func handleTranscriptFinalized(_ text: String) {
        guard isActive, state == .listening else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        lastUserTranscript = text
        voiceChatTrigger += 1  // notify AgentChatView to add user message
        transition(to: .thinking, reason: "transcript finalized")
        processInput(text)
    }

    // MARK: - Process Input → HTTP → Speak

    private func processInput(_ text: String) {
        streamTask?.cancel()
        streamTask = Task {
            await routeToGateway(text)
        }
    }

    private func routeToGateway(_ text: String) async {
        let port = AppState.shared.serverPort
        let token = KeychainManager.serverToken

        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            transition(to: .idle, reason: "invalid URL")
            return
        }

        let body: [String: Any] = [
            "messages": [
                ["role": "user", "content": text]
            ],
            "stream": true
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            transition(to: .idle, reason: "encode failed")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(activeAgentID, forHTTPHeaderField: "x-torbo-agent-id")
        request.httpBody = bodyData

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard !Task.isCancelled else { return }

            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                await MainActor.run { transition(to: .idle, reason: "HTTP error") }
                return
            }

            var accumulated = ""

            for try await line in bytes.lines {
                guard !Task.isCancelled else { break }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }

                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }

                accumulated += content
                lastAssistantResponse = accumulated  // update live for chat streaming
            }

            guard !Task.isCancelled, !accumulated.isEmpty else {
                await MainActor.run { transition(to: .idle, reason: "empty response") }
                return
            }
            TorboLog.info("Voice: got response (\(accumulated.count) chars), state=\(state.rawValue), muted=\(isMuted)", subsystem: "Voice")

            // Transition to speaking and play TTS
            guard state == .thinking else { return }
            transition(to: .speaking, reason: "response ready")

            if !isMuted {
                TorboLog.info("Voice: calling tts.speak()", subsystem: "Voice")
                tts.speak(accumulated)

                // Wait for TTS to finish — 30s timeout prevents infinite hang
                var ttsWaitCount = 0
                while tts.isSpeaking && !Task.isCancelled && ttsWaitCount < 300 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    ttsWaitCount += 1
                }
                if ttsWaitCount >= 300 {
                    TorboLog.warn("Voice: TTS timeout after 30s — forcing stop", subsystem: "Voice")
                    tts.stop()
                } else {
                    TorboLog.info("Voice: TTS finished speaking (\(ttsWaitCount * 100)ms)", subsystem: "Voice")
                }
            }

            guard !Task.isCancelled else { return }
            transition(to: .idle, reason: "speech complete")

        } catch {
            if !Task.isCancelled {
                TorboLog.error("Voice gateway error: \(error)", subsystem: "Voice")
                await MainActor.run { transition(to: .idle, reason: "error") }
            }
        }
    }

    // MARK: - Simulated Audio Levels

    private func simulatedThinkingLevels() -> [Float] {
        thinkingPhase += 0.05
        return (0..<40).map { i in
            let t = thinkingPhase + Double(i) * 0.1
            return Float(0.15 + sin(t * 2) * 0.08 + sin(t * 5) * 0.04)
        }
    }

    private func simulatedIdleLevels() -> [Float] {
        idlePhase += 0.02
        return (0..<40).map { i in
            let t = idlePhase + Double(i) * 0.08
            return Float(0.08 + sin(t) * 0.04)
        }
    }

    // MARK: - Orb Tap Action

    func handleOrbTap() {
        switch state {
        case .speaking:
            stopSpeaking()
        case .idle:
            listen()
        case .listening:
            // Force finalize
            speech.stopListening()
            let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                handleTranscriptFinalized(text)
            } else {
                transition(to: .idle, reason: "empty transcript")
            }
        case .thinking:
            // Cancel and go idle
            streamTask?.cancel()
            transition(to: .idle, reason: "cancelled")
        }
    }
}
#endif
