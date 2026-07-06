// test-localactions.swift — unit tests for the Local Action Toolbox.
//
// Co-compiled with scripts/Core.swift + scripts/MacControl.swift +
// scripts/LocalActionTools.swift. Asserts (PURE — no clipboard writes, no
// app launches, no real selection capture):
//   - calculator correctness (exact integer math, operators, precedence,
//     float division, malformed-input rejection without crashing),
//   - current_datetime formatting (iso / unix / rfc / custom pattern; timezone),
//   - open-target classification + argument parsing for the tools,
//   - that the two MUTATING tools are confirm-gated: they DENY with no confirmer,
//     DENY on user-deny, honor the MacControlGuard denylist even on approve, and
//     resolve to .approved only through the confirmer seam.
//
// The whole suite runs inside one `@MainActor` async entry point (kicked off and
// then serviced by the main RunLoop) so awaiting the @MainActor confirmer seam
// never deadlocks. A tiny `Logger` stub satisfies MacControl.swift's logging
// (the real Logger lives in UIKitGlass.swift, which we don't link here).

import Foundation

// ----------------------------------------------------------------------------
// Logger stub (MacControl.swift references Logger.shared.info/.error)
// ----------------------------------------------------------------------------

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    func log(_ message: String, level: String = "INFO") {}
    func info(_ message: String) {}
    func error(_ message: String) {}
}

// ----------------------------------------------------------------------------
// Tiny test harness
// ----------------------------------------------------------------------------

@MainActor var testsRun = 0
@MainActor var testsFailed = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    testsRun += 1
    if !condition {
        testsFailed += 1
        print("  [FAIL] \(message)")
    } else {
        print("  [ok]   \(message)")
    }
}

func section(_ name: String) {
    print("")
    print("— \(name)")
}

// A confirmer that always returns a programmed decision, so we can drive the
// confirm-gated tools deterministically.
@MainActor
final class FakeConfirmer: MacControlConfirmer {
    let decision: ConfirmationDecision
    var lastRequest: ConfirmationRequest?
    init(_ decision: ConfirmationDecision) { self.decision = decision }
    func requestConfirmation(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        lastRequest = request
        return decision
    }
}

// A sink that records whether a confirmation card was ever presented — used to
// prove "allow everything automatically" auto-approves WITHOUT showing a card.
@MainActor
final class RecordingSink: MacControlBroker.Sink {
    var presentedCount = 0
    func present(_ request: ConfirmationRequest) { presentedCount += 1 }
    func withdraw(id: String) {}
}

// ----------------------------------------------------------------------------
// The suite (on the MainActor, so awaiting the confirmer seam is safe).
// ----------------------------------------------------------------------------

@MainActor
func runSuite() async {
    // --- calculator ---------------------------------------------------------
    section("calculator: exact arithmetic")

    check((try? LocalActionLogic.evaluate("1234 * 5678")) == 7006652, "1234 * 5678 == 7006652")
    check((try? LocalActionLogic.evaluate("2 + 3 * 4")) == 14, "operator precedence: 2 + 3 * 4 == 14")
    check((try? LocalActionLogic.evaluate("(2 + 3) * 4")) == 20, "parentheses: (2 + 3) * 4 == 20")
    check((try? LocalActionLogic.evaluate("100 / 8")) == 12.5, "float division: 100 / 8 == 12.5")
    check((try? LocalActionLogic.evaluate("2 ** 10")) == 1024, "exponent **: 2 ** 10 == 1024")
    check((try? LocalActionLogic.evaluate("2 ^ 10")) == 1024, "caret ^ maps to exponent: 2 ^ 10 == 1024")
    check((try? LocalActionLogic.evaluate("-5 + 8")) == 3, "leading unary minus: -5 + 8 == 3")
    check((try? LocalActionLogic.evaluate("2 * -3")) == -6, "unary minus after a mul: 2 * -3 == -6")
    if let sq = try? LocalActionLogic.evaluate("sqrt(2) * 100") {
        check(abs(sq - 141.4213562373) < 1e-6, "function sqrt(2) * 100 ≈ 141.42 (\(sq))")
    } else { check(false, "sqrt(2) * 100 should evaluate") }

    check(LocalActionLogic.formatNumber(7006652) == "7006652", "formatNumber: integer has no .0")
    check(LocalActionLogic.formatNumber(12.5) == "12.5", "formatNumber: 12.5 keeps decimal")

    do {
        _ = try LocalActionLogic.evaluate("")
        check(false, "empty throws .empty")
    } catch let e as LocalActionLogic.CalcError {
        check(e == .empty, "empty → CalcError.empty")
    } catch { check(false, "empty threw wrong error") }

    check((try? LocalActionLogic.evaluate("rm -rf /")) == nil, "non-arithmetic input is rejected (char-set guard)")
    check((try? LocalActionLogic.evaluate("$(whoami)")) == nil, "shell-ish input is rejected")

    // Malformed but in-charset input must be rejected by isWellFormed, NOT crash
    // the process via an uncaught NSException.
    for bad in ["2++", "()", "* 3", "2 +", "sqrt(", "((1)", "1 + + 2", "2 3"] {
        check((try? LocalActionLogic.evaluate(bad)) == nil, "malformed '\(bad)' returns an error (no crash)")
    }
    check(LocalActionLogic.isWellFormed("1234 ** 5678"), "isWellFormed accepts a valid expression")
    check(!LocalActionLogic.isWellFormed("2 3"), "isWellFormed rejects a missing operator")
    check(!LocalActionLogic.isWellFormed("(1"), "isWellFormed rejects unbalanced parens")
    check(LocalActionLogic.floatizeLiterals("1234 * 5678") == "1234.0 * 5678.0",
          "floatizeLiterals decimalizes integer literals")

    let calcOut = (try? await CalculatorTool().invoke(JSONObject(["expression": "1234 * 5678"]))) ?? "THREW"
    check(calcOut.contains("7006652"), "CalculatorTool returns 7006652 in its result (\(calcOut))")
    let calcErr = (try? await CalculatorTool().invoke(JSONObject(["expression": "@@@"]))) ?? "THREW"
    check(calcErr.hasPrefix("Error:"), "CalculatorTool returns an Error: string on bad input")

    // --- current_datetime ---------------------------------------------------
    section("current_datetime: formatting")

    // A fixed instant: 2026-06-24T00:00:00Z (epoch 1782259200).
    let fixed = Date(timeIntervalSince1970: 1782259200)

    let iso = LocalActionLogic.formatDate(fixed, timeZoneID: "UTC", format: "iso")
    check(iso.text == "2026-06-24T00:00:00Z", "ISO in UTC: \(iso.text)")
    // macOS normalizes the "UTC" identifier to "GMT" — both name the same zone.
    check(iso.timeZone == "UTC" || iso.timeZone == "GMT", "ISO resolved zone is UTC/GMT (\(iso.timeZone))")

    let unix = LocalActionLogic.formatDate(fixed, timeZoneID: "UTC", format: "unix")
    check(unix.text == "1782259200", "unix epoch seconds: \(unix.text)")

    let rfc = LocalActionLogic.formatDate(fixed, timeZoneID: "UTC", format: "rfc")
    check(rfc.text == "Wed, 24 Jun 2026 00:00:00 +0000", "rfc form: \(rfc.text)")

    let custom = LocalActionLogic.formatDate(fixed, timeZoneID: "UTC", format: "yyyy-MM-dd")
    check(custom.text == "2026-06-24", "custom pattern yyyy-MM-dd: \(custom.text)")

    let ny = LocalActionLogic.formatDate(fixed, timeZoneID: "America/New_York", format: "iso")
    check(ny.text == "2026-06-23T20:00:00-04:00", "America/New_York shifts the clock: \(ny.text)")
    check(ny.timeZone == "America/New_York", "NY timezone identifier preserved")

    let localz = LocalActionLogic.formatDate(fixed, timeZoneID: nil, format: nil)
    check(!localz.text.isEmpty && !localz.timeZone.isEmpty, "nil timezone → local zone, non-empty output")

    let dtOut = (try? await CurrentDateTimeTool().invoke(JSONObject(["timezone": "UTC", "format": "unix"]))) ?? "THREW"
    check(dtOut.contains("\"timezone\":\"UTC\"") || dtOut.contains("\"timezone\":\"GMT\""),
          "CurrentDateTimeTool reports the UTC/GMT timezone (\(dtOut))")

    // --- open-target classification -----------------------------------------
    section("open_app_or_url: target classification")

    check(LocalActionLogic.classifyOpenTarget("https://apple.com") == .url("https://apple.com"),
          "explicit scheme → url")
    check(LocalActionLogic.classifyOpenTarget("apple.com") == .url("https://apple.com"),
          "bare domain → https url")
    check(LocalActionLogic.classifyOpenTarget("Safari") == .app("Safari"),
          "plain name → app")
    check(LocalActionLogic.classifyOpenTarget("/Applications/Mail.app") == .app("/Applications/Mail.app"),
          "absolute .app path → app")
    check(LocalActionLogic.classifyOpenTarget("file:///etc/hosts") == .url("file:///etc/hosts"),
          "file:// → url")
    check(LocalActionLogic.proposedCommand(open: "apple.com") == "open https://apple.com",
          "proposed command for a url")
    check(LocalActionLogic.proposedCommand(open: "Safari") == "open -a \"Safari\"",
          "proposed command for an app")

    // --- mutating tools are confirm-gated -----------------------------------
    section("clipboard_write / open_app_or_url: confirm-gating")

    // (1) No confirmer → structurally denied; NOTHING runs.
    let noGate = LocalActionGate(confirmer: nil)
    let cwNoConfirm = (try? await ClipboardWriteTool(gate: noGate).invoke(JSONObject(["text": "hello"]))) ?? "THREW"
    check(cwNoConfirm.lowercased().contains("not performed") || cwNoConfirm.lowercased().contains("no confirmation"),
          "clipboard_write with no confirmer is denied (\(cwNoConfirm))")
    let openNoConfirm = (try? await OpenAppOrURLTool(gate: noGate).invoke(JSONObject(["target": "https://apple.com"]))) ?? "THREW"
    check(openNoConfirm.lowercased().contains("not performed") || openNoConfirm.lowercased().contains("no confirmation"),
          "open_app_or_url with no confirmer is denied (\(openNoConfirm))")

    // (2) User denies → tool reports the action was NOT performed.
    let denyGate = LocalActionGate(confirmer: FakeConfirmer(.deny))
    let cwDenied = (try? await ClipboardWriteTool(gate: denyGate).invoke(JSONObject(["text": "hello"]))) ?? "THREW"
    check(cwDenied.lowercased().contains("denied") && cwDenied.lowercased().contains("not"),
          "clipboard_write denied by the user does not run (\(cwDenied))")

    // (3) MacControlGuard denylist is honored even with an APPROVING confirmer.
    let approveConfirmer = FakeConfirmer(.approve)
    let approveGate = LocalActionGate(confirmer: approveConfirmer)
    let dangerous = await approveGate.confirm(command: "sudo rm -rf /", explanation: "x")
    if case .denied(let r) = dangerous {
        check(r.lowercased().contains("denylist"), "denylist blocks a dangerous proposed action even on approve (\(r))")
    } else {
        check(false, "denylist should have blocked 'sudo rm -rf /'")
    }

    // (4) A safe approved action resolves to .approved through the confirmer seam.
    let safe = await approveGate.confirm(command: "open https://apple.com", explanation: "open a url")
    if case .approved = safe { check(true, "a safe approved action resolves to .approved") }
    else { check(false, "a safe approved action should resolve to .approved") }

    // (5) The confirmer actually saw a ConfirmationRequest (the seam was used).
    check(approveConfirmer.lastRequest != nil, "the confirmer received a ConfirmationRequest (confirm seam exercised)")

    // (6) Missing required args are rejected before any gating.
    let cwNoText = (try? await ClipboardWriteTool(gate: approveGate).invoke(JSONObject([:]))) ?? "THREW"
    check(cwNoText.hasPrefix("Error:"), "clipboard_write without 'text' errors")
    let openNoTarget = (try? await OpenAppOrURLTool(gate: approveGate).invoke(JSONObject([:]))) ?? "THREW"
    check(openNoTarget.hasPrefix("Error:"), "open_app_or_url without 'target' errors")

    // --- "allow everything automatically" (autoApproveAll) ------------------
    section("allow everything automatically")

    // (1) Broker with autoApproveAll auto-approves WITHOUT presenting a card.
    let autoSink = RecordingSink()
    let autoBroker = MacControlBroker()
    autoBroker.sink = autoSink
    autoBroker.autoApproveAll = true
    let autoReq = ConfirmationRequest(id: "a1", kind: .shell, command: "echo hi", explanation: "")
    let autoDecision = await autoBroker.requestConfirmation(autoReq)
    check(autoDecision == .approve, "autoApproveAll → request is auto-approved")
    check(autoSink.presentedCount == 0, "autoApproveAll → no confirmation card was presented")

    // (2) Even with autoApproveAll, a live gate still enforces the hard denylist
    //     (it's checked BEFORE the broker), so dangerous commands never run.
    let autoGate = LocalActionGate(confirmer: autoBroker)
    let autoDanger = await autoGate.confirm(command: "sudo rm -rf /", explanation: "x")
    if case .denied(let r) = autoDanger {
        check(r.lowercased().contains("denylist"), "autoApproveAll still blocks denylisted commands (\(r))")
    } else {
        check(false, "autoApproveAll must NOT bypass the denylist for 'sudo rm -rf /'")
    }
    // A safe command under autoApproveAll resolves straight to .approved.
    let autoSafe = await autoGate.confirm(command: "open https://apple.com", explanation: "x")
    if case .approved = autoSafe { check(true, "autoApproveAll approves a safe action with no prompt") }
    else { check(false, "autoApproveAll should approve a safe action") }

    // (3) Headless safety: autoApproveAll with NO sink still DENIES (never runs
    //     without a real UI present).
    let headlessBroker = MacControlBroker()
    headlessBroker.autoApproveAll = true   // no sink set
    let headlessDecision = await headlessBroker.requestConfirmation(
        ConfirmationRequest(id: "h1", kind: .shell, command: "echo hi", explanation: ""))
    check(headlessDecision == .deny, "autoApproveAll with no sink still denies (headless can't auto-run)")

    // --- tool specs ---------------------------------------------------------
    section("tool specs")

    let names: Set<String> = [
        CurrentDateTimeTool().spec.name,
        CalculatorTool().spec.name,
        ClipboardReadTool().spec.name,
        CurrentContextTool().spec.name,
        ClipboardWriteTool(gate: noGate).spec.name,
        OpenAppOrURLTool(gate: noGate).spec.name,
    ]
    check(names == ["current_datetime", "calculator", "clipboard_read", "current_context",
                    "clipboard_write", "open_app_or_url"],
          "all six tool names present and correct")
    check(CalculatorTool().spec.openAIToolDict["type"] as? String == "function",
          "CalculatorTool emits a valid OpenAI function-tool dict")

    // --- summary ------------------------------------------------------------
    print("")
    print("==========================================")
    print("test-localactions: \(testsRun - testsFailed)/\(testsRun) passed")
    if testsFailed > 0 {
        print("FAILED: \(testsFailed)")
        exit(1)
    }
    print("ALL PASSED")
    exit(0)
}

// Kick off the suite on the MainActor, then run the main loop to service it.
Task { @MainActor in await runSuite() }
RunLoop.main.run()
