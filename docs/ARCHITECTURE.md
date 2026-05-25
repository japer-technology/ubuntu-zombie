# Architecture

Ubuntu Zombie has three layers: a host installer, a privileged local
service, and a thin operator-facing UI. They are deliberately small so
the whole stack fits in one head.

```
┌─────────────────────────────────────────────────────────────────┐
│ Operator (human)                                                │
│   browser  ──SSH tunnel──▶  http://127.0.0.1:7878/             │
│   shell    ──SSH─────────▶  zombie@host                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ loopback only
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Chat service (systemd: ubuntu-zombie-chat.service, user=zombie) │
│   ┌─────────────┐  ┌──────────────┐  ┌─────────────────────┐    │
│   │ Provider    │  │ Policy gate  │  │ Command runner      │    │
│   │ (OpenAI /   │─▶│ policy.yaml  │─▶│ sudo wrapper        │    │
│   │  Anthropic) │  │ action class │  │ stdout/err/exit     │    │
│   └─────────────┘  └──────────────┘  └─────────────────────┘    │
│        │                  │                   │                 │
│        ▼                  ▼                   ▼                 │
│   SQLite history     Audit log (JSONL)   Verification           │
│   conversations.db   audit.log + rotate  scripts                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ Host body — created by install.sh                               │
│   zombie user (passwordless sudo)                               │
│   SSH (Tailscale-only, key-only)                                │
│   UFW (deny inbound, allow on tailscale0)                       │
│   Xorg + GDM, optional autologin                                │
│   x11vnc on 127.0.0.1:5900                                      │
│   Docker CE, Python venv (~zombie/agent-env), Node toolchain    │
│   Playwright + Chromium                                         │
│   GUI helpers (screenshot, click, type, key) under              │
│     /opt/ai-zombie/bin/                                         │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### `install.sh`

Single installer with subcommand dispatch:

- `install` — full install, idempotent.
- `verify` — read-only state check (no mutation).
- `doctor` — explain what is wrong and what would fix it.
- `repair` — apply known-safe fixes (re-asserts permissions, retries
  Tailscale login, restarts the chat service, etc.).
- `uninstall` — delegates to `uninstall.sh`.

### `uninstall.sh`

Reverses install. `--dry-run` lists what would change.
`--archive` tars `/home/zombie` (or whatever name was supplied via
`ZOMBIE_USER`) and `/opt/ai-zombie/state/` to
`/var/backups/` before removal. User data is never deleted without an
explicit confirmation prompt.

### `/opt/ai-zombie/`

Owned by the agent account (`zombie:zombie` by default). Layout:

```
/opt/ai-zombie/
├── agent/               # Python chat service source
│   ├── server.py
│   ├── providers.py
│   ├── policy.py
│   ├── audit.py
│   ├── runner.py
│   ├── history.py
│   ├── templates/
│   └── examples.md
├── bin/                 # Operator helpers (PATH-friendly wrappers)
│   ├── verify
│   ├── health-check
│   ├── audit-recent
│   ├── collect-diagnostics
│   ├── secrets-edit
│   ├── zombie-chat
│   ├── gui-env
│   ├── screenshot
│   ├── click
│   ├── type-text
│   ├── key
│   └── agent-shell
├── secrets/             # mode 0700; secrets/env mode 0600
│   └── env
├── state/               # SQLite history, screenshots, scratch
│   └── conversations.db
├── tools/               # smoke tests
└── logs/                # service stdout/err archives
```

### `/etc/ubuntu-zombie/`

Operator-owned configuration that survives reinstalls:

```
/etc/ubuntu-zombie/
└── policy.yaml          # action classes and approval rules
```

### `/var/log/ubuntu-zombie/`

```
/var/log/ubuntu-zombie/
└── audit.log            # JSON-lines, rotated via /etc/logrotate.d/
```

## Action classes

Defined in `policy.yaml`:

| Class            | Examples                                  | Default policy        |
| ---------------- | ----------------------------------------- | --------------------- |
| `read_only`      | `ls`, `cat`, `systemctl status`, `df`     | auto                  |
| `user_change`    | `mkdir ~/…`, `git clone`                  | approval              |
| `system_change`  | `apt install`, `systemctl restart`        | approval              |
| `network_change` | `ufw …`, `tailscale up`                   | approval              |
| `destructive`    | `rm -rf`, `userdel`, `dd of=`, `mkfs`     | approval + phrase     |

The classifier in `policy.py` matches the proposed command against
allow/deny patterns from `policy.yaml`. If unsure, the command falls
into the most restrictive matching class. Denied actions are recorded
in the audit log with the reason.

## Trust boundaries

1. **Provider boundary** — prompts, selected context, and proposed
   actions cross to the configured cloud provider. Commands and their
   output may be summarised back to the provider for follow-up
   reasoning. Provider keys never leave `secrets/env`.
2. **Network boundary** — UFW denies inbound except SSH on
   `tailscale0`. The chat UI never binds outside `127.0.0.1`.
3. **Privilege boundary** — every privileged action goes through the
   policy gate and is logged with an approval ID before `sudo` is
   invoked. Human shells using `sudo` directly are logged through
   `auth.log`/`audit.log` and are distinguishable from
   AI-initiated actions by the absence of an approval ID.
4. **Secrets boundary** — the chat service refuses to start if
   `secrets/env` is group- or world-readable. The audit log redacts
   token-shaped strings before write.

## Failure model

- Network failures around `apt`, `curl`, `pip`, `npm`, and
  `playwright install` are retried with exponential backoff.
- The installer is resumable: re-running `install` converges to the
  desired state.
- Provider failures are surfaced in the chat UI but do not crash the
  service.
- Bad `secrets/env` permissions fail closed at service start.
