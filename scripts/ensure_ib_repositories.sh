#!/usr/bin/env bash

# 为自建 ImageBuilder 补写在线软件源清单，并解除 standalone 门禁。
# 上游 make imagebuilder 在非 buildbot 构建下默认 IB_STANDALONE=y（见
# target/imagebuilder/Config.in: default y if !BUILDBOT）：全部软件包捆绑
# 本地，且运行时 apk 调用被门禁为不加载 repositories（见
# target/imagebuilder/files/Makefile 的 APK 变量：仅非 standalone 才传
# --repositories-file），IB 本地没有的包将无法安装。故除补写清单外，
# 还需把 .config 的 CONFIG_IB_STANDALONE 置为未设置——IB 运行时不跑
# defconfig，直接改写稳定生效；IB 内 keys/ 自带官方快照公钥，远程索引
# 验签可过。上游清单生成逻辑的 kmods 源行被 CONFIG_BUILDBOT 门住、版本
# 替换依赖 buildbot 注入的版本号，无法通过改配置直接复现，故按官方
# release 的清单模板生成（25.12 系已验证与官方逐字节一致）：
#   - arch 取自 IB .config 的 CONFIG_TARGET_ARCH_PACKAGES；
#   - kmods 目录按 IB 内核包的 vermagic 从官方 kmods 索引解析。
# 用法：ensure_ib_repositories.sh <已解包的 IB 目录> <版本号>
#   - 25.12/master（apk）系：补写 repositories + 关闭 IB_STANDALONE；
#   - 24.10（opkg）系：在既有 repositories.conf 前部插入官方远程源
#     （opkg 始终 -f repositories.conf，无 standalone 门禁，不用改）；
#   - 均幂等，已处理时原样退出。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

ib_dir="${1:-}"
ib_version="${2:-}"
[[ -n "$ib_dir" && -n "$ib_version" ]] || fail "usage: $0 <ib-dir> <version>"
[[ -d "$ib_dir" ]] || fail "IB directory not found: $ib_dir"
cd "$ib_dir"

# apk 系 IB（无 repositories.conf）且 standalone 开启时，运行时 apk 只用
# 本地捆绑索引；自建 IB 仅捆绑默认包，不解除门禁则官方在线源形同虚设
if [[ ! -f repositories.conf ]] && grep -q '^CONFIG_IB_STANDALONE=y$' .config; then
  sed -i 's/^CONFIG_IB_STANDALONE=y$/# CONFIG_IB_STANDALONE is not set/' .config
  echo "已关闭 IB_STANDALONE：make image 时 apk 将加载 repositories 官方在线源"
fi

if [[ -f repositories ]]; then
  # apk 系：repositories 多在底包构建阶段已由本脚本补写过；已有官方源行
  # 则只需上面的 standalone 门禁处理，直接退出
  if grep -qE '^https?://' repositories; then
    echo "IB 已自带 repositories（含官方远程源）"
    exit 0
  fi
  echo "IB 的 repositories 仅含本地源，将追加官方远程源"
fi

arch="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' .config | head -n1)"
kernel_name="$(basename "$(find packages -maxdepth 1 \( -name 'kernel-*.apk' -o -name 'kernel-*.ipk' -o -name 'kernel_*.ipk' \) 2>/dev/null | head -n1)")"
kernel_ver="$(printf '%s' "$kernel_name" | sed -nE 's/^kernel[-_]([0-9][0-9.]*)~.*/\1/p')"
kernel_hash="$(printf '%s' "$kernel_name" | sed -nE 's/.*~([0-9a-f]{32})-.*/\1/p')"
[[ -n "$arch" && -n "$kernel_ver" && -n "$kernel_hash" ]] ||
  fail "无法从 IB 元数据解析 arch/内核版本/vermagic（$arch / $kernel_ver / $kernel_hash）"

case "$ib_version" in
  master) base_url="https://downloads.immortalwrt.org/snapshots" ;;
  *)      base_url="https://downloads.immortalwrt.org/releases/$ib_version" ;;
esac
kmods_dir="$(curl -fsSL --retry 2 "$base_url/targets/rockchip/armv8/kmods/" 2>/dev/null |
  sed -nE "s#.*href=\"([^\"]*-$kernel_hash)/\".*#\1#p" | head -n1)" || kmods_dir=""

if [[ -f repositories.conf ]]; then
  # 24.10（opkg）系：repositories.conf 已存在（仅本地源），在文件前部插入官方远程源
  if grep -qE '^src/gz .*releases/' repositories.conf; then
    echo "repositories.conf 已含官方远程源，无需补写"
    exit 0
  fi
  {
    echo '## Remote package repositories'
    echo "src/gz immortalwrt_core $base_url/targets/rockchip/armv8/packages"
    echo "src/gz immortalwrt_base $base_url/packages/$arch/base"
    if [[ -n "$kmods_dir" ]]; then
      echo "src/gz immortalwrt_kmods $base_url/targets/rockchip/armv8/kmods/$kmods_dir"
    fi
    echo "src/gz immortalwrt_luci $base_url/packages/$arch/luci"
    echo "src/gz immortalwrt_packages $base_url/packages/$arch/packages"
    echo "src/gz immortalwrt_routing $base_url/packages/$arch/routing"
    echo "src/gz immortalwrt_telephony $base_url/packages/$arch/telephony"
    echo ''
  } > repositories.conf.new
  cat repositories.conf >> repositories.conf.new
  mv repositories.conf.new repositories.conf
  if [[ -n "$kmods_dir" ]]; then
    echo "=== repositories.conf 已补写官方远程源（版本 $ib_version，arch $arch，kmods $kmods_dir）==="
  else
    echo "=== repositories.conf 已补写基础远程源，但未能解析在线 kmods 目录（vermagic $kernel_hash），kmod 仅能用本地捆绑包 ===" >&2
  fi
  exit 0
fi

# 25.12/master（apk）系：生成/追加 repositories（与官方模板一致）
# 用 >> 追加以兼容既有文件（已含本地源行时不能覆盖）
{
  echo "$base_url/targets/rockchip/armv8/packages/packages.adb"
  echo "$base_url/packages/$arch/base/packages.adb"
  if [[ -n "$kmods_dir" ]]; then
    echo "$base_url/targets/rockchip/armv8/kmods/$kmods_dir/packages.adb"
  fi
  echo "$base_url/packages/$arch/luci/packages.adb"
  echo "$base_url/packages/$arch/packages/packages.adb"
  echo "$base_url/packages/$arch/routing/packages.adb"
  echo "$base_url/packages/$arch/telephony/packages.adb"
} >> repositories

if [[ -n "$kmods_dir" ]]; then
  echo "=== IB 缺少 repositories，已按官方模板生成（版本 $ib_version，arch $arch，kmods $kmods_dir）==="
else
  echo "=== IB 缺少 repositories，已生成基础源清单，但未能解析在线 kmods 目录（vermagic $kernel_hash），kmod 仅能用本地捆绑包 ===" >&2
fi
