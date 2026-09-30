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
