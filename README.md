# QuickLLM

System-wide AI text processing for macOS via keyboard shortcuts. Works in any application.

## Features

- **Grammar Check** (`Ctrl+Option+G`) - Fix grammar, spelling, and typos while preserving your tone
- **Articulate** (`Ctrl+Option+A`) - Improve clarity and professional expression
- **Craft Answer** (`Ctrl+Option+C`) - Generate a thoughtful response to selected text
- **Custom Prompt** (`Ctrl+Option+P`) - Enter any instruction via dialog
- **Chat** (`Ctrl+Option+L`) - Interactive conversation with selected text as context
- **Speak** (`Ctrl+Option+S`) - Text-to-speech using Kokoro-82M neural TTS

Select text anywhere, press a shortcut, and the result appears after your selection.

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

1. Select text in any application
2. Press a keyboard shortcut:
   | Shortcut | Action |
   |----------|--------|
   | `Ctrl+Option+G` | Grammar Check |
   | `Ctrl+Option+A` | Articulate |
   | `Ctrl+Option+C` | Craft Answer |
   | `Ctrl+Option+P` | Custom Prompt |
   | `Ctrl+Option+L` | Chat |
   | `Ctrl+Option+S` | Speak (TTS) |
3. Result appears after your selection (or Terminal/audio for Chat/Speak)

### Chat Mode

Opens an interactive Terminal session with your selected text as context. Type messages to continue the conversation. Type `exit` to quit.

### Text-to-Speech

Uses Kokoro-82M neural TTS for natural-sounding speech. First use downloads the model (~160MB).

```bash
# Command-line usage
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

Also update in `~/bin/llm-chat-session.sh` and recompile `LLMChat.swift` if using Chat.

### Change Keyboard Shortcuts

**System Settings** → **Keyboard** → **Keyboard Shortcuts** → **Services**

Find QuickLLM services under "Text" and double-click to change.

## File Structure

```
quickllm/
├── install.sh           # Installer
├── uninstall.sh         # Uninstaller
├── build-dmg.sh         # DMG builder
├── requirements.txt     # Python dependencies
├── scripts/
│   ├── llm-process.sh       # Core Ollama API client
│   ├── llm-clipboard.sh     # Clipboard handler
│   ├── llm-grammar.sh       # Grammar check
│   ├── llm-articulate.sh    # Articulate
│   ├── llm-answer.sh        # Craft answer
│   ├── llm-custom.sh        # Custom prompt
│   ├── llm-chat.sh          # Chat launcher
│   ├── llm-chat-session.sh  # Interactive chat
│   ├── llm-tts.py           # TTS client
│   ├── llm-tts-server.py    # TTS server
│   ├── llm-tts.sh           # TTS wrapper
│   ├── LLMChat.swift        # Native chat app
│   └── setup-workflows.sh   # Workflow generator
└── README.md
```

## Troubleshooting

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
# Check dependencies
python3 -c "import kokoro; print('OK')"

# Install if missing
pip install kokoro soundfile numpy
brew install espeak-ng
```

## Uninstall

```bash
./uninstall.sh
```

Or manually:
```bash
rm ~/bin/llm-*.sh ~/bin/llm-*.py ~/bin/LLMChat
rm -rf ~/Library/Services/LLM*.workflow
launchctl unload ~/Library/LaunchAgents/com.quickllm.tts-server.plist
rm ~/Library/LaunchAgents/com.quickllm.tts-server.plist
```

## License

MIT
