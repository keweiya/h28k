#!/usr/bin/env bash

# 解析插件包构建使用的 SDK 下载地址：
#   1. 优先使用基础构建（全量构建/周更）发布的自建 SDK——与固件同源同
#      feeds 状态，规避官方快照 SDK 的打包时间落后于 feed 结构调整导致的
#      依赖解析失败（libucode/liblua 等已迁移/移除的包在旧 SDK 中不可见）；
#   2. 基础 Release 尚无 SDK 附件（底包早于该机制重建）时，回退官方 SDK。
# 版本支持 X.Y.Z / X.Y-SNAPSHOT / master。需要 GH_TOKEN（缺失或查询失败
# 时自动走官方回退）。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

version="${1:-}"
github_output="${2:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output>"
[[ "$(version_kind "$version")" != "invalid" ]] ||
  fail "invalid version: $version（支持 X.Y.Z / X.Y-SNAPSHOT / master）"

rel_suffix="$version"
case "$version" in
  master|*-SNAPSHOT) ;;
  *) rel_suffix="v$version" ;;
esac

# 1) 自建 SDK：基础 Release（tag = immortalwrt-h28k-base-<版本>）的
#    immortalwrt-<版本>-h28k-base-sdk-*.tar.zst 附件，附带同源的
#    feeds.conf.default 锁定文件
sdk_asset="immortalwrt-${rel_suffix}-h28k-base-sdk-rockchip-armv8.tar.zst"
feeds_asset="immortalwrt-${rel_suffix}-h28k-base-feeds.conf.default"
base_tag="immortalwrt-h28k-base-$rel_suffix"
sdk_url=""
feeds_url=""

assets="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" \
  --jq '.assets[] | select(.name == "'"${sdk_asset}"'" or .name == "'"${feeds_asset}"'") | "\(.name) \(.browser_download_url)"' \
  2>/dev/null)" || assets=""
while read -r name url; do
  [[ -n "$name" ]] || continue
  case "$name" in
    "$sdk_asset") sdk_url="$url" ;;
    "$feeds_asset") feeds_url="$url" ;;
  esac
done <<< "${assets:-}"

if [[ -z "$sdk_url" ]]; then
  echo "注意：$base_tag 无自建 SDK 附件，回退官方 SDK（底包建议重建以获得同源 SDK）" >&2
fi

# 2) 回退：官方 SDK（rockchip/armv8）
if [[ -z "$sdk_url" ]]; then
  case "$version" in
    master) base_url="https://downloads.immortalwrt.org/snapshots" ;;
    *)      base_url="https://downloads.immortalwrt.org/releases/$version" ;;
  esac
  # 先完整捕获再取首行：管道接 head 会在 pipefail 下触发 SIGPIPE
  names="$(curl -fsSL --retry 2 "$base_url/targets/rockchip/armv8/" 2>/dev/null |
    sed -nE 's#.*href="(immortalwrt-sdk-[^"]*\.tar\.(zst|xz))".*#\1#p' |
    sort -u)" || names=""
  name="${names%%$'\n'*}"
  if [[ -z "$name" ]]; then
    fail "no SDK tarball found for $version (rockchip/armv8)"
  fi
  sdk_name="$name"
  sdk_url="$base_url/targets/rockchip/armv8/$name"
fi

{
  echo "sdk_name=$sdk_name"
  echo "sdk_url=$sdk_url"
  echo "feeds_url=$feeds_url"
} >> "$github_output"

echo "Selected SDK: $sdk_name${feeds_url:+（含同源 feeds 锁定）}"
