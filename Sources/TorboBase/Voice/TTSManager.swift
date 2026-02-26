// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Text-to-Speech Manager
// Two engines: system (AVSpeechSynthesizer) and elevenlabs (HTTP streaming).
// Ported from Torbo App — stripped Piper/ONNX, stripped iOS AVAudioSession.
#if os(macOS)
import AVFoundation
import SwiftUI

@MainActor
final class TTSManager: NSObject, ObservableObject {
    static let shared = TTSManager()

    // MARK: - Published State

    @Published var isSpeaking = false
    @Published var audioLevel: Float = 0
    @Published var audioLevels: [Float] = Array(repeating: 0, count: 40)

    // MARK: - Configuration

    var engine: String = "system" // "system", "elevenlabs", or "torbo"
    var agentID: String = "sid" // Current agent for Piper voice selection
    var elevenLabsVoiceID: String = "21m00Tcm4TlvDq8ikWAM" // Default Rachel
    var systemVoiceIdentifier: String = ""
    var rate: Float = 0.52

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AudioEngine.shared
    private var speakTask: Task<Void, Never>?
    private var meteringTimer: Timer?
    private var levelHistory: [Float] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
        // Initialize Piper on-device TTS (loads voice models if available)
        PiperTTSEngine.shared.loadModels()
        PiperTTSEngine.shared.warmup()
    }

    // MARK: - Public API

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSpeaking = true
        TorboLog.info("TTS speak — engine: \(engine), text: \"\(text.prefix(60))...\"", subsystem: "TTS")

        if engine == "torbo" {
            speakTask = Task { await synthesizePiper(text) }
        } else if engine == "elevenlabs" {
            speakTask = Task { await synthesizeElevenLabs(text) }
        } else {
            speakSystem(text)
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioEngine.stopPlayback()
        stopMetering()
        isSpeaking = false
        audioLevel = 0
        resetLevels()
    }

    // MARK: - System Voice (AVSpeechSynthesizer direct)

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if !systemVoiceIdentifier.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: systemVoiceIdentifier)
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        // Use direct speak — delegate handles isSpeaking + audio levels
        synthesizer.speak(utterance)
    }

    // MARK: - Piper On-Device TTS (TORBO engine)

    private func synthesizePiper(_ text: String) async {
        let piperEngine = PiperTTSEngine.shared
        guard piperEngine.isAvailable else {
            TorboLog.info("Piper not available — falling back to system voice", subsystem: "TTS")
            await MainActor.run { speakSystem(text) }
            return
        }

        guard let wavData = await piperEngine.synthesize(text: text, agentID: agentID) else {
            TorboLog.warn("Piper synthesis returned nil — falling back to system voice", subsystem: "TTS")
            await MainActor.run { speakSystem(text) }
            return
        }

        // Play WAV data through AudioEngine
        await playWAVData(wavData)
    }

    private func playWAVData(_ data: Data) async {
        guard !Task.isCancelled else {
            await MainActor.run { isSpeaking = false }
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("piper_\(UUID().uuidString).wav")
        do {
            try data.write(to: tempURL)
            let audioFile = try AVAudioFile(forReading: tempURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                TorboLog.error("Piper: failed to create PCM buffer", subsystem: "TTS")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run { isSpeaking = false }
                return
            }
            try audioFile.read(into: buffer)
            try? FileManager.default.removeItem(at: tempURL)

            guard !Task.isCancelled else {
                await MainActor.run { isSpeaking = false }
                return
            }

            await MainActor.run { startMetering() }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioEngine.playBuffer(buffer) {
                    continuation.resume()
                }
            }

            await MainActor.run {
                stopMetering()
                isSpeaking = false
                resetLevels()
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            TorboLog.error("Piper: failed to play audio: \(error)", subsystem: "TTS")
            await MainActor.run { isSpeaking = false }
        }
    }

    // MARK: - ElevenLabs Streaming TTS

    private func synthesizeElevenLabs(_ text: String) async {
        let apiKey = AppState.shared.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            TorboLog.warn("ElevenLabs API key not configured", subsystem: "TTS")
            await MainActor.run { isSpeaking = false }
            return
        }

        // Check disk cache first
        let cacheKey = djb2Hash(text + elevenLabsVoiceID)
        if let cached = loadFromCache(key: cacheKey) {
            await playAudioData(cached)
            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenLabsVoiceID)/stream") else {
            await MainActor.run { isSpeaking = false }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            TorboLog.info("TTS: ElevenLabs request starting...", subsystem: "TTS")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else {
                await MainActor.run { isSpeaking = false }
                return
            }

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                TorboLog.error("ElevenLabs error \(httpResp.statusCode)", subsystem: "TTS")
                await MainActor.run { isSpeaking = false }
                return
            }

            TorboLog.info("TTS: ElevenLabs response received (\(data.count) bytes)", subsystem: "TTS")

            // Cache the audio
            saveToCache(key: cacheKey, data: data)

            // Play the audio
            await playAudioData(data)
        } catch {
            if !Task.isCancelled {
                TorboLog.error("ElevenLabs request failed: \(error)", subsystem: "TTS")
                await MainActor.run { isSpeaking = false }
            }
        }
    }

    private func playAudioData(_ data: Data) async {
        guard !Task.isCancelled else {
            await MainActor.run { isSpeaking = false }
            return
        }

        // ElevenLabs returns mp3 — convert to PCM via AVAudioFile
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_\(UUID().uuidString).mp3")
        do {
            try data.write(to: tempURL)
            let audioFile = try AVAudioFile(forReading: tempURL)
            TorboLog.info("TTS: audio file — format: \(audioFile.processingFormat), frames: \(audioFile.length)", subsystem: "TTS")
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                TorboLog.error("TTS: failed to create PCM buffer", subsystem: "TTS")
                try? FileManager.default.removeItem(at: tempURL)
                await MainActor.run { isSpeaking = false }
                return
            }
            try audioFile.read(into: buffer)
            try? FileManager.default.removeItem(at: tempURL)

            guard !Task.isCancelled else {
                await MainActor.run { isSpeaking = false }
                return
            }

            TorboLog.info("TTS: starting playback (\(buffer.frameLength) frames)", subsystem: "TTS")
            await MainActor.run { startMetering() }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioEngine.playBuffer(buffer) {
                    continuation.resume()
                }
            }

            TorboLog.info("TTS: playback complete", subsystem: "TTS")
            await MainActor.run {
                stopMetering()
                isSpeaking = false
                resetLevels()
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            TorboLog.error("TTS: failed to play audio: \(error)", subsystem: "TTS")
            await MainActor.run { isSpeaking = false }
        }
    }

    // MARK: - Audio Metering

    private func startMetering() {
        audioEngine.installOutputMeteringTap()
        // Use GCD (not Task) — this closure fires on the realtime audio thread,
        // and creating Swift Tasks from audio threads corrupts concurrency runtime.
        audioEngine.onOutputLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.updateLevel(level)
            }
        }
    }

    private func stopMetering() {
        audioEngine.removeOutputTap()
        audioEngine.onOutputLevel = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func updateLevel(_ level: Float) {
        audioLevel = level
        levelHistory.append(level)
        if levelHistory.count > 40 { levelHistory.removeFirst() }
        audioLevels = levelHistory
        while audioLevels.count < 40 { audioLevels.insert(0, at: 0) }
    }

    private func resetLevels() {
        audioLevel = 0
        levelHistory.removeAll()
        audioLevels = Array(repeating: 0, count: 40)
    }

    // MARK: - Disk Cache (djb2 hash)

    private func djb2Hash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for char in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(char)
        }
        return String(hash, radix: 16)
    }

    private var cacheDir: URL {
        let dir = URL(fileURLWithPath: PlatformPaths.dataDir + "/tts_cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadFromCache(key: String) -> Data? {
        let file = cacheDir.appendingPathComponent("\(key).mp3")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // Check age — expire after 30 days
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) > 30 * 86400 {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return try? Data(contentsOf: file)
    }

    private func saveToCache(key: String, data: Data) {
        let file = cacheDir.appendingPathComponent("\(key).mp3")
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            stopMetering()
            isSpeaking = false
            resetLevels()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            stopMetering()
            isSpeaking = false
            resetLevels()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        // Simulate audio level from speech progress when using system voice
        Task { @MainActor in
            let progress = Float(characterRange.location) / max(Float(utterance.speechString.count), 1)
            let simLevel = 0.3 + sin(progress * .pi * 8) * 0.2 + Float.random(in: 0...0.15)
            updateLevel(min(1, max(0, simLevel)))
        }
    }
}
#endif
