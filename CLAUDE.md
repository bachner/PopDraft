# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Rules

**IMPORTANT:** When making git commits in this repository:
- **NEVER** add "Co-Authored-By: Claude" or any Claude co-author attribution
- **NEVER** add the Claude Code footer or any AI-generated markers to commit messages
- Keep commit messages clean and human-like

## Project Overview

PopDraft is a macOS menu bar app that provides system-wide LLM text processing via keyboard shortcuts. It supports multiple backends (llama.cpp, Ollama, OpenAI, Claude) for text generation and Kokoro-82M for neural TTS.

## Key Commands

```bash
# Installation from source
./install.sh              # Compile and install PopDraft

# Build DMG for distribution
./build-dmg.sh 2.0.0      # Creates build/PopDraft-2.0.0.dmg

# Clean removal
./uninstall.sh

# TTS dependencies (installed by install.sh)
brew install espeak-ng
pip install kokoro soundfile numpy

# Test TTS server
curl http://127.0.0.1:7865/health
```

## Architecture

### Data Flow
```
Selected Text -> Option+Space -> Popup Menu -> Select Action -> LLM API -> Result Preview -> Copy
                      OR
Selected Text -> Ctrl+Option+Shortcut -> Direct Action -> LLM API -> Result Preview -> Copy
```

### Files

**Main App:** the macOS app is split across focused, co-compiled `scripts/*.swift`
files (one Swift target, NO module boundaries — they share a namespace). The build
globs `scripts/*.swift`, so adding a file needs no build-line change. Key files:
- `scripts/Main.swift` - `@main` entry (`PopDraftMain`) + `--debug-show` harness
- `scripts/App.swift` - AppDelegate, menu bar, DependencyManager, UpdateManager, LaunchAtLogin
- `scripts/Hotkeys.swift` - Carbon HotkeyManager / global shortcuts
- `scripts/Popup.swift` - PopupView + PopupWindowController (action menu state machine)
- `scripts/Bubble.swift` - corner bubble (lives in `Chat.swift`)
- `scripts/Chat.swift` - ChatView, AgentChatViewModel, markdown/tool-call cards, BubbleView
- `scripts/Settings.swift` - SettingsView + tabs (General/Models/Actions/MCP/Voice), MCP settings
- `scripts/Onboarding.swift` - first-run onboarding
- `scripts/Agent.swift` - LLMClient (llama.cpp/Ollama/OpenAI/Claude), PopDraftAgent, text tools, **tool self-registration bootstrap** (`BuiltinTools`)
- `scripts/WebEngine.swift` - WebEngine, RendererPool, PinningProxy, web/browser tools
- `scripts/MacControl.swift` - confirm-gated run_shell / run_applescript tools
- `scripts/MCP.swift` - MCPClient / MCPManager
- `scripts/TTS.swift`, `scripts/LlamaServer.swift`, `scripts/ActionManager.swift`,
  `scripts/Models.swift`, `scripts/UIKitGlass.swift`, `scripts/Headless.swift` - supporting concerns
- `scripts/Core.swift` - pure/unit-tested core (config, agent loop, tool registry, `AgentToolCatalog`)

**Agent tool self-registration:** built-in tools are NOT listed in a shared
function. Each feature file declares a `BuiltinToolGroup` (gate + factory) and
registers it into `AgentToolCatalog` (in `Core.swift`) via its `register()`;
`BuiltinTools.installAll()` in `Agent.swift` is the single bootstrap, armed by
`BuiltinTools.arm()` at startup. `PopDraftAgent.buildRegistry` and
`BuiltinToolNames.reserved` are both DERIVED from the catalog — adding a tool is a
change to one feature file, not an edit to a shared list.

**TTS Server:**
- `scripts/llm-tts-server.py` - Kokoro TTS HTTP server

**Config:**
- `scripts/llm-config.sh` - Backend configuration helper (for debugging)

**Build & Install:**
- `install.sh` - Source installation script
- `uninstall.sh` - Clean removal
- `build-dmg.sh` - DMG creation for distribution
- `.github/workflows/build.yml` - CI/CD for GitHub releases

### Keyboard Shortcuts (registered in Swift)
- `Option+Space` - Show popup menu
- `Ctrl+Option+G` - Grammar Check
- `Ctrl+Option+A` - Articulate
- `Ctrl+Option+C` - Craft Answer
- `Ctrl+Option+P` - Custom Prompt
- `Ctrl+Option+S` - Speak (TTS)

## Configuration

**Config file:** `~/.popdraft/config.json`

```json
{
  "provider": "llamacpp",
  "ollamaModel": "qwen3.5:4b",
  "openaiAPIKey": "",
  "openaiModel": "gpt-4o",
  "claudeAPIKey": "",
  "claudeModel": "claude-sonnet-4-20250514",
  "ttsVoice": "af_heart",
  "ttsSpeed": 1.0
}
```

**API endpoints:**
- llama.cpp: `http://localhost:10819` (OpenAI-compatible)
- Ollama: `http://localhost:11434`
- OpenAI: `https://api.openai.com/v1/chat/completions`
- Claude: `https://api.anthropic.com/v1/messages`

**TTS server:** `http://127.0.0.1:7865`

**Agent / Mac-control / MCP config (PR9):** under `agentSettings` and `mcpServers`
in `config.json`:
```json
{
  "agentSettings": {
    "enableMacControl": false,        // master switch for run_shell / run_applescript (default OFF)
    "autoApproveSafeReadOnly": false, // skip confirm for ls/cat/pwd/echo/date/whoami (default OFF)
    "macControlDryRun": false,        // headless/eval: never execute, record "would execute" (default OFF)
    "enableWebSearch": true,
    "maxIterations": 6
  },
  "mcpServers": []                    // [{name, command, args, enabled}] — stdio JSON-RPC servers
}
```
Mac-control tools are confirm-gated: the agent PROPOSES; nothing runs without an
explicit user Approve/Edit (or the opt-in auto-approve-safe-read-only path). A
hard denylist (sudo, `rm -rf /`, `curl|sh`, fork bomb, `dd if=`, `> /dev/…`,
shutdown/reboot) is enforced even on Approve. MacControlGuard / MacControlPolicy
live in `scripts/Core.swift` (pure, unit-tested by `tests/test-maccontrol.swift`).

## WebEngine IP pinning (PR11) — DNS-rebinding defense

The WebEngine's `SafetyGuard` resolves a host and verifies every IP is public,
but WKWebView resolves the host AGAIN when it opens its socket — a hostile DNS
server could return a public IP to the guard and a private IP (e.g.
`169.254.169.254`, `10.x`, `127.x`) to WebKit (DNS-rebinding / TOCTOU).

**Primary control (macOS 14+):** an in-process forward proxy (`PinningProxy`,
Network framework) bound to `127.0.0.1:<ephemeral>`. WKWebView is pointed at it
via `WKWebsiteDataStore.proxyConfigurations` (and the search `URLSession` via
`URLSessionConfiguration.proxyConfigurations`). For every connection the proxy
resolves the target ONCE, runs all addresses through `SafetyGuard.pinnedAddress`
(fail-closed: reject if ANY is private/loopback/metadata, else pick one public
IP), and **dials that exact validated IP** — CONNECT is blind-tunnelled (no TLS
interception; certs validate in WebKit as normal), plain HTTP is forwarded with
a corrected Host header and byte cap. Because we dial the validated IP, WebKit
never resolves the host → rebinding is **closed on macOS 14+**.

**Fallback (macOS 13):** `proxyConfigurations` is 14+ only. On 13 the engine
keeps the PR6 mitigation (require all resolved IPs public, redirect cap, redirect
+ response-URL re-validation) — a residual rebinding risk remains on 13 only.

**Defense in depth:** the `decidePolicyFor` / response-host SSRF checks in
`NavigationBridge` stay as a backstop on every OS. Pure decision logic
(`SafetyGuard.pinnedAddress`, `ProxyParser` request parsing) is in `Core.swift`
and unit-tested by `tests/test-ippinning.swift`; the proxy round-trip is covered
by `tests/test-webengine-gui.swift` (RUN_GUI_TESTS=1). The build links
`-framework Network`.

## Installation Targets

- App: `/Applications/PopDraft.app`
- Config: `~/.popdraft/config.json`
- TTS Script: `~/.popdraft/llm-tts-server.py`
- LaunchAgent: `~/Library/LaunchAgents/com.popdraft.app.plist` (auto-created by app)
