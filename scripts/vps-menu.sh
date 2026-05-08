#!/usr/bin/env bash
# VPS 脚本交互菜单。
#
# 用一个入口选择执行重装、基础初始化或校验脚本。

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HEADER_FILE="${SCRIPT_DIR}/vps-menu-head.txt"

MENU_LABELS=(
  "重装为 Debian 13"
  "Debian 13 基础初始化 + 校验"
  "Debian 13 基础初始化结果校验"
  "部署 Headscale 主节点"
  "签发 Headscale 接入密钥"
  "接入 Headscale 网络"
  "Alpine 节点接入 Headscale 网络"
  "部署 k3s 主节点"
  "全流程：作为子节点并入网络"
  "部署 k3s 子节点"
  "部署 Flux GitOps"
  "查看 k3s 节点 token"
  "Headscale 主节点备份"
  "k3s 主节点备份"
  "部署 NodeGet hollow-net 探针页"
  "退出"
)
MENU_GROUPS=(
  "系统重装"
  "初始化配置"
  "初始化配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
  "并入集群配置"
)
MENU_HINTS=(
  "启动 Debian 13 重装"
  "首次配置并立即校验"
  "校验基础初始化结果"
  "安装 Headscale、配置 DNS/Caddy、按配置接入本机"
  "生成新节点接入密钥"
  "当前节点加入 Headscale 网络"
  "接入 Headscale 网络，可上报分流路由"
  "检查 Headscale 网络，部署 server、记录 token、部署 GitOps"
  "建议先执行系统重装；初始化、接入 Headscale 网络、部署 k3s 子节点"
  "检查 Headscale 网络，部署 agent"
  "安装 Flux 控制面"
  "输出 worker 接入 token"
  "加密并上传 Headscale 状态"
  "加密并上传 k3s/Flux 状态"
  "Alpine NAT LXC：NodeGet Server + StatusShow + Cloudflare Tunnel"
  "返回 shell"
)
MENU_KEYS=("1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f" "0")
MENU_ACTIONS=("reinstall" "bootstrap" "check" "headscale-main-node" "headscale-authkey" "headscale-client" "alpine-hollow-client" "k3s-main-node" "k3s-worker-full-node" "k3s-worker-node" "flux-gitops" "k3s-token" "backup-headscale" "backup-k3s" "nodeget-statusshow" "exit")

ITEM_LINES=()
MENU_END_LINE=1

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
  printf '%s[%s] ERROR：%s 在 %s 执行菜单时发生错误：%s%s\n' "$C_RED" "$SCRIPT_NAME" "$SCRIPT_NAME" "$(hostname 2>/dev/null || printf 'unknown')" "$*" "$C_RESET" >&2
}

cursor_hide() {
  printf '\033[?25l'
}

cursor_show() {
  printf '\033[?25h\033[0m'
}

cleanup_terminal() {
  cursor_show
}

need_tty() {
  [[ -t 0 && -t 1 ]] || {
    log_error "需要交互式终端。通过 SSH 执行时请使用 ssh -tt root@主机。"
    exit 1
  }
}

header_rows() {
  if [[ -r "$HEADER_FILE" ]]; then
    sed -n '1,40p' "$HEADER_FILE" | wc -l | tr -d ' '
  else
    printf '1\n'
  fi
}

script_path() {
  printf '%s/%s\n' "$SCRIPT_DIR" "$1"
}

run_script() {
  local file="$1"
  shift || true

  [[ -r "$file" ]] || {
    log_error "找不到脚本：$file"
    return 1
  }

  printf '\n%s执行：%s %s%s\n\n' "$C_DIM" "$file" "$*" "$C_RESET"
  bash "$file" "$@"
}

run_sh_script() {
  local file="$1"
  shift || true

  [[ -r "$file" ]] || {
    log_error "找不到脚本：$file"
    return 1
  }

  printf '\n%s执行：%s %s%s\n\n' "$C_DIM" "$file" "$*" "$C_RESET"
  sh "$file" "$@"
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

confirm_action() {
  local label="$1"
  local answer=''
  local hostname_text

  hostname_text="$(hostname 2>/dev/null || printf 'unknown')"
  printf '\n准备执行：%s%s%s\n' "$C_BOLD" "$label" "$C_RESET"
  printf '当前主机：%s%s%s\n' "$C_YELLOW" "$hostname_text" "$C_RESET"
  printf '输入 %sy%s 确认，直接 Enter 取消：' "$C_BOLD" "$C_RESET"
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

print_header() {
  if [[ -r "$HEADER_FILE" ]]; then
    printf '%s' "$C_CYAN"
    sed -n '1,40p' "$HEADER_FILE"
    printf '%s' "$C_RESET"
  else
    printf '%sVPS 管理菜单%s\n' "$C_BOLD" "$C_RESET"
  fi

  printf '%s%s%s\n\n' "$C_DIM" "$(hostname 2>/dev/null || printf 'unknown')" "$C_RESET"
}

print_item() {
  local index="$1"
  local selected="$2"

  if [[ "$selected" == "1" ]]; then
    printf '  %s%s> %s  %s%s\n' "$C_REV" "$C_BOLD" "${MENU_KEYS[$index]}" "${MENU_LABELS[$index]}" "$C_RESET"
    printf '     %s%s%s\n' "$C_DIM" "${MENU_HINTS[$index]}" "$C_RESET"
  else
    printf '    %s  %s\n' "${MENU_KEYS[$index]}" "${MENU_LABELS[$index]}"
    printf '     %s%s%s\n' "$C_DIM" "${MENU_HINTS[$index]}" "$C_RESET"
  fi
}

draw_menu() {
  local selected="$1"
  local i
  local current_group='__none__'
  local line

  ITEM_LINES=()
  line=1

  printf '\033[2J\033[H'
  print_header
  line=$((line + $(header_rows) + 2))

  printf '%s↑/↓ 移动，Enter 执行，数字/字母直达，q 退出%s\n\n' "$C_DIM" "$C_RESET"
  line=$((line + 2))

  for i in "${!MENU_LABELS[@]}"; do
    if [[ "${MENU_GROUPS[$i]}" != "$current_group" ]]; then
      current_group="${MENU_GROUPS[$i]}"
      printf '  %s%s%s\n' "$C_CYAN" "$current_group" "$C_RESET"
      line=$((line + 1))
    fi
    ITEM_LINES[$i]="$line"
    print_item "$i" "$([[ "$i" == "$selected" ]] && printf 1 || printf 0)"
    line=$((line + 2))
  done

  MENU_END_LINE="$line"
  printf '\n'
  printf '\033[%d;1H' "$MENU_END_LINE"
}

repaint_item() {
  local index="$1"
  local selected="$2"
  local line="${ITEM_LINES[$index]}"

  printf '\033[%d;1H\033[2K' "$line"
  if [[ "$selected" == "1" ]]; then
    printf '  %s%s> %s  %s%s' "$C_REV" "$C_BOLD" "${MENU_KEYS[$index]}" "${MENU_LABELS[$index]}" "$C_RESET"
  else
    printf '    %s  %s' "${MENU_KEYS[$index]}" "${MENU_LABELS[$index]}"
  fi

  printf '\033[%d;1H\033[2K' "$((line + 1))"
  printf '     %s%s%s' "$C_DIM" "${MENU_HINTS[$index]}" "$C_RESET"
  printf '\033[%d;1H' "$MENU_END_LINE"
}

prepare_action_area() {
  printf '\033[%d;1H\033[J' "$MENU_END_LINE"
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
  local label="${MENU_LABELS[$selected]}"

  prepare_action_area
  cursor_show

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
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_bootstrap_with_check || true
      pause_return
      ;;
    headscale-main-node)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path headscale-main-node.sh)" || true
      pause_return
      ;;
    check)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path debian13-bootstrap-check.sh)" || true
      pause_return
      ;;
    cloudflare-dns)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path cloudflare-dns.sh)" || true
      pause_return
      ;;
    headscale-server)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path headscale-server.sh)" || true
      pause_return
      ;;
    headscale-authkey)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path headscale-authkey.sh)" || true
      pause_return
      ;;
    headscale-client)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path headscale-client.sh)" || true
      pause_return
      ;;
    alpine-hollow-client)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_sh_script "$(script_path alpine-hollow-client.sh)" || true
      pause_return
      ;;
    k3s-server)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-server.sh)" || true
      pause_return
      ;;
    k3s-main-node)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-main-node.sh)" || true
      pause_return
      ;;
    k3s-worker-node)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-worker-node.sh)" || true
      pause_return
      ;;
    k3s-worker-full-node)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-worker-full-node.sh)" || true
      pause_return
      ;;
    flux-gitops)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path flux-gitops.sh)" || true
      pause_return
      ;;
    k3s-token)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-token.sh)" || true
      pause_return
      ;;
    k3s-agent)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path k3s-agent.sh)" || true
      pause_return
      ;;
    backup-headscale)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path vps-backup.sh)" headscale || true
      pause_return
      ;;
    backup-k3s)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_script "$(script_path vps-backup.sh)" k3s || true
      pause_return
      ;;
    nodeget-statusshow)
      confirm_action "$label" || {
        printf '\n已取消。\n'
        pause_return
        return 0
      }
      run_sh_script "$(script_path nodeget-statusshow.sh)" || true
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
  local old_selected=0
  local i
  local matched=0

  need_tty
  trap cleanup_terminal EXIT
  trap 'cleanup_terminal; exit 130' INT TERM
  cursor_hide
  draw_menu "$selected"

  while true; do
    key="$(read_menu_key)" || break

    case "$key" in
      $'\e[A' | k | K)
        old_selected="$selected"
        selected=$(((selected + menu_count - 1) % menu_count))
        repaint_item "$old_selected" 0
        repaint_item "$selected" 1
        ;;
      $'\e[B' | j | J)
        old_selected="$selected"
        selected=$(((selected + 1) % menu_count))
        repaint_item "$old_selected" 0
        repaint_item "$selected" 1
        ;;
      '')
        action_status=0
        run_selected_action "$selected" || action_status=$?
        if [[ "$action_status" == "10" ]]; then
          break
        fi
        cursor_hide
        draw_menu "$selected"
        ;;
      0 | q | Q)
        prepare_action_area
        printf '\n%s已退出。%s\n' "$C_GREEN" "$C_RESET"
        break
        ;;
      *)
        matched=0
        for i in "${!MENU_KEYS[@]}"; do
          if [[ "$key" == "${MENU_KEYS[$i]}" || "$key" == "${MENU_KEYS[$i]^^}" ]]; then
            selected="$i"
            matched=1
            break
          fi
        done
        if [[ "$matched" == "1" ]]; then
          action_status=0
          run_selected_action "$selected" || action_status=$?
          if [[ "$action_status" == "10" ]]; then
            break
          fi
          cursor_hide
          draw_menu "$selected"
        else
          prepare_action_area
          cursor_show
          printf '\n%s无效选择。%s\n' "$C_YELLOW" "$C_RESET"
          pause_return
          cursor_hide
          draw_menu "$selected"
        fi
        ;;
    esac
  done
}

main "$@"
