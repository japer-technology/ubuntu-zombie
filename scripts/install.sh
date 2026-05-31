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
#   ZOMBIE_NONINTERACTIVE=1     skip prompts (then SSH_PUBLIC_KEY and
#                               VNC_PASSWORD must be set unless already
#                               configured on disk).
#   ZOMBIE_USER="zombie"        name of the local account created as the
#                               operating identity of the AI Systems
#                               Administrator. Defaults to `zombie`. The
#                               legacy name `AGENT_USER` is still
#                               accepted for backward compatibility.
#   ZOMBIE_ENABLE_AUTOLOGIN=1   enable graphical autologin for the
#                               agent account (off by default).
#   ZOMBIE_SKIP_TAILSCALE=1     skip installing and enrolling Tailscale.
#                               This is the default. Inbound SSH is then
#                               allowed on every interface instead of being
#                               restricted to tailscale0, and a Tailscale
#                               account is not required.
#   ZOMBIE_SKIP_TAILSCALE=0     opt in to installing and enrolling Tailscale
#                               and restricting inbound SSH to tailscale0.
#                               Requires a Tailscale account.
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host"
#   VNC_PASSWORD="..."
#   TAILSCALE_AUTHKEY="tskey-auth-..."  (used only when ZOMBIE_SKIP_TAILSCALE=0)

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
  SCRIPT_VERSION="0.2.0"
fi
readonly SCRIPT_VERSION

AGENT_USER="${ZOMBIE_USER:-${AGENT_USER:-zombie}}"
AGENT_HOME="/home/${AGENT_USER}"
ZOMBIE_DIR="${ZOMBIE_DIR:-/opt/ai-zombie}"
ZOMBIE_ETC="/etc/ubuntu-zombie"
ZOMBIE_LOG_DIR="/var/log/ubuntu-zombie"
VNC_PORT="${VNC_PORT:-5900}"
CHAT_PORT="${ZOMBIE_CHAT_PORT:-7878}"
LOG_FILE="${LOG_FILE:-/var/log/ubuntu-zombie-install.log}"

ZOMBIE_NONINTERACTIVE="${ZOMBIE_NONINTERACTIVE:-0}"
ZOMBIE_ENABLE_AUTOLOGIN="${ZOMBIE_ENABLE_AUTOLOGIN:-0}"
# Tailscale is OFF by default. Opt in by setting ZOMBIE_SKIP_TAILSCALE=0
# (install and enrol Tailscale, restricting inbound SSH to tailscale0).
ZOMBIE_SKIP_TAILSCALE="${ZOMBIE_SKIP_TAILSCALE:-1}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

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

# Idempotency transparency: count how many idempotent steps were already in
# place versus newly applied, so a re-run does not look like a fresh install.
STEPS_SATISFIED=0
STEPS_CHANGED=0
note_satisfied() { STEPS_SATISFIED=$((STEPS_SATISFIED + 1)); }
note_changed()   { STEPS_CHANGED=$((STEPS_CHANGED + 1)); }

PAYLOAD_DIR="${PAYLOAD_DIR:-${REPO_ROOT}/payload}"

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
    printf '    Fix: free up space (e.g. `sudo apt-get clean`, `docker system prune`) and re-run.\n' >&2
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Ubuntu Zombie baseline installer + AI Systems Administrator chat service.

Usage:
  sudo ./${SCRIPT_NAME} [SUBCOMMAND] [FLAGS]

Subcommands:
  install     Full install (default). Idempotent.
  verify      Read-only state check. Does not change state.
  doctor      Explain failures and likely fixes.
  repair      Apply known-safe fixes (re-assert permissions, retry
              Tailscale login, restart the chat service).
  uninstall   Reverse the install (delegates to uninstall.sh).

Flags:
  Behaviour
    -n, --dry-run     Print the install plan without touching the host.
                      Only meaningful with the 'install' subcommand.
    -y, --yes         Skip the "Type YES" confirmation. Still prompts for
                      any missing inputs (use ZOMBIE_NONINTERACTIVE=1 to
                      skip every prompt for fully unattended installs).
        --strict      Treat preflight warnings as fatal.
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
  ZOMBIE_NONINTERACTIVE=1     skip prompts (then SSH_PUBLIC_KEY and
                              VNC_PASSWORD must be set unless already
                              configured on disk).
  ZOMBIE_USER=<name>          name of the local agent account (default
                              'zombie'). Must be set on every later
                              install/verify/doctor/repair/uninstall
                              run that targets a non-default account.
  ZOMBIE_ENABLE_AUTOLOGIN=1   enable graphical autologin (off by default).
  ZOMBIE_SKIP_TAILSCALE=1     skip installing/enrolling Tailscale. This is
                              the default. Inbound SSH is then allowed on
                              every interface rather than only on tailscale0.
  ZOMBIE_SKIP_TAILSCALE=0     opt in to Tailscale: install/enrol it and
                              restrict inbound SSH to tailscale0 (needs a
                              Tailscale account).
  ZOMBIE_COLOR=auto|always|never   colour policy (default auto).
  SSH_PUBLIC_KEY              SSH public key string.
  VNC_PASSWORD                Loopback-only VNC password.
  TAILSCALE_AUTHKEY           Pre-auth key for unattended Tailscale
                              (used only when ZOMBIE_SKIP_TAILSCALE=0).

Examples:
  # Preview the plan before granting anything:
  sudo ./${SCRIPT_NAME} install --dry-run

  # Minimal interactive install (prompts for SSH key + VNC password):
  sudo ./${SCRIPT_NAME} install

  # Attended, but skip the YES gate:
  sudo ./${SCRIPT_NAME} install --yes

  # Opt in to Tailscale (install/enrol it; SSH restricted to tailscale0):
  sudo ZOMBIE_SKIP_TAILSCALE=0 ./${SCRIPT_NAME} install

  # Fully unattended (CI / cloud-init):
  sudo ZOMBIE_NONINTERACTIVE=1 \\
       SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host" \\
       VNC_PASSWORD="s3cret" \\
       ./${SCRIPT_NAME} install

  # Fully unattended, with Tailscale enrolment via a pre-auth key:
  sudo ZOMBIE_NONINTERACTIVE=1 \\
       ZOMBIE_SKIP_TAILSCALE=0 \\
       SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host" \\
       VNC_PASSWORD="s3cret" \\
       TAILSCALE_AUTHKEY="tskey-auth-..." \\
       ./${SCRIPT_NAME} install

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
PARSED_ARGS=()
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
    install|verify|doctor|repair|uninstall)
                  if (( SUBCOMMAND_SEEN )); then
                    # A second subcommand token (e.g. `install install`) is
                    # ambiguous — fall through to the catch-all so it is
                    # reported as an unexpected positional. See FIX-1-15.
                    PARSED_ARGS+=("$1"); shift
                  else
                    SUBCOMMAND="$1"; SUBCOMMAND_SEEN=1; shift
                  fi ;;
    --) shift; PARSED_ARGS+=("$@"); break ;;
    -*) die "Unknown flag: $1 (try --help)" 2 ;;
    *)  PARSED_ARGS+=("$1"); shift ;;
  esac
done
readonly DRY_RUN

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

append_line_once() {
  local line="$1"
  local file="$2"
  if grep -qxF "$line" "$file" 2>/dev/null; then
    note_satisfied
    return 0
  fi
  # Ensure the file ends with a newline before appending, so we don't
  # concatenate the new line onto whatever was on the final partial line.
  if [[ -s "$file" ]] && [[ "$(tail -c1 "$file" 2>/dev/null)" != $'\n' ]]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$line" >> "$file"
  note_changed
}

is_ssh_pubkey() {
  # Accept any line that "looks like" an OpenSSH public key
  # ("<type> <base64> [comment]") and then defer real validation to
  # ssh-keygen, which knows about every key/certificate type OpenSSH
  # itself accepts (including sk-* FIDO keys, ssh-ed448, and the
  # *-cert-v01@openssh.com certificate blobs). See FIX-2-10.
  [[ "$1" =~ ^[A-Za-z0-9@._+/-]+[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    printf '%s\n' "$1" | ssh-keygen -l -f - >/dev/null 2>&1 || return 1
  fi
  return 0
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

# Validate user-controlled install settings before they are interpolated into
# paths, sudoers entries, generated unit files, or shell commands.
validate_config() {
  if ! is_supported_agent_username "${AGENT_USER}"; then
    die "Invalid agent username '${AGENT_USER}'. Use a non-reserved lowercase Linux username (letters first; then letters, digits, underscore, hyphen; max 32 chars; no trailing punctuation)." 2
  fi
  if ! is_safe_absolute_path "${ZOMBIE_DIR}"; then
    die "ZOMBIE_DIR must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  if ! is_safe_absolute_path "${LOG_FILE}"; then
    die "LOG_FILE must be an absolute path using only letters, digits, dot, underscore, slash, plus, colon, and hyphen." 2
  fi
  if ! is_valid_tcp_port "${VNC_PORT}"; then
    die "VNC_PORT must be an integer from 1 to 65535." 2
  fi
  if ! is_valid_tcp_port "${CHAT_PORT}"; then
    die "ZOMBIE_CHAT_PORT must be an integer from 1 to 65535." 2
  fi
}

# Unknown positional arguments are collected in PARSED_ARGS during option
# parsing; only the uninstall subcommand forwards them to uninstall.sh.
reject_unexpected_positional_args() {
  [[ ${#PARSED_ARGS[@]} -eq 0 ]] && return 0
  die "Unexpected argument(s) for ${SUBCOMMAND}: ${PARSED_ARGS[*]}" 2
}

# Source /etc/os-release into the current shell.
load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
  fi
}

# Map the running Ubuntu's VERSION_ID / *_CODENAME to a supported Ubuntu
# apt-repo codename. Tailscale and Docker both publish per-codename repos,
# so a wrong guess installs an incompatible package set. Returns 0 and
# echoes the codename on success; returns non-zero with no output if the
# host is not a supported Ubuntu LTS. See FIX-1-09.
resolve_ubuntu_codename() {
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ -z "${codename}" ]]; then
    case "${VERSION_ID:-}" in
      22.04) codename="jammy" ;;
      24.04) codename="noble" ;;
      *)     return 1 ;;
    esac
  fi
  printf '%s\n' "${codename}"
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
    *) warn "Unusual architecture ${arch}; Docker/Tailscale apt repos may not match."
       warnings=$((warnings + 1)); pf warn "Architecture ${arch}" ;;
  esac

  # Disk: need ~5 GB free under / for runtime + Chromium + Docker layers.
  local avail_kb
  avail_kb="$(df -P / | awk 'NR==2 {print $4}')"
  if [[ "${avail_kb:-0}" -lt 5000000 ]]; then
    warn "Less than 5 GB free under / ($((avail_kb/1024)) MB). Install may fail."
    warnings=$((warnings + 1)); pf warn "Disk >= 5 GB free ($((avail_kb/1024)) MB)"
  else
    pf ok "Disk free $((avail_kb/1024)) MB"
  fi

  # Memory: 2 GB minimum recommended.
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem_kb:-0}" -lt 2000000 ]]; then
    warn "Less than 2 GB RAM ($((mem_kb/1024)) MB). Desktop + Chromium will be tight."
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

  # Outbound connectivity
  if ! curl_get -o /dev/null -m 8 https://archive.ubuntu.com/ >/dev/null 2>&1 \
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

  # Public-SSH risk: is the SSH session terminating on a non-Tailscale
  # local address? SSH_CONNECTION is "<client_ip> <client_port> <local_ip>
  # <local_port>", so field 3 is the address sshd accepted the connection
  # on. The previous version greped tailscale0 for the client IP, which by
  # construction never matched and fired the warning unconditionally
  # (FIX-2-06).
  if [[ -n "${SSH_CONNECTION:-}" && "${ZOMBIE_SKIP_TAILSCALE}" != "1" ]]; then
    local local_ip
    local_ip="$(awk '{print $3}' <<<"${SSH_CONNECTION}")"
    local ts_addrs
    ts_addrs="$(ip -o addr show dev tailscale0 2>/dev/null \
                  | awk '{print $4}' | cut -d/ -f1)"
    if [[ -n "${local_ip}" ]] \
       && ! printf '%s\n' "${ts_addrs}" | grep -qxF "${local_ip}"; then
      warn "Detected SSH session terminating on ${local_ip}, which is NOT a tailscale0 address."
      warn "Installer restarts sshd and tightens UFW; you risk locking yourself out."
      if [[ "${ZOMBIE_NONINTERACTIVE}" != "1" && "${SUBCOMMAND}" == "install" ]]; then
        warnings=$((warnings + 1)); pf warn "SSH session on tailscale0"
      fi
    fi
  fi

  # Tailscale already present?
  if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
    warn "Tailscale is disabled (default; opt in with ZOMBIE_SKIP_TAILSCALE=0)."
    warn "  Inbound SSH will be allowed on every interface instead of only on"
    warn "  tailscale0. Only use this on a network you control (e.g. behind a"
    warn "  NAT/router or VPN)."
    warnings=$((warnings + 1)); pf warn "Tailscale skipped (SSH on every interface)"
  elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
      info "Tailscale is already installed and logged in."
      pf ok "Tailscale logged in"
    else
      info "Tailscale is installed but not logged in."
      pf info "Tailscale installed (not logged in)"
    fi
  fi

  # Display manager: warn if a non-GDM DM is active.
  if [[ -r /etc/X11/default-display-manager ]]; then
    local dm
    dm="$(tr -d '[:space:]' < /etc/X11/default-display-manager)"
    if [[ "${dm}" != *gdm* ]]; then
      warn "Active display manager is ${dm}, not GDM. The installer enables GDM autologin/Xorg via /etc/gdm3/."
      warnings=$((warnings + 1)); pf warn "Display manager is GDM (found ${dm})"
    else
      pf ok "Display manager is GDM"
    fi
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

  # FIX-2-08: treat an authorized_keys file that only contains blank lines
  # and comments as if no key was authorized, so non-interactive installs
  # cannot silently lock the operator out.
  local existing_keys=0
  if [[ -r "${AGENT_HOME}/.ssh/authorized_keys" ]]; then
    existing_keys="$(grep -cvE '^[[:space:]]*(#|$)' \
                       "${AGENT_HOME}/.ssh/authorized_keys" 2>/dev/null || true)"
    existing_keys="${existing_keys:-0}"
  fi

  local missing=()
  if [[ -z "${SSH_PUBLIC_KEY}" && "${existing_keys}" -eq 0 ]]; then
    missing+=("SSH_PUBLIC_KEY")
  fi
  if [[ -z "${VNC_PASSWORD}" && ! -f "${AGENT_HOME}/.vnc/passwd" ]]; then
    missing+=("VNC_PASSWORD")
  fi
  if [[ -n "${SSH_PUBLIC_KEY}" ]] && ! is_ssh_pubkey "${SSH_PUBLIC_KEY}"; then
    die "SSH_PUBLIC_KEY does not look like an OpenSSH public key." 64
  fi
  if (( ${#missing[@]} > 0 )); then
    warn "Non-interactive mode requires the following to be set:"
    local var
    for var in "${missing[@]}"; do
      case "${var}" in
        SSH_PUBLIC_KEY)
          warn "  export SSH_PUBLIC_KEY=\"ssh-ed25519 AAAA... you@host\"" ;;
        VNC_PASSWORD)
          warn "  export VNC_PASSWORD=\"<a-loopback-only-password>\"" ;;
        *)
          warn "  export ${var}=..." ;;
      esac
    done
    die "Non-interactive mode requires: ${missing[*]}" 64
  fi
}

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
  # passwordless sudo, DISPLAY, xdotool against the live X session) only
  # make sense when run by the agent account. If invoked as root, re-exec
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

  if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
    dr info tailscale "Tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)."
  elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
      dr ok tailscale "Tailscale logged in."
    else
      dr warn tailscale "Tailscale logged out. Fix: sudo tailscale up"
    fi
  else
    dr warn tailscale "Tailscale missing. Fix: sudo ./${SCRIPT_NAME} install (or set ZOMBIE_SKIP_TAILSCALE=1)"
  fi

  if ufw status 2>/dev/null | grep -q "Status: active"; then
    dr ok ufw "UFW active."
  else
    dr warn ufw "UFW not active. Fix: sudo ./${SCRIPT_NAME} repair"
  fi

  if [[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]]; then
    if grep -q "AutomaticLoginEnable=true" /etc/gdm3/custom.conf 2>/dev/null; then
      dr ok autologin "Autologin enabled (ZOMBIE_ENABLE_AUTOLOGIN=1)."
    else
      dr warn autologin "Autologin requested but not configured. Fix: sudo ZOMBIE_ENABLE_AUTOLOGIN=1 ./${SCRIPT_NAME} install"
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

  if command -v ufw >/dev/null 2>&1; then
    ufw --force default deny incoming || true
    ufw --force default allow outgoing || true
    if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
      if ! ufw status | grep -qE '(^|[[:space:]])22/tcp([[:space:]]|$)'; then
        ufw allow 22/tcp comment "SSH (Tailscale skipped)" || true
      fi
    else
      if ! ufw status | grep -q "tailscale0.*22/tcp"; then
        ufw allow in on tailscale0 to any port 22 proto tcp comment "SSH over Tailscale only" || true
      fi
    fi
    ufw --force enable >/dev/null || true
    ok "Firewall re-asserted."
  fi

  if [[ "${ZOMBIE_SKIP_TAILSCALE}" != "1" && -n "${TAILSCALE_AUTHKEY}" ]]; then
    tailscale up --ssh=false --authkey "${TAILSCALE_AUTHKEY}" || warn "Tailscale auth-key login failed."
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
}

# ---------------------------------------------------------------------------
# Subcommand: uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  if [[ -x "${SCRIPT_DIR}/uninstall.sh" ]]; then
    exec "${SCRIPT_DIR}/uninstall.sh" "${PARSED_ARGS[@]}"
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

A real 'install' run with the current environment would:

  Host:           ${ID:-?} ${VERSION_ID:-?} on $(dpkg --print-architecture 2>/dev/null || uname -m)
  Agent user:     ${AGENT_USER}  (home: ${AGENT_HOME})
  Install root:   ${ZOMBIE_DIR}
  Etc dir:        ${ZOMBIE_ETC}
  Log dir:        ${ZOMBIE_LOG_DIR}
  Transcript:     ${LOG_FILE}
  Chat port:      ${CHAT_PORT}/tcp (loopback only)
  VNC port:       ${VNC_PORT}/tcp (loopback only)
  Tailscale:      $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "SKIPPED (ZOMBIE_SKIP_TAILSCALE=1)" || echo "installed and enrolled")
  Autologin:      $([[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]] && echo enabled || echo disabled)
  Mode:           $([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)

Apt package groups installed:
  base            openssh-server, sudo, curl, ufw, fail2ban, unattended-upgrades, git,
                  python3*, build-essential, ripgrep, jq, …
  desktop         ubuntu-desktop-minimal, gdm3, xorg, x11vnc, xdotool, scrot, …
  nodejs          Node 22.x from deb.nodesource.com (signed-by keyring)
  docker          docker-ce, docker-ce-cli, containerd.io (official Docker apt)
  $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "(tailscale skipped)" || echo "tailscale       tailscale (official Tailscale apt)")

Files & directories created / re-asserted:
  /etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie   (NOPASSWD: ALL for ${AGENT_USER})
  ${AGENT_HOME}/.ssh/authorized_keys              (700 dir, 600 file, ${AGENT_USER}:${AGENT_USER})
  /etc/ssh/sshd_config.d/                         (key-only auth drop-in)
  /etc/gdm3/custom.conf                           (Xorg, optional autologin)
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

Firewall (ufw):
  default          deny incoming / allow outgoing
  $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "ssh             ALLOW IN 22/tcp from any (Tailscale skipped)" || echo "ssh             ALLOW IN 22/tcp on tailscale0 only")

Nothing has been changed. To proceed for real:

  sudo ./${SCRIPT_NAME} install

See docs/QUICKSTART.md and docs/ARCHITECTURE.md for the full picture.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch non-install subcommands early.
# ---------------------------------------------------------------------------

trap 'on_error ${LINENO}' ERR

validate_config

case "${SUBCOMMAND}" in
  verify)    reject_unexpected_positional_args; cmd_verify; exit $? ;;
  doctor)    reject_unexpected_positional_args; cmd_doctor; exit $? ;;
  repair)    reject_unexpected_positional_args; require_root; cmd_repair; exit $? ;;
  uninstall) require_root; cmd_uninstall; exit $? ;;
  install)   reject_unexpected_positional_args ;;
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
preflight
validate_noninteractive

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
ZOMBIE_PHASE_TOTAL="$(awk '/^# install — the rest of the file/{f=1} f && /^section "/{c++} END{print c+0}' "${BASH_SOURCE[0]}" 2>/dev/null || echo 0)"
# The count is derived by scanning this file, so guard against a 0/empty
# result (e.g. if the marker comment is ever moved) — fall back to an
# un-totalled "[n]" counter rather than printing a confusing "[n/0]".
[[ "${ZOMBIE_PHASE_TOTAL}" =~ ^[0-9]+$ ]] || ZOMBIE_PHASE_TOTAL=0
_SECTION_T0=""

# Re-define section() to: record a step breadcrumb, number the phase, and
# report how long the previous phase took so a long silent step is visibly
# making progress rather than appearing hung.
section() {
  local now; now="$(date +%s)"
  if [[ -n "${_SECTION_T0}" ]]; then
    (( ZOMBIE_QUIET )) || printf '%s    (previous step took %s)%s\n' \
      "${C_CYAN}" "$(fmt_duration "$(( now - _SECTION_T0 ))")" "${C_RESET}"
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
  printf '\n%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
  printf '%s%s %s%s\n' "${C_BOLD}" "${counter}" "$*" "${C_RESET}"
  printf '%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
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
if ! (( ZOMBIE_QUIET )); then
  printf '\n%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
  printf '%s%s %s  —  install%s\n' "${C_BOLD}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${C_RESET}"
  printf '%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
fi

info "Log file: ${LOG_FILE}"
info "Agent user: ${AGENT_USER}"
info "Install root: ${ZOMBIE_DIR}"
info "Chat port: ${CHAT_PORT} (loopback only)"
info "Autologin: $([[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]] && echo enabled || echo disabled)"
info "Mode: $([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"
if (( ZOMBIE_PHASE_TOTAL > 0 )); then
  info "Phases: ${ZOMBIE_PHASE_TOTAL}. Typical run takes ~10–20 min depending on network speed."
else
  info "Typical run takes ~10–20 min depending on network speed."
fi

cat <<EOF

This installer will:
  - Create the ${AGENT_USER} user (operating identity of the AI Systems Administrator) with passwordless sudo
  - Enable SSH key-only access
  - $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "Skip Tailscale install/enrolment (ZOMBIE_SKIP_TAILSCALE=1); allow SSH on every interface" || echo "Install Tailscale from its official apt repository")
  - $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "Allow inbound SSH on every interface (no Tailscale)" || echo "Allow inbound SSH only on the Tailscale interface")
  - Force Xorg instead of Wayland
  - $([[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]] && echo "Enable graphical autologin (ZOMBIE_ENABLE_AUTOLOGIN=1)" || echo "Leave graphical autologin disabled (default)")
  - Enable loopback-only x11vnc for emergency desktop access
  - Install GUI automation tools (xdotool, scrot, gnome-screenshot)
  - Install Playwright with Chromium for browser automation
  - Install Docker CE from its official apt repository
  - Install Python and Node agent runtimes
  - Install the loopback chat service (ubuntu-zombie-chat.service)
  - Install policy, audit log, and helper scripts
  - Enable automatic security updates

Run this from the physical Ubuntu machine, not over public SSH.

EOF

if [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]]; then
  info "Non-interactive mode: proceeding without confirmation."
elif (( ASSUME_YES )); then
  info "--yes: proceeding without confirmation."
else
  read -r -p "Continue? Type YES to proceed: " CONFIRM
  [[ "${CONFIRM}" == "YES" ]] || { info "Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

section "System update"

apt_get update
apt_get -y upgrade

section "Base packages"

apt_install \
  openssh-server \
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
  net-tools \
  dnsutils \
  iputils-ping \
  ufw \
  fail2ban \
  unattended-upgrades \
  logrotate \
  python3 \
  python3-pip \
  python3-venv \
  python3-tk \
  pipx \
  build-essential \
  ripgrep \
  fd-find \
  tree \
  rsync \
  cron \
  dbus-x11 \
  dconf-cli \
  pwgen \
  psmisc

section "Desktop, Xorg, and GUI control packages"

apt_install \
  ubuntu-desktop-minimal \
  gdm3 \
  xorg \
  x11vnc \
  xdotool \
  wmctrl \
  scrot \
  imagemagick \
  gnome-screenshot \
  xclip \
  xsel \
  xterm \
  at-spi2-core \
  x11-utils

# ---------------------------------------------------------------------------
# Agent user and sudo
# ---------------------------------------------------------------------------

section "Create ${AGENT_USER} user"

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
# SSH key
# ---------------------------------------------------------------------------

section "SSH key setup"

install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.ssh"
# Only create authorized_keys if it does not already exist. The previous
# "cat existing > tmp && mv tmp existing" dance was a functional no-op that
# left a window where a full disk could truncate the operator's keys and
# lock them out. See FIX-1-05. The chown/chmod below re-asserts ownership
# and mode whether or not the file pre-existed.
if [[ ! -e "${AGENT_HOME}/.ssh/authorized_keys" ]]; then
  install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${AGENT_HOME}/.ssh/authorized_keys"
fi
chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.ssh/authorized_keys"
chmod 600 "${AGENT_HOME}/.ssh/authorized_keys"

if [[ -r "${AGENT_HOME}/.ssh/authorized_keys" ]]; then
  EXISTING_KEYS="$(grep -cvE '^[[:space:]]*(#|$)' \
                     "${AGENT_HOME}/.ssh/authorized_keys" 2>/dev/null || true)"
  EXISTING_KEYS="${EXISTING_KEYS:-0}"
else
  EXISTING_KEYS=0
fi

if [[ -z "${SSH_PUBLIC_KEY}" && "${ZOMBIE_NONINTERACTIVE}" != "1" ]]; then
  if [[ "${EXISTING_KEYS}" -gt 0 ]]; then
    info "${EXISTING_KEYS} SSH key(s) already authorized for ${AGENT_USER}."
    # Re-prompts on a malformed key instead of aborting the whole install;
    # blank is accepted to skip adding another key.
    prompt_until_valid "Add another public key? Leave blank to skip: " \
      is_ssh_pubkey SSH_PUBLIC_KEY 1 || true
  else
    log
    log "Paste the SSH public key that will be allowed to control this machine."
    log "Example: ssh-ed25519 AAAAC3... you@workstation"
    log "Leave blank only if you will add it manually after install."
    prompt_until_valid "SSH public key (blank to add manually later): " \
      is_ssh_pubkey SSH_PUBLIC_KEY 1 || true
  fi
fi

if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
  if ! is_ssh_pubkey "${SSH_PUBLIC_KEY}"; then
    die "That does not look like an SSH public key. Expected a line starting with 'ssh-ed25519 ', 'ssh-rsa ', etc." 1
  fi
  append_line_once "${SSH_PUBLIC_KEY}" "${AGENT_HOME}/.ssh/authorized_keys"
  ok "Authorized the supplied SSH key."
elif [[ "${EXISTING_KEYS}" -eq 0 && "${ZOMBIE_NONINTERACTIVE}" == "1" ]]; then
  die "Non-interactive mode requires SSH_PUBLIC_KEY when no key is already authorized." 64
fi

chown -R "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.ssh"
chmod 700 "${AGENT_HOME}/.ssh"
chmod 600 "${AGENT_HOME}/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------

section "Harden SSH"

install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-ubuntu-zombie.conf <<EOF
# Managed by ${SCRIPT_NAME}.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding yes
AllowUsers ${AGENT_USER}
EOF

# sshd -t requires the privilege separation directory to exist; on fresh
# installs (or containers where /run is a tmpfs) it may be missing.
install -d -m 0755 /run/sshd
sshd -t
systemctl enable --now ssh >/dev/null
systemctl restart ssh
ok "SSH hardened (key-only, ${AGENT_USER} only)."

# ---------------------------------------------------------------------------
# Tailscale (official apt repo)
# ---------------------------------------------------------------------------

section "Install Tailscale"

if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
  info "Skipping Tailscale install (ZOMBIE_SKIP_TAILSCALE=1)."
else
  if ! command -v tailscale >/dev/null 2>&1; then
    install -d -m 755 /usr/share/keyrings
    if ! TS_CODENAME="$(resolve_ubuntu_codename)"; then
      die "Cannot determine Ubuntu codename for Tailscale repo (VERSION_ID='${VERSION_ID:-}'); supported: 22.04 jammy, 24.04 noble." 65
    fi
    curl_get "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${TS_CODENAME} main
EOF
    apt_get update
    apt_install tailscale
    ok "Tailscale installed from official apt repository."
  else
    info "Tailscale already installed."
  fi

  systemctl enable --now tailscaled >/dev/null
fi

# ---------------------------------------------------------------------------
# Firewall (idempotent)
# ---------------------------------------------------------------------------

if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
  section "Firewall (SSH allowed on every interface)"

  ufw --force default deny incoming
  ufw --force default allow outgoing

  # Remove any prior Tailscale-only SSH rule from a previous (non-skipped) run.
  while ufw status | grep -q "tailscale0.*22/tcp"; do
    ufw --force delete allow in on tailscale0 to any port 22 proto tcp >/dev/null 2>&1 || break
  done

  if ! ufw status | grep -qE '(^|[[:space:]])22/tcp([[:space:]]|$)'; then
    ufw allow 22/tcp comment "SSH (Tailscale skipped)"
  fi

  ufw --force enable >/dev/null
  warn "Tailscale is disabled. SSH is reachable from any network this host can be addressed on."
  ok "UFW: deny inbound, allow outbound, SSH allowed on every interface."
else
  section "Firewall (Tailscale-only inbound)"

  ufw --force default deny incoming
  ufw --force default allow outgoing

  # Remove any prior all-interface SSH rule we previously added (matched by
  # the comment we set in the skip-Tailscale branch). Tightened in FIX-1-16
  # so we never delete an unrelated 22/tcp rule the operator may have added.
  while ufw status numbered | grep -F '# SSH (Tailscale skipped)' | grep -q '22/tcp'; do
    rule_num="$(ufw status numbered \
      | awk -F'[][]' '/# SSH \(Tailscale skipped\)/ && /22\/tcp/ {print $2; exit}')"
    [[ -z "${rule_num}" ]] && break
    yes | ufw delete "${rule_num}" >/dev/null 2>&1 || break
  done

  if ! ufw status | grep -q "tailscale0.*22/tcp"; then
    ufw allow in on tailscale0 to any port 22 proto tcp comment "SSH over Tailscale only"
  fi

  ufw --force enable >/dev/null
  ok "UFW: deny inbound, allow outbound, SSH allowed only on tailscale0."
fi

# ---------------------------------------------------------------------------
# Security services and unattended upgrades
# ---------------------------------------------------------------------------

section "Security services"

systemctl enable --now fail2ban >/dev/null
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

# ---------------------------------------------------------------------------
# Xorg, optional autologin, no sleep, no lock
# ---------------------------------------------------------------------------

section "Force Xorg session"

install -d -m 755 /etc/gdm3
# FIX-2-13: only manage the four [daemon] keys we own; preserve any
# operator-authored content (e.g. [xdmcp] tweaks, greeter logo settings,
# WaylandEnable overrides on neighbouring keys). The first time the
# installer runs the file may not exist yet, so we create a minimal
# scaffold owned by us; on subsequent runs we update in place.
GDM_CONF="/etc/gdm3/custom.conf"
if [[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]]; then
  GDM_WAYLAND="false"
  GDM_AUTOLOGIN_ENABLE="true"
  GDM_AUTOLOGIN_USER="${AGENT_USER}"
else
  GDM_WAYLAND="false"
  GDM_AUTOLOGIN_ENABLE="false"
  GDM_AUTOLOGIN_USER=""
fi

if [[ ! -e "${GDM_CONF}" ]]; then
  cat > "${GDM_CONF}" <<EOF
# Managed by ${SCRIPT_NAME}.
[daemon]

[security]

[xdmcp]

[chooser]

[debug]
EOF
fi

# In-place INI updater: ensure [daemon] exists and set/replace the three
# keys we own (WaylandEnable, AutomaticLoginEnable, AutomaticLogin).
# Lines outside [daemon] are passed through verbatim. If AutomaticLogin
# should be unset (autologin disabled), the key is commented out rather
# than removed so a curious operator can still find it.
python3 - "${GDM_CONF}" "${GDM_WAYLAND}" "${GDM_AUTOLOGIN_ENABLE}" "${GDM_AUTOLOGIN_USER}" <<'PYEOF'
import os, sys
path, wayland, autologin_enable, autologin_user = sys.argv[1:5]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

owned = {
    "WaylandEnable": wayland,
    "AutomaticLoginEnable": autologin_enable,
}
if autologin_user:
    owned["AutomaticLogin"] = autologin_user

section = None
seen = {k: False for k in owned}
out = []
daemon_idx_end = None
for ln in lines:
    stripped = ln.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        if section == 'daemon':
            for k, v in owned.items():
                if not seen[k]:
                    out.append(f"{k}={v}\n")
                    seen[k] = True
        section = stripped[1:-1].lower()
        out.append(ln)
        continue
    if section == 'daemon':
        m = stripped.split('=', 1)
        key = m[0].lstrip('#').strip() if m else ''
        if key in owned and '=' in stripped:
            if not seen[key]:
                out.append(f"{key}={owned[key]}\n")
                seen[key] = True
            continue
        # If autologin is disabled, comment out any pre-existing
        # AutomaticLogin=<user> we don't own.
        if not autologin_user and key == 'AutomaticLogin' and '=' in stripped:
            out.append('# ' + ln if not ln.lstrip().startswith('#') else ln)
            continue
    out.append(ln)

if section == 'daemon':
    for k, v in owned.items():
        if not seen[k]:
            out.append(f"{k}={v}\n")
            seen[k] = True

# If [daemon] never appeared, append it.
if not any(s for s in seen.values()):
    out.append('\n[daemon]\n')
    for k, v in owned.items():
        out.append(f"{k}={v}\n")

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)
PYEOF

if [[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]]; then
  warn "Autologin is enabled. Any physical-access user gets an unlocked desktop as ${AGENT_USER}."
else
  info "Autologin is disabled. Desktop automation requires a live login as ${AGENT_USER}."
fi

install -d -m 755 /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/${AGENT_USER}" <<EOF
[User]
Session=ubuntu-xorg
XSession=ubuntu-xorg
SystemAccount=false
EOF

systemctl set-default graphical.target >/dev/null

section "Prevent sleep, suspend, and screen lock"

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true

runuser -l "${AGENT_USER}" -c "dbus-run-session -- gsettings set org.gnome.desktop.session idle-delay 0"             >/dev/null 2>&1 || true
runuser -l "${AGENT_USER}" -c "dbus-run-session -- gsettings set org.gnome.desktop.screensaver lock-enabled false"  >/dev/null 2>&1 || true
runuser -l "${AGENT_USER}" -c "dbus-run-session -- gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false" >/dev/null 2>&1 || true

ok "Sleep masked, lock disabled."

# ---------------------------------------------------------------------------
# Workspace at /opt/ai-zombie
# ---------------------------------------------------------------------------

section "Create Ubuntu Zombie workspace"

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
#   ZOMBIE_PROVIDER=openai      # openai|anthropic|gemini|xai|openrouter|mistral|groq
#   ZOMBIE_MODEL=gpt-4o-mini    # model for the agent loop + chat (required for openrouter)
#   ZOMBIE_CHAT_PORT=${CHAT_PORT}

DISPLAY=:0
ZOMBIE_DIR=${ZOMBIE_DIR}
AGENT_USER=${AGENT_USER}
AGENT_HOME=${AGENT_HOME}
ZOMBIE_CHAT_PORT=${CHAT_PORT}
EOF
  chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
  chmod 600 "${ZOMBIE_DIR}/secrets/env"
  ok "Created ${ZOMBIE_DIR}/secrets/env (edit with: sudo ${ZOMBIE_DIR}/bin/secrets-edit)."
else
  info "Preserving existing ${ZOMBIE_DIR}/secrets/env."
  chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/secrets/env"
  chmod 600 "${ZOMBIE_DIR}/secrets/env"
fi

# ---------------------------------------------------------------------------
# Docker CE (official repo)
# ---------------------------------------------------------------------------

section "Install Docker Engine"

if ! command -v docker >/dev/null 2>&1; then
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  install -m 0755 -d /etc/apt/keyrings
  curl_get https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  load_os_release
  if ! DOCKER_CODENAME="$(resolve_ubuntu_codename)"; then
    die "Cannot determine Ubuntu codename for Docker repo (VERSION_ID='${VERSION_ID:-}'); supported: 22.04 jammy, 24.04 noble." 65
  fi
  ARCH="$(dpkg --print-architecture)"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable
EOF
  apt_get update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  info "Docker already installed."
fi

usermod -aG docker "${AGENT_USER}"
systemctl enable --now docker >/dev/null
ok "Docker ready, ${AGENT_USER} is in the docker group."

# ---------------------------------------------------------------------------
# Python cloud-agent runtime
# ---------------------------------------------------------------------------

section "Python cloud-agent runtime"

# Stage the venv setup helper into ${ZOMBIE_DIR}/bin early so the
# unprivileged setup below can exec it. The rest of the operator
# helpers are installed in the "Deploy chat service" section below.
# Extracted in FIX-1-12 so the body is lintable by ShellCheck.
install -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/bin/setup-agent-venv" "${ZOMBIE_DIR}/bin/setup-agent-venv"

# Build the venv and install python packages as the agent user. This step
# downloads Chromium and can run for minutes; on an interactive TTY show a
# heartbeat spinner and route the (noisy) detail to the transcript, while
# non-interactive/CI runs keep the full output streaming as before.
#
# run_step needs a single command, so we wrap the redirection in `bash -c`.
# The arguments after the script are positional parameters for that inner
# shell: `_` is the throwaway $0, then $1=agent user, $2=helper path,
# $3=log file. We redirect the helper's stdout+stderr to the transcript so
# only the spinner shows on the console.
if [[ -t 2 ]] && ! (( ZOMBIE_QUIET )); then
  run_step "Building Python venv + browser (this can take a few minutes)" -- \
    bash -c 'runuser -l "$1" -- "$2" >>"$3" 2>&1' \
    _ "${AGENT_USER}" "${ZOMBIE_DIR}/bin/setup-agent-venv" "${LOG_FILE}"
else
  runuser -l "${AGENT_USER}" -- "${ZOMBIE_DIR}/bin/setup-agent-venv"
fi

# Install Chromium system dependencies as root (apt-get requires it). The
# unprivileged playwright browser download in setup-agent-venv above will
# then only fetch the browser binaries, which it can do as ${AGENT_USER}.
AGENT_VENV_PY="${AGENT_HOME}/agent-env/bin/python"
if [[ -x "${AGENT_VENV_PY}" ]]; then
  n=1; delay=5
  while true; do
    if "${AGENT_VENV_PY}" -m playwright install-deps chromium; then break; fi
    if (( n >= 4 )); then
      warn "playwright install-deps failed after ${n} attempts; Chromium may not launch."
      break
    fi
    log "playwright install-deps retry ${n} in ${delay}s..."
    sleep "${delay}"; n=$((n + 1)); delay=$((delay * 2))
  done
else
  warn "Agent venv python not found at ${AGENT_VENV_PY}; skipping playwright system deps."
fi

ok "Python venv ready at ${AGENT_HOME}/agent-env."

# ---------------------------------------------------------------------------
# Node runtime
# ---------------------------------------------------------------------------

section "Node runtime"

# The npm bundled with Ubuntu's apt-provided `nodejs` (Node 18 on
# 22.04/24.04) is too old to self-upgrade to npm@latest, which now
# requires Node ^20.17.0 || >=22.9.0. Install Node 22.x from the
# official NodeSource apt repository so the global npm install below —
# and the pi-ai / pi-coding-agent globals that follow — see a Node
# runtime they actually support. Pattern mirrors the Tailscale and
# Docker repo setup above (signed-by keyring + sources.list.d drop-in).
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
retry 4 5 -- npm install -g yarn pnpm typescript ts-node

# pi-ai is the unified LLM client for the chat service. Pinned to the
# exact version recorded in payload/agent/pi-ai.version so bumps are
# deliberate PRs with smoke evidence.
PI_AI_VERSION="$(tr -d '[:space:]' < "${PAYLOAD_DIR}/agent/pi-ai.version")"
if [[ -z "${PI_AI_VERSION}" ]]; then
  die "payload/agent/pi-ai.version is empty; refusing to install pi-ai unpinned." 1
fi
log "Installing @earendil-works/pi-ai@${PI_AI_VERSION} globally."
retry 4 5 -- npm install -g --ignore-scripts "@earendil-works/pi-ai@${PI_AI_VERSION}"

# pi-mono is the agent loop the chat service drives via
# payload/agent/pi-mono-bridge.mjs. Pinned the same way as pi-ai —
# the exact version is in payload/agent/pi-mono.version so version
# bumps land as deliberate PRs with their own smoke evidence.
PI_MONO_VERSION="$(tr -d '[:space:]' < "${PAYLOAD_DIR}/agent/pi-mono.version")"
if [[ -z "${PI_MONO_VERSION}" ]]; then
  die "payload/agent/pi-mono.version is empty; refusing to install pi-mono unpinned." 1
fi
log "Installing @earendil-works/pi-coding-agent@${PI_MONO_VERSION} globally."
retry 4 5 -- npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_MONO_VERSION}"

# ---------------------------------------------------------------------------
# Deploy payload: chat service, helpers, policy, systemd, logrotate.
# ---------------------------------------------------------------------------

section "Deploy chat service, helpers, and policy"

if [[ ! -d "${PAYLOAD_DIR}" ]]; then
  die "Payload directory ${PAYLOAD_DIR} not found. Re-clone the repository." 1
fi

# Chat service source.
install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${ZOMBIE_DIR}/agent" "${ZOMBIE_DIR}/agent/templates"
for f in server.py providers.py policy.py audit.py runner.py history.py tools.py pi_mono.py skill_loader.py examples.md; do
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

# Operator helpers.
for f in audit-recent health-check collect-diagnostics secrets-edit zombie-chat setup-agent-venv; do
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
# GUI control helper scripts (generated inline; they reference ZOMBIE_DIR).
# ---------------------------------------------------------------------------

section "GUI control helper scripts"

cat > "${ZOMBIE_DIR}/bin/gui-env" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -f ${ZOMBIE_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ${ZOMBIE_DIR}/secrets/env
  set +a
fi

export DISPLAY="\${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=\${XDG_RUNTIME_DIR}/bus}"

exec "\$@"
EOF

cat > "${ZOMBIE_DIR}/bin/screenshot" <<EOF
#!/usr/bin/env bash
set -euo pipefail
OUT="\${1:-${ZOMBIE_DIR}/state/screen.png}"
${ZOMBIE_DIR}/bin/gui-env gnome-screenshot -f "\$OUT"
echo "\$OUT"
EOF

cat > "${ZOMBIE_DIR}/bin/click" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -eq 2 ]] || { echo "Usage: click X Y" >&2; exit 2; }
${ZOMBIE_DIR}/bin/gui-env xdotool mousemove "\$1" "\$2" click 1
EOF

cat > "${ZOMBIE_DIR}/bin/type-text" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -ge 1 ]] || { echo "Usage: type-text 'text'" >&2; exit 2; }
${ZOMBIE_DIR}/bin/gui-env xdotool type --delay 10 "\$*"
EOF

cat > "${ZOMBIE_DIR}/bin/key" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -ge 1 ]] || { echo "Usage: key ctrl+l" >&2; exit 2; }
${ZOMBIE_DIR}/bin/gui-env xdotool key "\$@"
EOF

cat > "${ZOMBIE_DIR}/bin/agent-shell" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -f ${ZOMBIE_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ${ZOMBIE_DIR}/secrets/env
  set +a
fi

cd ${ZOMBIE_DIR}
exec tmux new -A -s ubuntu-zombie
EOF

chmod +x "${ZOMBIE_DIR}/bin/"gui-env "${ZOMBIE_DIR}/bin/"screenshot \
  "${ZOMBIE_DIR}/bin/"click "${ZOMBIE_DIR}/bin/"type-text \
  "${ZOMBIE_DIR}/bin/"key "${ZOMBIE_DIR}/bin/"agent-shell

chown -R "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}"

# ---------------------------------------------------------------------------
# Browser automation smoke test
# ---------------------------------------------------------------------------

section "Browser automation smoke test"

cat > "${ZOMBIE_DIR}/tools/browser-test.py" <<'EOF'
"""Smoke test: drive Chromium through Playwright on the real Xorg desktop."""
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=False)
    page = browser.new_page()
    page.goto("https://example.com")
    print(page.title())
    browser.close()
EOF

chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/tools/browser-test.py"

# ---------------------------------------------------------------------------
# x11vnc loopback only
# ---------------------------------------------------------------------------

section "x11vnc loopback-only desktop access"

runuser -l "${AGENT_USER}" -c "mkdir -p ~/.config/autostart ~/.local/share"
install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.vnc"

VNC_PASSWD_FILE="${AGENT_HOME}/.vnc/passwd"

if [[ -f "${VNC_PASSWD_FILE}" ]]; then
  info "VNC password already set; keeping it."
elif [[ -n "${VNC_PASSWORD}" ]]; then
  if ! printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
    | runuser -u "${AGENT_USER}" -- env HOME="${AGENT_HOME}" x11vnc -storepasswd >/dev/null 2>&1; then
    die "Failed to store VNC password; check that x11vnc is installed and ${AGENT_HOME}/.vnc is writable." 1
  fi
  chown "${AGENT_USER}:${AGENT_USER}" "${VNC_PASSWD_FILE}"
  chmod 600 "${VNC_PASSWD_FILE}"
  ok "VNC password set from VNC_PASSWORD env var."
elif [[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]]; then
  die "Non-interactive mode requires VNC_PASSWORD when no VNC password is already stored." 64
else
  log
  log "Set a VNC password. This is only used for emergency desktop access"
  log "over an SSH tunnel. VNC binds to 127.0.0.1, never to the network."
  # x11vnc -storepasswd prompts twice and masks input; on a mismatch it
  # exits non-zero. Retry a few times instead of aborting the whole install
  # on a single typo.
  vnc_attempt=0
  until runuser -l "${AGENT_USER}" -c "x11vnc -storepasswd"; do
    vnc_attempt=$((vnc_attempt + 1))
    if (( vnc_attempt >= 3 )); then
      die "Failed to set a VNC password after ${vnc_attempt} attempts." 1
    fi
    warn "That didn't work (passwords may not have matched). Try again."
  done
fi

cat > "${AGENT_HOME}/.config/autostart/x11vnc.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=x11vnc Loopback Only
Exec=/usr/bin/x11vnc -display :0 -forever -shared -localhost -rfbauth ${AGENT_HOME}/.vnc/passwd -rfbport ${VNC_PORT} -o ${AGENT_HOME}/.local/share/x11vnc.log
X-GNOME-Autostart-enabled=true
EOF

chown -R "${AGENT_USER}:${AGENT_USER}" \
  "${AGENT_HOME}/.config" "${AGENT_HOME}/.local" "${AGENT_HOME}/.vnc"

# ---------------------------------------------------------------------------
# Verification script
# ---------------------------------------------------------------------------

section "Install verification script"

cat > "${ZOMBIE_DIR}/bin/verify" <<EOF
#!/usr/bin/env bash
set -uo pipefail

ZOMBIE_DIR="${ZOMBIE_DIR}"
AGENT_USER="${AGENT_USER}"
AGENT_HOME="${AGENT_HOME}"
ZOMBIE_SKIP_TAILSCALE="${ZOMBIE_SKIP_TAILSCALE}"
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
check "ssh service active"                 systemctl is-active ssh
check "ufw active"                         bash -c "sudo ufw status | grep -q 'Status: active'"
if [[ "\${ZOMBIE_SKIP_TAILSCALE}" != "1" ]]; then
  check "tailscale binary present"           command -v tailscale
  check "tailscale is logged in"             bash -c "tailscale status >/dev/null 2>&1 && ! tailscale status | grep -q 'Logged out'"
else
  record skip "tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)"
  [[ "\${JSON}" == "1" ]] || printf '  %s[~]%s  tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)\\n' "\${C_YEL}" "\${C_RESET}"
fi
check "docker engine reachable"            docker version
[[ "\${JSON}" == "1" ]] || echo

hd "Desktop and GUI control:"
check "Xorg session forced for \${AGENT_USER}"  bash -c "grep -q 'XSession=ubuntu-xorg' /var/lib/AccountsService/users/\${AGENT_USER}"
check "x11vnc autostart present"           test -f \${AGENT_HOME}/.config/autostart/x11vnc.desktop
check "DISPLAY is set"                     test -n "\${DISPLAY:-}"
check "xdotool reachable on \${DISPLAY:-:0}" \${ZOMBIE_DIR}/bin/gui-env xdotool getdisplaygeometry
[[ "\${JSON}" == "1" ]] || echo

hd "Runtime:"
check "Python venv exists"                 test -x \${AGENT_HOME}/agent-env/bin/python
check "playwright importable"              \${AGENT_HOME}/agent-env/bin/python -c "from playwright.sync_api import sync_playwright"
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
check "skill tailscale.md deployed"        test -r \${ZOMBIE_DIR}/skills/tailscale.md
check "skill ufw.md deployed"              test -r \${ZOMBIE_DIR}/skills/ufw.md
check "skill docker.md deployed"           test -r \${ZOMBIE_DIR}/skills/docker.md
check "skill gui.md deployed"              test -r \${ZOMBIE_DIR}/skills/gui.md
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

hd "Screenshot:"
SHOT="\${ZOMBIE_DIR}/state/screen.png"
if \${ZOMBIE_DIR}/bin/screenshot "\$SHOT" >/dev/null 2>&1 && [[ -s "\$SHOT" ]]; then
  record ok "screenshot saved to \$SHOT"
  [[ "\${JSON}" == "1" ]] || printf '  %s[ok]%s screenshot saved to %s\\n' "\${C_GREEN}" "\${C_RESET}" "\$SHOT"
else
  record fail "screenshot failed (desktop session may not be active yet)"
  [[ "\${JSON}" == "1" ]] || printf '  %s[x]%s  screenshot failed (desktop session may not be active yet)\\n' "\${C_RED}" "\${C_RESET}"
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
  echo "  - If the desktop checks failed, run from a graphical login as \${AGENT_USER}."
  echo "  - If tailscale is logged out, run: sudo tailscale up"
  echo "  - If docker is not reachable, log out and log in again so the docker group applies."
  echo "  - If the chat service is not active: sudo systemctl status ubuntu-zombie-chat"
  exit 1
fi
EOF

chmod +x "${ZOMBIE_DIR}/bin/verify"
chown "${AGENT_USER}:${AGENT_USER}" "${ZOMBIE_DIR}/bin/verify"
ln -sf "${ZOMBIE_DIR}/bin/verify" /usr/local/bin/zombie-verify

# ---------------------------------------------------------------------------
# Tailscale enrolment
# ---------------------------------------------------------------------------

section "Tailscale authentication"

TS_STATUS_OK=0
if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
  info "Skipping Tailscale enrolment (ZOMBIE_SKIP_TAILSCALE=1)."
elif tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
  info "Tailscale is already logged in."
  TS_STATUS_OK=1
elif [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
  if tailscale up --ssh=false --authkey "${TAILSCALE_AUTHKEY}"; then
    ok "Tailscale logged in with pre-auth key."
    TS_STATUS_OK=1
  else
    warn "Tailscale auth-key login failed. Run 'sudo tailscale up' from the console."
  fi
else
  log
  log "Authenticate this machine into your private Tailscale network."
  log "This is the only intended remote ingress path."
  log
  if tailscale up --ssh=false; then
    ok "Tailscale logged in."
    TS_STATUS_OK=1
  else
    warn "Tailscale login did not complete. Run 'sudo tailscale up' from the console after install."
  fi
fi

# ---------------------------------------------------------------------------
# First-run status summary
# ---------------------------------------------------------------------------

section "First-run status"

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

if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
  bullet "1" "Tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)"
else
  bullet "${TS_STATUS_OK}" "Tailscale logged in"
fi
bullet "${PROVIDER_OK}"  "Provider token present in secrets/env"
bullet "${CHAT_OK}"      "Chat service running on 127.0.0.1:${CHAT_PORT}"
echo

NEXT_STEP=""
if [[ "${ZOMBIE_SKIP_TAILSCALE}" != "1" && "${TS_STATUS_OK}" != "1" ]]; then
  NEXT_STEP="sudo tailscale up"
elif [[ "${PROVIDER_OK}" != "1" ]]; then
  NEXT_STEP="sudo ${ZOMBIE_DIR}/bin/secrets-edit   # paste any of OPENAI/ANTHROPIC/GEMINI/XAI/OPENROUTER/MISTRAL/GROQ _API_KEY"
elif [[ "${CHAT_OK}" != "1" ]]; then
  NEXT_STEP="sudo systemctl start ubuntu-zombie-chat.service"
else
  if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
    NEXT_STEP="open http://127.0.0.1:${CHAT_PORT}/  (or tunnel: ssh -L ${CHAT_PORT}:127.0.0.1:${CHAT_PORT} ${AGENT_USER}@<host>)"
  else
    NEXT_STEP="open http://127.0.0.1:${CHAT_PORT}/  (or tunnel: ssh -L ${CHAT_PORT}:127.0.0.1:${CHAT_PORT} ${AGENT_USER}@<tailscale-name>)"
  fi
fi

ufw status verbose || true

cat <<EOF

${C_GREEN}${C_BOLD}Install complete.${C_RESET}

Next obvious step:
  ${C_BOLD}${NEXT_STEP}${C_RESET}

Then:

  1. Reboot:
       sudo reboot

  2. After reboot, from any device on your Tailscale network:
       ssh ${AGENT_USER}@<tailscale-name-or-ip>
       ${ZOMBIE_DIR}/bin/verify
       ${ZOMBIE_DIR}/bin/health-check

  3. Add cloud LLM keys (if not done already):
       sudo ${ZOMBIE_DIR}/bin/secrets-edit

  4. Open the chat UI:
       ssh -L ${CHAT_PORT}:127.0.0.1:${CHAT_PORT} ${AGENT_USER}@<tailscale-name-or-ip>
       # open http://127.0.0.1:${CHAT_PORT}/ locally

  5. Emergency desktop (still private):
       ssh -L ${VNC_PORT}:localhost:${VNC_PORT} ${AGENT_USER}@<tailscale-name-or-ip>
       # then point a VNC viewer at localhost:${VNC_PORT}

  6. Inspect what the AI has done:
       ${ZOMBIE_DIR}/bin/audit-recent

Surfaces installed:
  - Terminal: SSH + sudo + tmux
  - OS:       apt + systemctl + logs + files + Docker
  - GUI:      Xorg + xdotool + screenshot + x11vnc (loopback)
  - Browser:  Playwright + Chromium
  - Chat:     loopback HTTP on ${CHAT_PORT}, policy + audit
  - Network:  $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "SSH on every interface (Tailscale skipped)" || echo "Tailscale-only inbound")

Public exposure:
  - SSH:           $([[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]] && echo "every interface (Tailscale skipped)" || echo "Tailscale interface only")
  - VNC:           localhost only
  - Chat:          localhost only
  - Password SSH:  disabled
  - Root SSH:      disabled
  - UFW default:   deny inbound

Install transcript: ${LOG_FILE}
Audit log:          ${ZOMBIE_LOG_DIR}/audit.log
Policy:             ${ZOMBIE_ETC}/policy.yaml
Uninstall:          sudo ${SCRIPT_DIR}/uninstall.sh --dry-run
EOF

if [[ "${ZOMBIE_SKIP_TAILSCALE}" != "1" && "${TS_STATUS_OK}" != "1" ]]; then
  warn "Tailscale is not logged in yet. Run 'sudo tailscale up' before rebooting."
fi

echo
echo "A reboot is required: sudo reboot"

if [[ -n "${INSTALL_T0:-}" ]]; then
  ok "Install took $(fmt_duration "$(( $(date +%s) - INSTALL_T0 ))")."
fi

if (( STEPS_SATISFIED + STEPS_CHANGED > 0 )); then
  info "Idempotent steps: ${STEPS_SATISFIED} already satisfied, ${STEPS_CHANGED} applied this run."
fi
