#!/usr/bin/env bash

# 拉取官方软件源的插件包列表，生成 y/n 开关格式的 ib-packages.list。
#
# 数据来源：该版本 targets/rockchip/armv8/feeds.buildinfo 锁定的 4 个插件源
# （packages / luci / routing / telephony，base 核心系统包不在清单内），
# 按锁定的 commit 浅克隆后提取 define Package/ 定义的包名。
#
# 合并策略：已有文件中 =y（或裸包名）的启用项保留；新增包默认 =n。
# 重新生成（含换版本）不会丢掉你已启用的插件。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

version="${1:-}"
out_file="${2:-}"
[[ -n "$version" && -n "$out_file" ]] ||
  fail "usage: $0 <version> <ib-packages.list>"
case "$version" in
  master|*-SNAPSHOT|[0-9]*.[0-9]*.[0-9]*) ;;
  *) fail "invalid version: $version（支持 X.Y.Z / X.Y-SNAPSHOT / master）" ;;
esac

case "$version" in
  master) dl_base="https://downloads.immortalwrt.org/snapshots" ;;
  *)      dl_base="https://downloads.immortalwrt.org/releases/$version" ;;
esac

# 网络重试封装：TLS 握手偶发失败很常见
http_get() {
  local url="$1" attempt
  for attempt in 1 2 3 4 5; do
    if curl -4 -fsSL --max-time 60 "$url"; then
      return 0
    fi
    echo "    下载失败（第 $attempt 次），重试..." >&2
    sleep 3
  done
  return 1
}

# 默认启用的包（首次生成时 =y；重新生成时沿用你已有的选择）
defaults="kmod-mt7921u wpad-openssl openssh-sftp-server"

declare -A keep=()
if [[ -f "$out_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=n ]] && continue
    keep["${line%=y}"]=1
  done < "$out_file"
  echo "=== 已从现有清单读取启用项：${#keep[@]} 个 ==="
fi
for d in $defaults; do
  keep[$d]=1
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

buildinfo="$(http_get \
  "$dl_base/targets/rockchip/armv8/feeds.buildinfo")" ||
  fail "无法下载 $version 的 feeds.buildinfo"

declare -A feed_of=()
declare -a names=()
declare -a feeds_done=()
while read -r src name repo; do
  [[ "$src" == "src-git" ]] || continue
  sha="${repo##*^}"
  repo="${repo%%^*}"
  [[ -n "$name" && -n "$repo" && -n "$sha" ]] ||
    fail "feeds.buildinfo 格式异常: $src $name $repo"
  echo "=== [$name] 浅克隆 $sha ==="
  dir="$work_dir/$name"
  git init -q "$dir"
  git -C "$dir" remote add origin "$repo"
  git -C "$dir" fetch -q --depth 1 origin "$sha" ||
    fail "拉取 $name 源失败（$repo @ $sha）"
  git -C "$dir" checkout -q FETCH_HEAD
  mapfile -t found < <(grep -hE '^define Package/[A-Za-z0-9_.+-]+' -r "$dir" --include=Makefile |
    sed -E 's/^define Package\/([A-Za-z0-9_.+-]+).*/\1/' | sort -u)
  # luci 源使用 luci.mk 构建体系：applications/themes 的目录名即包名，无显式 define
  if [[ "$name" == "luci" ]]; then
    declare -a luci_extra=()
    for d in "$dir"/applications/*/ "$dir"/themes/*/; do
      [[ -f "${d}Makefile" ]] || continue
      luci_extra+=("$(basename "$d")")
    done
    echo "    luci.mk 目录约定补充 ${#luci_extra[@]} 个包"
    found+=("${luci_extra[@]}")
  fi
  echo "    ${#found[@]} 个包"
  feeds_done+=("$name")
  for n in "${found[@]}"; do
    [[ -n "${feed_of[$n]:-}" ]] && continue
    feed_of[$n]=$name
    names+=("$n")
  done
done < <(printf '%s\n' "$buildinfo")

(( ${#names[@]} >= 1 )) || fail "没有从任何插件源提取到包名"

{
  echo "# 官方源插件包开关清单（由 scripts/fetch_official_packages.sh 生成）"
  echo "# 上游版本：$version；覆盖源：${feeds_done[*]}"
  echo "# 用法：把要安装的包改为 =y，不安装保持 =n；# 开头为注释"
  echo "# 重新生成会保留你已启用（=y）的包，新增包默认 =n"
  echo "# 注意：kmod-* 由 targets 的 kmods 源提供，不在此清单；官方源没有的源码插件见 config/source-plugins.list"
  mapfile -t sorted < <(printf '%s\n' "${names[@]}" | sort -u)
  echo "# === 官方插件源包（feeds：${feeds_done[*]}）==="
  for n in "${sorted[@]}"; do
    state=n
    [[ -n "${keep[$n]:-}" ]] && state=y
    printf '%s=%s\n' "$n" "$state"
  done
  # feeds 里没有的官方包（base/kmods 源）：保留用户已有的启用项，
  # 也可以按需手动添加（如 kmod-xxx=y）
  echo "# === 清单外的官方包（base/kmods 源提供，不在插件源中）==="
  mapfile -t outside < <(printf '%s\n' "${!keep[@]}" | sort -u)
  for n in "${outside[@]}"; do
    [[ -n "${feed_of[$n]:-}" ]] && continue
    printf '%s=y\n' "$n"
  done
} > "$out_file"

total=$(grep -cE '^[A-Za-z0-9_.+-]+=(y|n)$' "$out_file" || true)
enabled=$(grep -cE '^[A-Za-z0-9_.+-]+=(y)$' "$out_file" || true)
echo "=== 完成：$out_file 共 $total 个包，其中启用 $enabled 个 ==="
