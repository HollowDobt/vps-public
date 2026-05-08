#!/usr/bin/env bash
# k3s 开机依赖修复脚本。
#
# 已部署 k3s 的机器可直接执行本脚本，给 k3s/k3s-agent 增加
# systemd 启动顺序保护，避免重启时早于 hollow-net 启动。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/k3s-boot-guard"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME [k3s|k3s-agent]

说明：
  - 不传参数时自动检测本机已有的 k3s 服务。
  - 只写入 systemd drop-in，不重装 k3s，不重启当前服务。
EOF
}

service_exists() {
  local service_name="$1"

  systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null |
    awk -v unit="${service_name}.service" '$1 == unit { found = 1 } END { exit found ? 0 : 1 }'
}

main() {
  local services=()
  local service_name

  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    k3s | k3s-agent)
      services+=("$1")
      ;;
    '')
      service_exists k3s && services+=(k3s)
      service_exists k3s-agent && services+=(k3s-agent)
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac

  prepare_vps_run
  [[ "${#services[@]}" -gt 0 ]] || die "未检测到 k3s 或 k3s-agent 服务。"

  begin_run
  for service_name in "${services[@]}"; do
    configure_k3s_tailnet_boot_guard "$service_name"
  done
  finish_run
}

main "$@"
