#!/usr/bin/env bash
# Configure or remove common Linux proxy settings for this machine.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

PROXY_INPUT="127.0.0.1:7897"
HTTP_PROXY_URL=""
ALL_PROXY_URL=""
NO_PROXY_LIST="localhost,127.0.0.1,::1,0.0.0.0,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
SKIP_APT=0
SKIP_GIT=0
SKIP_DOCKER=0
UNSET_PROXY=0
DRY_RUN=0
TMP_DIR=""

usage() {
  cat <<'EOF'
Usage:
  configure_proxy.sh [options]
  configure_proxy.sh --proxy HOST:PORT
  configure_proxy.sh --proxy http://HOST:PORT
  configure_proxy.sh --unset

Options:
      --proxy VALUE       Proxy address or URL. Default: 127.0.0.1:7897
                          HOST:PORT becomes http://HOST:PORT for http(s)
                          variables and socks5h://HOST:PORT for all_proxy.
      --all-proxy URL     Override all_proxy/ALL_PROXY. Default is derived
                          from --proxy as socks5h://HOST:PORT.
      --no-proxy LIST     Override no_proxy/NO_PROXY.
      --skip-apt          Do not configure apt proxy.
      --skip-git          Do not configure system git proxy.
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
  cat > "$tmp_file" <<EOF
# Global proxy for all users. Managed by ${SCRIPT_NAME}.
export http_proxy="${HTTP_PROXY_URL}"
export https_proxy="${HTTP_PROXY_URL}"
export HTTP_PROXY="${HTTP_PROXY_URL}"
export HTTPS_PROXY="${HTTP_PROXY_URL}"
export all_proxy="${ALL_PROXY_URL}"
export ALL_PROXY="${ALL_PROXY_URL}"
export no_proxy="${NO_PROXY_LIST}"
export NO_PROXY="\$no_proxy"
EOF
}

write_environment_proxy() {
  local tmp_file="$1"
  cat > "$tmp_file" <<EOF
http_proxy=${HTTP_PROXY_URL}
https_proxy=${HTTP_PROXY_URL}
HTTP_PROXY=${HTTP_PROXY_URL}
HTTPS_PROXY=${HTTP_PROXY_URL}
all_proxy=${ALL_PROXY_URL}
ALL_PROXY=${ALL_PROXY_URL}
no_proxy=${NO_PROXY_LIST}
NO_PROXY=${NO_PROXY_LIST}
EOF
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

  if [[ "$SKIP_APT" -eq 0 ]]; then
    write_apt_proxy
  fi

  if [[ "$SKIP_GIT" -eq 0 ]]; then
    if command -v git >/dev/null 2>&1; then
      run_root git config --system http.proxy "$HTTP_PROXY_URL"
      run_root git config --system https.proxy "$HTTP_PROXY_URL"
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

  if [[ "$SKIP_APT" -eq 0 ]]; then
    run_optional_root rm -f /etc/apt/apt.conf.d/95proxies
  fi

  if [[ "$SKIP_GIT" -eq 0 && $(command -v git || true) ]]; then
    run_optional_root git config --system --unset http.proxy
    run_optional_root git config --system --unset https.proxy
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
  if [[ "$UNSET_PROXY" -eq 1 ]]; then
    cat <<'EOF'

Done.
Open a new shell for environment changes to take effect.
EOF
    return 0
  fi

  cat <<EOF

Done.
  HTTP(S): ${HTTP_PROXY_URL}
  ALL:     ${ALL_PROXY_URL}

Open a new shell or run:
  source /etc/profile.d/proxy.sh

Quick check:
  echo \$http_proxy
  curl -I https://www.google.com
EOF
}

main() {
  parse_args "$@"

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
