#!/usr/bin/env bash
#
# install.sh
# ----------
# Beep: baseline installer + chat service.
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
#   BEEP_NONINTERACTIVE=1     skip prompts for fully unattended installs.
#   BEEP_USER="beep"        name of the local account created as the
#                               operating identity of the AI Systems
#                               Administrator. Defaults to `beep`. The
#                               legacy name `AGENT_USER` is still
#                               accepted for backward compatibility.
#   BEEP_CHAT_PORT=7878       loopback-only chat UI port.

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

AGENT_USER="${BEEP_USER:-${AGENT_USER:-beep}}"
AGENT_HOME="/home/${AGENT_USER}"
BEEP_DIR="${BEEP_DIR:-/opt/beep}"
BEEP_ETC="/etc/beep"
BEEP_LOG_DIR="/var/log/beep"
CHAT_PORT="${BEEP_CHAT_PORT:-7878}"
LOG_FILE="${LOG_FILE:-/var/log/beep-install.log}"

# Install receipt: a human-readable record of every parameter, written once
# when the install starts and finalised with the outcome when it finishes.
# Set BEEP_RECEIPT=0 to disable, or point BEEP_RECEIPT_FILE elsewhere.
BEEP_RECEIPT="${BEEP_RECEIPT:-1}"
RECEIPT_FILE="${BEEP_RECEIPT_FILE:-${BEEP_LOG_DIR}/install-receipt.txt}"

BEEP_NONINTERACTIVE="${BEEP_NONINTERACTIVE:-0}"

# Beep chat-UI password gate and Time-to-Live (TTL) kill switch.
# The chat service is reachable by every local user on http://127.0.0.1:PORT,
# so it is protected by a shared password (only a PBKDF2 hash is stored in
# secrets/env). The TTL bounds the lifetime of the root-capable agent: once
# it elapses (or the operator runs `/ttl --die`) the beep is permanently
# disabled until its lifecycle state is deliberately reinitialised. Routine
# reinstalls preserve the existing countdown and tombstone.
BEEP_ADMIN_PASSWORD_DEFAULT="braaaains"
ADMIN_PASSWORD="${BEEP_ADMIN_PASSWORD:-}"
# 1 once the operator has explicitly chosen a password (env or prompt), so a
# re-install does not silently overwrite a customised password with the default.
ADMIN_PASSWORD_SET=0
[[ -n "${ADMIN_PASSWORD}" ]] && ADMIN_PASSWORD_SET=1
TTL_DAYS="${BEEP_TTL_DAYS:-7}"

# Local LLM discovery. During an interactive install the script can scan the
# host's IPv4 /24 (all 256 addresses) for an OpenAI-compatible local LLM
# server — LM Studio, Ollama, llama.cpp, etc. — answering on
# http://<ip>:PORT/v1 and offer the models it advertises as the starting
# model. Set BEEP_SKIP_LLM_SCAN=1 to skip the scan, BEEP_LLM_SCAN_PORT to
# probe a different port (default 1234, LM Studio's default), and
# BEEP_LOCAL_LLM_API_KEY to record a non-default key for the local server
# (most ignore it).
BEEP_SKIP_LLM_SCAN="${BEEP_SKIP_LLM_SCAN:-0}"
BEEP_LLM_SCAN_PORT="${BEEP_LLM_SCAN_PORT:-1234}"
BEEP_LOCAL_LLM_API_KEY="${BEEP_LOCAL_LLM_API_KEY:-local}"
# Selection populated by discover_local_llms (empty when none is chosen).
LOCAL_LLM_ENDPOINT=""
LOCAL_LLM_BASE_URL=""
LOCAL_LLM_MODEL=""

# ---------------------------------------------------------------------------
# Optional components ("Beep + Options")
# ---------------------------------------------------------------------------
# Every opt-in component is governed by a BEEP_INSTALL_<COMPONENT> flag
# that defaults to 0, so the baseline install is unchanged unless the
# operator explicitly opts in. Each component follows the same contract:
# validated settings, an entry in the interactive Options menu (item 9 of
# the parameter review), a dry-run stanza, guarded idempotent install
# sections, receipt records, verify/doctor/repair checks, and a reversal
# path in uninstall.sh. Forgejo is the first component; more will follow.
#
# Forgejo: a self-hosted git forge backed by PostgreSQL. Forgejo itself stays
# on loopback; Caddy is the LAN-facing HTTPS endpoint. Optionally a Forgejo
# Actions runner is co-located on the same host using the Docker executor.
BEEP_INSTALL_FORGEJO="${BEEP_INSTALL_FORGEJO:-0}"
BEEP_INSTALL_FORGEJO_RUNNER="${BEEP_INSTALL_FORGEJO_RUNNER:-0}"
BEEP_INSTALL_LLAMA="${BEEP_INSTALL_LLAMA:-0}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_MODEL_ID="${LLAMA_MODEL_ID:-smollm2-360m-instruct-q4_k_m}"
LLAMA_CONTEXT_SIZE="${LLAMA_CONTEXT_SIZE:-2048}"
LLAMA_CPU_THREADS="${LLAMA_CPU_THREADS:-$(nproc 2>/dev/null || echo 1)}"
LLAMA_BOOT="${LLAMA_BOOT:-enabled}"
readonly LLAMA_HEALTH_ATTEMPTS=60
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
# Existing Forgejo and PostgreSQL state is never adopted implicitly. These
# exact-value acknowledgements keep unattended upgrades possible without
# allowing --yes to bypass the two data-safety gates.
FORGEJO_CONFIRM_UPDATE="${FORGEJO_CONFIRM_UPDATE:-}"
FORGEJO_CONFIRM_DATABASE_REUSE="${FORGEJO_CONFIRM_DATABASE_REUSE:-}"
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
FORGEJO_RUNNER_RESOLVED_VERSION=""

# True when at least one optional component is enabled — used to keep the
# default dry-run/receipt/banner output byte-for-byte unchanged otherwise.
any_option_enabled() {
  [[ "${BEEP_INSTALL_FORGEJO}" == "1" \
    || "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" \
    || "${BEEP_INSTALL_LLAMA}" == "1" ]]
}

# One-line label for where an optional-component password will come from,
# shared by the dry-run stanza, options table, and receipt start record.
password_source_label() {
  case "$1" in
    operator) echo 'set by operator, not recorded' ;;
    existing) echo 'reused from host, not recorded' ;;
    generated) echo 'generated, recorded in receipt' ;;
    *) echo 'generated, recorded in receipt' ;;
  esac
}

provider_credential_configured() {
  grep -Eq \
    '^(OPENAI|ANTHROPIC|GEMINI|XAI|OPENROUTER|MISTRAL|GROQ|LMSTUDIO)_API_KEY=..+' \
    "$1" 2>/dev/null
}

model_selection_configured() {
  local key
  for key in BEEP_MODEL BEEP_OPENAI_MODEL BEEP_ANTHROPIC_MODEL \
      BEEP_GEMINI_MODEL BEEP_XAI_MODEL BEEP_MISTRAL_MODEL \
      BEEP_GROQ_MODEL BEEP_OPENROUTER_MODEL; do
    if [[ -v "${key}" && -n "${!key}" ]]; then
      return 0
    fi
  done
  grep -Eq \
    '^[[:space:]]*(export[[:space:]]+)?BEEP_(MODEL|(OPENAI|ANTHROPIC|GEMINI|XAI|MISTRAL|GROQ|OPENROUTER)_MODEL)[[:space:]]*=[[:space:]]*[^[:space:]#]' \
    "${BEEP_DIR}/secrets/env" 2>/dev/null
}

# UX flags (set by argument parsing below; env provides the defaults).
#   ASSUME_YES   skip the interactive "Type YES" confirmation but keep
#                interactive prompts for any still-missing inputs.
#   STRICT       treat preflight warnings as fatal.
#   JSON_OUTPUT  emit machine-readable JSON from verify/doctor.
#   VERBOSE      enable xtrace into the transcript.
ASSUME_YES="${BEEP_ASSUME_YES:-0}"
STRICT="${BEEP_STRICT:-0}"
JSON_OUTPUT=0
VERBOSE="${BEEP_VERBOSE:-0}"
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

llama_catalog_release() {
  awk -F'"' '/"release":[[:space:]]*"/ {print $4; exit}' \
    "${PAYLOAD_DIR}/etc/llama-builds.json"
}

# Known-good versions of the Node bridges. The install path replaces these
# globals with versions resolved from npm before embedding them in the
# deployed version files and verifier. Other subcommands use the source-tree
# values only as informational fallbacks.
read_bridge_version_fallback() {
  local file="$1"
  if [[ -r "${file}" ]]; then
    tr -d '[:space:]' < "${file}"
  else
    printf 'unknown'
  fi
}
PI_AI_VERSION="$(read_bridge_version_fallback "${PAYLOAD_DIR}/agent/pi-ai.version")"
PI_MONO_VERSION="$(read_bridge_version_fallback "${PAYLOAD_DIR}/agent/pi-mono.version")"

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


# Public component targets accepted after the lifecycle verb. Component
# application logic stays in named hooks; shared infrastructure only walks
# this ordered registry.
readonly COMPONENT_BEEP="beep"
readonly COMPONENT_FORGEJO="forgejo"
readonly COMPONENT_FORGEJO_RUNNER="forgejo-runner"
readonly COMPONENT_LLAMA="llama"
readonly COMPONENT_MANIFEST_FORMAT_VERSION="1"
COMPONENT_MANIFEST_DIR="${BEEP_COMPONENT_MANIFEST_DIR:-/var/lib/beep/components}"
TARGET_ARGS=()
SELECTED_COMPONENTS=()
EXPLICIT_TARGETS=0

# shellcheck source=scripts/component-registry.sh
. "${SCRIPT_DIR}/component-registry.sh"

component_validate_beep() { validate_beep_config; }
component_validate_forgejo() { validate_forgejo_config; }
component_validate_forgejo_runner() { validate_forgejo_runner_config; }
component_validate_llama() { validate_llama_config; }
component_review_beep() { review_parameters; }
component_review_forgejo() { review_forgejo_parameters; }
component_review_forgejo_runner() { review_forgejo_runner_parameters; }
component_review_llama() { review_llama_parameters; }
component_dry_run_beep() { print_beep_dry_run; }
component_dry_run_forgejo() { print_forgejo_dry_run; }
component_dry_run_forgejo_runner() { print_forgejo_runner_dry_run; }
component_dry_run_llama() { print_llama_dry_run; }
component_receipt_start_beep() { receipt_start_beep; }
component_receipt_start_forgejo() { receipt_start_forgejo; }
component_receipt_start_forgejo_runner() { receipt_start_forgejo_runner; }
component_receipt_start_llama() { receipt_start_llama; }
component_receipt_finish_beep() { receipt_finish_beep; }
component_receipt_finish_forgejo() { receipt_finish_forgejo; }
component_receipt_finish_forgejo_runner() { receipt_finish_forgejo_runner; }
component_receipt_finish_llama() { receipt_finish_llama; }
component_install_beep() { install_beep; }
component_install_forgejo() { install_forgejo; }
component_install_forgejo_runner() { install_forgejo_runner; }
component_install_llama() { install_llama; }
component_manifest_beep() { write_beep_manifest; }
component_manifest_forgejo() { write_forgejo_manifest; }
component_manifest_forgejo_runner() { write_forgejo_runner_manifest; }
component_manifest_llama() { write_llama_manifest; }
component_final_beep() { final_beep_summary; }
component_final_forgejo() { final_forgejo_summary; }
component_final_forgejo_runner() { final_forgejo_runner_summary; }
component_final_llama() { final_llama_summary; }
component_legacy_beep() { legacy_beep_present; }
component_legacy_forgejo() { legacy_forgejo_present; }
component_legacy_forgejo_runner() { legacy_forgejo_runner_present; }
component_legacy_llama() { legacy_llama_present; }
component_verify_beep() { verify_beep; }
component_verify_forgejo() { verify_forgejo; }
component_verify_forgejo_runner() { verify_forgejo_runner; }
component_verify_llama() { verify_llama; }
component_doctor_beep() { doctor_beep; }
component_doctor_forgejo() { doctor_forgejo; }
component_doctor_forgejo_runner() { doctor_forgejo_runner; }
component_doctor_llama() { doctor_llama; }
component_repair_beep() { repair_beep; }
component_repair_forgejo() { repair_forgejo; }
component_repair_forgejo_runner() { repair_forgejo_runner; }
component_repair_llama() { repair_llama; }
component_phase_count_beep() { count_beep_phases; }
component_phase_count_forgejo() { count_forgejo_phases; }
component_phase_count_forgejo_runner() { count_forgejo_runner_phases; }
component_phase_count_llama() { count_llama_phases; }

register_component "${COMPONENT_BEEP}" "" \
  validate=component_validate_beep review=component_review_beep \
  dry_run=component_dry_run_beep receipt_start=component_receipt_start_beep \
  receipt_finish=component_receipt_finish_beep install=component_install_beep \
  manifest=component_manifest_beep final=component_final_beep \
  legacy=component_legacy_beep verify=component_verify_beep \
  doctor=component_doctor_beep repair=component_repair_beep \
  phase_count=component_phase_count_beep
register_component "${COMPONENT_FORGEJO}" "" \
  validate=component_validate_forgejo review=component_review_forgejo \
  dry_run=component_dry_run_forgejo receipt_start=component_receipt_start_forgejo \
  receipt_finish=component_receipt_finish_forgejo install=component_install_forgejo \
  manifest=component_manifest_forgejo final=component_final_forgejo \
  legacy=component_legacy_forgejo verify=component_verify_forgejo \
  doctor=component_doctor_forgejo repair=component_repair_forgejo \
  phase_count=component_phase_count_forgejo
register_component "${COMPONENT_FORGEJO_RUNNER}" "${COMPONENT_FORGEJO}" \
  validate=component_validate_forgejo_runner review=component_review_forgejo_runner \
  dry_run=component_dry_run_forgejo_runner \
  receipt_start=component_receipt_start_forgejo_runner \
  receipt_finish=component_receipt_finish_forgejo_runner \
  install=component_install_forgejo_runner \
  manifest=component_manifest_forgejo_runner final=component_final_forgejo_runner \
  legacy=component_legacy_forgejo_runner verify=component_verify_forgejo_runner \
  doctor=component_doctor_forgejo_runner repair=component_repair_forgejo_runner \
  phase_count=component_phase_count_forgejo_runner
register_component "${COMPONENT_LLAMA}" "" \
  validate=component_validate_llama review=component_review_llama \
  dry_run=component_dry_run_llama receipt_start=component_receipt_start_llama \
  receipt_finish=component_receipt_finish_llama install=component_install_llama \
  manifest=component_manifest_llama final=component_final_llama \
  legacy=component_legacy_llama verify=component_verify_llama \
  doctor=component_doctor_llama repair=component_repair_llama \
  phase_count=component_phase_count_llama

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


component_manifest_path() {
  local component="$1"
  is_public_component "${component}" || die "Unknown or invalid component name: ${component}. Valid components: $(component_names)" 2
  printf '%s/%s' "${COMPONENT_MANIFEST_DIR}" "${component}"
}

validate_component_manifest_dir() {
  is_safe_absolute_path "${COMPONENT_MANIFEST_DIR}" \
    || die "BEEP_COMPONENT_MANIFEST_DIR must be an absolute safe path." 2
}

ensure_component_manifest_dir() {
  validate_component_manifest_dir
  (( DRY_RUN )) && return 0
  install -d -m 755 -o root -g root "${COMPONENT_MANIFEST_DIR}"
}

write_component_manifest() {
  local component="$1" component_version="${2:-}" suboptions="${3:-}"
  local path tmp
  is_public_component "${component}" || die "Unknown manifest component: ${component}" 2
  ensure_component_manifest_dir
  (( DRY_RUN )) && return 0
  path="$(component_manifest_path "${component}")"
  tmp="${path}.tmp.$$"
  {
    printf 'format=%s\n' "${COMPONENT_MANIFEST_FORMAT_VERSION}"
    printf 'component=%s\n' "${component}"
    printf 'beep_version=%s\n' "${SCRIPT_VERSION}"
    printf 'converged_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'component_version=%s\n' "${component_version}"
    printf 'suboptions=%s\n' "${suboptions}"
  } > "${tmp}"
  chown root:root "${tmp}" 2>/dev/null || true
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${path}"
}

remove_component_manifest() {
  local component="$1" path manifest_parent_dir
  path="$(component_manifest_path "${component}")"
  manifest_parent_dir="$(dirname "${COMPONENT_MANIFEST_DIR}")"
  (( DRY_RUN )) && return 0
  rm -f -- "${path}"
  rmdir --ignore-fail-on-non-empty "${COMPONENT_MANIFEST_DIR}" 2>/dev/null || true
  rmdir --ignore-fail-on-non-empty "${manifest_parent_dir}" 2>/dev/null || true
}

_read_manifest_value() {
  local file="$1" key="$2"
  # Match lines starting with `key=`, return everything after the first
  # equals sign, and exit 1 if the key is absent.
  awk -v want="${key}" '
    index($0, want "=") == 1 {
      print substr($0, length(want) + 2)
      found = 1
    }
    END { if (!found) exit 1 }
  ' "${file}" 2>/dev/null
}

valid_component_manifest_entry() {
  local file="$1" component="$2"
  local -A seen=()
  local key value line
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line; do
    # Skip blank lines
    [[ -n "${line}" ]] || continue
    # A valid line must contain '=' and have a non-empty key before it.
    # Lines without '=' (key == whole line) are malformed.
    key="${line%%=*}"
    value="${line#*=}"
    [[ -n "${key}" && "${key}" != "${line}" ]] || return 1
    # Keys must use only lowercase letters and underscores.
    [[ "${key}" =~ ^[a-z_]+$ ]] || return 1
    # Values must not contain carriage returns (guard against CRLF files).
    # Null bytes cannot be stored in bash variables; skip that check.
    [[ "${value}" =~ $'\r' ]] && return 1
    case "${key}" in
      format|component|beep_version|converged_utc|component_version|suboptions)
        # Reject any duplicate key.
        [[ -n "${seen[${key}]+x}" ]] && return 1
        seen["${key}"]=1
        ;;
      *) return 1 ;;
    esac
  done < "${file}"
  # Require exactly one occurrence of every one of the six defined keys.
  for key in format component beep_version converged_utc component_version suboptions; do
    [[ -n "${seen[${key}]+x}" ]] || return 1
  done
  # Validate format version, component name, and component/path match.
  [[ "$(_read_manifest_value "${file}" format)" == "${COMPONENT_MANIFEST_FORMAT_VERSION}" ]] || return 1
  local file_component
  file_component="$(_read_manifest_value "${file}" component)"
  [[ "${file_component}" == "${component}" ]] || return 1
  # Ensure the stored component name is itself a known safe value so a
  # crafted manifest cannot inject an arbitrary string into the component
  # path even if component_manifest_path is called again later.
  is_public_component "${file_component}" || return 1
  return 0
}

list_manifest_components() {
  local component path
  validate_component_manifest_dir
  [[ -d "${COMPONENT_MANIFEST_DIR}" ]] || return 0
  for component in "${PUBLIC_COMPONENTS[@]}"; do
    path="$(component_manifest_path "${component}")"
    if [[ -e "${path}" ]]; then
      if valid_component_manifest_entry "${path}" "${component}"; then
        printf '%s\n' "${component}"
      else
        warn "Ignoring malformed component manifest: ${path}"
      fi
    fi
  done
  shopt -s nullglob
  for path in "${COMPONENT_MANIFEST_DIR}"/*; do
    component="$(basename -- "${path}")"
    is_public_component "${component}" || warn "Ignoring unknown component manifest: ${path}"
  done
  shopt -u nullglob
}

legacy_beep_present() {
  [[ -d "${BEEP_DIR}" || -f "/etc/systemd/system/beep-chat.service" || -d "${BEEP_ETC}" ]]
}

legacy_forgejo_present() {
  [[ -f /etc/systemd/system/forgejo.service || -d /etc/forgejo \
    || -x /usr/local/bin/forgejo \
    || -f /etc/systemd/system/forgejo-runner.service \
    || -x /usr/local/bin/forgejo-runner \
    || -d /var/lib/forgejo || -d /var/lib/forgejo-runner \
    || -f "${COMPONENT_MANIFEST_DIR}/${COMPONENT_FORGEJO}" ]]
}

legacy_forgejo_runner_present() {
  [[ -f /etc/systemd/system/forgejo-runner.service \
    || -x /usr/local/bin/forgejo-runner \
    || -d /var/lib/forgejo-runner \
    || -f "${COMPONENT_MANIFEST_DIR}/${COMPONENT_FORGEJO_RUNNER}" ]]
}

established_forgejo_state_present() {
  local path
  [[ -f /etc/systemd/system/forgejo.service \
      || -f "${COMPONENT_MANIFEST_DIR}/${COMPONENT_FORGEJO}" \
      || -s /etc/forgejo/app.ini ]] \
    && return 0
  for path in /var/lib/forgejo/data/forgejo-repositories \
      /var/lib/forgejo/data/lfs; do
    [[ -d "${path}" ]] || continue
    find "${path}" -mindepth 1 -print -quit 2>/dev/null | grep -q . \
      && return 0
  done
  return 1
}

llama_installation_is_managed() {
  local marker
  for marker in /etc/llama.cpp/managed-by-beep \
      /var/lib/llama.cpp/managed-by-beep; do
    valid_component_ownership_marker "${marker}" "${COMPONENT_LLAMA}" && return 0
  done
  return 1
}

legacy_llama_present() {
  llama_installation_is_managed
}

resolve_lifecycle_targets_from_manifest() {
  local component found="${#SELECTED_COMPONENTS[@]}"
  (( EXPLICIT_TARGETS )) && return 0
  [[ "${SUBCOMMAND}" == "verify" || "${SUBCOMMAND}" == "doctor" || "${SUBCOMMAND}" == "repair" ]] || return 0
  while IFS= read -r component; do
    [[ -n "${component}" ]] || continue
    add_selected_component "${component}"
    found=1
  done < <(list_manifest_components)
  if (( ! found )); then
    for component in "${PUBLIC_COMPONENTS[@]}"; do
      if component_dispatch_hook "${component}" legacy; then
        add_selected_component "${component}"
      fi
    done
  fi
}

component_selected_for_lifecycle() {
  is_selected_component "$1"
}

validate_and_resolve_targets() {
  local target component
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
    add_selected_component "${COMPONENT_BEEP}"
  fi

  if forgejo_config_selected; then
    add_selected_component "${COMPONENT_FORGEJO}"
  fi
  if forgejo_runner_config_selected; then
    add_selected_component "${COMPONENT_FORGEJO_RUNNER}"
  fi
  if llama_config_selected; then
    add_selected_component "${COMPONENT_LLAMA}"
  fi

  # Installing a component also installs its registered dependencies.
  # verify/doctor/repair/uninstall keep operating on the explicit targets
  # only, matching the documented selection rules.
  if [[ "${SUBCOMMAND}" == "install" ]] && (( ${#SELECTED_COMPONENTS[@]} > 0 )); then
    local -a resolved_targets=()
    while IFS= read -r component; do
      [[ -n "${component}" ]] && resolved_targets+=("${component}")
    done < <(resolve_component_targets "${SELECTED_COMPONENTS[@]}")
    SELECTED_COMPONENTS=("${resolved_targets[@]}")
  fi

  # Execution order follows the registry, not the order targets were typed.
  # This also makes legacy flags equivalent to explicit component selection.
  declare -A requested_components=()
  for target in "${SELECTED_COMPONENTS[@]}"; do
    requested_components["${target}"]=1
  done
  SELECTED_COMPONENTS=()
  for component in "${PUBLIC_COMPONENTS[@]}"; do
    [[ -n "${requested_components[${component}]+x}" ]] \
      && SELECTED_COMPONENTS+=("${component}")
  done

  # Compatibility mapping only: explicit registry selection keeps the legacy
  # environment selectors coherent for component-owned code.
  is_selected_component "${COMPONENT_FORGEJO}" && BEEP_INSTALL_FORGEJO=1
  is_selected_component "${COMPONENT_FORGEJO_RUNNER}" \
    && BEEP_INSTALL_FORGEJO_RUNNER=1
  is_selected_component "${COMPONENT_LLAMA}" && BEEP_INSTALL_LLAMA=1
  return 0
}

beep_config_selected() {
  is_selected_component "${COMPONENT_BEEP}" && return 0
  (( EXPLICIT_TARGETS )) && return 1
  # This is validation fallback only. Target selection for install happens in
  # validate_and_resolve_targets(); no-target non-install verbs keep the legacy
  # beep-centric validation path until the component manifest lands. No-target
  # uninstall delegates to uninstall.sh.
  [[ "${SUBCOMMAND}" != "uninstall" ]]
}

forgejo_config_selected() {
  is_selected_component "${COMPONENT_FORGEJO}" && return 0
  [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]]
}

forgejo_runner_config_selected() {
  is_selected_component "${COMPONENT_FORGEJO_RUNNER}" && return 0
  [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]
}

llama_config_selected() {
  is_selected_component "${COMPONENT_LLAMA}" && return 0
  [[ "${BEEP_INSTALL_LLAMA}" == "1" ]]
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

Beep baseline installer + AI Systems Administrator chat service.

Usage:
  sudo ./${SCRIPT_NAME} [VERB] [COMPONENT ...] [FLAGS]

Verbs:
  install     Full install (default). With no component target, installs the
              beep baseline. Interactive runs open an editable parameter
              review before any change is made.
  verify      Read-only state check. Does not change state.
  doctor      Explain failures and likely fixes.
  repair      Apply known-safe fixes (re-assert permissions, restart
              the chat service).
  uninstall   Reverse the install (delegates to uninstall.sh). With no target,
              keeps the current all-managed-artefacts behaviour.

Components:
  beep      The Beep account, runtime, chat UI, policy, and services.
  forgejo     Forgejo + PostgreSQL, independently installable without beep.
  forgejo-runner
              Forgejo Actions runner for an existing local Forgejo installation.
  llama       PC-wide llama.cpp server on 127.0.0.1:8080, independent of beep.

Selection rules:
  install with no component target selects beep. Explicit targets select
  exactly those components, plus any enabled legacy BEEP_INSTALL_* options.
  verify/doctor/repair targets are accepted now; no-target discovery falls back
  to current legacy checks until the component manifest lands.

Flags:
  Behaviour
    -n, --dry-run     Print the plan without touching the host.
                      Meaningful with 'install' and 'uninstall'.
    -y, --yes         Skip the "Type YES" confirmation. Still prompts for
                      any missing inputs (use BEEP_NONINTERACTIVE=1 to
                      skip every prompt for fully unattended installs).
        --strict      Treat preflight warnings as fatal.
  Uninstall only
        --archive     Archive /opt/beep before removing it.
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
  BEEP_NONINTERACTIVE=1     skip prompts for fully unattended installs.
  BEEP_USER=<name>          name of the local agent account (default
                              'beep'). Must be set on every later
                              install/verify/doctor/repair/uninstall
                              run that targets a non-default account.
  BEEP_COLOR=auto|always|never   colour policy (default auto). The setup
                              UI uses the Beep Orchid highlight (#AC43D9)
                              and compatible accents when colour is enabled.
  BEEP_RECEIPT=0            disable the start/finish install receipt
                              (written by default).
  BEEP_RECEIPT_FILE=<path>  override the receipt path (default
                              /var/log/beep/install-receipt.txt).
  BEEP_SKIP_LLM_SCAN=1     skip the interactive LAN scan that looks for an
                              OpenAI-compatible local LLM server and offers
                              its models as the starting model. The scan is
                              also skipped when a model is already configured.
  BEEP_LLM_SCAN_PORT=<n>    port probed for the local LLM scan (default
                              1234, LM Studio's default).
  BEEP_LOCAL_LLM_API_KEY=<k>  API key recorded for the discovered local LLM
                              (default 'local'; most local servers ignore it).
  BEEP_ADMIN_PASSWORD       Chat-UI password gate (default 'braaaains';
                              only a hash is stored).
  BEEP_TTL_DAYS=<n>         Time to Live in days before the beep is
                              permanently disabled (default 7).

Optional components (all default 0 / off; see options/ for the roadmap):
  BEEP_INSTALL_LLAMA=1      also install the standalone llama component.
  LLAMA_MODEL_ID=<id>         approved model (default
                              smollm2-360m-instruct-q4_k_m).
  LLAMA_CONTEXT_SIZE=<n>      context tokens (default 2048).
  LLAMA_CPU_THREADS=<n>       CPU inference threads (default: detected CPUs).
  LLAMA_BOOT=enabled|disabled start the server at boot (default enabled).
  BEEP_INSTALL_FORGEJO=1    also install a self-hosted Forgejo git forge
                              backed by PostgreSQL, reachable over LAN HTTPS
                              through Caddy and mDNS/Avahi.
  BEEP_INSTALL_FORGEJO_RUNNER=1  also install a Forgejo Actions runner on
                              the same host (restricted Docker executor).
                              Requires BEEP_INSTALL_FORGEJO=1.
  FORGEJO_HTTP_PORT=<n>       Forgejo loopback backend port (default 3000).
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
  sudo BEEP_NONINTERACTIVE=1 ./${SCRIPT_NAME} install

  # Canonical component form for the baseline:
  sudo ./${SCRIPT_NAME} install beep

  # Baseline plus a Forgejo forge with a co-located Actions runner
  # (environment flags remain supported for automation):
  sudo BEEP_INSTALL_FORGEJO=1 BEEP_INSTALL_FORGEJO_RUNNER=1 \\
    ./${SCRIPT_NAME} install

  # Equivalent component-target preview for the combined install:
  sudo ./${SCRIPT_NAME} install beep forgejo --dry-run

  # Install Forgejo + PostgreSQL without the beep account/runtime:
  sudo ./${SCRIPT_NAME} install forgejo

  # Install a standalone local llama.cpp service without beep:
  sudo ./${SCRIPT_NAME} install llama

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
    -q|--quiet)   BEEP_QUIET=1; shift ;;
    --verbose|--debug) VERBOSE=1; shift ;;
    --no-color|--no-colour) export BEEP_COLOR=never; lib_setup_colors; shift ;;
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

if [[ "${SUBCOMMAND}" == "install" ]] && ! (( BEEP_QUIET )); then
  brand_splash "install" "${SCRIPT_VERSION}"
fi

# ---------------------------------------------------------------------------
# Helpers shared across subcommands
# ---------------------------------------------------------------------------

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./${SCRIPT_NAME} ${SUBCOMMAND}" 2
}

# Existing service and database state needs a stronger acknowledgement than
# the general install confirmation. Only an exact, capitalized YES is accepted;
# --yes deliberately does not bypass this gate.
require_capitalized_yes() {
  local variable="$1" prompt="$2" answer="${!1:-}"
  if [[ "${answer}" == "YES" ]]; then
    info "${variable}=YES: ${prompt}"
    return 0
  fi
  if [[ "${BEEP_NONINTERACTIVE}" == "1" ]] || (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    die "${prompt} Set ${variable}=YES (capitalized exactly) to continue." 64
  fi
  if ! read -r -p "${prompt} Type YES to continue: " answer; then
    info "No input (EOF); cancelled."
    exit 0
  fi
  [[ "${answer}" == "YES" ]] || { info "Cancelled; existing data was left unchanged."; exit 0; }
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

download_verified_file() {
  local url="$1" sha256="$2" destination="$3" label="$4" actual
  if [[ -f "${destination}" ]]; then
    actual="$(sha256sum "${destination}" | awk '{print $1}')"
    [[ "${actual}" == "${sha256}" ]] && return 0
    rm -f "${destination}"
  fi
  rm -f "${destination}.part"
  info "Downloading ${label}…"
  curl_get -o "${destination}.part" "${url}" \
    || { rm -f "${destination}.part"; die "Could not download ${label}." 1; }
  actual="$(sha256sum "${destination}.part" | awk '{print $1}')"
  [[ "${actual}" == "${sha256}" ]] \
    || { rm -f "${destination}.part"; die "${label} checksum mismatch." 1; }
  mv -f "${destination}.part" "${destination}"
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
  # Reject path traversal: no '..' component anywhere in the path.
  [[ "$1" == */../* || "$1" == *"/.." ]] && return 1
  return 0
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
  # BSD regcomp (used by macOS bash) rejects bounded repetitions above
  # 255, so enforce the length separately and keep the regex simple.
  (( ${#1} >= 1 && ${#1} <= 512 )) || return 1
  [[ "$1" =~ ^[A-Za-z0-9._:/,+-]+$ ]]
}

# Forgejo JWT secrets are unpadded base64url encodings of exactly 32 bytes,
# which occupy 43 characters (ceil(32 * 8 / 6)). Reject older malformed values
# so a re-run can repair app.ini before Forgejo tries (and fails) to rewrite
# the intentionally root-owned configuration.
is_valid_forgejo_jwt_secret() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
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

forgejo_config_file_has_recovery_material() {
  local file="$1"
  local db_password secret_key internal_token jwt_secret lfs_jwt_secret
  [[ -s "${file}" ]] || return 1
  db_password="$(ini_get "${file}" database PASSWD || true)"
  secret_key="$(ini_get "${file}" security SECRET_KEY || true)"
  internal_token="$(ini_get "${file}" security INTERNAL_TOKEN || true)"
  jwt_secret="$(ini_get "${file}" oauth2 JWT_SECRET || true)"
  lfs_jwt_secret="$(ini_get "${file}" server LFS_JWT_SECRET || true)"
  [[ -n "${db_password}" && -n "${secret_key}" && -n "${internal_token}" ]] \
    && is_valid_forgejo_jwt_secret "${jwt_secret}" \
    && is_valid_forgejo_jwt_secret "${lfs_jwt_secret}"
}

forgejo_config_has_recovery_material() {
  forgejo_config_file_has_recovery_material /etc/forgejo/app.ini
}

forgejo_url_host() {
  local host
  host="$(hostname -s 2>/dev/null || hostname)"
  host="${host%.local}.local"
  printf '%s\n' "${host}" | tr '[:upper:]' '[:lower:]'
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

# Component-specific validation hooks.
validate_beep_config() {
  if ! is_supported_agent_username "${AGENT_USER}"; then
    die "Invalid agent username '${AGENT_USER}'. Use a non-reserved lowercase Linux username (letters first; then letters, digits, underscore, hyphen; max 32 chars; no trailing punctuation)." 2
  fi
  if ! is_safe_absolute_path "${BEEP_DIR}"; then
    die "BEEP_DIR must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  if ! is_valid_tcp_port "${CHAT_PORT}"; then
    die "BEEP_CHAT_PORT must be an integer from 1 to 65535." 2
  fi
  if ! is_valid_ttl_days "${TTL_DAYS}"; then
    die "BEEP_TTL_DAYS must be an integer number of days from 1 to 36500." 2
  fi
}

validate_forgejo_config() {
  if ! is_valid_option_flag "${BEEP_INSTALL_FORGEJO_RUNNER}"; then
    die "BEEP_INSTALL_FORGEJO_RUNNER must be 0 or 1." 2
  fi
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
  if [[ "${BEEP_RECEIPT}" != "1" ]] \
      && [[ -z "${FORGEJO_ADMIN_PASSWORD}" || -z "${FORGEJO_DB_PASSWORD}" ]]; then
    die "Forgejo password generation requires a receipt. Set BEEP_RECEIPT=1, or explicitly set both FORGEJO_ADMIN_PASSWORD and FORGEJO_DB_PASSWORD." 64
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
}

validate_forgejo_runner_config() {
  if ! is_valid_option_flag "${BEEP_INSTALL_FORGEJO_RUNNER}"; then
    die "BEEP_INSTALL_FORGEJO_RUNNER must be 0 or 1." 2
  fi
  if ! is_valid_forgejo_version "${FORGEJO_RUNNER_VERSION}"; then
    die "FORGEJO_RUNNER_VERSION must be a release like 6.3.1 (or empty for latest)." 2
  fi
  if ! is_valid_forgejo_runner_labels "${FORGEJO_RUNNER_LABELS}"; then
    die "FORGEJO_RUNNER_LABELS must use only letters, digits, and . _ : / , + - (no spaces or quotes; max 512 chars)." 2
  fi
}

validate_llama_config() {
  local model_context_limit
  [[ "${LLAMA_PORT}" == "8080" ]] \
    || die "LLAMA_PORT is fixed at 8080 for this release." 2
  model_context_limit="$(awk -v id="${LLAMA_MODEL_ID}" '
    index($0, "\"id\": \"" id "\"") { found=1 }
    found && /"context_size":/ {
      value=$0
      sub(/^.*"context_size":[[:space:]]*/, "", value)
      sub(/[^0-9].*$/, "", value)
      print value
      exit
    }
  ' "${PAYLOAD_DIR}/etc/llama-models.json")"
  [[ "${model_context_limit}" =~ ^[0-9]+$ ]] \
    || die "LLAMA_MODEL_ID is not present in the approved model catalogue." 2
  [[ "${LLAMA_CONTEXT_SIZE}" =~ ^[0-9]+$ ]] \
    && (( LLAMA_CONTEXT_SIZE >= 512 && LLAMA_CONTEXT_SIZE <= model_context_limit )) \
    || die "LLAMA_CONTEXT_SIZE must be between 512 and the approved model maximum of ${model_context_limit}." 2
  [[ "${LLAMA_CPU_THREADS}" =~ ^[0-9]+$ ]] \
    && (( LLAMA_CPU_THREADS >= 1 && LLAMA_CPU_THREADS <= 1024 )) \
    || die "LLAMA_CPU_THREADS must be between 1 and 1024." 2
  [[ "${LLAMA_BOOT}" == "enabled" || "${LLAMA_BOOT}" == "disabled" ]] \
    || die "LLAMA_BOOT must be enabled or disabled." 2
}

# Validate common settings, then dispatch only the selected components.
validate_config() {
  if ! is_safe_absolute_path "${LOG_FILE}"; then
    die "LOG_FILE must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  # Receipt is a core setting and is validated for every selected component,
  # even when Forgejo credentials make it mandatory rather than optional.
  if ! is_valid_option_flag "${BEEP_RECEIPT}"; then
    die "BEEP_RECEIPT must be 0 or 1." 2
  fi
  if [[ "${BEEP_RECEIPT}" == "1" ]] && ! is_safe_absolute_path "${RECEIPT_FILE}"; then
    die "BEEP_RECEIPT_FILE must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  validate_component_manifest_dir
  local component
  local -a validation_components=("${SELECTED_COMPONENTS[@]}")
  if ! is_valid_option_flag "${BEEP_INSTALL_FORGEJO}"; then
    die "BEEP_INSTALL_FORGEJO must be 0 or 1." 2
  fi
  if ! is_valid_option_flag "${BEEP_INSTALL_LLAMA}"; then
    die "BEEP_INSTALL_LLAMA must be 0 or 1." 2
  fi
  if (( ${#validation_components[@]} == 0 )) && [[ "${SUBCOMMAND}" != "uninstall" ]]; then
    validation_components=("${PUBLIC_COMPONENTS[0]}")
  fi
  for component in "${validation_components[@]}"; do
    component_dispatch_hook "${component}" validate
  done
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
  local errors=0 warnings=0 required_disk_kb=1000000 required_disk_label="1 GB"
  local memory_context="selected services"
  if is_selected_component "${COMPONENT_BEEP}"; then
    required_disk_kb=3000000
    required_disk_label="3 GB"
    memory_context="agent runtime"
  fi
  if is_selected_component "${COMPONENT_BEEP}" \
      && is_selected_component "${COMPONENT_FORGEJO}"; then
    required_disk_kb=4000000
    required_disk_label="4 GB"
  fi

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

  # Disk capacity follows the selected components. The beep runtime and its
  # Node/Python toolchain need more room than standalone Forgejo.
  local avail_kb
  avail_kb="$(df -P / | awk 'NR==2 {print $4}')"
  if [[ "${avail_kb:-0}" -lt "${required_disk_kb}" ]]; then
    warn "Less than ${required_disk_label} free under / ($((avail_kb/1024)) MB). Install may fail."
    warnings=$((warnings + 1)); pf warn "Disk >= ${required_disk_label} free ($((avail_kb/1024)) MB)"
  else
    pf ok "Disk free $((avail_kb/1024)) MB"
  fi

  # Memory: 2 GB minimum recommended.
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem_kb:-0}" -lt 2000000 ]]; then
    warn "Less than 2 GB RAM ($((mem_kb/1024)) MB). The ${memory_context} may be tight."
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
  if ! (( BEEP_QUIET )); then
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
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] || return 0
}

# Forgejo lifecycle helpers must be defined before the early
# verify/doctor/repair dispatch below.
caddyfile_has_forgejo_route() {
  # Return success only for one managed block containing the expected
  # host, loopback backend port, and internal-TLS directive.
  local caddyfile="$1" host="$2" port="$3"
  [[ -r "${caddyfile}" ]] || return 1
  awk -v host="${host}" -v port="${port}" '
    BEGIN {
      begin_marker = "# BEGIN install.sh Forgejo"
      end_marker = "# END install.sh Forgejo"
    }
    $0 == begin_marker {
      begin_count++
      managed = 1
      next
    }
    $0 == end_marker {
      end_count++
      managed = 0
      next
    }
    managed {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "https://" host " {") site_count++
      if (line == "tls internal") tls_count++
      if (line == "reverse_proxy 127.0.0.1:" port) proxy_count++
    }
    END {
      exit !(begin_count == 1 && end_count == 1 && !managed \
        && site_count == 1 && tls_count == 1 && proxy_count == 1)
    }
  ' "${caddyfile}"
}

caddy_configuration_is_valid() {
  # Validate as the caller when possible, with passwordless sudo as the
  # non-root doctor fallback.
  command -v caddy >/dev/null 2>&1 || return 1
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
      >/dev/null 2>&1 \
    || sudo -n caddy validate --config /etc/caddy/Caddyfile \
      --adapter caddyfile >/dev/null 2>&1
}

caddy_exported_ca_is_current() {
  # Return success only when the client export matches Caddy's active root.
  local active_ca=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
  local exported_ca=/etc/forgejo/caddy-local-ca.crt
  cmp -s "${active_ca}" "${exported_ca}" 2>/dev/null \
    || sudo -n cmp -s "${active_ca}" "${exported_ca}" 2>/dev/null
}

_caddyfile_is_packaged_default() {
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      content[++count] = line
    }
    END {
      exit !(count == 4 \
        && content[1] == ":80 {" \
        && content[2] == "root * /usr/share/caddy" \
        && content[3] == "file_server" \
        && content[4] == "}")
    }
  ' "$1"
}

# lifecycle-helper: forgejo-caddy-configure begin
configure_forgejo_lan_https() {
  local host caddy_tmp avahi_tmp ca_source caddy_begin caddy_end
  local caddy_begin_count caddy_end_count
  host="$(forgejo_url_host)"
  FORGEJO_URL_HOST="${host}"

  if [[ -f /etc/forgejo/app.ini ]]; then
    sed -i \
      -e 's|^HTTP_ADDR = .*|HTTP_ADDR = 127.0.0.1|' \
      -e "s|^DOMAIN = .*|DOMAIN = ${host}|" \
      -e "s|^ROOT_URL = .*|ROOT_URL = https://${host}/|" \
      /etc/forgejo/app.ini
    chown root:git /etc/forgejo/app.ini
    chmod 640 /etc/forgejo/app.ini
  fi

  [[ -f /etc/caddy/Caddyfile ]] || install -m 644 /dev/null /etc/caddy/Caddyfile
  if _caddyfile_is_packaged_default /etc/caddy/Caddyfile; then
    install -m 644 -o root -g root /dev/null /etc/caddy/Caddyfile
  fi
  caddy_begin="# BEGIN install.sh Forgejo"
  caddy_end="# END install.sh Forgejo"
  read -r caddy_begin_count caddy_end_count < <(
    awk -v begin="${caddy_begin}" -v end="${caddy_end}" '
      BEGIN { begin_count = 0; end_count = 0 }
      $0 == begin { begin_count++ }
      $0 == end { end_count++ }
      END { print begin_count + 0, end_count + 0 }
    ' /etc/caddy/Caddyfile
  )
  if (( caddy_begin_count != caddy_end_count )); then
    die "Caddyfile contains an incomplete managed Forgejo block. Restore or remove that block manually, then re-run repair forgejo." 1
  fi
  caddy_tmp="$(mktemp)"
  awk -v begin="${caddy_begin}" -v end="${caddy_end}" '
    BEGIN { managed = 0 }
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    !managed { print }
  ' /etc/caddy/Caddyfile > "${caddy_tmp}"
  cat >> "${caddy_tmp}" <<EOF
${caddy_begin}
# Managed by ${SCRIPT_NAME}. Forgejo stays on loopback; Caddy is the LAN edge.
https://${host} {
	tls internal
	reverse_proxy 127.0.0.1:${FORGEJO_HTTP_PORT}
}
${caddy_end}
EOF
  if cmp -s "${caddy_tmp}" /etc/caddy/Caddyfile; then
    rm -f "${caddy_tmp}"
  else
    install -m 644 -o root -g root "${caddy_tmp}" /etc/caddy/Caddyfile
    rm -f "${caddy_tmp}"
  fi
  rm -f /etc/caddy/conf.d/forgejo.caddy
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
    || die "Caddy configuration validation failed; /etc/caddy/Caddyfile was not activated." 1

  install -d -m 755 -o root -g root /etc/avahi/services
  avahi_tmp="$(mktemp)"
  cat > "${avahi_tmp}" <<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Forgejo on %h</name>
  <service>
    <type>_https._tcp</type>
    <port>443</port>
  </service>
</service-group>
EOF
  if [[ -f /etc/avahi/services/forgejo.service ]] \
      && cmp -s "${avahi_tmp}" /etc/avahi/services/forgejo.service; then
    rm -f "${avahi_tmp}"
  else
    install -m 644 -o root -g root "${avahi_tmp}" \
      /etc/avahi/services/forgejo.service
    rm -f "${avahi_tmp}"
  fi

  systemctl enable --now avahi-daemon.service >/dev/null 2>&1 \
    || die "Avahi failed to start; see journalctl -u avahi-daemon." 1
  systemctl restart forgejo.service \
    || die "Forgejo failed to apply its HTTPS public URL; see journalctl -u forgejo." 1
  if ! retry 6 2 -- curl -fsS --max-time 5 -o /dev/null \
       "http://127.0.0.1:${FORGEJO_HTTP_PORT}/api/healthz"; then
    die "Forgejo did not become healthy after applying its HTTPS public URL; see journalctl -u forgejo." 1
  fi
  systemctl enable --now caddy.service >/dev/null 2>&1 \
    || die "Caddy failed to start; see journalctl -u caddy." 1
  systemctl reload-or-restart caddy.service \
    || die "Caddy failed to load the Forgejo HTTPS configuration; see journalctl -u caddy." 1

  ca_source=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
  retry 6 1 -- test -r "${ca_source}" \
    || die "Caddy did not create its local CA certificate; see journalctl -u caddy." 1
  install -m 644 -o root -g root "${ca_source}" \
    /etc/forgejo/caddy-local-ca.crt
  if ! retry 6 2 -- curl -fsS --max-time 5 -o /dev/null \
       --cacert /etc/forgejo/caddy-local-ca.crt \
       --resolve "${host}:443:127.0.0.1" \
       "https://${host}/api/healthz"; then
    die "Forgejo HTTPS endpoint did not become healthy; see journalctl -u caddy and journalctl -u forgejo." 1
  fi
}
# lifecycle-helper: forgejo-caddy-configure end

forgejo_runner_config_is_managed() {
  [[ -r "${PAYLOAD_DIR}/etc/forgejo-runner-config.yaml" \
      && -r /var/lib/forgejo-runner/config.yaml ]] \
    && cmp -s "${PAYLOAD_DIR}/etc/forgejo-runner-config.yaml" \
      /var/lib/forgejo-runner/config.yaml
}

forgejo_manifest_has_runner() {
  local manifest="${COMPONENT_MANIFEST_DIR}/${COMPONENT_FORGEJO}"
  valid_component_manifest_entry "${manifest}" "${COMPONENT_FORGEJO}" \
    && [[ "$(_read_manifest_value "${manifest}" suboptions)" == "runner" ]]
}

forgejo_runner_manifest_present() {
  local manifest="${COMPONENT_MANIFEST_DIR}/${COMPONENT_FORGEJO_RUNNER}"
  valid_component_manifest_entry "${manifest}" "${COMPONENT_FORGEJO_RUNNER}"
}

forgejo_runner_is_expected() {
  [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
    || forgejo_runner_manifest_present \
    || forgejo_manifest_has_runner \
    || [[ -x /usr/local/bin/forgejo-runner \
      || -f /etc/systemd/system/forgejo-runner.service ]]
}

forgejo_runner_is_forgejo_suboption() {
  forgejo_runner_is_expected \
    && ! forgejo_runner_manifest_present \
    && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"
}

restore_forgejo_runner_intent() {
  is_selected_component "${COMPONENT_FORGEJO}" || return 0
  forgejo_runner_is_forgejo_suboption || return 0
  BEEP_INSTALL_FORGEJO_RUNNER=1
}

forgejo_runner_drop_in_paths() {
  local loaded
  loaded="$(
    systemctl show forgejo-runner.service --property=DropInPaths --value \
      2>/dev/null || true
  )"
  {
    tr ' ' '\n' <<<"${loaded}"
    find /etc/systemd/system/forgejo-runner.service.d -maxdepth 1 \
      \( -type f -o -type l \) -name '*.conf' -print 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

_forgejo_runner_drop_in_is_obsolete() {
  local drop_in="$1"
  [[ -f "${drop_in}" ]] || return 1
  awk '
    /^[[:space:]]*($|#|;)/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      content[++count] = line
    }
    END {
      exit !(count == 3 \
        && content[1] == "[Service]" \
        && content[2] == "ExecStart=" \
        && content[3] == "ExecStart=/usr/local/bin/forgejo-runner -c /var/lib/forgejo-runner/config.yaml daemon")
    }
  ' "${drop_in}"
}

remove_obsolete_forgejo_runner_drop_in() {
  local drop_in=/etc/systemd/system/forgejo-runner.service.d/override.conf
  _forgejo_runner_drop_in_is_obsolete "${drop_in}" || return 0
  rm -f "${drop_in}"
  rmdir /etc/systemd/system/forgejo-runner.service.d 2>/dev/null || true
  info "Removed the obsolete Forgejo runner systemd override."
  note_changed
}

forgejo_runner_uses_managed_config() {
  local exec_start expected
  expected="path=/usr/local/bin/forgejo-runner ; argv[]=/usr/local/bin/forgejo-runner -c /var/lib/forgejo-runner/config.yaml daemon ;"
  exec_start="$(
    systemctl show forgejo-runner.service --property=ExecStart --value \
      2>/dev/null || true
  )"
  [[ "${exec_start}" == *"${expected}"* ]]
}

forgejo_runner_in_docker_group() {
  id -nG forgejo-runner 2>/dev/null \
    | tr ' ' '\n' \
    | grep -Fx docker >/dev/null
}

forgejo_runner_has_docker_access() {
  if (( EUID == 0 )); then
    runuser -u forgejo-runner -- /usr/bin/docker info \
      --format '{{.ServerVersion}}' >/dev/null 2>&1
  else
    sudo -n -u forgejo-runner -- /usr/bin/docker info \
      --format '{{.ServerVersion}}' >/dev/null 2>&1
  fi
}

forgejo_runner_declared_successfully() {
  local invocation_id
  systemctl is-active --quiet forgejo-runner.service 2>/dev/null || return 1
  invocation_id="$(
    systemctl show forgejo-runner.service --property=InvocationID --value \
      2>/dev/null || true
  )"
  [[ "${invocation_id}" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  if journalctl --quiet --no-pager \
      "_SYSTEMD_INVOCATION_ID=${invocation_id}" 2>/dev/null \
      | awk 'index($0, "declared successfully") { found = 1 }
             END { exit !found }'; then
    return 0
  fi
  (( EUID != 0 )) \
    && sudo -n journalctl --quiet --no-pager \
      "_SYSTEMD_INVOCATION_ID=${invocation_id}" 2>/dev/null \
      | awk 'index($0, "declared successfully") { found = 1 }
             END { exit !found }'
}

# ---------------------------------------------------------------------------
# Subcommand: verify}

# ---------------------------------------------------------------------------
# Subcommand: verify
# ---------------------------------------------------------------------------

verify_beep() {
  # Keep lifecycle verification in this script. A deployed verifier may come
  # from an older release and must not be able to break current verify output.
  id "${AGENT_USER}" >/dev/null 2>&1 \
    && vr ok beep user "User ${AGENT_USER} exists." \
    || vr fail beep user "User ${AGENT_USER} missing. Run 'sudo ./${SCRIPT_NAME} install beep' first."
  [[ -f "/etc/sudoers.d/90-${AGENT_USER}-beep" ]] \
    && vr ok beep sudoers "Sudoers drop-in present." \
    || vr fail beep sudoers "Sudoers drop-in missing. Run 'sudo ./${SCRIPT_NAME} repair beep'."
  [[ -d "${BEEP_DIR}" ]] \
    && vr ok beep install_root "${BEEP_DIR} present." \
    || vr fail beep install_root "${BEEP_DIR} missing. Run 'sudo ./${SCRIPT_NAME} install beep' first."
  [[ -x "${BEEP_DIR}/bin/verify" ]] \
    && vr ok beep verify_script "${BEEP_DIR}/bin/verify present." \
    || vr fail beep verify_script "${BEEP_DIR}/bin/verify not found. Run 'sudo ./${SCRIPT_NAME} install beep' first."
  systemctl is-active --quiet beep-chat.service 2>/dev/null \
    && vr ok beep chat_service "Chat service active." \
    || vr fail beep chat_service "Chat service not active. Run: sudo systemctl start beep-chat"
}

verify_forgejo() {
  [[ -x /usr/local/bin/forgejo ]] \
    && vr ok forgejo binary "Forgejo binary present." \
    || vr fail forgejo binary "Forgejo binary missing."
  [[ -f /etc/systemd/system/forgejo.service ]] \
    && vr ok forgejo service_unit "Forgejo service unit present." \
    || vr fail forgejo service_unit "Forgejo service unit missing."
  local _fj_svc_active=0 _fj_config_readable=0
  local _fj_config_uninspectable=0 _fj_dir_perms _fj_cfg_perms _fj_port
  local _fj_host _fj_root_url _fj_http_addr
  systemctl is-active --quiet forgejo.service 2>/dev/null \
    && { vr ok forgejo service_active "Forgejo service active."; _fj_svc_active=1; } \
    || vr fail forgejo service_active "Forgejo service not active."
  if [[ -r /etc/forgejo/app.ini ]]; then
    vr ok forgejo config "Forgejo config present and readable."
    _fj_config_readable=1
  elif (( EUID != 0 )) && [[ -d /etc/forgejo && ! -x /etc/forgejo ]]; then
    vr fail forgejo config "Forgejo config is not inspectable without root. Re-run: sudo ./${SCRIPT_NAME} verify forgejo"
    _fj_config_uninspectable=1
  elif [[ -f /etc/forgejo/app.ini ]]; then
    vr fail forgejo config "Forgejo config is not readable. Re-run: sudo ./${SCRIPT_NAME} verify forgejo"
    _fj_config_uninspectable=1
  else
    vr fail forgejo config "Forgejo config missing."
  fi
  _fj_dir_perms="$(stat -c '%U:%G %a' /etc/forgejo 2>/dev/null || true)"
  _fj_cfg_perms="$(stat -c '%U:%G %a' /etc/forgejo/app.ini 2>/dev/null || true)"
  if [[ "${_fj_dir_perms}" == "root:git 750" && "${_fj_cfg_perms}" == "root:git 640" ]]; then
    vr ok forgejo config_perms "Forgejo config permissions correct (root:git 750/640)."
  elif (( _fj_config_uninspectable )); then
    vr fail forgejo config_perms "Forgejo config permissions are not inspectable without root. Re-run: sudo ./${SCRIPT_NAME} verify forgejo"
  else
    vr fail forgejo config_perms "Forgejo config permissions incorrect (${_fj_dir_perms:-?}/${_fj_cfg_perms:-?}). Run: sudo ./${SCRIPT_NAME} repair forgejo"
  fi
  if (( _fj_config_readable )) && forgejo_config_has_recovery_material; then
    vr ok forgejo config_recovery "Forgejo config contains the preserved database credential and security secrets."
  elif (( _fj_config_uninspectable )); then
    vr fail forgejo config_recovery "Forgejo recovery material is not inspectable without root. Re-run with sudo."
  else
    vr fail forgejo config_recovery "Forgejo config is missing required recovery material. Recover the original app.ini from backup."
  fi
  systemctl is-active --quiet postgresql 2>/dev/null \
    && vr ok forgejo db "PostgreSQL active." \
    || vr fail forgejo db "PostgreSQL not running (Forgejo needs it). Run: sudo systemctl start postgresql"
  _fj_port=3000
  _fj_host=""
  if (( _fj_config_readable )); then
    _fj_port="$(awk -F' = ' '/^HTTP_PORT/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
    _fj_port="${_fj_port:-3000}"
    _fj_host="$(awk -F' = ' '/^DOMAIN/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
    _fj_root_url="$(awk -F' = ' '/^ROOT_URL/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
    _fj_http_addr="$(awk -F' = ' '/^HTTP_ADDR/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
    if [[ -n "${_fj_host}" && "${_fj_root_url}" == "https://${_fj_host}/" \
        && "${_fj_http_addr}" == "127.0.0.1" ]]; then
      vr ok forgejo public_url "Forgejo uses HTTPS at ${_fj_root_url}; backend is loopback-only."
    else
      vr fail forgejo public_url "Forgejo HTTPS URL or loopback bind is incorrect. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    fi
  fi
  command -v caddy >/dev/null 2>&1 \
    && vr ok forgejo caddy_binary "Caddy binary present." \
    || vr fail forgejo caddy_binary "Caddy binary missing. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  systemctl cat caddy.service >/dev/null 2>&1 \
    && vr ok forgejo caddy_unit "Caddy service unit present." \
    || vr fail forgejo caddy_unit "Caddy service unit missing. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  systemctl is-enabled --quiet caddy.service 2>/dev/null \
    && vr ok forgejo caddy_enabled "Caddy service enabled at boot." \
    || vr fail forgejo caddy_enabled "Caddy service not enabled. Run: sudo systemctl enable caddy"
  systemctl is-active --quiet caddy.service 2>/dev/null \
    && vr ok forgejo caddy "Caddy HTTPS reverse proxy active." \
    || vr fail forgejo caddy "Caddy reverse proxy not active. Run: sudo systemctl restart caddy"
  if (( ! _fj_config_readable )); then
    vr fail forgejo caddy_route "Managed Caddy route cannot be checked without readable Forgejo configuration. Re-run with sudo."
  elif [[ -n "${_fj_host}" ]] \
      && caddyfile_has_forgejo_route /etc/caddy/Caddyfile "${_fj_host}" "${_fj_port}"; then
    vr ok forgejo caddy_route "Managed Caddy route matches ${_fj_host} -> 127.0.0.1:${_fj_port} with internal TLS."
  else
    vr fail forgejo caddy_route "Managed Caddy route is missing, duplicated, or stale. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  fi
  caddy_configuration_is_valid \
    && vr ok forgejo caddy_config "Active Caddy configuration validates." \
    || vr fail forgejo caddy_config "Caddy configuration is invalid. Run: sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
  [[ ! -e /etc/caddy/conf.d/forgejo.caddy ]] \
    && vr ok forgejo caddy_legacy_route "Legacy Forgejo Caddy fragment absent." \
    || vr fail forgejo caddy_legacy_route "Legacy Forgejo Caddy fragment remains. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  systemctl is-active --quiet avahi-daemon.service 2>/dev/null \
    && vr ok forgejo mdns "Avahi mDNS discovery active." \
    || vr fail forgejo mdns "Avahi mDNS discovery not active. Run: sudo systemctl restart avahi-daemon"
  [[ -r /etc/forgejo/caddy-local-ca.crt ]] \
    && vr ok forgejo local_ca "Caddy local CA certificate exported." \
    || vr fail forgejo local_ca "Caddy local CA certificate missing. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  caddy_exported_ca_is_current \
    && vr ok forgejo local_ca_current "Exported Caddy local CA matches the active CA root." \
    || vr fail forgejo local_ca_current "Exported and active Caddy local CA roots are missing or do not match. Run: sudo ./${SCRIPT_NAME} repair forgejo"
  if (( _fj_svc_active )); then
    if curl -fsS --max-time 5 -o /dev/null \
        "http://127.0.0.1:${_fj_port}/api/healthz" 2>/dev/null; then
      vr ok forgejo healthz "Forgejo /api/healthz reports healthy."
    else
      vr fail forgejo healthz "Forgejo /api/healthz did not return healthy. Check journalctl -u forgejo."
    fi
    if [[ -n "${_fj_host}" && -r /etc/forgejo/caddy-local-ca.crt ]]; then
      if curl -fsS --max-time 5 -o /dev/null \
          --cacert /etc/forgejo/caddy-local-ca.crt \
        --resolve "${_fj_host}:443:127.0.0.1" \
          "https://${_fj_host}/api/healthz" 2>/dev/null; then
        vr ok forgejo https_healthz "Forgejo HTTPS endpoint reports healthy."
      else
        vr fail forgejo https_healthz "Forgejo HTTPS endpoint failed. Check journalctl -u caddy."
      fi
    fi
  fi
  if forgejo_runner_is_forgejo_suboption; then
    local _fj_runner_cfg_perms _fj_runner_drop_ins
    local _fj_runner_registration_perms
    [[ -x /usr/local/bin/forgejo-runner ]] \
      && vr ok forgejo runner_binary "Forgejo runner binary present." \
      || vr fail forgejo runner_binary "Forgejo runner binary missing. Re-run the Forgejo runner install."
    [[ -f /etc/systemd/system/forgejo-runner.service ]] \
      && vr ok forgejo runner_unit "Forgejo runner service unit present." \
      || vr fail forgejo runner_unit "Forgejo runner service unit missing. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    systemctl is-enabled --quiet forgejo-runner.service 2>/dev/null \
      && vr ok forgejo runner_enabled "Forgejo runner enabled at boot." \
      || vr fail forgejo runner_enabled "Forgejo runner is not enabled at boot. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    systemctl is-active --quiet forgejo-runner.service 2>/dev/null \
      && vr ok forgejo runner "Forgejo Actions runner active." \
      || vr fail forgejo runner "Forgejo runner unit installed but not active. Run: sudo systemctl restart forgejo-runner"
    systemctl is-active --quiet docker.service 2>/dev/null \
      && vr ok forgejo runner_docker_service "Docker service active for the Forgejo runner." \
      || vr fail forgejo runner_docker_service "Docker service is not active. Run: sudo systemctl restart docker"
    forgejo_runner_in_docker_group \
      && vr ok forgejo runner_docker_group "forgejo-runner belongs to the docker group." \
      || vr fail forgejo runner_docker_group "forgejo-runner is not in the docker group. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    if [[ -s /var/lib/forgejo-runner/.runner ]]; then
      vr ok forgejo runner_registration "Forgejo runner registration is present."
    elif (( EUID != 0 )) \
        && [[ -d /var/lib/forgejo-runner && ! -x /var/lib/forgejo-runner ]]; then
      vr fail forgejo runner_registration "Runner registration is not inspectable without root. Re-run: sudo ./${SCRIPT_NAME} verify forgejo"
    else
      vr fail forgejo runner_registration "Runner registration is missing or empty. Re-run the Forgejo runner install."
    fi
    _fj_runner_registration_perms="$(
      stat -c '%U:%G %a' /var/lib/forgejo-runner/.runner 2>/dev/null || true
    )"
    [[ "${_fj_runner_registration_perms}" == "forgejo-runner:forgejo-runner 600" ]] \
      && vr ok forgejo runner_registration_perms "Runner registration permissions correct (forgejo-runner:forgejo-runner 600)." \
      || vr fail forgejo runner_registration_perms "Runner registration permissions are incorrect or not inspectable (${_fj_runner_registration_perms:-?}). Run: sudo ./${SCRIPT_NAME} repair forgejo"
    _fj_runner_cfg_perms="$(
      stat -c '%U:%G %a' /var/lib/forgejo-runner/config.yaml 2>/dev/null || true
    )"
    [[ "${_fj_runner_cfg_perms}" == "root:forgejo-runner 640" ]] \
      && vr ok forgejo runner_config_perms "Managed runner config permissions correct (root:forgejo-runner 640)." \
      || vr fail forgejo runner_config_perms "Managed runner config permissions are incorrect or not inspectable (${_fj_runner_cfg_perms:-?}). Run: sudo ./${SCRIPT_NAME} repair forgejo"
    forgejo_runner_config_is_managed \
      && vr ok forgejo runner_config "Runner uses the conservative managed same-host configuration." \
      || vr fail forgejo runner_config "Runner config is missing, not inspectable, or differs from the managed same-host configuration. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    forgejo_runner_uses_managed_config \
      && vr ok forgejo runner_exec "Runner service loads the managed configuration." \
      || vr fail forgejo runner_exec "Runner service does not load /var/lib/forgejo-runner/config.yaml. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    _fj_runner_drop_ins="$(forgejo_runner_drop_in_paths)"
    if [[ -z "${_fj_runner_drop_ins}" ]]; then
      vr ok forgejo runner_drop_ins "Runner service has no unmanaged systemd drop-ins."
    else
      vr fail forgejo runner_drop_ins "Runner service has unmanaged systemd drop-ins: ${_fj_runner_drop_ins//$'\n'/ }. Reconcile them, then run: sudo ./${SCRIPT_NAME} repair forgejo"
    fi
    if forgejo_runner_has_docker_access; then
      vr ok forgejo runner_docker_access "forgejo-runner can access the Docker daemon."
    elif (( EUID != 0 )); then
      vr fail forgejo runner_docker_access "Docker access as forgejo-runner is not inspectable without root. Re-run with sudo."
    else
      vr fail forgejo runner_docker_access "forgejo-runner cannot access the Docker daemon. Run: sudo ./${SCRIPT_NAME} repair forgejo"
    fi
    if forgejo_runner_declared_successfully; then
      vr ok forgejo runner_declared "The current runner invocation declared successfully to Forgejo."
    elif (( EUID != 0 )); then
      vr fail forgejo runner_declared "The current runner declaration is not inspectable without root. Re-run with sudo."
    else
      vr fail forgejo runner_declared "The current runner invocation has not declared successfully. Check: sudo journalctl -u forgejo-runner"
    fi
  fi
}

verify_forgejo_runner() {
  local component="${COMPONENT_FORGEJO_RUNNER}"
  local config_perms registration_perms drop_ins
  [[ -x /usr/local/bin/forgejo ]] \
    && vr ok "${component}" forgejo_binary "Required Forgejo server binary present." \
    || vr fail "${component}" forgejo_binary "Required Forgejo server binary missing."
  systemctl is-active --quiet forgejo.service 2>/dev/null \
    && vr ok "${component}" forgejo_service "Required Forgejo service active." \
    || vr fail "${component}" forgejo_service "Required Forgejo service is not active."
  [[ -x /usr/local/bin/forgejo-runner ]] \
    && vr ok "${component}" binary "Forgejo runner binary present." \
    || vr fail "${component}" binary "Forgejo runner binary missing."
  [[ -f /etc/systemd/system/forgejo-runner.service ]] \
    && vr ok "${component}" unit "Forgejo runner service unit present." \
    || vr fail "${component}" unit "Forgejo runner service unit missing."
  systemctl is-enabled --quiet forgejo-runner.service 2>/dev/null \
    && vr ok "${component}" enabled "Forgejo runner enabled at boot." \
    || vr fail "${component}" enabled "Forgejo runner is not enabled at boot."
  systemctl is-active --quiet forgejo-runner.service 2>/dev/null \
    && vr ok "${component}" service "Forgejo Actions runner active." \
    || vr fail "${component}" service "Forgejo Actions runner is not active."
  systemctl is-active --quiet docker.service 2>/dev/null \
    && vr ok "${component}" docker_service "Docker service active." \
    || vr fail "${component}" docker_service "Docker service is not active."
  forgejo_runner_in_docker_group \
    && vr ok "${component}" docker_group "forgejo-runner belongs to the docker group." \
    || vr fail "${component}" docker_group "forgejo-runner is not in the docker group."
  if [[ -s /var/lib/forgejo-runner/.runner ]]; then
    vr ok "${component}" registration "Forgejo runner registration is present."
  elif (( EUID != 0 )) \
      && [[ -d /var/lib/forgejo-runner && ! -x /var/lib/forgejo-runner ]]; then
    vr fail "${component}" registration "Runner registration is not inspectable without root. Re-run with sudo."
  else
    vr fail "${component}" registration "Forgejo runner registration is missing or empty."
  fi
  registration_perms="$(
    stat -c '%U:%G %a' /var/lib/forgejo-runner/.runner 2>/dev/null || true
  )"
  [[ "${registration_perms}" == "forgejo-runner:forgejo-runner 600" ]] \
    && vr ok "${component}" registration_perms "Runner registration permissions correct." \
    || vr fail "${component}" registration_perms "Runner registration permissions are incorrect or not inspectable."
  config_perms="$(
    stat -c '%U:%G %a' /var/lib/forgejo-runner/config.yaml 2>/dev/null || true
  )"
  [[ "${config_perms}" == "root:forgejo-runner 640" ]] \
    && forgejo_runner_config_is_managed \
    && vr ok "${component}" config "Managed runner configuration is active." \
    || vr fail "${component}" config "Runner configuration is missing, uninspectable, or unmanaged."
  forgejo_runner_uses_managed_config \
    && vr ok "${component}" exec "Runner service loads the managed configuration." \
    || vr fail "${component}" exec "Runner service does not load the managed configuration."
  drop_ins="$(forgejo_runner_drop_in_paths)"
  [[ -z "${drop_ins}" ]] \
    && vr ok "${component}" drop_ins "Runner service has no unmanaged systemd drop-ins." \
    || vr fail "${component}" drop_ins "Runner service has unmanaged systemd drop-ins: ${drop_ins//$'\n'/ }."
  if forgejo_runner_has_docker_access; then
    vr ok "${component}" docker_access "forgejo-runner can access the Docker daemon."
  elif (( EUID != 0 )); then
    vr fail "${component}" docker_access "Docker access is not inspectable without root. Re-run with sudo."
  else
    vr fail "${component}" docker_access "forgejo-runner cannot access the Docker daemon."
  fi
  forgejo_runner_declared_successfully \
    && vr ok "${component}" declared "Current runner invocation declared successfully to Forgejo." \
    || vr fail "${component}" declared "Current runner invocation has not declared successfully."
}

verify_llama() {
  [[ -f /etc/llama.cpp/managed-by-beep ]] \
    && vr ok llama marker "Managed ownership marker present." \
    || vr fail llama marker "Managed ownership marker missing; refusing to adopt this installation."
  [[ -x /usr/local/bin/beep-llama-manager ]] \
    && vr ok llama manager "beep-llama-manager present." \
    || vr fail llama manager "beep-llama-manager missing. Run 'sudo ./${SCRIPT_NAME} repair llama'."
  [[ -x /opt/llama.cpp/current/llama-server ]] \
    && vr ok llama runtime "Pinned llama.cpp runtime present." \
    || vr fail llama runtime "llama.cpp runtime missing. Run 'sudo ./${SCRIPT_NAME} repair llama'."
  [[ -f /var/lib/llama.cpp/models/SmolLM2-360M-Instruct-Q4_K_M.gguf ]] \
    && vr ok llama model "Managed SmolLM2 model present." \
    || vr fail llama model "Managed model missing. Run 'sudo ./${SCRIPT_NAME} repair llama'."
  [[ -f /etc/systemd/system/llama-server.service ]] \
    && vr ok llama unit "llama-server systemd unit present." \
    || vr fail llama unit "llama-server systemd unit missing."
  systemctl is-active --quiet llama-server.service 2>/dev/null \
    && vr ok llama service "llama-server active on 127.0.0.1:8080." \
    || vr fail llama service "llama-server not active. Run: sudo beep-llama-manager start"
  if systemctl is-active --quiet llama-server.service 2>/dev/null; then
    curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:8080/health \
      && vr ok llama health "llama-server health endpoint responds." \
      || vr fail llama health "llama-server health endpoint is unavailable."
  fi
}

cmd_verify() {
  local -a v_status=() v_component=() v_id=() v_msg=()
  vr() { v_status+=("$1"); v_component+=("$2"); v_id+=("$3"); v_msg+=("$4"); }
  if (( ${#SELECTED_COMPONENTS[@]} == 0 )); then
    vr fail none manifest "No managed components found."
  fi
  local component
  for component in "${SELECTED_COMPONENTS[@]}"; do
    component_dispatch_hook "${component}" verify
  done

  local n="${#v_status[@]}" i failed=0 passed=0
  for (( i = 0; i < n; i++ )); do
    case "${v_status[i]}" in
      ok) passed=$((passed + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  if (( JSON_OUTPUT )); then
    printf '{"tool":"verify","passed":%d,"failed":%d,"checks":[' "${passed}" "${failed}"
    for (( i = 0; i < n; i++ )); do
      printf '{"component":"%s","id":"%s","status":"%s","message":"%s"}' \
        "$(json_escape "${v_component[i]}")" "$(json_escape "${v_id[i]}")" "${v_status[i]}" "$(json_escape "${v_msg[i]}")"
      [[ $i -lt $((n - 1)) ]] && printf ','
    done
    printf ']}\n'
  else
    printf '%s== beep verify ==%s\n\n' "${C_BOLD}" "${C_RESET}"
    printf '%sComponents:%s %s\n\n' "${C_BOLD}" "${C_RESET}" "$(selected_components_label)"
    for (( i = 0; i < n; i++ )); do
      if [[ "${v_status[i]}" == "ok" ]]; then
        ok "[${v_component[i]}] ${v_msg[i]}"
      else
        printf '%s[x]%s [%s] %s\n' "${C_RED}" "${C_RESET}" "${v_component[i]}" "${v_msg[i]}"
      fi
    done
  fi
  (( failed == 0 ))
}

# ---------------------------------------------------------------------------
# Subcommand: doctor
# ---------------------------------------------------------------------------

cmd_doctor() {
  load_os_release

  local -a d_status=() d_msg=() d_id=() d_component=()
  dr() { d_status+=("$1"); d_component+=("$2"); d_id+=("$3"); d_msg+=("$4"); }

  local host_arch
  host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  if (( ${#SELECTED_COMPONENTS[@]} == 0 )); then
    dr info none manifest "No managed components found. Run 'sudo ./${SCRIPT_NAME} install' to install Beep."
  fi

  doctor_beep() {
    if id "${AGENT_USER}" >/dev/null 2>&1; then
      dr ok beep user "User ${AGENT_USER} exists."
    else
      dr warn beep user "User ${AGENT_USER} missing. Fix: sudo ./${SCRIPT_NAME} install beep"
    fi

    if [[ -f "/etc/sudoers.d/90-${AGENT_USER}-beep" ]]; then
      dr ok beep sudoers "Sudoers drop-in present."
    else
      dr warn beep sudoers "Sudoers drop-in missing. Fix: sudo ./${SCRIPT_NAME} repair beep"
    fi

    if [[ -d "${BEEP_DIR}" ]]; then
      dr ok beep install_root "${BEEP_DIR} present."
    else
      dr warn beep install_root "${BEEP_DIR} missing. Fix: sudo ./${SCRIPT_NAME} install beep"
    fi

    if [[ -f "${BEEP_DIR}/secrets/env" ]]; then
      local perms
      perms="$(stat -c %a "${BEEP_DIR}/secrets/env" 2>/dev/null || echo ???)"
      if [[ "${perms}" == "600" ]]; then
        dr ok beep secrets_perms "secrets/env permissions 600."
      else
        dr warn beep secrets_perms "secrets/env permissions ${perms} (must be 600). Fix: sudo ./${SCRIPT_NAME} repair beep"
      fi
      if provider_credential_configured "${BEEP_DIR}/secrets/env"; then
        dr ok beep provider_token "Provider credential present."
      else
        dr warn beep provider_token "No provider credential. Fix: sudo ${BEEP_DIR}/bin/beep-secrets-edit"
      fi
    else
      dr warn beep secrets_env "secrets/env missing. Fix: sudo ./${SCRIPT_NAME} install beep"
    fi

    if systemctl list-unit-files beep-chat.service >/dev/null 2>&1; then
      if systemctl is-active --quiet beep-chat.service; then
        dr ok beep chat_service "Chat service active."
      else
        dr warn beep chat_service "Chat service installed but not running. Fix: sudo systemctl start beep-chat"
      fi
    else
      dr warn beep chat_service "Chat service unit missing. Fix: sudo ./${SCRIPT_NAME} install beep"
    fi
  }

  doctor_forgejo() {
    if [[ -f /etc/systemd/system/forgejo.service || -d /etc/forgejo || -x /usr/local/bin/forgejo ]]; then
      if systemctl is-active --quiet forgejo.service 2>/dev/null; then
        dr ok forgejo forgejo "Forgejo service active."
      else
        dr warn forgejo forgejo "Forgejo installed but not running. Likely causes: port in use, DB auth, or migrations not run. Fix: sudo systemctl restart forgejo"
      fi
      local forgejo_config_readable=0 forgejo_config_uninspectable=0
      local forgejo_dir_perms forgejo_config_perms
      if [[ -r /etc/forgejo/app.ini ]]; then
        forgejo_config_readable=1
      elif (( EUID != 0 )) && [[ -d /etc/forgejo && ! -x /etc/forgejo ]]; then
        forgejo_config_uninspectable=1
        dr warn forgejo forgejo_config_file "Forgejo config is not inspectable without root. Re-run: sudo ./${SCRIPT_NAME} doctor forgejo"
      elif [[ -f /etc/forgejo/app.ini ]]; then
        forgejo_config_uninspectable=1
        dr warn forgejo forgejo_config_file "Forgejo config is not readable. Re-run: sudo ./${SCRIPT_NAME} doctor forgejo"
      else
        dr warn forgejo forgejo_config_file "Forgejo config is missing; do not restart Forgejo. Recover app.ini from backup before repair."
      fi
      forgejo_dir_perms="$(
        stat -c '%U:%G %a' /etc/forgejo 2>/dev/null \
          || sudo -n stat -c '%U:%G %a' /etc/forgejo 2>/dev/null \
          || true
      )"
      forgejo_config_perms="$(
        stat -c '%U:%G %a' /etc/forgejo/app.ini 2>/dev/null \
          || sudo -n stat -c '%U:%G %a' /etc/forgejo/app.ini 2>/dev/null \
          || true
      )"
      if [[ "${forgejo_dir_perms}" == "root:git 750" && "${forgejo_config_perms}" == "root:git 640" ]]; then
        dr ok forgejo forgejo_config "Forgejo config permissions are root:git 750/640."
      elif (( forgejo_config_uninspectable )); then
        dr warn forgejo forgejo_config "Forgejo config permissions are not inspectable without root."
      else
        dr warn forgejo forgejo_config "Forgejo config permissions are ${forgejo_dir_perms:-unknown}/${forgejo_config_perms}; expected root:git 750/640. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if (( forgejo_config_readable )) \
          && forgejo_config_has_recovery_material; then
        dr ok forgejo forgejo_config_recovery "Forgejo config contains the preserved database credential and security secrets."
      elif (( forgejo_config_uninspectable )); then
        dr warn forgejo forgejo_config_recovery "Forgejo recovery material is not inspectable without root."
      else
        dr warn forgejo forgejo_config_recovery "Forgejo config is missing required recovery material. Recover the original app.ini from backup."
      fi
      if systemctl is-active --quiet postgresql 2>/dev/null; then
        dr ok forgejo forgejo_db "PostgreSQL active."
      else
        dr warn forgejo forgejo_db "PostgreSQL not running (Forgejo needs it). Fix: sudo systemctl start postgresql"
      fi
      local forgejo_host="" forgejo_port=3000
      if (( forgejo_config_readable )); then
        forgejo_host="$(awk -F' = ' '/^DOMAIN/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
        forgejo_port="$(awk -F' = ' '/^HTTP_PORT/{print $2; exit}' /etc/forgejo/app.ini 2>/dev/null || true)"
        forgejo_port="${forgejo_port:-3000}"
      fi
      if command -v caddy >/dev/null 2>&1; then
        dr ok forgejo forgejo_caddy_binary "Caddy binary present."
      else
        dr warn forgejo forgejo_caddy_binary "Caddy binary missing. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if systemctl cat caddy.service >/dev/null 2>&1; then
        dr ok forgejo forgejo_caddy_unit "Caddy service unit present."
      else
        dr warn forgejo forgejo_caddy_unit "Caddy service unit missing. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if systemctl is-enabled --quiet caddy.service 2>/dev/null; then
        dr ok forgejo forgejo_caddy_enabled "Caddy service enabled at boot."
      else
        dr warn forgejo forgejo_caddy_enabled "Caddy service not enabled. Fix: sudo systemctl enable caddy"
      fi
      if systemctl is-active --quiet caddy.service 2>/dev/null; then
        dr ok forgejo forgejo_caddy "Caddy HTTPS reverse proxy active."
      else
        dr warn forgejo forgejo_caddy "Caddy is not running. Fix: sudo systemctl restart caddy"
      fi
      if (( ! forgejo_config_readable )); then
        dr warn forgejo forgejo_caddy_route "Managed Caddy route cannot be checked without readable Forgejo configuration. Re-run with sudo."
      elif [[ -n "${forgejo_host}" ]] \
          && caddyfile_has_forgejo_route /etc/caddy/Caddyfile "${forgejo_host}" "${forgejo_port}"; then
        dr ok forgejo forgejo_caddy_route "Managed Caddy route matches ${forgejo_host} -> 127.0.0.1:${forgejo_port} with internal TLS."
      else
        dr warn forgejo forgejo_caddy_route "Managed Caddy route is missing, duplicated, or stale. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if caddy_configuration_is_valid; then
        dr ok forgejo forgejo_caddy_config "Active Caddy configuration validates."
      else
        dr warn forgejo forgejo_caddy_config "Caddy configuration is invalid. Fix: sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
      fi
      if [[ -e /etc/caddy/conf.d/forgejo.caddy ]]; then
        dr warn forgejo forgejo_caddy_legacy "Legacy Forgejo Caddy fragment remains. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      else
        dr ok forgejo forgejo_caddy_legacy "Legacy Forgejo Caddy fragment absent."
      fi
      if systemctl is-active --quiet avahi-daemon.service 2>/dev/null; then
        dr ok forgejo forgejo_mdns "Avahi mDNS discovery active."
      else
        dr warn forgejo forgejo_mdns "Avahi is not running. Fix: sudo systemctl restart avahi-daemon"
      fi
      if [[ -r /etc/forgejo/caddy-local-ca.crt ]]; then
        dr ok forgejo forgejo_ca "Caddy local CA certificate exported for client trust."
      else
        dr warn forgejo forgejo_ca "Local CA export missing. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if caddy_exported_ca_is_current; then
        dr ok forgejo forgejo_ca_current "Exported Caddy local CA matches the active CA root."
      else
        dr warn forgejo forgejo_ca_current "Exported and active Caddy local CA roots are missing or do not match. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
      fi
      if forgejo_runner_is_forgejo_suboption; then
        local runner_config_perms runner_drop_ins
        if [[ -x /usr/local/bin/forgejo-runner ]]; then
          dr ok forgejo forgejo_runner_binary "Forgejo runner binary present."
        else
          dr warn forgejo forgejo_runner_binary "Forgejo runner binary missing. Re-run the Forgejo runner install."
        fi
        if [[ -f /etc/systemd/system/forgejo-runner.service ]]; then
          dr ok forgejo forgejo_runner_unit "Forgejo runner service unit present."
        else
          dr warn forgejo forgejo_runner_unit "Forgejo runner service unit missing. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        if systemctl is-enabled --quiet forgejo-runner.service 2>/dev/null; then
          dr ok forgejo forgejo_runner_enabled "Forgejo runner enabled at boot."
        else
          dr warn forgejo forgejo_runner_enabled "Forgejo runner is not enabled at boot. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        if systemctl is-active --quiet forgejo-runner.service 2>/dev/null; then
          dr ok forgejo forgejo_runner "Forgejo Actions runner active."
        else
          dr warn forgejo forgejo_runner "Forgejo runner not running. Check registration and Docker. Fix: sudo systemctl restart forgejo-runner"
        fi
        if systemctl is-active --quiet docker.service 2>/dev/null; then
          dr ok forgejo forgejo_runner_docker "Docker service active."
        else
          dr warn forgejo forgejo_runner_docker "Docker is not running. Fix: sudo systemctl restart docker"
        fi
        if forgejo_runner_in_docker_group; then
          dr ok forgejo forgejo_runner_group "forgejo-runner belongs to the docker group."
        else
          dr warn forgejo forgejo_runner_group "forgejo-runner is not in the docker group. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        if [[ -s /var/lib/forgejo-runner/.runner ]]; then
          dr ok forgejo forgejo_runner_registration "Runner registration is present."
        elif (( EUID != 0 )) \
            && [[ -d /var/lib/forgejo-runner && ! -x /var/lib/forgejo-runner ]]; then
          dr warn forgejo forgejo_runner_registration "Runner registration is not inspectable without root. Re-run with sudo."
        else
          dr warn forgejo forgejo_runner_registration "Runner registration is missing or empty. Re-run the Forgejo runner install."
        fi
        runner_config_perms="$(
          stat -c '%U:%G %a' /var/lib/forgejo-runner/config.yaml \
            2>/dev/null || true
        )"
        if [[ "${runner_config_perms}" == "root:forgejo-runner 640" ]] \
            && forgejo_runner_config_is_managed; then
          dr ok forgejo forgejo_runner_config "Conservative managed runner configuration is active on disk."
        else
          dr warn forgejo forgejo_runner_config "Runner config is missing, not inspectable, or unmanaged (${runner_config_perms:-unknown}). Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        if forgejo_runner_uses_managed_config; then
          dr ok forgejo forgejo_runner_exec "Runner service loads the managed configuration."
        else
          dr warn forgejo forgejo_runner_exec "Runner service ignores the managed configuration. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        runner_drop_ins="$(forgejo_runner_drop_in_paths)"
        if [[ -z "${runner_drop_ins}" ]]; then
          dr ok forgejo forgejo_runner_drop_ins "Runner service has no unmanaged systemd drop-ins."
        else
          dr warn forgejo forgejo_runner_drop_ins "Runner service has unmanaged systemd drop-ins: ${runner_drop_ins//$'\n'/ }. Reconcile them before repair."
        fi
        if forgejo_runner_has_docker_access; then
          dr ok forgejo forgejo_runner_docker_access "forgejo-runner can access the Docker daemon."
        elif (( EUID != 0 )); then
          dr warn forgejo forgejo_runner_docker_access "Docker access as forgejo-runner is not inspectable without root. Re-run with sudo."
        else
          dr warn forgejo forgejo_runner_docker_access "forgejo-runner cannot access Docker. Fix: sudo ./${SCRIPT_NAME} repair forgejo"
        fi
        if forgejo_runner_declared_successfully; then
          dr ok forgejo forgejo_runner_declared "Current runner invocation declared successfully to Forgejo."
        elif (( EUID != 0 )); then
          dr warn forgejo forgejo_runner_declared "Runner declaration is not inspectable without root. Re-run with sudo."
        else
          dr warn forgejo forgejo_runner_declared "Current runner invocation has not declared successfully. Check: sudo journalctl -u forgejo-runner"
        fi
      fi
    else
      dr warn forgejo forgejo_missing "Forgejo artefacts missing. Fix: sudo ./${SCRIPT_NAME} install forgejo"
    fi
  }

  doctor_forgejo_runner() {
    local component="${COMPONENT_FORGEJO_RUNNER}"
    if ! legacy_forgejo_runner_present; then
      dr warn "${component}" missing \
        "Forgejo runner artefacts missing. Fix: sudo ./${SCRIPT_NAME} install forgejo-runner"
      return
    fi
    systemctl is-active --quiet forgejo.service 2>/dev/null \
      && dr ok "${component}" forgejo "Required Forgejo service active." \
      || dr warn "${component}" forgejo "Required Forgejo service is not active."
    systemctl is-active --quiet docker.service 2>/dev/null \
      && dr ok "${component}" docker "Docker service active." \
      || dr warn "${component}" docker "Docker service is not active."
    systemctl is-active --quiet forgejo-runner.service 2>/dev/null \
      && dr ok "${component}" service "Forgejo Actions runner active." \
      || dr warn "${component}" service "Forgejo Actions runner is not active."
    [[ -s /var/lib/forgejo-runner/.runner ]] \
      && dr ok "${component}" registration "Runner registration is present." \
      || dr warn "${component}" registration "Runner registration is missing, empty, or uninspectable."
    forgejo_runner_config_is_managed \
      && forgejo_runner_uses_managed_config \
      && dr ok "${component}" config "Managed runner configuration is active." \
      || dr warn "${component}" config "Runner configuration is missing or unmanaged."
    forgejo_runner_in_docker_group \
      && dr ok "${component}" docker_group "forgejo-runner belongs to the docker group." \
      || dr warn "${component}" docker_group "forgejo-runner is not in the docker group."
    forgejo_runner_declared_successfully \
      && dr ok "${component}" declared "Current runner invocation declared successfully." \
      || dr warn "${component}" declared "Current runner invocation has not declared successfully."
  }

  doctor_llama() {
    if ! llama_installation_is_managed; then
      dr warn llama marker "Managed llama ownership marker missing. Fix: sudo ./${SCRIPT_NAME} install llama"
      return
    fi
    [[ -x /usr/local/bin/beep-llama-manager ]] \
      && dr ok llama manager "beep-llama-manager is installed." \
      || dr warn llama manager "beep-llama-manager is missing. Fix: sudo ./${SCRIPT_NAME} repair llama"
    [[ -x /opt/llama.cpp/current/llama-server ]] \
      && dr ok llama runtime "Pinned llama.cpp runtime is installed." \
      || dr warn llama runtime "Pinned runtime is missing. Fix: sudo ./${SCRIPT_NAME} repair llama"
    if systemctl is-active --quiet llama-server.service 2>/dev/null; then
      dr ok llama service "llama-server is active on loopback port 8080."
    else
      dr warn llama service "llama-server is stopped or failed. Fix: sudo beep-llama-manager restart"
    fi
  }

  local component
  for component in "${SELECTED_COMPONENTS[@]}"; do
    component_dispatch_hook "${component}" doctor
  done

  local n="${#d_status[@]}" i warns=0
  for (( i = 0; i < n; i++ )); do
    [[ "${d_status[i]}" == "warn" ]] && warns=$((warns + 1))
  done

  if (( JSON_OUTPUT )); then
    printf '{\n'
    printf '  "tool": "doctor",\n'
    printf '  "host": {"id": "%s", "version": "%s", "arch": "%s"},\n' \
      "$(json_escape "${ID:-}")" "$(json_escape "${VERSION_ID:-}")" "$(json_escape "${host_arch}")"
    printf '  "components": "%s",\n' "$(json_escape "$(selected_components_label)")"
    printf '  "warnings": %d,\n' "${warns}"
    printf '  "checks": [\n'
    for (( i = 0; i < n; i++ )); do
      printf '    {"component": "%s", "id": "%s", "status": "%s", "message": "%s"}' \
        "$(json_escape "${d_component[i]}")" "$(json_escape "${d_id[i]}")" "${d_status[i]}" "$(json_escape "${d_msg[i]}")"
      [[ $i -lt $((n - 1)) ]] && printf ','
      printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
    return 0
  fi

  printf '%s== beep doctor ==%s\n\n' "${C_BOLD}" "${C_RESET}"
  printf '%sHost:%s %s %s on %s\n' "${C_BOLD}" "${C_RESET}" \
    "${ID:-?}" "${VERSION_ID:-?}" "${host_arch}"
  printf '%sComponents:%s %s\n\n' "${C_BOLD}" "${C_RESET}" "$(selected_components_label)"
  for (( i = 0; i < n; i++ )); do
    case "${d_status[i]}" in
      ok)   ok   "[${d_component[i]}] ${d_msg[i]}" ;;
      warn) warn "[${d_component[i]}] ${d_msg[i]}" ;;
      *)    info "[${d_component[i]}] ${d_msg[i]}" ;;
    esac
  done
  echo
  if component_selected_for_lifecycle "${COMPONENT_BEEP}"; then
    info "For a runtime health summary: ${BEEP_DIR}/bin/beep-health"
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: repair
# ---------------------------------------------------------------------------

cmd_repair() {
  section "Repair"

  repair_beep() {
    if (( EXPLICIT_TARGETS )) && ! id "${AGENT_USER}" >/dev/null 2>&1 \
        && [[ ! -d "${BEEP_DIR}" ]]; then
      warn "Component 'beep' does not appear to be installed (user ${AGENT_USER} and ${BEEP_DIR} absent)."
      warn "  To install: sudo ./${SCRIPT_NAME} install beep"
    fi
    if id "${AGENT_USER}" >/dev/null 2>&1; then
      if [[ -f "${BEEP_DIR}/secrets/env" ]]; then
        chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/secrets/env"
        chmod 600 "${BEEP_DIR}/secrets/env"
        ok "Re-asserted secrets/env permissions."
      fi
      [[ -d "${BEEP_DIR}" ]] && chown -R "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}"
    fi
    if systemctl list-unit-files beep-chat.service >/dev/null 2>&1; then
      systemctl daemon-reload
      systemctl restart beep-chat.service || warn "Chat service failed to restart; see journalctl -u beep-chat"
      ok "Chat service restarted."
    fi
    if [[ -d "${BEEP_DIR}/agent/templates" ]]; then
      install -d -m 755 -o root -g root "${BEEP_DIR}/pi"
      install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" \
        "${BEEP_DIR}/state/logs" "${BEEP_DIR}/state/pi-mono-sessions" 2>/dev/null || true
      [[ ! -f "${BEEP_DIR}/agent/templates/settings.json.tmpl" ]] \
        || install -m 644 "${BEEP_DIR}/agent/templates/settings.json.tmpl" "${BEEP_DIR}/pi/settings.json"
      if [[ -f "${BEEP_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" ]]; then
        _facts="hostname=$(hostname) os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}")"
        sed -e "s|__AGENT_USER__|${AGENT_USER}|g" -e "s|__FACTS__|${_facts}|g" \
          "${BEEP_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" \
          | install -m 644 /dev/stdin "${BEEP_DIR}/pi/APPEND_SYSTEM.md"
      fi
      ok "pi-mono runtime configs re-rendered."
    fi
    if [[ -d "${PAYLOAD_DIR}/agent/skills" ]]; then
      install -d -m 755 -o root -g root "${BEEP_DIR}/skills"
      shopt -s nullglob
      for f in "${PAYLOAD_DIR}/agent/skills/"*.md; do
        install -m 644 -o root -g root "${f}" "${BEEP_DIR}/skills/$(basename "${f}")"
      done
      shopt -u nullglob
      install -d -m 755 -o root -g root "${BEEP_ETC}/skills.d"
      ok "Skill catalogue re-deployed."
    fi
  }

  repair_forgejo_runner() {
    if ! legacy_forgejo_runner_present; then
      warn "Component 'forgejo-runner' does not appear to be installed."
      warn "  To install: sudo ./${SCRIPT_NAME} install forgejo-runner"
      return
    fi
    [[ -x /usr/local/bin/forgejo && -s /etc/forgejo/app.ini ]] \
      || die "Forgejo runner repair requires a complete local Forgejo installation." 1
    systemctl is-active --quiet forgejo.service \
      || die "Forgejo must be active before its runner can be repaired." 1
    [[ -x /usr/local/bin/forgejo-runner ]] \
      || die "Forgejo runner binary is missing; re-run: sudo ./${SCRIPT_NAME} install forgejo-runner" 1
    id forgejo-runner >/dev/null 2>&1 \
      || die "Forgejo runner user is missing; re-run: sudo ./${SCRIPT_NAME} install forgejo-runner" 1
    [[ -s /var/lib/forgejo-runner/.runner ]] \
      || die "Forgejo runner registration is missing or empty; re-run: sudo ./${SCRIPT_NAME} install forgejo-runner" 1
    usermod -aG docker forgejo-runner
    chown forgejo-runner:forgejo-runner /var/lib/forgejo-runner \
      /var/lib/forgejo-runner/.runner
    chmod 750 /var/lib/forgejo-runner
    chmod 600 /var/lib/forgejo-runner/.runner
    install -m 640 -o root -g forgejo-runner \
      "${PAYLOAD_DIR}/etc/forgejo-runner-config.yaml" \
      /var/lib/forgejo-runner/config.yaml
    install -m 644 "${PAYLOAD_DIR}/systemd/forgejo-runner.service" \
      /etc/systemd/system/forgejo-runner.service
    remove_obsolete_forgejo_runner_drop_in
    systemctl enable --now docker.service >/dev/null 2>&1 \
      || die "Docker Engine failed to start; see journalctl -u docker." 1
    systemctl daemon-reload
    local runner_drop_ins
    runner_drop_ins="$(forgejo_runner_drop_in_paths)"
    [[ -z "${runner_drop_ins}" ]] \
      || die "Refusing to start the Forgejo runner with unmanaged systemd drop-ins: ${runner_drop_ins//$'\n'/ }. Reconcile them, then re-run repair." 1
    forgejo_runner_uses_managed_config \
      || die "The effective forgejo-runner unit ignores the managed config; inspect systemd drop-ins." 1
    forgejo_runner_in_docker_group && forgejo_runner_has_docker_access \
      || die "forgejo-runner cannot access the Docker daemon after repair." 1
    systemctl enable forgejo-runner.service >/dev/null \
      || die "Could not enable forgejo-runner.service during repair." 1
    systemctl restart forgejo-runner.service \
      || die "Forgejo runner failed to restart; see journalctl -u forgejo-runner." 1
    retry 6 2 -- forgejo_runner_declared_successfully \
      || die "Forgejo runner restarted but did not declare successfully; see journalctl -u forgejo-runner." 1
    ok "Forgejo runner ownership, configuration, and service re-asserted."
  }

  repair_forgejo() {
    if (( EXPLICIT_TARGETS )) \
        && [[ ! -d /etc/forgejo && ! -d /var/lib/forgejo && ! -x /usr/local/bin/forgejo ]]; then
      warn "Component 'forgejo' does not appear to be installed (no /etc/forgejo, /var/lib/forgejo, or /usr/local/bin/forgejo)."
      warn "  To install: sudo ./${SCRIPT_NAME} install forgejo"
    fi
    if [[ -d /etc/forgejo || -d /var/lib/forgejo ]]; then
      forgejo_config_has_recovery_material \
        || die "Refusing to repair or restart Forgejo because /etc/forgejo/app.ini is missing, empty, or incomplete. Recover the original config from backup; recreating its secrets requires a separate, backed-up recovery procedure." \
          1
      chown root:git /etc/forgejo
      chmod 750 /etc/forgejo
      chown root:git /etc/forgejo/app.ini
      chmod 640 /etc/forgejo/app.ini
      [[ -d /var/lib/forgejo ]] && { chown -R git:git /var/lib/forgejo; chmod 750 /var/lib/forgejo; }
      if [[ -f /etc/systemd/system/forgejo.service ]]; then
        systemctl daemon-reload
        systemctl restart forgejo.service \
          || die "Forgejo failed to restart; see journalctl -u forgejo." 1
      fi
      configure_forgejo_lan_https
      if forgejo_runner_is_forgejo_suboption; then
        repair_forgejo_runner
      fi
      ok "Forgejo ownership and services re-asserted."
    fi
  }

  repair_llama() {
    if [[ ! -f /etc/llama.cpp/managed-by-beep ]]; then
      warn "Component 'llama' is not managed by this installer."
      warn "  To install: sudo ./${SCRIPT_NAME} install llama"
      return
    fi
    local -a current=()
    mapfile -t current < <(python3 - /etc/llama.cpp/config.json <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["context_size"])
print(data["threads"])
PY
    ) || die "Could not read the managed llama configuration." 1
    (( ${#current[@]} == 2 )) \
      || die "Managed llama configuration is incomplete." 1
    local boot=disabled
    systemctl is-enabled --quiet llama-server.service 2>/dev/null \
      && boot=enabled
    info "Re-running the idempotent llama installer to verify and repair assets."
    env BEEP_NONINTERACTIVE=1 BEEP_INSTALL_LLAMA=0 \
      LLAMA_CONTEXT_SIZE="${current[0]}" LLAMA_CPU_THREADS="${current[1]}" \
      LLAMA_BOOT="${boot}" \
      "${SCRIPT_DIR}/install.sh" install llama --yes
  }

  local component
  for component in "${SELECTED_COMPONENTS[@]}"; do
    component_dispatch_hook "${component}" repair
  done
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
    (( BEEP_QUIET ))         && fwd+=(--quiet)
    (( UNINSTALL_ARCHIVE ))    && fwd+=(--archive)
    (( UNINSTALL_KEEP_AGENT )) && fwd+=(--keep-agent)
    [[ "${BEEP_COLOR:-}" == "never" ]] && fwd+=(--no-color)
    exec "${SCRIPT_DIR}/uninstall.sh" "${fwd[@]}" "${TARGET_ARGS[@]}"
  fi
  die "uninstall.sh not found alongside ${SCRIPT_NAME}." 1
}

# ---------------------------------------------------------------------------
# Dry-run summary (no host mutation; safe without sudo).
# ---------------------------------------------------------------------------

print_dry_run_plan() {
  load_os_release
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}  —  dry-run

A real install of the selected components would:

  Components:     $(selected_components_label)
  Host:           ${ID:-?} ${VERSION_ID:-?} on $(dpkg --print-architecture 2>/dev/null || uname -m)
  Transcript:     ${LOG_FILE}
  Receipt:        $([[ "${BEEP_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo "(disabled)")
EOF
  local component
  for component in "${SELECTED_COMPONENTS[@]}"; do
    component_dispatch_hook "${component}" dry_run
  done
  cat <<EOF

Nothing has been changed. To proceed for real:

  sudo ./${SCRIPT_NAME} install $(selected_components_label)

See docs/QUICKSTART.md and docs/ARCHITECTURE.md for the full picture.
EOF
}

print_beep_dry_run() {
  cat <<EOF

Beep component:
  Agent user:     ${AGENT_USER}  (home: ${AGENT_HOME})
  Install root:   ${BEEP_DIR}
  Etc dir:        ${BEEP_ETC}
  Log dir:        ${BEEP_LOG_DIR}
  Chat port:      ${CHAT_PORT}/tcp (loopback only)
  Mode:           $([[ "${BEEP_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)

Apt package groups installed:
  base            sudo, curl, git, editors, Python 3/venv, build-essential,
                  ripgrep, jq, logrotate, unattended-upgrades, …
  nodejs          Node 22.x from deb.nodesource.com (signed-by keyring)

Files & directories created / re-asserted:
  /etc/sudoers.d/90-${AGENT_USER}-beep   (NOPASSWD: ALL for ${AGENT_USER})
  ${BEEP_DIR}/                                  (755, ${AGENT_USER}:${AGENT_USER})
  ${BEEP_DIR}/secrets/                          (700, env file 600)
  ${BEEP_DIR}/bin/                              (verify, beep-health, beep-secrets-edit, beep-audit, …)
  ${BEEP_DIR}/agent/                            (Python package + templates + skills + pi bridge)
  ${BEEP_DIR}/pi/                               (rendered pi-mono settings + APPEND_SYSTEM.md)
  ${BEEP_DIR}/skills/                           (built-in markdown skills)
  ${BEEP_ETC}/skills.d/                         (operator-supplied skills)
  ${BEEP_LOG_DIR}/                              (750, ${AGENT_USER}:${AGENT_USER}, logrotate'd)
  /etc/systemd/system/beep-chat.service
  /etc/systemd/system/beep-health.service
  /etc/systemd/system/beep-health.timer
  /etc/logrotate.d/beep
EOF
}

print_forgejo_dry_run() {
  cat <<EOF

Optional components enabled:
  Forgejo server  git forge + PostgreSQL (${FORGEJO_VERSION:-latest release})
                  apt: git-lfs postgresql postgresql-contrib openssl xz-utils
                       caddy avahi-daemon libnss-mdns
                  binary: /usr/local/bin/forgejo (checksum-verified download)
                  data: /var/lib/forgejo (git:git)  config: /etc/forgejo/app.ini
                  database: ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD_SOURCE}"))
                  admin: ${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD_SOURCE}"))
                  unit: /etc/systemd/system/forgejo.service
                  exposure: https://$(forgejo_url_host)/ via mDNS + Caddy internal CA
                  backend: 127.0.0.1:${FORGEJO_HTTP_PORT} (not directly exposed)
EOF
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"; then
    print_forgejo_runner_dry_run
  fi
}

print_forgejo_runner_dry_run() {
  cat <<EOF

Forgejo runner component:
  Actions runner  co-located Forgejo Actions runner (restricted Docker executor)
                  Docker: reuse existing engine, otherwise apt: docker.io
                  binary: /usr/local/bin/forgejo-runner (${FORGEJO_RUNNER_VERSION:-latest release})
                  registers against 127.0.0.1:${FORGEJO_HTTP_PORT} with labels:
                    ${FORGEJO_RUNNER_LABELS}
                  unit: /etc/systemd/system/forgejo-runner.service
                  dependency: Forgejo server component
                  note: co-locating runner and forge is contrary to upstream
                        guidance and is enabled deliberately.
EOF
}

print_llama_dry_run() {
  cat <<EOF

Llama component:
  Runtime:        llama.cpp $(llama_catalog_release) (checksum-verified upstream CPU binary)
  Model:          SmolLM2 360M Instruct Q4_K_M (Apache-2.0, verified GGUF)
  API:            http://127.0.0.1:${LLAMA_PORT}/v1 (loopback only)
  Context:        ${LLAMA_CONTEXT_SIZE} tokens
  CPU threads:    ${LLAMA_CPU_THREADS}
  Start at boot:  ${LLAMA_BOOT}
  Manager:        /usr/local/bin/beep-llama-manager
  Data:           /var/lib/llama.cpp
  Beep impact:  none; this is an independent component
EOF
}

# ---------------------------------------------------------------------------
# Interactive parameter review (Beep Orchid setup experience)
# ---------------------------------------------------------------------------
# A branded, editable summary of every install parameter. The operator can
# tweak any field and re-review until satisfied, then accept. Skipped in
# non-interactive / --yes runs and when stdin is not a TTY, so automated
# installs are unaffected.

# Render the current parameters as a glance-able, brand-coloured table.
print_parameter_table() {
  load_os_release
  local receipt_state
  if [[ "${BEEP_RECEIPT}" == "1" ]]; then
    receipt_state="${RECEIPT_FILE}"
  else
    receipt_state="disabled"
  fi

  brand_banner "Beep — setup parameters"
  printf '  %sReview every setting below, edit any of them, then accept when happy.%s\n\n' \
    "${C_DIM}" "${C_RESET}"
  field "1) Agent user"      "${AGENT_USER}"
  field "   Agent home"      "${AGENT_HOME}" "${C_DIM}"
  field "2) Install root"    "${BEEP_DIR}"
  field "3) Chat port"       "${CHAT_PORT}/tcp (loopback only)"
  field "4) Transcript log"  "${LOG_FILE}"
  field "5) Receipt file"    "${receipt_state}"
  field "6) Chat password"   "$([[ "${ADMIN_PASSWORD_SET}" == "1" ]] && echo 'set (hidden)' || printf 'default (%s)' "${BEEP_ADMIN_PASSWORD_DEFAULT}")"
  field "7) Time to Live"    "${TTL_DAYS} day(s) then permanently disabled"
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    field "8) Local LLM"     "${LOCAL_LLM_MODEL} @ ${LOCAL_LLM_BASE_URL}"
  elif model_selection_configured; then
    field "8) Local LLM"     "skipped (an existing model is configured)" "${C_DIM}"
  else
    field "8) Local LLM"     "none (scan LAN for an OpenAI-compatible server)" "${C_DIM}"
  fi
  field "   Host"            "${ID:-?} ${VERSION_ID:-?} ($(dpkg --print-architecture 2>/dev/null || uname -m))" "${C_DIM}"
  printf '\n'
}

# One-line summary of every enabled optional component, for row 9.
options_summary() {
  local parts=()
  if [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]]; then
    local runner_state="off"
    [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] && runner_state="on"
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
_edit_beep_dir() {
  local v
  if prompt_until_valid "$(printf 'New install root [%s]: ' "${BEEP_DIR}")" \
       is_safe_absolute_path v 1 && [[ -n "${v}" ]]; then
    BEEP_DIR="${v}"
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
  if [[ "${BEEP_RECEIPT}" == "1" ]]; then
    local v
    printf 'Receipt is ON. Press Enter to turn it OFF, or type a new path: '
    if read -r v && [[ -n "${v}" ]]; then
      if is_safe_absolute_path "${v}"; then
        RECEIPT_FILE="${v}"; info "Receipt path set to ${RECEIPT_FILE}."
      else
        warn "Not a safe absolute path; receipt unchanged."
      fi
    else
      BEEP_RECEIPT=0; info "Receipt disabled."
    fi
  else
    BEEP_RECEIPT=1; info "Receipt enabled: ${RECEIPT_FILE}."
  fi
}
_edit_admin_password() {
  local p1 p2
  [[ "${BEEP_NONINTERACTIVE}" == "1" || ! -t 0 ]] && return 0
  if ! read -r -s -p "New chat password (blank to keep the default '${BEEP_ADMIN_PASSWORD_DEFAULT}'): " p1; then
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
  ok "Forgejo admin password accepted (not recorded)."
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
  ok "Forgejo database password accepted (not recorded)."
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
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
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
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    BEEP_INSTALL_FORGEJO_RUNNER=0
    info "Forgejo Actions runner disabled."
  else
    BEEP_INSTALL_FORGEJO_RUNNER=1
    warn "Co-locating the runner with the forge is contrary to upstream guidance; enabling deliberately."
    info "Forgejo Actions runner enabled (restricted Docker executor)."
  fi
}

_toggle_forgejo() {
  if [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]]; then
    BEEP_INSTALL_FORGEJO=0
    BEEP_INSTALL_FORGEJO_RUNNER=0
    info "Forgejo server disabled."
  else
    BEEP_INSTALL_FORGEJO=1
    info "Forgejo server enabled (PostgreSQL-backed, port ${FORGEJO_HTTP_PORT})."
  fi
}

# Render the current optional components as a glance-able sub-table.
print_options_table() {
  brand_banner "Beep — optional components"
  printf '  %sEvery option is off by default and reversible by uninstall.sh.%s\n\n' \
    "${C_DIM}" "${C_RESET}"
  if [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]]; then
    field "1) Forgejo server"  "enabled"
    field "2) Forgejo port"    "${FORGEJO_HTTP_PORT}/tcp (loopback backend)"
    field "3) Forgejo admin"   "${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD_SOURCE}"))"
    field "4) Actions runner"  "$([[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo 'enabled (restricted Docker executor, same host)' || echo 'disabled')"
    field "5) Database"        "PostgreSQL ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD_SOURCE}"))"
    if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
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
      2) [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_port \
           || warn "Enable the Forgejo server first (option 1)." ;;
      3) [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_admin \
           || warn "Enable the Forgejo server first (option 1)." ;;
      4) [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]] && _toggle_forgejo_runner \
           || warn "Enable the Forgejo server first (option 1)." ;;
      5) [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_database \
           || warn "Enable the Forgejo server first (option 1)." ;;
      6) [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]] && _edit_forgejo_versions \
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

# Ensure secrets/env carries a BEEP_ADMIN_PASSWORD_HASH line. The hash is
# (re)written when it is missing, or when the operator explicitly chose a
# password this run (ADMIN_PASSWORD_SET=1); an existing hash is otherwise
# preserved so a plain re-install never resets a customised password.
ensure_admin_password_hash() {
  local file="$1" hash has_line=0
  grep -q '^BEEP_ADMIN_PASSWORD_HASH=' "${file}" 2>/dev/null && has_line=1
  if [[ "${has_line}" -eq 1 && "${ADMIN_PASSWORD_SET}" != "1" ]]; then
    return 0
  fi
  if ! hash="$(admin_password_hash "${ADMIN_PASSWORD:-${BEEP_ADMIN_PASSWORD_DEFAULT}}")"; then
    die "Failed to hash the chat password." 1
  fi
  if [[ "${has_line}" -eq 1 ]]; then
    sed -i -E '/^BEEP_ADMIN_PASSWORD_HASH=/d' "${file}"
  fi
  [[ -s "${file}" ]] && [[ "$(tail -c1 "${file}" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${file}"
  printf 'BEEP_ADMIN_PASSWORD_HASH=%s\n' "${hash}" >> "${file}"
}

# Initialise the Time-to-Live kill switch on first install. Reinstalls preserve
# valid lifecycle state, including extensions and tombstones, so an upgrade
# cannot silently change an operator's existing TTL decision.
init_lifecycle_state() {
  local state="${BEEP_DIR}/state/lifecycle.json" current
  if [[ -s "${state}" ]]; then
    chown "${AGENT_USER}:${AGENT_USER}" "${state}"
    chmod 600 "${state}"
    if current="$(runuser -u "${AGENT_USER}" -- env \
          BEEP_LIFECYCLE_STATE="${state}" \
          python3 "${BEEP_DIR}/agent/lifecycle.py" status 2>/dev/null)" \
        && grep -Eq '"configured":[[:space:]]*true' <<<"${current}"; then
      ok "Preserving existing Time to Live state."
      return 0
    fi
    warn "Existing Time-to-Live state is invalid; creating a fresh countdown."
  fi
  if ! runuser -u "${AGENT_USER}" -- env \
        BEEP_LIFECYCLE_STATE="${state}" \
        python3 "${BEEP_DIR}/agent/lifecycle.py" init --days "${TTL_DAYS}" >/dev/null; then
    die "Failed to initialise the Time-to-Live state." 1
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${state}"
  chmod 600 "${state}"
  ok "Time to Live set: ${TTL_DAYS} day(s) until the beep is disabled."
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
  port="${BEEP_LLM_SCAN_PORT}"
  if ! is_valid_tcp_port "${port}"; then
    warn "BEEP_LLM_SCAN_PORT='${port}' is not a valid TCP port (1-65535); skipping LLM discovery."
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
# BEEP_SKIP_LLM_SCAN=1.
discover_local_llms() {
  local force="${1:-0}"
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0
  [[ "${BEEP_SKIP_LLM_SCAN}" == "1" ]] && return 0
  if [[ "${force}" != "1" ]] && model_selection_configured; then
    info "A model is already configured; preserving it and skipping local LLM discovery."
    return 0
  fi

  scan_local_llms || return 0

  local i choice
  while true; do
    brand_banner "Local LLM servers discovered on your network"
    printf '  %sPick a model to use as the starting model, or skip to configure a%s\n' "${C_DIM}" "${C_RESET}"
    printf '  %scloud provider later in %s/secrets/env.%s\n\n' "${C_DIM}" "${BEEP_DIR}" "${C_RESET}"
    for i in "${!DISCOVERED_MODELS[@]}"; do
      printf '  %s%2d)%s %s%s  @  http://%s/v1%s\n' \
        "${C_BRAND2}" "$((i + 1))" "${C_RESET}" "${C_ACCENT}" \
        "${DISCOVERED_MODELS[$i]}" "${DISCOVERED_ENDPOINTS[$i]}" "${C_RESET}"
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
  discover_local_llms 1
}

review_parameters() {
  # Automated paths skip the review entirely.
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0

  local choice
  while true; do
    print_parameter_table
    printf '  %s[a]%s accept and install    %s[1-8]%s edit a field    %s[q]%s cancel\n' \
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
      2)  _edit_beep_dir ;;
      3)  _edit_chat_port ;;
      4)  _edit_log_file ;;
      5)  _toggle_receipt ;;
      6)  _edit_admin_password ;;
      7)  _edit_ttl_days ;;
      8)  _edit_local_llm ;;
      *)  warn "Unrecognised choice: '${choice}'. Enter a number 1-8, 'a', or 'q'." ;;
    esac
  done
}

review_forgejo_parameters() {
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0

  local choice
  while true; do
    load_os_release
    brand_banner "Forgejo — setup parameters"
    field "1) Forgejo port"   "${FORGEJO_HTTP_PORT}/tcp (loopback backend)"
    field "2) Forgejo admin"  "${FORGEJO_ADMIN_USER} <${FORGEJO_ADMIN_EMAIL}> (password $(password_source_label "${FORGEJO_ADMIN_PASSWORD_SOURCE}"))"
    field "3) PostgreSQL database" "PostgreSQL ${FORGEJO_DB_NAME} (role ${FORGEJO_DB_USER}, password $(password_source_label "${FORGEJO_DB_PASSWORD_SOURCE}"))"
    field "4) Actions runner" "$([[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo 'enabled (restricted Docker executor, same host)' || echo disabled)"
    field "5) Versions"       "Forgejo ${FORGEJO_VERSION:-latest release}"
    field "6) Core records"   "${LOG_FILE}; $([[ "${BEEP_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo 'receipt disabled')"
    field "   Host"           "${ID:-?} ${VERSION_ID:-?} ($(dpkg --print-architecture 2>/dev/null || uname -m))" "${C_DIM}"
    printf '\n  %s[a]%s accept and install    %s[1-6]%s edit a field    %s[q]%s cancel\n' \
      "${C_ACCENT}" "${C_RESET}" "${C_BRAND2}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}"
    if ! read -r -p "$(printf '%s➜%s your choice [a]: ' "${C_BRAND}" "${C_RESET}")" choice; then
      info "No input (EOF); cancelling."; exit 0
    fi
    case "${choice,,}" in
      ""|a|accept|y|yes)
        validate_config
        REVIEWED=1
        ok "Parameters accepted."
        return 0 ;;
      q|quit|cancel|n|no) info "Cancelled."; exit 0 ;;
      1) _edit_forgejo_port ;;
      2) _edit_forgejo_admin ;;
      3) _edit_forgejo_database ;;
      4) _toggle_forgejo_runner ;;
      5) _edit_forgejo_versions ;;
      6) _edit_log_file; _toggle_receipt ;;
      *) warn "Unrecognised choice: '${choice}'. Enter a number 1-6, 'a', or 'q'." ;;
    esac
  done
}

review_forgejo_runner_parameters() {
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0

  brand_banner "Forgejo runner — setup parameters"
  field "Version" "${FORGEJO_RUNNER_VERSION:-latest release}"
  field "Labels" "${FORGEJO_RUNNER_LABELS}"
  field "Executor" "restricted Docker executor, co-located with Forgejo"
  local choice
  if ! read -r -p "$(printf '%s➜%s install these settings? [Y/n]: ' "${C_BRAND}" "${C_RESET}")" choice; then
    info "No input (EOF); cancelling."
    exit 0
  fi
  case "${choice,,}" in
    ""|y|yes) REVIEWED=1 ;;
    *) info "Cancelled."; exit 0 ;;
  esac
}

review_llama_parameters() {
  [[ "${BEEP_NONINTERACTIVE}" == "1" ]] && return 0
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 0

  brand_banner "Standalone llama — setup parameters"
  field "API" "http://127.0.0.1:${LLAMA_PORT}/v1 (PC-wide loopback)"
  field "Model" "${LLAMA_MODEL_ID} (about 271 MB)"
  field "Context" "${LLAMA_CONTEXT_SIZE} tokens"
  field "CPU threads" "${LLAMA_CPU_THREADS}"
  field "Start at boot" "${LLAMA_BOOT}"
  local choice
  if ! read -r -p "$(printf '%s➜%s install these settings? [Y/n]: ' "${C_BRAND}" "${C_RESET}")" choice; then
    info "No input (EOF); cancelling."
    exit 0
  fi
  case "${choice,,}" in
    ""|y|yes) REVIEWED=1 ;;
    *) info "Cancelled."; exit 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Install receipt (start + finish records)
# ---------------------------------------------------------------------------
# A human-readable record of the install. Written once when the run starts
# (every parameter) and finalised with the outcome when it ends. The file is
# root-only (mode 600). Operator-supplied password values and provider keys
# are never written; passwords the installer generates itself are recorded
# in the finish record so the operator can retrieve them.

receipt_start_beep() {
  printf 'Agent user       : %s\n' "${AGENT_USER}"
  printf 'Agent home       : %s\n' "${AGENT_HOME}"
  printf 'Install root     : %s\n' "${BEEP_DIR}"
  printf 'Etc dir          : %s\n' "${BEEP_ETC}"
  printf 'Log dir          : %s\n' "${BEEP_LOG_DIR}"
  printf 'Chat port        : %s/tcp (loopback only)\n' "${CHAT_PORT}"
  printf 'Local LLM        : %s\n' \
    "$([[ -n "${LOCAL_LLM_MODEL}" ]] && printf '%s @ %s' "${LOCAL_LLM_MODEL}" "${LOCAL_LLM_BASE_URL}" || echo 'none')"
}

receipt_start_forgejo() {
  printf 'Forgejo server   : enabled\n'
  printf 'Forgejo URL      : https://%s/ (mDNS; Caddy local CA)\n' \
    "$(forgejo_url_host)"
  printf 'Forgejo backend  : 127.0.0.1:%s/tcp\n' "${FORGEJO_HTTP_PORT}"
  printf 'Forgejo admin    : %s <%s> (password %s)\n' \
    "${FORGEJO_ADMIN_USER}" "${FORGEJO_ADMIN_EMAIL}" \
    "$(password_source_label "${FORGEJO_ADMIN_PASSWORD_SOURCE}")"
  printf 'Forgejo database : %s (role %s; password %s)\n' \
    "${FORGEJO_DB_NAME}" "${FORGEJO_DB_USER}" \
    "$(password_source_label "${FORGEJO_DB_PASSWORD_SOURCE}")"
  printf 'Forgejo version  : %s\n' "${FORGEJO_VERSION:-latest (resolved at install)}"
  if ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"; then
    printf 'Actions runner   : %s\n' \
      "$([[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] && echo 'enabled (co-located, restricted Docker executor)' || echo disabled)"
  fi
}

receipt_start_forgejo_runner() {
  printf 'Actions runner   : enabled (co-located, restricted Docker executor)\n'
  printf 'Runner version   : %s\n' \
    "${FORGEJO_RUNNER_VERSION:-latest (resolved at install)}"
  printf 'Runner labels    : %s\n' "${FORGEJO_RUNNER_LABELS}"
}

receipt_start_llama() {
  printf 'Llama component  : standalone PC-wide service\n'
  printf 'Llama API        : http://127.0.0.1:%s/v1 (loopback only)\n' "${LLAMA_PORT}"
  printf 'Llama runtime    : %s\n' "$(llama_catalog_release)"
  printf 'Llama model      : %s\n' "${LLAMA_MODEL_ID}"
  printf 'Llama context    : %s tokens; %s CPU threads\n' \
    "${LLAMA_CONTEXT_SIZE}" "${LLAMA_CPU_THREADS}"
}

receipt_finish_beep() {
  printf 'Provider token   : %s\n' "$([[ "${PROVIDER_OK:-0}" == "1" ]] && echo present || echo missing)"
  printf 'Chat service     : %s\n' "$([[ "${CHAT_OK:-0}" == "1" ]] && echo running || echo 'not running')"
}

receipt_finish_forgejo() {
  printf 'Forgejo version  : %s\n' "${FORGEJO_RESOLVED_VERSION:-unknown}"
  printf 'Forgejo service  : %s\n' \
    "$(systemctl is-active --quiet forgejo.service 2>/dev/null && echo running || echo 'not running')"
  printf 'Forgejo secrets  : generated (stored only in /etc/forgejo/app.ini, mode 640)\n'
  printf 'Forgejo admin pw : %s\n' \
    "$(receipt_password_line "${FORGEJO_ADMIN_PASSWORD_SOURCE}" "${FORGEJO_ADMIN_PASSWORD}")"
  printf 'Forgejo DB pw    : %s\n' \
    "$(receipt_password_line "${FORGEJO_DB_PASSWORD_SOURCE}" "${FORGEJO_DB_PASSWORD}")"
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"; then
    printf 'Actions runner   : %s\n' \
      "$(systemctl is-active --quiet forgejo-runner.service 2>/dev/null && echo running || echo 'not running')"
  fi
}

receipt_finish_forgejo_runner() {
  printf 'Runner version   : %s\n' \
    "${FORGEJO_RUNNER_RESOLVED_VERSION:-unknown}"
  printf 'Actions runner   : %s\n' \
    "$(systemctl is-active --quiet forgejo-runner.service 2>/dev/null && echo running || echo 'not running')"
}

receipt_finish_llama() {
  printf 'Llama service    : %s\n' \
    "$(systemctl is-active --quiet llama-server.service 2>/dev/null && echo running || echo 'not running')"
}

write_receipt_start() {
  [[ "${BEEP_RECEIPT}" == "1" ]] || return 0
  load_os_release
  if ! mkdir -p "$(dirname "${RECEIPT_FILE}")" 2>/dev/null; then
    warn "Could not create receipt directory; receipt disabled for this run."
    BEEP_RECEIPT=0
    return 0
  fi
  if [[ -f "${RECEIPT_FILE}" ]]; then
    chmod 600 "${RECEIPT_FILE}" 2>/dev/null || true
  elif ! install -m 600 /dev/null "${RECEIPT_FILE}" 2>/dev/null; then
    warn "Could not create the install receipt at ${RECEIPT_FILE}."
    BEEP_RECEIPT=0
    return 0
  fi

  if ! {
    printf '============================================================\n'
    printf 'Beep — install receipt\n'
    printf '============================================================\n'
    printf 'Phase            : START\n'
    printf 'Started (UTC)    : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Installer        : %s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
    printf 'Host             : %s %s (%s)\n' "${ID:-?}" "${VERSION_ID:-?}" \
      "$(dpkg --print-architecture 2>/dev/null || uname -m)"
    printf 'Invoked by       : %s (uid %s)\n' "${SUDO_USER:-$(id -un)}" "$(id -u)"
    printf 'Mode             : %s\n' \
      "$([[ "${BEEP_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"
    printf 'Components       : %s\n' "$(selected_components_label)"
    printf '\n-- Parameters --\n'
    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
      component_dispatch_hook "${component}" receipt_start
    done
    printf 'Transcript log   : %s\n' "${LOG_FILE}"
    printf 'Receipt file     : %s\n' "${RECEIPT_FILE}"
    printf '============================================================\n'
  } >> "${RECEIPT_FILE}" 2>/dev/null; then
    warn "Could not write the install receipt to ${RECEIPT_FILE}."
    BEEP_RECEIPT=0
    return 0
  fi
  chmod 600 "${RECEIPT_FILE}" 2>/dev/null || true
  info "Install receipt opened: ${RECEIPT_FILE}"
}

write_receipt_finish() {
  [[ "${BEEP_RECEIPT}" == "1" ]] || return 0
  [[ -f "${RECEIPT_FILE}" ]] || return 0
  {
    printf '\n-- Finish --\n'
    printf 'Phase            : FINISH\n'
    printf 'Result           : SUCCESS\n'
    printf 'Finished (UTC)   : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${INSTALL_T0:-}" ]]; then
      printf 'Duration         : %s\n' "$(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")"
    fi
    local component
    for component in "${SELECTED_COMPONENTS[@]}"; do
      component_dispatch_hook "${component}" receipt_finish
    done
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
  [[ "${BEEP_RECEIPT}" == "1" ]] || return 0
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

validate_component_registry \
  "validate review dry_run receipt_start receipt_finish install manifest final legacy verify doctor repair phase_count"
resolve_lifecycle_targets_from_manifest
restore_forgejo_runner_intent
validate_config

if [[ "${SUBCOMMAND}" != "uninstall" ]] \
  && (( UNINSTALL_ARCHIVE || UNINSTALL_KEEP_AGENT )); then
  die "--archive/--keep-agent only apply to the uninstall subcommand." 2
fi
if [[ "${SUBCOMMAND}" == "uninstall" ]] && (( EXPLICIT_TARGETS )) \
  && ! is_selected_component "${COMPONENT_BEEP}" \
  && (( UNINSTALL_ARCHIVE || UNINSTALL_KEEP_AGENT )); then
  die "--archive/--keep-agent only apply to a beep uninstall target." 2
fi

case "${SUBCOMMAND}" in
  # Verify reports failed health checks via its own output and exit status.
  # Do not let the install-time ERR trap re-label those expected failures as
  # installer crashes, especially when --json is feeding monitoring. Other
  # lifecycle subcommands keep the trap because their failures are mutations
  # or diagnostics that should retain the normal installer error context.
  verify)    trap - ERR; cmd_verify; exit $? ;;
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

# =============================================================================
# install — the rest of the file
# =============================================================================

require_root
validate_noninteractive

if is_selected_component "${COMPONENT_FORGEJO}" \
    && established_forgejo_state_present \
    && ! forgejo_config_has_recovery_material; then
  die "Refusing to install or update Forgejo because existing component state was found but /etc/forgejo/app.ini is missing, empty, or incomplete. Recover the original config from backup; secret rotation requires a separate, backed-up recovery procedure." 1
fi

if is_selected_component "${COMPONENT_FORGEJO}" && legacy_forgejo_present; then
  warn "An existing Forgejo installation was detected. The installer will update it in place and preserve repositories and database data."
  require_capitalized_yes FORGEJO_CONFIRM_UPDATE \
    "Allow Beep to update the existing Forgejo installation?"
fi

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
# --yes / non-interactive / non-TTY runs, when BEEP_SKIP_LLM_SCAN=1, or when
# an environment or installed secrets file already selects a model.
if is_selected_component "${COMPONENT_BEEP}"; then
  discover_local_llms
fi

# Interactive review: each selected component owns its parameter page. This
# keeps a beep-only install from asking about unselected options.
for component in "${SELECTED_COMPONENTS[@]}"; do
  component_dispatch_hook "${component}" review
done
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
BEEP_PHASE=0
SECTION_RULE_WIDTH=60
_count_option_sections() {
  awk -v m="$1" '
    $0 ~ "^ *# option-sections: " m " begin$" {f=1}
    f && /^ +section "/ {c++}
    $0 ~ "^ *# option-sections: " m " end$" {f=0}
    END {print c+0}
  ' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0
}
count_beep_phases() {
  awk '/^# install — the rest of the file/{f=1} f && /^section "/{c++} END{print c+0}' \
    "${BASH_SOURCE[0]}" 2>/dev/null || echo 0
}
count_forgejo_phases() {
  local count
  count="$(_count_option_sections forgejo)"
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"; then
    count=$(( count + $(_count_option_sections forgejo-runner) ))
  fi
  printf '%s\n' "${count}"
}
count_forgejo_runner_phases() {
  _count_option_sections forgejo-runner
}
count_llama_phases() {
  _count_option_sections llama
}
BEEP_PHASE_TOTAL=0
for component in "${SELECTED_COMPONENTS[@]}"; do
  component_phase_count="$(component_dispatch_hook "${component}" phase_count)"
  [[ "${component_phase_count}" =~ ^[0-9]+$ ]] || component_phase_count=0
  BEEP_PHASE_TOTAL=$(( BEEP_PHASE_TOTAL + component_phase_count ))
done
_SECTION_T0=""

# Re-define section() to record a breadcrumb, number each phase, and report
# how long the previous phase took in a plain-English "Completed in …" line,
# without surrounding every transition in three heavy separator lines.
section() {
  local now; now="$(date +%s)"
  if [[ -n "${_SECTION_T0}" ]]; then
    (( BEEP_QUIET )) || printf '%s    Completed in %s%s\n' \
      "${C_DIM}" "$(fmt_duration "$(( now - _SECTION_T0 ))")" "${C_RESET}"
  fi
  _SECTION_T0="${now}"
  BEEP_PHASE=$(( BEEP_PHASE + 1 ))
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STEP_LOG}" || true
  (( BEEP_QUIET )) && return 0
  local counter
  if (( BEEP_PHASE_TOTAL > 0 )); then
    counter="[${BEEP_PHASE}/${BEEP_PHASE_TOTAL}]"
  else
    counter="[${BEEP_PHASE}]"
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
info "Components: $(selected_components_label)"
if is_selected_component "${COMPONENT_BEEP}"; then
  info "Agent user: ${AGENT_USER}"
  info "Install root: ${BEEP_DIR}"
  info "Chat port: ${CHAT_PORT} (loopback only)"
fi
info "Mode: $([[ "${BEEP_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"
if (( BEEP_PHASE_TOTAL > 0 )); then
  info "Phases: ${BEEP_PHASE_TOTAL}. Typical run takes ~10–20 min depending on selected components and network speed."
else
  info "Typical run takes ~5–20 min depending on selected components and network speed."
fi

if is_selected_component "${COMPONENT_BEEP}"; then
  cat <<EOF

This installer will:
  - Create the ${AGENT_USER} user (operating identity of the AI Systems Administrator) with passwordless sudo
  - Install Python and Node agent runtimes
  - Install the loopback chat service (beep-chat.service)
  - Install policy, audit log, and helper scripts
  - Enable automatic security updates
EOF
elif is_selected_component "${COMPONENT_FORGEJO}"; then
  cat <<EOF

This installer will:
  - Install PostgreSQL and Forgejo without creating a beep account
  - Expose Forgejo at https://$(forgejo_url_host)/ through Caddy and Avahi
  - Keep installer-owned transcript and root-only receipt records under /var/log
EOF
else
  cat <<EOF

This installer will:
  - Install a standalone llama.cpp CPU runtime and small default model
  - Run an OpenAI-compatible API on 127.0.0.1:8080
  - Install beep-llama-manager without creating or changing a beep account
EOF
fi
if [[ "${BEEP_INSTALL_FORGEJO}" == "1" ]]; then
  printf '  - Install Forgejo + PostgreSQL with LAN HTTPS at https://%s/\n' \
    "$(forgejo_url_host)"
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    printf '  - Install a co-located Forgejo Actions runner (restricted Docker executor)\n'
  fi
  if [[ "${BEEP_INSTALL_LLAMA}" == "1" ]]; then
    printf '  - Install the independent PC-wide llama.cpp service on 127.0.0.1:8080\n'
  fi
fi
cat <<EOF

Run this from the physical Ubuntu machine, not over public SSH.

EOF

if [[ "${BEEP_NONINTERACTIVE}" == "1" ]]; then
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

install_beep_base() {
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

SUDOERS_FILE="/etc/sudoers.d/90-${AGENT_USER}-beep"
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
# Workspace at /opt/beep
# ---------------------------------------------------------------------------

section "Prepare application state"

install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" "${BEEP_DIR}" \
  "${BEEP_DIR}/bin" "${BEEP_DIR}/logs" "${BEEP_DIR}/state" \
  "${BEEP_DIR}/scripts" "${BEEP_DIR}/tools" "${BEEP_DIR}/agent" \
  "${BEEP_DIR}/agent/templates"
install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${BEEP_DIR}/secrets"
install -d -m 755 "${BEEP_ETC}"
install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" "${BEEP_LOG_DIR}"

if [[ ! -f "${BEEP_DIR}/secrets/env" ]]; then
  install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${BEEP_DIR}/secrets/env"
  cat > "${BEEP_DIR}/secrets/env" <<EOF
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
#   BEEP_PROVIDER=openai      # openai|anthropic|gemini|xai|openrouter|mistral|groq|lmstudio
#   BEEP_MODEL=gpt-4o-mini    # model for the agent loop + chat (required for openrouter/lmstudio)
#   LMSTUDIO_API_KEY=local      # local OpenAI-compatible server (LM Studio, Ollama,
#                               # llama.cpp). Pair with BEEP_PROVIDER=lmstudio; the
#                               # server URL lives in ~/.pi/agent/models.json.
#   BEEP_CHAT_PORT=${CHAT_PORT}

DISPLAY=:0
BEEP_DIR=${BEEP_DIR}
AGENT_USER=${AGENT_USER}
AGENT_HOME=${AGENT_HOME}
BEEP_CHAT_PORT=${CHAT_PORT}
EOF
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    cat >> "${BEEP_DIR}/secrets/env" <<EOF

# Local LLM auto-discovered on the LAN during install: an OpenAI-compatible
# server at ${LOCAL_LLM_BASE_URL}. The agent loop (pi-mono / the actual chat
# answers) reaches it through the custom 'lmstudio' provider defined in
# ${AGENT_HOME}/.pi/agent/models.json, which carries the server URL. Most local
# servers ignore the API key; replace it if yours requires one.
BEEP_PROVIDER=lmstudio
BEEP_MODEL=${LOCAL_LLM_MODEL}
LMSTUDIO_API_KEY=${BEEP_LOCAL_LLM_API_KEY}
EOF
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/secrets/env"
  chmod 600 "${BEEP_DIR}/secrets/env"
  if [[ -n "${LOCAL_LLM_MODEL}" ]]; then
    write_pi_models_json "${LOCAL_LLM_BASE_URL}" "${LOCAL_LLM_MODEL}"
    ok "Created ${BEEP_DIR}/secrets/env with local LLM ${LOCAL_LLM_MODEL} at ${LOCAL_LLM_BASE_URL}."
  else
    ok "Created ${BEEP_DIR}/secrets/env (edit with: sudo ${BEEP_DIR}/bin/beep-secrets-edit)."
  fi
else
  info "Preserving existing ${BEEP_DIR}/secrets/env."
  if grep -q '^BEEP_CHAT_PORT=' "${BEEP_DIR}/secrets/env"; then
    sed -i -E "s|^BEEP_CHAT_PORT=.*$|BEEP_CHAT_PORT=${CHAT_PORT}|" "${BEEP_DIR}/secrets/env"
  else
    [[ -s "${BEEP_DIR}/secrets/env" ]] && [[ "$(tail -c1 "${BEEP_DIR}/secrets/env" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${BEEP_DIR}/secrets/env"
    printf 'BEEP_CHAT_PORT=%s\n' "${CHAT_PORT}" >> "${BEEP_DIR}/secrets/env"
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
    sed -i -E '/^(BEEP_PROVIDER|BEEP_MODEL|LMSTUDIO_API_KEY)=/d' \
      "${BEEP_DIR}/secrets/env"
    [[ -s "${BEEP_DIR}/secrets/env" ]] && [[ "$(tail -c1 "${BEEP_DIR}/secrets/env" 2>/dev/null)" != $'\n' ]] && printf '\n' >> "${BEEP_DIR}/secrets/env"
    {
      printf 'BEEP_PROVIDER=lmstudio\n'
      printf 'BEEP_MODEL=%s\n' "${LOCAL_LLM_MODEL}"
      printf 'LMSTUDIO_API_KEY=%s\n' "${BEEP_LOCAL_LLM_API_KEY}"
    } >> "${BEEP_DIR}/secrets/env"
    write_pi_models_json "${LOCAL_LLM_BASE_URL}" "${LOCAL_LLM_MODEL}"
    ok "Applied local LLM ${LOCAL_LLM_MODEL} at ${LOCAL_LLM_BASE_URL} to existing secrets/env."
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/secrets/env"
  chmod 600 "${BEEP_DIR}/secrets/env"
fi

# Stamp the chat-UI password hash into secrets/env (idempotent: keeps an
# existing hash unless the operator chose a new password this run).
ensure_admin_password_hash "${BEEP_DIR}/secrets/env"
chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/secrets/env"
chmod 600 "${BEEP_DIR}/secrets/env"
# ---------------------------------------------------------------------------
# Python cloud-agent runtime
# ---------------------------------------------------------------------------

section "Build the Python runtime"

# Stage the venv setup helper into ${BEEP_DIR}/bin early so the
# unprivileged setup below can exec it. The rest of the operator
# helpers are installed in the "Deploy chat service" section below.
# Extracted in FIX-1-12 so the body is lintable by ShellCheck.
install -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/bin/beep-setup-venv" "${BEEP_DIR}/bin/beep-setup-venv"

# Build the venv and install Python packages as the agent user. On an
# interactive TTY show a heartbeat spinner and route the detail to the
# transcript, while non-interactive/CI runs keep the full output streaming.
if [[ -t 2 ]] && ! (( BEEP_QUIET )); then
  run_step "Building Python venv" -- \
    bash -c 'runuser -l "$1" -- "$2" >>"$3" 2>&1' \
    _ "${AGENT_USER}" "${BEEP_DIR}/bin/beep-setup-venv" "${LOG_FILE}"
else
  runuser -l "${AGENT_USER}" -- "${BEEP_DIR}/bin/beep-setup-venv"
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

install_latest_node_bridge() {
  local name="$1" package="$2" metadata_url="$3"
  local tmp_dir version tarball_url integrity tarball
  tmp_dir="$(mktemp -d)"
  curl_get "${metadata_url}" -o "${tmp_dir}/latest.json" \
    || { rm -rf "${tmp_dir}"; return 1; }
  node -e '
    const m = require(process.argv[1]);
    if (!m.version || !m.dist || !m.dist.tarball ||
        typeof m.dist.integrity !== "string") {
      console.error("metadata is missing version, tarball, or integrity");
      process.exit(1);
    }
    let tarball;
    try {
      tarball = new URL(m.dist.tarball);
    } catch {
      console.error("metadata contains an invalid tarball URL");
      process.exit(1);
    }
    if (tarball.protocol !== "https:" ||
        tarball.hostname !== "registry.npmjs.org") {
      console.error("metadata tarball URL is outside the npm registry");
      process.exit(1);
    }
    const i = m.dist.integrity.indexOf("-");
    if (i <= 0 || i === m.dist.integrity.length - 1 ||
        m.dist.integrity.slice(0, i) !== "sha512") {
      console.error("metadata must contain a sha512 integrity value");
      process.exit(1);
    }
    process.stdout.write(
      [m.version, m.dist.tarball, m.dist.integrity].join("\n") + "\n"
    );
  ' "${tmp_dir}/latest.json" > "${tmp_dir}/meta.txt" \
    || { rm -rf "${tmp_dir}"; die "npm metadata for latest ${package} was invalid." 1; }
  version="$(sed -n 1p "${tmp_dir}/meta.txt")"
  tarball_url="$(sed -n 2p "${tmp_dir}/meta.txt")"
  integrity="$(sed -n 3p "${tmp_dir}/meta.txt")"
  [[ -n "${version}" && -n "${tarball_url}" && -n "${integrity}" ]] \
    || { rm -rf "${tmp_dir}"; die "npm metadata for latest ${package} was incomplete." 1; }

  tarball="${tmp_dir}/${name}.tgz"
  curl_get "${tarball_url}" -o "${tarball}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    const sri = process.argv[1], file = process.argv[2];
    const i = sri.indexOf("-");
    if (i <= 0 || i === sri.length - 1 || sri.slice(0, i) !== "sha512") {
      console.error("malformed or unsupported integrity value");
      process.exit(1);
    }
    const got = crypto.createHash(sri.slice(0, i))
      .update(fs.readFileSync(file)).digest("base64");
    if (got !== sri.slice(i + 1)) {
      console.error("tarball integrity does not match registry metadata");
      process.exit(1);
    }
  ' "${integrity}" "${tarball}" \
    || { rm -rf "${tmp_dir}"; die "Integrity check failed for ${package}@${version}." 1; }

  log "Installing latest ${package} (${version}) from its integrity-verified tarball."
  npm install -g --ignore-scripts "${tarball}" \
    || { rm -rf "${tmp_dir}"; return 1; }
  rm -rf "${tmp_dir}"
  npm ls -g --depth=0 "${package}@${version}" >/dev/null \
    || die "${package}@${version} was not installed successfully." 1
  # name is the stable internal bridge label, not necessarily the npm package
  # basename (pi-mono maps to @earendil-works/pi-coding-agent).
  case "${name}" in
    pi-ai) PI_AI_VERSION="${version}" ;;
    pi-mono) PI_MONO_VERSION="${version}" ;;
    *) die "Unknown Earendil module label: ${name}." 1 ;;
  esac
}

# Resolve both Earendil modules at install time so every install and repair
# converges on the newest npm release. Registry-provided SRI is verified before
# npm sees either tarball.
retry 4 5 -- install_latest_node_bridge \
  pi-ai @earendil-works/pi-ai \
  "https://registry.npmjs.org/@earendil-works%2Fpi-ai/latest"

# pi-mono is the agent loop the chat service drives via
# payload/agent/pi-mono-bridge.mjs.
retry 4 5 -- install_latest_node_bridge \
  pi-mono @earendil-works/pi-coding-agent \
  "https://registry.npmjs.org/@earendil-works%2Fpi-coding-agent/latest"
}

# ---------------------------------------------------------------------------
# Optional component: Forgejo server (BEEP_INSTALL_FORGEJO=1)
# ---------------------------------------------------------------------------
# A self-hosted git forge backed by PostgreSQL. Forgejo listens on loopback;
# Avahi and Caddy provide LAN discovery and internal-CA HTTPS. Admin/database
# credentials are generated at install time and stored only in root-owned
# files on this host. Every step checks current state so re-runs converge.

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

# Candidate API origins for Forgejo release metadata. Forgejo's runner
# metadata moved off Codeberg; keep the legacy origin last for compatibility
# with older pinned releases that may still only be available there.
forgejo_release_api_origins() {
  case "$1" in
    forgejo/forgejo|forgejo/runner)
      printf '%s\n' \
        "https://data.forgejo.org" \
        "https://code.forgejo.org" \
        "https://codeberg.org"
      ;;
    *)
      printf '%s\n' "https://codeberg.org"
      ;;
  esac
}

# Candidate release download origins. Prefer Forgejo's canonical host, but keep
# Codeberg as a fallback for pinned versions still hosted there.
forgejo_release_download_bases() {
  case "$1" in
    forgejo/forgejo|forgejo/runner)
      printf '%s\n' \
        "https://code.forgejo.org" \
        "https://codeberg.org"
      ;;
    *)
      printf '%s\n' "https://codeberg.org"
      ;;
  esac
}

forgejo_release_tag_from_json() {
  python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

tag = data.get("tag_name") or data.get("name") or ""
if not tag:
    sys.exit(1)
print(tag)
'
}

# Resolve the latest release tag (e.g. "11.0.3") of a Forgejo repository.
forgejo_latest_release() {
  local repo="$1" origin json tag
  # Two short endpoint-local retries cover brief network flakes without
  # spending curl_get's full outer retry budget on an obsolete release host.
  local metadata_retry_count=2 metadata_retry_delay=2 metadata_max_time=15
  for origin in $(forgejo_release_api_origins "${repo}"); do
    # Use a bounded direct curl instead of curl_get here so a stale origin
    # fails over quickly. This trades curl_get's five outer attempts/logging for
    # one endpoint-local retry window before moving to the next origin. Forgejo
    # metadata origins have exposed the release version as either tag_name or
    # name, so accept both.
    json="$(curl -fsSL --retry "${metadata_retry_count}" \
              --retry-delay "${metadata_retry_delay}" \
              --max-time "${metadata_max_time}" \
              "${origin}/api/v1/repos/${repo}/releases/latest")" \
      || { warn "Release metadata unavailable from ${origin}; trying the next release origin."; continue; }
    tag="$(forgejo_release_tag_from_json <<<"${json}")" \
      || { warn "Release metadata malformed from ${origin}; trying the next release origin."; continue; }
    tag="${tag#v}"
    if [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
      printf '%s' "${tag}"
      return 0
    fi
    warn "Release metadata from ${origin} did not contain a valid semver tag; trying the next release origin."
  done
  return 1
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

# Download a Forgejo release asset from the canonical host with a legacy
# Codeberg fallback, verifying the adjacent .sha256 file from the same origin.
forgejo_fetch_release_asset() {
  local repo="$1" version="$2" asset="$3" dest="$4" base url
  for base in $(forgejo_release_download_bases "${repo}"); do
    url="${base}/${repo}/releases/download/v${version}/${asset}"
    if codeberg_fetch_verified "${url}" "${dest}"; then
      return 0
    fi
    warn "Release asset unavailable from ${base}; trying the next release origin."
  done
  return 1
}

ensure_forgejo_runner_docker_package() {
  local docker_cli="$1" containerd_status

  if [[ -x "${docker_cli}" ]]; then
    info "Docker CLI already installed; reusing the existing Docker Engine."
    note_satisfied
    return 0
  fi

  containerd_status="$(dpkg-query -W -f='${Status}' containerd.io 2>/dev/null || true)"
  if [[ "${containerd_status}" == "install ok installed" ]]; then
    die "Cannot install docker.io because containerd.io is installed. Existing packages were left unchanged; install a Docker Engine compatible with containerd.io or remove containerd.io, then re-run." 1
  fi

  apt_install docker.io
}

configure_caddy_apt_repository() {
  local keyring=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  local source=/etc/apt/sources.list.d/caddy-stable.list
  local tmp_dir

  install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d
  tmp_dir="$(mktemp -d)" \
    || die "Could not create temporary storage for Caddy's signing key." 1
  if ! curl_get https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      > "${tmp_dir}/key"; then
    rm -rf "${tmp_dir}"
    die "Could not download Caddy's stable repository signing key." 1
  fi
  if ! gpg --dearmor --yes < "${tmp_dir}/key" > "${tmp_dir}/keyring"; then
    rm -rf "${tmp_dir}"
    die "Could not install Caddy's stable repository signing key." 1
  fi
  install -m 0644 -o root -g root "${tmp_dir}/keyring" "${keyring}"
  rm -rf "${tmp_dir}"
  cat > "${source}" <<EOF
deb [signed-by=${keyring}] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
  chmod 0644 "${source}"
  apt_get update
}

install_forgejo_runner() {
  local runner_arch installed_runner runner_tmp runner_token runner_drop_ins

  # option-sections: forgejo-runner begin
  section "Install Forgejo runner"

  [[ -x /usr/local/bin/forgejo && -s /etc/forgejo/app.ini ]] \
    || die "Forgejo runner requires the local Forgejo server component. Run: sudo ./${SCRIPT_NAME} install forgejo-runner" 1
  systemctl is-active --quiet forgejo.service \
    || die "Forgejo must be active before its runner can be installed." 1
  runner_arch="$(forgejo_release_arch)" \
    || die "Forgejo runner releases support only amd64/arm64 hosts." 65

  warn "Co-locating the Actions runner with the forge is contrary to upstream guidance; enabled deliberately."
  ensure_forgejo_runner_docker_package /usr/bin/docker
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
  forgejo_runner_in_docker_group \
    || die "Could not add forgejo-runner to the docker group." 1
  forgejo_runner_has_docker_access \
    || die "forgejo-runner cannot access the Docker daemon after group setup." 1
  if [[ -n "${FORGEJO_RUNNER_VERSION}" ]]; then
    FORGEJO_RUNNER_RESOLVED_VERSION="${FORGEJO_RUNNER_VERSION}"
    info "Forgejo runner release pinned to ${FORGEJO_RUNNER_RESOLVED_VERSION}."
  else
    FORGEJO_RUNNER_RESOLVED_VERSION="$(forgejo_latest_release forgejo/runner)" \
      || die "Could not resolve the latest forgejo-runner release from Forgejo release metadata (pin FORGEJO_RUNNER_VERSION to proceed)." 66
    info "Latest forgejo-runner release: ${FORGEJO_RUNNER_RESOLVED_VERSION}."
  fi
  installed_runner=""
  if [[ -x /usr/local/bin/forgejo-runner ]]; then
    installed_runner="$(/usr/local/bin/forgejo-runner --version 2>/dev/null \
      | awk '{print $3}' | sed 's/^v//' || true)"
  fi
  if [[ "${installed_runner}" == "${FORGEJO_RUNNER_RESOLVED_VERSION}" ]]; then
    info "forgejo-runner ${FORGEJO_RUNNER_RESOLVED_VERSION} already installed."
    note_satisfied
  else
    runner_tmp="$(mktemp)"
    forgejo_fetch_release_asset forgejo/runner \
      "${FORGEJO_RUNNER_RESOLVED_VERSION}" \
      "forgejo-runner-${FORGEJO_RUNNER_RESOLVED_VERSION}-linux-${runner_arch}" \
      "${runner_tmp}" \
      || {
        rm -f "${runner_tmp}"
        die "Failed to download forgejo-runner ${FORGEJO_RUNNER_RESOLVED_VERSION}." 66
      }
    install -m 0755 -o root -g root "${runner_tmp}" \
      /usr/local/bin/forgejo-runner
    rm -f "${runner_tmp}"
    ok "Installed forgejo-runner ${FORGEJO_RUNNER_RESOLVED_VERSION} (checksum verified)."
    note_changed
  fi

  section "Register Forgejo runner"

  if forgejo_runner_config_is_managed \
      && [[ "$(stat -c '%U:%G %a' /var/lib/forgejo-runner/config.yaml \
        2>/dev/null || true)" == "root:forgejo-runner 640" ]]; then
    info "Managed same-host runner configuration already up to date."
    note_satisfied
  else
    install -m 640 -o root -g forgejo-runner \
      "${PAYLOAD_DIR}/etc/forgejo-runner-config.yaml" \
      /var/lib/forgejo-runner/config.yaml
    ok "Installed conservative same-host runner configuration."
    note_changed
  fi

  if [[ -s /var/lib/forgejo-runner/.runner ]]; then
    info "Runner already registered; skipping registration."
    note_satisfied
  else
    if [[ -f /etc/systemd/system/forgejo-runner.service ]]; then
      systemctl stop forgejo-runner.service \
        || die "Could not stop the existing Forgejo runner before re-registering it." 1
    fi
    rm -f /var/lib/forgejo-runner/.runner
    runner_token="$(runuser -u git -- /usr/local/bin/forgejo \
      --config /etc/forgejo/app.ini --work-path /var/lib/forgejo \
      actions generate-runner-token)"
    if ! runuser -u forgejo-runner -- /usr/local/bin/forgejo-runner \
        -c /var/lib/forgejo-runner/config.yaml register \
        --no-interactive \
        --instance "http://127.0.0.1:${FORGEJO_HTTP_PORT}/" \
        --token "${runner_token}" \
        --name "$(hostname)" \
        --labels "${FORGEJO_RUNNER_LABELS}"; then
      unset runner_token
      die "Forgejo runner registration failed." 1
    fi
    unset runner_token
    [[ -s /var/lib/forgejo-runner/.runner ]] \
      || die "Forgejo runner registration produced an empty state file." 1
    ok "Runner registered against 127.0.0.1:${FORGEJO_HTTP_PORT} with labels: ${FORGEJO_RUNNER_LABELS}"
    note_changed
  fi
  chown forgejo-runner:forgejo-runner /var/lib/forgejo-runner/.runner
  chmod 600 /var/lib/forgejo-runner/.runner
  install -m 644 "${PAYLOAD_DIR}/systemd/forgejo-runner.service" \
    /etc/systemd/system/forgejo-runner.service
  remove_obsolete_forgejo_runner_drop_in
  systemctl daemon-reload
  runner_drop_ins="$(forgejo_runner_drop_in_paths)"
  [[ -z "${runner_drop_ins}" ]] \
    || die "Refusing to start the Forgejo runner with unmanaged systemd drop-ins: ${runner_drop_ins//$'\n'/ }. Reconcile or remove them, then re-run install." 1
  forgejo_runner_uses_managed_config \
    || die "The effective forgejo-runner unit does not load the managed config; inspect systemd drop-ins." 1
  systemctl enable forgejo-runner.service >/dev/null \
    || die "Could not enable forgejo-runner.service." 1
  systemctl restart forgejo-runner.service \
    || die "forgejo-runner service did not start; see journalctl -u forgejo-runner." 1
  if ! retry 6 2 -- forgejo_runner_declared_successfully; then
    systemctl disable --now forgejo-runner.service >/dev/null 2>&1 \
      || warn "Could not disable the runner after its declaration failed."
    die "Forgejo runner did not declare successfully; it was stopped. See journalctl -u forgejo-runner." 1
  fi
  ok "Forgejo Actions runner declared successfully and is enabled."
  # option-sections: forgejo-runner end
}

# component-hook: forgejo begin
install_forgejo() {
  # option-sections: forgejo begin
  section "Install Forgejo prerequisites"

  apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg
  configure_caddy_apt_repository
  apt_install git git-lfs postgresql postgresql-contrib openssl xz-utils \
    caddy avahi-daemon libnss-mdns

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
    FORGEJO_RESOLVED_VERSION="$(forgejo_latest_release forgejo/forgejo)" \
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
    _forgejo_tmp="$(mktemp)"
    forgejo_fetch_release_asset forgejo/forgejo "${FORGEJO_RESOLVED_VERSION}" \
      "forgejo-${FORGEJO_RESOLVED_VERSION}-linux-${FORGEJO_ARCH}" "${_forgejo_tmp}" \
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
  _fj_role_exists=0
  _fj_database_exists=0
  if runuser -u postgres -- psql -tAc \
       "SELECT 1 FROM pg_roles WHERE rolname = '${FORGEJO_DB_USER}'" | grep -q 1; then
    _fj_role_exists=1
  fi
  if runuser -u postgres -- psql -tAc \
       "SELECT 1 FROM pg_database WHERE datname = '${FORGEJO_DB_NAME}'" | grep -q 1; then
    _fj_database_exists=1
  fi
  if (( _fj_role_exists || _fj_database_exists )) \
      && ! forgejo_config_has_recovery_material; then
    die "Refusing to reuse the existing Forgejo database or role without a complete /etc/forgejo/app.ini. Recover the original config from backup; secret rotation requires a separate, backed-up recovery procedure." 1
  fi
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
  if (( _fj_role_exists || _fj_database_exists )); then
    warn "Existing PostgreSQL state was detected for Forgejo (database ${FORGEJO_DB_NAME}, role ${FORGEJO_DB_USER}). It will be reused, never dropped."
    require_capitalized_yes FORGEJO_CONFIRM_DATABASE_REUSE \
      "Allow Beep to reuse the existing Forgejo PostgreSQL database and role?"
  fi
  if (( _fj_role_exists )); then
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
  if (( _fj_database_exists )); then
    info "PostgreSQL database ${FORGEJO_DB_NAME} already exists."
    note_satisfied
  else
    runuser -u postgres -- createdb -O "${FORGEJO_DB_USER}" "${FORGEJO_DB_NAME}"
    ok "Created PostgreSQL database ${FORGEJO_DB_NAME} (owner ${FORGEJO_DB_USER})."
    note_changed
  fi
  unset _fj_role_exists _fj_database_exists

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
  _fj_domain="$(forgejo_url_host)"
  FORGEJO_URL_HOST="${_fj_domain}"
  _fj_tmp="$(mktemp)"
  cat > "${_fj_tmp}" <<EOF
; Managed by ${SCRIPT_NAME} (Beep optional component).
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
; Caddy is the LAN-facing HTTPS endpoint; Forgejo itself is loopback-only.
HTTP_ADDR = 127.0.0.1
HTTP_PORT = ${FORGEJO_HTTP_PORT}
DOMAIN = ${_fj_domain}
ROOT_URL = https://${_fj_domain}/
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
  ok "Forgejo backend is healthy on 127.0.0.1:${FORGEJO_HTTP_PORT}."

  section "Configure Forgejo LAN HTTPS and mDNS"

  configure_forgejo_lan_https
  ok "Forgejo is available at https://${_fj_domain}/ after trusting the local CA."
  # option-sections: forgejo end

  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}"; then
    install_forgejo_runner
  fi
}
# component-hook: forgejo end

# ---------------------------------------------------------------------------
# Deploy payload: chat service, helpers, policy, systemd, logrotate.
# ---------------------------------------------------------------------------

install_beep_runtime() {
section "Deploy the agent runtime"

if [[ ! -d "${PAYLOAD_DIR}" ]]; then
  die "Payload directory ${PAYLOAD_DIR} not found. Re-clone the repository." 1
fi

# Chat service source.
install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${BEEP_DIR}/agent" "${BEEP_DIR}/agent/templates"
for f in server.py providers.py policy.py audit.py runner.py history.py tools.py pi_mono.py skill_loader.py auth.py lifecycle.py examples.md; do
  install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${PAYLOAD_DIR}/agent/${f}" "${BEEP_DIR}/agent/${f}"
done
# The pi-ai bridge and its version pin travel with the Python sources
# so providers.py can find them at the default path. Bridge is
# read-only; only root mutates the agent tree.
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-ai-bridge.mjs" "${BEEP_DIR}/agent/pi-ai-bridge.mjs"
printf '%s\n' "${PI_AI_VERSION}" > "${BEEP_DIR}/agent/pi-ai.version"
chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/agent/pi-ai.version"
chmod 644 "${BEEP_DIR}/agent/pi-ai.version"
# Deploy the payload VERSION alongside the agent tree so the chat
# service can report it via /api/version (the /version chat command).
if [[ -f "${REPO_ROOT}/VERSION" ]]; then
  install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${REPO_ROOT}/VERSION" "${BEEP_DIR}/VERSION"
fi
# pi-mono bridge + version pin live alongside the pi-ai ones for the
# same reasons.
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/pi-mono-bridge.mjs" "${BEEP_DIR}/agent/pi-mono-bridge.mjs"
printf '%s\n' "${PI_MONO_VERSION}" > "${BEEP_DIR}/agent/pi-mono.version"
chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/agent/pi-mono.version"
chmod 644 "${BEEP_DIR}/agent/pi-mono.version"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/index.html" "${BEEP_DIR}/agent/templates/index.html"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/settings.json.tmpl" "${BEEP_DIR}/agent/templates/settings.json.tmpl"
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" "${BEEP_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl"

# Initialise the Time-to-Live kill switch now that lifecycle.py is deployed,
# preserving valid state from an existing installation.
init_lifecycle_state

# Render pi-mono runtime configs into /opt/beep/pi/. Root-owned,
# world-readable; the chat service reads them but does not need to
# mutate them.
install -d -m 755 -o root -g root "${BEEP_DIR}/pi"
install -d -m 750 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${BEEP_DIR}/state/logs" "${BEEP_DIR}/state/pi-mono-sessions"
install -m 644 "${PAYLOAD_DIR}/agent/templates/settings.json.tmpl" \
  "${BEEP_DIR}/pi/settings.json"
# Render APPEND_SYSTEM.md via the chat-service helper so a single
# implementation is the source of truth for the rendered text.
if (cd "${PAYLOAD_DIR}/agent" && python3 server.py --render-append-system) \
       > "${BEEP_DIR}/pi/APPEND_SYSTEM.md.tmp" 2>/dev/null; then
  install -m 644 "${BEEP_DIR}/pi/APPEND_SYSTEM.md.tmp" \
    "${BEEP_DIR}/pi/APPEND_SYSTEM.md"
  rm -f "${BEEP_DIR}/pi/APPEND_SYSTEM.md.tmp"
else
  # Fallback: substitute placeholders from the template directly.
  rm -f "${BEEP_DIR}/pi/APPEND_SYSTEM.md.tmp"
  sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
      -e "s|__FACTS__|hostname=$(hostname) os=$(. /etc/os-release && echo "${PRETTY_NAME}")|g" \
      "${PAYLOAD_DIR}/agent/templates/APPEND_SYSTEM.md.tmpl" \
    | install -m 644 /dev/stdin "${BEEP_DIR}/pi/APPEND_SYSTEM.md"
fi

# Snapshot the conversations DB *before* the chat-service binary runs
# the schema migration. The migration is additive (forward-only,
# behind PRAGMA user_version) but a snapshot lets operators roll back
# without losing history. The bak file name embeds the timestamp.
if [[ -f "${BEEP_DIR}/state/conversations.db" ]]; then
  _ts="$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "${BEEP_DIR}/state/conversations.db" \
        "${BEEP_DIR}/state/conversations.db.bak.${_ts}" \
    || warn "Could not snapshot conversations.db (continuing)."
fi

section "Install policy and operator tools"

# Operator helpers.
for f in beep-audit beep-health beep-diagnostics beep-secrets-edit beep-chat beep-setup-venv beep-verify-release; do
  install -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${PAYLOAD_DIR}/bin/${f}" "${BEEP_DIR}/bin/${f}"
done
# Also make beep-secrets-edit and beep-audit reachable on PATH.
ln -sf "${BEEP_DIR}/bin/beep-chat"          /usr/local/bin/beep-chat
ln -sf "${BEEP_DIR}/bin/beep-audit"         /usr/local/bin/beep-audit
ln -sf "${BEEP_DIR}/bin/beep-secrets-edit"         /usr/local/bin/beep-secrets-edit
ln -sf "${BEEP_DIR}/bin/beep-health"         /usr/local/bin/beep-health
ln -sf "${BEEP_DIR}/bin/beep-diagnostics"  /usr/local/bin/beep-diagnostics

# Policy.
if [[ ! -f "${BEEP_ETC}/policy.yaml" ]]; then
  install -m 644 "${PAYLOAD_DIR}/etc/policy.yaml" "${BEEP_ETC}/policy.yaml"
  ok "Installed default policy at ${BEEP_ETC}/policy.yaml."
else
  info "Preserving existing ${BEEP_ETC}/policy.yaml."
fi

# Ship the built-in skill catalogue to /opt/beep/skills/
# (root-owned, world-readable) and provision the operator-extensible
# /etc/beep/skills.d/ tree with the same mode/owner contract
# as policy.yaml. Skills are static markdown read at chat-turn time;
# the loader never mutates them.
install -d -m 755 -o root -g root "${BEEP_DIR}/skills"
if [[ -d "${PAYLOAD_DIR}/agent/skills" ]]; then
  shopt -s nullglob
  for f in "${PAYLOAD_DIR}/agent/skills/"*.md; do
    install -m 644 -o root -g root "${f}" "${BEEP_DIR}/skills/$(basename "${f}")"
  done
  shopt -u nullglob
  ok "Installed built-in skills to ${BEEP_DIR}/skills/."
fi
install -d -m 755 -o root -g root "${BEEP_ETC}/skills.d"

# logrotate. The shipped file uses the ``__AGENT_USER__`` placeholder
# so the `create` line names the operator-chosen account (FIX-3-06).
sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
    "${PAYLOAD_DIR}/logrotate/beep" \
    | install -m 644 /dev/stdin /etc/logrotate.d/beep

# Audit log seed file (so chat service can open it without race).
if [[ ! -f "${BEEP_LOG_DIR}/audit.log" ]]; then
  install -m 640 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${BEEP_LOG_DIR}/audit.log"
fi

section "Enable background services"

# systemd units. The shipped unit files use the literal placeholders
# `__AGENT_USER__` and `__AGENT_HOME__` so the chosen account name is
# substituted in at install time. This keeps the units valid for the
# default `beep` account and any operator-chosen override.
render_unit() {
  local src="$1" dest="$2"
  # NOTE (FIX-1-17): The `s|…|${AGENT_USER}|g` substitution is only safe
  # because `is_supported_agent_username` (see validate_config) forbids the
  # sed-special characters `|`, `&`, and `\` in the username. If that
  # validator is ever relaxed, escape AGENT_USER/AGENT_HOME for sed here.
  sed -e "s|__AGENT_USER__|${AGENT_USER}|g" \
      -e "s|__AGENT_HOME__|${AGENT_HOME}|g" \
      -e "s|__BEEP_DIR__|${BEEP_DIR}|g" \
      "${src}" | install -m 644 /dev/stdin "${dest}"
}
render_unit "${PAYLOAD_DIR}/systemd/beep-chat.service"   /etc/systemd/system/beep-chat.service
render_unit "${PAYLOAD_DIR}/systemd/beep-health.service" /etc/systemd/system/beep-health.service
install -m 644 "${PAYLOAD_DIR}/systemd/beep-health.timer"   /etc/systemd/system/beep-health.timer
systemctl daemon-reload
systemctl enable beep-chat.service >/dev/null 2>&1 \
  || warn "Could not enable the chat service; see journalctl -u beep-chat"
# Use restart, not just start: on an in-place upgrade the agent tree
# (server.py, templates/index.html, VERSION) has just been overwritten,
# but `enable --now` would leave an already-running unit untouched, so
# the old process would keep serving the new template — rendering a
# literal "v{{VERSION}}" footer and a UI that no longer matches its API.
# Restart is idempotent: it starts the unit if it is stopped.
systemctl restart beep-chat.service \
  || warn "Chat service did not start; see journalctl -u beep-chat"
systemctl enable --now beep-health.timer || true
ok "Chat service installed and enabled."

# ---------------------------------------------------------------------------
# Verification script
# ---------------------------------------------------------------------------

section "Install health checks"

cat > "${BEEP_DIR}/bin/verify" <<EOF
#!/usr/bin/env bash
set -uo pipefail

BEEP_DIR="${BEEP_DIR}"
AGENT_USER="${AGENT_USER}"
AGENT_HOME="${AGENT_HOME}"
PI_AI_VERSION="${PI_AI_VERSION}"
PI_MONO_VERSION="${PI_MONO_VERSION}"

JSON="\${BEEP_JSON:-0}"

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

[[ "\${JSON}" == "1" ]] || printf '\\n%s== beep verify ==%s\\n' "\${C_BOLD}" "\${C_RESET}"
[[ "\${JSON}" == "1" ]] || echo

hd "User and sudo:"
check "running as \${AGENT_USER}"          test "\$(id -un)" = "\${AGENT_USER}"
check "passwordless sudo"                  sudo -n true
[[ "\${JSON}" == "1" ]] || echo

hd "Network and services:"
check "loopback chat port configured"         test -n "${BEEP_CHAT_PORT:-${CHAT_PORT}}"
[[ "\${JSON}" == "1" ]] || echo

hd "Runtime:"
check "Python venv exists"                 test -x \${AGENT_HOME}/agent-env/bin/python
check "node and tsc present"               bash -c "command -v node && command -v tsc"
check "pi-ai bridge deployed"              test -r \${BEEP_DIR}/agent/pi-ai-bridge.mjs
check "pi-ai installed (any version)"      bash -c "npm ls -g --depth=0 @earendil-works/pi-ai >/dev/null"
check "pi-ai pinned to \${PI_AI_VERSION}"     bash -c "npm ls -g --depth=0 @earendil-works/pi-ai 2>/dev/null | grep -q '@earendil-works/pi-ai@\${PI_AI_VERSION}'"
check "pi-mono bridge deployed"            test -r \${BEEP_DIR}/agent/pi-mono-bridge.mjs
check "pi-mono installed (any version)"    bash -c "npm ls -g --depth=0 @earendil-works/pi-coding-agent >/dev/null"
check "pi-mono pinned to \${PI_MONO_VERSION}" bash -c "npm ls -g --depth=0 @earendil-works/pi-coding-agent 2>/dev/null | grep -q '@earendil-works/pi-coding-agent@\${PI_MONO_VERSION}'"
check "pi-mono settings rendered"          test -r \${BEEP_DIR}/pi/settings.json
check "pi-mono APPEND_SYSTEM rendered"     test -r \${BEEP_DIR}/pi/APPEND_SYSTEM.md
check "pi-mono log dir present"            test -d \${BEEP_DIR}/state/logs
check "built-in skills directory present"  test -d \${BEEP_DIR}/skills
for skill in ai-agents apt backup certificates containers css database \
             desktop dev disk files forgejo git hardware hermes-agent html \
             journal json kernel llm locale network obsidian openclaw-agent \
             packages performance pi-mono-agent process reactivation \
             scheduling secrets security services snap sql systemd \
             troubleshoot ubuntu users virtualization web beep zram; do
  check "skill \${skill}.md deployed"        test -r \${BEEP_DIR}/skills/\${skill}.md
done
check "operator skills.d/ present"         test -d /etc/beep/skills.d
check "agent tools.py compiles"            \${AGENT_HOME}/agent-env/bin/python -m py_compile \${BEEP_DIR}/agent/tools.py
check "agent pi_mono.py compiles"          \${AGENT_HOME}/agent-env/bin/python -m py_compile \${BEEP_DIR}/agent/pi_mono.py
check "agent skill_loader.py compiles"     \${AGENT_HOME}/agent-env/bin/python -m py_compile \${BEEP_DIR}/agent/skill_loader.py
[[ "\${JSON}" == "1" ]] || echo

hd "Chat service and policy:"
check "policy.yaml present"                test -r /etc/beep/policy.yaml
check "audit log writable for ${AGENT_USER}"  bash -c "test -w /var/log/beep/audit.log || sudo -n test -w /var/log/beep/audit.log"
check "beep-chat.service active"  systemctl is-active beep-chat.service
check "chat listening on 127.0.0.1:${CHAT_PORT}" bash -c "ss -ltn 'sport = :${CHAT_PORT}' | grep -q 127.0.0.1"
check "agent server.py compiles"           \${AGENT_HOME}/agent-env/bin/python -m py_compile \${BEEP_DIR}/agent/server.py
[[ "\${JSON}" == "1" ]] || echo

# Optional component: Forgejo. Detected from the installed config so the
# checks run (or stay silent) regardless of the caller's environment.
if sudo -n test -f /etc/forgejo/app.ini 2>/dev/null; then
  FORGEJO_PORT="\$(sudo -n awk -F' = ' '\$0=="[server]"{s=1;next} /^\\[/{s=0} s && \$1=="HTTP_PORT"{print \$2; exit}' /etc/forgejo/app.ini 2>/dev/null)"
  FORGEJO_PORT="\${FORGEJO_PORT:-3000}"
  FORGEJO_HOST="\$(sudo -n awk -F' = ' '\$0=="[server]"{s=1;next} /^\\[/{s=0} s && \$1=="DOMAIN"{print \$2; exit}' /etc/forgejo/app.ini 2>/dev/null)"
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
  check "caddy binary present"                bash -c "command -v caddy"
  check "caddy.service unit present"          systemctl cat caddy.service
  check "caddy.service enabled"               systemctl is-enabled caddy.service
  check "caddy.service active"               systemctl is-active caddy.service
  check "Caddy configuration valid"           sudo -n caddy validate \
    --config /etc/caddy/Caddyfile --adapter caddyfile
  check "managed Caddy route markers unique"  bash -c \
    "test \"\$(sudo -n grep -Fxc '# BEGIN install.sh Forgejo' /etc/caddy/Caddyfile)\" = 1 \
      && test \"\$(sudo -n grep -Fxc '# END install.sh Forgejo' /etc/caddy/Caddyfile)\" = 1"
  if [[ -n "\${FORGEJO_HOST}" ]]; then
    check "Caddy route host matches \${FORGEJO_HOST}" sudo -n grep -Fqx \
      "https://\${FORGEJO_HOST} {" /etc/caddy/Caddyfile
    check "Caddy route uses internal TLS" sudo -n grep -Eq \
      '^[[:space:]]*tls internal[[:space:]]*$' /etc/caddy/Caddyfile
    check "Caddy route targets 127.0.0.1:\${FORGEJO_PORT}" sudo -n grep -Eq \
      "^[[:space:]]*reverse_proxy 127\\\\.0\\\\.0\\\\.1:\${FORGEJO_PORT}[[:space:]]*$" \
      /etc/caddy/Caddyfile
  fi
  check "legacy Forgejo Caddy fragment absent" sudo -n test ! -e \
    /etc/caddy/conf.d/forgejo.caddy
  check "avahi-daemon.service active"        systemctl is-active avahi-daemon.service
  check "Caddy local CA exported"            sudo -n test -r /etc/forgejo/caddy-local-ca.crt
  check "exported Caddy local CA is current"  sudo -n cmp -s \
    /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt \
    /etc/forgejo/caddy-local-ca.crt
  if [[ -n "\${FORGEJO_HOST}" ]]; then
    check "forgejo HTTPS healthy at \${FORGEJO_HOST}" sudo -n curl -fsS -m 5 -o /dev/null \
      --cacert /etc/forgejo/caddy-local-ca.crt \
      --resolve "\${FORGEJO_HOST}:443:127.0.0.1" \
      "https://\${FORGEJO_HOST}/api/healthz"
  fi
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
  echo "  - If the chat service is not active: sudo systemctl status beep-chat"
  exit 1
fi
EOF

chmod +x "${BEEP_DIR}/bin/verify"
chown "${AGENT_USER}:${AGENT_USER}" "${BEEP_DIR}/bin/verify"
ln -sf "${BEEP_DIR}/bin/verify" /usr/local/bin/beep-verify

# ---------------------------------------------------------------------------
# First-run status summary
# ---------------------------------------------------------------------------

section "Verify the installation"

PROVIDER_OK=0
if provider_credential_configured "${BEEP_DIR}/secrets/env"; then
  PROVIDER_OK=1
fi

CHAT_OK=0
if systemctl is-active --quiet beep-chat.service; then
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

bullet "${PROVIDER_OK}"  "Provider credential present in secrets/env"
bullet "${CHAT_OK}"      "Chat service running on 127.0.0.1:${CHAT_PORT}"
}

install_beep() {
  install_beep_base
  install_beep_runtime
}

assert_llama_installation_safe() {
  if ! llama_installation_is_managed; then
    local path
    for path in /opt/llama.cpp /etc/llama.cpp /var/lib/llama.cpp \
        /var/log/llama.cpp /usr/local/bin/beep-llama-manager \
        /etc/systemd/system/llama-server.service; do
      [[ ! -e "${path}" ]] \
        || die "Refusing to adopt unmanaged llama path: ${path}" 1
    done
    id llama-cpp >/dev/null 2>&1 \
      && die "Refusing to adopt unmanaged system account: llama-cpp" 1
  fi
  if command -v ss >/dev/null 2>&1 \
      && ss -H -ltn "sport = :${LLAMA_PORT}" 2>/dev/null | grep -q . \
      && ! systemctl is-active --quiet llama-server.service 2>/dev/null; then
    die "Port ${LLAMA_PORT} is already in use by an unmanaged service." 1
  fi
}

install_llama() {
  local build_catalog="${PAYLOAD_DIR}/etc/llama-builds.json"
  local model_catalog="${PAYLOAD_DIR}/etc/llama-models.json"
  local arch runtime_url runtime_sha archive_root model_url model_sha
  local model_filename model_size runtime_dir runtime_archive runtime_stage
  local model_path
  local -a llama_build_data=() llama_model_data=()

  # option-sections: llama begin
  section "Validate standalone llama ownership and catalogue"
  assert_llama_installation_safe
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  mapfile -t llama_build_data < <(python3 - "${build_catalog}" "${arch}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
asset = data["assets"][sys.argv[2]]
print(data["release"])
print(asset["url"])
print(asset["sha256"])
print(asset["archive_root"])
PY
  ) || die "Could not read the llama build catalogue for ${arch}." 1
  (( ${#llama_build_data[@]} == 4 )) \
    || die "No approved llama.cpp runtime for architecture ${arch}." 65
  LLAMA_RUNTIME_RELEASE="${llama_build_data[0]}"
  runtime_url="${llama_build_data[1]}"
  runtime_sha="${llama_build_data[2]}"
  archive_root="${llama_build_data[3]}"
  mapfile -t llama_model_data < <(python3 - "${model_catalog}" "${LLAMA_MODEL_ID}" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
model = next(item for item in data["models"] if item["id"] == sys.argv[2])
print(model["url"])
print(model["sha256"])
print(model["filename"])
print(model["size_bytes"])
PY
  ) || die "Could not read approved llama model ${LLAMA_MODEL_ID}." 1
  (( ${#llama_model_data[@]} == 4 )) \
    || die "Approved llama model metadata is incomplete." 1
  model_url="${llama_model_data[0]}"
  model_sha="${llama_model_data[1]}"
  model_filename="${llama_model_data[2]}"
  model_size="${llama_model_data[3]}"
  runtime_dir="/opt/llama.cpp/versions/${LLAMA_RUNTIME_RELEASE}-${arch}"
  runtime_archive="/var/cache/llama.cpp/${LLAMA_RUNTIME_RELEASE}-${arch}.tar.gz"
  model_path="/var/lib/llama.cpp/models/${model_filename}"

  section "Create standalone llama account and directories"
  if ! id llama-cpp >/dev/null 2>&1; then
    adduser --system --group --home /var/lib/llama.cpp --no-create-home llama-cpp
    note_changed
  else
    note_satisfied
  fi
  install -d -m 755 -o root -g root /opt/llama.cpp /opt/llama.cpp/versions
  install -d -m 755 -o root -g root /etc/llama.cpp /var/cache/llama.cpp
  install -d -m 755 -o root -g root /var/lib/llama.cpp
  install -d -m 750 -o llama-cpp -g llama-cpp \
    /var/lib/llama.cpp/models \
    /var/lib/llama.cpp/state /var/log/llama.cpp
  local marker
  for marker in /etc/llama.cpp/managed-by-beep \
      /var/lib/llama.cpp/managed-by-beep; do
    printf 'component=llama\nformat=1\n' \
      | install -m 644 -o root -g root /dev/stdin "${marker}"
  done

  section "Install pinned llama.cpp CPU runtime"
  local runtime_valid=0
  if [[ -x "${runtime_dir}/llama-server" \
      && -f "${runtime_dir}/.tree-sha256" ]] \
      && (cd "${runtime_dir}" && sha256sum -c .tree-sha256 >/dev/null 2>&1); then
    runtime_valid=1
  fi
  if (( ! runtime_valid )); then
    download_verified_file "${runtime_url}" "${runtime_sha}" \
      "${runtime_archive}" "pinned llama.cpp ${LLAMA_RUNTIME_RELEASE}"
    if tar -tzf "${runtime_archive}" \
        | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
      die "Pinned llama.cpp archive contains an unsafe path." 1
    fi
    runtime_stage="$(mktemp -d /opt/llama.cpp/versions/.stage.XXXXXX)"
    tar -xzf "${runtime_archive}" -C "${runtime_stage}"
    [[ -x "${runtime_stage}/${archive_root}/llama-server" \
        && -x "${runtime_stage}/${archive_root}/llama-cli" \
        && -x "${runtime_stage}/${archive_root}/llama-bench" ]] \
      || { rm -rf "${runtime_stage}"; die "llama.cpp archive is missing expected binaries." 1; }
    rm -rf "${runtime_dir}"
    mv "${runtime_stage}/${archive_root}" "${runtime_dir}"
    rm -rf "${runtime_stage}"
    chown -R root:root "${runtime_dir}"
    (
      cd "${runtime_dir}"
      find . -type f ! -name .tree-sha256 -print0 \
        | sort -z | xargs -0 sha256sum > .tree-sha256
    )
    chmod -R a-w "${runtime_dir}"
    note_changed
  else
    note_satisfied
  fi
  ln -sfn "${runtime_dir}" /opt/llama.cpp/current.new
  mv -Tf /opt/llama.cpp/current.new /opt/llama.cpp/current

  section "Install verified default llama model"
  local model_present=0
  [[ -f "${model_path}" ]] \
    && [[ "$(sha256sum "${model_path}" | awk '{print $1}')" == "${model_sha}" ]] \
    && model_present=1
  download_verified_file "${model_url}" "${model_sha}" \
    "${model_path}" "approved llama model"
  [[ "$(stat -c %s "${model_path}")" == "${model_size}" ]] \
    || { rm -f "${model_path}"; die "llama model size mismatch." 1; }
  if (( model_present )); then
    note_satisfied
  else
    note_changed
  fi
  chown llama-cpp:llama-cpp "${model_path}"
  chmod 640 "${model_path}"

  section "Configure beep-llama-manager and loopback service"
  install -m 755 -o root -g root \
    "${PAYLOAD_DIR}/bin/beep-llama-manager" /usr/local/bin/beep-llama-manager
  install -m 644 -o root -g root "${build_catalog}" /etc/llama.cpp/builds.json
  install -m 644 -o root -g root "${model_catalog}" /etc/llama.cpp/models.json
  cat > /etc/llama.cpp/config.json <<EOF
{
  "schema_version": 1,
  "port": ${LLAMA_PORT},
  "model_id": "${LLAMA_MODEL_ID}",
  "model_path": "${model_path}",
  "context_size": ${LLAMA_CONTEXT_SIZE},
  "threads": ${LLAMA_CPU_THREADS},
  "runtime_release": "${LLAMA_RUNTIME_RELEASE}",
  "runtime_dir": "/opt/llama.cpp/current"
}
EOF
  chown root:root /etc/llama.cpp/config.json
  chmod 644 /etc/llama.cpp/config.json
  install -m 644 -o root -g root \
    "${PAYLOAD_DIR}/systemd/llama-server.service" \
    /etc/systemd/system/llama-server.service
  systemctl daemon-reload
  if [[ "${LLAMA_BOOT}" == "enabled" ]]; then
    systemctl enable --now llama-server.service
    local ready=0
    for _ in $(seq 1 "${LLAMA_HEALTH_ATTEMPTS}"); do
      if curl -fsS --max-time 2 -o /dev/null \
          "http://127.0.0.1:${LLAMA_PORT}/health"; then
        ready=1
        break
      fi
      sleep 1
    done
    (( ready )) \
      || die "llama-server did not become healthy; check journalctl -u llama-server." 1
  else
    systemctl disable --now llama-server.service 2>/dev/null || true
  fi
  # option-sections: llama end
}

write_beep_manifest() {
  write_component_manifest "${COMPONENT_BEEP}" "${SCRIPT_VERSION}" ""
}

write_forgejo_manifest() {
  FORGEJO_URL_HOST="${FORGEJO_URL_HOST:-$(forgejo_url_host)}"
  FORGEJO_OK=0
  systemctl is-active --quiet forgejo.service && FORGEJO_OK=1
  if (( FORGEJO_OK )); then
    status ok "Forgejo ${FORGEJO_RESOLVED_VERSION:-} running at https://${FORGEJO_URL_HOST}/"
  else
    status warn "Forgejo ${FORGEJO_RESOLVED_VERSION:-} is not running"
  fi
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]]; then
    RUNNER_OK=0
    systemctl is-active --quiet forgejo-runner.service && RUNNER_OK=1
    if (( RUNNER_OK )); then
      status ok "Forgejo Actions runner registered and running"
    else
      status warn "Forgejo Actions runner is not running"
    fi
  fi
  forgejo_suboptions=""
  if [[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}" \
      && ! forgejo_runner_manifest_present; then
    forgejo_suboptions="runner"
  fi
  write_component_manifest "${COMPONENT_FORGEJO}" \
    "${FORGEJO_RESOLVED_VERSION:-${FORGEJO_VERSION:-}}" "${forgejo_suboptions}"
}

write_forgejo_runner_manifest() {
  RUNNER_OK=0
  systemctl is-active --quiet forgejo-runner.service && RUNNER_OK=1
  if (( RUNNER_OK )); then
    status ok "Forgejo Actions runner registered and running"
  else
    status warn "Forgejo Actions runner is not running"
  fi
  write_component_manifest "${COMPONENT_FORGEJO_RUNNER}" \
    "${FORGEJO_RUNNER_RESOLVED_VERSION:-${FORGEJO_RUNNER_VERSION:-}}" \
    "${FORGEJO_RUNNER_LABELS}"
}

write_llama_manifest() {
  write_component_manifest "${COMPONENT_LLAMA}" \
    "${LLAMA_RUNTIME_RELEASE:?llama runtime release was not resolved}" \
    "${LLAMA_MODEL_ID}"
}

final_beep_summary() {
  if [[ "${PROVIDER_OK}" != "1" ]]; then
    NEXT_STEP="sudo ${BEEP_DIR}/bin/beep-secrets-edit   # paste a supported provider API key"
  elif [[ "${CHAT_OK}" != "1" ]]; then
    NEXT_STEP="sudo systemctl start beep-chat.service"
  else
    NEXT_STEP="sudo reboot"
  fi
  printf 'Chat:    http://127.0.0.1:%s/ (localhost only, after reboot)\n' "${CHAT_PORT}"
  printf 'Check:   %s/bin/verify  ·  %s/bin/beep-audit\n' "${BEEP_DIR}" "${BEEP_DIR}"
}

final_forgejo_summary() {
  [[ -n "${NEXT_STEP}" ]] || NEXT_STEP="https://${FORGEJO_URL_HOST}/"
  printf 'Forgejo: https://%s/ (LAN mDNS + Caddy local CA%s)\n' \
    "${FORGEJO_URL_HOST}" \
    "$([[ "${BEEP_INSTALL_FORGEJO_RUNNER}" == "1" ]] \
      && ! is_selected_component "${COMPONENT_FORGEJO_RUNNER}" \
      && echo ', runner enabled')"
  printf 'Trust CA: /etc/forgejo/caddy-local-ca.crt\n'
}

final_forgejo_runner_summary() {
  [[ -n "${NEXT_STEP}" ]] || NEXT_STEP="systemctl status forgejo-runner.service"
  printf 'Runner:  Forgejo Actions runner registered and enabled\n'
}

final_llama_summary() {
  [[ -n "${NEXT_STEP}" ]] || NEXT_STEP="beep-llama-manager status"
  printf 'Llama:  http://127.0.0.1:%s/v1 (PC-wide loopback API)\n' "${LLAMA_PORT}"
  printf 'Manage: sudo beep-llama-manager {start|stop|restart|enable|disable|test}\n'
}

for component in "${SELECTED_COMPONENTS[@]}"; do
  component_dispatch_hook "${component}" install
  component_dispatch_hook "${component}" manifest
done
echo

NEXT_STEP=""
INSTALL_DURATION="$(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")"
printf '\n%s%sInstall complete in %s.%s\n' \
  "${C_GREEN}" "${C_BOLD}" "${INSTALL_DURATION}" "${C_RESET}"
for component in "${SELECTED_COMPONENTS[@]}"; do
  component_dispatch_hook "${component}" final
done
cat <<EOF
Next:    ${C_BOLD}${NEXT_STEP}${C_RESET}
Records: ${LOG_FILE}
         $([[ "${BEEP_RECEIPT}" == "1" ]] && echo "${RECEIPT_FILE}" || echo "receipt disabled")
Remove:  sudo ${SCRIPT_DIR}/uninstall.sh $(selected_components_label) --dry-run
EOF

if is_selected_component "${COMPONENT_BEEP}" && [[ "${NEXT_STEP}" != "sudo reboot" ]]; then
  info "Reboot after completing the next step: sudo reboot"
fi

if (( STEPS_SATISFIED + STEPS_CHANGED > 0 )); then
  info "Idempotent steps: ${STEPS_SATISFIED} already satisfied, ${STEPS_CHANGED} applied this run."
fi

# Finalise the install receipt with the outcome of this run.
write_receipt_finish
