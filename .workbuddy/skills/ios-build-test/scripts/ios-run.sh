#!/usr/bin/env bash
#
# ios-run.sh —— iOS 模拟器 / 真机的构建与测试（受限沙箱环境）
#
#   ios-run.sh probe                                    # 环境 + 沙箱判据 + 可用模拟器/真机
#   ios-run.sh sims                                     # 列可用模拟器（含 UDID）
#   ios-run.sh devices                                  # 列已连接的真机
#   ios-run.sh destinations --project Foo.xcodeproj --scheme Foo
#   ios-run.sh build --project Foo.xcodeproj --scheme Foo
#   ios-run.sh test  --workspace Foo.xcworkspace --scheme Foo --sim "iPhone 18 Pro"
#   ios-run.sh test  --project Foo.xcodeproj --scheme Foo --device 00008140-000A2888...
#   ios-run.sh test  --project Foo.xcodeproj --scheme Foo --only-testing FooTests/BarTests
#
# 自动做四件事：
#   1. **沙箱逃逸**：本 shell 若无法 apply deny-default 沙箱，自动加
#      `OTHER_SWIFT_FLAGS=-disable-sandbox`（Swift 宏 / swift-plugin-server 需要）。
#      判据：sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok
#   2. **挑 destination**：不给 --sim/--device 时自动选一台可用 iPhone 模拟器（用 UDID）。
#      **机型与 UDID 每次现查** —— 模拟器会被删掉重建，写死必然过期。
#   3. **给 xcodebuild 上界**：结果一出来就不再等"进程退场"，卡住就终止 + 回收残留（见 §上界）。
#   4. **日志落文件**，终端只回打关键行（失败先给第一条 error）。
#
# 环境变量：`IOS_TIMEOUT`（整体上限，默认 1800 秒）· `IOS_GRACE`（结果已出后再等几秒，默认 20 秒）
#
# 退出码 = xcodebuild 的退出码（0 = 成功）。其余参数透传。
#
# ⚠️ `--only-testing <Target>/<Class>` **对 Swift Testing 用例无效**：会跑 **0 条**，
#    而且照样打 `** TEST SUCCEEDED **`。脚本发现"0 条"时会显式警告（见 `report`）。

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

ACTION="build"
PROJECT=""
WORKSPACE=""
SCHEME=""
SIM=""
DEVICE=""
CONFIG=""
DERIVED=""
RESULT_BUNDLE=""
PASSTHROUGH=()

usage() { sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=""
case "${1:-}" in
  probe|sims|devices|destinations) CMD="$1"; shift ;;
  build|test)                      CMD="$1"; ACTION="$1"; shift ;;
  -h|--help|"")                    usage; exit 0 ;;
  *)                               CMD="build" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    build|test)      ACTION="$1"; CMD="$1"; shift ;;
    --project)       PROJECT="$2"; shift 2 ;;
    --workspace)     WORKSPACE="$2"; shift 2 ;;
    --scheme)        SCHEME="$2"; shift 2 ;;
    --sim)           SIM="$2"; shift 2 ;;
    --device)        DEVICE="$2"; shift 2 ;;
    --config)        CONFIG="$2"; shift 2 ;;
    --derived-data)  DERIVED="$2"; shift 2 ;;
    --result-bundle) RESULT_BUNDLE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               PASSTHROUGH+=("$1"); shift ;;
  esac
done

LOG="/tmp/ios-run-$(date +%Y%m%d-%H%M%S).log"

# ── 判据：要不要沙箱逃逸 ─────────────────────────────────────────────────
sandbox_escape_needed() {
  ! sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /bin/echo ok >/dev/null 2>&1
}
ESCAPE=0
sandbox_escape_needed && ESCAPE=1

# ── 现查设备（⚠️ BSD grep 不支持 \s，用 [[:space:]]）────────────────────
pick_simulator_udid() {
  xcrun simctl list devices available --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("devices", {})
except Exception:
    sys.exit(1)
for runtime in sorted(data, reverse=True):        # 最新 runtime 优先
    for dev in data[runtime]:
        if dev.get("isAvailable") and "iPhone" in dev.get("name", ""):
            print(dev["udid"])
            sys.exit(0)
sys.exit(1)
'
}

list_sims() {
  xcrun simctl list devices available 2>/dev/null \
    | grep -E "^[[:space:]]+(iPhone|iPad)"
}

# ── 给 xcodebuild 上界 ─────────────────────────────────────────────────────
# 为什么必须有（2026-10-15 实测，PlayerMPV 21 条例的套件）：
#   **测试跑完，xcodebuild 不退出。** 日志里 `Test run with 21 tests … failed` 已经打完，
#   而 `** TEST FAILED **` 与 xcresult 路径**一行都没有**；同一个套件**全绿**时 34 秒正常退出。
#   ⇒ 失败路径上它卡在 IDETestOperationsObserver 阶段（等测试进程退场）。
#   更糟的是**表现**：日志写进文件、终端一个字都不打 ⇒ 看起来就是死机（当天被中断两次）。
#
# 判据：**结论已经出来了，就不该继续等"进程退场"** —— 那件事对结论没有任何影响。
XCODE_TIMEOUT="${IOS_TIMEOUT:-1800}"
XCODE_GRACE="${IOS_GRACE:-20}"

verdict_seen() {
  grep -qE '\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*|^✔ Test run with|^✘ Test run with|Executed [0-9]+ tests?' "$LOG" 2>/dev/null
}

log_has_failure() {
  grep -qE '\*\* (BUILD|TEST) FAILED \*\*|^✘ |Executed [0-9]+ tests?, with [1-9][0-9]* failure|Test run with .*failed' "$LOG" 2>/dev/null
}

# 跑一条命令：结果一出来就只再等 `IOS_GRACE` 秒，超时就终止（结论已在日志里，不受影响）。
run_bounded() {
  "$@" > "$LOG" 2>&1 &
  local pid=$! waited=0 grace=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if verdict_seen; then
      grace=$((grace + 1))
      if [ "$grace" -ge "$XCODE_GRACE" ]; then
        echo "  ⚠️ 结果已出，但它 ${XCODE_GRACE} 秒内没退出 ⇒ 判定卡住，终止它"
        echo "     （结论仍然有效：最终判定已在日志里；卡住的只是「进程退场」这一步）"
        kill -TERM "$pid" 2>/dev/null
        sleep 2
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 0
      fi
    elif [ "$waited" -ge "$XCODE_TIMEOUT" ]; then
      echo "  ⚠️ 超过 IOS_TIMEOUT=${XCODE_TIMEOUT} 秒仍没有任何结果 ⇒ 终止"
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
  return $?
}

# 收尾：被终止之后，模拟器侧的测试进程常常还挂着（当天手工清过 5 个孤儿）。
# ⚠️ **只收"本次 derivedData 里的测试包"** —— 按 `$DERIVED/Build/Products/…/*.xctest` 精确匹配。
#    不能按 `$DERIVED` 裸匹配：**本脚本自己的命令行里就写着这个路径**，那样会把自己（和调用它的
#    那层 shell）一起杀掉。
reap_leftovers() {
  local pids p
  pids=$(pgrep -f "$DERIVED/Build/Products/.*\.xctest" 2>/dev/null || true)
  [ -z "$pids" ] && return 0
  echo "  清理残留测试进程：$(printf '%s ' $pids)"
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
}

report() {
  local code="$1" ok hits
  echo
  # ⚠️ 判定**以日志为准**，不以退出码为准：失败路径上 xcodebuild 可能被我们终止
  #    （见 `run_bounded`），那时退出码是我们给的，而真正的结论只在日志里。
  if log_has_failure; then
    echo "✗ 失败（判定来自日志；xcodebuild 退出码 ${code}）—— 只列前几条："
    hits=$(grep -nE "error:|fatal error:|Unable to find a destination|sandbox_apply|Code ?Sign(ing)? error|✘|Expectation failed|Test run with .*failed|BUILD FAILED" "$LOG" | head -20)
    if [ -z "$hits" ]; then
      # 匹配不到已知签名时**必须**给点东西 —— 否则「✗ 失败」后面是一片空白
      echo "  （未匹配到已知失败签名，下面是日志末尾 10 行）"
      tail -10 "$LOG" | sed 's/^/  /'
    else
      printf '%s\n' "$hits"
    fi
  else
    ok=$(grep -oE '\*\* (BUILD|TEST) SUCCEEDED \*\*' "$LOG" | tail -1)
    [ -z "$ok" ] && ok=$(grep -oE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG" | tail -1)
    if [ -z "$ok" ]; then
      echo "？ **没有明确结论**（退出码 ${code}）—— 日志里既没有成功也没有失败签名。末尾 10 行："
      tail -10 "$LOG" | sed 's/^/  /'
    else
      echo "✓ ${ok}"
      if [ "$ACTION" = "test" ]; then
        grep -oE "Test Suite '[^']*' (passed|failed)( at .*)?|Executed [0-9]+ test" "$LOG" | tail -3
      fi
    fi
  fi
  # ⚠️ **「一条都没跑」与「全都跑过了」长得一模一样。**
  #    实测：`--only-testing PlayerMPVTests/MPVKernelTests/testXxx`（Swift Testing 用例）
  #    ⇒ `Test run with 0 tests … passed` + `** TEST SUCCEEDED **`。
  #    没有这一行警告，你会以为"这条用例绿了"，其实它压根没跑（同 `P-050` 的形态：
  #    把"选不中"变成"什么都没发生"）。
  #    ⚠️ 只认 **Swift Testing** 的汇总行：`Executed N tests` 是 **XCTest** 的计数，
  #       纯 Swift Testing 套件下它**永远是 0**（把它算进来会在每次全绿时报假警）。
  if grep -qE 'Test run with 0 tests' "$LOG"; then
    echo "  ⚠️ 本次 **0 条用例**：\`--only-testing\` 只认 XCTest 的 <Target>/<Class>/<method>，"
    echo "     Swift Testing 的 @Test 选不中 —— 它没报错，也没跑东西。"
    echo "     ⇒ 去掉 --only-testing 跑全量，或改用 \`swift test --filter\`。"
  fi
  [ -n "$RESULT_BUNDLE" ] && echo "  测试报告：$RESULT_BUNDLE"
  echo "  完整日志：$LOG"
}

# ═══ probe / sims / devices ══════════════════════════════════════════════
if [ "$CMD" = "probe" ]; then
  echo "== 工具链 =="
  echo "  $(xcodebuild -version 2>&1 | head -1)"
  echo
  echo "== 沙箱判据（决定要不要逃逸参数）=="
  if [ "$ESCAPE" = "1" ]; then
    echo "  deny-default : ❌ 无法 apply → **会自动加 OTHER_SWIFT_FLAGS=-disable-sandbox**"
    echo "    （官方那三个 IDEPackageSupport* 参数在本环境无效：它们关的是内层沙箱）"
  else
    echo "  deny-default : ✅ 可 apply → 不需要特殊参数"
  fi
  echo
  echo "== iOS SDK =="
  xcodebuild -showsdks 2>/dev/null | grep -E -- "-sdk (iphoneos|iphonesimulator)" | sed 's/^/  /'
  echo
  echo "== 可用 iPhone/iPad 模拟器（现查；不要写死 UDID）=="
  list_sims | sed 's/^/  /'
  echo "  自动挑中的：$(pick_simulator_udid 2>/dev/null || echo '（无可用 iPhone 模拟器）')"
  echo
  # ⚠️ devicectl 的输出**真机与模拟器都有**，靠 Reality 列区分
  # （physical = 真机 / simulated = 模拟器）。真机取 Identifier 那一列。
  echo "== 设备（devicectl；Reality 列区分 physical / simulated）=="
  xcrun devicectl list devices 2>&1 | sed 's/^/  /' | head -14
  exit 0
fi

if [ "$CMD" = "sims" ];    then list_sims; exit 0; fi
if [ "$CMD" = "devices" ]; then xcrun devicectl list devices 2>&1 | head -20; exit 0; fi

# ── 容器 ─────────────────────────────────────────────────────────────────
CONTAINER=()
[ -n "$PROJECT" ]   && CONTAINER+=(-project "$PROJECT")
[ -n "$WORKSPACE" ] && CONTAINER+=(-workspace "$WORKSPACE")

if [ "$CMD" = "destinations" ]; then
  [ ${#CONTAINER[@]} -eq 0 ] || [ -z "$SCHEME" ] && { echo "需要 --project/--workspace 与 --scheme" >&2; exit 2; }
  xcodebuild "${CONTAINER[@]}" -scheme "$SCHEME" -showdestinations 2>&1 \
    | grep -vE '^[[:space:]]*$' | sed -n '1,40p'
  exit 0
fi

# ═══ build / test ════════════════════════════════════════════════════════
if [ -z "$SCHEME" ]; then
  echo "需要 --scheme（用 'ios-run.sh probe' 或从工程里 'xcodebuild -list' 先确认）" >&2
  exit 2
fi

# ⚠️ **不给 --project/--workspace 是合法的**：SwiftPM 包就是这种形态 ——
#    xcodebuild 在包根目录下可以直接 `-scheme <包名>`（`MPV/` 这类独立包就是）。
#    此前这里**直接报错退出**，结果是只能手调 xcodebuild —— 而手调的那几条命令
#    恰好绕过了本脚本的看门狗与收尾（当天两次"卡住"都发生在手调路径上）。
if [ ${#CONTAINER[@]} -eq 0 ]; then
  # ⚠️ `${PWD}` 的花括号**不能省**：紧跟其后是全角括号，`$PWD）` 会被当成变量名的一部分
  #    （实测报 `PWD…: unbound variable`）。同 `shell-portability` 的 §「$var 后紧跟全角字符」。
  echo "  （未给 --project/--workspace ⇒ 按 SwiftPM 包处理：在当前目录 ${PWD} 求值）"
fi

if [ -n "$DEVICE" ]; then
  DEST="id=$DEVICE"                                   # 真机（UDID）
  KIND="真机"
elif [ -n "$SIM" ]; then
  case "$SIM" in
    ????????-????-????-????-????????????) DEST="id=$SIM"; KIND="模拟器(UDID)" ;;
    *) DEST="platform=iOS Simulator,name=$SIM"; KIND="模拟器(名字)" ;;
  esac
else
  UDID=$(pick_simulator_udid) || {
    echo "✗ 没有可用的 iPhone 模拟器。跑 'ios-run.sh probe' 看列表，或显式给 --sim/--device" >&2
    exit 2
  }
  DEST="id=$UDID"; KIND="模拟器(自动挑)"
fi

DERIVED="${DERIVED:-$PWD/DerivedData}"

# ⚠️ `"${CONTAINER[@]}"` 在**空数组**时会触发 `set -u` 的 unbound variable
#    （bash 3.2 的老毛病；同一行的 `PASSTHROUGH` 早就用 `+` 守卫绕过了，
#     `CONTAINER` 以前**必须非空**所以没暴露 —— 现在 SwiftPM 包允许它为空）。
XARGS=("${CONTAINER[@]+"${CONTAINER[@]}"}" -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED")
[ -n "$CONFIG" ] && XARGS+=(-configuration "$CONFIG")
[ "$ESCAPE" = "1" ] && XARGS+=(OTHER_SWIFT_FLAGS=-disable-sandbox)   # build setting 必须在 action 前
[ -n "$RESULT_BUNDLE" ] && XARGS+=(-resultBundlePath "$RESULT_BUNDLE")
XARGS+=("${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}")
XARGS+=("$ACTION")

echo "→ xcodebuild -scheme $SCHEME -destination '$DEST' $ACTION   [$KIND]"
[ "$ESCAPE" = "1" ] && echo "  （已加沙箱逃逸：OTHER_SWIFT_FLAGS=-disable-sandbox）"
echo "  derivedData：$DERIVED"

run_bounded xcodebuild "${XARGS[@]}"
code=$?
report "$code"
reap_leftovers
# ⚠️ **退出码必须以日志判定为准**：被我们终止时进程的退出码是信号值（或我们给的 0），
#    它**不等于结论**。少了这一步，"测试失败"会以 0 退出 —— 调用方（和 CI）把红当绿。
log_has_failure && exit 1
exit $code
