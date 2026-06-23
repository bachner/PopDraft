#!/bin/bash
# Regenerate resources/AppIcon.icns from the generated brand orb PNG.
#
# Usage:
#   ./scripts/make-app-icon.sh [SOURCE_PNG] [OUTPUT_ICNS]
#
# Defaults:
#   SOURCE_PNG  = design-mocks/assets/popdraft-app-icon.png
#   OUTPUT_ICNS = resources/AppIcon.icns
#
# Requires the macOS `sips` and `iconutil` tools.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PNG="${1:-${SCRIPT_DIR}/design-mocks/assets/popdraft-app-icon.png}"
OUTPUT_ICNS="${2:-${SCRIPT_DIR}/resources/AppIcon.icns}"

if ! command -v sips >/dev/null 2>&1; then
    echo "[ERROR] sips not found (macOS only)" >&2
    exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
    echo "[ERROR] iconutil not found (macOS only)" >&2
    exit 1
fi
if [ ! -f "$SOURCE_PNG" ]; then
    echo "[ERROR] Source PNG not found: $SOURCE_PNG" >&2
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "Generating iconset from: $SOURCE_PNG"

# size@1x  -> filename
gen() {
    local px="$1"
    local name="$2"
    sips -z "$px" "$px" "$SOURCE_PNG" --out "$ICONSET/$name" >/dev/null
}

gen 16   "icon_16x16.png"
gen 32   "icon_16x16@2x.png"
gen 32   "icon_32x32.png"
gen 64   "icon_32x32@2x.png"
gen 128  "icon_128x128.png"
gen 256  "icon_128x128@2x.png"
gen 256  "icon_256x256.png"
gen 512  "icon_256x256@2x.png"
gen 512  "icon_512x512.png"
gen 1024 "icon_512x512@2x.png"

echo "Building .icns: $OUTPUT_ICNS"
mkdir -p "$(dirname "$OUTPUT_ICNS")"
iconutil -c icns "$ICONSET" -o "$OUTPUT_ICNS"

rm -rf "$(dirname "$ICONSET")"

echo "[OK] Wrote $OUTPUT_ICNS"
file "$OUTPUT_ICNS"
