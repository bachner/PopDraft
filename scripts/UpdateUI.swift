// Update progress UI — a small Liquid-Glass window that makes the (previously
// invisible) self-updater visible: Checking → Downloading % → Installing → relaunch.
// Co-compiled with the rest of scripts/*.swift.

import Cocoa
import SwiftUI

/// Observable mirror of `UpdateManager` state for the progress window. The
/// AppDelegate pokes `refresh()` from `UpdateManager.onUpdateStatusChanged`.
final class UpdateProgressModel: ObservableObject {
    @Published var title: String = "Checking for updates…"
    @Published var detail: String = ""
    @Published var progress: Double = 0
    @Published var indeterminate: Bool = true
}

/// Owns the floating progress window and keeps it in sync with `UpdateManager`.
final class UpdateProgressWindowController {
    let model = UpdateProgressModel()
    private var window: NSWindow?

    /// Show the window. `checking` seeds the "Checking for updates…" phase used
    /// while a manual check's network request is in flight.
    func show(checking: Bool) {
        model.title = checking ? "Checking for updates…" : "Preparing update…"
        model.detail = ""
        model.indeterminate = true
        model.progress = 0
        if window == nil {
            let host = NSHostingView(rootView: UpdateProgressView(model: model))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                             styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.level = .floating
            w.contentView = host
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pull the latest phase from `UpdateManager` into the model.
    func refresh() {
        let mgr = UpdateManager.shared
        if mgr.isInstalling {
            model.title = "Installing update…"
            model.detail = "Replacing the app and relaunching"
            model.indeterminate = true
        } else if mgr.isDownloading {
            model.title = "Downloading update…"
            model.detail = "\(Int(mgr.downloadProgress * 100))%"
            model.indeterminate = false
            model.progress = mgr.downloadProgress
        }
    }

    func hide() { window?.orderOut(nil) }
}

/// The Liquid-Glass progress card.
struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20)).foregroundColor(.accentColor)
                Text(model.title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            if model.indeterminate {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: model.progress, total: 1.0).progressViewStyle(.linear)
            }
            if !model.detail.isEmpty {
                Text(model.detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 360, height: 150, alignment: .topLeading)
        .background(LiquidGlassBackground(cornerRadius: 16, shadow: true))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
