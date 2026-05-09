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

require_backup_path() {
  local path="$1"

  [[ -e "$path" ]] || die "缺少备份路径：$path"
}

config_value() {
  local file="$1"
  local key="$2"

  [[ -r "$file" ]] || return 1
  awk -v key="$key" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file"
}

config_section_value() {
  local file="$1"
  local section="$2"
  local key="$3"

  [[ -r "$file" ]] || return 1
  awk -v section="$section" -v key="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $0 ~ "^" section ":[[:space:]]*($|#)" {
      in_section = 1
      next
    }
    in_section && /^[^[:space:]#][^:]*:/ {
      exit
    }
    in_section && $0 ~ "^[[:space:]]+" key "[[:space:]]*:" {
      sub("^[[:space:]]+" key "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$file"
}

config_nested_section_value() {
  local file="$1"
  local parent="$2"
  local child="$3"
  local key="$4"

  [[ -r "$file" ]] || return 1
  awk -v parent="$parent" -v child="$child" -v key="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $0 ~ "^" parent ":[[:space:]]*($|#)" {
      in_parent = 1
      in_child = 0
      next
    }
    in_parent && /^[^[:space:]#][^:]*:/ {
      exit
    }
    in_parent && $0 ~ "^[[:space:]]+" child ":[[:space:]]*($|#)" {
      in_child = 1
      next
    }
    in_child && $0 ~ "^[[:space:]]+" key "[[:space:]]*:" {
      sub("^[[:space:]]+" key "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
    in_child && $0 ~ "^[[:space:]]+[^[:space:]#][^:]*:" {
      if ($0 !~ "^[[:space:]]+" child ":[[:space:]]*($|#)") {
        in_child = 0
      }
    }
  ' "$file"
}

config_bool_true() {
  local file="$1"
  local key="$2"
  local value

  value="$(config_value "$file" "$key" 2>/dev/null || true)"
  [[ "$value" == "true" || "$value" == "1" ]]
}

copy_external_dump_file() {
  local source_file="$1"
  local target_file="$2"
  local label="$3"

  [[ -n "$source_file" ]] || die "${label} 使用外部数据库时必须设置对应的 dump 文件路径。"
  [[ -r "$source_file" ]] || die "无法读取外部数据库 dump：$source_file"
  install -m 0600 "$source_file" "$target_file"
}

dump_postgres_uri() {
  local uri="$1"
  local output="$2"
  local label="$3"

  [[ -n "$uri" ]] || die "${label} 使用 PostgreSQL 时必须设置数据库连接 URI。"
  command_exists pg_dump || die "缺少 pg_dump，无法备份 ${label} PostgreSQL 数据库。"
  PGDATABASE="$uri" pg_dump --format=custom --file "$output"
  chmod 0600 "$output"
}

headscale_database_type() {
  local config="/etc/headscale/config.yaml"
  local value

  value="$(config_value "$config" db_type 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(config_section_value "$config" database type 2>/dev/null || true)"
  case "$value" in
    postgres | postgresql) printf 'postgres\n' ;;
    sqlite | sqlite3 | '') printf 'sqlite\n' ;;
    *) die "不支持的 Headscale database type：$value" ;;
  esac
}

headscale_sqlite_db_path() {
  local config="/etc/headscale/config.yaml"
  local value

  value="$(config_value "$config" db_path 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(config_nested_section_value "$config" database sqlite path 2>/dev/null || true)"
  [[ -n "$value" ]] || value="$(config_section_value "$config" sqlite path 2>/dev/null || true)"
  [[ -n "$value" ]] || value="/var/lib/headscale/db.sqlite"
  printf '%s\n' "$value"
}

collect_headscale_database() {
  local db_type
  local sqlite_db
  local sqlite_backup="${WORK_DIR}/metadata/headscale-db.sqlite"

  db_type="$(headscale_database_type)"
  printf 'database_type=%s\n' "$db_type" >"${WORK_DIR}/metadata/headscale-database.env"

  case "$db_type" in
    sqlite)
      sqlite_db="$(headscale_sqlite_db_path)"
      require_backup_path "$sqlite_db"
      command_exists sqlite3 || die "缺少 sqlite3，无法创建 Headscale SQLite 在线备份。"
      sqlite3 "$sqlite_db" ".backup '${sqlite_backup}'"
      chmod 0600 "$sqlite_backup"
      printf 'sqlite_path=%s\n' "$sqlite_db" >>"${WORK_DIR}/metadata/headscale-database.env"
      ;;
    postgres)
      if [[ -n "${BACKUP_HEADSCALE_POSTGRES_DUMP_FILE:-}" ]]; then
        copy_external_dump_file "$BACKUP_HEADSCALE_POSTGRES_DUMP_FILE" \
          "${WORK_DIR}/metadata/headscale-postgres.dump" \
          "Headscale PostgreSQL"
      else
        dump_postgres_uri "${BACKUP_HEADSCALE_POSTGRES_URI:-}" \
          "${WORK_DIR}/metadata/headscale-postgres.dump" \
          "Headscale"
      fi
      ;;
  esac
}

k3s_datastore_endpoint() {
  local config="/etc/rancher/k3s/config.yaml"
  local args="${K3S_SERVER_EXTRA_ARGS:-}"
  local value

  value="${K3S_DATASTORE_ENDPOINT:-}"
  [[ -n "$value" ]] || value="$(config_value "$config" datastore-endpoint 2>/dev/null || true)"
  if [[ -z "$value" && "$args" =~ --datastore-endpoint=([^[:space:]]+) ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ -z "$value" && "$args" =~ --datastore-endpoint[[:space:]]+([^[:space:]]+) ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "$value"
}

collect_k3s_sqlite_database() {
  local sqlite_db="/var/lib/rancher/k3s/server/db/state.db"
  local sqlite_backup="${WORK_DIR}/metadata/k3s-state.db"

  require_backup_path /var/lib/rancher/k3s/server/db
  if [[ -f "$sqlite_db" ]]; then
    command_exists sqlite3 || die "缺少 sqlite3，无法创建 k3s SQLite 在线备份。"
    sqlite3 "$sqlite_db" ".backup '${sqlite_backup}'"
    chmod 0600 "$sqlite_backup"
    printf 'sqlite_path=%s\n' "$sqlite_db" >>"${WORK_DIR}/metadata/k3s-datastore.env"
  fi
}

collect_k3s_datastore() {
  local config="/etc/rancher/k3s/config.yaml"
  local snapshot_dir="${WORK_DIR}/k3s-etcd-snapshots"
  local datastore_endpoint

  datastore_endpoint="$(k3s_datastore_endpoint)"

  if [[ -n "$datastore_endpoint" ]]; then
    printf 'datastore=external\n' >"${WORK_DIR}/metadata/k3s-datastore.env"
    copy_external_dump_file "${BACKUP_K3S_DATASTORE_DUMP_FILE:-}" \
      "${WORK_DIR}/metadata/k3s-external-datastore.dump" \
      "k3s external datastore"
    return 0
  fi

  if config_bool_true "$config" cluster-init || [[ -d /var/lib/rancher/k3s/server/db/etcd ]]; then
    printf 'datastore=embedded-etcd\n' >"${WORK_DIR}/metadata/k3s-datastore.env"
    install -d -o root -g root -m 0700 "$snapshot_dir"
    k3s etcd-snapshot save \
      --name "hlwdot-${TIMESTAMP}" \
      --etcd-snapshot-dir "$snapshot_dir" \
      >"${WORK_DIR}/metadata/k3s-etcd-snapshot.txt" 2>&1 || die "k3s etcd snapshot 创建失败；详情见 metadata/k3s-etcd-snapshot.txt。"
    return 0
  fi

  printf 'datastore=sqlite\n' >"${WORK_DIR}/metadata/k3s-datastore.env"
  collect_k3s_sqlite_database
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
  require_backup_path /etc/headscale
  require_backup_path /var/lib/headscale

  if command_exists headscale; then
    headscale users list >"${WORK_DIR}/metadata/headscale-users.txt" 2>&1 || true
    headscale nodes list >"${WORK_DIR}/metadata/headscale-nodes.txt" 2>&1 || true
    headscale routes list >"${WORK_DIR}/metadata/headscale-routes.txt" 2>&1 || true
  fi
  systemctl status headscale --no-pager >"${WORK_DIR}/metadata/headscale-systemd.txt" 2>&1 || true
  collect_headscale_database

  tar_paths "$PLAIN_ARCHIVE" \
    etc/hlwdot \
    etc/headscale \
    var/lib/headscale \
    var/lib/tailscale
  tar -C "$WORK_DIR" --append -f "$PLAIN_ARCHIVE" metadata
}

collect_k3s() {
  log "收集 k3s 配置和状态。"
  require_backup_path /etc/rancher/k3s
  require_backup_path /var/lib/rancher/k3s/server
  command_exists k3s || die "找不到 k3s 命令，无法确认 k3s 主节点状态。"

  k3s kubectl get nodes -o wide >"${WORK_DIR}/metadata/k3s-nodes.txt" 2>&1 || true
  systemctl status k3s --no-pager >"${WORK_DIR}/metadata/k3s-systemd.txt" 2>&1 || true
  collect_k3s_datastore

  tar_paths "$PLAIN_ARCHIVE" \
    etc/hlwdot \
    etc/fluxcd \
    etc/rancher/k3s \
    var/lib/tailscale \
    var/lib/rancher/k3s/server
  if [[ -d "${WORK_DIR}/k3s-etcd-snapshots" ]]; then
    tar -C "$WORK_DIR" --append -f "$PLAIN_ARCHIVE" metadata k3s-etcd-snapshots
  else
    tar -C "$WORK_DIR" --append -f "$PLAIN_ARCHIVE" metadata
  fi
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

rclone_dest_file() {
  local dest="$1"
  local source_file="$2"
  local base

  [[ -n "$dest" ]] || die "BACKUP_RCLONE_DESTS 包含空目标。"
  base="$(basename "$source_file")"

  if [[ "$dest" == "/" ]]; then
    printf '/%s\n' "$base"
  elif [[ "$dest" == *: ]]; then
    printf '%s%s\n' "$dest" "$base"
  else
    dest="${dest%/}"
    if [[ -z "$dest" ]]; then
      printf '/%s\n' "$base"
    else
      printf '%s/%s\n' "$dest" "$base"
    fi
  fi
}

upload_rclone() {
  local dest
  local archive_dest
  local checksum_dest

  [[ -n "${BACKUP_RCLONE_DESTS:-}" ]] || return 0
  command_exists rclone || die "已配置 BACKUP_RCLONE_DESTS，但缺少 rclone。"

  while IFS= read -r dest; do
    [[ -n "$dest" ]] || continue
    log "上传到 rclone：$dest"
    archive_dest="$(rclone_dest_file "$dest" "$ENCRYPTED_ARCHIVE")"
    checksum_dest="$(rclone_dest_file "$dest" "$CHECKSUM_FILE")"
    rclone copyto "$ENCRYPTED_ARCHIVE" "$archive_dest"
    rclone copyto "$CHECKSUM_FILE" "$checksum_dest"
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
    git -C "$worktree" config user.name "${BACKUP_GIT_USER_NAME:-VPS Backup}"
    git -C "$worktree" config user.email "${BACKUP_GIT_USER_EMAIL:-backup@${HOST_ID}}"
    target_dir="${worktree}/${subdir}/${HOST_ID}/${PROFILE}"
    install -d -m 0755 "$target_dir"
    install -m 0600 "$ENCRYPTED_ARCHIVE" "$target_dir/"
    install -m 0644 "$CHECKSUM_FILE" "$target_dir/"
    git -C "$worktree" add "$subdir"
    if git -C "$worktree" diff --cached --quiet; then
      log "git 备份仓库没有新增变更：$repo"
    else
      git -C "$worktree" commit -m "backup: ${HOST_ID} ${PROFILE} ${TIMESTAMP}"
      git -C "$worktree" push origin "$branch"
    fi
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
