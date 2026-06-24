// PopDraft - File / Document Q&A Toolbox
//
// A self-contained agent tool that lets the assistant READ a local document the
// user points at (a path) and return its text content so the model can
// summarize or answer questions about it. It pairs with the always-on text
// tools (`summarize_text` / `extract_text`): the agent reads the file with
// `read_document`, then summarizes / extracts from the returned text.
//
// Built by co-compiling with the other scripts/*.swift sources:
//   swiftc -O scripts/*.swift \
//       -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation
//
// Tool (an `AgentTool`, self-registered via `AgentToolCatalog`):
//   - read_document — read a local file the user named and return its text.
//                     CONFIRM-GATED (reading an arbitrary local path is sensitive).
//
// Reading a path the user names is sensitive (it could be any file on disk), so
// `read_document` routes through the SAME confirm seam as run_shell /
// LocalActionTools' mutating tools (`MacControlConfirmer`): it PROPOSES the
// resolved path, the user Approves / Edits / Denies, and with NO confirmer
// (headless / no UI) it structurally denies — UNLESS Mac-control dry-run mode is
// on, in which case it records "would read" and still reads (a read has no side
// effects, so the dry-run path lets the headless eval prove the flow end to end).
//
// File-type handling:
//   - plain text / code / markdown / json / csv / xml / yaml / … → read directly
//     (UTF-8, lenient: falls back through encodings so odd files still decode).
//   - PDF  → PDFKit (`PDFDocument(url:).string`).
//   - RTF / RTFD → NSAttributedString.
//   - unknown / binary → a clear "unsupported type" message (never dumps bytes).
//
// Output is capped (`max_chars`, default ~20k) and cleaned/truncated with the
// SAME helpers `extract_text` uses (`MarkdownSanitizer` to collapse whitespace
// and truncate on a sensible boundary), and truncation is noted in the result.

import Cocoa
import PDFKit

// MARK: - Pure logic (unit-tested; no filesystem / PDFKit side effects)

/// Pure, deterministic logic for the document tool. Kept free of any filesystem
/// or PDFKit side effects so `tests/test-filetools.swift` can assert path
/// expansion, type dispatch by extension, and the cap/truncation behavior
/// without ever touching disk.
enum FileToolLogic {
    /// Default character cap for a document's returned text. Generous enough to
    /// summarize a real report, small enough to not blow up the model context.
    static let defaultMaxChars = 20_000
    /// A hard ceiling so a huge `max_chars` can't be used to flood the context.
    static let hardMaxChars = 60_000

    /// How a path's extension is to be read.
    enum Kind: Equatable {
        case text     // plain text / code / markdown / json / csv / … (UTF-8)
        case pdf      // PDFKit
        case rtf      // NSAttributedString (rtf / rtfd)
        case unsupported(String)  // a known-binary/opaque type we refuse to dump
        case unknown  // no extension / unrecognized — TRY as text (lenient)
    }

    /// Extensions we read directly as UTF-8 text (code, config, data, prose).
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "rst",
        "json", "ndjson", "jsonl", "csv", "tsv", "xml", "yaml", "yml", "toml",
        "ini", "cfg", "conf", "env", "properties", "log",
        "html", "htm", "css", "tex",
        // common code
        "swift", "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "php",
        "pl", "sh", "bash", "zsh", "fish", "sql", "r", "lua", "scala", "groovy",
        "dart", "ex", "exs", "clj", "cljs", "vue", "svelte", "gradle", "make",
        "mk", "cmake", "dockerfile", "gitignore", "patch", "diff",
    ]

    /// Extensions we KNOW are binary/opaque and must refuse to dump as bytes.
    static let unsupportedExtensions: Set<String> = [
        // images
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "icns", "ico", "svgz",
        // audio / video
        "mp3", "wav", "aac", "flac", "ogg", "m4a", "aiff",
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "wmv",
        // archives / packages / binaries
        "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso",
        "exe", "dll", "so", "dylib", "o", "a", "bin", "class", "jar", "wasm",
        // office / opaque docs we don't (yet) parse
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "odt", "ods", "odp", "epub",
        // databases / fonts
        "sqlite", "db", "ttf", "otf", "woff", "woff2",
    ]

    /// Expand a leading `~` or `$HOME`/`${HOME}` and strip surrounding whitespace
    /// and quotes the model sometimes wraps a path in. `home` is injectable so a
    /// test can assert expansion without depending on the runner's environment.
    static func expandPath(_ raw: String, home: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a single matched pair of surrounding quotes.
        if p.count >= 2 {
            let first = p.first!, last = p.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                p = String(p.dropFirst().dropLast())
            }
        }
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if p == "~" { return h }
        if p.hasPrefix("~/") { return h + String(p.dropFirst(1)) }
        // $HOME / ${HOME} only when it leads the path (don't rewrite mid-string).
        if p.hasPrefix("${HOME}") { return h + String(p.dropFirst("${HOME}".count)) }
        if p.hasPrefix("$HOME") { return h + String(p.dropFirst("$HOME".count)) }
        return p
    }

    /// Classify a path by its (lowercased) extension into a read `Kind`.
    static func classify(path: String) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .unknown }
        if ext == "pdf" { return .pdf }
        if ext == "rtf" || ext == "rtfd" { return .rtf }
        if textExtensions.contains(ext) { return .text }
        if unsupportedExtensions.contains(ext) { return .unsupported(ext) }
        return .unknown
    }

    /// Clamp a requested `max_chars` into a sane [1, hardMax] range, defaulting
    /// when nil / non-positive.
    static func resolveMaxChars(_ requested: Int?) -> Int {
        guard let r = requested, r > 0 else { return defaultMaxChars }
        return min(r, hardMaxChars)
    }

    /// Clean + cap a document's raw text exactly like `extract_text` does its
    /// inputs: collapse runs of whitespace/blank lines, then truncate on a
    /// paragraph/sentence boundary at `maxChars`. Returns (text, wasTruncated).
    static func prepare(_ raw: String, maxChars: Int) -> (text: String, truncated: Bool) {
        let cleaned = MarkdownSanitizer.collapseWhitespace(raw)
        return MarkdownSanitizer.truncate(cleaned, maxChars: maxChars)
    }

    /// The proposed-command string shown on the confirm card / dry-run line.
    static func proposedCommand(readPath path: String) -> String {
        return "Read the document at: \(path)"
    }

    /// The model-facing message for a type we refuse to dump as raw bytes.
    static func unsupportedMessage(ext: String) -> String {
        return "Error: '\(ext)' files are a binary/opaque type that read_document "
            + "cannot extract text from (it would be unreadable bytes). Supported: "
            + "plain text, code, markdown, json, csv, PDF, and RTF. If this is a "
            + "document with text, export it to PDF or a text format first."
    }
}

// MARK: - Confirm seam (reuses the run_shell / LocalActionTools confirmer)

/// The confirm gate for `read_document`. Reading a user-named path is sensitive,
/// so it routes through the SAME `MacControlConfirmer` seam as run_shell and the
/// mutating LocalActionTools: it PROPOSES the resolved path; the user
/// Approves / Edits / Denies; only on approval does the read happen. With NO
/// confirmer (headless / no UI) it structurally denies — UNLESS Mac-control
/// dry-run mode is on, where it records "would read" and proceeds (a read is
/// side-effect-free, so the dry-run path lets the headless eval exercise the
/// full read → summarize flow without a UI tap).
///
/// Kept in this file (rather than reusing LocalActionTools' `LocalActionGate`) so
/// the unit test co-compiles with Core + MacControl + FileTools alone.
struct FileReadGate: @unchecked Sendable {
    // `@unchecked Sendable`: `confirmer` is a MainActor-isolated object only ever
    // touched via `await …requestConfirmation` (on the MainActor); `dryRun` is a
    // value. No other mutable shared state. Mirrors LocalActionGate's reasoning.
    let confirmer: (any MacControlConfirmer)?
    let dryRun: Bool

    enum Outcome {
        case approved(path: String, dryRun: Bool)  // read it (path may have been edited)
        case denied(String)                        // model-facing reason; nothing read
    }

    /// Run the denylist precheck + confirm round-trip for reading `path`.
    func confirm(path: String) async -> FileReadGate.Outcome {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .denied("Error: 'path' is required.") }

        let command = FileToolLogic.proposedCommand(readPath: trimmed)

        // Defense in depth: even though we only READ, run the proposed action
        // through the shared denylist so a path crafted to look like a dangerous
        // command (or pointed at a device node) is refused before being offered.
        if let reason = MacControlGuard.denialReason(command) {
            Logger.shared.error("[read_document] DENIED by safety denylist (\(reason)) :: \(trimmed)")
            return .denied("Error: this action is blocked by the safety denylist (\(reason)). The file was NOT read.")
        }

        // Headless dry-run (the eval): record "would read" and READ anyway — a
        // read has no side effects, so this proves the flow without a UI tap.
        if dryRun {
            Logger.shared.info("[read_document] DRY-RUN would read: \(trimmed)")
            return .approved(path: trimmed, dryRun: true)
        }

        // No confirmer at all → structurally deny (cannot read without a UI tap),
        // exactly like run_shell / the mutating local actions in headless mode.
        guard let confirmer = confirmer else {
            Logger.shared.info("[read_document] no confirmer; refusing to read: \(trimmed)")
            return .denied("Error: no confirmation UI is available, so the file was NOT read.")
        }

        // Reuse the run_shell confirm card (kind .shell — same Approve/Edit/Deny UI).
        let req = ConfirmationRequest(
            id: UUID().uuidString, kind: .shell, command: command,
            explanation: "Read this local document and use its text to answer.")
        let decision = await confirmer.requestConfirmation(req)
        switch decision {
        case .deny:
            Logger.shared.info("[read_document] user DENIED: \(trimmed)")
            return .denied("The user denied reading this file. It was NOT read. Do not retry it; ask the user what they'd prefer or continue without it.")
        case .approve:
            Logger.shared.info("[read_document] user APPROVED: \(trimmed)")
            return .approved(path: trimmed, dryRun: false)
        case .edit(let edited):
            // The user may edit the card; the card shows "Read the document at: <path>".
            // Pull the path back out of an edited command, else treat the edit as
            // the path itself. Re-apply the denylist either way.
            let e = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "Read the document at: "
            let editedPath = e.hasPrefix(prefix) ? String(e.dropFirst(prefix.count)) : e
            let finalPath = editedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = MacControlGuard.denialReason(FileToolLogic.proposedCommand(readPath: finalPath)) {
                Logger.shared.error("[read_document] edited path DENIED (\(reason)) :: \(finalPath)")
                return .denied("Error: the edited path is blocked by the safety denylist (\(reason)). The file was NOT read.")
            }
            Logger.shared.info("[read_document] user EDITED+APPROVED: \(finalPath)")
            return .approved(path: finalPath.isEmpty ? trimmed : finalPath, dryRun: false)
        }
    }
}

// MARK: - File reading (side effects: disk + PDFKit + AppKit)

/// Reads a local file's text content. Isolated from the pure logic above so the
/// unit test never touches disk / PDFKit. Returns the extracted text or an
/// error message string (never raw bytes for an unsupported type).
enum FileReader {
    /// The outcome of a read: either extracted `text`, or a model-facing
    /// `failure` message (never raw bytes). A plain two-case result rather than
    /// `Result<…>` because the failure carries a display String, not an `Error`.
    enum Outcome {
        case text(String)
        case failure(String)
    }

    /// Read `path` (already expanded + approved) into text per its `Kind`.
    static func read(path: String, kind: FileToolLogic.Kind) -> FileReader.Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .failure("Error: no file exists at '\(path)'. Check the path (use an absolute path or one starting with ~).")
        }
        if isDir.boolValue {
            return .failure("Error: '\(path)' is a directory, not a file. Name a specific document to read.")
        }
        guard fm.isReadableFile(atPath: path) else {
            return .failure("Error: '\(path)' is not readable (permission denied).")
        }
        let url = URL(fileURLWithPath: path)

        switch kind {
        case .unsupported(let ext):
            return .failure(FileToolLogic.unsupportedMessage(ext: ext))

        case .pdf:
            guard let doc = PDFDocument(url: url) else {
                return .failure("Error: '\(path)' could not be opened as a PDF (it may be corrupt or encrypted).")
            }
            let text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure("The PDF at '\(path)' has \(doc.pageCount) page(s) but no extractable text (it is likely scanned images, not text). OCR would be needed.")
            }
            return .text(text)

        case .rtf:
            // RTF / RTFD → attributed string → plain text.
            if let attr = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
                return .text(attr.string)
            }
            // RTFD bundles (directory-backed) need the rtfd document type.
            if let attr = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil) {
                return .text(attr.string)
            }
            return .failure("Error: '\(path)' could not be read as RTF.")

        case .text, .unknown:
            // Lenient decode: UTF-8 first, then common fallbacks. For `.unknown`
            // (no/unrecognized extension) we ALSO guard against binary content so
            // we don't dump bytes for an unlabeled binary file.
            guard let data = try? Data(contentsOf: url) else {
                return .failure("Error: '\(path)' could not be read.")
            }
            if kind == .unknown, looksBinary(data) {
                return .failure("Error: '\(path)' appears to be a binary file (no readable text). read_document only returns text from text/code/markdown/json/csv, PDF, and RTF documents.")
            }
            for enc in [String.Encoding.utf8, .isoLatin1, .windowsCP1252, .ascii] {
                if let s = String(data: data, encoding: enc) { return .text(s) }
            }
            // Last resort: lossy UTF-8 (replaces invalid bytes) so a mostly-text
            // file with a few bad bytes still reads.
            let lossy = String(decoding: data, as: UTF8.self)
            return .text(lossy)
        }
    }

    /// Heuristic: a file is "binary" if its first chunk contains a NUL byte or a
    /// high fraction of non-text control bytes. Used only for extension-less /
    /// unrecognized files so we never dump raw bytes to the model.
    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8000)
        if sample.isEmpty { return false }
        var nonText = 0
        for b in sample {
            if b == 0 { return true }  // a NUL byte → definitely binary
            // Allow tab(9), LF(10), CR(13), and the printable range; count the rest.
            let isText = b == 9 || b == 10 || b == 13 || (b >= 32 && b != 127)
            if !isText { nonText += 1 }
        }
        return Double(nonText) / Double(sample.count) > 0.30
    }
}

// MARK: - read_document tool (confirm-gated)

/// `read_document` — read a local file the user named and return its text so the
/// model can summarize / answer questions about it. Reading an arbitrary local
/// path is sensitive, so it is CONFIRM-GATED through the run_shell seam.
struct ReadDocumentTool: AgentTool {
    let gate: FileReadGate
    var spec: ToolSpec {
        ToolSpec(
            name: "read_document",
            description: "Read a local document the user names (by file PATH) and return its "
                + "text content, so you can summarize it or answer questions about it. "
                + "Supports plain text, code, markdown, json, csv, PDF (via PDFKit), and RTF. "
                + "Use this whenever the user refers to a file on their Mac (e.g. "
                + "'summarize ~/Desktop/report.pdf' or 'what does /tmp/notes.txt say'). The "
                + "user must Approve reading the file before it runs. After reading, you can "
                + "pass the returned text to summarize_text / extract_text, or answer directly.",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute path to the file (a leading ~ or $HOME is expanded), e.g. '~/Desktop/report.pdf' or '/tmp/notes.txt'.",
                    ],
                    "max_chars": [
                        "type": "integer",
                        "description": "Optional cap on returned characters (default 20000). Large documents are truncated on a paragraph boundary and the truncation is noted.",
                    ],
                ],
                "required": ["path"],
            ])
    }

    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        guard let rawPath = (d["path"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return "Error: 'path' is required."
        }
        let maxChars = FileToolLogic.resolveMaxChars(intArg(d["max_chars"]))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = FileToolLogic.expandPath(rawPath, home: home)

        // Confirm-gate on the RESOLVED path (so the user sees exactly what's read).
        let outcome = await gate.confirm(path: expanded)
        switch outcome {
        case .denied(let reason):
            return reason
        case .approved(let approvedPath, let dryRun):
            // The user may have approved an edited path; re-expand it.
            let finalPath = FileToolLogic.expandPath(approvedPath, home: home)
            let kind = FileToolLogic.classify(path: finalPath)
            switch FileReader.read(path: finalPath, kind: kind) {
            case .failure(let message):
                return message
            case .text(let rawText):
                let (text, truncated) = FileToolLogic.prepare(rawText, maxChars: maxChars)
                if text.isEmpty {
                    return "The document at '\(finalPath)' contains no readable text."
                }
                let header = dryRun
                    ? "[dry-run] Read \(finalPath) (\(text.count) chars\(truncated ? ", truncated" : "")):\n\n"
                    : "Document: \(finalPath) (\(text.count) chars\(truncated ? ", truncated to fit" : "")):\n\n"
                let footer = truncated
                    ? "\n\n[Note: the document was truncated to ~\(maxChars) characters. Ask to read more, or use extract_text on the returned text for a specific section.]"
                    : ""
                return header + text + footer
            }
        }
    }

    /// Tolerantly read an integer argument that may arrive as Int, NSNumber, or
    /// a numeric String (llama.cpp sometimes stringifies numbers).
    private func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return i }
        return nil
    }
}

// MARK: - Self-registration

/// Self-registration of the file/document toolbox into the agent tool catalog.
///
/// `read_document` lives in ONE always-on group (`gate: { _ in true }`): it is
/// safe to register unconditionally because it routes through `FileReadGate` →
/// the SAME `MacControlConfirmer` seam as run_shell. With no confirmer (headless)
/// every read structurally denies (unless Mac-control dry-run is on), and with a
/// confirmer nothing is read until the user Approves.
///
/// Registering it in `make` regardless of confirmer means
/// `AgentToolCatalog.reservedNames` covers `read_document`, so no MCP server can
/// shadow it.
enum FileTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { _ in true },
            make: { config, confirmer in
                let c = confirmer as? (any MacControlConfirmer)
                let gate = FileReadGate(confirmer: c, dryRun: config.agentSettings.macControlDryRun)
                return [ReadDocumentTool(gate: gate)]
            }))
    }
}
