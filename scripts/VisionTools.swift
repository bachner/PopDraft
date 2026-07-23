// VisionTools.swift — the `see_image` agent tool (vision / "let the agent SEE").
//
// Gives PopDraft's agent SIGHT: it can look at a local image, an image URL, or —
// most usefully — a SCREENSHOT of a website ("take a snapshot of a site to see
// its visual appearance"). Vision runs on the CHOSEN model — the ACTIVE
// provider/model (read live, so an in-chat model switch is respected) — via the
// same `chatCompletion` primitive the agent loop uses. If that model can't take
// images, the tool result says exactly which model refused and how to switch to
// a vision-capable one (the message is read by the agent AND the user).
//
// The pure pieces live in Core.swift and are unit-tested without a GUI:
//   - `VisionSource`   — parse the `source` arg (local path | https URL | `screenshot:<url>`)
//   - `VisionSupport`  — capability heuristic + Ollama `/api/show` capabilities
//                        parser + the unsupported-model message
//   - `VisionContent`  — OpenAI / Anthropic content-PART arrays + bitmap-format
//                        mapping (shared with the serializers in Agent.swift)
//
// This file (app target) does the IMPERATIVE work: capture the screenshot via the
// existing SSRF-gated WebEngine path, load/rasterize/encode image bytes as a
// size-capped `data:` URI, download URL images for backends that can't fetch
// URLs themselves, confirm-gate LOCAL paths through the MacControlConfirmer
// seam, and run the one-shot vision `chatCompletion`.

import Foundation
import AppKit

// MARK: - Image byte loading / data-URI encoding

/// Loads image bytes (from disk, a screenshot PNG, or a download) and encodes
/// them as a size-capped `data:` URI. Non-bitmap formats (SVG/PDF/TIFF/HEIC/…)
/// are RASTERIZED to PNG first — base64-ing raw SVG bytes with an image/png
/// label produces a payload no vision backend can decode.
enum VisionImageLoader {
    /// Hard cap on the raw image bytes we will base64-encode and send. Cloud
    /// vision APIs reject very large images and a big bitmap blows up the request;
    /// 8 MB is generous for a page screenshot or a photo.
    static let maxBytes = 8 * 1024 * 1024

    /// Longest raster side when converting a non-bitmap source. Vector sources
    /// with tiny intrinsic sizes (icon SVGs) are upscaled to stay legible.
    static let maxRasterSide: CGFloat = 2000
    static let minRasterSide: CGFloat = 512
    static let upscaleTargetSide: CGFloat = 1024

    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case notAnImage(String)
        case tooLarge(Int)
        case blockedURL(String)
        case fetchFailed(String)

        var description: String {
            switch self {
            case .notFound(let p): return "no readable file at \(p)"
            case .notAnImage(let p): return "the file at \(p) is not a readable image"
            case .tooLarge(let n): return "image is too large (\(n) bytes; cap is \(maxBytes))"
            case .blockedURL(let r): return "the image URL is not allowed (\(r))"
            case .fetchFailed(let r): return "couldn't download the image (\(r))"
            }
        }
    }

    /// A loader result: the `data:` URI to ship plus an optional caveat the tool
    /// must surface with the analysis (e.g. "only page 1 of the PDF was seen").
    struct EncodedImage {
        let uri: String
        let note: String?
    }

    /// Read `path` and return an `EncodedImage`. Real bitmap bytes (sniffed, not
    /// extension-trusted) pass through byte-for-byte with their true media type;
    /// anything else is rasterized to PNG. Throws a descriptive `LoadError`.
    static func dataURI(forPath path: String) throws -> EncodedImage {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw LoadError.notFound(path)
        }
        guard let data = fm.contents(atPath: path) else { throw LoadError.notFound(path) }
        return try dataURI(fromData: data, label: path)
    }

    /// Shared encode step. The pass-through decision AND the media type come
    /// from the BYTES (`VisionContent.sniffBitmapType`) — an extension can lie
    /// (a ".png" holding SVG must be rasterized, not shipped mislabeled). The
    /// size cap applies to the bytes actually shipped.
    static func dataURI(fromData data: Data, label: String) throws -> EncodedImage {
        if let media = VisionContent.sniffBitmapType(data) {
            guard data.count <= maxBytes else { throw LoadError.tooLarge(data.count) }
            return EncodedImage(uri: "data:\(media);base64,\(data.base64EncodedString())",
                                note: animatedGIFNote(data, media: media))
        }
        let (png, note) = try pngByRasterizing(data, label: label)
        guard png.count <= maxBytes else { throw LoadError.tooLarge(png.count) }
        return EncodedImage(uri: "data:image/png;base64,\(png.base64EncodedString())", note: note)
    }

    /// Backends decode only the first frame of an animated GIF — say so rather
    /// than let the model "describe" an animation it never saw.
    private static func animatedGIFNote(_ data: Data, media: String) -> String? {
        guard media == "image/gif",
              let rep = NSBitmapImageRep(data: data),
              let frames = rep.value(forProperty: .frameCount) as? Int, frames > 1 else { return nil }
        return "(animated GIF with \(frames) frames — only the first frame may have been analyzed)"
    }

    /// Render arbitrary NSImage-readable bytes (SVG, PDF, TIFF, HEIC, …) into a
    /// PNG bitmap. Longest side clamped to `maxRasterSide`; tiny vector sources
    /// are upscaled to `upscaleTargetSide` so icon-sized SVGs stay legible. Drawn
    /// on a white background — vector sources are often transparent, and VLMs
    /// read dark-on-white best. Returns the PNG plus a caveat for multi-page PDFs.
    private static func pngByRasterizing(_ data: Data, label: String) throws -> (Data, String?) {
        guard let image = NSImage(data: data) else { throw LoadError.notAnImage(label) }
        // Source dimensions in PIXELS: `NSImage.size` is POINTS and undershoots
        // for any rep carrying dpi metadata (a 300-dpi TIFF would rasterize 4×
        // too small, shrinking text below legibility). Use the largest bitmap
        // rep's pixel geometry; only vector-backed images (PDF/SVG — no bitmap
        // rep) fall back to the point size.
        let size: NSSize
        if let biggest = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            size = NSSize(width: biggest.pixelsWide, height: biggest.pixelsHigh)
        } else {
            size = image.size
        }
        guard size.width > 0, size.height > 0 else { throw LoadError.notAnImage(label) }
        var note: String?
        if let pdf = image.representations.compactMap({ $0 as? NSPDFImageRep }).first,
           pdf.pageCount > 1 {
            note = "(the PDF has \(pdf.pageCount) pages — only page 1 was analyzed)"
        }
        let longest = max(size.width, size.height)
        let target = longest > maxRasterSide ? maxRasterSide
                   : (longest < minRasterSide ? upscaleTargetSide : longest)
        let scale = target / longest
        let pixelW = max(1, Int((size.width * scale).rounded()))
        let pixelH = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw LoadError.notAnImage(label)
        }
        rep.size = NSSize(width: pixelW, height: pixelH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pixelW, height: pixelH).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: pixelW, height: pixelH),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw LoadError.notAnImage(label)
        }
        return (png, note)
    }

    /// Download an image URL and return it as a `data:` URI, for backends that
    /// can NOT fetch URLs themselves: llama.cpp, and Ollama incl. Ollama Cloud
    /// (verified live — ollama.com rejects `image_url` URLs with "image URLs are
    /// not currently supported, please use base64 encoded data instead").
    ///
    /// https only. SSRF: fail-closed host check (same rules as every WebEngine
    /// fetch) on the initial URL AND every redirect via `DownloadRedirectGuard`;
    /// size-capped; rasterized when the payload isn't a known bitmap.
    static func downloadAsDataURI(_ urlString: String) async throws -> EncodedImage {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            throw LoadError.blockedURL("https URLs only")
        }
        if let reason = WebEngine.ssrfBlockReasonPure(for: url) {
            throw LoadError.blockedURL(reason)
        }
        let redirectGuard = DownloadRedirectGuard(allow: { WebEngine.ssrfBlockReasonPure(for: $0) == nil })
        let session = URLSession(configuration: .ephemeral, delegate: redirectGuard, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LoadError.fetchFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LoadError.fetchFailed("HTTP \(status)")
        }
        guard data.count <= maxBytes else { throw LoadError.tooLarge(data.count) }
        return try dataURI(fromData: data, label: urlString)
    }
}

// MARK: - Ollama vision-capability probe

/// Asks the Ollama daemon/cloud itself whether the configured model can see:
/// `POST /api/show {"model": …}` → `capabilities` contains "vision". This is
/// AUTHORITATIVE (works on ollama.com and a local daemon, key optional); the
/// name heuristic in `VisionSupport` is only the fallback when the probe fails.
/// Results are cached per (endpoint, model) — capabilities don't change.
actor OllamaVisionProbe {
    static let shared = OllamaVisionProbe()
    private var cache: [String: Bool] = [:]

    /// true/false = probe answered; nil = probe failed (caller falls back).
    func modelSeesImages(config: LLMConfig) async -> Bool? {
        let key = "\(config.effectiveOllamaURL)|\(config.ollamaModel)"
        if let hit = cache[key] { return hit }
        guard let url = URL(string: "\(config.effectiveOllamaURL)/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.ollamaAPIKey.isEmpty {
            req.setValue("Bearer \(config.ollamaAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.ollamaModel])
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let caps = VisionSupport.parseOllamaCapabilities(data) else {
            return nil
        }
        let sees = caps.contains("vision")
        cache[key] = sees
        return sees
    }
}

/// Asks the MAIN llama-server itself whether it can take images: `GET /props` →
/// `modalities.vision`. Authoritative — a multimodal-NAMED gguf served without a
/// loaded --mmproj still can't see (PopDraft's managed server never loads one).
/// Also surfaces the served model's basename so the unsupported message names
/// what is ACTUALLY loaded (config.llamaModel goes stale when the user switches
/// to a user-downloaded gguf). No cache: localhost, answers in ms, and the
/// served model changes on restart. nil = unreachable/odd shape (caller falls
/// back to the name heuristic).
enum LlamaVisionProbe {
    static func probe(config: LLMConfig) async -> (vision: Bool, modelName: String?)? {
        guard let url = URL(string: "\(config.llamacppURL)/props") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let props = VisionSupport.parseLlamaProps(data) else { return nil }
        let base = (props.modelPath as NSString?)?.lastPathComponent
        let name = base.map { $0.lowercased().hasSuffix(".gguf") ? String($0.dropLast(5)) : $0 }
        return (props.vision, name)
    }
}

// MARK: - see_image tool

/// `see_image(source, question?)` — look at an image / website screenshot with
/// the ACTIVE model and return a textual description.
///
///  - `source` is one of:
///      * a local image file path           → confirm-gated, rasterized/base64'd, sent
///      * an `https:` image URL              → passed through to OpenAI/Claude (they
///        fetch server-side); downloaded + base64'd for llama.cpp/Ollama (they can't)
///      * `screenshot:<website-url>`         → SSRF-gated capture, then sent
///  - `question` (optional) focuses the analysis; defaults to a general description.
///
/// If the active model can NOT take images, it does NOT fail blankly: it returns
/// `VisionSupport.unsupportedModelMessage` naming the model and how to switch to
/// a vision-capable one — after still performing the (cheap, safe) screenshot
/// capture so the user sees the capture happened.
struct SeeImageTool: AgentTool, @unchecked Sendable {
    // `@unchecked Sendable`: like `MacControlGate`, `confirmer` is a
    // MainActor-isolated class only ever touched via `await
    // confirmer.requestConfirmation(...)` (i.e. on the MainActor). There is no
    // mutable shared state, so the storage is safe to cross actor boundaries
    // even though `any MacControlConfirmer` isn't `Sendable`.

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

        // The CHOSEN model, read LIVE (not the registry-time snapshot): the
        // in-chat model picker and Settings both rewrite config mid-session, and
        // vision must follow the model the user actually selected. Re-read again
        // before the capability gate — source resolution below can block on the
        // user (confirm dialog) for arbitrarily long.
        let live = AppConfig.load(dir: LLMConfig.configDir)

        // Resolve `source` → an ImageRef (+ a note describing what we captured,
        // + a format caveat like "only page 1 of the PDF" to ship with the result).
        var imageRef: ImageRef
        var captureNote = ""
        var formatNote: String?
        if let filename = ImageEmbed.filename(fromRef: rawSource) {
            // `pdimg:<hash>.<ext>` — a downloaded image_search result already in our
            // web-cache. Load it directly from disk (no confirm gate: the agent
            // fetched this web image itself; it isn't a sensitive local file).
            let imagesDir = ((LLMConfig.configDir as NSString)
                .appendingPathComponent("web-cache") as NSString)
                .appendingPathComponent("images")
            let path = (imagesDir as NSString).appendingPathComponent(filename)
            do {
                let encoded = try VisionImageLoader.dataURI(forPath: path)
                imageRef = ImageRef(source: encoded.uri)
                formatNote = encoded.note
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
                let encoded = try VisionImageLoader.dataURI(forPath: shot.path)
                imageRef = ImageRef(source: encoded.uri)
                formatNote = encoded.note
            } catch {
                return "\(captureNote)\nError: couldn't read the screenshot file: \(error)."
            }

        case .imageURL(let urlString):
            // OpenAI/Claude fetch image URLs server-side — pass straight through.
            // llama.cpp and Ollama (incl. Ollama Cloud) do NOT: they require
            // base64 data, so download + convert here (SSRF-gated, https only).
            if live.provider == "llamacpp" || live.provider == "ollama" {
                do {
                    let encoded = try await VisionImageLoader.downloadAsDataURI(urlString)
                    imageRef = ImageRef(source: encoded.uri)
                    formatNote = encoded.note
                } catch {
                    return "Error: \(error). The active backend can't fetch image URLs itself, and downloading it here failed."
                }
            } else {
                imageRef = ImageRef(source: urlString)
            }

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
                let encoded = try VisionImageLoader.dataURI(forPath: path)
                imageRef = ImageRef(source: encoded.uri)
                formatNote = encoded.note
            } catch {
                return "Error: \(error)."
            }
        }
        }

        // RE-READ the config: the confirm dialog / capture / download above can
        // take arbitrarily long, and the user may have switched models meanwhile.
        // The capability gate and the completion must judge the SAME model, so
        // this check sits immediately before the send.
        let fresh = AppConfig.load(dir: LLMConfig.configDir)
        if (fresh.provider == "llamacpp" || fresh.provider == "ollama"),
           imageRef.source.lowercased().hasPrefix("http") {
            // A mid-flight switch landed on a backend that can't fetch URLs —
            // convert the still-URL ref now instead of letting the send fail.
            do {
                let encoded = try await VisionImageLoader.downloadAsDataURI(imageRef.source)
                imageRef = ImageRef(source: encoded.uri)
                formatNote = encoded.note
            } catch {
                return "Error: \(error). The active backend can't fetch image URLs itself, and downloading it here failed."
            }
        }

        // Capability gate on the CHOSEN model. Ollama answers authoritatively via
        // /api/show and llama.cpp via /props (a multimodal NAME can't prove an
        // mmproj is loaded); a failed probe and the cloud APIs use the heuristic.
        var supportsVision: Bool
        var refusingModel = VisionSupport.activeModelName(config: fresh)
        if fresh.provider == "ollama",
           let probed = await OllamaVisionProbe.shared.modelSeesImages(config: LLMConfig(from: fresh)) {
            supportsVision = probed
        } else if fresh.provider == "llamacpp",
                  let probed = await LlamaVisionProbe.probe(config: LLMConfig(from: fresh)) {
            supportsVision = probed.vision
            if let served = probed.modelName, !served.isEmpty { refusingModel = served }
        } else {
            supportsVision = VisionSupport.modelSupportsVision(config: fresh)
        }
        guard supportsVision else {
            let msg = VisionSupport.unsupportedModelMessage(model: refusingModel, provider: fresh.provider)
            return captureNote.isEmpty ? msg : "\(captureNote)\n\n\(msg)"
        }

        // ONE-SHOT vision turn on the chosen model via the agent-loop primitive
        // (provider routing, keys, and image serialization all come with it).
        // Thinking is forced off — a thinking model would bury the description —
        // and the gate serializes parallel see_image calls (single-slot local
        // servers crash under concurrent multimodal; cloud free tiers cap
        // concurrency).
        let ask = question.isEmpty
            ? "Describe this image in detail. If it is a screenshot of a website, describe its visual appearance and layout, and note anything that looks broken or off."
            : question
        await LLMClient.visionGate.acquire()
        do {
            let turn = try await LLMClient.shared.chatCompletion(
                messages: [ChatMessage(role: "user", content: ask, images: [imageRef])],
                tools: nil, forceThinkingOff: true)
            await LLMClient.visionGate.release()
            let analysis = (turn.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var body = analysis.isEmpty ? "(the vision model returned no description)" : analysis
            if let note = formatNote { body += "\n\n\(note)" }
            return captureNote.isEmpty ? body : "\(captureNote)\n\n\(body)"
        } catch {
            await LLMClient.visionGate.release()
            let err = "Error: the vision call to the active model failed: \(error.localizedDescription)"
            return captureNote.isEmpty ? err : "\(captureNote)\n\(err)"
        }
    }
}

// MARK: - Vision tool self-registration

/// Self-registration of the vision tool. ALWAYS registered (no gate): even when
/// the active model can't take images, the tool must exist so the agent can
/// capture a screenshot and return the actionable switch-model guidance instead
/// of claiming it can't see. The capability check happens INSIDE the tool.
enum VisionTools {
    static func register() {
        AgentToolCatalog.register(BuiltinToolGroup(
            gate: { _ in true },
            make: { _, confirmer in
                [SeeImageTool(confirmer: confirmer as? (any MacControlConfirmer))]
            }))
    }
}
