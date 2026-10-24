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
ib_version="${5:-}"
[[ -n "$ib_tarball" && -n "$config_file" && -n "$packages_list" && -n "$out_dir" ]] ||
  fail "usage: $0 <ib-tarball> <firmware.conf> <ib-packages.list> <out-dir> <ib-version>"
[[ -f "$ib_tarball" ]] || fail "ImageBuilder tarball not found: $ib_tarball"
[[ -f "$packages_list" ]] || fail "package list not found: $packages_list"

load_firmware_config "$config_file"

# 单引号转义：生成的首启脚本在设备上由 sh source 执行，值里的单引号需按
# '\'' 处理（PPPoE 密码等用户输入不可假设无特殊字符）
shq() { printf '%s' "$1" | sed -e "s/'/'\\\\''/g"; }

# 生成首启 uci-defaults 脚本（写入 $1）。
# 时序保证：boot(START=10) 内联先跑 kmodloader（USB 网卡驱动加载），
# 再 /sbin/wifi config 生成 radio0 段，最后才应用本脚本——因此可直接
# 开启 Wi-Fi。所有配置值留空时跳过对应设置（WAN 模式二选一由 config.sh
# 校验互斥：PPPoE 优先判定）。
gen_uci_defaults() {
  local target="$1" s
  {
    echo "uci set network.lan.ipaddr='$(shq "$lan_ip")'"
    echo "uci commit network"
    if [[ -n "$hostname" ]]; then
      echo "uci set system.@system[0].hostname='$(shq "$hostname")'"
    fi
    if [[ -n "$timezone" ]]; then
      echo "uci set system.@system[0].zonename='Asia/Shanghai'"
      echo "uci set system.@system[0].timezone='$(shq "$timezone")'"
    fi
    if [[ -n "$ntp_servers" ]]; then
      echo "uci -q delete system.ntp"
      echo "uci set system.ntp='timeserver'"
      echo "uci set system.ntp.enabled='1'"
      echo "uci set system.ntp.enable_server='0'"
      for s in $ntp_servers; do
        echo "uci add_list system.ntp.server='$(shq "$s")'"
      done
    fi
    echo "uci commit system"
    if [[ -n "$pppoe_user" ]]; then
      echo "uci set network.wan.proto='pppoe'"
      echo "uci set network.wan.username='$(shq "$pppoe_user")'"
      echo "uci set network.wan.password='$(shq "$pppoe_password")'"
      echo "uci commit network"
    elif [[ -n "$bypass_gateway" ]]; then
      echo "uci set network.lan.gateway='$(shq "$bypass_gateway")'"
      echo "uci -q delete network.lan.dns"
      echo "uci add_list network.lan.dns='$(shq "$bypass_gateway")'"
      echo "uci commit network"
      echo "uci set dhcp.lan.ignore='1'"
      echo "uci commit dhcp"
    fi
    if [[ -n "$wifi_ssid" ]]; then
      echo 'if uci -q get wireless.radio0 >/dev/null; then'
      echo "  uci set wireless.radio0.disabled='0'"
      echo '  if uci -q get wireless.default_radio0 >/dev/null; then'
      echo "    uci set wireless.default_radio0.ssid='$(shq "$wifi_ssid")'"
      echo "    uci set wireless.default_radio0.encryption='psk2'"
      echo "    uci set wireless.default_radio0.key='$(shq "$wifi_password")'"
      echo "    uci set wireless.default_radio0.network='lan'"
      echo '  fi'
      echo '  uci commit wireless'
      echo 'fi'
    fi
    if [[ -n "$luci_lang" || -n "$default_theme" ]]; then
      echo 'if uci -q get luci.main >/dev/null; then'
      if [[ -n "$luci_lang" ]]; then
        echo "  uci set luci.main.lang='$(shq "$luci_lang")'"
      fi
      if [[ -n "$default_theme" ]]; then
        echo "  uci set luci.main.theme='$(shq "$default_theme")'"
      fi
      echo '  uci commit luci'
      echo 'fi'
    fi
    # 首启写入 root 密码（构建期生成哈希，设备上无需 openssl）。
    # sed 程序必须用单引号：哈希含 $6$salt$ 字样，双引号会在设备首启时被 shell 展开。
    echo "sed -i 's|^root:[^:]*:|root:${password_hash}:|' /etc/shadow"
  } > "$target"
}

# 后续会 cd 进 ImageBuilder 目录，先把所有路径转为绝对路径
[[ -d "$out_dir" ]] || mkdir -p "$out_dir"
packages_list="$(cd "$(dirname -- "$packages_list")" && pwd)/$(basename -- "$packages_list")"
out_dir="$(cd -- "$out_dir" && pwd)"

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

# 生成 WAN 首启兜底脚本：不依赖 base-files 的 board.d，首启时直接生成 WAN
# 接口与 WAN 口 LED。98 字典序早于 99-h28k-setup，后者写入的 PPPoE 覆盖项
# 依赖 wan 节已存在，此顺序保证旁路/拨号配置仍能生效
write_wan_fallback() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
# H28K WAN 兜底：board.d 配置缺失时直接生成 WAN 接口与 WAN 口 LED
if ! uci -q get network.wan >/dev/null; then
  uci set network.wan=interface
  uci set network.wan.device='eth1'
  uci set network.wan.proto='dhcp'
  uci commit network
fi
if [ -e /sys/class/leds/blue:wan ]; then
  uci -q delete system.led_wan
  uci set system.led_wan=led
  uci set system.led_wan.name='WAN'
  uci set system.led_wan.sysfs='blue:wan'
  uci set system.led_wan.dev='eth1'
  uci set system.led_wan.trigger='netdev'
  uci set system.led_wan.mode='link tx rx'
  uci commit system
fi
EOF
  chmod +x "$target"
}

# 校验已解包 rootfs 的 WAN 配置：rootfs 的 02_network 与注入的自建版本字节
# 一致（H28K WAN case 在位），或已带首启 WAN 兜底。注意不能用 grep hinlink
# 判定——官方 25.12 的 02_network 本就含 hinlink（MAC 生成 case），base-files
# 被覆盖后该字样仍在，会误判通过
verify_wan_rootfs() {
  local root="$1"
  if [[ -f "$root/etc/board.d/02_network" && -f "$ib_dir/files/etc/board.d/02_network" ]] &&
     cmp -s "$root/etc/board.d/02_network" "$ib_dir/files/etc/board.d/02_network"; then
    return 0
  fi
  [[ -f "$root/etc/uci-defaults/98-h28k-wan" ]]
}

# 防御性恢复：自建 base-files 的版本号前缀取自源码提交计数（浅克隆构建下必然
# 低于官方 buildbot 的数值，如 1~ vs 1879~）。IB 组装启用官方远程源后，opkg/apk
# 会按更高版本安装官方 base-files，覆盖自建包并连带丢失 H28K 板级配置
# （board.d 的 WAN/LED 配置、phy-leds 等）。这里把 IB 捆绑的自建 base-files
# 中的板级文件解出并经 FILES 注入：make image 在安装完全部包之后才拷贝 FILES，
# 因此无论实际装的是哪个 base-files，最终 rootfs 都用回自建的板级配置。
bf_stage="$(mktemp -d)"
bf_src=""
if compgen -G "packages/base-files_*.ipk" >/dev/null; then
  # 24.10（opkg）：ipk 为 ar 归档，文件树在 data.tar.* 成员里
  bf_ipk="$(ls packages/base-files_*.ipk | head -n1)"
  for member in data.tar.gz data.tar.xz data.tar.zst data.tar; do
    if ar p "$bf_ipk" "$member" > "$bf_stage/$member" 2>/dev/null; then
      case "$member" in
        *.gz)  tar -xzf "$bf_stage/$member" -C "$bf_stage" 2>/dev/null || true ;;
        *.xz)  tar -xJf "$bf_stage/$member" -C "$bf_stage" 2>/dev/null || true ;;
        *.zst) tar --zstd -xf "$bf_stage/$member" -C "$bf_stage" 2>/dev/null || true ;;
        *)     tar -xf "$bf_stage/$member" -C "$bf_stage" 2>/dev/null || true ;;
      esac
      if [[ -e "$bf_stage/etc/board.d/02_network" ]]; then
        bf_src="$bf_stage"
        break
      fi
    fi
  done
elif compgen -G "packages/base-files-*.apk" >/dev/null; then
  # 25.12/master（apk）：包为 tar 流（apk2 平铺 / apk3 分段），两种布局都容忍
  bf_apk="$(ls packages/base-files-*.apk | head -n1)"
  if ( zcat "$bf_apk" 2>/dev/null || cat "$bf_apk" ) | tar -x --ignore-zeros -C "$bf_stage" 2>/dev/null; then
    if [[ -e "$bf_stage/etc/board.d/02_network" ]]; then
      bf_src="$bf_stage"
    fi
  fi
fi
if [[ -z "$bf_src" ]]; then
  bf_root="$(find "$bf_stage" -type f -path '*etc/board.d/02_network' -print -quit 2>/dev/null || true)"
  if [[ -n "$bf_root" ]]; then
    bf_src="$(dirname "$(dirname "$bf_root")")"
  fi
fi
bf_ok=0
if [[ -n "$bf_src" ]]; then
  mkdir -p files/etc/board.d files/etc/hotplug.d/net files/etc/init.d
  bf_ok=1
  for rel in etc/board.d/01_leds etc/board.d/02_network \
             etc/hotplug.d/net/40-net-smp-affinity etc/init.d/phy-leds; do
    hit="$(find "$bf_src" -type f -path "*/$rel" -print -quit 2>/dev/null || true)"
    if [[ -z "$hit" ]]; then
      bf_ok=0
      break
    fi
    cp -f "$hit" "files/$rel"
  done
  if [[ "$bf_ok" == 1 ]]; then
    chmod +x files/etc/init.d/phy-leds
    if grep -q hinlink files/etc/board.d/02_network; then
      echo "=== H28K 板级文件已注入 FILES（自建 base-files 兜底，防官方包覆盖） ==="
    else
      bf_ok=0
    fi
  fi
fi
if [[ "$bf_ok" != 1 ]]; then
  # 组装前修复：板级文件注入失败（IB 捆绑包解析失败等），退化为注入不依赖
  # base-files 的首启 WAN 兜底配置，由出厂自检确认其进入最终 rootfs
  echo "⚠️ 未能从 IB 捆绑的 base-files 解出 H28K 板级文件，已注入首启 WAN 兜底配置" >&2
  write_wan_fallback "$ib_dir/files/etc/uci-defaults/98-h28k-wan"
fi
rm -rf "$bf_stage"

echo "=== 生成首启配置（IP/密码/主题/WAN 模式/主机名/Wi-Fi/语言/时区） ==="
password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
mkdir -p files/etc/uci-defaults
gen_uci_defaults "$ib_dir/files/etc/uci-defaults/99-h28k-setup"
chmod +x files/etc/uci-defaults/99-h28k-setup

# 包列表格式：每行"包名=y"（安装）或"包名=n"（不安装），裸包名等同 =y，# 注释
packages="$(awk '
  { sub(/[[:space:]]*#.*/, "") }
  { gsub(/[[:space:]]/, ""); if ($0 == "") next }
  { if ($0 ~ /=n$/) next; sub(/=y$/, ""); print }
' "$packages_list" | tr '\n' ' ')"
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

# WAN 出厂自检：确认最终 rootfs 里 WAN 配置可用（board.d 含 H28K 配置，或已带
# 首启 WAN 兜底）。缺失时注入兜底脚本并重新打包一次，仍缺失则中止发布，杜绝
# 无 WAN 的固件进入 Release。以产物中的 rootfs.tar.gz 为检查对象（与镜像同一
# rootfs 制备流程）。
wan_selfcheck() {
  local check_dir wan_tar
  if ! compgen -G "$out_dir/*rootfs.tar.gz" >/dev/null; then
    echo "⚠️ 产物中无 rootfs.tar.gz，跳过 WAN 出厂自检（依赖前置注入保障）" >&2
    return 0
  fi
  wan_tar="$(ls "$out_dir"/*rootfs.tar.gz | head -n1)"
  check_dir="$(mktemp -d)"
  tar -xzf "$wan_tar" -C "$check_dir" \
    './etc/board.d/02_network' './etc/uci-defaults/98-h28k-wan' 2>/dev/null || true
  if verify_wan_rootfs "$check_dir"; then
    rm -rf "$check_dir"
    echo "=== WAN 出厂自检通过：rootfs 含 H28K WAN 配置 ==="
    return 0
  fi
  echo "⚠️ WAN 出厂自检失败：最终 rootfs 无 WAN 配置，注入首启兜底后重新打包" >&2
  write_wan_fallback "$ib_dir/files/etc/uci-defaults/98-h28k-wan"
  rm -f "$out_dir"/*rootfs.tar.gz "$out_dir"/*hinlink_h28k*sysupgrade*.img.gz 2>/dev/null || true
  if ! run_make_image "$good_pkgs"; then
    rm -rf "$check_dir"
    echo "❌ WAN 修复后重新打包失败" >&2
    exit 1
  fi
  if ! compgen -G "$out_dir/*rootfs.tar.gz" >/dev/null; then
    rm -rf "$check_dir"
    echo "❌ 重新打包后无 rootfs.tar.gz，无法复检，中止发布" >&2
    exit 1
  fi
  wan_tar="$(ls "$out_dir"/*rootfs.tar.gz | head -n1)"
  rm -rf "$check_dir"
  check_dir="$(mktemp -d)"
  tar -xzf "$wan_tar" -C "$check_dir" \
    './etc/board.d/02_network' './etc/uci-defaults/98-h28k-wan' 2>/dev/null || true
  if verify_wan_rootfs "$check_dir"; then
    rm -rf "$check_dir"
    echo "=== 重新打包后 WAN 自检通过（首启兜底已生效） ==="
    return 0
  fi
  rm -rf "$check_dir"
  echo "❌ 重新打包后 WAN 配置仍缺失，中止发布" >&2
  return 1
}
wan_selfcheck || exit 1

out_abs="$(cd "$out_dir" && pwd)"
shopt -s nullglob
images=("$out_abs"/*hinlink_h28k*sysupgrade*.img.gz)
[[ "${#images[@]}" -gt 0 ]] || { echo "error: 未生成 sysupgrade 固件" >&2; exit 1; }
echo "=== 产物 ==="
ls -lh "${images[@]}"
