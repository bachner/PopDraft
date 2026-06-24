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

// MARK: - View State

enum PopupState {
    case actionList
    case customPrompt
    case processing
    case streaming(text: String, isThinking: Bool)
    case ttsPlaying(isPaused: Bool)
    case result(String, thinking: String?)
    case error(String)
    /// PR8: the full Claude-style agent chat. The conversation state lives in the
    /// shared `AgentChatViewModel` (passed to `ChatView`), so this case is just a
    /// marker telling `PopupView` which surface to render in the fixed-size panel.
    case chat
}

// MARK: - Popup View

struct PopupView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    @Binding var state: PopupState
    @Binding var customPromptText: String
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCustomPromptFocused: Bool
    /// Drives the grow/fade-in appearance animation (item 3: smooth transitions).
    @State private var appeared = false
    let allActions: [Action]
    let onSelect: (Action) -> Void
    let onCopy: () -> Void
    let onBack: () -> Void
    let onDismiss: () -> Void
    let onTTSStop: () -> Void
    let onTTSPause: () -> Void
    let onTTSResume: () -> Void
    let onOpenAccessibilitySettings: () -> Void
    let onRestartLlamaServer: () -> Void
    /// PR8: present when `state == .chat`. Drives the full agent ChatView.
    var chatViewModel: AgentChatViewModel? = nil

    // Computed filtered actions - recomputes when searchText changes
    private var actions: [Action] {
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
            case .streaming(let text, let isThinking):
                streamingView(text: text, isThinking: isThinking)
            case .ttsPlaying(let isPaused):
                ttsPlayingView(isPaused: isPaused)
            case .result(let text, let thinking):
                resultView(text: text, thinking: thinking)
            case .error(let message):
                errorView(message: message)
            case .chat:
                // The chat owns its own fixed-size panel + internal ScrollView, so
                // it deliberately bypasses the 320-wide auto-resize layout below.
                if let vm = chatViewModel {
                    ChatView(viewModel: vm, onMinimize: onDismiss)
                } else {
                    // Defensive: should never happen (the controller always sets a
                    // view model before switching to .chat).
                    Color.clear.frame(width: 720, height: 560)
                }
            }
        }
        .frame(width: stateKey == "chat" ? nil : 360)
        .background(stateKey == "chat"
            ? AnyView(Color.clear)
            : AnyView(LiquidGlassBackground(cornerRadius: 18)))
        .clipShape(RoundedRectangle(cornerRadius: stateKey == "chat" ? 0 : 18, style: .continuous))
        // Smooth state transitions (not instant swaps) + a gentle grow/fade-in
        // when the panel first appears (mirrors the bubble→panel grow).
        .scaleEffect(appeared ? 1.0 : 0.94)
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: appeared)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: stateKey)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appeared = true }
        }
        .onChange(of: stateKey) { _, newKey in
            if newKey == "customPrompt" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isCustomPromptFocused = true
                }
            }
        }
    }

    // Helper to get state key for onChange comparison
    private var stateKey: String {
        switch state {
        case .actionList: return "actionList"
        case .customPrompt: return "customPrompt"
        case .processing: return "processing"
        case .streaming: return "streaming"
        case .ttsPlaying: return "ttsPlaying"
        case .result: return "result"
        case .error: return "error"
        case .chat: return "chat"
        }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().opacity(0.4)

            // Action list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            ActionRow(
                                action: action,
                                isSelected: index == selectedIndex,
                                isPrimary: index == 0 && searchText.isEmpty
                            )
                            .id(action.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(action)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    if newIndex < actions.count {
                        withAnimation {
                            proxy.scrollTo(actions[newIndex].id, anchor: .center)
                        }
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
                    .focused($isCustomPromptFocused)
                    .onAppear { isCustomPromptFocused = true }

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

    // MARK: - Streaming View

    private func streamingView(text: String, isThinking: Bool) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                if isThinking {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text("Thinking...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    Text("Generating...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if isThinking || text.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if isThinking {
                        Text("Model is reasoning...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding()
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - TTS Playing View

    private func ttsPlayingView(isPaused: Bool) -> some View {
        VStack(spacing: 8) {
            // Header with status
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)

                Text(isPaused ? "Paused" : "Reading...")
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                // Keyboard hints
                Text("Space: \(isPaused ? "Play" : "Pause") | Esc: Stop")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Compact control buttons
            HStack(spacing: 8) {
                // Pause/Resume button
                Button(action: {
                    if isPaused {
                        onTTSResume()
                    } else {
                        onTTSPause()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10))
                        Text(isPaused ? "Play" : "Pause")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                // Stop button
                Button(action: onTTSStop) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Result View

    @State private var isThinkingExpanded = false

    private func resultView(text: String, thinking: String? = nil) -> some View {
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
                VStack(alignment: .leading, spacing: 0) {
                    if let thinking = thinking, !thinking.isEmpty {
                        DisclosureGroup(isExpanded: $isThinkingExpanded) {
                            Text(thinking)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 11))
                                Text("Thinking")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 8)

                        Divider()
                            .padding(.bottom, 8)
                    }

                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(maxHeight: isThinkingExpanded ? 400 : 250)

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

            if message == "ACCESSIBILITY_PERMISSION_REQUIRED" {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.red)

                    Text("Accessibility Permission Required")
                        .font(.system(size: 13, weight: .semibold))

                    Text("PopDraft needs Accessibility access to capture selected text. Please grant permission in System Settings.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onOpenAccessibilitySettings) {
                        Text("Open Accessibility Settings")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else if message == LLMClient.llamaServerDownError {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("llama-server is not running")
                        .font(.system(size: 13, weight: .semibold))

                    Text("The local llama.cpp server could not be reached. Click below to restart it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onRestartLlamaServer) {
                        Text("Restart Server")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
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
}

struct ActionRow: View {
    let action: Action
    let isSelected: Bool
    /// The visually-primary default action (the first row — "Ask Agent"), matching
    /// the mock where the new default is highlighted blue.
    var isPrimary: Bool = false

    @State private var hovering = false

    /// Selected by keyboard nav OR pointer hover → the highlighted state.
    private var active: Bool { isSelected || hovering }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(iconBackground))

            Text(action.name)
                .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                .foregroundColor(active ? .white : ChatPalette.ink)

            Spacer()

            if let shortcut = action.shortcut {
                Text("⌃⌥\(shortcut)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(active ? .white.opacity(0.85) : ChatPalette.ink3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(active ? Color.white.opacity(0.18)
                                              : ChatPalette.ink.opacity(0.06)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(rowBackground)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if active {
            shape.fill(ChatPalette.blue)
        } else if isPrimary {
            shape.fill(ChatPalette.blueSoft)
        } else {
            shape.fill(Color.clear)
        }
    }

    private var iconColor: Color {
        if active { return .white }
        return isPrimary ? ChatPalette.blue : ChatPalette.blue.opacity(0.9)
    }

    private var iconBackground: Color {
        if active { return Color.white.opacity(0.18) }
        return isPrimary ? ChatPalette.blue.opacity(0.16) : ChatPalette.blue.opacity(0.10)
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
    private var ttsStatusTimer: Timer?
    private var previousApp: NSRunningApplication?

    /// PR5: every invocation that produces a result is recorded into a persisted
    /// session (the captured selection + the user/assistant exchange). The session
    /// is built when a result arrives and flushed to disk on copy / meaningful
    /// dismiss. `nil` between invocations and whenever there's nothing worth saving.
    private var currentSession: ChatSession?
    /// Guards against double-saving the same session (copy then dismiss).
    private var didSaveCurrentSession = false
    private let sessionStore = SessionStore(
        dir: NSString(string: "~/.popdraft").expandingTildeInPath
    )

    /// PR8: the live chat view model. Set whenever the popup is in `.chat` state;
    /// nil otherwise. Drives `ChatView`.
    private var chatViewModel: AgentChatViewModel?
    /// PR8: the session's message count when the chat was presented, so a reopened
    /// session that the user didn't continue isn't needlessly re-saved on dismiss.
    private var presentedMessageCount: Int?

    /// Called right before the popup is shown at the cursor — used to minimize
    /// the corner bubble (PR4). The popup itself stays bubble-agnostic.
    var onWillShow: (() -> Void)?
    /// Called when the popup is dismissed (copy / Esc / lost focus / TTS done) —
    /// used to bring the corner bubble back (PR4).
    var onDidDismiss: (() -> Void)?

    init() {
        let window = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.becomesKeyOnlyIfNeeded = false  // Always become key when shown
        // Fully transparent so the SwiftUI Liquid-Glass pane (action menu / chat)
        // shows through with its own frost, rounding, and soft shadow.
        GlassWindow.makeTransparent(window)

        super.init(window: window)

        updateView()

        // Dismiss when window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        // Track live resize so the chat content reflows to the window size.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // The chat is a PERSISTENT window: the user can click away into other apps
        // and keep it on screen alongside their work. It only goes away on explicit
        // minimize-to-bubble, copy, or close. The transient action menu still
        // auto-dismisses on blur.
        if case .chat = state { return }
        dismiss()
    }

    /// Keep the chat content sized to the (user-resizable) window. Only relevant
    /// in chat state; harmless otherwise. Skipped during programmatic resizes so
    /// it doesn't feed a panelSize→content-size→window-size loop.
    @objc private func windowDidResize(_ notification: Notification) {
        guard case .chat = state, !isProgrammaticResize, let window = window else { return }
        chatViewModel?.panelSize = window.frame.size
    }

    /// True while we're setting the chat window frame ourselves, so the resize
    /// notification doesn't echo back into `panelSize`.
    private var isProgrammaticResize = false

    /// Run `body` with programmatic-resize suppression so any resulting
    /// `windowDidResize` doesn't overwrite the size we just chose.
    private func withProgrammaticResize(_ body: () -> Void) {
        isProgrammaticResize = true
        body()
        // Clear on the next runloop tick, after the resize notification fires.
        DispatchQueue.main.async { [weak self] in self?.isProgrammaticResize = false }
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
            allActions: ActionManager.shared.popupActions,
            onSelect: { [weak self] action in self?.selectAction(action) },
            onCopy: { [weak self] in self?.copyResult() },
            onBack: { [weak self] in self?.goBack() },
            onDismiss: { [weak self] in self?.dismiss() },
            onTTSStop: { [weak self] in self?.stopTTS() },
            onTTSPause: { [weak self] in self?.pauseTTS() },
            onTTSResume: { [weak self] in self?.resumeTTS() },
            onOpenAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
            onRestartLlamaServer: { [weak self] in self?.restartLlamaServer() },
            chatViewModel: chatViewModel
        )

        if hostingView == nil {
            hostingView = NSHostingView(rootView: view)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = view
        }

        // PR8: the chat sizes itself from the window's content size (published on
        // the view model, updated on resize) and owns an internal ScrollView, so
        // it skips the `fittingSize` auto-resize used by the quick action menu.
        if case .chat = state { return }

        // Defer resize to next run loop so SwiftUI can finish layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let hostingView = self.hostingView, let window = self.window else { return }
            var size = hostingView.fittingSize
            size.height = min(size.height, 400)  // Maximum height
            window.setContentSize(size)

            // Ensure window stays within screen bounds after resize
            var frame = window.frame
            if let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                if frame.minY < screenFrame.minY {
                    frame.origin.y = screenFrame.minY + 5
                }
                if frame.maxY > screenFrame.maxY {
                    frame.origin.y = screenFrame.maxY - frame.height - 5
                }
                if frame.minX < screenFrame.minX {
                    frame.origin.x = screenFrame.minX + 5
                }
                if frame.maxX > screenFrame.maxX {
                    frame.origin.x = screenFrame.maxX - frame.width - 5
                }
                if frame != window.frame {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }

    private func captureSelectedText() {
        let pasteboard = NSPasteboard.general

        // Save current clipboard content
        let savedContents = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let types = item.types.first,
                  let data = item.data(forType: types) else { return nil }
            return (types, data)
        } ?? []
        let savedChangeCount = pasteboard.changeCount

        // Get the frontmost app and store it for later refocus
        let frontApp = NSWorkspace.shared.frontmostApplication
        previousApp = frontApp
        let frontName = frontApp?.localizedName ?? "unknown"

        // Strategy: try CGEvent Cmd+C first (works for Chrome, native apps),
        // then fall back to AppleScript Edit > Copy menu (works for Electron apps like Slack)
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // 0x08 = 'c'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update (poll up to 500ms for slower apps like Chrome)
        for _ in 0..<10 {
            usleep(50000)  // 50ms per check
            if pasteboard.changeCount != savedChangeCount { break }
        }

        // If CGEvent Cmd+C didn't work, fall back to AppleScript Edit > Copy menu
        if pasteboard.changeCount == savedChangeCount {
            let script = NSAppleScript(source: """
                tell application "\(frontName)" to activate
                delay 0.1
                tell application "System Events"
                    tell process "\(frontName)"
                        click menu item "Copy" of menu "Edit" of menu bar 1
                    end tell
                end tell
            """)
            script?.executeAndReturnError(nil)
            usleep(300000)  // 300ms for Electron apps
        }

        // Check if clipboard changed (meaning text was selected and copied)
        if pasteboard.changeCount != savedChangeCount {
            clipboardText = pasteboard.string(forType: .string) ?? ""

            // Restore original clipboard
            pasteboard.clearContents()
            for (type, data) in savedContents {
                pasteboard.setData(data, forType: type)
            }
        } else {
            // No selection - clipboard unchanged, don't use clipboard as fallback
            clipboardText = ""
        }
    }

    func showAtMouseLocation() {
        Logger.shared.info("showAtMouseLocation: entry")
        // Minimize the corner bubble (if enabled) as we transition to the panel.
        onWillShow?()

        // Capture selected text by simulating Cmd+C
        captureSelectedText()
        Logger.shared.info("showAtMouseLocation: captured \(clipboardText.count) chars of selected text")

        // Reset state.
        searchText = ""
        selectedIndex = 0
        customPromptText = ""
        resultText = ""
        // PR5: start a fresh invocation — drop any previously recorded session so a
        // stale exchange isn't re-saved on this dismiss.
        currentSession = nil
        didSaveCurrentSession = false
        chatViewModel = nil
        presentedMessageCount = nil

        // PR8: with the bubble enabled and NO text selected, the hotkey opens the
        // agent chat directly (empty, awaiting the user's first message). With the
        // bubble disabled, keep today's behavior (action list). With text selected,
        // it's always the action list (the user picks an action → chat).
        let bubbleEnabled = LLMConfig.load().bubble.enabled
        if bubbleEnabled && clipboardText.isEmpty {
            Logger.shared.info("showAtMouseLocation: no selection + bubble enabled → opening chat")
            enterChat(seedUser: "", selectedText: nil, autoRun: false)
            window?.makeKeyAndOrderFront(nil)
            startKeyboardMonitoring()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Logger.shared.info("showAtMouseLocation: showing action menu (selection=\(!clipboardText.isEmpty), bubble=\(bubbleEnabled))")
        resetPanelForMenu()
        state = .actionList
        updateView()

        // Position near mouse
        let mouseLocation = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero

        // Find the screen containing the mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        // Try to position below cursor first
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen horizontally
        if frame.minX < screenFrame.minX {
            frame.origin.x = screenFrame.minX + 10
        }
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }

        // If popup would be cut off at bottom, show it above the cursor instead
        if frame.minY < screenFrame.minY {
            frame.origin.y = mouseLocation.y + 20
            // If still cut off at top, clamp to screen
            if frame.maxY > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.height - 10
            }
        }

        updateView()
        window?.setFrame(frame, display: true)
        window?.makeKeyAndOrderFront(nil)

        // Start monitoring keyboard
        startKeyboardMonitoring()
        updateView()
        // Make the app active so we can receive key events
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWithAction(actionID: String) {
        Logger.shared.info("showWithAction: \(actionID)")
        // Minimize the corner bubble (if enabled) as we transition to the panel.
        onWillShow?()

        // Capture selected text by simulating Cmd+C
        captureSelectedText()

        // Find the action by ID
        guard let action = ActionManager.shared.popupActions.first(where: { $0.id == actionID }) else {
            showAtMouseLocation() // Fall back to showing popup
            return
        }

        // Reset state and prepare for direct action
        searchText = ""
        selectedIndex = 0
        customPromptText = ""
        resultText = ""
        // PR5: start a fresh invocation (see showAtMouseLocation).
        currentSession = nil
        didSaveCurrentSession = false
        // PR8: drop any stale chat VM before this invocation.
        chatViewModel = nil
        presentedMessageCount = nil

        // Position near mouse
        let mouseLocation = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero

        // Find the screen containing the mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        // Try to position below cursor first
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen horizontally
        if frame.minX < screenFrame.minX {
            frame.origin.x = screenFrame.minX + 10
        }
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }

        // If popup would be cut off at bottom, show it above the cursor instead
        if frame.minY < screenFrame.minY {
            frame.origin.y = mouseLocation.y + 20
            // If still cut off at top, clamp to screen
            if frame.maxY > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.height - 10
            }
        }

        window?.setFrame(frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        startKeyboardMonitoring()
        NSApp.activate(ignoringOtherApps: true)

        // Directly trigger the action (skip action list)
        selectAction(action)
    }

    func dismiss() {
        // PR8: stop any in-flight agent run before tearing down.
        chatViewModel?.cancel()
        // Persist the chat window's size/position so it reopens where the user
        // left it (UI overhaul: resizable + movable chat).
        saveChatGeometryIfChat()
        // PR5: persist the session on minimize/dismiss too (idempotent with copy —
        // a session already flushed by copyResult won't be written twice, and an
        // empty/aborted session is skipped by hasMeaningfulExchange).
        flushSessionIfMeaningful()

        stopTTSStatusPolling()
        stopKeyboardMonitoring()
        window?.orderOut(nil)

        // Refocus the previous app
        if let app = previousApp {
            app.activate(options: [])
        }
        previousApp = nil

        // Bring the corner bubble back (when enabled). With the bubble disabled
        // this is a no-op, so behavior matches today exactly.
        onDidDismiss?()
    }

    private func goBack() {
        state = .actionList
        customPromptText = ""
        updateView()
    }

    private func startKeyboardMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            // Handle Cmd+C in result state - copy and close
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "c" {
                    if case .result = self.state {
                        self.copyResult()
                        return nil
                    }
                }
                // Allow Cmd+C/V/X/A through for text editing in other states
                if key == "c" || key == "v" || key == "x" || key == "a" {
                    return event  // Pass through to text field
                }
            }

            let actions = ActionManager.shared.filteredActions(searchText: self.searchText)

            // PR8: in chat mode the SwiftUI TextField owns the keyboard — let every
            // key through (arrows, Return for submit/newline, Space) and only
            // intercept Escape to minimize the chat to the bubble.
            if case .chat = self.state {
                if event.keyCode == 53 { // Escape
                    self.dismiss()
                    return nil
                }
                // Item 8: Up arrow with an EMPTY input recalls the last sent
                // message into the input (shell-history style). When the input has
                // text we pass it through so caret movement still works.
                if event.keyCode == 126, let vm = self.chatViewModel,
                   vm.draft.isEmpty, !vm.lastSentUserMessage.isEmpty {
                    vm.draft = vm.lastSentUserMessage
                    return nil
                }
                return event
            }

            switch event.keyCode {
            case 53: // Escape
                switch self.state {
                case .actionList, .result, .error:
                    self.dismiss()
                case .ttsPlaying:
                    self.stopTTS()  // Stop TTS and dismiss
                default:
                    self.goBack()
                }
                return nil

            case 49: // Space - pause/play TTS
                if case .ttsPlaying(let isPaused) = self.state {
                    if isPaused {
                        self.resumeTTS()
                    } else {
                        self.pauseTTS()
                    }
                    return nil
                }
                return event

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
                        let customAction = Action(
                            id: "custom_prompt_inline",
                            name: "Custom",
                            icon: "ellipsis.circle.fill",
                            prompt: self.customPromptText
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

    private func selectAction(_ action: Action) {
        // Handle custom prompt
        if action.id == "custom_prompt" {
            Logger.shared.info("Action selected: Custom prompt")
            state = .customPrompt
            updateView()
            return
        }

        // Check accessibility permission
        if !AXIsProcessTrusted() {
            Logger.shared.error("Action '\(action.name)' failed: Accessibility permission not granted")
            state = .error("ACCESSIBILITY_PERMISSION_REQUIRED")
            updateView()
            return
        }

        // Get selected text from clipboard
        guard !clipboardText.isEmpty else {
            Logger.shared.error("Action '\(action.name)' failed: No text selected")
            state = .error("No text selected.\nSelect some text first.")
            updateView()
            return
        }

        let textPreview = clipboardText.prefix(50).replacingOccurrences(of: "\n", with: " ")
        Logger.shared.info("Action '\(action.name)' on \(clipboardText.count) chars: \"\(textPreview)...\"")

        // Show processing state
        state = .processing
        updateView()

        switch action.actionType {
        case .tts:
            TTSClient.shared.speak(text: clipboardText) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        Logger.shared.info("TTS playback started")
                        self?.state = .ttsPlaying(isPaused: false)
                        self?.updateView()
                        self?.startTTSStatusPolling()
                    case .failure(let error):
                        Logger.shared.error("TTS failed: \(error.localizedDescription)")
                        self?.state = .error("TTS Error: \(error.localizedDescription)\n\nMake sure the TTS server is running.")
                        self?.updateView()
                    }
                }
            }

        case .command:
            let commandTemplate = action.prompt
            Logger.shared.info("Running command action: \(commandTemplate)")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")

                let hasPlaceholder = commandTemplate.contains("{text}")
                let command: String
                if hasPlaceholder {
                    command = commandTemplate.replacingOccurrences(of: "{text}", with: self.clipboardText.replacingOccurrences(of: "'", with: "'\\''"))
                } else {
                    command = commandTemplate
                }
                process.arguments = ["-c", command]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if !hasPlaceholder {
                    let stdinPipe = Pipe()
                    stdinPipe.fileHandleForWriting.write(self.clipboardText.data(using: .utf8) ?? Data())
                    stdinPipe.fileHandleForWriting.closeFile()
                    process.standardInput = stdinPipe
                }

                // 30 second timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 30)
                timer.setEventHandler { process.terminate() }
                timer.resume()

                do {
                    try process.run()
                    process.waitUntilExit()
                    timer.cancel()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    DispatchQueue.main.async {
                        if process.terminationStatus == 0 {
                            Logger.shared.info("Command completed, output: \(stdout.count) chars")
                            self.resultText = stdout
                            self.recordExchange(userPrompt: commandTemplate, selectedText: self.clipboardText, assistant: stdout, thinking: nil)
                            self.state = .result(stdout, thinking: nil)
                        } else {
                            let errorMsg = stderr.isEmpty ? "Command exited with code \(process.terminationStatus)" : stderr
                            Logger.shared.error("Command failed: \(errorMsg)")
                            self.state = .error(errorMsg)
                        }
                        self.updateView()
                    }
                } catch {
                    timer.cancel()
                    DispatchQueue.main.async {
                        Logger.shared.error("Command failed to launch: \(error.localizedDescription)")
                        self.state = .error("Failed to run command: \(error.localizedDescription)")
                        self.updateView()
                    }
                }
            }

        case .llm:
            // PR8: any non-Copy LLM action now opens the full chat, seeded with the
            // action applied to the selection. The agent loop produces the first
            // assistant turn (continuable), instead of the old single-shot result.
            let capturedText = clipboardText
            let seed = capturedText.isEmpty
                ? action.prompt
                : "\(action.prompt)\n\nText:\n\(capturedText)"
            enterChat(
                seedUser: seed,
                selectedText: capturedText.isEmpty ? nil : capturedText,
                autoRun: true)

        case .agent:
            runAgent(action: action)
        }
    }

    // MARK: - Agent chat (PR7 → PR8)

    /// Open the full Claude-style ChatView (PR8) for an `.agent` action. Seeds a
    /// fresh `ChatSession` (system + user, with the selection as context), enters
    /// chat mode (fixed-size panel), and kicks off the agent loop — its result
    /// becomes the first assistant turn, and the user can keep chatting.
    private func runAgent(action: Action) {
        let capturedText = clipboardText
        let userRequest = action.prompt
        let userContent = capturedText.isEmpty
            ? userRequest
            : "\(userRequest)\n\nSelected text:\n\(capturedText)"
        enterChat(
            seedUser: userContent,
            selectedText: capturedText.isEmpty ? nil : capturedText,
            autoRun: true)
    }

    /// Build a fresh chat session, switch into `.chat` state, resize the window to
    /// the fixed chat panel, and (optionally) start generating. Shared by the
    /// "Ask Agent" action, any non-Copy action routed to chat, and the
    /// empty-selection hotkey.
    private func enterChat(seedUser: String, selectedText: String?, autoRun: Bool) {
        let now = Date().timeIntervalSince1970
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: PopDraftAgent.systemPrompt, createdAt: now),
        ]
        if !seedUser.isEmpty {
            messages.append(ChatMessage(role: "user", content: seedUser, createdAt: now))
        }
        var session = ChatSession(
            createdAt: now, updatedAt: now,
            model: LLMClient.shared.currentModel,
            selectedText: selectedText,
            messages: messages)
        session.refreshTitle()
        presentChat(for: session, autoRun: autoRun)
    }

    /// Present `ChatView` for an existing/seeded session and size the panel.
    private func presentChat(for session: ChatSession, autoRun: Bool) {
        let vm = AgentChatViewModel(session: session, store: sessionStore)
        chatViewModel = vm
        // The chat's own save point: the controller persists on copy/minimize.
        currentSession = session
        didSaveCurrentSession = false
        // Record the starting size so an UNCHANGED reopened session isn't re-saved.
        presentedMessageCount = session.messages.count
        state = .chat
        sizeWindowForChat()
        updateView()
        if autoRun { vm.run() }
    }

    // MARK: - Debug show (item 9)

    /// Show the REAL on-screen action menu populated with the default actions, at
    /// the center of the main screen, for a `--debug-show menu` screen capture.
    func debugShowMenu() {
        resetPanelForMenu()
        clipboardText = "Our platform helps teams ship faster. We've seen customers reduce their deployment time by 40% on average."
        searchText = ""
        selectedIndex = 0
        state = .actionList
        updateView()
        centerOnMainScreen(defaultSize: NSSize(width: 360, height: 420))
        window?.makeKeyAndOrderFront(nil)
        startKeyboardMonitoring()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the REAL on-screen chat window seeded with a representative
    /// conversation (user msg, assistant Markdown answer incl. a ```mermaid
    /// block, a finished tool-call card, a thinking disclosure, plus a queued
    /// follow-up) at a deliberately non-default size for a `--debug-show chat`
    /// capture.
    func debugShowChat() {
        let session = PopupWindowController.sampleDebugSession()
        let vm = AgentChatViewModel(session: session, store: sessionStore)
        chatViewModel = vm
        currentSession = session
        didSaveCurrentSession = false
        presentedMessageCount = session.messages.count
        state = .chat
        // Pick a deliberately NON-default size to prove the window is resizable,
        // and publish it BEFORE building the content so `ChatView` renders at that
        // size and the hosting view sizes the window to match (no size fight).
        let size = NSSize(width: 620, height: 640)
        vm.panelSize = size
        updateView()

        if let window = window {
            window.styleMask.insert(.resizable)
            window.isMovableByWindowBackground = true
            window.minSize = GlassWindow.ChatGeometry.minSize
            let vf = primaryVisibleFrame()
            let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
            withProgrammaticResize {
                window.setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }

        // Seed a queued follow-up so the "queued (N)" affordance + a pending user
        // bubble are visible in the capture, and keep the streaming caret alive.
        vm.debugSeedQueuedFollowup("And add a section on rollback strategy.")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The visible frame of the primary (menu-bar) display, i.e. the one whose
    /// origin is (0,0). Reliable for debug captures regardless of mouse position.
    private func primaryVisibleFrame() -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return primary.visibleFrame
    }

    /// Center the shared panel on the primary screen at `defaultSize`.
    private func centerOnMainScreen(defaultSize: NSSize) {
        guard let window = window else { return }
        let vf = primaryVisibleFrame()
        let origin = NSPoint(x: vf.midX - defaultSize.width / 2,
                             y: vf.midY - defaultSize.height / 2)
        window.setFrame(NSRect(origin: origin, size: defaultSize), display: true)
    }

    /// Build a rich sample chat session that exercises every chat affordance:
    /// a selected-text context, a user message, a finished tool call, a thinking
    /// disclosure, and an assistant answer with full Markdown + a Mermaid diagram.
    static func sampleDebugSession() -> ChatSession {
        let now = Date().timeIntervalSince1970
        let answer = """
        Here's a tighter rewrite — and I verified the **40% deployment-time** claim via the search result below.

        ## Suggested rewrite
        > Our platform helps teams ship faster — customers cut deployment time by **40%** on average, with onboarding in days.

        ### Why it's stronger
        1. Leads with the outcome (*ship faster*).
        2. Keeps the verified **40%** stat front and center.
        3. Trims filler ("usually takes just a couple of").

        | Metric | Before | After |
        | --- | --- | --- |
        | Words | 31 | 18 |
        | Reading grade | 9.4 | 6.1 |

        A quick view of the rollout flow:

        ```mermaid
        flowchart LR
            A[Selected text] --> B{Action}
            B -->|Ask Agent| C[Chat + tools]
            B -->|Grammar| D[Quick fix]
            C --> E[Copy result]
            D --> E
        ```

        And the equivalent in code:

        ```swift
        func rewrite(_ text: String) -> String {
            text.condensed(target: .marketing)
        }
        ```
        """
        let searchResult = """
        [{"title":"Enterprise SaaS pricing benchmark 2026","url":"https://example.com/saas-benchmark","snippet":"Teams adopting modern deployment pipelines report a 38–42% reduction in average deployment time."}]
        """
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: PopDraftAgent.systemPrompt, createdAt: now),
            ChatMessage(role: "user",
                        content: "Make this more concise, and double-check the 40% pricing claim.",
                        createdAt: now),
            ChatMessage(role: "assistant", content: "",
                        toolCalls: [
                            ChatToolCall(id: "call_1", name: "web_search",
                                         arguments: "{\"query\":\"enterprise SaaS pricing benchmark 2026\"}"),
                        ], createdAt: now),
            ChatMessage(role: "tool", content: searchResult, toolCallId: "call_1", createdAt: now),
            ChatMessage(role: "assistant", content: answer,
                        thinking: "The user wants a tighter rewrite and asked me to verify the 40% deployment-time figure. I searched for a 2026 SaaS benchmark, found a source reporting 38–42%, which supports ~40%, then condensed the copy while keeping that stat.",
                        createdAt: now),
        ]
        var session = ChatSession(
            createdAt: now, updatedAt: now, model: "Qwen3.5-4B · local",
            selectedText: "Our platform helps teams ship faster. We've seen customers reduce their deployment time by 40% on average, and onboarding usually takes just a couple of days.",
            messages: messages)
        session.refreshTitle()
        return session
    }

    /// Size the chat panel and make it user-resizable + movable. Restores the
    /// last saved size/position (clamped to screen) if the user moved it before,
    /// otherwise falls back to the default size pinned near the cursor.
    /// Make the chat hosting view WINDOW-driven (not intrinsic-size-driven) so a
    /// `setFrame` opens the panel at the size we ask for and the user can drag it
    /// larger/smaller. Without this, NSHostingView re-asserts its fitting size and
    /// our `setFrame` is immediately overridden.
    private func prepareChatHostingView() {
        guard let host = hostingView else { return }
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
    }

    private func sizeWindowForChat() {
        guard let window = window else { return }
        // Make the shared panel resizable + movable while in chat mode (the quick
        // action menu resets these in `resetPanelForMenu`).
        window.styleMask.insert(.resizable)
        window.isMovableByWindowBackground = true
        window.minSize = GlassWindow.ChatGeometry.minSize
        prepareChatHostingView()

        let screen = currentScreen()
        let screenFrame = screen.visibleFrame

        if let saved = GlassWindow.ChatGeometry.load() {
            // Restore, clamped so it can't open fully offscreen.
            var f = saved
            f.size.width = min(f.size.width, screenFrame.width - 20)
            f.size.height = min(f.size.height, screenFrame.height - 20)
            f.origin.x = min(max(f.origin.x, screenFrame.minX + 10), screenFrame.maxX - f.width - 10)
            f.origin.y = min(max(f.origin.y, screenFrame.minY + 10), screenFrame.maxY - f.height - 10)
            chatViewModel?.panelSize = f.size
            withProgrammaticResize { window.setFrame(f, display: true) }
            return
        }

        // First open: default size pinned near the cursor.
        let size = NSSize(width: ChatView.panelWidth, height: ChatView.panelHeight)
        let mouseLocation = NSEvent.mouseLocation
        var origin = NSPoint(
            x: mouseLocation.x - size.width / 2,
            y: mouseLocation.y - size.height - 10)
        if origin.x < screenFrame.minX + 10 { origin.x = screenFrame.minX + 10 }
        if origin.x + size.width > screenFrame.maxX - 10 { origin.x = screenFrame.maxX - size.width - 10 }
        if origin.y < screenFrame.minY + 10 {
            origin.y = screenFrame.midY - size.height / 2
        }
        if origin.y + size.height > screenFrame.maxY - 10 {
            origin.y = screenFrame.maxY - size.height - 10
        }
        chatViewModel?.panelSize = size
        withProgrammaticResize { window.setFrame(NSRect(origin: origin, size: size), display: true) }
    }

    private func currentScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Reset the shared panel back to the fixed, cursor-anchored quick-menu form
    /// (the action menu must not be resizable/movable). Called before showing the
    /// action list.
    private func resetPanelForMenu() {
        guard let window = window else { return }
        window.styleMask.remove(.resizable)
        window.isMovableByWindowBackground = false
    }

    /// Persist the chat window's current size + position (call before tearing the
    /// chat down) so it reopens where the user left it.
    private func saveChatGeometryIfChat() {
        guard case .chat = state, let window = window else { return }
        GlassWindow.ChatGeometry.save(window.frame)
    }

    // MARK: - Session recording (PR5)

    /// Record one completed exchange into `currentSession`. The single-shot
    /// generation path is untouched — this just snapshots what happened so it can
    /// be persisted on copy/minimize and reopened later.
    ///
    ///  - `userPrompt`: the action prompt or the custom prompt the user ran.
    ///  - `selectedText`: the captured text the action ran on (nil for promptless).
    ///  - `assistant`: the produced result.
    ///  - `thinking`: optional captured reasoning.
    private func recordExchange(userPrompt: String, selectedText: String?, assistant: String, thinking: String?) {
        // A fresh session per invocation (single-shot today; multi-turn arrives
        // with the chat UI in PR8).
        let now = Date().timeIntervalSince1970
        let userMessage = ChatMessage(role: "user", content: userPrompt, createdAt: now)
        let assistantMessage = ChatMessage(role: "assistant", content: assistant, thinking: thinking, createdAt: now)
        var session = ChatSession(
            createdAt: now,
            updatedAt: now,
            model: LLMClient.shared.currentModel,
            selectedText: selectedText,
            messages: [userMessage, assistantMessage]
        )
        session.refreshTitle()
        currentSession = session
        didSaveCurrentSession = false
    }

    /// Persist the current session if it carries a meaningful exchange and hasn't
    /// already been saved. Safe to call from both copy and dismiss. In chat mode
    /// (PR8) the live `AgentChatViewModel.session` is the source of truth (it has
    /// the full multi-turn transcript), so prefer it.
    private func flushSessionIfMeaningful() {
        guard !didSaveCurrentSession else { return }
        let session = chatViewModel?.session ?? currentSession
        guard let session = session, session.hasMeaningfulExchange else { return }
        // Don't pollute Recent with a chat whose only assistant turn is an error
        // (e.g. the server was down) — there's nothing useful to reopen.
        let hasNonErrorAnswer = session.messages.contains {
            $0.role == "assistant" && $0.isError != true
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasNonErrorAnswer else { return }
        // Skip a redundant rewrite of an unmodified reopened session (same message
        // count as when presented) — avoids needless disk writes + title churn.
        if let presented = presentedMessageCount, session.messages.count == presented {
            return
        }
        var s = session
        s.refreshTitle()
        if sessionStore.save(s) {
            didSaveCurrentSession = true
            Logger.shared.info("Saved session \(s.id) (\"\(s.title)\")")
        }
    }

    /// Reopen a previously saved session by id, showing its last assistant message
    /// in the existing result view (PR5 — no chat UI yet). Crash-safe: a missing
    /// session is a no-op.
    func reopenSession(id: String) {
        guard let session = sessionStore.load(id: id) else {
            Logger.shared.error("Could not reopen session \(id)")
            return
        }
        // PR8: reopen as a full, continuable chat (not the old single-message
        // result view). An unchanged session won't be re-saved on dismiss
        // (`presentedMessageCount` guard); a new turn grows it and re-saves.
        onWillShow?()
        // Remember the app to refocus on dismiss (reopen skips captureSelectedText,
        // which is where `previousApp` is normally set).
        previousApp = NSWorkspace.shared.frontmostApplication
        clipboardText = session.selectedText ?? ""
        searchText = ""
        customPromptText = ""
        selectedIndex = 0
        presentChat(for: session, autoRun: false)
        window?.makeKeyAndOrderFront(nil)
        startKeyboardMonitoring()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)

        // PR5: persist the session on copy (before dismiss restores focus).
        flushSessionIfMeaningful()

        // Show brief feedback then dismiss
        showNotification(title: "PopDraft", message: "Copied to clipboard")
        dismiss()
    }

    // MARK: - TTS Controls

    private func startTTSStatusPolling() {
        stopTTSStatusPolling()
        ttsStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            TTSClient.shared.checkStatus { status in
                DispatchQueue.main.async {
                    if status == "idle" {
                        self?.stopTTSStatusPolling()
                        self?.dismiss()
                    }
                }
            }
        }
    }

    private func stopTTSStatusPolling() {
        ttsStatusTimer?.invalidate()
        ttsStatusTimer = nil
    }

    private func stopTTS() {
        stopTTSStatusPolling()
        TTSClient.shared.stop()
        dismiss()
    }

    private func pauseTTS() {
        TTSClient.shared.pause { [weak self] success in
            guard success else { return }
            DispatchQueue.main.async {
                self?.state = .ttsPlaying(isPaused: true)
                self?.updateView()
            }
        }
    }

    private func resumeTTS() {
        TTSClient.shared.resume { [weak self] success in
            guard success else { return }
            DispatchQueue.main.async {
                self?.state = .ttsPlaying(isPaused: false)
                self?.updateView()
            }
        }
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        // Bring System Settings to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        }
    }

    private func restartLlamaServer() {
        let llamaServerExists = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server") ||
                                FileManager.default.fileExists(atPath: "/usr/local/bin/llama-server")
        guard llamaServerExists else {
            self.state = .error("llama-server binary not found. Please install llama.cpp first.")
            self.updateView()
            return
        }

        self.state = .processing
        self.updateView()

        LlamaServerManager.shared.restart { [weak self] success in
            if success {
                self?.state = .actionList
            } else {
                self?.state = .error("Failed to start llama-server. Check /tmp/llm-llama-server.log for details.")
            }
            self?.updateView()
        }
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
