// test-session.swift — Unit tests for the chat session model + store (Core.swift).
// Compile and run WITH Core.swift:
//   swiftc -o /tmp/test-session tests/test-session.swift scripts/Core.swift && /tmp/test-session

import Foundation

// MARK: - Test Harness

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL [\(file):\(line)]: \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  Running: \(name)")
    body()
}

func createTempDir() -> String {
    let dir = NSTemporaryDirectory() + "popdraft-session-tests-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func cleanup(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - Fixtures

/// Build a session with one user turn, one assistant turn with a tool call, and a
/// "tool" role answer — exercising every interesting field.
func makeRichSession() -> ChatSession {
    let toolCall = ChatToolCall(id: "call_1", name: "web_search", arguments: "{\"q\":\"swift\"}")
    let user = ChatMessage(role: "user", content: "Search for Swift docs", createdAt: 100)
    let assistant = ChatMessage(
        role: "assistant",
        content: "Here's what I found.",
        toolCalls: [toolCall],
        thinking: "I should search the web.",
        createdAt: 101
    )
    let toolMsg = ChatMessage(role: "tool", content: "[results...]", toolCallId: "call_1", createdAt: 102)
    var session = ChatSession(
        createdAt: 100,
        updatedAt: 102,
        model: "qwen3.5-2b",
        selectedText: "Swift docs",
        messages: [user, assistant, toolMsg]
    )
    session.refreshTitle()
    return session
}

// MARK: - Tests

print("Running ChatSession / SessionStore tests...\n")

test("ChatMessage round-trips through JSON including toolCalls") {
    let original = ChatMessage(
        role: "assistant",
        content: "ok",
        toolCalls: [ChatToolCall(id: "c1", name: "fn", arguments: "{\"a\":1}")],
        toolCallId: nil,
        thinking: "thought",
        createdAt: 42
    )
    let data = try! JSONEncoder().encode(original)
    let decoded = try! JSONDecoder().decode(ChatMessage.self, from: data)
    assert(decoded == original, "ChatMessage should round-trip exactly")
    assert(decoded.toolCalls?.count == 1, "toolCalls should survive round-trip")
    assert(decoded.toolCalls?.first?.arguments == "{\"a\":1}", "tool call arguments should survive")
    assert(decoded.thinking == "thought", "thinking should survive")
}

test("ChatSession round-trips through JSON") {
    let original = makeRichSession()
    let data = try! JSONEncoder().encode(original)
    let decoded = try! JSONDecoder().decode(ChatSession.self, from: data)
    assert(decoded == original, "ChatSession should round-trip exactly")
    assert(decoded.messages.count == 3, "all 3 messages should survive")
    assert(decoded.messages[1].toolCalls?.first?.name == "web_search", "tool call name should survive")
    assert(decoded.messages[2].toolCallId == "call_1", "tool role message should keep toolCallId")
    assert(decoded.selectedText == "Swift docs", "selectedText should survive")
    assert(decoded.model == "qwen3.5-2b", "model should survive")
}

test("SessionStore save -> load equality") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    let session = makeRichSession()
    assert(store.save(session), "save should succeed")
    let loaded = store.load(id: session.id)
    assert(loaded != nil, "load should return the saved session")
    assert(loaded == session, "loaded session should equal the saved one")
}

test("SessionStore writes one <id>.json under sessions/") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    let session = makeRichSession()
    store.save(session)

    let expectedPath = ((dir as NSString).appendingPathComponent("sessions") as NSString)
        .appendingPathComponent("\(session.id).json")
    assert(FileManager.default.fileExists(atPath: expectedPath), "expected <id>.json under sessions/")
}

test("SessionStore list() returns summaries sorted by updatedAt desc") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    let older = ChatSession(title: "Older", createdAt: 10, updatedAt: 10,
                            messages: [ChatMessage(role: "user", content: "a")])
    let middle = ChatSession(title: "Middle", createdAt: 20, updatedAt: 20,
                             messages: [ChatMessage(role: "user", content: "b")])
    let newer = ChatSession(title: "Newer", createdAt: 30, updatedAt: 30,
                            messages: [ChatMessage(role: "user", content: "c")])
    // Save out of order to make sure the sort is real.
    store.save(middle)
    store.save(newer)
    store.save(older)

    let summaries = store.list()
    assert(summaries.count == 3, "should list 3 summaries, got \(summaries.count)")
    assert(summaries[0].id == newer.id, "newest should be first")
    assert(summaries[1].id == middle.id, "middle should be second")
    assert(summaries[2].id == older.id, "oldest should be last")
    assert(summaries[0].title == "Newer", "summary should carry the title")
}

test("SessionStore list() on empty/missing dir is []") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    assert(store.list().isEmpty, "no sessions yet -> empty list, no crash")
}

test("SessionStore list() tolerates an unreadable/corrupt file") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    let good = ChatSession(title: "Good", updatedAt: 50,
                           messages: [ChatMessage(role: "user", content: "hi")])
    store.save(good)

    // Drop a junk .json file alongside the good one.
    let sessionsDir = (dir as NSString).appendingPathComponent("sessions")
    let junkPath = (sessionsDir as NSString).appendingPathComponent("garbage.json")
    try! "not valid json {{{".write(toFile: junkPath, atomically: true, encoding: .utf8)

    let summaries = store.list()
    assert(summaries.count == 1, "corrupt file should be skipped, only 1 valid summary")
    assert(summaries.first?.id == good.id, "the good session should still be listed")
}

test("SessionStore delete removes the file") {
    let dir = createTempDir()
    defer { cleanup(dir) }

    let store = SessionStore(dir: dir)
    let session = makeRichSession()
    store.save(session)
    assert(store.load(id: session.id) != nil, "precondition: session saved")

    assert(store.delete(id: session.id), "delete should report success")
    assert(store.load(id: session.id) == nil, "session should be gone after delete")
    assert(store.list().isEmpty, "list should be empty after delete")
}

test("Forward-compat: decode a session JSON missing newer fields") {
    // A minimal/older session JSON with no model, no selectedText, and messages
    // that lack toolCalls/toolCallId/thinking/createdAt — must still decode.
    let json = """
    {
        "id": "legacy-1",
        "title": "Legacy",
        "createdAt": 5,
        "updatedAt": 6,
        "messages": [
            { "id": "m1", "role": "user", "content": "hello" },
            { "id": "m2", "role": "assistant", "content": "hi there" }
        ]
    }
    """.data(using: .utf8)!

    let decoded = try? JSONDecoder().decode(ChatSession.self, from: json)
    assert(decoded != nil, "older session JSON should decode")
    assert(decoded?.id == "legacy-1", "id should decode")
    assert(decoded?.model == nil, "missing model -> nil")
    assert(decoded?.selectedText == nil, "missing selectedText -> nil")
    assert(decoded?.messages.count == 2, "both messages should decode")
    assert(decoded?.messages.first?.toolCalls == nil, "missing toolCalls -> nil")
    assert(decoded?.messages.first?.createdAt == 0, "missing createdAt -> 0 default")
    assert(decoded?.messages.last?.thinking == nil, "missing thinking -> nil")
}

test("Forward-compat: extra unknown fields are ignored") {
    let json = """
    {
        "id": "future-1",
        "title": "Future",
        "createdAt": 1,
        "updatedAt": 2,
        "futureField": { "nested": true },
        "messages": [
            { "id": "m1", "role": "user", "content": "x", "brandNewField": 99 }
        ]
    }
    """.data(using: .utf8)!

    let decoded = try? JSONDecoder().decode(ChatSession.self, from: json)
    assert(decoded != nil, "session with unknown fields should still decode")
    assert(decoded?.messages.count == 1, "message should decode despite unknown field")
}

test("deriveTitle: single line, trimmed, ~40 chars with ellipsis") {
    let long = "This is a very long first user message that easily exceeds forty characters"
    let title = ChatSession.deriveTitle(firstUserMessage: long, selectedText: nil)
    assert(title.count <= 41, "title should be capped near 40 chars (+ellipsis), got \(title.count)")
    assert(title.hasSuffix("…"), "truncated title should end with an ellipsis")
    assert(!title.contains("\n"), "title should be single-line")
}

test("deriveTitle: collapses newlines/whitespace to single line") {
    let messy = "  hello\n\n   world\t\ttab  "
    let title = ChatSession.deriveTitle(firstUserMessage: messy, selectedText: nil)
    assert(title == "hello world tab", "should collapse whitespace, got '\(title)'")
}

test("deriveTitle: falls back to selectedText then timestamp") {
    let fromSelection = ChatSession.deriveTitle(firstUserMessage: "   ", selectedText: "picked text")
    assert(fromSelection == "picked text", "empty user msg -> use selectedText")

    let fallback = ChatSession.deriveTitle(firstUserMessage: nil, selectedText: nil, createdAt: 0)
    assert(fallback.hasPrefix("Chat "), "no content -> timestamp-based 'Chat ...' title, got '\(fallback)'")
}

test("hasMeaningfulExchange flags empty/aborted sessions") {
    let empty = ChatSession()
    assert(!empty.hasMeaningfulExchange, "empty session is not meaningful")

    let userOnly = ChatSession(messages: [ChatMessage(role: "user", content: "hi")])
    assert(!userOnly.hasMeaningfulExchange, "user-only session is not meaningful")

    let blankAssistant = ChatSession(messages: [
        ChatMessage(role: "user", content: "hi"),
        ChatMessage(role: "assistant", content: "   ")
    ])
    assert(!blankAssistant.hasMeaningfulExchange, "blank assistant reply is not meaningful")

    let real = ChatSession(messages: [
        ChatMessage(role: "user", content: "hi"),
        ChatMessage(role: "assistant", content: "hello!")
    ])
    assert(real.hasMeaningfulExchange, "user + real assistant reply is meaningful")
}

// MARK: - Results

print("\n========================================")
print("Results: \(passCount) passed, \(failCount) failed")
print("========================================")

if failCount > 0 {
    exit(1)
} else {
    print("All tests passed!")
    exit(0)
}
