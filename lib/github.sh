#!/usr/bin/env bash

set -euo pipefail

gh_api_paginated_array() {
  local endpoint="$1"
  gh api --paginate "$endpoint" | jq -s 'add'
}

gh_repo_default_branch() {
  local repo_slug="$1"
  gh repo view "$repo_slug" --json defaultBranchRef --jq '.defaultBranchRef.name'
}

gh_clone_repo_if_missing() {
  local repo_slug="$1"
  local local_path="$2"

  if [[ -d "$local_path/.git" ]]; then
    return 0
  fi

  ensure_dir "$(dirname "$local_path")"
  gh repo clone "$repo_slug" "$local_path"
}

gh_list_assigned_open_issues() {
  local repo_slug="$1"
  local assignee="$2"
  local limit="${3:-100}"

  gh issue list \
    --repo "$repo_slug" \
    --assignee "$assignee" \
    --state open \
    --limit "$limit" \
    --json number,title,labels,createdAt,updatedAt,url,body,author
}

gh_issue_comment() {
  local repo_slug="$1"
  local issue_number="$2"
  local body="$3"
  gh issue comment "$issue_number" --repo "$repo_slug" --body "$body" >/dev/null
}

gh_issue_add_label() {
  local repo_slug="$1"
  local issue_number="$2"
  local label="$3"
  gh issue edit "$issue_number" --repo "$repo_slug" --add-label "$label" >/dev/null 2>&1 || return 0
}

gh_issue_remove_label() {
  local repo_slug="$1"
  local issue_number="$2"
  local label="$3"
  gh issue edit "$issue_number" --repo "$repo_slug" --remove-label "$label" >/dev/null 2>&1 || return 0
}

gh_issue_unassign() {
  local repo_slug="$1"
  local issue_number="$2"
  local assignee="$3"
  gh issue edit "$issue_number" --repo "$repo_slug" --remove-assignee "$assignee" >/dev/null 2>&1 || return 0
}

gh_find_open_pr_by_head() {
  local repo_slug="$1"
  local head_branch="$2"

  gh pr list \
    --repo "$repo_slug" \
    --state open \
    --head "$head_branch" \
    --limit 1 \
    --json number,url
}

gh_create_draft_pr() {
  local repo_slug="$1"
  local head_branch="$2"
  local base_branch="$3"
  local title="$4"
  local body="$5"

  gh pr create \
    --repo "$repo_slug" \
    --head "$head_branch" \
    --base "$base_branch" \
    --title "$title" \
    --body "$body" \
    --draft
}

gh_pr_add_label() {
  local repo_slug="$1"
  local pr_number="$2"
  local label="$3"
  gh pr edit "$pr_number" --repo "$repo_slug" --add-label "$label" >/dev/null 2>&1 || return 0
}

gh_pr_comment() {
  local repo_slug="$1"
  local pr_number="$2"
  local body="$3"
  gh pr comment "$pr_number" --repo "$repo_slug" --body "$body" >/dev/null
}

gh_list_open_prs() {
  local repo_slug="$1"
  local limit="${2:-100}"

  gh pr list \
    --repo "$repo_slug" \
    --state open \
    --limit "$limit" \
    --json number,title,body,url,headRefName,baseRefName,author,labels,createdAt
}

gh_pr_issue_comments() {
  local repo_slug="$1"
  local pr_number="$2"
  gh_api_paginated_array "/repos/${repo_slug}/issues/${pr_number}/comments?per_page=100"
}

gh_pr_review_comments() {
  local repo_slug="$1"
  local pr_number="$2"
  gh_api_paginated_array "/repos/${repo_slug}/pulls/${pr_number}/comments?per_page=100"
}

gh_pr_diff() {
  local repo_slug="$1"
  local pr_number="$2"
  gh pr diff "$pr_number" --repo "$repo_slug"
}
