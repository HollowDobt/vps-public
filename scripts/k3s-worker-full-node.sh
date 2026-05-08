#!/usr/bin/env bash
# k3s 子节点全流程接入脚本。
#
# 这个脚本给新刷好的普通节点使用。它会按顺序执行基础初始化、
# 初始化校验、接入 Headscale，然后把当前节点加入 k3s 集群。
# 已经承载业务的机器应改用菜单中的单项脚本，避免重复调整基础系统配置。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-worker-full-node"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

apply_vps_defaults k3s-worker-full-node

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

说明：
  - 用于新 VPS 作为 k3s 子节点接入集群。
  - 默认会执行基础初始化、初始化校验、Headscale 接入和 k3s agent 部署。
  - 运行前请准备 HEADSCALE_AUTHKEY、K3S_SERVER_URL 和 K3S_AGENT_TOKEN。
  - 建议先执行系统重装。
EOF
}

derive_defaults() {
  derive_node_identity_defaults k3s-worker
}

persist_defaults() {
  persist_node_identity_defaults
}

validate_input() {
  validate_bool K3S_WORKER_FULL_RUN_BOOTSTRAP "$K3S_WORKER_FULL_RUN_BOOTSTRAP"
  validate_bool K3S_WORKER_FULL_RUN_CHECK "$K3S_WORKER_FULL_RUN_CHECK"
  validate_bool K3S_WORKER_FULL_RUN_HEADSCALE "$K3S_WORKER_FULL_RUN_HEADSCALE"

  if [[ "$K3S_WORKER_FULL_RUN_HEADSCALE" == "1" ]] && ! tailnet_already_up; then
    if [[ -z "$HEADSCALE_SERVER_URL" && -z "$HEADSCALE_SERVER_HOSTNAME" && -z "${CLOUDFLARE_ZONE:-}" ]]; then
      die "请设置 HEADSCALE_SERVER_URL，或设置 HEADSCALE_SERVER_HOSTNAME/CLOUDFLARE_ZONE。"
    fi
    [[ -n "$HEADSCALE_AUTHKEY" ]] || die "请先填写 HEADSCALE_AUTHKEY。"
  fi
}

main() {
  parse_noarg_or_help "$@"
  prepare_vps_run
  derive_defaults
  validate_input
  begin_run
  persist_env_file
  persist_defaults

  log "建议先执行系统重装。"

  if [[ "$K3S_WORKER_FULL_RUN_BOOTSTRAP" == "1" ]]; then
    run_child "Debian 13 基础初始化" "$(script_path debian13-bootstrap.sh)"
  fi
  if [[ "$K3S_WORKER_FULL_RUN_CHECK" == "1" ]]; then
    run_child "Debian 13 初始化校验" "$(script_path debian13-bootstrap-check.sh)"
  fi
  if [[ "$K3S_WORKER_FULL_RUN_HEADSCALE" == "1" ]]; then
    run_child "接入 Headscale" "$(script_path headscale-client.sh)"
  fi

  run_child "部署 k3s 子节点" "$(script_path k3s-agent.sh)"

  finish_run
  printf '\nk3s 子节点全流程完成。\n'
  printf '  配置文件：/etc/hlwdot/vps.env\n'
}

main "$@"
