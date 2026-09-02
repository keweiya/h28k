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

load_firmware_config() {
  local file="$1" key value octet
  local -a octets
  [[ -f "$file" ]] || fail "config file not found: $file"

  default_series=""
  supported_versions=()
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
      lan_ip) lan_ip="$value" ;;
      password) password="$value" ;;
      rootfs_size) rootfs_size="$value" ;;
      default_theme) default_theme="$value" ;;
      check_official_abi) check_official_abi="$value" ;;
      *) fail "unknown config key: $key" ;;
    esac
  done < "$file"

  # 已测试版本白名单：ABI 与补丁仅对这些版本验证过，构建必须从中选择
  (( ${#supported_versions[@]} >= 1 )) || fail "supported_versions must not be empty"
  local v
  for v in "${supported_versions[@]}"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid supported version: $v"
  done

  # 工作流输入覆盖（环境变量，留空 = 使用 conf 默认值）
  lan_ip="${CFG_LAN_IP:-$lan_ip}"
  password="${CFG_PASSWORD:-$password}"
  rootfs_size="${CFG_ROOTFS_SIZE:-$rootfs_size}"
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
