#!/usr/bin/env bash

# 把手动触发的版本选择解析成构建矩阵的版本 JSON 列表：
#   - 选了版本：只构建该版本（必须在 supported_versions 白名单内）；
#   - 未选版本（定时构建）：每个系列取白名单中最新的一个（按系列倒序）。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

conf="${1:-}"
version_input="${2:-}"
github_output="${3:-}"
[[ -n "$conf" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <version|空> <github-output>"
load_firmware_config "$conf"

if [[ -n "$version_input" ]]; then
  version_in_list "$version_input" ||
    fail "版本 $version_input 不在已测试列表中，ABI 无法保证（可选：${supported_versions[*]}）"
  printf 'versions=["%s"]\n' "$version_input" >> "$github_output"
  exit 0
fi

# 每系列取白名单中最新的版本，系列按版本倒序排列
declare -A latest=()
for v in "${supported_versions[@]}"; do
  s="${v%.*}"
  if [[ -z "${latest[$s]:-}" ]]; then
    latest[$s]="$v"
  else
    latest[$s]="$(printf '%s\n%s\n' "$v" "${latest[$s]}" | sort -V | tail -n1)"
  fi
done

mapfile -t series_sorted < <(printf '%s\n' "${!latest[@]}" | sort -Vr)
json=''
for s in "${series_sorted[@]}"; do
  json+="\"${latest[$s]}\","
done
printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
