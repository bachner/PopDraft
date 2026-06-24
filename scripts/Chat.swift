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
    /// UI overhaul (item 7): messages the user sent WHILE the agent was already
    /// generating. They're appended to the transcript immediately (shown as sent
    /// user bubbles) and flushed together as ONE follow-up turn the moment the
    /// current run finishes — the input never blocks and nothing is dropped.
    private var pendingFollowups: [String] = []
    /// Count of queued-but-not-yet-processed user messages (drives the optional
    /// "queued (N)" affordance near the input).
    @Published private(set) var queuedCount: Int = 0
    /// The chat panel's current pixel size, driven by the window's content size
    /// (updated by the controller on resize). `ChatView` frames itself to this so
    /// the user-resizable window's content reflows cleanly (the SwiftUI content
    /// can't reliably fill an NSHostingView via `maxHeight: .infinity` because the
    /// transcript's GeometryReader has no intrinsic height).
    @Published var panelSize: CGSize = CGSize(width: 720, height: 560)
    /// The text of the last user message sent (for Up-arrow recall in the input).
    private(set) var lastSentUserMessage: String = ""

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

    /// Submit a new user turn (from the input bar). The input is NEVER blocked:
    /// if the agent is idle this starts a turn; if it's already generating the
    /// message is appended to the transcript and queued, then drained as a
    /// follow-up turn the moment the current run finishes (item 7).
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        lastSentUserMessage = trimmed
        let now = Date().timeIntervalSince1970
        session.messages.append(ChatMessage(role: "user", content: trimmed, createdAt: now))
        session.updatedAt = now
        rebuildVisible()
        if isGenerating {
            // Mid-generation: keep streaming, queue this for the next turn. The
            // message already shows as a sent bubble (rebuildVisible above).
            pendingFollowups.append(trimmed)
            queuedCount = pendingFollowups.count
        } else {
            run()
        }
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
                // Item 7: re-append any user messages the person typed WHILE this
                // run was generating (they were queued in `pendingFollowups` and
                // appended to `self.session`, but `outcome.session` was built from
                // the pre-run snapshot and would otherwise drop them).
                for followup in self.pendingFollowups {
                    saved.messages.append(ChatMessage(
                        role: "user", content: followup,
                        createdAt: Date().timeIntervalSince1970))
                }
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
    /// If the user queued follow-up messages mid-generation (item 7), drain them
    /// and immediately start the next turn so nothing is dropped.
    private func finishGenerating() {
        streamingText = ""
        liveToolCards = []
        pendingConfirmations = []
        isGenerating = false
        rebuildVisible()
        if !pendingFollowups.isEmpty {
            // The queued messages are already in `session.messages` (appended by
            // `send`, in order); clear the queue and run ONE follow-up turn against
            // the full transcript so they're all processed together.
            pendingFollowups.removeAll()
            queuedCount = 0
            run()
        }
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
        pendingFollowups.removeAll()
        queuedCount = 0
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

    /// Item 9 debug: append a queued user follow-up + show it as a sent bubble,
    /// driving the "queued (N)" affordance for the `--debug-show chat` capture.
    /// Does NOT start a model run (no network).
    func debugSeedQueuedFollowup(_ text: String) {
        lastSentUserMessage = text
        let now = Date().timeIntervalSince1970
        session.messages.append(ChatMessage(role: "user", content: text, createdAt: now))
        session.updatedAt = now
        rebuildVisible()
        pendingFollowups.append(text)
        queuedCount = pendingFollowups.count
        isGenerating = true
        streamingText = "Sure — condensing further and adding rollback notes"
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
// MARK: - Chat UI: WebKit Markdown + Mermaid renderer (UI overhaul, item 6)

/// Shared, lazily-loaded copies of the bundled web assets so each message's
/// WKWebView doesn't re-read them from disk. `available` is true only when
/// marked.js loaded — the caller falls back to the native renderer otherwise.
///
/// NOT main-actor isolated: every member is an immutable `let` `String` (which
/// is `Sendable`) lazily initialized once, thread-safely, by the Swift runtime
/// from a pure bundle read. Keeping it nonisolated lets `available` be read from
/// SwiftUI view builders (which CI compiles as nonisolated) without an isolation
/// violation, while staying concurrency-safe.
enum MarkdownWebAssets {
    static let marked: String = AppAssets.webResource("marked.min.js") ?? ""
    static let mermaid: String = AppAssets.webResource("mermaid.min.js") ?? ""
    static let highlightJS: String = AppAssets.webResource("highlight.min.js") ?? ""
    static let highlightLight: String = AppAssets.webResource("github.min.css") ?? ""
    static let highlightDark: String = AppAssets.webResource("github-dark.min.css") ?? ""

    /// The rich renderer is only usable if at least marked.js is present.
    static var available: Bool { !marked.isEmpty }
}

/// Renders one assistant message body as full Markdown (headings, lists, tables,
/// links, bold/italic, fenced code with copy + syntax highlighting) AND Mermaid
/// diagrams (```mermaid blocks) inside a `WKWebView`. The web view auto-reports
/// its rendered height back so the SwiftUI parent can size the bubble exactly.
///
/// Self-contained & offline: marked / mermaid / highlight.js + CSS are inlined
/// from the bundle, so the web view never loads anything over the network. Links
/// open in the user's browser instead of navigating the (local) document.
///
/// `@MainActor` so its `NSViewRepresentable` methods (which SwiftUI always calls
/// on the main actor) can touch the main-actor-isolated `Coordinator` (e.g.
/// mutate `lastMarkdown`) without an isolation violation under CI's stricter
/// concurrency checking, where these methods would otherwise be nonisolated.
@MainActor
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let width: CGFloat
    /// Updated by the JS height-report callback so the SwiftUI parent can grow.
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "heightChanged")
        controller.add(context.coordinator, name: "copyCode")
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // transparent → glass shows
        webView.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.webView = webView
        loadHTML(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Re-render only when the markdown actually changed (streaming updates).
        if context.coordinator.lastMarkdown != markdown {
            loadHTML(into: webView, context: context)
        }
    }

    private func loadHTML(into webView: WKWebView, context: Context) {
        context.coordinator.lastMarkdown = markdown
        let isDark = (webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let html = Self.document(markdown: markdown, dark: isDark)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: HTML document

    /// Build the full self-contained HTML page. The markdown is injected as a
    /// JSON-encoded string constant (so backticks/quotes can't break out), parsed
    /// by marked, highlighted, and mermaid-rendered; then the body height is
    /// posted back to Swift.
    static func document(markdown: String, dark: Bool) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: [markdown]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let ink = dark ? "#e8e8ea" : "#1d1d1f"
        let ink2 = dark ? "#a0a0a8" : "#6e6e73"
        let blue = "#0A84FF"
        let codeBg = dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.045)"
        let border = dark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.10)"
        let hlCSS = dark ? MarkdownWebAssets.highlightDark : MarkdownWebAssets.highlightLight
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(hlCSS)
        html,body{margin:0;padding:0;background:transparent;}
        body{font:13px/1.5 -apple-system,"SF Pro Text",system-ui,sans-serif;color:\(ink);
             -webkit-font-smoothing:antialiased;overflow:hidden;}
        #c{padding:0;}
        #c>*:first-child{margin-top:0;} #c>*:last-child{margin-bottom:0;}
        h1,h2,h3,h4{font-weight:600;line-height:1.3;margin:0.8em 0 0.4em;}
        h1{font-size:18px;} h2{font-size:16px;} h3{font-size:14px;} h4{font-size:13px;}
        p{margin:0.5em 0;} ul,ol{margin:0.5em 0;padding-left:1.4em;} li{margin:0.2em 0;}
        a{color:\(blue);text-decoration:none;} a:hover{text-decoration:underline;}
        strong{font-weight:600;} em{font-style:italic;}
        code{font-family:ui-monospace,"SF Mono",monospace;font-size:12px;
             background:\(codeBg);padding:1.5px 5px;border-radius:5px;}
        blockquote{margin:0.6em 0;padding:2px 12px;border-left:3px solid \(blue);
             color:\(ink2);}
        table{border-collapse:collapse;margin:0.6em 0;font-size:12.5px;width:auto;}
        th,td{border:1px solid \(border);padding:5px 10px;text-align:left;}
        th{background:\(codeBg);font-weight:600;}
        hr{border:none;border-top:1px solid \(border);margin:1em 0;}
        .codewrap{position:relative;margin:0.6em 0;border:1px solid \(border);
             border-radius:10px;overflow:hidden;background:\(codeBg);}
        .codewrap .bar{display:flex;align-items:center;justify-content:space-between;
             padding:5px 10px;font-size:9.5px;text-transform:uppercase;letter-spacing:0.04em;
             color:\(ink2);border-bottom:1px solid \(border);}
        .codewrap pre{margin:0;padding:10px;overflow-x:auto;}
        .codewrap pre code{background:none;padding:0;font-size:11.5px;line-height:1.45;}
        .copybtn{cursor:pointer;border:none;background:none;color:\(ink2);font:inherit;
             font-size:9.5px;text-transform:uppercase;letter-spacing:0.04em;padding:2px 6px;
             border-radius:5px;} .copybtn:hover{background:\(codeBg);color:\(blue);}
        .mermaid{margin:0.6em 0;text-align:center;background:transparent;}
        </style></head><body><div id="c"></div>
        <script>\(MarkdownWebAssets.marked)</script>
        <script>\(MarkdownWebAssets.highlightJS)</script>
        <script>
        (function(){
          var md = \(json)[0];
          try {
            marked.setOptions({gfm:true, breaks:true, highlight:function(code, lang){
              try { if(lang && hljs.getLanguage(lang)) return hljs.highlight(code,{language:lang}).value;
                    return hljs.highlightAuto(code).value; } catch(e){ return code; }
            }});
          } catch(e){}
          // Split fenced ```mermaid blocks out before markdown so they aren't
          // mangled, render the rest with marked.
          var html = '';
          try { html = marked.parse(md); } catch(e){ html = '<pre>'+md.replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];})+'</pre>'; }
          var c = document.getElementById('c');
          c.innerHTML = html;
          // Wrap each <pre><code> in a card with a language label + copy button.
          // Mermaid code blocks are converted to <div class="mermaid"> instead.
          c.querySelectorAll('pre code').forEach(function(code){
            var pre = code.parentElement;
            var cls = (code.className||'');
            var langm = cls.match(/language-(\\w+)/);
            var lang = langm ? langm[1] : '';
            if(lang === 'mermaid'){
              var div = document.createElement('div');
              div.className = 'mermaid';
              div.textContent = code.textContent;
              pre.replaceWith(div);
              return;
            }
            var wrap = document.createElement('div'); wrap.className='codewrap';
            var bar = document.createElement('div'); bar.className='bar';
            var label = document.createElement('span'); label.textContent = lang || 'code';
            var btn = document.createElement('button'); btn.className='copybtn'; btn.textContent='Copy';
            btn.addEventListener('click', function(){
              try { window.webkit.messageHandlers.copyCode.postMessage(code.textContent); } catch(e){}
              btn.textContent='Copied'; setTimeout(function(){btn.textContent='Copy';}, 1400);
            });
            bar.appendChild(label); bar.appendChild(btn);
            wrap.appendChild(bar);
            var newpre = document.createElement('pre'); newpre.appendChild(code.cloneNode(true));
            wrap.appendChild(newpre);
            pre.replaceWith(wrap);
          });
          function report(){
            var h = Math.ceil(document.getElementById('c').getBoundingClientRect().height);
            try { window.webkit.messageHandlers.heightChanged.postMessage(h); } catch(e){}
          }
          // Render mermaid diagrams (async), then report final height.
          function renderMermaid(){
            if(typeof mermaid === 'undefined' || !c.querySelector('.mermaid')){ report(); return; }
            try {
              mermaid.initialize({startOnLoad:false, theme:\(dark ? "'dark'" : "'default'"),
                                  securityLevel:'strict', fontFamily:'-apple-system,system-ui,sans-serif'});
              mermaid.run({nodes: c.querySelectorAll('.mermaid')}).then(report).catch(report);
            } catch(e){ report(); }
          }
          // Report height now (text) and again after mermaid + images settle.
          report();
          new ResizeObserver(report).observe(c);
          renderMermaid();
        })();
        </script>
        <script>\(MarkdownWebAssets.mermaid)</script>
        <script>/* mermaid loads last; trigger a re-render now that it exists */
          (function(){ try {
            var c=document.getElementById('c');
            if(typeof mermaid!=='undefined' && c.querySelector('.mermaid')){
              mermaid.initialize({startOnLoad:false, theme:\(dark ? "'dark'" : "'default'"),
                                  securityLevel:'strict', fontFamily:'-apple-system,system-ui,sans-serif'});
              mermaid.run({nodes:c.querySelectorAll('.mermaid')}).then(function(){
                var h=Math.ceil(c.getBoundingClientRect().height);
                try{window.webkit.messageHandlers.heightChanged.postMessage(h);}catch(e){}
              }).catch(function(){});
            }
          } catch(e){} })();
        </script>
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: MarkdownWebView
        weak var webView: WKWebView?
        var lastMarkdown: String = "\u{0}"  // sentinel so first render always fires

        init(_ parent: MarkdownWebView) { self.parent = parent }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "heightChanged":
                if let n = message.body as? NSNumber {
                    let h = CGFloat(truncating: n)
                    if abs(h - parent.measuredHeight) > 0.5 {
                        parent.measuredHeight = max(h, 1)
                    }
                }
            case "copyCode":
                if let s = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
            default: break
            }
        }

        // Links open in the user's browser; never navigate the local document.
        func webView(_ webView: WKWebView, decidePolicyFor nav: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if nav.navigationType == .linkActivated, let url = nav.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// A SwiftUI wrapper that hosts `MarkdownWebView` at its self-measured height,
/// with a native-Markdown fallback while the height is unknown / web assets are
/// missing. Keeps a plain-text copy affordance via the parent message bubble.
struct RichMarkdownBody: View {
    let markdown: String
    @State private var height: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            MarkdownWebView(markdown: markdown, width: geo.size.width, measuredHeight: $height)
        }
        .frame(height: max(height, 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
        // Item 6: when the bundled web assets are present, render the full body
        // (Markdown + tables + fenced code + Mermaid diagrams) in a WKWebView.
        // Otherwise fall back to the native AttributedString + CodeBlockView path.
        if MarkdownWebAssets.available {
            RichMarkdownBody(markdown: text)
        } else {
            nativeMarkdown(text)
        }
    }

    @ViewBuilder private func nativeMarkdown(_ text: String) -> some View {
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
/// Reports how far the transcript's bottom sentinel sits below the visible
/// bottom edge of the scroll view (≤ threshold ⇒ the user is pinned to the
/// bottom). Used for smart "stick to bottom" auto-scroll.
private struct BottomDistanceKey: PreferenceKey {
    // `let` (not `var`): the protocol only reads this, and a `let` is
    // concurrency-safe global state (no mutable shared state under Swift 6).
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: AgentChatViewModel
    let onMinimize: () -> Void
    @FocusState private var inputFocused: Bool
    /// Smart auto-scroll: true while the user is pinned to the bottom. Auto-scroll
    /// follows new content only while this is true; scrolling up turns it off, and
    /// scrolling back to the bottom turns it back on.
    @State private var isAtBottom = true

    private let scrollSpaceName = "transcriptScroll"
    /// Within this many points of the bottom counts as "pinned".
    private let bottomThreshold: CGFloat = 40

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
        // Size to the window's content size (published + updated on resize). This
        // makes the user-resizable window reflow cleanly — see `panelSize`.
        .frame(width: max(viewModel.panelSize.width, GlassWindow.ChatGeometry.minSize.width),
               height: max(viewModel.panelSize.height, GlassWindow.ChatGeometry.minSize.height))
        .background(LiquidGlassBackground(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            // Measure the visible viewport height so we can tell, from the bottom
            // sentinel's position in the scroll coordinate space, whether the user
            // is pinned to the bottom.
            GeometryReader { viewport in
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
                        // Invisible bottom sentinel: its maxY in the scroll space,
                        // minus the viewport height, is the user's distance from
                        // the bottom (≤ threshold ⇒ pinned).
                        Color.clear
                            .frame(height: 1)
                            .id("__bottom__")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomDistanceKey.self,
                                        value: geo.frame(in: .named(scrollSpaceName)).maxY
                                            - viewport.size.height)
                                })
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: scrollSpaceName)
                .onPreferenceChange(BottomDistanceKey.self) { distance in
                    // distance ≈ 0 when the sentinel sits at the viewport's bottom.
                    let pinned = distance <= bottomThreshold
                    if pinned != isAtBottom {
                        withAnimation(.easeOut(duration: 0.18)) { isAtBottom = pinned }
                    }
                }
                // Smart auto-scroll: follow the bottom only while the user is pinned.
                .onChange(of: viewModel.visibleMessages.count) { _, _ in autoScroll(proxy) }
                .onChange(of: viewModel.streamingText) { _, _ in autoScroll(proxy) }
                .onChange(of: viewModel.liveToolCards.count) { _, _ in autoScroll(proxy) }
                .onChange(of: viewModel.pendingConfirmations.count) { _, _ in autoScroll(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        jumpToLatestButton(proxy)
                            .padding(.trailing, 14)
                            .padding(.bottom, 10)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
    }

    /// A floating "jump to latest" button shown when the user has scrolled up.
    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isAtBottom = true
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("__bottom__", anchor: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
                Text("Latest").font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(ChatPalette.blue))
            .shadow(color: ChatPalette.blue.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest message")
    }

    /// Auto-scroll to the bottom, but ONLY while the user is pinned there. Never
    /// yanks the view down while they're reading scrolled-up content.
    private func autoScroll(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
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
                    // Item 7: input stays ENABLED during generation — a message
                    // sent mid-stream is queued and run as a follow-up turn.

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
                if viewModel.queuedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full").font(.system(size: 9))
                        Text("queued \(viewModel.queuedCount)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                Spacer()
                Text(viewModel.isGenerating ? "Streaming… you can keep typing" : "Enter to send · ↑ to recall")
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
        // Sending mid-generation is allowed (queued as a follow-up) — only an
        // empty draft blocks the button.
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        viewModel.send(viewModel.draft)
    }

    /// Up-arrow in an empty input recalls the last sent user message (item 8).
    fileprivate func recallLastMessage() {
        guard viewModel.draft.isEmpty, !viewModel.lastSentUserMessage.isEmpty else { return }
        viewModel.draft = viewModel.lastSentUserMessage
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
