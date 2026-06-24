// PopDraft - Session History Browser
//
// A self-contained window that lists every saved chat session from the
// `SessionStore`, with a search field (title match, optionally falling back to
// message text loaded on demand) and per-row Open / Delete actions. Styled with
// the shared `LiquidGlassBackground` so it matches the rest of the 3.0.x UI.
//
// Surfaced from the menu-bar status menu via a "Browse History…" item
// (AppDelegate.browseHistory). The only edits outside this file are that one
// menu item + its action and the `--debug-show history` case in Main.swift.
//
// Built by co-compiling with the rest of scripts/*.swift:
//   swiftc -O scripts/*.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation

import Cocoa
import SwiftUI

// MARK: - Pure search/filter logic (unit-tested by tests/test-history.swift)

/// Pure, dependency-free matching used by the history search field. Kept free of
/// any AppKit/SwiftUI types so it can be unit-tested in isolation.
///
/// The list view only has cheap `SessionSummary` fields (id/title/updatedAt) up
/// front; full message text is loaded on demand and passed in as `body` when the
/// user opts into a deeper search. A blank query matches everything.
enum HistorySearch {
    /// Case-/diacritic-insensitive "contains" with whitespace-trimmed query.
    static func matches(query: String, title: String, body: String? = nil) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        if contains(title, needle) { return true }
        if let body = body, contains(body, needle) { return true }
        return false
    }

    /// True when `query` is blank (so callers can skip the expensive on-demand
    /// body load entirely and keep the list responsive while typing nothing).
    static func isBlank(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A flattened, render-ready row for one saved session. `snippet` is the first
/// user message (loaded lazily, may be empty until the session is read).
struct HistoryRow: Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Double
    var snippet: String

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

// MARK: - View model

/// Drives `HistoryView`. Loads summaries from the store, builds snippets lazily,
/// and runs the (pure) search predicate. `@MainActor` because it owns UI state
/// and is only ever touched from the main thread (window controller + SwiftUI).
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var rows: [HistoryRow] = []
    /// When true, the search also matches message text (loaded on demand).
    @Published var searchMessageText: Bool = false

    private let store: SessionStore
    /// Cache of full-text bodies keyed by session id, so we don't re-read files
    /// from disk on every keystroke when "search message text" is enabled.
    private var bodyCache: [String: String] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    /// Reload the summaries from disk and rebuild rows (preserving snippets we
    /// already loaded). Called on open and after a delete.
    func reload() {
        let summaries = store.list()  // already sorted newest-first
        rows = summaries.map { summary in
            HistoryRow(
                id: summary.id,
                title: summary.title,
                updatedAt: summary.updatedAt,
                snippet: snippet(for: summary.id)
            )
        }
    }

    /// The rows that survive the current search query.
    var filteredRows: [HistoryRow] {
        if HistorySearch.isBlank(query) { return rows }
        return rows.filter { row in
            let body = searchMessageText ? fullText(for: row.id) : nil
            return HistorySearch.matches(query: query, title: row.title, body: body)
        }
    }

    /// First user message for a session, trimmed to a one-line preview. Cached.
    func snippet(for id: String) -> String {
        guard let session = store.load(id: id) else { return "" }
        let firstUser = session.messages.first { $0.role == "user" }
        let raw = firstUser?.content ?? session.selectedText ?? ""
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 120 { return oneLine }
        return String(oneLine.prefix(120)) + "…"
    }

    /// All message text for a session, concatenated, for "search message text".
    /// Loaded on demand and cached so typing stays responsive.
    private func fullText(for id: String) -> String {
        if let cached = bodyCache[id] { return cached }
        guard let session = store.load(id: id) else { return "" }
        let text = session.messages.map { $0.content }.joined(separator: "\n")
        bodyCache[id] = text
        return text
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let ok = store.delete(id: id)
        bodyCache[id] = nil
        if ok { reload() }
        return ok
    }

    static func relativeTime(from epoch: Double) -> String {
        // Mirror the menu's relative-time formatting without depending on
        // AppDelegate (which isn't reachable from --debug-show / tests cleanly).
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
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - SwiftUI view

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    /// Called with a session id when the user taps Open.
    var onOpen: (String) -> Void
    /// Called when the user dismisses the window.
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ChatPalette.hairline)
            content
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(LiquidGlassBackground(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { model.reload() }
    }

    // MARK: header (title + close + search)

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("History")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ChatPalette.ink)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ChatPalette.ink2)
                        .frame(width: 24, height: 24)
                        .background(ChatPalette.cardFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            searchBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(ChatPalette.ink3)
                TextField("Search history…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(ChatPalette.ink)
                if !model.query.isEmpty {
                    Button(action: { model.query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(ChatPalette.ink3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ChatPalette.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ChatPalette.cardStroke, lineWidth: 0.5))

            Toggle("Message text", isOn: $model.searchMessageText)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .foregroundColor(ChatPalette.ink2)
                .help("Also search within the message text of each session (loaded on demand)")
                .fixedSize()
        }
    }

    // MARK: content (list / empty states)

    @ViewBuilder
    private var content: some View {
        let rows = model.filteredRows
        if model.rows.isEmpty {
            emptyState(
                icon: "clock.arrow.circlepath",
                title: "No saved sessions yet",
                subtitle: "Chats you have with PopDraft will appear here.")
        } else if rows.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "No matches",
                subtitle: "No sessions match “\(model.query)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        HistoryRowView(
                            row: row,
                            onOpen: { onOpen(row.id) },
                            onDelete: { _ = model.delete(id: row.id) })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(ChatPalette.ink3)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ChatPalette.ink2)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(ChatPalette.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// One row: title, relative date, snippet, and Open / Delete buttons.
private struct HistoryRowView: View {
    let row: HistoryRow
    var onOpen: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ChatPalette.ink)
                        .lineLimit(1)
                    Text(HistoryViewModel.relativeTime(from: row.updatedAt))
                        .font(.system(size: 11))
                        .foregroundColor(ChatPalette.ink3)
                }
                if !row.snippet.isEmpty {
                    Text(row.snippet)
                        .font(.system(size: 12))
                        .foregroundColor(ChatPalette.ink2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(ChatPalette.ink2)
                }
                .buttonStyle(.plain)
                .help("Delete this session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ChatPalette.cardFill.opacity(hovering ? 0.9 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ChatPalette.cardStroke, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
    }
}

// MARK: - Window controller

/// Hosts `HistoryView` in a transparent, resizable Liquid-Glass window. Held by
/// the AppDelegate so it survives between opens. Reopens sessions through the
/// existing `PopupWindowController.reopenSession(id:)` path.
final class HistoryWindowController: NSWindowController {
    private var hostingView: NSHostingView<HistoryView>?
    private let model: HistoryViewModel
    /// Reopen route. Defaults to the live AppDelegate's popup controller; the
    /// `--debug-show` harness overrides it (no AppDelegate in that mode).
    var onOpenSession: (String) -> Void

    init(store: SessionStore = SessionStore(
            dir: NSString(string: "~/.popdraft").expandingTildeInPath)) {
        self.model = HistoryViewModel(store: store)
        self.onOpenSession = { id in
            (NSApp.delegate as? AppDelegate)?.popupController?.reopenSession(id: id)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PopDraft History"
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 420)
        // Transparent so the SwiftUI Liquid-Glass surface shows through.
        GlassWindow.makeTransparent(window)
        window.center()

        super.init(window: window)

        rebuildView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebuildView() {
        let view = HistoryView(
            model: model,
            onOpen: { [weak self] id in
                self?.onOpenSession(id)
                self?.window?.close()
            },
            onClose: { [weak self] in
                self?.window?.close()
            }
        )
        if let hostingView = hostingView {
            hostingView.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            hostingView = host
            window?.contentView = host
        }
    }

    func showWindow() {
        model.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
