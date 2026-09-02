#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

clone_extra_packages() {
  local source_dir="$1" list="$2" line
  local -a command
  [[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
  [[ -f "$list" ]] || fail "package list not found: $list"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r -a command <<< "$line"
    [[ "${command[0]:-}" == git && "${command[1]:-}" == clone ]] ||
      fail "only git clone commands are allowed: $line"
    (cd "$source_dir" && "${command[@]}")
  done < "$list"
}

apply_device_config() {
  local source_dir="$1" lan_ip_value="$2" password_value="$3" theme="$4"
  local shadow password_hash

  sed -i "s/192\.168\.1\.1/$lan_ip_value/g" \
    "$source_dir/package/base-files/files/bin/config_generate"

  if [[ -n "$theme" ]]; then
    sed -i "s|/luci-static/bootstrap|/luci-static/$theme|" \
      "$source_dir/feeds/luci/modules/luci-base/root/etc/config/luci"
  fi

  shadow="$source_dir/package/base-files/files/etc/shadow"
  password_hash="$(printf '%s\n' "$password_value" | openssl passwd -6 -stdin)"
  sed -i "s|^root:[^:]*:|root:${password_hash}:|" "$shadow"
}

enable_official_kmods() {
  local feeds="$1/include/feeds.mk"
  [[ "$(grep -c 'CONFIG_BUILDBOT' "$feeds")" -eq 2 ]] ||
    fail "official kmods feed rules were not found"
  sed -i 's/CONFIG_BUILDBOT/CONFIG_ALL_KMODS/g' "$feeds"
  [[ "$(grep -c 'CONFIG_ALL_KMODS' "$feeds")" -eq 2 ]] ||
    fail "official kmods feed rules were not updated"
}

prepare() {
  local source_dir="$1" config_file="$2" packages_file="$3" github_env="$4"
  [[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
  load_firmware_config "$config_file"
  # packages_file 为空表示本阶段不克隆源码包（第三方插件改由 SDK 工作流单独编译）
  if [[ -n "$packages_file" ]]; then
    clone_extra_packages "$source_dir" "$packages_file"
  fi
  apply_device_config "$source_dir" "$lan_ip" "$password" "$default_theme"
  [[ "$check_official_abi" == true ]] && enable_official_kmods "$source_dir"
  printf 'FIRMWARE_LAN_IP=%s\nFIRMWARE_PASSWORD=%s\n' "$lan_ip" "$password" >> "$github_env"
}

read_built_abi() {
  local source_dir="$1" vermagic
  vermagic="$(find "$source_dir"/build_dir/target-* \
    -path '*/linux-rockchip_armv8/linux-*/.vermagic' -print -quit)"
  [[ -n "$vermagic" ]] || fail "kernel .vermagic was not found"
  tr -d '[:space:]' < "$vermagic"
}

check_abi() {
  local source_dir="$1" config_file="$2" version="$3" tag="$4" kernel_kmods="$5"
  local built_abi official_abi="${kernel_kmods##*-}"
  [[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
  load_firmware_config "$config_file"
  [[ "$check_official_abi" == true ]] || { echo "Official ABI check skipped"; return; }
  [[ "$kernel_kmods" =~ -[0-9a-f]{32}$ ]] || fail "invalid kmods directory: $kernel_kmods"

  built_abi="$(read_built_abi "$source_dir")"
  echo "release=$tag"
  echo "built_abi=$built_abi"
  echo "official_abi=$official_abi"
  [[ "$built_abi" == "$official_abi" ]] ||
    fail "kernel ABI does not match official release $version"
}

case "${1:-}" in
  prepare)
    [[ $# -eq 5 ]] || fail "usage: $0 prepare <source-dir> <firmware.conf> <packages.conf> <github-env>"
    prepare "$2" "$3" "$4" "$5"
    ;;
  clone-packages)
    [[ $# -eq 3 ]] || fail "usage: $0 clone-packages <source-dir> <packages.conf>"
    clone_extra_packages "$2" "$3"
    ;;
  check-abi)
    [[ $# -eq 6 ]] || fail "usage: $0 check-abi <source-dir> <firmware.conf> <version> <tag> <kmods-directory>"
    check_abi "$2" "$3" "$4" "$5" "$6"
    ;;
  *) fail "unknown command: ${1:-}" ;;
esac
