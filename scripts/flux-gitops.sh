#!/usr/bin/env bash
# Flux GitOps 部署脚本。
#
# 在 k3s 主节点上安装 Flux CD，绑定 GitHub GitOps 仓库，
# 配置 Kustomize 分层、HelmRelease 模板和 SOPS + age 密钥。

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="/var/lib/hlwdot/flux-gitops"

# shellcheck source=lib/vps-common.sh
. "${SCRIPT_DIR}/lib/vps-common.sh"

FLUX_GITHUB_HOSTNAME="${FLUX_GITHUB_HOSTNAME:-github.com}"
FLUX_GITHUB_OWNER="${FLUX_GITHUB_OWNER:-}"
FLUX_GITHUB_REPO="${FLUX_GITHUB_REPO:-vps-gitops}"
FLUX_GITHUB_BRANCH="${FLUX_GITHUB_BRANCH:-main}"
FLUX_GITHUB_PRIVATE="${FLUX_GITHUB_PRIVATE:-1}"
FLUX_GITHUB_PERSONAL="${FLUX_GITHUB_PERSONAL:-1}"
FLUX_GIT_AUTH="${FLUX_GIT_AUTH:-ssh}"
FLUX_GIT_URL="${FLUX_GIT_URL:-}"
FLUX_GIT_SSH_KEY_FILE="${FLUX_GIT_SSH_KEY_FILE:-/etc/fluxcd/github-deploy.key}"
FLUX_CLUSTER_NAME="${FLUX_CLUSTER_NAME:-}"
FLUX_GITHUB_PATH="${FLUX_GITHUB_PATH:-}"
FLUX_COMPONENTS_EXTRA="${FLUX_COMPONENTS_EXTRA:-}"
FLUX_REPO_SCAFFOLD="${FLUX_REPO_SCAFFOLD:-1}"
FLUX_AGE_KEY_FILE="${FLUX_AGE_KEY_FILE:-/etc/fluxcd/sops-age.agekey}"
FLUX_AGE_PUBLIC_KEY="${FLUX_AGE_PUBLIC_KEY:-}"
FLUX_INTERVAL="${FLUX_INTERVAL:-10m0s}"
FLUX_RETRY_INTERVAL="${FLUX_RETRY_INTERVAL:-1m0s}"
FLUX_TIMEOUT="${FLUX_TIMEOUT:-5m0s}"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
K3S_NODE_NAME="${K3S_NODE_NAME:-}"
HEADSCALE_CLIENT_HOSTNAME="${HEADSCALE_CLIENT_HOSTNAME:-}"
BOOTSTRAP_HOSTNAME="${BOOTSTRAP_HOSTNAME:-}"

KUBECTL=()
AGE_PUBLIC_KEY=''

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME

必填配置：
  FLUX_GITHUB_OWNER=HollowDobt

常用配置：
  FLUX_GIT_AUTH=ssh
  FLUX_GIT_SSH_KEY_FILE=/etc/fluxcd/github-deploy.key
  FLUX_GITHUB_REPO=vps-gitops
  FLUX_GITHUB_BRANCH=main
  FLUX_CLUSTER_NAME=server3
  FLUX_GITHUB_PATH=clusters/server3

说明：
  - 必须在 k3s 主节点执行。
  - 脚本会生成 age 私钥并写入 Kubernetes Secret，公钥写入仓库 .sops.yaml。
EOF
}

validate_input() {
  [[ -n "$FLUX_GITHUB_OWNER" ]] || die "请设置 FLUX_GITHUB_OWNER。"
  case "$FLUX_GIT_AUTH" in
    ssh | token) ;;
    *) die "FLUX_GIT_AUTH 只能是 ssh 或 token。" ;;
  esac
  if [[ "$FLUX_GIT_AUTH" == "token" ]]; then
    [[ -n "$GITHUB_TOKEN" ]] || die "FLUX_GIT_AUTH=token 时必须设置 GITHUB_TOKEN 或 GH_TOKEN。"
  fi
  validate_bool FLUX_GITHUB_PRIVATE "$FLUX_GITHUB_PRIVATE"
  validate_bool FLUX_GITHUB_PERSONAL "$FLUX_GITHUB_PERSONAL"
  validate_bool FLUX_REPO_SCAFFOLD "$FLUX_REPO_SCAFFOLD"
}

resolve_defaults() {
  if [[ -z "$FLUX_CLUSTER_NAME" ]]; then
    if [[ -n "$K3S_NODE_NAME" ]]; then
      FLUX_CLUSTER_NAME="$K3S_NODE_NAME"
    elif [[ -n "$HEADSCALE_CLIENT_HOSTNAME" ]]; then
      FLUX_CLUSTER_NAME="$HEADSCALE_CLIENT_HOSTNAME"
    elif [[ -n "$BOOTSTRAP_HOSTNAME" ]]; then
      FLUX_CLUSTER_NAME="$BOOTSTRAP_HOSTNAME"
    else
      FLUX_CLUSTER_NAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'k3s')"
    fi
  fi
  if [[ -z "$FLUX_GITHUB_PATH" ]]; then
    FLUX_GITHUB_PATH="clusters/${FLUX_CLUSTER_NAME}"
  fi
}

detect_kubectl() {
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  [[ -r "$KUBECONFIG" ]] || die "找不到 kubeconfig：$KUBECONFIG"

  if command_exists kubectl; then
    KUBECTL=(kubectl)
  elif command_exists k3s; then
    KUBECTL=(k3s kubectl)
  else
    die "缺少 kubectl 或 k3s 命令。"
  fi

  "${KUBECTL[@]}" get nodes >/dev/null
}

github_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) die "当前架构不支持自动安装：$(uname -m)" ;;
  esac
}

github_latest_release() {
  local repo="$1"
  local tag

  tag="$(curl -fsSL --retry 3 "https://api.github.com/repos/${repo}/releases" |
    jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name')"
  [[ -n "$tag" && "$tag" != "null" ]] || die "无法获取 ${repo} 最新稳定版本。"
  printf '%s\n' "$tag"
}

install_flux_cli() {
  local install_script

  if command_exists flux; then
    log "Flux CLI 已安装。"
    return 0
  fi

  install_script="$(mktemp_managed)"
  log "安装 Flux CLI。"
  download_file https://fluxcd.io/install.sh "$install_script"
  bash "$install_script"
}

install_sops() {
  local version
  local arch
  local temp_bin
  local url

  if command_exists sops; then
    log "SOPS 已安装。"
    return 0
  fi

  version="$(github_latest_release getsops/sops)"
  arch="$(github_arch)"
  temp_bin="$(mktemp_managed)"
  url="https://github.com/getsops/sops/releases/download/${version}/sops-${version}.linux.${arch}"

  log "安装 SOPS：${version}"
  download_file "$url" "$temp_bin"
  install -o root -g root -m 0755 "$temp_bin" /usr/local/bin/sops
}

install_dependencies() {
  apt_install ca-certificates curl git jq gnupg age openssh-client
  install_flux_cli
  install_sops
}

ensure_git_ssh_key() {
  [[ "$FLUX_GIT_AUTH" == "ssh" ]] || return 0

  install -d -o root -g root -m 0700 "$(dirname "$FLUX_GIT_SSH_KEY_FILE")"
  if [[ ! -s "$FLUX_GIT_SSH_KEY_FILE" ]]; then
    [[ -n "$GITHUB_TOKEN" ]] || die "缺少 GitHub deploy key：$FLUX_GIT_SSH_KEY_FILE"
    log "生成 Flux GitHub deploy key。"
    ssh-keygen -t ed25519 -N '' -C "flux-${FLUX_CLUSTER_NAME}" -f "$FLUX_GIT_SSH_KEY_FILE" >/dev/null
  fi
  chmod 0600 "$FLUX_GIT_SSH_KEY_FILE"
}

github_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="https://api.github.com${path}"

  [[ -n "$GITHUB_TOKEN" ]] || return 1
  if [[ -n "$body" ]]; then
    curl -fsSL --request "$method" "$url" \
      --header "Authorization: Bearer ${GITHUB_TOKEN}" \
      --header 'Accept: application/vnd.github+json' \
      --header 'Content-Type: application/json' \
      --data "$body"
  else
    curl -fsSL --request "$method" "$url" \
      --header "Authorization: Bearer ${GITHUB_TOKEN}" \
      --header 'Accept: application/vnd.github+json'
  fi
}

ensure_github_repo_if_token_available() {
  local body

  [[ -n "$GITHUB_TOKEN" ]] || return 0
  [[ "$FLUX_GITHUB_HOSTNAME" == "github.com" ]] || return 0

  if github_api GET "/repos/${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}" >/dev/null 2>&1; then
    return 0
  fi

  body="$(jq -nc \
    --arg name "$FLUX_GITHUB_REPO" \
    --argjson private "$([[ "$FLUX_GITHUB_PRIVATE" == "1" ]] && printf true || printf false)" \
    '{name:$name,private:$private,auto_init:false}')"

  log "创建 GitHub GitOps 仓库：${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}"
  if [[ "$FLUX_GITHUB_PERSONAL" == "1" ]]; then
    github_api POST /user/repos "$body" >/dev/null
  else
    github_api POST "/orgs/${FLUX_GITHUB_OWNER}/repos" "$body" >/dev/null
  fi
}

ensure_github_deploy_key_if_token_available() {
  local public_key_file="${FLUX_GIT_SSH_KEY_FILE}.pub"
  local public_key
  local keys
  local body

  [[ "$FLUX_GIT_AUTH" == "ssh" ]] || return 0
  [[ -n "$GITHUB_TOKEN" ]] || return 0
  [[ "$FLUX_GITHUB_HOSTNAME" == "github.com" ]] || return 0
  [[ -r "$public_key_file" ]] || die "缺少 deploy key 公钥：$public_key_file"

  public_key="$(awk 'NF { print; exit }' "$public_key_file")"
  keys="$(github_api GET "/repos/${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}/keys")"
  if jq -e --arg key "$public_key" '.[] | select(.key == $key)' <<<"$keys" >/dev/null; then
    return 0
  fi

  body="$(jq -nc \
    --arg title "flux-${FLUX_CLUSTER_NAME}" \
    --arg key "$public_key" \
    '{title:$title,key:$key,read_only:false}')"

  log "写入 GitHub deploy key：${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}"
  github_api POST "/repos/${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}/keys" "$body" >/dev/null
}

ensure_age_key() {
  install -d -o root -g root -m 0700 "$(dirname "$FLUX_AGE_KEY_FILE")"
  if [[ ! -s "$FLUX_AGE_KEY_FILE" ]]; then
    log "生成 Flux SOPS age 私钥。"
    age-keygen -o "$FLUX_AGE_KEY_FILE" >/dev/null
    chmod 0600 "$FLUX_AGE_KEY_FILE"
  fi

  AGE_PUBLIC_KEY="$(awk '/^# public key:/ { print $4; exit }' "$FLUX_AGE_KEY_FILE")"
  [[ -n "$AGE_PUBLIC_KEY" ]] || die "无法从 $FLUX_AGE_KEY_FILE 读取 age 公钥。"
  FLUX_AGE_PUBLIC_KEY="$AGE_PUBLIC_KEY"
}

persist_flux_config() {
  persist_env_value FLUX_CLUSTER_NAME "$FLUX_CLUSTER_NAME"
  persist_env_value FLUX_GITHUB_PATH "$FLUX_GITHUB_PATH"
  persist_env_value FLUX_GIT_AUTH "$FLUX_GIT_AUTH"
  persist_env_value FLUX_GIT_SSH_KEY_FILE "$FLUX_GIT_SSH_KEY_FILE"
  persist_env_value FLUX_AGE_KEY_FILE "$FLUX_AGE_KEY_FILE"
  if [[ -n "$FLUX_AGE_PUBLIC_KEY" ]]; then
    persist_env_value FLUX_AGE_PUBLIC_KEY "$FLUX_AGE_PUBLIC_KEY"
  fi
  return 0
}

ensure_sops_secret() {
  log "写入 flux-system/sops-age。"
  "${KUBECTL[@]}" create namespace flux-system --dry-run=client -o yaml |
    "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" -n flux-system create secret generic sops-age \
    --from-file=identity.agekey="$FLUX_AGE_KEY_FILE" \
    --dry-run=client -o yaml |
    "${KUBECTL[@]}" apply -f -
}

flux_bootstrap() {
  local args=()

  if [[ "$FLUX_GIT_AUTH" == "ssh" ]]; then
    args=(bootstrap git
      --url "$(git_clone_url)"
      --branch "$FLUX_GITHUB_BRANCH"
      --path "$FLUX_GITHUB_PATH"
      --private-key-file "$FLUX_GIT_SSH_KEY_FILE")
  else
    args=(bootstrap github
      --token-auth
      --hostname "$FLUX_GITHUB_HOSTNAME"
      --owner "$FLUX_GITHUB_OWNER"
      --repository "$FLUX_GITHUB_REPO"
      --branch "$FLUX_GITHUB_BRANCH"
      --path "$FLUX_GITHUB_PATH")

    if [[ "$FLUX_GITHUB_PRIVATE" == "1" ]]; then
      args+=(--private=true)
    else
      args+=(--private=false)
    fi
    if [[ "$FLUX_GITHUB_PERSONAL" == "1" ]]; then
      args+=(--personal)
    fi
  fi
  if [[ -n "$FLUX_COMPONENTS_EXTRA" ]]; then
    args+=(--components-extra "$FLUX_COMPONENTS_EXTRA")
  fi

  log "执行 Flux bootstrap。"
  if [[ "$FLUX_GIT_AUTH" == "token" ]]; then
    GITHUB_TOKEN="$GITHUB_TOKEN" flux "${args[@]}"
  else
    flux "${args[@]}"
  fi
}

write_file() {
  local path="$1"

  install -d -m 0755 "$(dirname "$path")"
  cat >"$path"
}

write_file_if_absent() {
  local path="$1"

  if [[ -e "$path" ]]; then
    cat >/dev/null
    return 0
  fi
  write_file "$path"
}

git_clone_url() {
  if [[ -n "$FLUX_GIT_URL" ]]; then
    printf '%s\n' "$FLUX_GIT_URL"
  elif [[ "$FLUX_GIT_AUTH" == "ssh" ]]; then
    printf 'ssh://git@%s/%s/%s.git\n' "$FLUX_GITHUB_HOSTNAME" "$FLUX_GITHUB_OWNER" "$FLUX_GITHUB_REPO"
  else
    printf 'https://%s/%s/%s.git\n' "$FLUX_GITHUB_HOSTNAME" "$FLUX_GITHUB_OWNER" "$FLUX_GITHUB_REPO"
  fi
}

git_with_token_env() {
  local askpass="$1"

  cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf 'x-access-token\n' ;;
  *Password*) printf '%s\n' "$GITHUB_TOKEN" ;;
  *) printf '\n' ;;
esac
EOF
  chmod 0700 "$askpass"
}

git_ssh_command() {
  printf 'ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' "$(shell_quote "$FLUX_GIT_SSH_KEY_FILE")"
}

git_clone_repo() {
  local worktree="$1"
  local askpass="$2"

  if [[ "$FLUX_GIT_AUTH" == "ssh" ]]; then
    GIT_SSH_COMMAND="$(git_ssh_command)" git clone --branch "$FLUX_GITHUB_BRANCH" "$(git_clone_url)" "$worktree"
  else
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 GITHUB_TOKEN="$GITHUB_TOKEN" \
      git clone --branch "$FLUX_GITHUB_BRANCH" "$(git_clone_url)" "$worktree"
  fi
}

git_push_repo() {
  local worktree="$1"
  local askpass="$2"

  if [[ "$FLUX_GIT_AUTH" == "ssh" ]]; then
    GIT_SSH_COMMAND="$(git_ssh_command)" git -C "$worktree" push origin "$FLUX_GITHUB_BRANCH"
  else
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 GITHUB_TOKEN="$GITHUB_TOKEN" \
      git -C "$worktree" push origin "$FLUX_GITHUB_BRANCH"
  fi
}

scaffold_repo() {
  local worktree
  local askpass
  local cluster_dir

  [[ "$FLUX_REPO_SCAFFOLD" == "1" ]] || return 0

  worktree="$(mktemp -d "${STATE_DIR}/tmp/repo.XXXXXX")"
  askpass="$(mktemp_managed)"
  track_tempfile "$worktree"
  if [[ "$FLUX_GIT_AUTH" == "token" ]]; then
    git_with_token_env "$askpass"
  fi

  log "拉取 GitOps 仓库并写入基础目录。"
  git_clone_repo "$worktree" "$askpass"

  git -C "$worktree" config user.name "${FLUX_GIT_COMMIT_NAME:-hlwdot-bot}"
  git -C "$worktree" config user.email "${FLUX_GIT_COMMIT_EMAIL:-ops@hlwdot.local}"

  cluster_dir="${worktree}/${FLUX_GITHUB_PATH}"
  install -d -m 0755 "$cluster_dir" "${worktree}/infrastructure" "${worktree}/apps/examples/podinfo"

  write_file_if_absent "${worktree}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '.*\\.sops\\.ya?ml$'
    encrypted_regex: '^(data|stringData)$'
    age: ${AGE_PUBLIC_KEY}
EOF

  write_file_if_absent "${cluster_dir}/infrastructure.yaml" <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: ${FLUX_INTERVAL}
  retryInterval: ${FLUX_RETRY_INTERVAL}
  timeout: ${FLUX_TIMEOUT}
  path: ./infrastructure
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
EOF

  write_file_if_absent "${cluster_dir}/apps.yaml" <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: ${FLUX_INTERVAL}
  retryInterval: ${FLUX_RETRY_INTERVAL}
  timeout: ${FLUX_TIMEOUT}
  path: ./apps
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
EOF

  write_file_if_absent "${worktree}/infrastructure/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF

  write_file_if_absent "${worktree}/apps/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF

  write_file_if_absent "${worktree}/apps/examples/podinfo/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - source.yaml
  - release.yaml
EOF

  write_file_if_absent "${worktree}/apps/examples/podinfo/namespace.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: podinfo
EOF

  write_file_if_absent "${worktree}/apps/examples/podinfo/source.yaml" <<'EOF'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: podinfo
  namespace: podinfo
spec:
  interval: 1h0m0s
  url: https://stefanprodan.github.io/podinfo
EOF

  write_file_if_absent "${worktree}/apps/examples/podinfo/release.yaml" <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: podinfo
spec:
  interval: 30m0s
  chart:
    spec:
      chart: podinfo
      version: ">=6.0.0"
      sourceRef:
        kind: HelmRepository
        name: podinfo
        namespace: podinfo
      interval: 1h0m0s
  values:
    replicaCount: 1
EOF

  write_file_if_absent "${worktree}/apps/examples/README.md" <<'EOF'
# examples

这里的示例默认不会部署。确认要启用后，把对应目录加入 `apps/kustomization.yaml` 的 `resources`。
EOF

  write_file_if_absent "${worktree}/README.md" <<EOF
# ${FLUX_GITHUB_REPO}

目录约定：

- \`${FLUX_GITHUB_PATH}/\`：当前集群入口。
- \`infrastructure/\`：集群基础设施控制器和共享配置。
- \`apps/\`：业务应用和 HelmRelease。
- \`.sops.yaml\`：SOPS + age 加密规则。

密钥文件使用 \`*.sops.yaml\` 后缀，并只加密 \`data\` / \`stringData\`。
EOF

  git -C "$worktree" add .sops.yaml "$FLUX_GITHUB_PATH" infrastructure apps README.md
  if git -C "$worktree" diff --cached --quiet; then
    log "GitOps 仓库没有新的基础目录变更。"
  else
    git -C "$worktree" commit -m "gitops: initialize ${FLUX_CLUSTER_NAME}"
    git_push_repo "$worktree" "$askpass"
  fi
}

reconcile_flux() {
  flux check
  flux reconcile source git flux-system -n flux-system || true
  flux reconcile kustomization infrastructure -n flux-system --with-source || true
  flux reconcile kustomization apps -n flux-system --with-source || true
}

print_summary() {
  printf '\nFlux GitOps 部署完成。\n'
  printf '  仓库：%s/%s\n' "$FLUX_GITHUB_OWNER" "$FLUX_GITHUB_REPO"
  printf '  分支：%s\n' "$FLUX_GITHUB_BRANCH"
  printf '  集群路径：%s\n' "$FLUX_GITHUB_PATH"
  printf '  age 私钥：%s\n' "$FLUX_AGE_KEY_FILE"
  printf '  age 公钥：%s\n' "$AGE_PUBLIC_KEY"
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
  detect_kubectl
  begin_run
  persist_env_file
  persist_flux_config
  install_dependencies
  flux check --pre
  ensure_git_ssh_key
  ensure_github_repo_if_token_available
  ensure_github_deploy_key_if_token_available
  ensure_age_key
  persist_flux_config
  flux_bootstrap
  ensure_sops_secret
  scaffold_repo
  reconcile_flux
  print_summary
  finish_run
}

main "$@"
