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

// MARK: - Data Models

enum ActionType: String, Codable, CaseIterable {
    case llm = "llm"
    case command = "command"
    case agent = "agent"   // PR7: runs the tool-calling agent loop
    // (Retired: "tts" — the text-to-speech "Read aloud" action was removed. Saved
    //  actions of that type are dropped on load; see `RetiredActionTypeError`.)

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .command: return "CMD"
        case .agent: return "AGENT"
        }
    }
}

/// Thrown while decoding a saved action of a REMOVED type — text-to-speech
/// ("Read aloud"): `"actionType": "tts"`, or the legacy `"isTTS": true`. The
/// actions-file loader drops such entries rather than failing the whole file
/// (which would reset every user action to the defaults).
struct RetiredActionTypeError: Error {}

struct Action: Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var prompt: String
    var shortcut: String?
    var actionType: ActionType
    var isEnabled: Bool
    var order: Int
    var isDefault: Bool  // Was originally a built-in (enables "Reset to default")

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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Action, rhs: Action) -> Bool {
        lhs.id == rhs.id
    }
}

extension Action: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, icon, prompt, shortcut, actionType, isEnabled, order, isDefault
        case isTTS  // legacy field (pre-actionType files) — read only, never written
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

        // Try new actionType first, fall back to legacy isTTS. Text-to-speech
        // actions are retired: signal them so the file loader can drop them.
        if let raw = try container.decodeIfPresent(String.self, forKey: .actionType) {
            if raw == "tts" { throw RetiredActionTypeError() }
            guard let type = ActionType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .actionType, in: container, debugDescription: "Unknown actionType '\(raw)'")
            }
            actionType = type
        } else if let isTTS = try container.decodeIfPresent(Bool.self, forKey: .isTTS) {
            if isTTS { throw RetiredActionTypeError() }
            actionType = .llm
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
    /// Retired (text-to-speech) actions dropped while decoding. Not persisted.
    var droppedRetiredActions: Int = 0

    enum CodingKeys: String, CodingKey {
        case version, actions, customPromptShortcut, customPromptEnabled
    }
}

extension ActionsFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        let entries = try c.decode([DecodedAction].self, forKey: .actions)
        actions = entries.compactMap(\.action)
        droppedRetiredActions = entries.count - actions.count
        customPromptShortcut = try c.decodeIfPresent(String.self, forKey: .customPromptShortcut)
        customPromptEnabled = try c.decodeIfPresent(Bool.self, forKey: .customPromptEnabled)
    }
}

/// One saved action, or nil when it's of a retired type — so a stale "Read
/// aloud" entry can't make the whole actions file unreadable.
private struct DecodedAction: Decodable {
    let action: Action?

    init(from decoder: Decoder) throws {
        do {
            action = try Action(from: decoder)
        } catch is RetiredActionTypeError {
            action = nil
        }
    }
}

// Legacy type for migration from old actions.json format
// (promoted from `private` to `internal` so ActionManager, now in a separate
//  file of the same target, can still decode it during migration)
struct LegacyCustomAction: Codable {
    var id: UUID
    var name: String
    var icon: String
    var prompt: String
}

// MARK: - LLM Configuration

struct LLMConfig {
    enum Provider: String, CaseIterable {
        case llamacpp = "llamacpp"
        case ollama = "ollama"
        case openai = "openai"
        case claude = "claude"

        var displayName: String {
            switch self {
            case .llamacpp: return "llama.cpp (Local)"
            case .ollama: return "Ollama"
            case .openai: return "OpenAI"
            case .claude: return "Claude"
            }
        }
    }

    struct LlamaModel {
        let id: String
        let name: String
        let size: String
        let languages: String
        let url: String
        let filename: String
    }

    static let llamaModels: [LlamaModel] = [
        LlamaModel(
            id: "qwen3-30b-a3b",
            name: "Qwen3 30B-A3B (recommended)",
            size: "~18.6GB",
            languages: "119 languages",
            url: "https://huggingface.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf",
            filename: "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "qwen3.5-2b",
            name: "Qwen 3.5 2B",
            size: "~1.3GB",
            languages: "201 languages",
            url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
            filename: "Qwen3.5-2B-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "qwen3.5-4b",
            name: "Qwen 3.5 4B",
            size: "~2.7GB",
            languages: "201 languages",
            url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
            filename: "Qwen3.5-4B-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "phi-4-mini",
            name: "Phi-4 Mini 3.8B",
            size: "~2.5GB",
            languages: "22 languages",
            url: "https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
            filename: "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "gemma-3n-e4b",
            name: "Gemma 3n E4B",
            size: "~4.2GB",
            languages: "140+ languages",
            url: "https://huggingface.co/bartowski/google_gemma-3n-E4B-it-GGUF/resolve/main/google_gemma-3n-E4B-it-Q4_K_M.gguf",
            filename: "google_gemma-3n-E4B-it-Q4_K_M.gguf"
        )
    ]

    /// Physical RAM rounded to whole gigabytes — used to label the recommendation.
    static func physicalMemoryGB() -> Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
    }

    /// The single built-in local model recommended for THIS machine, chosen purely
    /// by physical RAM. `llamaModels` stays the definition source (filenames, ids,
    /// urls); this only PICKS one of them so the picker can surface a single
    /// "recommended for your Mac" row instead of the full catalog.
    ///   >= 28 GB → qwen3-30b-a3b
    ///   >= 12 GB → qwen3.5-4b
    ///   else     → qwen3.5-2b
    static func recommendedLlamaModel() -> LlamaModel {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let id: String
        if gb >= 28 { id = "qwen3-30b-a3b" }
        else if gb >= 12 { id = "qwen3.5-4b" }
        else { id = "qwen3.5-2b" }
        return llamaModels.first { $0.id == id } ?? llamaModels[0]
    }

    var provider: Provider = .llamacpp
    var llamaModel: String = "qwen3-30b-a3b"
    var llamacppURL: String = "http://localhost:10819"
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen3.5:4b"
    var ollamaAPIKey: String = ""
    var openaiAPIKey: String = ""
    var openaiModel: String = "gpt-4o"
    var claudeAPIKey: String = ""
    var claudeModel: String = "claude-sonnet-4-5-20250514"
    var claudeExtendedThinking: Bool = false
    var claudeThinkingBudget: Int = 10000
    var ollamaEnableThinking: Bool = false
    var llamacppEnableThinking: Bool = false
    var popupHotkey: String = "Space"  // Main popup hotkey (with Option modifier)

    /// A non-empty API key switches the Ollama provider to Ollama Cloud
    /// (ollama.com); an empty key keeps local Ollama at `ollamaURL`.
    var effectiveOllamaURL: String { ollamaAPIKey.isEmpty ? ollamaURL : "https://ollama.com" }

    // Legacy fields — only used for migration, not saved
    var disabledBuiltInActions: [String] = []
    var customShortcuts: [String: String] = [:]

    // PR3: user-managed models + cloud provider keys (carried through to AppConfig).
    var userModels: [ModelRef] = []
    var providerKeys: [String: String] = [:]

    // PR4: persistent corner bubble settings (carried through to AppConfig).
    var bubble: BubbleSettings = BubbleSettings()

    // PR9: agent + Mac-control + MCP settings (carried through to AppConfig).
    var agentSettings: AgentSettings = AgentSettings()
    var mcpServers: [MCPServerConfig] = []

    // Model lists
    static let openaiModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "o1",
        "o1-mini",
        "o1-pro",
        "o3-mini",
        "Custom..."
    ]

    static let claudeModels = [
        "claude-sonnet-4-5-20250514",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-20250514",
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
        "claude-3-opus-20240229",
        "Custom..."
    ]

    /// Directory holding all PopDraft on-disk state (`~/.popdraft`).
    ///
    /// Honors a `PD_CONFIG_DIR` env override so the headless `--agent-once`
    /// eval seam can point config/sessions/web-cache at a throwaway directory
    /// (with `--provider`/`--model` overrides written into it) WITHOUT touching
    /// the user's real `~/.popdraft`. The shipping app never sets this var, so
    /// normal launches are unchanged.
    static var configDir: String {
        if let override = ProcessInfo.processInfo.environment["PD_CONFIG_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".popdraft").path
    }

    /// Default-initialized config (all stored properties keep their defaults).
    init() {}

    /// Build an LLMConfig from the corresponding AppConfig fields.
    init(from app: AppConfig) {
        self.provider = Provider(rawValue: app.provider) ?? .llamacpp
        self.llamaModel = app.llamaModel
        self.llamacppURL = app.llamacppURL
        self.ollamaURL = app.ollamaURL
        self.ollamaModel = app.ollamaModel
        self.ollamaAPIKey = app.ollamaAPIKey
        self.openaiAPIKey = app.openaiAPIKey
        self.openaiModel = app.openaiModel
        self.claudeAPIKey = app.claudeAPIKey
        self.claudeModel = app.claudeModel
        self.claudeExtendedThinking = app.claudeExtendedThinking
        self.claudeThinkingBudget = app.claudeThinkingBudget
        self.ollamaEnableThinking = app.ollamaEnableThinking
        self.llamacppEnableThinking = app.llamacppEnableThinking
        self.popupHotkey = app.popupHotkey
        self.disabledBuiltInActions = app.disabledBuiltInActions
        self.customShortcuts = app.customShortcuts
        self.userModels = app.userModels
        self.providerKeys = app.providerKeys
        self.bubble = app.bubble
        self.agentSettings = app.agentSettings
        self.mcpServers = app.mcpServers
    }

    /// Map this LLMConfig onto an AppConfig, preserving the AppConfig's
    /// remaining forward-looking fields (agentSettings, webSearch).
    func toAppConfig(base: AppConfig) -> AppConfig {
        var app = base
        app.version = 2
        app.provider = provider.rawValue
        app.llamaModel = llamaModel
        app.llamacppURL = llamacppURL
        app.ollamaURL = ollamaURL
        app.ollamaModel = ollamaModel
        app.ollamaAPIKey = ollamaAPIKey
        app.openaiAPIKey = openaiAPIKey
        app.openaiModel = openaiModel
        app.claudeAPIKey = claudeAPIKey
        app.claudeModel = claudeModel
        app.claudeExtendedThinking = claudeExtendedThinking
        app.claudeThinkingBudget = claudeThinkingBudget
        app.ollamaEnableThinking = ollamaEnableThinking
        app.llamacppEnableThinking = llamacppEnableThinking
        app.popupHotkey = popupHotkey
        app.disabledBuiltInActions = disabledBuiltInActions
        app.customShortcuts = customShortcuts
        app.userModels = userModels
        app.providerKeys = providerKeys
        app.bubble = bubble
        app.agentSettings = agentSettings
        app.mcpServers = mcpServers
        return app
    }

    static func load() -> LLMConfig {
        // Delegate persistence to the pure Core.swift AppConfig store.
        // This reads config.json (v2), migrating legacy plaintext `config`
        // automatically on first run.
        let app = AppConfig.load(dir: configDir)
        return LLMConfig(from: app)
    }

    func save() {
        let dir = LLMConfig.configDir

        // Preserve any forward-looking fields already on disk.
        let base = AppConfig.load(dir: dir)
        let app = toAppConfig(base: base)
        app.save(to: dir)

        // Dual-write the legacy plaintext `~/.popdraft/config` for ONE release
        // (best-effort) so rolling back to an older binary still works.
        writeLegacyPlaintext(to: dir)
    }

    /// Best-effort write of the old KEY=value plaintext format (for rollback safety).
    private func writeLegacyPlaintext(to dir: String) {
        let configPath = (dir as NSString).appendingPathComponent("config")
        var lines: [String] = []
        lines.append("PROVIDER=\(provider.rawValue)")
        lines.append("LLAMACPP_URL=\(llamacppURL)")
        lines.append("LLAMA_MODEL=\(llamaModel)")
        lines.append("OLLAMA_URL=\(ollamaURL)")
        lines.append("OLLAMA_MODEL=\(ollamaModel)")
        lines.append("OLLAMA_API_KEY=\(ollamaAPIKey)")
        lines.append("OPENAI_API_KEY=\(openaiAPIKey)")
        lines.append("OPENAI_MODEL=\(openaiModel)")
        lines.append("CLAUDE_API_KEY=\(claudeAPIKey)")
        lines.append("CLAUDE_MODEL=\(claudeModel)")
        lines.append("CLAUDE_EXTENDED_THINKING=\(claudeExtendedThinking)")
        lines.append("CLAUDE_THINKING_BUDGET=\(claudeThinkingBudget)")
        lines.append("OLLAMA_ENABLE_THINKING=\(ollamaEnableThinking)")
        lines.append("LLAMACPP_ENABLE_THINKING=\(llamacppEnableThinking)")
        lines.append("POPUP_HOTKEY=\(popupHotkey)")

        let content = lines.joined(separator: "\n")
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

}

// MARK: - LLM Response

struct LLMResponse {
    let text: String
    let thinking: String?
}

enum LLMStreamProgress {
    case thinking
    case generating(String)  // accumulated response text so far
}
