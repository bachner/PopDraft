// test-toolrunner.swift — unit tests for the parallel ToolRunner (PR7).
//
// Co-compiled with scripts/Core.swift (NO network, NO WebKit). Drives the
// ToolRunner with stub tools (sleep + atomic counter) to assert:
//   - global concurrency cap respected (peak in-flight ≤ cap),
//   - results returned in INPUT order keyed by tool_call_id,
//   - a throwing tool → that result isError, others still succeed,
//   - a slow tool → .timeout isError (no hang; wall-clock bounded),
//   - unknown tool name → isError,
//   - cancellation unwinds without hanging.
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

// ----------------------------------------------------------------------------
// Atomic counter for tracking peak concurrency (thread-safe)
// ----------------------------------------------------------------------------

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = 0
    private var _peak = 0

    func enter() {
        lock.lock()
        _current += 1
        if _current > _peak { _peak = _current }
        lock.unlock()
    }
    func leave() {
        lock.lock()
        _current -= 1
        lock.unlock()
    }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }
    var current: Int { lock.lock(); defer { lock.unlock() }; return _current }
}

// ----------------------------------------------------------------------------
// Stub tools
// ----------------------------------------------------------------------------

/// A tool that sleeps `delayMs`, tracking peak concurrency through a shared Counter.
struct SleepTool: AgentTool {
    let toolName: String
    let delayMs: Int
    let counter: Counter

    var spec: ToolSpec { ToolSpec(name: toolName, description: "sleep \(delayMs)ms") }

    func invoke(_ args: JSONObject) async throws -> String {
        counter.enter()
        defer { counter.leave() }
        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        return "slept:\(toolName)"
    }
}

/// A tool that throws immediately.
struct ThrowingTool: AgentTool {
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    let toolName: String
    var spec: ToolSpec { ToolSpec(name: toolName, description: "throws") }
    func invoke(_ args: JSONObject) async throws -> String { throw Boom() }
}

/// A tool that echoes one of its string args back, to verify args/order plumbing.
struct EchoTool: AgentTool {
    let toolName: String
    var spec: ToolSpec { ToolSpec(name: toolName, description: "echo") }
    func invoke(_ args: JSONObject) async throws -> String {
        return (args.dictionary["msg"] as? String) ?? "<no-msg>"
    }
}

/// A tool that sleeps a long time — used for the cancellation test. It honors
/// cancellation via Task.sleep (which throws CancellationError when cancelled).
struct LongSleepTool: AgentTool {
    let toolName: String
    var spec: ToolSpec { ToolSpec(name: toolName, description: "long sleep") }
    func invoke(_ args: JSONObject) async throws -> String {
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        return "done"
    }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func makeRegistry(_ tools: [any AgentTool]) async -> ToolRegistry {
    let r = ToolRegistry()
    for t in tools { await r.register(t) }
    return r
}

func calls(_ pairs: [(String, String)]) -> [ParsedToolCall] {
    // (id, name) pairs with empty args
    return pairs.map { ParsedToolCall(id: $0.0, name: $0.1, rawArguments: "{}") }
}

// ----------------------------------------------------------------------------
// Tests (driven from an async main)
// ----------------------------------------------------------------------------

func runTests() async {
    // ------------------------------------------------------------------------
    section("global concurrency cap is respected (peak ≤ cap)")
    do {
        let counter = Counter()
        let n = 12
        let cap = 3
        var tools: [any AgentTool] = []
        var cs: [ParsedToolCall] = []
        for i in 0..<n {
            let name = "sleep\(i)"
            tools.append(SleepTool(toolName: name, delayMs: 60, counter: counter))
            cs.append(ParsedToolCall(id: "c\(i)", name: name, rawArguments: "{}"))
        }
        let registry = await makeRegistry(tools)
        let runner = ToolRunner(maxConcurrent: cap, perToolTimeoutMs: 5000)
        let results = await runner.run(cs, registry: registry)
        check(results.count == n, "all \(n) tools produced a result")
        check(counter.peak <= cap, "peak concurrency \(counter.peak) ≤ cap \(cap)")
        check(counter.peak >= 2, "peak concurrency \(counter.peak) shows real parallelism (≥2)")
        check(counter.current == 0, "no tools left in-flight after run")
    }

    // ------------------------------------------------------------------------
    section("results are returned in INPUT order keyed by tool_call_id")
    do {
        // Reverse the natural completion order: earlier ids sleep LONGER so they
        // finish LAST, proving re-assembly is by input index, not completion.
        let counter = Counter()
        var tools: [any AgentTool] = []
        var cs: [ParsedToolCall] = []
        let n = 6
        for i in 0..<n {
            let name = "t\(i)"
            // id i sleeps (n-i)*20 ms → id 0 finishes last
            tools.append(SleepTool(toolName: name, delayMs: (n - i) * 15, counter: counter))
            cs.append(ParsedToolCall(id: "id\(i)", name: name, rawArguments: "{}"))
        }
        let registry = await makeRegistry(tools)
        let runner = ToolRunner(maxConcurrent: 10, perToolTimeoutMs: 5000)
        let results = await runner.run(cs, registry: registry)
        check(results.count == n, "\(n) results")
        var ordered = true
        for i in 0..<n {
            if results[i].toolCallId != "id\(i)" || results[i].name != "t\(i)" { ordered = false }
        }
        check(ordered, "results[i] matches calls[i] by id+name (deterministic re-assembly)")
        check(results.allSatisfy { !$0.isError }, "all succeeded")
    }

    // ------------------------------------------------------------------------
    section("partial failure: one throwing tool → isError, others succeed")
    do {
        let counter = Counter()
        let tools: [any AgentTool] = [
            EchoTool(toolName: "echo"),
            ThrowingTool(toolName: "boom"),
            SleepTool(toolName: "sleep", delayMs: 20, counter: counter),
        ]
        let registry = await makeRegistry(tools)
        let cs = [
            ParsedToolCall(id: "a", name: "echo", rawArguments: "{\"msg\":\"hi\"}"),
            ParsedToolCall(id: "b", name: "boom", rawArguments: "{}"),
            ParsedToolCall(id: "c", name: "sleep", rawArguments: "{}"),
        ]
        let runner = ToolRunner(maxConcurrent: 4, perToolTimeoutMs: 5000)
        let results = await runner.run(cs, registry: registry)
        check(results.count == 3, "3 results")
        check(results[0].toolCallId == "a" && !results[0].isError && results[0].content == "hi", "echo succeeded with arg")
        check(results[1].toolCallId == "b" && results[1].isError, "throwing tool → isError")
        check(results[1].content.lowercased().contains("boom") || results[1].content.lowercased().contains("error"),
              "error content mentions the failure")
        check(results[2].toolCallId == "c" && !results[2].isError, "sleep tool still succeeded despite sibling failure")
    }

    // ------------------------------------------------------------------------
    section("slow tool → .timeout isError, no hang (wall-clock bounded)")
    do {
        let counter = Counter()
        let tools: [any AgentTool] = [
            SleepTool(toolName: "slow", delayMs: 2000, counter: counter),  // 2s
            EchoTool(toolName: "fast"),
        ]
        let registry = await makeRegistry(tools)
        let cs = [
            ParsedToolCall(id: "s", name: "slow", rawArguments: "{}"),
            ParsedToolCall(id: "f", name: "fast", rawArguments: "{\"msg\":\"ok\"}"),
        ]
        let runner = ToolRunner(maxConcurrent: 4, perToolTimeoutMs: 200) // 200ms timeout
        let t0 = nowMs()
        let results = await runner.run(cs, registry: registry)
        let elapsed = nowMs() - t0
        check(results.count == 2, "2 results")
        let slow = results.first { $0.toolCallId == "s" }!
        let fast = results.first { $0.toolCallId == "f" }!
        check(slow.isError, "slow tool timed out → isError")
        check(slow.content.lowercased().contains("timed out") || slow.content.lowercased().contains("timeout"),
              "timeout content names the timeout")
        check(!fast.isError && fast.content == "ok", "fast tool succeeded")
        check(elapsed < 1500, "run finished in \(Int(elapsed))ms — did NOT wait the full 2s (no hang)")
    }

    // ------------------------------------------------------------------------
    section("unknown tool name → isError, batch survives")
    do {
        let tools: [any AgentTool] = [EchoTool(toolName: "echo")]
        let registry = await makeRegistry(tools)
        let cs = [
            ParsedToolCall(id: "k", name: "does_not_exist", rawArguments: "{}"),
            ParsedToolCall(id: "e", name: "echo", rawArguments: "{\"msg\":\"yo\"}"),
        ]
        let runner = ToolRunner(maxConcurrent: 4, perToolTimeoutMs: 1000)
        let results = await runner.run(cs, registry: registry)
        check(results.count == 2, "2 results")
        let unknown = results.first { $0.toolCallId == "k" }!
        check(unknown.isError, "unknown tool → isError")
        check(unknown.content.lowercased().contains("unknown"), "error names the unknown tool")
        let echo = results.first { $0.toolCallId == "e" }!
        check(!echo.isError && echo.content == "yo", "sibling tool still ran")
    }

    // ------------------------------------------------------------------------
    section("empty input → empty results")
    do {
        let registry = await makeRegistry([EchoTool(toolName: "echo")])
        let runner = ToolRunner(maxConcurrent: 4, perToolTimeoutMs: 1000)
        let results = await runner.run([], registry: registry)
        check(results.isEmpty, "empty calls → empty results")
    }

    // ------------------------------------------------------------------------
    section("cancellation unwinds without hang")
    do {
        // Start a runner with a long-sleeping tool inside a Task, cancel the Task,
        // and assert it returns promptly (well under the 5s tool sleep).
        let registry = await makeRegistry([LongSleepTool(toolName: "long")])
        let runner = ToolRunner(maxConcurrent: 2, perToolTimeoutMs: 10_000)
        let cs = [ParsedToolCall(id: "L", name: "long", rawArguments: "{}")]

        let task = Task { () -> [ToolResult] in
            return await runner.run(cs, registry: registry)
        }
        // Give it a moment to start, then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        let t0 = nowMs()
        task.cancel()
        let results = await task.value
        let elapsed = nowMs() - t0
        check(elapsed < 1500, "cancelled run returned in \(Int(elapsed))ms (no 5s hang)")
        check(results.count == 1, "still produced one result for the cancelled call")
        // The cancelled tool yields an isError result (cancelled), never a crash.
        check(results[0].isError, "cancelled tool → isError result")
    }

    // ------------------------------------------------------------------------
    // Summary
    print("")
    print("==========================================")
    if testsFailed == 0 {
        print("test-toolrunner: ALL \(testsRun) CHECKS PASSED")
    } else {
        print("test-toolrunner: \(testsFailed)/\(testsRun) CHECKS FAILED")
    }
}

// Drive the async tests to completion, then exit with the right status.
let sem = DispatchSemaphore(value: 0)
Task {
    await runTests()
    sem.signal()
}
sem.wait()
exit(testsFailed == 0 ? 0 : 1)
