#!/usr/bin/env bash

# 解析版本选择为构建矩阵的版本 JSON 列表：
#   - all：在线枚举官方源当前发布的全部支持版本——supported_series 各系列的
#     所有 X.Y.Z 正式版与 X.Y-SNAPSHOT 分支快照（排除 excluded_versions），加
#     master。官方新发布的点版本自动纳入，无需改配置；枚举失败时回退到
#     firmware.conf 的 supported_versions 静态列表并告警。
#   - 具体版本：X.Y.Z / X.Y-SNAPSHOT / master，系列须在 supported_series 内。
# 同时输出 latest（其中最新的正式版），工作流用它决定哪个 Release 标
# --latest，滚动快照永不抢占。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

DL_BASE="https://downloads.immortalwrt.org"

# 在线枚举官方源的全部支持版本：各系列的 X.Y.Z 正式版全局按版本倒序、
# X.Y-SNAPSHOT 分支快照（目录存在才纳入）殿后，排除名单过滤，master 最后
enumerate_official_versions() {
  local listing series
  listing="$(curl -fsSL --retry 3 --max-time 60 "$DL_BASE/releases/")" ||
    fail "无法访问官方源 $DL_BASE/releases/（all 在线枚举失败）"
  {
    for series in "${supported_series[@]}"; do
      printf '%s\n' "$listing" |
        grep -oE "href=\"$series\.[0-9]+/\"" |
        sed -E "s#href=\"($series\.[0-9]+)/\"#\1#" || true
    done | sort -uVr
  } | while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if version_excluded "$v"; then
      echo "枚举跳过排除名单中的版本：$v" >&2
      continue
    fi
    printf '%s\n' "$v"
  done
  for series in "${supported_series[@]}"; do
    if printf '%s\n' "$listing" | grep -qF "href=\"$series-SNAPSHOT/\""; then
      printf '%s\n' "$series-SNAPSHOT"
    fi
  done
  printf '%s\n' master
}

# 静态兜底：supported_versions 展开为正式版倒序在前、滚动快照殿后
static_versions() {
  for v in "${supported_versions[@]}"; do
    [[ "$(version_kind "$v")" == "release" ]] && printf '%s\n' "$v"
  done | sort -Vr
  for v in "${supported_versions[@]}"; do
    [[ "$(version_kind "$v")" == "snapshot" ]] && printf '%s\n' "$v"
  done | sort
}

conf="${1:-}"
version_input="${2:-}"
github_output="${3:-}"
[[ -n "$conf" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <version|all> <github-output>"
load_firmware_config "$conf"

if [[ -n "$version_input" && "$version_input" != "all" ]]; then
  version="${version_input#v}"
  [[ "$(version_kind "$version")" != "invalid" ]] ||
    fail "无法识别的版本：$version（支持 X.Y.Z / X.Y-SNAPSHOT / master 或 all）"
  series="$(version_series "$version")"
  series_supported "$series" ||
    fail "系列 $series 未启用（firmware.conf 的 supported_series：${supported_series[*]}）"
  mapfile -t sorted < <(printf '%s\n' "$version")
  # 单版本构建的 latest 取静态集合里最新的正式版，避免旧版本误标 --latest
  mapfile -t latest_pool < <(static_versions)
else
  if mapfile -t sorted < <(enumerate_official_versions) &&
     (( ${#sorted[@]} >= 1 )); then
    echo "all：在线枚举到 ${#sorted[@]} 个支持版本（新发布的点版本已自动纳入）"
  else
    echo "::warning::all 的在线枚举失败，回退到 firmware.conf 的 supported_versions 静态列表" >&2
    mapfile -t sorted < <(static_versions)
  fi
  mapfile -t latest_pool < <(printf '%s\n' "${sorted[@]}")
fi

# latest = 候选池中最新的正式版（倒序排列时即第一个 release 条目）
latest=""
for v in "${latest_pool[@]}"; do
  [[ "$(version_kind "$v")" == "release" ]] || continue
  latest="$v"
  break
done

json=''
for v in "${sorted[@]}"; do
  json+="\"$v\","
done
printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
printf 'latest=%s\n' "$latest" >> "$github_output"
