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
# served via raw.githubusercontent.com from projects/docs/ on main (this IS the app's
# SUFeedURL); the zip itself is a GitHub Releases asset on Gilgamesh-J/X-ASR.
SPARKLE_BIN="native/third_party/sparkle/bin"
DOCS="../../docs"   # = projects/docs/ — the exact path the app's SUFeedURL fetches
UPDATE_ZIP="native/dist/VibeXASR-${VER}.zip"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "native/app/Resources/Info.plist" 2>/dev/null || echo 1)"
if [ -x "$SPARKLE_BIN/sign_update" ]; then
  rm -f "$UPDATE_ZIP"
  ditto -c -k --keepParent "$APP" "$UPDATE_ZIP"
  SIG_LINE="$("$SPARKLE_BIN/sign_update" "$UPDATE_ZIP")"   # sparkle:edSignature="…" length="…"
  PUBDATE="$(date '+%a, %d %b %Y %H:%M:%S %z')"
  # 默认下载源 = R2 CDN(国内快;EdDSA 签名只签字节,换 host 不影响验签)。GitHub Releases 仍留作备份镜像。
  # ?b=<build>:同名文件覆盖后破 Cloudflare 缓存——否则 CDN 边缘可能仍返回旧字节,与新 edSignature 对不上致更新失败。
  DL_URL="https://models.speech.wiki/app/VibeXASR-${VER}.zip?b=${BUILD_NUM}"
  # 更新说明:读 projects/docs/notes-<VER>.html(若有),作为 Sparkle 弹窗里的发行说明。
  NOTES_FILE="$DOCS/notes-${VER}.html"
  NOTES="$( [ -f "$NOTES_FILE" ] && cat "$NOTES_FILE" || printf 'Vibe XASR %s' "$VER" )"
  mkdir -p "$DOCS"
  cat > "$DOCS/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Vibe XASR</title>
    <link>https://models.speech.wiki/appcast.xml</link>
    <description>Vibe XASR 自动更新源 / auto-update feed</description>
    <language>zh</language>
    <item>
      <title>Vibe XASR ${VER}</title>
      <description><![CDATA[
${NOTES}
]]></description>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VER}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Gilgamesh-J/X-ASR/releases/tag/vibe-v${VER}</link>
      <enclosure url="${DL_URL}" type="application/octet-stream" ${SIG_LINE} />
    </item>
  </channel>
</rss>
XML
  echo "✅ 写入 $DOCS/appcast.xml  (enclosure → $DL_URL)"
  echo
  echo "提示:dmg/zip 会自动传到 GitHub Release + R2(见下)。剩下唯一手动步骤:"
  echo "  提交并推送 projects/docs/appcast.xml(push 到 main 后 raw.githubusercontent.com 即刻生效,旧版 App 即可检测到新版)"
else
  echo "   跳过:未找到 $SPARKLE_BIN/sign_update"
fi

echo "== 附:上传安装包到 GitHub Release(公证后自动传,方便分发)=="
# 公证完成的 dmg + zip 自动传到 vibe-v<VER>;GitHub 大文件上传爱静默失败,故每个文件
# 传完用 gh api 核实 state=uploaded、不行就重试。Release 不存在则先建。Windows MSI 不动。
TAG="vibe-v${VER}"
ZIP_OUT="native/dist/VibeXASR-${VER}.zip"
if command -v gh >/dev/null 2>&1; then
  gh release view "$TAG" -R Gilgamesh-J/X-ASR >/dev/null 2>&1 || \
    gh release create "$TAG" -R Gilgamesh-J/X-ASR -t "Vibe XASR v${VER}" --notes "Vibe XASR ${VER}" >/dev/null 2>&1 || true
  for f in "$DMG" "$ZIP_OUT"; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"; ok=""
    for try in 1 2 3; do
      gh release upload "$TAG" "$f" -R Gilgamesh-J/X-ASR --clobber >/dev/null 2>&1 || true
      st="$(gh api repos/Gilgamesh-J/X-ASR/releases/tags/$TAG --jq ".assets[]|select(.name==\"$name\")|.state" 2>/dev/null || true)"
      [ "$st" = "uploaded" ] && { echo "   ✓ $name → GitHub Release $TAG"; ok=1; break; }
      echo "   ⚠️ $name 第 $try 次未坐实,重试…"
    done
    [ -z "$ok" ] && echo "   ❌ $name 传 GitHub 失败 —— 手动: gh release upload $TAG \"$f\" -R Gilgamesh-J/X-ASR --clobber,再 gh api 核实"
  done
else
  echo "   跳过 GitHub 上传(无 gh CLI)"
fi

echo "== 附:同步安装包到 Cloudflare R2 CDN(国内加速)=="
# 每次公证完成的安装包都同步一份到 R2(custom domain models.speech.wiki/app/),
# 作为 GitHub Releases 之外的国内加速下载源。凭据在 projects/scripts/.env(gitignore);
# 没配 .env / 脚本就静默跳过(不影响发布)。
R2UP="../../scripts/r2_upload.sh"
if [ -x "$R2UP" ]; then
  # 安装包设短缓存(600s):同名覆盖发版后,边缘最多 10 分钟内回正(zip 的自动更新另靠 ?b= 破缓存,无延迟)。
  "$R2UP" "$DMG" "app/VibeXASR-${VER}.dmg" "" "public, max-age=600" || echo "   ⚠️ dmg → R2 失败(可稍后手动 r2_upload.sh 重传)"
  ZIP_OUT="native/dist/VibeXASR-${VER}.zip"
  [ -f "$ZIP_OUT" ] && { "$R2UP" "$ZIP_OUT" "app/VibeXASR-${VER}.zip" "" "public, max-age=600" || echo "   ⚠️ zip → R2 失败"; }
  # appcast 也传 R2(SUFeedURL 切 R2 后用);短缓存(120s)确保用户及时看到新版。
  [ -f "$DOCS/appcast.xml" ] && { "$R2UP" "$DOCS/appcast.xml" "appcast.xml" "application/xml" "public, max-age=120" || echo "   ⚠️ appcast → R2 失败"; }
  echo "   CDN: https://models.speech.wiki/app/VibeXASR-${VER}.dmg  (appcast: /appcast.xml)"
else
  echo "   跳过 R2 同步(无 $R2UP)"
fi

# 公证 dmg 复制到桌面,方便手动分发。
cp "$DMG" "$HOME/Desktop/" 2>/dev/null && echo "== dmg 已复制到桌面: ~/Desktop/$(basename "$DMG") =="
