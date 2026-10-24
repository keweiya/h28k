#!/usr/bin/env bash

# 定位指定版本的基础固件 Release（tag = immortalwrt-h28k-base-v<版本>，
# 由「H28K 固件全量构建」发布）：
#   - 校验其自建 ImageBuilder 附件（immortalwrt-v<版本>-h28k-base-imagebuilder-*.tar.zst）。
# 需要 GH_TOKEN 环境变量（工作流中由 GitHub 提供）。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

version="${1:-}"
github_output="${2:-}"
[[ -n "$version" && -n "$github_output" ]] ||
  fail "usage: $0 <version> <github-output>"
case "$version" in
  master|*-SNAPSHOT|[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "invalid version: $version（支持 X.Y.Z / X.Y-SNAPSHOT / master）" ;;
esac
# 下拉选项显示为 master-SNAPSHOT，内部统一为 master（底包 tag 沿用
# immortalwrt-h28k-base-master，已有 Release 不受影响）
version="${version/master-SNAPSHOT/master}"
rel_suffix="$version"
case "$version" in
  master|*-SNAPSHOT) ;;
  *) rel_suffix="v$version" ;;
esac

base_tag="immortalwrt-h28k-base-$rel_suffix"
ib_name="immortalwrt-${rel_suffix}-h28k-base-imagebuilder-rockchip-armv8.tar.zst"
ib_prefix="immortalwrt-${rel_suffix}-h28k-base-imagebuilder-"

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

# 滚动版本（master/SNAPSHOT）的底包会随官方 snapshots 源轮换而失效：底包捆绑
# 的包依赖的 ABI 版本库（如 libubusYYYYMMDD）被官方源换新后，组装将报
# "unable to select packages"。对底包 ImageBuilder 附件的更新时间做老化检查，
# 超期时提醒先重建底包（正式版 X.Y.Z 的源不可变，无此问题）
if [[ "$version" == master || "$version" == *-SNAPSHOT ]]; then
  ib_updated="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq \
    '.assets[] | select(.name == "'"${ib_name}"'" or (.name | startswith("'"${ib_prefix}"'"))) | .updated_at' \
    2>/dev/null | head -n1)"
  if [[ -n "$ib_updated" ]]; then
    age_days=$(( ( $(date +%s) - $(date -d "$ib_updated" +%s) ) / 86400 ))
    echo "底包 ImageBuilder 更新于 $ib_updated（距今 $age_days 天）"
    if (( age_days >= 2 )); then
      echo "⚠️ 滚动版本的底包已 $age_days 天未重建。官方 snapshots 源会轮换依赖包，" >&2
      echo "   旧底包组装可能报 unable to select packages（no such package）；建议先重跑「H28K 固件全量构建」刷新底包" >&2
    fi
  fi
fi


{
  echo "tag=$base_tag"
  echo "url=$ib_url"
  echo "version=$version"
  echo "rel_suffix=$rel_suffix"
} >> "$github_output"

echo "Selected base release: $base_tag"
