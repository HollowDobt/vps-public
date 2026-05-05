#!/usr/bin/env bash
# Headscale 服务端部署脚本。
#
# 从 Headscale GitHub release 安装 Debian 包，写入基础配置，
# 启动 systemd 服务，并按需配置加密备份定时器。

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/headscale-server"
readonly HEADSCALE_CONFIG="/etc/headscale/config.yaml"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

HEADSCALE_VERSION="${HEADSCALE_VERSION:-stable}"
HEADSCALE_SERVER_HOSTNAME="${HEADSCALE_SERVER_HOSTNAME:-}"
HEADSCALE_SERVER_URL="${HEADSCALE_SERVER_URL:-}"
HEADSCALE_LISTEN_ADDR="${HEADSCALE_LISTEN_ADDR:-127.0.0.1:8080}"
HEADSCALE_METRICS_LISTEN_ADDR="${HEADSCALE_METRICS_LISTEN_ADDR:-127.0.0.1:9090}"
HEADSCALE_GRPC_LISTEN_ADDR="${HEADSCALE_GRPC_LISTEN_ADDR:-127.0.0.1:50443}"
HEADSCALE_DNS_BASE_DOMAIN="${HEADSCALE_DNS_BASE_DOMAIN:-auto}"
HEADSCALE_USER="${HEADSCALE_USER:-hollow}"
HEADSCALE_CREATE_PREAUTHKEY="${HEADSCALE_CREATE_PREAUTHKEY:-0}"
HEADSCALE_PREAUTH_REUSABLE="${HEADSCALE_PREAUTH_REUSABLE:-0}"
HEADSCALE_PREAUTH_EXPIRATION="${HEADSCALE_PREAUTH_EXPIRATION:-24h}"
HEADSCALE_CONFIG_APPEND_FILE="${HEADSCALE_CONFIG_APPEND_FILE:-}"
HEADSCALE_UFW_ALLOW="${HEADSCALE_UFW_ALLOW:-0}"
HEADSCALE_UFW_PORTS="${HEADSCALE_UFW_PORTS:-8080/tcp}"
HEADSCALE_ENABLE_CADDY="${HEADSCALE_ENABLE_CADDY:-auto}"
HEADSCALE_CADDYFILE="${HEADSCALE_CADDYFILE:-/etc/caddy/Caddyfile}"
HEADSCALE_CADDY_EMAIL="${HEADSCALE_CADDY_EMAIL:-}"
HEADSCALE_CADDY_UFW_ALLOW="${HEADSCALE_CADDY_UFW_ALLOW:-1}"
CLOUDFLARE_HEADSCALE_DNS="${CLOUDFLARE_HEADSCALE_DNS:-1}"
CLOUDFLARE_DNS_TARGET_IPV4="${CLOUDFLARE_DNS_TARGET_IPV4:-auto}"
CLOUDFLARE_DNS_PROXIED="${CLOUDFLARE_DNS_PROXIED:-0}"
CLOUDFLARE_DNS_TTL="${CLOUDFLARE_DNS_TTL:-120}"

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

配置：
  复制 scripts/.env.example 为 scripts/.env，按实际域名设置：
    HEADSCALE_SERVER_URL=https://headscale.example.com
  也可以设置 HEADSCALE_SERVER_URL=auto，并提供 CLOUDFLARE_ZONE，
  脚本会使用 headscale.\$CLOUDFLARE_ZONE。

常用变量：
  HEADSCALE_VERSION=stable
  HEADSCALE_LISTEN_ADDR=127.0.0.1:8080
  HEADSCALE_DNS_BASE_DOMAIN=auto
  HEADSCALE_USER=hollow
  HEADSCALE_ENABLE_CADDY=auto
  HEADSCALE_CREATE_PREAUTHKEY=0
  BACKUP_ENABLE=1
  BACKUP_GPG_EMAILS=you@example.com
  BACKUP_RCLONE_DESTS=remote:path
EOF
}

looks_like_ipv4() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
}

url_scheme() {
  local value="$1"

  printf '%s\n' "${value%%://*}"
}

listen_port() {
  local value="$1"

  value="${value##*:}"
  printf '%s\n' "$value"
}

auto_headscale_host() {
  local host

  if [[ -n "$HEADSCALE_SERVER_HOSTNAME" ]]; then
    printf '%s\n' "$HEADSCALE_SERVER_HOSTNAME"
    return 0
  fi
  if [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
    printf 'headscale.%s\n' "${CLOUDFLARE_ZONE%.}"
    return 0
  fi

  host="$(hostname -f 2>/dev/null || true)"
  [[ -n "$host" && "$host" == *.* ]] || host="$(hostname 2>/dev/null || true)"
  [[ -n "$host" && "$host" == *.* ]] || die "HEADSCALE_SERVER_URL=auto 时需要设置 HEADSCALE_SERVER_HOSTNAME 或 CLOUDFLARE_ZONE。"
  printf '%s\n' "$host"
}

resolve_defaults() {
  local host
  local scheme
  local parent_domain

  case "$HEADSCALE_SERVER_URL" in
    '' | auto | https://headscale.example.com | http://headscale.example.com)
      host="$(auto_headscale_host)"
      HEADSCALE_SERVER_URL="https://${host}"
      ;;
  esac

  case "$HEADSCALE_DNS_BASE_DOMAIN" in
    '' | auto | example.com)
      if [[ -n "${CLOUDFLARE_ZONE:-}" ]]; then
        HEADSCALE_DNS_BASE_DOMAIN="net.${CLOUDFLARE_ZONE%.}"
      else
        host="$(url_host "$HEADSCALE_SERVER_URL")"
        parent_domain="${host#*.}"
        if [[ "$parent_domain" == "$host" || -z "$parent_domain" ]]; then
          HEADSCALE_DNS_BASE_DOMAIN="net.internal"
        else
          HEADSCALE_DNS_BASE_DOMAIN="net.${parent_domain}"
        fi
      fi
      ;;
  esac

  scheme="$(url_scheme "$HEADSCALE_SERVER_URL")"
  if [[ "$HEADSCALE_ENABLE_CADDY" == "auto" ]]; then
    host="$(url_host "$HEADSCALE_SERVER_URL")"
    if [[ "$scheme" == "https" && "$host" != "localhost" && "$host" != "127.0.0.1" ]] && ! looks_like_ipv4 "$host"; then
      HEADSCALE_ENABLE_CADDY=1
    else
      HEADSCALE_ENABLE_CADDY=0
    fi
  fi
}

validate_input() {
  [[ -n "$HEADSCALE_SERVER_URL" ]] || die "请在 .env 中设置 HEADSCALE_SERVER_URL。"
  [[ "$HEADSCALE_SERVER_URL" =~ ^https?:// ]] || die "HEADSCALE_SERVER_URL 必须以 http:// 或 https:// 开头。"
  validate_bool HEADSCALE_CREATE_PREAUTHKEY "$HEADSCALE_CREATE_PREAUTHKEY"
  validate_bool HEADSCALE_PREAUTH_REUSABLE "$HEADSCALE_PREAUTH_REUSABLE"
  validate_bool HEADSCALE_UFW_ALLOW "$HEADSCALE_UFW_ALLOW"
  validate_bool HEADSCALE_ENABLE_CADDY "$HEADSCALE_ENABLE_CADDY"
  validate_bool HEADSCALE_CADDY_UFW_ALLOW "$HEADSCALE_CADDY_UFW_ALLOW"
  validate_bool CLOUDFLARE_HEADSCALE_DNS "$CLOUDFLARE_HEADSCALE_DNS"
  validate_bool CLOUDFLARE_DNS_PROXIED "$CLOUDFLARE_DNS_PROXIED"
  if [[ "$CLOUDFLARE_HEADSCALE_DNS" == "1" && "$CLOUDFLARE_DNS_PROXIED" == "1" ]]; then
    die "Headscale DNS 记录不能开启 Cloudflare 代理，请设置 CLOUDFLARE_DNS_PROXIED=0。"
  fi
  [[ "$HEADSCALE_DNS_BASE_DOMAIN" == *.* ]] || die "HEADSCALE_DNS_BASE_DOMAIN 必须是 FQDN。"
  [[ "$HEADSCALE_DNS_BASE_DOMAIN" != "$(url_host "$HEADSCALE_SERVER_URL")" ]] || die "HEADSCALE_DNS_BASE_DOMAIN 不能与 HEADSCALE_SERVER_URL 的域名相同。"
  validate_backup_config
}

persist_headscale_config() {
  persist_env_value HEADSCALE_SERVER_URL "$HEADSCALE_SERVER_URL"
  persist_env_value HEADSCALE_LISTEN_ADDR "$HEADSCALE_LISTEN_ADDR"
  persist_env_value HEADSCALE_METRICS_LISTEN_ADDR "$HEADSCALE_METRICS_LISTEN_ADDR"
  persist_env_value HEADSCALE_GRPC_LISTEN_ADDR "$HEADSCALE_GRPC_LISTEN_ADDR"
  persist_env_value HEADSCALE_DNS_BASE_DOMAIN "$HEADSCALE_DNS_BASE_DOMAIN"
  persist_env_value HEADSCALE_USER "$HEADSCALE_USER"
  persist_env_value HEADSCALE_ENABLE_CADDY "$HEADSCALE_ENABLE_CADDY"
}

debian_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) printf 'amd64\n' ;;
    arm64) printf 'arm64\n' ;;
    armhf) printf 'armv7\n' ;;
    *) die "当前架构不在脚本支持范围内：$(dpkg --print-architecture)" ;;
  esac
}

resolve_headscale_version() {
  local tag

  if [[ "$HEADSCALE_VERSION" != "latest" && "$HEADSCALE_VERSION" != "stable" ]]; then
    printf '%s\n' "${HEADSCALE_VERSION#v}"
    return
  fi

  tag="$(curl -fsSL --retry 3 https://api.github.com/repos/juanfont/headscale/releases |
    jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "无法获取 Headscale 最新版本。"
  printf '%s\n' "${tag#v}"
}

install_headscale_package() {
  local version
  local arch
  local deb_file
  local url

  apt_install ca-certificates curl jq wget gnupg lsb-release

  version="$(resolve_headscale_version)"
  arch="$(debian_arch)"
  deb_file="$(mktemp_managed)"
  url="https://github.com/juanfont/headscale/releases/download/v${version}/headscale_${version}_linux_${arch}.deb"

  log "下载 Headscale：v${version} ${arch}"
  download_file "$url" "$deb_file"
  dpkg -i "$deb_file" || apt-get -y -o DPkg::Lock::Timeout=120 -f install
}

set_yaml_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temp_file

  temp_file="$(mktemp_managed)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*" key ":" && done == 0 {
      print key ": " value
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print key ": " value
      }
    }
  ' "$file" >"$temp_file"
  atomic_install_file "$temp_file" "$file" 0640 root headscale
}

set_dns_base_domain() {
  local file="$1"
  local value="$2"
  local temp_file

  temp_file="$(mktemp_managed)"
  awk -v value="$value" '
    BEGIN { in_dns = 0; done = 0 }
    /^dns:[[:space:]]*$/ {
      in_dns = 1
      print
      next
    }
    in_dns && /^[^[:space:]#][^:]*:/ {
      if (!done) {
        print "  base_domain: " value
        done = 1
      }
      in_dns = 0
    }
    in_dns && /^[[:space:]]+base_domain:/ {
      print "  base_domain: " value
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print "dns:"
        print "  base_domain: " value
      }
    }
  ' "$file" >"$temp_file"
  atomic_install_file "$temp_file" "$file" 0640 root headscale
}

download_config_example_if_needed() {
  local version
  local temp_config
  local url

  [[ -s "$HEADSCALE_CONFIG" ]] && return 0

  version="$(resolve_headscale_version)"
  temp_config="$(mktemp_managed)"
  url="https://raw.githubusercontent.com/juanfont/headscale/v${version}/config-example.yaml"
  log "下载 Headscale 配置模板。"
  download_file "$url" "$temp_config"
  atomic_install_file "$temp_config" "$HEADSCALE_CONFIG" 0640 root headscale
}

append_config_fragment() {
  local temp_config

  [[ -n "$HEADSCALE_CONFIG_APPEND_FILE" ]] || return 0
  [[ -r "$HEADSCALE_CONFIG_APPEND_FILE" ]] || die "无法读取 HEADSCALE_CONFIG_APPEND_FILE：$HEADSCALE_CONFIG_APPEND_FILE"

  temp_config="$(mktemp_managed)"
  awk '
    /^# BEGIN HLWDOT LOCAL APPEND$/ { skip = 1; next }
    /^# END HLWDOT LOCAL APPEND$/ { skip = 0; next }
    !skip { print }
  ' "$HEADSCALE_CONFIG" >"$temp_config"
  {
    printf '\n# BEGIN HLWDOT LOCAL APPEND\n'
    cat "$HEADSCALE_CONFIG_APPEND_FILE"
    printf '\n# END HLWDOT LOCAL APPEND\n'
  } >>"$temp_config"

  atomic_install_file "$temp_config" "$HEADSCALE_CONFIG" 0640 root headscale
}

configure_headscale() {
  local quoted_url
  local quoted_listen
  local quoted_metrics
  local quoted_grpc

  install -d -o headscale -g headscale -m 0750 /var/lib/headscale
  download_config_example_if_needed

  quoted_url="$(yaml_quote "$HEADSCALE_SERVER_URL")"
  quoted_listen="$(yaml_quote "$HEADSCALE_LISTEN_ADDR")"
  quoted_metrics="$(yaml_quote "$HEADSCALE_METRICS_LISTEN_ADDR")"
  quoted_grpc="$(yaml_quote "$HEADSCALE_GRPC_LISTEN_ADDR")"

  set_yaml_key "$HEADSCALE_CONFIG" server_url "$quoted_url"
  set_yaml_key "$HEADSCALE_CONFIG" listen_addr "$quoted_listen"
  set_yaml_key "$HEADSCALE_CONFIG" metrics_listen_addr "$quoted_metrics"
  set_yaml_key "$HEADSCALE_CONFIG" grpc_listen_addr "$quoted_grpc"
  set_dns_base_domain "$HEADSCALE_CONFIG" "$HEADSCALE_DNS_BASE_DOMAIN"
  append_config_fragment

  headscale configtest
  systemctl enable --now headscale
  log "Headscale 服务已启动。"
}

install_caddy_package() {
  local temp_key
  local temp_keyring
  local temp_list

  if command_exists caddy; then
    log "Caddy 已安装。"
    return 0
  fi

  apt_install debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
  temp_key="$(mktemp_managed)"
  temp_keyring="$(mktemp_managed)"
  temp_list="$(mktemp_managed)"

  log "配置 Caddy 软件源。"
  download_file https://dl.cloudsmith.io/public/caddy/stable/gpg.key "$temp_key"
  rm -f -- "$temp_keyring"
  gpg --dearmor -o "$temp_keyring" "$temp_key"
  atomic_install_file "$temp_keyring" /usr/share/keyrings/caddy-stable-archive-keyring.gpg 0644 root root

  download_file https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt "$temp_list"
  atomic_install_file "$temp_list" /etc/apt/sources.list.d/caddy-stable.list 0644 root root
  apt_install caddy
}

headscale_caddy_upstream() {
  local port

  port="$(listen_port "$HEADSCALE_LISTEN_ADDR")"
  [[ "$port" =~ ^[0-9]+$ ]] || die "无法从 HEADSCALE_LISTEN_ADDR 解析端口：$HEADSCALE_LISTEN_ADDR"
  printf '127.0.0.1:%s\n' "$port"
}

configure_caddy_if_needed() {
  local host
  local upstream
  local temp_file

  [[ "$HEADSCALE_ENABLE_CADDY" == "1" ]] || return 0

  host="$(url_host "$HEADSCALE_SERVER_URL")"
  [[ -n "$host" ]] || die "无法从 HEADSCALE_SERVER_URL 解析域名。"
  ! looks_like_ipv4 "$host" || die "HEADSCALE_ENABLE_CADDY=1 时 HEADSCALE_SERVER_URL 必须使用域名。"

  install_caddy_package
  upstream="$(headscale_caddy_upstream)"
  temp_file="$(mktemp_managed)"

  if [[ -r "$HEADSCALE_CADDYFILE" ]]; then
    awk '
      /^# BEGIN HLWDOT HEADSCALE$/ { skip = 1; next }
      /^# END HLWDOT HEADSCALE$/ { skip = 0; next }
      !skip { print }
    ' "$HEADSCALE_CADDYFILE" >"$temp_file"
  else
    : >"$temp_file"
  fi

  {
    printf '\n# BEGIN HLWDOT HEADSCALE\n'
    printf '%s {\n' "$host"
    if [[ -n "$HEADSCALE_CADDY_EMAIL" ]]; then
      printf '  tls %s\n' "$HEADSCALE_CADDY_EMAIL"
    fi
    printf '  reverse_proxy %s\n' "$upstream"
    printf '}\n'
    printf '# END HLWDOT HEADSCALE\n'
  } >>"$temp_file"

  atomic_install_file "$temp_file" "$HEADSCALE_CADDYFILE" 0644 root root
  caddy validate --config "$HEADSCALE_CADDYFILE"
  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
  log "Caddy 反向代理已配置：${host} -> ${upstream}"
}

ensure_headscale_user() {
  if headscale users list -o json 2>/dev/null | jq -e --arg user "$HEADSCALE_USER" '.[] | select(.name == $user)' >/dev/null 2>&1 ||
    headscale users list 2>/dev/null | awk -v user="$HEADSCALE_USER" '$0 ~ user { found = 1 } END { exit found ? 0 : 1 }'; then
    log "Headscale 用户已存在：$HEADSCALE_USER"
    return 0
  fi

  log "创建 Headscale 用户：$HEADSCALE_USER"
  headscale users create "$HEADSCALE_USER" || headscale user create "$HEADSCALE_USER"
}

headscale_user_id() {
  headscale users list -o json 2>/dev/null |
    jq -r --arg user "$HEADSCALE_USER" '.[] | select(.name == $user) | .id' |
    awk 'NF { print; exit }'
}

create_preauth_key_if_needed() {
  local args=()
  local user_ref
  local output
  local key

  [[ "$HEADSCALE_CREATE_PREAUTHKEY" == "1" ]] || return 0

  user_ref="$(headscale_user_id || true)"
  if [[ -n "$user_ref" ]]; then
    args=(preauthkeys create --user "$user_ref" --expiration "$HEADSCALE_PREAUTH_EXPIRATION")
  else
    args=(preauthkeys create --expiration "$HEADSCALE_PREAUTH_EXPIRATION")
  fi
  [[ "$HEADSCALE_PREAUTH_REUSABLE" == "1" ]] && args+=(--reusable)

  log "创建 Headscale preauth key。"
  if command_exists jq && output="$(headscale "${args[@]}" -o json 2>/dev/null)"; then
    key="$(jq -r '.key // .preAuthKey.key // .pre_auth_key.key // empty' <<<"$output")"
    if [[ -n "$key" && "$key" != "null" ]]; then
      printf '%s\n' "$key"
      persist_env_value HEADSCALE_AUTHKEY "$key"
      return 0
    fi
  fi

  output="$(headscale "${args[@]}")"
  printf '%s\n' "$output"
  key="$(grep -Eo '(hskey-auth|tskey-auth|tskey)-[A-Za-z0-9._=-]+' <<<"$output" | head -n 1 || true)"
  [[ -n "$key" ]] && persist_env_value HEADSCALE_AUTHKEY "$key"
}

configure_ufw() {
  local port

  command_exists ufw || return 0

  if [[ "$HEADSCALE_UFW_ALLOW" == "1" ]]; then
    while IFS= read -r port; do
      [[ -n "$port" ]] || continue
      ufw allow "$port" comment 'headscale'
    done < <(split_words "$HEADSCALE_UFW_PORTS")
  fi

  if [[ "$HEADSCALE_ENABLE_CADDY" == "1" && "$HEADSCALE_CADDY_UFW_ALLOW" == "1" ]]; then
    ufw allow 80/tcp comment 'caddy http'
    ufw allow 443/tcp comment 'caddy https'
  fi
}

configure_cloudflare_dns_if_needed() {
  local host
  local target

  [[ "$CLOUDFLARE_HEADSCALE_DNS" == "1" ]] || return 0
  cloudflare_configured || return 0

  apt_install curl jq
  host="$(url_host "$HEADSCALE_SERVER_URL")"
  [[ -n "$host" ]] || die "无法从 HEADSCALE_SERVER_URL 解析主机名。"
  if [[ "$CLOUDFLARE_DNS_TARGET_IPV4" == "auto" || -z "$CLOUDFLARE_DNS_TARGET_IPV4" ]]; then
    target="$(current_public_ipv4)"
  else
    target="$CLOUDFLARE_DNS_TARGET_IPV4"
  fi
  cloudflare_upsert_record "$host" A "$target" "$CLOUDFLARE_DNS_PROXIED" "$CLOUDFLARE_DNS_TTL"
}

print_summary() {
  printf '\nHeadscale 部署完成。\n'
  printf '  server_url：%s\n' "$HEADSCALE_SERVER_URL"
  printf '  listen_addr：%s\n' "$HEADSCALE_LISTEN_ADDR"
  printf '  systemd：headscale.service\n'
  printf '  配置文件：%s\n' "$HEADSCALE_CONFIG"
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
  resolve_defaults
  validate_input
  begin_run
  persist_env_file
  persist_headscale_config
  install_headscale_package
  configure_cloudflare_dns_if_needed
  configure_headscale
  configure_ufw
  configure_caddy_if_needed
  ensure_headscale_user
  create_preauth_key_if_needed
  install_backup_timer headscale
  print_summary
  finish_run
}

main "$@"
