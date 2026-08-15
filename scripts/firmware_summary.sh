#!/usr/bin/env bash

set -euo pipefail

out_file="${1:?summary output file required}"
manifest_file="${2:-}"
requested_file="${3:-}"
third_party_failed_file="${4:-}"
summary_requested_file="${5:-}"

mkdir -p "$(dirname "$out_file")"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

all_pkgs="$tmp_dir/all-packages.txt"
requested_pkgs="$tmp_dir/requested-packages.txt"
summary_requested_pkgs="$tmp_dir/summary-requested-packages.txt"
summary_installed_pkgs="$tmp_dir/summary-installed-packages.txt"
install_failed_pkgs="$tmp_dir/install-failed-packages.txt"
third_party_failed_pkgs="$tmp_dir/third-party-build-failed.txt"

: > "$all_pkgs"
: > "$requested_pkgs"
: > "$summary_requested_pkgs"
: > "$summary_installed_pkgs"
: > "$install_failed_pkgs"
: > "$third_party_failed_pkgs"

if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
  awk '{print $1}' "$manifest_file" \
    | sed '1s/^\xEF\xBB\xBF//; /^$/d' \
    | sort -u > "$all_pkgs"
fi

if [[ -n "$requested_file" && -f "$requested_file" ]]; then
  awk '{for (i = 1; i <= NF; i++) print $i}' "$requested_file" \
    | sed '1s/^\xEF\xBB\xBF//; /^$/d; /^-/d' \
    | sort -u > "$requested_pkgs"
fi

if [[ -n "$summary_requested_file" && -f "$summary_requested_file" ]]; then
  awk '{for (i = 1; i <= NF; i++) print $i}' "$summary_requested_file" \
    | sed '1s/^\xEF\xBB\xBF//; /^$/d; /^-/d' \
    | sort -u > "$summary_requested_pkgs"
fi

if [[ -n "$third_party_failed_file" && -f "$third_party_failed_file" ]]; then
  sed '1s/^\xEF\xBB\xBF//; /^$/d' "$third_party_failed_file" \
    | sort -u > "$third_party_failed_pkgs"
fi

# ImageBuilder 可能没有产出 manifest；此时至少按请求安装列表写摘要，
# 但不生成“安装失败/已跳过”差集，避免误报。
if [[ ! -s "$all_pkgs" && -s "$requested_pkgs" ]]; then
  cp "$requested_pkgs" "$all_pkgs"
fi

# 编译总结只展示本仓库明确额外安装的包，不展示上游 profile / 默认构建自带包。
# 存在 manifest 时仅展示“明确额外安装且最终进入固件”的交集；没有 manifest 时退化为
# 展示明确额外安装列表本身，避免把完整默认包列表写进 Release 总结。
if [[ -s "$summary_requested_pkgs" ]]; then
  if [[ -s "$all_pkgs" ]]; then
    comm -12 "$summary_requested_pkgs" "$all_pkgs" > "$summary_installed_pkgs" || true
  else
    cp "$summary_requested_pkgs" "$summary_installed_pkgs"
  fi
elif [[ -s "$requested_pkgs" ]]; then
  if [[ -s "$all_pkgs" ]]; then
    comm -12 "$requested_pkgs" "$all_pkgs" > "$summary_installed_pkgs" || true
  else
    cp "$requested_pkgs" "$summary_installed_pkgs"
  fi
else
  cp "$all_pkgs" "$summary_installed_pkgs"
fi

# 只有存在 manifest 时，才能可靠判断请求包是否最终进入固件。若提供了“总结显示包
# 列表”，失败/跳过列表同样只统计这些额外安装包，避免默认包混入 Release 总结。
if [[ -n "$manifest_file" && -s "$manifest_file" && -s "$all_pkgs" ]]; then
  if [[ -s "$summary_requested_pkgs" ]]; then
    comm -23 "$summary_requested_pkgs" "$all_pkgs" > "$install_failed_pkgs" || true
  elif [[ -s "$requested_pkgs" ]]; then
    comm -23 "$requested_pkgs" "$all_pkgs" > "$install_failed_pkgs" || true
  fi
fi

category_file() {
  local name="$1"
  echo "$tmp_dir/$name.txt"
}

classify_pkg() {
  local pkg="$1"
  case "$pkg" in
    kmod-*) echo "drivers" ;;
    luci-theme-*) echo "themes" ;;
    luci-app-*|luci-i18n-*) echo "luci" ;;
    *firmware*|wireless-regdb) echo "firmware" ;;
    *)
      if [[ -s "$summary_installed_pkgs" ]] && grep -Fxq "$pkg" "$summary_installed_pkgs"; then
        if grep -Fxq "luci-app-$pkg" "$summary_installed_pkgs"; then
          echo ""
          return 0
        fi
        echo "software"
      else
        echo ""
      fi
      ;;
  esac
}

for category in firmware drivers themes luci software; do
  : > "$(category_file "$category")"
done

while IFS= read -r pkg || [[ -n "$pkg" ]]; do
  [[ -n "$pkg" ]] || continue
  category="$(classify_pkg "$pkg")"
  [[ -n "$category" ]] || continue
  echo "$pkg" >> "$(category_file "$category")"
done < "$summary_installed_pkgs"

for category in firmware drivers themes luci software; do
  sort -u "$(category_file "$category")" -o "$(category_file "$category")" || true
done

write_category() {
  local title="$1" file="$2"
  [[ -s "$file" ]] || return 0
  {
    printf '\n### %s\n' "$title"
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
      [[ -n "$pkg" ]] || continue
      printf -- '- `%s`\n' "$pkg"
    done < "$file"
  } >> "$out_file"
}

{
  printf '## HINLINK H28K 固件\n\n'
  printf -- '- **编译日期**：%s\n' "${BUILD_DATE:-未知}"
  printf -- '- **上游版本**：%s%s\n' "${RELEASE_TAG:-未知}" "${UPSTREAM_HASH:+ (${UPSTREAM_HASH})}"
  printf -- '- **设备型号**：HINLINK H28K (RK3528)\n'
  printf -- '- **RootFS**：%s\n' "${ROOTFS_PARTSIZE_LABEL:-未知}"
  printf -- '- **管理地址**：`%s`\n' "${FIRMWARE_LAN_IP:-未知}"
  printf -- '- **root 密码**：`%s`\n' "${FIRMWARE_PASSWORD:-未设置}"
  if [[ -n "${IMAGEBUILDER_IMAGE:-}" ]]; then
    printf -- '- **ImageBuilder**：`%s`\n' "$IMAGEBUILDER_IMAGE"
  fi
  if [[ -n "${WORKING_MIRROR:-}" ]]; then
    printf -- '- **镜像源**：`%s`\n' "$WORKING_MIRROR"
  fi
  if [[ -n "${OFFICIAL_KERNEL:-}" ]]; then
    printf -- '- **官方内核**：`%s`\n' "$OFFICIAL_KERNEL"
  fi
  printf -- '- **内核 ABI**：`%s`\n' "${KERNEL_ABI:-未知}"
} > "$out_file"

write_category "额外安装固件" "$(category_file firmware)"
write_category "额外安装驱动" "$(category_file drivers)"
write_category "额外安装主题" "$(category_file themes)"
write_category "额外安装 LuCI 插件" "$(category_file luci)"
write_category "额外安装软件" "$(category_file software)"
write_category "第三方包编译失败/已跳过" "$third_party_failed_pkgs"