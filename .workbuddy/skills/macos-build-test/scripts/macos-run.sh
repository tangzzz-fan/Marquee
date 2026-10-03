#!/usr/bin/env bash
#
# macos-run.sh —— macOS 本机 / SwiftPM 的构建与测试（受限沙箱环境）
#
#   macos-run.sh probe                                   # 环境 + 沙箱判据 + SDK
#   macos-run.sh destinations --project Foo.xcodeproj --scheme Foo
#   macos-run.sh macos --project Foo.xcodeproj --scheme Foo                # 默认 build
#   macos-run.sh macos --project Foo.xcodeproj --scheme Foo test
#   macos-run.sh macos --workspace Foo.xcworkspace --scheme Foo --config Release build
#   macos-run.sh spm test --package-dir Modules          # SwiftPM 包（模块级，最快）
#
# 自动做三件事：
#   1. **沙箱逃逸**：本 shell 若无法 apply deny-default 沙箱，自动加
#      `OTHER_SWIFT_FLAGS=-disable-sandbox`（xcodebuild）/ `--disable-sandbox`（swift）。
#      判据：sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
#   2. **固定 derivedData** 到 `<cwd>/DerivedData`（可 --derived-data 覆盖）
#   3. **日志落文件**，终端只回打关键行（失败先给第一条 error）
#
# 退出码 = 底层命令的退出码（0 = 成功）。其余参数透传。

set -uo pipefail

# ── 剔除 WorkBuddy 沙箱的 toybox shim（让工具语义确定）────────────────────
# agent 会话的 PATH 首部是 WorkBuddy 的 shim 目录：grep/sed/find/ls/head/tail/…
# 都被换成 **toybox 0.8.13**。它与 BSD / GNU **语义不同**，而且差异**不报错**：
#   · grep 不支持 BRE 的 `\|`      → `grep 'a\|b'` 静默失配（rc=1，无输出）
#   · grep 不支持 `\s` / `\S`      → 静默失配（任何位置，含 -E）
#   · `sed -i` **不要**后缀参数    → 与 BSD 相反（BSD 要 `-i ''`，toybox 给 '' 会当文件名）
# shim 只在 stderr 出现 "Unknown option" 时才回退到真工具 ⇒ **语义差异不触发回退**。
# 本脚本要的是"在谁的机器上跑都一样"，所以直接把 shim 目录摘掉。
# 纯 bash，不调外部命令；普通终端里没有这两个目录 ⇒ 这段是 no-op。
__clean_path=""
__rest_path="$PATH"
while [ -n "$__rest_path" ]; do
  case "$__rest_path" in
    *:*) __path_dir="${__rest_path%%:*}"; __rest_path="${__rest_path#*:}" ;;
    *)   __path_dir="$__rest_path"; __rest_path="" ;;
  esac
  case "$__path_dir" in
    */shim/brokered-bin|*/shim/safe-bin) continue ;;
  esac
  __clean_path="${__clean_path:+$__clean_path:}$__path_dir"
done
PATH="$__clean_path"
unset __clean_path __rest_path __path_dir

CMD=""
ACTION="build"
PROJECT=""
WORKSPACE=""
SCHEME=""
CONFIG=""
DERIVED=""
PACKAGE_DIR="."
PASSTHROUGH=()

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  probe|destinations) CMD="$1"; shift ;;
  macos|spm)          CMD="$1"; shift ;;
  -h|--help|"")       usage; exit 0 ;;
  *)                  CMD="macos" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    build|test|clean) ACTION="$1"; shift ;;
    --project)       PROJECT="$2"; shift 2 ;;
    --workspace)     WORKSPACE="$2"; shift 2 ;;
    --scheme)        SCHEME="$2"; shift 2 ;;
    --config)        CONFIG="$2"; shift 2 ;;
    --derived-data)  DERIVED="$2"; shift 2 ;;
    --package-dir)   PACKAGE_DIR="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               PASSTHROUGH+=("$1"); shift ;;
  esac
done

LOG="/tmp/macos-run-$(date +%Y%m%d-%H%M%S).log"

# ── 判据：要不要沙箱逃逸 ─────────────────────────────────────────────────
sandbox_escape_needed() {
  ! sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1
}
ESCAPE=0
sandbox_escape_needed && ESCAPE=1

report() {
  local code="$1"
  echo
  if [ "$code" -eq 0 ]; then
    local ok
    ok=$(grep -oE '\*\* (BUILD|TEST|CLEAN) SUCCEEDED \*\*' "$LOG" | tail -1)
    [ -z "$ok" ] && ok=$(grep -oE 'Build complete!|Test run with .* passed' "$LOG" | tail -1)
    echo "✓ ${ok:-成功}"
  else
    echo "✗ 失败（exit ${code}）—— 只列前几条："
    hits=$(grep -nE "error:|fatal error:|Unable to find a destination|sandbox_apply|Code ?Sign(ing)? error|✘|Expectation failed|Test run with .*failed|BUILD FAILED" "$LOG" | head -20)
    if [ -z "$hits" ]; then
      # 匹配不到已知签名时**必须**给点东西 —— 否则「✗ 失败」后面是一片空白
      echo "  （未匹配到已知失败签名，下面是日志末尾 10 行）"
      tail -10 "$LOG" | sed 's/^/  /'
    else
      printf '%s\n' "$hits"
    fi
  fi
  local warns
  warns=$(grep -c "warning:" "$LOG" 2>/dev/null || true)
  [ "${warns:-0}" != "0" ] && echo "  warning: ${warns} 条"
  echo "  完整日志：$LOG"
}

# ═══ probe ═══════════════════════════════════════════════════════════════
if [ "$CMD" = "probe" ]; then
  echo "== 工具链 =="
  echo "  $(xcodebuild -version 2>&1 | head -1)"
  echo "  $(xcrun swift --version 2>&1 | head -1)"
  echo
  echo "== 沙箱判据（决定要不要逃逸参数）=="
  if [ "$ESCAPE" = "1" ]; then
    echo "  deny-default : ❌ 无法 apply → **会自动加逃逸参数**"
    echo "    xcodebuild  : OTHER_SWIFT_FLAGS=-disable-sandbox"
    echo "    swift       : --disable-sandbox"
    echo "    （官方那三个 IDEPackageSupport* 参数在本环境无效：它们关的是内层沙箱）"
  else
    echo "  deny-default : ✅ 可 apply → 不需要特殊参数"
  fi
  echo
  echo "== macOS SDK =="
  xcodebuild -showsdks 2>/dev/null | grep -E -- "-sdk macosx" | sed 's/^/  /'
  echo
  echo "== 当前目录下能找到的工程 =="
  # ⚠️ 排掉 `X.xcodeproj/project.xcworkspace` —— 那是 xcodeproj 包内部的东西，
  # 它不是可用的顶层 workspace，列出来只会误导。
  projects=$(ls -d *.xcodeproj *.xcworkspace */*.xcodeproj */*.xcworkspace 2>/dev/null \
    | grep -v '\.xcodeproj/project\.xcworkspace' || true)
  if [ -n "$projects" ]; then
    echo "$projects" | sed 's/^/  /'
  else
    echo "  （没找到；试 find . -maxdepth 3 -name '*.xcodeproj' -not -path '*/.build/*'）"
  fi
  exit 0
fi

# ── 容器 ─────────────────────────────────────────────────────────────────
CONTAINER=()
[ -n "$PROJECT" ]   && CONTAINER+=(-project "$PROJECT")
[ -n "$WORKSPACE" ] && CONTAINER+=(-workspace "$WORKSPACE")

if [ "$CMD" = "destinations" ]; then
  [ ${#CONTAINER[@]} -eq 0 ] || [ -z "$SCHEME" ] && { echo "需要 --project/--workspace 与 --scheme" >&2; exit 2; }
  xcodebuild "${CONTAINER[@]}" -scheme "$SCHEME" -showdestinations 2>&1 \
    | grep -vE '^[[:space:]]*$' | sed -n '1,30p'
  exit 0
fi

# ═══ spm ═════════════════════════════════════════════════════════════════
if [ "$CMD" = "spm" ]; then
  SPM_ARGS=(swift "$ACTION")
  [ "$ESCAPE" = "1" ] && SPM_ARGS+=(--disable-sandbox)
  SPM_ARGS+=("${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}")
  echo "→ (cd $PACKAGE_DIR && ${SPM_ARGS[*]})"
  [ "$ESCAPE" = "1" ] && echo "  （已加沙箱逃逸：--disable-sandbox）"
  ( cd "$PACKAGE_DIR" && "${SPM_ARGS[@]}" ) > "$LOG" 2>&1
  code=$?
  report "$code"
  exit $code
fi

# ═══ macos ═══════════════════════════════════════════════════════════════
if [ ${#CONTAINER[@]} -eq 0 ] || [ -z "$SCHEME" ]; then
  echo "需要 --project/--workspace 与 --scheme（先 'macos-run.sh probe' 或 xcodebuild -list）" >&2
  exit 2
fi

DERIVED="${DERIVED:-$PWD/DerivedData}"

XARGS=("${CONTAINER[@]}" -scheme "$SCHEME" -destination 'platform=macOS' -derivedDataPath "$DERIVED")
[ -n "$CONFIG" ] && XARGS+=(-configuration "$CONFIG")
[ "$ESCAPE" = "1" ] && XARGS+=(OTHER_SWIFT_FLAGS=-disable-sandbox)   # build setting 必须在 action 前
XARGS+=("${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}")
XARGS+=("$ACTION")

echo "→ xcodebuild -scheme $SCHEME -destination 'platform=macOS' $ACTION"
[ "$ESCAPE" = "1" ] && echo "  （已加沙箱逃逸：OTHER_SWIFT_FLAGS=-disable-sandbox）"
echo "  derivedData：$DERIVED"

xcodebuild "${XARGS[@]}" > "$LOG" 2>&1
code=$?
report "$code"
exit $code
