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
    case tts = "tts"
    case command = "command"
    case agent = "agent"   // PR7: runs the tool-calling agent loop

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .tts: return "TTS"
        case .command: return "CMD"
        case .agent: return "AGENT"
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

        // Try new actionType first, fall back to legacy isTTS
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

    var provider: Provider = .llamacpp
    var llamaModel: String = "qwen3-30b-a3b"
    var llamacppURL: String = "http://localhost:10819"
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen3.5:4b"
    var openaiAPIKey: String = ""
    var openaiModel: String = "gpt-4o"
    var claudeAPIKey: String = ""
    var claudeModel: String = "claude-sonnet-4-5-20250514"
    var claudeExtendedThinking: Bool = false
    var claudeThinkingBudget: Int = 10000
    var ollamaEnableThinking: Bool = false
    var llamacppEnableThinking: Bool = false
    var ttsVoice: String = "af_heart"
    var ttsSpeed: Double = 1.0
    var popupHotkey: String = "Space"  // Main popup hotkey (with Option modifier)

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

    // TTS voice list — all 54 Kokoro v1.0 voices grouped by language
    static let ttsVoiceLanguages: [String] = [
        "American English",
        "British English",
        "Japanese",
        "Mandarin Chinese",
        "Spanish",
        "French",
        "Hindi",
        "Italian",
        "Brazilian Portuguese",
    ]

    static let ttsVoices: [(id: String, name: String, language: String)] = [
        // American English - Female
        ("af_heart", "Heart (Female)", "American English"),
        ("af_alloy", "Alloy (Female)", "American English"),
        ("af_aoede", "Aoede (Female)", "American English"),
        ("af_bella", "Bella (Female)", "American English"),
        ("af_jessica", "Jessica (Female)", "American English"),
        ("af_kore", "Kore (Female)", "American English"),
        ("af_nicole", "Nicole (Female)", "American English"),
        ("af_nova", "Nova (Female)", "American English"),
        ("af_river", "River (Female)", "American English"),
        ("af_sarah", "Sarah (Female)", "American English"),
        ("af_sky", "Sky (Female)", "American English"),
        // American English - Male
        ("am_adam", "Adam (Male)", "American English"),
        ("am_echo", "Echo (Male)", "American English"),
        ("am_eric", "Eric (Male)", "American English"),
        ("am_fenrir", "Fenrir (Male)", "American English"),
        ("am_liam", "Liam (Male)", "American English"),
        ("am_michael", "Michael (Male)", "American English"),
        ("am_onyx", "Onyx (Male)", "American English"),
        ("am_puck", "Puck (Male)", "American English"),
        ("am_santa", "Santa (Male)", "American English"),
        // British English - Female
        ("bf_alice", "Alice (Female)", "British English"),
        ("bf_emma", "Emma (Female)", "British English"),
        ("bf_isabella", "Isabella (Female)", "British English"),
        ("bf_lily", "Lily (Female)", "British English"),
        // British English - Male
        ("bm_daniel", "Daniel (Male)", "British English"),
        ("bm_fable", "Fable (Male)", "British English"),
        ("bm_george", "George (Male)", "British English"),
        ("bm_lewis", "Lewis (Male)", "British English"),
        // Japanese - Female
        ("jf_alpha", "Alpha (Female)", "Japanese"),
        ("jf_gongitsune", "Gongitsune (Female)", "Japanese"),
        ("jf_nezumi", "Nezumi (Female)", "Japanese"),
        ("jf_tebukuro", "Tebukuro (Female)", "Japanese"),
        // Japanese - Male
        ("jm_kumo", "Kumo (Male)", "Japanese"),
        // Mandarin Chinese - Female
        ("zf_xiaobei", "Xiaobei (Female)", "Mandarin Chinese"),
        ("zf_xiaoni", "Xiaoni (Female)", "Mandarin Chinese"),
        ("zf_xiaoxiao", "Xiaoxiao (Female)", "Mandarin Chinese"),
        ("zf_xiaoyi", "Xiaoyi (Female)", "Mandarin Chinese"),
        // Mandarin Chinese - Male
        ("zm_yunjian", "Yunjian (Male)", "Mandarin Chinese"),
        ("zm_yunxi", "Yunxi (Male)", "Mandarin Chinese"),
        ("zm_yunxia", "Yunxia (Male)", "Mandarin Chinese"),
        ("zm_yunyang", "Yunyang (Male)", "Mandarin Chinese"),
        // Spanish - Female
        ("ef_dora", "Dora (Female)", "Spanish"),
        // Spanish - Male
        ("em_alex", "Alex (Male)", "Spanish"),
        ("em_santa", "Santa (Male)", "Spanish"),
        // French - Female
        ("ff_siwis", "Siwis (Female)", "French"),
        // Hindi - Female
        ("hf_alpha", "Alpha (Female)", "Hindi"),
        ("hf_beta", "Beta (Female)", "Hindi"),
        // Hindi - Male
        ("hm_omega", "Omega (Male)", "Hindi"),
        ("hm_psi", "Psi (Male)", "Hindi"),
        // Italian - Female
        ("if_sara", "Sara (Female)", "Italian"),
        // Italian - Male
        ("im_nicola", "Nicola (Male)", "Italian"),
        // Brazilian Portuguese - Female
        ("pf_dora", "Dora (Female)", "Brazilian Portuguese"),
        // Brazilian Portuguese - Male
        ("pm_alex", "Alex (Male)", "Brazilian Portuguese"),
        ("pm_santa", "Santa (Male)", "Brazilian Portuguese"),
    ]

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
        self.openaiAPIKey = app.openaiAPIKey
        self.openaiModel = app.openaiModel
        self.claudeAPIKey = app.claudeAPIKey
        self.claudeModel = app.claudeModel
        self.claudeExtendedThinking = app.claudeExtendedThinking
        self.claudeThinkingBudget = app.claudeThinkingBudget
        self.ollamaEnableThinking = app.ollamaEnableThinking
        self.llamacppEnableThinking = app.llamacppEnableThinking
        self.ttsVoice = app.ttsVoice
        self.ttsSpeed = app.ttsSpeed
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
        app.openaiAPIKey = openaiAPIKey
        app.openaiModel = openaiModel
        app.claudeAPIKey = claudeAPIKey
        app.claudeModel = claudeModel
        app.claudeExtendedThinking = claudeExtendedThinking
        app.claudeThinkingBudget = claudeThinkingBudget
        app.ollamaEnableThinking = ollamaEnableThinking
        app.llamacppEnableThinking = llamacppEnableThinking
        app.ttsVoice = ttsVoice
        app.ttsSpeed = ttsSpeed
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
        lines.append("OPENAI_API_KEY=\(openaiAPIKey)")
        lines.append("OPENAI_MODEL=\(openaiModel)")
        lines.append("CLAUDE_API_KEY=\(claudeAPIKey)")
        lines.append("CLAUDE_MODEL=\(claudeModel)")
        lines.append("CLAUDE_EXTENDED_THINKING=\(claudeExtendedThinking)")
        lines.append("CLAUDE_THINKING_BUDGET=\(claudeThinkingBudget)")
        lines.append("OLLAMA_ENABLE_THINKING=\(ollamaEnableThinking)")
        lines.append("LLAMACPP_ENABLE_THINKING=\(llamacppEnableThinking)")
        lines.append("TTS_VOICE=\(ttsVoice)")
        lines.append("TTS_SPEED=\(ttsSpeed)")
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
