# Phase 6.1 — Piper TTS Postponed

**Date:** 2026-02-26
**Status:** POSTPONED (compiles, does not run)

---

## What Was Built

Piper TTS on-device voice synthesis was fully integrated:

- `PiperTTSEngine.swift` — Singleton engine with per-agent ONNX voice models
- `SherpaOnnxTTS.swift` — C API bridge for sherpa-onnx
- `CSherpaOnnx` module — C header, module map, shim for SPM
- `Package.swift` — CSherpaOnnx target, `PIPER_TTS` build flag, linker settings
- `TTSManager.swift` — "torbo" engine path calling PiperTTSEngine
- Voice models deployed: SiD (63.5 MB) + Orion (63.5 MB) + espeak-ng-data (25 MB)
- sherpa-onnx v1.12.26 macOS universal2 dylibs (libsherpa-onnx-c-api + libonnxruntime)

All code compiles cleanly behind `#if PIPER_TTS` conditional compilation flag.

---

## Why It Was Postponed

**Root cause:** sherpa-onnx ONNX model initialization blocks the main thread.

When `PIPER_TTS` is enabled:
1. The binary links against `libsherpa-onnx-c-api.dylib` and `libonnxruntime.dylib`
2. At launch, the ONNX runtime initializes (loading ~63 MB model files)
3. This initialization happens synchronously during the SwiftUI scene setup phase
4. macOS detects the app is unresponsive and terminates it within ~1 second

**Evidence:**
- The sherpa-onnx C++ message `'n_speakers' does not exist in the metadata` appears in stdout, confirming the model loads
- The app prints `[Pairing] Loaded 10 paired device(s)` but never reaches `[ConvStore]` or gateway startup
- System log shows `CoreAnalytics: Entering exit handler` within 0.8 seconds of launch
- No crash report generated — clean exit, not a crash
- Original dist binary (without PIPER_TTS) runs perfectly
- New binary with PIPER_TTS enabled exits immediately on every launch attempt

**Not the cause:**
- dylib loading works (confirmed via `otool`, files present at rpath)
- Code compiles with zero errors
- Voice models are valid (sherpa-onnx CLI tool loads them, though synthesis has a separate issue)

---

## What Needs to Change for Phase 6.1

### 1. Async Model Loading
Move `PiperTTSEngine.shared.loadModels()` out of `TTSManager.init()` and into a background task:

```swift
// Instead of blocking init:
// PiperTTSEngine.shared.loadModels()  // BLOCKS main thread

// Use deferred async loading:
Task.detached(priority: .utility) {
    PiperTTSEngine.shared.loadModels()
    PiperTTSEngine.shared.warmup()
}
```

### 2. Lazy dylib Loading
Consider using `dlopen()` instead of static linking so the ONNX runtime doesn't initialize at process start:

```swift
// Load sherpa-onnx on demand, not at launch
let handle = dlopen("@rpath/libsherpa-onnx-c-api.dylib", RTLD_LAZY)
```

### 3. Voice Model Compatibility
The SiD/Orion ONNX models may need retraining or version matching:
- sherpa-onnx CLI tool loads models but exits with code 255 during synthesis
- The `n_speakers` metadata warning suggests single-speaker models (expected for custom voices)
- May need to test with sherpa-onnx version matching the iOS app's framework

### 4. Re-enable in Package.swift
Uncomment the Piper TTS block in `Package.swift` (currently commented out with `/* ... */`).

---

## Current State

| Component | Status |
|-----------|--------|
| `PiperTTSEngine.swift` | Compiles (behind `#if PIPER_TTS`) |
| `SherpaOnnxTTS.swift` | Compiles (behind `#if PIPER_TTS`) |
| `CSherpaOnnx` module | Present in Sources/ (unused when flag disabled) |
| `TTSManager.swift` "torbo" path | Falls back to system voice when `PIPER_TTS` not defined |
| Voice models | Deployed to `~/Library/Application Support/TorboBase/voices/` |
| sherpa-onnx dylibs | Present in `Frameworks/macOS/` (not linked) |
| Vox Engine UI "TORBO" button | Shows in UI, selects "torbo" engine (falls back gracefully) |

**The "torbo" voice engine selection works in the UI.** When a user selects it, the TTSManager falls back to system voice (AVSpeech) since PIPER_TTS is not compiled in. Once Phase 6.1 enables it, the same code path will use Piper instead.

---

## Files to Touch in Phase 6.1

1. `Package.swift` — Uncomment PIPER_TTS block
2. `TTSManager.swift` — Move loadModels/warmup to async Task
3. `PiperTTSEngine.swift` — Possibly switch to dlopen-based loading
4. Test voice model compatibility with sherpa-onnx v1.12.26

**Estimated effort:** 2-4 hours (mostly debugging the async initialization timing)
