// ORB Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Ported from ORB iOS — aurora silk ribbon orb renderer
import SwiftUI

/// Beautiful flowing orb with aurora-like silk ribbons — macOS version
struct OrbRenderer: View {
    let audioLevels: [Float]
    let color: Color
    let isActive: Bool

    @State private var smoothLevel: Float = 0.15
    @State private var targetLevel: Float = 0.15
    @State private var appearScale: CGFloat = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseRadius = min(size.width, size.height) * 0.45

                let level = smoothLevel
                let restingScale: CGFloat = 0.85
                let audioBoost: CGFloat = CGFloat(max(0, level - 0.1)) * 0.3
                let audioScale: CGFloat = restingScale + audioBoost
                let radius = baseRadius * min(audioScale, 1.1)
                let intensity = Double(max(0, level - 0.1)) * 1.5

                // Layer 1: Deep outer glow — magenta
                drawAuroraRibbon(context: context, center: center, radius: radius * 1.15,
                                color: Color(hue: 0.85, saturation: 0.8, brightness: 0.9),
                                phase: t * 0.08, wavePhase: t * 0.25,
                                scaleX: 1.1, scaleY: 0.45, rotation: t * 0.015,
                                intensity: intensity, blur: 18, opacity: 0.12)

                // Layer 2: Red ribbon
                drawAuroraRibbon(context: context, center: center, radius: radius,
                                color: Color(hue: 0.0, saturation: 0.85, brightness: 1.0),
                                phase: t * 0.12, wavePhase: t * 0.35,
                                scaleX: 1.0, scaleY: 0.5, rotation: t * 0.02,
                                intensity: intensity, blur: 12, opacity: 0.18)

                // Layer 3: Orange ribbon
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.95,
                                color: Color(hue: 0.08, saturation: 0.9, brightness: 1.0),
                                phase: t * 0.1 + 1.5, wavePhase: t * 0.3 + 2,
                                scaleX: 0.85, scaleY: 0.65, rotation: t * 0.018 + .pi * 0.3,
                                intensity: intensity, blur: 10, opacity: 0.2)

                // Layer 4: Cyan ribbon
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.9,
                                color: Color(hue: 0.52, saturation: 0.9, brightness: 1.0),
                                phase: t * 0.14 + 3, wavePhase: t * 0.4 + 1,
                                scaleX: 0.75, scaleY: 0.8, rotation: t * 0.022 + .pi * 0.7,
                                intensity: intensity, blur: 8, opacity: 0.22)

                // Layer 5: Blue ribbon
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.85,
                                color: Color(hue: 0.6, saturation: 0.85, brightness: 1.0),
                                phase: t * 0.09 + 2, wavePhase: t * 0.28 + 3,
                                scaleX: 0.7, scaleY: 0.75, rotation: t * 0.025 + .pi * 1.1,
                                intensity: intensity, blur: 6, opacity: 0.25)

                // Layer 6: Purple core ribbon
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.75,
                                color: Color(hue: 0.75, saturation: 0.8, brightness: 1.0),
                                phase: t * 0.16 + 4, wavePhase: t * 0.45 + 2,
                                scaleX: 0.6, scaleY: 0.7, rotation: t * 0.028 + .pi * 0.5,
                                intensity: intensity, blur: 4, opacity: 0.28)

                // Layer 7: Pink inner glow
                drawAuroraRibbon(context: context, center: center, radius: radius * 0.6,
                                color: Color(hue: 0.92, saturation: 0.7, brightness: 1.0),
                                phase: t * 0.11 + 1, wavePhase: t * 0.32 + 4,
                                scaleX: 0.55, scaleY: 0.6, rotation: t * 0.03 + .pi * 1.4,
                                intensity: intensity, blur: 3, opacity: 0.3)
            }
        }
        .scaleEffect(appearScale)
        .onChange(of: audioLevels) { _, newLevels in
            targetLevel = calculateSmoothedLevel(from: newLevels)
        }
        .onChange(of: targetLevel) { _, newTarget in
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
