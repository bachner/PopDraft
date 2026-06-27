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
    private var update: UpdateProgressWindowController?

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
        case "history":
            let h = HistoryWindowController()
            // No AppDelegate/popup in --debug-show; just log instead of reopening.
            h.onOpenSession = { id in
                FileHandle.standardError.write(Data("debug-show history: would open \(id)\n".utf8))
            }
            h.showWindow()
            history = h
            centerOnPrimary(h.window)
        case let s where s == "update" || s.hasPrefix("update:"):
            // Renders the VISIBLE auto-updater UI for a screen capture. A
            // sub-state after the colon selects the phase:
            //   update            → "Checking…" (default)
            //   update:available  → the "Update Available — Install Now/Later" dialog
            //   update:downloading→ "Downloading update… 45%"
            //   update:installing → "Installing…"
            //   update:relaunch   → "Updated to vX — Relaunch"
            //   update:uptodate   → "You're up to date"
            //   update:error      → an error end-state
            let sub = s.contains(":") ? String(s.split(separator: ":")[1]) : "checking"
            if sub == "available" {
                // The real "Update Available" dialog is a native NSAlert; show it
                // non-blocking so it can be captured.
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "PopDraft v2.7.0 is available (you have v2.6.0)."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Install Now")
                alert.addButton(withTitle: "Later")
                let panel = alert.window
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                break
            }
            let u = UpdateProgressWindowController()
            switch sub {
            case "downloading": u.model.phase = .downloading(progress: 0.45)
            case "installing":  u.model.phase = .installing
            case "relaunch":    u.model.phase = .readyToRelaunch(version: "2.7.0")
            case "uptodate":    u.model.phase = .upToDate(version: "2.6.0")
            case "error":       u.model.phase = .error(message: "Could not connect to GitHub. Please check your internet connection.")
            default:            u.model.phase = .checking
            }
            u.model.onRelaunch = {
                FileHandle.standardError.write(Data("debug-show update: would relaunch\n".utf8))
            }
            u.present()
            centerOnPrimary(u.window)
            update = u
        default:
            FileHandle.standardError.write(Data(
                "--debug-show: unknown state '\(state)' (use bubble|menu|chat|settings|history|update[:phase])\n".utf8))
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
