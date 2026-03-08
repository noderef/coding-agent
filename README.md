<div align="center">
<p>
  <img src="./assets/logo-center-black.svg#gh-light-mode-only" alt="coding-agent" width="280" />
  <img src="./assets/logo-center-white.svg#gh-dark-mode-only" alt="coding-agent" width="280" />

  <h3>Autonomous Coding Agent</h3>
</p>

<p>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/License-Apache%202.0-blue" alt="License: Apache-2.0" />
  </a>
  <img src="https://img.shields.io/badge/Runtime-Linux%20%2B%20Cron-2ea44f" alt="Linux + Cron" />
  <img src="https://img.shields.io/badge/Stack-Bash%20%2B%20gh%20%2B%20jq-1f6feb" alt="Bash + gh + jq" />
</p>
</div>

## What does the Agent?

- Polls assigned GitHub issues in configured repos.
- Creates per-issue branch/worktree and runs an autonomous coding agent.
- Validates safety constraints and optional tests.
- Commits, pushes, and opens draft PRs.
- Handles PR feedback via `@bot` mentions.
- Tracks processed feedback comments in JSON state.

## Design goals

- Production-lean, simple runtime.
- Filesystem + shell scripts only.
- No web app, no DB, no queue, no docker runtime dependency.
- Human-in-the-loop communication only in GitHub comments.

## Quick start

```bash
git clone <your-orchestration-repo-url> coding-agent
cd coding-agent
./install.sh
```

Then:

1. Edit `.env`.
2. Run `gh auth login`.
3. Configure `configs/repos.json`.
4. Run `./bin/doctor`.
5. Run once manually:
   - `./agents/issue-worker.sh`
   - `./agents/feedback-worker.sh`

## Install deps (`install.sh`)

Default behavior:
- Installs system deps (`git`, `jq`, `gh`, `flock`, `curl`, `cron`, and a supported Node.js runtime with npm).
- On apt-based systems, removes conflicting distro `npm` packages and upgrades/install Node.js 22 automatically if the distro default is older than Node 20.
- Creates `.env` from `.env.example` if missing.
- Installs Cline CLI with `npm install -g cline`.
- Installs/updates cron entries for both workers.

Optional overrides:

```bash
CLINE_VERSION=latest ./install.sh
INSTALL_CRON=false ./install.sh
```

## Runtime Flow

### Issue Worker

1. Finds oldest open issue assigned to `AGENT_GITHUB_USERNAME` in enabled repos.
2. Comments start + adds `in-progress` (best effort).
3. Syncs local repo checkout.
4. Creates branch/worktree.
5. Runs agent prompt.
6. Blocks forbidden file changes.
7. Runs configured test command (if set).
8. On success: commit, push, create draft PR, comment issue, update labels, unassign bot.
9. On no-op/failure/timeout: comment issue and exit safely.

### Feedback Worker

1. Finds open bot PRs in enabled repos.
2. Scans issue comments + review comments.
3. Filters comments that:
   - mention `@bot`
   - are by allowed users
   - are not already processed
4. Runs targeted patch on PR head branch worktree.
5. Validates forbidden files + tests.
6. Pushes follow-up commit and comments on PR.
7. Marks comment processed in state JSON (even on no-op/failure).

## Configuration

### `.env` (important vars)

- `AGENT_GITHUB_USERNAME`
- `AUTHORIZED_USERS`
- `AGENT_BACKEND=cline`
- `AGENT_CMD` (`cline` is the portable default; avoid hardcoding `/usr/local/bin/cline`)
- `AGENT_MODEL`
- `AGENT_BASE_URL`
- `AGENT_API_KEY`
- `PROJECTS_DIR`, `RUNTIME_DIR`, `STATE_DIR`, `LOG_DIR`
- `ISSUE_TIMEOUT_MINUTES`, `FEEDBACK_TIMEOUT_MINUTES`
- `MIN_AVAILABLE_MB`, `MAX_OPEN_AGENT_PRS`, `DAILY_FEEDBACK_LIMIT`
- `CONFIG_FILE`

Path behavior:
- `PROJECTS_DIR` = persistent repo clones (`owner/repo`).
- `RUNTIME_DIR/worktrees` = temporary working directories where agent edits/commits happen.
- Both must be outside this orchestration repository (enforced by workers/doctor).

### `configs/repos.json`

Per repo:
- `slug`
- `enabled`
- `local_path`
- `instructions_file` (optional)
- `test_command` (optional)
- `forbidden_paths` (optional)

Only `enabled: true` repos are processed.

## Issue Templates

This repo uses two Markdown issue templates:
- `.github/ISSUE_TEMPLATE/bug.md`
- `.github/ISSUE_TEMPLATE/feature.md`

For agent quality, the fields that matter most are:
- `Acceptance criteria`
- `Out of scope`
- `Constraints`
- `Test plan`

If those four fields are weak, the agent will usually compensate by making broader assumptions than you want.

## Safety Defaults

- Never push default branch.
- Never auto-merge PRs.
- Shared `flock` lock to avoid concurrent repo mutations.
- Global forbidden paths include `.env` and secret-like paths.
- Per-repo forbidden paths enforced before commit/push.
- Worker operations are owned by shell scripts (not LLM free-form behavior).

## Operations cheat sheet

Logs:
- `logs/issue-worker-YYYY-MM-DD.log`
- `logs/feedback-worker-YYYY-MM-DD.log`
- `logs/cron-issue.log`
- `logs/cron-feedback.log`

State:
- `state/processed-feedback.json`
- `state/worker.lock`

Recover stale worktree:

```bash
cd <repo-local-path>
git worktree list
git worktree remove --force <stale-worktree-path>
```

Disable repo quickly:
- Set `"enabled": false` in `configs/repos.json`.

Reprocess one feedback comment:

```bash
jq 'del(.processed["owner/repo#123#issue_comment#456789"])' state/processed-feedback.json > /tmp/processed.json
mv /tmp/processed.json state/processed-feedback.json
```

## Failure modes (Short)

- Auth failure (`gh`): run `gh auth login`.
- Rate limit/API errors: worker skips this cycle, cron retries.
- Clone/fetch/worktree conflict: task fails safely and logs details.
- No code changes: worker posts no-op comment.
- Forbidden files touched: patch blocked.
- Timeout/tests failed: no push, status comment posted.

## License

Apache License 2.0. See [LICENSE](./LICENSE).
