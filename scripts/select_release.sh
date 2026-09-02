#!/usr/bin/env bash

# 解析要构建的 ImmortalWrt 版本：
#   - 传系列参数时自动选择该系列最新的、官方 kmods 仍然可用的正式版；
#   - 传精确版本参数时固定构建该版本；
#   - 都不传时回退到 firmware.conf 的 default_series。
# 输出 series/tag/version/kernel_kmods 供工作流后续步骤使用。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

resolve_official_kmods() {
  local version="$1" kmods
  kmods="$(curl -fsSL \
    "https://downloads.immortalwrt.org/releases/$version/targets/rockchip/armv8/kmods/" \
    | sed -nE 's#.*href="([^"]*-[0-9a-f]{32})/".*#\1#p' \
    | head -n 1)"
  [[ "$kmods" =~ -[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$kmods"
}

config_file="${1:-}"
github_output="${2:-}"
series_input="${3:-}"
version_input="${4:-}"
[[ -n "$config_file" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <github-output> [series] [exact-version]"
upstream=https://github.com/immortalwrt/immortalwrt.git
load_firmware_config "$config_file"

release_series="${series_input:-$default_series}"
[[ "$release_series" =~ ^(24\.10|25\.12)$ ]] ||
  fail "unsupported release series: $release_series"

release_tag=""
if [[ -n "$version_input" ]]; then
  release_version="${version_input#v}"
  [[ "$release_version" =~ ^(24\.10|25\.12)\.[0-9]+$ ]] ||
    fail "unsupported exact version: $version_input"
  [[ "$release_version" == "$release_series".* ]] ||
    fail "exact version $release_version does not belong to series $release_series"
  release_tag="v$release_version"
  git ls-remote --exit-code --tags --refs "$upstream" "refs/tags/$release_tag" >/dev/null ||
    fail "upstream release tag not found: $release_tag"
  kernel_kmods="$(resolve_official_kmods "$release_version")" ||
    fail "official kmods not found for $release_version"
else
  release_prefix="v${release_series}."
  for tag in $(git ls-remote --tags --refs "$upstream" 'refs/tags/v*' \
    | awk -F/ -v prefix="$release_prefix" \
      '$3 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ && index($3, prefix) == 1 { print $3 }' \
    | sort -Vr); do
    version="${tag#v}"
    if kernel_kmods="$(resolve_official_kmods "$version")"; then
      release_tag="$tag"
      release_version="$version"
      break
    fi
  done
  [[ -n "$release_tag" ]] || fail "no usable $release_series release was found"
fi

{
  echo "series=$release_series"
  echo "tag=$release_tag"
  echo "version=$release_version"
  echo "kernel_kmods=$kernel_kmods"
} >> "$github_output"

echo "Selected ImmortalWrt release: $release_tag"
