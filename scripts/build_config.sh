#!/usr/bin/env bash

set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

validate_lan_ip() {
  local value="$1" name="${2:-lan_ip}" octet
  [[ -n "$value" ]] || fail "$name is required"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "invalid $name: $value"
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || fail "invalid $name: $value"
  done
}

load_config() {
  local file="$1" key value
  lan_ip=""
  password=""
  check_official_abi=true
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="${key%$'\r'}"
    value="${value%$'\r'}"
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    case "$key" in
      lan_ip) lan_ip="$value" ;;
      password) password="$value" ;;
      check_official_abi) check_official_abi="$value" ;;
      *) fail "unknown config key: $key" ;;
    esac
  done < "$file"
  validate_lan_ip "$lan_ip" lan_ip
  [[ "$check_official_abi" == true || "$check_official_abi" == false ]] ||
    fail "check_official_abi must be true or false"
}

clone_packages() {
  local source_dir="$1" list="$2" line
  local -a command
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r -a command <<< "$line"
    [[ "${command[0]:-}" == git && "${command[1]:-}" == clone ]] ||
      fail "only git clone commands are allowed: $line"
    (cd "$source_dir" && "${command[@]}")
  done < "$list"
}

apply_device_config() {
  local source_dir="$1" shadow password_hash
  sed -i "s/192\.168\.1\.1/$lan_ip/g" \
    "$source_dir/package/base-files/files/bin/config_generate"

  if [[ -n "$password" ]]; then
    shadow="$source_dir/package/base-files/files/etc/shadow"
    password_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
    sed -i "s|^root:[^:]*:|root:${password_hash}:|" "$shadow"
  fi
}

prepare() {
  local source_dir="$1" config="$2" packages="$3"
  load_config "$config"
  clone_packages "$source_dir" "$packages"
  apply_device_config "$source_dir"
}

prepare_imagebuilder_files() {
  local files_dir="$1" config="$2"
  local root_password_b64 uci_defaults_dir uci_defaults_file
  load_config "$config"
  root_password_b64="$(printf '%s' "$password" | base64 -w0)"

  uci_defaults_dir="$files_dir/etc/uci-defaults"
  uci_defaults_file="$uci_defaults_dir/99-h28k-custom"
  mkdir -p "$uci_defaults_dir"

  cat > "$uci_defaults_file" <<EOF
#!/bin/sh
set -e

uci set network.lan.ipaddr='$lan_ip'
uci commit network || true

if [ -n '$root_password_b64' ]; then
  ROOT_PASSWORD="\$(printf '%s' '$root_password_b64' | base64 -d)"
  printf '%s\n%s\n' "\$ROOT_PASSWORD" "\$ROOT_PASSWORD" | passwd root >/dev/null 2>&1 || true
fi

exit 0
EOF

  chmod +x "$uci_defaults_file"
  echo "Prepared ImageBuilder custom files: $uci_defaults_file"
}

check_abi() {
  local source_dir="$1" config="$2" version="$3" tag="$4" github_env="${5:-}"
  local vermagic built_abi official_kernel official_abi distfeeds base_url
  load_config "$config"
  vermagic="$(find "$source_dir"/build_dir/target-* \
    -path '*/linux-rockchip_armv8/linux-*/.vermagic' -print -quit)"
  [[ -n "$vermagic" ]] || fail "kernel .vermagic was not found"
  built_abi="$(tr -d '[:space:]' < "$vermagic")"
  echo "release=$tag"
  echo "built_abi=$built_abi"

  if [[ "$check_official_abi" == true ]]; then
    base_url="${IMMORTALWRT_BASE_URL:-https://downloads.immortalwrt.org/releases/$version/targets/rockchip/armv8}"
    official_kernel="$(curl -fsSL \
      "$base_url/packages/index.json" \
      | jq -r '.packages.kernel')"
    official_abi="$(sed -nE 's/.*~([0-9a-f]{32})-r[0-9]+/\1/p' <<< "$official_kernel")"
    echo "official_abi=$official_abi"
    if [[ "$built_abi" != "$official_abi" ]]; then
      echo "ABI validation result: FAIL (built ABI does not match official release ABI)" >&2
      fail "kernel ABI does not match official release"
    fi
    distfeeds="$(find "$source_dir/staging_dir" "$source_dir/build_dir" \
      -path '*/etc/apk/repositories.d/distfeeds.list' -print 2>/dev/null \
      | while read -r file; do
          grep -Eq "/targets/rockchip/armv8/kmods/[^/]+-${built_abi}/packages\\.adb$" "$file" && {
            echo "$file"
            break
          }
        done)"
    if [[ -z "$distfeeds" ]]; then
      echo "ABI validation result: FAIL (official kmods repository is missing)" >&2
      fail "official kmods repository is missing"
    fi
    echo "ABI validation result: PASS (built ABI matches official release ABI)"
  else
    echo 'official ABI check disabled'
  fi
  [[ -z "$github_env" ]] || echo "KERNEL_ABI=$built_abi" >> "$github_env"
}

case "${1:-}" in
  validate)
    load_config "$2"
    clone_count="$(grep -cEv '^[[:space:]]*(#|$)' "$3" || true)"
    echo "lan_ip=$lan_ip password=$([[ -n "$password" ]] && echo set || echo unchanged) abi=$check_official_abi git_packages=$clone_count"
    ;;
  prepare) prepare "$2" "$3" "$4" ;;
  prepare-imagebuilder-files) prepare_imagebuilder_files "$2" "$3" ;;
  check-abi) check_abi "$2" "$3" "$4" "$5" "${6:-}" ;;
  *) fail "unknown command: ${1:-}" ;;
esac
