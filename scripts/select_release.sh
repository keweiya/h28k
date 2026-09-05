#!/usr/bin/env bash

# 解析要构建的 ImmortalWrt 版本，支持三种形态：
#   X.Y.Z        正式 release：源码锁 tag vX.Y.Z，feeds/内核配置/kmods/SDK 取自
#                releases/X.Y.Z/（目录不可变，ABI 校验稳定）
#   X.Y-SNAPSHOT openwrt-X.Y 分支滚动快照：官方源 releases/X.Y-SNAPSHOT/，源码锁
#                version.buildinfo 里的 revision（rNNNNN-<hash>）
#   master       master 分支滚动快照：官方源 snapshots/，源码锁 revision
# 滚动快照不做 ABI 强校验（官方产物随时被新构建覆盖，无法作为固定契约）：
# 源码锁 revision + 全量 kmod 本地捆绑保证固件自包含，与官方源的 kmod
# 兼容是尽力而为。正式版 X.Y.Z 的官方产物目录不可变，ABI 强校验照常生效。
# 具体版本只需系列在 firmware.conf 的 supported_series 内（master 始终可用）；
# 是否"已验证"由编译后的 ABI 强校验兜底，而不是靠版本白名单拦截。
# 输出：version/series/kind/tag/clone_ref/clone_commit/base_url/kernel_kmods/
#       rel_suffix/revision 供工作流后续步骤使用。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

DL_BASE="https://downloads.immortalwrt.org"

# 正式 release：kmods 目录唯一，取第一个匹配
resolve_release_kmods() {
  local base_url="$1" kmods
  # 先完整捕获再取第一行：管道接 head 会在 pipefail 下触发 SIGPIPE
  kmods="$(curl -fsSL "$base_url/targets/rockchip/armv8/kmods/" |
    sed -nE 's#.*href="([^"]*-[0-9a-f]{32})/".*#\1#p')"
  kmods="${kmods%%$'\n'*}"
  [[ "$kmods" =~ -[0-9a-f]{32}$ ]] || return 1
  printf '%s\n' "$kmods"
}

# 滚动快照：kmods/ 会累积历史内核版本的目录，必须按 profiles.json 的
# linux_kernel（内核版本 + release + vermagic 哈希）精确定位本次快照的目录
resolve_snapshot_kmods() {
  local base_url="$1" obj version release vermagic candidate
  obj="$(curl -fsSL "$base_url/targets/rockchip/armv8/profiles.json" |
    grep -oE '"linux_kernel":\{[^}]*\}' || true)"
  [[ -n "$obj" ]] || return 1
  version="$(printf '%s\n' "$obj" | sed -nE 's/.*"version":"([^"]+)".*/\1/p')"
  release="$(printf '%s\n' "$obj" | sed -nE 's/.*"release":"([^"]+)".*/\1/p')"
  vermagic="$(printf '%s\n' "$obj" | sed -nE 's/.*"vermagic":"([^"]+)".*/\1/p')"
  [[ -n "$version" && -n "$release" && -n "$vermagic" ]] || return 1
  candidate="${version}-${release}-${vermagic}"
  # 与在线 kmods 索引对账（快照站点的 href 是相对路径，直接按子串匹配），
  # 目录不存在说明官方快照正在轮换，早失败早重跑
  curl -fsSL "$base_url/targets/rockchip/armv8/kmods/" | grep -qF "$candidate/" || return 1
  printf '%s\n' "$candidate"
}

# 滚动快照：version.buildinfo 内容为源码 revision（rNNNNN-<hash>）；
# 短 hash 在克隆后于分支的浅克隆深度窗口内解析为完整 sha（见 build-base 工作流）
resolve_snapshot_revision() {
  local base_url="$1" rev
  rev="$(curl -fsSL "$base_url/targets/rockchip/armv8/version.buildinfo")"
  rev="$(trim "$rev")"
  [[ "$rev" =~ ^r[0-9]+-[0-9a-f]{6,40}$ ]] || return 1
  printf '%s\n' "$rev"
}

config_file="${1:-}"
github_output="${2:-}"
version_input="${3:-}"
[[ -n "$config_file" && -n "$github_output" && -n "$version_input" ]] ||
  fail "usage: $0 <firmware.conf> <github-output> <version>"
load_firmware_config "$config_file"

version="${version_input#v}"
kind="$(version_kind "$version")"
[[ "$kind" != "invalid" ]] ||
  fail "无法识别的版本：$version（支持 X.Y.Z / X.Y-SNAPSHOT / master）"
series="$(version_series "$version")"
series_supported "$series" ||
  fail "系列 $series 未启用（firmware.conf 的 supported_series：${supported_series[*]}；master 始终可用）"

tag=""
clone_commit=""
if [[ "$kind" == "release" ]]; then
  tag="v$version"
  clone_ref="$tag"
  base_url="$DL_BASE/releases/$version"
  kernel_kmods="$(resolve_release_kmods "$base_url")" ||
    fail "official kmods not found for $version"
  revision="$tag"
else
  case "$version" in
    master) clone_ref="master" ;;
    *)      clone_ref="openwrt-$series" ;;
  esac
  case "$version" in
    master) base_url="$DL_BASE/snapshots" ;;
    *)      base_url="$DL_BASE/releases/$version" ;;
  esac
  revision="$(resolve_snapshot_revision "$base_url")" ||
    fail "snapshot revision not found for $version"
  clone_commit="${revision##*-}"
  kernel_kmods="$(resolve_snapshot_kmods "$base_url")" ||
    fail "official kmods not resolved from profiles.json for $version"
fi

rel_suffix="$(rel_suffix_of "$version")"

# 补丁目录映射：master 当前与 25.12 板级补丁同源（已在官方快照 revision 上
# 验证干净应用），直接复用 patches/25.12；上游分化导致补丁失配时再拆出
# patches/master/ 并把这里的映射改回去
if [[ "$series" == "master" ]]; then
  patch_series="25.12"
else
  patch_series="$series"
fi

{
  echo "version=$version"
  echo "series=$series"
  echo "patch_series=$patch_series"
  echo "kind=$kind"
  echo "tag=$tag"
  echo "clone_ref=$clone_ref"
  echo "clone_commit=$clone_commit"
  echo "base_url=$base_url"
  echo "kernel_kmods=$kernel_kmods"
  echo "rel_suffix=$rel_suffix"
  echo "revision=$revision"
} >> "$github_output"

echo "Selected ImmortalWrt $kind: $version（$revision，series $series）"
