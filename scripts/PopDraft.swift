#!/usr/bin/env swift
// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing

import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Data Models

struct LLMAction: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let prompt: String
    let shortcut: String?
    let isTTS: Bool

    init(name: String, icon: String, prompt: String, shortcut: String?, isTTS: Bool = false) {
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.shortcut = shortcut
        self.isTTS = isTTS
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LLMAction, rhs: LLMAction) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - LLM Configuration

struct LLMConfig {
    enum Backend: String {
        case ollama
        case llamacpp
    }

    var backend: Backend = .ollama
    var ollamaURL: String = "http://localhost:11434"
    var llamacppURL: String = "http://localhost:8080"
    var ollamaModel: String = "qwen3-coder:480b-cloud"
    var ollamaFallbackModel: String? = "qwen2.5-coder:7b"

    static func load() -> LLMConfig {
        var config = LLMConfig()
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".quickllm/config")

        guard let contents = try? String(contentsOf: configPath, encoding: .utf8) else {
            return config
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "BACKEND":
                config.backend = Backend(rawValue: value) ?? .ollama
            case "OLLAMA_URL":
                config.ollamaURL = value
            case "LLAMACPP_URL":
                config.llamacppURL = value
            case "OLLAMA_MODEL":
                config.ollamaModel = value
            case "OLLAMA_FALLBACK_MODEL":
                config.ollamaFallbackModel = value.isEmpty ? nil : value
            default:
                break
            }
        }

        return config
    }
}

// MARK: - LLM Client

class LLMClient {
    static let shared = LLMClient()
    private var config: LLMConfig
    private var activeBackend: LLMConfig.Backend?

    init() {
        config = LLMConfig.load()
    }

    func reloadConfig() {
        config = LLMConfig.load()
        activeBackend = nil
    }

    var backendName: String {
        let backend = activeBackend ?? config.backend
        return backend == .llamacpp ? "llama.cpp" : "Ollama"
    }

    // Check if a backend is available (synchronous, with short timeout)
    private func isBackendAvailable(_ backend: LLMConfig.Backend) -> Bool {
        let urlString = backend == .llamacpp
            ? "\(config.llamacppURL)/health"
            : "\(config.ollamaURL)/api/tags"

        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        let semaphore = DispatchSemaphore(value: 0)
        var isAvailable = false

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                isAvailable = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 1.5)
        return isAvailable
    }

    // Select backend with fallback
    private func selectBackend() -> LLMConfig.Backend? {
        // Try configured backend first
        if isBackendAvailable(config.backend) {
            activeBackend = config.backend
            return config.backend
        }

        // Try fallback
        let fallback: LLMConfig.Backend = config.backend == .llamacpp ? .ollama : .llamacpp
        if isBackendAvailable(fallback) {
            activeBackend = fallback
            return fallback
        }

        activeBackend = nil
        return nil
    }

    func generate(prompt: String, systemPrompt: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        // Auto-select backend with fallback
        guard let backend = selectBackend() else {
            completion(.failure(NSError(domain: "No LLM backend available. Start llama-server or Ollama.", code: -1)))
            return
        }

        switch backend {
        case .llamacpp:
            generateLlamaCpp(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
        case .ollama:
            generateOllama(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
        }
    }

    // MARK: - llama.cpp Backend (OpenAI-compatible API)

    private func generateLlamaCpp(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(config.llamacppURL)/v1/chat/completions") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "messages": messages,
            "stream": false,
            "max_tokens": 4096
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    var cleaned = content
                    if let range = cleaned.range(of: "</think>") {
                        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    completion(.success(cleaned))
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let errorObj = json["error"] as? [String: Any],
                          let message = errorObj["message"] as? String {
                    completion(.failure(NSError(domain: message, code: -1)))
                } else {
                    completion(.failure(NSError(domain: "Invalid response", code: -1)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Ollama Backend

    private func generateOllama(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        // Try primary model first, then fallback
        generateOllamaWithModel(model: config.ollamaModel, prompt: prompt, systemPrompt: systemPrompt) { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure(let error):
                // If primary model fails and we have a fallback, try it
                if let fallback = self?.config.ollamaFallbackModel {
                    self?.generateOllamaWithModel(model: fallback, prompt: prompt, systemPrompt: systemPrompt, completion: completion)
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func generateOllamaWithModel(model: String, prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(config.ollamaURL)/api/generate") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let responseText = json["response"] as? String {
                    var cleaned = responseText
                    if let range = cleaned.range(of: "</think>") {
                        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    completion(.success(cleaned))
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let errorMsg = json["error"] as? String {
                    // Model not found or other Ollama error - trigger fallback
                    completion(.failure(NSError(domain: errorMsg, code: -1)))
                } else {
                    completion(.failure(NSError(domain: "Invalid response", code: -1)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - TTS Client

class TTSClient {
    static let shared = TTSClient()
    private let serverURL = "http://127.0.0.1:7865"

    func speak(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // URL encode the text
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(serverURL)/speak?text=\(encodedText)&play=1") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(.success(()))
            } else {
                completion(.failure(NSError(domain: "TTS server error", code: -1)))
            }
        }.resume()
    }

    func checkHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(serverURL)/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }
}

// MARK: - Action Manager

class ActionManager {
    static let shared = ActionManager()

    let actions: [LLMAction] = [
        LLMAction(
            name: "Fix grammar and spelling",
            icon: "checkmark.circle.fill",
            prompt: "Fix any grammar, spelling, and punctuation errors in this text. Keep the same tone and meaning. Only output the corrected text, nothing else. Preserve the original language.",
            shortcut: "G"
        ),
        LLMAction(
            name: "Articulate",
            icon: "pencil.circle.fill",
            prompt: "Improve this text to be clearer and more professional while keeping the same meaning and tone. Only output the improved text, nothing else. Preserve the original language.",
            shortcut: "A"
        ),
        LLMAction(
            name: "Explain simply",
            icon: "lightbulb.fill",
            prompt: "Explain this text in simple terms that anyone can understand. Only output the explanation, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Craft a reply",
            icon: "arrowshape.turn.up.left.fill",
            prompt: "Write a thoughtful and helpful reply to this message. Be professional and friendly. Only output the reply, nothing else. Preserve the original language.",
            shortcut: "C"
        ),
        LLMAction(
            name: "Continue writing",
            icon: "arrow.right.circle.fill",
            prompt: "Continue writing from where this text ends, matching the style and tone. Only output the continuation, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Read aloud",
            icon: "speaker.wave.2.fill",
            prompt: "",
            shortcut: "S",
            isTTS: true
        ),
        LLMAction(
            name: "Custom prompt...",
            icon: "ellipsis.circle.fill",
            prompt: "",
            shortcut: "P"
        )
    ]

    func filteredActions(searchText: String) -> [LLMAction] {
        if searchText.isEmpty {
            return actions
        }
        return actions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - View State

enum PopupState {
    case actionList
    case customPrompt
    case processing
    case result(String)
    case error(String)
}

// MARK: - Popup View

struct PopupView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    @Binding var state: PopupState
    @Binding var customPromptText: String
    @FocusState private var isSearchFocused: Bool
    let allActions: [LLMAction]
    let onSelect: (LLMAction) -> Void
    let onCopy: () -> Void
    let onBack: () -> Void
    let onDismiss: () -> Void

    // Computed filtered actions - recomputes when searchText changes
    private var actions: [LLMAction] {
        if searchText.isEmpty {
            return allActions
        }
        return allActions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .actionList:
                actionListView
            case .customPrompt:
                customPromptView
            case .processing:
                processingView
            case .result(let text):
                resultView(text: text)
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 320)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }

    // MARK: - Action List View

    private var actionListView: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Search actions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Action list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            ActionRow(
                                action: action,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                onSelect(action)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .onAppear {
            // Focus the search field when action list appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Custom Prompt View

    private var customPromptView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Custom Prompt")
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 12) {
                TextField("Enter your instruction...", text: $customPromptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...6)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                Text("Press Enter to process")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Processing...")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    // MARK: - Result View

    private func resultView(text: String) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Result")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Result text
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 250)

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onCopy) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text("Copy")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Error")
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
}

struct ActionRow: View {
    let action: LLMAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 20)

            Text(action.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()

            if let shortcut = action.shortcut {
                Text("⌃⌥\(shortcut)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Key Panel (allows text input)

class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Popup Window Controller

class PopupWindowController: NSWindowController {
    private var hostingView: NSHostingView<PopupView>?
    private var searchText = ""
    private var selectedIndex = 0
    private var state: PopupState = .actionList
    private var customPromptText = ""
    private var clipboardText = ""
    private var resultText = ""
    private var localMonitor: Any?

    init() {
        let window = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.becomesKeyOnlyIfNeeded = false  // Always become key when shown

        super.init(window: window)

        updateView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateView() {
        let view = PopupView(
            searchText: Binding(
                get: { self.searchText },
                set: { newValue in
                    self.searchText = newValue
                    self.selectedIndex = 0  // Reset selection when searching
                    self.updateView()  // Trigger UI update
                }
            ),
            selectedIndex: Binding(get: { self.selectedIndex }, set: { self.selectedIndex = $0 }),
            state: Binding(get: { self.state }, set: { self.state = $0; self.updateView() }),
            customPromptText: Binding(get: { self.customPromptText }, set: { self.customPromptText = $0 }),
            allActions: ActionManager.shared.actions,
            onSelect: { [weak self] action in self?.selectAction(action) },
            onCopy: { [weak self] in self?.copyResult() },
            onBack: { [weak self] in self?.goBack() },
            onDismiss: { [weak self] in self?.dismiss() }
        )

        if hostingView == nil {
            hostingView = NSHostingView(rootView: view)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = view
        }

        window?.setContentSize(hostingView?.fittingSize ?? NSSize(width: 320, height: 400))
    }

    func showAtMouseLocation() {
        // Get clipboard content
        clipboardText = NSPasteboard.general.string(forType: .string) ?? ""

        // Reset state
        searchText = ""
        selectedIndex = 0
        state = .actionList
        customPromptText = ""
        resultText = ""
        updateView()

        // Position near mouse
        let mouseLocation = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero

        // Adjust position to be near cursor but visible on screen
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if frame.minX < screenFrame.minX {
                frame.origin.x = screenFrame.minX + 10
            }
            if frame.maxX > screenFrame.maxX {
                frame.origin.x = screenFrame.maxX - frame.width - 10
            }
            if frame.minY < screenFrame.minY {
                frame.origin.y = mouseLocation.y + 20
            }
        }

        window?.setFrame(frame, display: true)
        window?.makeKeyAndOrderFront(nil)

        // Start monitoring keyboard
        startKeyboardMonitoring()

        // Make the app active so we can receive key events
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        stopKeyboardMonitoring()
        window?.orderOut(nil)
    }

    private func goBack() {
        state = .actionList
        customPromptText = ""
        updateView()
    }

    private func startKeyboardMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            let actions = ActionManager.shared.filteredActions(searchText: self.searchText)

            switch event.keyCode {
            case 53: // Escape
                switch self.state {
                case .actionList:
                    self.dismiss()
                default:
                    self.goBack()
                }
                return nil

            case 125: // Down arrow
                if case .actionList = self.state, self.selectedIndex < actions.count - 1 {
                    self.selectedIndex += 1
                    self.updateView()
                }
                return nil

            case 126: // Up arrow
                if case .actionList = self.state, self.selectedIndex > 0 {
                    self.selectedIndex -= 1
                    self.updateView()
                }
                return nil

            case 36: // Return/Enter
                switch self.state {
                case .actionList:
                    if self.selectedIndex < actions.count {
                        self.selectAction(actions[self.selectedIndex])
                    }
                case .customPrompt:
                    if !self.customPromptText.isEmpty {
                        let customAction = LLMAction(
                            name: "Custom",
                            icon: "ellipsis.circle.fill",
                            prompt: self.customPromptText,
                            shortcut: nil
                        )
                        self.selectAction(customAction)
                    }
                case .result:
                    self.copyResult()
                default:
                    break
                }
                return nil

            default:
                return event
            }
        }
    }

    private func stopKeyboardMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func selectAction(_ action: LLMAction) {
        // Handle custom prompt
        if action.name == "Custom prompt..." {
            state = .customPrompt
            updateView()
            return
        }

        // Get selected text from clipboard
        guard !clipboardText.isEmpty else {
            state = .error("No text in clipboard.\nCopy some text first (⌘C)")
            updateView()
            return
        }

        // Handle TTS action
        if action.isTTS {
            state = .processing
            updateView()

            TTSClient.shared.speak(text: clipboardText) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.showNotification(title: "PopDraft", message: "Reading aloud...")
                        self?.dismiss()
                    case .failure(let error):
                        self?.state = .error("TTS Error: \(error.localizedDescription)\n\nMake sure the TTS server is running.")
                        self?.updateView()
                    }
                }
            }
            return
        }

        // Show processing state
        state = .processing
        updateView()

        // Build the full prompt
        let fullPrompt = "\(action.prompt)\n\nText:\n\(clipboardText)"

        // Call LLM backend
        LLMClient.shared.generate(prompt: fullPrompt) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    self?.resultText = response
                    self?.state = .result(response)
                case .failure(let error):
                    self?.state = .error(error.localizedDescription)
                }
                self?.updateView()
            }
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)

        // Show brief feedback then dismiss
        showNotification(title: "PopDraft", message: "Copied to clipboard")
        dismiss()
    }

    private func showNotification(title: String, message: String) {
        let script = """
        display notification "\(message.replacingOccurrences(of: "\"", with: "\\\""))" with title "\(title.replacingOccurrences(of: "\"", with: "\\\""))"
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - Settings Window

struct SettingsView: View {
    @State private var primaryModel: String = ""
    @State private var fallbackModel: String = ""
    @State private var availableModels: [String] = []
    @State private var isLoading = false
    @State private var statusMessage: String = ""
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Model Settings")
                .font(.headline)

            if isLoading {
                ProgressView("Loading models...")
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Primary model
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Primary Model")
                            .font(.system(size: 12, weight: .medium))
                        if availableModels.isEmpty {
                            TextField("e.g., qwen3-coder:480b-cloud", text: $primaryModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $primaryModel) {
                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                        Text("Cloud models (e.g., *-cloud) use Ollama's servers")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    // Fallback model
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fallback Model")
                            .font(.system(size: 12, weight: .medium))
                        if availableModels.isEmpty {
                            TextField("e.g., qwen2.5-coder:7b", text: $fallbackModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $fallbackModel) {
                                Text("None").tag("")
                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                        Text("Used when primary model is unavailable")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Save") {
                        onSave(primaryModel, fallbackModel)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryModel.isEmpty)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            loadCurrentConfig()
            fetchModels()
        }
    }

    private func loadCurrentConfig() {
        let config = LLMConfig.load()
        primaryModel = config.ollamaModel
        fallbackModel = config.ollamaFallbackModel ?? ""
    }

    private func fetchModels() {
        isLoading = true
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["models"] as? [[String: Any]] else {
                    return
                }

                availableModels = models.compactMap { $0["name"] as? String }.sorted()

                // Ensure current selections are in the list
                if !primaryModel.isEmpty && !availableModels.contains(primaryModel) {
                    availableModels.insert(primaryModel, at: 0)
                }
                if !fallbackModel.isEmpty && !availableModels.contains(fallbackModel) {
                    availableModels.append(fallbackModel)
                }
            }
        }.resume()
    }
}

class SettingsWindowController: NSWindowController {
    private var hostingView: NSHostingView<SettingsView>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PopDraft Settings"
        window.center()

        super.init(window: window)

        let view = SettingsView(
            onSave: { [weak self] primary, fallback in
                self?.saveConfig(primary: primary, fallback: fallback)
                self?.window?.close()
            },
            onCancel: { [weak self] in
                self?.window?.close()
            }
        )

        hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        // Recreate the view to refresh data
        let view = SettingsView(
            onSave: { [weak self] primary, fallback in
                self?.saveConfig(primary: primary, fallback: fallback)
                self?.window?.close()
            },
            onCancel: { [weak self] in
                self?.window?.close()
            }
        )
        hostingView?.rootView = view

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveConfig(primary: String, fallback: String) {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".quickllm/config")

        // Read existing config
        var lines: [String] = []
        if let contents = try? String(contentsOf: configPath, encoding: .utf8) {
            lines = contents.components(separatedBy: .newlines)
        }

        // Update or add model settings
        var foundPrimary = false
        var foundFallback = false

        for i in 0..<lines.count {
            if lines[i].hasPrefix("OLLAMA_MODEL=") {
                lines[i] = "OLLAMA_MODEL=\(primary)"
                foundPrimary = true
            } else if lines[i].hasPrefix("OLLAMA_FALLBACK_MODEL=") {
                lines[i] = "OLLAMA_FALLBACK_MODEL=\(fallback)"
                foundFallback = true
            }
        }

        if !foundPrimary {
            lines.append("OLLAMA_MODEL=\(primary)")
        }
        if !foundFallback {
            lines.append("OLLAMA_FALLBACK_MODEL=\(fallback)")
        }

        // Write config
        let newContent = lines.joined(separator: "\n")
        try? newContent.write(to: configPath, atomically: true, encoding: .utf8)

        // Reload config in LLMClient
        LLMClient.shared.reloadConfig()

        // Show notification
        let script = """
        display notification "Models updated: \(primary)" with title "PopDraft"
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popupController: PopupWindowController?
    var settingsController: SettingsWindowController?
    var globalHotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "PopDraft")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Popup (⌥Space)", action: #selector(showPopup), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About PopDraft", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Create controllers
        popupController = PopupWindowController()
        settingsController = SettingsWindowController()

        // Register global hotkey (Option + Space)
        registerGlobalHotKey()

        print("PopDraft started. Press Option+Space to show popup.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    @objc func showSettings() {
        settingsController?.showWindow()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PopDraft"
        alert.informativeText = "System-wide AI text processing for macOS.\n\nUsage:\n1. Copy text to clipboard\n2. Press Option+Space\n3. Select an action\n4. Review result and Copy\n\nBackend: \(LLMClient.shared.backendName)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Global Hotkey

    func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x514C4D), id: 1)
        let modifiers: UInt32 = UInt32(optionKey)
        let keyCode: UInt32 = 49 // Space

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            globalHotKeyRef = hotKeyRef

            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

                if hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.showPopup()
                        }
                    }
                }
                return noErr
            }, 1, &eventType, nil, nil)

            print("Global hotkey registered: Option+Space")
        } else {
            print("Failed to register global hotkey: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKeyRef = globalHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
