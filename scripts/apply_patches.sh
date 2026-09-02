#!/usr/bin/env bash

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

source_dir="${1:-}"
patch_dir="${2:-}"
[[ -n "$source_dir" && -n "$patch_dir" ]] ||
  fail "usage: $0 <source-dir> <patch-dir>"
[[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
[[ -d "$patch_dir" ]] || fail "patch directory not found: $patch_dir"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
[[ "${#patches[@]}" -gt 0 ]] || fail "no patches found: $patch_dir"

cd "$source_dir"
for patch in "${patches[@]}"; do
  echo "=== Applying patch: $(basename "$patch") ==="
  git apply --check --3way "$patch" || {
    echo "Patch check failed: $patch"
    git apply --reject "$patch" || true
    find . -name '*.rej' -print -exec cat {} \;
    exit 1
  }
  git apply --3way "$patch"
done

git diff --stat
