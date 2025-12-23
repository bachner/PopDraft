import Cocoa
import Foundation

// MARK: - LLM Configuration

struct LLMConfig {
    enum Backend: String {
        case ollama
        case llamacpp
    }

    var backend: Backend = .ollama
    var ollamaURL: String = "http://localhost:11434"
    var llamacppURL: String = "http://localhost:8080"
    var ollamaModel: String = "qwen2.5:7b"

    static func load() -> LLMConfig {
        var config = LLMConfig()
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".quickllm/config")

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
            case "BACKEND":
                config.backend = Backend(rawValue: value) ?? .ollama
            case "OLLAMA_URL":
                config.ollamaURL = value
            case "LLAMACPP_URL":
                config.llamacppURL = value
            case "OLLAMA_MODEL":
                config.ollamaModel = value
            default:
                break
            }
        }

        return config
    }
}

// MARK: - LLM API Client

class LLMClient {
    private var config: LLMConfig
    private var activeBackend: LLMConfig.Backend?
    var messages: [[String: String]] = []
    var contextText: String = ""

    init() {
        config = LLMConfig.load()
    }

    var backendName: String {
        let backend = activeBackend ?? config.backend
        return backend == .llamacpp ? "llama.cpp" : "Ollama"
    }

    // Check if a backend is available
    private func isBackendAvailable(_ backend: LLMConfig.Backend) -> Bool {
        let urlString = backend == .llamacpp
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

    // Select backend with fallback
    private func selectBackend() -> LLMConfig.Backend? {
        if isBackendAvailable(config.backend) {
            activeBackend = config.backend
            return config.backend
        }
        let fallback: LLMConfig.Backend = config.backend == .llamacpp ? .ollama : .llamacpp
        if isBackendAvailable(fallback) {
            activeBackend = fallback
            return fallback
        }
        return nil
    }

    func setContext(_ context: String) {
        contextText = context
        messages.append([
            "role": "system",
            "content": "You are a helpful assistant. The user has selected the following text and will give you instructions to apply to it. Follow their instructions precisely. Here is the selected text:\n\n---\n\(context)\n---"
        ])
    }

    func sendMessage(_ text: String, completion: @escaping (String) -> Void) {
        messages.append(["role": "user", "content": text])

        guard let backend = selectBackend() else {
            completion("Error: No LLM backend available. Start llama-server or Ollama.")
            return
        }

        switch backend {
        case .llamacpp:
            sendLlamaCpp(completion: completion)
        case .ollama:
            sendOllama(completion: completion)
        }
    }

    private func sendLlamaCpp(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "\(config.llamacppURL)/v1/chat/completions") else {
            completion("Error: Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "messages": messages,
            "stream": false,
            "max_tokens": 4096
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            var response = "Error: No response"

            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                response = content
                self?.messages.append(["role": "assistant", "content": content])
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let errorObj = json["error"] as? [String: Any],
                      let message = errorObj["message"] as? String {
                response = "Error: \(message)"
            } else if let error = error {
                response = "Error: \(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                completion(response)
            }
        }.resume()
    }

    private func sendOllama(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "\(config.ollamaURL)/api/chat") else {
            completion("Error: Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": config.ollamaModel,
            "messages": messages,
            "stream": false
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            var response = "Error: No response"

            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                response = content
                self?.messages.append(["role": "assistant", "content": content])
            } else if let error = error {
                response = "Error: \(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                completion(response)
            }
        }.resume()
    }
}

// MARK: - Chat Window Controller

class ChatWindowController: NSWindowController, NSTextFieldDelegate {
    var contextView: NSTextView!
    var chatView: NSTextView!
    var inputField: NSTextField!
    var sendButton: NSButton!
    var llmClient = LLMClient()
    var context: String = ""
    var escapeMonitor: Any?
    var idleTimer: Timer?

    convenience init(context: String) {
        self.init(window: nil)
        self.context = context
        setupUI()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
        setupEscapeHandler()
        resetIdleTimer()
    }

    private func setupUI() {
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupEscapeHandler() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC key
                self?.window?.close()
                NSApp.terminate(nil)
                return nil
            }
            self?.resetIdleTimer()
            return event
        }
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            self?.window?.close()
            NSApp.terminate(nil)
        }
    }

    deinit {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        idleTimer?.invalidate()
    }

    func setupWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Chat (\(llmClient.backendName))"
        window.minSize = NSSize(width: 500, height: 400)
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Context label
        let contextLabel = NSTextField(labelWithString: "Selected Text:")
        contextLabel.frame = NSRect(x: 15, y: 545, width: 150, height: 20)
        contextLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contextLabel.textColor = NSColor.systemOrange
        contextLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(contextLabel)

        // Context scroll view (fixed height at top)
        let contextScrollView = NSScrollView(frame: NSRect(x: 15, y: 420, width: 670, height: 120))
        contextScrollView.autoresizingMask = [.width, .minYMargin]
        contextScrollView.hasVerticalScroller = true
        contextScrollView.borderType = .bezelBorder

        contextView = NSTextView(frame: contextScrollView.bounds)
        contextView.autoresizingMask = [.width]
        contextView.isEditable = false
        contextView.isSelectable = true
        contextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        contextView.textContainerInset = NSSize(width: 8, height: 8)
        contextView.backgroundColor = NSColor.controlBackgroundColor
        contextView.textColor = NSColor.labelColor

        contextScrollView.documentView = contextView
        contentView.addSubview(contextScrollView)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 15, y: 410, width: 670, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(separator)

        // Chat label
        let chatLabel = NSTextField(labelWithString: "Conversation:")
        chatLabel.frame = NSRect(x: 15, y: 385, width: 150, height: 20)
        chatLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        chatLabel.textColor = NSColor.systemGreen
        chatLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(chatLabel)

        // Chat scroll view (flexible height)
        let chatScrollView = NSScrollView(frame: NSRect(x: 15, y: 60, width: 670, height: 320))
        chatScrollView.autoresizingMask = [.width, .height]
        chatScrollView.hasVerticalScroller = true
        chatScrollView.borderType = .bezelBorder

        chatView = NSTextView(frame: chatScrollView.bounds)
        chatView.autoresizingMask = [.width]
        chatView.isEditable = false
        chatView.isSelectable = true
        chatView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        chatView.textContainerInset = NSSize(width: 10, height: 10)
        chatView.backgroundColor = NSColor.textBackgroundColor

        chatScrollView.documentView = chatView
        contentView.addSubview(chatScrollView)

        // Input field
        inputField = NSTextField(frame: NSRect(x: 15, y: 15, width: 580, height: 35))
        inputField.autoresizingMask = [.width]
        inputField.placeholderString = "Enter instructions to apply to the text above..."
        inputField.font = NSFont.systemFont(ofSize: 13)
        inputField.delegate = self
        contentView.addSubview(inputField)

        // Send button
        sendButton = NSButton(frame: NSRect(x: 605, y: 15, width: 80, height: 35))
        sendButton.autoresizingMask = [.minXMargin]
        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.keyEquivalent = "\r"
        contentView.addSubview(sendButton)

        self.window = window

        // Display context
        if !context.isEmpty {
            llmClient.setContext(context)
            contextView.string = context
        } else {
            contextView.string = "(No text selected)"
        }

        // Focus input
        window.makeFirstResponder(inputField)
    }

    func appendText(_ text: String, color: NSColor, bold: Bool) {
        let font = bold
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let attrString = NSAttributedString(string: text, attributes: attrs)
        chatView.textStorage?.append(attrString)
        chatView.scrollToEndOfDocument(nil)
    }

    @objc func sendMessage() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        resetIdleTimer()
        inputField.stringValue = ""
        inputField.isEnabled = false
        sendButton.isEnabled = false

        appendText("You: ", color: .systemBlue, bold: true)
        appendText(text + "\n\n", color: .labelColor, bold: false)
        appendText("Processing...\n", color: .secondaryLabelColor, bold: false)

        llmClient.sendMessage(text) { [weak self] response in
            guard let self = self else { return }
            self.resetIdleTimer()

            // Remove "Processing..." text
            if let storage = self.chatView.textStorage {
                let fullText = storage.string
                if let range = fullText.range(of: "Processing...\n") {
                    let nsRange = NSRange(range, in: fullText)
                    storage.deleteCharacters(in: nsRange)
                }
            }

            self.appendText("Assistant: ", color: .systemGreen, bold: true)
            self.appendText(response + "\n\n", color: .labelColor, bold: false)

            self.inputField.isEnabled = true
            self.sendButton.isEnabled = true
            self.window?.makeFirstResponder(self.inputField)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            sendMessage()
            return true
        }
        return false
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: ChatWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var context = ""

        // Debug logging
        let debugLog = "/tmp/llmchat-debug.log"
        var debugInfo = "=== LLMChat Launch \(Date()) ===\n"
        debugInfo += "Arguments: \(CommandLine.arguments)\n"

        // Check if context file was provided
        if CommandLine.arguments.count > 1 {
            let contextFile = CommandLine.arguments[1]
            debugInfo += "Context file: \(contextFile)\n"
            debugInfo += "File exists: \(FileManager.default.fileExists(atPath: contextFile))\n"
            if FileManager.default.fileExists(atPath: contextFile) {
                context = (try? String(contentsOfFile: contextFile, encoding: .utf8)) ?? ""
                debugInfo += "File content length: \(context.count)\n"
                debugInfo += "File content: \(context.prefix(200))\n"
                try? FileManager.default.removeItem(atPath: contextFile)
            }
        }

        // If no context from file, try to get from clipboard directly
        if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugInfo += "Context empty, trying clipboard\n"
            if let clipboardString = NSPasteboard.general.string(forType: .string) {
                context = clipboardString
                debugInfo += "Clipboard content length: \(context.count)\n"
            }
        }

        debugInfo += "Final context length: \(context.count)\n"
        try? debugInfo.write(toFile: debugLog, atomically: true, encoding: .utf8)

        windowController = ChatWindowController(context: context)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
