#!/usr/bin/env bash

# 定位指定版本的固件 Release（tag = h28k-v<版本>，由「H28K 固件全量构建」发布）：
#   - 校验其自建 ImageBuilder 附件（immortalwrt-imagebuilder-*.tar.zst）；
#   - 解析与该版本匹配的插件包附件（h28k-packages-v<version>.tar.gz，
#     由「H28K 插件包构建」工作流发布，可能不存在）。
# 需要 GH_TOKEN 与 GH_REPO 环境变量（工作流中由 GitHub 提供）。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
github_output="${2:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output>"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "invalid version: $version"

asset_prefix="immortalwrt-imagebuilder-rockchip-armv8."
base_tag="h28k-v$version"

urls="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq '
  .assets[] | select(.name | startswith("'"$asset_prefix"'")) | .browser_download_url' 2>/dev/null)" ||
  urls=""
ib_url="${urls%%$'\n'*}"
[[ -n "$ib_url" ]] ||
  fail "Release $base_tag 不存在或没有自建 ImageBuilder 附件，请先运行「H28K 固件全量构建」工作流"

# 匹配该版本的插件包附件（取最新发布的那个）；没有插件包时留空（组装纯官方固件）
pkg_urls="$(gh api --paginate "repos/{owner}/{repo}/releases" --jq '
  .[]
  | select(.draft == false)
  | .assets[]?
  | select(.name == "h28k-packages-v'"$version"'.tar.gz")
  | .browser_download_url')"
packages_url="${pkg_urls%%$'\n'*}"
if [[ -z "$packages_url" ]]; then
  echo "注意：未找到 $version 的插件包附件，将组装不含源码插件的固件（可在 source-plugins.list 启用插件后运行「H28K 插件包构建」）" >&2
fi

{
  echo "tag=$base_tag"
  echo "url=$ib_url"
  echo "version=$version"
  echo "packages_url=$packages_url"
} >> "$github_output"

echo "Selected base release: $base_tag"
