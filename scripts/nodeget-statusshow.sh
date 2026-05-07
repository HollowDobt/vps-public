#!/bin/sh
# NodeGet StatusShow for hollow-net.
#
# Deploys a locally modified NodeGet-StatusShow build and a NodeGet Server on
# Alpine/OpenRC NAT LXC nodes. Public access is only through a Cloudflare Tunnel;
# all local listeners are bound to 127.0.0.1.

set -eu
umask 027

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/homebrew/bin"
export PATH

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

STATE_DIR="/var/lib/hlwdot/nodeget-statusshow"
TMP_DIR="${STATE_DIR}/tmp"
APP_ROOT="/opt/hlwdot/nodeget-statusshow"
SRC_DIR="${APP_ROOT}/source"
DIST_DIR="${APP_ROOT}/current"
CONFIG_DIR="/etc/hlwdot/nodeget-statusshow"
NODEGET_CONF="/etc/nodeget-server.conf"
NODEGET_CREDENTIALS="${CONFIG_DIR}/nodeget-server.credentials"
NODEGET_SERVER_UUID_FILE="${CONFIG_DIR}/server.uuid"
CADDYFILE="${CONFIG_DIR}/Caddyfile"
HOLLOW_JSON="${STATE_DIR}/hollow-nodes.json"
HOLLOW_SYNC_SCRIPT="/usr/local/lib/hlwdot/nodeget-hollow-sync.sh"
CLOUDFLARED_RUN_SCRIPT="/usr/local/lib/hlwdot/nodeget-cloudflared-run.sh"
TAILNET_INGRESS_RUN_SCRIPT="/usr/local/lib/hlwdot/nodeget-tailnet-ingress.sh"

NODEGET_SERVER_SERVICE="nodeget-server"
NODEGET_TAILNET_INGRESS_SERVICE="hlwdot-nodeget-tailnet-ingress"
NODEGET_STATUS_CADDY_SERVICE="hlwdot-nodeget-status-caddy"
NODEGET_HOLLOW_SYNC_SERVICE="hlwdot-nodeget-hollow-sync"
NODEGET_CLOUDFLARED_SERVICE="hlwdot-nodeget-cloudflared"
HOLLOW_NET_IP=''
SELF_TEST_ROOT=''

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] 警告：%s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] 错误：%s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
用法：
  sh $SCRIPT_NAME
  sh $SCRIPT_NAME --merge-env
  sh $SCRIPT_NAME --self-test
  sh $SCRIPT_NAME --self-test-build
  sh $SCRIPT_NAME --build-prebuilt-asset scripts/assets/nodeget-statusshow-dist.tar.gz

必填：
  NODEGET_STATUS_HOSTNAME=nodeget.example.com
  NODEGET_CLOUDFLARED_TOKEN=Cloudflare Tunnel token

最终公开数据读取需要：
  NODEGET_VISITOR_TOKEN=只读 Visitor Token

说明：
  - 仅支持 Alpine Linux + OpenRC。
  - 只读检查当前节点已在 hollow-net，不执行 Headscale 接入。
  - NodeGet Server 与 Caddy 都只监听 127.0.0.1。
  - Agent 内网入口只绑定 hollow-net IPv4，不监听公网。
  - Cloudflare 使用 Tunnel token 运行隧道；可用最小权限 API token
    幂等配置 healthy-page public hostname 和 proxied CNAME。
EOF
}

load_env_file() {
  file="$1"
  [ -r "$file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
  log "读取配置：$file"
}

load_env() {
  if [ -n "${VPS_ENV_FILE:-}" ]; then
    load_env_file "$VPS_ENV_FILE"
  else
    load_env_file /etc/hlwdot/vps.env
    load_env_file "${SCRIPT_DIR}/.env"
  fi
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

json_string() {
  jq -Rn --arg value "$1" '$value'
}

toml_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sed_in_place() {
  expr="$1"
  file="$2"
  tmp="${TMP_DIR:-/tmp}/${SCRIPT_NAME}.$$.sed"

  sed "$expr" "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

split_words() {
  printf '%s\n' "$1" | tr ' ,;' '\n' | awk 'NF { print }'
}

name_alias_segment() {
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for pair in $(split_words "${NODEGET_HOLLOW_NAME_ALIASES:-center:CNETER}"); do
    key=${pair%%:*}
    value=${pair#*:}
    if [ "$key" = "$raw" ] && [ "$value" != "$pair" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  printf '%s\n' "$raw" | tr '[:lower:]' '[:upper:]'
}

hollow_display_name_from_node_name() {
  raw=$(printf '%s' "$1" | sed 's/[.]$//' | tr '[:upper:]' '[:lower:]')
  first=${raw%%.*}
  rest=${raw#*.}
  if [ "$rest" = "$raw" ]; then
    rest=''
  else
    rest=${rest%%.*}
  fi
  number=$(printf '%s' "$first" | sed -n 's/^server\([0-9][0-9]*\)$/\1/p')
  if [ -z "$number" ]; then
    number=$(printf '%s' "$raw" | sed -n 's/^server\([0-9][0-9]*\)[.-].*/\1/p')
  fi
  if [ -n "$number" ] && [ -n "$rest" ]; then
    printf '%s-%s\n' "$(name_alias_segment "$rest")" "$number"
  else
    printf '%s\n' "$raw" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_.-]/-/g'
  fi
}

require_root() {
  [ "$(id -u)" = 0 ] || die "请使用 root 运行。"
}

require_alpine() {
  [ -r /etc/alpine-release ] || die "当前系统不是 Alpine Linux。"
  command_exists apk || die "缺少 apk。"
  command_exists rc-service || die "缺少 OpenRC rc-service。"
  command_exists rc-update || die "缺少 OpenRC rc-update。"
}

validate_bool() {
  name="$1"
  value="$2"
  case "$value" in
    0|1|true|false) ;;
    *) die "${name} 只能是 0/1/true/false。" ;;
  esac
}

setup_state_dir() {
  mkdir -p /etc/hlwdot /opt/hlwdot /var/lib/hlwdot
  mkdir -p "$TMP_DIR" "$APP_ROOT" "$CONFIG_DIR" /usr/local/lib/hlwdot
  chmod 0711 /etc/hlwdot /opt/hlwdot /var/lib/hlwdot
  chmod 0755 "$STATE_DIR" "$APP_ROOT" /usr/local/lib/hlwdot
  chmod 0750 "$CONFIG_DIR"
  chmod 0700 "$TMP_DIR"
}

cleanup_tempfiles() {
  [ -d "$TMP_DIR" ] || return 0
  find "$TMP_DIR" -mindepth 1 -maxdepth 1 -name "${SCRIPT_NAME}.*" -exec rm -rf {} + 2>/dev/null || true
}

on_interrupt() {
  warn "收到中断信号，已停止。重新执行脚本会继续处理未完成步骤。"
  exit 130
}

cleanup_self_test_root() {
  [ -n "$SELF_TEST_ROOT" ] || return 0
  case "$SELF_TEST_ROOT" in
    "${TMPDIR:-/tmp}"/nodeget-statusshow-selftest*|/tmp/nodeget-statusshow-selftest*)
      [ -d "$SELF_TEST_ROOT" ] && rm -rf "$SELF_TEST_ROOT"
      ;;
  esac
}

merge_nodeget_env_files() {
  old_env="$1"
  example_env="$2"
  li_env="$3"
  account_id="${4:-}"
  dir=$(CDPATH= cd -- "$(dirname -- "$old_env")" && pwd)
  base=$(basename "$old_env")
  tmp="${dir}/${base}.merge.$$"
  backup="${dir}/${base}.pre-nodeget-merge.$$"
  block="${dir}/${base}.nodeget-block.$$"
  overrides="${dir}/${base}.nodeget-overrides.$$"

  cleanup_merge() {
    rm -f "$tmp" "$block" "$overrides"
    if [ -f "$backup" ]; then
      cp -p "$backup" "$old_env"
      rm -f "$backup"
    fi
  }

  [ -f "$old_env" ] || die "找不到旧 .env：$old_env"
  [ -f "$example_env" ] || die "找不到 .env.example：$example_env"
  [ -f "$li_env" ] || die "找不到 .env-li：$li_env"

  cp -p "$old_env" "$backup"
  chmod 0600 "$li_env"
  awk '
    /^# NodeGet hollow-net 探针页。/ { keep = 1 }
    keep {
      if (/^# k3s 主节点。/) exit
      print
    }
  ' "$example_env" >"$block"
  [ -s "$block" ] || {
    cleanup_merge
    die ".env.example 缺少 NodeGet 配置段。"
  }

  awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ && $1 ~ /^NODEGET_/ { print }' "$li_env" >"$overrides"
  grep -q '^NODEGET_TUNNEL_NAME=' "$overrides" || printf 'NODEGET_TUNNEL_NAME=healthy-page\n' >>"$overrides"
  if [ -n "$account_id" ] && ! grep -q '^NODEGET_CLOUDFLARE_ACCOUNT_ID=' "$overrides"; then
    printf 'NODEGET_CLOUDFLARE_ACCOUNT_ID=%s\n' "$account_id" >>"$overrides"
  fi
  if [ -n "${NODEGET_DEFAULT_TUNNEL_ID:-}" ] && ! grep -q '^NODEGET_TUNNEL_ID=' "$overrides"; then
    printf 'NODEGET_TUNNEL_ID=%s\n' "$NODEGET_DEFAULT_TUNNEL_ID" >>"$overrides"
  fi
  if [ -n "${NODEGET_DEFAULT_ZONE_ID:-}" ] && ! grep -q '^NODEGET_CLOUDFLARE_ZONE_ID=' "$overrides"; then
    printf 'NODEGET_CLOUDFLARE_ZONE_ID=%s\n' "$NODEGET_DEFAULT_ZONE_ID" >>"$overrides"
  fi

  {
    awk '
      /^# NodeGet hollow-net 探针页。/ { skip = 1; next }
      skip && /^# k3s 主节点。/ { skip = 0; print; next }
      skip { next }
      /^NODEGET_/ { next }
      { print }
    ' "$old_env"
    printf '\n'
    awk -F= '
      FNR == NR {
        if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          key = $1
          line[key] = $0
          order[++n] = key
        }
        next
      }
      /^[A-Za-z_][A-Za-z0-9_]*=/ && $1 ~ /^NODEGET_/ {
        key = $1
        if (key in line) {
          print line[key]
          used[key] = 1
          next
        }
      }
      { print }
      END {
        for (i = 1; i <= n; i++) {
          key = order[i]
          if (!(key in used)) print line[key]
        }
      }
    ' "$overrides" "$block"
  } >"$tmp"
  chmod 0600 "$tmp"

  if ! sh -c '
    set -eu
    set -a
    . "$1"
    set +a
    : "${NODEGET_STATUS_HOSTNAME:?}"
    : "${NODEGET_CLOUDFLARED_TOKEN:?}"
    [ "${NODEGET_TUNNEL_NAME:-}" = healthy-page ]
    : "${NODEGET_TUNNEL_ID:?}"
    case "${NODEGET_TUNNEL_CONFIG_ENABLE:-auto}" in
      auto|0|1|true|false) ;;
      *) exit 13 ;;
    esac
    case "${NODEGET_CLOUDFLARED_ENABLE:-1}" in
      1|true) : "${NODEGET_CLOUDFLARED_TOKEN:?}" ;;
    esac
    case "${NODEGET_TUNNEL_CONFIG_ENABLE:-auto}" in
      1|true) : "${NODEGET_DNS_CONFIG_TOKEN:?}" ;;
      auto) [ -z "${NODEGET_DNS_CONFIG_TOKEN:-}" ] || : "${NODEGET_DNS_CONFIG_TOKEN:?}" ;;
    esac
    [ "${NODEGET_VISITOR_TOKEN:-}" != "YOUR_TOKEN_HERE" ]
    case "${NODEGET_SERVER_LISTEN:-127.0.0.1:2211}" in
      127.0.0.1:*|localhost:*) ;;
      *) exit 11 ;;
    esac
    case "${NODEGET_STATUS_LISTEN:-127.0.0.1:8221}" in
      127.0.0.1:*|localhost:*) ;;
      *) exit 12 ;;
    esac
    [ "${NODEGET_AGENT_LISTEN_ADDR:-auto}" != 0.0.0.0 ]
  ' sh "$tmp"; then
    cleanup_merge
    die ".env 合并后校验失败，已恢复旧 .env。"
  fi

  mv "$tmp" "$old_env"
  rm -f "$block" "$overrides" "$backup"
}

merge_env() {
  account_id="${NODEGET_CLOUDFLARE_ACCOUNT_ID:-${CLOUDFLARE_ACCOUNT_ID:-c23c771ead9657dab9308b8601bd02d9}}"
  NODEGET_DEFAULT_TUNNEL_ID="${NODEGET_DEFAULT_TUNNEL_ID:-52a24e2a-82dc-45b0-ab30-bef831425dfd}"
  NODEGET_DEFAULT_ZONE_ID="${NODEGET_DEFAULT_ZONE_ID:-8e60f95b7b37991976bb8db6df4ea2de}"
  export NODEGET_DEFAULT_TUNNEL_ID
  export NODEGET_DEFAULT_ZONE_ID
  merge_nodeget_env_files "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env-li" "$account_id"
  log ".env 已合并 NodeGet 配置；.env-li 权限已收紧。"
}

on_exit() {
  cleanup_tempfiles
  cleanup_self_test_root
}

trap on_exit EXIT
trap on_interrupt INT TERM

download_file() {
  url="$1"
  output="$2"
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$output"
  elif command_exists wget; then
    wget -q --tries=3 --timeout=15 -O "$output" "$url"
  else
    die "缺少 curl 或 wget，无法下载：$url"
  fi
}

sha256_file() {
  sha256sum "$1" | awk '{ print $1 }'
}

verify_sha256() {
  file="$1"
  expected="$2"
  actual=$(sha256_file "$file")
  [ "$actual" = "$expected" ] || die "sha256 校验失败：$(basename "$file")"
}

ensure_community_repo() {
  repo=''
  version=''

  grep -Eq '^[^#].*/community([[:space:]]*)?$' /etc/apk/repositories && return 0
  repo=$(awk '
    /^[[:space:]]*#/ { next }
    /\/main([[:space:]]*)?$/ {
      sub(/\/main([[:space:]]*)?$/, "/community")
      print
      exit
    }
  ' /etc/apk/repositories)
  if [ -z "$repo" ]; then
    version=$(cut -d. -f1,2 /etc/alpine-release)
    repo="https://dl-cdn.alpinelinux.org/alpine/v${version}/community"
  fi

  log "启用 Alpine community 仓库：$repo"
  printf '\n%s\n' "$repo" >>/etc/apk/repositories
}

install_packages() {
  ensure_community_repo
  apk update
  packages="ca-certificates curl jq openrc caddy coreutils iproute2 socat"
  if [ "${NODEGET_STATUSSHOW_BUILD_MODE:-prebuilt}" = build ]; then
    packages="${packages} git nodejs npm"
  fi
  apk add $packages
  command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
}

apply_defaults() {
  HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
  HEADSCALE_DNS_BASE_DOMAIN="${HEADSCALE_DNS_BASE_DOMAIN:-net.hlwdot.com}"

  NODEGET_VERSION="${NODEGET_VERSION:-v0.1.4}"
  NODEGET_RELEASE_REPO="${NODEGET_RELEASE_REPO:-GenshinMinecraft/NodeGet}"
  NODEGET_STATUSSHOW_REPO="${NODEGET_STATUSSHOW_REPO:-NodeSeekDev/NodeGet-StatusShow}"
  NODEGET_STATUSSHOW_REF="${NODEGET_STATUSSHOW_REF:-276786c0853dbdbbdbfaf529d6b02dad501d689f}"
  NODEGET_STATUSSHOW_VITE_VERSION="${NODEGET_STATUSSHOW_VITE_VERSION:-6.3.5}"
  NODEGET_STATUSSHOW_REACT_PLUGIN_VERSION="${NODEGET_STATUSSHOW_REACT_PLUGIN_VERSION:-4.7.0}"
  NODEGET_STATUSSHOW_TYPES_NODE_VERSION="${NODEGET_STATUSSHOW_TYPES_NODE_VERSION:-20.19.25}"
  NODEGET_STATUSSHOW_MINIFY="${NODEGET_STATUSSHOW_MINIFY:-0}"
  NODEGET_STATUSSHOW_BUILD_MODE="${NODEGET_STATUSSHOW_BUILD_MODE:-prebuilt}"
  NODEGET_STATUSSHOW_PREBUILT_ARCHIVE="${NODEGET_STATUSSHOW_PREBUILT_ARCHIVE:-${SCRIPT_DIR}/assets/nodeget-statusshow-dist.tar.gz}"

  NODEGET_STATUS_HOSTNAME="${NODEGET_STATUS_HOSTNAME:-nodeget.hlwdot.com}"
  NODEGET_STATUS_SITE_NAME="${NODEGET_STATUS_SITE_NAME:-Hollow Net Status}"
  NODEGET_STATUS_FOOTER="${NODEGET_STATUS_FOOTER:-Powered by NodeGet}"
  NODEGET_STATUS_LOGO="${NODEGET_STATUS_LOGO:-}"
  NODEGET_VISITOR_TOKEN="${NODEGET_VISITOR_TOKEN:-}"
  NODEGET_SERVER_NAME="${NODEGET_SERVER_NAME:-hollow-net}"
  NODEGET_SERVER_UUID="${NODEGET_SERVER_UUID:-auto_gen}"
  NODEGET_SERVER_LISTEN="${NODEGET_SERVER_LISTEN:-127.0.0.1:2211}"
  NODEGET_STATUS_LISTEN="${NODEGET_STATUS_LISTEN:-127.0.0.1:8221}"
  NODEGET_DATABASE_URL="${NODEGET_DATABASE_URL:-sqlite:///var/lib/nodeget-server/nodeget-server.db?mode=rwc}"
  NODEGET_JSONRPC_MAX_CONNECTIONS="${NODEGET_JSONRPC_MAX_CONNECTIONS:-80}"
  NODEGET_AGENT_INGRESS_ENABLE="${NODEGET_AGENT_INGRESS_ENABLE:-1}"
  NODEGET_AGENT_LISTEN_ADDR="${NODEGET_AGENT_LISTEN_ADDR:-auto}"
  NODEGET_AGENT_LISTEN_PORT="${NODEGET_AGENT_LISTEN_PORT:-2211}"

  NODEGET_CLOUDFLARED_ENABLE="${NODEGET_CLOUDFLARED_ENABLE:-1}"
  NODEGET_CLOUDFLARED_TOKEN="${NODEGET_CLOUDFLARED_TOKEN:-}"
  NODEGET_CLOUDFLARED_VERSION="${NODEGET_CLOUDFLARED_VERSION:-2026.3.0}"
  NODEGET_TUNNEL_CONFIG_ENABLE="${NODEGET_TUNNEL_CONFIG_ENABLE:-auto}"
  NODEGET_TUNNEL_NAME="${NODEGET_TUNNEL_NAME:-healthy-page}"
  NODEGET_TUNNEL_ID="${NODEGET_TUNNEL_ID:-}"
  NODEGET_DNS_CONFIG_TOKEN="${NODEGET_DNS_CONFIG_TOKEN:-}"
  NODEGET_CLOUDFLARE_ACCOUNT_ID="${NODEGET_CLOUDFLARE_ACCOUNT_ID:-${CLOUDFLARE_ACCOUNT_ID:-}}"
  NODEGET_CLOUDFLARE_ZONE="${NODEGET_CLOUDFLARE_ZONE:-${CLOUDFLARE_ZONE:-hlwdot.com}}"
  NODEGET_CLOUDFLARE_ZONE_ID="${NODEGET_CLOUDFLARE_ZONE_ID:-${CLOUDFLARE_ZONE_ID:-}}"

  NODEGET_HOLLOW_SYNC_INTERVAL_SEC="${NODEGET_HOLLOW_SYNC_INTERVAL_SEC:-30}"
  NODEGET_HOLLOW_DNS_SUFFIXES="${NODEGET_HOLLOW_DNS_SUFFIXES:-${HEADSCALE_DNS_BASE_DOMAIN},hlwdot.com}"
  NODEGET_HOLLOW_NAME_ALIASES="${NODEGET_HOLLOW_NAME_ALIASES:-center:CNETER}"
  NODEGET_HOLLOW_PUBLISH_IP="${NODEGET_HOLLOW_PUBLISH_IP:-0}"
}

validate_input() {
  case "$NODEGET_STATUS_HOSTNAME" in
    ''|*/*|*:*|*[!A-Za-z0-9_.-]*|.*|*.) die "NODEGET_STATUS_HOSTNAME 格式错误。" ;;
  esac
  if [ -z "$NODEGET_VISITOR_TOKEN" ]; then
    warn "NODEGET_VISITOR_TOKEN 为空；首跑会先初始化主控和隧道，创建 Visitor token 后重跑即可启用公开数据读取。"
  fi
  [ "$NODEGET_VISITOR_TOKEN" != "YOUR_TOKEN_HERE" ] || die "NODEGET_VISITOR_TOKEN 仍是占位符。"
  case "$NODEGET_SERVER_LISTEN" in
    127.0.0.1:*|localhost:*) ;;
    *) die "NODEGET_SERVER_LISTEN 必须绑定 127.0.0.1，不能监听公网。" ;;
  esac
  case "$NODEGET_STATUS_LISTEN" in
    127.0.0.1:*|localhost:*) ;;
    *) die "NODEGET_STATUS_LISTEN 必须绑定 127.0.0.1，不能监听公网。" ;;
  esac
  validate_bool NODEGET_CLOUDFLARED_ENABLE "$NODEGET_CLOUDFLARED_ENABLE"
  validate_bool NODEGET_HOLLOW_PUBLISH_IP "$NODEGET_HOLLOW_PUBLISH_IP"
  validate_bool NODEGET_AGENT_INGRESS_ENABLE "$NODEGET_AGENT_INGRESS_ENABLE"
  validate_bool NODEGET_STATUSSHOW_MINIFY "$NODEGET_STATUSSHOW_MINIFY"
  case "$NODEGET_STATUSSHOW_BUILD_MODE" in
    prebuilt|build) ;;
    *) die "NODEGET_STATUSSHOW_BUILD_MODE 只能是 prebuilt 或 build。" ;;
  esac
  case "$NODEGET_TUNNEL_CONFIG_ENABLE" in
    auto|0|1|true|false) ;;
    *) die "NODEGET_TUNNEL_CONFIG_ENABLE 只能是 auto/0/1/true/false。" ;;
  esac
  case "$NODEGET_JSONRPC_MAX_CONNECTIONS" in
    ''|*[!0-9]*) die "NODEGET_JSONRPC_MAX_CONNECTIONS 必须是数字。" ;;
  esac
  [ "$NODEGET_JSONRPC_MAX_CONNECTIONS" -ge 1 ] || die "NODEGET_JSONRPC_MAX_CONNECTIONS 必须大于 0。"
  case "$NODEGET_AGENT_LISTEN_PORT" in
    ''|*[!0-9]*) die "NODEGET_AGENT_LISTEN_PORT 必须是数字。" ;;
  esac
  [ "$NODEGET_AGENT_LISTEN_PORT" -ge 1 ] && [ "$NODEGET_AGENT_LISTEN_PORT" -le 65535 ] || die "NODEGET_AGENT_LISTEN_PORT 超出范围。"
  case "$NODEGET_AGENT_LISTEN_ADDR" in
    auto|100.*|127.0.0.1|[0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "NODEGET_AGENT_LISTEN_ADDR 必须是 auto 或明确 IPv4 地址。" ;;
  esac
  [ "$NODEGET_AGENT_LISTEN_ADDR" != "0.0.0.0" ] || die "NODEGET_AGENT_LISTEN_ADDR 不能是 0.0.0.0。"
  if { [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; } &&
    [ "$NODEGET_AGENT_LISTEN_ADDR" = "127.0.0.1" ]; then
    die "NODEGET_AGENT_LISTEN_ADDR 不能是 127.0.0.1；Agent 入口必须绑定 hollow-net 地址。"
  fi
  case "$NODEGET_HOLLOW_SYNC_INTERVAL_SEC" in
    ''|*[!0-9]*) die "NODEGET_HOLLOW_SYNC_INTERVAL_SEC 必须是数字。" ;;
  esac
  [ "$NODEGET_HOLLOW_SYNC_INTERVAL_SEC" -ge 10 ] || die "NODEGET_HOLLOW_SYNC_INTERVAL_SEC 不能低于 10 秒。"
  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    [ -n "$NODEGET_CLOUDFLARED_TOKEN" ] || die "请填写 NODEGET_CLOUDFLARED_TOKEN。"
  fi
  if tunnel_config_enabled; then
    [ -n "$NODEGET_DNS_CONFIG_TOKEN" ] || die "请填写 NODEGET_DNS_CONFIG_TOKEN。"
    case "$NODEGET_TUNNEL_NAME" in
      ''|*/*|*[!A-Za-z0-9_.-]*) die "NODEGET_TUNNEL_NAME 格式错误。" ;;
    esac
    if [ -n "$NODEGET_TUNNEL_ID" ]; then
      case "$NODEGET_TUNNEL_ID" in
        ????????-????-????-????-????????????) ;;
        *) die "NODEGET_TUNNEL_ID 格式错误。" ;;
      esac
    fi
    if [ -n "$NODEGET_CLOUDFLARE_ACCOUNT_ID" ]; then
      case "$NODEGET_CLOUDFLARE_ACCOUNT_ID" in
        *[!A-Fa-f0-9]*)
          die "NODEGET_CLOUDFLARE_ACCOUNT_ID 格式错误。"
          ;;
      esac
      [ "${#NODEGET_CLOUDFLARE_ACCOUNT_ID}" -eq 32 ] || die "NODEGET_CLOUDFLARE_ACCOUNT_ID 格式错误。"
    fi
  fi
}

tunnel_config_enabled() {
  case "$NODEGET_TUNNEL_CONFIG_ENABLE" in
    1|true) return 0 ;;
    0|false) return 1 ;;
    auto) [ -n "$NODEGET_DNS_CONFIG_TOKEN" ] ;;
  esac
}

require_hollow_net() {
  ip4=''

  command_exists tailscale || die "缺少 tailscale，请先执行 hollow-net 接入脚本。"
  tailscale status --self >/dev/null 2>&1 || die "当前节点尚未接入 Headscale/hollow-net。"
  if command_exists ip; then
    ip link show "$HOLLOW_NET_IFACE" >/dev/null 2>&1 || die "未找到 hollow-net 网卡：$HOLLOW_NET_IFACE。"
  fi
  ip4=$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }' || true)
  [ -n "$ip4" ] || die "无法读取当前 hollow-net IPv4 地址。"
  HOLLOW_NET_IP="$ip4"
  log "hollow-net 只读检查通过：$HOLLOW_NET_IFACE $ip4"
}

detect_nodeget_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ng_arch="x86_64" ;;
    aarch64|arm64) ng_arch="aarch64" ;;
    armv7l) ng_arch="armv7" ;;
    armv6l) ng_arch="arm" ;;
    i386|i686) ng_arch="i686" ;;
    *) die "NodeGet 不支持当前架构：$(uname -m)" ;;
  esac

  if ldd --version 2>&1 | grep -qi musl; then
    ng_libc="musl"
  else
    ng_libc="gnu"
  fi

  ng_abi=''
  if [ "$ng_arch" = arm ] || [ "$ng_arch" = armv7 ]; then
    if ldd --version 2>&1 | grep -qi 'hard float'; then
      ng_abi="hf"
    fi
  fi

  case "$ng_arch" in
    armv7) printf 'armv7-%seabi%s\n' "$ng_libc" "$ng_abi" ;;
    arm) printf 'arm-%seabi%s\n' "$ng_libc" "$ng_abi" ;;
    *) printf '%s-%s\n' "$ng_arch" "$ng_libc" ;;
  esac
}

detect_cloudflared_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'cloudflared-linux-amd64\n' ;;
    aarch64|arm64) printf 'cloudflared-linux-arm64\n' ;;
    armv7l|armv6l) printf 'cloudflared-linux-arm\n' ;;
    i386|i686) printf 'cloudflared-linux-386\n' ;;
    *) die "cloudflared 不支持当前架构：$(uname -m)" ;;
  esac
}

release_asset_info() {
  repo="$1"
  tag="$2"
  asset="$3"
  json_file="${TMP_DIR}/${SCRIPT_NAME}.$$.$(printf '%s' "$asset" | tr '/ ' '__').json"

  download_file "https://api.github.com/repos/${repo}/releases/tags/${tag}" "$json_file"
  jq -r --arg name "$asset" '
    .assets[]? |
    select(.name == $name) |
    [.browser_download_url, (.digest // "" | sub("^sha256:"; ""))] |
    @tsv
  ' "$json_file" | awk 'NF { print; exit }'
}

install_nodeget_server_binary() {
  target=$(detect_nodeget_arch)
  asset="nodeget-server-linux-${target}"
  info=$(release_asset_info "$NODEGET_RELEASE_REPO" "$NODEGET_VERSION" "$asset")
  [ -n "$info" ] || die "找不到 NodeGet release asset：${NODEGET_RELEASE_REPO} ${NODEGET_VERSION} ${asset}"
  url=$(printf '%s' "$info" | awk -F '\t' '{ print $1 }')
  digest=$(printf '%s' "$info" | awk -F '\t' '{ print $2 }')
  [ -n "$digest" ] || die "NodeGet release asset 缺少 sha256 digest：$asset"

  marker="${STATE_DIR}/nodeget-server.${asset}.${NODEGET_VERSION}.sha256"
  if [ -x /usr/local/bin/nodeget-server ] && [ -r "$marker" ] && [ "$(cat "$marker")" = "$digest" ]; then
    log "NodeGet Server 二进制已是目标版本：$NODEGET_VERSION"
    return 0
  fi

  tmp="${TMP_DIR}/${SCRIPT_NAME}.$$.nodeget-server"
  log "下载 NodeGet Server：${asset} ${NODEGET_VERSION}"
  download_file "$url" "$tmp"
  verify_sha256 "$tmp" "$digest"
  install -m 0755 "$tmp" /usr/local/bin/nodeget-server
  printf '%s\n' "$digest" >"$marker"
}

install_cloudflared_binary() {
  if [ "$NODEGET_CLOUDFLARED_ENABLE" != 1 ] && [ "$NODEGET_CLOUDFLARED_ENABLE" != true ]; then
    return 0
  fi

  asset=$(detect_cloudflared_asset)
  info=$(release_asset_info "cloudflare/cloudflared" "$NODEGET_CLOUDFLARED_VERSION" "$asset")
  [ -n "$info" ] || die "找不到 cloudflared release asset：${NODEGET_CLOUDFLARED_VERSION} ${asset}"
  url=$(printf '%s' "$info" | awk -F '\t' '{ print $1 }')
  digest=$(printf '%s' "$info" | awk -F '\t' '{ print $2 }')
  [ -n "$digest" ] || die "cloudflared release asset 缺少 sha256 digest：$asset"

  marker="${STATE_DIR}/cloudflared.${asset}.${NODEGET_CLOUDFLARED_VERSION}.sha256"
  if [ -x /usr/local/bin/cloudflared ] && [ -r "$marker" ] && [ "$(cat "$marker")" = "$digest" ]; then
    log "cloudflared 二进制已是目标版本：$NODEGET_CLOUDFLARED_VERSION"
    return 0
  fi

  tmp="${TMP_DIR}/${SCRIPT_NAME}.$$.cloudflared"
  log "下载 cloudflared：${asset} ${NODEGET_CLOUDFLARED_VERSION}"
  download_file "$url" "$tmp"
  verify_sha256 "$tmp" "$digest"
  install -m 0755 "$tmp" /usr/local/bin/cloudflared
  printf '%s\n' "$digest" >"$marker"
}

ensure_users() {
  grep -q '^nodeget:' /etc/passwd || adduser -D -H -s /sbin/nologin nodeget
  grep -q '^caddy:' /etc/passwd || adduser -D -H -s /sbin/nologin caddy
  mkdir -p /var/lib/nodeget-server "$STATE_DIR"
  chown -R nodeget:nodeget /var/lib/nodeget-server
  chmod 0750 /var/lib/nodeget-server
  chown root:caddy "$CONFIG_DIR"
  chmod 0750 "$CONFIG_DIR"
  chown -R caddy:caddy "$APP_ROOT" 2>/dev/null || true
}

write_nodeget_config() {
  tmp="${TMP_DIR}/${SCRIPT_NAME}.$$.nodeget-server.conf"
  server_uuid=$(nodeget_server_uuid_value)
  cat >"$tmp" <<EOF
log_level = "warn"
ws_listener = "$(toml_string "$NODEGET_SERVER_LISTEN")"
jsonrpc_max_connections = ${NODEGET_JSONRPC_MAX_CONNECTIONS}
jsonrpc_timing_log_level = "warn"
enable_unix_socket = false
unix_socket_path = "/var/lib/nodeget-server/nodeget-server.sock"
server_uuid = "$(toml_string "$server_uuid")"

[database]
database_url = "$(toml_string "$NODEGET_DATABASE_URL")"
sqlx_log_level = "error"
connect_timeout_ms = 3000
acquire_timeout_ms = 3000
idle_timeout_ms = 3000
max_lifetime_ms = 30000
max_connections = 5
EOF
  install -m 0640 -o root -g nodeget "$tmp" "$NODEGET_CONF"
}

nodeget_server_uuid_value() {
  if [ "$NODEGET_SERVER_UUID" != auto_gen ]; then
    printf '%s\n' "$NODEGET_SERVER_UUID"
    return 0
  fi
  if [ -r "$NODEGET_SERVER_UUID_FILE" ]; then
    awk 'NF { print; exit }' "$NODEGET_SERVER_UUID_FILE"
    return 0
  fi
  if [ -r "$NODEGET_CONF" ]; then
    existing=$(sed -n 's/^[[:space:]]*server_uuid[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p' "$NODEGET_CONF" | awk 'NF && $0 != "auto_gen" { print; exit }')
    if [ -n "${existing:-}" ]; then
      printf '%s\n' "$existing" >"$NODEGET_SERVER_UUID_FILE"
      chmod 0600 "$NODEGET_SERVER_UUID_FILE"
      printf '%s\n' "$existing"
      return 0
    fi
  fi
  if command_exists uuidgen; then
    generated=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    generated=$(cat /proc/sys/kernel/random/uuid)
  else
    die "无法生成 NodeGet server_uuid。"
  fi
  printf '%s\n' "$generated" >"$NODEGET_SERVER_UUID_FILE"
  chmod 0600 "$NODEGET_SERVER_UUID_FILE"
  printf '%s\n' "$generated"
}

write_nodeget_service() {
  init_file="/etc/init.d/${NODEGET_SERVER_SERVICE}"
  cat >"$init_file" <<'EOF'
#!/sbin/openrc-run

name="nodeget-server"
description="NodeGet Server for HlwDot status"
supervisor="${NODEGET_SERVER_SUPERVISOR:-supervise-daemon}"
command="/usr/local/bin/nodeget-server"
command_args="serve -c /etc/nodeget-server.conf"
command_user="nodeget:nodeget"
pidfile="/run/${RC_SVCNAME}.pid"
respawn_delay="${NODEGET_SERVER_RESPAWN_DELAY:-5}"
respawn_max="${NODEGET_SERVER_RESPAWN_MAX:-0}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -o nodeget:nodeget -m 0750 /var/lib/nodeget-server
}
EOF
  chmod 0755 "$init_file"
}

nodeget_server_port() {
  printf '%s\n' "${NODEGET_SERVER_LISTEN##*:}"
}

resolve_agent_listen_addr() {
  if [ "$NODEGET_AGENT_LISTEN_ADDR" = auto ]; then
    [ -n "$HOLLOW_NET_IP" ] || die "无法确定 hollow-net IPv4。"
    printf '%s\n' "$HOLLOW_NET_IP"
  else
    printf '%s\n' "$NODEGET_AGENT_LISTEN_ADDR"
  fi
}

write_tailnet_ingress_service() {
  [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ] || return 0

  listen_addr=$(resolve_agent_listen_addr)
  server_port=$(nodeget_server_port)
  case "$listen_addr" in
    0.0.0.0|'') die "NodeGet Agent 内网入口不能绑定公网/空地址。" ;;
  esac
  if [ "$listen_addr" != "$HOLLOW_NET_IP" ] && [ "$NODEGET_AGENT_LISTEN_ADDR" = auto ]; then
    die "NodeGet Agent 内网入口自动地址异常：$listen_addr"
  fi

  cat >"$TAILNET_INGRESS_RUN_SCRIPT" <<EOF
#!/bin/sh
set -eu
exec /usr/bin/socat TCP-LISTEN:${NODEGET_AGENT_LISTEN_PORT},bind=${listen_addr},fork,reuseaddr TCP:127.0.0.1:${server_port}
EOF
  chmod 0750 "$TAILNET_INGRESS_RUN_SCRIPT"
  chown root:root "$TAILNET_INGRESS_RUN_SCRIPT"

  init_file="/etc/init.d/${NODEGET_TAILNET_INGRESS_SERVICE}"
  cat >"$init_file" <<EOF
#!/sbin/openrc-run

name="${NODEGET_TAILNET_INGRESS_SERVICE}"
description="Tailnet-only NodeGet Agent ingress"
supervisor="\${NODEGET_TAILNET_INGRESS_SUPERVISOR:-supervise-daemon}"
command="${TAILNET_INGRESS_RUN_SCRIPT}"
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay="\${NODEGET_TAILNET_INGRESS_RESPAWN_DELAY:-5}"
respawn_max="\${NODEGET_TAILNET_INGRESS_RESPAWN_MAX:-0}"

depend() {
  need net ${NODEGET_SERVER_SERVICE}
  after hollow-tailscaled tailscale firewall
}
EOF
  chmod 0755 "$init_file"
}

nodeget_db_exists() {
  case "$NODEGET_DATABASE_URL" in
    sqlite://*)
      db=${NODEGET_DATABASE_URL#sqlite://}
      db=${db%%\?*}
      [ -s "$db" ]
      ;;
    *) [ -s /var/lib/nodeget-server/nodeget-server.db ] ;;
  esac
}

run_as_nodeget() {
  su -s /bin/sh nodeget -c "cd /var/lib/nodeget-server && $*"
}

init_nodeget_server() {
  [ -x /usr/local/bin/nodeget-server ] || die "缺少 nodeget-server。"
  if nodeget_db_exists; then
    log "NodeGet Server 数据库已存在，跳过 init。"
    return 0
  fi

  log "初始化 NodeGet Server。"
  log_file="${TMP_DIR}/${SCRIPT_NAME}.$$.nodeget-init.log"
  run_as_nodeget "/usr/local/bin/nodeget-server init -c /etc/nodeget-server.conf" >"$log_file" 2>&1 || {
    sed -n '1,80p' "$log_file" >&2
    die "NodeGet Server 初始化失败。"
  }

  token=$(awk -F 'Super Token: ' '/Super Token:/ { print $2; exit }' "$log_file")
  password=$(awk -F 'Root Password: ' '/Root Password:/ { print $2; exit }' "$log_file")
  server_uuid=$(/usr/local/bin/nodeget-server get-uuid -c /etc/nodeget-server.conf 2>/dev/null | tail -n 1 || true)
  {
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'username=root\n'
    [ -n "$password" ] && printf 'root_password=%s\n' "$(shell_quote "$password")"
    [ -n "$token" ] && printf 'super_token=%s\n' "$(shell_quote "$token")"
    [ -n "$server_uuid" ] && printf 'server_uuid=%s\n' "$(shell_quote "$server_uuid")"
    printf 'note=%s\n' "$(shell_quote '不要把 super_token 放进公开 StatusShow config。公开页只允许使用 Visitor token。')"
  } >"$NODEGET_CREDENTIALS"
  chmod 0600 "$NODEGET_CREDENTIALS"
  chown root:root "$NODEGET_CREDENTIALS"
  log "NodeGet 初始化凭据已保存：$NODEGET_CREDENTIALS"
}

clone_statusshow_source() {
  new_src_dir="${SRC_DIR}.new"
  rm -rf "$new_src_dir"
  mkdir -p "$APP_ROOT"
  log "拉取 NodeGet-StatusShow 固定提交：$NODEGET_STATUSSHOW_REF"
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git clone --depth 1 "https://github.com/${NODEGET_STATUSSHOW_REPO}.git" "$new_src_dir"; then
    rm -rf "$new_src_dir"
    die "NodeGet-StatusShow clone 失败。"
  fi
  if ! (
    cd "$new_src_dir"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git fetch --depth 1 origin "$NODEGET_STATUSSHOW_REF"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git checkout --detach FETCH_HEAD
  ); then
    rm -rf "$new_src_dir"
    die "NodeGet-StatusShow 固定提交 checkout 失败。"
  fi
  rm -rf "$SRC_DIR"
  mv "$new_src_dir" "$SRC_DIR"
}

patch_statusshow_source() {
  app_file="${SRC_DIR}/src/App.tsx"
  types_file="${SRC_DIR}/src/types.ts"
  hook_file="${SRC_DIR}/src/hooks/useHollowNodes.ts"

  grep -q "useHollowNodes" "$app_file" && return 0

  cat >"$hook_file" <<'EOF'
import { useEffect, useState } from 'react'
import type { Node } from '../types'

interface HollowInventory {
  nodes?: HollowInventoryNode[]
}

interface HollowInventoryNode {
  id?: string
  name?: string
  hostname?: string
  online?: boolean
  updated_at?: number
}

const META = {
  region: '',
  hidden: false,
  virtualization: 'hollow-net',
  lat: null,
  lng: null,
  order: 9000,
  price: 0,
  priceUnit: '$',
  priceCycle: 30,
  expireTime: '',
}

function nodeFromInventory(row: HollowInventoryNode): Node | null {
  const host = String(row.hostname || '').trim()
  const name = String(row.name || host).trim()
  if (!host && !name) return null
  const id = String(row.id || host || name).trim()
  const uuid = `hollow:${id}`
  const timestamp = Number(row.updated_at || Date.now())

  return {
    uuid,
    source: 'hollow-net',
    online: Boolean(row.online),
    meta: {
      ...META,
      name: name || host,
      tags: ['hollow-net', 'pending-agent'],
    },
    static: {
      uuid,
      timestamp,
      system: {
        system_host_name: host || name,
        system_name: 'hollow-net',
        virtualization: 'hollow-net',
      },
    },
    dynamic: null,
    history: [],
  }
}

function sameHost(a?: string, b?: string) {
  const left = (a || '').trim().toLowerCase()
  const right = (b || '').trim().toLowerCase()
  if (!left || !right) return false
  return left === right || left.split('.')[0] === right.split('.')[0]
}

export function mergeHollowNodes(nodes: Map<string, Node>, hollow: Map<string, Node>) {
  const out = new Map(nodes)
  for (const h of hollow.values()) {
    const hHost = h.static?.system?.system_host_name
    const match = Array.from(out.values()).find(n => sameHost(n.static?.system?.system_host_name, hHost))
    if (!match) {
      out.set(h.uuid, h)
      continue
    }
    out.set(match.uuid, {
      ...match,
      meta: {
        ...match.meta,
        name: match.meta?.name || h.meta.name,
        tags: Array.from(new Set([...(match.meta?.tags || []), 'hollow-net'])),
      },
    })
  }
  return out
}

export function useHollowNodes() {
  const [nodes, setNodes] = useState<Map<string, Node>>(new Map())

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      try {
        const res = await fetch(`${import.meta.env.BASE_URL}hollow-nodes.json`, { cache: 'no-store' })
        if (!res.ok) throw new Error(`hollow inventory ${res.status}`)
        const data = (await res.json()) as HollowInventory
        if (cancelled) return
        const next = new Map<string, Node>()
        for (const row of data.nodes || []) {
          const node = nodeFromInventory(row)
          if (node) next.set(node.uuid, node)
        }
        setNodes(next)
      } catch {
        if (!cancelled) setNodes(new Map())
      }
    }
    load()
    const timer = setInterval(load, 15000)
    return () => {
      cancelled = true
      clearInterval(timer)
    }
  }, [])

  return nodes
}
EOF

  sed_in_place "s|import { useNodes } from './hooks/useNodes'|import { useNodes } from './hooks/useNodes'\\
import { mergeHollowNodes, useHollowNodes } from './hooks/useHollowNodes'|" "$app_file"
  sed_in_place "s|  const { nodes, errors, pool } = useNodes(config)|  const { nodes, errors, pool } = useNodes(config)\\
  const hollowNodes = useHollowNodes()\\
  const mergedNodes = useMemo(() => mergeHollowNodes(nodes, hollowNodes), [nodes, hollowNodes])|" "$app_file"
  sed_in_place 's/nodes\.values()/mergedNodes.values()/g' "$app_file"
  sed_in_place 's/\[...nodes.values()\]/[...mergedNodes.values()]/g' "$app_file"
  sed_in_place 's/selected ? nodes.get(selected)/selected ? mergedNodes.get(selected)/g' "$app_file"
  sed_in_place 's/\[nodes\]/[mergedNodes]/g' "$app_file"
  sed_in_place 's/\[nodes, query, activeTag, activeRegion, sort, regions\]/[mergedNodes, query, activeTag, activeRegion, sort, regions]/g' "$app_file"

  sed_in_place "s/site_logo?: string/site_logo?: string\\
  hollow_net_inventory?: boolean/" "$types_file"
}

write_statusshow_config_file() {
  config_output="$1"
  mkdir -p "$(dirname "$config_output")"
  cat >"$config_output" <<EOF
{
  "site_name": $(json_string "$NODEGET_STATUS_SITE_NAME"),
  "site_logo": $(json_string "$NODEGET_STATUS_LOGO"),
  "footer": $(json_string "$NODEGET_STATUS_FOOTER"),
  "hollow_net_inventory": true,
  "site_tokens": [
    {
      "name": $(json_string "$NODEGET_SERVER_NAME"),
      "backend_url": $(json_string "wss://${NODEGET_STATUS_HOSTNAME}/nodeget-ws"),
      "token": $(json_string "$NODEGET_VISITOR_TOKEN")
    }
  ]
}
EOF
}

write_statusshow_config() {
  write_statusshow_config_file "${SRC_DIR}/public/config.json"
}

pin_statusshow_build_toolchain() {
  log "固定 StatusShow 构建工具链：vite ${NODEGET_STATUSSHOW_VITE_VERSION}"
  (
    cd "$SRC_DIR"
    npm pkg set \
      "devDependencies.vite=${NODEGET_STATUSSHOW_VITE_VERSION}" \
      "devDependencies.@vitejs/plugin-react=${NODEGET_STATUSSHOW_REACT_PLUGIN_VERSION}" \
      "devDependencies.@types/node=${NODEGET_STATUSSHOW_TYPES_NODE_VERSION}"
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund --cache "$npm_cache"
  )
}

build_statusshow() {
  npm_cache="${TMP_DIR}/${SCRIPT_NAME}.$$.npm-cache"

  if [ "$NODEGET_STATUSSHOW_BUILD_MODE" = prebuilt ]; then
    install_prebuilt_statusshow
    return 0
  fi

  clone_statusshow_source
  patch_statusshow_source
  write_statusshow_config
  pin_statusshow_build_toolchain
  log "安装 StatusShow 前端依赖并构建。"
  rm -rf "$npm_cache"
  (
    cd "$SRC_DIR"
    npm ci --no-audit --no-fund --cache "$npm_cache"
    if [ "$NODEGET_STATUSSHOW_MINIFY" = 1 ] || [ "$NODEGET_STATUSSHOW_MINIFY" = true ]; then
      npm run build
    else
      npm run build -- --minify=false
    fi
  )
  rm -rf "$npm_cache"
  rm -rf "${DIST_DIR}.new"
  mkdir -p "${DIST_DIR}.new"
  cp -R "${SRC_DIR}/dist/." "${DIST_DIR}.new/"
  write_statusshow_config_file "${DIST_DIR}.new/config.json"
  rm -rf "$DIST_DIR"
  mv "${DIST_DIR}.new" "$DIST_DIR"
  chown -R caddy:caddy "$DIST_DIR"
}

install_prebuilt_statusshow() {
  prebuilt_archive="$NODEGET_STATUSSHOW_PREBUILT_ARCHIVE"
  [ -r "$prebuilt_archive" ] || die "找不到 StatusShow 预构建资产：$prebuilt_archive"
  tar -tzf "$prebuilt_archive" | grep -qx './index.html' || die "StatusShow 预构建资产缺少 index.html。"
  if tar -tzf "$prebuilt_archive" | awk '$0 ~ /^\/|(^|\/)\.\.(\/|$)/ { bad = 1 } END { exit bad ? 0 : 1 }'; then
    die "StatusShow 预构建资产包含不安全路径。"
  fi
  rm -rf "${DIST_DIR}.new"
  mkdir -p "${DIST_DIR}.new"
  tar -xzf "$prebuilt_archive" -C "${DIST_DIR}.new"
  write_statusshow_config_file "${DIST_DIR}.new/config.json"
  rm -rf "$DIST_DIR"
  mv "${DIST_DIR}.new" "$DIST_DIR"
  chown -R caddy:caddy "$DIST_DIR"
}

write_hollow_sync_script() {
  cat >"$HOLLOW_SYNC_SCRIPT" <<'EOF'
#!/bin/sh
set -eu

STATE_DIR="${STATE_DIR:-/var/lib/hlwdot/nodeget-statusshow}"
TMP_DIR="${STATE_DIR}/tmp"
HOLLOW_JSON="${HOLLOW_JSON:-${STATE_DIR}/hollow-nodes.json}"
NODEGET_HOLLOW_SYNC_INTERVAL_SEC="${NODEGET_HOLLOW_SYNC_INTERVAL_SEC:-30}"
NODEGET_HOLLOW_DNS_SUFFIXES="${NODEGET_HOLLOW_DNS_SUFFIXES:-net.hlwdot.com,hlwdot.com}"
NODEGET_HOLLOW_NAME_ALIASES="${NODEGET_HOLLOW_NAME_ALIASES:-center:CNETER}"
NODEGET_HOLLOW_PUBLISH_IP="${NODEGET_HOLLOW_PUBLISH_IP:-0}"

mkdir -p "$TMP_DIR"

json_string() {
  jq -Rn --arg value "$1" '$value'
}

split_words() {
  printf '%s\n' "$1" | tr ' ,;' '\n' | awk 'NF { print }'
}

strip_suffixes() {
  value=$(printf '%s' "$1" | sed 's/[.]$//')
  for suffix in $(split_words "$NODEGET_HOLLOW_DNS_SUFFIXES"); do
    suffix=$(printf '%s' "$suffix" | sed 's/[.]$//')
    case "$value" in
      *."$suffix") value=${value%."$suffix"} ;;
    esac
  done
  printf '%s\n' "$value"
}

best_node_name() {
  host=$(printf '%s' "${1:-}" | sed 's/[.]$//')
  dns=$(printf '%s' "${2:-}" | sed 's/[.]$//')
  stripped=''

  if [ -n "$dns" ]; then
    stripped=$(strip_suffixes "$dns")
  fi
  if [ -n "$host" ] && printf '%s' "$host" | grep -q '[.]'; then
    printf '%s\n' "$host"
  elif [ -n "$stripped" ] && printf '%s' "$stripped" | grep -q '[.]'; then
    printf '%s\n' "$stripped"
  elif [ -n "$host" ]; then
    printf '%s\n' "$host"
  else
    printf '%s\n' "$stripped"
  fi
}

alias_segment() {
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for pair in $(split_words "$NODEGET_HOLLOW_NAME_ALIASES"); do
    key=${pair%%:*}
    value=${pair#*:}
    if [ "$key" = "$raw" ] && [ "$value" != "$pair" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  printf '%s\n' "$raw" | tr '[:lower:]' '[:upper:]'
}

hollow_display_name() {
  raw=$(printf '%s' "$1" | sed 's/[.]$//' | tr '[:upper:]' '[:lower:]')
  first=${raw%%.*}
  rest=${raw#*.}
  if [ "$rest" = "$raw" ]; then
    rest=''
  else
    rest=${rest%%.*}
  fi
  number=$(printf '%s' "$first" | sed -n 's/^server\([0-9][0-9]*\)$/\1/p')
  if [ -z "$number" ]; then
    number=$(printf '%s' "$raw" | sed -n 's/^server\([0-9][0-9]*\)[.-].*/\1/p')
  fi
  if [ -n "$number" ] && [ -n "$rest" ]; then
    printf '%s-%s\n' "$(alias_segment "$rest")" "$number"
  else
    printf '%s\n' "$raw" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_.-]/-/g'
  fi
}

hollow_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g'
}

write_once() {
  status_file="${TMP_DIR}/hollow-status.$$"
  rows_file="${TMP_DIR}/hollow-rows.$$"
  out_file="${TMP_DIR}/hollow-nodes.$$"
  now=$(date +%s)

  if [ -n "${TAILSCALE_STATUS_JSON_FILE:-}" ] && [ -r "$TAILSCALE_STATUS_JSON_FILE" ]; then
    cp "$TAILSCALE_STATUS_JSON_FILE" "$status_file"
  elif ! tailscale status --json >"$status_file" 2>/dev/null; then
    printf '{"generated_at":%s,"source":"hollow-net","nodes":[]}\n' "$now" >"$out_file"
    mv "$out_file" "$HOLLOW_JSON"
    return 0
  fi

  jq -r '
    def row($id; $n):
      [
        $id,
        ($n.HostName // ""),
        ($n.DNSName // ""),
        (($n.TailscaleIPs // [])[0] // ""),
        ((if $n.Online == null then true else $n.Online end) | tostring)
      ] | @tsv;
    row("self"; .Self // {}) ,
    ((.Peer // {}) | to_entries[] | row(.key; .value))
  ' "$status_file" >"$rows_file"

  {
    printf '{"generated_at":%s,"source":"hollow-net","nodes":[' "$now"
    first=1
    while IFS="$(printf '\t')" read -r id host dns ip online; do
      raw=$(best_node_name "$host" "$dns")
      [ -n "$raw" ] || continue
      name=$(hollow_display_name "$raw")
      hid=$(hollow_id "$raw")
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"id":%s,"name":%s,"hostname":%s,"online":%s,"updated_at":%s' \
        "$(json_string "$hid")" \
        "$(json_string "$name")" \
        "$(json_string "$raw")" \
        "$online" \
        "$now"
      if [ "$NODEGET_HOLLOW_PUBLISH_IP" = 1 ] || [ "$NODEGET_HOLLOW_PUBLISH_IP" = true ]; then
        printf ',"ip":%s' "$(json_string "$ip")"
      fi
      printf '}'
    done <"$rows_file"
    printf ']}\n'
  } >"$out_file"
  mv "$out_file" "$HOLLOW_JSON"
  chmod 0644 "$HOLLOW_JSON"
}

if [ "${NODEGET_HOLLOW_SYNC_ONCE:-0}" = 1 ]; then
  write_once
  exit 0
fi

while true; do
  write_once || true
  sleep "$NODEGET_HOLLOW_SYNC_INTERVAL_SEC"
done
EOF
  chmod 0755 "$HOLLOW_SYNC_SCRIPT"
}

write_hollow_sync_service() {
  init_file="/etc/init.d/${NODEGET_HOLLOW_SYNC_SERVICE}"
  cat >"$init_file" <<EOF
#!/sbin/openrc-run

name="${NODEGET_HOLLOW_SYNC_SERVICE}"
description="HlwDot hollow-net inventory for NodeGet StatusShow"
supervisor="\${HOLLOW_SYNC_SUPERVISOR:-supervise-daemon}"
command="${HOLLOW_SYNC_SCRIPT}"
command_user="root:root"
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay="\${HOLLOW_SYNC_RESPAWN_DELAY:-5}"
respawn_max="\${HOLLOW_SYNC_RESPAWN_MAX:-0}"

export STATE_DIR="${STATE_DIR}"
export HOLLOW_JSON="${HOLLOW_JSON}"
export NODEGET_HOLLOW_SYNC_INTERVAL_SEC="${NODEGET_HOLLOW_SYNC_INTERVAL_SEC}"
export NODEGET_HOLLOW_DNS_SUFFIXES="$(printf '%s' "$NODEGET_HOLLOW_DNS_SUFFIXES" | sed 's/"/\\"/g')"
export NODEGET_HOLLOW_NAME_ALIASES="$(printf '%s' "$NODEGET_HOLLOW_NAME_ALIASES" | sed 's/"/\\"/g')"
export NODEGET_HOLLOW_PUBLISH_IP="${NODEGET_HOLLOW_PUBLISH_IP}"

depend() {
  need net
  after hollow-tailscaled tailscale
}

start_pre() {
  checkpath -d -m 0755 "${STATE_DIR}"
  checkpath -d -m 0700 "${TMP_DIR}"
}
EOF
  chmod 0755 "$init_file"
}

write_caddy_config() {
  port=${NODEGET_STATUS_LISTEN##*:}
  cat >"$CADDYFILE" <<EOF
{
  admin off
  auto_https off
}

http://:${port} {
  bind 127.0.0.1
  encode zstd gzip

  header {
    X-Content-Type-Options nosniff
    Referrer-Policy no-referrer
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
    Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss://${NODEGET_STATUS_HOSTNAME}; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
  }

  @inventory path /hollow-nodes.json
  header @inventory Cache-Control "no-store"
  handle /hollow-nodes.json {
    root * ${STATE_DIR}
    file_server
  }

  handle /nodeget-ws* {
    rewrite * /
    reverse_proxy http://${NODEGET_SERVER_LISTEN}
  }

  handle {
    root * ${DIST_DIR}
    try_files {path} /index.html
    file_server
  }
}
EOF
  chown root:caddy "$CADDYFILE"
  chmod 0640 "$CADDYFILE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
  log "Caddy 本地入口：127.0.0.1:${port}"
}

write_caddy_service() {
  init_file="/etc/init.d/${NODEGET_STATUS_CADDY_SERVICE}"
  caddy_bin=$(command -v caddy)
  cat >"$init_file" <<EOF
#!/sbin/openrc-run

name="${NODEGET_STATUS_CADDY_SERVICE}"
description="HlwDot NodeGet StatusShow local Caddy"
supervisor="\${NODEGET_CADDY_SUPERVISOR:-supervise-daemon}"
command="${caddy_bin}"
command_args="run --config ${CADDYFILE} --adapter caddyfile"
command_user="caddy:caddy"
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay="\${NODEGET_CADDY_RESPAWN_DELAY:-5}"
respawn_max="\${NODEGET_CADDY_RESPAWN_MAX:-0}"

depend() {
  need net ${NODEGET_SERVER_SERVICE}
  after firewall
}
EOF
  chmod 0755 "$init_file"
}

write_cloudflared_service() {
  [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ] || return 0
  conf_file="${CONFIG_DIR}/cloudflared.env"
  init_file="/etc/init.d/${NODEGET_CLOUDFLARED_SERVICE}"

  cat >"$conf_file" <<EOF
TUNNEL_TOKEN=$(shell_quote "$NODEGET_CLOUDFLARED_TOKEN")
EOF
  chmod 0600 "$conf_file"
  chown root:root "$conf_file"

  cat >"$CLOUDFLARED_RUN_SCRIPT" <<EOF
#!/bin/sh
set -eu
. ${conf_file}
export TUNNEL_TOKEN
exec /usr/local/bin/cloudflared tunnel --no-autoupdate run
EOF
  chmod 0750 "$CLOUDFLARED_RUN_SCRIPT"
  chown root:root "$CLOUDFLARED_RUN_SCRIPT"

  cat >"$init_file" <<EOF
#!/sbin/openrc-run

name="${NODEGET_CLOUDFLARED_SERVICE}"
description="Cloudflare Tunnel for HlwDot NodeGet StatusShow"
supervisor="\${NODEGET_CLOUDFLARED_SUPERVISOR:-supervise-daemon}"
command="${CLOUDFLARED_RUN_SCRIPT}"
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay="\${NODEGET_CLOUDFLARED_RESPAWN_DELAY:-5}"
respawn_max="\${NODEGET_CLOUDFLARED_RESPAWN_MAX:-0}"

depend() {
  need net ${NODEGET_STATUS_CADDY_SERVICE}
  after firewall
}
EOF
  chmod 0755 "$init_file"
}

urlencode_component() {
  jq -rn --arg value "$1" '$value | @uri'
}

cloudflare_api() {
  method="$1"
  path="$2"
  output="$3"
  body="${4:-}"
  url="https://api.cloudflare.com/client/v4${path}"

  if [ -n "$body" ]; then
    if ! status=$(curl -sS --retry 3 --connect-timeout 15 -o "$output" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer ${NODEGET_DNS_CONFIG_TOKEN}" \
      -H "Content-Type: application/json" \
      --data @"$body"); then
      die "Cloudflare API 请求失败：${method} ${path}"
    fi
  else
    if ! status=$(curl -sS --retry 3 --connect-timeout 15 -o "$output" -w '%{http_code}' \
      -X "$method" "$url" \
      -H "Authorization: Bearer ${NODEGET_DNS_CONFIG_TOKEN}"); then
      die "Cloudflare API 请求失败：${method} ${path}"
    fi
  fi

  case "$status" in
    2*) ;;
    *)
      jq -r '.errors[]?.message // empty' "$output" 2>/dev/null | sed -n '1,5p' >&2 || true
      die "Cloudflare API 返回 HTTP ${status}：${method} ${path}"
      ;;
  esac
  jq -e '.success == true' "$output" >/dev/null 2>&1 || {
    jq -r '.errors[]?.message // empty' "$output" 2>/dev/null | sed -n '1,5p' >&2 || true
    die "Cloudflare API 返回失败：${method} ${path}"
  }
}

cloudflare_account_id() {
  if [ -n "$NODEGET_CLOUDFLARE_ACCOUNT_ID" ]; then
    printf '%s\n' "$NODEGET_CLOUDFLARE_ACCOUNT_ID"
    return 0
  fi

  out="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-accounts.json"
  cloudflare_api GET '/accounts?per_page=2' "$out"
  count=$(jq '.result | length' "$out")
  [ "$count" = 1 ] || die "无法唯一确定 Cloudflare account；请填写 NODEGET_CLOUDFLARE_ACCOUNT_ID。"
  jq -r '.result[0].id' "$out"
}

cloudflare_zone_id() {
  if [ -n "$NODEGET_CLOUDFLARE_ZONE_ID" ]; then
    printf '%s\n' "$NODEGET_CLOUDFLARE_ZONE_ID"
    return 0
  fi

  zone="$NODEGET_CLOUDFLARE_ZONE"
  [ -n "$zone" ] || zone=$(printf '%s\n' "$NODEGET_STATUS_HOSTNAME" | awk -F. 'NF >= 2 { print $(NF-1) "." $NF }')
  [ -n "$zone" ] || die "无法确定 Cloudflare zone；请填写 NODEGET_CLOUDFLARE_ZONE_ID。"
  out="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-zones.json"
  cloudflare_api GET "/zones?name=$(urlencode_component "$zone")&status=active&per_page=5" "$out"
  count=$(jq --arg zone "$zone" '[.result[] | select(.name == $zone)] | length' "$out")
  [ "$count" = 1 ] || die "无法唯一确定 Cloudflare zone：$zone；请填写 NODEGET_CLOUDFLARE_ZONE_ID。"
  jq -r --arg zone "$zone" '.result[] | select(.name == $zone) | .id' "$out"
}

cloudflare_tunnel_id() {
  account_id="$1"
  if [ -n "$NODEGET_TUNNEL_ID" ]; then
    printf '%s\n' "$NODEGET_TUNNEL_ID"
    return 0
  fi

  out="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-tunnels.json"
  cloudflare_api GET "/accounts/${account_id}/cfd_tunnel?name=$(urlencode_component "$NODEGET_TUNNEL_NAME")&is_deleted=false&per_page=5" "$out"
  count=$(jq --arg name "$NODEGET_TUNNEL_NAME" '[.result[] | select(.name == $name and (.deleted_at == null))] | length' "$out")
  [ "$count" = 1 ] || die "无法唯一确定 Cloudflare Tunnel：$NODEGET_TUNNEL_NAME。"
  jq -r --arg name "$NODEGET_TUNNEL_NAME" '.result[] | select(.name == $name and (.deleted_at == null)) | .id' "$out"
}

build_tunnel_config_body() {
  current_file="$1"
  output_file="$2"
  host="$3"
  service="$4"

  jq --arg host "$host" --arg service "$service" '
    (.result.config // {}) as $config |
    (($config.ingress // []) | map(select((.hostname // "") != $host))) as $without_host |
    ($without_host | map(select((has("hostname") or has("path"))))) as $rules |
    ($without_host | map(select((has("hostname") | not) and (has("path") | not))) | last // {service: "http_status:404"}) as $catch_all |
    {
      config: (
        $config |
        .ingress = ($rules + [{hostname: $host, service: $service}] + [$catch_all])
      )
    }
  ' "$current_file" >"$output_file"
}

cloudflare_configure_tunnel() {
  tunnel_config_enabled || return 0

  account_id=$(cloudflare_account_id)
  zone_id=$(cloudflare_zone_id)
  tunnel_id=$(cloudflare_tunnel_id "$account_id")
  service="http://${NODEGET_STATUS_LISTEN}"
  dns_target="${tunnel_id}.cfargotunnel.com"
  current="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-tunnel-config.current.json"
  desired="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-tunnel-config.desired.json"
  response="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-tunnel-config.response.json"

  log "配置 Cloudflare Tunnel public hostname：${NODEGET_TUNNEL_NAME} -> ${NODEGET_STATUS_HOSTNAME}"
  cloudflare_api GET "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$current"
  build_tunnel_config_body "$current" "$desired" "$NODEGET_STATUS_HOSTNAME" "$service"
  if jq -e --arg host "$NODEGET_STATUS_HOSTNAME" --arg service "$service" '
    (.result.config.ingress // []) | any((.hostname // "") == $host and .service == $service)
  ' "$current" >/dev/null 2>&1; then
    log "Cloudflare Tunnel ingress 已是目标配置。"
  else
    cloudflare_api PUT "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$response" "$desired"
  fi

  cloudflare_upsert_dns_record "$zone_id" "$dns_target"
}

cloudflare_upsert_dns_record() {
  zone_id="$1"
  dns_target="$2"
  records="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-dns-records.json"
  body="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-dns-record.body.json"
  response="${TMP_DIR}/${SCRIPT_NAME}.$$.cf-dns-record.response.json"

  cloudflare_api GET "/zones/${zone_id}/dns_records?name.exact=$(urlencode_component "$NODEGET_STATUS_HOSTNAME")&per_page=100" "$records"
  non_cname_count=$(jq '[.result[] | select(.type != "CNAME")] | length' "$records")
  [ "$non_cname_count" = 0 ] || die "Cloudflare DNS 已存在非 CNAME 的 ${NODEGET_STATUS_HOSTNAME}，为避免误改已停止。"
  cname_count=$(jq '[.result[] | select(.type == "CNAME")] | length' "$records")

  jq -n \
    --arg name "$NODEGET_STATUS_HOSTNAME" \
    --arg content "$dns_target" \
    '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:true, comment:"managed by hlwdot nodeget-statusshow"}' >"$body"

  if [ "$cname_count" = 0 ]; then
    log "创建 Cloudflare Tunnel CNAME：${NODEGET_STATUS_HOSTNAME} -> ${dns_target}"
    cloudflare_api POST "/zones/${zone_id}/dns_records" "$response" "$body"
    return 0
  fi
  [ "$cname_count" = 1 ] || die "Cloudflare DNS 存在多个 ${NODEGET_STATUS_HOSTNAME} CNAME，已停止。"

  record_id=$(jq -r '.result[] | select(.type == "CNAME") | .id' "$records")
  if jq -e --arg content "$dns_target" '.result[] | select(.type == "CNAME") | .content == $content and .proxied == true' "$records" >/dev/null; then
    log "Cloudflare Tunnel CNAME 已是目标配置。"
  else
    log "更新 Cloudflare Tunnel CNAME：${NODEGET_STATUS_HOSTNAME} -> ${dns_target}"
    cloudflare_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$response" "$body"
  fi
}

stop_openrc_service() {
  rc-service "$1" stop >/dev/null 2>&1 || true
}

start_services() {
  rc-update add "$NODEGET_SERVER_SERVICE" default >/dev/null
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    rc-update add "$NODEGET_TAILNET_INGRESS_SERVICE" default >/dev/null
  else
    stop_openrc_service "$NODEGET_TAILNET_INGRESS_SERVICE"
    rc-update del "$NODEGET_TAILNET_INGRESS_SERVICE" default >/dev/null 2>&1 || true
  fi
  rc-update add "$NODEGET_HOLLOW_SYNC_SERVICE" default >/dev/null
  rc-update add "$NODEGET_STATUS_CADDY_SERVICE" default >/dev/null
  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    rc-update add "$NODEGET_CLOUDFLARED_SERVICE" default >/dev/null
  else
    stop_openrc_service "$NODEGET_CLOUDFLARED_SERVICE"
    rc-update del "$NODEGET_CLOUDFLARED_SERVICE" default >/dev/null 2>&1 || true
  fi

  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    stop_openrc_service "$NODEGET_CLOUDFLARED_SERVICE"
  fi
  stop_openrc_service "$NODEGET_STATUS_CADDY_SERVICE"
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    stop_openrc_service "$NODEGET_TAILNET_INGRESS_SERVICE"
  fi
  stop_openrc_service "$NODEGET_HOLLOW_SYNC_SERVICE"
  stop_openrc_service "$NODEGET_SERVER_SERVICE"

  rc-service "$NODEGET_SERVER_SERVICE" start
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    rc-service "$NODEGET_TAILNET_INGRESS_SERVICE" start
  fi
  rc-service "$NODEGET_HOLLOW_SYNC_SERVICE" start
  rc-service "$NODEGET_STATUS_CADDY_SERVICE" start
  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    rc-service "$NODEGET_CLOUDFLARED_SERVICE" start
  fi
}

verify_local_only_listener() {
  ports="$1"
  command_exists ss || return 0
  for port in $ports; do
    bad=$(ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" && $4 !~ /^127[.]0[.]0[.]1:/ && $4 !~ /^\[::1\]:/ { print }' || true)
    [ -z "$bad" ] || die "检测到端口 $port 非本机监听：$bad"
  done
}

listener_has_exact() {
  listen_addr="$1"
  listen_port="$2"
  awk -v a="${listen_addr}:${listen_port}" '$4 == a { found = 1 } END { exit found ? 0 : 1 }'
}

wait_for_listener() {
  listen_addr="$1"
  listen_port="$2"
  label="$3"
  i=0
  while [ "$i" -lt 20 ]; do
    ss -ltn 2>/dev/null | listener_has_exact "$listen_addr" "$listen_port" && return 0
    i=$((i + 1))
    sleep 1
  done
  die "${label} 未监听 ${listen_addr}:${listen_port}。"
}

wait_for_tailnet_listener() {
  listen_port="$1"
  listen_addr="$2"
  i=0
  while [ "$i" -lt 20 ]; do
    ss -ltn 2>/dev/null | tailnet_listener_has_expected "$listen_port" "$listen_addr" && return 0
    i=$((i + 1))
    sleep 1
  done
  die "NodeGet Agent 入口未监听 ${listen_addr}:${listen_port}。"
}

wait_for_http() {
  url="$1"
  label="$2"
  i=0
  while [ "$i" -lt 20 ]; do
    curl -fsS --connect-timeout 5 "$url" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 1
  done
  die "${label} 不可读。"
}

verify_nodeget_server_listener() {
  server_port=$(nodeget_server_port)
  command_exists ss || return 0
  wait_for_listener 127.0.0.1 "$server_port" "NodeGet Server"

  allowed_tailnet=''
  if { [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; } &&
    [ "$NODEGET_AGENT_LISTEN_PORT" = "$server_port" ]; then
    allowed_tailnet="$(resolve_agent_listen_addr):${server_port}"
  fi

  bad=$(ss -ltn 2>/dev/null | awk -v p=":$server_port" -v allowed="$allowed_tailnet" '
    $4 ~ p"$" &&
    $4 !~ /^127[.]0[.]0[.]1:/ &&
    $4 !~ /^\[::1\]:/ &&
    (allowed == "" || $4 != allowed) { print }
  ' || true)
  [ -z "$bad" ] || die "检测到 NodeGet Server 端口异常监听：$bad"
}

tailnet_listener_bad_lines() {
  port="$1"
  listen_addr="$2"
  awk -v p=":$port" -v a="${listen_addr}:$port" '
    $4 ~ p"$" &&
    $4 != a &&
    $4 !~ /^127[.]0[.]0[.]1:/ &&
    $4 !~ /^\[::1\]:/ { print }
  '
}

tailnet_listener_has_expected() {
  port="$1"
  listen_addr="$2"
  awk -v a="${listen_addr}:$port" '$4 == a { found = 1 } END { exit found ? 0 : 1 }'
}

verify_tailnet_only_listener() {
  port="$1"
  listen_addr="$2"
  command_exists ss || return 0
  wait_for_tailnet_listener "$port" "$listen_addr"
  bad=$(ss -ltn 2>/dev/null | tailnet_listener_bad_lines "$port" "$listen_addr" || true)
  [ -z "$bad" ] || die "检测到 NodeGet Agent 入口监听在非 hollow-net 地址：$bad"
}

verify_services() {
  status_port=${NODEGET_STATUS_LISTEN##*:}
  verify_local_only_listener "$status_port"
  verify_nodeget_server_listener
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    agent_addr=$(resolve_agent_listen_addr)
    verify_tailnet_only_listener "$NODEGET_AGENT_LISTEN_PORT" "$agent_addr"
    rc-service "$NODEGET_TAILNET_INGRESS_SERVICE" status >/dev/null 2>&1 || die "NodeGet Agent hollow-net 入口未运行。"
  fi
  rc-service "$NODEGET_SERVER_SERVICE" status >/dev/null 2>&1 || die "NodeGet Server 未运行。"
  rc-service "$NODEGET_STATUS_CADDY_SERVICE" status >/dev/null 2>&1 || die "StatusShow Caddy 未运行。"
  rc-service "$NODEGET_HOLLOW_SYNC_SERVICE" status >/dev/null 2>&1 || die "hollow-net 自动发现服务未运行。"
  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    rc-service "$NODEGET_CLOUDFLARED_SERVICE" status >/dev/null 2>&1 || die "Cloudflare Tunnel 未运行。"
  fi
  wait_for_http "http://${NODEGET_STATUS_LISTEN}/config.json" "本地 StatusShow 配置"
  wait_for_http "http://${NODEGET_STATUS_LISTEN}/hollow-nodes.json" "hollow-net inventory"
}

self_test_require_base() {
  missing=''
  for cmd in jq sed awk; do
    command_exists "$cmd" || missing="${missing} ${cmd}"
  done
  [ -z "$missing" ] || die "自检缺少命令：$missing"
}

self_test_require_build() {
  missing=''
  for cmd in git npm node jq sed awk; do
    command_exists "$cmd" || missing="${missing} ${cmd}"
  done
  [ -z "$missing" ] || die "构建自检缺少命令：$missing"
}

self_test_names() {
  NODEGET_HOLLOW_NAME_ALIASES="${NODEGET_HOLLOW_NAME_ALIASES:-center:CNETER}"
  cases='server999.center=CNETER-999
server3.headscale=HEADSCALE-3
server4.net=NET-4'
  printf '%s\n' "$cases" | while IFS='=' read -r input expected; do
    actual=$(hollow_display_name_from_node_name "$input")
    [ "$actual" = "$expected" ] || die "节点名解析失败：$input -> $actual，期望 $expected"
  done
  log "自检通过：hollow-net 节点名解析。"
}

self_test_frontend_build() {
  npm_cache="${TMP_DIR}/${SCRIPT_NAME}.$$.npm-cache"

  NODEGET_STATUS_HOSTNAME="nodeget-selftest.example.com"
  NODEGET_STATUS_SITE_NAME="Self Test"
  NODEGET_STATUS_FOOTER="Self Test"
  NODEGET_STATUS_LOGO=""
  NODEGET_VISITOR_TOKEN="self-test-token"
  NODEGET_SERVER_NAME="self-test"

  mkdir -p "$TMP_DIR" "$APP_ROOT" "$CONFIG_DIR"
  clone_statusshow_source
  patch_statusshow_source
  write_statusshow_config
  pin_statusshow_build_toolchain
  rm -rf "$npm_cache"
  (
    cd "$SRC_DIR"
    npm ci --no-audit --no-fund --cache "$npm_cache"
    npm run typecheck
    if [ "$NODEGET_STATUSSHOW_MINIFY" = 1 ] || [ "$NODEGET_STATUSSHOW_MINIFY" = true ]; then
      npm run build
    else
      npm run build -- --minify=false
    fi
  )
  rm -rf "$npm_cache"
  [ -s "${SRC_DIR}/dist/index.html" ] || die "自检构建失败：缺少 dist/index.html"
  grep -R "hollow-nodes.json" "${SRC_DIR}/dist" >/dev/null 2>&1 || die "自检构建失败：产物缺少 hollow-net inventory 逻辑"
  jq -e '.hollow_net_inventory == true and .site_tokens[0].backend_url == "wss://nodeget-selftest.example.com/nodeget-ws"' "${SRC_DIR}/public/config.json" >/dev/null
  log "自检通过：魔改 StatusShow 可 typecheck/build。"
}

build_prebuilt_asset() {
  prebuilt_output="$1"
  [ -n "$prebuilt_output" ] || die "请指定预构建资产输出路径。"
  self_test_common_setup
  self_test_require_build

  NODEGET_STATUS_HOSTNAME="nodeget-prebuilt.example.invalid"
  NODEGET_STATUS_SITE_NAME="Prebuilt"
  NODEGET_STATUS_FOOTER="Prebuilt"
  NODEGET_STATUS_LOGO=""
  NODEGET_VISITOR_TOKEN=""
  NODEGET_SERVER_NAME="prebuilt"
  NODEGET_STATUSSHOW_BUILD_MODE=build

  clone_statusshow_source
  patch_statusshow_source
  write_statusshow_config
  npm_cache="${TMP_DIR}/${SCRIPT_NAME}.$$.npm-cache"
  pin_statusshow_build_toolchain
  rm -rf "$npm_cache"
  (
    cd "$SRC_DIR"
    npm ci --no-audit --no-fund --cache "$npm_cache"
    npm run typecheck
    if [ "$NODEGET_STATUSSHOW_MINIFY" = 1 ] || [ "$NODEGET_STATUSSHOW_MINIFY" = true ]; then
      npm run build
    else
      npm run build -- --minify=false
    fi
  )
  [ -s "${SRC_DIR}/dist/index.html" ] || die "预构建失败：缺少 dist/index.html"
  grep -R "hollow-nodes.json" "${SRC_DIR}/dist" >/dev/null 2>&1 || die "预构建失败：产物缺少 hollow-net inventory 逻辑"
  rm -f "${SRC_DIR}/dist/config.json"
  mkdir -p "$(dirname "$prebuilt_output")"
  tar -C "${SRC_DIR}/dist" -czf "$prebuilt_output" .
  rm -rf "$npm_cache" "$self_root"
  SELF_TEST_ROOT=''
  log "预构建资产已写入：$prebuilt_output"
}

self_test_menu() {
  menu_file="${SCRIPT_DIR}/vps-menu.sh"
  [ -r "$menu_file" ] || return 0
  counts=$(
    awk '
      /^MENU_LABELS=/{a="labels"}
      /^MENU_GROUPS=/{a="groups"}
      /^MENU_HINTS=/{a="hints"}
      /^MENU_KEYS=/{a="keys"}
      /^MENU_ACTIONS=/{a="actions"}
      {
        if (a && $0 ~ /^  "/) c[a]++
        if ($0 ~ /^MENU_KEYS=/) { n=gsub(/"[^"]+"/,"&"); c["keys"]=n }
        if ($0 ~ /^MENU_ACTIONS=/) { n=gsub(/"[^"]+"/,"&"); c["actions"]=n }
      }
      END { print c["labels"], c["groups"], c["hints"], c["keys"], c["actions"] }
    ' "$menu_file"
  )
  set -- $counts
  [ "$1" = "$2" ] && [ "$1" = "$3" ] && [ "$1" = "$4" ] && [ "$1" = "$5" ] || die "菜单数组长度不一致：$counts"
  grep -q 'nodeget-statusshow' "$menu_file" || die "菜单缺少 nodeget-statusshow 动作。"
  log "自检通过：vps-menu 选项对齐。"
}

self_test_inventory() {
  status_json="${TMP_DIR}/tailscale-status.json"
  out_json="${TMP_DIR}/hollow-nodes.json"
  HOLLOW_SYNC_SCRIPT="${TMP_DIR}/nodeget-hollow-sync.sh"
  cat >"$status_json" <<'EOF'
{
  "Self": {
    "HostName": "server4.net",
    "DNSName": "server4.net.net.hlwdot.com.",
    "TailscaleIPs": ["100.64.0.4"],
    "Online": true
  },
  "Peer": {
    "peer-999": {
      "HostName": "server999.center",
      "DNSName": "server999.center.net.hlwdot.com.",
      "TailscaleIPs": ["100.64.0.2"],
      "Online": true
    },
    "peer-3": {
      "HostName": "server3",
      "DNSName": "server3.headscale.net.hlwdot.com.",
      "TailscaleIPs": ["100.64.0.3"],
      "Online": false
    }
  }
}
EOF
  write_hollow_sync_script
  STATE_DIR="$STATE_DIR" \
    HOLLOW_JSON="$out_json" \
    TAILSCALE_STATUS_JSON_FILE="$status_json" \
    NODEGET_HOLLOW_SYNC_ONCE=1 \
    NODEGET_HOLLOW_DNS_SUFFIXES="net.hlwdot.com,hlwdot.com" \
    NODEGET_HOLLOW_NAME_ALIASES="center:CNETER" \
    sh "$HOLLOW_SYNC_SCRIPT"
  jq -e '
    ([.nodes[].name] | sort) == (["CNETER-999", "HEADSCALE-3", "NET-4"] | sort) and
    ([.nodes[] | select(.ip != null)] | length) == 0 and
    (.nodes[] | select(.name == "HEADSCALE-3") | .online) == false
  ' "$out_json" >/dev/null || die "hollow-net inventory 自检失败。"
  log "自检通过：hollow-net 自动发现 inventory。"
}

self_test_security_static() {
  case "$NODEGET_SERVER_LISTEN" in
    127.0.0.1:*|localhost:*) ;;
    *) die "安全自检失败：NODEGET_SERVER_LISTEN 默认值不是本机监听。" ;;
  esac
  case "$NODEGET_STATUS_LISTEN" in
    127.0.0.1:*|localhost:*) ;;
    *) die "安全自检失败：NODEGET_STATUS_LISTEN 默认值不是本机监听。" ;;
  esac
  if awk '
    /^self_test_security_static\(\) \{/ { skip = 1; next }
    skip && /^}/ { skip = 0; next }
    skip { next }
    /ufw|iptables|CLOUDFLARE_API_KEY|CLOUDFLARE_EMAIL/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$0"; then
    die "安全自检失败：脚本不应配置防火墙或要求 Cloudflare DNS 全局密钥。"
  fi
  log "自检通过：静态安全边界。"
}

self_test_listener_filters() {
  sample='State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:2211      0.0.0.0:*
LISTEN 0      4096       100.64.0.3:2211     0.0.0.0:*'
  bad=$(printf '%s\n' "$sample" | tailnet_listener_bad_lines 2211 100.64.0.3 || true)
  [ -z "$bad" ] || die "监听过滤自检失败：合法 loopback/tailnet 被误判。"
  printf '%s\n' "$sample" | tailnet_listener_has_expected 2211 100.64.0.3 ||
    die "监听过滤自检失败：未识别 hollow-net 监听。"

  sample_bad="${sample}
LISTEN 0      4096       0.0.0.0:2211        0.0.0.0:*"
  bad=$(printf '%s\n' "$sample_bad" | tailnet_listener_bad_lines 2211 100.64.0.3 || true)
  printf '%s\n' "$bad" | grep -q '0[.]0[.]0[.]0:2211' ||
    die "监听过滤自检失败：未拦截公网监听。"
  log "自检通过：NodeGet 监听过滤。"
}

self_test_cloudflare_config_body() {
  current="${TMP_DIR}/cf-current.json"
  desired="${TMP_DIR}/cf-desired.json"
  cat >"$current" <<'EOF'
{
  "success": true,
  "result": {
    "config": {
      "originRequest": {"connectTimeout": 10},
      "ingress": [
        {"hostname": "old.example.com", "service": "http://127.0.0.1:9000"},
        {"hostname": "nodeget.example.com", "service": "http://127.0.0.1:1111"},
        {"service": "http_status:404"}
      ]
    }
  }
}
EOF
  build_tunnel_config_body "$current" "$desired" "nodeget.example.com" "http://127.0.0.1:8221"
  jq -e '
    .config.originRequest.connectTimeout == 10 and
    ([.config.ingress[] | select(.hostname == "old.example.com")] | length) == 1 and
    ([.config.ingress[] | select(.hostname == "nodeget.example.com" and .service == "http://127.0.0.1:8221")] | length) == 1 and
    ([.config.ingress[] | select(.hostname == "nodeget.example.com")] | length) == 1 and
    (.config.ingress[-1].service == "http_status:404") and
    (.config.ingress[-1].hostname == null)
  ' "$desired" >/dev/null || die "Cloudflare Tunnel 配置合成自检失败。"
  log "自检通过：Cloudflare Tunnel 配置合成。"
}

self_test_env_merge() {
  old_env="${TMP_DIR}/old.env"
  example_env="${TMP_DIR}/example.env"
  li_env="${TMP_DIR}/li.env"
  cat >"$old_env" <<'EOF'
FOO=bar
NODEGET_STATUS_HOSTNAME=old.example.com
# k3s 主节点。
K3S_VERSION=
EOF
  cat >"$example_env" <<'EOF'
# top
# NodeGet hollow-net 探针页。
NODEGET_STATUS_HOSTNAME=nodeget.hlwdot.com
NODEGET_STATUS_SITE_NAME='Hollow Net Status'
NODEGET_STATUS_FOOTER='Powered by NodeGet'
NODEGET_VISITOR_TOKEN=
NODEGET_CLOUDFLARED_TOKEN=
NODEGET_DNS_CONFIG_TOKEN=
NODEGET_SERVER_LISTEN=127.0.0.1:2211
NODEGET_STATUS_LISTEN=127.0.0.1:8221
NODEGET_AGENT_LISTEN_ADDR=auto
NODEGET_TUNNEL_NAME=healthy-page
NODEGET_TUNNEL_ID=
NODEGET_CLOUDFLARE_ACCOUNT_ID=
# k3s 主节点。
K3S_VERSION=
EOF
  cat >"$li_env" <<'EOF'
NODEGET_STATUS_HOSTNAME=nodeget.example.com
NODEGET_CLOUDFLARED_TOKEN='run-token'
NODEGET_VISITOR_TOKEN=
NODEGET_TUNNEL_CONFIG_ENABLE=0
EOF
  chmod 0644 "$li_env"
  NODEGET_DEFAULT_TUNNEL_ID=52a24e2a-82dc-45b0-ab30-bef831425dfd
  NODEGET_DEFAULT_ZONE_ID=8e60f95b7b37991976bb8db6df4ea2de
  merge_nodeget_env_files "$old_env" "$example_env" "$li_env" c23c771ead9657dab9308b8601bd02d9
  li_env_mode=$(stat -c %a "$li_env" 2>/dev/null || stat -f %Lp "$li_env")
  [ "$li_env_mode" = 600 ] || die ".env-li 权限合并自检失败。"
  sh -c '
    set -eu
    . "$1"
    [ "$FOO" = bar ]
    [ "$NODEGET_STATUS_HOSTNAME" = nodeget.example.com ]
    [ "$NODEGET_STATUS_SITE_NAME" = "Hollow Net Status" ]
    [ "$NODEGET_VISITOR_TOKEN" = "" ]
    [ "$NODEGET_TUNNEL_CONFIG_ENABLE" = 0 ]
    [ "$NODEGET_CLOUDFLARE_ACCOUNT_ID" = c23c771ead9657dab9308b8601bd02d9 ]
    [ "$NODEGET_TUNNEL_ID" = 52a24e2a-82dc-45b0-ab30-bef831425dfd ]
    [ "$NODEGET_CLOUDFLARE_ZONE_ID" = 8e60f95b7b37991976bb8db6df4ea2de ]
    [ "$K3S_VERSION" = "" ]
  ' sh "$old_env" || die ".env 合并自检失败。"
  [ "$(grep -c '^NODEGET_STATUS_HOSTNAME=' "$old_env")" = 1 ] || die ".env 合并自检失败：重复 NODEGET_STATUS_HOSTNAME。"
  log "自检通过：.env NodeGet 合并。"
}

self_test_common_setup() {
  self_root=$(mktemp -d "${TMPDIR:-/tmp}/nodeget-statusshow-selftest-state.XXXXXX")
  SELF_TEST_ROOT="$self_root"
  STATE_DIR="${self_root}/state"
  TMP_DIR="${STATE_DIR}/tmp"
  APP_ROOT="${self_root}/app"
  SRC_DIR="${APP_ROOT}/source"
  DIST_DIR="${APP_ROOT}/current"
  CONFIG_DIR="${self_root}/etc"
  HOLLOW_JSON="${STATE_DIR}/hollow-nodes.json"
  mkdir -p "$TMP_DIR" "$APP_ROOT" "$CONFIG_DIR"
  chmod 0755 "$STATE_DIR" "$APP_ROOT" "$CONFIG_DIR"
  chmod 0700 "$TMP_DIR"
  apply_defaults
}

self_test() {
  self_test_common_setup
  self_test_require_base
  self_test_names
  self_test_inventory
  self_test_menu
  self_test_security_static
  self_test_listener_filters
  self_test_cloudflare_config_body
  self_test_env_merge
  rm -rf "$self_root"
  SELF_TEST_ROOT=''
  log "基础自检通过；前端魔改构建请单独执行 --self-test-build。"
}

self_test_build() {
  self_test_common_setup
  self_test_require_build
  self_test_names
  self_test_inventory
  self_test_menu
  self_test_security_static
  self_test_listener_filters
  self_test_cloudflare_config_body
  self_test_env_merge
  self_test_frontend_build
  rm -rf "$self_root"
  SELF_TEST_ROOT=''
  log "构建自检通过。"
}

print_summary() {
  printf '\nNodeGet StatusShow 部署完成。\n'
  printf '  public hostname：%s\n' "$NODEGET_STATUS_HOSTNAME"
  printf '  local status：http://%s\n' "$NODEGET_STATUS_LISTEN"
  printf '  local websocket：%s\n' "$NODEGET_SERVER_LISTEN"
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    printf '  agent hollow-net ws：ws://%s:%s\n' "$(resolve_agent_listen_addr)" "$NODEGET_AGENT_LISTEN_PORT"
  fi
  printf '  hollow inventory：%s\n' "$HOLLOW_JSON"
  printf '  初始化凭据：%s\n' "$NODEGET_CREDENTIALS"
  printf '  Cloudflare：Tunnel token 模式，无 DNS API key。\n'
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    --self-test)
      self_test
      exit 0
      ;;
    --self-test-build)
      self_test_build
      exit 0
      ;;
    --build-prebuilt-asset)
      build_prebuilt_asset "${2:-}"
      exit 0
      ;;
    --merge-env)
      merge_env
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
  require_alpine
  setup_state_dir
  load_env
  apply_defaults
  validate_input
  require_hollow_net
  install_packages
  ensure_users
  install_nodeget_server_binary
  install_cloudflared_binary
  write_nodeget_config
  write_nodeget_service
  init_nodeget_server
  write_tailnet_ingress_service
  build_statusshow
  write_hollow_sync_script
  write_hollow_sync_service
  write_caddy_config
  write_caddy_service
  cloudflare_configure_tunnel
  write_cloudflared_service
  start_services
  verify_services
  print_summary
}

main "$@"
