#!/usr/bin/env bash
#
# uninstall.sh
# ------------
# Reverse the Ubuntu Zombie installer.
#
# Removes the chat service, sudoers drop-in, SSH drop-in, x11vnc
# autostart, generated helpers, policy, logrotate rule, and (with
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
# This script intentionally does NOT remove Docker, Tailscale, Node,
# Python, or other base packages — those are normal Ubuntu software
# that other things may depend on.

set -Eeuo pipefail

AGENT_USER="${ZOMBIE_USER:-${AGENT_USER:-zombie}}"
AGENT_HOME="/home/${AGENT_USER}"
ZOMBIE_DIR="${ZOMBIE_DIR:-/opt/ai-zombie}"
VNC_PORT="${VNC_PORT:-5900}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups}"

DRY_RUN=0
ARCHIVE=0
ASSUME_YES=0
KEEP_AGENT=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YEL=""; C_CYAN=""
fi

info() { printf '%s[i]%s %s\n' "${C_CYAN}" "${C_RESET}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${C_YEL}"  "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
die()  { printf '%s[x]%s %s\n' "${C_RED}"  "${C_RESET}" "$*" >&2; exit 1; }

usage() {
  # Heredoc instead of `sed -n '2,30p' "$0"` so the help output cannot
  # drift into the executable preamble when the header comment grows or
  # shrinks. See FIX-1-08.
  cat <<'EOF'
uninstall.sh
------------
Reverse the Ubuntu Zombie installer.

Removes the chat service, sudoers drop-in, SSH drop-in, x11vnc
autostart, generated helpers, policy, logrotate rule, and (with
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

This script intentionally does NOT remove Docker, Tailscale, Node,
Python, or other base packages — those are normal Ubuntu software
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

is_valid_tcp_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( "$1" >= 1 && "$1" <= 65535 ))
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
  if ! is_valid_tcp_port "${VNC_PORT}"; then
    printf '%s[x]%s VNC_PORT must be an integer from 1 to 65535; got %q\n' \
      "${C_RED}" "${C_RESET}" "${VNC_PORT}" >&2
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
# 2. Remove systemd units, sudoers drop-in, SSH drop-in.
# -------------------------------------------------------------------
info "Removing systemd units, sudoers drop-in, SSH drop-in"
for unit in ubuntu-zombie-chat.service ubuntu-zombie-health.service ubuntu-zombie-health.timer; do
  run "rm -f /etc/systemd/system/${unit}"
done
run "systemctl daemon-reload"

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
  run "rm -f $f"
done
shopt -u nullglob
run "rm -f /etc/ssh/sshd_config.d/99-ubuntu-zombie.conf"
if [[ "${DRY_RUN}" != "1" ]]; then
  warn "Reloading sshd. PermitRootLogin, PasswordAuthentication, and AllowUsers"
  warn "now revert to the Ubuntu defaults; this host may be more open than before."
  systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

# -------------------------------------------------------------------
# 3. Remove x11vnc autostart and policy/logrotate.
# -------------------------------------------------------------------
info "Removing x11vnc autostart, policy, and logrotate rule"
run "rm -f ${AGENT_HOME}/.config/autostart/x11vnc.desktop"
run "rm -f /etc/logrotate.d/ubuntu-zombie"

# Optionally drop the firewall rule we added.
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "tailscale0.*22/tcp"; then
    run "ufw --force delete allow in on tailscale0 to any port 22 proto tcp 2>/dev/null || true"
  fi
  # Also remove the all-interface SSH rule that install.sh adds when
  # ZOMBIE_SKIP_TAILSCALE=1. Match by the stable comment so we never
  # delete an operator-managed 22/tcp rule. See FIX-2-03.
  while ufw status numbered 2>/dev/null | grep -F '# SSH (Tailscale skipped)' | grep -q '22/tcp'; do
    rule_num="$(ufw status numbered 2>/dev/null \
      | awk -F'[][]' '/# SSH \(Tailscale skipped\)/ && /22\/tcp/ {print $2; exit}')"
    [[ -z "${rule_num}" ]] && break
    run "yes | ufw delete ${rule_num} >/dev/null 2>&1 || true"
    # Guard against an infinite loop if the delete silently fails.
    if ufw status numbered 2>/dev/null \
        | awk -F'[][]' '/# SSH \(Tailscale skipped\)/ && /22\/tcp/ {print $2; exit}' \
        | grep -qx "${rule_num}"; then
      break
    fi
  done
fi

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
  # Create the tarballs with mode 0600 so SSH keys, the VNC password,
  # and any provider tokens are not world-readable when BACKUP_DIR itself
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
    run "rm -rf ${ZOMBIE_DIR}"
    ok "Removed ${ZOMBIE_DIR}"
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
        run "npm uninstall -g ${_pkg}"
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
      "${ZOMBIE_DIR}"/*) run "rm -f ${_path}" ;;
      "") # broken symlink; check the literal target instead.
        _literal="$(readlink "${_path}" 2>/dev/null || true)"
        case "${_literal}" in
          "${ZOMBIE_DIR}"/*) run "rm -f ${_path}" ;;
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
    run "rm -rf /etc/ubuntu-zombie"
  fi
fi

# -------------------------------------------------------------------
# 7. Remove the agent user (last, so its home is still owned).
# -------------------------------------------------------------------
UNINSTALL_EXIT=0

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

# -------------------------------------------------------------------
# 8. Force GDM out of auto-login so a removed user does not break boot.
# -------------------------------------------------------------------
if [[ -f /etc/gdm3/custom.conf ]]; then
  info "Disabling auto-login in /etc/gdm3/custom.conf"
  if [[ "${DRY_RUN}" != "1" ]]; then
    sed -i \
      -e 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/' \
      -e "s/^AutomaticLogin=.*/# AutomaticLogin=/" \
      /etc/gdm3/custom.conf || true
  else
    printf '%s[dry]%s sed -i ...AutomaticLoginEnable=false... /etc/gdm3/custom.conf\n' "${C_YEL}" "${C_RESET}"
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
  - Docker, Tailscale, Node, Python, Playwright, GNOME, x11vnc
    (these are normal Ubuntu packages; remove them with apt if you
    really want to).
  - /var/log/ubuntu-zombie/ and /var/log/ubuntu-zombie-install.log
    are retained for audit. Remove them with:
        sudo rm -rf /var/log/ubuntu-zombie /var/log/ubuntu-zombie-install.log

If you want to fully purge package state too:
  sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \\
       docker-buildx-plugin docker-compose-plugin tailscale x11vnc
EOF

exit "${UNINSTALL_EXIT}"
