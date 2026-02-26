// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Canvas Window
// Floating workspace for notes, generated content, and agent output.
// Agents can push content here via the canvas_write tool.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// Shared store so agent tools can push content to the Canvas window.
@MainActor
final class CanvasStore: ObservableObject {
    static let shared = CanvasStore()

    @Published var content: String = ""
    @Published var title: String = "Untitled"

    /// Called by agent tools to write content to the canvas and open the window.
    func write(title: String, content: String, append: Bool = false) {
        self.title = title
        if append {
            if !self.content.isEmpty { self.content += "\n\n" }
            self.content += content
        } else {
            self.content = content
        }
        // Open the canvas window
        WindowOpener.openWindow?(id: "canvas")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CanvasWindow: View {
    @ObservedObject private var store = CanvasStore.shared
    @State private var isEditing = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))

                if isEditing {
                    TextField("Title", text: $store.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .onSubmit { isEditing = false }
                } else {
                    Text(store.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .onTapGesture { isEditing = true }
                }

                Spacer()

                Text("\(store.content.count) chars")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Copy all")

                Button {
                    store.content = ""
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
            TextEditor(text: $store.content)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .preferredColorScheme(.dark)
    }
}
#endif
