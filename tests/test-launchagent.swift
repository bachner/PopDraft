// test-launchagent.swift — unit tests for the launch-at-login self-heal policy.
//
// Co-compiled with scripts/Core.swift (NO AppKit, NO filesystem). Asserts:
//   - LoginItemPolicy.programPath appends the binary path inside the bundle,
//   - shouldRewrite heals a stale path only when running from /Applications
//     (the real-world poisoning: plist pointing at a dev-tree/DMG-staged copy),
//   - a matching plist is left alone (no pointless rewrites at every launch),
//   - a malformed plist (nil program path) is healed,
//   - a copy running OUTSIDE /Applications never rewrites — a dev-tree copy
//     capturing the login item is the bug this policy exists to undo.
//
// Keep it PURE — no plist I/O.

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

let installed = "/Applications/PopDraft.app"
let installedBin = "/Applications/PopDraft.app/Contents/MacOS/PopDraft"
let devStaged = "/Users/dev/llm-mac/build/dmg/PopDraft.app"

// ----------------------------------------------------------------------------
// programPath
// ----------------------------------------------------------------------------

section("programPath derives the binary path from the bundle path")

check(LoginItemPolicy.programPath(forBundle: installed) == installedBin,
      "programPath appends Contents/MacOS/PopDraft")

// ----------------------------------------------------------------------------
// shouldRewrite: installed copy heals stale/broken plists
// ----------------------------------------------------------------------------

section("installed copy heals a stale or broken plist")

check(LoginItemPolicy.shouldRewrite(existingProgramPath: devStaged + "/Contents/MacOS/PopDraft",
                                    bundlePath: installed),
      "stale dev-tree path is rewritten by the /Applications copy")

check(LoginItemPolicy.shouldRewrite(existingProgramPath: "/Volumes/PopDraft/PopDraft.app/Contents/MacOS/PopDraft",
                                    bundlePath: installed),
      "stale DMG-mount path is rewritten by the /Applications copy")

check(LoginItemPolicy.shouldRewrite(existingProgramPath: nil, bundlePath: installed),
      "malformed plist (nil program path) is rewritten by the /Applications copy")

check(LoginItemPolicy.shouldRewrite(existingProgramPath: "/Applications/PopDraft OLD.app/Contents/MacOS/PopDraft",
                                    bundlePath: installed),
      "renamed old copy under /Applications is still rewritten")

// ----------------------------------------------------------------------------
// shouldRewrite: no-op cases
// ----------------------------------------------------------------------------

section("matching plist is left alone")

check(!LoginItemPolicy.shouldRewrite(existingProgramPath: installedBin, bundlePath: installed),
      "plist already pointing at the running installed copy is NOT rewritten")

section("non-installed copies never capture the login item")

check(!LoginItemPolicy.shouldRewrite(existingProgramPath: installedBin, bundlePath: devStaged),
      "dev-tree copy does NOT steal a plist pointing at /Applications")

check(!LoginItemPolicy.shouldRewrite(existingProgramPath: devStaged + "/Contents/MacOS/PopDraft",
                                     bundlePath: devStaged),
      "dev-tree copy does NOT rewrite even a matching stale plist")

check(!LoginItemPolicy.shouldRewrite(existingProgramPath: nil,
                                     bundlePath: "/Volumes/PopDraft/PopDraft.app"),
      "DMG-mounted copy does NOT rewrite a malformed plist")

// ----------------------------------------------------------------------------

print("")
print("\(testsRun) checks, \(testsFailed) failed")
if testsFailed > 0 { exit(1) }
print("ALL LAUNCH-AGENT TESTS PASSED")
