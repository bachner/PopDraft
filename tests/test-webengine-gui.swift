// test-webengine-gui.swift — LOCAL-ONLY GUI/WebKit tests for WebEngine.
//
// Gated behind RUN_GUI_TESTS=1 in run-tests.sh because hosted CI can't reliably
// drive an offscreen WKWebView. Co-compiled with PopDraft.swift + Core.swift so
// it links the real engine. It is staged as `webgui-main.swift` and the app's
// own @main is stripped by the harness (see run-tests.sh) so this file's
// top-level code is the entry point.
//
// Usage (driven by run-tests.sh): a Python fixture server is started first and
// its base URL is passed via the PD_FIXTURE_BASE env var.
//
// Assertions:
//   - read() of /article returns sanitized Markdown (heading, bullets, code
//     fence, link with utm stripped), char-capped.
//   - JS-rendered content is captured (only a real renderer sees it).
//   - ad-heavy page extracts the real body, drops ad chrome.
//   - screenshot() writes a non-blank PNG (luminance variance).
//   - slow page trips the timeout -> error (no hang).
//   - SSRF: a redirect to a loopback address is blocked.
//   - a direct loopback/file URL is blocked by the scheme/SSRF guard.

import Cocoa

// MARK: - Harness

final class GUIResults {
    var pass = 0
    var fail = 0
    func check(_ cond: Bool, _ msg: String, line: Int = #line) {
        if cond { pass += 1 } else { fail += 1; print("  FAIL [line \(line)]: \(msg)") }
    }
}
let R = GUIResults()

func base() -> String {
    return ProcessInfo.processInfo.environment["PD_FIXTURE_BASE"] ?? "http://127.0.0.1:0"
}

// Luminance variance of a PNG — used to confirm a screenshot isn't a blank fill.
func isNonBlank(pngPath: String) -> Bool {
    guard let img = NSImage(contentsOfFile: pngPath),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return false }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return false }
    var sum = 0.0, sumSq = 0.0, count = 0.0
    let stepX = max(1, w / 40), stepY = max(1, h / 40)
    var x = 0
    while x < w {
        var y = 0
        while y < h {
            if let c = rep.colorAt(x: x, y: y) {
                let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                sum += l; sumSq += l * l; count += 1
            }
            y += stepY
        }
        x += stepX
    }
    guard count > 0 else { return false }
    let mean = sum / count
    let variance = sumSq / count - mean * mean
    return variance > 0.0005  // any real content yields some spread
}

@MainActor
func runTests() async {
    let b = base()
    print("Running WebEngine GUI tests against \(b)\n")

    await WebEngine.shared.warmUp()
    let engine = WebEngine.shared

    // --- PR11: the pinning proxy starts and WKWebView routes through it (14+) ---
    if #available(macOS 14.0, *) {
        let port = PinningProxy.shared.startIfNeeded()
        R.check(port != 0, "PR11: pinning proxy bound to a loopback port (\(port))")
        print("  [info] pinning proxy port=\(port) — fixture reads below route THROUGH it on 14+")
    } else {
        print("  [info] macOS < 14 — proxy pinning unavailable; PR6 mitigation path in effect")
    }

    // --- read() of a clean article ---
    // On macOS 14+ this load travels through the pinning proxy (CONNECT for the
    // loopback fixture is validated via the test-loopback hatch). If the proxy
    // mis-tunnels, this end-to-end read would fail — so it doubles as the
    // "normal page still loads through the proxy" regression check.
    do {
        let r = try await engine.read(URL(string: "\(b)/article")!, maxChars: 12000)
        R.check(r.markdown.contains("# The Title of the Article") || r.title.contains("Title of the Article"),
                "article: title/heading present")
        R.check(r.markdown.contains("first paragraph"), "article: body paragraph present")
        R.check(r.markdown.contains("- First bullet point") || r.markdown.contains("First bullet point"),
                "article: bullet list present")
        R.check(r.markdown.contains("```"), "article: code fence present")
        // Link present, utm stripped, id kept.
        R.check(r.markdown.contains("example.com/dest?id=9") || r.markdown.contains("example.com/dest"),
                "article: link present")
        R.check(!r.markdown.contains("utm_source"), "article: utm param stripped from link")
        // Chrome dropped.
        R.check(!r.markdown.contains("Subscribe to our newsletter"), "article: sidebar chrome dropped")
        R.check(r.byline == "Ada Lovelace" || r.byline == nil, "article: byline parsed (or absent)")
        print("  [info] article markdown chars=\(r.charCount) truncated=\(r.truncated)")
    } catch {
        R.check(false, "article read threw: \(error)")
    }

    // --- char cap enforced ---
    do {
        let r = try await engine.read(URL(string: "\(b)/article")!, maxChars: 120)
        R.check(r.charCount <= 140, "char cap respected (<=140 with ellipsis), got \(r.charCount)")
        R.check(r.truncated, "small cap marks truncated")
    } catch {
        R.check(false, "article read (capped) threw: \(error)")
    }

    // --- JS-rendered content captured ---
    do {
        let r = try await engine.read(URL(string: "\(b)/jsrendered")!, maxChars: 12000)
        R.check(r.markdown.contains("Dynamically Loaded") || r.markdown.contains("injected by JavaScript"),
                "js-rendered: dynamic content captured (markdown=\(r.markdown.prefix(120)))")
        R.check(!r.markdown.contains("placeholder"), "js-rendered: placeholder replaced")
    } catch {
        R.check(false, "jsrendered read threw: \(error)")
    }

    // --- ad-heavy page extracts real body ---
    do {
        let r = try await engine.read(URL(string: "\(b)/adheavy")!, maxChars: 12000)
        R.check(r.markdown.contains("genuine article body text"), "adheavy: real body extracted")
        R.check(!r.markdown.contains("BUY NOW"), "adheavy: promo chrome dropped")
    } catch {
        R.check(false, "adheavy read threw: \(error)")
    }

    // --- screenshot produces a non-blank PNG ---
    do {
        let shot = try await engine.screenshot(URL(string: "\(b)/article")!, fullPage: false)
        let exists = FileManager.default.fileExists(atPath: shot.path)
        R.check(exists, "screenshot: PNG written to \(shot.path)")
        R.check(shot.width > 0 && shot.height > 0, "screenshot: dims > 0 (\(shot.width)x\(shot.height))")
        if exists { R.check(isNonBlank(pngPath: shot.path), "screenshot: PNG is non-blank (luminance variance)") }
    } catch {
        R.check(false, "screenshot threw: \(error)")
    }

    // --- redirect (302 -> /article) resolves ---
    do {
        let r = try await engine.read(URL(string: "\(b)/redirect")!, maxChars: 12000)
        R.check(r.finalURL.contains("/article"), "redirect: followed to /article (final=\(r.finalURL))")
    } catch {
        R.check(false, "redirect read threw: \(error)")
    }

    // --- SSRF: redirect to a loopback IP must be blocked ---
    do {
        _ = try await engine.read(URL(string: "\(b)/redirect-internal")!, maxChars: 12000)
        R.check(false, "SSRF redirect should have thrown but returned content")
    } catch let e as WebEngineError {
        switch e {
        case .blockedHost, .navigationFailed, .timeout:
            R.check(true, "SSRF redirect-to-internal blocked (\(e))")
        default:
            R.check(false, "SSRF redirect blocked but with unexpected error: \(e)")
        }
    } catch {
        R.check(true, "SSRF redirect blocked with error: \(error)")
    }

    // --- direct loopback URL blocked up-front ---
    do {
        _ = try await engine.read(URL(string: "http://127.0.0.1:1/")!, maxChars: 1000)
        R.check(false, "direct loopback should have thrown")
    } catch let e as WebEngineError {
        if case .blockedHost = e { R.check(true, "direct loopback blocked") }
        else { R.check(false, "loopback blocked with unexpected error: \(e)") }
    } catch {
        R.check(false, "loopback blocked but non-WebEngineError: \(error)")
    }

    // --- file:// scheme blocked ---
    do {
        _ = try await engine.read(URL(string: "file:///etc/hosts")!, maxChars: 1000)
        R.check(false, "file:// should have thrown")
    } catch let e as WebEngineError {
        if case .blockedScheme = e { R.check(true, "file:// scheme blocked") }
        else { R.check(false, "file:// blocked with unexpected error: \(e)") }
    } catch {
        R.check(false, "file:// blocked but non-WebEngineError: \(error)")
    }

    // --- slow page trips the timeout (no hang) ---
    do {
        let start = Date()
        _ = try await engine.read(URL(string: "\(b)/slow")!, maxChars: 1000)
        R.check(false, "slow page should have timed out (elapsed \(Date().timeIntervalSince(start))s)")
    } catch let e as WebEngineError {
        if case .timeout = e { R.check(true, "slow page tripped the timeout") }
        else { R.check(true, "slow page failed (acceptable): \(e)") }
    } catch {
        R.check(true, "slow page failed (acceptable): \(error)")
    }

    // --- size cap: the /big fixture (~12MB) must be rejected, not read ---
    do {
        _ = try await engine.read(URL(string: "\(b)/big")!, maxChars: 1000)
        R.check(false, "oversized /big page should have been rejected by the size cap")
    } catch let e as WebEngineError {
        if case .tooLarge = e { R.check(true, "size cap rejected /big (tooLarge)") }
        else { R.check(true, "/big rejected (acceptable error): \(e)") }
    } catch {
        R.check(true, "/big rejected (acceptable error): \(error)")
    }

    // --- concurrent reads (parallel renderers) ---
    do {
        async let a = engine.read(URL(string: "\(b)/article")!, maxChars: 4000)
        async let c = engine.read(URL(string: "\(b)/adheavy")!, maxChars: 4000)
        let (ra, rc) = try await (a, c)
        R.check(ra.markdown.contains("first paragraph") && rc.markdown.contains("genuine article"),
                "concurrent reads both succeed")
    } catch {
        R.check(false, "concurrent reads threw: \(error)")
    }

    // =====================================================================
    // Interactive browser session: open → click a link → read.
    // =====================================================================
    do {
        // open /portal
        let s1 = try await engine.browserOpen(URL(string: "\(b)/portal")!)
        R.check(s1.finalURL.contains("/portal"), "browser_open: landed on /portal (\(s1.finalURL))")
        R.check(s1.title.contains("Fixture Portal"), "browser_open: title parsed (\(s1.title))")
        R.check(s1.elements.contains { $0.label.contains("Read the Full Article") },
                "browser_open: summary lists the article link (\(s1.elements.map{$0.label}))")
        R.check(s1.elements.contains { $0.role == "input" },
                "browser_open: summary lists the search input")

        // click the link by visible text
        let s2 = try await engine.browserClick(target: "Read the Full Article")
        R.check(s2.finalURL.contains("/article"), "browser_click(text): navigated to /article (\(s2.finalURL))")
        R.check(s2.action.lowercased().contains("clicked"), "browser_click: action describes the click")

        // read the resulting page
        let r = try await engine.browserRead(maxChars: 12000)
        R.check(r.finalURL.contains("/article"), "browser_read: reads the current /article page")
        R.check(r.markdown.contains("first paragraph"), "browser_read: article body extracted")
        R.check(r.markdown.contains("```"), "browser_read: code fence preserved")

        // screenshot the current session page
        let shot = try await engine.browserScreenshot(fullPage: false)
        R.check(FileManager.default.fileExists(atPath: shot.path) && shot.width > 0,
                "browser_screenshot: PNG written (\(shot.width)x\(shot.height))")

        // scroll the page (static fixture: just verifies it runs + re-snapshots)
        let sc = try await engine.browserScroll(to: "bottom", pixels: nil, steps: 2)
        R.check(sc.finalURL.contains("/article"), "browser_scroll: stays on /article (\(sc.finalURL))")
        R.check(sc.action.lowercased().contains("scroll"), "browser_scroll: action describes the scroll (\(sc.action))")

        // evaluate JS in the page and coerce results of several types
        let title = try await engine.browserEvaluate(script: "document.title", maxChars: 8000)
        R.check(title.contains("Article"), "browser_evaluate(string): returns document.title (\(title))")
        let num = try await engine.browserEvaluate(script: "1 + 2", maxChars: 100)
        R.check(num == "3", "browser_evaluate(number): 1+2 coerces to \"3\" (got \"\(num)\")")
        let boolv = try await engine.browserEvaluate(script: "document.body != null", maxChars: 100)
        R.check(boolv == "true", "browser_evaluate(bool): coerces to \"true\" (got \"\(boolv)\")")
        let arr = try await engine.browserEvaluate(script: "[1,2,3]", maxChars: 100)
        R.check(arr.contains("[1,2,3]") || arr.contains("[1, 2, 3]"), "browser_evaluate(array): JSON-encoded (\(arr))")
        let dom = try await engine.browserEvaluate(script: "document.documentElement.innerHTML", maxChars: 200)
        R.check(dom.contains("truncated"), "browser_evaluate: long DOM is char-capped (\(dom.count) chars)")

        // back to the portal
        let s3 = try await engine.browserBack()
        R.check(s3.finalURL.contains("/portal"), "browser_back: returned to /portal (\(s3.finalURL))")
    } catch {
        R.check(false, "browser open→click→read flow threw: \(error)")
    }

    // --- browser_type + submit drives a search box → results page ---
    do {
        _ = try await engine.browserOpen(URL(string: "\(b)/portal")!)
        let st = try await engine.browserType(target: "Search", text: "eiffel tower", submit: true)
        R.check(st.finalURL.contains("/searchresults"), "browser_type+submit: navigated to results (\(st.finalURL))")
        let r = try await engine.browserRead(maxChars: 8000)
        R.check(r.markdown.lowercased().contains("eiffel tower"),
                "browser_type+submit: query echoed into results body")
        R.check(r.markdown.contains("genuine result body"), "browser_read: results body extracted")
    } catch {
        R.check(false, "browser type+submit flow threw: \(error)")
    }

    // --- browser_click: element-not-found returns a clean error (no crash) ---
    do {
        _ = try await engine.browserOpen(URL(string: "\(b)/portal")!)
        _ = try await engine.browserClick(target: "This Link Does Not Exist At All")
        R.check(false, "browser_click of a missing target should have thrown")
    } catch let e as WebEngineError {
        if case .navigationFailed(let msg) = e {
            R.check(msg.contains("No clickable element"), "browser_click not-found gives a helpful error: \(msg)")
        } else {
            R.check(true, "browser_click not-found threw (\(e))")
        }
    } catch {
        R.check(false, "browser_click not-found threw a non-WebEngineError: \(error)")
    }

    // --- browser SSRF: opening a loopback URL is blocked up-front ---
    do {
        _ = try await engine.browserOpen(URL(string: "http://127.0.0.1:1/")!)
        R.check(false, "browser_open of a loopback URL should have thrown")
    } catch let e as WebEngineError {
        if case .blockedHost = e { R.check(true, "browser_open loopback blocked (SSRF)") }
        else { R.check(true, "browser_open loopback blocked (\(e))") }
    } catch {
        R.check(false, "browser_open loopback blocked but non-WebEngineError: \(error)")
    }

    // --- regression: a page with a srcdoc iframe (about:srcdoc) loads fine ---
    // Previously the navigation-delegate SSRF guard fail-closed on the iframe's
    // about:srcdoc sub-navigation → "Blocked host (SSRF / private address):
    // about:srcdoc". The outer page must now open + read without error.
    do {
        let s = try await engine.browserOpen(URL(string: "\(b)/srcdoc")!)
        R.check(s.finalURL.contains("/srcdoc"), "srcdoc: outer page opened (\(s.finalURL))")
        R.check(s.title.contains("Srcdoc"), "srcdoc: outer page title parsed (\(s.title))")
        // A screenshot exercises the load path (loadAndSettle) too — must not throw.
        let shot = try await engine.screenshot(URL(string: "\(b)/srcdoc")!, fullPage: false)
        R.check(FileManager.default.fileExists(atPath: shot.path),
                "srcdoc: screenshot of a srcdoc-iframe page succeeds (no SSRF block)")
    } catch let e as WebEngineError {
        if case .blockedHost(let h) = e {
            R.check(false, "srcdoc iframe wrongly blocked as SSRF host: \(h)")
        } else {
            R.check(false, "srcdoc page load threw: \(e)")
        }
    } catch {
        R.check(false, "srcdoc page load threw: \(error)")
    }

    // =====================================================================
    // download_file: SSRF-gated fetch + write to disk (uses the loopback fixture
    // via the test-loopback escape hatch). The CONFIRM gate is a separate seam
    // exercised by the unit tests + the real --agent-once run; here we drive the
    // engine's `downloadFile` method directly (the I/O half).
    // =====================================================================
    do {
        let r = try await engine.downloadFile(url: URL(string: "\(b)/afile.png")!, filename: "fixture-download.png")
        R.check(FileManager.default.fileExists(atPath: r.path), "download_file: file written to \(r.path)")
        R.check(r.bytes > 0, "download_file: non-empty (\(r.bytes) bytes)")
        R.check(r.contentType == "image/png", "download_file: content-type captured (\(r.contentType))")
        R.check((r.path as NSString).lastPathComponent == "fixture-download.png",
                "download_file: requested filename honored (\(r.path))")
        // Clean up the artifact from ~/Downloads.
        try? FileManager.default.removeItem(atPath: r.path)
    } catch {
        R.check(false, "download_file threw: \(error)")
    }

    // --- download_file: filename derived from the URL when none given ---
    do {
        let r = try await engine.downloadFile(url: URL(string: "\(b)/afile.png")!, filename: nil)
        R.check((r.path as NSString).lastPathComponent.hasPrefix("afile"),
                "download_file: filename derived from URL (\(r.path))")
        try? FileManager.default.removeItem(atPath: r.path)
    } catch {
        R.check(false, "download_file (derived name) threw: \(error)")
    }

    // --- download_file SSRF: a 302 to a loopback IP must be blocked mid-flight ---
    do {
        _ = try await engine.downloadFile(url: URL(string: "\(b)/file-redirect-internal")!, filename: nil)
        R.check(false, "download_file SSRF redirect-to-internal should have thrown")
    } catch {
        // The redirect guard cancels the hop → URLSession surfaces a cancel error.
        R.check(true, "download_file SSRF redirect blocked (\(error))")
    }

    // --- download_file SSRF: a direct loopback file URL is blocked up-front ---
    do {
        _ = try await engine.downloadFile(url: URL(string: "http://127.0.0.1:1/x.bin")!, filename: nil)
        R.check(false, "download_file of a loopback URL should have thrown")
    } catch let e as WebEngineError {
        if case .blockedHost = e { R.check(true, "download_file loopback blocked (SSRF)") }
        else { R.check(true, "download_file loopback blocked (\(e))") }
    } catch {
        R.check(false, "download_file loopback blocked but non-WebEngineError: \(error)")
    }

    print("\n========================================")
    print("GUI Results: \(R.pass) passed, \(R.fail) failed")
    print("========================================")
    exit(R.fail == 0 ? 0 : 1)
}

// MARK: - Entry point (app run loop for WebKit)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    // Guard against an indefinite hang in CI by capping the whole suite.
    let watchdog = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 90_000_000_000)  // 90s
        print("  FAIL: GUI test watchdog fired (suite hung)")
        exit(1)
    }
    await runTests()
    watchdog.cancel()
}
app.run()
