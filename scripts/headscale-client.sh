#!/usr/bin/env bash
# Headscale 客户端接入脚本。
#
# 安装 Tailscale 客户端，启动 tailscaled，然后把当前 VPS 接入指定
# Headscale 服务端。auth key 留空时会走手动登录流程。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/headscale-client"
readonly TUN_MODULES="/etc/modules-load.d/90-hlwdot-tailscale.conf"
readonly TAILSCALED_DEFAULTS="/etc/default/tailscaled"
readonly TAILSCALED_OVERRIDE="/etc/systemd/system/tailscaled.service.d/10-hlwdot-interface.conf"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

HEADSCALE_SERVER_URL="${HEADSCALE_SERVER_URL:-}"
HEADSCALE_SERVER_HOSTNAME="${HEADSCALE_SERVER_HOSTNAME:-}"
HEADSCALE_AUTHKEY="${HEADSCALE_AUTHKEY:-}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
HEADSCALE_ACCEPT_DNS="${HEADSCALE_ACCEPT_DNS:-true}"
HEADSCALE_ADVERTISE_ROUTES="${HEADSCALE_ADVERTISE_ROUTES:-}"
HEADSCALE_ADVERTISE_EXIT_NODE="${HEADSCALE_ADVERTISE_EXIT_NODE:-0}"
HEADSCALE_ENABLE_TS_SSH="${HEADSCALE_ENABLE_TS_SSH:-0}"
HEADSCALE_RESET="${HEADSCALE_RESET:-0}"
HEADSCALE_EXTRA_UP_ARGS="${HEADSCALE_EXTRA_UP_ARGS:-}"
HEADSCALE_ENDPOINT_CHECK="${HEADSCALE_ENDPOINT_CHECK:-1}"
HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC="${HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC:-15}"
HEADSCALE_CLIENT_UP_TIMEOUT_SEC="${HEADSCALE_CLIENT_UP_TIMEOUT_SEC:-120}"
HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
HOLLOW_NET_UFW_ALLOW="${HOLLOW_NET_UFW_ALLOW:-1}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

配置：
  HEADSCALE_SERVER_URL=https://headscale.example.com
  HEADSCALE_AUTHKEY=tskey-auth-...
  HEADSCALE_CLIENT_HOSTNAME=server-new

说明：
  - HEADSCALE_AUTHKEY 留空时，脚本会输出登录 URL。
  - HEADSCALE_RESET=1 可用于重新写入 tailscale up 参数。
EOF
}

validate_input() {
  [[ -n "$HEADSCALE_SERVER_URL" ]] || die "请在 .env 中设置 HEADSCALE_SERVER_URL。"
  [[ "$HEADSCALE_SERVER_URL" =~ ^https?:// ]] || die "HEADSCALE_SERVER_URL 必须以 http:// 或 https:// 开头。"
  [[ "$HOLLOW_NET_IFACE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "HOLLOW_NET_IFACE 包含非法字符。"
  case "$HEADSCALE_ACCEPT_DNS" in
    true | false) ;;
    *) die "HEADSCALE_ACCEPT_DNS 只能是 true 或 false。" ;;
  esac
  validate_bool HEADSCALE_ADVERTISE_EXIT_NODE "$HEADSCALE_ADVERTISE_EXIT_NODE"
  validate_bool HEADSCALE_ENABLE_TS_SSH "$HEADSCALE_ENABLE_TS_SSH"
  validate_bool HEADSCALE_RESET "$HEADSCALE_RESET"
  validate_bool HEADSCALE_ENDPOINT_CHECK "$HEADSCALE_ENDPOINT_CHECK"
  validate_bool HOLLOW_NET_UFW_ALLOW "$HOLLOW_NET_UFW_ALLOW"
  [[ "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC 必须是数字。"
  [[ "$HEADSCALE_CLIENT_UP_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "HEADSCALE_CLIENT_UP_TIMEOUT_SEC 必须是数字。"
}

resolve_server_url() {
  local host

  case "$HEADSCALE_SERVER_URL" in
    '' | auto | https://headscale.example.com | http://headscale.example.com)
      if [[ -n "$HEADSCALE_SERVER_HOSTNAME" ]]; then
        host="$HEADSCALE_SERVER_HOSTNAME"
      elif [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
        host="headscale.${CLOUDFLARE_ZONE%.}"
      else
        die "HEADSCALE_SERVER_URL=auto 时需要设置 HEADSCALE_SERVER_HOSTNAME 或 CLOUDFLARE_ZONE。"
      fi
      HEADSCALE_SERVER_URL="https://${host}"
      ;;
  esac
}

apply_defaults() {
  if [[ -z "$HEADSCALE_CLIENT_HOSTNAME" ]]; then
    HEADSCALE_CLIENT_HOSTNAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'vps')"
  fi
  if [[ -z "$K3S_NODE_NAME" ]]; then
    K3S_NODE_NAME="$HEADSCALE_CLIENT_HOSTNAME"
  fi
}

persist_client_config() {
  persist_env_value HEADSCALE_SERVER_URL "$HEADSCALE_SERVER_URL"
  persist_env_value HEADSCALE_CLIENT_HOSTNAME "$HEADSCALE_CLIENT_HOSTNAME"
  persist_env_value HOLLOW_NET_IFACE "$HOLLOW_NET_IFACE"
  persist_env_value HOLLOW_NET_UFW_ALLOW "$HOLLOW_NET_UFW_ALLOW"
  persist_env_value K3S_NODE_NAME "$K3S_NODE_NAME"
}

install_tailscale() {
  local install_script

  apt_install ca-certificates curl gnupg iproute2 lsb-release

  if command_exists tailscale && command_exists tailscaled; then
    log "Tailscale 已安装。"
    return 0
  fi

  install_script="$(mktemp_managed)"
  log "下载 Tailscale 安装脚本。"
  download_file https://tailscale.com/install.sh "$install_script"
  sh "$install_script"
}

configure_tun_module() {
  local temp_file

  modprobe tun 2>/dev/null || warn "tun 模块加载失败，稍后请检查当前 VPS 内核。"
  temp_file="$(mktemp_managed)"
  printf 'tun\n' >"$temp_file"
  atomic_install_file "$temp_file" "$TUN_MODULES" 0644 root root
}

configure_tailscaled_interface() {
  local temp_defaults
  local temp_override

  temp_defaults="$(mktemp_managed)"
  temp_override="$(mktemp_managed)"
  {
    printf 'PORT="41641"\n'
    printf 'FLAGS="--tun=%s"\n' "$HOLLOW_NET_IFACE"
  } >"$temp_defaults"
  {
    printf '[Service]\n'
    printf 'EnvironmentFile=-%s\n' "$TAILSCALED_DEFAULTS"
    printf 'ExecStart=\n'
    printf 'ExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} $FLAGS\n'
  } >"$temp_override"

  atomic_install_file "$temp_defaults" "$TAILSCALED_DEFAULTS" 0644 root root
  atomic_install_file "$temp_override" "$TAILSCALED_OVERRIDE" 0644 root root
  systemd_reload
}

start_tailscaled() {
  systemctl enable tailscaled >/dev/null 2>&1 || true
  systemctl restart tailscaled
}

tailnet_already_up() {
  command_exists tailscale || return 1
  tailscale status --self >/dev/null 2>&1 || return 1
  [[ -n "$(tailscale_ipv4)" ]]
}

headscale_key_url() {
  printf '%s/key?v=133\n' "${HEADSCALE_SERVER_URL%/}"
}

check_headscale_certificate_name() {
  local host
  local scheme
  local cert_subject

  scheme="${HEADSCALE_SERVER_URL%%://*}"
  [[ "$scheme" == "https" ]] || return 0
  host="$(url_host "$HEADSCALE_SERVER_URL")"
  [[ -n "$host" ]] || return 0
  command_exists openssl || return 0

  cert_subject="$(
    printf '\n' |
      openssl s_client -connect "${host}:443" -servername "$host" -showcerts 2>/dev/null |
      openssl x509 -noout -subject 2>/dev/null || true
  )"

  if grep -q 'TRAEFIK DEFAULT CERT' <<<"$cert_subject"; then
    die "Headscale 入口当前返回 TRAEFIK DEFAULT CERT，请先重新执行 Headscale 主节点部署脚本修正 HTTPS 入口。"
  fi
}

check_headscale_endpoint() {
  local url
  local out_file
  local err_file
  local err_text

  [[ "$HEADSCALE_ENDPOINT_CHECK" == "1" ]] || return 0

  url="$(headscale_key_url)"
  out_file="$(mktemp_managed)"
  err_file="$(mktemp_managed)"
  check_headscale_certificate_name

  if curl -fsSL \
    --connect-timeout "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" \
    --max-time "$HEADSCALE_ENDPOINT_CHECK_TIMEOUT_SEC" \
    "$url" -o "$out_file" 2>"$err_file"; then
    log "Headscale 入口检查通过：$url"
    return 0
  fi

  if grep -q 'TRAEFIK DEFAULT CERT' "$err_file" 2>/dev/null; then
    die "Headscale 入口返回 TRAEFIK DEFAULT CERT，请重新执行 Headscale 主节点部署脚本。"
  fi

  err_text="$(sed -n '1,3p' "$err_file" 2>/dev/null | tr '\n' ' ')"
  die "Headscale 入口不可用：$url ${err_text}"
}

stop_stale_tailscale_up() {
  local pids
  local pid

  pids="$(ps -eo pid=,args= 2>/dev/null | awk -v self="$$" '$0 ~ /[t]ailscale[[:space:]]+up/ && $1 != self { print $1 }' || true)"
  [[ -n "$pids" ]] || return 0

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

run_tailscale_up() {
  local args=(up --login-server "$HEADSCALE_SERVER_URL" "--accept-dns=${HEADSCALE_ACCEPT_DNS}" "--timeout=${HEADSCALE_CLIENT_UP_TIMEOUT_SEC}s")
  local extra
  local exit_code=0

  if [[ "$HEADSCALE_RESET" != "1" ]] && tailnet_already_up; then
    log "当前节点已接入 Headscale 网络。"
    return 0
  fi

  if [[ -n "$HEADSCALE_AUTHKEY" ]]; then
    args+=(--auth-key "$HEADSCALE_AUTHKEY")
  fi
  if [[ -n "$HEADSCALE_CLIENT_HOSTNAME" ]]; then
    args+=(--hostname "$HEADSCALE_CLIENT_HOSTNAME")
  fi
  if [[ -n "$HEADSCALE_ADVERTISE_ROUTES" ]]; then
    args+=(--advertise-routes "$HEADSCALE_ADVERTISE_ROUTES")
  fi
  if [[ "$HEADSCALE_ADVERTISE_EXIT_NODE" == "1" ]]; then
    args+=(--advertise-exit-node)
  fi
  if [[ "$HEADSCALE_ENABLE_TS_SSH" == "1" ]]; then
    args+=(--ssh)
  fi
  if [[ "$HEADSCALE_RESET" == "1" ]]; then
    args+=(--reset)
  fi

  while IFS= read -r extra; do
    if [[ -n "$extra" ]]; then
      args+=("$extra")
    fi
  done < <(split_words "$HEADSCALE_EXTRA_UP_ARGS")

  stop_stale_tailscale_up
  check_headscale_endpoint
  log "执行 tailscale up。"
  timeout "$HEADSCALE_CLIENT_UP_TIMEOUT_SEC" tailscale "${args[@]}" || exit_code=$?
  if [[ "$exit_code" == "124" || "$exit_code" == "143" ]]; then
    die "tailscale up 超时；请检查 HEADSCALE_AUTHKEY 是否过期、已使用，或 Headscale 入口是否可达。"
  fi
  [[ "$exit_code" == "0" ]] || exit "$exit_code"
}

verify_tailnet_ready() {
  local ip4

  tailscale status --self >/dev/null 2>&1 || die "tailscale 状态未就绪。"
  ip4="$(tailscale_ipv4 || true)"
  [[ -n "$ip4" ]] || die "未获取到 Headscale IPv4 地址。"
  ip link show "$HOLLOW_NET_IFACE" >/dev/null 2>&1 || die "未找到网卡 $HOLLOW_NET_IFACE。"
}

verify_reboot_persistence() {
  systemctl is-enabled --quiet tailscaled || die "tailscaled.service 未设置开机自启，主机重启后不会自动接入。"
  systemctl is-active --quiet tailscaled || die "tailscaled.service 未运行。"
  [[ -s /var/lib/tailscale/tailscaled.state ]] || die "缺少 /var/lib/tailscale/tailscaled.state，主机重启后无法保持登录状态。"
}

persist_tailnet_state() {
  local ip4

  ip4="$(tailscale_ipv4 || true)"
  [[ -n "$ip4" ]] || return 0
  persist_env_value HEADSCALE_CLIENT_IP "$ip4"
  persist_env_value K3S_NODE_IP "$ip4"
}

print_summary() {
  printf '\nHeadscale 接入完成。\n'
  printf '  login-server：%s\n' "$HEADSCALE_SERVER_URL"
  printf '  hostname：%s\n' "${HEADSCALE_CLIENT_HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown')}"
  printf '  网卡：%s\n' "$HOLLOW_NET_IFACE"
  tailscale status --self 2>/dev/null || true
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
  recover_previous_run
  resolve_server_url
  apply_defaults
  validate_input
  begin_run
  persist_env_file
  persist_client_config
  install_tailscale
  configure_tun_module
  configure_tailscaled_interface
  start_tailscaled
  run_tailscale_up
  verify_tailnet_ready
  verify_reboot_persistence
  configure_hollow_net_ufw
  persist_tailnet_state
  print_summary
  finish_run
}

main "$@"
