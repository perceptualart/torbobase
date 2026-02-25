// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Photo Editing Engine
// Wraps ImageMagick (magick) and Python rembg for photo operations.
// Tools: edit_photo, remove_background, photo_composite

import Foundation

actor PhotoEditor {
    static let shared = PhotoEditor()

    /// Max input file size: 500 MB
    private let maxFileSize = 500 * 1024 * 1024
    /// Execution timeout per operation: 2 minutes
    private let timeout: TimeInterval = 120

    // MARK: - Edit Photo

    /// Apply a chain of operations to an image.
    /// Operations: resize, crop, rotate, flip, grayscale, sepia, blur, sharpen,
    /// vignette, brightness, contrast, saturation, border, watermark, convert, compress
    func editPhoto(inputPath: String, operations: [[String: Any]], outputFormat: String? = nil) async -> String {
        let fm = FileManager.default

        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found at \(inputPath)"
        }

        guard let attrs = try? fm.attributesOfItem(atPath: inputPath),
              let size = attrs[.size] as? Int, size <= maxFileSize else {
            return "Error: File too large (max 500MB)"
        }

        // Validate it's an image by checking magic bytes
        guard isImageFile(inputPath) else {
            return "Error: Input file does not appear to be a valid image"
        }

        // Build output path
        let ext = outputFormat ?? (inputPath as NSString).pathExtension
        let outputPath = NSTemporaryDirectory() + "torbo_edit_\(UUID().uuidString).\(ext)"

        // Build ImageMagick command arguments
        var magickArgs = [inputPath]

        for op in operations {
            guard let action = op["action"] as? String else { continue }

            switch action {
            case "resize":
                let width = op["width"] as? Int
                let height = op["height"] as? Int
                if let w = width, let h = height {
                    magickArgs.append(contentsOf: ["-resize", "\(w)x\(h)"])
                } else if let w = width {
                    magickArgs.append(contentsOf: ["-resize", "\(w)x"])
                } else if let h = height {
                    magickArgs.append(contentsOf: ["-resize", "x\(h)"])
                }

            case "crop":
                if let w = op["width"] as? Int, let h = op["height"] as? Int {
                    let x = op["x"] as? Int ?? 0
                    let y = op["y"] as? Int ?? 0
                    magickArgs.append(contentsOf: ["-crop", "\(w)x\(h)+\(x)+\(y)", "+repage"])
                }

            case "rotate":
                let degrees = op["degrees"] as? Double ?? 0
                magickArgs.append(contentsOf: ["-rotate", String(format: "%.1f", degrees)])

            case "flip":
                let direction = op["direction"] as? String ?? "vertical"
                magickArgs.append(direction == "horizontal" ? "-flop" : "-flip")

            case "grayscale":
                magickArgs.append(contentsOf: ["-colorspace", "Gray"])

            case "sepia":
                let intensity = op["intensity"] as? Int ?? 80
                magickArgs.append(contentsOf: ["-sepia-tone", "\(clamp(intensity, 0, 100))%"])

            case "blur":
                let radius = op["radius"] as? Double ?? 8
                magickArgs.append(contentsOf: ["-blur", "0x\(String(format: "%.1f", clamp(radius, 0.1, 50)))"])

            case "sharpen":
                let radius = op["radius"] as? Double ?? 2
                magickArgs.append(contentsOf: ["-sharpen", "0x\(String(format: "%.1f", clamp(radius, 0.1, 20)))"])

            case "vignette":
                let radius = op["radius"] as? Int ?? 50
                magickArgs.append(contentsOf: ["-vignette", "0x\(clamp(radius, 1, 100))"])

            case "brightness":
                let value = op["value"] as? Int ?? 100
                // ImageMagick modulate: brightness, saturation, hue
                magickArgs.append(contentsOf: ["-modulate", "\(clamp(value, 0, 300)),100,100"])

            case "contrast":
                let value = op["value"] as? Int ?? 0
                if value > 0 {
                    for _ in 0..<min(value, 5) { magickArgs.append("-contrast") }
                } else if value < 0 {
                    for _ in 0..<min(abs(value), 5) { magickArgs.append("+contrast") }
                }

            case "saturation":
                let value = op["value"] as? Int ?? 100
                magickArgs.append(contentsOf: ["-modulate", "100,\(clamp(value, 0, 300)),100"])

            case "border":
                let width = op["width"] as? Int ?? 10
                let color = sanitizeColor(op["color"] as? String ?? "black")
                magickArgs.append(contentsOf: ["-bordercolor", color, "-border", "\(clamp(width, 1, 200))"])

            case "watermark":
                let text = sanitizeText(op["text"] as? String ?? "")
                if !text.isEmpty {
                    let size = op["font_size"] as? Int ?? 24
                    let color = sanitizeColor(op["color"] as? String ?? "white")
                    let gravity = sanitizeGravity(op["position"] as? String ?? "southeast")
                    magickArgs.append(contentsOf: [
                        "-gravity", gravity,
                        "-fill", color,
                        "-pointsize", "\(clamp(size, 8, 200))",
                        "-annotate", "+10+10", text
                    ])
                }

            case "compress":
                let quality = op["quality"] as? Int ?? 85
                magickArgs.append(contentsOf: ["-quality", "\(clamp(quality, 1, 100))"])

            default:
                continue
            }
        }

        magickArgs.append(outputPath)

        // Execute ImageMagick
        let result = await runProcess(executable: "magick", arguments: magickArgs)

        guard result.exitCode == 0 else {
            return "Error: ImageMagick failed — \(result.stderr.prefix(500))"
        }

        // Store in FileVault
        let mime = FileVault.mimeType(for: outputPath)
        let name = "edited_\((inputPath as NSString).lastPathComponent)"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: mime) else {
            return "Error: Failed to store output in FileVault"
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Photo edited successfully (\(operations.count) operation(s) applied).\nDownload: \(url)"
    }

    // MARK: - Remove Background

    /// AI background removal via Python rembg.
    func removeBackground(inputPath: String) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found at \(inputPath)"
        }
        guard isImageFile(inputPath) else {
            return "Error: Input file does not appear to be a valid image"
        }

        let outputPath = NSTemporaryDirectory() + "torbo_nobg_\(UUID().uuidString).png"

        let result = await runProcess(
            executable: "python3",
            arguments: ["-m", "rembg", "i", inputPath, outputPath]
        )

        guard result.exitCode == 0, fm.fileExists(atPath: outputPath) else {
            return "Error: Background removal failed — \(result.stderr.prefix(500))"
        }

        let name = "nobg_\((inputPath as NSString).lastPathComponent.replacingOccurrences(of: (inputPath as NSString).pathExtension, with: "png"))"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: "image/png") else {
            return "Error: Failed to store output in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Background removed successfully.\nDownload: \(url)"
    }

    // MARK: - Photo Composite

    /// Layer multiple images with position and opacity.
    func composite(basePath: String, layers: [[String: Any]]) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath) else {
            return "Error: Base image not found at \(basePath)"
        }

        let outputPath = NSTemporaryDirectory() + "torbo_comp_\(UUID().uuidString).png"

        // Start with copying base
        var currentInput = basePath

        for (i, layer) in layers.enumerated() {
            guard let layerPath = layer["path"] as? String, fm.fileExists(atPath: layerPath) else {
                continue
            }
            let x = layer["x"] as? Int ?? 0
            let y = layer["y"] as? Int ?? 0
            let opacity = layer["opacity"] as? Int ?? 100
            let tempOut = i < layers.count - 1
                ? NSTemporaryDirectory() + "torbo_comp_step\(i)_\(UUID().uuidString).png"
                : outputPath

            var args = [currentInput]
            args.append(contentsOf: [layerPath, "-geometry", "+\(x)+\(y)"])
            if opacity < 100 {
                let pct = Double(clamp(opacity, 0, 100)) / 100.0
                args.append(contentsOf: ["-define", "compose:args=\(String(format: "%.0f", pct * 100))"])
            }
            args.append(contentsOf: ["-composite", tempOut])

            let result = await runProcess(executable: "magick", arguments: args)
            if result.exitCode != 0 {
                return "Error: Composite layer \(i) failed — \(result.stderr.prefix(500))"
            }

            // Clean up intermediate files
            if i > 0 { try? fm.removeItem(atPath: currentInput) }
            currentInput = tempOut
        }

        guard fm.fileExists(atPath: outputPath) else {
            return "Error: Composite operation produced no output"
        }

        let name = "composite_\(UUID().uuidString.prefix(8)).png"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: "image/png") else {
            return "Error: Failed to store output in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Composite created (\(layers.count) layer(s)).\nDownload: \(url)"
    }

    // MARK: - Helpers

    private func isImageFile(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(8))
        // PNG
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        // JPEG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        // GIF
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return true }
        // WebP (RIFF....WEBP)
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return true }
        // BMP
        if bytes.starts(with: [0x42, 0x4D]) { return true }
        // TIFF
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        // SVG (text file starting with <)
        if bytes[0] == 0x3C { return true }
        return false
    }

    private func sanitizeText(_ text: String) -> String {
        // Remove shell-dangerous characters for ImageMagick text overlay
        var cleaned = text
        for ch in ["'", "\"", "`", "$", "\\", ";", "|", "&", "(", ")", "{", "}", "<", ">"] {
            cleaned = cleaned.replacingOccurrences(of: ch, with: "")
        }
        return String(cleaned.prefix(200))
    }

    private func sanitizeColor(_ color: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#"))
        let cleaned = String(color.unicodeScalars.filter { allowed.contains($0) })
        return String(cleaned.prefix(20))
    }

    private func sanitizeGravity(_ gravity: String) -> String {
        let valid = ["northwest", "north", "northeast", "west", "center", "east", "southwest", "south", "southeast"]
        return valid.contains(gravity.lowercased()) ? gravity.capitalized : "SouthEast"
    }

    private func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        max(low, min(high, value))
    }

    // MARK: - Process Execution

    struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(executable: String, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            // Search common paths for the executable
            let searchPaths = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
            let fullPath = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0 + executable) }).map { $0 + executable } ?? executable
            proc.executableURL = URL(fileURLWithPath: fullPath)
            proc.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            do {
                try proc.run()
            } catch {
                continuation.resume(returning: ProcessResult(stdout: "", stderr: "Failed to launch \(executable): \(error)", exitCode: -1))
                return
            }

            // Timeout: kill process if it runs too long
            let timeoutTask = DispatchWorkItem { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: timeoutTask)

            proc.waitUntilExit()
            timeoutTask.cancel()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            continuation.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
        }
    }

    // MARK: - Tool Definitions

    static let editPhotoToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "edit_photo",
            "description": "Edit a photo with one or more operations: resize, crop, rotate, flip, grayscale, sepia, blur, sharpen, vignette, brightness, contrast, saturation, border, watermark, compress, convert format. Operations are applied sequentially.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the input image file"],
                    "operations": [
                        "type": "array",
                        "description": "Array of operations to apply sequentially",
                        "items": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "enum": ["resize", "crop", "rotate", "flip", "grayscale", "sepia", "blur", "sharpen", "vignette", "brightness", "contrast", "saturation", "border", "watermark", "compress"]],
                                "width": ["type": "integer", "description": "Width in pixels (resize, crop)"],
                                "height": ["type": "integer", "description": "Height in pixels (resize, crop)"],
                                "x": ["type": "integer", "description": "X offset (crop)"],
                                "y": ["type": "integer", "description": "Y offset (crop)"],
                                "degrees": ["type": "number", "description": "Rotation degrees"],
                                "direction": ["type": "string", "enum": ["horizontal", "vertical"], "description": "Flip direction"],
                                "radius": ["type": "number", "description": "Effect radius (blur, sharpen, vignette)"],
                                "value": ["type": "integer", "description": "Effect value (brightness 0-300, contrast -5 to 5, saturation 0-300, quality 1-100)"],
                                "intensity": ["type": "integer", "description": "Sepia intensity 0-100"],
                                "text": ["type": "string", "description": "Watermark text"],
                                "color": ["type": "string", "description": "Color name or hex (border, watermark)"],
                                "position": ["type": "string", "description": "Watermark position: northwest, north, northeast, west, center, east, southwest, south, southeast"],
                                "font_size": ["type": "integer", "description": "Watermark font size"],
                                "quality": ["type": "integer", "description": "Compression quality 1-100"]
                            ] as [String: Any],
                            "required": ["action"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "output_format": ["type": "string", "description": "Output format: png, jpg, webp, gif, bmp (optional, defaults to input format)"]
                ] as [String: Any],
                "required": ["input_path", "operations"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let removeBackgroundToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "remove_background",
            "description": "Remove the background from an image using AI (rembg). Outputs a PNG with transparent background.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the input image file"]
                ] as [String: Any],
                "required": ["input_path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let photoCompositeToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "photo_composite",
            "description": "Layer multiple images together with position and opacity control.",
            "parameters": [
                "type": "object",
                "properties": [
                    "base_path": ["type": "string", "description": "Path to the base/background image"],
                    "layers": [
                        "type": "array",
                        "description": "Array of layers to composite on top",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Path to the layer image"],
                                "x": ["type": "integer", "description": "X position offset"],
                                "y": ["type": "integer", "description": "Y position offset"],
                                "opacity": ["type": "integer", "description": "Opacity 0-100"]
                            ] as [String: Any],
                            "required": ["path"]
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["base_path", "layers"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
