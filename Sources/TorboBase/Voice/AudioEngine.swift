// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Shared AVAudioEngine singleton for macOS
// Manages mic input tap and audio playback node. No AVAudioSession on macOS.
#if os(macOS)
import AVFoundation

// Module-level callback storage — accessed from realtime audio threads.
// Must NOT be on any actor to avoid Swift concurrency runtime corruption.
private var _audioInputCallback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
private var _audioOutputCallback: ((Float) -> Void)?

@MainActor
final class AudioEngine: ObservableObject {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    @Published var micPermissionGranted = false
    @Published var isRunning = false
    /// Ambient mic level (0–1) — always available when engine running, for orb reactivity
    @Published var audioLevel: Float = 0

    /// Callback for mic audio buffers (used by SpeechRecognizer).
    /// Stored in module-level global — safe to call from realtime audio thread.
    var onInputBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { _audioInputCallback }
        set { _audioInputCallback = newValue }
    }

    /// Callback for output metering (used by TTSManager → orb).
    /// Stored in module-level global — safe to call from realtime audio thread.
    var onOutputLevel: ((Float) -> Void)? {
        get { _audioOutputCallback }
        set { _audioOutputCallback = newValue }
    }

    private var inputTapInstalled = false
    private var outputTapInstalled = false

    private init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - Mic Permission

    func requestMicPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            micPermissionGranted = true
            prepareIfNeeded()
            return true
        }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micPermissionGranted = granted
            if granted { prepareIfNeeded() }
            return granted
        }
        micPermissionGranted = false
        return false
    }

    /// Prepare the engine to configure audio hardware — call after mic permission granted
    func prepareIfNeeded() {
        // Access inputNode to trigger hardware configuration on macOS
        let inputNode = engine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        engine.prepare()
        TorboLog.info("Audio engine prepared — input format: \(fmt.sampleRate)Hz, \(fmt.channelCount)ch", subsystem: "AudioEngine")
    }

    // MARK: - Engine Lifecycle

    func startEngine() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        isRunning = true
    }

    func stopEngine() {
        removeInputTap()
        removeOutputTap()
        playerNode.stop()
        engine.stop()
        isRunning = false
    }

    // MARK: - Input Tap (Mic)

    func installInputTap() {
        guard !inputTapInstalled else { return }
        let inputNode = engine.inputNode
        var format = inputNode.outputFormat(forBus: 0)
        TorboLog.info("Input tap format: \(format.sampleRate)Hz, \(format.channelCount)ch", subsystem: "AudioEngine")

        if format.sampleRate <= 0 {
            // Hardware not configured yet — prepare and retry
            TorboLog.warn("Input format invalid, preparing engine and retrying...", subsystem: "AudioEngine")
            engine.prepare()
            format = inputNode.outputFormat(forBus: 0)
            TorboLog.info("After prepare: \(format.sampleRate)Hz, \(format.channelCount)ch", subsystem: "AudioEngine")
            guard format.sampleRate > 0 else {
                TorboLog.error("Audio input still invalid after prepare — no mic available", subsystem: "AudioEngine")
                return
            }
        }

        // Closure captures module-level global — no @MainActor access on audio thread
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            _audioInputCallback?(buffer, time)
            // Also compute ambient mic level for orb reactivity
            if let data = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<count { sum += data[i] * data[i] }
                let rms = sqrt(sum / max(Float(count), 1))
                let db = 20 * log10(max(rms, 1e-7))
                let normalized = max(0, min(1, (db + 50) / 50))
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // EMA: fast attack, slow release
                    let alpha: Float = normalized > self.audioLevel ? 0.3 : 0.1
                    self.audioLevel += alpha * (normalized - self.audioLevel)
                }
            }
        }
        inputTapInstalled = true
        TorboLog.info("Input tap installed successfully", subsystem: "AudioEngine")
    }

    func removeInputTap() {
        guard inputTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    // MARK: - Output Metering Tap

    func installOutputMeteringTap() {
        guard !outputTapInstalled else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        // Closure captures module-level global — no @MainActor access on audio thread
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += data[i] * data[i] }
            let rms = sqrt(sum / max(Float(count), 1))
            let db = 20 * log10(max(rms, 1e-7))
            let normalized = max(0, min(1, (db + 50) / 50))
            _audioOutputCallback?(normalized)
        }
        outputTapInstalled = true
    }

    func removeOutputTap() {
        guard outputTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        outputTapInstalled = false
    }

    // MARK: - Playback

    /// Play a PCM buffer through the player node.
    /// Handles format conversion if the buffer format doesn't match the engine output.
    func playBuffer(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) {
        // Reconnect player node to match the buffer's format — avoids silent failures
        // from format mismatches (e.g., ElevenLabs 22050Hz vs hardware 48000Hz)
        let bufferFormat = buffer.format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: bufferFormat)

        if !engine.isRunning {
            engine.prepare()
            do { try startEngine() } catch {
                TorboLog.error("Failed to start engine for playback: \(error)", subsystem: "AudioEngine")
                DispatchQueue.main.async { completion?() }
                return
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
        TorboLog.info("AudioEngine: scheduling buffer — \(bufferFormat.sampleRate)Hz, \(bufferFormat.channelCount)ch, \(buffer.frameLength) frames", subsystem: "AudioEngine")
        playerNode.scheduleBuffer(buffer) {
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Stop all playback immediately
    func stopPlayback() {
        playerNode.stop()
        playerNode.play() // Reset to ready state
    }

    /// The audio engine's input node format (for SpeechRecognizer)
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// The input node itself (for SpeechRecognizer to create recognition request)
    var inputNode: AVAudioInputNode {
        engine.inputNode
    }
}
#endif
