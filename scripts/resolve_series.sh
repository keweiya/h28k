#!/usr/bin/env bash

# 把 Actions 手动触发参数解析成构建矩阵的系列 JSON 列表：
#   - 未指定精确版本时，all 输出全部支持的系列，否则输出所选系列；
#   - 指定精确版本（如 v24.10.6 / 25.12.1）时只构建该版本所属的系列。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

known_series="24.10 25.12"
is_known_series() { [[ " $known_series " == *" $1 "* ]]; }

series_input="${1:-all}"
exact_version="${2:-}"
github_output="${3:-}"
[[ -n "$github_output" ]] || fail "usage: $0 <series|all> [exact-version] <github-output>"

if [[ -n "$exact_version" ]]; then
  version="${exact_version#v}"
  [[ "$version" =~ ^(24\.10|25\.12)\.[0-9]+$ ]] ||
    fail "exact version must look like 24.10.x or 25.12.x: $exact_version"
  series="${version%.*}"
  if [[ -n "$series_input" && "$series_input" != "all" &&
        "$series_input" != "$series" ]]; then
    fail "exact version $version does not belong to series $series_input"
  fi
  printf 'series=["%s"]\n' "$series" >> "$github_output"
  exit 0
fi

if [[ -z "$series_input" || "$series_input" == "all" ]]; then
  json="$(printf '"%s",' $known_series)"
  printf 'series=[%s]\n' "${json%,}" >> "$github_output"
elif is_known_series "$series_input"; then
  printf 'series=["%s"]\n' "$series_input" >> "$github_output"
else
  fail "unsupported series: $series_input (known: $known_series)"
fi
