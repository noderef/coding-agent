#!/usr/bin/env bash

set -euo pipefail

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${COMMON_DIR}/.." && pwd)"

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$*"
}

log_info() { log "INFO" "$*"; }
log_warn() { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }

die() {
  log_error "$*"
  exit 1
}

ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

expand_path() {
  local value="$1"
  case "$value" in
    ~) printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    /*) printf '%s\n' "$value" ;;
    .) printf '%s\n' "$ROOT_DIR" ;;
    ./*) printf '%s/%s\n' "$ROOT_DIR" "${value#./}" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$value" ;;
  esac
}

path_is_within() {
  local child parent
  child="$(expand_path "$1")"
  parent="$(expand_path "$2")"

  child="${child%/}"
  parent="${parent%/}"

  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

load_env_file() {
  local env_file="${1:-${ROOT_DIR}/.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

require_commands() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_error "Missing required command: $cmd"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi
}

acquire_shared_lock() {
  local lock_file="$1"
  ensure_dir "$(dirname "$lock_file")"
  exec 200>"$lock_file"
  if ! flock -n 200; then
    log_info "Another worker is active; exiting"
    return 1
  fi
  return 0
}

run_with_timeout() {
  local minutes="$1"
  shift

  if [[ "$minutes" -le 0 ]]; then
    "$@"
    return $?
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${minutes}m" "$@"
    return $?
  fi

  "$@"
}

available_memory_mb() {
  if [[ -r /proc/meminfo ]]; then
    awk '/MemAvailable:/ { print int($2/1024) }' /proc/meminfo
    return 0
  fi

  if command -v free >/dev/null 2>&1; then
    free -m | awk '/^Mem:/ { print $7 }'
    return 0
  fi

  return 1
}

enforce_memory_guard() {
  local min_mb="${1:-0}"
  if [[ "$min_mb" -le 0 ]]; then
    return 0
  fi

  local avail
  if ! avail="$(available_memory_mb)"; then
    log_warn "Unable to determine available memory; continuing"
    return 0
  fi

  if [[ -z "$avail" ]]; then
    log_warn "Available memory check returned empty value; continuing"
    return 0
  fi

  if (( avail < min_mb )); then
    log_warn "Available memory ${avail}MB below configured minimum ${min_mb}MB"
    return 1
  fi

  return 0
}

comma_list_contains() {
  local list_csv="$1"
  local needle="$2"
  local lower_list
  local lower_needle

  lower_list="$(printf '%s' "$list_csv" | tr '[:upper:]' '[:lower:]')"
  lower_needle="$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')"

  IFS=',' read -r -a _items <<<"$lower_list"
  local item
  for item in "${_items[@]}"; do
    item="$(printf '%s' "$item" | xargs)"
    if [[ "$item" == "$lower_needle" ]]; then
      return 0
    fi
  done
  return 1
}

json_escape_file() {
  local file_path="$1"
  jq -Rs . <"$file_path"
}

json_escape_string() {
  local raw="$1"
  jq -Rn --arg value "$raw" '$value'
}

safe_cat() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    cat "$file_path"
  fi
}

log_excerpt_for_comment() {
  local file_path="$1"
  local lines="${2:-60}"
  local max_chars="${3:-3500}"

  if [[ ! -f "$file_path" ]]; then
    return 0
  fi

  local excerpt
  excerpt="$(tail -n "$lines" "$file_path" 2>/dev/null | tr -cd '\11\12\15\40-\176')"
  if [[ -z "$excerpt" ]]; then
    return 0
  fi

  if (( ${#excerpt} > max_chars )); then
    excerpt="[truncated]\n${excerpt: -max_chars}"
  fi

  printf '%s\n' "$excerpt"
}
