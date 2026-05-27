# Architecture

Ubuntu Zombie turns an Ubuntu Desktop LTS PC into a workstation with a
resident AI Systems Administrator. The whole product is deliberately
small enough to fit in one head: a single installer, a single
uninstaller, one privileged user account, one loopback HTTP service,
one policy file, one audit log.

This document is the canonical map of what the system *is* — every
component, file, boundary, and lifecycle — and how the pieces fit
together. It is kept in lockstep with `scripts/` and `payload/`; if
the code and this document disagree, the code is right and this
document is a bug.

---

## 1. System overview

Ubuntu Zombie has **three layers** that talk to each other over
well-defined, narrow interfaces:

```
┌──────────────────────────────────────────────────────────────────────┐
│ L3  Operator (human)                                                 │
│                                                                      │
│       browser                                          shell         │
│         │                                                │           │
│         │  SSH local-forward  -L 7878:127.0.0.1:7878     │  SSH      │
│         ▼                                                ▼           │
└──────────────────────────────────────────────────────────────────────┘
                              │  Tailscale (WireGuard) — only path in
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ L2  Chat service     systemd unit: ubuntu-zombie-chat.service        │
│                      runs as: zombie  (loopback 127.0.0.1:7878)      │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐     │
│   │ Provider     │  │ Policy gate  │  │ Command runner         │     │
│   │ OpenAI /     │─▶│ policy.yaml  │─▶│ sudo wrapper, timeout, │     │
│   │ Anthropic    │  │ classifier   │  │ stdout/err/exit, retry │     │
│   └──────────────┘  └──────────────┘  └────────────────────────┘     │
│         │                  │                       │                 │
│         ▼                  ▼                       ▼                 │
│    SQLite history     Audit log (JSONL)     Verification follow-ups  │
│    conversations.db   audit.log + logrotate (read-only suggestions)  │
└──────────────────────────────────────────────────────────────────────┘
                              │  sudo (passwordless, log-traced)
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ L1  Host body          provisioned by scripts/install.sh             │
│                                                                      │
│   zombie user (passwordless sudo, docker group)                      │
│   SSH (key-only; Tailscale-only by default)                          │
│   UFW (deny inbound, allow outbound, SSH only on tailscale0)         │
│   Xorg + GDM (optional autologin for zombie)                         │
│   x11vnc on 127.0.0.1:5900 (loopback only, password-protected)       │
│   Docker CE  ·  Node toolchain  ·  Python venv at ~zombie/agent-env  │
│   Playwright + Chromium (browser automation)                         │
│   GUI helpers (gui-env, screenshot, click, type-text, key)           │
│   Health timer: ubuntu-zombie-health.timer  (every 15 min)           │
└──────────────────────────────────────────────────────────────────────┘
```

Each layer is owned by a different principal:

| Layer | Principal | Trust |
|-------|-----------|-------|
| L3 Operator | the human | full |
| L2 Chat service | `zombie` user (unprivileged, with `sudo` allow-list) | gated by `policy.yaml` |
| L1 Host body | `root` (only at install/uninstall/upgrade time) | bounded by `install.sh` |

There is **no remote API surface**. The chat UI binds to `127.0.0.1`
only; the only way in from another machine is an SSH tunnel over
Tailscale, and the only way `root` is exercised is by an operator
running `scripts/install.sh` or `scripts/uninstall.sh`.

---

## 2. Repository layout

The shipped source tree is intentionally flat:

```
ubuntu-zombie/
├── scripts/                          # operator-run, root-required
│   ├── install.sh                    # installer + verify/doctor/repair
│   └── uninstall.sh                  # reverse the installer
├── payload/                          # files copied verbatim to disk
│   ├── agent/                        # → /opt/ai-zombie/agent/
│   │   ├── server.py                 # HTTP server + request lifecycle
│   │   ├── providers.py              # OpenAI / Anthropic abstraction
│   │   ├── policy.py                 # YAML reader + classifier
│   │   ├── runner.py                 # subprocess wrapper + follow-ups
│   │   ├── audit.py                  # JSONL writer + redactor
│   │   ├── history.py                # SQLite conversation store
│   │   ├── examples.md               # prompt library shown in the UI
│   │   └── templates/index.html      # single-page chat UI
│   ├── bin/                          # → /opt/ai-zombie/bin/  (shipped)
│   │   ├── audit-recent              # tail/pretty-print audit.log
│   │   ├── collect-diagnostics       # redacted bug-report bundle
│   │   ├── health-check              # one-shot health summary
│   │   ├── secrets-edit              # safe editor for secrets/env
│   │   ├── setup-agent-venv          # build ~zombie/agent-env
│   │   └── zombie-chat               # print local + tunnel URL
│   ├── etc/policy.yaml               # → /etc/ubuntu-zombie/policy.yaml
│   ├── logrotate/ubuntu-zombie       # → /etc/logrotate.d/ubuntu-zombie
│   └── systemd/                      # → /etc/systemd/system/
│       ├── ubuntu-zombie-chat.service
│       ├── ubuntu-zombie-health.service
│       └── ubuntu-zombie-health.timer
├── tests/smoke.sh                    # non-root syntax / standards checks
├── docs/                             # this directory
├── Makefile                          # lint / test / package targets
└── VERSION                           # single source of truth
```

`install.sh` reads `VERSION` and `payload/` relative to the repository
root, so the installer can be invoked from any working directory.
Nothing else in the repository is copied to the target machine — the
documentation, tests, and CI metadata stay in the checkout.

### 2.1  On-host layout (after `install.sh install`)

```
/opt/ai-zombie/                       # AGENT_USER:AGENT_USER, mode 0755
├── agent/                            # Python chat service source
│   ├── server.py providers.py policy.py
│   ├── runner.py audit.py history.py
│   ├── examples.md
│   └── templates/index.html
├── bin/                              # operator + GUI helpers
│   ├── audit-recent  collect-diagnostics
│   ├── health-check  secrets-edit
│   ├── setup-agent-venv  zombie-chat
│   ├── gui-env       screenshot      # generated inline by install.sh
│   ├── click         type-text       # (they wrap xdotool / scrot)
│   ├── key           agent-shell
├── secrets/                          # mode 0700
│   └── env                           # mode 0600, AGENT_USER:AGENT_USER
├── state/                            # SQLite + scratch (screenshots, etc.)
│   └── conversations.db
├── tools/                            # smoke utilities (e.g. browser-test.py)
├── scripts/                          # reserved for operator add-ons
└── logs/                             # service stdout archives

/etc/ubuntu-zombie/                   # operator-owned config; survives reinstall
└── policy.yaml

/var/log/ubuntu-zombie/               # mode 0750, AGENT_USER:AGENT_USER
└── audit.log                         # JSON lines, rotated weekly × 8

/var/log/ubuntu-zombie-install.log    # mode 0600, root:root (monthly × 4)

/etc/sudoers.d/ubuntu-zombie-<user>   # passwordless sudo for AGENT_USER
/etc/ssh/sshd_config.d/zz-zombie.conf # SSH hardening (key-only, etc.)
/etc/gdm3/custom.conf                 # optional autologin for AGENT_USER
/etc/logrotate.d/ubuntu-zombie        # rotation policy (rendered from payload)
/etc/systemd/system/ubuntu-zombie-chat.service
/etc/systemd/system/ubuntu-zombie-health.service
/etc/systemd/system/ubuntu-zombie-health.timer

~zombie/                              # the agent account
├── .ssh/authorized_keys              # mode 0600, only SSH_PUBLIC_KEY
├── .vnc/passwd                       # x11vnc password (mode 0600)
├── .config/autostart/x11vnc.desktop  # loopback-only x11vnc autostart
└── agent-env/                        # Python venv (Playwright + deps)
```

PATH-friendly symlinks placed by the installer in `/usr/local/bin/`:

```
zombie-chat          → /opt/ai-zombie/bin/zombie-chat
zombie-health        → /opt/ai-zombie/bin/health-check
zombie-diagnostics   → /opt/ai-zombie/bin/collect-diagnostics
audit-recent         → /opt/ai-zombie/bin/audit-recent
secrets-edit         → /opt/ai-zombie/bin/secrets-edit
```

The account name is **configurable** — `ZOMBIE_USER=<name>` overrides
the default `zombie`, in which case `AGENT_HOME` becomes `/home/<name>`
and the sudoers drop-in is renamed accordingly. The legacy
`AGENT_USER` variable is still accepted for upgrades.

---

## 3. Components

### 3.1  `scripts/install.sh`

Single installer with explicit subcommands:

| Subcommand  | Effect                                                      |
|-------------|-------------------------------------------------------------|
| `install`   | Full install. Idempotent: re-running converges to desired state. |
| `verify`    | Read-only state check. Never mutates. Exit non-zero on drift. |
| `doctor`    | Same checks as `verify`, but explains *why* and *how to fix*. |
| `repair`    | Apply known-safe fixes (re-asserts permissions, restarts the chat service, re-allows SSH on `tailscale0`, retries Tailscale login). |
| `uninstall` | Delegates to `scripts/uninstall.sh`.                        |

Design rules:

- **Idempotent.** Every section guards with `if ! command`, `command_exists`, or `install -m … -o …` so re-running converges instead of duplicating state.
- **Retry transient network failures.** `apt`, `curl`, `pip`, `npm`, and `playwright install` are wrapped with exponential backoff.
- **Fail closed.** Missing required env vars under `ZOMBIE_NONINTERACTIVE=1` exit with code 64; bad `secrets/env` permissions abort.
- **Self-documenting.** The header comment lists every honored env var; `--help` prints the same.
- **Resumable.** State lives on disk, not in shell memory, so a half-finished run can be completed by re-invoking `install`.

### 3.2  `scripts/uninstall.sh`

Reverses the installer. Flags:

- `--dry-run` — print every action; mutate nothing.
- `--archive` — tar `~AGENT_USER` and `/opt/ai-zombie/state/` to `/var/backups/` before removal.
- `--yes` — skip interactive confirmations (CI use).
- `--keep-agent` — leave the agent account in place; remove only services and files.

Out of scope: removing Docker, Tailscale, Node, or Python. These are
ordinary Ubuntu packages other things may depend on; the operator
removes them with `apt` if desired.

### 3.3  Chat service (`payload/agent/`)

Run as `AGENT_USER` by `ubuntu-zombie-chat.service`. Bound to
`127.0.0.1:${ZOMBIE_CHAT_PORT}` (default `7878`). Six modules, each
under ~500 lines:

| Module | Responsibility |
|--------|----------------|
| `server.py`     | `ThreadingHTTPServer` + handler; serves the single-page UI and the `/api/*` routes; orchestrates the request lifecycle. |
| `providers.py`  | Backend abstraction over OpenAI and Anthropic; chosen by `ZOMBIE_PROVIDER`, otherwise the first provider with a configured key. Model overrides via `ZOMBIE_MODEL` / `ZOMBIE_OPENAI_MODEL` / `ZOMBIE_ANTHROPIC_MODEL`. |
| `policy.py`     | Dependency-free YAML reader for `policy.yaml`; classifies a command into one of five action classes via ordered `re.search` rules. Re-reads on every classification so the operator can edit without restarting. |
| `runner.py`     | Subprocess wrapper: timeout (`ZOMBIE_COMMAND_TIMEOUT`, default 300s), stdout/err/exit, duration, and a small set of suggested read-only follow-ups (e.g. propose `systemctl status X` after `systemctl restart X`). |
| `audit.py`      | Append-only JSON-lines logger with secret redaction (provider keys, Tailscale auth keys, SSH keys, generic `TOKEN=…` / `Authorization:` patterns). Thread-safe; no SIGHUP needed across logrotate. |
| `history.py`    | SQLite store of conversations and messages, schema created on first run; default path `/opt/ai-zombie/state/conversations.db` (override with `ZOMBIE_HISTORY_DB`). |

HTTP surface (loopback only):

| Method + path                  | Purpose |
|--------------------------------|---------|
| `GET  /` and `/index.html`     | The single-page chat UI. |
| `GET  /api/health`             | Liveness and configured-provider summary. |
| `GET  /api/conversations`      | List conversation ids and titles. |
| `GET  /api/conversation/{id}`  | Fetch one conversation's messages. |
| `GET  /api/audit`              | Recent audit-log entries for the UI panel. |
| `POST /api/message`            | Send a user prompt; receive provider reply + proposed actions. |
| `POST /api/approve`            | Approve a proposed action (with confirmation phrase for `destructive`). |

The UI shows proposed commands inline before they run. Auto-classified
`read_only` commands stream their output back without an extra prompt;
every other class requires an explicit click (and a typed phrase for
`destructive`).

### 3.4  GUI control helpers (generated inline by `install.sh`)

Tiny shell wrappers placed in `/opt/ai-zombie/bin/`. They share
`gui-env`, which exports the right `DISPLAY` and `XAUTHORITY` for the
active GDM session before invoking the underlying tool:

| Helper        | Wraps                              |
|---------------|------------------------------------|
| `screenshot`  | `gnome-screenshot -f <path>` (default `state/screen.png`) |
| `click`       | `xdotool mousemove X Y click 1`    |
| `type-text`   | `xdotool type --delay 10 "$*"`     |
| `key`         | `xdotool key "$@"`                 |
| `agent-shell` | `runuser -l AGENT_USER` shortcut   |

These let the chat service interact with the actual desktop session
when Playwright/Chromium is not the right tool — for example,
controlling a native app the operator has opened.

### 3.5  systemd units (`payload/systemd/`)

- `ubuntu-zombie-chat.service` — long-running. `User=AGENT_USER`,
  `EnvironmentFile=-/opt/ai-zombie/secrets/env`, `Restart=on-failure`,
  loopback-only port from `ZOMBIE_CHAT_PORT` (default 7878). Hardened
  with `ProtectSystem=full`, `PrivateTmp=true`,
  `ProtectKernelTunables/Modules/ControlGroups`, `RestrictRealtime`,
  `RestrictSUIDSGID`, `LockPersonality`. **`NoNewPrivileges` is
  intentionally absent** because the whole product elevates via
  passwordless `sudo` once the policy gate has approved a command —
  `NoNewPrivileges` would block every approved elevation. The policy
  gate is the security boundary, not the systemd sandbox.
- `ubuntu-zombie-health.service` — oneshot. Runs
  `/opt/ai-zombie/bin/health-check` and exits.
- `ubuntu-zombie-health.timer` — fires the health service at
  `OnBootSec=5min` and `OnUnitActiveSec=15min`, `Persistent=true`.

The two service unit files use the literal placeholders
`__AGENT_USER__` and `__AGENT_HOME__`, which the installer substitutes
at deploy time via `sed`. Account-name validation in
`validate_config` (in `install.sh`) refuses the sed-special characters
`|`, `&`, and `\` so this substitution is safe.

### 3.6  Operator helpers (`payload/bin/`)

| Helper                  | Purpose |
|-------------------------|---------|
| `health-check`          | Coloured one-shot summary: chat service active, audit log writable, secrets file mode, Tailscale state, UFW posture, GDM/x11vnc autostart, agent venv present. Used both by humans and by the health timer. |
| `audit-recent`          | Pretty-print the last *N* JSON-lines audit entries (default 25; `--all` for everything). |
| `collect-diagnostics`   | Tar a redacted bundle of logs, unit status, and config for bug reports. Secrets are stripped before write; staging directory is cleaned up under `trap … EXIT` (FIX-3-23). |
| `secrets-edit`          | Open `secrets/env` in `$EDITOR` and re-assert owner + 0600 on exit, success *or* failure. Creates the file with a commented template if missing. |
| `setup-agent-venv`      | Build `~AGENT_USER/agent-env`, install Python deps, and unprivileged Playwright browser binaries. Re-runnable; exponential backoff on transient failures. Called by `install.sh` via `runuser -l AGENT_USER`. |
| `zombie-chat`           | Print local URL and a copy-pasteable SSH local-forward example for remote operators. |

### 3.7  Policy (`payload/etc/policy.yaml`)

Operator-owned, copied into place only when absent so reinstalls
never clobber custom rules. Two top-level sections:

- `settings.destructive_confirmation` — the exact phrase the operator
  must type to authorise a `destructive` command. Defaults to
  `"yes, I understand this is destructive"`.
- `settings.default_class` — the class assigned when no rule matches.
  Defaults to `system_change` (the safe choice: it requires approval).
- `classes` — per-class metadata (`approval: auto|required`,
  `confirm_phrase: true` for `destructive`, free-text `description`).
- `rules` — ordered list of `{ pattern, class }`. Patterns are Python
  `re.search` regexes. **First match wins**, so order matters; see
  `payload/etc/policy.yaml` for the live rules.

### 3.8  Log rotation (`payload/logrotate/ubuntu-zombie`)

- `/var/log/ubuntu-zombie/audit.log` — weekly, keep 8, compressed,
  `create 0640 AGENT_USER AGENT_USER`. The `AGENT_USER` is templated
  in via the `__AGENT_USER__` placeholder (FIX-3-06). The `postrotate`
  hook is intentionally empty: `audit.py` reopens on every append.
- `/var/log/ubuntu-zombie-install.log` — monthly, keep 4,
  `create 0600 root root`.

---

## 4. Request lifecycle

A single chat round-trip is the smallest reasoning unit. Every step
appears in `audit.log` with a shared `approval_id`, so the operator
can trace any state change back to a prompt.

```
Operator                Chat service                            Host
   │                          │                                   │
   │ POST /api/message        │                                   │
   │ {prompt}                 │                                   │
   ├─────────────────────────▶│                                   │
   │                          │ history.append(user, prompt)      │
   │                          │ audit("prompt", …)                │
   │                          │ providers.complete(prompt)        │
   │                          │   ─────── LLM ───────▶            │
   │                          │   ◀── reply + proposed cmds ──    │
   │                          │ for each proposed cmd:            │
   │                          │   class = policy.classify(cmd)    │
   │                          │   audit("proposed", cmd, class)   │
   │                          │                                   │
   │   reply + cmd list ◀─────┤                                   │
   │   (auto-run for          │                                   │
   │   read_only, else        │                                   │
   │   show "Approve"         │                                   │
   │   button)                │                                   │
   │                          │                                   │
   │ POST /api/approve        │                                   │
   │ {approval_id, phrase?}   │                                   │
   ├─────────────────────────▶│                                   │
   │                          │ verify approval (+phrase for      │
   │                          │   destructive)                    │
   │                          │ audit("approved", approval_id)    │
   │                          │ runner.run(cmd, sudo if needed)   │
   │                          │   ─── subprocess ───▶             │
   │                          │   ◀── stdout/stderr/exit ──       │
   │                          │ audit("ran", exit, duration)      │
   │                          │ history.append(assistant, output) │
   │                          │ propose verification follow-ups   │
   │                          │   (always read_only, auto-run)    │
   │   result + follow-ups ◀──┤                                   │
   │                          │                                   │
```

Auto-execution rule: `read_only` commands skip `/api/approve`.
Everything else *must* round-trip through an explicit operator click.
For `destructive`, the operator must type the
`settings.destructive_confirmation` phrase verbatim; the server
compares it case-sensitively before logging the approval.

---

## 5. Action classes

| Class             | Examples                                       | Default policy             |
|-------------------|------------------------------------------------|----------------------------|
| `read_only`       | `ls`, `cat`, `systemctl status`, `df`, `git status`, `docker ps`, safe `find` (no `-delete`/`-exec`/`-ok`/`-fprint*`) | auto                       |
| `user_change`     | `mkdir`, `touch`, `git clone`, `git pull/fetch/checkout/reset`, `git rm`/`git mv` (FIX-3-26), `pip install`, `npm install` | approval                   |
| `system_change`   | `apt install`, `dpkg -i`, `snap install`, `systemctl restart`, `docker run/build`, `chmod`/`chown`, `mv`, plain `rm`, writes under `/etc/` | approval                   |
| `network_change`  | `ufw`, `iptables`, `nft`, `tailscale up/down/set`, `ip link/addr/route set/add/del`, `systemctl restart ssh/tailscaled/networking` | approval                   |
| `destructive`     | `rm -rf /`, `mkfs`, `dd of=/dev/…`, `userdel`, `shred`, `docker system prune`, write to `/dev/sdX`, `find … -delete/-exec/-ok/-fprint*` (FIX-3-03) | approval **+ phrase**      |

Rules are evaluated **in file order**; the first match wins. Two
ordering subtleties enforced by the shipped policy:

1. `git rm`/`git mv` are user-level VCS operations and are matched
   *before* the generic `\brm\s+` / `\bmv\s+` system-change rules, so
   they stay in `user_change` (FIX-3-26).
2. `find` with `-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`,
   `-fprint`, `-fprintf`, or `-fls` is forced to `destructive`
   *before* any `read_only` rule sees it (FIX-3-03). Plain `find`
   without those flags falls into `read_only`.

Unknown commands fall into `settings.default_class` (default
`system_change`), so the safe failure mode is "require approval". Denied
actions are still recorded in the audit log with the reason.

---

## 6. Trust boundaries

The product has five clean trust seams. Each is the smallest possible
interface that achieves its purpose.

### 6.1  Provider boundary

Prompts, selected context, and the text of proposed commands cross to
the configured cloud provider (OpenAI or Anthropic). Command output
may be summarised back to the provider on follow-up turns. Provider
**keys never leave** `secrets/env`: only the chat service reads them,
and they are redacted from every audit-log line before write.

### 6.2  Network boundary

- UFW: `default deny incoming`, `default allow outgoing`.
- SSH: by default allowed only on the `tailscale0` interface
  (`ZOMBIE_SKIP_TAILSCALE=1` opens SSH on every interface, with a loud
  warning logged by `install.sh`).
- Chat service: binds to `127.0.0.1` only. There is no TLS because
  there is no remote listener.
- x11vnc: bound to `127.0.0.1:5900` with `-localhost`, password
  required, autostarted in the agent session.

The only externally reachable port is SSH/22 over Tailscale.

### 6.3  Privilege boundary

The chat service runs as `AGENT_USER`, which has **passwordless
`sudo`** via `/etc/sudoers.d/ubuntu-zombie-<user>`. Every privileged
action follows the same path:

```
proposed cmd → policy.classify → operator approval (UI) → audit("approved")
             → runner.run(sudo …) → audit("ran", exit_code) → verify
```

The approval ID is recorded in the audit log *before* `sudo` is
invoked. A human shell that runs `sudo` directly is logged in
`auth.log` and `audit.log` with **no** approval ID, so AI-initiated
elevations and human-initiated elevations are always distinguishable
after the fact.

Defence in depth: operators who want to constrain the agent further
can layer an AppArmor profile that allows `/usr/bin/sudo` and the
specific binaries they expect the agent to invoke. The product is
designed to coexist with that.

### 6.4  Secrets boundary

- `/opt/ai-zombie/secrets/` — directory, mode 0700, owner `AGENT_USER`.
- `/opt/ai-zombie/secrets/env` — file, mode 0600, owner `AGENT_USER`.
- `server.py` **refuses to start** if `secrets/env` is group- or
  world-readable. Fail closed.
- `audit.py` redacts token-shaped strings on every write: `sk-…`,
  `sk-ant-…`, `tskey-…`, `ssh-(rsa|ed25519|dss) …`, and
  `(API_KEY|TOKEN|PASSWORD|SECRET)=…` (case-insensitive). FIX-3-11
  preserves the original separator (`:` or `=`) on redaction so
  rewritten lines remain syntactically faithful.
- `collect-diagnostics` runs the same redactor before bundling any log
  fragment.
- `secrets-edit` re-asserts mode 0600 and the right owner under
  `trap … EXIT`, even if the editor crashes.

### 6.5  Filesystem boundary

The installer uses `install -m … -o … -g …` rather than `cp` + `chmod`
+ `chown`, so file modes and owners are set atomically with creation.
`AGENT_USER` owns everything under `/opt/ai-zombie/` except the
read-only systemd unit files; `root` owns `/etc/ubuntu-zombie/` and
the systemd units. `/var/log/ubuntu-zombie/` is mode 0750, owned by
`AGENT_USER`, so only the agent and `root` can read the audit log.

---

## 7. Operator surface

Everything an operator needs is reachable from `PATH`:

| Command                 | Reads          | Writes         |
|-------------------------|----------------|----------------|
| `zombie-chat`           | nothing        | stdout (URL + tunnel hint) |
| `zombie-health`         | systemd, FS    | stdout         |
| `audit-recent`          | `audit.log`    | stdout         |
| `secrets-edit`          | `secrets/env`  | `secrets/env` (mode-locked) |
| `zombie-diagnostics`    | logs, unit state, config | `/tmp/ubuntu-zombie-diagnostics-*.tar.gz` |
| `sudo scripts/install.sh verify` | live state | nothing |
| `sudo scripts/install.sh doctor` | live state | nothing |
| `sudo scripts/install.sh repair` | live state | known-safe fixes |

Service control is plain systemd:

```
sudo systemctl status   ubuntu-zombie-chat.service
sudo systemctl restart  ubuntu-zombie-chat.service
sudo journalctl -u      ubuntu-zombie-chat.service -f
sudo systemctl list-timers ubuntu-zombie-health.timer
```

---

## 8. Configuration surface

All configuration is environment variables read at install time, or
plain files read at run time. There is no separate config registry.

### 8.1  Install-time env vars (`scripts/install.sh`)

| Variable                  | Default        | Meaning |
|---------------------------|----------------|---------|
| `ZOMBIE_USER`             | `zombie`       | Agent account name. `AGENT_USER` is a legacy alias. |
| `ZOMBIE_DIR`              | `/opt/ai-zombie` | Workspace root. |
| `ZOMBIE_NONINTERACTIVE`   | `0`            | When `1`, no prompts; `SSH_PUBLIC_KEY` and `VNC_PASSWORD` must be set unless already on disk. |
| `ZOMBIE_ENABLE_AUTOLOGIN` | `0`            | Enable graphical autologin for the agent account. |
| `ZOMBIE_SKIP_TAILSCALE`   | `0`            | Skip Tailscale install/enrol; allow SSH on every interface instead. |
| `ZOMBIE_CHAT_PORT`        | `7878`         | Loopback port for the chat service. |
| `VNC_PORT`                | `5900`         | Loopback port for x11vnc. |
| `LOG_FILE`                | `/var/log/ubuntu-zombie-install.log` | Installer log destination. |
| `SSH_PUBLIC_KEY`          | —              | The single key written to `~AGENT_USER/.ssh/authorized_keys`. |
| `VNC_PASSWORD`            | —              | Initial x11vnc password. |
| `TAILSCALE_AUTHKEY`       | —              | Non-interactive `tailscale up` key; ignored under `ZOMBIE_SKIP_TAILSCALE=1`. |

### 8.2  Runtime env vars (chat service)

Read from `/opt/ai-zombie/secrets/env` via `EnvironmentFile=`:

| Variable                   | Default        | Meaning |
|----------------------------|----------------|---------|
| `OPENAI_API_KEY`           | —              | Enables the OpenAI provider. |
| `ANTHROPIC_API_KEY`        | —              | Enables the Anthropic provider. |
| `ZOMBIE_PROVIDER`          | autodetect     | `openai` or `anthropic`. |
| `ZOMBIE_MODEL`             | per-provider   | Overrides both providers' default models. |
| `ZOMBIE_OPENAI_MODEL`      | `gpt-4o-mini`  | OpenAI default model. |
| `ZOMBIE_ANTHROPIC_MODEL`   | `claude-3-5-sonnet-latest` | Anthropic default model. |
| `ZOMBIE_USER`              | `zombie`       | Identity exposed in the UI and prompts. |
| `ZOMBIE_CHAT_PORT`         | `7878`         | Loopback port. |
| `ZOMBIE_SECRETS`           | `/opt/ai-zombie/secrets/env` | Override path for tests. |
| `ZOMBIE_POLICY`            | `/etc/ubuntu-zombie/policy.yaml` | Override path for tests. |
| `ZOMBIE_AUDIT_LOG`         | `/var/log/ubuntu-zombie/audit.log` | Override path for tests. |
| `ZOMBIE_HISTORY_DB`        | `/opt/ai-zombie/state/conversations.db` | Override path for tests. |
| `ZOMBIE_COMMAND_TIMEOUT`   | `300` (seconds) | Per-command runner timeout. |

See `docs/CONFIGURATION.md` for operator-facing detail.

---

## 9. Failure model and recovery

| Failure                                          | Behaviour                                                                                              |
|--------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| Transient network failure (`apt`/`curl`/`pip`/`npm`/`playwright`) | Retried with exponential backoff inside the installer and `setup-agent-venv`. |
| Installer crash mid-run                          | Re-run `sudo scripts/install.sh install`; idempotent guards converge to desired state.                 |
| Drift from desired state                         | `verify` reports; `doctor` explains; `repair` fixes the known-safe set.                                |
| Provider API outage or auth failure              | Surfaced in the UI as a structured error; the chat service does not crash; other functionality remains. |
| No provider key configured                       | `NoProviderConfigured` raised on first request; UI shows a clear instruction to run `secrets-edit`.    |
| Bad `secrets/env` permissions                    | Chat service fails to start (fail closed); `health-check` and `verify` both flag it.                   |
| Audit log lost to logrotate race                 | `audit.py` reopens on every append; no SIGHUP needed; rotated file is preserved by `delaycompress`.    |
| x11vnc password missing                          | `install.sh` aborts with a clear error before writing autostart entries.                               |
| Tailscale logged out                             | `health-check` flags it; `repair` retries `tailscale up`; SSH-on-tailscale0 keeps working until the link drops. |
| Agent account compromised                        | UFW + Tailscale-only SSH limit blast radius; `secrets/env` is the only credential material on disk; `uninstall.sh --archive` snapshots state before remediation. |

The health timer runs `/opt/ai-zombie/bin/health-check` every 15
minutes (and at boot + 5 min), giving the operator a passive trip-wire
without any extra infrastructure.

---

## 10. Non-goals

To keep the system small and auditable, the following are explicitly
out of scope:

- **Multi-tenant operation.** One host, one operator, one agent
  account. Multi-user isolation belongs to the OS, not to the chat
  service.
- **Remote API.** The chat service is loopback only. Remote access is
  by SSH tunnel; there is no plan for TLS, OAuth, or web auth.
- **Self-upgrading.** Upgrades are `git pull && sudo
  ./scripts/install.sh install`. There is no autoupdater.
- **Custom provider plugins at run time.** New providers are added by
  editing `providers.py` and shipping a release.
- **Generic policy DSL.** `policy.yaml` is intentionally a flat list
  of ordered regex rules — easy to read in one pass, no Turing-complete
  surprises.

---

## 11. Extending the system

Common changes and where to make them:

| Change                                | Where                                                   |
|---------------------------------------|---------------------------------------------------------|
| Tighten / loosen a command class      | `payload/etc/policy.yaml` (live; re-read per request)   |
| Add a provider                        | `payload/agent/providers.py` + entry in `select_provider` |
| Add an HTTP route                     | `payload/agent/server.py` → `do_GET` / `do_POST`        |
| Add an operator helper                | `payload/bin/<name>`, then add to the install loop in `scripts/install.sh` and (optionally) symlink under `/usr/local/bin/` |
| Add a smoke check                     | `tests/smoke.sh` — keep it non-root and fast            |
| Add a host package                    | `apt_install` line in `scripts/install.sh`              |
| Add a systemd unit                    | `payload/systemd/<unit>`, then `render_unit` / `install -m 644` block in `scripts/install.sh` |
| Add a redaction pattern               | `_REDACTORS` in `payload/agent/audit.py` *and* the matching `sed` in `payload/bin/collect-diagnostics` |
| Reserve a new env var                 | Add to the install-time or runtime table in §8 of this document, document in `docs/CONFIGURATION.md`, and read it through `os.environ.get(...)` with a safe default |

The repository's `Makefile` enforces the shared standards:

```
make lint       # shellcheck + bash -n + py_compile
make test       # tests/smoke.sh all
make package    # tar a release bundle into dist/
```

If a change passes `make lint && make test` and the relevant section
of this document still describes reality, the change is ready to
review.
