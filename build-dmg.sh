#!/bin/bash
# Build DMG installer for PopDraft
# Creates a distributable disk image with drag-to-install

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-1.0.0}"
APP_NAME="PopDraft"
DMG_NAME="PopDraft-${VERSION}"
BUILD_DIR="${SCRIPT_DIR}/build"
DMG_DIR="${BUILD_DIR}/dmg"
APP_BUNDLE="${DMG_DIR}/${APP_NAME}.app"

echo "Building PopDraft DMG v${VERSION}..."

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${DMG_DIR}"

# Create the .app bundle structure
echo "Creating application bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Resources/scripts"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PopDraft Installer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.popdraft.installer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PopDraft</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# Create the installer launcher script
cat > "${APP_BUNDLE}/Contents/MacOS/PopDraft Installer" << 'LAUNCHER'
#!/bin/bash
# PopDraft Installer Launcher
# This script runs the installation from within the .app bundle

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="${SCRIPT_DIR}/../Resources"

# Open Terminal and run the installer
osascript << EOF
tell application "Terminal"
    activate
    do script "cd '${RESOURCES_DIR}' && ./install.sh; echo ''; echo 'Press any key to close...'; read -n 1"
end tell
EOF
LAUNCHER

chmod +x "${APP_BUNDLE}/Contents/MacOS/PopDraft Installer"

# Copy all necessary files to Resources
echo "Copying resources..."

# Copy scripts
cp "${SCRIPT_DIR}/scripts/llm-process.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-clipboard.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-grammar.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-articulate.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-answer.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-custom.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-chat.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-chat-session.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-tts.py" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-tts.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-tts-server.py" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/llm-chat-gui.py" "${APP_BUNDLE}/Contents/Resources/scripts/" 2>/dev/null || true
cp "${SCRIPT_DIR}/scripts/llm-chat-gui.sh" "${APP_BUNDLE}/Contents/Resources/scripts/" 2>/dev/null || true
cp "${SCRIPT_DIR}/scripts/LLMChat.swift" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/PopDraft.swift" "${APP_BUNDLE}/Contents/Resources/scripts/"
cp "${SCRIPT_DIR}/scripts/setup-workflows.sh" "${APP_BUNDLE}/Contents/Resources/scripts/"

# Copy pre-compiled binaries if they exist
if [ -f "${SCRIPT_DIR}/scripts/LLMChat" ]; then
    cp "${SCRIPT_DIR}/scripts/LLMChat" "${APP_BUNDLE}/Contents/Resources/scripts/"
fi
if [ -f "${SCRIPT_DIR}/scripts/PopDraft" ]; then
    cp "${SCRIPT_DIR}/scripts/PopDraft" "${APP_BUNDLE}/Contents/Resources/scripts/"
fi

# Copy root files
cp "${SCRIPT_DIR}/install.sh" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/uninstall.sh" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/requirements.txt" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/README.md" "${APP_BUNDLE}/Contents/Resources/"

# Create a modified install.sh that works from the app bundle
cat > "${APP_BUNDLE}/Contents/Resources/install.sh" << 'INSTALLER'
#!/bin/bash
# PopDraft Installer (bundled version)
# Installs LLM text processing tools with system-wide keyboard shortcuts

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_SRC="${SCRIPT_DIR}/scripts"

echo "=========================================="
echo "  PopDraft Installer"
echo "=========================================="
echo ""

# Create ~/bin if it doesn't exist
mkdir -p ~/bin

# Copy scripts to ~/bin
echo "Installing scripts to ~/bin..."
SCRIPTS=(
    "llm-process.sh"
    "llm-clipboard.sh"
    "llm-grammar.sh"
    "llm-articulate.sh"
    "llm-answer.sh"
    "llm-custom.sh"
    "llm-chat.sh"
    "llm-chat-session.sh"
    "llm-tts.py"
    "llm-tts.sh"
    "llm-tts-server.py"
    "setup-workflows.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [ -f "${SCRIPTS_SRC}/${script}" ]; then
        cp "${SCRIPTS_SRC}/${script}" ~/bin/
        chmod +x ~/bin/"${script}"
        echo "  Installed: ${script}"
    fi
done

# Copy optional scripts
for script in llm-chat-gui.py llm-chat-gui.sh; do
    if [ -f "${SCRIPTS_SRC}/${script}" ]; then
        cp "${SCRIPTS_SRC}/${script}" ~/bin/
        chmod +x ~/bin/"${script}"
        echo "  Installed: ${script}"
    fi
done

# Install TTS dependencies
echo ""
echo "Checking TTS dependencies..."

# Check for espeak-ng
if ! command -v espeak-ng &> /dev/null && ! command -v espeak &> /dev/null; then
    echo "Installing espeak-ng via Homebrew..."
    if command -v brew &> /dev/null; then
        brew install espeak-ng
    else
        echo "WARNING: Homebrew not found. Please install espeak-ng manually:"
        echo "  brew install espeak-ng"
    fi
else
    echo "  espeak-ng: OK"
fi

# Install Python packages
echo "Installing Python packages..."
python3 -m pip install --user kokoro soundfile numpy 2>/dev/null || \
    pip3 install --user kokoro soundfile numpy 2>/dev/null || \
    echo "WARNING: Could not install Python packages. Install manually: pip install kokoro soundfile numpy"

# Create TTS server LaunchAgent
echo ""
echo "Setting up TTS server auto-start..."
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
    <string>~/bin</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/llm-tts-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/llm-tts-server.log</string>
</dict>
</plist>
PLIST

# Fix the path expansion in plist
sed -i '' "s|~/bin|$HOME/bin|g" ~/Library/LaunchAgents/com.popdraft.tts-server.plist

# Load the LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.popdraft.tts-server.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.popdraft.tts-server.plist
echo "  TTS server configured for auto-start"

# Compile native apps
echo ""
echo "Compiling native apps..."

# Chat app
if [ -f "${SCRIPTS_SRC}/LLMChat" ]; then
    cp "${SCRIPTS_SRC}/LLMChat" ~/bin/
    chmod +x ~/bin/LLMChat
    echo "  Installed pre-compiled LLMChat"
elif [ -f "${SCRIPTS_SRC}/LLMChat.swift" ]; then
    cp "${SCRIPTS_SRC}/LLMChat.swift" ~/bin/
    if swiftc -o ~/bin/LLMChat ~/bin/LLMChat.swift -framework Cocoa 2>/dev/null; then
        echo "  Compiled LLMChat successfully"
    else
        echo "  WARNING: Could not compile LLMChat. Chat will use Terminal fallback."
    fi
fi

# Popup app (PopDraft)
if [ -f "${SCRIPTS_SRC}/PopDraft" ]; then
    cp "${SCRIPTS_SRC}/PopDraft" ~/bin/
    chmod +x ~/bin/PopDraft
    echo "  Installed pre-compiled PopDraft"
elif [ -f "${SCRIPTS_SRC}/PopDraft.swift" ]; then
    cp "${SCRIPTS_SRC}/PopDraft.swift" ~/bin/
    if swiftc -O -o ~/bin/PopDraft ~/bin/PopDraft.swift -framework Cocoa -framework Carbon 2>/dev/null; then
        echo "  Compiled PopDraft successfully"
    else
        echo "  WARNING: Could not compile PopDraft"
    fi
fi

# Setup popup app auto-start
if [ -f ~/bin/PopDraft ]; then
    cat > ~/Library/LaunchAgents/com.popdraft.app.plist << 'LAUNCHPLIST'
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
LAUNCHPLIST
    sed -i '' "s|HOME_DIR|$HOME|g" ~/Library/LaunchAgents/com.popdraft.app.plist
    launchctl unload ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    launchctl load ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    echo "  PopDraft app set to auto-start"
fi

# Add ~/bin to PATH if not already there
echo ""
echo "Configuring PATH..."
SHELL_RC=""
if [ -f ~/.zshrc ]; then
    SHELL_RC=~/.zshrc
elif [ -f ~/.bashrc ]; then
    SHELL_RC=~/.bashrc
fi

if [ -n "$SHELL_RC" ]; then
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$SHELL_RC" 2>/dev/null; then
        echo '' >> "$SHELL_RC"
        echo '# PopDraft tools' >> "$SHELL_RC"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
        echo "  Added ~/bin to PATH in $SHELL_RC"
    else
        echo "  PATH already configured"
    fi
fi

# Export PATH for current session
export PATH="$HOME/bin:$PATH"

# Setup Automator workflows
echo ""
echo "Creating keyboard shortcuts..."
if [ -f ~/bin/setup-workflows.sh ]; then
    bash ~/bin/setup-workflows.sh
else
    echo "  WARNING: Could not find setup-workflows.sh"
fi

echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""
echo "POPUP MENU (Recommended):"
echo "  Option+Space -> Show action popup"
echo "  Look for the sparkles icon in menu bar"
echo ""
echo "KEYBOARD SHORTCUTS (Ctrl+Option+...):"
echo "  G - Grammar Check"
echo "  A - Articulate"
echo "  C - Craft Answer"
echo "  P - Custom Prompt"
echo "  L - Chat"
echo "  S - Speak (TTS)"
echo ""
echo "Usage: Copy text (Cmd+C), then press Option+Space"
echo ""
echo "To uninstall, run: ~/bin/uninstall.sh"
echo ""
INSTALLER

chmod +x "${APP_BUNDLE}/Contents/Resources/install.sh"

# Copy uninstall script
cp "${SCRIPT_DIR}/uninstall.sh" "${APP_BUNDLE}/Contents/Resources/"

# Create app icon (simple text-based icns placeholder)
# For a real icon, you'd use iconutil with proper .iconset
echo "Creating app icon..."
create_icon() {
    local ICONSET="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "${ICONSET}"

    # Create a simple icon using sips (built-in macOS tool)
    # We'll create a colored square with text overlay using Python
    python3 << 'PYICON'
import os
import subprocess

# Create a simple PNG icon using built-in tools
# This creates a basic gradient icon
iconset_dir = os.environ.get('ICONSET_DIR', 'build/AppIcon.iconset')
os.makedirs(iconset_dir, exist_ok=True)

# Sizes needed for iconset
sizes = [16, 32, 64, 128, 256, 512]

for size in sizes:
    # Create icon using sips from a colored image
    # Since we can't easily create complex graphics, we'll skip this
    # and just create placeholder files
    pass
PYICON

    # Alternative: Copy existing icon or skip icon creation
    echo "  (Icon creation skipped - using default)"
}

# Try to create icon, but don't fail if it doesn't work
create_icon 2>/dev/null || true

# Create a symbolic link to Applications folder in DMG
echo "Creating Applications symlink..."
ln -s /Applications "${DMG_DIR}/Applications"

# Create README for the DMG
cat > "${DMG_DIR}/README.txt" << 'README'
PopDraft - System-wide AI Text Processing for macOS

INSTALLATION:
1. Double-click "PopDraft.app" to run the installer
2. Follow the prompts in Terminal
3. Grant Accessibility permissions when prompted

REQUIREMENTS:
- macOS 13 (Ventura) or later
- Ollama running at localhost:11434
- Python 3.10+

KEYBOARD SHORTCUTS (after installation):
- Ctrl+Option+G : Grammar Check
- Ctrl+Option+A : Articulate
- Ctrl+Option+C : Craft Answer
- Ctrl+Option+P : Custom Prompt
- Ctrl+Option+L : Chat
- Ctrl+Option+S : Speak (TTS)

UNINSTALL:
Run ~/bin/uninstall.sh in Terminal

For more information, see README.md inside the app bundle.
README

# Create the DMG
echo ""
echo "Creating DMG..."
DMG_TEMP="${BUILD_DIR}/${DMG_NAME}-temp.dmg"
DMG_FINAL="${BUILD_DIR}/${DMG_NAME}.dmg"

# Create temporary DMG
hdiutil create -srcfolder "${DMG_DIR}" -volname "${APP_NAME}" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW "${DMG_TEMP}"

# Mount it
MOUNT_DIR="/Volumes/${APP_NAME}"
hdiutil attach "${DMG_TEMP}" -mountpoint "${MOUNT_DIR}"

# Set custom icon positions using AppleScript (optional visual layout)
osascript << EOF
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 900, 450}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 72
        set position of item "${APP_NAME}.app" of container window to {125, 170}
        set position of item "Applications" of container window to {375, 170}
        set position of item "README.txt" of container window to {250, 300}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

# Sync and unmount
sync
hdiutil detach "${MOUNT_DIR}"

# Convert to compressed DMG
hdiutil convert "${DMG_TEMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FINAL}"

# Clean up temp DMG
rm -f "${DMG_TEMP}"

echo ""
echo "=========================================="
echo "  DMG Build Complete!"
echo "=========================================="
echo ""
echo "Output: ${DMG_FINAL}"
echo "Size: $(du -h "${DMG_FINAL}" | cut -f1)"
echo ""
echo "To test: open '${DMG_FINAL}'"
