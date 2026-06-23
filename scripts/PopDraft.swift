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

// MARK: - Version

struct AppVersion {
    static var current: String {
        // 1. Bundle Info.plist (DMG/app bundle install)
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !bundleVersion.isEmpty,
           bundleVersion != "1.0" {
            return bundleVersion
        }

        // 2. Version file written by install.sh (source install)
        let versionFile = NSHomeDirectory() + "/.popdraft/version"
        if let fileVersion = try? String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !fileVersion.isEmpty {
            return fileVersion
        }

        // 3. Dev build fallback
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "dev-\(formatter.string(from: AppVersion.buildDate))"
    }

    private static let buildDate: Date = Date()
}

// MARK: - App Assets

/// Loads bespoke brand PNGs bundled at `Contents/Resources/Assets/`.
///
/// Every accessor is nil-safe: when PopDraft runs as a bare binary from the
/// `install.sh` source-install (no `.app` bundle, no `Assets/` directory) all
/// of these return `nil` and callers fall back to SF Symbols / code-drawn art.
enum AppAssets {
    /// Looks up a PNG named `<name>.png` inside the bundle's `Assets/` subdirectory.
    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Assets") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Standalone orb bubble (used by the corner bubble in a later PR).
    static var bubbleOrb: NSImage? { image(named: "popdraft-bubble") }

    /// Onboarding hero illustration (used by onboarding in a later PR).
    static var onboardingHero: NSImage? { image(named: "popdraft-onboarding-hero") }

    /// Full colorful app-icon orb (e.g. for an About panel).
    static var appIconImage: NSImage? { image(named: "popdraft-app-icon") }

    /// Sheet of icon variants.
    static var iconSet: NSImage? { image(named: "popdraft-icon-set") }
}

// MARK: - Menu Bar Glyph

enum MenuBarGlyph {
    /// Draws a bespoke, on-brand monochrome template glyph for the menu bar:
    /// the orb silhouette (a stroked circle) with a small 4-point sparkle at the
    /// upper-right, echoing the colorful brand orb. Returned as a template image
    /// so AppKit tints it correctly for light/dark menu bars and active states.
    ///
    /// The colorful orb PNG cannot be used here because template images must be
    /// monochrome, and rasterizing the orb to ~18px looks muddy.
    static func template(size: CGFloat = 18) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Renders the same glyph onto a flat color (non-template) for previews.
    static func preview(size: CGFloat = 128, color: NSColor = .black) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setStroke()
            color.setFill()
            draw(in: rect)
            return true
        }
    }

    /// Shared vector drawing for both the template and the preview. Uses the
    /// current fill/stroke colors so the template path tints automatically.
    private static func draw(in rect: NSRect) {
        let w = rect.width
        let h = rect.height
        let unit = min(w, h)
        let lineWidth = max(1.0, unit * 0.085)

        // Orb: a stroked circle, inset to leave room for the sparkle + stroke.
        let inset = lineWidth + unit * 0.12
        let orbRect = NSRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: w - inset * 2,
            height: h - inset * 2
        )
        let orb = NSBezierPath(ovalIn: orbRect)
        orb.lineWidth = lineWidth
        orb.stroke()

        // Sparkle: a 4-point star at the upper-right, echoing the brand orb.
        let sparkleCenter = NSPoint(x: rect.maxX - unit * 0.16, y: rect.maxY - unit * 0.16)
        let arm = unit * 0.16      // tip distance from center
        let waist = unit * 0.045   // half-width at the pinched waist
        let s = NSBezierPath()
        s.move(to: NSPoint(x: sparkleCenter.x, y: sparkleCenter.y + arm))          // top tip
        s.line(to: NSPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y + waist))
        s.line(to: NSPoint(x: sparkleCenter.x + arm, y: sparkleCenter.y))          // right tip
        s.line(to: NSPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y - waist))
        s.line(to: NSPoint(x: sparkleCenter.x, y: sparkleCenter.y - arm))          // bottom tip
        s.line(to: NSPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y - waist))
        s.line(to: NSPoint(x: sparkleCenter.x - arm, y: sparkleCenter.y))          // left tip
        s.line(to: NSPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y + waist))
        s.close()
        s.fill()
    }
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let logPath: String
    private let maxLogSize: Int = 1_000_000  // 1MB max log size

    private init() {
        let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        logPath = "\(configDir)/debug.log"

        // Rotate log if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int,
           size > maxLogSize {
            let backupPath = "\(configDir)/popdraft.log.old"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"

        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
        print(logMessage, terminator: "")
    }

    func error(_ message: String) {
        log(message, level: "ERROR")
    }

    func info(_ message: String) {
        log(message, level: "INFO")
    }
}

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
private struct LegacyCustomAction: Codable {
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
    var llamaModel: String = "qwen3.5-2b"
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

// MARK: - LLM Client

class LLMClient {
    static let llamaServerDownError = "LLAMA_SERVER_DOWN"
    static let shared = LLMClient()
    private var config: LLMConfig
    private var activeProvider: LLMConfig.Provider?
    private var activeStreamDelegate: OllamaStreamDelegate?
    private var activeLlamaCppStreamDelegate: LlamaCppStreamDelegate?

    init() {
        config = LLMConfig.load()
    }

    func reloadConfig() {
        config = LLMConfig.load()
        activeProvider = nil
    }

    var providerName: String {
        return (activeProvider ?? config.provider).displayName
    }

    var currentModel: String {
        switch activeProvider ?? config.provider {
        case .llamacpp: return "Local Model"
        case .ollama: return config.ollamaModel
        case .openai: return config.openaiModel
        case .claude: return config.claudeModel
        }
    }

    // Check if a local backend is available
    private func isLocalBackendAvailable(_ provider: LLMConfig.Provider) -> Bool {
        guard provider == .llamacpp || provider == .ollama else { return true }

        let urlString = provider == .llamacpp
            ? "\(config.llamacppURL)/health"
            : "\(config.ollamaURL)/api/tags"

        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0

        let semaphore = DispatchSemaphore(value: 0)
        var isAvailable = false

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                isAvailable = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 1.5)
        return isAvailable
    }

    private func logError(_ message: String) {
        Logger.shared.log(message)
    }

    func generate(prompt: String, systemPrompt: String? = nil, onProgress: ((LLMStreamProgress) -> Void)? = nil, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        let provider = config.provider
        activeProvider = provider

        Logger.shared.info("Sending to \(provider.displayName) [\(currentModel)]")

        // Generate with the configured provider, fallback to llama.cpp on failure
        generateWithProvider(provider, prompt: prompt, systemPrompt: systemPrompt, onProgress: onProgress) { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure(let error):
                // If not already using llama.cpp, try falling back to it
                if provider != .llamacpp {
                    self?.logError("Provider \(provider.displayName) failed: \(error.localizedDescription). Falling back to llama.cpp.")
                    self?.activeProvider = .llamacpp
                    self?.generateWithProvider(.llamacpp, prompt: prompt, systemPrompt: systemPrompt, completion: completion)
                } else {
                    completion(result)
                }
            }
        }
    }

    private func generateWithProvider(_ provider: LLMConfig.Provider, prompt: String, systemPrompt: String?, onProgress: ((LLMStreamProgress) -> Void)? = nil, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        switch provider {
        case .llamacpp:
            generateLlamaCpp(prompt: prompt, systemPrompt: systemPrompt, onProgress: onProgress, completion: completion)
        case .ollama:
            generateOllama(prompt: prompt, systemPrompt: systemPrompt, onProgress: onProgress, completion: completion)
        case .openai:
            if config.openaiAPIKey.isEmpty {
                completion(.failure(NSError(domain: "OpenAI API key not configured", code: -1)))
                return
            }
            generateOpenAI(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
        case .claude:
            if config.claudeAPIKey.isEmpty {
                completion(.failure(NSError(domain: "Claude API key not configured", code: -1)))
                return
            }
            generateClaude(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
        }
    }

    // MARK: - llama.cpp Backend (OpenAI-compatible API)

    private func generateLlamaCpp(prompt: String, systemPrompt: String?, onProgress: ((LLMStreamProgress) -> Void)? = nil, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        guard let url = URL(string: "\(config.llamacppURL)/v1/chat/completions") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        let useStreaming = onProgress != nil

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "messages": messages,
            "stream": useStreaming,
            "max_tokens": 4096
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        if useStreaming {
            let delegate = LlamaCppStreamDelegate(
                enableThinking: config.llamacppEnableThinking,
                onProgress: { progress in
                    DispatchQueue.main.async { onProgress?(progress) }
                },
                onCompletion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.activeLlamaCppStreamDelegate = nil
                        completion(result)
                    }
                }
            )
            activeLlamaCppStreamDelegate = delegate
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
        } else {
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    if (error as? URLError)?.code == .cannotConnectToHost {
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])))
                    } else {
                        completion(.failure(error))
                    }
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 503 {
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "No data", code: -1)))
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        var cleaned = content
                        var thinkingText: String? = nil
                        if let range = cleaned.range(of: "</think>") {
                            if self.config.llamacppEnableThinking, let startRange = cleaned.range(of: "<think>") {
                                thinkingText = String(cleaned[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        completion(.success(LLMResponse(text: cleaned, thinking: thinkingText)))
                    } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let errorObj = json["error"] as? [String: Any],
                              let message = errorObj["message"] as? String {
                        completion(.failure(NSError(domain: message, code: -1)))
                    } else {
                        completion(.failure(NSError(domain: "Invalid response", code: -1)))
                    }
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }
    }

    // MARK: - Ollama Backend

    private func generateOllama(prompt: String, systemPrompt: String?, onProgress: ((LLMStreamProgress) -> Void)? = nil, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        guard let url = URL(string: "\(config.ollamaURL)/api/generate") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        let useStreaming = config.ollamaEnableThinking && onProgress != nil

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.ollamaModel,
            "prompt": prompt,
            "stream": useStreaming
        ]

        body["think"] = config.ollamaEnableThinking

        if let system = systemPrompt {
            body["system"] = system
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        if useStreaming {
            let delegate = OllamaStreamDelegate(
                enableThinking: config.ollamaEnableThinking,
                onProgress: { progress in
                    DispatchQueue.main.async { onProgress?(progress) }
                },
                onCompletion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.activeStreamDelegate = nil
                        completion(result)
                    }
                }
            )
            activeStreamDelegate = delegate
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: request).resume()
        } else {
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "No data", code: -1)))
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let responseText = json["response"] as? String {
                        var cleaned = responseText
                        var thinkingText: String? = nil
                        // Ollama returns thinking in a separate "thinking" field
                        if self.config.ollamaEnableThinking, let thinking = json["thinking"] as? String, !thinking.isEmpty {
                            thinkingText = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        // Also handle <think> tags in response text as fallback
                        if let range = cleaned.range(of: "</think>") {
                            if self.config.ollamaEnableThinking && thinkingText == nil, let startRange = cleaned.range(of: "<think>") {
                                thinkingText = String(cleaned[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        completion(.success(LLMResponse(text: cleaned, thinking: thinkingText)))
                    } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let errorMsg = json["error"] as? String {
                        completion(.failure(NSError(domain: errorMsg, code: -1)))
                    } else {
                        completion(.failure(NSError(domain: "Invalid response", code: -1)))
                    }
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }
    }

    // MARK: - OpenAI Backend

    private func generateOpenAI(prompt: String, systemPrompt: String?, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.openaiAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": config.openaiModel,
            "messages": messages,
            "max_tokens": 4096
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    completion(.success(LLMResponse(text: content, thinking: nil)))
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let errorObj = json["error"] as? [String: Any],
                          let message = errorObj["message"] as? String {
                    completion(.failure(NSError(domain: "OpenAI: \(message)", code: -1)))
                } else {
                    completion(.failure(NSError(domain: "Invalid OpenAI response", code: -1)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Claude Backend

    private func generateClaude(prompt: String, systemPrompt: String?, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        let useThinking = config.claudeExtendedThinking
        request.setValue(useThinking ? "2025-04-15" : "2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let maxTokens = useThinking ? config.claudeThinkingBudget + 4096 : 4096
        var body: [String: Any] = [
            "model": config.claudeModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]

        if useThinking {
            body["thinking"] = ["type": "enabled", "budget_tokens": config.claudeThinkingBudget]
        }

        if let system = systemPrompt {
            body["system"] = system
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = json["content"] as? [[String: Any]] {
                    var thinkingParts: [String] = []
                    var textParts: [String] = []
                    for block in content {
                        let blockType = block["type"] as? String ?? ""
                        if blockType == "thinking", let t = block["thinking"] as? String {
                            thinkingParts.append(t)
                        } else if blockType == "text", let t = block["text"] as? String {
                            textParts.append(t)
                        }
                    }
                    let responseText = textParts.joined(separator: "\n")
                    let thinkingText = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")
                    if !responseText.isEmpty {
                        completion(.success(LLMResponse(text: responseText, thinking: thinkingText)))
                    } else {
                        completion(.failure(NSError(domain: "Invalid Claude response", code: -1)))
                    }
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let errorObj = json["error"] as? [String: Any],
                          let message = errorObj["message"] as? String {
                    completion(.failure(NSError(domain: "Claude: \(message)", code: -1)))
                } else {
                    completion(.failure(NSError(domain: "Invalid Claude response", code: -1)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - PR7: chatCompletion (agent-loop primitive)
    //
    // A full-message-array, tool-aware chat primitive used by the agent loop.
    // It is a SEPARATE path from the single-shot `generate()` above (which is
    // left untouched), so the existing menu-bar behavior is unchanged. This one
    // is async/throwing and returns an `AssistantTurn` (content + tool_calls +
    // thinking) so the loop can iterate. Streaming is kept simple here: text is
    // pushed to `onTextDelta` only for the local providers that already stream;
    // tool-call detection always uses the non-streamed body.

    /// One chat-completion round. `messages` is the FULL OpenAI-style message
    /// array (system/user/assistant/tool). `tools` is the OpenAI `tools` array
    /// (nil → no tools). Returns the assistant turn. Throws on transport / API
    /// errors. Provider is read from the current config (no fallback here — the
    /// loop owns retry policy).
    func chatCompletion(
        messages: [ChatMessage],
        tools: [[String: Any]]? = nil,
        stream: Bool = false,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AssistantTurn {
        let provider = config.provider
        activeProvider = provider
        switch provider {
        case .llamacpp:
            return try await chatCompletionOpenAICompatible(
                urlString: "\(config.llamacppURL)/v1/chat/completions",
                model: nil, apiKey: nil, messages: messages, tools: tools,
                isLlamaCpp: true, onTextDelta: onTextDelta)
        case .ollama:
            // Ollama's native /api/generate isn't tool-capable; use its
            // OpenAI-compatible endpoint for the agent path.
            return try await chatCompletionOpenAICompatible(
                urlString: "\(config.ollamaURL)/v1/chat/completions",
                model: config.ollamaModel, apiKey: nil, messages: messages, tools: tools,
                isLlamaCpp: false, onTextDelta: onTextDelta)
        case .openai:
            guard !config.openaiAPIKey.isEmpty else {
                throw NSError(domain: "OpenAI API key not configured", code: -1)
            }
            return try await chatCompletionOpenAICompatible(
                urlString: "https://api.openai.com/v1/chat/completions",
                model: config.openaiModel, apiKey: config.openaiAPIKey,
                messages: messages, tools: tools, isLlamaCpp: false, onTextDelta: onTextDelta)
        case .claude:
            guard !config.claudeAPIKey.isEmpty else {
                throw NSError(domain: "Claude API key not configured", code: -1)
            }
            return try await chatCompletionClaude(messages: messages, tools: tools)
        }
    }

    /// Build the OpenAI-style `messages` array from `ChatMessage`s, including
    /// `tool_calls` on assistant turns and `tool_call_id` on tool messages.
    private func openAIMessagesJSON(_ messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            var entry: [String: Any] = ["role": m.role]
            switch m.role {
            case "assistant":
                // content may be empty when only tool_calls are present.
                entry["content"] = m.content
                if let calls = m.toolCalls, !calls.isEmpty {
                    entry["tool_calls"] = calls.map { c -> [String: Any] in
                        return [
                            "id": c.id,
                            "type": "function",
                            "function": ["name": c.name, "arguments": c.arguments],
                        ]
                    }
                }
            case "tool":
                entry["content"] = m.content
                if let id = m.toolCallId { entry["tool_call_id"] = id }
            default:
                entry["content"] = m.content
            }
            out.append(entry)
        }
        return out
    }

    /// One round against any OpenAI-compatible `/v1/chat/completions` endpoint
    /// (llama.cpp, Ollama-OpenAI, OpenAI). Non-streamed (so `tool_calls` parse
    /// reliably); pushes the final text to `onTextDelta` once.
    private func chatCompletionOpenAICompatible(
        urlString: String, model: String?, apiKey: String?,
        messages: [ChatMessage], tools: [[String: Any]]?, isLlamaCpp: Bool,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AssistantTurn {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "messages": openAIMessagesJSON(messages),
            "stream": false,
            "max_tokens": 4096,
        ]
        if let model = model { body["model"] = model }
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
            // `parallel_tool_calls` is an OpenAI-cloud field; only send it to the
            // real OpenAI API (an `apiKey` is present). llama.cpp / Ollama-OpenAI
            // generally ignore unknown keys, but a stricter server could 400 on it.
            if apiKey != nil && !isLlamaCpp {
                body["parallel_tool_calls"] = true
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if isLlamaCpp, (error as? URLError)?.code == .cannotConnectToHost {
                throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
            }
            throw error
        }
        if isLlamaCpp, let http = response as? HTTPURLResponse, http.statusCode == 503 {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Invalid response", code: -1)
        }
        if let errorObj = json["error"] as? [String: Any], let message = errorObj["message"] as? String {
            throw NSError(domain: message, code: -1)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw NSError(domain: "Invalid response", code: -1)
        }

        // Parse tool_calls (OpenAI / llama.cpp shape).
        var parsedCalls: [ParsedToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for (i, tc) in toolCalls.enumerated() {
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                // Normalize a blank id to a positional one: llama.cpp sometimes
                // emits `"id":""` for parallel tool calls, and an empty id is
                // worthless (and collides across calls). The `?? "call_\(i)"`
                // alone only fires when the key is ABSENT, so coalesce "" too.
                let id = (tc["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(i)"
                // `arguments` may be a JSON string OR an object — pass raw; the
                // loop's ToolArgs.parse tolerates both.
                let rawArgs = fn["arguments"]
                parsedCalls.append(ParsedToolCall(id: id, name: name, rawArguments: rawArgs))
            }
        }

        // Parse content + <think> blocks (llama.cpp local thinking).
        var content = (message["content"] as? String) ?? ""
        var thinking: String? = nil
        if let range = content.range(of: "</think>") {
            if let startRange = content.range(of: "<think>") {
                thinking = String(content[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            content = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if parsedCalls.isEmpty, !content.isEmpty { onTextDeltaSafe(onTextDelta, content) }
        return AssistantTurn(content: content.isEmpty ? nil : content, toolCalls: parsedCalls, thinking: thinking)
    }

    /// One round against Anthropic `/v1/messages`, mapping `tool_use` blocks to
    /// `ParsedToolCall` and prior `tool` messages back into Anthropic shape.
    private func chatCompletionClaude(
        messages: [ChatMessage], tools: [[String: Any]]?
    ) async throws -> AssistantTurn {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 180

        // Split out a leading system message; map the rest to Anthropic content.
        var systemPrompt: String? = nil
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case "system":
                systemPrompt = (systemPrompt.map { $0 + "\n" } ?? "") + m.content
            case "user":
                anthropicMessages.append(["role": "user", "content": m.content])
            case "assistant":
                var blocks: [[String: Any]] = []
                if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                if let calls = m.toolCalls {
                    for c in calls {
                        let input = (try? ToolArgs.parse(c.arguments)) ?? [:]
                        blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": input])
                    }
                }
                anthropicMessages.append(["role": "assistant", "content": blocks])
            case "tool":
                // Anthropic carries tool results as a user message with a
                // tool_result block keyed to the tool_use id. Flag failures with
                // `is_error` so Claude knows the tool errored (OpenAI conveys this
                // as plain text, so only the Anthropic shape needs the flag).
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content,
                ]
                if m.isError == true { block["is_error"] = true }
                anthropicMessages.append(["role": "user", "content": [block]])
            default:
                break
            }
        }

        var body: [String: Any] = [
            "model": config.claudeModel,
            "max_tokens": 4096,
            "messages": anthropicMessages,
        ]
        if let system = systemPrompt { body["system"] = system }
        if let tools = tools, !tools.isEmpty {
            // Map OpenAI function tools → Anthropic tool schema.
            body["tools"] = tools.compactMap { t -> [String: Any]? in
                guard let fn = t["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                return [
                    "name": name,
                    "description": fn["description"] as? String ?? "",
                    "input_schema": fn["parameters"] as? [String: Any] ?? ["type": "object"],
                ]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Invalid Claude response", code: -1)
        }
        if let errorObj = json["error"] as? [String: Any], let message = errorObj["message"] as? String {
            throw NSError(domain: "Claude: \(message)", code: -1)
        }
        guard let content = json["content"] as? [[String: Any]] else {
            throw NSError(domain: "Invalid Claude response", code: -1)
        }

        var textParts: [String] = []
        var thinkingParts: [String] = []
        var parsedCalls: [ParsedToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { textParts.append(t) }
            case "thinking":
                if let t = block["thinking"] as? String { thinkingParts.append(t) }
            case "tool_use":
                if let name = block["name"] as? String {
                    let id = (block["id"] as? String) ?? "call_\(parsedCalls.count)"
                    parsedCalls.append(ParsedToolCall(id: id, name: name, rawArguments: block["input"]))
                }
            default:
                break
            }
        }
        let text = textParts.joined(separator: "\n")
        let thinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")
        return AssistantTurn(content: text.isEmpty ? nil : text, toolCalls: parsedCalls, thinking: thinking)
    }

    private func onTextDeltaSafe(_ cb: (@Sendable (String) -> Void)?, _ text: String) {
        cb?(text)
    }
}

// MARK: - Ollama Stream Delegate

class OllamaStreamDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var accumulatedText = ""
    private var accumulatedThinking = ""
    private let onProgress: (LLMStreamProgress) -> Void
    private let onCompletion: (Result<LLMResponse, Error>) -> Void
    private let enableThinking: Bool

    init(enableThinking: Bool, onProgress: @escaping (LLMStreamProgress) -> Void, onCompletion: @escaping (Result<LLMResponse, Error>) -> Void) {
        self.enableThinking = enableThinking
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Parse newline-delimited JSON
        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let done = json["done"] as? Bool ?? false

            if enableThinking, let thinking = json["thinking"] as? String, !thinking.isEmpty {
                accumulatedThinking += thinking
                onProgress(.thinking)
            }

            if let response = json["response"] as? String, !response.isEmpty {
                accumulatedText += response
                onProgress(.generating(accumulatedText))
            }

            if done {
                var finalText = accumulatedText
                var thinkingText: String? = accumulatedThinking.isEmpty ? nil : accumulatedThinking.trimmingCharacters(in: .whitespacesAndNewlines)

                // Handle <think> tags in response text as fallback
                if let range = finalText.range(of: "</think>") {
                    if enableThinking && thinkingText == nil, let startRange = finalText.range(of: "<think>") {
                        thinkingText = String(finalText[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    finalText = String(finalText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                onCompletion(.success(LLMResponse(text: finalText, thinking: thinkingText)))
                return
            }
        }

        // Also try to parse remaining buffer if it's a complete JSON object (no trailing newline)
        if !buffer.isEmpty, let json = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any], json["done"] as? Bool == true {
            buffer.removeAll()

            if enableThinking, let thinking = json["thinking"] as? String, !thinking.isEmpty {
                accumulatedThinking += thinking
            }
            if let response = json["response"] as? String, !response.isEmpty {
                accumulatedText += response
            }

            var finalText = accumulatedText
            var thinkingText: String? = accumulatedThinking.isEmpty ? nil : accumulatedThinking.trimmingCharacters(in: .whitespacesAndNewlines)

            if let range = finalText.range(of: "</think>") {
                if enableThinking && thinkingText == nil, let startRange = finalText.range(of: "<think>") {
                    thinkingText = String(finalText[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                finalText = String(finalText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            onCompletion(.success(LLMResponse(text: finalText, thinking: thinkingText)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onCompletion(.failure(error))
        }
    }
}

// MARK: - llama.cpp Stream Delegate (OpenAI SSE format)

class LlamaCppStreamDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var accumulatedText = ""
    private var insideThinkTag = false
    private var accumulatedThinking = ""
    private let onProgress: (LLMStreamProgress) -> Void
    private let onCompletion: (Result<LLMResponse, Error>) -> Void
    private let enableThinking: Bool
    private var receivedHTTPError = false

    init(enableThinking: Bool, onProgress: @escaping (LLMStreamProgress) -> Void, onCompletion: @escaping (Result<LLMResponse, Error>) -> Void) {
        self.enableThinking = enableThinking
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 503 {
            receivedHTTPError = true
            onCompletion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Parse SSE lines
        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) else { continue }

            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix(":") { continue }

            // Check for stream end
            if line == "data: [DONE]" {
                finishStream()
                return
            }

            // Parse SSE data line
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }

            // Track <think> tags in streamed content
            accumulatedText += content

            // Check for think tag transitions
            if accumulatedText.contains("<think>") && !insideThinkTag {
                insideThinkTag = true
            }

            if insideThinkTag {
                if accumulatedText.contains("</think>") {
                    insideThinkTag = false
                    // Extract text after </think> for display
                    if let range = accumulatedText.range(of: "</think>") {
                        let afterThink = String(accumulatedText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !afterThink.isEmpty {
                            onProgress(.generating(afterThink))
                        }
                    }
                } else if enableThinking {
                    onProgress(.thinking)
                }
            } else {
                // Outside think tags - show accumulated text without think block
                var displayText = accumulatedText
                if let range = displayText.range(of: "</think>") {
                    displayText = String(displayText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !displayText.isEmpty {
                    onProgress(.generating(displayText))
                }
            }
        }
    }

    private func finishStream() {
        var finalText = accumulatedText
        var thinkingText: String? = nil

        if let range = finalText.range(of: "</think>") {
            if enableThinking, let startRange = finalText.range(of: "<think>") {
                thinkingText = String(finalText[startRange.upperBound..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            finalText = String(finalText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        onCompletion(.success(LLMResponse(text: finalText, thinking: thinkingText)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if receivedHTTPError { return }
        if let error = error {
            if (error as? URLError)?.code == .cannotConnectToHost {
                onCompletion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])))
            } else {
                onCompletion(.failure(error))
            }
        } else if !accumulatedText.isEmpty {
            // Stream ended without [DONE] - finish with what we have
            finishStream()
        }
    }
}

// MARK: - Llama Server Manager

class LlamaServerManager {
    static let shared = LlamaServerManager()

    enum Status {
        case unknown, online, loading, offline
    }

    private(set) var status: Status = .unknown
    var onStatusChanged: ((Status) -> Void)?
    private var pollTimer: Timer?

    private var healthURL: URL {
        let config = LLMConfig.load()
        return URL(string: "\(config.llamacppURL)/health")!
    }

    func startPolling(interval: TimeInterval = 10.0) {
        stopPolling()
        checkNow()
        DispatchQueue.main.async {
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkNow()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func checkNow(completion: ((Status) -> Void)? = nil) {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let newStatus: Status
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    newStatus = .online
                } else if http.statusCode == 503 {
                    newStatus = .loading
                } else {
                    newStatus = .offline
                }
            } else {
                newStatus = .offline
            }
            DispatchQueue.main.async {
                let changed = self?.status != newStatus
                self?.status = newStatus
                if changed {
                    self?.onStatusChanged?(newStatus)
                }
                completion?(newStatus)
            }
        }.resume()
    }

    func restart(completion: @escaping (Bool) -> Void) {
        let config = LLMConfig.load()
        let plistPath = NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath

        // Create plist if missing
        if !FileManager.default.fileExists(atPath: plistPath) {
            DependencyManager.shared.createLlamaLaunchAgentForModel(
                LLMConfig.llamaModels.first { $0.id == config.llamaModel } ?? LLMConfig.llamaModels[0]
            )
            guard FileManager.default.fileExists(atPath: plistPath) else {
                completion(false)
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let uid = getuid()

            // Stop existing server if running
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stopProcess.arguments = ["bootout", "gui/\(uid)/com.popdraft.llama-server"]
            try? stopProcess.run()
            stopProcess.waitUntilExit()

            // Ensure service is enabled (uninstall can disable it permanently)
            let enableProcess = Process()
            enableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            enableProcess.arguments = ["enable", "gui/\(uid)/com.popdraft.llama-server"]
            try? enableProcess.run()
            enableProcess.waitUntilExit()

            let startProcess = Process()
            startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            startProcess.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            try? startProcess.run()
            startProcess.waitUntilExit()

            let healthURL = URL(string: "\(config.llamacppURL)/health")!
            var serverReady = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                URLSession.shared.dataTask(with: healthURL) { _, response, _ in
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        ok = true
                    }
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 2)
                if ok {
                    serverReady = true
                    break
                }
            }

            DispatchQueue.main.async {
                if serverReady {
                    self?.status = .online
                    self?.onStatusChanged?(.online)
                }
                completion(serverReady)
            }
        }
    }
}

// MARK: - TTS Client

class TTSClient {
    static let shared = TTSClient()
    private let serverURL = "http://127.0.0.1:7865"
    var isPaused = false

    func speak(text: String, voice: String? = nil, speed: Double? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        isPaused = false

        // Load config for defaults
        let config = LLMConfig.load()
        let useVoice = voice ?? config.ttsVoice
        let useSpeed = speed ?? config.ttsSpeed

        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(serverURL)/speak?text=\(encodedText)&voice=\(useVoice)&speed=\(useSpeed)&play=1") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        // Ensure TTS server is running, then speak (server may take ~30s to load model)
        TTSServerManager.shared.ensureRunning()
        waitForServer(maxAttempts: 15, interval: 2.0) { [weak self] ready in
            guard self != nil else { return }
            if !ready {
                completion(.failure(NSError(domain: "TTS server not available. It may still be loading the model.", code: -1)))
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 300  // Long timeout for TTS

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "TTS server error", code: -1)))
                }
            }.resume()
        }
    }

    private func waitForServer(maxAttempts: Int, interval: TimeInterval, attempt: Int = 0, completion: @escaping (Bool) -> Void) {
        checkHealth { [weak self] isHealthy in
            if isHealthy {
                completion(true)
            } else if attempt < maxAttempts {
                DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                    self?.waitForServer(maxAttempts: maxAttempts, interval: interval, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/stop") else {
            completion?(false)
            return
        }
        isPaused = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            completion?(success)
        }.resume()
    }

    func pause(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/pause") else {
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            if success { self?.isPaused = true }
            completion?(success)
        }.resume()
    }

    func resume(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/resume") else {
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            if success { self?.isPaused = false }
            completion?(success)
        }.resume()
    }

    func checkStatus(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "\(serverURL)/status") else {
            completion("error")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let status = String(data: data, encoding: .utf8) {
                completion(status)
            } else {
                completion("error")
            }
        }.resume()
    }

    func checkHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(serverURL)/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }
}

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

    // Actions for popup including custom prompt sentinel at end
    var popupActions: [Action] {
        var result = visibleActions
        if customPromptEnabled {
            result.append(Action(id: "custom_prompt", name: "Custom prompt...", icon: "ellipsis.circle.fill",
                                 prompt: "", shortcut: customPromptShortcut))
        }
        return result
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

// MARK: - View State

enum PopupState {
    case actionList
    case customPrompt
    case processing
    case streaming(text: String, isThinking: Bool)
    case ttsPlaying(isPaused: Bool)
    case result(String, thinking: String?)
    case error(String)
    /// PR8: the full Claude-style agent chat. The conversation state lives in the
    /// shared `AgentChatViewModel` (passed to `ChatView`), so this case is just a
    /// marker telling `PopupView` which surface to render in the fixed-size panel.
    case chat
}

// MARK: - Popup View

struct PopupView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    @Binding var state: PopupState
    @Binding var customPromptText: String
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCustomPromptFocused: Bool
    let allActions: [Action]
    let onSelect: (Action) -> Void
    let onCopy: () -> Void
    let onBack: () -> Void
    let onDismiss: () -> Void
    let onTTSStop: () -> Void
    let onTTSPause: () -> Void
    let onTTSResume: () -> Void
    let onOpenAccessibilitySettings: () -> Void
    let onRestartLlamaServer: () -> Void
    /// PR8: present when `state == .chat`. Drives the full agent ChatView.
    var chatViewModel: AgentChatViewModel? = nil

    // Computed filtered actions - recomputes when searchText changes
    private var actions: [Action] {
        if searchText.isEmpty {
            return allActions
        }
        return allActions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .actionList:
                actionListView
            case .customPrompt:
                customPromptView
            case .processing:
                processingView
            case .streaming(let text, let isThinking):
                streamingView(text: text, isThinking: isThinking)
            case .ttsPlaying(let isPaused):
                ttsPlayingView(isPaused: isPaused)
            case .result(let text, let thinking):
                resultView(text: text, thinking: thinking)
            case .error(let message):
                errorView(message: message)
            case .chat:
                // The chat owns its own fixed-size panel + internal ScrollView, so
                // it deliberately bypasses the 320-wide auto-resize layout below.
                if let vm = chatViewModel {
                    ChatView(viewModel: vm, onMinimize: onDismiss)
                } else {
                    // Defensive: should never happen (the controller always sets a
                    // view model before switching to .chat).
                    Color.clear.frame(width: 720, height: 560)
                }
            }
        }
        .frame(width: stateKey == "chat" ? nil : 320)
        .background(stateKey == "chat"
            ? AnyView(Color.clear)
            : AnyView(VisualEffectView(material: .popover, blendingMode: .behindWindow)))
        .clipShape(RoundedRectangle(cornerRadius: stateKey == "chat" ? 0 : 10))
        .shadow(color: .black.opacity(stateKey == "chat" ? 0 : 0.2), radius: 10, x: 0, y: 5)
        .onChange(of: stateKey) { _, newKey in
            if newKey == "customPrompt" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isCustomPromptFocused = true
                }
            }
        }
    }

    // Helper to get state key for onChange comparison
    private var stateKey: String {
        switch state {
        case .actionList: return "actionList"
        case .customPrompt: return "customPrompt"
        case .processing: return "processing"
        case .streaming: return "streaming"
        case .ttsPlaying: return "ttsPlaying"
        case .result: return "result"
        case .error: return "error"
        case .chat: return "chat"
        }
    }

    // MARK: - Action List View

    private var actionListView: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Search actions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Action list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            ActionRow(
                                action: action,
                                isSelected: index == selectedIndex
                            )
                            .id(action.id)
                            .onTapGesture {
                                onSelect(action)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    if newIndex < actions.count {
                        withAnimation {
                            proxy.scrollTo(actions[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .onAppear {
            // Focus the search field when action list appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Custom Prompt View

    private var customPromptView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Custom Prompt")
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 12) {
                TextField("Enter your instruction...", text: $customPromptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...6)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .focused($isCustomPromptFocused)
                    .onAppear { isCustomPromptFocused = true }

                Text("Press Enter to process")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Processing...")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    // MARK: - Streaming View

    private func streamingView(text: String, isThinking: Bool) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                if isThinking {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text("Thinking...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                    Text("Generating...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if isThinking || text.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if isThinking {
                        Text("Model is reasoning...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding()
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - TTS Playing View

    private func ttsPlayingView(isPaused: Bool) -> some View {
        VStack(spacing: 8) {
            // Header with status
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)

                Text(isPaused ? "Paused" : "Reading...")
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                // Keyboard hints
                Text("Space: \(isPaused ? "Play" : "Pause") | Esc: Stop")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Compact control buttons
            HStack(spacing: 8) {
                // Pause/Resume button
                Button(action: {
                    if isPaused {
                        onTTSResume()
                    } else {
                        onTTSPause()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10))
                        Text(isPaused ? "Play" : "Pause")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                // Stop button
                Button(action: onTTSStop) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Result View

    @State private var isThinkingExpanded = false

    private func resultView(text: String, thinking: String? = nil) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Result")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Result text
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let thinking = thinking, !thinking.isEmpty {
                        DisclosureGroup(isExpanded: $isThinkingExpanded) {
                            Text(thinking)
                                .font(.system(size: 11))
                                .italic()
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 11))
                                Text("Thinking")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 8)

                        Divider()
                            .padding(.bottom, 8)
                    }

                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
            .frame(maxHeight: isThinkingExpanded ? 400 : 250)

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onCopy) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text("Copy")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text("Error")
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if message == "ACCESSIBILITY_PERMISSION_REQUIRED" {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.red)

                    Text("Accessibility Permission Required")
                        .font(.system(size: 13, weight: .semibold))

                    Text("PopDraft needs Accessibility access to capture selected text. Please grant permission in System Settings.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onOpenAccessibilitySettings) {
                        Text("Open Accessibility Settings")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else if message == LLMClient.llamaServerDownError {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("llama-server is not running")
                        .font(.system(size: 13, weight: .semibold))

                    Text("The local llama.cpp server could not be reached. Click below to restart it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onRestartLlamaServer) {
                        Text("Restart Server")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
    }
}

struct ActionRow: View {
    let action: Action
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 20)

            Text(action.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()

            if let shortcut = action.shortcut {
                Text("⌃⌥\(shortcut)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Chat UI: Liquid Glass palette (PR8)

/// Shared color tokens mirroring `design-mocks/mock-1-liquid-glass.html` so the
/// SwiftUI chat matches the approved mock. System-blue accent (#0A84FF), an ink
/// ramp, and a green "ready" dot. All dynamic where it matters so dark mode reads
/// well too.
enum ChatPalette {
    static let blue = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let blueSoft = blue.opacity(0.14)

    /// Primary ink (adapts to light/dark via the system label color).
    static let ink = Color(nsColor: .labelColor)
    static let ink2 = Color(nsColor: .secondaryLabelColor)
    static let ink3 = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// A faint translucent fill for cards layered on the glass.
    static let cardFill = Color(nsColor: .controlBackgroundColor).opacity(0.55)
    static let cardStroke = Color(nsColor: .separatorColor).opacity(0.6)
}

// MARK: - Chat UI: live tool-call card state (PR8)

/// The live state of one tool call as rendered by `ToolCallCard`. Fed by the
/// `AgentLoop` progress hook: a `.started` event creates a `.running` card; a
/// `.finished` event flips it to `.done`/`.error` with a compact, tool-specific
/// preview decoded from the result string.
struct ToolCallState: Identifiable, Equatable {
    enum Status: Equatable { case running, done, error }

    let id: String          // == the loop's callKey (stable, matches tool message id)
    var name: String        // tool name, e.g. "web_search"
    var argsSummary: String // a short human summary of the arguments
    var rawArguments: String
    var status: Status
    /// A compact, decoded preview of the result (search rows, read title/snippet,
    /// screenshot path, …). nil while running.
    var preview: ToolResultPreview?

    static func == (lhs: ToolCallState, rhs: ToolCallState) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.argsSummary == rhs.argsSummary
            && lhs.status == rhs.status && lhs.preview == rhs.preview
    }
}

/// A decoded, render-ready view of a tool result (built off the result string).
enum ToolResultPreview: Equatable {
    case search([SearchResult])
    case read(title: String, snippet: String)
    case screenshot(path: String)
    case extract(title: String, chunks: [String])
    case open(title: String, url: String)
    case text(String)      // generic / unknown tool → a short snippet
    case error(String)
}

// MARK: - Chat UI: ViewModel (PR8)

/// Drives one agent chat session for `ChatView`. Holds the displayable message
/// list and the live tool-call cards, runs `PopDraftAgent`, streams assistant
/// text via the text-delta callback, and surfaces per-call tool progress through
/// the injected `ToolProgressHook`. `@MainActor` so all `@Published` mutations
/// are main-thread safe; the agent runs in a detached `Task`.
@MainActor
final class AgentChatViewModel: ObservableObject, MacControlBroker.Sink {
    /// The persisted conversation (system/user/assistant/tool turns).
    @Published private(set) var session: ChatSession
    /// Display-only messages (user + assistant), in order. Tool/system turns are
    /// folded into the owning assistant turn's cards, not shown as bubbles.
    @Published private(set) var visibleMessages: [ChatMessage] = []
    /// Live tool cards for the assistant turn currently generating (and, after it
    /// finishes, attached to that assistant message by id).
    @Published private(set) var liveToolCards: [ToolCallState] = []
    /// Streaming text for the in-progress assistant turn (empty when idle).
    @Published private(set) var streamingText: String = ""
    /// True while the agent loop is running (drives the caret + disables input).
    @Published private(set) var isGenerating: Bool = false
    /// User-facing model label for the header (e.g. "Qwen2.5-7B · local").
    @Published var modelLabel: String
    /// Whether web tools are enabled (drives the "Web" chip + the ready dot).
    @Published var webEnabled: Bool
    /// The draft text in the input bar.
    @Published var draft: String = ""
    /// Tool cards keyed by the assistant message id they belong to (so a finished
    /// turn keeps its cards rendered above its answer).
    @Published private(set) var cardsByMessage: [String: [ToolCallState]] = [:]
    /// PR9: Mac-control confirmations awaiting the user's Approve/Edit/Deny. The
    /// chat renders a confirm card per entry; resolving one resumes the paused
    /// tool. Usually 0 or 1.
    @Published private(set) var pendingConfirmations: [ConfirmationRequest] = []

    /// PR9: the broker the Mac-control tools `await`. This view-model is its sink.
    let confirmBroker = MacControlBroker()

    private let store: SessionStore
    private var runTask: Task<Void, Never>?
    /// Monotonic generation id. Bumped on every `run()`/`cancel()` so that a
    /// late-arriving streaming/progress event from a SUPERSEDED run is dropped
    /// (the `onDelta`/`onProgress` sinks fire on unstructured Tasks whose order
    /// vs. the completion is not guaranteed).
    private var generation: Int = 0

    init(session: ChatSession, store: SessionStore) {
        self.session = session
        self.store = store
        let cfg = AppConfig.load(dir: LLMConfig.configDir)
        self.webEnabled = cfg.agentSettings.enableWebSearch
        self.modelLabel = AgentChatViewModel.makeModelLabel()
        rebuildVisible()
        // PR9: receive Mac-control confirmation requests as our sink.
        confirmBroker.sink = self
    }

    /// A compact "Model · provider" label for the header.
    static func makeModelLabel() -> String {
        let cfg = LLMConfig.load()
        let provider = cfg.provider
        let suffix: String
        switch provider {
        case .llamacpp: suffix = "local"
        case .ollama: suffix = "ollama"
        case .openai: suffix = "OpenAI"
        case .claude: suffix = "Claude"
        }
        return "\(LLMClient.shared.currentModel) · \(suffix)"
    }

    /// Recompute `visibleMessages` + per-message cards from `session.messages`.
    ///
    /// One agent turn can be MULTIPLE messages on the wire: an assistant message
    /// carrying only `tool_calls` (empty content), then `role:"tool"` results,
    /// then a final assistant answer. We fold the tool cards of empty tool-only
    /// turns onto the next rendered bubble so they appear ABOVE that turn's answer
    /// (as in the mock) — never as an orphaned label-only bubble.
    private func rebuildVisible() {
        var visible: [ChatMessage] = []
        var cards: [String: [ToolCallState]] = [:]
        // Cards from tool-only turns waiting to attach to the next bubble.
        var carried: [ToolCallState] = []
        // Cards for the most-recent assistant message that DID get a bubble, so a
        // trailing tool message (resolving a card) can update them in place.
        var activeBubbleId: String?

        func cardsFrom(_ m: ChatMessage) -> [ToolCallState] {
            guard let calls = m.toolCalls, !calls.isEmpty else { return [] }
            return calls.enumerated().map { (i, c) in
                let key = c.id.isEmpty ? "call_\(i)" : c.id
                return ToolCallState(
                    id: key, name: c.name,
                    argsSummary: ToolArgFormatter.summary(name: c.name, arguments: c.arguments),
                    rawArguments: c.arguments, status: .running, preview: nil)
            }
        }
        func resolveCard(_ toolCallId: String, content: String, isError: Bool) {
            if let i = carried.firstIndex(where: { $0.id == toolCallId }) {
                carried[i].status = isError ? .error : .done
                carried[i].preview = ToolResultDecoder.decode(name: carried[i].name, content: content, isError: isError)
            } else if let bid = activeBubbleId, var bucket = cards[bid],
                      let i = bucket.firstIndex(where: { $0.id == toolCallId }) {
                bucket[i].status = isError ? .error : .done
                bucket[i].preview = ToolResultDecoder.decode(name: bucket[i].name, content: content, isError: isError)
                cards[bid] = bucket
            }
        }

        for m in session.messages {
            switch m.role {
            case "user":
                visible.append(m)
                carried = []
                activeBubbleId = nil
            case "assistant":
                let myCards = cardsFrom(m)
                let hasContent = !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasContent {
                    visible.append(m)
                    cards[m.id] = carried + myCards
                    activeBubbleId = m.id
                    carried = []
                } else {
                    // Tool-only turn: carry its cards to the next rendered bubble.
                    carried.append(contentsOf: myCards)
                    // The cards stay "active" so trailing tool messages resolve them.
                    activeBubbleId = nil
                }
            case "tool":
                resolveCard(m.toolCallId ?? "", content: m.content, isError: m.isError == true)
            default:
                break
            }
        }
        // Any cards still carried (a turn ended without a final answer bubble):
        // attach them to a synthetic trailing assistant bubble so they're visible.
        // Use a STABLE id derived from the carried card ids so the bubble keeps its
        // SwiftUI identity across rebuilds (no view churn / lost scroll).
        if !carried.isEmpty {
            let stableId = "cards:" + carried.map { $0.id }.joined(separator: ",")
            visible.append(ChatMessage(id: stableId, role: "assistant", content: ""))
            cards[stableId] = carried
        }
        self.visibleMessages = visible
        self.cardsByMessage = cards
    }

    /// Submit a new user turn (from the input bar) and run the agent.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        draft = ""
        let now = Date().timeIntervalSince1970
        session.messages.append(ChatMessage(role: "user", content: trimmed, createdAt: now))
        session.updatedAt = now
        rebuildVisible()
        run()
    }

    /// Run the agent loop against the current session, streaming text + tool
    /// progress into the published state.
    func run() {
        guard !isGenerating else { return }
        generation += 1
        let gen = generation
        isGenerating = true
        streamingText = ""
        liveToolCards = []

        let snapshot = session
        let appConfig = AppConfig.load(dir: LLMConfig.configDir)

        // @Sendable sinks: capture self weakly ONCE (not via the enclosing Task)
        // so they stay strict-concurrency clean. Each event hops to the MainActor
        // and is dropped if a newer run/cancel has superseded this `gen`.
        let onDelta: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.streamingText = text
            }
        }
        let onProgress: ToolProgressHook = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.apply(progress: event)
            }
        }

        runTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { if self.generation == gen { self.runTask = nil } }
            do {
                let outcome = try await PopDraftAgent.run(
                    session: snapshot, config: appConfig,
                    confirmer: self.confirmBroker,
                    onTextDelta: onDelta, onProgress: onProgress)
                guard self.generation == gen else { return }  // superseded → drop
                var saved = outcome.session
                saved.refreshTitle()
                self.session = saved
                self.finishGenerating()
            } catch is CancellationError {
                guard self.generation == gen else { return }
                self.finishGenerating()
            } catch {
                guard self.generation == gen else { return }
                // Surface the failure as an assistant error message so the user
                // sees what went wrong (and the chat stays continuable).
                let msg = "I hit an error: \(error.localizedDescription)"
                self.session.messages.append(ChatMessage(
                    role: "assistant", content: msg, isError: true))
                self.session.updatedAt = Date().timeIntervalSince1970
                self.finishGenerating()
            }
        }
    }

    /// Clear all transient generating state and rebuild the visible transcript.
    private func finishGenerating() {
        streamingText = ""
        liveToolCards = []
        pendingConfirmations = []
        isGenerating = false
        rebuildVisible()
    }

    /// Apply one tool-progress event to the live cards.
    private func apply(progress event: ToolProgressEvent) {
        switch event.phase {
        case .started:
            // New running card (or refresh an existing one by key).
            if let idx = liveToolCards.firstIndex(where: { $0.id == event.callKey }) {
                liveToolCards[idx].status = .running
            } else {
                liveToolCards.append(ToolCallState(
                    id: event.callKey, name: event.name,
                    argsSummary: ToolArgFormatter.summary(name: event.name, arguments: event.arguments),
                    rawArguments: event.arguments, status: .running, preview: nil))
            }
        case .finished(let content, let isError):
            // Resolve the FIRST still-running card with this key (handles a model
            // that emits the same id for parallel calls — each finished event
            // resolves one running card rather than re-resolving a done one).
            let idx = liveToolCards.firstIndex(where: { $0.id == event.callKey && $0.status == .running })
                ?? liveToolCards.firstIndex(where: { $0.id == event.callKey })
            if let idx = idx {
                liveToolCards[idx].status = isError ? .error : .done
                liveToolCards[idx].preview = ToolResultDecoder.decode(
                    name: event.name, content: content, isError: isError)
            }
        }
    }

    /// Cancel any in-flight run (used on dismiss). Bumps `generation` so any
    /// already-queued streaming/progress events are dropped, and clears the
    /// transient generating state.
    func cancel() {
        generation += 1
        // PR9: deny any pending Mac-control confirmations so their paused tools
        // resume (as denied) rather than leaking a suspended continuation.
        confirmBroker.denyAll()
        runTask?.cancel()
        runTask = nil
        isGenerating = false
        streamingText = ""
        liveToolCards = []
        pendingConfirmations = []
    }

    // MARK: - PR9: Mac-control confirmation (MacControlBroker.Sink)

    /// Show a confirm card for `request`. The card's buttons call `resolveConfirmation`.
    func present(_ request: ConfirmationRequest) {
        if !pendingConfirmations.contains(where: { $0.id == request.id }) {
            pendingConfirmations.append(request)
        }
    }

    /// Remove a confirm card (the broker resolved/withdrew it).
    func withdraw(id: String) {
        pendingConfirmations.removeAll { $0.id == id }
    }

    /// Called by the confirm card's Approve / Edit / Deny buttons. Forwards the
    /// decision to the broker, which resumes the paused tool. The card is removed
    /// by the broker's `withdraw` callback.
    func resolveConfirmation(id: String, decision: ConfirmationDecision) {
        confirmBroker.resolve(id: id, decision: decision)
    }

    /// The latest assistant answer text (for whole-answer copy).
    var latestAnswer: String {
        session.messages.last(where: { $0.role == "assistant" })?.content ?? ""
    }

    /// Persist the session now (idempotent — store.save overwrites by id).
    @discardableResult
    func persist() -> Bool {
        guard session.hasMeaningfulExchange else { return false }
        var s = session
        s.refreshTitle()
        session = s
        return store.save(s)
    }

    /// Deterministically seed the live streaming + tool-card state for offscreen
    /// rendering / the PR10 `--ui-screenshot` harness (no model call). Lets a
    /// render driver show the streaming caret + running cards without a network
    /// round-trip. Not used on the interactive path.
    func seedRenderState(streamingText: String, generating: Bool, liveCards: [ToolCallState]) {
        self.streamingText = streamingText
        self.isGenerating = generating
        self.liveToolCards = liveCards
    }
}

// MARK: - Chat UI: tool argument formatting + result decoding (PR8)

/// Builds the short "(args)" summary shown next to a tool name on a card.
enum ToolArgFormatter {
    static func summary(name: String, arguments: String) -> String {
        let obj = (try? ToolArgs.parse(arguments)) ?? [:]
        switch name {
        case "web_search":
            if let q = obj["query"] as? String { return "\"\(q)\"" }
        case "web_open", "web_read", "web_screenshot", "web_extract":
            if let u = obj["url"] as? String { return shortURL(u) }
        case "summarize_text", "extract_text":
            if let t = obj["text"] as? String { return "\(t.prefix(40))…" }
        default:
            break
        }
        // Fallback: first string value, or a compact key list.
        if let first = obj.values.compactMap({ $0 as? String }).first, !first.isEmpty {
            return "\(first.prefix(48))"
        }
        let keys = obj.keys.sorted().joined(separator: ", ")
        return keys.isEmpty ? "" : keys
    }

    static func shortURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let path = u.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// Decodes a tool's result string into a compact, render-ready `ToolResultPreview`.
enum ToolResultDecoder {
    static func decode(name: String, content: String, isError: Bool) -> ToolResultPreview {
        if isError {
            return .error(String(content.prefix(200)))
        }
        let data = content.data(using: .utf8)
        switch name {
        case "web_search":
            if let d = data, let arr = try? JSONDecoder().decode([SearchResult].self, from: d) {
                return .search(Array(arr.prefix(5)))
            }
        case "web_read":
            // web_read returns Markdown with a "# Title\nURL: ..." header.
            let (title, snippet) = parseReadMarkdown(content)
            return .read(title: title, snippet: snippet)
        case "web_screenshot":
            if let d = data, let shot = try? JSONDecoder().decode(ShotResult.self, from: d) {
                return .screenshot(path: shot.path)
            }
        case "web_extract":
            if let d = data, let ex = try? JSONDecoder().decode(ExtractResult.self, from: d) {
                return .extract(title: ex.title, chunks: ex.chunks.prefix(3).map { $0.text })
            }
        case "web_open":
            if let d = data, let op = try? JSONDecoder().decode(OpenResult.self, from: d) {
                return .open(title: op.title, url: op.finalURL)
            }
        default:
            break
        }
        // Generic: a short snippet of the (possibly JSON) content.
        let snippet = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return .text(String(snippet.prefix(220)))
    }

    /// Pull a title + leading snippet out of `web_read`'s Markdown.
    private static func parseReadMarkdown(_ md: String) -> (String, String) {
        var title = "Page"
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var consumedHeader = false
        var body: [String] = []
        for line in lines {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !consumedHeader {
                if s.hasPrefix("# ") { title = String(s.dropFirst(2)); continue }
                if s.hasPrefix("URL:") || s.hasPrefix("By:") || s.hasPrefix("(truncated") || s.isEmpty {
                    continue
                }
                consumedHeader = true
            }
            if !s.isEmpty { body.append(s) }
            if body.joined(separator: " ").count > 200 { break }
        }
        let snippet = body.joined(separator: " ")
        return (title, String(snippet.prefix(220)))
    }
}

// MARK: - Chat UI: Markdown rendering (PR8)

/// Splits assistant Markdown into ordered blocks for rendering: fenced code
/// blocks get a `CodeBlockView` (with their own copy button + monospaced body),
/// everything else is rendered as inline Markdown via `AttributedString`.
/// The `index` is the block's ordinal position, used as a collision-free
/// `Identifiable.id` (two identical code blocks must keep distinct ForEach ids).
enum MarkdownBlock: Identifiable {
    case prose(index: Int, String)
    case code(index: Int, language: String?, code: String)
    var id: Int {
        switch self {
        case .prose(let index, _): return index
        case .code(let index, _, _): return index
        }
    }
}

enum MarkdownParser {
    /// Parse text into a sequence of prose / fenced-code blocks. Fences are
    /// ```lang … ``` (the closing fence may be missing on a streaming partial).
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var inCode = false
        var lang: String? = nil

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.prose(index: out.count, joined)) }
            prose = []
        }
        func flushCode() {
            out.append(.code(index: out.count, language: lang, code: code.joined(separator: "\n")))
            code = []
            lang = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let l = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lang = l.isEmpty ? nil : l
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { flushCode() } else { flushProse() }
        return out
    }

    /// Render an inline-Markdown prose block as an AttributedString (headings,
    /// bold/italic, lists, links, inline code). Falls back to plain text if the
    /// Markdown can't be parsed. Headings/list bullets are pre-processed since
    /// `AttributedString(markdown:)` doesn't render block structure.
    static func attributed(_ prose: String) -> AttributedString {
        var result = AttributedString()
        let lines = prose.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            if i > 0 { result.append(AttributedString("\n")) }
            let line = raw
            // Heading.
            if let h = headingLevel(line) {
                let textPart = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                var a = inlineAttributed(textPart)
                let size: CGFloat = h == 1 ? 17 : (h == 2 ? 15 : 14)
                a.font = .system(size: size, weight: .semibold)
                result.append(a)
                continue
            }
            // List item.
            let listTrim = line.trimmingCharacters(in: .whitespaces)
            if listTrim.hasPrefix("- ") || listTrim.hasPrefix("* ") {
                var a = AttributedString("•  ")
                a.foregroundColor = ChatPalette.ink2
                result.append(a)
                result.append(inlineAttributed(String(listTrim.dropFirst(2))))
                continue
            }
            if let m = numberedItem(listTrim) {
                var a = AttributedString("\(m.number).  ")
                a.foregroundColor = ChatPalette.ink2
                result.append(a)
                result.append(inlineAttributed(m.body))
                continue
            }
            result.append(inlineAttributed(line))
        }
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func numberedItem(_ line: String) -> (number: Int, body: String)? {
        guard let dot = line.firstIndex(of: "."), line.startIndex != dot else { return nil }
        let numPart = line[line.startIndex..<dot]
        guard let n = Int(numPart) else { return nil }
        let after = line[line.index(after: dot)...]
        guard after.hasPrefix(" ") else { return nil }
        return (n, String(after.dropFirst()))
    }

    /// Parse inline Markdown (bold/italic/links/inline-code) into an
    /// AttributedString. Graceful fallback to plain text.
    private static func inlineAttributed(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: text, options: opts) {
            return a
        }
        return AttributedString(text)
    }
}

// MARK: - Chat UI: code block view (PR8)

/// A fenced code block with a language chip + its own copy button + monospaced
/// body, styled to match the Liquid-Glass mock.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatPalette.ink3)
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(copied ? ChatPalette.green : ChatPalette.ink2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(ChatPalette.ink)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatPalette.cardStroke, lineWidth: 0.5))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

// MARK: - Chat UI: thinking disclosure (PR8)

/// A collapsible "Reasoning…" section shown only when an assistant message
/// carries `thinking`. Matches the mock's sparkle + chevron + muted body.
struct ThinkingDisclosure: View {
    let thinking: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ChatPalette.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundColor(ChatPalette.blue)
                    Text(expanded ? "Reasoning" : "Reasoning — show thinking")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ChatPalette.ink2)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(thinking)
                    .font(.system(size: 11.5))
                    .foregroundColor(ChatPalette.ink2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.leading, 21)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(ChatPalette.blueSoft.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Chat UI: tool-call card (PR8)

/// A compact card for one tool call: name + args summary + a status indicator
/// (spinner → check / ✗), with tool-specialized result rendering.
struct ToolCallCard: View {
    let card: ToolCallState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ChatPalette.blue)
                Text(card.name)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatPalette.ink)
                if !card.argsSummary.isEmpty {
                    Text(card.argsSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ChatPalette.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                statusBadge
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if let preview = card.preview, card.status != .running {
                Divider().opacity(0.35)
                previewView(preview)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
        }
        .background(ChatPalette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(ChatPalette.cardStroke, lineWidth: 0.5))
    }

    private var icon: String {
        switch card.name {
        case "web_search": return "magnifyingglass"
        case "web_read", "web_open": return "doc.text"
        case "web_screenshot": return "camera"
        case "web_extract": return "text.viewfinder"
        case "summarize_text": return "text.alignleft"
        case "extract_text": return "text.magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch card.status {
        case .running:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .done:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text(resultCount).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(ChatPalette.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
    }

    private var resultCount: String {
        if case .search(let arr)? = card.preview { return "\(arr.count)" }
        return "done"
    }

    @ViewBuilder private func previewView(_ preview: ToolResultPreview) -> some View {
        switch preview {
        case .search(let results):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(ChatPalette.ink)
                            .lineLimit(1)
                        Text(r.snippet)
                            .font(.system(size: 10.5))
                            .foregroundColor(ChatPalette.ink2)
                            .lineLimit(2)
                        Text(host(r.url))
                            .font(.system(size: 9.5))
                            .foregroundColor(ChatPalette.blue)
                    }
                }
            }
        case .read(let title, let snippet):
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(ChatPalette.ink).lineLimit(1)
                Text(snippet).font(.system(size: 10.5)).foregroundColor(ChatPalette.ink2).lineLimit(3)
            }
        case .extract(let title, let chunks):
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(ChatPalette.ink).lineLimit(1)
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, c in
                    Text(c).font(.system(size: 10.5)).foregroundColor(ChatPalette.ink2).lineLimit(2)
                }
            }
        case .open(let title, let url):
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(ChatPalette.ink).lineLimit(1)
                Text(host(url)).font(.system(size: 9.5)).foregroundColor(ChatPalette.blue)
            }
        case .screenshot(let path):
            screenshotThumb(path)
        case .text(let s):
            Text(s).font(.system(size: 10.5)).foregroundColor(ChatPalette.ink2).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let s):
            Text(s).font(.system(size: 10.5)).foregroundColor(.red).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func screenshotThumb(_ path: String) -> some View {
        if let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ChatPalette.cardStroke, lineWidth: 0.5))
        } else {
            HStack(spacing: 5) {
                Image(systemName: "photo").font(.system(size: 11)).foregroundColor(ChatPalette.ink3)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 10.5)).foregroundColor(ChatPalette.ink2).lineLimit(1)
            }
        }
    }

    private func host(_ s: String) -> String {
        URL(string: s)?.host ?? s
    }
}

// MARK: - Chat UI: Mac-control confirm card (PR9)

/// The confirm-before-execute card for a `run_shell` / `run_applescript` proposal.
/// Shows the EXACT command/script verbatim plus a warning, and Approve / Edit /
/// Deny buttons. The tool is paused until the user decides — the agent loop
/// CANNOT run a Mac-control command without a tap here. Liquid-Glass styling
/// mirrors `ToolCallCard`.
struct ConfirmCardView: View {
    let request: ConfirmationRequest
    /// (decision) -> void: Approve / Edit(command) / Deny.
    let onDecide: (ConfirmationDecision) -> Void

    @State private var editing = false
    @State private var editedCommand: String = ""

    private var kindIcon: String {
        switch request.kind {
        case .shell: return "terminal"
        case .applescript: return "applescript"
        }
    }
    private var kindLabel: String {
        switch request.kind {
        case .shell: return "run_shell"
        case .applescript: return "run_applescript"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: warning glyph + tool name + "needs approval".
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Image(systemName: kindIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ChatPalette.ink2)
                Text(kindLabel)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(ChatPalette.ink)
                Spacer(minLength: 6)
                Text("NEEDS APPROVAL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 7)

            if !request.explanation.isEmpty {
                Text(request.explanation)
                    .font(.system(size: 11))
                    .foregroundColor(ChatPalette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 7)
            }

            Divider().opacity(0.35)

            // The EXACT command/script, monospaced. Editable when "Edit" is tapped.
            Group {
                if editing {
                    TextEditor(text: $editedCommand)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 54, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        Text(request.command)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(ChatPalette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.05))

            Divider().opacity(0.35)

            // Approve / Edit / Deny.
            HStack(spacing: 8) {
                if editing {
                    Button { onDecide(.edit(editedCommand)) } label: {
                        Label("Run edited", systemImage: "play.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(ConfirmButtonStyle(tint: ChatPalette.blue, filled: true))
                    Button { editing = false } label: {
                        Text("Cancel edit").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(ConfirmButtonStyle(tint: ChatPalette.ink2, filled: false))
                    Spacer(minLength: 0)
                } else {
                    Button { onDecide(.approve) } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(ConfirmButtonStyle(tint: ChatPalette.green, filled: true))

                    Button {
                        editedCommand = request.command
                        editing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(ConfirmButtonStyle(tint: ChatPalette.blue, filled: false))

                    Button { onDecide(.deny) } label: {
                        Label("Deny", systemImage: "xmark")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(ConfirmButtonStyle(tint: .red, filled: false))

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .background(ChatPalette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }
}

/// Small pill button style for the confirm card (filled = primary action).
struct ConfirmButtonStyle: ButtonStyle {
    let tint: Color
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(filled ? .white : tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(filled ? tint.opacity(configuration.isPressed ? 0.8 : 1.0)
                              : tint.opacity(configuration.isPressed ? 0.22 : 0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(filled ? 0 : 0.4), lineWidth: 0.5))
    }
}

// MARK: - Chat UI: message bubble (PR8)

/// One conversation turn. User turns get a blue-tinted right-aligned bubble;
/// assistant turns render author-labeled Markdown (with code blocks), an optional
/// Thinking disclosure, the turn's tool cards, and a per-message copy button.
struct MessageBubble: View {
    let message: ChatMessage
    /// Tool cards belonging to THIS assistant turn (finished) — rendered above the answer.
    let toolCards: [ToolCallState]

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantBubble
        }
    }

    // MARK: User

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(ChatPalette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(ChatPalette.blueSoft)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .frame(maxWidth: 440, alignment: .trailing)
            copyButton(text: message.content)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                Text("PopDraft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatPalette.ink2)

                if let thinking = message.thinking, !thinking.isEmpty {
                    ThinkingDisclosure(thinking: thinking)
                }

                ForEach(toolCards) { card in
                    ToolCallCard(card: card)
                }

                if message.isError == true {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !message.content.isEmpty {
                    renderedMarkdown(message.content)
                }

                if !message.content.isEmpty {
                    copyButton(text: message.content)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatar: some View {
        Group {
            if let orb = AppAssets.bubbleOrb {
                Image(nsImage: orb).resizable().scaledToFit()
            } else {
                Circle().fill(
                    LinearGradient(colors: [ChatPalette.blue, Color(red: 0.78, green: 0.61, blue: 1.0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "sparkle").font(.system(size: 9)).foregroundColor(.white))
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
    }

    @ViewBuilder private func renderedMarkdown(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.blocks(text)) { block in
                switch block {
                case .prose(_, let p):
                    Text(MarkdownParser.attributed(p))
                        .font(.system(size: 13))
                        .foregroundColor(ChatPalette.ink)
                        .textSelection(.enabled)
                        .tint(ChatPalette.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(_, let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
    }

    private func copyButton(text: String) -> some View {
        MessageCopyButton(text: text)
    }
}

/// A small per-message copy button with a brief "Copied" confirmation.
struct MessageCopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        }) {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(copied ? ChatPalette.green : ChatPalette.ink3)
        }
        .buttonStyle(.plain)
    }
}

/// The blinking streaming caret shown on the in-progress assistant line.
struct StreamingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(ChatPalette.blue)
            .frame(width: 7, height: 14)
            .opacity(on ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

// MARK: - Chat UI: ChatView (PR8)

/// The full Claude-style agent chat surface (Liquid Glass). A header (title +
/// model indicator + minimize), a scrolling transcript of `MessageBubble`s with
/// live tool cards + streaming caret, and a bottom input bar with a send button,
/// tool chips, and a streaming hint. Fixed-size panel + internal ScrollView (no
/// `fittingSize` auto-resize).
struct ChatView: View {
    @ObservedObject var viewModel: AgentChatViewModel
    let onMinimize: () -> Void
    @FocusState private var inputFocused: Bool

    static let panelWidth: CGFloat = 720
    static let panelHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            inputBar
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let orb = AppAssets.bubbleOrb {
                    Image(nsImage: orb).resizable().scaledToFit()
                } else {
                    Circle().fill(LinearGradient(
                        colors: [ChatPalette.blue, Color(red: 0.78, green: 0.61, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.session.title.isEmpty ? "Agent chat" : viewModel.session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatPalette.ink)
                    .lineLimit(1)
                Text("Agent session · saved on Copy")
                    .font(.system(size: 10))
                    .foregroundColor(ChatPalette.ink3)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle().fill(ChatPalette.green).frame(width: 7, height: 7)
                Text(viewModel.modelLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ChatPalette.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(ChatPalette.cardFill)
            .clipShape(Capsule())

            Button(action: minimize) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ChatPalette.ink2)
                    .frame(width: 26, height: 26)
                    .background(ChatPalette.cardFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Minimize to bubble")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let sel = viewModel.session.selectedText, !sel.isEmpty {
                        contextChip(sel)
                    }
                    ForEach(viewModel.visibleMessages, id: \.id) { msg in
                        MessageBubble(
                            message: msg,
                            toolCards: viewModel.cardsByMessage[msg.id] ?? [])
                        .id(msg.id)
                    }
                    // The still-generating turn (streaming text + running tool
                    // cards + caret) renders as its own trailing block.
                    if viewModel.isGenerating {
                        generatingBlock
                            .id("__generating__")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.visibleMessages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.liveToolCards.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.pendingConfirmations.count) { _, _ in scrollToBottom(proxy) }
        }
    }

    /// The live "agent is working" block: spinner over the running tool cards and
    /// the streaming partial answer with a caret.
    private var generatingBlock: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(LinearGradient(
                colors: [ChatPalette.blue, Color(red: 0.78, green: 0.61, blue: 1.0)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "sparkle").font(.system(size: 9)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 8) {
                Text("PopDraft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatPalette.ink2)
                ForEach(viewModel.liveToolCards) { card in
                    ToolCallCard(card: card)
                }
                // PR9: confirm cards for any Mac-control proposal awaiting approval.
                ForEach(viewModel.pendingConfirmations) { req in
                    ConfirmCardView(request: req) { decision in
                        viewModel.resolveConfirmation(id: req.id, decision: decision)
                    }
                }
                if !viewModel.pendingConfirmations.isEmpty {
                    Text("Waiting for your approval…")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                } else if viewModel.streamingText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        Text(viewModel.liveToolCards.contains { $0.status == .running }
                             ? "Running tools…" : "Thinking…")
                            .font(.system(size: 12))
                            .foregroundColor(ChatPalette.ink3)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        Text(viewModel.streamingText)
                            .font(.system(size: 13))
                            .foregroundColor(ChatPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StreamingCaret()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextChip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(ChatPalette.blue).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ChatPalette.blue)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundColor(ChatPalette.ink2)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatPalette.blueSoft.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                if viewModel.isGenerating {
                    proxy.scrollTo("__generating__", anchor: .bottom)
                } else if let last = viewModel.visibleMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Ask anything, or paste more text…", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .disabled(viewModel.isGenerating)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(canSend ? ChatPalette.blue : ChatPalette.blue.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ChatPalette.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(ChatPalette.cardStroke, lineWidth: 0.5))

            HStack(spacing: 8) {
                toolChip("globe", "Web", on: viewModel.webEnabled)
                toolChip("wand.and.stars", "Actions", on: false)
                Spacer()
                Text(viewModel.isGenerating ? "Streaming…" : "Enter to send")
                    .font(.system(size: 10))
                    .foregroundColor(ChatPalette.ink3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func toolChip(_ icon: String, _ label: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(on ? ChatPalette.blue : ChatPalette.ink3)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(on ? ChatPalette.blueSoft : ChatPalette.cardFill)
        .clipShape(Capsule())
    }

    private var canSend: Bool {
        !viewModel.isGenerating &&
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        viewModel.send(viewModel.draft)
    }

    private func minimize() {
        viewModel.cancel()
        onMinimize()
    }
}

// MARK: - Corner Bubble (PR4)

/// The persistent orb that lives in a screen corner. Renders the bundled brand
/// orb (`AppAssets.bubbleOrb`) when present, otherwise a drawn Liquid-Glass
/// fallback (radial-gradient sphere + sparkle + soft glow) so it ALWAYS shows,
/// even for a bare source install with no bundled art.
///
/// The hosting panel is non-key (it must never steal focus), so this view cannot
/// receive SwiftUI key/tap events the usual way — clicks are delivered via a
/// local mouse-down handler in the controller, which calls `onExpand`.
struct BubbleView: View {
    /// Diameter of the orb in points.
    static let diameter: CGFloat = 64

    /// When true, render the hover (scale + brighter glow) state. The controller
    /// drives this from `.onHover`; an explicit flag lets us also render the hover
    /// state deterministically for the offscreen PNG snapshots.
    var forceHover: Bool = false

    @State private var isHovering = false

    private var hovered: Bool { forceHover || isHovering }

    var body: some View {
        ZStack {
            orb
            // Small "ready" status dot at the lower-right, like an online badge.
            Circle()
                .fill(Color.green)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: Color.green.opacity(0.6), radius: 3)
                .offset(x: Self.diameter * 0.30, y: Self.diameter * 0.30)
        }
        // Leave headroom around the orb for the glow + hover scale so nothing clips.
        .frame(width: Self.diameter + 24, height: Self.diameter + 24)
        .scaleEffect(hovered ? 1.06 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovered)
        .onHover { hovering in isHovering = hovering }
        .help("PopDraft — click or press the hotkey to open")
    }

    @ViewBuilder
    private var orb: some View {
        ZStack {
            // Soft outer glow — brighter on hover.
            Circle()
                .fill(Color(red: 0.45, green: 0.5, blue: 0.98))
                .frame(width: Self.diameter, height: Self.diameter)
                .blur(radius: hovered ? 18 : 12)
                .opacity(hovered ? 0.65 : 0.42)

            if let orb = AppAssets.bubbleOrb {
                // Bundled brand orb (carries its own coloring/glow).
                Image(nsImage: orb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: Self.diameter, height: Self.diameter)
                    .shadow(color: Color.black.opacity(0.25), radius: 6, y: 2)
            } else {
                drawnOrb
            }
        }
    }

    /// Drawn Liquid-Glass fallback orb: a radial-gradient sphere with a glossy
    /// highlight, a thin rim, and a small 4-point sparkle.
    private var drawnOrb: some View {
        ZStack {
            // Sphere body.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.62, green: 0.68, blue: 1.0),
                            Color(red: 0.40, green: 0.45, blue: 0.95),
                            Color(red: 0.26, green: 0.22, blue: 0.78)
                        ]),
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 2,
                        endRadius: Self.diameter * 0.75
                    )
                )
                .frame(width: Self.diameter, height: Self.diameter)

            // Glassy top highlight.
            Ellipse()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: Self.diameter * 0.62, height: Self.diameter * 0.40)
                .offset(y: -Self.diameter * 0.20)
                .blur(radius: 1)

            // Thin rim for the glass edge.
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: Self.diameter, height: Self.diameter)

            // Sparkle (4-point star) at the upper-right.
            SparkleShape()
                .fill(Color.white.opacity(0.95))
                .frame(width: Self.diameter * 0.30, height: Self.diameter * 0.30)
                .offset(x: Self.diameter * 0.20, y: -Self.diameter * 0.20)
                .shadow(color: Color.white.opacity(0.8), radius: 3)
        }
        .shadow(color: Color.black.opacity(0.30), radius: 6, y: 2)
    }
}

/// A simple 4-point sparkle/star drawn with concave sides.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let arm = min(rect.width, rect.height) / 2
        let waist = arm * 0.22
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - arm))               // top tip
        p.addQuadCurve(to: CGPoint(x: c.x + arm, y: c.y),       // right tip
                       control: CGPoint(x: c.x + waist, y: c.y - waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + arm),       // bottom tip
                       control: CGPoint(x: c.x + waist, y: c.y + waist))
        p.addQuadCurve(to: CGPoint(x: c.x - arm, y: c.y),       // left tip
                       control: CGPoint(x: c.x - waist, y: c.y + waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - arm),       // back to top
                       control: CGPoint(x: c.x - waist, y: c.y - waist))
        p.closeSubpath()
        return p
    }
}

/// A borderless, NON-ACTIVATING panel that hosts the corner orb. Unlike
/// `KeyPanel`, it must NEVER become key or activate the app — it just floats.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for the orb that turns a mouse-down into an expand. Because the
/// panel is non-key it won't get SwiftUI tap/key events, so we catch the click
/// here directly (this fires for clicks on a non-activating panel without ever
/// activating the app).
final class BubbleClickHostingView: NSHostingView<BubbleView> {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Owns the persistent corner orb panel: shows/hides it, pins it to the chosen
/// corner of the active screen, repositions on screen changes, and forwards a
/// click to `onExpand` (the controller is non-key, so it watches mouse-down).
final class BubbleWindowController: NSWindowController {
    /// Called when the orb is clicked — wired to the same expand path as the hotkey.
    var onExpand: (() -> Void)?

    private var hostingView: BubbleClickHostingView?
    private var isShown = false

    init() {
        let size = NSSize(width: BubbleView.diameter + 24, height: BubbleView.diameter + 24)
        let panel = BubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the orb art carries its own glow
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        super.init(window: panel)

        let host = BubbleClickHostingView(rootView: BubbleView())
        host.frame = NSRect(origin: .zero, size: size)
        host.onClick = { [weak self] in self?.onExpand?() }
        panel.contentView = host
        hostingView = host

        // Reposition when displays/arrangement change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Corner geometry

    /// Compute the orb's origin for a given corner of a screen's visible frame,
    /// inset by `margin`. Pure geometry so it stays easy to reason about.
    static func origin(for corner: BubbleCorner, in visibleFrame: NSRect, size: NSSize, margin: CGFloat) -> NSPoint {
        switch corner {
        case .topLeft:
            return NSPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .topRight:
            return NSPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.maxY - size.height - margin)
        case .bottomLeft:
            return NSPoint(x: visibleFrame.minX + margin,
                           y: visibleFrame.minY + margin)
        case .bottomRight:
            return NSPoint(x: visibleFrame.maxX - size.width - margin,
                           y: visibleFrame.minY + margin)
        }
    }

    private func pinToCorner(animated: Bool) {
        guard let window = window else { return }
        let corner = BubbleCorner.parse(LLMConfig.load().bubble.corner)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = BubbleWindowController.origin(
            for: corner, in: visible, size: window.frame.size, margin: 16
        )
        window.setFrameOrigin(origin)
    }

    @objc private func screenParametersChanged() {
        if isShown { pinToCorner(animated: false) }
    }

    // MARK: Show / hide

    /// Show the orb in its corner, fading in. Does NOT activate the app.
    func show(animated: Bool = true) {
        guard let window = window else { return }
        pinToCorner(animated: false)
        isShown = true
        if animated {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    /// Hide the orb, fading out, then ordering it out.
    func hide(animated: Bool = true) {
        guard let window = window, isShown else { return }
        isShown = false
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                window.animator().alphaValue = 0
            }, completionHandler: { [weak window] in
                window?.orderOut(nil)
            })
        } else {
            window.orderOut(nil)
        }
    }

    var isVisible: Bool { isShown }
}

// MARK: - Key Panel (allows text input)

class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Popup Window Controller

class PopupWindowController: NSWindowController {
    private var hostingView: NSHostingView<PopupView>?
    private var searchText = ""
    private var selectedIndex = 0
    private var state: PopupState = .actionList
    private var customPromptText = ""
    private var clipboardText = ""
    private var resultText = ""
    private var localMonitor: Any?
    private var ttsStatusTimer: Timer?
    private var previousApp: NSRunningApplication?

    /// PR5: every invocation that produces a result is recorded into a persisted
    /// session (the captured selection + the user/assistant exchange). The session
    /// is built when a result arrives and flushed to disk on copy / meaningful
    /// dismiss. `nil` between invocations and whenever there's nothing worth saving.
    private var currentSession: ChatSession?
    /// Guards against double-saving the same session (copy then dismiss).
    private var didSaveCurrentSession = false
    private let sessionStore = SessionStore(
        dir: NSString(string: "~/.popdraft").expandingTildeInPath
    )

    /// PR8: the live chat view model. Set whenever the popup is in `.chat` state;
    /// nil otherwise. Drives `ChatView`.
    private var chatViewModel: AgentChatViewModel?
    /// PR8: the session's message count when the chat was presented, so a reopened
    /// session that the user didn't continue isn't needlessly re-saved on dismiss.
    private var presentedMessageCount: Int?

    /// Called right before the popup is shown at the cursor — used to minimize
    /// the corner bubble (PR4). The popup itself stays bubble-agnostic.
    var onWillShow: (() -> Void)?
    /// Called when the popup is dismissed (copy / Esc / lost focus / TTS done) —
    /// used to bring the corner bubble back (PR4).
    var onDidDismiss: (() -> Void)?

    init() {
        let window = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.becomesKeyOnlyIfNeeded = false  // Always become key when shown

        super.init(window: window)

        updateView()

        // Dismiss when window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateView() {
        let view = PopupView(
            searchText: Binding(
                get: { self.searchText },
                set: { newValue in
                    self.searchText = newValue
                    self.selectedIndex = 0  // Reset selection when searching
                    self.updateView()  // Trigger UI update
                }
            ),
            selectedIndex: Binding(get: { self.selectedIndex }, set: { self.selectedIndex = $0 }),
            state: Binding(get: { self.state }, set: { self.state = $0; self.updateView() }),
            customPromptText: Binding(get: { self.customPromptText }, set: { self.customPromptText = $0 }),
            allActions: ActionManager.shared.popupActions,
            onSelect: { [weak self] action in self?.selectAction(action) },
            onCopy: { [weak self] in self?.copyResult() },
            onBack: { [weak self] in self?.goBack() },
            onDismiss: { [weak self] in self?.dismiss() },
            onTTSStop: { [weak self] in self?.stopTTS() },
            onTTSPause: { [weak self] in self?.pauseTTS() },
            onTTSResume: { [weak self] in self?.resumeTTS() },
            onOpenAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
            onRestartLlamaServer: { [weak self] in self?.restartLlamaServer() },
            chatViewModel: chatViewModel
        )

        if hostingView == nil {
            hostingView = NSHostingView(rootView: view)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = view
        }

        // PR8: the chat uses a FIXED-size panel with its own internal ScrollView —
        // the `fittingSize` auto-resize hack below fights a growing transcript, so
        // skip it entirely in chat mode (the size is set once in `enterChat`).
        if case .chat = state { return }

        // Defer resize to next run loop so SwiftUI can finish layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let hostingView = self.hostingView, let window = self.window else { return }
            var size = hostingView.fittingSize
            size.height = min(size.height, 400)  // Maximum height
            window.setContentSize(size)

            // Ensure window stays within screen bounds after resize
            var frame = window.frame
            if let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                if frame.minY < screenFrame.minY {
                    frame.origin.y = screenFrame.minY + 5
                }
                if frame.maxY > screenFrame.maxY {
                    frame.origin.y = screenFrame.maxY - frame.height - 5
                }
                if frame.minX < screenFrame.minX {
                    frame.origin.x = screenFrame.minX + 5
                }
                if frame.maxX > screenFrame.maxX {
                    frame.origin.x = screenFrame.maxX - frame.width - 5
                }
                if frame != window.frame {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }

    private func captureSelectedText() {
        let pasteboard = NSPasteboard.general

        // Save current clipboard content
        let savedContents = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let types = item.types.first,
                  let data = item.data(forType: types) else { return nil }
            return (types, data)
        } ?? []
        let savedChangeCount = pasteboard.changeCount

        // Get the frontmost app and store it for later refocus
        let frontApp = NSWorkspace.shared.frontmostApplication
        previousApp = frontApp
        let frontName = frontApp?.localizedName ?? "unknown"

        // Strategy: try CGEvent Cmd+C first (works for Chrome, native apps),
        // then fall back to AppleScript Edit > Copy menu (works for Electron apps like Slack)
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // 0x08 = 'c'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update (poll up to 500ms for slower apps like Chrome)
        for _ in 0..<10 {
            usleep(50000)  // 50ms per check
            if pasteboard.changeCount != savedChangeCount { break }
        }

        // If CGEvent Cmd+C didn't work, fall back to AppleScript Edit > Copy menu
        if pasteboard.changeCount == savedChangeCount {
            let script = NSAppleScript(source: """
                tell application "\(frontName)" to activate
                delay 0.1
                tell application "System Events"
                    tell process "\(frontName)"
                        click menu item "Copy" of menu "Edit" of menu bar 1
                    end tell
                end tell
            """)
            script?.executeAndReturnError(nil)
            usleep(300000)  // 300ms for Electron apps
        }

        // Check if clipboard changed (meaning text was selected and copied)
        if pasteboard.changeCount != savedChangeCount {
            clipboardText = pasteboard.string(forType: .string) ?? ""

            // Restore original clipboard
            pasteboard.clearContents()
            for (type, data) in savedContents {
                pasteboard.setData(data, forType: type)
            }
        } else {
            // No selection - clipboard unchanged, don't use clipboard as fallback
            clipboardText = ""
        }
    }

    func showAtMouseLocation() {
        // Minimize the corner bubble (if enabled) as we transition to the panel.
        onWillShow?()

        // Capture selected text by simulating Cmd+C
        captureSelectedText()

        // Reset state.
        searchText = ""
        selectedIndex = 0
        customPromptText = ""
        resultText = ""
        // PR5: start a fresh invocation — drop any previously recorded session so a
        // stale exchange isn't re-saved on this dismiss.
        currentSession = nil
        didSaveCurrentSession = false
        chatViewModel = nil
        presentedMessageCount = nil

        // PR8: with the bubble enabled and NO text selected, the hotkey opens the
        // agent chat directly (empty, awaiting the user's first message). With the
        // bubble disabled, keep today's behavior (action list). With text selected,
        // it's always the action list (the user picks an action → chat).
        let bubbleEnabled = LLMConfig.load().bubble.enabled
        if bubbleEnabled && clipboardText.isEmpty {
            enterChat(seedUser: "", selectedText: nil, autoRun: false)
            window?.makeKeyAndOrderFront(nil)
            startKeyboardMonitoring()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        state = .actionList
        updateView()

        // Position near mouse
        let mouseLocation = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero

        // Find the screen containing the mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        // Try to position below cursor first
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen horizontally
        if frame.minX < screenFrame.minX {
            frame.origin.x = screenFrame.minX + 10
        }
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }

        // If popup would be cut off at bottom, show it above the cursor instead
        if frame.minY < screenFrame.minY {
            frame.origin.y = mouseLocation.y + 20
            // If still cut off at top, clamp to screen
            if frame.maxY > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.height - 10
            }
        }

        updateView()
        window?.setFrame(frame, display: true)
        window?.makeKeyAndOrderFront(nil)

        // Start monitoring keyboard
        startKeyboardMonitoring()
        updateView()
        // Make the app active so we can receive key events
        NSApp.activate(ignoringOtherApps: true)
    }

    func showWithAction(actionID: String) {
        // Minimize the corner bubble (if enabled) as we transition to the panel.
        onWillShow?()

        // Capture selected text by simulating Cmd+C
        captureSelectedText()

        // Find the action by ID
        guard let action = ActionManager.shared.popupActions.first(where: { $0.id == actionID }) else {
            showAtMouseLocation() // Fall back to showing popup
            return
        }

        // Reset state and prepare for direct action
        searchText = ""
        selectedIndex = 0
        customPromptText = ""
        resultText = ""
        // PR5: start a fresh invocation (see showAtMouseLocation).
        currentSession = nil
        didSaveCurrentSession = false
        // PR8: drop any stale chat VM before this invocation.
        chatViewModel = nil
        presentedMessageCount = nil

        // Position near mouse
        let mouseLocation = NSEvent.mouseLocation
        var frame = window?.frame ?? .zero

        // Find the screen containing the mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        // Try to position below cursor first
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen horizontally
        if frame.minX < screenFrame.minX {
            frame.origin.x = screenFrame.minX + 10
        }
        if frame.maxX > screenFrame.maxX {
            frame.origin.x = screenFrame.maxX - frame.width - 10
        }

        // If popup would be cut off at bottom, show it above the cursor instead
        if frame.minY < screenFrame.minY {
            frame.origin.y = mouseLocation.y + 20
            // If still cut off at top, clamp to screen
            if frame.maxY > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.height - 10
            }
        }

        window?.setFrame(frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        startKeyboardMonitoring()
        NSApp.activate(ignoringOtherApps: true)

        // Directly trigger the action (skip action list)
        selectAction(action)
    }

    func dismiss() {
        // PR8: stop any in-flight agent run before tearing down.
        chatViewModel?.cancel()
        // PR5: persist the session on minimize/dismiss too (idempotent with copy —
        // a session already flushed by copyResult won't be written twice, and an
        // empty/aborted session is skipped by hasMeaningfulExchange).
        flushSessionIfMeaningful()

        stopTTSStatusPolling()
        stopKeyboardMonitoring()
        window?.orderOut(nil)

        // Refocus the previous app
        if let app = previousApp {
            app.activate(options: [])
        }
        previousApp = nil

        // Bring the corner bubble back (when enabled). With the bubble disabled
        // this is a no-op, so behavior matches today exactly.
        onDidDismiss?()
    }

    private func goBack() {
        state = .actionList
        customPromptText = ""
        updateView()
    }

    private func startKeyboardMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            // Handle Cmd+C in result state - copy and close
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == "c" {
                    if case .result = self.state {
                        self.copyResult()
                        return nil
                    }
                }
                // Allow Cmd+C/V/X/A through for text editing in other states
                if key == "c" || key == "v" || key == "x" || key == "a" {
                    return event  // Pass through to text field
                }
            }

            let actions = ActionManager.shared.filteredActions(searchText: self.searchText)

            // PR8: in chat mode the SwiftUI TextField owns the keyboard — let every
            // key through (arrows, Return for submit/newline, Space) and only
            // intercept Escape to minimize the chat to the bubble.
            if case .chat = self.state {
                if event.keyCode == 53 { // Escape
                    self.dismiss()
                    return nil
                }
                return event
            }

            switch event.keyCode {
            case 53: // Escape
                switch self.state {
                case .actionList, .result, .error:
                    self.dismiss()
                case .ttsPlaying:
                    self.stopTTS()  // Stop TTS and dismiss
                default:
                    self.goBack()
                }
                return nil

            case 49: // Space - pause/play TTS
                if case .ttsPlaying(let isPaused) = self.state {
                    if isPaused {
                        self.resumeTTS()
                    } else {
                        self.pauseTTS()
                    }
                    return nil
                }
                return event

            case 125: // Down arrow
                if case .actionList = self.state, self.selectedIndex < actions.count - 1 {
                    self.selectedIndex += 1
                    self.updateView()
                }
                return nil

            case 126: // Up arrow
                if case .actionList = self.state, self.selectedIndex > 0 {
                    self.selectedIndex -= 1
                    self.updateView()
                }
                return nil

            case 36: // Return/Enter
                switch self.state {
                case .actionList:
                    if self.selectedIndex < actions.count {
                        self.selectAction(actions[self.selectedIndex])
                    }
                case .customPrompt:
                    if !self.customPromptText.isEmpty {
                        let customAction = Action(
                            id: "custom_prompt_inline",
                            name: "Custom",
                            icon: "ellipsis.circle.fill",
                            prompt: self.customPromptText
                        )
                        self.selectAction(customAction)
                    }
                case .result:
                    self.copyResult()
                default:
                    break
                }
                return nil

            default:
                return event
            }
        }
    }

    private func stopKeyboardMonitoring() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func selectAction(_ action: Action) {
        // Handle custom prompt
        if action.id == "custom_prompt" {
            Logger.shared.info("Action selected: Custom prompt")
            state = .customPrompt
            updateView()
            return
        }

        // Check accessibility permission
        if !AXIsProcessTrusted() {
            Logger.shared.error("Action '\(action.name)' failed: Accessibility permission not granted")
            state = .error("ACCESSIBILITY_PERMISSION_REQUIRED")
            updateView()
            return
        }

        // Get selected text from clipboard
        guard !clipboardText.isEmpty else {
            Logger.shared.error("Action '\(action.name)' failed: No text selected")
            state = .error("No text selected.\nSelect some text first.")
            updateView()
            return
        }

        let textPreview = clipboardText.prefix(50).replacingOccurrences(of: "\n", with: " ")
        Logger.shared.info("Action '\(action.name)' on \(clipboardText.count) chars: \"\(textPreview)...\"")

        // Show processing state
        state = .processing
        updateView()

        switch action.actionType {
        case .tts:
            TTSClient.shared.speak(text: clipboardText) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        Logger.shared.info("TTS playback started")
                        self?.state = .ttsPlaying(isPaused: false)
                        self?.updateView()
                        self?.startTTSStatusPolling()
                    case .failure(let error):
                        Logger.shared.error("TTS failed: \(error.localizedDescription)")
                        self?.state = .error("TTS Error: \(error.localizedDescription)\n\nMake sure the TTS server is running.")
                        self?.updateView()
                    }
                }
            }

        case .command:
            let commandTemplate = action.prompt
            Logger.shared.info("Running command action: \(commandTemplate)")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")

                let hasPlaceholder = commandTemplate.contains("{text}")
                let command: String
                if hasPlaceholder {
                    command = commandTemplate.replacingOccurrences(of: "{text}", with: self.clipboardText.replacingOccurrences(of: "'", with: "'\\''"))
                } else {
                    command = commandTemplate
                }
                process.arguments = ["-c", command]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if !hasPlaceholder {
                    let stdinPipe = Pipe()
                    stdinPipe.fileHandleForWriting.write(self.clipboardText.data(using: .utf8) ?? Data())
                    stdinPipe.fileHandleForWriting.closeFile()
                    process.standardInput = stdinPipe
                }

                // 30 second timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 30)
                timer.setEventHandler { process.terminate() }
                timer.resume()

                do {
                    try process.run()
                    process.waitUntilExit()
                    timer.cancel()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    DispatchQueue.main.async {
                        if process.terminationStatus == 0 {
                            Logger.shared.info("Command completed, output: \(stdout.count) chars")
                            self.resultText = stdout
                            self.recordExchange(userPrompt: commandTemplate, selectedText: self.clipboardText, assistant: stdout, thinking: nil)
                            self.state = .result(stdout, thinking: nil)
                        } else {
                            let errorMsg = stderr.isEmpty ? "Command exited with code \(process.terminationStatus)" : stderr
                            Logger.shared.error("Command failed: \(errorMsg)")
                            self.state = .error(errorMsg)
                        }
                        self.updateView()
                    }
                } catch {
                    timer.cancel()
                    DispatchQueue.main.async {
                        Logger.shared.error("Command failed to launch: \(error.localizedDescription)")
                        self.state = .error("Failed to run command: \(error.localizedDescription)")
                        self.updateView()
                    }
                }
            }

        case .llm:
            // PR8: any non-Copy LLM action now opens the full chat, seeded with the
            // action applied to the selection. The agent loop produces the first
            // assistant turn (continuable), instead of the old single-shot result.
            let capturedText = clipboardText
            let seed = capturedText.isEmpty
                ? action.prompt
                : "\(action.prompt)\n\nText:\n\(capturedText)"
            enterChat(
                seedUser: seed,
                selectedText: capturedText.isEmpty ? nil : capturedText,
                autoRun: true)

        case .agent:
            runAgent(action: action)
        }
    }

    // MARK: - Agent chat (PR7 → PR8)

    /// Open the full Claude-style ChatView (PR8) for an `.agent` action. Seeds a
    /// fresh `ChatSession` (system + user, with the selection as context), enters
    /// chat mode (fixed-size panel), and kicks off the agent loop — its result
    /// becomes the first assistant turn, and the user can keep chatting.
    private func runAgent(action: Action) {
        let capturedText = clipboardText
        let userRequest = action.prompt
        let userContent = capturedText.isEmpty
            ? userRequest
            : "\(userRequest)\n\nSelected text:\n\(capturedText)"
        enterChat(
            seedUser: userContent,
            selectedText: capturedText.isEmpty ? nil : capturedText,
            autoRun: true)
    }

    /// Build a fresh chat session, switch into `.chat` state, resize the window to
    /// the fixed chat panel, and (optionally) start generating. Shared by the
    /// "Ask Agent" action, any non-Copy action routed to chat, and the
    /// empty-selection hotkey.
    private func enterChat(seedUser: String, selectedText: String?, autoRun: Bool) {
        let now = Date().timeIntervalSince1970
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: PopDraftAgent.systemPrompt, createdAt: now),
        ]
        if !seedUser.isEmpty {
            messages.append(ChatMessage(role: "user", content: seedUser, createdAt: now))
        }
        var session = ChatSession(
            createdAt: now, updatedAt: now,
            model: LLMClient.shared.currentModel,
            selectedText: selectedText,
            messages: messages)
        session.refreshTitle()
        presentChat(for: session, autoRun: autoRun)
    }

    /// Present `ChatView` for an existing/seeded session and size the panel.
    private func presentChat(for session: ChatSession, autoRun: Bool) {
        let vm = AgentChatViewModel(session: session, store: sessionStore)
        chatViewModel = vm
        // The chat's own save point: the controller persists on copy/minimize.
        currentSession = session
        didSaveCurrentSession = false
        // Record the starting size so an UNCHANGED reopened session isn't re-saved.
        presentedMessageCount = session.messages.count
        state = .chat
        sizeWindowForChat()
        updateView()
        if autoRun { vm.run() }
    }

    /// Resize + recenter the window to the fixed chat panel, clamped to screen.
    private func sizeWindowForChat() {
        guard let window = window else { return }
        let size = NSSize(width: ChatView.panelWidth, height: ChatView.panelHeight)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(
            x: mouseLocation.x - size.width / 2,
            y: mouseLocation.y - size.height - 10)
        if origin.x < screenFrame.minX + 10 { origin.x = screenFrame.minX + 10 }
        if origin.x + size.width > screenFrame.maxX - 10 { origin.x = screenFrame.maxX - size.width - 10 }
        if origin.y < screenFrame.minY + 10 {
            origin.y = screenFrame.midY - size.height / 2
        }
        if origin.y + size.height > screenFrame.maxY - 10 {
            origin.y = screenFrame.maxY - size.height - 10
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Session recording (PR5)

    /// Record one completed exchange into `currentSession`. The single-shot
    /// generation path is untouched — this just snapshots what happened so it can
    /// be persisted on copy/minimize and reopened later.
    ///
    ///  - `userPrompt`: the action prompt or the custom prompt the user ran.
    ///  - `selectedText`: the captured text the action ran on (nil for promptless).
    ///  - `assistant`: the produced result.
    ///  - `thinking`: optional captured reasoning.
    private func recordExchange(userPrompt: String, selectedText: String?, assistant: String, thinking: String?) {
        // A fresh session per invocation (single-shot today; multi-turn arrives
        // with the chat UI in PR8).
        let now = Date().timeIntervalSince1970
        let userMessage = ChatMessage(role: "user", content: userPrompt, createdAt: now)
        let assistantMessage = ChatMessage(role: "assistant", content: assistant, thinking: thinking, createdAt: now)
        var session = ChatSession(
            createdAt: now,
            updatedAt: now,
            model: LLMClient.shared.currentModel,
            selectedText: selectedText,
            messages: [userMessage, assistantMessage]
        )
        session.refreshTitle()
        currentSession = session
        didSaveCurrentSession = false
    }

    /// Persist the current session if it carries a meaningful exchange and hasn't
    /// already been saved. Safe to call from both copy and dismiss. In chat mode
    /// (PR8) the live `AgentChatViewModel.session` is the source of truth (it has
    /// the full multi-turn transcript), so prefer it.
    private func flushSessionIfMeaningful() {
        guard !didSaveCurrentSession else { return }
        let session = chatViewModel?.session ?? currentSession
        guard let session = session, session.hasMeaningfulExchange else { return }
        // Don't pollute Recent with a chat whose only assistant turn is an error
        // (e.g. the server was down) — there's nothing useful to reopen.
        let hasNonErrorAnswer = session.messages.contains {
            $0.role == "assistant" && $0.isError != true
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasNonErrorAnswer else { return }
        // Skip a redundant rewrite of an unmodified reopened session (same message
        // count as when presented) — avoids needless disk writes + title churn.
        if let presented = presentedMessageCount, session.messages.count == presented {
            return
        }
        var s = session
        s.refreshTitle()
        if sessionStore.save(s) {
            didSaveCurrentSession = true
            Logger.shared.info("Saved session \(s.id) (\"\(s.title)\")")
        }
    }

    /// Reopen a previously saved session by id, showing its last assistant message
    /// in the existing result view (PR5 — no chat UI yet). Crash-safe: a missing
    /// session is a no-op.
    func reopenSession(id: String) {
        guard let session = sessionStore.load(id: id) else {
            Logger.shared.error("Could not reopen session \(id)")
            return
        }
        // PR8: reopen as a full, continuable chat (not the old single-message
        // result view). An unchanged session won't be re-saved on dismiss
        // (`presentedMessageCount` guard); a new turn grows it and re-saves.
        onWillShow?()
        // Remember the app to refocus on dismiss (reopen skips captureSelectedText,
        // which is where `previousApp` is normally set).
        previousApp = NSWorkspace.shared.frontmostApplication
        clipboardText = session.selectedText ?? ""
        searchText = ""
        customPromptText = ""
        selectedIndex = 0
        presentChat(for: session, autoRun: false)
        window?.makeKeyAndOrderFront(nil)
        startKeyboardMonitoring()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)

        // PR5: persist the session on copy (before dismiss restores focus).
        flushSessionIfMeaningful()

        // Show brief feedback then dismiss
        showNotification(title: "PopDraft", message: "Copied to clipboard")
        dismiss()
    }

    // MARK: - TTS Controls

    private func startTTSStatusPolling() {
        stopTTSStatusPolling()
        ttsStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            TTSClient.shared.checkStatus { status in
                DispatchQueue.main.async {
                    if status == "idle" {
                        self?.stopTTSStatusPolling()
                        self?.dismiss()
                    }
                }
            }
        }
    }

    private func stopTTSStatusPolling() {
        ttsStatusTimer?.invalidate()
        ttsStatusTimer = nil
    }

    private func stopTTS() {
        stopTTSStatusPolling()
        TTSClient.shared.stop()
        dismiss()
    }

    private func pauseTTS() {
        TTSClient.shared.pause { [weak self] success in
            guard success else { return }
            DispatchQueue.main.async {
                self?.state = .ttsPlaying(isPaused: true)
                self?.updateView()
            }
        }
    }

    private func resumeTTS() {
        TTSClient.shared.resume { [weak self] success in
            guard success else { return }
            DispatchQueue.main.async {
                self?.state = .ttsPlaying(isPaused: false)
                self?.updateView()
            }
        }
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        // Bring System Settings to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        }
    }

    private func restartLlamaServer() {
        let llamaServerExists = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server") ||
                                FileManager.default.fileExists(atPath: "/usr/local/bin/llama-server")
        guard llamaServerExists else {
            self.state = .error("llama-server binary not found. Please install llama.cpp first.")
            self.updateView()
            return
        }

        self.state = .processing
        self.updateView()

        LlamaServerManager.shared.restart { [weak self] success in
            if success {
                self?.state = .actionList
            } else {
                self?.state = .error("Failed to start llama-server. Check /tmp/llm-llama-server.log for details.")
            }
            self?.updateView()
        }
    }

    private func showNotification(title: String, message: String) {
        let script = """
        display notification "\(message.replacingOccurrences(of: "\"", with: "\\\""))" with title "\(title.replacingOccurrences(of: "\"", with: "\\\""))"
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - Settings Window

struct SettingsView: View {
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case actions = "Actions"
        case models = "Models"
        case tts = "Text-to-Speech"
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
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(
                                selectedTab == tab ?
                                Color.accentColor.opacity(0.1) : Color.clear
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()
                .padding(.top, 8)

            // Tab content - fixed height container
            Group {
                switch selectedTab {
                case .general:
                    generalSettingsTab
                case .actions:
                    actionsSettingsTab
                case .models:
                    modelsSettingsTab
                case .tts:
                    ttsSettingsTab
                }
            }
            .frame(height: 340)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500, height: 580)
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
                        Text("MCP servers (from config.json): \(mcpServers.map { $0.name }.joined(separator: ", "))")
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PopDraft Settings"
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

// MARK: - Dependency Manager

class DependencyManager {
    static let shared = DependencyManager()

    var currentInstallProcess: Process?
    var installCancelled = false

    var ttsVenvPython: String {
        NSString(string: "~/.popdraft/tts-venv/bin/python3").expandingTildeInPath
    }

    func cancelInstall() {
        installCancelled = true
        currentInstallProcess?.terminate()
    }

    struct DependencyStatus {
        var hasHomebrew: Bool = false
        var hasEspeak: Bool = false
        var hasPythonPackages: Bool = false
        var hasLlamaCpp: Bool = false
        var hasLlamaModel: Bool = false
        var isLlamaServerRunning: Bool = false
    }

    // Get current model from config
    func getCurrentModel() -> LLMConfig.LlamaModel {
        let config = LLMConfig.load()
        return LLMConfig.llamaModels.first { $0.id == config.llamaModel } ?? LLMConfig.llamaModels[0]
    }

    // Get model by ID
    func getModel(byId id: String) -> LLMConfig.LlamaModel? {
        return LLMConfig.llamaModels.first { $0.id == id }
    }

    // Check if a specific model is downloaded
    func isModelDownloaded(_ modelId: String) -> Bool {
        guard let model = getModel(byId: modelId) else { return false }
        let modelPath = NSString(string: "~/.popdraft/models/\(model.filename)").expandingTildeInPath
        return FileManager.default.fileExists(atPath: modelPath)
    }

    func checkDependencies() -> DependencyStatus {
        var status = DependencyStatus()

        // Check Homebrew
        status.hasHomebrew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
                            FileManager.default.fileExists(atPath: "/usr/local/bin/brew")

        // Check espeak-ng
        status.hasEspeak = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/espeak-ng") ||
                          FileManager.default.fileExists(atPath: "/usr/local/bin/espeak-ng") ||
                          FileManager.default.fileExists(atPath: "/usr/bin/espeak")

        // Check Python packages (in venv)
        let checkScript = "\(ttsVenvPython) -c 'import kokoro; import soundfile; import numpy' 2>/dev/null && echo OK"
        let result = runShellCommand(checkScript)
        status.hasPythonPackages = result.contains("OK")

        // Check llama.cpp
        status.hasLlamaCpp = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server") ||
                            FileManager.default.fileExists(atPath: "/usr/local/bin/llama-server")

        // Check for configured model
        let currentModel = getCurrentModel()
        let modelPath = NSString(string: "~/.popdraft/models/\(currentModel.filename)").expandingTildeInPath
        status.hasLlamaModel = FileManager.default.fileExists(atPath: modelPath)

        // Check if server is running
        let config = LLMConfig.load()
        let healthCheck = runShellCommand("curl -s \(config.llamacppURL)/health 2>/dev/null")
        status.isLlamaServerRunning = healthCheck.contains("ok") || healthCheck.contains("OK")

        return status
    }

    func installDependencies(statusCallback: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.installCancelled = false
            var success = true

            // Check current status
            let status = self.checkDependencies()

            // Install espeak-ng if missing (and homebrew available)
            if !status.hasEspeak && status.hasHomebrew {
                DispatchQueue.main.async { statusCallback("Installing espeak-ng...") }
                let result = self.runShellCommand("/opt/homebrew/bin/brew install espeak-ng 2>&1 || /usr/local/bin/brew install espeak-ng 2>&1", timeout: 300, trackProcess: true)
                if self.installCancelled { return }
                if result.contains("Error") {
                    print("espeak-ng install warning: \(result)")
                }
            }

            // Install Python packages into venv if missing
            if !status.hasPythonPackages {
                DispatchQueue.main.async { statusCallback("Creating Python environment...") }
                let venvDir = NSString(string: "~/.popdraft/tts-venv").expandingTildeInPath
                // Remove old venv to avoid issues with corrupted/partial venvs on Python 3.9
                try? FileManager.default.removeItem(atPath: venvDir)
                let venvResult = self.runShellCommand("python3 -m venv \"\(venvDir)\" 2>&1", timeout: 120, trackProcess: true)
                if self.installCancelled { return }
                if venvResult.contains("Error") {
                    print("venv creation warning: \(venvResult)")
                    success = false
                } else {
                    DispatchQueue.main.async { statusCallback("Installing TTS packages (this may take a few minutes)...") }
                    let pipPath = venvDir + "/bin/pip"
                    let result = self.runShellCommand("\"\(pipPath)\" install --quiet kokoro soundfile numpy 2>&1", timeout: 600, trackProcess: true)
                    if self.installCancelled { return }
                    if result.contains("ERROR") {
                        print("pip install warning: \(result)")
                        success = false
                    }
                }
            }

            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    func installLlamaCpp(modelId: String? = nil, statusCallback: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var status = self.checkDependencies()

            // Get the model to install (use provided ID or current config)
            let model: LLMConfig.LlamaModel
            if let modelId = modelId, let m = self.getModel(byId: modelId) {
                model = m
            } else {
                model = self.getCurrentModel()
            }

            // Install llama.cpp if missing
            if !status.hasLlamaCpp && status.hasHomebrew {
                DispatchQueue.main.async { statusCallback("Installing llama.cpp (this may take a few minutes)...") }
                let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
                let result = self.runShellCommand("\(brewPath) install llama.cpp 2>&1")
                if result.contains("Error") && !result.contains("already installed") {
                    print("llama.cpp install warning: \(result)")
                }
                status = self.checkDependencies()
            }

            // Download model if missing
            let modelPath = NSString(string: "~/.popdraft/models/\(model.filename)").expandingTildeInPath
            if !FileManager.default.fileExists(atPath: modelPath) {
                let modelsDir = NSString(string: "~/.popdraft/models").expandingTildeInPath
                try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)

                // Get expected file size from model (parse from size string like "~2.5GB")
                let expectedSize: Int64
                if model.size.contains("5GB") {
                    expectedSize = 5_000_000_000
                } else if model.size.contains("2.5GB") {
                    expectedSize = 2_500_000_000
                } else if model.size.contains("1.5GB") {
                    expectedSize = 1_500_000_000
                } else {
                    expectedSize = 2_500_000_000 // default
                }

                DispatchQueue.main.async { statusCallback("Downloading \(model.name) (0%)...") }

                // Start curl in background
                let curlProcess = Process()
                curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curlProcess.arguments = ["-L", "-o", modelPath, model.url]
                curlProcess.standardOutput = FileHandle.nullDevice
                curlProcess.standardError = FileHandle.nullDevice
                try? curlProcess.run()

                // Monitor progress
                while curlProcess.isRunning {
                    Thread.sleep(forTimeInterval: 1.0)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
                       let fileSize = attrs[.size] as? Int64 {
                        let percent = min(99, Int((Double(fileSize) / Double(expectedSize)) * 100))
                        let downloadedMB = fileSize / 1_000_000
                        DispatchQueue.main.async {
                            statusCallback("Downloading \(model.name) (\(percent)% - \(downloadedMB)MB)...")
                        }
                    }
                }

                if curlProcess.terminationStatus != 0 {
                    DispatchQueue.main.async {
                        statusCallback("Download failed (error \(curlProcess.terminationStatus)). Check internet connection.")
                    }
                    Thread.sleep(forTimeInterval: 3.0)
                } else {
                    // Verify file was downloaded completely
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
                       let fileSize = attrs[.size] as? Int64, fileSize < 100_000_000 {
                        // File too small, likely an error page or incomplete
                        try? FileManager.default.removeItem(atPath: modelPath)
                        DispatchQueue.main.async {
                            statusCallback("Download failed - file incomplete. Please try again.")
                        }
                        Thread.sleep(forTimeInterval: 3.0)
                    }
                }
                status = self.checkDependencies()
            }

            // Create LaunchAgent for llama-server
            if status.hasLlamaCpp {
                DispatchQueue.main.async { statusCallback("Configuring llama server...") }
                self.createLlamaLaunchAgent(model: model)

                // Unload existing agent if any
                _ = self.runShellCommand("launchctl unload ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>&1")

                // Start the server
                DispatchQueue.main.async { statusCallback("Starting llama server...") }
                _ = self.runShellCommand("launchctl load ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>&1")

                // Wait a moment for server to start
                Thread.sleep(forTimeInterval: 2.0)
            }

            DispatchQueue.main.async {
                let modelExists = FileManager.default.fileExists(atPath: modelPath)
                completion(status.hasLlamaCpp && modelExists)
            }
        }
    }

    /// Escape the five XML special characters so a value can be safely embedded
    /// inside a plist `<string>` element.
    static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func createLlamaLaunchAgent(model: LLMConfig.LlamaModel? = nil) {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        let selectedModel = model ?? getCurrentModel()
        // XML-escape the path before embedding it in the plist (defense-in-depth against
        // a stray `<`, `&`, or quote in a model filename). PR3 also validates HF filenames
        // up front, but the legacy download path reaches here too.
        let rawModelPath = NSString(string: "~/.popdraft/models/\(selectedModel.filename)").expandingTildeInPath
        let modelPath = Self.xmlEscape(rawModelPath)
        let llamaServerPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server")
            ? "/opt/homebrew/bin/llama-server"
            : "/usr/local/bin/llama-server"

        let config = LLMConfig.load()
        let port = URLComponents(string: config.llamacppURL)?.port ?? 10819

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.popdraft.llama-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(llamaServerPath)</string>
        <string>-m</string>
        <string>\(modelPath)</string>
        <string>--port</string>
        <string>\(port)</string>
        <string>-ngl</string>
        <string>99</string>
        <string>--jinja</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-llama-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-llama-server.log</string>
</dict>
</plist>
"""
        let plistPath = launchAgentsDir + "/com.popdraft.llama-server.plist"
        try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    // Public method to update LaunchAgent for a specific model (used by Settings)
    func createLlamaLaunchAgentForModel(_ model: LLMConfig.LlamaModel) {
        createLlamaLaunchAgent(model: model)
    }

    private func runShellCommand(_ command: String, timeout: TimeInterval = 0, trackProcess: Bool = false) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        if trackProcess {
            currentInstallProcess = process
        }

        do {
            try process.run()
        } catch {
            if trackProcess { currentInstallProcess = nil }
            return "Error: \(error)"
        }

        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if installCancelled {
                    process.terminate()
                    if trackProcess { currentInstallProcess = nil }
                    return "Error: Cancelled"
                }
                if Date() > deadline {
                    process.terminate()
                    if trackProcess { currentInstallProcess = nil }
                    return "Error: Timed out after \(Int(timeout))s"
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else {
            process.waitUntilExit()
        }

        if trackProcess { currentInstallProcess = nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - TTS Server Manager

class TTSServerManager {
    static let shared = TTSServerManager()

    private var serverProcess: Process?
    private let serverScript = "~/.popdraft/llm-tts-server.py"
    private let serverURL = "http://127.0.0.1:7865"

    func ensureRunning() {
        // First ensure script exists
        ensureScriptExists()

        // Check if server is already running
        TTSClient.shared.checkHealth { [weak self] isHealthy in
            if !isHealthy {
                DispatchQueue.main.async {
                    self?.startServer()
                }
            }
        }
    }

    private func ensureScriptExists() {
        let destPath = NSString(string: serverScript).expandingTildeInPath
        let configDir = NSString(string: "~/.popdraft").expandingTildeInPath

        // Create config dir if needed
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)

        // If script doesn't exist, copy from bundle
        if !FileManager.default.fileExists(atPath: destPath) {
            if let bundlePath = Bundle.main.path(forResource: "llm-tts-server", ofType: "py") {
                do {
                    try FileManager.default.copyItem(atPath: bundlePath, toPath: destPath)
                    // Make executable
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
                    print("TTS server script copied from bundle to \(destPath)")
                } catch {
                    print("Failed to copy TTS server script: \(error)")
                }
            } else {
                print("TTS server script not found in bundle")
            }
        }
    }

    private let logPath = NSString(string: "~/.popdraft/tts-server.log").expandingTildeInPath

    private func startServer() {
        let expandedPath = NSString(string: serverScript).expandingTildeInPath

        // Check if script exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("TTS server script not found at: \(expandedPath)")
            return
        }

        let venvPython = NSString(string: "~/.popdraft/tts-venv/bin/python3").expandingTildeInPath
        let pythonPath = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/python3"

        // Log server output to file for debugging instead of discarding
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [expandedPath]
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            print("TTS server started with \(pythonPath) (PID: \(process.processIdentifier))")

            // Verify server health after giving it time to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self else { return }
                TTSClient.shared.checkHealth { isHealthy in
                    if !isHealthy {
                        print("TTS server failed to become healthy. Check log: \(self.logPath)")
                        if let proc = self.serverProcess, !proc.isRunning {
                            print("TTS server process exited with code: \(proc.terminationStatus)")
                        }
                    }
                }
            }
        } catch {
            print("Failed to start TTS server: \(error)")
        }
    }

    func stopServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("TTS server stopped")
        }
        serverProcess = nil
    }
}

// MARK: - Update Manager

class UpdateManager: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    private(set) var updateAvailable = false
    private(set) var latestVersion: String?
    private(set) var downloadURL: String?
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0
    var onUpdateStatusChanged: (() -> Void)?

    private let githubAPI = "https://api.github.com/repos/bachner/PopDraft/releases/latest"
    private let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
    private var downloadTask: URLSessionDownloadTask?

    // MARK: - Check for updates

    func checkOnLaunchIfNeeded() {
        let checkFile = "\(configDir)/update_check"
        if let data = FileManager.default.contents(atPath: checkFile),
           let timestamp = String(data: data, encoding: .utf8).flatMap(Double.init) {
            let lastCheck = Date(timeIntervalSince1970: timestamp)
            if Date().timeIntervalSince(lastCheck) < 86400 { return }
        }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool) {
        guard let url = URL(string: githubAPI) else { return }

        var request = URLRequest(url: url)
        request.setValue("PopDraft/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Save check timestamp
            let checkFile = "\(self.configDir)/update_check"
            try? "\(Date().timeIntervalSince1970)".write(toFile: checkFile, atomically: true, encoding: .utf8)

            if let error = error {
                Logger.shared.error("Update check failed: \(error.localizedDescription)")
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "Update Check Failed", message: "Could not connect to GitHub. Please check your internet connection.") }
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "Update Check Failed", message: "Could not parse update information.") }
                }
                return
            }

            // Find DMG asset URL
            var dmgURL: String?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let url = asset["browser_download_url"] as? String {
                        dmgURL = url
                        break
                    }
                }
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if self.isNewerVersion(remoteVersion, than: AppVersion.current) {
                self.updateAvailable = true
                self.latestVersion = remoteVersion
                self.downloadURL = dmgURL
                Logger.shared.info("Update available: v\(remoteVersion)")
                DispatchQueue.main.async { self.onUpdateStatusChanged?() }
                if silent {
                    DispatchQueue.main.async { self.downloadAndInstall() }
                }
            } else {
                self.updateAvailable = false
                self.latestVersion = nil
                self.downloadURL = nil
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "You're Up to Date", message: "PopDraft \(AppVersion.current) is the latest version.") }
                }
            }
        }.resume()
    }

    // MARK: - Version comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        // Dev builds always count as older
        if local.hasPrefix("dev-") { return true }

        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Download and install

    func downloadAndInstall() {
        guard let urlString = downloadURL, let url = URL(string: urlString) else {
            showAlert(title: "Update Error", message: "No download URL available.")
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        onUpdateStatusChanged?()

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
        Logger.shared.info("Downloading update from \(urlString)")
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onUpdateStatusChanged?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dmgPath = "/tmp/PopDraft-update.dmg"
        let dmgURL = URL(fileURLWithPath: dmgPath)

        do {
            // Remove any existing file
            try? FileManager.default.removeItem(at: dmgURL)
            try FileManager.default.moveItem(at: location, to: dmgURL)
            Logger.shared.info("Download complete: \(dmgPath)")
            installFromDMG(at: dmgPath)
        } catch {
            Logger.shared.error("Failed to save DMG: \(error)")
            isDownloading = false
            onUpdateStatusChanged?()
            showAlert(title: "Update Error", message: "Failed to save download: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Logger.shared.error("Download failed: \(error.localizedDescription)")
            isDownloading = false
            downloadProgress = 0
            onUpdateStatusChanged?()
            showAlert(title: "Download Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Install from DMG

    private func installFromDMG(at dmgPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let mountPoint = "/tmp/PopDraft-mount"

            // Detach any stale mount
            let detachStale = Process()
            detachStale.launchPath = "/usr/bin/hdiutil"
            detachStale.arguments = ["detach", mountPoint, "-quiet", "-force"]
            detachStale.standardOutput = FileHandle.nullDevice
            detachStale.standardError = FileHandle.nullDevice
            try? detachStale.run()
            detachStale.waitUntilExit()

            // Mount DMG
            let mount = Process()
            mount.launchPath = "/usr/bin/hdiutil"
            mount.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
            mount.standardOutput = FileHandle.nullDevice
            mount.standardError = FileHandle.nullDevice

            do {
                try mount.run()
                mount.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to mount DMG: \(error.localizedDescription)")
                }
                return
            }

            guard mount.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to mount DMG (exit code \(mount.terminationStatus)).")
                }
                return
            }

            // Find .app in mount
            let appSource = "\(mountPoint)/PopDraft.app"
            guard FileManager.default.fileExists(atPath: appSource) else {
                // Unmount and fail
                let unmount = Process()
                unmount.launchPath = "/usr/bin/hdiutil"
                unmount.arguments = ["detach", mountPoint, "-quiet"]
                unmount.standardOutput = FileHandle.nullDevice
                unmount.standardError = FileHandle.nullDevice
                try? unmount.run()
                unmount.waitUntilExit()

                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "PopDraft.app not found in DMG.")
                }
                return
            }

            let appDest = "/Applications/PopDraft.app"

            do {
                // Remove old app
                if FileManager.default.fileExists(atPath: appDest) {
                    try FileManager.default.removeItem(atPath: appDest)
                }
                // Copy new app
                try FileManager.default.copyItem(atPath: appSource, toPath: appDest)

                // Clear quarantine
                let xattr = Process()
                xattr.launchPath = "/usr/bin/xattr"
                xattr.arguments = ["-cr", appDest]
                xattr.standardOutput = FileHandle.nullDevice
                xattr.standardError = FileHandle.nullDevice
                try? xattr.run()
                xattr.waitUntilExit()

                Logger.shared.info("Updated app installed to \(appDest)")
            } catch {
                Logger.shared.error("Failed to install update: \(error)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to install: \(error.localizedDescription)")
                }
                // Still unmount
                let unmount = Process()
                unmount.launchPath = "/usr/bin/hdiutil"
                unmount.arguments = ["detach", mountPoint, "-quiet"]
                unmount.standardOutput = FileHandle.nullDevice
                unmount.standardError = FileHandle.nullDevice
                try? unmount.run()
                unmount.waitUntilExit()
                return
            }

            // Unmount DMG
            let unmount = Process()
            unmount.launchPath = "/usr/bin/hdiutil"
            unmount.arguments = ["detach", mountPoint, "-quiet"]
            unmount.standardOutput = FileHandle.nullDevice
            unmount.standardError = FileHandle.nullDevice
            try? unmount.run()
            unmount.waitUntilExit()

            // Cleanup
            try? FileManager.default.removeItem(atPath: dmgPath)

            // Relaunch
            DispatchQueue.main.async {
                self.relaunchApp()
            }
        }
    }

    // MARK: - Relaunch

    private func relaunchApp() {
        let appPath = "/Applications/PopDraft.app"
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; killall PopDraft 2>/dev/null; sleep 0.5; open \"\(appPath)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        Logger.shared.info("Relaunching PopDraft...")
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = title.contains("Error") || title.contains("Failed") ? .warning : .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Launch at Login Manager

class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let launchAgentPath: String
    private let bundleIdentifier = "com.popdraft.app"

    init() {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        launchAgentPath = "\(launchAgentsDir)/\(bundleIdentifier).plist"
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            createLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private func createLaunchAgent() {
        // Get the app bundle path
        let appPath = Bundle.main.bundlePath

        // Create LaunchAgents directory if needed
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Create plist content
        let plistContent: [String: Any] = [
            "Label": bundleIdentifier,
            "ProgramArguments": [appPath + "/Contents/MacOS/PopDraft"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        // Write plist
        let plistData = try? PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try? plistData?.write(to: URL(fileURLWithPath: launchAgentPath))

        print("Launch at Login enabled: \(launchAgentPath)")
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
        print("Launch at Login disabled")
    }
}

// MARK: - Onboarding Window

struct OnboardingView: View {
    @State private var hasAccessibility = false
    @State private var selectedProvider: LLMConfig.Provider = .llamacpp
    @State private var apiKey = ""
    @State private var selectedModel = ""
    @State private var selectedLlamaModel: String = "qwen3.5-2b"
    @State private var ollamaModels: [String] = []
    @State private var checkingPermission = false
    @State private var isSettingUp = false
    @State private var setupStatus = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header — bundled Liquid-Glass hero (PR2 asset) with an SF-Symbol
            // fallback for the bare source-install binary (no Assets/ dir).
            VStack(spacing: 8) {
                if let hero = AppAssets.onboardingHero {
                    Image(nsImage: hero)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        .padding(.top, 4)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                }
                Text("Welcome to PopDraft")
                    .font(.title)
                    .fontWeight(.bold)
                Text("System-wide AI text processing for macOS")
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            Divider()

            // Step 1: Accessibility
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "1.circle.fill")
                        .foregroundColor(hasAccessibility ? .green : .accentColor)
                        .font(.title2)
                    Text("Grant Accessibility Access")
                        .font(.headline)
                    Spacer()
                }

                Text("PopDraft needs accessibility permission to capture selected text and register keyboard shortcuts.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !hasAccessibility {
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("Permission granted", systemImage: "checkmark")
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Step 2: Provider Selection
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: hasAccessibility ? "2.circle.fill" : "2.circle")
                        .foregroundColor(hasAccessibility ? .accentColor : .secondary)
                        .font(.title2)
                    Text("Choose Your LLM Backend")
                        .font(.headline)
                    Spacer()
                }

                Picker("", selection: $selectedProvider) {
                    ForEach(LLMConfig.Provider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!hasAccessibility)

                Text(providerDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Model selection for llama.cpp
                if selectedProvider == .llamacpp {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Model:")
                                .font(.callout)
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
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for Ollama
                if selectedProvider == .ollama {
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        if ollamaModels.isEmpty {
                            TextField("e.g., qwen3.5:4b", text: $selectedModel)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $selectedModel) {
                                ForEach(ollamaModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for OpenAI
                if selectedProvider == .openai {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!hasAccessibility)
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        Picker("", selection: $selectedModel) {
                            ForEach(LLMConfig.openaiModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(!hasAccessibility)
                }

                // Model selection for Claude
                if selectedProvider == .claude {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!hasAccessibility)
                    HStack {
                        Text("Model:")
                            .font(.callout)
                        Picker("", selection: $selectedModel) {
                            ForEach(LLMConfig.claudeModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(!hasAccessibility)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .opacity(hasAccessibility ? 1.0 : 0.6)
            .onChange(of: selectedProvider) { _, newValue in
                // Set default model for provider
                switch newValue {
                case .llamacpp:
                    selectedModel = ""
                case .ollama:
                    selectedModel = ollamaModels.first ?? "qwen3.5:4b"
                    fetchOllamaModels()
                case .openai:
                    selectedModel = LLMConfig.openaiModels.first ?? "gpt-4o"
                case .claude:
                    selectedModel = LLMConfig.claudeModels.first ?? "claude-sonnet-4-20250514"
                }
            }

            Spacer()

            // Get Started button with progress
            VStack(spacing: 8) {
                if isSettingUp {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(setupStatus)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                        }
                        Text("This may take a few moments...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(action: {
                            DependencyManager.shared.cancelInstall()
                            finishOnboarding()
                        }) {
                            Text("Skip TTS Setup")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 74)
                } else {
                    Button(action: completeOnboarding) {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasAccessibility)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(width: 450, height: 620)
        .onAppear {
            // Prompt system to add this app to Accessibility list (shows up disabled)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)

            checkAccessibility()
            // Start polling for permission
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                checkAccessibility()
                if hasAccessibility {
                    timer.invalidate()
                }
            }
        }
    }

    private var providerDescription: String {
        switch selectedProvider {
        case .llamacpp:
            return "Runs locally using llama.cpp. Private and free, but requires downloading a model."
        case .ollama:
            return "Local models with Ollama. Easy model management with 'ollama pull'."
        case .openai:
            return "Use GPT-4o and other OpenAI models. Requires an API key."
        case .claude:
            return "Use Claude 3.5/4 models. Requires an Anthropic API key."
        }
    }

    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        // Use AXIsProcessTrustedWithOptions to prompt the system to add THIS app
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Also open settings so user can see and toggle
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        // Bring System Settings to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
        }
    }

    private func fetchOllamaModels() {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return
            }

            DispatchQueue.main.async {
                ollamaModels = models.compactMap { $0["name"] as? String }.sorted()
                if selectedModel.isEmpty, let first = ollamaModels.first {
                    selectedModel = first
                }
            }
        }.resume()
    }

    private func completeOnboarding() {
        isSettingUp = true
        setupStatus = "Saving configuration..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Save config
            var config = LLMConfig.load()
            config.provider = selectedProvider

            switch selectedProvider {
            case .llamacpp:
                config.llamaModel = selectedLlamaModel
            case .ollama:
                config.ollamaModel = selectedModel.isEmpty ? "qwen3.5:4b" : selectedModel
            case .openai:
                config.openaiAPIKey = apiKey
                config.openaiModel = selectedModel.isEmpty ? "gpt-4o" : selectedModel
            case .claude:
                config.claudeAPIKey = apiKey
                config.claudeModel = selectedModel.isEmpty ? "claude-sonnet-4-20250514" : selectedModel
            }
            config.save()

            setupStatus = "Enabling launch at login..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                LaunchAtLoginManager.shared.setEnabled(true)

                // Check and install dependencies
                setupStatus = "Checking dependencies..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Install llama.cpp if selected
                    if selectedProvider == .llamacpp {
                        let depStatus = DependencyManager.shared.checkDependencies()
                        let modelDownloaded = DependencyManager.shared.isModelDownloaded(selectedLlamaModel)
                        if !depStatus.hasLlamaCpp || !modelDownloaded {
                            DependencyManager.shared.installLlamaCpp(
                                modelId: selectedLlamaModel,
                                statusCallback: { status in
                                    self.setupStatus = status
                                },
                                completion: { _ in
                                    self.installTTSDependencies()
                                }
                            )
                        } else {
                            self.installTTSDependencies()
                        }
                    } else {
                        self.installTTSDependencies()
                    }
                }
            }
        }
    }

    private func installTTSDependencies() {
        let depStatus = DependencyManager.shared.checkDependencies()
        if depStatus.hasPythonPackages && depStatus.hasEspeak {
            // TTS dependencies already installed
            self.finishOnboarding()
        } else {
            // Install TTS dependencies
            DependencyManager.shared.installDependencies(
                statusCallback: { status in
                    DispatchQueue.main.async {
                        self.setupStatus = status
                    }
                },
                completion: { _ in
                    DispatchQueue.main.async {
                        self.finishOnboarding()
                    }
                }
            )
        }
    }

    private func finishOnboarding() {
        setupStatus = "Finalizing setup..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Mark onboarding complete
            let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
            let completePath = configDir + "/onboarding_complete"
            FileManager.default.createFile(atPath: completePath, contents: nil)

            // Complete - TTS server will be started by completeStartup()
            onComplete()
        }
    }
}

class OnboardingWindowController: NSWindowController {
    private var hostingView: NSHostingView<OnboardingView>?

    init(onComplete: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to PopDraft"
        window.center()

        super.init(window: window)

        let view = OnboardingView(onComplete: { [weak self] in
            // Close window BEFORE calling onComplete (which may nil out the controller)
            self?.window?.close()
            onComplete()
        })

        hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Hotkey Manager

class HotkeyManager {
    static let shared = HotkeyManager()

    struct HotkeyConfig {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let actionID: String
        let description: String
    }

    // Key code mapping
    private let keyCodeMap: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
        "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
        "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
        "Y": 16, "Z": 6, "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25, "SPACE": 49, "`": 50, "~": 50
    ]

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotkeys: [HotkeyConfig] = []

    func buildHotkeys() -> [HotkeyConfig] {
        let config = LLMConfig.load()
        var hotkeys: [HotkeyConfig] = []
        var id: UInt32 = 1

        // Register popup hotkey (Option + configured key)
        let popupKey = config.popupHotkey.uppercased()
        if let popupKeyCode = keyCodeMap[popupKey] {
            hotkeys.append(HotkeyConfig(id: id, keyCode: popupKeyCode, modifiers: UInt32(optionKey), actionID: "popup", description: "Option+\(popupKey)"))
            id += 1
        }

        // Register shortcuts for all enabled actions
        for action in ActionManager.shared.actions where action.isEnabled {
            guard let shortcutKey = action.shortcut,
                  let keyCode = keyCodeMap[shortcutKey.uppercased()] else { continue }

            hotkeys.append(HotkeyConfig(
                id: id,
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey),
                actionID: action.id,
                description: "Ctrl+Option+\(shortcutKey)"
            ))
            id += 1
        }

        // Register custom prompt shortcut
        if ActionManager.shared.customPromptEnabled,
           let cpShortcut = ActionManager.shared.customPromptShortcut,
           let keyCode = keyCodeMap[cpShortcut.uppercased()] {
            hotkeys.append(HotkeyConfig(
                id: id,
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey),
                actionID: "custom_prompt",
                description: "Ctrl+Option+\(cpShortcut)"
            ))
            id += 1
        }

        return hotkeys
    }

    func registerAll() {
        registeredHotkeys = buildHotkeys()

        // Install single event handler for all hotkeys
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

            DispatchQueue.main.async {
                HotkeyManager.shared.handleHotkey(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandlerRef)

        // Register each hotkey
        for config in registeredHotkeys {
            let hotKeyID = EventHotKeyID(signature: OSType(0x504450), id: config.id) // "PDP" signature
            var hotKeyRef: EventHotKeyRef?

            let status = RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

            if status == noErr, let ref = hotKeyRef {
                hotKeyRefs[config.id] = ref
                print("Registered hotkey: \(config.description) -> \(config.actionID)")
            } else {
                print("Failed to register hotkey: \(config.description) (status: \(status))")
            }
        }
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
    }

    func reloadHotkeys() {
        unregisterAll()
        registerAll()
    }

    func handleHotkey(id: UInt32) {
        guard let config = registeredHotkeys.first(where: { $0.id == id }) else { return }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.triggerAction(actionID: config.actionID)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var popupController: PopupWindowController?
    var bubbleController: BubbleWindowController?
    var settingsController: SettingsWindowController?
    var onboardingController: OnboardingWindowController?
    var updateMenuItem: NSMenuItem?
    var serverStatusMenuItem: NSMenuItem?

    /// PR5: "Recent" submenu listing recently saved sessions. Rebuilt lazily each
    /// time the menu is about to open (so newly saved sessions appear).
    private var recentMenuItem: NSMenuItem?
    private let sessionStore = SessionStore(
        dir: NSString(string: "~/.popdraft").expandingTildeInPath
    )

    private var isOnboardingComplete: Bool {
        let path = NSString(string: "~/.popdraft/onboarding_complete").expandingTildeInPath
        return FileManager.default.fileExists(atPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create Edit menu for standard text editing commands
        setupEditMenu()

        // Check if onboarding needed
        if !isOnboardingComplete {
            showOnboarding()
            return
        }

        // Normal startup
        completeStartup()
    }

    private func showOnboarding() {
        onboardingController = OnboardingWindowController(onComplete: { [weak self] in
            self?.onboardingController = nil
            self?.completeStartup()
        })
        onboardingController?.showWindow()
    }

    private func completeStartup() {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Bespoke code-drawn template glyph (orb + sparkle) that adapts to
            // light/dark menu bars. Fall back to the SF Symbol only if drawing
            // somehow returns nil.
            if let glyph = MenuBarGlyph.template() {
                button.image = glyph
            } else {
                button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "PopDraft")
                button.image?.isTemplate = true
            }
        }

        // Create menu
        let menu = NSMenu()
        menu.delegate = self  // rebuild the Recent submenu each time the menu opens
        menu.addItem(NSMenuItem(title: "Show Popup", action: #selector(showPopup), keyEquivalent: ""))

        // PR5: Recent sessions submenu. Populated lazily in menuNeedsUpdate(_:).
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu(title: "Recent")
        menu.addItem(recentItem)
        recentMenuItem = recentItem

        menu.addItem(NSMenuItem.separator())

        let statusMenuItem = NSMenuItem(title: "llama.cpp: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        serverStatusMenuItem = statusMenuItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About PopDraft", action: #selector(showAbout), keyEquivalent: ""))
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = menu

        // Create controllers
        popupController = PopupWindowController()
        settingsController = SettingsWindowController()

        // PR4: persistent corner bubble. Clicking it expands into the panel at
        // the cursor (same path as the hotkey). The popup minimizes the bubble
        // while it's open and restores it on dismiss/copy — but ONLY when the
        // bubble is enabled, so the disabled case is byte-for-byte today's flow.
        bubbleController = BubbleWindowController()
        bubbleController?.onExpand = { [weak self] in
            self?.popupController?.showAtMouseLocation()
        }
        popupController?.onWillShow = { [weak self] in
            // Hide the orb while the expanded panel is open.
            if self?.isBubbleEnabled == true { self?.bubbleController?.hide() }
        }
        popupController?.onDidDismiss = { [weak self] in
            // Restore the orb to its corner once the panel closes.
            if self?.isBubbleEnabled == true { self?.bubbleController?.show() }
        }
        if isBubbleEnabled {
            bubbleController?.show()
        }

        // Start TTS server if needed
        TTSServerManager.shared.ensureRunning()

        // PR6: compile the web engine's content-blocking rules once at startup
        // (cached by WebKit). The engine itself is lazy; this just primes it.
        Task { @MainActor in await WebEngine.shared.warmUp() }

        // Ensure llama.cpp server is running if configured
        let config = LLMConfig.load()
        if config.provider == .llamacpp {
            let plistPath = NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath
            if FileManager.default.fileExists(atPath: plistPath) {
                DispatchQueue.global(qos: .utility).async {
                    let uid = getuid()
                    // Ensure service is enabled
                    let enableProcess = Process()
                    enableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    enableProcess.arguments = ["enable", "gui/\(uid)/com.popdraft.llama-server"]
                    enableProcess.standardOutput = FileHandle.nullDevice
                    enableProcess.standardError = FileHandle.nullDevice
                    try? enableProcess.run()
                    enableProcess.waitUntilExit()

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["bootstrap", "gui/\(uid)", plistPath]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                }
            }

            // Ensure llama.cpp is up to date for newer models
            DispatchQueue.global(qos: .background).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
                process.arguments = ["upgrade", "llama.cpp"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }

        // Start llama.cpp server monitoring
        if config.provider == .llamacpp {
            LlamaServerManager.shared.onStatusChanged = { [weak self] status in
                self?.updateServerStatusMenuItem(status)
            }
            LlamaServerManager.shared.startPolling()
        } else {
            serverStatusMenuItem?.isHidden = true
        }

        // Register all global hotkeys
        HotkeyManager.shared.registerAll()

        Logger.shared.info("PopDraft \(AppVersion.current) started. Press Option+Space to show popup.")

        // Enable launch at login on first run
        let loginFlag = NSString(string: "~/.popdraft/login_configured").expandingTildeInPath
        if !FileManager.default.fileExists(atPath: loginFlag) {
            LaunchAtLoginManager.shared.setEnabled(true)
            FileManager.default.createFile(atPath: loginFlag, contents: nil)
        }

        // Set up update manager
        UpdateManager.shared.onUpdateStatusChanged = { [weak self] in
            self?.refreshUpdateMenuItem()
        }
        UpdateManager.shared.checkOnLaunchIfNeeded()

        // Monitor accessibility permission periodically
        var wasAccessible = AXIsProcessTrusted()
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            let isAccessible = AXIsProcessTrusted()
            if wasAccessible && !isAccessible {
                Logger.shared.error("Accessibility permission was revoked")
                let script = """
                display notification "PopDraft needs Accessibility permission to capture text. Please re-enable it in System Settings > Privacy & Security > Accessibility." with title "PopDraft: Accessibility Permission Lost"
                """
                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]
                try? task.run()
            }
            wasAccessible = isAccessible
        }
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()

        // App menu (required)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit PopDraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregisterAll()
        TTSServerManager.shared.stopServer()
    }

    /// Whether the persistent corner bubble is enabled in config (PR4).
    private var isBubbleEnabled: Bool {
        LLMConfig.load().bubble.enabled
    }

    /// Re-apply bubble settings after the user changes them in Settings: show or
    /// hide the orb and re-pin it to the (possibly new) corner.
    func refreshBubble() {
        guard let bubble = bubbleController else { return }
        if isBubbleEnabled {
            // show() re-pins to the configured corner; if already visible it just
            // re-positions (and fades in if it was hidden).
            bubble.show(animated: !bubble.isVisible)
        } else {
            bubble.hide()
        }
    }

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    // MARK: - Recent sessions submenu (PR5)

    /// `NSMenuDelegate` — refresh the Recent submenu whenever the status-bar menu
    /// is about to open, so newly saved sessions show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildRecentMenu()
    }

    /// Rebuild the "Recent" submenu from the session store. Crash-safe: shows an
    /// "(No recent sessions)" placeholder when empty.
    private func rebuildRecentMenu() {
        guard let submenu = recentMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let summaries = Array(sessionStore.list().prefix(10))
        if summaries.isEmpty {
            let empty = NSMenuItem(title: "No recent sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for summary in summaries {
            let title = summary.title.isEmpty ? "Untitled" : summary.title
            let relative = AppDelegate.relativeTime(from: summary.updatedAt)
            let item = NSMenuItem(
                title: "\(title)  —  \(relative)",
                action: #selector(openRecentSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = summary.id
            submenu.addItem(item)
        }
    }

    @objc private func openRecentSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        popupController?.reopenSession(id: id)
    }

    /// Compact relative time like "just now", "5m ago", "3h ago", "2d ago".
    static func relativeTime(from epoch: Double) -> String {
        let seconds = Date().timeIntervalSince1970 - epoch
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    func triggerAction(actionID: String) {
        if actionID == "popup" {
            showPopup()
        } else {
            popupController?.showWithAction(actionID: actionID)
        }
    }

    @objc func showSettings() {
        settingsController?.showWindow()
    }

    private func updateServerStatusMenuItem(_ status: LlamaServerManager.Status) {
        switch status {
        case .online:
            serverStatusMenuItem?.title = "llama.cpp: Online"
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Online")
            serverStatusMenuItem?.image?.isTemplate = false
        case .loading:
            serverStatusMenuItem?.title = "llama.cpp: Loading Model..."
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Loading")
            serverStatusMenuItem?.image?.isTemplate = false
        case .offline:
            serverStatusMenuItem?.title = "llama.cpp: Offline"
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Offline")
            serverStatusMenuItem?.image?.isTemplate = false
        case .unknown:
            serverStatusMenuItem?.title = "llama.cpp: Checking..."
            serverStatusMenuItem?.image = nil
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PopDraft"
        alert.informativeText = "Version: \(AppVersion.current)\n\nSystem-wide AI text processing for macOS.\n\nUsage:\n1. Select text in any app\n2. Press Option+Space\n3. Select an action\n4. Review result and Copy\n\nProvider: \(LLMClient.shared.providerName)\nModel: \(LLMClient.shared.currentModel)\n\nBuilt by Ofer Bachner"
        // Use the bespoke brand orb when bundled; nil-safe (falls back to the
        // app's default icon when running as a bare source-install binary).
        if let icon = AppAssets.appIconImage {
            alert.icon = icon
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func checkForUpdatesMenu() {
        let mgr = UpdateManager.shared
        if mgr.updateAvailable && !mgr.isDownloading {
            let alert = NSAlert()
            alert.messageText = "Update Available"
            alert.informativeText = "PopDraft v\(mgr.latestVersion ?? "?") is available. You have v\(AppVersion.current).\n\nDownload and install now?"
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                mgr.downloadAndInstall()
            }
        } else if !mgr.isDownloading {
            mgr.checkForUpdates(silent: false)
        }
    }

    private func refreshUpdateMenuItem() {
        let mgr = UpdateManager.shared
        if mgr.isDownloading {
            let pct = Int(mgr.downloadProgress * 100)
            updateMenuItem?.title = "Downloading Update... \(pct)%"
            updateMenuItem?.action = nil
        } else if mgr.updateAvailable {
            updateMenuItem?.title = "Update Available: v\(mgr.latestVersion ?? "")"
            updateMenuItem?.action = #selector(checkForUpdatesMenu)
        } else {
            updateMenuItem?.title = "Check for Updates..."
            updateMenuItem?.action = #selector(checkForUpdatesMenu)
        }

        // Status bar dot indicator
        if let button = statusItem?.button {
            button.title = mgr.updateAvailable ? "·" : ""
        }
    }
}

// =====================================================================
// MARK: - PR6: Web Engine (WebKit-backed orchestration)
//
// An in-app, agent-optimized headless browser. The pure logic (SSRF, DDG
// parsing, Markdown sanitizing, BM25 ranking, config knobs) lives in
// Core.swift and is unit-tested without WebKit. This file wires that logic
// to one persistent offscreen NSWindow hosting a bounded pool of fresh
// WKWebViews, plus a keyless DuckDuckGo search path and an on-disk cache.
//
// Public entry point: `WebEngine.shared` (@MainActor) with async methods
// search / open / read / screenshot / extract — each runnable in parallel
// up to the renderer cap. PR7 registers these as tools.
// =====================================================================

// MARK: - Bundled JS (Readability + HTML→Markdown)

/// JavaScript injected into a loaded page to (1) run a trimmed Mozilla
/// Readability pass on a clone of the document and (2) convert the cleaned
/// node tree to Markdown. Returns a JSON object the Swift side decodes.
/// This is a compact, self-contained reimplementation of Readability's core
/// scoring heuristics (no external file needed; nothing to bundle on disk).
enum WebJS {
    /// Returns `{title, byline, siteName, markdown, textLen}` as a JSON string,
    /// or `{error: "..."}`. `dropImages` controls image handling.
    static func extractScript(dropImages: Bool) -> String {
        return """
        (function() {
          try {
            function txt(n){ return (n.textContent || '').replace(/\\s+/g,' ').trim(); }
            function tag(n){ return n.nodeType===1 ? n.tagName.toUpperCase() : ''; }

            // ---- meta helpers ----
            function meta(names){
              for (var i=0;i<names.length;i++){
                var m = document.querySelector('meta[property="'+names[i]+'"]') ||
                        document.querySelector('meta[name="'+names[i]+'"]');
                if (m && m.content) return m.content.trim();
              }
              return '';
            }
            var docTitle = (document.title||'').trim();
            var ogTitle = meta(['og:title','twitter:title']);
            var title = ogTitle || docTitle || '';
            var byline = meta(['author','article:author','og:article:author']);
            var siteName = meta(['og:site_name','application-name']) ||
                           (location.hostname||'').replace(/^www\\./,'');

            // ---- candidate scoring (trimmed Readability) ----
            var UNLIKELY = /(combx|comment|community|disqus|extra|foot|header|menu|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup|nav|breadcrumb|share|social|promo|cookie|consent|subscribe|newsletter|related|recommend)/i;
            var POSITIVE = /(article|body|content|entry|hentry|main|page|post|text|blog|story)/i;
            var BLOCK_TAGS = {DIV:1,ARTICLE:1,SECTION:1,MAIN:1,TD:1};

            function classId(n){ return ((n.className||'')+' '+(n.id||'')); }

            var candidates = [];
            var all = document.body ? document.body.getElementsByTagName('*') : [];
            for (var i=0;i<all.length;i++){
              var node = all[i];
              var t = tag(node);
              if (!BLOCK_TAGS[t]) continue;
              var ci = classId(node);
              if (UNLIKELY.test(ci) && !POSITIVE.test(ci)) continue;
              // Count paragraph-ish text length.
              var ps = node.getElementsByTagName('p');
              var plen = 0, pcount = 0;
              for (var j=0;j<ps.length;j++){ var tl = txt(ps[j]).length; if (tl>20){ plen += tl; pcount++; } }
              var direct = txt(node).length;
              var score = plen + pcount*25 + Math.min(direct/100, 50);
              if (POSITIVE.test(ci)) score += 30;
              if (t==='ARTICLE' || t==='MAIN') score += 40;
              var commas = (txt(node).match(/,/g)||[]).length;
              score += commas;
              if (score > 25) candidates.push({node:node, score:score});
            }
            candidates.sort(function(a,b){return b.score-a.score;});

            var root = candidates.length ? candidates[0].node :
                       (document.querySelector('article') || document.querySelector('main') || document.body);
            if (!root) return JSON.stringify({error:'no-root'});

            // ---- HTML -> Markdown walk ----
            var SKIP = {SCRIPT:1,STYLE:1,NOSCRIPT:1,NAV:1,ASIDE:1,FORM:1,BUTTON:1,SVG:1,IFRAME:1,FOOTER:1,HEADER:1};
            var dropImages = \(dropImages ? "true" : "false");
            var TRACK = /^(utm_[a-z]+|gclid|fbclid|dclid|gclsrc|msclkid|yclid|mc_cid|mc_eid|igshid|vero_id|vero_conv|_hsenc|_hsmi|mkt_tok|ref|ref_src|ref_url|spm|scm|_openstat|wt_mc|trk|trkcampaign)$/i;
            function cleanURL(u){
              if(!u) return '';
              try{
                var a=document.createElement('a'); a.href=u;
                // Strip tracking query params, preserving the rest.
                if (a.search && a.search.length>1){
                  var parts = a.search.substring(1).split('&');
                  var kept = [];
                  for (var i=0;i<parts.length;i++){
                    var kv = parts[i].split('=');
                    if (!TRACK.test(kv[0])) kept.push(parts[i]);
                  }
                  a.search = kept.length ? ('?'+kept.join('&')) : '';
                }
                return a.href;
              }catch(e){ return u; }
            }
            function inline(n){
              if (n.nodeType===3) return n.nodeValue.replace(/\\s+/g,' ');
              if (n.nodeType!==1) return '';
              var t = tag(n);
              if (SKIP[t]) return '';
              var inner='';
              for (var c=n.firstChild;c;c=c.nextSibling) inner += inline(c);
              if (t==='STRONG'||t==='B'){ return inner.trim()? '**'+inner.trim()+'**' : ''; }
              if (t==='EM'||t==='I'){ return inner.trim()? '*'+inner.trim()+'*' : ''; }
              if (t==='CODE'){ return inner.trim()? '`'+inner.trim()+'`' : ''; }
              if (t==='BR'){ return ' '; }
              if (t==='A'){
                var href = cleanURL(n.getAttribute('href'));
                var label = inner.trim();
                if (!label) return '';
                if (!href || href.indexOf('javascript:')===0) return label;
                return '['+label+']('+href+')';
              }
              if (t==='IMG'){
                if (dropImages) return '';
                var src = cleanURL(n.getAttribute('src'));
                var alt = (n.getAttribute('alt')||'').trim();
                return src ? '!['+alt+']('+src+')' : '';
              }
              return inner;
            }
            var out = [];
            function block(n, depth){
              if (n.nodeType===3){ var s=n.nodeValue.replace(/\\s+/g,' ').trim(); if(s) out.push(s); return; }
              if (n.nodeType!==1) return;
              var t = tag(n);
              if (SKIP[t]) return;
              var ci = classId(n);
              if (UNLIKELY.test(ci) && !POSITIVE.test(ci) && t!=='P') return;
              if (t==='H1'){ out.push('# '+txt(n)); return; }
              if (t==='H2'){ out.push('## '+txt(n)); return; }
              if (t==='H3'){ out.push('### '+txt(n)); return; }
              if (t==='H4'){ out.push('#### '+txt(n)); return; }
              if (t==='H5'){ out.push('##### '+txt(n)); return; }
              if (t==='H6'){ out.push('###### '+txt(n)); return; }
              if (t==='P'){ var p=inline(n).replace(/\\s+/g,' ').trim(); if(p) out.push(p); return; }
              if (t==='BLOCKQUOTE'){
                var q=''; for (var c=n.firstChild;c;c=c.nextSibling) q+=inline(c);
                q=q.replace(/\\s+/g,' ').trim(); if(q) out.push('> '+q); return;
              }
              if (t==='PRE'){
                var code = (n.textContent||'').replace(/\\s+$/,'');
                if (code.trim()) out.push('```\\n'+code+'\\n```'); return;
              }
              if (t==='UL' || t==='OL'){
                var ordered = (t==='OL'); var idx=1;
                for (var c=n.firstChild;c;c=c.nextSibling){
                  if (c.nodeType===1 && tag(c)==='LI'){
                    var li=inline(c).replace(/\\s+/g,' ').trim();
                    if (li){ out.push((ordered? (idx++)+'. ' : '- ')+li); }
                  }
                }
                out.push('');
                return;
              }
              if (t==='TABLE'){
                var rows = n.querySelectorAll('tr');
                var lines=[]; var headerDone=false;
                for (var r=0;r<rows.length;r++){
                  var cells = rows[r].querySelectorAll('th,td');
                  if (!cells.length) continue;
                  var cols=[];
                  for (var k=0;k<cells.length;k++){ cols.push(inline(cells[k]).replace(/\\s+/g,' ').replace(/\\|/g,'\\\\|').trim()); }
                  lines.push('| '+cols.join(' | ')+' |');
                  if (!headerDone){ var sep=[]; for (var s2=0;s2<cols.length;s2++) sep.push('---'); lines.push('| '+sep.join(' | ')+' |'); headerDone=true; }
                }
                if (lines.length) out.push(lines.join('\\n'));
                return;
              }
              if (t==='IMG' && !dropImages){ var im=inline(n); if(im) out.push(im); return; }
              if (t==='FIGURE' || t==='HR'){ if(t==='HR') out.push('---'); }
              // Recurse into generic containers.
              for (var ch=n.firstChild;ch;ch=ch.nextSibling) block(ch, depth+1);
            }
            for (var c=root.firstChild;c;c=c.nextSibling) block(c, 0);

            var md = out.join('\\n\\n');
            return JSON.stringify({
              title: title, byline: byline, siteName: siteName,
              markdown: md, textLen: txt(root).length
            });
          } catch(e){
            return JSON.stringify({error: String(e)});
          }
        })();
        """
    }

    /// Tiny probe used by `open()`: returns `{title, text}` (first chunk of body text).
    static let openProbeScript = """
    (function(){
      var t=(document.title||'').trim();
      var b=document.body? (document.body.innerText||'').replace(/\\s+/g,' ').trim():'';
      return JSON.stringify({title:t, text:b.slice(0,2000)});
    })();
    """

    /// Returns the document's full scroll height for full-page screenshots.
    static let scrollHeightScript = """
    (function(){
      var b=document.body, e=document.documentElement;
      return Math.max(b?b.scrollHeight:0, b?b.offsetHeight:0, e?e.scrollHeight:0, e?e.offsetHeight:0, e?e.clientHeight:0);
    })();
    """

    static let readyStateScript = "document.readyState"
}

// MARK: - Content blocking ruleset

/// Compiles small `WKContentRuleList`s once at startup and caches them. Two
/// variants: ads/trackers only (screenshots need images) and a read-mode
/// variant that also drops image/media to save bandwidth.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    private var adsList: WKContentRuleList?
    private var readList: WKContentRuleList?
    private var compiled = false

    private init() {}

    /// A small bundled ad/tracker blocklist (host-suffix triggers).
    private static let adHosts: [String] = [
        "doubleclick.net", "googlesyndication.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com",
        "facebook.net", "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        "scorecardresearch.com", "quantserve.com", "adnxs.com", "criteo.com",
        "taboola.com", "outbrain.com", "amazon-adsystem.com", "adsrvr.org",
        "hotjar.com", "mixpanel.com", "segment.io", "segment.com",
        "moatads.com", "bidswitch.net", "rubiconproject.com", "pubmatic.com",
        "openx.net", "casalemedia.com", "yieldmo.com", "branch.io",
    ]

    /// Build the JSON rule source. When `blockMedia`, also block image/media types.
    private static func ruleJSON(blockMedia: Bool) -> String {
        var rules: [[String: Any]] = []
        // Block ad/tracker hosts entirely.
        for host in adHosts {
            let esc = host.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": ".*\(esc).*"],
                "action": ["type": "block"],
            ])
        }
        if blockMedia {
            // Block images + media everywhere (read mode: we don't render).
            rules.append([
                "trigger": ["url-filter": ".*", "resource-type": ["image", "media"]],
                "action": ["type": "block"],
            ])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Compile both rule lists once (idempotent). Safe to call at startup.
    func compileIfNeeded() async {
        if compiled { return }
        compiled = true
        let store = WKContentRuleListStore.default()
        if let store = store {
            adsList = try? await store.compileContentRuleList(
                forIdentifier: "popdraft-ads",
                encodedContentRuleList: Self.ruleJSON(blockMedia: false))
            readList = try? await store.compileContentRuleList(
                forIdentifier: "popdraft-read",
                encodedContentRuleList: Self.ruleJSON(blockMedia: true))
        }
    }

    /// Ruleset for read/extract (drops images+media).
    func readModeList() -> WKContentRuleList? { readList }
    /// Ruleset for screenshots/open (ads only; keeps images).
    func adsOnlyList() -> WKContentRuleList? { adsList }
}

// MARK: - Offscreen render host

/// ONE persistent borderless window positioned far offscreen. WKWebViews are
/// added as subviews with an explicit non-zero frame so they actually render
/// (a zero-frame / detached webview snapshots blank). Never made key.
@MainActor
final class OffscreenRenderHost {
    static let shared = OffscreenRenderHost()

    private let window: NSWindow

    private init() {
        let frame = NSRect(x: -10000, y: -10000, width: 1400, height: 2200)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.ignoresMouseEvents = true
        window.alphaValue = 1.0
        window.hasShadow = false
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        window.contentView = host
        // Render offscreen without stealing focus.
        window.orderBack(nil)
    }

    /// Attach a webview as a subview with an explicit frame so it renders.
    func attach(_ webView: WKWebView, frame: NSRect) {
        webView.frame = frame
        window.contentView?.addSubview(webView)
    }

    func detach(_ webView: WKWebView) {
        webView.removeFromSuperview()
    }
}

// MARK: - One-shot navigation delegate

/// Bridges a single navigation to an async continuation: resolves on
/// didFinish, throws on didFail / didFailProvisional / process crash, and
/// enforces the SSRF/scheme policy on the initial request and EVERY redirect.
///
/// SSRF NOTE: the host/IP checks here (and in `WebEngine.guardURL`) classify the
/// address(es) we resolve via `getaddrinfo`. WebKit resolves independently, so a
/// hostile DNS server could in principle return a public IP to us and a private
/// IP to WebKit (DNS-rebinding / TOCTOU). We mitigate by (a) requiring ALL of
/// our resolved addresses to be public, (b) capping redirects, and (c) re-checking
/// every redirect AND the final response URL. Full per-socket IP pinning is a
/// tracked follow-up; until then a residual rebinding risk remains.
@MainActor
final class NavigationBridge: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    /// Max redirects we follow before refusing (defense against redirect loops /
    /// rebinding chains). Exceeding this cancels with an error.
    static let maxRedirects = 8
    private var redirectCount = 0

    /// Called for every navigation action — enforce SSRF + scheme here so a
    /// redirect to an internal IP is blocked mid-flight.
    var policyCheck: ((URL) -> Bool)?
    /// Max bytes allowed for the response body; checked against the response's
    /// `expectedContentLength` in `decidePolicyForNavigationResponse`.
    var maxBytes: Int = .max
    /// Re-validates the response URL's host (resolve + all-public) on the
    /// committed response, catching a host that differs from the request.
    var responseHostCheck: ((URL) -> Bool)?
    /// The REAL HTTP status code of the main-frame response (0 if unknown, e.g.
    /// non-HTTP). Captured in `decidePolicyForNavigationResponse`.
    private(set) var httpStatus: Int = 0

    func wait(_ body: @escaping () -> Void) async throws {
        // Cancellation-aware: if the surrounding task is cancelled (e.g. the
        // renderer-pool timeout wins), resume the continuation with an error so
        // the caller always returns and the pool's `defer` releases its permit.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                body()
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.failure(CancellationError())) }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        let cont = continuation
        continuation = nil
        switch result {
        case .success: cont?.resume()
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            // about:blank is allowed (reset); everything else passes the guard.
            if url.absoluteString.lowercased() != "about:blank" {
                // A redirect re-uses the same navigation; count it and cap.
                if navigationAction.navigationType == .other && webView.isLoading {
                    redirectCount += 1
                    if redirectCount > Self.maxRedirects {
                        decisionHandler(.cancel)
                        resolve(.failure(WebEngineError.navigationFailed("too many redirects")))
                        return
                    }
                }
                if let check = policyCheck, check(url) == false {
                    decisionHandler(.cancel)
                    resolve(.failure(WebEngineError.blockedHost(url.host ?? url.absoluteString)))
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    /// Enforce the byte cap (via `expectedContentLength`) and re-validate the
    /// response host before the body is fetched.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        // Capture the real HTTP status for the main-frame response.
        if navigationResponse.isForMainFrame, let http = response as? HTTPURLResponse {
            httpStatus = http.statusCode
        }
        // Size cap: reject up-front when the server declares an oversized body.
        let expected = response.expectedContentLength
        if expected > 0, SizeGuard.rejectByContentLength(Int(expected), max: maxBytes) {
            decisionHandler(.cancel)
            resolve(.failure(WebEngineError.tooLarge(Int(expected))))
            return
        }
        // Re-validate the committed response URL's host (catches a late rebind).
        if let url = response.url, url.absoluteString.lowercased() != "about:blank" {
            if let check = responseHostCheck, check(url) == false {
                decisionHandler(.cancel)
                resolve(.failure(WebEngineError.blockedHost(url.host ?? url.absoluteString)))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolve(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolve(.failure(WebEngineError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolve(.failure(WebEngineError.navigationFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resolve(.failure(WebEngineError.renderProcessCrashed))
    }
}

// MARK: - Async semaphore (continuation-based)

/// A small FIFO async semaphore bounding concurrent renderers. MainActor-bound
/// so its state is single-threaded by construction.
@MainActor
final class AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { permits = max(1, value) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            w.resume()
        } else {
            permits += 1
        }
    }
}

// MARK: - Renderer pool

/// Bounds concurrent WKWebViews. `withRenderer` acquires a permit, creates a
/// FRESH webview (non-persistent store, desktop UA, content-blocking ruleset),
/// attaches it offscreen, runs the body, and detaches + releases in `defer`.
/// Recreate-per-job (no reuse). Per-job timeout cancels and stops loading.
@MainActor
final class RendererPool {
    private let semaphore: AsyncSemaphore
    private let userAgent: String
    let navTimeoutMs: Int

    init(maxRenderers: Int, navTimeoutMs: Int) {
        self.semaphore = AsyncSemaphore(value: WebTuning.clampRenderers(maxRenderers))
        self.navTimeoutMs = navTimeoutMs
        self.userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    }

    /// `readMode` selects the image/media-blocking ruleset; otherwise ads-only.
    func withRenderer<T: Sendable>(
        readMode: Bool,
        frame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 2000),
        _ body: @escaping @MainActor (WKWebView) async throws -> T
    ) async throws -> T {
        await semaphore.acquire()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: frame, configuration: config)
        webView.customUserAgent = userAgent

        // Attach the compiled content-blocking ruleset.
        let blocker = ContentBlocker.shared
        if let list = readMode ? blocker.readModeList() : blocker.adsOnlyList() {
            webView.configuration.userContentController.add(list)
        }

        OffscreenRenderHost.shared.attach(webView, frame: frame)

        // Run the body under a timeout. The timeout task cancels the body and
        // stops loading; the body task races it.
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            OffscreenRenderHost.shared.detach(webView)
            semaphore.release()
        }

        let timeoutNs = UInt64(max(1000, navTimeoutMs)) * 1_000_000
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await body(webView)
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: timeoutNs)
                webView.stopLoading()
                throw WebEngineError.timeout
            }
            // First to finish wins; cancel the rest.
            guard let first = try await group.next() else {
                throw WebEngineError.navigationFailed("no result")
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Search providers

protocol SearchProvider: Sendable {
    var name: String { get }
    /// Returns nil if this provider is not configured (so the router can cascade).
    func isConfigured(keys: [String: String]) -> Bool
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult]
}

/// Keyless DuckDuckGo provider via the lite endpoint (HTML fallback), plain
/// URLSession GET — no webview, no JS. Parsing lives in `DDGParser` (Core).
struct DuckDuckGoProvider: SearchProvider {
    let name = "ddg"
    /// Search HTML is tiny; cap the body well under the engine's page cap.
    static let maxSearchBytes = 4 * 1024 * 1024
    func isConfigured(keys: [String: String]) -> Bool { true }  // always available

    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        let trimmed = q.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Try lite first, then the html endpoint.
        let endpoints = [
            "https://lite.duckduckgo.com/lite/",
            "https://html.duckduckgo.com/html/",
        ]
        var lastError: Error?
        for endpoint in endpoints {
            guard var comps = URLComponents(string: endpoint) else { continue }
            comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Reject an oversized response up-front (Content-Length) or after read.
                let declared = (response as? HTTPURLResponse)?.expectedContentLength
                if let len = declared, len > 0, SizeGuard.rejectByContentLength(Int(len), max: Self.maxSearchBytes) {
                    lastError = WebEngineError.tooLarge(Int(len)); continue
                }
                if SizeGuard.exceeds(received: data.count, max: Self.maxSearchBytes) {
                    lastError = WebEngineError.tooLarge(data.count); continue
                }
                guard status == 200, let html = String(data: data, encoding: .utf8) else {
                    lastError = WebEngineError.searchFailed("HTTP \(status)")
                    continue
                }
                let results = DDGParser.parseLite(html, maxResults: q.maxResults)
                if !results.isEmpty { return results }
                // Empty parse — try the next endpoint.
            } catch {
                lastError = error
                continue
            }
        }
        if let e = lastError { throw WebEngineError.searchFailed(String(describing: e)) }
        return []
    }
}

/// Key-based provider stubs. They declare configuration via `apiKeys` but are
/// not yet wired to their APIs (PR-later); the router falls through to DDG.
struct TavilyProvider: SearchProvider {
    let name = "tavily"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["tavily"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("tavily provider not implemented")
    }
}

struct BraveProvider: SearchProvider {
    let name = "brave"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["brave"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("brave provider not implemented")
    }
}

struct ExaProvider: SearchProvider {
    let name = "exa"
    func isConfigured(keys: [String: String]) -> Bool { !(keys["exa"] ?? "").isEmpty }
    func search(_ q: SearchQuery, keys: [String: String]) async throws -> [SearchResult] {
        throw WebEngineError.searchFailed("exa provider not implemented")
    }
}

/// Cascades: a configured-key provider first, DuckDuckGo as the always-on
/// fallback. Dedupes results by host+path. Politely rate-limited.
actor SearchRouter {
    private let apiKeys: [String: String]
    private let preferred: String
    private let ddg = DuckDuckGoProvider()
    private let keyed: [SearchProvider]
    private var lastRequest: Date = .distantPast
    private let minInterval: TimeInterval = 0.5

    init(apiKeys: [String: String], preferred: String) {
        self.apiKeys = apiKeys
        self.preferred = preferred
        self.keyed = [TavilyProvider(), BraveProvider(), ExaProvider()]
    }

    private func rateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequest)
        if elapsed < minInterval {
            let waitNs = UInt64((minInterval - elapsed) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
        }
        lastRequest = Date()
    }

    func search(_ q: SearchQuery) async throws -> [SearchResult] {
        await rateLimit()

        // 1) A configured keyed provider matching the preferred name first.
        var providers: [SearchProvider] = []
        if let pref = keyed.first(where: { $0.name == preferred && $0.isConfigured(keys: apiKeys) }) {
            providers.append(pref)
        }
        // 2) Any other configured keyed provider.
        for p in keyed where p.isConfigured(keys: apiKeys) && p.name != preferred {
            providers.append(p)
        }
        // 3) DDG always last as the keyless fallback.
        providers.append(ddg)

        var lastError: Error?
        for p in providers {
            do {
                let results = try await p.search(q, keys: apiKeys)
                if !results.isEmpty { return Self.dedupe(results, limit: q.maxResults) }
            } catch {
                lastError = error
                continue
            }
        }
        if let e = lastError { throw e }
        return []
    }

    /// Dedupe by normalized host+path (drops scheme + query + trailing slash).
    static func dedupe(_ results: [SearchResult], limit: Int) -> [SearchResult] {
        var seen = Set<String>()
        var out: [SearchResult] = []
        for r in results {
            let key: String
            if let comps = URLComponents(string: r.url), let host = comps.host {
                var path = comps.path
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                key = (host + path).lowercased()
            } else {
                key = r.url.lowercased()
            }
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(r)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - Web cache (actor)

/// On-disk + in-memory cache keyed by sha256(method+url+variant), with TTLs per
/// kind and in-flight coalescing so duplicate concurrent requests share one
/// fetch. Bounded with simple LRU eviction.
actor WebCache {
    struct Entry {
        let data: Data
        let storedAt: Date
        let ttl: TimeInterval
        var isFresh: Bool { Date().timeIntervalSince(storedAt) < ttl }
    }

    private var memory: [String: Entry] = [:]
    private var order: [String] = []                  // LRU: oldest first
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let maxEntries: Int
    private let diskDir: String

    init(diskDir: String, maxEntries: Int = 128) {
        self.diskDir = diskDir
        self.maxEntries = maxEntries
        try? FileManager.default.createDirectory(atPath: diskDir, withIntermediateDirectories: true)
    }

    static func key(method: String, url: String, variant: String) -> String {
        let raw = "\(method)|\(url)|\(variant)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ k: String) {
        if let i = order.firstIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }

    private func evictIfNeeded() {
        while memory.count > maxEntries, let oldest = order.first {
            memory.removeValue(forKey: oldest)
            order.removeFirst()
        }
    }

    /// Fetch-or-compute with coalescing. `compute` runs at most once per key
    /// while in flight; the result is cached for `ttl` ONLY when `shouldStore`
    /// returns true (default: always). A transient bad render (e.g. empty
    /// Markdown) can thus be returned to THIS caller without poisoning the cache.
    func value(
        forKey key: String,
        ttl: TimeInterval,
        shouldStore: @escaping @Sendable (Data) -> Bool = { _ in true },
        compute: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        // Fresh memory hit?
        if let e = memory[key], e.isFresh {
            touch(key)
            return e.data
        }
        // Coalesce concurrent identical requests.
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await compute() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        if shouldStore(data) {
            memory[key] = Entry(data: data, storedAt: Date(), ttl: ttl)
            touch(key)
            evictIfNeeded()
        }
        return data
    }

    /// Path for an on-disk artifact (e.g. a screenshot PNG) under the cache dir.
    func diskPath(for name: String) -> String {
        return (diskDir as NSString).appendingPathComponent(name)
    }
}

// MARK: - WebEngine (public async API)

/// The public façade. Owns the renderer pool, search router, content blocker,
/// cache, and safety guard. All methods are async + parallel-safe up to the
/// renderer cap. PR7 registers these as agent tools.
@MainActor
final class WebEngine {
    static let shared = WebEngine()

    private var pool: RendererPool
    private var router: SearchRouter
    private let cache: WebCache
    private let shotsDir: String
    private var config: AppConfig

    private init() {
        let cfg = AppConfig.load(dir: LLMConfig.configDir)
        self.config = cfg
        let cacheDir = (LLMConfig.configDir as NSString).appendingPathComponent("web-cache")
        self.shotsDir = (cacheDir as NSString).appendingPathComponent("shots")
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        self.cache = WebCache(diskDir: cacheDir)
        self.pool = RendererPool(maxRenderers: cfg.webMaxRenderers, navTimeoutMs: cfg.webNavTimeoutMs)
        self.router = SearchRouter(apiKeys: cfg.webSearch.apiKeys, preferred: cfg.webSearch.provider)
    }

    /// Re-read config (renderer cap, timeouts, search keys) and rebuild the pool
    /// and router. Call after the user changes settings.
    func reloadConfig() {
        let cfg = AppConfig.load(dir: LLMConfig.configDir)
        config = cfg
        pool = RendererPool(maxRenderers: cfg.webMaxRenderers, navTimeoutMs: cfg.webNavTimeoutMs)
        router = SearchRouter(apiKeys: cfg.webSearch.apiKeys, preferred: cfg.webSearch.provider)
    }

    /// Compile content-blocking rules at startup (call once from AppDelegate).
    func warmUp() async {
        await ContentBlocker.shared.compileIfNeeded()
    }

    // MARK: SSRF gate

    /// Core SSRF host check, FAIL-CLOSED. Returns nil when the host is safe to
    /// fetch, or a reason string when it must be blocked.
    ///
    /// Rules (in order):
    ///   - TEST-ONLY loopback escape hatch (env-gated; never set in the app).
    ///   - obvious-local literal host (localhost / *.local / *.internal / IP literal) → block.
    ///   - resolve via getaddrinfo: ZERO resolved addresses → block (FAIL CLOSED —
    ///     a non-resolving name is not provably public).
    ///   - ANY resolved address private/loopback/metadata → block (require ALL public).
    ///
    /// Residual DNS-rebinding risk: WebKit resolves independently of us, so this
    /// is TOCTOU. Mitigated by re-checking redirects + the response URL and
    /// capping redirects; full per-socket IP pinning is a tracked follow-up.
    private func ssrfBlockReason(for url: URL) -> String? {
        guard SafetyGuard.isSchemeAllowed(url) else { return "scheme \(url.scheme ?? "(none)")" }
        guard let host = url.host, !host.isEmpty else { return "no host" }
        if SafetyGuard.isTestLoopback(host: host, port: url.port) { return nil }
        if SafetyGuard.isLiteralHostBlocked(host) { return host }
        let addrs = DNSResolver.resolve(host)
        if addrs.isEmpty {
            // FAIL CLOSED: an unresolvable, non-literal host is not provably public.
            return "\(host) (unresolvable)"
        }
        // Require EVERY resolved address to be public.
        for ip in addrs where SafetyGuard.isBlockedIP(ip) {
            return "\(host) -> \(ip)"
        }
        return nil
    }

    /// Validate a URL's scheme + resolved IP BEFORE navigation. Throws on any
    /// blocked scheme/host.
    private func guardURL(_ url: URL) throws {
        guard SafetyGuard.isSchemeAllowed(url) else {
            throw WebEngineError.blockedScheme(url.scheme ?? "(none)")
        }
        guard let host = url.host, !host.isEmpty else {
            throw WebEngineError.invalidURL(url.absoluteString)
        }
        if let reason = ssrfBlockReason(for: url) {
            throw WebEngineError.blockedHost(reason)
        }
    }

    /// A synchronous policy closure used inside `decidePolicyFor` (and the
    /// response check) so redirects / responses to internal IPs are blocked
    /// mid-navigation. Returns true if allowed (fail-closed via `ssrfBlockReason`).
    private func redirectAllowed(_ url: URL) -> Bool {
        return ssrfBlockReason(for: url) == nil
    }

    // MARK: Load + settle

    /// Navigate `webView` to `url`, wait for didFinish, then poll readyState and
    /// apply a bounded settle. Enforces SSRF on the initial request + redirects.
    /// Navigate + settle; returns the real main-frame HTTP status (0 if unknown).
    @discardableResult
    private func loadAndSettle(_ webView: WKWebView, url: URL) async throws -> Int {
        let bridge = NavigationBridge()
        bridge.policyCheck = { [weak self] u in self?.redirectAllowed(u) ?? false }
        bridge.responseHostCheck = { [weak self] u in self?.redirectAllowed(u) ?? false }
        bridge.maxBytes = config.webMaxBytes
        webView.navigationDelegate = bridge
        try await bridge.wait {
            webView.load(URLRequest(url: url))
        }
        // Poll readyState == complete (bounded). Check cancellation explicitly so
        // a renderer-pool timeout propagates out (the pool's `defer` then releases
        // the permit instead of hanging); a transient JS-eval error is tolerated,
        // but the `Task.sleep` uses plain `try` so cancellation isn't swallowed.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = (try? await webView.evaluateJavaScript(WebJS.readyStateScript)) as? String
            if state == "complete" { break }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        // Bounded settle. Plain `try` so cancellation surfaces.
        let settleNs = UInt64(max(0, config.webSettleMs)) * 1_000_000
        if settleNs > 0 { try await Task.sleep(nanoseconds: settleNs) }
        return bridge.httpStatus
    }

    // MARK: search

    func search(_ q: SearchQuery) async throws -> [SearchResult] {
        let key = WebCache.key(method: "GET", url: "search:\(q.query)", variant: "n=\(q.maxResults)")
        // Capture sendable copies for the closure.
        let router = self.router
        let query = q
        let data = try await cache.value(forKey: key, ttl: 300) {
            let results = try await router.search(query)
            return (try? JSONEncoder().encode(results)) ?? Data("[]".utf8)
        }
        return (try? JSONDecoder().decode([SearchResult].self, from: data)) ?? []
    }

    // MARK: open

    func open(_ url: URL) async throws -> OpenResult {
        try guardURL(url)
        return try await pool.withRenderer(readMode: false) { webView in
            let status = try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString
            let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            let probeRaw = (try? await webView.evaluateJavaScript(WebJS.openProbeScript) as? String) ?? "{}"
            var preview = ""
            if let pdata = probeRaw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] {
                preview = String((obj["text"] as? String ?? "").prefix(500))
            }
            // Real HTTP status (0 → unknown, e.g. non-HTTP); fall back to 200 only
            // when WebKit gave us nothing.
            return OpenResult(finalURL: finalURL, status: status > 0 ? status : 200, title: title, preview: preview)
        }
    }

    // MARK: read

    /// Minimum char count for a read to be cached. A render that yields fewer
    /// chars is returned to the caller but NOT cached, so a transient bad render
    /// doesn't poison the 15-min cache. Plain `nonisolated` so the @Sendable
    /// cache predicate can read it.
    nonisolated static let minCacheableReadChars = 20

    func read(_ url: URL, maxChars: Int) async throws -> ReadResult {
        try guardURL(url)
        let cap = maxChars > 0 ? maxChars : config.webReadMaxChars
        let key = WebCache.key(method: "GET", url: url.absoluteString, variant: "read:\(cap)")
        let minChars = WebEngine.minCacheableReadChars   // capture for the @Sendable closure
        let data = try await cache.value(
            forKey: key,
            ttl: 900,
            shouldStore: { d in
                // Only cache a substantial result (decode + check charCount).
                guard let r = try? JSONDecoder().decode(ReadResult.self, from: d) else { return false }
                return r.charCount >= minChars
            },
            compute: { [self] in
                let result = try await self.performRead(url: url, maxChars: cap)
                return (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
            })
        if let decoded = try? JSONDecoder().decode(ReadResult.self, from: data) { return decoded }
        throw WebEngineError.noContent
    }

    private func performRead(url: URL, maxChars: Int) async throws -> ReadResult {
        return try await pool.withRenderer(readMode: true) { webView in
            let status = try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString
            let script = WebJS.extractScript(dropImages: true)
            let raw = (try? await webView.evaluateJavaScript(script) as? String) ?? "{}"
            guard let jdata = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jdata) as? [String: Any] else {
                throw WebEngineError.noContent
            }
            if let err = obj["error"] as? String, !err.isEmpty, obj["markdown"] == nil {
                throw WebEngineError.navigationFailed("extract: \(err)")
            }
            let title = (obj["title"] as? String) ?? ""
            let byline = (obj["byline"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let siteName = (obj["siteName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var markdown = (obj["markdown"] as? String) ?? ""
            markdown = MarkdownSanitizer.collapseWhitespace(markdown)
            let (capped, truncated) = MarkdownSanitizer.truncate(markdown, maxChars: maxChars)
            return ReadResult(
                finalURL: finalURL, status: status > 0 ? status : 200, title: title,
                byline: byline, siteName: siteName,
                markdown: capped, charCount: capped.count, truncated: truncated)
        }
    }

    // MARK: screenshot

    func screenshot(_ url: URL, fullPage: Bool) async throws -> ShotResult {
        try guardURL(url)
        let hashName = WebCache.key(method: "GET", url: url.absoluteString, variant: "shot:\(fullPage)")
        let path = (shotsDir as NSString).appendingPathComponent("\(hashName).png")
        // Disk cache: if a fresh PNG exists, reuse it.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 900,
           let img = NSImage(contentsOfFile: path) {
            return ShotResult(finalURL: url.absoluteString, path: path, width: Int(img.size.width), height: Int(img.size.height), fullPage: fullPage)
        }

        return try await pool.withRenderer(readMode: false, frame: NSRect(x: 0, y: 0, width: 1280, height: 2000)) { webView in
            try await self.loadAndSettle(webView, url: url)
            let finalURL = webView.url?.absoluteString ?? url.absoluteString

            // Full-page height cap. Lowered from 20000 → 12000 to bound the
            // bitmap memory spike (1280 × 12000 × 4 bytes ≈ 61 MB).
            let maxFullPageHeight = 12000
            var targetHeight = 2000
            if fullPage {
                // Evaluate scrollHeight ONCE; it can come back as Int or Double.
                let raw = try? await webView.evaluateJavaScript(WebJS.scrollHeightScript)
                if let h = raw as? Int {
                    targetHeight = min(max(h, 400), maxFullPageHeight)
                } else if let hd = raw as? Double {
                    targetHeight = min(max(Int(hd), 400), maxFullPageHeight)
                } else if let hn = raw as? NSNumber {
                    targetHeight = min(max(hn.intValue, 400), maxFullPageHeight)
                } else {
                    // Could not read the scroll height — log and fall back to the
                    // default viewport height instead of silently guessing.
                    Logger.shared.log("screenshot: scrollHeight unreadable (got \(String(describing: raw))); falling back to \(targetHeight)px")
                }
                webView.frame = NSRect(x: 0, y: 0, width: 1280, height: targetHeight)
                // Let layout settle after resize.
                try await Task.sleep(nanoseconds: 250_000_000)
            }

            let png = try await self.snapshotPNG(webView, height: targetHeight, fullPage: fullPage)
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            let img = NSImage(data: png)
            let w = Int(img?.size.width ?? 1280)
            let h = Int(img?.size.height ?? CGFloat(targetHeight))
            return ShotResult(finalURL: finalURL, path: path, width: w, height: h, fullPage: fullPage)
        }
    }

    /// Take a WKSnapshot and encode it as PNG.
    private func snapshotPNG(_ webView: WKWebView, height: Int, fullPage: Bool) async throws -> Data {
        let snapConfig = WKSnapshotConfiguration()
        if fullPage {
            snapConfig.rect = NSRect(x: 0, y: 0, width: 1280, height: height)
        }
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: snapConfig) { img, err in
                if let img = img { cont.resume(returning: img) }
                else { cont.resume(throwing: err ?? WebEngineError.noContent) }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw WebEngineError.noContent
        }
        return png
    }

    // MARK: extract

    func extract(_ url: URL, instruction: String) async throws -> ExtractResult {
        let read = try await read(url, maxChars: config.webReadMaxChars)
        let chunks = ChunkRanker.chunk(read.markdown)
        let ranked = ChunkRanker.rank(chunks: chunks, instruction: instruction, limit: 5)
        return ExtractResult(finalURL: read.finalURL, title: read.title, instruction: instruction, chunks: ranked)
    }

    // MARK: Tool schemas (re-exported for PR7)

    static let webSearchToolSchema = WebToolSchemas.webSearch
    static let webOpenToolSchema = WebToolSchemas.webOpen
    static let webReadToolSchema = WebToolSchemas.webRead
    static let webScreenshotToolSchema = WebToolSchemas.webScreenshot
    static let webExtractToolSchema = WebToolSchemas.webExtract
}

// =====================================================================
// MARK: - PR7: Agent tools (WebEngine-backed + text) + PopDraftAgent
//
// Concrete `AgentTool`s. The web tools wrap `WebEngine.shared` (PR6) and
// return compact JSON/text the model can read; the text tools are local
// transforms that need no network. `PopDraftAgent` builds the registry and
// runs `AgentLoop` using `LLMClient.chatCompletion` as the injected model.
// =====================================================================

/// Encode a Codable result as compact JSON for a tool's string output. On
/// failure, falls back to a short description so the tool never returns nothing.
private func toolJSON<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "\(value)"
}

/// Parse a `WebToolSchemas` constant into a `ToolSpec`, degrading to a minimal
/// spec (named, no params) instead of crashing if the JSON is ever broken. The
/// constants are valid today (a test asserts it), so this is purely defensive.
private func webToolSpec(_ json: String, fallbackName: String, fallbackDescription: String) -> ToolSpec {
    return ToolSpec.fromOpenAIJSON(json)
        ?? ToolSpec(name: fallbackName, description: fallbackDescription)
}

/// `web_search` — search the web, return [{title,url,snippet}].
struct WebSearchTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webSearch, fallbackName: "web_search", fallbackDescription: "Search the web.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let query = (d["query"] as? String) ?? ""
        guard !query.isEmpty else { return "Error: 'query' is required." }
        var maxResults = 8
        if let n = d["max_results"] as? Int { maxResults = n }
        else if let n = d["max_results"] as? NSNumber { maxResults = n.intValue }
        maxResults = min(10, max(1, maxResults))
        let results = try await WebEngine.shared.search(SearchQuery(query: query, maxResults: maxResults))
        if results.isEmpty { return "No results found for \"\(query)\"." }
        return toolJSON(results)
    }
}

/// Shared helper to validate + build a URL from a tool argument.
private func toolURL(_ raw: Any?) throws -> URL {
    func err(_ msg: String) -> NSError {
        // Put the message in localizedDescription so the model reads a clean
        // "Error: ..." string (not "Error Domain=...").
        NSError(domain: "PopDraftTool", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
    guard let s = raw as? String, !s.isEmpty else {
        throw err("Error: 'url' is required.")
    }
    guard let url = URL(string: s), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
        throw err("Error: 'url' must be an absolute http(s) URL.")
    }
    return url
}

/// `web_open` — load a URL, return {finalURL,status,title,preview}.
struct WebOpenTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webOpen, fallbackName: "web_open", fallbackDescription: "Open a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let url = try toolURL(args.dictionary["url"])
        return toolJSON(try await WebEngine.shared.open(url))
    }
}

/// `web_read` — load a URL, return its main content as clean Markdown.
struct WebReadTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webRead, fallbackName: "web_read", fallbackDescription: "Read a URL as Markdown.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        var maxChars = 0
        if let n = d["max_chars"] as? Int { maxChars = n }
        else if let n = d["max_chars"] as? NSNumber { maxChars = n.intValue }
        let r = try await WebEngine.shared.read(url, maxChars: maxChars)
        // The model mostly wants the Markdown + a little provenance; keep it compact.
        var header = "# \(r.title)\nURL: \(r.finalURL)"
        if let byline = r.byline, !byline.isEmpty { header += "\nBy: \(byline)" }
        if r.truncated { header += "\n(truncated to \(r.charCount) chars)" }
        return header + "\n\n" + r.markdown
    }
}

/// `web_screenshot` — render a URL, save a PNG, return {path,width,height}.
struct WebScreenshotTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webScreenshot, fallbackName: "web_screenshot", fallbackDescription: "Screenshot a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        let fullPage = (d["full_page"] as? Bool) ?? ((d["full_page"] as? NSNumber)?.boolValue ?? false)
        return toolJSON(try await WebEngine.shared.screenshot(url, fullPage: fullPage))
    }
}

/// `web_extract` — read a URL and return the chunks most relevant to an instruction.
struct WebExtractTool: AgentTool {
    var spec: ToolSpec { webToolSpec(WebToolSchemas.webExtract, fallbackName: "web_extract", fallbackDescription: "Extract relevant chunks from a URL.") }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let url = try toolURL(d["url"])
        let instruction = (d["instruction"] as? String) ?? ""
        guard !instruction.isEmpty else { return "Error: 'instruction' is required." }
        let r = try await WebEngine.shared.extract(url, instruction: instruction)
        if r.chunks.isEmpty { return "No content on \(r.finalURL) matched: \(instruction)" }
        return toolJSON(r)
    }
}

// MARK: - Text tools (no network)

private enum TextToolSchemas {
    // Computed (not stored) so they don't count as non-Sendable shared mutable
    // state under -strict-concurrency=complete; each access builds a fresh dict.
    static var summarize: [String: Any] {
        [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "The text to summarize."]],
            "required": ["text"],
        ]
    }
    static var extractText: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The text to search."],
                "instruction": ["type": "string", "description": "What to extract / look for."],
            ],
            "required": ["text", "instruction"],
        ]
    }
}

/// `summarize_text` — return the leading portion of provided text as a compact
/// excerpt the model can reason over (a deterministic local transform).
struct SummarizeTextTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "summarize_text",
                 description: "Condense provided text to a compact excerpt (first paragraphs, char-capped). Use to shrink long text you already have before reasoning over it.",
                 parametersSchema: TextToolSchemas.summarize)
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let text = (args.dictionary["text"] as? String) ?? ""
        guard !text.isEmpty else { return "Error: 'text' is required." }
        let cleaned = MarkdownSanitizer.collapseWhitespace(text)
        let (out, _) = MarkdownSanitizer.truncate(cleaned, maxChars: 2000)
        return out
    }
}

/// `extract_text` — return the chunks of provided text most relevant to an
/// instruction (keyword/BM25 ranked; local, no network).
struct ExtractTextTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "extract_text",
                 description: "Return the chunks of provided text most relevant to an instruction (keyword-ranked). Use to pull a specific answer out of long text you already have.",
                 parametersSchema: TextToolSchemas.extractText)
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let text = (d["text"] as? String) ?? ""
        let instruction = (d["instruction"] as? String) ?? ""
        guard !text.isEmpty else { return "Error: 'text' is required." }
        guard !instruction.isEmpty else { return "Error: 'instruction' is required." }
        let chunks = ChunkRanker.chunk(text)
        let ranked = ChunkRanker.rank(chunks: chunks, instruction: instruction, limit: 5)
        if ranked.isEmpty { return "No part of the text matched: \(instruction)" }
        return toolJSON(ranked)
    }
}

// MARK: - PR9: Mac-control confirmation seam

/// The seam between a Mac-control tool (running off-main inside `ToolRunner`)
/// and the chat UI. The tool `await`s `requestConfirmation(_:)`; the UI renders a
/// confirm card and later calls `resolve(id:decision:)`. `@MainActor`-isolated
/// so all UI state mutation is main-thread safe; the tool hops here via `await`.
///
/// CRITICAL: this is the ONLY way a Mac-control tool obtains permission to run.
/// There is no bypass — a tool with no confirmer (headless / no UI) gets `.deny`
/// from the default broker, so it can never auto-execute.
@MainActor
protocol MacControlConfirmer: AnyObject {
    /// Present `request` to the user and suspend until they decide. Implementations
    /// MUST eventually resolve (approve/edit/deny) — including on cancel/teardown.
    func requestConfirmation(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

/// A broker that funnels confirmation requests from the tool to a UI sink and
/// suspends on a continuation until the UI resolves them. The active chat
/// view-model registers itself as the `sink`; with no sink (headless), every
/// request resolves to `.deny` so nothing can run without a real UI tap.
@MainActor
final class MacControlBroker: MacControlConfirmer {
    /// A presenter the UI implements: show the card; the broker is told the
    /// decision later via `resolve(id:decision:)`.
    @MainActor
    protocol Sink: AnyObject {
        func present(_ request: ConfirmationRequest)
        /// Called when a request is withdrawn (e.g. run cancelled) so the UI can
        /// drop its card.
        func withdraw(id: String)
    }

    weak var sink: Sink?

    private var pending: [String: CheckedContinuation<ConfirmationDecision, Never>] = [:]

    func requestConfirmation(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        // No UI to confirm → deny, structurally. Nothing runs.
        guard let sink = sink else { return .deny }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ConfirmationDecision, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: .deny)
                    return
                }
                self.pending[request.id] = cont
                sink.present(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: request.id, decision: .deny) }
        }
    }

    /// Resolve a pending confirmation (called by the UI on Approve/Edit/Deny).
    func resolve(id: String, decision: ConfirmationDecision) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        sink?.withdraw(id: id)
        cont.resume(returning: decision)
    }

    /// Deny + withdraw everything still pending (used on chat dismiss/cancel).
    func denyAll() {
        let ids = Array(pending.keys)
        for id in ids { resolve(id: id, decision: .deny) }
    }
}

// MARK: - PR9: Mac-control command execution (reuses the .command primitive)

/// Runs a shell command via the SAME `Process` primitive as the `.command`
/// action (zsh + 30s timeout + captured stdout/stderr). Pure execution only —
/// the denylist + confirm-gate are enforced by the CALLER before this is ever
/// reached. Never elevates privileges. Returns (stdout, stderr, exitCode).
enum MacControlExec {
    static let timeoutSeconds: Double = 30

    /// Run `command` in zsh. `@Sendable`/nonisolated so the tool can call it off
    /// the main actor inside the ToolRunner task group.
    static func runShell(_ command: String) -> (stdout: String, stderr: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 30s timeout — terminate the process if it overruns (mirrors .command).
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            // Read BEFORE waitUntilExit to avoid a pipe-buffer deadlock on large output.
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return (out, err, process.terminationStatus)
        } catch {
            timer.cancel()
            return ("", "Failed to launch: \(error.localizedDescription)", -1)
        }
    }

    /// Run an AppleScript via `osascript -e`. Same 30s bound.
    static func runAppleScript(_ script: String) -> (stdout: String, stderr: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return (out, err, process.terminationStatus)
        } catch {
            timer.cancel()
            return ("", "Failed to launch: \(error.localizedDescription)", -1)
        }
    }
}

// MARK: - PR9: Mac-control tools (confirm-gated)

/// Shared confirm-gate logic for `run_shell` / `run_applescript`. This is the
/// SINGLE execution path; both tools route through it so the gate cannot be
/// bypassed.
///
/// Flow for one invocation:
///   1. Denylist check (always) → on hit, return an error, run NOTHING + log.
///   2. `MacControlPolicy.decide` → `.autoApprove` only if the user enabled the
///      safe-read-only setting AND the command is allowlisted; else `.needsConfirm`.
///   3. Dry-run / headless → record "would execute" and return WITHOUT running.
///   4. `.needsConfirm` → `await confirmer.requestConfirmation(...)`:
///        - `.deny`     → return "user denied", run NOTHING.
///        - `.edit(c2)` → re-run the gate on the edited command (deny still applies),
///                        then run it.
///        - `.approve`  → run it.
///   5. Run via `MacControlExec`, cap output, LOG the executed command, return.
struct MacControlGate: @unchecked Sendable {
    // `@unchecked Sendable`: `confirmer` is a MainActor-isolated class, only ever
    // touched via `await confirmer.requestConfirmation(...)` (i.e. on the
    // MainActor); `settings`/`kind` are value/Sendable. No mutable shared state.
    let kind: ConfirmationKind
    let confirmer: (any MacControlConfirmer)?
    let settings: AgentSettings

    /// Thread-safe log line. `Logger.shared` appends to a file via `FileHandle`
    /// (safe to call from any thread), so no actor hop is needed.
    private func log(_ message: String, error: Bool = false) {
        if error { Logger.shared.error(message) } else { Logger.shared.info(message) }
    }

    /// `run(command:)` returns the model-facing tool result string. `runner`
    /// is the actual executor (shell or applescript), injected so the same gate
    /// serves both tools and stays unit-testable.
    func run(command rawCommand: String,
             explanation: String,
             runner: @Sendable (String) -> (stdout: String, stderr: String, exit: Int32)) async -> String {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "Error: an empty command cannot be run." }

        // (1)+(2) Pure decision (denylist first).
        let decision = MacControlPolicy.decide(
            command: command, autoApproveSafeReadOnly: settings.autoApproveSafeReadOnly)
        if case .denied(let reason) = decision {
            log("[mac-control] DENIED (\(kind.rawValue)): \(reason) :: \(command)", error: true)
            return "Error: this command is blocked by the safety denylist (\(reason)). It was NOT run. Propose a safer command."
        }

        // (3) Dry-run / headless: never execute when there's no UI to confirm.
        if settings.macControlDryRun {
            log("[mac-control] DRY-RUN would execute (\(kind.rawValue)): \(command)")
            return "Dry-run: would execute (awaiting confirm): \(command)\n(Mac-control dry-run mode is on, so nothing ran.)"
        }

        // (4) Decide the command to actually run (immutable result via a helper so
        //     nothing is a captured `var`).
        let commandToRun: String
        if case .needsConfirm = decision {
            // No confirmer at all → structurally deny (cannot run without UI).
            guard let confirmer = confirmer else {
                log("[mac-control] no confirmer; refusing to run \(command)")
                return "Error: no confirmation UI is available, so this command was NOT run."
            }
            let req = ConfirmationRequest(
                id: UUID().uuidString, kind: kind, command: command,
                explanation: explanation.isEmpty ? defaultExplanation(command) : explanation)
            let userDecision = await confirmer.requestConfirmation(req)
            switch userDecision {
            case .deny:
                log("[mac-control] user DENIED (\(kind.rawValue)): \(command)")
                return "The user denied running this command. It was NOT run. Do not retry it; ask the user what they'd prefer or continue without it."
            case .approve:
                commandToRun = command
            case .edit(let edited):
                let trimmedEdit = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                // Re-apply the denylist to the edited command — Edit can't smuggle danger.
                if let reason = MacControlGuard.denialReason(trimmedEdit) {
                    log("[mac-control] edited command DENIED: \(reason) :: \(trimmedEdit)", error: true)
                    return "Error: the edited command is blocked by the safety denylist (\(reason)). It was NOT run."
                }
                commandToRun = trimmedEdit.isEmpty ? command : trimmedEdit
            }
        } else {
            // .autoApprove: a user-opted-in safe read-only command.
            commandToRun = command
        }

        // (5) Execute via the .command Process primitive.
        log("[mac-control] EXECUTING (\(kind.rawValue)): \(commandToRun)")
        let result = runner(commandToRun)
        log("[mac-control] done (\(kind.rawValue)) exit=\(result.exit) out=\(result.stdout.count)ch")
        return MacControlOutput.format(stdout: result.stdout, stderr: result.stderr, exitCode: result.exit)
    }

    private func defaultExplanation(_ command: String) -> String {
        switch kind {
        case .shell: return "Run this shell command on your Mac."
        case .applescript: return "Run this AppleScript on your Mac."
        }
    }
}

/// `run_shell` — propose a shell command; runs only after the user approves.
struct RunShellTool: AgentTool {
    let gate: MacControlGate
    var spec: ToolSpec {
        ToolSpec.fromOpenAIJSON(MacControlSchemas.runShell)
            ?? ToolSpec(name: "run_shell", description: "Propose a shell command (user must approve).")
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let command = (d["command"] as? String) ?? ""
        let explanation = (d["explanation"] as? String) ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'command' is required."
        }
        return await gate.run(command: command, explanation: explanation) { cmd in
            MacControlExec.runShell(cmd)
        }
    }
}

/// `run_applescript` — propose an AppleScript; runs only after the user approves.
struct RunAppleScriptTool: AgentTool {
    let gate: MacControlGate
    var spec: ToolSpec {
        ToolSpec.fromOpenAIJSON(MacControlSchemas.runAppleScript)
            ?? ToolSpec(name: "run_applescript", description: "Propose an AppleScript (user must approve).")
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let script = (d["script"] as? String) ?? ""
        let explanation = (d["explanation"] as? String) ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'script' is required."
        }
        return await gate.run(command: script, explanation: explanation) { src in
            MacControlExec.runAppleScript(src)
        }
    }
}

// MARK: - PR9: MCP client (stdio JSON-RPC subprocess)

/// A minimal but real MCP client: spawns the configured server subprocess, does
/// the 2025-06-18 handshake (`initialize` → `notifications/initialized` →
/// `tools/list`), and exposes a `call(tool:arguments:)` that forwards
/// `tools/call` over stdio. The pure wire format lives in `MCPProtocol`
/// (Core.swift); this owns the process + pipes + request/response matching.
///
/// `@unchecked Sendable`: all access is serialized through `ioQueue`; the public
/// async API is the only entry point.
final class MCPClient: @unchecked Sendable {
    let serverName: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let ioQueue = DispatchQueue(label: "com.popdraft.mcp.\(UUID().uuidString)")
    private var nextId = 100
    private var buffer = Data()
    private var started = false

    init(serverName: String) {
        self.serverName = serverName
    }

    /// Spawn the server and run the handshake; returns the discovered tool specs.
    /// Throws if the server can't start or doesn't answer — the caller skips it.
    func start(command: String, args: [String], timeoutMs: Int = 8000) async throws -> [MCPToolSpec] {
        // Resolve the command via /usr/bin/env so a bare name (e.g. "npx") works.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardInput = stdin
        process.standardOutput = stdout
        // Let the server's stderr flow to our stderr/log (don't capture/block on it).
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw NSError(domain: "MCPClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to start MCP server '\(serverName)': \(error.localizedDescription)"])
        }
        started = true

        // initialize → wait for response → send initialized → tools/list.
        _ = try await request(MCPProtocol.initializeRequest(), expectId: 1, timeoutMs: timeoutMs)
        writeLine(MCPProtocol.initializedNotification())
        let listResp = try await request(MCPProtocol.toolsListRequest(id: 2), expectId: 2, timeoutMs: timeoutMs)
        return MCPProtocol.parseToolsList(listResp)
    }

    /// Forward a `tools/call`, returning (text, isError).
    func call(tool: String, arguments: [String: Any], timeoutMs: Int = 30000) async -> (text: String, isError: Bool) {
        guard started, process.isRunning else { return ("Error: MCP server '\(serverName)' is not running.", true) }
        let id = nextRequestId()
        do {
            let resp = try await request(
                MCPProtocol.toolsCallRequest(id: id, name: tool, arguments: arguments),
                expectId: id, timeoutMs: timeoutMs)
            return MCPProtocol.parseToolCallResult(resp)
        } catch {
            return ("Error calling MCP tool '\(tool)': \(error.localizedDescription)", true)
        }
    }

    func shutdown() {
        ioQueue.async { [process, stdin] in
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }

    private func nextRequestId() -> Int {
        return ioQueue.sync { nextId += 1; return nextId }
    }

    /// Write one newline-delimited JSON-RPC message.
    private func writeLine(_ data: Data) {
        ioQueue.async { [stdin] in
            var line = data
            line.append(0x0A)  // '\n'
            try? stdin.fileHandleForWriting.write(contentsOf: line)
        }
    }

    /// Hard cap on the rolling read buffer so a chatty/garbage server can't grow
    /// memory without bound while we wait for our id.
    private static let maxBufferBytes = 4 * 1024 * 1024

    /// Send a request and await the response line whose `id` matches `expectId`.
    /// Reads newline-delimited JSON-RPC from stdout, bounded by `timeoutMs`.
    ///
    /// The blocking `availableData` read is RACED against the remaining deadline
    /// (via a throwing task group) so a silent server that writes nothing and
    /// never EOFs cannot hang the call past the timeout — the deadline is
    /// authoritative.
    private func request(_ data: Data, expectId: Int, timeoutMs: Int) async throws -> Data {
        writeLine(data)
        let handle = stdout.fileHandleForReading
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        // Drain whole lines from a rolling buffer until we see our id (or time out).
        while Date() < deadline {
            if let line = try takeBufferedLine(matching: expectId) { return line }
            let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
            if remainingMs <= 0 { break }

            // Race the (blocking) read against the remaining time budget.
            let chunk: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                        self.ioQueue.async { cont.resume(returning: handle.availableData) }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
                    return nil  // deadline sentinel
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard let chunk = chunk else { break }  // deadline won the race
            if chunk.isEmpty {
                // EOF or no data yet; if the process is gone and nothing's left, stop.
                if !process.isRunning && buffer.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            buffer.append(chunk)
            if buffer.count > Self.maxBufferBytes {
                throw NSError(domain: "MCPClient", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "MCP server '\(serverName)' response exceeded buffer cap"])
            }
        }
        throw NSError(domain: "MCPClient", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "timed out waiting for MCP response id=\(expectId)"])
    }

    /// Pull a complete newline-delimited JSON object from `buffer` whose id
    /// matches (skipping notifications / other ids), or nil if none yet.
    private func takeBufferedLine(matching expectId: Int) throws -> Data? {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let trimmed = line.trimmingTrailingWhitespace()
            if trimmed.isEmpty { continue }
            if MCPProtocol.responseId(trimmed) == expectId { return trimmed }
            // Different id or a notification — discard and keep scanning.
        }
        return nil
    }
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        var d = self
        while let last = d.last, last == 0x20 || last == 0x09 || last == 0x0D || last == 0x0A {
            d.removeLast()
        }
        return d
    }
}

/// An `AgentTool` backed by a discovered MCP tool. Forwards `invoke` to the
/// client's `tools/call`. NOT confirm-gated (MCP servers are explicit,
/// user-configured integrations), but only ever registered when the server is
/// configured + reachable.
struct MCPTool: AgentTool {
    let client: MCPClient
    let originalName: String        // the server-side tool name
    let toolSpec: ToolSpec          // namespaced spec (server__tool)
    var spec: ToolSpec { toolSpec }

    func invoke(_ args: JSONObject) async throws -> String {
        let (text, isError) = await client.call(tool: originalName, arguments: args.dictionary)
        if isError {
            // Surface as a thrown error so ToolRunner marks the result isError,
            // letting the model adapt — same contract as the other tools.
            throw NSError(domain: "MCPTool", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}

/// Spawns every configured+enabled MCP server, runs the handshake, and returns
/// the discovered `AgentTool`s. A server that fails to start/handshake is
/// skipped + logged (never crashes the agent). The live clients are returned so
/// the caller can shut them down when the turn ends.
@MainActor
enum MCPManager {
    static func buildTools(servers: [MCPServerConfig]) async -> (tools: [any AgentTool], clients: [MCPClient]) {
        var tools: [any AgentTool] = []
        var clients: [MCPClient] = []
        for cfg in servers where cfg.enabled && !cfg.command.isEmpty {
            let client = MCPClient(serverName: cfg.name)
            do {
                let specs = try await client.start(command: cfg.command, args: cfg.args)
                for s in specs {
                    let namespaced = s.toToolSpec(serverName: cfg.name)
                    tools.append(MCPTool(client: client, originalName: s.name, toolSpec: namespaced))
                }
                clients.append(client)
                Logger.shared.info("[mcp] '\(cfg.name)' started; \(specs.count) tools")
            } catch {
                client.shutdown()
                Logger.shared.error("[mcp] '\(cfg.name)' skipped: \(error.localizedDescription)")
            }
        }
        return (tools, clients)
    }
}

// MARK: - PopDraftAgent (registry + loop wiring)

/// Builds the tool registry from config and runs the `AgentLoop` over the real
/// model via `LLMClient.chatCompletion`. Minimal entry point for the "Ask Agent"
/// action — returns the final answer plus the updated session.
struct PopDraftAgent {
    /// Default system prompt seeding the agent.
    static let systemPrompt = """
    You are PopDraft, a helpful desktop assistant. You can call tools to search \
    and read the web and to transform text. Think step by step. Prefer to verify \
    facts with the web tools when a question needs current or external \
    information; otherwise answer directly. When you call a tool, wait for its \
    result before answering. Keep final answers concise and well-formatted.
    """

    /// Build the registry of tools the agent may use, honoring config gates.
    ///
    /// - Web tools: gated on `agentSettings.enableWebSearch`.
    /// - Mac-control tools (`run_shell`/`run_applescript`): registered ONLY when
    ///   `agentSettings.enableMacControl == true` (default false). When the gate
    ///   is off they are literally absent from the registry, so the model cannot
    ///   call them. When on, each runs through `MacControlGate` (denylist +
    ///   confirm-before-execute); `confirmer` is the UI seam.
    /// - MCP tools: discovered from each configured+enabled server; failures are
    ///   skipped. The live clients are returned so the caller can shut them down.
    static func buildRegistry(
        config: AppConfig,
        confirmer: (any MacControlConfirmer)? = nil
    ) async -> (registry: ToolRegistry, mcpClients: [MCPClient]) {
        let registry = ToolRegistry()
        // Text tools are always available (no network).
        await registry.register([SummarizeTextTool(), ExtractTextTool()])
        if config.agentSettings.enableWebSearch {
            await registry.register([
                WebSearchTool(), WebOpenTool(), WebReadTool(),
                WebScreenshotTool(), WebExtractTool(),
            ])
        }
        // PR9: confirm-gated Mac-control tools — OFF by default.
        if config.agentSettings.enableMacControl {
            await registry.register([
                RunShellTool(gate: MacControlGate(kind: .shell, confirmer: confirmer, settings: config.agentSettings)),
                RunAppleScriptTool(gate: MacControlGate(kind: .applescript, confirmer: confirmer, settings: config.agentSettings)),
            ])
        }
        // PR9: MCP tools — only for configured+enabled servers (default none).
        let mcp = await MCPManager.buildTools(servers: config.mcpServers)
        if !mcp.tools.isEmpty { await registry.register(mcp.tools) }
        return (registry, mcp.clients)
    }

    /// Run the agent loop on `session`. Returns the loop outcome (updated session
    /// + final answer). The model `call` is `LLMClient.chatCompletion`; tools run
    /// in parallel via `ToolRunner` with the renderer cap as the concurrency cap.
    ///
    /// `confirmer` is the Mac-control confirmation seam (the chat view-model). With
    /// no confirmer, confirm-gated commands structurally resolve to deny.
    static func run(
        session: ChatSession,
        config: AppConfig,
        confirmer: (any MacControlConfirmer)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil,
        onProgress: ToolProgressHook? = nil
    ) async throws -> AgentLoop.Outcome {
        let (registry, mcpClients) = await buildRegistry(config: config, confirmer: confirmer)
        // Shut MCP servers down when the turn ends, however it ends.
        defer { for c in mcpClients { c.shutdown() } }
        // Tool concurrency cap == renderer pool size (web tools are the heavy ones).
        // Per-tool timeout: normally web-nav + slack, but when Mac-control is on a
        // confirm-gated tool may sit AWAITING THE USER'S APPROVAL — so give the
        // batch a generous wall-clock window. (The execution itself is still
        // bounded by MacControlExec's own 30s process timeout.)
        let baseTimeout = max(5000, config.webNavTimeoutMs + 5000)
        let perToolTimeout = config.agentSettings.enableMacControl ? max(baseTimeout, 300_000) : baseTimeout
        let runner = ToolRunner(
            maxConcurrent: max(1, config.webMaxRenderers),
            perToolTimeoutMs: perToolTimeout)
        let loop = AgentLoop(maxIterations: config.agentSettings.maxIterations, runner: runner)

        let modelCall: AgentLoop.ModelCall = { messages, toolsBoxed in
            let tools = unboxTools(toolsBoxed)
            return try await LLMClient.shared.chatCompletion(
                messages: messages, tools: tools.isEmpty ? nil : tools,
                stream: false, onTextDelta: onTextDelta)
        }
        return try await loop.run(
            session: session, registry: registry, call: modelCall, onProgress: onProgress)
    }
}

// MARK: - DNS resolution (for SSRF on resolved IP)

/// Resolves a hostname to its IP strings using getaddrinfo. Pure C API; returns
/// every resolved address so SafetyGuard can reject if ANY is private/loopback.
enum DNSResolver {
    static func resolve(_ host: String) -> [String] {
        // A literal IP resolves to itself.
        if SafetyGuard.parseIPv4(host) != nil || SafetyGuard.parseIPv6(host) != nil {
            return [host]
        }
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0 else { return [] }
        defer { freeaddrinfo(result) }

        var addrs: [String] = []
        var ptr = result
        while let info = ptr {
            let sa = info.pointee.ai_addr
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let sa = sa,
               getnameinfo(sa, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if !ip.isEmpty { addrs.append(ip) }
            }
            ptr = info.pointee.ai_next
        }
        return addrs
    }
}

// MARK: - Headless CLI seam (PR10)
//
// Two hidden modes the eval/visual-regression harnesses drive. Both run with
// NO menu bar / Dock / hotkeys / bubble / onboarding — they boot only what they
// need, do their work on a Task while `NSApplication` pumps the run loop (a
// real main run loop is required for WKWebView in the WebEngine), then exit().
//
//   --agent-once   : run the agent on one prompt, emit a transcript JSON.
//   --ui-screenshot: render one window state to a PNG (visual regression).

/// Parsed `--agent-once` flags.
private struct AgentOnceOptions {
    var prompt: String = ""
    var selectedTextFile: String?
    var provider: String?
    var model: String?
    var seed: Int?
    var allowNetwork: Bool = true
    var outPath: String?
    var screenshotDir: String?
    var maxIterations: Int?
}

/// Tiny `--flag value` parser (shared by both modes). Recognizes `--flag value`
/// and `--flag=value`; unknown flags are ignored (forward-compatible).
private enum CLIArgs {
    static func value(_ flag: String, in args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == flag, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
        }
        return nil
    }
    static func has(_ flag: String, in args: [String]) -> Bool {
        args.contains { $0 == flag || $0.hasPrefix(flag + "=") }
    }
}

/// The headless eval/visual-regression entry point. Detected in `main()` BEFORE
/// any UI setup. Returns true if it handled (and will `exit()`) the process.
enum HeadlessRunner {

    // MARK: Dispatch

    /// If CLI args request a headless mode, set up the run loop, kick off the
    /// work on a Task, and return true (caller must NOT do the normal UI setup).
    /// Returns false for a normal launch.
    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        if CLIArgs.has("--agent-once", in: args) {
            runAgentOnce(args: args)
            return true
        }
        if CLIArgs.has("--ui-screenshot", in: args) {
            runUIScreenshot(args: args)
            return true
        }
        return false
    }

    // MARK: --agent-once

    private static func parseAgentOnce(_ args: [String]) -> AgentOnceOptions {
        var o = AgentOnceOptions()
        o.prompt = CLIArgs.value("--prompt", in: args) ?? ""
        o.selectedTextFile = CLIArgs.value("--selected-text-file", in: args)
        o.provider = CLIArgs.value("--provider", in: args)
        o.model = CLIArgs.value("--model", in: args)
        o.seed = CLIArgs.value("--seed", in: args).flatMap { Int($0) }
        if let n = CLIArgs.value("--allow-network", in: args) { o.allowNetwork = (n != "0") }
        o.outPath = CLIArgs.value("--out", in: args)
        o.screenshotDir = CLIArgs.value("--screenshot-dir", in: args)
        o.maxIterations = CLIArgs.value("--max-iterations", in: args).flatMap { Int($0) }
        return o
    }

    /// Boot the agent for a single prompt, run it under a hard timeout, and emit
    /// a transcript JSON to `--out` (or stdout). Always exits the process.
    private static func runAgentOnce(args: [String]) {
        let opts = parseAgentOnce(args)

        // Redirect ALL on-disk state (config / sessions / web-cache / shots) to a
        // throwaway dir so we never touch the user's ~/.popdraft, and so the
        // provider/model overrides we write are what every component reads.
        let workDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("popdraft-agent-once-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        setenv("PD_CONFIG_DIR", workDir, 1)

        // Load the user's real config as a BASE (so keys/URLs are present), apply
        // overrides, FORCE Mac-control dry-run, then persist into the work dir so
        // LLMClient/WebEngine read the overridden values consistently.
        let realDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".popdraft").path
        var config = AppConfig.load(dir: realDir)
        if let p = opts.provider { config.provider = p }
        if let m = opts.model {
            // Apply the model override to whichever provider is active.
            switch config.provider {
            case "openai": config.openaiModel = m
            case "claude", "anthropic": config.claudeModel = m
            case "ollama": config.ollamaModel = m
            default: config.llamaModel = m
            }
        }
        // Normalize the eval's "anthropic" alias to the app's "claude" provider id.
        if config.provider == "anthropic" { config.provider = "claude" }
        if let mi = opts.maxIterations { config.agentSettings.maxIterations = max(1, mi) }
        // HEADLESS SAFETY: Mac-control NEVER executes — it records "would execute".
        config.agentSettings.macControlDryRun = true
        // Surface Mac-control tools so a prompt CAN request one (and we can prove
        // the dry-run gate held), but they can never actually run.
        config.agentSettings.enableMacControl = true
        // Web tools stay REGISTERED regardless of `--allow-network`: the eval
        // points them at its loopback fixture server (via PD_WEB_ALLOW_LOOPBACK_PORT)
        // and the SafetyGuard/SSRF layer governs real reachability. `--allow-network 0`
        // is a preference, not a hard kill-switch — a tool that can't reach the
        // network records its error in the transcript instead of failing the run.
        _ = config.save(to: workDir)
        // Make sure the live singletons pick up the work-dir config.
        LLMClient.shared.reloadConfig()

        let startWall = Date()
        // Seed the session exactly like the real chat path (system + user), with
        // optional selected-text context.
        let selectedText: String? = opts.selectedTextFile.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        let now = Date().timeIntervalSince1970
        // `--allow-network 0` biases the model toward answering offline (web tools
        // remain available but the agent is told to prefer not using them).
        let systemPrompt = opts.allowNetwork
            ? PopDraftAgent.systemPrompt
            : PopDraftAgent.systemPrompt + "\n\nNetwork access is restricted: prefer to answer from your own knowledge and avoid web tools unless absolutely necessary."
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt, createdAt: now),
        ]
        if let sel = selectedText, !sel.isEmpty {
            messages.append(ChatMessage(
                role: "user",
                content: "Context (selected text):\n\(sel)",
                createdAt: now))
        }
        messages.append(ChatMessage(role: "user", content: opts.prompt, createdAt: now))
        let session = ChatSession(
            createdAt: now, updatedAt: now,
            model: LLMClient.shared.currentModel,
            selectedText: selectedText,
            messages: messages)

        let providerLabel = config.provider
        let modelLabel = LLMClient.shared.currentModel

        // The collector is an actor-isolated reference type so the @Sendable
        // progress hook (which fires from off-main Tasks) can append safely.
        let collector = TranscriptCollector()

        let app = NSApplication.shared
        // No Dock, no menu bar, no status item — purely headless.
        app.setActivationPolicy(.prohibited)

        // Hard timeout watchdog: a wedged model/tool can't hang forever. Emit a
        // partial transcript and exit(1). If the run finishes first it cancels
        // this task — `Task.sleep` then THROWS, so we must NOT fall through to
        // the timeout emit on cancellation (else a fast run reports "timeout").
        let timeoutTask = Task { @MainActor [providerLabel, modelLabel] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)  // 120s
            } catch {
                return  // cancelled (run completed) — do nothing
            }
            guard !Task.isCancelled else { return }
            let json = await collector.makeTranscript(
                finalText: "", iterations: 0, exitStatus: "timeout",
                wallMs: Int(Date().timeIntervalSince(startWall) * 1000),
                provider: providerLabel, model: modelLabel, seed: opts.seed)
            emit(json, to: opts.outPath)
            FileHandle.standardError.write(Data("agent-once: hard timeout after 120s\n".utf8))
            exit(1)
        }

        let onProgress: ToolProgressHook = { event in
            // Sendable hook; the collector actor serializes appends.
            Task.detached { await collector.record(event) }
        }

        Task { @MainActor [providerLabel, modelLabel, config] in
            var exitStatus = "ok"
            var finalText = ""
            var iterations = 0
            do {
                let outcome = try await PopDraftAgent.run(
                    session: session, config: config,
                    confirmer: nil,                 // no UI → confirm-gated cmds can't run
                    onTextDelta: nil, onProgress: onProgress)
                finalText = outcome.finalText
                iterations = outcome.iterations
                if outcome.stoppedAtMax { exitStatus = "max_iterations" }
            } catch {
                exitStatus = "error"
                await collector.recordError("\(error)")
            }
            timeoutTask.cancel()
            // Optionally copy screenshots into a stable dir for the harness.
            if let dir = opts.screenshotDir {
                await collector.relocateScreenshots(to: dir)
            }
            let json = await collector.makeTranscript(
                finalText: finalText, iterations: iterations, exitStatus: exitStatus,
                wallMs: Int(Date().timeIntervalSince(startWall) * 1000),
                provider: providerLabel, model: modelLabel, seed: opts.seed)
            emit(json, to: opts.outPath)
            // Clean the throwaway state dir (screenshots already relocated).
            try? FileManager.default.removeItem(atPath: workDir)
            exit(exitStatus == "ok" || exitStatus == "max_iterations" ? 0 : 1)
        }
        app.run()
    }

    /// Write the transcript JSON to `--out` (or stdout if nil).
    private static func emit(_ json: String, to path: String?) {
        if let path = path {
            try? json.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(json)
        }
    }

    // MARK: --ui-screenshot

    /// Render one deterministic window state to a PNG. Used for visual regression
    /// vs `design-mocks/`. Always exits the process.
    private static func runUIScreenshot(args: [String]) {
        let state = CLIArgs.value("--ui-screenshot", in: args) ?? "bubble"
        let outPath = CLIArgs.value("--out", in: args)
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("popdraft-\(state).png")
        let dark = CLIArgs.has("--dark", in: args)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        Task { @MainActor in
            if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let ok = UIScreenshotRenderer.render(state: state, to: outPath, dark: dark)
            if ok {
                print("ui-screenshot: wrote \(state) → \(outPath)")
                exit(0)
            } else {
                FileHandle.standardError.write(Data("ui-screenshot: failed for state '\(state)'\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}

// MARK: - Transcript collector (PR10)

/// Serializes tool-progress events (which arrive from off-main detached Tasks)
/// into an ordered transcript. An actor so appends are race-free without locks.
actor TranscriptCollector {
    /// One in-flight/finished tool call. Times are ms since the collector's t0.
    private struct ToolRecord {
        var id: String
        var name: String
        var arguments: String
        var startMs: Int
        var endMs: Int?
        var isError: Bool
        var resultPreview: String
    }

    private let t0 = Date()
    private var order: [String] = []                 // call keys in start order
    private var records: [String: ToolRecord] = [:]
    private var fetchedURLs: [String] = []
    private var screenshots: [String] = []
    private var errors: [String] = []

    private func nowMs() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

    func record(_ event: ToolProgressEvent) {
        switch event.phase {
        case .started:
            if records[event.callKey] == nil { order.append(event.callKey) }
            records[event.callKey] = ToolRecord(
                id: event.callKey, name: event.name, arguments: event.arguments,
                startMs: nowMs(), endMs: nil, isError: false, resultPreview: "")
            noteURLs(fromArguments: event.arguments)
        case .finished(let content, let isError):
            if var r = records[event.callKey] {
                r.endMs = nowMs()
                r.isError = isError
                r.resultPreview = String(content.prefix(500))
                records[event.callKey] = r
            } else {
                // Started event missed (shouldn't happen) — synthesize one.
                order.append(event.callKey)
                records[event.callKey] = ToolRecord(
                    id: event.callKey, name: event.name, arguments: event.arguments,
                    startMs: nowMs(), endMs: nowMs(), isError: isError,
                    resultPreview: String(content.prefix(500)))
            }
            noteURLs(fromResult: content, tool: event.name)
        }
    }

    func recordError(_ message: String) { errors.append(message) }

    /// Pull URLs out of a tool-call's `arguments` JSON (the `url` field).
    private func noteURLs(fromArguments raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let u = obj["url"] as? String, !u.isEmpty { addURL(u) }
    }

    /// Pull `finalURL` / screenshot `path` out of a tool RESULT (most web tools
    /// return JSON; `web_read` returns a "URL: <x>" header line).
    private func noteURLs(fromResult content: String, tool: String) {
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            collectURLsAndShots(obj)
            return
        }
        // web_read returns Markdown with a "URL: <final>" provenance line.
        for line in content.split(separator: "\n").prefix(4) {
            if line.hasPrefix("URL: ") { addURL(String(line.dropFirst(5))) }
        }
    }

    private func collectURLsAndShots(_ obj: Any) {
        if let dict = obj as? [String: Any] {
            if let u = dict["finalURL"] as? String { addURL(u) }
            if let u = dict["url"] as? String { addURL(u) }
            if let p = dict["path"] as? String, p.hasSuffix(".png") { addShot(p) }
            for v in dict.values { collectURLsAndShots(v) }
        } else if let arr = obj as? [Any] {
            for v in arr { collectURLsAndShots(v) }
        }
    }

    private func addURL(_ u: String) {
        guard u.hasPrefix("http"), !fetchedURLs.contains(u) else { return }
        fetchedURLs.append(u)
    }
    private func addShot(_ p: String) {
        guard !screenshots.contains(p) else { return }
        screenshots.append(p)
    }

    /// Copy any captured screenshots into `dir`, rewriting the recorded paths.
    func relocateScreenshots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var moved: [String] = []
        for src in screenshots {
            let dest = (dir as NSString).appendingPathComponent((src as NSString).lastPathComponent)
            try? FileManager.default.removeItem(atPath: dest)
            if (try? FileManager.default.copyItem(atPath: src, toPath: dest)) != nil {
                moved.append(dest)
            } else {
                moved.append(src)
            }
        }
        screenshots = moved
    }

    /// Render the full transcript as a JSON string.
    func makeTranscript(finalText: String, iterations: Int, exitStatus: String,
                        wallMs: Int, provider: String, model: String, seed: Int?) -> String {
        var toolCalls: [[String: Any]] = []
        for key in order {
            guard let r = records[key] else { continue }
            toolCalls.append([
                "id": r.id,
                "name": r.name,
                "arguments": r.arguments,
                "startMs": r.startMs,
                "endMs": r.endMs ?? r.startMs,
                "isError": r.isError,
                "resultPreview": r.resultPreview,
            ])
        }
        var root: [String: Any] = [
            "finalText": finalText,
            "iterations": iterations,
            "exitStatus": exitStatus,
            "wallMs": wallMs,
            "provider": provider,
            "model": model,
            "toolCalls": toolCalls,
            "fetchedURLs": fetchedURLs,
            "screenshots": screenshots,
        ]
        if let seed = seed { root["seed"] = seed } else { root["seed"] = NSNull() }
        if !errors.isEmpty { root["errors"] = errors }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"exitStatus\":\"serialize_failed\"}"
        }
        return s
    }
}

// MARK: - UI screenshot renderer (PR10)

/// Renders a SwiftUI window state offscreen to a PNG via `NSHostingView` +
/// `bitmapImageRepForCachingDisplay` (the technique earlier PRs used for
/// previews). Deterministic: seeded sample data, fixed sizes.
@MainActor
enum UIScreenshotRenderer {

    static func render(state: String, to path: String, dark: Bool) -> Bool {
        let view: NSView
        switch state {
        case "bubble":
            view = host(BubbleView(forceHover: true), size: NSSize(width: 120, height: 120))
        case "menu":
            view = host(sampleMenuView(), size: NSSize(width: 420, height: 360))
        case "chat":
            view = host(sampleChatView(), size: NSSize(width: ChatView.panelWidth, height: ChatView.panelHeight))
        case "confirm":
            view = host(sampleConfirmView(), size: NSSize(width: 460, height: 300))
        default:
            FileHandle.standardError.write(Data("unknown state '\(state)' (use bubble|menu|chat|confirm)\n".utf8))
            return false
        }
        if dark { view.appearance = NSAppearance(named: .darkAqua) }
        // Force a layout pass so SwiftUI content is realized before snapshotting.
        view.layoutSubtreeIfNeeded()
        return writePNG(of: view, to: path)
    }

    /// Wrap a SwiftUI view in a sized NSHostingView.
    private static func host<V: View>(_ v: V, size: NSSize) -> NSHostingView<V> {
        let h = NSHostingView(rootView: v)
        h.frame = NSRect(origin: .zero, size: size)
        return h
    }

    /// Snapshot an NSView's content into a PNG file. Returns true on success.
    private static func writePNG(of view: NSView, to path: String) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch { return false }
    }

    // MARK: Seeded sample data

    /// A compact, mock action list mirroring the real menu chrome.
    private static func sampleMenuView() -> some View {
        let actions = ActionManager.defaultActions
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                Text("Search actions…").foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(actions.prefix(7).enumerated()), id: \.offset) { idx, action in
                        ActionRow(action: action, isSelected: idx == 0)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 420, height: 360)
        .background(VisualEffectView(material: .menu, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A seeded chat: a user question, a web_search + web_read tool round
    /// (resolved cards), and a final assistant answer — exercises ToolCallCard.
    private static func sampleChatView() -> some View {
        let now = Date().timeIntervalSince1970
        let searchResult = """
        [{"title":"Paris - Wikipedia","url":"https://en.wikipedia.org/wiki/Paris","snippet":"Paris is the capital and most populous city of France."}]
        """
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: PopDraftAgent.systemPrompt, createdAt: now),
            ChatMessage(role: "user", content: "What is the capital of France? Search the web to be sure.", createdAt: now),
            ChatMessage(role: "assistant", content: "",
                        toolCalls: [
                            ChatToolCall(id: "call_1", name: "web_search",
                                         arguments: "{\"query\":\"capital of France\"}"),
                            ChatToolCall(id: "call_2", name: "web_read",
                                         arguments: "{\"url\":\"https://en.wikipedia.org/wiki/Paris\"}"),
                        ], createdAt: now),
            ChatMessage(role: "tool", content: searchResult, toolCallId: "call_1", createdAt: now),
            ChatMessage(role: "tool",
                        content: "# Paris\nURL: https://en.wikipedia.org/wiki/Paris\n\nParis is the capital and most populous city of France.",
                        toolCallId: "call_2", createdAt: now),
            ChatMessage(role: "assistant",
                        content: "The capital of France is **Paris** — confirmed via Wikipedia. It's the country's most populous city and seat of government.",
                        thinking: "The user wants the capital of France and asked me to verify on the web, so I searched and read the Wikipedia page before answering.",
                        createdAt: now),
        ]
        var session = ChatSession(
            createdAt: now, updatedAt: now, model: "Qwen3.5 · local",
            selectedText: nil, messages: messages)
        session.refreshTitle()
        let vm = AgentChatViewModel(session: session, store: SessionStore(dir: LLMConfig.configDir))
        return ChatView(viewModel: vm, onMinimize: {})
    }

    /// A seeded Mac-control confirm card.
    private static func sampleConfirmView() -> some View {
        let req = ConfirmationRequest(
            id: "sample", kind: .shell,
            command: "git status && git log --oneline -5",
            explanation: "Show the working tree status and the last five commits.")
        return VStack {
            Spacer(minLength: 0)
            ConfirmCardView(request: req, onDecide: { _ in })
                .padding(16)
            Spacer(minLength: 0)
        }
        .frame(width: 460, height: 300)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

// MARK: - Main

@main
struct PopDraftMain {
    static func main() {
        // PR10 eval seam: detect the headless CLI modes BEFORE any menu-bar /
        // window / hotkey / onboarding setup. These set up their own run loop
        // and exit() the process, so a normal launch never reaches them.
        if HeadlessRunner.handleIfRequested() { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
