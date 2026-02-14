// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — by Michael David Murphy
// Setup Wizard — first-launch experience with unmissable step numbering
#if canImport(SwiftUI)
import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome = 0
    case ollama = 1
    case models = 2
    case security = 3
    case apiKeys = 4
    case voiceKeys = 5
    case remoteAccess = 6
    case ready = 7

    var title: String {
        switch self {
        case .welcome: return "Welcome to Torbo Base"
        case .ollama: return "Local Inference"
        case .models: return "Starting Model"
        case .security: return "Access Level"
        case .apiKeys: return "Cloud Providers"
        case .voiceKeys: return "Voice & Image"
        case .remoteAccess: return "Remote Access"
        case .ready: return "Godspeed"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return ""
        case .ollama: return "Run language models locally on your machine"
        case .models: return "Pick a model to get started — add more later"
        case .security: return "Control what connected clients can do"
        case .apiKeys: return "Connect to cloud models (optional — skip if unsure)"
        case .voiceKeys: return "Enable voice and image features (optional)"
        case .remoteAccess: return "Access Torbo Base from anywhere (optional)"
        case .ready: return ""
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "circle.hexagongrid.fill"
        case .ollama: return "cpu"
        case .models: return "cube.fill"
        case .security: return "shield.checkered"
        case .apiKeys: return "cloud.fill"
        case .voiceKeys: return "waveform.circle.fill"
        case .remoteAccess: return "network"
        case .ready: return "checkmark.seal.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .welcome: return .cyan
        case .ollama: return .cyan
        case .models: return .purple
        case .security: return .green
        case .apiKeys: return .orange
        case .voiceKeys: return .pink
        case .remoteAccess: return .blue
        case .ready: return .cyan
        }
    }

    /// Total steps excluding welcome and ready (user-facing count)
    static var userStepCount: Int { 6 }

    /// User-facing step number (1-based, nil for welcome/ready)
    var stepNumber: Int? {
        switch self {
        case .welcome, .ready: return nil
        default: return rawValue
        }
    }
}

struct SetupWizardView: View {
    @Environment(AppState.self) private var state
    @State private var currentStep: SetupStep = .welcome
    @State private var selectedModel: String = "qwen2.5:7b"
    @State private var selectedLevel: AccessLevel = .chatOnly
    @State private var orbAppeared = false
    @State private var skipOllama = false
    @State private var showAPIKeyInfo = false
    @State private var tailscaleInstalled = false
    @State private var tailscaleRunning = false
    @State private var tailscaleIP: String = ""
    @State private var keySaveTask: Task<Void, Never>?
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            // Background
            Color(nsColor: NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Step indicator bar (only on numbered steps)
                if currentStep.stepNumber != nil {
                    stepIndicatorBar
                        .padding(.top, 16)
                        .padding(.horizontal, 40)
                }

                Spacer()

                // Step content
                Group {
                    switch currentStep {
                    case .welcome: welcomeStep
                    case .ollama: ollamaStep
                    case .models: modelsStep
                    case .security: securityStep
                    case .apiKeys: apiKeysStep
                    case .voiceKeys: voiceKeysStep
                    case .remoteAccess: remoteAccessStep
                    case .ready: readyStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(currentStep)

                Spacer()

                // Navigation
                HStack {
                    if currentStep.rawValue > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                navigateBack()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left")
                                Text("Back")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 13))
                    }

                    Spacer()

                    if currentStep == .ready {
                        Button {
                            AppConfig.setupCompleted = true
                            state.setupCompleted = true
                            state.accessLevel = selectedLevel
                            onComplete()
                        } label: {
                            HStack(spacing: 6) {
                                Text("Launch Torbo Base")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.cyan)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                navigateForward()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(nextButtonLabel)
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }
        }
        .frame(width: 640, height: 600)
        .preferredColorScheme(.dark)
    }

    // MARK: - Step Header (big number on each step)

    @ViewBuilder
    private func stepHeader(step: SetupStep, headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // BIG step number
            if let num = step.stepNumber {
                Text("\(num)")
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundStyle(step.iconColor.opacity(0.25))
                    .frame(width: 52, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Icon + title
                HStack(spacing: 8) {
                    Image(systemName: step.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(step.iconColor.opacity(0.8))
                    Text(headline)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineSpacing(2)
            }

            Spacer()
        }
        .padding(.horizontal, 44)
    }

    // MARK: - Step Indicator Bar

    @ViewBuilder
    private var stepIndicatorBar: some View {
        if let stepNum = currentStep.stepNumber {
            VStack(spacing: 8) {
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(currentStep.iconColor)
                            .frame(width: geo.size.width * (CGFloat(stepNum) / CGFloat(SetupStep.userStepCount)), height: 3)
                            .animation(.easeInOut(duration: 0.4), value: currentStep)
                    }
                }
                .frame(height: 3)

                // Step dots with labels
                HStack(spacing: 0) {
                    ForEach(1...SetupStep.userStepCount, id: \.self) { num in
                        if let step = SetupStep(rawValue: num) {
                            let isCurrent = num == stepNum
                            let isComplete = num < stepNum

                            HStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(isComplete ? step.iconColor.opacity(0.3) : isCurrent ? step.iconColor : Color.white.opacity(0.06))
                                        .frame(width: 22, height: 22)
                                    if isComplete {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(step.iconColor)
                                    } else {
                                        Text("\(num)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(isCurrent ? .black : .white.opacity(0.25))
                                    }
                                }
                                Text(step.title)
                                    .font(.system(size: 8, weight: isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? .white.opacity(0.6) : .white.opacity(0.15))
                                    .lineLimit(1)
                            }

                            if num < SetupStep.userStepCount {
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Navigation Logic

    private var nextButtonLabel: String {
        switch currentStep {
        case .welcome: return "Get Started"
        case .apiKeys:
            return state.cloudAPIKeys.values.contains(where: { !$0.isEmpty }) ? "Next" : "Skip — I'll do this later"
        case .voiceKeys:
            return (state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty ? "Skip — I'll do this later" : "Next"
        case .remoteAccess:
            return tailscaleRunning ? "Next" : "Skip — local only for now"
        case .ollama:
            return skipOllama ? "Skip — cloud only" : "Continue"
        default:
            return "Continue"
        }
    }

    private func navigateForward() {
        var nextRaw = currentStep.rawValue + 1
        if currentStep == .ollama && skipOllama {
            nextRaw = SetupStep.security.rawValue
        }
        if let next = SetupStep(rawValue: nextRaw) {
            currentStep = next
        }
    }

    private func navigateBack() {
        var prevRaw = currentStep.rawValue - 1
        if currentStep == .security && skipOllama {
            prevRaw = SetupStep.ollama.rawValue
        }
        if let prev = SetupStep(rawValue: prevRaw) {
            currentStep = prev
        }
    }

    // MARK: - Welcome Step

    @ViewBuilder
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            OrbRenderer(
                audioLevels: Array(repeating: Float(0.2), count: 40),
                color: Color(hue: 0.52, saturation: 0.9, brightness: 1.0),
                isActive: false
            )
            .frame(width: 220, height: 220)
            .scaleEffect(orbAppeared ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
                    orbAppeared = true
                }
            }

            Text("TORBO BASE")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(4)

            Text("Your local inference gateway.\nPrivate. Powerful. Yours.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            // Cross-platform pitch
            VStack(spacing: 8) {
                Text("Works with any device on your network")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.cyan.opacity(0.6))

                HStack(spacing: 16) {
                    platformBadge(icon: "desktopcomputer", label: "Mac")
                    platformBadge(icon: "pc", label: "Windows")
                    platformBadge(icon: "iphone", label: "Phone")
                    platformBadge(icon: "ipad", label: "Tablet")
                }
            }
            .padding(.top, 4)

            Text("6 quick steps — takes about 2 minutes")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func platformBadge(icon: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.25))
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.15))
        }
    }

    // MARK: - Step 1: Ollama

    @ViewBuilder
    private var ollamaStep: some View {
        VStack(spacing: 16) {
            stepHeader(
                step: .ollama,
                headline: "Install Ollama",
                detail: "Ollama runs language models locally — no data leaves your machine.\nThis is optional. You can use cloud models instead."
            )

            VStack(alignment: .leading, spacing: 12) {
                instructionRow(icon: "1.circle.fill", text: "Download from ollama.com/download")
                instructionRow(icon: "2.circle.fill", text: "Or install via Homebrew: brew install ollama")
                instructionRow(icon: "3.circle.fill", text: "Launch Ollama — it runs in the menu bar")
            }
            .padding(.horizontal, 50)

            HStack(spacing: 12) {
                if state.ollamaRunning {
                    Label("Ollama detected!", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await OllamaManager.shared.ensureRunning() }
                    } label: {
                        Label("Check for Ollama", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 80)

            VStack(spacing: 6) {
                Toggle(isOn: $skipOllama) {
                    Text("I only want cloud models — skip local setup")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.cyan)
                .padding(.horizontal, 60)

                if skipOllama {
                    Text("You can install Ollama later from Settings → Models")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.2))
                }
            }
        }
    }

    // MARK: - Step 2: Models

    @ViewBuilder
    private var modelsStep: some View {
        VStack(spacing: 16) {
            stepHeader(
                step: .models,
                headline: "Choose a Starting Model",
                detail: "This will be downloaded to your machine for local use.\nFree, offline, and private. You can add more models later."
            )

            VStack(spacing: 4) {
                modelChoice("qwen2.5:7b", desc: "Excellent all-rounder — 4.4 GB", size: "7B")
                modelChoice("llama3.2:3b", desc: "Lightweight & fast — 2.0 GB", size: "3B")
                modelChoice("llama3.1:8b", desc: "Great performance — 4.7 GB", size: "8B")
                modelChoice("mistral:7b", desc: "Fast reasoning — 4.1 GB", size: "7B")
            }
            .padding(.horizontal, 50)

            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 10))
                Text("Models are stored locally — no ongoing cost, no internet needed")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.white.opacity(0.2))
        }
    }

    @ViewBuilder
    private func modelChoice(_ name: String, desc: String, size: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selectedModel == name ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedModel == name ? .cyan : .white.opacity(0.2))
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Text(size)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.08))
                .cornerRadius(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selectedModel == name ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selectedModel == name ? Color.cyan.opacity(0.3) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedModel = name }
    }

    // MARK: - Step 3: Security

    @ViewBuilder
    private var securityStep: some View {
        VStack(spacing: 16) {
            stepHeader(
                step: .security,
                headline: "Set Access Level",
                detail: "What can connected clients (like Cursor or Claude Desktop) do?\nYou can change this anytime from the main Torbo window."
            )

            VStack(spacing: 4) {
                ForEach([AccessLevel.chatOnly, .readFiles, .writeFiles], id: \.rawValue) { lvl in
                    HStack(spacing: 10) {
                        Image(systemName: selectedLevel == lvl ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedLevel == lvl ? lvl.color : .white.opacity(0.2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Level \(lvl.rawValue) — \(lvl.name)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                            Text(lvl.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer()
                        if lvl == .chatOnly {
                            Text("RECOMMENDED")
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.6))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.08))
                                .cornerRadius(3)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(selectedLevel == lvl ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selectedLevel == lvl ? lvl.color.opacity(0.3) : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedLevel = lvl }
                }
            }
            .padding(.horizontal, 50)

            // What this means in practice
            VStack(alignment: .leading, spacing: 4) {
                Text("WHAT THIS MEANS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.15))
                    .tracking(1)
                Text(accessLevelExplanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineSpacing(2)
            }
            .padding(.horizontal, 50)
            .padding(.top, 4)
        }
    }

    private var accessLevelExplanation: String {
        switch selectedLevel {
        case .chatOnly:
            return "Clients can send messages and get responses. They cannot read, write, or execute anything on your computer. This is the safest option."
        case .readFiles:
            return "Clients can chat and also read files from your approved folders (Desktop, Documents, Downloads). They cannot modify or delete anything."
        case .writeFiles:
            return "Clients can chat, read files, and create or modify files in your sandbox folders. They still cannot run programs or scripts."
        default:
            return ""
        }
    }

    // MARK: - Step 4: Cloud API Keys

    @ViewBuilder
    private var apiKeysStep: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                stepHeader(
                    step: .apiKeys,
                    headline: "Cloud Providers",
                    detail: "Connect to cloud models like Claude, GPT, and Gemini.\nCompletely optional — skip if you only want local models."
                )

                // What is an API key? (collapsible)
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAPIKeyInfo.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11))
                            Text("What is an API key? What does it cost?")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Image(systemName: showAPIKeyInfo ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.orange.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if showAPIKeyInfo {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow(
                                q: "What is it?",
                                a: "A secret password that lets Torbo Base talk to cloud AI services on your behalf. Each provider gives you one on their website."
                            )
                            infoRow(
                                q: "Does it cost money?",
                                a: "Yes — cloud providers charge per use (usually pennies per message). Each provider has a free tier or trial credits to start."
                            )
                            infoRow(
                                q: "Is it safe to paste here?",
                                a: "Yes. Keys are stored in your Mac's Keychain (the same vault Safari uses for passwords). They never leave your machine."
                            )
                            infoRow(
                                q: "Can I skip this?",
                                a: "Absolutely. If you have Ollama set up, you can run entirely locally with zero cloud dependency. Add keys later in Settings."
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .background(Color.orange.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 44)

                // Key entry fields
                VStack(spacing: 8) {
                    apiKeyRow(
                        provider: "Anthropic",
                        keyName: "ANTHROPIC_API_KEY",
                        models: "Claude Opus · Sonnet · Haiku",
                        getKeyURL: "console.anthropic.com",
                        color: .orange,
                        freeInfo: "$5 free credit on signup"
                    )
                    apiKeyRow(
                        provider: "OpenAI",
                        keyName: "OPENAI_API_KEY",
                        models: "GPT-4o · o1 · DALL-E · Whisper",
                        getKeyURL: "platform.openai.com/api-keys",
                        color: .green,
                        freeInfo: "Also powers voice & image features"
                    )
                    apiKeyRow(
                        provider: "Google",
                        keyName: "GOOGLE_API_KEY",
                        models: "Gemini 2.0 · Gemini Pro",
                        getKeyURL: "aistudio.google.com/apikey",
                        color: .blue,
                        freeInfo: "Free tier available"
                    )
                    apiKeyRow(
                        provider: "xAI",
                        keyName: "XAI_API_KEY",
                        models: "Grok 3 · Grok 3 Fast",
                        getKeyURL: "console.x.ai",
                        color: .purple,
                        freeInfo: "$25 free credit on signup"
                    )
                }
                .padding(.horizontal, 44)

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                    Text("Stored in your Mac Keychain — never sent anywhere except the provider you chose")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.white.opacity(0.15))
                .padding(.top, 2)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func infoRow(q: String, a: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(q)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(a)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
                .lineSpacing(1)
        }
    }

    @ViewBuilder
    private func apiKeyRow(provider: String, keyName: String, models: String, getKeyURL: String, color: Color, freeInfo: String) -> some View {
        let hasKey = !(state.cloudAPIKeys[keyName] ?? "").isEmpty

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(hasKey ? color.opacity(0.3) : Color.white.opacity(0.06))
                        .frame(width: 18, height: 18)
                    if hasKey {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color)
                    } else {
                        Circle()
                            .fill(color.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Text(provider)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Text("·")
                    .foregroundStyle(.white.opacity(0.1))

                Text(models)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(1)

                Spacer()

                if !hasKey {
                    Text(freeInfo)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(color.opacity(0.4))
                }
            }

            SecureField("Paste \(provider) API key", text: genericKeyBinding(for: keyName))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(hasKey ? color.opacity(0.3) : Color.white.opacity(0.04), lineWidth: 1)
                )

            // Get key link
            if !hasKey {
                Text("Get a key → \(getKeyURL)")
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.25))
                    .padding(.leading, 2)
            }
        }
        .padding(10)
        .background(hasKey ? color.opacity(0.02) : Color.white.opacity(0.015))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hasKey ? color.opacity(0.1) : Color.white.opacity(0.03), lineWidth: 1)
        )
    }

    // MARK: - Step 5: Voice & Image

    @ViewBuilder
    private var voiceKeysStep: some View {
        VStack(spacing: 14) {
            stepHeader(
                step: .voiceKeys,
                headline: "Voice & Image",
                detail: "These features use cloud APIs you may have already set up.\nNothing new to buy — this step just shows what's available."
            )

            // Capability status cards
            VStack(spacing: 6) {
                capabilityCard(
                    icon: "speaker.wave.2.fill",
                    name: "Text-to-Speech",
                    status: ttsStatus,
                    statusColor: ttsStatusColor,
                    detail: "ElevenLabs (premium voices) or OpenAI (included with GPT key)"
                )

                capabilityCard(
                    icon: "mic.fill",
                    name: "Speech-to-Text",
                    status: sttStatus,
                    statusColor: sttStatusColor,
                    detail: "OpenAI Whisper — transcribe audio to text"
                )

                capabilityCard(
                    icon: "photo.fill",
                    name: "Image Generation",
                    status: imageGenStatus,
                    statusColor: imageGenStatusColor,
                    detail: "DALL-E 3 — generate images from text prompts"
                )
            }
            .padding(.horizontal, 44)

            Divider().overlay(Color.white.opacity(0.04)).padding(.horizontal, 80)

            // ElevenLabs key (the only new key on this step)
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.pink.opacity(0.6))
                    Text("Want premium voices? Add an ElevenLabs key (optional)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }

                let hasELKey = !(state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Paste ElevenLabs API key", text: genericKeyBinding(for: "ELEVENLABS_API_KEY"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(hasELKey ? Color.pink.opacity(0.3) : Color.white.opacity(0.04), lineWidth: 1)
                        )

                    if !hasELKey {
                        Text("Get a key → elevenlabs.io → Profile → API Keys")
                            .font(.system(size: 9))
                            .foregroundStyle(.pink.opacity(0.25))
                    }
                }
            }
            .padding(.horizontal, 44)

            // Already have OpenAI? You're set.
            if !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Your OpenAI key from Step 4 already enables STT, TTS fallback, and image generation")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 44)
            }
        }
    }

    // Voice/Image status helpers
    private var ttsStatus: String {
        if !(state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty { return "Ready — ElevenLabs" }
        if !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty { return "Ready — OpenAI" }
        return "Needs API key"
    }
    private var ttsStatusColor: Color {
        if !(state.cloudAPIKeys["ELEVENLABS_API_KEY"] ?? "").isEmpty { return .pink }
        if !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty { return .green }
        return .white.opacity(0.2)
    }
    private var sttStatus: String {
        !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty ? "Ready" : "Needs OpenAI key"
    }
    private var sttStatusColor: Color {
        !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty ? .green : .white.opacity(0.2)
    }
    private var imageGenStatus: String {
        !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty ? "Ready" : "Needs OpenAI key"
    }
    private var imageGenStatusColor: Color {
        !(state.cloudAPIKeys["OPENAI_API_KEY"] ?? "").isEmpty ? .green : .white.opacity(0.2)
    }

    @ViewBuilder
    private func capabilityCard(icon: String, name: String, status: String, statusColor: Color, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(statusColor.opacity(0.6))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.1))
                    Text(status)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(statusColor.opacity(0.7))
                }
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.2))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
    }

    // MARK: - Step 6: Remote Access (Tailscale)

    @ViewBuilder
    private var remoteAccessStep: some View {
        VStack(spacing: 16) {
            stepHeader(
                step: .remoteAccess,
                headline: "Remote Access",
                detail: "Access Torbo Base from anywhere — not just your local WiFi.\nTailscale creates a secure private network between your devices."
            )

            VStack(alignment: .leading, spacing: 14) {
                // What is Tailscale
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue.opacity(0.6))
                        Text("What is Tailscale?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text("Tailscale is a free VPN that connects your devices together securely. Once set up, your phone can reach Torbo Base from anywhere — coffee shop, office, or traveling. No port forwarding or firewall changes needed.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineSpacing(2)
                }
                .padding(10)
                .background(Color.blue.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.08), lineWidth: 1)
                )

                // Installation instructions
                VStack(alignment: .leading, spacing: 10) {
                    instructionRow(icon: "1.circle.fill", text: "Install: brew install tailscale  (or tailscale.com/download)")
                    instructionRow(icon: "2.circle.fill", text: "Sign in: sudo tailscale up  (creates a free account)")
                    instructionRow(icon: "3.circle.fill", text: "Install Tailscale on your phone too (App Store / Play Store)")
                    instructionRow(icon: "4.circle.fill", text: "Both devices join the same tailnet — done!")
                }

                // Status check
                HStack(spacing: 12) {
                    if tailscaleRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Tailscale connected!", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.green)
                            if !tailscaleIP.isEmpty {
                                HStack(spacing: 4) {
                                    Text("Your Tailscale IP:")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.4))
                                    Text(tailscaleIP)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.blue.opacity(0.7))
                                }
                            }
                        }
                    } else if tailscaleInstalled {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Tailscale installed but not running", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.yellow)
                            Text("Run: sudo tailscale up")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    } else {
                        Label("Tailscale not detected", systemImage: "circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer()

                    Button {
                        Task { await checkTailscaleStatus() }
                    } label: {
                        Label("Check", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 50)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                Text("All traffic is end-to-end encrypted — Tailscale never sees your data")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.white.opacity(0.15))
        }
        .task {
            await checkTailscaleStatus()
        }
    }

    private func checkTailscaleStatus() async {
        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["tailscale"]
        let whichPipe = Pipe()
        whichProc.standardOutput = whichPipe
        whichProc.standardError = Pipe()

        do {
            try whichProc.run()
            whichProc.waitUntilExit()

            guard whichProc.terminationStatus == 0 else {
                await MainActor.run { tailscaleInstalled = false; tailscaleRunning = false }
                return
            }

            await MainActor.run { tailscaleInstalled = true }

            // Use the path `which` found (works on both Intel and Apple Silicon)
            let whichOutput = String(data: whichPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tailscalePath = whichOutput.isEmpty ? "/usr/local/bin/tailscale" : whichOutput

            let statusProc = Process()
            statusProc.executableURL = URL(fileURLWithPath: tailscalePath)
            statusProc.arguments = ["status", "--json"]
            let statusPipe = Pipe()
            statusProc.standardOutput = statusPipe
            statusProc.standardError = Pipe()

            try statusProc.run()
            statusProc.waitUntilExit()

            let data = statusPipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let backendState = json["BackendState"] as? String ?? "Unknown"
                let selfIP = (json["TailscaleIPs"] as? [String])?.first ?? ""
                await MainActor.run {
                    tailscaleRunning = backendState == "Running"
                    tailscaleIP = selfIP
                }
            }
        } catch {
            await MainActor.run { tailscaleInstalled = false; tailscaleRunning = false }
        }
    }

    // MARK: - Ready Step

    @ViewBuilder
    private var readyStep: some View {
        VStack(spacing: 20) {
            OrbRenderer(
                audioLevels: (0..<40).map { _ in Float.random(in: 0.2...0.5) },
                color: selectedLevel.color,
                isActive: true
            )
            .frame(width: 140, height: 140)

            Text("GODSPEED")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .tracking(3)

            VStack(spacing: 6) {
                checkRow("Gateway on port \(state.serverPort)")
                checkRow("Access level: \(selectedLevel.name)")
                if state.ollamaRunning && !skipOllama {
                    checkRow("Ollama connected — \(state.ollamaModels.count) model\(state.ollamaModels.count == 1 ? "" : "s")")
                } else if skipOllama {
                    checkRow("Cloud-only mode — add Ollama anytime")
                }
                if state.cloudAPIKeys.values.contains(where: { !$0.isEmpty }) {
                    let count = state.cloudAPIKeys.values.filter({ !$0.isEmpty }).count
                    checkRow("\(count) cloud key\(count == 1 ? "" : "s") configured")
                }
                if tailscaleRunning {
                    checkRow("Tailscale connected — remote access enabled")
                }
                checkRow("Zero data collection — 100% private")
            }

            // Cross-platform access
            VStack(spacing: 8) {
                Text("CONNECT FROM ANY DEVICE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                    .tracking(1)

                VStack(spacing: 6) {
                    // Local network URL
                    VStack(spacing: 2) {
                        Text("Local Network")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("http://\(state.localIP):\(state.serverPort)/chat")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(Color.cyan.opacity(0.04))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.cyan.opacity(0.1), lineWidth: 1)
                            )
                    }

                    // Tailscale URL (if available)
                    if tailscaleRunning && !tailscaleIP.isEmpty {
                        VStack(spacing: 2) {
                            Text("Anywhere (Tailscale)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.15))
                            Text("http://\(tailscaleIP):\(state.serverPort)/chat")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.blue.opacity(0.7))
                                .textSelection(.enabled)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(Color.blue.opacity(0.04))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.blue.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }

                Text("No app install needed — works in any browser")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.15))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func instructionRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.cyan.opacity(0.7))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func genericKeyBinding(for keyName: String) -> Binding<String> {
        Binding(
            get: { state.cloudAPIKeys[keyName] ?? "" },
            set: {
                state.cloudAPIKeys[keyName] = $0
                keySaveTask?.cancel()
                keySaveTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    AppConfig.cloudAPIKeys = state.cloudAPIKeys
                }
            }
        )
    }
}
#endif
