// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
#if canImport(SwiftUI)
import SwiftUI

struct EULAView: View {
    var onAccept: () -> Void

    @State private var hasReadEnough = false

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with orb
                VStack(spacing: 12) {
                    OrbRenderer(
                        audioLevels: Array(repeating: Float(0.15), count: 40),
                        color: Color(hue: 0.52, saturation: 0.9, brightness: 1.0),
                        isActive: false
                    )
                    .frame(width: 64, height: 64)

                    Text("License Agreement")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Please read before using Torbo Base")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 28)
                .padding(.bottom, 16)

                Divider().overlay(Color.white.opacity(0.06))

                // EULA text
                ScrollView {
                    Text(Legal.eulaText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear.frame(height: 1)
                        .onAppear { hasReadEnough = true }
                }
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider().overlay(Color.white.opacity(0.06))

                // Privacy badge
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.green)
                    Text("Torbo Base collects zero data. Everything stays on your device.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.vertical, 10)

                // Buttons
                HStack(spacing: 16) {
                    Button("Decline") {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.white.opacity(0.5))

                    Button {
                        Legal.eulaAccepted = true
                        onAccept()
                    } label: {
                        Text("Accept")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(Color.cyan)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasReadEnough)
                    .opacity(hasReadEnough ? 1 : 0.4)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 520, height: 560)
        .preferredColorScheme(.dark)
    }
}
#endif
