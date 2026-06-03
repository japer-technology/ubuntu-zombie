# Tailscale, VNC, and the VNC password

This document explains the remote-access model of `ubuntu-zombie` and,
in particular, **why** and **how** the VNC password is used, and
**whether it is required**.

## The access path

The host exposes no graphical service to the network. The only
externally reachable port is SSH (22), and by default that is allowed
only on the `tailscale0` interface:

- UFW is `default deny incoming`, `default allow outgoing`.
- SSH is restricted to the Tailscale interface (set
  `ZOMBIE_SKIP_TAILSCALE=1` to open SSH on every interface instead,
  with a loud warning).
- `x11vnc` binds to `127.0.0.1:${VNC_PORT:-5900}` only (`-localhost`),
  and never listens on the network.
- The chat UI likewise binds to `127.0.0.1` only.

So the desktop is reached by joining the machine's private Tailscale
network and tunnelling VNC over SSH:

```bash
ssh -L 5900:127.0.0.1:5900 zombie@<tailscale-name-or-ip>
# then point a VNC viewer at localhost:5900
```

The VNC password is the credential that the viewer presents once that
tunnel is open.

## Why the VNC password exists

`x11vnc` is installed for **emergency, loopback-only desktop access** —
for example to watch or take over the GNOME session the agent is
driving when something needs a human at the screen. Because the VNC
server runs inside the agent's GNOME session and shares its X display,
it needs an authentication step of its own so that simply reaching the
loopback socket (over the SSH tunnel) is not enough to attach to the
live desktop.

The password is therefore a second factor *behind* the SSH/Tailscale
boundary, not a replacement for it:

- **Tailscale + SSH key** controls who can reach the host and open the
  tunnel at all.
- **The VNC password** controls who can then attach to the running
  desktop through that tunnel.

It is deliberately scoped to this single job. It is not a login
password, not a sudo password, and is never used for the chat service
or for any provider credential.

## How the VNC password is used

At install time the installer (`scripts/install.sh`) provisions
`x11vnc` for the agent account (default `zombie`):

1. It creates `~/.vnc` with mode `0700`, owned by the agent user.
2. It stores the password by piping it to `x11vnc -storepasswd`, which
   writes the obfuscated password file `~/.vnc/passwd` (mode `0600`).
3. It writes a GNOME autostart entry,
   `~/.config/autostart/x11vnc.desktop`, that launches:

   ```
   x11vnc -display :0 -forever -shared -localhost \
          -rfbauth ~/.vnc/passwd -rfbport ${VNC_PORT}
   ```

   `-localhost` keeps the listener on `127.0.0.1`, and `-rfbauth`
   points at the stored password file so every connection must
   authenticate.

The password is supplied to the installer in one of three ways:

- **Interactively** — the installer prompts (twice, masked) and calls
  `x11vnc -storepasswd`, retrying on a mismatch.
- **Via the `VNC_PASSWORD` environment variable** — used for
  unattended installs; the installer stores it without prompting.
- **Reused from disk** — if `~/.vnc/passwd` already exists (for example
  on a re-run or upgrade), the installer keeps it and does not prompt.

`VNC_PASSWORD` is treated as a secret throughout: the audit logger
redacts it, and the install receipt records only a set/unset flag, not
the value.

### Resetting or changing it

Reset the password at any time as the agent user:

```bash
sudo -u zombie x11vnc -storepasswd
```

The VNC port is fixed at install time. To change it, re-run the
installer with `VNC_PORT=<n>` (and re-tunnel accordingly):

```bash
sudo VNC_PORT=5901 ./scripts/install.sh install
```

## Is the VNC password required?

**Yes — a VNC password must exist for the install to complete, but you
are not always asked to type one.** The rules are:

| Situation | Behaviour |
| --------- | --------- |
| `~/.vnc/passwd` already exists | Reused; you are not prompted. |
| Interactive install, no stored password | You are **prompted** to set one (required to proceed). |
| `VNC_PASSWORD` env var is set | Used directly; no prompt. |
| Non-interactive install (`ZOMBIE_NONINTERACTIVE=1`), no stored password | `VNC_PASSWORD` is **mandatory**; the installer aborts if it is missing. |

In other words, the installer never configures `x11vnc` without a
password. There is no "no password" mode — the desktop is always
behind both the Tailscale/SSH boundary and the VNC password.

## Related documents

- `docs/CONFIGURATION.md` — VNC and chat tunnelling, port changes.
- `docs/QUICKSTART.md` — required inputs (`SSH_PUBLIC_KEY`,
  `VNC_PASSWORD`) and unattended installs.
- `docs/TROUBLESHOOTING.md` — recovering VNC access.
- `SECURITY.md` and `docs/ARCHITECTURE.md` — the full network and
  privilege model.
