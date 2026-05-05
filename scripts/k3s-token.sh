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

main() {
  require_root
  setup_state_dir
  load_env

  if [[ -r /var/lib/rancher/k3s/server/node-token ]]; then
    printf '\nk3s node token：\n'
    cat /var/lib/rancher/k3s/server/node-token
    printf '\n'
  elif [[ -r /etc/rancher/k3s/config.yaml ]]; then
    printf '\nk3s config token：\n'
    awk -F: '$1 == "token" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^"|"$/, "", $2); print $2; exit }' /etc/rancher/k3s/config.yaml
  else
    die "未找到 k3s token，请确认当前机器是 k3s 主节点。"
  fi
}

main "$@"
