#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

log() {
  printf '[install] %s\n' "$*"
}

die() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return 0
  fi

  die "This step requires root privileges. Run as root or install sudo."
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "apt"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    printf '%s\n' "dnf"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    printf '%s\n' "yum"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' "pacman"
    return 0
  fi

  die "Unsupported Linux distribution. Install git, jq, gh, flock(util-linux), curl manually."
}

install_system_packages() {
  local pm="$1"

  case "$pm" in
    apt)
      as_root apt-get update
      as_root apt-get install -y git jq curl ca-certificates util-linux gh cron gnupg
      ;;
    dnf)
      as_root dnf install -y git jq curl ca-certificates util-linux gh cronie nodejs npm
      ;;
    yum)
      as_root yum install -y git jq curl ca-certificates util-linux gh cronie nodejs npm
      ;;
    pacman)
      as_root pacman -Sy --noconfirm git jq curl ca-certificates util-linux github-cli cronie nodejs npm
      ;;
    *)
      die "Unknown package manager: $pm"
      ;;
  esac
}

command_exists() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

expand_path() {
  local value="$1"
  case "$value" in
    ~) printf '%s\n' "$HOME" ;;
    ~/*) printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    /*) printf '%s\n' "$value" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$value" ;;
  esac
}

resolve_agent_cmd_basename() {
  local cmd_value="${AGENT_CMD:-cline}"
  if [[ "$cmd_value" == */* ]]; then
    basename "$cmd_value"
  else
    printf '%s\n' "$cmd_value"
  fi
}

agent_cmd_available() {
  local cmd_value="${AGENT_CMD:-cline}"

  if [[ "$cmd_value" == */* ]]; then
    [[ -x "$cmd_value" ]]
    return $?
  fi

  command_exists "$cmd_value"
}

install_agent_via_download_url() {
  local url="${AGENT_DOWNLOAD_URL:-}"
  [[ -n "$url" ]] || return 1

  local tmp
  tmp="$(mktemp /tmp/coding-agent-cli.XXXXXX)"

  log "Downloading agent CLI from AGENT_DOWNLOAD_URL"
  curl -fL "$url" -o "$tmp"

  local target
  if [[ "${AGENT_CMD:-}" == */* ]]; then
    target="${AGENT_CMD}"
  else
    target="/usr/local/bin/${AGENT_CMD:-cline}"
  fi

  as_root install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
}

node_major_version() {
  node --version | sed -E 's/^v([0-9]+).*/\1/'
}

cleanup_conflicting_apt_node_packages() {
  local remove_pkgs=()
  local pkg

  for pkg in npm nodejs-doc libnode-dev; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      remove_pkgs+=("$pkg")
    fi
  done

  if [[ "${#remove_pkgs[@]}" -gt 0 ]]; then
    log "Removing conflicting Debian/Ubuntu Node packages: ${remove_pkgs[*]}"
    as_root apt-get remove -y "${remove_pkgs[@]}"
  fi
}

install_nodesource_node_apt() {
  local tmp
  tmp="$(mktemp /tmp/nodesource-setup.XXXXXX)"

  cleanup_conflicting_apt_node_packages

  log "Installing Node.js 22 from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_22.x" -o "$tmp"
  as_root bash "$tmp"
  rm -f "$tmp"

  as_root apt-get install -y nodejs
}

ensure_supported_node_runtime() {
  local pm="$1"

  if command_exists node && command_exists npm; then
    local major
    major="$(node_major_version)"
    if [[ -n "$major" ]] && (( major >= 20 )); then
      return 0
    fi
  fi

  case "$pm" in
    apt)
      install_nodesource_node_apt
      ;;
    *)
      if ! command_exists node || ! command_exists npm; then
        die "Node.js 20+ and npm are required, but automatic installation is only configured for apt-based systems."
      fi
      ;;
  esac
}

ensure_node_version() {
  if ! command_exists node; then
    die "Node.js is required for Cline CLI installation."
  fi

  local major
  major="$(node_major_version)"
  if [[ -z "$major" ]]; then
    die "Could not determine Node.js version."
  fi

  if (( major < 20 )); then
    die "Cline CLI requires Node.js >= 20. Detected v${major}. Please install Node.js 20+ (Node 22 recommended) and rerun install.sh."
  fi
}

install_agent_via_npm() {
  ensure_node_version

  local pkg="cline"
  if [[ -n "${CLINE_VERSION:-}" ]]; then
    pkg="cline@${CLINE_VERSION}"
  fi

  log "Installing Cline CLI via npm package: ${pkg}"
  as_root npm install -g "$pkg"
}

install_agent_cli() {
  if agent_cmd_available; then
    log "Agent CLI already available: ${AGENT_CMD:-cline}"
    return 0
  fi

  if [[ "${SKIP_AGENT_INSTALL:-false}" == "true" ]]; then
    die "Agent CLI is missing and SKIP_AGENT_INSTALL=true."
  fi

  if [[ -n "${AGENT_INSTALL_COMMAND:-}" ]]; then
    log "Installing agent CLI via AGENT_INSTALL_COMMAND"
    bash -lc "$AGENT_INSTALL_COMMAND"
  elif [[ -n "${AGENT_DOWNLOAD_URL:-}" ]]; then
    install_agent_via_download_url
  else
    install_agent_via_npm
  fi

  if ! agent_cmd_available; then
    die "Agent CLI still not found after installation: ${AGENT_CMD:-cline}"
  fi

  log "Agent CLI installed: $(resolve_agent_cmd_basename)"
}

ensure_env_file() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    return 0
  fi

  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  log "Created ${ROOT_DIR}/.env from .env.example"
  log "Edit .env with your bot username, API endpoint/key, and managed repos before starting cron"
}

reload_env_file() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

normalize_agent_cmd() {
  local cmd_value="${AGENT_CMD:-cline}"

  if [[ "$cmd_value" == */* && ! -x "$cmd_value" ]]; then
    local fallback
    fallback="$(basename "$cmd_value")"
    if command -v "$fallback" >/dev/null 2>&1; then
      log "AGENT_CMD path not found; using '$fallback' from PATH instead"
      AGENT_CMD="$fallback"
    fi
  fi
}

check_required_commands() {
  local missing=0
  local cmd
  for cmd in git jq gh flock curl node npm; do
    if ! command_exists "$cmd"; then
      printf '[install] missing command after install: %s\n' "$cmd" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    die "One or more required commands are still missing"
  fi
}

install_cron_entries() {
  if [[ "${INSTALL_CRON:-true}" != "true" ]]; then
    log "Skipping cron installation because INSTALL_CRON=${INSTALL_CRON}"
    return 0
  fi

  if ! command_exists crontab; then
    die "crontab command not found. Install cron package first."
  fi

  local run_dir log_dir
  run_dir="$ROOT_DIR"
  log_dir="$(expand_path "${LOG_DIR:-$ROOT_DIR/logs}")"
  mkdir -p "$log_dir"

  local feedback_line issue_line
  feedback_line="*/5 * * * * cd \"$run_dir\" && ./agents/feedback-worker.sh >> \"$log_dir/cron-feedback.log\" 2>&1 # coding-agent-feedback"
  issue_line="1-59/5 * * * * cd \"$run_dir\" && ./agents/issue-worker.sh >> \"$log_dir/cron-issue.log\" 2>&1 # coding-agent-issue"

  local current tmp
  current="$(crontab -l 2>/dev/null || true)"
  tmp="$(mktemp /tmp/coding-agent-cron.XXXXXX)"

  {
    printf '%s\n' "$current" | sed '/# coding-agent-feedback$/d; /# coding-agent-issue$/d'
    printf '%s\n' "$feedback_line"
    printf '%s\n' "$issue_line"
  } >"$tmp"

  crontab "$tmp"
  rm -f "$tmp"

  log "Installed/updated cron entries for issue and feedback workers"
}

main() {
  log "Installing coding-agent runtime dependencies"

  local pm
  pm="$(detect_pkg_manager)"
  log "Detected package manager: $pm"

  install_system_packages "$pm"
  ensure_supported_node_runtime "$pm"
  check_required_commands

  ensure_env_file
  reload_env_file
  normalize_agent_cmd
  install_agent_cli
  install_cron_entries

  log "Base installation complete"
  log "Next steps:"
  log "1) Edit .env"
  log "2) Run: gh auth login"
  log "3) Run: ./bin/doctor"
  log "4) Run workers once manually to validate first run"
}

main "$@"
