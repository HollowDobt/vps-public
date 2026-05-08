#!/usr/bin/env bash
# VPS 脚本共享函数。
#
# 这里放各脚本共同使用的环境文件加载、原子写入、软件包安装、
# systemd 配置和备份定时器配置。业务动作仍放在各自脚本里。

VPS_COMMON_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")/.." && pwd)"
fi

ENV_SOURCE=''
ENV_SOURCES=()
TEMP_FILES=()
RUN_MARKER=''
DONE_MARKER=''

log_location() {
  hostname 2>/dev/null || printf 'unknown'
}

log() {
  printf '[%s] INFO：%s 在 %s 执行：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*"
}

warn() {
  printf '[%s] WARN：%s 在 %s 执行时提示：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*" >&2
}

die() {
  printf '[%s] ERROR：%s 在 %s 执行脚本时发生错误：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "请使用 root 或 sudo 运行。"
}

validate_bool() {
  local name="$1"
  local value="$2"

  case "$value" in
    0 | 1) ;;
    *) die "${name} 只能是 0 或 1。" ;;
  esac
}

setup_state_dir() {
  install -d -o root -g root -m 0755 "$STATE_DIR"
  install -d -o root -g root -m 0700 "${STATE_DIR}/tmp"
  RUN_MARKER="${STATE_DIR}/run.in-progress"
  DONE_MARKER="${STATE_DIR}/done.env"
}

track_tempfile() {
  TEMP_FILES+=("$1")
}

mktemp_managed() {
  local temp_file

  temp_file="$(mktemp "${STATE_DIR}/tmp/${SCRIPT_NAME}.XXXXXX")"
  track_tempfile "$temp_file"
  printf '%s\n' "$temp_file"
}

cleanup_tempfiles() {
  local temp_file

  for temp_file in "${TEMP_FILES[@]}"; do
    [[ -e "$temp_file" ]] && rm -rf -- "$temp_file"
  done

  return 0
}

recover_previous_run() {
  if [[ -d "${STATE_DIR}/tmp" ]]; then
    find "${STATE_DIR}/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  fi

  if [[ -f "$RUN_MARKER" ]]; then
    warn "检测到上次运行未完成，已清理本脚本临时文件。本次将重新执行可重复步骤。"
  fi
}

begin_run() {
  install -d -o root -g root -m 0755 "$STATE_DIR"
  {
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'script=%s\n' "$SCRIPT_NAME"
    printf 'pid=%s\n' "$$"
  } >"$RUN_MARKER"
  chmod 0644 "$RUN_MARKER"
}

finish_run() {
  {
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'script=%s\n' "$SCRIPT_NAME"
  } >"$DONE_MARKER"
  chmod 0644 "$DONE_MARKER"
  rm -f -- "$RUN_MARKER"
}

on_interrupt() {
  warn "收到中断信号，已停止。重新执行脚本会继续处理未完成步骤。"
  exit 130
}

on_error() {
  local exit_code=$?
  local line_no="${1:-未知}"
  local failed_command="${2:-未知命令}"

  [[ "$exit_code" -eq 0 ]] && return 0
  warn "第 ${line_no} 行执行命令失败：${failed_command}；请查看上方命令输出。"
  exit "$exit_code"
}

install_traps() {
  trap cleanup_tempfiles EXIT
  trap on_interrupt INT TERM
  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
}

load_env() {
  local candidate
  local candidates=()
  local loaded=0
  local sources_text

  if [[ -n "${VPS_ENV_FILE:-}" ]]; then
    candidates+=("$VPS_ENV_FILE")
  else
    candidates+=("/etc/hlwdot/vps.env" "${SCRIPT_DIR}/.env")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -r "$candidate" ]]; then
      if [[ -z "${VPS_ENV_FILE:-}" && "$candidate" == "${SCRIPT_DIR}/.env" && -r /etc/hlwdot/vps.env ]]; then
        local filtered_env

        filtered_env="$(mktemp_managed)"
        awk '
          /^[[:space:]]*#/ { print; next }
          /^[[:space:]]*$/ { print; next }
          /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*$/ { next }
          { print }
        ' "$candidate" >"$filtered_env"
        set -a
        # shellcheck disable=SC1090
        . "$filtered_env"
        set +a
      else
        set -a
        # shellcheck disable=SC1090
        . "$candidate"
        set +a
      fi
      ENV_SOURCE="$candidate"
      ENV_SOURCES+=("$candidate")
      loaded=1
    fi
  done

  if [[ "$loaded" == "1" ]]; then
    sources_text="$(IFS=', '; printf '%s' "${ENV_SOURCES[*]}")"
    log "读取配置：$sources_text"
  fi

  return 0
}

persist_env_file() {
  [[ "${VPS_PERSIST_ENV:-1}" == "1" ]] || return 0
  [[ -e /etc/hlwdot/vps.env ]] && return 0
  [[ -n "$ENV_SOURCE" && -r "$ENV_SOURCE" ]] || return 0
  [[ "$ENV_SOURCE" != "/etc/hlwdot/vps.env" ]] || return 0

  install -d -o root -g root -m 0700 /etc/hlwdot
  install -o root -g root -m 0600 "$ENV_SOURCE" /etc/hlwdot/vps.env
  log "写入系统配置副本：/etc/hlwdot/vps.env"
}

shell_quote() {
  local value="$1"

  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

ensure_system_env_file() {
  install -d -o root -g root -m 0700 /etc/hlwdot
  if [[ ! -e /etc/hlwdot/vps.env ]]; then
    if [[ -n "$ENV_SOURCE" && -r "$ENV_SOURCE" ]]; then
      install -o root -g root -m 0600 "$ENV_SOURCE" /etc/hlwdot/vps.env
    else
      install -o root -g root -m 0600 /dev/null /etc/hlwdot/vps.env
    fi
  else
    chmod 0600 /etc/hlwdot/vps.env
  fi
}

persist_env_value_to_file() {
  local target="$1"
  local key="$2"
  local value="$3"
  local temp_file

  temp_file="$(mktemp_managed)"
  awk -v key="$key" '$0 !~ "^[[:space:]]*" key "=" { print }' "$target" >"$temp_file"
  printf '%s=%s\n' "$key" "$(shell_quote "$value")" >>"$temp_file"
  atomic_install_file "$temp_file" "$target" 0600 root root
}

persist_env_value() {
  local key="$1"
  local value="$2"
  local target="/etc/hlwdot/vps.env"
  local local_env="${SCRIPT_DIR}/.env"

  [[ -n "$key" ]] || return 0
  ensure_system_env_file
  persist_env_value_to_file "$target" "$key" "$value"
  if [[ -n "${VPS_ENV_FILE:-}" && "$VPS_ENV_FILE" != "$target" && -e "$VPS_ENV_FILE" ]]; then
    persist_env_value_to_file "$VPS_ENV_FILE" "$key" "$value"
  elif [[ -e "$local_env" && "$local_env" != "$target" ]]; then
    persist_env_value_to_file "$local_env" "$key" "$value"
  fi
  printf -v "$key" '%s' "$value"
  export "$key"
  log "更新系统配置：$key"
}

atomic_install_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local owner="${4:-root}"
  local group="${5:-root}"
  local target_dir
  local temp_target

  target_dir="$(dirname "$target_file")"
  install -d -o "$owner" -g "$group" -m 0755 "$target_dir"
  temp_target="$(mktemp "${target_dir}/.${SCRIPT_NAME}.XXXXXX")"
  track_tempfile "$temp_target"
  install -o "$owner" -g "$group" -m "$mode" "$source_file" "$temp_target"
  mv -f -- "$temp_target" "$target_file"
}

apt_install() {
  local packages=("$@")

  log "安装依赖软件包：${packages[*]}"
  apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update
  apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=3 \
    -o DPkg::Lock::Timeout=120 \
    install "${packages[@]}"
}

download_file() {
  local url="$1"
  local output="$2"

  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$output"
  elif command_exists wget; then
    wget -q --tries=3 --timeout=15 -O "$output" "$url"
  else
    die "缺少 curl 或 wget，无法下载：$url"
  fi
}

url_host() {
  local value="$1"

  value="${value#*://}"
  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s\n' "$value"
}

tailscale_ipv4() {
  tailscale ip -4 2>/dev/null | awk 'NF { print; exit }'
}

require_tailnet_ready() {
  local iface="${HOLLOW_NET_IFACE:-hollow-net}"
  local ip4

  command_exists tailscale || die "缺少 tailscale，请先执行 Headscale 接入脚本。"
  tailscale status --self >/dev/null 2>&1 || die "当前节点尚未接入 Headscale 网络，请先执行 Headscale 接入脚本。"

  if command_exists ip; then
    ip link show "$iface" >/dev/null 2>&1 || die "未找到网卡 $iface，请检查 HOLLOW_NET_IFACE 和 tailscaled 配置。"
  fi

  ip4="$(tailscale_ipv4)"
  [[ -n "$ip4" ]] || die "无法读取当前节点的 Headscale IPv4 地址。"
  printf '%s\n' "$ip4"
}

current_public_ipv4() {
  local ip4

  ip4="$(curl -fsSL --retry 3 --connect-timeout 10 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip4" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "无法自动获取公网 IPv4。"
  printf '%s\n' "$ip4"
}

cloudflare_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="https://api.cloudflare.com/client/v4${path}"
  local auth_headers=()

  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    auth_headers+=(--header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
  elif [[ -n "${CLOUDFLARE_API_KEY:-}" && -n "${CLOUDFLARE_EMAIL:-}" ]]; then
    auth_headers+=(--header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}")
  else
    die "请设置 CLOUDFLARE_API_TOKEN，或同时设置 CLOUDFLARE_EMAIL 与 CLOUDFLARE_API_KEY。"
  fi

  if [[ -n "$body" ]]; then
    curl -fsSL --request "$method" "$url" \
      "${auth_headers[@]}" \
      --header 'Content-Type: application/json' \
      --data "$body"
  else
    curl -fsSL --request "$method" "$url" \
      "${auth_headers[@]}" \
      --header 'Content-Type: application/json'
  fi
}

cloudflare_zone_id_for_name() {
  local name="$1"
  local candidate="${name%.}"
  local response
  local zone_id

  if [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi

  if [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
    candidate="$CLOUDFLARE_ZONE"
  fi

  while [[ "$candidate" == *.* ]]; do
    response="$(cloudflare_request GET "/zones?name=${candidate}")"
    zone_id="$(jq -r '.result[0].id // empty' <<<"$response")"
    if [[ -n "$zone_id" ]]; then
      printf '%s\n' "$zone_id"
      return 0
    fi
    candidate="${candidate#*.}"
  done

  die "无法从 Cloudflare 找到对应 zone：$name"
}

cloudflare_upsert_record() {
  local name="$1"
  local type="$2"
  local content="$3"
  local proxied="${4:-0}"
  local ttl="${5:-120}"
  local zone_id
  local response
  local record_id
  local body
  local proxied_json=false
  local proxy_label='关闭'

  if [[ "$proxied" == "1" ]]; then
    proxied_json=true
    proxy_label='开启'
  fi
  zone_id="$(cloudflare_zone_id_for_name "$name")"
  response="$(cloudflare_request GET "/zones/${zone_id}/dns_records?type=${type}&name=${name}")"
  record_id="$(jq -r '.result[0].id // empty' <<<"$response")"
  body="$(jq -nc \
    --arg type "$type" \
    --arg name "$name" \
    --arg content "$content" \
    --argjson ttl "$ttl" \
    --argjson proxied "$proxied_json" \
    '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"

  if [[ -n "$record_id" ]]; then
    cloudflare_request PUT "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null
  else
    cloudflare_request POST "/zones/${zone_id}/dns_records" "$body" >/dev/null
  fi
  log "Cloudflare DNS：${type} ${name} -> ${content}，Cloudflare 代理：${proxy_label}"
}

cloudflare_configured() {
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" || ( -n "${CLOUDFLARE_API_KEY:-}" && -n "${CLOUDFLARE_EMAIL:-}" ) ]]
}

configure_hollow_net_ufw() {
  local iface="${HOLLOW_NET_IFACE:-hollow-net}"

  [[ "${HOLLOW_NET_UFW_ALLOW:-1}" == "1" ]] || return 0
  command_exists ufw || return 0

  log "放行 ${iface} 网卡入站流量。"
  ufw allow in on "$iface" to any comment 'hollow-net'
}

ufw_allow_in_on_iface() {
  local iface="$1"
  local port="$2"
  local proto="$3"
  local comment="$4"

  if [[ -n "$iface" ]]; then
    ufw allow in on "$iface" to any port "$port" proto "$proto" comment "$comment"
  else
    ufw allow "${port}/${proto}" comment "$comment"
  fi
}

configure_k3s_ufw_rules() {
  local role="$1"
  local iface="${K3S_UFW_INTERFACE:-${HOLLOW_NET_IFACE:-hollow-net}}"
  local api_port="${K3S_API_PORT:-6443}"
  local cluster_cidr="${K3S_CLUSTER_CIDR:-10.42.0.0/16}"
  local service_cidr="${K3S_SERVICE_CIDR:-10.43.0.0/16}"

  [[ "${K3S_UFW_ALLOW:-1}" == "1" ]] || return 0
  command_exists ufw || return 0

  log "配置 k3s 防火墙规则：${iface}"
  if [[ "$role" == "server" ]]; then
    ufw_allow_in_on_iface "$iface" "$api_port" tcp 'k3s api'
    if [[ "${K3S_UFW_ALLOW_ETCD:-0}" == "1" ]]; then
      ufw_allow_in_on_iface "$iface" '2379:2380' tcp 'k3s etcd'
    fi
  fi

  ufw_allow_in_on_iface "$iface" 8472 udp 'k3s flannel vxlan'
  ufw_allow_in_on_iface "$iface" 10250 tcp 'k3s kubelet'
  ufw allow from "$cluster_cidr" to any comment 'k3s pods'
  ufw allow from "$service_cidr" to any comment 'k3s services'
  ufw route allow from "$cluster_cidr" to any comment 'k3s pod routes'
  ufw route allow from "$service_cidr" to any comment 'k3s service routes'
}

configure_k3s_tailnet_boot_guard() {
  local service_name="$1"
  local iface="${K3S_FLANNEL_IFACE:-${HOLLOW_NET_IFACE:-hollow-net}}"
  local wait_seconds="${K3S_TAILNET_BOOT_WAIT_SEC:-120}"
  local dropin_dir="/etc/systemd/system/${service_name}.service.d"
  local dropin_file="${dropin_dir}/10-hlwdot-tailnet.conf"
  local temp_file
  local wait_script

  case "$service_name" in
    k3s | k3s-agent) ;;
    *) die "不支持的 k3s systemd 服务：$service_name" ;;
  esac
  [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]] || die "k3s 网卡名称包含非法字符：$iface"
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "K3S_TAILNET_BOOT_WAIT_SEC 必须是数字。"

  printf -v wait_script \
    'elapsed=0; while [ "$elapsed" -lt %s ]; do /usr/sbin/ip link show %s >/dev/null 2>&1 && /usr/sbin/ip -4 addr show dev %s | /usr/bin/grep -q "inet " && exit 0; elapsed=$((elapsed + 2)); /bin/sleep 2; done; echo "等待 %s 网卡 IPv4 超时" >&2; exit 1' \
    "$wait_seconds" "$(shell_quote "$iface")" "$(shell_quote "$iface")" "$iface"

  temp_file="$(mktemp_managed)"
  {
    printf '[Unit]\n'
    printf '# k3s 使用 hollow-net 承载集群流量，开机时先等 tailscaled 建好网卡。\n'
    printf 'Wants=network-online.target tailscaled.service\n'
    printf 'After=network-online.target tailscaled.service\n'
    printf 'StartLimitIntervalSec=0\n\n'
    printf '[Service]\n'
    printf 'ExecStartPre=/bin/sh -c %s\n' "$(shell_quote "$wait_script")"
    printf 'Restart=always\n'
    printf 'RestartSec=5s\n'
  } >"$temp_file"

  atomic_install_file "$temp_file" "$dropin_file" 0644 root root
  systemd_reload
  log "配置 k3s 开机等待网卡：${service_name}.service -> ${iface}"
}

systemd_reload() {
  systemctl daemon-reload
}

enable_timer() {
  local timer="$1"

  systemd_reload
  systemctl enable --now "$timer"
}

split_words() {
  local value="$1"
  local old_ifs
  local item

  old_ifs="$IFS"
  IFS=$' ,\n\t'
  for item in $value; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
  IFS="$old_ifs"
}

yaml_quote() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_yaml_list() {
  local indent="$1"
  local raw="$2"
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    printf '%s- ' "$indent"
    yaml_quote "$item"
    printf '\n'
  done < <(split_words "$raw")
}

backup_destinations_configured() {
  [[ -n "${BACKUP_RCLONE_DESTS:-}" || -n "${BACKUP_GIT_REPOS:-}" ]]
}

validate_backup_config() {
  validate_bool BACKUP_ENABLE "${BACKUP_ENABLE:-0}"
  [[ "${BACKUP_ENABLE:-0}" == "1" ]] || return 0
  [[ -n "${BACKUP_GPG_RECIPIENTS:-}" || -n "${BACKUP_GPG_EMAILS:-}" ]] || die "BACKUP_ENABLE=1 时必须设置 BACKUP_GPG_RECIPIENTS 或 BACKUP_GPG_EMAILS。"
  backup_destinations_configured || die "BACKUP_ENABLE=1 时必须设置 BACKUP_RCLONE_DESTS 或 BACKUP_GIT_REPOS。"
}

install_backup_timer() {
  local profile="$1"
  local service_file="/etc/systemd/system/hlwdot-${profile}-backup.service"
  local timer_file="/etc/systemd/system/hlwdot-${profile}-backup.timer"
  local temp_service
  local temp_timer

  validate_backup_config
  [[ "${BACKUP_ENABLE:-0}" == "1" ]] || {
    log "备份未启用：BACKUP_ENABLE=0"
    return 0
  }

  [[ -r "${SCRIPT_DIR}/vps-backup.sh" ]] || die "找不到备份脚本：${SCRIPT_DIR}/vps-backup.sh"
  [[ -r "${SCRIPT_DIR}/lib/vps-common.sh" ]] || die "找不到共享函数：${SCRIPT_DIR}/lib/vps-common.sh"

  apt_install gnupg tar gzip coreutils git rclone
  persist_env_file
  install -d -o root -g root -m 0755 /usr/local/lib/hlwdot
  install -o root -g root -m 0644 "${SCRIPT_DIR}/lib/vps-common.sh" /usr/local/lib/hlwdot/vps-common.sh
  install -o root -g root -m 0750 "${SCRIPT_DIR}/vps-backup.sh" /usr/local/sbin/hlwdot-vps-backup

  temp_service="$(mktemp_managed)"
  temp_timer="$(mktemp_managed)"
  {
    printf '[Unit]\n'
    printf 'Description=HlwDot %s backup\n\n' "$profile"
    printf '[Service]\n'
    printf 'Type=oneshot\n'
    printf 'Environment=VPS_ENV_FILE=/etc/hlwdot/vps.env\n'
    printf 'ExecStart=/usr/local/sbin/hlwdot-vps-backup %s\n' "$profile"
  } >"$temp_service"
  {
    printf '[Unit]\n'
    printf 'Description=Run HlwDot %s backup\n\n' "$profile"
    printf '[Timer]\n'
    printf 'OnCalendar=%s\n' "${BACKUP_ON_CALENDAR:-*-*-* 03:30:00}"
    printf 'RandomizedDelaySec=%s\n' "${BACKUP_RANDOMIZED_DELAY_SEC:-15m}"
    printf 'Persistent=true\n\n'
    printf '[Install]\n'
    printf 'WantedBy=timers.target\n'
  } >"$temp_timer"

  atomic_install_file "$temp_service" "$service_file" 0644 root root
  atomic_install_file "$temp_timer" "$timer_file" 0644 root root
  enable_timer "hlwdot-${profile}-backup.timer"
  log "配置备份定时器：hlwdot-${profile}-backup.timer"
}
