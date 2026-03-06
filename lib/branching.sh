#!/usr/bin/env bash

set -euo pipefail

slugify() {
  local text="$1"
  text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  text="$(printf '%s' "$text" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$text" ]]; then
    text="update"
  fi
  printf '%s\n' "$text"
}

branch_prefix_for_labels() {
  local labels_csv="$1"
  local lower

  lower="$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')"

  if [[ ",$lower," == *",bug,"* ]]; then
    printf '%s\n' "fix"
    return 0
  fi

  if [[ ",$lower," == *",enhancement,"* ]] || [[ ",$lower," == *",feature,"* ]]; then
    printf '%s\n' "feature"
    return 0
  fi

  printf '%s\n' "chore"
}

build_issue_branch_name() {
  local issue_title="$1"
  local issue_number="$2"
  local labels_csv="$3"

  local prefix
  local slug
  prefix="$(branch_prefix_for_labels "$labels_csv")"
  slug="$(slugify "$issue_title")"

  printf '%s/%s-%s\n' "$prefix" "$slug" "$issue_number"
}

