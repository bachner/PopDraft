// Unit tests for the streaming tool_call re-assembly + subprocess PATH repair
// (both pure, in scripts/Core.swift).
//
// Run via tests/run-tests.sh (co-compiled with scripts/Core.swift).
//
// The bug these lock down: Ollama's OpenAI-compat layer emits EVERY parallel tool
// call with `index: 0`, so index-keyed accumulation merged two calls into one
// unparseable `{"a":1}{"b":2}` argument string — the model's second call was lost,
// the first errored, and echoing that string back made Ollama reject the whole
// next request with HTTP 400 `invalid tool call arguments`.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual == expected {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)\n      expected: \(expected)\n      actual:   \(actual)")
    }
}

// MARK: - ToolArgs.splitTopLevelJSONObjects

print("\n== ToolArgs.splitTopLevelJSONObjects ==")

checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1}"), ["{\"a\":1}"],
           "a single object returns itself")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1}{\"b\":2}"),
           ["{\"a\":1}", "{\"b\":2}"], "two concatenated objects split")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1} \n {\"b\":2}"),
           ["{\"a\":1}", "{\"b\":2}"], "whitespace between objects is allowed")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"o\":{\"n\":{\"d\":1}}}{\"b\":2}"),
           ["{\"o\":{\"n\":{\"d\":1}}}", "{\"b\":2}"], "nested braces don't split early")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"q\":\"}{ not a brace\"}"),
           ["{\"q\":\"}{ not a brace\"}"], "braces inside a string are ignored")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"q\":\"esc \\\" }\"}"),
           ["{\"q\":\"esc \\\" }\"}"], "escaped quote doesn't end the string")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1"), [], "truncated object → no parts")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1}}"), [], "unbalanced close → no parts")
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"a\":1} garbage"), [],
           "trailing non-whitespace → no parts")
checkEqual(ToolArgs.splitTopLevelJSONObjects("\"just a string\""), [],
           "a bare top-level string → no parts")
checkEqual(ToolArgs.splitTopLevelJSONObjects(""), [], "empty → no parts")
// Hebrew (multi-byte) content, the exact case from the bug report.
checkEqual(ToolArgs.splitTopLevelJSONObjects("{\"query\":\"עופר בכנר\"}{\"query\":\"Ofer Bachner\"}"),
           ["{\"query\":\"עופר בכנר\"}", "{\"query\":\"Ofer Bachner\"}"],
           "multi-byte (Hebrew) values split correctly")

// MARK: - ToolArgs.sanitizedRequestArguments

print("\n== ToolArgs.sanitizedRequestArguments ==")

checkEqual(ToolArgs.sanitizedRequestArguments("{\"a\":1}"), "{\"a\":1}",
           "a valid object passes through byte-identical")
checkEqual(ToolArgs.sanitizedRequestArguments("  {\"a\": 1}  "), "  {\"a\": 1}  ",
           "surrounding whitespace is preserved (still valid JSON to a server)")
checkEqual(ToolArgs.sanitizedRequestArguments(""), "{}",
           "empty → {} (an empty string makes Ollama 400 the request)")
checkEqual(ToolArgs.sanitizedRequestArguments("   "), "{}", "whitespace-only → {}")
checkEqual(ToolArgs.sanitizedRequestArguments("{\"a\":1}{\"b\":2}"), "{\"a\":1}",
           "concatenated pair → the first object")
checkEqual(ToolArgs.sanitizedRequestArguments("not json at all"), "{}",
           "garbage → {}")
checkEqual(ToolArgs.sanitizedRequestArguments("[1,2]"), "{}",
           "a JSON array is not an arguments object → {}")
checkEqual(ToolArgs.sanitizedRequestArguments("{\"a\":1"), "{}",
           "truncated object → {}")

// MARK: - ToolCallStreamAccumulator

print("\n== ToolCallStreamAccumulator ==")

/// Helper: build a delta entry.
func delta(index: Int? = nil, id: String? = nil, name: String? = nil,
           args: Any? = nil) -> [String: Any] {
    var d: [String: Any] = [:]
    if let index = index { d["index"] = index }
    if let id = id { d["id"] = id }
    var fn: [String: Any] = [:]
    if let name = name { fn["name"] = name }
    if let args = args { fn["arguments"] = args }
    if !fn.isEmpty { d["function"] = fn }
    return d
}

// 1. The OpenAI spec shape: one call fragmented across deltas.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "call_1", name: "web_search", args: "")])
    acc.ingest([delta(index: 0, args: "{\"query\":")])
    acc.ingest([delta(index: 0, args: "\"paris\"}")])
    let calls = acc.calls
    checkEqual(calls.count, 1, "fragmented single call → 1 call")
    checkEqual(calls.first?.name ?? "", "web_search", "name from the first fragment")
    checkEqual(calls.first?.id ?? "", "call_1", "id from the first fragment")
    checkEqual(calls.first?.argumentsJSONString ?? "", "{\"query\":\"paris\"}",
               "argument fragments concatenate")
}

// 2. Spec-correct parallel calls (distinct indices).
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "a", name: "web_search", args: "{\"query\":\"x\"}")])
    acc.ingest([delta(index: 1, id: "b", name: "web_read", args: "{\"url\":\"u\"}")])
    let calls = acc.calls
    checkEqual(calls.count, 2, "distinct indices → 2 calls")
    checkEqual(calls.map { $0.name }, ["web_search", "web_read"], "both names kept, in order")
    checkEqual(calls.map { $0.id }, ["a", "b"], "both ids kept")
}

// 3. THE BUG: Ollama Cloud — both parallel calls in ONE delta, both `index: 0`,
//    distinct ids, complete arguments each.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([
        delta(index: 0, id: "call_019f", name: "web_search", args: "{\"query\":\"עופר בכנר\"}"),
        delta(index: 0, id: "call_01a0", name: "web_search", args: "{\"query\":\"Ofer Bachner\"}"),
    ])
    let calls = acc.calls
    checkEqual(calls.count, 2, "same index + distinct ids → 2 calls (was 1 merged, broken)")
    checkEqual(calls.map { $0.id }, ["call_019f", "call_01a0"], "each call keeps its own id")
    checkEqual(calls.map { $0.argumentsJSONString },
               ["{\"query\":\"עופר בכנר\"}", "{\"query\":\"Ofer Bachner\"}"],
               "arguments are NOT concatenated")
    check(calls.allSatisfy { (try? ToolArgs.parse($0.rawArguments)) != nil },
          "both calls' arguments parse")
}

// 4. Same index, different tool name (no usable ids) → separate calls.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([
        delta(index: 0, name: "web_search", args: "{\"query\":\"x\"}"),
        delta(index: 0, name: "web_read", args: "{\"url\":\"u\"}"),
    ])
    let calls = acc.calls
    checkEqual(calls.count, 2, "same index + different names → 2 calls")
    checkEqual(calls.map { $0.name }, ["web_search", "web_read"], "names preserved")
    checkEqual(calls.map { $0.id }, ["call_0", "call_1"], "blank ids get positional ids")
}

// 5. Same index, SAME name, no ids, each fragment a complete object → 2 calls.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([
        delta(index: 0, name: "web_search", args: "{\"query\":\"a\"}"),
        delta(index: 0, name: "web_search", args: "{\"query\":\"b\"}"),
    ])
    let calls = acc.calls
    checkEqual(calls.count, 2, "repeated name + fresh complete object → 2 calls")
    checkEqual(calls.map { $0.argumentsJSONString },
               ["{\"query\":\"a\"}", "{\"query\":\"b\"}"], "each keeps its own arguments")
}

// 6. A server that repeats the name on EVERY fragment of ONE call must not split.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "c1", name: "web_search", args: "{\"query\":")])
    acc.ingest([delta(index: 0, id: "c1", name: "web_search", args: "\"paris\"}")])
    let calls = acc.calls
    checkEqual(calls.count, 1, "repeated name mid-fragment does NOT split the call")
    checkEqual(calls.first?.argumentsJSONString ?? "", "{\"query\":\"paris\"}",
               "fragments still concatenate")
}

// 7. Last-resort salvage: a provider merges two objects with no id/index/name to
//    tell them apart → split at assembly time.
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "m", name: "web_search",
                      args: "{\"query\":\"a\"}{\"query\":\"b\"}")])
    let calls = acc.calls
    checkEqual(calls.count, 2, "pre-merged arguments are split into 2 calls")
    checkEqual(calls.map { $0.id }, ["m", "m_1"], "the split calls get distinct ids")
    checkEqual(calls.map { $0.argumentsJSONString },
               ["{\"query\":\"a\"}", "{\"query\":\"b\"}"], "one object per call")
}

// 8. `arguments` arriving as a decoded OBJECT (llama.cpp template quirk).
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "o", name: "web_search", args: ["query": "paris"])])
    let calls = acc.calls
    checkEqual(calls.count, 1, "object-valued arguments → 1 call")
    checkEqual(calls.first?.argumentsJSONString ?? "", "{\"query\":\"paris\"}",
               "object-valued arguments are re-encoded to a JSON string")
}

// 9. Degenerate deltas: no index, nameless fragments, empty stream.
do {
    var acc = ToolCallStreamAccumulator()
    checkEqual(acc.calls.count, 0, "no deltas → no calls")
    acc.ingest([delta(args: "{\"query\":\"x\"}")])
    checkEqual(acc.calls.count, 0, "a nameless slot is dropped")
    acc.ingest([delta(name: "web_search")])
    checkEqual(acc.calls.count, 1, "a later name adopts the pending fragment")
    checkEqual(acc.calls.first?.argumentsJSONString ?? "", "{\"query\":\"x\"}",
               "missing index defaults to slot 0")
}

// 10. A genuinely malformed single call is left alone (the agent loop reports the
//     parse error to the model, which can then retry).
do {
    var acc = ToolCallStreamAccumulator()
    acc.ingest([delta(index: 0, id: "x", name: "web_search", args: "{\"query\":")])
    let calls = acc.calls
    checkEqual(calls.count, 1, "truncated arguments stay one call")
    checkEqual(calls.first?.argumentsJSONString ?? "", "{\"query\":",
               "the raw (malformed) string is preserved for the error message")
}

// MARK: - SubprocessPATH

print("\n== SubprocessPATH ==")

let home = "/Users/tester"

do {
    let path = SubprocessPATH.augmented(base: "/usr/bin:/bin:/usr/sbin:/sbin", home: home)
    let dirs = path.split(separator: ":").map(String.init)
    checkEqual(Array(dirs.prefix(4)), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"],
               "the inherited PATH keeps priority, in order")
    check(dirs.contains("/opt/homebrew/bin"), "Apple-silicon Homebrew bin is added")
    check(dirs.contains("/usr/local/bin"), "Intel Homebrew / manual bin is added")
    check(dirs.contains("\(home)/.volta/bin"), "volta shim dir is added")
    check(dirs.contains("\(home)/.bun/bin"), "bun bin is added")
    check(dirs.contains("\(home)/.local/bin"), "uv/uvx bin is added")
    checkEqual(dirs.count, Set(dirs).count, "no duplicate entries")
}

do {
    // An already-rich PATH must not gain duplicates or lose its ordering.
    let path = SubprocessPATH.augmented(base: "/opt/homebrew/bin:/usr/bin", home: home)
    let dirs = path.split(separator: ":").map(String.init)
    checkEqual(Array(dirs.prefix(2)), ["/opt/homebrew/bin", "/usr/bin"],
               "existing entries stay first, in the user's order")
    checkEqual(dirs.filter { $0 == "/opt/homebrew/bin" }.count, 1,
               "an already-present dir isn't appended twice")
}

checkEqual(SubprocessPATH.augmented(base: nil, home: home)
            .hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin"), true,
           "a nil PATH falls back to the launchd default")
checkEqual(SubprocessPATH.augmented(base: "", home: home)
            .hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin"), true,
           "an empty PATH falls back to the launchd default")

do {
    let path = SubprocessPATH.augmented(base: "/usr/bin", home: home,
                                        discovered: ["\(home)/.nvm/versions/node/v22.3.0/bin"])
    let dirs = path.split(separator: ":").map(String.init)
    check(dirs.contains("\(home)/.nvm/versions/node/v22.3.0/bin"),
          "a discovered nvm dir is included")
    check(dirs.firstIndex(of: "\(home)/.nvm/versions/node/v22.3.0/bin")!
            < dirs.firstIndex(of: "/opt/homebrew/bin")!,
          "discovered dirs rank above the static fallbacks")
}

// resolve() against a fake filesystem.
do {
    let installed: Set<String> = ["/opt/homebrew/bin/npx", "/usr/bin/env",
                                  "/Users/tester/bin/my-server"]
    let exists: (String) -> Bool = { installed.contains($0) }
    let path = "/usr/bin:/bin:/opt/homebrew/bin"

    checkEqual(SubprocessPATH.resolve("npx", path: path, isExecutable: exists),
               "/opt/homebrew/bin/npx", "a bare command resolves from a later PATH entry")
    checkEqual(SubprocessPATH.resolve("env", path: path, isExecutable: exists),
               "/usr/bin/env", "the FIRST matching PATH entry wins")
    checkEqual(SubprocessPATH.resolve("uvx", path: path, isExecutable: exists), nil,
               "a missing command resolves to nil (fail fast, don't spawn)")
    checkEqual(SubprocessPATH.resolve("/Users/tester/bin/my-server", path: path,
                                      isExecutable: exists),
               "/Users/tester/bin/my-server", "an absolute path passes through")
    checkEqual(SubprocessPATH.resolve("/nope/my-server", path: path, isExecutable: exists), nil,
               "a non-existent absolute path is nil, not spawned")
    checkEqual(SubprocessPATH.resolve("  npx  ", path: path, isExecutable: exists),
               "/opt/homebrew/bin/npx", "the command name is trimmed")
    checkEqual(SubprocessPATH.resolve("", path: path, isExecutable: exists), nil,
               "an empty command is nil")
}

// MARK: - MCPProbeResult labels for the new failure modes

print("\n== MCPProbeResult.label ==")

checkEqual(MCPProbeResult.from(toolCount: nil,
                               error: "command 'npx' not found for MCP server 'Gmail'").label,
           "command not found", "a missing launcher reads as 'command not found', not auth")
checkEqual(MCPProbeResult.from(toolCount: nil,
                               error: "MCP server 'Gmail' exited (status 1) before answering").label,
           "exited on start — check auth/args", "an early exit reads as an exit, not a timeout")
checkEqual(MCPProbeResult.from(toolCount: nil,
                               error: "timed out waiting for MCP response id=1").label,
           "needs auth / unreachable", "a real timeout still reads as needs-auth")
checkEqual(MCPProbeResult.from(toolCount: 14, error: nil).label, "14 tools",
           "a reachable server reports its tool count")

// MARK: - Summary

print("\n==========================================")
if failures == 0 {
    print("test-toolcallstream: ALL \(checks) CHECKS PASSED")
    exit(0)
} else {
    print("test-toolcallstream: \(failures)/\(checks) CHECKS FAILED")
    exit(1)
}
