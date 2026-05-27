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
# Read README.md and docs/QUICKSTART.md before running.
#
# Subcommands:
#   install     Full install (default). Idempotent.
#   verify      Read-only state check (no mutation).
#   doctor      Explain what is wrong and likely fixes.
#   repair      Apply known-safe fixes for common drift.
#   uninstall   Delegate to uninstall.sh.
#
# Common env vars (see docs/CONFIGURATION.md for the full list):
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
#                               When set, inbound SSH is allowed on every
#                               interface instead of being restricted to
#                               tailscale0. A Tailscale account is then
#                               not required.
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host"
#   VNC_PASSWORD="..."
#   TAILSCALE_AUTHKEY="tskey-auth-..."  (ignored when ZOMBIE_SKIP_TAILSCALE=1)

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
ZOMBIE_SKIP_TAILSCALE="${ZOMBIE_SKIP_TAILSCALE:-0}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

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

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s[i]%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
warn()  { printf '%s[!]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
ok()    { printf '%s[+]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
die()   { printf '%s[x]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit "${2:-1}"; }

section() {
  printf '\n%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
  printf '%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
  printf '%s============================================================%s\n' "${C_BOLD}" "${C_RESET}"
}

on_error() {
  local exit_code=$?
  local line=$1
  printf '\n%s[x] %s failed on line %s with exit code %s.%s\n' \
    "${C_RED}" "${SCRIPT_NAME}" "${line}" "${exit_code}" "${C_RESET}" >&2
  printf '%s    Full transcript: %s%s\n' "${C_RED}" "${LOG_FILE}" "${C_RESET}" >&2
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
  sudo ./${SCRIPT_NAME} [SUBCOMMAND] [--help] [--version]

Subcommands:
  install     Full install (default). Idempotent.
  verify      Read-only state check. Does not change state.
  doctor      Explain failures and likely fixes.
  repair      Apply known-safe fixes (re-assert permissions, retry
              Tailscale login, restart the chat service).
  uninstall   Reverse the install (delegates to uninstall.sh).

Environment variables (selected; see CONFIGURATION.md for all):
  ZOMBIE_NONINTERACTIVE=1     skip prompts (then SSH_PUBLIC_KEY and
                              VNC_PASSWORD must be set unless already
                              configured on disk).
  ZOMBIE_USER=<name>          name of the local agent account (default
                              'zombie'). Must be set on every later
                              install/verify/doctor/repair/uninstall
                              run that targets a non-default account.
  ZOMBIE_ENABLE_AUTOLOGIN=1   enable graphical autologin (off by default).
  ZOMBIE_SKIP_TAILSCALE=1     skip installing/enrolling Tailscale. Inbound
                              SSH is then allowed on every interface
                              rather than only on tailscale0.
  SSH_PUBLIC_KEY              SSH public key string.
  VNC_PASSWORD                Loopback-only VNC password.
  TAILSCALE_AUTHKEY           Pre-auth key for unattended Tailscale
                              (ignored when ZOMBIE_SKIP_TAILSCALE=1).

See README.md, QUICKSTART.md, and SECURITY.md.
EOF
}

SUBCOMMAND="install"
PARSED_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
    install|verify|doctor|repair|uninstall)
                  SUBCOMMAND="$1"; shift ;;
    --) shift; PARSED_ARGS+=("$@"); break ;;
    -*) die "Unknown flag: $1 (try --help)" 2 ;;
    *)  PARSED_ARGS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers shared across subcommands
# ---------------------------------------------------------------------------

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./${SCRIPT_NAME} ${SUBCOMMAND}" 2
}

# Retry with exponential backoff. Usage: retry <attempts> <sleep_base> -- cmd args...
retry() {
  local attempts="$1"; shift
  local base="$1"; shift
  [[ "$1" == "--" ]] && shift
  local n=1 delay="${base}"
  while true; do
    if "$@"; then
      return 0
    fi
    if (( n >= attempts )); then
      warn "Command failed after ${n} attempts: $*"
      return 1
    fi
    warn "Attempt ${n} failed, retrying in ${delay}s: $*"
    sleep "${delay}"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

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

apt_get() {
  wait_for_apt_lock || true
  retry 4 5 -- env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
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
    return 0
  fi
  # Ensure the file ends with a newline before appending, so we don't
  # concatenate the new line onto whatever was on the final partial line.
  if [[ -s "$file" ]] && [[ "$(tail -c1 "$file" 2>/dev/null)" != $'\n' ]]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$line" >> "$file"
}

is_ssh_pubkey() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\  ]]
}

is_supported_agent_username() {
  # Either 2-32 chars starting with a letter and ending alphanumeric, with
  # underscore/hyphen allowed in the middle, or 1-32 alphanumeric chars.
  [[ "$1" =~ ^[a-z]([a-z0-9_-]{0,30}[a-z0-9]|[a-z0-9]{0,31})$ ]] || return 1
  [[ "$1" != "root" && "$1" != "nobody" ]]
}

# Validate user-controlled install settings before they are interpolated into
# paths, sudoers entries, generated unit files, or shell commands.
validate_config() {
  if ! is_supported_agent_username "${AGENT_USER}"; then
    die "Invalid agent username '${AGENT_USER}'. Use a non-reserved lowercase Linux username (letters first; then letters, digits, underscore, hyphen; max 32 chars; no trailing punctuation)." 2
  fi
  if [[ "${ZOMBIE_DIR}" != /* ]]; then
    die "ZOMBIE_DIR must be an absolute path." 2
  fi
  if [[ "${LOG_FILE}" != /* ]]; then
    die "LOG_FILE must be an absolute path." 2
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
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && . /etc/os-release || true
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  load_os_release
  local errors=0 warnings=0

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Not Ubuntu. Detected: ${PRETTY_NAME:-unknown}. Unsupported."
    warnings=$((warnings + 1))
  fi
  case "${VERSION_ID:-}" in
    22.04|24.04) : ;;
    "")          warn "Could not detect Ubuntu version."; warnings=$((warnings + 1)) ;;
    *)           warn "Recommended versions: 22.04 LTS or 24.04 LTS. Detected: ${VERSION_ID}."
                 warnings=$((warnings + 1)) ;;
  esac

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "${arch}" in
    amd64|arm64) : ;;
    *) warn "Unusual architecture ${arch}; Docker/Tailscale apt repos may not match."
       warnings=$((warnings + 1)) ;;
  esac

  # Disk: need ~5 GB free under / for runtime + Chromium + Docker layers.
  local avail_kb
  avail_kb="$(df -P / | awk 'NR==2 {print $4}')"
  if [[ "${avail_kb:-0}" -lt 5000000 ]]; then
    warn "Less than 5 GB free under / ($((avail_kb/1024)) MB). Install may fail."
    warnings=$((warnings + 1))
  fi

  # Memory: 2 GB minimum recommended.
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem_kb:-0}" -lt 2000000 ]]; then
    warn "Less than 2 GB RAM ($((mem_kb/1024)) MB). Desktop + Chromium will be tight."
    warnings=$((warnings + 1))
  fi

  # DNS
  if ! getent hosts deb.debian.org >/dev/null 2>&1 \
     && ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    warn "DNS resolution looks broken (cannot resolve archive.ubuntu.com)."
    warnings=$((warnings + 1))
  fi

  # Outbound connectivity
  if ! curl_get -o /dev/null -m 8 https://archive.ubuntu.com/ >/dev/null 2>&1 \
     && ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 \
     && ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    warn "No outbound connectivity detected. Package installation will fail."
    if [[ "${SUBCOMMAND}" == "install" ]]; then
      errors=$((errors + 1))
    fi
  fi

  # apt/dpkg lock
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    info "apt/dpkg lock currently held; install will wait up to 5 minutes."
  fi

  # Public-SSH risk: are we connected over a non-Tailscale SSH session?
  if [[ -n "${SSH_CONNECTION:-}" && "${ZOMBIE_SKIP_TAILSCALE}" != "1" ]]; then
    local from_ip
    from_ip="$(awk '{print $1}' <<<"${SSH_CONNECTION}")"
    if ! ip -o addr show dev tailscale0 2>/dev/null | grep -q "${from_ip}"; then
      warn "Detected SSH session from ${from_ip} that is NOT on tailscale0."
      warn "Installer restarts sshd and tightens UFW; you risk locking yourself out."
      if [[ "${ZOMBIE_NONINTERACTIVE}" != "1" && "${SUBCOMMAND}" == "install" ]]; then
        warnings=$((warnings + 1))
      fi
    fi
  fi

  # Tailscale already present?
  if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
    warn "ZOMBIE_SKIP_TAILSCALE=1: Tailscale will be skipped. Inbound SSH will be"
    warn "  allowed on every interface instead of only on tailscale0. Only use"
    warn "  this on a network you control (e.g. behind a NAT/router or VPN)."
    warnings=$((warnings + 1))
  elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
      info "Tailscale is already installed and logged in."
    else
      info "Tailscale is installed but not logged in."
    fi
  fi

  # Display manager: warn if a non-GDM DM is active.
  if [[ -r /etc/X11/default-display-manager ]]; then
    local dm
    dm="$(tr -d '[:space:]' < /etc/X11/default-display-manager)"
    if [[ "${dm}" != *gdm* ]]; then
      warn "Active display manager is ${dm}, not GDM. The installer enables GDM autologin/Xorg via /etc/gdm3/."
      warnings=$((warnings + 1))
    fi
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

  local missing=()
  if [[ -z "${SSH_PUBLIC_KEY}" && ! -s "${AGENT_HOME}/.ssh/authorized_keys" ]]; then
    missing+=("SSH_PUBLIC_KEY")
  fi
  if [[ -z "${VNC_PASSWORD}" && ! -f "${AGENT_HOME}/.vnc/passwd" ]]; then
    missing+=("VNC_PASSWORD")
  fi
  if [[ -n "${SSH_PUBLIC_KEY}" ]] && ! is_ssh_pubkey "${SSH_PUBLIC_KEY}"; then
    die "SSH_PUBLIC_KEY does not look like an OpenSSH public key." 64
  fi
  if (( ${#missing[@]} > 0 )); then
    die "Non-interactive mode requires: ${missing[*]}" 64
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: verify
# ---------------------------------------------------------------------------

cmd_verify() {
  if [[ -x "${ZOMBIE_DIR}/bin/verify" ]]; then
    "${ZOMBIE_DIR}/bin/verify"
    return $?
  fi
  die "${ZOMBIE_DIR}/bin/verify not found. Run 'sudo ./${SCRIPT_NAME} install' first." 1
}

# ---------------------------------------------------------------------------
# Subcommand: doctor
# ---------------------------------------------------------------------------

cmd_doctor() {
  load_os_release
  printf '%s== ubuntu-zombie doctor ==%s\n\n' "${C_BOLD}" "${C_RESET}"

  printf '%sHost:%s %s %s on %s\n\n' "${C_BOLD}" "${C_RESET}" \
    "${ID:-?}" "${VERSION_ID:-?}" "$(dpkg --print-architecture 2>/dev/null || uname -m)"

  if id "${AGENT_USER}" >/dev/null 2>&1; then
    ok "User ${AGENT_USER} exists."
  else
    warn "User ${AGENT_USER} missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if [[ -f "/etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie" ]]; then
    ok "Sudoers drop-in present."
  else
    warn "Sudoers drop-in missing. Fix: sudo ./${SCRIPT_NAME} repair"
  fi

  if [[ -d "${ZOMBIE_DIR}" ]]; then
    ok "${ZOMBIE_DIR} present."
  else
    warn "${ZOMBIE_DIR} missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if [[ -f "${ZOMBIE_DIR}/secrets/env" ]]; then
    local perms
    perms="$(stat -c %a "${ZOMBIE_DIR}/secrets/env" 2>/dev/null || echo ???)"
    if [[ "${perms}" == "600" ]]; then
      ok "secrets/env permissions 600."
    else
      warn "secrets/env permissions ${perms} (must be 600). Fix: sudo ./${SCRIPT_NAME} repair"
    fi
    if grep -Eq '^(OPENAI|ANTHROPIC)_API_KEY=..+' "${ZOMBIE_DIR}/secrets/env" 2>/dev/null; then
      ok "Provider token present."
    else
      warn "No provider token. Fix: sudo ${ZOMBIE_DIR}/bin/secrets-edit"
    fi
  else
    warn "secrets/env missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if systemctl list-unit-files ubuntu-zombie-chat.service >/dev/null 2>&1; then
    if systemctl is-active --quiet ubuntu-zombie-chat.service; then
      ok "Chat service active."
    else
      warn "Chat service installed but not running. Fix: sudo systemctl start ubuntu-zombie-chat"
    fi
  else
    warn "Chat service unit missing. Fix: sudo ./${SCRIPT_NAME} install"
  fi

  if [[ "${ZOMBIE_SKIP_TAILSCALE}" == "1" ]]; then
    info "Tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)."
  elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
      ok "Tailscale logged in."
    else
      warn "Tailscale logged out. Fix: sudo tailscale up"
    fi
  else
    warn "Tailscale missing. Fix: sudo ./${SCRIPT_NAME} install (or set ZOMBIE_SKIP_TAILSCALE=1)"
  fi

  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "UFW active."
  else
    warn "UFW not active. Fix: sudo ./${SCRIPT_NAME} repair"
  fi

  if [[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]]; then
    if grep -q "AutomaticLoginEnable=true" /etc/gdm3/custom.conf 2>/dev/null; then
      ok "Autologin enabled (ZOMBIE_ENABLE_AUTOLOGIN=1)."
    else
      warn "Autologin requested but not configured. Fix: sudo ZOMBIE_ENABLE_AUTOLOGIN=1 ./${SCRIPT_NAME} install"
    fi
  fi

  echo
  info "For a runtime health summary: /opt/ai-zombie/bin/health-check"
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

section "${SCRIPT_NAME} ${SCRIPT_VERSION}  —  install"

info "Log file: ${LOG_FILE}"
info "Agent user: ${AGENT_USER}"
info "Install root: ${ZOMBIE_DIR}"
info "Chat port: ${CHAT_PORT} (loopback only)"
info "Autologin: $([[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]] && echo enabled || echo disabled)"
info "Mode: $([[ "${ZOMBIE_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"

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

if [[ "${ZOMBIE_NONINTERACTIVE}" != "1" ]]; then
  read -r -p "Continue? Type YES to proceed: " CONFIRM
  [[ "${CONFIRM}" == "YES" ]] || die "Cancelled." 0
else
  info "Non-interactive mode: proceeding without confirmation."
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
  nodejs \
  npm \
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
install -m 0440 /dev/null "${SUDOERS_FILE}"
cat > "${SUDOERS_FILE}" <<EOF
# Managed by ${SCRIPT_NAME}. Grants ${AGENT_USER} passwordless root.
${AGENT_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "${SUDOERS_FILE}"
visudo -cf "${SUDOERS_FILE}" >/dev/null
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

EXISTING_KEYS="$(awk 'END{print NR}' "${AGENT_HOME}/.ssh/authorized_keys" 2>/dev/null || echo 0)"

if [[ -z "${SSH_PUBLIC_KEY}" && "${ZOMBIE_NONINTERACTIVE}" != "1" ]]; then
  if [[ "${EXISTING_KEYS}" -gt 0 ]]; then
    info "${EXISTING_KEYS} SSH key(s) already authorized for ${AGENT_USER}."
    read -r -p "Add another public key? Leave blank to skip: " SSH_PUBLIC_KEY || true
  else
    log
    log "Paste the SSH public key that will be allowed to control this machine."
    log "Example: ssh-ed25519 AAAAC3... you@workstation"
    log "Leave blank only if you will add it manually after install."
    read -r -p "SSH public key: " SSH_PUBLIC_KEY || true
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
    TS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
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

  # Remove any prior all-interface SSH rule from a previous (skipped-Tailscale) run.
  while ufw status numbered | grep -E '(^|[[:space:]])22/tcp([[:space:]]|$)' | grep -vq 'tailscale0'; do
    rule_num="$(ufw status numbered | awk -F'[][]' '/22\/tcp/ && !/tailscale0/ {print $2; exit}')"
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
if [[ "${ZOMBIE_ENABLE_AUTOLOGIN}" == "1" ]]; then
  cat > /etc/gdm3/custom.conf <<EOF
# Managed by ${SCRIPT_NAME}. Autologin enabled by ZOMBIE_ENABLE_AUTOLOGIN=1.
[daemon]
WaylandEnable=false
AutomaticLoginEnable=true
AutomaticLogin=${AGENT_USER}

[security]

[xdmcp]

[chooser]

[debug]
EOF
  warn "Autologin is enabled. Any physical-access user gets an unlocked desktop as ${AGENT_USER}."
else
  cat > /etc/gdm3/custom.conf <<EOF
# Managed by ${SCRIPT_NAME}. Autologin OFF (default).
# Set ZOMBIE_ENABLE_AUTOLOGIN=1 to enable; read SECURITY.md first.
[daemon]
WaylandEnable=false
AutomaticLoginEnable=false

[security]

[xdmcp]

[chooser]

[debug]
EOF
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
# Pick ONE provider line and paste the key:
#   OPENAI_API_KEY=sk-...
#   ANTHROPIC_API_KEY=sk-ant-...
#
# Optional:
#   ZOMBIE_PROVIDER=openai      # or anthropic
#   ZOMBIE_MODEL=gpt-4o-mini    # override default model
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
  DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
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

runuser -l "${AGENT_USER}" -c '
set -euo pipefail
if [[ ! -d ~/agent-env ]]; then
  python3 -m venv ~/agent-env
fi
# shellcheck disable=SC1091
. ~/agent-env/bin/activate

pip_with_retry() {
  local n=1 delay=3
  while true; do
    if pip "$@"; then return 0; fi
    if (( n >= 4 )); then return 1; fi
    echo "pip retry ${n} in ${delay}s..."
    sleep "${delay}"; n=$((n + 1)); delay=$((delay * 2))
  done
}

pip_with_retry install --upgrade pip wheel setuptools
pip_with_retry install --upgrade \
  openai \
  anthropic \
  requests \
  pydantic \
  rich \
  typer \
  python-dotenv \
  playwright \
  pyautogui \
  pillow \
  mss \
  opencv-python \
  python-xlib
'

# Install Chromium system dependencies as root (apt-get requires it). The
# unprivileged playwright install below will then only fetch the browser
# binaries, which it can do as ${AGENT_USER}.
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

runuser -l "${AGENT_USER}" -c '
set -euo pipefail
# shellcheck disable=SC1091
. ~/agent-env/bin/activate

# Playwright browser downloads tend to flake on transient network.
n=1; delay=5
while true; do
  if python -m playwright install chromium; then break; fi
  if (( n >= 4 )); then
    echo "playwright install failed after ${n} attempts; rerun later."
    break
  fi
  echo "playwright retry ${n} in ${delay}s..."
  sleep "${delay}"; n=$((n + 1)); delay=$((delay * 2))
done
'

ok "Python venv ready at ${AGENT_HOME}/agent-env."

# ---------------------------------------------------------------------------
# Node runtime
# ---------------------------------------------------------------------------

section "Node runtime"

retry 4 5 -- npm install -g npm@latest
retry 4 5 -- npm install -g yarn pnpm typescript ts-node

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
for f in server.py providers.py policy.py audit.py runner.py history.py examples.md; do
  install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
    "${PAYLOAD_DIR}/agent/${f}" "${ZOMBIE_DIR}/agent/${f}"
done
install -m 644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${PAYLOAD_DIR}/agent/templates/index.html" "${ZOMBIE_DIR}/agent/templates/index.html"

# Operator helpers.
for f in audit-recent health-check collect-diagnostics secrets-edit zombie-chat; do
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

# logrotate.
install -m 644 "${PAYLOAD_DIR}/logrotate/ubuntu-zombie" /etc/logrotate.d/ubuntu-zombie

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
  runuser -l "${AGENT_USER}" -c "x11vnc -storepasswd"
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

if [[ -t 1 ]]; then
  C_RESET=\$'\\033[0m'; C_RED=\$'\\033[31m'; C_GREEN=\$'\\033[32m'; C_BOLD=\$'\\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_BOLD=""
fi

PASS=0; FAIL=0
check() {
  local label="\$1"; shift
  if "\$@" >/dev/null 2>&1; then
    printf '  %s[ok]%s %s\\n' "\${C_GREEN}" "\${C_RESET}" "\${label}"
    PASS=\$((PASS+1))
  else
    printf '  %s[--]%s %s\\n' "\${C_RED}" "\${C_RESET}" "\${label}"
    FAIL=\$((FAIL+1))
  fi
}

if [[ -f \${ZOMBIE_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source \${ZOMBIE_DIR}/secrets/env
  set +a
fi

printf '\\n%s== ubuntu-zombie verify ==%s\\n' "\${C_BOLD}" "\${C_RESET}"
echo

echo "User and sudo:"
check "running as \${AGENT_USER}"          test "\$(id -un)" = "\${AGENT_USER}"
check "passwordless sudo"                  sudo -n true
echo

echo "Network and services:"
check "ssh service active"                 systemctl is-active ssh
check "ufw active"                         bash -c "sudo ufw status | grep -q 'Status: active'"
if [[ "\${ZOMBIE_SKIP_TAILSCALE}" != "1" ]]; then
  check "tailscale binary present"           command -v tailscale
  check "tailscale is logged in"             bash -c "tailscale status >/dev/null 2>&1 && ! tailscale status | grep -q 'Logged out'"
else
  printf '  %s[--]%s tailscale skipped (ZOMBIE_SKIP_TAILSCALE=1)\\n' "\${C_BOLD}" "\${C_RESET}"
fi
check "docker engine reachable"            docker version
echo

echo "Desktop and GUI control:"
check "Xorg session forced for \${AGENT_USER}"  bash -c "grep -q 'XSession=ubuntu-xorg' /var/lib/AccountsService/users/\${AGENT_USER}"
check "x11vnc autostart present"           test -f \${AGENT_HOME}/.config/autostart/x11vnc.desktop
check "DISPLAY is set"                     test -n "\${DISPLAY:-}"
check "xdotool reachable on \${DISPLAY:-:0}" \${ZOMBIE_DIR}/bin/gui-env xdotool getdisplaygeometry
echo

echo "Runtime:"
check "Python venv exists"                 test -x \${AGENT_HOME}/agent-env/bin/python
check "openai SDK importable"              \${AGENT_HOME}/agent-env/bin/python -c "import openai"
check "anthropic SDK importable"           \${AGENT_HOME}/agent-env/bin/python -c "import anthropic"
check "playwright importable"              \${AGENT_HOME}/agent-env/bin/python -c "from playwright.sync_api import sync_playwright"
check "node and tsc present"               bash -c "command -v node && command -v tsc"
echo

echo "Chat service and policy:"
check "policy.yaml present"                test -r /etc/ubuntu-zombie/policy.yaml
check "audit log writable for ${AGENT_USER}"  bash -c "test -w /var/log/ubuntu-zombie/audit.log || sudo -n test -w /var/log/ubuntu-zombie/audit.log"
check "ubuntu-zombie-chat.service active"  systemctl is-active ubuntu-zombie-chat.service
check "chat listening on 127.0.0.1:${CHAT_PORT}" bash -c "ss -ltn 'sport = :${CHAT_PORT}' | grep -q 127.0.0.1"
check "agent server.py compiles"           \${AGENT_HOME}/agent-env/bin/python -m py_compile \${ZOMBIE_DIR}/agent/server.py
echo

echo "Screenshot:"
SHOT="\${ZOMBIE_DIR}/state/screen.png"
if \${ZOMBIE_DIR}/bin/screenshot "\$SHOT" >/dev/null 2>&1 && [[ -s "\$SHOT" ]]; then
  printf '  %s[ok]%s screenshot saved to %s\\n' "\${C_GREEN}" "\${C_RESET}" "\$SHOT"
  PASS=\$((PASS+1))
else
  printf '  %s[--]%s screenshot failed (desktop session may not be active yet)\\n' "\${C_RED}" "\${C_RESET}"
  FAIL=\$((FAIL+1))
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
if grep -Eq '^(OPENAI|ANTHROPIC)_API_KEY=..+' "${ZOMBIE_DIR}/secrets/env" 2>/dev/null; then
  PROVIDER_OK=1
fi

CHAT_OK=0
if systemctl is-active --quiet ubuntu-zombie-chat.service; then
  CHAT_OK=1
fi

bullet() {
  local ok="$1" label="$2"
  if [[ "${ok}" == "1" ]]; then
    printf '  %s[ok]%s %s\n' "${C_GREEN}" "${C_RESET}" "${label}"
  else
    printf '  %s[--]%s %s\n' "${C_YELLOW}" "${C_RESET}" "${label}"
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
  NEXT_STEP="sudo ${ZOMBIE_DIR}/bin/secrets-edit   # add OPENAI_API_KEY or ANTHROPIC_API_KEY"
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
