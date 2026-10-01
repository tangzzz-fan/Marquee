#!/usr/bin/env bash
#
# 打一个别人能直接装、双击不被 Gatekeeper 拦下的 Marquee。
#
#   归档 → Developer ID 签名导出 → 公证（notarytool）→ 装订（staple）→ 打成 DMG → 核验
#
# ⚠️ 这个脚本**我（AI）没法在本机端到端跑通**：它需要你的 Developer ID 证书与
#    公证凭据。所以下面每一步都写了"怎么判断它成了"，请在真机跑一次，
#    把输出贴回来我再改 —— 宁可现在多问一句，也不要给你一个看起来能跑、
#    实际在别人机器上被 Gatekeeper 拦下的包。
#
# ── 一次性准备（只需做一次）────────────────────────────────────────────
#
# 1) 确认有 Developer ID Application 证书：
#
#      security find-identity -v -p codesigning | grep "Developer ID Application"
#
#    没有的话去 developer.apple.com → Certificates 建一张，
#    或让 Xcode 在 Accounts 里自动生成（Manage Certificates → + → Developer ID Application）。
#
# 2) 存一份公证凭据（会写进钥匙串，脚本后面按 profile 名引用，**不落明文密码**）：
#
#      xcrun notarytool store-credentials "marquee-notary" \
#        --apple-id "<你的 Apple ID>" --team-id "<TEAMID>" --password "<App 专用密码>"
#
#    App 专用密码在 appleid.apple.com → 登录与安全 → App 专用密码 里生成。
#    ⚠️ 不是你的 Apple ID 登录密码。
#
# 3) 本机 shell 若被外层沙箱包裹，xcodebuild 会编不过 SwiftUI 宏
#    （见 scripts/build.sh 顶部的说明）。在**普通终端**里跑这个脚本。
#
# 用法：
#
#     ./scripts/package.sh                     # 版本取 project.yml 里的值
#     VERSION=0.2.0 ./scripts/package.sh       # 临时指定版本号
#     NOTARY_PROFILE=xxx ./scripts/package.sh  # 换一个公证凭据
#
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Marquee"
APP_NAME="Marquee"
TEAM_ID="${DEVELOPMENT_TEAM:-UKXWZ3FS84}"
NOTARY_PROFILE="${NOTARY_PROFILE:-marquee-notary}"
BUILD_DIR="$PWD/.build-package"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

echo "── 0/7 前置检查 ─────────────────────────────────────────────"

if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
  echo "✗ 缺少必需的 Xcode 设置。先执行：" >&2
  echo "    defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "✗ 找不到 Developer ID Application 证书。见脚本顶部第 1 步。" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ 公证凭据「$NOTARY_PROFILE」不可用。见脚本顶部第 2 步。" >&2
  exit 1
fi

# 版本号：默认取 project.yml 上的（没有就 1.0.0）。
VERSION="${VERSION:-$(awk '/MARKETING_VERSION:/{print $2; exit}' project.yml 2>/dev/null || echo 1.0.0)}"
VERSION="${VERSION:-1.0.0}"
echo "  版本：$VERSION  团队：$TEAM_ID  公证凭据：$NOTARY_PROFILE"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "── 1/7 生成工程 ─────────────────────────────────────────────"
xcodegen generate

echo "── 2/7 归档（Release）───────────────────────────────────────"
xcodebuild \
  -workspace Marquee.xcworkspace \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  MARKETING_VERSION="$VERSION" \
  archive

echo "── 3/7 导出（Developer ID）──────────────────────────────────"
# 用 `-exportOptionsPlist` 而不是直接拿 .app：它会把签名做全
#（含 hardened runtime、时间戳），而"直接拷 .app"经常会漏掉公证要求的那几项。
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ 导出目录里没有 $APP_NAME.app" >&2; exit 1; }

echo "── 4/7 核验签名（公证的前置条件）────────────────────────────"
# `--deep` 已弃用；`--strict` 才是"按发布标准检查"。
# 这一步失败**不要往下走**：公证一定会被拒，而拒信要等好几分钟才回来。
codesign --verify --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority=|^TeamIdentifier=|^Timestamp=" || true

echo "── 5/7 公证 ─────────────────────────────────────────────────"
# 先打 zip：notarytool 收的是压缩包（DMG 也行，但 zip 更快上传、失败时重试成本低）
ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "── 6/7 装订 ─────────────────────────────────────────────────"
# 装订把公证票据**贴进 app 本体**：没这一步的话，用户第一次打开时
# 离线（或 Apple 那边抖动）就会被 Gatekeeper 拦下 —— 而"有的人能打开、有的人不能"
# 是最难查的一类反馈。
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "── 7/7 打包 DMG ─────────────────────────────────────────────"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# 放一个指向 /Applications 的软链：用户拖进去就是安装
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG"
# DMG 自己也要签名 + 公证，否则"下载后打开 dmg"这一步就会被拦。
codesign --force --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

echo
echo "✓ 完成"
echo "  DMG：$DMG"
echo "  大小：$(du -h "$DMG" | cut -f1)"
echo "  最低系统：$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '见 project.yml')"
echo
echo "  发给别人之前，**务必在一台没装开发环境的 Mac 上双击试一次** ——"
echo "  本机上它一定是「过」的（你的钥匙串里有证书），那不构成证据。"
