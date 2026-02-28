// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Terminal WebView
// NSViewRepresentable WKWebView with xterm.js and bidirectional JS-Swift bridge.
#if canImport(WebKit) && os(macOS)
import SwiftUI
import WebKit

struct TerminalWebView: NSViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let userContent = config.userContentController
        userContent.add(context.coordinator, name: "terminalInput")
        userContent.add(context.coordinator, name: "terminalResize")
        userContent.add(context.coordinator, name: "terminalReady")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        // Wire PTY output -> xterm.js
        session.onOutput = { [weak coordinator = context.coordinator] data in
            coordinator?.handleOutput(data)
        }

        webView.loadHTMLString(Self.xtermHTML, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // No-op — xterm.js state is managed via JS bridge, not SwiftUI updates
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "terminalInput":
                if let text = message.body as? String,
                   let data = text.data(using: .utf8) {
                    session.write(data)
                }
            case "terminalResize":
                if let dict = message.body as? [String: Int],
                   let cols = dict["cols"], let rows = dict["rows"],
                   cols > 0, rows > 0 {
                    session.resize(cols: UInt16(cols), rows: UInt16(rows))
                }
            case "terminalReady":
                // JS sends current size after initial fit
                if let dict = message.body as? [String: Int],
                   let cols = dict["cols"], let rows = dict["rows"] {
                    replayBuffer(currentCols: UInt16(cols), currentRows: UInt16(rows))
                } else {
                    replayBuffer(currentCols: 0, currentRows: 0)
                }
            default:
                break
            }
        }

        func handleOutput(_ data: Data) {
            let base64 = data.base64EncodedString()
            let js = "writeTerminalData('\(base64)');"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Replay accumulated PTY output into a freshly created xterm.js instance.
        /// If the size changed (tabs <-> tiled), replays into scrollback then clears the
        /// visible screen so the SIGWINCH redraw (from reportSize) draws onto a clean slate.
        /// If same size (dashboard tab switch), replays as-is for perfect restoration.
        private func replayBuffer(currentCols: UInt16, currentRows: UInt16) {
            let buffer = session.outputBuffer
            guard !buffer.isEmpty else { return }

            let base64 = buffer.base64EncodedString()
            let sizeChanged = currentCols > 0 && currentRows > 0
                && (currentCols != session.lastCols || currentRows != session.lastRows)

            if sizeChanged {
                // Replay into scrollback (garbled at new width, but preserves history),
                // then clear the visible screen. reportSize() fires AFTER this and sends
                // SIGWINCH — the running program redraws onto the clean screen.
                let js = "writeTerminalData('\(base64)'); term.write('\\x1b[2J\\x1b[H');"
                webView?.evaluateJavaScript(js) { [weak self] _, _ in
                    // Safety net: force SIGWINCH even if reportSize already resized the PTY
                    self?.session.forceRedraw()
                }
            } else {
                // Same size — replay as-is for perfect restoration
                let js = "writeTerminalData('\(base64)');"
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - xterm.js HTML

    private static let xtermHTML: String = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      html, body { width: 100%; height: 100%; overflow: hidden; background: #14141a; }
      #terminal { width: 100%; height: 100%; }
    </style>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
    <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-links@0.11.0/lib/addon-web-links.min.js"></script>
    </head>
    <body>
    <div id="terminal"></div>
    <script>
      const term = new Terminal({
        fontSize: 13,
        fontFamily: "'SF Mono', Menlo, Monaco, 'Courier New', monospace",
        cursorBlink: true,
        cursorStyle: 'bar',
        macOptionIsMeta: true,
        allowProposedApi: true,
        theme: {
          background: '#14141a',
          foreground: '#e4e4ef',
          cursor: '#a855f7',
          cursorAccent: '#14141a',
          selectionBackground: 'rgba(168, 85, 247, 0.3)',
          black: '#14141a',
          red: '#ef4444',
          green: '#22c55e',
          yellow: '#eab308',
          blue: '#3b82f6',
          magenta: '#a855f7',
          cyan: '#06b6d4',
          white: '#e4e4ef',
          brightBlack: '#6b7280',
          brightRed: '#f87171',
          brightGreen: '#4ade80',
          brightYellow: '#fde047',
          brightBlue: '#60a5fa',
          brightMagenta: '#c084fc',
          brightCyan: '#22d3ee',
          brightWhite: '#ffffff'
        }
      });

      const fitAddon = new FitAddon.FitAddon();
      const webLinksAddon = new WebLinksAddon.WebLinksAddon();
      term.loadAddon(fitAddon);
      term.loadAddon(webLinksAddon);
      term.open(document.getElementById('terminal'));

      // Initial fit — tell Swift we're ready BEFORE reporting size.
      // This lets Swift compare the new xterm size against the PTY's
      // previous size (lastCols/lastRows) to detect view-mode changes.
      // reportSize() then updates the PTY, triggering SIGWINCH if needed.
      requestAnimationFrame(() => {
        fitAddon.fit();
        window.webkit.messageHandlers.terminalReady.postMessage({
          cols: term.cols, rows: term.rows
        });
        reportSize();
      });

      // Resize observer
      const ro = new ResizeObserver(() => {
        fitAddon.fit();
        reportSize();
      });
      ro.observe(document.getElementById('terminal'));

      function reportSize() {
        const msg = { cols: term.cols, rows: term.rows };
        window.webkit.messageHandlers.terminalResize.postMessage(msg);
      }

      // User keystrokes -> Swift
      term.onData((data) => {
        window.webkit.messageHandlers.terminalInput.postMessage(data);
      });

      // Swift -> xterm.js (called from evaluateJavaScript)
      function writeTerminalData(base64) {
        const bytes = atob(base64);
        const arr = new Uint8Array(bytes.length);
        for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
        const text = new TextDecoder().decode(arr);
        term.write(text);
      }

      // Focus terminal on load
      term.focus();
    </script>
    </body>
    </html>
    """
}
#endif
