#!/usr/bin/env bash

# 解析版本选择为构建矩阵的版本 JSON 列表：
#   - all：静态集合 = firmware.conf 的 supported_versions（与各工作流的版本
#     下拉选项保持一致），不在线枚举官方源、不自动纳入新发布的点版本。
#   - X.Y（如 24.10 / 25.12）：系列矩阵——仅枚举该系列的 X.Y.Z 正式版与
#     X.Y-SNAPSHOT（不含 master）。
#   - 具体版本：X.Y.Z / X.Y-SNAPSHOT / master-SNAPSHOT（归一化为 master），
#     系列须在 supported_series 内。
# 同时输出 latest（静态集合中最新的正式版），工作流用它决定哪个 Release 标
# --latest，滚动快照永不抢占。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

DL_BASE="https://downloads.immortalwrt.org"

# 在线枚举官方源的支持版本：filter 为空时遍历全部 supported_series（正式版
# 全局按版本倒序、X.Y-SNAPSHOT 殿后、master 最后）；指定系列时只枚举该系列
# 的 X.Y.Z 与 X.Y-SNAPSHOT（不含 master）
enumerate_official_versions() {
  local filter="${1:-}" listing series
  # 注意：本函数在 < <(...) 进程替换子 shell 里运行，这里不能 exit（fail 会
  # 静默终止子 shell 而主流程无感知地走兜底），统一用 warning + 非零返回表达
  listing="$(curl -fsSL --retry 3 --max-time 60 "$DL_BASE/releases/" 2>/dev/null)" || {
    echo "::warning::无法访问官方源 $DL_BASE/releases/（在线枚举失败），将回退到静态列表" >&2
    return 1
  }
  [[ -n "$listing" ]] || {
    echo "::warning::官方源 releases/ 页面解析为空，将回退到静态列表" >&2
    return 1
  }
  {
    for series in "${supported_series[@]}"; do
      if [[ -n "$filter" && "$series" != "$filter" ]]; then
        continue
      fi
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
    if [[ -n "$filter" && "$series" != "$filter" ]]; then
      continue
    fi
    if printf '%s\n' "$listing" | grep -qF "href=\"$series-SNAPSHOT/\""; then
      printf '%s\n' "$series-SNAPSHOT"
    fi
  done
  [[ -z "$filter" ]] && printf '%s\n' master
  return 0
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
no_rolling="${4:-}"
[[ -n "$conf" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <version|all> <github-output> [no_rolling]"
load_firmware_config "$conf"

# 下拉选项显示为 master-SNAPSHOT（与 X.Y-SNAPSHOT 命名一致），内部统一为 master
version_input="${version_input/master-SNAPSHOT/master}"

# no_rolling=true：排除滚动版本（master / X.Y-SNAPSHOT）——供 build-custom
# 使用，滚动版本的固件由 build-weekly 的周更包承载，不再单独出 custom Release
filter_no_rolling() {
  printf '%s\n' "$@" | grep -vE '^(master|.*-SNAPSHOT)$' || true
}

latest_pool=""

if [[ -n "$version_input" && "$version_input" != "all" ]]; then
  version="${version_input#v}"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    # 系列矩阵：该系列的全部正式版与分支快照（不含 master）
    series_supported "$version" ||
      fail "系列 $version 未启用（firmware.conf 的 supported_series：${supported_series[*]}）"
    if mapfile -t sorted < <(enumerate_official_versions "$version") &&
       (( ${#sorted[@]} >= 1 )); then
      echo "系列 $version：在线枚举到 ${#sorted[@]} 个版本"
    else
      echo "::warning::系列 $version 的在线枚举失败，回退到 supported_versions 静态列表" >&2
      mapfile -t sorted < <(static_versions)
    fi
    # latest 取静态集合中最新的正式版，系列矩阵不会抢占 --latest
    latest_pool="static"
  else
    [[ "$(version_kind "$version")" != "invalid" ]] ||
      fail "无法识别的版本：$version（支持 X.Y.Z / X.Y-SNAPSHOT / master / X.Y 系列矩阵 / all）"
    if version_excluded "$version"; then
      fail "版本 $version 在排除名单中（firmware.conf 的 excluded_versions）：上游 24.10.1 才引入 phy-leds 脚本，24.10.0 无法应用板级补丁，请改用 24.10.1 及以上"
    fi
    series="$(version_series "$version")"
    series_supported "$series" ||
      fail "系列 $series 未启用（firmware.conf 的 supported_series：${supported_series[*]}）"
    mapfile -t sorted < <(printf '%s\n' "$version")
    latest_pool="static"
  fi
else
  # all：只构建与工作流下拉选项一致的静态集合（firmware.conf 的
  # supported_versions），不在线枚举官方源——官方新发布的点版本需先加入
  # 各工作流的版本选项并完成全量构建（产出底包），否则组装会 404
  mapfile -t sorted < <(static_versions)
  latest_pool="static"
fi

# latest = 静态集合中最新的正式版（all 与单版本/系列矩阵一致），避免旧版本
# 或单一系列误标 --latest
mapfile -t pool < <(static_versions)
latest=""
for v in "${pool[@]}"; do
  [[ "$(version_kind "$v")" == "release" ]] || continue
  latest="$v"
  break
done

if [[ "$no_rolling" == "true" ]]; then
  mapfile -t sorted < <(filter_no_rolling "${sorted[@]}")
  if (( ${#sorted[@]} == 0 )); then
    fail "排除滚动版本后无待构建版本；滚动版本的固件由 build-weekly 周更包承载"
  fi
fi

json=''
for v in "${sorted[@]}"; do
  json+="\"$v\","
done
printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
printf 'latest=%s\n' "$latest" >> "$github_output"
