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
  sh $SCRIPT_NAME --self-test
  sh $SCRIPT_NAME --self-test-build

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
  - Cloudflare 只使用 Tunnel token，不需要 Zone DNS API key。
  - Cloudflare public hostname 的 service 指向 http://127.0.0.1:8221。
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
  mkdir -p "$TMP_DIR" "$APP_ROOT" "$CONFIG_DIR" /usr/local/lib/hlwdot
  chmod 0755 "$STATE_DIR" "$APP_ROOT" "$CONFIG_DIR" /usr/local/lib/hlwdot
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
  apk add ca-certificates curl git jq nodejs npm openrc caddy coreutils iproute2 socat
  command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
}

apply_defaults() {
  HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
  HEADSCALE_DNS_BASE_DOMAIN="${HEADSCALE_DNS_BASE_DOMAIN:-net.hlwdot.com}"

  NODEGET_VERSION="${NODEGET_VERSION:-v0.1.4}"
  NODEGET_RELEASE_REPO="${NODEGET_RELEASE_REPO:-GenshinMinecraft/NodeGet}"
  NODEGET_STATUSSHOW_REPO="${NODEGET_STATUSSHOW_REPO:-NodeSeekDev/NodeGet-StatusShow}"
  NODEGET_STATUSSHOW_REF="${NODEGET_STATUSSHOW_REF:-276786c0853dbdbbdbfaf529d6b02dad501d689f}"

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
  chown -R caddy:caddy "$APP_ROOT" 2>/dev/null || true
}

write_nodeget_config() {
  tmp="${TMP_DIR}/${SCRIPT_NAME}.$$.nodeget-server.conf"
  cat >"$tmp" <<EOF
log_level = "warn"
ws_listener = "$(toml_string "$NODEGET_SERVER_LISTEN")"
jsonrpc_max_connections = ${NODEGET_JSONRPC_MAX_CONNECTIONS}
jsonrpc_timing_log_level = "warn"
enable_unix_socket = false
unix_socket_path = "/var/lib/nodeget-server/nodeget-server.sock"
server_uuid = "$(toml_string "$NODEGET_SERVER_UUID")"

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
  su -s /bin/sh nodeget -c "$*"
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

write_statusshow_config() {
  mkdir -p "${SRC_DIR}/public"
  cat >"${SRC_DIR}/public/config.json" <<EOF
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

build_statusshow() {
  npm_cache="${TMP_DIR}/${SCRIPT_NAME}.$$.npm-cache"

  clone_statusshow_source
  patch_statusshow_source
  write_statusshow_config
  log "安装 StatusShow 前端依赖并构建。"
  rm -rf "$npm_cache"
  (
    cd "$SRC_DIR"
    npm ci --no-audit --no-fund --cache "$npm_cache"
    npm run build
  )
  rm -rf "$npm_cache"
  rm -rf "${DIST_DIR}.new"
  mkdir -p "${DIST_DIR}.new"
  cp -R "${SRC_DIR}/dist/." "${DIST_DIR}.new/"
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

http://${NODEGET_STATUS_LISTEN} {
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
  chmod 0644 "$CADDYFILE"
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
exec /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "\$TUNNEL_TOKEN"
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

start_services() {
  rc-update add "$NODEGET_SERVER_SERVICE" default >/dev/null
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    rc-update add "$NODEGET_TAILNET_INGRESS_SERVICE" default >/dev/null
  fi
  rc-update add "$NODEGET_HOLLOW_SYNC_SERVICE" default >/dev/null
  rc-update add "$NODEGET_STATUS_CADDY_SERVICE" default >/dev/null
  rc-service "$NODEGET_SERVER_SERVICE" restart
  if [ "$NODEGET_AGENT_INGRESS_ENABLE" = 1 ] || [ "$NODEGET_AGENT_INGRESS_ENABLE" = true ]; then
    rc-service "$NODEGET_TAILNET_INGRESS_SERVICE" restart
  fi
  rc-service "$NODEGET_HOLLOW_SYNC_SERVICE" restart
  rc-service "$NODEGET_STATUS_CADDY_SERVICE" restart
  if [ "$NODEGET_CLOUDFLARED_ENABLE" = 1 ] || [ "$NODEGET_CLOUDFLARED_ENABLE" = true ]; then
    rc-update add "$NODEGET_CLOUDFLARED_SERVICE" default >/dev/null
    rc-service "$NODEGET_CLOUDFLARED_SERVICE" restart
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

verify_nodeget_server_listener() {
  server_port=$(nodeget_server_port)
  command_exists ss || return 0
  ss -ltn 2>/dev/null | awk -v p=":$server_port" '$4 ~ "^127[.]0[.]0[.]1" p "$" { found = 1 } END { exit found ? 0 : 1 }' ||
    die "NodeGet Server 未监听 127.0.0.1:${server_port}。"

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
  ss -ltn 2>/dev/null | tailnet_listener_has_expected "$port" "$listen_addr" ||
    die "NodeGet Agent 入口未监听 ${listen_addr}:${port}。"
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
  curl -fsS --connect-timeout 5 "http://${NODEGET_STATUS_LISTEN}/config.json" >/dev/null || die "本地 StatusShow 配置不可读。"
  curl -fsS --connect-timeout 5 "http://${NODEGET_STATUS_LISTEN}/hollow-nodes.json" >/dev/null || die "hollow-net inventory 不可读。"
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
  rm -rf "$npm_cache"
  (
    cd "$SRC_DIR"
    npm ci --no-audit --no-fund --cache "$npm_cache"
    npm run typecheck
    npm run build
  )
  rm -rf "$npm_cache"
  [ -s "${SRC_DIR}/dist/index.html" ] || die "自检构建失败：缺少 dist/index.html"
  grep -R "hollow-nodes.json" "${SRC_DIR}/dist" >/dev/null 2>&1 || die "自检构建失败：产物缺少 hollow-net inventory 逻辑"
  jq -e '.hollow_net_inventory == true and .site_tokens[0].backend_url == "wss://nodeget-selftest.example.com/nodeget-ws"' "${SRC_DIR}/public/config.json" >/dev/null
  log "自检通过：魔改 StatusShow 可 typecheck/build。"
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
  write_cloudflared_service
  start_services
  verify_services
  print_summary
}

main "$@"
