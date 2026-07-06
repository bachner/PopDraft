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

// MARK: - PR9: Mac-control confirmation seam

/// The seam between a Mac-control tool (running off-main inside `ToolRunner`)
/// and the chat UI. The tool `await`s `requestConfirmation(_:)`; the UI renders a
/// confirm card and later calls `resolve(id:decision:)`. `@MainActor`-isolated
/// so all UI state mutation is main-thread safe; the tool hops here via `await`.
///
/// CRITICAL: this is the ONLY way a Mac-control tool obtains permission to run.
/// There is no bypass — a tool with no confirmer (headless / no UI) gets `.deny`
/// from the default broker, so it can never auto-execute.
@MainActor
protocol MacControlConfirmer: AnyObject {
    /// Present `request` to the user and suspend until they decide. Implementations
    /// MUST eventually resolve (approve/edit/deny) — including on cancel/teardown.
    func requestConfirmation(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

/// A broker that funnels confirmation requests from the tool to a UI sink and
/// suspends on a continuation until the UI resolves them. The active chat
/// view-model registers itself as the `sink`; with no sink (headless), every
/// request resolves to `.deny` so nothing can run without a real UI tap.
@MainActor
final class MacControlBroker: MacControlConfirmer {
    /// A presenter the UI implements: show the card; the broker is told the
    /// decision later via `resolve(id:decision:)`.
    @MainActor
    protocol Sink: AnyObject {
        func present(_ request: ConfirmationRequest)
        /// Called when a request is withdrawn (e.g. run cancelled) so the UI can
        /// drop its card.
        func withdraw(id: String)
    }

    weak var sink: Sink?

    /// "Allow everything automatically" (AgentSettings.autoApproveAll). When set,
    /// a request is approved WITHOUT presenting a card. The caller (each gate) has
    /// ALREADY enforced the hard denylist before reaching here, so this can only
    /// auto-approve commands that already passed the safety denylist. Kept in sync
    /// by the chat view-model from config; only consulted when a `sink` exists, so
    /// the headless (no-sink) path can never auto-run.
    var autoApproveAll: Bool = false

    private var pending: [String: CheckedContinuation<ConfirmationDecision, Never>] = [:]

    func requestConfirmation(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        // No UI to confirm → deny, structurally. Nothing runs.
        guard let sink = sink else { return .deny }
        // Opt-in "allow everything automatically": approve without a card. The
        // denylist was already applied upstream by the gate, so dangerous commands
        // never reach this point.
        if autoApproveAll {
            Logger.shared.info("[mac-control] AUTO-APPROVED (allow-everything on, \(request.kind.rawValue)): \(request.command)")
            return .approve
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ConfirmationDecision, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: .deny)
                    return
                }
                self.pending[request.id] = cont
                sink.present(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: request.id, decision: .deny) }
        }
    }

    /// Resolve a pending confirmation (called by the UI on Approve/Edit/Deny).
    func resolve(id: String, decision: ConfirmationDecision) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        sink?.withdraw(id: id)
        cont.resume(returning: decision)
    }

    /// Deny + withdraw everything still pending (used on chat dismiss/cancel).
    func denyAll() {
        let ids = Array(pending.keys)
        for id in ids { resolve(id: id, decision: .deny) }
    }
}

// MARK: - PR9: Mac-control command execution (reuses the .command primitive)

/// Runs a shell command via the SAME `Process` primitive as the `.command`
/// action (zsh + 30s timeout + captured stdout/stderr). Pure execution only —
/// the denylist + confirm-gate are enforced by the CALLER before this is ever
/// reached. Never elevates privileges. Returns (stdout, stderr, exitCode).
enum MacControlExec {
    static let timeoutSeconds: Double = 30

    /// Run `command` in zsh. `@Sendable`/nonisolated so the tool can call it off
    /// the main actor inside the ToolRunner task group.
    static func runShell(_ command: String) -> (stdout: String, stderr: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 30s timeout — terminate the process if it overruns (mirrors .command).
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            // Read BEFORE waitUntilExit to avoid a pipe-buffer deadlock on large output.
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return (out, err, process.terminationStatus)
        } catch {
            timer.cancel()
            return ("", "Failed to launch: \(error.localizedDescription)", -1)
        }
    }

    /// Run an AppleScript via `osascript -e`. Same 30s bound.
    static func runAppleScript(_ script: String) -> (stdout: String, stderr: String, exit: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { process.terminate() }
        timer.resume()

        do {
            try process.run()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return (out, err, process.terminationStatus)
        } catch {
            timer.cancel()
            return ("", "Failed to launch: \(error.localizedDescription)", -1)
        }
    }
}

// MARK: - PR9: Mac-control tools (confirm-gated)

/// Shared confirm-gate logic for `run_shell` / `run_applescript`. This is the
/// SINGLE execution path; both tools route through it so the gate cannot be
/// bypassed.
///
/// Flow for one invocation:
///   1. Denylist check (always) → on hit, return an error, run NOTHING + log.
///   2. `MacControlPolicy.decide` → `.autoApprove` only if the user enabled the
///      safe-read-only setting AND the command is allowlisted; else `.needsConfirm`.
///   3. Dry-run / headless → record "would execute" and return WITHOUT running.
///   4. `.needsConfirm` → `await confirmer.requestConfirmation(...)`:
///        - `.deny`     → return "user denied", run NOTHING.
///        - `.edit(c2)` → re-run the gate on the edited command (deny still applies),
///                        then run it.
///        - `.approve`  → run it.
///   5. Run via `MacControlExec`, cap output, LOG the executed command, return.
struct MacControlGate: @unchecked Sendable {
    // `@unchecked Sendable`: `confirmer` is a MainActor-isolated class, only ever
    // touched via `await confirmer.requestConfirmation(...)` (i.e. on the
    // MainActor); `settings`/`kind` are value/Sendable. No mutable shared state.
    let kind: ConfirmationKind
    let confirmer: (any MacControlConfirmer)?
    let settings: AgentSettings

    /// Thread-safe log line. `Logger.shared` appends to a file via `FileHandle`
    /// (safe to call from any thread), so no actor hop is needed.
    private func log(_ message: String, error: Bool = false) {
        if error { Logger.shared.error(message) } else { Logger.shared.info(message) }
    }

    /// `run(command:)` returns the model-facing tool result string. `runner`
    /// is the actual executor (shell or applescript), injected so the same gate
    /// serves both tools and stays unit-testable.
    func run(command rawCommand: String,
             explanation: String,
             runner: @Sendable (String) -> (stdout: String, stderr: String, exit: Int32)) async -> String {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "Error: an empty command cannot be run." }

        // (1)+(2) Pure decision (denylist first).
        let decision = MacControlPolicy.decide(
            command: command, autoApproveSafeReadOnly: settings.autoApproveSafeReadOnly)
        if case .denied(let reason) = decision {
            log("[mac-control] DENIED (\(kind.rawValue)): \(reason) :: \(command)", error: true)
            return "Error: this command is blocked by the safety denylist (\(reason)). It was NOT run. Propose a safer command."
        }

        // (3) Dry-run / headless: never execute when there's no UI to confirm.
        if settings.macControlDryRun {
            log("[mac-control] DRY-RUN would execute (\(kind.rawValue)): \(command)")
            return "Dry-run: would execute (awaiting confirm): \(command)\n(Mac-control dry-run mode is on, so nothing ran.)"
        }

        // (4) Decide the command to actually run (immutable result via a helper so
        //     nothing is a captured `var`).
        let commandToRun: String
        if case .needsConfirm = decision {
            // No confirmer at all → structurally deny (cannot run without UI).
            guard let confirmer = confirmer else {
                log("[mac-control] no confirmer; refusing to run \(command)")
                return "Error: no confirmation UI is available, so this command was NOT run."
            }
            let req = ConfirmationRequest(
                id: UUID().uuidString, kind: kind, command: command,
                explanation: explanation.isEmpty ? defaultExplanation(command) : explanation)
            let userDecision = await confirmer.requestConfirmation(req)
            switch userDecision {
            case .deny:
                log("[mac-control] user DENIED (\(kind.rawValue)): \(command)")
                return "The user denied running this command. It was NOT run. Do not retry it; ask the user what they'd prefer or continue without it."
            case .approve:
                commandToRun = command
            case .edit(let edited):
                let trimmedEdit = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                // Re-apply the denylist to the edited command — Edit can't smuggle danger.
                if let reason = MacControlGuard.denialReason(trimmedEdit) {
                    log("[mac-control] edited command DENIED: \(reason) :: \(trimmedEdit)", error: true)
                    return "Error: the edited command is blocked by the safety denylist (\(reason)). It was NOT run."
                }
                commandToRun = trimmedEdit.isEmpty ? command : trimmedEdit
            }
        } else {
            // .autoApprove: a user-opted-in safe read-only command.
            commandToRun = command
        }

        // (5) Execute via the .command Process primitive.
        log("[mac-control] EXECUTING (\(kind.rawValue)): \(commandToRun)")
        let result = runner(commandToRun)
        log("[mac-control] done (\(kind.rawValue)) exit=\(result.exit) out=\(result.stdout.count)ch")
        return MacControlOutput.format(stdout: result.stdout, stderr: result.stderr, exitCode: result.exit)
    }

    private func defaultExplanation(_ command: String) -> String {
        switch kind {
        case .shell: return "Run this shell command on your Mac."
        case .applescript: return "Run this AppleScript on your Mac."
        case .download: return "Download this file to your Mac."
        }
    }
}

/// `run_shell` — propose a shell command; runs only after the user approves.
struct RunShellTool: AgentTool {
    let gate: MacControlGate
    var spec: ToolSpec {
        ToolSpec.fromOpenAIJSON(MacControlSchemas.runShell)
            ?? ToolSpec(name: "run_shell", description: "Propose a shell command (user must approve).")
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let command = (d["command"] as? String) ?? ""
        let explanation = (d["explanation"] as? String) ?? ""
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'command' is required."
        }
        return await gate.run(command: command, explanation: explanation) { cmd in
            MacControlExec.runShell(cmd)
        }
    }
}

/// `run_applescript` — propose an AppleScript; runs only after the user approves.
struct RunAppleScriptTool: AgentTool {
    let gate: MacControlGate
    var spec: ToolSpec {
        ToolSpec.fromOpenAIJSON(MacControlSchemas.runAppleScript)
            ?? ToolSpec(name: "run_applescript", description: "Propose an AppleScript (user must approve).")
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let script = (d["script"] as? String) ?? ""
        let explanation = (d["explanation"] as? String) ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'script' is required."
        }
        return await gate.run(command: script, explanation: explanation) { src in
            MacControlExec.runAppleScript(src)
        }
    }
}

// MARK: - Mac-control tool self-registration

/// Self-registration of the confirm-gated Mac-control tools. Gated on
/// `enableMacControl` (OFF by default); when off, neither tool is registered, so
/// the model cannot call them. When on, each runs through `MacControlGate`
/// (denylist + confirm-before-execute) with the injected confirmer.
enum MacControlTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { $0.agentSettings.enableMacControl },
            make: { config, confirmer in
                let c = confirmer as? (any MacControlConfirmer)
                return [
                    RunShellTool(gate: MacControlGate(kind: .shell, confirmer: c, settings: config.agentSettings)),
                    RunAppleScriptTool(gate: MacControlGate(kind: .applescript, confirmer: c, settings: config.agentSettings)),
                ]
            }))
    }
}
