// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Terminal Session
// PTY lifecycle: openpty(), shell process, async I/O, resize.
#if os(macOS)
import Foundation
import Darwin

@MainActor
class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "zsh"
    @Published var isRunning: Bool = false

    var onOutput: ((Data) -> Void)?

    /// Accumulated PTY output for replay when WebView is recreated (e.g. tab switch).
    /// Capped at 1MB to avoid unbounded growth.
    private(set) var outputBuffer = Data()
    private static let maxBufferSize = 1_048_576

    /// Last known terminal dimensions — used to detect size changes on WebView recreation.
    private(set) var lastCols: UInt16 = 80
    private(set) var lastRows: UInt16 = 24

    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var process: Process?
    private var masterHandle: FileHandle?

    private var defaultShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    func start() {
        guard !isRunning else { return }

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            TorboLog.error("Failed to open PTY: \(String(cString: strerror(errno)))", subsystem: "Terminal")
            return
        }
        masterFD = master
        slaveFD = slave

        // Set initial window size
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)

        // Configure shell process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: defaultShell)
        proc.arguments = ["--login"]
        proc.standardInput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardOutput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardError = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)

        // Build environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        proc.environment = env

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }

        do {
            try proc.run()
        } catch {
            TorboLog.error("Failed to start shell: \(error)", subsystem: "Terminal")
            close(masterFD)
            close(slaveFD)
            masterFD = -1
            slaveFD = -1
            return
        }

        // Parent closes slave — child owns it
        close(slaveFD)
        slaveFD = -1

        process = proc
        isRunning = true

        // Update title with shell name
        let shellName = (defaultShell as NSString).lastPathComponent
        title = shellName

        // Read PTY output asynchronously
        let handle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        masterHandle = handle
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Accumulate for replay on WebView recreation
                self.outputBuffer.append(data)
                if self.outputBuffer.count > Self.maxBufferSize {
                    // Trim front half to stay within cap
                    self.outputBuffer = Data(self.outputBuffer.suffix(Self.maxBufferSize / 2))
                }
                self.onOutput?(data)
            }
        }
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = Darwin.write(masterFD, ptr, buffer.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        lastCols = cols
        lastRows = rows
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    /// Force running processes to redraw by toggling the PTY window size.
    /// Sends two SIGWINCH signals — the process ends up at the original size.
    func forceRedraw() {
        guard masterFD >= 0 else { return }
        var ws = winsize()
        guard ioctl(masterFD, TIOCGWINSZ, &ws) == 0 else { return }
        let origCols = ws.ws_col
        ws.ws_col = origCols > 1 ? origCols - 1 : origCols + 1
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        ws.ws_col = origCols
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func stop() {
        masterHandle?.readabilityHandler = nil
        masterHandle = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil

        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        if slaveFD >= 0 {
            close(slaveFD)
            slaveFD = -1
        }

        isRunning = false
    }

    deinit {
        masterHandle?.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        if masterFD >= 0 { close(masterFD) }
        if slaveFD >= 0 { close(slaveFD) }
    }
}
#endif
