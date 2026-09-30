#!/usr/bin/env bash
#
# 构建 Marquee.app
#
# ⚠️ 前置条件（一次性，见 docs/DEV-NOTES.md 第 4 节）
#
# xcodebuild 解析本地 SPM 包时会应用 **deny-default** 形态的沙箱，
# 而当前宿主环境无法应用该形态的沙箱（`sandbox_apply: Operation not permitted`）。
# 这不是网络问题，`proxy_on` 无效；本地路径包不联网。
# 因此需要打开 Xcode 的 manifest 求值沙箱开关：
#
#   defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
#   # 回退:
#   defaults delete com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox
#
# 本脚本不会自动修改你的全局设置，只会在缺失时报错并提示。

set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
  echo "✗ 缺少必需的 Xcode 设置，构建无法进行。请先执行（一次性，可回退）：" >&2
  echo "" >&2
  echo "    defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES" >&2
  echo "" >&2
  echo "  原因见 docs/DEV-NOTES.md 第 4 节。" >&2
  exit 1
fi

xcodegen generate
xcodebuild \
  -project Marquee.xcodeproj \
  -scheme Marquee \
  -configuration "${CONFIGURATION:-Debug}" \
  -destination 'platform=macOS' \
  build

# ── 稳定签名：让「屏幕录制」授权跨构建保留 ──────────────────────────────
#
# 背景（已实测，见 docs/DEV-NOTES.md 第 1 节）：
# TCC 按「bundle id + 代码签名身份」记账。ad-hoc 签名（CODE_SIGN_IDENTITY = "-"）
# 没有稳定身份，系统只能退回按 cdhash 记账 —— 而每次重新构建 cdhash 都会变，
# 于是 macOS 把新构建当成一个**新应用**，每次都重新弹屏幕录制权限、之前的勾选也失效。
#
# 用证书重签一次后身份就稳定了，授权跨构建保留。
# 代价：从 ad-hoc 换成证书的**第一次**仍会再弹一次（身份变了），之后不该再弹。
#
# 覆盖方式：MARQUEE_SIGN_IDENTITY="..." ./scripts/build.sh
# 跳过：    MARQUEE_SKIP_RESIGN=1 ./scripts/build.sh
SIGN_IDENTITY="${MARQUEE_SIGN_IDENTITY:-Apple Development: zhenzhi Tang (7H6TJ2PN25)}"

if [ "${MARQUEE_SKIP_RESIGN:-0}" = "1" ]; then
  echo "⏭  跳过重签（MARQUEE_SKIP_RESIGN=1）：本次构建仍是 ad-hoc，权限会需要重新授权"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  APP_PATH=$(xcodebuild \
      -project Marquee.xcodeproj \
      -scheme Marquee \
      -configuration "${CONFIGURATION:-Debug}" \
      -destination 'platform=macOS' \
      -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{dir=$2} / FULL_PRODUCT_NAME = /{name=$2} END{if (dir != "" && name != "") print dir "/" name}')

  if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier dev.tango.Marquee "$APP_PATH"
    echo "✓ 已用稳定身份重签：$SIGN_IDENTITY"
    echo "  → 屏幕录制授权现在跨构建保留（从 ad-hoc 换过来的第一次仍需授权一次）"
  else
    echo "✗ 没能定位构建产物，跳过重签（权限可能需要重新授权）" >&2
  fi
else
  echo "⚠️  未找到签名身份：$SIGN_IDENTITY" >&2
  echo "   本次构建保持 ad-hoc —— 每次重新构建都要重新授权屏幕录制。" >&2
  echo "   查看可用身份：security find-identity -v -p codesigning" >&2
fi
