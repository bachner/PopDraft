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

// MARK: - Settings Window

/// One segment of the Settings tab bar: an icon + label, filled system-blue when
/// selected, with a hover highlight otherwise. A `Button` so it's keyboard- and
/// pointer-clickable, but plain-styled so it reads as a tab not a push button.
private struct SettingsTabButton: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(tab.shortLabel)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : ChatPalette.ink2)
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(ChatPalette.blue)
                          : (hovering ? AnyShapeStyle(ChatPalette.blue.opacity(0.10))
                             : AnyShapeStyle(Color.clear))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SettingsView: View {
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case models = "Models"
        case actions = "Actions"
        case mcp = "MCP"
        case tts = "Text-to-Speech"

        /// SF Symbol shown beside the tab label in the segmented tab bar.
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .models: return "cpu.fill"
            case .actions: return "wand.and.stars"
            case .mcp: return "server.rack"
            case .tts: return "speaker.wave.2.fill"
            }
        }

        /// Short label for the compact segmented control.
        var shortLabel: String {
            switch self {
            case .tts: return "Voice"
            default: return rawValue
            }
        }
    }

    @State private var selectedTab: SettingsTab = .general
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.shared.isEnabled
    @State private var selectedProvider: LLMConfig.Provider = .llamacpp
    @State private var ollamaModel: String = ""
    @State private var openaiAPIKey: String = ""
    @State private var openaiModel: String = ""
    @State private var claudeAPIKey: String = ""
    @State private var claudeModel: String = ""
    @State private var claudeExtendedThinking: Bool = false
    @State private var claudeThinkingBudget: Double = 10000
    @State private var ollamaEnableThinking: Bool = false
    @State private var llamacppEnableThinking: Bool = false
    @State private var availableOllamaModels: [String] = []
    @State private var isLoading = false
    @State private var customOpenAIModel: String = ""
    @State private var customClaudeModel: String = ""
    @State private var ttsVoice: String = "af_heart"
    @State private var ttsSpeed: Double = 1.0
    @State private var voiceSearchText: String = ""
    @State private var settingsActions: [Action] = []

    private var sortedActions: [Action] {
        settingsActions.sorted(by: { $0.order < $1.order })
    }
    @State private var customPromptEnabled: Bool = true
    @State private var showingActionEditor: Bool = false
    @State private var actionToEdit: Action? = nil
    @State private var editingShortcutFor: String? = nil  // actionId currently being edited
    @State private var customPromptShortcut: String? = "P"
    @State private var popupHotkey: String = "Space"
    @State private var editingPopupHotkey: Bool = false
    // PR4: corner bubble settings.
    @State private var bubbleEnabled: Bool = true
    @State private var bubbleCorner: BubbleCorner = .bottomRight
    // PR9: agent Mac-control settings.
    @State private var macControlEnabled: Bool = false
    @State private var autoApproveSafeReadOnly: Bool = false
    @State private var mcpServers: [MCPServerConfig] = []
    @State private var selectedLlamaModel: String = "qwen3.5-2b"
    @State private var isDownloadingModel: Bool = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadStatus: String = ""
    @State private var serverStatus: LlamaServerManager.Status = .unknown
    @State private var isRestartingServer: Bool = false
    @State private var serverStatusTimer: Timer? = nil

    // PR3: Models tab — local (Hugging Face) validation
    @State private var hfRepoInput: String = ""
    @State private var hfValidating: Bool = false
    @State private var hfValidation: ModelValidation? = nil
    @State private var hfFiles: [GGUFFile] = []
    @State private var hfSelectedFile: String = ""
    @State private var hfDebounceTask: Task<Void, Never>? = nil
    @State private var userModels: [ModelRef] = []

    // PR3: Models tab — cloud key validation
    @State private var cloudProvider: CloudProvider = .openai
    @State private var cloudKey: String = ""
    @State private var cloudValidating: Bool = false
    @State private var cloudValidation: KeyValidation? = nil
    @State private var cloudSelectedModel: String = ""
    @State private var providerKeys: [String: String] = [:]
    @State private var cloudDebounceTask: Task<Void, Never>? = nil
    let onSave: (LLMConfig) -> Void
    let onCancel: () -> Void

    private var filteredVoices: [(id: String, name: String, language: String)] {
        if voiceSearchText.isEmpty {
            return LLMConfig.ttsVoices
        }
        return LLMConfig.ttsVoices.filter {
            $0.name.localizedCaseInsensitiveContains(voiceSearchText) ||
            $0.id.localizedCaseInsensitiveContains(voiceSearchText) ||
            $0.language.localizedCaseInsensitiveContains(voiceSearchText)
        }
    }

    enum VoiceListItem: Identifiable {
        case header(language: String, count: Int)
        case voice(id: String, name: String, language: String)

        var id: String {
            switch self {
            case .header(let language, _): return "header_\(language)"
            case .voice(let id, _, _): return id
            }
        }
    }

    private var voiceListItems: [VoiceListItem] {
        let voices = filteredVoices
        var items: [VoiceListItem] = []
        for lang in LLMConfig.ttsVoiceLanguages {
            let langVoices = voices.filter { $0.language == lang }
            if !langVoices.isEmpty {
                items.append(.header(language: lang, count: langVoices.count))
                for v in langVoices {
                    items.append(.voice(id: v.id, name: v.name, language: v.language))
                }
            }
        }
        return items
    }

    @ViewBuilder
    private func voiceListRow(_ item: VoiceListItem) -> some View {
        switch item {
        case .header(let language, let count):
            HStack {
                Text(language)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        case .voice(let voiceId, let name, _):
            HStack {
                Image(systemName: ttsVoice == voiceId ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(ttsVoice == voiceId ? .accentColor : .secondary)
                    .font(.system(size: 14))
                Text(name)
                    .font(.system(size: 12))
                Spacer()
                Text(voiceId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(ttsVoice == voiceId ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(4)
            .onTapGesture {
                ttsVoice = voiceId
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            tabBar
            Divider().opacity(0.4)

            // Tab content — scrolls if a tab grows beyond the window.
            ScrollView {
                Group {
                    switch selectedTab {
                    case .general:
                        generalSettingsTab
                    case .actions:
                        actionsSettingsTab
                    case .models:
                        modelsSettingsTab
                    case .mcp:
                        MCPSettingsView(servers: $mcpServers)
                    case .tts:
                        ttsSettingsTab
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.4)

            // Footer actions.
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 620)
        .background(LiquidGlassBackground(cornerRadius: 16, shadow: false))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            loadCurrentConfig()
            if selectedProvider == .ollama {
                fetchOllamaModels()
            }
        }
        .onChange(of: selectedProvider) { _, newValue in
            if newValue == .ollama {
                fetchOllamaModels()
            }
        }
    }

    /// A small title row with the brand orb + "Settings" — reads as a window
    /// title since the real titlebar chrome is hidden for the glass look.
    private var titleBar: some View {
        HStack(spacing: 9) {
            Group {
                if let orb = AppAssets.bubbleOrb {
                    Image(nsImage: orb).resizable().scaledToFit()
                } else {
                    Circle().fill(LinearGradient(
                        colors: [ChatPalette.blue, Color(red: 0.78, green: 0.61, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .frame(width: 20, height: 20)
            Text("PopDraft Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatPalette.ink)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// A clearly-visible, capsule-segmented tab bar (System-Settings style):
    /// each tab is an icon + label, the selected one filled system-blue.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: { withAnimation(.easeOut(duration: 0.16)) { selectedTab = tab } })
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(ChatPalette.ink.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(ChatPalette.hairline.opacity(0.5), lineWidth: 0.5))
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    // MARK: - General Settings Tab

    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Launch at Login toggle
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                            .font(.system(size: 13, weight: .medium))
                        Text("Start PopDraft automatically when you log in")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLoginManager.shared.setEnabled(newValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Popup Hotkey
            VStack(alignment: .leading, spacing: 8) {
                Text("Popup Menu Hotkey")
                    .font(.system(size: 13, weight: .medium))

                HStack {
                    Text("Option +")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if editingPopupHotkey {
                        ShortcutRecorderView(
                            onCapture: { key in
                                if let key = key {
                                    popupHotkey = key
                                }
                                editingPopupHotkey = false
                            },
                            onCancel: {
                                editingPopupHotkey = false
                            }
                        )
                        .frame(width: 80)
                    } else {
                        Button(action: {
                            editingPopupHotkey = true
                        }) {
                            Text(popupHotkey.uppercased())
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("to show popup menu")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // PR4: Corner bubble
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $bubbleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show corner bubble")
                            .font(.system(size: 13, weight: .medium))
                        Text("Keep a small orb pinned to a screen corner instead of vanishing")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack {
                    Text("Corner")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Picker("", selection: $bubbleCorner) {
                        ForEach(BubbleCorner.allCases, id: \.self) { corner in
                            Text(corner.displayName).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(!bubbleEnabled)
                    Spacer()
                }
                .opacity(bubbleEnabled ? 1.0 : 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // PR9: Mac-control (confirm-gated) — OFF by default, with a warning.
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $macControlEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.orange)
                            Text("Allow agent to control your Mac")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text("Lets the agent PROPOSE shell commands and AppleScripts. Every action is shown to you for explicit approval before it runs — the agent can never execute anything on its own. Dangerous commands (sudo, rm -rf /, curl | sh, …) are always blocked.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if macControlEnabled {
                    Toggle(isOn: $autoApproveSafeReadOnly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-approve safe read-only commands")
                                .font(.system(size: 12))
                            Text("Skip the approval prompt for read-only commands like ls, cat, pwd, echo, date, whoami. Everything else still asks; the denylist always applies.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(6)

                    if !mcpServers.isEmpty {
                        Text("MCP servers: \(mcpServers.map { $0.name }.joined(separator: ", ")) — manage in the MCP tab")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Actions Settings Tab

    private var actionsSettingsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    Text("Actions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)

                    // Action list with up/down reorder buttons
                    VStack(spacing: 0) {
                        let sorted = sortedActions
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, action in
                            if index > 0 {
                                Divider().padding(.horizontal, 12)
                            }
                            actionRow(action: action, index: index, total: sorted.count)
                        }

                        Divider().padding(.horizontal, 12)

                        // Custom prompt row (inline)
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { customPromptEnabled },
                                set: { newVal in
                                    customPromptEnabled = newVal
                                    ActionManager.shared.customPromptEnabled = newVal
                                    ActionManager.shared.save()
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .frame(width: 36)

                            Image(systemName: "ellipsis.circle.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 18)

                            Text("Custom prompt...")
                                .font(.system(size: 12))
                                .lineLimit(1)

                            Spacer()

                            shortcutButton(actionId: "custom_prompt", currentShortcut: customPromptShortcut)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal, 16)

                    // Add Action button
                    Button(action: {
                        actionToEdit = nil
                        showingActionEditor = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Action")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    // Restore defaults button
                    HStack {
                        Spacer()
                        Button(action: {
                            ActionManager.shared.restoreDefaults()
                            settingsActions = ActionManager.shared.actions
                        }) {
                            Text("Restore Default Actions")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear {
            loadActionsState()
        }
        .sheet(isPresented: $showingActionEditor) {
            ActionEditorSheet(
                action: actionToEdit,
                onSave: { newAction in
                    if actionToEdit != nil {
                        ActionManager.shared.update(newAction)
                    } else {
                        ActionManager.shared.add(newAction)
                    }
                    settingsActions = ActionManager.shared.actions
                    showingActionEditor = false
                    actionToEdit = nil
                },
                onCancel: {
                    showingActionEditor = false
                    actionToEdit = nil
                }
            )
        }
    }

    private func actionRow(action: Action, index: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { settingsActions.first(where: { $0.id == action.id })?.isEnabled ?? true },
                set: { _ in
                    ActionManager.shared.toggleEnabled(action.id)
                    settingsActions = ActionManager.shared.actions
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 36)

            Image(systemName: action.icon)
                .foregroundColor(.accentColor)
                .frame(width: 18)

            Text(action.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Text(action.actionType.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(3)

            Spacer()

            // Reorder buttons
            VStack(spacing: 0) {
                Button(action: {
                    guard index > 0 else { return }
                    ActionManager.shared.move(from: IndexSet(integer: index), to: index - 1)
                    settingsActions = ActionManager.shared.actions
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(index > 0 ? .secondary : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button(action: {
                    guard index < total - 1 else { return }
                    ActionManager.shared.move(from: IndexSet(integer: index), to: index + 2)
                    settingsActions = ActionManager.shared.actions
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(index < total - 1 ? .secondary : .secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(index == total - 1)
            }
            .frame(width: 16)

            shortcutButton(actionId: action.id, currentShortcut: action.shortcut)

            Button(action: {
                actionToEdit = action
                showingActionEditor = true
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: {
                ActionManager.shared.delete(action.id)
                settingsActions = ActionManager.shared.actions
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func shortcutButton(actionId: String, currentShortcut: String?) -> some View {
        Group {
            if editingShortcutFor == actionId {
                ShortcutRecorderView(
                    onCapture: { key in
                        if actionId == "custom_prompt" {
                            customPromptShortcut = key
                            ActionManager.shared.customPromptShortcut = key
                            ActionManager.shared.save()
                        } else if let key = key {
                            if var action = settingsActions.first(where: { $0.id == actionId }) {
                                action.shortcut = key
                                ActionManager.shared.update(action)
                                settingsActions = ActionManager.shared.actions
                            }
                        } else {
                            if var action = settingsActions.first(where: { $0.id == actionId }) {
                                action.shortcut = nil
                                ActionManager.shared.update(action)
                                settingsActions = ActionManager.shared.actions
                            }
                        }
                        editingShortcutFor = nil
                    },
                    onCancel: {
                        editingShortcutFor = nil
                    }
                )
                .frame(width: 70)
            } else {
                Button(action: { editingShortcutFor = actionId }) {
                    if let shortcut = currentShortcut {
                        Text("^⌥\(shortcut)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Set...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }
        }
    }

    private func loadActionsState() {
        ActionManager.shared.load()
        settingsActions = ActionManager.shared.actions
        customPromptShortcut = ActionManager.shared.customPromptShortcut
        customPromptEnabled = ActionManager.shared.customPromptEnabled
    }

    // MARK: - Models Settings Tab (PR3)

    private var modelsSettingsTab: some View {
        VStack(spacing: 12) {
            // Provider selection — chooses the ACTIVE provider used by the single-shot path.
            VStack(alignment: .leading, spacing: 4) {
                Text("Active Provider")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: $selectedProvider) {
                    ForEach(LLMConfig.Provider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Provider-specific settings + the new validation panes.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedProvider {
                    case .llamacpp:
                        llamacppSettings
                        Divider()
                        localModelSection
                    case .ollama:
                        ollamaSettings
                    case .openai:
                        openaiSettings
                        Divider()
                        cloudModelSection
                    case .claude:
                        claudeSettings
                        Divider()
                        cloudModelSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 230)
        }
    }

    // MARK: - Local model section (Hugging Face GGUF)

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a local model from Hugging Face")
                .font(.system(size: 12, weight: .semibold))

            TextField("e.g. Qwen/Qwen2.5-7B-Instruct-GGUF", text: $hfRepoInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onChange(of: hfRepoInput) { _, newValue in
                    scheduleHFValidation(newValue)
                }

            // Live chip
            hfValidationChip

            // Quant picker + download (only when valid & files listed)
            if let v = hfValidation, v.isUsable, !hfFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Quantization")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $hfSelectedFile) {
                            ForEach(hfFiles, id: \.filename) { f in
                                Text(quantLabel(f)).tag(f.filename)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }

                    if isDownloadingModel {
                        ProgressView(value: downloadProgress, total: 100)
                            .progressViewStyle(.linear)
                        Text(downloadStatus)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Button("Download & Use") {
                            downloadHFModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            // User-managed local models
            let localUserModels = userModels.filter { $0.source == "huggingface" }
            if !localUserModels.isEmpty {
                Divider()
                Text("Your local models")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                ForEach(Array(localUserModels.enumerated()), id: \.offset) { _, m in
                    HStack(spacing: 6) {
                        Image(systemName: "cube.box.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        Text(m.name + (m.quant.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(action: { removeUserModel(m) }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hfValidationChip: some View {
        if hfRepoInput.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if hfValidating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Checking Hugging Face…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        } else if let v = hfValidation {
            HStack(spacing: 6) {
                Image(systemName: chipIcon(for: v))
                    .foregroundColor(chipColor(for: v))
                    .font(.system(size: 12))
                Text(chipText(for: v))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func chipIcon(for v: ModelValidation) -> String {
        switch v.state {
        case .valid: return "checkmark.circle.fill"
        case .validNeedsToken: return "lock.fill"
        default: return "xmark.circle.fill"
        }
    }

    private func chipColor(for v: ModelValidation) -> Color {
        switch v.state {
        case .valid: return .green
        case .validNeedsToken: return .orange
        default: return .red
        }
    }

    private func chipText(for v: ModelValidation) -> String {
        if v.state == .valid {
            // Show the smallest known-size quant + size as a hint (skip 0-byte/unknown).
            if let f = smallestUsableFile(hfFiles) ?? hfFiles.first {
                let size = f.sizeBytes > 0 ? " · \(f.sizeBytes.humanReadableSize)" : ""
                let quant = f.quant.isEmpty ? "" : " · \(f.quant)"
                return "Found on Hugging Face\(quant)\(size)"
            }
            return v.message
        }
        return v.message
    }

    private func quantLabel(_ f: GGUFFile) -> String {
        let q = f.quant.isEmpty ? f.filename : f.quant
        let size = f.sizeBytes > 0 ? " (\(f.sizeBytes.humanReadableSize))" : ""
        return q + size
    }

    // MARK: - Cloud model section (provider key validation)

    private var cloudModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Validate your API key")
                .font(.system(size: 12, weight: .semibold))

            Picker("", selection: $cloudProvider) {
                ForEach(CloudProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: cloudProvider) { _, _ in
                cloudValidation = nil
                cloudKey = providerKeys[cloudProvider.rawValue] ?? currentKeyForActiveProvider()
            }

            SecureField("API key", text: $cloudKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onChange(of: cloudKey) { _, newValue in
                    scheduleCloudValidation(newValue)
                }

            // Live chip
            if cloudValidating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Validating key…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if let v = cloudValidation {
                HStack(spacing: 6) {
                    Image(systemName: v.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(v.isValid ? .green : .red)
                        .font(.system(size: 12))
                    Text(v.isValid ? "Key valid · \(v.models.count) models available" : "Key invalid\(v.error.map { " (\($0))" } ?? "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            // Model picker from returned ids
            if let v = cloudValidation, v.isValid, !v.models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 11, weight: .medium))
                    Picker("", selection: $cloudSelectedModel) {
                        ForEach(v.models, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .labelsHidden()
                    if cloudProviderCanBeActive {
                        Text("Selecting a model here sets it as the active model for \(cloudProvider.displayName).")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(cloudProvider.displayName) is saved for use in Agent mode (coming soon) — it can't be the active single-shot model yet.")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                .onChange(of: cloudSelectedModel) { _, newValue in
                    applyCloudModelSelection(newValue)
                }
            }
        }
    }

    /// PR3 only routes single-shot generation to OpenAI (api.openai.com) and Anthropic.
    /// Gemini/OpenRouter keys are validated + stored, but can't be the ACTIVE model yet
    /// (full routing arrives in PR7). This guards against clobbering the OpenAI config.
    private var cloudProviderCanBeActive: Bool {
        cloudProvider == .openai || cloudProvider == .anthropic
    }

    /// The key currently in the active-provider config field, used as a sensible default.
    /// Only OpenAI/Anthropic mirror to real config; others read from providerKeys only.
    private func currentKeyForActiveProvider() -> String {
        switch cloudProvider {
        case .openai: return openaiAPIKey
        case .anthropic: return claudeAPIKey
        case .gemini, .openrouter: return providerKeys[cloudProvider.rawValue] ?? ""
        }
    }

    // MARK: - TTS Settings Tab

    private var ttsSettingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Voice selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice")
                    .font(.system(size: 12, weight: .medium))

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("Search voices...", text: $voiceSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                // Voice list grouped by language
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(voiceListItems, id: \.id) { item in
                            voiceListRow(item)
                        }
                    }
                }
                .frame(height: 160)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
            }

            // Speed slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speed")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.1fx", ttsSpeed))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("0.5x")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(value: $ttsSpeed, in: 0.5...2.0, step: 0.1)
                    Text("2.0x")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Test button
            Button(action: testVoice) {
                HStack {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Test Voice")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(16)
    }

    private func testVoice() {
        TTSClient.shared.speak(text: "Hello! This is a test of the selected voice.", voice: ttsVoice, speed: ttsSpeed) { _ in }
    }

    // MARK: - Provider Settings Views

    private var llamacppSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("llama.cpp runs locally on your machine.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
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

            // Download status
            if isDownloadingModel {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: downloadProgress, total: 100)
                        .progressViewStyle(.linear)
                    Text(downloadStatus)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else if !DependencyManager.shared.isModelDownloaded(selectedLlamaModel) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text("Model not downloaded")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Button("Download Model") {
                        downloadSelectedModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("Model ready")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Server status
            HStack(spacing: 6) {
                Circle()
                    .fill(serverStatusColor)
                    .frame(width: 8, height: 8)
                Text(serverStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if isRestartingServer {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Restarting...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Button(action: restartServer) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                            Text("Restart")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                }
            }
            .onAppear {
                serverStatus = LlamaServerManager.shared.status
                LlamaServerManager.shared.checkNow { status in
                    serverStatus = status
                }
                serverStatusTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                    LlamaServerManager.shared.checkNow { status in
                        serverStatus = status
                    }
                }
            }
            .onDisappear {
                serverStatusTimer?.invalidate()
                serverStatusTimer = nil
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Enable Thinking", isOn: $llamacppEnableThinking)
                    .font(.system(size: 12, weight: .medium))
                Text("Enable reasoning from thinking models (e.g., DeepSeek-R1, QwQ)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var serverStatusColor: Color {
        switch serverStatus {
        case .online: return .green
        case .loading: return .orange
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    private var serverStatusText: String {
        switch serverStatus {
        case .online: return "Server online"
        case .loading: return "Server loading model..."
        case .offline: return "Server offline"
        case .unknown: return "Checking server..."
        }
    }

    private func restartServer() {
        isRestartingServer = true
        LlamaServerManager.shared.restart { success in
            isRestartingServer = false
            serverStatus = success ? .online : .offline
        }
    }

    private func downloadSelectedModel() {
        guard let model = LLMConfig.llamaModels.first(where: { $0.id == selectedLlamaModel }) else { return }

        isDownloadingModel = true
        downloadProgress = 0
        downloadStatus = "Starting download..."

        DispatchQueue.global(qos: .userInitiated).async {
            // Stop llama-server if running
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stopProcess.arguments = ["bootout", "gui/\(getuid())/com.popdraft.llama-server"]
            try? stopProcess.run()
            stopProcess.waitUntilExit()

            // Create models directory
            let modelsDir = NSString(string: "~/.popdraft/models").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)

            let modelPath = "\(modelsDir)/\(model.filename)"

            // Download using curl with progress
            let curlProcess = Process()
            curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curlProcess.arguments = ["-L", "-o", modelPath, "--progress-bar", model.url]

            let pipe = Pipe()
            curlProcess.standardError = pipe

            try? curlProcess.run()

            // Monitor progress
            DispatchQueue.main.async {
                self.downloadStatus = "Downloading \(model.name)..."
            }

            curlProcess.waitUntilExit()

            if curlProcess.terminationStatus == 0 {
                // Update config and restart server
                DispatchQueue.main.async {
                    self.downloadStatus = "Restarting server..."
                    self.downloadProgress = 90
                }

                // Update LaunchAgent with new model
                DependencyManager.shared.createLlamaLaunchAgentForModel(model)

                // Start server
                let startProcess = Process()
                startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                startProcess.arguments = ["bootstrap", "gui/\(getuid())",
                    NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath]
                try? startProcess.run()
                startProcess.waitUntilExit()

                DispatchQueue.main.async {
                    self.downloadProgress = 100
                    self.downloadStatus = "Complete!"

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.isDownloadingModel = false
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.downloadStatus = "Download failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.isDownloadingModel = false
                    }
                }
            }
        }
    }

    // MARK: - PR3: Hugging Face validation + download

    /// Debounced (~400ms) validation of the pasted HF repo via ModelValidator.
    private func scheduleHFValidation(_ raw: String) {
        hfDebounceTask?.cancel()
        let repo = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else {
            hfValidating = false
            hfValidation = nil
            hfFiles = []
            return
        }
        // Clear stale state so the chip / quant picker don't show old data mid-debounce.
        hfValidating = true
        hfValidation = nil
        hfFiles = []
        hfDebounceTask = Task { [repo] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let validation = await ModelValidator.validateHFRepo(repo)
            // `let` (not `var`) so the value isn't a mutable capture in the closures below
            // — older CI Swift rejects capturing a mutated var in concurrent code.
            let files: [GGUFFile] = validation.isUsable ? await ModelValidator.listGGUFFiles(repo) : []
            if Task.isCancelled { return }
            await MainActor.run {
                hfValidating = false
                hfValidation = validation
                hfFiles = files
                // Prefer the smallest file with a KNOWN size; size-unknown (0-byte) GGUFs
                // (e.g. sharded parts) shouldn't win the default selection.
                if let first = smallestUsableFile(files) {
                    hfSelectedFile = first.filename
                } else if let first = files.first {
                    hfSelectedFile = first.filename
                }
            }
        }
    }

    /// The smallest GGUF file with a known (>0) size, used for the default quant pick.
    private func smallestUsableFile(_ files: [GGUFFile]) -> GGUFFile? {
        files.filter { $0.sizeBytes > 0 }.min(by: { $0.sizeBytes < $1.sizeBytes })
    }

    /// Download the chosen GGUF file from the validated HF repo and register it as a user model.
    private func downloadHFModel() {
        let repo = ModelValidator.normalizeHFRepo(hfRepoInput)
        guard !repo.isEmpty, let file = hfFiles.first(where: { $0.filename == hfSelectedFile }) ?? hfFiles.first else { return }

        // Security: reject any filename that isn't a plain `name.gguf` before it flows
        // into a filesystem path or the launch-agent plist XML (path traversal / XML injection).
        // Validate the bare last component — the local file + plist must be a safe name.
        let baseName = (file.filename as NSString).lastPathComponent
        guard let destFilename = ModelValidator.safeGGUFFilename(baseName) else {
            downloadStatus = "Unsafe model filename — refusing to download."
            isDownloadingModel = false
            return
        }

        let resolveURL = ModelValidator.hfResolveURL(repo: repo, file: file.filename)
        isDownloadingModel = true
        downloadProgress = 0
        downloadStatus = "Starting download…"

        DispatchQueue.global(qos: .userInitiated).async {
            // Stop llama-server if running (mirrors downloadSelectedModel).
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stopProcess.arguments = ["bootout", "gui/\(getuid())/com.popdraft.llama-server"]
            try? stopProcess.run()
            stopProcess.waitUntilExit()

            let modelsDir = NSString(string: "~/.popdraft/models").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
            let modelPath = "\(modelsDir)/\(destFilename)"

            DispatchQueue.main.async { self.downloadStatus = "Downloading \(destFilename)…" }

            let curlProcess = Process()
            curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curlProcess.arguments = ["-L", "-o", modelPath, resolveURL]
            curlProcess.standardOutput = FileHandle.nullDevice
            curlProcess.standardError = FileHandle.nullDevice
            try? curlProcess.run()

            // Progress by polling the partial file against the known size.
            let expected = file.sizeBytes > 0 ? file.sizeBytes : 4_000_000_000
            while curlProcess.isRunning {
                Thread.sleep(forTimeInterval: 1.0)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
                   let size = attrs[.size] as? Int64 {
                    let percent = min(99.0, Double(size) / Double(expected) * 100.0)
                    let mb = size / 1_000_000
                    DispatchQueue.main.async {
                        self.downloadProgress = percent
                        self.downloadStatus = "Downloading… \(Int(percent))% (\(mb)MB)"
                    }
                }
            }

            let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: modelPath))?[.size] as? Int64 ?? 0
            let ok = curlProcess.terminationStatus == 0 && downloadedSize > 100_000_000

            if ok {
                DispatchQueue.main.async {
                    self.downloadProgress = 95
                    self.downloadStatus = "Configuring server…"
                    // Register as a user model + make it active.
                    let ref = ModelRef(provider: "llamacpp", name: repo, quant: file.quant.isEmpty ? nil : file.quant, source: "huggingface")
                    if !self.userModels.contains(where: { $0.name == ref.name && $0.quant == ref.quant }) {
                        self.userModels.append(ref)
                    }
                }
                // Point the llama-server LaunchAgent at the freshly downloaded file.
                let model = LLMConfig.LlamaModel(
                    id: "hf:\(repo):\(file.quant)",
                    name: repo,
                    size: file.sizeBytes.humanReadableSize,
                    languages: "",
                    url: resolveURL,
                    filename: destFilename
                )
                DependencyManager.shared.createLlamaLaunchAgentForModel(model)

                let startProcess = Process()
                startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                startProcess.arguments = ["bootstrap", "gui/\(getuid())",
                    NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath]
                try? startProcess.run()
                startProcess.waitUntilExit()

                DispatchQueue.main.async {
                    self.downloadProgress = 100
                    self.downloadStatus = "Ready"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.isDownloadingModel = false
                    }
                }
            } else {
                try? FileManager.default.removeItem(atPath: modelPath)
                DispatchQueue.main.async {
                    self.downloadStatus = "Download failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.isDownloadingModel = false
                    }
                }
            }
        }
    }

    private func removeUserModel(_ model: ModelRef) {
        userModels.removeAll { $0.name == model.name && $0.quant == model.quant && $0.source == model.source }
    }

    // MARK: - PR3: Cloud key validation

    /// Debounced (~500ms) validation of the cloud API key.
    private func scheduleCloudValidation(_ raw: String) {
        cloudDebounceTask?.cancel()
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always store the key under its own provider slot.
        providerKeys[cloudProvider.rawValue] = key
        // Only OpenAI/Anthropic mirror into the real config fields used by the
        // single-shot path. Gemini/OpenRouter must NEVER overwrite the OpenAI key
        // (PR3 routes single-shot only to api.openai.com / api.anthropic.com).
        switch cloudProvider {
        case .openai: openaiAPIKey = key
        case .anthropic: claudeAPIKey = key
        case .gemini, .openrouter: break
        }
        guard key.count >= 8 else {
            cloudValidating = false
            cloudValidation = nil
            return
        }
        cloudValidating = true
        let provider = cloudProvider
        cloudDebounceTask = Task { [key, provider] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            let result = await ModelValidator.validateCloudKey(provider: provider, key: key)
            if Task.isCancelled { return }
            await MainActor.run {
                cloudValidating = false
                cloudValidation = result
                if result.isValid, cloudSelectedModel.isEmpty, let first = result.models.first {
                    cloudSelectedModel = first
                }
            }
        }
    }

    /// Apply the user's cloud model selection. Only OpenAI/Anthropic become the ACTIVE
    /// single-shot model; Gemini/OpenRouter are only recorded in userModels (for PR7).
    private func applyCloudModelSelection(_ modelId: String) {
        guard !modelId.isEmpty else { return }
        switch cloudProvider {
        case .openai:
            openaiModel = modelId
            customOpenAIModel = modelId
        case .anthropic:
            claudeModel = modelId
            customClaudeModel = modelId
        case .gemini, .openrouter:
            // Do NOT touch openaiModel/claudeModel — those drive the live request path.
            break
        }
        // Record under the provider's own slot (gemini/openrouter use their own rawValue).
        let provider = cloudProviderCanBeActive ? cloudProvider.llmProviderRawValue : cloudProvider.rawValue
        let ref = ModelRef(provider: provider, name: modelId, quant: nil, source: "cloud")
        if !userModels.contains(where: { $0.name == ref.name && $0.provider == ref.provider && $0.source == "cloud" }) {
            userModels.append(ref)
        }
    }

    private var ollamaSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                ProgressView("Loading models...")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                    if availableOllamaModels.isEmpty {
                        TextField("e.g., qwen3.5:4b", text: $ollamaModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $ollamaModel) {
                            ForEach(availableOllamaModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Text("If Ollama fails, PopDraft will fall back to llama.cpp")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable Thinking", isOn: $ollamaEnableThinking)
                        .font(.system(size: 12, weight: .medium))
                    Text("Enable reasoning from thinking models (e.g., DeepSeek-R1, QwQ)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var openaiSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.system(size: 12, weight: .medium))
                SecureField("sk-...", text: $openaiAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your API key from platform.openai.com")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: $openaiModel) {
                    ForEach(openaiModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()

                if openaiModel == "Custom..." {
                    TextField("Enter model name", text: $customOpenAIModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    /// Picker options for OpenAI: user-validated models first (source of truth),
    /// then the small suggestion list as a fallback, plus "Custom...".
    private var openaiModelOptions: [String] {
        var ids = userModels.filter { $0.provider == "openai" && $0.source == "cloud" }.map { $0.name }
        for s in LLMConfig.openaiModels where !ids.contains(s) { ids.append(s) }
        if !ids.contains("Custom...") { ids.append("Custom...") }
        return ids
    }

    /// Picker options for Claude/Anthropic: user-validated models first, then suggestions.
    private var claudeModelOptions: [String] {
        var ids = userModels.filter { $0.provider == "claude" && $0.source == "cloud" }.map { $0.name }
        for s in LLMConfig.claudeModels where !ids.contains(s) { ids.append(s) }
        if !ids.contains("Custom...") { ids.append("Custom...") }
        return ids
    }

    private var claudeSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.system(size: 12, weight: .medium))
                SecureField("sk-ant-...", text: $claudeAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your API key from console.anthropic.com")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: $claudeModel) {
                    ForEach(claudeModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()

                if claudeModel == "Custom..." {
                    TextField("Enter model name", text: $customClaudeModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Extended Thinking", isOn: $claudeExtendedThinking)
                    .font(.system(size: 12, weight: .medium))
                if claudeExtendedThinking {
                    HStack {
                        Text("Budget:")
                            .font(.system(size: 11))
                        Slider(value: $claudeThinkingBudget, in: 1000...100000, step: 1000)
                        Text("\(Int(claudeThinkingBudget / 1000))K tokens")
                            .font(.system(size: 11))
                            .frame(width: 65, alignment: .trailing)
                    }
                }
                Text("Let Claude think step-by-step before responding")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Methods

    private func loadCurrentConfig() {
        let config = LLMConfig.load()
        // PR3: load user-managed models + keys FIRST so picker resolution can see them.
        userModels = config.userModels
        providerKeys = config.providerKeys

        selectedProvider = config.provider
        selectedLlamaModel = LLMConfig.llamaModels.contains(where: { $0.id == config.llamaModel }) ? config.llamaModel : LLMConfig.llamaModels.first?.id ?? "qwen3.5-2b"
        ollamaModel = config.ollamaModel
        openaiAPIKey = config.openaiAPIKey
        // A saved model resolves to itself if it's a known suggestion OR a user-validated model.
        let knownOpenAI = LLMConfig.openaiModels.contains(config.openaiModel) ||
            userModels.contains { $0.provider == "openai" && $0.source == "cloud" && $0.name == config.openaiModel }
        openaiModel = knownOpenAI ? config.openaiModel : "Custom..."
        if openaiModel == "Custom..." {
            customOpenAIModel = config.openaiModel
        }
        claudeAPIKey = config.claudeAPIKey
        let knownClaude = LLMConfig.claudeModels.contains(config.claudeModel) ||
            userModels.contains { $0.provider == "claude" && $0.source == "cloud" && $0.name == config.claudeModel }
        claudeModel = knownClaude ? config.claudeModel : "Custom..."
        if claudeModel == "Custom..." {
            customClaudeModel = config.claudeModel
        }
        claudeExtendedThinking = config.claudeExtendedThinking
        claudeThinkingBudget = Double(config.claudeThinkingBudget)
        ollamaEnableThinking = config.ollamaEnableThinking
        llamacppEnableThinking = config.llamacppEnableThinking
        ttsVoice = config.ttsVoice
        ttsSpeed = config.ttsSpeed
        popupHotkey = config.popupHotkey
        bubbleEnabled = config.bubble.enabled
        bubbleCorner = BubbleCorner.parse(config.bubble.corner)
        // PR9: Mac-control + MCP.
        macControlEnabled = config.agentSettings.enableMacControl
        autoApproveSafeReadOnly = config.agentSettings.autoApproveSafeReadOnly
        mcpServers = config.mcpServers
        settingsActions = ActionManager.shared.actions
        customPromptShortcut = ActionManager.shared.customPromptShortcut
        customPromptEnabled = ActionManager.shared.customPromptEnabled

        // PR3: default the cloud panel to match the active provider, prefilling its key.
        switch config.provider {
        case .claude:
            cloudProvider = .anthropic
            cloudKey = providerKeys["anthropic"] ?? config.claudeAPIKey
        default:
            cloudProvider = .openai
            cloudKey = providerKeys["openai"] ?? config.openaiAPIKey
        }
    }

    private func fetchOllamaModels() {
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

                availableOllamaModels = models.compactMap { $0["name"] as? String }.sorted()

                if !ollamaModel.isEmpty && !availableOllamaModels.contains(ollamaModel) {
                    availableOllamaModels.insert(ollamaModel, at: 0)
                }
            }
        }.resume()
    }

    private func saveSettings() {
        var config = LLMConfig()
        config.provider = selectedProvider
        config.llamaModel = selectedLlamaModel
        config.ollamaModel = ollamaModel
        config.openaiAPIKey = openaiAPIKey
        config.openaiModel = openaiModel == "Custom..." ? customOpenAIModel : openaiModel
        config.claudeAPIKey = claudeAPIKey
        config.claudeModel = claudeModel == "Custom..." ? customClaudeModel : claudeModel
        config.claudeExtendedThinking = claudeExtendedThinking
        config.claudeThinkingBudget = Int(claudeThinkingBudget)
        config.ollamaEnableThinking = ollamaEnableThinking
        config.llamacppEnableThinking = llamacppEnableThinking
        config.ttsVoice = ttsVoice
        config.ttsSpeed = ttsSpeed
        config.popupHotkey = popupHotkey
        // PR3: persist user-managed models + provider keys.
        config.userModels = userModels
        config.providerKeys = providerKeys
        // PR4: persist corner-bubble settings.
        config.bubble = BubbleSettings(enabled: bubbleEnabled, corner: bubbleCorner.rawValue)
        // PR9: persist Mac-control settings, PRESERVING the other agentSettings
        // fields (maxIterations / enableWebSearch / macControlDryRun) already on
        // disk — we only own the two General-tab toggles here.
        var agent = AppConfig.load(dir: LLMConfig.configDir).agentSettings
        agent.enableMacControl = macControlEnabled
        agent.autoApproveSafeReadOnly = autoApproveSafeReadOnly
        config.agentSettings = agent
        config.mcpServers = mcpServers
        onSave(config)
    }
}

// MARK: - PR10: MCP servers settings (self-contained)

/// Self-contained Settings section for managing MCP servers: add / edit /
/// remove + enable, with one-click presets for common integrations. Binds
/// directly to `SettingsView`'s `mcpServers` state, which `saveSettings()`
/// already persists into `AppConfig.mcpServers`. Kept as its own struct so it
/// merges cleanly with a parallel SettingsView overhaul (one `case .mcp`).
struct MCPSettingsView: View {
    @Binding var servers: [MCPServerConfig]
    /// Index of the server being edited inline (nil = none / list view).
    @State private var editingIndex: Int? = nil
    @State private var draftName: String = ""
    @State private var draftCommand: String = ""
    @State private var draftArgs: String = ""   // space/newline-joined for editing
    @State private var showPresetMenu: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("MCP servers")
                    .font(.system(size: 13, weight: .semibold))
                Text("Connect external tools (email, calendar, Slack, Notion, files, …) "
                    + "so the agent can use them. Each runs as a local stdio process; its "
                    + "tools appear to the agent namespaced as server__tool.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Existing servers.
                if servers.isEmpty {
                    Text("No MCP servers configured. Add one below or pick a preset.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(servers.indices, id: \.self) { i in
                        serverRow(i)
                    }
                }

                Divider().padding(.vertical, 4)

                // Add / edit form.
                if let idx = editingIndex {
                    editForm(editingExisting: idx < servers.count)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            beginAdd()
                        } label: {
                            Label("Add server", systemImage: "plus")
                        }
                        Menu("Presets") {
                            ForEach(IntegrationCatalog.all.indices, id: \.self) { p in
                                let cat = IntegrationCatalog.all[p]
                                Button(cat.displayName) { addPreset(cat) }
                            }
                        }
                        .frame(width: 110)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func serverRow(_ i: Int) -> some View {
        let s = servers[i]
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { i < servers.count ? servers[i].enabled : false },
                set: { newVal in if i < servers.count { servers[i].enabled = newVal } }))
                .labelsHidden()
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? "(unnamed)" : s.name)
                    .font(.system(size: 12, weight: .medium))
                Text(([s.command] + s.args).joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                beginEdit(i)
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button {
                if i < servers.count { servers.remove(at: i) }
                if editingIndex == i { editingIndex = nil }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: Add / edit form

    @ViewBuilder
    private func editForm(editingExisting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(editingExisting ? "Edit server" : "Add server")
                .font(.system(size: 12, weight: .semibold))
            TextField("Name (e.g. Gmail)", text: $draftName)
                .textFieldStyle(.roundedBorder)
            TextField("Command (e.g. npx)", text: $draftCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Args (space-separated)", text: $draftArgs)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text("Tip: many servers need a token or path supplied via the command "
                + "args or the process environment — check the server's docs.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { editingIndex = nil }
                Button(editingExisting ? "Update" : "Add") { commitDraft() }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty
                        || draftCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: Actions

    private func beginAdd() {
        draftName = ""; draftCommand = ""; draftArgs = ""
        editingIndex = servers.count    // sentinel: "new"
    }

    private func beginEdit(_ i: Int) {
        guard i < servers.count else { return }
        let s = servers[i]
        draftName = s.name
        draftCommand = s.command
        draftArgs = s.args.joined(separator: " ")
        editingIndex = i
    }

    private func addPreset(_ cat: IntegrationCatalog) {
        // Don't duplicate an existing server of the same name.
        if !servers.contains(where: { $0.name == cat.id }) {
            servers.append(cat.preset)
        }
        // Open it for editing so the user can fill in any token/path immediately.
        if let idx = servers.firstIndex(where: { $0.name == cat.id }) {
            beginEdit(idx)
        }
    }

    private func commitDraft() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return }
        let args = draftArgs
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        let cfg = MCPServerConfig(name: name, command: command, args: args, enabled: true)
        if let idx = editingIndex, idx < servers.count {
            // Preserve the existing enabled state on edit.
            var updated = cfg
            updated.enabled = servers[idx].enabled
            servers[idx] = updated
        } else {
            servers.append(cfg)
        }
        editingIndex = nil
    }
}

// MARK: - Shortcut Recorder View

struct ShortcutRecorderView: View {
    let onCapture: (String?) -> Void
    let onCancel: () -> Void

    @State private var isRecording = true

    var body: some View {
        HStack(spacing: 4) {
            if isRecording {
                Text("Press key...")
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor)
            }
            Button(action: {
                onCapture(nil)  // Clear shortcut
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15))
        .cornerRadius(4)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {  // Escape
                    onCancel()
                    return nil
                }

                // Handle Space key
                if event.keyCode == 49 {
                    onCapture("Space")
                    return nil
                }

                // Handle backtick/grave key
                if event.keyCode == 50 {
                    onCapture("`")
                    return nil
                }

                // Get the key character (letters and numbers)
                if let chars = event.charactersIgnoringModifiers?.uppercased(),
                   chars.count == 1,
                   let char = chars.first,
                   char.isLetter || char.isNumber {
                    onCapture(String(char))
                    return nil
                }
                return event
            }
        }
    }
}

// MARK: - Action Editor Sheet

struct ActionEditorSheet: View {
    let action: Action?
    let onSave: (Action) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var selectedIcon: String = "star.fill"
    @State private var selectedActionType: ActionType = .llm

    private let availableIcons = [
        "star.fill", "heart.fill", "bolt.fill", "globe", "flag.fill",
        "bookmark.fill", "tag.fill", "paperplane.fill", "doc.text.fill",
        "pencil", "highlighter", "text.bubble.fill", "quote.bubble.fill",
        "character.book.closed.fill", "text.magnifyingglass",
        "wand.and.stars", "sparkles", "lightbulb.fill", "brain.head.profile",
        "checkmark.circle.fill", "pencil.circle.fill", "arrowshape.turn.up.left.fill",
        "arrow.right.circle.fill", "speaker.wave.2.fill"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(action == nil ? "New Action" : "Edit Action")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let action = action, action.isDefault {
                    Button("Reset to Default") {
                        ActionManager.shared.resetToDefault(action.id)
                        if let defaultAction = ActionManager.shared.actions.first(where: { $0.id == action.id }) {
                            name = defaultAction.name
                            prompt = defaultAction.prompt
                            selectedIcon = defaultAction.icon
                            selectedActionType = defaultAction.actionType
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("e.g., Translate to Hebrew", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Icon picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Icon")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 9), spacing: 6) {
                            ForEach(availableIcons, id: \.self) { icon in
                                Button(action: { selectedIcon = icon }) {
                                    Image(systemName: icon)
                                        .font(.system(size: 13))
                                        .frame(width: 26, height: 26)
                                        .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                                        .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(selectedIcon == icon ? .accentColor : .primary)
                            }
                        }
                    }

                    // Action type picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Action Type")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Picker("", selection: $selectedActionType) {
                            // `.agent` is a built-in type ("Ask Agent"), not a
                            // user-creatable custom action — hide it from the picker.
                            ForEach(ActionType.allCases.filter { $0 != .agent }, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Contextual fields based on action type
                    VStack(alignment: .leading, spacing: 6) {
                        switch selectedActionType {
                        case .llm:
                            Text("Prompt Instructions")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextEditor(text: $prompt)
                                .font(.system(size: 12))
                                .frame(minHeight: 80, maxHeight: 120)
                                .padding(4)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            Text("The selected text will be sent to the LLM with these instructions.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        case .tts:
                            Text("Text-to-Speech")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Selected text will be read aloud using the configured TTS voice.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                        case .command:
                            Text("Shell Command")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextEditor(text: $prompt)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 80, maxHeight: 120)
                                .padding(4)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            Text("Use {text} as placeholder for selected text, or it will be piped via stdin.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        case .agent:
                            // Built-in "Ask Agent" type; not user-editable here,
                            // but the switch must stay exhaustive.
                            Text("Agent")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Runs the tool-calling agent on the selected text.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    var newAction: Action
                    if let existing = action {
                        newAction = existing
                        newAction.name = name
                        newAction.icon = selectedIcon
                        newAction.prompt = prompt
                        newAction.actionType = selectedActionType
                    } else {
                        newAction = Action(
                            id: "user_\(UUID().uuidString)",
                            name: name,
                            icon: selectedIcon,
                            prompt: prompt,
                            actionType: selectedActionType
                        )
                    }
                    onSave(newAction)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || (selectedActionType == .llm && prompt.isEmpty) || (selectedActionType == .command && prompt.isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380, height: 520)
        .onAppear {
            if let action = action {
                name = action.name
                prompt = action.prompt
                selectedIcon = action.icon
                selectedActionType = action.actionType
            }
        }
    }
}


class SettingsWindowController: NSWindowController {
    private var hostingView: NSHostingView<SettingsView>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PopDraft Settings"
        window.isMovableByWindowBackground = true
        // Transparent so the SwiftUI Liquid-Glass settings surface shows through.
        GlassWindow.makeTransparent(window)
        window.center()

        super.init(window: window)

        let view = SettingsView(
            onSave: { [weak self] config in
                self?.saveConfig(config)
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
            onSave: { [weak self] config in
                self?.saveConfig(config)
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

    private func saveConfig(_ config: LLMConfig) {
        config.save()

        // Reload config in LLMClient
        LLMClient.shared.reloadConfig()

        // Reload hotkeys to apply any shortcut changes
        HotkeyManager.shared.reloadHotkeys()

        // PR4: re-apply corner-bubble settings (enabled + chosen corner).
        (NSApp.delegate as? AppDelegate)?.refreshBubble()

        // Show notification
        let script = """
        display notification "Settings saved - Provider: \(config.provider.displayName)" with title "PopDraft"
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}
