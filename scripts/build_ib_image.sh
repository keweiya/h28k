#!/usr/bin/env bash

# 用自建 ImageBuilder 组装定制固件：不编译任何东西，只解包 IB、注入
# LAN IP / root 密码 / 默认主题（首启 uci-defaults）、按包列表安装并生成镜像。
# 内核与 kmod 与基础构建完全一致，ABI 不变。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

ib_tarball="${1:-}"
config_file="${2:-}"
packages_list="${3:-}"
out_dir="${4:-}"
[[ -n "$ib_tarball" && -n "$config_file" && -n "$packages_list" && -n "$out_dir" ]] ||
  fail "usage: $0 <ib-tarball> <firmware.conf> <ib-packages.list> <out-dir>"
[[ -f "$ib_tarball" ]] || fail "ImageBuilder tarball not found: $ib_tarball"
[[ -f "$packages_list" ]] || fail "package list not found: $packages_list"

load_firmware_config "$config_file"

# 后续会 cd 进 ImageBuilder 目录，先把所有路径转为绝对路径
[[ -d "$out_dir" ]] || mkdir -p "$out_dir"
packages_list="$(cd "$(dirname -- "$packages_list")" && pwd)/$(basename -- "$packages_list")"
out_dir="$(cd -- "$out_dir" && pwd)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "=== 解包 ImageBuilder ==="
tar -xJf "$ib_tarball" -C "$work_dir"
ib_dir="$(find "$work_dir" -maxdepth 1 -type d -name 'immortalwrt-imagebuilder-*' | head -n1)"
[[ -n "$ib_dir" ]] || fail "ImageBuilder directory not found in tarball"
cd "$ib_dir"

echo "=== 生成首启配置（IP/密码/主题） ==="
password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
mkdir -p files/etc/uci-defaults
{
  echo "uci set network.lan.ipaddr='$lan_ip'"
  echo "uci commit network"
  if [[ -n "$default_theme" ]]; then
    echo "uci set luci.main.theme='$default_theme'"
    echo "uci commit luci"
  fi
  # 首启写入 root 密码（构建期生成哈希，设备上无需 openssl）。
  # sed 程序必须用单引号：哈希含 $6$salt$ 字样，双引号会在设备首启时被 shell 展开。
  echo "sed -i 's|^root:[^:]*:|root:${password_hash}:|' /etc/shadow"
} > files/etc/uci-defaults/99-h28k-setup
chmod +x files/etc/uci-defaults/99-h28k-setup

packages="$(sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$packages_list" | tr '\n' ' ')"
echo "=== 组装镜像（PROFILE=hinlink_h28k） ==="
echo "    额外软件包: ${packages:-（无）}"
make image \
  PROFILE=hinlink_h28k \
  PACKAGES="$packages" \
  FILES="$ib_dir/files" \
  ROOTFS_PARTSIZE="$rootfs_size" \
  BIN_DIR="$(cd "$out_dir" && pwd)"

out_abs="$(cd "$out_dir" && pwd)"
shopt -s nullglob
images=("$out_abs"/*hinlink_h28k*sysupgrade*.img.gz)
[[ "${#images[@]}" -gt 0 ]] || { echo "error: 未生成 sysupgrade 固件" >&2; exit 1; }
echo "=== 产物 ==="
ls -lh "${images[@]}"
