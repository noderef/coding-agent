#!/usr/bin/env bash

set -euo pipefail

list_changed_files() {
  local worktree="$1"
  {
    git -C "$worktree" diff --name-only
    git -C "$worktree" diff --cached --name-only
    git -C "$worktree" ls-files --others --exclude-standard
  } | awk 'NF' | sort -u
}

file_matches_pattern() {
  local file_path="$1"
  local pattern="$2"

  if [[ -z "$pattern" ]]; then
    return 1
  fi

  # Support leading **/ explicitly so these patterns match both root and nested paths.
  # Example: **/master.key matches master.key and any/path/master.key.
  if [[ "${pattern:0:3}" == "**/" ]]; then
    local suffix="${pattern:3}"
    if [[ -n "$suffix" ]] && ([[ "$file_path" == $suffix ]] || [[ "$file_path" == */$suffix ]]); then
      return 0
    fi
  fi

  if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]] || [[ "$pattern" == *"["* ]]; then
    [[ "$file_path" == $pattern ]]
    return $?
  fi

  if [[ "$file_path" == "$pattern" ]] || [[ "$file_path" == "$pattern"/* ]]; then
    return 0
  fi

  return 1
}

forbidden_touches() {
  local changed_files="$1"
  local forbidden_json="$2"

  local -a global_forbidden=(
    ".env"
    ".env.*"
    "**/.env"
    "**/.env.*"
    "secrets"
    "secrets/*"
    "**/secrets/*"
  )

  local -a repo_forbidden=()
  if [[ -n "$forbidden_json" ]]; then
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] && repo_forbidden+=("$pattern")
    done < <(jq -r '.[]' <<<"$forbidden_json")
  fi

  local file pattern
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    for pattern in "${global_forbidden[@]}"; do
      if file_matches_pattern "$file" "$pattern"; then
        printf '%s\n' "$file"
        continue 2
      fi
    done

    for pattern in "${repo_forbidden[@]}"; do
      if file_matches_pattern "$file" "$pattern"; then
        printf '%s\n' "$file"
        continue 2
      fi
    done
  done <<<"$changed_files"
}

prepare_repo_checkout_fetch() {
  local repo_slug="$1"
  local local_path="$2"

  gh_clone_repo_if_missing "$repo_slug" "$local_path"

  if [[ -n "$(git -C "$local_path" status --porcelain)" ]]; then
    die "Local checkout has uncommitted changes: $local_path"
  fi

  git -C "$local_path" fetch --prune origin
}

prepare_repo_checkout_sync_default() {
  local repo_slug="$1"
  local local_path="$2"

  prepare_repo_checkout_fetch "$repo_slug" "$local_path"

  local default_branch
  default_branch="$(gh_repo_default_branch "$repo_slug")"
  git -C "$local_path" checkout "$default_branch" >/dev/null 2>&1
  git -C "$local_path" reset --hard "origin/${default_branch}" >/dev/null

  printf '%s\n' "$default_branch"
}
