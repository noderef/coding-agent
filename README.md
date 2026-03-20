<div align="center">
<p>
  <img src="./assets/logo-center-black.svg#gh-light-mode-only" alt="coding-agent" width="380" />
  <img src="./assets/logo-center-white.svg#gh-dark-mode-only" alt="coding-agent" width="380" />

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

## Introduction

An experiment in agentic coding, built to support [NodeRef](https://github.com/noderef/noderef). The agent picks up GitHub issues, writes code, and opens draft PRs on its own. It also responds to PR feedback through `@bot` mentions.

The stack is intentionally minimal: shell scripts, cron, and the filesystem. No database, no web framework, no Docker runtime. [LiteLLM](https://github.com/BerriAI/litellm) sits in front as an LLM proxy, so switching models is just a one-line change in `.env`.

## Quick start

```bash
git clone https://github.com/noderef/coding-agent.git
cd coding-agent
./install.sh
```

1. Edit `.env` (created from `.env.example` by the installer).
2. Run `gh auth login`.
3. Configure Cline auth:
   ```bash
   cline auth -p openai -k "$AGENT_API_KEY" -b "$AGENT_BASE_URL" -m "$AGENT_MODEL"
   ```
4. Add your repos to `configs/repos.json`.
5. Run `./bin/doctor` to verify everything.
6. Try it out:
   ```bash
   ./agents/issue-worker.sh
   ./agents/feedback-worker.sh
   ```

Cron entries are installed automatically by `install.sh` (disable with `INSTALL_CRON=false`).

## Doctor

Checks that all dependencies, auth, config, and runtime directories are in order.

```bash
./bin/doctor
```

## Log viewer

Web UI for tailing worker logs.

```bash
cd log-viewer && npm install && cd ..

./bin/log-viewer start
./bin/log-viewer stop
./bin/log-viewer status
```

Runs on `http://localhost:3000` by default. Change the port with `LOG_VIEWER_PORT` in `.env`.

## Configuration

All settings live in `.env`. The important ones:

| Variable | Purpose |
|---|---|
| `AGENT_GITHUB_USERNAME` | Bot's GitHub identity |
| `AUTHORIZED_USERS` | Who can trigger feedback via `@bot` |
| `AGENT_MODEL` | Which model to use |
| `AGENT_BASE_URL` / `AGENT_API_KEY` | LiteLLM endpoint credentials |
| `CONFIG_FILE` | Path to `configs/repos.json` |

Per-repo settings go in `configs/repos.json`: `slug`, `enabled`, `install_command`, `test_command`, `forbidden_paths`, and an optional `instructions_file`.

## License

Apache 2.0. See [LICENSE](./LICENSE).
