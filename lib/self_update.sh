#!/usr/bin/env bash
# Shared fast-forward self-update helper for scripts in this repository.

scripts_self_update_git() {
  local repo_root="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${SCRIPTS_SELF_UPDATE_TIMEOUT:-12}" git -C "$repo_root" "$@"
  else
    git -C "$repo_root" "$@"
  fi
}

scripts_self_update_warn() {
  local script_name="$1"
  shift

  printf '[%s] Warning: %s\n' "$script_name" "$*" >&2
}

scripts_self_update() {
  local script_dir="$1"
  local script_path="$2"
  shift 2

  local script_name=""
  local repo_root=""
  local branch=""
  local upstream=""
  local remote=""
  local remote_branch=""
  local local_sha=""
  local remote_sha=""
  local merge_base=""

  script_name="$(basename -- "$script_path")"

  [[ "${SCRIPTS_SKIP_SELF_UPDATE:-0}" == "1" ]] && return 0
  [[ "${SCRIPTS_SELF_UPDATE:-1}" == "0" ]] && return 0
  command -v git >/dev/null 2>&1 || return 0

  repo_root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || return 0

  branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    scripts_self_update_warn "$script_name" "skipped self-update because the repository is in detached HEAD state"
    return 0
  fi

  if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]]; then
    scripts_self_update_warn "$script_name" "skipped self-update because the repository has local changes"
    return 0
  fi

  upstream="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    upstream="origin/${branch}"
    git -C "$repo_root" show-ref --verify --quiet "refs/remotes/${upstream}" || return 0
  fi

  remote="${upstream%%/*}"
  remote_branch="${upstream#*/}"
  if [[ -z "$remote" || -z "$remote_branch" || "$remote" == "$remote_branch" ]]; then
    return 0
  fi

  if ! scripts_self_update_git "$repo_root" fetch --quiet "$remote" "$remote_branch"; then
    scripts_self_update_warn "$script_name" "could not check remote updates quickly; continuing with local copy"
    return 0
  fi

  local_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  remote_sha="$(git -C "$repo_root" rev-parse "$upstream" 2>/dev/null || true)"
  [[ -n "$local_sha" && -n "$remote_sha" ]] || return 0
  [[ "$local_sha" == "$remote_sha" ]] && return 0

  merge_base="$(git -C "$repo_root" merge-base HEAD "$upstream" 2>/dev/null || true)"
  if [[ "$merge_base" != "$local_sha" ]]; then
    scripts_self_update_warn "$script_name" "skipped self-update because local and remote branches have diverged"
    return 0
  fi

  printf '[%s] Updating scripts from %s...\n' "$script_name" "$upstream"
  if ! scripts_self_update_git "$repo_root" pull --ff-only --quiet; then
    scripts_self_update_warn "$script_name" "git pull --ff-only failed; continuing with local copy"
    return 0
  fi

  printf '[%s] Updated. Restarting with the latest script.\n' "$script_name"
  exec env SCRIPTS_SKIP_SELF_UPDATE=1 "$script_path" "$@"
}
