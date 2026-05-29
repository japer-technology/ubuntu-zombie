# Requirements

What Ubuntu Zombie needs in order to install and run. Everything on
this page is provisioned automatically by `scripts/install.sh`, with
the exception of the **operator-supplied** items in the first section
(SSH key, VNC password, LLM API key, and — only if you opt in to
Tailscale — a Tailscale account). This document is a reference so
operators and reviewers can see at a glance which external
repositories, packages, runtimes, and services the installer will pull
onto the machine.

If any item below changes, update this file in the same commit so it
stays a faithful inventory.

---

## 1. Operating system

- **Ubuntu Desktop LTS**, x86-64 or arm64.
  - **22.04 LTS** (`jammy`) — supported.
  - **24.04 LTS** (`noble`) — supported.
  - Other Ubuntu versions are rejected by the Tailscale and Docker
    apt-repo codename probe (`scripts/install.sh` around the
    `VERSION_ID` checks).
- Root access (the installer is run with `sudo`).
- A physical keyboard for the first interactive run, unless
  `ZOMBIE_NONINTERACTIVE=1` is set together with `SSH_PUBLIC_KEY`
  and `VNC_PASSWORD`.
- Outbound internet access to the apt mirrors, the third-party apt
  repositories below, PyPI, the npm registry, and the configured LLM
  provider endpoint.

## 2. Operator-supplied inputs

These are **not** installed by the script; the operator brings them.

- **SSH public key** for the `zombie` account (`ssh-ed25519 …`
  recommended). Provided interactively or via `SSH_PUBLIC_KEY=…`.
- **VNC password** for loopback-only `x11vnc`. Provided interactively
  or via `VNC_PASSWORD=…`.
- **One LLM provider API key** used by the chat service (which calls
  the provider through `@earendil-works/pi-ai` internally). Pick
  exactly one:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `GEMINI_API_KEY`
  - `XAI_API_KEY`
  - `OPENROUTER_API_KEY` (also requires `ZOMBIE_MODEL`)
  - `MISTRAL_API_KEY`
  - `GROQ_API_KEY`
- **Tailscale account** and (recommended) a pre-auth key
  (`TAILSCALE_AUTHKEY=…`) — **only if you opt in** to Tailscale with
  `ZOMBIE_SKIP_TAILSCALE=0`. Tailscale is off by default; with the
  default there is no tailnet trust boundary and SSH is reachable on
  every interface.

## 3. Third-party apt repositories

The installer enables these repositories with their official signing
keys under `/usr/share/keyrings` and `/etc/apt/keyrings`.

| Repository | Source | Used for |
| ---------- | ------ | -------- |
| Tailscale  | `https://pkgs.tailscale.com/stable/ubuntu` (`jammy`/`noble`) signed by `pkgs.tailscale.com/.../noarmor.gpg` | `tailscale`, `tailscaled` — **only when `ZOMBIE_SKIP_TAILSCALE=0`** |
| Docker CE  | `https://download.docker.com/linux/ubuntu` (`jammy`/`noble`) signed by `download.docker.com/linux/ubuntu/gpg` | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` |

The stock Ubuntu archive (`archive.ubuntu.com`) and the Ubuntu
`universe` component are also required for the base packages below.

## 4. apt packages

### 4.1 Base system packages

Installed in the "Base packages" section of `scripts/install.sh`:

`openssh-server`, `sudo`, `curl`, `wget`, `ca-certificates`, `gnupg`,
`lsb-release`, `software-properties-common`, `apt-transport-https`,
`git`, `vim`, `nano`, `tmux`, `htop`, `unzip`, `zip`, `jq`,
`net-tools`, `dnsutils`, `iputils-ping`, `ufw`, `fail2ban`,
`unattended-upgrades`, `logrotate`, `python3`, `python3-pip`,
`python3-venv`, `python3-tk`, `pipx`,
`build-essential`, `ripgrep`, `fd-find`, `tree`, `rsync`, `cron`,
`dbus-x11`, `dconf-cli`, `pwgen`, `psmisc`.

### 4.2 Desktop, Xorg, and GUI control packages

`ubuntu-desktop-minimal`, `gdm3`, `xorg`, `x11vnc`, `xdotool`,
`wmctrl`, `scrot`, `imagemagick`, `gnome-screenshot`, `xclip`,
`xsel`, `xterm`, `at-spi2-core`, `x11-utils`.

### 4.3 From the Tailscale apt repo

Installed **only when you opt in** with `ZOMBIE_SKIP_TAILSCALE=0`:

- `tailscale` (provides the `tailscaled` daemon)

### 4.4 From the Docker apt repo

- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-buildx-plugin`
- `docker-compose-plugin`

### 4.5 From the NodeSource apt repo

- `nodejs` — Node.js 22.x. Added via a `signed-by` keyring at
  `/usr/share/keyrings/nodesource.gpg` and a `deb822`-style sources
  file at `/etc/apt/sources.list.d/nodesource.sources` pointing at
  `https://deb.nodesource.com/node_22.x` (suite `nodistro`). The
  Ubuntu-archive `nodejs` (Node 18 on 22.04 / 24.04) is too old for
  `npm@latest`, which now requires Node `^20.17.0 || >=22.9.0`, so
  `install.sh` pins the `nodejs` package to the NodeSource origin via
  `/etc/apt/preferences.d/nodejs`.

### 4.6 Pulled implicitly by `playwright install-deps chromium`

The agent venv runs `playwright install-deps chromium` as root, which
shells out to `apt-get` and installs the Chromium system libraries
appropriate for the running Ubuntu release. Exact list is whatever
the Playwright version pinned in `setup-agent-venv` reports.

## 5. Python (agent virtualenv)

Created by `payload/bin/setup-agent-venv` at
`/home/<user>/agent-env` (where `<user>` is the `zombie` account,
renameable via `ZOMBIE_USER=<name>`), populated with
pinned-by-latest releases of:

- `pip`, `wheel`, `setuptools` (upgraded)
- `requests`
- `pydantic`
- `rich`
- `typer`
- `python-dotenv`
- `playwright` (plus the Chromium browser fetched via
  `python -m playwright install chromium`)
- `pyautogui`
- `pillow`
- `mss`
- `opencv-python`
- `python-xlib`

## 6. Node runtime and global npm packages

`install.sh` installs Node.js 22.x from the NodeSource apt repository
(see § 4.5) instead of the Ubuntu-archive `nodejs`/`npm` packages,
because the bundled npm on Ubuntu 22.04 / 24.04 cannot self-upgrade
to `npm@latest` (which requires Node `^20.17.0 || >=22.9.0`). With
Node 22 in place, `install.sh` upgrades npm itself and installs the
following globally:

- `npm@latest`
- `yarn`
- `pnpm`
- `typescript`
- `ts-node`
- `@earendil-works/pi-ai` — version pinned in
  `payload/agent/pi-ai.version`. Drives the chat service via
  `payload/agent/pi-ai-bridge.mjs`.
- `@earendil-works/pi-coding-agent` — version pinned in
  `payload/agent/pi-mono.version`. Drives the agent loop via
  `payload/agent/pi-mono-bridge.mjs`.

## 7. Systemd units and helpers deployed under `/opt/ai-zombie`

Provided by this repository's `payload/` tree and installed by
`scripts/install.sh`:

- `ubuntu-zombie-chat.service` — the local chat server on
  `127.0.0.1:7878`.
- Helper binaries under `/opt/ai-zombie/bin/`: `verify`,
  `audit-recent`, `health-check`, `collect-diagnostics`,
  `secrets-edit`, `setup-agent-venv`, `zombie-chat`.
- Policy, skills, templates, and audit configuration from
  `payload/agent/` and `payload/etc/`.
- `logrotate` drop-in from `payload/logrotate/`.

## 8. External network services at runtime

- **LLM provider API** — exactly one of the providers listed in §2,
  reached over HTTPS from the chat service.
- **Tailscale coordination server** (`controlplane.tailscale.com`) and
  the operator's tailnet, only when you opt in with
  `ZOMBIE_SKIP_TAILSCALE=0` (Tailscale is off by default).
- **Ubuntu, Docker, PyPI, and npm registries** (plus the Tailscale
  registry when Tailscale is enabled) for install and upgrade only.

## 9. Local accounts, groups, and firewall

Created or modified by `scripts/install.sh`:

- Local user `zombie` (renameable via `ZOMBIE_USER=<name>`), added to
  `sudo` and `docker` groups, with a sudoers drop-in granting
  `NOPASSWD: ALL` at
  `/etc/sudoers.d/90-<user>-ubuntu-zombie`.
- `ufw` enabled with default-deny inbound, default-allow outbound,
  and SSH (`22/tcp`) allowed on **every** interface by default (or
  only on `tailscale0` when `ZOMBIE_SKIP_TAILSCALE=0`).
- `fail2ban` enabled for `sshd`.

---

For the human-readable narrative of why each of these is here, read
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md) and
[`SECURITY.md`](../SECURITY.md). For the exact commands and
environment variables that drive the installer, see
[`docs/CONFIGURATION.md`](CONFIGURATION.md) and `scripts/install.sh --help`.
