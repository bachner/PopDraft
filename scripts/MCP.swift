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
    /// Start ONE server and turn its advertised tools into namespaced
    /// `MCPTool`s. Returns nil if the server failed to start/handshake (it is
    /// shut down + logged). Shared by the serial-output assembly and the live
    /// `add_mcp_server` path.
    static func startServer(_ cfg: MCPServerConfig) async -> (client: MCPClient, tools: [any AgentTool])? {
        let client = MCPClient(serverName: cfg.name)
        do {
            let specs = try await client.start(command: cfg.command, args: MCPClient.expandedArgs(cfg.args))
            var tools: [any AgentTool] = []
            for s in specs {
                let namespaced = s.toToolSpec(serverName: cfg.name)
                // SAFETY: never let an MCP tool shadow a built-in (esp. the
                // confirm-gated run_shell / run_applescript). Namespacing makes a
                // collision unlikely, but a server named to collide must be
                // rejected, not allowed to hijack a privileged tool.
                guard !BuiltinToolNames.isReserved(namespaced.name) else {
                    Logger.shared.error("[mcp] '\(cfg.name)' tool '\(s.name)' skipped: '\(namespaced.name)' collides with a built-in tool")
                    continue
                }
                tools.append(MCPTool(client: client, originalName: s.name, toolSpec: namespaced))
            }
            Logger.shared.info("[mcp] '\(cfg.name)' started; \(tools.count)/\(specs.count) tools registered")
            return (client, tools)
        } catch {
            client.shutdown()
            Logger.shared.error("[mcp] '\(cfg.name)' skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Build the tools for all enabled servers. Startups run CONCURRENTLY (one
    /// task per server) so a slow/failing server (e.g. Gmail awaiting OAuth) can't
    /// delay the others — but the OUTPUT stays ordered by the config list so the
    /// agent's `tools` array is deterministic. The live clients are returned so the
    /// caller can shut them down when the turn ends.
    static func buildTools(servers: [MCPServerConfig]) async -> (tools: [any AgentTool], clients: [MCPClient]) {
        let enabled = servers.enumerated().filter { $0.element.enabled && !$0.element.command.isEmpty }
        guard !enabled.isEmpty else { return ([], []) }

        // Run each server's handshake on its own task, keyed by config index so we
        // can re-order the results deterministically afterwards.
        var byIndex: [Int: (client: MCPClient, tools: [any AgentTool])] = [:]
        await withTaskGroup(of: (Int, (client: MCPClient, tools: [any AgentTool])?).self) { group in
            for (idx, cfg) in enabled {
                group.addTask { (idx, await startServer(cfg)) }
            }
            for await (idx, result) in group {
                if let result = result { byIndex[idx] = result }
            }
        }

        var tools: [any AgentTool] = []
        var clients: [MCPClient] = []
        for (idx, _) in enabled {
            guard let r = byIndex[idx] else { continue }
            clients.append(r.client)
            tools.append(contentsOf: r.tools)
        }
        return (tools, clients)
    }

    /// One-shot, time-bounded connection probe for the Settings "Test" action:
    /// start the server, count its advertised tools, then shut it down. Bounded by
    /// `timeoutMs` so a hung/awaiting-auth server can't freeze Settings. Pure-result
    /// (`MCPProbeResult`) so the UI mapping stays testable.
    static func probe(_ cfg: MCPServerConfig, timeoutMs: Int = 12000) async -> MCPProbeResult {
        guard !cfg.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return MCPProbeResult.from(toolCount: nil, error: "no command configured")
        }
        let client = MCPClient(serverName: cfg.name)
        defer { client.shutdown() }
        do {
            let specs = try await client.start(
                command: cfg.command, args: MCPClient.expandedArgs(cfg.args), timeoutMs: timeoutMs)
            return MCPProbeResult.from(toolCount: specs.count, error: nil)
        } catch {
            return MCPProbeResult.from(toolCount: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - PR12: live MCP client holder (teardown set, appended to mid-turn)

/// A reference holder for the live `MCPClient`s a turn owns. It exists (instead
/// of a plain returned `[MCPClient]`) so a server STARTED MID-TURN by
/// `add_mcp_server` is tracked in the SAME set the turn's teardown shuts down —
/// a value-type array returned from `buildRegistry` couldn't see a later append.
/// `@MainActor`: appended from the installer (main actor) and drained by the
/// turn's `defer`, also on the main actor.
@MainActor
final class MCPClientHolder {
    private(set) var clients: [MCPClient] = []
    func append(_ client: MCPClient) { clients.append(client) }
    func append(contentsOf newClients: [MCPClient]) { clients.append(contentsOf: newClients) }
    func shutdownAll() { for c in clients { c.shutdown() }; clients.removeAll() }
}

// MARK: - PR12: live MCP installer (the add_mcp_server execution seam)

/// The seam `add_mcp_server` uses to actually SET UP a server in the running
/// session: it (a) persists the new `MCPServerConfig` into `AppConfig.mcpServers`,
/// (b) starts the server live and registers its tools INTO THE CURRENTLY RUNNING
/// agent `ToolRegistry` (so they're usable in the same turn), and (c) tracks the
/// live client so the turn's teardown shuts it down.
///
/// `@MainActor`: it owns the live `[MCPClient]` array that `PopDraftAgent.run`'s
/// `defer` shuts down on the main actor, and persistence is cheap. The actual
/// confirm-gate + denylist run in `AddMcpServerTool.invoke` BEFORE this is called.
@MainActor
final class MCPServerInstaller {
    /// The live registry new tools are registered into (the same instance the
    /// loop re-reads each iteration).
    let registry: ToolRegistry
    /// Where to persist `AppConfig` (so a future turn / the Settings UI sees it).
    let configDir: String
    /// Appends a started client to the turn's shutdown list. Keeps the installer
    /// from owning teardown policy — `PopDraftAgent.run` does.
    private let trackClient: @MainActor (MCPClient) -> Void

    init(registry: ToolRegistry, configDir: String, trackClient: @escaping @MainActor (MCPClient) -> Void) {
        self.registry = registry
        self.configDir = configDir
        self.trackClient = trackClient
    }

    /// The outcome relayed back to the model.
    enum InstallResult {
        case started(toolNames: [String])     // started + registered N tools
        case addedNotReachable(String)        // persisted, but handshake failed
    }

    /// Persist + start `cfg` and register its tools into the live registry.
    /// `cfg` has already passed `MCPInstallGuard.validate` and the user's confirm.
    func install(_ cfg: MCPServerConfig) async -> InstallResult {
        // (b) Persist into config first so the server survives the session even if
        // the live handshake then times out (the user can finish auth + it loads
        // next time). Replace any existing server of the same name.
        var config = AppConfig.load(dir: configDir)
        if let i = config.mcpServers.firstIndex(where: { $0.name == cfg.name }) {
            config.mcpServers[i] = cfg
        } else {
            config.mcpServers.append(cfg)
        }
        _ = config.save(to: configDir)

        // (c) Start live + register into the running registry.
        guard let started = await MCPManager.startServer(cfg) else {
            return .addedNotReachable(
                "Added '\(cfg.name)' to your MCP servers and saved it, but it did not "
                + "connect just now (handshake timed out / failed). It may need a one-time "
                + "auth or setup step — check Settings → MCP and use Test. It will be tried "
                + "again next session.")
        }
        trackClient(started.client)
        await registry.register(started.tools)
        let names = started.tools.map { $0.spec.name }
        return .started(toolNames: names)
    }
}

// MARK: - PR12: add_mcp_server agent tool (confirm-gated)

/// `add_mcp_server` — lets the agent INSTALL + ENABLE a new MCP server itself.
/// Confirm-gated through the SAME `MacControlConfirmer` seam as `run_shell`: the
/// agent PROPOSES the exact `command args`; nothing spawns until the user
/// Approves (or Edits). The hard `MacControlGuard` denylist applies so it can
/// never `curl|sh`, `sudo`, etc. On approval it persists the server and starts it
/// live, registering the discovered tools into the running registry so the agent
/// can USE them in the same turn.
///
/// `@unchecked Sendable`: `confirmer` and `installer` are `@MainActor`-isolated
/// reference types, only ever touched via `await` (i.e. hopped to the MainActor);
/// `settings` is a value type. No mutable shared state crosses threads. Mirrors
/// the same rationale as `MacControlGate`.
struct AddMcpServerTool: AgentTool, @unchecked Sendable {
    let confirmer: (any MacControlConfirmer)?
    let installer: MCPServerInstaller?
    let settings: AgentSettings

    var spec: ToolSpec {
        ToolSpec(
            name: "add_mcp_server",
            description: "Install and enable a new MCP server so you gain NEW tools you "
                + "don't currently have (e.g. a weather, maps, database, or service "
                + "connector). Propose the launch command; the user must Approve before "
                + "anything is installed/run (you are PROPOSING, not executing). On approval "
                + "the server starts and its tools become available to you in THIS turn — "
                + "call them next. Prefer an IntegrationCatalog preset's command when one "
                + "fits; otherwise use web_search to find the right npx/uvx package first. "
                + "Do NOT use this for local file/command/code work — use run_shell for that.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string",
                             "description": "A short server name (used as the tool namespace, e.g. 'Weather')."],
                    "command": ["type": "string",
                                "description": "The launch command, e.g. 'npx' or 'uvx'."],
                    "args": ["type": "array", "items": ["type": "string"],
                             "description": "Command arguments, e.g. ['-y', '@modelcontextprotocol/server-...']."],
                    "description": ["type": "string",
                                    "description": "One-line plain-English note on what this server adds (for the approval card)."],
                ],
                "required": ["name", "command"],
            ])
    }

    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let name = (d["name"] as? String) ?? ""
        let command = (d["command"] as? String) ?? ""
        let argsList = (d["args"] as? [String])
            ?? (d["args"] as? [Any])?.compactMap { $0 as? String }
            ?? []
        let note = (d["description"] as? String) ?? ""

        // (a) PURE validation + denylist (same hard block as run_shell).
        switch MCPInstallGuard.validate(name: name, command: command, args: argsList) {
        case .invalid(let reason):
            return "Error: cannot add MCP server — \(reason)."
        case .denied(let reason):
            Logger.shared.error("[mcp] add_mcp_server DENIED by denylist (\(reason)): \(MCPInstallGuard.commandLine(command: command, args: argsList))")
            return "Error: that install command is blocked by the safety denylist (\(reason)). "
                + "It was NOT run. Propose a safer command."
        case .ok(let cfg):
            // Headless/eval dry-run: never spawn — record "would install" and return,
            // exactly like the Mac-control gate does.
            if settings.macControlDryRun {
                let line = MCPInstallGuard.commandLine(command: cfg.command, args: cfg.args)
                Logger.shared.info("[mcp] DRY-RUN would install MCP server '\(cfg.name)': \(line)")
                return "Dry-run: would install and enable MCP server '\(cfg.name)' "
                    + "(\(line)). (Mac-control dry-run mode is on, so nothing was installed/run.)"
            }
            // (b) Confirm gate — same seam as run_shell. No confirmer (headless UI)
            // → structurally deny.
            guard let confirmer = confirmer, let installer = installer else {
                return "Error: no confirmation UI is available, so the MCP server was NOT installed."
            }
            let line = MCPInstallGuard.commandLine(command: cfg.command, args: cfg.args)
            let explanation = note.isEmpty
                ? "Install and run a new MCP server to gain its tools."
                : note
            let req = ConfirmationRequest(
                id: UUID().uuidString, kind: .shell,
                command: "Add MCP server '\(cfg.name)': \(line)",
                explanation: explanation)
            let decision = await confirmer.requestConfirmation(req)
            let approved: MCPServerConfig
            switch decision {
            case .deny:
                Logger.shared.info("[mcp] user DENIED add_mcp_server '\(cfg.name)'")
                return "The user declined to add that MCP server. It was NOT installed. "
                    + "Do not retry it; ask the user what they'd prefer or continue without it."
            case .approve:
                approved = cfg
            case .edit(let edited):
                // The user can edit the "<command> <args…>" line. Re-validate the
                // edited launch through the denylist (Edit can't smuggle danger).
                let editedLine = Self.stripPrefix(edited, server: cfg.name)
                let parts = editedLine
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
                guard let editedCmd = parts.first else {
                    return "Error: the edited install command was empty. Nothing was run."
                }
                let editedArgs = Array(parts.dropFirst())
                switch MCPInstallGuard.validate(name: cfg.name, command: editedCmd, args: editedArgs) {
                case .ok(let c2): approved = c2
                case .denied(let reason):
                    return "Error: the edited install command is blocked by the safety denylist (\(reason)). It was NOT run."
                case .invalid(let reason):
                    return "Error: the edited install command is invalid — \(reason)."
                }
            }

            Logger.shared.info("[mcp] EXECUTING add_mcp_server '\(approved.name)': \(MCPInstallGuard.commandLine(command: approved.command, args: approved.args))")
            switch await installer.install(approved) {
            case .started(let names):
                if names.isEmpty {
                    return "Added and started '\(approved.name)', but it advertised no tools. "
                        + "It may need configuration; check Settings → MCP."
                }
                return "Installed and enabled MCP server '\(approved.name)'. New tools now "
                    + "available to you this turn: \(names.joined(separator: ", ")). "
                    + "Call them to fulfill the request."
            case .addedNotReachable(let msg):
                return msg
            }
        }
    }

    /// Strip the "Add MCP server '<name>': " prefix the confirm card shows, so an
    /// untouched-then-edited command still parses cleanly.
    static func stripPrefix(_ edited: String, server: String) -> String {
        let prefix = "Add MCP server '\(server)': "
        let s = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        return s
    }
}
