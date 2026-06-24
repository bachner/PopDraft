// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing
//
// Built by co-compiling with scripts/Core.swift:
//   swiftc -O scripts/PopDraft.swift scripts/Core.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import WebKit
import CryptoKit
import Network

// MARK: - Onboarding Window

struct OnboardingView: View {
    @State private var hasAccessibility = false
    @State private var selectedProvider: LLMConfig.Provider = .llamacpp
    @State private var apiKey = ""
    @State private var selectedModel = ""
    @State private var selectedLlamaModel: String = "qwen3.5-2b"
    @State private var ollamaModels: [String] = []
    @State private var checkingPermission = false
    @State private var isSettingUp = false
    @State private var setupStatus = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header — bundled Liquid-Glass hero (PR2 asset) with an SF-Symbol
            // fallback for the bare source-install binary (no Assets/ dir).
            VStack(spacing: 8) {
                if let hero = AppAssets.onboardingHero {
                    Image(nsImage: hero)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        .padding(.top, 4)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                }
                Text("Welcome to PopDraft")
                    .font(.title)
                    .fontWeight(.bold)
                Text("System-wide AI text processing for macOS")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            Divider()

            // Step 1: Accessibility
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "1.circle.fill")
                        .foregroundColor(hasAccessibility ? .green : .accentColor)
                        .font(.title2)
                    Text("Grant Accessibility Access")
                        .font(.headline)
                    Spacer()
                }

                Text("PopDraft needs accessibility permission to capture selected text and register keyboard shortcuts.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !hasAccessibility {
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("Permission granted", systemImage: "checkmark")
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Step 2: Provider Selection
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: hasAccessibility ? "2.circle.fill" : "2.circle")
                        .foregroundColor(hasAccessibility ? .accentColor : .secondary)
                        .font(.title2)
                    Text("Choose Your LLM Backend")
                        .font(.headline)
                    Spacer()
                }

                Picker("", selection: $selectedProvider) {
                    ForEach(LLMConfig.Provider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!hasAccessibility)

                Text(providerDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Model selection for llama.cpp
                if selectedProvider == .llamacpp {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Model:")
                                .font(.callout)
                            Picker("", selection: $selectedLlamaModel) {
                                ForEach(LLMConfig.llamaModels, id: \.id) { model in
                                    Text("\(model.name) (\(model.size))").tag(model.id)
                                }
                            }
                            .labelsHidden()
                        }
                        if let model = LLMConfig.llamaModels.first(where: { $0.id == selectedLlamaModel }) {
                            Text("Languages: \(model.languages)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for Ollama
                if selectedProvider == .ollama {
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        if ollamaModels.isEmpty {
                            TextField("e.g., qwen3.5:4b", text: $selectedModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $selectedModel) {
                                ForEach(ollamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for OpenAI
                if selectedProvider == .openai {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!hasAccessibility)
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        Picker("", selection: $selectedModel) {
                            ForEach(LLMConfig.openaiModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for Claude
                if selectedProvider == .claude {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!hasAccessibility)
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        Picker("", selection: $selectedModel) {
                            ForEach(LLMConfig.claudeModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(!hasAccessibility)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .opacity(hasAccessibility ? 1.0 : 0.6)
            .onChange(of: selectedProvider) { _, newValue in
                // Set default model for provider
                switch newValue {
                case .llamacpp:
                    selectedModel = ""
                case .ollama:
                    selectedModel = ollamaModels.first ?? "qwen3.5:4b"
                    fetchOllamaModels()
                case .openai:
                    selectedModel = LLMConfig.openaiModels.first ?? "gpt-4o"
                case .claude:
                    selectedModel = LLMConfig.claudeModels.first ?? "claude-sonnet-4-20250514"
                }
            }

            Spacer()

            // Get Started button with progress
            VStack(spacing: 8) {
                if isSettingUp {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(setupStatus)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                        }
                        Text("This may take a few moments...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: {
                            DependencyManager.shared.cancelInstall()
                            finishOnboarding()
                        }) {
                            Text("Skip TTS Setup")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 74)
                } else {
                    Button(action: completeOnboarding) {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasAccessibility)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(width: 450, height: 620)
        .onAppear {
            // Prompt system to add this app to Accessibility list (shows up disabled)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            checkAccessibility()
            // Start polling for permission
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                checkAccessibility()
                if hasAccessibility {
                    timer.invalidate()
                }
            }
        }
    }

    private var providerDescription: String {
        switch selectedProvider {
        case .llamacpp:
            return "Runs locally using llama.cpp. Private and free, but requires downloading a model."
        case .ollama:
            return "Local models with Ollama. Easy model management with 'ollama pull'."
        case .openai:
            return "Use GPT-4o and other OpenAI models. Requires an API key."
        case .claude:
            return "Use Claude 3.5/4 models. Requires an Anthropic API key."
        }
    }

    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        // Use AXIsProcessTrustedWithOptions to prompt the system to add THIS app
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Also open settings so user can see and toggle
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        // Bring System Settings to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        }
    }

    private func fetchOllamaModels() {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return
            }

            DispatchQueue.main.async {
                ollamaModels = models.compactMap { $0["name"] as? String }.sorted()
                if selectedModel.isEmpty, let first = ollamaModels.first {
                    selectedModel = first
                }
            }
        }.resume()
    }

    private func completeOnboarding() {
        isSettingUp = true
        setupStatus = "Saving configuration..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Save config
            var config = LLMConfig.load()
            config.provider = selectedProvider

            switch selectedProvider {
            case .llamacpp:
                config.llamaModel = selectedLlamaModel
            case .ollama:
                config.ollamaModel = selectedModel.isEmpty ? "qwen3.5:4b" : selectedModel
            case .openai:
                config.openaiAPIKey = apiKey
                config.openaiModel = selectedModel.isEmpty ? "gpt-4o" : selectedModel
            case .claude:
                config.claudeAPIKey = apiKey
                config.claudeModel = selectedModel.isEmpty ? "claude-sonnet-4-20250514" : selectedModel
            }
            config.save()

            setupStatus = "Enabling launch at login..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                LaunchAtLoginManager.shared.setEnabled(true)

                // Check and install dependencies
                setupStatus = "Checking dependencies..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Install llama.cpp if selected
                    if selectedProvider == .llamacpp {
                        let depStatus = DependencyManager.shared.checkDependencies()
                        let modelDownloaded = DependencyManager.shared.isModelDownloaded(selectedLlamaModel)
                        if !depStatus.hasLlamaCpp || !modelDownloaded {
                            DependencyManager.shared.installLlamaCpp(
                                modelId: selectedLlamaModel,
                                statusCallback: { status in
                                    self.setupStatus = status
                                },
                                completion: { _ in
                                    self.installTTSDependencies()
                                }
                            )
                        } else {
                            self.installTTSDependencies()
                        }
                    } else {
                        self.installTTSDependencies()
                    }
                }
            }
        }
    }

    private func installTTSDependencies() {
        let depStatus = DependencyManager.shared.checkDependencies()
        if depStatus.hasPythonPackages && depStatus.hasEspeak {
            // TTS dependencies already installed
            self.finishOnboarding()
        } else {
            // Install TTS dependencies
            DependencyManager.shared.installDependencies(
                statusCallback: { status in
                    DispatchQueue.main.async {
                        self.setupStatus = status
                    }
                },
                completion: { _ in
                    DispatchQueue.main.async {
                        self.finishOnboarding()
                    }
                }
            )
        }
    }

    private func finishOnboarding() {
        setupStatus = "Finalizing setup..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Mark onboarding complete
            let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
            let completePath = configDir + "/onboarding_complete"
            FileManager.default.createFile(atPath: completePath, contents: nil)

            // Complete - TTS server will be started by completeStartup()
            onComplete()
        }
    }
}

class OnboardingWindowController: NSWindowController {
    private var hostingView: NSHostingView<OnboardingView>?

    init(onComplete: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to PopDraft"
        window.center()

        super.init(window: window)

        let view = OnboardingView(onComplete: { [weak self] in
            // Close window BEFORE calling onComplete (which may nil out the controller)
            self?.window?.close()
            onComplete()
        })

        hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
