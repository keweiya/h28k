#!/usr/bin/env bash

# Shared firmware.conf parsing helpers. Source this file from other scripts.

fail() { echo "error: $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# 判断版本是否在 supported_versions 白名单内。
# 调用前必须已经执行过 load_firmware_config。
version_in_list() {
  local needle="$1" item
  for item in "${supported_versions[@]}"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# 判断系列是否允许构建（supported_series；master 滚动快照始终允许）。
# 调用前必须已经执行过 load_firmware_config。
series_supported() {
  local needle="$1" item
  [[ "$needle" == "master" ]] && return 0
  for item in "${supported_series[@]}"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# 版本形态：
#   X.Y.Z        正式 release（源码锁 tag vX.Y.Z，官方源 releases/X.Y.Z/）
#   X.Y-SNAPSHOT 分支滚动快照（源码锁 openwrt-X.Y 分支 revision，官方源 releases/X.Y-SNAPSHOT/）
#   master       master 滚动快照（源码锁 master 分支 revision，官方源 snapshots/）
# 输出 release / snapshot / invalid。
version_kind() {
  local v="$1"
  case "$v" in
    master) printf 'snapshot\n' ;;
    *)
      if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'release\n'
      elif [[ "$v" =~ ^[0-9]+\.[0-9]+-SNAPSHOT$ ]]; then
        printf 'snapshot\n'
      else
        printf 'invalid\n'
      fi
      ;;
  esac
}

# 版本所属系列（决定补丁目录 patches/<series> 与系列特例逻辑）：
# X.Y.Z 与 X.Y-SNAPSHOT 都归入 X.Y，master 归入 master。
version_series() {
  local v="$1"
  case "$v" in
    master) printf 'master\n' ;;
    *-SNAPSHOT) printf '%s\n' "${v%-SNAPSHOT}" ;;
    *) printf '%s\n' "${v%.*}" ;;
  esac
}

# 产物 / Release tag 命名后缀：正式版沿用 vX.Y.Z，滚动快照用原样字符串。
rel_suffix_of() {
  case "$1" in
    master|*-SNAPSHOT) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
}

load_firmware_config() {
  local file="$1" key value octet
  local -a octets
  [[ -f "$file" ]] || fail "config file not found: $file"

  default_series=""
  supported_versions=()
  supported_series=()
  lan_ip=""
  password=""
  rootfs_size=""
  default_theme=""
  check_official_abi=true

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="$(trim "${key%$'\r'}")"
    value="$(trim "${value%$'\r'}")"
    [[ -z "$key" || "$key" == \#* ]] && continue
    if [[ "$value" =~ ^(.*)[[:space:]]+#.*$ ]]; then
      value="$(trim "${BASH_REMATCH[1]}")"
    fi
    case "$key" in
      supported_versions) read -r -a supported_versions <<< "$value" ;;
      supported_series) read -r -a supported_series <<< "$value" ;;
      lan_ip) lan_ip="$value" ;;
      password) password="$value" ;;
      rootfs_size) rootfs_size="$value" ;;
      default_theme) default_theme="$value" ;;
      check_official_abi) check_official_abi="$value" ;;
      *) fail "unknown config key: $key" ;;
    esac
  done < "$file"

  # supported_versions：默认构建集合（工作流选 all 时展开的版本列表）
  (( ${#supported_versions[@]} >= 1 )) || fail "supported_versions must not be empty"
  local v
  for v in "${supported_versions[@]}"; do
    [[ "$(version_kind "$v")" != "invalid" ]] ||
      fail "invalid supported version: $v（支持 X.Y.Z / X.Y-SNAPSHOT / master）"
  done
  # supported_series：允许构建的系列（具体版本与 X.Y-SNAPSHOT 按系列放行，master 始终允许）
  (( ${#supported_series[@]} >= 1 )) || fail "supported_series must not be empty"
  local s
  for s in "${supported_series[@]}"; do
    [[ "$s" =~ ^[0-9]+\.[0-9]+$ ]] || fail "invalid supported series: $s"
  done

  # 工作流输入覆盖（环境变量，留空 = 使用 conf 默认值）
  lan_ip="${CFG_LAN_IP:-$lan_ip}"
  password="${CFG_PASSWORD:-$password}"
  rootfs_size="${CFG_ROOTFS_SIZE:-$rootfs_size}"
  # 根目录大小兼容 2G/1G/512M 与纯 MiB 数字，统一换算为 MiB
  case "$rootfs_size" in
    *[Gg]) rootfs_size=$(( ${rootfs_size%[Gg]} * 1024 )) ;;
    *[Mm]) rootfs_size=$(( ${rootfs_size%[Mm]} )) ;;
  esac
  # 主题允许被工作流显式置空（阶段 1 基础固件不含第三方主题），unset 时保留 conf 值
  default_theme="${CFG_DEFAULT_THEME-$default_theme}"

  [[ -n "$rootfs_size" && "$rootfs_size" =~ ^[0-9]+$ ]] ||
    fail "invalid rootfs_size: $rootfs_size"
  (( 10#$rootfs_size >= 256 && 10#$rootfs_size <= 4096 )) ||
    fail "rootfs_size must be 256..4096 MiB: $rootfs_size"

  [[ -n "$lan_ip" ]] || fail "lan_ip is required"
  [[ "$lan_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    fail "invalid lan_ip: $lan_ip"
  IFS=. read -r -a octets <<< "$lan_ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || fail "invalid lan_ip: $lan_ip"
  done
  [[ -n "$password" ]] || fail "password is required"
  [[ -z "$default_theme" || "$default_theme" =~ ^[A-Za-z0-9_-]+$ ]] ||
    fail "invalid default_theme: $default_theme"
  [[ "$check_official_abi" == true || "$check_official_abi" == false ]] ||
    fail "check_official_abi must be true or false"
}
