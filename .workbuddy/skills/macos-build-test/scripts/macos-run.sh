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
# 自动做四件事：
#   1. **沙箱逃逸**：本 shell 若无法 apply deny-default 沙箱，自动加
#      `OTHER_SWIFT_FLAGS=-disable-sandbox`（xcodebuild）/ `--disable-sandbox`（swift）。
#      判据：sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
#   2. **固定 derivedData** 到 `<cwd>/DerivedData`（可 --derived-data 覆盖）
#   3. **给底层命令上界**：结果一出来就不再等"进程退场"，卡住就终止 + 回收残留（见 §上界）
#   4. **日志落文件**，终端只回打关键行（失败先给第一条 error）
#
# 环境变量：`MACOS_TIMEOUT`（整体上限，默认 1800 秒）· `MACOS_GRACE`（结果已出后再等几秒，默认 20 秒）
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

# ── 给底层命令上界 ─────────────────────────────────────────────────────────
# 为什么必须有（2026-10-15，同一个坑在 iOS 侧先被踩到）：
#   **xcodebuild 在"测试失败"的路径上不退出** —— 日志里 Swift Testing 的汇总已经打完，
#   而 `** TEST FAILED **` 与 xcresult 路径一行都没有（全绿时 30 秒内正常退出）。
#   表现更糟：日志写文件、终端一个字都不打 ⇒ 看起来就是死机。
#   同一族还有一个更隐蔽的：`swift test` 结束之后**测试进程还挂着**（当天清出 5 个孤儿，
#   load average 被抬到 4）。
#
# 判据：**结论已经出来了，就不该继续等「进程退场」** —— 那件事对结论没有任何影响。
CMD_TIMEOUT="${MACOS_TIMEOUT:-1800}"
CMD_GRACE="${MACOS_GRACE:-20}"

verdict_seen() {
  grep -qE '\*\* (BUILD|TEST|CLEAN) (SUCCEEDED|FAILED) \*\*|^✔ Test run with|^✘ Test run with|Build complete!|Executed [0-9]+ tests?' "$LOG" 2>/dev/null
}

log_has_failure() {
  grep -qE '\*\* (BUILD|TEST) FAILED \*\*|^✘ |error:|Executed [0-9]+ tests?, with [1-9][0-9]* failure|Test run with .*failed' "$LOG" 2>/dev/null
}

run_bounded() {
  "$@" > "$LOG" 2>&1 &
  local pid=$! waited=0 grace=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if verdict_seen; then
      grace=$((grace + 1))
      if [ "$grace" -ge "$CMD_GRACE" ]; then
        echo "  ⚠️ 结果已出，但它 ${CMD_GRACE} 秒内没退出 ⇒ 判定卡住，终止它"
        echo "     （结论仍然有效：最终判定已在日志里；卡住的只是「进程退场」这一步）"
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 0
      fi
    elif [ "$waited" -ge "$CMD_TIMEOUT" ]; then
      echo "  ⚠️ 超过 MACOS_TIMEOUT=${CMD_TIMEOUT} 秒仍没有任何结果 ⇒ 终止"
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
  return $?
}

# 收尾：测试进程常常比命令活得久（当天手工清过 5 个）。
# ⚠️ 只按"**测试包在本次构建目录里**"精确匹配；**不能按目录裸匹配** ——
#    脚本自己的命令行里就写着那个路径，那样会把自己和调用它的 shell 一起杀掉。
reap_leftovers() {
  local pids p pk
  pids=""
  if [ -n "${DERIVED:-}" ]; then
    pids=$(pgrep -f "$DERIVED/Build/Products/.*\.xctest" 2>/dev/null || true)
  fi
  if [ -n "${PACKAGE_DIR:-}" ]; then
    # ⚠️ `PACKAGE_DIR` 默认是 `.`，而进程命令行里是**绝对路径** ⇒ 必须先解析成绝对路径，
    #    否则模式永远匹配不上（这类"匹配不上"不报错，只表现为"没有残留"）。
    pk=$(cd "$PACKAGE_DIR" 2>/dev/null && pwd) || pk=""
    [ -n "$pk" ] && pids="$pids $(pgrep -f "$pk/\.build/.*\.xctest" 2>/dev/null || true)"
  fi
  pids=$(printf '%s\n' $pids | sort -u | tr '\n' ' ')
  [ -z "${pids// /}" ] && return 0
  echo "  清理残留测试进程：$pids"
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
}

report() {
  local code="$1" ok hits
  echo
  # ⚠️ 判定**以日志为准**，不以退出码为准：失败路径上底层命令可能被我们终止（见 `run_bounded`）。
  if log_has_failure; then
    echo "✗ 失败（判定来自日志；退出码 ${code}）—— 只列前几条："
    hits=$(grep -nE "error:|fatal error:|Unable to find a destination|sandbox_apply|Code ?Sign(ing)? error|✘|Expectation failed|Test run with .*failed|BUILD FAILED" "$LOG" | head -20)
    if [ -z "$hits" ]; then
      # 匹配不到已知签名时**必须**给点东西 —— 否则「✗ 失败」后面是一片空白
      echo "  （未匹配到已知失败签名，下面是日志末尾 10 行）"
      tail -10 "$LOG" | sed 's/^/  /'
    else
      printf '%s\n' "$hits"
    fi
  else
    ok=$(grep -oE '\*\* (BUILD|TEST|CLEAN) SUCCEEDED \*\*' "$LOG" | tail -1)
    [ -z "$ok" ] && ok=$(grep -oE 'Build complete!|Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG" | tail -1)
    if [ -z "$ok" ]; then
      echo "？ **没有明确结论**（退出码 ${code}）—— 日志里既没有成功也没有失败签名。末尾 10 行："
      tail -10 "$LOG" | sed 's/^/  /'
    else
      echo "✓ ${ok}"
    fi
  fi
  # ⚠️ 「一条都没跑」与「全都跑过了」长得一模一样 —— 只认 Swift Testing 的汇总行
  #    （`Executed N tests` 是 XCTest 的计数，纯 Swift Testing 套件下永远是 0）。
  if grep -qE 'Test run with 0 tests' "$LOG"; then
    echo "  ⚠️ 本次 **0 条用例** —— 过滤条件没选中任何东西，它不会报错。"
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
  # 在子 shell 里 cd 到包目录再跑（`run_bounded` 是后台执行，cd 不会污染父 shell）
  spm_in_dir() { cd "$PACKAGE_DIR" && exec "${SPM_ARGS[@]}"; }
  run_bounded spm_in_dir
  code=$?
  report "$code"
  reap_leftovers
  # ⚠️ 退出码以**日志判定**为准（见 `run_bounded` 的说明）
  log_has_failure && exit 1
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

run_bounded xcodebuild "${XARGS[@]}"
code=$?
report "$code"
reap_leftovers
# ⚠️ 退出码以**日志判定**为准（见 `run_bounded` 的说明）
log_has_failure && exit 1
exit $code
