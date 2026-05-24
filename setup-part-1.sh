#!/usr/bin/env bash
#
# ai-full-control-ubuntu.sh
# -------------------------
# Turn a fresh Ubuntu Desktop into an AI-controllable workstation.
#
# This is the minimum recommended install for non-expert Ubuntu users
# who want an AI assistant to be able to operate the machine end-to-end:
# terminal, OS, files, Docker, GUI applications, and the browser.
# Inbound access is restricted to a private Tailscale network. The
# public internet cannot reach this host.
#
# Read README.md in this directory before running.
#
# Usage:
#   chmod +x ai-full-control-ubuntu.sh
#   sudo ./ai-full-control-ubuntu.sh
#
# Non-interactive use:
#   sudo AFC_NONINTERACTIVE=1 \
#        SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host" \
#        VNC_PASSWORD="..." \
#        TAILSCALE_AUTHKEY="tskey-auth-..." \
#        ./ai-full-control-ubuntu.sh
#
# Re-running is safe: the script is idempotent. Firewall, sudoers, SSH,
# Tailscale, and VNC state are added to or skipped, not reset.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="ai-full-control-ubuntu.sh"

AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="/home/${AGENT_USER}"
AFC_DIR="${AFC_DIR:-/opt/ai-full-control}"
VNC_PORT="${VNC_PORT:-5900}"
LOG_FILE="${LOG_FILE:-/var/log/ai-full-control-install.log}"

AFC_NONINTERACTIVE="${AFC_NONINTERACTIVE:-0}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

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
die()   { printf '%s[x]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

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
trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION}

Turn a fresh Ubuntu Desktop into an AI-controllable workstation,
reachable only over Tailscale.

Usage:
  sudo ./${SCRIPT_NAME} [--help] [--version]

Environment variables (all optional):
  AGENT_USER          Login name for the agent user (default: agent)
  AFC_DIR             Install root (default: /opt/ai-full-control)
  VNC_PORT            Loopback-only VNC port (default: 5900)
  LOG_FILE            Install transcript path (default: /var/log/ai-full-control-install.log)
  AFC_NONINTERACTIVE  Set to 1 to skip all prompts (then SSH_PUBLIC_KEY and VNC_PASSWORD must be set)
  SSH_PUBLIC_KEY      SSH public key string (an 'ssh-ed25519 ...' or 'ssh-rsa ...' line)
  VNC_PASSWORD        VNC password for loopback-only emergency desktop access
  TAILSCALE_AUTHKEY   Pre-auth key for unattended Tailscale enrolment

See README.md in this directory for the full guide.
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help)    usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
    *)            die "Unknown argument: ${arg} (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./${SCRIPT_NAME}"

# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  warn "This installer targets Ubuntu. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway."
fi

case "${VERSION_ID:-}" in
  22.04|24.04) : ;;
  "")          warn "Could not detect Ubuntu version." ;;
  *)           warn "Recommended versions are Ubuntu 22.04 LTS or 24.04 LTS. Detected: ${VERSION_ID}. Continuing." ;;
esac

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64|arm64) : ;;
  *)           warn "Architecture ${ARCH} is unusual. The Docker and Tailscale apt repos may not have packages for it." ;;
esac

if ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 \
   && ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  warn "No outbound connectivity detected. Package installation will fail."
fi

# ---------------------------------------------------------------------------
# Transcript logging
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

# Tee everything from here on into the log file as well.
exec > >(tee -a "${LOG_FILE}") 2>&1

section "${SCRIPT_NAME} ${SCRIPT_VERSION}"

info "Log file: ${LOG_FILE}"
info "Agent user: ${AGENT_USER}"
info "Install root: ${AFC_DIR}"
info "Mode: $([[ "${AFC_NONINTERACTIVE}" == "1" ]] && echo non-interactive || echo interactive)"

cat <<EOF

This installer will:
  - Create a full-control agent user with passwordless sudo
  - Enable SSH key-only access
  - Install Tailscale from its official apt repository
  - Allow inbound SSH only on the Tailscale interface
  - Force Xorg instead of Wayland, autologin the agent user
  - Enable loopback-only x11vnc for emergency desktop access
  - Install GUI automation tools (xdotool, scrot, gnome-screenshot)
  - Install Playwright with Chromium for browser automation
  - Install Docker CE from its official apt repository
  - Install Python and Node agent runtimes
  - Enable automatic security updates

Run this from the physical Ubuntu machine, not over public SSH.

EOF

if [[ "${AFC_NONINTERACTIVE}" != "1" ]]; then
  read -r -p "Continue? Type YES to proceed: " CONFIRM
  [[ "${CONFIRM}" == "YES" ]] || die "Cancelled."
else
  info "Non-interactive mode: proceeding without confirmation."
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

append_line_once() {
  local line="$1"
  local file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

is_ssh_pubkey() {
  # Accept the common OpenSSH public-key prefixes.
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\  ]]
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

section "System update"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  upgrade

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
  pwgen

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

section "Create agent user"

if id "${AGENT_USER}" >/dev/null 2>&1; then
  info "User ${AGENT_USER} already exists."
else
  adduser --gecos "" --disabled-password "${AGENT_USER}"
  ok "Created user ${AGENT_USER}."
fi

usermod -aG sudo "${AGENT_USER}"

SUDOERS_FILE="/etc/sudoers.d/90-${AGENT_USER}-full-control"
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
install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${AGENT_HOME}/.ssh/authorized_keys.tmp"
if [[ -f "${AGENT_HOME}/.ssh/authorized_keys" ]]; then
  cat "${AGENT_HOME}/.ssh/authorized_keys" > "${AGENT_HOME}/.ssh/authorized_keys.tmp"
fi
mv "${AGENT_HOME}/.ssh/authorized_keys.tmp" "${AGENT_HOME}/.ssh/authorized_keys"
chown "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.ssh/authorized_keys"
chmod 600 "${AGENT_HOME}/.ssh/authorized_keys"

EXISTING_KEYS="$(wc -l < "${AGENT_HOME}/.ssh/authorized_keys" 2>/dev/null || echo 0)"

if [[ -z "${SSH_PUBLIC_KEY}" && "${AFC_NONINTERACTIVE}" != "1" ]]; then
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
    die "That does not look like an SSH public key. Expected a line starting with 'ssh-ed25519 ', 'ssh-rsa ', etc."
  fi
  append_line_once "${SSH_PUBLIC_KEY}" "${AGENT_HOME}/.ssh/authorized_keys"
  ok "Authorized the supplied SSH key."
elif [[ "${EXISTING_KEYS}" -eq 0 && "${AFC_NONINTERACTIVE}" == "1" ]]; then
  die "Non-interactive mode requires SSH_PUBLIC_KEY when no key is already authorized."
fi

chown -R "${AGENT_USER}:${AGENT_USER}" "${AGENT_HOME}/.ssh"
chmod 700 "${AGENT_HOME}/.ssh"
chmod 600 "${AGENT_HOME}/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------

section "Harden SSH"

install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-ai-full-control.conf <<EOF
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

if ! command -v tailscale >/dev/null 2>&1; then
  install -d -m 755 /usr/share/keyrings
  TS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg
  cat > /etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${TS_CODENAME} main
EOF
  apt-get update
  apt_install tailscale
  ok "Tailscale installed from official apt repository."
else
  info "Tailscale already installed."
fi

systemctl enable --now tailscaled >/dev/null

# ---------------------------------------------------------------------------
# Firewall (idempotent)
# ---------------------------------------------------------------------------

section "Firewall (Tailscale-only inbound)"

ufw --force default deny incoming
ufw --force default allow outgoing

if ! ufw status | grep -q "tailscale0.*22/tcp"; then
  ufw allow in on tailscale0 to any port 22 proto tcp comment "SSH over Tailscale only"
fi

ufw --force enable >/dev/null
ok "UFW: deny inbound, allow outbound, SSH allowed only on tailscale0."

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
# Force Xorg, autologin, no sleep, no lock
# ---------------------------------------------------------------------------

section "Force Xorg and autologin"

install -d -m 755 /etc/gdm3
cat > /etc/gdm3/custom.conf <<EOF
# Managed by ${SCRIPT_NAME}.
[daemon]
WaylandEnable=false
AutomaticLoginEnable=true
AutomaticLogin=${AGENT_USER}

[security]

[xdmcp]

[chooser]

[debug]
EOF

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
# Workspace at /opt/ai-full-control
# ---------------------------------------------------------------------------

section "Create AI Full Control workspace"

install -d -m 755 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AFC_DIR}" \
  "${AFC_DIR}/bin" "${AFC_DIR}/logs" "${AFC_DIR}/state" \
  "${AFC_DIR}/scripts" "${AFC_DIR}/tools"
install -d -m 700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AFC_DIR}/secrets"

if [[ ! -f "${AFC_DIR}/secrets/env" ]]; then
  install -m 600 -o "${AGENT_USER}" -g "${AGENT_USER}" /dev/null "${AFC_DIR}/secrets/env"
  cat > "${AFC_DIR}/secrets/env" <<EOF
# Cloud LLM keys and runtime environment for the agent user.
# Example:
#   OPENAI_API_KEY=sk-...
#   ANTHROPIC_API_KEY=sk-ant-...

DISPLAY=:0
AFC_DIR=${AFC_DIR}
AGENT_USER=${AGENT_USER}
AGENT_HOME=${AGENT_HOME}
EOF
  chown "${AGENT_USER}:${AGENT_USER}" "${AFC_DIR}/secrets/env"
  chmod 600 "${AFC_DIR}/secrets/env"
  ok "Created ${AFC_DIR}/secrets/env (add your LLM keys with: sudoedit ${AFC_DIR}/secrets/env)."
else
  info "Preserving existing ${AFC_DIR}/secrets/env."
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
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  . /etc/os-release
  DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable
EOF
  apt-get update
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
pip install --upgrade pip wheel setuptools
pip install --upgrade \
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
python -m playwright install --with-deps chromium
'

ok "Python venv ready at ${AGENT_HOME}/agent-env."

# ---------------------------------------------------------------------------
# Node runtime
# ---------------------------------------------------------------------------

section "Node runtime"

npm install -g npm@latest
npm install -g yarn pnpm typescript ts-node

# ---------------------------------------------------------------------------
# GUI control helper scripts
# ---------------------------------------------------------------------------

section "GUI control helper scripts"

cat > "${AFC_DIR}/bin/gui-env" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -f ${AFC_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ${AFC_DIR}/secrets/env
  set +a
fi

export DISPLAY="\${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=\${XDG_RUNTIME_DIR}/bus}"

exec "\$@"
EOF

cat > "${AFC_DIR}/bin/screenshot" <<EOF
#!/usr/bin/env bash
set -euo pipefail
OUT="\${1:-${AFC_DIR}/state/screen.png}"
${AFC_DIR}/bin/gui-env gnome-screenshot -f "\$OUT"
echo "\$OUT"
EOF

cat > "${AFC_DIR}/bin/click" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -eq 2 ]] || { echo "Usage: click X Y" >&2; exit 2; }
${AFC_DIR}/bin/gui-env xdotool mousemove "\$1" "\$2" click 1
EOF

cat > "${AFC_DIR}/bin/type-text" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -ge 1 ]] || { echo "Usage: type-text 'text'" >&2; exit 2; }
${AFC_DIR}/bin/gui-env xdotool type --delay 10 "\$*"
EOF

cat > "${AFC_DIR}/bin/key" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$# -ge 1 ]] || { echo "Usage: key ctrl+l" >&2; exit 2; }
${AFC_DIR}/bin/gui-env xdotool key "\$@"
EOF

cat > "${AFC_DIR}/bin/agent-shell" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -f ${AFC_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ${AFC_DIR}/secrets/env
  set +a
fi

cd ${AFC_DIR}
exec tmux new -A -s ai-full-control
EOF

chmod +x "${AFC_DIR}/bin/"*
chown -R "${AGENT_USER}:${AGENT_USER}" "${AFC_DIR}"

# ---------------------------------------------------------------------------
# Browser automation smoke test
# ---------------------------------------------------------------------------

section "Browser automation smoke test"

cat > "${AFC_DIR}/tools/browser-test.py" <<'EOF'
"""Smoke test: drive Chromium through Playwright on the real Xorg desktop."""
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=False)
    page = browser.new_page()
    page.goto("https://example.com")
    print(page.title())
    browser.close()
EOF

chown "${AGENT_USER}:${AGENT_USER}" "${AFC_DIR}/tools/browser-test.py"

# ---------------------------------------------------------------------------
# x11vnc loopback only
# ---------------------------------------------------------------------------

section "x11vnc loopback-only desktop access"

runuser -l "${AGENT_USER}" -c "mkdir -p ~/.vnc ~/.config/autostart ~/.local/share"

VNC_PASSWD_FILE="${AGENT_HOME}/.vnc/passwd"

if [[ -f "${VNC_PASSWD_FILE}" ]]; then
  info "VNC password already set; keeping it."
elif [[ -n "${VNC_PASSWORD}" ]]; then
  runuser -l "${AGENT_USER}" -c "x11vnc -storepasswd '${VNC_PASSWORD}' ~/.vnc/passwd" >/dev/null
  ok "VNC password set from VNC_PASSWORD env var."
elif [[ "${AFC_NONINTERACTIVE}" == "1" ]]; then
  die "Non-interactive mode requires VNC_PASSWORD when no VNC password is already stored."
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
# Verification script (paths expanded at install time)
# ---------------------------------------------------------------------------

section "Install verification script"

cat > "${AFC_DIR}/bin/verify" <<EOF
#!/usr/bin/env bash
set -uo pipefail

AFC_DIR="${AFC_DIR}"
AGENT_USER="${AGENT_USER}"
AGENT_HOME="${AGENT_HOME}"

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

if [[ -f \${AFC_DIR}/secrets/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source \${AFC_DIR}/secrets/env
  set +a
fi

printf '\\n%s== ai-full-control verify ==%s\\n' "\${C_BOLD}" "\${C_RESET}"
echo

echo "User and sudo:"
check "running as \${AGENT_USER}"          test "\$(id -un)" = "\${AGENT_USER}"
check "passwordless sudo"                  sudo -n true
echo

echo "Network and services:"
check "ssh service active"                 systemctl is-active ssh
check "ufw active"                         bash -c "sudo ufw status | grep -q 'Status: active'"
check "tailscale binary present"           command -v tailscale
check "tailscale is logged in"             bash -c "tailscale status >/dev/null 2>&1 && ! tailscale status | grep -q 'Logged out'"
check "docker engine reachable"            docker version
echo

echo "Desktop and GUI control:"
check "Xorg session forced for \${AGENT_USER}"  bash -c "grep -q 'XSession=ubuntu-xorg' /var/lib/AccountsService/users/\${AGENT_USER}"
check "x11vnc autostart present"           test -f \${AGENT_HOME}/.config/autostart/x11vnc.desktop
check "DISPLAY is set"                     test -n "\${DISPLAY:-}"
check "xdotool reachable on \${DISPLAY:-:0}" \${AFC_DIR}/bin/gui-env xdotool getdisplaygeometry
echo

echo "Runtime:"
check "Python venv exists"                 test -x \${AGENT_HOME}/agent-env/bin/python
check "openai SDK importable"              \${AGENT_HOME}/agent-env/bin/python -c "import openai"
check "anthropic SDK importable"           \${AGENT_HOME}/agent-env/bin/python -c "import anthropic"
check "playwright importable"              \${AGENT_HOME}/agent-env/bin/python -c "from playwright.sync_api import sync_playwright"
check "node and tsc present"               bash -c "command -v node && command -v tsc"
echo

echo "Screenshot:"
SHOT="\${AFC_DIR}/state/screen.png"
if \${AFC_DIR}/bin/screenshot "\$SHOT" >/dev/null 2>&1 && [[ -s "\$SHOT" ]]; then
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
  exit 1
fi
EOF

chmod +x "${AFC_DIR}/bin/verify"
chown "${AGENT_USER}:${AGENT_USER}" "${AFC_DIR}/bin/verify"

# ---------------------------------------------------------------------------
# Tailscale enrolment
# ---------------------------------------------------------------------------

section "Tailscale authentication"

TS_STATUS_OK=0
if tailscale status >/dev/null 2>&1 && ! tailscale status 2>/dev/null | grep -q "Logged out"; then
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
# Final summary
# ---------------------------------------------------------------------------

section "Final state"

ufw status verbose || true

cat <<EOF

${C_GREEN}${C_BOLD}Install complete.${C_RESET}

Next steps:

  1. Reboot:
       sudo reboot

  2. After reboot, from any device on your Tailscale network:
       ssh ${AGENT_USER}@<tailscale-name-or-ip>
       ${AFC_DIR}/bin/verify

  3. Add cloud LLM keys (optional but expected):
       sudoedit ${AFC_DIR}/secrets/env

  4. Start a persistent agent shell:
       ${AFC_DIR}/bin/agent-shell

  5. Emergency desktop (still private):
       ssh -L ${VNC_PORT}:localhost:${VNC_PORT} ${AGENT_USER}@<tailscale-name-or-ip>
       # then point a VNC viewer at localhost:${VNC_PORT}

Surfaces installed:
  - Terminal: SSH + sudo + tmux
  - OS:       apt + systemctl + logs + files + Docker
  - GUI:      Xorg + xdotool + screenshot + x11vnc (loopback)
  - Browser:  Playwright + Chromium
  - Network:  Tailscale-only inbound

Public exposure:
  - SSH:           Tailscale interface only
  - VNC:           localhost only
  - Password SSH:  disabled
  - Root SSH:      disabled
  - UFW default:   deny inbound

Install transcript: ${LOG_FILE}
EOF

if [[ "${TS_STATUS_OK}" != "1" ]]; then
  warn "Tailscale is not logged in yet. Run 'sudo tailscale up' before rebooting."
fi

echo
echo "A reboot is required: sudo reboot"
