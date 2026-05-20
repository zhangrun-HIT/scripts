#!/usr/bin/env bash
# Install or update mihomo, MetaCubeXD UI, and common Linux proxy settings.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_UI_DIR="/etc/mihomo/ui"
MIHOMO_LOG_DIR="/var/log/mihomo"
MIHOMO_CONFIG_FILE="/etc/mihomo/config.yaml"
SUB_URL_FILE="/etc/mihomo/subscription.url"

HTTP_PORT="7897"
SOCKS_PORT="7891"
CONTROLLER_ADDR="0.0.0.0:9090"
ALLOW_LAN="false"
SECRET=""
DOWNLOAD_PROXY=""
SUB_URL="${MIHOMO_SUB_URL:-}"
SUB_URL_PATH=""
FETCH_UA="${MIHOMO_SUB_UA:-clash-verge/v2.4.0}"
CUSTOM_UA=0
SKIP_SUBSCRIPTION=0
SKIP_SYSTEM_PROXY=0
SKIP_DOCKER_PROXY=0
DRY_RUN=0
TMP_DIR=""
MIHOMO_DEB_DIR=""

declare -a EXTRA_HEADERS=()

usage() {
  cat <<'EOF'
Usage:
  install_mihomo_proxy.sh --sub-url URL [options]
  MIHOMO_SUB_URL=URL install_mihomo_proxy.sh [options]

Options:
      --sub-url URL          Subscription URL for /etc/mihomo/config.yaml.
      --sub-url-file FILE    Read the subscription URL from FILE.
      --user-agent VALUE     User-Agent used when fetching the subscription.
                             Default: clash-verge/v2.4.0
      --header 'K: V'        Extra header for subscription fetch. Can repeat.
      --download-proxy URL   Proxy used by curl while downloading releases/subscription.
      --http-port PORT       HTTP proxy port written to mihomo/system config.
                             Default: 7897
      --socks-port PORT      SOCKS proxy port written to mihomo/system config.
                             Default: 7891
      --controller ADDR      external-controller value. Default: 0.0.0.0:9090
      --allow-lan true|false allow-lan value. Default: false
      --secret VALUE         Secret for the mihomo external controller.
      --skip-subscription    Do not download config.yaml; keep the current file.
      --skip-system-proxy    Do not write /etc/profile.d, /etc/environment,
                             apt, git, or docker proxy settings.
      --skip-docker-proxy    Do not write/restart Docker proxy settings.
      --dry-run              Print planned actions without changing the system.
  -h, --help                 Show this help.

Examples:
  install_mihomo_proxy.sh --sub-url 'https://example.com/api/v1/client/subscribe?token=...'
  MIHOMO_SUB_URL='https://example.com/sub' install_mihomo_proxy.sh
  install_mihomo_proxy.sh --sub-url-file ~/.config/mihomo/sub_url
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

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_root_cmd() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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

  need_root_cmd "$@"
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

parse_args() {
  while (($#)); do
    case "$1" in
      --sub-url)
        [[ $# -ge 2 ]] || die "--sub-url requires a value"
        SUB_URL="$2"
        shift 2
        ;;
      --sub-url-file)
        [[ $# -ge 2 ]] || die "--sub-url-file requires a value"
        SUB_URL_PATH="$2"
        shift 2
        ;;
      --user-agent)
        [[ $# -ge 2 ]] || die "--user-agent requires a value"
        FETCH_UA="$2"
        CUSTOM_UA=1
        shift 2
        ;;
      --header)
        [[ $# -ge 2 ]] || die "--header requires a value"
        EXTRA_HEADERS+=("$2")
        shift 2
        ;;
      --download-proxy)
        [[ $# -ge 2 ]] || die "--download-proxy requires a value"
        DOWNLOAD_PROXY="$2"
        shift 2
        ;;
      --http-port)
        [[ $# -ge 2 ]] || die "--http-port requires a value"
        HTTP_PORT="$2"
        shift 2
        ;;
      --socks-port)
        [[ $# -ge 2 ]] || die "--socks-port requires a value"
        SOCKS_PORT="$2"
        shift 2
        ;;
      --controller)
        [[ $# -ge 2 ]] || die "--controller requires a value"
        CONTROLLER_ADDR="$2"
        shift 2
        ;;
      --allow-lan)
        [[ $# -ge 2 ]] || die "--allow-lan requires true or false"
        ALLOW_LAN="$2"
        shift 2
        ;;
      --secret)
        [[ $# -ge 2 ]] || die "--secret requires a value"
        SECRET="$2"
        shift 2
        ;;
      --skip-subscription)
        SKIP_SUBSCRIPTION=1
        shift
        ;;
      --skip-system-proxy)
        SKIP_SYSTEM_PROXY=1
        shift
        ;;
      --skip-docker-proxy)
        SKIP_DOCKER_PROXY=1
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

  is_port "$HTTP_PORT" || die "invalid --http-port: $HTTP_PORT"
  is_port "$SOCKS_PORT" || die "invalid --socks-port: $SOCKS_PORT"
  [[ "$ALLOW_LAN" == "true" || "$ALLOW_LAN" == "false" ]] || die "--allow-lan must be true or false"

  if [[ -n "$SUB_URL_PATH" ]]; then
    [[ -r "$SUB_URL_PATH" ]] || die "subscription URL file is not readable: $SUB_URL_PATH"
    SUB_URL="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$SUB_URL_PATH")"
  fi

  if [[ "$SKIP_SUBSCRIPTION" -eq 0 && -z "$SUB_URL" && -r "$SUB_URL_FILE" ]]; then
    SUB_URL="$(run_root cat "$SUB_URL_FILE" 2>/dev/null | sed -n '1{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q}')"
  fi

  if [[ "$SKIP_SUBSCRIPTION" -eq 0 && -z "$SUB_URL" ]]; then
    die "provide --sub-url URL, MIHOMO_SUB_URL, or --skip-subscription"
  fi
}

curl_base() {
  local -a args=(curl --fail --location --show-error --silent --compressed --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180)
  if [[ -n "$DOWNLOAD_PROXY" ]]; then
    args+=(--proxy "$DOWNLOAD_PROXY")
  fi
  printf '%s\0' "${args[@]}"
}

download_to() {
  local url="$1"
  local output="$2"
  local -a curl_cmd=()
  mapfile -d '' -t curl_cmd < <(curl_base)
  run "${curl_cmd[@]}" "$url" --output "$output"
}

github_latest_asset_url() {
  local repo="$1"
  local selector="$2"
  local json_file="$3"
  local asset_arch="${4:-}"

  download_to "https://api.github.com/repos/${repo}/releases/latest" "$json_file"

  python3 - "$selector" "$json_file" "$asset_arch" <<'PY'
import json
import re
import sys

selector = sys.argv[1]
json_file = sys.argv[2]
asset_arch = sys.argv[3] if len(sys.argv) > 3 else ""
release = json.load(open(json_file, encoding="utf-8"))
assets = release.get("assets", [])

def emit(asset):
    print(release.get("tag_name", ""))
    print(asset.get("name", ""))
    print(asset.get("browser_download_url", ""))
    sys.exit(0)

if selector == "mihomo-deb":
    if not asset_arch:
        print("mihomo architecture was not provided", file=sys.stderr)
        sys.exit(1)

    tag = release.get("tag_name", "")
    candidates = [
        asset for asset in assets
        if asset.get("name", "").startswith(f"mihomo-linux-{asset_arch}-")
        and asset.get("name", "").endswith(".deb")
    ]

    if not candidates:
        available = [
            asset.get("name", "")
            for asset in assets
            if asset.get("name", "").startswith("mihomo-linux-")
            and asset.get("name", "").endswith(".deb")
        ]
        print(f"no mihomo linux .deb asset found for architecture: {asset_arch}", file=sys.stderr)
        if available:
            print("available .deb assets:", file=sys.stderr)
            for name in available:
                print(f"  {name}", file=sys.stderr)
        sys.exit(1)

    generic_name = f"mihomo-linux-{asset_arch}-{tag}.deb"

    def score(asset):
        name = asset.get("name", "")
        if name == generic_name:
            return (0, name)
        match = re.match(rf"^mihomo-linux-{re.escape(asset_arch)}-v([0-9]+)-{re.escape(tag)}\.deb$", name)
        if match:
            return (10 + int(match.group(1)), name)
        return (100, name)

    emit(sorted(candidates, key=score)[0])

for asset in assets:
    name = asset.get("name", "")
    if selector == "metacubexd-tgz":
        if name == "compressed-dist.tgz":
            emit(asset)

print(f"no matching asset for {selector}", file=sys.stderr)
sys.exit(1)
PY
}

detect_mihomo_arch() {
  local arch=""

  if command -v dpkg >/dev/null 2>&1; then
    arch="$(dpkg --print-architecture)"
  else
    arch="$(uname -m)"
  fi

  case "$arch" in
    amd64|x86_64)
      printf 'amd64\n'
      ;;
    arm64|aarch64)
      printf 'arm64\n'
      ;;
    armhf|armv7l|armv7*)
      printf 'armv7\n'
      ;;
    armel|armv6l|armv6*)
      printf 'armv6\n'
      ;;
    i386|i686|386)
      printf '386\n'
      ;;
    riscv64)
      printf 'riscv64\n'
      ;;
    *)
      die "unsupported system architecture for mihomo .deb: ${arch}"
      ;;
  esac
}

install_prerequisites() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_cmd sudo
  fi

  require_cmd apt-get

  log "Installing prerequisite packages"
  run_root apt-get update
  run_root apt-get install -y \
    ca-certificates \
    coreutils \
    curl \
    findutils \
    gawk \
    gzip \
    python3 \
    sed \
    tar

  if [[ "$DRY_RUN" -eq 0 ]]; then
    require_cmd curl
    require_cmd python3
    require_cmd tar
    require_cmd sed
    require_cmd awk
    require_cmd find
  fi
}

install_mihomo() {
  local tmp_dir="$1"
  local release_info="${tmp_dir}/mihomo-release.txt"
  local deb_path=""
  local mihomo_arch=""
  local tag=""
  local asset_name=""
  local asset_url=""

  mihomo_arch="$(detect_mihomo_arch)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would resolve, download, and install the latest MetaCubeX/mihomo ${mihomo_arch} .deb"
    return 0
  fi

  log "Detected system architecture for mihomo: ${mihomo_arch}"
  github_latest_asset_url "MetaCubeX/mihomo" "mihomo-deb" "${tmp_dir}/mihomo-release.json" "$mihomo_arch" > "$release_info"
  mapfile -t lines < "$release_info"
  tag="${lines[0]:-}"
  asset_name="${lines[1]:-}"
  asset_url="${lines[2]:-}"
  [[ -n "$asset_url" ]] || die "could not resolve latest mihomo .deb asset"

  MIHOMO_DEB_DIR="$(mktemp -d /tmp/mihomo-deb.XXXXXX)"
  chmod 0755 "$MIHOMO_DEB_DIR"
  deb_path="${MIHOMO_DEB_DIR}/mihomo.deb"

  log "Downloading mihomo ${tag} (${asset_name})"
  download_to "$asset_url" "$deb_path"
  chmod 0644 "$deb_path"

  log "Installing mihomo package"
  run_root apt-get install -y "$deb_path"
  rm -rf -- "$MIHOMO_DEB_DIR"
  MIHOMO_DEB_DIR=""

  if command -v mihomo >/dev/null 2>&1; then
    log "Installed $(mihomo -v | head -n 1)"
  fi
}

install_ui() {
  local tmp_dir="$1"
  local release_info="${tmp_dir}/metacubexd-release.txt"
  local tgz_path="${tmp_dir}/metacubexd.tgz"
  local unpack_dir="${tmp_dir}/metacubexd"
  local tag=""
  local asset_url=""
  local index_file=""
  local ui_src=""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would resolve, download, and install the latest MetaCubeXD compressed-dist.tgz"
    return 0
  fi

  github_latest_asset_url "MetaCubeX/metacubexd" "metacubexd-tgz" "${tmp_dir}/metacubexd-release.json" > "$release_info"
  mapfile -t lines < "$release_info"
  tag="${lines[0]:-}"
  asset_url="${lines[2]:-}"
  [[ -n "$asset_url" ]] || die "could not resolve latest MetaCubeXD UI asset"

  log "Downloading MetaCubeXD UI ${tag}"
  download_to "$asset_url" "$tgz_path"

  mkdir -p "$unpack_dir"
  tar -xzf "$tgz_path" -C "$unpack_dir"
  index_file="$(find "$unpack_dir" -type f -name index.html | head -n 1)"
  [[ -n "$index_file" ]] || die "MetaCubeXD archive does not contain index.html"
  ui_src="$(dirname "$index_file")"

  log "Installing UI files to ${MIHOMO_UI_DIR}"
  run_root mkdir -p "$MIHOMO_UI_DIR"
  run_root find "$MIHOMO_UI_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  run_root cp -a "${ui_src}/." "$MIHOMO_UI_DIR/"
}

backup_config_if_needed() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if [[ -f "$MIHOMO_CONFIG_FILE" ]]; then
    local stamp=""
    stamp="$(date +%Y%m%d-%H%M%S)"
    run_root cp -a "$MIHOMO_CONFIG_FILE" "${MIHOMO_CONFIG_FILE}.bak-${stamp}"
    log "Backed up existing config to ${MIHOMO_CONFIG_FILE}.bak-${stamp}"
  fi
}

fetch_subscription_config() {
  local tmp_dir="$1"
  local output="${tmp_dir}/config.yaml"
  local -a curl_cmd=()
  local -a header_args=()
  local -a user_agents=("$FETCH_UA")
  local header=""
  local ua=""
  local candidate=""
  local attempt_file=""
  local attempt=0
  local best_file=""
  local best_ua=""

  mapfile -d '' -t curl_cmd < <(curl_base)

  if [[ "$CUSTOM_UA" -eq 0 ]]; then
    for candidate in "clash-verge/v2.4.0" "Clash Verge/v2.4.0" "clash-verge/v2.4.2" "Clash Verge/v2.4.2" "clash-verge/v1.7.7" "ClashforWindows/0.20.39" "ClashMetaForAndroid/2.11.13" "clash"; do
      [[ "$candidate" == "$FETCH_UA" ]] && continue
      user_agents+=("$candidate")
    done
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would fetch subscription config with Clash Verge compatible headers"
    return 0
  fi

  log "Fetching subscription config with Clash Verge compatible headers"
  for ua in "${user_agents[@]}"; do
    attempt=$((attempt + 1))
    attempt_file="${tmp_dir}/config.${attempt}.yaml"
    header_args=(-H "User-Agent: ${ua}" -H "Accept: */*" -H "Cache-Control: no-cache" -H "Pragma: no-cache")
    for header in "${EXTRA_HEADERS[@]}"; do
      header_args+=(-H "$header")
    done

    if ! "${curl_cmd[@]}" "${header_args[@]}" "$SUB_URL" --output "$attempt_file"; then
      warn "subscription fetch failed with User-Agent: ${ua}"
      continue
    fi

    if [[ ! -s "$attempt_file" ]]; then
      warn "subscription response is empty with User-Agent: ${ua}"
      continue
    fi

    if grep -qiE '<html|<!doctype html|subscription.*expired|invalid|forbidden|unauthorized' "$attempt_file"; then
      warn "subscription response looks like an error page with User-Agent: ${ua}"
      continue
    fi

    if grep -qE '^(proxies|proxy-providers|proxy-groups|rules|mixed-port|port|socks-port):' "$attempt_file"; then
      cp "$attempt_file" "$output"
      log "Subscription fetched successfully with User-Agent: ${ua}"
      best_file=""
      break
    fi

    if [[ -z "$best_file" ]]; then
      best_file="$attempt_file"
      best_ua="$ua"
    fi
  done

  if [[ ! -s "$output" && -n "$best_file" ]]; then
    cp "$best_file" "$output"
    warn "subscription response fetched with User-Agent: ${best_ua}, but it does not look like a normal mihomo YAML config"
  fi

  [[ -s "$output" ]] || die "could not fetch a usable subscription config; try --user-agent or --header"

  if ! grep -qE '^(proxies|proxy-providers|proxy-groups|rules|mixed-port|port|socks-port):' "$output"; then
    warn "installing subscription response even though normal mihomo YAML keys were not detected"
  fi

  backup_config_if_needed
  run_root mkdir -p "$MIHOMO_CONFIG_DIR"
  run_root install -m 0644 "$output" "$MIHOMO_CONFIG_FILE"

  if [[ -n "$SUB_URL" ]]; then
    printf '%s\n' "$SUB_URL" > "${tmp_dir}/subscription.url"
    run_root install -m 0600 "${tmp_dir}/subscription.url" "$SUB_URL_FILE"
  fi
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

set_yaml_key() {
  local key="$1"
  local value="$2"
  local tmp_file="$3"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would set ${key}: ${value} in ${MIHOMO_CONFIG_FILE}"
    return 0
  fi

  # shellcheck disable=SC2016
  run_root awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" { next }
    { print }
  ' "$MIHOMO_CONFIG_FILE" > "$tmp_file"
  printf '%s: %s\n' "$key" "$value" >> "$tmp_file"
  run_root install -m 0644 "$tmp_file" "$MIHOMO_CONFIG_FILE"
}

configure_mihomo_yaml() {
  local tmp_dir="$1"
  local tmp_file="${tmp_dir}/config-patched.yaml"

  [[ "$DRY_RUN" -eq 1 || -f "$MIHOMO_CONFIG_FILE" ]] || die "mihomo config not found: $MIHOMO_CONFIG_FILE"

  set_yaml_key "port" "$HTTP_PORT" "$tmp_file"
  set_yaml_key "socks-port" "$SOCKS_PORT" "$tmp_file"
  set_yaml_key "allow-lan" "$ALLOW_LAN" "$tmp_file"
  set_yaml_key "external-controller" "$(yaml_quote "$CONTROLLER_ADDR")" "$tmp_file"
  set_yaml_key "external-ui" "$MIHOMO_UI_DIR" "$tmp_file"
  set_yaml_key "secret" "$(yaml_quote "$SECRET")" "$tmp_file"
}

write_profile_proxy() {
  local tmp_file="$1"
  cat > "$tmp_file" <<EOF
# Global proxy for all users. Managed by ${SCRIPT_NAME}.
export http_proxy="http://127.0.0.1:${HTTP_PORT}"
export https_proxy="http://127.0.0.1:${HTTP_PORT}"
export HTTP_PROXY="http://127.0.0.1:${HTTP_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${HTTP_PORT}"
export all_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
export ALL_PROXY="socks5h://127.0.0.1:${SOCKS_PORT}"
export no_proxy="localhost,127.0.0.1,::1,0.0.0.0,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
export NO_PROXY="\$no_proxy"
EOF
}

write_environment_proxy() {
  local tmp_file="$1"
  cat > "$tmp_file" <<EOF
http_proxy=http://127.0.0.1:${HTTP_PORT}
https_proxy=http://127.0.0.1:${HTTP_PORT}
HTTP_PROXY=http://127.0.0.1:${HTTP_PORT}
HTTPS_PROXY=http://127.0.0.1:${HTTP_PORT}
all_proxy=socks5h://127.0.0.1:${SOCKS_PORT}
ALL_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}
no_proxy=localhost,127.0.0.1,::1,0.0.0.0,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
NO_PROXY=localhost,127.0.0.1,::1,0.0.0.0,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
EOF
}

merge_environment_proxy() {
  local tmp_dir="$1"
  local filtered="${tmp_dir}/environment.filtered"
  local proxy_block="${tmp_dir}/environment.proxy"
  local merged="${tmp_dir}/environment.merged"

  write_environment_proxy "$proxy_block"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would merge proxy variables into /etc/environment"
    return 0
  fi

  if [[ -f /etc/environment ]]; then
    # shellcheck disable=SC2016
    run_root awk -F= '
      $1 ~ /^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|all_proxy|ALL_PROXY|no_proxy|NO_PROXY)$/ { next }
      { print }
    ' /etc/environment > "$filtered"
  else
    : > "$filtered"
  fi

  cat "$filtered" "$proxy_block" > "$merged"
  run_root install -m 0644 "$merged" /etc/environment
}

configure_system_proxy() {
  local tmp_dir="$1"
  local profile_tmp="${tmp_dir}/proxy.sh"
  local apt_tmp="${tmp_dir}/95proxies"
  local docker_tmp="${tmp_dir}/http-proxy.conf"

  log "Writing system proxy environment"
  write_profile_proxy "$profile_tmp"
  run_root install -m 0644 "$profile_tmp" /etc/profile.d/proxy.sh
  merge_environment_proxy "$tmp_dir"

  cat > "$apt_tmp" <<EOF
Acquire::http::Proxy "http://127.0.0.1:${HTTP_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${HTTP_PORT}";
EOF
  run_root install -m 0644 "$apt_tmp" /etc/apt/apt.conf.d/95proxies

  if command -v git >/dev/null 2>&1; then
    run_root git config --system http.proxy "http://127.0.0.1:${HTTP_PORT}"
    run_root git config --system https.proxy "http://127.0.0.1:${HTTP_PORT}"
  else
    warn "git is not installed; skipped git proxy config"
  fi

  if [[ "$SKIP_DOCKER_PROXY" -eq 1 ]]; then
    return 0
  fi

  cat > "$docker_tmp" <<EOF
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:${HTTP_PORT}"
Environment="HTTPS_PROXY=http://127.0.0.1:${HTTP_PORT}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
EOF

  if systemd_unit_exists docker.service; then
    log "Writing Docker systemd proxy"
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

restart_mihomo() {
  if systemd_unit_exists mihomo.service; then
    log "Enabling and restarting mihomo.service"
    run_root systemctl enable mihomo
    run_root systemctl restart mihomo
    run_root systemctl is-enabled mihomo
  else
    warn "mihomo.service was not found or systemd is unavailable; start mihomo manually"
  fi
}

systemd_unit_exists() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --no-legend "$unit" 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$unit"
}

print_summary() {
  cat <<EOF

Done.
  Config: ${MIHOMO_CONFIG_FILE}
  UI:     ${MIHOMO_UI_DIR}
  HTTP:   http://127.0.0.1:${HTTP_PORT}
  SOCKS:  socks5h://127.0.0.1:${SOCKS_PORT}
  UI URL: http://<server-ip>:${CONTROLLER_ADDR##*:}/ui

Open a new shell or run:
  source /etc/profile.d/proxy.sh

Quick checks:
  mihomo -v
  curl -I https://www.google.com
EOF
}

main() {
  parse_args "$@"
  install_prerequisites

  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"; [[ -n "${MIHOMO_DEB_DIR:-}" ]] && rm -rf -- "$MIHOMO_DEB_DIR"' EXIT

  log "Creating mihomo directories"
  run_root mkdir -p "$MIHOMO_CONFIG_DIR" "$MIHOMO_UI_DIR" "$MIHOMO_LOG_DIR"

  install_mihomo "$TMP_DIR"
  install_ui "$TMP_DIR"

  if [[ "$SKIP_SUBSCRIPTION" -eq 0 ]]; then
    fetch_subscription_config "$TMP_DIR"
  fi

  configure_mihomo_yaml "$TMP_DIR"

  if [[ "$SKIP_SYSTEM_PROXY" -eq 0 ]]; then
    configure_system_proxy "$TMP_DIR"
  fi

  restart_mihomo
  print_summary
}

main "$@"
