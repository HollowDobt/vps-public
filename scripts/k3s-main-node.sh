#!/usr/bin/env bash
# k3s 主节点部署脚本。
#
# 适合 Kubernetes 控制节点使用。脚本会确认本机已接入 Headscale，
# 然后部署 k3s server，并按配置部署 Flux GitOps。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-main-node"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

K3S_MAIN_ENABLE_FLUX="${K3S_MAIN_ENABLE_FLUX:-1}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"
BOOTSTRAP_HOSTNAME="${BOOTSTRAP_HOSTNAME:-}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

说明：
  - 用于 k3s 主节点。
  - 运行前会确认本机已接入 Headscale 网络。
  - Debian 13 基础初始化和 Headscale 接入请先从菜单执行。
  - K3S_MAIN_ENABLE_FLUX=1 时会自动部署 Flux GitOps。
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

derive_defaults() {
  if [[ -z "$HEADSCALE_CLIENT_HOSTNAME" ]]; then
    if [[ -n "$BOOTSTRAP_HOSTNAME" ]]; then
      HEADSCALE_CLIENT_HOSTNAME="$BOOTSTRAP_HOSTNAME"
    else
      HEADSCALE_CLIENT_HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'k3s-main')"
    fi
  fi
  if [[ -z "$K3S_NODE_NAME" ]]; then
    K3S_NODE_NAME="$HEADSCALE_CLIENT_HOSTNAME"
  fi
  if [[ -z "$BOOTSTRAP_HOSTNAME" ]]; then
    BOOTSTRAP_HOSTNAME="$HEADSCALE_CLIENT_HOSTNAME"
  fi
}

persist_defaults() {
  persist_env_value HEADSCALE_CLIENT_HOSTNAME "$HEADSCALE_CLIENT_HOSTNAME"
  persist_env_value K3S_NODE_NAME "$K3S_NODE_NAME"
  persist_env_value BOOTSTRAP_HOSTNAME "$BOOTSTRAP_HOSTNAME"
}

validate_input() {
  validate_bool K3S_MAIN_ENABLE_FLUX "$K3S_MAIN_ENABLE_FLUX"
}

check_headscale_dependency() {
  local tailnet_ip
  local iface="${HOLLOW_NET_IFACE:-hollow-net}"

  tailnet_ip="$(require_tailnet_ready)"
  log "Headscale 网络已就绪：${iface} ${tailnet_ip}"
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

  check_headscale_dependency
  run_child "部署 k3s 主节点" "$(script_path k3s-server.sh)"
  run_child "记录 k3s 子节点 token" "$(script_path k3s-token.sh)"

  if [[ "$K3S_MAIN_ENABLE_FLUX" == "1" ]]; then
    run_child "部署 Flux GitOps" "$(script_path flux-gitops.sh)"
  fi

  finish_run
  printf '\nk3s 主节点部署完成。\n'
  printf '  配置文件：/etc/hlwdot/vps.env\n'
}

main "$@"
