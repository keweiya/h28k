#!/usr/bin/env bash

# 过滤"上游无更新"的版本，避免重复编译底包（build-base 工作流专用）：
#   - X.Y.Z 正式版：官方源不可变（tag 永不变化），底包 Release 已存在且带
#     ImageBuilder 附件即跳过
#   - master / X.Y-SNAPSHOT 滚动快照：官方 snapshots/releases 源会滚动轮换，
#     比对官方当前 revision（version.buildinfo）与上次构建记录在 Release 正文
#     （"上游版本"：rNNNNN-hash）中的 revision；一致且补丁指纹未变则跳过。
#     官方源不可达等无法证明"未更新"的情形一律保守重建
# 补丁指纹 = patches/*.patch 的排序 sha256，构建时写入 Release 正文；指纹
# 变化（改过补丁）即使上游未推进也会重建
# force=true 时不过滤，全部保留（输出原列表）。
# 用法：filter_unchanged_versions.sh <firmware.conf> <patches-dir> <versions-json> <github-output>
# 依赖：gh（GH_TOKEN）、curl；输出 versions（过滤后 JSON）与 skipped（说明）

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

conf="${1:-}"
patches_dir="${2:-}"
versions_json="${3:-}"
github_output="${4:-}"
[[ -n "$conf" && -n "$patches_dir" && -n "$versions_json" && -n "$github_output" ]] ||
  fail "usage: $0 <firmware.conf> <patches-dir> <versions-json> <github-output>"
load_firmware_config "$conf"

force="${FORCE:-false}"
patch_hash="$(find "$patches_dir" -type f -name '*.patch' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
echo "补丁指纹：$patch_hash"

DL_BASE="https://downloads.immortalwrt.org"

# 官方当前 revision（仅滚动快照有；正式版官方源不可变无此概念）
official_revision() {
  local v="$1" url rev
  case "$v" in
    master) url="$DL_BASE/snapshots/targets/rockchip/armv8/version.buildinfo" ;;
    *-SNAPSHOT) url="$DL_BASE/releases/$v/targets/rockchip/armv8/version.buildinfo" ;;
    *) return 1 ;;
  esac
  rev="$(curl -fsSL --retry 2 --max-time 60 "$url" 2>/dev/null | tr -d '[:space:]')"
  [[ "$rev" =~ ^r[0-9]+-[0-9a-f]{6,40}$ ]] || return 1
  printf '%s\n' "$rev"
}

# 从 Release 正文解析上次构建记录：上游 revision 与补丁指纹
body_field() {
  local body="$1" key="$2" pattern="$3" hit
  hit="$(printf '%s\n' "$body" | grep "$key" | grep -oE "$pattern" | head -n1)" || hit=""
  printf '%s\n' "$hit"
}

mapfile -t versions < <(printf '%s' "$versions_json" | sed -E 's/^\[//; s/\]$//; s/"//g' | tr ',' '\n')

keep=()
skipped=""
for v in "${versions[@]}"; do
  [[ -n "$v" ]] || continue
  # 下拉选项显示为 master-SNAPSHOT，内部统一为 master（底包 tag 沿用 master 后缀）
  v="${v/master-SNAPSHOT/master}"
  rel="$(rel_suffix_of "$v")"
  base_tag="immortalwrt-h28k-base-$rel"
  ib_name="immortalwrt-${rel}-h28k-base-imagebuilder-rockchip-armv8.tar.zst"
  ib_prefix="immortalwrt-${rel}-h28k-base-imagebuilder-"

  if [[ "$force" == "true" ]]; then
    echo "$v：force=true，跳过校验强制重建"
    keep+=("$v")
    continue
  fi

  rel_json="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" 2>/dev/null)" || rel_json=""
  if [[ -z "$rel_json" ]]; then
    echo "$v：底包 Release $base_tag 不存在 → 构建"
    keep+=("$v")
    continue
  fi

  ib_asset="$(printf '%s' "$rel_json" | grep -oE '"name": *"[^"]*h28k-base-imagebuilder[^"]*"' | head -n1)" || ib_asset=""
  if [[ -z "$ib_asset" ]]; then
    echo "$v：底包存在但缺 ImageBuilder 附件 → 构建"
    keep+=("$v")
    continue
  fi

  body="$(gh api "repos/{owner}/{repo}/releases/tags/$base_tag" --jq '.body' 2>/dev/null)" || body=""
  recorded_rev="$(body_field "$body" '上游版本' 'r[0-9]+-[0-9a-f]{6,40}')"
  recorded_hash="$(body_field "$body" '补丁指纹' '[0-9a-f]{64}')"

  if [[ "$(version_kind "$v")" == "release" ]]; then
    echo "$v：正式版官方源不可变，底包已存在 → 跳过"
    skipped+="$v(官方源不可变) "
    continue
  fi

  if [[ -n "$recorded_hash" && "$recorded_hash" != "$patch_hash" ]]; then
    echo "$v：补丁指纹已变化（${recorded_hash:0:12}… → ${patch_hash:0:12}…）→ 重建"
    keep+=("$v")
    continue
  fi

  cur_rev="$(official_revision "$v")" || cur_rev=""
  if [[ -z "$cur_rev" ]]; then
    echo "$v：无法获取官方当前 revision（官方源不可达？）→ 保守重建"
    keep+=("$v")
    continue
  fi

  if [[ -n "$recorded_rev" && "$recorded_rev" == "$cur_rev" ]]; then
    echo "$v：官方 revision 未变（$cur_rev）且补丁指纹一致 → 跳过"
    skipped+="$v(官方无更新) "
    continue
  fi

  echo "$v：官方 revision 已推进（${recorded_rev:-未知} → $cur_rev）→ 重建"
  keep+=("$v")
done

# 全部被过滤时输出哨兵值 "skip"（配合编译 job 的 if 条件跳过）：GitHub 对
# 空矩阵会把整个 run 标记为失败，不能输出空数组
if (( ${#keep[@]} == 0 )); then
  echo "::warning::所有版本上游均无更新，本次不重建任何底包"
  printf 'versions=["skip"]\n' >> "$github_output"
else
  json=''
  for v in "${keep[@]}"; do
    json+="\"$v\","
  done
  printf 'versions=[%s]\n' "${json%,}" >> "$github_output"
fi
printf 'skipped=%s\n' "${skipped:-（无）}" >> "$github_output"
