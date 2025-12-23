# QuickLLM

System-wide AI text processing for macOS. Select text, press a shortcut, and get AI-powered improvements instantly.

## Features

### Popup Menu (Option+Space)
The easiest way to use QuickLLM - a floating action menu that appears near your cursor:

- **Fix grammar and spelling** - Correct errors while preserving tone
- **Articulate** - Make text clearer and more professional
- **Explain simply** - Break down complex text
- **Craft a reply** - Generate thoughtful responses
- **Continue writing** - Extend your text
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
- [Ollama](https://ollama.ai) running locally
- Python 3.10+ (for TTS features)

## Installation

### From DMG (Recommended)

1. Download `QuickLLM-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and double-click **QuickLLM.app**
3. Follow the Terminal prompts
4. Grant Accessibility permissions when prompted

### From Source

```bash
git clone https://github.com/YOUR_USERNAME/quickllm.git
cd quickllm
./install.sh
```

### Build DMG

```bash
./build-dmg.sh 1.0.0
# Output: build/QuickLLM-1.0.0.dmg
```

## Usage

### Popup Menu (Recommended)

1. **Copy text** to clipboard (Cmd+C)
2. Press **Option+Space**
3. Select an action from the popup or type to search
4. Result is automatically pasted

Look for the ✨ icon in your menu bar.

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

### Change LLM Model

Edit `~/bin/llm-process.sh`:
```bash
"model": "your-model-name"
```

Also update in:
- `~/bin/llm-chat-session.sh`
- `~/bin/QuickLLMApp` (requires recompile)

### Change Keyboard Shortcuts

**System Settings** → **Keyboard** → **Keyboard Shortcuts** → **Services**

Find QuickLLM services under "Text" and double-click to change.

### Change Popup Hotkey

Edit and recompile `scripts/QuickLLMApp.swift` - modify the `registerGlobalHotKey()` function.

## File Structure

```
quickllm/
├── install.sh              # Installer
├── uninstall.sh            # Uninstaller
├── build-dmg.sh            # DMG builder
├── requirements.txt        # Python dependencies
├── scripts/
│   ├── QuickLLMApp.swift   # Popup menu app (NEW)
│   ├── llm-process.sh      # Core Ollama API client
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
└── README.md
```

## Troubleshooting

### Popup not appearing

1. Check if QuickLLMApp is running: `pgrep -f QuickLLMApp`
2. Start it manually: `~/bin/QuickLLMApp &`
3. Check for the ✨ icon in the menu bar

### Shortcuts not working

1. Restart the application you're using
2. Check **System Settings** → **Keyboard** → **Keyboard Shortcuts** → **Services**
3. Verify Accessibility permissions are granted

### Ollama not responding

```bash
curl http://localhost:11434/api/tags
```

### TTS issues

```bash
python3 -c "import kokoro; print('OK')"
pip install kokoro soundfile numpy
brew install espeak-ng
```

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
