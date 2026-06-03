# VNC and the VNC password

Why Ubuntu Zombie ships a VNC server, how the VNC password protects it,
and whether you have to set one.

## What the VNC server is for

The agent automates a real GNOME desktop (Xorg + `xdotool` + `scrot`).
`x11vnc` is bundled so a human can *watch and drive that same desktop*
when something needs eyes-on attention — an install dialog the agent
can't dismiss, a wedged session, or just confirming what the AI is
doing on screen. It is an **emergency / manual desktop surface**, not a
day-to-day login: routine interaction happens through SSH and the chat
UI.

`x11vnc` shares the live `:0` display (`-display :0 -forever -shared`)
and starts from the agent account's GNOME autostart entry
(`~/.config/autostart/x11vnc.desktop`).

## Why a password is required at all

The VNC server is bound to loopback only:

```
x11vnc ... -localhost -rfbauth ~/.vnc/passwd -rfbport <VNC_PORT>
```

`-localhost` binds it to `127.0.0.1:${VNC_PORT:-5900}` and it is **never**
exposed to the network. To reach it you SSH-tunnel the port (over
Tailscale if you enabled it):

```bash
ssh -L 5900:127.0.0.1:5900 zombie@<tailscale-name-or-ip>
# then point a VNC viewer at localhost:5900
```

So why bother with a password if the socket is already private? Defence
in depth. Anyone who can reach the loopback socket — i.e. anyone with a
shell on the box — can drive the desktop, and on a multi-user or
tunnelled host the loopback port is not as private as it looks. The
password is a second credential in front of full keyboard/mouse control
of an unlocked session. `SECURITY.md` lists it as a real credential
("loopback-only but still a credential"), and the VNC protocol has no
unauthenticated mode worth using, so a password is always set.

## How the password is stored and used

The password is **never** kept in plain text. During install the value
is fed to `x11vnc -storepasswd`, which writes an obfuscated password
file:

- Location: `~agent/.vnc/passwd` (e.g. `/home/zombie/.vnc/passwd`).
- Permissions: directory `0700`, file `0600`, owned by the agent
  account.
- Use: `x11vnc` reads it via `-rfbauth ~/.vnc/passwd`; connecting
  clients must present the matching password.

The raw `VNC_PASSWORD` you provide is only used at install time to
generate that file. It is not written to the install receipt or audit
log — only a set/unset flag is recorded.

## Is the VNC password required?

**Yes — the installer always ends up with a VNC password set**, but how
you supply it depends on the mode:

- **Interactive install:** if no `~agent/.vnc/passwd` already exists,
  the installer prompts you (via `x11vnc -storepasswd`, masked, with up
  to three retries on a mismatch).
- **Non-interactive install (`ZOMBIE_NONINTERACTIVE=1` / `--yes`):** you
  **must** export `VNC_PASSWORD` *unless* a password file already
  exists on disk. If it is missing the installer aborts with exit code
  `64` ("Non-interactive mode requires `VNC_PASSWORD`…").
- **Re-running the installer:** if `~agent/.vnc/passwd` is already
  present it is kept as-is ("VNC password already set; keeping it"), so
  you do not have to re-supply it on upgrades.

In other words the password itself is not optional; only the *prompt*
is skipped when one is already stored.

### Setting it non-interactively

```bash
sudo ZOMBIE_NONINTERACTIVE=1 \
     SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@host" \
     VNC_PASSWORD="s3cret" \
     ./scripts/install.sh install
```

## Resetting or rotating the password

Re-run `x11vnc -storepasswd` as the agent account at any time:

```bash
sudo -u zombie x11vnc -storepasswd
```

This rewrites `~/.vnc/passwd`. The change takes effect the next time
`x11vnc` starts (e.g. after the next desktop login or reboot).

## Changing the port

The port is fixed at install time (`VNC_PORT`, default `5900`). To
change it, re-run the installer and re-tunnel accordingly:

```bash
sudo VNC_PORT=5901 ./scripts/install.sh install
```

## Related reading

- [`docs/CONFIGURATION.md`](CONFIGURATION.md) — VNC, chat, Tailscale,
  and other post-install tuning.
- [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — connection, forgotten
  password, and black-screen fixes.
- [`SECURITY.md`](../SECURITY.md) — the trust model and credential
  rotation table.
