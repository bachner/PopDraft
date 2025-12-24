#!/bin/bash
# Build DMG for PopDraft
# Creates a drag-to-install app bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-1.0.0}"
APP_NAME="PopDraft"
DMG_NAME="PopDraft-${VERSION}"
BUILD_DIR="${SCRIPT_DIR}/build"
DMG_DIR="${BUILD_DIR}/dmg"
APP_BUNDLE="${DMG_DIR}/${APP_NAME}.app"

echo "Building PopDraft DMG v${VERSION}..."
echo ""

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${DMG_DIR}"

# Create app bundle structure
echo "Creating application bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Compile PopDraft
echo "Compiling PopDraft..."
swiftc -O -o "${APP_BUNDLE}/Contents/MacOS/PopDraft" \
    "${SCRIPT_DIR}/scripts/PopDraft.swift" \
    -framework Cocoa -framework Carbon

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to compile PopDraft"
    exit 1
fi
echo "  [OK] PopDraft compiled"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PopDraft</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.popdraft.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PopDraft</string>
    <key>CFBundleDisplayName</key>
    <string>PopDraft</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>PopDraft needs to send keystrokes to capture selected text and paste results.</string>
</dict>
</plist>
EOF

# Copy TTS server to Resources
echo "Copying resources..."
cp "${SCRIPT_DIR}/scripts/llm-tts-server.py" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/install.sh" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/uninstall.sh" "${APP_BUNDLE}/Contents/Resources/"
cp "${SCRIPT_DIR}/README.md" "${APP_BUNDLE}/Contents/Resources/"

echo "  [OK] Resources copied"

# Create Applications symlink
ln -s /Applications "${DMG_DIR}/Applications"

# Create the DMG
echo ""
echo "Creating DMG..."
DMG_TEMP="${BUILD_DIR}/${DMG_NAME}-temp.dmg"
DMG_FINAL="${BUILD_DIR}/${DMG_NAME}.dmg"

# Create temporary DMG
hdiutil create -srcfolder "${DMG_DIR}" -volname "${APP_NAME}" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW "${DMG_TEMP}"

# Mount temporarily for layout (optional, may fail silently)
MOUNT_DIR="/Volumes/PopDraft_build_$$"
if hdiutil attach "${DMG_TEMP}" -mountpoint "${MOUNT_DIR}" 2>/dev/null; then
    # Try to set window layout (best effort)
    osascript << EOF 2>/dev/null || true
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 850, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 80
        set position of item "${APP_NAME}.app" of container window to {120, 140}
        set position of item "Applications" of container window to {330, 140}
        close
        update without registering applications
        delay 1
    end tell
end tell
EOF
    sync
    hdiutil detach "${MOUNT_DIR}" 2>/dev/null || hdiutil detach "${MOUNT_DIR}" -force
fi

# Convert to compressed DMG
hdiutil convert "${DMG_TEMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FINAL}"

# Clean up
rm -f "${DMG_TEMP}"

echo ""
echo "==========================================="
echo "[OK] DMG Build Complete!"
echo "==========================================="
echo ""
echo "Output: ${DMG_FINAL}"
echo "Size: $(du -h "${DMG_FINAL}" | cut -f1)"
echo ""
echo "To test: open '${DMG_FINAL}'"
echo ""
