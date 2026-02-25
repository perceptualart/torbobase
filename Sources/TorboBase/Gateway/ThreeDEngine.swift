// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — 3D Model Creation Engine
// LLM writes Blender Python scripts, executes headless, exports models.
// Tools: create_3d_model, render_3d

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor ThreeDEngine {
    static let shared = ThreeDEngine()

    private let timeout: TimeInterval = 300 // 5 minutes for Blender

    // MARK: - Create 3D Model

    /// LLM generates a Blender Python script from description, executes it headless,
    /// exports the model + renders a preview image.
    func createModel(description: String, outputFormat: String = "glb", apiKeys: [String: String] = [:]) async -> String {
        let validFormats = ["obj", "stl", "glb", "fbx"]
        let format = validFormats.contains(outputFormat.lowercased()) ? outputFormat.lowercased() : "glb"

        let outputModelPath = NSTemporaryDirectory() + "torbo_3d_\(UUID().uuidString).\(format)"
        let outputRenderPath = NSTemporaryDirectory() + "torbo_3d_preview_\(UUID().uuidString).png"

        // Ask LLM to generate Blender Python script
        let systemPrompt = """
        You are an expert Blender Python (bpy) scripter. Generate a complete Blender Python script that:
        1. Clears the default scene
        2. Creates the 3D model described by the user
        3. Adds materials with colors
        4. Sets up a camera and lighting
        5. Exports to \(format) at: \(outputModelPath)
        6. Renders a preview image (1080x1080) to: \(outputRenderPath)

        Output ONLY the Python code — no explanation, no markdown fences.
        Only use: bpy, math, random, mathutils. Do NOT use: os, subprocess, socket, urllib, sys, importlib.
        """

        let script = await callLLM(system: systemPrompt, user: description, apiKeys: apiKeys)

        guard !script.isEmpty else {
            return "Error: LLM did not generate a Blender script"
        }

        // Sanitize the script — block dangerous imports
        guard isScriptSafe(script) else {
            return "Error: Generated script contains blocked imports (os, subprocess, socket, etc.)"
        }

        // Write script to temp file
        let scriptPath = NSTemporaryDirectory() + "torbo_3d_script_\(UUID().uuidString).py"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            return "Error: Failed to write script: \(error)"
        }

        // Execute Blender headless
        let blenderPaths = ["/opt/homebrew/bin/blender", "/usr/local/bin/blender", "/Applications/Blender.app/Contents/MacOS/Blender"]
        guard let blenderPath = blenderPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            try? FileManager.default.removeItem(atPath: scriptPath)
            return "Error: Blender not found. Install with: brew install --cask blender"
        }

        let result = await runProcess(
            executablePath: blenderPath,
            arguments: ["--background", "--python", scriptPath]
        )

        // Clean up script
        try? FileManager.default.removeItem(atPath: scriptPath)

        let fm = FileManager.default
        var outputs: [String] = []

        // Store model if it was created
        if fm.fileExists(atPath: outputModelPath) {
            let mime = FileVault.mimeType(for: outputModelPath)
            let name = "model_\(UUID().uuidString.prefix(8)).\(format)"
            if let entry = await FileVault.shared.store(sourceFilePath: outputModelPath, originalName: name, mimeType: mime) {
                let baseURL = FileVault.resolveBaseURL(port: 8420)
                let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
                outputs.append("3D Model (\(format)): \(url)")
            }
            try? fm.removeItem(atPath: outputModelPath)
        }

        // Store preview render if it was created
        if fm.fileExists(atPath: outputRenderPath) {
            if let entry = await FileVault.shared.store(sourceFilePath: outputRenderPath, originalName: "preview.png", mimeType: "image/png") {
                let baseURL = FileVault.resolveBaseURL(port: 8420)
                let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
                outputs.append("Preview: \(url)")
            }
            try? fm.removeItem(atPath: outputRenderPath)
        }

        if outputs.isEmpty {
            let errSnippet = String(result.stderr.suffix(500))
            return "Error: Blender produced no output.\nExit code: \(result.exitCode)\nLog: \(errSnippet)"
        }

        return "3D model created successfully.\n" + outputs.joined(separator: "\n")
    }

    // MARK: - Render 3D

    /// Render an existing 3D model file to a PNG image.
    func renderModel(inputPath: String, resolution: Int = 1080, apiKeys: [String: String] = [:]) async -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputPath) else {
            return "Error: Input file not found at \(inputPath)"
        }

        let outputPath = NSTemporaryDirectory() + "torbo_render_\(UUID().uuidString).png"

        // Generate import + render script based on file extension
        let ext = (inputPath as NSString).pathExtension.lowercased()
        let importCmd: String
        switch ext {
        case "obj": importCmd = "bpy.ops.wm.obj_import(filepath='\(inputPath)')"
        case "stl": importCmd = "bpy.ops.wm.stl_import(filepath='\(inputPath)')"
        case "glb", "gltf": importCmd = "bpy.ops.import_scene.gltf(filepath='\(inputPath)')"
        case "fbx": importCmd = "bpy.ops.import_scene.fbx(filepath='\(inputPath)')"
        default: return "Error: Unsupported 3D format: \(ext)"
        }

        let script = """
        import bpy, math
        # Clear scene
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.object.delete()
        # Import model
        \(importCmd)
        # Auto-frame camera
        bpy.ops.object.camera_add(location=(5, -5, 5))
        cam = bpy.context.object
        cam.rotation_euler = (math.radians(55), 0, math.radians(45))
        bpy.context.scene.camera = cam
        # Add light
        bpy.ops.object.light_add(type='SUN', location=(10, 10, 10))
        # Render settings
        bpy.context.scene.render.resolution_x = \(resolution)
        bpy.context.scene.render.resolution_y = \(resolution)
        bpy.context.scene.render.filepath = '\(outputPath)'
        bpy.context.scene.render.image_settings.file_format = 'PNG'
        bpy.ops.render.render(write_still=True)
        """

        let scriptPath = NSTemporaryDirectory() + "torbo_render_script_\(UUID().uuidString).py"
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let blenderPaths = ["/opt/homebrew/bin/blender", "/usr/local/bin/blender", "/Applications/Blender.app/Contents/MacOS/Blender"]
        guard let blenderPath = blenderPaths.first(where: { fm.fileExists(atPath: $0) }) else {
            try? fm.removeItem(atPath: scriptPath)
            return "Error: Blender not found"
        }

        let result = await runProcess(executablePath: blenderPath, arguments: ["--background", "--python", scriptPath])
        try? fm.removeItem(atPath: scriptPath)

        guard fm.fileExists(atPath: outputPath) else {
            return "Error: Render failed (exit \(result.exitCode)): \(result.stderr.suffix(500))"
        }

        guard let entry = await FileVault.shared.store(sourceFilePath: outputPath, originalName: "render.png", mimeType: "image/png") else {
            return "Error: Failed to store render in FileVault"
        }

        try? fm.removeItem(atPath: outputPath)

        let baseURL = FileVault.resolveBaseURL(port: 8420)
        let url = await FileVault.shared.downloadURL(for: entry, baseURL: baseURL)
        return "Rendered at \(resolution)x\(resolution).\nDownload: \(url)"
    }

    // MARK: - Script Safety

    private func isScriptSafe(_ script: String) -> Bool {
        let blocked = ["import os", "import subprocess", "import socket", "import urllib",
                       "import sys", "import importlib", "import shutil", "import pathlib",
                       "__import__", "exec(", "eval(", "compile("]
        for pattern in blocked {
            if script.contains(pattern) { return false }
        }
        return true
    }

    // MARK: - LLM Call (reuses DiagramEngine pattern)

    private func callLLM(system: String, user: String, apiKeys: [String: String]) async -> String {
        // Try Ollama first (needs a capable model for code generation)
        let ollamaResult = await callOllama(system: system, user: user)
        if !ollamaResult.isEmpty { return ollamaResult }

        if let key = apiKeys["ANTHROPIC_API_KEY"] ?? KeychainManager.get("apikey.ANTHROPIC_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "anthropic", apiKey: key)
        }
        if let key = apiKeys["OPENAI_API_KEY"] ?? KeychainManager.get("apikey.OPENAI_API_KEY"), !key.isEmpty {
            return await callCloud(system: system, user: user, provider: "openai", apiKey: key)
        }
        return ""
    }

    private func callOllama(system: String, user: String) async -> String {
        guard let url = URL(string: "\(OllamaManager.baseURL)/api/generate") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = ["model": "qwen2.5:7b", "system": system, "prompt": user, "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? String { return response }
        } catch {}
        return ""
    }

    private func callCloud(system: String, user: String, provider: String, apiKey: String) async -> String {
        if provider == "anthropic" {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let body: [String: Any] = [
                "model": "claude-sonnet-4-20250514", "max_tokens": 8192,
                "system": system, "messages": [["role": "user", "content": user]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String { return text }
            } catch {}
        } else {
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return "" }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let body: [String: Any] = [
                "model": "gpt-4o-mini",
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let text = msg["content"] as? String { return text }
            } catch {}
        }
        return ""
    }

    // MARK: - Process

    private func runProcess(executablePath: String, arguments: [String]) async -> PhotoEditor.ProcessResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            do { try proc.run() } catch {
                continuation.resume(returning: PhotoEditor.ProcessResult(stdout: "", stderr: "Failed to launch: \(error)", exitCode: -1))
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

    static let create3DModelToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_3d_model",
            "description": "Generate a 3D model from a text description. Uses Blender headless to create geometry, materials, lighting, and exports the model file plus a preview render.",
            "parameters": [
                "type": "object",
                "properties": [
                    "description": ["type": "string", "description": "Description of the 3D model to create"],
                    "format": ["type": "string", "enum": ["glb", "obj", "stl", "fbx"], "description": "Output format (default: glb)"]
                ] as [String: Any],
                "required": ["description"]
            ] as [String: Any]
        ] as [String: Any]
    ]

    static let render3DToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "render_3d",
            "description": "Render an existing 3D model file to a PNG image with configurable resolution.",
            "parameters": [
                "type": "object",
                "properties": [
                    "input_path": ["type": "string", "description": "Path to the 3D model file (obj, stl, glb, fbx)"],
                    "resolution": ["type": "integer", "description": "Render resolution in pixels (square, default: 1080)"]
                ] as [String: Any],
                "required": ["input_path"]
            ] as [String: Any]
        ] as [String: Any]
    ]
}
