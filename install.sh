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

    # Write version file from latest git tag (e.g., v2.6.0 -> 2.6.0)
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
        APP_VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
        if [ -n "$APP_VERSION" ]; then
            echo "$APP_VERSION" > "$CONFIG_DIR/version"
            echo "  [OK] Version set to $APP_VERSION"
        fi
    fi
fi

# Copy TTS server script
echo ""
echo "Setting up TTS server..."
TTS_SCRIPT=""
if [ -f "$SCRIPT_DIR/scripts/llm-tts-server.py" ]; then
    TTS_SCRIPT="$SCRIPT_DIR/scripts/llm-tts-server.py"
elif [ -f "$SCRIPT_DIR/llm-tts-server.py" ]; then
    # App bundle path: script is in Contents/Resources/ directly
    TTS_SCRIPT="$SCRIPT_DIR/llm-tts-server.py"
fi

if [ -n "$TTS_SCRIPT" ]; then
    cp "$TTS_SCRIPT" "$CONFIG_DIR/"
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

# Install Python packages into venv
# kokoro >= 0.9.4 requires Python 3.10-3.12, so we can't use the macOS system python3 (3.9)
# or recent Homebrew pythons (3.13+). Find a compatible interpreter, installing one if needed.
echo "  Looking for Python 3.10-3.12 (required by kokoro)..."

PYTHON_BIN=""
for py in python3.12 python3.11 python3.10 \
          /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
          /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3.10; do
    if command -v "$py" &> /dev/null; then
        PYTHON_BIN="$py"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "  No Python 3.10-3.12 found. Installing python@3.12 via Homebrew..."
    if command -v brew &> /dev/null; then
        if brew install python@3.12; then
            BREW_PREFIX="$(brew --prefix)"
            if [ -x "$BREW_PREFIX/opt/python@3.12/bin/python3.12" ]; then
                PYTHON_BIN="$BREW_PREFIX/opt/python@3.12/bin/python3.12"
            elif command -v python3.12 &> /dev/null; then
                PYTHON_BIN="python3.12"
            fi
        else
            echo "  [ERROR] brew install python@3.12 failed"
        fi
    else
        echo "  [ERROR] Homebrew not found. Install Python 3.10-3.12 manually, then re-run."
    fi
fi

if [ -n "$PYTHON_BIN" ]; then
    echo "  [OK] Using $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"
    echo "  Creating Python virtual environment..."
    # Remove old venv to avoid issues with corrupted/partial venvs
    rm -rf "$CONFIG_DIR/tts-venv"
    if "$PYTHON_BIN" -m venv "$CONFIG_DIR/tts-venv"; then
        echo "  [OK] Virtual environment created"
        echo "  Upgrading pip..."
        "$CONFIG_DIR/tts-venv/bin/pip" install --upgrade pip > /dev/null
        echo "  Installing Python packages (this may take a few minutes)..."
        if "$CONFIG_DIR/tts-venv/bin/pip" install "kokoro>=0.9.4" "misaki[ja]" "misaki[zh]" soundfile numpy; then
            if "$CONFIG_DIR/tts-venv/bin/python3" -c "import kokoro" 2>/dev/null; then
                echo "  [OK] TTS packages installed and verified"
            else
                echo "  [WARN] kokoro installed but import failed"
            fi
        else
            echo "  [ERROR] Failed to install TTS packages. Install manually:"
            echo "         $CONFIG_DIR/tts-venv/bin/pip install \"kokoro>=0.9.4\" \"misaki[ja]\" \"misaki[zh]\" soundfile numpy"
        fi
    else
        echo "  [ERROR] Could not create Python venv with $PYTHON_BIN"
    fi
else
    echo "  [ERROR] No usable Python found. TTS will not work until Python 3.10-3.12 is installed."
fi

# Restore config from backup if it doesn't exist (e.g., after uninstall + reinstall)
if [ ! -f "$CONFIG_DIR/config.json" ] && [ -f /tmp/popdraft-config-backup.json ]; then
    cp /tmp/popdraft-config-backup.json "$CONFIG_DIR/config.json"
    rm -f /tmp/popdraft-config-backup.json
    echo "  [OK] Config restored from backup"
elif [ ! -f "$CONFIG_DIR/config.json" ]; then
    echo '{"provider":"llamacpp"}' > "$CONFIG_DIR/config.json"
    echo "  [OK] Default config created"
fi

if [ ! -f "$CONFIG_DIR/actions.json" ] && [ -f /tmp/popdraft-actions-backup.json ]; then
    cp /tmp/popdraft-actions-backup.json "$CONFIG_DIR/actions.json"
    rm -f /tmp/popdraft-actions-backup.json
    echo "  [OK] Actions restored from backup"
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
