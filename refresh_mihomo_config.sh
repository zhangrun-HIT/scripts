#!/usr/bin/env bash
# Refresh /etc/mihomo/config.yaml from a subscription and a GitHub-hosted customizer.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$SCRIPT_PATH")"
# shellcheck source=lib/self_update.sh
source "${SCRIPT_DIR}/lib/self_update.sh"
scripts_self_update "$SCRIPT_DIR" "$SCRIPT_PATH" "$@"

SCRIPT_NAME="$(basename "$0")"

MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_UI_DIR="/etc/mihomo/ui"
MIHOMO_CONFIG_FILE="/etc/mihomo/config.yaml"
SUB_URL_FILE="/etc/mihomo/subscription.url"
SUBSCRIPTION_CACHE_FILE="/etc/mihomo/subscription.last-known-good.yaml"
FINAL_CONFIG_CACHE_FILE="/etc/mihomo/config.yaml.last-known-good"
CUSTOMIZER_CACHE_FILE="/etc/mihomo/clash-verge-script.last-known-good.js"
CUSTOMIZER_URL="${MIHOMO_CUSTOMIZER_URL:-https://raw.githubusercontent.com/zhangrun-HIT/clash-subscription-customizer/main/clash-verge-script.js}"
CUSTOMIZER_JS=""

HTTP_PORT="7897"
SOCKS_PORT="7891"
CONTROLLER_ADDR="0.0.0.0:9090"
ALLOW_LAN="false"
SECRET=""
DOWNLOAD_PROXY=""
SUB_URL="${MIHOMO_SUB_URL:-}"
SUB_URL_SOURCE=""
SUB_URL_PATH=""
FETCH_UA="${MIHOMO_SUB_UA:-clash-verge/v2.4.2}"
CUSTOM_UA=0
DRY_RUN=0
NO_RESTART=0
SKIP_PREREQUISITES=0
TMP_DIR=""
CONFIG_ROLLBACK_FILE=""

declare -a EXTRA_HEADERS=()

usage() {
  cat <<'EOF'
Usage:
  refresh_mihomo_config.sh --sub-url URL [options]
  refresh_mihomo_config.sh [options]

Options:
      --sub-url URL             Subscription URL to fetch.
      --sub-url-file FILE       Read the subscription URL from FILE.
      --subscription-file FILE  Stored subscription URL file.
                                Default: /etc/mihomo/subscription.url
      --customizer-url URL      GitHub raw URL for the temporary JS customizer.
                                Default:
                                  https://raw.githubusercontent.com/zhangrun-HIT/clash-subscription-customizer/main/clash-verge-script.js
      --config-file FILE        Mihomo config to update.
                                Default: /etc/mihomo/config.yaml
      --user-agent VALUE        User-Agent used when fetching the subscription.
                                Default: clash-verge/v2.4.2
      --header 'K: V'           Extra header for subscription fetch. Can repeat.
      --download-proxy URL      Proxy used by curl while downloading subscription.
      --http-port PORT          HTTP proxy port written to mihomo config.
                                Default: 7897
      --socks-port PORT         SOCKS proxy port written to mihomo config.
                                Default: 7891
      --controller ADDR         external-controller value.
                                Default: 0.0.0.0:9090
      --external-ui PATH        external-ui value. Default: /etc/mihomo/ui
      --allow-lan true|false    allow-lan value. Default: false
      --secret VALUE            Secret for the mihomo external controller.
      --no-restart              Do not restart mihomo.service after writing config.
      --skip-prerequisites      Do not install required apt packages.
      --dry-run                 Print planned actions without changing the system.
  -h, --help                    Show this help.

Examples:
  refresh_mihomo_config.sh --sub-url 'https://example.com/subscribe?...'
  refresh_mihomo_config.sh
  refresh_mihomo_config.sh --customizer-url https://raw.githubusercontent.com/OWNER/REPO/BRANCH/file.js
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

read_first_config_line() {
  sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$1"
}

read_stored_sub_url() {
  local file="$1"

  [[ -e "$file" ]] || return 0

  if [[ -r "$file" ]]; then
    sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$file"
    return 0
  fi

  if need_root_cmd test -r "$file" 2>/dev/null; then
    need_root_cmd sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$file"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --sub-url)
        [[ $# -ge 2 ]] || die "--sub-url requires a value"
        SUB_URL="$2"
        SUB_URL_SOURCE="--sub-url"
        shift 2
        ;;
      --sub-url-file)
        [[ $# -ge 2 ]] || die "--sub-url-file requires a value"
        SUB_URL_PATH="$2"
        shift 2
        ;;
      --subscription-file)
        [[ $# -ge 2 ]] || die "--subscription-file requires a value"
        SUB_URL_FILE="$2"
        shift 2
        ;;
      --customizer-url)
        [[ $# -ge 2 ]] || die "--customizer-url requires a value"
        CUSTOMIZER_URL="$2"
        shift 2
        ;;
      --config-file)
        [[ $# -ge 2 ]] || die "--config-file requires a value"
        MIHOMO_CONFIG_FILE="$2"
        MIHOMO_CONFIG_DIR="$(dirname -- "$MIHOMO_CONFIG_FILE")"
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
      --external-ui)
        [[ $# -ge 2 ]] || die "--external-ui requires a value"
        MIHOMO_UI_DIR="$2"
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
      --no-restart)
        NO_RESTART=1
        shift
        ;;
      --skip-prerequisites)
        SKIP_PREREQUISITES=1
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
    SUB_URL="$(read_first_config_line "$SUB_URL_PATH")"
    SUB_URL_SOURCE="$SUB_URL_PATH"
  fi

  if [[ -z "$SUB_URL" ]]; then
    SUB_URL="$(read_stored_sub_url "$SUB_URL_FILE" || true)"
    [[ -n "$SUB_URL" ]] && SUB_URL_SOURCE="$SUB_URL_FILE"
  fi

  [[ -n "$SUB_URL" ]] || die "provide --sub-url URL once, or keep a readable ${SUB_URL_FILE}"
  [[ -n "$SUB_URL_SOURCE" ]] || SUB_URL_SOURCE="MIHOMO_SUB_URL"
  [[ -n "$CUSTOMIZER_URL" ]] || die "--customizer-url cannot be empty"
}

install_prerequisites() {
  if [[ "$SKIP_PREREQUISITES" -eq 1 ]]; then
    require_cmd curl
    require_cmd node
    require_cmd python3
    python3 - <<'PY'
import yaml  # noqa: F401
PY
    return 0
  fi

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
    nodejs \
    python3 \
    python3-yaml \
    sed

  if [[ "$DRY_RUN" -eq 0 ]]; then
    require_cmd curl
    require_cmd node
    require_cmd python3
    python3 - <<'PY'
import yaml  # noqa: F401
PY
  fi
}

curl_base() {
  local -a args=(curl --fail --location --show-error --silent --compressed --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 --http1.1)
  if [[ -n "$DOWNLOAD_PROXY" ]]; then
    args+=(--proxy "$DOWNLOAD_PROXY")
  else
    args+=(--noproxy "*")
  fi
  printf '%s\0' "${args[@]}"
}

read_root_file_to() {
  local source_file="$1"
  local output_file="$2"

  rm -f -- "$output_file"
  if [[ -r "$source_file" ]]; then
    cp -f -- "$source_file" "$output_file"
  elif need_root_cmd test -r "$source_file" 2>/dev/null; then
    need_root_cmd cat "$source_file" > "$output_file"
  else
    return 1
  fi

  [[ -s "$output_file" ]]
}

persist_cache_file() {
  local source_file="$1"
  local cache_file="$2"
  local mode="${3:-0600}"

  run_root mkdir -p "$(dirname -- "$cache_file")"
  run_root install -m "$mode" "$source_file" "$cache_file"
}

restore_cached_file() {
  local cache_file="$1"
  local output_file="$2"
  local label="$3"

  if read_root_file_to "$cache_file" "$output_file"; then
    log "Using cached ${label} from ${cache_file}"
    return 0
  fi

  return 1
}

sanitize_subscription_config() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" <<'PY'
import re
import sys

input_path, output_path = sys.argv[1], sys.argv[2]
text = open(input_path, encoding="utf-8").read()

if not re.search(r"^(proxies|proxy-providers|proxy-groups|rules|mixed-port|port|socks-port):", text, re.M):
    print("normal mihomo YAML keys were not detected", file=sys.stderr)
    sys.exit(1)

if re.search(r"^proxies:\s*\{\s*\}\s*$", text, re.M):
    print("subscription contains an empty top-level proxies map", file=sys.stderr)
    sys.exit(1)

if re.search(r"^\s+proxies:\s*\{\s*\}\s*$", text, re.M) and not re.search(r"^proxy-providers:", text, re.M):
    print("subscription contains empty proxy-group proxies maps", file=sys.stderr)
    sys.exit(1)

if re.search(r"^proxies:\s*$", text, re.M) and not re.search(r"^proxy-providers:", text, re.M):
    proxy_block = re.search(r"^proxies:\s*\n(?P<body>.*?)(?=^[^ \t#].*?:|\Z)", text, re.M | re.S)
    body = proxy_block.group("body") if proxy_block else ""
    if not re.search(r"^\s{4}server:", body, re.M) or not re.search(r"^\s{4}port:", body, re.M):
        print("subscription proxies do not include complete server/port nodes", file=sys.stderr)
        sys.exit(1)

lines = text.splitlines()
out = []
node = []

def flush_node():
    global node
    if not node:
        return
    is_anytls = any(re.match(r"^\s{4}type:\s*anytls\s*$", line, re.I) for line in node)
    has_fingerprint = any(re.match(r"^\s{4}client-fingerprint:", line) for line in node)
    for line in node:
        out.append(line)
        if is_anytls and not has_fingerprint and re.match(r"^\s{4}type:\s*anytls\s*$", line, re.I):
            out.append("    client-fingerprint: chrome")
    node = []

for line in lines:
    if re.match(r"^\s{2}-\s*$", line):
        flush_node()
        node = [line]
    elif node and re.match(r"^[^ \t#].*?:", line):
        flush_node()
        out.append(line)
    elif node:
        node.append(line)
    else:
        out.append(line)

flush_node()
open(output_path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

fetch_subscription_config() {
  local tmp_dir="$1"
  local output="${tmp_dir}/subscription.yaml"
  local normalized_file=""
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
    for candidate in \
      "clash-verge/v2.4.2" \
      "clash-verge/v2.4.7" \
      "clash-verge/v2.4.0" \
      "clash-verge/v1.7.7" \
      "ClashforWindows/0.20.39" \
      "ClashMetaForAndroid/2.11.13" \
      "clash"
    do
      [[ "$candidate" == "$FETCH_UA" ]] && continue
      user_agents+=("$candidate")
    done
  fi

  log "Fetching subscription config with Clash Verge compatible headers"
  for ua in "${user_agents[@]}"; do
    attempt=$((attempt + 1))
    attempt_file="${tmp_dir}/subscription.${attempt}.yaml"
    normalized_file="${tmp_dir}/subscription.${attempt}.normalized.yaml"
    header_args=(-H "User-Agent: ${ua}" -H "Accept: */*" -H "Cache-Control: no-cache" -H "Pragma: no-cache" -H "Connection: close")
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

    if sanitize_subscription_config "$attempt_file" "$normalized_file"; then
      cp "$normalized_file" "$output"
      persist_cache_file "$output" "$SUBSCRIPTION_CACHE_FILE" 0600
      log "Subscription fetched successfully with User-Agent: ${ua}"
      best_file=""
      break
    fi
    warn "subscription response is not usable with User-Agent: ${ua}"

    if [[ -z "$best_file" ]]; then
      best_file="$normalized_file"
      best_ua="$ua"
    fi
  done

  if [[ ! -s "$output" && -n "$best_file" ]]; then
    warn "best subscription response was fetched with User-Agent: ${best_ua}, but it was rejected as unusable"
  fi

  if [[ ! -s "$output" ]]; then
    restore_cached_file "$SUBSCRIPTION_CACHE_FILE" "$output" "subscription config" || \
      die "could not fetch a usable subscription config and no cached subscription is available"
  fi
}

fetch_customizer_js() {
  local tmp_dir="$1"
  local output="${tmp_dir}/clash-verge-script.js"
  local -a curl_cmd=()

  mapfile -d '' -t curl_cmd < <(curl_base)

  log "Fetching temporary customizer from GitHub"
  if ! "${curl_cmd[@]}" "$CUSTOMIZER_URL" --output "$output"; then
    warn "customizer download failed: ${CUSTOMIZER_URL}"
    restore_cached_file "$CUSTOMIZER_CACHE_FILE" "$output" "customizer script" || \
      die "customizer download failed and no cached customizer is available"
  elif [[ ! -s "$output" ]]; then
    warn "customizer download is empty: ${CUSTOMIZER_URL}"
    restore_cached_file "$CUSTOMIZER_CACHE_FILE" "$output" "customizer script" || \
      die "customizer download is empty and no cached customizer is available"
  elif grep -qiE '<html|<!doctype html|404: not found|access denied' "$output"; then
    warn "customizer response looks like an error page: ${CUSTOMIZER_URL}"
    restore_cached_file "$CUSTOMIZER_CACHE_FILE" "$output" "customizer script" || \
      die "customizer response is not usable and no cached customizer is available"
  else
    persist_cache_file "$output" "$CUSTOMIZER_CACHE_FILE" 0600
  fi

  if ! grep -qE 'function[[:space:]]+main|module\\.exports|exports\\.main' "$output"; then
    warn "downloaded customizer does not obviously define main(config)"
  fi

  CUSTOMIZER_JS="$output"
}

transform_config() {
  local input_yaml="$1"
  local output_yaml="$2"
  local json_in="${TMP_DIR}/config.in.json"
  local json_out="${TMP_DIR}/config.out.json"
  local runner="${TMP_DIR}/run-customizer.js"

  cat > "$runner" <<'JS'
const fs = require('fs');
const vm = require('vm');

const [scriptPath, jsonIn, jsonOut] = process.argv.slice(2);
const source = fs.readFileSync(scriptPath, 'utf8');
const config = JSON.parse(fs.readFileSync(jsonIn, 'utf8'));
const moduleObject = { exports: {} };
const sandbox = {
  console,
  module: moduleObject,
  exports: moduleObject.exports,
};

vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: scriptPath });

let transform = null;
if (typeof sandbox.main === 'function') {
  transform = sandbox.main;
} else if (typeof moduleObject.exports === 'function') {
  transform = moduleObject.exports;
} else if (moduleObject.exports && typeof moduleObject.exports.main === 'function') {
  transform = moduleObject.exports.main;
}

if (!transform) {
  throw new Error('customizer script must define main(config) or export a function');
}

const result = transform(config);
fs.writeFileSync(jsonOut, JSON.stringify(result || config, null, 2));
JS

  python3 - "$input_yaml" "$json_in" <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
PY

  log "Transforming config with downloaded customizer"
  node "$runner" "$CUSTOMIZER_JS" "$json_in" "$json_out"

  python3 - "$json_out" "$output_yaml" <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    yaml.safe_dump(
        data,
        f,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )
PY
}

patch_local_config() {
  local input_yaml="$1"
  local output_yaml="$2"

  python3 - "$input_yaml" "$output_yaml" \
    "$HTTP_PORT" "$SOCKS_PORT" "$ALLOW_LAN" "$CONTROLLER_ADDR" "$MIHOMO_UI_DIR" "$SECRET" <<'PY'
import sys
import yaml

input_yaml, output_yaml = sys.argv[1], sys.argv[2]
http_port, socks_port = int(sys.argv[3]), int(sys.argv[4])
allow_lan = sys.argv[5].lower() == "true"
controller, external_ui, secret = sys.argv[6], sys.argv[7], sys.argv[8]

with open(input_yaml, encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

proxies = data.get("proxies")
if proxies == {}:
    raise SystemExit("subscription contains an empty top-level proxies map")
if isinstance(proxies, list):
    for proxy in proxies:
        if not isinstance(proxy, dict):
            continue
        if str(proxy.get("type", "")).lower() == "anytls":
            proxy.setdefault("client-fingerprint", "chrome")

data["port"] = http_port
data["socks-port"] = socks_port
data["allow-lan"] = allow_lan
data["external-controller"] = controller
data["external-ui"] = external_ui
data["secret"] = secret

with open(output_yaml, "w", encoding="utf-8") as f:
    yaml.safe_dump(
        data,
        f,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
    )
PY
}

validate_yaml() {
  local file="$1"

  python3 - "$file" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    yaml.safe_load(f)
PY
}

validate_mihomo_config() {
  local config_file="$1"

  if ! command -v mihomo >/dev/null 2>&1; then
    warn "mihomo command was not found; skipped config test"
    return 0
  fi

  log "Testing mihomo configuration"
  if ! run_root env \
    -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u all_proxy -u ALL_PROXY \
    timeout 120 mihomo -t -d "$MIHOMO_CONFIG_DIR" -f "$config_file"; then
    die "mihomo config test failed; if GEO downloads timed out, rerun with --download-proxy"
  fi
}

backup_config_if_needed() {
  CONFIG_ROLLBACK_FILE=""
  if [[ -f "$MIHOMO_CONFIG_FILE" ]]; then
    local stamp=""
    stamp="$(date +%Y%m%d-%H%M%S)"
    CONFIG_ROLLBACK_FILE="${TMP_DIR}/config.rollback.yaml"
    read_root_file_to "$MIHOMO_CONFIG_FILE" "$CONFIG_ROLLBACK_FILE" || CONFIG_ROLLBACK_FILE=""
    run_root cp -a "$MIHOMO_CONFIG_FILE" "${MIHOMO_CONFIG_FILE}.bak-${stamp}"
    log "Backed up existing config to ${MIHOMO_CONFIG_FILE}.bak-${stamp}"
  fi
}

install_config() {
  local source_file="$1"

  backup_config_if_needed
  run_root mkdir -p "$MIHOMO_CONFIG_DIR"
  run_root install -m 0600 "$source_file" "$MIHOMO_CONFIG_FILE"
  persist_cache_file "$source_file" "$FINAL_CONFIG_CACHE_FILE" 0600
}

store_subscription_url() {
  local tmp_file="${TMP_DIR}/subscription.url"

  printf '%s\n' "$SUB_URL" > "$tmp_file"
  run_root mkdir -p "$(dirname -- "$SUB_URL_FILE")"
  run_root install -m 0600 "$tmp_file" "$SUB_URL_FILE"
}

systemd_unit_exists() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --no-legend "$unit" 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$unit"
}

restart_mihomo() {
  if [[ "$NO_RESTART" -eq 1 ]]; then
    log "Skipped mihomo.service restart"
    return 0
  fi

  if systemd_unit_exists mihomo.service; then
    log "Restarting mihomo.service"
    if run_root systemctl restart mihomo; then
      return 0
    fi

    if [[ -n "$CONFIG_ROLLBACK_FILE" && -s "$CONFIG_ROLLBACK_FILE" ]]; then
      warn "mihomo restart failed; restoring previous config"
      run_root install -m 0600 "$CONFIG_ROLLBACK_FILE" "$MIHOMO_CONFIG_FILE"
      run_root systemctl restart mihomo || true
    fi

    die "failed to restart mihomo.service"
  else
    warn "mihomo.service was not found or systemd is unavailable; start mihomo manually"
  fi
}

print_dry_run_plan() {
  cat <<EOF
[${SCRIPT_NAME}] Dry run plan:
  Subscription URL source: ${SUB_URL_SOURCE}
  Stored URL file:        ${SUB_URL_FILE}
  Customizer URL:         ${CUSTOMIZER_URL}
  Config file:            ${MIHOMO_CONFIG_FILE}
  Local config keys:
    port:                ${HTTP_PORT}
    socks-port:          ${SOCKS_PORT}
    allow-lan:           ${ALLOW_LAN}
    external-controller: ${CONTROLLER_ADDR}
    external-ui:         ${MIHOMO_UI_DIR}
    secret:              ${SECRET}
  Restart mihomo:         $([[ "$NO_RESTART" -eq 1 ]] && printf 'no' || printf 'yes')
EOF
}

print_summary() {
  cat <<EOF

Done.
  Config:        ${MIHOMO_CONFIG_FILE}
  Subscription:  ${SUB_URL_FILE}
  Customizer:    ${CUSTOMIZER_URL}
  HTTP:          http://127.0.0.1:${HTTP_PORT}
  SOCKS:         socks5h://127.0.0.1:${SOCKS_PORT}
EOF
}

main() {
  parse_args "$@"
  install_prerequisites

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_dry_run_plan
    return 0
  fi

  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"' EXIT

  local fetched_config="${TMP_DIR}/subscription.yaml"
  local transformed_config="${TMP_DIR}/config.transformed.yaml"
  local final_config="${TMP_DIR}/config.final.yaml"

  fetch_subscription_config "$TMP_DIR"
  [[ -s "$fetched_config" ]] || die "subscription was not downloaded"

  fetch_customizer_js "$TMP_DIR"
  transform_config "$fetched_config" "$transformed_config"

  log "Applying local mihomo settings"
  patch_local_config "$transformed_config" "$final_config"
  validate_yaml "$final_config"
  validate_mihomo_config "$final_config"

  install_config "$final_config"
  store_subscription_url
  restart_mihomo
  print_summary
}

main "$@"
