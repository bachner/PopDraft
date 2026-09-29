// test-localserver.swift — which background processes PopDraft may run or stop.
//
// Co-compiled with scripts/Core.swift (pure; no process is started or signalled).
// Asserts:
//   - LocalServerPolicy: the local llama-server runs ONLY for the llamacpp
//     provider (never for ollama / openai / claude / unknown values),
//   - LocalServerPolicy.isOwnedServer: only a llama-server on OUR port (10819) or
//     serving a model from ~/.popdraft/models counts as ours — a user's own
//     llama-server elsewhere is never touched,
//   - LegacyTTSServer.isServer: only python running ~/.popdraft/llm-tts-server.py
//     (not an editor/grep on it, not a copy elsewhere),
//   - ProcessTable: ps parsing + filtering by uid and self.

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

let home = "/Users/u"

// ----------------------------------------------------------------------------
// Provider policy
// ----------------------------------------------------------------------------

section("Local llama-server runs only for llama.cpp")

check(LocalServerPolicy.shouldRun(provider: "llamacpp"), "llamacpp → run")
for p in ["ollama", "openai", "claude", "gemini", "openrouter", "", "LLAMACPP", "llama.cpp"] {
    check(!LocalServerPolicy.shouldRun(provider: p), "\(p.isEmpty ? "<empty>" : p) → never run")
}
check(LocalServerPolicy.ownedPort == 10819, "owned port is 10819")

// ----------------------------------------------------------------------------
// Owned llama-server matching
// ----------------------------------------------------------------------------

section("Owned llama-server matching")

let ours = [
    // What PopDraft's launchd plist runs (the process seen with provider=ollama).
    "/opt/homebrew/bin/llama-server -m /Users/u/.popdraft/models/Qwen3.5-4B-Q4_K_M.gguf --port 10819 -ngl 99 -np 1 --jinja -fa on -ctk q4_0 -ctv q4_0 -c 131072",
    "/usr/local/bin/llama-server --port 10819 -m /some/other/model.gguf",
    "llama-server --port=10819",
    // The retired :10820 vision sidecar — also ours (models dir).
    "/opt/homebrew/bin/llama-server -m /Users/u/.popdraft/models/Qwen3.5-0.8B-Q4_K_M.gguf --mmproj /Users/u/.popdraft/models/mmproj-Qwen3.5-0.8B-F16.gguf --port 10820",
    "/opt/homebrew/bin/llama-server --model /Users/u/.popdraft/models/x.gguf --port 9999",
    "/opt/homebrew/bin/llama-server --model=/Users/u/.popdraft/models/x.gguf",
]
for c in ours {
    check(LocalServerPolicy.isOwnedServer(command: c, home: home), "ours: \(c.prefix(72))")
}

let notOurs = [
    "/opt/homebrew/bin/llama-server -m /Users/u/models/mine.gguf --port 8080",           // user's own server
    "/opt/homebrew/bin/llama-server -m /Users/u/models/mine.gguf",                       // default port 8080
    "/opt/homebrew/bin/llama-server --port 108190 -m /x.gguf",                           // not our port
    "/opt/homebrew/bin/llama-server -m /Users/other/.popdraft/models/x.gguf --port 8081", // another user's dir
    "/opt/homebrew/bin/llama-server -m /Users/u/.popdraft/modelsX/x.gguf --port 8081",   // prefix trap
    "/opt/homebrew/bin/llama-cli -m /Users/u/.popdraft/models/x.gguf",                   // not the server
    "vim /Users/u/.popdraft/models/notes --port 10819",                                  // not llama-server
    "tail -f /tmp/llm-llama-server.log",
    "grep llama-server --port 10819",
    "",
]
for c in notOurs {
    check(!LocalServerPolicy.isOwnedServer(command: c, home: home), "not ours: \(c.isEmpty ? "<empty>" : String(c.prefix(72)))")
}

// ----------------------------------------------------------------------------
// Legacy TTS server matching
// ----------------------------------------------------------------------------

section("Leftover TTS server matching")

let script = "/Users/u/.popdraft/llm-tts-server.py"
check(LegacyTTSServer.scriptPath(home: home) == script, "script path under ~/.popdraft")
check(LegacyTTSServer.pidFilePath(home: home) == "/Users/u/.llm-tts-server.pid", "pid file path")

let ttsOurs = [
    "/Users/u/.popdraft/tts-venv/bin/python3 \(script)",
    "/usr/bin/python3 \(script)",
    "/opt/homebrew/Cellar/python@3.12/3.12.4/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python \(script)",
    "python3 -u \(script) --daemon",
]
for c in ttsOurs {
    check(LegacyTTSServer.isServer(command: c, home: home), "ours: \(c.prefix(72))")
}
let ttsNotOurs = [
    "vim \(script)",
    "/usr/bin/less \(script)",
    "grep -n foo \(script)",
    "python3 -m py_compile \(script)",
    "python3 /Users/u/dev/llm-mac/scripts/llm-tts-server.py",   // dev copy
    "python3 /Users/other/.popdraft/llm-tts-server.py",         // another user's
    "python3 \(script).bak",
    "python3 \(script)x",
    script,                                                     // no interpreter
    "",
]
for c in ttsNotOurs {
    check(!LegacyTTSServer.isServer(command: c, home: home), "not ours: \(c.isEmpty ? "<empty>" : String(c.prefix(72)))")
}

// ----------------------------------------------------------------------------
// ps parsing + filtering
// ----------------------------------------------------------------------------

section("ProcessTable")

let psOutput = """
  101   501 /Users/u/.popdraft/tts-venv/bin/python3 \(script)
  102   501 vim \(script)
  103     0 /usr/bin/python3 \(script)
  104   501 /opt/homebrew/bin/llama-server -m /Users/u/.popdraft/models/a.gguf --port 10819
  105   501 /opt/homebrew/bin/llama-server -m /Users/u/models/mine.gguf --port 8080
  106   501 /Users/u/.popdraft/tts-venv/bin/python3 \(script)
  107     0 /opt/homebrew/bin/llama-server --port 10819
garbage line
"""
let rows = ProcessTable.parse(psOutput)
check(rows.count == 7, "parses 7 rows, skips garbage (got \(rows.count))")
check(rows.first == ProcessRow(pid: 101, uid: 501, command: "/Users/u/.popdraft/tts-venv/bin/python3 \(script)"),
      "row fields parsed (pid, uid, command)")
check(ProcessTable.pids(in: rows, uid: 501, selfPID: 106) { LegacyTTSServer.isServer(command: $0, home: home) } == [101],
      "TTS sweep: our uid only; skips editor, root, and self")
check(ProcessTable.pids(in: rows, uid: 501, selfPID: 1) { LocalServerPolicy.isOwnedServer(command: $0, home: home) } == [104],
      "llama sweep: our server only; skips the user's :8080 server and root's")
check(ProcessTable.parse("").isEmpty, "empty ps output → no rows")

// ----------------------------------------------------------------------------

print("")
print("\(testsRun) checks, \(testsFailed) failed")
if testsFailed > 0 { exit(1) }
print("ALL LOCAL-SERVER TESTS PASSED")
