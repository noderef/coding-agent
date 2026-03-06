#!/usr/bin/env bash

set -euo pipefail

agent_validate_config() {
  : "${AGENT_BACKEND:?AGENT_BACKEND is required}"
  : "${AGENT_CMD:?AGENT_CMD is required}"
  : "${AGENT_MODEL:?AGENT_MODEL is required}"
  : "${AGENT_BASE_URL:?AGENT_BASE_URL is required}"
  : "${AGENT_API_KEY:?AGENT_API_KEY is required}"

  if [[ ! -x "$AGENT_CMD" ]]; then
    if ! command -v "$AGENT_CMD" >/dev/null 2>&1; then
      die "Agent command not executable or not on PATH: $AGENT_CMD"
    fi
  fi
}

agent_run() {
  local workdir="$1"
  local prompt_file="$2"
  local timeout_minutes="$3"
  local run_log_file="$4"

  agent_validate_config

  local backend="${AGENT_BACKEND}"
  local input_mode="${AGENT_INPUT_MODE:-file}"
  local subcommand="${AGENT_SUBCOMMAND:-run}"
  local model_flag="${AGENT_MODEL_FLAG:---model}"
  local base_url_flag="${AGENT_BASE_URL_FLAG:---base-url}"
  local api_key_flag="${AGENT_API_KEY_FLAG:---api-key}"
  local prompt_file_flag="${AGENT_PROMPT_FILE_FLAG:---prompt-file}"
  local non_interactive_flag="${AGENT_NON_INTERACTIVE_FLAG:---non-interactive}"

  local -a cmd
  cmd=("$AGENT_CMD")

  case "$backend" in
    cline)
      if [[ -n "$subcommand" ]]; then
        cmd+=("$subcommand")
      fi
      cmd+=("$model_flag" "$AGENT_MODEL")
      cmd+=("$base_url_flag" "$AGENT_BASE_URL")
      cmd+=("$api_key_flag" "$AGENT_API_KEY")
      if [[ -n "$non_interactive_flag" ]]; then
        cmd+=("$non_interactive_flag")
      fi

      if [[ "$input_mode" == "file" ]]; then
        cmd+=("$prompt_file_flag" "$prompt_file")
      fi
      ;;
    *)
      die "Unsupported AGENT_BACKEND: $backend"
      ;;
  esac

  if [[ -n "${AGENT_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=( ${AGENT_EXTRA_ARGS} )
    cmd+=("${extra[@]}")
  fi

  log_info "Running agent backend=$backend workdir=$workdir"

  if [[ "$input_mode" == "stdin" ]]; then
    if command -v timeout >/dev/null 2>&1 && [[ "$timeout_minutes" -gt 0 ]]; then
      (
        cd "$workdir"
        cat "$prompt_file" | timeout "${timeout_minutes}m" "${cmd[@]}"
      ) >"$run_log_file" 2>&1
      return $?
    fi

    (
      cd "$workdir"
      cat "$prompt_file" | "${cmd[@]}"
    ) >"$run_log_file" 2>&1
    return $?
  fi

  if command -v timeout >/dev/null 2>&1 && [[ "$timeout_minutes" -gt 0 ]]; then
    (
      cd "$workdir"
      timeout "${timeout_minutes}m" "${cmd[@]}"
    ) >"$run_log_file" 2>&1
    return $?
  fi

  (
    cd "$workdir"
    "${cmd[@]}"
  ) >"$run_log_file" 2>&1
}

