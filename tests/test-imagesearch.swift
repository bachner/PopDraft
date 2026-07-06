// test-imagesearch.swift — CI-pure unit tests for the image_search + download_file
// pure logic (Core.swift). NO network, NO WebKit.
//
// Compile + run WITH Core.swift (staged as main.swift by run-tests.sh):
//   swiftc -o /tmp/test-imagesearch tests/test-imagesearch.swift scripts/Core.swift && /tmp/test-imagesearch
//
// Covers:
//   - ImageSearchParser: vqd token extraction, DuckDuckGo i.js JSON parsing,
//     the rendered-SERP JSON parsing, https-only / dedupe / cap / fallbacks.
//   - DownloadPlanner: filename sanitization (path-traversal defeated), URL-
//     derived names, default-extension logic, destination stays under baseDir.
//   - Confirm + SSRF gating invariants: the download confirmation kind exists,
//     and the SafetyGuard the download path resolves through blocks internal IPs
//     while allowing public ones (the same gate download_file's redirect guard
//     uses via WebEngine.ssrfBlockReasonPure).
//   - The image_search / download_file tool JSON schemas are valid JSON.

import Foundation

// MARK: - Harness

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passCount += 1 }
    else { failCount += 1; print("  FAIL [\(file):\(line)]: \(message)") }
}

func test(_ name: String, _ body: () -> Void) {
    print("  Running: \(name)")
    body()
}

print("Running image_search + download_file (pure) tests...\n")

// MARK: - ImageSearchParser.parseVQD

test("parseVQD extracts the DuckDuckGo session token") {
    assert(ImageSearchParser.parseVQD("var vqd='4-123456789';") == "4-123456789",
           "single-quoted vqd")
    assert(ImageSearchParser.parseVQD("vqd=\"4-987abc\"") == "4-987abc",
           "double-quoted vqd")
    assert(ImageSearchParser.parseVQD("https://duckduckgo.com/i.js?q=x&vqd=4-deadbeef&p=1") == "4-deadbeef",
           "query-param vqd")
    assert(ImageSearchParser.parseVQD("<html>no token here</html>") == nil,
           "no token → nil")
    assert(ImageSearchParser.parseVQD("") == nil, "empty → nil")
}

// MARK: - ImageSearchParser.parseDDGImageJSON

test("parseDDGImageJSON decodes the i.js response") {
    let json = """
    {
      "results": [
        {"image":"https://cdn.example.com/eiffel.jpg","thumbnail":"https://tn.duckduckgo.com/t.jpg","url":"https://example.com/eiffel","title":"Eiffel Tower at night"},
        {"image":"https://cdn.example.com/2.png","thumbnail":"https://tn.duckduckgo.com/t2.png","url":"https://example.org/2","title":"Another"},
        {"image":"http://insecure.example.com/3.jpg","thumbnail":"https://tn.duckduckgo.com/t3.jpg","url":"https://example.org/3","title":"Insecure should drop"},
        {"image":"https://cdn.example.com/eiffel.jpg","thumbnail":"https://tn.duckduckgo.com/dup.jpg","url":"https://example.com/dup","title":"Duplicate image url"}
      ]
    }
    """
    let r = ImageSearchParser.parseDDGImageJSON(json, maxResults: 8)
    assert(r.count == 2, "kept 2 https results (http dropped, dup deduped) — got \(r.count)")
    assert(r.first?.imageURL == "https://cdn.example.com/eiffel.jpg", "first image url")
    assert(r.first?.thumbnailURL == "https://tn.duckduckgo.com/t.jpg", "first thumbnail")
    assert(r.first?.sourcePage == "https://example.com/eiffel", "first source page")
    assert(r.first?.title == "Eiffel Tower at night", "first title")
    assert(!r.contains(where: { $0.imageURL.hasPrefix("http://") }), "no http image survived")
}

test("parseDDGImageJSON caps to maxResults") {
    var items = ""
    for i in 0..<20 {
        items += "{\"image\":\"https://cdn.example.com/\(i).jpg\",\"thumbnail\":\"https://t/\(i).jpg\",\"url\":\"https://p/\(i)\",\"title\":\"t\(i)\"}"
        if i < 19 { items += "," }
    }
    let json = "{\"results\":[\(items)]}"
    let r = ImageSearchParser.parseDDGImageJSON(json, maxResults: 5)
    assert(r.count == 5, "capped to 5 — got \(r.count)")
}

test("parseDDGImageJSON tolerates garbage") {
    assert(ImageSearchParser.parseDDGImageJSON("", maxResults: 8).isEmpty, "empty → []")
    assert(ImageSearchParser.parseDDGImageJSON("not json", maxResults: 8).isEmpty, "junk → []")
    assert(ImageSearchParser.parseDDGImageJSON("{}", maxResults: 8).isEmpty, "no results key → []")
    assert(ImageSearchParser.parseDDGImageJSON("{\"results\":[]}", maxResults: 8).isEmpty, "empty results → []")
}

test("parseDDGImageJSON falls back thumbnail to image when thumb non-https") {
    let json = """
    {"results":[{"image":"https://cdn.example.com/a.jpg","thumbnail":"http://insecure/tn.jpg","url":"https://p","title":"x"}]}
    """
    let r = ImageSearchParser.parseDDGImageJSON(json, maxResults: 8)
    assert(r.count == 1, "one result")
    assert(r.first?.thumbnailURL == "https://cdn.example.com/a.jpg", "non-https thumb falls back to image url")
}

// MARK: - ImageSearchParser.parseImageSERPJSON (render fallback)

test("parseImageSERPJSON decodes the injected-JS array") {
    let json = """
    [
      {"image":"https://img.example.com/cat.jpg","thumbnail":"https://img.example.com/cat_tn.jpg","source":"https://pets.example.com/cat","title":"A cat"},
      {"image":"https://img.example.com/dog.png","thumbnail":"https://img.example.com/dog_tn.png","source":"https://pets.example.com/dog","title":"A dog"}
    ]
    """
    let r = ImageSearchParser.parseImageSERPJSON(json, maxResults: 8)
    assert(r.count == 2, "two results — got \(r.count)")
    assert(r[0].imageURL == "https://img.example.com/cat.jpg", "cat image url")
    assert(r[0].sourcePage == "https://pets.example.com/cat", "cat source page (from 'source' key)")
    assert(r[1].title == "A dog", "dog title")
}

test("parseImageSERPJSON strips tracking params from image url") {
    let json = """
    [{"image":"https://img.example.com/x.jpg?utm_source=foo&w=200","thumbnail":"https://img.example.com/x.jpg","source":"","title":"x"}]
    """
    let r = ImageSearchParser.parseImageSERPJSON(json, maxResults: 8)
    assert(r.count == 1, "one result")
    assert(!r[0].imageURL.contains("utm_source"), "tracking param stripped: \(r[0].imageURL)")
    assert(r[0].imageURL.contains("w=200"), "real param kept")
}

// MARK: - DownloadPlanner.sanitizeFilename (path-traversal defense)

test("sanitizeFilename defeats path traversal") {
    assert(DownloadPlanner.sanitizeFilename("../../etc/passwd") == "passwd",
           "leading ../ + dirs stripped → passwd, got \(DownloadPlanner.sanitizeFilename("../../etc/passwd"))")
    assert(DownloadPlanner.sanitizeFilename("/absolute/path/file.png") == "file.png",
           "absolute path → basename")
    assert(DownloadPlanner.sanitizeFilename("a/b/c.txt") == "c.txt", "nested → basename")
    assert(!DownloadPlanner.sanitizeFilename("foo\nbar.png").contains("\n"), "newline removed")
    assert(DownloadPlanner.sanitizeFilename("") == "download", "empty → fallback")
    assert(DownloadPlanner.sanitizeFilename("..") == "download", ".. → fallback")
    assert(DownloadPlanner.sanitizeFilename(".") == "download", ". → fallback")
    // No hidden / leading-dot files.
    assert(!DownloadPlanner.sanitizeFilename(".hidden").hasPrefix("."), "leading dot trimmed")
}

test("sanitizeFilename caps length, keeping extension") {
    let long = String(repeating: "a", count: 500) + ".png"
    let s = DownloadPlanner.sanitizeFilename(long)
    assert(s.count <= 200, "capped to <=200 — got \(s.count)")
    assert(s.hasSuffix(".png"), "extension preserved")
}

// MARK: - DownloadPlanner.filenameFromURL

test("filenameFromURL derives the last path component") {
    assert(DownloadPlanner.filenameFromURL("https://www.gnu.org/graphics/heckert_gnu.transp.small.png")
           == "heckert_gnu.transp.small.png", "gnu png")
    assert(DownloadPlanner.filenameFromURL("https://example.com/a/b/report.pdf") == "report.pdf", "pdf")
    assert(DownloadPlanner.filenameFromURL("https://example.com/") == nil, "root → nil")
    assert(DownloadPlanner.filenameFromURL("https://example.com") == nil, "no path → nil")
    // Percent-encoded names decode.
    assert(DownloadPlanner.filenameFromURL("https://example.com/my%20file.jpg") == "my file.jpg",
           "percent-decoded name")
}

// MARK: - DownloadPlanner.resolveFilename

test("resolveFilename prefers explicit name, then URL, then default") {
    // Explicit wins (and is sanitized).
    assert(DownloadPlanner.resolveFilename(requested: "cat.png", url: "https://x/dog.jpg") == "cat.png",
           "explicit name wins")
    assert(DownloadPlanner.resolveFilename(requested: "../evil.sh", url: "https://x/dog.jpg") == "evil.sh",
           "explicit name sanitized")
    // No explicit → derive from URL.
    assert(DownloadPlanner.resolveFilename(requested: nil, url: "https://x/dog.jpg") == "dog.jpg",
           "derived from URL")
    assert(DownloadPlanner.resolveFilename(requested: "  ", url: "https://x/dog.jpg") == "dog.jpg",
           "blank requested → derive from URL")
    // No name anywhere → timestamped default.
    let d = DownloadPlanner.resolveFilename(requested: nil, url: "https://x/")
    assert(d.hasPrefix("download-"), "default timestamped name — got \(d)")
}

test("resolveFilename appends default extension only when missing") {
    assert(DownloadPlanner.resolveFilename(requested: "photo", url: "https://x/", defaultExt: "png") == "photo.png",
           "appends ext when none")
    assert(DownloadPlanner.resolveFilename(requested: "photo.jpg", url: "https://x/", defaultExt: "png") == "photo.jpg",
           "does NOT append when ext present")
    assert(DownloadPlanner.resolveFilename(requested: "photo", url: "https://x/", defaultExt: ".png") == "photo.png",
           "dotted defaultExt handled")
    assert(DownloadPlanner.resolveFilename(requested: "photo", url: "https://x/", defaultExt: "") == "photo",
           "empty defaultExt → no change")
}

// MARK: - DownloadPlanner.destination (stays under baseDir)

test("destination always lands a single component under baseDir") {
    let dir = "/Users/me/Downloads"
    assert(DownloadPlanner.destination(baseDir: dir, filename: "x.png") == "/Users/me/Downloads/x.png",
           "simple join")
    // A malicious filename can't escape the base dir.
    let escaped = DownloadPlanner.destination(baseDir: dir, filename: "../../etc/passwd")
    assert(escaped == "/Users/me/Downloads/passwd", "traversal contained — got \(escaped)")
    assert(!escaped.contains(".."), "no .. in destination")
}

// MARK: - Confirm gating: the download confirmation kind exists

test("ConfirmationKind has a .download case (confirm-gate seam)") {
    let k = ConfirmationKind.download
    assert(k.rawValue == "download", "download kind raw value")
    // A request can be built for a download (this is what the tool routes through
    // the MacControlConfirmer seam on every real (non-dry-run) download).
    let req = ConfirmationRequest(id: "id1", kind: .download,
                                  command: "Download https://x/a.png\n  → ~/Downloads/a.png",
                                  explanation: "Download this file to your Downloads folder.")
    assert(req.kind == .download, "request kind is download")
    assert(req.command.contains("Download https://x/a.png"), "request shows the url + dest")
}

// MARK: - SSRF gating: the gate download_file's redirect guard relies on

test("SSRF gate blocks internal hosts, allows public (download redirect guard)") {
    // download_file's redirect guard rejects any hop whose IP is private/loopback/
    // metadata via WebEngine.ssrfBlockReasonPure → SafetyGuard.isBlockedIP. Verify
    // the underlying classification here (pure, no WebKit).
    assert(SafetyGuard.isBlockedIP("127.0.0.1"), "loopback blocked")
    assert(SafetyGuard.isBlockedIP("169.254.169.254"), "cloud-metadata blocked")
    assert(SafetyGuard.isBlockedIP("10.0.0.1"), "RFC1918 blocked")
    assert(SafetyGuard.isBlockedIP("192.168.1.1"), "RFC1918 blocked")
    assert(!SafetyGuard.isBlockedIP("93.184.216.34"), "public IP allowed")
    // Non-https schemes are not allowed for the file fetch path.
    assert(!SafetyGuard.isSchemeAllowed(URL(string: "file:///etc/passwd")!), "file: blocked")
    assert(SafetyGuard.isSchemeAllowed(URL(string: "https://example.com/a.png")!), "https allowed")
    // A literal internal host is blocked even before DNS.
    assert(SafetyGuard.isLiteralHostBlocked("localhost"), "localhost literal blocked")
}

// MARK: - Tool JSON schemas are valid

test("image_search + download_file schemas are valid JSON with the right names") {
    func parsed(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    guard let img = parsed(WebToolSchemas.imageSearch),
          let imgFn = img["function"] as? [String: Any] else {
        assert(false, "image_search schema is not valid JSON"); return
    }
    assert(imgFn["name"] as? String == "image_search", "image_search name")
    guard let dl = parsed(WebToolSchemas.downloadFile),
          let dlFn = dl["function"] as? [String: Any] else {
        assert(false, "download_file schema is not valid JSON"); return
    }
    assert(dlFn["name"] as? String == "download_file", "download_file name")
    // Both are present in `all` (so they self-register / are validated by the
    // existing schema-validity test).
    assert(WebToolSchemas.all.contains(WebToolSchemas.imageSearch), "image_search in .all")
    assert(WebToolSchemas.all.contains(WebToolSchemas.downloadFile), "download_file in .all")
}

// MARK: - ImageResult.embedURL default + legacy decode

test("ImageResult.embedURL defaults to the reliable proxy thumbnail") {
    let r = ImageResult(imageURL: "https://cdn.example.com/full.jpg",
                        thumbnailURL: "https://proxy.duckduckgo.com/iu/?u=x",
                        sourcePage: "https://example.com/p", title: "t")
    // Default embedURL = thumbnail (renders reliably), NOT the hotlink-prone original.
    assert(r.embedURL == "https://proxy.duckduckgo.com/iu/?u=x", "embedURL defaults to thumbnailURL, got \(r.embedURL)")
    // No thumbnail → fall back to the original rather than empty.
    let r2 = ImageResult(imageURL: "https://cdn.example.com/full.jpg", thumbnailURL: "",
                         sourcePage: "", title: "t")
    assert(r2.embedURL == "https://cdn.example.com/full.jpg", "embedURL falls back to imageURL when no thumb")
    // Explicit embedURL (e.g. a pdimg ref after download) is preserved.
    let r3 = ImageResult(imageURL: "https://cdn.example.com/full.jpg", thumbnailURL: "https://t/x",
                         sourcePage: "", title: "t", embedURL: "pdimg:abc123.jpg")
    assert(r3.embedURL == "pdimg:abc123.jpg", "explicit embedURL preserved")
}

test("ImageResult decodes legacy JSON without embedURL") {
    // A cached result from before embedURL existed must still decode (embedURL
    // synthesized from the thumbnail) — no crash on the 5-min image cache.
    let legacy = #"{"imageURL":"https://a/i.jpg","thumbnailURL":"https://t/i.jpg","sourcePage":"https://p","title":"x"}"#
    let decoded = try? JSONDecoder().decode(ImageResult.self, from: Data(legacy.utf8))
    assert(decoded != nil, "legacy ImageResult JSON decodes")
    assert(decoded?.embedURL == "https://t/i.jpg", "legacy decode fills embedURL from thumbnail")
    // Round-trips WITH embedURL once re-encoded.
    if let d = decoded, let re = try? JSONEncoder().encode(d),
       let s = String(data: re, encoding: .utf8) {
        assert(s.contains("embedURL"), "re-encoded ImageResult includes embedURL")
    } else { assert(false, "re-encode failed") }
}

// MARK: - ImageEmbed: cache naming, MIME mapping, safe ref parsing

test("ImageEmbed extension + MIME mapping") {
    assert(ImageEmbed.ext(forContentType: "image/png") == "png", "png ext")
    assert(ImageEmbed.ext(forContentType: "image/jpeg") == "jpg", "jpeg→jpg ext")
    assert(ImageEmbed.ext(forContentType: "image/webp; charset=x") == "webp", "webp ext")
    assert(ImageEmbed.ext(forContentType: nil) == "jpg", "nil content-type → jpg")
    assert(ImageEmbed.ext(forContentType: "application/octet-stream") == "jpg", "unknown → jpg")
    assert(ImageEmbed.mimeType(forFilename: "abc.png") == "image/png", "png mime")
    assert(ImageEmbed.mimeType(forFilename: "abc.webp") == "image/webp", "webp mime")
    assert(ImageEmbed.mimeType(forFilename: "abc.jpg") == "image/jpeg", "jpg mime")
    assert(ImageEmbed.mimeType(forFilename: "abc") == "image/jpeg", "no ext → jpeg default")
}

test("ImageEmbed ref round-trip + traversal-safe filename parsing") {
    let key = String(repeating: "a", count: 64)  // looks like a sha256 hex
    let filename = ImageEmbed.cacheFilename(key: key, contentType: "image/png")
    assert(filename == "\(key).png", "cacheFilename is <key>.<ext>")
    let ref = ImageEmbed.ref(forFilename: filename)
    assert(ref == "pdimg:\(key).png", "ref is pdimg:<file>")
    assert(ImageEmbed.filename(fromRef: ref) == filename, "ref → filename round-trips")
    assert(ImageEmbed.filename(fromRef: "pdimg://\(filename)") == filename, "pdimg:// form also parses")
    // Rejections: path traversal, separators, wrong scheme, bad shape.
    assert(ImageEmbed.filename(fromRef: "pdimg:../../etc/passwd") == nil, "traversal rejected")
    assert(ImageEmbed.filename(fromRef: "pdimg:\(key)/x.png") == nil, "slash rejected")
    assert(ImageEmbed.filename(fromRef: "pdimg:..%2fx.png") == nil, "encoded traversal rejected")
    assert(ImageEmbed.filename(fromRef: "https://evil/x.png") == nil, "wrong scheme rejected")
    assert(ImageEmbed.filename(fromRef: "pdimg:notahash.png") == nil, "non-hex base rejected")
    assert(ImageEmbed.filename(fromRef: "pdimg:\(key)") == nil, "missing extension rejected")
    assert(ImageEmbed.filename(fromRef: "pdimg:\(key).PNG") == nil, "uppercase ext (never minted) rejected")
    assert(ImageEmbed.isSafeFilename("\(key).jpg"), "canonical name is safe")
    assert(!ImageEmbed.isSafeFilename("a.jpg"), "too-short base unsafe")
}

// MARK: - Summary

print("\n----------------------------------------")
print("image_search/download_file tests: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    print("RESULT: FAIL")
    exit(1)
} else {
    print("RESULT: PASS")
    exit(0)
}
