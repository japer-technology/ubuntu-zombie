# Architecture

Ubuntu Zombie is a local-only AI Systems Administrator for Ubuntu
Desktop LTS. The installer creates a dedicated Linux account, installs a
small Python chat service, renders pi-mono runtime configuration, and
runs everything behind a local policy gate and audit log.

## Installed shape

```text
scripts/install.sh
  -> /opt/ai-zombie/
       agent/                Python chat service and pi bridges
       bin/                  operator helpers
       etc/policy.yaml       default action policy
       pi/                   rendered pi-mono settings and prompt prelude
       state/                conversations, lifecycle, logs
  -> /etc/ubuntu-zombie/     operator-editable policy/skills overlays
  -> /etc/systemd/system/    chat service and health timer
  -> /etc/sudoers.d/         passwordless sudo for the agent account
```

The default install does **not** provision SSH, Tailscale, VNC, Docker,
graphical autologin, or GUI automation. The only product access surface
is the chat service on `127.0.0.1:${ZOMBIE_CHAT_PORT:-7878}`.

## Runtime components

- `server.py` serves the chat UI, session APIs, approval flow, health
  endpoints, and model selection endpoints.
- `pi_mono.py` starts `pi-mono-bridge.mjs`, enforces turn timeouts, and
  returns structured events to the server.
- `tools.py` defines the closed tool registry: shell, filesystem,
  package, service, network status, and skill loading tools.
- `policy.py` classifies commands and tool calls before execution.
- `audit.py` writes JSON-lines audit records with secret redaction.
- `history.py` persists conversations and tool events in SQLite.
- `lifecycle.py` enforces the Time to Live state.

## Trust boundaries

1. The browser talks to the loopback chat service.
2. The server sends prompts to the configured LLM provider through
   pi-mono.
3. Proposed tool calls pass through schema validation and policy
   classification.
4. Elevated actions require the configured approval path before running.
5. Every decision and tool result is audit-logged.

The local agent account has passwordless sudo by design. The policy gate
and audit trail are the runtime safety boundary; they do not make the
agent account unprivileged.

## Tool policy

Action classes are:

| Class | Meaning |
| ----- | ------- |
| `read_only` | Inspection only; can auto-run. |
| `user_change` | Changes within user-owned state. |
| `system_change` | Package, service, or privileged file mutation. |
| `network_change` | Firewall or interface mutation. |
| `destructive` | Irreversible actions; requires the confirmation phrase. |

Built-in skills ship under `/opt/ai-zombie/skills/` and currently cover
`apt` and `systemd`. Operators may add local skill briefs under
`/etc/ubuntu-zombie/skills.d/`.

## Installer subcommands

| Subcommand | Behaviour |
| ---------- | --------- |
| `install` | Idempotent full install. |
| `verify` | Read-only state check. |
| `doctor` | Explain failures and likely fixes. |
| `repair` | Re-assert permissions, re-render runtime config, redeploy skills, restart chat. |
| `uninstall` | Delegate to `scripts/uninstall.sh`. |

## Logs and state

| Path | Purpose |
| ---- | ------- |
| `/var/log/ubuntu-zombie-install.log` | Installer transcript. |
| `/var/log/ubuntu-zombie/install-receipt.txt` | Non-secret install receipt. |
| `/var/log/ubuntu-zombie/audit.log` | JSON-lines audit trail. |
| `/opt/ai-zombie/state/conversations.db` | Chat history. |
| `/opt/ai-zombie/state/lifecycle.json` | TTL/tombstone state. |
| `/opt/ai-zombie/state/logs/` | pi-mono bridge logs. |
