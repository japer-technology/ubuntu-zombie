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
  endpoints, model selection endpoints, and the authenticated
  server-sent-events stream used for live turn progress.
- `pi_mono.py` starts `pi-mono-bridge.mjs`, enforces turn timeouts, and
  returns structured events to the server. Optional bridge `token` and
  `progress` events are forwarded as live UI hints; the final persisted
  conversation remains authoritative.
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

## Chat turn transport

The browser normally asks `POST /api/message` for a streaming turn. The
server validates the prompt and TTL, registers an opaque `turn_id`, starts
the model turn in a worker thread, and returns immediately. The browser
then opens `GET /api/stream/{turn_id}` with `EventSource`; the endpoint is
behind the same session-cookie gate as the JSON APIs and is not public.

The stream is one-way SSE over the existing loopback `ThreadingHTTPServer`
and carries a small vocabulary:

| Event | Purpose |
| ----- | ------- |
| `phase` | Coarse turn state such as model work or finalising. |
| `token` | Best-effort assistant text deltas from the bridge. |
| `tool_start` / `tool_end` | Live tool activity from the same paths that write history/audit records, or display-only pi built-in tool progress. |
| `pending_approval` | An elevated call has entered the operator approval queue. |
| `turn_done` | The exact final JSON payload the synchronous path returns. |
| `turn_error` | Provider, bridge, TTL, or stream setup failure. |

Clients that omit `stream: true`, lack `EventSource`, or lose the stream
fall back to the original synchronous JSON response or a conversation
reload. Closing the stream does not cancel the server-side turn; history
and the audit log continue to be written and can be reloaded later.

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

## Optional components

The installer uses the component-aware grammar `scripts/install.sh
<verb> [component ...] [flags]`. Public targets currently are `zombie`
(the baseline account, runtime, chat UI, policy, and services) and
`forgejo`. The legacy `ZOMBIE_INSTALL_*` flags remain supported and are
additive with explicit targets; all default to `0`, and specifications
live under `options/`. Each component follows one contract: validated
settings, an entry in the interactive Options menu, a dry-run stanza,
guarded idempotent install sections, receipt records,
`verify`/`doctor`/`repair` checks, and a reversal path in
`uninstall.sh`.

The first component is the **Forgejo server**
(`ZOMBIE_INSTALL_FORGEJO`): a git forge backed by PostgreSQL, running
as the dedicated `git` system user under a hardened `forgejo.service`
unit, plus an optional co-located Actions runner
(`ZOMBIE_INSTALL_FORGEJO_RUNNER`, Docker executor, `forgejo-runner`
system user). Its trust boundary differs from the chat service: the
Forgejo process is loopback-only, while Caddy is the **network-listening
service** on HTTPS port `443`. Avahi publishes the machine's `.local`
name, Caddy terminates a certificate from its internal CA, and the
installer exports only the public CA root for clients to trust. These
services are sandboxed
(`NoNewPrivileges`, `ProtectSystem=full`, scoped `ReadWritePaths`) —
the opposite of the deliberately unsandboxed chat unit. Its secrets
live only in `/etc/forgejo/app.ini` (`root:git`, `640`). The policy
gate classifies forge administration (`forgejo`, `forgejo-runner`,
`psql`, `createdb`) as `system_change` and database drops
(`dropdb`/`dropuser`/`DROP DATABASE`) as `destructive`.

The installer core owns parsing, target ordering, selected configuration
validation, host preflight, apt/download helpers, logging, receipts,
progress, and manifest writes. Component hooks own their mutations.
`install_zombie` converges the account, runtimes, policy, and chat stack;
`install_forgejo` converges PostgreSQL, Forgejo, and its optional runner.
The Forgejo hook has an explicit package set (`git`, `git-lfs`,
`postgresql`, `postgresql-contrib`, `openssl`, `xz-utils`, `caddy`,
`avahi-daemon`, and `libnss-mdns`, plus `docker.io` for the runner) and
does not depend on zombie-owned state.

## Installer command grammar

```text
scripts/install.sh <verb> [component ...] [flags]
```

| Verb | Behaviour |
| ---- | --------- |
| `install` | Idempotent install. With no target, selects `zombie`. |
| `verify` | Read-only state check. |
| `doctor` | Explain failures and likely fixes. |
| `repair` | Re-assert permissions, re-render runtime config, redeploy skills, restart chat. |
| `uninstall` | Delegate to `scripts/uninstall.sh`; `uninstall zombie` / `uninstall forgejo` remove only that component, and no target removes all managed components. |

`install forgejo` is a standalone path: it creates neither the zombie
account nor `/opt/ai-zombie`, and it does not deploy Node, the Python
agent runtime, policy, audit, chat, or desktop-availability settings.
Installer-owned transcript and receipt records remain under `/var/log/`.

## Component manifest

Installed components are tracked independently under
`/var/lib/ubuntu-zombie/components/`. This directory is intentionally
outside `/opt/ai-zombie`, so selective zombie removal does not erase the
manifest entry for a remaining component such as Forgejo.

Manifest files use a fixed format-version-`1` key/value layout:
`format=`, `component=`, `ubuntu_zombie_version=`, `converged_utc=`,
`component_version=`, and `suboptions=`. They are parsed as data, never
sourced. Malformed or unknown entries are skipped.

A component entry is written only after that component's install has
completed successfully and passed its health checks. It is removed only
after that component's uninstall completes successfully; if cleanup for a
component fails, its manifest entry is retained so later lifecycle
commands can see that the component still needs attention.

## Logs and state

| Path | Purpose |
| ---- | ------- |
| `/var/log/ubuntu-zombie-install.log` | Installer transcript. |
| `/var/log/ubuntu-zombie/install-receipt.txt` | Non-secret install receipt. |
| `/var/log/ubuntu-zombie/audit.log` | JSON-lines audit trail. |
| `/opt/ai-zombie/state/conversations.db` | Chat history. |
| `/opt/ai-zombie/state/lifecycle.json` | TTL/tombstone state. |
| `/opt/ai-zombie/state/logs/` | pi-mono bridge logs. |
