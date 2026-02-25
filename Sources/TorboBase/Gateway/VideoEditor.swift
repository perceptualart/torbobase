// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Video Editing Engine
// Wraps ffmpeg and ffprobe for video operations.
// Tools: edit_video, extract_audio, video_info, video_thumbnail

import Foundation

actor VideoEditor {
    static let shared = VideoEditor()

    /// Max input file size: 2 GB
    private let maxFileSize: Int64 = 2 * 1024 * 1024 * 1024
    /// Execution timeout: 5 minutes
    private let timeout: TimeInterval = 300

    // MARK: - Edit Video

    func editVideo(inputPath: String, operations: [[String: Any]], outputFormat: String? = nil) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found at \(inputPath)"
        }

        guard let attrs = try? fm.attributesOfItem(atPath: inputPath),
              let size = attrs[.size] as? Int64, size <= maxFileSize else {
            return "Error: File too large (max 2GB)"
        }

        let ext = outputFormat ?? (inputPath as NSString).pathExtension
        let outputPath = NSTemporaryDirectory() + "torbo_video_\(UUID().uuidString).\(ext)"

        // Build ffmpeg command
        var args = ["-y", "-i", inputPath]

        var videoFilters: [String] = []

        for op in operations {
            guard let action = op["action"] as? String else { continue }

            switch action {
            case "trim":
                if let start = op["start"] as? String {
                    args.append(contentsOf: ["-ss", sanitizeTimestamp(start)])
                }
                if let end = op["end"] as? String {
                    args.append(contentsOf: ["-to", sanitizeTimestamp(end)])
                }
                if let duration = op["duration"] as? Double {
                    args.append(contentsOf: ["-t", String(format: "%.2f", duration)])
                }

            case "resize":
                let width = op["width"] as? Int ?? -1
                let height = op["height"] as? Int ?? -1
                videoFilters.append("scale=\(width):\(height)")

            case "crop":
                if let w = op["width"] as? Int, let h = op["height"] as? Int {
                    let x = op["x"] as? Int ?? 0
                    let y = op["y"] as? Int ?? 0
                    videoFilters.append("crop=\(w):\(h):\(x):\(y)")
                }

            case "compress":
                let crf = op["crf"] as? Int ?? 28
                args.append(contentsOf: ["-crf", "\(clamp(crf, 0, 51))"])
                if let preset = op["preset"] as? String, ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"].contains(preset) {
                    args.append(contentsOf: ["-preset", preset])
                }

            case "speed":
                let factor = op["factor"] as? Double ?? 1.0
                let clamped = max(0.25, min(4.0, factor))
                videoFilters.append("setpts=\(String(format: "%.4f", 1.0 / clamped))*PTS")

            case "text_overlay":
                let text = sanitizeDrawText(op["text"] as? String ?? "")
                if !text.isEmpty {
                    let size = op["font_size"] as? Int ?? 48
                    let color = sanitizeColor(op["color"] as? String ?? "white")
                    let x = op["x"] as? Int ?? 100
                    let y = op["y"] as? Int ?? 100
                    videoFilters.append("drawtext=text='\(text)':fontsize=\(clamp(size, 8, 200)):fontcolor=\(color):x=\(x):y=\(y)")
                }

            case "rotate":
                let degrees = op["degrees"] as? Int ?? 90
                switch degrees {
                case 90: videoFilters.append("transpose=1")
                case 180: videoFilters.append("transpose=1,transpose=1")
                case 270: videoFilters.append("transpose=2")
                default: break
                }

            case "flip":
                let direction = op["direction"] as? String ?? "vertical"
                videoFilters.append(direction == "horizontal" ? "hflip" : "vflip")

            case "fade_in":
                let duration = op["duration"] as? Double ?? 1.0
                videoFilters.append("fade=t=in:st=0:d=\(String(format: "%.1f", duration))")

            case "fade_out":
                let duration = op["duration"] as? Double ?? 1.0
                let start = op["start"] as? Double ?? 0
                videoFilters.append("fade=t=out:st=\(String(format: "%.1f", start)):d=\(String(format: "%.1f", duration))")

            case "remove_audio":
                args.append("-an")

            case "gif":
                videoFilters.append("fps=\(op["fps"] as? Int ?? 15),scale=\(op["width"] as? Int ?? 480):-1")

            default:
                continue
            }
        }

        if !videoFilters.isEmpty {
            args.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])
        }

        args.append(outputPath)

        let result = await runProcess(executable: "ffmpeg", arguments: args)

        guard result.exitCode == 0, fm.fileExists(atPath: outputPath) else {
            return "Error: ffmpeg failed — \(result.stderr.suffix(500))"
        }

        let mime = FileVault.mimeType(for: outputPath)
        let name = "edited_\((inputPath as NSString).lastPathComponent)"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: mime) else {
            return "Error: Failed to store output in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Video edited successfully (\(operations.count) operation(s)).\nDownload: \(url)"
    }

    // MARK: - Extract Audio

    func extractAudio(inputPath: String, format: String = "mp3") async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found"
        }

        let validFormats = ["mp3", "aac", "wav", "flac", "ogg"]
        let fmt = validFormats.contains(format) ? format : "mp3"

        let outputPath = NSTemporaryDirectory() + "torbo_audio_\(UUID().uuidString).\(fmt)"

        let codec: String
        switch fmt {
        case "mp3": codec = "libmp3lame"
        case "aac": codec = "aac"
        case "wav": codec = "pcm_s16le"
        case "flac": codec = "flac"
        case "ogg": codec = "libvorbis"
        default: codec = "libmp3lame"
        }

        let result = await runProcess(
            executable: "ffmpeg",
            arguments: ["-y", "-i", inputPath, "-vn", "-acodec", codec, outputPath]
        )

        guard result.exitCode == 0, fm.fileExists(atPath: outputPath) else {
            return "Error: Audio extraction failed — \(result.stderr.suffix(500))"
        }

        let mime = FileVault.mimeType(for: outputPath)
        let name = "audio_\((inputPath as NSString).lastPathComponent.replacingOccurrences(of: (inputPath as NSString).pathExtension, with: fmt))"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: mime) else {
            return "Error: Failed to store output in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Audio extracted as \(fmt).\nDownload: \(url)"
    }

    // MARK: - Video Info

    func videoInfo(inputPath: String) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found"
        }

        let result = await runProcess(
            executable: "ffprobe",
            arguments: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", inputPath]
        )

        guard result.exitCode == 0 else {
            return "Error: ffprobe failed — \(result.stderr.suffix(500))"
        }

        // Parse JSON and extract key info
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result.stdout
        }

        var info: [String] = []

        if let format = json["format"] as? [String: Any] {
            if let duration = format["duration"] as? String, let d = Double(duration) {
                info.append("Duration: \(formatDuration(d))")
            }
            if let size = format["size"] as? String, let s = Int64(size) {
                info.append("Size: \(formatBytes(s))")
            }
            if let bitrate = format["bit_rate"] as? String, let b = Int(bitrate) {
                info.append("Bitrate: \(b / 1000) kbps")
            }
            if let name = format["format_long_name"] as? String {
                info.append("Format: \(name)")
            }
        }

        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                let codecType = stream["codec_type"] as? String ?? ""
                let codecName = stream["codec_name"] as? String ?? "unknown"
                if codecType == "video" {
                    let w = stream["width"] as? Int ?? 0
                    let h = stream["height"] as? Int ?? 0
                    info.append("Video: \(codecName) \(w)x\(h)")
                    if let fps = stream["r_frame_rate"] as? String {
                        info.append("FPS: \(fps)")
                    }
                } else if codecType == "audio" {
                    let sr = stream["sample_rate"] as? String ?? "?"
                    let channels = stream["channels"] as? Int ?? 0
                    info.append("Audio: \(codecName) \(sr)Hz \(channels)ch")
                }
            }
        }

        return info.joined(separator: "\n")
    }

    // MARK: - Video Thumbnail

    func videoThumbnail(inputPath: String, timestamp: String = "00:00:01") async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found"
        }

        let outputPath = NSTemporaryDirectory() + "torbo_thumb_\(UUID().uuidString).png"

        let result = await runProcess(
            executable: "ffmpeg",
            arguments: ["-y", "-i", inputPath, "-ss", sanitizeTimestamp(timestamp), "-vframes", "1", outputPath]
        )

        guard result.exitCode == 0, fm.fileExists(atPath: outputPath) else {
            return "Error: Thumbnail extraction failed — \(result.stderr.suffix(500))"
        }

        let name = "thumb_\((inputPath as NSString).lastPathComponent).png"
        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: name, mimeType: "image/png") else {
            return "Error: Failed to store output in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Thumbnail extracted at \(timestamp).\nDownload: \(url)"
    }

    // MARK: - Helpers

    private func sanitizeTimestamp(_ ts: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789:.")
        return String(ts.unicodeScalars.filter { allowed.contains($0) }).prefix(12).description
    }

    private func sanitizeDrawText(_ text: String) -> String {
        var cleaned = text
        for ch in ["'", "\"", "\\", ";", ":", "{", "}", "[", "]"] {
            cleaned = cleaned.replacingOccurrences(of: ch, with: "")
        }
        return String(cleaned.prefix(200))
    }

    private func sanitizeColor(_ color: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#"))
        return String(String(color.unicodeScalars.filter { allowed.contains($0) }).prefix(20))
    }

    private func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        max(low, min(high, value))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
    }

    // MARK: - Process Execution

    private func runProcess(executable: String, arguments: [String]) async -> PhotoEditor.ProcessResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            let searchPaths = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"]
            let fullPath = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0 + executable) }).map { $0 + executable } ?? executable
            proc.executableURL = URL(fileURLWithPath: fullPath)
            proc.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            do { try proc.run() } catch {
                continuation.resume(returning: PhotoEditor.ProcessResult(stdout: "", stderr: "Failed to launch \(executable): \(error)", exitCode: -1))
                return
            }

            let timeoutTask = DispatchWorkItem { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: timeoutTask)

            proc.waitUntilExit()
            timeoutTask.cancel()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            continuation.resume(returning: PhotoEditor.ProcessResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
        }
    }

    // MARK: - Tool Definitions

    static let editVideoToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "edit_video",
            "description": "Edit a video with operations: trim, resize, crop, compress, speed, text_overlay, rotate, flip, fade_in, fade_out, remove_audio, gif conversion. Operations are applied sequentially.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the input video file"],
                    "operations": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "action": ["type": "string", "enum": ["trim", "resize", "crop", "compress", "speed", "text_overlay", "rotate", "flip", "fade_in", "fade_out", "remove_audio", "gif"]],
                                "start": ["type": "string", "description": "Start time HH:MM:SS (trim)"],
                                "end": ["type": "string", "description": "End time HH:MM:SS (trim)"],
                                "duration": ["type": "number", "description": "Duration in seconds (trim)"],
                                "width": ["type": "integer"], "height": ["type": "integer"],
                                "x": ["type": "integer"], "y": ["type": "integer"],
                                "crf": ["type": "integer", "description": "Compression quality 0-51 (lower=better, default 28)"],
                                "preset": ["type": "string", "description": "Encoding speed preset"],
                                "factor": ["type": "number", "description": "Speed factor 0.25-4.0"],
                                "text": ["type": "string"], "font_size": ["type": "integer"],
                                "color": ["type": "string"],
                                "degrees": ["type": "integer", "description": "Rotation: 90, 180, or 270"],
                                "direction": ["type": "string", "enum": ["horizontal", "vertical"]],
                                "fps": ["type": "integer", "description": "GIF frame rate"]
                            ] as [String: Any],
                            "required": ["action"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "output_format": ["type": "string", "description": "Output format: mp4, mov, avi, gif, webm"]
                ] as [String: Any],
                "required": ["input_path", "operations"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let extractAudioToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "extract_audio",
            "description": "Extract the audio track from a video file.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the input video file"],
                    "format": ["type": "string", "enum": ["mp3", "aac", "wav", "flac", "ogg"], "description": "Output audio format (default: mp3)"]
                ] as [String: Any],
                "required": ["input_path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let videoInfoToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "video_info",
            "description": "Get metadata about a video file: duration, resolution, codec, bitrate, audio info.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the video file"]
                ] as [String: Any],
                "required": ["input_path"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let videoThumbnailToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "video_thumbnail",
            "description": "Extract a single frame from a video as an image.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the video file"],
                    "timestamp": ["type": "string", "description": "Timestamp to extract frame at (HH:MM:SS format, default: 00:00:01)"]
                ] as [String: Any],
                "required": ["input_path"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
