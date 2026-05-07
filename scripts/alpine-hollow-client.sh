#!/bin/sh
# Alpine Headscale 网络接入脚本。
#
# 用于低配 Alpine VPS。脚本只安装并配置 Tailscale/OpenRC，
# 然后把当前节点接入 Headscale 管理的内网，不处理 Debian 初始化，
# 也不部署 k3s。

set -eu
umask 027

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR="/var/lib/hlwdot/alpine-hollow-client"
TMP_DIR="${STATE_DIR}/tmp"
RUN_MARKER="${STATE_DIR}/run.in-progress"
DONE_MARKER="${STATE_DIR}/done.env"
HOLLOW_OPENRC_SERVICE="${HOLLOW_OPENRC_SERVICE:-hollow-tailscaled}"
HOLLOW_OPENRC_CONF="/etc/conf.d/${HOLLOW_OPENRC_SERVICE}"
HOLLOW_OPENRC_INIT="/etc/init.d/${HOLLOW_OPENRC_SERVICE}"
SPLIT_LOCAL_SCRIPT="/etc/local.d/hlwdot-split.start"
TAILNET_DNSMASQ_CONF="/etc/dnsmasq.d/90-hlwdot-tailnet.conf"
TAILNET_DNS_RESOLV_BACKUP="/etc/hlwdot/tailnet-dns.original-resolv.conf"
TAILNET_DNS_UPSTREAMS_FILE="/etc/hlwdot/tailnet-dns.upstreams"

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

require_root() {
  [ "$(id -u)" = 0 ] || die "请使用 root 运行。"
}

setup_state_dir() {
  mkdir -p "$TMP_DIR"
  chmod 0755 "$STATE_DIR"
  chmod 0700 "$TMP_DIR"
}

cleanup_tempfiles() {
  [ -d "$TMP_DIR" ] || return 0
  find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type f -name "${SCRIPT_NAME}.*" -exec rm -f {} + 2>/dev/null || true
}

on_interrupt() {
  warn "收到中断信号，已停止。重新执行脚本会继续处理未完成步骤。"
  exit 130
}

on_error() {
  warn "执行失败，请检查上方输出。"
  exit 1
}

trap cleanup_tempfiles EXIT
trap on_interrupt INT TERM
trap on_error HUP

usage() {
  cat <<EOF
用法：
  sh $SCRIPT_NAME

常用配置：
  HEADSCALE_SERVER_URL=https://headscale.hlwdot.com
  HEADSCALE_AUTHKEY=tskey-auth-...
  HEADSCALE_CLIENT_HOSTNAME=alpine-edge-1
  HOLLOW_NET_IFACE=hollow-net
  ALPINE_TAILSCALE_INSTALL_SOURCE=auto
  ALPINE_TAILSCALE_MIN_VERSION=1.74.0
  ALPINE_SPLIT_DIRECTION=none
  ALPINE_SPLIT_ROUTE_CIDRS=10.45.153.0/24
  ALPINE_SPLIT_OUTBOUND_PROXY_PORTS=7890/tcp,7891/tcp
  ALPINE_SPLIT_INBOUND_FORWARDS=443/tcp=100.64.0.2:443
  HEADSCALE_ENDPOINT_CHECK=1
  HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC=15
  HEADSCALE_AUTO_DISABLE_DNS_FIGHT=1
  ALPINE_TAILNET_DNS_MODE=auto
  ALPINE_TAILNET_DNS_DOMAINS=auto
  ALPINE_TAILNET_DNS_UPSTREAMS=auto
  ALPINE_TAILSCALE_UP_TIMEOUT_SEC=120

说明：
  - 仅支持 Alpine Linux + OpenRC。
  - 默认只接入 Headscale 网络，不部署 k3s。
  - LXD 容器里默认用 dnsmasq 保留原 DNS，并把 Headscale DNS 域分流到 100.100.100.100。
  - 出站分流指 Headscale 网络内的机器访问本机代理端口。
  - 入站分流指公网端口转发到 Headscale 网络内部目标。
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

persist_env_value_to_file() {
  target="$1"
  key="$2"
  value="$3"
  temp_file="${TMP_DIR}/${SCRIPT_NAME}.$$.$key"

  [ -e "$target" ] || : >"$target"
  chmod 0600 "$target"

  awk -v key="$key" '$0 !~ "^[[:space:]]*" key "=" { print }' "$target" >"$temp_file"
  printf '%s=%s\n' "$key" "$(shell_quote "$value")" >>"$temp_file"
  cat "$temp_file" >"$target"
  chmod 0600 "$target"
}

persist_env_value() {
  key="$1"
  value="$2"
  target="/etc/hlwdot/vps.env"
  local_env="${SCRIPT_DIR}/.env"

  mkdir -p /etc/hlwdot
  chmod 0700 /etc/hlwdot

  persist_env_value_to_file "$target" "$key" "$value"
  if [ -e "$local_env" ] && [ "$local_env" != "$target" ]; then
    persist_env_value_to_file "$local_env" "$key" "$value"
  fi

  log "更新系统配置：$key"
}

validate_bool() {
  name="$1"
  value="$2"
  case "$value" in
    0|1) ;;
    *) die "${name} 只能是 0 或 1。" ;;
  esac
}

validate_input() {
  case "${HEADSCALE_SERVER_URL}" in
    http://*|https://*) ;;
    *) die "HEADSCALE_SERVER_URL 必须以 http:// 或 https:// 开头。" ;;
  esac
  case "${HEADSCALE_ACCEPT_DNS}" in
    true|false) ;;
    *) die "HEADSCALE_ACCEPT_DNS 只能是 true 或 false。" ;;
  esac
  case "${HOLLOW_NET_IFACE}" in
    *[!A-Za-z0-9_.-]*|'') die "HOLLOW_NET_IFACE 包含非法字符。" ;;
  esac
  case "${ALPINE_SPLIT_DIRECTION}" in
    none|inbound|outbound|both) ;;
    *) die "ALPINE_SPLIT_DIRECTION 只能是 none、inbound、outbound、both。" ;;
  esac
  validate_bool HEADSCALE_ENABLE_TS_SSH "$HEADSCALE_ENABLE_TS_SSH"
  validate_bool HEADSCALE_RESET "$HEADSCALE_RESET"
  validate_bool HEADSCALE_ENDPOINT_CHECK "$HEADSCALE_ENDPOINT_CHECK"
  validate_bool HEADSCALE_AUTO_DISABLE_DNS_FIGHT "$HEADSCALE_AUTO_DISABLE_DNS_FIGHT"
  case "$ALPINE_TAILNET_DNS_MODE" in
    auto|off|dnsmasq) ;;
    *) die "ALPINE_TAILNET_DNS_MODE 只能是 auto、off 或 dnsmasq。" ;;
  esac
  validate_bool ALPINE_ENABLE_COMMUNITY_REPO "$ALPINE_ENABLE_COMMUNITY_REPO"
  validate_bool ALPINE_ALLOW_INTERACTIVE_LOGIN "$ALPINE_ALLOW_INTERACTIVE_LOGIN"
  validate_bool ALPINE_KILL_STALE_TAILSCALE_UP "$ALPINE_KILL_STALE_TAILSCALE_UP"
  case "$ALPINE_TAILSCALE_INSTALL_SOURCE" in
    auto|static|apk) ;;
    *) die "ALPINE_TAILSCALE_INSTALL_SOURCE 只能是 auto、static 或 apk。" ;;
  esac
  case "$ALPINE_TAILSCALE_MIN_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "ALPINE_TAILSCALE_MIN_VERSION 格式错误。" ;;
  esac
  case "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" in
    ''|*[!0-9]*) die "HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC 必须是数字。" ;;
  esac
  case "$ALPINE_TAILSCALE_UP_TIMEOUT_SEC" in
    ''|*[!0-9]*) die "ALPINE_TAILSCALE_UP_TIMEOUT_SEC 必须是数字。" ;;
  esac
}

require_alpine() {
  [ -r /etc/alpine-release ] || die "当前系统不是 Alpine Linux。"
  command_exists apk || die "缺少 apk。"
  command_exists rc-service || die "缺少 OpenRC rc-service。"
  command_exists rc-update || die "缺少 OpenRC rc-update。"
}

apply_defaults() {
  HEADSCALE_SERVER_URL="${HEADSCALE_SERVER_URL:-https://headscale.hlwdot.com}"
  HEADSCALE_SERVER_HOSTNAME="${HEADSCALE_SERVER_HOSTNAME:-}"
  HEADSCALE_AUTHKEY="${HEADSCALE_AUTHKEY:-}"
  HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-$(hostname 2>/dev/null || printf 'alpine-vps')}"
  HEADSCALE_ACCEPT_DNS="${HEADSCALE_ACCEPT_DNS:-true}"
  HEADSCALE_ADVERTISE_ROUTES="${HEADSCALE_ADVERTISE_ROUTES:-}"
  HEADSCALE_ENABLE_TS_SSH="${HEADSCALE_ENABLE_TS_SSH:-0}"
  HEADSCALE_RESET="${HEADSCALE_RESET:-0}"
  HEADSCALE_EXTRA_UP_ARGS="${HEADSCALE_EXTRA_UP_ARGS:-}"
  HEADSCALE_ENDPOINT_CHECK="${HEADSCALE_ENDPOINT_CHECK:-1}"
  HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC="${HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC:-15}"
  HEADSCALE_AUTO_DISABLE_DNS_FIGHT="${HEADSCALE_AUTO_DISABLE_DNS_FIGHT:-1}"
  ALPINE_TAILNET_DNS_MODE="${ALPINE_TAILNET_DNS_MODE:-auto}"
  ALPINE_TAILNET_DNS_DOMAINS="${ALPINE_TAILNET_DNS_DOMAINS:-auto}"
  ALPINE_TAILNET_DNS_UPSTREAMS="${ALPINE_TAILNET_DNS_UPSTREAMS:-auto}"
  HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
  ALPINE_TAILSCALE_INSTALL_SOURCE="${ALPINE_TAILSCALE_INSTALL_SOURCE:-auto}"
  ALPINE_TAILSCALE_MIN_VERSION="${ALPINE_TAILSCALE_MIN_VERSION:-1.74.0}"
  ALPINE_TAILSCALE_STATIC_URL="${ALPINE_TAILSCALE_STATIC_URL:-auto}"
  ALPINE_ENABLE_COMMUNITY_REPO="${ALPINE_ENABLE_COMMUNITY_REPO:-1}"
  ALPINE_COMMUNITY_REPO_URL="${ALPINE_COMMUNITY_REPO_URL:-auto}"
  ALPINE_ENABLE_FORWARDING="${ALPINE_ENABLE_FORWARDING:-auto}"
  ALPINE_SPLIT_DIRECTION="${ALPINE_SPLIT_DIRECTION:-none}"
  ALPINE_SPLIT_ROUTE_CIDRS="${ALPINE_SPLIT_ROUTE_CIDRS:-}"
  ALPINE_SPLIT_OUTBOUND_PROXY_PORTS="${ALPINE_SPLIT_OUTBOUND_PROXY_PORTS:-}"
  ALPINE_SPLIT_INBOUND_FORWARDS="${ALPINE_SPLIT_INBOUND_FORWARDS:-}"
  ALPINE_PUBLIC_IFACE="${ALPINE_PUBLIC_IFACE:-auto}"
  ALPINE_ALLOW_INTERACTIVE_LOGIN="${ALPINE_ALLOW_INTERACTIVE_LOGIN:-0}"
  ALPINE_KILL_STALE_TAILSCALE_UP="${ALPINE_KILL_STALE_TAILSCALE_UP:-1}"
  ALPINE_TAILSCALE_UP_TIMEOUT_SEC="${ALPINE_TAILSCALE_UP_TIMEOUT_SEC:-120}"

  case "$HEADSCALE_SERVER_URL" in
    auto|https://headscale.example.com|http://headscale.example.com)
      if [ -n "$HEADSCALE_SERVER_HOSTNAME" ]; then
        HEADSCALE_SERVER_URL="https://${HEADSCALE_SERVER_HOSTNAME}"
      elif [ -n "${CLOUDFLARE_ZONE:-}" ]; then
        HEADSCALE_SERVER_URL="https://headscale.$(printf '%s' "$CLOUDFLARE_ZONE" | sed 's/[.]$//')"
      else
        HEADSCALE_SERVER_URL="https://headscale.hlwdot.com"
      fi
      ;;
  esac
}

begin_run() {
  {
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'script=%s\n' "$SCRIPT_NAME"
    printf 'pid=%s\n' "$$"
  } >"$RUN_MARKER"
}

finish_run() {
  {
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'script=%s\n' "$SCRIPT_NAME"
  } >"$DONE_MARKER"
  rm -f "$RUN_MARKER"
}

recover_previous_run() {
  cleanup_tempfiles
  if [ -f "$RUN_MARKER" ]; then
    warn "检测到上次运行未完成，本次将重新执行可重复步骤。"
  fi
}

ensure_community_repo() {
  repo=''
  version=''

  [ "$ALPINE_ENABLE_COMMUNITY_REPO" = 1 ] || return 0
  grep -Eq '^[^#].*/community([[:space:]]*)?$' /etc/apk/repositories && return 0

  if [ "$ALPINE_COMMUNITY_REPO_URL" != auto ]; then
    repo="$ALPINE_COMMUNITY_REPO_URL"
  else
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
  fi

  log "启用 Alpine community 仓库：$repo"
  printf '\n%s\n' "$repo" >>/etc/apk/repositories
}

install_packages() {
  packages='ca-certificates curl openrc openssl tar iptables iproute2'

  ensure_community_repo
  apk update
  if [ "$ALPINE_TAILSCALE_INSTALL_SOURCE" = apk ]; then
    packages="$packages tailscale tailscale-openrc"
  fi
  if [ "$ALPINE_TAILNET_DNS_MODE" != off ]; then
    packages="$packages dnsmasq"
  fi
  apk add $packages
  command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
}

tailscale_version_number() {
  command_exists tailscale || return 1
  tailscale version 2>/dev/null | awk 'NR == 1 { print $1; exit }'
}

version_ge() {
  current="$1"
  minimum="$2"
  current_major=${current%%.*}
  rest=${current#*.}
  current_minor=${rest%%.*}
  current_patch=${rest#*.}
  current_patch=${current_patch%%[!0-9]*}

  minimum_major=${minimum%%.*}
  rest=${minimum#*.}
  minimum_minor=${rest%%.*}
  minimum_patch=${rest#*.}
  minimum_patch=${minimum_patch%%[!0-9]*}

  [ "${current_major:-0}" -gt "${minimum_major:-0}" ] && return 0
  [ "${current_major:-0}" -lt "${minimum_major:-0}" ] && return 1
  [ "${current_minor:-0}" -gt "${minimum_minor:-0}" ] && return 0
  [ "${current_minor:-0}" -lt "${minimum_minor:-0}" ] && return 1
  [ "${current_patch:-0}" -ge "${minimum_patch:-0}" ]
}

tailscale_static_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv6l) printf 'arm\n' ;;
    i386|i686) printf '386\n' ;;
    *) die "当前架构不支持 Tailscale 静态包：$(uname -m)" ;;
  esac
}

download_to_file() {
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

resolve_tailscale_static_url() {
  arch=$(tailscale_static_arch)
  page="${TMP_DIR}/${SCRIPT_NAME}.$$.tailscale-packages.html"
  url=''

  if [ "$ALPINE_TAILSCALE_STATIC_URL" != auto ]; then
    printf '%s\n' "$ALPINE_TAILSCALE_STATIC_URL"
    return 0
  fi

  download_to_file https://pkgs.tailscale.com/stable/ "$page"
  url=$(
    grep -Eo "tailscale_[0-9][0-9.]*_${arch}[.]tgz" "$page" |
      awk 'NF { print "https://pkgs.tailscale.com/stable/" $0; exit }'
  )
  [ -n "$url" ] || die "无法解析 Tailscale 静态包下载地址。"
  printf '%s\n' "$url"
}

install_tailscale_static() {
  url=$(resolve_tailscale_static_url)
  tgz="${TMP_DIR}/${SCRIPT_NAME}.$$.tailscale.tgz"
  sum_file="${TMP_DIR}/${SCRIPT_NAME}.$$.tailscale.tgz.sha256"
  unpack_dir="${TMP_DIR}/${SCRIPT_NAME}.$$.tailscale"
  bin_dir=''
  version=''

  log "下载 Tailscale 静态包：$url"
  download_to_file "$url" "$tgz"
  if command_exists sha256sum && download_to_file "${url}.sha256" "$sum_file"; then
    expected=$(awk 'NF { print $1; exit }' "$sum_file")
    actual=$(sha256sum "$tgz" | awk '{ print $1 }')
    [ "$expected" = "$actual" ] || die "Tailscale 静态包校验失败。"
  fi

  mkdir -p "$unpack_dir"
  tar -xzf "$tgz" -C "$unpack_dir"
  bin_dir=$(find "$unpack_dir" -mindepth 1 -maxdepth 1 -type d -name 'tailscale_*' | head -n 1)
  [ -x "${bin_dir}/tailscale" ] && [ -x "${bin_dir}/tailscaled" ] || die "Tailscale 静态包内容不完整。"

  version=$(basename "$bin_dir" | sed -E 's/^tailscale_([0-9.]+)_.*/\1/')
  mkdir -p "/usr/local/lib/tailscale-${version}" /usr/local/bin /usr/local/sbin
  cp "$bin_dir/tailscale" "/usr/local/lib/tailscale-${version}/tailscale"
  cp "$bin_dir/tailscaled" "/usr/local/lib/tailscale-${version}/tailscaled"
  chmod 0755 "/usr/local/lib/tailscale-${version}/tailscale" "/usr/local/lib/tailscale-${version}/tailscaled"
  ln -sf "/usr/local/lib/tailscale-${version}/tailscale" /usr/local/bin/tailscale
  ln -sf "/usr/local/lib/tailscale-${version}/tailscaled" /usr/local/sbin/tailscaled
  log "已安装 Tailscale 静态包：v${version}"
}

ensure_tailscale_version() {
  current=''

  current=$(tailscale_version_number || true)
  if [ -n "$current" ] && version_ge "$current" "$ALPINE_TAILSCALE_MIN_VERSION"; then
    log "Tailscale 版本满足要求：v${current}"
    return 0
  fi

  if [ "$ALPINE_TAILSCALE_INSTALL_SOURCE" = apk ]; then
    die "当前 Tailscale 版本 ${current:-未安装} 低于 ${ALPINE_TAILSCALE_MIN_VERSION}；请使用 ALPINE_TAILSCALE_INSTALL_SOURCE=auto 或 static。"
  fi

  install_tailscale_static
  current=$(tailscale_version_number || true)
  [ -n "$current" ] && version_ge "$current" "$ALPINE_TAILSCALE_MIN_VERSION" || die "Tailscale 版本仍低于 ${ALPINE_TAILSCALE_MIN_VERSION}。"
}

configure_tun_module() {
  mkdir -p /etc/modules-load.d
  printf 'tun\n' >/etc/modules-load.d/90-hlwdot-tailscale.conf
  touch /etc/modules
  grep -qxF tun /etc/modules || printf 'tun\n' >>/etc/modules

  if [ -c /dev/net/tun ]; then
    log "tun 设备已就绪。"
    return 0
  fi

  modprobe tun 2>/dev/null || true
  if [ -c /dev/net/tun ]; then
    log "tun 设备已就绪。"
    return 0
  fi

  mkdir -p /dev/net
  if command_exists mknod; then
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 0666 /dev/net/tun 2>/dev/null || true
  fi

  if [ -c /dev/net/tun ]; then
    log "tun 设备已就绪。"
  else
    warn "未检测到 /dev/net/tun；如果 tailscaled 启动失败，请检查 VPS 是否允许 TUN。"
  fi
}

tailscaled_bin() {
  command -v tailscaled 2>/dev/null || printf '/usr/sbin/tailscaled'
}

write_openrc_service() {
  bin_path=$(tailscaled_bin)

  cat >"$HOLLOW_OPENRC_CONF" <<EOF
HOLLOW_TAILSCALED_BIN="$bin_path"
HOLLOW_TAILSCALED_STATE="/var/lib/tailscale/tailscaled.state"
HOLLOW_TAILSCALED_SOCKET="/run/tailscale/tailscaled.sock"
HOLLOW_TAILSCALE_PORT="41641"
HOLLOW_NET_IFACE="$HOLLOW_NET_IFACE"
HOLLOW_TAILSCALED_EXTRA_ARGS=""
EOF
  chmod 0644 "$HOLLOW_OPENRC_CONF"

  cat >"$HOLLOW_OPENRC_INIT" <<'EOF'
#!/sbin/openrc-run

name="hollow-tailscaled"
description="HlwDot tailscaled for Headscale network"
supervisor="${HOLLOW_TAILSCALED_SUPERVISOR:-supervise-daemon}"
command="${HOLLOW_TAILSCALED_BIN:-/usr/sbin/tailscaled}"
command_args="--state=${HOLLOW_TAILSCALED_STATE:-/var/lib/tailscale/tailscaled.state} --socket=${HOLLOW_TAILSCALED_SOCKET:-/run/tailscale/tailscaled.sock} --port=${HOLLOW_TAILSCALE_PORT:-41641} --tun=${HOLLOW_NET_IFACE:-hollow-net} ${HOLLOW_TAILSCALED_EXTRA_ARGS:-}"
pidfile="/run/${RC_SVCNAME}.pid"
respawn_delay="${HOLLOW_TAILSCALED_RESPAWN_DELAY:-5}"
respawn_max="${HOLLOW_TAILSCALED_RESPAWN_MAX:-0}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -d -m 0755 /run/tailscale
  checkpath -d -m 0700 /var/lib/tailscale
  checkpath -d -m 0755 /dev/net
  modprobe tun 2>/dev/null || true
  if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 0666 /dev/net/tun 2>/dev/null || true
  fi
}
EOF
  chmod 0755 "$HOLLOW_OPENRC_INIT"
}

start_tailscaled() {
  if [ -x /etc/init.d/tailscale ]; then
    rc-service tailscale stop >/dev/null 2>&1 || true
    rc-update del tailscale default >/dev/null 2>&1 || true
    rc-update del tailscale sysinit >/dev/null 2>&1 || true
  fi

  rc-update add "$HOLLOW_OPENRC_SERVICE" default >/dev/null
  if rc-service "$HOLLOW_OPENRC_SERVICE" status >/dev/null 2>&1; then
    rc-service "$HOLLOW_OPENRC_SERVICE" restart || warn "${HOLLOW_OPENRC_SERVICE} restart 返回非零，继续按 socket 状态复查。"
  else
    rc-service "$HOLLOW_OPENRC_SERVICE" start || warn "${HOLLOW_OPENRC_SERVICE} start 返回非零，继续按 socket 状态复查。"
  fi
}

wait_tailscaled_socket() {
  i=0
  while [ "$i" -lt 30 ]; do
    [ -S /run/tailscale/tailscaled.sock ] && return 0
    i=$((i + 1))
    sleep 1
  done
  die "tailscaled socket 未就绪。"
}

configure_forwarding_if_needed() {
  need_forward=0
  if [ "$ALPINE_ENABLE_FORWARDING" = 1 ]; then
    need_forward=1
  elif [ "$ALPINE_ENABLE_FORWARDING" = auto ]; then
    [ -n "$HEADSCALE_ADVERTISE_ROUTES" ] && need_forward=1
    { [ "$ALPINE_SPLIT_DIRECTION" = inbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; } && [ -n "$ALPINE_SPLIT_ROUTE_CIDRS" ] && need_forward=1
    { [ "$ALPINE_SPLIT_DIRECTION" = inbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; } && [ -n "$ALPINE_SPLIT_INBOUND_FORWARDS" ] && need_forward=1
  fi
  [ "$need_forward" = 1 ] || return 0

  cat >/etc/sysctl.d/90-hlwdot-hollow-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl -p /etc/sysctl.d/90-hlwdot-hollow-forward.conf >/dev/null 2>&1 || true
  log "已打开系统转发能力。"
}

split_words() {
  printf '%s\n' "$1" | tr ' ,;' '\n' | awk 'NF { print }'
}

valid_dns_domain() {
  value="$1"
  case "$value" in
    ''|.*|*.|*[!A-Za-z0-9_.-]*|*..*|*.-*|*-.*) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_dns_upstream() {
  value="$1"
  case "$value" in
    ''|*[!0-9A-Fa-f:.]*) return 1 ;;
    *.*|*:*) return 0 ;;
    *) return 1 ;;
  esac
}

resolv_conf_hlwdot_managed() {
  [ -r /etc/resolv.conf ] || return 1
  grep -q 'HlwDot tailnet DNS resolver' /etc/resolv.conf
}

original_resolv_source() {
  if [ -r "$TAILNET_DNS_RESOLV_BACKUP" ]; then
    printf '%s\n' "$TAILNET_DNS_RESOLV_BACKUP"
  else
    printf '/etc/resolv.conf\n'
  fi
}

resolv_search_domains() {
  source_file=$(original_resolv_source)
  [ -r "$source_file" ] || return 0
  awk '
    /^[[:space:]]*search[[:space:]]+/ {
      for (i = 2; i <= NF; i++) print $i
    }
    /^[[:space:]]*domain[[:space:]]+/ {
      print $2
    }
  ' "$source_file"
}

resolv_nameservers() {
  source_file="$1"
  [ -r "$source_file" ] || return 0
  awk '
    /^[[:space:]]*nameserver[[:space:]]+/ {
      if ($2 != "127.0.0.1" && $2 != "::1" && $2 != "100.100.100.100") print $2
    }
  ' "$source_file"
}

tailnet_dns_domains() {
  if [ "$ALPINE_TAILNET_DNS_DOMAINS" != auto ]; then
    split_words "$ALPINE_TAILNET_DNS_DOMAINS"
    return 0
  fi

  if [ -n "${HEADSCALE_DNS_BASE_DOMAIN:-}" ] && [ "$HEADSCALE_DNS_BASE_DOMAIN" != auto ]; then
    printf '%s\n' "$HEADSCALE_DNS_BASE_DOMAIN"
  elif [ -n "${CLOUDFLARE_ZONE:-}" ]; then
    printf 'net.%s\n' "$(printf '%s' "$CLOUDFLARE_ZONE" | sed 's/[.]$//')"
  fi
}

tailnet_dns_needed() {
  case "$ALPINE_TAILNET_DNS_MODE" in
    off) return 1 ;;
    dnsmasq) return 0 ;;
    auto)
      resolv_conf_lxd_managed || tailscale_dns_fight_reported || resolv_conf_hlwdot_managed
      ;;
  esac
}

tailnet_dns_upstreams() {
  source_file=$(original_resolv_source)
  upstreams=''

  if [ "$ALPINE_TAILNET_DNS_UPSTREAMS" != auto ]; then
    split_words "$ALPINE_TAILNET_DNS_UPSTREAMS"
    return 0
  fi

  if [ -r /etc/resolv.conf ] && ! resolv_conf_hlwdot_managed; then
    upstreams=$(resolv_nameservers /etc/resolv.conf)
  fi
  if [ -z "$upstreams" ] && [ -r "$TAILNET_DNS_UPSTREAMS_FILE" ]; then
    upstreams=$(awk 'NF { print }' "$TAILNET_DNS_UPSTREAMS_FILE")
  fi
  if [ -z "$upstreams" ]; then
    upstreams=$(resolv_nameservers "$source_file")
  fi

  printf '%s\n' "$upstreams" | awk 'NF { print }'
}

save_tailnet_dns_original_state() {
  mkdir -p /etc/hlwdot
  chmod 0700 /etc/hlwdot

  if [ -r /etc/resolv.conf ] && ! resolv_conf_hlwdot_managed; then
    cp /etc/resolv.conf "$TAILNET_DNS_RESOLV_BACKUP"
    chmod 0600 "$TAILNET_DNS_RESOLV_BACKUP"
    resolv_nameservers /etc/resolv.conf >"$TAILNET_DNS_UPSTREAMS_FILE"
    chmod 0600 "$TAILNET_DNS_UPSTREAMS_FILE"
  fi
}

ensure_dnsmasq_include_dir() {
  mkdir -p /etc/dnsmasq.d
  touch /etc/dnsmasq.conf
  if ! grep -Eq '^[[:space:]]*conf-dir=/etc/dnsmasq[.]d' /etc/dnsmasq.conf; then
    {
      printf '\n'
      printf '# HlwDot managed include directory.\n'
      printf 'conf-dir=/etc/dnsmasq.d,*.conf\n'
    } >>/etc/dnsmasq.conf
  fi
}

write_tailnet_dnsmasq_conf() {
  temp_file="${TMP_DIR}/${SCRIPT_NAME}.$$.dnsmasq"
  domains=$(tailnet_dns_domains | awk '!seen[$0]++')
  upstreams=$(tailnet_dns_upstreams | awk '!seen[$0]++')

  [ -n "$domains" ] || die "无法确定 Headscale DNS 域，请设置 ALPINE_TAILNET_DNS_DOMAINS。"
  [ -n "$upstreams" ] || die "无法保留原 DNS 上游，请设置 ALPINE_TAILNET_DNS_UPSTREAMS。"

  printf '%s\n' "$domains" | while IFS= read -r domain; do
    valid_dns_domain "$domain" || die "DNS 域名格式错误：$domain"
  done
  printf '%s\n' "$upstreams" | while IFS= read -r upstream; do
    valid_dns_upstream "$upstream" || die "DNS 上游格式错误：$upstream"
  done

  {
    printf '# HlwDot tailnet DNS resolver. Generated by alpine-hollow-client.sh.\n'
    printf 'no-resolv\n'
    printf 'listen-address=127.0.0.1\n'
    printf 'bind-interfaces\n'
    printf 'local-service=host\n'
    printf 'cache-size=1000\n'
    printf '\n'
    printf '%s\n' "$upstreams" | while IFS= read -r upstream; do
      [ -n "$upstream" ] && printf 'server=%s\n' "$upstream"
    done
    printf '\n'
    printf '%s\n' "$domains" | while IFS= read -r domain; do
      [ -n "$domain" ] && printf 'server=/%s/100.100.100.100\n' "$domain"
    done
  } >"$temp_file"

  cat "$temp_file" >"$TAILNET_DNSMASQ_CONF"
  chmod 0644 "$TAILNET_DNSMASQ_CONF"
}

write_tailnet_resolv_conf() {
  temp_file="${TMP_DIR}/${SCRIPT_NAME}.$$.resolv"
  search_domains=$(
    {
      tailnet_dns_domains
      resolv_search_domains
    } | awk 'NF && !seen[$0]++ { print }'
  )

  {
    printf '# HlwDot tailnet DNS resolver. Generated by alpine-hollow-client.sh.\n'
    if [ -n "$search_domains" ]; then
      printf 'search'
      printf '%s\n' "$search_domains" | while IFS= read -r domain; do
        [ -n "$domain" ] && printf ' %s' "$domain"
      done
      printf '\n'
    fi
    printf 'nameserver 127.0.0.1\n'
  } >"$temp_file"

  cat "$temp_file" >/etc/resolv.conf
  chmod 0644 /etc/resolv.conf
}

start_dnsmasq_service() {
  command_exists dnsmasq || die "缺少 dnsmasq。"
  dnsmasq --test >/dev/null
  rc-update add dnsmasq default >/dev/null
  if rc-service dnsmasq status >/dev/null 2>&1; then
    rc-service dnsmasq restart
  else
    rc-service dnsmasq start
  fi
}

tailnet_dns_probe_name() {
  domains=$(tailnet_dns_domains | awk 'NF { printf "%s%s", sep, $0; sep = "|" }')
  [ -n "$domains" ] || return 1
  tailscale status 2>/dev/null |
    awk -v domains="$domains" '
      BEGIN { n = split(domains, d, "|") }
      /^[0-9]/ {
        for (i = 1; i <= n; i++) {
          suffix = "." d[i]
          if ($2 == d[i] || substr($2, length($2) - length(suffix) + 1) == suffix) {
            print $2
            exit
          }
        }
      }
    '
}

verify_tailnet_dns_proxy() {
  rc-service dnsmasq status >/dev/null 2>&1 || die "dnsmasq 未运行。"
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+127[.]0[.]0[.]1([[:space:]]|$)' /etc/resolv.conf || die "/etc/resolv.conf 未指向本地 dnsmasq。"
  nslookup github.com 127.0.0.1 >/dev/null 2>&1 || die "本地 dnsmasq 无法转发普通公网 DNS。"

  probe=$(tailnet_dns_probe_name || true)
  if [ -n "$probe" ]; then
    nslookup "$probe" 127.0.0.1 2>/dev/null | grep -Eq 'Address:[[:space:]]+100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' ||
      die "本地 dnsmasq 无法解析 Headscale DNS：$probe"
    getent hosts "$probe" >/dev/null 2>&1 || die "系统 resolver 无法解析 Headscale DNS：$probe"
  else
    warn "未找到可用于验证的 Headscale DNS peer，已跳过内网域名解析验证。"
  fi

  log "本地 DNS 分流验证通过。"
}

configure_tailnet_dns_proxy() {
  if ! tailnet_dns_needed; then
    return 0
  fi

  save_tailnet_dns_original_state
  ensure_dnsmasq_include_dir
  write_tailnet_dnsmasq_conf
  start_dnsmasq_service
  write_tailnet_resolv_conf
  verify_tailnet_dns_proxy
}

resolve_public_iface() {
  if [ "$ALPINE_PUBLIC_IFACE" != auto ]; then
    printf '%s\n' "$ALPINE_PUBLIC_IFACE"
    return 0
  fi
  ip route show default 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

validate_port_proto() {
  value="$1"
  port=${value%/*}
  proto=${value#*/}
  [ "$port" != "$value" ] || return 1
  case "$proto" in
    tcp|udp) ;;
    *) return 1 ;;
  esac
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

write_split_rules_script() {
  public_iface=$(resolve_public_iface)
  need_rules=0

  case "$ALPINE_SPLIT_DIRECTION" in
    outbound|both)
      [ -n "$ALPINE_SPLIT_OUTBOUND_PROXY_PORTS" ] && need_rules=1
      ;;
  esac
  case "$ALPINE_SPLIT_DIRECTION" in
    inbound|both)
      [ -n "$ALPINE_SPLIT_INBOUND_FORWARDS" ] && need_rules=1
      ;;
  esac

  if [ "$need_rules" != 1 ]; then
    cleanup_split_rules
    return 0
  fi
  [ -n "$public_iface" ] || die "无法自动识别公网网卡，请设置 ALPINE_PUBLIC_IFACE。"

  mkdir -p /etc/local.d
  {
    printf '#!/bin/sh\n'
    printf '# Headscale 网络分流规则。由 alpine-hollow-client.sh 生成。\n\n'
    printf 'set -eu\n\n'
    printf 'HOLLOW_NET_IFACE=%s\n' "$(shell_quote "$HOLLOW_NET_IFACE")"
    printf 'PUBLIC_IFACE=%s\n\n' "$(shell_quote "$public_iface")"
    printf 'iptables -N HLWDOT_SPLIT_INPUT 2>/dev/null || true\n'
    printf 'iptables -F HLWDOT_SPLIT_INPUT\n'
    printf 'iptables -C INPUT -j HLWDOT_SPLIT_INPUT 2>/dev/null || iptables -A INPUT -j HLWDOT_SPLIT_INPUT\n'
    printf 'iptables -N HLWDOT_SPLIT_FORWARD 2>/dev/null || true\n'
    printf 'iptables -F HLWDOT_SPLIT_FORWARD\n'
    printf 'iptables -C FORWARD -j HLWDOT_SPLIT_FORWARD 2>/dev/null || iptables -A FORWARD -j HLWDOT_SPLIT_FORWARD\n'
    printf 'iptables -A HLWDOT_SPLIT_FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n'
    printf 'iptables -t nat -N HLWDOT_SPLIT_PREROUTING 2>/dev/null || true\n'
    printf 'iptables -t nat -F HLWDOT_SPLIT_PREROUTING\n'
    printf 'iptables -t nat -C PREROUTING -j HLWDOT_SPLIT_PREROUTING 2>/dev/null || iptables -t nat -A PREROUTING -j HLWDOT_SPLIT_PREROUTING\n'
    printf 'iptables -t nat -N HLWDOT_SPLIT_POSTROUTING 2>/dev/null || true\n'
    printf 'iptables -t nat -F HLWDOT_SPLIT_POSTROUTING\n'
    printf 'iptables -t nat -C POSTROUTING -j HLWDOT_SPLIT_POSTROUTING 2>/dev/null || iptables -t nat -A POSTROUTING -j HLWDOT_SPLIT_POSTROUTING\n\n'

    if [ "$ALPINE_SPLIT_DIRECTION" = outbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; then
      split_words "$ALPINE_SPLIT_OUTBOUND_PROXY_PORTS" | while IFS= read -r item; do
        [ -n "$item" ] || continue
        validate_port_proto "$item" || die "ALPINE_SPLIT_OUTBOUND_PROXY_PORTS 格式错误：$item"
        port=${item%/*}
        proto=${item#*/}
        printf 'iptables -A HLWDOT_SPLIT_INPUT -i "$HOLLOW_NET_IFACE" -p %s --dport %s -j ACCEPT\n' "$proto" "$port"
      done
    fi

    if [ "$ALPINE_SPLIT_DIRECTION" = inbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; then
      split_words "$ALPINE_SPLIT_INBOUND_FORWARDS" | while IFS= read -r item; do
        [ -n "$item" ] || continue
        left=${item%%=*}
        target=${item#*=}
        [ "$left" != "$item" ] || die "ALPINE_SPLIT_INBOUND_FORWARDS 格式错误：$item"
        validate_port_proto "$left" || die "ALPINE_SPLIT_INBOUND_FORWARDS 端口格式错误：$item"
        listen_port=${left%/*}
        proto=${left#*/}
        target_ip=${target%:*}
        target_port=${target##*:}
        [ "$target_ip" != "$target" ] || die "ALPINE_SPLIT_INBOUND_FORWARDS 目标格式错误：$item"
        case "$target_port" in
          ''|*[!0-9]*) die "ALPINE_SPLIT_INBOUND_FORWARDS 目标端口错误：$item" ;;
        esac
        [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ] || die "ALPINE_SPLIT_INBOUND_FORWARDS 目标端口越界：$item"
        printf 'iptables -t nat -A HLWDOT_SPLIT_PREROUTING -i "$PUBLIC_IFACE" -p %s --dport %s -j DNAT --to-destination %s\n' "$proto" "$listen_port" "$target"
        printf 'iptables -A HLWDOT_SPLIT_FORWARD -i "$PUBLIC_IFACE" -o "$HOLLOW_NET_IFACE" -p %s -d %s --dport %s -j ACCEPT\n' "$proto" "$target_ip" "$target_port"
        printf 'iptables -t nat -A HLWDOT_SPLIT_POSTROUTING -o "$HOLLOW_NET_IFACE" -p %s -d %s --dport %s -j MASQUERADE\n' "$proto" "$target_ip" "$target_port"
      done
    fi
  } >"$SPLIT_LOCAL_SCRIPT"
  chmod 0755 "$SPLIT_LOCAL_SCRIPT"

  rc-update add local default >/dev/null 2>&1 || true
  sh "$SPLIT_LOCAL_SCRIPT"
  log "已配置 Headscale 网络分流规则：${ALPINE_SPLIT_DIRECTION}"
}

cleanup_split_rules() {
  removed=0

  if [ -e "$SPLIT_LOCAL_SCRIPT" ]; then
    rm -f "$SPLIT_LOCAL_SCRIPT"
    removed=1
  fi
  if command_exists iptables; then
    iptables -D INPUT -j HLWDOT_SPLIT_INPUT 2>/dev/null || true
    iptables -D FORWARD -j HLWDOT_SPLIT_FORWARD 2>/dev/null || true
    iptables -t nat -D PREROUTING -j HLWDOT_SPLIT_PREROUTING 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j HLWDOT_SPLIT_POSTROUTING 2>/dev/null || true
    iptables -F HLWDOT_SPLIT_INPUT 2>/dev/null || true
    iptables -F HLWDOT_SPLIT_FORWARD 2>/dev/null || true
    iptables -t nat -F HLWDOT_SPLIT_PREROUTING 2>/dev/null || true
    iptables -t nat -F HLWDOT_SPLIT_POSTROUTING 2>/dev/null || true
    iptables -X HLWDOT_SPLIT_INPUT 2>/dev/null || true
    iptables -X HLWDOT_SPLIT_FORWARD 2>/dev/null || true
    iptables -t nat -X HLWDOT_SPLIT_PREROUTING 2>/dev/null || true
    iptables -t nat -X HLWDOT_SPLIT_POSTROUTING 2>/dev/null || true
  fi
  [ "$removed" = 1 ] && log "已清理旧的 Headscale 网络分流规则。"
  return 0
}

split_rules_enabled() {
  case "$ALPINE_SPLIT_DIRECTION" in
    outbound|both)
      [ -n "$ALPINE_SPLIT_OUTBOUND_PROXY_PORTS" ] && return 0
      ;;
  esac
  case "$ALPINE_SPLIT_DIRECTION" in
    inbound|both)
      [ -n "$ALPINE_SPLIT_INBOUND_FORWARDS" ] && return 0
      ;;
  esac
  return 1
}

tailnet_already_up() {
  command_exists tailscale || return 1
  tailscale status --self >/dev/null 2>&1 || return 1
  [ -n "$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }')" ]
}

tailscale_current_accept_dns() {
  command_exists tailscale || return 1
  tailscale debug prefs 2>/dev/null |
    awk -F: '/"CorpDNS"/ { gsub(/[ ,]/, "", $2); print $2; exit }'
}

sync_tailscale_accept_dns() {
  command_exists tailscale || return 1
  tailscale set "--accept-dns=${HEADSCALE_ACCEPT_DNS}"
}

tailscale_dns_fight_reported() {
  command_exists tailscale || return 1
  tailscale status 2>/dev/null |
    grep -Eq 'dns-fight|System DNS config not ideal|/etc/resolv[.]conf overwritten'
}

resolv_conf_lxd_managed() {
  [ -r /etc/resolv.conf ] || return 1
  [ ! -L /etc/resolv.conf ] || return 1
  grep -Eq '(^search[[:space:]].*([[:space:]]|^)lxd([[:space:]]|$)|^nameserver[[:space:]]+10[.]45[.]153[.]1$)' /etc/resolv.conf
}

maybe_disable_tailscale_dns_fight() {
  [ "$HEADSCALE_AUTO_DISABLE_DNS_FIGHT" = 1 ] || return 0
  [ "$HEADSCALE_ACCEPT_DNS" = true ] || return 0

  if tailscale_dns_fight_reported; then
    warn "检测到 Tailscale DNS fight，将关闭系统 DNS 接管。"
  elif resolv_conf_lxd_managed; then
    warn "检测到 LXD 管理的 /etc/resolv.conf，将关闭系统 DNS 接管。"
  else
    return 0
  fi

  HEADSCALE_ACCEPT_DNS=false
  persist_env_value HEADSCALE_ACCEPT_DNS "$HEADSCALE_ACCEPT_DNS"
}

url_host() {
  value="$1"
  value=${value#*://}
  value=${value%%/*}
  value=${value%%:*}
  printf '%s\n' "$value"
}

url_scheme() {
  value="$1"
  printf '%s\n' "${value%%://*}"
}

headscale_key_url() {
  value=${HEADSCALE_SERVER_URL%/}
  printf '%s/key?v=133\n' "$value"
}

check_headscale_certificate_name() {
  host=$(url_host "$HEADSCALE_SERVER_URL")
  scheme=$(url_scheme "$HEADSCALE_SERVER_URL")
  cert_subject=''

  [ "$scheme" = https ] || return 0
  [ -n "$host" ] || return 0
  command_exists openssl || return 0

  cert_subject=$(
    printf '\n' |
      openssl s_client -connect "${host}:443" -servername "$host" -showcerts 2>/dev/null |
      openssl x509 -noout -subject 2>/dev/null || true
  )

  case "$cert_subject" in
    *"TRAEFIK DEFAULT CERT"*)
      die "Headscale 入口当前返回 TRAEFIK DEFAULT CERT，请先重新执行 Headscale 主节点部署脚本修正 HTTPS 入口。"
      ;;
  esac
}

check_headscale_endpoint() {
  url=$(headscale_key_url)
  err_file="${TMP_DIR}/${SCRIPT_NAME}.$$.headscale-endpoint.err"
  out_file="${TMP_DIR}/${SCRIPT_NAME}.$$.headscale-endpoint.out"

  [ "$HEADSCALE_ENDPOINT_CHECK" = 1 ] || return 0

  check_headscale_certificate_name

  if command_exists curl; then
    if curl -fsSL \
      --connect-timeout "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" \
      --max-time "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" \
      "$url" -o "$out_file" 2>"$err_file"; then
      log "Headscale 入口检查通过：$url"
      return 0
    fi
  elif command_exists wget; then
    if wget -q -T "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" -O "$out_file" "$url" 2>"$err_file"; then
      log "Headscale 入口检查通过：$url"
      return 0
    fi
  else
    die "缺少 curl 或 wget，无法检查 Headscale 入口。"
  fi

  if grep -q 'TRAEFIK DEFAULT CERT' "$err_file" 2>/dev/null; then
    die "Headscale 入口返回 TRAEFIK DEFAULT CERT，请重新执行 Headscale 主节点部署脚本。"
  fi

  err_text=$(sed -n '1,3p' "$err_file" 2>/dev/null | tr '\n' ' ')
  die "Headscale 入口不可用：$url ${err_text}"
}

stop_stale_tailscale_up() {
  pids=''

  [ "$ALPINE_KILL_STALE_TAILSCALE_UP" = 1 ] || return 0
  command_exists ps || return 0

  pids=$(
    ps w 2>/dev/null |
      awk -v self="$$" '$0 ~ /[t]ailscale[[:space:]]+up/ && $1 != self { print $1 }' || true
  )
  [ -n "$pids" ] || return 0

  warn "检测到未结束的 tailscale up，正在停止后重试。"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

run_with_timeout() {
  timeout_seconds="$1"
  shift
  child_pid=''
  elapsed=0
  exit_code=0

  if command_exists timeout; then
    timeout "$timeout_seconds" "$@" || return $?
    return 0
  fi

  "$@" &
  child_pid=$!
  while kill -0 "$child_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$child_pid" 2>/dev/null || true
      sleep 2
      kill -0 "$child_pid" 2>/dev/null && kill -KILL "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$child_pid" || exit_code=$?
  return "$exit_code"
}

run_tailscale_up() {
  exit_code=0
  already_up=0
  current_accept_dns=''

  if tailnet_already_up; then
    already_up=1
  fi

  if [ "$HEADSCALE_RESET" != 1 ] && [ "$already_up" = 1 ]; then
    current_accept_dns=$(tailscale_current_accept_dns || true)
    if [ "$current_accept_dns" = "$HEADSCALE_ACCEPT_DNS" ]; then
      log "当前节点已接入 Headscale 网络。"
      return 0
    fi
    log "当前节点已接入 Headscale 网络，正在同步 DNS 接管偏好。"
    sync_tailscale_accept_dns
    return 0
  fi
  if [ -z "$HEADSCALE_AUTHKEY" ] && [ "$already_up" != 1 ] && [ "$ALPINE_ALLOW_INTERACTIVE_LOGIN" != 1 ]; then
    die "请填写 HEADSCALE_AUTHKEY；需要手动网页登录时设置 ALPINE_ALLOW_INTERACTIVE_LOGIN=1。"
  fi

  set -- up --login-server "$HEADSCALE_SERVER_URL" "--accept-dns=${HEADSCALE_ACCEPT_DNS}" "--timeout=${ALPINE_TAILSCALE_UP_TIMEOUT_SEC}s"
  if [ -n "$HEADSCALE_AUTHKEY" ] && { [ "$already_up" != 1 ] || [ "$HEADSCALE_RESET" = 1 ]; }; then
    set -- "$@" --auth-key "$HEADSCALE_AUTHKEY"
  fi
  [ -n "$HEADSCALE_CLIENT_HOSTNAME" ] && set -- "$@" --hostname "$HEADSCALE_CLIENT_HOSTNAME"
  if [ -n "$HEADSCALE_ADVERTISE_ROUTES" ]; then
    set -- "$@" --advertise-routes "$HEADSCALE_ADVERTISE_ROUTES"
  elif { [ "$ALPINE_SPLIT_DIRECTION" = inbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; } && [ -n "$ALPINE_SPLIT_ROUTE_CIDRS" ]; then
    set -- "$@" --advertise-routes "$ALPINE_SPLIT_ROUTE_CIDRS"
  fi
  [ "$HEADSCALE_ENABLE_TS_SSH" = 1 ] && set -- "$@" --ssh
  [ "$HEADSCALE_RESET" = 1 ] && set -- "$@" --reset

  # HEADSCALE_EXTRA_UP_ARGS 用于少量额外开关，按空白拆分。
  # 复杂参数应直接写进脚本配置，避免 shell 解析歧义。
  for extra in $HEADSCALE_EXTRA_UP_ARGS; do
    set -- "$@" "$extra"
  done

  stop_stale_tailscale_up
  check_headscale_endpoint
  log "执行 tailscale up。"
  run_with_timeout "$ALPINE_TAILSCALE_UP_TIMEOUT_SEC" tailscale "$@" || exit_code=$?
  if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 143 ]; then
    die "tailscale up 超时；请检查 HEADSCALE_AUTHKEY 是否过期、已使用，或 Headscale 入口是否可达。"
  fi
  [ "$exit_code" -eq 0 ] || exit "$exit_code"
}

verify_tailnet_ready() {
  ip4=''

  tailscale status --self >/dev/null 2>&1 || die "tailscale 状态未就绪。"
  ip4=$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }' || true)
  [ -n "$ip4" ] || die "未获取到 Headscale IPv4 地址。"
  if command_exists ip; then
    ip link show "$HOLLOW_NET_IFACE" >/dev/null 2>&1 || die "未找到网卡 $HOLLOW_NET_IFACE。"
  fi
}

verify_reboot_persistence() {
  if ! rc-update show default 2>/dev/null | awk -v svc="$HOLLOW_OPENRC_SERVICE" '$1 == svc { found = 1 } END { exit found ? 0 : 1 }'; then
    die "${HOLLOW_OPENRC_SERVICE} 未加入 default 运行级别，主机重启后不会自动接入。"
  fi

  rc-service "$HOLLOW_OPENRC_SERVICE" status >/dev/null 2>&1 || die "${HOLLOW_OPENRC_SERVICE} 未运行。"
  [ -s /var/lib/tailscale/tailscaled.state ] || die "缺少 /var/lib/tailscale/tailscaled.state，主机重启后无法保持登录状态。"

  if split_rules_enabled; then
    [ -x "$SPLIT_LOCAL_SCRIPT" ] || die "分流规则未写入 $SPLIT_LOCAL_SCRIPT。"
    if ! rc-update show default 2>/dev/null | awk '$1 == "local" { found = 1 } END { exit found ? 0 : 1 }'; then
      die "local 服务未加入 default 运行级别，主机重启后分流规则不会自动恢复。"
    fi
  fi

  if tailnet_dns_needed; then
    if ! rc-update show default 2>/dev/null | awk '$1 == "dnsmasq" { found = 1 } END { exit found ? 0 : 1 }'; then
      die "dnsmasq 未加入 default 运行级别，主机重启后本地 DNS 分流不会自动恢复。"
    fi
  fi
}

persist_tailnet_state() {
  ip4=$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }' || true)
  [ -n "$ip4" ] && persist_env_value HEADSCALE_CLIENT_IP "$ip4"
}

print_summary() {
  printf '\nAlpine Headscale 网络接入完成。\n'
  printf '  login-server：%s\n' "$HEADSCALE_SERVER_URL"
  printf '  hostname：%s\n' "$HEADSCALE_CLIENT_HOSTNAME"
  printf '  网卡：%s\n' "$HOLLOW_NET_IFACE"
  tailscale status --self 2>/dev/null || true
  if [ -n "$HEADSCALE_ADVERTISE_ROUTES" ]; then
    printf '  分流路由：已上报，是否启用由 Headscale 控制端确认。\n'
  elif { [ "$ALPINE_SPLIT_DIRECTION" = inbound ] || [ "$ALPINE_SPLIT_DIRECTION" = both ]; } && [ -n "$ALPINE_SPLIT_ROUTE_CIDRS" ]; then
    printf '  分流路由：已上报，是否启用由 Headscale 控制端确认。\n'
  fi
  if [ "$ALPINE_SPLIT_DIRECTION" != none ]; then
    printf '  分流方向：%s\n' "$ALPINE_SPLIT_DIRECTION"
  fi
  if tailnet_dns_needed; then
    printf '  DNS：本地 dnsmasq 分流，默认保留原上游，Headscale 域走 100.100.100.100。\n'
  fi
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
  require_alpine
  setup_state_dir
  load_env
  apply_defaults
  validate_input
  recover_previous_run
  begin_run
  install_packages
  ensure_tailscale_version
  configure_tun_module
  write_openrc_service
  start_tailscaled
  wait_tailscaled_socket
  configure_forwarding_if_needed
  write_split_rules_script
  maybe_disable_tailscale_dns_fight
  run_tailscale_up
  verify_tailnet_ready
  configure_tailnet_dns_proxy
  verify_reboot_persistence
  persist_tailnet_state
  print_summary
  finish_run
}

main "$@"
