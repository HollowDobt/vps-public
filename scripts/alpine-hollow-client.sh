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
  ALPINE_SPLIT_DIRECTION=none
  ALPINE_SPLIT_ROUTE_CIDRS=10.45.153.0/24
  ALPINE_SPLIT_OUTBOUND_PROXY_PORTS=7890/tcp,7891/tcp
  ALPINE_SPLIT_INBOUND_FORWARDS=443/tcp=100.64.0.2:443

说明：
  - 仅支持 Alpine Linux + OpenRC。
  - 默认只接入 Headscale 网络，不部署 k3s。
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

persist_env_value() {
  key="$1"
  value="$2"
  target="/etc/hlwdot/vps.env"
  temp_file="${TMP_DIR}/${SCRIPT_NAME}.$$.$key"

  mkdir -p /etc/hlwdot
  chmod 0700 /etc/hlwdot
  [ -e "$target" ] || : >"$target"
  chmod 0600 "$target"

  awk -v key="$key" '$0 !~ "^[[:space:]]*" key "=" { print }' "$target" >"$temp_file"
  printf '%s=%s\n' "$key" "$(shell_quote "$value")" >>"$temp_file"
  cat "$temp_file" >"$target"
  chmod 0600 "$target"
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
  validate_bool ALPINE_ENABLE_COMMUNITY_REPO "$ALPINE_ENABLE_COMMUNITY_REPO"
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
  HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
  ALPINE_ENABLE_COMMUNITY_REPO="${ALPINE_ENABLE_COMMUNITY_REPO:-1}"
  ALPINE_COMMUNITY_REPO_URL="${ALPINE_COMMUNITY_REPO_URL:-auto}"
  ALPINE_ENABLE_FORWARDING="${ALPINE_ENABLE_FORWARDING:-auto}"
  ALPINE_SPLIT_DIRECTION="${ALPINE_SPLIT_DIRECTION:-none}"
  ALPINE_SPLIT_ROUTE_CIDRS="${ALPINE_SPLIT_ROUTE_CIDRS:-}"
  ALPINE_SPLIT_OUTBOUND_PROXY_PORTS="${ALPINE_SPLIT_OUTBOUND_PROXY_PORTS:-}"
  ALPINE_SPLIT_INBOUND_FORWARDS="${ALPINE_SPLIT_INBOUND_FORWARDS:-}"
  ALPINE_PUBLIC_IFACE="${ALPINE_PUBLIC_IFACE:-auto}"

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
  ensure_community_repo
  apk update
  apk add ca-certificates openrc iptables iproute2 tailscale tailscale-openrc
  command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
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
    rc-service "$HOLLOW_OPENRC_SERVICE" restart
  else
    rc-service "$HOLLOW_OPENRC_SERVICE" start
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
  printf '%s\n' "$1" | tr ',;' '\n' | awk 'NF { print }'
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

  [ "$need_rules" = 1 ] || return 0
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

tailnet_already_up() {
  command_exists tailscale || return 1
  tailscale status --self >/dev/null 2>&1 || return 1
  [ -n "$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }')" ]
}

run_tailscale_up() {
  if [ "$HEADSCALE_RESET" != 1 ] && tailnet_already_up; then
    log "当前节点已接入 Headscale 网络。"
    return 0
  fi

  set -- up --login-server "$HEADSCALE_SERVER_URL" "--accept-dns=${HEADSCALE_ACCEPT_DNS}"
  [ -n "$HEADSCALE_AUTHKEY" ] && set -- "$@" --auth-key "$HEADSCALE_AUTHKEY"
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

  log "执行 tailscale up。"
  tailscale "$@"
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
  configure_tun_module
  write_openrc_service
  start_tailscaled
  wait_tailscaled_socket
  configure_forwarding_if_needed
  write_split_rules_script
  run_tailscale_up
  persist_tailnet_state
  print_summary
  finish_run
}

main "$@"
