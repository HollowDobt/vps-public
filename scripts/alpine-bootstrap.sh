#!/bin/sh
# Alpine VPS 初装后的首次基础配置脚本。
#
# Alpine/OpenRC 环境的基础初始化：BOOTSTRAP_USER 登录、SSH 公钥、安全防护、
# 自动 apk 更新、BBR、LXC 宿主机时间/swap 管理，以及中断后的可重复执行恢复。
#
# 运行方式：
#   sudo sh scripts/alpine-bootstrap.sh
#
# 运行前配置：
#   - 脚本会读取 VPS_ENV_FILE 指定文件；未指定时读取 /etc/hlwdot/vps.env 和同目录 .env。
#   - SSH 登录公钥来源必须有其一：
#       BOOTSTRAP_AUTHORIZED_KEYS='ssh-ed25519 AAAA...'
#       BOOTSTRAP_AUTHORIZED_KEYS_SOURCE 指向的文件中已有公钥，默认 /root/.ssh/authorized_keys
#       root、BOOTSTRAP_USER、SUDO_USER 或现有 UID>=1000 用户已有 authorized_keys
#   - 必须填写 VPS_NODE_NAME。
#   - 需要修改 SSH 端口时填写 BOOTSTRAP_SSH_PORT。
#   - BOOTSTRAP_SSH_LOCKDOWN=auto 时，有可用公钥才禁用密码登录；1 强制禁用，0 保留。
#   - BOOTSTRAP_SUDO_NOPASSWD=auto 时，有可用公钥才启用免密 sudo；1/0 为强制开关。
#   - BOOTSTRAP_ENABLE_UFW=1 在 Alpine 下启用受管 iptables 防火墙。
#   - HOLLOW_NET_IFACE 为 hollow-net 网卡名，防火墙默认放行该网卡入站。
#   - BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES=1 写入 daily apk upgrade 并启用 crond。
#   - ALPINE_LXC_MODE=1 时按 LXC 容器执行：swap 由宿主机/cgroup 管理，
#     脚本不在容器内创建 swapfile/zram。默认值为 1。
#   - ALPINE_LXC_MODE=1 时系统时钟由宿主机管理，脚本不安装或启动 chronyd。
#   - ALPINE_LXC_MODE=0 时按 Alpine VM/裸机执行：
#     BOOTSTRAP_SWAP_SIZE=auto 在 swapfile 所在文件系统可用空间小于或等于 1GB 时创建 128MB；
#     否则 MemTotal 小于或等于 2GB 创建约等于 MemTotal 的 swapfile，MemTotal 大于 2GB 创建 4GB。
#   - 非 LXC 环境里 swapfile 因底层文件系统含洞或不支持而无法启用时，脚本改用 Alpine zram-init swap。
#   - ALPINE_ENABLE_COMMUNITY_REPO=1 时启用 community 仓库；
#     ALPINE_COMMUNITY_REPO_URL=auto 时按 main 仓库推导，推导失败时使用官方 CDN。

set -eu
umask 027

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
STATE_DIR="/var/lib/hlwdot/alpine-bootstrap"
TMP_DIR="${STATE_DIR}/tmp"
DONE_MARKER="${STATE_DIR}/done.env"
INTERRUPT_MARKER="${STATE_DIR}/interrupted"
SWAP_IN_PROGRESS="${STATE_DIR}/swap-create.in-progress"
SSHD_CHANGE_IN_PROGRESS="${STATE_DIR}/sshd-change.in-progress"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-hlwdot-bootstrap.conf"
SSHD_DROPIN_BACKUP="${STATE_DIR}/sshd-dropin.previous"
SSHD_DROPIN_HAD_BACKUP="${STATE_DIR}/sshd-dropin.had-backup"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BACKUP="${STATE_DIR}/sshd-config.previous"
SSHD_CONFIG_HAD_BACKUP="${STATE_DIR}/sshd-config.had-backup"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/10-hlwdot-sshd.conf"
APK_AUTO_UPGRADE="/etc/periodic/daily/90-hlwdot-apk-upgrade"
LOCALE_PROFILE="/etc/profile.d/90-hlwdot-locale.sh"
FIREWALL_SCRIPT="/etc/local.d/hlwdot-firewall.start"
MODULES_BBR="/etc/modules-load.d/90-hlwdot-bbr.conf"
SYSCTL_BBR="/etc/sysctl.d/90-hlwdot-bbr.conf"
ZRAM_CONF="/etc/conf.d/zram-init"

load_bootstrap_env_file() {
  env_file="$1"

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  env_status=$?
  set +a
  return "$env_status"
}

load_bootstrap_env() {
  if [ -n "${VPS_ENV_FILE:-}" ]; then
    env_candidates=$VPS_ENV_FILE
  else
    env_candidates="/etc/hlwdot/vps.env
${SCRIPT_DIR}/.env"
  fi

  old_ifs=$IFS
  IFS='
'
  for env_candidate in $env_candidates; do
    [ -r "$env_candidate" ] || continue
    if [ -z "${VPS_ENV_FILE:-}" ] && [ "$env_candidate" = "${SCRIPT_DIR}/.env" ] && [ -r /etc/hlwdot/vps.env ]; then
      filtered_env=$(mktemp "/tmp/${SCRIPT_NAME}.env.XXXXXX")
      awk '
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*$/ { print; next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*$/ { next }
        { print }
      ' "$env_candidate" >"$filtered_env"
      load_bootstrap_env_file "$filtered_env"
      rm -f -- "$filtered_env"
    else
      load_bootstrap_env_file "$env_candidate"
    fi
  done
  IFS=$old_ifs
}

load_bootstrap_env

VPS_NODE_NAME="${VPS_NODE_NAME:-}"
BOOTSTRAP_USER="${BOOTSTRAP_USER:-hollow}"
BOOTSTRAP_HOSTNAME="$VPS_NODE_NAME"
BOOTSTRAP_TIMEZONE="${BOOTSTRAP_TIMEZONE:-Asia/Shanghai}"
BOOTSTRAP_LOCALE="${BOOTSTRAP_LOCALE:-en_US.UTF-8}"
BOOTSTRAP_EXTRA_LOCALES="${BOOTSTRAP_EXTRA_LOCALES:-zh_CN.UTF-8}"
BOOTSTRAP_SSH_PORT="${BOOTSTRAP_SSH_PORT:-22}"
BOOTSTRAP_SSH_LOCKDOWN="${BOOTSTRAP_SSH_LOCKDOWN:-auto}"
BOOTSTRAP_SUDO_NOPASSWD="${BOOTSTRAP_SUDO_NOPASSWD:-auto}"
BOOTSTRAP_ENABLE_UFW="${BOOTSTRAP_ENABLE_UFW:-1}"
BOOTSTRAP_ENABLE_FAIL2BAN="${BOOTSTRAP_ENABLE_FAIL2BAN:-1}"
BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES="${BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES:-1}"
BOOTSTRAP_FULL_UPGRADE="${BOOTSTRAP_FULL_UPGRADE:-1}"
BOOTSTRAP_ENABLE_BBR="${BOOTSTRAP_ENABLE_BBR:-1}"
BOOTSTRAP_AUTHORIZED_KEYS_SOURCE="${BOOTSTRAP_AUTHORIZED_KEYS_SOURCE:-/root/.ssh/authorized_keys}"
BOOTSTRAP_AUTHORIZED_KEYS="${BOOTSTRAP_AUTHORIZED_KEYS:-}"
BOOTSTRAP_USER_PASSWORD_HASH="${BOOTSTRAP_USER_PASSWORD_HASH:-}"
BOOTSTRAP_USER_PASSWORD="${BOOTSTRAP_USER_PASSWORD:-}"
HOLLOW_NET_IFACE="${HOLLOW_NET_IFACE:-hollow-net}"
BOOTSTRAP_ENABLE_SWAP="${BOOTSTRAP_ENABLE_SWAP:-1}"
BOOTSTRAP_SWAPFILE="${BOOTSTRAP_SWAPFILE:-/swapfile}"
BOOTSTRAP_SWAP_SIZE="${BOOTSTRAP_SWAP_SIZE:-auto}"
ALPINE_LXC_MODE="${ALPINE_LXC_MODE:-1}"
ALPINE_ENABLE_COMMUNITY_REPO="${ALPINE_ENABLE_COMMUNITY_REPO:-1}"
ALPINE_COMMUNITY_REPO_URL="${ALPINE_COMMUNITY_REPO_URL:-auto}"

AUTHORIZED_KEYS_INSTALLED=0
SSH_LOCKDOWN_ACTIVE=0
BBR_CONFIGURED=0
BBR_STATUS=not-run
BBR_DETAIL=''
SWAP_SIZE_MB=0
SWAP_BACKEND=none
SWAP_ACTIVE_TARGET=''
TEMP_FILES=''

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

is_lxc_container() {
  case "$ALPINE_LXC_MODE" in
    1) return 0 ;;
    0) return 1 ;;
  esac

  if [ -r /proc/1/environ ] && tr '\000' '\n' </proc/1/environ 2>/dev/null | grep -Eq '^container=(lxc|lxc-libvirt)$'; then
    return 0
  fi
  if [ -r /proc/1/cgroup ] && grep -Eqa '(^|/)(lxc|lxc\.payload|machine.slice/.+\.scope)' /proc/1/cgroup; then
    return 0
  fi
  return 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

enabled_label() {
  if [ "$1" = 1 ]; then
    printf '启用'
  else
    printf '停用'
  fi
}

configured_label() {
  if [ "$1" = 1 ]; then
    printf '已配置'
  else
    printf '未配置'
  fi
}

ssh_password_login_label() {
  if [ "$SSH_LOCKDOWN_ACTIVE" = 1 ]; then
    printf '禁用'
  else
    printf '保留'
  fi
}

usage() {
  cat <<EOF
用法：
  sh $SCRIPT_NAME

可配置环境变量：
  VPS_NODE_NAME=server-new
  BOOTSTRAP_USER=hollow
  BOOTSTRAP_TIMEZONE=Asia/Shanghai
  BOOTSTRAP_LOCALE=en_US.UTF-8
  BOOTSTRAP_EXTRA_LOCALES=zh_CN.UTF-8
  BOOTSTRAP_SSH_PORT=22
  BOOTSTRAP_SSH_LOCKDOWN=auto          # auto、1、0
  BOOTSTRAP_SUDO_NOPASSWD=auto         # auto、1、0
  BOOTSTRAP_ENABLE_UFW=1               # Alpine 下对应受管 iptables 防火墙
  BOOTSTRAP_ENABLE_FAIL2BAN=1
  BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES=1
  BOOTSTRAP_FULL_UPGRADE=1
  BOOTSTRAP_ENABLE_BBR=1
  HOLLOW_NET_IFACE=hollow-net
  BOOTSTRAP_AUTHORIZED_KEYS_SOURCE=/root/.ssh/authorized_keys
  BOOTSTRAP_AUTHORIZED_KEYS='ssh-ed25519 AAAA...'
  BOOTSTRAP_USER_PASSWORD_HASH='...'
  BOOTSTRAP_ENABLE_SWAP=1
  BOOTSTRAP_SWAPFILE=/swapfile
  BOOTSTRAP_SWAP_SIZE=auto             # auto、0、1024M、2G
  ALPINE_LXC_MODE=1                    # 1、0、auto
  ALPINE_ENABLE_COMMUNITY_REPO=1
  ALPINE_COMMUNITY_REPO_URL=auto

说明：
  - 仅支持 Alpine Linux + OpenRC。
  - BOOTSTRAP_SSH_LOCKDOWN=auto 时，只有找到可用登录密钥并写入 root 与 BOOTSTRAP_USER 后才启用仅密钥登录。
  - BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES=1 会写入 daily periodic apk upgrade，并启用 crond。
  - BOOTSTRAP_ENABLE_UFW=1 会放行 SSH 端口和 HOLLOW_NET_IFACE 网卡，其余入站默认拒绝。
  - ALPINE_LXC_MODE=1 时不在容器内配置 swapfile/zram；swap 由宿主机/cgroup 管理。
  - ALPINE_LXC_MODE=1 时不安装或启动 chronyd；系统时钟由宿主机管理。
  - ALPINE_LXC_MODE=0 时才在 Alpine VM/裸机内配置 swapfile；auto 在磁盘可用空间小于或等于 1GB 时使用 128M，否则按 MemTotal 选择自身内存大小或 4G。
  - fstab 不设置 pri，使用系统默认 swap 优先级。
EOF
}

require_root() {
  [ "$(id -u)" = 0 ] || die "请使用 root 运行。"
}

validate_bool() {
  name="$1"
  value="$2"
  case "$value" in
    0|1) ;;
    *) die "$name 只能是 0 或 1。" ;;
  esac
}

validate_auto_bool() {
  name="$1"
  value="$2"
  case "$value" in
    auto|0|1) ;;
    *) die "$name 只能是 auto、0 或 1。" ;;
  esac
}

validate_input() {
  [ -n "$VPS_NODE_NAME" ] || die "必须设置 VPS_NODE_NAME。"
  printf '%s\n' "$VPS_NODE_NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$' || die "VPS_NODE_NAME 格式不合法。"
  case "$VPS_NODE_NAME" in
    *..*) die "VPS_NODE_NAME 不能包含连续的点。" ;;
  esac
  BOOTSTRAP_HOSTNAME="$VPS_NODE_NAME"

  case "$BOOTSTRAP_USER" in
    ''|*[!a-z_0-9-]*|-*) die "BOOTSTRAP_USER 必须是简单的小写 Linux 用户名。" ;;
  esac

  is_uint "$BOOTSTRAP_SSH_PORT" || die "BOOTSTRAP_SSH_PORT 必须是数字。"
  [ "$BOOTSTRAP_SSH_PORT" -ge 1 ] && [ "$BOOTSTRAP_SSH_PORT" -le 65535 ] || die "BOOTSTRAP_SSH_PORT 必须在 1 到 65535 之间。"

  if [ -n "$BOOTSTRAP_HOSTNAME" ]; then
    printf '%s\n' "$BOOTSTRAP_HOSTNAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$' || die "BOOTSTRAP_HOSTNAME 格式不合法。"
    case "$BOOTSTRAP_HOSTNAME" in
      *..*) die "BOOTSTRAP_HOSTNAME 不能包含连续的点。" ;;
    esac
  fi

  case "$BOOTSTRAP_TIMEZONE" in
    /*|*..*) die "BOOTSTRAP_TIMEZONE 不能是绝对路径或包含 ..。" ;;
  esac
  printf '%s\n' "$BOOTSTRAP_TIMEZONE" | grep -Eq '^[A-Za-z0-9_+./-]+$' || die "BOOTSTRAP_TIMEZONE 包含非法字符。"

  case "$BOOTSTRAP_SWAPFILE" in
    /*) ;;
    *) die "BOOTSTRAP_SWAPFILE 必须是绝对路径。" ;;
  esac
  [ "$BOOTSTRAP_SWAPFILE" != / ] || die "BOOTSTRAP_SWAPFILE 不能是根目录。"
  if printf '%s' "$BOOTSTRAP_SWAPFILE" | grep -q '[[:space:]]'; then
    die "BOOTSTRAP_SWAPFILE 不能包含空白字符。"
  fi

  validate_auto_bool BOOTSTRAP_SSH_LOCKDOWN "$BOOTSTRAP_SSH_LOCKDOWN"
  validate_auto_bool BOOTSTRAP_SUDO_NOPASSWD "$BOOTSTRAP_SUDO_NOPASSWD"
  validate_bool BOOTSTRAP_ENABLE_UFW "$BOOTSTRAP_ENABLE_UFW"
  validate_bool BOOTSTRAP_ENABLE_FAIL2BAN "$BOOTSTRAP_ENABLE_FAIL2BAN"
  validate_bool BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES "$BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES"
  validate_bool BOOTSTRAP_FULL_UPGRADE "$BOOTSTRAP_FULL_UPGRADE"
  validate_bool BOOTSTRAP_ENABLE_BBR "$BOOTSTRAP_ENABLE_BBR"
  validate_bool BOOTSTRAP_ENABLE_SWAP "$BOOTSTRAP_ENABLE_SWAP"
  validate_auto_bool ALPINE_LXC_MODE "$ALPINE_LXC_MODE"
  validate_bool ALPINE_ENABLE_COMMUNITY_REPO "$ALPINE_ENABLE_COMMUNITY_REPO"

  case "$HOLLOW_NET_IFACE" in
    ''|*[!A-Za-z0-9_.:-]*) die "HOLLOW_NET_IFACE 只能包含字母、数字、下划线、点、冒号和连字符。" ;;
  esac
  [ "${#HOLLOW_NET_IFACE}" -le 15 ] || die "HOLLOW_NET_IFACE 长度不能超过 15 个字符。"
}

require_alpine_openrc() {
  [ -r /etc/alpine-release ] || die "当前系统不是 Alpine Linux。"
  command_exists apk || die "缺少 apk。"
  command_exists rc-service || die "缺少 OpenRC rc-service。"
  command_exists rc-update || die "缺少 OpenRC rc-update。"
}

setup_state_dir() {
  mkdir -p "$TMP_DIR"
  chmod 0755 "$STATE_DIR"
  chmod 0700 "$TMP_DIR"
}

track_tempfile() {
  TEMP_FILES="${TEMP_FILES}
$1"
}

mktemp_managed() {
  temp_file=$(mktemp "${TMP_DIR}/${SCRIPT_NAME}.XXXXXX")
  track_tempfile "$temp_file"
  printf '%s\n' "$temp_file"
}

cleanup_tempfiles() {
  old_ifs=$IFS
  IFS='
'
  for temp_file in $TEMP_FILES; do
    [ -n "$temp_file" ] && [ -e "$temp_file" ] && rm -f -- "$temp_file"
  done
  IFS=$old_ifs
}

on_interrupt() {
  warn "收到中断信号，已停止。再次运行脚本会先做恢复检查。"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  date -u +%Y-%m-%dT%H:%M:%SZ >"$INTERRUPT_MARKER" 2>/dev/null || true
  exit 130
}

on_error() {
  warn "脚本收到 HUP 信号或命令执行失败；请查看上方命令输出。"
  exit 1
}

trap cleanup_tempfiles EXIT
trap on_interrupt INT TERM
trap on_error HUP

atomic_install_file() {
  source_file="$1"
  target_file="$2"
  mode="$3"
  owner="$4"
  group="$5"
  target_dir=$(dirname "$target_file")

  mkdir -p "$target_dir"
  temp_target=$(mktemp "${target_dir}/.${SCRIPT_NAME}.XXXXXX")
  track_tempfile "$temp_target"
  cp "$source_file" "$temp_target"
  chown "$owner:$group" "$temp_target"
  chmod "$mode" "$temp_target"
  mv -f -- "$temp_target" "$target_file"
}

is_swap_active() {
  swap_path="$1"
  [ -r /proc/swaps ] || return 1
  awk -v path="$swap_path" 'NR > 1 && $1 == path { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps
}

safe_remove_managed_swapfile() {
  swap_path="$1"
  [ -n "$swap_path" ] || return 1
  case "$swap_path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ "$swap_path" != / ] || return 1
  if [ -e "$swap_path" ] && ! is_swap_active "$swap_path"; then
    rm -f -- "$swap_path"
    log "删除未完成的 swapfile：$swap_path"
  fi
}

recover_swap_if_needed() {
  [ -f "$SWAP_IN_PROGRESS" ] || return 0
  swap_path=$(sed -n 's/^swapfile=//p' "$SWAP_IN_PROGRESS" | head -n 1)

  if [ -n "$swap_path" ] && is_swap_active "$swap_path"; then
    log "swapfile 已处于启用状态，移除未完成标记。"
  else
    safe_remove_managed_swapfile "$swap_path" || warn "未能清理上次未完成的 swapfile：${swap_path:-未知路径}"
  fi

  rm -f -- "$SWAP_IN_PROGRESS"
}

sshd_binary() {
  if command_exists sshd; then
    command -v sshd
  elif [ -x /usr/sbin/sshd ]; then
    printf '/usr/sbin/sshd\n'
  else
    return 1
  fi
}

test_sshd_config() {
  sshd=$(sshd_binary)
  mkdir -p /run/sshd
  ssh-keygen -A >/dev/null 2>&1 || true
  "$sshd" -t
}

rollback_sshd_config() {
  if [ -f "$SSHD_DROPIN_HAD_BACKUP" ] && [ -f "$SSHD_DROPIN_BACKUP" ]; then
    cp "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN"
    chmod 0644 "$SSHD_DROPIN"
    log "恢复 SSH drop-in 备份。"
  else
    rm -f -- "$SSHD_DROPIN"
    log "移除未完成写入的 SSH drop-in。"
  fi

  if [ -f "$SSHD_CONFIG_HAD_BACKUP" ] && [ -f "$SSHD_CONFIG_BACKUP" ]; then
    cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG"
    chmod 0644 "$SSHD_CONFIG"
    log "恢复 sshd_config 备份。"
  fi
}

recover_sshd_if_needed() {
  [ -f "$SSHD_CHANGE_IN_PROGRESS" ] || return 0

  if test_sshd_config; then
    log "SSH 配置校验通过，移除未完成标记。"
  else
    warn "检测到上次 SSH 配置未完成且当前 sshd 配置无效，开始回滚受管配置。"
    rollback_sshd_config
    test_sshd_config || die "回滚受管 SSH 配置后，sshd 配置仍然无效。"
  fi

  rm -f -- "$SSHD_CHANGE_IN_PROGRESS" "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP" "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG_HAD_BACKUP"
}

recover_previous_run() {
  if [ -d "$TMP_DIR" ]; then
    find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  fi
  if [ -f "$INTERRUPT_MARKER" ]; then
    log "检测到上次运行曾被中断，开始恢复检查。"
    rm -f -- "$INTERRUPT_MARKER"
  fi

  recover_swap_if_needed
  recover_sshd_if_needed
}

ensure_community_repo() {
  [ "$ALPINE_ENABLE_COMMUNITY_REPO" = 1 ] || return 0
  [ -r /etc/apk/repositories ] || return 0
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
  packages='bash bash-completion ca-certificates curl fail2ban file git gnupg htop iproute2 iptables jq kmod logrotate openssh openrc rsync shadow sudo tar tmux tzdata unzip vim wget zip'
  if ! is_lxc_container; then
    packages="$packages chrony"
  fi

  ensure_community_repo
  log "更新 apk 软件源索引。"
  apk update

  if [ "$BOOTSTRAP_FULL_UPGRADE" = 1 ]; then
    log "升级系统已有软件包。"
    apk upgrade
  fi

  log "安装基础工具和安全组件。"
  apk add $packages
  command_exists update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
}

configure_hostname() {
  [ -n "$BOOTSTRAP_HOSTNAME" ] || return 0

  log "设置主机名：$BOOTSTRAP_HOSTNAME"
  printf '%s\n' "$BOOTSTRAP_HOSTNAME" >/etc/hostname
  hostname "$BOOTSTRAP_HOSTNAME" || true

  temp_hosts=$(mktemp_managed)
  if [ -f /etc/hosts ]; then
    awk -v host="$BOOTSTRAP_HOSTNAME" '
      BEGIN { updated = 0 }
      /^[[:space:]]*#/ { print; next }
      /^127\.0\.1\.1[[:space:]]+/ {
        print "127.0.1.1\t" host
        updated = 1
        next
      }
      { print }
      END {
        if (!updated) print "127.0.1.1\t" host
      }
    ' /etc/hosts >"$temp_hosts"
  else
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$BOOTSTRAP_HOSTNAME" >"$temp_hosts"
  fi
  atomic_install_file "$temp_hosts" /etc/hosts 0644 root root
}

configure_timezone() {
  [ -e "/usr/share/zoneinfo/$BOOTSTRAP_TIMEZONE" ] || die "时区不存在：$BOOTSTRAP_TIMEZONE"

  log "设置时区：$BOOTSTRAP_TIMEZONE"
  ln -sfn "/usr/share/zoneinfo/$BOOTSTRAP_TIMEZONE" /etc/localtime
  printf '%s\n' "$BOOTSTRAP_TIMEZONE" >/etc/timezone
}

configure_locale() {
  temp_locale=$(mktemp_managed)
  temp_env=$(mktemp_managed)

  log "配置默认 locale 环境变量：$BOOTSTRAP_LOCALE"
  {
    printf '# 由 Alpine 基础配置脚本管理。\n'
    printf 'export LANG=%s\n' "$BOOTSTRAP_LOCALE"
  } >"$temp_locale"
  atomic_install_file "$temp_locale" "$LOCALE_PROFILE" 0644 root root

  if [ -f /etc/environment ]; then
    awk '$0 !~ /^LANG=/' /etc/environment >"$temp_env"
  else
    : >"$temp_env"
  fi
  printf 'LANG=%s\n' "$BOOTSTRAP_LOCALE" >>"$temp_env"
  atomic_install_file "$temp_env" /etc/environment 0644 root root
}

home_for_user() {
  user_name="$1"
  awk -F: -v user="$user_name" '$1 == user { print $6; exit }' /etc/passwd
}

ensure_user() {
  log "确保用户 $BOOTSTRAP_USER 存在并加入 wheel 组。"

  if id "$BOOTSTRAP_USER" >/dev/null 2>&1; then
    usermod -s /bin/bash "$BOOTSTRAP_USER" 2>/dev/null || true
  else
    adduser -D -s /bin/bash "$BOOTSTRAP_USER"
  fi
  addgroup "$BOOTSTRAP_USER" wheel >/dev/null 2>&1 || true

  if [ -n "$BOOTSTRAP_USER_PASSWORD_HASH" ]; then
    log "为 $BOOTSTRAP_USER 设置密码 hash。"
    usermod -p "$BOOTSTRAP_USER_PASSWORD_HASH" "$BOOTSTRAP_USER"
  elif [ -n "$BOOTSTRAP_USER_PASSWORD" ]; then
    log "为 $BOOTSTRAP_USER 设置临时密码。"
    printf '%s:%s\n' "$BOOTSTRAP_USER" "$BOOTSTRAP_USER_PASSWORD" | chpasswd
  fi
}

build_authorized_keys_material() {
  all_keys=$(mktemp_managed)
  cleaned_keys=$(mktemp_managed)

  # 普通用户密钥排在 root 前面，并跳过 forced-command 密钥，避免云镜像
  # root authorized_keys 中的提示命令被误当作可登录 shell 的密钥。
  [ -n "$BOOTSTRAP_AUTHORIZED_KEYS" ] && printf '%s\n' "$BOOTSTRAP_AUTHORIZED_KEYS" >>"$all_keys"

  {
    printf '%s\n' "$BOOTSTRAP_USER"
    [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ] && printf '%s\n' "$SUDO_USER"
    awk -F: '($3 >= 1000 && $3 < 60000 && $1 != "root") { print $1 }' /etc/passwd
  } | awk 'NF && !seen[$0]++' | while read -r user_name; do
    home_dir=$(home_for_user "$user_name" 2>/dev/null || true)
    [ -n "$home_dir" ] || continue
    authorized_keys="${home_dir}/.ssh/authorized_keys"
    [ -s "$authorized_keys" ] && cat "$authorized_keys" >>"$all_keys"
  done

  [ -s "$BOOTSTRAP_AUTHORIZED_KEYS_SOURCE" ] && cat "$BOOTSTRAP_AUTHORIZED_KEYS_SOURCE" >>"$all_keys"

  home_dir=$(home_for_user root 2>/dev/null || true)
  if [ -n "$home_dir" ]; then
    authorized_keys="${home_dir}/.ssh/authorized_keys"
    [ -s "$authorized_keys" ] && cat "$authorized_keys" >>"$all_keys"
  fi

  tr -d '\r' <"$all_keys" | awk '
    function is_key_type(value) {
      return value ~ /^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/
    }
    function has_forced_command() {
      return !is_key_type($1) && $1 ~ /(^|,)command=/
    }
    function key_id(    i, key_type) {
      for (i = 1; i <= NF; i++) {
        key_type = $i
        if (is_key_type(key_type) && i < NF) {
          return key_type " " $(i + 1)
        }
      }
      return $0
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    has_forced_command() { next }
    {
      id = key_id()
      if (!seen[id]++) { print }
    }
  ' >"$cleaned_keys"

  printf '%s\n' "$cleaned_keys"
}

install_authorized_keys_for_user() {
  user_name="$1"
  key_file="$2"
  home_dir=$(home_for_user "$user_name")
  group_name=$(id -gn "$user_name")
  ssh_dir="${home_dir}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  chown "$user_name:$group_name" "$ssh_dir"
  chmod 0700 "$ssh_dir"
  atomic_install_file "$key_file" "$authorized_keys" 0600 "$user_name" "$group_name"
  log "安装 $user_name 的 SSH authorized_keys。"
}

install_authorized_keys() {
  cleaned_keys=$(build_authorized_keys_material)

  if [ ! -s "$cleaned_keys" ]; then
    warn "未发现 SSH 登录密钥；不修改 SSH 登录认证方式。"
    return
  fi

  install_authorized_keys_for_user root "$cleaned_keys"
  install_authorized_keys_for_user "$BOOTSTRAP_USER" "$cleaned_keys"
  AUTHORIZED_KEYS_INSTALLED=1
}

configure_sudoers() {
  sudo_mode="$BOOTSTRAP_SUDO_NOPASSWD"
  sudoers_file="/etc/sudoers.d/90-${BOOTSTRAP_USER}-bootstrap"
  temp_sudoers=$(mktemp_managed)

  if [ "$sudo_mode" = auto ]; then
    if [ "$AUTHORIZED_KEYS_INSTALLED" = 1 ]; then
      sudo_mode=1
    else
      sudo_mode=0
    fi
  fi

  if [ "$sudo_mode" != 1 ]; then
    rm -f -- "$sudoers_file"
    log "未启用 $BOOTSTRAP_USER 的免密码 sudo。"
    return
  fi

  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$BOOTSTRAP_USER" >"$temp_sudoers"
  visudo -cf "$temp_sudoers" >/dev/null
  atomic_install_file "$temp_sudoers" "$sudoers_file" 0440 root root
  log "设置 $BOOTSTRAP_USER 的免密码 sudo。"
}

current_ssh_ports() {
  sshd=$(sshd_binary 2>/dev/null || true)
  if [ -n "$sshd" ] && [ -x "$sshd" ]; then
    "$sshd" -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true
  fi
  printf '%s\n' "$BOOTSTRAP_SSH_PORT"
}

configure_firewall() {
  [ "$BOOTSTRAP_ENABLE_UFW" = 1 ] || return 0

  ports=$(current_ssh_ports | awk 'NF && !seen[$1]++')
  temp_firewall=$(mktemp_managed)
  {
    printf '#!/bin/sh\n'
    printf '# 由 Alpine 基础配置脚本管理。\n'
    printf 'set -eu\n'
    printf 'HOLLOW_NET_IFACE=%s\n' "$HOLLOW_NET_IFACE"
    printf 'IPT=$(command -v iptables || true)\n'
    printf '[ -n "$IPT" ] || exit 0\n'
    printf '$IPT -N HLWDOT_BOOTSTRAP_INPUT 2>/dev/null || true\n'
    printf '$IPT -F HLWDOT_BOOTSTRAP_INPUT\n'
    printf '$IPT -C INPUT -j HLWDOT_BOOTSTRAP_INPUT 2>/dev/null || $IPT -I INPUT 1 -j HLWDOT_BOOTSTRAP_INPUT\n'
    printf '$IPT -A HLWDOT_BOOTSTRAP_INPUT -i lo -j ACCEPT\n'
    printf '[ -n "$HOLLOW_NET_IFACE" ] && $IPT -A HLWDOT_BOOTSTRAP_INPUT -i "$HOLLOW_NET_IFACE" -j ACCEPT\n'
    printf '$IPT -A HLWDOT_BOOTSTRAP_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
    printf '$IPT -A HLWDOT_BOOTSTRAP_INPUT -p icmp -j ACCEPT\n'
    while read -r port; do
      [ -n "$port" ] || continue
      printf '$IPT -A HLWDOT_BOOTSTRAP_INPUT -p tcp --dport %s -m conntrack --ctstate NEW -j ACCEPT\n' "$port"
    done <<EOF_PORTS
$ports
EOF_PORTS
    printf '$IPT -A HLWDOT_BOOTSTRAP_INPUT -j DROP\n'
    printf 'IP6T=$(command -v ip6tables || true)\n'
    printf '[ -n "$IP6T" ] || exit 0\n'
    printf '$IP6T -L >/dev/null 2>&1 || exit 0\n'
    printf '$IP6T -N HLWDOT_BOOTSTRAP_INPUT 2>/dev/null || true\n'
    printf '$IP6T -F HLWDOT_BOOTSTRAP_INPUT\n'
    printf '$IP6T -C INPUT -j HLWDOT_BOOTSTRAP_INPUT 2>/dev/null || $IP6T -I INPUT 1 -j HLWDOT_BOOTSTRAP_INPUT\n'
    printf '$IP6T -A HLWDOT_BOOTSTRAP_INPUT -i lo -j ACCEPT\n'
    printf '[ -n "$HOLLOW_NET_IFACE" ] && $IP6T -A HLWDOT_BOOTSTRAP_INPUT -i "$HOLLOW_NET_IFACE" -j ACCEPT\n'
    printf '$IP6T -A HLWDOT_BOOTSTRAP_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
    printf '$IP6T -A HLWDOT_BOOTSTRAP_INPUT -p ipv6-icmp -j ACCEPT\n'
    while read -r port; do
      [ -n "$port" ] || continue
      printf '$IP6T -A HLWDOT_BOOTSTRAP_INPUT -p tcp --dport %s -m conntrack --ctstate NEW -j ACCEPT\n' "$port"
    done <<EOF_PORTS
$ports
EOF_PORTS
    printf '$IP6T -A HLWDOT_BOOTSTRAP_INPUT -j DROP\n'
  } >"$temp_firewall"

  atomic_install_file "$temp_firewall" "$FIREWALL_SCRIPT" 0755 root root
  log "配置受管 iptables 防火墙：默认拒绝入站，放行 SSH 和 ${HOLLOW_NET_IFACE}。"
  "$FIREWALL_SCRIPT"
  rc-update add local default >/dev/null 2>&1 || true
}

begin_sshd_change() {
  rm -f -- "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP" "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG_HAD_BACKUP"
  if [ -f "$SSHD_DROPIN" ]; then
    cp -p "$SSHD_DROPIN" "$SSHD_DROPIN_BACKUP"
    touch "$SSHD_DROPIN_HAD_BACKUP"
  fi
  if [ -f "$SSHD_CONFIG" ]; then
    cp -p "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
    touch "$SSHD_CONFIG_HAD_BACKUP"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ >"$SSHD_CHANGE_IN_PROGRESS"
}

finish_sshd_change() {
  rm -f -- "$SSHD_CHANGE_IN_PROGRESS" "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP" "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG_HAD_BACKUP"
}

ensure_sshd_include() {
  mkdir -p /etc/ssh/sshd_config.d
  [ -f "$SSHD_CONFIG" ] || : >"$SSHD_CONFIG"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
    return 0
  fi

  temp_config=$(mktemp_managed)
  {
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
    cat "$SSHD_CONFIG"
  } >"$temp_config"
  atomic_install_file "$temp_config" "$SSHD_CONFIG" 0644 root root
}

configure_sshd() {
  lockdown="$BOOTSTRAP_SSH_LOCKDOWN"
  temp_sshd=$(mktemp_managed)

  if [ "$lockdown" = auto ]; then
    if [ "$AUTHORIZED_KEYS_INSTALLED" = 1 ]; then
      lockdown=1
    else
      lockdown=0
    fi
  fi

  [ "$lockdown" != 1 ] || [ "$AUTHORIZED_KEYS_INSTALLED" = 1 ] || die "拒绝启用仅密钥 SSH 登录：未发现可用 SSH 登录密钥。"
  [ "$lockdown" = 1 ] && SSH_LOCKDOWN_ACTIVE=1

  {
    printf '# 由 Alpine 基础配置脚本管理。\n'
    printf 'Port %s\n' "$BOOTSTRAP_SSH_PORT"
    printf 'PubkeyAuthentication yes\n'
    printf 'MaxAuthTries 3\n'
    if [ "$lockdown" = 1 ]; then
      printf 'PermitRootLogin prohibit-password\n'
      printf 'PasswordAuthentication no\n'
      printf 'KbdInteractiveAuthentication no\n'
      printf 'AuthenticationMethods publickey\n'
      printf '# 不写 AllowUsers，避免排除云厂商默认账号或现有救援账号。\n'
    else
      printf '# 尚未发现 root/%s/现有登录用户密钥，因此暂不启用仅密钥登录策略。\n' "$BOOTSTRAP_USER"
    fi
  } >"$temp_sshd"

  log "写入并验证 SSH 配置。"
  begin_sshd_change
  ensure_sshd_include
  atomic_install_file "$temp_sshd" "$SSHD_DROPIN" 0644 root root
  if ! test_sshd_config; then
    warn "新的 SSH 配置未通过校验，回滚受管配置。"
    rollback_sshd_config
    finish_sshd_change
    die "写入 $SSHD_DROPIN 后 sshd 配置校验失败。"
  fi

  rc-update add sshd default >/dev/null
  rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || rc-service sshd start >/dev/null
  finish_sshd_change
}

configure_fail2ban() {
  [ "$BOOTSTRAP_ENABLE_FAIL2BAN" = 1 ] || return 0

  temp_jail=$(mktemp_managed)
  mkdir -p /var/log
  touch /var/log/auth.log /var/log/messages
  chmod 0600 /var/log/auth.log
  {
    printf '[sshd]\n'
    printf 'enabled = true\n'
    printf 'port = %s\n' "$BOOTSTRAP_SSH_PORT"
    printf 'backend = polling\n'
    printf 'logpath = /var/log/auth.log\n'
    printf '          /var/log/messages\n'
    printf 'maxretry = 5\n'
    printf 'findtime = 10m\n'
    printf 'bantime = 1h\n'
  } >"$temp_jail"

  log "配置 fail2ban 的 sshd jail。"
  atomic_install_file "$temp_jail" "$FAIL2BAN_JAIL" 0644 root root
  fail2ban-client -t >/dev/null
  rc-update add fail2ban default >/dev/null
  rc-service fail2ban restart >/dev/null 2>&1 || rc-service fail2ban start >/dev/null
}

configure_unattended_upgrades() {
  if [ "$BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES" != 1 ]; then
    rm -f -- "$APK_AUTO_UPGRADE"
    return 0
  fi

  temp_upgrade=$(mktemp_managed)
  {
    printf '#!/bin/sh\n'
    printf '# 由 Alpine 基础配置脚本管理。\n'
    printf 'set -eu\n'
    printf 'apk update >/dev/null\n'
    printf 'apk upgrade --available\n'
  } >"$temp_upgrade"

  log "配置 daily apk 自动更新。"
  atomic_install_file "$temp_upgrade" "$APK_AUTO_UPGRADE" 0755 root root
  rc-update add crond default >/dev/null
  rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null
}

sysctl_proc_path() {
  key="$1"
  printf '/proc/sys/%s\n' "$(printf '%s' "$key" | tr . /)"
}

sysctl_key_exists() {
  [ -e "$(sysctl_proc_path "$1")" ]
}

sysctl_read_value() {
  sysctl -n "$1" 2>/dev/null || true
}

sysctl_set_checked() {
  key="$1"
  value="$2"
  error_file=$(mktemp_managed)

  if ! sysctl_key_exists "$key"; then
    warn "当前内核未暴露 ${key}，跳过该 BBR 子项。"
    return 2
  fi

  if sysctl -w "${key}=${value}" >"$error_file" 2>&1; then
    return 0
  fi

  error_text=$(tr '\n' ' ' <"$error_file")
  warn "无法设置 ${key}=${value}：${error_text:-未知错误}"
  return 1
}

tcp_bbr_available() {
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

configure_bbr() {
  if [ "$BOOTSTRAP_ENABLE_BBR" != 1 ]; then
    BBR_STATUS=disabled
    BBR_DETAIL='BOOTSTRAP_ENABLE_BBR=0'
    return 0
  fi

  log "配置 TCP BBR。"
  BBR_CONFIGURED=0
  BBR_STATUS=failed
  BBR_DETAIL=''
  qdisc_configured=0
  temp_modules=$(mktemp_managed)
  temp_etc_modules=$(mktemp_managed)
  temp_conf=$(mktemp_managed)

  printf 'tcp_bbr\n' >"$temp_modules"
  mkdir -p /etc/modules-load.d /etc/sysctl.d
  atomic_install_file "$temp_modules" "$MODULES_BBR" 0644 root root
  if [ -f /etc/modules ]; then
    awk '$1 != "tcp_bbr" { print } END { print "tcp_bbr" }' /etc/modules >"$temp_etc_modules"
  else
    printf 'tcp_bbr\n' >"$temp_etc_modules"
  fi
  atomic_install_file "$temp_etc_modules" /etc/modules 0644 root root

  if ! tcp_bbr_available; then
    modprobe tcp_bbr 2>/dev/null || true
  fi

  if ! sysctl_key_exists net.ipv4.tcp_congestion_control; then
    BBR_STATUS=unavailable
    BBR_DETAIL='net.ipv4.tcp_congestion_control is not exposed'
    die "无法开启 BBR：当前内核命名空间没有 net.ipv4.tcp_congestion_control，脚本无法在这个 Alpine 环境内修改拥塞控制。"
  fi

  if [ "$(sysctl_read_value net.ipv4.tcp_congestion_control)" != bbr ]; then
    tcp_bbr_available || die "无法开启 BBR：当前内核的 tcp_available_congestion_control 未列出 bbr。"
    sysctl_set_checked net.ipv4.tcp_congestion_control bbr || die "无法写入 net.ipv4.tcp_congestion_control=bbr。"
  fi

  if [ "$(sysctl_read_value net.ipv4.tcp_congestion_control)" != bbr ]; then
    BBR_STATUS=failed
    BBR_DETAIL="tcp_congestion_control=$(sysctl_read_value net.ipv4.tcp_congestion_control)"
    die "BBR 未开启：${BBR_DETAIL}"
  fi

  if sysctl_key_exists net.core.default_qdisc; then
    if sysctl_set_checked net.core.default_qdisc fq &&
      [ "$(sysctl_read_value net.core.default_qdisc)" = fq ]; then
      qdisc_configured=1
    fi
  else
    log "当前内核未暴露 net.core.default_qdisc，跳过可选队列配置。"
  fi

  {
    [ "$qdisc_configured" = 1 ] && printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  } >"$temp_conf"
  atomic_install_file "$temp_conf" "$SYSCTL_BBR" 0644 root root
  rc-update add sysctl boot >/dev/null 2>&1 || rc-update add sysctl default >/dev/null 2>&1 || true

  BBR_CONFIGURED=1
  BBR_STATUS=active
  if [ "$qdisc_configured" = 1 ]; then
    BBR_DETAIL='tcp_congestion_control=bbr; default_qdisc=fq'
  else
    BBR_DETAIL='tcp_congestion_control=bbr'
  fi
  log "BBR 已开启：${BBR_DETAIL}"
}

choose_auto_swap_size_mb() {
  available_mb="${1:-}"
  if is_uint "$available_mb" && [ "$available_mb" -le 1024 ]; then
    printf '128\n'
    return
  fi

  mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
  is_uint "$mem_kb" && [ "$mem_kb" -gt 0 ] || die "无法读取 /proc/meminfo 中的 MemTotal。"
  mem_mb=$(((mem_kb + 1023) / 1024))

  if [ "$mem_mb" -le 2048 ]; then
    printf '%s\n' "$mem_mb"
  else
    printf '4096\n'
  fi
}

parse_swap_size_mb() {
  raw="$1"
  available_mb="${2:-}"
  case "$raw" in
    auto)
      choose_auto_swap_size_mb "$available_mb"
      ;;
    0)
      printf '0\n'
      ;;
    *[Kk])
      number=${raw%?}
      is_uint "$number" || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' $(((number + 1023) / 1024))
      ;;
    *[Mm])
      number=${raw%?}
      is_uint "$number" || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' "$number"
      ;;
    *[Gg])
      number=${raw%?}
      is_uint "$number" || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' $((number * 1024))
      ;;
    *)
      is_uint "$raw" || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' "$raw"
      ;;
  esac
}

swapfile_has_signature() {
  swap_path="$1"
  file -b "$swap_path" 2>/dev/null | grep -qi 'swap file'
}

remove_fstab_swap_entry() {
  swap_path="$1"
  temp_fstab=$(mktemp_managed)

  if [ ! -f /etc/fstab ]; then
    return 0
  fi

  awk -v swap="$swap_path" '$1 == swap && $3 == "swap" { next } { print }' /etc/fstab >"$temp_fstab"
  atomic_install_file "$temp_fstab" /etc/fstab 0644 root root
}

cleanup_lxc_swap_artifacts() {
  stale_swap_path=''

  if [ -f "$SWAP_IN_PROGRESS" ]; then
    stale_swap_path=$(sed -n 's/^swapfile=//p' "$SWAP_IN_PROGRESS" | head -n 1)
    if [ -n "$stale_swap_path" ]; then
      safe_remove_managed_swapfile "$stale_swap_path" || warn "未能清理上次未完成的 swapfile：$stale_swap_path"
      remove_fstab_swap_entry "$stale_swap_path"
    fi
    rm -f -- "$SWAP_IN_PROGRESS"
    return 0
  fi

  if [ "$BOOTSTRAP_SWAPFILE" = /swapfile ] &&
    [ -f /swapfile ] &&
    ! is_swap_active /swapfile &&
    swapfile_has_signature /swapfile; then
    rm -f -- /swapfile
    remove_fstab_swap_entry /swapfile
    log "删除 Alpine LXC 中旧的受管 swapfile 残留：/swapfile"
  fi
}

zram_swap_active() {
  [ -r /proc/swaps ] || return 1
  awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-9]+$/ && $3 == "partition" { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps
}

configure_zram_swap() {
  size_mb="$1"
  original_error="${2:-}"

  if is_lxc_container; then
    cleanup_lxc_swap_artifacts
    SWAP_BACKEND=lxc-host
    SWAP_ACTIVE_TARGET=host-managed
    log "检测到 LXC 容器，swap 由宿主机/cgroup 管理；不在容器内配置 zram。"
    return 0
  fi

  temp_zram=$(mktemp_managed)
  warn "swapfile 无法在当前文件系统启用，改用 Alpine 官方 zram-init swap。原始错误：${original_error:-未知错误}"
  rm -f -- "$BOOTSTRAP_SWAPFILE"
  remove_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"

  if ! apk add zram-init >/dev/null; then
    rm -f -- "$SWAP_IN_PROGRESS"
    die "无法安装 zram-init，且当前文件系统无法启用 swapfile。"
  fi
  {
    printf 'load_on_start=yes\n'
    printf 'unload_on_stop=yes\n'
    printf 'num_devices=1\n'
    printf 'type0=swap\n'
    printf 'size0=%s\n' "$size_mb"
  } >"$temp_zram"
  atomic_install_file "$temp_zram" "$ZRAM_CONF" 0644 root root

  if ! rc-service zram-init restart >/dev/null 2>&1; then
    rc-service zram-init start >/dev/null || {
      rm -f -- "$SWAP_IN_PROGRESS"
      die "zram-init 服务启动失败。"
    }
  fi
  rc-update add zram-init default >/dev/null

  if ! zram_swap_active; then
    rm -f -- "$SWAP_IN_PROGRESS"
    die "zram-init 已配置但 /proc/swaps 未出现 /dev/zram*；请检查 rc-service zram-init status。"
  fi

  SWAP_BACKEND=zram
  SWAP_ACTIVE_TARGET=/dev/zram0
  log "启用 zram swap：${size_mb}M。"
}

swapfile_size_bytes() {
  wc -c <"$1" | tr -d '[:space:]'
}

create_swapfile_with_method() {
  swap_path="$1"
  size_mb="$2"
  method="$3"
  expected_bytes=$((size_mb * 1024 * 1024))

  rm -f -- "$swap_path"
  : >"$swap_path"
  chmod 0600 "$swap_path"
  if command_exists chattr; then
    chattr +C "$swap_path" >/dev/null 2>&1 || true
  fi

  case "$method" in
    fallocate)
      command_exists fallocate || return 1
      fallocate -l "${size_mb}M" "$swap_path" 2>/dev/null || return 1
      ;;
    zero)
      dd if=/dev/zero of="$swap_path" bs=1M count="$size_mb"
      ;;
    nonzero)
      dd if=/dev/zero bs=1M count="$size_mb" 2>/dev/null | tr '\000' '\377' >"$swap_path"
      ;;
    *)
      return 1
      ;;
  esac

  chmod 0600 "$swap_path"
  actual_bytes=$(swapfile_size_bytes "$swap_path" 2>/dev/null || printf 0)
  [ "$actual_bytes" = "$expected_bytes" ]
}

run_swapon_checked() {
  swap_path="$1"
  error_file=$(mktemp_managed)
  SWAPON_ERROR=''

  if swapon "$swap_path" >"$error_file" 2>&1; then
    return 0
  fi

  SWAPON_ERROR=$(tr '\n' ' ' <"$error_file")
  return 1
}

format_and_swapon_checked() {
  swap_path="$1"
  error_file=$(mktemp_managed)
  SWAPON_ERROR=''

  if ! mkswap "$swap_path" >"$error_file" 2>&1; then
    SWAPON_ERROR=$(tr '\n' ' ' <"$error_file")
    return 1
  fi

  run_swapon_checked "$swap_path"
}

swapon_error_is_holes() {
  printf '%s\n' "$SWAPON_ERROR" | grep -Eqi 'hole|holes|洞'
}

create_and_enable_swapfile() {
  swap_path="$1"
  size_mb="$2"
  first_error=''

  if create_swapfile_with_method "$swap_path" "$size_mb" fallocate; then
    log "已预分配 swapfile：$swap_path"
  else
    create_swapfile_with_method "$swap_path" "$size_mb" zero || {
      rm -f -- "$swap_path" "$SWAP_IN_PROGRESS"
      die "无法创建 ${size_mb}M swapfile：$swap_path"
    }
  fi

  if format_and_swapon_checked "$swap_path"; then
    SWAP_BACKEND=file
    SWAP_ACTIVE_TARGET="$swap_path"
    return 0
  fi

  first_error="$SWAPON_ERROR"
  if swapon_error_is_holes; then
    warn "检测到 swapfile 含洞，改用非零字节重新创建：$swap_path"
    create_swapfile_with_method "$swap_path" "$size_mb" nonzero || {
      configure_zram_swap "$size_mb" "$first_error"
      return 0
    }
    if format_and_swapon_checked "$swap_path"; then
      SWAP_BACKEND=file
      SWAP_ACTIVE_TARGET="$swap_path"
      return 0
    fi
    first_error="$SWAPON_ERROR"
  fi

  configure_zram_swap "$size_mb" "$first_error"
}

ensure_fstab_swap_entry() {
  swap_path="$1"
  temp_fstab=$(mktemp_managed)
  if [ -f /etc/fstab ]; then
    awk -v swap="$swap_path" '
      $1 == swap && $3 == "swap" { next }
      { print }
      END { print swap " none swap sw 0 0" }
    ' /etc/fstab >"$temp_fstab"
  else
    printf '%s none swap sw 0 0\n' "$swap_path" >"$temp_fstab"
  fi
  atomic_install_file "$temp_fstab" /etc/fstab 0644 root root
}

configure_swapfile() {
  reserve_mb=256

  [ "$BOOTSTRAP_ENABLE_SWAP" = 1 ] || return 0

  if is_lxc_container; then
    SWAP_SIZE_MB=0
    SWAP_BACKEND=lxc-host
    SWAP_ACTIVE_TARGET=host-managed
    cleanup_lxc_swap_artifacts
    log "检测到 LXC 容器，swap 由宿主机/cgroup 管理；跳过容器内 swapfile/zram 配置。"
    return 0
  fi

  swap_dir=$(dirname "$BOOTSTRAP_SWAPFILE")
  mkdir -p "$swap_dir"
  available_kb=$(df -kP "$swap_dir" | awk 'NR == 2 { print $4 }')
  is_uint "$available_kb" || die "无法读取 ${swap_dir} 的可用磁盘空间。"
  available_mb=$((available_kb / 1024))

  size_mb=$(parse_swap_size_mb "$BOOTSTRAP_SWAP_SIZE" "$available_mb")
  SWAP_SIZE_MB="$size_mb"
  if [ "$size_mb" -eq 0 ]; then
    log "BOOTSTRAP_SWAP_SIZE=0，跳过 swapfile。"
    return
  fi
  if [ "$BOOTSTRAP_SWAP_SIZE" = auto ]; then
    log "自动选择 swapfile 大小：${size_mb}M。"
  fi

  if is_swap_active "$BOOTSTRAP_SWAPFILE"; then
    log "swapfile 处于启用状态：$BOOTSTRAP_SWAPFILE"
    ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
    return
  fi

  if [ -e "$BOOTSTRAP_SWAPFILE" ]; then
    [ -f "$BOOTSTRAP_SWAPFILE" ] || die "swapfile 目标存在但不是普通文件：$BOOTSTRAP_SWAPFILE"
    if swapfile_has_signature "$BOOTSTRAP_SWAPFILE"; then
      chmod 0600 "$BOOTSTRAP_SWAPFILE"
      if ! run_swapon_checked "$BOOTSTRAP_SWAPFILE"; then
        configure_zram_swap "$size_mb" "$SWAPON_ERROR"
        return
      fi
      SWAP_BACKEND=file
      SWAP_ACTIVE_TARGET="$BOOTSTRAP_SWAPFILE"
      ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
      log "启用已有 swapfile：$BOOTSTRAP_SWAPFILE"
      return
    fi
    die "swapfile 目标已存在但不是 swap 文件，拒绝覆盖：$BOOTSTRAP_SWAPFILE"
  fi

  if [ "$BOOTSTRAP_SWAP_SIZE" = auto ] && [ "$size_mb" -eq 128 ] && [ "$available_mb" -le 1024 ]; then
    reserve_mb=0
  fi
  [ "$available_mb" -gt $((size_mb + reserve_mb)) ] || die "磁盘空间不足，无法在 ${swap_dir} 创建 ${size_mb}M swapfile。"

  printf 'swapfile=%s\nsize_mb=%s\n' "$BOOTSTRAP_SWAPFILE" "$size_mb" >"$SWAP_IN_PROGRESS"
  log "创建 swapfile：${BOOTSTRAP_SWAPFILE}，大小 ${size_mb}M。"
  create_and_enable_swapfile "$BOOTSTRAP_SWAPFILE" "$size_mb"
  if [ "$SWAP_BACKEND" = file ]; then
    ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
  fi
  rm -f -- "$SWAP_IN_PROGRESS"
}

enable_core_services() {
  log "启动基础服务。"
  if is_lxc_container; then
    if rc-service chronyd status >/dev/null 2>&1; then
      rc-service chronyd stop >/dev/null 2>&1 || true
    fi
    if rc-update show default 2>/dev/null | awk '$1 == "chronyd" { found = 1 } END { exit found ? 0 : 1 }'; then
      rc-update del chronyd default >/dev/null 2>&1 || true
    fi
    log "检测到 LXC 容器，系统时钟由宿主机管理；不启动 chronyd。"
  else
    rc-update add chronyd default >/dev/null 2>&1 || true
    rc-service chronyd restart >/dev/null 2>&1 || rc-service chronyd start >/dev/null 2>&1 || warn "chronyd 启动失败。"
  fi
  rc-update add sshd default >/dev/null 2>&1 || true
}

cleanup_apk() {
  log "清理 apk 缓存。"
  apk cache clean >/dev/null 2>&1 || true
}

write_done_marker() {
  mkdir -p "$STATE_DIR"
  {
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'user=%s\n' "$BOOTSTRAP_USER"
    printf 'ssh_lockdown=%s\n' "$SSH_LOCKDOWN_ACTIVE"
    printf 'firewall=%s\n' "$BOOTSTRAP_ENABLE_UFW"
    printf 'fail2ban=%s\n' "$BOOTSTRAP_ENABLE_FAIL2BAN"
    printf 'bbr=%s\n' "$BBR_CONFIGURED"
    printf 'bbr_status=%s\n' "$BBR_STATUS"
    printf 'bbr_detail=%s\n' "$BBR_DETAIL"
    printf 'swapfile=%s\n' "$BOOTSTRAP_SWAPFILE"
    printf 'swap_size_mb=%s\n' "$SWAP_SIZE_MB"
    printf 'swap_backend=%s\n' "$SWAP_BACKEND"
    printf 'swap_active_target=%s\n' "$SWAP_ACTIVE_TARGET"
  } >"$DONE_MARKER"
  chmod 0644 "$DONE_MARKER"
}

print_summary() {
  log "执行完成。"
  printf '\n状态：\n'
  printf '  用户：%s\n' "$BOOTSTRAP_USER"
  printf '  authorized_keys：%s\n' "$(configured_label "$AUTHORIZED_KEYS_INSTALLED")"
  printf '  密码 SSH 登录：%s\n' "$(ssh_password_login_label)"
  printf '  SSH 用户限制：未限定\n'
  printf '  防火墙：%s\n' "$(enabled_label "$BOOTSTRAP_ENABLE_UFW")"
  printf '  fail2ban：%s\n' "$(enabled_label "$BOOTSTRAP_ENABLE_FAIL2BAN")"
  printf '  BBR：%s%s\n' "$BBR_STATUS" "$([ -n "$BBR_DETAIL" ] && printf '；%s' "$BBR_DETAIL")"
  printf '  swap：%s %s\n' "$SWAP_BACKEND" "${SWAP_ACTIVE_TARGET:-未启用}"
  printf '  状态文件：%s\n' "$DONE_MARKER"

  if [ "$AUTHORIZED_KEYS_INSTALLED" != 1 ]; then
    printf '\n未发现 root/%s/现有登录用户 authorized_keys，SSH 登录策略保持原状。\n' "$BOOTSTRAP_USER"
  fi
}

main() {
  case "${1:-}" in
    -h|--help)
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
  validate_input
  require_alpine_openrc
  setup_state_dir
  recover_previous_run

  install_packages
  configure_hostname
  configure_timezone
  configure_locale
  ensure_user
  install_authorized_keys
  configure_sudoers
  configure_firewall
  configure_sshd
  configure_fail2ban
  configure_unattended_upgrades
  configure_bbr
  configure_swapfile
  enable_core_services
  cleanup_apk
  write_done_marker
  print_summary
}

main "$@"
