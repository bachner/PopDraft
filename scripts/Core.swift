// Core.swift — Pure, Foundation-only logic for PopDraft.
//
// This file is co-compiled with PopDraft.swift (`swiftc PopDraft.swift Core.swift ...`)
// and ALSO compiled standalone by the test harness (`swiftc tests/test-config.swift Core.swift`).
// It MUST NOT import Cocoa / AppKit / SwiftUI / WebKit — Foundation only — so the
// pure logic stays testable without a GUI toolkit.

import Foundation

// MARK: - Forward-looking config sub-models

/// A user-managed model reference (local HF repo or cloud provider model).
struct ModelRef: Codable, Equatable {
    var provider: String          // e.g. "llamacpp", "ollama", "openai", "claude"
    var name: String              // model name or HF repo (e.g. "user/repo")
    var quant: String?            // optional quantization (e.g. "Q4_K_M")
    var source: String            // e.g. "huggingface", "ollama", "cloud"

    init(provider: String, name: String, quant: String? = nil, source: String = "huggingface") {
        self.provider = provider
        self.name = name
        self.quant = quant
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "llamacpp"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        quant = try c.decodeIfPresent(String.self, forKey: .quant)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "huggingface"
    }
}

/// Settings for the (forthcoming) agent loop.
struct AgentSettings: Codable, Equatable {
    var maxIterations: Int
    /// Master switch for the confirm-gated Mac-control tools (`run_shell` /
    /// `run_applescript`). OFF by default — when false the tools are NOT even
    /// registered, so the model literally cannot call them. (PR9)
    var enableMacControl: Bool
    var enableWebSearch: Bool
    /// When true, a small set of safe READ-ONLY command prefixes (ls/cat/pwd/…)
    /// may run WITHOUT the confirm dialog. Everything else always confirms; the
    /// hard denylist always applies. Default OFF. (PR9)
    var autoApproveSafeReadOnly: Bool
    /// Headless/eval safety: when true, Mac-control tools NEVER execute — they
    /// record "would execute: <cmd> (awaiting confirm)" and return. Used by a
    /// future headless eval where there is no UI to confirm. Default OFF. (PR9)
    var macControlDryRun: Bool

    init(maxIterations: Int = 6,
         enableMacControl: Bool = false,
         enableWebSearch: Bool = true,
         autoApproveSafeReadOnly: Bool = false,
         macControlDryRun: Bool = false) {
        self.maxIterations = maxIterations
        self.enableMacControl = enableMacControl
        self.enableWebSearch = enableWebSearch
        self.autoApproveSafeReadOnly = autoApproveSafeReadOnly
        self.macControlDryRun = macControlDryRun
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 6
        enableMacControl = try c.decodeIfPresent(Bool.self, forKey: .enableMacControl) ?? false
        enableWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enableWebSearch) ?? true
        autoApproveSafeReadOnly = try c.decodeIfPresent(Bool.self, forKey: .autoApproveSafeReadOnly) ?? false
        macControlDryRun = try c.decodeIfPresent(Bool.self, forKey: .macControlDryRun) ?? false
    }
}

/// One configured MCP server: a subprocess the app spawns and speaks JSON-RPC
/// (stdio) to, exposing its `tools/list` as agent tools. Default config carries
/// an empty list, so nothing is spawned until a user configures a server. (PR9)
struct MCPServerConfig: Codable, Equatable {
    var name: String
    var command: String
    var args: [String]
    /// Whether this server is active (lets a user keep a config but disable it).
    var enabled: Bool

    init(name: String, command: String, args: [String] = [], enabled: Bool = true) {
        self.name = name
        self.command = command
        self.args = args
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Settings for the persistent corner bubble (PR4).
///
/// `corner` is one of "topLeft" / "topRight" / "bottomLeft" / "bottomRight".
/// Unknown values fall back to the default ("bottomRight") via `BubbleCorner`.
struct BubbleSettings: Codable, Equatable {
    var enabled: Bool
    var corner: String

    init(enabled: Bool = true, corner: String = "bottomRight") {
        self.enabled = enabled
        self.corner = corner
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        corner = try c.decodeIfPresent(String.self, forKey: .corner) ?? "bottomRight"
    }
}

/// The four screen corners the bubble can be pinned to. Pure (no AppKit) so it
/// can live in Core.swift and be unit-tested; the AppKit side maps it to points.
enum BubbleCorner: String, CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// Parse a stored string, defaulting to `.bottomRight` for unknown values.
    static func parse(_ raw: String) -> BubbleCorner {
        return BubbleCorner(rawValue: raw) ?? .bottomRight
    }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// Web-search provider configuration.
struct WebSearchConfig: Codable, Equatable {
    var provider: String              // "ddg" (default, no key), "tavily", "brave", "exa"
    var apiKeys: [String: String]     // provider -> key

    init(provider: String = "ddg", apiKeys: [String: String] = [:]) {
        self.provider = provider
        self.apiKeys = apiKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "ddg"
        apiKeys = try c.decodeIfPresent([String: String].self, forKey: .apiKeys) ?? [:]
    }
}

// MARK: - AppConfig (v2 JSON config model)

/// The v2 on-disk config model. Persisted as `~/.popdraft/config.json`.
///
/// Every field uses `decodeIfPresent` + a default so older or partial JSON still
/// decodes cleanly (same backward-compat pattern as `Action.init(from:)`).
struct AppConfig: Codable, Equatable {
    var version: Int

    // --- Fields mirrored 1:1 from the legacy LLMConfig ---
    var provider: String
    var llamacppURL: String
    var llamaModel: String
    var ollamaURL: String
    var ollamaModel: String
    var openaiAPIKey: String
    var openaiModel: String
    var claudeAPIKey: String
    var claudeModel: String
    var claudeExtendedThinking: Bool
    var claudeThinkingBudget: Int
    var ollamaEnableThinking: Bool
    var llamacppEnableThinking: Bool
    var ttsVoice: String
    var ttsSpeed: Double
    var popupHotkey: String
    var disabledBuiltInActions: [String]
    var customShortcuts: [String: String]

    // --- New forward-looking fields ---
    var userModels: [ModelRef]
    var providerKeys: [String: String]
    var agentSettings: AgentSettings
    var webSearch: WebSearchConfig
    var bubble: BubbleSettings
    /// Configured MCP servers (PR9). Default `[]` — nothing is spawned until the
    /// user adds one. Discovered tools register into the same agent ToolRegistry.
    var mcpServers: [MCPServerConfig]

    // --- PR6: homemade WebEngine knobs ---
    /// Max concurrent offscreen WKWebViews. Clamped to 1...6. Default 2 (vetted posture).
    var webMaxRenderers: Int
    /// Per-job navigation timeout in milliseconds (load + settle). Default 15000.
    var webNavTimeoutMs: Int
    /// Bounded "settle" wait after `readyState=="complete"`, in ms. Default 600.
    var webSettleMs: Int
    /// Hard character cap for read()/extract() Markdown output. Default 12000.
    var webReadMaxChars: Int
    /// Max response size accepted by the engine, in bytes. Default 8 MB.
    var webMaxBytes: Int

    // MARK: Defaults

    init(
        version: Int = 2,
        provider: String = "llamacpp",
        llamacppURL: String = "http://localhost:10819",
        llamaModel: String = "qwen3.5-4b",
        ollamaURL: String = "http://localhost:11434",
        ollamaModel: String = "qwen3.5:4b",
        openaiAPIKey: String = "",
        openaiModel: String = "gpt-4o",
        claudeAPIKey: String = "",
        claudeModel: String = "claude-sonnet-4-5-20250514",
        claudeExtendedThinking: Bool = false,
        claudeThinkingBudget: Int = 10000,
        ollamaEnableThinking: Bool = false,
        llamacppEnableThinking: Bool = false,
        ttsVoice: String = "af_heart",
        ttsSpeed: Double = 1.0,
        popupHotkey: String = "Space",
        disabledBuiltInActions: [String] = [],
        customShortcuts: [String: String] = [:],
        userModels: [ModelRef] = [],
        providerKeys: [String: String] = [:],
        agentSettings: AgentSettings = AgentSettings(),
        webSearch: WebSearchConfig = WebSearchConfig(),
        bubble: BubbleSettings = BubbleSettings(),
        mcpServers: [MCPServerConfig] = [],
        webMaxRenderers: Int = 2,
        webNavTimeoutMs: Int = 15000,
        webSettleMs: Int = 600,
        webReadMaxChars: Int = 12000,
        webMaxBytes: Int = 8 * 1024 * 1024
    ) {
        self.version = version
        self.provider = provider
        self.llamacppURL = llamacppURL
        self.llamaModel = llamaModel
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
        self.openaiAPIKey = openaiAPIKey
        self.openaiModel = openaiModel
        self.claudeAPIKey = claudeAPIKey
        self.claudeModel = claudeModel
        self.claudeExtendedThinking = claudeExtendedThinking
        self.claudeThinkingBudget = claudeThinkingBudget
        self.ollamaEnableThinking = ollamaEnableThinking
        self.llamacppEnableThinking = llamacppEnableThinking
        self.ttsVoice = ttsVoice
        self.ttsSpeed = ttsSpeed
        self.popupHotkey = popupHotkey
        self.disabledBuiltInActions = disabledBuiltInActions
        self.customShortcuts = customShortcuts
        self.userModels = userModels
        self.providerKeys = providerKeys
        self.agentSettings = agentSettings
        self.webSearch = webSearch
        self.bubble = bubble
        self.mcpServers = mcpServers
        self.webMaxRenderers = webMaxRenderers
        self.webNavTimeoutMs = webNavTimeoutMs
        self.webSettleMs = webSettleMs
        self.webReadMaxChars = webReadMaxChars
        self.webMaxBytes = webMaxBytes
    }

    // MARK: Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()  // defaults

        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        llamacppURL = try c.decodeIfPresent(String.self, forKey: .llamacppURL) ?? d.llamacppURL
        llamaModel = try c.decodeIfPresent(String.self, forKey: .llamaModel) ?? d.llamaModel
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        openaiAPIKey = try c.decodeIfPresent(String.self, forKey: .openaiAPIKey) ?? d.openaiAPIKey
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? d.openaiModel
        claudeAPIKey = try c.decodeIfPresent(String.self, forKey: .claudeAPIKey) ?? d.claudeAPIKey
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        claudeExtendedThinking = try c.decodeIfPresent(Bool.self, forKey: .claudeExtendedThinking) ?? d.claudeExtendedThinking
        claudeThinkingBudget = try c.decodeIfPresent(Int.self, forKey: .claudeThinkingBudget) ?? d.claudeThinkingBudget
        ollamaEnableThinking = try c.decodeIfPresent(Bool.self, forKey: .ollamaEnableThinking) ?? d.ollamaEnableThinking
        llamacppEnableThinking = try c.decodeIfPresent(Bool.self, forKey: .llamacppEnableThinking) ?? d.llamacppEnableThinking
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice) ?? d.ttsVoice
        ttsSpeed = try c.decodeIfPresent(Double.self, forKey: .ttsSpeed) ?? d.ttsSpeed
        popupHotkey = try c.decodeIfPresent(String.self, forKey: .popupHotkey) ?? d.popupHotkey
        disabledBuiltInActions = try c.decodeIfPresent([String].self, forKey: .disabledBuiltInActions) ?? d.disabledBuiltInActions
        customShortcuts = try c.decodeIfPresent([String: String].self, forKey: .customShortcuts) ?? d.customShortcuts
        userModels = try c.decodeIfPresent([ModelRef].self, forKey: .userModels) ?? d.userModels
        providerKeys = try c.decodeIfPresent([String: String].self, forKey: .providerKeys) ?? d.providerKeys
        agentSettings = try c.decodeIfPresent(AgentSettings.self, forKey: .agentSettings) ?? d.agentSettings
        webSearch = try c.decodeIfPresent(WebSearchConfig.self, forKey: .webSearch) ?? d.webSearch
        bubble = try c.decodeIfPresent(BubbleSettings.self, forKey: .bubble) ?? d.bubble
        mcpServers = try c.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? d.mcpServers
        // PR6 web-engine knobs: clamp/sanitize so out-of-range disk values can't break the pool.
        webMaxRenderers = WebTuning.clampRenderers(try c.decodeIfPresent(Int.self, forKey: .webMaxRenderers) ?? d.webMaxRenderers)
        webNavTimeoutMs = max(1000, try c.decodeIfPresent(Int.self, forKey: .webNavTimeoutMs) ?? d.webNavTimeoutMs)
        webSettleMs = max(0, try c.decodeIfPresent(Int.self, forKey: .webSettleMs) ?? d.webSettleMs)
        webReadMaxChars = max(500, try c.decodeIfPresent(Int.self, forKey: .webReadMaxChars) ?? d.webReadMaxChars)
        webMaxBytes = max(64 * 1024, try c.decodeIfPresent(Int.self, forKey: .webMaxBytes) ?? d.webMaxBytes)
    }
}

/// Shared tuning helpers for the web engine (pure; unit-tested).
enum WebTuning {
    /// Clamp the renderer-pool size to the vetted 1...6 band.
    static func clampRenderers(_ n: Int) -> Int { min(6, max(1, n)) }
}

// MARK: - Persistence

extension AppConfig {
    static let jsonFileName = "config.json"
    static let legacyPlaintextFileName = "config"

    /// Load config from `<dir>/config.json` and/or legacy plaintext `<dir>/config`.
    ///
    /// Rules:
    ///  (a) If `config.json` exists and decodes with `version >= 2`, use it as-is.
    ///  (b) Otherwise start from defaults, overlay legacy plaintext `config` (if present),
    ///      then overlay any keys present in a legacy minimal `config.json` stub
    ///      (e.g. `{"provider":"llamacpp"}`), and return that.
    static func load(dir: String) -> AppConfig {
        let jsonPath = (dir as NSString).appendingPathComponent(jsonFileName)
        let legacyPath = (dir as NSString).appendingPathComponent(legacyPlaintextFileName)

        // (a) Full v2 JSON config: a real v2 file carries an explicit version >= 2.
        if let data = FileManager.default.contents(atPath: jsonPath),
           let v = rawVersion(data), v >= 2,
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return decoded
        }

        // (b) Build from defaults, then overlay sources in PRECEDENCE order
        //     (lowest first, highest last):
        //       1. defaults
        //       2. legacy minimal/partial JSON stub (version < 2 or missing)
        //       3. legacy plaintext `config`  ← highest, wins over the stub
        //
        // The legacy plaintext `config` is the OLD binary's real source of truth.
        // install.sh writes a `{"provider":"llamacpp"}` stub whenever config.json
        // is missing, and runs BEFORE the new binary on upgrade — so that stub must
        // NEVER override a real plaintext setting (e.g. PROVIDER=openai).
        var config = AppConfig()

        if let data = FileManager.default.contents(atPath: jsonPath) {
            config = overlayLegacyJSON(data, onto: config)
        }

        if let legacyText = try? String(contentsOfFile: legacyPath, encoding: .utf8) {
            config = overlayLegacyPlaintext(legacyText, onto: config)
        }

        return config
    }

    /// Read just the `version` field from raw JSON data, if present.
    private static func rawVersion(_ data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? Int
    }

    /// Overlay any recognized keys from a legacy/partial JSON stub onto a base config.
    /// Unknown keys are ignored; missing keys keep the base value.
    private static func overlayLegacyJSON(_ data: Data, onto base: AppConfig) -> AppConfig {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return base }
        var c = base
        if let v = obj["provider"] as? String { c.provider = v }
        if let v = obj["llamacppURL"] as? String { c.llamacppURL = v }
        if let v = obj["llamaModel"] as? String { c.llamaModel = v }
        if let v = obj["ollamaURL"] as? String { c.ollamaURL = v }
        if let v = obj["ollamaModel"] as? String { c.ollamaModel = v }
        if let v = obj["openaiAPIKey"] as? String { c.openaiAPIKey = v }
        if let v = obj["openaiModel"] as? String { c.openaiModel = v }
        if let v = obj["claudeAPIKey"] as? String { c.claudeAPIKey = v }
        if let v = obj["claudeModel"] as? String { c.claudeModel = v }
        if let v = obj["claudeExtendedThinking"] as? Bool { c.claudeExtendedThinking = v }
        if let v = obj["claudeThinkingBudget"] as? Int { c.claudeThinkingBudget = v }
        if let v = obj["ollamaEnableThinking"] as? Bool { c.ollamaEnableThinking = v }
        if let v = obj["llamacppEnableThinking"] as? Bool { c.llamacppEnableThinking = v }
        if let v = obj["ttsVoice"] as? String { c.ttsVoice = v }
        if let v = obj["ttsSpeed"] as? Double { c.ttsSpeed = v }
        if let v = obj["popupHotkey"] as? String { c.popupHotkey = v }
        if let v = obj["disabledBuiltInActions"] as? [String] { c.disabledBuiltInActions = v }
        if let v = obj["customShortcuts"] as? [String: String] { c.customShortcuts = v }
        return c
    }

    /// Save config as `<dir>/config.json` (always version 2).
    @discardableResult
    func save(to dir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var copy = self
        copy.version = 2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy) else { return false }
        let jsonPath = (dir as NSString).appendingPathComponent(AppConfig.jsonFileName)
        return (try? data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)) != nil
    }
}

// MARK: - Legacy plaintext migration

extension AppConfig {
    /// Parse the OLD `KEY=value` plaintext config format into a fresh `AppConfig`
    /// (defaults for any key not present in the text).
    /// Mirrors the key set in the legacy `LLMConfig.load()`, including the
    /// embedded-JSON `CUSTOM_SHORTCUTS` value.
    static func migrateLegacyPlaintext(_ text: String) -> AppConfig {
        return overlayLegacyPlaintext(text, onto: AppConfig())
    }

    /// Overlay the OLD `KEY=value` plaintext format onto a base config.
    /// Only keys actually present in the text are set; everything else keeps the
    /// base value. Used so legacy plaintext can take precedence over a JSON stub.
    static func overlayLegacyPlaintext(_ text: String, onto base: AppConfig) -> AppConfig {
        var config = base

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split on the FIRST '=' only — values (e.g. URLs, JSON) may contain '='.
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "PROVIDER":
                config.provider = value
            case "LLAMACPP_URL":
                config.llamacppURL = value
            case "LLAMA_MODEL":
                config.llamaModel = value
            case "OLLAMA_URL":
                config.ollamaURL = value
            case "OLLAMA_MODEL":
                config.ollamaModel = value
            case "OPENAI_API_KEY":
                config.openaiAPIKey = value
            case "OPENAI_MODEL":
                config.openaiModel = value
            case "CLAUDE_API_KEY":
                config.claudeAPIKey = value
            case "CLAUDE_MODEL":
                config.claudeModel = value
            case "CLAUDE_EXTENDED_THINKING":
                config.claudeExtendedThinking = (value == "true")
            case "CLAUDE_THINKING_BUDGET":
                config.claudeThinkingBudget = Int(value) ?? 10000
            case "OLLAMA_ENABLE_THINKING":
                config.ollamaEnableThinking = (value == "true")
            case "LLAMACPP_ENABLE_THINKING":
                config.llamacppEnableThinking = (value == "true")
            case "TTS_VOICE":
                config.ttsVoice = value
            case "TTS_SPEED":
                config.ttsSpeed = Double(value) ?? 1.0
            case "DISABLED_ACTIONS":
                config.disabledBuiltInActions = value.components(separatedBy: ",").filter { !$0.isEmpty }
            case "CUSTOM_SHORTCUTS":
                if let data = value.data(using: .utf8),
                   let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                    config.customShortcuts = dict
                }
            case "POPUP_HOTKEY":
                config.popupHotkey = value
            default:
                break
            }
        }

        return config
    }
}

// MARK: - Model Validation (pure parsers + thin async network)
//
// All logic here is Foundation-only and split into two layers:
//   1. PURE PARSERS — take raw `Data`/`Int` and return value types. These are
//      exercised directly by `tests/test-model-validation.swift` over hand-crafted
//      JSON fixtures, with NO network access.
//   2. Thin async methods — fetch over the network, then delegate to the pure
//      parsers. Not unit-tested (network), but trivial wrappers.

/// Gating state of a Hugging Face repo. HF returns `gated` as `false`, `"auto"`,
/// or `"manual"` — we collapse to a small enum.
enum HFGated: Equatable {
    case none          // public, no terms to accept
    case auto          // auto-approved gate (still needs a token)
    case manual        // manual-approval gate (needs token + accepted terms)

    /// Parse HF's polymorphic `gated` JSON value (`false` | `"auto"` | `"manual"`).
    static func parse(_ value: Any?) -> HFGated {
        if let b = value as? Bool { return b ? .manual : .none }
        if let s = value as? String {
            switch s.lowercased() {
            case "auto": return .auto
            case "manual": return .manual
            case "false", "": return .none
            default: return .manual   // unknown truthy string ⇒ treat as gated
            }
        }
        return .none
    }

    var isGated: Bool { self != .none }
}

/// Parsed metadata about a Hugging Face model repo.
struct HFModelInfo: Equatable {
    var exists: Bool
    var hasGGUF: Bool        // top-level `gguf` object present ⇒ strong "is a GGUF repo" signal
    var isPrivate: Bool
    var gated: HFGated
}

/// A single `.gguf` file in a repo tree, with its parsed quant + size.
struct GGUFFile: Equatable {
    var filename: String
    var quant: String        // e.g. "Q4_K_M", "IQ4_XS", "Q8_0" (empty if unparseable)
    var sizeBytes: Int64
}

/// The result of validating a local (Hugging Face GGUF) model reference.
struct ModelValidation: Equatable {
    enum State: Equatable {
        case valid                 // public GGUF repo, ready to download
        case validNeedsToken       // GGUF repo but private/gated — needs HF token / accepted terms
        case notGGUF               // repo exists but has no GGUF files
        case notFound              // repo doesn't exist (or anon 401/404)
        case error(String)         // network / parse error
    }

    var state: State
    var info: HFModelInfo?

    var isUsable: Bool { state == .valid }
    var message: String {
        switch state {
        case .valid: return "Found on Hugging Face"
        case .validNeedsToken: return "Found, but gated — needs a Hugging Face token / accepted terms"
        case .notGGUF: return "Not a GGUF repo (no .gguf files)"
        case .notFound: return "Not found on Hugging Face"
        case .error(let m): return m
        }
    }
}

/// The result of validating a cloud provider API key.
struct KeyValidation: Equatable {
    var isValid: Bool
    var models: [String]       // available model ids (empty if key invalid)
    var error: String?

    static let invalid = KeyValidation(isValid: false, models: [], error: nil)
}

/// Cloud providers we can validate keys against.
enum CloudProvider: String, CaseIterable, Equatable {
    case openai
    case anthropic
    case gemini
    case openrouter

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    /// Base URL for the OpenAI-compatible `/v1/models` probe.
    /// (Anthropic uses its own adapter, but we still give it a base.)
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: return "https://openrouter.ai/api"
        }
    }

    /// Maps a cloud provider to the legacy `LLMConfig.Provider` rawValue used in config.
    var llmProviderRawValue: String {
        switch self {
        case .openai, .gemini, .openrouter: return "openai"
        case .anthropic: return "claude"
        }
    }
}

/// Pure parsers + thin async network methods for validating models.
enum ModelValidator {

    // MARK: - PURE PARSERS (no network — unit-tested over fixtures)

    /// Parse the JSON body of `GET https://huggingface.co/api/models/{repo}`.
    /// Returns nil only if the body isn't a JSON object at all.
    static func parseHFModel(_ data: Data) -> HFModelInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The top-level `gguf` object is the strong "this is a GGUF repo" signal.
        let hasGGUF = obj["gguf"] != nil && !(obj["gguf"] is NSNull)
        let isPrivate = (obj["private"] as? Bool) ?? false
        let gated = HFGated.parse(obj["gated"])
        return HFModelInfo(exists: true, hasGGUF: hasGGUF, isPrivate: isPrivate, gated: gated)
    }

    /// Apply HF validation rules given an HTTP status + (optional) parsed info.
    /// HF returns 401 for nonexistent repos when anonymous — treat 401/404 as not found.
    static func validateHFModel(status: Int, info: HFModelInfo?) -> ModelValidation {
        if status == 401 || status == 404 {
            return ModelValidation(state: .notFound, info: nil)
        }
        guard status == 200, let info = info else {
            return ModelValidation(state: .error("HTTP \(status)"), info: info)
        }
        guard info.hasGGUF else {
            return ModelValidation(state: .notGGUF, info: info)
        }
        if info.isPrivate || info.gated.isGated {
            return ModelValidation(state: .validNeedsToken, info: info)
        }
        return ModelValidation(state: .valid, info: info)
    }

    /// Extract the quantization token (e.g. `Q4_K_M`, `IQ4_XS`, `Q8_0`, `Q5_K_S`)
    /// from a GGUF filename. Returns "" if none is recognizable.
    static func parseQuant(fromFilename filename: String) -> String {
        // Strip directory + extension. Split on FILENAME separators only ('-' and '.')
        // — NOT '_', because a quant token like Q4_K_M contains underscores.
        let base = (filename as NSString).lastPathComponent
        let stem = base.hasSuffix(".gguf") ? String(base.dropLast(5)) : base
        let tokens = stem.components(separatedBy: CharacterSet(charactersIn: "-."))
        // Match the canonical shapes: Q<digit>(_<...>) or IQ<digit>(_<...>) or F16/F32/BF16.
        // Scan from the end (quant usually trails the model name).
        for token in tokens.reversed() {
            let upper = token.uppercased()
            if isQuantToken(upper) { return upper }
        }
        return ""
    }

    private static func isQuantToken(_ t: String) -> Bool {
        if t == "F16" || t == "F32" || t == "BF16" || t == "F64" { return true }
        // IQ<n>... or Q<n>...
        var s = Substring(t)
        if s.hasPrefix("IQ") { s = s.dropFirst(2) }
        else if s.hasPrefix("Q") { s = s.dropFirst(1) }
        else { return false }
        guard let first = s.first, first.isNumber else { return false }
        return true
    }

    /// Parse the JSON body of `GET /api/models/{repo}/tree/main` into GGUF files.
    /// Filters to `*.gguf`, parses quant + size. Sorted by filename for determinism.
    static func parseHFTree(_ data: Data) -> [GGUFFile] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var files: [GGUFFile] = []
        for entry in arr {
            // Tree entries: {"type":"file","path":"...","size":N, "lfs":{"size":N}}
            guard let path = entry["path"] as? String, path.lowercased().hasSuffix(".gguf") else { continue }
            if let type = entry["type"] as? String, type != "file" { continue }
            // Prefer the LFS size (real file size for GGUFs stored in LFS); fall back to `size`.
            var size: Int64 = 0
            if let lfs = entry["lfs"] as? [String: Any], let s = (lfs["size"] as? NSNumber)?.int64Value {
                size = s
            } else if let s = (entry["size"] as? NSNumber)?.int64Value {
                size = s
            }
            files.append(GGUFFile(filename: path, quant: parseQuant(fromFilename: path), sizeBytes: size))
        }
        return files.sorted { $0.filename < $1.filename }
    }

    /// Parse an OpenAI-compatible `GET /v1/models` body: `{"data":[{"id":"..."}]}`.
    static func parseOpenAIModels(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["id"] as? String }
    }

    /// Parse an Anthropic `GET /v1/models` body: `{"data":[{"id":"...","display_name":"..."}]}`.
    static func parseAnthropicModels(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { $0["id"] as? String }
    }

    // MARK: - Network helpers

    /// Normalize a user-pasted HF repo string: strip a full URL down to `owner/name`,
    /// drop a trailing `:quant`, trim whitespace and slashes.
    static func normalizeHFRepo(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Note whether the original was a URL BEFORE we strip the scheme — a URL must
        // never have its scheme colon (`https:`) mistaken for a `:quant` suffix.
        let wasURL = s.contains("://")
        // Strip a leading huggingface.co URL (any scheme).
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        // Drop a trailing `:Q4_K_M` quant suffix — but ONLY from the final path component,
        // and ONLY when the input wasn't a URL (whose `://` colon must be left alone).
        if !wasURL {
            let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if var last = parts.last, let colon = last.firstIndex(of: ":") {
                last = String(last[..<colon])
                s = (parts.dropLast() + [last]).joined(separator: "/")
            }
        }
        // Keep just `owner/name`, dropping any `/tree/...` or `/resolve/...` tail.
        let comps = s.split(separator: "/").map(String.init)
        if comps.count >= 2 {
            s = "\(comps[0])/\(comps[1])"
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// Build the HF resolve URL for downloading a specific GGUF file.
    static func hfResolveURL(repo: String, file: String) -> String {
        return "https://huggingface.co/\(repo)/resolve/main/\(file)"
    }

    /// Validate a downloaded GGUF filename before it is written into a path or
    /// embedded into the launch-agent plist XML. Guards against path traversal and
    /// XML/shell injection: must match `^[A-Za-z0-9._-]+\.gguf$` (no slashes, no spaces,
    /// no `<>&'"`). Returns the bare filename if safe, else nil.
    static func safeGGUFFilename(_ filename: String) -> String? {
        // Strictly enforce `^[A-Za-z0-9._-]+\.gguf$` on the WHOLE string — any slash,
        // space, or XML metacharacter (so `../`, `</string>`, `&`) fails outright.
        guard filename.lowercased().hasSuffix(".gguf"), filename.count <= 255 else { return nil }
        let stem = String(filename.dropLast(5))           // strip ".gguf"
        guard !stem.isEmpty else { return nil }            // ".gguf" alone has no name
        if stem.hasPrefix(".") { return nil }              // reject hidden / dotfile names
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard filename.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return filename
    }

    // MARK: - Thin async network methods (fetch → pure parse)

#if canImport(FoundationNetworking)
    // (Linux) — URLSession lives in FoundationNetworking.
#endif

    /// Validate that an HF repo exists and is a usable GGUF repo.
    static func validateHFRepo(_ repo: String, token: String? = nil) async -> ModelValidation {
        let clean = normalizeHFRepo(repo)
        guard !clean.isEmpty, clean.contains("/"),
              let url = URL(string: "https://huggingface.co/api/models/\(clean)") else {
            return ModelValidation(state: .notFound, info: nil)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let info = (status == 200) ? parseHFModel(data) : nil
            return validateHFModel(status: status, info: info)
        } catch {
            return ModelValidation(state: .error(error.localizedDescription), info: nil)
        }
    }

    /// List the `.gguf` files in an HF repo (with quant + size).
    static func listGGUFFiles(_ repo: String, token: String? = nil) async -> [GGUFFile] {
        let clean = normalizeHFRepo(repo)
        guard !clean.isEmpty, clean.contains("/"),
              let url = URL(string: "https://huggingface.co/api/models/\(clean)/tree/main") else {
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return parseHFTree(data)
        } catch {
            return []
        }
    }

    /// Validate a cloud provider API key by probing its model-list endpoint.
    /// 200 ⇒ key valid (returns available model ids). 401/403 ⇒ invalid.
    static func validateCloudKey(provider: CloudProvider, key: String, baseURL: String? = nil) async -> KeyValidation {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .invalid }

        let base = (baseURL?.isEmpty == false ? baseURL! : provider.defaultBaseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        let urlString: String
        var headers: [String: String] = [:]
        let isAnthropic = (provider == .anthropic)

        if isAnthropic {
            urlString = "\(base)/v1/models"
            headers["x-api-key"] = trimmedKey
            headers["anthropic-version"] = "2023-06-01"
        } else {
            urlString = "\(base)/v1/models"
            headers["Authorization"] = "Bearer \(trimmedKey)"
        }

        guard let url = URL(string: urlString) else {
            return KeyValidation(isValid: false, models: [], error: "Invalid base URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return KeyValidation(isValid: false, models: [], error: "HTTP \(status)")
            }
            let models = isAnthropic ? parseAnthropicModels(data) : parseOpenAIModels(data)
            return KeyValidation(isValid: true, models: models, error: nil)
        } catch {
            return KeyValidation(isValid: false, models: [], error: error.localizedDescription)
        }
    }
}

// MARK: - Human-readable byte size

extension Int64 {
    /// Format a byte count like "4.7 GB" / "512 MB" (1000-based, like HF shows).
    var humanReadableSize: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var idx = 0
        while value >= 1000 && idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        if idx == 0 { return "\(self) B" }
        return String(format: "%.1f %@", value, units[idx])
    }
}

// MARK: - Chat session model (PR5)
//
// These types map 1:1 to OpenAI chat-completions `messages` / `tool_calls` /
// `role:"tool"` so a saved session can be replayed straight into the agent loop
// (PR7) and rendered in the chat UI (PR8). They are pure value types — Foundation
// only — and decode forward-compatibly (every field uses `decodeIfPresent` + a
// default) so a session written by a newer build still loads in an older one.

/// One OpenAI-style tool call requested by the assistant. No execution here — just
/// the shape, so a session that already used tools can round-trip on disk.
struct ChatToolCall: Codable, Equatable {
    var id: String
    var name: String
    var arguments: String   // raw JSON string, OpenAI-style (may be `{}` or `""`)

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
    }
}

/// One message in a chat session. Maps to an OpenAI `messages[]` entry:
///  - `role`     — "system" / "user" / "assistant" / "tool"
///  - `toolCalls`  — set on an assistant turn that requested tools
///  - `toolCallId` — set on a "tool" role message answering a specific call
///  - `thinking`   — optional captured reasoning (rendered collapsed in the UI)
struct ChatMessage: Codable, Equatable {
    var id: String
    var role: String
    var content: String
    var toolCalls: [ChatToolCall]?
    var toolCallId: String?
    var thinking: String?
    /// Set on a `role:"tool"` message when the tool failed (timeout / throw /
    /// unknown / invalid args). Carried through so providers that distinguish
    /// errored tool results (e.g. Anthropic's `is_error`) can flag them, and the
    /// PR8 chat UI can render error tool cards. nil/false on success.
    var isError: Bool?
    var createdAt: Double   // epoch seconds

    init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        toolCalls: [ChatToolCall]? = nil,
        toolCallId: String? = nil,
        thinking: String? = nil,
        isError: Bool? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.thinking = thinking
        self.isError = isError
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try c.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }
}

/// A persisted conversation. Every PopDraft invocation becomes one of these — a
/// captured selection plus the resulting exchange — which can later be reopened
/// and continued as a chat.
struct ChatSession: Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var model: String?
    var selectedText: String?
    var messages: [ChatMessage]

    init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970,
        model: String? = nil,
        selectedText: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.selectedText = selectedText
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date().timeIntervalSince1970
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
        model = try c.decodeIfPresent(String.self, forKey: .model)
        selectedText = try c.decodeIfPresent(String.self, forKey: .selectedText)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }

    /// Derive a short, single-line, ~40-char title from the first user message
    /// (or the captured selection), falling back to a timestamp-based title.
    static func deriveTitle(
        firstUserMessage: String?,
        selectedText: String?,
        createdAt: Double = Date().timeIntervalSince1970,
        maxLength: Int = 40
    ) -> String {
        let candidates = [firstUserMessage, selectedText]
        for raw in candidates {
            guard let raw = raw else { continue }
            let oneLine = raw
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            // Collapse runs of whitespace to single spaces.
            let collapsed = oneLine.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count <= maxLength { return trimmed }
            let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
            return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
        }
        // Fallback: timestamp-based title.
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Chat \(formatter.string(from: Date(timeIntervalSince1970: createdAt)))"
    }

    /// Recompute `title` from the session's own first user message / selectedText.
    mutating func refreshTitle() {
        let firstUser = messages.first(where: { $0.role == "user" })?.content
        title = ChatSession.deriveTitle(
            firstUserMessage: firstUser,
            selectedText: selectedText,
            createdAt: createdAt
        )
    }

    /// True when the session has something worth saving: at least one user turn
    /// AND one non-empty assistant turn. Empty / aborted sessions return false.
    var hasMeaningfulExchange: Bool {
        let hasUser = messages.contains { $0.role == "user" }
        let hasAssistant = messages.contains {
            $0.role == "assistant" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasUser && hasAssistant
    }
}

// MARK: - Session summary (lightweight listing)

/// A lightweight view of a session for menus/lists — avoids decoding every
/// message just to show a title.
struct SessionSummary: Codable, Equatable {
    var id: String
    var title: String
    var updatedAt: Double
}

// MARK: - Session persistence

/// Persists `ChatSession`s as one pretty-printed `<id>.json` per session under
/// `<dir>/sessions/` (default `~/.popdraft/sessions/`). `dir` is injectable so
/// tests can point it at a temp directory. Foundation only — fully unit-tested.
struct SessionStore {
    /// The PARENT directory (e.g. `~/.popdraft`). Sessions live in `<dir>/sessions/`.
    let dir: String

    init(dir: String) {
        self.dir = dir
    }

    /// The `<dir>/sessions/` directory where the per-session JSON files live.
    var sessionsDir: String {
        return (dir as NSString).appendingPathComponent("sessions")
    }

    private func path(for id: String) -> String {
        return (sessionsDir as NSString).appendingPathComponent("\(id).json")
    }

    /// Write a session to `<dir>/sessions/<id>.json` (pretty-printed, atomic).
    @discardableResult
    func save(_ session: ChatSession) -> Bool {
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path(for: session.id)), options: .atomic)) != nil
    }

    /// Load a single session by id, or nil if missing / unreadable / corrupt.
    func load(id: String) -> ChatSession? {
        guard let data = FileManager.default.contents(atPath: path(for: id)) else { return nil }
        return try? JSONDecoder().decode(ChatSession.self, from: data)
    }

    /// List all sessions as lightweight summaries, sorted by `updatedAt` descending.
    /// Tolerates unreadable / corrupt files (they're skipped, never crash).
    func list() -> [SessionSummary] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }
        var summaries: [SessionSummary] = []
        for name in names where name.hasSuffix(".json") {
            let full = (sessionsDir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: full),
                  let session = try? JSONDecoder().decode(ChatSession.self, from: data) else {
                continue
            }
            summaries.append(SessionSummary(id: session.id, title: session.title, updatedAt: session.updatedAt))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Delete a session file by id. No-op if it doesn't exist.
    @discardableResult
    func delete(id: String) -> Bool {
        return (try? FileManager.default.removeItem(atPath: path(for: id))) != nil
    }
}

// =====================================================================
// MARK: - PR6: Web Engine (pure logic)
//
// Everything below is Foundation-only (NO WebKit / AppKit) so it is unit-
// tested by `tests/test-webengine-core.swift` with no network and no GUI.
// The WebKit-backed orchestration (RendererPool, WebEngine, screenshots)
// lives in PopDraft.swift and calls into these helpers.
// =====================================================================

// MARK: Public value types (shared by Core + PopDraft + tests)

/// One web search hit.
struct SearchResult: Codable, Equatable {
    var title: String
    var url: String
    var snippet: String

    init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// A search request. `maxResults` is advisory; providers may return fewer.
struct SearchQuery: Equatable {
    var query: String
    var maxResults: Int

    init(query: String, maxResults: Int = 8) {
        self.query = query
        self.maxResults = maxResults
    }
}

/// Result of `WebEngine.open` — a light "did it load, what is it" probe.
struct OpenResult: Codable, Equatable {
    var finalURL: String
    var status: Int
    var title: String
    var preview: String      // first ~500 chars of cleaned text
}

/// Result of `WebEngine.read` — sanitized article Markdown.
struct ReadResult: Codable, Equatable {
    var finalURL: String
    var status: Int
    var title: String
    var byline: String?
    var siteName: String?
    var markdown: String
    var charCount: Int
    var truncated: Bool
}

/// Result of `WebEngine.screenshot` — a PNG written to disk.
struct ShotResult: Codable, Equatable {
    var finalURL: String
    var path: String
    var width: Int
    var height: Int
    var fullPage: Bool
}

/// One relevant chunk returned by `WebEngine.extract`.
struct ExtractChunk: Codable, Equatable {
    var text: String
    var score: Double
}

/// Result of `WebEngine.extract` — top relevant chunks for an instruction.
struct ExtractResult: Codable, Equatable {
    var finalURL: String
    var title: String
    var instruction: String
    var chunks: [ExtractChunk]
}

/// One clickable element / input surfaced in the DOM-accessibility summary the
/// agent reads to decide what to click or type into.
struct BrowserElement: Codable, Equatable {
    var role: String      // "link" | "button" | "input" | "textarea" | "select"
    var label: String     // visible text / value / placeholder / aria-label
    var selector: String? // a stable CSS selector the agent can pass back as `target`
}

/// Snapshot of the persistent browsing session after an action. Returned by
/// every `browser_*` tool so the agent always sees where it is and what it can
/// do next. `action` describes what just happened (e.g. "clicked link 'Foo'").
struct BrowserState: Codable, Equatable {
    var finalURL: String
    var title: String
    var action: String          // human-readable description of the last action
    var summary: String         // short readable text snapshot of the page
    var elements: [BrowserElement]   // clickable elements / inputs (capped)

    init(finalURL: String, title: String, action: String,
         summary: String = "", elements: [BrowserElement] = []) {
        self.finalURL = finalURL
        self.title = title
        self.action = action
        self.summary = summary
        self.elements = elements
    }
}

// MARK: - Browser target resolution (pure, unit-tested)

/// Pure helpers for the interactive browser tools. Kept Foundation-only so they
/// are unit-tested without WebKit. The actual DOM lookup runs in bundled JS
/// (`BrowserJS`); these helpers (a) decide whether a target string is a CSS
/// selector vs. visible text, and (b) safely JSON-encode any agent-supplied
/// string for embedding into a bundled script — so a page never contributes a
/// raw string to the JS we evaluate.
enum BrowserTargets {
    /// Heuristic: does `target` look like a CSS selector (vs. plain visible text)?
    /// Selectors start with `#`, `.`, `[`, or are a bare tag/attribute pattern
    /// containing selector punctuation but no inner whitespace. Plain words like
    /// "Sign in" are treated as visible text.
    static func looksLikeSelector(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        // Obvious selector anchors.
        if t.hasPrefix("#") || t.hasPrefix(".") || t.hasPrefix("[") { return true }
        // Has selector punctuation AND no inner whitespace → selector-ish
        // (e.g. "input[name=q]", "button.primary", "a#main", "div>span").
        let hasSelPunct = t.contains("[") || t.contains("#") || t.contains(".")
            || t.contains(">") || t.contains("=")
        let hasSpace = t.contains(" ")
        if hasSelPunct && !hasSpace { return true }
        return false
    }

    /// JSON-encode an arbitrary string as a JS string literal (with surrounding
    /// quotes). Used to embed agent-supplied targets/text into a bundled script
    /// WITHOUT string concatenation of raw page/user text. Falls back to an empty
    /// JS string literal if encoding somehow fails (never returns invalid JS).
    static func jsString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s),
           let lit = String(data: data, encoding: .utf8) {
            return lit
        }
        return "\"\""
    }

    /// Build the JS argument object literal `{target:..., asSelector:..., text:...}`
    /// from agent input, with every string JSON-encoded. `text` is optional (used
    /// by type). The returned literal is safe to splice into a bundled function
    /// call: only structural punctuation we control plus JSON string literals.
    static func argLiteral(target: String, text: String? = nil) -> String {
        let sel = looksLikeSelector(target)
        var parts = [
            "target: \(jsString(target))",
            "asSelector: \(sel ? "true" : "false")",
        ]
        if let text = text {
            parts.append("text: \(jsString(text))")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}

/// Errors surfaced by the web engine. `String`-bearing cases carry detail for tools.
enum WebEngineError: Error, Equatable, CustomStringConvertible {
    case blockedScheme(String)
    case blockedHost(String)          // SSRF: resolved to a private/loopback/metadata IP
    case invalidURL(String)
    case navigationFailed(String)
    case timeout
    case tooLarge(Int)                // exceeded webMaxBytes
    case renderProcessCrashed
    case noContent
    case searchFailed(String)

    var description: String {
        switch self {
        case .blockedScheme(let s): return "Blocked URL scheme: \(s)"
        case .blockedHost(let h): return "Blocked host (SSRF / private address): \(h)"
        case .invalidURL(let u): return "Invalid URL: \(u)"
        case .navigationFailed(let m): return "Navigation failed: \(m)"
        case .timeout: return "Navigation timed out"
        case .tooLarge(let n): return "Response too large: \(n) bytes"
        case .renderProcessCrashed: return "Web content process crashed"
        case .noContent: return "No readable content found"
        case .searchFailed(let m): return "Search failed: \(m)"
        }
    }
}

// MARK: - SafetyGuard (SSRF + scheme allowlist)

/// SSRF / scheme defenses. Everything that takes only a hostname/IP/scheme string
/// is pure and unit-tested; the DNS-resolving entry point (`isSafe(url:)`) is a
/// thin wrapper used by the engine before any navigation and on every redirect.
enum SafetyGuard {

    /// Schemes the engine is willing to navigate to. `about:blank` is allowed
    /// separately (see `isSchemeAllowed`). Everything else (file/ftp/data/...) is rejected.
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// TEST-ONLY loopback escape hatch. The GUI test suite serves fixtures on a
    /// random loopback port; those URLs would normally be blocked as SSRF. When
    /// the env var `PD_WEB_ALLOW_LOOPBACK_PORT=<port>` is set (only ever set by
    /// `tests/run-tests.sh`), `http://127.0.0.1:<port>` is permitted. This is
    /// read from the environment so the shipping app — which never sets it —
    /// keeps full SSRF protection. Returns the allowed port, or nil.
    static func allowedLoopbackTestPort() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["PD_WEB_ALLOW_LOOPBACK_PORT"],
              let p = Int(raw), p > 0 else { return nil }
        return p
    }

    /// True when a host:port is the explicitly-allowlisted loopback test target.
    static func isTestLoopback(host: String, port: Int?) -> Bool {
        guard let allowed = allowedLoopbackTestPort(), let port = port, port == allowed else { return false }
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }

    /// Whether a URL's scheme is allowed. Special-cases `about:blank` (used to
    /// reset a recycled webview) while blocking every other `about:` target,
    /// and blocks `file:`, `ftp:`, `data:`, `javascript:`, etc.
    static func isSchemeAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" {
            // Only about:blank is permitted.
            return url.absoluteString.lowercased() == "about:blank"
        }
        return allowedSchemes.contains(scheme)
    }

    /// Classify a literal IP string (v4 or v6). Returns true if the address is
    /// one we must refuse to fetch: loopback, RFC1918, link-local, ULA, the
    /// unspecified address, or the cloud metadata endpoint.
    static func isBlockedIP(_ ip: String) -> Bool {
        let s = ip.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return true }
        // Strip a zone id (e.g. "fe80::1%en0") and brackets.
        let noZone = s.split(separator: "%").first.map(String.init) ?? s
        let bare = noZone.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if let v4 = parseIPv4(bare) {
            return isBlockedIPv4(v4)
        }
        if let v6 = parseIPv6(bare) {
            return isBlockedIPv6(v6)
        }
        // Unparseable as an IP — treat as not-an-IP (host-name path handles it).
        return false
    }

    /// Parse a dotted-quad IPv4 into 4 octets, or nil.
    ///
    /// Decimal-only and canonical: a leading-zero octet (`0177`, `010`) or a
    /// hex octet (`0x7f`) returns nil so the literal is NOT classified here as a
    /// bare IPv4. This matters for the SSRF guard: `inet_aton` (used by
    /// CFNetwork/WebKit) reads `0177.0.0.1` as OCTAL → `127.0.0.1` (loopback),
    /// whereas a naive `Int("0177")` reads decimal 177 (a public address). By
    /// rejecting such forms we avoid mis-classifying them as public; they fall
    /// through to `getaddrinfo`, which canonicalizes them correctly and lets the
    /// resolved-IP check block the real (loopback) destination.
    static func parseIPv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber }) else { return nil }
            // Reject non-canonical octets that other resolvers read as octal/hex:
            // a leading zero with more digits (`0177`, `010`) or any `0x`/`0X`
            // prefix. `"0"` itself is fine. (allSatisfy isNumber already excludes
            // the `x`, but keep the check explicit and future-proof.)
            if p.count > 1 && p.first == "0" { return nil }
            let lower = p.lowercased()
            if lower.hasPrefix("0x") { return nil }
            guard let n = Int(p), n >= 0, n <= 255 else { return nil }
            octets.append(n)
        }
        return octets
    }

    /// True for blocked IPv4 ranges.
    static func isBlockedIPv4(_ o: [Int]) -> Bool {
        guard o.count == 4 else { return true }
        // 0.0.0.0/8 (incl. the unspecified 0.0.0.0)
        if o[0] == 0 { return true }
        // 127.0.0.0/8 loopback
        if o[0] == 127 { return true }
        // 10.0.0.0/8 RFC1918
        if o[0] == 10 { return true }
        // 172.16.0.0/12 RFC1918
        if o[0] == 172 && (o[1] >= 16 && o[1] <= 31) { return true }
        // 192.168.0.0/16 RFC1918
        if o[0] == 192 && o[1] == 168 { return true }
        // 169.254.0.0/16 link-local (incl. 169.254.169.254 cloud metadata)
        if o[0] == 169 && o[1] == 254 { return true }
        // 100.64.0.0/10 CGNAT (shared address space)
        if o[0] == 100 && (o[1] >= 64 && o[1] <= 127) { return true }
        return false
    }

    /// Parse an IPv6 string into 8 16-bit groups (supports `::` compression and
    /// a trailing embedded IPv4). Returns nil if not a valid IPv6 literal.
    static func parseIPv6(_ s: String) -> [Int]? {
        if !s.contains(":") { return nil }
        var str = s
        // Handle embedded IPv4 tail (e.g. ::ffff:1.2.3.4).
        if let lastColon = str.lastIndex(of: ":"), str[str.index(after: lastColon)...].contains(".") {
            let tail = String(str[str.index(after: lastColon)...])
            guard let v4 = parseIPv4(tail) else { return nil }
            let hi = (v4[0] << 8) | v4[1]
            let lo = (v4[2] << 8) | v4[3]
            str = String(str[..<str.index(after: lastColon)])
                + String(format: "%x:%x", hi, lo)
        }

        let halves = str.components(separatedBy: "::")
        if halves.count > 2 { return nil }

        func groups(_ part: String) -> [Int]? {
            if part.isEmpty { return [] }
            var out: [Int] = []
            for g in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard !g.isEmpty, g.count <= 4,
                      let v = Int(g, radix: 16), v >= 0, v <= 0xFFFF else { return nil }
                out.append(v)
            }
            return out
        }

        if halves.count == 2 {
            guard let head = groups(halves[0]), let tail = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - tail.count
            guard fill >= 0 else { return nil }
            return head + Array(repeating: 0, count: fill) + tail
        } else {
            guard let all = groups(halves[0]), all.count == 8 else { return nil }
            return all
        }
    }

    /// True for blocked IPv6 ranges.
    static func isBlockedIPv6(_ g: [Int]) -> Bool {
        guard g.count == 8 else { return true }
        // :: unspecified
        if g.allSatisfy({ $0 == 0 }) { return true }
        // ::1 loopback
        if g[0...6].allSatisfy({ $0 == 0 }) && g[7] == 1 { return true }
        // fe80::/10 link-local
        if (g[0] & 0xFFC0) == 0xFE80 { return true }
        // fc00::/7 unique-local (fc.. / fd..)
        if (g[0] & 0xFE00) == 0xFC00 { return true }
        // ::ffff:a.b.c.d  IPv4-mapped — re-check the embedded v4.
        if g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[4] == 0, g[5] == 0xFFFF {
            let o = [(g[6] >> 8) & 0xFF, g[6] & 0xFF, (g[7] >> 8) & 0xFF, g[7] & 0xFF]
            return isBlockedIPv4(o)
        }
        return false
    }

    /// A literal-host check that does NOT resolve DNS: if the host is already an
    /// IP literal, classify it; if it's a name that is obviously local
    /// (`localhost`, `*.local`, `*.internal`), block it too. Names that need DNS
    /// are deferred to the resolving caller (`isSafe`).
    static func isLiteralHostBlocked(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        if h.isEmpty { return true }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }
        // If it parses as an IP literal, classify it.
        if parseIPv4(h) != nil || parseIPv6(h) != nil {
            return isBlockedIP(h)
        }
        return false
    }

    // MARK: - Connection-level IP pinning (PR11)

    /// Outcome of pinning a host to a single validated public IP. Either a chosen
    /// address to dial (and ONLY that address may be dialed) or a block reason.
    enum PinResult: Equatable {
        case allowed(String)        // the picked public IP literal to dial
        case blocked(String)        // human-readable reason (host -> ip, "no addresses", ...)
    }

    /// Pure pinning decision: given the set of addresses a host resolved to,
    /// FAIL CLOSED — reject if there are zero addresses OR if ANY address is
    /// blocked (loopback / RFC1918 / link-local / ULA / metadata / 0.0.0.0). When
    /// every address is public, pick ONE deterministically (the first by stable
    /// order) so the proxy dials only that validated IP and WebKit never resolves
    /// the host itself → DNS-rebinding is closed.
    ///
    /// `allowTestLoopback` lets the GUI test suite (which serves fixtures on a
    /// loopback port) pin to a loopback address — only ever true when the
    /// env-gated test hook is active; the shipping app passes false.
    static func pinnedAddress(forResolved addrs: [String], allowTestLoopback: Bool = false) -> PinResult {
        let cleaned = addrs
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .blocked("no addresses") }

        if allowTestLoopback {
            // Test path: every address must be loopback (and otherwise valid). We
            // still require ALL to be loopback so a mixed set isn't silently OK.
            for ip in cleaned {
                let isLoopback = (parseIPv4(ip).map { $0.count == 4 && $0[0] == 127 } ?? false)
                    || (parseIPv6(ip).map { g in g.count == 8 && g[0...6].allSatisfy { $0 == 0 } && g[7] == 1 } ?? false)
                if !isLoopback { return .blocked("test-loopback expected but got \(ip)") }
            }
            return .allowed(cleaned[0])
        }

        // Production: require EVERY resolved address to be public, then pin one.
        for ip in cleaned where isBlockedIP(ip) {
            return .blocked(ip)
        }
        // Prefer the first IPv4 (broader reachability), else the first address.
        if let v4 = cleaned.first(where: { parseIPv4($0) != nil }) {
            return .allowed(v4)
        }
        return .allowed(cleaned[0])
    }
}

// MARK: - Forward-proxy request parsing (PR11 IP-pinning proxy)

/// Pure parsers for the bytes the localhost pinning proxy receives from WKWebView.
/// No network — just request-line / header extraction so the proxy logic is unit
/// testable. WKWebView speaks standard HTTP-proxy framing:
///   - HTTPS: `CONNECT host:port HTTP/1.1` then a blank line, then opaque TLS.
///   - plain HTTP: `GET http://host/path HTTP/1.1` (absolute-form) + `Host:` header.
enum ProxyParser {

    /// A parsed CONNECT target (the host:port the client wants tunneled).
    struct ConnectTarget: Equatable {
        var host: String
        var port: Int
    }

    /// Parse a `CONNECT host:port HTTP/1.1` request line. Returns nil if it is not
    /// a well-formed CONNECT (wrong method, missing port, garbage). Default port is
    /// rejected (CONNECT must carry an explicit port) to avoid ambiguity.
    static func parseConnect(_ requestLine: String) -> ConnectTarget? {
        let line = requestLine.trimmingCharacters(in: .whitespaces)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else { return nil }
        return splitHostPort(parts[1], defaultPort: nil)
    }

    /// Split an authority `host:port` (or bracketed IPv6 `[::1]:443`) into parts.
    /// `defaultPort` is used when no `:port` is present; if nil and no port is
    /// given, returns nil (caller requires an explicit port).
    static func splitHostPort(_ authority: String, defaultPort: Int?) -> ConnectTarget? {
        let s = authority.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Bracketed IPv6 literal: [host]:port  or  [host]
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = s[s.index(after: close)...]
            if rest.isEmpty {
                guard let dp = defaultPort else { return nil }
                return ConnectTarget(host: host, port: dp)
            }
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()), p > 0, p <= 65535 else { return nil }
            return ConnectTarget(host: host, port: p)
        }
        // Unbracketed: a bare IPv6 (multiple colons) has no port here.
        let colonCount = s.filter { $0 == ":" }.count
        if colonCount > 1 {
            // Bare IPv6 literal without brackets → no explicit port.
            guard let dp = defaultPort else { return nil }
            return ConnectTarget(host: s, port: dp)
        }
        if colonCount == 1 {
            let comps = s.split(separator: ":", maxSplits: 1).map(String.init)
            guard comps.count == 2, !comps[0].isEmpty,
                  let p = Int(comps[1]), p > 0, p <= 65535 else { return nil }
            return ConnectTarget(host: comps[0], port: p)
        }
        // No colon → host only.
        guard let dp = defaultPort else { return nil }
        return ConnectTarget(host: s, port: dp)
    }

    /// A parsed plain-HTTP proxy request: method, the target host:port to dial,
    /// the origin-form path to send upstream, and the HTTP version token.
    struct HTTPTarget: Equatable {
        var method: String
        var host: String
        var port: Int
        var path: String        // origin-form path+query to send to the upstream
        var version: String
    }

    /// Parse a plain-HTTP proxy request line in absolute-form
    /// (`GET http://host:port/path HTTP/1.1`). Returns nil for CONNECT, for a
    /// non-http scheme, or anything malformed. Falls back to `hostHeader` for the
    /// authority if the request-line is origin-form (some clients send that with a
    /// Host header even to a proxy).
    static func parseHTTP(requestLine: String, hostHeader: String?) -> HTTPTarget? {
        let line = requestLine.trimmingCharacters(in: .whitespaces)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { return nil }
        let method = parts[0].uppercased()
        guard method != "CONNECT" else { return nil }
        let target = parts[1]
        let version = parts[2]
        guard version.hasPrefix("HTTP/") else { return nil }

        // Absolute-form: scheme://authority/path
        if let schemeRange = target.range(of: "://") {
            let scheme = target[target.startIndex..<schemeRange.lowerBound].lowercased()
            guard scheme == "http" else { return nil }   // https never arrives plain
            let rest = String(target[schemeRange.upperBound...])
            // Authority is up to the first '/', '?' or end.
            let authEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
            let authority = String(rest[rest.startIndex..<authEnd])
            guard let hp = splitHostPort(authority, defaultPort: 80) else { return nil }
            var path = String(rest[authEnd...])
            if path.isEmpty { path = "/" }
            return HTTPTarget(method: method, host: hp.host, port: hp.port, path: path, version: version)
        }

        // Origin-form (path only) + Host header.
        guard target.hasPrefix("/"), let hostHeader = hostHeader,
              let hp = splitHostPort(hostHeader, defaultPort: 80) else { return nil }
        return HTTPTarget(method: method, host: hp.host, port: hp.port, path: target, version: version)
    }

    /// Extract the value of a header (case-insensitive) from a raw header block
    /// (the lines after the request line, CRLF-separated). Returns nil if absent.
    static func header(_ name: String, in headerLines: [String]) -> String? {
        let want = name.lowercased()
        for line in headerLines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == want {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

// MARK: - URL cleaning (tracking-param stripping)

enum URLCleaner {
    /// Query params we strip from links before returning them (analytics noise).
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_reader", "utm_name", "utm_social", "utm_brand",
        "gclid", "fbclid", "dclid", "gclsrc", "msclkid", "yclid",
        "mc_cid", "mc_eid", "igshid", "vero_id", "vero_conv",
        "_hsenc", "_hsmi", "mkt_tok", "ref", "ref_src", "ref_url",
        "spm", "scm", "_openstat", "wt_mc", "trk", "trkCampaign",
    ]

    /// Remove tracking query params from a URL string. Preserves order of the
    /// remaining params, drops a trailing "?" when nothing is left, and leaves
    /// non-http(s) / unparseable strings unchanged.
    static func strip(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        guard let items = comps.queryItems, !items.isEmpty else { return urlString }
        let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
        comps.queryItems = kept.isEmpty ? nil : kept
        // Avoid a dangling "?".
        if kept.isEmpty { comps.query = nil }
        return comps.string ?? urlString
    }
}

// MARK: - DuckDuckGo "lite" / "html" result parsing

enum DDGParser {
    /// Decode DDG's `uddg` redirect param into the real destination URL.
    /// DDG links look like `/l/?uddg=https%3A%2F%2Fexample.com%2F&rut=...`.
    /// Returns nil if there's no usable `uddg`.
    static func decodeRedirect(_ href: String) -> String? {
        // Build absolute so URLComponents can parse a root-relative href.
        let abs = href.hasPrefix("http") ? href : "https://duckduckgo.com" + (href.hasPrefix("/") ? href : "/" + href)
        guard let comps = URLComponents(string: abs),
              let items = comps.queryItems,
              let uddg = items.first(where: { $0.name == "uddg" })?.value,
              !uddg.isEmpty else {
            return nil
        }
        // URLComponents already percent-decodes the value.
        return uddg
    }

    /// Extract an HTML attribute value from a tag's attribute string, tolerating
    /// single- OR double-quoted values (DDG lite uses single quotes on `class`,
    /// double on `href`). Returns nil if the attribute is absent.
    static func attrValue(_ name: String, in attrs: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = attrs as NSString
        guard let m = re.firstMatch(in: attrs, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound { return ns.substring(with: r) }
        }
        return nil
    }

    /// Parse the HTML body of the DDG **lite** endpoint into results.
    /// The lite page is a flat table: result rows have an `<a ... class="result-link">`
    /// (the title+link) followed by a snippet cell with `class="result-snippet"`.
    /// We parse defensively with regex (no HTML lib) and tolerate format drift.
    ///
    /// As of 2026 the lite endpoint emits DIRECT hrefs on `class='result-link'`
    /// anchors (e.g. `<a href="https://example.com" class='result-link'>`) — it
    /// no longer wraps them in a `/l/?uddg=` redirect. It also uses SINGLE quotes
    /// on its `class` attributes. So we accept a result anchor when EITHER:
    ///   (a) its `class` contains `result-link` (single OR double quoted), or
    ///   (b) its href decodes a `uddg` redirect (older markup / html endpoint).
    static func parseLite(_ html: String, maxResults: Int = 10) -> [SearchResult] {
        var results: [SearchResult] = []
        // Capture the whole opening `<a ...>` tag (group 1) and the link text
        // (group 2). We pull href/class out of the tag separately so quoting
        // (single vs double) and attribute ordering don't matter.
        let anchorPattern = "<a\\b([^>]*)>(.*?)</a>"
        guard let re = try? NSRegularExpression(pattern: anchorPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        let matches = re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))

        // Build a list of (url, title, anchorStart, anchorEnd) for result anchors.
        var anchors: [(url: String, title: String, start: Int, end: Int)] = []
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let attrs = ns.substring(with: m.range(at: 1))
            guard let href = attrValue("href", in: attrs) else { continue }
            let cls = attrValue("class", in: attrs) ?? ""
            let isResultLink = cls.range(of: "result-link", options: .caseInsensitive) != nil
            // Resolve the real destination: a uddg redirect decodes to its target;
            // otherwise (new lite markup) the href IS the destination when it's a
            // result-link anchor pointing at an absolute http(s) URL.
            let real: String?
            if let decoded = decodeRedirect(href) {
                real = decoded
            } else if isResultLink, href.hasPrefix("http") {
                real = href
            } else {
                real = nil
            }
            guard let dest = real, !dest.isEmpty else { continue }
            let rawTitle = ns.substring(with: m.range(at: 2))
            let title = stripTags(rawTitle)
            guard !title.isEmpty else { continue }
            anchors.append((url: URLCleaner.strip(dest), title: title,
                            start: m.range.location, end: m.range.location + m.range.length))
        }

        // For each result anchor, grab a result-snippet block — but ONLY one that
        // falls strictly BEFORE the next result anchor, so a result with no
        // snippet of its own can't borrow the following result's snippet. The
        // class attribute may be single- OR double-quoted, hence `['\"]`.
        let snippetPattern = "class=['\"]result-snippet['\"][^>]*>(.*?)</td>"
        let snippetRe = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])

        var snippetRanges: [(text: String, start: Int)] = []
        if let snippetRe = snippetRe {
            for m in snippetRe.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 2 {
                let raw = ns.substring(with: m.range(at: 1))
                snippetRanges.append((text: stripTags(raw), start: m.range.location))
            }
        }

        for (i, a) in anchors.enumerated() {
            // Upper bound = start of the next anchor (or end-of-document).
            let nextStart = (i + 1 < anchors.count) ? anchors[i + 1].start : ns.length
            let snippet = snippetRanges.first(where: { $0.start >= a.end && $0.start < nextStart })?.text ?? ""
            // Dedupe by exact URL within this page.
            if results.contains(where: { $0.url == a.url }) { continue }
            results.append(SearchResult(title: a.title, url: a.url, snippet: snippet))
            if results.count >= maxResults { break }
        }
        return results
    }

    /// Parse the JSON array string produced by `WebJS.serpExtractScript` (the
    /// browse-the-SERP fallback) into `[SearchResult]`. Tolerant: bad/empty
    /// input yields []. URLs are normalized through `URLCleaner.strip`.
    static func parseSERPJSON(_ json: String, maxResults: Int = 10) -> [SearchResult] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var results: [SearchResult] = []
        var seen = Set<String>()
        for obj in arr {
            guard let rawURL = obj["url"] as? String, !rawURL.isEmpty,
                  rawURL.hasPrefix("http") else { continue }
            let title = (obj["title"] as? String) ?? ""
            guard !title.isEmpty else { continue }
            let url = URLCleaner.strip(rawURL)
            if seen.contains(url) { continue }
            seen.insert(url)
            let snippet = (obj["snippet"] as? String) ?? ""
            results.append(SearchResult(title: title, url: url, snippet: snippet))
            if results.count >= maxResults { break }
        }
        return results
    }

    /// Strip HTML tags + decode a small set of entities, collapse whitespace.
    static func stripTags(_ s: String) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            out = re.stringByReplacingMatches(in: out, options: [], range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        }
        out = decodeEntities(out)
        let collapsed = out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the handful of HTML entities DDG actually emits.
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
            ("&nbsp;", " "), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

// MARK: - Markdown truncation / sanitization

enum MarkdownSanitizer {
    /// Collapse 3+ blank lines to 2; trim trailing spaces on every line.
    static func collapseWhitespace(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n").map { line -> String in
            // rstrip
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }
        // Collapse runs of >2 blank lines.
        var out: [String] = []
        var blankRun = 0
        for l in lines {
            if l.isEmpty {
                blankRun += 1
                if blankRun <= 2 { out.append(l) }
            } else {
                blankRun = 0
                out.append(l)
            }
        }
        lines = out
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncate Markdown to at most `maxChars`, preferring a paragraph boundary
    /// (a blank line) at or before the limit; falls back to a sentence then a
    /// hard cut. Returns (text, truncated).
    static func truncate(_ md: String, maxChars: Int) -> (String, Bool) {
        if md.count <= maxChars { return (md, false) }
        let prefix = String(md.prefix(maxChars))

        // 1) Prefer the last paragraph break ("\n\n") inside the prefix.
        if let r = prefix.range(of: "\n\n", options: .backwards) {
            let cut = String(prefix[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only accept if we keep a reasonable chunk (avoid truncating to almost nothing).
            if cut.count >= maxChars / 2 {
                return (cut + "\n\n…", true)
            }
        }
        // 2) Fall back to the last sentence end.
        let sentenceEnders = CharacterSet(charactersIn: ".!?")
        if let idx = prefix.unicodeScalars.lastIndex(where: { sentenceEnders.contains($0) }) {
            let endStr = prefix.unicodeScalars[...idx]
            let cut = String(String.UnicodeScalarView(endStr)).trimmingCharacters(in: .whitespacesAndNewlines)
            if cut.count >= maxChars / 2 {
                return (cut + " …", true)
            }
        }
        // 3) Hard cut at the last space, else exact.
        if let space = prefix.range(of: " ", options: .backwards) {
            return (String(prefix[..<space.lowerBound]) + " …", true)
        }
        return (prefix + "…", true)
    }
}

// MARK: - Size-cap logic

enum SizeGuard {
    /// True when `received` bytes exceed the configured cap. Pure so the engine's
    /// streaming/`Content-Length` checks share one rule.
    static func exceeds(received: Int, max: Int) -> Bool {
        return received > max
    }

    /// Given an optional `Content-Length`, decide whether to reject up-front.
    static func rejectByContentLength(_ contentLength: Int?, max: Int) -> Bool {
        guard let len = contentLength else { return false }
        return len > max
    }
}

// MARK: - Keyword / BM25-ish chunk ranking (for extract)

enum ChunkRanker {
    /// Split Markdown into reasonably sized chunks on paragraph boundaries,
    /// merging tiny ones so each chunk is roughly `targetChars` long.
    static func chunk(_ markdown: String, targetChars: Int = 700) -> [String] {
        let paras = markdown.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var cur = ""
        for p in paras {
            if cur.isEmpty {
                cur = p
            } else if cur.count + p.count + 2 <= targetChars {
                cur += "\n\n" + p
            } else {
                chunks.append(cur)
                cur = p
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    /// Common English stopwords filtered out before ranking so a query word like
    /// "are" / "in" / "what" can't make an off-topic chunk score highly.
    static let stopwords: Set<String> = [
        "the", "an", "and", "or", "but", "of", "to", "in", "on", "at", "by",
        "for", "with", "as", "is", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "you", "he", "she",
        "we", "they", "them", "his", "her", "their", "what", "which", "who",
        "whom", "how", "when", "where", "why", "do", "does", "did", "can", "could",
        "would", "should", "will", "shall", "may", "might", "must", "have", "has",
        "had", "not", "no", "yes", "from", "into", "about", "than", "then", "so",
        "if", "there", "here", "out", "up", "down", "over", "under", "some", "any",
        "all", "each", "more", "most", "other", "such", "only", "own", "same",
    ]

    /// Lowercase, split on non-alphanumerics into tokens >= 2 chars, dropping
    /// stopwords so ranking keys on content words.
    static func tokenize(_ s: String) -> [String] {
        let lower = s.lowercased()
        var token = ""
        var tokens: [String] = []
        func flush() {
            if token.count >= 2 && !stopwords.contains(token) { tokens.append(token) }
            token = ""
        }
        for ch in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                token.unicodeScalars.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Rank `chunks` by BM25 against the `instruction` query. Returns the top
    /// `limit` as (chunk, score) sorted by score desc. Deterministic.
    static func rank(chunks: [String], instruction: String, limit: Int = 5) -> [ExtractChunk] {
        guard !chunks.isEmpty else { return [] }
        let queryTerms = Array(Set(tokenize(instruction)))
        // No usable query → return the leading chunks (still useful context).
        if queryTerms.isEmpty {
            return chunks.prefix(limit).map { ExtractChunk(text: $0, score: 0) }
        }

        let docs = chunks.map { tokenize($0) }
        let n = Double(docs.count)
        let avgLen = docs.reduce(0.0) { $0 + Double($1.count) } / n

        // Document frequency per query term.
        var df: [String: Int] = [:]
        for term in queryTerms {
            var count = 0
            for d in docs where d.contains(term) { count += 1 }
            df[term] = count
        }

        let k1 = 1.5, b = 0.75
        var scored: [(idx: Int, score: Double)] = []
        for (i, d) in docs.enumerated() {
            // Term frequencies in this doc.
            var tf: [String: Int] = [:]
            for t in d { tf[t, default: 0] += 1 }
            let dl = Double(d.count)
            var score = 0.0
            for term in queryTerms {
                let f = Double(tf[term] ?? 0)
                if f == 0 { continue }
                let nq = Double(df[term] ?? 0)
                // BM25 idf (with +1 to stay positive).
                let idf = log(1 + (n - nq + 0.5) / (nq + 0.5))
                let denom = f + k1 * (1 - b + b * (dl / max(avgLen, 1)))
                score += idf * (f * (k1 + 1)) / denom
            }
            scored.append((i, score))
        }
        // Sort by score desc, tie-break by original order (stable).
        let ordered = scored.enumerated().sorted {
            if $0.element.score != $1.element.score { return $0.element.score > $1.element.score }
            return $0.offset < $1.offset
        }
        return ordered.prefix(limit)
            .filter { $0.element.score > 0 }
            .map { ExtractChunk(text: chunks[$0.element.idx], score: $0.element.score) }
    }
}

// MARK: - OpenAI-style tool JSON-Schema constants (for PR7 to register)

/// JSON-Schema tool specs in the OpenAI function-tool shape. These are plain
/// strings (validated as JSON in tests) so PR7 can register them verbatim with
/// any OpenAI-compatible `tools` array. Kept in Core.swift so tests can assert
/// they parse without pulling in WebKit.
enum WebToolSchemas {
    static let webSearch = """
    {
      "type": "function",
      "function": {
        "name": "web_search",
        "description": "Search the web and return a list of results (title, url, snippet). Use for finding pages relevant to a question before reading them.",
        "parameters": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "The search query." },
            "max_results": { "type": "integer", "description": "Maximum number of results to return (1-10).", "default": 8 }
          },
          "required": ["query"]
        }
      }
    }
    """

    static let webOpen = """
    {
      "type": "function",
      "function": {
        "name": "web_open",
        "description": "Open a URL and return its final URL, HTTP status, title, and a short text preview. Lightweight check that a page loads.",
        "parameters": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "The absolute http(s) URL to open." }
          },
          "required": ["url"]
        }
      }
    }
    """

    static let webRead = """
    {
      "type": "function",
      "function": {
        "name": "web_read",
        "description": "Open a URL and return its main article content as clean Markdown (Readability-extracted, sanitized, char-capped). Use to actually read a page.",
        "parameters": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "The absolute http(s) URL to read." },
            "max_chars": { "type": "integer", "description": "Hard cap on returned characters.", "default": 12000 }
          },
          "required": ["url"]
        }
      }
    }
    """

    static let webScreenshot = """
    {
      "type": "function",
      "function": {
        "name": "web_screenshot",
        "description": "Render a URL and save a PNG screenshot to disk. Returns the file path and image dimensions.",
        "parameters": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "The absolute http(s) URL to screenshot." },
            "full_page": { "type": "boolean", "description": "Capture the full scrollable page instead of just the viewport.", "default": false }
          },
          "required": ["url"]
        }
      }
    }
    """

    static let webExtract = """
    {
      "type": "function",
      "function": {
        "name": "web_extract",
        "description": "Read a URL and return the chunks of its content most relevant to an instruction (keyword/BM25 ranked). Use to pull a specific answer out of a long page.",
        "parameters": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "The absolute http(s) URL to extract from." },
            "instruction": { "type": "string", "description": "What to look for / the question to answer from the page." }
          },
          "required": ["url", "instruction"]
        }
      }
    }
    """

    /// All schemas, in registration order.
    static let all: [String] = [webSearch, webOpen, webRead, webScreenshot, webExtract]

    // MARK: Interactive browser session tools (Playwright-style)

    static let browserOpen = """
    {
      "type": "function",
      "function": {
        "name": "browser_open",
        "description": "Open a URL in the persistent browsing session (a live browser tab kept across tool calls) and wait for it to load. Use a full URL, or a search-engine URL like https://duckduckgo.com/ to start a search. Returns the final URL, page title, a short readable summary, and a list of clickable elements / inputs you can act on next.",
        "parameters": {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "The absolute http(s) URL to navigate the session to." }
          },
          "required": ["url"]
        }
      }
    }
    """

    static let browserClick = """
    {
      "type": "function",
      "function": {
        "name": "browser_click",
        "description": "Click an element on the CURRENT session page. Pass either its visible text (e.g. a link or button label) OR a CSS selector. Best-match is found among links, buttons, and inputs by text, else by querySelector. Returns the resulting URL, title, summary, and clickable elements after any navigation. Returns a helpful error (not a crash) if nothing matches.",
        "parameters": {
          "type": "object",
          "properties": {
            "target": { "type": "string", "description": "Visible text of the link/button to click, OR a CSS selector (e.g. \\"#submit\\", \\"a.result-title\\")." }
          },
          "required": ["target"]
        }
      }
    }
    """

    static let browserType = """
    {
      "type": "function",
      "function": {
        "name": "browser_type",
        "description": "Type text into an input/textarea on the CURRENT session page, identified by its visible label, placeholder, name, aria-label, OR a CSS selector. Optionally submit (press Enter / submit the form) afterward. Use this to fill a search box and run the search. Returns the resulting state.",
        "parameters": {
          "type": "object",
          "properties": {
            "target": { "type": "string", "description": "The input's placeholder/label/name/aria-label, OR a CSS selector (e.g. \\"input[name=q]\\")." },
            "text": { "type": "string", "description": "The text to type into the field." },
            "submit": { "type": "boolean", "description": "Press Enter / submit the form after typing.", "default": false }
          },
          "required": ["target", "text"]
        }
      }
    }
    """

    static let browserRead = """
    {
      "type": "function",
      "function": {
        "name": "browser_read",
        "description": "Read the CURRENT session page's main content as clean Markdown (Readability-extracted, sanitized, char-capped). Use after navigating/clicking to actually read what's on the page.",
        "parameters": {
          "type": "object",
          "properties": {
            "max_chars": { "type": "integer", "description": "Hard cap on returned characters.", "default": 12000 }
          },
          "required": []
        }
      }
    }
    """

    static let browserScreenshot = """
    {
      "type": "function",
      "function": {
        "name": "browser_screenshot",
        "description": "Take a PNG screenshot of the CURRENT session page and save it to disk. Returns the file path and image dimensions.",
        "parameters": {
          "type": "object",
          "properties": {
            "full_page": { "type": "boolean", "description": "Capture the full scrollable page instead of just the viewport.", "default": false }
          },
          "required": []
        }
      }
    }
    """

    static let browserBack = """
    {
      "type": "function",
      "function": {
        "name": "browser_back",
        "description": "Go back one step in the session's history (like the browser Back button). Returns the resulting URL, title, summary, and clickable elements.",
        "parameters": {
          "type": "object",
          "properties": {},
          "required": []
        }
      }
    }
    """

    /// Interactive browser tool schemas, in registration order.
    static let browserAll: [String] = [
        browserOpen, browserClick, browserType, browserRead, browserScreenshot, browserBack,
    ]
}

// =====================================================================
// MARK: - PR7: Agent engine (pure, Foundation-only)
//
// The tool-calling agent loop. Everything below is Foundation-only (NO
// AppKit / WebKit / network) so it is unit-tested by
// `tests/test-agentloop.swift` + `tests/test-toolrunner.swift` with
// injected canned model turns and stub tools.
//
//   - `ToolArgs`        — tolerant arguments parser (object OR JSON string).
//   - `ToolSpec`        — name/description/JSON-schema for one tool.
//   - `ParsedToolCall`  — one tool call requested by the model.
//   - `ToolResult`      — the (possibly-error) result of running one call.
//   - `AgentTool`       — protocol a concrete tool implements.
//   - `ToolRegistry`    — actor holding tools; emits the OpenAI `tools` array.
//   - `ToolRunner`      — parallel `withTaskGroup` runner (cap + timeout +
//                         partial-failure + deterministic re-assembly).
//   - `AgentLoop`       — the orchestrator over an injected model `call`.
//
// The WebKit-backed tools and the real model `call` live in PopDraft.swift
// and plug into these via the `AgentTool` protocol and the injected closure.
// =====================================================================

// MARK: - JSONObject (Sendable box for arbitrary JSON dictionaries)

/// An immutable, `Sendable` wrapper around a `[String: Any]` JSON object.
///
/// Swift's `[String: Any]` is not `Sendable`, so it can't cross an actor or be
/// captured in a `@Sendable` closure under `-strict-concurrency=complete` (where
/// it surfaces as a warning that the Swift 6 language mode escalates to an
/// error). We only ever pass JSON we just produced and never mutate after
/// construction, so wrapping it as an immutable snapshot is sound — hence
/// `@unchecked Sendable`. Callers read the dictionary back through `.dictionary`.
struct JSONObject: @unchecked Sendable {
    let dictionary: [String: Any]
    init(_ dictionary: [String: Any]) { self.dictionary = dictionary }
}

/// A `Sendable` box for a JSON value that may be a String OR an object OR nil —
/// exactly the `arguments` shapes a tool call carries. Lets `ParsedToolCall`
/// (and the closures that capture it) be `Sendable`.
struct JSONArgs: @unchecked Sendable {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw }
}

// MARK: - ToolArgs (object-or-string argument parsing)

/// Parses the `arguments` field of a tool call into a `[String: Any]` dictionary.
///
/// This is the #1 llama.cpp quirk: depending on the served chat template, the
/// `arguments` come back as EITHER a JSON **string** (`"{\"q\":\"x\"}"`, the
/// OpenAI spec shape) OR an already-decoded JSON **object**. We tolerate both,
/// plus the empty / whitespace case (→ `{}`), and surface a clear error on
/// genuinely malformed JSON so the loop can answer the model with an error tool
/// message instead of crashing.
enum ToolArgs {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case notAnObject       // valid JSON, but not a `{...}` object
        case malformed(String) // not valid JSON at all

        var description: String {
            switch self {
            case .notAnObject: return "tool arguments are not a JSON object"
            case .malformed(let m): return "malformed tool arguments JSON: \(m)"
            }
        }
    }

    /// Parse a raw `arguments` value. `raw` may be:
    ///   - `nil` / `NSNull`               → `[:]`
    ///   - a `String`  (possibly `""`)    → JSON-decode (empty → `[:]`)
    ///   - a `[String: Any]`              → returned as-is
    ///   - any other JSON-encodable value → `.notAnObject`
    static func parse(_ raw: Any?) throws -> [String: Any] {
        guard let raw = raw, !(raw is NSNull) else { return [:] }

        // Already an object (llama.cpp decoded-object shape).
        if let dict = raw as? [String: Any] { return dict }

        // A JSON string (OpenAI spec shape).
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [:] }
            guard let data = trimmed.data(using: .utf8) else {
                throw ParseError.malformed("not utf-8")
            }
            let obj: Any
            do {
                obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                throw ParseError.malformed(error.localizedDescription)
            }
            if let dict = obj as? [String: Any] { return dict }
            throw ParseError.notAnObject
        }

        // Some other already-decoded value (array, number, bool) — not an object.
        throw ParseError.notAnObject
    }
}

// MARK: - Tool value types

/// A tool's OpenAI-style specification. `parametersSchema` is the JSON-Schema
/// `parameters` object (the inner schema, not the full function wrapper).
struct ToolSpec: Equatable {
    var name: String
    var description: String
    var parametersSchema: [String: Any]

    init(name: String, description: String, parametersSchema: [String: Any] = ["type": "object", "properties": [String: Any]()]) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
    }

    /// The full OpenAI function-tool dictionary for the `tools` array.
    var openAIToolDict: [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema,
            ],
        ]
    }

    /// A `Sendable`-boxed copy of `openAIToolDict` (crosses the actor boundary).
    var openAIToolBox: JSONObject { JSONObject(openAIToolDict) }

    // [String: Any] isn't auto-Equatable; compare via name + a JSON encoding of
    // the schema (stable enough for tests / dedupe).
    static func == (lhs: ToolSpec, rhs: ToolSpec) -> Bool {
        guard lhs.name == rhs.name, lhs.description == rhs.description else { return false }
        return JSONSchema.canonical(lhs.parametersSchema) == JSONSchema.canonical(rhs.parametersSchema)
    }

    /// Build a `ToolSpec` from one of the JSON-string schemas in `WebToolSchemas`.
    /// Returns nil if the JSON doesn't carry a `function.name`.
    static func fromOpenAIJSON(_ json: String) -> ToolSpec? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fn = obj["function"] as? [String: Any],
              let name = fn["name"] as? String else {
            return nil
        }
        let desc = fn["description"] as? String ?? ""
        let params = fn["parameters"] as? [String: Any] ?? ["type": "object"]
        return ToolSpec(name: name, description: desc, parametersSchema: params)
    }
}

/// One tool call requested by the assistant, as parsed from a model response.
/// `rawArguments` is the untouched `arguments` value (String OR object) so the
/// loop can run `ToolArgs.parse` + schema-validate at the right moment.
struct ParsedToolCall: Sendable {
    var id: String
    var name: String
    /// The untouched `arguments` value (String OR object OR nil), `Sendable`-boxed.
    var args: JSONArgs

    var rawArguments: Any? { args.raw }

    init(id: String, name: String, rawArguments: Any? = nil) {
        self.id = id
        self.name = name
        self.args = JSONArgs(rawArguments)
    }

    /// The arguments as a raw JSON string, for persisting into a `ChatToolCall`.
    /// An object is re-encoded; a string is passed through; nil → "{}".
    var argumentsJSONString: String {
        if let s = args.raw as? String { return s }
        if let raw = args.raw, !(raw is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

/// The result of running one tool call. `isError` marks a failure (throw,
/// timeout, unknown tool, invalid args) that is reported back to the model as a
/// `role:"tool"` message WITHOUT tearing down the turn.
struct ToolResult: Equatable {
    var toolCallId: String
    var name: String
    var content: String
    var isError: Bool

    init(toolCallId: String, name: String, content: String, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.name = name
        self.content = content
        self.isError = isError
    }
}

// MARK: - AgentTool protocol

/// A tool the agent can call. `invoke` receives already-parsed, schema-validated
/// arguments and returns a compact string the model will read. Throwing is fine
/// — `ToolRunner` converts a throw into an `isError` `ToolResult`.
protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Invoke the tool with already-parsed, schema-validated arguments. The args
    /// arrive `Sendable`-boxed; read them via `args.dictionary`.
    func invoke(_ args: JSONObject) async throws -> String
}

// MARK: - ToolRegistry

/// Holds the set of available tools and emits the OpenAI `tools` array. An actor
/// so registration / lookup is safe across the concurrent `ToolRunner`.
actor ToolRegistry {
    private var tools: [String: any AgentTool] = [:]
    private var order: [String] = []

    init() {}

    /// Register (or replace) a tool. Registration order is preserved for
    /// `openAITools()` so the `tools` array is deterministic.
    func register(_ tool: any AgentTool) {
        let name = tool.spec.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }

    func register(_ newTools: [any AgentTool]) {
        for t in newTools { register(t) }
    }

    /// Look up a tool by name.
    func tool(named name: String) -> (any AgentTool)? {
        return tools[name]
    }

    /// All registered tool names, in registration order.
    func names() -> [String] {
        return order
    }

    var count: Int { tools.count }

    /// The OpenAI `tools` array (one function-tool dict per registered tool),
    /// in registration order. Each entry is `Sendable`-boxed so the array can
    /// cross back to a nonisolated context.
    func openAITools() -> [JSONObject] {
        return order.compactMap { tools[$0]?.spec.openAIToolBox }
    }
}

/// Unwrap a boxed tools array back into plain `[[String: Any]]` for request
/// bodies. Safe to call once the boxes are back on a single task.
func unboxTools(_ boxed: [JSONObject]) -> [[String: Any]] {
    return boxed.map { $0.dictionary }
}

// MARK: - Timeout helper

/// Errors raised by the agent runtime.
enum AgentError: Error, Equatable, CustomStringConvertible {
    case timeout
    case unknownTool(String)
    case maxIterationsReached(Int)

    var description: String {
        switch self {
        case .timeout: return "tool timed out"
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .maxIterationsReached(let n): return "agent stopped after \(n) iterations"
        }
    }
}

/// Run `operation`, cancelling it and throwing `AgentError.timeout` if it does
/// not finish within `milliseconds`. Implemented by racing the operation against
/// a `Task.sleep` in a task group; whichever wins cancels the other.
func withThrowingTimeout<T: Sendable>(
    milliseconds: Int,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // A non-positive timeout means "no timeout".
    if milliseconds <= 0 {
        return try await operation()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            throw AgentError.timeout
        }
        // First task to finish wins; cancel the rest.
        guard let result = try await group.next() else {
            throw AgentError.timeout
        }
        group.cancelAll()
        return result
    }
}

// MARK: - ToolRunner (parallel, capped, timed, deterministic)

/// Runs a batch of tool calls concurrently with:
///   - a global concurrency cap (peak in-flight ≤ cap),
///   - a per-tool timeout (→ `.timeout` `isError` result),
///   - partial failure (a throw / timeout / unknown tool is isolated to that
///     one result — the batch always completes),
///   - deterministic re-assembly (results returned in the SAME order as the
///     input `calls`, keyed by `tool_call_id`).
struct ToolRunner {
    /// Max concurrent tool invocations. Clamped to >= 1.
    var maxConcurrent: Int
    /// Per-tool timeout in milliseconds (<= 0 disables it).
    var perToolTimeoutMs: Int

    init(maxConcurrent: Int = 4, perToolTimeoutMs: Int = 30_000) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.perToolTimeoutMs = perToolTimeoutMs
    }

    /// Run `calls` against `registry`, returning one `ToolResult` per call in the
    /// SAME order as `calls`. Never throws — failures become `isError` results.
    func run(_ calls: [ParsedToolCall], registry: ToolRegistry) async -> [ToolResult] {
        if calls.isEmpty { return [] }

        let cap = max(1, maxConcurrent)
        let timeoutMs = perToolTimeoutMs

        // Each unit of work returns (index, ToolResult) so we can re-assemble in
        // input order regardless of completion order.
        let results: [(Int, ToolResult)] = await withTaskGroup(of: (Int, ToolResult).self) { group in
            var collected: [(Int, ToolResult)] = []
            collected.reserveCapacity(calls.count)
            var nextIndex = 0

            // Prime the group up to the cap.
            let initial = min(cap, calls.count)
            while nextIndex < initial {
                let idx = nextIndex
                let call = calls[idx]
                group.addTask {
                    let r = await ToolRunner.runOne(call, registry: registry, timeoutMs: timeoutMs)
                    return (idx, r)
                }
                nextIndex += 1
            }

            // As each finishes, enqueue the next — keeping in-flight ≤ cap.
            while let finished = await group.next() {
                collected.append(finished)
                if nextIndex < calls.count {
                    let idx = nextIndex
                    let call = calls[idx]
                    group.addTask {
                        let r = await ToolRunner.runOne(call, registry: registry, timeoutMs: timeoutMs)
                        return (idx, r)
                    }
                    nextIndex += 1
                }
            }
            return collected
        }

        // Deterministic re-assembly: sort by original index.
        return results.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Run a single call, converting every failure mode into an `isError` result.
    private static func runOne(_ call: ParsedToolCall, registry: ToolRegistry, timeoutMs: Int) async -> ToolResult {
        guard let tool = await registry.tool(named: call.name) else {
            return ToolResult(toolCallId: call.id, name: call.name,
                              content: "Error: \(AgentError.unknownTool(call.name).description)", isError: true)
        }

        // Parse arguments tolerantly (object-or-string), then box for Sendable.
        let argsBox: JSONObject
        do {
            argsBox = JSONObject(try ToolArgs.parse(call.rawArguments))
        } catch {
            return ToolResult(toolCallId: call.id, name: call.name,
                              content: "Error parsing arguments: \(error)", isError: true)
        }

        do {
            let content = try await withThrowingTimeout(milliseconds: timeoutMs) {
                try await tool.invoke(argsBox)
            }
            return ToolResult(toolCallId: call.id, name: call.name, content: content, isError: false)
        } catch is CancellationError {
            return ToolResult(toolCallId: call.id, name: call.name,
                              content: "Error: tool cancelled", isError: true)
        } catch let e as AgentError where e == .timeout {
            return ToolResult(toolCallId: call.id, name: call.name,
                              content: "Error: tool timed out after \(timeoutMs) ms", isError: true)
        } catch {
            return ToolResult(toolCallId: call.id, name: call.name,
                              content: "Error: \(error)", isError: true)
        }
    }
}

// MARK: - AssistantTurn (one decoded model turn)

/// One assistant turn returned by the injected model `call`. Either it asks for
/// tools (`toolCalls` non-empty) or it answers (`content`). `thinking` carries
/// optional captured reasoning.
struct AssistantTurn {
    var content: String?
    var toolCalls: [ParsedToolCall]
    var thinking: String?

    init(content: String? = nil, toolCalls: [ParsedToolCall] = [], thinking: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.thinking = thinking
    }
}

// MARK: - JSON-Schema (minimal validator)

/// A tiny, dependency-free JSON-Schema validator — just enough to catch the
/// argument mistakes a small local model actually makes (missing `required`
/// fields, wrong primitive types). On invalid args the loop appends an `isError`
/// tool message so the model can retry, rather than crashing.
enum JSONSchema {
    /// Validate `args` against a tool's `parametersSchema`. Returns nil if valid,
    /// or a short human-readable error string if not. Unknown/loose schemas pass.
    static func validate(_ args: [String: Any], schema: [String: Any]) -> String? {
        // Only object schemas are validated; anything else is treated as permissive.
        let type = schema["type"] as? String
        if let type = type, type != "object" { return nil }

        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []

        // Required-field presence.
        for key in required {
            if args[key] == nil || args[key] is NSNull {
                return "missing required argument: \(key)"
            }
        }

        // Primitive type checks for present, known properties.
        for (key, value) in args {
            guard let propSchema = properties[key] as? [String: Any],
                  let expected = propSchema["type"] as? String else { continue }
            if value is NSNull { continue }
            if let mismatch = typeError(key: key, value: value, expected: expected) {
                return mismatch
            }
        }
        return nil
    }

    private static func typeError(key: String, value: Any, expected: String) -> String? {
        switch expected {
        case "string":
            if !(value is String) { return "argument '\(key)' must be a string" }
        case "integer":
            // Accept any number that is integral; JSON has no separate int type.
            if let n = value as? NSNumber {
                if !isIntegral(n) { return "argument '\(key)' must be an integer" }
            } else if value is Bool {
                return "argument '\(key)' must be an integer"
            } else if !(value is Int) {
                return "argument '\(key)' must be an integer"
            }
        case "number":
            if value is Bool { return "argument '\(key)' must be a number" }
            if !(value is NSNumber) && !(value is Int) && !(value is Double) {
                return "argument '\(key)' must be a number"
            }
        case "boolean":
            // NSNumber bridges bools; require the underlying type to be Bool.
            if let n = value as? NSNumber {
                if !isBool(n) { return "argument '\(key)' must be a boolean" }
            } else if !(value is Bool) {
                return "argument '\(key)' must be a boolean"
            }
        case "array":
            if !(value is [Any]) { return "argument '\(key)' must be an array" }
        case "object":
            if !(value is [String: Any]) { return "argument '\(key)' must be an object" }
        default:
            break
        }
        return nil
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        // Objective-C bools are tagged with the bool obj-c type encoding.
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func isIntegral(_ n: NSNumber) -> Bool {
        if isBool(n) { return false }
        let d = n.doubleValue
        return d.truncatingRemainder(dividingBy: 1) == 0
    }

    /// A stable canonical JSON string for a `[String: Any]` (sorted keys), used
    /// only for `ToolSpec` equality / dedupe. Best-effort: unencodable → "".
    static func canonical(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }
}

// MARK: - Tool progress (UI streaming hook)

/// A progress event emitted by `AgentLoop` as it dispatches tool calls, so a UI
/// (PR8's chat) can show a live "running → done/error" card per call WITHOUT the
/// pure loop taking a hard UI dependency. The hook is an optional injected
/// closure; when `nil` the loop behaves exactly as before (the existing
/// agentloop/toolrunner tests pass an unchanged signature via the trailing
/// `call:` argument and never see this).
///
/// Each tool call surfaces two events keyed by a stable `callKey` (the loop's
/// positional id — `pc.id` or `call_<i>` when blank — so duplicate/blank ids a
/// small local model emits don't collide):
///   - `.started`  → a "running" card with the tool name + raw arguments,
///   - `.finished` → that card flips to done/error with a compact result string.
struct ToolProgressEvent: Sendable {
    enum Phase: Sendable {
        case started
        case finished(content: String, isError: Bool)
    }
    /// Stable per-call key (matches the emitted `role:"tool"` message's id).
    var callKey: String
    /// The tool name (e.g. `web_search`).
    var name: String
    /// The raw `arguments` JSON string for the call (for an args summary).
    var arguments: String
    /// 0-based index of this call within its assistant turn's batch.
    var index: Int
    var phase: Phase
}

/// The injected progress sink. `Sendable` so it can be captured by the loop and
/// fired from an async context. Optional — `nil` disables progress entirely.
typealias ToolProgressHook = @Sendable (ToolProgressEvent) -> Void

// MARK: - AgentLoop (orchestrator)

/// The tool-calling agent loop. `call` is INJECTED so tests can stub the model:
/// it takes the current messages + the OpenAI `tools` array and returns one
/// `AssistantTurn`. The loop:
///   1. asks the model,
///   2. if it requested tools: append the assistant message, schema-validate +
///      run each call (in parallel via `ToolRunner`), append one `role:"tool"`
///      message per `tool_call_id`, and loop,
///   3. else: append the final assistant message and return.
/// Bounded by `maxIterations` model calls — i.e. at most `maxIterations - 1`
/// tool-feedback rounds before a forced stop (the last call gets no chance to
/// act on tool output).
struct AgentLoop {
    /// The injected model call: (messages, toolsJSON) -> one assistant turn.
    /// `toolsJSON` arrives `Sendable`-boxed; unwrap with `unboxTools(_:)`.
    typealias ModelCall = @Sendable ([ChatMessage], [JSONObject]) async throws -> AssistantTurn

    var maxIterations: Int
    var runner: ToolRunner

    init(maxIterations: Int = 6, runner: ToolRunner = ToolRunner()) {
        self.maxIterations = max(1, maxIterations)
        self.runner = runner
    }

    /// The outcome of a loop run.
    struct Outcome {
        var session: ChatSession      // messages appended (assistant + tool turns)
        var finalText: String         // the final assistant answer (may be "")
        var iterations: Int           // how many model calls were made
        var stoppedAtMax: Bool        // true if the iteration cap halted a tool loop
    }

    /// Run the loop. `registry` supplies tools + the `tools` array; `call` is the
    /// (stubbed-in-tests) model. The returned `ChatSession` has all assistant and
    /// tool messages appended.
    ///
    /// `onProgress` is an OPTIONAL injected sink (default `nil`): when set, the
    /// loop emits a `.started` then a `.finished` `ToolProgressEvent` per tool
    /// call so a UI can render live tool cards. It carries NO UI dependency — the
    /// pure core stays testable, and the existing tests (which omit it) are
    /// unaffected because they pass `call:` by its label.
    func run(
        session: ChatSession,
        registry: ToolRegistry,
        call: ModelCall,
        onProgress: ToolProgressHook? = nil,
        finalize: ModelCall? = nil
    ) async throws -> Outcome {
        var working = session
        let toolsJSON = await registry.openAITools()
        var lastText = ""
        var iterations = 0

        while iterations < maxIterations {
            iterations += 1
            let turn = try await call(working.messages, toolsJSON)

            // No tools requested → final answer.
            if turn.toolCalls.isEmpty {
                let text = turn.content ?? ""
                // GUARD: a no-tools turn that still came back EMPTY (e.g. the whole
                // answer was eaten by a <think> block, or the model emitted nothing
                // usable) — synthesize a real answer from the context so we never
                // return blank. Only when a `finalize` synthesis call is injected.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let finalize = finalize,
                   working.messages.contains(where: { $0.role == "tool" }) {
                    if let synth = try? await synthesizeFinal(&working, finalize: finalize),
                       !synth.isEmpty {
                        return Outcome(session: working, finalText: synth,
                                       iterations: iterations + 1, stoppedAtMax: false)
                    }
                }
                lastText = text
                working.messages.append(ChatMessage(
                    role: "assistant", content: text, thinking: turn.thinking))
                working.updatedAt = Date().timeIntervalSince1970
                return Outcome(session: working, finalText: text,
                               iterations: iterations, stoppedAtMax: false)
            }

            // Tools requested → record the assistant turn (with its tool_calls).
            let toolCalls = turn.toolCalls.map {
                ChatToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSONString)
            }
            working.messages.append(ChatMessage(
                role: "assistant",
                content: turn.content ?? "",
                toolCalls: toolCalls,
                thinking: turn.thinking))

            // Notify the UI a batch of tool calls is starting (one "running" card
            // each), keyed by the same positional id we'll stamp on the tool
            // messages below.
            if let onProgress = onProgress {
                for (i, pc) in turn.toolCalls.enumerated() {
                    let key = pc.id.isEmpty ? "call_\(i)" : pc.id
                    onProgress(ToolProgressEvent(
                        callKey: key, name: pc.name,
                        arguments: pc.argumentsJSONString, index: i, phase: .started))
                }
            }

            // Schema-validate each call. Invalid ones get an isError tool message
            // (the model can retry) and are NOT dispatched to the runner.
            //
            // Re-assembly is POSITIONAL (by the index of `turn.toolCalls`), NOT
            // by tool_call_id: a model can emit duplicate or blank ids for
            // parallel calls (a known llama.cpp quirk), and keying results by id
            // would silently lose one result and duplicate another. `results[i]`
            // always belongs to `turn.toolCalls[i]`. `toRunIndexed` carries each
            // valid call's original index so the runner's output (which preserves
            // input order) can be slotted back into the right slot.
            var results: [ToolResult?] = Array(repeating: nil, count: turn.toolCalls.count)
            var toRunIndexed: [(index: Int, call: ParsedToolCall)] = []
            for (i, pc) in turn.toolCalls.enumerated() {
                guard let tool = await registry.tool(named: pc.name) else {
                    // Unknown tool: let the runner produce the canonical unknown-tool error.
                    toRunIndexed.append((i, pc))
                    continue
                }
                // Parse + validate arguments here so invalid args short-circuit.
                let parsed: [String: Any]
                do {
                    parsed = try ToolArgs.parse(pc.rawArguments)
                } catch {
                    results[i] = ToolResult(
                        toolCallId: pc.id, name: pc.name,
                        content: "Error parsing arguments: \(error)", isError: true)
                    continue
                }
                if let err = JSONSchema.validate(parsed, schema: tool.spec.parametersSchema) {
                    results[i] = ToolResult(
                        toolCallId: pc.id, name: pc.name,
                        content: "Error: invalid arguments — \(err)", isError: true)
                    continue
                }
                toRunIndexed.append((i, pc))
            }

            // Run the valid calls in parallel. `ToolRunner.run` returns results in
            // the SAME order as its input, so the k-th output maps to
            // `toRunIndexed[k]` — slot each back into its ORIGINAL position.
            let ranResults = await runner.run(toRunIndexed.map { $0.call }, registry: registry)
            for (k, r) in ranResults.enumerated() where k < toRunIndexed.count {
                results[toRunIndexed[k].index] = r
            }

            // Emit exactly one role:"tool" message per original call, in order.
            // Normalize a blank id to a positional one so the wire stays
            // consistent even if the model collided / blanked ids.
            for (i, pc) in turn.toolCalls.enumerated() {
                let result = results[i] ?? ToolResult(
                    toolCallId: pc.id, name: pc.name,
                    content: "Error: no result produced", isError: true)
                let toolCallId = pc.id.isEmpty ? "call_\(i)" : pc.id
                working.messages.append(ChatMessage(
                    role: "tool",
                    content: result.content,
                    toolCallId: toolCallId,
                    isError: result.isError ? true : nil))
                // Flip the running card to done/error with a compact result.
                onProgress?(ToolProgressEvent(
                    callKey: toolCallId, name: pc.name,
                    arguments: pc.argumentsJSONString, index: i,
                    phase: .finished(content: result.content, isError: result.isError)))
            }

            // Keep the partial assistant text (if any) as the latest answer.
            if let c = turn.content, !c.isEmpty { lastText = c }
            working.updatedAt = Date().timeIntervalSince1970
            // …loop: ask the model again with the tool results in context.
        }

        // Iteration cap hit while still in a tool loop. The model never produced a
        // plain answer — it kept calling tools. If we have tool results in context
        // and a `finalize` synthesis call, do ONE final tools-disabled turn so we
        // ALWAYS end with a real natural-language answer (never blank). This is the
        // heart of the "always-answer" fix: tool-using flows must not end empty.
        if lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let finalize = finalize,
           working.messages.contains(where: { $0.role == "tool" }) {
            if let synth = try? await synthesizeFinal(&working, finalize: finalize),
               !synth.isEmpty {
                return Outcome(session: working, finalText: synth,
                               iterations: iterations + 1, stoppedAtMax: true)
            }
        }
        working.updatedAt = Date().timeIntervalSince1970
        return Outcome(session: working, finalText: lastText,
                       iterations: iterations, stoppedAtMax: true)
    }

    /// One final model turn with tools DISABLED and a directive to answer now in
    /// plain language using the information gathered so far. Appends the directive
    /// + the synthesized assistant answer to `working` and returns the answer text
    /// (or "" on failure). `finalize` is the injected model call; the caller wires
    /// it to disable thinking for this turn so the model reliably emits prose.
    private func synthesizeFinal(
        _ working: inout ChatSession, finalize: ModelCall
    ) async throws -> String {
        let directive = ChatMessage(
            role: "user",
            content: "Using the information gathered above, answer my question now "
                + "in plain language. Do not call any tools. If a search or page "
                + "returned relevant facts, base your answer on them. Be direct and concise.")
        var msgs = working.messages
        msgs.append(directive)
        // Empty tools array → the model gets no `tools`, so it must answer in text.
        let turn = try await finalize(msgs, [])
        let text = (turn.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        working.messages.append(directive)
        working.messages.append(ChatMessage(
            role: "assistant", content: text, thinking: turn.thinking))
        working.updatedAt = Date().timeIntervalSince1970
        return text
    }
}

// =====================================================================
// MARK: - PR9: Mac-control safety + confirm-gate decision logic (pure)
//
// Everything below is Foundation-only and PURE so it is unit-tested by
// `tests/test-maccontrol.swift` with NO process execution.
//
//   - `MacControlGuard`   — the HARD denylist (sudo, rm -rf /, dd, fork bomb,
//                           curl|sh, …) enforced even on Approve, plus the
//                           opt-in safe read-only allowlist.
//   - `MacControlPolicy`  — pure decision: given a command + settings, returns
//                           .denied / .autoApprove / .needsConfirm. The
//                           confirm-gate's structural guarantee lives here.
//   - `ConfirmationDecision` / `ConfirmationKind` — the seam the UI resolves.
//   - MCP JSON-RPC framing — encode initialize/tools-call requests, parse a
//                           tools/list response into specs (no subprocess).
//
// The AppKit/Process side (the actual `Process` run, the UI confirm card, the
// MCP subprocess) lives in PopDraft.swift and calls into these.
// =====================================================================

// MARK: - MacControlGuard (hard denylist + safe-allowlist)

/// Pure, unit-testable matcher for dangerous shell commands. The denylist is a
/// HARD block: it rejects outright even after a user taps Approve (defense in
/// depth against social-engineering the user into approving a destructive
/// command). The allowlist is the opposite — a tiny set of read-only prefixes
/// that MAY skip the confirm dialog, but ONLY when the user has opted in.
enum MacControlGuard {
    /// Why a command was denied (for the error result + log line).
    struct Denial: Equatable {
        var reason: String
    }

    /// Read-only command prefixes that are safe to auto-approve (when the user
    /// has enabled `autoApproveSafeReadOnly`). The FIRST shell word must equal
    /// one of these. Anything else always confirms.
    static let safeReadOnlyPrefixes: Set<String> = [
        "ls", "cat", "pwd", "echo", "date", "whoami",
    ]

    /// True iff `command` matches a hard-denied dangerous pattern. The denylist
    /// ALWAYS applies, regardless of approval or the allowlist.
    static func isDenied(_ command: String) -> Bool {
        return denialReason(command) != nil
    }

    /// The human-readable denial reason, or nil if the command is not denied.
    /// Matching is done on a normalized (lowercased, whitespace-collapsed) copy
    /// so simple obfuscation (extra spaces, case) can't slip a pattern past us.
    static func denialReason(_ command: String) -> String? {
        let raw = command
        let lower = command.lowercased()
        // Collapse runs of whitespace to single spaces for pattern matching,
        // but keep a version WITHOUT spaces too for "rm -rf" style gaps and the
        // fork-bomb which is whitespace-insensitive.
        let collapsed = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let nospace = lower.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\n", with: "")

        // 1. Privilege escalation — sudo / su / doas anywhere as a command word.
        if hasCommandWord(collapsed, anyOf: ["sudo", "doas"]) || collapsed == "su" || collapsed.hasPrefix("su ") {
            return "privilege escalation (sudo/su/doas) is not allowed"
        }

        // 1b. AppleScript admin escalation — `do shell script "…" with administrator
        //     privileges` (and the `with admin privileges` variant). Applies to BOTH
        //     run_applescript inputs AND `osascript -e '… with administrator privileges'`
        //     from the shell side. Matched on the whitespace-stripped, lowercased form
        //     so extra spaces/newlines/tabs can't slip it past us. Precise enough that
        //     a benign script (display notification, do shell script without admin)
        //     is unaffected.
        if nospace.contains("withadministratorprivileges") || nospace.contains("withadminprivileges") {
            return "AppleScript/admin privilege escalation (with administrator privileges) is not allowed"
        }

        // 2. Recursive force-remove of root / home / glob roots.
        //    Matches `rm -rf /`, `rm -fr /`, `rm -rf ~`, `rm -rf /*`, `rm -rf .` etc.
        if isDangerousRm(collapsed) {
            return "recursive force-delete of a root/home path is not allowed"
        }

        // 3. Filesystem creation / raw disk writes.
        if hasCommandWord(collapsed, anyOf: ["mkfs"]) || collapsed.contains("mkfs.") || collapsed.contains("newfs") {
            return "filesystem creation (mkfs) is not allowed"
        }
        if collapsed.contains("dd if=") || collapsed.contains("dd if =") || nospace.contains("ddif=") {
            return "raw disk write (dd if=) is not allowed"
        }

        // 4. Fork bomb — `:(){ :|:& };:` and whitespace variants.
        if nospace.contains(":(){") || nospace.contains(":(){:|:&};:") {
            return "fork bomb is not allowed"
        }

        // 5. Pipe-to-shell of network downloads — `curl … | sh`, `wget … | bash`.
        if isPipeToShell(collapsed) {
            return "piping a network download into a shell is not allowed"
        }

        // 6. Redirecting into device nodes — `> /dev/sda`, `> /dev/disk0`.
        if redirectsToDevice(collapsed) {
            return "writing to a device node (> /dev/...) is not allowed"
        }

        // 7. Power state — shutdown / reboot / halt / poweroff.
        if hasCommandWord(collapsed, anyOf: ["shutdown", "reboot", "halt", "poweroff"]) {
            return "shutting down or rebooting the machine is not allowed"
        }
        // `osascript … restart`/`shut down` (AppleScript) variants.
        if raw.range(of: "(?i)tell\\s+app(lication)?\\s+\"?(system events|finder)\"?.*(restart|shut\\s*down|log\\s*out)",
                     options: .regularExpression) != nil {
            return "shutting down or rebooting the machine is not allowed"
        }

        return nil
    }

    /// Whether `command`'s FIRST shell word is in the opt-in safe read-only set.
    /// Note: a denied command is never "safe", even if it starts with `ls`.
    static func isSafeReadOnly(_ command: String) -> Bool {
        if isDenied(command) { return false }
        guard let first = firstWord(command) else { return false }
        // Reject if the command contains shell metacharacters that could chain
        // a non-safe command after the safe prefix (`ls; rm -rf x`, `cat $(…)`).
        if containsShellChaining(command) { return false }
        return safeReadOnlyPrefixes.contains(first)
    }

    // MARK: helpers

    /// The first shell word (the command name), lowercased, or nil if empty.
    static func firstWord(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.first
    }

    /// True if any shell metacharacter that could chain/expand into a second
    /// command is present (so an allowlisted prefix can't smuggle danger).
    private static func containsShellChaining(_ command: String) -> Bool {
        let metas = [";", "|", "&", "`", "$(", ">", "<", "\n", "&&", "||"]
        return metas.contains { command.contains($0) }
    }

    /// True if any of `words` appears as a command word (start, or after a
    /// chaining operator / whitespace). Avoids matching it inside a longer token.
    private static func hasCommandWord(_ collapsed: String, anyOf words: [String]) -> Bool {
        let tokens = collapsed
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let set = Set(words)
        // A word matches if a token equals it OR a token is "word/path" (e.g.
        // /sbin/shutdown) ending in /word.
        for t in tokens {
            if set.contains(t) { return true }
            if let slash = t.lastIndex(of: "/") {
                let tail = String(t[t.index(after: slash)...])
                if set.contains(tail) { return true }
            }
        }
        return false
    }

    /// Detect `rm` with recursive+force flags targeting a root/home/glob path.
    /// Token-based: a target is catastrophic only when the WHOLE argument token
    /// is a root/home/glob path (so `rm -rf ./build` — a named subdir — is fine,
    /// but `rm -rf /`, `rm -rf ~`, `rm -rf /*`, `rm -rf /Users` are caught).
    private static func isDangerousRm(_ collapsed: String) -> Bool {
        // Must invoke rm.
        guard hasCommandWord(collapsed, anyOf: ["rm"]) else { return false }
        // Recursive + force in some flag order: -rf, -fr, -r -f, --recursive --force.
        let recursive = collapsed.contains("-rf") || collapsed.contains("-fr")
            || (collapsed.contains("-r") && collapsed.contains("-f"))
            || (collapsed.contains("--recursive") && collapsed.contains("--force"))
            || collapsed.contains("-r ") || collapsed.contains("--recursive")
        guard recursive else { return false }

        // Catastrophic TOKENS (the entire argument equals one of these).
        let catastrophic: Set<String> = [
            "/", "/*", "~", "~/", ".", "./", "*",
            "$home", "${home}", "/users", "/system", "/applications", "/library",
        ]
        // Also flag any token under a top-level system/home root (e.g. `/Users`,
        // `/System/...`, `~/` with a glob): a token that starts with one of these
        // AND is the root itself or root + "/*".
        let rootPrefixes = ["/users", "/system", "/library", "/applications"]

        let tokens = collapsed
            .replacingOccurrences(of: ";", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("-") && $0 != "rm" }
        for t in tokens {
            if catastrophic.contains(t) { return true }
            // `/users/*`, `/system/*`, etc.
            if rootPrefixes.contains(where: { t == $0 || t == $0 + "/" || t == $0 + "/*" }) { return true }
            // `~/*` (glob-delete the whole home dir).
            if t == "~/*" || t == "$home/*" || t == "${home}/*" { return true }
        }
        return false
    }

    /// Detect a network-download piped straight into a shell interpreter.
    private static func isPipeToShell(_ collapsed: String) -> Bool {
        guard collapsed.contains("curl") || collapsed.contains("wget") || collapsed.contains("fetch") else { return false }
        guard collapsed.contains("|") else { return false }
        // The thing AFTER a pipe is a shell.
        let segments = collapsed.components(separatedBy: "|")
        guard segments.count >= 2 else { return false }
        let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "perl", "ruby", "node"]
        for seg in segments.dropFirst() {
            if let w = firstWord(seg), shells.contains(w) { return true }
            // `| sudo sh` style.
            let trimmedSeg = seg.trimmingCharacters(in: .whitespaces)
            for s in shells where trimmedSeg.hasPrefix(s + " ") || trimmedSeg == s { return true }
        }
        return false
    }

    /// Detect a redirect into a /dev device node (excluding the harmless
    /// /dev/null and /dev/stdout|stderr).
    private static func redirectsToDevice(_ collapsed: String) -> Bool {
        guard collapsed.contains(">") && collapsed.contains("/dev/") else { return false }
        // Allow the benign sinks.
        let benign = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"]
        // Find a `> /dev/...` target.
        if let range = collapsed.range(of: ">[[:space:]]*/dev/[a-z0-9]+", options: .regularExpression) {
            let target = String(collapsed[range]).replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            if benign.contains(where: { target.hasPrefix($0) }) { return false }
            return true
        }
        return false
    }
}

// MARK: - MacControlPolicy (pure confirm-gate decision)

/// The structural confirm-gate decision. Given a command and the user's
/// settings, returns EXACTLY ONE of:
///   - `.denied(reason)`     → never run, return an error result + warn.
///   - `.autoApprove`        → run WITHOUT a dialog (only ever returned when the
///                             user enabled auto-approve AND the command is a
///                             safe read-only allowlisted prefix).
///   - `.needsConfirm`       → PAUSE and ask the user (Approve/Edit/Deny).
///
/// This is the single source of truth for "can the loop run this without a
/// tap?". The tool's `invoke` MUST route through it; there is no other path to
/// execution. The denylist is checked FIRST so it always wins.
enum MacControlPolicy {
    enum Decision: Equatable {
        case denied(reason: String)
        case autoApprove
        case needsConfirm
    }

    /// Decide what to do with `command`.
    /// - `dryRun`: headless/eval mode — the caller must NOT execute; it records
    ///   "would execute" and returns. We still return the real decision so the
    ///   caller can log it, but `.autoApprove` in dryRun still means "don't run".
    static func decide(command: String,
                       autoApproveSafeReadOnly: Bool) -> Decision {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .denied(reason: "empty command") }
        // 1. Hard denylist ALWAYS wins.
        if let reason = MacControlGuard.denialReason(trimmed) {
            return .denied(reason: reason)
        }
        // 2. Opt-in safe read-only auto-approve.
        if autoApproveSafeReadOnly && MacControlGuard.isSafeReadOnly(trimmed) {
            return .autoApprove
        }
        // 3. Everything else needs an explicit user tap.
        return .needsConfirm
    }
}

// MARK: - Confirmation seam (resolved by the UI)

/// The kind of Mac-control action awaiting confirmation (drives the card icon
/// and the run path).
enum ConfirmationKind: String, Equatable, Sendable {
    case shell
    case applescript
}

/// The user's decision on a pending confirmation. `.edit` carries the possibly
/// user-modified command to run instead.
enum ConfirmationDecision: Equatable, Sendable {
    case approve
    case edit(String)
    case deny
}

/// A request for the user to confirm a Mac-control action, surfaced by the tool
/// and rendered by the chat UI as a confirm card. Pure/`Sendable` so it can
/// cross the actor boundary between the tool (off-main) and the UI (main).
struct ConfirmationRequest: Equatable, Sendable, Identifiable {
    let id: String
    let kind: ConfirmationKind
    /// The EXACT command/script that will run on Approve (shown verbatim).
    let command: String
    /// A short, human explanation of what this does (for the card subtitle).
    let explanation: String

    init(id: String, kind: ConfirmationKind, command: String, explanation: String) {
        self.id = id
        self.kind = kind
        self.command = command
        self.explanation = explanation
    }
}

/// Caps the output a Mac-control tool returns to the model, so a chatty command
/// can't blow up the context. Pure so it's unit-tested.
enum MacControlOutput {
    static let maxChars = 8000

    /// Combine stdout/stderr/exit into a compact, capped tool-result string.
    static func format(stdout: String, stderr: String, exitCode: Int32) -> String {
        var parts: [String] = []
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("exit code: \(exitCode)")
        if !out.isEmpty { parts.append("stdout:\n" + out) }
        if !err.isEmpty { parts.append("stderr:\n" + err) }
        if out.isEmpty && err.isEmpty { parts.append("(no output)") }
        var joined = parts.joined(separator: "\n\n")
        if joined.count > maxChars {
            let idx = joined.index(joined.startIndex, offsetBy: maxChars)
            joined = String(joined[..<idx]) + "\n…(output truncated)"
        }
        return joined
    }
}

// MARK: - Mac-control tool JSON schemas

/// OpenAI function-tool schemas for the confirm-gated Mac-control tools.
enum MacControlSchemas {
    static let runShell = """
    {
      "type": "function",
      "function": {
        "name": "run_shell",
        "description": "Run a shell command on the user's Mac (zsh). The command is shown to the user for explicit Approve/Edit/Deny BEFORE it runs — you are PROPOSING, not executing. Returns the command's exit code, stdout, and stderr. Use for read-only inspection or small actions; the user controls every run.",
        "parameters": {
          "type": "object",
          "properties": {
            "command": { "type": "string", "description": "The exact shell command to propose running." },
            "explanation": { "type": "string", "description": "A one-line plain-English explanation of what this command does and why." }
          },
          "required": ["command"]
        }
      }
    }
    """

    static let runAppleScript = """
    {
      "type": "function",
      "function": {
        "name": "run_applescript",
        "description": "Run an AppleScript on the user's Mac (osascript). The script is shown to the user for explicit Approve/Edit/Deny BEFORE it runs — you are PROPOSING, not executing. Returns the script's output. Use to control Mac apps; the user controls every run.",
        "parameters": {
          "type": "object",
          "properties": {
            "script": { "type": "string", "description": "The exact AppleScript source to propose running." },
            "explanation": { "type": "string", "description": "A one-line plain-English explanation of what this script does and why." }
          },
          "required": ["script"]
        }
      }
    }
    """
}

// =====================================================================
// MARK: - PR9: MCP client JSON-RPC framing (pure)
//
// Minimal but real MCP (Model Context Protocol, 2025-06-18) over stdio:
// encode the handshake/tool-call requests and parse the responses. The
// subprocess + stdio plumbing lives in PopDraft.swift; this is the pure,
// testable wire format.
// =====================================================================

/// The MCP protocol version this client speaks.
enum MCPProtocol {
    static let version = "2025-06-18"

    /// Encode the `initialize` request (id 1). Returns the JSON-RPC line bytes
    /// (no trailing newline; the transport adds framing).
    static func initializeRequest(clientName: String = "PopDraft", clientVersion: String = "1.0") -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "clientInfo": ["name": clientName, "version": clientVersion],
            ],
        ]
        return encode(body)
    }

    /// Encode the `notifications/initialized` notification (no id).
    static func initializedNotification() -> Data {
        encode(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// Encode the `tools/list` request with the given id.
    static func toolsListRequest(id: Int = 2) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": [String: Any]()])
    }

    /// Encode a `tools/call` request for `name` with `arguments`.
    static func toolsCallRequest(id: Int, name: String, arguments: [String: Any]) -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        return encode(body)
    }

    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// One tool advertised by an MCP server (name + description + input schema).
struct MCPToolSpec: Equatable {
    var name: String
    var description: String
    var inputSchema: [String: Any]

    static func == (lhs: MCPToolSpec, rhs: MCPToolSpec) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
            && JSONSchema.canonical(lhs.inputSchema) == JSONSchema.canonical(rhs.inputSchema)
    }

    /// Build an agent `ToolSpec`, namespacing the tool name with the server so
    /// two servers can't collide (`<server>__<tool>`).
    func toToolSpec(serverName: String) -> ToolSpec {
        let prefixed = MCPProtocol.namespacedToolName(server: serverName, tool: name)
        return ToolSpec(name: prefixed, description: description, parametersSchema: inputSchema)
    }
}

extension MCPProtocol {
    /// `<server>__<tool>` — a stable, collision-free agent tool name.
    static func namespacedToolName(server: String, tool: String) -> String {
        let safeServer = server.replacingOccurrences(of: " ", with: "_")
        return "\(safeServer)__\(tool)"
    }

    /// Parse a JSON-RPC `tools/list` response body into `[MCPToolSpec]`.
    /// Tolerates a missing/odd shape by returning `[]`.
    static func parseToolsList(_ data: Data) -> [MCPToolSpec] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // Errors carry an `error` member; treat as empty (the caller logs).
        if obj["error"] != nil { return [] }
        guard let result = obj["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"] as? String, !name.isEmpty else { return nil }
            let desc = (t["description"] as? String) ?? ""
            let schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object"]
            return MCPToolSpec(name: name, description: desc, inputSchema: schema)
        }
    }

    /// Extract the text content of a `tools/call` result into a compact string
    /// for the model. MCP results carry `content: [{type:"text", text:"…"}, …]`.
    static func parseToolCallResult(_ data: Data) -> (text: String, isError: Bool) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("(no parseable MCP response)", true)
        }
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "MCP error"
            return ("Error: \(msg)", true)
        }
        guard let result = obj["result"] as? [String: Any] else {
            return ("(empty MCP result)", true)
        }
        let isError = (result["isError"] as? Bool) ?? false
        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { item -> String? in
                if let type = item["type"] as? String, type == "text" {
                    return item["text"] as? String
                }
                // Non-text blocks: surface a marker so the model knows there's more.
                if let type = item["type"] as? String { return "[\(type) content]" }
                return nil
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (joined.isEmpty ? "(no text content)" : joined, isError)
        }
        // Fall back to structuredContent or a JSON dump.
        if let sc = result["structuredContent"],
           let d = try? JSONSerialization.data(withJSONObject: sc, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return (s, isError)
        }
        return ("(no content)", isError)
    }

    /// Pull the JSON-RPC `id` out of a response line (for matching responses to
    /// requests when multiplexing). Returns nil for notifications.
    static func responseId(_ data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["id"] as? Int
    }
}

// =====================================================================
// MARK: - Integration catalog (capability → MCP server)
//
// PR10: makes the agent *capability-aware*. When the user asks for something
// the agent has no tool for (email, calendar, Slack, Notion, files, …), the
// agent should NOT flatly refuse — it should explain it can connect via an MCP
// server and name a concrete one, pointing the user at Settings → MCP.
//
// This is the single source of truth for BOTH:
//   - the `suggest_integration(capability)` agent tool, and
//   - the one-click presets in the MCP settings UI.
// Pure + testable; no AppKit, no process spawning.
// =====================================================================

/// A known integration the app can connect to via an MCP server. Carries enough
/// to (a) tell the user which server to add and how, and (b) prefill the add-MCP
/// form as a one-click preset.
struct IntegrationCatalog {
    /// Canonical id (also the suggested MCP server name).
    let id: String
    /// Human-facing label, e.g. "Gmail".
    let displayName: String
    /// Capability keywords that should map to this integration (lowercased).
    let keywords: [String]
    /// The MCP server command to run (e.g. "npx").
    let command: String
    /// Arguments for the command (e.g. ["-y", "@modelcontextprotocol/server-gmail"]).
    let args: [String]
    /// Short note on what the user must supply (token, path, …) — empty if none.
    let setupNote: String

    /// The full registry of known integrations. Commands use `npx -y …` so a bare
    /// machine can fetch the package on first run; the user supplies any token via
    /// the server's own auth flow / env (noted in `setupNote`).
    static let all: [IntegrationCatalog] = [
        IntegrationCatalog(
            id: "Gmail", displayName: "Gmail",
            keywords: ["email", "e-mail", "mail", "gmail", "inbox", "message", "messages",
                       "read my email", "send an email", "compose"],
            command: "npx", args: ["-y", "@gongrzhe/server-gmail-autoauth-mcp"],
            setupNote: "Runs a one-time Google OAuth in your browser on first use."),
        IntegrationCatalog(
            id: "Google_Calendar", displayName: "Google Calendar",
            keywords: ["calendar", "event", "events", "schedule", "meeting", "meetings",
                       "appointment", "availability", "free time", "agenda"],
            command: "npx", args: ["-y", "@cocal/google-calendar-mcp"],
            setupNote: "Set GOOGLE_OAUTH_CREDENTIALS to your OAuth client JSON path."),
        IntegrationCatalog(
            id: "Slack", displayName: "Slack",
            keywords: ["slack", "channel", "channels", "dm", "direct message", "workspace"],
            command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"],
            setupNote: "Set SLACK_BOT_TOKEN and SLACK_TEAM_ID."),
        IntegrationCatalog(
            id: "Notion", displayName: "Notion",
            keywords: ["notion", "wiki", "doc", "docs", "page", "pages", "knowledge base", "database"],
            command: "npx", args: ["-y", "@notionhq/notion-mcp-server"],
            setupNote: "Set NOTION_API_KEY to your internal integration token."),
        IntegrationCatalog(
            id: "Filesystem", displayName: "Local Files",
            keywords: ["file", "files", "filesystem", "folder", "directory", "disk",
                       "read a file", "write a file", "local files", "documents"],
            command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "$HOME"],
            setupNote: "Replace $HOME with the folder you want to grant access to."),
        IntegrationCatalog(
            id: "GitHub", displayName: "GitHub",
            keywords: ["github", "repo", "repository", "pull request", "pr", "issue", "issues", "commit"],
            command: "npx", args: ["-y", "@modelcontextprotocol/server-github"],
            setupNote: "Set GITHUB_PERSONAL_ACCESS_TOKEN."),
    ]

    /// Find the best integration for a free-text capability ask. Matches against
    /// keywords (substring, case-insensitive), preferring the longest matching
    /// keyword so "google calendar" beats a bare "google". Returns nil if nothing
    /// in the catalog plausibly covers it.
    static func match(_ capability: String) -> IntegrationCatalog? {
        let q = capability.lowercased()
        guard !q.isEmpty else { return nil }
        var best: (entry: IntegrationCatalog, score: Int)?
        for entry in all {
            for kw in entry.keywords where q.contains(kw) {
                let score = kw.count
                if best == nil || score > best!.score {
                    best = (entry, score)
                }
            }
        }
        return best?.entry
    }

    /// The preset `MCPServerConfig` for this integration (disabled by default so
    /// the user can fill in any token/path before enabling it).
    var preset: MCPServerConfig {
        MCPServerConfig(name: id, command: command, args: args, enabled: false)
    }

    /// A concrete, actionable one-line suggestion the agent can speak back, e.g.
    /// "I can connect to your Gmail via the Gmail MCP server. Add it in
    /// Settings → MCP (command: `npx -y …`). …"
    func suggestionText() -> String {
        let cmd = ([command] + args).joined(separator: " ")
        var s = "I can connect to \(displayName) for you via an MCP server. "
        s += "Open Settings → MCP and add the \"\(displayName)\" server "
        s += "(or pick its one-click preset): command `\(cmd)`."
        if !setupNote.isEmpty { s += " \(setupNote)" }
        return s
    }
}

/// Names of the built-in agent tools that an MCP server's tool must NEVER shadow.
/// MCP tools are namespaced `<server>__<tool>`, so a collision is unlikely, but
/// we belt-and-suspenders guard the confirm-gated Mac-control tools (and the
/// other built-ins) so a malicious/buggy server can't hijack them.
enum BuiltinToolNames {
    static let reserved: Set<String> = [
        "run_shell", "run_applescript",
        "summarize_text", "extract_text", "suggest_integration",
        "web_search", "web_open", "web_read", "web_screenshot", "web_extract",
        "browser_open", "browser_click", "browser_type",
        "browser_read", "browser_screenshot", "browser_back",
    ]

    /// True if `name` would shadow a built-in tool and must be rejected.
    static func isReserved(_ name: String) -> Bool { reserved.contains(name) }
}
