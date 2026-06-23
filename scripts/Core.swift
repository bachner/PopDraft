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
        webSearch: WebSearchConfig = WebSearchConfig()
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
