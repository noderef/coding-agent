#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib/repo-config.sh
source "${ROOT_DIR}/lib/repo-config.sh"
# shellcheck source=lib/github.sh
source "${ROOT_DIR}/lib/github.sh"
# shellcheck source=lib/agent-runner.sh
source "${ROOT_DIR}/lib/agent-runner.sh"
# shellcheck source=lib/state.sh
source "${ROOT_DIR}/lib/state.sh"
# shellcheck source=lib/worktree.sh
source "${ROOT_DIR}/lib/worktree.sh"

load_env_file "${ROOT_DIR}/.env"

: "${AGENT_GITHUB_USERNAME:?AGENT_GITHUB_USERNAME is required}"
: "${PROJECTS_DIR:=./projects}"
: "${RUNTIME_DIR:=./worktrees}"
: "${STATE_DIR:=${ROOT_DIR}/state}"
: "${LOG_DIR:=${ROOT_DIR}/logs}"
: "${FEEDBACK_TIMEOUT_MINUTES:=35}"
: "${MIN_AVAILABLE_MB:=512}"
: "${DAILY_FEEDBACK_LIMIT:=0}"

PROJECTS_DIR="$(expand_path "$PROJECTS_DIR")"
RUNTIME_DIR="$(expand_path "$RUNTIME_DIR")"
STATE_DIR="$(expand_path "$STATE_DIR")"
LOG_DIR="$(expand_path "$LOG_DIR")"

LOCK_FILE="${STATE_DIR}/worker.lock"

ensure_dir "$STATE_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$PROJECTS_DIR"
ensure_dir "${RUNTIME_DIR}/worktrees"

LOG_FILE="${LOG_DIR}/feedback-worker-$(date -u +%Y-%m-%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_commands gh jq git flock awk sed tr tee
repo_config_validate
state_init

if ! enforce_memory_guard "$MIN_AVAILABLE_MB"; then
  log_warn "Memory guard blocked feedback worker run"
  exit 0
fi

if ! acquire_shared_lock "$LOCK_FILE"; then
  exit 0
fi

SYSTEM_PR_LABEL="$(repo_system_pr_label)"
FEEDBACK_VALIDATION_LOG_FILE=""
FEEDBACK_CLEANUP_ACTIVE=0
FEEDBACK_CLEANUP_REPO_SLUG=""
FEEDBACK_CLEANUP_PR_NUMBER=""
FEEDBACK_CLEANUP_COMMENT_URL=""
FEEDBACK_CLEANUP_LOCAL_REPO_PATH=""
FEEDBACK_CLEANUP_WORKTREE_PATH=""
FEEDBACK_CLEANUP_PROMPT_FILE=""

feedback_cleanup_on_error() {
  local exit_code="$?"

  if [[ "$FEEDBACK_CLEANUP_ACTIVE" -ne 1 ]]; then
    return "$exit_code"
  fi

  FEEDBACK_CLEANUP_ACTIVE=0

  log_error "Feedback processing failed unexpectedly for ${FEEDBACK_CLEANUP_REPO_SLUG}#PR${FEEDBACK_CLEANUP_PR_NUMBER}"
  if [[ -n "$FEEDBACK_CLEANUP_REPO_SLUG" ]] && [[ -n "$FEEDBACK_CLEANUP_PR_NUMBER" ]]; then
    gh_pr_comment \
      "$FEEDBACK_CLEANUP_REPO_SLUG" \
      "$FEEDBACK_CLEANUP_PR_NUMBER" \
      "Autonomous feedback processing failed unexpectedly${FEEDBACK_CLEANUP_COMMENT_URL:+ while handling ${FEEDBACK_CLEANUP_COMMENT_URL}}. Cleanup was applied and no additional changes were pushed. Logs are available to maintainers on the runtime host." \
      || true
  fi

  if [[ -n "$FEEDBACK_CLEANUP_WORKTREE_PATH" ]] && [[ -n "$FEEDBACK_CLEANUP_LOCAL_REPO_PATH" ]]; then
    git -C "$FEEDBACK_CLEANUP_LOCAL_REPO_PATH" worktree remove --force "$FEEDBACK_CLEANUP_WORKTREE_PATH" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FEEDBACK_CLEANUP_PROMPT_FILE" ]]; then
    rm -f "$FEEDBACK_CLEANUP_PROMPT_FILE" || true
  fi

  return "$exit_code"
}

feedback_cleanup_activate() {
  local repo_slug="$1"
  local pr_number="$2"
  local local_repo_path="${3:-}"
  local worktree_path="${4:-}"
  local comment_url="${5:-}"

  FEEDBACK_CLEANUP_REPO_SLUG="$repo_slug"
  FEEDBACK_CLEANUP_PR_NUMBER="$pr_number"
  FEEDBACK_CLEANUP_LOCAL_REPO_PATH="$local_repo_path"
  FEEDBACK_CLEANUP_WORKTREE_PATH="$worktree_path"
  FEEDBACK_CLEANUP_COMMENT_URL="$comment_url"
  FEEDBACK_CLEANUP_ACTIVE=1
}

feedback_cleanup_deactivate() {
  FEEDBACK_CLEANUP_ACTIVE=0
  FEEDBACK_CLEANUP_REPO_SLUG=""
  FEEDBACK_CLEANUP_PR_NUMBER=""
  FEEDBACK_CLEANUP_COMMENT_URL=""
  FEEDBACK_CLEANUP_LOCAL_REPO_PATH=""
  FEEDBACK_CLEANUP_WORKTREE_PATH=""
  FEEDBACK_CLEANUP_PROMPT_FILE=""
}

trap 'feedback_cleanup_on_error' ERR

is_authorized_user() {
  local username="$1"
  local allowed="${AUTHORIZED_USERS:-}"

  if [[ -z "$allowed" ]]; then
    return 0
  fi

  comma_list_contains "$allowed" "$username"
}

comment_mentions_bot() {
  local comment_body="$1"
  local lower_body
  local lower_bot

  lower_body="$(printf '%s' "$comment_body" | tr '[:upper:]' '[:lower:]')"
  lower_bot="$(printf '%s' "$AGENT_GITHUB_USERNAME" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower_body" == *"@${lower_bot}"* ]]
}

feedback_too_broad() {
  local comment_body="$1"
  local lower_body
  lower_body="$(printf '%s' "$comment_body" | tr '[:upper:]' '[:lower:]')"

  if [[ ${#lower_body} -gt 3500 ]]; then
    return 0
  fi

  if [[ "$lower_body" == *"entire repo"* ]] || [[ "$lower_body" == *"whole codebase"* ]]; then
    return 0
  fi

  if [[ "$lower_body" == *"rewrite"* ]] && [[ "$lower_body" == *"from scratch"* ]]; then
    return 0
  fi

  return 1
}

collect_open_candidate_prs() {
  local prs='[]'
  local repo_slug

  while IFS= read -r repo_slug; do
    [[ -z "$repo_slug" ]] && continue

    local result
    if ! result="$(gh_list_open_prs "$repo_slug" 100 2>/dev/null)"; then
      log_warn "Skipping PR list for repo due to failure: $repo_slug" >&2
      continue
    fi

    result="$(jq -c \
      --arg repo "$repo_slug" \
      --arg bot "$AGENT_GITHUB_USERNAME" \
      --arg label "$SYSTEM_PR_LABEL" '
      [
        .[]
        | . + {repo_slug: $repo}
        | select(
            (.author.login == $bot)
            or
            ([.labels[].name] | index($label) != null)
          )
      ]
    ' <<<"$result")"

    prs="$(jq -c --argjson incoming "$result" '. + $incoming' <<<"$prs")"
  done < <(repo_list_enabled_slugs)

  jq -c 'sort_by(.createdAt)' <<<"$prs"
}

collect_pr_feedback_comments() {
  local repo_slug="$1"
  local pr_number="$2"

  local issue_comments review_comments
  issue_comments="$(gh_pr_issue_comments "$repo_slug" "$pr_number")"
  review_comments="$(gh_pr_review_comments "$repo_slug" "$pr_number")"

  jq -c -n \
    --argjson issue "$issue_comments" \
    --argjson review "$review_comments" '
      (
        $issue | map({
          type: "issue_comment",
          id: .id,
          body: (.body // ""),
          author: .user.login,
          created_at: .created_at,
          url: .html_url,
          path: null,
          line: null
        })
      )
      +
      (
        $review | map({
          type: "review_comment",
          id: .id,
          body: (.body // ""),
          author: .user.login,
          created_at: .created_at,
          url: .html_url,
          path: (.path // null),
          line: (.line // null)
        })
      )
      | sort_by(.created_at)
    '
}

create_pr_worktree() {
  local local_path="$1"
  local worktree_path="$2"
  local head_branch="$3"

  if [[ -d "$worktree_path" ]]; then
    git -C "$local_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || rm -rf "$worktree_path"
  fi

  git -C "$local_path" fetch origin "$head_branch" >/dev/null
  git -C "$local_path" worktree add -B "$head_branch" "$worktree_path" "origin/${head_branch}" >/dev/null
}

run_validation_commands_if_configured() {
  local repo_slug="$1"
  local worktree_path="$2"
  local install_cmd
  local test_cmd
  local repo_key
  local validation_log
  install_cmd="$(repo_get_install_command "$repo_slug")"
  test_cmd="$(repo_get_test_command "$repo_slug")"

  if [[ -z "$install_cmd" ]] && [[ -z "$test_cmd" ]]; then
    FEEDBACK_VALIDATION_LOG_FILE=""
    log_info "No install/test commands configured for ${repo_slug}; skipping validation" >&2
    printf '%s\n' "not-configured"
    return 0
  fi

  repo_key="$(repo_slug_to_fs_key "$repo_slug")"
  validation_log="${LOG_DIR}/validation-feedback-${repo_key}-$(date -u +%Y%m%dT%H%M%SZ).log"
  FEEDBACK_VALIDATION_LOG_FILE="$validation_log"

  if [[ -n "$install_cmd" ]]; then
    printf 'Install command: %s\n' "$install_cmd" >"$validation_log"
    if (
      cd "$worktree_path"
      bash -lc "$install_cmd"
    ) >>"$validation_log" 2>&1; then
      printf '\n' >>"$validation_log"
    else
      log_warn "Install command failed (log: $validation_log)" >&2
      printf '%s\n' "install-failed"
      return 0
    fi
  else
    : >"$validation_log"
  fi

  if [[ -n "$test_cmd" ]]; then
    printf 'Test command: %s\n' "$test_cmd" >>"$validation_log"
    if ! (
      cd "$worktree_path"
      bash -lc "$test_cmd"
    ) >>"$validation_log" 2>&1; then
      log_warn "Test command failed (log: $validation_log)" >&2
      printf '%s\n' "test-failed"
      return 0
    fi
  fi

  log_info "Validation commands passed (log: $validation_log)" >&2
  printf '%s\n' "passed"
  return 0
}

line_context_snippet() {
  local worktree_path="$1"
  local file_path="$2"
  local line_no="$3"

  if [[ -z "$file_path" ]] || [[ -z "$line_no" ]] || [[ ! -f "$worktree_path/$file_path" ]]; then
    return 0
  fi

  local start end
  start=$(( line_no > 5 ? line_no - 5 : 1 ))
  end=$(( line_no + 5 ))
  sed -n "${start},${end}p" "$worktree_path/$file_path"
}

build_feedback_prompt_file() {
  local output_file="$1"
  local repo_slug="$2"
  local pr_number="$3"
  local pr_title="$4"
  local pr_body="$5"
  local feedback_json="$6"
  local forbidden_json="$7"
  local install_command="$8"
  local test_command="$9"
  local instructions_file="${10}"
  local diff_snippet="${11}"
  local line_context="${12}"

  cat "${ROOT_DIR}/agents/feedback-worker-prompt.md" >"$output_file"

  cat >>"$output_file" <<PROMPT

## Runtime Context
- Repository: ${repo_slug}
- PR Number: ${pr_number}
- PR Title: ${pr_title}
- Install Command: ${install_command:-not configured}
- Test Command: ${test_command:-not configured}

## PR Description
${pr_body}

## Feedback To Address
- Comment Type: $(jq -r '.type' <<<"$feedback_json")
- Author: $(jq -r '.author' <<<"$feedback_json")
- URL: $(jq -r '.url' <<<"$feedback_json")
- Body:
$(jq -r '.body' <<<"$feedback_json")

## Forbidden Paths (Do Not Modify)
$(jq -r '.[] | "- " + .' <<<"$forbidden_json")

## PR Diff (Truncated)
${diff_snippet}
PROMPT

  if [[ -n "$line_context" ]]; then
    cat >>"$output_file" <<PROMPT

## Review Line Context
${line_context}
PROMPT
  fi

  if [[ -f "$instructions_file" ]]; then
    cat >>"$output_file" <<PROMPT

## Repo Specific Instructions
$(cat "$instructions_file")
PROMPT
  fi
}

feedback_validation_status_for_comment() {
  local validation_status="$1"

  case "$validation_status" in
    passed)
      printf '%s\n' "Configured install/test commands passed."
      ;;
    not-configured)
      printf '%s\n' "No repository install/test commands were configured."
      ;;
    install-failed)
      printf '%s\n' "Configured install command failed."
      ;;
    test-failed)
      printf '%s\n' "Configured test command failed."
      ;;
    *)
      printf 'Validation status: %s.\n' "$validation_status"
      ;;
  esac
}

summarize_feedback_files_for_comment() {
  local changed_files="$1"
  local limit="${2:-5}"

  local file_count=0
  local summary=""
  local file

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    file_count=$((file_count + 1))
    if (( file_count <= limit )); then
      summary+="- \`${file}\`\n"
    fi
  done <<<"$changed_files"

  if (( file_count > limit )); then
    summary+="- ...and $((file_count - limit)) more file(s)\n"
  fi

  printf '%s\n' "$file_count"
  printf '%b' "$summary"
}

build_feedback_success_comment() {
  local comment_id="$1"
  local comment_author="$2"
  local comment_url="$3"
  local commit_sha="$4"
  local validation_status="$5"
  local changed_files="$6"

  local -a openers=(
    "Implemented your feedback."
    "Finished a focused follow-up for this comment."
    "Applied the requested adjustment."
  )

  local opener_index=$(( comment_id % ${#openers[@]} ))
  local opener="${openers[$opener_index]}"

  local files_preview file_count validation_note
  files_preview="$(summarize_feedback_files_for_comment "$changed_files" 5)"
  file_count="$(head -n1 <<<"$files_preview")"
  files_preview="$(tail -n +2 <<<"$files_preview")"
  validation_note="$(feedback_validation_status_for_comment "$validation_status")"

  cat <<EOF
${opener}
Addressed ${comment_url} from @${comment_author} in commit \`${commit_sha}\`.

Summary:
- ${validation_note}
- Files touched (${file_count}):
${files_preview}
EOF
}

feedback_commit_prefix_for_branch() {
  local branch_name="$1"
  local lower
  lower="$(printf '%s' "$branch_name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == fix/* ]] || [[ "$lower" == bug/* ]]; then
    printf '%s\n' ":bug:"
    return 0
  fi

  if [[ "$lower" == feature/* ]] || [[ "$lower" == feat/* ]] || [[ "$lower" == enhancement/* ]]; then
    printf '%s\n' ":sparkles:"
    return 0
  fi

  printf '%s\n' "agent:"
}

normalize_commit_sentence() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
  printf '%s\n' "$value"
}

build_feedback_commit_message() {
  local head_branch="$1"
  local pr_title="$2"

  local prefix
  local summary
  prefix="$(feedback_commit_prefix_for_branch "$head_branch")"
  summary="$(normalize_commit_sentence "$pr_title")"

  if [[ -z "$summary" ]]; then
    summary="Apply requested PR follow-up."
  elif [[ ! "$summary" =~ [.!?]$ ]]; then
    summary="${summary}."
  fi

  printf '%s %s\n' "$prefix" "$summary"
}

process_feedback_comment() {
  local pr_json="$1"
  local feedback_json="$2"

  local repo_slug pr_number pr_title pr_body head_branch
  repo_slug="$(jq -r '.repo_slug' <<<"$pr_json")"
  pr_number="$(jq -r '.number' <<<"$pr_json")"
  pr_title="$(jq -r '.title' <<<"$pr_json")"
  pr_body="$(jq -r '.body // ""' <<<"$pr_json")"
  head_branch="$(jq -r '.headRefName' <<<"$pr_json")"

  local comment_id comment_type comment_author comment_body comment_url
  comment_id="$(jq -r '.id' <<<"$feedback_json")"
  comment_type="$(jq -r '.type' <<<"$feedback_json")"
  comment_author="$(jq -r '.author' <<<"$feedback_json")"
  comment_body="$(jq -r '.body' <<<"$feedback_json")"
  comment_url="$(jq -r '.url' <<<"$feedback_json")"

  local key
  key="$(state_feedback_key "$repo_slug" "$pr_number" "$comment_type" "$comment_id")"
  if state_is_processed "$key"; then
    return 0
  fi

  if ! comment_mentions_bot "$comment_body"; then
    return 0
  fi

  if [[ "$comment_author" == "$AGENT_GITHUB_USERNAME" ]]; then
    return 0
  fi

  if ! is_authorized_user "$comment_author"; then
    return 0
  fi

  if [[ "$DAILY_FEEDBACK_LIMIT" -gt 0 ]]; then
    local today_count
    today_count="$(state_processed_today_count)"
    if [[ "$today_count" -ge "$DAILY_FEEDBACK_LIMIT" ]]; then
      log_warn "Daily feedback limit reached (${DAILY_FEEDBACK_LIMIT})"
      return 1
    fi
  fi

  if feedback_too_broad "$comment_body"; then
    gh_pr_comment "$repo_slug" "$pr_number" "I skipped this feedback because it appears too broad for a safe autonomous patch. Please split it into a focused request with explicit scope."
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "too_broad" "$comment_url" "feedback rejected as too broad"
    return 0
  fi

  local default_branch
  default_branch="$(gh_repo_default_branch "$repo_slug")"
  if [[ "$head_branch" == "$default_branch" ]]; then
    gh_pr_comment "$repo_slug" "$pr_number" "Safety check blocked this run because the PR head branch matches the default branch."
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "unsafe_branch" "$comment_url" "head branch matched default branch"
    return 0
  fi

  local local_repo_path repo_key worktree_path
  local prompt_file agent_log instructions_file forbidden_json install_command test_command
  local diff_snippet line_context

  local_repo_path="$(repo_get_local_path "$repo_slug")"
  repo_key="$(repo_slug_to_fs_key "$repo_slug")"
  worktree_path="${RUNTIME_DIR}/worktrees/${repo_key}/pr-${pr_number}"

  feedback_cleanup_activate "$repo_slug" "$pr_number" "$local_repo_path" "$worktree_path" "$comment_url"

  prepare_repo_checkout_fetch "$repo_slug" "$local_repo_path"
  create_pr_worktree "$local_repo_path" "$worktree_path" "$head_branch"

  instructions_file="$(repo_get_instructions_file "$repo_slug")"
  forbidden_json="$(repo_get_forbidden_paths_json "$repo_slug")"
  install_command="$(repo_get_install_command "$repo_slug")"
  test_command="$(repo_get_test_command "$repo_slug")"

  diff_snippet="$(gh_pr_diff "$repo_slug" "$pr_number" | sed -n '1,400p')"

  line_context=""
  local review_path review_line
  review_path="$(jq -r '.path // ""' <<<"$feedback_json")"
  review_line="$(jq -r '.line // ""' <<<"$feedback_json")"
  if [[ -n "$review_path" ]] && [[ -n "$review_line" ]]; then
    line_context="$(line_context_snippet "$worktree_path" "$review_path" "$review_line")"
  fi

  prompt_file="$(mktemp "${STATE_DIR}/feedback-prompt-${pr_number}-${comment_id}.XXXX.md")"
  FEEDBACK_CLEANUP_PROMPT_FILE="$prompt_file"
  agent_log="${LOG_DIR}/agent-feedback-${repo_key}-${pr_number}-${comment_id}-$(date -u +%Y%m%dT%H%M%SZ).log"

  build_feedback_prompt_file \
    "$prompt_file" \
    "$repo_slug" \
    "$pr_number" \
    "$pr_title" \
    "$pr_body" \
    "$feedback_json" \
    "$forbidden_json" \
    "$install_command" \
    "$test_command" \
    "$instructions_file" \
    "$diff_snippet" \
    "$line_context"

  local agent_exit=0
  set +e
  agent_run "$worktree_path" "$prompt_file" "$FEEDBACK_TIMEOUT_MINUTES" "$agent_log"
  agent_exit=$?
  set -e

  rm -f "$prompt_file"
  FEEDBACK_CLEANUP_PROMPT_FILE=""

  if [[ "$agent_exit" -ne 0 ]]; then
    local fail_note="Autonomous feedback run failed."
    local status="failed"
    local failure_excerpt=""
    if [[ "$agent_exit" -eq 124 ]]; then
      fail_note="Autonomous feedback run timed out after ${FEEDBACK_TIMEOUT_MINUTES} minutes."
      status="timeout"
    fi
    failure_excerpt="$(log_excerpt_for_comment "$agent_log" 80 5000)"
    gh_pr_comment "$repo_slug" "$pr_number" "$(cat <<EOF
${fail_note} (source comment: ${comment_url})

Recent output:
\`\`\`
${failure_excerpt:-No log output captured.}
\`\`\`
EOF
    )"
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "$status" "$comment_url" "$fail_note"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    feedback_cleanup_deactivate
    return 0
  fi

  local changed_files
  changed_files="$(list_changed_files "$worktree_path")"

  if [[ -z "$changed_files" ]]; then
    gh_pr_comment "$repo_slug" "$pr_number" "I reviewed ${comment_url} and found no code changes were required."
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "noop" "$comment_url" "no code changes needed"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    feedback_cleanup_deactivate
    return 0
  fi

  local forbidden_touched
  forbidden_touched="$(forbidden_touches "$changed_files" "$forbidden_json" || true)"
  if [[ -n "$forbidden_touched" ]]; then
    gh_pr_comment "$repo_slug" "$pr_number" "$(cat <<EOF
I skipped this feedback because the resulting patch touched forbidden paths:

$(printf '%s\n' "$forbidden_touched" | sed 's/^/- /')
EOF
)"
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "forbidden" "$comment_url" "forbidden paths touched"
    git -C "$worktree_path" reset --hard >/dev/null
    git -C "$worktree_path" clean -fd >/dev/null
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    feedback_cleanup_deactivate
    return 0
  fi

  local validation_status
  validation_status="$(run_validation_commands_if_configured "$repo_slug" "$worktree_path")"
  if [[ "$validation_status" == "install-failed" ]] || [[ "$validation_status" == "test-failed" ]]; then
    local test_excerpt=""
    test_excerpt="$(log_excerpt_for_comment "$FEEDBACK_VALIDATION_LOG_FILE" 80 5000)"
    gh_pr_comment "$repo_slug" "$pr_number" "$(cat <<EOF
I applied a candidate change for ${comment_url}, but configured validation commands failed (${validation_status}), so nothing was pushed.

Recent validation output:
\`\`\`
${test_excerpt:-No validation output captured.}
\`\`\`
EOF
    )"
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "validation_failed" "$comment_url" "validation commands failed"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    feedback_cleanup_deactivate
    return 0
  fi

  git -C "$worktree_path" add -A
  if git -C "$worktree_path" diff --cached --quiet; then
    gh_pr_comment "$repo_slug" "$pr_number" "I reviewed ${comment_url}; after validation there were no committable changes."
    state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "noop" "$comment_url" "no staged changes"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    feedback_cleanup_deactivate
    return 0
  fi

  local commit_message
  commit_message="$(build_feedback_commit_message "$head_branch" "$pr_title")"
  git -C "$worktree_path" commit -m "$commit_message" >/dev/null
  git -C "$worktree_path" push origin "$head_branch" >/dev/null

  local commit_sha
  commit_sha="$(git -C "$worktree_path" rev-parse --short HEAD)"

  gh_pr_comment \
    "$repo_slug" \
    "$pr_number" \
    "$(build_feedback_success_comment "$comment_id" "$comment_author" "$comment_url" "$commit_sha" "$validation_status" "$changed_files")"
  state_mark_processed "$key" "$repo_slug" "$pr_number" "$comment_type" "$comment_id" "$comment_author" "applied" "$comment_url" "commit ${commit_sha}"

  git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  feedback_cleanup_deactivate
  return 0
}

main() {
  log_info "Feedback worker started"

  local prs
  prs="$(collect_open_candidate_prs)"

  if [[ "$(jq 'length' <<<"$prs")" -eq 0 ]]; then
    log_info "No eligible open PRs found"
    exit 0
  fi

  local stop_for_day=0
  local pr_json
  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue

    local repo_slug pr_number
    repo_slug="$(jq -r '.repo_slug' <<<"$pr_json")"
    pr_number="$(jq -r '.number' <<<"$pr_json")"

    log_info "Checking feedback for ${repo_slug}#PR${pr_number}"

    local comments
    if ! comments="$(collect_pr_feedback_comments "$repo_slug" "$pr_number")"; then
      log_warn "Failed to collect comments for ${repo_slug}#PR${pr_number}"
      continue
    fi

    local feedback_json
    while IFS= read -r feedback_json; do
      [[ -z "$feedback_json" ]] && continue
      if ! process_feedback_comment "$pr_json" "$feedback_json"; then
        stop_for_day=1
        break
      fi
    done < <(jq -c '.[]' <<<"$comments")

    if [[ "$stop_for_day" -eq 1 ]]; then
      break
    fi
  done < <(jq -c '.[]' <<<"$prs")

  log_info "Feedback worker finished"
}

main "$@"
