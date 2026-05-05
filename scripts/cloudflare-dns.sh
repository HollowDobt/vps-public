#!/usr/bin/env bash
# Cloudflare DNS 配置脚本。
#
# 根据 .env 中的域名和 Cloudflare API Token 自动创建或更新 DNS 记录。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/cloudflare-dns"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

HEADSCALE_SERVER_URL="${HEADSCALE_SERVER_URL:-}"
CLOUDFLARE_DNS_TARGET_IPV4="${CLOUDFLARE_DNS_TARGET_IPV4:-auto}"
CLOUDFLARE_DNS_PROXIED="${CLOUDFLARE_DNS_PROXIED:-0}"
CLOUDFLARE_DNS_TTL="${CLOUDFLARE_DNS_TTL:-120}"
CLOUDFLARE_HEADSCALE_DNS="${CLOUDFLARE_HEADSCALE_DNS:-1}"
CLOUDFLARE_K3S_DNS_TARGET="${CLOUDFLARE_K3S_DNS_TARGET:-tailnet}"
CLOUDFLARE_K3S_DNS_NAMES="${CLOUDFLARE_K3S_DNS_NAMES:-}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

必填：
  CLOUDFLARE_API_TOKEN=...
  或 CLOUDFLARE_EMAIL=... + CLOUDFLARE_API_KEY=...

常用：
  HEADSCALE_SERVER_URL=https://headscale.example.com
  CLOUDFLARE_K3S_DNS_NAMES=api.example.com,*.apps.example.com
  CLOUDFLARE_DNS_TARGET_IPV4=auto
  CLOUDFLARE_K3S_DNS_TARGET=tailnet
EOF
}

validate_input() {
  cloudflare_configured || die "请设置 CLOUDFLARE_API_TOKEN，或同时设置 CLOUDFLARE_EMAIL 与 CLOUDFLARE_API_KEY。"
  validate_bool CLOUDFLARE_DNS_PROXIED "$CLOUDFLARE_DNS_PROXIED"
  validate_bool CLOUDFLARE_HEADSCALE_DNS "$CLOUDFLARE_HEADSCALE_DNS"
  [[ "$CLOUDFLARE_DNS_TTL" =~ ^[0-9]+$ ]] || die "CLOUDFLARE_DNS_TTL 必须是数字。"
}

dns_target() {
  if [[ "$CLOUDFLARE_DNS_TARGET_IPV4" == "auto" || -z "$CLOUDFLARE_DNS_TARGET_IPV4" ]]; then
    current_public_ipv4
  else
    printf '%s\n' "$CLOUDFLARE_DNS_TARGET_IPV4"
  fi
}

k3s_dns_target() {
  case "$CLOUDFLARE_K3S_DNS_TARGET" in
    tailnet)
      require_tailnet_ready
      ;;
    auto | public)
      dns_target
      ;;
    *)
      printf '%s\n' "$CLOUDFLARE_K3S_DNS_TARGET"
      ;;
  esac
}

configure_records() {
  local target
  local k3s_target
  local host
  local name

  target="$(dns_target)"
  k3s_target=''

  if [[ "$CLOUDFLARE_HEADSCALE_DNS" == "1" ]]; then
    [[ -n "$HEADSCALE_SERVER_URL" ]] || die "CLOUDFLARE_HEADSCALE_DNS=1 时必须设置 HEADSCALE_SERVER_URL。"
    host="$(url_host "$HEADSCALE_SERVER_URL")"
    cloudflare_upsert_record "$host" A "$target" "$CLOUDFLARE_DNS_PROXIED" "$CLOUDFLARE_DNS_TTL"
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -n "$k3s_target" ]] || k3s_target="$(k3s_dns_target)"
    cloudflare_upsert_record "$name" A "$k3s_target" "$CLOUDFLARE_DNS_PROXIED" "$CLOUDFLARE_DNS_TTL"
  done < <(split_words "$CLOUDFLARE_K3S_DNS_NAMES")
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    '')
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac

  require_root
  setup_state_dir
  install_traps
  load_env
  validate_input
  apt_install curl jq ca-certificates
  configure_records
}

main "$@"
