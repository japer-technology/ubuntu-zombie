# Configuration

Everything an operator can tune after a successful install.

## Provider keys

Provider credentials live in `/opt/ai-zombie/secrets/env`, mode `0600`,
owned by the local agent account (default `zombie:zombie`; whatever
name was passed to `ZOMBIE_USER` at install time). Edit them with the
safe helper, which re-asserts permissions after `$EDITOR` exits:

```bash
sudo /opt/ai-zombie/bin/secrets-edit
```

Supported variables:

| Variable             | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `OPENAI_API_KEY`     | API key for the OpenAI provider          |
| `ANTHROPIC_API_KEY`  | API key for the Anthropic provider       |
| `GEMINI_API_KEY`     | API key for Google Gemini (routed via `pi-ai`'s `google` provider) |
| `XAI_API_KEY`        | API key for the xAI provider             |
| `OPENROUTER_API_KEY` | API key for the OpenRouter aggregator. Requires `ZOMBIE_MODEL` to be set to a fully-qualified id such as `anthropic/claude-3.5-sonnet`. |
| `MISTRAL_API_KEY`    | API key for the Mistral provider         |
| `GROQ_API_KEY`       | API key for the Groq provider            |
| `ZOMBIE_PROVIDER`    | One of `openai`, `anthropic`, `gemini`, `xai`, `openrouter`, `mistral`, `groq` (default: first key found, in the order above) |
| `ZOMBIE_MODEL`       | Override the provider's default model    |
| `ZOMBIE_CHAT_PORT`   | Loopback port for the chat UI (default `7878`) |
| `DISPLAY`            | X display for desktop helpers (default `:0`) |

All providers are routed through [`@earendil-works/pi-ai`][pi-ai],
installed globally by `scripts/install.sh` at the version pinned in
`payload/agent/pi-ai.version`. The bespoke OpenAI/Anthropic Python
clients that used to live in `payload/agent/providers.py` were
removed in the Phase 1 cutover documented in
[`docs/UPGRADE-TO-PI-PLAN.md`](UPGRADE-TO-PI-PLAN.md).

[pi-ai]: https://github.com/earendil-works/pi

Restart the chat service after editing:

```bash
sudo systemctl restart ubuntu-zombie-chat.service
```

## Agent account name

The installer creates a single local Linux user as the operating
identity of the AI Systems Administrator. The default name is
`zombie`. To pick a different name, pass `ZOMBIE_USER` to the
installer:

```bash
sudo ZOMBIE_USER=admin ./scripts/install.sh install
```

The same variable must be set on every later `install`, `verify`,
`doctor`, `repair`, or `uninstall` run that targets a non-default
account. `AGENT_USER` is still accepted as a backward-compatible alias
so older installs (which used `agent`) can still be repaired or
removed by exporting `AGENT_USER=agent`.

The chosen name appears throughout: `/home/<name>`, the sudoers
drop-in `/etc/sudoers.d/90-<name>-ubuntu-zombie`, the systemd
`User=`/`Group=` of `ubuntu-zombie-chat.service`, and the system
prompt the chat service hands to the LLM.

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
sudo rm /etc/sudoers.d/90-zombie-ubuntu-zombie
```

## Policy

`/etc/ubuntu-zombie/policy.yaml` controls what the agent may run
without approval, what requires approval, and what requires the extra
destructive confirmation phrase. See `ARCHITECTURE.md` for the action
classes. The chat service reloads the policy on every request — no
restart needed.

### Fail-closed default

`settings.default_class` is the classification used when no rule
matches a proposed command. Starting with Phase 0 of
[`docs/UPGRADE-TO-PI-PLAN.md`](UPGRADE-TO-PI-PLAN.md), the shipped
default is `destructive` — the highest gated class — so unknown
commands cannot auto-run. Operators may relax this to a lower class
once a workflow is proven safe.

### Sudo allow-list

`sudo_allow_list:` (a top-level list of program names) keeps common
privileged commands at `system_change` despite the conservative
fail-closed default. The standard approval prompt still fires for
these — they do not auto-run — but they are not escalated to
`destructive`. Entries are matched against the basename of the
program that `sudo` invokes (after `sudo` consumes its own flags), so
`sudo apt install foo`, `sudo -u root systemctl restart sshd`, and
`sudo -E /usr/bin/apt update` are all classified by the entries for
`apt` and `systemctl`. Add entries only after confirming the
underlying program is safe to elevate.

### Tool classes and per-turn budgets (Phases 2 and 4)

Phase 2 of [`docs/UPGRADE-TO-PI-PLAN.md`](UPGRADE-TO-PI-PLAN.md)
replaces the fenced-bash parser with the `pi-mono` agent loop
(`@earendil-works/pi-coding-agent`). The agent now emits structured
tool calls from a closed 13-tool registry (`shell.run`, `fs.read`,
`fs.write`, `pkg.query`, `pkg.install`, `svc.status`, `svc.control`,
`net.status`, `gui.screenshot`, `gui.click`, `gui.type`, `skill.list`,
`skill.load`). Two new `policy.yaml` blocks control them:

```yaml
tool_classes:
  # Override the registry default for a tool. shell.run is always
  # classified per-argv via classify(); listed tools take the class
  # below before classify_tool falls back to the registry default.
  fs.write: user_change
  pkg.install: system_change

agent:
  max_tool_calls_per_turn: 12        # total tool calls per user message
  max_elevated_calls_per_turn: 3     # cap on non read_only calls
```

Phase 4 / P4.1 of [`docs/UPGRADE-TO-PI-PLAN.md`](UPGRADE-TO-PI-PLAN.md)
realigned the defaults with [`docs/UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md)
§6.1–§6.2 (12 / 3) and made the elevated budget enforcement match the
total-call budget enforcement:

- `max_tool_calls_per_turn` is enforced by `pi_mono.run_turn` and the
  bridge — once exceeded, the agent receives a synthetic
  `budget_exceeded:` observation for further calls.
- `max_elevated_calls_per_turn` is enforced by `server.py` against the
  classification returned by `policy.classify_tool`. Each call past the
  budget is recorded as a `budget_exceeded` audit decision and the
  agent sees the same synthetic observation so it ends the turn
  cleanly. The same counter still drives the operator-facing per-turn
  budget badge in the UI.

### pi-mono runtime

The installer pins `@earendil-works/pi-coding-agent` to the version in
`payload/agent/pi-mono.version` and renders runtime configs into
`/opt/ai-zombie/pi/`:

| Path                                   | Purpose                                  |
| -------------------------------------- | ---------------------------------------- |
| `/opt/ai-zombie/pi/settings.json`      | pi-mono settings (`--no-builtin-tools`)  |
| `/opt/ai-zombie/pi/APPEND_SYSTEM.md`   | rendered system-prompt prelude           |
| `/opt/ai-zombie/agent/pi-mono-bridge.mjs` | Node bridge wrapping `pi --mode json` |
| `/opt/ai-zombie/state/logs/pi-mono.*.log` | per-turn bridge logs, rotated daily   |
| `/opt/ai-zombie/state/pi-mono-sessions/`  | pi session/checkpoint state           |

Environment overrides (read by `payload/agent/pi_mono.py`):

| Variable                  | Purpose                                                  |
| ------------------------- | -------------------------------------------------------- |
| `ZOMBIE_PI_MONO_BIN`      | Override the `pi` binary path (defaults to `which pi`).  |
| `ZOMBIE_PI_MONO_BRIDGE`   | Override the bridge script (used by smoke tests).        |
| `ZOMBIE_PI_MONO_LOG_DIR`  | Override the log directory.                              |
| `ZOMBIE_PI_MONO_SETTINGS` | Override the settings.json path.                         |

After editing `policy.yaml` or any template under
`/opt/ai-zombie/agent/templates/`, run `sudo ./scripts/install.sh
repair` to re-render the `pi/` tree and restart the chat service.

## Tailscale

By default the installer enrols the machine into your Tailscale tailnet
and restricts inbound SSH to the `tailscale0` interface via UFW. To
re-enrol or change accounts:

```bash
sudo tailscale logout
sudo tailscale up
```

The chat service never binds outside `127.0.0.1`; remote access is by
SSH tunnel only.

### Skipping Tailscale (no Tailscale account)

If you do not have (or do not want to use) a Tailscale account, run the
installer with `ZOMBIE_SKIP_TAILSCALE=1`:

```bash
sudo ZOMBIE_SKIP_TAILSCALE=1 ./scripts/install.sh install
```

When set, the installer will:

- skip installing the Tailscale apt repo, `tailscale` package, and
  `tailscaled` enablement;
- skip the interactive `tailscale up` prompt and ignore
  `TAILSCALE_AUTHKEY`;
- configure UFW to allow inbound SSH on **every** interface instead of
  only `tailscale0`.

This trades the Tailscale-only ingress posture for reachability on
whatever network the machine sits on. SSH is still key-only and
root-disabled, and the chat/VNC services still bind to `127.0.0.1`
only, but anyone who can route to port 22 on the host can attempt to
authenticate. Use this mode only on a network you control (e.g. behind
a home router/NAT) or behind another VPN.

Re-run the installer without `ZOMBIE_SKIP_TAILSCALE` at any time to
enrol the machine into Tailscale and re-tighten UFW.

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

`x11vnc` binds to `127.0.0.1:5900` only and starts via the agent
account's GNOME autostart entry. Tunnel to it over Tailscale:

```bash
ssh -L 5900:127.0.0.1:5900 zombie@<tailscale-name-or-ip>
# open a VNC viewer at localhost:5900
```

Reset the password:

```bash
sudo -u zombie x11vnc -storepasswd
```

## Chat access

The chat UI is served at `http://127.0.0.1:${ZOMBIE_CHAT_PORT:-7878}/`.
Tunnel over Tailscale exactly the same way as VNC. There is no
authentication on the loopback socket itself — anyone with shell
access as the agent account (default `zombie`) or root can use it.
That matches the trust model: having a shell on the box is already
root-equivalent.

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
