#!/usr/bin/env bash
#
# install.sh —— 把本目录下的项目级技能挂到**用户级**技能目录。
#
#   bash .workbuddy/skills/install.sh
#
# 为什么需要它
# ------------
# WorkBuddy 的「项目级技能」只在这个工作区里生效。想在**其它项目**里也用上
# 同样这两个 build 技能，就得让它们出现在用户级目录。
#
# 这里用**符号链接**而不是拷贝：
#   · 实体只有一份，就在本目录（随仓库走）⇒ 永远不会出现"改了这份忘了那份"；
#   · 链接落在 ~/.workbuddy/skills/，不在仓库里，所以每台设备各建一次即可。
#
# WorkBuddy 的技能扫描**跟随符号链接**（2026-10-03 实测：8 秒内被收录），
# 所以挂上去就能被正常识别，无需重启。
#
# 换新设备：clone 仓库 → 跑这个脚本 → 两个技能在本机所有项目可用。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${WORKBUDDY_SKILLS_DIR:-$HOME/.workbuddy/skills}"
SKILLS="ios-build-test macos-build-test"

mkdir -p "$DEST"

for s in $SKILLS; do
  src="$HERE/$s"
  dst="$DEST/$s"

  if [ ! -d "$src" ]; then
    echo "跳过（源不存在）：$s"
    continue
  fi

  if [ -L "$dst" ]; then
    ln -sfn "$src" "$dst"
    echo "已更新链接：$dst"
  elif [ -e "$dst" ]; then
    echo "已存在实体，未改动：$dst"
    echo "  若确认要以本仓库为准，先移走那个目录再重跑本脚本。"
  else
    ln -s "$src" "$dst"
    echo "已建立链接：$dst"
  fi
done

echo
echo "完成。WorkBuddy 会重新扫描技能；若没生效，重启客户端即可。"
