// test-ippinning.swift — CI-pure unit tests for the PR11 connection-level
// IP-pinning logic (Core.swift). NO network, NO WebKit, NO Network framework.
//
// Compile + run WITH Core.swift:
//   swiftc -o /tmp/test-ippinning tests/test-ippinning.swift scripts/Core.swift && /tmp/test-ippinning
//
// Covers:
//   - SafetyGuard.pinnedAddress: picks ONE validated public IP from a resolved
//     set, rejects when ANY address is blocked (metadata / RFC1918 / loopback /
//     link-local / ULA / 0.0.0.0), rejects an empty set (fail-closed), prefers
//     IPv4, and honors the test-loopback escape hatch.
//   - ProxyParser.parseConnect: CONNECT host:port extraction + malformed reject.
//   - ProxyParser.parseHTTP: plain-HTTP absolute-form + origin-form target.
//   - ProxyParser.header / splitHostPort edge cases (IPv6 brackets, default port).

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

print("Running IP-pinning (pure) tests...\n")

// MARK: - pinnedAddress: pick a validated public IP

test("pinnedAddress picks a public IP") {
    if case .allowed(let ip) = SafetyGuard.pinnedAddress(forResolved: ["93.184.216.34"]) {
        assert(ip == "93.184.216.34", "single public IPv4 picked")
    } else { assert(false, "single public IPv4 should be allowed") }

    if case .allowed(let ip) = SafetyGuard.pinnedAddress(forResolved: ["2606:2800:220:1:248:1893:25c8:1946"]) {
        assert(ip == "2606:2800:220:1:248:1893:25c8:1946", "public IPv6 picked")
    } else { assert(false, "public IPv6 should be allowed") }

    // Prefer IPv4 when both are present.
    if case .allowed(let ip) = SafetyGuard.pinnedAddress(forResolved: ["2606:2800:220:1::1", "93.184.216.34"]) {
        assert(ip == "93.184.216.34", "IPv4 preferred over IPv6 (got \(ip))")
    } else { assert(false, "mixed public set should be allowed") }
}

// MARK: - pinnedAddress: ANY blocked address rejects (fail-closed)

test("pinnedAddress rejects when ANY address is blocked") {
    // Cloud metadata — the marquee rebinding target.
    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["169.254.169.254"]) {
        assert(true, "metadata IP blocked")
    } else { assert(false, "169.254.169.254 must be blocked") }

    // A public + a private address together → reject (rebinding shape).
    if case .blocked(let reason) = SafetyGuard.pinnedAddress(forResolved: ["93.184.216.34", "10.0.0.5"]) {
        assert(reason.contains("10.0.0.5"), "blocked reason names the private IP (got \(reason))")
    } else { assert(false, "public+private set must be blocked") }

    // Loopback.
    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["127.0.0.1"]) {
        assert(true, "loopback blocked")
    } else { assert(false, "127.0.0.1 must be blocked") }

    // RFC1918 ranges.
    for ip in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1"] {
        if case .blocked = SafetyGuard.pinnedAddress(forResolved: [ip]) {
            assert(true, "\(ip) blocked")
        } else { assert(false, "\(ip) must be blocked") }
    }

    // Link-local, ULA, unspecified.
    for ip in ["169.254.10.10", "fd00::1", "fe80::1", "0.0.0.0", "::"] {
        if case .blocked = SafetyGuard.pinnedAddress(forResolved: [ip]) {
            assert(true, "\(ip) blocked")
        } else { assert(false, "\(ip) must be blocked") }
    }

    // IPv4-mapped IPv6 of a private address must also be blocked.
    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["::ffff:10.0.0.1"]) {
        assert(true, "IPv4-mapped private blocked")
    } else { assert(false, "::ffff:10.0.0.1 must be blocked") }
}

// MARK: - pinnedAddress: empty set is fail-closed

test("pinnedAddress fails closed on empty resolution") {
    if case .blocked(let r) = SafetyGuard.pinnedAddress(forResolved: []) {
        assert(r.contains("no addresses"), "empty set blocked (got \(r))")
    } else { assert(false, "empty resolution must be blocked (fail-closed)") }

    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["", "   "]) {
        assert(true, "all-blank set blocked")
    } else { assert(false, "blank-only set must be blocked") }
}

// MARK: - pinnedAddress: test-loopback escape hatch

test("pinnedAddress test-loopback hatch") {
    // With the hatch on, a loopback address is allowed (fixtures).
    if case .allowed(let ip) = SafetyGuard.pinnedAddress(forResolved: ["127.0.0.1"], allowTestLoopback: true) {
        assert(ip == "127.0.0.1", "loopback allowed under test hatch")
    } else { assert(false, "loopback should be allowed under test hatch") }
    // But a NON-loopback under the hatch is rejected (hatch is loopback-only).
    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["93.184.216.34"], allowTestLoopback: true) {
        assert(true, "public IP rejected under loopback-only hatch")
    } else { assert(false, "non-loopback must be rejected under the loopback hatch") }
}

// MARK: - parseIPv4 canonical-form (leading-zero / hex octal rebinding guard)

test("parseIPv4 rejects non-canonical octets (octal/hex)") {
    // Leading-zero octets are read as OCTAL by inet_aton (CFNetwork/WebKit), so
    // they must NOT parse as a bare decimal IPv4 here — else 0177.0.0.1 (=127.x
    // loopback) would be mis-classified as public 177.x on the macOS-13 backstop.
    assert(SafetyGuard.parseIPv4("0177.0.0.1") == nil, "0177.0.0.1 (octal loopback) rejected")
    assert(SafetyGuard.parseIPv4("010.0.0.1") == nil, "010.0.0.1 (leading-zero) rejected")
    assert(SafetyGuard.parseIPv4("0x7f.0.0.1") == nil, "0x7f.0.0.1 (hex) rejected")
    assert(SafetyGuard.parseIPv4("127.0.0.01") == nil, "trailing leading-zero octet rejected")

    // Canonical addresses still parse to the right octets (no regression).
    assert(SafetyGuard.parseIPv4("127.0.0.1") == [127, 0, 0, 1], "127.0.0.1 parses")
    assert(SafetyGuard.parseIPv4("10.0.0.5") == [10, 0, 0, 5], "10.0.0.5 parses")
    assert(SafetyGuard.parseIPv4("192.168.1.1") == [192, 168, 1, 1], "192.168.1.1 parses")
    assert(SafetyGuard.parseIPv4("8.8.8.8") == [8, 8, 8, 8], "8.8.8.8 parses")
    assert(SafetyGuard.parseIPv4("0.0.0.0") == [0, 0, 0, 0], "0.0.0.0 parses (single 0 octets ok)")
    assert(SafetyGuard.parseIPv4("169.254.169.254") == [169, 254, 169, 254], "metadata IP parses")
}

test("octal-loopback literal is not classified as public") {
    // parseIPv4 now returns nil for the octal form, so it is NOT treated as a
    // bare IPv4 — isLiteralHostBlocked falls through to the resolving caller,
    // which getaddrinfo-normalizes it to 127.0.0.1 and blocks the resolved IP.
    assert(SafetyGuard.parseIPv4("0177.0.0.1") == nil, "octal literal not a bare IPv4")
    // The realistic flow: the RESOLVED loopback address is rejected by the pin.
    if case .blocked = SafetyGuard.pinnedAddress(forResolved: ["127.0.0.1"]) {
        assert(true, "resolved octal-loopback (127.0.0.1) is blocked")
    } else { assert(false, "127.0.0.1 must be blocked") }
}

// MARK: - ProxyParser.parseConnect

test("parseConnect host:port") {
    let t = ProxyParser.parseConnect("CONNECT example.com:443 HTTP/1.1")
    assert(t?.host == "example.com" && t?.port == 443, "CONNECT example.com:443 parsed")

    let t2 = ProxyParser.parseConnect("CONNECT api.github.com:8443 HTTP/1.1")
    assert(t2?.host == "api.github.com" && t2?.port == 8443, "custom port parsed")

    // Bracketed IPv6.
    let t3 = ProxyParser.parseConnect("CONNECT [2606:2800::1]:443 HTTP/1.1")
    assert(t3?.host == "2606:2800::1" && t3?.port == 443, "bracketed IPv6 CONNECT parsed (got \(String(describing: t3)))")

    // Case-insensitive method.
    let t4 = ProxyParser.parseConnect("connect example.com:443 HTTP/1.1")
    assert(t4?.host == "example.com", "lowercase connect accepted")
}

test("parseConnect rejects malformed") {
    assert(ProxyParser.parseConnect("GET http://example.com/ HTTP/1.1") == nil, "GET is not CONNECT")
    assert(ProxyParser.parseConnect("CONNECT example.com HTTP/1.1") == nil, "CONNECT without port rejected")
    assert(ProxyParser.parseConnect("CONNECT") == nil, "bare CONNECT rejected")
    assert(ProxyParser.parseConnect("") == nil, "empty line rejected")
    assert(ProxyParser.parseConnect("CONNECT example.com:notaport HTTP/1.1") == nil, "non-numeric port rejected")
    assert(ProxyParser.parseConnect("CONNECT example.com:99999 HTTP/1.1") == nil, "out-of-range port rejected")
}

// MARK: - ProxyParser.parseHTTP

test("parseHTTP absolute-form") {
    let t = ProxyParser.parseHTTP(requestLine: "GET http://example.com/path?x=1 HTTP/1.1", hostHeader: nil)
    assert(t?.method == "GET", "method GET")
    assert(t?.host == "example.com", "host example.com")
    assert(t?.port == 80, "default port 80")
    assert(t?.path == "/path?x=1", "origin path+query preserved (got \(String(describing: t?.path)))")

    let t2 = ProxyParser.parseHTTP(requestLine: "POST http://example.com:8080/api HTTP/1.1", hostHeader: nil)
    assert(t2?.port == 8080, "explicit port 8080")
    assert(t2?.method == "POST", "method POST")

    // Root path defaults to "/".
    let t3 = ProxyParser.parseHTTP(requestLine: "GET http://example.com HTTP/1.1", hostHeader: nil)
    assert(t3?.path == "/", "missing path defaults to / (got \(String(describing: t3?.path)))")
}

test("parseHTTP origin-form with Host header") {
    let t = ProxyParser.parseHTTP(requestLine: "GET /path HTTP/1.1", hostHeader: "example.com")
    assert(t?.host == "example.com" && t?.path == "/path", "origin-form uses Host header")
    let t2 = ProxyParser.parseHTTP(requestLine: "GET /path HTTP/1.1", hostHeader: "example.com:8080")
    assert(t2?.port == 8080, "Host header port honored")
}

test("parseHTTP rejects non-http and malformed") {
    assert(ProxyParser.parseHTTP(requestLine: "CONNECT example.com:443 HTTP/1.1", hostHeader: nil) == nil, "CONNECT not an HTTP forward")
    assert(ProxyParser.parseHTTP(requestLine: "GET https://example.com/ HTTP/1.1", hostHeader: nil) == nil, "https absolute-form never arrives plain")
    assert(ProxyParser.parseHTTP(requestLine: "GET ftp://example.com/ HTTP/1.1", hostHeader: nil) == nil, "ftp scheme rejected")
    assert(ProxyParser.parseHTTP(requestLine: "GET /path HTTP/1.1", hostHeader: nil) == nil, "origin-form without Host rejected")
    assert(ProxyParser.parseHTTP(requestLine: "garbage", hostHeader: nil) == nil, "garbage rejected")
    assert(ProxyParser.parseHTTP(requestLine: "GET /x NOTHTTP", hostHeader: "h") == nil, "bad version token rejected")
}

// MARK: - splitHostPort + header helpers

test("splitHostPort edge cases") {
    assert(ProxyParser.splitHostPort("h:80", defaultPort: nil)?.port == 80, "explicit port")
    assert(ProxyParser.splitHostPort("h", defaultPort: 443)?.port == 443, "default port applied")
    assert(ProxyParser.splitHostPort("h", defaultPort: nil) == nil, "no port + no default → nil")
    assert(ProxyParser.splitHostPort("[::1]:8443", defaultPort: nil)?.host == "::1", "bracketed IPv6 host")
    assert(ProxyParser.splitHostPort("[2606:2800::1]", defaultPort: 443)?.port == 443, "bracketed IPv6 default port")
    assert(ProxyParser.splitHostPort("2606:2800::1", defaultPort: 443)?.host == "2606:2800::1", "bare IPv6 uses default port")
    assert(ProxyParser.splitHostPort("", defaultPort: 80) == nil, "empty authority → nil")
}

test("header extraction is case-insensitive") {
    let lines = ["Host: example.com", "User-Agent: x", "PROXY-Connection: keep-alive"]
    assert(ProxyParser.header("host", in: lines) == "example.com", "host (lower) found")
    assert(ProxyParser.header("HOST", in: lines) == "example.com", "HOST (upper) found")
    assert(ProxyParser.header("proxy-connection", in: lines) == "keep-alive", "proxy-connection found")
    assert(ProxyParser.header("missing", in: lines) == nil, "absent header → nil")
}

// MARK: - Summary

print("\n========================================")
print("IP-pinning core: \(passCount) passed, \(failCount) failed")
print("========================================")
exit(failCount == 0 ? 0 : 1)
