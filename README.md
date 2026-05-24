# Ubuntu Zombie

> A fresh Ubuntu **Server** minimum install, prepared once at the
> physical console, then handed to an **AI Systems Administrator with
> full root access**, reachable only over Tailscale. No public
> exposure. The desktop is an **optional layer**, not the default.

This is the **minimum recommended install** for anyone who wants to
turn an Ubuntu machine into a host that an **AI Systems Administrator
with full root access** can fully operate — terminal, files, OS,
Docker, optionally GUI and browser — without exposing the machine to
the public internet.

The baseline is deliberately small: a stock Ubuntu Server install plus
the few packages an agent actually needs to act as a system
administrator. Anything graphical is opt-in.

You do not need to be a Linux expert to run it. You need to be willing
to sit in front of the machine once with a keyboard.

---

## Who owns the system administrator

This project takes a deliberate position on accountability:

**The token-stream provider — the cloud LLM vendor whose API key is
configured in `secrets/env` — is the owner of the system administrator
identity on this device.**

Concretely:

- The on-host system administrator is the local `agent` user.
- `agent` has passwordless `sudo` and is the only identity allowed to
  log in over SSH.
- `agent` does not act on its own. Every meaningful action it takes is
  produced by a token stream coming back from the configured LLM
  endpoint (OpenAI, Anthropic, or another provider you select in
  `/opt/ai-zombie/secrets/env`).
- The local operator chooses the provider, holds the SSH key, and can
  pull the plug. But while the box is running normally, the
  *administrator* of this Ubuntu device is, in practice, whichever
  model is on the other end of that API key.

That is the trust model. Pick your provider accordingly, and treat the
API key, the SSH private key, and the Tailscale account as a single
matched set of credentials that together name the administrator of
this host.

---

## What this gives you

After one run and a reboot:

| Surface | What the AI can do |
| --- | --- |
| Terminal | SSH in as the dedicated `agent` user with passwordless `sudo`, work inside a persistent `tmux` session |
| OS | Manage packages, services, files, logs, cron, and Docker containers |
| Network in | **Only** through your private Tailscale network. Nothing on the public internet can reach this host. |
| Network out | Standard outbound, used by the cloud LLM SDKs and `apt` |
| Desktop (GUI) — **optional layer** | Move the mouse, type, take screenshots, drive any application — via `xdotool` on a forced-Xorg session |
| Browser — **optional layer** | Drive Chromium through Playwright (headless by default, headed when the desktop layer is installed) |

With the optional desktop layer installed, the host is also configured
so it stays awake, never locks the screen, and autologins the `agent`
user so the X session is always available to control.

---

## Trust model — read this first

This installer makes one deliberate trade-off so AI can do real work:

- The `agent` user has **passwordless `sudo`**.
- Whoever holds the SSH key for `agent` — and the API key for the
  configured LLM provider — therefore holds full root on the host
  through the token stream.
- The only protection against that key being abused is the **Tailscale
  network boundary** and **OpenSSH public-key auth** (no passwords, no
  root login, no other users allowed).

Decide before you run this that you are comfortable with that trade.
Treat the SSH private key, the LLM API key, and the Tailscale account
the same way you would treat a root password.

This profile is **not** the Forgejo Society production runtime. The
production runtime is the self-hosted Forgejo described in the
[transition plan](../transition-plan/00-overview.md). This profile is
a controlled body that an agency can pilot for unattended sysadmin
work, with desktop and browser bolted on when the task needs them.

---

## Profile

The installer is written for one specific shape of machine:

- Local physical hardware (not a cloud VM).
- Intel CPU.
- No local GPU required — language work goes to a cloud LLM.
- **Base profile: Ubuntu Server minimum.** No desktop unless you
  explicitly enable the optional desktop layer.
- Tailscale is the only inbound network path. Nothing is public.
- SSH password authentication is disabled. SSH root login is
  disabled. Public-key authentication only, over Tailscale only.
- **Optional desktop layer:** when enabled, installs
  `ubuntu-desktop-minimal` with Xorg (Wayland disabled) so GUI
  automation actually works, plus `x11vnc` bound to `127.0.0.1` for
  emergency operator viewing over an SSH tunnel.

If your machine does not match this profile, read
[`ai-zombie-ubuntu.sh`](ai-zombie-ubuntu.sh) before running it and
adjust.

---

## Before you start

You will need, sitting at the physical machine:

| Item | Detail |
| --- | --- |
| A fresh Ubuntu 24.04 LTS Server install | 22.04 LTS Server also works. The base profile is server-minimum; the script does **not** install a desktop unless you opt in. |
| A working internet connection | Wired is best. |
| A Tailscale account | Free personal plan is fine. Have your login ready. |
| One SSH public key | The key you will use to log in remotely. Bring it on a USB stick or in a password manager, ready to paste. Look for a line that starts with `ssh-ed25519` or `ssh-rsa`. |
| One cloud LLM API key | OpenAI, Anthropic, or another provider. This key names the *token-stream provider* that will own the system-administrator role on this host. You can paste it after install into `/opt/ai-zombie/secrets/env`. |
| 15 minutes (server only) or 25 minutes (with desktop layer) | Most of that is package downloads. |

---

## Run it

From the physical console of the Ubuntu machine, in a terminal:

```bash
chmod +x ai-zombie-ubuntu.sh
sudo ./ai-zombie-ubuntu.sh
```

To also install the optional desktop / GUI / browser layer:

```bash
sudo AFC_INSTALL_DESKTOP=1 ./ai-zombie-ubuntu.sh
```

The script will:

1. Show you a plan and wait for you to type `YES`.
2. Update the system and install everything the base profile needs.
3. Ask for your SSH public key (paste the whole line).
4. If `AFC_INSTALL_DESKTOP=1`, ask you to set a VNC password (this is
   only used over an SSH tunnel, never on the network).
5. Open a Tailscale login URL — open it on any device, sign in,
   approve the machine.

When it finishes:

```bash
sudo reboot
```

After the machine reboots, from any device on your Tailscale network:

```bash
ssh agent@<tailscale-name-or-ip>
/opt/ai-zombie/bin/verify
```

`verify` walks through every part of the install and prints a green or
red status for each. If anything is red, the message tells you exactly
what to do.

If the desktop layer is installed, the machine will additionally
autologin the `agent` user into an Xorg desktop session so the GUI is
always available for the agent to control.

---

## Configure the token-stream provider

The token-stream provider is the entity whose model the local agent
talks to. Naming it makes the trust model concrete: this is who, in
practice, administers the device.

```bash
sudoedit /opt/ai-zombie/secrets/env
```

Add lines such as:

```
# Pick one. This provider is the owner of the agent identity on this host.
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

This file is owned by the `agent` user and is mode `600`. The helper
scripts under `/opt/ai-zombie/bin/` source it automatically.

---

## Files

| File | Purpose |
| --- | --- |
| [`ai-zombie-ubuntu.sh`](ai-zombie-ubuntu.sh) | One-shot installer. Turns a fresh Ubuntu Server install into an AI-admin-ready host. With `AFC_INSTALL_DESKTOP=1`, also installs the optional desktop / GUI-automation / browser layer. Most steps are idempotent (`apt_install`, the `id`-guarded `adduser`, `usermod -aG`, the `append_line_once` helper for `authorized_keys`, and the `cat >` drop-ins in `/etc/sudoers.d/`, `/etc/ssh/sshd_config.d/`, and — if applicable — `/etc/gdm3/`). A few steps re-prompt interactively on every run: the initial `Type YES` confirmation, the SSH public-key paste, optionally the `x11vnc -storepasswd` password, and `tailscale up` if the device is not already authenticated. UFW is reset and re-applied on every run, so re-running after a transient failure is safe. |
| [`script-description.md`](script-description.md) | Short operator quick-reference for the installer. |
| [`awakening.md`](awakening.md) | Framing document. The machine is not "installed" — it wakes up. Describes the inert-body → token-stream → installer → AI-administrator → root picture, the shape of an awakening token stream, the boot flow, and the safety line (`root-capable, never root-unbounded`) the installer must hold. |

---

## What is installed

### Base profile (always)

| Group | Packages |
| --- | --- |
| Base | `openssh-server`, `sudo`, `ufw`, `fail2ban`, `unattended-upgrades`, `tmux`, `git`, `curl`, `jq`, `ripgrep`, `fd-find`, `tree`, `htop`, `rsync`, `cron`, `python3` + `pipx` + `venv`, `nodejs` + `npm`, `build-essential` |
| Runtime | `python3` venv at `~agent/agent-env` with the LLM SDKs (`openai`, `anthropic`), `requests`, `pydantic`, `rich`, `typer`, `python-dotenv`. Node + `typescript`, `ts-node`, `yarn`, `pnpm`. |
| Containers | `docker-ce` from Docker's official apt repository |
| Remote access | `tailscale` from Tailscale's official apt repository |

### Optional desktop layer (`AFC_INSTALL_DESKTOP=1`)

| Group | Packages |
| --- | --- |
| Desktop & GUI control | `ubuntu-desktop-minimal`, `gdm3`, `xorg`, `xterm`, `dbus-x11`, `dconf-cli`, `x11vnc`, `xdotool`, `wmctrl`, `scrot`, `imagemagick`, `gnome-screenshot`, `xclip`, `xsel`, `at-spi2-core`, `x11-utils`, `python3-tk` |
| Vision & GUI Python | adds `playwright` (+ browsers), `pyautogui`, `pillow`, `mss`, `opencv-python`, `python-xlib` to the existing `agent-env` venv |

Helper scripts in `/opt/ai-zombie/bin/`:

| Script | What it does | Layer |
| --- | --- | --- |
| `agent-shell` | Sources `secrets/env` and attaches to (or starts) a persistent `tmux` session called `ai-zombie` | base |
| `verify` | Runs the full post-install self-check | base |
| `gui-env <cmd>` | Runs `<cmd>` with `DISPLAY`, `DBUS`, and `XDG_RUNTIME_DIR` set, and the secrets file sourced | desktop |
| `screenshot [path]` | Saves a PNG of the desktop (default: `/opt/ai-zombie/state/screen.png`) | desktop |
| `click X Y` | Moves the mouse to `(X,Y)` and clicks | desktop |
| `type-text "…"` | Types literal text into the focused window | desktop |
| `key ctrl+l` | Sends a keystroke (any `xdotool` key sequence) | desktop |

---

## What the installer does, step by step

In order, the script:

1. Confirms `sudo` (exits if `EUID` is not `0`), sources
   `/etc/os-release` and prints a warning if `ID` is not `ubuntu`,
   and asks you to type `YES` to continue.
2. Runs `apt update` and `apt upgrade -y`.
3. Installs the **base** packages: `openssh-server`, `sudo`, common
   shell and network tooling, `ufw`, `fail2ban`,
   `unattended-upgrades`, `python3` + `pipx` + `venv`, `nodejs` +
   `npm`, `build-essential`, `ripgrep`, `fd-find`, `tree`, `rsync`,
   `cron`.
4. Creates the `agent` user, adds it to `sudo`, and grants it
   `NOPASSWD: ALL` via a dedicated `/etc/sudoers.d/` drop-in. This is
   the on-host identity the *token-stream provider* will operate
   under.
5. Asks for one SSH public key and writes it to
   `/home/agent/.ssh/authorized_keys` with correct permissions.
6. Drops `/etc/ssh/sshd_config.d/99-ai-zombie.conf` to disable
   root login, disable password authentication, allow only
   `AllowUsers agent`. Restarts SSH.
7. Installs Tailscale via the upstream installer.
8. Resets UFW, sets default deny-inbound / allow-outbound, allows
   SSH **only on the `tailscale0` interface**, then enables UFW.
9. Enables `fail2ban` and `unattended-upgrades`.
10. Creates `/opt/ai-zombie/{bin,logs,state,secrets,scripts,tools}`
    owned by `agent`, with `secrets/` at mode `0700`. Writes a
    placeholder `secrets/env` for the **token-stream provider** API
    key.
11. Installs Docker Engine from the upstream Docker apt repository
    (`docker-ce`, `docker-ce-cli`, `containerd.io`,
    `docker-buildx-plugin`, `docker-compose-plugin`), adds `agent` to
    the `docker` group, and enables the service.
12. Creates a Python virtualenv at `/home/agent/agent-env` and
    installs the **base** agent runtime: `openai`, `anthropic`,
    `requests`, `pydantic`, `rich`, `typer`, `python-dotenv`.
13. Upgrades `npm` and installs `yarn`, `pnpm`, `typescript`,
    `ts-node` globally.
14. Writes `agent-shell` and `verify` into `/opt/ai-zombie/bin/`.
15. **If `AFC_INSTALL_DESKTOP=1`**, runs the optional desktop layer
    (see next section).
16. Runs `tailscale up --ssh=false` to print the device-auth URL.
    Approve the device in the Tailscale admin console.
17. Prints a final summary of what was installed and what to do next.

A reboot is required at the end.

### Optional desktop layer steps

When `AFC_INSTALL_DESKTOP=1` is set, the script additionally:

D1. Installs the desktop and GUI-automation packages:
    `ubuntu-desktop-minimal`, `gdm3`, `xorg`, `x11vnc`, `xdotool`,
    `wmctrl`, `scrot`, `imagemagick`, `gnome-screenshot`, `xclip`,
    `xsel`, `xterm`, `at-spi2-core`, `x11-utils`, `python3-tk`,
    `dbus-x11`, `dconf-cli`.
D2. Forces Xorg in GDM (`WaylandEnable=false`) and configures GDM
    autologin as `agent`. Sets `Session=ubuntu-xorg` for the user.
    Sets the default target to `graphical.target`.
D3. Masks `sleep.target`, `suspend.target`, `hibernate.target`, and
    `hybrid-sleep.target` so the machine cannot drop the desktop the
    agent is driving. Disables the screensaver and idle lock via
    `gsettings` in a transient dbus session.
D4. Adds `playwright`, `pyautogui`, `pillow`, `mss`, `opencv-python`,
    `python-xlib` to the existing `agent-env` venv and runs
    `playwright install --with-deps` to fetch Chromium and its system
    dependencies.
D5. Writes the GUI-control helper scripts (`gui-env`, `screenshot`,
    `click`, `type-text`, `key`) into `/opt/ai-zombie/bin/`.
D6. Writes `tools/browser-test.py`, a 7-line Playwright smoke test
    that opens `example.com` and prints its title.
D7. Asks you to set an x11vnc password (stored at
    `~agent/.vnc/passwd`) and writes a
    `~/.config/autostart/x11vnc.desktop` entry that runs `x11vnc
    -display :0 -forever -shared -localhost -rfbauth ... -rfbport
    5900`. **Localhost-bound only**, never on the LAN or WAN.

---

## Emergency desktop access

Only relevant if you installed the optional desktop layer.

If you need to actually see the desktop (because something on screen
is blocking the AI), forward the loopback VNC port over your private
SSH session:

```bash
ssh -L 5900:localhost:5900 agent@<tailscale-name-or-ip>
```

Then point any VNC viewer at `localhost:5900` and use the VNC password
you set during install. VNC is bound to `127.0.0.1` on the host, so it
is **never** reachable directly over the network.

---

## Re-running the installer

The script is safe to re-run. It will:

- Add to existing config rather than reset firewall state.
- Skip the SSH-key prompt if a key is already authorized for `agent`.
- Skip the VNC-password prompt if one is already stored (desktop layer).
- Skip the Tailscale auth step if the host is already logged in.

If you want to start from scratch, remove `/opt/ai-zombie/`,
`/etc/sudoers.d/90-agent-full-control`, and
`/etc/ssh/sshd_config.d/99-ai-zombie.conf`, then run again.

---

## Non-interactive install

For provisioning multiple identical hosts you can drive the installer
entirely from environment variables:

```bash
sudo AFC_NONINTERACTIVE=1 \
     SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host" \
     TAILSCALE_AUTHKEY="tskey-auth-..." \
     ./ai-zombie-ubuntu.sh
```

Add `AFC_INSTALL_DESKTOP=1` and `VNC_PASSWORD="$(pwgen -s 24 1)"` if
you also want the desktop layer.

`TAILSCALE_AUTHKEY` is optional. If it is omitted, the script will
print the interactive Tailscale login URL and continue; you can
approve the host afterwards.

---

## Public exposure summary

| Item | State |
| --- | --- |
| Inbound SSH on the public interface | Blocked by UFW |
| Inbound SSH on the Tailscale interface | Allowed, key-only |
| Inbound VNC anywhere (desktop layer only) | Bound to `127.0.0.1`, not reachable |
| Password SSH | Disabled |
| Root SSH | Disabled |
| Tailscale SSH | Disabled (we use OpenSSH only) |
| Unattended security upgrades | Enabled |
| UFW default policy | Deny inbound, allow outbound |

If any of these change after install, `verify` will tell you.

---

## Control surfaces installed

Base profile:

| Surface | How the token-stream provider uses it |
| --- | --- |
| Shell | SSH (key-only, Tailscale-only) + `tmux` + `agent-shell` |
| OS | `apt`, `systemctl`, `journalctl`, file editing, `cron`, Docker |

Optional desktop layer adds:

| Surface | How the token-stream provider uses it |
| --- | --- |
| Desktop GUI | `xdotool`, `wmctrl`, `gnome-screenshot`, `scrot`, `xclip`, `xsel` |
| Browser | Playwright (Chromium) with system dependencies installed |
| Vision | `pillow`, `mss`, `opencv-python` for screen capture and analysis |
| Real desktop | `x11vnc` bound to `127.0.0.1:5900` only, reached via SSH tunnel |

---

## After the installer finishes

```bash
# 1. Reboot the machine.
sudo reboot

# 2. From your laptop, over Tailscale only:
ssh agent@<tailscale-ip-or-name>

# 3. Run the verification script.
/opt/ai-zombie/bin/verify

# 4. Add the token-stream provider API key.
sudoedit /opt/ai-zombie/secrets/env

# 5. Start the persistent agent shell.
/opt/ai-zombie/bin/agent-shell
```

If you installed the desktop layer and need the real desktop (e.g. to
drive a stubborn GUI app), open an SSH tunnel and connect a VNC
viewer:

```bash
ssh -L 5900:localhost:5900 agent@<tailscale-ip-or-name>
# Then point a VNC viewer at localhost:5900
```

---

## Security posture

- **SSH:** key-only, root denied, `AllowUsers agent`, reachable only
  over the `tailscale0` interface.
- **UFW:** default deny inbound, default allow outbound, single allow
  rule for SSH on `tailscale0`.
- **VNC (desktop layer only):** `x11vnc` is bound to `127.0.0.1`
  only. There is no UFW rule for it; the only way in is through an
  authenticated SSH tunnel.
- **Sudo:** `agent` has `NOPASSWD: ALL` so the token-stream provider
  can drive the machine non-interactively. This is the trade-off.
  Treat the SSH private key, the Tailscale account, the LLM API key,
  and `secrets/env` as equivalently sensitive.
- **fail2ban** and **unattended-upgrades** are enabled.
- **Wayland is disabled** when the desktop layer is installed, so GUI
  automation works reliably. Xorg has weaker isolation between apps;
  this is acceptable because the agent is the only user.

This is a **single-operator workstation** profile. Do not deploy it
as a shared host. Do not expose any port publicly. Do not weaken the
Tailscale-only rule.

---

## Undoing the install

There is no automated uninstaller. To revert:

1. `sudo ufw --force reset`
2. `sudo rm /etc/ssh/sshd_config.d/99-ai-zombie.conf && sudo systemctl restart ssh`
3. `sudo rm /etc/sudoers.d/90-agent-full-control`
4. `sudo deluser --remove-home agent`
5. `sudo rm -rf /opt/ai-zombie`
6. `sudo tailscale logout && sudo apt remove --purge tailscale`
7. `sudo rm /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc`
8. `sudo apt remove --purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`
9. If you installed the desktop layer, restore your previous GDM
   config in `/etc/gdm3/custom.conf`.

For a disposable host, reinstalling Ubuntu Server is usually faster.

---

## Example use

Once the install is finished, the SSH key and the LLM API key are in
place, and you are in `agent-shell`, the host is driven by talking to
the token-stream provider the way you would talk to a junior sysadmin
sitting at the keyboard. For example:

> "I will call you Spock. Please install PostgreSQL (latest stable),
> create a role and database for me, and ensure it is managed moving
> forward."

A run like that uses the surfaces the base installer provisioned:

- The conversation happens inside the `tmux` session `ai-zombie`
  started by `/opt/ai-zombie/bin/agent-shell`, so the transcript
  persists across SSH disconnects.
- The agent runs `apt-get update && apt-get install -y postgresql
  postgresql-contrib` non-interactively because `agent` has
  `NOPASSWD: ALL` sudo.
- The agent enables the service (`systemctl enable --now postgresql`)
  and confirms with `systemctl is-active postgresql`.
- The agent creates the role and database via `sudo -u postgres psql`
  and writes any generated credentials to a file under
  `/opt/ai-zombie/secrets/` with mode `0600`.
- "Managed moving forward" means the agent records what it did — a
  short note under `/opt/ai-zombie/state/` and the `tmux` scrollback
  — and re-uses `systemctl status postgresql` and the PostgreSQL log
  under `/var/log/postgresql/` whenever you ask about it later.

The same shape works for any other unit of work the operator wants
to delegate: installing a service, configuring a daemon, debugging a
failing systemd unit, or — with the desktop layer installed — driving
a GUI program through `xdotool` or running a browser flow through
Playwright. The operator stays in the conversation; the token-stream
provider does the typing.

This is the workstation from which the operator then shepherds
Forgejo Society proper — the forge, the runner fleet, the agencies
described under [`../transition-plan/`](../transition-plan/00-overview.md).

---

## Relationship to the rest of Forgejo Society

This workstation is the operator's *hands*, but the *administrator*
of those hands is the token-stream provider you configured. It is the
machine an operator sits at — or remotes into via Tailscale — while
shepherding a Forgejo Society deployment. The forge itself and the
runner fleet are separate machines, described in
[`../transition-plan/00-overview.md`](../transition-plan/00-overview.md)
and
[`../transition-plan/09-runner-scale-strategy.md`](../transition-plan/09-runner-scale-strategy.md).
None of the agent code in this workstation executes against shared
Forgejo or against github.com infrastructure; the LLM calls go out to
the cloud provider you configure in `secrets/env`, and everything
else stays on the machine.
