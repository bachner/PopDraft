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

    if swiftc -O -o "$CONFIG_DIR/PopDraft" "$SCRIPT_DIR"/scripts/*.swift -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation -framework Network 2>/dev/null; then
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

# Copy bundled web assets for the chat's Markdown + Mermaid renderer so a
# source install (binary in ~/.popdraft) can find them via AppAssets.webResource.
if [ -d "$SCRIPT_DIR/resources/web" ]; then
    mkdir -p "$CONFIG_DIR/web"
    cp "$SCRIPT_DIR"/resources/web/* "$CONFIG_DIR/web/" 2>/dev/null
    echo "  [OK] Chat web assets installed"
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
