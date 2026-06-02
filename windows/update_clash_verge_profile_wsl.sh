#!/usr/bin/env bash
# Update a Windows Clash Verge profile from WSL using the official subscription User-Agent.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$SCRIPT_PATH")"
# shellcheck source=../lib/self_update.sh
source "${REPO_DIR}/lib/self_update.sh"
scripts_self_update "$REPO_DIR" "$SCRIPT_PATH" "$@"

SCRIPT_NAME="$(basename "$0")"
APP_PACKAGE_DIR="io.github.clash-verge-rev.clash-verge-rev"

SUB_URL="${MIHOMO_SUB_URL:-}"
SUB_URL_PATH=""
FETCH_UA="${MIHOMO_SUB_UA:-clash-verge/v2.4.2}"
DOWNLOAD_PROXY=""
WINDOWS_USER="${MIHOMO_WINDOWS_USER:-${USER:-}}"
APP_DATA_DIR="${MIHOMO_CLASH_VERGE_APPDATA:-}"
PROFILE_ID="${MIHOMO_CLASH_VERGE_PROFILE_ID:-}"
PROFILE_FILE="${MIHOMO_CLASH_VERGE_PROFILE_FILE:-}"
OUTPUT_FILE=""
CACHE_FILE=""
DRY_RUN=0
CUSTOM_UA=0

declare -a EXTRA_HEADERS=()

usage() {
  cat <<'EOF'
Usage:
  update_clash_verge_profile_wsl.sh --sub-url URL --profile-id ID [options]
  update_clash_verge_profile_wsl.sh --sub-url-file FILE --profile-id ID [options]
  update_clash_verge_profile_wsl.sh --sub-url URL --profile-file FILE [options]
  update_clash_verge_profile_wsl.sh --sub-url URL --output FILE [options]

Options:
      --sub-url URL          Subscription URL to fetch.
      --sub-url-file FILE    Read the subscription URL from FILE.
      --user-agent VALUE     User-Agent used when fetching the subscription.
                             Default: clash-verge/v2.4.2
      --header 'K: V'        Extra header for subscription fetch. Can repeat.
      --download-proxy URL   Proxy used by curl while downloading the profile.
      --windows-user NAME    Windows username for /mnt/c/Users/NAME discovery.
      --app-data-dir DIR     Override Clash Verge app data directory.
      --profile-id ID        Clash Verge profile ID under profiles/ID.yaml.
      --profile-file FILE    Exact Windows profile YAML path to overwrite.
      --output FILE          Write the fetched YAML to FILE.
      --cache-file FILE      Cache file used when live fetch fails.
      --dry-run              Print planned actions without changing files.
  -h, --help                 Show this help.

Examples:
  update_clash_verge_profile_wsl.sh \
    --sub-url 'http://43.135.28.238/link/...?...' \
    --profile-id RmkFk6tnuFxa

  update_clash_verge_profile_wsl.sh \
    --sub-url-file ~/.config/mihomo/sub_url \
    --profile-file '/mnt/c/Users/zhangrun/AppData/Roaming/io.github.clash-verge-rev.clash-verge-rev/profiles/RmkFk6tnuFxa.yaml'
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
      --windows-user)
        [[ $# -ge 2 ]] || die "--windows-user requires a value"
        WINDOWS_USER="$2"
        shift 2
        ;;
      --app-data-dir)
        [[ $# -ge 2 ]] || die "--app-data-dir requires a value"
        APP_DATA_DIR="$2"
        shift 2
        ;;
      --profile-id)
        [[ $# -ge 2 ]] || die "--profile-id requires a value"
        PROFILE_ID="$2"
        shift 2
        ;;
      --profile-file)
        [[ $# -ge 2 ]] || die "--profile-file requires a value"
        PROFILE_FILE="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output requires a value"
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --cache-file)
        [[ $# -ge 2 ]] || die "--cache-file requires a value"
        CACHE_FILE="$2"
        shift 2
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

  if [[ -n "$SUB_URL_PATH" ]]; then
    [[ -r "$SUB_URL_PATH" ]] || die "subscription URL file is not readable: $SUB_URL_PATH"
    SUB_URL="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//; p; q' "$SUB_URL_PATH")"
  fi

  [[ -n "$SUB_URL" ]] || die "provide --sub-url URL, --sub-url-file FILE, or MIHOMO_SUB_URL"

  if [[ -z "$APP_DATA_DIR" ]]; then
    APP_DATA_DIR="/mnt/c/Users/${WINDOWS_USER}/AppData/Roaming/${APP_PACKAGE_DIR}"
  fi

  if [[ -z "$PROFILE_FILE" && -n "$PROFILE_ID" ]]; then
    PROFILE_FILE="${APP_DATA_DIR}/profiles/${PROFILE_ID}.yaml"
  fi

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$PROFILE_FILE"
  fi

  [[ -n "$OUTPUT_FILE" ]] || die "provide --profile-id, --profile-file, or --output"

  if [[ -z "$CACHE_FILE" ]]; then
    CACHE_FILE="$(dirname -- "$OUTPUT_FILE")/$(basename -- "$OUTPUT_FILE" .yaml).last-known-good.yaml"
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

validate_subscription_config() {
  local input_file="$1"

  python3 - "$input_file" <<'PY'
import re
import sys
import yaml

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

if not re.search(r"^(proxies|proxy-providers|proxy-groups|rules|mixed-port|port|socks-port):", text, re.M):
    raise SystemExit("normal Clash/Mihomo YAML keys were not detected")

if re.search(r"^proxies:\s*\{\s*\}\s*$", text, re.M):
    raise SystemExit("subscription contains an empty top-level proxies map")

if re.search(r"^\s+proxies:\s*\{\s*\}\s*$", text, re.M) and not re.search(r"^proxy-providers:", text, re.M):
    raise SystemExit("subscription contains empty proxy-group proxies maps")

data = yaml.safe_load(text) or {}
proxies = data.get("proxies")
if proxies == {}:
    raise SystemExit("subscription contains an empty top-level proxies map")
PY
}

restore_cached_file() {
  local cache_file="$1"
  local output_file="$2"

  [[ -s "$cache_file" ]] || return 1
  cp -f -- "$cache_file" "$output_file"
  [[ -s "$output_file" ]]
}

persist_cache_file() {
  local source_file="$1"
  mkdir -p "$(dirname -- "$CACHE_FILE")"
  cp -f -- "$source_file" "$CACHE_FILE"
  chmod 600 "$CACHE_FILE" 2>/dev/null || true
}

fetch_subscription_config() {
  local output_file="$1"
  local -a curl_cmd=()
  local -a header_args=()
  local -a user_agents=("$FETCH_UA")
  local candidate=""
  local ua=""
  local attempt=0
  local attempt_file=""
  local header=""

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

  for ua in "${user_agents[@]}"; do
    attempt=$((attempt + 1))
    attempt_file="${TMP_DIR}/subscription.${attempt}.yaml"
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

    if validate_subscription_config "$attempt_file"; then
      cp -f -- "$attempt_file" "$output_file"
      persist_cache_file "$output_file"
      log "Subscription fetched successfully with User-Agent: ${ua}"
      return 0
    fi

    warn "subscription response is not usable with User-Agent: ${ua}"
  done

  if restore_cached_file "$CACHE_FILE" "$output_file"; then
    log "Live fetch failed; using cached Windows profile from ${CACHE_FILE}"
    return 0
  fi

  die "could not fetch a usable subscription config and no cached profile is available"
}

backup_target_if_needed() {
  local target_file="$1"
  local backup_dir="$(dirname -- "$target_file")/backups"
  local backup_file=""

  [[ -f "$target_file" ]] || return 0

  run mkdir -p "$backup_dir"
  backup_file="${backup_dir}/$(basename -- "$target_file").$(date +%Y%m%d-%H%M%S).bak"
  run cp -f -- "$target_file" "$backup_file"
  log "Backed up existing profile to ${backup_file}"
}

install_profile() {
  local source_file="$1"

  backup_target_if_needed "$OUTPUT_FILE"
  run mkdir -p "$(dirname -- "$OUTPUT_FILE")"
  run cp -f -- "$source_file" "$OUTPUT_FILE"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    chmod 600 "$OUTPUT_FILE" 2>/dev/null || true
  fi
}

print_summary() {
  cat <<EOF

Done.
  Subscription URL: ${SUB_URL}
  User-Agent:       ${FETCH_UA}
  Output file:      ${OUTPUT_FILE}
  Cache file:       ${CACHE_FILE}
EOF
}

main() {
  parse_args "$@"

  require_cmd curl
  require_cmd python3
  python3 - <<'PY'
import yaml  # noqa: F401
PY

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
[${SCRIPT_NAME}] Dry run plan:
  Subscription URL: ${SUB_URL}
  User-Agent:       ${FETCH_UA}
  App data dir:     ${APP_DATA_DIR}
  Output file:      ${OUTPUT_FILE}
  Cache file:       ${CACHE_FILE}
EOF
    return 0
  fi

  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"' EXIT

  local fetched_profile="${TMP_DIR}/profile.yaml"
  fetch_subscription_config "$fetched_profile"
  install_profile "$fetched_profile"
  print_summary
}

main "$@"
