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
    var enableMacControl: Bool
    var enableWebSearch: Bool

    init(maxIterations: Int = 6, enableMacControl: Bool = false, enableWebSearch: Bool = true) {
        self.maxIterations = maxIterations
        self.enableMacControl = enableMacControl
        self.enableWebSearch = enableWebSearch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 6
        enableMacControl = try c.decodeIfPresent(Bool.self, forKey: .enableMacControl) ?? false
        enableWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enableWebSearch) ?? true
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

    // MARK: Defaults

    init(
        version: Int = 2,
        provider: String = "llamacpp",
        llamacppURL: String = "http://localhost:10819",
        llamaModel: String = "qwen3.5-2b",
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
        bubble: BubbleSettings = BubbleSettings()
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
    }
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
    var createdAt: Double   // epoch seconds

    init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        toolCalls: [ChatToolCall]? = nil,
        toolCallId: String? = nil,
        thinking: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.thinking = thinking
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
