#!/usr/bin/env bash
# k3s 子节点部署脚本。
#
# 使用官方安装脚本部署 k3s agent，并接入已有 k3s server。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-agent"
readonly K3S_CONFIG="/etc/rancher/k3s/config.yaml"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

K3S_VERSION="${K3S_VERSION:-}"
K3S_SERVER_URL="${K3S_SERVER_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_AGENT_TOKEN="${K3S_AGENT_TOKEN:-}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"
K3S_NODE_IP="${K3S_NODE_IP:-}"
K3S_FLANNEL_IFACE="${K3S_FLANNEL_IFACE:-}"
K3S_AGENT_EXTRA_ARGS="${K3S_AGENT_EXTRA_ARGS:-}"
K3S_SERVER_HOSTNAME="${K3S_SERVER_HOSTNAME:-}"
K3S_API_PORT="${K3S_API_PORT:-6443}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

必填配置：
  K3S_SERVER_URL=https://主节点:6443
  K3S_AGENT_TOKEN=子节点接入 token
  或 K3S_TOKEN=共享集群 token

常用配置：
  K3S_NODE_NAME=server-worker-1
  K3S_SERVER_HOSTNAME=k3s-main.example.com
  K3S_FLANNEL_IFACE=hollow-net

说明：
  - 必须先接入 Headscale；脚本会用 Headscale 分配的 IPv4 作为 node-ip。
EOF
}

validate_input() {
  [[ "$HOLLOW_NET_IFACE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "HOLLOW_NET_IFACE 包含非法字符。"
  [[ "$K3S_API_PORT" =~ ^[0-9]+$ ]] || die "K3S_API_PORT 必须是数字。"
  if [[ -n "$HEADSCALE_CLIENT_HOSTNAME" && -n "$K3S_NODE_NAME" && "$HEADSCALE_CLIENT_HOSTNAME" != "$K3S_NODE_NAME" ]]; then
    die "K3S_NODE_NAME 必须与 HEADSCALE_CLIENT_HOSTNAME 一致。"
  fi
  if [[ -z "$K3S_SERVER_URL" && -n "$K3S_SERVER_HOSTNAME" ]]; then
    K3S_SERVER_URL="https://${K3S_SERVER_HOSTNAME}:${K3S_API_PORT}"
  fi
  [[ -n "$K3S_SERVER_URL" ]] || die "请设置 K3S_SERVER_URL。"
  [[ "$K3S_SERVER_URL" =~ ^https:// ]] || die "K3S_SERVER_URL 必须以 https:// 开头。"
  if [[ -z "$K3S_TOKEN" && -n "$K3S_AGENT_TOKEN" ]]; then
    K3S_TOKEN="$K3S_AGENT_TOKEN"
  fi
  [[ -n "$K3S_TOKEN" ]] || die "请设置 K3S_TOKEN 或 K3S_AGENT_TOKEN。"
}

apply_tailnet_defaults() {
  local tailnet_ip

  tailnet_ip="$(require_tailnet_ready)"
  [[ -n "$K3S_NODE_NAME" ]] || K3S_NODE_NAME="${HEADSCALE_CLIENT_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'k3s-agent')}"
  [[ -n "$K3S_NODE_IP" ]] || K3S_NODE_IP="$tailnet_ip"
  [[ -n "$K3S_FLANNEL_IFACE" ]] || K3S_FLANNEL_IFACE="$HOLLOW_NET_IFACE"
}

persist_k3s_agent_config() {
  persist_env_value K3S_SERVER_URL "$K3S_SERVER_URL"
  persist_env_value K3S_NODE_NAME "$K3S_NODE_NAME"
  persist_env_value K3S_NODE_IP "$K3S_NODE_IP"
  persist_env_value K3S_FLANNEL_IFACE "$K3S_FLANNEL_IFACE"
  persist_env_value HOLLOW_NET_IFACE "$HOLLOW_NET_IFACE"
  [[ -n "$K3S_AGENT_TOKEN" ]] && persist_env_value K3S_AGENT_TOKEN "$K3S_AGENT_TOKEN"
}

write_k3s_config() {
  local temp_config

  install -d -o root -g root -m 0700 /etc/rancher/k3s
  temp_config="$(mktemp_managed)"
  {
    printf 'server: '
    yaml_quote "$K3S_SERVER_URL"
    printf '\n'
    printf 'token: '
    yaml_quote "$K3S_TOKEN"
    printf '\n'
    if [[ -n "$K3S_NODE_NAME" ]]; then
      printf 'node-name: '
      yaml_quote "$K3S_NODE_NAME"
      printf '\n'
    fi
    if [[ -n "$K3S_NODE_IP" ]]; then
      printf 'node-ip: '
      yaml_quote "$K3S_NODE_IP"
      printf '\n'
    fi
    if [[ -n "$K3S_FLANNEL_IFACE" ]]; then
      printf 'flannel-iface: '
      yaml_quote "$K3S_FLANNEL_IFACE"
      printf '\n'
    fi
  } >"$temp_config"

  atomic_install_file "$temp_config" "$K3S_CONFIG" 0600 root root
}

install_k3s_agent() {
  local install_script
  local exec_cmd='agent'
  local env_args=()

  apt_install ca-certificates curl gnupg lsb-release
  install_script="$(mktemp_managed)"
  download_file https://get.k3s.io "$install_script"

  [[ -n "$K3S_AGENT_EXTRA_ARGS" ]] && exec_cmd+=" ${K3S_AGENT_EXTRA_ARGS}"
  env_args+=(INSTALL_K3S_EXEC="$exec_cmd")
  [[ -n "$K3S_VERSION" ]] && env_args+=(INSTALL_K3S_VERSION="$K3S_VERSION")

  log "安装 k3s agent。"
  env "${env_args[@]}" sh "$install_script"
  systemctl enable --now k3s-agent
}

print_summary() {
  printf '\nk3s 子节点部署完成。\n'
  printf '  systemd：k3s-agent.service\n'
  printf '  server：%s\n' "$K3S_SERVER_URL"
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
  validate_input
  apply_tailnet_defaults
  begin_run
  persist_env_file
  persist_k3s_agent_config
  write_k3s_config
  install_k3s_agent
  print_summary
  finish_run
}

main "$@"
