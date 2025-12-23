# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Rules

**IMPORTANT:** When making git commits in this repository:
- **NEVER** add "Co-Authored-By: Claude" or any Claude co-author attribution
- **NEVER** add the Claude Code footer or any AI-generated markers to commit messages
- Keep commit messages clean and human-like

## Project Overview

QuickLLM is a macOS tool that provides system-wide LLM text processing via keyboard shortcuts. It integrates Ollama for text generation and Kokoro-82M for neural TTS, accessible from any application.

## Key Commands

```bash
# Installation (idempotent - safe to run multiple times)
./install.sh              # Full install: scripts, workflows, TTS dependencies
./uninstall.sh            # Clean removal

# Build DMG for distribution
./build-dmg.sh 1.0.0      # Creates build/QuickLLM-1.0.0.dmg

# Workflow setup (regenerate shortcuts)
./scripts/setup-workflows.sh

# Compile native chat app manually
swiftc -o ~/bin/LLMChat scripts/LLMChat.swift -framework Cocoa

# TTS dependency installation
brew install espeak-ng
pip install kokoro soundfile numpy

# TTS server management
launchctl load ~/Library/LaunchAgents/com.quickllm.tts-server.plist    # Start
launchctl unload ~/Library/LaunchAgents/com.quickllm.tts-server.plist  # Stop
tail -f /tmp/llm-tts-server.log                                         # Logs
curl http://127.0.0.1:7865/health                                       # Health check

# Test Ollama connectivity
curl http://localhost:11434/api/tags
```

## Architecture

### Data Flow
```
# Popup Menu Flow (Recommended)
Copy Text → Option+Space → Popup Menu → Select Action → Ollama API → Result pasted

# Keyboard Shortcut Flow
Selected Text → Keyboard Shortcut → Automator Workflow → llm-clipboard.sh → Ollama API → Result pasted
```

### Component Layers

**Popup Menu App (Primary Interface):**
- `QuickLLMApp.swift` - Native macOS menu bar app with floating popup
  - Global hotkey: Option+Space
  - Searchable action list
  - Direct Ollama API integration
  - LaunchAgent: `~/Library/LaunchAgents/com.quickllm.app.plist`

**Core Engine (for keyboard shortcuts):**
- `llm-process.sh` - Ollama API client (`/api/generate`), handles JSON escaping
- `llm-clipboard.sh` - Clipboard capture, LLM processing, auto-paste with clipboard restoration

**Feature Wrappers (thin scripts calling llm-clipboard.sh):**
- `llm-grammar.sh`, `llm-articulate.sh`, `llm-answer.sh`, `llm-custom.sh`

**Chat System:**
- `llm-chat.sh` - Launcher, saves context to temp file
- `llm-chat-session.sh` - Interactive Terminal chat with JSON message history (`/api/chat`)
- `LLMChat.swift` - Native macOS GUI (Cocoa), async URLSession requests

**TTS:**
- `llm-tts-server.py` - Persistent TTS server (keeps model loaded, ~400-600MB RAM)
- `llm-tts.py` - Client that uses server if running, falls back to direct loading
- `llm-tts.sh` - Shell wrapper for clipboard integration
- LaunchAgent: `~/Library/LaunchAgents/com.quickllm.tts-server.plist` (auto-start on login)

**System Integration:**
- `setup-workflows.sh` - Generates Automator Quick Action `.workflow` bundles in `~/Library/Services/`

### Keyboard Shortcuts (set via `defaults write pbs NSServicesStatus`)
- `Ctrl+Option+G` - Grammar Check
- `Ctrl+Option+A` - Articulate
- `Ctrl+Option+C` - Craft Answer
- `Ctrl+Option+P` - Custom Prompt
- `Ctrl+Option+L` - Chat
- `Ctrl+Option+S` - Speak (TTS)

## Configuration Points

**LLM Model** (hardcoded in 3 places):
- `llm-process.sh`: `"model": "qwen3-coder:480b-cloud"`
- `llm-chat-session.sh`: `MODEL="qwen3-coder:480b-cloud"`
- `LLMChat.swift`: `let model = "qwen3-coder:480b-cloud"`

**Ollama API:** `http://localhost:11434`

**TTS voices:** American (`af_heart`, `af_bella`, `am_adam`...) and British (`bf_emma`, `bm_george`...)

## Key Patterns

- Temp files via `mktemp /tmp/llm-*.XXXXXX` for context passing
- Clipboard state preserved and restored after operations
- System notifications via `osascript -e 'display notification'`
- All prompts include language preservation instruction
- Feature scripts are 3-line wrappers delegating to `llm-clipboard.sh`

## Installation Targets

- Scripts: `~/bin/`
- Workflows: `~/Library/Services/`
- PATH update: `~/.zshrc` or `~/.bashrc`
