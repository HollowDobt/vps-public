#!/usr/bin/env bash
# Debian 13 VPS 刷写系统后的首次基础配置脚本。
#
# Debian 13 安装完成后的基础初始化：BOOTSTRAP_USER 登录、基础安全防护、
# BBR、swapfile，以及 Ctrl-C 中断后的可重复执行恢复。
#
# 运行方式：
#   sudo bash scripts/debian13-bootstrap.sh
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
#   - BOOTSTRAP_SWAP_SIZE=auto 时，swapfile 所在文件系统可用空间小于或等于 1GB 创建 128MB；
#     否则 MemTotal 小于或等于 2GB 创建约等于 MemTotal 的 swapfile，MemTotal 大于 2GB 创建 4GB。
#
# 中断后再次运行时，脚本会清理受管临时文件、恢复 dpkg/apt 半配置状态，
# 然后继续完成剩余配置。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

# 运行状态目录只保存本脚本自己的标记、备份和临时文件。重新执行时只会清理
# 这里记录过的受管内容，避免误删用户数据或业务文件。
readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly SCRIPT_DIR
readonly STATE_DIR="/var/lib/hlwdot/debian13-bootstrap"
readonly TMP_DIR="${STATE_DIR}/tmp"
readonly DONE_MARKER="${STATE_DIR}/done.env"
readonly INTERRUPT_MARKER="${STATE_DIR}/interrupted"
readonly SWAP_IN_PROGRESS="${STATE_DIR}/swap-create.in-progress"
readonly SSHD_CHANGE_IN_PROGRESS="${STATE_DIR}/sshd-change.in-progress"
readonly SSHD_DROPIN_BACKUP="${STATE_DIR}/sshd-dropin.previous"
readonly SSHD_DROPIN_HAD_BACKUP="${STATE_DIR}/sshd-dropin.had-backup"

# 这些文件由脚本负责生成和维护。脚本只覆盖这些明确受管的 drop-in 文件。
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-hlwdot-bootstrap.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/10-hlwdot-sshd.conf"
readonly APT_AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
readonly APT_UNATTENDED_UPGRADES="/etc/apt/apt.conf.d/52hlwdot-unattended-upgrades"
readonly MODULES_BBR="/etc/modules-load.d/90-hlwdot-bbr.conf"
readonly SYSCTL_BBR="/etc/sysctl.d/90-hlwdot-bbr.conf"

load_bootstrap_env_file() {
  local env_file="$1"
  local env_status

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  env_status=$?
  set +a
  return "$env_status"
}

load_bootstrap_env() {
  local candidate
  local candidates=()

  if [[ -n "${VPS_ENV_FILE:-}" ]]; then
    candidates+=("$VPS_ENV_FILE")
  else
    candidates+=("/etc/hlwdot/vps.env" "${SCRIPT_DIR}/.env")
  fi

  for candidate in "${candidates[@]}"; do
    [[ -r "$candidate" ]] || continue
    if [[ -z "${VPS_ENV_FILE:-}" && "$candidate" == "${SCRIPT_DIR}/.env" && -r /etc/hlwdot/vps.env ]]; then
      set -a
      # shellcheck disable=SC1090
      . <(awk '
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*$/ { print; next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*$/ { next }
        { print }
      ' "$candidate")
      set +a
    else
      load_bootstrap_env_file "$candidate"
    fi
  done
}

load_bootstrap_env

# 默认值尽量贴合新 VPS 的基础使用场景：BOOTSTRAP_USER 是主账号，SSH 端口默认 22。
# 只有找到可用登录密钥并写入 root 与 BOOTSTRAP_USER 后，才会启用仅密钥 SSH 登录策略。
VPS_NODE_NAME="${VPS_NODE_NAME:-}"
BOOTSTRAP_USER="${BOOTSTRAP_USER:-hollow}"
BOOTSTRAP_HOSTNAME="$VPS_NODE_NAME"
BOOTSTRAP_TIMEZONE="${BOOTSTRAP_TIMEZONE:-Asia/Shanghai}"
BOOTSTRAP_LOCALE="${BOOTSTRAP_LOCALE:-en_US.UTF-8}"
BOOTSTRAP_EXTRA_LOCALES="${BOOTSTRAP_EXTRA_LOCALES:-zh_CN.UTF-8}"
BOOTSTRAP_SSH_PORT="${BOOTSTRAP_SSH_PORT:-22}"
BOOTSTRAP_SSH_LOCKDOWN="${BOOTSTRAP_SSH_LOCKDOWN:-auto}"      # auto、1、0
BOOTSTRAP_SUDO_NOPASSWD="${BOOTSTRAP_SUDO_NOPASSWD:-auto}"    # auto、1、0
BOOTSTRAP_ENABLE_UFW="${BOOTSTRAP_ENABLE_UFW:-1}"
BOOTSTRAP_ENABLE_FAIL2BAN="${BOOTSTRAP_ENABLE_FAIL2BAN:-1}"
BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES="${BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES:-1}"
BOOTSTRAP_FULL_UPGRADE="${BOOTSTRAP_FULL_UPGRADE:-1}"
BOOTSTRAP_ENABLE_BBR="${BOOTSTRAP_ENABLE_BBR:-1}"
BOOTSTRAP_AUTHORIZED_KEYS_SOURCE="${BOOTSTRAP_AUTHORIZED_KEYS_SOURCE:-/root/.ssh/authorized_keys}"
BOOTSTRAP_AUTHORIZED_KEYS="${BOOTSTRAP_AUTHORIZED_KEYS:-}"
BOOTSTRAP_USER_PASSWORD_HASH="${BOOTSTRAP_USER_PASSWORD_HASH:-}"
BOOTSTRAP_USER_PASSWORD="${BOOTSTRAP_USER_PASSWORD:-}"

# swapfile 默认开启。BOOTSTRAP_SWAP_SIZE=auto 时先看 swapfile 所在文件系统可用空间：
# 可用空间小于或等于 1GB 创建 128MB；否则 MemTotal 小于或等于 2GB 创建约等于
# MemTotal 的 swapfile，MemTotal 大于 2GB 创建 4GB。
# fstab 中不设置 pri，让内核使用默认 swap 优先级。
BOOTSTRAP_ENABLE_SWAP="${BOOTSTRAP_ENABLE_SWAP:-1}"
BOOTSTRAP_SWAPFILE="${BOOTSTRAP_SWAPFILE:-/swapfile}"
BOOTSTRAP_SWAP_SIZE="${BOOTSTRAP_SWAP_SIZE:-auto}"            # auto、0、1024M、2G

AUTHORIZED_KEYS_INSTALLED=0
SSH_LOCKDOWN_ACTIVE=0
BBR_CONFIGURED=0
SWAP_SIZE_MB=0
TEMP_FILES=()

APT_GET=(
  apt-get
  -y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Acquire::Retries=3
  -o DPkg::Lock::Timeout=120
)

log_location() {
  hostname 2>/dev/null || printf 'unknown'
}

log() {
  printf '[%s] INFO：%s 在 %s 执行：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*"
}

enabled_label() {
  if [[ "$1" == "1" ]]; then
    printf '启用'
  else
    printf '停用'
  fi
}

configured_label() {
  if [[ "$1" == "1" ]]; then
    printf '已配置'
  else
    printf '未配置'
  fi
}

ssh_password_login_label() {
  if [[ "$SSH_LOCKDOWN_ACTIVE" == "1" ]]; then
    printf '禁用'
  else
    printf '保留'
  fi
}

warn() {
  printf '[%s] WARN：%s 在 %s 执行时提示：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*" >&2
}

die() {
  printf '[%s] ERROR：%s 在 %s 执行脚本时发生错误：%s\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$*" >&2
  exit 1
}

# 统一创建运行目录。后续所有临时文件都放在受管目录中，方便中断后清理。
setup_state_dir() {
  install -d -o root -g root -m 0755 "$STATE_DIR"
  install -d -o root -g root -m 0700 "$TMP_DIR"
}

track_tempfile() {
  TEMP_FILES+=("$1")
}

mktemp_managed() {
  local temp_file

  temp_file="$(mktemp "${TMP_DIR}/${SCRIPT_NAME}.XXXXXX")"
  track_tempfile "$temp_file"
  printf '%s\n' "$temp_file"
}

# 清理当前进程创建的临时文件。这里不删除正式配置文件，也不碰业务目录。
cleanup_tempfiles() {
  local temp_file

  for temp_file in "${TEMP_FILES[@]}"; do
    [[ -e "$temp_file" ]] && rm -f -- "$temp_file"
  done

  return 0
}

# Ctrl-C 或 TERM 中断时只记录状态并清理临时文件。正式恢复动作放到下一次
# 启动时执行，这样不会在信号处理过程中做复杂系统修改。
on_interrupt() {
  warn "收到中断信号，已停止。再次运行脚本会先做恢复检查。"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  date -u +%Y-%m-%dT%H:%M:%SZ >"$INTERRUPT_MARKER" 2>/dev/null || true
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

trap cleanup_tempfiles EXIT
trap on_interrupt INT TERM
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

可配置环境变量：
  VPS_NODE_NAME=server-new
  BOOTSTRAP_USER=hollow
  BOOTSTRAP_TIMEZONE=Asia/Shanghai
  BOOTSTRAP_LOCALE=en_US.UTF-8
  BOOTSTRAP_EXTRA_LOCALES=zh_CN.UTF-8
  BOOTSTRAP_SSH_PORT=22
  BOOTSTRAP_SSH_LOCKDOWN=auto          # auto、1、0
  BOOTSTRAP_SUDO_NOPASSWD=auto         # auto、1、0
  BOOTSTRAP_ENABLE_UFW=1
  BOOTSTRAP_ENABLE_FAIL2BAN=1
  BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES=1
  BOOTSTRAP_FULL_UPGRADE=1
  BOOTSTRAP_ENABLE_BBR=1
  BOOTSTRAP_AUTHORIZED_KEYS_SOURCE=/root/.ssh/authorized_keys
  BOOTSTRAP_AUTHORIZED_KEYS='ssh-ed25519 AAAA...'
  BOOTSTRAP_USER_PASSWORD_HASH='\$y\$...'
  BOOTSTRAP_ENABLE_SWAP=1
  BOOTSTRAP_SWAPFILE=/swapfile
  BOOTSTRAP_SWAP_SIZE=auto             # auto、0、1024M、2G

说明：
  - 仅支持 Debian 13。
  - BOOTSTRAP_SSH_LOCKDOWN=auto 时，只有找到可用登录密钥并写入 root 与 BOOTSTRAP_USER 后才启用仅密钥登录。
  - swapfile 默认开启；auto 在磁盘可用空间小于或等于 1GB 时使用 128M，否则按 MemTotal 选择自身内存大小或 4G。
  - fstab 不设置 pri，使用系统默认 swap 优先级。
  - 中断后可重新执行；脚本会先检查上次未完成的受管配置。
EOF
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

validate_auto_bool() {
  local name="$1"
  local value="$2"

  case "$value" in
    auto | 0 | 1) ;;
    *) die "${name} 只能是 auto、0 或 1。" ;;
  esac
}

# 输入校验尽早执行，避免错误参数写入系统配置。
validate_input() {
  [[ -n "$VPS_NODE_NAME" ]] || die "必须设置 VPS_NODE_NAME。"
  [[ "$VPS_NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$ ]] || die "VPS_NODE_NAME 格式不合法。"
  [[ "$VPS_NODE_NAME" != *..* ]] || die "VPS_NODE_NAME 不能包含连续的点。"
  BOOTSTRAP_HOSTNAME="$VPS_NODE_NAME"

  case "$BOOTSTRAP_USER" in
    '' | *[!a-z_0-9-]* | -*)
      die "BOOTSTRAP_USER 必须是简单的小写 Linux 用户名。"
      ;;
  esac

  case "$BOOTSTRAP_SSH_PORT" in
    '' | *[!0-9]*)
      die "BOOTSTRAP_SSH_PORT 必须是数字。"
      ;;
  esac
  ((BOOTSTRAP_SSH_PORT >= 1 && BOOTSTRAP_SSH_PORT <= 65535)) || die "BOOTSTRAP_SSH_PORT 必须在 1 到 65535 之间。"

  if [[ -n "$BOOTSTRAP_HOSTNAME" ]]; then
    [[ "$BOOTSTRAP_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$ ]] || die "BOOTSTRAP_HOSTNAME 格式不合法。"
    [[ "$BOOTSTRAP_HOSTNAME" != *..* ]] || die "BOOTSTRAP_HOSTNAME 不能包含连续的点。"
  fi

  [[ "$BOOTSTRAP_TIMEZONE" != /* && "$BOOTSTRAP_TIMEZONE" != *..* ]] || die "BOOTSTRAP_TIMEZONE 不能是绝对路径或包含 ..。"
  [[ "$BOOTSTRAP_TIMEZONE" =~ ^[A-Za-z0-9_+./-]+$ ]] || die "BOOTSTRAP_TIMEZONE 包含非法字符。"

  [[ "$BOOTSTRAP_SWAPFILE" == /* ]] || die "BOOTSTRAP_SWAPFILE 必须是绝对路径。"
  [[ "$BOOTSTRAP_SWAPFILE" != "/" && "$BOOTSTRAP_SWAPFILE" != *$'\n'* && "$BOOTSTRAP_SWAPFILE" != *[[:space:]]* ]] || die "BOOTSTRAP_SWAPFILE 不能是根目录，也不能包含空白字符。"

  validate_auto_bool BOOTSTRAP_SSH_LOCKDOWN "$BOOTSTRAP_SSH_LOCKDOWN"
  validate_auto_bool BOOTSTRAP_SUDO_NOPASSWD "$BOOTSTRAP_SUDO_NOPASSWD"
  validate_bool BOOTSTRAP_ENABLE_UFW "$BOOTSTRAP_ENABLE_UFW"
  validate_bool BOOTSTRAP_ENABLE_FAIL2BAN "$BOOTSTRAP_ENABLE_FAIL2BAN"
  validate_bool BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES "$BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES"
  validate_bool BOOTSTRAP_FULL_UPGRADE "$BOOTSTRAP_FULL_UPGRADE"
  validate_bool BOOTSTRAP_ENABLE_BBR "$BOOTSTRAP_ENABLE_BBR"
  validate_bool BOOTSTRAP_ENABLE_SWAP "$BOOTSTRAP_ENABLE_SWAP"
}

require_debian_13() {
  [[ -r /etc/os-release ]] || die "找不到 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "debian" ]] || die "仅支持 Debian 13，当前系统 ID=${ID:-未知}。"
  [[ "${VERSION_ID%%.*}" == "13" ]] || die "仅支持 Debian 13，当前 VERSION_ID=${VERSION_ID:-未知}。"
}

# 如果上一次在 apt/dpkg 阶段被中断，Debian 可能留下“半配置”的包状态。
# 重新执行时先修复这个状态，后续 apt install/full-upgrade 才不会连锁失败。
repair_package_manager() {
  log "检查并修复 apt/dpkg 状态。"
  dpkg --configure -a
  "${APT_GET[@]}" -f install
}

is_swap_active() {
  local swap_path="$1"

  swapon --noheadings --show=NAME 2>/dev/null | awk -v path="$swap_path" '$1 == path { found = 1 } END { exit found ? 0 : 1 }'
}

safe_remove_managed_swapfile() {
  local swap_path="$1"

  [[ -n "$swap_path" && "$swap_path" == /* && "$swap_path" != "/" ]] || return 1
  if [[ -e "$swap_path" ]] && ! is_swap_active "$swap_path"; then
    rm -f -- "$swap_path"
    log "删除未完成的 swapfile：$swap_path"
  fi
}

# 恢复上次未完成的 swap 创建。只有存在本脚本留下的 in-progress 标记时，
# 才会清理对应 swapfile，避免误删用户手工创建的文件。
recover_swap_if_needed() {
  local swap_path

  [[ -f "$SWAP_IN_PROGRESS" ]] || return 0
  swap_path="$(sed -n 's/^swapfile=//p' "$SWAP_IN_PROGRESS" | head -n 1)"

  if [[ -n "$swap_path" ]] && is_swap_active "$swap_path"; then
    log "swapfile 已处于启用状态，移除未完成标记。"
  else
    safe_remove_managed_swapfile "$swap_path" || warn "未能清理上次未完成的 swapfile：${swap_path:-未知路径}"
  fi

  rm -f -- "$SWAP_IN_PROGRESS"
}

sshd_binary() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  else
    printf '/usr/sbin/sshd\n'
  fi
}

test_sshd_config() {
  local sshd

  sshd="$(sshd_binary)"
  install -d -o root -g root -m 0755 /run/sshd
  "$sshd" -t
}

rollback_sshd_dropin() {
  if [[ -f "$SSHD_DROPIN_HAD_BACKUP" && -f "$SSHD_DROPIN_BACKUP" ]]; then
    install -o root -g root -m 0644 "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN"
    log "恢复 SSH drop-in 备份。"
  else
    rm -f -- "$SSHD_DROPIN"
    log "移除未完成写入的 SSH drop-in。"
  fi
}

# 如果上次在替换 SSH 配置和验证配置之间被中断，重新执行时先验证当前配置。
# 当前配置无效时只回滚本脚本管理的 drop-in，不改动用户其它 SSH 配置。
recover_sshd_if_needed() {
  [[ -f "$SSHD_CHANGE_IN_PROGRESS" ]] || return 0

  if test_sshd_config; then
    log "SSH 配置校验通过，移除未完成标记。"
  else
    warn "检测到上次 SSH 配置未完成且当前 sshd 配置无效，开始回滚受管 drop-in。"
    rollback_sshd_dropin
    test_sshd_config || die "回滚本脚本管理的 SSH drop-in 后，sshd 配置仍然无效；请检查 /etc/ssh/sshd_config 和 /etc/ssh/sshd_config.d/ 中的非本脚本配置。"
  fi

  rm -f -- "$SSHD_CHANGE_IN_PROGRESS" "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP"
}

# 统一恢复入口：先清理临时文件，再处理上次中断留下的受管状态。
recover_previous_run() {
  local need_repair=0

  if [[ -d "$TMP_DIR" ]]; then
    find "$TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  fi
  if [[ -f "$INTERRUPT_MARKER" ]]; then
    log "检测到上次运行曾被中断，开始恢复检查。"
    rm -f -- "$INTERRUPT_MARKER"
    need_repair=1
  fi

  recover_swap_if_needed
  recover_sshd_if_needed

  if dpkg --audit 2>/dev/null | grep -q .; then
    need_repair=1
  fi

  if [[ "$need_repair" == "1" ]]; then
    repair_package_manager
  fi
}

atomic_install_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"
  local target_dir
  local temp_target

  target_dir="$(dirname "$target_file")"
  if [[ ! -d "$target_dir" ]]; then
    install -d -o "$owner" -g "$group" -m 0755 "$target_dir"
  fi
  temp_target="$(mktemp "${target_dir}/.${SCRIPT_NAME}.XXXXXX")"
  track_tempfile "$temp_target"
  install -o "$owner" -g "$group" -m "$mode" "$source_file" "$temp_target"
  mv -f -- "$temp_target" "$target_file"
}

run_apt() {
  local packages

  packages=(
    bash-completion
    ca-certificates
    chrony
    curl
    fail2ban
    file
    git
    gnupg
    htop
    jq
    kmod
    locales
    lsb-release
    openssh-server
    rsync
    sudo
    tar
    tmux
    tzdata
    ufw
    unattended-upgrades
    unzip
    vim
    wget
    zip
  )

  log "更新 apt 软件源索引。"
  apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 update

  if [[ "$BOOTSTRAP_FULL_UPGRADE" == "1" ]]; then
    log "升级系统已有软件包。"
    "${APT_GET[@]}" full-upgrade
  fi

  log "安装基础工具和安全组件。"
  "${APT_GET[@]}" install "${packages[@]}"
}

configure_hostname() {
  local temp_hosts

  [[ -n "$BOOTSTRAP_HOSTNAME" ]] || return 0

  log "设置主机名：$BOOTSTRAP_HOSTNAME"
  hostnamectl set-hostname "$BOOTSTRAP_HOSTNAME"

  # Debian 常用 127.0.1.1 绑定本机 hostname；同步它可以减少 sudo、
  # 本地解析和服务启动时的 hostname 警告。
  if [[ -f /etc/hosts ]]; then
    temp_hosts="$(mktemp_managed)"
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
        if (!updated) {
          print "127.0.1.1\t" host
        }
      }
    ' /etc/hosts >"$temp_hosts"
    atomic_install_file "$temp_hosts" /etc/hosts 0644 root root
  fi
}

configure_timezone() {
  if [[ ! -e "/usr/share/zoneinfo/$BOOTSTRAP_TIMEZONE" ]]; then
    die "时区不存在：$BOOTSTRAP_TIMEZONE"
  fi

  log "设置时区：$BOOTSTRAP_TIMEZONE"
  timedatectl set-timezone "$BOOTSTRAP_TIMEZONE" || true
  ln -sfn "/usr/share/zoneinfo/$BOOTSTRAP_TIMEZONE" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata >/dev/null
}

escape_ere() {
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

enable_locale_line() {
  local locale_name="$1"
  local escaped

  [[ -n "$locale_name" ]] || return 0
  escaped="$(escape_ere "$locale_name")"

  if grep -Eq "^${escaped}[[:space:]]+UTF-8$" /etc/locale.gen; then
    return
  fi

  if grep -Eq "^#[[:space:]]*${escaped}[[:space:]]+UTF-8$" /etc/locale.gen; then
    sed -i -E "s/^#[[:space:]]*(${escaped}[[:space:]]+UTF-8)$/\\1/" /etc/locale.gen
  else
    printf '%s UTF-8\n' "$locale_name" >>/etc/locale.gen
  fi
}

configure_locale() {
  local extra_locale
  local old_ifs

  log "配置默认 locale：$BOOTSTRAP_LOCALE"
  enable_locale_line "$BOOTSTRAP_LOCALE"

  # 额外 locale 允许用空格、逗号或换行分隔，方便一次声明多个常用语言环境。
  old_ifs="$IFS"
  IFS=$' ,\n\t'
  for extra_locale in $BOOTSTRAP_EXTRA_LOCALES; do
    enable_locale_line "$extra_locale"
  done
  IFS="$old_ifs"

  locale-gen
  update-locale "LANG=$BOOTSTRAP_LOCALE"
}

ensure_user() {
  log "确保用户 $BOOTSTRAP_USER 存在并加入 sudo 组。"

  if id "$BOOTSTRAP_USER" >/dev/null 2>&1; then
    usermod --append --groups sudo "$BOOTSTRAP_USER"
    usermod --shell /bin/bash "$BOOTSTRAP_USER"
  else
    useradd --create-home --shell /bin/bash --groups sudo "$BOOTSTRAP_USER"
  fi

  # 优先使用密码 hash，避免把明文密码写进 shell 历史。明文密码变量只作为
  # 临时救援手段保留，日志中不会打印实际密码。
  if [[ -n "$BOOTSTRAP_USER_PASSWORD_HASH" ]]; then
    log "为 $BOOTSTRAP_USER 设置密码 hash。"
    usermod --password "$BOOTSTRAP_USER_PASSWORD_HASH" "$BOOTSTRAP_USER"
  elif [[ -n "$BOOTSTRAP_USER_PASSWORD" ]]; then
    log "为 $BOOTSTRAP_USER 设置临时密码。"
    printf '%s:%s\n' "$BOOTSTRAP_USER" "$BOOTSTRAP_USER_PASSWORD" | chpasswd
  fi
}

build_authorized_keys_material() {
  local user_name
  local home_dir
  local authorized_keys
  local all_keys
  local cleaned_keys

  all_keys="$(mktemp_managed)"
  cleaned_keys="$(mktemp_managed)"

  # 合并显式传入的密钥、现有普通登录用户密钥、指定来源文件和 root 密钥。
  # 普通用户密钥排在 root 前面，并跳过 forced-command 密钥，避免 Azure
  # 等云镜像 root authorized_keys 中的提示命令被误当作可登录 shell 的密钥。
  [[ -n "$BOOTSTRAP_AUTHORIZED_KEYS" ]] && printf '%s\n' "$BOOTSTRAP_AUTHORIZED_KEYS" >>"$all_keys"

  {
    printf '%s\n' "$BOOTSTRAP_USER"
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] && printf '%s\n' "$SUDO_USER"
    awk -F: '($3 >= 1000 && $3 < 60000 && $1 != "root") { print $1 }' /etc/passwd
  } | awk 'NF && !seen[$0]++' | while read -r user_name; do
    home_dir="$(getent passwd "$user_name" 2>/dev/null | cut -d: -f6)"
    [[ -n "$home_dir" ]] || continue
    authorized_keys="${home_dir}/.ssh/authorized_keys"
    [[ -s "$authorized_keys" ]] && cat "$authorized_keys" >>"$all_keys"
  done

  [[ -s "$BOOTSTRAP_AUTHORIZED_KEYS_SOURCE" ]] && cat "$BOOTSTRAP_AUTHORIZED_KEYS_SOURCE" >>"$all_keys"

  home_dir="$(getent passwd root 2>/dev/null | cut -d: -f6)"
  if [[ -n "$home_dir" ]]; then
    authorized_keys="${home_dir}/.ssh/authorized_keys"
    [[ -s "$authorized_keys" ]] && cat "$authorized_keys" >>"$all_keys"
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
  local user_name="$1"
  local key_file="$2"
  local home_dir
  local group_name
  local ssh_dir
  local authorized_keys

  home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
  group_name="$(id -gn "$user_name")"
  ssh_dir="${home_dir}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"

  install -d -o "$user_name" -g "$group_name" -m 0700 "$ssh_dir"
  atomic_install_file "$key_file" "$authorized_keys" 0600 "$user_name" "$group_name"
  log "安装 $user_name 的 SSH authorized_keys。"
}

install_authorized_keys() {
  local cleaned_keys

  cleaned_keys="$(build_authorized_keys_material)"

  if [[ ! -s "$cleaned_keys" ]]; then
    warn "未发现 SSH 登录密钥；不修改 SSH 登录认证方式。"
    return
  fi

  install_authorized_keys_for_user root "$cleaned_keys"
  install_authorized_keys_for_user "$BOOTSTRAP_USER" "$cleaned_keys"
  AUTHORIZED_KEYS_INSTALLED=1
}

configure_sudoers() {
  local sudo_mode="$BOOTSTRAP_SUDO_NOPASSWD"
  local sudoers_file="/etc/sudoers.d/90-${BOOTSTRAP_USER}-bootstrap"
  local temp_sudoers

  if [[ "$sudo_mode" == "auto" ]]; then
    if [[ "$AUTHORIZED_KEYS_INSTALLED" == "1" ]]; then
      sudo_mode="1"
    else
      sudo_mode="0"
    fi
  fi

  if [[ "$sudo_mode" != "1" ]]; then
    rm -f -- "$sudoers_file"
    log "未启用 $BOOTSTRAP_USER 的免密码 sudo。"
    return
  fi

  # sudoers 必须先用 visudo 校验，再写入 /etc/sudoers.d，避免把 sudo 配坏。
  temp_sudoers="$(mktemp_managed)"
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$BOOTSTRAP_USER" >"$temp_sudoers"
  visudo -cf "$temp_sudoers" >/dev/null
  atomic_install_file "$temp_sudoers" "$sudoers_file" 0440 root root
  log "设置 $BOOTSTRAP_USER 的免密码 sudo。"
}

current_ssh_ports() {
  local sshd

  sshd="$(sshd_binary)"
  if [[ -x "$sshd" ]]; then
    "$sshd" -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true
  fi
  printf '%s\n' "$BOOTSTRAP_SSH_PORT"
}

configure_ufw() {
  local port
  local ports

  [[ "$BOOTSTRAP_ENABLE_UFW" == "1" ]] || return 0

  # 先放行当前 SSH 端口和目标 SSH 端口，再启用默认拒绝入站。
  # 这样即使脚本在改 SSH 端口前后被中断，也不会出现“防火墙已关门但 sshd
  # 还没监听新端口”的状态。
  log "配置 UFW：默认拒绝入站，放行 SSH。"
  ufw allow in on lo comment 'loopback'
  ufw allow out on lo comment 'loopback'
  ports="$(current_ssh_ports | awk 'NF && !seen[$1]++')"
  while read -r port; do
    [[ -n "$port" ]] || continue
    ufw limit "${port}/tcp" comment 'ssh'
  done <<<"$ports"

  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
}

reload_ssh_service() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl reload ssh || systemctl restart ssh
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    systemctl enable sshd >/dev/null 2>&1 || true
    systemctl reload sshd || systemctl restart sshd
  else
    warn "没有找到 ssh/sshd systemd 服务，已完成配置校验但未重载服务。"
  fi
}

begin_sshd_change() {
  rm -f -- "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP"
  if [[ -f "$SSHD_DROPIN" ]]; then
    cp -p -- "$SSHD_DROPIN" "$SSHD_DROPIN_BACKUP"
    touch "$SSHD_DROPIN_HAD_BACKUP"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ >"$SSHD_CHANGE_IN_PROGRESS"
}

finish_sshd_change() {
  rm -f -- "$SSHD_CHANGE_IN_PROGRESS" "$SSHD_DROPIN_BACKUP" "$SSHD_DROPIN_HAD_BACKUP"
}

configure_sshd() {
  local lockdown="$BOOTSTRAP_SSH_LOCKDOWN"
  local temp_sshd

  if [[ "$lockdown" == "auto" ]]; then
    if [[ "$AUTHORIZED_KEYS_INSTALLED" == "1" ]]; then
      lockdown="1"
    else
      lockdown="0"
    fi
  fi

  [[ "$lockdown" != "1" || "$AUTHORIZED_KEYS_INSTALLED" == "1" ]] || die "拒绝启用仅密钥 SSH 登录：未发现可用 SSH 登录密钥。"
  [[ "$lockdown" == "1" ]] && SSH_LOCKDOWN_ACTIVE=1

  # drop-in 只写本脚本关心的最小配置。其它 SSH 行为继续由系统默认配置决定，
  # 避免把脚本做成不可维护的大型 sshd_config 生成器。
  temp_sshd="$(mktemp_managed)"
  {
    printf '# 由 Debian 13 基础配置脚本管理。\n'
    printf 'Port %s\n' "$BOOTSTRAP_SSH_PORT"
    printf 'PubkeyAuthentication yes\n'
    printf 'MaxAuthTries 3\n'
    if [[ "$lockdown" == "1" ]]; then
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
  atomic_install_file "$temp_sshd" "$SSHD_DROPIN" 0644 root root
  if ! test_sshd_config; then
    warn "新的 SSH 配置未通过校验，回滚受管 drop-in。"
    rollback_sshd_dropin
    finish_sshd_change
    die "写入 $SSHD_DROPIN 后 sshd 配置校验失败；脚本已回滚受管 drop-in，请运行 sshd -t 检查 /etc/ssh/sshd_config 和 /etc/ssh/sshd_config.d/。"
  fi

  reload_ssh_service
  finish_sshd_change
}

configure_fail2ban() {
  local temp_jail

  [[ "$BOOTSTRAP_ENABLE_FAIL2BAN" == "1" ]] || return 0

  log "配置 fail2ban 的 sshd jail。"
  temp_jail="$(mktemp_managed)"
  {
    printf '[sshd]\n'
    printf 'enabled = true\n'
    printf 'port = %s\n' "$BOOTSTRAP_SSH_PORT"
    printf 'backend = systemd\n'
    printf 'maxretry = 5\n'
    printf 'findtime = 10m\n'
    printf 'bantime = 1h\n'
  } >"$temp_jail"

  atomic_install_file "$temp_jail" "$FAIL2BAN_JAIL" 0644 root root
  fail2ban-client -t >/dev/null
  systemctl enable --now fail2ban
}

configure_unattended_upgrades() {
  local temp_conf
  local temp_unattended
  local codename

  [[ "$BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES" == "1" ]] || return 0

  log "配置自动安全更新。"
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-trixie}")"
  temp_conf="$(mktemp_managed)"
  temp_unattended="$(mktemp_managed)"
  {
    printf 'APT::Periodic::Enable "1";\n'
    printf 'APT::Periodic::Update-Package-Lists "1";\n'
    printf 'APT::Periodic::Download-Upgradeable-Packages "1";\n'
    printf 'APT::Periodic::Unattended-Upgrade "1";\n'
    printf 'APT::Periodic::AutocleanInterval "7";\n'
  } >"$temp_conf"
  {
    printf 'Unattended-Upgrade::Origins-Pattern {\n'
    printf '  "origin=Debian,codename=%s,label=Debian";\n' "$codename"
    printf '  "origin=Debian,codename=%s-updates,label=Debian";\n' "$codename"
    printf '  "origin=Debian,codename=%s-security,label=Debian-Security";\n' "$codename"
    printf '};\n'
    printf 'Unattended-Upgrade::Remove-Unused-Dependencies "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    printf 'Unattended-Upgrade::SyslogEnable "true";\n'
  } >"$temp_unattended"

  atomic_install_file "$temp_conf" "$APT_AUTO_UPGRADES" 0644 root root
  atomic_install_file "$temp_unattended" "$APT_UNATTENDED_UPGRADES" 0644 root root
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
}

configure_bbr() {
  local temp_modules
  local temp_conf

  [[ "$BOOTSTRAP_ENABLE_BBR" == "1" ]] || return 0

  # Debian 13 内核通常已经提供 tcp_bbr，但干净系统不一定已经加载模块。
  # 先加载模块并写入开机加载配置，再设置拥塞控制和默认队列规则。
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    if ! modprobe tcp_bbr 2>/dev/null; then
      warn "当前内核无法加载 tcp_bbr，跳过 BBR 配置。"
      return 0
    fi
  fi

  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "tcp_bbr 已尝试加载，但内核仍未列出 bbr，跳过 BBR 配置。"
    return 0
  fi

  log "配置 TCP BBR。"
  temp_modules="$(mktemp_managed)"
  temp_conf="$(mktemp_managed)"
  printf 'tcp_bbr\n' >"$temp_modules"
  {
    printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
  } >"$temp_conf"

  atomic_install_file "$temp_modules" "$MODULES_BBR" 0644 root root
  atomic_install_file "$temp_conf" "$SYSCTL_BBR" 0644 root root
  sysctl -p "$SYSCTL_BBR" >/dev/null
  BBR_CONFIGURED=1
}

choose_auto_swap_size_mb() {
  local available_mb="$1"
  local mem_kb
  local mem_mb

  if [[ "$available_mb" =~ ^[0-9]+$ ]] && ((available_mb <= 1024)); then
    printf '128\n'
    return
  fi

  mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  [[ "$mem_kb" =~ ^[0-9]+$ && "$mem_kb" -gt 0 ]] || die "无法读取 /proc/meminfo 中的 MemTotal。"
  mem_mb=$(((mem_kb + 1023) / 1024))

  if ((mem_mb <= 2048)); then
    printf '%s\n' "$mem_mb"
  else
    printf '4096\n'
  fi
}

parse_swap_size_mb() {
  local raw="$1"
  local available_mb="${2:-}"
  local number
  local unit

  case "$raw" in
    auto)
      choose_auto_swap_size_mb "$available_mb"
      return
      ;;
    0)
      printf '0\n'
      return
      ;;
    *[Kk])
      number="${raw%?}"
      [[ "$number" =~ ^[0-9]+$ ]] || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' $(((number + 1023) / 1024))
      return
      ;;
    *[Mm] | *[Gg])
      unit="${raw: -1}"
      number="${raw%?}"
      [[ "$number" =~ ^[0-9]+$ ]] || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      if [[ "$unit" == "G" || "$unit" == "g" ]]; then
        printf '%s\n' $((number * 1024))
      else
        printf '%s\n' "$number"
      fi
      return
      ;;
    *)
      [[ "$raw" =~ ^[0-9]+$ ]] || die "BOOTSTRAP_SWAP_SIZE 格式不合法：$raw"
      printf '%s\n' "$raw"
      return
      ;;
  esac
}

swapfile_has_signature() {
  local swap_path="$1"

  file -b "$swap_path" 2>/dev/null | grep -qi 'swap file'
}

ensure_fstab_swap_entry() {
  local swap_path="$1"
  local temp_fstab

  temp_fstab="$(mktemp_managed)"
  if [[ -f /etc/fstab ]]; then
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
  local size_mb
  local swap_dir
  local available_mb
  local reserve_mb=256

  [[ "$BOOTSTRAP_ENABLE_SWAP" == "1" ]] || return 0

  swap_dir="$(dirname "$BOOTSTRAP_SWAPFILE")"
  install -d -o root -g root -m 0755 "$swap_dir"
  available_mb="$(df -Pm "$swap_dir" | awk 'NR == 2 { print $4 }')"
  [[ "$available_mb" =~ ^[0-9]+$ ]] || die "无法读取 ${swap_dir} 的可用磁盘空间。"

  size_mb="$(parse_swap_size_mb "$BOOTSTRAP_SWAP_SIZE" "$available_mb")"
  SWAP_SIZE_MB="$size_mb"
  if ((size_mb == 0)); then
    log "BOOTSTRAP_SWAP_SIZE=0，跳过 swapfile。"
    return
  fi

  if [[ "$BOOTSTRAP_SWAP_SIZE" == "auto" ]]; then
    log "自动选择 swapfile 大小：${size_mb}M。"
  fi

  if is_swap_active "$BOOTSTRAP_SWAPFILE"; then
    log "swapfile 处于启用状态：$BOOTSTRAP_SWAPFILE"
    ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
    return
  fi

  if [[ -e "$BOOTSTRAP_SWAPFILE" ]]; then
    [[ -f "$BOOTSTRAP_SWAPFILE" ]] || die "swapfile 目标存在但不是普通文件：$BOOTSTRAP_SWAPFILE"
    if swapfile_has_signature "$BOOTSTRAP_SWAPFILE"; then
      chmod 0600 "$BOOTSTRAP_SWAPFILE"
      swapon "$BOOTSTRAP_SWAPFILE"
      ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
      log "启用已有 swapfile：$BOOTSTRAP_SWAPFILE"
      return
    fi
    die "swapfile 目标已存在但不是 swap 文件，拒绝覆盖：$BOOTSTRAP_SWAPFILE"
  fi

  if [[ "$BOOTSTRAP_SWAP_SIZE" == "auto" && "$size_mb" -eq 128 && "$available_mb" -le 1024 ]]; then
    reserve_mb=0
  fi
  ((available_mb > size_mb + reserve_mb)) || die "磁盘空间不足，无法在 ${swap_dir} 创建 ${size_mb}M swapfile；请运行 df -h ${swap_dir} 检查可用空间。"

  # 从这里开始写入 in-progress 标记。若 fallocate/dd/mkswap/swapon 期间中断，
  # 下次运行会根据这个标记清理未完成的受管 swapfile，然后重新创建。
  printf 'swapfile=%s\n' "$BOOTSTRAP_SWAPFILE" >"$SWAP_IN_PROGRESS"
  printf 'size_mb=%s\n' "$size_mb" >>"$SWAP_IN_PROGRESS"

  log "创建 swapfile：${BOOTSTRAP_SWAPFILE}，大小 ${size_mb}M。"
  if ! fallocate -l "${size_mb}M" "$BOOTSTRAP_SWAPFILE" 2>/dev/null; then
    dd if=/dev/zero of="$BOOTSTRAP_SWAPFILE" bs=1M count="$size_mb" status=progress
  fi
  chmod 0600 "$BOOTSTRAP_SWAPFILE"
  mkswap "$BOOTSTRAP_SWAPFILE" >/dev/null
  swapon "$BOOTSTRAP_SWAPFILE"
  ensure_fstab_swap_entry "$BOOTSTRAP_SWAPFILE"
  rm -f -- "$SWAP_IN_PROGRESS"
}

enable_core_services() {
  log "启动基础服务。"
  systemctl enable --now chrony >/dev/null 2>&1 || warn "systemctl 在本机启用 chrony.service 时失败；请运行 systemctl status chrony.service 查看服务错误。"
  systemctl enable --now ssh >/dev/null 2>&1 || true
}

cleanup_apt() {
  log "清理 apt 缓存和不再需要的软件包。"
  "${APT_GET[@]}" autoremove
  apt-get clean
}

write_done_marker() {
  install -d -o root -g root -m 0755 "$STATE_DIR"
  {
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'user=%s\n' "$BOOTSTRAP_USER"
    printf 'ssh_lockdown=%s\n' "$SSH_LOCKDOWN_ACTIVE"
    printf 'ufw=%s\n' "$BOOTSTRAP_ENABLE_UFW"
    printf 'fail2ban=%s\n' "$BOOTSTRAP_ENABLE_FAIL2BAN"
    printf 'bbr=%s\n' "$BBR_CONFIGURED"
    printf 'swapfile=%s\n' "$BOOTSTRAP_SWAPFILE"
    printf 'swap_size_mb=%s\n' "$SWAP_SIZE_MB"
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
  printf '  UFW：%s\n' "$(enabled_label "$BOOTSTRAP_ENABLE_UFW")"
  printf '  fail2ban：%s\n' "$(enabled_label "$BOOTSTRAP_ENABLE_FAIL2BAN")"
  printf '  BBR：%s\n' "$(configured_label "$BBR_CONFIGURED")"
  printf '  swapfile：%s\n' "$BOOTSTRAP_SWAPFILE"
  printf '  状态文件：%s\n' "$DONE_MARKER"

  if [[ "$AUTHORIZED_KEYS_INSTALLED" != "1" ]]; then
    printf '\n未发现 root/%s/现有登录用户 authorized_keys，SSH 登录策略保持原状。\n' "$BOOTSTRAP_USER"
  fi
}

main() {
  case "${1:-}" in
    -h | --help)
      trap - ERR
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
  require_debian_13
  setup_state_dir
  recover_previous_run

  run_apt
  configure_hostname
  configure_timezone
  configure_locale
  ensure_user
  install_authorized_keys
  configure_sudoers
  configure_ufw
  configure_sshd
  configure_fail2ban
  configure_unattended_upgrades
  configure_bbr
  configure_swapfile
  enable_core_services
  cleanup_apt
  write_done_marker
  print_summary
}

main "$@"
