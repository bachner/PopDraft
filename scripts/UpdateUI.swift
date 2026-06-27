// PopDraft - Visible auto-updater UI
//
// Built by co-compiling with the rest of scripts/*.swift:
//   swiftc -O scripts/*.swift -framework Cocoa -framework Carbon \
//       -framework WebKit -framework AVFoundation
//
// This file makes PopDraft's homemade updater (UpdateManager in App.swift)
// VISIBLE. The updater itself only published flags + fired an
// `onUpdateStatusChanged` callback; nothing presented them, so a manual
// "Check for Updates…" with an update available looked like a no-op and a
// download had no progress UI. Here we add:
//
//   • `UpdateProgressModel` — a tiny @MainActor ObservableObject that mirrors
//     the updater's current phase (checking / downloading / installing / up to
//     date / available / done / error) and is fed from `onUpdateStatusChanged`.
//   • `UpdateProgressView` — a small, always-readable Liquid-Glass card with a
//     status line + a determinate progress bar (reuses LiquidGlassBackground /
//     ChatPalette from the rest of the app).
//   • `UpdateProgressWindowController` — a self-contained, transparent
//     glass window that hosts the view and is driven by the model.
//   • `UpdateUIPresenter` — the glue the AppDelegate uses: present the
//     "Update Available — Install Now / Later" dialog, show the progress
//     window, and refresh it from the updater callback.

import Cocoa
import SwiftUI

// MARK: - Phase

/// The user-visible phase of an update flow. Derived from `UpdateManager`'s
/// flags by `UpdateUIPresenter`, then rendered by `UpdateProgressView`.
enum UpdatePhase: Equatable {
    case checking
    case downloading(progress: Double)   // 0…1
    case installing
    case upToDate(version: String)
    case available(version: String, current: String)
    case readyToRelaunch(version: String)
    case error(message: String)

    /// A short status line shown above the progress bar.
    var statusLine: String {
        switch self {
        case .checking:
            return "Checking for updates…"
        case .downloading(let p):
            return "Downloading update… \(Int((p * 100).rounded()))%"
        case .installing:
            return "Installing…"
        case .upToDate(let v):
            return "You're up to date (v\(v))"
        case .available(let v, _):
            return "Update available — v\(v)"
        case .readyToRelaunch(let v):
            return "Updated to v\(v)"
        case .error(let m):
            return m
        }
    }

    /// The determinate bar fraction (0…1). Indeterminate phases use a small
    /// non-zero sliver so the bar reads as "active" rather than empty.
    var fraction: Double {
        switch self {
        case .checking:                return 0.08
        case .downloading(let p):      return max(0.02, min(1.0, p))
        case .installing:              return 0.97
        case .upToDate, .readyToRelaunch: return 1.0
        case .available:               return 0.0
        case .error:                   return 0.0
        }
    }

    /// `true` while the flow is actively working (busy bar accent).
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var isError: Bool { if case .error = self { return true }; return false }
    var isDone: Bool {
        switch self { case .upToDate, .readyToRelaunch: return true; default: return false }
    }
}

// MARK: - Model

/// Observable mirror of the updater's current phase. Lives on the main actor so
/// SwiftUI can bind to it safely; `UpdateUIPresenter` pushes new phases here on
/// the main thread from the `onUpdateStatusChanged` callback.
@MainActor
final class UpdateProgressModel: ObservableObject {
    @Published var phase: UpdatePhase = .checking
    /// Set when a relaunch is offered; the view's button invokes it.
    var onRelaunch: (() -> Void)?
    /// Dismiss handler wired by the window controller.
    var onClose: (() -> Void)?
}

// MARK: - View

/// A small, self-contained Liquid-Glass progress card: an orb/sparkle header,
/// a STATUS line, a determinate progress bar, and (only when relevant) a
/// Relaunch / Close button. Driven entirely by `UpdateProgressModel.phase`.
struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Status line — always readable, single source of truth.
            Text(model.phase.statusLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(model.phase.isError ? Color(nsColor: .systemRed) : ChatPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update-status")

            progressBar

            footer
        }
        .padding(20)
        .frame(width: 360)
        .background(LiquidGlassBackground(cornerRadius: 20))
    }

    // Header: brand glyph + title.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: glyphName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(model.phase.isError ? Color(nsColor: .systemRed)
                                  : model.phase.isDone ? ChatPalette.green : ChatPalette.blue)
            Text("Software Update")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatPalette.ink)
            Spacer(minLength: 0)
        }
    }

    private var glyphName: String {
        if model.phase.isError { return "exclamationmark.triangle.fill" }
        if model.phase.isDone { return "checkmark.circle.fill" }
        return "arrow.down.circle"
    }

    // Determinate progress bar (we draw our own so it matches the glass palette
    // and reads clearly on the frosted background in light & dark).
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ChatPalette.ink3.opacity(0.25))
                Capsule()
                    .fill(barColor)
                    .frame(width: max(6, geo.size.width * CGFloat(model.phase.fraction)))
                    .animation(.easeInOut(duration: 0.25), value: model.phase.fraction)
            }
        }
        .frame(height: 8)
        .accessibilityIdentifier("update-progress-bar")
    }

    private var barColor: Color {
        if model.phase.isError { return Color(nsColor: .systemRed) }
        if model.phase.isDone { return ChatPalette.green }
        return ChatPalette.blue
    }

    // Footer: a Relaunch button when an update finished, otherwise a Close
    // button on terminal (done / error / up-to-date) states.
    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .readyToRelaunch:
            HStack {
                Spacer()
                Button("Relaunch") { model.onRelaunch?() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .upToDate, .error:
            HStack {
                Spacer()
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
        default:
            // Busy phases: no button (the window can still be dismissed by the
            // controller programmatically when it transitions).
            EmptyView()
        }
    }
}

// MARK: - Window controller

/// A small, transparent, always-on-top glass window that hosts
/// `UpdateProgressView`. Held by `UpdateUIPresenter`; created on demand and torn
/// down when the flow ends and the user dismisses it.
@MainActor
final class UpdateProgressWindowController: NSWindowController {
    let model = UpdateProgressModel()
    private var hostingView: NSHostingView<UpdateProgressView>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        window.level = .floating
        GlassWindow.makeTransparent(window)
        super.init(window: window)

        model.onClose = { [weak self] in self?.dismiss() }

        let host = NSHostingView(rootView: UpdateProgressView(model: model))
        hostingView = host
        window.contentView = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Center near the top-right of the primary (menu-bar) display and order front.
    func present() {
        guard let window = window else { return }
        // Size the window to fit the SwiftUI content before placing it.
        if let host = hostingView {
            let fitting = host.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                window.setContentSize(fitting)
            }
        }
        positionTopRight()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-fit the window when the content height changes (e.g. a button appears).
    func refitIfNeeded() {
        guard let window = window, let host = hostingView else { return }
        let fitting = host.fittingSize
        guard fitting.height > 0, abs(fitting.height - window.frame.height) > 1 else { return }
        let top = window.frame.maxY
        window.setContentSize(fitting)
        var f = window.frame
        f.origin.y = top - f.height
        window.setFrame(f, display: true, animate: false)
    }

    /// Place near the top-right of the primary screen so it's visible but
    /// unobtrusive (it never steals the center of the user's work area).
    private func positionTopRight() {
        guard let window = window else { return }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = primary?.visibleFrame else { window.center(); return }
        let margin: CGFloat = 24
        let f = window.frame
        let origin = NSPoint(x: vf.maxX - f.width - margin,
                             y: vf.maxY - f.height - margin)
        window.setFrameOrigin(origin)
    }

    func dismiss() {
        window?.orderOut(nil)
    }
}

// MARK: - Presenter

/// The glue the AppDelegate uses to make the updater visible. It:
///   • presents the "Update Available — Install Now / Later" dialog,
///   • owns + drives the glass progress window from `onUpdateStatusChanged`,
///   • maps the updater's flags to an `UpdatePhase`.
///
/// `@MainActor` because it touches AppKit/SwiftUI exclusively.
@MainActor
final class UpdateUIPresenter {
    private var progress: UpdateProgressWindowController?

    /// `nonisolated` so the AppDelegate (which is not `@MainActor`) can hold one
    /// as a stored property. The init only sets up an optional — it touches no
    /// AppKit state — so it's safe to construct off the main actor.
    nonisolated init() {}

    /// Show "Checking for updates…" immediately when the user runs a manual
    /// check, so the click has visible feedback even before the network returns.
    func beginManualCheck() {
        let pc = ensureProgressWindow()
        pc.model.phase = .checking
        pc.present()
    }

    /// Present the "Update Available" decision dialog. Returns whether the user
    /// chose to install now. Uses a native NSAlert (modal, consistent with the
    /// app's other update alerts); the visible PROGRESS afterward is the glass
    /// window.
    func presentUpdateAvailable(version: String, current: String) -> Bool {
        // Don't keep a "checking…" glass window up behind the modal dialog.
        progress?.dismiss()

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "PopDraft v\(version) is available (you have v\(current))."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Start showing download/install progress (called right after the user
    /// chooses Install Now and `downloadAndInstall()` kicks off).
    func beginDownload() {
        let pc = ensureProgressWindow()
        pc.model.phase = .downloading(progress: 0)
        pc.present()
    }

    /// Refresh the visible progress from the updater's current flags. Wired to
    /// `UpdateManager.onUpdateStatusChanged`. Only updates the window when one is
    /// already on screen (so the silent launch check stays invisible until the
    /// user opts in).
    func refresh(isDownloading: Bool, progress fraction: Double, installing: Bool,
                 finishedVersion: String?) {
        guard let pc = progress, pc.window?.isVisible == true else { return }
        if let v = finishedVersion {
            pc.model.phase = .readyToRelaunch(version: v)
        } else if installing {
            pc.model.phase = .installing
        } else if isDownloading {
            pc.model.phase = .downloading(progress: fraction)
        }
        pc.refitIfNeeded()
    }

    /// Land on the "up to date" end state in the glass window (manual check).
    func showUpToDate(current: String) {
        let pc = ensureProgressWindow()
        pc.model.phase = .upToDate(version: current)
        pc.present()
        pc.refitIfNeeded()
    }

    /// Land on an error end state in the glass window (manual check).
    func showError(_ message: String) {
        let pc = ensureProgressWindow()
        pc.model.phase = .error(message: message)
        pc.present()
        pc.refitIfNeeded()
    }

    /// Switch to the "Updated to vX — Relaunch" end state. The button invokes
    /// the supplied relaunch action.
    func showReadyToRelaunch(version: String, relaunch: @escaping () -> Void) {
        let pc = ensureProgressWindow()
        pc.model.onRelaunch = relaunch
        pc.model.phase = .readyToRelaunch(version: version)
        pc.present()
        pc.refitIfNeeded()
    }

    /// Dismiss the progress window if it's on screen (used when a manual check
    /// resolves to up-to-date / error and the existing NSAlert takes over).
    func dismissProgress() {
        progress?.dismiss()
    }

    private func ensureProgressWindow() -> UpdateProgressWindowController {
        if let pc = progress { return pc }
        let pc = UpdateProgressWindowController()
        progress = pc
        return pc
    }
}
