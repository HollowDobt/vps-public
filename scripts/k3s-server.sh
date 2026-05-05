#!/usr/bin/env bash
# k3s 主节点部署脚本。
#
# 使用官方安装脚本部署 k3s server。默认启用 cluster-init，
# 方便主节点使用 k3s 自带 etcd snapshot，并按需配置加密备份定时器。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-server"
readonly K3S_CONFIG="/etc/rancher/k3s/config.yaml"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

K3S_VERSION="${K3S_VERSION:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_AGENT_TOKEN="${K3S_AGENT_TOKEN:-}"
K3S_CLUSTER_INIT="${K3S_CLUSTER_INIT:-1}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"
K3S_NODE_IP="${K3S_NODE_IP:-}"
K3S_ADVERTISE_ADDRESS="${K3S_ADVERTISE_ADDRESS:-}"
K3S_FLANNEL_IFACE="${K3S_FLANNEL_IFACE:-}"
K3S_CLUSTER_CIDR="${K3S_CLUSTER_CIDR:-10.42.0.0/16}"
K3S_SERVICE_CIDR="${K3S_SERVICE_CIDR:-10.43.0.0/16}"
K3S_DISABLE_COMPONENTS="${K3S_DISABLE_COMPONENTS:-}"
K3S_KUBECONFIG_MODE="${K3S_KUBECONFIG_MODE:-0600}"
K3S_ETCD_SNAPSHOT_SCHEDULE="${K3S_ETCD_SNAPSHOT_SCHEDULE:-0 */12 * * *}"
K3S_ETCD_SNAPSHOT_RETENTION="${K3S_ETCD_SNAPSHOT_RETENTION:-5}"
K3S_ETCD_SNAPSHOT_COMPRESS="${K3S_ETCD_SNAPSHOT_COMPRESS:-1}"
K3S_SERVER_EXTRA_ARGS="${K3S_SERVER_EXTRA_ARGS:-}"
K3S_UFW_ALLOW="${K3S_UFW_ALLOW:-1}"
K3S_UFW_INTERFACE="${K3S_UFW_INTERFACE:-}"
K3S_API_PORT="${K3S_API_PORT:-6443}"
K3S_SERVER_HOSTNAME="${K3S_SERVER_HOSTNAME:-}"
K3S_SERVER_URL="${K3S_SERVER_URL:-}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
CLOUDFLARE_K3S_DNS_NAMES="${CLOUDFLARE_K3S_DNS_NAMES:-}"
CLOUDFLARE_DNS_PROXIED="${CLOUDFLARE_DNS_PROXIED:-0}"
CLOUDFLARE_DNS_TTL="${CLOUDFLARE_DNS_TTL:-120}"
K3S_AUTO_TLS_SAN=''

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

常用配置：
  K3S_TOKEN=共享集群 token
  K3S_NODE_NAME=server3
  K3S_SERVER_HOSTNAME=k3s-main.example.com
  K3S_FLANNEL_IFACE=hollow-net
  BACKUP_ENABLE=1
  BACKUP_GPG_EMAILS=you@example.com
  BACKUP_RCLONE_DESTS=remote:path

说明：
  - 必须先接入 Headscale；脚本会用 Headscale 分配的 IPv4 作为 node-ip 和 advertise-address。
EOF
}

validate_input() {
  validate_bool K3S_CLUSTER_INIT "$K3S_CLUSTER_INIT"
  validate_bool K3S_ETCD_SNAPSHOT_COMPRESS "$K3S_ETCD_SNAPSHOT_COMPRESS"
  validate_bool K3S_UFW_ALLOW "$K3S_UFW_ALLOW"
  validate_bool CLOUDFLARE_DNS_PROXIED "$CLOUDFLARE_DNS_PROXIED"
  [[ "$HOLLOW_NET_IFACE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "HOLLOW_NET_IFACE 包含非法字符。"
  if [[ -n "$HEADSCALE_CLIENT_HOSTNAME" && -n "$K3S_NODE_NAME" && "$HEADSCALE_CLIENT_HOSTNAME" != "$K3S_NODE_NAME" ]]; then
    die "K3S_NODE_NAME 必须与 HEADSCALE_CLIENT_HOSTNAME 一致。"
  fi
  [[ "$K3S_ETCD_SNAPSHOT_RETENTION" =~ ^[0-9]+$ ]] || die "K3S_ETCD_SNAPSHOT_RETENTION 必须是数字。"
  [[ "$K3S_API_PORT" =~ ^[0-9]+$ ]] || die "K3S_API_PORT 必须是数字。"
  validate_backup_config
}

append_tls_san() {
  local value="$1"

  [[ -n "$value" ]] || return 0
  [[ "$value" == "localhost" || "$value" == "localhost.localdomain" ]] && return 0
  if ! grep -Fxq "$value" <<<"$K3S_AUTO_TLS_SAN"; then
    K3S_AUTO_TLS_SAN+="${value}"$'\n'
  fi
}

apply_tailnet_defaults() {
  local tailnet_ip
  local host_fqdn
  local public_ip

  tailnet_ip="$(require_tailnet_ready)"
  [[ -n "$K3S_NODE_NAME" ]] || K3S_NODE_NAME="${HEADSCALE_CLIENT_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'k3s-server')}"
  [[ -n "$K3S_NODE_IP" ]] || K3S_NODE_IP="$tailnet_ip"
  [[ -n "$K3S_ADVERTISE_ADDRESS" ]] || K3S_ADVERTISE_ADDRESS="$tailnet_ip"
  [[ -n "$K3S_FLANNEL_IFACE" ]] || K3S_FLANNEL_IFACE="$HOLLOW_NET_IFACE"
  [[ -n "$K3S_UFW_INTERFACE" ]] || K3S_UFW_INTERFACE="$HOLLOW_NET_IFACE"

  host_fqdn="$(hostname -f 2>/dev/null || true)"
  public_ip="$(current_public_ipv4 2>/dev/null || true)"

  append_tls_san "$K3S_NODE_NAME"
  append_tls_san "$host_fqdn"
  append_tls_san "$K3S_NODE_IP"
  append_tls_san "$K3S_ADVERTISE_ADDRESS"
  append_tls_san "$K3S_SERVER_HOSTNAME"
  append_tls_san "$public_ip"
}

resolve_server_url() {
  if [[ -n "$K3S_SERVER_URL" ]]; then
    return 0
  fi
  if [[ -n "$K3S_SERVER_HOSTNAME" ]]; then
    K3S_SERVER_URL="https://${K3S_SERVER_HOSTNAME}:${K3S_API_PORT}"
  else
    K3S_SERVER_URL="https://${K3S_ADVERTISE_ADDRESS}:${K3S_API_PORT}"
  fi
}

existing_config_token() {
  [[ -r "$K3S_CONFIG" ]] || return 1
  awk -F: '$1 == "token" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^"|"$/, "", $2); print $2; exit }' "$K3S_CONFIG"
}

ensure_token() {
  local existing

  [[ -n "$K3S_TOKEN" ]] && {
    persist_env_value K3S_TOKEN "$K3S_TOKEN"
    return 0
  }
  existing="$(existing_config_token || true)"
  if [[ -n "$existing" ]]; then
    K3S_TOKEN="$existing"
    persist_env_value K3S_TOKEN "$K3S_TOKEN"
    return 0
  fi

  K3S_TOKEN="$(openssl rand -hex 32)"
  persist_env_value K3S_TOKEN "$K3S_TOKEN"
  log "已生成 k3s token。"
}

persist_k3s_server_config() {
  persist_env_value K3S_NODE_NAME "$K3S_NODE_NAME"
  persist_env_value K3S_NODE_IP "$K3S_NODE_IP"
  persist_env_value K3S_ADVERTISE_ADDRESS "$K3S_ADVERTISE_ADDRESS"
  persist_env_value K3S_FLANNEL_IFACE "$K3S_FLANNEL_IFACE"
  persist_env_value K3S_UFW_INTERFACE "$K3S_UFW_INTERFACE"
  persist_env_value K3S_API_PORT "$K3S_API_PORT"
  persist_env_value K3S_SERVER_URL "$K3S_SERVER_URL"
  [[ -n "$K3S_SERVER_HOSTNAME" ]] && persist_env_value K3S_SERVER_HOSTNAME "$K3S_SERVER_HOSTNAME"
}

write_k3s_config() {
  local temp_config

  install -d -o root -g root -m 0700 /etc/rancher/k3s
  temp_config="$(mktemp_managed)"
  {
    printf 'token: '
    yaml_quote "$K3S_TOKEN"
    printf '\n'
    printf 'write-kubeconfig-mode: '
    yaml_quote "$K3S_KUBECONFIG_MODE"
    printf '\n'
    printf 'cluster-cidr: '
    yaml_quote "$K3S_CLUSTER_CIDR"
    printf '\n'
    printf 'service-cidr: '
    yaml_quote "$K3S_SERVICE_CIDR"
    printf '\n'

    [[ "$K3S_CLUSTER_INIT" == "1" ]] && printf 'cluster-init: true\n'
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
    if [[ -n "$K3S_ADVERTISE_ADDRESS" ]]; then
      printf 'advertise-address: '
      yaml_quote "$K3S_ADVERTISE_ADDRESS"
      printf '\n'
    fi
    if [[ -n "$K3S_FLANNEL_IFACE" ]]; then
      printf 'flannel-iface: '
      yaml_quote "$K3S_FLANNEL_IFACE"
      printf '\n'
    fi
    if [[ -n "$K3S_DISABLE_COMPONENTS" ]]; then
      printf 'disable:\n'
      write_yaml_list '  ' "$K3S_DISABLE_COMPONENTS"
    fi
    if [[ -n "$K3S_AUTO_TLS_SAN" ]]; then
      printf 'tls-san:\n'
      write_yaml_list '  ' "$K3S_AUTO_TLS_SAN"
    fi
    if [[ "$K3S_CLUSTER_INIT" == "1" ]]; then
      printf 'etcd-snapshot-schedule-cron: '
      yaml_quote "$K3S_ETCD_SNAPSHOT_SCHEDULE"
      printf '\n'
      printf 'etcd-snapshot-retention: %s\n' "$K3S_ETCD_SNAPSHOT_RETENTION"
      [[ "$K3S_ETCD_SNAPSHOT_COMPRESS" == "1" ]] && printf 'etcd-snapshot-compress: true\n'
    fi
  } >"$temp_config"

  atomic_install_file "$temp_config" "$K3S_CONFIG" 0600 root root
}

install_k3s() {
  local install_script
  local exec_cmd='server'
  local env_args=()

  apt_install ca-certificates curl gnupg lsb-release openssl
  install_script="$(mktemp_managed)"
  download_file https://get.k3s.io "$install_script"

  [[ -n "$K3S_SERVER_EXTRA_ARGS" ]] && exec_cmd+=" ${K3S_SERVER_EXTRA_ARGS}"
  env_args+=(INSTALL_K3S_EXEC="$exec_cmd")
  [[ -n "$K3S_VERSION" ]] && env_args+=(INSTALL_K3S_VERSION="$K3S_VERSION")

  log "安装 k3s server。"
  env "${env_args[@]}" sh "$install_script"
  systemctl enable --now k3s
}

persist_agent_token_if_available() {
  local token_file="/var/lib/rancher/k3s/server/node-token"
  local token

  [[ -r "$token_file" ]] || return 0
  token="$(awk 'NF { print; exit }' "$token_file")"
  [[ -n "$token" ]] || return 0
  K3S_AGENT_TOKEN="$token"
  persist_env_value K3S_AGENT_TOKEN "$K3S_AGENT_TOKEN"
}

configure_ufw() {
  [[ "$K3S_UFW_ALLOW" == "1" ]] || return 0
  command_exists ufw || return 0

  if [[ -n "$K3S_UFW_INTERFACE" ]]; then
    ufw allow in on "$K3S_UFW_INTERFACE" to any port "$K3S_API_PORT" proto tcp comment 'k3s api'
  else
    ufw allow "${K3S_API_PORT}/tcp" comment 'k3s api'
  fi
}

configure_cloudflare_dns_if_needed() {
  local name

  cloudflare_configured || return 0
  apt_install curl jq

  if [[ -n "$K3S_SERVER_HOSTNAME" ]]; then
    cloudflare_upsert_record "$K3S_SERVER_HOSTNAME" A "$K3S_ADVERTISE_ADDRESS" "$CLOUDFLARE_DNS_PROXIED" "$CLOUDFLARE_DNS_TTL"
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    cloudflare_upsert_record "$name" A "$K3S_ADVERTISE_ADDRESS" "$CLOUDFLARE_DNS_PROXIED" "$CLOUDFLARE_DNS_TTL"
  done < <(split_words "$CLOUDFLARE_K3S_DNS_NAMES")
}

print_summary() {
  printf '\nk3s 主节点部署完成。\n'
  printf '  systemd：k3s.service\n'
  printf '  kubeconfig：/etc/rancher/k3s/k3s.yaml\n'
  printf '  token：/etc/rancher/k3s/config.yaml\n'
  kubectl get nodes -o wide 2>/dev/null || true
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
  resolve_server_url
  begin_run
  persist_env_file
  ensure_token
  persist_k3s_server_config
  write_k3s_config
  configure_ufw
  configure_cloudflare_dns_if_needed
  install_k3s
  persist_agent_token_if_available
  install_backup_timer k3s
  print_summary
  finish_run
}

main "$@"
