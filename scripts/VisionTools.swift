// VisionTools.swift — the `see_image` agent tool (vision / "let the agent SEE").
//
// Gives PopDraft's agent SIGHT: it can look at a local image, an image URL, or —
// most usefully — a SCREENSHOT of a website ("take a snapshot of a site to see
// its visual appearance"). The pure pieces it leans on live in Core.swift and are
// unit-tested without a GUI:
//   - `VisionSource`   — parse the `source` arg (local path | https URL | `screenshot:<url>`)
//   - `VisionSupport`  — is the configured model vision-capable? + the no-vision message
//   - `VisionContent`  — build the OpenAI / Anthropic content-PART arrays (shared
//                        with the serializers in Agent.swift)
//
// This file (app target) does the IMPERATIVE work: capture the screenshot via the
// existing SSRF-gated WebEngine path, load/encode the bytes as a size-capped
// data: URI, confirm-gate LOCAL paths through the MacControlConfirmer seam, and
// run a ONE-SHOT vision `chatCompletion` on the vision-capable model.

import Foundation
import AppKit

// MARK: - Image byte loading / data-URI encoding

/// Loads image bytes (from disk or a screenshot PNG) and encodes them as a
/// size-capped `data:` URI. Kept tiny + dependency-light so the tool stays simple.
enum VisionImageLoader {
    /// Hard cap on the raw image bytes we will base64-encode and send. Cloud
    /// vision APIs reject very large images and a big bitmap blows up the request;
    /// 8 MB is generous for a page screenshot or a photo.
    static let maxBytes = 8 * 1024 * 1024

    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case notAnImage(String)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .notFound(let p): return "no readable file at \(p)"
            case .notAnImage(let p): return "the file at \(p) is not a readable image"
            case .tooLarge(let n): return "image is too large (\(n) bytes; cap is \(maxBytes))"
            }
        }
    }

    /// MIME type from a file extension (defaults to png). PNG/JPEG/GIF/WebP cover
    /// what both the screenshotter and the vision APIs accept.
    static func mediaType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Read `path` and return a `data:` URI, validating it is a real image and is
    /// under the size cap. Throws a descriptive `LoadError` otherwise.
    static func dataURI(forPath path: String) throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw LoadError.notFound(path)
        }
        guard let data = fm.contents(atPath: path) else { throw LoadError.notFound(path) }
        guard data.count <= maxBytes else { throw LoadError.tooLarge(data.count) }
        // Validate it actually decodes as an image (don't ship garbage to the API).
        guard NSImage(data: data) != nil else { throw LoadError.notAnImage(path) }
        let media = mediaType(forPath: path)
        return "data:\(media);base64,\(data.base64EncodedString())"
    }
}

// MARK: - see_image tool

/// `see_image(source, question?)` — look at an image / website screenshot with a
/// vision-capable model and return a textual description.
///
///  - `source` is one of:
///      * a local image file path           → confirm-gated, base64'd, sent
///      * an `https:` image URL              → passed to the vision model directly
///      * `screenshot:<website-url>`         → SSRF-gated capture, then sent
///  - `question` (optional) focuses the analysis; defaults to a general description.
///
/// If NO vision-capable model is configured, it does NOT fail blankly: it returns
/// a clear, actionable message (mirroring `suggest_integration`) explaining how to
/// add one — after still performing the (cheap, safe) screenshot capture so the
/// user sees the capture happened.
struct SeeImageTool: AgentTool, @unchecked Sendable {
    // `@unchecked Sendable`: like `MacControlGate`, `confirmer` is a
    // MainActor-isolated class only ever touched via `await
    // confirmer.requestConfirmation(...)` (i.e. on the MainActor); `config` is a
    // value type. There is no mutable shared state, so the storage is safe to
    // cross actor boundaries even though `any MacControlConfirmer` isn't `Sendable`.

    /// Snapshot of the config at registry-build time — used for the vision-capability
    /// check and to construct the one-shot vision message correctly.
    let config: AppConfig
    /// The confirm seam (LOCAL image paths are sensitive → ask first). URLs and
    /// screenshots don't need it (the web path is already SSRF-gated).
    let confirmer: (any MacControlConfirmer)?

    var spec: ToolSpec {
        ToolSpec(
            name: "see_image",
            description: "SEE an image or a website's visual appearance and describe it. "
                + "Use when the user asks what a site/page/image LOOKS like, whether a "
                + "layout is broken or correct, or to visually inspect something. "
                + "`source` is a local image file path, an https image URL, OR "
                + "\"screenshot:<website-url>\" to capture a live page and look at it. "
                + "To SEE a website, pass \"screenshot:<url>\" to THIS tool in a SINGLE "
                + "call — do NOT call web_screenshot first (this tool captures the page "
                + "itself, then looks at it). "
                + "Add a `question` to focus the analysis (e.g. \"is the nav bar broken?\").",
            parametersSchema: [
                "type": "object",
                "properties": [
                    "source": [
                        "type": "string",
                        "description": "A local image file path, an https image URL, or "
                            + "\"screenshot:<url>\" to screenshot a website and see it.",
                    ],
                    "question": [
                        "type": "string",
                        "description": "Optional: what to look for / describe about the image.",
                    ],
                ],
                "required": ["source"],
            ])
    }

    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        let rawSource = (d["source"] as? String) ?? ""
        guard !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'source' is required (a local image path, an https image URL, or \"screenshot:<url>\")."
        }
        let question = (d["question"] as? String) ?? ""

        // Resolve `source` → an ImageRef (+ a note describing what we captured).
        let imageRef: ImageRef
        var captureNote = ""
        if let filename = ImageEmbed.filename(fromRef: rawSource) {
            // `pdimg:<hash>.<ext>` — a downloaded image_search result already in our
            // web-cache. Load it directly from disk (no confirm gate: the agent
            // fetched this web image itself; it isn't a sensitive local file).
            let imagesDir = ((LLMConfig.configDir as NSString)
                .appendingPathComponent("web-cache") as NSString)
                .appendingPathComponent("images")
            let path = (imagesDir as NSString).appendingPathComponent(filename)
            do {
                imageRef = ImageRef(source: try VisionImageLoader.dataURI(forPath: path))
            } catch {
                return "Error: couldn't read the cached image (\(filename)). It may have been evicted — re-run image_search. (\(error))"
            }
        } else {
        switch VisionSource.parse(rawSource) {
        case .screenshot(let urlString):
            guard let url = URL(string: urlString),
                  let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                return "Error: \"screenshot:\" must be followed by an absolute http(s) URL."
            }
            // SSRF-gated capture via the existing WebEngine screenshot path.
            let shot: ShotResult
            do {
                shot = try await WebEngine.shared.screenshot(url, fullPage: false)
            } catch {
                return "Error: couldn't screenshot \(urlString): \(error.localizedDescription)"
            }
            captureNote = "Captured a screenshot of \(shot.finalURL) (\(shot.width)×\(shot.height)px) → \(shot.path)."
            do {
                imageRef = ImageRef(source: try VisionImageLoader.dataURI(forPath: shot.path))
            } catch {
                return "\(captureNote)\nError: couldn't read the screenshot file: \(error)."
            }

        case .imageURL(let urlString):
            // Cloud vision models fetch the URL themselves — pass it straight through.
            imageRef = ImageRef(source: urlString)

        case .localPath(let path):
            // LOCAL paths are sensitive → confirm-gate before reading the file.
            guard let confirmer = confirmer else {
                return "Error: reading a local image needs a confirmation UI, which isn't available here. It was NOT read."
            }
            let req = ConfirmationRequest(
                id: UUID().uuidString, kind: .shell,
                command: "see_image \(path)",
                explanation: "Read and look at the local image at \(path).")
            switch await confirmer.requestConfirmation(req) {
            case .deny:
                return "The user declined to share the local image. It was NOT read."
            case .approve, .edit:
                break
            }
            do {
                imageRef = ImageRef(source: try VisionImageLoader.dataURI(forPath: path))
            } catch {
                return "Error: \(error)."
            }
        }
        }

        // Capability gate: the DEDICATED vision server (VisionServerManager, :10820)
        // handles vision regardless of the main provider/model — it's usable
        // whenever its model files are installed. If they're not, don't fail
        // blankly: return an actionable message (with the capture note when we did
        // capture a screenshot, so the user sees that part worked).
        guard VisionServerManager.isAvailable else {
            let msg = "No local vision model installed. Download Qwen3.5-0.8B (model + mmproj) to ~/.popdraft/models/."
            return captureNote.isEmpty ? msg : "\(captureNote)\n\n\(msg)"
        }

        // ONE-SHOT vision turn on the DEDICATED vision server (:10820), independent
        // of the global provider/config. The instruction is carried in the single
        // user message alongside the image (thinking is force-disabled inside
        // visionCompletion — the VL model is a thinking model).
        let ask = question.isEmpty
            ? "Describe this image in detail. If it is a screenshot of a website, describe its visual appearance and layout, and note anything that looks broken or off."
            : question
        do {
            let analysis = try await LLMClient.shared.visionCompletion(text: ask, images: [imageRef])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = analysis.isEmpty ? "(the vision model returned no description)" : analysis
            return captureNote.isEmpty ? body : "\(captureNote)\n\n\(body)"
        } catch {
            let err = "Error: the vision model call failed: \(error.localizedDescription)"
            return captureNote.isEmpty ? err : "\(captureNote)\n\(err)"
        }
    }
}

// MARK: - Vision tool self-registration

/// Self-registration of the vision tool. ALWAYS registered (no gate): even when
/// no vision-capable model is configured, the tool must exist so the agent can
/// capture a screenshot and return the actionable "add a vision model" guidance
/// instead of claiming it can't see. The capability check happens INSIDE the tool.
enum VisionTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { _ in true },
            make: { config, confirmer in
                [SeeImageTool(config: config, confirmer: confirmer as? (any MacControlConfirmer))]
            }))
    }
}
