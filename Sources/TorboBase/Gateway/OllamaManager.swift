import Foundation

actor OllamaManager {
    static let shared = OllamaManager()

    private let baseURL = "http://127.0.0.1:11434"
    private var process: Process?

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/bin/ollama") ||
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
    }

    var isRunning: Bool {
        get async {
            guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
            do {
                let (_, resp) = try await URLSession.shared.data(from: url)
                return (resp as? HTTPURLResponse)?.statusCode == 200
            } catch { return false }
        }
    }

    private var ollamaPath: String? {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama") { return "/opt/homebrew/bin/ollama" }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/ollama") { return "/usr/local/bin/ollama" }
        return nil
    }

    func checkAndUpdate() async {
        let installed = isInstalled
        let running = await isRunning
        var models: [String] = []
        if running { models = await fetchModelNames() }
        await MainActor.run {
            AppState.shared.ollamaRunning = running
            AppState.shared.ollamaModels = models
            if !installed {
                AppState.shared.serverError = "Ollama not installed"
            }
        }
    }

    func ensureRunning() async {
        guard isInstalled else { return }
        if await isRunning {
            await MainActor.run { AppState.shared.ollamaRunning = true }
            return
        }
        await startOllama()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await isRunning {
                await MainActor.run { AppState.shared.ollamaRunning = true }
                let models = await fetchModelNames()
                await MainActor.run { AppState.shared.ollamaModels = models }
                return
            }
        }
        await MainActor.run { AppState.shared.serverError = "Ollama failed to start" }
    }

    private func startOllama() async {
        guard let path = ollamaPath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:11434"
        proc.environment = env
        do {
            try proc.run()
            self.process = proc
            print("[Ollama] Started")
        } catch {
            print("[Ollama] Failed to start: \(error)")
        }
    }

    private func fetchModelNames() async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { $0["name"] as? String }
            }
        } catch {}
        return []
    }
}
