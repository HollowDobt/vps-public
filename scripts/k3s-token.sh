#!/usr/bin/env bash
# k3s 节点 token 查看脚本。
#
# 在 k3s 主节点执行，保存子节点接入所需 token；--show 时才输出完整 token。

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
  sudo bash $SCRIPT_NAME --show

说明：
  在 k3s 主节点执行。默认只把子节点接入 token 写入
  /etc/hlwdot/vps.env，不向终端输出完整 token。
  只有显式使用 --show 时才打印完整 token。
EOF
}

parse_args() {
  SHOW_TOKEN=0
  [[ "$#" -le 1 ]] || {
    usage
    die "参数过多。"
  }
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    --show)
      SHOW_TOKEN=1
      ;;
    '')
      ;;
    *)
      usage
      die "未知参数：$1"
      ;;
  esac
}

masked_token() {
  local token="$1"
  local length="${#token}"

  if ((length <= 12)); then
    printf '***'
  else
    printf '%s...%s' "${token:0:6}" "${token: -6}"
  fi
}

report_token_saved() {
  local label="$1"
  local token="$2"
  local key="$3"

  if [[ "${SHOW_TOKEN:-0}" == "1" ]]; then
    printf '\n%s：\n%s\n' "$label" "$token"
  else
    printf '\n%s 已写入 /etc/hlwdot/vps.env 的 %s：%s\n' "$label" "$key" "$(masked_token "$token")"
  fi
}

main() {
  local token=''

  parse_args "$@"
  prepare_vps_run
  begin_run

  if [[ -r /var/lib/rancher/k3s/server/node-token ]]; then
    token="$(awk 'NF { print; exit }' /var/lib/rancher/k3s/server/node-token)"
    [[ -n "$token" ]] || die "k3s node-token 文件为空。"
    persist_env_value K3S_AGENT_TOKEN "$token"
    report_token_saved "k3s node token" "$token" K3S_AGENT_TOKEN
  elif [[ -r /etc/rancher/k3s/config.yaml ]]; then
    token="$(awk -F: '$1 == "token" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^"|"$/, "", $2); print $2; exit }' /etc/rancher/k3s/config.yaml)"
    [[ -n "$token" ]] || die "未能从 /etc/rancher/k3s/config.yaml 读取 token。"
    persist_env_value K3S_TOKEN "$token"
    report_token_saved "k3s config token" "$token" K3S_TOKEN
  else
    die "未找到 k3s token，请确认当前机器是 k3s 主节点。"
  fi

  finish_run
}

main "$@"
