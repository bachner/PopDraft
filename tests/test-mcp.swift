// test-mcp.swift — unit tests for the MCP integration layer (PR10).
//
// Co-compiled with scripts/Core.swift (NO process execution, NO AppKit, NO
// network). Asserts the PURE pieces that make the agent MCP-capable and
// capability-aware:
//   - MCP JSON-RPC framing: initialize / tools-list / tools-call encode correctly,
//   - tools/list response → MCPToolSpec parsing,
//   - namespacing a server's tool into `<server>__<tool>`,
//   - tools/call result parsing (text content, isError, JSON-RPC error),
//   - the capability → MCP suggestion map (IntegrationCatalog.match) and the
//     concrete suggestion text it produces,
//   - the built-in-tool shadow guard (BuiltinToolNames) that keeps an MCP tool
//     from hijacking the confirm-gated run_shell / run_applescript.
//
// Keep it PURE — no actual execution, no spawning.

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

func decode(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// ----------------------------------------------------------------------------
// MCP JSON-RPC request framing: initialize / tools-list / tools-call
// ----------------------------------------------------------------------------

section("MCP JSON-RPC framing")

let initReq = decode(MCPProtocol.initializeRequest())
check(initReq["jsonrpc"] as? String == "2.0", "initialize is jsonrpc 2.0")
check(initReq["method"] as? String == "initialize", "initialize method")
check(initReq["id"] as? Int == 1, "initialize id == 1")
if let params = initReq["params"] as? [String: Any] {
    check(params["protocolVersion"] as? String == MCPProtocol.version,
          "initialize carries protocolVersion \(MCPProtocol.version)")
    check((params["clientInfo"] as? [String: Any])?["name"] as? String == "PopDraft",
          "initialize clientInfo.name == PopDraft")
    check((params["capabilities"] as? [String: Any])?["tools"] != nil,
          "initialize advertises a tools capability")
} else {
    check(false, "initialize has params")
}

let notif = decode(MCPProtocol.initializedNotification())
check(notif["method"] as? String == "notifications/initialized", "initialized notification method")
check(notif["id"] == nil, "initialized notification has no id")

let listReq = decode(MCPProtocol.toolsListRequest(id: 2))
check(listReq["method"] as? String == "tools/list", "tools/list method")
check(listReq["id"] as? Int == 2, "tools/list id == 2")

let callReq = decode(MCPProtocol.toolsCallRequest(id: 7, name: "echo", arguments: ["text": "hi"]))
check(callReq["method"] as? String == "tools/call", "tools/call method")
check(callReq["id"] as? Int == 7, "tools/call id passthrough")
if let p = callReq["params"] as? [String: Any] {
    check(p["name"] as? String == "echo", "tools/call params.name")
    check((p["arguments"] as? [String: Any])?["text"] as? String == "hi", "tools/call params.arguments")
} else {
    check(false, "tools/call has params")
}

// ----------------------------------------------------------------------------
// tools/list response → specs + namespacing
// ----------------------------------------------------------------------------

section("tools/list parsing + namespacing")

let toolsListResponse = """
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "echo",
        "description": "Echo a string back.",
        "inputSchema": {
          "type": "object",
          "properties": { "text": { "type": "string" } },
          "required": ["text"]
        }
      }
    ]
  }
}
""".data(using: .utf8)!

let parsed = MCPProtocol.parseToolsList(toolsListResponse)
check(parsed.count == 1, "parsed 1 MCP tool spec")
check(parsed.first?.name == "echo", "spec name == echo")
check((parsed.first?.inputSchema["required"] as? [String]) == ["text"], "spec input schema preserved")

// Namespacing — a space in the server name is normalized to '_'.
let nsSpec = parsed[0].toToolSpec(serverName: "my echo")
check(nsSpec.name == "my_echo__echo", "MCP tool namespaced as <server>__<tool> (spaces → _)")
check(MCPProtocol.namespacedToolName(server: "stub", tool: "echo") == "stub__echo",
      "namespacedToolName helper")

check(MCPProtocol.parseToolsList("not json".data(using: .utf8)!).isEmpty, "garbage → empty tool list")

// ----------------------------------------------------------------------------
// tools/call result parsing
// ----------------------------------------------------------------------------

section("tools/call result parsing")

let okResult = """
{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"hello"}]}}
""".data(using: .utf8)!
let (okText, okErr) = MCPProtocol.parseToolCallResult(okResult)
check(okText == "hello" && !okErr, "text content extracted, not error")

let isErrResult = """
{"jsonrpc":"2.0","id":7,"result":{"isError":true,"content":[{"type":"text","text":"bad input"}]}}
""".data(using: .utf8)!
let (errText, isErr) = MCPProtocol.parseToolCallResult(isErrResult)
check(errText == "bad input" && isErr, "isError flag honored")

let rpcErr = """
{"jsonrpc":"2.0","id":7,"error":{"code":-1,"message":"boom"}}
""".data(using: .utf8)!
let (rpcText, rpcIsErr) = MCPProtocol.parseToolCallResult(rpcErr)
check(rpcText.contains("boom") && rpcIsErr, "JSON-RPC error → error result")

check(MCPProtocol.responseId(okResult) == 7, "responseId extracts id")

// ----------------------------------------------------------------------------
// Capability → MCP suggestion map
// ----------------------------------------------------------------------------

section("capability → MCP suggestion map")

// Core capabilities each resolve to the expected integration.
check(IntegrationCatalog.match("read my email")?.id == "Gmail", "'read my email' → Gmail")
check(IntegrationCatalog.match("send an email to my boss")?.id == "Gmail", "'send an email' → Gmail")
check(IntegrationCatalog.match("what's on my calendar today")?.id == "Google_Calendar",
      "'calendar' → Google Calendar")
check(IntegrationCatalog.match("schedule a meeting")?.id == "Google_Calendar",
      "'meeting/schedule' → Google Calendar")
check(IntegrationCatalog.match("post this to slack")?.id == "Slack", "'slack' → Slack")
check(IntegrationCatalog.match("open my notion page")?.id == "Notion", "'notion' → Notion")
check(IntegrationCatalog.match("read a file on disk")?.id == "Filesystem", "'file on disk' → Filesystem")
check(IntegrationCatalog.match("open the github repo")?.id == "GitHub", "'github repo' → GitHub")

// Longest-keyword preference: "google calendar" must NOT fall back to a weaker
// match; nothing else owns "calendar" so this stays Calendar.
check(IntegrationCatalog.match("check google calendar availability")?.id == "Google_Calendar",
      "'google calendar availability' → Google Calendar (longest keyword wins)")

// Case-insensitive.
check(IntegrationCatalog.match("READ MY EMAIL")?.id == "Gmail", "match is case-insensitive")

// No match for something unrelated.
check(IntegrationCatalog.match("what is 2 + 2") == nil, "unrelated ask → no integration")
check(IntegrationCatalog.match("") == nil, "empty capability → nil")

// The suggestion text is concrete + actionable: names the server, the command,
// and points at Settings → MCP.
if let gmail = IntegrationCatalog.match("read my email") {
    let text = gmail.suggestionText()
    check(text.contains("Gmail"), "suggestion names the Gmail server")
    check(text.localizedCaseInsensitiveContains("Settings"), "suggestion points at Settings")
    check(text.contains("MCP"), "suggestion mentions MCP")
    check(text.contains("npx"), "suggestion includes the concrete command")
} else {
    check(false, "Gmail integration resolvable for suggestion-text test")
}

// Every catalog entry yields a non-empty, valid preset.
for cat in IntegrationCatalog.all {
    let preset = cat.preset
    check(!preset.name.isEmpty && !preset.command.isEmpty,
          "preset for \(cat.displayName) has name + command")
    check(preset.enabled == false, "preset for \(cat.displayName) is disabled by default")
}
check(IntegrationCatalog.all.count >= 5, "catalog has at least 5 presets")

// ----------------------------------------------------------------------------
// Built-in shadow guard: an MCP tool can't hijack a privileged built-in
// ----------------------------------------------------------------------------

section("built-in tool shadow guard")

check(BuiltinToolNames.isReserved("run_shell"), "run_shell is reserved")
check(BuiltinToolNames.isReserved("run_applescript"), "run_applescript is reserved")
check(BuiltinToolNames.isReserved("suggest_integration"), "suggest_integration is reserved")
check(BuiltinToolNames.isReserved("web_search"), "web_search is reserved")
check(!BuiltinToolNames.isReserved("Gmail__search_threads"), "a namespaced MCP tool is NOT reserved")

// A normally-namespaced MCP tool never collides with a built-in.
let normalSpec = MCPToolSpec(name: "list_files", description: "", inputSchema: ["type": "object"])
let normalNs = normalSpec.toToolSpec(serverName: "Files")
check(!BuiltinToolNames.isReserved(normalNs.name), "Files__list_files does not shadow a built-in")

// ----------------------------------------------------------------------------
// Summary
// ----------------------------------------------------------------------------

print("")
print("==========================================")
if testsFailed == 0 {
    print("test-mcp: ALL \(testsRun) CHECKS PASSED")
} else {
    print("test-mcp: \(testsFailed)/\(testsRun) CHECKS FAILED")
}
exit(testsFailed == 0 ? 0 : 1)
