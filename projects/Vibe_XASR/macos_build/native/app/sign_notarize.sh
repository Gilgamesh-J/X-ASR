#!/bin/sh
set -e
# Sign (Developer ID) + notarize + staple + build .dmg for "Vibe XASR.app".
#
# ONE-TIME setup (creates a notarytool keychain profile from an app-specific
# password generated at appleid.apple.com → Sign-In and Security → App-Specific
# Passwords):
#   xcrun notarytool store-credentials vibeime \
#     --apple-id "<your-apple-id-email>" --team-id TEAMID --password "<app-specific-password>"
#
# Usage: ./sign_notarize.sh [path-to-.app]
cd "$(dirname "$0")"
APP="${1:-../dist/Vibe XASR.app}"
ID="Developer ID Application: Your Name (TEAMID)"
ENT="Resources/VibeIME.entitlements"
PROFILE="vibeime"
OUTDIR="$(dirname "$APP")"
DMG="$OUTDIR/VibeIME-0.1.0.dmg"

echo ">>> 1) sign nested dylibs / frameworks (inside-out)"
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) | while read -r f; do
    codesign --force --options runtime --timestamp -s "$ID" "$f"
  done
  find "$APP/Contents/Frameworks" -type d -name "*.framework" | while read -r fw; do
    codesign --force --options runtime --timestamp -s "$ID" "$fw"
  done
fi

echo ">>> 2) sign the app (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ">>> 3) notarize (submit + wait)"
ZIP="$OUTDIR/_notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"
spctl -a -vvv --type execute "$APP" || true

echo ">>> 4) build .dmg"
rm -f "$DMG"
hdiutil create -volname "Vibe XASR" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "→ $DMG  (signed, notarized, stapled)"
