// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — SherpaOnnxTTS
// Minimal TTS wrapper from sherpa-onnx for Piper VITS models.
// Source: https://github.com/k2-fsa/sherpa-onnx (Apache 2.0 license)
// Only TTS-relevant code extracted. Requires PIPER_TTS build flag + sherpa-onnx macOS libs.

#if PIPER_TTS
import Foundation
import CSherpaOnnx

// MARK: - C String Helper

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
    let cs = (s as NSString).utf8String
    return UnsafePointer<Int8>(cs)
}

// MARK: - Config Builders

func sherpaOnnxOfflineTtsVitsModelConfig(
    model: String = "",
    lexicon: String = "",
    tokens: String = "",
    dataDir: String = "",
    noiseScale: Float = 0.667,
    noiseScaleW: Float = 0.8,
    lengthScale: Float = 1.0,
    dictDir: String = ""
) -> SherpaOnnxOfflineTtsVitsModelConfig {
    return SherpaOnnxOfflineTtsVitsModelConfig(
        model: toCPointer(model),
        lexicon: toCPointer(lexicon),
        tokens: toCPointer(tokens),
        data_dir: toCPointer(dataDir),
        noise_scale: noiseScale,
        noise_scale_w: noiseScaleW,
        length_scale: lengthScale,
        dict_dir: toCPointer(dictDir)
    )
}

func sherpaOnnxOfflineTtsModelConfig(
    vits: SherpaOnnxOfflineTtsVitsModelConfig = sherpaOnnxOfflineTtsVitsModelConfig(),
    numThreads: Int = 2,
    debug: Int = 0,
    provider: String = "cpu"
) -> SherpaOnnxOfflineTtsModelConfig {
    return SherpaOnnxOfflineTtsModelConfig(
        vits: vits,
        num_threads: Int32(numThreads),
        debug: Int32(debug),
        provider: toCPointer(provider),
        matcha: SherpaOnnxOfflineTtsMatchaModelConfig(),
        kokoro: SherpaOnnxOfflineTtsKokoroModelConfig(),
        kitten: SherpaOnnxOfflineTtsKittenModelConfig(),
        zipvoice: SherpaOnnxOfflineTtsZipvoiceModelConfig(),
        pocket: SherpaOnnxOfflineTtsPocketModelConfig()
    )
}

func sherpaOnnxOfflineTtsConfig(
    model: SherpaOnnxOfflineTtsModelConfig,
    ruleFsts: String = "",
    ruleFars: String = "",
    maxNumSentences: Int = 1,
    silenceScale: Float = 0.2
) -> SherpaOnnxOfflineTtsConfig {
    return SherpaOnnxOfflineTtsConfig(
        model: model,
        rule_fsts: toCPointer(ruleFsts),
        max_num_sentences: Int32(maxNumSentences),
        rule_fars: toCPointer(ruleFars),
        silence_scale: silenceScale
    )
}

// MARK: - Generated Audio Wrapper

class SherpaOnnxGeneratedAudioWrapper {
    let audio: UnsafePointer<SherpaOnnxGeneratedAudio>!

    init(audio: UnsafePointer<SherpaOnnxGeneratedAudio>!) {
        self.audio = audio
    }

    deinit {
        if let audio {
            SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
        }
    }

    var n: Int32 { audio.pointee.n }
    var sampleRate: Int32 { audio.pointee.sample_rate }

    var samples: [Float] {
        if let p = audio.pointee.samples {
            return [Float](UnsafeBufferPointer(start: p, count: Int(n)))
        }
        return []
    }

    func save(filename: String) -> Int32 {
        return SherpaOnnxWriteWave(audio.pointee.samples, n, sampleRate, toCPointer(filename))
    }
}

// MARK: - TTS Wrapper

class SherpaOnnxOfflineTtsWrapper {
    let tts: OpaquePointer!

    init(config: UnsafePointer<SherpaOnnxOfflineTtsConfig>!) {
        tts = SherpaOnnxCreateOfflineTts(config)
    }

    deinit {
        if let tts {
            SherpaOnnxDestroyOfflineTts(tts)
        }
    }

    func generate(text: String, sid: Int = 0, speed: Float = 1.0) -> SherpaOnnxGeneratedAudioWrapper {
        let audio = SherpaOnnxOfflineTtsGenerate(tts, toCPointer(text), Int32(sid), speed)
        return SherpaOnnxGeneratedAudioWrapper(audio: audio)
    }
}

#endif // PIPER_TTS
