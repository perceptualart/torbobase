// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Apple Speech Framework with Conversational Presence Detection
// Ported from Torbo App — stripped iOS audio session code, kept CPD logic intact.
#if os(macOS)
import Speech
import AVFoundation

@MainActor
final class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()

    // MARK: - Published State

    @Published var transcript: String = ""
    @Published var isListening = false
    @Published var audioLevel: Float = 0
    @Published var audioLevels: [Float] = Array(repeating: 0, count: 40)
    @Published var error: String?

    // MARK: - CPD (Conversational Presence Detection)

    /// Rolling energy metric — decays at 0.92/tick, boosted by speech
    private var presenceEnergy: Float = 0
    /// Threshold: real speech vs room noise
    private let speechEnergyThreshold: Float = 0.45
    /// Silence timers scaled by user preference
    private var quickSilenceThreshold: TimeInterval = 1.2
    private var normalSilenceThreshold: TimeInterval = 3.5
    private var midSentenceSilenceThreshold: TimeInterval = 3.0

    // MARK: - Audio Controls

    /// Input gain multiplier (0.5 = quiet, 4.0 = loud)
    /// nonisolated(unsafe): read from realtime audio thread in input tap callback
    nonisolated(unsafe) var inputGain: Float = 1.5
    /// Noise gate threshold — audio below this normalized level is suppressed
    /// nonisolated(unsafe): read from realtime audio thread in input tap callback
    nonisolated(unsafe) var noiseGateLevel: Float = 0.05

    // MARK: - Callbacks

    var onTranscriptFinalized: ((String) -> Void)?

    // MARK: - Private

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AudioEngine.shared

    private var silenceTimer: Timer?
    private var lastTranscriptTime = Date()
    private var lastTranscriptText = ""
    private var levelHistory: [Float] = []

    /// Pause before reply slider (0.0 = fast, 1.0 = patient)
    var pauseSlider: Float = 0.5 {
        didSet {
            // Scale silence thresholds: fast (0.8-2.0s) to patient (2.0-5.0s)
            let t = Double(pauseSlider)
            quickSilenceThreshold = 0.8 + t * 1.2
            normalSilenceThreshold = 2.0 + t * 3.0
            midSentenceSilenceThreshold = 1.5 + t * 2.5
        }
    }

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Start / Stop

    func startListening() {
        guard !isListening else { return }

        // Check speech recognition authorization
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus != .authorized {
            error = "Speech not authorized (status \(authStatus.rawValue)). Grant in System Settings > Privacy > Speech Recognition."
            TorboLog.warn("Speech auth status: \(authStatus.rawValue)", subsystem: "Speech")
            // If not determined, request asynchronously
            if authStatus == .notDetermined {
                Task {
                    let granted = await requestAuthorization()
                    if granted { startListening() }
                }
            }
            return
        }

        guard recognizer?.isAvailable == true else {
            error = "Speech recognition unavailable on this device"
            TorboLog.error("Speech recognizer not available", subsystem: "Speech")
            return
        }

        // Reset state
        transcript = ""
        lastTranscriptText = ""
        lastTranscriptTime = Date()
        error = nil

        TorboLog.info("Speech: starting listen — engine running: \(audioEngine.isRunning), mic: \(audioEngine.micPermissionGranted)", subsystem: "Speech")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        // Set up the buffer callback with gain + noise gate
        audioEngine.onInputBuffer = { [weak self] buffer, _ in
            guard let self else { return }
            // Apply gain to buffer (modifies in place)
            let gain = self.inputGain
            let gate = self.noiseGateLevel
            if let data = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                // Apply gain
                if gain != 1.0 {
                    for i in 0..<count { data[i] *= gain }
                }
                // Noise gate: if RMS below threshold, zero the buffer
                if gate > 0 {
                    var sum: Float = 0
                    for i in 0..<count { sum += data[i] * data[i] }
                    let rms = sqrt(sum / max(Float(count), 1))
                    let db = 20 * log10(max(rms, 1e-7))
                    let normalized = max(0, min(1, (db + 50) / 50))
                    if normalized < gate {
                        for i in 0..<count { data[i] = 0 }
                    }
                }
            }
            request.append(buffer)
            // Use GCD — creating Swift Tasks from audio threads corrupts concurrency runtime
            DispatchQueue.main.async {
                self.processAudioBuffer(buffer)
            }
        }

        // Clean state: remove any existing tap
        audioEngine.removeInputTap()

        // If engine is running, stop it — macOS requires taps installed before start
        if audioEngine.isRunning {
            TorboLog.info("Speech: stopping engine for tap reinstall", subsystem: "Speech")
            audioEngine.stopEngine()
        }

        // Prepare engine to configure hardware (ensures valid input format)
        audioEngine.prepareIfNeeded()

        // Install input tap, then start engine
        audioEngine.installInputTap()

        do {
            try audioEngine.startEngine()
            TorboLog.info("Speech: engine started, tap installed, listening (running: \(audioEngine.isRunning))", subsystem: "Speech")
        } catch {
            self.error = "Audio engine failed: \(error.localizedDescription)"
            TorboLog.error("Speech: audio engine failed — \(error)", subsystem: "Speech")
            audioEngine.removeInputTap()
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            // Use GCD — recognition callback fires on Speech framework thread
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    self.lastTranscriptTime = Date()
                    self.lastTranscriptText = text

                    // CPD: Boost presence energy on new speech
                    self.presenceEnergy = min(1.0, self.presenceEnergy + 0.3)

                    // Reset silence timer
                    self.resetSilenceTimer()

                    // Apple says final — but we verify with CPD
                    if result.isFinal {
                        // Only finalize if presence energy has decayed (real pause)
                        if self.presenceEnergy < self.speechEnergyThreshold {
                            self.finalizeTranscript()
                        }
                        // Otherwise, CPD says user is still talking — silence timer will handle it
                    }
                }

                if let error {
                    // Ignore cancellation errors
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 { return }
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 { return }
                    TorboLog.debug("Speech recognition error: \(error)", subsystem: "Speech")
                }
            }
        }

        isListening = true
        TorboLog.info("Listening started", subsystem: "Speech")
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine.removeInputTap()
        audioEngine.onInputBuffer = nil
        isListening = false
        presenceEnergy = 0
    }

    // MARK: - CPD Silence Timer

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()

        // Determine silence threshold based on thought completeness
        let threshold: TimeInterval
        let completeness = thoughtCompleteness(lastTranscriptText)
        switch completeness {
        case .complete:
            threshold = quickSilenceThreshold
        case .likely:
            threshold = normalSilenceThreshold
        case .incomplete:
            threshold = midSentenceSilenceThreshold
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finalizeTranscript()
            }
        }
    }

    private func finalizeTranscript() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        silenceTimer?.invalidate()
        silenceTimer = nil

        TorboLog.debug("Finalized: \"\(text.prefix(50))...\"", subsystem: "Speech")
        onTranscriptFinalized?(text)

        // Don't clear transcript — let VoiceEngine handle the flow
    }

    // MARK: - Thought Completeness Detection

    private enum ThoughtCompleteness {
        case complete, likely, incomplete
    }

    private func thoughtCompleteness(_ text: String) -> ThoughtCompleteness {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .complete }

        let lastChar = trimmed.last ?? " "

        // Ends with sentence-ending punctuation
        if ".!?".contains(lastChar) { return .complete }

        // Ends with comma, semicolon — mid-thought
        if ",;:".contains(lastChar) { return .incomplete }

        // Common incomplete patterns
        let lower = trimmed.lowercased()
        let incompleteEndings = ["and", "but", "or", "the", "a", "an", "to", "of", "in",
                                  "for", "with", "that", "which", "who", "when", "where",
                                  "because", "since", "if", "so", "then", "also", "like"]
        let lastWord = lower.components(separatedBy: " ").last ?? ""
        if incompleteEndings.contains(lastWord) { return .incomplete }

        // Short utterances (< 5 words) are likely complete (commands, answers)
        let wordCount = trimmed.components(separatedBy: " ").count
        if wordCount <= 4 { return .complete }

        return .likely
    }

    // MARK: - Audio Level Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / max(Float(count), 1))

        // Convert to dB and normalize
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 50) / 50))

        audioLevel = normalized
        levelHistory.append(normalized)
        if levelHistory.count > 40 { levelHistory.removeFirst() }
        audioLevels = levelHistory
        while audioLevels.count < 40 { audioLevels.insert(0, at: 0) }

        // CPD: Decay presence energy
        presenceEnergy *= 0.92
        if normalized > 0.15 {
            presenceEnergy = min(1.0, presenceEnergy + normalized * 0.2)
        }
    }
}
#endif
