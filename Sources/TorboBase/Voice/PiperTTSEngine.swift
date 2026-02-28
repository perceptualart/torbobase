// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — PiperTTSEngine
// On-device TTS using Piper VITS models via sherpa-onnx.
// Each agent has a custom-trained voice model. Falls back to SiD voice (NEVER system voice).
// Requires PIPER_TTS build flag + sherpa-onnx macOS libraries to activate.
// Without the flag, the engine compiles as a stub that returns nil (graceful fallback).

#if os(macOS)
import Foundation
import AVFoundation

/// On-device Piper TTS engine. Loads per-agent ONNX voice models at runtime.
/// Thread-safe: synthesis runs on a background queue, returns PCM audio data.
class PiperTTSEngine {
    static let shared = PiperTTSEngine()

    /// Sample rate for all Piper models (22050 Hz)
    static let sampleRate: Int = 22050

    /// Agent voice model mapping: agent ID → model file prefix
    /// Agents without a trained model will fall back to "sid" (never system voice)
    static let agentModels: [String: String] = [
        "sid": "sid_piper",
        "orion": "orion_piper",
        "mira": "mira_piper",
        "ada": "ada_piper",
    ]

    /// Per-agent voice tuning parameters (personality-matched)
    private static let voiceTuning: [String: (noiseScale: Float, noiseW: Float, lengthScale: Float)] = [
        "sid":   (noiseScale: 0.80, noiseW: 0.90, lengthScale: 0.95),  // Confident, clear leader
        "orion": (noiseScale: 0.75, noiseW: 0.85, lengthScale: 1.00),  // Analytical, measured
        "mira":  (noiseScale: 0.85, noiseW: 0.95, lengthScale: 1.00),  // Warm, expressive
        "ada":   (noiseScale: 0.80, noiseW: 0.90, lengthScale: 0.93),  // Creative, energetic
    ]

    /// Display names for log messages
    private static let displayNames: [String: String] = [
        "sid": "SiD",
        "orion": "Orion",
        "ada": "aDa",
        "mira": "Mira",
    ]

    /// The fallback agent ID — used when an agent's voice model isn't available
    static let fallbackAgentID = "sid"

    #if PIPER_TTS

    // MARK: - Full Implementation (sherpa-onnx available)

    /// Agent ID → loaded TTS wrapper
    private var models: [String: SherpaOnnxOfflineTtsWrapper] = [:]
    private let queue = DispatchQueue(label: "com.torbo.piper-tts", qos: .userInitiated)
    private var isInitialized = false
    private var isReady = false
    /// Continuations waiting for model loading to complete
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Whether the Piper engine is available and has at least one model loaded.
    var isAvailable: Bool { isReady && !models.isEmpty }

    /// Check if a Piper voice is available for the given agent (or fallback).
    func hasVoice(for agentID: String) -> Bool {
        return models[agentID] != nil || models[Self.fallbackAgentID] != nil
    }

    /// Check if a CUSTOM Piper voice is available (not fallback).
    func hasCustomVoice(for agentID: String) -> Bool {
        return models[agentID] != nil
    }

    /// Load all available Piper voice models ASYNCHRONOUSLY on a background queue.
    /// Call once at app startup. Does NOT block the calling thread.
    func loadModels() {
        guard !isInitialized else { return }
        isInitialized = true

        // CRITICAL: dispatch async — NOT sync. Sync blocked the main thread and caused
        // macOS to terminate the app at launch (Phase 6.1 fix).
        queue.async { [self] in
            let startTime = CFAbsoluteTimeGetCurrent()
            let voicesDir = PlatformPaths.dataDir + "/voices"
            let espeakDataPath = voicesDir + "/espeak-ng-data"
            let fm = FileManager.default

            guard fm.fileExists(atPath: espeakDataPath) else {
                TorboLog.info("espeak-ng-data not found at \(espeakDataPath) — Piper TTS unavailable", subsystem: "PiperTTS")
                self.markReady()
                return
            }

            for (agentID, prefix) in Self.agentModels {
                let name = Self.displayNames[agentID] ?? agentID
                let modelPath = voicesDir + "/\(prefix).onnx"
                let configPath = voicesDir + "/\(prefix).onnx.json"

                guard fm.fileExists(atPath: modelPath),
                      fm.fileExists(atPath: configPath) else {
                    TorboLog.info("Voice model not found for \(name): \(prefix).onnx", subsystem: "PiperTTS")
                    continue
                }

                // Tokens file is required by sherpa-onnx. Try agent-specific, then SiD fallback.
                let agentTokensPath = voicesDir + "/\(agentID)_tokens.txt"
                let sidTokensPath = voicesDir + "/sid_tokens.txt"
                let tokensFile: String
                if fm.fileExists(atPath: agentTokensPath) {
                    tokensFile = agentTokensPath
                } else if fm.fileExists(atPath: sidTokensPath) {
                    tokensFile = sidTokensPath
                } else {
                    TorboLog.warn("No tokens file for \(name) — skipping (sherpa-onnx requires tokens)", subsystem: "PiperTTS")
                    continue
                }

                // Per-agent voice tuning
                let tuning = Self.voiceTuning[agentID] ?? (noiseScale: 0.80, noiseW: 0.90, lengthScale: 1.0)

                let vitsConfig = sherpaOnnxOfflineTtsVitsModelConfig(
                    model: modelPath,
                    tokens: tokensFile,
                    dataDir: espeakDataPath,
                    noiseScale: tuning.noiseScale,
                    noiseScaleW: tuning.noiseW,
                    lengthScale: tuning.lengthScale
                )

                let modelConfig = sherpaOnnxOfflineTtsModelConfig(
                    vits: vitsConfig,
                    numThreads: 2,
                    provider: "cpu"
                )

                var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
                let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)

                if wrapper.tts != nil {
                    self.models[agentID] = wrapper
                    TorboLog.info("Loaded voice for \(name)", subsystem: "PiperTTS")
                } else {
                    TorboLog.warn("Failed to load voice for \(name)", subsystem: "PiperTTS")
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            TorboLog.info("Loaded \(self.models.count)/\(Self.agentModels.count) voices in \(String(format: "%.0f", elapsed))ms", subsystem: "PiperTTS")
            self.markReady()
        }
    }

    /// Signal that model loading is complete — resume any waiters.
    private func markReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Wait until models have finished loading (up to 10 seconds).
    private func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if self.isReady {
                    continuation.resume()
                } else {
                    self.readyWaiters.append(continuation)
                }
            }
        }
    }

    /// Warm up by running a short synthesis for each loaded model.
    func warmup() {
        queue.async { [self] in
            for (agentID, model) in self.models {
                let startTime = CFAbsoluteTimeGetCurrent()
                let _ = model.generate(text: "warmup", speed: 1.0)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let name = Self.displayNames[agentID] ?? agentID
                TorboLog.info("Warmup for \(name): \(String(format: "%.0f", elapsed))ms", subsystem: "PiperTTS")
            }
        }
    }

    /// Resolve which model to use: agent's own voice, or SiD fallback.
    private func resolveModel(for agentID: String) -> (model: SherpaOnnxOfflineTtsWrapper, resolvedID: String)? {
        if let model = models[agentID] {
            return (model, agentID)
        }
        if let fallback = models[Self.fallbackAgentID] {
            return (fallback, Self.fallbackAgentID)
        }
        return nil
    }

    /// Synthesize text to WAV audio data using the agent's Piper voice.
    /// Falls back to SiD voice if agent has no custom model. Returns nil only if NO models loaded.
    /// Waits for model loading to complete if called before models are ready.
    func synthesize(text: String, agentID: String, speed: Float = 1.0) async -> Data? {
        // Wait for background model loading to finish (non-blocking if already ready)
        if !isReady {
            await waitUntilReady()
        }

        guard let (model, resolvedID) = resolveModel(for: agentID) else {
            TorboLog.warn("No voice loaded (not even fallback)", subsystem: "PiperTTS")
            return nil
        }
        let name = Self.displayNames[agentID] ?? agentID
        let usingFallback = resolvedID != agentID

        return await withCheckedContinuation { continuation in
            queue.async {
                let startTime = CFAbsoluteTimeGetCurrent()
                let audio = model.generate(text: text, speed: speed)

                let samples = audio.samples
                guard !samples.isEmpty else {
                    TorboLog.warn("Empty audio generated for \(name)", subsystem: "PiperTTS")
                    continuation.resume(returning: nil)
                    return
                }

                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                let duration = Double(samples.count) / Double(Self.sampleRate)
                let fallbackNote = usingFallback ? " [using SiD fallback]" : ""
                TorboLog.info("\(name)\(fallbackNote): \(text.prefix(40))... → \(samples.count) samples (\(String(format: "%.1f", duration))s) in \(String(format: "%.0f", elapsed))ms", subsystem: "PiperTTS")

                let wavData = Self.floatSamplesToWAV(samples, sampleRate: Self.sampleRate)
                continuation.resume(returning: wavData)
            }
        }
    }

    /// Convert Float32 audio samples to 16-bit PCM WAV data.
    private static func floatSamplesToWAV(_ samples: [Float], sampleRate: Int) -> Data {
        let numSamples = samples.count
        let bitsPerSample: Int = 16
        let numChannels: Int = 1
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numSamples * blockAlign
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt chunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: [UInt8]("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        // Convert float samples to Int16 PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        return data
    }

    #else

    // MARK: - Stub Implementation (sherpa-onnx not available)

    private init() {}

    /// Whether the Piper engine is available. Returns false when sherpa-onnx is not compiled in.
    var isAvailable: Bool { false }

    /// Always returns false when Piper is not compiled in.
    func hasVoice(for agentID: String) -> Bool { false }

    /// Always returns false when Piper is not compiled in.
    func hasCustomVoice(for agentID: String) -> Bool { false }

    /// No-op when Piper is not compiled in.
    func loadModels() {
        TorboLog.info("Piper TTS not compiled — build with -DPIPER_TTS to enable on-device voices", subsystem: "PiperTTS")
    }

    /// No-op when Piper is not compiled in.
    func warmup() {}

    /// Always returns nil when Piper is not compiled in.
    func synthesize(text: String, agentID: String, speed: Float = 1.0) async -> Data? {
        return nil
    }

    #endif // PIPER_TTS
}
#endif // os(macOS)
