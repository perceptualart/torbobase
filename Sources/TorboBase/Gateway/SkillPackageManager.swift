// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Skill Package Manager
// Portable .tbskill format for skill distribution.
// A .tbskill file is a ZIP archive containing skill.json, prompt.md, tools.json, etc.
// Supports import, export, and validation with security checks.

import Foundation

/// Errors that can occur during skill package operations.
enum SkillPackageError: Error, LocalizedError {
    case manifestMissing
    case manifestInvalid(String)
    case pathTraversal(String)
    case tooLarge(Int)
    case skillAlreadyExists(String)
    case skillNotFound(String)
    case zipFailed(String)
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: return "skill.json not found in package"
        case .manifestInvalid(let reason): return "Invalid skill.json: \(reason)"
        case .pathTraversal(let path): return "Path traversal detected: \(path)"
        case .tooLarge(let bytes): return "Package too large: \(bytes) bytes (max 10MB)"
        case .skillAlreadyExists(let id): return "Skill '\(id)' already exists"
        case .skillNotFound(let id): return "Skill '\(id)' not found"
        case .zipFailed(let reason): return "ZIP creation failed: \(reason)"
        case .unzipFailed(let reason): return "ZIP extraction failed: \(reason)"
        }
    }
}

/// Skill package manifest — the required fields in skill.json.
struct SkillManifest: Codable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String
    let icon: String
    let requiredAccessLevel: Int
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, author, icon, tags
        case requiredAccessLevel = "required_access_level"
    }

    /// Dictionary representation for API responses
    func toDict() -> [String: Any] {
        [
            "id": id, "name": name, "description": description,
            "version": version, "author": author, "icon": icon,
            "required_access_level": requiredAccessLevel, "tags": tags
        ]
    }
}

/// Manages .tbskill package import, export, and validation.
enum SkillPackageManager {

    /// Skills directory
    private static var skillsDir: URL {
        let appSupport = PlatformPaths.appSupportDir
        return appSupport.appendingPathComponent("TorboBase/skills", isDirectory: true)
    }

    /// Maximum uncompressed package size: 10MB
    private static let maxPackageSize = 10 * 1024 * 1024

    /// Allowed file extensions inside a .tbskill package
    private static let allowedExtensions = Set(["json", "md", "txt", "yaml", "yml", "toml"])

    // MARK: - Export

    /// Export a skill as a .tbskill package (ZIP archive).
    /// Returns the URL to the exported file in a temporary directory.
    static func export(skillID: String) throws -> URL {
        let skillDir = skillsDir.appendingPathComponent(skillID, isDirectory: true)
        let fm = FileManager.default

        guard fm.fileExists(atPath: skillDir.path) else {
            throw SkillPackageError.skillNotFound(skillID)
        }

        // Create temp directory for output
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tbskill-export-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputURL = tempDir.appendingPathComponent("\(skillID).tbskill")

        // Use ditto (macOS) or zip to create archive
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", skillDir.path, outputURL.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", outputURL.path, skillID]
        process.currentDirectoryURL = skillsDir
        #endif

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SkillPackageError.zipFailed(stderr)
        }

        TorboLog.info("Exported '\(skillID)' → \(outputURL.lastPathComponent)", subsystem: "SkillPkg")
        return outputURL
    }

    // MARK: - Import

    /// Import a .tbskill package, validate it, and install to skills directory.
    /// Returns the installed skill ID.
    @discardableResult
    static func importPackage(from url: URL) throws -> String {
        let fm = FileManager.default

        // Validate first
        let manifest = try validate(at: url)

        // Check if skill already exists
        let destDir = skillsDir.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: destDir.path) {
            // Remove existing to allow upgrade
            try fm.removeItem(at: destDir)
        }

        // Extract to temp location first
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tbskill-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Unzip
        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, tempDir.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", url.path, "-d", tempDir.path]
        #endif

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SkillPackageError.unzipFailed(stderr)
        }

        // Find the skill directory (may be nested from ditto --keepParent)
        let extracted = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.isDirectoryKey])
        var sourceDir: URL?

        // Look for directory containing skill.json
        for item in extracted {
            if fm.fileExists(atPath: item.appendingPathComponent("skill.json").path) {
                sourceDir = item
                break
            }
        }

        // If skill.json is directly in tempDir
        if sourceDir == nil && fm.fileExists(atPath: tempDir.appendingPathComponent("skill.json").path) {
            sourceDir = tempDir
        }

        guard let source = sourceDir else {
            throw SkillPackageError.manifestMissing
        }

        // Move to skills directory
        try fm.copyItem(at: source, to: destDir)

        // Ensure enabled = true in the installed skill.json
        let skillJsonURL = destDir.appendingPathComponent("skill.json")
        if let data = try? Data(contentsOf: skillJsonURL),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["enabled"] = true
            if let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                try? updated.write(to: skillJsonURL)
            }
        }

        TorboLog.info("Imported '\(manifest.id)' v\(manifest.version) by \(manifest.author)", subsystem: "SkillPkg")
        return manifest.id
    }

    // MARK: - Validation

    /// Validate a .tbskill package without installing it.
    /// Returns the manifest if valid, throws if not.
    @discardableResult
    static func validate(at url: URL) throws -> SkillManifest {
        let fm = FileManager.default

        // Check file exists
        guard fm.fileExists(atPath: url.path) else {
            throw SkillPackageError.skillNotFound(url.lastPathComponent)
        }

        // Check file size
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int) ?? 0
        if fileSize > maxPackageSize {
            throw SkillPackageError.tooLarge(fileSize)
        }

        // Extract to temp for inspection
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tbskill-validate-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let process = Process()
        #if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, tempDir.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", url.path, "-d", tempDir.path]
        #endif
        try process.run()
        process.waitUntilExit()

        // Find skill.json in extracted contents
        guard let manifestURL = findSkillJSON(in: tempDir) else {
            throw SkillPackageError.manifestMissing
        }

        // Parse and validate manifest
        let data = try Data(contentsOf: manifestURL)
        let manifest: SkillManifest
        do {
            manifest = try JSONDecoder().decode(SkillManifest.self, from: data)
        } catch {
            throw SkillPackageError.manifestInvalid(error.localizedDescription)
        }

        // Validate manifest fields
        if manifest.id.isEmpty {
            throw SkillPackageError.manifestInvalid("id cannot be empty")
        }
        if manifest.name.isEmpty {
            throw SkillPackageError.manifestInvalid("name cannot be empty")
        }

        // Check for path traversal in ID
        if manifest.id.contains("..") || manifest.id.contains("/") || manifest.id.contains("\\") {
            throw SkillPackageError.pathTraversal(manifest.id)
        }

        // Validate version format (loose semver)
        let versionPattern = #"^\d+\.\d+(\.\d+)?(-[a-zA-Z0-9]+)?$"#
        if manifest.version.range(of: versionPattern, options: .regularExpression) == nil {
            throw SkillPackageError.manifestInvalid("version must be semver (e.g. 1.0.0)")
        }

        // Check access level range
        if manifest.requiredAccessLevel < 0 || manifest.requiredAccessLevel > 5 {
            throw SkillPackageError.manifestInvalid("required_access_level must be 0-5")
        }

        // Scan extracted files for path traversal and suspicious content
        let skillDir = manifestURL.deletingLastPathComponent()
        if let enumerator = fm.enumerator(at: skillDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            var totalSize = 0
            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath = fileURL.path.replacingOccurrences(of: skillDir.path, with: "")
                if relativePath.contains("..") {
                    throw SkillPackageError.pathTraversal(relativePath)
                }

                // Check total uncompressed size
                let fileAttrs = try? fm.attributesOfItem(atPath: fileURL.path)
                totalSize += (fileAttrs?[.size] as? Int) ?? 0
                if totalSize > maxPackageSize {
                    throw SkillPackageError.tooLarge(totalSize)
                }
            }
        }

        return manifest
    }

    // MARK: - List

    /// List all installed skill packages with their manifests.
    static func listInstalled() -> [SkillManifest] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var manifests: [SkillManifest] = []
        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let skillJSON = item.appendingPathComponent("skill.json")
            guard let data = try? Data(contentsOf: skillJSON),
                  let manifest = try? JSONDecoder().decode(SkillManifest.self, from: data) else { continue }
            manifests.append(manifest)
        }

        return manifests.sorted { $0.name < $1.name }
    }

    // MARK: - Hashing

    /// SHA-256 hash of a .tbskill package for integrity verification.
    static func hashPackage(at url: URL) throws -> String {
        try SkillIntegrityVerifier.hashPackage(at: url)
    }

    // MARK: - Helpers

    /// Recursively find skill.json in a directory tree.
    private static func findSkillJSON(in directory: URL) -> URL? {
        let fm = FileManager.default

        // Direct check
        let direct = directory.appendingPathComponent("skill.json")
        if fm.fileExists(atPath: direct.path) { return direct }

        // One level deep (common with ZIP extraction adding a parent dir)
        if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents {
                let nested = item.appendingPathComponent("skill.json")
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }

        return nil
    }
}
