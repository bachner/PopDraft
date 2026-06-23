// test-config.swift — Unit tests for the AppConfig store (Core.swift).
// Compile and run WITH Core.swift:
//   swiftc -o /tmp/test-config tests/test-config.swift scripts/Core.swift && /tmp/test-config

import Foundation

// MARK: - Test Harness

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL [\(file):\(line)]: \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  Running: \(name)")
    body()
}

func createTempDir() -> String {
    let dir = NSTemporaryDirectory() + "popdraft-config-tests-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func cleanup(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

func write(_ text: String, to dir: String, named name: String) {
    let path = (dir as NSString).appendingPathComponent(name)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func exists(_ dir: String, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
}

// MARK: - Fixtures

// A complete legacy plaintext config exercising every key, including the
// embedded-JSON CUSTOM_SHORTCUTS hack and a URL value that contains '='.
let legacyPlaintext = """
# PopDraft legacy config
PROVIDER=claude
LLAMACPP_URL=http://localhost:9999/v1?token=abc=def
LLAMA_MODEL=qwen3.5-7b
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=llama3.2:8b
OPENAI_API_KEY=sk-openai-123
OPENAI_MODEL=gpt-4.1
CLAUDE_API_KEY=sk-ant-456
CLAUDE_MODEL=claude-opus-4-5-20251101
CLAUDE_EXTENDED_THINKING=true
CLAUDE_THINKING_BUDGET=20000
OLLAMA_ENABLE_THINKING=true
LLAMACPP_ENABLE_THINKING=true
TTS_VOICE=af_bella
TTS_SPEED=1.25
DISABLED_ACTIONS=articulate,read_aloud
CUSTOM_SHORTCUTS={"explain_simply":"E","craft_a_reply":"R"}
POPUP_HOTKEY=J
"""

// MARK: - Tests

print("Running AppConfig store tests...\n")

test("Legacy plaintext migration - every field maps correctly") {
    let c = AppConfig.migrateLegacyPlaintext(legacyPlaintext)
    assert(c.version == 2, "version should default to 2")
    assert(c.provider == "claude", "provider")
    assert(c.llamacppURL == "http://localhost:9999/v1?token=abc=def", "llamacppURL preserves '=' in value, got \(c.llamacppURL)")
    assert(c.llamaModel == "qwen3.5-7b", "llamaModel")
    assert(c.ollamaURL == "http://localhost:11434", "ollamaURL")
    assert(c.ollamaModel == "llama3.2:8b", "ollamaModel")
    assert(c.openaiAPIKey == "sk-openai-123", "openaiAPIKey")
    assert(c.openaiModel == "gpt-4.1", "openaiModel")
    assert(c.claudeAPIKey == "sk-ant-456", "claudeAPIKey")
    assert(c.claudeModel == "claude-opus-4-5-20251101", "claudeModel")
    assert(c.claudeExtendedThinking == true, "claudeExtendedThinking")
    assert(c.claudeThinkingBudget == 20000, "claudeThinkingBudget")
    assert(c.ollamaEnableThinking == true, "ollamaEnableThinking")
    assert(c.llamacppEnableThinking == true, "llamacppEnableThinking")
    assert(c.ttsVoice == "af_bella", "ttsVoice")
    assert(c.ttsSpeed == 1.25, "ttsSpeed")
    assert(c.disabledBuiltInActions == ["articulate", "read_aloud"], "disabledBuiltInActions")
    assert(c.customShortcuts == ["explain_simply": "E", "craft_a_reply": "R"], "customShortcuts (embedded JSON)")
    assert(c.popupHotkey == "J", "popupHotkey")
}

test("Legacy plaintext migration - unknown keys / comments / blanks ignored") {
    let text = """
    # comment line
    PROVIDER=ollama

    UNKNOWN_KEY=whatever
    TTS_SPEED=2.0
    """
    let c = AppConfig.migrateLegacyPlaintext(text)
    assert(c.provider == "ollama", "known key parsed")
    assert(c.ttsSpeed == 2.0, "second known key parsed")
    // Unrecognized values fall back to defaults.
    assert(c.openaiModel == "gpt-4o", "default kept for absent key")
}

test("JSON round-trip save -> load is stable") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    var original = AppConfig.migrateLegacyPlaintext(legacyPlaintext)
    original.userModels = [ModelRef(provider: "llamacpp", name: "user/repo", quant: "Q4_K_M", source: "huggingface")]
    original.providerKeys = ["openai": "k1", "claude": "k2"]
    original.agentSettings = AgentSettings(maxIterations: 9, enableMacControl: true, enableWebSearch: false)
    original.webSearch = WebSearchConfig(provider: "tavily", apiKeys: ["tavily": "tvly-1"])

    assert(original.save(to: dir), "save should succeed")
    assert(exists(dir, "config.json"), "config.json should be written")

    let loaded = AppConfig.load(dir: dir)
    assert(loaded == original, "round-tripped config should equal the original")
    assert(loaded.userModels.first?.quant == "Q4_K_M", "userModels survive round-trip")
    assert(loaded.agentSettings.maxIterations == 9, "agentSettings survive round-trip")
    assert(loaded.webSearch.provider == "tavily", "webSearch survive round-trip")
}

test("New fields default when absent from JSON") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    // A minimal v2 JSON missing all new fields.
    write(#"{"version":2,"provider":"openai","openaiModel":"gpt-4o-mini"}"#, to: dir, named: "config.json")

    let c = AppConfig.load(dir: dir)
    assert(c.provider == "openai", "present field loaded")
    assert(c.openaiModel == "gpt-4o-mini", "present field loaded")
    // New forward-looking fields get sane defaults.
    assert(c.userModels.isEmpty, "userModels defaults to empty")
    assert(c.providerKeys.isEmpty, "providerKeys defaults to empty")
    assert(c.agentSettings.maxIterations == 6, "agentSettings.maxIterations defaults to 6")
    assert(c.agentSettings.enableMacControl == false, "enableMacControl defaults false")
    assert(c.webSearch.provider == "ddg", "webSearch.provider defaults to ddg")
    // Absent legacy fields also get defaults.
    assert(c.ttsVoice == "af_heart", "ttsVoice defaults")
    assert(c.popupHotkey == "Space", "popupHotkey defaults")
}

test("Load rule (a): full v2 config.json is used as-is") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    var saved = AppConfig()
    saved.provider = "openai"
    saved.ttsVoice = "af_nicole"
    assert(saved.save(to: dir), "save")

    // Also drop a stale legacy plaintext that should be IGNORED because v2 JSON wins.
    write("PROVIDER=ollama\nTTS_VOICE=af_heart", to: dir, named: "config")

    let c = AppConfig.load(dir: dir)
    assert(c.provider == "openai", "v2 JSON wins over legacy plaintext, got \(c.provider)")
    assert(c.ttsVoice == "af_nicole", "v2 JSON value used")
}

test("Load rule (b): legacy plaintext WINS over legacy minimal JSON stub") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    // Legacy plaintext sets several fields, including provider.
    write("PROVIDER=ollama\nOLLAMA_MODEL=mistral\nTTS_SPEED=1.5", to: dir, named: "config")
    // Legacy minimal/partial JSON stub (version < 2) disagrees on provider.
    write(#"{"provider":"claude"}"#, to: dir, named: "config.json")

    let c = AppConfig.load(dir: dir)
    // Plaintext is the old binary's real source of truth -> it wins over the stub.
    assert(c.provider == "ollama", "plaintext provider wins over stub, got \(c.provider)")
    assert(c.ollamaModel == "mistral", "plaintext value retained")
    assert(c.ttsSpeed == 1.5, "plaintext value retained")
}

test("Upgrade regression: install.sh stub must NOT reset a real plaintext config") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    // Simulate an existing user: old binary's real plaintext config with non-default settings.
    write("""
    PROVIDER=openai
    OPENAI_MODEL=gpt-4o
    CLAUDE_API_KEY=sk-xxx
    OLLAMA_MODEL=qwen3.5:7b
    """, to: dir, named: "config")
    // install.sh writes this stub before the new binary runs on upgrade.
    write(#"{"provider":"llamacpp"}"#, to: dir, named: "config.json")

    let c = AppConfig.load(dir: dir)
    assert(c.provider == "openai", "plaintext provider must survive the install stub, got \(c.provider)")
    assert(c.openaiModel == "gpt-4o", "openaiModel from plaintext intact")
    assert(c.claudeAPIKey == "sk-xxx", "claudeAPIKey from plaintext intact")
    assert(c.ollamaModel == "qwen3.5:7b", "ollamaModel from plaintext intact")
}

test("Stub-only (no plaintext): provider comes from the JSON stub") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    // No plaintext `config` — only the install stub exists.
    write(#"{"provider":"claude"}"#, to: dir, named: "config.json")

    let c = AppConfig.load(dir: dir)
    assert(c.provider == "claude", "stub provider used when no plaintext, got \(c.provider)")
    assert(c.openaiModel == "gpt-4o", "absent keys keep defaults")
}

test("Load with empty dir returns defaults") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let c = AppConfig.load(dir: dir)
    assert(c == AppConfig(), "empty dir yields pure defaults")
    assert(c.provider == "llamacpp", "default provider")
}

test("Legacy-only dir (no JSON) migrates plaintext") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    write(legacyPlaintext, to: dir, named: "config")
    let c = AppConfig.load(dir: dir)
    assert(c.provider == "claude", "migrated from plaintext")
    assert(c.customShortcuts == ["explain_simply": "E", "craft_a_reply": "R"], "shortcuts migrated")
}

// MARK: - Results

print("\n========================================")
print("Results: \(passCount) passed, \(failCount) failed")
print("========================================")

if failCount > 0 {
    exit(1)
} else {
    print("All config tests passed!")
    exit(0)
}
