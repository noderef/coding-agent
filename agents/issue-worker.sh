#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib/repo-config.sh
source "${ROOT_DIR}/lib/repo-config.sh"
# shellcheck source=lib/branching.sh
source "${ROOT_DIR}/lib/branching.sh"
# shellcheck source=lib/github.sh
source "${ROOT_DIR}/lib/github.sh"
# shellcheck source=lib/agent-runner.sh
source "${ROOT_DIR}/lib/agent-runner.sh"

load_env_file "${ROOT_DIR}/.env"

: "${AGENT_GITHUB_USERNAME:?AGENT_GITHUB_USERNAME is required}"
: "${PROJECTS_DIR:=./projects}"
: "${RUNTIME_DIR:=./worktrees}"
: "${STATE_DIR:=${ROOT_DIR}/state}"
: "${LOG_DIR:=${ROOT_DIR}/logs}"
: "${ISSUE_TIMEOUT_MINUTES:=45}"
: "${MIN_AVAILABLE_MB:=512}"
: "${MAX_OPEN_AGENT_PRS:=0}"
: "${UNASSIGN_ON_NOOP:=true}"

PROJECTS_DIR="$(expand_path "$PROJECTS_DIR")"
RUNTIME_DIR="$(expand_path "$RUNTIME_DIR")"
STATE_DIR="$(expand_path "$STATE_DIR")"
LOG_DIR="$(expand_path "$LOG_DIR")"

LOCK_FILE="${STATE_DIR}/worker.lock"

ensure_dir "$STATE_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$PROJECTS_DIR"
ensure_dir "${RUNTIME_DIR}/worktrees"

LOG_FILE="${LOG_DIR}/issue-worker-$(date -u +%Y-%m-%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

require_commands gh jq git flock awk sed tr tee
repo_config_validate

if ! enforce_memory_guard "$MIN_AVAILABLE_MB"; then
  log_warn "Memory guard blocked issue worker run"
  exit 0
fi

if ! acquire_shared_lock "$LOCK_FILE"; then
  exit 0
fi

SYSTEM_PR_LABEL="$(repo_system_pr_label)"
ISSUE_CLEANUP_ACTIVE=0
ISSUE_CLEANUP_REPO_SLUG=""
ISSUE_CLEANUP_ISSUE_NUMBER=""
ISSUE_CLEANUP_LOCAL_REPO_PATH=""
ISSUE_CLEANUP_WORKTREE_PATH=""

issue_cleanup_on_error() {
  local exit_code="$?"

  if [[ "$ISSUE_CLEANUP_ACTIVE" -ne 1 ]]; then
    return "$exit_code"
  fi

  ISSUE_CLEANUP_ACTIVE=0

  log_error "Issue processing failed unexpectedly for ${ISSUE_CLEANUP_REPO_SLUG}#${ISSUE_CLEANUP_ISSUE_NUMBER}"
  gh_issue_comment \
    "$ISSUE_CLEANUP_REPO_SLUG" \
    "$ISSUE_CLEANUP_ISSUE_NUMBER" \
    "Autonomous implementation failed unexpectedly. Cleanup was applied and the issue was returned for retry. Logs are available to maintainers on the runtime host." \
    || true
  gh_issue_remove_label "$ISSUE_CLEANUP_REPO_SLUG" "$ISSUE_CLEANUP_ISSUE_NUMBER" "in-progress" || true
  gh_issue_unassign "$ISSUE_CLEANUP_REPO_SLUG" "$ISSUE_CLEANUP_ISSUE_NUMBER" "$AGENT_GITHUB_USERNAME" || true

  if [[ -n "$ISSUE_CLEANUP_WORKTREE_PATH" ]] && [[ -n "$ISSUE_CLEANUP_LOCAL_REPO_PATH" ]]; then
    git -C "$ISSUE_CLEANUP_LOCAL_REPO_PATH" worktree remove --force "$ISSUE_CLEANUP_WORKTREE_PATH" >/dev/null 2>&1 || true
  fi

  return "$exit_code"
}

issue_cleanup_activate() {
  local repo_slug="$1"
  local issue_number="$2"
  local local_repo_path="${3:-}"
  local worktree_path="${4:-}"

  ISSUE_CLEANUP_REPO_SLUG="$repo_slug"
  ISSUE_CLEANUP_ISSUE_NUMBER="$issue_number"
  ISSUE_CLEANUP_LOCAL_REPO_PATH="$local_repo_path"
  ISSUE_CLEANUP_WORKTREE_PATH="$worktree_path"
  ISSUE_CLEANUP_ACTIVE=1
}

issue_cleanup_deactivate() {
  ISSUE_CLEANUP_ACTIVE=0
  ISSUE_CLEANUP_REPO_SLUG=""
  ISSUE_CLEANUP_ISSUE_NUMBER=""
  ISSUE_CLEANUP_LOCAL_REPO_PATH=""
  ISSUE_CLEANUP_WORKTREE_PATH=""
}

trap 'issue_cleanup_on_error' ERR

collect_candidate_issues() {
  local repos_json='[]'
  local repo_slug

  while IFS= read -r repo_slug; do
    if [[ -z "$repo_slug" ]]; then
      continue
    fi

    local result
    if ! result="$(gh_list_assigned_open_issues "$repo_slug" "$AGENT_GITHUB_USERNAME" 100 2>/dev/null)"; then
      log_warn "Skipping repo due to issue list failure: $repo_slug"
      continue
    fi

    result="$(jq -c --arg repo "$repo_slug" '[.[] | . + {repo_slug: $repo}]' <<<"$result")"
    repos_json="$(jq -c --argjson incoming "$result" '. + $incoming' <<<"$repos_json")"
  done < <(repo_list_enabled_slugs)

  jq -c 'sort_by(.createdAt)' <<<"$repos_json"
}

count_open_agent_prs() {
  local total=0
  local repo_slug

  while IFS= read -r repo_slug; do
    [[ -z "$repo_slug" ]] && continue
    local prs
    if ! prs="$(gh_list_open_prs "$repo_slug" 100 2>/dev/null)"; then
      continue
    fi
    local count
    count="$(jq -r --arg bot "$AGENT_GITHUB_USERNAME" '[.[] | select(.author.login == $bot)] | length' <<<"$prs")"
    total=$((total + count))
  done < <(repo_list_enabled_slugs)

  printf '%s\n' "$total"
}

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
    while IFS= read -r p; do
      [[ -n "$p" ]] && repo_forbidden+=("$p")
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

prepare_repo_checkout() {
  local repo_slug="$1"
  local local_path="$2"

  gh_clone_repo_if_missing "$repo_slug" "$local_path"

  if [[ -n "$(git -C "$local_path" status --porcelain)" ]]; then
    die "Local checkout has uncommitted changes: $local_path"
  fi

  git -C "$local_path" fetch --prune origin

  local default_branch
  default_branch="$(gh_repo_default_branch "$repo_slug")"
  git -C "$local_path" checkout "$default_branch" >/dev/null 2>&1
  git -C "$local_path" reset --hard "origin/${default_branch}" >/dev/null

  printf '%s\n' "$default_branch"
}

create_issue_worktree() {
  local local_path="$1"
  local worktree_path="$2"
  local branch_name="$3"
  local default_branch="$4"

  if [[ -d "$worktree_path" ]]; then
    git -C "$local_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || rm -rf "$worktree_path"
  fi

  if git -C "$local_path" ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
    if git -C "$local_path" show-ref --verify --quiet "refs/heads/${branch_name}"; then
      git -C "$local_path" branch -f "$branch_name" "origin/${branch_name}" >/dev/null
    else
      git -C "$local_path" branch "$branch_name" "origin/${branch_name}" >/dev/null
    fi
    git -C "$local_path" worktree add "$worktree_path" "$branch_name" >/dev/null
    return 0
  fi

  if git -C "$local_path" show-ref --verify --quiet "refs/heads/${branch_name}"; then
    git -C "$local_path" worktree add "$worktree_path" "$branch_name" >/dev/null
    return 0
  fi

  git -C "$local_path" worktree add -b "$branch_name" "$worktree_path" "origin/${default_branch}" >/dev/null
}

run_test_command_if_configured() {
  local repo_slug="$1"
  local worktree_path="$2"
  local test_cmd
  test_cmd="$(repo_get_test_command "$repo_slug")"

  if [[ -z "$test_cmd" ]]; then
    log_info "No test command configured for ${repo_slug}; skipping tests" >&2
    printf '%s\n' "not-configured"
    return 0
  fi

  log_info "Running configured tests: $test_cmd" >&2
  if (
    cd "$worktree_path"
    bash -lc "$test_cmd"
  ); then
    printf '%s\n' "passed"
  else
    printf '%s\n' "failed"
  fi
}

build_issue_prompt_file() {
  local output_file="$1"
  local repo_slug="$2"
  local issue_number="$3"
  local issue_title="$4"
  local issue_url="$5"
  local issue_body="$6"
  local forbidden_json="$7"
  local test_command="$8"
  local instructions_file="$9"

  cat "${ROOT_DIR}/agents/issue-worker-prompt.md" >"$output_file"

  cat >>"$output_file" <<PROMPT

## Runtime Context
- Repository: ${repo_slug}
- Issue Number: ${issue_number}
- Issue URL: ${issue_url}
- Issue Title: ${issue_title}
- Test Command: ${test_command:-not configured}

## Forbidden Paths (Do Not Modify)
$(jq -r '.[] | "- " + .' <<<"$forbidden_json")

## Issue Description
${issue_body}
PROMPT

  if [[ -f "$instructions_file" ]]; then
    cat >>"$output_file" <<PROMPT

## Repo Specific Instructions
$(cat "$instructions_file")
PROMPT
  fi
}

process_issue() {
  local issue_json="$1"

  local repo_slug issue_number issue_title issue_url issue_body labels_csv
  repo_slug="$(jq -r '.repo_slug' <<<"$issue_json")"
  issue_number="$(jq -r '.number' <<<"$issue_json")"
  issue_title="$(jq -r '.title' <<<"$issue_json")"
  issue_url="$(jq -r '.url' <<<"$issue_json")"
  issue_body="$(jq -r '.body // ""' <<<"$issue_json")"
  labels_csv="$(jq -r '[.labels[].name | ascii_downcase] | join(",")' <<<"$issue_json")"

  log_info "Selected issue ${repo_slug}#${issue_number}: ${issue_title}"

  local local_repo_path
  local default_branch
  local branch_name
  local repo_key
  local worktree_path
  local prompt_file
  local agent_log
  local instructions_file
  local forbidden_json
  local test_command

  local_repo_path="$(repo_get_local_path "$repo_slug")"
  issue_cleanup_activate "$repo_slug" "$issue_number" "$local_repo_path"
  default_branch="$(prepare_repo_checkout "$repo_slug" "$local_repo_path")"
  branch_name="$(build_issue_branch_name "$issue_title" "$issue_number" "$labels_csv")"
  repo_key="$(repo_slug_to_fs_key "$repo_slug")"
  worktree_path="${RUNTIME_DIR}/worktrees/${repo_key}/issue-${issue_number}"
  ensure_dir "$(dirname "$worktree_path")"
  issue_cleanup_activate "$repo_slug" "$issue_number" "$local_repo_path" "$worktree_path"

  create_issue_worktree "$local_repo_path" "$worktree_path" "$branch_name" "$default_branch"
  gh_issue_comment "$repo_slug" "$issue_number" "Starting autonomous implementation run for this issue. I will post an update with results shortly."
  gh_issue_add_label "$repo_slug" "$issue_number" "in-progress"

  instructions_file="$(repo_get_instructions_file "$repo_slug")"
  forbidden_json="$(repo_get_forbidden_paths_json "$repo_slug")"
  test_command="$(repo_get_test_command "$repo_slug")"

  prompt_file="$(mktemp "${STATE_DIR}/issue-prompt-${issue_number}.XXXX.md")"
  agent_log="${LOG_DIR}/agent-issue-${repo_key}-${issue_number}-$(date -u +%Y%m%dT%H%M%SZ).log"

  build_issue_prompt_file \
    "$prompt_file" \
    "$repo_slug" \
    "$issue_number" \
    "$issue_title" \
    "$issue_url" \
    "$issue_body" \
    "$forbidden_json" \
    "$test_command" \
    "$instructions_file"

  local agent_exit=0
  set +e
  agent_run "$worktree_path" "$prompt_file" "$ISSUE_TIMEOUT_MINUTES" "$agent_log"
  agent_exit=$?
  set -e

  rm -f "$prompt_file"

  if [[ "$agent_exit" -ne 0 ]]; then
    local fail_msg="Autonomous implementation failed."
    if [[ "$agent_exit" -eq 124 ]]; then
      fail_msg="Autonomous implementation timed out after ${ISSUE_TIMEOUT_MINUTES} minutes."
    fi

    gh_issue_comment "$repo_slug" "$issue_number" "${fail_msg} Logs are available to maintainers on the runtime host."
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  local changed_files
  changed_files="$(list_changed_files "$worktree_path")"

  if [[ -z "$changed_files" ]]; then
    gh_issue_comment "$repo_slug" "$issue_number" "No actionable implementation changes were produced in this run."
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    if [[ "${UNASSIGN_ON_NOOP}" == "true" ]]; then
      gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    fi
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  local forbidden_touched
  forbidden_touched="$(forbidden_touches "$changed_files" "$forbidden_json" || true)"
  if [[ -n "$forbidden_touched" ]]; then
    gh_issue_comment "$repo_slug" "$issue_number" "$(cat <<EOF
Run skipped: forbidden paths were modified by the agent:

$(printf '%s\n' "$forbidden_touched" | sed 's/^/- /')
EOF
)"
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    git -C "$worktree_path" reset --hard >/dev/null
    git -C "$worktree_path" clean -fd >/dev/null
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  local test_status
  test_status="$(run_test_command_if_configured "$repo_slug" "$worktree_path")"
  if [[ "$test_status" == "failed" ]]; then
    gh_issue_comment "$repo_slug" "$issue_number" "Agent produced changes, but configured tests failed. No PR was opened."
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  git -C "$worktree_path" add -A
  if git -C "$worktree_path" diff --cached --quiet; then
    gh_issue_comment "$repo_slug" "$issue_number" "No committable changes remained after validation."
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  git -C "$worktree_path" commit -m "agent: address issue #${issue_number}" >/dev/null

  if [[ "$branch_name" == "$default_branch" ]]; then
    gh_issue_comment "$repo_slug" "$issue_number" "Safety check failed: computed branch equals default branch. Aborting push."
    gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
    gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"
    git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    issue_cleanup_deactivate
    return 0
  fi

  git -C "$worktree_path" push -u origin "$branch_name" >/dev/null

  local existing_pr_json existing_pr_url pr_url pr_number
  existing_pr_json="$(gh_find_open_pr_by_head "$repo_slug" "$branch_name")"
  existing_pr_url="$(jq -r '.[0].url // ""' <<<"$existing_pr_json")"

  if [[ -n "$existing_pr_url" ]]; then
    pr_url="$existing_pr_url"
    pr_number="$(jq -r '.[0].number' <<<"$existing_pr_json")"
  else
    local pr_title pr_body
    pr_title="${issue_title} (#${issue_number})"
    pr_body=$(cat <<PRBODY
Automated implementation for ${repo_slug}#${issue_number}.

- Branch: ${branch_name}
- Safety checks: passed
- Tests: ${test_status}

Closes #${issue_number}
PRBODY
)

    pr_url="$(gh_create_draft_pr "$repo_slug" "$branch_name" "$default_branch" "$pr_title" "$pr_body" | tail -n1)"
    pr_number="${pr_url##*/}"
  fi

  if [[ -n "$SYSTEM_PR_LABEL" ]]; then
    gh_pr_add_label "$repo_slug" "$pr_number" "$SYSTEM_PR_LABEL"
  fi

  gh_issue_comment "$repo_slug" "$issue_number" "Draft PR created: ${pr_url}"
  gh_issue_remove_label "$repo_slug" "$issue_number" "in-progress"
  gh_issue_add_label "$repo_slug" "$issue_number" "pr-created"
  gh_issue_unassign "$repo_slug" "$issue_number" "$AGENT_GITHUB_USERNAME"

  issue_cleanup_deactivate
  git -C "$local_repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
}

main() {
  log_info "Issue worker started"

  if [[ "$MAX_OPEN_AGENT_PRS" -gt 0 ]]; then
    local open_prs
    open_prs="$(count_open_agent_prs)"
    if [[ "$open_prs" -ge "$MAX_OPEN_AGENT_PRS" ]]; then
      log_info "Open agent PR limit reached (${open_prs}/${MAX_OPEN_AGENT_PRS}); skipping issue processing"
      exit 0
    fi
  fi

  local candidates
  candidates="$(collect_candidate_issues)"

  if [[ "$(jq 'length' <<<"$candidates")" -eq 0 ]]; then
    log_info "No eligible assigned issues found"
    exit 0
  fi

  local selected
  selected="$(jq -c '.[0]' <<<"$candidates")"
  process_issue "$selected"

  log_info "Issue worker finished"
}

main "$@"
