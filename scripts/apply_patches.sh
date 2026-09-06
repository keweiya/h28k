#!/usr/bin/env bash

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

# 用法：apply_patches.sh <source-dir> <patches-dir> <series>
#   series = 24.10 / 25.12 / master
# 补丁目录为单层结构，命名规则：<序号>-<功能>.<系列>.patch
#   - 序号决定应用顺序（字典序）
#   - -v<系列> 后缀决定适用范围：仅应用与 series 匹配的补丁；
#     未知系列后缀视为命名错误，直接失败（防止补丁被静默跳过）
#   - master 源码树沿用 25.12 系列补丁（同源）+ -vmaster 专属补丁
#     （如上游删除的 kmod 定义恢复）

source_dir="${1:-}"
patch_dir="${2:-}"
series="${3:-}"
[[ -n "$source_dir" && -n "$patch_dir" && -n "$series" ]] ||
  fail "usage: $0 <source-dir> <patches-dir> <series>"
[[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
[[ -d "$patch_dir" ]] || fail "patch directory not found: $patch_dir"
case "$series" in
  24.10|25.12|master) ;;
  *) fail "unknown series: $series" ;;
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
    *-vmaster) scope="master" ;;
    *) fail "补丁 $base 的系列后缀无法识别（应为 -v24.10 / -v25.12 / -vmaster）" ;;
  esac
  # master 源码树 = 25.12 系列补丁（同源）+ master 专属补丁
  [[ "$scope" == "$series" || ( "$series" == "master" && "$scope" == "25.12" ) ]] || continue
  echo "=== Applying patch: $(basename "$patch") ==="
  # 浅克隆（--depth=1 / --filter=blob:none）常缺补丁 index 行引用的旧 blob，
  # --3way 会报 "repository lacks the necessary blob"——但这不代表补丁冲突，
  # 源码其他位置演进而补丁上下文未动时，纯 git apply 仍可干净应用；
  # 两级检查都失败才是真冲突，才走 --reject 展示 .rej 并失败
  if git apply --check --3way "$patch" 2>/dev/null; then
    git apply --3way "$patch"
  elif git apply --check "$patch" 2>/dev/null; then
    echo "    3way 所需 blob 不在浅克隆内，已退回直接应用: $(basename "$patch")"
    git apply "$patch"
  else
    echo "Patch check failed: $patch"
    git apply --reject "$patch" || true
    find . -name '*.rej' -print -exec cat {} \;
    exit 1
  fi
  applied=$((applied + 1))
done

[[ "$applied" -gt 0 ]] || fail "系列 $series 没有匹配到任何补丁（补丁后缀与系列不一致？）"
echo "=== 共应用 $applied 个补丁（系列 $series）==="
git diff --stat
