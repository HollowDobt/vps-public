#!/usr/bin/env bash
# Headscale 主节点部署脚本。
#
# 适合第一台 VPN 控制节点使用。脚本部署 Headscale 服务端，
# 按配置生成认证密钥，并可把本机接入 hollow-net。基础初始化
# 只由菜单中的初始化项负责，不在这里自动执行。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/headscale-main-node"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

HEADSCALE_MAIN_JOIN_SELF="${HEADSCALE_MAIN_JOIN_SELF:-1}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"
BOOTSTRAP_HOSTNAME="${BOOTSTRAP_HOSTNAME:-}"
HEADSCALE_SERVER_URL="${HEADSCALE_SERVER_URL:-}"
HEADSCALE_SERVER_HOSTNAME="${HEADSCALE_SERVER_HOSTNAME:-}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

说明：
  - 用于 Headscale 主节点首次部署。
  - 不会执行 Debian 13 基础初始化；需要时先从菜单单独执行。
  - HEADSCALE_SERVER_URL 可设置为 auto；如果设置了 CLOUDFLARE_ZONE，
    默认使用 https://headscale.\$CLOUDFLARE_ZONE。
  - 脚本会把生成的 hostname、auth key、Headscale IP 写入 /etc/hlwdot/vps.env。
EOF
}

script_path() {
  printf '%s/%s\n' "$SCRIPT_DIR" "$1"
}

run_child() {
  local label="$1"
  local file="$2"

  [[ -r "$file" ]] || die "找不到脚本：$file"
  log "开始：$label"
  bash "$file"
  log "完成：$label"
}

reload_system_env() {
  [[ -r /etc/hlwdot/vps.env ]] || return 0
  set -a
  # shellcheck disable=SC1091
  . /etc/hlwdot/vps.env
  set +a
}

tailnet_already_up() {
  command_exists tailscale || return 1
  tailscale status --self >/dev/null 2>&1 || return 1
  [[ -n "$(tailscale_ipv4)" ]]
}

derive_defaults() {
  local host

  if [[ -z "$HEADSCALE_CLIENT_HOSTNAME" ]]; then
    if [[ -n "$BOOTSTRAP_HOSTNAME" ]]; then
      HEADSCALE_CLIENT_HOSTNAME="$BOOTSTRAP_HOSTNAME"
    else
      HEADSCALE_CLIENT_HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'server')"
    fi
  fi
  if [[ -z "$K3S_NODE_NAME" ]]; then
    K3S_NODE_NAME="$HEADSCALE_CLIENT_HOSTNAME"
  fi
  if [[ -z "$BOOTSTRAP_HOSTNAME" ]]; then
    BOOTSTRAP_HOSTNAME="$HEADSCALE_CLIENT_HOSTNAME"
  fi

  case "$HEADSCALE_SERVER_URL" in
    '' | auto | https://headscale.example.com | http://headscale.example.com)
      if [[ -n "$HEADSCALE_SERVER_HOSTNAME" ]]; then
        host="$HEADSCALE_SERVER_HOSTNAME"
      elif [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
        host="headscale.${CLOUDFLARE_ZONE%.}"
      else
        host="$(hostname -f 2>/dev/null || true)"
      fi
      [[ -n "$host" && "$host" == *.* ]] || die "请设置 HEADSCALE_SERVER_URL，或设置 CLOUDFLARE_ZONE 让脚本自动生成域名。"
      HEADSCALE_SERVER_URL="https://${host}"
      ;;
  esac
}

persist_defaults() {
  persist_env_value HEADSCALE_CLIENT_HOSTNAME "$HEADSCALE_CLIENT_HOSTNAME"
  persist_env_value K3S_NODE_NAME "$K3S_NODE_NAME"
  persist_env_value BOOTSTRAP_HOSTNAME "$BOOTSTRAP_HOSTNAME"
  persist_env_value HEADSCALE_SERVER_URL "$HEADSCALE_SERVER_URL"
}

validate_input() {
  validate_bool HEADSCALE_MAIN_JOIN_SELF "$HEADSCALE_MAIN_JOIN_SELF"
  [[ "$HEADSCALE_SERVER_URL" =~ ^https?:// ]] || die "HEADSCALE_SERVER_URL 必须以 http:// 或 https:// 开头。"
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
  recover_previous_run
  derive_defaults
  validate_input
  begin_run
  persist_env_file
  persist_defaults

  run_child "Headscale 服务端部署" "$(script_path headscale-server.sh)"
  reload_system_env

  if [[ "$HEADSCALE_MAIN_JOIN_SELF" == "1" ]]; then
    if ! tailnet_already_up; then
      run_child "生成 Headscale 认证密钥" "$(script_path headscale-authkey.sh)"
      reload_system_env
    fi
    run_child "本机接入 Headscale" "$(script_path headscale-client.sh)"
  fi

  finish_run
  printf '\nHeadscale 主节点部署完成。\n'
  printf '  server_url：%s\n' "$HEADSCALE_SERVER_URL"
  printf '  配置文件：/etc/hlwdot/vps.env\n'
}

main "$@"
