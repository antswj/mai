#!/usr/bin/env bash
# Notarize and staple Mai for distribution to other Macs. RUN THIS ONLY WHEN YOU ARE
# READY TO SHARE Mai. It is a separate, deliberate step from building, because it
# needs your Apple ID and a one-time app-specific password and it talks to Apple's
# notary service.
#
# WHAT NOTARIZATION DOES
#   Apple scans your signed app and issues a "ticket" that says it is known and safe.
#   Stapling attaches that ticket to the app and dmg. With it, the app opens on any
#   Mac with the normal launch dialog instead of a Gatekeeper block. Without it, a
#   Developer-ID-signed app opens fine on YOUR Mac but warns on someone else's.
#
# ONE-TIME SETUP (do this once)
#   1. Make sure two-factor authentication is on for your Apple Account.
#   2. Generate an APP-SPECIFIC PASSWORD (this is NOT your Apple ID password):
#        Sign in at https://account.apple.com -> Sign-In and Security ->
#        App-Specific Passwords -> generate one, and copy it.
#   3. Store your notarization credentials in the keychain (replace the values):
#        xcrun notarytool store-credentials "MaiNotary" \
#          --apple-id "you@example.com" \
#          --team-id "8SEQMXA27L" \
#          --password "the-app-specific-password"
#
# THEN, each time you want to ship:
#   ./release.sh        # builds + signs Mai.app and Mai.dmg
#   ./notarize.sh       # this script: notarizes + staples both
#
# Verify the keychain profile name below matches what you stored.
set -euo pipefail

PROFILE="${MAI_NOTARY_PROFILE:-MaiNotary}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${ROOT}/Mai.app"
DMG="${ROOT}/Mai.dmg"
ZIP="${ROOT}/Mai.zip"

[ -d "$APP" ] || { echo "Mai.app not found. Run ./release.sh first."; exit 1; }

echo "1. Zipping the app for submission (you cannot submit a bare .app)..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "2. Submitting the app to Apple's notary service (this can take a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "3. Stapling the ticket to the app..."
xcrun stapler staple "$APP"
rm -f "$ZIP"

if [ -f "$DMG" ]; then
    echo "4. Rebuilding the dmg with the now-stapled app, then notarizing the dmg..."
    "${ROOT}/release.sh" >/dev/null   # repackage so the dmg holds the stapled app
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    echo "5. Stapling the ticket to the dmg..."
    xcrun stapler staple "$DMG"
fi

echo
echo "Verifying..."
xcrun stapler validate "$APP" || true
spctl -a -vvv "$APP" || true
[ -f "$DMG" ] && xcrun stapler validate "$DMG" || true
[ -f "$DMG" ] && spctl -a -t open -vvv --context context:primary-signature "$DMG" || true

cat <<EOF

Done. If the checks above say "accepted" and "source=Notarized Developer ID", the
dmg now opens on any Mac with no Gatekeeper warning. (On macOS 14+ you can also run
'syspolicy_check distribution Mai.app' as the authoritative Gatekeeper check.)
EOF
