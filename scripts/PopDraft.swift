#!/usr/bin/env swift
// PopDraft - Popup Menu App
// A menu bar app that shows a floating action popup for text processing

import Cocoa
import SwiftUI
import Carbon.HIToolbox

// MARK: - Data Models

struct LLMAction: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let prompt: String
    let shortcut: String?
    let isTTS: Bool

    init(name: String, icon: String, prompt: String, shortcut: String?, isTTS: Bool = false) {
        self.name = name
        self.icon = icon
        self.prompt = prompt
        self.shortcut = shortcut
        self.isTTS = isTTS
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LLMAction, rhs: LLMAction) -> Bool {
        lhs.id == rhs.id
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

    var provider: Provider = .llamacpp
    var llamacppURL: String = "http://localhost:8080"
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen2.5:7b"
    var openaiAPIKey: String = ""
    var openaiModel: String = "gpt-4o"
    var claudeAPIKey: String = ""
    var claudeModel: String = "claude-sonnet-4-5-20250514"
    var ttsVoice: String = "af_heart"
    var ttsSpeed: Double = 1.0

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
        lines.append("OLLAMA_URL=\(ollamaURL)")
        lines.append("OLLAMA_MODEL=\(ollamaModel)")
        lines.append("OPENAI_API_KEY=\(openaiAPIKey)")
        lines.append("OPENAI_MODEL=\(openaiModel)")
        lines.append("CLAUDE_API_KEY=\(claudeAPIKey)")
        lines.append("CLAUDE_MODEL=\(claudeModel)")
        lines.append("TTS_VOICE=\(ttsVoice)")
        lines.append("TTS_SPEED=\(ttsSpeed)")

        let content = lines.joined(separator: "\n")
        try? content.write(to: configPath, atomically: true, encoding: .utf8)
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
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] PopDraft: \(message)\n"
        let logPath = "/tmp/popdraft.log"
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

    func generate(prompt: String, systemPrompt: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let provider = config.provider
        activeProvider = provider

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

    let actions: [LLMAction] = [
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
        ),
        LLMAction(
            name: "Custom prompt...",
            icon: "ellipsis.circle.fill",
            prompt: "",
            shortcut: "P"
        )
    ]

    func filteredActions(searchText: String) -> [LLMAction] {
        if searchText.isEmpty {
            return actions
        }
        return actions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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

        // Simulate Cmd+C to copy selected text
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+C
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)  // 0x08 = 'c'
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up: Cmd+C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update
        usleep(50000)  // 50ms

        // Check if clipboard changed (meaning text was selected and copied)
        if pasteboard.changeCount != savedChangeCount {
            clipboardText = pasteboard.string(forType: .string) ?? ""

            // Restore original clipboard
            pasteboard.clearContents()
            for (type, data) in savedContents {
                pasteboard.setData(data, forType: type)
            }
        } else {
            // No selection - clipboard unchanged, use existing clipboard content
            clipboardText = pasteboard.string(forType: .string) ?? ""
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

        // Adjust position to be near cursor but visible on screen
        frame.origin = NSPoint(
            x: mouseLocation.x - frame.width / 2,
            y: mouseLocation.y - frame.height - 10
        )

        // Make sure it's on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if frame.minX < screenFrame.minX {
                frame.origin.x = screenFrame.minX + 10
            }
            if frame.maxX > screenFrame.maxX {
                frame.origin.x = screenFrame.maxX - frame.width - 10
            }
            if frame.minY < screenFrame.minY {
                frame.origin.y = mouseLocation.y + 20
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

    func dismiss() {
        stopTTSStatusPolling()
        stopKeyboardMonitoring()
        window?.orderOut(nil)
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
                case .actionList:
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
            state = .customPrompt
            updateView()
            return
        }

        // Get selected text from clipboard
        guard !clipboardText.isEmpty else {
            state = .error("No text selected.\nSelect some text first.")
            updateView()
            return
        }

        // Handle TTS action
        if action.isTTS {
            state = .ttsPlaying(isPaused: false)
            updateView()

            TTSClient.shared.speak(text: clipboardText) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        // Playback started - start polling for completion
                        self?.startTTSStatusPolling()
                    case .failure(let error):
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
        LLMClient.shared.generate(prompt: fullPrompt) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    self?.resultText = response
                    self?.state = .result(response)
                case .failure(let error):
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
        case llm = "LLM"
        case tts = "Text-to-Speech"
    }

    @State private var selectedTab: SettingsTab = .llm
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

            // Tab content
            switch selectedTab {
            case .llm:
                llmSettingsTab
            case .tts:
                ttsSettingsTab
            }

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
        .frame(width: 420, height: 440)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("llama.cpp runs locally on your machine.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Server URL: http://localhost:8080")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            Text("No configuration needed - uses the model loaded in llama-server.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
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
        config.ollamaModel = ollamaModel
        config.openaiAPIKey = openaiAPIKey
        config.openaiModel = openaiModel == "Custom..." ? customOpenAIModel : openaiModel
        config.claudeAPIKey = claudeAPIKey
        config.claudeModel = claudeModel == "Custom..." ? customClaudeModel : claudeModel
        config.ttsVoice = ttsVoice
        config.ttsSpeed = ttsSpeed
        onSave(config)
    }
}

class SettingsWindowController: NSWindowController {
    private var hostingView: NSHostingView<SettingsView>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popupController: PopupWindowController?
    var settingsController: SettingsWindowController?
    var globalHotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create Edit menu for standard text editing commands
        setupEditMenu()

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

        // Register global hotkey (Option + Space)
        registerGlobalHotKey()

        print("PopDraft started. Press Option+Space to show popup.")
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
        unregisterGlobalHotKey()
    }

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    @objc func showSettings() {
        settingsController?.showWindow()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PopDraft"
        alert.informativeText = "System-wide AI text processing for macOS.\n\nUsage:\n1. Select text in any app\n2. Press Option+Space\n3. Select an action\n4. Review result and Copy\n\nProvider: \(LLMClient.shared.providerName)\nModel: \(LLMClient.shared.currentModel)\n\nBuilt by Ofer Bachner"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Global Hotkey

    func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x514C4D), id: 1)
        let modifiers: UInt32 = UInt32(optionKey)
        let keyCode: UInt32 = 49 // Space

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            globalHotKeyRef = hotKeyRef

            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

                if hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.showPopup()
                        }
                    }
                }
                return noErr
            }, 1, &eventType, nil, nil)

            print("Global hotkey registered: Option+Space")
        } else {
            print("Failed to register global hotkey: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKeyRef = globalHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
