#!/usr/bin/env bash
#
# 图标生成器。与 Tools/ 下其他工具一样：独立 swiftc 编译，不进产品工程。
#
#   ./run.sh                    渲染三个方案的预览
#   ./run.sh install dark       把 dark 装成 AppIcon（写进 App/Assets.xcassets）
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# 工具里的路径（`App/Assets.xcassets`、`Tools/IconGen/preview`）都是**相对仓库根**的，
# 所以编译完要回到根目录再跑 —— 否则会写出一层 `Tools/IconGen/Tools/IconGen/`。
cd "$here/../.."
swiftc -O -o "$here/.build-icon" "$here/main.swift"
"$here/.build-icon" "$@"
