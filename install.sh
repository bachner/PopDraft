#!/bin/bash
# QuickLLM Installer
# Installs LLM text processing tools for macOS

set -e

echo "QuickLLM Installer"
echo "===================="
echo ""

# Check for Ollama
echo "Checking requirements..."
if ! curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "Warning: Ollama doesn't appear to be running at localhost:11434"
    echo "   Please install Ollama from https://ollama.ai and start it"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "[OK] Ollama is running"
fi

# Get the directory where install.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create bin directory
echo ""
echo "Installing scripts to ~/bin/..."
mkdir -p ~/bin

# Copy scripts
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

cat > ~/Library/LaunchAgents/com.quickllm.tts-server.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.quickllm.tts-server</string>
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
sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.quickllm.tts-server.plist

# Stop any existing TTS server and load the LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.quickllm.tts-server.plist 2>/dev/null || true
pkill -f llm-tts-server.py 2>/dev/null || true
sleep 1
launchctl load ~/Library/LaunchAgents/com.quickllm.tts-server.plist 2>/dev/null || true

echo "  [OK] TTS server configured (auto-starts on login, ~400-600MB RAM)"

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
if swiftc -O -o ~/bin/QuickLLMApp "$SCRIPT_DIR/scripts/QuickLLMApp.swift" -framework Cocoa -framework Carbon 2>/dev/null; then
    echo "[OK] QuickLLM popup app compiled"

    # Create LaunchAgent for popup app
    cat > ~/Library/LaunchAgents/com.quickllm.app.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.quickllm.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>HOME_DIR/bin/QuickLLMApp</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
    sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.quickllm.app.plist
    launchctl unload ~/Library/LaunchAgents/com.quickllm.app.plist 2>/dev/null || true
    launchctl load ~/Library/LaunchAgents/com.quickllm.app.plist 2>/dev/null || true
    echo "[OK] QuickLLM popup app set to auto-start"
else
    echo "[WARN] Could not compile QuickLLM popup app"
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
            echo '# QuickLLM tools' >> "$SHELL_RC"
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
echo "POPUP MENU (Recommended):"
echo "  Option+Space  ->  Show action popup (copy text first)"
echo "  Look for the ✨ icon in your menu bar"
echo ""
echo "KEYBOARD SHORTCUTS:"
echo "  Ctrl+Option+G  ->  Grammar Check"
echo "  Ctrl+Option+A  ->  Articulate"
echo "  Ctrl+Option+C  ->  Craft Answer"
echo "  Ctrl+Option+P  ->  Custom Prompt"
echo "  Ctrl+Option+L  ->  Chat with Context"
echo "  Ctrl+Option+S  ->  Speak (Text-to-Speech)"
echo ""
echo "Usage: Select text, copy it (Cmd+C), then press Option+Space"
echo "       Or use keyboard shortcuts directly on selected text"
echo ""
echo "Note: You may need to restart apps for shortcuts to take effect."
echo "      Customize shortcuts in: System Settings > Keyboard > Keyboard Shortcuts > Services"
echo ""
