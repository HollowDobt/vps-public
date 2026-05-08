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

apply_vps_defaults k3s-main-node

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

derive_defaults() {
  derive_node_identity_defaults k3s-main
}

persist_defaults() {
  persist_node_identity_defaults
}

validate_input() {
  validate_bool K3S_MAIN_ENABLE_FLUX "$K3S_MAIN_ENABLE_FLUX"
}

main() {
  parse_noarg_or_help "$@"
  prepare_vps_run
  derive_defaults
  validate_input
  begin_run
  persist_env_file
  persist_defaults

  log_tailnet_ready
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
