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

// MARK: - TTS Client

class TTSClient {
    static let shared = TTSClient()
    private let serverURL = "http://127.0.0.1:7865"
    var isPaused = false

    func speak(text: String, voice: String? = nil, speed: Double? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        isPaused = false

        // Load config for defaults
        let config = LLMConfig.load()
        let useVoice = voice ?? config.ttsVoice
        let useSpeed = speed ?? config.ttsSpeed

        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(serverURL)/speak?text=\(encodedText)&voice=\(useVoice)&speed=\(useSpeed)&play=1") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        // Ensure TTS server is running, then speak (server may take ~30s to load model)
        TTSServerManager.shared.ensureRunning()
        waitForServer(maxAttempts: 15, interval: 2.0) { [weak self] ready in
            guard self != nil else { return }
            if !ready {
                completion(.failure(NSError(domain: "TTS server not available. It may still be loading the model.", code: -1)))
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 300  // Long timeout for TTS

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "TTS server error", code: -1)))
                }
            }.resume()
        }
    }

    private func waitForServer(maxAttempts: Int, interval: TimeInterval, attempt: Int = 0, completion: @escaping (Bool) -> Void) {
        checkHealth { [weak self] isHealthy in
            if isHealthy {
                completion(true)
            } else if attempt < maxAttempts {
                DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                    self?.waitForServer(maxAttempts: maxAttempts, interval: interval, attempt: attempt + 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/stop") else {
            completion?(false)
            return
        }
        isPaused = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            completion?(success)
        }.resume()
    }

    func pause(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/pause") else {
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            if success { self?.isPaused = true }
            completion?(success)
        }.resume()
    }

    func resume(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(serverURL)/resume") else {
            completion?(false)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            if success { self?.isPaused = false }
            completion?(success)
        }.resume()
    }

    func checkStatus(completion: @escaping (String) -> Void) {
        guard let url = URL(string: "\(serverURL)/status") else {
            completion("error")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let status = String(data: data, encoding: .utf8) {
                completion(status)
            } else {
                completion("error")
            }
        }.resume()
    }

    func checkHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(serverURL)/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }
}

// MARK: - TTS Server Manager

class TTSServerManager {
    static let shared = TTSServerManager()

    private var serverProcess: Process?
    private let serverScript = "~/.popdraft/llm-tts-server.py"
    private let serverURL = "http://127.0.0.1:7865"

    func ensureRunning() {
        // First ensure script exists
        ensureScriptExists()

        // Check if server is already running
        TTSClient.shared.checkHealth { [weak self] isHealthy in
            if !isHealthy {
                DispatchQueue.main.async {
                    self?.startServer()
                }
            }
        }
    }

    private func ensureScriptExists() {
        let destPath = NSString(string: serverScript).expandingTildeInPath
        let configDir = NSString(string: "~/.popdraft").expandingTildeInPath

        // Create config dir if needed
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)

        // If script doesn't exist, copy from bundle
        if !FileManager.default.fileExists(atPath: destPath) {
            if let bundlePath = Bundle.main.path(forResource: "llm-tts-server", ofType: "py") {
                do {
                    try FileManager.default.copyItem(atPath: bundlePath, toPath: destPath)
                    // Make executable
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
                    print("TTS server script copied from bundle to \(destPath)")
                } catch {
                    print("Failed to copy TTS server script: \(error)")
                }
            } else {
                print("TTS server script not found in bundle")
            }
        }
    }

    private let logPath = NSString(string: "~/.popdraft/tts-server.log").expandingTildeInPath

    private func startServer() {
        let expandedPath = NSString(string: serverScript).expandingTildeInPath

        // Check if script exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("TTS server script not found at: \(expandedPath)")
            return
        }

        let venvPython = NSString(string: "~/.popdraft/tts-venv/bin/python3").expandingTildeInPath
        let pythonPath = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/python3"

        // Log server output to file for debugging instead of discarding
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [expandedPath]
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            print("TTS server started with \(pythonPath) (PID: \(process.processIdentifier))")

            // Verify server health after giving it time to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self else { return }
                TTSClient.shared.checkHealth { isHealthy in
                    if !isHealthy {
                        print("TTS server failed to become healthy. Check log: \(self.logPath)")
                        if let proc = self.serverProcess, !proc.isRunning {
                            print("TTS server process exited with code: \(proc.terminationStatus)")
                        }
                    }
                }
            }
        } catch {
            print("Failed to start TTS server: \(error)")
        }
    }

    func stopServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("TTS server stopped")
        }
        serverProcess = nil
    }
}
