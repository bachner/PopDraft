// test-compaction.swift — unit tests for automatic session compaction.
//
// Co-compiled with scripts/Core.swift (NO network, NO WebKit). Exercises the
// pure `ContextBudget` + the `AgentLoop` compaction wiring:
//   - token-estimate monotonicity + per-message accounting,
//   - effectiveBudget per provider (local vs cloud floor),
//   - trimToolResult caps oversized content (head+tail+marker),
//   - compact() keeps system + latest-user + recent-K VERBATIM and folds the
//     older region into ONE "Conversation so far:" recap,
//   - compactUntilUnder() drives a huge transcript under the proactive threshold,
//   - isContextOverflowError() matches the llama.cpp / cloud overflow shapes,
//   - REACTIVE: AgentLoop.callCompacted recovers from a simulated context-overflow
//     throw (compacts harder + retries) and still answers,
//   - tool-result trimming is applied to BOTH the older recap and the kept tail.
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
// Builders
// ----------------------------------------------------------------------------

func msg(_ role: String, _ content: String, calls: [ChatToolCall]? = nil,
         toolCallId: String? = nil) -> ChatMessage {
    return ChatMessage(role: role, content: content, toolCalls: calls, toolCallId: toolCallId)
}

func bigText(_ n: Int, _ seed: String = "x") -> String {
    return String(repeating: seed, count: n)
}

/// A long synthetic transcript: system + many (user / assistant / tool) turns,
/// with several large tool results (fetched pages) — the exact shape that blows
/// past a 16k window in a real long agent session.
func longTranscript(turns: Int, toolResultChars: Int) -> [ChatMessage] {
    var out: [ChatMessage] = [
        msg("system", "You are PopDraft, a helpful agent. " + bigText(200, "s")),
    ]
    for i in 0..<turns {
        out.append(msg("user", "Question \(i): please research topic \(i). " + bigText(80, "u")))
        out.append(msg("assistant", "", calls: [
            ChatToolCall(id: "call_\(i)", name: "web_search", arguments: "{\"q\":\"topic \(i)\"}"),
        ]))
        out.append(msg("tool", "PAGE \(i): " + bigText(toolResultChars, "p"), toolCallId: "call_\(i)"))
        out.append(msg("assistant", "Here is a summary of topic \(i). " + bigText(60, "a")))
    }
    // The LATEST user message (the actual current question) must always survive.
    out.append(msg("user", "FINAL_QUESTION: given all the above, what is the conclusion?"))
    return out
}

// ----------------------------------------------------------------------------
// A scripted model `call` for the reactive-retry test. It THROWS a context-
// overflow on the first `failTimes` calls, then returns a final answer. It also
// records the token estimate of the messages it was last handed, so the test can
// assert compaction actually shrank the input before the successful call.
// ----------------------------------------------------------------------------

final class OverflowThenAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private(set) var calls = 0
    private(set) var lastInputTokens = 0
    private(set) var lastInputCount = 0
    let answer: String

    init(failTimes: Int, answer: String) {
        self.remainingFailures = failTimes
        self.answer = answer
    }

    func call(_ messages: [ChatMessage]) throws -> AssistantTurn {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        lastInputTokens = ContextBudget.estimateTokens(messages)
        lastInputCount = messages.count
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw NSError(domain: "llama.cpp", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Context size has been exceeded. error -1."])
        }
        return AssistantTurn(content: answer)
    }

    /// Boxed as the AgentLoop.ModelCall the loop expects.
    nonisolated var modelCall: AgentLoop.ModelCall {
        return { [self] messages, _ in try self.call(messages) }
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

func runTests() async {

    // ------------------------------------------------------------------------
    section("token estimate — monotonicity + per-message accounting")
    do {
        let base: [ChatMessage] = [msg("system", "sys"), msg("user", "hello")]
        let t0 = ContextBudget.estimateTokens(base)
        check(t0 > 0, "non-empty estimate for a small array")

        // Appending any message must not DECREASE the estimate (monotonic).
        var grown = base
        var prev = t0
        for i in 0..<20 {
            grown.append(msg(i % 2 == 0 ? "assistant" : "user", bigText(100 * (i + 1))))
            let t = ContextBudget.estimateTokens(grown)
            check(t >= prev, "estimate is monotonic on append (step \(i): \(prev) → \(t))")
            prev = t
        }

        // A bigger single message estimates higher than a smaller one.
        let small = ContextBudget.estimateTokens([msg("user", bigText(100))])
        let large = ContextBudget.estimateTokens([msg("user", bigText(10_000))])
        check(large > small * 50, "estimate scales with content length")

        // Tool-call args + thinking are counted (so a tool-call turn isn't free).
        let plain = ContextBudget.estimateTokens([msg("assistant", "")])
        let withCalls = ContextBudget.estimateTokens([msg("assistant", "",
            calls: [ChatToolCall(id: "c1", name: "web_search", arguments: "{\"q\":\"" + bigText(2000) + "\"}")])])
        check(withCalls > plain * 10, "tool-call arguments count toward the estimate")
    }

    // ------------------------------------------------------------------------
    section("effectiveBudget — precedence: configured PIN > detected > default")
    do {
        // 1) A non-zero configured value PINS the budget exactly (local).
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 16384) == 16384,
              "a configured llamacpp value pins the budget exactly")
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 16384, detected: 200_000) == 16384,
              "a configured PIN overrides even a larger detected window")
        // Cloud still gets at least the floor even when configured smaller.
        check(ContextBudget.effectiveBudget(provider: "openai", configured: 16384)
                >= ContextBudget.cloudBudgetFloor, "openai configured-small still gets the cloud floor")
        check(ContextBudget.effectiveBudget(provider: "claude", configured: 200_000) == 200_000,
              "a higher configured cloud budget still wins")

        // 2) configured == 0 (AUTO) + a detected served context → use detection.
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 0, detected: 200_192) == 200_192,
              "auto + detected n_ctx uses the ACTUAL served context (≈200K)")
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 0, detected: 16384) == 16384,
              "auto + a smaller detected n_ctx (e.g. -c 16384) is honored")

        // 3) configured == 0, no detection → sensible per-provider default.
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 0) == ContextBudget.llamacppDefaultBudget,
              "auto llamacpp default is the ~200K flash-attn/q4 window")
        check(ContextBudget.effectiveBudget(provider: "ollama", configured: 0) == ContextBudget.ollamaDefaultBudget,
              "auto ollama default is its small window")
        check(ContextBudget.effectiveBudget(provider: "claude", configured: 0) == ContextBudget.cloudBudgetFloor,
              "auto cloud default is the cloud floor")
        // A garbage/0 detected value falls through to the default (never ~0).
        check(ContextBudget.effectiveBudget(provider: "llamacpp", configured: 0, detected: 0)
                >= ContextBudget.minBudget, "a 0 detected value falls back to a sane default")
    }

    // ------------------------------------------------------------------------
    section("trimToolResult — caps oversized content with a clear marker")
    do {
        let huge = bigText(50_000, "z")
        let trimmed = ContextBudget.trimToolResult(huge, maxChars: 4000)
        check(trimmed.count < huge.count, "trimmed result is smaller than the original")
        check(trimmed.count <= 4000 + 120, "trimmed result respects the cap (+marker slack)")
        check(trimmed.contains("trimmed to fit"), "trimmed result carries an elision marker")
        check(trimmed.hasPrefix("zz"), "head of the content is preserved")
        check(trimmed.hasSuffix("zz"), "tail of the content is preserved")

        // Below-cap content is returned unchanged.
        let small = bigText(100)
        check(ContextBudget.trimToolResult(small, maxChars: 4000) == small,
              "below-cap content is returned unchanged")
    }

    // ------------------------------------------------------------------------
    section("compact — keeps system + latest-user + recent-K, folds the rest")
    do {
        let transcript = longTranscript(turns: 30, toolResultChars: 3000)
        let budget = 16384
        check(ContextBudget.estimateTokens(transcript) > budget,
              "the synthetic transcript genuinely exceeds the 16k budget")
        check(ContextBudget.shouldCompact(transcript, budget: budget),
              "shouldCompact() flags it for compaction")

        let r = await ContextBudget.compact(transcript, budget: budget,
                                            recentKeep: ContextBudget.recentKeepDefault)
        check(r.didCompact, "compact() reports it changed the message set")
        check(r.afterTokens < r.beforeTokens, "compaction lowered the estimate")

        let out = r.messages
        // System prompt kept verbatim, first.
        check(out.first?.role == "system", "system prompt is kept first")
        check(out.first?.content == transcript.first?.content, "system prompt kept VERBATIM")
        // The latest user message survives verbatim somewhere in the sent set.
        check(out.contains(where: { $0.role == "user" && $0.content.contains("FINAL_QUESTION") }),
              "the latest user message is kept verbatim")
        // Exactly one injected recap "Conversation so far:" message.
        let recaps = out.filter { $0.content.hasPrefix("Conversation so far") }
        check(recaps.count == 1, "exactly one 'Conversation so far' recap is injected")
        // The recent tail (the last few transcript messages) survives verbatim.
        let lastAssistant = transcript[transcript.count - 2]   // the assistant before FINAL
        check(out.contains(where: { $0.content == lastAssistant.content }),
              "a recent-K tail message is preserved verbatim")
        // The sent set is far smaller than the original.
        check(out.count < transcript.count, "compaction drops older messages from the sent set")
    }

    // ------------------------------------------------------------------------
    section("compact — never splits an assistant tool-call from its tool results")
    do {
        // Craft a transcript whose recent-K window would otherwise BEGIN on a
        // role:"tool" message; compaction must walk back to the assistant turn.
        var t: [ChatMessage] = [msg("system", "s")]
        for i in 0..<10 {
            t.append(msg("user", "u\(i) " + bigText(500)))
            t.append(msg("assistant", "", calls: [ChatToolCall(id: "c\(i)", name: "tool", arguments: "{}")]))
            t.append(msg("tool", "result \(i) " + bigText(500), toolCallId: "c\(i)"))
            t.append(msg("assistant", "a\(i) " + bigText(500)))
        }
        t.append(msg("user", "final"))
        let r = await ContextBudget.compact(t, budget: 8192, recentKeep: 3)
        // In the SENT set, every tool message must be preceded (anywhere earlier)
        // by an assistant turn that carries its tool_call id — i.e. no orphan tool.
        let sent = r.messages
        for (i, m) in sent.enumerated() where m.role == "tool" {
            let id = m.toolCallId ?? ""
            let hasOwner = sent[..<i].contains { $0.role == "assistant" && ($0.toolCalls?.contains { $0.id == id } ?? false) }
            check(hasOwner, "tool message \(id) is not orphaned from its assistant turn")
        }
    }

    // ------------------------------------------------------------------------
    section("compactUntilUnder — drives a huge transcript under threshold")
    do {
        // A transcript so large a single fold isn't enough — tiered passes needed.
        let transcript = longTranscript(turns: 60, toolResultChars: 6000)
        let budget = 16384
        let r = await ContextBudget.compactUntilUnder(transcript, budget: budget)
        check(r.afterTokens <= Int(Double(budget) * ContextBudget.proactiveThreshold),
              "compactUntilUnder gets the estimate under the proactive threshold (\(r.afterTokens) ≤ \(Int(Double(budget) * ContextBudget.proactiveThreshold)))")
        check(r.messages.contains(where: { $0.role == "system" }), "system survives the aggressive pass")
        check(r.messages.contains(where: { $0.content.contains("FINAL_QUESTION") }),
              "latest user message survives the aggressive pass")
    }

    // ------------------------------------------------------------------------
    section("tool-result trimming — applied to the KEPT tail, not just older")
    do {
        // A single fresh tool result LARGER than the budget, sitting in the tail.
        var t: [ChatMessage] = [msg("system", "s")]
        t.append(msg("user", "fetch it"))
        t.append(msg("assistant", "", calls: [ChatToolCall(id: "c1", name: "web_read", arguments: "{}")]))
        t.append(msg("tool", "GIANT " + bigText(80_000, "g"), toolCallId: "c1"))
        t.append(msg("user", "summarize"))
        let r = await ContextBudget.compact(t, budget: 16384, recentKeep: 8,
                                           toolMaxChars: ContextBudget.toolResultMaxChars)
        let toolMsg = r.messages.first { $0.role == "tool" }
        check(toolMsg != nil, "the tool result is still present in the tail")
        check((toolMsg?.content.count ?? .max) <= ContextBudget.toolResultMaxChars + 120,
              "an oversized tail tool result is trimmed to the cap")
        check(toolMsg?.content.contains("trimmed to fit") ?? false, "trimmed tail tool result carries the marker")
    }

    // ------------------------------------------------------------------------
    section("isContextOverflowError — matches the overflow shapes")
    do {
        let llama = NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey:
            "Context size has been exceeded. error -1."])
        check(isContextOverflowError(llama), "matches llama.cpp 'Context size has been exceeded'")
        let cloud = NSError(domain: "prompt is too long: 250000 tokens > 200000 maximum", code: -1)
        check(isContextOverflowError(cloud), "matches a cloud 'prompt is too long' message")
        let window = NSError(domain: "the context window was exceeded", code: -1)
        check(isContextOverflowError(window), "matches 'context window … exceeded'")
        let unrelated = NSError(domain: "Could not connect to the server", code: -1)
        check(!isContextOverflowError(unrelated), "does NOT match an unrelated connection error")
        let invalidKey = NSError(domain: "Invalid API key", code: 401)
        check(!isContextOverflowError(invalidKey), "does NOT match an auth error")
    }

    // ------------------------------------------------------------------------
    section("REACTIVE — callCompacted recovers from a context-overflow throw")
    do {
        // A transcript that overflows; the stubbed model THROWS overflow once,
        // then answers. callCompacted must compact harder and retry → answer.
        let transcript = longTranscript(turns: 40, toolResultChars: 4000)
        let beforeTokens = ContextBudget.estimateTokens(transcript)
        let model = OverflowThenAnswer(failTimes: 1, answer: "Recovered answer.")
        let comp = AgentLoop.Compaction(budget: 16384, maxRetries: 2, summarize: nil)

        let turn = try! await AgentLoop.callCompacted(
            transcript, [], call: model.modelCall, compaction: comp)
        check(turn.content == "Recovered answer.", "callCompacted returned the model's recovered answer")
        check(model.calls >= 2, "the model was retried after the overflow throw (calls=\(model.calls))")
        check(model.lastInputTokens < beforeTokens,
              "the retried input was smaller than the original (\(model.lastInputTokens) < \(beforeTokens))")
    }

    // ------------------------------------------------------------------------
    section("REACTIVE — exhausted retries surface the error (not a hang)")
    do {
        // The model ALWAYS overflows; after maxRetries we must rethrow (graceful
        // path is handled one level up), not loop forever.
        let transcript = longTranscript(turns: 10, toolResultChars: 2000)
        let model = OverflowThenAnswer(failTimes: 99, answer: "never")
        let comp = AgentLoop.Compaction(budget: 16384, maxRetries: 2, summarize: nil)
        var threw = false
        do {
            _ = try await AgentLoop.callCompacted(transcript, [], call: model.modelCall, compaction: comp)
        } catch {
            threw = isContextOverflowError(error)
        }
        check(threw, "callCompacted rethrows the overflow once retries are exhausted")
        check(model.calls <= 1 + comp.maxRetries + 1, "retry count is bounded (calls=\(model.calls))")
    }

    // ------------------------------------------------------------------------
    section("PROACTIVE — full AgentLoop run compacts a huge session then answers")
    do {
        // No overflow throw at all — but the session is huge, so the loop must
        // proactively compact before the first call. The stub records the input
        // it actually received; assert it was already under budget.
        let transcript = longTranscript(turns: 50, toolResultChars: 5000)
        let beforeTokens = ContextBudget.estimateTokens(transcript)
        check(beforeTokens > 16384, "the run's transcript genuinely exceeds 16k")

        let model = OverflowThenAnswer(failTimes: 0, answer: "Proactive answer.")
        let comp = AgentLoop.Compaction(budget: 16384, maxRetries: 2, summarize: nil)
        let loop = AgentLoop(maxIterations: 3)
        let registry = ToolRegistry()  // no tools → first turn is the final answer
        let session = ChatSession(messages: transcript)

        let outcome = try! await loop.run(
            session: session, registry: registry, call: model.modelCall, compaction: comp)
        check(outcome.finalText == "Proactive answer.", "the loop produced an answer despite the huge session")
        check(model.lastInputTokens <= Int(Double(16384) * ContextBudget.proactiveThreshold) + 200,
              "the model received a proactively-compacted (under-threshold) input (\(model.lastInputTokens))")
        // The FULL transcript is preserved in the returned session (UI sees it all).
        check(outcome.session.messages.count >= transcript.count,
              "the full transcript is preserved in the session (compaction only changed what was SENT)")
    }

    // ------------------------------------------------------------------------
    section("summarizer is used when provided, else structural recap")
    do {
        let transcript = longTranscript(turns: 12, toolResultChars: 2000)
        // Injected summarizer returns a fixed recap.
        let summarize: ContextBudget.Summarizer = { dropped in
            return "MODEL-RECAP of \(dropped.count) messages"
        }
        let r = await ContextBudget.compact(transcript, budget: 16384, recentKeep: 4, summarize: summarize)
        let recap = r.messages.first { $0.content.hasPrefix("Conversation so far") }
        check(recap?.content.contains("MODEL-RECAP") ?? false, "the injected summarizer's recap is used")

        // Without a summarizer, a deterministic structural recap is produced.
        let r2 = await ContextBudget.compact(transcript, budget: 16384, recentKeep: 4, summarize: nil)
        let recap2 = r2.messages.first { $0.content.hasPrefix("Conversation so far") }
        check(recap2 != nil && !(recap2!.content.isEmpty), "a structural recap is produced without a summarizer")
        check(recap2!.content.contains("You asked") || recap2!.content.contains("Assistant"),
              "the structural recap names the earlier turns")
    }

    // ------------------------------------------------------------------------
    print("")
    print("Results: \(testsRun - testsFailed) passed, \(testsFailed) failed")
}

// Drive the async tests to completion, then exit with the right status.
let sem = DispatchSemaphore(value: 0)
Task {
    await runTests()
    sem.signal()
}
sem.wait()
exit(testsFailed == 0 ? 0 : 1)
