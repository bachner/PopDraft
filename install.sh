#!/bin/bash
# PopDraft Installer
# Simple installer that sets up PopDraft and launches it

set -e

echo "PopDraft Installer"
echo "===================="
echo ""

# Get the directory where install.sh is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config directory
CONFIG_DIR="$HOME/.popdraft"
mkdir -p "$CONFIG_DIR"

# Check if running from app bundle (DMG install) or source
if [[ "$SCRIPT_DIR" == *".app/Contents/Resources"* ]]; then
    echo "Installing from app bundle..."
    APP_BUNDLE="${SCRIPT_DIR%/Contents/Resources}"

    # If app is in /Volumes, remind user to drag to Applications
    if [[ "$APP_BUNDLE" == /Volumes/* ]]; then
        echo ""
        echo "[INFO] Please drag PopDraft.app to Applications first."
        echo "       Then run the app from Applications."
        echo ""
        open -R "$APP_BUNDLE"
        exit 0
    fi
else
    echo "Installing from source..."

    # Compile PopDraft
    echo ""
    echo "Compiling PopDraft..."

    if swiftc -O -o "$CONFIG_DIR/PopDraft" "$SCRIPT_DIR/scripts/PopDraft.swift" -framework Cocoa -framework Carbon 2>/dev/null; then
        echo "  [OK] PopDraft compiled"
    else
        echo "  [ERROR] Failed to compile PopDraft"
        exit 1
    fi
fi

# Copy TTS server script
echo ""
echo "Setting up TTS server..."
if [ -f "$SCRIPT_DIR/scripts/llm-tts-server.py" ]; then
    cp "$SCRIPT_DIR/scripts/llm-tts-server.py" "$CONFIG_DIR/"
    chmod +x "$CONFIG_DIR/llm-tts-server.py"
    echo "  [OK] TTS server installed"
else
    echo "  [WARN] TTS server script not found"
fi

# Install TTS dependencies
echo ""
echo "Installing TTS dependencies..."

# Check for espeak-ng
if ! command -v espeak-ng &> /dev/null && ! command -v espeak &> /dev/null; then
    echo "  Installing espeak-ng..."
    if command -v brew &> /dev/null; then
        brew install espeak-ng 2>/dev/null || echo "  [WARN] Could not install espeak-ng"
    else
        echo "  [WARN] Homebrew not found. Install espeak-ng manually: brew install espeak-ng"
    fi
else
    echo "  [OK] espeak-ng is available"
fi

# Install Python packages
echo "  Installing Python packages..."
if python3 -m pip install --user kokoro soundfile numpy 2>/dev/null; then
    echo "  [OK] TTS packages installed"
else
    echo "  [WARN] Could not install TTS packages. Install manually: pip install kokoro soundfile numpy"
fi

# Create default config if it doesn't exist
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    echo '{"provider":"llamacpp"}' > "$CONFIG_DIR/config.json"
    echo "  [OK] Default config created"
fi

# Launch PopDraft
echo ""
echo "==========================================="
echo "[OK] Installation complete!"
echo "==========================================="
echo ""
echo "Launching PopDraft..."
echo ""

if [ -f "$CONFIG_DIR/PopDraft" ]; then
    # Running compiled version from source install
    "$CONFIG_DIR/PopDraft" &
elif [ -d "/Applications/PopDraft.app" ]; then
    # Running from Applications
    open "/Applications/PopDraft.app"
else
    echo "[INFO] PopDraft not found. Please launch it manually."
fi

echo "Look for the sparkles icon in your menu bar."
echo "Press Option+Space to show the action popup."
echo ""
