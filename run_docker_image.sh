#!/usr/bin/env bash
# Instantiate GPU/GUI Docker images on WSL or native Ubuntu.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$SCRIPT_PATH")"
# shellcheck source=lib/self_update.sh
source "${SCRIPT_DIR}/lib/self_update.sh"
scripts_self_update "$SCRIPT_DIR" "$SCRIPT_PATH" "$@"

usage() {
  cat <<'EOF'
Usage:
  run_docker_image.sh IMAGE CONTAINER_NAME [options]

Examples:
  run_docker_image.sh yopo:latest yopo
  run_docker_image.sh base_image:ubt20-ros1-cda ego-planner
  run_docker_image.sh local/fastdronexi35:pc fast-drone --workspace ~/code:/root/code

Options:
  -n, --name NAME             Container name. Overrides positional CONTAINER_NAME.
  -w, --workspace SRC[:DST]   Primary bind mount. Default: ~:/root/host_home.
  -v, --volume SRC:DST        Add an extra bind mount. Can be used multiple times.
      --shm-size SIZE         Docker shm size. Default: 16g.
      --network MODE          Docker network mode. Default: host.
      --entrypoint CMD        Docker entrypoint. Default: bash.
      --proxy VALUE           none, auto, PORT, HOST:PORT, or URL. Default: 7897.
      --no-gpu                Do not pass GPU options.
      --no-privileged         Do not pass --privileged.
      --replace               Remove an existing container with the same name first.
      --dry-run               Print the docker command without running it.
  -h, --help                  Show this help.

Notes:
  - GPU, privileged mode, host networking, proxy port 7897, and ~:/root/host_home
    are enabled by default.
  - When proxy is enabled, shell, apt, and git proxy settings inside the
    container are updated through managed config instead of duplicated.
  - DISPLAY is set to :0 on WSL and :1 on native Ubuntu. GUI environment
    variables inside the container are updated through managed config blocks.
  - Bind mount sources and required WSL/GUI/GPU paths must exist before Docker runs.
  - In WSL, localhost/127.0.0.1 proxy values are rewritten to host.docker.internal.
  - On native Ubuntu, localhost/127.0.0.1 proxy values are kept.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null ||
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

sanitize_name() {
  local value="$1"
  value="${value##*/}"
  value="${value//[:.]/-}"
  value="${value//[^a-zA-Z0-9_.-]/-}"
  printf '%s\n' "$value"
}

require_path() {
  local path="$1"
  local label="$2"

  [[ -e "$path" ]] || die "$label does not exist: $path"
}

expand_host_path() {
  local value="$1"

  case "$value" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${value#~/}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

normalize_mount() {
  local value="$1"
  local default_dst="$2"
  local src=""
  local rest=""

  if [[ "$value" == *:* ]]; then
    src="${value%%:*}"
    rest="${value#*:}"
  else
    src="$value"
    rest="$default_dst"
  fi

  src="$(expand_host_path "$src")"
  printf '%s:%s\n' "$src" "$rest"
}

mount_source() {
  local value="$1"
  printf '%s\n' "${value%%:*}"
}

shorten_home_path() {
  local value="$1"

  case "$value" in
    "$HOME")
      printf '~\n'
      ;;
    "$HOME"/*)
      printf '%s/%s\n' '~' "${value#"$HOME"/}"
      ;;
    "$HOME":*)
      printf '~:%s\n' "${value#"$HOME":}"
      ;;
    "$HOME"/*:*)
      printf '%s/%s\n' '~' "${value#"$HOME"/}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

proxy_url_from_value() {
  local value="$1"

  case "$value" in
    auto|none|'')
      printf '%s\n' "$value"
      ;;
    http://*|https://*|socks5://*)
      printf '%s\n' "$value"
      ;;
    *:*)
      printf 'http://%s\n' "$value"
      ;;
    *)
      printf 'http://127.0.0.1:%s\n' "$value"
      ;;
  esac
}

rewrite_proxy_for_container() {
  local value="$1"

  if is_wsl; then
    value="${value//127.0.0.1/host.docker.internal}"
    value="${value//localhost/host.docker.internal}"
  fi

  printf '%s\n' "$value"
}

detect_proxy() {
  local value="${http_proxy:-${HTTP_PROXY:-${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}}}"

  if [[ -n "$value" ]]; then
    proxy_url_from_value "$value"
    return
  fi

  printf 'none\n'
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$1"
}

entrypoint_supports_bootstrap() {
  [[ "$(basename "$ENTRYPOINT")" == "bash" ]]
}

container_proxy_setup_script() {
  cat <<'EOF'
set -Eeuo pipefail

proxy_enabled="${RUN_DOCKER_PROXY_ENABLED:-0}"
proxy="${RUN_DOCKER_PROXY:-}"
no_proxy_value="${RUN_DOCKER_NO_PROXY:-localhost,127.0.0.1,::1}"
display_value="${RUN_DOCKER_DISPLAY:-:0}"
qt_x11_no_mitshm_value="${RUN_DOCKER_QT_X11_NO_MITSHM:-1}"
wayland_display_value="${RUN_DOCKER_WAYLAND_DISPLAY:-}"
xdg_runtime_dir_value="${RUN_DOCKER_XDG_RUNTIME_DIR:-}"
pulse_server_value="${RUN_DOCKER_PULSE_SERVER:-}"
start_marker="# >>> run_docker_image proxy >>>"
end_marker="# <<< run_docker_image proxy <<<"
display_start_marker="# >>> run_docker_image display >>>"
display_end_marker="# <<< run_docker_image display <<<"
proxy_vars='http_proxy|https_proxy|ftp_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|ALL_PROXY|no_proxy|NO_PROXY'
display_vars='DISPLAY|QT_X11_NO_MITSHM|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|PULSE_SERVER'

escape_double_quotes() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

append_shell_export() {
  local file="$1"
  local name="$2"
  local value="$3"

  printf 'export %s="%s"\n' "$name" "$(escape_double_quotes "$value")" >> "$file"
}

append_environment_value() {
  local file="$1"
  local name="$2"
  local value="$3"

  printf '%s="%s"\n' "$name" "$(escape_double_quotes "$value")" >> "$file"
}

update_shell_file() {
  local file="$1"
  local tmp_file=""

  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp_file="$(mktemp)"

  awk -v proxy_start="$start_marker" \
      -v proxy_end="$end_marker" \
      -v display_start="$display_start_marker" \
      -v display_end="$display_end_marker" \
      -v vars="$proxy_vars|$display_vars" '
    $0 == proxy_start || $0 == display_start { skip = 1; next }
    $0 == proxy_end || $0 == display_end { skip = 0; next }
    skip { next }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" vars ")=" { next }
    { print }
  ' "$file" > "$tmp_file"

  cat >> "$tmp_file" <<DISPLAYEOF

$display_start_marker
DISPLAYEOF
  append_shell_export "$tmp_file" DISPLAY "$display_value"
  append_shell_export "$tmp_file" QT_X11_NO_MITSHM "$qt_x11_no_mitshm_value"
  [[ -n "$wayland_display_value" ]] && append_shell_export "$tmp_file" WAYLAND_DISPLAY "$wayland_display_value"
  [[ -n "$xdg_runtime_dir_value" ]] && append_shell_export "$tmp_file" XDG_RUNTIME_DIR "$xdg_runtime_dir_value"
  [[ -n "$pulse_server_value" ]] && append_shell_export "$tmp_file" PULSE_SERVER "$pulse_server_value"
  cat >> "$tmp_file" <<DISPLAYEOF
$display_end_marker
DISPLAYEOF

  if [[ "$proxy_enabled" == "1" ]]; then
    cat >> "$tmp_file" <<PROXYEOF

$start_marker
export http_proxy="$proxy"
export https_proxy="$proxy"
export ftp_proxy="$proxy"
export all_proxy="$proxy"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export FTP_PROXY="\$ftp_proxy"
export ALL_PROXY="\$all_proxy"
export no_proxy="$no_proxy_value"
export NO_PROXY="\$no_proxy"
$end_marker
PROXYEOF
  fi

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

update_environment_file() {
  local file="/etc/environment"
  local tmp_file=""

  touch "$file"
  tmp_file="$(mktemp)"

  awk -v proxy_start="$start_marker" \
      -v proxy_end="$end_marker" \
      -v display_start="$display_start_marker" \
      -v display_end="$display_end_marker" \
      -v vars="$proxy_vars|$display_vars" '
    $0 == proxy_start || $0 == display_start { skip = 1; next }
    $0 == proxy_end || $0 == display_end { skip = 0; next }
    skip { next }
    $0 ~ "^[[:space:]]*(" vars ")=" { next }
    { print }
  ' "$file" > "$tmp_file"

  cat >> "$tmp_file" <<DISPLAYEOF

$display_start_marker
DISPLAYEOF
  append_environment_value "$tmp_file" DISPLAY "$display_value"
  append_environment_value "$tmp_file" QT_X11_NO_MITSHM "$qt_x11_no_mitshm_value"
  [[ -n "$wayland_display_value" ]] && append_environment_value "$tmp_file" WAYLAND_DISPLAY "$wayland_display_value"
  [[ -n "$xdg_runtime_dir_value" ]] && append_environment_value "$tmp_file" XDG_RUNTIME_DIR "$xdg_runtime_dir_value"
  [[ -n "$pulse_server_value" ]] && append_environment_value "$tmp_file" PULSE_SERVER "$pulse_server_value"
  cat >> "$tmp_file" <<DISPLAYEOF
$display_end_marker
DISPLAYEOF

  if [[ "$proxy_enabled" == "1" ]]; then
    cat >> "$tmp_file" <<PROXYEOF

$start_marker
http_proxy="$proxy"
https_proxy="$proxy"
ftp_proxy="$proxy"
all_proxy="$proxy"
HTTP_PROXY="$proxy"
HTTPS_PROXY="$proxy"
FTP_PROXY="$proxy"
ALL_PROXY="$proxy"
no_proxy="$no_proxy_value"
NO_PROXY="$no_proxy_value"
$end_marker
PROXYEOF
  fi

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

update_profile_script() {
  local file="/etc/profile.d/run_docker_image_env.sh"
  local old_file="/etc/profile.d/run_docker_image_proxy.sh"

  rm -f "$old_file"

  : > "$file"
  append_shell_export "$file" DISPLAY "$display_value"
  append_shell_export "$file" QT_X11_NO_MITSHM "$qt_x11_no_mitshm_value"
  [[ -n "$wayland_display_value" ]] && append_shell_export "$file" WAYLAND_DISPLAY "$wayland_display_value"
  [[ -n "$xdg_runtime_dir_value" ]] && append_shell_export "$file" XDG_RUNTIME_DIR "$xdg_runtime_dir_value"
  [[ -n "$pulse_server_value" ]] && append_shell_export "$file" PULSE_SERVER "$pulse_server_value"

  if [[ "$proxy_enabled" == "1" ]]; then
    cat >> "$file" <<PROXYEOF
export http_proxy="$proxy"
export https_proxy="$proxy"
export ftp_proxy="$proxy"
export all_proxy="$proxy"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export FTP_PROXY="\$ftp_proxy"
export ALL_PROXY="\$all_proxy"
export no_proxy="$no_proxy_value"
export NO_PROXY="\$no_proxy"
PROXYEOF
  fi
}

update_apt_proxy() {
  local apt_dir="/etc/apt/apt.conf.d"
  local apt_file="$apt_dir/95proxies"

  [[ -d "$apt_dir" ]] || return 0

  while IFS= read -r -d '' file; do
    [[ "$file" == "$apt_file" ]] && continue
    sed -i -E '/Acquire::(http|https|ftp)::Proxy/d' "$file" || true
  done < <(find "$apt_dir" -maxdepth 1 -type f -print0)

  if [[ "$proxy_enabled" != "1" ]]; then
    rm -f "$apt_file"
    return
  fi

  cat > "$apt_file" <<PROXYEOF
Acquire::http::Proxy "$proxy";
Acquire::https::Proxy "$proxy";
Acquire::ftp::Proxy "$proxy";
PROXYEOF
}

update_git_proxy() {
  command -v git >/dev/null 2>&1 || return 0

  if [[ "$proxy_enabled" == "1" ]]; then
    git config --global --replace-all http.proxy "$proxy"
    git config --global --replace-all https.proxy "$proxy"
  else
    git config --global --unset-all http.proxy 2>/dev/null || true
    git config --global --unset-all https.proxy 2>/dev/null || true
  fi
}

update_shell_file /root/.bashrc
[[ -f /etc/bash.bashrc ]] && update_shell_file /etc/bash.bashrc
update_environment_file
update_profile_script
update_apt_proxy
update_git_proxy

export DISPLAY="$display_value"
export QT_X11_NO_MITSHM="$qt_x11_no_mitshm_value"
[[ -n "$wayland_display_value" ]] && export WAYLAND_DISPLAY="$wayland_display_value"
[[ -n "$xdg_runtime_dir_value" ]] && export XDG_RUNTIME_DIR="$xdg_runtime_dir_value"
[[ -n "$pulse_server_value" ]] && export PULSE_SERVER="$pulse_server_value"

if [[ "$proxy_enabled" == "1" ]]; then
  export http_proxy="$proxy"
  export https_proxy="$proxy"
  export ftp_proxy="$proxy"
  export all_proxy="$proxy"
  export HTTP_PROXY="$proxy"
  export HTTPS_PROXY="$proxy"
  export FTP_PROXY="$proxy"
  export ALL_PROXY="$proxy"
  export no_proxy="$no_proxy_value"
  export NO_PROXY="$no_proxy_value"
fi
EOF
}

container_start_command() {
  printf '%s\n' "$(container_proxy_setup_script)"
  printf 'exec bash -i\n'
}

proxy_exec_env_args() {
  local -n out_args="$1"

  out_args+=(
    -e "RUN_DOCKER_DISPLAY=$DISPLAY_VALUE"
    -e "RUN_DOCKER_QT_X11_NO_MITSHM=$QT_X11_NO_MITSHM_VALUE"
    -e "RUN_DOCKER_WAYLAND_DISPLAY=$WAYLAND_DISPLAY_VALUE"
    -e "RUN_DOCKER_XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR_VALUE"
    -e "RUN_DOCKER_PULSE_SERVER=$PULSE_SERVER_VALUE"
    -e "DISPLAY=$DISPLAY_VALUE"
    -e "QT_X11_NO_MITSHM=$QT_X11_NO_MITSHM_VALUE"
    -e "RUN_DOCKER_PROXY_ENABLED=$PROXY_ENABLED"
    -e "RUN_DOCKER_PROXY=$PROXY_VALUE"
    -e "RUN_DOCKER_NO_PROXY=$NO_PROXY_VALUE"
  )

  [[ -n "$WAYLAND_DISPLAY_VALUE" ]] && out_args+=(-e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY_VALUE")
  [[ -n "$XDG_RUNTIME_DIR_VALUE" ]] && out_args+=(-e "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR_VALUE")
  [[ -n "$PULSE_SERVER_VALUE" ]] && out_args+=(-e "PULSE_SERVER=$PULSE_SERVER_VALUE")

  if [[ "$PROXY_ENABLED" -eq 1 ]]; then
    out_args+=(
      -e "http_proxy=$PROXY_VALUE"
      -e "https_proxy=$PROXY_VALUE"
      -e "ftp_proxy=$PROXY_VALUE"
      -e "all_proxy=$PROXY_VALUE"
      -e "HTTP_PROXY=$PROXY_VALUE"
      -e "HTTPS_PROXY=$PROXY_VALUE"
      -e "FTP_PROXY=$PROXY_VALUE"
      -e "ALL_PROXY=$PROXY_VALUE"
      -e "no_proxy=$NO_PROXY_VALUE"
      -e "NO_PROXY=$NO_PROXY_VALUE"
    )
  fi
}

configure_existing_container_proxy() {
  local container_name="$1"
  local exec_args=(exec)

  proxy_exec_env_args exec_args
  docker "${exec_args[@]}" "$container_name" bash -lc "$(container_proxy_setup_script)"
}

open_container_shell() {
  local container_name="$1"
  local exec_args=(exec -it)

  proxy_exec_env_args exec_args
  exec docker "${exec_args[@]}" "$container_name" bash
}

IMAGE_NAME=""
CTN_NAME=""
WORKSPACE_MOUNT="${HOME}:/root/host_home"
SHM_SIZE="16g"
NETWORK_MODE="host"
ENTRYPOINT="bash"
PROXY_MODE="7897"
PROXY_ENABLED=0
PROXY_VALUE=""
NO_PROXY_VALUE="localhost,127.0.0.1,::1,host.docker.internal"
DISPLAY_VALUE=""
QT_X11_NO_MITSHM_VALUE="1"
WAYLAND_DISPLAY_VALUE=""
XDG_RUNTIME_DIR_VALUE=""
PULSE_SERVER_VALUE=""
USE_GPU=1
USE_PRIVILEGED=1
REPLACE=0
DRY_RUN=0
EXTRA_VOLUMES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--name)
      [[ $# -ge 2 ]] || die "--name needs a value"
      CTN_NAME="$2"
      shift 2
      ;;
    -w|--workspace)
      [[ $# -ge 2 ]] || die "--workspace needs a value"
      WORKSPACE_MOUNT="$2"
      shift 2
      ;;
    -v|--volume)
      [[ $# -ge 2 ]] || die "--volume needs a value"
      EXTRA_VOLUMES+=("$2")
      shift 2
      ;;
    --shm-size)
      [[ $# -ge 2 ]] || die "--shm-size needs a value"
      SHM_SIZE="$2"
      shift 2
      ;;
    --network)
      [[ $# -ge 2 ]] || die "--network needs a value"
      NETWORK_MODE="$2"
      shift 2
      ;;
    --entrypoint)
      [[ $# -ge 2 ]] || die "--entrypoint needs a value"
      ENTRYPOINT="$2"
      shift 2
      ;;
    --proxy)
      [[ $# -ge 2 ]] || die "--proxy needs a value"
      PROXY_MODE="$2"
      shift 2
      ;;
    --no-gpu)
      USE_GPU=0
      shift
      ;;
    --no-privileged)
      USE_PRIVILEGED=0
      shift
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ -z "$IMAGE_NAME" ]]; then
        IMAGE_NAME="$1"
      elif [[ -z "$CTN_NAME" ]]; then
        CTN_NAME="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$IMAGE_NAME" ]] || {
  usage
  exit 1
}

if [[ -z "$CTN_NAME" ]]; then
  CTN_NAME="$(sanitize_name "$IMAGE_NAME")"
fi

command -v docker >/dev/null 2>&1 || die "docker command not found"

WORKSPACE_MOUNT="$(normalize_mount "$WORKSPACE_MOUNT" "/root/host_home")"
HOST_WORKSPACE="${WORKSPACE_MOUNT%%:*}"
[[ -d "$HOST_WORKSPACE" ]] || die "workspace path does not exist: $HOST_WORKSPACE"
require_path /tmp/.X11-unix "X11 socket directory"

NORMALIZED_EXTRA_VOLUMES=()
for volume in "${EXTRA_VOLUMES[@]}"; do
  [[ "$volume" == *:* ]] || die "--volume must be SRC:DST or SRC:DST:OPTIONS: $volume"
  normalized_volume="$(normalize_mount "$volume" "")"
  require_path "$(mount_source "$normalized_volume")" "volume source"
  NORMALIZED_EXTRA_VOLUMES+=("$normalized_volume")
done
EXTRA_VOLUMES=("${NORMALIZED_EXTRA_VOLUMES[@]}")

if is_wsl; then
  DISPLAY_VALUE=":0"
  WAYLAND_DISPLAY_VALUE="${WAYLAND_DISPLAY:-wayland-0}"
  XDG_RUNTIME_DIR_VALUE="/mnt/wslg/runtime-dir"
  PULSE_SERVER_VALUE="${PULSE_SERVER:-}"
else
  DISPLAY_VALUE=":1"
fi

args=(
  run
  --entrypoint "$ENTRYPOINT"
  -it
  --shm-size "$SHM_SIZE"
  --network="$NETWORK_MODE"
  --name "$CTN_NAME"
  -e ACCEPT_EULA=Y
  -e PRIVACY_CONSENT=Y
  -v /tmp/.X11-unix:/tmp/.X11-unix
  -v "$WORKSPACE_MOUNT"
)

for volume in "${EXTRA_VOLUMES[@]}"; do
  args+=(-v "$volume")
done

if [[ "$USE_PRIVILEGED" -eq 1 ]]; then
  args+=(--privileged)
fi

if [[ "$USE_GPU" -eq 1 ]]; then
  args+=(--gpus all)

  if ! is_wsl && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    args+=(--runtime=nvidia)
  fi
fi

if is_wsl; then
  require_path /mnt/wslg "WSLg directory"
  require_path /mnt/wslg/runtime-dir "WSLg runtime directory"
  require_path /usr/lib/wsl "WSL library directory"

  if [[ "$USE_GPU" -eq 1 ]]; then
    require_path /dev/dxg "WSL GPU device"
    args+=(--device=/dev/dxg)
  fi

  args+=(-v /mnt/wslg:/mnt/wslg)
  args+=(-v /usr/lib/wsl:/usr/lib/wsl)

  args+=(
    -e LD_LIBRARY_PATH=/usr/lib/wsl/lib:/opt/ros/noetic/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
  )
fi

case "$PROXY_MODE" in
  none)
    PROXY_ENABLED=0
    PROXY_VALUE=""
    ;;
  auto)
    proxy_value="$(detect_proxy)"
    if [[ "$proxy_value" != "none" ]]; then
      PROXY_ENABLED=1
      PROXY_VALUE="$(rewrite_proxy_for_container "$proxy_value")"
    fi
    ;;
  *)
    proxy_value="$(proxy_url_from_value "$PROXY_MODE")"
    PROXY_ENABLED=1
    PROXY_VALUE="$(rewrite_proxy_for_container "$proxy_value")"
    ;;
esac

proxy_exec_env_args args
args+=("$IMAGE_NAME")

STARTUP_COMMAND=""
if entrypoint_supports_bootstrap; then
  STARTUP_COMMAND="$(container_start_command)"
  args+=("-lc" "$STARTUP_COMMAND")
fi

echo "Environment: $(is_wsl && echo WSL || echo Ubuntu)"
echo "Image: $IMAGE_NAME"
echo "Container: $CTN_NAME"
echo "Display: $DISPLAY_VALUE"
workspace_label="$WORKSPACE_MOUNT"
workspace_label="$(shorten_home_path "$workspace_label")"
echo "Workspace: $workspace_label"

if [[ "$DRY_RUN" -eq 1 ]]; then
  display_args=("${args[@]}")
  for i in "${!display_args[@]}"; do
    if [[ -n "$STARTUP_COMMAND" && "${display_args[$i]}" == "$STARTUP_COMMAND" ]]; then
      display_args[$i]="<configure-container-proxy-and-open-bash>"
      continue
    fi
    display_args[$i]="$(shorten_home_path "${display_args[$i]}")"
  done

  printf 'docker'
  for arg in "${display_args[@]}"; do
    if [[ "$arg" == \~ || "$arg" == \~/* || "$arg" == \~:* ]]; then
      printf ' %s' "$arg"
    else
      printf ' %q' "$arg"
    fi
  done
  printf '\n'
  exit 0
fi

if container_exists "$CTN_NAME"; then
  if [[ "$REPLACE" -eq 1 ]]; then
    docker rm -f "$CTN_NAME" >/dev/null
  elif container_running "$CTN_NAME"; then
    echo "Container '$CTN_NAME' is already running; opening a shell in it."
    configure_existing_container_proxy "$CTN_NAME"
    open_container_shell "$CTN_NAME"
  else
    echo "Container '$CTN_NAME' already exists; starting and attaching it."
    docker start "$CTN_NAME" >/dev/null
    configure_existing_container_proxy "$CTN_NAME"
    exec docker attach "$CTN_NAME"
  fi
fi

exec docker "${args[@]}"
