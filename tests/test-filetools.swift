// test-filetools.swift — unit tests for the File / Document Q&A toolbox.
//
// Co-compiled with scripts/Core.swift + scripts/MacControl.swift +
// scripts/FileTools.swift. Asserts (PURE — no disk reads, no PDFKit, no real
// confirmation UI):
//   - path expansion (~, $HOME, ${HOME}, quote stripping),
//   - type dispatch by extension (text / pdf / rtf / unsupported / unknown),
//   - max_chars clamping + truncation/cap logic (reuses MarkdownSanitizer),
//   - confirm-gating: DENY with no confirmer, DENY on user-deny, the denylist is
//     honored, dry-run resolves to .approved(dryRun:true) WITHOUT a confirmer,
//     and a normal approve resolves through the confirmer seam,
//   - the binary-content heuristic used for extension-less files.
//
// The whole suite runs inside one `@MainActor` async entry point (kicked off and
// then serviced by the main RunLoop) so awaiting the @MainActor confirmer seam
// never deadlocks. A tiny `Logger` stub satisfies MacControl.swift / FileTools'
// logging (the real Logger lives in UIKitGlass.swift, which we don't link here).

import Foundation

// ----------------------------------------------------------------------------
// Logger stub (MacControl.swift / FileTools.swift reference Logger.shared)
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
// confirm-gated tool deterministically.
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

// ----------------------------------------------------------------------------
// The suite (on the MainActor, so awaiting the confirmer seam is safe).
// ----------------------------------------------------------------------------

@MainActor
func runSuite() async {
    // --- path expansion -----------------------------------------------------
    section("path expansion: ~, $HOME, ${HOME}, quotes")

    let home = "/Users/test"
    check(FileToolLogic.expandPath("~", home: home) == "/Users/test", "bare ~ → home")
    check(FileToolLogic.expandPath("~/Desktop/report.pdf", home: home) == "/Users/test/Desktop/report.pdf",
          "~/path expands")
    check(FileToolLogic.expandPath("$HOME/notes.txt", home: home) == "/Users/test/notes.txt",
          "$HOME/path expands")
    check(FileToolLogic.expandPath("${HOME}/notes.txt", home: home) == "/Users/test/notes.txt",
          "${HOME}/path expands")
    check(FileToolLogic.expandPath("/tmp/file.txt", home: home) == "/tmp/file.txt",
          "absolute path is unchanged")
    check(FileToolLogic.expandPath("  ~/x  ", home: home) == "/Users/test/x",
          "surrounding whitespace trimmed before expansion")
    check(FileToolLogic.expandPath("\"~/a b.txt\"", home: home) == "/Users/test/a b.txt",
          "surrounding double-quotes stripped")
    check(FileToolLogic.expandPath("'/tmp/q.txt'", home: home) == "/tmp/q.txt",
          "surrounding single-quotes stripped")
    // $HOME only rewrites when it LEADS the path (not mid-string).
    check(FileToolLogic.expandPath("/var/$HOME/x", home: home) == "/var/$HOME/x",
          "$HOME mid-string is NOT rewritten")
    // Home with a trailing slash normalizes (no double slash).
    check(FileToolLogic.expandPath("~/x", home: "/Users/test/") == "/Users/test/x",
          "trailing-slash home does not double the slash")

    // --- type dispatch ------------------------------------------------------
    section("classify: type dispatch by extension")

    check(FileToolLogic.classify(path: "/a/report.pdf") == .pdf, "pdf → .pdf")
    check(FileToolLogic.classify(path: "/a/REPORT.PDF") == .pdf, "case-insensitive: PDF → .pdf")
    check(FileToolLogic.classify(path: "/a/notes.txt") == .text, "txt → .text")
    check(FileToolLogic.classify(path: "/a/data.csv") == .text, "csv → .text")
    check(FileToolLogic.classify(path: "/a/config.json") == .text, "json → .text")
    check(FileToolLogic.classify(path: "/a/README.md") == .text, "md → .text")
    check(FileToolLogic.classify(path: "/a/Main.swift") == .text, "swift code → .text")
    check(FileToolLogic.classify(path: "/a/memo.rtf") == .rtf, "rtf → .rtf")
    check(FileToolLogic.classify(path: "/a/memo.rtfd") == .rtf, "rtfd → .rtf")
    check(FileToolLogic.classify(path: "/a/photo.png") == .unsupported("png"), "png → .unsupported")
    check(FileToolLogic.classify(path: "/a/movie.mp4") == .unsupported("mp4"), "mp4 → .unsupported")
    check(FileToolLogic.classify(path: "/a/sheet.xlsx") == .unsupported("xlsx"), "xlsx → .unsupported")
    check(FileToolLogic.classify(path: "/a/Makefile") == .unknown, "no extension → .unknown")
    check(FileToolLogic.classify(path: "/a/weirdfile.qzx") == .unknown, "unrecognized ext → .unknown")

    // The unsupported message never dumps bytes and names the type.
    let unsupMsg = FileToolLogic.unsupportedMessage(ext: "png")
    check(unsupMsg.hasPrefix("Error:") && unsupMsg.contains("png"),
          "unsupported message is an Error naming the type")

    // --- max_chars clamping + truncation ------------------------------------
    section("max_chars: clamping + truncation/cap")

    check(FileToolLogic.resolveMaxChars(nil) == FileToolLogic.defaultMaxChars,
          "nil → default cap (\(FileToolLogic.defaultMaxChars))")
    check(FileToolLogic.resolveMaxChars(0) == FileToolLogic.defaultMaxChars,
          "0 → default cap")
    check(FileToolLogic.resolveMaxChars(-5) == FileToolLogic.defaultMaxChars,
          "negative → default cap")
    check(FileToolLogic.resolveMaxChars(500) == 500, "in-range value passes through")
    check(FileToolLogic.resolveMaxChars(1_000_000) == FileToolLogic.hardMaxChars,
          "huge value clamped to hard ceiling (\(FileToolLogic.hardMaxChars))")

    // prepare(): a short doc is returned unchanged + not truncated.
    let short = "Hello world.\n\nThis is a small note."
    let (shortOut, shortTrunc) = FileToolLogic.prepare(short, maxChars: 20_000)
    check(!shortTrunc, "a short doc is not truncated")
    check(shortOut.contains("Hello world"), "a short doc's text is preserved")

    // prepare(): a long doc IS truncated and the result fits within the cap+marker.
    let para = String(repeating: "Lorem ipsum dolor sit amet. ", count: 50)  // ~1400 chars
    let longDoc = Array(repeating: para, count: 20).joined(separator: "\n\n")  // ~28k chars
    let (longOut, longTrunc) = FileToolLogic.prepare(longDoc, maxChars: 2000)
    check(longTrunc, "a long doc is truncated at the cap")
    check(longOut.count <= 2000 + 8, "truncated output is within the cap (+ ellipsis marker) (\(longOut.count))")

    // prepare() collapses excessive blank lines to at most 2 (MarkdownSanitizer
    // keeps up to 2 blank lines → at most 3 consecutive newlines) and rstrips
    // trailing spaces.
    let messy = "Line A\n\n\n\n\nLine B   \nLine C   "
    let (cleanOut, _) = FileToolLogic.prepare(messy, maxChars: 20_000)
    check(!cleanOut.contains("\n\n\n\n"), "prepare collapses 3+ blank lines to ≤2 (MarkdownSanitizer reuse)")
    check(!cleanOut.contains("Line B   "), "prepare strips trailing spaces on lines")

    // --- binary heuristic ---------------------------------------------------
    section("binary-content heuristic (for extension-less files)")

    check(!FileReader.looksBinary(Data("plain ascii text\n".utf8)), "plain text is not binary")
    check(FileReader.looksBinary(Data([0x00, 0x01, 0x02, 0x41, 0x42])), "a NUL byte → binary")
    let mostlyBinary = Data((0..<200).map { _ in UInt8(0x1B) })  // ESC control bytes
    check(FileReader.looksBinary(mostlyBinary), "mostly control bytes → binary")
    check(!FileReader.looksBinary(Data()), "empty data is not flagged binary")

    // --- confirm-gating -----------------------------------------------------
    section("read_document: confirm-gating")

    // (1) No confirmer, no dry-run → structurally denied; NOTHING read.
    let noGate = FileReadGate(confirmer: nil, dryRun: false)
    let denied = await noGate.confirm(path: "/tmp/x.txt")
    if case .denied(let r) = denied {
        check(r.lowercased().contains("not read") || r.lowercased().contains("no confirmation"),
              "no confirmer (no dry-run) → denied (\(r))")
    } else { check(false, "no confirmer should deny") }

    let toolNoConfirm = (try? await ReadDocumentTool(gate: noGate).invoke(JSONObject(["path": "/tmp/x.txt"]))) ?? "THREW"
    check(toolNoConfirm.lowercased().contains("not read") || toolNoConfirm.lowercased().contains("no confirmation"),
          "read_document with no confirmer denies (\(toolNoConfirm))")

    // (2) User denies → denied, file NOT read.
    let denyGate = FileReadGate(confirmer: FakeConfirmer(.deny), dryRun: false)
    let userDenied = await denyGate.confirm(path: "/tmp/x.txt")
    if case .denied(let r) = userDenied {
        check(r.lowercased().contains("denied") && r.lowercased().contains("not"),
              "user-deny → not read (\(r))")
    } else { check(false, "user deny should deny") }

    // (3) The MacControlGuard denylist is honored even with an APPROVING confirmer
    //     (a path crafted to look like a dangerous command is refused).
    let approveConfirmer = FakeConfirmer(.approve)
    let approveGate = FileReadGate(confirmer: approveConfirmer, dryRun: false)
    let dangerous = await approveGate.confirm(path: "/etc/x; sudo rm -rf /")
    if case .denied(let r) = dangerous {
        check(r.lowercased().contains("denylist"), "denylist blocks a dangerous-looking path even on approve (\(r))")
    } else {
        check(false, "denylist should have blocked a path containing 'sudo rm -rf /'")
    }

    // (4) A normal approve resolves through the confirmer seam to .approved(dryRun:false).
    let okApprove = await approveGate.confirm(path: "/tmp/report.txt")
    if case .approved(let p, let dr) = okApprove {
        check(p == "/tmp/report.txt" && !dr, "a safe approve resolves to .approved (not dry-run)")
    } else { check(false, "a safe approve should resolve to .approved") }
    check(approveConfirmer.lastRequest != nil, "the confirmer received a ConfirmationRequest (seam exercised)")
    check(approveConfirmer.lastRequest?.command.contains("/tmp/report.txt") == true,
          "the confirm card shows the RESOLVED path")

    // (5) Dry-run resolves to .approved(dryRun:true) WITHOUT any confirmer.
    let dryGate = FileReadGate(confirmer: nil, dryRun: true)
    let dryOut = await dryGate.confirm(path: "/tmp/report.txt")
    if case .approved(let p, let dr) = dryOut {
        check(p == "/tmp/report.txt" && dr, "dry-run with no confirmer → .approved(dryRun:true)")
    } else { check(false, "dry-run should resolve to .approved even with no confirmer") }

    // (6) Empty path is rejected before any gating.
    let emptyPath = await noGate.confirm(path: "   ")
    if case .denied(let r) = emptyPath {
        check(r.hasPrefix("Error:"), "empty path → Error before gating (\(r))")
    } else { check(false, "empty path should be denied") }
    let toolNoPath = (try? await ReadDocumentTool(gate: approveGate).invoke(JSONObject([:]))) ?? "THREW"
    check(toolNoPath.hasPrefix("Error:"), "read_document without 'path' errors")

    // --- tool spec ----------------------------------------------------------
    section("tool spec")

    let spec = ReadDocumentTool(gate: noGate).spec
    check(spec.name == "read_document", "tool name is read_document")
    check(spec.openAIToolDict["type"] as? String == "function",
          "read_document emits a valid OpenAI function-tool dict")
    if let fn = spec.openAIToolDict["function"] as? [String: Any],
       let params = fn["parameters"] as? [String: Any],
       let required = params["required"] as? [String] {
        check(required == ["path"], "schema requires only 'path'")
    } else { check(false, "schema should declare required: [path]") }

    // --- summary ------------------------------------------------------------
    print("")
    print("==========================================")
    print("test-filetools: \(testsRun - testsFailed)/\(testsRun) passed")
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
