#!/usr/bin/env bash
# Build, sign, and package Mai as a distributable .dmg.
#
#   ./release.sh
#
# This produces Mai.dmg containing the Developer-ID-signed, hardened-runtime Mai.app.
# It opens cleanly on YOUR Mac. To hand it to someone else without a Gatekeeper
# warning, notarize it first with ./notarize.sh (a separate, deliberate step that
# needs your Apple ID app-specific password). Command Line Tools are enough.
set -euo pipefail

APP_NAME="Mai"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/${APP_NAME}.app"
DMG="${ROOT}/${APP_NAME}.dmg"

# 1. Build + sign the app (Developer ID, hardened runtime, entitlements).
"${ROOT}/make-app.sh"

# Reuse the same signing identity make-app.sh chose.
if [ -z "${SIGN_ID:-}" ]; then
    ALL_IDS="$(security find-identity -p codesigning 2>/dev/null)"
    if echo "$ALL_IDS" | grep -q "Developer ID Application"; then
        SIGN_ID="$(echo "$ALL_IDS" | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    else
        SIGN_ID="-"
    fi
fi

echo "Packaging ${APP_NAME}.dmg..."
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"        # drag-to-install layout
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 2. Sign the dmg too, so Gatekeeper has a signature to check.
codesign --force --sign "$SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG" || true

cat <<EOF

Built ${DMG}
Signed with: ${SIGN_ID}

This opens cleanly on YOUR Mac. On someone else's Mac it will show a Gatekeeper
warning until it is notarized. When you are ready to share it, run:

  ./notarize.sh

which notarizes and staples the app and the dmg (you provide a one-time Apple ID
app-specific password). See README.md, section "Shipping Mai".
EOF
