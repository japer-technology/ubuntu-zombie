# Tailscale

This document explains how `ubuntu-zombie` authenticates to Tailscale,
**why** that credential is used, and **whether it is required**.

## There is no "Tailscale password"

Tailscale does not use a password. A machine joins your private network
(your *tailnet*) by **authenticating**, in one of two ways:

- **Interactive login** — `tailscale up` prints a URL; you open it and
  approve the machine against your existing Tailscale identity (Google,
  Microsoft, GitHub, Okta, etc.). The identity provider, not a local
  password, is what authenticates you.
- **A pre-auth key** (`TAILSCALE_AUTHKEY`, a `tskey-auth-…` token) —
  generated in the Tailscale admin console for unattended enrolment.

So when this repo refers to a Tailscale "credential" it means one of
these, never a password.

## Why you might opt in to Tailscale

Tailscale is an optional extra ingress boundary. The default remote
access path is normal OpenSSH: key-only authentication, password login
disabled, and root login disabled. That is secure enough for a host
behind a trusted LAN, private cloud network, security group, bastion,
or existing VPN. When Tailscale is enabled, the security posture
becomes:

- UFW is `default deny incoming`, `default allow outgoing`.
- Inbound SSH (22) is allowed **only** on the `tailscale0` interface,
  so the machine is reachable for administration only from devices on
  your tailnet.
- The desktop (`x11vnc`) and chat UI bind to `127.0.0.1` only and are
  reached by tunnelling over that SSH connection.

In other words, Tailscale is not required to make SSH safe; it narrows
which devices can even attempt SSH authentication. The loopback-only
chat and VNC services still sit behind SSH in both modes.

## Is Tailscale required?

**No — Tailscale is off by default.** The installer ships with
`ZOMBIE_SKIP_TAILSCALE=1`, which means it does **not** install or enrol
Tailscale and does not ask for any Tailscale credential. In that mode
inbound SSH is allowed on **every** interface (with a loud warning),
but SSH remains key-only and root-disabled. Use that default behind a
network boundary you already trust (a private LAN, cloud firewall,
bastion, another VPN, etc.).

You opt in by setting `ZOMBIE_SKIP_TAILSCALE=0`:

```bash
sudo ZOMBIE_SKIP_TAILSCALE=0 ./scripts/install.sh install
```

This installs Tailscale from its official apt repository, enables
`tailscaled`, restricts inbound SSH to `tailscale0`, and enrols the
machine. You can re-run the installer with `ZOMBIE_SKIP_TAILSCALE=0` at
any later time to switch a host over to the Tailscale-only posture.

| `ZOMBIE_SKIP_TAILSCALE` | Tailscale credential | SSH exposure |
| ----------------------- | -------------------- | ------------ |
| `1` (default)           | none — not installed/enrolled | every interface (warned) |
| `0`                     | required — interactive login or `TAILSCALE_AUTHKEY` | `tailscale0` only |

## How the Tailscale credential is used

When `ZOMBIE_SKIP_TAILSCALE=0`, `scripts/install.sh` enrols the machine
in this order:

1. **Already logged in?** If `tailscale status` shows the node is up and
   not "Logged out", enrolment is skipped.
2. **`TAILSCALE_AUTHKEY` set?** The installer runs
   `tailscale up --ssh=false --authkey "$TAILSCALE_AUTHKEY"` for fully
   unattended enrolment. (`--ssh=false` keeps Tailscale SSH disabled;
   access is plain SSH restricted to the `tailscale0` interface.)
3. **Otherwise (interactive):** the installer runs `tailscale up` and
   prints the login URL for you to approve in a browser.

`TAILSCALE_AUTHKEY` is only consulted when `ZOMBIE_SKIP_TAILSCALE=0`; it
is ignored in the default skip mode. It is treated as a secret
throughout — the audit logger redacts `tskey-…` tokens and the
`TAILSCALE_AUTHKEY` environment value, and the install receipt never
records it.

### Fully unattended example

```bash
sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA… you@host" \
     ZOMBIE_NONINTERACTIVE=1 \
     ZOMBIE_SKIP_TAILSCALE=0 \
     VNC_PASSWORD="replace-me" \
     TAILSCALE_AUTHKEY="tskey-auth-…" \
     ./scripts/install.sh install
```

### Re-authenticating later

```bash
sudo tailscale logout
sudo tailscale up
```

If interactive enrolment does not complete during install, the
installer warns and you can finish it from the console with
`sudo tailscale up` before relying on the Tailscale-only SSH rule.

## Tailscale vs the VNC password

These are independent credentials at different layers and are both used
when Tailscale is enabled:

- **Tailscale login / auth key** — controls which devices can reach the
  host and open an SSH tunnel.
- **VNC password** (`VNC_PASSWORD`, stored in `~/.vnc/passwd`) — a
  separate credential that controls who can then attach to the running
  desktop through that tunnel. Unlike Tailscale, the VNC password is
  always required for an install to complete, because `x11vnc` is never
  configured without one. See `docs/CONFIGURATION.md` (VNC section).

## Related documents

- `docs/CONFIGURATION.md` — opting in to Tailscale, re-enrolling, and
  tunnelling VNC/chat over it.
- `docs/QUICKSTART.md` — required inputs and unattended installs.
- `docs/TROUBLESHOOTING.md` — recovering Tailscale/SSH access.
- `SECURITY.md` and `docs/ARCHITECTURE.md` — the full network and
  privilege model.
