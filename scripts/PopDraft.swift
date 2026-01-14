#!/usr/bin/env swift
// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing

import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Version

struct AppVersion {
    static var current: String {
        // Try to get version from bundle Info.plist (official release)
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !bundleVersion.isEmpty,
           bundleVersion != "1.0" {  // Default Xcode value
            return bundleVersion
        }

        // Dev build - use compilation timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "dev-\(formatter.string(from: AppVersion.buildDate))"
    }

    // Compilation timestamp (evaluated at compile time via static initialization)
    private static let buildDate: Date = Date()
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

struct LLMAction: Identifiable, Hashable {
    let id: String  // Stable string ID for built-in actions
    let name: String
    let icon: String
    let prompt: String
    let shortcut: String?
    let isTTS: Bool
    let isBuiltIn: Bool

    init(id: String? = nil, name: String, icon: String, prompt: String, shortcut: String?, isTTS: Bool = false, isBuiltIn: Bool = true) {
        self.id = id ?? name.lowercased().replacingOccurrences(of: " ", with: "_")
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.shortcut = shortcut
        self.isTTS = isTTS
        self.isBuiltIn = isBuiltIn
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LLMAction, rhs: LLMAction) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Custom Actions (User-defined)

struct CustomAction: Codable, Identifiable {
    var id: UUID
    var name: String
    var icon: String
    var prompt: String

    init(id: UUID = UUID(), name: String, icon: String, prompt: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.prompt = prompt
    }

    func toLLMAction() -> LLMAction {
        return LLMAction(id: "custom_\(id.uuidString)", name: name, icon: icon, prompt: prompt, shortcut: nil, isBuiltIn: false)
    }
}

class CustomActionManager {
    static let shared = CustomActionManager()

    private let actionsFile = "~/.popdraft/actions.json"
    var customActions: [CustomAction] = []

    init() {
        load()
    }

    func load() {
        let path = NSString(string: actionsFile).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            customActions = []
            return
        }
        do {
            customActions = try JSONDecoder().decode([CustomAction].self, from: data)
        } catch {
            print("Failed to load custom actions: \(error)")
            customActions = []
        }
    }

    func save() {
        let path = NSString(string: actionsFile).expandingTildeInPath
        let dir = NSString(string: "~/.popdraft").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        do {
            let data = try JSONEncoder().encode(customActions)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("Failed to save custom actions: \(error)")
        }
    }

    func add(_ action: CustomAction) {
        customActions.append(action)
        save()
    }

    func update(_ action: CustomAction) {
        if let index = customActions.firstIndex(where: { $0.id == action.id }) {
            customActions[index] = action
            save()
        }
    }

    func delete(_ action: CustomAction) {
        customActions.removeAll { $0.id == action.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        customActions.move(fromOffsets: source, toOffset: destination)
        save()
    }
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
            id: "qwen2.5-3b",
            name: "Qwen 2.5 3B",
            size: "~2.5GB",
            languages: "29+ languages",
            url: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf",
            filename: "qwen2.5-3b-instruct-q4_k_m.gguf"
        ),
        LlamaModel(
            id: "qwen2.5-7b",
            name: "Qwen 2.5 7B",
            size: "~5GB",
            languages: "29+ languages",
            url: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf",
            filename: "qwen2.5-7b-instruct-q4_k_m.gguf"
        ),
        LlamaModel(
            id: "llama-3.2-3b",
            name: "Llama 3.2 3B",
            size: "~2.5GB",
            languages: "8 languages",
            url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "gemma-2-2b",
            name: "Gemma 2 2B",
            size: "~1.5GB",
            languages: "Multilingual",
            url: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf",
            filename: "gemma-2-2b-it-Q4_K_M.gguf"
        ),
        LlamaModel(
            id: "phi-3-mini",
            name: "Phi-3 Mini",
            size: "~2.5GB",
            languages: "Multilingual",
            url: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf",
            filename: "Phi-3-mini-4k-instruct-q4.gguf"
        )
    ]

    var provider: Provider = .llamacpp
    var llamaModel: String = "qwen2.5-3b"
    var llamacppURL: String = "http://localhost:8080"
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen2.5:7b"
    var openaiAPIKey: String = ""
    var openaiModel: String = "gpt-4o"
    var claudeAPIKey: String = ""
    var claudeModel: String = "claude-sonnet-4-5-20250514"
    var ttsVoice: String = "af_heart"
    var ttsSpeed: Double = 1.0
    var disabledBuiltInActions: [String] = []  // IDs of disabled built-in actions
    var customShortcuts: [String: String] = [:]  // actionId -> shortcut key (e.g., "G", "A")
    var popupHotkey: String = "Space"  // Main popup hotkey (with Option modifier)

    // TTS voice list
    static let ttsVoices: [(id: String, name: String, grade: String)] = [
        // American English - Female
        ("af_heart", "Heart (American Female)", "A"),
        ("af_bella", "Bella (American Female)", "A-"),
        ("af_nicole", "Nicole (American Female)", "B-"),
        ("af_aoede", "Aoede (American Female)", "C+"),
        ("af_kore", "Kore (American Female)", "C+"),
        ("af_sarah", "Sarah (American Female)", "C+"),
        ("af_alloy", "Alloy (American Female)", "C"),
        ("af_nova", "Nova (American Female)", "C"),
        ("af_sky", "Sky (American Female)", "C-"),
        ("af_jessica", "Jessica (American Female)", "D"),
        ("af_river", "River (American Female)", "D"),
        // American English - Male
        ("am_fenrir", "Fenrir (American Male)", "C+"),
        ("am_michael", "Michael (American Male)", "C+"),
        ("am_puck", "Puck (American Male)", "C+"),
        ("am_echo", "Echo (American Male)", "D"),
        ("am_eric", "Eric (American Male)", "D"),
        ("am_liam", "Liam (American Male)", "D"),
        ("am_onyx", "Onyx (American Male)", "D"),
        ("am_adam", "Adam (American Male)", "F+"),
        ("am_santa", "Santa (American Male)", "D-"),
        // British English - Female
        ("bf_emma", "Emma (British Female)", "B-"),
        ("bf_isabella", "Isabella (British Female)", "C"),
        ("bf_alice", "Alice (British Female)", "D"),
        ("bf_lily", "Lily (British Female)", "D"),
        // British English - Male
        ("bm_fable", "Fable (British Male)", "C"),
        ("bm_george", "George (British Male)", "C"),
        ("bm_lewis", "Lewis (British Male)", "D+"),
        ("bm_daniel", "Daniel (British Male)", "D"),
        // French
        ("ff_siwis", "Siwis (French Female)", "B-"),
        // Italian
        ("if_sara", "Sara (Italian Female)", "C"),
        ("im_nicola", "Nicola (Italian Male)", "C"),
        // Japanese
        ("jf_alpha", "Alpha (Japanese Female)", "C+"),
        ("jf_gongitsune", "Gongitsune (Japanese Female)", "C"),
        ("jf_tebukuro", "Tebukuro (Japanese Female)", "C"),
        ("jf_nezumi", "Nezumi (Japanese Female)", "C-"),
        ("jm_kumo", "Kumo (Japanese Male)", "C-"),
        // Hindi
        ("hf_alpha", "Alpha (Hindi Female)", "C"),
        ("hf_beta", "Beta (Hindi Female)", "C"),
        ("hm_omega", "Omega (Hindi Male)", "C"),
        ("hm_psi", "Psi (Hindi Male)", "C"),
        // Spanish
        ("ef_dora", "Dora (Spanish Female)", "-"),
        ("em_alex", "Alex (Spanish Male)", "-"),
        // Mandarin Chinese
        ("zf_xiaobei", "Xiaobei (Chinese Female)", "D"),
        ("zf_xiaoni", "Xiaoni (Chinese Female)", "D"),
        ("zf_xiaoxiao", "Xiaoxiao (Chinese Female)", "D"),
        ("zf_xiaoyi", "Xiaoyi (Chinese Female)", "D"),
        ("zm_yunjian", "Yunjian (Chinese Male)", "D"),
        ("zm_yunxi", "Yunxi (Chinese Male)", "D"),
        ("zm_yunxia", "Yunxia (Chinese Male)", "D"),
        ("zm_yunyang", "Yunyang (Chinese Male)", "D"),
        // Brazilian Portuguese
        ("pf_dora", "Dora (Portuguese Female)", "-"),
        ("pm_alex", "Alex (Portuguese Male)", "-"),
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

    static func load() -> LLMConfig {
        var config = LLMConfig()
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".popdraft/config")

        guard let contents = try? String(contentsOf: configPath, encoding: .utf8) else {
            return config
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "PROVIDER":
                config.provider = Provider(rawValue: value) ?? .llamacpp
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

    func save() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".popdraft")
        let configPath = configDir.appendingPathComponent("config")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

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
        lines.append("TTS_VOICE=\(ttsVoice)")
        lines.append("TTS_SPEED=\(ttsSpeed)")
        lines.append("DISABLED_ACTIONS=\(disabledBuiltInActions.joined(separator: ","))")
        lines.append("POPUP_HOTKEY=\(popupHotkey)")
        if let shortcutsData = try? JSONEncoder().encode(customShortcuts),
           let shortcutsString = String(data: shortcutsData, encoding: .utf8) {
            lines.append("CUSTOM_SHORTCUTS=\(shortcutsString)")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // Get effective shortcut for an action (custom or default)
    func getShortcut(for actionId: String, defaultShortcut: String?) -> String? {
        return customShortcuts[actionId] ?? defaultShortcut
    }
}

// MARK: - LLM Client

class LLMClient {
    static let shared = LLMClient()
    private var config: LLMConfig
    private var activeProvider: LLMConfig.Provider?

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

    func generate(prompt: String, systemPrompt: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let provider = config.provider
        activeProvider = provider

        Logger.shared.info("Sending to \(provider.displayName) [\(currentModel)]")

        // Generate with the configured provider, fallback to llama.cpp on failure
        generateWithProvider(provider, prompt: prompt, systemPrompt: systemPrompt) { [weak self] result in
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

    private func generateWithProvider(_ provider: LLMConfig.Provider, prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        switch provider {
        case .llamacpp:
            generateLlamaCpp(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
        case .ollama:
            generateOllama(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
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

    private func generateLlamaCpp(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(config.llamacppURL)/v1/chat/completions") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

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
            "stream": false,
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
                    var cleaned = content
                    if let range = cleaned.range(of: "</think>") {
                        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    completion(.success(cleaned))
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

    // MARK: - Ollama Backend

    private func generateOllama(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(config.ollamaURL)/api/generate") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.ollamaModel,
            "prompt": prompt,
            "stream": false
        ]

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
                   let responseText = json["response"] as? String {
                    var cleaned = responseText
                    if let range = cleaned.range(of: "</think>") {
                        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    completion(.success(cleaned))
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

    // MARK: - OpenAI Backend

    private func generateOpenAI(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
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
                    completion(.success(content))
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

    private func generateClaude(prompt: String, systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.claudeModel,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]

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
                   let content = json["content"] as? [[String: Any]],
                   let first = content.first,
                   let text = first["text"] as? String {
                    completion(.success(text))
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

    let builtInActions: [LLMAction] = [
        LLMAction(
            name: "Fix grammar and spelling",
            icon: "checkmark.circle.fill",
            prompt: "Fix any grammar, spelling, and punctuation errors in this text. Keep the same tone and meaning. Only output the corrected text, nothing else. Preserve the original language.",
            shortcut: "G"
        ),
        LLMAction(
            name: "Articulate",
            icon: "pencil.circle.fill",
            prompt: "Improve this text to be clearer and more professional while keeping the same meaning and tone. Only output the improved text, nothing else. Preserve the original language.",
            shortcut: "A"
        ),
        LLMAction(
            name: "Explain simply",
            icon: "lightbulb.fill",
            prompt: "Explain this text in simple terms that anyone can understand. Only output the explanation, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Craft a reply",
            icon: "arrowshape.turn.up.left.fill",
            prompt: "Write a thoughtful and helpful reply to this message. Be professional and friendly. Only output the reply, nothing else. Preserve the original language.",
            shortcut: "C"
        ),
        LLMAction(
            name: "Continue writing",
            icon: "arrow.right.circle.fill",
            prompt: "Continue writing from where this text ends, matching the style and tone. Only output the continuation, nothing else. Preserve the original language.",
            shortcut: nil
        ),
        LLMAction(
            name: "Read aloud",
            icon: "speaker.wave.2.fill",
            prompt: "",
            shortcut: "S",
            isTTS: true
        )
    ]

    let customPromptAction = LLMAction(
        name: "Custom prompt...",
        icon: "ellipsis.circle.fill",
        prompt: "",
        shortcut: "P"
    )

    // All built-in actions (for settings UI)
    var allBuiltInActions: [LLMAction] {
        return builtInActions + [customPromptAction]
    }

    // Combined actions: enabled built-in + user custom + "Custom prompt..." at end
    var actions: [LLMAction] {
        let config = LLMConfig.load()
        let disabledIds = Set(config.disabledBuiltInActions)

        var result = builtInActions.filter { !disabledIds.contains($0.id) }
        let customActions = CustomActionManager.shared.customActions.map { $0.toLLMAction() }
        result.append(contentsOf: customActions)

        // Only add custom prompt if not disabled
        if !disabledIds.contains(customPromptAction.id) {
            result.append(customPromptAction)
        }
        return result
    }

    func filteredActions(searchText: String) -> [LLMAction] {
        let allActions = actions
        if searchText.isEmpty {
            return allActions
        }
        return allActions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func reloadCustomActions() {
        CustomActionManager.shared.load()
    }

    func isBuiltInActionEnabled(_ actionId: String) -> Bool {
        let config = LLMConfig.load()
        return !config.disabledBuiltInActions.contains(actionId)
    }
}

// MARK: - View State

enum PopupState {
    case actionList
    case customPrompt
    case processing
    case ttsPlaying(isPaused: Bool)
    case result(String)
    case error(String)
}

// MARK: - Popup View

struct PopupView: View {
    @Binding var searchText: String
    @Binding var selectedIndex: Int
    @Binding var state: PopupState
    @Binding var customPromptText: String
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCustomPromptFocused: Bool
    let allActions: [LLMAction]
    let onSelect: (LLMAction) -> Void
    let onCopy: () -> Void
    let onBack: () -> Void
    let onDismiss: () -> Void
    let onTTSStop: () -> Void
    let onTTSPause: () -> Void
    let onTTSResume: () -> Void

    // Computed filtered actions - recomputes when searchText changes
    private var actions: [LLMAction] {
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
            case .ttsPlaying(let isPaused):
                ttsPlayingView(isPaused: isPaused)
            case .result(let text):
                resultView(text: text)
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(width: 320)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
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
        case .ttsPlaying: return "ttsPlaying"
        case .result: return "result"
        case .error: return "error"
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

    private func resultView(text: String) -> some View {
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
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 250)

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

struct ActionRow: View {
    let action: LLMAction
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
            allActions: ActionManager.shared.actions,
            onSelect: { [weak self] action in self?.selectAction(action) },
            onCopy: { [weak self] in self?.copyResult() },
            onBack: { [weak self] in self?.goBack() },
            onDismiss: { [weak self] in self?.dismiss() },
            onTTSStop: { [weak self] in self?.stopTTS() },
            onTTSPause: { [weak self] in self?.pauseTTS() },
            onTTSResume: { [weak self] in self?.resumeTTS() }
        )

        if hostingView == nil {
            hostingView = NSHostingView(rootView: view)
            window?.contentView = hostingView
        } else {
            hostingView?.rootView = view
        }

        // Defer resize to next run loop so SwiftUI can finish layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let hostingView = self.hostingView else { return }
            var size = hostingView.fittingSize
            size.height = min(size.height, 400)  // Maximum height
            self.window?.setContentSize(size)
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

        // Use AppleScript to click Edit > Copy menu (works with Electron apps like Slack)
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

        // Wait for clipboard to update (300ms for Electron apps)
        usleep(300000)  // 300ms

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
        // Capture selected text by simulating Cmd+C
        captureSelectedText()

        // Reset state
        searchText = ""
        selectedIndex = 0
        state = .actionList
        customPromptText = ""
        resultText = ""
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

    func showWithAction(actionName: String) {
        // Capture selected text by simulating Cmd+C
        captureSelectedText()

        // Find the action by name
        guard let action = ActionManager.shared.actions.first(where: { $0.name == actionName }) else {
            showAtMouseLocation() // Fall back to showing popup
            return
        }

        // Reset state and prepare for direct action
        searchText = ""
        selectedIndex = 0
        customPromptText = ""
        resultText = ""

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
        stopTTSStatusPolling()
        stopKeyboardMonitoring()
        window?.orderOut(nil)

        // Refocus the previous app
        if let app = previousApp {
            app.activate(options: [])
        }
        previousApp = nil
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
                        let customAction = LLMAction(
                            name: "Custom",
                            icon: "ellipsis.circle.fill",
                            prompt: self.customPromptText,
                            shortcut: nil
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

    private func selectAction(_ action: LLMAction) {
        // Handle custom prompt
        if action.name == "Custom prompt..." {
            Logger.shared.info("Action selected: Custom prompt")
            state = .customPrompt
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

        // Handle TTS action
        if action.isTTS {
            state = .ttsPlaying(isPaused: false)
            updateView()

            TTSClient.shared.speak(text: clipboardText) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        Logger.shared.info("TTS playback started")
                        // Playback started - start polling for completion
                        self?.startTTSStatusPolling()
                    case .failure(let error):
                        Logger.shared.error("TTS failed: \(error.localizedDescription)")
                        self?.state = .error("TTS Error: \(error.localizedDescription)\n\nMake sure the TTS server is running.")
                        self?.updateView()
                    }
                }
            }
            return
        }

        // Show processing state
        state = .processing
        updateView()

        // Build the full prompt
        let fullPrompt = "\(action.prompt)\n\nText:\n\(clipboardText)"

        // Call LLM backend
        let startTime = Date()
        LLMClient.shared.generate(prompt: fullPrompt) { [weak self] result in
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    Logger.shared.info("LLM response received (\(elapsed), \(response.count) chars)")
                    self?.resultText = response
                    self?.state = .result(response)
                case .failure(let error):
                    Logger.shared.error("LLM failed (\(elapsed)): \(error.localizedDescription)")
                    self?.state = .error(error.localizedDescription)
                }
                self?.updateView()
            }
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)

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
        case llm = "LLM"
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
    @State private var availableOllamaModels: [String] = []
    @State private var isLoading = false
    @State private var customOpenAIModel: String = ""
    @State private var customClaudeModel: String = ""
    @State private var ttsVoice: String = "af_heart"
    @State private var ttsSpeed: Double = 1.0
    @State private var voiceSearchText: String = ""
    @State private var customActions: [CustomAction] = []
    @State private var editingAction: CustomAction? = nil
    @State private var isAddingAction: Bool = false
    @State private var disabledBuiltInActions: Set<String> = []
    @State private var showingActionEditor: Bool = false
    @State private var actionToEdit: CustomAction? = nil
    @State private var customShortcuts: [String: String] = [:]
    @State private var editingShortcutFor: String? = nil  // actionId currently being edited
    @State private var popupHotkey: String = "Space"
    @State private var editingPopupHotkey: Bool = false
    @State private var selectedLlamaModel: String = "qwen2.5-3b"
    @State private var isDownloadingModel: Bool = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadStatus: String = ""
    let onSave: (LLMConfig) -> Void
    let onCancel: () -> Void

    private var filteredVoices: [(id: String, name: String, grade: String)] {
        if voiceSearchText.isEmpty {
            return LLMConfig.ttsVoices
        }
        return LLMConfig.ttsVoices.filter {
            $0.name.localizedCaseInsensitiveContains(voiceSearchText) ||
            $0.id.localizedCaseInsensitiveContains(voiceSearchText)
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
                case .llm:
                    llmSettingsTab
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
        .frame(width: 420, height: 480)
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

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Actions Settings Tab

    private var actionsSettingsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Built-in actions section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Built-in Actions")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 1) {
                            ForEach(ActionManager.shared.allBuiltInActions, id: \.id) { action in
                                builtInActionRow(action: action)
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)

                    // Custom actions section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Custom Actions")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                actionToEdit = nil
                                showingActionEditor = true
                            }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)

                        if customActions.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 4) {
                                    Text("No custom actions")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    Text("Click + to add one")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.7))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 20)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                        } else {
                            VStack(spacing: 1) {
                                ForEach(customActions) { action in
                                    customActionRow(action: action)
                                }
                            }
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.bottom, 12)
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
                        CustomActionManager.shared.update(newAction)
                    } else {
                        CustomActionManager.shared.add(newAction)
                    }
                    customActions = CustomActionManager.shared.customActions
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

    private func builtInActionRow(action: LLMAction) -> some View {
        let effectiveShortcut = customShortcuts[action.id] ?? action.shortcut

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !disabledBuiltInActions.contains(action.id) },
                set: { enabled in
                    if enabled {
                        disabledBuiltInActions.remove(action.id)
                    } else {
                        disabledBuiltInActions.insert(action.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.7)
            .frame(width: 40)

            Image(systemName: action.icon)
                .foregroundColor(.accentColor)
                .frame(width: 18)

            Text(action.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            shortcutButton(actionId: action.id, currentShortcut: effectiveShortcut)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func shortcutButton(actionId: String, currentShortcut: String?) -> some View {
        Group {
            if editingShortcutFor == actionId {
                ShortcutRecorderView(
                    onCapture: { key in
                        if let key = key {
                            customShortcuts[actionId] = key
                        } else {
                            customShortcuts.removeValue(forKey: actionId)
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

    private func customActionRow(action: CustomAction) -> some View {
        let actionId = "custom_\(action.id.uuidString)"
        let effectiveShortcut = customShortcuts[actionId]

        return HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(.accentColor)
                .frame(width: 18)

            Text(action.name)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            shortcutButton(actionId: actionId, currentShortcut: effectiveShortcut)

            Button(action: {
                actionToEdit = action
                showingActionEditor = true
            }) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: { deleteCustomAction(action) }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func loadActionsState() {
        customActions = CustomActionManager.shared.customActions
        let config = LLMConfig.load()
        disabledBuiltInActions = Set(config.disabledBuiltInActions)
        customShortcuts = config.customShortcuts
    }

    private func deleteCustomAction(_ action: CustomAction) {
        CustomActionManager.shared.delete(action)
        customActions = CustomActionManager.shared.customActions
    }

    // MARK: - LLM Settings Tab

    private var llmSettingsTab: some View {
        VStack(spacing: 12) {
            // Provider selection
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider")
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

            // Provider-specific settings
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedProvider {
                    case .llamacpp:
                        llamacppSettings
                    case .ollama:
                        ollamaSettings
                    case .openai:
                        openaiSettings
                    case .claude:
                        claudeSettings
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 200)
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

                // Voice list
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredVoices, id: \.id) { voice in
                            HStack {
                                Image(systemName: ttsVoice == voice.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(ttsVoice == voice.id ? .accentColor : .secondary)
                                    .font(.system(size: 14))

                                Text(voice.name)
                                    .font(.system(size: 12))

                                Spacer()

                                Text("Grade: \(voice.grade)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(ttsVoice == voice.id ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                            .onTapGesture {
                                ttsVoice = voice.id
                            }
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

            Text("Server: http://localhost:8080")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
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

    private var ollamaSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                ProgressView("Loading models...")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                    if availableOllamaModels.isEmpty {
                        TextField("e.g., qwen2.5:7b", text: $ollamaModel)
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
                    ForEach(LLMConfig.openaiModels, id: \.self) { model in
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
                    ForEach(LLMConfig.claudeModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()

                if claudeModel == "Custom..." {
                    TextField("Enter model name", text: $customClaudeModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func loadCurrentConfig() {
        let config = LLMConfig.load()
        selectedProvider = config.provider
        selectedLlamaModel = config.llamaModel
        ollamaModel = config.ollamaModel
        openaiAPIKey = config.openaiAPIKey
        openaiModel = LLMConfig.openaiModels.contains(config.openaiModel) ? config.openaiModel : "Custom..."
        if openaiModel == "Custom..." {
            customOpenAIModel = config.openaiModel
        }
        claudeAPIKey = config.claudeAPIKey
        claudeModel = LLMConfig.claudeModels.contains(config.claudeModel) ? config.claudeModel : "Custom..."
        if claudeModel == "Custom..." {
            customClaudeModel = config.claudeModel
        }
        ttsVoice = config.ttsVoice
        ttsSpeed = config.ttsSpeed
        disabledBuiltInActions = Set(config.disabledBuiltInActions)
        customShortcuts = config.customShortcuts
        popupHotkey = config.popupHotkey
        customActions = CustomActionManager.shared.customActions
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
        config.ttsVoice = ttsVoice
        config.ttsSpeed = ttsSpeed
        config.disabledBuiltInActions = Array(disabledBuiltInActions)
        config.customShortcuts = customShortcuts
        config.popupHotkey = popupHotkey
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
    let action: CustomAction?
    let onSave: (CustomAction) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var selectedIcon: String = "star.fill"

    private let availableIcons = [
        "star.fill", "heart.fill", "bolt.fill", "globe", "flag.fill",
        "bookmark.fill", "tag.fill", "paperplane.fill", "doc.text.fill",
        "pencil", "highlighter", "text.bubble.fill", "quote.bubble.fill",
        "character.book.closed.fill", "text.magnifyingglass",
        "wand.and.stars", "sparkles", "lightbulb.fill", "brain.head.profile"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(action == nil ? "New Action" : "Edit Action")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
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

                    // Prompt field
                    VStack(alignment: .leading, spacing: 6) {
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
                        Text("The selected text will be provided to the LLM with these instructions.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
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
                    let newAction = CustomAction(
                        id: action?.id ?? UUID(),
                        name: name,
                        icon: selectedIcon,
                        prompt: prompt
                    )
                    onSave(newAction)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || prompt.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 340, height: 380)
        .onAppear {
            if let action = action {
                name = action.name
                prompt = action.prompt
                selectedIcon = action.icon
            }
        }
    }
}

class SettingsWindowController: NSWindowController {
    private var hostingView: NSHostingView<SettingsView>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
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

        // Check Python packages
        let checkScript = "python3 -c 'import kokoro; import soundfile; import numpy' 2>/dev/null && echo OK"
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
        let healthCheck = runShellCommand("curl -s http://localhost:8080/health 2>/dev/null")
        status.isLlamaServerRunning = healthCheck.contains("ok") || healthCheck.contains("OK")

        return status
    }

    func installDependencies(statusCallback: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var success = true

            // Check current status
            let status = self.checkDependencies()

            // Install espeak-ng if missing (and homebrew available)
            if !status.hasEspeak && status.hasHomebrew {
                DispatchQueue.main.async { statusCallback("Installing espeak-ng...") }
                let result = self.runShellCommand("/opt/homebrew/bin/brew install espeak-ng 2>&1 || /usr/local/bin/brew install espeak-ng 2>&1")
                if result.contains("Error") {
                    print("espeak-ng install warning: \(result)")
                }
            }

            // Install Python packages if missing
            if !status.hasPythonPackages {
                DispatchQueue.main.async { statusCallback("Installing TTS packages (this may take a minute)...") }
                let result = self.runShellCommand("python3 -m pip install --user --quiet kokoro soundfile numpy 2>&1")
                if result.contains("ERROR") {
                    print("pip install warning: \(result)")
                    success = false
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

    private func createLlamaLaunchAgent(model: LLMConfig.LlamaModel? = nil) {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        let selectedModel = model ?? getCurrentModel()
        let modelPath = NSString(string: "~/.popdraft/models/\(selectedModel.filename)").expandingTildeInPath
        let llamaServerPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server")
            ? "/opt/homebrew/bin/llama-server"
            : "/usr/local/bin/llama-server"

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
        <string>8080</string>
        <string>-ngl</string>
        <string>99</string>
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

    private func runShellCommand(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Error: \(error)"
        }

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

    private func startServer() {
        let expandedPath = NSString(string: serverScript).expandingTildeInPath

        // Check if script exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("TTS server script not found at: \(expandedPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [expandedPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            print("TTS server started (PID: \(process.processIdentifier))")
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
    @State private var selectedLlamaModel: String = "qwen2.5-3b"
    @State private var ollamaModels: [String] = []
    @State private var checkingPermission = false
    @State private var isSettingUp = false
    @State private var setupStatus = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
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
                            TextField("e.g., qwen2.5:7b", text: $selectedModel)
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
                    selectedModel = ollamaModels.first ?? "qwen2.5:7b"
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
                    }
                    .frame(height: 54)
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
                config.ollamaModel = selectedModel.isEmpty ? "qwen2.5:7b" : selectedModel
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

    // Default shortcuts mapping: actionId -> (shortcut key, trigger action)
    private let defaultShortcuts: [(actionId: String, defaultKey: String, triggerAction: String)] = [
        ("fix_grammar_and_spelling", "G", "grammar"),
        ("articulate", "A", "articulate"),
        ("craft_a_reply", "C", "answer"),
        ("custom_prompt...", "P", "custom"),
        ("read_aloud", "S", "speak"),
    ]

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

        // Register action shortcuts from config or defaults
        for (actionId, defaultKey, triggerAction) in defaultShortcuts {
            // Check if action is disabled
            if config.disabledBuiltInActions.contains(actionId) {
                continue
            }

            // Get custom shortcut or use default
            let shortcutKey = config.customShortcuts[actionId] ?? defaultKey
            guard let keyCode = keyCodeMap[shortcutKey.uppercased()] else { continue }

            hotkeys.append(HotkeyConfig(
                id: id,
                keyCode: keyCode,
                modifiers: UInt32(controlKey | optionKey),
                actionID: triggerAction,
                description: "Ctrl+Option+\(shortcutKey)"
            ))
            id += 1
        }

        // Register shortcuts for custom actions
        for customAction in CustomActionManager.shared.customActions {
            let actionId = "custom_\(customAction.id.uuidString)"
            if let shortcutKey = config.customShortcuts[actionId],
               let keyCode = keyCodeMap[shortcutKey.uppercased()] {
                hotkeys.append(HotkeyConfig(
                    id: id,
                    keyCode: keyCode,
                    modifiers: UInt32(controlKey | optionKey),
                    actionID: actionId,
                    description: "Ctrl+Option+\(shortcutKey)"
                ))
                id += 1
            }
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popupController: PopupWindowController?
    var settingsController: SettingsWindowController?
    var onboardingController: OnboardingWindowController?

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
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "PopDraft")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Popup", action: #selector(showPopup), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About PopDraft", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = menu

        // Create controllers
        popupController = PopupWindowController()
        settingsController = SettingsWindowController()

        // Start TTS server if needed
        TTSServerManager.shared.ensureRunning()

        // Register all global hotkeys
        HotkeyManager.shared.registerAll()

        Logger.shared.info("PopDraft \(AppVersion.current) started. Press Option+Space to show popup.")
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

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    func triggerAction(actionID: String) {
        switch actionID {
        case "popup":
            showPopup()
        case "grammar":
            popupController?.showWithAction(actionName: "Fix grammar and spelling")
        case "articulate":
            popupController?.showWithAction(actionName: "Articulate")
        case "answer":
            popupController?.showWithAction(actionName: "Craft a reply")
        case "custom":
            popupController?.showWithAction(actionName: "Custom prompt...")
        case "speak":
            popupController?.showWithAction(actionName: "Read aloud")
        default:
            // Check if it's a custom action (custom_UUID format) or a built-in action ID
            if actionID.hasPrefix("custom_") {
                // Find the custom action by ID
                let uuidString = String(actionID.dropFirst(7)) // Remove "custom_" prefix
                if let uuid = UUID(uuidString: uuidString),
                   let customAction = CustomActionManager.shared.customActions.first(where: { $0.id == uuid }) {
                    popupController?.showWithAction(actionName: customAction.name)
                } else {
                    showPopup()
                }
            } else {
                // Try to find built-in action by ID
                let actions = ActionManager.shared.actions
                if let action = actions.first(where: { $0.id == actionID }) {
                    popupController?.showWithAction(actionName: action.name)
                } else {
                    showPopup()
                }
            }
        }
    }

    @objc func showSettings() {
        settingsController?.showWindow()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PopDraft"
        alert.informativeText = "Version: \(AppVersion.current)\n\nSystem-wide AI text processing for macOS.\n\nUsage:\n1. Select text in any app\n2. Press Option+Space\n3. Select an action\n4. Review result and Copy\n\nProvider: \(LLMClient.shared.providerName)\nModel: \(LLMClient.shared.currentModel)\n\nBuilt by Ofer Bachner"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
