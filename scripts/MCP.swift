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

// MARK: - PR9: MCP client (stdio JSON-RPC subprocess)

/// A minimal but real MCP client: spawns the configured server subprocess, does
/// the 2025-06-18 handshake (`initialize` → `notifications/initialized` →
/// `tools/list`), and exposes a `call(tool:arguments:)` that forwards
/// `tools/call` over stdio. The pure wire format lives in `MCPProtocol`
/// (Core.swift); this owns the process + pipes + request/response matching.
///
/// `@unchecked Sendable`: all access is serialized through `ioQueue`; the public
/// async API is the only entry point.
final class MCPClient: @unchecked Sendable {
    let serverName: String
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let ioQueue = DispatchQueue(label: "com.popdraft.mcp.\(UUID().uuidString)")
    private var nextId = 100
    private var buffer = Data()
    private var started = false

    init(serverName: String) {
        self.serverName = serverName
    }

    /// Spawn the server and run the handshake; returns the discovered tool specs.
    /// Throws if the server can't start or doesn't answer — the caller skips it.
    /// Expand `$VAR`, `${VAR}` and a leading `~` in server args. Config stores
    /// e.g. `$HOME`, but `Process` does not run through a shell, so it would pass
    /// the literal string — expand here so e.g. the filesystem server roots at the
    /// real home directory.
    static func expandedArgs(_ args: [String]) -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let re = try? NSRegularExpression(pattern: "\\$\\{?([A-Za-z_][A-Za-z0-9_]*)\\}?")
        return args.map { arg -> String in
            var s = arg
            if s == "~" { s = home } else if s.hasPrefix("~/") { s = home + String(s.dropFirst(1)) }
            guard let re = re else { return s }
            let ns = s as NSString
            var result = s
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let name = ns.substring(with: m.range(at: 1))
                if let val = env[name] { result = (result as NSString).replacingCharacters(in: m.range, with: val) }
            }
            return result
        }
    }

    /// `timeoutMs` defaults high because `npx -y <pkg>` downloads the package on
    /// first run (often >8s) before the server can answer `initialize`.
    func start(command: String, args: [String], timeoutMs: Int = 60000) async throws -> [MCPToolSpec] {
        // Resolve the command via /usr/bin/env so a bare name (e.g. "npx") works.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.standardInput = stdin
        process.standardOutput = stdout
        // Let the server's stderr flow to our stderr/log (don't capture/block on it).
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw NSError(domain: "MCPClient", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to start MCP server '\(serverName)': \(error.localizedDescription)"])
        }
        started = true

        // initialize → wait for response → send initialized → tools/list.
        _ = try await request(MCPProtocol.initializeRequest(), expectId: 1, timeoutMs: timeoutMs)
        writeLine(MCPProtocol.initializedNotification())
        let listResp = try await request(MCPProtocol.toolsListRequest(id: 2), expectId: 2, timeoutMs: timeoutMs)
        return MCPProtocol.parseToolsList(listResp)
    }

    /// Forward a `tools/call`, returning (text, isError).
    func call(tool: String, arguments: [String: Any], timeoutMs: Int = 30000) async -> (text: String, isError: Bool) {
        guard started, process.isRunning else { return ("Error: MCP server '\(serverName)' is not running.", true) }
        let id = nextRequestId()
        do {
            let resp = try await request(
                MCPProtocol.toolsCallRequest(id: id, name: tool, arguments: arguments),
                expectId: id, timeoutMs: timeoutMs)
            return MCPProtocol.parseToolCallResult(resp)
        } catch {
            return ("Error calling MCP tool '\(tool)': \(error.localizedDescription)", true)
        }
    }

    func shutdown() {
        ioQueue.async { [process, stdin] in
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
    }

    private func nextRequestId() -> Int {
        return ioQueue.sync { nextId += 1; return nextId }
    }

    /// Write one newline-delimited JSON-RPC message.
    private func writeLine(_ data: Data) {
        ioQueue.async { [stdin] in
            var line = data
            line.append(0x0A)  // '\n'
            try? stdin.fileHandleForWriting.write(contentsOf: line)
        }
    }

    /// Hard cap on the rolling read buffer so a chatty/garbage server can't grow
    /// memory without bound while we wait for our id.
    private static let maxBufferBytes = 4 * 1024 * 1024

    /// Send a request and await the response line whose `id` matches `expectId`.
    /// Reads newline-delimited JSON-RPC from stdout, bounded by `timeoutMs`.
    ///
    /// The blocking `availableData` read is RACED against the remaining deadline
    /// (via a throwing task group) so a silent server that writes nothing and
    /// never EOFs cannot hang the call past the timeout — the deadline is
    /// authoritative.
    private func request(_ data: Data, expectId: Int, timeoutMs: Int) async throws -> Data {
        writeLine(data)
        let handle = stdout.fileHandleForReading
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        // Drain whole lines from a rolling buffer until we see our id (or time out).
        while Date() < deadline {
            if let line = try takeBufferedLine(matching: expectId) { return line }
            let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
            if remainingMs <= 0 { break }

            // Race the (blocking) read against the remaining time budget.
            let chunk: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                        self.ioQueue.async { cont.resume(returning: handle.availableData) }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
                    return nil  // deadline sentinel
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard let chunk = chunk else { break }  // deadline won the race
            if chunk.isEmpty {
                // EOF or no data yet; if the process is gone and nothing's left, stop.
                if !process.isRunning && buffer.isEmpty { break }
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            buffer.append(chunk)
            if buffer.count > Self.maxBufferBytes {
                throw NSError(domain: "MCPClient", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "MCP server '\(serverName)' response exceeded buffer cap"])
            }
        }
        throw NSError(domain: "MCPClient", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "timed out waiting for MCP response id=\(expectId)"])
    }

    /// Pull a complete newline-delimited JSON object from `buffer` whose id
    /// matches (skipping notifications / other ids), or nil if none yet.
    private func takeBufferedLine(matching expectId: Int) throws -> Data? {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let trimmed = line.trimmingTrailingWhitespace()
            if trimmed.isEmpty { continue }
            if MCPProtocol.responseId(trimmed) == expectId { return trimmed }
            // Different id or a notification — discard and keep scanning.
        }
        return nil
    }
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        var d = self
        while let last = d.last, last == 0x20 || last == 0x09 || last == 0x0D || last == 0x0A {
            d.removeLast()
        }
        return d
    }
}

/// An `AgentTool` backed by a discovered MCP tool. Forwards `invoke` to the
/// client's `tools/call`. NOT confirm-gated (MCP servers are explicit,
/// user-configured integrations), but only ever registered when the server is
/// configured + reachable.
struct MCPTool: AgentTool {
    let client: MCPClient
    let originalName: String        // the server-side tool name
    let toolSpec: ToolSpec          // namespaced spec (server__tool)
    var spec: ToolSpec { toolSpec }

    func invoke(_ args: JSONObject) async throws -> String {
        let (text, isError) = await client.call(tool: originalName, arguments: args.dictionary)
        if isError {
            // Surface as a thrown error so ToolRunner marks the result isError,
            // letting the model adapt — same contract as the other tools.
            throw NSError(domain: "MCPTool", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}

/// Spawns every configured+enabled MCP server, runs the handshake, and returns
/// the discovered `AgentTool`s. A server that fails to start/handshake is
/// skipped + logged (never crashes the agent). The live clients are returned so
/// the caller can shut them down when the turn ends.
@MainActor
enum MCPManager {
    static func buildTools(servers: [MCPServerConfig]) async -> (tools: [any AgentTool], clients: [MCPClient]) {
        var tools: [any AgentTool] = []
        var clients: [MCPClient] = []
        for cfg in servers where cfg.enabled && !cfg.command.isEmpty {
            let client = MCPClient(serverName: cfg.name)
            do {
                let specs = try await client.start(command: cfg.command, args: MCPClient.expandedArgs(cfg.args))
                var registered = 0
                for s in specs {
                    let namespaced = s.toToolSpec(serverName: cfg.name)
                    // SAFETY: never let an MCP tool shadow a built-in (esp. the
                    // confirm-gated run_shell / run_applescript). Namespacing makes
                    // a collision unlikely, but a server named to collide must be
                    // rejected, not allowed to hijack a privileged tool.
                    guard !BuiltinToolNames.isReserved(namespaced.name) else {
                        Logger.shared.error("[mcp] '\(cfg.name)' tool '\(s.name)' skipped: '\(namespaced.name)' collides with a built-in tool")
                        continue
                    }
                    tools.append(MCPTool(client: client, originalName: s.name, toolSpec: namespaced))
                    registered += 1
                }
                clients.append(client)
                Logger.shared.info("[mcp] '\(cfg.name)' started; \(registered)/\(specs.count) tools registered")
            } catch {
                client.shutdown()
                Logger.shared.error("[mcp] '\(cfg.name)' skipped: \(error.localizedDescription)")
            }
        }
        return (tools, clients)
    }
}
