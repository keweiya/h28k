#!/usr/bin/env bash

# 解析要构建的 ImmortalWrt 版本：只能选 firmware.conf supported_versions 中
# 已测试的版本（补丁与 ABI 校验仅对这些版本成立，其他版本无法保证 ABI）。
# 输出 series/tag/version/kernel_kmods 供工作流后续步骤使用。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

resolve_official_kmods() {
  local version="$1" kmods
  # 先完整捕获再取第一行：管道接 head 会在 pipefail 下触发 SIGPIPE
  kmods="$(curl -fsSL \
    "https://downloads.immortalwrt.org/releases/$version/targets/rockchip/armv8/kmods/" \
    | sed -nE 's#.*href="([^"]*-[0-9a-f]{32})/".*#\1#p')"
  kmods="${kmods%%$'\n'*}"
  [[ "$kmods" =~ -[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$kmods"
}

config_file="${1:-}"
github_output="${2:-}"
version_input="${3:-}"
[[ -n "$config_file" && -n "$github_output" && -n "$version_input" ]] ||
  fail "usage: $0 <firmware.conf> <github-output> <version>"
load_firmware_config "$config_file"

release_version="${version_input#v}"
version_in_list "$release_version" ||
  fail "版本 $release_version 不在已测试列表中，ABI 无法保证（可选：${supported_versions[*]}）"

release_series="${release_version%.*}"
release_tag="v$release_version"
kernel_kmods="$(resolve_official_kmods "$release_version")" ||
  fail "official kmods not found for $release_version"

{
  echo "series=$release_series"
  echo "tag=$release_tag"
  echo "version=$release_version"
  echo "kernel_kmods=$kernel_kmods"
} >> "$github_output"

echo "Selected ImmortalWrt release: $release_tag"
