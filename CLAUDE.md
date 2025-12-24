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

**Main App:**
- `scripts/PopDraft.swift` - Complete macOS app including:
  - Menu bar with sparkles icon
  - Popup window for text processing
  - HotkeyManager for global keyboard shortcuts
  - OnboardingWindowController for first-run setup
  - TTSServerManager for TTS subprocess
  - LaunchAtLoginManager for auto-start
  - Multi-provider LLM support (llama.cpp, Ollama, OpenAI, Claude)
  - Settings window with General/LLM/TTS tabs

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
  "ollamaModel": "qwen2.5:7b",
  "openaiAPIKey": "",
  "openaiModel": "gpt-4o",
  "claudeAPIKey": "",
  "claudeModel": "claude-sonnet-4-20250514",
  "ttsVoice": "af_heart",
  "ttsSpeed": 1.0
}
```

**API endpoints:**
- llama.cpp: `http://localhost:8080` (OpenAI-compatible)
- Ollama: `http://localhost:11434`
- OpenAI: `https://api.openai.com/v1/chat/completions`
- Claude: `https://api.anthropic.com/v1/messages`

**TTS server:** `http://127.0.0.1:7865`

## Installation Targets

- App: `/Applications/PopDraft.app`
- Config: `~/.popdraft/config.json`
- TTS Script: `~/.popdraft/llm-tts-server.py`
- LaunchAgent: `~/Library/LaunchAgents/com.popdraft.app.plist` (auto-created by app)
