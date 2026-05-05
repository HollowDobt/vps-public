#!/usr/bin/env bash
# Headscale 认证密钥生成脚本。
#
# 在 Headscale 主节点执行。默认生成一次性 preauth key，复制到客户端
# .env 的 HEADSCALE_AUTHKEY 后即可完成自动接入。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/headscale-authkey"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

HEADSCALE_USER="${HEADSCALE_USER:-hollow}"
HEADSCALE_PREAUTH_REUSABLE="${HEADSCALE_PREAUTH_REUSABLE:-0}"
HEADSCALE_PREAUTH_EXPIRATION="${HEADSCALE_PREAUTH_EXPIRATION:-24h}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

常用配置：
  HEADSCALE_USER=hollow
  HEADSCALE_PREAUTH_REUSABLE=0
  HEADSCALE_PREAUTH_EXPIRATION=24h
EOF
}

validate_input() {
  command_exists headscale || die "缺少 headscale 命令，请在 Headscale 主节点执行。"
  validate_bool HEADSCALE_PREAUTH_REUSABLE "$HEADSCALE_PREAUTH_REUSABLE"
}

ensure_headscale_user() {
  if command_exists jq &&
    headscale users list -o json 2>/dev/null |
    jq -e --arg user "$HEADSCALE_USER" '.[] | select(.name == $user)' >/dev/null 2>&1; then
    return 0
  fi

  if headscale users list 2>/dev/null | awk -v user="$HEADSCALE_USER" '$0 ~ user { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi

  log "创建 Headscale 用户：$HEADSCALE_USER"
  headscale users create "$HEADSCALE_USER" || headscale user create "$HEADSCALE_USER"
}

headscale_user_id() {
  command_exists jq || return 1
  headscale users list -o json 2>/dev/null |
    jq -r --arg user "$HEADSCALE_USER" '.[] | select(.name == $user) | .id' |
    awk 'NF { print; exit }'
}

create_key() {
  local args=()
  local user_ref

  user_ref="$(headscale_user_id || true)"
  [[ -n "$user_ref" ]] || user_ref="$HEADSCALE_USER"
  args=(preauthkeys create --user "$user_ref" --expiration "$HEADSCALE_PREAUTH_EXPIRATION")
  [[ "$HEADSCALE_PREAUTH_REUSABLE" == "1" ]] && args+=(--reusable)

  printf '\n新认证密钥：\n'
  headscale "${args[@]}"
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
  validate_input
  ensure_headscale_user
  create_key
}

main "$@"
