// test-legacy-actions.swift — old actions files after text-to-speech was removed.
//
// Co-compiled with scripts/Core.swift + scripts/Models.swift +
// scripts/ActionManager.swift — the REAL decoding + ActionManager, pointed at
// temp files (never ~/.popdraft/actions.json). Existing users' files contain the
// retired "Read aloud" action as `"actionType": "tts"` (v3) or `"isTTS": true`
// (v2). Asserts:
//   - such files still load (no reset-to-defaults, custom actions kept),
//   - the TTS entries are dropped (not in the menu, no Ctrl+Option+S hotkey),
//   - the cleaned file is written back without them,
//   - a genuinely unknown actionType still fails decoding (no silent data loss),
//   - fresh installs no longer seed a "Read aloud" action.

import Foundation

// ----------------------------------------------------------------------------
// Tiny test harness
// ----------------------------------------------------------------------------

var testsRun = 0
var testsFailed = 0

func check(_ condition: Bool, _ message: String) {
    testsRun += 1
    if !condition {
        testsFailed += 1
        print("  [FAIL] \(message)")
    } else {
        print("  [ok]   \(message)")
    }
}

func section(_ name: String) {
    print("")
    print("— \(name)")
}

let tmpDir = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("popdraft-legacy-actions-\(getpid())")
try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: tmpDir) }

func writeFile(_ json: String, _ name: String) -> String {
    let path = (tmpDir as NSString).appendingPathComponent(name)
    try! json.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

func fileText(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

// ----------------------------------------------------------------------------
// v3 file with "actionType": "tts"
// ----------------------------------------------------------------------------

section("v3 actions file with a \"tts\" Read aloud action")

let v3 = """
{
  "version": 3,
  "customPromptShortcut": "P",
  "customPromptEnabled": true,
  "actions": [
    {"id": "ask_agent", "name": "Ask Agent", "icon": "sparkles", "prompt": "p",
     "actionType": "agent", "isEnabled": true, "order": 0, "isDefault": true},
    {"id": "fix_grammar_and_spelling", "name": "Fix grammar", "icon": "checkmark.circle.fill", "prompt": "fix",
     "shortcut": "G", "actionType": "llm", "isEnabled": true, "order": 1, "isDefault": true},
    {"id": "read_aloud", "name": "Read aloud", "icon": "speaker.wave.2.fill", "prompt": "",
     "shortcut": "S", "actionType": "tts", "isEnabled": true, "order": 2, "isDefault": true},
    {"id": "custom_1", "name": "My jq", "icon": "star.fill", "prompt": "jq .",
     "shortcut": "J", "actionType": "command", "isEnabled": true, "order": 3, "isDefault": false},
    {"id": "custom_2", "name": "Summarize", "icon": "star.fill", "prompt": "Summarize",
     "actionType": "llm", "isEnabled": false, "order": 4, "isDefault": false}
  ]
}
"""
let p1 = writeFile(v3, "v3.json")
let m1 = ActionManager(actionsFilePath: p1)
let ids1 = m1.actions.map(\.id)

check(ids1 == ["ask_agent", "fix_grammar_and_spelling", "custom_1", "custom_2"],
      "file loads; only read_aloud dropped, got \(ids1)")
check(m1.actions.first { $0.id == "custom_1" }?.actionType == .command, "custom command action kept intact")
check(m1.actions.first { $0.id == "custom_2" }?.isEnabled == false, "disabled custom action kept intact")
check(m1.customPromptShortcut == "P", "file-level fields kept")
check(!m1.visibleActions.contains { $0.id == "read_aloud" }, "Read aloud not in the popup menu")
check(!m1.visibleActions.contains { $0.shortcut == "S" }, "no Ctrl+Option+S shortcut left to register")

let rewritten = fileText(p1)
check(!rewritten.contains("read_aloud") && !rewritten.contains("\"tts\""), "file re-saved without the TTS action")
check(rewritten.contains("custom_1") && rewritten.contains("custom_2"), "re-saved file keeps custom actions")

let m1b = ActionManager(actionsFilePath: p1)
check(m1b.actions.map(\.id) == ids1, "reload of the cleaned file is stable")

// ----------------------------------------------------------------------------
// v2 file with the legacy isTTS field
// ----------------------------------------------------------------------------

section("v2 actions file with legacy isTTS")

let v2 = """
{
  "version": 2,
  "customPromptShortcut": "P",
  "actions": [
    {"id": "fix_grammar_and_spelling", "name": "Fix grammar", "icon": "checkmark.circle.fill", "prompt": "fix",
     "shortcut": "G", "isTTS": false, "isEnabled": true, "order": 0, "isDefault": true},
    {"id": "read_aloud", "name": "Read aloud", "icon": "speaker.wave.2.fill", "prompt": "",
     "shortcut": "S", "isTTS": true, "isEnabled": true, "order": 1, "isDefault": true},
    {"id": "custom_legacy", "name": "Old custom", "icon": "star.fill", "prompt": "Do it",
     "isEnabled": true, "order": 2, "isDefault": false}
  ]
}
"""
let p2 = writeFile(v2, "v2.json")
let m2 = ActionManager(actionsFilePath: p2)
let ids2 = m2.actions.map(\.id)
check(!ids2.contains("read_aloud"), "isTTS:true action dropped")
check(ids2.contains("fix_grammar_and_spelling") && ids2.contains("custom_legacy"), "other v2 actions kept, got \(ids2)")
check(m2.actions.first { $0.id == "fix_grammar_and_spelling" }?.actionType == .llm, "isTTS:false maps to LLM")
check(m2.actions.first { $0.id == "custom_legacy" }?.actionType == .llm, "no type field defaults to LLM")
check(ids2.contains("ask_agent"), "Ask Agent still auto-added for older files")
check(!fileText(p2).contains("isTTS"), "legacy isTTS field not written back")

// ----------------------------------------------------------------------------
// Decoding-level guarantees
// ----------------------------------------------------------------------------

section("Decoding")

let onlyTTS = """
{"version": 3, "actions": [
  {"id": "read_aloud", "name": "Read aloud", "icon": "i", "prompt": "", "actionType": "tts",
   "isEnabled": true, "order": 0, "isDefault": true}]}
"""
let decoded = try? JSONDecoder().decode(ActionsFile.self, from: Data(onlyTTS.utf8))
check(decoded != nil, "a file of only TTS actions still decodes")
check(decoded?.actions.isEmpty == true && decoded?.droppedRetiredActions == 1, "…to zero actions, 1 dropped")

let unknownType = """
{"version": 3, "actions": [
  {"id": "x", "name": "X", "icon": "i", "prompt": "p", "actionType": "hologram",
   "isEnabled": true, "order": 0, "isDefault": false}]}
"""
check((try? JSONDecoder().decode(ActionsFile.self, from: Data(unknownType.utf8))) == nil,
      "an unknown (non-retired) actionType still fails decoding, as before")

let clean = try? JSONDecoder().decode(ActionsFile.self, from: Data(fileText(p1).utf8))
check(clean?.droppedRetiredActions == 0, "a clean file reports nothing dropped (no needless re-save)")

// ----------------------------------------------------------------------------
// Fresh install
// ----------------------------------------------------------------------------

section("Fresh install defaults")

let p3 = (tmpDir as NSString).appendingPathComponent("fresh.json")
let m3 = ActionManager(actionsFilePath: p3)
check(!m3.actions.contains { $0.id == "read_aloud" }, "no Read aloud default")
check(!m3.actions.contains { $0.shortcut == "S" }, "no S shortcut among defaults")
check(!ActionType.allCases.map(\.rawValue).contains("tts"), "ActionType has no tts case")
check(m3.actions.first?.id == "ask_agent", "Ask Agent is the first default")

// ----------------------------------------------------------------------------

print("")
print("\(testsRun) checks, \(testsFailed) failed")
if testsFailed > 0 { exit(1) }
print("ALL LEGACY-ACTIONS TESTS PASSED")
