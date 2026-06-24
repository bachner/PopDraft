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
