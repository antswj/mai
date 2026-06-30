#!/usr/bin/env bash
# Generate Mai's app icon (Resources/AppIcon.icns) from tools/make-icon.swift.
# Run once (or after changing the design): ./tools/make-icon.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
ICONSET="${TMP}/AppIcon.iconset"
mkdir -p "$ICONSET" "${ROOT}/Resources"

swift "${ROOT}/tools/make-icon.swift" "${TMP}/icon_1024.png"

# Standard macOS iconset sizes (1x and 2x).
for size in 16 32 128 256 512; do
    sips -z $size $size "${TMP}/icon_1024.png" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "${TMP}/icon_1024.png" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "${ROOT}/Resources/AppIcon.icns"
rm -rf "$TMP"
echo "wrote ${ROOT}/Resources/AppIcon.icns"
