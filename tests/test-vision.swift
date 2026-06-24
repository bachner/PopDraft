// test-vision.swift — unit tests for vision (image attachments / `see_image`).
//
// Co-compiled with scripts/Core.swift ONLY (pure logic; NO AppKit, NO WebKit, NO
// network). Asserts:
//   - ChatMessage carries `images` and round-trips on disk; OLD sessions (no
//     `images` key) decode unchanged (backward-compat).
//   - The serializer DECISION: a user message WITHOUT images uses the bare-string
//     fast-path (content is a String, byte-identical to before); WITH images it
//     emits a content-PART array (OpenAI image_url / Anthropic image blocks).
//   - VisionContent.openAIParts / anthropicParts shapes (incl. data-URI → base64,
//     http URL → url source).
//   - VisionSupport.modelSupportsVision per provider/model (true for gpt-4o /
//     Claude Sonnet/Opus; FALSE for the default local 4B and gpt-3.5).
//   - VisionSource.parse for local path / https URL / `screenshot:<url>` prefix.
//   - The no-vision-model capability message is actionable (mentions gpt-4o,
//     Claude Sonnet, Settings → Models, gemma-3n).
//
// Run via tests/run-tests.sh (staged as main.swift alongside Core.swift).

import Foundation

// ----------------------------------------------------------------------------
// Tiny test harness
// ----------------------------------------------------------------------------

var testsRun = 0
var testsFailed = 0

func check(_ condition: Bool, _ message: String) {
    testsRun += 1
    if !condition { testsFailed += 1; print("  [FAIL] \(message)") }
    else { print("  [ok]   \(message)") }
}

func section(_ name: String) { print(""); print("— \(name)") }

// A tiny 1x1 PNG as a data URI, for the data-URI splitting test.
let onePxPNGDataURI =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

// ----------------------------------------------------------------------------
// Replicate the serializer DECISION so the fast-path is asserted without linking
// the (private) serializers. This mirrors EXACTLY the branch added to
// openAIMessagesJSON / chatCompletionClaude in Agent.swift.
// ----------------------------------------------------------------------------

/// OpenAI: a user turn's `content` field — String (fast-path) or parts array.
func openAIUserContent(_ m: ChatMessage) -> Any {
    if let images = m.images, !images.isEmpty {
        return VisionContent.openAIParts(text: m.content, images: images)
    }
    return m.content
}

/// Anthropic: a user turn's `content` field — String (fast-path) or blocks array.
func anthropicUserContent(_ m: ChatMessage) -> Any {
    if let images = m.images, !images.isEmpty {
        return VisionContent.anthropicParts(text: m.content, images: images)
    }
    return m.content
}

// ----------------------------------------------------------------------------

print("=== Vision tests ===")

// ---- ImageRef classification ----
section("ImageRef.kind classification")
check(ImageRef(source: "data:image/png;base64,AAAA").kind == .dataURI, "data: URI → .dataURI")
check(ImageRef(source: "https://example.com/x.png").kind == .httpURL, "https URL → .httpURL")
check(ImageRef(source: "http://example.com/x.png").kind == .httpURL, "http URL → .httpURL")
check(ImageRef(source: "/Users/me/x.png").kind == .localPath, "absolute path → .localPath")
check(ImageRef(source: "relative/x.jpg").kind == .localPath, "relative path → .localPath")

// ---- ChatMessage Codable round-trip + backward-compat ----
section("ChatMessage images Codable")
do {
    let msg = ChatMessage(role: "user", content: "look at this",
                          images: [ImageRef(source: "https://e.com/a.png", detail: "high")])
    let data = try JSONEncoder().encode(msg)
    let back = try JSONDecoder().decode(ChatMessage.self, from: data)
    check(back.images?.count == 1, "encodes + decodes 1 image")
    check(back.images?.first?.source == "https://e.com/a.png", "image source round-trips")
    check(back.images?.first?.detail == "high", "image detail round-trips")
    check(back.content == "look at this", "content round-trips")
} catch { check(false, "round-trip threw: \(error)") }

do {
    // OLD session JSON: no `images` key at all → must decode with images == nil.
    let oldJSON = #"{"id":"x","role":"user","content":"hi","createdAt":1.0}"#
    let back = try JSONDecoder().decode(ChatMessage.self, from: Data(oldJSON.utf8))
    check(back.images == nil, "old session (no images key) decodes with images == nil")
    check(back.content == "hi", "old session content preserved")
} catch { check(false, "old-session decode threw: \(error)") }

// ---- Serializer fast-path (NO images → bare string) ----
section("Serializer fast-path (no images → bare string, zero regression)")
do {
    let plain = ChatMessage(role: "user", content: "translate this")
    check(openAIUserContent(plain) as? String == "translate this",
          "OpenAI: no-image user content is the bare String (fast-path)")
    check(anthropicUserContent(plain) as? String == "translate this",
          "Anthropic: no-image user content is the bare String (fast-path)")

    // An EMPTY images array must ALSO take the fast-path (not an empty parts list).
    let emptyImgs = ChatMessage(role: "user", content: "hello", images: [])
    check(openAIUserContent(emptyImgs) as? String == "hello",
          "OpenAI: empty images[] still uses the bare-String fast-path")
    check(anthropicUserContent(emptyImgs) as? String == "hello",
          "Anthropic: empty images[] still uses the bare-String fast-path")
}

// ---- OpenAI content parts WITH images ----
section("OpenAI content parts (with images)")
do {
    let m = ChatMessage(role: "user", content: "what is this?",
                        images: [ImageRef(source: "https://e.com/a.png", detail: "high")])
    guard let parts = openAIUserContent(m) as? [[String: Any]] else {
        check(false, "OpenAI with-image content is a parts array"); exit(1)
    }
    check(parts.count == 2, "OpenAI: text part + 1 image part")
    check(parts[0]["type"] as? String == "text", "OpenAI: first part is text")
    check(parts[0]["text"] as? String == "what is this?", "OpenAI: text carried through")
    check(parts[1]["type"] as? String == "image_url", "OpenAI: second part is image_url")
    let iu = parts[1]["image_url"] as? [String: Any]
    check(iu?["url"] as? String == "https://e.com/a.png", "OpenAI: image_url.url set")
    check(iu?["detail"] as? String == "high", "OpenAI: image_url.detail set")

    // No text → only the image part (no empty text block).
    let noText = ChatMessage(role: "user", content: "", images: [ImageRef(source: "https://e.com/b.png")])
    let p2 = openAIUserContent(noText) as? [[String: Any]]
    check(p2?.count == 1, "OpenAI: empty text → only the image part")
    check(p2?.first?["type"] as? String == "image_url", "OpenAI: that part is image_url")
}

// ---- Anthropic content blocks WITH images ----
section("Anthropic content blocks (with images)")
do {
    // https URL → {type:image, source:{type:url, url}}
    let urlMsg = ChatMessage(role: "user", content: "describe",
                             images: [ImageRef(source: "https://e.com/a.png")])
    let ublocks = anthropicUserContent(urlMsg) as? [[String: Any]]
    check(ublocks?.count == 2, "Anthropic: text block + 1 image block (url)")
    check(ublocks?[0]["type"] as? String == "text", "Anthropic: first block is text")
    let usrc = ublocks?[1]["source"] as? [String: Any]
    check(ublocks?[1]["type"] as? String == "image", "Anthropic: second block is image")
    check(usrc?["type"] as? String == "url", "Anthropic: url image uses source.type=url")
    check(usrc?["url"] as? String == "https://e.com/a.png", "Anthropic: source.url set")

    // data: URI → {type:image, source:{type:base64, media_type, data}}
    let dataMsg = ChatMessage(role: "user", content: "",
                              images: [ImageRef(source: onePxPNGDataURI)])
    let dblocks = anthropicUserContent(dataMsg) as? [[String: Any]]
    check(dblocks?.count == 1, "Anthropic: empty text + data image → 1 image block")
    let dsrc = dblocks?[0]["source"] as? [String: Any]
    check(dsrc?["type"] as? String == "base64", "Anthropic: data URI uses source.type=base64")
    check(dsrc?["media_type"] as? String == "image/png", "Anthropic: media_type parsed from data URI")
    check((dsrc?["data"] as? String)?.hasPrefix("iVBOR") == true, "Anthropic: base64 payload extracted")
}

// ---- data URI parsing ----
section("VisionContent.parseDataURI")
do {
    let parsed = VisionContent.parseDataURI(onePxPNGDataURI)
    check(parsed?.media == "image/png", "parses media type")
    check(parsed?.base64.hasPrefix("iVBOR") == true, "parses base64 payload")
    check(VisionContent.parseDataURI("https://e.com/x.png") == nil, "non-data URI → nil")
    check(VisionContent.parseDataURI("data:image/png,notbase64") == nil, "non-base64 data URI → nil")
}

// ---- Vision capability detection ----
section("VisionSupport.modelSupportsVision per provider/model")
func cfg(_ provider: String, openai: String = "gpt-4o", claude: String = "claude-sonnet-4-5-20250514",
         llama: String = "qwen3.5-4b", ollama: String = "qwen3.5:4b") -> AppConfig {
    var c = AppConfig()
    c.provider = provider
    c.openaiModel = openai
    c.claudeModel = claude
    c.llamaModel = llama
    c.ollamaModel = ollama
    return c
}
// OpenAI
check(VisionSupport.modelSupportsVision(config: cfg("openai", openai: "gpt-4o")), "openai gpt-4o → vision")
check(VisionSupport.modelSupportsVision(config: cfg("openai", openai: "gpt-4o-mini")), "openai gpt-4o-mini → vision")
check(VisionSupport.modelSupportsVision(config: cfg("openai", openai: "gpt-4.1")), "openai gpt-4.1 → vision")
check(!VisionSupport.modelSupportsVision(config: cfg("openai", openai: "gpt-3.5-turbo")), "openai gpt-3.5 → NO vision")
// Claude
check(VisionSupport.modelSupportsVision(config: cfg("claude", claude: "claude-sonnet-4-5-20250514")), "claude sonnet 4 → vision")
check(VisionSupport.modelSupportsVision(config: cfg("claude", claude: "claude-3-5-sonnet-20241022")), "claude 3.5 sonnet → vision")
check(VisionSupport.modelSupportsVision(config: cfg("claude", claude: "claude-opus-4-20250514")), "claude opus 4 → vision")
check(!VisionSupport.modelSupportsVision(config: cfg("claude", claude: "claude-2.1")), "claude-2.1 → NO vision")
check(VisionSupport.modelSupportsVision(config: cfg("anthropic", claude: "claude-3-5-sonnet-20241022")), "anthropic alias → vision")
// llamacpp (default local 4B is text-only)
check(!VisionSupport.modelSupportsVision(config: cfg("llamacpp", llama: "qwen3.5-4b")), "llamacpp qwen3.5-4b (default) → NO vision")
check(VisionSupport.modelSupportsVision(config: cfg("llamacpp", llama: "gemma-3n-e4b")), "llamacpp gemma-3n → vision")
check(VisionSupport.modelSupportsVision(config: cfg("llamacpp", llama: "llava-1.6-mistral")), "llamacpp llava → vision")
// ollama
check(!VisionSupport.modelSupportsVision(config: cfg("ollama", ollama: "qwen3.5:4b")), "ollama qwen3.5 → NO vision")
check(VisionSupport.modelSupportsVision(config: cfg("ollama", ollama: "llava:13b")), "ollama llava → vision")
// unknown provider
check(!VisionSupport.modelSupportsVision(config: cfg("mystery")), "unknown provider → NO vision")

// ---- No-vision-model message is actionable ----
section("VisionSupport.noVisionModelMessage actionable")
do {
    let msg = VisionSupport.noVisionModelMessage()
    check(msg.contains("gpt-4o"), "message names gpt-4o")
    check(msg.contains("Sonnet"), "message names Claude Sonnet")
    check(msg.contains("Settings → Models"), "message points at Settings → Models")
    check(msg.lowercased().contains("gemma-3n"), "message names a local multimodal option (gemma-3n)")
    check(!msg.lowercased().contains("can't") || msg.lowercased().contains("can capture"),
          "message is not a flat refusal (offers a path)")
}

// ---- see_image source parsing ----
section("VisionSource.parse (incl. screenshot: prefix)")
check(VisionSource.parse("screenshot:https://example.com") == .screenshot(url: "https://example.com"),
      "screenshot:<url> → .screenshot")
check(VisionSource.parse("SCREENSHOT: https://example.com ") == .screenshot(url: "https://example.com"),
      "screenshot prefix case-insensitive + trims the url")
check(VisionSource.parse("https://e.com/pic.png") == .imageURL("https://e.com/pic.png"),
      "https URL → .imageURL")
check(VisionSource.parse("http://e.com/pic.png") == .imageURL("http://e.com/pic.png"),
      "http URL → .imageURL")
check(VisionSource.parse("/Users/me/Desktop/shot.png") == .localPath("/Users/me/Desktop/shot.png"),
      "absolute path → .localPath")
check(VisionSource.parse("  ./pics/cat.jpg  ") == .localPath("./pics/cat.jpg"),
      "relative path trimmed → .localPath")

// ----------------------------------------------------------------------------

print("")
print("=== \(testsRun) checks, \(testsFailed) failed ===")
exit(testsFailed == 0 ? 0 : 1)
