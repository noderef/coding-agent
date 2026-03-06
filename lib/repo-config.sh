#!/usr/bin/env bash

set -euo pipefail

REPO_CONFIG_DEFAULT="${ROOT_DIR}/configs/repos.json"

repo_config_path() {
  local cfg="${CONFIG_FILE:-$REPO_CONFIG_DEFAULT}"
  expand_path "$cfg"
}

repo_config_validate() {
  local cfg
  cfg="$(repo_config_path)"

  if [[ ! -f "$cfg" ]]; then
    log_error "Config file not found: $cfg"
    return 1
  fi

  jq -e '.repos and (.repos | type == "array")' "$cfg" >/dev/null
}

repo_list_enabled_slugs() {
  local cfg
  cfg="$(repo_config_path)"
  jq -r '.repos[] | select(.enabled == true) | .slug' "$cfg"
}

repo_is_enabled() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"
  jq -e --arg slug "$slug" '.repos[] | select(.slug == $slug and .enabled == true)' "$cfg" >/dev/null
}

repo_slug_to_fs_key() {
  local slug="$1"
  printf '%s\n' "${slug//\//__}"
}

repo_default_local_path() {
  local slug="$1"
  local owner
  local repo_name
  owner="${slug%%/*}"
  repo_name="${slug##*/}"
  printf '%s/%s/%s\n' "$(expand_path "${PROJECTS_DIR}")" "$owner" "$repo_name"
}

repo_get_local_path() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"

  local configured
  configured="$(jq -r --arg slug "$slug" '
    .repos[] | select(.slug == $slug) | (.local_path // "")
  ' "$cfg")"

  if [[ -n "$configured" ]]; then
    expand_path "$configured"
  else
    repo_default_local_path "$slug"
  fi
}

repo_get_instructions_file() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"

  local rel
  rel="$(jq -r --arg slug "$slug" '
    .repos[] | select(.slug == $slug) | (.instructions_file // "")
  ' "$cfg")"

  if [[ -z "$rel" ]]; then
    return 0
  fi

  if [[ "$rel" = /* ]]; then
    printf '%s\n' "$rel"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$rel"
  fi
}

repo_get_test_command() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"
  jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | (.test_command // "")' "$cfg"
}

repo_get_forbidden_paths_json() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"
  jq -c --arg slug "$slug" '
    .repos[] | select(.slug == $slug) | (.forbidden_paths // [])
  ' "$cfg"
}

repo_get_optional_labels_json() {
  local slug="$1"
  local cfg
  cfg="$(repo_config_path)"
  jq -c --arg slug "$slug" '
    .repos[] | select(.slug == $slug) | (.labels // {})
  ' "$cfg"
}

repo_system_pr_label() {
  local cfg
  cfg="$(repo_config_path)"
  jq -r '.system.pr_label // "coding-agent"' "$cfg"
}

repo_allows_repo() {
  local slug="$1"
  repo_is_enabled "$slug"
}

