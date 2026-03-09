#!/usr/bin/env bash

set -euo pipefail

AGENT_CLI_HELP_CACHE=""

agent_cli_help() {
  if [[ -n "$AGENT_CLI_HELP_CACHE" ]]; then
    printf '%s\n' "$AGENT_CLI_HELP_CACHE"
    return 0
  fi

  AGENT_CLI_HELP_CACHE="$("$AGENT_CMD" --help 2>/dev/null || true)"
  printf '%s\n' "$AGENT_CLI_HELP_CACHE"
}

agent_cli_supports_flag() {
  local flag="$1"
  local help_text
  help_text="$(agent_cli_help)"
  [[ "$help_text" == *"$flag"* ]]
}

agent_cli_has_command() {
  local name="$1"
  local help_text
  help_text="$(agent_cli_help)"
  grep -Eq "^[[:space:]]+${name}([[:space:]]|\\|)" <<<"$help_text"
}

agent_validate_config() {
  : "${AGENT_BACKEND:?AGENT_BACKEND is required}"
  : "${AGENT_CMD:?AGENT_CMD is required}"
  : "${AGENT_MODEL:?AGENT_MODEL is required}"

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
  local input_mode="${AGENT_INPUT_MODE-}"
  local subcommand="${AGENT_SUBCOMMAND-}"
  local model_flag="${AGENT_MODEL_FLAG-}"
  local base_url_flag="${AGENT_BASE_URL_FLAG-}"
  local api_key_flag="${AGENT_API_KEY_FLAG-}"
  local prompt_file_flag="${AGENT_PROMPT_FILE_FLAG-}"
  local non_interactive_flag="${AGENT_NON_INTERACTIVE_FLAG-}"
  local prompt_text=""

  local -a cmd
  cmd=("$AGENT_CMD")

  case "$backend" in
    cline)
      if [[ -z "${AGENT_SUBCOMMAND+x}" ]]; then
        if agent_cli_has_command "run"; then
          subcommand="run"
        else
          subcommand=""
        fi
      fi

      if [[ -z "${AGENT_MODEL_FLAG+x}" ]]; then
        model_flag="--model"
      fi
      if [[ -z "${AGENT_BASE_URL_FLAG+x}" ]]; then
        if agent_cli_supports_flag "--base-url"; then
          base_url_flag="--base-url"
        else
          base_url_flag=""
        fi
      fi
      if [[ -z "${AGENT_API_KEY_FLAG+x}" ]]; then
        if agent_cli_supports_flag "--api-key"; then
          api_key_flag="--api-key"
        else
          api_key_flag=""
        fi
      fi
      if [[ -z "${AGENT_PROMPT_FILE_FLAG+x}" ]]; then
        if agent_cli_supports_flag "--prompt-file"; then
          prompt_file_flag="--prompt-file"
        else
          prompt_file_flag=""
        fi
      fi
      if [[ -z "${AGENT_NON_INTERACTIVE_FLAG+x}" ]]; then
        if agent_cli_supports_flag "--non-interactive"; then
          non_interactive_flag="--non-interactive"
        else
          non_interactive_flag=""
        fi
      fi
      if [[ -z "${AGENT_INPUT_MODE+x}" ]]; then
        if [[ -n "$prompt_file_flag" ]]; then
          input_mode="file"
        else
          input_mode="arg"
        fi
      fi

      case "$input_mode" in
        file|stdin|arg) ;;
        *)
          die "Unsupported AGENT_INPUT_MODE: $input_mode (expected: file, stdin, or arg)"
          ;;
      esac

      if [[ -n "$subcommand" ]]; then
        cmd+=("$subcommand")
      fi
      if [[ -n "$model_flag" ]]; then
        cmd+=("$model_flag" "$AGENT_MODEL")
      fi
      if [[ -n "$base_url_flag" && -n "${AGENT_BASE_URL:-}" ]]; then
        cmd+=("$base_url_flag" "$AGENT_BASE_URL")
      fi
      if [[ -n "$api_key_flag" && -n "${AGENT_API_KEY:-}" ]]; then
        cmd+=("$api_key_flag" "$AGENT_API_KEY")
      fi
      if [[ -n "$non_interactive_flag" ]]; then
        cmd+=("$non_interactive_flag")
      fi

      if [[ "$input_mode" == "file" ]]; then
        if [[ -n "$prompt_file_flag" ]]; then
          cmd+=("$prompt_file_flag" "$prompt_file")
        else
          prompt_text="$(cat "$prompt_file")"
          cmd+=("$prompt_text")
        fi
      elif [[ "$input_mode" == "arg" ]]; then
        prompt_text="$(cat "$prompt_file")"
        cmd+=("$prompt_text")
      fi
      ;;
    *)
      die "Unsupported AGENT_BACKEND: $backend"
      ;;
  esac

  if [[ -n "${AGENT_EXTRA_ARGS:-}" ]]; then
    local -a extra=()
    if [[ "${AGENT_EXTRA_ARGS}" == *$'\n'* ]]; then
      while IFS= read -r arg; do
        [[ -n "$arg" ]] && extra+=("$arg")
      done <<<"${AGENT_EXTRA_ARGS}"
    else
      # shellcheck disable=SC2206
      extra=( ${AGENT_EXTRA_ARGS} )
    fi
    cmd+=("${extra[@]}")
  fi

  log_info "Running agent backend=$backend workdir=$workdir"

  local -a env_prefix=()
  if [[ -n "${AGENT_BASE_URL:-}" ]]; then
    env_prefix+=("OPENAI_BASE_URL=${AGENT_BASE_URL}")
  fi
  if [[ -n "${AGENT_API_KEY:-}" ]]; then
    env_prefix+=("OPENAI_API_KEY=${AGENT_API_KEY}")
  fi

  local -a exec_cmd=()
  if [[ "${#env_prefix[@]}" -gt 0 ]]; then
    exec_cmd=(env "${env_prefix[@]}" "${cmd[@]}")
  else
    exec_cmd=("${cmd[@]}")
  fi

  if [[ "$input_mode" == "stdin" ]]; then
    if command -v timeout >/dev/null 2>&1 && [[ "$timeout_minutes" -gt 0 ]]; then
      (
        cd "$workdir"
        cat "$prompt_file" | timeout "${timeout_minutes}m" "${exec_cmd[@]}"
      ) >"$run_log_file" 2>&1
      return $?
    fi

    (
      cd "$workdir"
      cat "$prompt_file" | "${exec_cmd[@]}"
    ) >"$run_log_file" 2>&1
    return $?
  fi

  if command -v timeout >/dev/null 2>&1 && [[ "$timeout_minutes" -gt 0 ]]; then
    (
      cd "$workdir"
      timeout "${timeout_minutes}m" "${exec_cmd[@]}"
    ) >"$run_log_file" 2>&1
    return $?
  fi

  (
    cd "$workdir"
    "${exec_cmd[@]}"
  ) >"$run_log_file" 2>&1
}
