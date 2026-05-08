#!/usr/bin/env bash
# Instantiate GPU/GUI Docker images on WSL or native Ubuntu.
set -Eeuo pipefail

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
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
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
      printf '~/%s\n' "${value#"$HOME"/}"
      ;;
    "$HOME":*)
      printf '~:%s\n' "${value#"$HOME":}"
      ;;
    "$HOME"/*:*)
      printf '~/%s\n' "${value#"$HOME"/}"
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

IMAGE_NAME=""
CTN_NAME=""
WORKSPACE_MOUNT="${HOME}:/root/host_home"
SHM_SIZE="16g"
NETWORK_MODE="host"
ENTRYPOINT="bash"
PROXY_MODE="7897"
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

args=(
  run
  --entrypoint "$ENTRYPOINT"
  -it
  --shm-size "$SHM_SIZE"
  --network="$NETWORK_MODE"
  --name "$CTN_NAME"
  -e ACCEPT_EULA=Y
  -e PRIVACY_CONSENT=Y
  -e DISPLAY="${DISPLAY:-:0}"
  -e QT_X11_NO_MITSHM=1
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
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    -e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir
    -e LD_LIBRARY_PATH=/usr/lib/wsl/lib:/opt/ros/noetic/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64
  )

  [[ -n "${PULSE_SERVER:-}" ]] && args+=(-e PULSE_SERVER="$PULSE_SERVER")
fi

case "$PROXY_MODE" in
  none)
    ;;
  auto)
    proxy_value="$(detect_proxy)"
    if [[ "$proxy_value" != "none" ]]; then
      proxy_value="$(rewrite_proxy_for_container "$proxy_value")"
      args+=(
        -e "http_proxy=$proxy_value"
        -e "https_proxy=$proxy_value"
        -e "all_proxy=$proxy_value"
        -e "HTTP_PROXY=$proxy_value"
        -e "HTTPS_PROXY=$proxy_value"
        -e "ALL_PROXY=$proxy_value"
      )
    fi
    ;;
  *)
    proxy_value="$(proxy_url_from_value "$PROXY_MODE")"
    proxy_value="$(rewrite_proxy_for_container "$proxy_value")"
    args+=(
      -e "http_proxy=$proxy_value"
      -e "https_proxy=$proxy_value"
      -e "all_proxy=$proxy_value"
      -e "HTTP_PROXY=$proxy_value"
      -e "HTTPS_PROXY=$proxy_value"
      -e "ALL_PROXY=$proxy_value"
    )
    ;;
esac

args+=("$IMAGE_NAME")

echo "Environment: $(is_wsl && echo WSL || echo Ubuntu)"
echo "Image: $IMAGE_NAME"
echo "Container: $CTN_NAME"
workspace_label="$WORKSPACE_MOUNT"
workspace_label="$(shorten_home_path "$workspace_label")"
echo "Workspace: $workspace_label"

if [[ "$DRY_RUN" -eq 1 ]]; then
  display_args=("${args[@]}")
  for i in "${!display_args[@]}"; do
    display_args[$i]="$(shorten_home_path "${display_args[$i]}")"
  done

  printf 'docker'
  for arg in "${display_args[@]}"; do
    if [[ "$arg" == "~" || "$arg" == "~/"* || "$arg" == "~:"* ]]; then
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
    exec docker exec -it "$CTN_NAME" bash
  else
    echo "Container '$CTN_NAME' already exists; starting and attaching it."
    exec docker start -ai "$CTN_NAME"
  fi
fi

exec docker "${args[@]}"
