// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Browser Automation Engine
// BrowserAutomation.swift — Headless browser control via Playwright CLI
// Gives agents the ability to navigate, interact with, and extract data from web pages
// Requires: npx playwright (auto-installs on first use)

import Foundation

// MARK: - Browser Action Types

enum BrowserAction: String, Codable {
    case navigate       // Go to URL
    case screenshot     // Take a screenshot
    case click          // Click an element
    case type           // Type text into an element
    case extract        // Extract text/data from page
    case evaluate       // Run JavaScript on the page
    case waitFor        // Wait for selector
    case scroll         // Scroll the page
    case select         // Select from dropdown
    case pdf            // Save page as PDF
}

// MARK: - Browser Session

actor BrowserAutomation {
    static let shared = BrowserAutomation()

    private let session: URLSession
    private let baseDir: String
    private var sessionCount = 0

    // Playwright server process (if running)
    private var serverProcess: Process?
    private var serverPort: Int = 3100
    private var isServerRunning = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)

        let appSupport = PlatformPaths.appSupportDir
        baseDir = appSupport.appendingPathComponent("TorboBase/browser").path
        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        TorboLog.info("Initialized at \(baseDir)", subsystem: "Browser")
    }

    // MARK: - Execute Browser Actions

    /// Execute a browser action by generating and running a Playwright script
    func execute(action: BrowserAction, params: [String: Any]) async -> BrowserResult {
        let startTime = Date()
        sessionCount += 1
        let sessionID = "\(sessionCount)_\(UUID().uuidString.prefix(8))"
        let workDir = "\(baseDir)/session_\(sessionID)"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        // Generate the Playwright script
        let script = generateScript(action: action, params: params, workDir: workDir, sessionID: sessionID)

        // Write script to file
        let scriptPath = "\(workDir)/script.js"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Execute with npx playwright (auto-installs)
        let result = await runPlaywrightScript(scriptPath: scriptPath, workDir: workDir, timeout: 60)

        let executionTime = Date().timeIntervalSince(startTime)

        // Collect any generated files (screenshots, PDFs)
        let generatedFiles = collectFiles(in: workDir, excluding: ["script.js"])

        TorboLog.info("\(action.rawValue) completed in \(String(format: "%.1f", executionTime))s — exit: \(result.exitCode)", subsystem: "Browser")

        // Schedule cleanup (keep files for 30 minutes)
        Task {
            try? await Task.sleep(nanoseconds: 1800 * 1_000_000_000)
            try? FileManager.default.removeItem(atPath: workDir)
        }

        return BrowserResult(
            success: result.exitCode == 0,
            output: result.stdout,
            error: result.stderr,
            files: generatedFiles,
            executionTime: executionTime
        )
    }

    // MARK: - Convenience Methods

    /// Navigate to URL and extract page content
    func navigateAndExtract(url: String, selector: String? = nil) async -> String {
        let result = await execute(action: .extract, params: [
            "url": url,
            "selector": selector ?? "body"
        ])
        return result.success ? result.output : "Error: \(result.error)"
    }

    /// Take a screenshot of a URL
    func screenshot(url: String, fullPage: Bool = false) async -> BrowserResult {
        return await execute(action: .screenshot, params: [
            "url": url,
            "fullPage": fullPage
        ])
    }

    /// Click an element on a page
    func click(url: String, selector: String) async -> BrowserResult {
        return await execute(action: .click, params: [
            "url": url,
            "selector": selector
        ])
    }

    /// Fill a form field
    func typeText(url: String, selector: String, text: String) async -> BrowserResult {
        return await execute(action: .type, params: [
            "url": url,
            "selector": selector,
            "text": text
        ])
    }

    // MARK: - Script Generation

    private func generateScript(action: BrowserAction, params: [String: Any], workDir: String, sessionID: String) -> String {
        let url = params["url"] as? String ?? "about:blank"
        let escapedURL = url.replacingOccurrences(of: "'", with: "\\'")
        let selector = (params["selector"] as? String ?? "body").replacingOccurrences(of: "'", with: "\\'")
        let text = (params["text"] as? String ?? "").replacingOccurrences(of: "'", with: "\\'")
        let fullPage = params["fullPage"] as? Bool ?? false
        let jsCode = (params["javascript"] as? String ?? "").replacingOccurrences(of: "`", with: "\\`")
        let escapedWorkDir = workDir.replacingOccurrences(of: "'", with: "\\'")

        var script = """
        const { chromium } = require('playwright');

        (async () => {
            const browser = await chromium.launch({
                headless: true,
                args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
            });
            const context = await browser.newContext({
                userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                viewport: { width: 1280, height: 720 }
            });
            const page = await context.newPage();

            try {

        """

        switch action {
        case .navigate:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    const title = await page.title();
                    const url = page.url();
                    console.log(JSON.stringify({ title, url, status: 'navigated' }));

            """

        case .screenshot:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.screenshot({
                        path: '\(escapedWorkDir)/screenshot.png',
                        fullPage: \(fullPage ? "true" : "false")
                    });
                    console.log(JSON.stringify({ file: 'screenshot.png', status: 'captured' }));

            """

        case .click:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.click('\(selector)', { timeout: 10000 });
                    await page.waitForTimeout(1000);
                    const title = await page.title();
                    const newUrl = page.url();
                    console.log(JSON.stringify({ title, url: newUrl, status: 'clicked', selector: '\(selector)' }));

            """

        case .type:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.fill('\(selector)', '\(text)', { timeout: 10000 });
                    console.log(JSON.stringify({ status: 'typed', selector: '\(selector)', text: '\(text)' }));

            """

        case .extract:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    const content = await page.evaluate((sel) => {
                        const el = document.querySelector(sel);
                        if (!el) return '[Element not found]';
                        return el.innerText || el.textContent || '';
                    }, '\(selector)');
                    const title = await page.title();
                    const links = await page.evaluate(() => {
                        return Array.from(document.querySelectorAll('a[href]')).slice(0, 20).map(a => ({
                            text: (a.innerText || '').trim().substring(0, 100),
                            href: a.href
                        })).filter(l => l.text && l.href.startsWith('http'));
                    });
                    console.log(JSON.stringify({ title, content: content.substring(0, 10000), links, url: page.url() }));

            """

        case .evaluate:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    const result = await page.evaluate(() => {
                        \(jsCode)
                    });
                    console.log(JSON.stringify({ result, status: 'evaluated' }));

            """

        case .waitFor:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.waitForSelector('\(selector)', { timeout: 15000 });
                    const found = await page.isVisible('\(selector)');
                    console.log(JSON.stringify({ found, selector: '\(selector)', status: 'waited' }));

            """

        case .scroll:
            let direction = params["direction"] as? String ?? "down"
            let amount = params["amount"] as? Int ?? 500
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.evaluate(({ dir, amt }) => {
                        if (dir === 'down') window.scrollBy(0, amt);
                        else if (dir === 'up') window.scrollBy(0, -amt);
                        else if (dir === 'bottom') window.scrollTo(0, document.body.scrollHeight);
                        else if (dir === 'top') window.scrollTo(0, 0);
                    }, { dir: '\(direction)', amt: \(amount) });
                    console.log(JSON.stringify({ status: 'scrolled', direction: '\(direction)' }));

            """

        case .select:
            let value = params["value"] as? String ?? ""
            let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.selectOption('\(selector)', '\(escapedValue)', { timeout: 10000 });
                    console.log(JSON.stringify({ status: 'selected', selector: '\(selector)', value: '\(escapedValue)' }));

            """

        case .pdf:
            script += """
                    await page.goto('\(escapedURL)', { waitUntil: 'domcontentloaded', timeout: 30000 });
                    await page.pdf({
                        path: '\(escapedWorkDir)/page.pdf',
                        format: 'A4',
                        printBackground: true
                    });
                    console.log(JSON.stringify({ file: 'page.pdf', status: 'saved' }));

            """
        }

        script += """
            } catch (error) {
                console.error(JSON.stringify({ error: error.message, status: 'failed' }));
                process.exitCode = 1;
            } finally {
                await browser.close();
            }
        })();
        """

        return script
    }

    // MARK: - Playwright Execution

    private func runPlaywrightScript(scriptPath: String, workDir: String, timeout: Int) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()

        // Try npx first, then node directly with playwright
        let npxPaths = ["/usr/local/bin/npx", "/opt/homebrew/bin/npx", "/usr/bin/npx"]
        var npxPath: String?
        for path in npxPaths {
            if FileManager.default.fileExists(atPath: path) {
                npxPath = path
                break
            }
        }

        // Try `which npx` as fallback
        if npxPath == nil {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["npx"]
            let pipe = Pipe()
            which.standardOutput = pipe
            do {
                try which.run()
                which.waitUntilExit()
            } catch {
                TorboLog.debug("Process failed to start: \(error)", subsystem: "Browser")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let p = path, !p.isEmpty { npxPath = p }
        }

        guard let npx = npxPath else {
            return (-1, "", "npx not found. Install Node.js: brew install node")
        }

        process.executableURL = URL(fileURLWithPath: npx)
        // Use playwright test runner or direct node execution
        process.arguments = ["-y", "playwright", "test", "--config=/dev/null", scriptPath]
        // Actually, simpler to just run with node since we require('playwright')
        // Let's use node directly
        let nodePaths = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        var nodePath: String?
        for path in nodePaths {
            if FileManager.default.fileExists(atPath: path) {
                nodePath = path
                break
            }
        }
        if nodePath == nil {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["node"]
            let pipe = Pipe()
            which.standardOutput = pipe
            do {
                try which.run()
                which.waitUntilExit()
            } catch {
                TorboLog.debug("Process failed to start: \(error)", subsystem: "Browser")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let p = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let p, !p.isEmpty { nodePath = p }
        }

        guard let node = nodePath else {
            return (-1, "", "node not found. Install Node.js: brew install node")
        }

        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        // Ensure playwright can find browsers
        env["PLAYWRIGHT_BROWSERS_PATH"] = "\(baseDir)/browsers"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if process.isRunning { process.terminate() }
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutTask.cancel()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return (process.terminationStatus, stdout, stderr)
        } catch {
            return (-1, "", "Failed to run: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func collectFiles(in directory: String, excluding: [String]) -> [BrowserFile] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let excluded = Set(excluding)

        return contents.compactMap { filename -> BrowserFile? in
            guard !excluded.contains(filename) else { return nil }
            let filePath = "\(directory)/\(filename)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let size = attrs[.size] as? Int else { return nil }
            return BrowserFile(name: filename, path: filePath, size: size)
        }
    }

    /// Check if Playwright is installed
    func isPlaywrightAvailable() async -> Bool {
        let process = Process()
        let npxPaths = ["/usr/local/bin/npx", "/opt/homebrew/bin/npx"]
        for path in npxPaths {
            if FileManager.default.fileExists(atPath: path) {
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["playwright", "--version"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch { continue }
            }
        }
        return false
    }

    /// Install Playwright and browsers
    func installPlaywright() async -> String {
        let npxPaths = ["/usr/local/bin/npx", "/opt/homebrew/bin/npx"]
        var npxPath: String?
        for path in npxPaths {
            if FileManager.default.fileExists(atPath: path) { npxPath = path; break }
        }
        guard let npx = npxPath else { return "npx not found. Install Node.js first: brew install node" }

        // Install playwright
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "playwright", "install", "chromium"]
        var env = ProcessInfo.processInfo.environment
        env["PLAYWRIGHT_BROWSERS_PATH"] = "\(baseDir)/browsers"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                return "Playwright installed successfully.\n\(stdout)"
            } else {
                return "Installation failed: \(stderr)"
            }
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Stats
    func stats() -> [String: Any] {
        let sessionDirs = (try? FileManager.default.contentsOfDirectory(atPath: baseDir))?.filter { $0.hasPrefix("session_") } ?? []
        return [
            "total_sessions": sessionCount,
            "active_sessions": sessionDirs.count,
            "base_path": baseDir
        ]
    }
}

// MARK: - Browser Result

struct BrowserResult {
    let success: Bool
    let output: String
    let error: String
    let files: [BrowserFile]
    let executionTime: TimeInterval

    var toolResponse: String {
        var parts: [String] = []
        if success && !output.isEmpty {
            // Try to parse JSON output for cleaner display
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Format JSON result
                if let title = json["title"] as? String { parts.append("Title: \(title)") }
                if let url = json["url"] as? String { parts.append("URL: \(url)") }
                if let content = json["content"] as? String {
                    parts.append("Content:\n\(String(content.prefix(8000)))")
                }
                if let links = json["links"] as? [[String: Any]], !links.isEmpty {
                    let linkList = links.prefix(15).map { link in
                        "  [\(link["text"] as? String ?? "")] → \(link["href"] as? String ?? "")"
                    }.joined(separator: "\n")
                    parts.append("Links:\n\(linkList)")
                }
                if let status = json["status"] as? String { parts.append("Status: \(status)") }
                if let file = json["file"] as? String { parts.append("File: \(file)") }
                if let result = json["result"] { parts.append("Result: \(result)") }
            } else {
                parts.append(String(output.prefix(8000)))
            }
        }
        if !success {
            parts.append("Error: \(error.prefix(2000))")
        }
        if !files.isEmpty {
            let fileList = files.map { "  - \($0.name) (\(formatBytes($0.size)))" }.joined(separator: "\n")
            parts.append("Generated files:\n\(fileList)")
        }
        parts.append("Time: \(String(format: "%.1f", executionTime))s")
        return parts.joined(separator: "\n")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}

struct BrowserFile {
    let name: String
    let path: String
    let size: Int
}
