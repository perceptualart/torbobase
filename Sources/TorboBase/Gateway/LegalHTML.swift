// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Legal HTML Page Server
// Serves legal documents (ToS, Privacy, AUP, Constitution) at /legal/*

import Foundation

enum LegalHTML {
    /// Valid legal page paths and their corresponding filenames
    private static let pages: [String: String] = [
        "/legal/terms-of-service.html": "terms-of-service.html",
        "/legal/privacy-policy.html": "privacy-policy.html",
        "/legal/acceptable-use-policy.html": "acceptable-use-policy.html",
        "/legal/torbo-constitution.html": "torbo-constitution.html",
    ]

    /// In-memory cache of loaded HTML pages (loaded once, cached forever)
    private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Returns the HTML content for a given URL path, or nil if not found
    static func page(for path: String) -> String? {
        guard let filename = pages[path] else { return nil }

        cacheLock.lock()
        if let cached = cache[path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Try to load from disk
        if let html = loadFromDisk(filename: filename) {
            cacheLock.lock()
            cache[path] = html
            cacheLock.unlock()
            return html
        }

        return nil
    }

    /// Search for legal HTML files in common locations relative to the executable
    private static func loadFromDisk(filename: String) -> String? {
        let fm = FileManager.default
        var searchPaths: [String] = []

        // 1. Adjacent to the executable: <exec_dir>/legal/
        if let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath() as URL? {
            let execDir = execURL.deletingLastPathComponent().path
            searchPaths.append("\(execDir)/legal/\(filename)")
            // macOS .app bundle: <app>/Contents/MacOS/../Resources/legal/
            searchPaths.append("\(execDir)/../Resources/legal/\(filename)")
            // Repo root relative to .build: <repo>/legal/
            searchPaths.append("\(execDir)/../../../legal/\(filename)")
            searchPaths.append("\(execDir)/../../../../legal/\(filename)")
        }

        // 2. Working directory
        let cwd = fm.currentDirectoryPath
        searchPaths.append("\(cwd)/legal/\(filename)")

        // 3. Known repo location (macOS)
        #if os(macOS)
        let home = NSHomeDirectory()
        searchPaths.append("\(home)/Documents/ORB MASTER/Torbo Base/legal/\(filename)")
        #endif

        for candidatePath in searchPaths {
            if fm.fileExists(atPath: candidatePath),
               let data = fm.contents(atPath: candidatePath),
               let html = String(data: data, encoding: .utf8) {
                return html
            }
        }

        return nil
    }
}
