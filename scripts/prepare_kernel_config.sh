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
base_url="${6:-}"
[[ -n "$source_dir" && -n "$config_file" && -n "$release_version" &&
   -n "$release_series" && -n "$device_config" && -n "$base_url" ]] ||
  fail "usage: $0 <source-dir> <firmware.conf> <release-version> <release-series> <device-config> <base-url>"
[[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
[[ -f "$device_config" ]] || fail "device config not found: $device_config"
# 版本与系列一致性：X.Y.Z 归入 X.Y，X.Y-SNAPSHOT 归入 X.Y，master 归入 master
case "$release_version" in
  master)       [[ "$release_series" == "master" ]] || fail "release version and series do not match" ;;
  *-SNAPSHOT)   [[ "${release_version%-SNAPSHOT}" == "$release_series" ]] || fail "release version and series do not match" ;;
  *)            [[ "${release_version%.*}" == "$release_series" ]] || fail "release version and series do not match" ;;
esac

load_firmware_config "$config_file"
cd "$source_dir"

if [[ "$check_official_abi" == true ]]; then
  buildinfo_url="$base_url/targets/rockchip/armv8/config.buildinfo"
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
  # 根目录大小来自 firmware.conf 的 rootfs_size（工作流输入可覆盖），
  # 在设备种子之后追加，make defconfig 时以最后写入的值为准
  printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "$rootfs_size" >> .config
  [[ "$release_series" == 24.10 ]] &&
    exclude_rk3528_from_abi include/kernel-defaults.mk
else
  cp "$device_config" .config
  printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "$rootfs_size" >> .config
fi

make defconfig
