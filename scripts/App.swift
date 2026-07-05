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

// MARK: - Dependency Manager

class DependencyManager {
    static let shared = DependencyManager()

    var currentInstallProcess: Process?
    var installCancelled = false

    var ttsVenvPython: String {
        NSString(string: "~/.popdraft/tts-venv/bin/python3").expandingTildeInPath
    }

    func cancelInstall() {
        installCancelled = true
        currentInstallProcess?.terminate()
    }

    struct DependencyStatus {
        var hasHomebrew: Bool = false
        var hasEspeak: Bool = false
        var hasPythonPackages: Bool = false
        var hasLlamaCpp: Bool = false
        var hasLlamaModel: Bool = false
        var isLlamaServerRunning: Bool = false
    }

    // Get current model from config
    func getCurrentModel() -> LLMConfig.LlamaModel {
        let config = LLMConfig.load()
        return LLMConfig.llamaModels.first { $0.id == config.llamaModel } ?? LLMConfig.llamaModels[0]
    }

    // Get model by ID
    func getModel(byId id: String) -> LLMConfig.LlamaModel? {
        return LLMConfig.llamaModels.first { $0.id == id }
    }

    // Check if a specific model is downloaded
    func isModelDownloaded(_ modelId: String) -> Bool {
        guard let model = getModel(byId: modelId) else { return false }
        let modelPath = NSString(string: "~/.popdraft/models/\(model.filename)").expandingTildeInPath
        return FileManager.default.fileExists(atPath: modelPath)
    }

    func checkDependencies() -> DependencyStatus {
        var status = DependencyStatus()

        // Check Homebrew
        status.hasHomebrew = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
                            FileManager.default.fileExists(atPath: "/usr/local/bin/brew")

        // Check espeak-ng
        status.hasEspeak = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/espeak-ng") ||
                          FileManager.default.fileExists(atPath: "/usr/local/bin/espeak-ng") ||
                          FileManager.default.fileExists(atPath: "/usr/bin/espeak")

        // Check Python packages (in venv)
        let checkScript = "\(ttsVenvPython) -c 'import kokoro; import soundfile; import numpy' 2>/dev/null && echo OK"
        let result = runShellCommand(checkScript)
        status.hasPythonPackages = result.contains("OK")

        // Check llama.cpp
        status.hasLlamaCpp = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server") ||
                            FileManager.default.fileExists(atPath: "/usr/local/bin/llama-server")

        // Check for configured model
        let currentModel = getCurrentModel()
        let modelPath = NSString(string: "~/.popdraft/models/\(currentModel.filename)").expandingTildeInPath
        status.hasLlamaModel = FileManager.default.fileExists(atPath: modelPath)

        // Check if server is running
        let config = LLMConfig.load()
        let healthCheck = runShellCommand("curl -s \(config.llamacppURL)/health 2>/dev/null")
        status.isLlamaServerRunning = healthCheck.contains("ok") || healthCheck.contains("OK")

        return status
    }

    func installDependencies(statusCallback: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.installCancelled = false
            var success = true

            // Check current status
            let status = self.checkDependencies()

            // Install espeak-ng if missing (and homebrew available)
            if !status.hasEspeak && status.hasHomebrew {
                DispatchQueue.main.async { statusCallback("Installing espeak-ng...") }
                let result = self.runShellCommand("/opt/homebrew/bin/brew install espeak-ng 2>&1 || /usr/local/bin/brew install espeak-ng 2>&1", timeout: 300, trackProcess: true)
                if self.installCancelled { return }
                if result.contains("Error") {
                    print("espeak-ng install warning: \(result)")
                }
            }

            // Install Python packages into venv if missing
            if !status.hasPythonPackages {
                DispatchQueue.main.async { statusCallback("Creating Python environment...") }
                let venvDir = NSString(string: "~/.popdraft/tts-venv").expandingTildeInPath
                // Remove old venv to avoid issues with corrupted/partial venvs on Python 3.9
                try? FileManager.default.removeItem(atPath: venvDir)
                let venvResult = self.runShellCommand("python3 -m venv \"\(venvDir)\" 2>&1", timeout: 120, trackProcess: true)
                if self.installCancelled { return }
                if venvResult.contains("Error") {
                    print("venv creation warning: \(venvResult)")
                    success = false
                } else {
                    DispatchQueue.main.async { statusCallback("Installing TTS packages (this may take a few minutes)...") }
                    let pipPath = venvDir + "/bin/pip"
                    let result = self.runShellCommand("\"\(pipPath)\" install --quiet kokoro soundfile numpy 2>&1", timeout: 600, trackProcess: true)
                    if self.installCancelled { return }
                    if result.contains("ERROR") {
                        print("pip install warning: \(result)")
                        success = false
                    }
                }
            }

            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    func installLlamaCpp(modelId: String? = nil, statusCallback: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var status = self.checkDependencies()

            // Get the model to install (use provided ID or current config)
            let model: LLMConfig.LlamaModel
            if let modelId = modelId, let m = self.getModel(byId: modelId) {
                model = m
            } else {
                model = self.getCurrentModel()
            }

            // Install llama.cpp if missing
            if !status.hasLlamaCpp && status.hasHomebrew {
                DispatchQueue.main.async { statusCallback("Installing llama.cpp (this may take a few minutes)...") }
                let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
                let result = self.runShellCommand("\(brewPath) install llama.cpp 2>&1")
                if result.contains("Error") && !result.contains("already installed") {
                    print("llama.cpp install warning: \(result)")
                }
                status = self.checkDependencies()
            }

            // Download model if missing
            let modelPath = NSString(string: "~/.popdraft/models/\(model.filename)").expandingTildeInPath
            if !FileManager.default.fileExists(atPath: modelPath) {
                let modelsDir = NSString(string: "~/.popdraft/models").expandingTildeInPath
                try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)

                // Get expected file size from model (parse from size string like "~2.5GB")
                let expectedSize: Int64
                if model.size.contains("5GB") {
                    expectedSize = 5_000_000_000
                } else if model.size.contains("2.5GB") {
                    expectedSize = 2_500_000_000
                } else if model.size.contains("1.5GB") {
                    expectedSize = 1_500_000_000
                } else {
                    expectedSize = 2_500_000_000 // default
                }

                DispatchQueue.main.async { statusCallback("Downloading \(model.name) (0%)...") }

                // Start curl in background
                let curlProcess = Process()
                curlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curlProcess.arguments = ["-L", "-o", modelPath, model.url]
                curlProcess.standardOutput = FileHandle.nullDevice
                curlProcess.standardError = FileHandle.nullDevice
                try? curlProcess.run()

                // Monitor progress
                while curlProcess.isRunning {
                    Thread.sleep(forTimeInterval: 1.0)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
                       let fileSize = attrs[.size] as? Int64 {
                        let percent = min(99, Int((Double(fileSize) / Double(expectedSize)) * 100))
                        let downloadedMB = fileSize / 1_000_000
                        DispatchQueue.main.async {
                            statusCallback("Downloading \(model.name) (\(percent)% - \(downloadedMB)MB)...")
                        }
                    }
                }

                if curlProcess.terminationStatus != 0 {
                    DispatchQueue.main.async {
                        statusCallback("Download failed (error \(curlProcess.terminationStatus)). Check internet connection.")
                    }
                    Thread.sleep(forTimeInterval: 3.0)
                } else {
                    // Verify file was downloaded completely
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: modelPath),
                       let fileSize = attrs[.size] as? Int64, fileSize < 100_000_000 {
                        // File too small, likely an error page or incomplete
                        try? FileManager.default.removeItem(atPath: modelPath)
                        DispatchQueue.main.async {
                            statusCallback("Download failed - file incomplete. Please try again.")
                        }
                        Thread.sleep(forTimeInterval: 3.0)
                    }
                }
                status = self.checkDependencies()
            }

            // Create LaunchAgent for llama-server
            if status.hasLlamaCpp {
                DispatchQueue.main.async { statusCallback("Configuring llama server...") }
                self.createLlamaLaunchAgent(model: model)

                // Unload existing agent if any
                _ = self.runShellCommand("launchctl unload ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>&1")

                // Start the server
                DispatchQueue.main.async { statusCallback("Starting llama server...") }
                _ = self.runShellCommand("launchctl load ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>&1")

                // Wait a moment for server to start
                Thread.sleep(forTimeInterval: 2.0)
            }

            DispatchQueue.main.async {
                let modelExists = FileManager.default.fileExists(atPath: modelPath)
                completion(status.hasLlamaCpp && modelExists)
            }
        }
    }

    /// Escape the five XML special characters so a value can be safely embedded
    /// inside a plist `<string>` element.
    static func xmlEscape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func createLlamaLaunchAgent(model: LLMConfig.LlamaModel? = nil) {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        let selectedModel = model ?? getCurrentModel()
        // XML-escape the path before embedding it in the plist (defense-in-depth against
        // a stray `<`, `&`, or quote in a model filename). PR3 also validates HF filenames
        // up front, but the legacy download path reaches here too.
        let rawModelPath = NSString(string: "~/.popdraft/models/\(selectedModel.filename)").expandingTildeInPath
        let modelPath = Self.xmlEscape(rawModelPath)
        let llamaServerPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/llama-server")
            ? "/opt/homebrew/bin/llama-server"
            : "/usr/local/bin/llama-server"

        let config = LLMConfig.load()
        let port = URLComponents(string: config.llamacppURL)?.port ?? 10819

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.popdraft.llama-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(llamaServerPath)</string>
        <string>-m</string>
        <string>\(modelPath)</string>
        <string>--port</string>
        <string>\(port)</string>
        <string>-ngl</string>
        <string>99</string>
        <string>-np</string>
        <string>1</string>
        <string>--jinja</string>
        <string>-fa</string>
        <string>on</string>
        <string>-ctk</string>
        <string>q4_0</string>
        <string>-ctv</string>
        <string>q4_0</string>
        <string>-c</string>
        <string>131072</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-llama-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-llama-server.log</string>
</dict>
</plist>
"""
        let plistPath = launchAgentsDir + "/com.popdraft.llama-server.plist"
        try? plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    // Public method to update LaunchAgent for a specific model (used by Settings)
    func createLlamaLaunchAgentForModel(_ model: LLMConfig.LlamaModel) {
        createLlamaLaunchAgent(model: model)
    }

    /// Switch the local llama.cpp model live: rewrite the LaunchAgent plist for the
    /// new model, then bootout+bootstrap so llama-server reloads with it. Used by
    /// the in-chat model switcher so the user can change local models without
    /// opening Settings. The server takes a few seconds to reload the new weights.
    func switchLocalModelAndRestart(_ model: LLMConfig.LlamaModel) {
        createLlamaLaunchAgent(model: model)
        let uid = getuid()
        let plist = NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath
        // bootout (ok if not currently loaded) then bootstrap → reloads the plist.
        let out = Process(); out.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        out.arguments = ["bootout", "gui/\(uid)/com.popdraft.llama-server"]
        try? out.run(); out.waitUntilExit()
        let boot = Process(); boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        boot.arguments = ["bootstrap", "gui/\(uid)", plist]
        try? boot.run(); boot.waitUntilExit()
    }

    private func runShellCommand(_ command: String, timeout: TimeInterval = 0, trackProcess: Bool = false) -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        if trackProcess {
            currentInstallProcess = process
        }

        do {
            try process.run()
        } catch {
            if trackProcess { currentInstallProcess = nil }
            return "Error: \(error)"
        }

        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if installCancelled {
                    process.terminate()
                    if trackProcess { currentInstallProcess = nil }
                    return "Error: Cancelled"
                }
                if Date() > deadline {
                    process.terminate()
                    if trackProcess { currentInstallProcess = nil }
                    return "Error: Timed out after \(Int(timeout))s"
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else {
            process.waitUntilExit()
        }

        if trackProcess { currentInstallProcess = nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Update Manager

class UpdateManager: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    private(set) var updateAvailable = false
    private(set) var latestVersion: String?
    private(set) var downloadURL: String?
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0
    var onUpdateStatusChanged: (() -> Void)?

    private let githubAPI = "https://api.github.com/repos/bachner/PopDraft/releases/latest"
    private let configDir = NSString(string: "~/.popdraft").expandingTildeInPath
    private var downloadTask: URLSessionDownloadTask?

    // MARK: - Check for updates

    func checkOnLaunchIfNeeded() {
        let checkFile = "\(configDir)/update_check"
        if let data = FileManager.default.contents(atPath: checkFile),
           let timestamp = String(data: data, encoding: .utf8).flatMap(Double.init) {
            let lastCheck = Date(timeIntervalSince1970: timestamp)
            if Date().timeIntervalSince(lastCheck) < 86400 { return }
        }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool) {
        guard let url = URL(string: githubAPI) else { return }

        var request = URLRequest(url: url)
        request.setValue("PopDraft/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Save check timestamp
            let checkFile = "\(self.configDir)/update_check"
            try? "\(Date().timeIntervalSince1970)".write(toFile: checkFile, atomically: true, encoding: .utf8)

            if let error = error {
                Logger.shared.error("Update check failed: \(error.localizedDescription)")
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "Update Check Failed", message: "Could not connect to GitHub. Please check your internet connection.") }
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "Update Check Failed", message: "Could not parse update information.") }
                }
                return
            }

            // Find DMG asset URL
            var dmgURL: String?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let url = asset["browser_download_url"] as? String {
                        dmgURL = url
                        break
                    }
                }
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            if self.isNewerVersion(remoteVersion, than: AppVersion.current) {
                self.updateAvailable = true
                self.latestVersion = remoteVersion
                self.downloadURL = dmgURL
                Logger.shared.info("Update available: v\(remoteVersion)")
                DispatchQueue.main.async { self.onUpdateStatusChanged?() }
                if silent {
                    DispatchQueue.main.async { self.downloadAndInstall() }
                }
            } else {
                self.updateAvailable = false
                self.latestVersion = nil
                self.downloadURL = nil
                if !silent {
                    DispatchQueue.main.async { self.showAlert(title: "You're Up to Date", message: "PopDraft \(AppVersion.current) is the latest version.") }
                }
            }
        }.resume()
    }

    // MARK: - Version comparison

    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        // Dev builds always count as older
        if local.hasPrefix("dev-") { return true }

        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, localParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    // MARK: - Download and install

    func downloadAndInstall() {
        guard let urlString = downloadURL, let url = URL(string: urlString) else {
            showAlert(title: "Update Error", message: "No download URL available.")
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        onUpdateStatusChanged?()

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
        Logger.shared.info("Downloading update from \(urlString)")
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onUpdateStatusChanged?()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dmgPath = "/tmp/PopDraft-update.dmg"
        let dmgURL = URL(fileURLWithPath: dmgPath)

        do {
            // Remove any existing file
            try? FileManager.default.removeItem(at: dmgURL)
            try FileManager.default.moveItem(at: location, to: dmgURL)
            Logger.shared.info("Download complete: \(dmgPath)")
            installFromDMG(at: dmgPath)
        } catch {
            Logger.shared.error("Failed to save DMG: \(error)")
            isDownloading = false
            onUpdateStatusChanged?()
            showAlert(title: "Update Error", message: "Failed to save download: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Logger.shared.error("Download failed: \(error.localizedDescription)")
            isDownloading = false
            downloadProgress = 0
            onUpdateStatusChanged?()
            showAlert(title: "Download Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Install from DMG

    private func installFromDMG(at dmgPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let mountPoint = "/tmp/PopDraft-mount"

            // Detach any stale mount
            let detachStale = Process()
            detachStale.launchPath = "/usr/bin/hdiutil"
            detachStale.arguments = ["detach", mountPoint, "-quiet", "-force"]
            detachStale.standardOutput = FileHandle.nullDevice
            detachStale.standardError = FileHandle.nullDevice
            try? detachStale.run()
            detachStale.waitUntilExit()

            // Mount DMG
            let mount = Process()
            mount.launchPath = "/usr/bin/hdiutil"
            mount.arguments = ["attach", dmgPath, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
            mount.standardOutput = FileHandle.nullDevice
            mount.standardError = FileHandle.nullDevice

            do {
                try mount.run()
                mount.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to mount DMG: \(error.localizedDescription)")
                }
                return
            }

            guard mount.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to mount DMG (exit code \(mount.terminationStatus)).")
                }
                return
            }

            // Find .app in mount
            let appSource = "\(mountPoint)/PopDraft.app"
            guard FileManager.default.fileExists(atPath: appSource) else {
                // Unmount and fail
                let unmount = Process()
                unmount.launchPath = "/usr/bin/hdiutil"
                unmount.arguments = ["detach", mountPoint, "-quiet"]
                unmount.standardOutput = FileHandle.nullDevice
                unmount.standardError = FileHandle.nullDevice
                try? unmount.run()
                unmount.waitUntilExit()

                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "PopDraft.app not found in DMG.")
                }
                return
            }

            let appDest = "/Applications/PopDraft.app"

            do {
                // Remove old app
                if FileManager.default.fileExists(atPath: appDest) {
                    try FileManager.default.removeItem(atPath: appDest)
                }
                // Copy new app
                try FileManager.default.copyItem(atPath: appSource, toPath: appDest)

                // Clear quarantine
                let xattr = Process()
                xattr.launchPath = "/usr/bin/xattr"
                xattr.arguments = ["-cr", appDest]
                xattr.standardOutput = FileHandle.nullDevice
                xattr.standardError = FileHandle.nullDevice
                try? xattr.run()
                xattr.waitUntilExit()

                Logger.shared.info("Updated app installed to \(appDest)")
            } catch {
                Logger.shared.error("Failed to install update: \(error)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.onUpdateStatusChanged?()
                    self.showAlert(title: "Update Error", message: "Failed to install: \(error.localizedDescription)")
                }
                // Still unmount
                let unmount = Process()
                unmount.launchPath = "/usr/bin/hdiutil"
                unmount.arguments = ["detach", mountPoint, "-quiet"]
                unmount.standardOutput = FileHandle.nullDevice
                unmount.standardError = FileHandle.nullDevice
                try? unmount.run()
                unmount.waitUntilExit()
                return
            }

            // Unmount DMG
            let unmount = Process()
            unmount.launchPath = "/usr/bin/hdiutil"
            unmount.arguments = ["detach", mountPoint, "-quiet"]
            unmount.standardOutput = FileHandle.nullDevice
            unmount.standardError = FileHandle.nullDevice
            try? unmount.run()
            unmount.waitUntilExit()

            // Cleanup
            try? FileManager.default.removeItem(atPath: dmgPath)

            // Relaunch
            DispatchQueue.main.async {
                self.relaunchApp()
            }
        }
    }

    // MARK: - Relaunch

    private func relaunchApp() {
        let appPath = "/Applications/PopDraft.app"
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; killall PopDraft 2>/dev/null; sleep 0.5; open \"\(appPath)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        Logger.shared.info("Relaunching PopDraft...")
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = title.contains("Error") || title.contains("Failed") ? .warning : .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Launch at Login Manager

class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let launchAgentPath: String
    private let bundleIdentifier = "com.popdraft.app"

    init() {
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        launchAgentPath = "\(launchAgentsDir)/\(bundleIdentifier).plist"
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            createLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private func createLaunchAgent() {
        // Get the app bundle path
        let appPath = Bundle.main.bundlePath

        // Create LaunchAgents directory if needed
        let launchAgentsDir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        // Create plist content
        let plistContent: [String: Any] = [
            "Label": bundleIdentifier,
            "ProgramArguments": [appPath + "/Contents/MacOS/PopDraft"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        // Write plist
        let plistData = try? PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try? plistData?.write(to: URL(fileURLWithPath: launchAgentPath))

        print("Launch at Login enabled: \(launchAgentPath)")
    }

    private func removeLaunchAgent() {
        try? FileManager.default.removeItem(atPath: launchAgentPath)
        print("Launch at Login disabled")
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var popupController: PopupWindowController?
    var bubbleController: BubbleWindowController?
    var settingsController: SettingsWindowController?
    var historyController: HistoryWindowController?
    var onboardingController: OnboardingWindowController?
    var updateMenuItem: NSMenuItem?
    var serverStatusMenuItem: NSMenuItem?

    /// PR5: "Recent" submenu listing recently saved sessions. Rebuilt lazily each
    /// time the menu is about to open (so newly saved sessions appear).
    private var recentMenuItem: NSMenuItem?
    private let sessionStore = SessionStore(
        dir: NSString(string: "~/.popdraft").expandingTildeInPath
    )

    private var isOnboardingComplete: Bool {
        let path = NSString(string: "~/.popdraft/onboarding_complete").expandingTildeInPath
        return FileManager.default.fileExists(atPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create Edit menu for standard text editing commands
        setupEditMenu()

        // Check if onboarding needed
        if !isOnboardingComplete {
            showOnboarding()
            return
        }

        // Normal startup
        completeStartup()
    }

    private func showOnboarding() {
        onboardingController = OnboardingWindowController(onComplete: { [weak self] in
            self?.onboardingController = nil
            self?.completeStartup()
        })
        onboardingController?.showWindow()
    }

    private func completeStartup() {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Bespoke code-drawn template glyph (orb + sparkle) that adapts to
            // light/dark menu bars. Fall back to the SF Symbol only if drawing
            // somehow returns nil.
            if let glyph = MenuBarGlyph.template() {
                button.image = glyph
            } else {
                button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "PopDraft")
                button.image?.isTemplate = true
            }
        }

        // Create menu
        let menu = NSMenu()
        menu.delegate = self  // rebuild the Recent submenu each time the menu opens
        menu.addItem(NSMenuItem(title: "Show Popup", action: #selector(showPopup), keyEquivalent: ""))

        // PR5: Recent sessions submenu. Populated lazily in menuNeedsUpdate(_:).
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu(title: "Recent")
        menu.addItem(recentItem)
        recentMenuItem = recentItem

        menu.addItem(NSMenuItem(title: "Browse History…", action: #selector(browseHistory), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        let statusMenuItem = NSMenuItem(title: "llama.cpp: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        serverStatusMenuItem = statusMenuItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About PopDraft", action: #selector(showAbout), keyEquivalent: ""))
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        menu.addItem(updateItem)
        updateMenuItem = updateItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = menu

        // Create controllers
        popupController = PopupWindowController()
        settingsController = SettingsWindowController()
        historyController = HistoryWindowController()

        // PR4: persistent corner bubble. Clicking it expands into the panel at
        // the cursor (same path as the hotkey). The popup minimizes the bubble
        // while it's open and restores it on dismiss/copy — but ONLY when the
        // bubble is enabled, so the disabled case is byte-for-byte today's flow.
        bubbleController = BubbleWindowController()
        bubbleController?.onExpand = { [weak self] in
            // Clicking the orb opens the agent chat directly (the hotkey is the
            // action-menu entry point; the bubble is the chat one).
            self?.popupController?.showChat()
        }
        popupController?.onWillShow = { [weak self] in
            // Hide the orb while the expanded panel is open.
            if self?.isBubbleEnabled == true { self?.bubbleController?.hide() }
        }
        popupController?.onDidDismiss = { [weak self] in
            // Restore the orb to its corner once the panel closes.
            if self?.isBubbleEnabled == true { self?.bubbleController?.show() }
        }
        if isBubbleEnabled {
            bubbleController?.show()
        }

        // Start TTS server if needed
        TTSServerManager.shared.ensureRunning()

        // PR6: compile the web engine's content-blocking rules once at startup
        // (cached by WebKit). The engine itself is lazy; this just primes it.
        Task { @MainActor in await WebEngine.shared.warmUp() }

        // Ensure llama.cpp server is running if configured
        let config = LLMConfig.load()
        if config.provider == .llamacpp {
            let plistPath = NSString(string: "~/Library/LaunchAgents/com.popdraft.llama-server.plist").expandingTildeInPath
            if FileManager.default.fileExists(atPath: plistPath) {
                DispatchQueue.global(qos: .utility).async {
                    let uid = getuid()
                    // Ensure service is enabled
                    let enableProcess = Process()
                    enableProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    enableProcess.arguments = ["enable", "gui/\(uid)/com.popdraft.llama-server"]
                    enableProcess.standardOutput = FileHandle.nullDevice
                    enableProcess.standardError = FileHandle.nullDevice
                    try? enableProcess.run()
                    enableProcess.waitUntilExit()

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["bootstrap", "gui/\(uid)", plistPath]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try? process.run()
                    process.waitUntilExit()
                }
            }

            // Ensure llama.cpp is up to date for newer models
            DispatchQueue.global(qos: .background).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
                process.arguments = ["upgrade", "llama.cpp"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }

        // Start llama.cpp server monitoring
        if config.provider == .llamacpp {
            LlamaServerManager.shared.onStatusChanged = { [weak self] status in
                self?.updateServerStatusMenuItem(status)
            }
            LlamaServerManager.shared.startPolling()
        } else {
            serverStatusMenuItem?.isHidden = true
        }

        // Register all global hotkeys
        HotkeyManager.shared.registerAll()

        Logger.shared.info("PopDraft \(AppVersion.current) started. Press Option+Space to show popup.")

        // Enable launch at login on first run
        let loginFlag = NSString(string: "~/.popdraft/login_configured").expandingTildeInPath
        if !FileManager.default.fileExists(atPath: loginFlag) {
            LaunchAtLoginManager.shared.setEnabled(true)
            FileManager.default.createFile(atPath: loginFlag, contents: nil)
        }

        // Set up update manager
        UpdateManager.shared.onUpdateStatusChanged = { [weak self] in
            self?.refreshUpdateMenuItem()
        }
        UpdateManager.shared.checkOnLaunchIfNeeded()

        // Monitor accessibility permission periodically
        var wasAccessible = AXIsProcessTrusted()
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            let isAccessible = AXIsProcessTrusted()
            if wasAccessible && !isAccessible {
                Logger.shared.error("Accessibility permission was revoked")
                let script = """
                display notification "PopDraft needs Accessibility permission to capture text. Please re-enable it in System Settings > Privacy & Security > Accessibility." with title "PopDraft: Accessibility Permission Lost"
                """
                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]
                try? task.run()
            }
            wasAccessible = isAccessible
        }
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()

        // App menu (required)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit PopDraft", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregisterAll()
        TTSServerManager.shared.stopServer()
    }

    /// Whether the persistent corner bubble is enabled in config (PR4).
    private var isBubbleEnabled: Bool {
        LLMConfig.load().bubble.enabled
    }

    /// Re-apply bubble settings after the user changes them in Settings: show or
    /// hide the orb and re-pin it to the (possibly new) corner.
    func refreshBubble() {
        guard let bubble = bubbleController else { return }
        if isBubbleEnabled {
            // show() re-pins to the configured corner; if already visible it just
            // re-positions (and fades in if it was hidden).
            bubble.show(animated: !bubble.isVisible)
        } else {
            bubble.hide()
        }
    }

    @objc func showPopup() {
        popupController?.showAtMouseLocation()
    }

    // MARK: - Recent sessions submenu (PR5)

    /// `NSMenuDelegate` — refresh the Recent submenu whenever the status-bar menu
    /// is about to open, so newly saved sessions show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildRecentMenu()
    }

    /// Rebuild the "Recent" submenu from the session store. Crash-safe: shows an
    /// "(No recent sessions)" placeholder when empty.
    private func rebuildRecentMenu() {
        guard let submenu = recentMenuItem?.submenu else { return }
        submenu.removeAllItems()

        let summaries = Array(sessionStore.list().prefix(10))
        if summaries.isEmpty {
            let empty = NSMenuItem(title: "No recent sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        for summary in summaries {
            let title = summary.title.isEmpty ? "Untitled" : summary.title
            let relative = AppDelegate.relativeTime(from: summary.updatedAt)
            let item = NSMenuItem(
                title: "\(title)  —  \(relative)",
                action: #selector(openRecentSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = summary.id
            submenu.addItem(item)
        }
    }

    @objc private func openRecentSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        popupController?.reopenSession(id: id)
    }

    @objc func browseHistory() {
        historyController?.showWindow()
    }

    /// Compact relative time like "just now", "5m ago", "3h ago", "2d ago".
    static func relativeTime(from epoch: Double) -> String {
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
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    func triggerAction(actionID: String) {
        Logger.shared.info("triggerAction: \(actionID) (accessibility=\(AXIsProcessTrusted()))")
        // BUG-1 fix: capturing the user's selected text relies on simulating
        // Cmd+C via CGEvent, which SILENTLY no-ops without Accessibility
        // permission. A fresh/unsigned build at the same path loses the grant, so
        // the hotkey appeared to "do nothing": capture returned empty → with the
        // bubble enabled the empty selection routed to chat (or nothing visible),
        // never the action menu. Detect the missing permission up-front and guide
        // the user instead of failing silently.
        guard AXIsProcessTrusted() else {
            Logger.shared.error("triggerAction: Accessibility NOT granted — prompting user (hotkey would otherwise do nothing)")
            promptForAccessibility()
            return
        }
        if actionID == "popup" {
            showPopup()
        } else {
            popupController?.showWithAction(actionID: actionID)
        }
    }

    /// Show a clear, actionable prompt when the global hotkey fires but
    /// Accessibility permission is missing (so the app can't read the selection
    /// or simulate Cmd+C). Triggers the system "add this app" prompt AND opens the
    /// Accessibility pane, plus an alert explaining what to do. Debounced so a
    /// repeated hotkey press doesn't stack alerts.
    private var isShowingAccessibilityPrompt = false
    func promptForAccessibility() {
        if isShowingAccessibilityPrompt { return }
        isShowingAccessibilityPrompt = true

        // Ask macOS to surface THIS binary in the Accessibility list.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "PopDraft needs Accessibility permission"
        alert.informativeText = "To read your selected text and show the action menu, "
            + "PopDraft needs Accessibility access.\n\n"
            + "Open System Settings → Privacy & Security → Accessibility, then enable "
            + "PopDraft (toggle it off and on again if it's already listed — a new build "
            + "can lose the grant). Then press the hotkey again."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.activate()
                }
            }
        }
        isShowingAccessibilityPrompt = false
    }

    @objc func showSettings() {
        settingsController?.showWindow()
    }

    private func updateServerStatusMenuItem(_ status: LlamaServerManager.Status) {
        switch status {
        case .online:
            serverStatusMenuItem?.title = "llama.cpp: Online"
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Online")
            serverStatusMenuItem?.image?.isTemplate = false
        case .loading:
            serverStatusMenuItem?.title = "llama.cpp: Loading Model..."
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Loading")
            serverStatusMenuItem?.image?.isTemplate = false
        case .offline:
            serverStatusMenuItem?.title = "llama.cpp: Offline"
            serverStatusMenuItem?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Offline")
            serverStatusMenuItem?.image?.isTemplate = false
        case .unknown:
            serverStatusMenuItem?.title = "llama.cpp: Checking..."
            serverStatusMenuItem?.image = nil
        }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PopDraft"
        alert.informativeText = "Version: \(AppVersion.current)\n\nSystem-wide AI text processing for macOS.\n\nUsage:\n1. Select text in any app\n2. Press Option+Space\n3. Select an action\n4. Review result and Copy\n\nProvider: \(LLMClient.shared.providerName)\nModel: \(LLMClient.shared.currentModel)\n\nBuilt by Ofer Bachner"
        // Use the bespoke brand orb when bundled; nil-safe (falls back to the
        // app's default icon when running as a bare source-install binary).
        if let icon = AppAssets.appIconImage {
            alert.icon = icon
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func checkForUpdatesMenu() {
        let mgr = UpdateManager.shared
        if mgr.updateAvailable && !mgr.isDownloading {
            let alert = NSAlert()
            alert.messageText = "Update Available"
            alert.informativeText = "PopDraft v\(mgr.latestVersion ?? "?") is available. You have v\(AppVersion.current).\n\nDownload and install now?"
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                mgr.downloadAndInstall()
            }
        } else if !mgr.isDownloading {
            mgr.checkForUpdates(silent: false)
        }
    }

    private func refreshUpdateMenuItem() {
        let mgr = UpdateManager.shared
        if mgr.isDownloading {
            let pct = Int(mgr.downloadProgress * 100)
            updateMenuItem?.title = "Downloading Update... \(pct)%"
            updateMenuItem?.action = nil
        } else if mgr.updateAvailable {
            updateMenuItem?.title = "Update Available: v\(mgr.latestVersion ?? "")"
            updateMenuItem?.action = #selector(checkForUpdatesMenu)
        } else {
            updateMenuItem?.title = "Check for Updates..."
            updateMenuItem?.action = #selector(checkForUpdatesMenu)
        }

        // Status bar dot indicator
        if let button = statusItem?.button {
            button.title = mgr.updateAvailable ? "·" : ""
        }
    }
}

// =====================================================================
