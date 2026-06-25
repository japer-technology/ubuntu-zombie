# Ubuntu Zombie Zero

> A reductive analysis: what is the *smallest* Ubuntu Zombie that still
> delivers the full power and scope of the AI Systems Administrator,
> reached through a **single** access path — the local-browser Pi-Mono
> chat at `http://127.0.0.1:7878/`?

This document is a thought experiment, not a shipped configuration. It
catalogues every installer component that could be **removed** or made
**optional** without reducing the authority, reach, or auditability of
the agent itself, on the assumption that the *only* sanctioned entry
point is the loopback browser UI driving the Pi-Mono runner.

Before relying on any item here, read [`docs/VISION.md`](../VISION.md),
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md), and
[`SECURITY.md`](../../SECURITY.md). The current product MVP is broader
than "local browser only" — it deliberately supports remote
administration over SSH and optional Tailscale. "Zombie Zero" trades
that remote reach away; it does **not** trade away the agent's power on
the box.

## What "power and scope" means here

The agent's authority comes from a small, irreducible core. None of it
is on the chopping block:

- The root-capable **`agent` user** with passwordless `sudo` — the
  operating identity and the "deep connection to the fabric of the PC".
- The **chat service** (`payload/agent/server.py`) bound to
  `127.0.0.1`, which already *is* a local-browser product.
- The **Pi-Mono runner and Node bridge** (`pi_mono.py`,
  `pi-mono-bridge.mjs`, the pinned `pi` CLI) — the actual agent loop
  with its built-in tools (read, bash, edit, write, grep, find, ls).
- The **policy gate** (`payload/etc/policy.yaml`,
  `payload/agent/policy.py`) and the **audit log**
  (`payload/agent/audit.py`) — the security boundary that makes the
  power safe and reversible.
- The **Python venv runtime** and the **workspace** at
  `/opt/ai-zombie/` that hosts all of the above.

Everything in that list stays. Everything below it can go or become
opt-in without touching the agent's reach on the local machine.

## Installer sections classified

The installer (`scripts/install.sh`) runs ~23 numbered phases. Mapping
each phase to the Zombie Zero goal:

| Section | Verdict for Zombie Zero |
| --- | --- |
| System update | **Keep** — toolchain baseline. |
| Base packages | **Trim** — keep the agent's tools, drop server/remote extras (see below). |
| Desktop, Xorg, and GUI control packages | **Optional** — only for GUI-driving. |
| Create `agent` user | **Keep** — the core authority. |
| SSH key setup | **Remove** — remote ingress, not local browser. |
| Harden SSH | **Remove** — only meaningful if SSH is installed. |
| Install Tailscale | **Remove** — remote networking (already off by default). |
| Firewall (SSH/Tailscale variants) | **Optional** — exists to gate SSH/Tailscale ingress. |
| Security services (fail2ban) | **Remove** — protects an exposed SSH surface that no longer exists. |
| Force Xorg session | **Optional** — only needed for the GUI/VNC path. |
| Prevent sleep, suspend, screen lock | **Keep** — keeps the loopback service reachable. |
| Create Ubuntu Zombie workspace | **Keep** — payload home. |
| Install Docker Engine | **Optional** — only if the agent must manage containers. |
| Python cloud-agent runtime | **Keep** — the chat server. |
| Node runtime | **Keep** — runs the Pi-Mono bridge. |
| Deploy chat service, helpers, and policy | **Keep** — the UI, policy gate, audit log. |
| GUI control helper scripts | **Optional** — only for GUI-driving. |
| Browser automation smoke test | **Optional** — validates the GUI path only. |
| x11vnc loopback-only desktop access | **Remove** — remote/secondary desktop viewing. |
| Install verification script | **Keep (cheap)** — operator convenience, no runtime cost. |
| Tailscale authentication | **Remove** — pairs with Tailscale install. |
| First-run status | **Keep (cheap)** — informational. |

## Components that could be removed entirely

These serve **remote administration** or **defence of a remote surface**.
With local-browser-only access, none of them adds to the agent's power
on the machine.

1. **SSH server + key setup + hardening.** `openssh-server`, the
   `agent` `authorized_keys` provisioning, and the sshd hardening drop-in.
   A loopback-only agent never accepts inbound SSH. Removing this also
   removes the need for the `SSH_PUBLIC_KEY` input.
2. **Tailscale install + authentication.** The official Tailscale apt
   repo, the daemon, and `tailscale up` enrolment. Already opt-in
   (`ZOMBIE_SKIP_TAILSCALE=1` is the default), so this is "delete the
   off-by-default branch", and with it the `TAILSCALE_AUTHKEY` input.
3. **fail2ban / "Security services".** Its only job is to throttle
   brute-force attempts against exposed SSH. No SSH surface, no purpose.
4. **x11vnc loopback desktop access.** A second remote-ish viewing path
   (VNC over an SSH tunnel) that duplicates, rather than enables, the
   browser entry point. The `VNC_PASSWORD` input goes with it.
5. **Autologin** (`ZOMBIE_ENABLE_AUTOLOGIN`). An unattended-desktop
   convenience tied to the VNC/GUI story; already off by default.

Removing 1–4 collapses the firewall section to a no-op (its rules exist
solely to scope SSH/Tailscale ingress), so the **UFW configuration**
becomes optional too — a single "deny inbound, allow loopback" default
is enough for Zombie Zero.

## Components that could be made optional (feature-gated)

These are real capabilities the agent *can* use, but they are not part
of the irreducible core. Behind an off-by-default flag they preserve
"scope" while shrinking the default footprint.

1. **Docker Engine.** Referenced by the policy gate
   (`payload/etc/policy.yaml`) and by `runner.py` follow-ups, but the
   core browser→agent loop never requires it. Gate behind something like
   `ZOMBIE_ENABLE_DOCKER=1`. The agent can still install Docker *itself*,
   on request, through the approved policy path.
2. **The GUI-automation stack.** `ubuntu-desktop-minimal`, `gdm3`,
   `xorg`, the "Force Xorg session" step, the GUI control helper
   scripts (`xdotool`, `wmctrl`, `scrot`, `imagemagick`,
   `gnome-screenshot`, `xclip`, `xsel`, `xterm`, `at-spi2-core`,
   `x11-utils`), and the browser-automation smoke test. These let the
   agent see and drive the desktop. If "deep connection" means only
   shell/filesystem/service control, this entire stack is optional.
   Gate behind `ZOMBIE_ENABLE_GUI=1`.
3. **Base-package extras for the server/remote story.** From the "Base
   packages" list, the following are not needed by a loopback agent and
   could move to an optional set: `openssh-server`, `ufw`, `fail2ban`,
   `net-tools`, `dnsutils`, `python3-tk` (Tk is only needed for GUI
   automation). The agent's own toolbox — `git`, `vim`, `nano`, `tmux`,
   `jq`, `ripgrep`, `fd-find`, `curl`, `python3`/`pip`/`venv`,
   `build-essential`, etc. — stays, because the agent uses those tools
   directly.

## What a "Zombie Zero" install would still contain

After the trims above, the minimal-but-equally-powerful install is:

- System update + a **lean base-package set** (agent tooling only).
- The **`agent` user** with passwordless `sudo`.
- The **workspace** at `/opt/ai-zombie/`.
- The **Python venv** and **Node runtime** with the pinned `pi` CLI.
- The **chat service** (loopback), **policy gate**, **audit log**, and
  operator **helper scripts** (`verify`, `audit-recent`,
  `collect-diagnostics`, `health-check`, `secrets-edit`).
- **Sleep/lock inhibition** so the service stays up.
- A trivial **loopback-only firewall default** and the
  **verification/first-run status** niceties.

That install presents exactly one door — the local browser at
`127.0.0.1:7878` — and behind it the agent has the same root-capable
authority, the same policy gate, and the same audit trail as the full
product. The power and scope are unchanged; only the remote-access and
GUI-driving surface area is shed.

## Caveats and non-goals

- **This is analysis, not a delivered profile.** No `ZOMBIE_PROFILE`
  flag exists today; implementing one is a separate piece of work.
- **Revocation story changes.** Today the kill switch includes
  "remove the SSH key" and "disable Tailscale". A Zombie Zero with no
  SSH/Tailscale relies on key rotation, stopping the service, and
  `uninstall` instead — which is arguably cleaner for a single-box,
  single-operator deployment.
- **No TTL exists.** "Single access until a deadline" is sometimes
  asked for, but there is no time-to-live / self-expiry mechanism in
  the installer or service — only per-turn idle timeouts
  (`policy.max_turn_seconds` and the bridge watchdog). A true TTL would
  be new functionality, out of scope for this reduction exercise.
- **Defence-in-depth trade-off.** Removing UFW/fail2ban is safe *only*
  because the remote surface is also removed. Keep them if any inbound
  service is ever re-enabled.
