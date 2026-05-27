# UPGRADE-2: Bring the `github-minimum-intelligence` workflow + Pi (`pi-mono`) agent capabilities to Ubuntu Zombie

This document analyses what it would take to give Ubuntu Zombie the same
"Agent AI capabilities" as
[`japer-technology/github-minimum-intelligence`](https://github.com/japer-technology/github-minimum-intelligence)
(hereafter **GMI**), which is built on the
[`earendil-works/pi`](https://github.com/earendil-works/pi) agent harness
(hereafter **Pi** / `pi-mono`).

It is *analysis only*: no code is changed by this PR. The intent is to
argue about scope, fit, and tradeoffs **before** any of it is built. If
only one section is read, read [§3 "What 'same as GMI' really means
here"](#3-what-same-as-gmi-really-means-here) — copying GMI literally
into Ubuntu Zombie would break Ubuntu Zombie's promise. The interesting
question is *which* GMI capabilities transfer, and how.

Companion documents:

- [`UPGRADE-1.md`](UPGRADE-1.md) — the prior, security-focused upgrade
  list. The Phase 1 items there (argv-aware classifier, fail-closed
  default, sudo-allow-list, etc.) are **prerequisites** for anything in
  this document, because a Pi-style multi-tool agent makes the policy
  gate's blast radius much larger.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the existing L1/L2/L3
  layering this proposal has to slot into.
- [`docs/VISION.md`](docs/VISION.md) — the promise this proposal must
  not violate ("a normal Ubuntu PC with an administrator inside it",
  not "a hosted service").

---

## 1. Executive summary

GMI and Ubuntu Zombie solve **different problems with overlapping
shapes**:

| Dimension          | GMI                                              | Ubuntu Zombie                                                   |
|--------------------|--------------------------------------------------|-----------------------------------------------------------------|
| Where it runs      | GitHub Actions (ephemeral CI runners)            | A specific Ubuntu Desktop LTS PC (long-lived host)              |
| Conversational UI  | GitHub Issues + comments                         | Local loopback HTTP chat at `127.0.0.1:7878`                    |
| Persistence        | Git commits in the repo (`state/sessions/*.jsonl`) | SQLite DB + JSONL audit log on the host                       |
| Agent runtime      | `pi-mono` (Node, multi-tool harness)             | Bespoke ~1,400-line Python service (`payload/agent/*.py`)       |
| Tool surface       | Code-edit, git, GitHub API, file IO              | `bash -c`, sudo, host introspection, GUI automation (Playwright)|
| LLM providers      | 7+ (OpenAI, Anthropic, Gemini, xAI, OpenRouter, Mistral, Groq) | 2 (OpenAI, Anthropic) via `payload/agent/providers.py` |
| Trust boundary     | Repo collaborators with write access             | Local `zombie` Unix user + Tailnet + policy gate                |
| Audit              | Git log                                          | `audit.log` (JSONL) + logrotate                                 |
| Update mechanism   | Self-installing workflow that re-fetches itself  | `scripts/install.sh install \| repair \| upgrade`               |

So "make Ubuntu Zombie use Pi" is **three separable** decisions, and
they should be argued separately. In rough order of value-per-risk:

1. **Replace `payload/agent/providers.py` with `@earendil-works/pi-ai`
   (or its Python equivalent)** — pure win on provider coverage and
   maintenance, low blast radius. (See §5.1.)
2. **Replace the bespoke prompt/response loop with a Pi-style
   tool-calling agent (`pi-agent-core`)** — bigger change, but the right
   shape for Ubuntu Zombie's actual job (multi-step diagnose → propose →
   verify). The policy gate has to be re-applied at the *tool* layer
   rather than at the "one bash command per turn" layer. (See §5.2.)
3. **Add an *optional*, off-by-default GMI-style GitHub-Issues control
   plane** — a second front door to the same agent so an operator can
   drive Ubuntu Zombie from a phone/laptop via an issue thread in a
   private repo. This is interesting but it punches a hole through the
   "no public inbound exposure" property and must be explicitly opted
   into. (See §5.3.)

**Recommendation:** do (1) now (it's an internal refactor), do (2) as a
designed v2 of the agent behind a feature flag, **gate (3) behind an
explicit opt-in and treat it as a separate product mode**, not the
default.

---

## 2. What GMI actually is (so we don't copy the wrong thing)

GMI's design, from
[`github-minimum-intelligence-agent.yml`](https://github.com/japer-technology/github-minimum-intelligence/blob/main/.github/workflows/github-minimum-intelligence-agent.yml)
and its README:

1. **One workflow file** is installed into the user's repo.
2. **Triggers**: `issues: [opened]`, `issue_comment: [created]`,
   `workflow_dispatch` (self-install / upgrade).
3. **Permissions**: `contents: write`, `issues: write`, `actions:
   write`. Only collaborators with write access can trigger it.
4. **Each run** is a fresh ephemeral GitHub Actions runner that:
   - Looks up the issue → `state/issues/<N>.json` → session jsonl path.
   - Spawns `pi-mono` with the prior session loaded.
   - Lets the agent think, call tools, edit files, and reply.
   - Commits session updates + any file edits.
   - Posts the reply as an issue comment.
5. **Memory** = git. There is no DB, no server, no queue.
6. **Tooling** = whatever `pi-mono` ships with: file edit, shell, git,
   GitHub API. Skills are markdown files in
   `.github-minimum-intelligence/skills/` and are composable.

GMI's *cleverness* is not the LLM or even Pi — it is the **storage
choice**: the repo is both the workspace and the memory, so the user
already owns and can audit everything by reading `git log`.

The corresponding "storage choice" for Ubuntu Zombie is **the machine
itself** — its filesystem, package DB, systemd, and audit log. That
asymmetry is the core of why a literal port doesn't make sense.

`pi-mono` itself is the genuinely portable piece: a tool-calling agent
runtime (`@earendil-works/pi-agent-core`), a multi-provider client
(`@earendil-works/pi-ai`), and a markdown-skill system. Those are useful
to Ubuntu Zombie *independent* of Issues-as-UI.

---

## 3. What "same as GMI" really means here

Reading the problem statement charitably, "same Agent AI capabilities"
decomposes into five capabilities that GMI clearly demonstrates:

| GMI capability                                                  | Already in Ubuntu Zombie?                                                                                                  | Gap                                                                                                                                  |
|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| **C1 — Multi-provider LLM access**                               | Partial. `payload/agent/providers.py` supports OpenAI + Anthropic only.                                                    | Add Gemini, xAI, OpenRouter, Mistral, Groq. Pi-ai already does this; reuse it.                                                       |
| **C2 — Tool-calling agent loop** (think → call tool → observe → reply) | No. Today the LLM produces text; the server regex-extracts a single shell command and either runs it or asks for approval. | Adopt a real tool-calling loop, where "run a shell command" is one of several tools (others: `read_file`, `edit_file`, `screenshot`, `policy_check`). |
| **C3 — Persistent, inspectable session memory**                   | Partial. `history.py` writes SQLite + `audit.py` writes JSONL.                                                              | The data is there but it isn't a Pi-style session jsonl that can be replayed by the harness. Either expose an export, or migrate.    |
| **C4 — Composable, user-extensible skills (markdown files)**      | No.                                                                                                                         | Add a `payload/agent/skills/` directory loaded at start. This is genuinely new capability, not just refactoring.                     |
| **C5 — Conversation triggered from outside the host (Issues)**    | Out of scope by design; the chat UI is loopback-only.                                                                       | This is the *opt-in* mode in §5.3; do **not** make it the default.                                                                   |

C1–C4 are net improvements that don't change Ubuntu Zombie's trust
model. C5 *does* change the trust model and is treated separately.

---

## 4. Constraints Ubuntu Zombie imposes on any "Pi-ification"

Anything we adopt from GMI/Pi has to live with the following
non-negotiables, taken straight from `SECURITY.md`,
`docs/ARCHITECTURE.md`, `docs/VISION.md`, and the existing agent code:

1. **Loopback by default.** The chat service binds `127.0.0.1`; remote
   access is via SSH-over-Tailscale. Nothing introduced here may open a
   new public listener.
2. **The `zombie` Linux user is the operating identity.** The agent
   runs as `zombie` (not root). Privilege is acquired via a *restricted*
   `sudo` allow-list configured by `scripts/install.sh`.
3. **The policy gate is load-bearing.** Every command that the agent
   wants to run goes through `payload/agent/policy.py` and is classified
   `read_only | user_change | system_change | network_change |
   destructive`. UPGRADE-1 §1–§3 already flag the current classifier as
   the weakest link; this proposal makes the policy gate's job *bigger*
   (now it has to gate tools, not just commands), so UPGRADE-1 Phase 1
   must land first or in parallel.
4. **Audit log is canonical.** `audit.py` JSONL is what an operator
   reviews after the fact. Any new agent loop must write a complete,
   per-step audit trail with the same fields (timestamp, actor, intent,
   tool, args, classification, exit, stdout/stderr digests).
5. **Idempotent installer.** Anything new has to be installed,
   verified, repaired, and uninstalled by `scripts/install.sh`'s
   existing subcommands (`install | verify | doctor | repair |
   uninstall`) and pass `tests/smoke.sh` and `make lint test package`.
6. **No new network egress at runtime beyond LLM provider + Tailscale +
   apt/snap.** A Pi harness that phones home for telemetry, model
   downloads, or skill marketplaces is not acceptable in the default
   profile.
7. **No Node runtime in the privileged hot path unless we have to.**
   The current agent is pure-Python under a venv created by
   `payload/bin/setup-agent-venv`. `pi-mono` is Node/TypeScript. Either
   we accept a Node runtime alongside the venv (already partially true
   because of Playwright/Chromium tooling) or we use the *Python*
   surface of `pi-ai`/the harness if/when available. This is the single
   biggest packaging decision.

---

## 5. Three concrete proposals (independent, ordered by risk)

### 5.1. Adopt `pi-ai` as the provider layer (low risk)

**Goal:** Get GMI's provider breadth without changing the agent loop.

**What changes:**

- `payload/agent/providers.py` is replaced by a thin shim around
  `pi-ai`. The shim still exposes `provider_from_env()` /
  `provider_status()` so `server.py` is unchanged. Behind the shim,
  `pi-ai` handles OpenAI, Anthropic, Gemini, xAI, OpenRouter, Mistral,
  Groq.
- `payload/etc/policy.yaml` and `docs/CONFIGURATION.md` gain the new
  env vars (`GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`,
  `MISTRAL_API_KEY`, `GROQ_API_KEY`) and `ZOMBIE_PROVIDER` accepts the
  new names.
- `payload/bin/secrets-edit` and the installer's secret-file template
  list the new variables (commented out by default).
- `payload/bin/setup-agent-venv` pins the new dependency.

**What does *not* change:**

- The chat UI, the policy gate, the audit log, the SQLite history, and
  the systemd unit. This is an internal refactor.

**Open question:** is there a maintained *Python* package that gives us
the same provider matrix as `pi-ai`? If not, we either (a) keep
per-provider Python clients and just *add* the missing ones (Gemini, xAI,
OpenRouter, Mistral, Groq), or (b) accept a small Node sidecar that
exposes a localhost JSON-RPC interface to `pi-ai`. (a) is much less
invasive and is the recommended first cut; (b) is only worth it if §5.2
also adopts the Node harness.

**Validation:** existing `make lint test package` plus a new provider
matrix smoke test that exercises `provider_from_env` for each provider
with a fake key and asserts the right error class is raised when the
key is missing.

**Estimated blast radius:** one file rewritten, ~5 docs touched, no
schema changes, no installer changes beyond the secret template.

### 5.2. Adopt a Pi-style tool-calling agent loop (medium risk, high value)

**Goal:** Replace the current "LLM emits text; we regex one shell
command out of it" loop with a proper tool-calling agent.

**Current loop (`payload/agent/server.py`, ~567 lines):**

```
user prompt
  → provider.chat(messages)
  → LLM returns text
  → server.py heuristically finds a fenced shell block
  → policy.classify(command)
  → if read_only: run inline; else: ask operator to approve
  → append result to history + audit
```

**Proposed loop (Pi-shaped):**

```
user prompt
  → agent.run(messages, tools=[...])
    repeatedly:
      → LLM emits a tool call (name + args)
      → tool dispatcher:
          • validate args against the tool's schema
          • classify(tool, args) via policy.py            ← gate moves here
          • if not auto-allowed, suspend and ask operator
          • execute, capture (exit, stdout, stderr, latency)
          • append a "tool_observation" message
          • append an audit event
      → repeat until LLM emits a final assistant message
  → append final reply to history
```

**Tools to ship in v1** (each with a JSON schema and a policy class):

| Tool                | Wraps                                                 | Default class       |
|---------------------|-------------------------------------------------------|---------------------|
| `shell.run`         | `runner.run(command)`                                 | computed per-argv   |
| `fs.read`           | `Path.read_text` with allow-list                      | `read_only`         |
| `fs.write`          | `Path.write_text` with allow-list                     | `user_change`       |
| `pkg.query`         | `dpkg -s`, `apt-cache policy`                         | `read_only`         |
| `pkg.install`       | `apt-get install -y`                                  | `system_change`     |
| `svc.status`        | `systemctl status / is-active`                        | `read_only`         |
| `svc.control`       | `systemctl start/stop/restart/enable/disable`         | `system_change`     |
| `net.status`        | `ip`, `ufw status`, `tailscale status`                | `read_only`         |
| `gui.screenshot`    | existing GUI helper                                   | `read_only`         |
| `gui.click` / `gui.type` | existing GUI helpers                              | `user_change`       |

The policy gate becomes a **schema-aware** classifier instead of a
regex-on-text classifier — which is exactly what UPGRADE-1 §1 already
asks for, just expressed as tools rather than as argv. This is a strict
improvement: the agent never gets to smuggle commands through prose,
because prose isn't an execution path anymore.

**Skills:** ship a `payload/agent/skills/` directory with markdown
files (`apt.md`, `systemd.md`, `tailscale.md`, `ufw.md`, `docker.md`,
`gui.md`). Each skill is loaded into the system prompt only when its
trigger words appear in the conversation, à la GMI. Skills are
*static guidance*, not code; they can't expand the tool surface.

**Runtime choice (pure-Python vs Node sidecar):**

- **Pure-Python.** Implement the loop in `payload/agent/agent.py` using
  the providers' native function-calling APIs. Reuses the existing
  venv. ~400 lines of code. **Recommended.**
- **Node sidecar.** Add `@earendil-works/pi-agent-core` as a localhost
  service, install Node via the installer (we already pull Node for
  other tooling), and have `server.py` proxy to it. Gets us GMI's exact
  harness "for free" but doubles the runtime surface and the audit
  story has to bridge two processes. **Only adopt if `pi-agent-core`
  evolves capabilities we can't easily match.**

**What must change in the codebase (Python-path):**

- New file `payload/agent/agent.py` — the loop above.
- New file `payload/agent/tools.py` — tool definitions + JSON schemas.
- `payload/agent/policy.py` — extend with `classify_tool(tool_name,
  args) -> Verdict`, sharing the classification taxonomy with
  `classify_command` (which stays for backwards-compat).
- `payload/agent/server.py` — `/api/message` switches from calling
  `provider.chat` directly to calling `agent.run`. The approval
  workflow (pending action → operator confirmation) generalises from
  "approve this command" to "approve this tool call".
- `payload/agent/history.py` — sessions store tool calls + observations
  alongside user/assistant messages. Schema gets a `tool_calls` column
  or a new `events` table; migrate forward in-place.
- `payload/agent/audit.py` — one event per tool call, with
  `tool`, `args_redacted`, `classification`, `decision`, `exit`,
  `duration_ms`, `stdout_sha256`, `stderr_sha256`. (Hashing big outputs
  keeps the log small; the full output stays in history.)
- `payload/agent/templates/index.html` — render tool calls and
  observations distinctly from prose, with the approval button on
  pending tool calls.

**What must change in tests/CI:**

- `tests/smoke.sh` — add a non-interactive end-to-end test using a
  fake provider that emits a canned sequence of tool calls and
  observations, asserting the audit log and history shape.
- `make lint` — add the new modules to whatever linters are already run.
- `.github/workflows/ci.yml` — no structural change; the new tests
  just run.

**Migration:** the existing `conversations.db` is preserved; old
conversations render as before, new ones use the tool-call schema. No
forced reset.

**Estimated blast radius:** ~3 new files, ~1k LOC of changes, schema
migration, UI changes, new tests. Realistically a multi-PR effort.

### 5.3. Optional: GMI-style "drive Ubuntu Zombie from a GitHub issue" mode (high risk, opt-in only)

**Goal:** Let an operator open an issue in a *private* GitHub repo they
own and have the Ubuntu Zombie host pick it up, answer it, and post
back — the GMI loop, but with Ubuntu Zombie as the executor.

**Why this is **not** just GMI-on-a-PC:**

- GMI runs on ephemeral GitHub Actions runners; failures are bounded by
  the runner image. Ubuntu Zombie runs on the operator's actual
  machine; a bad tool call has *physical* consequences (apt removes
  packages, ufw blocks SSH, etc.). The blast radius is incomparable.
- GMI's "auth" is GitHub repo collaborators. Ubuntu Zombie's auth is
  Tailnet + local Unix user. Bolting GitHub-auth onto a host gives a
  second, weaker key to the kingdom unless we are very careful.
- GMI's responses are commits in a repo the user already audits. Ubuntu
  Zombie's responses change *the host*. Treating an issue thread as the
  audit log is not equivalent to a JSONL on disk.

**What the design would be, if pursued:**

- A new optional component, `ubuntu-zombie-issue-poller.service`,
  installed only when `ZOMBIE_ENABLE_ISSUE_BRIDGE=1` is set at install
  time. It is **off by default** and the installer prints a long
  warning when it is enabled.
- The poller runs as `zombie`, holds a GitHub fine-grained PAT scoped
  to exactly one private repo, and polls (or uses a webhook via a
  reverse tunnel — Tailscale Funnel is the only acceptable option) for
  new issues / comments on issues labelled e.g. `zombie:request`.
- For each event:
  1. Verify the author is on an allow-list configured in
     `/etc/ubuntu-zombie/issue-bridge.yaml` (single GitHub username by
     default).
  2. Treat the issue body / comment as a chat message.
  3. Run it through the **same** agent loop as §5.2, with the **same**
     policy gate, the **same** audit log, and one extra rule: any tool
     classified above `read_only` is auto-rejected unless the issue
     also carries an explicit `zombie:approve` label applied by the
     same allow-listed user. This mirrors the local "approve / reject"
     button, but over GitHub's labels.
  4. Post the assistant reply (and a redacted summary of tool calls
     and exit codes) back as an issue comment.
  5. Append the full session to the existing on-host audit log; the
     issue thread is a *convenience mirror*, not the source of truth.
- No inbound listener is opened on the host. The poller is outbound to
  `api.github.com` only.

**What this still does *not* solve:**

- A compromised GitHub account belonging to the allow-listed user
  becomes a remote code execution path on the host. Today, the same
  user being compromised gets the attacker as far as Tailscale +
  SSH key, which is a higher bar. Document this explicitly and make it
  the operator's call.
- Issue bodies are unstructured Markdown. The agent's interpretation of
  a "request" is fuzzier than typing into the chat UI on the host. The
  policy gate is still the safety net, but UI signals (chat is local,
  operator is physically present) are lost.

**Recommendation:** specify this mode but **do not build it in the same
PR as §5.1/§5.2**. Build it only if there is a real operator request,
ship it behind `ZOMBIE_ENABLE_ISSUE_BRIDGE=1`, and require UPGRADE-1
Phase 1 to be merged first.

---

## 6. Phased delivery (if we do all of the above)

Each phase is independently shippable and reverts cleanly.

**Phase 0 — Prerequisites (from UPGRADE-1):**

- UPGRADE-1 §1 argv-aware classifier.
- UPGRADE-1 §2 fail-closed default.
- UPGRADE-1 §3 sudo allow-list trimmed.

Without these, §5.2 makes the gate's blast radius worse, not better.

**Phase 1 — Provider breadth (§5.1):**

- Shim `payload/agent/providers.py` to add Gemini, xAI, OpenRouter,
  Mistral, Groq.
- Update `secrets-edit`, `docs/CONFIGURATION.md`,
  `docs/QUICKSTART.md`, `payload/etc/policy.yaml` (if it names
  providers), and CI.

**Phase 2 — Tool-calling loop (§5.2, Python path):**

- Add `agent.py`, `tools.py`; extend `policy.py`, `history.py`,
  `audit.py`, `server.py`, `templates/index.html`.
- Migrate existing chat flow to the tool loop behind a feature flag
  (`ZOMBIE_AGENT_MODE=tools|legacy`, default `legacy`).
- Once smoke tests pass on real hardware, flip the default.

**Phase 3 — Skills directory:**

- Ship `payload/agent/skills/{apt,systemd,tailscale,ufw,docker,gui}.md`.
- Loader: include a skill in the system prompt when any of its trigger
  words appears in the last N user messages.
- Document how operators add their own skills under
  `/etc/ubuntu-zombie/skills.d/`.

**Phase 4 — Optional Issue bridge (§5.3):**

- Ship the poller, the allow-list config, the install-time opt-in, and
  documentation that is explicit about the trust tradeoff.
- Land **only** after Phases 0–3 are stable.

---

## 7. Risks and how to defuse them

| Risk                                                                                                                  | Defuse                                                                                                                                                                                  |
|-----------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Tool-call agents can chain many small actions; the policy gate is currently per-command.**                          | Gate at the tool layer (§5.2), and add a per-turn budget (e.g. ≤ N tool calls between operator messages, configurable in `policy.yaml`). Audit every tool call individually.            |
| **Adding 5 new providers expands the supply chain.**                                                                  | Pin versions in the venv requirements, vendor `requirements.txt` lockfile, run `pip-audit` in CI. Make every provider optional (only installed if the corresponding key is set or `--all-providers` was passed at install). |
| **Skills are LLM prompt-injection vectors if loaded from operator-writable paths.**                                   | Ship skills as root-owned, mode `0644`, under `/opt/ai-zombie/skills/`. Operator-added skills go to `/etc/ubuntu-zombie/skills.d/` and require a `repair` to reload. Never trust the working dir. |
| **A Node-based `pi-mono` sidecar widens the attack surface.**                                                         | Prefer the pure-Python implementation in §5.2. Only adopt the Node sidecar if a Pi feature we genuinely need is impractical to reimplement.                                            |
| **GMI's "session in git" pattern tempts us to commit `audit.log` somewhere.**                                         | Do not. The host's audit log is local-only. The §5.3 Issue bridge mirrors *summaries*, never the raw audit log, and never secrets.                                                     |
| **Issue bridge (§5.3) creates a remote control plane.**                                                               | Keep it off by default. Require explicit opt-in. Auto-reject anything above `read_only` without a label approval from the same allow-listed user. Document the trust delta loudly.     |
| **Bigger agent loop = more LLM context = more cost and more leakage.**                                                | Add per-conversation token budgets in `policy.yaml`, surface them in the UI, and redact secret-file paths from history snapshots before they enter the prompt.                         |
| **Schema migration of `conversations.db` could brick existing installs on upgrade.**                                  | Forward-only migration with a backup snapshot at `state/conversations.db.bak.<ts>` taken by `install.sh upgrade`, and a `doctor` check that detects schema drift.                      |

---

## 8. Open questions for the maintainer

These are honest "I don't know" items that change the shape of the
plan; please decide before any code is written.

1. **Python or Node for the harness?** Are we willing to add Node to
   the agent's runtime path, or do we want a pure-Python Pi-shaped
   agent that we own? (My recommendation: pure-Python, at least for
   v1.)
2. **Is provider breadth itself a goal, or only a side effect?** If the
   only providers we care about are OpenAI + Anthropic + one local
   (Ollama / llama.cpp), §5.1's value drops a lot.
3. **Is the Issue bridge (§5.3) actually wanted, or did the problem
   statement just mean "Pi-style agent loop"?** Building §5.3 is a
   product decision; building §5.1+§5.2 is a refactor.
4. **Skill format — copy GMI's markdown layout verbatim, or invent
   one?** Copying makes future skills cross-compatible with GMI;
   inventing lets us add Ubuntu-specific frontmatter (e.g. required
   policy classes a skill is allowed to suggest). Probably: copy the
   shape, add optional frontmatter.
5. **How aggressive should we be about retiring the legacy
   "one-shell-command-per-turn" path?** Keep it forever behind a flag
   (safer), or remove it once Phase 2 is stable (less code to maintain)?
6. **Where do skills installed by operators live?** Under
   `/etc/ubuntu-zombie/skills.d/` (config, survives upgrade) feels
   right, mirroring `policy.yaml`.

---

## 9. What this PR is not doing

To be explicit:

- No code in `payload/`, `scripts/`, `docs/`, or `tests/` is modified.
- No new dependencies are added.
- No installer subcommand changes.
- No security boundary is crossed; the existing `lint`, `test`, and
  `package` targets remain green because nothing else changed.

The only artifact produced is this file, `UPGRADE-2.md`, sitting next
to `UPGRADE-1.md`. Each section above can become its own PR once the
maintainer signs off on scope.

---

## 10. TL;DR

- The valuable part of GMI for Ubuntu Zombie is **Pi's tool-calling
  agent loop + provider breadth + composable skills**, not "use GitHub
  Issues as the UI".
- Adopt them in three phases: provider shim → tool-calling agent +
  skills → (optional, opt-in) Issue bridge.
- Land [`UPGRADE-1.md`](UPGRADE-1.md) Phase 1 first; a Pi-style multi-tool
  agent makes a weak policy gate worse, not better.
- Do not let `pi-mono`'s "session lives in git" pattern leak the host
  audit log into a remote repo.
