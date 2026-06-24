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

// MARK: - Version

struct AppVersion {
    static var current: String {
        // 1. Bundle Info.plist (DMG/app bundle install)
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !bundleVersion.isEmpty,
           bundleVersion != "1.0" {
            return bundleVersion
        }

        // 2. Version file written by install.sh (source install)
        let versionFile = NSHomeDirectory() + "/.popdraft/version"
        if let fileVersion = try? String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !fileVersion.isEmpty {
            return fileVersion
        }

        // 3. Dev build fallback
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "dev-\(formatter.string(from: AppVersion.buildDate))"
    }

    private static let buildDate: Date = Date()
}

// MARK: - App Assets

/// Loads bespoke brand PNGs bundled at `Contents/Resources/Assets/`.
///
/// Every accessor is nil-safe: when PopDraft runs as a bare binary from the
/// `install.sh` source-install (no `.app` bundle, no `Assets/` directory) all
/// of these return `nil` and callers fall back to SF Symbols / code-drawn art.
enum AppAssets {
    /// Looks up a PNG named `<name>.png` inside the bundle's `Assets/` subdirectory.
    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Assets") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Standalone orb bubble (used by the corner bubble in a later PR).
    static var bubbleOrb: NSImage? { image(named: "popdraft-bubble") }

    /// Onboarding hero illustration (used by onboarding in a later PR).
    static var onboardingHero: NSImage? { image(named: "popdraft-onboarding-hero") }

    /// Full colorful app-icon orb (e.g. for an About panel).
    static var appIconImage: NSImage? { image(named: "popdraft-app-icon") }

    /// Sheet of icon variants.
    static var iconSet: NSImage? { image(named: "popdraft-icon-set") }

    /// Load a bundled web asset (JS/CSS) from `Contents/Resources/web/` for the
    /// `WKWebView`-backed Markdown+Mermaid renderer. Falls back to the source-tree
    /// `resources/web/` directory for dev builds run straight out of the repo, so
    /// the rich renderer works without first packaging an .app.
    static func webResource(_ name: String) -> String? {
        // 1) Packaged app bundle.
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "web"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        // 2) Source install: ~/.popdraft/web (populated by install.sh).
        let installed = URL(fileURLWithPath: NSString(string: "~/.popdraft/web/\(name)").expandingTildeInPath)
        if let s = try? String(contentsOf: installed, encoding: .utf8) { return s }

        // 3) Dev fallback: walk up from the executable to find resources/web.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("resources/web/\(name)")
            if let s = try? String(contentsOf: candidate, encoding: .utf8) { return s }
            dir.deleteLastPathComponent()
        }
        // 4) CWD fallback.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("resources/web/\(name)")
        return try? String(contentsOf: cwd, encoding: .utf8)
    }
}

// MARK: - Menu Bar Glyph

enum MenuBarGlyph {
    /// Draws a bespoke, on-brand monochrome template glyph for the menu bar:
    /// the orb silhouette (a stroked circle) with a small 4-point sparkle at the
    /// upper-right, echoing the colorful brand orb. Returned as a template image
    /// so AppKit tints it correctly for light/dark menu bars and active states.
    ///
    /// The colorful orb PNG cannot be used here because template images must be
    /// monochrome, and rasterizing the orb to ~18px looks muddy.
    static func template(size: CGFloat = 18) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Renders the same glyph onto a flat color (non-template) for previews.
    static func preview(size: CGFloat = 128, color: NSColor = .black) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setStroke()
            color.setFill()
            draw(in: rect)
            return true
        }
    }

    /// Shared vector drawing for both the template and the preview. Uses the
    /// current fill/stroke colors so the template path tints automatically.
    private static func draw(in rect: NSRect) {
        let w = rect.width
        let h = rect.height
        let unit = min(w, h)
        let lineWidth = max(1.0, unit * 0.085)

        // Orb: a stroked circle, inset to leave room for the sparkle + stroke.
        let inset = lineWidth + unit * 0.12
        let orbRect = NSRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: w - inset * 2,
            height: h - inset * 2
        )
        let orb = NSBezierPath(ovalIn: orbRect)
        orb.lineWidth = lineWidth
        orb.stroke()

        // Sparkle: a 4-point star at the upper-right, echoing the brand orb.
        let sparkleCenter = NSPoint(x: rect.maxX - unit * 0.16, y: rect.maxY - unit * 0.16)
        let arm = unit * 0.16      // tip distance from center
        let waist = unit * 0.045   // half-width at the pinched waist
        let s = NSBezierPath()
        s.move(to: NSPoint(x: sparkleCenter.x, y: sparkleCenter.y + arm))          // top tip
        s.line(to: NSPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y + waist))
        s.line(to: NSPoint(x: sparkleCenter.x + arm, y: sparkleCenter.y))          // right tip
        s.line(to: NSPoint(x: sparkleCenter.x + waist, y: sparkleCenter.y - waist))
        s.line(to: NSPoint(x: sparkleCenter.x, y: sparkleCenter.y - arm))          // bottom tip
        s.line(to: NSPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y - waist))
        s.line(to: NSPoint(x: sparkleCenter.x - arm, y: sparkleCenter.y))          // left tip
        s.line(to: NSPoint(x: sparkleCenter.x - waist, y: sparkleCenter.y + waist))
        s.close()
        s.fill()
    }
}

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let logPath: String
    private let maxLogSize: Int = 1_000_000  // 1MB max log size

    private init() {
        let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        logPath = "\(configDir)/debug.log"

        // Rotate log if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int,
           size > maxLogSize {
            let backupPath = "\(configDir)/popdraft.log.old"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.moveItem(atPath: logPath, toPath: backupPath)
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"

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

    func error(_ message: String) {
        log(message, level: "ERROR")
    }

    func info(_ message: String) {
        log(message, level: "INFO")
    }
}

// MARK: - Liquid Glass background (UI overhaul)

/// The reusable Liquid-Glass pane that matches `design-mocks/mock-1-liquid-glass`:
/// a soft aurora gradient wash (low-opacity blue → indigo → violet) under a
/// `.ultraThinMaterial` frosted layer, finished with a hairline border and a
/// soft, layered drop shadow. Used as the background for the chat panel, the
/// action menu, and the settings window so they read as floating frosted glass
/// over the desktop (the hosting NSWindow must be transparent for this to show).
///
/// `cornerRadius` controls the rounding (≈20–24 for panels, ≈12–16 for cards).
/// `shadow` can be disabled where the parent already casts one (e.g. cards).
struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 22
    var shadow: Bool = true
    /// A subtler variant for nested cards (less aurora, tighter border).
    var card: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // 1) Aurora gradient wash — the soft colored glow behind the frost.
            auroraWash
                .opacity(card ? 0.5 : 1.0)

            // 2) Frosted glass layer. `.ultraThinMaterial` blends with whatever
            //    is behind the (transparent) window, giving the real glass look.
            shape.fill(.ultraThinMaterial)

            // 3) A faint top-down sheen so the glass catches light at the top.
            shape.fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.0)],
                    startPoint: .top, endPoint: .center))
        }
        .clipShape(shape)
        // 4) Hairline border: a bright top edge fading to a dark bottom edge.
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0.08),
                             Color.black.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1))
        // 5) Soft, layered drop shadow (only for top-level panels).
        .modifier(GlassShadow(enabled: shadow))
    }

    private var auroraWash: some View {
        ZStack {
            // Base tint.
            Color(red: 0.96, green: 0.97, blue: 1.0).opacity(0.55)
            // Blue bloom, top-left.
            RadialGradient(
                colors: [ChatPalette.blue.opacity(0.22), .clear],
                center: UnitPoint(x: 0.16, y: 0.10), startRadius: 0, endRadius: 360)
            // Indigo bloom, top-right.
            RadialGradient(
                colors: [Color(red: 0.42, green: 0.36, blue: 0.95).opacity(0.20), .clear],
                center: UnitPoint(x: 0.92, y: 0.04), startRadius: 0, endRadius: 380)
            // Violet bloom, bottom-right.
            RadialGradient(
                colors: [Color(red: 0.74, green: 0.45, blue: 0.98).opacity(0.18), .clear],
                center: UnitPoint(x: 0.96, y: 0.96), startRadius: 0, endRadius: 420)
            // Soft cyan bloom, bottom-left.
            RadialGradient(
                colors: [Color(red: 0.30, green: 0.78, blue: 0.98).opacity(0.14), .clear],
                center: UnitPoint(x: 0.04, y: 0.92), startRadius: 0, endRadius: 360)
        }
    }
}

/// A soft, layered drop shadow for a glass panel (two stacked shadows read more
/// natural than one). A no-op when `enabled` is false.
private struct GlassShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 12)
                .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
        } else {
            content
        }
    }
}

/// Hosts SwiftUI content in a fully transparent NSWindow/NSPanel so a
/// `LiquidGlassBackground` shows through (vibrancy reads the desktop behind).
/// Centralizes the "make this window glass-ready" setup used by the chat,
/// action menu, and settings.
enum GlassWindow {
    /// Persist + restore the chat window's last size & position so it doesn't snap
    /// back to a cursor-pinned default every time it's reopened (UI overhaul: the
    /// chat panel is now user-resizable & movable). Stored in UserDefaults as a
    /// flat dict; absent/invalid → nil so callers fall back to the default frame.
    enum ChatGeometry {
        private static let key = "popdraft.chatWindowFrame"
        static let minSize = NSSize(width: 420, height: 360)

        static func save(_ frame: NSRect) {
            UserDefaults.standard.set(
                ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
                forKey: key)
        }

        static func load() -> NSRect? {
            guard let d = UserDefaults.standard.dictionary(forKey: key),
                  let x = (d["x"] as? NSNumber)?.doubleValue,
                  let y = (d["y"] as? NSNumber)?.doubleValue,
                  let w = (d["w"] as? NSNumber)?.doubleValue,
                  let h = (d["h"] as? NSNumber)?.doubleValue
            else { return nil }
            let size = NSSize(width: max(CGFloat(w), minSize.width),
                              height: max(CGFloat(h), minSize.height))
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
    }

    /// Strip the window chrome and make the backing surface clear so SwiftUI's
    /// frosted glass + rounded corners are the only thing the user sees.
    static func makeTransparent(_ window: NSWindow) {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false  // the SwiftUI glass casts its own soft shadow
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Hide the traffic-light buttons if this is a titled window (settings).
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
