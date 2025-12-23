# PopDraft

System-wide AI text processing for macOS. Select text, press a shortcut, and get AI-powered improvements instantly.

## Features

### Popup Menu (Option+Space)
The easiest way to use PopDraft - a floating action menu that appears near your cursor:

- **Fix grammar and spelling** - Correct errors while preserving tone
- **Articulate** - Make text clearer and more professional
- **Explain simply** - Break down complex text
- **Craft a reply** - Generate thoughtful responses
- **Continue writing** - Extend your text
- **Read aloud** - Text-to-speech using neural TTS
- **Custom prompt** - Enter any instruction

### Keyboard Shortcuts
Direct shortcuts for common actions:

| Shortcut | Action |
|----------|--------|
| `Option+Space` | **Show popup menu** |
| `Ctrl+Option+G` | Grammar Check |
| `Ctrl+Option+A` | Articulate |
| `Ctrl+Option+C` | Craft Answer |
| `Ctrl+Option+P` | Custom Prompt |
| `Ctrl+Option+L` | Chat |
| `Ctrl+Option+S` | Speak (TTS) |

## Requirements

- macOS 13+ (Ventura or later)
- Python 3.10+ (for TTS features)
- **One of the following backends:**
  - **llama.cpp** (recommended) - Lightweight, direct model loading
  - **Ollama** - Easy model management

## Installation

### From DMG (Recommended)

1. Download `PopDraft-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and double-click **PopDraft.app**
3. Follow the Terminal prompts to choose your backend
4. Grant Accessibility permissions when prompted

### From Source

```bash
git clone https://github.com/YOUR_USERNAME/popdraft.git
cd popdraft
./install.sh
```

The installer will prompt you to choose:
1. **Backend**: llama.cpp or Ollama
2. **Model** (if llama.cpp): Download size from 2GB to 8.5GB

### Build DMG

```bash
./build-dmg.sh 1.0.0
# Output: build/PopDraft-1.0.0.dmg
```

## Backend Options

### llama.cpp (Recommended)

Minimal inference server that loads GGUF models directly. No GUI app required.

**Pros:**
- Smaller footprint
- Direct model control
- Auto-starts with the system

**Setup:** The installer handles everything:
- Installs llama.cpp via Homebrew
- Downloads your chosen model
- Sets up auto-start LaunchAgent

### Ollama

Convenient model management with automatic updates.

**Pros:**
- Easy model switching (`ollama pull model-name`)
- Automatic model updates
- Web UI available

**Setup:**
1. Install from [ollama.ai](https://ollama.ai)
2. Run `ollama pull qwen2.5:7b` (or your preferred model)
3. Choose Ollama during PopDraft installation

## Usage

### Popup Menu (Recommended)

1. **Select text** in any application
2. Press **Option+Space**
3. Select an action from the popup or type to search
4. **Preview the result** in the popup window
5. Click **Copy** (or press Enter) to copy to clipboard

Look for the sparkles icon in your menu bar.

**Keyboard shortcuts in popup:**
- `Up/Down` - Navigate actions
- `Enter` - Select action / Copy result
- `Escape` - Close popup / Go back
- Type to filter actions

### Keyboard Shortcuts

1. **Select text** in any application
2. Press a keyboard shortcut (e.g., `Ctrl+Option+G`)
3. Result appears after your selection

### Chat Mode

Opens an interactive session with your selected text as context. Type messages to continue the conversation. Type `exit` to quit.

### Text-to-Speech

Uses Kokoro-82M neural TTS for natural-sounding speech.

```bash
llm-tts.py "Hello, world!"
llm-tts.py -v bf_emma "British voice"
llm-tts.py -s 1.2 "Faster speech"
llm-tts.py -o output.wav "Save to file"
```

**Voices:** `af_heart`, `af_bella`, `am_adam` (American), `bf_emma`, `bm_george` (British)

## Configuration

Configuration file: `~/.popdraft/config`

```bash
# Backend: ollama or llamacpp
BACKEND=llamacpp

# Ollama settings
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=qwen2.5:7b

# llama.cpp settings
LLAMACPP_URL=http://localhost:8080
LLAMACPP_MODEL_PATH=~/.popdraft/models/qwen2.5-7b-instruct-q4_k_m.gguf
```

### Switch Backends

1. Edit `~/.popdraft/config`
2. Change `BACKEND=ollama` or `BACKEND=llamacpp`
3. Restart PopDraft (or log out/in)

### Change Model

**For llama.cpp:**
1. Download a GGUF model to `~/.popdraft/models/`
2. Update `LLAMACPP_MODEL_PATH` in config
3. Restart the llama server: `launchctl kickstart -k gui/$(id -u)/com.popdraft.llama-server`

**For Ollama:**
1. Pull the model: `ollama pull model-name`
2. Update `OLLAMA_MODEL` in config
3. Restart PopDraft

### Change Keyboard Shortcuts

**System Settings** -> **Keyboard** -> **Keyboard Shortcuts** -> **Services**

Find PopDraft services under "Text" and double-click to change.

### Change Popup Hotkey

Edit and recompile `scripts/PopDraft.swift` - modify the `registerGlobalHotKey()` function.

## File Structure

```
popdraft/
├── install.sh              # Installer (backend selection, model download)
├── uninstall.sh            # Uninstaller
├── build-dmg.sh            # DMG builder
├── scripts/
│   ├── llm-config.sh       # Configuration & API abstraction
│   ├── PopDraft.swift      # Popup menu app
│   ├── llm-process.sh      # Core LLM processing
│   ├── llm-clipboard.sh    # Clipboard handler
│   ├── llm-grammar.sh      # Grammar check
│   ├── llm-articulate.sh   # Articulate
│   ├── llm-answer.sh       # Craft answer
│   ├── llm-custom.sh       # Custom prompt
│   ├── llm-chat.sh         # Chat launcher
│   ├── llm-chat-session.sh # Interactive chat
│   ├── llm-tts.py          # TTS client
│   ├── llm-tts-server.py   # TTS server
│   ├── llm-tts.sh          # TTS wrapper
│   ├── LLMChat.swift       # Native chat app
│   └── setup-workflows.sh  # Workflow generator
├── ~/.popdraft/
│   ├── config              # Backend configuration
│   └── models/             # GGUF models (llama.cpp)
└── README.md
```

## Troubleshooting

### Popup not appearing

1. Check if PopDraft is running: `pgrep -f PopDraft`
2. Start it manually: `~/bin/PopDraft &`
3. Check for the sparkles icon in the menu bar

### Shortcuts not working

1. Restart the application you're using
2. Check **System Settings** -> **Keyboard** -> **Keyboard Shortcuts** -> **Services**
3. Verify Accessibility permissions are granted

### LLM not responding

**For llama.cpp:**
```bash
# Check if server is running
curl http://localhost:8080/health

# Check logs
tail -f /tmp/llm-llama-server.log

# Restart server
launchctl kickstart -k gui/$(id -u)/com.popdraft.llama-server
```

**For Ollama:**
```bash
# Check if running
curl http://localhost:11434/api/tags

# Start Ollama app if needed
```

### TTS issues

```bash
python3 -c "import kokoro; print('OK')"
pip install kokoro soundfile numpy
brew install espeak-ng
```

### View current configuration

```bash
~/bin/llm-config.sh
```

## Uninstall

```bash
./uninstall.sh
```

This removes:
- Scripts from `~/bin/`
- Workflows from `~/Library/Services/`
- LaunchAgents
- Configuration (optional)

## License

MIT
