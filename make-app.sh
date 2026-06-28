#!/usr/bin/env bash
# Build Mai and assemble a minimal, TCC-capable Mai.app so it can receive Screen
# Recording and Microphone permissions (a bare `swift run` binary cannot hold them).
# Command Line Tools are enough (no Xcode).
#
#   ./make-app.sh                    # ad-hoc signature (grant resets on each rebuild)
#   SIGN_ID="Mai Dev" ./make-app.sh  # a self-signed cert named "Mai Dev" -> grant persists
#
# To create the self-signed cert once: Keychain Access, Certificate Assistant,
# Create a Certificate, name "Mai Dev", type Code Signing, Self Signed Root.
set -euo pipefail

APP_NAME="Mai"
BUNDLE_ID="com.mai.app"     # stable: part of the TCC identity, keep it constant
VERSION="0.2"
BUILD="2"
MIN_OS="15.0"              # SCStreamConfiguration.captureMicrophone is macOS 15+

# Signing identity. A stable cert makes the Screen Recording / Microphone grants
# PERSIST across rebuilds; ad-hoc grants reset every rebuild because the code hash
# changes, which leaves a stale "on" entry in System Settings that no longer matches.
# If SIGN_ID is unset, auto-use a self-signed code-signing cert named "Mai Dev" when
# present, else fall back to ad-hoc.
if [ -z "${SIGN_ID:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Mai Dev"; then
        SIGN_ID="Mai Dev"
    else
        SIGN_ID="-"
    fi
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"

echo "Building ${APP_NAME} (release)..."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN" "$MACOS/${APP_NAME}"
# Copy SwiftPM resource bundles (e.g. Mai_MaiCore.bundle holding the prompt
# templates) next to the executable so Bundle.module resolves inside the app.
cp -R "$(dirname "$BIN")"/*.bundle "$MACOS"/ 2>/dev/null || true

# Info.plist is written before signing (signing seals it).
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>           <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>           <string>${APP_NAME}</string>
    <key>CFBundleName</key>                 <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
    <key>CFBundleVersion</key>              <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>       <string>${MIN_OS}</string>
    <key>NSMicrophoneUsageDescription</key> <string>Mai uses the microphone to transcribe your speech in real time during meetings.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# No --deep (single binary), no --options runtime and no entitlements: a
# non-sandboxed local app reaches mic + screen through TCC alone. Hardened runtime
# would instead require the audio-input entitlement.
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --verbose=2 "$APP" || true

SIGN_DESC="ad-hoc (grants reset on each rebuild)"
[ "$SIGN_ID" != "-" ] && SIGN_DESC="\"$SIGN_ID\" (grants persist across rebuilds)"

cat <<EOF

Built ${APP}
Signed: ${SIGN_DESC}
Run it:  open "${APP}"
Then grant Screen Recording and Microphone when prompted (or in System Settings,
Privacy and Security, Screen and System Audio Recording / Microphone), and relaunch.

If it keeps asking even though Settings shows the grant, the ad-hoc signature
changed on rebuild and the old grant is stale. Fix it once:
  1. Create a self-signed code-signing certificate named "Mai Dev" in Keychain
     Access (Certificate Assistant, Create a Certificate, Self Signed Root, Code
     Signing). make-app.sh then uses it automatically and grants persist.
  2. Clear the stale grants:
       tccutil reset ScreenCapture ${BUNDLE_ID}
       tccutil reset Microphone ${BUNDLE_ID}
  3. ./make-app.sh, open Mai.app, grant once, relaunch.
EOF
