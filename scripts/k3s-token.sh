#!/usr/bin/env bash
# k3s 节点 token 查看脚本。
#
# 在 k3s 主节点执行，输出子节点接入所需 token。

set -Eeuo pipefail
IFS=$'\n\t'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-token"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

说明：
  在 k3s 主节点执行。脚本会输出子节点接入 token，并写入
  /etc/hlwdot/vps.env 的 K3S_AGENT_TOKEN。
EOF
}

main() {
  local token=''

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
  begin_run

  if [[ -r /var/lib/rancher/k3s/server/node-token ]]; then
    token="$(awk 'NF { print; exit }' /var/lib/rancher/k3s/server/node-token)"
    [[ -n "$token" ]] || die "k3s node-token 文件为空。"
    printf '\nk3s node token：\n%s\n' "$token"
    persist_env_value K3S_AGENT_TOKEN "$token"
  elif [[ -r /etc/rancher/k3s/config.yaml ]]; then
    token="$(awk -F: '$1 == "token" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^"|"$/, "", $2); print $2; exit }' /etc/rancher/k3s/config.yaml)"
    [[ -n "$token" ]] || die "未能从 /etc/rancher/k3s/config.yaml 读取 token。"
    printf '\nk3s config token：\n%s\n' "$token"
    persist_env_value K3S_TOKEN "$token"
  else
    die "未找到 k3s token，请确认当前机器是 k3s 主节点。"
  fi

  finish_run
}

main "$@"
