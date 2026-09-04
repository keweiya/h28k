#!/usr/bin/env bash

# 定位指定版本的基础固件 Release（tag = immortalwrt-h28k-base-v<版本>，
# 由「H28K 固件全量构建」发布）：
#   - 校验其自建 ImageBuilder 附件（immortalwrt-v<版本>-h28k-base-imagebuilder-*.tar.zst）；
#   - 解析与该版本匹配的插件包附件（immortalwrt-v<版本>-h28k-packages.tar.gz，
#     位于独立的 tag = immortalwrt-h28k-packages-v<版本> Release，
#     由「H28K 插件包构建」工作流发布，可能不存在）。
# 需要 GH_TOKEN 环境变量（工作流中由 GitHub 提供）。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
github_output="${2:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output>"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "invalid version: $version"

base_tag="immortalwrt-h28k-base-v$version"
ib_name="immortalwrt-v${version}-h28k-base-imagebuilder-rockchip-armv8.tar.zst"
ib_prefix="immortalwrt-v${version}-h28k-base-imagebuilder-"
pkg_name="immortalwrt-v${version}-h28k-packages.tar.gz"

# 1) Release 是否存在：失败时如实打印 gh 的真实报错，不再吞成同一句话
api_err="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" 2>&1 >/dev/null)" || true
if [[ -n "$api_err" ]]; then
  fail "Release $base_tag 不存在或无法访问（$(printf '%s' "$api_err" | head -n1)）。请先运行「H28K 固件全量构建」工作流"
fi

# 2) ImageBuilder 附件：精确名优先，回退同前缀（管道接 head 会因 pipefail 触发
#    SIGPIPE，故沿用 ${var%%$'\n'*} 取首行的仓库约定）
ib_urls="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq \
  '.assets[] | select(.name == "'"${ib_name}"'" or (.name | startswith("'"${ib_prefix}"'"))) | .browser_download_url' \
  2>/dev/null)" || ib_urls=""
ib_url="${ib_urls%%$'\n'*}"
if [[ -z "$ib_url" ]]; then
  assets="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq '[.assets[].name] | join("、")' 2>/dev/null)" || assets="(读取附件列表失败)"
  fail "Release $base_tag 存在但没有自建 ImageBuilder 附件（期望 ${ib_name}）。实际附件：${assets}。请重新运行「H28K 固件全量构建」工作流"
fi

# 3) 插件包附件（独立 Packages Release，可能尚未发布）：没有时留空（组装纯官方固件）
pkg_urls="$(gh api "repos/{owner}/{repo}/releases/tags/immortalwrt-h28k-packages-v$version" --jq \
  '.assets[] | select(.name == "'"${pkg_name}"'") | .browser_download_url' \
  2>/dev/null)" || pkg_urls=""
pkg_url="${pkg_urls%%$'\n'*}"
if [[ -z "$pkg_url" ]]; then
  echo "注意：未找到 $version 的插件包附件，将组装不含源码插件的固件（可在 config/source-plugins.list 启用插件后运行「H28K 插件包构建」工作流）" >&2
fi

{
  echo "tag=$base_tag"
  echo "url=$ib_url"
  echo "version=$version"
  echo "packages_url=$pkg_url"
} >> "$github_output"

echo "Selected base release: $base_tag"
