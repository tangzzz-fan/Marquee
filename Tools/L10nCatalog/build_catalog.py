#!/usr/bin/env python3
"""从生产代码里抽出 L10n.t("…") 的 key（插值归一成 %lld / %@），并生成 catalog。

用法：
  python3 build_catalog.py keys          # 打印 key 清单
  python3 build_catalog.py write         # 用 translations.py 里的表生成 .xcstrings
"""
import json
import pathlib
import re
import sys

# ⚠️ 路径**从脚本位置推**，不写绝对值。
#
# 这个脚本原先是 `/tmp` 里的临时文件，`ROOT` 写死了本人机器的绝对路径 ——
# 于是它只能在一台机器、一个 checkout 上跑，而且**丢了就得手工重做 187 条翻译**
# （它是生成 catalog 的唯一工具，`LocalizationScanTests` 只能校验、不能生成）。
# 收进仓库 + 相对路径之后，谁 clone 下来都能重出同一份 catalog。
_HERE = pathlib.Path(__file__).resolve().parent
ROOT = _HERE.parents[1]
OUT = ROOT / "App/Resources/Localizable.xcstrings"

# 翻译表与生成器同目录：`from translations import EN` 靠这一行才能从任意 cwd 生效。
sys.path.insert(0, str(_HERE))
CJK = re.compile(r"[\u4e00-\u9fff]")

# 「像字符串」的表达式 → %@，其余按整数 %lld
STRINGY = ("localizedDescription", ".path", "displayString", "reason", "detail",
           "title", "text", "conflict", "uppercased()", "String(")


# 这几个是**读过声明**定下来的，不是猜的（探测结果见 ticket 17b 的实现记录）：
#   RecentCapturesPanelController: size 是拼好的 String   → %@
#   ShortcutService:              status 是 Int32/OSStatus → %d
#   ScreenCaptureKitCapturer:     id 是 UInt32             → %u
SPEC_OVERRIDES = {"size": "%@", "status": "%d", "id": "%u"}


def spec_for(expr: str) -> str:
    bare = expr.strip()
    if bare in SPEC_OVERRIDES:
        return SPEC_OVERRIDES[bare]
    if "CGFloat" in expr or "Double" in expr:
        return "%lf"
    if "UInt32" in expr or "UInt8" in expr or "UInt16" in expr:
        return "%u"
    if "Int32" in expr or "OSStatus" in expr:
        return "%d"
    return "%@" if any(s in expr for s in STRINGY) else "%lld"


def key_of(content: str) -> str:
    """把 Swift 插值转成 catalog 的格式说明符。"""
    out = []
    i = 0
    n = len(content)
    while i < n:
        if content[i] == "\\" and i + 1 < n and content[i + 1] == "(":
            depth = 1
            j = i + 2
            while j < n and depth:
                if content[j] == "(":
                    depth += 1
                elif content[j] == ")":
                    depth -= 1
                j += 1
            out.append(spec_for(content[i + 2:j - 1]))
            i = j
            continue
        if content[i] == "\\" and i + 1 < n:
            esc = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "0": "\0"}
            out.append(esc.get(content[i + 1], content[i + 1]))
            i += 2
            continue
        out.append(content[i])
        i += 1
    return "".join(out)


def literals(code: str):
    out, i, n = [], 0, len(code)
    while i < n:
        if code[i] == "/" and i + 1 < n and code[i + 1] == "/":
            break
        if code[i] == '"':
            j = i + 1
            while j < n:
                if code[j] == "\\" and j + 1 < n and code[j + 1] == "(":
                    depth, k = 1, j + 2
                    while k < n and depth:
                        if code[k] == "(":
                            depth += 1
                        elif code[k] == ")":
                            depth -= 1
                        k += 1
                    j = k
                    continue
                if code[j] == "\\":
                    j += 2
                    continue
                if code[j] == '"':
                    break
                j += 1
            if j >= n:
                return out
            out.append((i, j + 1, code[i + 1:j]))
            i = j + 1
            continue
        i += 1
    return out


def collect():
    keys = {}
    files = sorted(list(ROOT.glob("App/Sources/*.swift"))
                   + list(ROOT.glob("Modules/Sources/*/*.swift")))
    for f in files:
        for line_no, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for start, end, content in literals(line):
                if not CJK.search(content):
                    continue
                if not line[:start].rstrip().endswith("L10n.t("):
                    continue
                if any(m in line for m in ("logger.", "os_log(", "print(", "assert")):
                    continue
                keys.setdefault(key_of(content), []).append(f"{f.relative_to(ROOT)}:{line_no}")
    return keys


def main():
    keys = collect()
    # 不给参数时按 `keys` 走。原先直接 `sys.argv[1]`，裸跑会抛 IndexError ——
    # 而"忘了带参数"是最容易发生的一种调用方式。
    command = sys.argv[1] if len(sys.argv) > 1 else "keys"
    if command == "keys":
        for k in sorted(keys):
            print(k)
        print(f"\n== {len(keys)} 个 key ==")
        return

    from translations import EN  # noqa: E402

    missing = sorted(k for k in keys if k not in EN)
    extra = sorted(k for k in EN if k not in keys)
    if missing:
        print("!! 缺翻译：")
        for k in missing:
            print(f"   {k}    {keys[k][0]}")
    if extra:
        print("!! 表里有、源码里没有（孤儿）：")
        for k in extra:
            print(f"   {k}")
    if missing or extra:
        print(f"\n缺 {len(missing)} / 孤儿 {len(extra)}；先补齐再 write")
        return

    strings = {
        key: {"localizations": {"en": {"stringUnit": {"state": "translated", "value": EN[key]}}}}
        for key in sorted(keys)
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"sourceLanguage": "zh-Hans",
                               "strings": strings,
                               "version": "1.0"},
                              ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                   encoding="utf-8")
    print(f"写出 {OUT} —— {len(strings)} 条")


main()
