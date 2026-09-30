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

# ⚠️ 已知环境限制：**被外部沙箱包裹的 shell 里，这个脚本跑不过去**。
#
# 症状（出现在 `MarqueeEditor/AnnotationEditorWindow.swift`）：
#
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
#   for macro 'State()'; '.../swift-plugin-server' produced malformed response
#
# 根因不是代码，也不是 PATH：`swift-plugin-server` 启动时会**自己再套一层沙箱**
# （`sandbox_apply()`），外层沙箱不放行就会被直接杀掉（实测该进程在本 shell 里
# 退出码 137 / SIGKILL，`--version` 都打不出任何东西）。这是嵌套沙箱问题。
#
# 判断是不是这个原因：`./scripts/test.sh` 走 SwiftPM，**同一条代码路径能过** ——
# 因为它按 `--disable-sandbox` 拉起插件。所以只要 SwiftPM 能编、xcodebuild 不能，
# 就说明是宿主沙箱在挡，别去改代码。
#
# 正常终端 / Xcode / 本机 shell 下这个脚本是好的。
# 官方给 xcodebuild 的对应参数是
#   -IDEPackageSupportDisableManifestSandbox=1
#   -IDEPackageSupportDisablePluginExecutionSandbox=1
#   ENABLE_USER_SCRIPT_SANDBOXING=NO
# 它们对**外层**沙箱无效（外层的 apply 本身就被拒），因此这里不加 ——
# 加了会让人误以为脚本能自愈。

if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
  echo "✗ 缺少必需的 Xcode 设置，构建无法进行。请先执行（一次性，可回退）：" >&2
  echo "" >&2
  echo "    defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES" >&2
  echo "" >&2
  echo "  原因见 docs/DEV-NOTES.md 第 4 节。" >&2
  exit 1
fi

xcodegen generate

# ── 产物路径固定到工程目录下 ────────────────────────────────────────────
#
# 默认的 ~/Library/Developer/Xcode/DerivedData/<工程名>-<路径哈希> 有两个问题：
#   1. 路径里带哈希，你没法凭直觉找到 app
#   2. 工程目录改名（本项目 Snipo → Marquee）会**再生成一份**，旧的那份还留着 ——
#      很容易跑到旧的 ad-hoc 产物上，然后怀疑"为什么权限不对"
#
# `-derivedDataPath` 显式钉死路径。注意 `xcodebuild` **不认** workspace 里的
# DerivedDataLocationStyle 设置（实测：指定 workspace 后它又换了个哈希目录），
# 所以必须在这里显式给。
#
# GUI 那边（File → Workspace Settings → Derived Data → Workspace-relative）
# 由 `Marquee.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` 提供。
# 覆盖 CLI 路径：MARQUEE_DERIVED_DATA=/some/path ./scripts/build.sh
DERIVED_DATA="${MARQUEE_DERIVED_DATA:-$PWD/DerivedData}"

xcodebuild \
  -workspace Marquee.xcworkspace \
  -scheme Marquee \
  -configuration "${CONFIGURATION:-Debug}" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

# ── 签名核验：稳定身份 = 「屏幕录制」授权能留住的前提 ──────────────────
#
# 背景（已实测，见 docs/DEV-NOTES.md 第 1 节）：
# TCC 按「bundle id + 代码签名身份」记账。ad-hoc 签名没有身份，系统只能退回按 cdhash 记账，
# 而每次重新构建 cdhash 都会变 —— 于是 macOS 把每次构建都当成**新应用**，
# 屏幕录制权限反复索要、勾过的也留不住。
#
# 签名本身必须由**工程**负责（project.yml 的 CODE_SIGN_IDENTITY + DEVELOPMENT_TEAM），
# 这样从 Xcode 里直接 Run 也是对的 —— 开发时走 Xcode Run 才是常态，
# 把修复只放在这个脚本里等于没修（2026-09-30 踩过这个坑）。
# 这一段只做两件事：**核验**结果，以及发现退回 ad-hoc 时给出可执行的补救。
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION:-Debug}/Marquee.app"

if [ ! -d "$APP_PATH" ]; then
  echo "✗ 没能定位构建产物：$APP_PATH" >&2
elif codesign -dvvv "$APP_PATH" 2>&1 | grep -q "adhoc"; then
  echo "⚠️  产物是 **ad-hoc** 签名 —— macOS 会把每次构建当成新应用，屏幕录制权限会反复索要。" >&2
  echo "   检查 project.yml 的 CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM 是否被改回 \"-\"。" >&2
  if [ -n "${MARQUEE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$MARQUEE_SIGN_IDENTITY" --identifier dev.tango.Marquee "$APP_PATH"
    echo "✓ 已按 MARQUEE_SIGN_IDENTITY 强制重签：$MARQUEE_SIGN_IDENTITY" >&2
  else
    echo "   临时补救：MARQUEE_SIGN_IDENTITY=\"<证书名>\" ./scripts/build.sh" >&2
    echo "   可用证书：security find-identity -v -p codesigning" >&2
  fi
else
  IDENTITY=$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'=' '/^Authority=/{print $2; exit}')
  TEAM=$(codesign -dvvv "$APP_PATH" 2>&1 | awk -F'=' '/^TeamIdentifier=/{print $2; exit}')
  # 注意：`${IDENTITY}` 的大括号不能省。中文文案里紧跟在变量后面的全角字符会被 shell
  # 当成变量名的一部分，于是 `set -u` 直接报 "unbound variable"。
  echo "✓ 签名身份稳定：${IDENTITY} (team ${TEAM})"
  echo "  产物：${APP_PATH}"
fi
