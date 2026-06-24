// test-history.swift — Unit tests for the pure history search/filter predicate
// (History.swift). Co-compiles with History.swift + Core.swift:
//   swiftc -o /tmp/test-history tests/test-history.swift scripts/History.swift scripts/Core.swift && /tmp/test-history

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

// MARK: - Tests

print("Running HistorySearch tests...\n")

test("blank query matches everything") {
    assert(HistorySearch.isBlank(""), "empty string is blank")
    assert(HistorySearch.isBlank("   \n\t "), "whitespace-only is blank")
    assert(!HistorySearch.isBlank("x"), "non-empty is not blank")
    assert(HistorySearch.matches(query: "", title: "anything"), "blank query matches any title")
    assert(HistorySearch.matches(query: "   ", title: "anything"), "whitespace query matches any title")
}

test("title match is case- and diacritic-insensitive") {
    assert(HistorySearch.matches(query: "swift", title: "Swift Docs"), "case-insensitive title match")
    assert(HistorySearch.matches(query: "SWIFT", title: "swift docs"), "uppercase query matches lowercase title")
    assert(HistorySearch.matches(query: "cafe", title: "Visit a Café"), "diacritic-insensitive match")
    assert(!HistorySearch.matches(query: "python", title: "Swift Docs"), "non-matching query rejected")
}

test("query is trimmed before matching") {
    assert(HistorySearch.matches(query: "  swift  ", title: "Swift Docs"), "surrounding whitespace trimmed")
}

test("body is only consulted when provided (load-on-demand)") {
    // No body: a title-only miss stays a miss.
    assert(!HistorySearch.matches(query: "rebind", title: "Keyboard Notes"),
           "no body -> title-only miss")
    // With body: the same query now hits the message text.
    assert(HistorySearch.matches(query: "rebind", title: "Keyboard Notes",
                                 body: "how do I rebind ctrl+s"),
           "body provided -> message-text match")
    // Title still wins even with an unrelated body.
    assert(HistorySearch.matches(query: "keyboard", title: "Keyboard Notes",
                                 body: "unrelated"),
           "title match independent of body")
}

test("no false positive when neither title nor body matches") {
    assert(!HistorySearch.matches(query: "zzz", title: "Keyboard Notes", body: "nothing here"),
           "miss in both title and body")
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
