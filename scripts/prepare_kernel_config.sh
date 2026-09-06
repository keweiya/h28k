#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

exclude_symbols_from_abi() {
  local kernel_defaults="$1"; shift
  local chain="" sym
  for sym in "$@"; do
    chain="$chain | grep -v '^${sym}'"
  done
  sed -i \
    "/\.config\.set.*\.vermagic/s/| LC_ALL=C sort/${chain} | LC_ALL=C sort/" \
    "$kernel_defaults"
  for sym in "$@"; do
    [[ "$(grep -Fc "grep -v '^${sym}'" "$kernel_defaults")" -eq 1 ]] ||
      fail "kernel ABI generation rule was not updated ($sym)"
  done
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
  # CLK_RK3528：设备种子启用而官方未启用。CONFIG_KEYBOARD_ADC：上游 24.10
  # 分支 v24.10.4 起才有 kmod-input-adc-keys 定义，1/2/3 需补丁回填该 kmod
  # （官方这些版本未启用该符号）。两个差量符号从 vermagic 哈希中排除以对齐
  # 官方 ABI——新增模块不改动核心内核代码，远程官方 kmod 仍可正常加载
  if [[ "$release_series" == 24.10 ]]; then
    case "$release_version" in
      24.10.1|24.10.2|24.10.3)
        exclude_symbols_from_abi include/kernel-defaults.mk \
          CONFIG_CLK_RK3528=y CONFIG_KEYBOARD_ADC=m
        ;;
      *)
        exclude_symbols_from_abi include/kernel-defaults.mk CONFIG_CLK_RK3528=y
        ;;
    esac
  fi
else
  cp "$device_config" .config
  printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n' "$rootfs_size" >> .config
fi

make defconfig
