#!/usr/bin/env bash

# Shared firmware.conf parsing helpers. Source this file from other scripts.

fail() { echo "error: $*" >&2; exit 1; }

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_firmware_config() {
  local file="$1" key value octet
  local -a octets
  [[ -f "$file" ]] || fail "config file not found: $file"

  default_series=""
  lan_ip=""
  password=""
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
      default_series) default_series="$value" ;;
      lan_ip) lan_ip="$value" ;;
      password) password="$value" ;;
      default_theme) default_theme="$value" ;;
      check_official_abi) check_official_abi="$value" ;;
      *) fail "unknown config key: $key" ;;
    esac
  done < "$file"

  [[ "$default_series" =~ ^(24\.10|25\.12)$ ]] ||
    fail "default_series must be 24.10 or 25.12"
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
