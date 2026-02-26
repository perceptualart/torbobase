// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Perceptual AI
// Ported from Torbo iOS — aurora silk ribbon orb renderer
#if canImport(SwiftUI)
import SwiftUI

/// Beautiful flowing orb with aurora-like silk ribbons — macOS version
struct OrbRenderer: View {
    let audioLevels: [Float]
    let color: Color
    let isActive: Bool
    /// When set, uses this fixed radius instead of deriving from Canvas size.
    /// Allows a large Canvas frame for petal/blur overflow while keeping a controlled orb size.
    var orbRadius: CGFloat? = nil

    @State private var smoothLevel: Float = 0.15
    @State private var targetLevel: Float = 0.15
    @State private var appearScale: CGFloat = 0.001
    @State private var breathePhase: Double = 0
    @State private var lastLevelUpdate: Date = .distantPast
    /// Random per-instance seed — every orb starts at a unique hue offset so no two look alike
    @State private var instanceSeed: Double = Double.random(in: 0...1000)

    /// Canvas frame size — when orbRadius is set, we make the canvas big enough for petals + blur.
    private var canvasFrame: CGFloat? {
        guard let r = orbRadius else { return nil }
        return r * 6.0  // ~3x radius on each side of center — room for all petal extensions + blur
    }

    private func wrapHue(_ h: Double) -> Double { h - floor(h) }

    /// All 7 layers share one rotation speed with golden-ratio offsets (~0.618 apart),
    /// guaranteeing permanent maximum separation — no two petals can ever match.
    /// A subtle per-layer sine wobble adds organic breathing without convergence.
    /// `instanceSeed` offsets the base rotation so every orb instance has unique colors.
    private func palette(at t: Double) -> [(hue: Double, sat: Double, bri: Double)] {
        let phi = 0.6180339887498949 // golden ratio conjugate
        let baseRotation = t * 0.025 + instanceSeed // seed makes each orb unique
        // Tiny per-layer wobble rates (different primes keep them out of sync)
        let wobbleSpeeds: [Double] = [0.11, 0.13, 0.17, 0.19, 0.23, 0.29, 0.31]
        return (0..<7).map { i in
            let offset = Double(i) * phi
            let wobble = sin(t * wobbleSpeeds[i]) * 0.03 // ±3% hue — never enough to overlap
            return (wrapHue(baseRotation + offset + wobble), 1.0, 1.0)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            // Canvas with explicit frame when orbRadius is set — prevents petal clipping
            canvas(t: t)
        }
        .scaleEffect(appearScale)
        .onChange(of: audioLevels) { newLevels in
            // Throttle to ~15Hz — matches iOS, prevents frame-sync glitches
            let now = Date()
            guard now.timeIntervalSince(lastLevelUpdate) >= 0.065 else { return }
            lastLevelUpdate = now
            targetLevel = calculateSmoothedLevel(from: newLevels)
        }
        .onChange(of: targetLevel) { newTarget in
            withAnimation(.interpolatingSpring(stiffness: 25, damping: 8)) {
                smoothLevel = newTarget
            }
        }
        .onAppear {
            smoothLevel = calculateSmoothedLevel(from: audioLevels)
            targetLevel = smoothLevel
            withAnimation(.easeOut(duration: 0.8)) {
                appearScale = 1.0
            }
        }
    }

    @ViewBuilder
    private func canvas(t: Double) -> some View {
        let cv = Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = orbRadius ?? min(size.width, size.height) * 0.45

            let level = smoothLevel
            let restingScale: CGFloat = 0.85
            let breathe = CGFloat(sin(t * 0.8) * 0.02 + cos(t * 0.5) * 0.015)
            let audioBoost: CGFloat = CGFloat(max(0, level - 0.1)) * 0.4
            let audioScale: CGFloat = restingScale + audioBoost + breathe
            let radius = baseRadius * min(audioScale, 1.15)
            let intensity = Double(max(0, level - 0.08)) * 2.0
            let p = palette(at: t)

            // Layer 1: Deep outer glow — slow drift
            drawAuroraRibbon(context: context, center: center, radius: radius * 1.18,
                            color: Color(hue: p[0].hue, saturation: p[0].sat, brightness: p[0].bri),
                            phase: t * 0.15, wavePhase: t * 0.4,
                            scaleX: 1.12, scaleY: 0.48, rotation: t * 0.025,
                            intensity: intensity, blur: 22, opacity: 0.10)

            // Layer 2: Warm flowing ribbon
            drawAuroraRibbon(context: context, center: center, radius: radius * 1.05,
                            color: Color(hue: p[1].hue, saturation: p[1].sat, brightness: p[1].bri),
                            phase: t * 0.22, wavePhase: t * 0.55,
                            scaleX: 1.0, scaleY: 0.52, rotation: t * 0.035,
                            intensity: intensity, blur: 16, opacity: 0.15)

            // Layer 3: Cross-flowing ribbon
            drawAuroraRibbon(context: context, center: center, radius: radius * 0.95,
                            color: Color(hue: p[2].hue, saturation: p[2].sat, brightness: p[2].bri),
                            phase: t * 0.18 + 1.5, wavePhase: t * 0.48 + 2,
                            scaleX: 0.88, scaleY: 0.68, rotation: t * 0.03 + .pi * 0.3,
                            intensity: intensity, blur: 12, opacity: 0.18)

            // Layer 4: Active mid ribbon
            drawAuroraRibbon(context: context, center: center, radius: radius * 0.88,
                            color: Color(hue: p[3].hue, saturation: p[3].sat, brightness: p[3].bri),
                            phase: t * 0.25 + 3, wavePhase: t * 0.6 + 1,
                            scaleX: 0.78, scaleY: 0.82, rotation: t * 0.04 + .pi * 0.7,
                            intensity: intensity, blur: 9, opacity: 0.22)

            // Layer 5: Bright inner ribbon
            drawAuroraRibbon(context: context, center: center, radius: radius * 0.82,
                            color: Color(hue: p[4].hue, saturation: p[4].sat, brightness: p[4].bri),
                            phase: t * 0.2 + 2, wavePhase: t * 0.5 + 3,
                            scaleX: 0.72, scaleY: 0.78, rotation: t * 0.045 + .pi * 1.1,
                            intensity: intensity, blur: 7, opacity: 0.20)

            // Layer 6: Vivid accent
            drawAuroraRibbon(context: context, center: center, radius: radius * 0.72,
                            color: Color(hue: p[5].hue, saturation: p[5].sat, brightness: p[5].bri),
                            phase: t * 0.28 + 4, wavePhase: t * 0.65 + 2,
                            scaleX: 0.62, scaleY: 0.72, rotation: t * 0.05 + .pi * 0.5,
                            intensity: intensity, blur: 5, opacity: 0.20)

            // Layer 7: Inner core glow
            drawAuroraRibbon(context: context, center: center, radius: radius * 0.58,
                            color: Color(hue: p[6].hue, saturation: p[6].sat, brightness: p[6].bri),
                            phase: t * 0.2 + 1, wavePhase: t * 0.52 + 4,
                            scaleX: 0.55, scaleY: 0.62, rotation: t * 0.055 + .pi * 1.4,
                            intensity: intensity, blur: 3, opacity: 0.22)
        }

        if let cs = canvasFrame {
            cv.frame(width: cs, height: cs)
        } else {
            cv
        }
    }

    /// Matches iOS: last 6 samples, powers-of-2 weighting, clamped [0.1, 1.0]
    private func calculateSmoothedLevel(from levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0.15 }
        let count = min(6, levels.count)
        let recent = Array(levels.suffix(count))
        var weighted: Float = 0
        var weightSum: Float = 0
        for (i, level) in recent.enumerated() {
            let weight = Float(pow(2.0, Double(i)))  // 1, 2, 4, 8, 16, 32
            weighted += level * weight
            weightSum += weight
        }
        let avg = weighted / weightSum
        return max(0.1, min(1.0, avg))
    }

    private func drawAuroraRibbon(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                                   color: Color, phase: Double, wavePhase: Double,
                                   scaleX: CGFloat, scaleY: CGFloat, rotation: Double,
                                   intensity: Double, blur: CGFloat, opacity: Double) {
        var path = Path()
        let segments = 80

        for i in 0...segments {
            let angle = Double(i) / Double(segments) * .pi * 2
            // Organic wave composition — multiple harmonics
            let wave1 = sin(angle * 2 + phase) * 0.22
            let wave2 = sin(angle * 3 + wavePhase) * 0.16
            let wave3 = cos(angle * 5 + phase * 0.7) * 0.09
            let wave4 = sin(angle * 1.5 + wavePhase * 1.2) * 0.13
            let wave5 = cos(angle * 4 + phase * 1.5) * 0.06
            // Audio-reactive perturbation — more dramatic
            let audioPulse = sin(angle * 2 + phase * 3.5) * intensity * 0.30
            let audioPulse2 = cos(angle * 3 + wavePhase * 2.5) * intensity * 0.22
            let audioPulse3 = sin(angle * 5 + phase * 4.5) * intensity * 0.15
            let audioPulse4 = cos(angle * 7 + wavePhase * 3) * intensity * 0.10
            let waveSum = wave1 + wave2 + wave3 + wave4 + wave5 + audioPulse + audioPulse2 + audioPulse3 + audioPulse4
            let r = Double(radius) * (0.55 + waveSum)
            let breatheX = Double(scaleX) * (1.0 + sin(wavePhase * 0.4) * 0.06)
            let breatheY = Double(scaleY) * (1.0 + cos(wavePhase * 0.35) * 0.06)
            let x = cos(angle) * r * breatheX
            let y = sin(angle) * r * breatheY
            let rotatedX = x * cos(rotation) - y * sin(rotation)
            let rotatedY = x * sin(rotation) + y * cos(rotation)
            let point = CGPoint(x: center.x + rotatedX, y: center.y + rotatedY)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()

        var glowCtx = context
        glowCtx.blendMode = .plusLighter
        glowCtx.addFilter(.blur(radius: blur))
        glowCtx.fill(path, with: .color(color.opacity(opacity)))

        var coreCtx = context
        coreCtx.blendMode = .plusLighter
        coreCtx.addFilter(.blur(radius: blur * 0.35))
        coreCtx.fill(path, with: .color(color.opacity(opacity * 0.4)))
    }

}
#endif
