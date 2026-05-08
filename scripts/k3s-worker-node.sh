#!/usr/bin/env bash
# k3s 子节点部署脚本。
#
# 适合普通工作节点使用。脚本会确认本机已接入 Headscale，
# 然后用主节点提供的地址与 token 接入 k3s 集群。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-worker-node"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

apply_vps_defaults k3s-worker-node

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

说明：
  - 用于 k3s 子节点。
  - 运行前会确认本机已接入 Headscale 网络。
  - Debian 13 基础初始化和 Headscale 接入请先从菜单执行。
  - 必须已经准备好 K3S_SERVER_URL，以及 K3S_AGENT_TOKEN 或 K3S_TOKEN。
EOF
}

derive_defaults() {
  derive_node_identity_defaults k3s-worker
}

persist_defaults() {
  persist_node_identity_defaults
}

check_headscale_dependency() {
  log_tailnet_ready
}

main() {
  parse_noarg_or_help "$@"
  prepare_vps_run
  derive_defaults
  begin_run
  persist_env_file
  persist_defaults

  check_headscale_dependency
  run_child "部署 k3s 子节点" "$(script_path k3s-agent.sh)"

  finish_run
  printf '\nk3s 子节点部署完成。\n'
  printf '  配置文件：/etc/hlwdot/vps.env\n'
}

main "$@"
