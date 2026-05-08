#!/usr/bin/env bash
# VPS 主节点备份脚本。
#
# 支持 Headscale 和 k3s 主节点。备份先生成本地归档，再用指定 GPG
# 公钥加密，最后上传到 rclone 目标或 git 仓库。明文工作目录会在退出时清理。

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/vps-backup"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh" 2>/dev/null || . /usr/local/lib/hlwdot/vps-common.sh

PROFILE="${1:-}"
HOST_ID=''
TIMESTAMP=''
WORK_DIR=''
PLAIN_ARCHIVE=''
ENCRYPTED_ARCHIVE=''
CHECKSUM_FILE=''

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME headscale
  sudo bash $SCRIPT_NAME k3s

配置：
  读取 scripts/.env 或 /etc/hlwdot/vps.env。

必填：
  BACKUP_ENABLE=1
  BACKUP_GPG_EMAILS=you@example.com 或 BACKUP_GPG_RECIPIENTS=GPG_KEY_FINGERPRINT
  BACKUP_RCLONE_DESTS=remote:path 或 BACKUP_GIT_REPOS=git@server:repo.git
EOF
}

require_profile() {
  case "$PROFILE" in
    headscale | k3s) ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "未知备份类型：${PROFILE:-空}"
      ;;
  esac
}

import_backup_public_key() {
  local temp_key
  local email

  if [[ -n "${BACKUP_GPG_PUBLIC_KEY_FILE:-}" ]]; then
    [[ -r "$BACKUP_GPG_PUBLIC_KEY_FILE" ]] || die "无法读取 GPG 公钥文件：$BACKUP_GPG_PUBLIC_KEY_FILE"
    gpg --batch --import "$BACKUP_GPG_PUBLIC_KEY_FILE" >/dev/null
  fi

  if [[ -n "${BACKUP_GPG_PUBLIC_KEY_URL:-}" ]]; then
    temp_key="$(mktemp_managed)"
    download_file "$BACKUP_GPG_PUBLIC_KEY_URL" "$temp_key"
    gpg --batch --import "$temp_key" >/dev/null
  fi

  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    log "查找 GPG 公钥：$email"
    gpg --batch --auto-key-locate clear,wkd,keyserver \
      --keyserver hkps://keys.openpgp.org \
      --locate-keys "$email" >/dev/null
  done < <(split_words "${BACKUP_GPG_EMAILS:-}")
}

prepare_workdir() {
  HOST_ID="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  WORK_DIR="$(mktemp -d "${STATE_DIR}/tmp/${PROFILE}.${TIMESTAMP}.XXXXXX")"
  track_tempfile "$WORK_DIR"
  PLAIN_ARCHIVE="${WORK_DIR}/${HOST_ID}-${PROFILE}-${TIMESTAMP}.tar"
  ENCRYPTED_ARCHIVE="${BACKUP_LOCAL_DIR:-/var/backups/hlwdot}/${PROFILE}/${HOST_ID}-${PROFILE}-${TIMESTAMP}.tar.gpg"
  CHECKSUM_FILE="${ENCRYPTED_ARCHIVE}.sha256"

  install -d -o root -g root -m 0700 "$(dirname "$ENCRYPTED_ARCHIVE")"
  install -d -o root -g root -m 0700 "${WORK_DIR}/metadata"
}

tar_paths() {
  local archive="$1"
  shift

  tar --warning=no-file-changed --ignore-failed-read -C / -cpf "$archive" "$@" || {
    local status=$?
    [[ "$status" == "1" ]] || return "$status"
    return 0
  }
}

collect_headscale() {
  log "收集 Headscale 配置和状态。"

  if command_exists headscale; then
    headscale users list >"${WORK_DIR}/metadata/headscale-users.txt" 2>&1 || true
    headscale nodes list >"${WORK_DIR}/metadata/headscale-nodes.txt" 2>&1 || true
    headscale routes list >"${WORK_DIR}/metadata/headscale-routes.txt" 2>&1 || true
  fi
  systemctl status headscale --no-pager >"${WORK_DIR}/metadata/headscale-systemd.txt" 2>&1 || true

  tar_paths "$PLAIN_ARCHIVE" \
    etc/hlwdot \
    etc/headscale \
    var/lib/headscale \
    var/lib/tailscale
  tar -C "$WORK_DIR" --append -f "$PLAIN_ARCHIVE" metadata
}

collect_k3s() {
  local snapshot_dir="${WORK_DIR}/k3s-etcd-snapshots"

  log "收集 k3s 配置和状态。"
  install -d -o root -g root -m 0700 "$snapshot_dir"

  if command_exists k3s; then
    kubectl get nodes -o wide >"${WORK_DIR}/metadata/k3s-nodes.txt" 2>&1 || true
    k3s etcd-snapshot save \
      --name "hlwdot-${TIMESTAMP}" \
      --etcd-snapshot-dir "$snapshot_dir" \
      >"${WORK_DIR}/metadata/k3s-etcd-snapshot.txt" 2>&1 || true
  fi
  systemctl status k3s --no-pager >"${WORK_DIR}/metadata/k3s-systemd.txt" 2>&1 || true

  tar_paths "$PLAIN_ARCHIVE" \
    etc/hlwdot \
    etc/fluxcd \
    etc/rancher/k3s \
    var/lib/tailscale \
    var/lib/rancher/k3s/server
  tar -C "$WORK_DIR" --append -f "$PLAIN_ARCHIVE" metadata k3s-etcd-snapshots
}

encrypt_archive() {
  local recipient
  local gpg_args=()

  while IFS= read -r recipient; do
    [[ -n "$recipient" ]] || continue
    gpg_args+=(--recipient "$recipient")
  done < <(split_words "${BACKUP_GPG_RECIPIENTS:-}")
  while IFS= read -r recipient; do
    [[ -n "$recipient" ]] || continue
    gpg_args+=(--recipient "$recipient")
  done < <(split_words "${BACKUP_GPG_EMAILS:-}")

  ((${#gpg_args[@]} > 0)) || die "BACKUP_GPG_EMAILS 和 BACKUP_GPG_RECIPIENTS 均为空。"

  log "加密备份归档。"
  gpg --batch --yes --trust-model always \
    --output "$ENCRYPTED_ARCHIVE" \
    --encrypt "${gpg_args[@]}" \
    "$PLAIN_ARCHIVE"
  rm -f -- "$PLAIN_ARCHIVE"
  sha256sum "$ENCRYPTED_ARCHIVE" >"$CHECKSUM_FILE"
}

prune_local_backups() {
  local keep="${BACKUP_KEEP_LOCAL:-7}"
  local dir

  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  ((keep > 0)) || return 0
  dir="$(dirname "$ENCRYPTED_ARCHIVE")"
  find "$dir" -maxdepth 1 -type f -name '*.tar.gpg' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk -v keep="$keep" 'NR > keep { print substr($0, index($0, $2)) }' |
    while IFS= read -r old_file; do
      [[ -n "$old_file" ]] || continue
      rm -f -- "$old_file" "${old_file}.sha256"
    done
}

upload_rclone() {
  local dest

  [[ -n "${BACKUP_RCLONE_DESTS:-}" ]] || return 0
  command_exists rclone || die "已配置 BACKUP_RCLONE_DESTS，但缺少 rclone。"

  while IFS= read -r dest; do
    [[ -n "$dest" ]] || continue
    log "上传到 rclone：$dest"
    rclone copy "$ENCRYPTED_ARCHIVE" "$dest"
    rclone copy "$CHECKSUM_FILE" "$dest"
  done < <(split_words "$BACKUP_RCLONE_DESTS")
}

upload_git() {
  local repo
  local branch="${BACKUP_GIT_BRANCH:-main}"
  local subdir="${BACKUP_GIT_SUBDIR:-vps-backups}"
  local worktree
  local target_dir

  [[ -n "${BACKUP_GIT_REPOS:-}" ]] || return 0
  command_exists git || die "已配置 BACKUP_GIT_REPOS，但缺少 git。"

  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    worktree="$(mktemp -d "${STATE_DIR}/tmp/git.${PROFILE}.${TIMESTAMP}.XXXXXX")"
    track_tempfile "$worktree"
    log "写入 git 备份仓库：$repo"
    git clone --depth=1 --branch "$branch" "$repo" "$worktree"
    target_dir="${worktree}/${subdir}/${HOST_ID}/${PROFILE}"
    install -d -m 0755 "$target_dir"
    install -m 0600 "$ENCRYPTED_ARCHIVE" "$target_dir/"
    install -m 0644 "$CHECKSUM_FILE" "$target_dir/"
    git -C "$worktree" add "$subdir"
    git -C "$worktree" commit -m "backup: ${HOST_ID} ${PROFILE} ${TIMESTAMP}" || true
    git -C "$worktree" push origin "$branch"
  done < <(split_words "$BACKUP_GIT_REPOS")
}

main() {
  require_profile
  prepare_vps_run

  BACKUP_ENABLE="${BACKUP_ENABLE:-0}"
  BACKUP_LOCAL_DIR="${BACKUP_LOCAL_DIR:-/var/backups/hlwdot}"
  validate_backup_config
  [[ "$BACKUP_ENABLE" == "1" ]] || die "备份未启用：BACKUP_ENABLE=0"
  begin_run

  import_backup_public_key
  prepare_workdir

  case "$PROFILE" in
    headscale) collect_headscale ;;
    k3s) collect_k3s ;;
  esac

  encrypt_archive
  upload_rclone
  upload_git
  prune_local_backups

  log "备份完成：$ENCRYPTED_ARCHIVE"
  finish_run
}

main "$@"
