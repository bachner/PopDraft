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

// MARK: - Llama Server Manager

class LlamaServerManager {
    static let shared = LlamaServerManager()

    enum Status {
        case unknown, online, loading, offline
    }

    private(set) var status: Status = .unknown
    var onStatusChanged: ((Status) -> Void)?
    private var pollTimer: Timer?

    private var healthURL: URL {
        let config = LLMConfig.load()
        return URL(string: "\(config.llamacppURL)/health")!
    }

    func startPolling(interval: TimeInterval = 10.0) {
        stopPolling()
        checkNow()
        DispatchQueue.main.async {
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkNow()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func checkNow(completion: ((Status) -> Void)? = nil) {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let newStatus: Status
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    newStatus = .online
                } else if http.statusCode == 503 {
                    newStatus = .loading
                } else {
                    newStatus = .offline
                }
            } else {
                newStatus = .offline
            }
            DispatchQueue.main.async {
                let changed = self?.status != newStatus
                self?.status = newStatus
                if changed {
                    self?.onStatusChanged?(newStatus)
                }
                completion?(newStatus)
            }
        }.resume()
    }

    func restart(completion: @escaping (Bool) -> Void) {
        let config = LLMConfig.load()
        let plistPath = NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath

        // Create plist if missing
        if !FileManager.default.fileExists(atPath: plistPath) {
            DependencyManager.shared.createLlamaLaunchAgentForModel(
                LLMConfig.llamaModels.first { $0.id == config.llamaModel } ?? LLMConfig.llamaModels[0]
            )
            guard FileManager.default.fileExists(atPath: plistPath) else {
                completion(false)
                return
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let uid = getuid()

            // Stop existing server if running
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stopProcess.arguments = ["bootout", "gui/\(uid)/com.popdraft.llama-server"]
            try? stopProcess.run()
            stopProcess.waitUntilExit()

            // Ensure service is enabled (uninstall can disable it permanently)
            let enableProcess = Process()
            enableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            enableProcess.arguments = ["enable", "gui/\(uid)/com.popdraft.llama-server"]
            try? enableProcess.run()
            enableProcess.waitUntilExit()

            let startProcess = Process()
            startProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            startProcess.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            try? startProcess.run()
            startProcess.waitUntilExit()

            let healthURL = URL(string: "\(config.llamacppURL)/health")!
            var serverReady = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                URLSession.shared.dataTask(with: healthURL) { _, response, _ in
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        ok = true
                    }
                    sem.signal()
                }.resume()
                _ = sem.wait(timeout: .now() + 2)
                if ok {
                    serverReady = true
                    break
                }
            }

            DispatchQueue.main.async {
                if serverReady {
                    self?.status = .online
                    self?.onStatusChanged?(.online)
                }
                completion(serverReady)
            }
        }
    }
}

// MARK: - Vision Server Manager (dedicated parallel vision llama-server)

/// Manages a SECOND llama-server — dedicated to vision — running in PARALLEL to
/// the main one (:10819). It serves a multimodal VL model + its mmproj projector
/// on :10820 so `see_image` can SEE regardless of what the main provider/model
/// is. Independent of the global provider/config: whenever the model files are
/// present we run this server, and route `see_image` to it.
///
/// Mirrors `LlamaServerManager` / `DependencyManager.switchLocalModelFileAndRestart`:
/// a launchd job `com.popdraft.llama-vision` (plist under ~/Library/LaunchAgents)
/// started via `launchctl bootout`+`bootstrap gui/<uid>`.
class VisionServerManager {
    static let shared = VisionServerManager()

    /// The dedicated vision model + its vision projector, both under
    /// ~/.popdraft/models/. The user downloads these out-of-band (no download UI
    /// here); when both are present the server is started automatically.
    static let modelFilename = "Qwen3.5-0.8B-Q4_K_M.gguf"
    static let mmprojFilename = "mmproj-Qwen3.5-0.8B-F16.gguf"

    /// Second llama-server endpoint (parallel to the main :10819 one).
    static let endpoint = "http://127.0.0.1:10820"
    static let port = 10820
    static let launchLabel = "com.popdraft.llama-vision"

    private static var modelsDir: String {
        NSString(string: "~/.popdraft/models").expandingTildeInPath
    }
    static var modelPath: String { modelsDir + "/" + modelFilename }
    static var mmprojPath: String { modelsDir + "/" + mmprojFilename }
    private static var plistPath: String {
        NSString(string: "~/Library/LaunchAgents/\(launchLabel).plist").expandingTildeInPath
    }

    /// Both the VL model and its vision projector must be present for the
    /// dedicated vision server to be startable / usable.
    static var isAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelPath) && fm.fileExists(atPath: mmprojPath)
    }

    private let lock = NSLock()
    /// We only bootstrap once per process — launchd `KeepAlive` restarts the
    /// server if it crashes, so re-bootstrapping a still-loading server (which
    /// would kill and reload it) is avoided.
    private var startAttempted = false

    private var healthURL: URL { URL(string: "\(Self.endpoint)/health")! }

    /// Bounded, synchronous /health probe (mirrors `LlamaServerManager.restart`'s
    /// readiness poll). BLOCKS — call off the main thread.
    func isHealthy(timeout: TimeInterval = 2.0) -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return ok
    }

    /// Start the dedicated vision llama-server if its model files exist and it
    /// isn't already serving. Idempotent + safe to call repeatedly. BLOCKS (writes
    /// the plist, runs launchctl) — call off the main thread.
    func ensureRunning() {
        guard Self.isAvailable else { return }
        if isHealthy() { return }
        lock.lock()
        defer { lock.unlock() }
        // Already kicked it off (it's loading, or launchd is keeping it alive).
        if startAttempted { return }

        writePlist()

        let uid = getuid()
        let plist = Self.plistPath
        // bootout (ok if not currently loaded) then bootstrap → (re)loads the plist.
        let out = Process(); out.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        out.arguments = ["bootout", "gui/\(uid)/\(Self.launchLabel)"]
        out.standardOutput = FileHandle.nullDevice
        out.standardError = FileHandle.nullDevice
        try? out.run(); out.waitUntilExit()

        // Ensure the service is enabled (a prior uninstall can disable it).
        let en = Process(); en.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        en.arguments = ["enable", "gui/\(uid)/\(Self.launchLabel)"]
        en.standardOutput = FileHandle.nullDevice
        en.standardError = FileHandle.nullDevice
        try? en.run(); en.waitUntilExit()

        let boot = Process(); boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        boot.arguments = ["bootstrap", "gui/\(uid)", plist]
        boot.standardOutput = FileHandle.nullDevice
        boot.standardError = FileHandle.nullDevice
        try? boot.run(); boot.waitUntilExit()

        startAttempted = true
    }

    /// Write the launchd plist for the vision server. ProgramArguments mirror the
    /// VALIDATED command:
    ///   llama-server -m <model> --mmproj <mmproj> --port 10820 -ngl 99 -c 8192 --jinja
    private func writePlist() {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        let llamaServerPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server")
            ? "/opt/homebrew/bin/llama-server"
            : "/usr/local/bin/llama-server"
        // XML-escape the embedded paths (defense-in-depth; the home dir could in
        // principle contain a stray `<`, `&`, or quote).
        let modelPath = Self.xmlEscape(Self.modelPath)
        let mmprojPath = Self.xmlEscape(Self.mmprojPath)

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(Self.launchLabel)</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(llamaServerPath)</string>
        <string>-m</string>
        <string>\(modelPath)</string>
        <string>--mmproj</string>
        <string>\(mmprojPath)</string>
        <string>--port</string>
        <string>\(Self.port)</string>
        <string>-ngl</string>
        <string>99</string>
        <string>-c</string>
        <string>8192</string>
        <string>--jinja</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-llama-vision.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-llama-vision.log</string>
</dict>
</plist>
"""
        try? plistContent.write(toFile: Self.plistPath, atomically: true, encoding: .utf8)
    }

    private static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
