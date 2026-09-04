#!/usr/bin/env bash

# 解析版本选择为构建矩阵的版本 JSON 列表：
#   - all / 空：firmware.conf supported_versions 列出的默认集合（正式版按版本
#     倒序在前，滚动快照殿后），并输出其中最新的正式版 latest（工作流用它决定
#     哪个 Release 标记 --latest，滚动快照永不抢占 latest）；
#   - 具体版本：X.Y.Z / X.Y-SNAPSHOT / master，系列须在 supported_series 内。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

conf="${1:-}"
version_input="${2:-}"
github_output="${3:-}"
[[ -n "$conf" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <version|all> <github-output>"
load_firmware_config "$conf"

if [[ -n "$version_input" && "$version_input" != "all" ]]; then
  version="${version_input#v}"
  [[ "$(version_kind "$version")" != "invalid" ]] ||
    fail "无法识别的版本：$version（支持 X.Y.Z / X.Y-SNAPSHOT / master 或 all）"
  series="$(version_series "$version")"
  series_supported "$series" ||
    fail "系列 $series 未启用（firmware.conf 的 supported_series：${supported_series[*]}）"
  mapfile -t sorted < <(printf '%s\n' "$version")
else
  mapfile -t sorted < <(
    for v in "${supported_versions[@]}"; do
      [[ "$(version_kind "$v")" == "release" ]] && printf '%s\n' "$v"
    done | sort -Vr
    for v in "${supported_versions[@]}"; do
      [[ "$(version_kind "$v")" == "snapshot" ]] && printf '%s\n' "$v"
    done | sort
  )
fi

# latest 始终取默认集合中最新的正式版：单版本构建旧版本时不会被误标 --latest
# latest 始终取默认集合中最新的正式版：单版本构建旧版本时不会被误标 --latest
latest="$(for v in "${supported_versions[@]}"; do
  [[ "$(version_kind "$v")" == "release" ]] && printf '%s\n' "$v"
done | sort -Vr | sed -n '1p')"

json=''
for v in "${sorted[@]}"; do
  json+="\"$v\","
done
printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
printf 'latest=%s\n' "$latest" >> "$github_output"
