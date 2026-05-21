#!/usr/bin/env bash
# Configure or remove common Linux proxy settings for this machine.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$SCRIPT_PATH")"
# shellcheck source=lib/self_update.sh
source "${SCRIPT_DIR}/lib/self_update.sh"
scripts_self_update "$SCRIPT_DIR" "$SCRIPT_PATH" "$@"

SCRIPT_NAME="$(basename "$0")"

DEFAULT_PROXY_INPUT="127.0.0.1:7897"
WSL_DOCKER_PROXY_INPUT="host.docker.internal:7897"
PROXY_INPUT=""
PROXY_EXPLICIT=0
HTTP_PROXY_URL=""
ALL_PROXY_URL=""
NO_PROXY_LIST="localhost,127.0.0.1,::1,0.0.0.0,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
CONFIGURE_HTTP_ENV=0
SKIP_APT=0
CONFIGURE_APT=0
SKIP_GIT=0
SKIP_DOCKER=0
UNSET_PROXY=0
DRY_RUN=0
TMP_DIR=""
BASHRC_PROXY_START="# >>> configure_proxy http env >>>"
BASHRC_PROXY_END="# <<< configure_proxy http env <<<"
SSH_GITHUB_START="# >>> configure_proxy github ssh >>>"
SSH_GITHUB_END="# <<< configure_proxy github ssh <<<"

usage() {
  cat <<'EOF'
Usage:
  configure_proxy.sh [options]
  configure_proxy.sh --proxy HOST:PORT
  configure_proxy.sh --proxy http://HOST:PORT
  configure_proxy.sh --unset

Options:
      --proxy VALUE       Proxy address or URL. Default: 127.0.0.1:7897.
                          Inside WSL Docker containers, the default is
                          host.docker.internal:7897.
                          HOST:PORT becomes http://HOST:PORT for http(s)
                          variables and socks5h://HOST:PORT for all_proxy.
      --all-proxy URL     Override all_proxy/ALL_PROXY. Default is derived
                          from --proxy as socks5h://HOST:PORT.
      --no-proxy LIST     Override no_proxy/NO_PROXY.
      --http-env          Also export http_proxy/https_proxy in system
                          environment files. Disabled by default because apt
                          reads them and some repositories fail through HTTP
                          proxy. User ~/.bashrc always gets HTTP(S) exports.
      --apt               Configure apt proxy. By default apt is unchanged.
      --skip-apt          Do not change apt proxy settings.
      --skip-git          Do not configure system or global git proxy.
      --skip-docker       Do not configure Docker systemd proxy.
      --unset             Remove proxy settings managed by this script.
      --dry-run           Print planned changes without changing the system.
  -h, --help              Show this help.

Examples:
  configure_proxy.sh
  configure_proxy.sh --proxy 192.168.31.10:7897
  configure_proxy.sh --proxy http://127.0.0.1:7897 --all-proxy socks5h://127.0.0.1:7897
  configure_proxy.sh --unset
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] Warning: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] Error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_root() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      printf ' %q' "$@"
    else
      printf ' sudo'
      printf ' %q' "$@"
    fi
    printf '\n'
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_optional_root() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      printf ' %q' "$@"
    else
      printf ' sudo'
      printf ' %q' "$@"
    fi
    printf '\n'
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@" || true
  else
    sudo "$@" || true
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --proxy)
        [[ $# -ge 2 ]] || die "--proxy requires a value"
        PROXY_INPUT="$2"
        PROXY_EXPLICIT=1
        shift 2
        ;;
      --all-proxy)
        [[ $# -ge 2 ]] || die "--all-proxy requires a value"
        ALL_PROXY_URL="$2"
        shift 2
        ;;
      --no-proxy)
        [[ $# -ge 2 ]] || die "--no-proxy requires a value"
        NO_PROXY_LIST="$2"
        shift 2
        ;;
      --http-env)
        CONFIGURE_HTTP_ENV=1
        shift
        ;;
      --apt)
        CONFIGURE_APT=1
        SKIP_APT=0
        shift
        ;;
      --skip-apt)
        SKIP_APT=1
        shift
        ;;
      --skip-git)
        SKIP_GIT=1
        shift
        ;;
      --skip-docker)
        SKIP_DOCKER=1
        shift
        ;;
      --unset)
        UNSET_PROXY=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null ||
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

is_container() {
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '/(docker|containerd|kubepods)(/|[-:])' /proc/1/cgroup /proc/self/cgroup 2>/dev/null
}

select_default_proxy() {
  if [[ "$PROXY_EXPLICIT" -eq 1 ]]; then
    return 0
  fi

  if is_wsl && is_container; then
    PROXY_INPUT="$WSL_DOCKER_PROXY_INPUT"
  else
    PROXY_INPUT="$DEFAULT_PROXY_INPUT"
  fi
}

strip_scheme() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value#socks5h://}"
  value="${value#socks5://}"
  value="${value#socks4://}"
  printf '%s\n' "$value"
}

derive_proxy_urls() {
  local host_port=""

  if [[ "$PROXY_INPUT" == *"://"* ]]; then
    HTTP_PROXY_URL="$PROXY_INPUT"
    host_port="$(strip_scheme "$PROXY_INPUT")"
  else
    HTTP_PROXY_URL="http://${PROXY_INPUT}"
    host_port="$PROXY_INPUT"
  fi

  host_port="${host_port%%/*}"
  [[ "$host_port" == *:* ]] || die "proxy must include host and port: $PROXY_INPUT"

  if [[ -z "$ALL_PROXY_URL" ]]; then
    ALL_PROXY_URL="socks5h://${host_port}"
  fi
}

write_profile_proxy() {
  local tmp_file="$1"
  {
    cat <<EOF
# Global proxy for all users. Managed by ${SCRIPT_NAME}.
export all_proxy="${ALL_PROXY_URL}"
export ALL_PROXY="${ALL_PROXY_URL}"
export no_proxy="${NO_PROXY_LIST}"
export NO_PROXY="\$no_proxy"
EOF
    if [[ "$CONFIGURE_HTTP_ENV" -eq 1 ]]; then
      cat <<EOF
export http_proxy="${HTTP_PROXY_URL}"
export https_proxy="${HTTP_PROXY_URL}"
export HTTP_PROXY="${HTTP_PROXY_URL}"
export HTTPS_PROXY="${HTTP_PROXY_URL}"
EOF
    fi
  } > "$tmp_file"
}

write_environment_proxy() {
  local tmp_file="$1"
  {
    cat <<EOF
all_proxy=${ALL_PROXY_URL}
ALL_PROXY=${ALL_PROXY_URL}
no_proxy=${NO_PROXY_LIST}
NO_PROXY=${NO_PROXY_LIST}
EOF
    if [[ "$CONFIGURE_HTTP_ENV" -eq 1 ]]; then
      cat <<EOF
http_proxy=${HTTP_PROXY_URL}
https_proxy=${HTTP_PROXY_URL}
HTTP_PROXY=${HTTP_PROXY_URL}
HTTPS_PROXY=${HTTP_PROXY_URL}
EOF
    fi
  } > "$tmp_file"
}

target_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

target_home() {
  local user="$1"
  local home=""

  if command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$user" | awk -F: '{ print $6 }')"
  fi

  if [[ -z "$home" ]]; then
    if [[ "$user" == "$(id -un)" ]]; then
      home="${HOME}"
    else
      home="/home/${user}"
    fi
  fi

  printf '%s\n' "$home"
}

target_bashrc() {
  local user
  user="$(target_user)"
  printf '%s/.bashrc\n' "$(target_home "$user")"
}

target_chown_spec() {
  local user="$1"
  local group=""

  group="$(id -gn "$user" 2>/dev/null || true)"
  if [[ -n "$group" ]]; then
    printf '%s:%s\n' "$user" "$group"
  else
    printf '%s\n' "$user"
  fi
}

write_bashrc_http_proxy_block() {
  local tmp_file="$1"

  cat > "$tmp_file" <<EOF
${BASHRC_PROXY_START}
export http_proxy="${HTTP_PROXY_URL}"
export https_proxy="${HTTP_PROXY_URL}"
export HTTP_PROXY="${HTTP_PROXY_URL}"
export HTTPS_PROXY="${HTTP_PROXY_URL}"
export no_proxy="${NO_PROXY_LIST}"
export NO_PROXY="\$no_proxy"
${BASHRC_PROXY_END}
EOF
}

target_ssh_config() {
  local user
  user="$(target_user)"
  printf '%s/.ssh/config\n' "$(target_home "$user")"
}

target_ssh_dir() {
  local user
  user="$(target_user)"
  printf '%s/.ssh\n' "$(target_home "$user")"
}

write_github_ssh_config_block() {
  local tmp_file="$1"

  cat > "$tmp_file" <<EOF
${SSH_GITHUB_START}
Host github.com
    Hostname ssh.github.com
    Port 443
    User git
${SSH_GITHUB_END}
EOF
}

filter_github_ssh_config() {
  local input="$1"
  local output="$2"
  local remove_unmanaged="${3:-0}"

  if [[ -f "$input" ]]; then
    awk -v start="$SSH_GITHUB_START" \
        -v end="$SSH_GITHUB_END" \
        -v remove_unmanaged="$remove_unmanaged" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      skip { next }

      remove_unmanaged && $0 ~ /^[[:space:]]*Host[[:space:]]+github\.com([[:space:]]*)$/ {
        skip_github = 1
        next
      }

      skip_github && $0 ~ /^[[:space:]]*(Host|Match)[[:space:]]+/ {
        skip_github = 0
      }

      !skip_github { print }
    ' "$input" > "$output"
  else
    : > "$output"
  fi
}

merge_github_ssh_config() {
  local user=""
  local ssh_dir=""
  local ssh_config=""
  local filtered="${TMP_DIR}/ssh_config.filtered"
  local github_block="${TMP_DIR}/ssh_config.github"
  local merged="${TMP_DIR}/ssh_config.merged"

  user="$(target_user)"
  ssh_dir="$(target_ssh_dir)"
  ssh_config="$(target_ssh_config)"
  write_github_ssh_config_block "$github_block"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would merge GitHub SSH-over-443 config into ${ssh_config}"
    return 0
  fi

  install -d -m 0700 "$ssh_dir"
  filter_github_ssh_config "$ssh_config" "$filtered" 1
  cat "$filtered" "$github_block" > "$merged"
  install -m 0644 "$merged" "$ssh_config"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown -R "$(target_chown_spec "$user")" "$ssh_dir"
  fi
}

unset_github_ssh_config() {
  local user=""
  local ssh_dir=""
  local ssh_config=""
  local filtered="${TMP_DIR}/ssh_config.filtered"

  user="$(target_user)"
  ssh_dir="$(target_ssh_dir)"
  ssh_config="$(target_ssh_config)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would remove managed GitHub SSH-over-443 config from ${ssh_config}"
    return 0
  fi

  [[ -f "$ssh_config" ]] || return 0
  filter_github_ssh_config "$ssh_config" "$filtered" 0
  install -m 0644 "$filtered" "$ssh_config"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown -R "$(target_chown_spec "$user")" "$ssh_dir"
  fi
}

filter_bashrc_proxy_block() {
  local input="$1"
  local output="$2"

  if [[ -f "$input" ]]; then
    awk -v start="$BASHRC_PROXY_START" -v end="$BASHRC_PROXY_END" '
      $0 == start { skip = 1; next }
      $0 == end { skip = 0; next }
      !skip { print }
    ' "$input" > "$output"
  else
    : > "$output"
  fi
}

merge_bashrc_http_proxy() {
  local user=""
  local bashrc=""
  local filtered="${TMP_DIR}/bashrc.filtered"
  local proxy_block="${TMP_DIR}/bashrc.proxy"
  local merged="${TMP_DIR}/bashrc.merged"

  user="$(target_user)"
  bashrc="$(target_bashrc)"
  write_bashrc_http_proxy_block "$proxy_block"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would merge HTTP(S) proxy variables into ${bashrc}"
    return 0
  fi

  filter_bashrc_proxy_block "$bashrc" "$filtered"
  cat "$filtered" "$proxy_block" > "$merged"
  install -m 0644 "$merged" "$bashrc"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown "$(target_chown_spec "$user")" "$bashrc"
  fi
}

unset_bashrc_http_proxy() {
  local user=""
  local bashrc=""
  local filtered="${TMP_DIR}/bashrc.filtered"

  user="$(target_user)"
  bashrc="$(target_bashrc)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would remove HTTP(S) proxy variables from ${bashrc}"
    return 0
  fi

  filter_bashrc_proxy_block "$bashrc" "$filtered"
  install -m 0644 "$filtered" "$bashrc"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown "$(target_chown_spec "$user")" "$bashrc"
  fi
}

filter_environment_proxy() {
  local output="$1"

  if [[ -f /etc/environment ]]; then
    # shellcheck disable=SC2016
    run_root awk -F= '
      $1 ~ /^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|all_proxy|ALL_PROXY|no_proxy|NO_PROXY)$/ { next }
      { print }
    ' /etc/environment > "$output"
  else
    : > "$output"
  fi
}

merge_environment_proxy() {
  local filtered="${TMP_DIR}/environment.filtered"
  local proxy_block="${TMP_DIR}/environment.proxy"
  local merged="${TMP_DIR}/environment.merged"

  write_environment_proxy "$proxy_block"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would merge proxy variables into /etc/environment"
    return 0
  fi

  filter_environment_proxy "$filtered"
  cat "$filtered" "$proxy_block" > "$merged"
  run_root install -m 0644 "$merged" /etc/environment
}

write_apt_proxy() {
  local apt_tmp="${TMP_DIR}/95proxies"

  cat > "$apt_tmp" <<EOF
Acquire::http::Proxy "${HTTP_PROXY_URL}";
Acquire::https::Proxy "${HTTP_PROXY_URL}";
EOF
  run_root install -m 0644 "$apt_tmp" /etc/apt/apt.conf.d/95proxies
}

systemd_unit_exists() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --no-legend "$unit" 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$unit"
}

write_docker_proxy() {
  local docker_tmp="${TMP_DIR}/http-proxy.conf"

  cat > "$docker_tmp" <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY_URL}"
Environment="HTTPS_PROXY=${HTTP_PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY_LIST}"
EOF

  if systemd_unit_exists docker.service; then
    run_root mkdir -p /etc/systemd/system/docker.service.d
    run_root install -m 0644 "$docker_tmp" /etc/systemd/system/docker.service.d/http-proxy.conf
    run_root systemctl daemon-reload
    if systemctl is-active docker >/dev/null 2>&1; then
      run_root systemctl restart docker
    else
      warn "docker service is not active; proxy drop-in was written but docker was not restarted"
    fi
  else
    warn "docker.service was not found; skipped Docker proxy config"
  fi
}

git_global_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
  fi
}

run_git_global() {
  local user
  user="$(git_global_user)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    if [[ -n "$user" ]]; then
      printf ' sudo -H -u %q' "$user"
    fi
    printf ' git config --global'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  if [[ -n "$user" ]]; then
    sudo -H -u "$user" git config --global "$@"
  else
    git config --global "$@"
  fi
}

run_optional_git_global() {
  run_git_global "$@" || true
}

configure_git_proxy() {
  run_root git config --system --replace-all http.proxy "$HTTP_PROXY_URL"
  run_root git config --system --replace-all https.proxy "$HTTP_PROXY_URL"
  run_git_global --replace-all http.proxy "$HTTP_PROXY_URL"
  run_git_global --replace-all https.proxy "$HTTP_PROXY_URL"
}

unset_git_proxy() {
  run_optional_root git config --system --unset-all http.proxy
  run_optional_root git config --system --unset-all https.proxy
  run_optional_git_global --unset-all http.proxy
  run_optional_git_global --unset-all https.proxy
}

configure_proxy() {
  local profile_tmp="${TMP_DIR}/proxy.sh"

  derive_proxy_urls

  log "Configuring proxy"
  log "HTTP(S): ${HTTP_PROXY_URL}"
  log "ALL:     ${ALL_PROXY_URL}"
  log "NO_PROXY:${NO_PROXY_LIST}"

  write_profile_proxy "$profile_tmp"
  run_root install -m 0644 "$profile_tmp" /etc/profile.d/proxy.sh
  merge_environment_proxy
  merge_bashrc_http_proxy

  if [[ "$SKIP_APT" -eq 0 && "$CONFIGURE_APT" -eq 1 ]]; then
    write_apt_proxy
  fi

  if [[ "$SKIP_GIT" -eq 0 ]]; then
    if command -v git >/dev/null 2>&1; then
      configure_git_proxy
      merge_github_ssh_config
    else
      warn "git is not installed; skipped git proxy config"
    fi
  fi

  if [[ "$SKIP_DOCKER" -eq 0 ]]; then
    write_docker_proxy
  fi
}

unset_environment_proxy() {
  local filtered="${TMP_DIR}/environment.filtered"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would remove proxy variables from /etc/environment"
    return 0
  fi

  filter_environment_proxy "$filtered"
  run_root install -m 0644 "$filtered" /etc/environment
}

unset_proxy() {
  log "Removing proxy settings managed by ${SCRIPT_NAME}"
  run_optional_root rm -f /etc/profile.d/proxy.sh
  unset_environment_proxy
  unset_bashrc_http_proxy

  if [[ "$SKIP_APT" -eq 0 ]]; then
    run_optional_root rm -f /etc/apt/apt.conf.d/95proxies
  fi

  if [[ "$SKIP_GIT" -eq 0 && $(command -v git || true) ]]; then
    unset_git_proxy
    unset_github_ssh_config
  fi

  if [[ "$SKIP_DOCKER" -eq 0 ]]; then
    run_optional_root rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
    if command -v systemctl >/dev/null 2>&1; then
      run_optional_root systemctl daemon-reload
      if systemctl is-active docker >/dev/null 2>&1; then
        run_optional_root systemctl restart docker
      fi
    fi
  fi
}

print_summary() {
  local http_env_status="disabled by default"

  if [[ "$UNSET_PROXY" -eq 1 ]]; then
    cat <<'EOF'

Done.
Open a new shell for environment changes to take effect.
EOF
    return 0
  fi

  if [[ "$CONFIGURE_HTTP_ENV" -eq 1 ]]; then
    http_env_status="enabled"
  fi

  cat <<EOF

Done.
  ALL:     ${ALL_PROXY_URL}
  ~/.bashrc HTTP(S) env: enabled
  system HTTP(S) env: ${http_env_status}
  GitHub SSH: ssh.github.com:443

Open a new shell or run:
  source /etc/profile.d/proxy.sh
  source "$(target_bashrc)"

Quick check:
  echo \$all_proxy
  echo \$https_proxy
  curl -I https://www.google.com
EOF
}

main() {
  parse_args "$@"
  select_default_proxy

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_cmd sudo
  fi
  require_cmd awk
  require_cmd install
  require_cmd rm

  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"' EXIT

  if [[ "$UNSET_PROXY" -eq 1 ]]; then
    unset_proxy
  else
    configure_proxy
  fi

  print_summary
}

main "$@"
