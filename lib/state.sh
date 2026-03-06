#!/usr/bin/env bash

set -euo pipefail

state_file_path() {
  printf '%s\n' "${STATE_FILE:-${STATE_DIR}/processed-feedback.json}"
}

state_init() {
  local file
  file="$(state_file_path)"
  ensure_dir "$(dirname "$file")"
  if [[ ! -f "$file" ]]; then
    printf '{"processed":{}}\n' >"$file"
    return 0
  fi

  if ! jq -e '.processed and (.processed | type == "object")' "$file" >/dev/null 2>&1; then
    log_warn "State file malformed, resetting: $file"
    printf '{"processed":{}}\n' >"$file"
  fi
}

state_feedback_key() {
  local repo_slug="$1"
  local pr_number="$2"
  local comment_type="$3"
  local comment_id="$4"
  printf '%s\n' "${repo_slug}#${pr_number}#${comment_type}#${comment_id}"
}

state_is_processed() {
  local key="$1"
  local file
  file="$(state_file_path)"
  jq -e --arg key "$key" '.processed[$key] != null' "$file" >/dev/null
}

state_mark_processed() {
  local key="$1"
  local repo_slug="$2"
  local pr_number="$3"
  local comment_type="$4"
  local comment_id="$5"
  local author="$6"
  local status="$7"
  local source_url="$8"
  local note="${9:-}"

  local file tmp
  file="$(state_file_path)"
  tmp="$(mktemp "${file}.tmp.XXXX")"

  jq \
    --arg key "$key" \
    --arg repo_slug "$repo_slug" \
    --arg pr_number "$pr_number" \
    --arg comment_type "$comment_type" \
    --arg comment_id "$comment_id" \
    --arg author "$author" \
    --arg status "$status" \
    --arg source_url "$source_url" \
    --arg note "$note" \
    --arg processed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '.processed[$key] = {
      repo_slug: $repo_slug,
      pr_number: ($pr_number|tonumber),
      comment_type: $comment_type,
      comment_id: ($comment_id|tonumber),
      author: $author,
      status: $status,
      source_url: $source_url,
      note: $note,
      processed_at: $processed_at
    }' \
    "$file" >"$tmp"

  mv "$tmp" "$file"
}

state_processed_today_count() {
  local file today
  file="$(state_file_path)"
  today="$(date -u +'%Y-%m-%d')"

  jq -r --arg today "$today" '
    [.processed[] | select(.processed_at | startswith($today))] | length
  ' "$file"
}

