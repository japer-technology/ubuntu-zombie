#!/usr/bin/env bash
#
# install.sh
# ----------
# Ubuntu Zombie: baseline installer + chat service.
#
# Turn a normal Ubuntu Desktop LTS PC into a machine with a resident
# AI Systems Administrator, authenticated by the configured token
# provider, contactable through a private loopback chat UI.
#
# Read README.md before running.
#
# Subcommands:
#   install     Full install (default). Idempotent.
#   verify      Read-only state check (no mutation).
#   doctor      Explain what is wrong and likely fixes.
#   repair      Apply known-safe fixes for common drift.
#   uninstall   Delegate to uninstall.sh.
#
# Common env vars (run `install.sh --help` for the full list):
#   ZOMBIE_NONINTERACTIVE=1     skip prompts for fully unattended installs.
#   ZOMBIE_USER="zombie"        name of the local account created as the
#                               operating identity of the AI Systems
#                               Administrator. Defaults to `zombie`. The
#                               legacy name `AGENT_USER` is still
#                               accepted for backward compatibility.
#   ZOMBIE_CHAT_PORT=7878       loopback-only chat UI port.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="install.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# Repository root is one level above scripts/. The installer reads VERSION and
# the payload from the repo root so it can be invoked from anywhere.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

# Shared UX helpers (colours, status vocabulary, retry, timing, spinner,
# prompt loops). Sourced so install.sh, uninstall.sh, and build-deb.sh
# present an identical look and behaviour.
# shellcheck source=scripts/lib.sh
if [[ -r "${SCRIPT_DIR}/lib.sh" ]]; then
  . "${SCRIPT_DIR}/lib.sh"
else
  printf 'install.sh: required library %s/lib.sh not found.\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

if [[ -f "${REPO_ROOT}/VERSION" ]]; then
  SCRIPT_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
else
  SCRIPT_VERSION="0000.00.00.00.00.00"
fi
readonly SCRIPT_VERSION

AGENT_USER="${ZOMBIE_USER:-${AGENT_USER:-zombie}}"
AGENT_HOME="/home/${AGENT_USER}"
ZOMBIE_DIR="${ZOMBIE_DIR:-/opt/ai-zombie}"
ZOMBIE_ETC="/etc/ubuntu-zombie"
ZOMBIE_LOG_DIR="/var/log/ubuntu-zombie"
CHAT_PORT="${ZOMBIE_CHAT_PORT:-7878}"
LOG_FILE="${LOG_FILE:-/var/log/ubuntu-zombie-install.log}"

# Install receipt: a human-readable record of every parameter, written once
# when the install starts and finalised with the outcome when it finishes.
# Set ZOMBIE_RECEIPT=0 to disable, or point ZOMBIE_RECEIPT_FILE elsewhere.
ZOMBIE_RECEIPT="${ZOMBIE_RECEIPT:-1}"
RECEIPT_FILE="${ZOMBIE_RECEIPT_FILE:-${ZOMBIE_LOG_DIR}/install-receipt.txt}"

ZOMBIE_NONINTERACTIVE="${ZOMBIE_NONINTERACTIVE:-0}"

# Ubuntu Zombie chat-UI password gate and Time-to-Live (TTL) kill switch.
# The chat service is reachable by every local user on http://127.0.0.1:PORT,
# so it is protected by a shared password (only a PBKDF2 hash is stored in
# secrets/env). The TTL bounds the lifetime of the root-capable agent: once
# it elapses (or the operator runs `/ttl --die`) the zombie is permanently
# disabled until the next reinstall.
ZOMBIE_ADMIN_PASSWORD_DEFAULT="braaaains"
ADMIN_PASSWORD="${ZOMBIE_ADMIN_PASSWORD:-}"
# 1 once the operator has explicitly chosen a password (env or prompt), so a
# re-install does not silently overwrite a customised password with the default.
ADMIN_PASSWORD_SET=0
[[ -n "${ADMIN_PASSWORD}" ]] && ADMIN_PASSWORD_SET=1
TTL_DAYS="${ZOMBIE_TTL_DAYS:-7}"

# Local LLM discovery. During an interactive install the script can scan the
# host's IPv4 /24 (all 256 addresses) for an OpenAI-compatible local LLM
# server — LM Studio, Ollama, llama.cpp, etc. — answering on
# http://<ip>:PORT/v1 and offer the models it advertises as the starting
# model. Set ZOMBIE_SKIP_LLM_SCAN=1 to skip the scan, ZOMBIE_LLM_SCAN_PORT to
# probe a different port (default 1234, LM Studio's default), and
# ZOMBIE_LOCAL_LLM_API_KEY to record a non-default key for the local server
# (most ignore it).
ZOMBIE_SKIP_LLM_SCAN="${ZOMBIE_SKIP_LLM_SCAN:-0}"
ZOMBIE_LLM_SCAN_PORT="${ZOMBIE_LLM_SCAN_PORT:-1234}"
ZOMBIE_LOCAL_LLM_API_KEY="${ZOMBIE_LOCAL_LLM_API_KEY:-local}"
# Selection populated by discover_local_llms (empty when none is chosen).
LOCAL_LLM_ENDPOINT=""
LOCAL_LLM_BASE_URL=""
LOCAL_LLM_MODEL=""

# ---------------------------------------------------------------------------
# Optional components ("Ubuntu Zombie + Options")
# ---------------------------------------------------------------------------
# Every opt-in component is governed by a ZOMBIE_INSTALL_<COMPONENT> flag
# that defaults to 0, so the baseline install is unchanged unless the
# operator explicitly opts in. Each component follows the same contract:
# validated settings, an entry in the interactive Options menu (item 9 of
# the parameter review), a dry-run stanza, guarded idempotent install
# sections, receipt records, verify/doctor/repair checks, and a reversal
# path in uninstall.sh. Forgejo is the first component; more will follow.
#
# Forgejo: a self-hosted git forge backed by PostgreSQL, listening on the
# normal network interfaces (this is a service for people on the LAN, not
# a loopback-only agent surface). Optionally a Forgejo Actions runner is
# co-located on the same host using the standard Docker-based executor.
ZOMBIE_INSTALL_FORGEJO="${ZOMBIE_INSTALL_FORGEJO:-0}"
ZOMBIE_INSTALL_FORGEJO_RUNNER="${ZOMBIE_INSTALL_FORGEJO_RUNNER:-0}"
FORGEJO_HTTP_PORT="${FORGEJO_HTTP_PORT:-3000}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-forgejo-admin}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-forgejo-admin@localhost.localdomain}"
FORGEJO_DB_NAME="${FORGEJO_DB_NAME:-forgejo}"
FORGEJO_DB_USER="${FORGEJO_DB_USER:-forgejo}"
# Passwords are options like everything else: leave them empty and the
# installer generates them randomly and records the generated values in the
# root-only install receipt; set them and the operator's values are used and
# never recorded anywhere.
FORGEJO_ADMIN_PASSWORD="${FORGEJO_ADMIN_PASSWORD:-}"
FORGEJO_DB_PASSWORD="${FORGEJO_DB_PASSWORD:-}"
# Where each password came from this run: "operator" (env/prompt),
# "generated" (random, recorded in the receipt), "existing" (reused from
# the host, e.g. app.ini), or "" (not touched, e.g. admin already exists).
FORGEJO_ADMIN_PASSWORD_SOURCE=""
FORGEJO_DB_PASSWORD_SOURCE=""
[[ -n "${FORGEJO_ADMIN_PASSWORD}" ]] && FORGEJO_ADMIN_PASSWORD_SOURCE="operator"
[[ -n "${FORGEJO_DB_PASSWORD}" ]] && FORGEJO_DB_PASSWORD_SOURCE="operator"
FORGEJO_VERSION="${FORGEJO_VERSION:-}"
FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-}"
FORGEJO_RUNNER_LABELS="${FORGEJO_RUNNER_LABELS:-ubuntu-latest:docker://node:20-bookworm}"
# Populated at install time once the release tag is resolved.
FORGEJO_RESOLVED_VERSION=""

# True when at least one optional component is enabled — used to keep the
# default dry-run/receipt/banner output byte-for-byte unchanged otherwise.
any_option_enabled() {
  [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]
}

# One-line label for where an optional-component password will come from,
# shared by the dry-run stanza, options table, and receipt start record.
password_source_label() {
  [[ -n "$1" ]] && echo 'set via env' || echo 'generated, recorded in receipt'
}

# UX flags (set by argument parsing below; env provides the defaults).
#   ASSUME_YES   skip the interactive "Type YES" confirmation but keep
#                interactive prompts for any still-missing inputs.
#   STRICT       treat preflight warnings as fatal.
#   JSON_OUTPUT  emit machine-readable JSON from verify/doctor.
#   VERBOSE      enable xtrace into the transcript.
ASSUME_YES="${ZOMBIE_ASSUME_YES:-0}"
STRICT="${ZOMBIE_STRICT:-0}"
JSON_OUTPUT=0
VERBOSE="${ZOMBIE_VERBOSE:-0}"
# Set to 1 once the operator has reviewed (and possibly edited) the install
# parameters interactively, so the later confirmation gate is not asked twice.
REVIEWED=0

# Idempotency transparency: count how many idempotent steps were already in
# place versus newly applied, so a re-run does not look like a fresh install.
STEPS_SATISFIED=0
STEPS_CHANGED=0
note_satisfied() { STEPS_SATISFIED=$((STEPS_SATISFIED + 1)); }
note_changed()   { STEPS_CHANGED=$((STEPS_CHANGED + 1)); }

PAYLOAD_DIR="${PAYLOAD_DIR:-${REPO_ROOT}/payload}"

# Pinned versions of the Node bridges, read from their single source of
# truth (the *.version files deployed alongside the agent). They are
# embedded into the generated verify script and used by the install-time
# pin checks, so define them up front to avoid unbound-variable aborts
# under `set -u`. Fall back to "unknown" if a file is somehow missing so
# the installer degrades gracefully instead of crashing.
read_pinned_version() {
  local file="$1"
  if [[ -r "${file}" ]]; then
    tr -d '[:space:]' < "${file}"
  else
    printf 'unknown'
  fi
}
PI_AI_VERSION="$(read_pinned_version "${PAYLOAD_DIR}/agent/pi-ai.version")"
PI_MONO_VERSION="$(read_pinned_version "${PAYLOAD_DIR}/agent/pi-mono.version")"
readonly PI_AI_VERSION PI_MONO_VERSION

# Exit codes:
#   0  ok
#   1  generic failure
#   2  bad usage
#   64 missing required environment (non-interactive)
#   65 incompatible host
#   66 network preflight failure

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
#
# The colour/TTY logic and the log/info/warn/ok/die/section/status/retry/
# run_step/prompt_until_valid helpers all live in scripts/lib.sh, sourced
# above, so every script in the suite shares one vocabulary.

# diagnose_failure <exit_code> — map a few common failure signatures onto a
# single targeted, copy-pasteable hint. Best-effort: every probe is guarded
# so this never itself aborts the error handler.
diagnose_failure() {
  local code="${1:-1}"
  case "${code}" in
    66) printf '    Likely cause: network/DNS preflight. Check connectivity and re-run.\n' >&2; return ;;
    64) printf '    Likely cause: missing required environment for non-interactive mode (see hints above).\n' >&2; return ;;
    65) printf '    Likely cause: unsupported host (need Ubuntu 22.04/24.04 LTS on amd64/arm64).\n' >&2; return ;;
  esac
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
    printf '    Likely cause: apt/dpkg is locked by another process (e.g. unattended-upgrades).\n' >&2
    printf '    Fix: wait for it to finish, then re-run the installer (it is idempotent).\n' >&2
    return
  fi
  local avail_kb
  avail_kb="$(df -P / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "${avail_kb:-}" && "${avail_kb}" -lt 1000000 ]]; then
    printf '    Likely cause: the root filesystem is nearly full (%s MB free).\n' "$((avail_kb/1024))" >&2
    printf '    Fix: free up space (e.g. `sudo apt-get clean`) and re-run.\n' >&2
    return
  fi
  if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 \
     && ! getent hosts deb.debian.org >/dev/null 2>&1; then
    printf '    Likely cause: DNS resolution looks broken (cannot resolve archive.ubuntu.com).\n' >&2
    printf '    Fix: check /etc/resolv.conf and outbound connectivity, then re-run.\n' >&2
    return
  fi
}

on_error() {
  local exit_code=$?
  local line=$1
  printf '\n%s[x] %s failed on line %s with exit code %s.%s\n' \
    "${C_RED}" "${SCRIPT_NAME}" "${line}" "${exit_code}" "${C_RESET}" >&2
  printf '%s    Full transcript: %s%s\n' "${C_RED}" "${LOG_FILE}" "${C_RESET}" >&2
  diagnose_failure "${exit_code}" || true
  printf '%s    Exit codes: 1 generic · 2 usage · 64 missing env · 65 bad host · 66 network.%s\n' \
    "${C_RED}" "${C_RESET}" >&2
  exit "${exit_code}"
}


# Public component targets accepted after the lifecycle verb. Keep this list
# in sync with the static shell completions and smoke standards.
readonly COMPONENT_ZOMBIE="zombie"
readonly COMPONENT_FORGEJO="forgejo"
readonly PUBLIC_COMPONENTS=("${COMPONENT_ZOMBIE}" "${COMPONENT_FORGEJO}")
TARGET_ARGS=()
SELECTED_COMPONENTS=()
EXPLICIT_TARGETS=0
COMPONENT_ZOMBIE_SELECTED=0
COMPONENT_FORGEJO_SELECTED=0

component_names() {
  printf '%s' "${PUBLIC_COMPONENTS[*]}"
}

is_lifecycle_verb() {
  case "$1" in
    install|verify|doctor|repair|uninstall) return 0 ;;
    *) return 1 ;;
  esac
}

is_public_component() {
  local candidate="$1" component
  for component in "${PUBLIC_COMPONENTS[@]}"; do
    [[ "${candidate}" == "${component}" ]] && return 0
  done
  return 1
}

is_selected_component() {
  local candidate="$1" component
  for component in "${SELECTED_COMPONENTS[@]}"; do
    [[ "${candidate}" == "${component}" ]] && return 0
  done
  return 1
}

add_selected_component() {
  local component="$1"
  is_selected_component "${component}" || SELECTED_COMPONENTS+=("${component}")
}

validate_and_resolve_targets() {
  local target
  declare -A seen_targets=()
  for target in "${TARGET_ARGS[@]}"; do
    if is_lifecycle_verb "${target}"; then
      die "Lifecycle verb cannot be used as a component target after ${SUBCOMMAND}: ${target}" 2
    fi
    if ! is_public_component "${target}"; then
      die "Unknown component target '${target}'. Valid components: $(component_names)" 2
    fi
    if [[ -n "${seen_targets[${target}]+x}" ]]; then
      die "Duplicate component target '${target}'." 2
    fi
    seen_targets["${target}"]=1
    SELECTED_COMPONENTS+=("${target}")
  done

  (( ${#TARGET_ARGS[@]} > 0 )) && EXPLICIT_TARGETS=1

  if (( ! EXPLICIT_TARGETS )) && [[ "${SUBCOMMAND}" == "install" ]]; then
    add_selected_component "${COMPONENT_ZOMBIE}"
  fi

  if forgejo_config_selected; then
    add_selected_component "${COMPONENT_FORGEJO}"
  fi

  for target in "${SELECTED_COMPONENTS[@]}"; do
    case "${target}" in
      "${COMPONENT_ZOMBIE}") COMPONENT_ZOMBIE_SELECTED=1 ;;
      "${COMPONENT_FORGEJO}") COMPONENT_FORGEJO_SELECTED=1; ZOMBIE_INSTALL_FORGEJO=1 ;;
    esac
  done
}

zombie_config_selected() {
  (( COMPONENT_ZOMBIE_SELECTED )) && return 0
  (( EXPLICIT_TARGETS )) && return 1
  # This is validation fallback only. Target selection for install happens in
  # validate_and_resolve_targets(); no-target non-install verbs keep the legacy
  # zombie-centric validation path until the component manifest lands. No-target
  # uninstall delegates to uninstall.sh.
  [[ "${SUBCOMMAND}" != "uninstall" ]]
}

forgejo_config_selected() {
  (( COMPONENT_FORGEJO_SELECTED )) && return 0
  [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]
}

selected_components_label() {
  if (( ${#SELECTED_COMPONENTS[@]} == 0 )); then
    case "${SUBCOMMAND}" in
      uninstall) printf 'all managed artefacts (compatibility mode)' ;;
      *) printf 'installed components (manifest discovery pending)' ;;
    esac
  else
    printf '%s' "${SELECTED_COMPONENTS[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Ubuntu Zombie baseline installer + AI Systems Administrator chat service.

Usage:
  sudo ./${SCRIPT_NAME} [VERB] [COMPONENT ...] [FLAGS]

Verbs:
  install     Full install (default). With no component target, installs the
              zombie baseline. Interactive runs open an editable parameter
              review before any change is made.
  verify      Read-only state check. Does not change state.
  doctor      Explain failures and likely fixes.
  repair      Apply known-safe fixes (re-assert permissions, restart
              the chat service).
  uninstall   Reverse the install (delegates to uninstall.sh). With no target,
              keeps the current all-managed-artefacts behaviour.

Components:
  zombie      The Ubuntu Zombie account, runtime, chat UI, policy, and services.
  forgejo     Forgejo + PostgreSQL option. The component target is accepted for
              parser/dry-run compatibility; standalone non-dry-run Forgejo
              install remains gated until the component extraction phase lands.

Selection rules:
  install with no component target selects zombie. Explicit targets select
  exactly those components, plus any enabled legacy ZOMBIE_INSTALL_* options.
  verify/doctor/repair targets are accepted now; no-target discovery falls back
  to current legacy checks until the component manifest lands.

Flags:
  Behaviour
    -n, --dry-run     Print the plan without touching the host.
                      Meaningful with 'install' and 'uninstall'.
    -y, --yes         Skip the "Type YES" confirmation. Still prompts for
                      any missing inputs (use ZOMBIE_NONINTERACTIVE=1 to
                      skip every prompt for fully unattended installs).
        --strict      Treat preflight warnings as fatal.
  Uninstall only
        --archive     Archive /opt/ai-zombie before removing it.
        --keep-agent  Do not remove the agent user account.
  Output
    -q, --quiet       Only show warnings and errors.
        --verbose,
        --debug       Write shell xtrace to the transcript for debugging.
        --no-color    Disable ANSI colour (NO_COLOR is also honoured).
        --json        Machine-readable JSON output (verify, doctor only).
  Other
    -h, --help        Show this help and exit.
    -v, --version     Print the version and exit.

Environment variables (selected; see docs/CONFIGURATION.md for all):
  ZOMBIE_NONINTERACTIVE=1     skip prompts for fully unattended installs.
  ZOMBIE_USER=<name>          name of the local agent account (default
                              'zombie'). Must be set on every later
                              install/verify/doctor/repair/uninstall
                              run that targets a non-default account.
  ZOMBIE_COLOR=auto|always|never   colour policy (default auto). The setup
                              UI uses the Zombie Orchid highlight (#AC43D9)
                              and compatible accents when colour is enabled.
  ZOMBIE_RECEIPT=0            disable the start/finish install receipt
                              (written by default).
  ZOMBIE_RECEIPT_FILE=<path>  override the receipt path (default
                              /var/log/ubuntu-zombie/install-receipt.txt).
  ZOMBIE_SKIP_LLM_SCAN=1     skip the interactive LAN scan that looks for an
                              OpenAI-compatible local LLM server and offers
                              its models as the starting model.
  ZOMBIE_LLM_SCAN_PORT=<n>    port probed for the local LLM scan (default
                              1234, LM Studio's default).
  ZOMBIE_LOCAL_LLM_API_KEY=<k>  API key recorded for the discovered local LLM
                              (default 'local'; most local servers ignore it).
  ZOMBIE_ADMIN_PASSWORD       Chat-UI password gate (default 'braaaains';
                              only a hash is stored).
  ZOMBIE_TTL_DAYS=<n>         Time to Live in days before the zombie is
                              permanently disabled (default 7).

Optional components (all default 0 / off; see options/ for the roadmap):
  ZOMBIE_INSTALL_FORGEJO=1    also install a self-hosted Forgejo git forge
                              backed by PostgreSQL, reachable on the normal
                              network interfaces (port 3000 by default).
  ZOMBIE_INSTALL_FORGEJO_RUNNER=1  also install a Forgejo Actions runner on
                              the same host (standard Docker executor).
                              Requires ZOMBIE_INSTALL_FORGEJO=1.
  FORGEJO_HTTP_PORT=<n>       Forgejo web/API port (default 3000).
  FORGEJO_ADMIN_USER=<name>   initial admin account (default forgejo-admin).
  FORGEJO_ADMIN_EMAIL=<addr>  admin email (default forgejo-admin@localhost.localdomain).
  FORGEJO_ADMIN_PASSWORD=<p>  initial admin password (default: randomly
                              generated and recorded in the install receipt).
  FORGEJO_DB_NAME=<name>      PostgreSQL database (default forgejo).
  FORGEJO_DB_USER=<name>      PostgreSQL role (default forgejo).
  FORGEJO_DB_PASSWORD=<p>     PostgreSQL role password (default: randomly
                              generated and recorded in the install receipt).
  FORGEJO_VERSION=<x.y.z>     pin the Forgejo release (default: latest).
  FORGEJO_RUNNER_VERSION=<x.y.z>  pin the runner release (default: latest).
  FORGEJO_RUNNER_LABELS=<labels>  runner labels (default
                              ubuntu-latest:docker://node:20-bookworm).

Examples:
  # Preview the plan before granting anything:
  sudo ./${SCRIPT_NAME} install --dry-run

  # Minimal interactive install:
  sudo ./${SCRIPT_NAME} install

  # Attended, but skip the YES gate:
  sudo ./${SCRIPT_NAME} install --yes

  # Fully unattended (CI / cloud-init):
  sudo ZOMBIE_NONINTERACTIVE=1 ./${SCRIPT_NAME} install

  # Canonical component form for the baseline:
  sudo ./${SCRIPT_NAME} install zombie

  # Baseline plus a Forgejo forge with a co-located Actions runner
  # (environment flags remain supported for automation):
  sudo ZOMBIE_INSTALL_FORGEJO=1 ZOMBIE_INSTALL_FORGEJO_RUNNER=1 \\
    ./${SCRIPT_NAME} install

  # Equivalent component-target preview for the combined install:
  sudo ./${SCRIPT_NAME} install zombie forgejo --dry-run

  # Accepted syntax for standalone Forgejo planning; the non-dry-run
  # standalone install is gated until component extraction is complete:
  ./${SCRIPT_NAME} install forgejo --dry-run

  # Machine-readable health for monitoring:
  ./${SCRIPT_NAME} verify --json

Shell completion:
  Bash:  source scripts/completions/install.bash
  Zsh:   add scripts/completions/ to \$fpath, then: autoload -U compinit && compinit

See README.md, docs/QUICKSTART.md, and SECURITY.md.
EOF
}

SUBCOMMAND="install"
SUBCOMMAND_SEEN=0
DRY_RUN=0
UNINSTALL_ARCHIVE=0
UNINSTALL_KEEP_AGENT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -q|--quiet)   ZOMBIE_QUIET=1; shift ;;
    --verbose|--debug) VERBOSE=1; shift ;;
    --no-color|--no-colour) export ZOMBIE_COLOR=never; lib_setup_colors; shift ;;
    --strict)     STRICT=1; shift ;;
    --json)       JSON_OUTPUT=1; shift ;;
    --archive)    UNINSTALL_ARCHIVE=1; shift ;;
    --keep-agent) UNINSTALL_KEEP_AGENT=1; shift ;;
    install|verify|doctor|repair|uninstall)
                  if (( SUBCOMMAND_SEEN )); then
                    die "Unexpected lifecycle verb after ${SUBCOMMAND}: $1" 2
                  fi
                  SUBCOMMAND="$1"; SUBCOMMAND_SEEN=1; shift ;;
    --) shift; TARGET_ARGS+=("$@"); break ;;
    -*) die "Unknown flag: $1 (try --help)" 2 ;;
    *)  TARGET_ARGS+=("$1"); shift ;;
  esac
done
readonly DRY_RUN
validate_and_resolve_targets

if [[ "${SUBCOMMAND}" == "install" ]] && ! (( ZOMBIE_QUIET )); then
  brand_splash "install" "${SCRIPT_VERSION}"
fi

# ---------------------------------------------------------------------------
# Helpers shared across subcommands
# ---------------------------------------------------------------------------

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./${SCRIPT_NAME} ${SUBCOMMAND}" 2
}

# `retry` (exponential backoff) is provided by scripts/lib.sh.

wait_for_apt_lock() {
  local waited=0 max=300
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock     >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock          >/dev/null 2>&1; do
    if (( waited >= max )); then
      warn "Timed out waiting ${max}s for apt/dpkg lock."
      return 1
    fi
    info "Waiting for apt/dpkg lock (${waited}s/${max}s)..."
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

_apt_get_once() {
  # Re-check the dpkg lock before *every* attempt so unattended-upgrades
  # waking up between retries does not cause spurious failures. See
  # FIX-2-07.
  wait_for_apt_lock || true
  env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

apt_get() {
  retry 4 5 -- _apt_get_once "$@"
}

apt_install() {
  apt_get install -y "$@"
}

curl_get() {
  retry 5 3 -- curl -fsSL --retry 3 --retry-delay 2 "$@"
}

is_supported_agent_username() {
  # Either 2-32 chars starting with a letter and ending alphanumeric, with
  # underscore/hyphen allowed in the middle, or 1-32 alphanumeric chars.
  [[ "$1" =~ ^[a-z]([a-z0-9_-]{0,30}[a-z0-9]|[a-z0-9]{0,31})$ ]] || return 1
  [[ "$1" != "root" && "$1" != "nobody" ]]
}

is_safe_absolute_path() {
  [[ "$1" == /* ]] || return 1
  [[ "$1" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
}

is_valid_tcp_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( "$1" >= 1 && "$1" <= 65535 ))
}

# A Time-to-Live in whole days: a positive integer from 1 to 36500
# (a century is plenty; the upper bound keeps the expiry timestamp sane).
is_valid_ttl_days() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( "$1" >= 1 && "$1" <= 36500 ))
}

# A boolean opt-in flag: exactly "0" or "1".
is_valid_option_flag() {
  [[ "$1" == "0" || "$1" == "1" ]]
}

# A Forgejo account / database identifier: conservative because the value
# is interpolated into psql statements and CLI invocations. 1-40 chars,
# starts with a letter, ends alphanumeric, underscore/hyphen in the middle.
is_valid_forgejo_name() {
  [[ "$1" =~ ^[a-z]([a-z0-9_-]{0,38}[a-z0-9])?$ ]]
}

# A plausible email for the Forgejo admin account (conservative subset).
is_valid_forgejo_email() {
  [[ "$1" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+$ ]]
}

# An optional Forgejo release pin like "11.0.3" (empty means "latest").
is_valid_forgejo_version() {
  [[ -z "$1" || "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]
}

# Runner labels like "ubuntu-latest:docker://node:20-bookworm". Conservative
# because the value is interpolated into the runner-registration command:
# no whitespace, quotes, or shell metacharacters.
is_valid_forgejo_runner_labels() {
  [[ "$1" =~ ^[A-Za-z0-9._:/,+-]{1,512}$ ]]
}

# Forgejo JWT secrets are unpadded base64url encodings of exactly 32 bytes,
# which occupy 43 characters (ceil(32 * 8 / 6)). Reject older malformed values
# so a re-run can repair app.ini before Forgejo tries (and fails) to rewrite
# the intentionally root-owned configuration.
is_valid_forgejo_jwt_secret() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

# An optional operator-supplied password (empty means "generate randomly").
# Conservative because the value is interpolated into psql literals, app.ini
# lines, and CLI arguments: 8-256 printable characters, no control characters
# or newlines.
is_valid_forgejo_password() {
  [[ -z "$1" ]] && return 0
  (( ${#1} >= 8 && ${#1} <= 256 )) || return 1
  [[ "$1" =~ ^[[:print:]]+$ ]]
}

# Validate user-controlled install settings before they are interpolated into
# paths, sudoers entries, generated unit files, or shell commands.
validate_config() {
  if zombie_config_selected; then
    if ! is_supported_agent_username "${AGENT_USER}"; then
      die "Invalid agent username '${AGENT_USER}'. Use a non-reserved lowercase Linux username (letters first; then letters, digits, underscore, hyphen; max 32 chars; no trailing punctuation)." 2
    fi
    if ! is_safe_absolute_path "${ZOMBIE_DIR}"; then
      die "ZOMBIE_DIR must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
    fi
  fi
  if ! is_safe_absolute_path "${LOG_FILE}"; then
    die "LOG_FILE must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  if [[ "${ZOMBIE_RECEIPT}" == "1" ]] && ! is_safe_absolute_path "${RECEIPT_FILE}"; then
    die "ZOMBIE_RECEIPT_FILE must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  if zombie_config_selected; then
    if ! is_valid_tcp_port "${CHAT_PORT}"; then
      die "ZOMBIE_CHAT_PORT must be an integer from 1 to 65535." 2
    fi
    if ! is_valid_ttl_days "${TTL_DAYS}"; then
      die "ZOMBIE_TTL_DAYS must be an integer number of days from 1 to 36500." 2
    fi
  fi
  if ! is_valid_option_flag "${ZOMBIE_INSTALL_FORGEJO}"; then
    die "ZOMBIE_INSTALL_FORGEJO must be 0 or 1." 2
  fi
  if ! is_valid_option_flag "${ZOMBIE_INSTALL_FORGEJO_RUNNER}"; then
    die "ZOMBIE_INSTALL_FORGEJO_RUNNER must be 0 or 1." 2
  fi
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    if ! is_valid_tcp_port "${FORGEJO_HTTP_PORT}"; then
      die "FORGEJO_HTTP_PORT must be an integer from 1 to 65535." 2
    fi
    if ! is_valid_forgejo_name "${FORGEJO_ADMIN_USER}"; then
      die "FORGEJO_ADMIN_USER must be a lowercase identifier (letters first; then letters, digits, underscore, hyphen; max 40 chars)." 2
    fi
    if ! is_valid_forgejo_email "${FORGEJO_ADMIN_EMAIL}"; then
      die "FORGEJO_ADMIN_EMAIL must look like an email address." 2
    fi
    if ! is_valid_forgejo_name "${FORGEJO_DB_NAME}"; then
      die "FORGEJO_DB_NAME must be a lowercase identifier (letters first; then letters, digits, underscore, hyphen; max 40 chars)." 2
    fi
    if ! is_valid_forgejo_name "${FORGEJO_DB_USER}"; then
      die "FORGEJO_DB_USER must be a lowercase identifier (letters first; then letters, digits, underscore, hyphen; max 40 chars)." 2
    fi
    if ! is_valid_forgejo_password "${FORGEJO_ADMIN_PASSWORD}"; then
      die "FORGEJO_ADMIN_PASSWORD must be 8-256 printable characters (or empty to auto-generate)." 2
    fi
    if ! is_valid_forgejo_password "${FORGEJO_DB_PASSWORD}"; then
      die "FORGEJO_DB_PASSWORD must be 8-256 printable characters (or empty to auto-generate)." 2
    fi
    if ! is_valid_forgejo_version "${FORGEJO_VERSION}"; then
      die "FORGEJO_VERSION must be a release like 11.0.3 (or empty for latest)." 2
    fi
    if ! is_valid_forgejo_version "${FORGEJO_RUNNER_VERSION}"; then
      die "FORGEJO_RUNNER_VERSION must be a release like 6.3.1 (or empty for latest)." 2
    fi
    if ! is_valid_forgejo_runner_labels "${FORGEJO_RUNNER_LABELS}"; then
      die "FORGEJO_RUNNER_LABELS must use only letters, digits, and . _ : / , + - (no spaces or quotes; max 512 chars)." 2
    fi
  fi
}

# Source /etc/os-release into the current shell.
load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  load_os_release
  local errors=0 warnings=0

  # Compact result table: parallel arrays of status (ok|warn|fail|info) and
  # a short label, rendered as a glance-able summary before the YES prompt.
  local -a pf_status=() pf_label=()
  pf() { pf_status+=("$1"); pf_label+=("$2"); }

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Not Ubuntu. Detected: ${PRETTY_NAME:-unknown}. Unsupported."
    warnings=$((warnings + 1)); pf warn "OS is Ubuntu"
  else
    pf ok "OS is Ubuntu"
  fi
  case "${VERSION_ID:-}" in
    22.04|24.04) pf ok "Ubuntu version ${VERSION_ID} (LTS)" ;;
    "")          warn "Could not detect Ubuntu version."; warnings=$((warnings + 1))
                 pf warn "Ubuntu version detected" ;;
    *)           warn "Recommended versions: 22.04 LTS or 24.04 LTS. Detected: ${VERSION_ID}."
                 warnings=$((warnings + 1)); pf warn "Ubuntu version ${VERSION_ID} (recommend LTS)" ;;
  esac

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    amd64|arm64) pf ok "Architecture ${arch}" ;;
    *) warn "Unusual architecture ${arch}; some upstream apt repos may not match."
       warnings=$((warnings + 1)); pf warn "Architecture ${arch}" ;;
  esac

  # Disk: need ~3 GB free under / for runtime packages and the agent venv.
  local avail_kb
  avail_kb="$(df -P / | awk 'NR==2 {print $4}')"
  if [[ "${avail_kb:-0}" -lt 3000000 ]]; then
    warn "Less than 3 GB free under / ($((avail_kb/1024)) MB). Install may fail."
    warnings=$((warnings + 1)); pf warn "Disk >= 3 GB free ($((avail_kb/1024)) MB)"
  else
    pf ok "Disk free $((avail_kb/1024)) MB"
  fi

  # Memory: 2 GB minimum recommended.
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem_kb:-0}" -lt 2000000 ]]; then
    warn "Less than 2 GB RAM ($((mem_kb/1024)) MB). The agent runtime may be tight."
    warnings=$((warnings + 1)); pf warn "RAM >= 2 GB ($((mem_kb/1024)) MB)"
  else
    pf ok "RAM $((mem_kb/1024)) MB"
  fi

  # DNS
  if ! getent hosts deb.debian.org >/dev/null 2>&1 \
     && ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    warn "DNS resolution looks broken (cannot resolve archive.ubuntu.com)."
    warnings=$((warnings + 1)); pf warn "DNS resolution"
  else
    pf ok "DNS resolution"
  fi

  # Outbound connectivity. Keep this to one bounded attempt: curl_get is the
  # retrying download helper and can otherwise add 45 seconds of backoff before
  # the fallback probes run on an offline host.
  if ! curl -fsSL -o /dev/null -m 8 https://archive.ubuntu.com/ >/dev/null 2>&1 \
     && ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 \
     && ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    warn "No outbound connectivity detected. Package installation will fail."
    if [[ "${SUBCOMMAND}" == "install" ]]; then
      errors=$((errors + 1)); pf fail "Outbound connectivity"
    else
      pf warn "Outbound connectivity"
    fi
  else
    pf ok "Outbound connectivity"
  fi

  # apt/dpkg lock
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    info "apt/dpkg lock currently held; install will wait up to 5 minutes."
    pf info "apt/dpkg lock (will wait)"
  fi

  # Render the compact summary table.
  if ! (( ZOMBIE_QUIET )); then
    printf '\n%sPreflight summary:%s\n' "${C_BOLD}" "${C_RESET}"
    local i
    for (( i = 0; i < ${#pf_status[@]}; i++ )); do
      status "${pf_status[i]}" "${pf_label[i]}"
    done
    echo
  fi

  # --strict turns warnings into hard failures so unattended pipelines can
  # refuse to continue on a marginal host.
  if (( STRICT )) && (( warnings > 0 )); then
    die "Preflight: ${warnings} warning(s) and --strict is set. Aborting." 66
  fi

  if (( errors > 0 )); then
    die "Preflight failed (${errors} error(s), ${warnings} warning(s)). See above." 66
  fi
  if (( warnings > 0 )); then
    info "Preflight: ${warnings} warning(s). Continuing."
  else
    ok "Preflight: clean."
  fi
}

# ---------------------------------------------------------------------------
# Validate non-interactive required env early.
# ---------------------------------------------------------------------------

validate_noninteractive() {
  [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] || return 0
}

# ---------------------------------------------------------------------------
# Subcommand: verify}

# ---------------------------------------------------------------------------
# Subcommand: verify
# ---------------------------------------------------------------------------

cmd_verify() {
  if [[ ! -x "${ZOMBIE_DIR}/bin/verify" ]]; then
    die "${ZOMBIE_DIR}/bin/verify not found. Run 'sudo ./${SCRIPT_NAME} install' first." 1
  fi
  # Propagate --json to the deployed verify script.
  if (( JSON_OUTPUT )); then
    export ZOMBIE_JSON=1
  fi
  # The embedded verify script's checks ("running as ${AGENT_USER}",
  # passwordless sudo, runtime files) only make sense when run by the
  # agent account. If invoked as root, re-exec
  # under the agent identity. See FIX-2-09.
  if [[ ${EUID} -eq 0 ]] && [[ "$(id -un)" != "${AGENT_USER}" ]]; then
    if id "${AGENT_USER}" >/dev/null 2>&1; then
      exec runuser -l "${AGENT_USER}" -c "ZOMBIE_JSON=${ZOMBIE_JSON:-0} ${ZOMBIE_DIR}/bin/verify"
    fi
  fi
  exec "${ZOMBIE_DIR}/bin/verify"
}

# ---------------------------------------------------------------------------
# Subcommand: doctor
# ---------------------------------------------------------------------------

cmd_doctor() {
  load_os_release

  # Collected results: parallel arrays of status (ok|warn|info),
  # human message, and machine-readable check id.
  local -a d_status=() d_msg=() d_id=()
  dr() { d_status+=("$1"); d_id+=("$2"); d_msg+=("$3"); }

  local host_arch
  host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  if id "${AGENT_USER}" >/dev/null 2>&1; then
    dr ok user "User ${AGENT_USER} exists."
  else
    dr warn user "User ${AGENT_USER} missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if [[ -f "/etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie" ]]; then
    dr ok sudoers "Sudoers drop-in present."
  else
    dr warn sudoers "Sudoers drop-in missing. Fix: sudo ./${SCRIPT_NAME} repair"
  fi

  if [[ -d "${ZOMBIE_DIR}" ]]; then
    dr ok install_root "${ZOMBIE_DIR} present."
  else
    dr warn install_root "${ZOMBIE_DIR} missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if [[ -f "${ZOMBIE_DIR}/secrets/env" ]]; then
    local perms
    perms="$(stat -c %a "${ZOMBIE_DIR}/secrets/env" 2>/dev/null || echo ???)"
    if [[ "${perms}" == "600" ]]; then
      dr ok secrets_perms "secrets/env permissions 600."
    else
      dr warn secrets_perms "secrets/env permissions ${perms} (must be 600). Fix: sudo ./${SCRIPT_NAME} repair"
    fi
    if grep -Eq '^(OPENAI|ANTHROPIC|GEMINI|XAI|OPENROUTER|MISTRAL|GROQ)_API_KEY=..+' "${ZOMBIE_DIR}/secrets/env" 2>/dev/null; then
      dr ok provider_token "Provider token present."
    else
      dr warn provider_token "No provider token. Fix: sudo ${ZOMBIE_DIR}/bin/secrets-edit"
    fi
  else
    dr warn secrets_env "secrets/env missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if systemctl list-unit-files ubuntu-zombie-chat.service >/dev/null 2>&1; then
    if systemctl is-active --quiet ubuntu-zombie-chat.service; then
      dr ok chat_service "Chat service active."
    else
      dr warn chat_service "Chat service installed but not running. Fix: sudo systemctl start ubuntu-zombie-chat"
    fi
  else
    dr warn chat_service "Chat service unit missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  # Optional component: Forgejo (detected from the installed unit/config).
  if [[ -f /etc/systemd/system/forgejo.service || -d /etc/forgejo ]]; then
    if systemctl is-active --quiet forgejo.service 2>/dev/null; then
      dr ok forgejo "Forgejo service active."
    else
      dr warn forgejo "Forgejo installed but not running. Likely causes: port in use (ss -ltnp), DB auth (journalctl -u forgejo | grep -i password), or migrations not run. Fix: sudo systemctl restart forgejo"
    fi
    local forgejo_dir_perms forgejo_config_perms
    forgejo_dir_perms="$(stat -c '%U:%G %a' /etc/forgejo 2>/dev/null || true)"
    forgejo_config_perms="$(
      stat -c '%U:%G %a' /etc/forgejo/app.ini 2>/dev/null \
        || sudo -n stat -c '%U:%G %a' /etc/forgejo/app.ini 2>/dev/null \
        || true
    )"
    if [[ "${forgejo_dir_perms}" == "root:git 750" \
          && "${forgejo_config_perms}" == "root:git 640" ]]; then
      dr ok forgejo_config "Forgejo config permissions are root:git 750/640."
    elif [[ -n "${forgejo_config_perms}" ]]; then
      dr warn forgejo_config "Forgejo config permissions are ${forgejo_dir_perms:-unknown}/${forgejo_config_perms}; expected root:git 750/640. Fix: sudo ./${SCRIPT_NAME} repair"
    fi
    if systemctl is-active --quiet postgresql 2>/dev/null; then
      dr ok forgejo_db "PostgreSQL active."
    else
      dr warn forgejo_db "PostgreSQL not running (Forgejo needs it). Fix: sudo systemctl start postgresql"
    fi
    if [[ -f /etc/systemd/system/forgejo-runner.service ]]; then
      if systemctl is-active --quiet forgejo-runner.service 2>/dev/null; then
        dr ok forgejo_runner "Forgejo Actions runner active."
      else
        dr warn forgejo_runner "Forgejo runner not running. Check registration (/var/lib/forgejo-runner/.runner) and Docker (systemctl status docker). Fix: sudo systemctl restart forgejo-runner"
      fi
    fi
  fi

  local n="${#d_status[@]}" i warns=0
  for (( i = 0; i < n; i++ )); do
    [[ "${d_status[i]}" == "warn" ]] && warns=$((warns + 1))
  done

  if (( JSON_OUTPUT )); then
    printf '{\n'
    printf '  "tool": "doctor",\n'
    printf '  "host": {"id": "%s", "version": "%s", "arch": "%s"},\n' \
      "$(json_escape "${ID:-}")" "$(json_escape "${VERSION_ID:-}")" "$(json_escape "${host_arch}")"
    printf '  "warnings": %d,\n' "${warns}"
    printf '  "checks": [\n'
    for (( i = 0; i < n; i++ )); do
      printf '    {"id": "%s", "status": "%s", "message": "%s"}' \
        "$(json_escape "${d_id[i]}")" "${d_status[i]}" "$(json_escape "${d_msg[i]}")"
      [[ $i -lt $((n - 1)) ]] && printf ','
      printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
    return 0
  fi

  printf '%s== ubuntu-zombie doctor ==%s\n\n' "${C_BOLD}" "${C_RESET}"
  printf '%sHost:%s %s %s on %s\n\n' "${C_BOLD}" "${C_RESET}" \
    "${ID:-?}" "${VERSION_ID:-?}" "${host_arch}"
  for (( i = 0; i < n; i++ )); do
    case "${d_status[i]}" in
      ok)   ok   "${d_msg[i]}" ;;
      warn) warn "${d_msg[i]}" ;;
      *)    info "${d_msg[i]}" ;;
    esac
  done
  echo
  info "For a runtime health summary: ${ZOMBIE_DIR}/bin/health-check"
}

# ---------------------------------------------------------------------------
# Subcommand: repair
# ---------------------------------------------------------------------------

cmd_repair() {
  section "Repair"

  if id "${AGENT_USER}" >/dev/null 2>&1; then
    if [[ -f "${ZOMBIE_DIR}/secrets/env" ]]; then
      chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
      chmod 600 "${ZOMBIE_DIR}/secrets/env"
      ok "Re-asserted secrets/env permissions."
    fi
    if [[ -d "${ZOMBIE_DIR}" ]]; then
      chown -R "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}"
    fi
  fi

  if systemctl list-unit-files ubuntu-zombie-chat.service >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl restart ubuntu-zombie-chat.service || warn "Chat service failed to restart; see journalctl -u ubuntu-zombie-chat"
    ok "Chat service restarted."
  fi

  # Re-render pi-mono runtime configs from the deployed templates.
  # Operators routinely use ``install.sh repair`` to recover after
  # manual edits, so the pi/ tree must be brought back into a known
  # good state.
  if [[ -d "${ZOMBIE_DIR}/agent/templates" ]]; then
    install -d -m 755 -o root -g root "${ZOMBIE_DIR}/pi"
    install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" \
      "${ZOMBIE_DIR}/state/logs" "${ZOMBIE_DIR}/state/pi-mono-sessions" 2>/dev/null || true
    if [[ -f "${ZOMBIE_DIR}/agent/templates/settings.json.tmpl" ]]; then
      install -m 644 "${ZOMBIE_DIR}/agent/templates/settings.json.tmpl" \
        "${ZOMBIE_DIR}/pi/settings.json"
    fi
    if [[ -f "${ZOMBIE_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" ]]; then
      _facts="hostname=$(hostname) os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}")"
      sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
          -e "s|__FACTS__|${_facts}|g" \
          "${ZOMBIE_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" \
        | install -m 644 /dev/stdin "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md"
    fi
    ok "pi-mono runtime configs re-rendered."
  fi

  # Repair re-deploys the built-in skill catalogue from the payload
  # tree so manual edits to /opt/ai-zombie/skills/ are reverted, and
  # ensures /etc/ubuntu-zombie/skills.d/ exists so operator skills
  # survive a repair run.
  if [[ -d "${PAYLOAD_DIR}/agent/skills" ]]; then
    install -d -m 755 -o root -g root "${ZOMBIE_DIR}/skills"
    shopt -s nullglob
    for f in "${PAYLOAD_DIR}/agent/skills/"*.md; do
      install -m 644 -o root -g root "${f}" "${ZOMBIE_DIR}/skills/$(basename "${f}")"
    done
    shopt -u nullglob
    install -d -m 755 -o root -g root "${ZOMBIE_ETC}/skills.d"
    ok "Skill catalogue re-deployed."
  fi

  # Optional component: Forgejo — re-assert ownership/permissions and
  # restart the units when the component is installed.
  if [[ -d /etc/forgejo || -d /var/lib/forgejo ]]; then
    [[ -d /etc/forgejo ]] && { chown root:git /etc/forgejo; chmod 750 /etc/forgejo; }
    [[ -f /etc/forgejo/app.ini ]] && { chown root:git /etc/forgejo/app.ini; chmod 640 /etc/forgejo/app.ini; }
    [[ -d /var/lib/forgejo ]] && { chown -R git:git /var/lib/forgejo; chmod 750 /var/lib/forgejo; }
    if [[ -f /etc/systemd/system/forgejo.service ]]; then
      systemctl daemon-reload
      systemctl restart forgejo.service || warn "Forgejo failed to restart; see journalctl -u forgejo"
    fi
    if [[ -f /etc/systemd/system/forgejo-runner.service ]]; then
      chown -R forgejo-runner:forgejo-runner /var/lib/forgejo-runner 2>/dev/null || true
      systemctl restart forgejo-runner.service || warn "Forgejo runner failed to restart; see journalctl -u forgejo-runner"
    fi
    ok "Forgejo ownership and services re-asserted."
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  if [[ -x "${SCRIPT_DIR}/uninstall.sh" ]]; then
    # Forward the behaviour flags parsed by this wrapper so that
    # `install.sh uninstall --dry-run` really previews (and does not
    # perform a live uninstall), and `--yes`, `--quiet`, `--no-color`,
    # `--archive`, and `--keep-agent` reach the uninstaller.
    local -a fwd=()
    (( DRY_RUN ))              && fwd+=(--dry-run)
    (( ASSUME_YES ))           && fwd+=(--yes)
    (( ZOMBIE_QUIET ))         && fwd+=(--quiet)
    (( UNINSTALL_ARCHIVE ))    && fwd+=(--archive)
    (( UNINSTALL_KEEP_AGENT )) && fwd+=(--keep-agent)
    [[ "${ZOMBIE_COLOR:-}" == "never" ]] && fwd+=(--no-color)
    exec "${SCRIPT_DIR}/uninstall.sh" "${fwd[@]}" "${TARGET_ARGS[@]}"
  fi
  die "uninstall.sh not found alongside ${SCRIPT_NAME}." 1
}

# ---------------------------------------------------------------------------
# Dry-run summary (no host mutation; safe without sudo).
# ---------------------------------------------------------------------------

print_dry_run_plan() {
  load_os_release
  if (( COMPONENT_FORGEJO_SELECTED )) && (( ! COMPONENT_ZOMBIE_SELECTED )); then
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}  —  dry-run

A real standalone Forgejo install is accepted by the parser but gated until
the component extraction phase lands. With the current environment it would
plan:

  Components:     $(selected_components_label)
  Host:           ${ID:-?} ${VERSION_ID:-?} on $(dpkg --print-architecture 2>/dev/null || uname -m)
  Transcript:     ${LOG_FILE}
  Receipt:        $([[ "${ZOMBIE_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo "(disabled)")

Forgejo component:
  Forgejo server  git forge + PostgreSQL (${FORGEJO_VERSION:-latest release})
                  apt: git-lfs postgresql postgresql-contrib openssl xz-utils
                  binary: /usr/local/bin/forgejo (checksum-verified download)
                  data: /var/lib/forgejo (git:git)  config: /etc/forgejo/app.ini
                  database: ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD}"))
                  admin: ${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD}"))
                  unit: /etc/systemd/system/forgejo.service
                  exposure: http://<host>:${FORGEJO_HTTP_PORT}/ on all interfaces (normal access)
EOF
    if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
      cat <<EOF
  Actions runner  co-located Forgejo Actions runner (Docker executor)
                  unit: /etc/systemd/system/forgejo-runner.service
EOF
    fi
    cat <<EOF

Nothing has been changed. To install Forgejo today, use the legacy combined
Ubuntu Zombie + Forgejo path:

  sudo ZOMBIE_INSTALL_FORGEJO=1 ./${SCRIPT_NAME} install

See docs/QUICKSTART.md and docs/ARCHITECTURE.md for the full picture.
EOF
    return 0
  fi
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}  —  dry-run

A real 'install' run with the current environment would:

  Host:           ${ID:-?} ${VERSION_ID:-?} on $(dpkg --print-architecture 2>/dev/null || uname -m)
  Agent user:     ${AGENT_USER}  (home: ${AGENT_HOME})
  Install root:   ${ZOMBIE_DIR}
  Etc dir:        ${ZOMBIE_ETC}
  Log dir:        ${ZOMBIE_LOG_DIR}
  Transcript:     ${LOG_FILE}
  Receipt:        $([[ "${ZOMBIE_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo "(disabled)")
  Chat port:      ${CHAT_PORT}/tcp (loopback only)
  Mode:           $([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)

Apt package groups installed:
  base            sudo, curl, git, editors, Python 3/venv, build-essential,
                  ripgrep, jq, logrotate, unattended-upgrades, …
  nodejs          Node 22.x from deb.nodesource.com (signed-by keyring)

Files & directories created / re-asserted:
  /etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie   (NOPASSWD: ALL for ${AGENT_USER})
  ${ZOMBIE_DIR}/                                  (755, ${AGENT_USER}:${AGENT_USER})
  ${ZOMBIE_DIR}/secrets/                          (700, env file 600)
  ${ZOMBIE_DIR}/bin/                              (verify, health-check, secrets-edit, audit-recent, …)
  ${ZOMBIE_DIR}/agent/                            (Python package + templates + skills + pi bridge)
  ${ZOMBIE_DIR}/pi/                               (rendered pi-mono settings + APPEND_SYSTEM.md)
  ${ZOMBIE_DIR}/skills/                           (built-in markdown skills)
  ${ZOMBIE_ETC}/skills.d/                         (operator-supplied skills)
  ${ZOMBIE_LOG_DIR}/                              (750, ${AGENT_USER}:${AGENT_USER}, logrotate'd)
  /etc/systemd/system/ubuntu-zombie-chat.service
  /etc/systemd/system/ubuntu-zombie-health.service
  /etc/systemd/system/ubuntu-zombie-health.timer
  /etc/logrotate.d/ubuntu-zombie
EOF
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    cat <<EOF

Optional components enabled (ZOMBIE_INSTALL_* flags):
  Forgejo server  git forge + PostgreSQL (${FORGEJO_VERSION:-latest release})
                  apt: git-lfs postgresql postgresql-contrib openssl xz-utils
                  binary: /usr/local/bin/forgejo (checksum-verified download)
                  data: /var/lib/forgejo (git:git)  config: /etc/forgejo/app.ini
                  database: ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD}"))
                  admin: ${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD}"))
                  unit: /etc/systemd/system/forgejo.service
                  exposure: http://<host>:${FORGEJO_HTTP_PORT}/ on all interfaces (normal access)
EOF
    if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
      cat <<EOF
  Actions runner  co-located Forgejo Actions runner (Docker executor)
                  apt: docker.io   binary: /usr/local/bin/forgejo-runner
                  registers against 127.0.0.1:${FORGEJO_HTTP_PORT} with labels:
                    ${FORGEJO_RUNNER_LABELS}
                  unit: /etc/systemd/system/forgejo-runner.service
                  note: co-locating runner and forge is contrary to upstream
                        guidance and is enabled deliberately.
EOF
    fi
  fi
  cat <<EOF

Nothing has been changed. To proceed for real:

  sudo ./${SCRIPT_NAME} install

See docs/QUICKSTART.md and docs/ARCHITECTURE.md for the full picture.
EOF
}

# ---------------------------------------------------------------------------
# Interactive parameter review (Zombie Orchid setup experience)
# ---------------------------------------------------------------------------
# A branded, editable summary of every install parameter. The operator can
# tweak any field and re-review until satisfied, then accept. Skipped in
# non-interactive / --yes runs and when stdin is not a TTY, so automated
# installs are unaffected.

# Render the current parameters as a glance-able, brand-coloured table.
print_parameter_table() {
  load_os_release
  local receipt_state
  if [[ "${ZOMBIE_RECEIPT}" == "1" ]]; then
    receipt_state="${RECEIPT_FILE}"
  else
    receipt_state="disabled"
  fi

  brand_banner "Ubuntu Zombie — setup parameters"
  printf '  %sReview every setting below, edit any of them, then accept when happy.%s\n\n' \
    "${C_DIM}" "${C_RESET}"
  field "1) Agent user"      "${AGENT_USER}"
  field "   Agent home"      "${AGENT_HOME}" "${C_DIM}"
  field "2) Install root"    "${ZOMBIE_DIR}"
  field "3) Chat port"       "${CHAT_PORT}/tcp (loopback only)"
  field "4) Transcript log"  "${LOG_FILE}"
  field "5) Receipt file"    "${receipt_state}"
  field "6) Chat password"   "$([[ "${ADMIN_PASSWORD_SET}" == "1" ]] && echo 'set (hidden)' || printf 'default (%s)' "${ZOMBIE_ADMIN_PASSWORD_DEFAULT}")"
  field "7) Time to Live"    "${TTL_DAYS} day(s) then permanently disabled"
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    field "8) Local LLM"     "${LOCAL_LLM_MODEL} @ ${LOCAL_LLM_BASE_URL}"
  else
    field "8) Local LLM"     "none (scan LAN for an OpenAI-compatible server)" "${C_DIM}"
  fi
  if any_option_enabled; then
    field "9) Options"       "$(options_summary)"
  else
    field "9) Options"       "none selected (backup, forge, and more to come)" "${C_DIM}"
  fi
  field "   Host"            "${ID:-?} ${VERSION_ID:-?} ($(dpkg --print-architecture 2>/dev/null || uname -m))" "${C_DIM}"
  printf '\n'
}

# One-line summary of every enabled optional component, for row 9.
options_summary() {
  local parts=()
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    local runner_state="off"
    [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]] && runner_state="on"
    parts+=("Forgejo server (port ${FORGEJO_HTTP_PORT}, admin ${FORGEJO_ADMIN_USER}, runner: ${runner_state})")
  fi
  local IFS='; '
  printf '%s' "${parts[*]}"
}

# Individual field editors.# Individual field editors. Each keeps the current value when the operator
# presses Enter (allow_empty=1), and re-prompts on invalid input rather than
# aborting the whole run.
_edit_agent_user() {
  local v
  if prompt_until_valid "$(printf 'New agent user [%s]: ' "${AGENT_USER}")" \
       is_supported_agent_username v 1 && [[ -n "${v}" ]]; then
    AGENT_USER="${v}"; AGENT_HOME="/home/${AGENT_USER}"
  fi
}
_edit_zombie_dir() {
  local v
  if prompt_until_valid "$(printf 'New install root [%s]: ' "${ZOMBIE_DIR}")" \
       is_safe_absolute_path v 1 && [[ -n "${v}" ]]; then
    ZOMBIE_DIR="${v}"
  fi
}
_edit_chat_port() {
  local v
  if prompt_until_valid "$(printf 'New chat port [%s]: ' "${CHAT_PORT}")" \
       is_valid_tcp_port v 1 && [[ -n "${v}" ]]; then
    CHAT_PORT="${v}"
  fi
}
_edit_log_file() {
  local v
  if prompt_until_valid "$(printf 'New transcript log path [%s]: ' "${LOG_FILE}")" \
       is_safe_absolute_path v 1 && [[ -n "${v}" ]]; then
    LOG_FILE="${v}"
  fi
}
_toggle_receipt() {
  if [[ "${ZOMBIE_RECEIPT}" == "1" ]]; then
    local v
    printf 'Receipt is ON. Press Enter to turn it OFF, or type a new path: '
    if read -r v && [[ -n "${v}" ]]; then
      if is_safe_absolute_path "${v}"; then
        RECEIPT_FILE="${v}"; info "Receipt path set to ${RECEIPT_FILE}."
      else
        warn "Not a safe absolute path; receipt unchanged."
      fi
    else
      ZOMBIE_RECEIPT=0; info "Receipt disabled."
    fi
  else
    ZOMBIE_RECEIPT=1; info "Receipt enabled: ${RECEIPT_FILE}."
  fi
}
_edit_admin_password() {
  local p1 p2
  [[ "${ZOMBIE_NONINTERACTIVE}" == "1" || ! -t 0 ]] && return 0
  if ! read -r -s -p "New chat password (blank to keep the default '${ZOMBIE_ADMIN_PASSWORD_DEFAULT}'): " p1; then
    echo
    warn "No input (EOF); chat password unchanged."
    return 0
  fi
  echo
  if [[ -z "${p1}" ]]; then
    info "Chat password left at the default."
    return 0
  fi
  if ! read -r -s -p "Confirm chat password: " p2; then
    echo
    warn "No input (EOF); chat password unchanged."
    return 0
  fi
  echo
  if [[ "${p1}" != "${p2}" ]]; then
    warn "Passwords did not match; chat password unchanged."
    return 0
  fi
  ADMIN_PASSWORD="${p1}"
  ADMIN_PASSWORD_SET=1
  ok "Chat password recorded."
}
_edit_ttl_days() {
  local v
  if prompt_until_valid "$(printf 'New Time to Live in days [%s]: ' "${TTL_DAYS}")" \
       is_valid_ttl_days v 1 && [[ -n "${v}" ]]; then
    TTL_DAYS="${v}"; ok "Time to Live set to ${TTL_DAYS} day(s)."
  fi
}

# ---------------------------------------------------------------------------
# Optional components menu (item 9 of the parameter review)
# ---------------------------------------------------------------------------
# A nested, branded sub-menu that lists every opt-in component with its
# on/off state and settings. New components add one row here instead of
# renumbering the top-level review menu.

_edit_forgejo_port() {
  local v
  if prompt_until_valid "$(printf 'Forgejo web port [%s]: ' "${FORGEJO_HTTP_PORT}")" \
       is_valid_tcp_port v 1 && [[ -n "${v}" ]]; then
    FORGEJO_HTTP_PORT="${v}"; ok "Forgejo port set to ${FORGEJO_HTTP_PORT}."
  fi
}

_edit_forgejo_admin() {
  local v
  if prompt_until_valid "$(printf 'Forgejo admin username [%s]: ' "${FORGEJO_ADMIN_USER}")" \
       is_valid_forgejo_name v 1 && [[ -n "${v}" ]]; then
    FORGEJO_ADMIN_USER="${v}"; ok "Forgejo admin set to ${FORGEJO_ADMIN_USER}."
  fi
  if prompt_until_valid "$(printf 'Forgejo admin email [%s]: ' "${FORGEJO_ADMIN_EMAIL}")" \
       is_valid_forgejo_email v 1 && [[ -n "${v}" ]]; then
    FORGEJO_ADMIN_EMAIL="${v}"; ok "Forgejo admin email set to ${FORGEJO_ADMIN_EMAIL}."
  fi
  local p1 p2
  if ! read -r -s -p "Forgejo admin password (blank to auto-generate and record in the receipt): " p1; then
    printf '\n'
    warn "No input (EOF); Forgejo admin password unchanged."
    return 0
  fi
  printf '\n'
  if [[ -z "${p1}" ]]; then
    FORGEJO_ADMIN_PASSWORD=""
    FORGEJO_ADMIN_PASSWORD_SOURCE=""
    info "Forgejo admin password will be generated and recorded in the receipt."
    return 0
  fi
  if ! is_valid_forgejo_password "${p1}"; then
    warn "Password must be 8-256 printable characters; Forgejo admin password unchanged."
    return 0
  fi
  if ! read -r -s -p "Confirm Forgejo admin password: " p2; then
    printf '\n'
    warn "No input (EOF); Forgejo admin password unchanged."
    return 0
  fi
  printf '\n'
  if [[ "${p1}" != "${p2}" ]]; then
    warn "Passwords did not match; Forgejo admin password unchanged."
    return 0
  fi
  FORGEJO_ADMIN_PASSWORD="${p1}"
  FORGEJO_ADMIN_PASSWORD_SOURCE="operator"
  ok "Forgejo admin password recorded."
}

_edit_forgejo_database() {
  local v
  if prompt_until_valid "$(printf 'Forgejo PostgreSQL database name [%s]: ' "${FORGEJO_DB_NAME}")" \
       is_valid_forgejo_name v 1 && [[ -n "${v}" ]]; then
    FORGEJO_DB_NAME="${v}"; ok "Forgejo database set to ${FORGEJO_DB_NAME}."
  fi
  if prompt_until_valid "$(printf 'Forgejo PostgreSQL role (username) [%s]: ' "${FORGEJO_DB_USER}")" \
       is_valid_forgejo_name v 1 && [[ -n "${v}" ]]; then
    FORGEJO_DB_USER="${v}"; ok "Forgejo database role set to ${FORGEJO_DB_USER}."
  fi
  local p1 p2
  if ! read -r -s -p "Forgejo PostgreSQL role password (blank to auto-generate and record in the receipt): " p1; then
    printf '\n'
    warn "No input (EOF); Forgejo database password unchanged."
    return 0
  fi
  printf '\n'
  if [[ -z "${p1}" ]]; then
    FORGEJO_DB_PASSWORD=""
    FORGEJO_DB_PASSWORD_SOURCE=""
    info "Forgejo database password will be generated and recorded in the receipt."
    return 0
  fi
  if ! is_valid_forgejo_password "${p1}"; then
    warn "Password must be 8-256 printable characters; Forgejo database password unchanged."
    return 0
  fi
  if ! read -r -s -p "Confirm Forgejo PostgreSQL role password: " p2; then
    printf '\n'
    warn "No input (EOF); Forgejo database password unchanged."
    return 0
  fi
  printf '\n'
  if [[ "${p1}" != "${p2}" ]]; then
    warn "Passwords did not match; Forgejo database password unchanged."
    return 0
  fi
  FORGEJO_DB_PASSWORD="${p1}"
  FORGEJO_DB_PASSWORD_SOURCE="operator"
  ok "Forgejo database password recorded."
}

# Accepts a release pin like 11.0.3 or the keyword "latest" (clears the pin).
_forgejo_version_or_latest() {
  [[ "${1,,}" == "latest" ]] || is_valid_forgejo_version "$1"
}

_edit_forgejo_versions() {
  local v
  if prompt_until_valid "$(printf 'Forgejo release pin (x.y.z, or "latest") [%s]: ' "${FORGEJO_VERSION:-latest}")" \
       _forgejo_version_or_latest v 1 && [[ -n "${v}" ]]; then
    [[ "${v,,}" == "latest" ]] && v=""
    FORGEJO_VERSION="${v}"; ok "Forgejo version set to ${FORGEJO_VERSION:-latest release}."
  fi
  if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    if prompt_until_valid "$(printf 'Runner release pin (x.y.z, or "latest") [%s]: ' "${FORGEJO_RUNNER_VERSION:-latest}")" \
         _forgejo_version_or_latest v 1 && [[ -n "${v}" ]]; then
      [[ "${v,,}" == "latest" ]] && v=""
      FORGEJO_RUNNER_VERSION="${v}"; ok "Runner version set to ${FORGEJO_RUNNER_VERSION:-latest release}."
    fi
    if prompt_until_valid "$(printf 'Runner labels [%s]: ' "${FORGEJO_RUNNER_LABELS}")" \
         is_valid_forgejo_runner_labels v 1 && [[ -n "${v}" ]]; then
      FORGEJO_RUNNER_LABELS="${v}"; ok "Runner labels set to ${FORGEJO_RUNNER_LABELS}."
    fi
  fi
}

_toggle_forgejo_runner() {
  if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    ZOMBIE_INSTALL_FORGEJO_RUNNER=0
    info "Forgejo Actions runner disabled."
  else
    ZOMBIE_INSTALL_FORGEJO_RUNNER=1
    warn "Co-locating the runner with the forge is contrary to upstream guidance; enabling deliberately."
    info "Forgejo Actions runner enabled (standard Docker executor)."
  fi
}

_toggle_forgejo() {
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    ZOMBIE_INSTALL_FORGEJO=0
    ZOMBIE_INSTALL_FORGEJO_RUNNER=0
    info "Forgejo server disabled."
  else
    ZOMBIE_INSTALL_FORGEJO=1
    info "Forgejo server enabled (PostgreSQL-backed, port ${FORGEJO_HTTP_PORT})."
  fi
}

# Render the current optional components as a glance-able sub-table.
print_options_table() {
  brand_banner "Ubuntu Zombie — optional components"
  printf '  %sEvery option is off by default and reversible by uninstall.sh.%s\n\n' \
    "${C_DIM}" "${C_RESET}"
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    field "1) Forgejo server"  "enabled"
    field "2) Forgejo port"    "${FORGEJO_HTTP_PORT}/tcp (all interfaces)"
    field "3) Forgejo admin"   "${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD}"))"
    field "4) Actions runner"  "$([[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo 'enabled (Docker executor, same host)' || echo 'disabled')"
    field "5) Database"        "PostgreSQL ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD}"))"
    if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
      field "6) Versions"      "Forgejo ${FORGEJO_VERSION:-latest release}, runner ${FORGEJO_RUNNER_VERSION:-latest release} (labels ${FORGEJO_RUNNER_LABELS})"
    else
      field "6) Versions"      "Forgejo ${FORGEJO_VERSION:-latest release}"
    fi
  else
    field "1) Forgejo server"  "disabled (git forge + PostgreSQL, optional CI runner)" "${C_DIM}"
  fi
  printf '\n'
}

# The nested options review loop, entered from item 9 of review_parameters.
review_options() {
  local choice
  while true; do
    print_options_table
    printf '  %s[b]%s back to setup    %s[1-6]%s toggle or edit an option\n' \
      "${C_ACCENT}" "${C_RESET}" "${C_BRAND2}" "${C_RESET}"
    if ! read -r -p "$(printf '%s➜%s your choice [b]: ' "${C_BRAND}" "${C_RESET}")" choice; then
      return 0
    fi
    case "${choice,,}" in
      ""|b|back|q) return 0 ;;
      1) _toggle_forgejo ;;
      2) [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_port \
           || warn "Enable the Forgejo server first (option 1)." ;;
      3) [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_admin \
           || warn "Enable the Forgejo server first (option 1)." ;;
      4) [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && _toggle_forgejo_runner \
           || warn "Enable the Forgejo server first (option 1)." ;;
      5) [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_database \
           || warn "Enable the Forgejo server first (option 1)." ;;
      6) [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_versions \
           || warn "Enable the Forgejo server first (option 1)." ;;
      *) warn "Unrecognised choice: '${choice}'. Enter a number 1-6 or 'b'." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Local LLM discovery on the LAN
# ---------------------------------------------------------------------------
# Probe every address in the host's IPv4 /24 for an OpenAI-compatible LLM
# server (LM Studio, Ollama, llama.cpp, …) answering on
# http://<ip>:PORT/v1/models, then offer the advertised models as the
# starting model. Entirely best-effort: a missing curl/python3, an
# undetectable subnet, or an empty result simply leaves the selection unset.

# Print the host's primary global IPv4 /24 prefix (first three octets), or
# nothing when it cannot be determined.
_local_ipv4_prefix() {
  local cidr ip
  cidr="$(ip -4 -o addr show scope global up 2>/dev/null \
            | awk '{print $4; exit}')"
  ip="${cidr%/*}"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 0
  printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Parse the model ids from a /v1/models JSON body on stdin, one per line.
# Only ids made of a conservative, shell/env-safe character set are emitted:
# the values are later written verbatim into secrets/env, so a hostile or
# malformed local server must not be able to inject newlines or other
# characters that would smuggle extra assignments into that file.
_parse_model_ids() {
  python3 -c '
import json, re, sys
SAFE = re.compile(r"\A[A-Za-z0-9._:/+@-]{1,200}\Z")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data.get("data") if isinstance(data, dict) else None
if not isinstance(items, list):
    sys.exit(0)
seen = set()
for item in items:
    if not isinstance(item, dict):
        continue
    mid = item.get("id")
    if isinstance(mid, str):
        mid = mid.strip()
        if mid and mid not in seen and SAFE.match(mid):
            seen.add(mid)
            print(mid)
' 2>/dev/null || true
}

# Probe a single host:port for an OpenAI-compatible /v1/models endpoint and,
# on success, append "host<TAB>port<TAB>model" lines to ``outfile``.
_probe_llm_host() {
  local host="$1" port="$2" outfile="$3"
  local body model
  body="$(curl -fsS --connect-timeout 1 --max-time 3 \
            "http://${host}:${port}/v1/models" 2>/dev/null)" || return 0
  [[ -n "${body}" ]] || return 0
  while IFS= read -r model; do
    [[ -n "${model}" ]] && printf '%s\t%s\t%s\n' "${host}" "${port}" "${model}" >> "${outfile}"
  done < <(printf '%s' "${body}" | _parse_model_ids)
}

# Write the `pi` custom-provider config so the agent loop reaches a local
# OpenAI-compatible server through the 'lmstudio' provider. pi reads
# ${AGENT_HOME}/.pi/agent/models.json (homedir() + ~/.pi/agent), so the server
# URL lives here rather than in an environment variable. Args: base URL, model.
write_pi_models_json() {
  local base_url="$1" model="$2" dir="${AGENT_HOME}/.pi/agent" file
  file="${dir}/models.json"
  install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.pi" "${dir}"
  install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${file}"
  cat > "${file}" <<EOF
{
  "providers": {
    "lmstudio": {
      "baseUrl": "$(json_escape "${base_url}")",
      "api": "openai-completions",
      "apiKey": "LMSTUDIO_API_KEY",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        { "id": "$(json_escape "${model}")" }
      ]
    }
  }
}
EOF
  chown "${AGENT_USER}:${AGENT_USER}" "${file}"
  chmod 600 "${file}"
}

# Compute the PBKDF2 hash for the chat-UI password without exposing the
# plaintext on a command line (it is piped to auth.py over stdin). An empty
# password makes auth.py fall back to the documented default.
admin_password_hash() {
  printf '%s\n' "$1" | python3 "${PAYLOAD_DIR}/agent/auth.py"
}

# Ensure secrets/env carries a ZOMBIE_ADMIN_PASSWORD_HASH line. The hash is
# (re)written when it is missing, or when the operator explicitly chose a
# password this run (ADMIN_PASSWORD_SET=1); an existing hash is otherwise
# preserved so a plain re-install never resets a customised password.
ensure_admin_password_hash() {
  local file="$1" hash has_line=0
  grep -q '^ZOMBIE_ADMIN_PASSWORD_HASH=' "${file}" 2>/dev/null && has_line=1
  if [[ "${has_line}" -eq 1 && "${ADMIN_PASSWORD_SET}" != "1" ]]; then
    return 0
  fi
  if ! hash="$(admin_password_hash "${ADMIN_PASSWORD:-${ZOMBIE_ADMIN_PASSWORD_DEFAULT}}")"; then
    die "Failed to hash the chat password." 1
  fi
  if [[ "${has_line}" -eq 1 ]]; then
    sed -i -E '/^ZOMBIE_ADMIN_PASSWORD_HASH=/d' "${file}"
  fi
  [[ -s "${file}" ]] && [[ "$(tail -c1 "${file}" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${file}"
  printf 'ZOMBIE_ADMIN_PASSWORD_HASH=%s\n' "${hash}" >> "${file}"
}

# Initialise (or reset) the Time-to-Live kill switch. A reinstall always
# resets the tombstone and starts a fresh countdown — that is how a dead
# zombie is brought back to life.
init_lifecycle_state() {
  local state="${ZOMBIE_DIR}/state/lifecycle.json"
  if ! runuser -u "${AGENT_USER}" -- env \
        ZOMBIE_LIFECYCLE_STATE="${state}" \
        python3 "${ZOMBIE_DIR}/agent/lifecycle.py" init --days "${TTL_DAYS}" >/dev/null; then
    die "Failed to initialise the Time-to-Live state." 1
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${state}"
  chmod 600 "${state}"
  ok "Time to Live set: ${TTL_DAYS} day(s) until the zombie is disabled."
}
# DISCOVERED_MODELS (parallel index) with every advertised model.
DISCOVERED_ENDPOINTS=()
DISCOVERED_MODELS=()
scan_local_llms() {
  DISCOVERED_ENDPOINTS=()
  DISCOVERED_MODELS=()
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    warn "Local LLM scan needs curl and python3; skipping."
    return 1
  fi
  local prefix port
  prefix="$(_local_ipv4_prefix)"
  port="${ZOMBIE_LLM_SCAN_PORT}"
  if ! is_valid_tcp_port "${port}"; then
    warn "ZOMBIE_LLM_SCAN_PORT='${port}' is not a valid TCP port (1-65535); skipping LLM discovery."
    return 1
  fi
  if [[ -z "${prefix}" ]]; then
    warn "Could not determine a local IPv4 /24 to scan; skipping LLM discovery."
    return 1
  fi
  info "Scanning ${prefix}.0/24 on port ${port} for OpenAI-compatible LLM servers…"
  local resfile pids n max=64
  resfile="$(mktemp 2>/dev/null)" || { warn "Could not create a temp file for the scan."; return 1; }
  chmod 600 "${resfile}" 2>/dev/null || true
  pids=()
  for n in $(seq 0 255); do
    _probe_llm_host "${prefix}.${n}" "${port}" "${resfile}" &
    pids+=("$!")
    if (( ${#pids[@]} >= max )); then
      wait "${pids[@]}" 2>/dev/null || true
      pids=()
    fi
  done
  (( ${#pids[@]} )) && { wait "${pids[@]}" 2>/dev/null || true; }

  local host hport hmodel
  while IFS=$'\t' read -r host hport hmodel; do
    [[ -n "${host}" && -n "${hmodel}" ]] || continue
    DISCOVERED_ENDPOINTS+=("${host}:${hport}")
    DISCOVERED_MODELS+=("${hmodel}")
  done < <(sort -u "${resfile}" 2>/dev/null)
  rm -f "${resfile}" 2>/dev/null || true

  if (( ${#DISCOVERED_MODELS[@]} == 0 )); then
    info "No local LLM servers found on ${prefix}.0/24:${port}."
    return 1
  fi
  return 0
}

# Interactive picker: scan, present the discovered models, and record the
# operator's choice in LOCAL_LLM_ENDPOINT / LOCAL_LLM_BASE_URL /
# LOCAL_LLM_MODEL. Skipped on non-interactive / --yes / non-TTY runs and when
# ZOMBIE_SKIP_LLM_SCAN=1.
discover_local_llms() {
  [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0
  [[ "${ZOMBIE_SKIP_LLM_SCAN}" == "1" ]] && return 0

  scan_local_llms || return 0

  local i choice
  while true; do
    brand_banner "Local LLM servers discovered on your network"
    printf '  %sPick a model to use as the starting model, or skip to configure a%s\n' "${C_DIM}" "${C_RESET}"
    printf '  %scloud provider later in %s/secrets/env.%s\n\n' "${C_DIM}" "${ZOMBIE_DIR}" "${C_RESET}"
    for i in "${!DISCOVERED_MODELS[@]}"; do
      field "$(printf '%2d)' "$((i + 1))")" \
        "${DISCOVERED_MODELS[$i]}  @  http://${DISCOVERED_ENDPOINTS[$i]}/v1"
    done
    printf '\n  %s[1-%d]%s use a model    %s[r]%s rescan    %s[s]%s skip\n' \
      "${C_BRAND2}" "${#DISCOVERED_MODELS[@]}" "${C_RESET}" \
      "${C_ACCENT}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}"
    if ! read -r -p "$(printf '%s➜%s your choice [s]: ' "${C_BRAND}" "${C_RESET}")" choice; then
      info "No input (EOF); skipping local LLM selection."
      return 0
    fi
    case "${choice,,}" in
      ""|s|skip|n|no)
        info "No local LLM selected."
        return 0 ;;
      r|rescan)
        scan_local_llms || return 0
        continue ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DISCOVERED_MODELS[@]} )); then
          LOCAL_LLM_ENDPOINT="${DISCOVERED_ENDPOINTS[$((choice - 1))]}"
          LOCAL_LLM_MODEL="${DISCOVERED_MODELS[$((choice - 1))]}"
          LOCAL_LLM_BASE_URL="http://${LOCAL_LLM_ENDPOINT}/v1"
          ok "Local LLM ${LOCAL_LLM_MODEL} (${LOCAL_LLM_BASE_URL}) chosen as the starting model."
          return 0
        fi
        warn "Unrecognised choice: '${choice}'. Enter 1-${#DISCOVERED_MODELS[@]}, 'r', or 's'." ;;
    esac
  done
}

_edit_local_llm() {
  discover_local_llms
}

review_parameters() {
  # Automated paths skip the review entirely.
  [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0

  local choice
  while true; do
    print_parameter_table
    printf '  %s[a]%s accept and install    %s[1-9]%s edit a field    %s[q]%s cancel\n' \
      "${C_ACCENT}" "${C_RESET}" "${C_BRAND2}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}"
    if ! read -r -p "$(printf '%s➜%s your choice [a]: ' "${C_BRAND}" "${C_RESET}")" choice; then
      info "No input (EOF); cancelling."; exit 0
    fi
    case "${choice,,}" in
      ""|a|accept|y|yes)
        # Edits are validated as they are entered, so this is a belt-and-
        # braces final check before committing to the install.
        validate_config
        REVIEWED=1
        ok "Parameters accepted."
        return 0 ;;
      q|quit|cancel|n|no)
        info "Cancelled."; exit 0 ;;
      1)  _edit_agent_user ;;
      2)  _edit_zombie_dir ;;
      3)  _edit_chat_port ;;
      4)  _edit_log_file ;;
      5)  _toggle_receipt ;;
      6)  _edit_admin_password ;;
      7)  _edit_ttl_days ;;
      8)  _edit_local_llm ;;
      9)  review_options ;;
      *)  warn "Unrecognised choice: '${choice}'. Enter a number 1-9, 'a', or 'q'." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Install receipt (start + finish records)
# ---------------------------------------------------------------------------
# A human-readable record of the install. Written once when the run starts
# (every parameter) and finalised with the outcome when it ends. The file is
# root-only (mode 600). Operator-supplied password values and provider keys
# are never written; passwords the installer generates itself are recorded
# in the finish record so the operator can retrieve them.

write_receipt_start() {
  [[ "${ZOMBIE_RECEIPT}" == "1" ]] || return 0
  load_os_release
  if ! mkdir -p "$(dirname "${RECEIPT_FILE}")" 2>/dev/null; then
    warn "Could not create receipt directory; receipt disabled for this run."
    ZOMBIE_RECEIPT=0
    return 0
  fi
  if [[ -f "${RECEIPT_FILE}" ]]; then
    chmod 600 "${RECEIPT_FILE}" 2>/dev/null || true
  elif ! install -m 600 /dev/null "${RECEIPT_FILE}" 2>/dev/null; then
    warn "Could not create the install receipt at ${RECEIPT_FILE}."
    ZOMBIE_RECEIPT=0
    return 0
  fi

  if ! {
    printf '============================================================\n'
    printf 'Ubuntu Zombie — install receipt\n'
    printf '============================================================\n'
    printf 'Phase            : START\n'
    printf 'Started (UTC)    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Installer        : %s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
    printf 'Host             : %s %s (%s)\n' "${ID:-?}" "${VERSION_ID:-?}" \
      "$(dpkg --print-architecture 2>/dev/null || uname -m)"
    printf 'Invoked by       : %s (uid %s)\n' "${SUDO_USER:-$(id -un)}" "$(id -u)"
    printf 'Mode             : %s\n' \
      "$([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"
    printf '\n-- Parameters --\n'
    printf 'Agent user       : %s\n' "${AGENT_USER}"
    printf 'Agent home       : %s\n' "${AGENT_HOME}"
    printf 'Install root     : %s\n' "${ZOMBIE_DIR}"
    printf 'Etc dir          : %s\n' "${ZOMBIE_ETC}"
    printf 'Log dir          : %s\n' "${ZOMBIE_LOG_DIR}"
    printf 'Transcript log   : %s\n' "${LOG_FILE}"
    printf 'Chat port        : %s/tcp (loopback only)\n' "${CHAT_PORT}"
    printf 'Local LLM        : %s\n' \
      "$([[ -n "${LOCAL_LLM_MODEL}" ]] && printf '%s @ %s' "${LOCAL_LLM_MODEL}" "${LOCAL_LLM_BASE_URL}" || echo 'none')"
    printf 'Receipt file     : %s\n' "${RECEIPT_FILE}"
    if any_option_enabled; then
      printf '\n-- Optional components --\n'
      if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
        printf 'Forgejo server   : enabled\n'
        printf 'Forgejo port     : %s/tcp (all interfaces)\n' "${FORGEJO_HTTP_PORT}"
        printf 'Forgejo admin    : %s <%s> (password %s)\n' \
          "${FORGEJO_ADMIN_USER}" "${FORGEJO_ADMIN_EMAIL}" \
          "$(password_source_label "${FORGEJO_ADMIN_PASSWORD}")"
        printf 'Forgejo database : %s (role %s; password %s)\n' \
          "${FORGEJO_DB_NAME}" "${FORGEJO_DB_USER}" \
          "$(password_source_label "${FORGEJO_DB_PASSWORD}")"
        printf 'Forgejo version  : %s\n' "${FORGEJO_VERSION:-latest (resolved at install)}"
        printf 'Actions runner   : %s\n' \
          "$([[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo 'enabled (co-located, Docker executor)' || echo disabled)"
      fi
    fi
    printf '============================================================\n'
  } >> "${RECEIPT_FILE}" 2>/dev/null; then
    warn "Could not write the install receipt to ${RECEIPT_FILE}."
    ZOMBIE_RECEIPT=0
    return 0
  fi
  chmod 600 "${RECEIPT_FILE}" 2>/dev/null || true
  info "Install receipt opened: ${RECEIPT_FILE}"
}

write_receipt_finish() {
  [[ "${ZOMBIE_RECEIPT}" == "1" ]] || return 0
  [[ -f "${RECEIPT_FILE}" ]] || return 0
  {
    printf '\n-- Finish --\n'
    printf 'Phase            : FINISH\n'
    printf 'Result           : SUCCESS\n'
    printf 'Finished (UTC)   : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${INSTALL_T0:-}" ]]; then
      printf 'Duration         : %s\n' "$(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")"
    fi
    printf 'Provider token   : %s\n' "$([[ "${PROVIDER_OK:-0}" == "1" ]] && echo present || echo missing)"
    printf 'Chat service     : %s\n' "$([[ "${CHAT_OK:-0}" == "1" ]] && echo running || echo 'not running')"
    if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
      printf 'Forgejo version  : %s\n' "${FORGEJO_RESOLVED_VERSION:-unknown}"
      printf 'Forgejo service  : %s\n' \
        "$(systemctl is-active --quiet forgejo.service 2>/dev/null && echo running || echo 'not running')"
      printf 'Forgejo secrets  : generated (stored only in /etc/forgejo/app.ini, mode 640)\n'
      printf 'Forgejo admin pw : %s\n' \
        "$(receipt_password_line "${FORGEJO_ADMIN_PASSWORD_SOURCE}" "${FORGEJO_ADMIN_PASSWORD}")"
      printf 'Forgejo DB pw    : %s\n' \
        "$(receipt_password_line "${FORGEJO_DB_PASSWORD_SOURCE}" "${FORGEJO_DB_PASSWORD}")"
      if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
        printf 'Actions runner   : %s\n' \
          "$(systemctl is-active --quiet forgejo-runner.service 2>/dev/null && echo running || echo 'not running')"
      fi
    fi
    printf 'Steps satisfied  : %s\n' "${STEPS_SATISFIED}"
    printf 'Steps applied    : %s\n' "${STEPS_CHANGED}"
    [[ -n "${NEXT_STEP:-}" ]] && printf 'Next step        : %s\n' "${NEXT_STEP}"
    printf '============================================================\n'
  } >> "${RECEIPT_FILE}" 2>/dev/null || {
    warn "Could not finalise the install receipt at ${RECEIPT_FILE}."
    return 0
  }
  ok "Install receipt finalised: ${RECEIPT_FILE}"
}

# Render one password line for the finish receipt. Only values this run
# generated itself are written out (the receipt is root-only, mode 600);
# operator-supplied or reused credentials are never recorded.
receipt_password_line() { # $1 = source, $2 = value
  case "$1" in
    generated) printf '%s (generated this run)' "$2" ;;
    operator)  printf 'set by operator (not recorded)' ;;
    existing)  printf 'unchanged (reused from host, not recorded)' ;;
    *)         printf 'unchanged (not touched this run)' ;;
  esac
}

# Append a short failure record to the receipt from the error trap.
write_receipt_fail() {
  [[ "${ZOMBIE_RECEIPT}" == "1" ]] || return 0
  [[ -f "${RECEIPT_FILE}" ]] || return 0
  {
    printf '\n-- Finish --\n'
    printf 'Phase            : FINISH\n'
    printf 'Result           : FAILED (line %s, exit %s)\n' "${1:-?}" "${2:-?}"
    printf 'Finished (UTC)   : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${INSTALL_T0:-}" ]]; then
      printf 'Duration         : %s\n' "$(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")"
    fi
    printf 'Transcript log   : %s\n' "${LOG_FILE}"
    printf '============================================================\n'
  } >> "${RECEIPT_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Dispatch non-install subcommands early.
# ---------------------------------------------------------------------------

trap 'on_error ${LINENO}' ERR

validate_config

if [[ "${SUBCOMMAND}" != "uninstall" ]] \
  && (( UNINSTALL_ARCHIVE || UNINSTALL_KEEP_AGENT )); then
  die "--archive/--keep-agent only apply to the uninstall subcommand." 2
fi
if [[ "${SUBCOMMAND}" == "uninstall" ]] && (( EXPLICIT_TARGETS )) \
  && (( ! COMPONENT_ZOMBIE_SELECTED )) && (( UNINSTALL_ARCHIVE || UNINSTALL_KEEP_AGENT )); then
  die "--archive/--keep-agent only apply to a zombie uninstall target." 2
fi

case "${SUBCOMMAND}" in
  verify)    cmd_verify; exit $? ;;
  doctor)    cmd_doctor; exit $? ;;
  repair)    require_root; cmd_repair; exit $? ;;
  uninstall) (( DRY_RUN )) || require_root; cmd_uninstall; exit $? ;;
  install)   ;;
  *)         die "Unknown subcommand: ${SUBCOMMAND}" 2 ;;
esac

# Dry-run short-circuits the entire install path. It does not require
# root: the whole point is to let an operator preview what would happen
# before they grant sudo.
if (( DRY_RUN )); then
  print_dry_run_plan
  exit 0
fi

if (( COMPONENT_FORGEJO_SELECTED )) && (( ! COMPONENT_ZOMBIE_SELECTED )); then
  die "Standalone Forgejo install syntax is accepted, but non-dry-run execution is gated until component extraction is complete. Use 'ZOMBIE_INSTALL_FORGEJO=1 ./${SCRIPT_NAME} install' for the current combined path." 2
fi

# =============================================================================
# install — the rest of the file
# =============================================================================

require_root
validate_noninteractive

# Bootstrap prerequisites: a fresh Ubuntu Desktop image ships without curl,
# and a minimal image can also lack python3. Both are needed before the main
# package phase — the local LLM scan, the preflight connectivity check, and
# every curl_get download rely on them — so install whichever is missing now.
# Idempotent: does nothing when both commands are already present.
bootstrap_prerequisites() {
  local missing=()
  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  (( ${#missing[@]} )) || return 0
  info "Installing missing prerequisite package(s): ${missing[*]}…"
  apt_get update -qq \
    || warn "apt-get update failed; attempting the install anyway."
  apt_install "${missing[@]}" \
    || die "Could not install prerequisite package(s): ${missing[*]}. Install them manually (apt-get install ${missing[*]}) and re-run." 1
  ok "Prerequisite package(s) installed: ${missing[*]}"
}
bootstrap_prerequisites

# Local LLM discovery: scan the host's IPv4 /24 for an OpenAI-compatible LLM
# server and offer the models it advertises as the starting model. Runs before
# the parameter review so the choice shows up in the table. No-op for
# --yes / non-interactive / non-TTY runs or when ZOMBIE_SKIP_LLM_SCAN=1.
discover_local_llms

# Interactive review: present every parameter in a branded, editable table
# and let the operator tweak settings until satisfied. Runs before any state
# is touched and before the transcript is opened, so edits to LOG_FILE take
# effect. No-op for --yes / non-interactive / non-TTY runs.
review_parameters
preflight

# Transcript logging
mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Step-trace breadcrumb: every section() call writes to this file so a
# crashed install leaves a clear trail of which step failed and which
# steps preceded it. on_error() includes the tail in its diagnostic.
STEP_LOG="${LOG_FILE%.log}.steps"
mkdir -p "$(dirname "${STEP_LOG}")"
: > "${STEP_LOG}"
chmod 600 "${STEP_LOG}" 2>/dev/null || true

# Enable shell xtrace into the transcript only (not the console) when the
# operator asked for --verbose/--debug. BASH_XTRACEFD keeps the noisy trace
# out of the live terminal while preserving it for post-mortem debugging.
if (( VERBOSE )); then
  exec {_TRACE_FD}>>"${LOG_FILE}"
  BASH_XTRACEFD="${_TRACE_FD}"
  set -x
fi

# Phase counter: count the install-path section banners so each one can be
# numbered "[n/total]". Derived from this file so it stays correct as
# phases are added or removed.
ZOMBIE_PHASE=0
SECTION_RULE_WIDTH=60
ZOMBIE_PHASE_TOTAL="$(awk '/^# install — the rest of the file/{f=1} f && /^section "/{c++} END{print c+0}' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0)"
# The count is derived by scanning this file, so guard against a 0/empty
# result (e.g. if the marker comment is ever moved) — fall back to an
# un-totalled "[n]" counter rather than printing a confusing "[n/0]".
[[ "${ZOMBIE_PHASE_TOTAL}" =~ ^[0-9]+$ ]] || ZOMBIE_PHASE_TOTAL=0

# Optional components add indented `  section "..."` calls inside guarded
# if-blocks (deliberately not matched by the top-level count above, so a
# default install's "[n/total]" is unaffected). When a component is
# enabled, add its section count to the denominator so progress stays
# honest. Blocks are delimited by "# option-sections: <name> begin/end".
_count_option_sections() {
  awk -v m="$1" '
    $0 ~ "^ *# option-sections: " m " begin$" {f=1}
    f && /^ +section "/ {c++}
    $0 ~ "^ *# option-sections: " m " end$" {f=0}
    END {print c+0}
  ' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0
}
if (( ZOMBIE_PHASE_TOTAL > 0 )); then
  if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
    ZOMBIE_PHASE_TOTAL=$(( ZOMBIE_PHASE_TOTAL + $(_count_option_sections forgejo) ))
    if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
      ZOMBIE_PHASE_TOTAL=$(( ZOMBIE_PHASE_TOTAL + $(_count_option_sections forgejo-runner) ))
    fi
  fi
fi
_SECTION_T0=""

# Re-define section() to record a breadcrumb, number each phase, and report
# how long the previous phase took in a plain-English "Completed in …" line,
# without surrounding every transition in three heavy separator lines.
section() {
  local now; now="$(date +%s)"
  if [[ -n "${_SECTION_T0}" ]]; then
    (( ZOMBIE_QUIET )) || printf '%s    Completed in %s%s\n' \
      "${C_DIM}" "$(fmt_duration "$(( now - _SECTION_T0 ))")" "${C_RESET}"
  fi
  _SECTION_T0="${now}"
  ZOMBIE_PHASE=$(( ZOMBIE_PHASE + 1 ))
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STEP_LOG}" || true
  (( ZOMBIE_QUIET )) && return 0
  local counter
  if (( ZOMBIE_PHASE_TOTAL > 0 )); then
    counter="[${ZOMBIE_PHASE}/${ZOMBIE_PHASE_TOTAL}]"
  else
    counter="[${ZOMBIE_PHASE}]"
  fi
  printf '\n%s%sPhase %s%s  %s\n' \
    "${C_BRAND}" "${C_BOLD}" "${counter}" "${C_RESET}" "$*"
  brand_rule "${SECTION_RULE_WIDTH}"
}

# Augment on_error() with the step trail so an operator pasting the
# failure into an issue has both the line number AND the last few
# completed install phases.
on_error() {
  local exit_code=$?
  local line=$1
  printf '\n%s[x] %s failed on line %s with exit code %s.%s\n' \
    "${C_RED}" "${SCRIPT_NAME}" "${line}" "${exit_code}" "${C_RESET}" >&2
  printf '%s    Full transcript: %s%s\n' "${C_RED}" "${LOG_FILE}" "${C_RESET}" >&2
  if [[ -s "${STEP_LOG}" ]]; then
    printf '%s    Steps completed before failure (last 5):%s\n' "${C_RED}" "${C_RESET}" >&2
    tail -n 5 "${STEP_LOG}" | sed 's/^/      /' >&2 || true
    printf '%s    Full step trail: %s%s\n' "${C_RED}" "${STEP_LOG}" "${C_RESET}" >&2
  fi
  diagnose_failure "${exit_code}" || true
  write_receipt_fail "${line}" "${exit_code}" || true
  printf '%s    Exit codes: 1 generic · 2 usage · 64 missing env · 65 bad host · 66 network.%s\n' \
    "${C_RED}" "${C_RESET}" >&2
  printf '%s    Recovery: re-run the installer (it is idempotent), or %ssudo ./%s doctor%s for guidance.%s\n' \
    "${C_RED}" "${C_BOLD}" "${SCRIPT_NAME}" "${C_RESET}${C_RED}" "${C_RESET}" >&2
  exit "${exit_code}"
}

# Record the install start so the run can report total elapsed time at the
# end. The title is printed as a plain banner so it is not counted as a
# numbered phase.
INSTALL_T0="$(date +%s)"

info "Log file: ${LOG_FILE}"
info "Agent user: ${AGENT_USER}"
info "Install root: ${ZOMBIE_DIR}"
info "Chat port: ${CHAT_PORT} (loopback only)"
info "Mode: $([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"
if (( ZOMBIE_PHASE_TOTAL > 0 )); then
  info "Phases: ${ZOMBIE_PHASE_TOTAL}. Typical run takes ~10–20 min depending on network speed."
else
  info "Typical run takes ~10–20 min depending on network speed."
fi

cat <<EOF

This installer will:
  - Create the ${AGENT_USER} user (operating identity of the AI Systems Administrator) with passwordless sudo
  - Install Python and Node agent runtimes
  - Install the loopback chat service (ubuntu-zombie-chat.service)
  - Install policy, audit log, and helper scripts
  - Enable automatic security updates
EOF
if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
  printf '  - Install a Forgejo git forge + PostgreSQL on port %s (all interfaces)\n' "${FORGEJO_HTTP_PORT}"
  if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    printf '  - Install a co-located Forgejo Actions runner (Docker executor)\n'
  fi
fi
cat <<EOF

Run this from the physical Ubuntu machine, not over public SSH.

EOF

if [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]]; then
  info "Non-interactive mode: proceeding without confirmation."
elif (( ASSUME_YES )); then
  info "--yes: proceeding without confirmation."
elif (( REVIEWED )); then
  info "Parameters reviewed and accepted: proceeding."
else
  read -r -p "Continue? Type YES to proceed: " CONFIRM
  [[ "${CONFIRM}" == "YES" ]] || { info "Cancelled."; exit 0; }
fi

# Open the install receipt now that every parameter is finalised and the
# operator has committed to the run.
write_receipt_start

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

section "Update the operating system"

apt_get update
apt_get -y upgrade

section "Install system dependencies"

apt_install \
  sudo \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  apt-transport-https \
  git \
  vim \
  nano \
  tmux \
  htop \
  unzip \
  zip \
  jq \
  iputils-ping \
  unattended-upgrades \
  logrotate \
  python3 \
  python3-pip \
  python3-venv \
  pipx \
  build-essential \
  ripgrep \
  fd-find \
  tree \
  rsync \
  cron \
  pwgen \
  psmisc

# ---------------------------------------------------------------------------
# Agent user and sudo
# ---------------------------------------------------------------------------

section "Configure the ${AGENT_USER} agent identity"

if id "${AGENT_USER}" >/dev/null 2>&1; then
  info "User ${AGENT_USER} already exists."
else
  adduser --gecos "" --disabled-password "${AGENT_USER}"
  ok "Created user ${AGENT_USER}."
fi

usermod -aG sudo "${AGENT_USER}"

SUDOERS_FILE="/etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie"
SUDOERS_TMP="$(mktemp "${SUDOERS_FILE}.XXXXXX")"
cat > "${SUDOERS_TMP}" <<EOF
# Managed by ${SCRIPT_NAME}. Grants ${AGENT_USER} passwordless root.
${AGENT_USER} ALL=(ALL) NOPASSWD:ALL
EOF
if ! visudo -cf "${SUDOERS_TMP}" >/dev/null; then
  rm -f "${SUDOERS_TMP}"
  die "Generated sudoers drop-in failed validation." 1
fi
install -m 0440 "${SUDOERS_TMP}" "${SUDOERS_FILE}"
rm -f "${SUDOERS_TMP}"
ok "Configured passwordless sudo for ${AGENT_USER}."

# ---------------------------------------------------------------------------
# Security services and unattended upgrades
# ---------------------------------------------------------------------------

section "Configure automatic security updates"

systemctl enable --now unattended-upgrades >/dev/null || true

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

ok "Automatic security updates enabled (reboots at 04:00 if required)."

section "Keep the desktop available"

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true

ok "Sleep and suspend targets masked."

# ---------------------------------------------------------------------------
# Workspace at /opt/ai-zombie
# ---------------------------------------------------------------------------

section "Prepare application state"

install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" "${ZOMBIE_DIR}" \
  "${ZOMBIE_DIR}/bin" "${ZOMBIE_DIR}/logs" "${ZOMBIE_DIR}/state" \
  "${ZOMBIE_DIR}/scripts" "${ZOMBIE_DIR}/tools" "${ZOMBIE_DIR}/agent" \
  "${ZOMBIE_DIR}/agent/templates"
install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${ZOMBIE_DIR}/secrets"
install -d -m 755 "${ZOMBIE_ETC}"
install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" "${ZOMBIE_LOG_DIR}"

if [[ ! -f "${ZOMBIE_DIR}/secrets/env" ]]; then
  install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${ZOMBIE_DIR}/secrets/env"
  cat > "${ZOMBIE_DIR}/secrets/env" <<EOF
# Token provider credentials and runtime environment for the AI Systems Administrator.
# Pick ONE provider line and paste the key. The same provider + model
# selection drives BOTH the agent loop (pi-mono / the actual chat
# answers) and the status banner — there is a single source of truth.
#   OPENAI_API_KEY=sk-...
#   ANTHROPIC_API_KEY=sk-ant-...
#   GEMINI_API_KEY=...
#   XAI_API_KEY=...
#   OPENROUTER_API_KEY=...
#   MISTRAL_API_KEY=...
#   GROQ_API_KEY=...
#
# Optional:
#   ZOMBIE_PROVIDER=openai      # openai|anthropic|gemini|xai|openrouter|mistral|groq|lmstudio
#   ZOMBIE_MODEL=gpt-4o-mini    # model for the agent loop + chat (required for openrouter/lmstudio)
#   LMSTUDIO_API_KEY=local      # local OpenAI-compatible server (LM Studio, Ollama,
#                               # llama.cpp). Pair with ZOMBIE_PROVIDER=lmstudio; the
#                               # server URL lives in ~/.pi/agent/models.json.
#   ZOMBIE_CHAT_PORT=${CHAT_PORT}

DISPLAY=:0
ZOMBIE_DIR=${ZOMBIE_DIR}
AGENT_USER=${AGENT_USER}
AGENT_HOME=${AGENT_HOME}
ZOMBIE_CHAT_PORT=${CHAT_PORT}
EOF
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    cat >> "${ZOMBIE_DIR}/secrets/env" <<EOF

# Local LLM auto-discovered on the LAN during install: an OpenAI-compatible
# server at ${LOCAL_LLM_BASE_URL}. The agent loop (pi-mono / the actual chat
# answers) reaches it through the custom 'lmstudio' provider defined in
# ${AGENT_HOME}/.pi/agent/models.json, which carries the server URL. Most local
# servers ignore the API key; replace it if yours requires one.
ZOMBIE_PROVIDER=lmstudio
ZOMBIE_MODEL=${LOCAL_LLM_MODEL}
LMSTUDIO_API_KEY=${ZOMBIE_LOCAL_LLM_API_KEY}
EOF
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
  chmod 600 "${ZOMBIE_DIR}/secrets/env"
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    write_pi_models_json "${LOCAL_LLM_BASE_URL}" "${LOCAL_LLM_MODEL}"
    ok "Created ${ZOMBIE_DIR}/secrets/env with local LLM ${LOCAL_LLM_MODEL} at ${LOCAL_LLM_BASE_URL}."
  else
    ok "Created ${ZOMBIE_DIR}/secrets/env (edit with: sudo ${ZOMBIE_DIR}/bin/secrets-edit)."
  fi
else
  info "Preserving existing ${ZOMBIE_DIR}/secrets/env."
  if grep -q '^ZOMBIE_CHAT_PORT=' "${ZOMBIE_DIR}/secrets/env"; then
    sed -i -E "s|^ZOMBIE_CHAT_PORT=.*$|ZOMBIE_CHAT_PORT=${CHAT_PORT}|" "${ZOMBIE_DIR}/secrets/env"
  else
    [[ -s "${ZOMBIE_DIR}/secrets/env" ]] && [[ "$(tail -c1 "${ZOMBIE_DIR}/secrets/env" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${ZOMBIE_DIR}/secrets/env"
    printf 'ZOMBIE_CHAT_PORT=%s\n' "${CHAT_PORT}" >> "${ZOMBIE_DIR}/secrets/env"
  fi
  # When a local LLM was discovered during this run, also apply the
  # lmstudio provider settings to the existing secrets/env so a
  # re-install picks up the new backend instead of silently keeping
  # whatever provider was previously selected (the chat banner would
  # otherwise still show e.g. "openai" even though the operator
  # intends to use the local server).
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    # Drop any prior provider/model/key lines so we can append fresh
    # values without sed-escaping the operator-supplied key (which may
    # contain characters that would otherwise terminate the s|||
    # expression).
    sed -i -E '/^(ZOMBIE_PROVIDER|ZOMBIE_MODEL|LMSTUDIO_API_KEY)=/d' \
      "${ZOMBIE_DIR}/secrets/env"
    [[ -s "${ZOMBIE_DIR}/secrets/env" ]] && [[ "$(tail -c1 "${ZOMBIE_DIR}/secrets/env" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${ZOMBIE_DIR}/secrets/env"
    {
      printf 'ZOMBIE_PROVIDER=lmstudio\n'
      printf 'ZOMBIE_MODEL=%s\n' "${LOCAL_LLM_MODEL}"
      printf 'LMSTUDIO_API_KEY=%s\n' "${ZOMBIE_LOCAL_LLM_API_KEY}"
    } >> "${ZOMBIE_DIR}/secrets/env"
    write_pi_models_json "${LOCAL_LLM_BASE_URL}" "${LOCAL_LLM_MODEL}"
    ok "Applied local LLM ${LOCAL_LLM_MODEL} at ${LOCAL_LLM_BASE_URL} to existing secrets/env."
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
  chmod 600 "${ZOMBIE_DIR}/secrets/env"
fi

# Stamp the chat-UI password hash into secrets/env (idempotent: keeps an
# existing hash unless the operator chose a new password this run).
ensure_admin_password_hash "${ZOMBIE_DIR}/secrets/env"
chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
chmod 600 "${ZOMBIE_DIR}/secrets/env"
# ---------------------------------------------------------------------------
# Python cloud-agent runtime
# ---------------------------------------------------------------------------

section "Build the Python runtime"

# Stage the venv setup helper into ${ZOMBIE_DIR}/bin early so the
# unprivileged setup below can exec it. The rest of the operator
# helpers are installed in the "Deploy chat service" section below.
# Extracted in FIX-1-12 so the body is lintable by ShellCheck.
install -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/bin/setup-agent-venv" "${ZOMBIE_DIR}/bin/setup-agent-venv"

# Build the venv and install Python packages as the agent user. On an
# interactive TTY show a heartbeat spinner and route the detail to the
# transcript, while non-interactive/CI runs keep the full output streaming.
if [[ -t 2 ]] && ! (( ZOMBIE_QUIET )); then
  run_step "Building Python venv" -- \
    bash -c 'runuser -l "$1" -- "$2" >>"$3" 2>&1' \
    _ "${AGENT_USER}" "${ZOMBIE_DIR}/bin/setup-agent-venv" "${LOG_FILE}"
else
  runuser -l "${AGENT_USER}" -- "${ZOMBIE_DIR}/bin/setup-agent-venv"
fi

ok "Python venv ready at ${AGENT_HOME}/agent-env."

# ---------------------------------------------------------------------------
# Node runtime
# ---------------------------------------------------------------------------

section "Build the Node agent runtime"

# The npm bundled with Ubuntu's apt-provided `nodejs` (Node 18 on
# 22.04/24.04) is too old to self-upgrade to npm@latest, which now
# requires Node ^20.17.0 || >=22.9.0. Install Node 22.x from the
# official NodeSource apt repository so the global npm install below —
# and the pi-ai / pi-coding-agent globals that follow — see a Node
# runtime they actually support. Pattern uses the standard signed-by
# keyring + sources.list.d drop-in apt repository setup.
NODESOURCE_KEYRING="/usr/share/keyrings/nodesource.gpg"
NODESOURCE_SOURCES="/etc/apt/sources.list.d/nodesource.sources"
NODESOURCE_PREF="/etc/apt/preferences.d/nodejs"
NODE_MAJOR="22"
NODE_ARCH="$(dpkg --print-architecture)"
case "${NODE_ARCH}" in
  amd64|arm64) : ;;
  *) die "NodeSource supports only amd64/arm64; detected '${NODE_ARCH}'." 65 ;;
esac
install -d -m 755 "$(dirname "${NODESOURCE_KEYRING}")"
# Remove any legacy one-line NodeSource list left by an older install
# or manual setup; we now manage the source via the deb822 file below.
rm -f /etc/apt/sources.list.d/nodesource.list
curl_get https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o "${NODESOURCE_KEYRING}"
chmod 0644 "${NODESOURCE_KEYRING}"
cat > "${NODESOURCE_SOURCES}" <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: ${NODE_ARCH}
Signed-By: ${NODESOURCE_KEYRING}
EOF
# Pin nodejs to the NodeSource origin so apt always prefers it over the
# older Ubuntu archive package on subsequent upgrades.
cat > "${NODESOURCE_PREF}" <<EOF
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
EOF
apt_get update
apt_install nodejs

# Upgrading npm in place is booby-trapped on recent Node releases:
# `npm install -g npm@latest` makes npm reinstall *itself*, and partway
# through the reify pipeline it removes its own `node_modules` (including
# transitive deps such as `promise-retry`) before arborist's rebuild step
# lazily `require()`s them — so the command dies with
#   MODULE_NOT_FOUND / Cannot find module 'promise-retry'
# (see nodejs/node#62425, npm/cli#9151, actions/runner-images#13883).
#
# This is NOT merely an incomplete-bundle problem: the self-upgrade crashes
# even when the running npm is complete (verified against the official
# nodejs.org tarball, which does ship promise-retry). Repairing the bundle
# and re-running the self-upgrade therefore just re-triggers the same race.
#
# So we never ask npm to upgrade itself. Instead we fetch the latest npm
# release straight from the npm registry — whose published tarball bundles
# all of npm's dependencies — verify its Subresource Integrity hash, and drop
# it into the global node_modules ourselves. No reify, no self-deletion race,
# and the result is a complete, current npm. The retry wrapper around this
# only has to cover transient network failures.
npm_install_root() {
  local npm_cmd="$1"
  node -e '
    const fs = require("fs");
    const path = require("path");
    let dir;
    try {
      dir = path.dirname(fs.realpathSync(process.argv[1]));
    } catch (_) {
      process.exit(1);
    }
    while (true) {
      if (path.basename(dir) === "npm" &&
          fs.existsSync(path.join(dir, "package.json"))) {
        console.log(dir);
        process.exit(0);
      }
      const parent = path.dirname(dir);
      if (parent === dir) {
        process.exit(1);
      }
      dir = parent;
    }
  ' "${npm_cmd}"
}

# Install the latest npm release from the npm registry without going through
# npm's self-upgrade (see the long note above for why that self-destructs).
# The registry's published tarball bundles every npm dependency, so unpacking
# it straight into the global node_modules yields a complete, current npm with
# no reify step. We require and verify the registry-provided Subresource
# Integrity hash before extracting as root, and parse the packument with node
# (already installed) to avoid pulling in a jq dependency. Transient network
# errors bubble up as a non-zero return so the retry wrapper can try again.
install_npm_latest() {
  local npm_cmd npm_root tmp_dir version tarball_url integrity tarball
  npm_cmd="$(command -v npm)" || die "npm command missing after nodejs install." 1
  npm_root="$(npm_install_root "${npm_cmd}")" \
    || die "Could not resolve npm install root for ${npm_cmd}." 1
  tmp_dir="$(mktemp -d)"
  curl_get "https://registry.npmjs.org/npm/latest" -o "${tmp_dir}/latest.json" \
    || { rm -rf "${tmp_dir}"; return 1; }
  node -e '
    const m = require(process.argv[1]);
    if (!m.version || !m.dist || !m.dist.tarball || typeof m.dist.integrity !== "string") process.exit(1);
    const sri = m.dist.integrity;
    const i = sri.indexOf("-");
    if (i <= 0 || i === sri.length - 1) process.exit(1);
    process.stdout.write([m.version, m.dist.tarball, sri].join("\n") + "\n");
  ' "${tmp_dir}/latest.json" > "${tmp_dir}/meta.txt" \
    || { rm -rf "${tmp_dir}"; die "npm registry metadata for the latest npm release was missing a valid integrity hash." 1; }
  version="$(sed -n 1p "${tmp_dir}/meta.txt")"
  tarball_url="$(sed -n 2p "${tmp_dir}/meta.txt")"
  integrity="$(sed -n 3p "${tmp_dir}/meta.txt")"
  [[ -n "${version}" && -n "${tarball_url}" && -n "${integrity}" ]] \
    || { rm -rf "${tmp_dir}"; die "npm registry metadata for the latest npm release was incomplete." 1; }
  tarball="${tmp_dir}/npm.tgz"
  curl_get "${tarball_url}" -o "${tarball}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  # Verify the registry's SRI hash (e.g. "sha512-<base64>") before trusting the
  # archive. A mismatch means a corrupt or tampered download, so we abort hard
  # rather than retrying a request that would keep failing the same way.
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    const sri = process.argv[1], file = process.argv[2];
    const i = sri.indexOf("-");
    if (i <= 0 || i === sri.length - 1) process.exit(1);
    const algo = sri.slice(0, i);
    const expected = sri.slice(i + 1);
    const got = crypto.createHash(algo).update(fs.readFileSync(file)).digest("base64");
    process.exit(got === expected ? 0 : 1);
  ' "${integrity}" "${tarball}" \
    || { rm -rf "${tmp_dir}"; die "Integrity check failed for npm@${version} from the npm registry." 1; }
  tar -xzf "${tarball}" -C "${tmp_dir}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  [[ -d "${tmp_dir}/package" ]] \
    || { rm -rf "${tmp_dir}"; die "npm registry tarball for npm@${version} had an unexpected layout." 1; }
  rm -rf "${npm_root}"
  mkdir -p "$(dirname "${npm_root}")"
  cp -a "${tmp_dir}/package" "${npm_root}"
  rm -rf "${tmp_dir}"
  npm --version >/dev/null \
    || die "npm broken after installing npm@${version} from the registry." 1
  log "Installed npm@${version} from the npm registry."
}
retry 4 5 -- install_npm_latest
retry 4 5 -- npm install -g --ignore-scripts yarn pnpm typescript ts-node

install_pinned_node_bridge() {
  local name="$1" version_file="$2"
  local pinned_version package version url sha256 tmp_dir tarball
  local _integrity _license

  pinned_version="$(tr -d '[:space:]' < "${version_file}")"
  if [[ -z "${pinned_version}" ]]; then
    die "${version_file#${REPO_ROOT}/} is empty; refusing to install ${name} unpinned." 1
  fi

  if ! read -r package version url sha256 _integrity _license < <(
    awk -v want="${name}" '
      $0 !~ /^#/ && $1 == want { print $2, $3, $4, $5, $6, $7 }
    ' "${PAYLOAD_DIR}/agent/bridge-dependencies.lock"
  ); then
    die "Missing bridge dependency lock entry for ${name}." 1
  fi
  if [[ -z "${package:-}" || -z "${version:-}" || -z "${url:-}" || -z "${sha256:-}" ]]; then
    die "Incomplete bridge dependency lock entry for ${name}." 1
  fi
  if [[ "${version}" != "${pinned_version}" ]]; then
    die "${version_file#${REPO_ROOT}/} pins ${pinned_version}, but bridge lock pins ${version}." 1
  fi

  tmp_dir="$(mktemp -d)"
  tarball="${tmp_dir}/${name}.tgz"
  curl_get "${url}" -o "${tarball}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  printf '%s  %s\n' "${sha256}" "${tarball}" | sha256sum -c - >/dev/null \
    || { rm -rf "${tmp_dir}"; die "Checksum mismatch for ${package}@${version} from ${url}." 1; }

  log "Installing ${package}@${version} globally from checksum-pinned tarball."
  npm install -g --ignore-scripts "${tarball}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  rm -rf "${tmp_dir}"
}

# pi-ai is the unified LLM client for the chat service. Pinned to the
# exact version and checksum recorded in payload/agent/bridge-dependencies.lock.
retry 4 5 -- install_pinned_node_bridge pi-ai "${PAYLOAD_DIR}/agent/pi-ai.version"

# pi-mono is the agent loop the chat service drives via
# payload/agent/pi-mono-bridge.mjs. Pinned the same way as pi-ai.
retry 4 5 -- install_pinned_node_bridge pi-mono "${PAYLOAD_DIR}/agent/pi-mono.version"

# ---------------------------------------------------------------------------
# Optional component: Forgejo server (ZOMBIE_INSTALL_FORGEJO=1)
# ---------------------------------------------------------------------------
# A self-hosted git forge backed by PostgreSQL. This is a *normal* network
# service for people: it listens on all interfaces (unlike the loopback-only
# chat UI), and its admin/database credentials are generated at install time
# and stored only in root-owned files on this host. Every step checks the
# current state first so re-runs converge without errors.

# Map dpkg architecture to the Forgejo release asset suffix. The uname -m
# names (x86_64/aarch64) only apply when dpkg is unavailable and the
# fallback runs.
forgejo_release_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64)  printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

# Resolve the latest release tag (e.g. "11.0.3") of a Codeberg repository.
codeberg_latest_release() {
  local repo="$1" tag
  tag="$(curl_get "https://codeberg.org/api/v1/repos/${repo}/releases/latest" \
           | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)" || return 1
  tag="${tag#v}"
  [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || return 1
  printf '%s' "${tag}"
}

# Read one key from one section of an ini file (first match wins), so
# same-named keys in other sections (e.g. NAME/USER/PASSWD) never leak.
ini_get() {
  local file="$1" section="$2" key="$3"
  awk -F' = ' -v s="[${section}]" -v k="${key}" '
    $0 == s {in_s=1; next}
    /^\[/   {in_s=0}
    in_s && $1 == k {print $2; exit}
  ' "${file}" 2>/dev/null
}

# Download a Codeberg release asset and verify its published .sha256 sum.
# Usage: codeberg_fetch_verified <url> <dest_tmp_file>
codeberg_fetch_verified() {
  local url="$1" dest="$2" sum
  curl_get "${url}" -o "${dest}" || return 1
  sum="$(curl_get "${url}.sha256" | awk '{print $1}')" || return 1
  [[ "${sum}" =~ ^[0-9a-f]{64}$ ]] \
    || die "Could not fetch a valid checksum for ${url}." 1
  printf '%s  %s\n' "${sum}" "${dest}" | sha256sum -c - >/dev/null \
    || die "Checksum mismatch for ${url}." 1
}

if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
  # option-sections: forgejo begin
  section "Install Forgejo prerequisites"

  apt_install git git-lfs postgresql postgresql-contrib openssl xz-utils

  section "Create git system user"

  if id git >/dev/null 2>&1; then
    info "User git already exists."
    note_satisfied
  else
    adduser --system --group --home /var/lib/forgejo \
      --shell /bin/bash --gecos "Forgejo git service" git
    ok "Created system user git."
    note_changed
  fi

  section "Install Forgejo binary"

  FORGEJO_ARCH="$(forgejo_release_arch)" \
    || die "Forgejo releases support only amd64/arm64 hosts." 65
  if [[ -n "${FORGEJO_VERSION}" ]]; then
    FORGEJO_RESOLVED_VERSION="${FORGEJO_VERSION}"
    info "Forgejo release pinned to ${FORGEJO_RESOLVED_VERSION}."
  else
    FORGEJO_RESOLVED_VERSION="$(codeberg_latest_release forgejo/forgejo)" \
      || die "Could not resolve the latest Forgejo release from codeberg.org (pin FORGEJO_VERSION to proceed)." 66
    info "Latest Forgejo release: ${FORGEJO_RESOLVED_VERSION}."
  fi
  _installed_forgejo=""
  if [[ -x /usr/local/bin/forgejo ]]; then
    _installed_forgejo="$(/usr/local/bin/forgejo --version 2>/dev/null \
      | awk '{print $3}' | cut -d+ -f1 || true)"
  fi
  if [[ "${_installed_forgejo}" == "${FORGEJO_RESOLVED_VERSION}" ]]; then
    info "Forgejo ${FORGEJO_RESOLVED_VERSION} already installed."
    note_satisfied
  else
    _forgejo_url="https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_RESOLVED_VERSION}/forgejo-${FORGEJO_RESOLVED_VERSION}-linux-${FORGEJO_ARCH}"
    _forgejo_tmp="$(mktemp)"
    codeberg_fetch_verified "${_forgejo_url}" "${_forgejo_tmp}" \
      || { rm -f "${_forgejo_tmp}"; die "Failed to download Forgejo ${FORGEJO_RESOLVED_VERSION}." 66; }
    install -m 0755 -o root -g root "${_forgejo_tmp}" /usr/local/bin/forgejo
    rm -f "${_forgejo_tmp}"
    ok "Installed Forgejo ${FORGEJO_RESOLVED_VERSION} to /usr/local/bin/forgejo (checksum verified)."
    note_changed
  fi

  section "Create Forgejo directories"

  install -d -m 750 -o git -g git /var/lib/forgejo
  install -d -m 750 -o root -g git /etc/forgejo
  note_satisfied

  section "Configure PostgreSQL for Forgejo"

  systemctl enable --now postgresql >/dev/null 2>&1 \
    || die "PostgreSQL failed to start; see journalctl -u postgresql." 1
  # Password precedence: an operator-supplied FORGEJO_DB_PASSWORD wins;
  # otherwise reuse the password from an existing app.ini so re-runs never
  # desync the credential; otherwise generate it exactly once and record it
  # in the install receipt.
  if [[ -z "${FORGEJO_DB_PASSWORD}" && -f /etc/forgejo/app.ini ]]; then
    FORGEJO_DB_PASSWORD="$(ini_get /etc/forgejo/app.ini database PASSWD || true)"
    [[ -n "${FORGEJO_DB_PASSWORD}" ]] && FORGEJO_DB_PASSWORD_SOURCE="existing"
  fi
  if [[ -z "${FORGEJO_DB_PASSWORD}" ]]; then
    FORGEJO_DB_PASSWORD="$(openssl rand -hex 24)"
    FORGEJO_DB_PASSWORD_SOURCE="generated"
  fi
  if runuser -u postgres -- psql -tAc \
       "SELECT 1 FROM pg_roles WHERE rolname = '${FORGEJO_DB_USER}'" | grep -q 1; then
    info "PostgreSQL role ${FORGEJO_DB_USER} already exists; re-asserting password."
    note_satisfied
  else
    ok "Creating PostgreSQL role ${FORGEJO_DB_USER}."
    note_changed
  fi
  # FORGEJO_DB_USER is constrained by is_valid_forgejo_name but may contain
  # hyphens, so it is double-quoted as a SQL identifier; the password is
  # single-quote doubled for SQL-literal safety.
  _fj_pass_sql="${FORGEJO_DB_PASSWORD//\'/\'\'}"
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<PSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${FORGEJO_DB_USER}') THEN
    CREATE ROLE "${FORGEJO_DB_USER}" LOGIN PASSWORD '${_fj_pass_sql}';
  ELSE
    ALTER ROLE "${FORGEJO_DB_USER}" WITH LOGIN PASSWORD '${_fj_pass_sql}';
  END IF;
END
\$\$;
PSQL
  unset _fj_pass_sql
  if runuser -u postgres -- psql -tAc \
       "SELECT 1 FROM pg_database WHERE datname = '${FORGEJO_DB_NAME}'" | grep -q 1; then
    info "PostgreSQL database ${FORGEJO_DB_NAME} already exists."
    note_satisfied
  else
    runuser -u postgres -- createdb -O "${FORGEJO_DB_USER}" "${FORGEJO_DB_NAME}"
    ok "Created PostgreSQL database ${FORGEJO_DB_NAME} (owner ${FORGEJO_DB_USER})."
    note_changed
  fi

  section "Write Forgejo configuration"

  # An install or upgrade may replace app.ini and migrate the database. Stop
  # an existing daemon first so it cannot race either operation or use a
  # half-updated schema. Start it again only after migration and admin setup.
  if [[ -f /etc/systemd/system/forgejo.service ]]; then
    systemctl stop forgejo.service \
      || die "Could not stop Forgejo safely before migration; check systemctl status forgejo and journalctl -u forgejo." 1
  fi

  # Reuse existing secrets from app.ini so a re-run never rotates them
  # behind the running service; generate them exactly once otherwise.
  _fj_secret_key=""; _fj_internal_token=""; _fj_jwt_secret=""
  _fj_lfs_jwt_secret=""
  if [[ -f /etc/forgejo/app.ini ]]; then
    _fj_secret_key="$(ini_get /etc/forgejo/app.ini security SECRET_KEY || true)"
    _fj_internal_token="$(ini_get /etc/forgejo/app.ini security INTERNAL_TOKEN || true)"
    _fj_jwt_secret="$(ini_get /etc/forgejo/app.ini oauth2 JWT_SECRET || true)"
    _fj_lfs_jwt_secret="$(ini_get /etc/forgejo/app.ini server LFS_JWT_SECRET || true)"
  fi
  if [[ -n "${_fj_jwt_secret}" ]] && ! is_valid_forgejo_jwt_secret "${_fj_jwt_secret}"; then
    warn "Existing Forgejo OAuth2 JWT secret is malformed; regenerating it."
    _fj_jwt_secret=""
  fi
  if [[ -n "${_fj_lfs_jwt_secret}" ]] && ! is_valid_forgejo_jwt_secret "${_fj_lfs_jwt_secret}"; then
    warn "Existing Forgejo LFS JWT secret is malformed; regenerating it."
    _fj_lfs_jwt_secret=""
  fi
  [[ -n "${_fj_secret_key}" ]]     || _fj_secret_key="$(/usr/local/bin/forgejo generate secret SECRET_KEY)"
  [[ -n "${_fj_internal_token}" ]] || _fj_internal_token="$(/usr/local/bin/forgejo generate secret INTERNAL_TOKEN)"
  [[ -n "${_fj_jwt_secret}" ]]     || _fj_jwt_secret="$(/usr/local/bin/forgejo generate secret JWT_SECRET)"
  [[ -n "${_fj_lfs_jwt_secret}" ]] || _fj_lfs_jwt_secret="$(/usr/local/bin/forgejo generate secret JWT_SECRET)"
  _fj_domain="$(hostname -f 2>/dev/null || hostname)"
  _fj_tmp="$(mktemp)"
  cat > "${_fj_tmp}" <<EOF
; Managed by ${SCRIPT_NAME} (Ubuntu Zombie optional component).
; Re-runs preserve the generated secrets below; edit with care.
APP_NAME = Forgejo
RUN_USER = git
WORK_PATH = /var/lib/forgejo

[database]
DB_TYPE = postgres
HOST = 127.0.0.1:5432
NAME = ${FORGEJO_DB_NAME}
USER = ${FORGEJO_DB_USER}
PASSWD = ${FORGEJO_DB_PASSWORD}

[server]
; Normal network access: the forge serves people on the LAN, unlike the
; loopback-only chat UI.
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${FORGEJO_HTTP_PORT}
DOMAIN = ${_fj_domain}
ROOT_URL = http://${_fj_domain}:${FORGEJO_HTTP_PORT}/
LFS_START_SERVER = true
LFS_JWT_SECRET = ${_fj_lfs_jwt_secret}

[repository]
ROOT = /var/lib/forgejo/data/forgejo-repositories

[lfs]
PATH = /var/lib/forgejo/data/lfs

[security]
INSTALL_LOCK = true
SECRET_KEY = ${_fj_secret_key}
INTERNAL_TOKEN = ${_fj_internal_token}

[oauth2]
JWT_SECRET = ${_fj_jwt_secret}

[service]
DISABLE_REGISTRATION = true

[actions]
ENABLED = true
EOF
  if [[ -f /etc/forgejo/app.ini ]] && cmp -s "${_fj_tmp}" /etc/forgejo/app.ini; then
    info "Forgejo configuration already up to date."
    rm -f "${_fj_tmp}"
    note_satisfied
  else
    install -m 640 -o root -g git "${_fj_tmp}" /etc/forgejo/app.ini
    rm -f "${_fj_tmp}"
    ok "Wrote /etc/forgejo/app.ini (secrets generated once, never logged)."
    note_changed
  fi
  # FORGEJO_DB_PASSWORD is kept until the finish receipt is written so a
  # generated value can be recorded there; other secrets are one-shot.
  unset _fj_secret_key _fj_internal_token _fj_jwt_secret _fj_lfs_jwt_secret

  section "Initialize Forgejo database and service"

  install -m 644 "${PAYLOAD_DIR}/systemd/forgejo.service" \
    /etc/systemd/system/forgejo.service
  systemctl daemon-reload
  # Forgejo persists newly introduced generated settings while loading an
  # installed configuration. Allow that only for the stopped, one-shot
  # migration command, then restore the standard locked-down permissions even
  # when migration fails. This also makes upgrades resilient to future
  # Forgejo settings without leaving the running daemon able to rewrite config.
  chown root:git /etc/forgejo /etc/forgejo/app.ini
  chmod 660 /etc/forgejo/app.ini
  _fj_migrate_status=0
  runuser -u git -- /usr/local/bin/forgejo migrate \
    --config /etc/forgejo/app.ini --work-path /var/lib/forgejo \
    || _fj_migrate_status=$?
  chown root:git /etc/forgejo /etc/forgejo/app.ini
  chmod 750 /etc/forgejo
  chmod 640 /etc/forgejo/app.ini
  if (( _fj_migrate_status != 0 )); then
    die "Forgejo database migration failed (exit ${_fj_migrate_status}); config permissions were restored. Transcript: ${LOG_FILE}" 1
  fi
  unset _fj_migrate_status

  if runuser -u git -- /usr/local/bin/forgejo admin user list --admin \
       --config /etc/forgejo/app.ini --work-path /var/lib/forgejo 2>/dev/null \
       | awk '{print $2}' | grep -qx "${FORGEJO_ADMIN_USER}"; then
    info "Forgejo admin ${FORGEJO_ADMIN_USER} already exists."
    if [[ "${FORGEJO_ADMIN_PASSWORD_SOURCE}" == "operator" ]]; then
      info "FORGEJO_ADMIN_PASSWORD ignored: the admin account already exists."
    fi
    FORGEJO_ADMIN_PASSWORD=""
    FORGEJO_ADMIN_PASSWORD_SOURCE=""
    note_satisfied
  else
    if [[ "${FORGEJO_ADMIN_PASSWORD_SOURCE}" != "operator" ]]; then
      FORGEJO_ADMIN_PASSWORD="$(openssl rand -base64 18)"
      FORGEJO_ADMIN_PASSWORD_SOURCE="generated"
    fi
    # A generated password must be changed on first sign-in; an
    # operator-chosen one is taken as deliberate and kept as-is.
    _fj_must_change=()
    [[ "${FORGEJO_ADMIN_PASSWORD_SOURCE}" == "generated" ]] \
      && _fj_must_change=(--must-change-password)
    runuser -u git -- /usr/local/bin/forgejo admin user create \
      --config /etc/forgejo/app.ini --work-path /var/lib/forgejo \
      --admin --username "${FORGEJO_ADMIN_USER}" \
      --email "${FORGEJO_ADMIN_EMAIL}" \
      --password "${FORGEJO_ADMIN_PASSWORD}" "${_fj_must_change[@]}"
    ok "Created Forgejo admin ${FORGEJO_ADMIN_USER}."
    if [[ "${FORGEJO_ADMIN_PASSWORD_SOURCE}" == "generated" ]]; then
      printf '\n%s  Forgejo admin credentials (also recorded in the install receipt):%s\n' "${C_BOLD}" "${C_RESET}"
      printf '    username: %s\n' "${FORGEJO_ADMIN_USER}"
      printf '    password: %s\n' "${FORGEJO_ADMIN_PASSWORD}"
      printf '  You must change it on first sign-in at http://%s:%s/\n\n' "${_fj_domain}" "${FORGEJO_HTTP_PORT}"
    fi
    unset _fj_must_change
    note_changed
  fi
  systemctl enable --now forgejo.service \
    || die "Forgejo service failed to start; see journalctl -u forgejo." 1
  # retry() waits 2, 4, 8, 16, then 32 seconds between these six probes;
  # each request is capped at 5s.
  if ! retry 6 2 -- curl -fsS --max-time 5 -o /dev/null \
       "http://127.0.0.1:${FORGEJO_HTTP_PORT}/api/healthz"; then
    systemctl disable --now forgejo.service >/dev/null \
      || warn "Could not disable the unhealthy Forgejo service."
    die "Forgejo started but did not become healthy; it was stopped. See journalctl -u forgejo." 1
  fi
  ok "Forgejo is healthy at http://${_fj_domain}:${FORGEJO_HTTP_PORT}/."
  # option-sections: forgejo end

  if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    # option-sections: forgejo-runner begin
    section "Install Forgejo runner"

    warn "Co-locating the Actions runner with the forge is contrary to upstream guidance; enabled deliberately."
    apt_install docker.io
    systemctl enable --now docker >/dev/null 2>&1 \
      || die "Docker Engine failed to start; see journalctl -u docker." 1
    if id forgejo-runner >/dev/null 2>&1; then
      info "User forgejo-runner already exists."
      note_satisfied
    else
      adduser --system --group --home /var/lib/forgejo-runner \
        --shell /bin/bash --gecos "Forgejo Actions runner" forgejo-runner
      ok "Created system user forgejo-runner."
      note_changed
    fi
    usermod -aG docker forgejo-runner
    install -d -m 750 -o forgejo-runner -g forgejo-runner /var/lib/forgejo-runner
    if [[ -n "${FORGEJO_RUNNER_VERSION}" ]]; then
      _runner_version="${FORGEJO_RUNNER_VERSION}"
      info "Forgejo runner release pinned to ${_runner_version}."
    else
      _runner_version="$(codeberg_latest_release forgejo/runner)" \
        || die "Could not resolve the latest forgejo-runner release from codeberg.org (pin FORGEJO_RUNNER_VERSION to proceed)." 66
      info "Latest forgejo-runner release: ${_runner_version}."
    fi
    _installed_runner=""
    if [[ -x /usr/local/bin/forgejo-runner ]]; then
      _installed_runner="$(/usr/local/bin/forgejo-runner --version 2>/dev/null \
        | awk '{print $3}' | sed 's/^v//' || true)"
    fi
    if [[ "${_installed_runner}" == "${_runner_version}" ]]; then
      info "forgejo-runner ${_runner_version} already installed."
      note_satisfied
    else
      _runner_url="https://codeberg.org/forgejo/runner/releases/download/v${_runner_version}/forgejo-runner-${_runner_version}-linux-${FORGEJO_ARCH}"
      _runner_tmp="$(mktemp)"
      codeberg_fetch_verified "${_runner_url}" "${_runner_tmp}" \
        || { rm -f "${_runner_tmp}"; die "Failed to download forgejo-runner ${_runner_version}." 66; }
      install -m 0755 -o root -g root "${_runner_tmp}" /usr/local/bin/forgejo-runner
      rm -f "${_runner_tmp}"
      ok "Installed forgejo-runner ${_runner_version} (checksum verified)."
      note_changed
    fi

    section "Register Forgejo runner"

    if [[ -f /var/lib/forgejo-runner/.runner ]]; then
      info "Runner already registered; skipping registration."
      note_satisfied
    else
      _runner_token="$(runuser -u git -- /usr/local/bin/forgejo \
        --config /etc/forgejo/app.ini --work-path /var/lib/forgejo \
        actions generate-runner-token)"
      runuser -u forgejo-runner -- bash -c \
        "cd /var/lib/forgejo-runner && /usr/local/bin/forgejo-runner register \
           --no-interactive \
           --instance 'http://127.0.0.1:${FORGEJO_HTTP_PORT}/' \
           --token '${_runner_token}' \
           --name '$(hostname)' \
           --labels '${FORGEJO_RUNNER_LABELS}'"
      unset _runner_token
      ok "Runner registered against 127.0.0.1:${FORGEJO_HTTP_PORT} with labels: ${FORGEJO_RUNNER_LABELS}"
      note_changed
    fi
    install -m 644 "${PAYLOAD_DIR}/systemd/forgejo-runner.service" \
      /etc/systemd/system/forgejo-runner.service
    systemctl daemon-reload
    systemctl enable --now forgejo-runner.service \
      || warn "forgejo-runner service did not start; see journalctl -u forgejo-runner."
    ok "Forgejo Actions runner installed and enabled."
    # option-sections: forgejo-runner end
  fi
elif [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
  warn "ZOMBIE_INSTALL_FORGEJO_RUNNER=1 has no effect without ZOMBIE_INSTALL_FORGEJO=1; skipping the runner."
fi

# ---------------------------------------------------------------------------
# Deploy payload: chat service, helpers, policy, systemd, logrotate.
# ---------------------------------------------------------------------------

section "Deploy the agent runtime"

if [[ ! -d "${PAYLOAD_DIR}" ]]; then
  die "Payload directory ${PAYLOAD_DIR} not found. Re-clone the repository." 1
fi

# Chat service source.
install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${ZOMBIE_DIR}/agent" "${ZOMBIE_DIR}/agent/templates"
for f in server.py providers.py policy.py audit.py runner.py history.py tools.py pi_mono.py skill_loader.py auth.py lifecycle.py examples.md; do
  install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${PAYLOAD_DIR}/agent/${f}" "${ZOMBIE_DIR}/agent/${f}"
done
# The pi-ai bridge and its version pin travel with the Python sources
# so providers.py can find them at the default path. Bridge is
# read-only; only root mutates the agent tree.
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-ai-bridge.mjs" "${ZOMBIE_DIR}/agent/pi-ai-bridge.mjs"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-ai.version" "${ZOMBIE_DIR}/agent/pi-ai.version"
# Deploy the payload VERSION alongside the agent tree so the chat
# service can report it via /api/version (the /version chat command).
if [[ -f "${REPO_ROOT}/VERSION" ]]; then
  install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${REPO_ROOT}/VERSION" "${ZOMBIE_DIR}/VERSION"
fi
# pi-mono bridge + version pin live alongside the pi-ai ones for the
# same reasons.
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-mono-bridge.mjs" "${ZOMBIE_DIR}/agent/pi-mono-bridge.mjs"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-mono.version" "${ZOMBIE_DIR}/agent/pi-mono.version"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/index.html" "${ZOMBIE_DIR}/agent/templates/index.html"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/settings.json.tmpl" "${ZOMBIE_DIR}/agent/templates/settings.json.tmpl"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" "${ZOMBIE_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl"

# Initialise the Time-to-Live kill switch now that lifecycle.py is deployed.
# Every install starts (or restarts) the countdown with a fresh tombstone.
init_lifecycle_state

# Render pi-mono runtime configs into /opt/ai-zombie/pi/. Root-owned,
# world-readable; the chat service reads them but does not need to
# mutate them.
install -d -m 755 -o root -g root "${ZOMBIE_DIR}/pi"
install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${ZOMBIE_DIR}/state/logs" "${ZOMBIE_DIR}/state/pi-mono-sessions"
install -m 644 "${PAYLOAD_DIR}/agent/templates/settings.json.tmpl" \
  "${ZOMBIE_DIR}/pi/settings.json"
# Render APPEND_SYSTEM.md via the chat-service helper so a single
# implementation is the source of truth for the rendered text.
if (cd "${PAYLOAD_DIR}/agent" && python3 server.py --render-append-system) \
       > "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md.tmp" 2>/dev/null; then
  install -m 644 "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md.tmp" \
    "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md"
  rm -f "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md.tmp"
else
  # Fallback: substitute placeholders from the template directly.
  rm -f "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md.tmp"
  sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
      -e "s|__FACTS__|hostname=$(hostname) os=$(. /etc/os-release && echo "${PRETTY_NAME}")|g" \
      "${PAYLOAD_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" \
    | install -m 644 /dev/stdin "${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md"
fi

# Snapshot the conversations DB *before* the chat-service binary runs
# the schema migration. The migration is additive (forward-only,
# behind PRAGMA user_version) but a snapshot lets operators roll back
# without losing history. The bak file name embeds the timestamp.
if [[ -f "${ZOMBIE_DIR}/state/conversations.db" ]]; then
  _ts="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "${ZOMBIE_DIR}/state/conversations.db" \
        "${ZOMBIE_DIR}/state/conversations.db.bak.${_ts}" \
    || warn "Could not snapshot conversations.db (continuing)."
fi

section "Install policy and operator tools"

# Operator helpers.
for f in audit-recent health-check collect-diagnostics secrets-edit zombie-chat setup-agent-venv verify-release; do
  install -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${PAYLOAD_DIR}/bin/${f}" "${ZOMBIE_DIR}/bin/${f}"
done
# Also make secrets-edit and audit-recent reachable on PATH.
ln -sf "${ZOMBIE_DIR}/bin/zombie-chat"          /usr/local/bin/zombie-chat
ln -sf "${ZOMBIE_DIR}/bin/audit-recent"         /usr/local/bin/audit-recent
ln -sf "${ZOMBIE_DIR}/bin/secrets-edit"         /usr/local/bin/secrets-edit
ln -sf "${ZOMBIE_DIR}/bin/health-check"         /usr/local/bin/zombie-health
ln -sf "${ZOMBIE_DIR}/bin/collect-diagnostics"  /usr/local/bin/zombie-diagnostics

# Policy.
if [[ ! -f "${ZOMBIE_ETC}/policy.yaml" ]]; then
  install -m 644 "${PAYLOAD_DIR}/etc/policy.yaml" "${ZOMBIE_ETC}/policy.yaml"
  ok "Installed default policy at ${ZOMBIE_ETC}/policy.yaml."
else
  info "Preserving existing ${ZOMBIE_ETC}/policy.yaml."
fi

# Ship the built-in skill catalogue to /opt/ai-zombie/skills/
# (root-owned, world-readable) and provision the operator-extensible
# /etc/ubuntu-zombie/skills.d/ tree with the same mode/owner contract
# as policy.yaml. Skills are static markdown read at chat-turn time;
# the loader never mutates them.
install -d -m 755 -o root -g root "${ZOMBIE_DIR}/skills"
if [[ -d "${PAYLOAD_DIR}/agent/skills" ]]; then
  shopt -s nullglob
  for f in "${PAYLOAD_DIR}/agent/skills/"*.md; do
    install -m 644 -o root -g root "${f}" "${ZOMBIE_DIR}/skills/$(basename "${f}")"
  done
  shopt -u nullglob
  ok "Installed built-in skills to ${ZOMBIE_DIR}/skills/."
fi
install -d -m 755 -o root -g root "${ZOMBIE_ETC}/skills.d"

# logrotate. The shipped file uses the ``__AGENT_USER__`` placeholder
# so the `create` line names the operator-chosen account (FIX-3-06).
sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
    "${PAYLOAD_DIR}/logrotate/ubuntu-zombie" \
    | install -m 644 /dev/stdin /etc/logrotate.d/ubuntu-zombie

# Audit log seed file (so chat service can open it without race).
if [[ ! -f "${ZOMBIE_LOG_DIR}/audit.log" ]]; then
  install -m 640 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${ZOMBIE_LOG_DIR}/audit.log"
fi

section "Enable background services"

# systemd units. The shipped unit files use the literal placeholders
# `__AGENT_USER__` and `__AGENT_HOME__` so the chosen account name is
# substituted in at install time. This keeps the units valid for the
# default `zombie` account and any operator-chosen override.
render_unit() {
  local src="$1" dest="$2"
  # NOTE (FIX-1-17): The `s|…|${AGENT_USER}|g` substitution is only safe
  # because `is_supported_agent_username` (see validate_config) forbids the
  # sed-special characters `|`, `&`, and `\` in the username. If that
  # validator is ever relaxed, escape AGENT_USER/AGENT_HOME for sed here.
  sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
      -e "s|__AGENT_HOME__|${AGENT_HOME}|g" \
      -e "s|__ZOMBIE_DIR__|${ZOMBIE_DIR}|g" \
      "${src}" | install -m 644 /dev/stdin "${dest}"
}
render_unit "${PAYLOAD_DIR}/systemd/ubuntu-zombie-chat.service"   /etc/systemd/system/ubuntu-zombie-chat.service
render_unit "${PAYLOAD_DIR}/systemd/ubuntu-zombie-health.service" /etc/systemd/system/ubuntu-zombie-health.service
install -m 644 "${PAYLOAD_DIR}/systemd/ubuntu-zombie-health.timer"   /etc/systemd/system/ubuntu-zombie-health.timer
systemctl daemon-reload
systemctl enable --now ubuntu-zombie-chat.service || warn "Chat service did not start; see journalctl -u ubuntu-zombie-chat"
systemctl enable --now ubuntu-zombie-health.timer || true
ok "Chat service installed and enabled."

# ---------------------------------------------------------------------------
# Verification script
# ---------------------------------------------------------------------------

section "Install health checks"

cat > "${ZOMBIE_DIR}/bin/verify" <<EOF
#!/usr/bin/env bash
set -uo pipefail

ZOMBIE_DIR="${ZOMBIE_DIR}"
AGENT_USER="${AGENT_USER}"
AGENT_HOME="${AGENT_HOME}"
PI_AI_VERSION="${PI_AI_VERSION}"
PI_MONO_VERSION="${PI_MONO_VERSION}"

JSON="\${ZOMBIE_JSON:-0}"

if [[ -t 1 && "\${JSON}" != "1" ]]; then
  C_RESET=\$'\\033[0m'; C_RED=\$'\\033[31m'; C_GREEN=\$'\\033[32m'; C_BOLD=\$'\\033[1m'; C_YEL=\$'\\033[33m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_BOLD=""; C_YEL=""
fi

PASS=0; FAIL=0
JSON_ITEMS=""

json_escape() {
  local s="\$1"
  s="\${s//\\\\/\\\\\\\\}"
  s="\${s//\\"/\\\\\\"}"
  printf '%s' "\${s}"
}

record() {
  # record <ok|fail|skip> <label>
  local st="\$1" label="\$2"
  case "\${st}" in
    ok)   PASS=\$((PASS+1)) ;;
    fail) FAIL=\$((FAIL+1)) ;;
  esac
  local item
  item="{\\"status\\": \\"\${st}\\", \\"label\\": \\"\$(json_escape "\${label}")\\"}"
  if [[ -z "\${JSON_ITEMS}" ]]; then JSON_ITEMS="\${item}"; else JSON_ITEMS="\${JSON_ITEMS},\${item}"; fi
}

# hd <text> — print a human-readable group header (suppressed in JSON mode).
hd() { [[ "\${JSON}" == "1" ]] || printf '%s\\n' "\$1"; }

check() {
  local label="\$1"; shift
  if "\$@" >/dev/null 2>&1; then
    record ok "\${label}"
    [[ "\${JSON}" == "1" ]] || printf '  %s[ok]%s %s\\n' "\${C_GREEN}" "\${C_RESET}" "\${label}"
  else
    record fail "\${label}"
    [[ "\${JSON}" == "1" ]] || printf '  %s[x]%s  %s\\n' "\${C_RED}" "\${C_RESET}" "\${label}"
  fi
}

if [[ -f \${ZOMBIE_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source \${ZOMBIE_DIR}/secrets/env
  set +a
fi

[[ "\${JSON}" == "1" ]] || printf '\\n%s== ubuntu-zombie verify ==%s\\n' "\${C_BOLD}" "\${C_RESET}"
[[ "\${JSON}" == "1" ]] || echo

hd "User and sudo:"
check "running as \${AGENT_USER}"          test "\$(id -un)" = "\${AGENT_USER}"
check "passwordless sudo"                  sudo -n true
[[ "\${JSON}" == "1" ]] || echo

hd "Network and services:"
check "loopback chat port configured"         test -n "${ZOMBIE_CHAT_PORT:-${CHAT_PORT}}"
[[ "\${JSON}" == "1" ]] || echo

hd "Runtime:"
check "Python venv exists"                 test -x \${AGENT_HOME}/agent-env/bin/python
check "node and tsc present"               bash -c "command -v node && command -v tsc"
check "pi-ai bridge deployed"              test -r \${ZOMBIE_DIR}/agent/pi-ai-bridge.mjs
check "pi-ai installed (any version)"      bash -c "npm ls -g --depth=0 @earendil-works/pi-ai >/dev/null"
check "pi-ai pinned to \${PI_AI_VERSION}"     bash -c "npm ls -g --depth=0 @earendil-works/pi-ai 2>/dev/null | grep -q '@earendil-works/pi-ai@\${PI_AI_VERSION}'"
check "pi-mono bridge deployed"            test -r \${ZOMBIE_DIR}/agent/pi-mono-bridge.mjs
check "pi-mono installed (any version)"    bash -c "npm ls -g --depth=0 @earendil-works/pi-coding-agent >/dev/null"
check "pi-mono pinned to \${PI_MONO_VERSION}" bash -c "npm ls -g --depth=0 @earendil-works/pi-coding-agent 2>/dev/null | grep -q '@earendil-works/pi-coding-agent@\${PI_MONO_VERSION}'"
check "pi-mono settings rendered"          test -r \${ZOMBIE_DIR}/pi/settings.json
check "pi-mono APPEND_SYSTEM rendered"     test -r \${ZOMBIE_DIR}/pi/APPEND_SYSTEM.md
check "pi-mono log dir present"            test -d \${ZOMBIE_DIR}/state/logs
check "built-in skills directory present"  test -d \${ZOMBIE_DIR}/skills
check "skill apt.md deployed"              test -r \${ZOMBIE_DIR}/skills/apt.md
check "skill systemd.md deployed"          test -r \${ZOMBIE_DIR}/skills/systemd.md
check "operator skills.d/ present"         test -d /etc/ubuntu-zombie/skills.d
check "agent tools.py compiles"            \${AGENT_HOME}/agent-env/bin/python -m py_compile \${ZOMBIE_DIR}/agent/tools.py
check "agent pi_mono.py compiles"          \${AGENT_HOME}/agent-env/bin/python -m py_compile \${ZOMBIE_DIR}/agent/pi_mono.py
check "agent skill_loader.py compiles"     \${AGENT_HOME}/agent-env/bin/python -m py_compile \${ZOMBIE_DIR}/agent/skill_loader.py
[[ "\${JSON}" == "1" ]] || echo

hd "Chat service and policy:"
check "policy.yaml present"                test -r /etc/ubuntu-zombie/policy.yaml
check "audit log writable for ${AGENT_USER}"  bash -c "test -w /var/log/ubuntu-zombie/audit.log || sudo -n test -w /var/log/ubuntu-zombie/audit.log"
check "ubuntu-zombie-chat.service active"  systemctl is-active ubuntu-zombie-chat.service
check "chat listening on 127.0.0.1:${CHAT_PORT}" bash -c "ss -ltn 'sport = :${CHAT_PORT}' | grep -q 127.0.0.1"
check "agent server.py compiles"           \${AGENT_HOME}/agent-env/bin/python -m py_compile \${ZOMBIE_DIR}/agent/server.py
[[ "\${JSON}" == "1" ]] || echo

# Optional component: Forgejo. Detected from the installed config so the
# checks run (or stay silent) regardless of the caller's environment.
if sudo -n test -f /etc/forgejo/app.ini 2>/dev/null; then
  FORGEJO_PORT="\$(sudo -n awk -F' = ' '\$0=="[server]"{s=1;next} /^\\[/{s=0} s && \$1=="HTTP_PORT"{print \$2; exit}' /etc/forgejo/app.ini 2>/dev/null)"
  FORGEJO_PORT="\${FORGEJO_PORT:-3000}"
  FORGEJO_DB="\$(sudo -n awk -F' = ' '\$0=="[database]"{s=1;next} /^\\[/{s=0} s && \$1=="NAME"{print \$2; exit}' /etc/forgejo/app.ini 2>/dev/null)"
  FORGEJO_DB="\${FORGEJO_DB:-forgejo}"
  hd "Forgejo (optional component):"
  check "forgejo binary present"             test -x /usr/local/bin/forgejo
  check "forgejo reports a version"          /usr/local/bin/forgejo --version
  check "postgresql active"                  systemctl is-active postgresql
  check "forgejo database \${FORGEJO_DB} present" bash -c "sudo -n runuser -u postgres -- psql -tAc \"SELECT 1 FROM pg_database WHERE datname = '\${FORGEJO_DB}'\" | grep -q 1"
  check "forgejo config directory root:git 750" bash -c "test \"\$(sudo -n stat -c '%U:%G %a' /etc/forgejo)\" = 'root:git 750'"
  check "forgejo app.ini root:git 640"       bash -c "test \"\$(sudo -n stat -c '%U:%G %a' /etc/forgejo/app.ini)\" = 'root:git 640'"
  check "forgejo.service active"             systemctl is-active forgejo.service
  check "forgejo healthy on 127.0.0.1:\${FORGEJO_PORT}" curl -fsS -m 5 -o /dev/null "http://127.0.0.1:\${FORGEJO_PORT}/api/healthz"
  if [[ -f /etc/systemd/system/forgejo-runner.service ]]; then
    check "forgejo-runner.service active"    systemctl is-active forgejo-runner.service
    check "runner registration present"      sudo -n test -f /var/lib/forgejo-runner/.runner
  fi
  [[ "\${JSON}" == "1" ]] || echo
fi

if [[ "\${JSON}" == "1" ]]; then
  printf '{"tool": "verify", "passed": %d, "failed": %d, "checks": [%s]}\\n' "\$PASS" "\$FAIL" "\${JSON_ITEMS}"
  [[ \$FAIL -gt 0 ]] && exit 1
  exit 0
fi

echo
printf '%sResult:%s %d passed, %d failed.\\n' "\${C_BOLD}" "\${C_RESET}" "\$PASS" "\$FAIL"

if [[ \$FAIL -gt 0 ]]; then
  echo
  echo "Tips:"
  echo "  - If the chat service is not active: sudo systemctl status ubuntu-zombie-chat"
  exit 1
fi
EOF

chmod +x "${ZOMBIE_DIR}/bin/verify"
chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/bin/verify"
ln -sf "${ZOMBIE_DIR}/bin/verify" /usr/local/bin/zombie-verify

# ---------------------------------------------------------------------------
# First-run status summary
# ---------------------------------------------------------------------------

section "Verify the installation"

PROVIDER_OK=0
if grep -Eq '^(OPENAI|ANTHROPIC|GEMINI|XAI|OPENROUTER|MISTRAL|GROQ)_API_KEY=..+' "${ZOMBIE_DIR}/secrets/env" 2>/dev/null; then
  PROVIDER_OK=1
fi

CHAT_OK=0
if systemctl is-active --quiet ubuntu-zombie-chat.service; then
  CHAT_OK=1
fi

bullet() {
  local ok="$1" label="$2"
  if [[ "${ok}" == "1" ]]; then
    status ok "${label}"
  else
    status warn "${label}"
  fi
}

bullet "${PROVIDER_OK}"  "Provider token present in secrets/env"
bullet "${CHAT_OK}"      "Chat service running on 127.0.0.1:${CHAT_PORT}"
if [[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]]; then
  FORGEJO_OK=0
  systemctl is-active --quiet forgejo.service && FORGEJO_OK=1
  bullet "${FORGEJO_OK}" "Forgejo ${FORGEJO_RESOLVED_VERSION:-} running on port ${FORGEJO_HTTP_PORT} (all interfaces)"
  if [[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    RUNNER_OK=0
    systemctl is-active --quiet forgejo-runner.service && RUNNER_OK=1
    bullet "${RUNNER_OK}" "Forgejo Actions runner registered and running"
  fi
fi
echo

NEXT_STEP=""
if [[ "${PROVIDER_OK}" != "1" ]]; then
  NEXT_STEP="sudo ${ZOMBIE_DIR}/bin/secrets-edit   # paste any of OPENAI/ANTHROPIC/GEMINI/XAI/OPENROUTER/MISTRAL/GROQ _API_KEY"
elif [[ "${CHAT_OK}" != "1" ]]; then
  NEXT_STEP="sudo systemctl start ubuntu-zombie-chat.service"
else
  NEXT_STEP="sudo reboot"
fi

INSTALL_DURATION="$(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")"
cat <<EOF

${C_GREEN}${C_BOLD}Install complete in ${INSTALL_DURATION}.${C_RESET}
Next:    ${C_BOLD}${NEXT_STEP}${C_RESET}
Chat:    http://127.0.0.1:${CHAT_PORT}/ (localhost only, after reboot)
Check:   ${ZOMBIE_DIR}/bin/verify  ·  ${ZOMBIE_DIR}/bin/audit-recent
Records: ${LOG_FILE}
         $([[ "${ZOMBIE_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo "receipt disabled")  ·  ${ZOMBIE_ETC}/policy.yaml
$([[ "${ZOMBIE_INSTALL_FORGEJO}" == "1" ]] && printf 'Forgejo: http://<host>:%s/ (all interfaces%s)\n' "${FORGEJO_HTTP_PORT}" "$([[ "${ZOMBIE_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo ', runner enabled')")
Remove:  sudo ${SCRIPT_DIR}/uninstall.sh --dry-run
EOF

if [[ "${NEXT_STEP}" != "sudo reboot" ]]; then
  info "Reboot after completing the next step: sudo reboot"
fi

if (( STEPS_SATISFIED + STEPS_CHANGED > 0 )); then
  info "Idempotent steps: ${STEPS_SATISFIED} already satisfied, ${STEPS_CHANGED} applied this run."
fi

# Finalise the install receipt with the outcome of this run.
write_receipt_finish
