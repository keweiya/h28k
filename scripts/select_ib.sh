#!/usr/bin/env bash

# 选择最新的、附带自建 ImageBuilder 附件的本仓库 Release。
# 需要 GH_TOKEN 与 GH_REPO 环境变量（工作流中由 GitHub 提供）。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

series="${1:-}"
github_output="${2:-}"
[[ -n "$series" && -n "$github_output" ]] ||
  fail "usage: $0 <series> <github-output>"
[[ "$series" =~ ^(24\.10|25\.12)$ ]] ||
  fail "unsupported release series: $series"

asset_prefix="immortalwrt-imagebuilder-rockchip-armv8."

rows="$(gh api --paginate "repos/{owner}/{repo}/releases" --jq '
  .[]
  | select(.draft == false and (.tag_name | startswith("h28k-v'"$series"'.")))
  | select(any(.assets[]; .name | startswith("'"$asset_prefix"'")))
  | [.tag_name,
     ([.assets[] | select(.name | startswith("'"$asset_prefix"'"))][0].browser_download_url)]
  | @tsv')"
# 先完整捕获再取第一行：管道接 head 会在 pipefail 下触发 SIGPIPE
row="${rows%%$'\n'*}"

[[ -n "$row" ]] || fail "no release with an ImageBuilder asset was found for series $series"

tag="${row%%$'\t'*}"
asset_url="${row##*$'\t'}"
{
  echo "tag=$tag"
  echo "asset_url=$asset_url"
} >> "$github_output"

echo "Selected base release with ImageBuilder: $tag"
