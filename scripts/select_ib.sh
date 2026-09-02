#!/usr/bin/env bash

# 选择基础固件 Release（含自建 ImageBuilder 附件），并解析与该版本匹配的
# 插件包附件（h28k-packages-v<version>.tar.gz，由「构建插件包」工作流发布）。
# 需要 GH_TOKEN 与 GH_REPO 环境变量（工作流中由 GitHub 提供）。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
github_output="${2:-}"
base_tag_input="${3:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output> [base-release-tag]"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "invalid version: $version"

asset_prefix="immortalwrt-imagebuilder-rockchip-armv8."

if [[ -n "$base_tag_input" ]]; then
  base_tag="$base_tag_input"
  urls="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq '
    .assets[] | select(.name | startswith("'"$asset_prefix"'")) | .browser_download_url')"
  ib_url="${urls%%$'\n'*}"
  [[ -n "$ib_url" ]] || fail "Release $base_tag 没有自建 ImageBuilder 附件"
else
  rows="$(gh api --paginate "repos/{owner}/{repo}/releases" --jq '
    .[]
    | select(.draft == false and (.tag_name | startswith("h28k-v'"$version"'-")))
    | select(any(.assets[]; .name | startswith("'"$asset_prefix"'")))
    | [.tag_name,
       ([.assets[] | select(.name | startswith("'"$asset_prefix"'"))][0].browser_download_url)]
    | @tsv')"
  # 先完整捕获再取第一行：管道接 head 会在 pipefail 下触发 SIGPIPE
  row="${rows%%$'\n'*}"
  [[ -n "$row" ]] || fail "no release with an ImageBuilder asset was found for series $series"
  base_tag="${row%%$'\t'*}"
  ib_url="${row##*$'\t'}"
fi

# 从标签 h28k-v<版本>-<日期> 解析版本号
ver_date="${base_tag#h28k-v}"
version="${ver_date%%-*}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "cannot parse version from release tag: $base_tag"

# 匹配该版本的插件包附件（取最新发布的那个）；没有插件包时留空（组装纯官方固件）
pkg_urls="$(gh api --paginate "repos/{owner}/{repo}/releases" --jq '
  .[]
  | select(.draft == false)
  | .assets[]?
  | select(.name == "h28k-packages-v'"$version"'.tar.gz")
  | .browser_download_url')"
packages_url="${pkg_urls%%$'\n'*}"
if [[ -z "$packages_url" ]]; then
  echo "注意：未找到 $version 的插件包附件，将组装不含源码插件的固件（可在 source-plugins.list 启用插件后运行「构建插件包」）" >&2
fi

{
  echo "tag=$base_tag"
  echo "url=$ib_url"
  echo "version=$version"
  echo "packages_url=$packages_url"
} >> "$github_output"

echo "Selected base release with ImageBuilder: $base_tag"
