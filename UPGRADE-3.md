# UPGRADE-3: Implementing a `pi-mono`-based agent inside Ubuntu Zombie

This document is the **implementation-level follow-up** to
[`UPGRADE-2.md`](UPGRADE-2.md). UPGRADE-2 argued *whether* Ubuntu Zombie
should adopt the [`pi-mono`](https://github.com/earendil-works/pi) agent
harness used by
[`japer-technology/github-minimum-intelligence`](https://github.com/japer-technology/github-minimum-intelligence)
(GMI), and concluded that the valuable parts are (a) provider breadth,
(b) a real tool-calling loop, and (c) markdown skills — but **not**
GitHub Issues as the UI.

The problem statement attached to this PR is more directive than
UPGRADE-2's framing:

> I want to implement pi mono agent like I have in
> github-minimum-intelligence … I want the Ubuntu Zombie to have the same
> Agentic AI capabilities.

So UPGRADE-3 takes UPGRADE-2's recommendation as a *given* and works the
problem forward: assuming we are going to ship a `pi-mono`-shaped agent
inside Ubuntu Zombie, what does that actually look like in this
codebase, what changes, what breaks, and what is the smallest first PR?

This is still *analysis only*. No code is changed by this PR.

Companion documents:

- [`UPGRADE-1.md`](UPGRADE-1.md) — security boundary hardening.
  Phase 1 there (argv-aware classifier, fail-closed default, sudo
  allow-list) is a **hard prerequisite** for anything below.
- [`UPGRADE-2.md`](UPGRADE-2.md) — scope decision (what to take from
  GMI, what to leave). UPGRADE-3 does not re-litigate §3 of UPGRADE-2.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
  [`docs/VISION.md`](docs/VISION.md),
  [`SECURITY.md`](SECURITY.md) — the constraints that bound the design.

---

## 1. Executive summary

1. **Adopt `pi-mono` directly, do not reimplement it in Python.** Node
   is already a first-class runtime on the host
   (`scripts/install.sh:761-762`, `scripts/install.sh:1239-1240`,
   `scripts/install.sh:1522`), and `pi-mono` is the actual artefact that
   GMI uses. Reimplementing it in Python — the option UPGRADE-2 §5.2
   recommended on packaging grounds — duplicates a moving upstream and
   loses GMI compatibility for the things that *are* worth copying
   (skills, session jsonl format, provider matrix). UPGRADE-2's
   Node-vs-Python recommendation should flip now that we know Node is
   already in the install.
2. **Run `pi-mono` as a subprocess of the existing Python chat
   service**, not in place of it. `payload/agent/server.py` keeps
   ownership of the loopback HTTP UI, the SQLite history, the JSONL
   audit log, the approval workflow, and `policy.py`. It invokes
   `pi-mono` per turn (or as a long-lived stdio child) and treats it as
   a *planning + tool-using* engine whose tool calls are mediated by
   Ubuntu Zombie's policy gate.
3. **The policy gate moves to the tool layer**, exactly as UPGRADE-2
   §5.2 prescribed. `pi-mono`'s tools are wrapped in Ubuntu Zombie
   shims that call `policy.classify_tool(name, args)` and route to the
   existing approval flow when the verdict is not `auto`.
4. **Sessions are dual-written.** `pi-mono`'s native jsonl session goes
   under `${ZOMBIE_DIR}/state/sessions/`; the existing SQLite
   `conversations.db` and `audit.log` continue to be the source of
   truth for the chat UI and the operator's audit. The jsonl is a
   *byproduct* that gives GMI-format portability for free.
5. **No GitHub Issues bridge in this work.** That stays UPGRADE-2 §5.3
   territory: opt-in, separate PR, separate threat model.

The result: from the operator's point of view, the chat UI at
`http://127.0.0.1:7878/` looks the same, but the assistant can now call
tools, multi-step plans actually plan, and the provider list matches
GMI's.

---

## 2. What the current agent does vs. what `pi-mono` does

Numbers below are line counts from this repo as of writing.

| Concern              | Today in Ubuntu Zombie                                                                                          | `pi-mono` (as used by GMI)                                                            |
|----------------------|-----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| Agent loop           | `payload/agent/server.py:260` `App.post_message` → one `provider.chat` call → `extract_commands` regex parse    | Multi-turn tool-calling loop; LLM emits tool calls, harness executes, feeds observations back |
| Tools                | Implicit single tool: "the next fenced shell block in the reply" (`server.py:239` `extract_commands`)            | Explicit, named, schema'd tools (file edit, shell, git, github, skill loaders, etc.)  |
| Providers            | OpenAI, Anthropic (`payload/agent/providers.py:42-87`)                                                          | OpenAI, Anthropic, Google, xAI, OpenRouter, Mistral, Groq                             |
| Session memory       | SQLite (`payload/agent/history.py:37` `History`) + JSONL audit (`payload/agent/audit.py:72` `log_event`)         | One JSONL file per session under `state/sessions/`, committed to git in GMI           |
| Skills               | None                                                                                                            | Markdown skill files loaded into the system prompt on demand                          |
| Policy gate          | `payload/agent/policy.py:48` `Policy.classify` over the raw command string                                       | None (GMI's blast radius is the runner image; we cannot rely on that)                 |
| UI                   | Loopback HTTP on `127.0.0.1:7878`                                                                               | GitHub Issues                                                                         |
| Runtime              | Python venv at `${AGENT_HOME}/agent-env`                                                                        | Node, installed globally (`scripts/install.sh:761-762`)                                |

The **agent loop** row is the central change. The **policy gate** row
is the reason a literal port is unsafe and why we wrap, not replace.

---

## 3. Target architecture

```
operator browser ──HTTP──> server.py (Python)
                              │
                              │  per-turn:
                              │   1. write/append jsonl in
                              │      ${ZOMBIE_DIR}/state/sessions/<id>.jsonl
                              │   2. spawn pi-mono with --session <id>
                              │      and --tools <ubuntu-zombie-tool-bundle>
                              │
                              ▼
                       pi-mono (Node)
                              │
                              │ tool call:
                              │   { "name": "shell.run", "args": {...} }
                              ▼
                  Ubuntu Zombie tool shim (Python helper script
                  invoked over stdio / a localhost UDS)
                              │
                              │  - validate against JSON schema
                              │  - policy.classify_tool(name, args)
                              │  - if not auto: suspend, ask operator
                              │  - else: runner.run(...)
                              │  - audit.log_event(...)
                              │
                              ▼
                       Tool observation
                              │
                              ▼
                       pi-mono continues loop
                              │
                              ▼
                  Final assistant message → server.py → UI
```

Key properties of this shape:

- **The HTTP server, the DB, and `policy.py` do not move.** The agent
  loop is delegated; everything else stays in the existing Python
  process.
- **`pi-mono` never touches the host directly.** Every tool it calls is
  a shim under Ubuntu Zombie's control, so the policy gate sees every
  effect.
- **The session jsonl is the protocol with `pi-mono`.** It is also,
  conveniently, GMI-format-compatible, so a future operator who wants
  to look at their session under git (the GMI mental model) can.

---

## 4. Concrete change list

Each subsection corresponds to a real file (existing or new) and is
sized for one focused PR.

### 4.1. Provider layer

- **Replace** `payload/agent/providers.py` (147 lines, OpenAI +
  Anthropic only) with a thin shim that defers to `pi-ai` for the
  multi-turn planning path.
- **Keep** the synchronous `provider.chat()` surface for the legacy
  path (see §5 "Feature flag") so existing code keeps compiling while
  the tool-calling path is built.
- **Add** env vars to `payload/etc/policy.yaml`,
  `payload/bin/secrets-edit`, and `docs/CONFIGURATION.md`:
  `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`,
  `MISTRAL_API_KEY`, `GROQ_API_KEY`. `ZOMBIE_PROVIDER` accepts the new
  names.
- **Installer** changes are limited to the secret-file template; the
  agent venv already exists, and `pi-ai` ships with `pi-mono`.

### 4.2. `pi-mono` runtime

- **Install** `pi-mono` globally via the existing npm step
  (`scripts/install.sh:1239-1240`), pinned to an exact version in a new
  `payload/agent/pi-mono.version` file, so `install.sh verify` can
  assert the installed version.
- **Configure** `pi-mono` from a Zombie-owned, root-readable config:
  - `/opt/ai-zombie/pi/settings.json` (mode `0644`, owner root) —
    selects `defaultProvider`, `defaultModel`, `defaultThinkingLevel`.
    Mirrors GMI's `.pi/settings.json`.
  - `/opt/ai-zombie/pi/APPEND_SYSTEM.md` (mode `0644`, owner root) —
    the Ubuntu Zombie identity prompt; renders the same machine-facts
    block that `payload/agent/server.py:90` `render_system_prompt`
    already produces.
- **Do not** let `pi-mono` reach the operator's `$HOME` or write
  anywhere outside `${ZOMBIE_DIR}/state/`. Set the working directory
  explicitly when spawning.

### 4.3. Tool surface (the load-bearing decision)

Ship the following tools to `pi-mono`, each as a Ubuntu Zombie shim:

| Tool                | Wraps                                                    | Default policy class | Notes                                                                  |
|---------------------|----------------------------------------------------------|----------------------|------------------------------------------------------------------------|
| `shell.run`         | `payload/agent/runner.py:CommandResult` (`runner.run`)   | computed per-argv    | Argv classification per UPGRADE-1 §1                                   |
| `fs.read`           | `Path.read_text` with an allow-list                      | `read_only`          | Allow-list defaults to `/etc`, `/var/log`, `${ZOMBIE_DIR}`             |
| `fs.write`          | `Path.write_text` with an allow-list                     | `user_change`        | Writes outside the allow-list are rejected pre-policy                  |
| `pkg.query`         | `dpkg -s`, `apt-cache policy`                            | `read_only`          | No need for `shell.run` for the common case                            |
| `pkg.install`       | `apt-get install -y`                                     | `system_change`      | Single tool, single classification                                     |
| `svc.status`        | `systemctl status / is-active`                           | `read_only`          |                                                                        |
| `svc.control`       | `systemctl start/stop/restart/enable/disable`            | `system_change`      |                                                                        |
| `net.status`        | `ip`, `ufw status`, `tailscale status`                   | `read_only`          |                                                                        |
| `gui.screenshot`    | existing Playwright helper (`scripts/install.sh:1397`)   | `read_only`          | Already shipped; surface it                                            |
| `gui.click`/`type`  | existing Playwright helper                               | `user_change`        |                                                                        |
| `skill.list`/`load` | `payload/agent/skills/` and `/etc/ubuntu-zombie/skills.d/` | `read_only`         | Skills are *guidance*, not code                                        |

`pi-mono`'s built-in `shell` tool is **not** exposed directly — only
`shell.run` (the Ubuntu Zombie shim) is. Same for `pi-mono`'s file-edit
tool: replaced by `fs.read`/`fs.write` with a path allow-list.

Lock the tool list at process start. `pi-mono` is invoked with
`--tools <comma-separated>` (or whatever the version-pinned equivalent
flag is) and refuses to load tools not on that list.

### 4.4. Policy gate, audit, history

- `payload/agent/policy.py` gains a sibling to `classify` (line 53):

  ```
  def classify_tool(name: str, args: dict) -> str: ...
  ```

  For `shell.run`, this delegates to the argv-aware classifier from
  UPGRADE-1 §1. For typed tools, it inspects `args` directly — e.g.
  `pkg.install` is always `system_change` regardless of package list;
  `fs.write` looks at `args["path"]` and returns `destructive` for
  paths inside `/etc/ssh`, `/etc/sudoers.d`, `/boot`.

  `classify` (the command-string version) stays for backward compat
  and the legacy path; both must agree on the class taxonomy
  (`CLASS_ORDER` at `policy.py:22`).

- `payload/agent/audit.py:72` `log_event` gets a new event type
  `tool_call` with fields `tool`, `args_redacted`, `classification`,
  `decision`, `exit`, `duration_ms`, `stdout_sha256`, `stderr_sha256`.
  Hashing big outputs keeps the JSONL small; the full output stays in
  history.

- `payload/agent/history.py:37` `History` gets a new `events` table (or
  a `tool_calls` column on `messages`) so the UI can render tool calls
  and observations distinctly from prose. Forward-only migration; the
  existing `conversations.db` is preserved.

- `payload/agent/server.py` `App._handle_commands` (line 304) and
  `App.approve` (line 341) generalise from "approve this command" to
  "approve this tool call". The wire shape grows a `tool` field; the
  current `command` field remains for legacy proposals.

### 4.5. Skills

- Ship root-owned skills at `/opt/ai-zombie/skills/` (mode `0644`).
  Suggested first set: `apt.md`, `systemd.md`, `tailscale.md`,
  `ufw.md`, `docker.md`, `gui.md`. Each is one short markdown file
  describing when to invoke which tools.
- Operator-extensible skills go at `/etc/ubuntu-zombie/skills.d/`,
  same mode/owner contract as `/etc/ubuntu-zombie/policy.yaml`.
  `install.sh repair` reloads them.
- A skill is included in the system prompt only when one of its
  declared trigger words appears in the last N user messages. This
  matches GMI's loading pattern and keeps context size bounded.
- **Skills cannot expand the tool surface.** Adding a tool requires a
  Python change in §4.3 and a release. Skills only steer.

### 4.6. UI

- `payload/agent/templates/index.html` (referenced from
  `server.py:_render_index`, line 416) renders three new bubble types:
  `tool_call`, `tool_observation`, `pending_tool_call`. The "approve"
  / "reject" button moves from the bottom of an assistant message to
  the specific pending tool call.
- A per-turn tool-call counter is rendered (matches §6 budget below).

### 4.7. Installer, packaging, tests

- `scripts/install.sh`:
  - New step: write `/opt/ai-zombie/pi/settings.json` and
    `APPEND_SYSTEM.md`.
  - New step: `npm install -g @earendil-works/pi-mono@<pinned>` (or
    `pi-mono@<pinned>` if the published name differs). Idempotent.
  - `verify`: check `pi-mono --version` matches the pinned file.
  - `repair`: re-install `pi-mono` at the pinned version, re-render
    `settings.json`, reload skills.
  - `uninstall`: `npm uninstall -g pi-mono`, drop `/opt/ai-zombie/pi/`.
- `payload/systemd/ubuntu-zombie-chat.service`: no unit change; the
  Python process is still the foreground service. Add
  `Environment=ZOMBIE_AGENT_MODE=tools` once the feature is the
  default (see §5).
- `tests/smoke.sh`: add a non-interactive case using a fake provider
  (already present for §provider tests) that emits a canned tool-call
  sequence; assert audit log and history shape.
- `Makefile`: `make lint` and `make test` cover the new modules
  automatically; `make package` includes `payload/agent/skills/` and
  `payload/agent/pi-mono.version`.

---

## 5. Migration and feature flag

Ship the new path behind `ZOMBIE_AGENT_MODE`, default `legacy`:

- `legacy` — current `server.py` behaviour, `provider.chat`, single
  command per turn, `extract_commands` regex parse.
- `tools` — `pi-mono` subprocess, tool-calling loop, skills.

Once `tools` is green on real hardware over at least one minor
release, flip the default to `tools`. Keep `legacy` available for one
further minor release, then remove `extract_commands` and the
single-command approval path.

The SQLite schema migration is forward-only; `install.sh upgrade`
snapshots `conversations.db` to `state/conversations.db.bak.<ts>`
before applying the migration, and `install.sh doctor` flags schema
drift.

---

## 6. Defences specific to the multi-tool loop

A tool-calling agent can chain many small actions between operator
turns. The current policy gate sees one command per turn and approves
once; the new one will see many tool calls per turn. Defences:

1. **Per-turn tool-call budget.** Configurable in `policy.yaml`
   (`agent.max_tool_calls_per_turn`, default 12). Exceeding the budget
   ends the turn and reports a soft failure to the operator. Surface
   the count in the UI.
2. **Per-turn elevated-tool budget.** A separate, smaller budget
   (`agent.max_elevated_calls_per_turn`, default 3) on tool calls
   classified above `read_only`. The first elevated call still needs
   per-call approval; the budget is the upper bound on how many such
   approvals can occur between two operator messages.
3. **Per-conversation token budget.** Carried over from UPGRADE-2 §7;
   redact secret-file paths and known sensitive env keys from history
   snapshots before they enter the prompt.
4. **Skill provenance.** Skills under `/opt/ai-zombie/skills/` are
   shipped by the package; skills under `/etc/ubuntu-zombie/skills.d/`
   are operator-installed. Render the source path in the UI when a
   skill is active so prompt injection via a skill is visible.
5. **Tool registry is closed.** `pi-mono` is invoked with an explicit
   tool allow-list. New tools require a code release; the LLM cannot
   ask the harness to "also use" a tool that wasn't pre-registered.
6. **No internet egress beyond providers.** `pi-mono` is configured
   with no http/fetch tool. If a future skill needs `apt update`, that
   goes through `pkg.install`/`shell.run` and the policy gate, not via
   a new generic `http.get` tool.
7. **Per-tool argument schema.** Every tool ships a JSON schema; calls
   that fail validation are rejected before classification, with an
   audit event of type `tool_call_rejected_schema`.

---

## 7. What this proposal is *not* doing

To be explicit about scope, by symmetry with UPGRADE-2 §9:

- **No GitHub Issues bridge.** That stays UPGRADE-2 §5.3 territory and
  must be a separate PR with its own threat model.
- **No replacement of `policy.py`'s class taxonomy.** UPGRADE-1's
  argv-aware classifier is a hard prerequisite; UPGRADE-3 *consumes*
  it via `classify_tool`. Both must agree on `CLASS_ORDER`
  (`policy.py:22`).
- **No removal of the Python chat service.** `pi-mono` is a child of
  `server.py`, not a replacement. The HTTP UI, SQLite history, JSONL
  audit, approval workflow, and systemd unit all stay.
- **No new public listener.** The loopback-only property of the chat
  service (`docs/ARCHITECTURE.md`,
  [`SECURITY.md`](SECURITY.md)) is preserved.
- **No code in this PR.** This file is the only artefact.

---

## 8. Phased delivery

Phase numbers continue from UPGRADE-2 §6.

- **Phase 0 — Prerequisites.** UPGRADE-1 §1–§3 (argv-aware classifier,
  fail-closed default, sudo allow-list). Cannot start UPGRADE-3 work
  before this lands.
- **Phase A — Provider shim (≈ UPGRADE-2 §5.1).** Replace
  `payload/agent/providers.py` with a `pi-ai`-backed shim; add the
  five missing providers; update secrets template, docs, CI. No agent
  loop change. Reversible.
- **Phase B — `pi-mono` installed but unused.** Installer step adds
  `pi-mono` at the pinned version. `verify`/`doctor`/`repair`/
  `uninstall` learn about it. `ZOMBIE_AGENT_MODE` defaults to
  `legacy`. This phase is pure plumbing; useful because it surfaces
  Node/version issues on real hardware before any behaviour change.
- **Phase C — Tool shims and policy.classify_tool.** Ship `tools.py`,
  `agent.py`, the `classify_tool` extension, the `events` table, and
  the templated UI for tool calls. `ZOMBIE_AGENT_MODE=tools` is
  available behind the flag.
- **Phase D — Skills.** Ship `payload/agent/skills/*.md` and the
  loader. Documented operator extension point at
  `/etc/ubuntu-zombie/skills.d/`.
- **Phase E — Flip the default.** After Phase C+D have been green on
  real hardware for ≥ one minor release, `ZOMBIE_AGENT_MODE=tools`
  becomes the default. The legacy path stays one further minor
  release, then is removed.
- **Phase F — (Out of scope here.)** UPGRADE-2 §5.3 GitHub Issues
  bridge, if and only if there is operator demand and Phase E is
  stable.

Each phase is independently shippable, independently revertible, and
gated by `make lint && make test && make package`.

---

## 9. Open questions

These changed since UPGRADE-2; deciding them shapes Phases A–E.

1. **Pin `pi-mono` at a specific version, or track `latest`?**
   Recommendation: pin. Treat upstream `pi-mono` releases like any
   other dependency — bumped in a deliberate PR with smoke-test
   evidence — not as a moving target the operator's host quietly
   follows.
2. **One `pi-mono` process per turn, or a persistent stdio child?**
   Per-turn is simpler and matches GMI's per-event spawn; persistent
   is faster but expands the surface (process lifecycle, restart on
   crash, leaked tool-state between operators). Recommendation:
   per-turn for v1, revisit if latency is unacceptable.
3. **Where do `pi-mono` stdout/stderr go?** Both should be captured
   to `${ZOMBIE_DIR}/state/logs/pi-mono.<ts>.log` (root-readable
   only), with a logrotate config alongside the existing one. They
   are not in the JSONL audit (which stays structured), but they are
   on the host for incident review.
4. **Same JSONL session format as GMI, or a Zombie superset?**
   Recommendation: start with GMI's exact format; add Zombie-specific
   fields under a `zombie` namespace so jq queries from GMI still
   work. Keeps a future "import GMI session into Zombie" or
   "summarise this session as a GMI-style artefact" trivial.
5. **Do we expose `pi-mono`'s GitHub tools at all on the host?**
   Recommendation: no. The host is not a CI runner; a `git` tool that
   pushes to arbitrary remotes is well outside Ubuntu Zombie's
   threat model. If an operator wants the agent to touch a repo on
   the host, that goes through `shell.run` with `git` and is gated
   like any other command.
6. **Retire `extract_commands` (`server.py:239`) entirely after Phase
   E, or keep behind the legacy flag indefinitely?** Recommendation:
   remove it. Two parsing paths for "what does the LLM want to do"
   is exactly the kind of footgun the new architecture is meant to
   eliminate.

---

## 10. TL;DR

- Adopt `pi-mono` itself, not a Python re-implementation: Node is
  already installed (`scripts/install.sh:761-762, 1239-1240, 1522`),
  and GMI compatibility is worth keeping.
- Run it as a subprocess of the existing Python chat service; do not
  replace `server.py`, `history.py`, `audit.py`, or `policy.py`.
- Every `pi-mono` tool call goes through a Ubuntu Zombie shim that
  hits `policy.classify_tool(name, args)` and the existing approval
  flow. The policy gate moves from "one command per turn" to "every
  tool call".
- Add the five missing providers via `pi-ai` first (Phase A); install
  `pi-mono` second (Phase B); wire tool-calling third (Phase C); ship
  skills fourth (Phase D); flip the default last (Phase E). Issues
  bridge stays out of scope.
- UPGRADE-1 Phase 1 must land first. Without it, this proposal makes
  the policy gate's blast radius worse, not better.
