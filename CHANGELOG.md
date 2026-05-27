# Changelog

All notable changes to Ubuntu Zombie are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Phase 4 of `docs/UPGRADE-TO-PI-PLAN.md` — hardening pass:
  - **P4.1** Per-turn budget defaults realigned with
    `docs/UPGRADE-TO-PI.md` §6.1–§6.2 (`max_tool_calls_per_turn` 12,
    `max_elevated_calls_per_turn` 3) in `payload/etc/policy.yaml` and
    `payload/agent/policy.py`. `server.py` now enforces
    `max_elevated_calls_per_turn` and `pi_mono.py` emits a uniform
    synthetic `budget_exceeded:` observation when either budget is
    exceeded; the synthetic observation is recorded in the JSONL audit
    (`decision="budget_exceeded"`) and the history `events` table.
    `tests/smoke.sh` gained regression tests against
    `tests/fixtures/stub-pi-mono.mjs` that drive both budgets through
    the soft-failure path. `docs/CONFIGURATION.md` updated.
  - **P4.2** Persistent `pi-mono` evaluated and declined (no-go).
    Rationale recorded in `docs/UPGRADE-TO-PI-PLAN.md` §11; no code
    change.
- Phase 2 of `docs/UPGRADE-TO-PI-PLAN.md` — atomic cutover from the
  fenced-bash parser to the `pi-mono` agent loop:
  - **P2.1** Pinned `@earendil-works/pi-coding-agent` via
    `payload/agent/pi-mono.version`; installer runs `npm install -g`
    against the pinned version and `verify` asserts the pin.
  - **P2.2** Closed 13-tool registry in `payload/agent/tools.py`
    (`shell.run`, `fs.read`, `fs.write`, `pkg.query`, `pkg.install`,
    `svc.status`, `svc.control`, `net.status`, `gui.screenshot`,
    `gui.click`, `gui.type`, `skill.list`, `skill.load`) with per-tool
    schema validation, path allow-lists for filesystem tools, and
    fail-closed dispatch.
  - **P2.3** Additive history schema migration in
    `payload/agent/history.py` via `PRAGMA user_version`, with a
    pre-migration snapshot saved to
    `state/conversations.db.bak.<ts>`. New `events` table records
    structured `tool_call`/`tool_observation`/`pending_tool_call`
    events for the UI replay.
  - **P2.4** Node bridge (`payload/agent/pi-mono-bridge.mjs`) wraps
    `pi --mode json --no-builtin-tools --tools <names>` and speaks a
    line-delimited JSON protocol to the Python client
    (`payload/agent/pi_mono.py`). `ZOMBIE_PI_MONO_BRIDGE` lets the
    smoke suite swap in `tests/fixtures/stub-pi-mono.mjs`.
  - **P2.5** Per-tool approval UI: `payload/agent/templates/index.html`
    replaces `renderProposal` with `tool_call`/`tool_observation`/
    `pending_tool_call` renderers, a per-turn budget counter, and
    `tool_call_id`-keyed approval POSTs.
  - **P2.6** New `policy.yaml` blocks (`tool_classes:` and
    `agent: max_tool_calls_per_turn / max_elevated_calls_per_turn`),
    classified via `policy.classify_tool`. Audit log gains
    `log_tool_call(...)` recording SHA-256 + byte count of stdout/
    stderr (never raw content), plus extended sensitive-env redaction.
  - Installer + `uninstall.sh` updates: deploy `pi-mono-bridge.mjs`,
    render `/opt/ai-zombie/pi/{settings.json,APPEND_SYSTEM.md}`,
    create `state/logs/` and `state/pi-mono-sessions/`, snapshot the
    DB before migration, add pi-mono checks to `verify`, re-render
    pi configs from `cmd_repair`, and prompt to remove the global
    `@earendil-works/pi-coding-agent` package on uninstall.

### Added
- `LICENSE`, `CODE_OF_CONDUCT.md`, and `.editorconfig` so the repository
  metadata matches the documented GitHub project layout.
- Smoke coverage and CI checks for required repository metadata and the
  release package source bundle.
- `ZOMBIE_USER` env var to choose the local Linux account name used as
  the operating identity of the AI Systems Administrator. The legacy
  `AGENT_USER` is still honoured as a backward-compatible alias.
- Phase 0 of `docs/UPGRADE-TO-PI-PLAN.md` (the security prerequisites
  Phase 2 depends on):
  - **P0.1** Argv-aware classifier in `payload/agent/policy.py`. The
    classifier now splits pipelines/sequences, strips leading
    `VAR=value` env prefixes and `sudo` flags, and re-applies every
    rule to the canonical argv in addition to the rendered whole
    command. This catches `LC_ALL=C ls`, `sudo -u root systemctl …`,
    and `rm -rf "/quoted path"` that the legacy regex-only matcher
    missed.
  - **P0.2** Fail-closed default: `settings.default_class` ships as
    `destructive` so unknown commands cannot auto-run. Documented in
    `docs/CONFIGURATION.md`.
  - **P0.3** `sudo_allow_list:` in `payload/etc/policy.yaml` keeps
    common privileged targets (`apt`, `systemctl`, `ufw`, `tailscale`,
    …) at `system_change` despite the conservative default. Documented
    in `docs/CONFIGURATION.md`.

### Changed
- The agent account created by the installer is now called `zombie` by
  default (previously `agent`). The name is overridable at install time
  via `ZOMBIE_USER`, and is propagated to the sudoers drop-in, the
  systemd `User=`/`Group=` of `ubuntu-zombie-chat.service`, the venv
  ownership, the SSH `AllowUsers` line, and the chat service system
  prompt. Existing installs are unaffected — re-run the installer with
  `ZOMBIE_USER=agent` (or `AGENT_USER=agent`) to keep the old name.

## [0.2.0] - 2026-05-24

### Added — MVP product loop
- Subcommand dispatch on `install.sh`:
  `install`, `verify`, `doctor`, `repair`, `uninstall`.
- Separate `uninstall.sh` with `--dry-run` and `--archive`
  modes that remove sudoers drop-ins, SSH drop-ins, x11vnc autostart,
  the chat systemd service, generated helpers, and (optionally) the
  `agent` user. User data under `/home/agent` and
  `/opt/ai-zombie/state/` is only deleted with explicit confirmation.
- Stronger preflight: detect free disk and memory, DNS resolution,
  `apt`/`dpkg` lock contention, conflicting display managers, public-SSH
  install path, and an existing Tailscale login.
- Retry with exponential backoff around `apt-get`, `curl`, `pip`, `npm`,
  and `playwright install`.
- `ZOMBIE_ENABLE_AUTOLOGIN` opt-in for graphical autologin (default off).
  The installer documents the trade-off and verifies the choice.
- Policy file `/etc/ubuntu-zombie/policy.yaml` with the action classes
  `read_only`, `user_change`, `system_change`, `network_change`,
  `destructive`. Defaults require approval for anything beyond read-only
  diagnostics and require an extra confirmation phrase for destructive
  actions.
- JSON-lines audit log at `/var/log/ubuntu-zombie/audit.log` with
  `logrotate` rules. Every prompt, proposed action, approval decision,
  command, exit code, and verification result is recorded. Secrets are
  redacted before logging.
- Local web chat service bound to `127.0.0.1`, served from
  `/opt/ai-zombie/agent/`. SQLite conversation history under
  `/opt/ai-zombie/state/conversations.db`. The conversation survives
  process restart.
- Provider abstraction with `openai` and `anthropic` backends, selected
  via `ZOMBIE_PROVIDER`. A clear error is raised if no provider is
  configured.
- Approval gate before privileged or destructive commands; safe-command
  runner that captures stdout, stderr, exit code, and proposed follow-up
  checks.
- systemd unit `ubuntu-zombie-chat.service` running as `agent`.
- Helper scripts under `/opt/ai-zombie/bin/`:
  - `zombie-chat` — print the chat URL and Tailscale tunnel example.
  - `audit-recent` — pretty-print recent audit entries.
  - `health-check` — single-command health summary (agent service,
    Tailscale, SSH, firewall, Docker, desktop, provider token, disk).
  - `collect-diagnostics` — collect logs and state into a redacted
    bundle in `/tmp/`.
  - `secrets-edit` — safe editor wrapper that re-asserts `0600`.
  - `doctor`, `repair` — wrappers around the installer subcommands.
- Optional systemd timer `ubuntu-zombie-health.timer` that runs
  `health-check` every 15 minutes.
- First-run status summary printed at the end of `install`, with the
  exact next command for each pending step.
- Safe example prompts shipped in `/opt/ai-zombie/agent/examples.md`
  and exposed in the chat UI.

### Added — packaging and developer ergonomics
- `VERSION` file consumed by the installer.
- `Makefile` with `lint`, `test`, `install-local`, `verify`, `package`.
- GitHub Actions CI: ShellCheck on shell scripts, `bash -n` syntax
  checks on the installer and all generated helpers, secret-pattern
  scan, Python syntax check on the chat service, and Markdown link
  sanity.
- `.gitignore` covering logs, state, screenshots, virtualenvs,
  `node_modules`, Debian build artifacts, and editor files.

### Added — documentation
- `VISION.md` — the one-sentence MVP promise.
- `QUICKSTART.md` — install in the shortest safe path.
- `CONFIGURATION.md` — provider keys, Tailscale, VNC, chat access.
- `TROUBLESHOOTING.md` — apt locks, Tailscale, Docker group, desktop
  automation, Playwright, VNC, secrets permissions.
- `ARCHITECTURE.md` — components and trust boundaries.
- `SECURITY.md` — trust boundary, what the provider sees, rotation,
  revocation, known risks, responsible disclosure.
- `CONTRIBUTING.md` — how to test and change the installer.
- `ROADMAP.md` — post-MVP ideas extracted from the possibility docs.
- README rewritten as a concise front door pointing to the new docs.

### Changed
- `install.sh` reads the version from the `VERSION` file at the
  repository root when present.
- Graphical autologin is no longer enabled by default; the installer
  prints the recommended override when the choice matters for
  desktop-automation flows.

## [0.1.0] - 2025-Q4

### Added
- Initial proof-of-concept installer (`install.sh`) that creates
  the `agent` user, configures passwordless sudo, hardens SSH,
  installs Tailscale + UFW, forces Xorg + autologin, installs Docker,
  Python and Node runtimes, Playwright + Chromium, GUI automation
  tools, and a loopback-only x11vnc desktop, plus an end-of-install
  verification script.
