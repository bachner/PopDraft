#!/usr/bin/env swift
// QuickLLM - Popup Menu App
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LLMAction, rhs: LLMAction) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Ollama Client

class OllamaClient {
    static let shared = OllamaClient()
    private let baseURL = "http://localhost:11434"
    private let model = "qwen3-coder:480b-cloud"

    func generate(prompt: String, systemPrompt: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
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
                    // Clean up the response - remove /no_think tags if present
                    var cleaned = responseText
                    if let range = cleaned.range(of: "</think>") {
                        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    completion(.success(cleaned))
                } else {
                    completion(.failure(NSError(domain: "Invalid response", code: -1)))
                }
            } catch {
                completion(.failure(error))
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
            name: "Improve writing",
            icon: "pencil.circle.fill",
            prompt: "Improve this text to be clearer and more professional while keeping the same meaning and tone. Only output the improved text, nothing else. Preserve the original language.",
            shortcut: "A"
        ),
        LLMAction(
            name: "Make it shorter",
            icon: "arrow.down.right.and.arrow.up.left",
            prompt: "Make this text more concise while keeping the key points. Only output the shortened text, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Make it longer",
            icon: "arrow.up.left.and.arrow.down.right",
            prompt: "Expand this text with more details and context while keeping the same meaning. Only output the expanded text, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Summarize",
            icon: "doc.text.fill",
            prompt: "Summarize this text in a few sentences, capturing the main points. Only output the summary, nothing else. Preserve the original language.",
            shortcut: nil
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
            name: "Change tone to formal",
            icon: "person.crop.circle.fill",
            prompt: "Rewrite this text in a formal, professional tone. Only output the rewritten text, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Change tone to casual",
            icon: "face.smiling.fill",
            prompt: "Rewrite this text in a casual, friendly tone. Only output the rewritten text, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Translate to English",
            icon: "globe",
            prompt: "Translate this text to English. Only output the translation, nothing else.",
            shortcut: nil
        ),
        LLMAction(
            name: "Continue writing",
            icon: "arrow.right.circle.fill",
            prompt: "Continue writing from where this text ends, matching the style and tone. Only output the continuation, nothing else. Preserve the original language.",
            shortcut: nil
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

// MARK: - Popup View

struct PopupView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    @Binding var isProcessing: Bool
    @Binding var customPromptText: String
    @Binding var showCustomPrompt: Bool
    let actions: [LLMAction]
    let onSelect: (LLMAction) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                if showCustomPrompt {
                    TextField("Enter your prompt...", text: $customPromptText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit {
                            if !customPromptText.isEmpty {
                                let customAction = LLMAction(
                                    name: "Custom",
                                    icon: "ellipsis.circle.fill",
                                    prompt: customPromptText,
                                    shortcut: nil
                                )
                                onSelect(customAction)
                            }
                        }
                } else {
                    TextField("Search actions...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if isProcessing {
                // Processing indicator
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding()
            } else if showCustomPrompt {
                // Custom prompt hint
                VStack(spacing: 8) {
                    Text("Type your instruction and press Enter")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button("Cancel") {
                        showCustomPrompt = false
                        customPromptText = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding()
            } else {
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
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 280)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
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

// MARK: - Popup Window Controller

class PopupWindowController: NSWindowController {
    private var hostingView: NSHostingView<PopupView>?
    private var searchText = ""
    private var selectedIndex = 0
    private var isProcessing = false
    private var customPromptText = ""
    private var showCustomPrompt = false
    private var clipboardText = ""
    private var localMonitor: Any?

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
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

        super.init(window: window)

        updateView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateView() {
        let actions = ActionManager.shared.filteredActions(searchText: searchText)
        if selectedIndex >= actions.count {
            selectedIndex = max(0, actions.count - 1)
        }

        let view = PopupView(
            searchText: Binding(get: { self.searchText }, set: { self.searchText = $0; self.updateView() }),
            selectedIndex: Binding(get: { self.selectedIndex }, set: { self.selectedIndex = $0 }),
            isProcessing: Binding(get: { self.isProcessing }, set: { self.isProcessing = $0 }),
            customPromptText: Binding(get: { self.customPromptText }, set: { self.customPromptText = $0 }),
            showCustomPrompt: Binding(get: { self.showCustomPrompt }, set: { self.showCustomPrompt = $0; self.updateView() }),
            actions: actions,
            onSelect: { [weak self] action in self?.selectAction(action) },
            onCancel: { [weak self] in self?.dismiss() }
        )

        if hostingView == nil {
            hostingView = NSHostingView(rootView: view)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = view
        }

        window?.setContentSize(hostingView?.fittingSize ?? NSSize(width: 280, height: 400))
    }

    func showAtMouseLocation() {
        // Get clipboard content
        clipboardText = NSPasteboard.general.string(forType: .string) ?? ""

        // Reset state
        searchText = ""
        selectedIndex = 0
        isProcessing = false
        customPromptText = ""
        showCustomPrompt = false
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

    private func startKeyboardMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            let actions = ActionManager.shared.filteredActions(searchText: self.searchText)

            switch event.keyCode {
            case 53: // Escape
                self.dismiss()
                return nil

            case 125: // Down arrow
                if self.selectedIndex < actions.count - 1 {
                    self.selectedIndex += 1
                    self.updateView()
                }
                return nil

            case 126: // Up arrow
                if self.selectedIndex > 0 {
                    self.selectedIndex -= 1
                    self.updateView()
                }
                return nil

            case 36: // Return/Enter
                if self.showCustomPrompt {
                    if !self.customPromptText.isEmpty {
                        let customAction = LLMAction(
                            name: "Custom",
                            icon: "ellipsis.circle.fill",
                            prompt: self.customPromptText,
                            shortcut: nil
                        )
                        self.selectAction(customAction)
                    }
                } else if self.selectedIndex < actions.count {
                    self.selectAction(actions[self.selectedIndex])
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
            showCustomPrompt = true
            updateView()
            return
        }

        // Get selected text from clipboard (user should have copied it)
        guard !clipboardText.isEmpty else {
            showNotification(title: "QuickLLM", message: "No text in clipboard. Copy some text first.")
            dismiss()
            return
        }

        // Show processing state
        isProcessing = true
        updateView()

        // Build the full prompt
        let fullPrompt = "\(action.prompt)\n\nText:\n\(clipboardText)"

        // Call Ollama
        OllamaClient.shared.generate(prompt: fullPrompt) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessing = false

                switch result {
                case .success(let response):
                    // Copy result to clipboard
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response, forType: .string)

                    // Show success notification
                    self?.showNotification(title: "QuickLLM", message: "Result copied to clipboard")

                    // Try to paste (Cmd+V)
                    self?.simulatePaste()

                case .failure(let error):
                    self?.showNotification(title: "QuickLLM Error", message: error.localizedDescription)
                }

                self?.dismiss()
            }
        }
    }

    private func simulatePaste() {
        // Small delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)

            // Key down
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            // Key up
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func showNotification(title: String, message: String) {
        // Use osascript for notifications (works reliably on all macOS versions)
        let script = """
        display notification "\(message.replacingOccurrences(of: "\"", with: "\\\""))" with title "\(title.replacingOccurrences(of: "\"", with: "\\\""))"
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
    var globalHotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "QuickLLM")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Popup (⌥Space)", action: #selector(showPopup), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About QuickLLM", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Create popup controller
        popupController = PopupWindowController()

        // Register global hotkey (Option + Space)
        registerGlobalHotKey()

        print("QuickLLM started. Press Option+Space to show popup.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "QuickLLM"
        alert.informativeText = "System-wide AI text processing for macOS.\n\nUsage:\n1. Copy text to clipboard\n2. Press Option+Space\n3. Select an action\n\nPowered by Ollama"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Global Hotkey

    func registerGlobalHotKey() {
        // Option + Space
        let hotKeyID = EventHotKeyID(signature: OSType(0x514C4D), id: 1) // "QLM" + 1
        let modifiers: UInt32 = UInt32(optionKey)
        let keyCode: UInt32 = 49 // Space

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            globalHotKeyRef = hotKeyRef

            // Install event handler
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
