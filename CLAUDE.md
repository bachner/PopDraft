# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Rules

**IMPORTANT:** When making git commits in this repository:
- **NEVER** add "Co-Authored-By: Claude" or any Claude co-author attribution
- **NEVER** add the Claude Code footer or any AI-generated markers to commit messages
- Keep commit messages clean and human-like

## Project Overview

QuickLLM is a macOS tool that provides system-wide LLM text processing via keyboard shortcuts. It supports multiple backends (llama.cpp or Ollama) for text generation and Kokoro-82M for neural TTS, accessible from any application.

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

# llama.cpp server management (if using llama.cpp backend)
launchctl load ~/Library/LaunchAgents/com.quickllm.llama-server.plist   # Start
launchctl unload ~/Library/LaunchAgents/com.quickllm.llama-server.plist # Stop
tail -f /tmp/llm-llama-server.log                                        # Logs
curl http://localhost:8080/health                                        # Health check

# Test backend connectivity
# For llama.cpp:
curl http://localhost:8080/health
# For Ollama:
curl http://localhost:11434/api/tags
```

## Architecture

### Data Flow
```
# Popup Menu Flow (Recommended)
Copy Text -> Option+Space -> Popup Menu -> Select Action -> LLM API -> Result Preview -> Copy Button

# Keyboard Shortcut Flow
Selected Text -> Keyboard Shortcut -> Automator Workflow -> llm-clipboard.sh -> LLM API -> Result pasted
```

### Component Layers

**Configuration:**
- `~/.quickllm/config` - Backend selection and settings (ollama or llamacpp)
- `~/.quickllm/models/` - GGUF model storage for llama.cpp
- `llm-config.sh` - Configuration helper with unified API abstraction

**Popup Menu App (Primary Interface):**
- `PopDraft.swift` - Native macOS menu bar app with floating popup
  - Global hotkey: Option+Space
  - Searchable action list with 7 actions (including TTS)
  - Result preview with Copy button (no auto-paste)
  - State machine: actionList -> processing -> result/error
  - Reads config from ~/.quickllm/config for backend selection
  - TTS integration via HTTP server at localhost:7865
  - LaunchAgent: `~/Library/LaunchAgents/com.popdraft.app.plist`

**Core Engine (for keyboard shortcuts):**
- `llm-config.sh` - Unified API abstraction for both backends
- `llm-process.sh` - Text processing using llm-config.sh
- `llm-clipboard.sh` - Clipboard capture, LLM processing, auto-paste with clipboard restoration

**Feature Wrappers (thin scripts calling llm-clipboard.sh):**
- `llm-grammar.sh`, `llm-articulate.sh`, `llm-answer.sh`, `llm-custom.sh`

**Chat System:**
- `llm-chat.sh` - Launcher, saves context to temp file
- `llm-chat-session.sh` - Interactive Terminal chat with JSON message history
- `LLMChat.swift` - Native macOS GUI (Cocoa), async URLSession requests

**TTS:**
- `llm-tts-server.py` - Persistent TTS server (keeps model loaded, ~400-600MB RAM)
- `llm-tts.py` - Client that uses server if running, falls back to direct loading
- `llm-tts.sh` - Shell wrapper for clipboard integration
- LaunchAgent: `~/Library/LaunchAgents/com.quickllm.tts-server.plist` (auto-start on login)

**LLM Server (llama.cpp backend only):**
- LaunchAgent: `~/Library/LaunchAgents/com.quickllm.llama-server.plist`
- Runs `llama-server` with configured model on port 8080

**System Integration:**
- `setup-workflows.sh` - Generates Automator Quick Action `.workflow` bundles in `~/Library/Services/`

### Keyboard Shortcuts (set via `defaults write pbs NSServicesStatus`)
- `Ctrl+Option+G` - Grammar Check
- `Ctrl+Option+A` - Articulate
- `Ctrl+Option+C` - Craft Answer
- `Ctrl+Option+P` - Custom Prompt
- `Ctrl+Option+L` - Chat
- `Ctrl+Option+S` - Speak (TTS)

## Configuration

**Config file:** `~/.quickllm/config`

```bash
# Backend: ollama or llamacpp
BACKEND=llamacpp

# Ollama settings
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=qwen2.5:7b

# llama.cpp settings
LLAMACPP_URL=http://localhost:8080
LLAMACPP_MODEL_PATH=~/.quickllm/models/qwen2.5-7b-instruct-q4_k_m.gguf
```

**Switching backends:** Edit `~/.quickllm/config`, change `BACKEND=`, then restart PopDraft.

**API endpoints:**
- llama.cpp: `http://localhost:8080` (OpenAI-compatible `/v1/chat/completions`)
- Ollama: `http://localhost:11434` (`/api/generate`, `/api/chat`)

**TTS voices:** American (`af_heart`, `af_bella`, `am_adam`...) and British (`bf_emma`, `bm_george`...)

## Key Patterns

- Temp files via `mktemp /tmp/llm-*.XXXXXX` for context passing
- Clipboard state preserved and restored after operations
- System notifications via `osascript -e 'display notification'`
- All prompts include language preservation instruction
- Feature scripts are 3-line wrappers delegating to `llm-clipboard.sh`
- Unified API in `llm-config.sh` handles backend differences

## Installation Targets

- Scripts: `~/bin/`
- Config: `~/.quickllm/config`
- Models: `~/.quickllm/models/`
- Workflows: `~/Library/Services/`
- LaunchAgents: `~/Library/LaunchAgents/`
- PATH update: `~/.zshrc` or `~/.bashrc`
