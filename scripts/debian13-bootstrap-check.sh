#!/usr/bin/env bash
# Debian 13 基础配置校验脚本。
#
# 校验目标与 debian13-bootstrap.sh 保持一致：系统版本、hollow 用户、
# SSH、sudo、UFW、fail2ban、自动安全更新、chrony、locale、timezone、
# BBR、swapfile、受管状态文件和中断恢复标记。
#
# 推荐运行方式：
#   sudo bash scripts/debian13-bootstrap-check.sh
#
# 非 root 运行时仍会输出结果，但部分需要读取受限文件或服务状态的项目
# 可能显示为 WARN。

set -Eeuo pipefail
IFS=$'\n\t'

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="/var/lib/hlwdot/debian13-bootstrap"
readonly DONE_MARKER="${STATE_DIR}/done.env"
readonly INTERRUPT_MARKER="${STATE_DIR}/interrupted"
readonly SWAP_IN_PROGRESS="${STATE_DIR}/swap-create.in-progress"
readonly SSHD_CHANGE_IN_PROGRESS="${STATE_DIR}/sshd-change.in-progress"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-hlwdot-bootstrap.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/10-hlwdot-sshd.conf"
readonly APT_AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
readonly APT_UNATTENDED_UPGRADES="/etc/apt/apt.conf.d/52hlwdot-unattended-upgrades"
readonly MODULES_BBR="/etc/modules-load.d/90-hlwdot-bbr.conf"
readonly SYSCTL_BBR="/etc/sysctl.d/90-hlwdot-bbr.conf"

STATUS_LIST=()
ITEM_LIST=()
DETAIL_LIST=()
ROOT_KEYS_PRESENT=0
ROOT_KEYS_VALID=0
HOLLOW_KEYS_PRESENT=0
HOLLOW_KEYS_VALID=0

log_location() {
  hostname 2>/dev/null || printf 'unknown'
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''
  C_GREEN=''
  C_RED=''
  C_YELLOW=''
  C_BLUE=''
  C_BOLD=''
fi

marker_value() {
  local key="$1"

  [[ -r "$DONE_MARKER" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 } END { exit found ? 0 : 1 }' "$DONE_MARKER"
}

MARKER_USER="$(marker_value user 2>/dev/null || true)"
MARKER_SWAPFILE="$(marker_value swapfile 2>/dev/null || true)"
MARKER_SWAP_SIZE_MB="$(marker_value swap_size_mb 2>/dev/null || true)"
MARKER_UFW="$(marker_value ufw 2>/dev/null || true)"
MARKER_FAIL2BAN="$(marker_value fail2ban 2>/dev/null || true)"
MARKER_SSH_LOCKDOWN="$(marker_value ssh_lockdown 2>/dev/null || true)"
MARKER_BBR="$(marker_value bbr 2>/dev/null || true)"

VERIFY_USER="${VERIFY_USER:-${BOOTSTRAP_USER:-${MARKER_USER:-hollow}}}"
VERIFY_TIMEZONE="${VERIFY_TIMEZONE:-${BOOTSTRAP_TIMEZONE:-Asia/Shanghai}}"
VERIFY_LOCALE="${VERIFY_LOCALE:-${BOOTSTRAP_LOCALE:-en_US.UTF-8}}"
VERIFY_EXTRA_LOCALES="${VERIFY_EXTRA_LOCALES:-${BOOTSTRAP_EXTRA_LOCALES:-zh_CN.UTF-8}}"
VERIFY_SSH_PORT="${VERIFY_SSH_PORT:-${BOOTSTRAP_SSH_PORT:-22}}"
VERIFY_SSH_LOCKDOWN="${VERIFY_SSH_LOCKDOWN:-${BOOTSTRAP_SSH_LOCKDOWN:-${MARKER_SSH_LOCKDOWN:-auto}}}"
VERIFY_SUDO_NOPASSWD="${VERIFY_SUDO_NOPASSWD:-${BOOTSTRAP_SUDO_NOPASSWD:-auto}}"
VERIFY_ENABLE_UFW="${VERIFY_ENABLE_UFW:-${BOOTSTRAP_ENABLE_UFW:-${MARKER_UFW:-1}}}"
VERIFY_ENABLE_FAIL2BAN="${VERIFY_ENABLE_FAIL2BAN:-${BOOTSTRAP_ENABLE_FAIL2BAN:-${MARKER_FAIL2BAN:-1}}}"
VERIFY_ENABLE_UNATTENDED_UPGRADES="${VERIFY_ENABLE_UNATTENDED_UPGRADES:-${BOOTSTRAP_ENABLE_UNATTENDED_UPGRADES:-1}}"
VERIFY_ENABLE_BBR="${VERIFY_ENABLE_BBR:-${BOOTSTRAP_ENABLE_BBR:-${MARKER_BBR:-1}}}"
VERIFY_ENABLE_SWAP="${VERIFY_ENABLE_SWAP:-${BOOTSTRAP_ENABLE_SWAP:-1}}"
VERIFY_SWAPFILE="${VERIFY_SWAPFILE:-${BOOTSTRAP_SWAPFILE:-${MARKER_SWAPFILE:-/swapfile}}}"
VERIFY_SWAP_SIZE="${VERIFY_SWAP_SIZE:-${BOOTSTRAP_SWAP_SIZE:-auto}}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

可配置环境变量：
  VERIFY_USER=hollow
  VERIFY_TIMEZONE=Asia/Shanghai
  VERIFY_LOCALE=en_US.UTF-8
  VERIFY_EXTRA_LOCALES=zh_CN.UTF-8
  VERIFY_SSH_PORT=22
  VERIFY_SSH_LOCKDOWN=auto              # auto、1、0
  VERIFY_SUDO_NOPASSWD=auto             # auto、1、0
  VERIFY_ENABLE_UFW=1
  VERIFY_ENABLE_FAIL2BAN=1
  VERIFY_ENABLE_UNATTENDED_UPGRADES=1
  VERIFY_ENABLE_BBR=1
  VERIFY_ENABLE_SWAP=1
  VERIFY_SWAPFILE=/swapfile
  VERIFY_SWAP_SIZE=auto                 # auto、0、1024M、2G

说明：
  - 校验 Debian 13 基础初始化结果。
  - 默认读取 bootstrap 完成标记中的用户、swapfile、UFW、fail2ban、BBR 和 SSH 策略。
  - 有 FAIL 时退出码为 1；无 FAIL 但有 WARN 时退出码为 2；全部通过时退出码为 0。
EOF
}

add_result() {
  local status="$1"
  local item="$2"
  local detail="$3"

  STATUS_LIST+=("$status")
  ITEM_LIST+=("$item")
  DETAIL_LIST+=("$detail")
}

status_label() {
  local status="$1"

  case "$status" in
    OK) printf '%sOK%s' "$C_GREEN" "$C_RESET" ;;
    FAIL) printf '%sFAIL%s' "$C_RED" "$C_RESET" ;;
    WARN) printf '%sWARN%s' "$C_YELLOW" "$C_RESET" ;;
    SKIP) printf '%sSKIP%s' "$C_BLUE" "$C_RESET" ;;
    *) printf '%s' "$status" ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

join_items() {
  local separator="$1"
  local output=''
  local item

  shift || true
  for item in "$@"; do
    if [[ -n "$output" ]]; then
      output+="$separator"
    fi
    output+="$item"
  done
  printf '%s' "$output"
}

passwd_entry_for_user() {
  local user="$1"

  if command_exists getent; then
    getent passwd "$user" 2>/dev/null || true
  elif [[ -r /etc/passwd ]]; then
    awk -F: -v user="$user" '$1 == user { print; exit }' /etc/passwd 2>/dev/null || true
  fi
}

is_root() {
  [[ "$EUID" -eq 0 ]]
}

check_file_mode_owner() {
  local path="$1"
  local expected_mode="$2"
  local expected_owner="$3"
  local expected_group="$4"
  local actual_mode
  local actual_owner
  local actual_group

  [[ -e "$path" ]] || return 1
  actual_mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  actual_owner="$(stat -c '%U' "$path" 2>/dev/null || true)"
  actual_group="$(stat -c '%G' "$path" 2>/dev/null || true)"

  [[ "$actual_mode" == "$expected_mode" && "$actual_owner" == "$expected_owner" && "$actual_group" == "$expected_group" ]]
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled() {
  systemctl is-enabled --quiet "$1" 2>/dev/null
}

sshd_binary() {
  if command_exists sshd; then
    command -v sshd
  elif [[ -x /usr/sbin/sshd ]]; then
    printf '/usr/sbin/sshd\n'
  else
    return 1
  fi
}

sshd_effective_config() {
  local sshd

  sshd="$(sshd_binary)" || return 1
  "$sshd" -T 2>/dev/null
}

sshd_value() {
  local key="$1"
  awk -v key="$key" '$1 == key { print $2; exit }'
}

sshd_allow_users_exact_root_hollow() {
  awk '
    $1 == "allowusers" {
      for (i = 2; i <= NF; i++) {
        if ($i == "root") root = 1
        else if ($i == "hollow") hollow = 1
        else extra = 1
      }
    }
    END {
      exit (root && hollow && !extra) ? 0 : 1
    }
  '
}

bool_enabled() {
  [[ "$1" == "1" ]]
}

check_authorized_keys_user() {
  local user="$1"
  local label="$2"
  local passwd_entry
  local home_dir
  local ssh_dir
  local auth_keys
  local group_name
  local present=0
  local valid=0

  passwd_entry="$(passwd_entry_for_user "$user")"
  if [[ -z "$passwd_entry" ]]; then
    add_result FAIL "$label 账号" "$user 不存在"
    return 0
  fi

  home_dir="$(cut -d: -f6 <<<"$passwd_entry")"
  ssh_dir="${home_dir}/.ssh"
  auth_keys="${ssh_dir}/authorized_keys"
  group_name="$(id -gn "$user" 2>/dev/null || true)"

  if [[ -d "$ssh_dir" ]]; then
    if check_file_mode_owner "$ssh_dir" 700 "$user" "$group_name"; then
      add_result OK "$label .ssh" "${ssh_dir}；${user}:${group_name} 700"
    else
      add_result FAIL "$label .ssh" "$(stat -c '%U:%G %a %n' "$ssh_dir" 2>/dev/null || printf '无法读取')"
    fi
  else
    add_result FAIL "$label .ssh" "缺少 $ssh_dir"
  fi

  if [[ -s "$auth_keys" ]]; then
    present=1
    if check_file_mode_owner "$auth_keys" 600 "$user" "$group_name"; then
      valid=1
      add_result OK "$label authorized_keys" "${auth_keys}；${user}:${group_name} 600"
    else
      add_result FAIL "$label authorized_keys" "$(stat -c '%U:%G %a %n' "$auth_keys" 2>/dev/null || printf '无法读取')"
    fi
  else
    add_result FAIL "$label authorized_keys" "缺少或为空：$auth_keys"
  fi

  case "$user" in
    root)
      ROOT_KEYS_PRESENT=$present
      ROOT_KEYS_VALID=$valid
      ;;
    hollow)
      HOLLOW_KEYS_PRESENT=$present
      HOLLOW_KEYS_VALID=$valid
      ;;
  esac

  return 0
}

parse_swap_size_mb() {
  local raw="$1"
  local available_mb="${2:-}"
  local number
  local unit
  local mem_kb
  local mem_mb

  case "$raw" in
    auto)
      if [[ "$MARKER_SWAP_SIZE_MB" =~ ^[0-9]+$ && "$MARKER_SWAP_SIZE_MB" -gt 0 ]]; then
        printf '%s\n' "$MARKER_SWAP_SIZE_MB"
        return
      fi
      if [[ "$available_mb" =~ ^[0-9]+$ ]] && ((available_mb <= 1024)); then
        printf '128\n'
        return
      fi
      mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || printf '0')"
      [[ "$mem_kb" =~ ^[0-9]+$ && "$mem_kb" -gt 0 ]] || return 1
      mem_mb=$(((mem_kb + 1023) / 1024))
      if ((mem_mb <= 2048)); then
        printf '%s\n' "$mem_mb"
      else
        printf '4096\n'
      fi
      ;;
    0)
      printf '0\n'
      ;;
    *[Kk])
      number="${raw%?}"
      [[ "$number" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' $(((number + 1023) / 1024))
      ;;
    *[Mm] | *[Gg])
      unit="${raw: -1}"
      number="${raw%?}"
      [[ "$number" =~ ^[0-9]+$ ]] || return 1
      if [[ "$unit" == "G" || "$unit" == "g" ]]; then
        printf '%s\n' $((number * 1024))
      else
        printf '%s\n' "$number"
      fi
      ;;
    *)
      [[ "$raw" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$raw"
      ;;
  esac
}

swap_active_bytes() {
  local swap_path="$1"

  swapon --bytes --noheadings --show=NAME,SIZE 2>/dev/null | awk -v path="$swap_path" '$1 == path { print $2; found = 1 } END { exit found ? 0 : 1 }'
}

swap_available_mb_for_check() {
  local swap_path="$1"
  local swap_dir
  local available_mb

  swap_dir="$(dirname "$swap_path")"
  [[ -d "$swap_dir" ]] || return 1
  available_mb="$(df -Pm "$swap_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$available_mb" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$available_mb"
}

fstab_has_swap_entry() {
  local swap_path="$1"

  [[ -r /etc/fstab ]] || return 3

  awk -v swap="$swap_path" '
    $1 == swap && $3 == "swap" {
      found = 1
      if ($4 ~ /(^|,)pri=/) pri = 1
    }
    END {
      if (!found) exit 1
      if (pri) exit 2
      exit 0
    }
  ' /etc/fstab
}

sysctl_value() {
  local key="$1"

  sysctl -n "$key" 2>/dev/null || true
}

check_runtime_context() {
  if is_root; then
    add_result OK "运行权限" "root；可读取全部受限配置"
  else
    add_result WARN "运行权限" "非 root；部分配置可能无法完整读取"
  fi
}

check_os() {
  local id=''
  local version=''

  if [[ -r /etc/os-release ]]; then
    id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
    version="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  fi

  if [[ "$id" == "debian" && "${version%%.*}" == "13" ]]; then
    add_result OK "系统版本" "Debian ${version}"
  else
    add_result FAIL "系统版本" "当前 ${id:-unknown} ${version:-unknown}，目标 Debian 13"
  fi
}

check_marker_state() {
  local pending=()

  if [[ -r "$DONE_MARKER" ]]; then
    add_result OK "完成标记" "$DONE_MARKER"
  else
    add_result FAIL "完成标记" "缺少 $DONE_MARKER"
  fi

  [[ -e "$INTERRUPT_MARKER" ]] && pending+=("interrupted")
  [[ -e "$SWAP_IN_PROGRESS" ]] && pending+=("swap-create.in-progress")
  [[ -e "$SSHD_CHANGE_IN_PROGRESS" ]] && pending+=("sshd-change.in-progress")

  if ((${#pending[@]} == 0)); then
    add_result OK "未完成标记" "无"
  else
    add_result FAIL "未完成标记" "$(join_items '、' "${pending[@]}")"
  fi
}

check_package_state() {
  local missing=()
  local packages=(
    bash-completion ca-certificates chrony curl fail2ban file git gnupg htop jq
    kmod locales lsb-release openssh-server rsync sudo tar tmux tzdata ufw
    unattended-upgrades unzip vim wget zip
  )
  local pkg
  local deb_count

  for pkg in "${packages[@]}"; do
    package_installed "$pkg" || missing+=("$pkg")
  done

  if ((${#missing[@]} == 0)); then
    add_result OK "基础软件包" "全部已安装"
  else
    add_result FAIL "基础软件包" "缺少：$(join_items '、' "${missing[@]}")"
  fi

  if dpkg --audit 2>/dev/null | grep -q .; then
    add_result FAIL "dpkg 状态" "存在未配置或异常软件包"
  else
    add_result OK "dpkg 状态" "正常"
  fi

  # apt 缓存只做状态提示，不作为硬性完成条件。目录不存在时直接记为 WARN，
  # 避免校验因为环境差异提前中断。
  if [[ -d /var/cache/apt/archives ]]; then
    deb_count="$(find /var/cache/apt/archives -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$deb_count" == "0" ]]; then
      add_result OK "apt 缓存" "无残留 .deb 包"
    else
      add_result WARN "apt 缓存" "/var/cache/apt/archives 中有 ${deb_count} 个 .deb 包"
    fi
  else
    add_result WARN "apt 缓存" "/var/cache/apt/archives 不存在"
  fi
}

check_user() {
  local passwd_entry
  local home_dir
  local shell_path

  passwd_entry="$(passwd_entry_for_user "$VERIFY_USER")"
  if [[ -z "$passwd_entry" ]]; then
    add_result FAIL "用户" "$VERIFY_USER 不存在"
    add_result FAIL "sudo 组" "无法检查"
    return
  fi

  home_dir="$(cut -d: -f6 <<<"$passwd_entry")"
  shell_path="$(cut -d: -f7 <<<"$passwd_entry")"

  if [[ -d "$home_dir" && "$shell_path" == "/bin/bash" ]]; then
    add_result OK "用户" "$VERIFY_USER；home=$home_dir；shell=$shell_path"
  else
    add_result FAIL "用户" "home=$home_dir；shell=$shell_path"
  fi

  if id -nG "$VERIFY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
    add_result OK "sudo 组" "$VERIFY_USER 属于 sudo"
  else
    add_result FAIL "sudo 组" "$VERIFY_USER 不属于 sudo"
  fi
}

check_sudoers() {
  local sudo_file="/etc/sudoers.d/90-${VERIFY_USER}-bootstrap"
  local expect="$VERIFY_SUDO_NOPASSWD"

  if [[ "$expect" == "auto" ]]; then
    if [[ "$ROOT_KEYS_VALID" == "1" && "$HOLLOW_KEYS_VALID" == "1" ]]; then
      expect="1"
    else
      expect="0"
    fi
  fi

  if [[ "$expect" == "0" ]]; then
    if [[ -e "$sudo_file" ]]; then
      add_result WARN "免密码 sudo" "存在 $sudo_file，但当前期望为停用"
    else
      add_result OK "免密码 sudo" "未配置受管 sudoers"
    fi
    return
  fi

  if [[ ! -r "$sudo_file" ]]; then
    add_result FAIL "免密码 sudo" "缺少或不可读：$sudo_file"
    return
  fi

  if grep -Eq "^${VERIFY_USER}[[:space:]]+ALL=\\(ALL:ALL\\)[[:space:]]+NOPASSWD:ALL$" "$sudo_file" && visudo -cf "$sudo_file" >/dev/null 2>&1; then
    add_result OK "免密码 sudo" "$sudo_file"
  else
    add_result FAIL "免密码 sudo" "$sudo_file 内容或语法异常"
  fi
}

check_sshd() {
  local cfg
  local value

  if [[ ! -r "$SSHD_DROPIN" ]]; then
    add_result FAIL "SSH drop-in" "缺少或不可读：$SSHD_DROPIN"
  else
    if grep -qx "Port ${VERIFY_SSH_PORT}" "$SSHD_DROPIN" && grep -qx 'MaxAuthTries 3' "$SSHD_DROPIN"; then
      add_result OK "SSH drop-in" "$SSHD_DROPIN"
    else
      add_result FAIL "SSH drop-in" "端口或 MaxAuthTries 不符合预期"
    fi
  fi

  if ! cfg="$(sshd_effective_config)"; then
    add_result FAIL "sshd 配置校验" "sshd -T 失败"
    return
  fi

  add_result OK "sshd 配置校验" "sshd -T 正常"

  value="$(sshd_value port <<<"$cfg")"
  if [[ "$value" == "$VERIFY_SSH_PORT" ]]; then
    add_result OK "SSH 端口" "$value"
  else
    add_result FAIL "SSH 端口" "当前 ${value:-unknown}，预期 $VERIFY_SSH_PORT"
  fi

  if [[ "$ROOT_KEYS_PRESENT" == "0" && "$HOLLOW_KEYS_PRESENT" == "0" ]]; then
    add_result SKIP "SSH 登录策略" "未配置 root/hollow authorized_keys"
  elif [[ "$ROOT_KEYS_VALID" != "1" || "$HOLLOW_KEYS_VALID" != "1" ]]; then
    add_result FAIL "SSH 登录策略" "root/hollow authorized_keys 未同时可用"
  elif [[ "$VERIFY_SSH_LOCKDOWN" == "0" ]]; then
    add_result OK "SSH 登录策略" "当前期望为保留系统默认登录策略"
  else
    local permit_root
    local password_auth
    local kbd_auth
    local pubkey_auth
    local auth_methods
    local max_auth

    permit_root="$(sshd_value permitrootlogin <<<"$cfg")"
    password_auth="$(sshd_value passwordauthentication <<<"$cfg")"
    kbd_auth="$(sshd_value kbdinteractiveauthentication <<<"$cfg")"
    pubkey_auth="$(sshd_value pubkeyauthentication <<<"$cfg")"
    auth_methods="$(sshd_value authenticationmethods <<<"$cfg")"
    max_auth="$(sshd_value maxauthtries <<<"$cfg")"

    if [[ ("$permit_root" == "prohibit-password" || "$permit_root" == "without-password") &&
      "$password_auth" == "no" &&
      "$kbd_auth" == "no" &&
      "$pubkey_auth" == "yes" &&
      "$auth_methods" == "publickey" &&
      "$max_auth" == "3" ]] &&
      sshd_allow_users_exact_root_hollow <<<"$cfg"; then
      add_result OK "SSH 登录策略" "AllowUsers root hollow；仅 publickey"
    else
      add_result FAIL "SSH 登录策略" "permitroot=$permit_root password=$password_auth kbd=$kbd_auth pubkey=$pubkey_auth methods=$auth_methods maxauth=$max_auth"
    fi
  fi

  if service_enabled ssh.service || service_enabled sshd.service; then
    add_result OK "SSH 服务 enabled" "enabled"
  else
    add_result FAIL "SSH 服务 enabled" "未启用"
  fi

  if service_active ssh.service || service_active sshd.service; then
    add_result OK "SSH 服务 active" "active"
  else
    add_result FAIL "SSH 服务 active" "未运行"
  fi
}

check_ufw() {
  local status_text

  if ! bool_enabled "$VERIFY_ENABLE_UFW"; then
    add_result SKIP "UFW" "当前期望为停用"
    return
  fi

  if ! command_exists ufw; then
    add_result FAIL "UFW" "ufw 命令不存在"
    return
  fi

  status_text="$(ufw status verbose 2>/dev/null || true)"
  if grep -qi '^Status: active' <<<"$status_text"; then
    add_result OK "UFW 状态" "active"
  else
    add_result FAIL "UFW 状态" "未启用"
  fi

  if grep -qi 'Default: deny (incoming), allow (outgoing)' <<<"$status_text"; then
    add_result OK "UFW 默认策略" "deny incoming / allow outgoing"
  else
    add_result FAIL "UFW 默认策略" "不符合预期"
  fi

  if grep -Eq "^${VERIFY_SSH_PORT}/tcp[[:space:]]+LIMIT" <<<"$status_text"; then
    add_result OK "UFW SSH 规则" "${VERIFY_SSH_PORT}/tcp LIMIT"
  else
    add_result FAIL "UFW SSH 规则" "缺少 ${VERIFY_SSH_PORT}/tcp LIMIT"
  fi
}

check_fail2ban() {
  if ! bool_enabled "$VERIFY_ENABLE_FAIL2BAN"; then
    add_result SKIP "fail2ban" "当前期望为停用"
    return
  fi

  if [[ -r "$FAIL2BAN_JAIL" ]] && grep -qx 'enabled = true' "$FAIL2BAN_JAIL" && grep -qx "port = ${VERIFY_SSH_PORT}" "$FAIL2BAN_JAIL"; then
    add_result OK "fail2ban 配置" "$FAIL2BAN_JAIL"
  else
    add_result FAIL "fail2ban 配置" "缺少或端口不匹配：$FAIL2BAN_JAIL"
  fi

  if service_enabled fail2ban.service; then
    add_result OK "fail2ban enabled" "enabled"
  else
    add_result FAIL "fail2ban enabled" "未启用"
  fi

  if service_active fail2ban.service; then
    add_result OK "fail2ban active" "active"
  else
    add_result FAIL "fail2ban active" "未运行"
  fi

  if command_exists fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
    add_result OK "fail2ban sshd jail" "可查询"
  else
    add_result WARN "fail2ban sshd jail" "无法查询 sshd jail"
  fi
}

check_unattended_upgrades() {
  local codename=''

  if ! bool_enabled "$VERIFY_ENABLE_UNATTENDED_UPGRADES"; then
    add_result SKIP "自动安全更新" "当前期望为停用"
    return
  fi

  if [[ -r /etc/os-release ]]; then
    codename="$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release)"
  fi
  [[ -n "$codename" ]] || codename="trixie"

  if [[ -r "$APT_AUTO_UPGRADES" ]] &&
    grep -qx 'APT::Periodic::Enable "1";' "$APT_AUTO_UPGRADES" &&
    grep -qx 'APT::Periodic::Update-Package-Lists "1";' "$APT_AUTO_UPGRADES" &&
    grep -qx 'APT::Periodic::Download-Upgradeable-Packages "1";' "$APT_AUTO_UPGRADES" &&
    grep -qx 'APT::Periodic::Unattended-Upgrade "1";' "$APT_AUTO_UPGRADES"; then
    add_result OK "自动安全更新配置" "$APT_AUTO_UPGRADES"
  else
    add_result FAIL "自动安全更新配置" "缺少或内容不符合预期"
  fi

  if [[ -r "$APT_UNATTENDED_UPGRADES" ]] &&
    grep -qx "  \"origin=Debian,codename=${codename},label=Debian\";" "$APT_UNATTENDED_UPGRADES" &&
    grep -qx "  \"origin=Debian,codename=${codename}-updates,label=Debian\";" "$APT_UNATTENDED_UPGRADES" &&
    grep -qx "  \"origin=Debian,codename=${codename}-security,label=Debian-Security\";" "$APT_UNATTENDED_UPGRADES" &&
    grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' "$APT_UNATTENDED_UPGRADES"; then
    add_result OK "自动升级策略" "$APT_UNATTENDED_UPGRADES"
  else
    add_result FAIL "自动升级策略" "缺少或内容不符合预期"
  fi

  if service_enabled unattended-upgrades.service; then
    add_result OK "unattended-upgrades enabled" "enabled"
  else
    add_result FAIL "unattended-upgrades enabled" "未启用"
  fi

  if service_enabled apt-daily.timer && service_enabled apt-daily-upgrade.timer; then
    add_result OK "apt 自动更新 timer" "apt-daily / apt-daily-upgrade"
  else
    add_result FAIL "apt 自动更新 timer" "未启用"
  fi
}

check_time_locale() {
  local timezone
  local lang
  local extra_locale
  local missing_extra=()
  local old_ifs

  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$timezone" == "$VERIFY_TIMEZONE" ]]; then
    add_result OK "时区" "$timezone"
  else
    add_result FAIL "时区" "当前 ${timezone:-unknown}，预期 $VERIFY_TIMEZONE"
  fi

  lang="$(awk -F= '$1 == "LANG" { gsub(/"/, "", $2); print $2 }' /etc/default/locale 2>/dev/null || true)"
  if [[ "$lang" == "$VERIFY_LOCALE" ]] && locale -a 2>/dev/null | grep -Fxq "${VERIFY_LOCALE%.UTF-8}.utf8"; then
    add_result OK "默认 locale" "$lang"
  else
    add_result FAIL "默认 locale" "当前 ${lang:-unknown}，预期 $VERIFY_LOCALE"
  fi

  old_ifs="$IFS"
  IFS=$' ,\n\t'
  for extra_locale in $VERIFY_EXTRA_LOCALES; do
    locale -a 2>/dev/null | grep -Fxq "${extra_locale%.UTF-8}.utf8" || missing_extra+=("$extra_locale")
  done
  IFS="$old_ifs"

  if ((${#missing_extra[@]} == 0)); then
    add_result OK "额外 locale" "${VERIFY_EXTRA_LOCALES:-无}"
  else
    add_result FAIL "额外 locale" "缺少：$(join_items '、' "${missing_extra[@]}")"
  fi

  if service_enabled chrony.service && service_active chrony.service; then
    add_result OK "chrony" "enabled / active"
  else
    add_result FAIL "chrony" "未启用或未运行"
  fi
}

check_bbr() {
  local available
  local qdisc
  local congestion

  if ! bool_enabled "$VERIFY_ENABLE_BBR"; then
    add_result SKIP "BBR" "当前期望为停用"
    return
  fi

  available="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
  if grep -qw bbr <<<"$available"; then
    add_result OK "BBR 内核支持" "$available"
  else
    add_result FAIL "BBR 内核支持" "tcp_available_congestion_control=${available:-unknown}"
  fi

  if [[ -r "$MODULES_BBR" ]] && grep -qx 'tcp_bbr' "$MODULES_BBR"; then
    add_result OK "BBR 模块配置" "$MODULES_BBR"
  else
    add_result FAIL "BBR 模块配置" "缺少或内容不符合预期：$MODULES_BBR"
  fi

  if [[ -r "$SYSCTL_BBR" ]] &&
    grep -qx 'net.core.default_qdisc = fq' "$SYSCTL_BBR" &&
    grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$SYSCTL_BBR"; then
    add_result OK "BBR 配置" "$SYSCTL_BBR"
  else
    add_result FAIL "BBR 配置" "缺少或内容不符合预期：$SYSCTL_BBR"
  fi

  qdisc="$(sysctl_value net.core.default_qdisc)"
  congestion="$(sysctl_value net.ipv4.tcp_congestion_control)"
  if [[ "$qdisc" == "fq" && "$congestion" == "bbr" ]]; then
    add_result OK "BBR 运行状态" "default_qdisc=fq；tcp_congestion_control=bbr"
  else
    add_result FAIL "BBR 运行状态" "default_qdisc=${qdisc:-unknown}；tcp_congestion_control=${congestion:-unknown}"
  fi
}

check_swap() {
  local expected_mb
  local available_mb=''
  local active_bytes
  local active_mb
  local mode

  if ! bool_enabled "$VERIFY_ENABLE_SWAP"; then
    add_result SKIP "swapfile" "当前期望为停用"
    return
  fi

  available_mb="$(swap_available_mb_for_check "$VERIFY_SWAPFILE" || true)"
  expected_mb="$(parse_swap_size_mb "$VERIFY_SWAP_SIZE" "$available_mb" || true)"
  if [[ -z "$expected_mb" ]]; then
    add_result WARN "swapfile 大小" "无法解析 VERIFY_SWAP_SIZE=$VERIFY_SWAP_SIZE"
    expected_mb=0
  fi

  if active_bytes="$(swap_active_bytes "$VERIFY_SWAPFILE")"; then
    active_mb=$(((active_bytes + 1024 * 1024 - 1) / 1024 / 1024))
    if ((expected_mb == 0 || active_mb >= expected_mb)); then
      add_result OK "swapfile active" "${VERIFY_SWAPFILE}；${active_mb}M"
    else
      add_result FAIL "swapfile active" "${active_mb}M，小于预期 ${expected_mb}M"
    fi
  else
    add_result FAIL "swapfile active" "$VERIFY_SWAPFILE 未启用"
  fi

  if [[ -f "$VERIFY_SWAPFILE" ]]; then
    mode="$(stat -c '%a' "$VERIFY_SWAPFILE" 2>/dev/null || true)"
    if [[ "$mode" == "600" ]]; then
      add_result OK "swapfile 权限" "${VERIFY_SWAPFILE} 600"
    else
      add_result FAIL "swapfile 权限" "${VERIFY_SWAPFILE} ${mode:-unknown}"
    fi
  else
    add_result FAIL "swapfile 文件" "缺少 $VERIFY_SWAPFILE"
  fi

  if fstab_has_swap_entry "$VERIFY_SWAPFILE"; then
    add_result OK "fstab swap" "${VERIFY_SWAPFILE} none swap sw 0 0"
  else
    case "$?" in
      2) add_result FAIL "fstab swap" "存在 pri=；预期使用默认优先级" ;;
      3) add_result FAIL "fstab swap" "/etc/fstab 缺少或不可读" ;;
      *) add_result FAIL "fstab swap" "缺少 $VERIFY_SWAPFILE 的 swap 条目" ;;
    esac
  fi
}

check_hostname() {
  local expected="${VERIFY_HOSTNAME:-${BOOTSTRAP_HOSTNAME:-${VPS_NODE_NAME:-}}}"
  local current

  [[ -n "$expected" ]] || {
    add_result SKIP "主机名" "未指定 VERIFY_HOSTNAME"
    return
  }

  current="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
  if [[ "$current" == "$expected" ]]; then
    add_result OK "主机名" "$current"
  else
    add_result FAIL "主机名" "当前 ${current:-unknown}，预期 $expected"
  fi

  if awk -v host="$expected" '$1 == "127.0.1.1" { for (i = 2; i <= NF; i++) if ($i == host) found = 1 } END { exit found ? 0 : 1 }' /etc/hosts 2>/dev/null; then
    add_result OK "hosts 主机名" "127.0.1.1 $expected"
  else
    add_result FAIL "hosts 主机名" "/etc/hosts 缺少 127.0.1.1 $expected"
  fi
}

print_table() {
  local i
  local ok=0
  local fail=0
  local warn=0
  local skip=0
  local status

  printf '%sDebian 13 基础配置校验%s\n' "$C_BOLD" "$C_RESET"
  printf '+-----+------------------------------+--------+------------------------------------------------------------+\n'
  printf '| No. | 项目                         | 结果   | 详情                                                       |\n'
  printf '+-----+------------------------------+--------+------------------------------------------------------------+\n'

  for i in "${!STATUS_LIST[@]}"; do
    status="${STATUS_LIST[$i]}"
    case "$status" in
      OK) ok=$((ok + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      WARN) warn=$((warn + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
    esac
    printf '| %3d | %-28s | %-13b | %s |\n' "$((i + 1))" "${ITEM_LIST[$i]}" "$(status_label "$status")" "${DETAIL_LIST[$i]}"
  done

  printf '+-----+------------------------------+--------+------------------------------------------------------------+\n'
  printf '汇总：%sOK=%d%s  %sFAIL=%d%s  %sWARN=%d%s  %sSKIP=%d%s\n' \
    "$C_GREEN" "$ok" "$C_RESET" \
    "$C_RED" "$fail" "$C_RESET" \
    "$C_YELLOW" "$warn" "$C_RESET" \
    "$C_BLUE" "$skip" "$C_RESET"

  if ((fail > 0)); then
    return 1
  fi
  if ((warn > 0)); then
    return 2
  fi
  return 0
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      return 0
      ;;
    '')
      ;;
    *)
      usage
      printf '[%s] ERROR：%s 在 %s 执行校验脚本时发生错误：未知参数：%s；请使用 --help 查看支持的参数。\n' "$SCRIPT_NAME" "$SCRIPT_NAME" "$(log_location)" "$1" >&2
      return 1
      ;;
  esac

  check_runtime_context
  check_os
  check_marker_state
  check_package_state
  check_user
  check_authorized_keys_user root "root"
  check_authorized_keys_user hollow "hollow"
  check_sudoers
  check_sshd
  check_ufw
  check_fail2ban
  check_unattended_upgrades
  check_time_locale
  check_bbr
  check_swap
  check_hostname
  print_table
}

main "$@"
