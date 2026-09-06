#!/usr/bin/env bash

# Shared firmware.conf parsing helpers. Source this file from other scripts.

fail() { echo "error: $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# 校验 IPv4 地址格式与各字节范围
ipv4_ok() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o
  local -a parts=()
  IFS=. read -r -a parts <<< "$ip"
  for o in "${parts[@]}"; do
    (( 10#$o <= 255 )) || return 1
  done
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

# 判断版本是否在排除名单内（excluded_versions；all 枚举时跳过）。
# 调用前必须已经执行过 load_firmware_config。
version_excluded() {
  local needle="$1" item
  for item in "${excluded_versions[@]}"; do
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
  local file="$1" key value
  [[ -f "$file" ]] || fail "config file not found: $file"

  default_series=""
  supported_versions=()
  supported_series=()
  excluded_versions=()
  lan_ip=""
  password=""
  rootfs_size=""
  default_theme=""
  check_official_abi=true
  hostname=""
  pppoe_user=""
  pppoe_password=""
  bypass_gateway=""
  wifi_ssid=""
  wifi_password=""
  luci_lang=""
  timezone=""
  ntp_servers=""

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
      excluded_versions) read -r -a excluded_versions <<< "$value" ;;
      lan_ip) lan_ip="$value" ;;
      password) password="$value" ;;
      rootfs_size) rootfs_size="$value" ;;
      default_theme) default_theme="$value" ;;
      check_official_abi) check_official_abi="$value" ;;
      hostname) hostname="$value" ;;
      pppoe_user) pppoe_user="$value" ;;
      pppoe_password) pppoe_password="$value" ;;
      bypass_gateway) bypass_gateway="$value" ;;
      wifi_ssid) wifi_ssid="$value" ;;
      wifi_password) wifi_password="$value" ;;
      luci_lang) luci_lang="$value" ;;
      timezone) timezone="$value" ;;
      ntp_servers) ntp_servers="$value" ;;
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
  # excluded_versions：系列内明确不支持、all 枚举时排除的版本（如 24.10.0 无 phy-leds）
  local e
  for e in "${excluded_versions[@]}"; do
    [[ "$e" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid excluded version: $e"
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
  ipv4_ok "$lan_ip" || fail "invalid lan_ip: $lan_ip"
  [[ -n "$password" ]] || fail "password is required"
  [[ -z "$default_theme" || "$default_theme" =~ ^[A-Za-z0-9_-]+$ ]] ||
    fail "invalid default_theme: $default_theme"
  [[ "$check_official_abi" == true || "$check_official_abi" == false ]] ||
    fail "check_official_abi must be true or false"

  # 首启默认配置校验（全部可留空 = 跳过）
  [[ -z "$hostname" || "$hostname" =~ ^[A-Za-z0-9_-]+$ ]] ||
    fail "invalid hostname: $hostname"
  if [[ -n "$pppoe_user" || -n "$pppoe_password" ]]; then
    [[ -n "$pppoe_user" && -n "$pppoe_password" ]] ||
      fail "pppoe_user 与 pppoe_password 需同时填写（留空则保持 DHCP）"
    case "$pppoe_user$pppoe_password" in
      *"'"*|*'"'*|*\\*) fail "pppoe 账号/密码不能包含引号或反斜杠" ;;
    esac
  fi
  [[ -z "$bypass_gateway" ]] || ipv4_ok "$bypass_gateway" ||
    fail "invalid bypass_gateway: $bypass_gateway"
  [[ -z "$pppoe_user" || -z "$bypass_gateway" ]] ||
    fail "pppoe_user 与 bypass_gateway 互斥：拨号与旁路由只能二选一"
  if [[ -n "$wifi_ssid" ]]; then
    (( ${#wifi_password} >= 8 )) ||
      fail "wifi_password 至少 8 位（WPA2 要求）：当前 ${#wifi_password} 位"
  else
    [[ -z "$wifi_password" ]] || fail "填写了 wifi_password 但 wifi_ssid 为空"
  fi
  [[ -z "$luci_lang" || "$luci_lang" =~ ^[a-z]{2}(_[A-Za-z]{2,5})?$ ]] ||
    fail "invalid luci_lang: $luci_lang"
  [[ -z "$timezone" || "$timezone" =~ ^[A-Za-z0-9_+-]+$ ]] ||
    fail "invalid timezone: $timezone"
  local ntp
  for ntp in $ntp_servers; do
    [[ "$ntp" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid ntp server: $ntp"
  done
}
