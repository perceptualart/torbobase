// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Canvas WebView
// NSViewRepresentable WKWebView wrapper for live HTML/CSS/JS preview in the Canvas window.
#if canImport(WebKit) && os(macOS)
import SwiftUI
import WebKit

struct CanvasWebView: NSViewRepresentable {
    let htmlContent: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastContent = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when content actually changes — prevents flash on every SwiftUI cycle
        guard htmlContent != context.coordinator.lastContent else { return }
        context.coordinator.lastContent = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator {
        var lastContent: String = ""
    }
}
#endif
