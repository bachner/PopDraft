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
| `Ctrl+Option+S` | Speak (TTS) |

## Requirements

- macOS 13+ (Ventura or later)
- Python 3.10+ (for TTS features)
- **One of the following backends:**
  - **llama.cpp** (default) - Runs locally, no account needed
  - **Ollama** - Local models with easy management
  - **OpenAI API** - GPT-4o and other OpenAI models (requires API key)
  - **Claude API** - Claude 3.5/4 models (requires API key)

## Installation

### From DMG (Recommended)

1. Download `PopDraft-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and drag **PopDraft.app** to Applications
3. Launch PopDraft from Applications
4. Complete the onboarding:
   - Grant Accessibility permissions when prompted
   - Choose your LLM backend (llama.cpp, Ollama, OpenAI, or Claude)
   - Enter API key if using OpenAI or Claude

### From Source

```bash
git clone https://github.com/YOUR_USERNAME/popdraft.git
cd popdraft
./install.sh
```

### Build DMG

```bash
./build-dmg.sh 1.0.0
# Output: build/PopDraft-1.0.0.dmg
```

## Backend Options

### llama.cpp (Default)

Minimal inference server that loads GGUF models directly. Runs completely locally.

**Pros:**
- No account or API key needed
- Complete privacy - data never leaves your machine
- Auto-starts with the system

**Setup:** The installer handles everything:
- Installs llama.cpp via Homebrew
- Downloads your chosen model (~4GB)
- Sets up auto-start LaunchAgent

### Ollama

Local model management with easy switching between models.

**Pros:**
- Easy model switching (`ollama pull model-name`)
- Supports cloud models via Ollama's service
- Good for trying different models

**Setup:**
1. Choose Ollama during installation (offers to install via Homebrew if needed)
2. Run `ollama pull qwen2.5:7b` (or your preferred model)

### OpenAI API

Use GPT-4o and other OpenAI models via their API.

**Pros:**
- Access to latest GPT models
- No local compute needed
- Fast responses

**Setup:**
1. Get an API key from [platform.openai.com](https://platform.openai.com)
2. Choose OpenAI during installation
3. Enter your API key when prompted

**Available models:** gpt-4o, gpt-4o-mini, gpt-4.1, o1, o3-mini, and more

### Claude API

Use Claude 3.5/4 models via Anthropic's API.

**Pros:**
- Excellent at writing and analysis tasks
- Strong reasoning capabilities
- No local compute needed

**Setup:**
1. Get an API key from [console.anthropic.com](https://console.anthropic.com)
2. Choose Claude during installation
3. Enter your API key when prompted

**Available models:** claude-sonnet-4-5, claude-opus-4-5, claude-sonnet-4, claude-3-5-sonnet, claude-3-5-haiku

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

**During TTS playback:**
- `Space` - Pause / Resume
- `Escape` - Stop and close

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
# Provider: llamacpp, ollama, openai, or claude
PROVIDER=llamacpp

# llama.cpp settings
LLAMACPP_URL=http://localhost:8080

# Ollama settings
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=qwen2.5:7b
OLLAMA_FALLBACK_MODEL=

# OpenAI settings
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o

# Claude settings
CLAUDE_API_KEY=sk-ant-...
CLAUDE_MODEL=claude-sonnet-4-5-20250514
```

### Switch Providers

**Option 1: Use Settings UI**
1. Click the sparkles icon in the menu bar
2. Select **Settings...**
3. Choose your provider and configure options

**Option 2: Edit config file**
1. Edit `~/.popdraft/config`
2. Change `PROVIDER=` to your desired provider
3. Restart PopDraft

### Change Model

**For llama.cpp:**
1. Download a GGUF model to `~/.popdraft/models/`
2. Restart the llama server: `launchctl kickstart -k gui/$(id -u)/com.popdraft.llama-server`

**For Ollama:**
1. Pull the model: `ollama pull model-name`
2. Update `OLLAMA_MODEL` in config or use Settings UI

**For OpenAI/Claude:**
1. Update the model in Settings UI, or
2. Edit `OPENAI_MODEL` or `CLAUDE_MODEL` in config

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

**For OpenAI/Claude:**
- Verify your API key is correct in Settings
- Check your account has available credits
- Ensure you have network connectivity

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

## Author

Built by [Ofer Bachner](https://www.linkedin.com/in/ofer-bachner/)

## License

MIT + Commons Clause - See [LICENSE](LICENSE) for details.
