#!/usr/bin/env bash

# 解析版本选择为构建矩阵的版本 JSON 列表：
#   - all / 空：全部白名单版本（按版本倒序）；
#   - 具体版本：必须在 supported_versions 白名单内。

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
  version_in_list "$version_input" ||
    fail "版本 $version_input 不在已测试列表中，ABI 无法保证（可选：all 或 ${supported_versions[*]}）"
  mapfile -t sorted < <(printf '%s\n' "$version_input")
else
  mapfile -t sorted < <(printf '%s\n' "${supported_versions[@]}" | sort -Vr)
fi

json=''
for v in "${sorted[@]}"; do
  json+="\"$v\","
done
printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
