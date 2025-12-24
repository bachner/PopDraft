#!/bin/bash
# PopDraft Installer
# Installs LLM text processing tools for macOS

set -e

echo "PopDraft Installer"
echo "===================="
echo ""

# Get the directory where install.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config directory
CONFIG_DIR="$HOME/.popdraft"
CONFIG_FILE="$CONFIG_DIR/config"
MODELS_DIR="$CONFIG_DIR/models"

mkdir -p "$CONFIG_DIR"
mkdir -p "$MODELS_DIR"

# Backend selection
echo "Choose your LLM backend:"
echo "  1) llama.cpp [default] - runs locally, downloads model (~4GB)"
echo "  2) Ollama - local/cloud models, easy management"
echo "  3) OpenAI API - GPT-4o, GPT-4 (requires API key)"
echo "  4) Claude API - Claude 3.5 Sonnet (requires API key)"
echo ""
read -p "Enter choice [1-4, default=1]: " BACKEND_CHOICE
BACKEND_CHOICE=${BACKEND_CHOICE:-1}

case "$BACKEND_CHOICE" in
    2) SELECTED_BACKEND="ollama" ;;
    3) SELECTED_BACKEND="openai" ;;
    4) SELECTED_BACKEND="claude" ;;
    *) SELECTED_BACKEND="llamacpp" ;;
esac

echo ""
echo "Selected backend: $SELECTED_BACKEND"
echo ""

# Backend-specific setup
if [ "$SELECTED_BACKEND" = "openai" ]; then
    echo "Setting up OpenAI API..."
    echo ""
    echo "Get your API key from: https://platform.openai.com/api-keys"
    echo ""
    read -p "Enter your OpenAI API key: " OPENAI_API_KEY

    if [ -z "$OPENAI_API_KEY" ]; then
        echo "[ERROR] API key is required for OpenAI backend"
        exit 1
    fi

    echo ""
    echo "Available models:"
    echo "  1) gpt-4o [default] - best quality, faster"
    echo "  2) gpt-4o-mini - cheaper, good quality"
    echo "  3) gpt-4-turbo - high quality"
    echo ""
    read -p "Enter choice [1-3, default=1]: " MODEL_CHOICE

    case "$MODEL_CHOICE" in
        2) OPENAI_MODEL="gpt-4o-mini" ;;
        3) OPENAI_MODEL="gpt-4-turbo" ;;
        *) OPENAI_MODEL="gpt-4o" ;;
    esac

    echo "  [OK] Using model: $OPENAI_MODEL"

    # Write config
    cat > "$CONFIG_FILE" << EOF
# PopDraft Configuration
BACKEND=openai

# OpenAI settings
OPENAI_API_KEY=$OPENAI_API_KEY
OPENAI_MODEL=$OPENAI_MODEL
EOF

    echo "  [OK] Configuration saved to $CONFIG_FILE"

elif [ "$SELECTED_BACKEND" = "claude" ]; then
    echo "Setting up Claude API..."
    echo ""
    echo "Get your API key from: https://console.anthropic.com/settings/keys"
    echo ""
    read -p "Enter your Anthropic API key: " CLAUDE_API_KEY

    if [ -z "$CLAUDE_API_KEY" ]; then
        echo "[ERROR] API key is required for Claude backend"
        exit 1
    fi

    echo ""
    echo "Available models:"
    echo "  1) claude-sonnet-4-20250514 [default] - best balance"
    echo "  2) claude-3-5-sonnet-20241022 - great for coding"
    echo "  3) claude-3-5-haiku-20241022 - faster, cheaper"
    echo ""
    read -p "Enter choice [1-3, default=1]: " MODEL_CHOICE

    case "$MODEL_CHOICE" in
        2) CLAUDE_MODEL="claude-3-5-sonnet-20241022" ;;
        3) CLAUDE_MODEL="claude-3-5-haiku-20241022" ;;
        *) CLAUDE_MODEL="claude-sonnet-4-20250514" ;;
    esac

    echo "  [OK] Using model: $CLAUDE_MODEL"

    # Write config
    cat > "$CONFIG_FILE" << EOF
# PopDraft Configuration
BACKEND=claude

# Claude/Anthropic settings
CLAUDE_API_KEY=$CLAUDE_API_KEY
CLAUDE_MODEL=$CLAUDE_MODEL
EOF

    echo "  [OK] Configuration saved to $CONFIG_FILE"

elif [ "$SELECTED_BACKEND" = "ollama" ]; then
    echo "Setting up Ollama..."

    # Check if Ollama is installed
    OLLAMA_INSTALLED=false
    if command -v ollama &> /dev/null; then
        OLLAMA_INSTALLED=true
        echo "  [OK] Ollama is installed"
    else
        echo "  Ollama is not installed."
        echo ""
        read -p "Would you like to install Ollama via Homebrew? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v brew &> /dev/null; then
                echo "  Installing Ollama..."
                brew install ollama
                OLLAMA_INSTALLED=true
                echo "  [OK] Ollama installed"
                echo ""
                echo "  Starting Ollama service..."
                brew services start ollama
                sleep 3
            else
                echo "  [ERROR] Homebrew not found. Please install Ollama manually from https://ollama.ai"
                exit 1
            fi
        else
            echo "  Please install Ollama from https://ollama.ai and run this installer again."
            exit 1
        fi
    fi

    # Check if Ollama is running
    OLLAMA_RUNNING=false
    if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
        OLLAMA_RUNNING=true
        echo "  [OK] Ollama is running"
    else
        echo "  [WARN] Ollama is not running. Starting it..."
        if command -v brew &> /dev/null; then
            brew services start ollama 2>/dev/null || ollama serve &
        else
            ollama serve &
        fi
        sleep 3
        if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
            OLLAMA_RUNNING=true
            echo "  [OK] Ollama started"
        else
            echo "  [WARN] Could not start Ollama. Please start it manually."
        fi
    fi

    # Model selection
    SELECTED_MODEL="qwen2.5:7b"
    FALLBACK_MODEL=""

    if [ "$OLLAMA_RUNNING" = true ]; then
        echo ""
        echo "Available Ollama models:"

        MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    models = [m['name'] for m in data.get('models', [])]
    for i, m in enumerate(models[:15], 1):
        print(f'  {i}) {m}')
    if len(models) > 15:
        print(f'  ... and {len(models) - 15} more')
except:
    pass
" 2>/dev/null)

        if [ -n "$MODELS" ]; then
            echo "$MODELS"
        else
            echo "  No models found. You can pull models with: ollama pull <model>"
        fi

        echo ""
        echo "Enter model name (or press Enter for default):"
        echo "  Cloud models: qwen3-coder:480b-cloud, llama3:70b-cloud"
        echo "  Local models: qwen2.5:7b, llama3:8b, mistral:7b"
        echo ""
        read -p "Model [default: qwen2.5:7b]: " USER_MODEL
        if [ -n "$USER_MODEL" ]; then
            SELECTED_MODEL="$USER_MODEL"
        fi
    fi

    echo "  [OK] Using model: $SELECTED_MODEL"

    # Write config
    cat > "$CONFIG_FILE" << EOF
# PopDraft Configuration
BACKEND=ollama

# Ollama settings
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=$SELECTED_MODEL
EOF

    echo "  [OK] Configuration saved to $CONFIG_FILE"

elif [ "$SELECTED_BACKEND" = "llamacpp" ]; then
    echo "Setting up llama.cpp..."

    # Install llama.cpp via Homebrew
    if ! command -v llama-server &> /dev/null; then
        echo "  Installing llama.cpp via Homebrew..."
        if command -v brew &> /dev/null; then
            brew install llama.cpp
            echo "  [OK] llama.cpp installed"
        else
            echo "  [ERROR] Homebrew not found. Please install Homebrew first:"
            echo "          /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
    else
        echo "  [OK] llama.cpp already installed"
    fi

    # Model selection
    echo ""
    echo "Choose a model to download:"
    echo "  1) Qwen 2.5 7B Instruct Q4 (4.4 GB - good balance)"
    echo "  2) Qwen 2.5 3B Instruct Q4 (2.0 GB - faster, lighter)"
    echo "  3) Qwen 2.5 14B Instruct Q4 (8.5 GB - higher quality)"
    echo "  4) Skip model download (I'll provide my own)"
    echo ""
    read -p "Enter choice [1-4, default=1]: " MODEL_CHOICE
    MODEL_CHOICE=${MODEL_CHOICE:-1}

    MODEL_URL=""
    MODEL_FILE=""
    case "$MODEL_CHOICE" in
        1)
            MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf"
            MODEL_FILE="qwen2.5-7b-instruct-q4_k_m.gguf"
            ;;
        2)
            MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
            MODEL_FILE="qwen2.5-3b-instruct-q4_k_m.gguf"
            ;;
        3)
            MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"
            MODEL_FILE="qwen2.5-14b-instruct-q4_k_m.gguf"
            ;;
        4)
            echo "  Skipping model download."
            echo "  Set LLAMACPP_MODEL_PATH in ~/.popdraft/config to your model path."
            MODEL_FILE=""
            ;;
    esac

    if [ -n "$MODEL_URL" ]; then
        MODEL_PATH="$MODELS_DIR/$MODEL_FILE"
        if [ -f "$MODEL_PATH" ]; then
            echo "  [OK] Model already exists: $MODEL_FILE"
        else
            echo "  Downloading model: $MODEL_FILE"
            echo "  This may take a while depending on your connection..."
            curl -L --progress-bar -o "$MODEL_PATH" "$MODEL_URL"
            echo "  [OK] Model downloaded to $MODEL_PATH"
        fi
    fi

    # Write config
    cat > "$CONFIG_FILE" << EOF
# PopDraft Configuration
BACKEND=llamacpp

# llama.cpp settings
LLAMACPP_URL=http://localhost:8080
LLAMACPP_MODEL_PATH=$MODELS_DIR/${MODEL_FILE:-model.gguf}
EOF

    echo "  [OK] Configuration saved to $CONFIG_FILE"
fi

# Create bin directory
echo ""
echo "Installing scripts to ~/bin/..."
mkdir -p ~/bin

# Copy scripts
cp "$SCRIPT_DIR/scripts/llm-config.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-process.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-clipboard.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-grammar.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-articulate.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-answer.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-custom.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-chat.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-chat-session.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-tts.py" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-tts.sh" ~/bin/
cp "$SCRIPT_DIR/scripts/llm-tts-server.py" ~/bin/

# Install TTS dependencies
echo ""
echo "Setting up Text-to-Speech (Kokoro-82M)..."

# Check for espeak-ng (required for phoneme processing)
if ! command -v espeak-ng &> /dev/null && ! command -v espeak &> /dev/null; then
    echo "  Installing espeak-ng..."
    if command -v brew &> /dev/null; then
        brew install espeak-ng 2>/dev/null || echo "  [WARN] Could not install espeak-ng via Homebrew"
    else
        echo "  [WARN] Homebrew not found. Please install espeak-ng manually:"
        echo "         brew install espeak-ng"
    fi
else
    echo "  [OK] espeak-ng is available"
fi

# Install Python dependencies for TTS
echo "  Installing Python packages for TTS..."
if python3 -m pip install --user kokoro soundfile numpy 2>/dev/null; then
    echo "  [OK] TTS Python packages installed"
else
    echo "  [WARN] Could not install TTS packages. Install manually with:"
    echo "         pip install kokoro soundfile numpy"
fi

# Setup TTS server LaunchAgent for auto-start on login
echo "  Setting up TTS server auto-start..."
mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/com.popdraft.tts-server.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.popdraft.tts-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>llm-tts-server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>HOME_DIR/bin</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-tts-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-tts-server.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

# Replace HOME_DIR placeholder with actual home directory
sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.popdraft.tts-server.plist

# Stop any existing TTS server and load the LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.popdraft.tts-server.plist 2>/dev/null || true
pkill -f llm-tts-server.py 2>/dev/null || true
sleep 1
launchctl load ~/Library/LaunchAgents/com.popdraft.tts-server.plist 2>/dev/null || true

echo "  [OK] TTS server configured (auto-starts on login, ~400-600MB RAM)"

# Setup llama.cpp server LaunchAgent if using llama.cpp backend
if [ "$SELECTED_BACKEND" = "llamacpp" ] && [ -n "$MODEL_FILE" ]; then
    echo ""
    echo "Setting up llama.cpp server auto-start..."

    cat > ~/Library/LaunchAgents/com.popdraft.llama-server.plist << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.popdraft.llama-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/llama-server</string>
        <string>-m</string>
        <string>$MODELS_DIR/$MODEL_FILE</string>
        <string>--port</string>
        <string>8080</string>
        <string>-ngl</string>
        <string>99</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-llama-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-llama-server.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST

    # Check if llama-server is in /usr/local/bin instead (Intel Macs)
    if [ ! -f /opt/homebrew/bin/llama-server ] && [ -f /usr/local/bin/llama-server ]; then
        sed -i '' "s|/opt/homebrew/bin/llama-server|/usr/local/bin/llama-server|g" ~/Library/LaunchAgents/com.popdraft.llama-server.plist
    fi

    # Stop any existing llama server and load the LaunchAgent
    launchctl unload ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>/dev/null || true
    pkill -f "llama-server.*8080" 2>/dev/null || true
    sleep 1
    launchctl load ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>/dev/null || true

    echo "  [OK] llama.cpp server configured (auto-starts on login)"
    echo "  [INFO] Server will start loading model in background..."
    echo "  [INFO] Check logs: tail -f /tmp/llm-llama-server.log"
fi

# Compile and install native chat app
echo ""
echo "Compiling native apps..."

# Chat app
if swiftc -o ~/bin/LLMChat "$SCRIPT_DIR/scripts/LLMChat.swift" -framework Cocoa 2>/dev/null; then
    echo "[OK] Native chat app compiled"
else
    echo "[WARN] Could not compile native chat app, falling back to Terminal"
    echo '#!/bin/bash
    export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
    CONTEXT_FILE="$1"
    osascript -e "tell application \"Terminal\"
        activate
        do script \"\\\"$HOME/bin/llm-chat-session.sh\\\" \\\"$CONTEXT_FILE\\\"\"
    end tell"' > ~/bin/LLMChat
    chmod +x ~/bin/LLMChat
fi

# Popup app (menu bar)
if swiftc -O -o ~/bin/PopDraft "$SCRIPT_DIR/scripts/PopDraft.swift" -framework Cocoa -framework Carbon 2>/dev/null; then
    echo "[OK] PopDraft app compiled"

    # Create LaunchAgent for popup app
    cat > ~/Library/LaunchAgents/com.popdraft.app.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.popdraft.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>HOME_DIR/bin/PopDraft</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
    sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.popdraft.app.plist
    launchctl unload ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    launchctl load ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    echo "[OK] PopDraft app set to auto-start"
else
    echo "[WARN] Could not compile PopDraft app"
fi

# Make executable
chmod +x ~/bin/llm-*.sh ~/bin/llm-*.py

echo "[OK] Scripts installed to ~/bin/"

# Add ~/bin to PATH if not already there
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo ""
    echo "Adding ~/bin to PATH..."

    SHELL_RC=""
    if [ -f ~/.zshrc ]; then
        SHELL_RC=~/.zshrc
    elif [ -f ~/.bashrc ]; then
        SHELL_RC=~/.bashrc
    fi

    if [ -n "$SHELL_RC" ]; then
        if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$SHELL_RC"; then
            echo '' >> "$SHELL_RC"
            echo '# PopDraft tools' >> "$SHELL_RC"
            echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
            echo "[OK] Added ~/bin to PATH in $SHELL_RC"
        fi
    fi
fi

# Setup Quick Action workflows
echo ""
echo "Setting up Quick Action workflows..."
bash "$SCRIPT_DIR/scripts/setup-workflows.sh"

echo ""
echo "==========================================="
echo "[OK] Installation complete!"
echo "==========================================="
echo ""
echo "Backend: $SELECTED_BACKEND"
if [ "$SELECTED_BACKEND" = "llamacpp" ]; then
    echo "Model: $MODEL_FILE"
fi
echo ""
echo "POPUP MENU (Recommended):"
echo "  Option+Space  ->  Show action popup (copy text first)"
echo "  Look for the sparkles icon in your menu bar"
echo ""
echo "KEYBOARD SHORTCUTS:"
echo "  Ctrl+Option+G  ->  Grammar Check"
echo "  Ctrl+Option+A  ->  Articulate"
echo "  Ctrl+Option+C  ->  Craft Answer"
echo "  Ctrl+Option+P  ->  Custom Prompt"
echo "  Ctrl+Option+L  ->  Chat with Context"
echo "  Ctrl+Option+S  ->  Speak (Text-to-Speech)"
echo ""
echo "Usage: Select text, then press Option+Space"
echo "       Or use keyboard shortcuts directly on selected text"
echo ""
echo "Configuration: ~/.popdraft/config"
echo "To switch backends, edit the config file and restart PopDraft."
echo ""
echo "Note: You may need to restart apps for shortcuts to take effect."
echo "      Customize shortcuts in: System Settings > Keyboard > Keyboard Shortcuts > Services"
echo ""
