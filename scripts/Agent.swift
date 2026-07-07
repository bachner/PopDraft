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

// MARK: - Agent trace log

/// Human-readable, step-by-step trace of the agent loop, written to
/// `~/.popdraft/agent-trace.log`. The pure `AgentLoop` emits one line per event
/// (the model's thinking, each tool call + arguments, each tool result, the final
/// answer) into this sink, so a wrong conclusion can be traced to the exact
/// search query and result that produced it. Thread-safe (called from the async
/// loop); the file self-rotates past ~4 MB so it can't grow unbounded.
enum AgentTrace {
    static let path = NSString(string: "~/.popdraft/agent-trace.log").expandingTildeInPath
    private static let lock = NSLock()
    private static let maxBytes = 4 * 1024 * 1024
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamped = "[\(stampFormatter.string(from: Date()))] \(line)\n"
        let url = URL(fileURLWithPath: path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > maxBytes {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data(stamped.utf8))
            try? fh.close()
        } else {
            let dir = NSString(string: "~/.popdraft").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? Data(stamped.utf8).write(to: url)
        }
    }
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
        cachedLlamaContext = nil   // re-detect against the (possibly new) URL
    }

    var providerName: String {
        return (activeProvider ?? config.provider).displayName
    }

    /// Cached detected llama-server context window (`/props` `n_ctx`), keyed by
    /// the URL it was read from, so we probe at most once per server/config.
    private var cachedLlamaContext: (url: String, nCtx: Int)?

    /// The ACTUAL served context window in tokens for the current provider, or nil
    /// when it can't be detected. For llama.cpp this reads `/props` `n_ctx` (the
    /// real served window — now ~200K with flash-attn + q4 KV — not a hardcoded
    /// guess). Cloud/Ollama return nil (handled by per-provider defaults in
    /// `ContextBudget.effectiveBudget`). Result cached per-URL. Bounded 1.5s probe.
    func detectedContextTokens() -> Int? {
        guard (activeProvider ?? config.provider) == .llamacpp else { return nil }
        let urlString = "\(config.llamacppURL)/props"
        if let cached = cachedLlamaContext, cached.url == urlString { return cached.nCtx }
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5

        let semaphore = DispatchSemaphore(value: 0)
        var detected: Int?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            // llama-server exposes n_ctx under default_generation_settings (and,
            // on some builds, at the top level). Accept either.
            if let gen = json["default_generation_settings"] as? [String: Any],
               let n = gen["n_ctx"] as? Int, n > 0 {
                detected = n
            } else if let n = json["n_ctx"] as? Int, n > 0 {
                detected = n
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2.0)

        if let n = detected { cachedLlamaContext = (urlString, n) }
        return detected
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
        generate(prompt: prompt, systemPrompt: systemPrompt, onProgress: onProgress,
                 allowContextRetry: true, completion: completion)
    }

    /// `allowContextRetry` is an internal flag: when a single-shot generation
    /// overflows the context window, we retry ONCE with a budget-trimmed prompt
    /// (this flag false on the retry, so we can't loop). The menu-bar text actions
    /// can hit this when a user selects a very large block. (Compaction)
    private func generate(prompt: String, systemPrompt: String?, onProgress: ((LLMStreamProgress) -> Void)?, allowContextRetry: Bool, completion: @escaping (Result<LLMResponse, Error>) -> Void) {
        let provider = config.provider
        activeProvider = provider

        Logger.shared.info("Sending to \(provider.displayName) [\(currentModel)]")

        // Generate with the configured provider, fallback to llama.cpp on failure
        generateWithProvider(provider, prompt: prompt, systemPrompt: systemPrompt, onProgress: onProgress) { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure(let error):
                // Reactive context-overflow recovery for the single-shot path: a
                // very large selection can blow the served window. Trim the prompt
                // to fit the budget and retry ONCE (never the raw "-1").
                if allowContextRetry, let self = self, isContextOverflowError(error) {
                    let budget = ContextBudget.effectiveBudget(
                        provider: provider.rawValue,
                        configured: self.config.agentSettings.contextTokens,
                        detected: self.detectedContextTokens())
                    // Reserve room for the system prompt + the model's reply.
                    let reserve = (systemPrompt?.count ?? 0) + 4096 * Int(ContextBudget.charsPerToken)
                    let promptCap = max(2000, Int(Double(budget) * 0.6 * ContextBudget.charsPerToken) - reserve)
                    if prompt.count > promptCap {
                        let trimmed = ContextBudget.trimToolResult(prompt, maxChars: promptCap)
                        self.logError("Context overflow on single-shot generate; retrying with prompt trimmed \(prompt.count)→\(trimmed.count) chars.")
                        self.generate(prompt: trimmed, systemPrompt: systemPrompt,
                                      onProgress: onProgress, allowContextRetry: false, completion: completion)
                        return
                    }
                }
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
        onTextDelta: (@Sendable (String) -> Void)? = nil,
        forceThinkingOff: Bool = false
    ) async throws -> AssistantTurn {
        let provider = config.provider
        activeProvider = provider
        switch provider {
        case .llamacpp:
            return try await chatCompletionOpenAICompatible(
                urlString: "\(config.llamacppURL)/v1/chat/completions",
                model: nil, apiKey: nil, messages: messages, tools: tools,
                isLlamaCpp: true, onTextDelta: onTextDelta, forceThinkingOff: forceThinkingOff)
        case .ollama:
            // Ollama's native /api/generate isn't tool-capable; use its
            // OpenAI-compatible endpoint for the agent path.
            return try await chatCompletionOpenAICompatible(
                urlString: "\(config.ollamaURL)/v1/chat/completions",
                model: config.ollamaModel, apiKey: nil, messages: messages, tools: tools,
                isLlamaCpp: false, onTextDelta: onTextDelta, forceThinkingOff: forceThinkingOff)
        case .openai:
            guard !config.openaiAPIKey.isEmpty else {
                throw NSError(domain: "OpenAI API key not configured", code: -1)
            }
            return try await chatCompletionOpenAICompatible(
                urlString: "https://api.openai.com/v1/chat/completions",
                model: config.openaiModel, apiKey: config.openaiAPIKey,
                messages: messages, tools: tools, isLlamaCpp: false, onTextDelta: onTextDelta,
                forceThinkingOff: forceThinkingOff)
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
                // VISION: a user turn carrying images emits a content-PART array.
                // Otherwise keep the EXACT bare-string fast-path (byte-identical
                // for every existing flow — zero regression).
                if let images = m.images, !images.isEmpty {
                    entry["content"] = VisionContent.openAIParts(text: m.content, images: images)
                } else {
                    entry["content"] = m.content
                }
            }
            out.append(entry)
        }
        return out
    }

    /// One round against any OpenAI-compatible `/v1/chat/completions` endpoint
    /// (llama.cpp, Ollama-OpenAI, OpenAI). Non-streamed (so `tool_calls` parse
    /// reliably); pushes the final text to `onTextDelta` once.
    /// One-shot VISION completion against the DEDICATED vision llama-server on
    /// :10820 (`VisionServerManager`) — NOT the global provider/config. `see_image`
    /// routes here so it can SEE regardless of what the main model is.
    ///
    /// The VL model is a THINKING model, so thinking MUST be disabled or it returns
    /// an empty answer (`chat_template_kwargs.enable_thinking:false` +
    /// `enable_thinking:false`). Retries through the connection-refused / 503 window
    /// (via `LlamaLoadRetry`) while the vision server loads its weights.
    func visionCompletion(text: String, images: [ImageRef]) async throws -> String {
        let urlString = "\(VisionServerManager.endpoint)/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        // llama.cpp ignores `model`; the single user message carries the image
        // parts (VisionContent.openAIParts builds the OpenAI content array).
        let body: [String: Any] = [
            "model": "vision",
            "messages": [[
                "role": "user",
                "content": VisionContent.openAIParts(text: text, images: images),
            ]],
            "stream": false,
            "max_tokens": 500,
            "temperature": 0,
            "chat_template_kwargs": ["enable_thinking": false],
            "enable_thinking": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retry through the vision server's "still loading" window (just booted /
        // weights loading): connection-refused or a 503.
        let attemptStart = Date()
        var data: Data!
        var response: URLResponse!
        while true {
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if (error as? URLError)?.code == .cannotConnectToHost {
                    if LlamaLoadRetry.shouldRetry(elapsed: Date().timeIntervalSince(attemptStart)) {
                        try await Task.sleep(nanoseconds: UInt64(LlamaLoadRetry.pollIntervalSeconds * 1_000_000_000))
                        continue
                    }
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
                }
                throw error
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 503 {
                if LlamaLoadRetry.shouldRetry(elapsed: Date().timeIntervalSince(attemptStart)) {
                    try await Task.sleep(nanoseconds: UInt64(LlamaLoadRetry.pollIntervalSeconds * 1_000_000_000))
                    continue
                }
                throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
            }
            break
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
        var content = (message["content"] as? String) ?? ""
        // Strip any stray <think>…</think> the VL model might still emit.
        if let range = content.range(of: "</think>") {
            content = String(content[range.upperBound...])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatCompletionOpenAICompatible(
        urlString: String, model: String?, apiKey: String?,
        messages: [ChatMessage], tools: [[String: Any]]?, isLlamaCpp: Bool,
        onTextDelta: (@Sendable (String) -> Void)? = nil,
        forceThinkingOff: Bool = false
    ) async throws -> AssistantTurn {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        // Per-request timeout. Default 180s, but very large local models (e.g. a
        // 235B streaming experts from SSD) can spend minutes just on prefill of a
        // long agentic context, so allow an override via POPDRAFT_HTTP_TIMEOUT_SEC.
        if let t = ProcessInfo.processInfo.environment["POPDRAFT_HTTP_TIMEOUT_SEC"], let secs = Double(t), secs > 0 {
            request.timeoutInterval = secs
        } else {
            request.timeoutInterval = 180
        }

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
        // Force-disable model reasoning for THIS turn (used by the agent's final
        // answer-synthesis turn so a thinking model reliably emits plain prose and
        // doesn't bury the whole answer inside a <think> block). Qwen/llama.cpp
        // honor `chat_template_kwargs.enable_thinking`; OpenAI's reasoning models
        // read `reasoning_effort`. Harmless extra keys on servers that ignore them.
        if forceThinkingOff {
            body["chat_template_kwargs"] = ["enable_thinking": false]
            body["enable_thinking"] = false
            if apiKey != nil && !isLlamaCpp { body["reasoning_effort"] = "low" }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retry through the llama.cpp "not ready yet" window (just switched
        // models / just booted): connection-refused or a 503 while weights load.
        // Only applies to llamacpp — other providers surface their error as-is.
        let attemptStart = Date()
        var didRestartServer = false
        var data: Data!
        var response: URLResponse!
        while true {
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if isLlamaCpp, (error as? URLError)?.code == .cannotConnectToHost {
                    // The socket is REFUSED — the server process is down, not merely
                    // loading (which returns 503). Retrying the request alone never
                    // recovers that; kick a one-time restart (bootout+bootstrap) and
                    // keep polling through the restart + weight-load window. This is
                    // the "asked a question right after a model change and got
                    // 'server isn't responding'" case.
                    if !didRestartServer {
                        didRestartServer = true
                        await MainActor.run { LlamaServerManager.shared.restart { _ in } }
                    }
                    if LlamaLoadRetry.shouldRetry(elapsed: Date().timeIntervalSince(attemptStart)) {
                        try await Task.sleep(nanoseconds: UInt64(LlamaLoadRetry.pollIntervalSeconds * 1_000_000_000))
                        continue
                    }
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
                }
                throw error
            }
            if isLlamaCpp, let http = response as? HTTPURLResponse, http.statusCode == 503 {
                if LlamaLoadRetry.shouldRetry(elapsed: Date().timeIntervalSince(attemptStart)) {
                    try await Task.sleep(nanoseconds: UInt64(LlamaLoadRetry.pollIntervalSeconds * 1_000_000_000))
                    continue
                }
                throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: LLMClient.llamaServerDownError])
            }
            break
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
                // VISION: a user turn carrying images emits a content-PART array
                // (text block + image blocks). With no images, keep the EXACT
                // bare-string fast-path — byte-identical to before.
                if let images = m.images, !images.isEmpty {
                    anthropicMessages.append([
                        "role": "user",
                        "content": VisionContent.anthropicParts(text: m.content, images: images),
                    ])
                } else {
                    anthropicMessages.append(["role": "user", "content": m.content])
                }
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

/// `suggest_integration` — given a capability the agent lacks a tool for
/// (e.g. "email", "calendar", "slack", "read a file"), return a concrete,
/// actionable suggestion: which MCP server connects it and how to add it in
/// Settings → MCP. This is how the agent stays capability-aware instead of
/// flatly refusing. Pure lookup over `IntegrationCatalog`; no network, no gate.
struct SuggestIntegrationTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "suggest_integration",
            description: "When the user asks for a capability you have NO tool for "
                + "(email, calendar, Slack, Notion, local files, GitHub, …), call this "
                + "with the capability to get the name of an MCP server that provides it "
                + "and how to add it. Use this instead of refusing; then relay the "
                + "suggestion to the user.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "capability": [
                        "type": "string",
                        "description": "An EXTERNAL service the user wants that needs its own account/auth, e.g. 'read my email', 'check my calendar', 'send a slack message'. Do NOT use for local file/command/code tasks — those use run_shell.",
                    ],
                ],
                "required": ["capability"],
            ])
    }

    func invoke(_ args: JSONObject) async throws -> String {
        let capability = (args.dictionary["capability"] as? String) ?? ""
        guard !capability.isEmpty else { return "Error: 'capability' is required." }
        if let match = IntegrationCatalog.match(capability) {
            return match.suggestionText()
        }
        // Unknown capability: still don't refuse — point at the generic path.
        let known = IntegrationCatalog.all.map { $0.displayName }.joined(separator: ", ")
        return "I don't have a built-in connector for \"\(capability)\" yet, but you can "
            + "connect almost any service by adding an MCP server in Settings → MCP. "
            + "Built-in presets cover: \(known). For other services, search for an "
            + "\"<service> MCP server\" and add its command there."
    }
}

/// Self-registration of the always-on text tools. These need no gate (no
/// network, no privileged action) so they are always available.
enum TextTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { _ in true },
            make: { _, _ in [SummarizeTextTool(), ExtractTextTool(), SuggestIntegrationTool()] }))
    }
}

/// The single bootstrap that plugs every feature file's built-in tools into the
/// catalog. Adding a NEW feature file = add a `register()` to it and one line
/// here; adding a tool to an EXISTING feature = edit only that file's group.
/// `AgentToolCatalog.installBuiltins` is wired to this at app startup, and the
/// catalog runs it exactly once (lazily, on first registry/reserved-name use).
enum BuiltinTools {
    static func installAll() {
        TextTools.register()       // summarize_text / extract_text / suggest_integration
        WebTools.register()        // web_* + browser_*  (gated on enableWebSearch)
        MacControlTools.register() // run_shell / run_applescript (gated on enableMacControl)
        LocalActionTools.register() // current_datetime / calculator / clipboard_* / current_context / open_app_or_url
        VisionTools.register()     // see_image (local path / image URL / screenshot:<url>) — vision
        FileTools.register()       // read_document (confirm-gated local document/PDF reader)
    }

    /// Arm the catalog's install hook. Safe to call multiple times; the catalog
    /// itself guards against double-install.
    static func arm() {
        AgentToolCatalog.installBuiltins = { BuiltinTools.installAll() }
    }
}

// MARK: - PopDraftAgent (registry + loop wiring)

/// Builds the tool registry from config and runs the `AgentLoop` over the real
/// model via `LLMClient.chatCompletion`. Minimal entry point for the "Ask Agent"
/// action — returns the final answer plus the updated session.
struct PopDraftAgent {
    /// Default system prompt seeding the agent.
    /// The agent's system prompt. COMPUTED (not a constant) so every new session
    /// is stamped with the CURRENT date/time and an anti-stale-knowledge directive:
    /// a local/older model otherwise answers "what exists / recent prices / events"
    /// from its training cutoff and confidently contradicts reality (and even live
    /// search results). The date is ground truth; tool results beat memory.
    static var systemPrompt: String {
        return currentContextPreamble() + "\n\n" + systemPromptBase
    }

    /// A fresh preamble with today's date/time (local) + the rule that the model's
    /// built-in knowledge is dated and must yield to the date above and to tool
    /// results. Regenerated on each access so it's always current.
    static func currentContextPreamble() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let stamp = df.string(from: Date())
        let tz = TimeZone.current.identifier
        return """
        CURRENT DATE & TIME: \(stamp) (\(tz), the user's local time). Treat this as \
        ground truth for anything time-sensitive. You ALREADY KNOW the current \
        date/time from this line — do NOT call the current_datetime tool just to \
        find out what day/time it is; only use it if you need a precise machine \
        timestamp for a computation.

        YOUR TRAINING KNOWLEDGE IS DATED. Your built-in knowledge has a cutoff in the \
        PAST, so what you "remember" about recent products, models, prices, releases, \
        people's current roles, and world events may be OUT OF DATE or wrong. Rules:
        - NEVER tell the user that a product, model, feature, event, or release \
        "doesn't exist yet", "isn't out", "hasn't happened", or "isn't available" \
        based on your own memory. If you're unsure whether something current exists, \
        web_search FIRST, then answer from what you find.
        - When a web/tool result CONFLICTS with what you remember, TRUST THE TOOL \
        RESULT — it reflects today; your memory does not. Do not "correct" fresh \
        search results with stale assumptions or warn the user that real, current \
        facts are mistaken.
        - For prices, availability, "the latest X", recent news, or anything that \
        changes over time, verify with the web tools rather than recalling.
        """
    }

    static let systemPromptBase = """
    You are PopDraft, a helpful desktop assistant. You can call tools to search \
    and read the web, to DRIVE a live browser (navigate, click, type, read), and \
    to transform text. You also have local OS tools: get the current date/time \
    (current_datetime), do exact math (calculator), read/write the clipboard \
    (clipboard_read / clipboard_write), see the frontmost app + the user's text \
    selection (current_context), and open an app or URL (open_app_or_url) — the \
    clipboard write and open actions ask the user to confirm before they run. \
    You can also READ a local document the user names (text, code, markdown, json, \
    csv, PDF, or RTF) via read_document (confirm-gated), then summarize or answer \
    questions about it. \
    You can also connect to external services (email, calendar, \
    Slack, Notion, files, GitHub, …) through MCP servers the user has configured — \
    each connected server's tools appear to you namespaced as `<server>__<tool>`. \
    Think step by step. Prefer to verify facts with the web tools when a question \
    needs current or external information; otherwise answer directly.

    YOUR MESSAGES RENDER RICH CONTENT — they are NOT plain text. The chat renders \
    full Markdown (tables, fenced code with highlighting), **images** \
    (`![alt](https-or-data-URL)`), **Mermaid** diagrams (```mermaid blocks), and \
    **arbitrary HTML / CSS / SVG / JavaScript** (a ```html block — or inline HTML — \
    renders with its styles and scripts). So when the user asks you to DRAW, \
    VISUALIZE, SHOW, sketch, chart, or render ANYTHING — a picture, an animal, a \
    chart, a diagram, a shape, a UI mockup — actually PRODUCE it as inline `<svg>` \
    or an HTML/CSS/Canvas drawing (or a Mermaid diagram for flows/graphs). NEVER \
    say you "can't draw" or that you are "text-only" — you can, and the user will \
    see it rendered. Put the SVG/HTML markup DIRECTLY in your reply text — it \
    renders inline — do NOT save it to a file, and do NOT call a tool (write_file, \
    run_shell, etc.) to deliver a drawing; just include the `<svg>`/HTML in your \
    message. Prefer crisp inline `<svg>` for pictures and shapes — a drawing may be \
    raw inline `<svg>…</svg>` OR a ```svg / ```html fenced block; all three render.

    PARALLEL TOOL CALLS — when you need several INDEPENDENT lookups or actions \
    (e.g. three different web_search queries, or web_read of several URLs, or a few \
    unrelated commands), emit them as MULTIPLE tool calls in the SAME turn — they \
    execute CONCURRENTLY. Batch independent work this way; only chain calls one \
    after another when a call genuinely depends on a previous call's result.

    WHEN TO USE TOOLS — read this first. Prefer the FEWEST tools necessary, and \
    NEVER call a tool when you can answer directly.
    - PURE TEXT TASKS — translate, rewrite, improve, articulate, fix grammar, \
    summarize, rephrase, explain, format, or extract from text the user already \
    gave you — need ZERO tools. Just produce the transformed text directly. Do NOT \
    call web_search / web_* / browser_* — and do NOT call current_datetime, \
    calculator, current_context, or any other tool. "Improve this text… only \
    output the improved text" means: reply with ONLY the improved text, no tool \
    calls at all.
    - GENERAL KNOWLEDGE you already know — answer DIRECTLY, no tools.
    - Use web_search / browse tools ONLY when the user explicitly asks you to \
    search or look something up online, OR the question genuinely needs current, \
    external, or factual information you don't already have (news, prices, a \
    specific person/org, recent events, a specific page).
    - When the instruction is "translate / rewrite / summarize this text" and the \
    text is included, output ONLY the transformed text — no tools, no preamble, \
    no trailing commentary. If the user says "add nothing before or after", return \
    exactly the transformed text and nothing else.
    Examples:
    - "Translate to Hebrew, add nothing: 'BQ incident costs:'" → answer with only \
    the Hebrew translation, ZERO tool calls.
    - "Fix the grammar: 'he go to store'" → answer "He goes to the store.", no tools.
    - "What's the latest iPhone price?" → web_search is appropriate (current/external).

    How to use tools well:
    - When you call a tool, wait for its result before continuing.
    - For a quick lookup, use web_search + web_read. To interact with a page \
    (run a search box, click into results, work through a multi-step flow), use \
    the browser_* tools: browser_open a site, browser_type into a field (with \
    submit:true to search), browser_click a link/button by its visible text or a \
    CSS selector, browser_read the page, browser_back to go back. The browser \
    session persists across these calls, and each result lists the clickable \
    elements you can act on next.
    - DYNAMIC / JS-RENDERED PAGES: many sites (feeds, video grids, infinite scroll) \
    load their real content with JavaScript AFTER the page loads, so browser_read \
    or a screenshot right away shows only the header/nav with an empty content \
    area. When that happens, call browser_scroll (to:"bottom", and raise `steps` \
    to page through progressive loaders) to trigger the content, THEN browser_read \
    / browser_screenshot. To grab the fully-rendered DOM or a computed value \
    directly, use browser_evaluate (e.g. script:"document.documentElement.innerHTML" \
    or a querySelector). Prefer browser_screenshot with full_page:true to capture a \
    tall page in one shot.
    - After EACH tool result, reassess: decide whether you have enough to answer, \
    or whether one more tool call is genuinely needed. Don't repeat the same \
    search over and over — if a search returns results, READ them and answer.
    - If a search or page returned relevant facts, base your answer on them; do \
    not stop at the raw tool output.
    - If the user has a connected MCP tool that fits the request (a \
    `<server>__<tool>` tool), USE it — that is the whole point of connecting it.
    - PHOTOS / PICTURES / IMAGES — when the user asks to find / show / see a \
    photo, picture, image, or what someone or something LOOKS LIKE, call \
    `image_search` (NOT web_search). Your reply MUST then EMBED the actual images \
    as inline Markdown: output one `![title](embedURL)` per line using each \
    result's `embedURL` field — ALWAYS use `embedURL`, NOT `imageURL` (the full-size \
    `imageURL` is often hotlink-protected and renders as a broken icon; `embedURL` \
    is the one that reliably displays). These `![](...)` lines are the ONLY thing \
    that makes images appear, so they are REQUIRED. Output ~4–6 image lines (optionally \
    ONE short intro sentence) and NOTHING ELSE. Do NOT instead write a numbered \
    list of titles / captions / "source:" lines describing the photos — a text \
    description shows the user no image and is wrong here.
    - DOWNLOADING / SAVING A FILE — when the user asks to download or save a file \
    or image to their Mac, call `download_file` with the https URL (it saves to \
    ~/Downloads by default; the user approves first). Report the saved path.

    TAKING ACTION ON THIS MAC. When Mac control is enabled you have `run_shell` \
    and `run_applescript`. Use them to ACTUALLY DO local work: run any shell \
    command, write code to a file and execute it (python/node/bash/swift…), read \
    and write files, inspect the system, open apps or URLs. NEVER claim you can't \
    read a file, run code, or run a command — propose it via run_shell (the user \
    approves before anything runs; read-only commands like cat/ls may auto-run). \
    Do local file/command/code work with run_shell, NOT by suggesting an MCP.

    GAINING A NEW CAPABILITY — IMPORTANT. You can SET UP new tools for yourself \
    via MCP servers. When the user wants something you have NO connected tool for \
    (weather, maps, a database, Linear, Drive, email, calendar, Slack, …) — and it \
    is NOT local file/command/code work (that ALWAYS uses run_shell, never an MCP) \
    — DO NOT refuse. Instead, set it up yourself, end to end:
    1. Call `suggest_integration` with the capability. If it returns a known \
    server (it checks a built-in catalog of presets), use that server's exact \
    command + args.
    2. If it's NOT in the catalog, use `web_search` to find the right package — \
    search e.g. "<capability> MCP server npm" or "<capability> MCP server github" \
    — and determine the `npx -y <package>` (or `uvx <package>`) command + args.
    3. Call `add_mcp_server` with {name, command, args, description} to install + \
    enable it. The USER must Approve before it installs/runs — you are PROPOSING. \
    On approval its tools become available to you immediately, named \
    `<server>__<tool>`.
    4. Then ACTUALLY USE those new tools (look at the next tool list) to fulfill \
    the original request, and answer.
    Example: "set up a weather MCP and tell me the weather in Tel Aviv" → \
    suggest_integration("weather") → add_mcp_server(name:"Weather", command:"npx", \
    args:["-y","<weather-pkg>"]) → user approves → call the new \
    `Weather__<tool>` → answer with the forecast.
    If `add_mcp_server` reports the server was added but not reachable (it may need \
    a one-time auth/OAuth or setup step), tell the user that plainly and point them \
    at Settings → MCP (Test) — don't pretend it worked.

    SEEING IMAGES & WEBSITES. You have `see_image` — call it whenever the user asks \
    what a website LOOKS like, whether a page's layout is broken or correct, or to \
    visually inspect / describe a page or an image. To capture AND see a live site, \
    pass `source:"screenshot:<url>"` to see_image in a SINGLE call (it screenshots \
    the page itself, then looks at it) — do NOT call web_screenshot first. To look \
    at an image, pass a local file path or an `https:` image URL. Use see_image \
    instead of guessing from HTML/text when the question is about VISUAL appearance.

    ALWAYS finish your turn with a clear, direct, natural-language answer to the \
    user's question, synthesized from what you found. Never end with only a tool \
    result and no answer. Keep final answers concise and well-formatted.
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
    ///   skipped. Live clients are tracked in the returned `MCPClientHolder` so the
    ///   caller can shut them ALL down — INCLUDING any started mid-turn by
    ///   `add_mcp_server` (the holder is a reference, so a later append is visible).
    @MainActor
    static func buildRegistry(
        config: AppConfig,
        confirmer: (any MacControlConfirmer)? = nil,
        configDir: String = LLMConfig.configDir
    ) async -> (registry: ToolRegistry, mcpClients: MCPClientHolder) {
        let registry = ToolRegistry()
        let holder = MCPClientHolder()
        // Built-in tools are SELF-REGISTERED by their owning feature files into
        // `AgentToolCatalog` (text — always on; web/browser — behind
        // `enableWebSearch`; confirm-gated Mac-control — behind `enableMacControl`).
        // The catalog applies each group's gate for `config` and builds the
        // concrete tools, so this wiring no longer carries a hand-maintained tool
        // list — adding a built-in tool is a change to one feature file.
        let builtins = AgentToolCatalog.enabledTools(config: config, confirmer: confirmer)
        await registry.register(builtins)
        // PR9: MCP tools — only for configured+enabled servers (default none).
        let mcp = await MCPManager.buildTools(servers: config.mcpServers)
        holder.append(contentsOf: mcp.clients)
        if !mcp.tools.isEmpty { await registry.register(mcp.tools) }
        // PR12: the agent can SET UP a new MCP server itself. The installer starts
        // a server live, registers its tools into THIS running registry, and tracks
        // its client in the same `holder` the turn teardown drains. Confirm-gated
        // through the run_shell `confirmer` seam (denylist enforced in the tool).
        let installer = MCPServerInstaller(
            registry: registry, configDir: configDir,
            trackClient: { holder.append($0) })
        await registry.register(AddMcpServerTool(
            confirmer: confirmer, installer: installer, settings: config.agentSettings))
        return (registry, holder)
    }

    /// Run the agent loop on `session`. Returns the loop outcome (updated session
    /// + final answer). The model `call` is `LLMClient.chatCompletion`; tools run
    /// in parallel via `ToolRunner` with the renderer cap as the concurrency cap.
    ///
    /// `confirmer` is the Mac-control confirmation seam (the chat view-model). With
    /// no confirmer, confirm-gated commands structurally resolve to deny.
    @MainActor
    static func run(
        session: ChatSession,
        config: AppConfig,
        confirmer: (any MacControlConfirmer)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil,
        onProgress: ToolProgressHook? = nil,
        disableTools: Bool = false,
        forceThinkingOff: Bool = false
    ) async throws -> AgentLoop.Outcome {
        // Pure text-transformation actions (Improve / Fix grammar / Translate / …)
        // must NOT call tools — offering them just invites a small model to reach
        // for summarize_text / current_datetime / etc. on a plain rewrite. An empty
        // registry means the model literally CANNOT call a tool; it just produces
        // the transformed text. Follow-up chat turns run with the full registry.
        let (registry, mcpClients): (ToolRegistry, MCPClientHolder) = disableTools
            ? (ToolRegistry(), MCPClientHolder())
            : await buildRegistry(config: config, confirmer: confirmer)
        // Shut MCP servers down when the turn ends, however it ends — INCLUDING any
        // started mid-turn by `add_mcp_server` (the holder is appended to live).
        defer { mcpClients.shutdownAll() }
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
        var loop = AgentLoop(maxIterations: config.agentSettings.maxIterations, runner: runner)
        // Full step-by-step trace → ~/.popdraft/agent-trace.log (thinking, every
        // tool call + args, every result, final answer). Lets a wrong conclusion be
        // traced to the exact search/result that drove it.
        loop.trace = { AgentTrace.write($0) }

        let modelCall: AgentLoop.ModelCall = { messages, toolsBoxed in
            let tools = unboxTools(toolsBoxed)
            return try await LLMClient.shared.chatCompletion(
                messages: messages, tools: tools.isEmpty ? nil : tools,
                stream: false, onTextDelta: onTextDelta, forceThinkingOff: forceThinkingOff)
        }
        // Final answer-synthesis call (BUG 3 fix): tools DISABLED and thinking
        // FORCED OFF, so when the tool loop ends without a plain answer we always
        // get one synthesized from the gathered tool results — never blank, and
        // never just the raw tool output. (toolsBoxed is empty here by contract.)
        let finalizeCall: AgentLoop.ModelCall = { messages, _ in
            return try await LLMClient.shared.chatCompletion(
                messages: messages, tools: nil,
                stream: false, onTextDelta: onTextDelta, forceThinkingOff: true)
        }
        // Automatic session compaction: keep a long conversation under the served
        // context window so it never dies with the "Context size has been
        // exceeded" / "-1" error. The budget is the provider's effective window —
        // the ACTUAL served context (llama-server `/props` `n_ctx`, now ~200K) when
        // it can be detected, else a sensible per-provider default; a non-zero
        // `contextTokens` config pins it manually. With a 200K window compaction
        // is rare, but it's the safety net for huge pastes / long tool outputs and
        // for cloud models with smaller windows. The summarizer is a single cheap,
        // tools-OFF, thinking-OFF model call that recaps the dropped older messages.
        let detected = LLMClient.shared.detectedContextTokens()
        let budget = ContextBudget.effectiveBudget(
            provider: config.provider,
            configured: config.agentSettings.contextTokens,
            detected: detected)
        let summarize: ContextBudget.Summarizer = { dropped in
            await PopDraftAgent.summarizeOlder(dropped)
        }
        let compaction = AgentLoop.Compaction(budget: budget, maxRetries: 2, summarize: summarize)
        return try await loop.run(
            session: session, registry: registry, call: modelCall,
            onProgress: onProgress, finalize: finalizeCall, compaction: compaction)
    }

    /// Summarize the older messages that compaction is about to fold away, with a
    /// single cheap model call (tools OFF, thinking OFF). Returns a concise recap
    /// for the "Conversation so far:" message, or nil on any failure (the caller
    /// then falls back to a deterministic structural recap — never an error).
    ///
    /// The summary request itself is intentionally bounded: we feed the model a
    /// pre-trimmed transcript of the dropped region (tool results hard-capped) so
    /// the summarization call can't itself overflow.
    static func summarizeOlder(_ dropped: [ChatMessage]) async -> String? {
        guard !dropped.isEmpty else { return nil }
        // Build a compact, role-tagged transcript with tool results pre-trimmed.
        var transcript = ""
        for m in dropped {
            let body: String
            if m.role == "tool" {
                body = ContextBudget.trimToolResult(m.content, maxChars: 800)
            } else if let calls = m.toolCalls, !calls.isEmpty, m.content.isEmpty {
                body = "[called tools: " + calls.map { $0.name }.joined(separator: ", ") + "]"
            } else {
                body = m.content
            }
            if body.isEmpty { continue }
            transcript += "\(m.role.uppercased()): \(body)\n\n"
        }
        if transcript.isEmpty { return nil }
        // Hard cap the transcript fed to the summarizer so the call itself is safe.
        transcript = ContextBudget.trimToolResult(transcript, maxChars: 8000)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content:
                "You compress conversation history. Produce a tight, factual recap "
                + "(8 bullet points max) of the exchange below: the user's goals/"
                + "questions, key facts found, decisions, and any open threads. No "
                + "preamble, no tool call syntax — just the recap."),
            ChatMessage(role: "user", content: "Recap this earlier conversation:\n\n\(transcript)"),
        ]
        do {
            let turn = try await LLMClient.shared.chatCompletion(
                messages: messages, tools: nil, stream: false,
                onTextDelta: nil, forceThinkingOff: true)
            let text = (turn.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil  // structural recap fallback handles it
        }
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
