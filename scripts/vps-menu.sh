#!/usr/bin/env bash
# VPS 脚本交互菜单。
#
# 用一个简洁入口选择执行重装、基础初始化或只读校验脚本。

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HEADER_FILE="${SCRIPT_DIR}/vps-menu-head.txt"

MENU_LABELS=(
  "重装为 Debian 13"
  "Debian 13 基础初始化 + 校验"
  "Debian 13 基础初始化结果校验"
  "退出"
)
MENU_KEYS=("1" "2" "3" "0")
MENU_ACTIONS=("reinstall" "bootstrap" "check" "exit")

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_REV=$'\033[7m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_REV=''
  C_GREEN=''
  C_RED=''
  C_YELLOW=''
  C_CYAN=''
fi

log_error() {
  printf '%s[%s] 错误：%s%s\n' "$C_RED" "$SCRIPT_NAME" "$*" "$C_RESET" >&2
}

need_tty() {
  [[ -t 0 && -t 1 ]] || {
    log_error "需要交互式终端。通过 SSH 执行时请使用 ssh -tt root@主机。"
    exit 1
  }
}

script_path() {
  printf '%s/%s\n' "$SCRIPT_DIR" "$1"
}

run_script() {
  local file="$1"

  [[ -r "$file" ]] || {
    log_error "找不到脚本：$file"
    return 1
  }

  printf '\n%s执行：%s%s\n\n' "$C_DIM" "$file" "$C_RESET"
  bash "$file"
}

run_bootstrap_with_check() {
  local bootstrap_file
  local check_file
  local bootstrap_status=0

  bootstrap_file="$(script_path debian13-bootstrap.sh)"
  check_file="$(script_path debian13-bootstrap-check.sh)"

  run_script "$bootstrap_file" || bootstrap_status=$?

  printf '\n%s开始校验基础初始化结果。%s\n' "$C_DIM" "$C_RESET"
  run_script "$check_file" || true

  return "$bootstrap_status"
}

confirm_reinstall() {
  local answer=''
  local hostname_text

  hostname_text="$(hostname 2>/dev/null || printf 'unknown')"
  printf '\n%s危险操作：这会启动系统重装，当前系统数据会被覆盖。%s\n' "$C_RED" "$C_RESET"
  printf '当前主机：%s%s%s\n' "$C_YELLOW" "$hostname_text" "$C_RESET"
  printf '输入 %sDD%s 确认执行：' "$C_BOLD" "$C_RESET"
  IFS= read -r answer
  [[ "$answer" == "DD" ]]
}

print_header() {
  clear 2>/dev/null || true

  if [[ -r "$HEADER_FILE" ]]; then
    printf '%s' "$C_CYAN"
    sed -n '1,40p' "$HEADER_FILE"
    printf '%s' "$C_RESET"
  else
    printf '%sVPS 管理菜单%s\n' "$C_BOLD" "$C_RESET"
  fi

  printf '%s%s%s\n\n' "$C_DIM" "$(hostname 2>/dev/null || printf 'unknown')" "$C_RESET"
}

print_menu() {
  local selected="$1"
  local i

  printf '%s↑/↓ 移动，Enter 执行，数字直达，q 退出%s\n\n' "$C_DIM" "$C_RESET"

  for i in "${!MENU_LABELS[@]}"; do
    if [[ "$i" == "$selected" ]]; then
      printf '  %s%s> %-2s %s%s\n' "$C_REV" "$C_BOLD" "${MENU_KEYS[$i]}" "${MENU_LABELS[$i]}" "$C_RESET"
    else
      printf '    %-2s %s\n' "${MENU_KEYS[$i]}" "${MENU_LABELS[$i]}"
    fi
  done

  printf '\n'
}

pause_return() {
  local _

  printf '\n%s按 Enter 返回菜单%s' "$C_DIM" "$C_RESET"
  IFS= read -r _ || true
}

read_menu_key() {
  local key=''
  local rest=''

  IFS= read -r -s -n 1 key || return 1
  if [[ "$key" == $'\e' ]]; then
    IFS= read -r -s -n 2 -t 0.05 rest || true
    key+="$rest"
  fi

  printf '%s' "$key"
}

run_selected_action() {
  local selected="$1"
  local action="${MENU_ACTIONS[$selected]}"

  case "$action" in
    reinstall)
      if confirm_reinstall; then
        run_script "$(script_path dd2debian13.sh)"
        return 10
      fi
      printf '\n已取消。\n'
      pause_return
      ;;
    bootstrap)
      run_bootstrap_with_check || true
      pause_return
      ;;
    check)
      run_script "$(script_path debian13-bootstrap-check.sh)" || true
      pause_return
      ;;
    exit)
      printf '\n%s已退出。%s\n' "$C_GREEN" "$C_RESET"
      return 10
      ;;
  esac
}

main() {
  local selected=0
  local key=''
  local menu_count="${#MENU_LABELS[@]}"
  local action_status=0

  need_tty

  while true; do
    print_header
    print_menu "$selected"
    key="$(read_menu_key)" || break

    case "$key" in
      $'\e[A' | k | K)
        selected=$(((selected + menu_count - 1) % menu_count))
        ;;
      $'\e[B' | j | J)
        selected=$(((selected + 1) % menu_count))
        ;;
      '')
        action_status=0
        run_selected_action "$selected" || action_status=$?
        if [[ "$action_status" == "10" ]]; then
          break
        fi
        ;;
      1)
        selected=0
        action_status=0
        run_selected_action "$selected" || action_status=$?
        if [[ "$action_status" == "10" ]]; then
          break
        fi
        ;;
      2)
        selected=1
        action_status=0
        run_selected_action "$selected" || action_status=$?
        if [[ "$action_status" == "10" ]]; then
          break
        fi
        ;;
      3)
        selected=2
        action_status=0
        run_selected_action "$selected" || action_status=$?
        if [[ "$action_status" == "10" ]]; then
          break
        fi
        ;;
      0 | q | Q)
        printf '\n%s已退出。%s\n' "$C_GREEN" "$C_RESET"
        break
        ;;
      *)
        printf '\n%s无效选择。%s\n' "$C_YELLOW" "$C_RESET"
        pause_return
        ;;
    esac
  done
}

main "$@"
