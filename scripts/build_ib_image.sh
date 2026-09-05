#!/usr/bin/env bash

# 用自建 ImageBuilder 组装定制固件：不编译任何东西，只解包 IB、注入
# LAN IP / root 密码 / 默认主题（首启 uci-defaults）、按包列表安装并生成镜像。
# 内核与 kmod 与基础构建完全一致，ABI 不变。

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"

ib_tarball="${1:-}"
config_file="${2:-}"
packages_list="${3:-}"
out_dir="${4:-}"
plugins_tarball="${5:-}"
ib_version="${6:-}"
[[ -n "$ib_tarball" && -n "$config_file" && -n "$packages_list" && -n "$out_dir" ]] ||
  fail "usage: $0 <ib-tarball> <firmware.conf> <ib-packages.list> <out-dir> [plugins-tarball] [ib-version]"
[[ -f "$ib_tarball" ]] || fail "ImageBuilder tarball not found: $ib_tarball"
[[ -f "$packages_list" ]] || fail "package list not found: $packages_list"

load_firmware_config "$config_file"

# 后续会 cd 进 ImageBuilder 目录，先把所有路径转为绝对路径
[[ -d "$out_dir" ]] || mkdir -p "$out_dir"
packages_list="$(cd "$(dirname -- "$packages_list")" && pwd)/$(basename -- "$packages_list")"
out_dir="$(cd -- "$out_dir" && pwd)"
if [[ -n "$plugins_tarball" ]]; then
  [[ -f "$plugins_tarball" ]] || fail "plugins tarball not found: $plugins_tarball"
  plugins_tarball="$(cd "$(dirname -- "$plugins_tarball")" && pwd)/$(basename -- "$plugins_tarball")"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "=== 解包 ImageBuilder ==="
# 官方 24.10/25.12 的 ImageBuilder 均为 zstd（.tar.zst）压缩；兼容旧的 xz
case "$ib_tarball" in
  *.tar.zst) tar --zstd -xf "$ib_tarball" -C "$work_dir" ;;
  *.tar.xz)  tar -xJf "$ib_tarball" -C "$work_dir" ;;
  *) fail "unsupported ImageBuilder tarball format: $ib_tarball（支持 .tar.zst / .tar.xz）" ;;
esac
ib_dir="$(find "$work_dir" -maxdepth 1 -type d -name 'immortalwrt-imagebuilder-*' | head -n1)"
[[ -n "$ib_dir" ]] || fail "ImageBuilder directory not found in tarball"
cd "$ib_dir"

# 官方 buildbot 打包的 IB 自带 repositories（apk 在线源清单）；本地 make
# imagebuilder 默认 standalone 模式不生成它。缺失时由共享脚本按官方模板补写，
# 保证 IB 本地没有的包仍可从官方源安装（与官方 release 完全一致、ABI 不变）。
bash "$SCRIPT_DIR/ensure_ib_repositories.sh" "$ib_dir" "$ib_version"

if [[ -n "$plugins_tarball" ]]; then
  echo "=== 注入插件包（ipk/apk 自动匹配） ==="
  plugins_dir="$work_dir/plugins"
  mkdir -p "$plugins_dir"
  tar -xzf "$plugins_tarball" -C "$plugins_dir"
  find "$plugins_dir" \( -name '*.ipk' -o -name '*.apk' \) -exec cp -f {} "$ib_dir/packages/" \;
  ipk_num="$(find "$ib_dir/packages" \( -name '*.ipk' -o -name '*.apk' \) | wc -l)"
  echo "    ImageBuilder 本地包数量: $ipk_num"
fi

echo "=== 生成首启配置（IP/密码/主题） ==="
password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
mkdir -p files/etc/uci-defaults
{
  echo "uci set network.lan.ipaddr='$lan_ip'"
  echo "uci commit network"
  if [[ -n "$default_theme" ]]; then
    echo "uci set luci.main.theme='$default_theme'"
    echo "uci commit luci"
  fi
  # 首启写入 root 密码（构建期生成哈希，设备上无需 openssl）。
  # sed 程序必须用单引号：哈希含 $6$salt$ 字样，双引号会在设备首启时被 shell 展开。
  echo "sed -i 's|^root:[^:]*:|root:${password_hash}:|' /etc/shadow"
} > files/etc/uci-defaults/99-h28k-setup
chmod +x files/etc/uci-defaults/99-h28k-setup

# 包列表格式：每行"包名=y"（安装）或"包名=n"（不安装），裸包名等同 =y，# 注释
packages="$(awk '
  { sub(/[[:space:]]*#.*/, "") }
  { gsub(/[[:space:]]/, ""); if ($0 == "") next }
  { if ($0 ~ /=n$/) next; sub(/=y$/, ""); print }
' "$packages_list" | tr '\n' ' ')"
# 源码插件：插件包内附 packages.list（构建插件包时写入的包名清单）自动并入安装列表，
# 因此 source-plugins.list 里启用的插件无需写进 ib-packages.list
if [[ -n "$plugins_tarball" && -f "$plugins_dir/packages.list" ]]; then
  plugin_names="$(sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$plugins_dir/packages.list" | tr '\n' ' ')"
  packages="$packages $plugin_names"
fi
# 去重
packages="$(printf '%s\n' $packages | awk 'NF' | sort -u | tr '\n' ' ')"

# 预检：仅对 luci-* 包做"是否在官方源"检查（kmod/base 等本地捆绑必有，不检查）。
# 官方包列表 = 各 feed 目录页里列出的 .apk/.ipk 文件名（apk 系取 repositories
# 里的 URL 去掉 packages.adb 后缀；opkg 系取 repositories.conf 的 src/gz URL），
# 纯 curl+grep，确定性判断，不依赖 apk 模拟行为；本地捆绑（packages/ 下的
# 文件名前缀）作为兜底。注意：apk 文件名用连字符分隔（名-版本-架构），opkg
# 的 ipk 用下划线（名_版本_架构），两种分隔符都要匹配。不在官方源也不在本地
# 捆绑的包提前剔除并写入 out/missing-packages.txt；官方源目录列表拉取为空时
# 放弃预检，按原清单继续。
if [ -f repositories ] || [ -f repositories.conf ]; then
  official_files="$out_dir/official-feed-files.txt"
  : > "$official_files"
  if [ -f repositories ]; then
    # apk 系：repositories 每行一个 .../packages.adb，feed 目录为其所在目录
    sed -n 's#/packages.adb$##p' repositories | while IFS= read -r url; do
      curl -fsSL --retry 2 "$url/" 2>/dev/null |
        grep -oE 'href="[^"]+\.(apk|ipk)"' | sed -e 's/^href="//' -e 's/"$//' || true
    done >> "$official_files"
  else
    # opkg 系：repositories.conf 的 src/gz <名> <URL>
    sed -nE 's#^src/gz [^ ]+ (https?://[^ ]+)#\1#p' repositories.conf | while IFS= read -r url; do
      curl -fsSL --retry 2 "$url/" 2>/dev/null |
        grep -oE 'href="[^"]+\.(apk|ipk)"' | sed -e 's/^href="//' -e 's/"$//' || true
    done >> "$official_files"
  fi
  if [ ! -s "$official_files" ]; then
    echo "⚠️ 预检：官方源目录列表拉取为空，放弃预检，按原清单继续组装"
    rm -f "$official_files" "$out_dir/missing-packages.txt"
  else
    missing_file="$out_dir/missing-packages.txt"
    : > "$missing_file"
    keep=''
    n_enabled=0
    n_missing=0
    for p in $packages; do
      case "$p" in
        -*) keep="$keep $p"; continue ;;   # 负包名（移除默认包）交给 make image 处理
        luci-*) ;;                          # 仅 luci- 包参与官方源比对
        *) keep="$keep $p"; continue ;;
      esac
      n_enabled=$((n_enabled + 1))
      # apk 文件名连字符分隔、opkg 的 ipk 下划线分隔，两种都要匹配；
      # 版本段以数字开头（26.236… / 6.6.133~…），据此区分同名前缀的其他包。
      # 注意 ${p} 必须加花括号：$p_ 会被 bash 解析成名为 p_ 的变量（set -u 直接中止）
      if grep -qE "^${p}[-_][0-9]" "$official_files" 2>/dev/null ||
         compgen -G "packages/${p}-*.apk" >/dev/null ||
         compgen -G "packages/${p}-*.ipk" >/dev/null ||
         compgen -G "packages/${p}_*.apk" >/dev/null ||
         compgen -G "packages/${p}_*.ipk" >/dev/null; then
        keep="$keep $p"
      else
        printf '%s\n' "$p" >> "$missing_file"
        n_missing=$((n_missing + 1))
      fi
    done
    rm -f "$official_files"
    packages="${keep# }"
    if [ "$n_missing" -gt 0 ]; then
      echo "=== 预检：以下 $n_missing 个包官方源与本地捆绑均没有，已提前跳过 ==="
      cat "$missing_file"
    fi
  fi
fi

echo "=== 组装镜像（PROFILE=hinlink_h28k） ==="
echo "    额外软件包: ${packages:-（无）}"

IB_META="$ib_dir/.targetinfo"

run_make_image() {
  make image \
    PROFILE=hinlink_h28k \
    PACKAGES="$1" \
    FILES="$ib_dir/files" \
    ROOTFS_PARTSIZE="$rootfs_size" \
    BIN_DIR="$out_dir" 2>&1 | tee "$out_dir/make-image.log"
  return ${PIPESTATUS[0]}
}

# 设备配方引用的包若在所有源都不可得（如 24.10.1/2/3 的 kmod-input-adc-keys、
# master 的 kmod-saradc-rockchip——上游删除/未产出），make image 会失败。
# 从 make image 日志解析缺失包名，自动从设备配方（.targetinfo）剔除后重试。
prune_missing_device_packages() {
  local log="$1" pkg pruned=0 missing
  missing="$({
    grep -oE "Unknown package '[^']+'" "$log" 2>/dev/null | sed -E "s/.*'([^']+)'.*/\1/"
    grep -oE "^  [a-zA-Z0-9+._-]+ [(]no such package[)]" "$log" 2>/dev/null | awk '{print $1}'
  })" || true
  [[ -n "$missing" ]] || return 1
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if grep -qE "^Target-Profile-Packages: .*$pkg" "$IB_META" 2>/dev/null; then
      sed -i "/^Target-Profile-Packages:/ { s/$pkg //g; s/ $pkg//g; s/  */ /g }" "$IB_META"
      echo "    已从设备配方剔除缺失包: $pkg"
      pruned=$((pruned+1))
    fi
  done <<< "$missing"
  [[ $pruned -gt 0 ]]
}

declare -a failed_pkgs=()
good_pkgs="$packages"
per_package_done=0
round=0
until run_make_image "$good_pkgs"; do
  round=$((round+1))
  # 第一优先：自动剔除设备配方中不可安装的缺失包（最多 3 轮）
  if [[ $round -le 3 ]] && prune_missing_device_packages "$out_dir/make-image.log"; then
    echo "=== 已剔除缺失设备包，重试组装（第 $round 轮）==="
    continue
  fi
  # 无可剔除：转为逐包降级，定位用户插件失败项（仅一轮）
  if [[ "$per_package_done" == 1 ]]; then
    echo "❌ 镜像组装失败（已用尽自动容错）" >&2
    exit 1
  fi
  per_package_done=1
  echo "=== 批量安装失败，转为逐个插件安装以定位失败项 ==="
  good_pkgs=""
  for p in $packages; do
    echo "--- 尝试安装: $p ---"
    if run_make_image "$good_pkgs $p"; then
      good_pkgs="$good_pkgs $p"
    else
      echo "    ⚠ 安装失败，已跳过: $p"
      failed_pkgs+=("$p")
    fi
  done
  echo "=== 用成功集合重组最终镜像 ==="
done

if (("${#failed_pkgs[@]}")); then
  printf '%s\n' "${failed_pkgs[@]}" > "$out_dir/failed-packages.txt"
  echo "=== ⚠ 安装失败的插件（已跳过）: ${failed_pkgs[*]} ==="
fi

out_abs="$(cd "$out_dir" && pwd)"
shopt -s nullglob
images=("$out_abs"/*hinlink_h28k*sysupgrade*.img.gz)
[[ "${#images[@]}" -gt 0 ]] || { echo "error: 未生成 sysupgrade 固件" >&2; exit 1; }
echo "=== 产物 ==="
ls -lh "${images[@]}"
