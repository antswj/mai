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
SIGN_ID="${SIGN_ID:--}"   # "-" is ad-hoc

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
    <key>NSMicrophoneUsageDescription</key> <string>Mai transcribes your microphone while it is listening.</string>
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

cat <<EOF

Built ${APP}
Run it:  open "${APP}"
Then grant Screen Recording and Microphone when prompted (or in System Settings,
Privacy and Security), and relaunch. Ad-hoc grants reset on each rebuild; use a
self-signed cert (SIGN_ID="Mai Dev") to make them persist.
EOF
