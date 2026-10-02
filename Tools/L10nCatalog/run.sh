#!/usr/bin/env bash
#
# 文案目录（Localizable.xcstrings）的生成器。
#
#   ./run.sh          # 只报告：源码里有哪些 key、翻译表有没有缺/多（**不写文件**）
#   ./run.sh write    # 真的重写 App/Resources/Localizable.xcstrings
#
# ⚠️ 这个脚本是**唯一能生成** catalog 的工具；`LocalizationScanTests` 只能校验。
# 所以它必须留在仓库里 —— 它一度只存在于 `/tmp`，丢了就是 187 条翻译的返工。
#
# ⚠️ 不要用 Xcode 的「Extract Strings」代替它：字面量在 SPM 模块里、catalog 挂在
# App target 下，而 Xcode 的抽取是**按 target** 做的 —— 它会把 187 条全标成 stale
# 并删除其中的一部分。见 docs/PITFALLS.md 116。
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
py="${L10N_PYTHON:-/usr/bin/python3}"
exec "$py" "$here/build_catalog.py" "${@:-keys}"
