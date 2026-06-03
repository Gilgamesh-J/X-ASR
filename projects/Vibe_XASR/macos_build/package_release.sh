#!/bin/bash
# One-command release: build -> Developer-ID sign (hardened runtime) -> notarize -> staple -> .dmg -> notarize dmg -> staple.
# Usage: ./package_release.sh           (full release: sign + notarize + dmg)
#        ./package_release.sh dev        (build + sign only, no notarize — fast dev loop)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
ID="${SIGN_ID:-Developer ID Application: Your Name (TEAMID)}"
APP="native/dist/Vibe XASR.app"
ENT="native/app/Resources/VibeIME.entitlements"
PROFILE="vibeime"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "native/app/Resources/Info.plist" 2>/dev/null || echo 0.2.0)"
DMG="native/dist/VibeXASR-${VER}.dmg"

echo "== 1/5 build =="
( cd native/app && ./build_app.sh ) 2>&1 | grep -iE "Build complete|error:" | grep -v "error: &err" | tail -3
[ -d "$APP" ] || { echo "❌ 没有产出 $APP"; exit 1; }

echo "== 2/5 sign (frameworks first, then app, hardened runtime + entitlements) =="
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -name "*.dylib" -print0 | while IFS= read -r -d '' dy; do
    codesign --force --options runtime --timestamp -s "$ID" "$dy" >/dev/null
  done
fi
# Sparkle.framework: re-sign nested helpers + framework with Developer ID (hardened
# runtime + secure timestamp) so the whole thing notarizes.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  codesign --force --options runtime --timestamp -s "$ID" "$SPK/Versions/B/Updater.app"
  codesign --force --options runtime --timestamp -s "$ID" "$SPK/Versions/B/Autoupdate"
  codesign --force --options runtime --timestamp -s "$ID" "$SPK"
fi
codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2 || true

if [ "$MODE" = "dev" ]; then
  echo "== dev 模式:跳过公证,直接装机 =="
  pkill -f "MacOS/VibeIME" 2>/dev/null || true; sleep 1
  rm -rf "/Applications/Vibe XASR.app"; cp -R "$APP" /Applications/
  open -a "/Applications/Vibe XASR.app"; sleep 2
  pgrep -fl "MacOS/VibeIME" >/dev/null && echo "运行中 ✓" || echo "未运行 ✗"
  exit 0
fi

echo "== 3/5 notarize app =="
ZIP="native/dist/VibeXASR-${VER}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "== 4/5 build dmg =="
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Vibe XASR" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$ID" "$DMG"

echo "== 5/5 notarize dmg =="
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "✅ 公证已装订: $DMG"
echo "完成: $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")  (v$VER)"

echo "== 附:Sparkle 更新包 + appcast =="
# Sparkle in-place update payload = a zip of the STAPLED app (notarization ticket
# travels inside, so Gatekeeper passes after extraction). appcast.xml (small) is
# served from GitHub Pages (docs/); the zip itself is a GitHub Releases asset.
SPARKLE_BIN="native/third_party/sparkle/bin"
DOCS="../docs"
UPDATE_ZIP="native/dist/VibeXASR-${VER}.zip"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "native/app/Resources/Info.plist" 2>/dev/null || echo 1)"
if [ -x "$SPARKLE_BIN/sign_update" ]; then
  rm -f "$UPDATE_ZIP"
  ditto -c -k --keepParent "$APP" "$UPDATE_ZIP"
  SIG_LINE="$("$SPARKLE_BIN/sign_update" "$UPDATE_ZIP")"   # sparkle:edSignature="…" length="…"
  PUBDATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
  DL_URL="https://github.com/liutaocode/Vibe_XASR/releases/download/v${VER}/VibeXASR-${VER}.zip"
  mkdir -p "$DOCS"
  cat > "$DOCS/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Vibe XASR</title>
    <link>https://liutaocode.github.io/Vibe_XASR/appcast.xml</link>
    <description>Vibe XASR 自动更新源 / auto-update feed</description>
    <language>zh</language>
    <item>
      <title>Vibe XASR ${VER}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VER}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <link>https://github.com/liutaocode/Vibe_XASR/releases/tag/v${VER}</link>
      <enclosure url="${DL_URL}" type="application/octet-stream" ${SIG_LINE} />
    </item>
  </channel>
</rss>
XML
  echo "✅ 写入 $DOCS/appcast.xml  (enclosure → $DL_URL)"
  echo
  echo "发布这次更新,还差两步(都是对外操作,确认后执行):"
  echo "  1) 把 dmg + 更新 zip 传到 Release:"
  echo "     gh release create v${VER} \"$DMG\" \"$UPDATE_ZIP\" -R liutaocode/Vibe_XASR -t \"Vibe XASR v${VER}\" --notes \"…\""
  echo "  2) 提交并推送 docs/appcast.xml(GitHub Pages 刷新后,旧版 App 即可检测到新版)"
else
  echo "   跳过:未找到 $SPARKLE_BIN/sign_update"
fi
