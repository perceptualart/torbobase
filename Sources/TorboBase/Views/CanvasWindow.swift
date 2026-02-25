// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Canvas Window
// Floating workspace for notes, generated content, and agent output.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

struct CanvasWindow: View {
    @State private var content: String = ""
    @State private var title: String = "Untitled"
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))

                if isEditing {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .onSubmit { isEditing = false }
                } else {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .onTapGesture { isEditing = true }
                }

                Spacer()

                Text("\(content.count) chars")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Copy all")

                Button {
                    content = ""
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().overlay(Color.white.opacity(0.06))

            // Editor
            TextEditor(text: $content)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .preferredColorScheme(.dark)
    }
}
#endif
