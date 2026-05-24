# Configuration

Everything an operator can tune after a successful install.

## Provider keys

Provider credentials live in `/opt/ai-zombie/secrets/env`, mode `0600`,
owned by `agent:agent`. Edit them with the safe helper, which
re-asserts permissions after `$EDITOR` exits:

```bash
sudo /opt/ai-zombie/bin/secrets-edit
```

Supported variables:

| Variable             | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `OPENAI_API_KEY`     | API key for the OpenAI provider          |
| `ANTHROPIC_API_KEY`  | API key for the Anthropic provider       |
| `ZOMBIE_PROVIDER`    | `openai` or `anthropic` (default: first key found) |
| `ZOMBIE_MODEL`       | Override the provider's default model    |
| `ZOMBIE_CHAT_PORT`   | Loopback port for the chat UI (default `7878`) |
| `DISPLAY`            | X display for desktop helpers (default `:0`) |

Restart the chat service after editing:

```bash
sudo systemctl restart ubuntu-zombie-chat.service
```

## Rotating provider keys

1. `sudo /opt/ai-zombie/bin/secrets-edit` — replace the value.
2. `sudo systemctl restart ubuntu-zombie-chat.service`.
3. Optionally revoke the old key in the provider's console.

## Revoking the agent

To stop useful agent operation immediately:

```bash
sudo /opt/ai-zombie/bin/secrets-edit   # delete every API key
sudo systemctl restart ubuntu-zombie-chat.service
```

The chat will load but refuse to call any provider.

To stop the service entirely:

```bash
sudo systemctl disable --now ubuntu-zombie-chat.service
```

To remove privileged access without uninstalling everything:

```bash
sudo rm /etc/sudoers.d/90-agent-ubuntu-zombie
```

## Policy

`/etc/ubuntu-zombie/policy.yaml` controls what the agent may run
without approval, what requires approval, and what requires the extra
destructive confirmation phrase. See `ARCHITECTURE.md` for the action
classes. The chat service reloads the policy on every request — no
restart needed.

## Tailscale

The installer enrols the machine into your Tailscale tailnet. To
re-enrol or change accounts:

```bash
sudo tailscale logout
sudo tailscale up
```

Inbound SSH is restricted to the `tailscale0` interface via UFW. The
chat service never binds outside `127.0.0.1`; remote access is by SSH
tunnel only.

## Autologin

By default Ubuntu Zombie does **not** enable graphical autologin. To
enable it (required for unattended desktop automation), re-run the
installer with:

```bash
sudo ZOMBIE_ENABLE_AUTOLOGIN=1 ./scripts/install.sh install
```

Autologin trades a meaningful slice of physical-access security for
the ability for the agent to drive the desktop without a human first
typing the password. Read `SECURITY.md` before enabling it.

## VNC

`x11vnc` binds to `127.0.0.1:5900` only and starts via the agent's
GNOME autostart entry. Tunnel to it over Tailscale:

```bash
ssh -L 5900:127.0.0.1:5900 agent@<tailscale-name-or-ip>
# open a VNC viewer at localhost:5900
```

Reset the password:

```bash
sudo -u agent x11vnc -storepasswd
```

## Chat access

The chat UI is served at `http://127.0.0.1:${ZOMBIE_CHAT_PORT:-7878}/`.
Tunnel over Tailscale exactly the same way as VNC. There is no
authentication on the loopback socket itself — anyone with shell
access as `agent` (or root) can use it. That matches the trust model:
having a shell on the box is already root-equivalent.

## Logs and state

| Path                                    | Purpose                          |
| --------------------------------------- | -------------------------------- |
| `/var/log/ubuntu-zombie-install.log`    | Installer transcripts            |
| `/var/log/ubuntu-zombie/audit.log`      | JSON-lines AI audit trail        |
| `/opt/ai-zombie/state/conversations.db` | Chat history (SQLite)            |
| `/opt/ai-zombie/state/screen.png`       | Latest screenshot helper output  |

## Health check

Run on demand:

```bash
/opt/ai-zombie/bin/health-check
```

Enable the systemd timer for periodic checks:

```bash
sudo systemctl enable --now ubuntu-zombie-health.timer
```
