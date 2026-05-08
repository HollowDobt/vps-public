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

apply_vps_defaults headscale-server

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
  HEADSCALE_CADDY_VERIFY=1
  HEADSCALE_EXCLUSIVE_PUBLIC_PORTS=1
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
  validate_bool HEADSCALE_CADDY_VERIFY "$HEADSCALE_CADDY_VERIFY"
  validate_bool HEADSCALE_CADDY_REPAIR_CERT_CACHE "$HEADSCALE_CADDY_REPAIR_CERT_CACHE"
  validate_bool HEADSCALE_EXCLUSIVE_PUBLIC_PORTS "$HEADSCALE_EXCLUSIVE_PUBLIC_PORTS"
  validate_bool HEADSCALE_DISABLE_K3S_CONFLICTS "$HEADSCALE_DISABLE_K3S_CONFLICTS"
  validate_bool CLOUDFLARE_HEADSCALE_DNS "$CLOUDFLARE_HEADSCALE_DNS"
  [[ "$HEADSCALE_CADDY_VERIFY_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || die "HEADSCALE_CADDY_VERIFY_TIMEOUT_SEC 必须是数字。"
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
  if [[ "$HEADSCALE_ENABLE_CADDY" == "1" ]]; then
    set_yaml_key "$HEADSCALE_CONFIG" tls_cert_path '""'
    set_yaml_key "$HEADSCALE_CONFIG" tls_key_path '""'
  fi
  set_dns_base_domain "$HEADSCALE_CONFIG" "$HEADSCALE_DNS_BASE_DOMAIN"
  append_config_fragment

  headscale configtest
  systemctl enable headscale
  systemctl restart headscale
  log "Headscale 服务已启动。"
}

public_port_conflict_detected() {
  command_exists iptables || return 1
  iptables -t nat -S 2>/dev/null |
    grep -Eq 'CNI-HOSTPORT-DNAT|kube-system/traefik|--dports 80,443|tcp --dport (80|443).*KUBE'
}

clear_k3s_public_port_conflicts() {
  [[ "$HEADSCALE_ENABLE_CADDY" == "1" ]] || return 0
  [[ "$HEADSCALE_EXCLUSIVE_PUBLIC_PORTS" == "1" ]] || return 0
  public_port_conflict_detected || return 0

  if [[ "$HEADSCALE_DISABLE_K3S_CONFLICTS" != "1" ]]; then
    die "检测到 k3s/CNI 正在接管 80/443；Headscale HTTPS 入口需要独占公网 80/443。"
  fi

  warn "检测到 k3s/CNI 接管 80/443，正在按 Headscale 主节点角色关闭 k3s/k3s-agent。"
  systemctl disable --now k3s >/dev/null 2>&1 || true
  systemctl disable --now k3s-agent >/dev/null 2>&1 || true
  if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
    /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
  fi

  sleep 2
  public_port_conflict_detected && die "k3s/CNI 仍在接管 80/443，请检查残留的 k3s 服务或容器。"
  log "Headscale 公网入口冲突已清理。"
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
  systemctl enable caddy
  systemctl start caddy
  systemctl reload caddy || systemctl restart caddy
  verify_caddy_headscale_endpoint "$host"
  log "Caddy 反向代理已配置：${host} -> ${upstream}"
}

caddy_served_cert_text() {
  local host="$1"

  command_exists openssl || return 1
  printf '\n' |
    openssl s_client -connect 127.0.0.1:443 -servername "$host" -showcerts 2>/dev/null |
    openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || return 1
}

caddy_key_endpoint_ready() {
  local host="$1"
  local deadline
  local cert_text
  local out_file
  local err_file

  out_file="$(mktemp_managed)"
  err_file="$(mktemp_managed)"
  deadline=$((SECONDS + HEADSCALE_CADDY_VERIFY_TIMEOUT_SEC))

  while (( SECONDS <= deadline )); do
    cert_text="$(caddy_served_cert_text "$host" || true)"
    if grep -q 'TRAEFIK DEFAULT CERT' <<<"$cert_text"; then
      return 2
    fi

    if curl -fsS \
      --resolve "${host}:443:127.0.0.1" \
      --connect-timeout 5 \
      --max-time 10 \
      "https://${host}/key?v=133" \
      -o "$out_file" 2>"$err_file"; then
      return 0
    fi

    sleep 2
  done

  return 1
}

repair_caddy_domain_cert_cache() {
  local host="$1"
  local cert_root="/var/lib/caddy/.local/share/caddy/certificates"
  local backup_dir
  local found=0
  local path
  local issuer

  [[ "$HEADSCALE_CADDY_REPAIR_CERT_CACHE" == "1" ]] || return 1
  [[ -d "$cert_root" ]] || return 0

  backup_dir="${STATE_DIR}/caddy-cert-backups/${host}-$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -o root -g root -m 0700 "$backup_dir"

  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    issuer="$(basename "$(dirname "$path")")"
    mv -- "$path" "${backup_dir}/${issuer}"
    found=1
  done < <(find "$cert_root" -mindepth 2 -maxdepth 2 -type d -name "$host" 2>/dev/null)

  if [[ "$found" == "1" ]]; then
    log "已隔离 ${host} 的 Caddy 证书缓存：${backup_dir}"
  fi
  return 0
}

verify_caddy_headscale_endpoint() {
  local host="$1"

  [[ "$HEADSCALE_CADDY_VERIFY" == "1" ]] || return 0

  log "检查 Headscale HTTPS 入口：${host}"
  if caddy_key_endpoint_ready "$host"; then
    log "Headscale HTTPS 入口检查通过：https://${host}/key"
    return 0
  fi

  warn "Headscale HTTPS 入口首次检查失败，重启 Caddy 后复查。"
  systemctl restart caddy
  if caddy_key_endpoint_ready "$host"; then
    log "Headscale HTTPS 入口检查通过：https://${host}/key"
    return 0
  fi

  warn "Headscale HTTPS 入口仍未通过，隔离本域名证书缓存后复查。"
  repair_caddy_domain_cert_cache "$host"
  systemctl restart caddy
  if caddy_key_endpoint_ready "$host"; then
    log "Headscale HTTPS 入口检查通过：https://${host}/key"
    return 0
  fi

  die "Headscale HTTPS 入口检查失败：请检查 DNS 是否指向本机、80/443 是否可达、Caddy 是否占用正确端口。"
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
  if [[ "$HEADSCALE_PREAUTH_REUSABLE" == "1" ]]; then
    args+=(--reusable)
  fi

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
  if [[ -n "$key" ]]; then
    persist_env_value HEADSCALE_AUTHKEY "$key"
  else
    warn "未能从输出中解析认证密钥，请手工复制上方输出。"
  fi
  return 0
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
  cloudflare_upsert_record "$host" A "$target" 0 "$CLOUDFLARE_DNS_TTL"
}

verify_headscale_boot_persistence() {
  systemctl is-enabled --quiet headscale || die "headscale.service 未设置开机自启；请运行 systemctl enable headscale.service 后重试。"
  systemctl is-active --quiet headscale || die "headscale.service 未运行；请运行 systemctl status headscale.service 查看服务错误。"

  if [[ "$HEADSCALE_ENABLE_CADDY" == "1" ]]; then
    systemctl is-enabled --quiet caddy || die "caddy.service 未设置开机自启；请运行 systemctl enable caddy.service 后重试。"
    systemctl is-active --quiet caddy || die "caddy.service 未运行；请运行 systemctl status caddy.service 查看服务错误。"
  fi
}

print_summary() {
  printf '\nHeadscale 部署完成。\n'
  printf '  server_url：%s\n' "$HEADSCALE_SERVER_URL"
  printf '  listen_addr：%s\n' "$HEADSCALE_LISTEN_ADDR"
  printf '  systemd：headscale.service\n'
  printf '  配置文件：%s\n' "$HEADSCALE_CONFIG"
}

main() {
  parse_noarg_or_help "$@"
  prepare_vps_run
  resolve_defaults
  validate_input
  begin_run
  persist_env_file
  persist_headscale_config
  install_headscale_package
  configure_cloudflare_dns_if_needed
  configure_headscale
  configure_ufw
  clear_k3s_public_port_conflicts
  configure_caddy_if_needed
  verify_headscale_boot_persistence
  ensure_headscale_user
  create_preauth_key_if_needed
  install_backup_timer headscale
  print_summary
  finish_run
}

main "$@"
