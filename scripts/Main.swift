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

// MARK: - Main

@main
struct PopDraftMain {
    static func main() {
        // Arm the agent tool catalog FIRST: the feature files self-register their
        // built-in tools through `AgentToolCatalog`, and every later path (headless
        // `--agent-once`, the chat UI, MCP's shadow guard) reads from it.
        BuiltinTools.arm()

        // PR10 eval seam: detect the headless CLI modes BEFORE any menu-bar /
        // window / hotkey / onboarding setup. These set up their own run loop
        // and exit() the process, so a normal launch never reaches them.
        if HeadlessRunner.handleIfRequested() { return }

        // Item 9: `--debug-show <bubble|menu|chat|settings>` shows the REAL
        // on-screen window for that state populated with sample data, then stays
        // up so a coordinator can `screencapture` it. Strictly gated behind the
        // flag — a normal launch never enters this path.
        let args = CommandLine.arguments
        if let state = CLIArgs.value("--debug-show", in: args) {
            let app = NSApplication.shared
            let delegate = DebugShowDelegate(state: state)
            app.delegate = delegate
            app.setActivationPolicy(.regular)  // foreground so the window is captured
            app.run()
            return
        }

        // Diagnostic: read the frontmost app's selected text via the AX path and
        // print it, then exit. Drive a target app into place first, then run this.
        if CLIArgs.has("--debug-capture", in: args) {
            fputs("debug-capture: AXIsProcessTrusted=\(AXIsProcessTrusted())\n", stderr)
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            fputs("debug-capture: frontmost=\(front)\n", stderr)
            // Select-all in the frontmost app (clean Cmd+A) so there IS a selection.
            let src = CGEventSource(stateID: .hidSystemState)
            for k: CGKeyCode in [0x3A, 0x3D, 0x3B, 0x3E, 0x38, 0x3C] {
                let u = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false); u?.flags = []; u?.post(tap: .cghidEventTap)
            }
            usleep(30000)
            let aD = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true); aD?.flags = .maskCommand; aD?.post(tap: .cghidEventTap)
            let aU = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false); aU?.flags = .maskCommand; aU?.post(tap: .cghidEventTap)
            usleep(150000)
            if let ax = PopupWindowController.accessibilitySelectedText() {
                fputs("debug-capture: AX selected text after Cmd+A = \(ax.count) chars: \(String(ax.prefix(120)))\n", stderr)
            } else {
                fputs("debug-capture: AX selected text = nil (app exposes no selection)\n", stderr)
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Item 9: an app delegate used ONLY for `--debug-show <state>`. On launch it
/// creates the real window controller for the requested state, seeds it with
/// representative sample data, and shows it on screen (no menu bar item, no
/// hotkeys, no onboarding). It stays up until the process is killed.
final class DebugShowDelegate: NSObject, NSApplicationDelegate {
    private let state: String
    private var popup: PopupWindowController?
    private var settings: SettingsWindowController?
    private var bubble: BubbleWindowController?
    private var history: HistoryWindowController?
    private var modelSwitchWindow: NSWindow?

    init(state: String) { self.state = state }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        switch state {
        case "bubble":
            let b = BubbleWindowController()
            b.show(animated: false)
            bubble = b
            centerOnPrimary(b.window)
        case "menu":
            let p = PopupWindowController()
            p.debugShowMenu()
            popup = p
        case "chat":
            let p = PopupWindowController()
            p.debugShowChat()
            popup = p
            centerOnPrimary(p.window)
        case "settings":
            let s = SettingsWindowController()
            s.showWindow()
            settings = s
            centerOnPrimary(s.window)
        case "modelswitch":
            // Render the type-to-search model switcher standalone for a screenshot.
            let host = NSHostingView(rootView: ModelSwitcherPalette(
                onSelect: { _ in }, onDismiss: {}))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 340),
                               styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.makeKeyAndOrderFront(nil)
            centerOnPrimary(win)
            modelSwitchWindow = win
        case "history":
            let h = HistoryWindowController()
            // No AppDelegate/popup in --debug-show; just log instead of reopening.
            h.onOpenSession = { id in
                FileHandle.standardError.write(Data("debug-show history: would open \(id)\n".utf8))
            }
            h.showWindow()
            history = h
            centerOnPrimary(h.window)
        default:
            FileHandle.standardError.write(Data(
                "--debug-show: unknown state '\(state)' (use bubble|menu|chat|settings|history)\n".utf8))
            exit(2)
        }
    }

    /// Move a window to the center of the primary (menu-bar) display so the
    /// screen capture lands on a known screen.
    private func centerOnPrimary(_ window: NSWindow?) {
        guard let window = window else { return }
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = primary?.visibleFrame else { return }
        let f = window.frame
        let origin = NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
        window.setFrameOrigin(origin)
    }
}
