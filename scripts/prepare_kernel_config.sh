#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

exclude_rk3528_from_abi() {
  local kernel_defaults="$1"
  sed -i \
    "/\.config\.set.*\.vermagic/s/| LC_ALL=C sort/| grep -v '^CONFIG_CLK_RK3528=y' | LC_ALL=C sort/" \
    "$kernel_defaults"
  [[ "$(grep -Fc "grep -v '^CONFIG_CLK_RK3528=y'" "$kernel_defaults")" -eq 1 ]] ||
    fail "kernel ABI generation rule was not updated"
}

source_dir="${1:-}"
config_file="${2:-}"
release_version="${3:-}"
release_series="${4:-}"
device_config="${5:-}"
[[ -n "$source_dir" && -n "$config_file" && -n "$release_version" &&
   -n "$release_series" && -n "$device_config" ]] ||
  fail "usage: $0 <source-dir> <firmware.conf> <release-version> <release-series> <device-config>"
[[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
[[ -f "$device_config" ]] || fail "device config not found: $device_config"
[[ "${release_version%.*}" == "$release_series" ]] ||
  fail "release version and series do not match"

load_firmware_config "$config_file"
cd "$source_dir"

if [[ "$check_official_abi" == true ]]; then
  buildinfo_url="https://downloads.immortalwrt.org/releases/$release_version/targets/rockchip/armv8/config.buildinfo"
  curl -fsSL "$buildinfo_url" -o .config.buildinfo
  awk '
    /^CONFIG_ALL_KMODS=y$/ ||
    /^CONFIG_DEVEL=y$/ ||
    (/^CONFIG_KERNEL_[A-Za-z0-9_]+=/ &&
      $0 !~ /^CONFIG_KERNEL_BUILD_(DOMAIN|USER)=/) ||
    /^# CONFIG_KERNEL_[A-Za-z0-9_]+ is not set$/
  ' .config.buildinfo > .config.official
  grep -q '^CONFIG_ALL_KMODS=y$' .config.official
  grep -q '^CONFIG_DEVEL=y$' .config.official
  cat .config.official "$device_config" > .config
  [[ "$release_series" == 24.10 ]] &&
    exclude_rk3528_from_abi include/kernel-defaults.mk
else
  cp "$device_config" .config
fi

make defconfig
