#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

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
  local source_dir="$1" config_file="$2" github_env="$3"
  [[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
  load_firmware_config "$config_file"
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
  # 滚动快照（master / X.Y-SNAPSHOT）：官方产物随时被新构建覆盖，ABI 强校验
  # 不适用（轮换会误报失败）。构建改为源码锁 revision + 全量 kmod 本地捆绑，
  # 固件自包含；与官方源的 kmod 兼容是尽力而为，不做硬性门禁
  if [[ "$(version_kind "$version")" == "snapshot" ]]; then
    echo "Rolling snapshot $version: official ABI check skipped（官方产物随时轮换，kmod 以本地捆绑为准）"
    return
  fi
  [[ "$kernel_kmods" =~ -[0-9a-f]{32}$ ]] || fail "invalid kmods directory: $kernel_kmods"

  built_abi="$(read_built_abi "$source_dir")"
  echo "release=$tag"
  echo "built_abi=$built_abi"
  echo "official_abi=$official_abi"
  if [[ "$built_abi" != "$official_abi" ]]; then
    echo "kernel ABI does not match official $version" >&2
    exit 1
  fi
}

# 解析源码插件清单（config/source-plugins.list）：
# 执行其中的 clone: 行（把源码克隆进 SDK 源码树），并把要编译的包名打印到 stdout。
run_source_plugins() {
  local sdk_dir="$1" list_file="$2" line cmd name
  local -a command names=()
  [[ -d "$sdk_dir" ]] || fail "SDK directory not found: $sdk_dir"
  [[ -f "$list_file" ]] || fail "source plugins list not found: $list_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == clone:* ]]; then
      cmd="$(trim "${line#clone:}")"
      read -r -a command <<< "$cmd"
      [[ "${command[0]:-}" == git && "${command[1]:-}" == clone ]] ||
        fail "clone lines must be git clone commands: $line"
      (cd "$sdk_dir" && "${command[@]}")
    else
      names+=("$line")
    fi
  done < "$list_file"

  for name in "${names[@]}"; do
    printf '%s\n' "$name"
  done
}

case "${1:-}" in
  prepare)
    [[ $# -eq 4 ]] || fail "usage: $0 prepare <source-dir> <firmware.conf> <github-env>"
    prepare "$2" "$3" "$4"
    ;;
  source-plugins)
    [[ $# -eq 3 ]] || fail "usage: $0 source-plugins <sdk-dir> <source-plugins.list>"
    run_source_plugins "$2" "$3"
    ;;
  check-abi)
    [[ $# -eq 6 ]] || fail "usage: $0 check-abi <source-dir> <firmware.conf> <version> <tag> <kmods-directory>"
    check_abi "$2" "$3" "$4" "$5" "$6"
    ;;
  *) fail "unknown command: ${1:-}" ;;
esac
