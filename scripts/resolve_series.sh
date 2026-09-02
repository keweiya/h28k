#!/usr/bin/env bash

# 把 Actions 手动触发参数解析成构建矩阵的系列 JSON 列表。
# 系列列表由 firmware.conf 的 supported_versions 推导；
# 指定精确版本时必须在 supported_versions 内。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

conf="${1:-}"
series_input="${2:-}"
exact_version="${3:-}"
github_output="${4:-}"
[[ -n "$conf" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <series|all> [exact-version] <github-output>"
load_firmware_config "$conf"

if [[ -n "$exact_version" ]]; then
  version="${exact_version#v}"
  version_in_list "$version" ||
    fail "版本 $version 不在已测试列表中，ABI 无法保证（可选：${supported_versions[*]}）"
  series="${version%.*}"
  if [[ -n "$series_input" && "$series_input" != "all" &&
        "$series_input" != "$series" ]]; then
    fail "exact version $version does not belong to series $series_input"
  fi
  printf 'series=["%s"]\n' "$series" >> "$github_output"
  exit 0
fi

if [[ -z "$series_input" || "$series_input" == "all" ]]; then
  # 从已测试版本推导去重后的系列列表（保持首次出现顺序）
  declare -A seen=()
  declare -a series_list=()
  for v in "${supported_versions[@]}"; do
    s="${v%.*}"
    [[ -n "${seen[$s]:-}" ]] && continue
    seen[$s]=1
    series_list+=("$s")
  done
  json="$(printf '"%s",' "${series_list[@]}")"
  printf 'series=[%s]\n' "${json%,}" >> "$github_output"
else
  series_ok=false
  for v in "${supported_versions[@]}"; do
    [[ "$v" == "$series_input".* ]] && series_ok=true
  done
  [[ "$series_ok" == true ]] ||
    fail "unsupported series: $series_input（supported_versions 中没有该系列的已测试版本）"
  printf 'series=["%s"]\n' "$series_input" >> "$github_output"
fi
