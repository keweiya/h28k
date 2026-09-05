#!/usr/bin/env bash

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

# 用法：apply_patches.sh <source-dir> <patches-dir> <series>
#   series = 24.10 / 25.12（master 构建由调用方映射为 25.12）
# 补丁目录为单层结构，命名规则：<序号>-<功能>.<系列>.patch
#   - 序号决定应用顺序（字典序）
#   - -v<系列> 后缀决定适用范围：仅应用与 series 匹配的补丁；
#     未知系列后缀视为命名错误，直接失败（防止补丁被静默跳过）

source_dir="${1:-}"
patch_dir="${2:-}"
series="${3:-}"
[[ -n "$source_dir" && -n "$patch_dir" && -n "$series" ]] ||
  fail "usage: $0 <source-dir> <patches-dir> <series>"
[[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
[[ -d "$patch_dir" ]] || fail "patch directory not found: $patch_dir"
case "$series" in
  24.10|25.12) ;;
  *) fail "unknown series: $series（master 构建应映射为 25.12）" ;;
esac

cd "$source_dir"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
[[ "${#patches[@]}" -gt 0 ]] || fail "no patches found: $patch_dir"

applied=0
for patch in "${patches[@]}"; do
  base="$(basename "$patch" .patch)"
  # 系列后缀取自文件名末段（.24.10 / .25.12）；不能用 ${base##*.}——版本号本身带点
  case "$base" in
    *-v24.10) scope="24.10" ;;
    *-v25.12) scope="25.12" ;;
    *) fail "补丁 $base 的系列后缀无法识别（应为 -v24.10 或 -v25.12）" ;;
  esac
  [[ "$scope" == "$series" ]] || continue
  echo "=== Applying patch: $(basename "$patch") ==="
  git apply --check --3way "$patch" || {
    echo "Patch check failed: $patch"
    git apply --reject "$patch" || true
    find . -name '*.rej' -print -exec cat {} \;
    exit 1
  }
  git apply --3way "$patch"
  applied=$((applied + 1))
done

[[ "$applied" -gt 0 ]] || fail "系列 $series 没有匹配到任何补丁（补丁后缀与系列不一致？）"
echo "=== 共应用 $applied 个补丁（系列 $series）==="
git diff --stat
