# UPGRADE-TO-PI-PLAN: Execution plan for adopting `pi-mono` + `pi-ai`

> **Scope.** This document is the *execution plan* derived from
> [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md). Where that document is the
> *directive and analysis* ("`pi` overrides all other concerns"), this
> document is the *work breakdown*: ordered PRs, deliverables,
> acceptance criteria, validation steps, rollback procedures, and risk
> tracking. Nothing here may relax a constraint set by
> [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md),
> [`UPGRADE-1.md`](UPGRADE-1.md), or
> [`SECURITY.md`](../SECURITY.md). Where ambiguity exists, defer to
> those documents.
>
> This file is *planning only*. The PR that introduces it makes no
> code changes, in keeping with the precedent set by
> [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §7.

Companion documents:

- [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) — directive, target
  architecture, change list. **Authoritative.** This plan only orders
  and operationalises that document.
- [`UPGRADE-1.md`](UPGRADE-1.md) — security prerequisites. Phase 0
  below is its Phase 1.
- [`UPGRADE-2.md`](UPGRADE-2.md) / [`UPGRADE-3.md`](UPGRADE-3.md) —
  superseded for sequencing and feature-flag staging by
  [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md); still useful for context on
  rejected alternatives.
- [`SECURITY.md`](../SECURITY.md), [`ARCHITECTURE.md`](ARCHITECTURE.md),
  [`CONFIGURATION.md`](CONFIGURATION.md),
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — operator-facing
  surface that must be updated as phases land.

---

## 1. Plan-at-a-glance

The work is decomposed into five phases (numbering matches
[`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §8) and within each phase into
one or more focused PRs. Each PR is gated by
`make lint && make test && make package` (see stored repository
convention) and by the acceptance criteria listed below.

| Phase | Theme                              | PRs        | Independently revertible? |
|-------|------------------------------------|------------|---------------------------|
| 0     | Security prerequisites (UPGRADE-1) | P0.1–P0.3  | Yes                       |
| 1     | Provider swap to `pi-ai`           | P1.1–P1.2  | Yes                       |
| 2     | `pi-mono` agent loop (atomic cut)  | P2.1–P2.6  | **No** (package downgrade only) |
| 3     | Skills surface                     | P3.1–P3.2  | Yes                       |
| 4     | Hardening pass                     | P4.1–P4.2  | Yes                       |

Phase 2 is the cutover. Everything in it ships in one release; there
is no `ZOMBIE_AGENT_MODE` flag and no parallel `legacy` path
([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §5).

---

## 2. Cross-cutting working agreements

These apply to every PR in the plan.

1. **Authoritative source.** When this plan and
   [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) disagree on substance, the
   directive wins. Update this plan, not the directive.
2. **Validation gate.** Every PR runs `make lint`, `make test`, and
   `make package` locally and in CI before merge. No PR is merged
   with a red gate.
3. **Smoke coverage.** `tests/smoke.sh` is extended in lockstep with
   each PR that changes operator-visible behaviour, the agent loop,
   or installer steps.
4. **Idempotent installer.** Any `scripts/install.sh` change must be
   safe to run repeatedly under
   `ZOMBIE_NONINTERACTIVE=1` (see stored repository fact) on a fresh
   host and on an already-installed host.
5. **No silent secret handling.** New env vars (provider keys, pin
   files, settings) are documented in
   [`CONFIGURATION.md`](CONFIGURATION.md) in the same PR that
   introduces them. Secrets never appear in audit logs or in
   `pi-mono` stdout/stderr captures.
6. **Audit-first.** Any new code path that can touch the host is
   instrumented with `audit.log_event` (or its successor) before it
   is wired into a user-reachable route.
7. **Forward-only DB migrations.** Snapshot
   `state/conversations.db` to `state/conversations.db.bak.<ts>`
   before applying. Document the rollback procedure in
   [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
8. **Pinned upstream.** `pi-mono` and `pi-ai` versions are stored in
   `payload/agent/pi-mono.version` (and `pi-ai.version` if separately
   installable). Bumps are their own PRs with smoke evidence.

---

## 3. Phase 0 — Security prerequisites

**Goal.** Land [`UPGRADE-1.md`](UPGRADE-1.md) Phase 1 in full so the
policy gate is safe to extend in Phase 2. Phase 1 cannot begin until
Phase 0 is merged and verified.

### P0.1 Argv-aware classifier

- Deliverable. `payload/agent/policy.py` `classify` parses argv (not
  just the rendered command string) and returns the same
  `CLASS_ORDER` taxonomy.
- Acceptance. Existing classifier tests pass; new cases cover
  `sudo` invocations, redirections, env prefixes, and quoted
  filenames.
- Risk. Behavioural drift for in-flight conversations. Mitigated by
  unit-test parity matrix against the current classifier on a
  recorded corpus.

### P0.2 Fail-closed default

- Deliverable. Unknown commands classify as the highest gated class
  (operator approval required) rather than auto-running.
- Acceptance. A canary command unknown to all rules requires
  approval in `tests/smoke.sh`.
- Risk. Operator friction. Mitigated by P0.3.

### P0.3 Sudo allow-list

- Deliverable. Curated allow-list of `sudo` targets pre-classified
  as `system_change` with no per-command prompt beyond the standard
  approval.
- Acceptance. The list is sourced from `policy.yaml` and is
  documented in [`CONFIGURATION.md`](CONFIGURATION.md).

**Phase 0 exit criteria.** All three PRs merged; `make lint`,
`make test`, `make package` green; smoke run on a freshly imaged
host shows the new classifier on the happy path *and* on the
fail-closed path.

---

## 4. Phase 1 — `pi-ai` provider swap

**Goal.** Replace the bespoke provider layer with `pi-ai` while
leaving the existing agent loop in place. This is the only phase
that is independently revertible by package downgrade alone
([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §8).

### P1.1 Wire `pi-ai` behind `provider.chat`

- Deliverable.
  - Delete bespoke OpenAI/Anthropic client code in
    `payload/agent/providers.py` (≈147 lines per
    [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §4.1).
  - New thin adapter calls `pi-ai`. The Python-facing
    `provider.chat()` signature is preserved so
    `payload/agent/server.py` is unchanged.
  - `payload/agent/pi-ai.version` is created and pinned.
  - `scripts/install.sh` installs `pi-ai` at the pinned version and
    `verify` asserts the installed version matches.
- Acceptance.
  - `ZOMBIE_PROVIDER=openai` and `ZOMBIE_PROVIDER=anthropic` both
    succeed end-to-end against the existing chat UI with a real key
    and against a `pi-ai` test provider in `tests/smoke.sh`.
  - No regression in `extract_commands` behaviour (it still runs).
- Rollback. Package downgrade; no DB shape changes in this PR.

### P1.2 Surface additional providers

- Deliverable.
  - Accept `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`,
    `MISTRAL_API_KEY`, `GROQ_API_KEY` in the secrets file template
    and via `payload/bin/secrets-edit`.
  - `ZOMBIE_PROVIDER` accepts the new names.
  - [`CONFIGURATION.md`](CONFIGURATION.md) documents each new
    variable and the deprecation of the bespoke client.
- Acceptance. A smoke run with each new provider name (against the
  test provider) succeeds; missing-key cases surface a clear error.

**Phase 1 exit criteria.** Both PRs merged; chat UI behaviour
unchanged from the operator's perspective; `make package` artefact
on a clean host successfully boots the chat service with each
supported provider in turn (matrix-driven smoke).

---

## 5. Phase 2 — `pi-mono` cutover (atomic)

**Goal.** Execute the single, atomic migration described in
[`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §5. After this phase, the
agent loop is `pi-mono`, tools are gated by `classify_tool`, and
`extract_commands` is gone.

This phase is not independently revertible. Roll back via package
downgrade plus the `conversations.db.bak.<ts>` snapshot.

> **Ordering note.** PRs P2.1–P2.5 are prepared and reviewed
> independently but **must merge in a single release train**. Each
> earlier PR ships behind internal scaffolding (the runtime path is
> not taken until P2.6 lands). The release that contains P2.6 is the
> migration release.

### P2.1 Pinned `pi-mono` install, settings, identity prompt

- Deliverable.
  - `payload/agent/pi-mono.version`.
  - `/opt/ai-zombie/pi/settings.json` and `APPEND_SYSTEM.md`
    rendered by `scripts/install.sh` at install/repair time, mode
    `0644`, owner root.
  - `install.sh verify`/`doctor`/`repair`/`uninstall` learn about
    `pi-mono` (install, version check, re-render, npm uninstall).
- Acceptance.
  - `pi-mono --version` matches the pin on a fresh install and
    after `repair`.
  - `APPEND_SYSTEM.md` content matches what
    `server.py:render_system_prompt` produces for the same host.
  - Idempotency verified by running `install.sh` twice.

### P2.2 Tool shims and `classify_tool`

- Deliverable.
  - `payload/agent/policy.py` gains
    `classify_tool(name, args) -> str` aligned with `CLASS_ORDER`.
  - Per-tool JSON schemas. Schema-failing calls are rejected
    pre-classification with an audit event of type
    `tool_call_rejected_schema`
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.7).
  - Shims for the closed tool list in
    [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §4.3:
    `shell.run`, `fs.read`, `fs.write`, `pkg.query`, `pkg.install`,
    `svc.status`, `svc.control`, `net.status`, `gui.screenshot`,
    `gui.click`, `gui.type`, `skill.list`, `skill.load`.
  - Allow-list passed to `pi-mono` at spawn; built-in `shell` and
    file-edit tools are *not* exposed.
- Acceptance.
  - Unit tests cover each shim's allow-list, schema-rejection,
    classification, and approval routing.
  - Internet-egress tools are absent from the registry (regression
    test asserts).

### P2.3 Audit + history shape

- Deliverable.
  - `payload/agent/audit.py` `log_event` gains a `tool_call` event
    with `tool`, `args_redacted`, `classification`, `decision`,
    `exit`, `duration_ms`, `stdout_sha256`, `stderr_sha256`
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §4.4).
  - `payload/agent/history.py` gains an `events` table (or a
    `tool_calls` column on `messages`) sufficient to render tool
    activity in the UI.
  - Forward-only DB migration with the
    `conversations.db.bak.<ts>` snapshot performed by
    `install.sh upgrade`.
  - Secrets-path and sensitive-env redaction implemented for both
    audit entries and history snapshots fed back into prompts
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.3).
- Acceptance.
  - Migration applies cleanly on a recorded `conversations.db`
    fixture; rollback by restoring the snapshot also succeeds.
  - Audit redaction unit tests cover known sensitive keys and the
    secrets-file path.

### P2.4 Server wiring

- Deliverable.
  - `payload/agent/server.py` spawns `pi-mono` per turn with the
    session JSONL, allow-list, and Zombie-owned config tree.
  - Working directory and writable paths confined to
    `${ZOMBIE_DIR}/state/`.
  - `_handle_commands` and `approve` generalised to
    "approve this tool call" with a `tool` field on the wire; the
    old `command` field is removed.
  - `pi-mono` stdout/stderr captured to
    `${ZOMBIE_DIR}/state/logs/pi-mono.<ts>.log` (root-readable
    only) with logrotate
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.3).
- Acceptance.
  - End-to-end smoke turn with a stubbed `pi-mono` succeeds and
    produces the expected audit + history rows.
  - Process confinement verified by asserting `pi-mono` cannot
    read the secrets file path via the `shell.run` shim (it should
    be denied or absent from the allow-list).

### P2.5 UI updates

- Deliverable.
  - `payload/agent/templates/index.html` renders `tool_call`,
    `tool_observation`, and `pending_tool_call` bubbles with
    targeted approve/reject buttons.
  - Per-turn tool-call counter rendered against the budgets in
    [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.
  - Skill provenance displayed when a skill is active
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.4).
- Acceptance.
  - Existing conversations render as prose-only without errors.
  - New turns render the new bubble types and counter.

### P2.6 Atomic cutover and `extract_commands` removal

- Deliverable.
  - `extract_commands` and the single-command-per-turn approval
    path are removed in this PR
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.6).
  - `Makefile` `make package` includes the pinned-version files
    (and `payload/agent/skills/` once Phase 3 lands; until then,
    the directory may not exist).
  - `tests/smoke.sh` gains a non-interactive case driven by a
    stubbed `pi-mono` (or a `pi-ai` test provider) that emits a
    canned tool-call sequence and asserts audit/history shape
    ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §4.7).
  - [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) and
    [`CONFIGURATION.md`](CONFIGURATION.md) updated to reflect the
    new runtime, the new env/paths, and the rollback procedure.
- Acceptance.
  - `install.sh upgrade` on a host previously running the Phase 1
    package: snapshot taken, DB migrated, `pi-mono` pinned, unit
    restarted, `install.sh verify` green.
  - If `pi-mono`, `pi-ai`, or required credentials are missing,
    `install.sh verify` fails and the unit is left in its previous
    state ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §5.2).
  - Documented rollback (package downgrade + snapshot restore) is
    exercised once on a test host before release.

**Phase 2 exit criteria.** Migration release builds; smoke matrix
covers (a) fresh install, (b) upgrade from Phase 1, (c) failed
verify → unit left untouched, (d) rollback to Phase 1 via snapshot.

---

## 6. Phase 3 — Skills

**Goal.** Ship the closed-skill surface defined in
[`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §4.5. Skills never expand the
tool surface.

### P3.1 Built-in skills and loader

- Deliverable.
  - `payload/agent/skills/` with `apt.md`, `systemd.md`,
    `tailscale.md`, `ufw.md`, `docker.md`, `gui.md`.
  - Installed to `/opt/ai-zombie/skills/`, mode `0644`, owner root.
  - Loader injects a skill into the system prompt only when its
    trigger words appear in the last N user messages.
- Acceptance. Unit tests cover the trigger logic; smoke run with a
  matching prompt shows the skill path rendered in the UI
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.4).

### P3.2 Operator-extensible skills

- Deliverable. `/etc/ubuntu-zombie/skills.d/` with the same
  mode/owner contract as `/etc/ubuntu-zombie/policy.yaml`;
  `install.sh repair` reloads.
- Acceptance. Adding a file under `skills.d/` and running
  `install.sh repair` causes it to be picked up; permissions are
  validated.

**Phase 3 exit criteria.** Both PRs merged; `make package` includes
`payload/agent/skills/`; smoke run demonstrates skill loading and
provenance display.

---

## 7. Phase 4 — Hardening pass

**Goal.** Tighten the per-turn budgets and revisit process-lifecycle
trade-offs based on real-hardware telemetry.

### P4.1 Tune budgets

- Deliverable. Adjust defaults of
  `agent.max_tool_calls_per_turn` and
  `agent.max_elevated_calls_per_turn` in `policy.yaml` based on
  measured turn distributions
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.1–§6.2).
- Acceptance. Telemetry summary attached to the PR; regression test
  asserts budget enforcement (soft failure when exceeded).

### P4.2 Persistent `pi-mono` (conditional)

- Deliverable. If, and only if, per-turn spawn latency is
  unacceptable on target hardware, prototype a persistent stdio
  child with explicit restart-on-crash and per-conversation tool
  state isolation ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.2).
- Acceptance. A written go/no-go decision with measurements is
  attached; if no-go, this PR is closed without merging.

**Phase 4 exit criteria.** Budgets reflect production telemetry;
process-lifecycle decision documented in this file (update §11).

---

## 8. Test and validation strategy

For each PR:

1. **Unit tests.** New or modified Python modules ship with tests
   under `tests/`. Cover the happy path, the schema-rejection
   path, the classifier-fail-closed path, and the redaction path
   where applicable.
2. **Smoke.** Extend `tests/smoke.sh` to cover the new
   operator-visible behaviour. Always run via
   `ZOMBIE_NONINTERACTIVE=1` with the required env vars
   (`SSH_PUBLIC_KEY`, `VNC_PASSWORD`) so it is repeatable on a
   fresh host (see stored repository fact).
3. **Packaging.** `make package` must succeed and the resulting
   artefact must install cleanly on a fresh Ubuntu host.
4. **Manual matrix.** Phases 1 and 2 each include a documented
   manual matrix:
   - Provider matrix (Phase 1): each `ZOMBIE_PROVIDER` value boots
     the chat service and serves one turn.
   - Migration matrix (Phase 2): fresh install / upgrade / failed
     verify / rollback.

CI gates:

- `make lint`, `make test`, `make package` as the merge gate (see
  stored repository fact).
- Smoke run on a Phase-appropriate Ubuntu image once the migration
  release (P2.6) is staged.

---

## 9. Rollback plan

- **Phases 0, 1, 3, 4.** Standard package downgrade. No DB shape
  changes; no rollback steps beyond reinstalling the previous
  package.
- **Phase 2 (cutover).** Documented procedure in
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md):
  1. `systemctl stop ubuntu-zombie-chat`.
  2. Restore `state/conversations.db` from the most recent
     `state/conversations.db.bak.<ts>` snapshot.
  3. Downgrade the package to the last Phase 1 release.
  4. `install.sh verify`.
  5. `systemctl start ubuntu-zombie-chat`.

There is intentionally no in-product "fall back to the legacy
loop" knob ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §5.4).

---

## 10. Risk register

| ID  | Risk                                                            | Phase | Mitigation                                                                                              |
|-----|-----------------------------------------------------------------|-------|---------------------------------------------------------------------------------------------------------|
| R1  | Argv-aware classifier diverges from prior behaviour             | 0     | Parity matrix in P0.1; smoke covers fail-closed canary.                                                 |
| R2  | `pi-ai` provider behaviour differs from bespoke client          | 1     | Adapter preserves `provider.chat()` signature; provider matrix smoke.                                   |
| R3  | DB migration corrupts `conversations.db`                        | 2     | Snapshot to `state/conversations.db.bak.<ts>` before applying; restore exercised on a test host.        |
| R4  | `pi-mono` escapes confinement                                   | 2     | Allow-list at spawn; built-in tools not exposed; working dir limited to `state/`; secrets path denied.  |
| R5  | Secrets leak through `pi-mono` logs                             | 2     | Logs root-readable only; audit redaction tests; no secrets passed via argv.                             |
| R6  | Migration release fails on operator hosts                       | 2     | `install.sh verify` fails closed and leaves the previous unit running; rollback procedure documented.   |
| R7  | Per-turn spawn latency unacceptable                             | 4     | Phase 4 revisits persistent child only if measured latency justifies it; otherwise stay per-turn.       |
| R8  | Skill prompt injection                                          | 3     | Closed tool registry (skills cannot add tools); skill provenance shown in UI.                           |
| R9  | Upstream `pi-mono`/`pi-ai` version drift                        | All   | Pinned via `payload/agent/pi-mono.version` / `pi-ai.version`; bumps are explicit PRs with smoke evidence.|

---

## 11. Decisions log

Recorded so future contributors can see *why* this plan looks the
way it does. Update when a Phase 4 measurement closes an open
question.

- **D1.** No `ZOMBIE_AGENT_MODE` legacy flag. Single supported mode
  is `pi` ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §5).
- **D2.** Pin `pi-mono` and `pi-ai`; no "track latest"
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.1).
- **D3.** Per-turn `pi-mono` invocation for Phase 2; revisit in
  Phase 4 only on measured latency
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.2).
- **D4.** `pi-mono` stdout/stderr to
  `${ZOMBIE_DIR}/state/logs/pi-mono.<ts>.log`, root-readable
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.3).
- **D5.** GMI-format JSONL with Zombie additions under a `zombie`
  namespace ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.4).
- **D6.** No GitHub tools exposed on the host; no GitHub Issues
  bridge in this plan ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §7,
  §9.5).
- **D7.** `extract_commands` is removed atomically in P2.6
  ([`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §9.6).
- **D8.** Phase 4 / P4.2 — *no-go on a persistent `pi-mono` child.*
  Per-turn `pi-mono` spawn is retained. The cost of opening the
  process-lifecycle surface (restart-on-crash, cross-conversation
  tool-state isolation, deciding when to recycle the child after a
  `policy.yaml` reload, holding a Node runtime resident on a desktop
  host) is not justified without measured evidence that per-turn
  spawn latency is unacceptable on target hardware. The Phase 4
  acceptance criterion explicitly contemplates closing P4.2 without
  merging when no such evidence exists; revisit if and only if a
  future measurement on a supported Ubuntu Desktop SKU shows
  unacceptable interactive latency.
- **D9.** Phase 4 / P4.1 — default per-turn budgets aligned with
  [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.1–§6.2
  (`max_tool_calls_per_turn` 12, `max_elevated_calls_per_turn` 3).
  Both budgets enforce a soft failure via a synthetic
  `budget_exceeded` observation; the elevated budget is enforced in
  `server.py` against `policy.classify_tool`, the total-call budget
  in `pi_mono.run_turn`. Regression coverage in
  `tests/smoke.sh` exercises both soft-failure paths against the
  `tests/fixtures/stub-pi-mono.mjs` bridge.

### Phase status

- **Phase 0** — complete (security prerequisites; argv-aware
  classifier, fail-closed default, sudo allow-list).
- **Phase 1** — complete (atomic `pi-ai` provider swap).
- **Phase 2** — complete. `pi-mono` (`@earendil-works/pi-coding-agent`
  pinned in `payload/agent/pi-mono.version`) is the agent loop;
  fenced-bash parser removed; closed 13-tool registry in
  `payload/agent/tools.py`; structured `tool_call` /
  `tool_observation` / `pending_tool_call` events; per-tool approval
  UI; additive history schema migration with pre-migration snapshot;
  per-turn budgets via `policy.yaml` `agent:` block; documented
  rollback in `docs/TROUBLESHOOTING.md`. **Documented deviation:**
  pi-mono logs are `0640` agent-owned rather than root-only, because
  the chat service does not run as root and needs to write them.
- **Phase 3** — complete. Six built-in skills ship under
  `payload/agent/skills/` and install to `/opt/ai-zombie/skills/`
  (root:root `0644`); operator-extensible skills live in
  `/etc/ubuntu-zombie/skills.d/` (same contract as `policy.yaml`);
  `payload/agent/skill_loader.py` selects skills by trigger-word match
  against the last *N* user messages and renders them with on-disk
  provenance into the pi-mono system prompt; `server.py` records a
  `skill_active` history event per active skill and the UI renders the
  source path so prompt injection via a skill stays visible (§6.4);
  `install.sh repair` re-deploys the catalogue and `install.sh verify`
  asserts each shipped skill is present.
- **Phase 4** — complete. **P4.1** realigned the per-turn budget
  defaults with [`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §6.1–§6.2
  (12 / 3) and made `max_elevated_calls_per_turn` an enforced
  soft-failure budget in `payload/agent/server.py` alongside the
  existing total-call budget in `payload/agent/pi_mono.py`. Both
  budgets now emit a synthetic `budget_exceeded` observation
  (recorded in the JSONL audit and the history `events` table) so
  the model ends the turn cleanly. `tests/smoke.sh` exercises both
  soft-failure paths against the stub bridge. **P4.2** closed as
  no-go without code change; rationale recorded in D8 above.

---

## 12. Out of scope

The following are explicitly *not* part of this plan, mirroring
[`UPGRADE-TO-PI.md`](UPGRADE-TO-PI.md) §7:

- GitHub Issues bridge.
- Replacing `policy.py`'s class taxonomy.
- Removing the Python chat service.
- New public listeners; the chat service stays loopback-only.
- Importing GMI's "runner is the blast radius" threat model.
- Code in the PR that introduces this document.

---

## 13. Definition of done (whole plan)

- All five phases merged in order.
- `make lint`, `make test`, `make package` green on the final
  migration release.
- `install.sh verify` green on (a) a freshly imaged Ubuntu host and
  (b) a host upgraded from the immediately prior Phase 1 release.
- [`CONFIGURATION.md`](CONFIGURATION.md),
  [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md),
  [`ARCHITECTURE.md`](ARCHITECTURE.md), and the secrets-file
  template reflect the new runtime, env vars, paths, and rollback
  procedure.
- The risk register (§10) has no open mitigations in `Phase ≤
  current release`.
- The decisions log (§11) reflects any Phase 4 measurement
  outcomes.
