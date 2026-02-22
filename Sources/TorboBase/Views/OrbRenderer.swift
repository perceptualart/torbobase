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
    var baseHue: Double? = nil
    var baseSaturation: Double = 0.85

    @State private var smoothLevel: Float = 0.15
    @State private var targetLevel: Float = 0.15
    @State private var appearScale: CGFloat = 0.001

    private func wrapHue(_ h: Double) -> Double { h - floor(h) }

    private var palette: [(hue: Double, sat: Double, bri: Double)] {
        if let bh = baseHue {
            let s = baseSaturation
            return [
                (wrapHue(bh - 0.10), s * 0.9,  0.9),
                (wrapHue(bh - 0.05), s,         1.0),
                (wrapHue(bh + 0.03), s,         1.0),
                (wrapHue(bh + 0.08), s,         1.0),
                (wrapHue(bh - 0.12), s * 0.95,  1.0),
                (wrapHue(bh + 0.15), s * 0.9,   1.0),
                (wrapHue(bh),        s * 0.8,   1.0),
            ]
        } else {
            return [
                (0.85, 0.8,  0.9), (0.0, 0.85, 1.0), (0.08, 0.9, 1.0),
                (0.12, 0.9,  1.0), (0.9, 0.85, 1.0), (0.75, 0.8, 1.0),
                (0.92, 0.7,  1.0),
            ]
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                // Guard against zero-size frames during initial layout —
                // applying transforms/scales to a zero-dimension view produces
                // a singular CGAffineTransform that crashes on Intel Macs.
                guard size.width > 1, size.height > 1 else { return }

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseRadius = min(size.width, size.height) * 0.45

                let level = smoothLevel
                let restingScale: CGFloat = 0.85
                let audioBoost: CGFloat = CGFloat(max(0, level - 0.1)) * 0.3
                let audioScale: CGFloat = restingScale + audioBoost
                let radius = baseRadius * min(audioScale, 1.1)
                let intensity = Double(max(0, level - 0.1)) * 1.5
                let p = palette

                // Layer 1: Deep outer glow
                drawAuroraRibbon(context: context, center: center, radius: radius * 1.15,
                                color: Color(hue: p[0].hue, saturation: p[0].sat, brightness: p[0].bri),
                                phase: t * 0.08, wavePhase: t * 0.25,
                                scaleX: 1.1, scaleY: 0.45, rotation: t * 0.015,
                                intensity: intensity, blur: 18, opacity: 0.12)

                // Layer 2
                drawAuroraRibbon(context: context, center: center, radius: radius,
                                color: Color(hue: p[1].hue, saturation: p[1].sat, brightness: p[1].bri),
                                phase: t * 0.12, wavePhase: t * 0.35,
                                scaleX: 1.0, scaleY: 0.5, rotation: t * 0.02,
                                intensity: intensity, blur: 12, opacity: 0.18)

                // Layer 3
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.95,
                                color: Color(hue: p[2].hue, saturation: p[2].sat, brightness: p[2].bri),
                                phase: t * 0.1 + 1.5, wavePhase: t * 0.3 + 2,
                                scaleX: 0.85, scaleY: 0.65, rotation: t * 0.018 + .pi * 0.3,
                                intensity: intensity, blur: 10, opacity: 0.2)

                // Layer 4
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.9,
                                color: Color(hue: p[3].hue, saturation: p[3].sat, brightness: p[3].bri),
                                phase: t * 0.14 + 3, wavePhase: t * 0.4 + 1,
                                scaleX: 0.75, scaleY: 0.8, rotation: t * 0.022 + .pi * 0.7,
                                intensity: intensity, blur: 8, opacity: 0.22)

                // Layer 5
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.85,
                                color: Color(hue: p[4].hue, saturation: p[4].sat, brightness: p[4].bri),
                                phase: t * 0.09 + 2, wavePhase: t * 0.28 + 3,
                                scaleX: 0.7, scaleY: 0.75, rotation: t * 0.025 + .pi * 1.1,
                                intensity: intensity, blur: 6, opacity: 0.25)

                // Layer 6
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.75,
                                color: Color(hue: p[5].hue, saturation: p[5].sat, brightness: p[5].bri),
                                phase: t * 0.16 + 4, wavePhase: t * 0.45 + 2,
                                scaleX: 0.6, scaleY: 0.7, rotation: t * 0.028 + .pi * 0.5,
                                intensity: intensity, blur: 4, opacity: 0.28)

                // Layer 7: Inner glow
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.6,
                                color: Color(hue: p[6].hue, saturation: p[6].sat, brightness: p[6].bri),
                                phase: t * 0.11 + 1, wavePhase: t * 0.32 + 4,
                                scaleX: 0.55, scaleY: 0.6, rotation: t * 0.03 + .pi * 1.4,
                                intensity: intensity, blur: 3, opacity: 0.3)
            }
        }
        .scaleEffect(appearScale)
        .onChange(of: audioLevels) { newLevels in
            targetLevel = calculateSmoothedLevel(from: newLevels)
        }
        .onChange(of: targetLevel) { newTarget in
            withAnimation(.easeOut(duration: 0.08)) {
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

    private func calculateSmoothedLevel(from levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0.15 }
        let count = min(6, levels.count)
        let recent = Array(levels.suffix(count))
        var weighted: Float = 0
        var weightSum: Float = 0
        for (i, level) in recent.enumerated() {
            let weight = Float(pow(2.0, Double(i)))
            weighted += level * weight
            weightSum += weight
        }
        return max(0.1, min(1.0, weighted / weightSum))
    }

    private func drawAuroraRibbon(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                                   color: Color, phase: Double, wavePhase: Double,
                                   scaleX: CGFloat, scaleY: CGFloat, rotation: Double,
                                   intensity: Double, blur: CGFloat, opacity: Double) {
        var path = Path()
        let segments = 64

        for i in 0...segments {
            let angle = Double(i) / Double(segments) * .pi * 2
            let wave1 = sin(angle * 2 + phase) * 0.25
            let wave2 = sin(angle * 3 + wavePhase) * 0.18
            let wave3 = cos(angle * 4 + phase * 0.8) * 0.12
            let wave4 = sin(angle * 1.5 + wavePhase * 1.3) * 0.15
            let audioPulse = sin(angle * 2 + phase * 3) * intensity * 0.35
            let audioPulse2 = cos(angle * 3 + wavePhase * 2) * intensity * 0.25
            let audioPulse3 = sin(angle * 5 + phase * 4) * intensity * 0.18
            let waveSum = wave1 + wave2 + wave3 + wave4 + audioPulse + audioPulse2 + audioPulse3
            let r = Double(radius) * (0.55 + waveSum)
            let breatheX = Double(scaleX) * (1.0 + sin(wavePhase * 0.3) * 0.08)
            let breatheY = Double(scaleY) * (1.0 + cos(wavePhase * 0.25) * 0.08)
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
        coreCtx.addFilter(.blur(radius: blur * 0.4))
        coreCtx.fill(path, with: .color(color.opacity(opacity * 0.49)))
    }
}
#endif
