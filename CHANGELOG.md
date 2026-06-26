# Changelog

All notable changes to Ubuntu Zombie are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses **date-time versioning**: each release is stamped
with its UTC release time as `yyyy.mm.dd.hh.nn.ss`.

## [Unreleased]

### Added
- **Chat-UI password gate and Time-to-Live (TTL) kill switch.** The chat
  service is reachable by every local user on `http://127.0.0.1:7878`, so
  it is now protected by a shared password (the installer asks for it;
  default `braaaains`, stored only as a PBKDF2 hash in
  `secrets/env` as `ZOMBIE_ADMIN_PASSWORD_HASH`). Each install also gets a
  Time to Live (default 7 days, set with `ZOMBIE_TTL_DAYS` or the
  interactive review). Once the TTL elapses — or an operator runs
  `/ttl --die` — the zombie writes a durable tombstone and is permanently
  disabled until the next reinstall. The new `/ttl` chat command shows the
  remaining time, `/ttl <days>` extends it, and `/ttl --die` kills the
  zombie immediately. New server endpoints back it: `GET /api/session`,
  `POST /api/login`, `POST /api/logout`, and `GET`/`POST /api/ttl`. State
  lives in `payload/agent/lifecycle.py`; the password helpers live in
  `payload/agent/auth.py`.

### Changed
- Expanded the in-chat example prompt library with richer inspection,
  recovery, maintenance, security, and Ubuntu Zombie self-operation
  requests.
- The chat interface now includes a top-centre **Logoff** control, a
  `/logout` slash command that reopens the password gate, and a grouped,
  alphabetised `/help` command list.
- The installer now shows the Ubuntu Zombie logo as soon as install mode
  starts, the uninstaller shows the same logo, the default TTL is 7 days,
  and the default chat password is `braaaains`.
- **Zombie Zero default footprint.** Removed the installer/runtime
  surfaces identified in `docs/analysis/ubuntu-zombie-zero.md`: SSH
  server setup, Tailscale, fail2ban/UFW wiring, VNC/x11vnc, graphical
  autologin, Docker, GUI/browser automation, and their built-in skills.
  The product now installs a loopback-only chat surface plus the local
  policy/audit runtime.

### Fixed
- **The installer no longer aborts at "Install verification script" with
  `JSON: unbound variable`.** A generated `verify` line now preserves
  `${JSON}` for runtime evaluation instead of expanding it while
  `install.sh` writes the script under `set -u`.
- **Uninstall now continues cleanup after non-critical host failures.** A
  failed `systemctl daemon-reload`, global npm package removal, or stubborn
  install directory now records an error but no longer prevents later cleanup
  steps such as shim and user removal. Path removals are quoted before passing
  through the dry-run/eval helper, and directory removals are verified before
  printing success.
- **`/whoami` no longer errors when provider configuration is broken or
  incomplete.** The chat UI now calls a dedicated `/api/whoami`
  endpoint, and `/profile` no longer builds itself through `/config`, so
  local identity commands stay available even before a model provider is
  configured.
- **The installer no longer aborts at "Install verification script" with
  `PI_AI_VERSION: unbound variable`.** The generated `verify` script and
  the install-time pin checks referenced `PI_AI_VERSION` and
  `PI_MONO_VERSION`, but those variables were never defined, so under
  `set -u` the installer crashed on line ~2780. They are now read once
  from their source of truth (`payload/agent/pi-ai.version` and
  `payload/agent/pi-mono.version`) and degrade to `unknown` if a pin file
  is missing rather than aborting.
- Clarified provider/model setup in `README.md`, `docs/QUICKSTART.md`,
  and `docs/CONFIGURATION.md`: Ubuntu Zombie reads
  `/opt/ai-zombie/secrets/env`, maps `ZOMBIE_PROVIDER=gemini` to pi-ai's
  `google` provider internally, passes the resolved provider/model to
  `pi` on each turn, and treats `ZOMBIE_MODEL` as taking precedence over
  provider-specific model fallback variables.
- **Approved package installs and `/etc` edits no longer fail with
  "Read-only file system."** The chat service unit ran under
  `ProtectSystem=full`, which read-only bind-mounts `/usr`, `/boot`, and
  `/etc` inside the unit's private mount namespace. Because `sudo` does
  not open a new mount namespace, every approved elevation — including
  `pkg.install` (`apt-get install`) and configuration edits — inherited
  the read-only `/usr` and failed regardless of any live
  `mount -o remount,rw`. `ProtectSystem` is now disabled (`false`) so the
  agent can write `/usr`/`/etc` as its job requires; the policy gate and
  closed tool registry remain the security boundary (same rationale as
  the deliberately-absent `NoNewPrivileges`).
- Periodic post-install health checks now report unhealthy runtime state in
  the journal without leaving `ubuntu-zombie-health.service` failed after the
  timer runs.

### Added
- The installer, `zombie-chat` helper, and browser chat UI now start with
  the full ANSI Shadow `UBUNTU ZOMBIE` wordmark.
- **`payload/README.md`** — a world-class tour of the payload tree: what
  each file is, where the installer deploys it, and the four runtime
  invariants (loopback-only, closed tool surface, policy gate +
  approval, full audit), with Mermaid diagrams for deployment, the
  per-turn tool-call flow, the `agent/` module graph, and the action
  classes.
- Release builds now generate a SLSA provenance attestation, publish it with
  the release assets, and ship `payload/bin/verify-release` so consumers can
  check `SHA256SUMS`, cosign signatures, and provenance in one command.
- Node bridge inputs are now recorded in
  `payload/agent/bridge-dependencies.lock` with source URLs, SHA-256 hashes,
  integrity strings, and license metadata; release builds verify the pins and
  installs consume the checksum-verified tarballs.
- Changing `VERSION` on `main` now triggers the release workflow, creates the
  matching `v<VERSION>` tag when needed, and publishes the release artifacts.
- **`/model` chat command.** The chat UI now lists the models the
  configured provider offers and lets the operator switch between them at
  runtime. `/model` (no argument) lists the provider's catalogue with the
  active model marked `*`; `/model <id>` pins a different model for the
  running chat service. Backed by pi-ai's bundled model catalogue
  (`getModels`) via a new `list_models` op in `pi-ai-bridge.mjs`, the
  `providers.list_models` / `current_model` / `set_active_model` helpers,
  and the `GET /api/models` + `POST /api/model` endpoints. Providers
  without a catalogue (e.g. `lmstudio`) accept a free-form id.
- **Local LLM discovery on the LAN.** On an interactive install,
  `scripts/install.sh install` now scans the host's IPv4 `/24` (all 256
  addresses) for an OpenAI-compatible local LLM server answering on
  `http://<ip>:1234/v1` — LM Studio, Ollama, llama.cpp, etc. — queries
  each responder's `/v1/models`, and offers the advertised models as the
  starting model. Choosing one writes `ZOMBIE_PROVIDER=lmstudio`,
  `ZOMBIE_MODEL`, and `LMSTUDIO_API_KEY` to `secrets/env` and the server's
  base URL to the `pi` custom-provider file `~/.pi/agent/models.json`, so
  the agent loop reaches the local server through a dedicated `lmstudio`
  provider (rather than `openai`, whose base URL the `pi` CLI ignores).
  Best-effort and skipped for `--yes` / non-interactive / non-TTY runs;
  tune with `ZOMBIE_SKIP_LLM_SCAN`, `ZOMBIE_LLM_SCAN_PORT`, and
  `ZOMBIE_LOCAL_LLM_API_KEY`.
- **Interactive install parameter review.** On an interactive terminal,
  `scripts/install.sh install` now opens an editable, branded summary of
  every parameter (agent user, install root, chat/VNC ports, autologin,
  Tailscale, transcript/receipt paths, SSH public key, VNC password)
  before touching the host. Edit any field with validation and re-prompt
  until satisfied, then accept to proceed; `q` cancels without changes.
  Automated runs (`--yes`, `ZOMBIE_NONINTERACTIVE=1`, non-TTY) skip it.
- **Zombie Orchid setup theme.** The setup UI is highlighted in
  `#AC43D9` with compatible accent colours (lighter orchid tint,
  complementary teal, warm magenta) via shared helpers in
  `scripts/lib.sh`. Honours the existing `ZOMBIE_COLOR` / `NO_COLOR`
  policy, so `--no-color` still emits plain text.
- **Install receipt.** Every install writes a human-readable receipt
  with all parameters at start and the outcome (result, duration,
  service status, step counts, next step) at finish; failures append a
  `FAILED` record. Secrets are never written (only an SSH key
  fingerprint and a VNC password set/unset flag). Controlled by
  `ZOMBIE_RECEIPT` (default on) and `ZOMBIE_RECEIPT_FILE` (default
  `/var/log/ubuntu-zombie/install-receipt.txt`).
- **Chat slash commands.** The chat web UI now recognises client-side
  commands (handled in the browser, never sent to the agent): `/help`,
  `/clear`, `/new` (alias `/reset`), `/examples`, `/tools`, `/health`,
  `/status`, `/version`, `/audit`, `/conversations` (alias `/history`),
  `/load <id>`, and `/shortcuts`. Diagnostic commands read the existing
  read-only API endpoints; `/version` is backed by a new
  `GET /api/version` endpoint and the deployed `VERSION` file.
- **Expanded chat command surface.** The web UI now also supports
  `/commands`, `/redraw`, `/sessions`, `/resume`, `/export`/`/save`,
  `/copy`, `/title`, `/retry`, `/undo`, `/branch`, `/compress`,
  `/skills`, `/config`, `/policy`, `/whoami`, `/profile`, `/approve`,
  and `/deny`. Conversation rewinds and retries create new branches so
  the original transcript and audit trail stay intact, and destructive
  approval phrase mistakes keep the pending action available for retry.
- **`install.sh --dry-run`.** Prints the agent user, install root,
  package groups, file paths, and firewall rules that a real
  `install` would change, then exits without modifying the host.
  Works without `sudo`. Usable for change review before granting
  privilege.
- **Step-trace log on installer failure.** A failed
  `scripts/install.sh install` now records the completed sections in
  `<log-file>.steps` and prints the last five plus a recovery hint
  in the error footer, so an operator pasting the failure into an
  issue has both the line number and the install phase.
- **`.deb` packaging.** `make deb` (or `bash scripts/build-deb.sh`)
  produces an installable `ubuntu-zombie_<version>_all.deb` under
  `dist/`. The package stages the source tree under
  `/usr/share/ubuntu-zombie/` and exposes a wrapper at
  `/usr/sbin/ubuntu-zombie`. It deliberately does NOT run the
  installer at apt time. The `prerm` refuses to remove the package
  while the host is still set up (override with
  `UBUNTU_ZOMBIE_FORCE_REMOVE=1`). `debian/` skeleton committed.
- **Signed releases.** `.github/workflows/release.yml` builds the
  source tarball, the `.deb`, an SPDX-JSON SBOM (Syft), per-artifact
  cosign keyless signatures, and `SHA256SUMS`, and uploads everything
  to the matching GitHub Release. Release notes include the cosign
  verify-blob snippet.
- **OpenSSF Scorecard, CodeQL, dependency-review.** New
  `.github/workflows/{codeql,dependency-review,scorecard}.yml`
  cover the Python agent code, the npm bridges, and PR-time
  dependency checks. Scorecard publishes the SARIF for the badge in
  README.
- **CI matrix.** `ci.yml` now runs lint + smoke + pytest on both
  Ubuntu 22.04 (Python 3.10) and Ubuntu 24.04 (Python 3.12). All
  third-party actions are pinned to commit SHAs with the
  human-readable tag in a trailing comment.
- **Integration workflow.** `.github/workflows/integration.yml`
  exercises `scripts/install.sh install --dry-run` on
  `ubuntu-22.04` and `ubuntu-24.04` runners nightly and on demand,
  plus a container-based smoke run.
- **`secrets-edit` backup-on-edit.** A timestamped backup of
  `/opt/ai-zombie/secrets/env` (mode 600, owned by the agent user)
  is written to `/opt/ai-zombie/secrets/backups/` every time the
  editor is opened. The ten most recent are kept; older backups are
  pruned. Empty saves trigger a roll-back hint.
- **Pre-commit hooks.** `.pre-commit-config.yaml` wires up
  shellcheck, shfmt, ruff (+ formatter), standard hygiene hooks,
  and the smoke `syntax`/`python`/`standards` blocks so local
  commits get the same checks CI runs. `ruff.toml` lives at the
  repository root.
- **`pytest` regression suite.** `tests/python/` mirrors the policy
  classification and audit-redaction blocks from `tests/smoke.sh
  python` with a real pytest layout so individual cases can be run
  with `-k`. Both runners stay in CI: smoke is the safety net,
  pytest is the readable surface.
- **Docs.**
  - [`docs/PLATFORMS.md`](docs/PLATFORMS.md) — supported Ubuntu
    versions, architectures, and what is explicitly unsupported.
  - [`docs/FAQ.md`](docs/FAQ.md) — quick answers distilled from
    TROUBLESHOOTING and SECURITY.
  - [`docs/UPGRADING.md`](docs/UPGRADING.md) — version-by-version
    upgrade notes.
  - [`SUPPORT.md`](SUPPORT.md) — discussions vs. issues vs.
    security disclosure routing.
  - [`RELEASE.md`](RELEASE.md) — release cut process for
    maintainers.
  - Research notes under `docs/ALTERNATIVE-*.md`,
    `docs/ALTERNATIVES*.md`, and `docs/SIMILAR.md` moved to
    `docs/research/` with a stub README so the user-facing TOC is
    shorter.
  - README gains CI, CodeQL, Scorecard, Latest-release, and
    Ubuntu-LTS badges and a `.deb` install snippet.
  - TROUBLESHOOTING gains a table mapping symptoms to
    `repair`-vs-`install` fixes.

### Changed
- **Version scheme is now date-time based.** Releases are versioned
  `yyyy.mm.dd.hh.nn.ss` (UTC release timestamp) instead of Semantic
  Versioning. `VERSION`, `RELEASE.md`, `debian/changelog`,
  `.github/workflows/release.yml`, and `README.md` updated accordingly.
- **Tailscale is now off by default.** `scripts/install.sh` no longer
  installs or enrols Tailscale unless you opt in with
  `ZOMBIE_SKIP_TAILSCALE=0`. With the default, inbound SSH is allowed
  on every interface (still key-only and root-disabled); opting in
  restricts inbound SSH to the `tailscale0` interface as before.
  `TAILSCALE_AUTHKEY` is used only when `ZOMBIE_SKIP_TAILSCALE=0`.
  `README.md`, `docs/QUICKSTART.md`, `docs/CONFIGURATION.md`,
  `SECURITY.md`, `docs/FAQ.md`, and `docs/REQUIRES.md` updated, and
  `docs/QUICKSTART.md`/`README.md` now document every parameter the
  installer requires to proceed.

### Fixed
- **Chat memory and command execution in the pi-mono agent loop.** The
  `pi-mono` bridge (`payload/agent/pi-mono-bridge.mjs`) now forwards the
  prior conversation into pi's one-shot `-p` prompt, so the agent
  remembers names and earlier context across turns instead of starting
  fresh every message. It also enables pi's real built-in tools (`read`,
  `bash`, `edit`, `write`, `grep`, `find`, `ls`) instead of passing the
  Python registry's logical names (`fs.read`, `shell.run`, …) — which pi
  does not recognise — together with `--no-builtin-tools`, a combination
  that left the agent with zero usable tools and made it emit
  tool-call-shaped text (e.g. `<|tool_call>call:fs.list{…}`) rather than
  acting. The chat system prompt now describes these built-in tools.
- **Loading a past conversation in the chat UI.** The `/load <id>`
  command now reports unknown ids instead of silently showing an empty
  transcript: `GET /api/conversation/<id>` returns a `404` with an
  `{"error": …}` body for an unknown conversation (and the existing
  `400 bad id` for a non-numeric id), and the chat UI surfaces that
  server message rather than a bare `HTTP 4xx`. Loaded transcripts now
  interleave chat messages and tool events in their recorded
  chronological order — matching the live turn view — instead of
  rendering every message first and bunching all tool calls at the end.
  A smoke test (`tests/smoke.sh python`) guards the conversation
  endpoint's existing / bad-id / not-found responses.
- **`collect-diagnostics` aborted before writing its bundle.** The
  `capture` helper ran each diagnostic command under `set -euo
  pipefail` without guarding its exit status, so the first tool that
  returned non-zero — `systemctl status` of an inactive unit (exit
  3), `docker version` with no daemon, or a `tailscale` binary that
  is not installed — aborted the whole script. The EXIT trap then
  deleted the partial staging directory, leaving no tarball. These
  failures are exactly the broken states an operator runs diagnostics
  to capture. `capture` now swallows the command's exit status (its
  output is still recorded via `2>&1`), so every section is collected
  regardless of individual failures. A smoke test
  (`tests/smoke.sh diagnostics`) guards the behaviour.
- **Installer Node runtime.** `scripts/install.sh` now installs
  Node.js 22.x from the official NodeSource apt repository instead
  of the Ubuntu-archive `nodejs`/`npm` packages. The bundled npm on
  Ubuntu 22.04 / 24.04 (npm 9.x on Node 18) could not self-upgrade to
  `npm@latest`, which now requires Node `^20.17.0 || >=22.9.0`, so
  the "Node runtime" section failed with `EBADENGINE` and aborted
  the install after retries. The NodeSource source is configured
  with a `signed-by` keyring at `/usr/share/keyrings/nodesource.gpg`
  and the `nodejs` package is pinned to the NodeSource origin via
  `/etc/apt/preferences.d/nodejs`. `docs/REQUIRES.md` updated.

### Added
- **Verbose scribe (opt-in debugging).** `payload/agent/audit.py`
  honours `ZOMBIE_AUDIT_VERBOSE=1` to attach a redacted
  `stdout_preview` / `stderr_preview` (default 2 KiB, tunable via
  `ZOMBIE_AUDIT_PREVIEW_BYTES`, hard-capped at 16 KiB) to every
  `tool_call` entry. Existing SHA-256 digests are unchanged so the
  integrity contract holds. Every audit entry now also carries
  `ts_utc` (ISO-8601 UTC) and `pid` so testers can correlate audit
  lines with `journalctl` without timezone math. `payload/bin/audit-recent`
  gained `--follow`/`-f` (tail -F across logrotate) and `-t TYPE`
  filters and now surfaces previews when present. Smoke tests cover
  the redaction round-trip and the always-on `pid` / `ts_utc` fields.
  Documented in `docs/CONFIGURATION.md` and `docs/TROUBLESHOOTING.md`.
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
