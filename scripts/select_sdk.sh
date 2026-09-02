#!/usr/bin/env bash

# 解析指定 ImmortalWrt 版本的官方 SDK（rockchip/armv8）下载地址。
# SDK 与固件同版本、同 musl ABI，用它编译的用户态插件 ipk 可在
# 同版本固件上直接安装。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
github_output="${2:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output>"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "invalid version: $version"

base_url="https://downloads.immortalwrt.org/releases/$version/targets/rockchip/armv8"
# 先完整捕获再取第一行：管道接 head 会在 pipefail 下触发 SIGPIPE
# 官方 24.10/25.12 的 SDK 均为 zstd（.tar.zst）压缩；兼容旧的 xz
names="$(curl -fsSL "$base_url/" |
  sed -nE 's#.*href="(immortalwrt-sdk-[^"]*\.tar\.(zst|xz))".*#\1#p' |
  sort -u)"
name="${names%%$'\n'*}"
[[ -n "$name" ]] || fail "no SDK tarball found for $version (rockchip/armv8)"

{
  echo "sdk_name=$name"
  echo "sdk_url=$base_url/$name"
} >> "$github_output"

echo "Selected SDK: $name"
