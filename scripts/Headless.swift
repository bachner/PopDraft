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
    var timeoutSeconds: Int = 120
    var noTools: Bool = false
}

/// Tiny `--flag value` parser (shared by both modes). Recognizes `--flag value`
/// and `--flag=value`; unknown flags are ignored (forward-compatible).
/// (promoted from `private` to `internal` so the `@main` entry in Main.swift,
///  now a separate file of the same target, can parse `--debug-show`)
enum CLIArgs {
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
        if let t = CLIArgs.value("--timeout", in: args).flatMap({ Int($0) }), t > 0 { o.timeoutSeconds = t }
        o.noTools = CLIArgs.has("--no-tools", in: args)
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
        let timeoutSeconds = opts.timeoutSeconds
        let timeoutTask = Task { @MainActor [providerLabel, modelLabel] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            } catch {
                return  // cancelled (run completed) — do nothing
            }
            guard !Task.isCancelled else { return }
            let json = await collector.makeTranscript(
                finalText: "", iterations: 0, exitStatus: "timeout",
                wallMs: Int(Date().timeIntervalSince(startWall) * 1000),
                provider: providerLabel, model: modelLabel, seed: opts.seed)
            emit(json, to: opts.outPath)
            FileHandle.standardError.write(Data("agent-once: hard timeout after \(timeoutSeconds)s\n".utf8))
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
                    onTextDelta: nil, onProgress: onProgress,
                    disableTools: opts.noTools)
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
