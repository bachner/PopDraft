// PopDraft - Local Action Toolbox
//
// A self-contained set of thin agent tools that expose OS capabilities the
// agent lacks today, so it can "do any task" locally without reaching for a
// shell. All of them are tiny wrappers over Foundation / AppKit primitives the
// app already uses elsewhere (NSExpression for math, NSPasteboard for the
// clipboard, NSWorkspace for the frontmost app / opening apps & URLs, and the
// same CGEvent Cmd+C trick PopupController uses to read the user's selection).
//
// Built by co-compiling with the other scripts/*.swift sources:
//   swiftc -O scripts/*.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation
//
// Tools (each an `AgentTool`, self-registered via `AgentToolCatalog`):
//   - current_datetime  — current date/time (optional timezone/format). READ-ONLY.
//   - calculator        — exact arithmetic via NSExpression.            READ-ONLY.
//   - clipboard_read    — current clipboard text.                       READ-ONLY.
//   - current_context   — frontmost app + the user's text selection.    READ-ONLY.
//   - clipboard_write   — set the clipboard.            MUTATES → confirm-gated.
//   - open_app_or_url   — open an app or URL via NSWorkspace. MUTATES → gated.
//
// Read-only tools are always available. The two MUTATING tools route through the
// SAME confirm seam as run_shell (`MacControlConfirmer`): they PROPOSE; nothing
// happens until the user Approves/Edits/Denies — and with no confirmer (headless)
// they structurally deny. The MacControlGuard denylist mindset is honored too:
// each mutating action's proposed command string is run through
// `MacControlGuard.denialReason` before it is ever offered for confirmation.

import Cocoa
import Carbon.HIToolbox

// MARK: - Pure helpers (unit-tested; no AppKit side effects)

/// Pure, deterministic logic for the local action tools. Kept free of AppKit
/// side effects so `tests/test-localactions.swift` can assert math correctness,
/// date formatting, argument parsing, and the mutating-action gate precheck
/// without touching the clipboard, the frontmost app, or launching anything.
enum LocalActionLogic {

    // MARK: calculator

    enum CalcError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalid(String)
        case notFinite

        var description: String {
            switch self {
            case .empty: return "no expression was provided"
            case .invalid(let s): return "could not evaluate the expression: \(s)"
            case .notFinite: return "the result is not a finite number"
            }
        }
    }

    /// Evaluate an arithmetic expression exactly via `NSExpression`. Supports
    /// `+ - * /`, parentheses, exponentiation (`**` or `^`), and the common math
    /// functions NSExpression exposes (sqrt, abs, …). Rejects anything that
    /// isn't a pure numeric expression. Returns a `Double`.
    ///
    /// `NSExpression(format:)` raises an *Objective-C* `NSException` on
    /// malformed input — which pure Swift cannot catch — so we VALIDATE the
    /// token stream first (`isWellFormed`) and only hand a known-good string to
    /// NSExpression. Integer literals are normalized to decimals so `100 / 8`
    /// behaves like a calculator (12.5) rather than integer division (12).
    ///
    /// Pure: a value computation (no I/O, no global state), so it stays testable
    /// and side-effect-free.
    static func evaluate(_ rawExpression: String) throws -> Double {
        let expr = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { throw CalcError.empty }

        // Character-set guard: digits, whitespace, decimal point, the arithmetic
        // operators, parentheses, comma, and letters (function names like sqrt).
        // This keeps NSExpression from ever seeing keypaths / object selectors.
        let allowed = CharacterSet(charactersIn:
            "0123456789.eE+-*/^() ,\t" +
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        guard expr.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw CalcError.invalid(expr)
        }

        // NSExpression spells exponentiation as `**`; accept `^` too.
        let normalized = expr.replacingOccurrences(of: "^", with: "**")

        // Structurally validate so a malformed expression returns an error
        // instead of crashing the process via an uncaught NSException.
        guard isWellFormed(normalized) else { throw CalcError.invalid(expr) }

        // Force floating-point so division isn't truncated to integers.
        let floated = floatizeLiterals(normalized)

        let e = NSExpression(format: floated)
        guard let number = e.expressionValue(with: nil, context: nil) as? NSNumber else {
            throw CalcError.invalid(expr)
        }
        let d = number.doubleValue
        guard d.isFinite else { throw CalcError.notFinite }
        return d
    }

    /// Append `.0` to every integer literal that isn't already part of a float
    /// or an identifier, so NSExpression does float (not integer) arithmetic.
    static func floatizeLiterals(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber {
                var j = i
                var num = ""
                while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                // Already a float if a '.' follows or precedes the run; skip if the
                // digits are part of an identifier (preceded by a letter/_).
                let dotAfter = j < chars.count && chars[j] == "."
                let dotBefore = i > 0 && chars[i - 1] == "."
                let prevAlpha = i > 0 && (chars[i - 1].isLetter || chars[i - 1] == "_")
                out += num
                if !dotAfter && !dotBefore && !prevAlpha { out += ".0" }
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// A conservative well-formedness check for an arithmetic expression that has
    /// already passed the character-set guard (and had `^`→`**` applied). Catches
    /// the realistic malformed cases that would otherwise make NSExpression raise
    /// an uncaught NSException: unbalanced parens, an operator at the start/end,
    /// two binary operators in a row, an empty `()`, or a value/`)` immediately
    /// followed by a value/`(` with no operator between.
    static func isWellFormed(_ s: String) -> Bool {
        // `sign` = +/- (can be unary or binary); `mul` = * / ** (binary only).
        enum Tok: Equatable { case num, ident, sign, mul, lparen, rparen, comma }
        var toks: [Tok] = []
        let chars = Array(s)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c.isNumber || c == "." {
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" { i += 1 }
                toks.append(.num)
            } else if c.isLetter || c == "_" {
                while i < chars.count, chars[i].isLetter || chars[i] == "_" || chars[i].isNumber { i += 1 }
                toks.append(.ident)
            } else if c == "(" {
                depth += 1; toks.append(.lparen); i += 1
            } else if c == ")" {
                depth -= 1; if depth < 0 { return false }; toks.append(.rparen); i += 1
            } else if c == "," {
                toks.append(.comma); i += 1
            } else if c == "+" || c == "-" {
                toks.append(.sign); i += 1
            } else if c == "*" || c == "/" {
                if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" { i += 2 } else { i += 1 }
                toks.append(.mul)
            } else {
                return false
            }
        }
        guard depth == 0, !toks.isEmpty else { return false }

        // A position "expects a value" when the previous token was start, an
        // operator, '(' or ','. In that position a `mul` (* / **) is illegal and
        // a `sign` (+/-) is a unary prefix (legal). A value/`)` ends an operand.
        func expectsValue(before idx: Int) -> Bool {
            guard idx > 0 else { return true }
            switch toks[idx - 1] {
            case .sign, .mul, .lparen, .comma: return true
            case .num, .ident, .rparen: return false
            }
        }

        for (idx, t) in toks.enumerated() {
            let prev = idx > 0 ? toks[idx - 1] : nil
            let last = idx == toks.count - 1
            switch t {
            case .mul:
                // Binary-only: never at start/end, never where a value is expected.
                if expectsValue(before: idx) || last { return false }
            case .sign:
                // Never at the very end. A unary sign after a `mul` is fine
                // (NSExpression accepts `2 * -3`, `2 ** -1`); but two signs in a
                // row (`1 + + 2`) is rejected by NSExpression, so reject it here.
                if last { return false }
                if let p = prev, p == .sign { return false }
            case .num:
                if let p = prev, p == .num || p == .rparen { return false }
            case .ident:
                if let p = prev, p == .num || p == .rparen { return false }
            case .lparen:
                if let p = prev, p == .num || p == .rparen { return false }
            case .rparen:
                if let p = prev, p == .sign || p == .mul || p == .lparen || p == .comma { return false }
            case .comma:
                if prev == nil || prev == .sign || prev == .mul || prev == .lparen || prev == .comma { return false }
            }
        }
        return true
    }

    /// Format a numeric result compactly: integers print without a trailing
    /// `.0`; non-integers keep full precision (trimmed of trailing zeros).
    static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        // Trim trailing zeros from a high-precision representation.
        var s = String(format: "%.10f", value)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            s.removeLast()
        }
        return s
    }

    // MARK: datetime

    /// Build a date string for `date` in `timeZoneID` (nil → current) using
    /// `format`: nil/"iso" → ISO-8601; "rfc"/"rfc2822" → RFC-2822-ish; otherwise
    /// the string is treated as a `DateFormatter` pattern. Returns the formatted
    /// string and the resolved timezone identifier.
    static func formatDate(_ date: Date,
                           timeZoneID: String?,
                           format: String?) -> (text: String, timeZone: String) {
        let tz: TimeZone = {
            if let id = timeZoneID, !id.isEmpty, let t = TimeZone(identifier: id) { return t }
            if let id = timeZoneID, !id.isEmpty, let t = TimeZone(abbreviation: id) { return t }
            return TimeZone.current
        }()

        let fmtKey = (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch fmtKey {
        case "", "iso", "iso8601", "iso-8601":
            let f = ISO8601DateFormatter()
            f.timeZone = tz
            f.formatOptions = [.withInternetDateTime]
            return (f.string(from: date), tz.identifier)
        case "rfc", "rfc2822", "rfc822":
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz
            df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return (df.string(from: date), tz.identifier)
        case "unix", "epoch", "timestamp":
            return (String(Int64(date.timeIntervalSince1970)), tz.identifier)
        default:
            // Treat the value as a custom DateFormatter pattern.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz
            df.dateFormat = format
            return (df.string(from: date), tz.identifier)
        }
    }

    // MARK: open target

    enum OpenTargetKind: Equatable {
        case url(String)         // an http(s)/file/scheme URL
        case app(String)         // an application name or path
    }

    /// Classify an `open_app_or_url` target: a URL with a scheme (or a bare
    /// host like `example.com`) is treated as a URL; everything else is treated
    /// as an application name/path.
    static func classifyOpenTarget(_ raw: String) -> OpenTargetKind {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://") { return .url(t) }
        // A bare domain like "apple.com" or "www.x.org/y" → https URL.
        if !t.hasPrefix("/"), !t.hasPrefix("~"),
           let firstWord = t.split(separator: " ").first,
           firstWord.contains("."),
           !firstWord.hasSuffix(".app"),
           !t.lowercased().hasSuffix(".app") {
            return .url("https://" + t)
        }
        return .app(t)
    }

    /// The "command string" a mutating action would represent, used purely to
    /// run it through the shared `MacControlGuard` denylist (defense in depth)
    /// and to show the user exactly what will happen.
    static func proposedCommand(clipboardWrite text: String) -> String {
        let preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        return "Set the clipboard to: \(preview)"
    }
    static func proposedCommand(open target: String) -> String {
        switch classifyOpenTarget(target) {
        case .url(let u): return "open \(u)"
        case .app(let a): return "open -a \"\(a)\""
        }
    }
}

// MARK: - Confirm seam (reuses the run_shell confirmer)

/// The mutating local-action tools route through the SAME confirmation seam as
/// `run_shell`: a `MacControlConfirmer` (the chat view-model's broker). They
/// PROPOSE a `ConfirmationRequest`; the user Approves/Edits/Denies; only on
/// approval does the native AppKit side effect run. With no confirmer (headless
/// / no UI) the broker contract resolves every request to `.deny`, so a mutating
/// tool can never auto-execute — mirroring run_shell exactly.
///
/// Shared gate used by clipboard_write / open_app_or_url. Kept tiny: it applies
/// the MacControlGuard denylist (belt-and-suspenders), asks the confirmer, and
/// returns the user's resolved decision (or a structural deny).
struct LocalActionGate: @unchecked Sendable {
    // `@unchecked Sendable`: `confirmer` is a MainActor-isolated object only ever
    // touched via `await …requestConfirmation` (on the MainActor). No other
    // mutable shared state. Mirrors MacControlGate's reasoning.
    let confirmer: (any MacControlConfirmer)?

    enum Outcome {
        case approved(String)   // run it (carries the possibly-edited command preview)
        case denied(String)     // model-facing reason; nothing ran
    }

    /// Run the denylist precheck + confirm round-trip for a proposed mutating
    /// action described by `command` (shown verbatim) and `explanation`.
    func confirm(command: String, explanation: String) async -> Outcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .denied("Error: nothing to do (empty request).") }

        // Defense in depth: a mutating local action must still respect the hard
        // denylist (sudo / rm -rf / curl|sh / …) even though these tools don't
        // shell out — a maliciously crafted "open" target or clipboard payload
        // that looks like a dangerous command is refused before it's even offered.
        if let reason = MacControlGuard.denialReason(trimmed) {
            Logger.shared.error("[local-action] DENIED by safety denylist (\(reason)) :: \(trimmed)")
            return .denied("Error: this action is blocked by the safety denylist (\(reason)). It was NOT performed.")
        }

        // No confirmer at all → structurally deny (cannot act without a UI tap),
        // exactly like run_shell in headless mode.
        guard let confirmer = confirmer else {
            Logger.shared.info("[local-action] no confirmer; refusing to perform: \(trimmed)")
            return .denied("Error: no confirmation UI is available, so this action was NOT performed.")
        }

        // Reuse the run_shell confirm card (kind .shell — same Approve/Edit/Deny UI).
        let req = ConfirmationRequest(
            id: UUID().uuidString, kind: .shell, command: trimmed,
            explanation: explanation.isEmpty ? trimmed : explanation)
        let decision = await confirmer.requestConfirmation(req)
        switch decision {
        case .deny:
            Logger.shared.info("[local-action] user DENIED: \(trimmed)")
            return .denied("The user denied this action. It was NOT performed. Do not retry it; ask the user what they'd prefer or continue without it.")
        case .approve:
            Logger.shared.info("[local-action] user APPROVED: \(trimmed)")
            return .approved(trimmed)
        case .edit(let edited):
            let e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            // Re-apply the denylist to the edited text — Edit can't smuggle danger.
            if let reason = MacControlGuard.denialReason(e) {
                Logger.shared.error("[local-action] edited action DENIED (\(reason)) :: \(e)")
                return .denied("Error: the edited action is blocked by the safety denylist (\(reason)). It was NOT performed.")
            }
            Logger.shared.info("[local-action] user EDITED+APPROVED: \(e)")
            return .approved(e.isEmpty ? trimmed : e)
        }
    }
}

// MARK: - Read-only tools (always available)

/// `current_datetime` — the current date and time, optionally in a given
/// timezone and/or format. Foundation-only; read-only; always available.
struct CurrentDateTimeTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "current_datetime",
            description: "Get the current date and time. Use this whenever you need 'now' — "
                + "the current date, day of week, or time. Optional 'timezone' (IANA id like "
                + "'America/New_York' or 'UTC'; default: the Mac's local zone) and 'format' "
                + "('iso' (default), 'rfc', 'unix', or a custom DateFormatter pattern like "
                + "'EEEE, MMMM d, yyyy h:mm a').",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "timezone": ["type": "string", "description": "IANA timezone id (e.g. 'UTC', 'America/New_York'). Optional; defaults to local."],
                    "format": ["type": "string", "description": "'iso' (default), 'rfc', 'unix', or a DateFormatter pattern. Optional."],
                ],
            ])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let tz = d["timezone"] as? String
        let fmt = d["format"] as? String
        let (text, zone) = LocalActionLogic.formatDate(Date(), timeZoneID: tz, format: fmt)
        return localActionJSON(["datetime": text, "timezone": zone])
    }
}

/// `calculator` — evaluate an arithmetic expression exactly via NSExpression.
/// Read-only; always available.
struct CalculatorTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "calculator",
            description: "Evaluate an arithmetic expression exactly (e.g. '1234 * 5678', "
                + "'(2 + 3) ** 4', 'sqrt(2) * 100'). Use this for ANY arithmetic instead of "
                + "computing it yourself — it is exact. Supports + - * /, parentheses, "
                + "exponentiation (** or ^), and common math functions (sqrt, abs, …).",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "expression": ["type": "string", "description": "The arithmetic expression to evaluate."],
                ],
                "required": ["expression"],
            ])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let expr = (args.dictionary["expression"] as? String) ?? ""
        do {
            let value = try LocalActionLogic.evaluate(expr)
            return localActionJSON(["expression": expr.trimmingCharacters(in: .whitespacesAndNewlines),
                                    "result": LocalActionLogic.formatNumber(value)])
        } catch let e as LocalActionLogic.CalcError {
            return "Error: \(e.description)"
        }
    }
}

/// `clipboard_read` — the current text on the system clipboard. Read-only.
struct ClipboardReadTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "clipboard_read",
            description: "Read the current text contents of the macOS clipboard (pasteboard). "
                + "Use to see what the user just copied. Returns the clipboard text, or notes "
                + "that it is empty / non-text.",
            parametersSchema: ["type": "object", "properties": [String: Any]()])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let text = await MainActor.run { () -> String? in
            NSPasteboard.general.string(forType: .string)
        }
        guard let text = text, !text.isEmpty else {
            return "The clipboard is empty or does not contain text."
        }
        return text
    }
}

/// `current_context` — the frontmost app name and the user's current text
/// selection (captured the same way the popup captures it: a transient Cmd+C
/// that is restored afterwards). Read-only. Needs Accessibility; degrades
/// gracefully (selection omitted) when it is not granted or nothing is selected.
struct CurrentContextTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "current_context",
            description: "Get the user's current desktop context: the name of the frontmost "
                + "(active) application and the text the user currently has selected there. "
                + "Use this to act on 'this', 'the selected text', or 'what I'm looking at' "
                + "without asking. The selection may be empty if nothing is selected or "
                + "Accessibility permission is not granted.",
            parametersSchema: ["type": "object", "properties": [String: Any]()])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        let snapshot = await MainActor.run { LocalSelection.capture() }
        var out: [String: String] = ["frontmostApp": snapshot.appName]
        if let sel = snapshot.selection, !sel.isEmpty {
            out["selection"] = sel
        } else {
            out["selection"] = ""
            out["note"] = "No text selection was detected (nothing selected, or Accessibility not granted)."
        }
        return localActionJSON(out)
    }
}

// MARK: - Mutating tools (confirm-gated)

/// `clipboard_write` — set the system clipboard to `text`. MUTATES state, so it
/// routes through the confirm seam (the user sees what it'll set and Approves /
/// Edits / Denies). On approval the write is the native `NSPasteboard` call.
struct ClipboardWriteTool: AgentTool {
    let gate: LocalActionGate
    var spec: ToolSpec {
        ToolSpec(
            name: "clipboard_write",
            description: "Set the macOS clipboard to the given text (so the user can paste it). "
                + "MUTATES the clipboard — the user must Approve before it runs. Use after you "
                + "have produced a result the user will want to paste.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The exact text to place on the clipboard."],
                ],
                "required": ["text"],
            ])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        guard let text = args.dictionary["text"] as? String, !text.isEmpty else {
            return "Error: 'text' is required."
        }
        let outcome = await gate.confirm(
            command: LocalActionLogic.proposedCommand(clipboardWrite: text),
            explanation: "Replace the clipboard contents.")
        switch outcome {
        case .denied(let reason):
            return reason
        case .approved:
            // The user approved setting the clipboard to `text` (the proposed
            // preview is for display; the actual payload is the full `text`).
            let ok = await MainActor.run { () -> Bool in
                let pb = NSPasteboard.general
                pb.clearContents()
                return pb.setString(text, forType: .string)
            }
            return ok
                ? "Clipboard set (\(text.count) characters). The user can now paste it."
                : "Error: failed to write to the clipboard."
        }
    }
}

/// `open_app_or_url` — open an application or a URL via `NSWorkspace`. MUTATES /
/// launches, so it routes through the confirm seam. On approval it uses
/// `NSWorkspace.shared.open(_:)` for URLs and an app launcher for apps.
struct OpenAppOrURLTool: AgentTool {
    let gate: LocalActionGate
    var spec: ToolSpec {
        ToolSpec(
            name: "open_app_or_url",
            description: "Open an application or a URL on the user's Mac. 'target' may be a URL "
                + "('https://apple.com', a bare domain like 'apple.com', or a 'file://' / app "
                + "scheme) or an application name/path ('Safari', 'Notes', "
                + "'/Applications/Mail.app'). MUTATES — launches something — so the user must "
                + "Approve before it runs.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "A URL, a bare domain, or an application name/path to open."],
                ],
                "required": ["target"],
            ])
    }
    func invoke(_ args: JSONObject) async throws -> String {
        guard let target = (args.dictionary["target"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            return "Error: 'target' is required."
        }
        let outcome = await gate.confirm(
            command: LocalActionLogic.proposedCommand(open: target),
            explanation: "Open this on your Mac.")
        switch outcome {
        case .denied(let reason):
            return reason
        case .approved:
            let kind = LocalActionLogic.classifyOpenTarget(target)
            let result: String = await MainActor.run { () -> String in
                switch kind {
                case .url(let u):
                    guard let url = URL(string: u) else { return "Error: '\(target)' is not a valid URL." }
                    return NSWorkspace.shared.open(url)
                        ? "Opened \(u)."
                        : "Error: macOS could not open \(u)."
                case .app(let name):
                    return LocalSelection.openApplication(name)
                        ? "Opened application '\(name)'."
                        : "Error: could not open application '\(name)'."
                }
            }
            return result
        }
    }
}

// MARK: - AppKit capture helpers (MainActor)

/// MainActor-isolated AppKit helpers used by the read-only context tool and the
/// open tool. Selection capture mirrors PopupController.captureSelectedText: a
/// transient CGEvent Cmd+C, poll the pasteboard, then RESTORE the original
/// clipboard so we never clobber what the user had copied.
@MainActor
enum LocalSelection {
    struct Snapshot {
        let appName: String
        let selection: String?
    }

    static func capture() -> Snapshot {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let selection = captureSelection()
        return Snapshot(appName: appName, selection: selection)
    }

    /// Best-effort copy of the current selection via a transient Cmd+C, with the
    /// original clipboard restored. Returns nil if nothing changed (no selection
    /// / no Accessibility). Read-only from the user's perspective.
    private static func captureSelection() -> String? {
        let pasteboard = NSPasteboard.general
        // Save the current clipboard so we can restore it.
        let saved: [(NSPasteboard.PasteboardType, Data)] = pasteboard.pasteboardItems?
            .compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
                guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
                return (type, data)
            } ?? []
        let savedChangeCount = pasteboard.changeCount

        // Simulate Cmd+C (virtual key 0x08 == 'c').
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)

        // Poll up to ~500ms for the clipboard to change.
        for _ in 0..<10 {
            usleep(50_000)
            if pasteboard.changeCount != savedChangeCount { break }
        }

        let captured: String?
        if pasteboard.changeCount != savedChangeCount {
            captured = pasteboard.string(forType: .string)
            // Restore the user's original clipboard.
            pasteboard.clearContents()
            for (type, data) in saved { pasteboard.setData(data, forType: type) }
        } else {
            captured = nil  // nothing copied → no selection (or no Accessibility)
        }
        return captured
    }

    /// Open an application by name or path. Tries, in order: an explicit
    /// path/.app, a bundle-id lookup, and the standard `/Applications` (and
    /// user) folders by display name. Uses only non-deprecated NSWorkspace APIs.
    static func openApplication(_ nameOrPath: String) -> Bool {
        let ws = NSWorkspace.shared
        let fm = FileManager.default

        if nameOrPath.hasPrefix("/") || nameOrPath.hasSuffix(".app") {
            let url = URL(fileURLWithPath: nameOrPath)
            if fm.fileExists(atPath: url.path) {
                ws.open(url)
                return true
            }
        }
        if let url = ws.urlForApplication(withBundleIdentifier: nameOrPath) {
            ws.open(url)
            return true
        }
        // By display name → look in the standard Applications folders.
        let appFile = nameOrPath.hasSuffix(".app") ? nameOrPath : nameOrPath + ".app"
        let candidates = [
            "/Applications/\(appFile)",
            "/System/Applications/\(appFile)",
            NSString(string: "~/Applications/\(appFile)").expandingTildeInPath,
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            ws.open(URL(fileURLWithPath: path))
            return true
        }
        return false
    }
}

/// Encode a `[String: String]` result as compact, deterministic (sorted-key)
/// JSON for a tool's string output. Self-contained (no dependency on the web
/// engine's `toolJSON`) so this file co-compiles with Core alone in unit tests.
func localActionJSON(_ dict: [String: String]) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(dict), let s = String(data: data, encoding: .utf8) {
        return s
    }
    // Fallback: never return nothing.
    return dict.keys.sorted().map { "\($0): \(dict[$0] ?? "")" }.joined(separator: "\n")
}

// MARK: - Self-registration

/// Self-registration of the local action toolbox into the agent tool catalog.
///
/// All six tools live in ONE always-on group (`gate: { _ in true }`). The
/// read-only tools (datetime / calculator / clipboard_read / current_context)
/// run with no further gating. The two MUTATING tools (clipboard_write /
/// open_app_or_url) are still safe to register unconditionally because they
/// route through `LocalActionGate` → the SAME `MacControlConfirmer` seam as
/// run_shell: with no confirmer (headless) every mutating request structurally
/// denies, and with a confirmer nothing happens until the user Approves.
///
/// Registering all six in `make` (regardless of confirmer) also means
/// `AgentToolCatalog.reservedNames` — which calls each group's `make` — covers
/// every name here, so no MCP server can shadow them.
enum LocalActionTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { _ in true },
            make: { _, confirmer in
                let c = confirmer as? (any MacControlConfirmer)
                let gate = LocalActionGate(confirmer: c)
                return [
                    // read-only, always usable
                    CurrentDateTimeTool(),
                    CalculatorTool(),
                    ClipboardReadTool(),
                    CurrentContextTool(),
                    // mutating, confirm-gated through the run_shell seam
                    ClipboardWriteTool(gate: gate),
                    OpenAppOrURLTool(gate: gate),
                ]
            }))
    }
}
