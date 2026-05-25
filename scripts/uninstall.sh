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
  sed -n '2,30p' "$0"
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

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo $0"

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '%s[dry]%s %s\n' "${C_YEL}" "${C_RESET}" "$*"
  else
    # shellcheck disable=SC2294 # commands include shell metacharacters; eval is intentional.
    eval "$@"
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
run "rm -f /etc/ssh/sshd_config.d/99-ubuntu-zombie.conf"
if [[ "${DRY_RUN}" != "1" ]]; then
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
fi

# -------------------------------------------------------------------
# 4. Archive user data if requested.
# -------------------------------------------------------------------
STAMP="$(date -u +%Y%m%d-%H%M%S)"
if [[ "${ARCHIVE}" == "1" ]]; then
  info "Archiving ${AGENT_HOME} and ${ZOMBIE_DIR}/state to ${BACKUP_DIR}"
  run "install -d -m 700 ${BACKUP_DIR}"
  if [[ -d "${AGENT_HOME}" ]]; then
    run "tar -czf ${BACKUP_DIR}/ubuntu-zombie-home-${STAMP}.tar.gz -C / home/${AGENT_USER}"
  fi
  if [[ -d "${ZOMBIE_DIR}/state" ]]; then
    run "tar -czf ${BACKUP_DIR}/ubuntu-zombie-state-${STAMP}.tar.gz -C ${ZOMBIE_DIR} state"
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
if [[ "${KEEP_AGENT}" == "1" ]]; then
  info "Keeping user ${AGENT_USER} (--keep-agent)."
elif id "${AGENT_USER}" >/dev/null 2>&1; then
  if confirm "Remove the ${AGENT_USER} user and ${AGENT_HOME} ?"; then
    # Kill any session first so userdel does not refuse.
    run "loginctl terminate-user ${AGENT_USER} 2>/dev/null || true"
    run "pkill -KILL -u ${AGENT_USER} 2>/dev/null || true"
    sleep 1
    run "deluser --remove-home ${AGENT_USER} 2>/dev/null || userdel -r ${AGENT_USER} 2>/dev/null || true"
    ok "Removed user ${AGENT_USER}"
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
ok "Uninstall complete."
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
