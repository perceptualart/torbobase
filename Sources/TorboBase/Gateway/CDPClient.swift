// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Chrome DevTools Protocol Client
// CDPClient.swift — WebSocket client connecting to Chrome's DevTools port
// Supports navigation, screenshots, JS execution, DOM queries, and tab management.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor CDPClient {
    static let shared = CDPClient()

    private var session: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private var messageID: Int = 0
    private var pendingCallbacks: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var debugPort: Int = 9222
    private var isConnected = false
    private var browserProcess: Process?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    /// Launch Chrome with remote debugging enabled (headless mode)
    func launchBrowser(headless: Bool = true, port: Int = 9222) async -> Bool {
        debugPort = port

        #if os(macOS)
        let chromePaths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium"
        ]
        #else
        let chromePaths = [
            "/usr/bin/google-chrome",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium"
        ]
        #endif

        guard let chromePath = chromePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            TorboLog.error("Chrome/Chromium not found", subsystem: "CDP")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: chromePath)
        var args = [
            "--remote-debugging-port=\(port)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-extensions"
        ]
        if headless {
            args.append("--headless=new")
        }
        process.arguments = args

        do {
            try process.run()
            browserProcess = process
            // Wait for Chrome to start listening
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            TorboLog.info("Chrome launched on port \(port)", subsystem: "CDP")
            return true
        } catch {
            TorboLog.error("Failed to launch Chrome: \(error)", subsystem: "CDP")
            return false
        }
    }

    /// Connect to an already-running Chrome instance
    func connect(port: Int = 9222) async -> Bool {
        debugPort = port

        // Get the first available target
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return false }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let target = targets.first(where: { $0["type"] as? String == "page" }),
                  let wsURL = target["webSocketDebuggerUrl"] as? String,
                  let wsURLObj = URL(string: wsURL) else { return false }

            wsTask = session.webSocketTask(with: wsURLObj)
            wsTask?.resume()
            isConnected = true

            // Start receiving messages
            Task { await receiveLoop() }

            TorboLog.info("Connected to Chrome DevTools on port \(port)", subsystem: "CDP")
            return true
        } catch {
            TorboLog.error("Failed to connect: \(error)", subsystem: "CDP")
            return false
        }
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        isConnected = false
    }

    func shutdown() {
        disconnect()
        browserProcess?.terminate()
        browserProcess = nil
    }

    // MARK: - CDP Commands

    /// Navigate to a URL
    func navigate(url: String) async -> [String: Any] {
        await sendCommand("Page.navigate", params: ["url": url])
    }

    /// Capture a screenshot
    func captureScreenshot(format: String = "png", quality: Int = 80, fullPage: Bool = false) async -> Data? {
        var params: [String: Any] = ["format": format]
        if format == "jpeg" { params["quality"] = quality }
        if fullPage {
            // Get layout metrics for full page
            let metrics = await sendCommand("Page.getLayoutMetrics", params: [:])
            if let contentSize = metrics["contentSize"] as? [String: Any],
               let width = contentSize["width"] as? Double,
               let height = contentSize["height"] as? Double {
                params["clip"] = [
                    "x": 0, "y": 0,
                    "width": width, "height": height, "scale": 1
                ]
            }
        }

        let result = await sendCommand("Page.captureScreenshot", params: params)
        if let base64 = result["data"] as? String {
            return Data(base64Encoded: base64)
        }
        return nil
    }

    /// Execute JavaScript in the page
    func evaluateJS(_ expression: String) async -> [String: Any] {
        await sendCommand("Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true
        ])
    }

    /// Get the document DOM tree
    func getDocument() async -> [String: Any] {
        await sendCommand("DOM.getDocument", params: [:])
    }

    /// Query selector
    func querySelector(_ selector: String, nodeId: Int? = nil) async -> [String: Any] {
        let docNodeId: Int
        if let nid = nodeId {
            docNodeId = nid
        } else {
            let doc = await getDocument()
            guard let root = doc["root"] as? [String: Any],
                  let nid = root["nodeId"] as? Int else { return ["error": "No document"] }
            docNodeId = nid
        }
        return await sendCommand("DOM.querySelector", params: [
            "nodeId": docNodeId,
            "selector": selector
        ])
    }

    /// Enable network monitoring
    func enableNetwork() async {
        let _ = await sendCommand("Network.enable", params: [:])
    }

    /// Get page text content
    func getPageText() async -> String {
        let result = await evaluateJS("document.body.innerText")
        if let resultObj = result["result"] as? [String: Any],
           let value = resultObj["value"] as? String {
            return value
        }
        return ""
    }

    /// Click an element by selector
    func click(selector: String) async -> Bool {
        let result = await evaluateJS("""
            (() => {
                const el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
                if (el) { el.click(); return true; }
                return false;
            })()
            """)
        if let resultObj = result["result"] as? [String: Any],
           let value = resultObj["value"] as? Bool { return value }
        return false
    }

    /// Type text into a focused element
    func typeText(_ text: String, selector: String? = nil) async {
        if let selector {
            let _ = await evaluateJS("document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))').focus()")
        }
        for char in text {
            let _ = await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyDown",
                "text": String(char)
            ])
            let _ = await sendCommand("Input.dispatchKeyEvent", params: [
                "type": "keyUp",
                "text": String(char)
            ])
        }
    }

    /// Wait for a selector to appear
    func waitFor(selector: String, timeoutMs: Int = 5000) async -> Bool {
        let startTime = Date()
        let timeout = Double(timeoutMs) / 1000.0
        while Date().timeIntervalSince(startTime) < timeout {
            let result = await evaluateJS("document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))') !== null")
            if let resultObj = result["result"] as? [String: Any],
               let value = resultObj["value"] as? Bool, value { return true }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        return false
    }

    // MARK: - Tab Management

    func listTabs() async -> [[String: Any]] {
        guard let url = URL(string: "http://127.0.0.1:\(debugPort)/json") else { return [] }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        } catch { return [] }
    }

    func createTab(url: String = "about:blank") async -> [String: Any] {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let reqURL = URL(string: "http://127.0.0.1:\(debugPort)/json/new?\(encoded)") else { return [:] }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: reqURL))
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch { return [:] }
    }

    func closeTab(targetID: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(debugPort)/json/close/\(targetID)") else { return false }
        do {
            let (_, response) = try await session.data(for: URLRequest(url: url))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - Cookie Persistence

    /// Get all cookies from the browser
    func getCookies() async -> [[String: Any]] {
        let result = await sendCommand("Network.getAllCookies", params: [:])
        return result["cookies"] as? [[String: Any]] ?? []
    }

    /// Set cookies in the browser (restore a previous session)
    func setCookies(_ cookies: [[String: Any]]) async {
        let _ = await sendCommand("Network.setCookies", params: ["cookies": cookies])
    }

    /// Clear all cookies
    func clearCookies() async {
        let _ = await sendCommand("Network.clearBrowserCookies", params: [:])
    }

    // MARK: - Scroll

    /// Scroll the page in a direction
    func scroll(direction: String, amount: Int = 500) async {
        let jsCode: String
        switch direction.lowercased() {
        case "up": jsCode = "window.scrollBy(0, -\(amount))"
        case "bottom": jsCode = "window.scrollTo(0, document.body.scrollHeight)"
        case "top": jsCode = "window.scrollTo(0, 0)"
        default: jsCode = "window.scrollBy(0, \(amount))" // down
        }
        let _ = await evaluateJS(jsCode)
    }

    /// Get page title
    func getPageTitle() async -> String {
        let result = await evaluateJS("document.title")
        if let resultObj = result["result"] as? [String: Any],
           let value = resultObj["value"] as? String { return value }
        return ""
    }

    /// Get current URL
    func getCurrentURL() async -> String {
        let result = await evaluateJS("window.location.href")
        if let resultObj = result["result"] as? [String: Any],
           let value = resultObj["value"] as? String { return value }
        return ""
    }

    /// Check if Chrome is reachable on the debug port
    func isAvailable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(debugPort)/json/version") else { return false }
        do {
            let (_, resp) = try await session.data(for: URLRequest(url: url))
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - WebSocket Communication

    func sendCommand(_ method: String, params: [String: Any]) async -> [String: Any] {
        if !isConnected {
            // Auto-connect if not connected
            guard await connect(port: debugPort) else {
                return ["error": "Not connected to Chrome DevTools"]
            }
        }

        messageID += 1
        let id = messageID

        let message: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            return ["error": "Failed to serialize command"]
        }

        return await withCheckedContinuation { continuation in
            pendingCallbacks[id] = continuation
            Task {
                do {
                    try await wsTask?.send(.string(json))
                } catch {
                    pendingCallbacks.removeValue(forKey: id)
                    continuation.resume(returning: ["error": error.localizedDescription])
                }
            }

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let cb = pendingCallbacks.removeValue(forKey: id) {
                    cb.resume(returning: ["error": "Timeout"])
                }
            }
        }
    }

    private func receiveLoop() async {
        while isConnected {
            do {
                guard let message = try await wsTask?.receive() else { break }
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let id = json["id"] as? Int,
                       let callback = pendingCallbacks.removeValue(forKey: id) {
                        let result = json["result"] as? [String: Any] ?? json
                        callback.resume(returning: result)
                    }
                }
            } catch {
                if isConnected {
                    TorboLog.error("WS receive error: \(error)", subsystem: "CDP")
                }
                break
            }
        }
    }

    // MARK: - Stats

    func stats() -> [String: Any] {
        [
            "connected": isConnected,
            "debug_port": debugPort,
            "pending_commands": pendingCallbacks.count,
            "browser_running": browserProcess?.isRunning ?? false
        ]
    }
}
