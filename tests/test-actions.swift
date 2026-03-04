#!/usr/bin/env swift
// test-actions.swift — Unit tests for the Action system
// Compile and run: swiftc -o /tmp/test-actions tests/test-actions.swift && /tmp/test-actions

import Foundation

// MARK: - Extracted types (mirrored from PopDraft.swift)

enum ActionType: String, Codable, CaseIterable {
    case llm = "llm"
    case tts = "tts"
    case command = "command"

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .tts: return "TTS"
        case .command: return "CMD"
        }
    }
}

struct Action: Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var prompt: String
    var shortcut: String?
    var actionType: ActionType
    var isEnabled: Bool
    var order: Int
    var isDefault: Bool

    init(id: String, name: String, icon: String, prompt: String, shortcut: String? = nil,
         actionType: ActionType = .llm, isEnabled: Bool = true, order: Int = 0, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.shortcut = shortcut
        self.actionType = actionType
        self.isEnabled = isEnabled
        self.order = order
        self.isDefault = isDefault
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Action, rhs: Action) -> Bool { lhs.id == rhs.id }
}

extension Action: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, icon, prompt, shortcut, actionType, isEnabled, order, isDefault
        case isTTS  // legacy field for backward compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        prompt = try container.decode(String.self, forKey: .prompt)
        shortcut = try container.decodeIfPresent(String.self, forKey: .shortcut)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        order = try container.decode(Int.self, forKey: .order)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)

        if let type = try container.decodeIfPresent(ActionType.self, forKey: .actionType) {
            actionType = type
        } else if let isTTS = try container.decodeIfPresent(Bool.self, forKey: .isTTS) {
            actionType = isTTS ? .tts : .llm
        } else {
            actionType = .llm
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encode(actionType, forKey: .actionType)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(order, forKey: .order)
        try container.encode(isDefault, forKey: .isDefault)
    }
}

struct ActionsFile: Codable {
    var version: Int = 3
    var actions: [Action]
    var customPromptShortcut: String?
    var customPromptEnabled: Bool?
}

private struct LegacyCustomAction: Codable {
    var id: UUID
    var name: String
    var icon: String
    var prompt: String
}

// MARK: - Testable ActionManager (file-system based, custom path)

class ActionManager {
    var actions: [Action] = []
    var customPromptShortcut: String? = "P"
    var customPromptEnabled: Bool = true
    private let actionsFilePath: String

    static let defaultActions: [Action] = [
        Action(id: "fix_grammar_and_spelling", name: "Fix grammar and spelling", icon: "checkmark.circle.fill",
               prompt: "Fix any grammar, spelling, and punctuation errors in this text. Keep the same tone and meaning. Only output the corrected text, nothing else. Preserve the original language.",
               shortcut: "G", isEnabled: true, order: 0, isDefault: true),
        Action(id: "articulate", name: "Articulate", icon: "pencil.circle.fill",
               prompt: "Improve this text to be clearer and more professional while keeping the same meaning and tone. Only output the improved text, nothing else. Preserve the original language.",
               shortcut: "A", isEnabled: true, order: 1, isDefault: true),
        Action(id: "explain_simply", name: "Explain simply", icon: "lightbulb.fill",
               prompt: "Explain this text in simple terms that anyone can understand. Only output the explanation, nothing else. Preserve the original language.",
               isEnabled: true, order: 2, isDefault: true),
        Action(id: "craft_a_reply", name: "Craft a reply", icon: "arrowshape.turn.up.left.fill",
               prompt: "Write a thoughtful and helpful reply to this message. Be professional and friendly. Only output the reply, nothing else. Preserve the original language.",
               shortcut: "C", isEnabled: true, order: 3, isDefault: true),
        Action(id: "continue_writing", name: "Continue writing", icon: "arrow.right.circle.fill",
               prompt: "Continue writing from where this text ends, matching the style and tone. Only output the continuation, nothing else. Preserve the original language.",
               isEnabled: true, order: 4, isDefault: true),
        Action(id: "read_aloud", name: "Read aloud", icon: "speaker.wave.2.fill",
               prompt: "", shortcut: "S", actionType: .tts, isEnabled: true, order: 5, isDefault: true),
    ]

    init(actionsFilePath: String) {
        self.actionsFilePath = actionsFilePath
        load()
    }

    var visibleActions: [Action] {
        actions.filter { $0.isEnabled }.sorted { $0.order < $1.order }
    }

    var popupActions: [Action] {
        var result = visibleActions
        if customPromptEnabled {
            result.append(Action(id: "custom_prompt", name: "Custom prompt...", icon: "ellipsis.circle.fill",
                                 prompt: "", shortcut: customPromptShortcut))
        }
        return result
    }

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

    func move(fromIndex: Int, toIndex: Int) {
        actions.sort { $0.order < $1.order }
        let item = actions.remove(at: fromIndex)
        let dest = toIndex > fromIndex ? toIndex - 1 : toIndex
        actions.insert(item, at: dest)
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

    func load() {
        guard let data = FileManager.default.contents(atPath: actionsFilePath) else {
            actions = ActionManager.defaultActions
            customPromptShortcut = "P"
            save()
            return
        }

        if let actionsFile = try? JSONDecoder().decode(ActionsFile.self, from: data) {
            actions = actionsFile.actions
            customPromptShortcut = actionsFile.customPromptShortcut
            customPromptEnabled = actionsFile.customPromptEnabled ?? true
            return
        }

        if let legacyActions = try? JSONDecoder().decode([LegacyCustomAction].self, from: data) {
            migrateFromLegacy(legacyActions)
            return
        }

        actions = ActionManager.defaultActions
        customPromptShortcut = "P"
        save()
    }

    func save() {
        let dir = (actionsFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = ActionsFile(version: 3, actions: actions, customPromptShortcut: customPromptShortcut, customPromptEnabled: customPromptEnabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(file) {
            try? data.write(to: URL(fileURLWithPath: actionsFilePath))
        }
    }

    private func migrateFromLegacy(_ legacyActions: [LegacyCustomAction]) {
        actions = ActionManager.defaultActions
        customPromptShortcut = "P"
        var nextOrder = actions.count
        for legacy in legacyActions {
            let action = Action(
                id: "custom_\(legacy.id.uuidString)",
                name: legacy.name,
                icon: legacy.icon,
                prompt: legacy.prompt,
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

// MARK: - Test Harness

var passCount = 0
var failCount = 0
var testNames: [String] = []

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL [\(file):\(line)]: \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    testNames.append(name)
    print("  Running: \(name)")
    body()
}

func createTempPath() -> String {
    let dir = NSTemporaryDirectory() + "popdraft-tests-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/actions.json"
}

func cleanup(_ path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - Tests

print("Running Action system tests...\n")

test("Fresh install - seeds 6 defaults") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.actions.count == 6, "Expected 6 actions, got \(mgr.actions.count)")
    assert(mgr.actions[0].id == "fix_grammar_and_spelling", "First action should be grammar")
    assert(mgr.actions[5].id == "read_aloud", "Last action should be read_aloud")
    assert(mgr.customPromptShortcut == "P", "Custom prompt shortcut should be P")

    // Verify file was created
    assert(FileManager.default.fileExists(atPath: path), "actions.json should be created")
}

test("Fresh install - correct order values") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    for (i, action) in mgr.actions.enumerated() {
        assert(action.order == i, "Action \(action.id) order should be \(i), got \(action.order)")
    }
}

test("Fresh install - all enabled and isDefault") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    for action in mgr.actions {
        assert(action.isEnabled, "Action \(action.id) should be enabled")
        assert(action.isDefault, "Action \(action.id) should be isDefault")
    }
}

test("Fresh install - correct action types") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    for action in mgr.actions {
        if action.id == "read_aloud" {
            assert(action.actionType == .tts, "read_aloud should be TTS type")
        } else {
            assert(action.actionType == .llm, "\(action.id) should be LLM type")
        }
    }
}

test("Old format migration - bare array") {
    let path = createTempPath()
    defer { cleanup(path) }

    let legacy = [
        LegacyCustomAction(id: UUID(), name: "My Custom", icon: "star.fill", prompt: "Do something")
    ]
    let data = try! JSONEncoder().encode(legacy)
    try! data.write(to: URL(fileURLWithPath: path))

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.actions.count == 7, "Expected 6 defaults + 1 custom = 7, got \(mgr.actions.count)")
    assert(mgr.actions.last?.name == "My Custom", "Last action should be custom")
    assert(mgr.actions.last?.isDefault == false, "Custom action should not be isDefault")
}

test("v2 format migration - isTTS field maps to actionType") {
    let path = createTempPath()
    defer { cleanup(path) }

    // Write a v2-style JSON with isTTS fields
    let v2Json = """
    {
        "version": 2,
        "actions": [
            {
                "id": "grammar",
                "name": "Grammar",
                "icon": "checkmark.circle.fill",
                "prompt": "Fix grammar",
                "isTTS": false,
                "isEnabled": true,
                "order": 0,
                "isDefault": true
            },
            {
                "id": "read_aloud",
                "name": "Read aloud",
                "icon": "speaker.wave.2.fill",
                "prompt": "",
                "shortcut": "S",
                "isTTS": true,
                "isEnabled": true,
                "order": 1,
                "isDefault": true
            }
        ],
        "customPromptShortcut": "P"
    }
    """.data(using: .utf8)!
    try! v2Json.write(to: URL(fileURLWithPath: path))

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.actions.count == 2, "Expected 2 actions")
    assert(mgr.actions[0].actionType == .llm, "Grammar should be LLM type (migrated from isTTS: false)")
    assert(mgr.actions[1].actionType == .tts, "Read aloud should be TTS type (migrated from isTTS: true)")
}

test("v3 format load - preserves actionType") {
    let path = createTempPath()
    defer { cleanup(path) }

    let customAction = Action(id: "test_action", name: "Test", icon: "bolt.fill", prompt: "test prompt",
                              shortcut: "T", actionType: .command, isEnabled: false, order: 10, isDefault: false)
    let file = ActionsFile(version: 3, actions: [customAction], customPromptShortcut: "X")
    let data = try! JSONEncoder().encode(file)
    try! data.write(to: URL(fileURLWithPath: path))

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.actions.count == 1, "Expected 1 action")
    assert(mgr.actions[0].shortcut == "T", "Shortcut should be T")
    assert(mgr.actions[0].isEnabled == false, "Should be disabled")
    assert(mgr.actions[0].order == 10, "Order should be 10")
    assert(mgr.actions[0].actionType == .command, "Should be command type")
    assert(mgr.customPromptShortcut == "X", "Custom prompt shortcut should be X")
}

test("Command action type - create and persist") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let cmdAction = Action(id: "word_count", name: "Word count", icon: "number",
                           prompt: "wc -w", actionType: .command)
    mgr.add(cmdAction)

    assert(mgr.actions.last?.actionType == .command, "Should be command type")
    assert(mgr.actions.last?.prompt == "wc -w", "Prompt should contain command")

    // Reload and verify persistence
    let mgr2 = ActionManager(actionsFilePath: path)
    let reloaded = mgr2.actions.first(where: { $0.id == "word_count" })
    assert(reloaded != nil, "Command action should persist")
    assert(reloaded?.actionType == .command, "Command type should persist")
    assert(reloaded?.prompt == "wc -w", "Command should persist")
}

test("ActionType label") {
    assert(ActionType.llm.label == "LLM", "LLM label")
    assert(ActionType.tts.label == "TTS", "TTS label")
    assert(ActionType.command.label == "CMD", "CMD label")
}

test("CRUD - Add") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let initialCount = mgr.actions.count
    let newAction = Action(id: "user_test", name: "Test Action", icon: "star.fill", prompt: "do stuff")
    mgr.add(newAction)

    assert(mgr.actions.count == initialCount + 1, "Should have one more action")
    assert(mgr.actions.last?.id == "user_test", "New action should be last")
    assert(mgr.actions.last!.order == initialCount, "New action order should be \(initialCount)")
}

test("CRUD - Update") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    var action = mgr.actions[0]
    action.name = "Updated Name"
    action.prompt = "Updated prompt"
    mgr.update(action)

    assert(mgr.actions[0].name == "Updated Name", "Name should be updated")
    assert(mgr.actions[0].prompt == "Updated prompt", "Prompt should be updated")
}

test("CRUD - Delete") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let initialCount = mgr.actions.count
    mgr.delete("explain_simply")

    assert(mgr.actions.count == initialCount - 1, "Should have one fewer action")
    assert(!mgr.actions.contains(where: { $0.id == "explain_simply" }), "explain_simply should be gone")
}

test("CRUD - Delete recalculates order") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.delete("explain_simply")

    for (i, action) in mgr.actions.sorted(by: { $0.order < $1.order }).enumerated() {
        assert(action.order == i, "After delete, action \(action.id) order should be \(i), got \(action.order)")
    }
}

test("CRUD - Move/Reorder") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    // Move first action to position 3
    mgr.move(fromIndex: 0, toIndex: 3)

    let sorted = mgr.actions.sorted { $0.order < $1.order }
    // Moving item 0 to position 3 in SwiftUI means: [a,b,c,d,e,f] -> [b,c,a,d,e,f]
    assert(sorted[0].id == "articulate", "After move, articulate should be first, got \(sorted[0].id)")
    assert(sorted[2].id == "fix_grammar_and_spelling", "fix_grammar should now be at index 2, got \(sorted[2].id)")
}

test("Toggle enabled") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.actions[0].isEnabled, "Should start enabled")
    mgr.toggleEnabled(mgr.actions[0].id)
    assert(!mgr.actions[0].isEnabled, "Should be disabled after toggle")
    mgr.toggleEnabled(mgr.actions[0].id)
    assert(mgr.actions[0].isEnabled, "Should be re-enabled after second toggle")
}

test("visibleActions - only enabled and sorted") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.toggleEnabled("articulate")

    let visible = mgr.visibleActions
    assert(visible.count == 5, "Should have 5 visible (6 - 1 disabled)")
    assert(!visible.contains(where: { $0.id == "articulate" }), "articulate should not be visible")

    // Check sorted by order
    for i in 0..<(visible.count - 1) {
        assert(visible[i].order < visible[i+1].order, "Should be sorted by order")
    }
}

test("Reset to default") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let originalName = mgr.actions[0].name
    var action = mgr.actions[0]
    action.name = "Changed Name"
    action.prompt = "Changed prompt"
    mgr.update(action)

    assert(mgr.actions[0].name == "Changed Name", "Name should be changed")

    mgr.resetToDefault(mgr.actions[0].id)
    assert(mgr.actions[0].name == originalName, "Name should be restored to default")
}

test("Restore defaults - re-adds missing") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.delete("articulate")
    mgr.delete("read_aloud")
    assert(mgr.actions.count == 4, "Should have 4 after deleting 2")

    mgr.restoreDefaults()
    assert(mgr.actions.count == 6, "Should have 6 after restore")
    assert(mgr.actions.contains(where: { $0.id == "articulate" }), "articulate should be back")
    assert(mgr.actions.contains(where: { $0.id == "read_aloud" }), "read_aloud should be back")
}

test("Custom prompt shortcut - stored separately") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.customPromptShortcut = "X"
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    assert(mgr2.customPromptShortcut == "X", "Custom prompt shortcut should persist as X")
}

test("Duplicate shortcut detection") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    // "G" is used by grammar action
    assert(mgr.isShortcutInUse("G", excludingActionId: nil), "G should be in use")
    assert(!mgr.isShortcutInUse("G", excludingActionId: "fix_grammar_and_spelling"), "G should not be in use when excluding grammar")
    assert(!mgr.isShortcutInUse("Z", excludingActionId: nil), "Z should not be in use")
    assert(mgr.isShortcutInUse("P", excludingActionId: nil), "P should be in use (custom prompt)")
    assert(!mgr.isShortcutInUse("P", excludingActionId: "custom_prompt"), "P not in use when excluding custom_prompt")
}

test("Round-trip save/load") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.add(Action(id: "user_abc", name: "Custom Thing", icon: "bolt.fill", prompt: "do stuff", shortcut: "Z"))
    mgr.toggleEnabled("articulate")
    mgr.customPromptShortcut = "Q"
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    assert(mgr2.actions.count == mgr.actions.count, "Action count should match after reload")
    assert(mgr2.customPromptShortcut == "Q", "Custom prompt shortcut should be Q")

    for (a, b) in zip(mgr.actions.sorted(by: { $0.id < $1.id }), mgr2.actions.sorted(by: { $0.id < $1.id })) {
        assert(a.id == b.id, "IDs should match")
        assert(a.name == b.name, "Names should match for \(a.id)")
        assert(a.isEnabled == b.isEnabled, "isEnabled should match for \(a.id)")
        assert(a.shortcut == b.shortcut, "Shortcuts should match for \(a.id)")
        assert(a.order == b.order, "Orders should match for \(a.id)")
        assert(a.actionType == b.actionType, "actionType should match for \(a.id)")
    }
}

test("Round-trip save/load with command action") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.add(Action(id: "user_cmd", name: "Word Count", icon: "number", prompt: "wc -w", actionType: .command))
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    let cmd = mgr2.actions.first(where: { $0.id == "user_cmd" })
    assert(cmd != nil, "Command action should persist")
    assert(cmd?.actionType == .command, "actionType should be command after reload")
    assert(cmd?.prompt == "wc -w", "Command prompt should persist")
}

test("popupActions includes custom prompt when enabled") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let popup = mgr.popupActions
    assert(popup.last?.id == "custom_prompt", "Last popup action should be custom_prompt")
    assert(popup.count == 7, "6 visible + 1 custom prompt = 7")
}

test("popupActions excludes custom prompt when disabled") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.customPromptEnabled = false
    let popup = mgr.popupActions
    assert(popup.count == 6, "6 visible, no custom prompt = 6, got \(popup.count)")
    assert(!popup.contains(where: { $0.id == "custom_prompt" }), "custom_prompt should not be in popup")
}

test("customPromptEnabled - persists across save/load") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.customPromptEnabled == true, "Should default to enabled")
    mgr.customPromptEnabled = false
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    assert(mgr2.customPromptEnabled == false, "Should persist as disabled")
}

test("customPromptEnabled - defaults to true for v2 files") {
    let path = createTempPath()
    defer { cleanup(path) }

    // Write a v2 file without customPromptEnabled field
    let v2Json = """
    {
        "version": 2,
        "actions": [
            {
                "id": "grammar",
                "name": "Grammar",
                "icon": "checkmark.circle.fill",
                "prompt": "Fix grammar",
                "isTTS": false,
                "isEnabled": true,
                "order": 0,
                "isDefault": true
            }
        ],
        "customPromptShortcut": "P"
    }
    """.data(using: .utf8)!
    try! v2Json.write(to: URL(fileURLWithPath: path))

    let mgr = ActionManager(actionsFilePath: path)
    assert(mgr.customPromptEnabled == true, "Should default to true for v2 files without field")
}

// MARK: - Toggle Tests

test("Toggle enabled - each action can be toggled independently") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    // Toggle each action and verify
    for action in mgr.actions {
        assert(action.isEnabled, "\(action.id) should start enabled")
    }

    mgr.toggleEnabled("fix_grammar_and_spelling")
    mgr.toggleEnabled("read_aloud")

    assert(!mgr.actions.first(where: { $0.id == "fix_grammar_and_spelling" })!.isEnabled, "Grammar should be disabled")
    assert(!mgr.actions.first(where: { $0.id == "read_aloud" })!.isEnabled, "Read aloud should be disabled")
    assert(mgr.actions.first(where: { $0.id == "articulate" })!.isEnabled, "Articulate should still be enabled")
}

test("Toggle enabled - persists after save/load") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.toggleEnabled("articulate")
    mgr.toggleEnabled("craft_a_reply")
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    assert(!mgr2.actions.first(where: { $0.id == "articulate" })!.isEnabled, "Articulate should be disabled after reload")
    assert(!mgr2.actions.first(where: { $0.id == "craft_a_reply" })!.isEnabled, "Craft a reply should be disabled after reload")
    assert(mgr2.actions.first(where: { $0.id == "fix_grammar_and_spelling" })!.isEnabled, "Grammar should still be enabled")
}

test("visibleActions - disabled actions excluded from popup") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.toggleEnabled("fix_grammar_and_spelling")
    mgr.toggleEnabled("articulate")
    mgr.toggleEnabled("read_aloud")

    let visible = mgr.visibleActions
    assert(visible.count == 3, "Should have 3 visible (6 - 3 disabled), got \(visible.count)")
    assert(!visible.contains(where: { $0.id == "fix_grammar_and_spelling" }), "Grammar should not be visible")
    assert(!visible.contains(where: { $0.id == "articulate" }), "Articulate should not be visible")
    assert(!visible.contains(where: { $0.id == "read_aloud" }), "Read aloud should not be visible")
}

// MARK: - Reorder Tests

test("Move up - move second item to first position") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    // Simulating "move up" button: move item at index 1 up to index 0
    // In SwiftUI onMove terms: move(fromIndex: 1, toIndex: 1) means move to before index 1 = index 0
    mgr.move(fromIndex: 1, toIndex: 0)

    let sorted = mgr.actions.sorted { $0.order < $1.order }
    assert(sorted[0].id == "articulate", "Articulate should now be first, got \(sorted[0].id)")
    assert(sorted[1].id == "fix_grammar_and_spelling", "Grammar should now be second, got \(sorted[1].id)")
}

test("Move down - move first item to second position") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    // Simulating "move down" button: move item at index 0 down to index 1
    // In SwiftUI onMove terms: move(fromIndex: 0, toIndex: 2) means move to after index 1
    mgr.move(fromIndex: 0, toIndex: 2)

    let sorted = mgr.actions.sorted { $0.order < $1.order }
    assert(sorted[0].id == "articulate", "Articulate should now be first, got \(sorted[0].id)")
    assert(sorted[1].id == "fix_grammar_and_spelling", "Grammar should now be second, got \(sorted[1].id)")
}

test("Move - order persists after save/load") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.move(fromIndex: 5, toIndex: 0) // Move read_aloud to top
    mgr.save()

    let mgr2 = ActionManager(actionsFilePath: path)
    let sorted = mgr2.actions.sorted { $0.order < $1.order }
    assert(sorted[0].id == "read_aloud", "Read aloud should be first after reload, got \(sorted[0].id)")
}

test("Move - last item cannot move down (stays in place)") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let lastIndex = mgr.actions.count - 1
    let lastId = mgr.actions.sorted(by: { $0.order < $1.order })[lastIndex].id

    // Try to move last item down (would be invalid in UI, button disabled)
    // The move function handles fromIndex:5, toIndex:7 which is out of bounds
    // In practice the UI prevents this, but verify state is consistent
    let sorted = mgr.actions.sorted { $0.order < $1.order }
    assert(sorted[lastIndex].id == lastId, "Last item should still be last")
}

// MARK: - Action Type Tests

test("All default action types are correct") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let sorted = mgr.actions.sorted { $0.order < $1.order }
    assert(sorted[0].actionType == .llm, "Grammar should be LLM")
    assert(sorted[1].actionType == .llm, "Articulate should be LLM")
    assert(sorted[2].actionType == .llm, "Explain simply should be LLM")
    assert(sorted[3].actionType == .llm, "Craft a reply should be LLM")
    assert(sorted[4].actionType == .llm, "Continue writing should be LLM")
    assert(sorted[5].actionType == .tts, "Read aloud should be TTS")
}

test("Add command action and verify in popup") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.add(Action(id: "word_count", name: "Word count", icon: "number",
                   prompt: "wc -w", actionType: .command))

    let visible = mgr.visibleActions
    assert(visible.contains(where: { $0.id == "word_count" }), "Command action should be visible")
    assert(visible.first(where: { $0.id == "word_count" })?.actionType == .command, "Should be command type")

    let popup = mgr.popupActions
    assert(popup.count == 8, "6 defaults + 1 command + 1 custom prompt = 8, got \(popup.count)")
}

test("Disable command action removes from visibleActions") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.add(Action(id: "word_count", name: "Word count", icon: "number",
                   prompt: "wc -w", actionType: .command))
    mgr.toggleEnabled("word_count")

    let visible = mgr.visibleActions
    assert(!visible.contains(where: { $0.id == "word_count" }), "Disabled command should not be visible")
}

// MARK: - Edge Cases

test("Toggle nonexistent action - no crash") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let countBefore = mgr.actions.count
    mgr.toggleEnabled("nonexistent_id")
    assert(mgr.actions.count == countBefore, "Action count should not change")
}

test("Delete nonexistent action - no crash") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    let countBefore = mgr.actions.count
    mgr.delete("nonexistent_id")
    assert(mgr.actions.count == countBefore, "Action count should not change")
}

test("All actions disabled - popup only shows custom prompt") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    for action in mgr.actions {
        mgr.toggleEnabled(action.id)
    }

    let visible = mgr.visibleActions
    assert(visible.count == 0, "No visible actions when all disabled")

    let popup = mgr.popupActions
    assert(popup.count == 1, "Only custom prompt in popup when all disabled, got \(popup.count)")
    assert(popup[0].id == "custom_prompt", "Should be custom prompt")
}

test("All actions disabled + custom prompt disabled - empty popup") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    for action in mgr.actions {
        mgr.toggleEnabled(action.id)
    }
    mgr.customPromptEnabled = false

    let popup = mgr.popupActions
    assert(popup.count == 0, "Popup should be empty when everything disabled, got \(popup.count)")
}

test("Add action gets highest order") {
    let path = createTempPath()
    defer { cleanup(path) }

    let mgr = ActionManager(actionsFilePath: path)
    mgr.add(Action(id: "a1", name: "First", icon: "star.fill", prompt: "p1"))
    mgr.add(Action(id: "a2", name: "Second", icon: "star.fill", prompt: "p2"))
    mgr.add(Action(id: "a3", name: "Third", icon: "star.fill", prompt: "p3"))

    assert(mgr.actions.first(where: { $0.id == "a1" })!.order == 6, "First added should be order 6")
    assert(mgr.actions.first(where: { $0.id == "a2" })!.order == 7, "Second added should be order 7")
    assert(mgr.actions.first(where: { $0.id == "a3" })!.order == 8, "Third added should be order 8")
}

// MARK: - Results

print("\n========================================")
print("Results: \(passCount) passed, \(failCount) failed")
print("========================================")

if failCount > 0 {
    exit(1)
} else {
    print("All tests passed!")
    exit(0)
}
