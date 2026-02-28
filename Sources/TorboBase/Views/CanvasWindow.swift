// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Canvas Window
// Floating workspace for notes, generated content, and agent output.
// Agents can push content here via the canvas_write tool.
// Includes a live Preview mode for HTML/CSS/JS rendering via WKWebView.

#if canImport(SwiftUI)
import SwiftUI

/// Shared store so agent tools can push content to the Canvas window.
/// Cross-platform: macOS uses WindowOpener, iOS uses isPresented sheet binding.
@MainActor
final class CanvasStore: ObservableObject {
    static let shared = CanvasStore()

    @Published var content: String = ""
    @Published var title: String = "Untitled"
    @Published var isPresented: Bool = false

    /// Per-agent canvas snapshots: agentID -> (title, content)
    private var agentSnapshots: [String: (title: String, content: String)] = [:]
    /// Currently active agent ID (for snapshot tracking)
    private var activeAgentID: String?

    /// Returns current canvas state if non-empty
    func captureState() -> (title: String, content: String)? {
        guard !content.isEmpty else { return nil }
        return (title, content)
    }

    /// Saves current canvas for the active agent, loads the new agent's canvas.
    func switchAgent(to newAgentID: String) {
        // Save current agent's canvas
        if let oldID = activeAgentID {
            if !content.isEmpty {
                agentSnapshots[oldID] = (title: title, content: content)
            } else {
                agentSnapshots.removeValue(forKey: oldID)
            }
        }
        activeAgentID = newAgentID
        // Restore new agent's canvas (or clear)
        if let snapshot = agentSnapshots[newAgentID] {
            self.title = snapshot.title
            self.content = snapshot.content
        } else {
            self.title = "Untitled"
            self.content = ""
        }
    }

    /// Restores canvas content and opens the window/sheet
    func restoreState(title: String, content: String) {
        self.title = title
        self.content = content
        #if os(macOS)
        WindowOpener.openWindow?(id: "canvas")
        NSApp.activate(ignoringOtherApps: true)
        #else
        isPresented = true
        #endif
    }

    /// Whether content looks like HTML that should be previewed (full doc or rich fragment)
    var looksLikeHTML: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Full HTML document
        if trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html") { return true }
        // Rich HTML fragment with structure tags
        let structureTags = ["<canvas", "<svg", "<style", "<div", "<body", "<table", "<form", "<nav", "<header", "<section"]
        return structureTags.contains(where: { trimmed.contains($0) })
    }

    /// Called by agent tools to write content to the canvas and open the window/sheet.
    func write(title: String, content: String, append: Bool = false) {
        self.title = title
        if append {
            if !self.content.isEmpty { self.content += "\n\n" }
            self.content += content
        } else {
            self.content = content
        }
        #if os(macOS)
        WindowOpener.openWindow?(id: "canvas")
        NSApp.activate(ignoringOtherApps: true)
        #else
        isPresented = true
        #endif
    }
}
#endif

// MARK: - macOS Canvas Window + Preview

#if canImport(SwiftUI) && os(macOS)
struct CanvasWindow: View {
    @ObservedObject private var store = CanvasStore.shared
    @State private var isEditing = false
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Image(systemName: showPreview ? "globe" : "doc.text")
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

                // Preview / Edit toggle
                Button {
                    showPreview.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showPreview ? "pencil" : "play.fill")
                            .font(.system(size: 10))
                        Text(showPreview ? "Edit" : "Preview")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(showPreview ? .white.opacity(0.5) : .green.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(showPreview ? Color.white.opacity(0.04) : Color.green.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(showPreview ? "Switch to editor" : "Preview as HTML")

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

            // Content area: Editor or Preview
            if showPreview {
                CanvasPreviewView(content: store.content)
            } else {
                TextEditor(text: $store.content)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(16)
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .preferredColorScheme(.dark)
        .onChange(of: store.content) { newContent in
            // Auto-enable preview when HTML content is written by an agent
            if !showPreview && store.looksLikeHTML {
                showPreview = true
            }
        }
    }
}

// MARK: - Preview View

/// Wraps content in appropriate HTML and renders via WKWebView.
private struct CanvasPreviewView: View {
    let content: String

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.15))
                Text("Nothing to preview")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CanvasWebView(htmlContent: prepareHTML(content))
                .padding(1) // Prevent WKWebView from bleeding into borders
        }
    }

    /// Detect content type and wrap in appropriate HTML for preview.
    private func prepareHTML(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Full HTML document — render as-is
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") {
            return raw
        }

        // HTML fragment (contains common tags) — wrap in shell
        if looksLikeHTML(lower) {
            return wrapInHTMLShell(raw)
        }

        // JavaScript — wrap with script tag + console capture
        if looksLikeJavaScript(lower) {
            return wrapJS(raw)
        }

        // CSS — wrap with sample elements
        if looksLikeCSS(lower) {
            return wrapCSS(raw)
        }

        // Fallback: display as preformatted code
        return wrapCode(raw)
    }

    private func looksLikeHTML(_ lower: String) -> Bool {
        let tags = ["<div", "<p>", "<p ", "<span", "<h1", "<h2", "<h3", "<h4",
                     "<ul", "<ol", "<li", "<table", "<form", "<input", "<button",
                     "<img", "<a ", "<a>", "<nav", "<header", "<footer", "<section",
                     "<style", "<canvas", "<svg", "<body"]
        return tags.contains(where: { lower.contains($0) })
    }

    private func looksLikeJavaScript(_ lower: String) -> Bool {
        let patterns = ["function ", "const ", "let ", "var ", "=> {",
                        "document.", "console.", "window.", "class ",
                        "import ", "export ", "async ", "await "]
        let hits = patterns.filter { lower.contains($0) }.count
        return hits >= 2 && !lower.contains("<div") && !lower.contains("<p>")
    }

    private func looksLikeCSS(_ lower: String) -> Bool {
        return (lower.contains("{") && lower.contains("}") &&
                (lower.contains("color:") || lower.contains("margin:") ||
                 lower.contains("padding:") || lower.contains("display:") ||
                 lower.contains("font-") || lower.contains("background")))
                && !lower.contains("function ") && !lower.contains("const ")
    }

    private func wrapInHTMLShell(_ fragment: String) -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body { font-family: -apple-system, system-ui, sans-serif; margin: 16px;
                   background: #0f0f14; color: #e0e0e0; }
            a { color: #66ccff; }
        </style>
        </head><body>\(fragment)</body></html>
        """
    }

    private func wrapJS(_ code: String) -> String {
        let escaped = code.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "`", with: "\\`")
                         .replacingOccurrences(of: "$", with: "\\$")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
            body { font-family: -apple-system, monospace; margin: 16px;
                   background: #0f0f14; color: #e0e0e0; }
            #console { white-space: pre-wrap; font-family: 'SF Mono', Menlo, monospace;
                       font-size: 13px; line-height: 1.5; color: #a0ffa0; }
            .error { color: #ff6b6b; }
        </style>
        </head><body>
        <div id="console"></div>
        <script>
        (function() {
            const el = document.getElementById('console');
            const origLog = console.log;
            const origErr = console.error;
            const origWarn = console.warn;
            function append(text, cls) {
                const line = document.createElement('div');
                if (cls) line.className = cls;
                line.textContent = typeof text === 'object' ? JSON.stringify(text, null, 2) : String(text);
                el.appendChild(line);
            }
            console.log = function() { append([...arguments].map(a => typeof a === 'object' ? JSON.stringify(a, null, 2) : String(a)).join(' ')); origLog.apply(console, arguments); };
            console.error = function() { append([...arguments].join(' '), 'error'); origErr.apply(console, arguments); };
            console.warn = function() { append('⚠ ' + [...arguments].join(' ')); origWarn.apply(console, arguments); };
            try {
                \(escaped)
            } catch(e) {
                append('Error: ' + e.message, 'error');
            }
        })();
        </script>
        </body></html>
        """
    }

    private func wrapCSS(_ css: String) -> String {
        let escaped = css.replacingOccurrences(of: "</", with: "<\\/")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
            body { font-family: -apple-system, system-ui, sans-serif; margin: 24px;
                   background: #0f0f14; color: #e0e0e0; }
            \(escaped)
        </style>
        </head><body>
        <h1>Heading 1</h1>
        <h2>Heading 2</h2>
        <p>This is a paragraph with <a href="#">a link</a> and <strong>bold text</strong>.</p>
        <div class="container"><div class="box">Box 1</div><div class="box">Box 2</div><div class="box">Box 3</div></div>
        <button>Button</button>
        <ul><li>Item one</li><li>Item two</li><li>Item three</li></ul>
        </body></html>
        """
    }

    private func wrapCode(_ code: String) -> String {
        let escaped = code.replacingOccurrences(of: "&", with: "&amp;")
                         .replacingOccurrences(of: "<", with: "&lt;")
                         .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
            body { margin: 0; padding: 16px; background: #0f0f14; }
            pre { font-family: 'SF Mono', Menlo, monospace; font-size: 13px;
                  line-height: 1.5; color: #d4d4d4; white-space: pre-wrap;
                  word-wrap: break-word; margin: 0; }
        </style>
        </head><body><pre><code>\(escaped)</code></pre></body></html>
        """
    }
}
#endif
