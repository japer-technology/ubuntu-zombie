# UPGRADE-TO-PI: Adopt `pi-mono` and `pi-ai` as Ubuntu Zombie's agent

> **Directive.** Use of `pi` (the [`pi-mono`](https://github.com/earendil-works/pi)
> harness and its [`pi-ai`](https://github.com/earendil-works/pi) provider
> library) **overrides all other concerns** in the agent layer. Where this
> document conflicts with [`UPGRADE-2.md`](UPGRADE-2.md) or
> [`UPGRADE-3.md`](UPGRADE-3.md) — including their scoping, phasing, or
> feature-flag recommendations — this document wins. Security invariants
> from [`UPGRADE-1.md`](UPGRADE-1.md) and [`SECURITY.md`](../SECURITY.md)
> are the only constraints that remain non-negotiable.

This is the planning document for Ubuntu Zombie's switch to a
`pi-mono` + `pi-ai` agent. It is *analysis only*; no code is changed
by the PR that introduces this file.

Companion documents:

- [`UPGRADE-1.md`](UPGRADE-1.md) — security boundary hardening.
  Phase 1 there (argv-aware classifier, fail-closed default, sudo
  allow-list) is a **hard prerequisite** and is *not* overridden by
  this document.
- [`UPGRADE-2.md`](UPGRADE-2.md) — original scope decision. Read for
  context; its "leave the agent loop alone for now" framing is
  superseded.
- [`UPGRADE-3.md`](UPGRADE-3.md) — the implementation-level analysis
  for a `pi-mono`-backed agent behind a feature flag. Read deeply;
  this document inherits its target architecture, tool taxonomy, and
  defences, but **discards its feature-flag / multi-release migration**
  and **commits to `pi-ai` as the only provider abstraction**.

---

## 1. Executive summary

1. **`pi-mono` is the agent loop. `pi-ai` is the provider layer.**
   There is no second path. The bespoke `provider.chat` + regex
   `extract_commands` loop in `payload/agent/server.py` is replaced,
   not run alongside.
2. **No `ZOMBIE_AGENT_MODE` legacy flag.** UPGRADE-3 §5 proposed
   shipping `legacy` and `tools` side by side for one or more minor
   releases. That is rejected: two parsing paths for "what does the
   LLM want to do" is exactly the footgun this work exists to remove.
   The single, supported mode is `pi`.
3. **`pi-mono` runs as a subprocess of the existing Python chat
   service.** `payload/agent/server.py` keeps ownership of the
   loopback HTTP UI, SQLite history, JSONL audit log, the approval
   workflow, and `payload/agent/policy.py`. It invokes `pi-mono` per
   turn and treats it as the planning + tool-using engine.
4. **The policy gate moves to the tool layer.** Every `pi-mono` tool
   call is wrapped by a Ubuntu Zombie shim that calls
   `policy.classify_tool(name, args)` and routes to the existing
   approval flow when the verdict is not `auto`. UPGRADE-3 §4.4
   stands; this document does not relax it.
5. **`pi-mono` and `pi-ai` are pinned dependencies.** No "track
   latest" mode; bumps are deliberate PRs with smoke-test evidence.
6. **GitHub Issues bridge stays out of scope**, exactly as in
   UPGRADE-2 §5.3 and UPGRADE-3 §7.

The result, from the operator's point of view, is that the chat UI
at `http://127.0.0.1:7878/` still looks the same, but the assistant
plans multi-step work, calls typed tools, and supports the full
provider matrix `pi-ai` exposes — and there is no "old mode" to fall
back to.

---

## 2. Why `pi` overrides all other concerns

The previous two upgrade documents tried to balance several goals:
provider breadth, agent-loop quality, packaging simplicity, backward
compatibility, GMI portability, and operator trust. That balancing
act is the source of UPGRADE-3's feature-flag complexity and
UPGRADE-2's Python-reimplementation suggestion.

This document collapses the trade space:

- **Provider breadth** is solved by `pi-ai`. Stop maintaining a
  bespoke `payload/agent/providers.py`.
- **Agent-loop quality** is solved by `pi-mono`. Stop maintaining
  `extract_commands` and the single-command-per-turn approval flow.
- **GMI compatibility** is a free byproduct of using the same
  upstream artefacts GMI uses; the JSONL session format is GMI's.
- **Packaging simplicity** is solved by the fact that Node is
  already a first-class runtime on the host
  (`scripts/install.sh:761-762, 1239-1240, 1522`). A second runtime
  was the cost UPGRADE-2 was trying to avoid; that cost is already
  paid.
- **Backward compatibility** of the *agent loop* is explicitly given
  up. Backward compatibility of the *operator interface* (loopback
  HTTP chat, approval UX, audit log, secrets file layout, systemd
  unit name, install/upgrade/uninstall semantics) is preserved.

What is *not* overridden:

- The security invariants in [`SECURITY.md`](../SECURITY.md) and
  [`UPGRADE-1.md`](UPGRADE-1.md). The policy gate, fail-closed
  defaults, sudo allow-list, loopback-only listener, root-owned
  config, and audit log are non-negotiable. `pi-mono` adoption does
  not loosen any of these.
- The "no new public listener" and "no internet egress beyond
  configured providers" properties from UPGRADE-3 §6 and §7.
- The argv-aware classifier from UPGRADE-1 §1, which `classify_tool`
  consumes for `shell.run`.

---

## 3. Target architecture

Inherits UPGRADE-3 §3 verbatim. Summary:

```
operator browser ──HTTP──> server.py (Python)
                              │
                              │  per-turn:
                              │   1. append jsonl in
                              │      ${ZOMBIE_DIR}/state/sessions/<id>.jsonl
                              │   2. spawn pi-mono with the session id
                              │      and the Ubuntu Zombie tool bundle
                              ▼
                       pi-mono (Node)
                              │
                              │ tool call →
                              ▼
                  Ubuntu Zombie tool shim
                              │  validate args, classify, gate,
                              │  audit, run, observe
                              ▼
                       Tool observation
                              │
                              ▼
                       pi-mono loop continues
                              │
                              ▼
                  Final assistant message → server.py → UI
```

Key properties (all preserved from UPGRADE-3 §3):

- The HTTP server, the DB, `audit.py`, and `policy.py` do not move.
- `pi-mono` never touches the host directly; every effect goes
  through a Ubuntu Zombie tool shim under policy.
- The session JSONL is the protocol with `pi-mono` and is
  GMI-format compatible.

---

## 4. Concrete change list

This is the same change list as UPGRADE-3 §4, with one structural
simplification: there is no `legacy` branch to keep alive. Each
sub-area is scoped to one focused PR.

### 4.1. Provider layer — replace with `pi-ai`

- **Delete** `payload/agent/providers.py`'s bespoke OpenAI/Anthropic
  client code (147 lines). The Python `provider.chat()` surface is
  retired alongside `extract_commands` (see §4.3).
- **Configure** `pi-ai` from the existing secrets file. Add env
  passthrough for the providers `pi-ai` supports beyond today's two:
  `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`,
  `MISTRAL_API_KEY`, `GROQ_API_KEY`. `ZOMBIE_PROVIDER` accepts the
  new names.
- **Update** `payload/bin/secrets-edit`, `docs/CONFIGURATION.md`,
  and the secrets-file template generated by `scripts/install.sh` to
  document the new variables and the deprecation of the bespoke
  client.
- **Do not** keep a "Python-native fallback" provider. If `pi-mono`
  cannot reach any configured provider, the agent surfaces a clear
  error to the operator. Adding a second code path here is exactly
  the kind of footgun being eliminated.

### 4.2. `pi-mono` runtime

- **Install** `pi-mono` globally via the existing npm step
  (`scripts/install.sh:1239-1240`), pinned to an exact version in a
  new `payload/agent/pi-mono.version` file. `install.sh verify`
  asserts the installed version matches.
- **Pin `pi-ai` the same way** in `payload/agent/pi-ai.version` if
  it is a separately installable artefact; otherwise it is
  transitively pinned through `pi-mono`.
- **Configure** `pi-mono` from a Zombie-owned, root-readable config
  tree (mirrors GMI's `.pi/`):
  - `/opt/ai-zombie/pi/settings.json` — `defaultProvider`,
    `defaultModel`, `defaultThinkingLevel`. Mode `0644`, owner root.
  - `/opt/ai-zombie/pi/APPEND_SYSTEM.md` — Ubuntu Zombie identity
    prompt; renders the same machine-facts block that
    `payload/agent/server.py:render_system_prompt` already produces.
    Mode `0644`, owner root.
- **Confine** `pi-mono`'s working directory and writable paths to
  `${ZOMBIE_DIR}/state/`. It must not be able to reach the
  operator's `$HOME`, the secrets file, or any path outside the
  state tree without going through a tool shim.

### 4.3. Tool surface

Inherits UPGRADE-3 §4.3 verbatim. Recap of the closed tool list:

| Tool                | Wraps                                                    | Default policy class |
|---------------------|----------------------------------------------------------|----------------------|
| `shell.run`         | `payload/agent/runner.py:CommandResult` (`runner.run`)   | computed per-argv    |
| `fs.read`           | `Path.read_text` with an allow-list                      | `read_only`          |
| `fs.write`          | `Path.write_text` with an allow-list                     | `user_change`        |
| `pkg.query`         | `dpkg -s`, `apt-cache policy`                            | `read_only`          |
| `pkg.install`       | `apt-get install -y`                                     | `system_change`      |
| `svc.status`        | `systemctl status / is-active`                           | `read_only`          |
| `svc.control`       | `systemctl start/stop/restart/enable/disable`            | `system_change`      |
| `net.status`        | `ip`, `ufw status`, `tailscale status`                   | `read_only`          |
| `gui.screenshot`    | existing Playwright helper                               | `read_only`          |
| `gui.click`/`type`  | existing Playwright helper                               | `user_change`        |
| `skill.list`/`load` | `payload/agent/skills/`, `/etc/ubuntu-zombie/skills.d/`  | `read_only`          |

`pi-mono`'s built-in `shell` and file-edit tools are **not**
exposed directly. The tool list is locked at process start, and
`pi-mono` is invoked with an explicit allow-list; tools not on that
list are refused. There is no generic `http.get`/`fetch` tool —
internet egress beyond configured providers is forbidden.

Concurrent with this work, `extract_commands` and the
single-command-per-turn approval path are removed. There is no
fallback parser.

### 4.4. Policy gate, audit, history

Inherits UPGRADE-3 §4.4. Concretely:

- `payload/agent/policy.py` gains `classify_tool(name, args) -> str`,
  agreeing with `classify` on `CLASS_ORDER`
  (`payload/agent/policy.py:22`). The old `classify` is *removed*
  with `extract_commands`; its argv-aware logic moves into
  `classify_tool("shell.run", {"argv": ...})`.
- `payload/agent/audit.py:72 log_event` gains a `tool_call` event
  with `tool`, `args_redacted`, `classification`, `decision`,
  `exit`, `duration_ms`, `stdout_sha256`, `stderr_sha256`.
- `payload/agent/history.py:37 History` gains an `events` table (or
  a `tool_calls` column on `messages`) so the UI can render tool
  calls and observations distinctly. Forward-only migration;
  `install.sh upgrade` snapshots `conversations.db` to
  `state/conversations.db.bak.<ts>` before applying.
- `payload/agent/server.py` `_handle_commands` and `approve`
  generalise from "approve this command" to "approve this tool
  call". The wire shape gains a `tool` field; the old `command`
  field is removed in the same PR.

### 4.5. Skills

Inherits UPGRADE-3 §4.5 verbatim:

- Root-owned skills at `/opt/ai-zombie/skills/` (mode `0644`),
  initial set `apt.md`, `systemd.md`, `tailscale.md`, `ufw.md`,
  `docker.md`, `gui.md`.
- Operator-extensible skills at `/etc/ubuntu-zombie/skills.d/`,
  same mode/owner contract as `/etc/ubuntu-zombie/policy.yaml`.
  `install.sh repair` reloads them.
- A skill is included in the system prompt only when its trigger
  words appear in the last N user messages.
- **Skills cannot expand the tool surface.** Adding a tool requires
  a code release.

### 4.6. UI

Inherits UPGRADE-3 §4.6:

- `payload/agent/templates/index.html` renders `tool_call`,
  `tool_observation`, and `pending_tool_call` bubbles. Approve and
  reject buttons attach to specific pending tool calls.
- A per-turn tool-call counter is rendered (see §6 budget).

### 4.7. Installer, packaging, tests

- `scripts/install.sh`:
  - Writes `/opt/ai-zombie/pi/settings.json` and `APPEND_SYSTEM.md`.
  - Runs `npm install -g pi-mono@<pinned>` (and `pi-ai` if
    separate). Idempotent.
  - `verify`: `pi-mono --version` matches `payload/agent/pi-mono.version`.
  - `repair`: re-install at the pinned version, re-render
    `settings.json`, reload skills.
  - `uninstall`: `npm uninstall -g pi-mono` (and `pi-ai`), remove
    `/opt/ai-zombie/pi/`.
- `payload/systemd/ubuntu-zombie-chat.service`: no unit change; the
  Python process is still the foreground service.
- `tests/smoke.sh`: add a non-interactive case driven by a stubbed
  `pi-mono` (or `pi-ai` test provider) that emits a canned tool-call
  sequence; assert audit log and history shape.
- `Makefile`: `make lint`, `make test`, and `make package` continue
  to be the gate. `make package` includes `payload/agent/skills/`
  and the pinned-version files.

---

## 5. Migration (no feature flag)

Override of UPGRADE-3 §5. There is no `ZOMBIE_AGENT_MODE`. The
single supported mode is `pi`. Migration is a single, atomic
release:

1. `install.sh upgrade` runs the forward-only DB migration, with
   the `conversations.db.bak.<ts>` snapshot from §4.4.
2. The systemd unit restarts; the new `server.py` requires the new
   `events` shape, the `pi-mono` binary at the pinned version, and
   `pi-ai` provider credentials. If any of these are missing,
   `install.sh verify` fails and the unit is left in its previous
   state.
3. Existing conversations are preserved; old messages render as
   prose-only (no `tool_call` rows). New turns use the tool-call
   path exclusively.
4. There is no "fall back to the legacy loop" knob. Operators who
   need to roll back use the snapshot taken in step 1 and the
   previous package version, like any other package downgrade.

Rationale: the cost of a parallel `legacy` path — code, tests,
docs, surface area, operator confusion — exceeds the cost of a
single forward migration with an explicit rollback procedure. This
is the concrete way "use of `pi` overrides all other concerns"
shows up at the release-engineering layer.

---

## 6. Defences specific to the multi-tool loop

Inherits UPGRADE-3 §6 verbatim, restated here so this document is
self-contained:

1. **Per-turn tool-call budget.** Configurable in `policy.yaml`
   (`agent.max_tool_calls_per_turn`, default 12). Exceeding the
   budget ends the turn and reports a soft failure.
2. **Per-turn elevated-tool budget.** A smaller budget
   (`agent.max_elevated_calls_per_turn`, default 3) on tool calls
   above `read_only`. Each elevated call still requires per-call
   approval.
3. **Per-conversation token budget.** Carried over from UPGRADE-2
   §7. Secrets-file paths and known sensitive env keys are redacted
   from history snapshots before they enter the prompt.
4. **Skill provenance.** Render the on-disk path of any active
   skill in the UI so prompt injection via a skill is visible.
5. **Closed tool registry.** `pi-mono` invocation includes an
   explicit tool allow-list; new tools require a code release.
6. **No internet egress beyond providers.** No generic
   `http.get`/`fetch` tool.
7. **Per-tool JSON schema.** Calls failing validation are rejected
   pre-classification with an audit event of type
   `tool_call_rejected_schema`.

---

## 7. What this proposal is *not* doing

- **No GitHub Issues bridge.** UPGRADE-2 §5.3 / UPGRADE-3 §7
  territory; separate PR with its own threat model.
- **No replacement of `policy.py`'s class taxonomy.** UPGRADE-1's
  argv-aware classifier is consumed by `classify_tool`.
- **No removal of the Python chat service.** `pi-mono` is a child
  of `server.py`, not a replacement.
- **No new public listener.** The loopback-only property of the
  chat service is preserved.
- **No GMI runner image / blast-radius assumptions.** Ubuntu
  Zombie's threat model is "host the operator owns and trusts to
  fail safe"; `pi-mono` adoption does not import GMI's "the runner
  is the blast radius" assumption.
- **No code in the PR that introduces this document.** This file is
  the only artefact.

---

## 8. Phased delivery

Phase numbering restarts from this document, since the override of
UPGRADE-3 §5 removes the feature-flag staging.

- **Phase 0 — Prerequisites.** UPGRADE-1 §1–§3 (argv-aware
  classifier, fail-closed default, sudo allow-list). Cannot start
  Phase 1 before this lands.
- **Phase 1 — `pi-ai` provider swap.** Replace
  `payload/agent/providers.py` with calls into `pi-ai`. Surface the
  five additional providers via the secrets file and
  `docs/CONFIGURATION.md`. No agent-loop change yet; the legacy
  loop now drives a `pi-ai`-backed provider. This is the only phase
  that is independently revertible.
- **Phase 2 — `pi-mono` installed and wired.** Installer pins and
  installs `pi-mono`; `verify`/`doctor`/`repair`/`uninstall` learn
  about it. The Python `server.py` is rewired to spawn `pi-mono`
  per turn. Tool shims, `classify_tool`, the `events` table, and
  the new UI bubbles all land in this phase. `extract_commands` and
  the single-command approval path are removed in the same PR.
  This is the migration described in §5; it is atomic by design.
- **Phase 3 — Skills.** Ship `payload/agent/skills/*.md` and the
  loader, plus the `/etc/ubuntu-zombie/skills.d/` operator
  extension point.
- **Phase 4 — Hardening pass.** Tighten the per-turn budgets in §6
  based on real-hardware telemetry; revisit the per-turn vs.
  persistent `pi-mono` process question (see §9 Q2).

Each phase is gated by `make lint && make test && make package`.
Phases 2 and onward are *not* independently revertible by feature
flag; rollback uses package downgrade plus the
`conversations.db.bak.<ts>` snapshot.

---

## 9. Open questions

Carried over from UPGRADE-3 §9, with answers tightened by the
"`pi` overrides all other concerns" directive.

1. **Pin `pi-mono` and `pi-ai` at specific versions, or track
   `latest`?** Pin. Deliberate PRs only. Treat upstream like any
   other dependency.
2. **One `pi-mono` process per turn, or a persistent stdio child?**
   Per-turn for Phase 2; revisit in Phase 4 if latency is
   unacceptable. Persistent expands the process-lifecycle surface
   (restart on crash, leaked tool-state between operators) and is
   only justified by measured latency.
3. **Where do `pi-mono` stdout/stderr go?**
   `${ZOMBIE_DIR}/state/logs/pi-mono.<ts>.log`, root-readable only,
   with a logrotate config alongside the existing one. Not in the
   JSONL audit (which stays structured) but on the host for
   incident review.
4. **Same JSONL session format as GMI, or a Zombie superset?**
   Start with GMI's exact format. Add Zombie-specific fields under
   a `zombie` namespace so jq queries from GMI still work.
5. **Expose `pi-mono`'s GitHub tools on the host?** No. The host is
   not a CI runner. A `git` tool that pushes to arbitrary remotes
   is outside the threat model; operators who want git work go
   through `shell.run`-via-`git` and the policy gate.
6. **Retire `extract_commands` (`payload/agent/server.py`)?** Yes,
   in Phase 2, atomically with the cutover. Two parsing paths for
   "what does the LLM want to do" is the footgun this proposal
   eliminates.

---

## 10. TL;DR

- Use `pi-mono` for the agent loop and `pi-ai` for providers. No
  alternative path is shipped.
- Run `pi-mono` as a subprocess of the existing Python chat
  service. `server.py`, `history.py`, `audit.py`, and `policy.py`
  stay, with the tool-layer additions from §4.
- Every `pi-mono` tool call goes through a Ubuntu Zombie shim that
  hits `policy.classify_tool(name, args)` and the existing approval
  flow.
- One atomic migration, gated by `install.sh verify` and the
  `conversations.db.bak.<ts>` snapshot. No `ZOMBIE_AGENT_MODE`
  legacy flag.
- UPGRADE-1 Phase 1 (argv-aware classifier, fail-closed default,
  sudo allow-list) must land first. UPGRADE-1's security
  invariants and the loopback-only property of
  [`SECURITY.md`](../SECURITY.md) are the only constraints that
  override the "use `pi`" directive.
