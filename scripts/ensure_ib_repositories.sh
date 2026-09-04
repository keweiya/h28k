#!/usr/bin/env bash

# 为自建 ImageBuilder 补写 repositories（apk 在线源清单）。
# 上游 make imagebuilder 在非 buildbot 构建下默认 IB_STANDALONE=y（见
# target/imagebuilder/Config.in: default y if !BUILDBOT）：全部软件包捆绑
# 本地、不生成 repositories，IB 本地没有的包将无法安装；官方 buildbot
# 产物自带该文件。且上游生成逻辑的 kmods 源行被 CONFIG_BUILDBOT 门住、
# 版本替换依赖 buildbot 注入的版本号，无法通过改配置直接复现，故按官方
# release 的 repositories 模板生成（已验证与官方逐字节一致）：
#   - arch 取自 IB .config 的 CONFIG_TARGET_ARCH_PACKAGES；
#   - kmods 目录按 IB 内核包的 vermagic 从官方 kmods 索引解析。
# 用法：ensure_ib_repositories.sh <已解包的 IB 目录> <版本号>
#   - 已有 repositories：幂等退出；
#   - 仅有 repositories.conf（24.10 opkg 系）：跳过并提示。

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

ib_dir="${1:-}"
ib_version="${2:-}"
[[ -n "$ib_dir" && -n "$ib_version" ]] || fail "usage: $0 <ib-dir> <version>"
[[ -d "$ib_dir" ]] || fail "IB directory not found: $ib_dir"
cd "$ib_dir"

if [[ -f repositories ]]; then
  echo "IB 已自带 repositories，无需补写"
  exit 0
fi

if [[ -f repositories.conf ]]; then
  echo "⚠️ 24.10（opkg）系列的 IB 暂不支持自动补写在线源清单；其本地捆绑包仍可正常组装，或重跑本修复后的全量构建获取完整 IB" >&2
  exit 0
fi

arch="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' .config | head -n1)"
kernel_name="$(basename "$(find packages -maxdepth 1 -name 'kernel-*.apk' | head -n1)")"
kernel_ver="$(printf '%s' "$kernel_name" | sed -nE 's/^kernel-([0-9][0-9.]*)~.*/\1/p')"
kernel_hash="$(printf '%s' "$kernel_name" | sed -nE 's/.*~([0-9a-f]{32})-.*/\1/p')"
[[ -n "$arch" && -n "$kernel_ver" && -n "$kernel_hash" ]] ||
  fail "无法从 IB 元数据解析 arch/内核版本/vermagic（$arch / $kernel_ver / $kernel_hash）"

base_url="https://downloads.immortalwrt.org/releases/$ib_version"
kmods_dir="$(curl -fsSL --retry 2 "$base_url/targets/rockchip/armv8/kmods/" 2>/dev/null |
  sed -nE "s#.*href=\"([^\"]*-$kernel_hash)/\".*#\1#p" | head -n1)" || kmods_dir=""

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
} > repositories

if [[ -n "$kmods_dir" ]]; then
  echo "=== IB 缺少 repositories，已按官方模板生成（版本 $ib_version，arch $arch，kmods $kmods_dir）==="
else
  echo "=== IB 缺少 repositories，已生成基础源清单，但未能解析在线 kmods 目录（vermagic $kernel_hash），kmod 仅能用本地捆绑包 ===" >&2
fi
