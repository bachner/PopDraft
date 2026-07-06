// test-webengine-core.swift — CI-pure unit tests for the WebEngine's
// Foundation-only logic (Core.swift). NO network, NO WebKit.
//
// Compile + run WITH Core.swift:
//   swiftc -o /tmp/test-webengine-core tests/test-webengine-core.swift scripts/Core.swift && /tmp/test-webengine-core
//
// Covers: SSRF/IP classification (every blocked range + a public IP allowed +
// the cloud-metadata IP blocked), the scheme allowlist, DDG lite parsing from
// the committed fixture (incl. uddg decoding + dedupe), size-cap logic, the
// char-cap/paragraph-boundary truncation, URL tracking-param stripping, the
// BM25 chunk ranker, the new web config knobs round-trip, and that the tool
// JSON-Schema constants are valid JSON.

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

print("Running WebEngine core (pure) tests...\n")

// MARK: - SSRF: scheme allowlist

test("Scheme allowlist") {
    func u(_ s: String) -> URL { URL(string: s)! }
    assert(SafetyGuard.isSchemeAllowed(u("https://example.com")), "https allowed")
    assert(SafetyGuard.isSchemeAllowed(u("http://example.com")), "http allowed")
    assert(SafetyGuard.isSchemeAllowed(u("about:blank")), "about:blank allowed (reset)")
    assert(!SafetyGuard.isSchemeAllowed(u("file:///etc/passwd")), "file: blocked")
    assert(!SafetyGuard.isSchemeAllowed(u("ftp://example.com")), "ftp: blocked")
    assert(!SafetyGuard.isSchemeAllowed(u("data:text/html,<h1>x")), "data: blocked")
    assert(!SafetyGuard.isSchemeAllowed(u("javascript:alert(1)")), "javascript: blocked")
    assert(!SafetyGuard.isSchemeAllowed(u("about:settings")), "about:settings blocked (only blank)")
}

// MARK: - WebEngineError messages: unresolvable host is distinct from an SSRF block

test("unresolvableHost reads as 'wrong URL', not a security block") {
    let unresolvable = WebEngineError.unresolvableHost("next.example.invalid").description
    // Must clearly say the host couldn't be resolved…
    assert(unresolvable.lowercased().contains("resolve"), "unresolvable message mentions resolving (\(unresolvable))")
    assert(unresolvable.contains("next.example.invalid"), "unresolvable message names the host")
    // …and explicitly NOT read as an SSRF/private-address block (the old behavior).
    assert(!unresolvable.contains("SSRF"), "unresolvable message does NOT say SSRF")
    assert(!unresolvable.contains("private address"), "unresolvable message does NOT say private address")
    // The real SSRF block message is unchanged + still distinct.
    let blocked = WebEngineError.blockedHost("10.0.0.5").description
    assert(blocked.contains("SSRF") && blocked.contains("private address"), "blockedHost keeps its SSRF wording")
    assert(WebEngineError.unresolvableHost("h") != WebEngineError.blockedHost("h"),
           "unresolvableHost and blockedHost are distinct cases")
}

// MARK: - SSRF: IPv4 classification

test("IPv4 blocked ranges") {
    // Loopback
    assert(SafetyGuard.isBlockedIP("127.0.0.1"), "127.0.0.1 loopback blocked")
    assert(SafetyGuard.isBlockedIP("127.255.255.255"), "127/8 blocked")
    // RFC1918
    assert(SafetyGuard.isBlockedIP("10.0.0.1"), "10/8 blocked")
    assert(SafetyGuard.isBlockedIP("10.255.255.255"), "10/8 upper blocked")
    assert(SafetyGuard.isBlockedIP("172.16.0.1"), "172.16/12 lower blocked")
    assert(SafetyGuard.isBlockedIP("172.31.255.255"), "172.16/12 upper blocked")
    assert(SafetyGuard.isBlockedIP("192.168.1.1"), "192.168/16 blocked")
    // Link-local
    assert(SafetyGuard.isBlockedIP("169.254.1.1"), "169.254/16 link-local blocked")
    // Cloud metadata — explicit
    assert(SafetyGuard.isBlockedIP("169.254.169.254"), "169.254.169.254 cloud metadata blocked")
    // Unspecified
    assert(SafetyGuard.isBlockedIP("0.0.0.0"), "0.0.0.0 blocked")
    assert(SafetyGuard.isBlockedIP("0.1.2.3"), "0/8 blocked")
    // CGNAT
    assert(SafetyGuard.isBlockedIP("100.64.0.1"), "100.64/10 CGNAT blocked")
}

test("IPv4 public addresses allowed") {
    assert(!SafetyGuard.isBlockedIP("8.8.8.8"), "8.8.8.8 public allowed")
    assert(!SafetyGuard.isBlockedIP("1.1.1.1"), "1.1.1.1 public allowed")
    assert(!SafetyGuard.isBlockedIP("93.184.216.34"), "example.com IP public allowed")
    assert(!SafetyGuard.isBlockedIP("172.15.0.1"), "172.15 is NOT in 172.16/12 -> allowed")
    assert(!SafetyGuard.isBlockedIP("172.32.0.1"), "172.32 is NOT in 172.16/12 -> allowed")
    assert(!SafetyGuard.isBlockedIP("192.169.0.1"), "192.169 is NOT 192.168 -> allowed")
    assert(!SafetyGuard.isBlockedIP("100.63.0.1"), "100.63 is NOT in CGNAT -> allowed")
    assert(!SafetyGuard.isBlockedIP("100.128.0.1"), "100.128 is NOT in CGNAT -> allowed")
}

// MARK: - SSRF: IPv6 classification

test("IPv6 blocked ranges") {
    assert(SafetyGuard.isBlockedIP("::1"), "::1 loopback blocked")
    assert(SafetyGuard.isBlockedIP("::"), ":: unspecified blocked")
    assert(SafetyGuard.isBlockedIP("fe80::1"), "fe80::/10 link-local blocked")
    assert(SafetyGuard.isBlockedIP("fe80::1%en0"), "link-local with zone-id blocked")
    assert(SafetyGuard.isBlockedIP("fc00::1"), "fc00::/7 ULA blocked")
    assert(SafetyGuard.isBlockedIP("fd12:3456::1"), "fd.. ULA blocked")
    assert(SafetyGuard.isBlockedIP("::ffff:127.0.0.1"), "IPv4-mapped loopback blocked")
    assert(SafetyGuard.isBlockedIP("::ffff:169.254.169.254"), "IPv4-mapped metadata blocked")
}

test("IPv6 public addresses allowed") {
    assert(!SafetyGuard.isBlockedIP("2606:4700:4700::1111"), "Cloudflare v6 allowed")
    assert(!SafetyGuard.isBlockedIP("2001:4860:4860::8888"), "Google v6 allowed")
    assert(!SafetyGuard.isBlockedIP("::ffff:8.8.8.8"), "IPv4-mapped public allowed")
}

// MARK: - SSRF: literal host (no DNS)

test("Literal host classification (no DNS)") {
    assert(SafetyGuard.isLiteralHostBlocked("localhost"), "localhost blocked")
    assert(SafetyGuard.isLiteralHostBlocked("foo.localhost"), "*.localhost blocked")
    assert(SafetyGuard.isLiteralHostBlocked("printer.local"), "*.local blocked")
    assert(SafetyGuard.isLiteralHostBlocked("svc.internal"), "*.internal blocked")
    assert(SafetyGuard.isLiteralHostBlocked("127.0.0.1"), "loopback literal blocked")
    assert(SafetyGuard.isLiteralHostBlocked("169.254.169.254"), "metadata literal blocked")
    assert(!SafetyGuard.isLiteralHostBlocked("example.com"), "named public host not blocked here (DNS deferred)")
    assert(!SafetyGuard.isLiteralHostBlocked("8.8.8.8"), "public IP literal allowed")
}

// MARK: - IPv4 / IPv6 parsing edge cases

test("IP parsing rejects malformed") {
    assert(SafetyGuard.parseIPv4("256.0.0.1") == nil, "octet > 255 rejected")
    assert(SafetyGuard.parseIPv4("1.2.3") == nil, "too few octets rejected")
    assert(SafetyGuard.parseIPv4("1.2.3.4.5") == nil, "too many octets rejected")
    assert(SafetyGuard.parseIPv4("a.b.c.d") == nil, "non-numeric rejected")
    assert(SafetyGuard.parseIPv4("1.2.3.4") != nil, "valid v4 parsed")
    assert(SafetyGuard.parseIPv6("::1") != nil, "::1 parsed")
    assert(SafetyGuard.parseIPv6("fe80::1") != nil, "fe80::1 parsed")
    assert(SafetyGuard.parseIPv6("not:an:ip:zzzz") == nil, "garbage v6 rejected")
    assert(SafetyGuard.parseIPv6("1.2.3.4") == nil, "v4 is not v6")
}

// MARK: - DDG lite parsing (from committed fixture)

test("DDG lite parsing from fixture + uddg decode + dedupe") {
    let path = "tests/fixtures/ddg-lite.html"
    guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
        assert(false, "could not read fixture \(path)")
        return
    }
    let results = DDGParser.parseLite(html, maxResults: 10)
    // 4 anchors with uddg, but #1 and #4 dedupe to the same example.com URL ->
    // we expect 3 unique results (settings link has no uddg -> ignored).
    assert(results.count == 3, "expected 3 deduped results, got \(results.count)")

    assert(results[0].title == "Example Domain & More", "title entity decoded, got '\(results[0].title)'")
    // uddg decoded to the real URL AND tracking params stripped (utm_source gone, id kept).
    assert(results[0].url == "https://www.example.com/article?id=42", "uddg decoded + utm stripped, got '\(results[0].url)'")
    assert(results[0].snippet.contains("illustrative examples"), "snippet captured, got '\(results[0].snippet)'")
    assert(!results[0].snippet.contains("&hellip;"), "entities decoded in snippet")

    assert(results[1].url == "https://en.wikipedia.org/wiki/Example", "second url decoded")
    assert(results[1].title == "Example - Wikipedia", "second title")
    assert(results[2].url == "https://www.iana.org/help/example-domains", "third url decoded")

    // The settings link (no uddg) must NOT appear.
    assert(!results.contains(where: { $0.url.contains("settings") }), "non-result anchor ignored")
}

test("DDG snippet pairing bounded to before next anchor") {
    // Result #1 has a snippet; result #2 has NO snippet of its own — it must NOT
    // borrow result #3's snippet (it should be empty).
    let html = """
    <table>
      <tr><td><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com%2F1" class="result-link">First</a></td></tr>
      <tr><td class="result-snippet">snippet for first result</td></tr>
      <tr><td><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fb.com%2F2" class="result-link">Second</a></td></tr>
      <tr><td><a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fc.com%2F3" class="result-link">Third</a></td></tr>
      <tr><td class="result-snippet">snippet for third result</td></tr>
    </table>
    """
    let r = DDGParser.parseLite(html, maxResults: 10)
    assert(r.count == 3, "three results, got \(r.count)")
    assert(r[0].snippet == "snippet for first result", "first gets its own snippet")
    assert(r[1].snippet == "", "second (no snippet) does NOT borrow third's, got '\(r[1].snippet)'")
    assert(r[2].snippet == "snippet for third result", "third gets its own snippet")
}

test("DDG uddg redirect decoding directly") {
    let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Ffoo.bar%2Fbaz%3Fx%3D1&rut=z"
    assert(DDGParser.decodeRedirect(href) == "https://foo.bar/baz?x=1", "decodeRedirect")
    assert(DDGParser.decodeRedirect("/settings") == nil, "no uddg -> nil")
    assert(DDGParser.decodeRedirect("https://example.com/plain") == nil, "absolute non-redirect -> nil")
}

test("DDG lite parses 2026 DIRECT-href markup (single-quoted class, no uddg)") {
    // The current lite endpoint emits direct hrefs on single-quoted
    // class='result-link' anchors, with single-quoted result-snippet cells.
    let html = """
    <table>
      <tr><td>
        <a rel="nofollow" href="https://en.wikipedia.org/wiki/Canberra" class='result-link'>Canberra - Wikipedia</a>
      </td></tr>
      <tr><td class='result-snippet'>Canberra is the <b>capital</b> city of Australia.</td></tr>
      <tr><td>
        <a rel="nofollow" href="https://www.britannica.com/place/Canberra" class='result-link'>Canberra | Britannica</a>
      </td></tr>
      <tr><td class='result-snippet'>Canberra, capital of Australia.</td></tr>
      <tr><td><a href="/settings" class='nav-link'>Settings</a></td></tr>
    </table>
    """
    let r = DDGParser.parseLite(html, maxResults: 10)
    assert(r.count == 2, "two direct-href results parsed, got \(r.count)")
    assert(r[0].url == "https://en.wikipedia.org/wiki/Canberra", "direct href #1, got '\(r[0].url)'")
    assert(r[0].title == "Canberra - Wikipedia", "title #1, got '\(r[0].title)'")
    assert(r[0].snippet.contains("capital city of Australia"), "snippet #1, got '\(r[0].snippet)'")
    assert(r[1].url == "https://www.britannica.com/place/Canberra", "direct href #2")
    // The non-result nav link (not a result-link, relative href) must be ignored.
    assert(!r.contains(where: { $0.url.contains("settings") }), "nav link ignored")
}

test("DDGParser.attrValue tolerates single + double quotes") {
    let attrs = "rel=\"nofollow\" href=\"https://x.com\" class='result-link'"
    assert(DDGParser.attrValue("href", in: attrs) == "https://x.com", "double-quoted href")
    assert(DDGParser.attrValue("class", in: attrs) == "result-link", "single-quoted class")
    assert(DDGParser.attrValue("missing", in: attrs) == nil, "absent attr -> nil")
}

test("DDGParser.parseSERPJSON parses browse-SERP fallback output") {
    let json = """
    [
      {"title":"Canberra - Wikipedia","url":"https://en.wikipedia.org/wiki/Canberra?utm_source=ddg","snippet":"Capital of Australia."},
      {"title":"","url":"https://skip.me","snippet":"no title -> skipped"},
      {"title":"Dup","url":"https://en.wikipedia.org/wiki/Canberra","snippet":"deduped by url"},
      {"title":"Bad","url":"ftp://nope","snippet":"non-http skipped"}
    ]
    """
    let r = DDGParser.parseSERPJSON(json, maxResults: 10)
    // The two Canberra entries dedupe AFTER url-cleaning (utm stripped) → 1 unique.
    assert(r.count == 1, "deduped + filtered to 1 result, got \(r.count)")
    assert(r[0].title == "Canberra - Wikipedia", "title kept")
    assert(r[0].url == "https://en.wikipedia.org/wiki/Canberra", "tracking param stripped")
    assert(DDGParser.parseSERPJSON("not json", maxResults: 10).isEmpty, "bad json -> []")
    assert(DDGParser.parseSERPJSON("[]", maxResults: 10).isEmpty, "empty array -> []")
}

// MARK: - URL tracking-param stripping

test("URL tracking-param stripping") {
    assert(URLCleaner.strip("https://e.com/a?utm_source=x&id=5") == "https://e.com/a?id=5", "utm_source dropped, id kept")
    assert(URLCleaner.strip("https://e.com/a?utm_source=x&fbclid=y") == "https://e.com/a", "all-tracking -> no query, no dangling ?")
    assert(URLCleaner.strip("https://e.com/a?id=5") == "https://e.com/a?id=5", "clean URL unchanged")
    assert(URLCleaner.strip("https://e.com/a") == "https://e.com/a", "no query unchanged")
    assert(URLCleaner.strip("not a url") == "not a url", "non-URL unchanged")
    // Case-insensitive param matching.
    assert(URLCleaner.strip("https://e.com/a?UTM_SOURCE=x&id=5") == "https://e.com/a?id=5", "case-insensitive tracking match")
}

// MARK: - Size-cap logic

test("Size-cap logic") {
    assert(SizeGuard.exceeds(received: 9 * 1024 * 1024, max: 8 * 1024 * 1024), "9MB > 8MB cap")
    assert(!SizeGuard.exceeds(received: 1024, max: 8 * 1024 * 1024), "1KB under cap")
    assert(!SizeGuard.exceeds(received: 8 * 1024 * 1024, max: 8 * 1024 * 1024), "exactly cap is OK")
    assert(SizeGuard.rejectByContentLength(20_000_000, max: 8 * 1024 * 1024), "Content-Length 20MB rejected up-front")
    assert(!SizeGuard.rejectByContentLength(nil, max: 8 * 1024 * 1024), "absent Content-Length not rejected up-front")
    assert(!SizeGuard.rejectByContentLength(1024, max: 8 * 1024 * 1024), "small Content-Length OK")
}

// MARK: - Markdown char-cap / paragraph-boundary truncation

test("Markdown truncation at paragraph boundary") {
    let p1 = String(repeating: "a", count: 300)
    let p2 = String(repeating: "b", count: 300)
    let p3 = String(repeating: "c", count: 300)
    let md = "\(p1)\n\n\(p2)\n\n\(p3)"  // 906 chars
    let (out, truncated) = MarkdownSanitizer.truncate(md, maxChars: 700)
    assert(truncated, "should be truncated")
    assert(out.count <= 720, "respects cap (with ellipsis), got \(out.count)")
    // Should cut at a paragraph boundary -> keep p1+p2, drop the partial p3.
    assert(out.contains(p1) && out.contains(p2), "keeps whole paragraphs up to boundary")
    assert(!out.contains(p3), "drops the paragraph past the boundary")
    assert(out.hasSuffix("…"), "ends with ellipsis marker")

    // Under the cap -> unchanged.
    let (out2, trunc2) = MarkdownSanitizer.truncate("short text", maxChars: 700)
    assert(!trunc2 && out2 == "short text", "short input unchanged")
}

test("Markdown whitespace collapsing") {
    let md = "Line1   \n\n\n\n\nLine2  \n"
    let out = MarkdownSanitizer.collapseWhitespace(md)
    assert(!out.contains("   \n"), "trailing spaces stripped")
    // "3+ blank lines collapse to 2" means at most 2 empty lines == 3 newlines;
    // so 4+ consecutive newlines must never survive.
    assert(!out.contains("\n\n\n\n"), "4+ newlines (3+ blank lines) collapsed")
    assert(out.hasPrefix("Line1"), "content preserved")
}

// MARK: - BM25 chunk ranking

test("BM25 chunk ranking") {
    let md = """
    The capital of France is Paris, a major European city on the Seine.

    Bananas are a popular tropical fruit grown in many warm climates.

    Paris hosts the Eiffel Tower and the Louvre, famous landmarks of France.

    The stock market saw gains today amid economic optimism.
    """
    // Small target keeps each paragraph its own chunk (no merging) so the
    // banana paragraph is a distinct, rankable chunk.
    let chunks = ChunkRanker.chunk(md, targetChars: 50)
    assert(chunks.count == 4, "four distinct chunks, got \(chunks.count)")
    let ranked = ChunkRanker.rank(chunks: chunks, instruction: "What landmarks are in Paris, France?", limit: 4)
    assert(!ranked.isEmpty, "ranking returns chunks")
    // Top chunk should be about Paris/France/landmarks.
    let top = ranked.first?.text ?? ""
    assert(top.lowercased().contains("paris") || top.lowercased().contains("france"), "top chunk is Paris/France relevant, got: \(top)")
    // The banana paragraph must not be the single best match.
    assert(!(ranked.first?.text.contains("Bananas") ?? false), "banana chunk not ranked first")
    // The banana + stock-market chunks should rank below the Paris/France ones.
    let parisChunks = ranked.prefix(2).filter { $0.text.lowercased().contains("paris") }
    assert(parisChunks.count == 2, "both Paris chunks rank in the top 2")
    // Scores are descending.
    if ranked.count >= 2 {
        assert(ranked[0].score >= ranked[1].score, "scores descending")
    }
}

test("BM25 empty instruction returns leading chunks") {
    let chunks = ["aaa bbb ccc", "ddd eee fff", "ggg hhh iii"]
    let ranked = ChunkRanker.rank(chunks: chunks, instruction: "", limit: 2)
    assert(ranked.count == 2, "returns up to limit")
    assert(ranked[0].text == "aaa bbb ccc", "leading chunk first when no query")
}

test("Chunk merging respects target size") {
    let md = "One.\n\nTwo.\n\nThree.\n\nFour."
    let chunks = ChunkRanker.chunk(md, targetChars: 100)
    // Small paragraphs merge into one chunk under the target.
    assert(chunks.count == 1, "small paras merge, got \(chunks.count)")
    let big = String(repeating: "x", count: 80)
    let md2 = "\(big)\n\n\(big)\n\n\(big)"
    let chunks2 = ChunkRanker.chunk(md2, targetChars: 100)
    assert(chunks2.count == 3, "each big para its own chunk, got \(chunks2.count)")
}

// MARK: - Config knobs round-trip

test("Web config knobs default + round-trip + clamp") {
    let d = AppConfig()
    assert(d.webMaxRenderers == 2, "webMaxRenderers default 2")
    assert(d.webNavTimeoutMs == 15000, "webNavTimeoutMs default 15000")
    assert(d.webSettleMs == 600, "webSettleMs default 600")
    assert(d.webReadMaxChars == 12000, "webReadMaxChars default 12000")
    assert(d.webMaxBytes == 8 * 1024 * 1024, "webMaxBytes default 8MB")

    // Round-trip via JSON.
    var c = AppConfig()
    c.webMaxRenderers = 4
    c.webNavTimeoutMs = 9000
    c.webSettleMs = 250
    c.webReadMaxChars = 5000
    c.webMaxBytes = 4 * 1024 * 1024
    let data = try! JSONEncoder().encode(c)
    let back = try! JSONDecoder().decode(AppConfig.self, from: data)
    assert(back.webMaxRenderers == 4, "renderers round-trip")
    assert(back.webNavTimeoutMs == 9000, "timeout round-trip")
    assert(back.webSettleMs == 250, "settle round-trip")
    assert(back.webReadMaxChars == 5000, "maxChars round-trip")
    assert(back.webMaxBytes == 4 * 1024 * 1024, "maxBytes round-trip")

    // Out-of-range renderer count is clamped on decode (1...6).
    let hi = #"{"version":2,"webMaxRenderers":99}"#.data(using: .utf8)!
    let hiCfg = try! JSONDecoder().decode(AppConfig.self, from: hi)
    assert(hiCfg.webMaxRenderers == 6, "renderers clamped to 6, got \(hiCfg.webMaxRenderers)")
    let lo = #"{"version":2,"webMaxRenderers":0}"#.data(using: .utf8)!
    let loCfg = try! JSONDecoder().decode(AppConfig.self, from: lo)
    assert(loCfg.webMaxRenderers == 1, "renderers clamped to 1, got \(loCfg.webMaxRenderers)")
    assert(WebTuning.clampRenderers(-5) == 1 && WebTuning.clampRenderers(10) == 6, "clampRenderers helper")
}

// MARK: - Tool schemas are valid JSON in the OpenAI function shape

test("Web tool JSON-Schema constants are valid JSON") {
    for (i, schema) in WebToolSchemas.all.enumerated() {
        guard let data = schema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            assert(false, "schema \(i) is not valid JSON")
            continue
        }
        assert(obj["type"] as? String == "function", "schema \(i) has type=function")
        let fn = obj["function"] as? [String: Any]
        assert(fn != nil, "schema \(i) has function object")
        assert((fn?["name"] as? String)?.isEmpty == false, "schema \(i) has a name")
        assert(fn?["parameters"] is [String: Any], "schema \(i) has parameters object")
    }
    // web_search, web_open, web_read, web_screenshot, web_extract, image_search, download_file
    assert(WebToolSchemas.all.count == 7, "seven tool schemas")
}

// MARK: - Interactive browser tool schemas are valid JSON

test("Browser tool JSON-Schema constants are valid JSON") {
    let expectedNames = ["browser_open", "browser_click", "browser_type",
                         "browser_read", "browser_screenshot", "browser_back",
                         "browser_scroll", "browser_evaluate"]
    assert(WebToolSchemas.browserAll.count == 8, "eight browser tool schemas")
    var names: [String] = []
    for (i, schema) in WebToolSchemas.browserAll.enumerated() {
        guard let data = schema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            assert(false, "browser schema \(i) is not valid JSON")
            continue
        }
        assert(obj["type"] as? String == "function", "browser schema \(i) has type=function")
        let fn = obj["function"] as? [String: Any]
        assert(fn != nil, "browser schema \(i) has function object")
        let name = fn?["name"] as? String ?? ""
        assert(!name.isEmpty, "browser schema \(i) has a name")
        names.append(name)
        assert(fn?["parameters"] is [String: Any], "browser schema \(i) has parameters object")
        // Each parses into a ToolSpec with a matching name.
        let spec = ToolSpec.fromOpenAIJSON(schema)
        assert(spec?.name == name, "browser schema \(i) parses to a ToolSpec named \(name)")
    }
    assert(names == expectedNames, "browser tool names in expected order: \(names)")
    // browser_open / click / type carry their required params.
    let open = ToolSpec.fromOpenAIJSON(WebToolSchemas.browserOpen)
    let openReq = (open?.parametersSchema["required"] as? [String]) ?? []
    assert(openReq == ["url"], "browser_open requires url")
    let click = ToolSpec.fromOpenAIJSON(WebToolSchemas.browserClick)
    let clickReq = (click?.parametersSchema["required"] as? [String]) ?? []
    assert(clickReq == ["target"], "browser_click requires target")
    let type = ToolSpec.fromOpenAIJSON(WebToolSchemas.browserType)
    let typeReq = (type?.parametersSchema["required"] as? [String]) ?? []
    assert(typeReq.contains("target") && typeReq.contains("text"), "browser_type requires target+text")
    // browser_evaluate requires a script; browser_scroll has no required params.
    let evaluate = ToolSpec.fromOpenAIJSON(WebToolSchemas.browserEvaluate)
    let evaluateReq = (evaluate?.parametersSchema["required"] as? [String]) ?? []
    assert(evaluateReq == ["script"], "browser_evaluate requires script")
    let scroll = ToolSpec.fromOpenAIJSON(WebToolSchemas.browserScroll)
    let scrollReq = (scroll?.parametersSchema["required"] as? [String]) ?? []
    assert(scrollReq.isEmpty, "browser_scroll has no required params")
}

// MARK: - BrowserTargets: selector-vs-text classification + safe JS embedding

test("BrowserTargets.looksLikeSelector classification") {
    // Selector-ish.
    assert(BrowserTargets.looksLikeSelector("#submit"), "# id is a selector")
    assert(BrowserTargets.looksLikeSelector(".btn"), ". class is a selector")
    assert(BrowserTargets.looksLikeSelector("[name=q]"), "[attr] is a selector")
    assert(BrowserTargets.looksLikeSelector("input[name=q]"), "tag[attr] is a selector")
    assert(BrowserTargets.looksLikeSelector("button.primary"), "tag.class is a selector")
    assert(BrowserTargets.looksLikeSelector("a#main"), "tag#id is a selector")
    assert(BrowserTargets.looksLikeSelector("div>span"), "tag>tag is a selector")
    // Plain visible text — NOT a selector.
    assert(!BrowserTargets.looksLikeSelector("Sign in"), "plain words are text")
    assert(!BrowserTargets.looksLikeSelector("Search"), "single word is text")
    assert(!BrowserTargets.looksLikeSelector("Add to cart"), "multi-word is text")
    assert(!BrowserTargets.looksLikeSelector(""), "empty is not a selector")
    // A sentence containing a period is treated as text (has whitespace).
    assert(!BrowserTargets.looksLikeSelector("Read more here."), "sentence with period+space is text")
}

test("BrowserTargets.jsString safely encodes arbitrary strings") {
    // Quotes / backslashes / newlines must be escaped so the JS stays valid.
    let nasty = "a\"b\\c\nd</script>"
    let lit = BrowserTargets.jsString(nasty)
    assert(lit.hasPrefix("\"") && lit.hasSuffix("\""), "jsString is a quoted literal: \(lit)")
    // Decoding the literal back as JSON yields the original string (round-trip).
    let back = try? JSONDecoder().decode(String.self, from: Data(lit.utf8))
    assert(back == nasty, "jsString round-trips through JSON: \(String(describing: back))")
    // No raw double-quote escapes the literal (would break out of the JS string).
    let inner = String(lit.dropFirst().dropLast())
    assert(!inner.contains("\"") || inner.contains("\\\""), "inner quotes are escaped")
}

test("BrowserTargets.argLiteral builds a safe JS object with asSelector") {
    // Visible text → asSelector:false.
    let a = BrowserTargets.argLiteral(target: "Sign in")
    assert(a.contains("asSelector: false"), "text target → asSelector false: \(a)")
    assert(a.contains("\"Sign in\""), "target string embedded as JSON literal")
    assert(!a.contains("text:"), "no text key when text is nil")
    // Selector → asSelector:true, plus a typed text value.
    let b = BrowserTargets.argLiteral(target: "input[name=q]", text: "Eiffel Tower")
    assert(b.contains("asSelector: true"), "selector target → asSelector true: \(b)")
    assert(b.contains("\"Eiffel Tower\""), "text embedded as JSON literal")
    // The literal is parseable as JSON5-ish? At minimum the JSON string literals
    // are valid: extract and decode the target literal.
    assert(b.hasPrefix("{") && b.hasSuffix("}"), "argLiteral is an object literal")
    // Injection attempt: a target trying to break out of the JS string must stay
    // contained inside the JSON string literal (the `"` gets escaped to `\"`).
    let inject = "\"});alert(1);//"
    let c = BrowserTargets.argLiteral(target: inject)
    // The target value is the JSON-encoded literal of `inject`; re-encode it
    // directly and assert it appears verbatim in the arg literal (so the only
    // copy of the payload is the safely-escaped one).
    let safeLit = BrowserTargets.jsString(inject)   // e.g. "\"});alert(1);\/\/"
    assert(c.contains(safeLit), "injection embedded only as the escaped JSON literal: \(c)")
    // The dangerous breakout sequence — a BARE double-quote immediately closing
    // the string then `});` — must NOT appear (the quote is escaped as \").
    assert(!c.contains("q: \"\"});"), "no bare-quote breakout")
    // Decoding the embedded literal back yields the original payload (round-trip),
    // proving it's a contained string, not executable JS.
    let decoded = try? JSONDecoder().decode(String.self, from: Data(safeLit.utf8))
    assert(decoded == inject, "escaped injection round-trips to the original payload")
}

// MARK: - BrowserState / BrowserElement Codable sanity

test("BrowserState Codable round-trip") {
    let st = BrowserState(
        finalURL: "https://e.com/x", title: "X", action: "opened https://e.com/x",
        summary: "hello world",
        elements: [BrowserElement(role: "link", label: "Next", selector: "#next"),
                   BrowserElement(role: "input", label: "Search", selector: nil)])
    let data = try! JSONEncoder().encode(st)
    let back = try! JSONDecoder().decode(BrowserState.self, from: data)
    assert(back == st, "BrowserState round-trips with nested elements")
}

// MARK: - SearchResult / value-type Codable sanity

test("SearchResult Codable round-trip") {
    let r = SearchResult(title: "T", url: "https://e.com", snippet: "S")
    let data = try! JSONEncoder().encode([r])
    let back = try! JSONDecoder().decode([SearchResult].self, from: data)
    assert(back == [r], "SearchResult array round-trips")
}

// MARK: - Results

print("\n========================================")
print("Results: \(passCount) passed, \(failCount) failed")
print("========================================")

if failCount > 0 { exit(1) } else { print("All WebEngine core tests passed!"); exit(0) }
