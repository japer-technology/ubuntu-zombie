#!/usr/bin/env bash
#
# uninstall.sh
# ------------
# Reverse the Ubuntu Zombie installer.
#
# Removes the chat service, sudoers drop-in, generated helpers, policy,
# logrotate rule, and (with
# confirmation) the agent user account (default name `zombie`,
# overridable with ZOMBIE_USER). Optionally archives the account's
# home directory and /opt/ai-zombie/state/ to /var/backups/ before
# deletion.
#
# Usage:
#   sudo ./uninstall.sh            # interactive
#   sudo ./uninstall.sh --dry-run  # preview
#   sudo ./uninstall.sh --archive  # archive then remove
#   sudo ./uninstall.sh --yes      # skip confirmations
#   sudo ./uninstall.sh --keep-agent  # do not remove user
#
# Environment:
#   ZOMBIE_USER=<name>   override the account name (default `zombie`).
#                        `AGENT_USER` is still accepted as a legacy
#                        alias so older installs can still be reversed.
#
# This script intentionally does NOT remove Node, Python, or other base
# packages — those are normal Ubuntu software
# that other things may depend on.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib.sh
if [[ -r "${SCRIPT_DIR}/lib.sh" ]]; then
  . "${SCRIPT_DIR}/lib.sh"
else
  printf 'uninstall.sh: cannot find required library %s\n' "${SCRIPT_DIR}/lib.sh" >&2
  exit 1
fi

AGENT_USER="${ZOMBIE_USER:-${AGENT_USER:-zombie}}"
AGENT_HOME="/home/${AGENT_USER}"
ZOMBIE_DIR="${ZOMBIE_DIR:-/opt/ai-zombie}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups}"

DRY_RUN=0
ARCHIVE=0
ASSUME_YES=0
KEEP_AGENT=0
# Track recoverable failures from the start so early cleanup can continue
# through later steps while still returning a non-zero final status.
UNINSTALL_EXIT=0

# Shared colours/logging come from lib.sh. Keep the legacy C_YEL alias so the
# inline printf calls below (e.g. the [dry] glyph) need no churn.
lib_setup_colors
C_YEL="${C_YELLOW}"

usage() {
  # Heredoc instead of `sed -n '2,30p' "$0"` so the help output cannot
  # drift into the executable preamble when the header comment grows or
  # shrinks. See FIX-1-08.
  cat <<'EOF'
uninstall.sh
------------
Reverse the Ubuntu Zombie installer.

Removes the chat service, sudoers drop-in, generated helpers, policy,
logrotate rule, and (with
confirmation) the agent user account (default name `zombie`,
overridable with ZOMBIE_USER). Optionally archives the account's
home directory and /opt/ai-zombie/state/ to /var/backups/ before
deletion.

Usage:
  sudo ./uninstall.sh            # interactive
  sudo ./uninstall.sh --dry-run  # preview
  sudo ./uninstall.sh --archive  # archive then remove
  sudo ./uninstall.sh --yes      # skip confirmations
  sudo ./uninstall.sh --keep-agent  # do not remove user

Environment:
  ZOMBIE_USER=<name>   override the account name (default `zombie`).
                       `AGENT_USER` is still accepted as a legacy
                       alias so older installs can still be reversed.

This script intentionally does NOT remove Node, Python, or other base
packages — those are normal Ubuntu software
that other things may depend on.
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help)    usage; exit 0 ;;
    --dry-run)    DRY_RUN=1 ;;
    --archive)    ARCHIVE=1 ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --keep-agent) KEEP_AGENT=1 ;;
    *)            die "Unknown argument: ${arg} (try --help)" ;;
  esac
done

# Validate user-controlled inputs before they are interpolated into any
# command string handed to `run` (which eval's it). Mirrors
# install.sh::validate_config so the uninstaller has the same guarantees.
# Runs before the EUID check so smoke tests can assert exit-code 2 for
# obviously-bad ZOMBIE_USER values without needing root. See FIX-2-01.
is_supported_agent_username() {
  [[ "$1" =~ ^[a-z]([a-z0-9_-]{0,30}[a-z0-9]|[a-z0-9]{0,31})$ ]] || return 1
  [[ "$1" != "root" && "$1" != "nobody" ]]
}

is_safe_absolute_path() {
  [[ "$1" == /* ]] || return 1
  [[ "$1" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
}

validate_config() {
  if ! is_supported_agent_username "${AGENT_USER}"; then
    printf '%s[x]%s Invalid agent username %q. Use a non-reserved lowercase Linux username (letters first; then letters, digits, underscore, hyphen; max 32 chars; no trailing punctuation).\n' \
      "${C_RED}" "${C_RESET}" "${AGENT_USER}" >&2
    exit 2
  fi
  if ! is_safe_absolute_path "${ZOMBIE_DIR}"; then
    printf '%s[x]%s ZOMBIE_DIR must be an absolute path using only safe path characters; got %q\n' \
      "${C_RED}" "${C_RESET}" "${ZOMBIE_DIR}" >&2
    exit 2
  fi
  if ! is_safe_absolute_path "${BACKUP_DIR}"; then
    printf '%s[x]%s BACKUP_DIR must be an absolute path using only safe path characters; got %q\n' \
      "${C_RED}" "${C_RESET}" "${BACKUP_DIR}" >&2
    exit 2
  fi
}
validate_config

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo $0"

run() {
  # Defensive guard: callers must pass exactly one composed command string,
  # not argv-style arguments (which would be silently dropped under
  # `eval "$1"`). See FIX-2-11.
  if (( $# != 1 )); then
    printf '%s[x]%s run() takes exactly one composed command string; got %d args: %s\n' \
      "${C_RED}" "${C_RESET}" "$#" "$*" >&2
    exit 1
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '%s[dry]%s %s\n' "${C_YEL}" "${C_RESET}" "$1"
  else
    # Callers pass a single string with shell metacharacters (redirections,
    # `||`, globbing). Re-evaluate that one string so the quoting survives.
    # See FIX-1-06.
    # shellcheck disable=SC2294 # eval on a single composed command string is intentional.
    eval "$1"
  fi
}

shell_quote() {
  # Quote a single token before embedding it in any composed command string
  # that will be evaluated. Bash printf %q uses backslash-style escaping,
  # which keeps dry-run output readable while preserving safety.
  printf '%q' "$1"
}

run_or_warn() {
  # Run a non-critical cleanup command. Failures are reported in the final
  # exit code, but they must not stop later uninstall steps from running.
  local description="$1"
  local command="$2"
  if [[ "${DRY_RUN}" == "1" ]]; then
    run "${command}"
    return 0
  fi
  set +e
  # shellcheck disable=SC2294 # Re-evaluate shell_quote output in the composed command string.
  eval "${command}"
  local rc=$?
  set -e
  if (( rc != 0 )); then
    warn "${description} failed (exit ${rc}); continuing cleanup."
    UNINSTALL_EXIT=1
  fi
  return 0
}

remove_tree_checked() {
  # Remove a directory tree and verify it is actually gone before reporting
  # success; stubborn paths are errors, but cleanup should still continue.
  local path="$1"
  local label="$2"
  local quoted
  quoted="$(shell_quote "${path}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    run "rm -rf -- ${quoted}"
    ok "Would remove ${label}"
    return 0
  fi
  set +e
  rm -rf -- "${path}"
  local rc=$?
  set -e
  if (( rc != 0 )); then
    warn "Failed to remove ${label} (exit ${rc}); continuing cleanup."
    UNINSTALL_EXIT=1
    return 0
  fi
  if [[ -e "${path}" ]]; then
    warn "Failed to remove ${label}; path still exists: ${path}"
    UNINSTALL_EXIT=1
    return 0
  fi
  ok "Removed ${label}"
  return 0
}

confirm() {
  local prompt="$1"
  [[ "${ASSUME_YES}" == "1" ]] && return 0
  read -r -p "${prompt} Type YES to proceed: " ans
  [[ "${ans}" == "YES" ]]
}

printf '%s== ubuntu-zombie uninstall ==%s\n\n' "${C_BOLD}" "${C_RESET}"
[[ "${DRY_RUN}" == "1" ]] && warn "Dry-run mode: nothing will be changed."

# -------------------------------------------------------------------
# 1. Stop and disable the chat service + health timer.
# -------------------------------------------------------------------
info "Stopping ubuntu-zombie services"
run "systemctl disable --now ubuntu-zombie-health.timer 2>/dev/null || true"
run "systemctl disable --now ubuntu-zombie-health.service 2>/dev/null || true"
run "systemctl disable --now ubuntu-zombie-chat.service   2>/dev/null || true"

# -------------------------------------------------------------------
# 2. Remove systemd units and sudoers drop-ins.
# -------------------------------------------------------------------
info "Removing systemd units and sudoers drop-ins"
for unit in ubuntu-zombie-chat.service ubuntu-zombie-health.service ubuntu-zombie-health.timer; do
  run "rm -f /etc/systemd/system/${unit}"
done
run_or_warn "systemctl daemon-reload" "systemctl daemon-reload"

run "rm -f /etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie"
# Also remove drop-ins from any previous install that used a different
# ZOMBIE_USER, so a stale NOPASSWD:ALL entry cannot be left behind.
# See FIX-2-04. The shell does the glob expansion locally; the only
# metacharacters in $f come from the kernel's directory listing, and
# FIX-2-01 guarantees AGENT_USER is safe so we cannot accidentally
# delete the current-account drop-in twice via an odd glob expansion.
shopt -s nullglob
for f in /etc/sudoers.d/90-*-ubuntu-zombie; do
  case "$f" in
    /etc/sudoers.d/90-"${AGENT_USER}"-ubuntu-zombie) continue ;;
  esac
  orphan_name="${f#/etc/sudoers.d/90-}"
  orphan_name="${orphan_name%-ubuntu-zombie}"
  warn "Removing orphaned sudoers drop-in for user '${orphan_name}': ${f}"
  if id "${orphan_name}" >/dev/null 2>&1; then
    warn "  account '${orphan_name}' still exists; remove it manually if no longer wanted."
  fi
  run "rm -f -- $(shell_quote "${f}")"
done
shopt -u nullglob

# -------------------------------------------------------------------
# 3. Remove policy/logrotate and legacy desktop artefacts.
# -------------------------------------------------------------------
info "Removing policy, logrotate rule, and legacy desktop artefacts"
run "rm -f /etc/logrotate.d/ubuntu-zombie"

# -------------------------------------------------------------------
# 4. Archive user data if requested.
# -------------------------------------------------------------------
STAMP="$(date -u +%Y%m%d-%H%M%S)"
if [[ "${ARCHIVE}" == "1" ]]; then
  info "Archiving ${AGENT_HOME} and ${ZOMBIE_DIR}/state to ${BACKUP_DIR}"
  # Only assert mode when creating the directory new; otherwise leave the
  # existing mode/ownership alone (e.g. /var/backups must stay 0755 so dpkg,
  # cracklib, and audit collectors keep working). See FIX-1-04.
  if [[ ! -d "${BACKUP_DIR}" ]]; then
    run "install -d -m 700 ${BACKUP_DIR}"
  fi
  # Create the tarballs with mode 0600 so provider tokens and other
  # secrets are not world-readable when BACKUP_DIR itself
  # is 0755 (the Ubuntu default for /var/backups). See FIX-2-02.
  if [[ -d "${AGENT_HOME}" ]]; then
    run "(umask 077 && tar -czf ${BACKUP_DIR}/ubuntu-zombie-home-${STAMP}.tar.gz -C / home/${AGENT_USER})"
  fi
  if [[ -d "${ZOMBIE_DIR}/state" ]]; then
    run "(umask 077 && tar -czf ${BACKUP_DIR}/ubuntu-zombie-state-${STAMP}.tar.gz -C ${ZOMBIE_DIR} state)"
  fi
fi

# -------------------------------------------------------------------
# 5. Remove /opt/ai-zombie (state/secrets only with confirmation).
# -------------------------------------------------------------------
if [[ -d "${ZOMBIE_DIR}" ]]; then
  if confirm "Remove ${ZOMBIE_DIR} (includes secrets, state, and chat history)?"; then
    remove_tree_checked "${ZOMBIE_DIR}" "${ZOMBIE_DIR}"
  else
    warn "Keeping ${ZOMBIE_DIR}. Privileged code under it is still on disk."
  fi
fi

# -------------------------------------------------------------------
# 5b. Remove globally-installed npm packages we own.
# -------------------------------------------------------------------
# The installer pulls @earendil-works/pi-ai and
# @earendil-works/pi-coding-agent via ``npm install -g``.
# ``rm -rf /opt/ai-zombie`` removes our source tree but leaves the
# Node packages installed system-wide. Uninstall them explicitly so
# the host is left clean.
if command -v npm >/dev/null 2>&1; then
  for _pkg in @earendil-works/pi-coding-agent @earendil-works/pi-ai; do
    if npm ls -g --depth=0 "${_pkg}" >/dev/null 2>&1; then
      if confirm "Remove global npm package ${_pkg}?"; then
        run_or_warn "Remove global npm package ${_pkg}" \
          "npm uninstall -g $(shell_quote "${_pkg}")"
      fi
    fi
  done
fi

# -------------------------------------------------------------------
# 5c. Remove /usr/local/bin symlinks installed by install.sh.
# -------------------------------------------------------------------
# install.sh adds these as `ln -sf ${ZOMBIE_DIR}/bin/...` shims so the
# CLI is on PATH for the operator. Without explicit cleanup they become
# dangling symlinks after step 5 removes ${ZOMBIE_DIR}. Only remove a
# link if it is a symlink whose target lives under ${ZOMBIE_DIR}, so we
# never delete an operator-owned binary of the same name.
info "Removing /usr/local/bin shims that point into ${ZOMBIE_DIR}"
for _shim in zombie-chat audit-recent secrets-edit zombie-health zombie-diagnostics zombie-verify; do
  _path="/usr/local/bin/${_shim}"
  if [[ -L "${_path}" ]]; then
    _target="$(readlink -f "${_path}" 2>/dev/null || true)"
    case "${_target}" in
      "${ZOMBIE_DIR}"/*) run "rm -f -- $(shell_quote "${_path}")" ;;
      "") # broken symlink; check the literal target instead.
        _literal="$(readlink "${_path}" 2>/dev/null || true)"
        case "${_literal}" in
          "${ZOMBIE_DIR}"/*) run "rm -f -- $(shell_quote "${_path}")" ;;
        esac
        ;;
    esac
  fi
done

# -------------------------------------------------------------------
# 6. Remove /etc/ubuntu-zombie policy config.
# -------------------------------------------------------------------
if [[ -d /etc/ubuntu-zombie ]]; then
  if confirm "Remove /etc/ubuntu-zombie (policy.yaml)?"; then
    remove_tree_checked "/etc/ubuntu-zombie" "/etc/ubuntu-zombie"
  fi
fi

# -------------------------------------------------------------------
# 7. Remove the agent user (last, so its home is still owned).
# -------------------------------------------------------------------
if [[ "${KEEP_AGENT}" == "1" ]]; then
  info "Keeping user ${AGENT_USER} (--keep-agent)."
elif id "${AGENT_USER}" >/dev/null 2>&1; then
  if confirm "Remove the ${AGENT_USER} user and ${AGENT_HOME} ?"; then
    # Kill any session first so userdel does not refuse.
    run "loginctl terminate-user ${AGENT_USER} 2>/dev/null || true"
    run "pkill -KILL -u ${AGENT_USER} 2>/dev/null || true"
    sleep 1
    # FIX-2-05: do not swallow removal failures. Capture the rc and verify
    # the account is actually gone before printing the success line.
    if [[ "${DRY_RUN}" == "1" ]]; then
      run "deluser --remove-home ${AGENT_USER} 2>/dev/null || userdel -r ${AGENT_USER}"
      ok "Would remove user ${AGENT_USER}"
    else
      set +e
      deluser --remove-home "${AGENT_USER}" >/dev/null 2>&1
      rc=$?
      if (( rc != 0 )); then
        userdel -r "${AGENT_USER}" >/dev/null 2>&1
        rc=$?
      fi
      set -e
      if (( rc == 0 )) && ! id "${AGENT_USER}" >/dev/null 2>&1; then
        ok "Removed user ${AGENT_USER}"
        # FIX-2-12: drop the now-orphaned primary group so a future
        # `adduser` of the same name does not pick up unexpected file
        # ownership. --only-if-empty makes this safe.
        if getent group "${AGENT_USER}" >/dev/null 2>&1; then
          run "delgroup --only-if-empty ${AGENT_USER} >/dev/null 2>&1 || true"
        fi
        # install.sh writes /var/lib/AccountsService/users/${AGENT_USER}
        # to pin the XSession to ubuntu-xorg; userdel does not clean it
        # up, leaving a stale AccountsService entry referencing a missing
        # account. Remove it once the user is actually gone.
        if [[ -f "/var/lib/AccountsService/users/${AGENT_USER}" ]]; then
          run "rm -f /var/lib/AccountsService/users/${AGENT_USER}"
        fi
      else
        warn "Failed to remove user ${AGENT_USER}; see 'who', 'loginctl list-sessions',"
        warn "  'lsof +D ${AGENT_HOME}' and re-run after the processes are gone."
        UNINSTALL_EXIT=1
      fi
    fi
  else
    warn "Keeping user ${AGENT_USER}. Its home and authorized_keys remain."
  fi
fi

echo
if (( UNINSTALL_EXIT != 0 )); then
  warn "Uninstall finished with errors (exit ${UNINSTALL_EXIT})."
else
  ok "Uninstall complete."
fi
cat <<EOF

Left intact on purpose:
  - Node, Python, and other shared runtime packages
    (remove them with apt only if you know nothing else needs them).
  - /var/log/ubuntu-zombie/ and /var/log/ubuntu-zombie-install.log
    are retained for audit. Remove them with:
        sudo rm -rf /var/log/ubuntu-zombie /var/log/ubuntu-zombie-install.log
EOF

exit "${UNINSTALL_EXIT}"
