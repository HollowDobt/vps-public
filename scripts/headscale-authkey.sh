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

apply_vps_defaults headscale-authkey

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
  local output
  local key

  user_ref="$(headscale_user_id || true)"
  if [[ -n "$user_ref" ]]; then
    args=(preauthkeys create --user "$user_ref" --expiration "$HEADSCALE_PREAUTH_EXPIRATION")
  else
    args=(preauthkeys create --expiration "$HEADSCALE_PREAUTH_EXPIRATION")
  fi
  if [[ "$HEADSCALE_PREAUTH_REUSABLE" == "1" ]]; then
    args+=(--reusable)
  fi

  printf '\n新认证密钥：\n'
  if command_exists jq && output="$(headscale "${args[@]}" -o json 2>/dev/null)"; then
    key="$(jq -r '.key // .preAuthKey.key // .pre_auth_key.key // empty' <<<"$output")"
    if [[ -n "$key" && "$key" != "null" ]]; then
      printf '%s\n' "$key"
      persist_env_value HEADSCALE_AUTHKEY "$key"
      return 0
    fi
  fi

  output="$(headscale "${args[@]}")"
  printf '%s\n' "$output"
  key="$(grep -Eo '(hskey-auth|tskey-auth|tskey)-[A-Za-z0-9._=-]+' <<<"$output" | head -n 1 || true)"
  if [[ -n "$key" ]]; then
    persist_env_value HEADSCALE_AUTHKEY "$key"
  else
    warn "未能从输出中解析认证密钥，请手工复制上方输出。"
  fi
}

main() {
  parse_noarg_or_help "$@"
  prepare_vps_run
  begin_run
  persist_env_file
  validate_input
  persist_env_value HEADSCALE_USER "$HEADSCALE_USER"
  ensure_headscale_user
  create_key
  finish_run
}

main "$@"
