// test-agentloop.swift — unit tests for the AgentLoop orchestrator (PR7).
//
// Co-compiled with scripts/Core.swift (NO network, NO WebKit). Drives the
// AgentLoop with a STUB model `call` returning canned AssistantTurns + stub
// tools, asserting:
//   - single tool call → correct role:"tool" assembly (id/name/order) → final answer,
//   - PARALLEL tool calls in one turn handled,
//   - arguments as object AND JSON-string AND empty AND malformed
//       (malformed → isError, no crash),
//   - maxIterations cap stops a tool-loop,
//   - schema-invalid args → isError tool message + the model can retry,
//   - unknown tool → isError, loop survives.
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
// Stub tools
// ----------------------------------------------------------------------------

/// Echoes back a JSON description of the args it received (so tests can assert
/// the args actually reached the tool, decoded correctly).
struct EchoArgsTool: AgentTool {
    let toolName: String
    // JSONObject is a Sendable box around [String: Any] (defined in Core.swift),
    // so this tool stays Sendable under -strict-concurrency=complete.
    let schemaBox: JSONObject
    init(name: String, schema: [String: Any] = ["type": "object", "properties": [String: Any]()]) {
        self.toolName = name
        self.schemaBox = JSONObject(schema)
    }
    var spec: ToolSpec { ToolSpec(name: toolName, description: "echo args", parametersSchema: schemaBox.dictionary) }
    func invoke(_ args: JSONObject) async throws -> String {
        let d = args.dictionary
        // Stable string: sorted keys.
        let parts = d.keys.sorted().map { "\($0)=\(d[$0]!)" }
        return "ok[\(toolName)]:" + parts.joined(separator: ",")
    }
}

/// A counter shared across calls so a tool-call loop can be observed.
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A thread-safe log of `ToolProgressEvent`s for the PR8 progress-hook test (the
/// loop may fire the hook from concurrent tool tasks).
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ToolProgressEvent] = []
    func append(_ e: ToolProgressEvent) { lock.lock(); defer { lock.unlock() }; events.append(e) }
    func snapshot() -> [ToolProgressEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

func makeRegistry(_ tools: [any AgentTool]) async -> ToolRegistry {
    let r = ToolRegistry()
    for t in tools { await r.register(t) }
    return r
}

func newSession(user: String) -> ChatSession {
    return ChatSession(selectedText: nil, messages: [ChatMessage(role: "user", content: user)])
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

func runTests() async {

    // ------------------------------------------------------------------------
    section("single tool call → role:\"tool\" assembly → final answer")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)

        // Turn 1: ask for one tool. Turn 2: final answer.
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "call_1", name: "echo", rawArguments: "{\"q\":\"hi\"}")]),
            AssistantTurn(content: "Final answer."),
        ])

        let outcome = try! await loop.run(session: newSession(user: "do it"), registry: registry, call: turns.call)
        let msgs = outcome.session.messages

        check(outcome.finalText == "Final answer.", "returned the final assistant text")
        check(outcome.iterations == 2, "made 2 model calls")
        check(!outcome.stoppedAtMax, "did not hit the iteration cap")

        // Expected message sequence: user, assistant(tool_calls), tool, assistant(final)
        check(msgs.count == 4, "4 messages appended/assembled (got \(msgs.count))")
        check(msgs[0].role == "user", "msg0 user")
        check(msgs[1].role == "assistant" && (msgs[1].toolCalls?.count ?? 0) == 1, "msg1 assistant carries the tool_call")
        check(msgs[1].toolCalls?.first?.id == "call_1", "tool_call id preserved on assistant turn")
        check(msgs[2].role == "tool", "msg2 is a tool message")
        check(msgs[2].toolCallId == "call_1", "tool message keyed to the right tool_call_id")
        check(msgs[2].content == "ok[echo]:q=hi", "tool message carries the tool's output (args decoded)")
        check(msgs[3].role == "assistant" && msgs[3].content == "Final answer.", "msg3 final assistant answer")
    }

    // ------------------------------------------------------------------------
    section("PARALLEL tool calls in one turn → tool messages in input order")
    do {
        let registry = await makeRegistry([
            EchoArgsTool(name: "a"), EchoArgsTool(name: "b"), EchoArgsTool(name: "c"),
        ])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "p1", name: "a", rawArguments: "{\"x\":1}"),
                ParsedToolCall(id: "p2", name: "b", rawArguments: "{\"x\":2}"),
                ParsedToolCall(id: "p3", name: "c", rawArguments: "{\"x\":3}"),
            ]),
            AssistantTurn(content: "done"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "go"), registry: registry, call: turns.call)
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 3, "3 tool messages for 3 parallel calls")
        check(toolMsgs[0].toolCallId == "p1" && toolMsgs[1].toolCallId == "p2" && toolMsgs[2].toolCallId == "p3",
              "tool messages preserve INPUT order by tool_call_id")
        check(toolMsgs[0].content.contains("ok[a]") && toolMsgs[2].content.contains("ok[c]"),
              "each tool message carries the right tool's output")
        check(outcome.finalText == "done", "final answer after parallel tools")
    }

    // ------------------------------------------------------------------------
    section("parallel calls with BLANK (\"\") ids → neither result lost/duplicated")
    do {
        // A known llama.cpp quirk: parallel tool calls all carry id "". If the
        // loop re-assembled by id, the empty key would collide — one result
        // lost, the other duplicated. Positional re-assembly must keep both,
        // in input order, and emit distinct non-empty tool_call_ids.
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "", name: "echo", rawArguments: "{\"v\":\"first\"}"),
                ParsedToolCall(id: "", name: "echo", rawArguments: "{\"v\":\"second\"}"),
            ]),
            AssistantTurn(content: "merged"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "go"), registry: registry, call: turns.call)
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 2, "both blank-id calls produced a tool message (none lost)")
        check(toolMsgs[0].content == "ok[echo]:v=first", "first result in slot 0 (not duplicated/overwritten)")
        check(toolMsgs[1].content == "ok[echo]:v=second", "second result in slot 1 (not lost)")
        let ids = toolMsgs.map { $0.toolCallId ?? "" }
        check(ids.allSatisfy { !$0.isEmpty }, "blank ids normalized to non-empty wire ids")
        check(Set(ids).count == 2, "the two emitted tool_call_ids are distinct")
        check(outcome.finalText == "merged", "loop continues to a final answer")
    }

    // ------------------------------------------------------------------------
    section("parallel calls sharing the SAME non-empty id → neither lost/duplicated")
    do {
        // Same collision risk with a duplicated non-empty id.
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "dup", name: "echo", rawArguments: "{\"v\":\"alpha\"}"),
                ParsedToolCall(id: "dup", name: "echo", rawArguments: "{\"v\":\"beta\"}"),
            ]),
            AssistantTurn(content: "ok"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "go"), registry: registry, call: turns.call)
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 2, "both same-id calls produced a tool message")
        check(toolMsgs[0].content == "ok[echo]:v=alpha", "first (alpha) preserved in order")
        check(toolMsgs[1].content == "ok[echo]:v=beta", "second (beta) preserved in order — not duplicated")
    }

    // ------------------------------------------------------------------------
    section("errored tool message carries isError = true")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "ok1", name: "echo", rawArguments: "{\"v\":\"yes\"}"),
                ParsedToolCall(id: "bad", name: "missing_tool", rawArguments: "{}"),
            ]),
            AssistantTurn(content: "done"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "go"), registry: registry, call: turns.call)
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 2, "two tool messages")
        check(toolMsgs[0].isError != true, "successful tool message is not flagged isError")
        check(toolMsgs[1].isError == true, "errored (unknown) tool message flagged isError == true")
    }

    // ------------------------------------------------------------------------
    section("arguments: object form decodes (not just JSON string)")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        // rawArguments is an already-decoded dictionary (llama.cpp object shape).
        let objArgs: [String: Any] = ["q": "obj"]
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "o1", name: "echo", rawArguments: objArgs)]),
            AssistantTurn(content: "ok"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "x"), registry: registry, call: turns.call)
        let toolMsg = outcome.session.messages.first { $0.role == "tool" }!
        check(toolMsg.content == "ok[echo]:q=obj", "object-form arguments decoded and passed through")
    }

    // ------------------------------------------------------------------------
    section("arguments: empty string → {} (no crash)")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "e1", name: "echo", rawArguments: "")]),
            AssistantTurn(content: "ok"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "x"), registry: registry, call: turns.call)
        let toolMsg = outcome.session.messages.first { $0.role == "tool" }!
        check(!toolMsg.content.lowercased().contains("error"), "empty args → no error")
        check(toolMsg.content == "ok[echo]:", "empty args → tool invoked with {}")
    }

    // ------------------------------------------------------------------------
    section("arguments: malformed JSON → isError tool message, no crash")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "m1", name: "echo", rawArguments: "{not valid json")]),
            AssistantTurn(content: "recovered"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "x"), registry: registry, call: turns.call)
        let toolMsg = outcome.session.messages.first { $0.role == "tool" }!
        check(toolMsg.toolCallId == "m1", "tool message still keyed to the call")
        check(toolMsg.content.lowercased().contains("error"), "malformed args → isError tool message")
        check(outcome.finalText == "recovered", "loop survives malformed args and reaches a final answer")
    }

    // ------------------------------------------------------------------------
    section("schema-invalid args → isError tool message, model can retry")
    do {
        // Tool requires a string `url`. First turn passes an integer → invalid.
        // Second turn (the retry) passes a valid string → succeeds.
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["url": ["type": "string"]],
            "required": ["url"],
        ]
        let registry = await makeRegistry([EchoArgsTool(name: "fetch", schema: schema)])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([
            // invalid: missing required url
            AssistantTurn(toolCalls: [ParsedToolCall(id: "v1", name: "fetch", rawArguments: "{}")]),
            // retry: valid
            AssistantTurn(toolCalls: [ParsedToolCall(id: "v2", name: "fetch", rawArguments: "{\"url\":\"http://x\"}")]),
            AssistantTurn(content: "retried successfully"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "fetch it"), registry: registry, call: turns.call)
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 2, "two tool messages (invalid + retry)")
        check(toolMsgs[0].toolCallId == "v1" && toolMsgs[0].content.lowercased().contains("invalid"),
              "first call → invalid-arguments isError message")
        check(toolMsgs[1].toolCallId == "v2" && !toolMsgs[1].content.lowercased().contains("error"),
              "retry call succeeded")
        check(toolMsgs[1].content.contains("url=http://x"), "retry args reached the tool")
        check(outcome.finalText == "retried successfully", "model recovered after the schema error")
    }

    // ------------------------------------------------------------------------
    section("type mismatch in args → isError (schema validation)")
    do {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["n": ["type": "integer"]],
        ]
        let registry = await makeRegistry([EchoArgsTool(name: "num", schema: schema)])
        let loop = AgentLoop(maxIterations: 4)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "t1", name: "num", rawArguments: "{\"n\":\"not-a-number\"}")]),
            AssistantTurn(content: "ok"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "x"), registry: registry, call: turns.call)
        let toolMsg = outcome.session.messages.first { $0.role == "tool" }!
        check(toolMsg.content.lowercased().contains("error") && toolMsg.content.lowercased().contains("integer"),
              "string where integer expected → isError naming the type")
    }

    // ------------------------------------------------------------------------
    section("unknown tool → isError, loop survives")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "u1", name: "ghost_tool", rawArguments: "{}")]),
            AssistantTurn(content: "moved on"),
        ])
        let outcome = try! await loop.run(session: newSession(user: "x"), registry: registry, call: turns.call)
        let toolMsg = outcome.session.messages.first { $0.role == "tool" }!
        check(toolMsg.toolCallId == "u1", "tool message keyed to the unknown call")
        check(toolMsg.content.lowercased().contains("unknown"), "unknown tool → isError naming it")
        check(outcome.finalText == "moved on", "loop survives an unknown tool")
    }

    // ------------------------------------------------------------------------
    section("maxIterations cap stops a tool loop")
    do {
        // The model NEVER answers — it always asks for the tool again. The cap
        // must halt it. With maxIterations=3 we expect exactly 3 model calls.
        let box = Box()
        let registry = await makeRegistry([EchoArgsTool(name: "spin")])
        let loop = AgentLoop(maxIterations: 3)
        // A non-scripted, always-tool-calling model.
        let alwaysTool: AgentLoop.ModelCall = { _, _ in
            let n = box.inc()
            return AssistantTurn(toolCalls: [ParsedToolCall(id: "spin\(n)", name: "spin", rawArguments: "{}")])
        }
        let outcome = try! await loop.run(session: newSession(user: "loop"), registry: registry, call: alwaysTool)
        check(outcome.stoppedAtMax, "stoppedAtMax flagged")
        check(outcome.iterations == 3, "exactly maxIterations (3) model calls were made (got \(outcome.iterations))")
        check(box.value == 3, "the model was invoked exactly 3 times")
        let toolMsgs = outcome.session.messages.filter { $0.role == "tool" }
        check(toolMsgs.count == 3, "3 tool turns ran before the cap stopped it")
        // No `finalize` injected here → finalText stays empty (legacy behavior).
        check(outcome.finalText.isEmpty, "without finalize, capped tool loop returns empty (unchanged)")
    }

    // ------------------------------------------------------------------------
    section("BUG3: always-answer — capped tool loop synthesizes a final answer")
    do {
        // A model that NEVER answers in text (only tool calls) hits the cap with
        // empty finalText. With a `finalize` synthesis call injected, the loop
        // must do ONE final tools-disabled turn and ALWAYS end with a real answer.
        let box = Box()
        let registry = await makeRegistry([EchoArgsTool(name: "spin")])
        let loop = AgentLoop(maxIterations: 3)
        let alwaysTool: AgentLoop.ModelCall = { _, tools in
            // Sanity: the synthesis call passes an EMPTY tools array.
            check(!tools.isEmpty, "main call receives the tools array")
            let n = box.inc()
            return AssistantTurn(toolCalls: [ParsedToolCall(id: "spin\(n)", name: "spin", rawArguments: "{}")])
        }
        let finalizeBox = Box()
        let finalize: AgentLoop.ModelCall = { _, tools in
            _ = finalizeBox.inc()
            check(tools.isEmpty, "finalize call receives an EMPTY tools array (tools disabled)")
            return AssistantTurn(content: "Synthesized answer from the gathered results.")
        }
        let outcome = try! await loop.run(
            session: newSession(user: "loop"), registry: registry,
            call: alwaysTool, finalize: finalize)
        check(outcome.stoppedAtMax, "stoppedAtMax still flagged (we did hit the cap)")
        check(finalizeBox.value == 1, "finalize was invoked exactly once")
        check(outcome.finalText == "Synthesized answer from the gathered results.",
              "BUG3: non-empty synthesized final answer, got '\(outcome.finalText)'")
        check(outcome.session.messages.last?.role == "assistant", "ends with the assistant answer")
        check(outcome.session.messages.last?.content == outcome.finalText, "final message carries the answer")
    }

    // ------------------------------------------------------------------------
    section("BUG3: a no-tools turn with EMPTY content + prior tools → synthesize")
    do {
        // The model stops calling tools but returns an empty answer (e.g. the
        // whole answer was eaten by a <think> block). With prior tool results +
        // finalize, the loop must synthesize rather than return blank.
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "e1", name: "echo", rawArguments: "{\"q\":\"x\"}")]),
            AssistantTurn(content: ""),   // model "answers" but it's empty
        ])
        let finalize: AgentLoop.ModelCall = { _, _ in
            AssistantTurn(content: "Recovered answer.")
        }
        let outcome = try! await loop.run(
            session: newSession(user: "go"), registry: registry,
            call: turns.call, finalize: finalize)
        check(outcome.finalText == "Recovered answer.",
              "BUG3: empty no-tools answer recovered via synthesis, got '\(outcome.finalText)'")
        check(!outcome.stoppedAtMax, "did not hit the cap (model returned a no-tools turn)")
    }

    // ------------------------------------------------------------------------
    section("BUG3: a non-empty answer is NOT overwritten by synthesis")
    do {
        // When the model DOES answer, finalize must not fire.
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([
            AssistantTurn(toolCalls: [ParsedToolCall(id: "e1", name: "echo", rawArguments: "{\"q\":\"x\"}")]),
            AssistantTurn(content: "The real answer."),
        ])
        let finBox = Box()
        let finalize: AgentLoop.ModelCall = { _, _ in
            _ = finBox.inc()
            return AssistantTurn(content: "SHOULD NOT APPEAR")
        }
        let outcome = try! await loop.run(
            session: newSession(user: "go"), registry: registry,
            call: turns.call, finalize: finalize)
        check(outcome.finalText == "The real answer.", "real answer kept, got '\(outcome.finalText)'")
        check(finBox.value == 0, "finalize NOT invoked when the model already answered")
    }

    // ------------------------------------------------------------------------
    section("no tools requested on turn 1 → immediate final answer")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)
        let turns = TurnScript([AssistantTurn(content: "Just an answer.")])
        let outcome = try! await loop.run(session: newSession(user: "hi"), registry: registry, call: turns.call)
        check(outcome.iterations == 1, "one model call")
        check(outcome.finalText == "Just an answer.", "final answer returned")
        check(outcome.session.messages.last?.role == "assistant", "last message is the assistant answer")
        check(!outcome.session.messages.contains { $0.role == "tool" }, "no tool messages")
    }

    // ------------------------------------------------------------------------
    section("PR8: optional onProgress hook emits started→finished per tool call")
    do {
        let registry = await makeRegistry([EchoArgsTool(name: "echo")])
        let loop = AgentLoop(maxIterations: 6)
        // Two parallel calls in turn 1, then a final answer.
        let turns = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "a", name: "echo", rawArguments: "{\"q\":\"1\"}"),
                ParsedToolCall(id: "b", name: "echo", rawArguments: "{\"q\":\"2\"}"),
            ]),
            AssistantTurn(content: "done"),
        ])
        // Thread-safe event collector (the loop may fire from concurrent tasks).
        let events = EventLog()
        let outcome = try! await loop.run(
            session: newSession(user: "go"), registry: registry, call: turns.call,
            onProgress: { ev in events.append(ev) })

        let log = events.snapshot()
        let started = log.filter { if case .started = $0.phase { return true }; return false }
        let finished = log.filter { if case .finished = $0.phase { return true }; return false }
        check(started.count == 2, "two started events (one per call), got \(started.count)")
        check(finished.count == 2, "two finished events (one per call), got \(finished.count)")
        check(Set(started.map { $0.callKey }) == ["a", "b"], "started events keyed to both call ids")
        check(finished.allSatisfy { if case .finished(_, let isErr) = $0.phase { return !isErr }; return false },
              "both finished events report success (isError == false)")
        check(outcome.finalText == "done", "loop still returns the final answer with the hook attached")

        // The same loop run WITHOUT the hook must behave identically (the existing
        // tests already cover this; assert message parity here for safety).
        let turns2 = TurnScript([
            AssistantTurn(toolCalls: [
                ParsedToolCall(id: "a", name: "echo", rawArguments: "{\"q\":\"1\"}"),
                ParsedToolCall(id: "b", name: "echo", rawArguments: "{\"q\":\"2\"}"),
            ]),
            AssistantTurn(content: "done"),
        ])
        let plain = try! await loop.run(session: newSession(user: "go"), registry: registry, call: turns2.call)
        check(plain.session.messages.count == outcome.session.messages.count,
              "message count identical with and without the progress hook")
    }

    // ------------------------------------------------------------------------
    // Summary
    print("")
    print("==========================================")
    if testsFailed == 0 {
        print("test-agentloop: ALL \(testsRun) CHECKS PASSED")
    } else {
        print("test-agentloop: \(testsFailed)/\(testsRun) CHECKS FAILED")
    }
}

// ----------------------------------------------------------------------------
// TurnScript: a Sendable stub model that returns canned turns in sequence.
// ----------------------------------------------------------------------------

actor TurnScript {
    private var turns: [AssistantTurn]
    private var idx = 0
    init(_ turns: [AssistantTurn]) { self.turns = turns }

    private func next() -> AssistantTurn {
        if idx < turns.count {
            let t = turns[idx]
            idx += 1
            return t
        }
        return AssistantTurn(content: "")
    }

    /// The injectable ModelCall. Returns the next scripted turn; if the script is
    /// exhausted, returns an empty final answer (defensive).
    nonisolated var call: AgentLoop.ModelCall {
        return { [self] _, _ in
            return await self.next()
        }
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
