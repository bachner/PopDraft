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

// MARK: - Owned background processes (live side of the pure matchers in Core)

/// Finds and stops background processes PopDraft itself started (a leftover
/// llama-server, the retired TTS server). Matching is delegated to the pure,
/// unit-tested predicates in Core.swift (`LocalServerPolicy.isOwnedServer`,
/// `LegacyTTSServer.isServer`) and is always restricted to this user's processes.
enum OwnedProcesses {
    /// PIDs of this user's processes whose command line satisfies `matches`. BLOCKS (runs ps).
    static func pids(where matches: (String) -> Bool) -> [Int32] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,uid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return ProcessTable.pids(in: ProcessTable.parse(output), uid: getuid(), selfPID: getpid(), where: matches)
    }

    /// The command line of `pid` if it's one of this user's processes. BLOCKS.
    static func command(of pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ww", "-o", "pid=,uid=,command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return ProcessTable.parse(output).first { $0.pid == pid && $0.uid == getuid() }?.command
    }

    /// SIGTERM, then SIGKILL whatever is still alive after `grace` seconds. BLOCKS.
    static func terminate(_ pids: [Int32], grace: TimeInterval = 3) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

// MARK: - Llama Server Manager

class LlamaServerManager {
    static let shared = LlamaServerManager()

    enum Status {
        case unknown, online, loading, offline
    }

    /// launchd job of the main local server (plist written by
    /// `DependencyManager.createLlamaLaunchAgent`; it has RunAtLoad + KeepAlive).
    static let launchLabel = "com.popdraft.llama-server"
    static var plistPath: String {
        NSString(string: "~/Library/LaunchAgents/\(launchLabel).plist").expandingTildeInPath
    }

    /// Whether the local server may run at all right now: ONLY while the saved
    /// provider is llama.cpp (`LocalServerPolicy`). Every start path checks this.
    static var isActiveProvider: Bool {
        LocalServerPolicy.shouldRun(provider: LLMConfig.load().provider.rawValue)
    }

    /// Bring the local server in line with `provider` — at startup and whenever
    /// the active provider changes. llama.cpp: status polling + start the launchd
    /// service (skipped with `startServer: false` when the caller is about to
    /// restart it on a new model itself). Anything else: stop polling and stop
    /// the server, so no local model sits in memory.
    func applyProvider(_ provider: LLMConfig.Provider, startServer: Bool = true) {
        if LocalServerPolicy.shouldRun(provider: provider.rawValue) {
            startPolling()
            if startServer {
                lifecycleQueue.async { Self.startService() }
            }
        } else {
            stopPolling()
            lifecycleQueue.async { Self.stopOwnedServer() }
        }
    }

    /// Serializes start/stop so a quick provider flip can't interleave them; each
    /// step re-reads the SAVED provider, so the latest choice wins.
    private let lifecycleQueue = DispatchQueue(label: "com.popdraft.llama-lifecycle", qos: .utility)

    /// enable + bootstrap the launchd service (a no-op if it's already loaded).
    /// Does nothing unless the provider is llama.cpp and the plist exists. BLOCKS.
    static func startService() {
        guard isActiveProvider, FileManager.default.fileExists(atPath: plistPath) else { return }
        launchctl(["enable", "gui/\(getuid())/\(launchLabel)"])
        launchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    /// Stop PopDraft's local llama-server and KEEP it stopped: boot the launchd
    /// job out, then `disable` it — its plist has RunAtLoad + KeepAlive, so
    /// otherwise launchd starts the model again at the next login whatever the
    /// provider (the "Ollama configured, llama-server still resident" bug). Then
    /// stop any leftover llama-server PopDraft owns (our port or models dir —
    /// never anyone else's). The plist stays: it records the chosen local model,
    /// and switching back to llama.cpp re-enables it. BLOCKS.
    static func stopOwnedServer() {
        // Switched back to llama.cpp before this ran? Then there's nothing to stop.
        guard !isActiveProvider else { return }
        launchctl(["bootout", "gui/\(getuid())/\(launchLabel)"])
        launchctl(["disable", "gui/\(getuid())/\(launchLabel)"])
        let home = NSHomeDirectory()
        let pids = OwnedProcesses.pids { LocalServerPolicy.isOwnedServer(command: $0, home: home) }
        if !pids.isEmpty {
            OwnedProcesses.terminate(pids)
            Logger.shared.info("Stopped local llama-server (provider isn't llama.cpp): pids \(pids)")
        }
    }

    /// Run `launchctl` quietly and wait for it. BLOCKS.
    static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
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
        // Never (re)start a local model for another provider — this also covers
        // the agent's auto-restart-on-refused-socket path.
        guard LocalServerPolicy.shouldRun(provider: config.provider.rawValue) else {
            Logger.shared.info("llama-server restart skipped: provider is \(config.provider.rawValue)")
            completion(false)
            return
        }
        let plistPath = Self.plistPath

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

    /// One-time teardown of the dedicated vision service: `see_image` now runs
    /// on the ACTIVE model, so a resident :10820 VL server is pure RAM/boot cost
    /// with zero consumers. Boots the launchd job out and removes its plist —
    /// the model FILES under ~/.popdraft/models are the user's and stay put.
    /// Idempotent (the plist is the marker: gone ⇒ already torn down). BLOCKS
    /// (runs launchctl) — call off the main thread.
    func teardown() {
        guard FileManager.default.fileExists(atPath: Self.plistPath) else { return }
        let out = Process(); out.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        out.arguments = ["bootout", "gui/\(getuid())/\(Self.launchLabel)"]
        out.standardOutput = FileHandle.nullDevice
        out.standardError = FileHandle.nullDevice
        try? out.run(); out.waitUntilExit()
        try? FileManager.default.removeItem(atPath: Self.plistPath)
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
