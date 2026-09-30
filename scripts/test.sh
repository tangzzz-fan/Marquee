#!/usr/bin/env bash
#
# 跑模块单元测试（比走 xcodebuild test 快得多，日常开发用这条）
#
# `--disable-sandbox` 是必须的：SwiftPM 默认给 Package.swift 的求值套
# deny-default 沙箱，当前宿主环境无法应用该形态的沙箱。原因见 docs/DEV-NOTES.md 第 4 节。

set -euo pipefail
cd "$(dirname "$0")/../Modules"
exec swift test --disable-sandbox "$@"
