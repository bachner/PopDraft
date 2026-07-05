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

// MARK: - Action Manager

class ActionManager {
    static let shared = ActionManager()

    var actions: [Action] = []
    var customPromptShortcut: String? = "P"
    var customPromptEnabled: Bool = true

    private let actionsFilePath: String

    static let defaultActions: [Action] = [
        Action(id: "ask_agent", name: "Ask Agent", icon: "sparkles",
               prompt: "Answer the user's request using the selected text as context. Use tools (web search/read, text tools) when helpful.",
               actionType: .agent, isEnabled: true, order: 0, isDefault: true),
        Action(id: "fix_grammar_and_spelling", name: "Fix grammar and spelling", icon: "checkmark.circle.fill",
               prompt: "Fix any grammar, spelling, and punctuation errors in this text. Keep the same tone and meaning. Only output the corrected text, nothing else. Preserve the original language.",
               shortcut: "G", isEnabled: true, order: 1, isDefault: true),
        Action(id: "articulate", name: "Articulate", icon: "pencil.circle.fill",
               prompt: "Improve this text to be clearer and more professional while keeping the same meaning and tone. Only output the improved text, nothing else. Preserve the original language.",
               shortcut: "A", isEnabled: true, order: 2, isDefault: true),
        Action(id: "explain_simply", name: "Explain simply", icon: "lightbulb.fill",
               prompt: "Explain this text in simple terms that anyone can understand. Only output the explanation, nothing else. Preserve the original language.",
               isEnabled: true, order: 3, isDefault: true),
        Action(id: "craft_a_reply", name: "Craft a reply", icon: "arrowshape.turn.up.left.fill",
               prompt: "Write a thoughtful and helpful reply to this message. Be professional and friendly. Only output the reply, nothing else. Preserve the original language.",
               shortcut: "C", isEnabled: true, order: 4, isDefault: true),
        Action(id: "continue_writing", name: "Continue writing", icon: "arrow.right.circle.fill",
               prompt: "Continue writing from where this text ends, matching the style and tone. Only output the continuation, nothing else. Preserve the original language.",
               isEnabled: true, order: 5, isDefault: true),
        Action(id: "read_aloud", name: "Read aloud", icon: "speaker.wave.2.fill",
               prompt: "", shortcut: "S", actionType: .tts, isEnabled: true, order: 6, isDefault: true),
    ]

    init() {
        actionsFilePath = NSString(string: "~/.popdraft/actions.json").expandingTildeInPath
        load()
    }

    // For testing: init with a custom path
    init(actionsFilePath: String) {
        self.actionsFilePath = actionsFilePath
        load()
    }

    // Visible actions for popup: enabled actions sorted by order
    var visibleActions: [Action] {
        actions.filter { $0.isEnabled }.sorted { $0.order < $1.order }
    }

    // Actions for the popup menu. "Custom prompt…" was removed — "Ask Agent"
    // (the primary first row) opens a blank agent chat you can type anything into,
    // which fully replaces the old free-form custom-prompt row.
    var popupActions: [Action] {
        return visibleActions
    }

    func filteredActions(searchText: String) -> [Action] {
        let allActions = popupActions
        if searchText.isEmpty {
            return allActions
        }
        return allActions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - CRUD

    func add(_ action: Action) {
        var newAction = action
        newAction.order = (actions.map { $0.order }.max() ?? -1) + 1
        actions.append(newAction)
        save()
    }

    func update(_ action: Action) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
            save()
        }
    }

    func delete(_ actionId: String) {
        actions.sort { $0.order < $1.order }
        actions.removeAll { $0.id == actionId }
        recalculateOrder()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        actions.sort { $0.order < $1.order }
        actions.move(fromOffsets: source, toOffset: destination)
        recalculateOrder()
        save()
    }

    func toggleEnabled(_ actionId: String) {
        if let index = actions.firstIndex(where: { $0.id == actionId }) {
            actions[index].isEnabled.toggle()
            save()
        }
    }

    func resetToDefault(_ actionId: String) {
        guard let defaultAction = ActionManager.defaultActions.first(where: { $0.id == actionId }),
              let index = actions.firstIndex(where: { $0.id == actionId }) else { return }
        let currentOrder = actions[index].order
        let currentEnabled = actions[index].isEnabled
        actions[index] = defaultAction
        actions[index].order = currentOrder
        actions[index].isEnabled = currentEnabled
        save()
    }

    func restoreDefaults() {
        let existingIds = Set(actions.map { $0.id })
        var nextOrder = (actions.map { $0.order }.max() ?? -1) + 1
        for defaultAction in ActionManager.defaultActions {
            if !existingIds.contains(defaultAction.id) {
                var action = defaultAction
                action.order = nextOrder
                actions.append(action)
                nextOrder += 1
            }
        }
        save()
    }

    /// Check if a shortcut key is already in use by another action (or custom prompt)
    func isShortcutInUse(_ key: String, excludingActionId: String?) -> Bool {
        let upperKey = key.uppercased()
        for action in actions where action.id != excludingActionId {
            if let shortcut = action.shortcut, shortcut.uppercased() == upperKey {
                return true
            }
        }
        if excludingActionId != "custom_prompt",
           let cpShortcut = customPromptShortcut, cpShortcut.uppercased() == upperKey {
            return true
        }
        return false
    }

    // MARK: - Persistence

    func load() {
        guard let data = FileManager.default.contents(atPath: actionsFilePath) else {
            // No file exists — seed with defaults
            actions = ActionManager.defaultActions
            customPromptShortcut = "P"
            save()
            return
        }

        // Try v2/v3 format first
        if let actionsFile = try? JSONDecoder().decode(ActionsFile.self, from: data) {
            actions = actionsFile.actions
            customPromptShortcut = actionsFile.customPromptShortcut
            customPromptEnabled = actionsFile.customPromptEnabled ?? true
            ensureAskAgentPresent()
            return
        }

        // Try old format (bare array of LegacyCustomAction)
        if let legacyActions = try? JSONDecoder().decode([LegacyCustomAction].self, from: data) {
            migrateFromLegacy(legacyActions)
            return
        }

        // Unreadable — seed defaults
        actions = ActionManager.defaultActions
        customPromptShortcut = "P"
        save()
    }

    /// Ensure the built-in "Ask Agent" action exists. Saved action files written
    /// before "Ask Agent" became a default won't contain it, so it never appeared
    /// in the menu for existing users. Insert it at the front (order 0), the
    /// visually-primary row, and bump every other action down by one.
    private func ensureAskAgentPresent() {
        guard !actions.contains(where: { $0.id == "ask_agent" }) else { return }
        guard let askAgent = ActionManager.defaultActions.first(where: { $0.id == "ask_agent" }) else { return }
        for i in actions.indices { actions[i].order += 1 }
        var a = askAgent
        a.order = 0
        a.isEnabled = true
        actions.insert(a, at: 0)
        save()
    }

    func save() {
        let dir = NSString(string: "~/.popdraft").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let file = ActionsFile(version: 3, actions: actions, customPromptShortcut: customPromptShortcut, customPromptEnabled: customPromptEnabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(file) {
            try? data.write(to: URL(fileURLWithPath: actionsFilePath))
        }
    }

    private func migrateFromLegacy(_ legacyActions: [LegacyCustomAction]) {
        // Start with defaults
        actions = ActionManager.defaultActions

        // Apply disabled actions and custom shortcuts from old config
        let config = LLMConfig.load()
        let disabledIds = Set(config.disabledBuiltInActions)
        for i in 0..<actions.count {
            if disabledIds.contains(actions[i].id) {
                actions[i].isEnabled = false
            }
            if let customShortcut = config.customShortcuts[actions[i].id] {
                actions[i].shortcut = customShortcut
            }
        }

        // Custom prompt shortcut from old config
        customPromptShortcut = config.customShortcuts["custom_prompt..."] ?? "P"

        // Append legacy custom actions
        var nextOrder = actions.count
        for legacy in legacyActions {
            let action = Action(
                id: "custom_\(legacy.id.uuidString)",
                name: legacy.name,
                icon: legacy.icon,
                prompt: legacy.prompt,
                shortcut: config.customShortcuts["custom_\(legacy.id.uuidString)"],
                isEnabled: true,
                order: nextOrder,
                isDefault: false
            )
            actions.append(action)
            nextOrder += 1
        }

        save()
    }

    private func recalculateOrder() {
        for i in 0..<actions.count {
            actions[i].order = i
        }
    }
}
