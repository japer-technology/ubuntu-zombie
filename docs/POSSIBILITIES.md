# Possibilities — a council of zombies on one PC

> **Status:** exploratory analysis, not a roadmap commitment. The MVP
> described in [`VISION.md`](VISION.md) is deliberately *one* AI
> Systems Administrator on *one* machine. This document explores what
> changes — technically, operationally, and in the trust model — if a
> single PC could host *several* named AI personas (for example
> `sysadmin`, `analyst`, `logreporter`, `librarian`, `scribe`) that
> the operator addresses by name through a shared UX.

The prompt: *"What if the 'zombie' could be installed a number of
times — `SysAdmin`, `ComputerAnalyst`, `LogReportAnalyser`, etc — so
the PC carries a collection of AI intelligences that the operator
addresses by name in a common UX?"*

The honest short answer is: **most of the plumbing already exists,
but the trust model, the audit story, and the UX must be redesigned
before this is safe to ship.** This file walks through why.

---

## 1. What the current architecture assumes

Ubuntu Zombie today is built around a small set of singletons. They
are documented in [`ARCHITECTURE.md`](ARCHITECTURE.md), but worth
restating here because every multi-persona option below either
multiplies, partitions, or virtualises one of them:

| Singleton | Where it lives | Why it is singular |
|-----------|----------------|--------------------|
| `zombie` Linux user (renameable) | `/home/zombie`, passwordless `sudo`, `docker` group | One operating identity → one audit attribution |
| Chat service | `ubuntu-zombie-chat.service`, bound to `127.0.0.1:7878` | One UI URL, one port, one process to supervise |
| Policy file | `/etc/ubuntu-zombie/policy.yaml` | One classification table for the whole machine |
| Closed tool registry | `payload/agent/tools.py` | One audited surface; expanding it requires a release |
| Secrets store | `/opt/ai-zombie/secrets/env` (mode `0600`) | One API key, one VNC password |
| Audit log | `/var/log/ubuntu-zombie/audit.log` (JSONL) | One linear, redacted record of what happened |
| SQLite history | `/opt/ai-zombie/state/conversations.db` | One conversation namespace |
| GUI session | Xorg + GDM + x11vnc on `:5900` | One desktop the agent can see and click |
| Health timer | `ubuntu-zombie-health.timer` | One liveness signal |

A "council of zombies" design has to answer, for each of those rows,
the same question: **shared, partitioned, or replicated?**

---

## 2. Three shapes the idea can take

The phrase *"installed a number of times"* can mean very different
things. The cost, blast radius, and UX are different for each.

### 2.1  Shape A — one body, many personas (lightest)

One `zombie` Linux user, one chat service, one tool registry, one
audit log. Personas are *configurations* loaded by the same agent:
different system prompts, different skill subsets, different default
LLM models, optionally different per-persona policy overlays. The
operator picks a persona in the UI (or `@mentions` one) and the
backend swaps which prompt, skill catalogue, and policy view is
active for that turn.

- **What changes in code:** `providers.py`, `skill_loader.py`,
  `pi_mono.py`, and the chat templates gain a `persona` field.
  `policy.yaml` grows an optional `personas:` map of per-persona
  overrides. `history.py` adds a `persona` column to `messages`.
  `audit.py` records the active persona on every `tool_call` event.
- **What does *not* change:** the Linux user, the sudo allow-list,
  the open ports, the secrets file, the kill switch, the installer.
- **What you gain:** named "characters" with focused prompts and
  skill sets. Cheap, fast, no new attack surface.
- **What you do *not* gain:** real isolation. A prompt-injected
  "Librarian" can still call any tool the "SysAdmin" can, because
  they share the same process, the same sudoer, and the same API
  key. Personas here are an *ergonomic* feature, not a *security*
  feature.

### 2.2  Shape B — one body, many Linux accounts (middle)

Each persona is its own Unix user (`zombie-sysadmin`,
`zombie-analyst`, `zombie-logs`, …), each with its own home, its own
Python venv, its own systemd unit, its own loopback port, and its
own row in the `sudoers.d` allow-list. A thin shared "front desk"
service (the common UX) talks to whichever backend the operator
named.

- **What changes in code:** the installer is rewritten to be
  *persona-parameterised* — every per-user path
  (`/opt/ai-zombie/...`, `/etc/ubuntu-zombie/...`, the systemd unit
  name, the port, the secrets file) gains a persona suffix. A new
  small router (call it `ubuntu-zombie-frontdesk.service`) hosts the
  common UI and proxies turns to the addressed backend.
- **What you gain:**
  - Real OS-level isolation between personas: file permissions,
    process boundaries, separate audit logs, separate sudo
    allow-lists. A compromised "LogReporter" cannot read the
    "SysAdmin"'s history database.
  - Per-persona privilege minimisation. The `LogReportAnalyser`
    plausibly never needs `apt`, `ufw`, or `tailscale` — it gets a
    much smaller `sudo_allow_list` and a `default_class` of
    `read_only`. That is a genuine security win the current single
    `zombie` cannot express.
  - Per-persona LLM provider / model / cost ceiling — see §4.
- **What you must accept:**
  - More moving parts (N×) to install, verify, doctor, repair,
    upgrade, and uninstall. The installer's "one privileged user,
    one service" simplicity (a deliberate property of the MVP, see
    `VISION.md` §"What the MVP promises") is gone.
  - The audit story doubles: each persona has its own log, *and*
    the front desk has a routing log. Both have to be inspectable.
  - GUI sharing — see §6.

### 2.3  Shape C — one host, many containers / VMs (heaviest)

Each persona lives in its own container (rootless Podman, LXD, or a
microVM). The host runs only the front desk and the orchestration
plumbing. Personas talk to the host through a narrow, audited RPC.

- **What you gain:** the strongest isolation. Personas can run
  different distributions, different LLM client libraries, different
  Python versions; a compromise stays in the box.
- **What you give up:** the *core promise* of Ubuntu Zombie — that
  the agent administers *this very machine* with `sudo` on the host
  — does not survive containerisation without explicit, audited
  host-side capability grants. You have effectively rebuilt a
  fleet-management plane on a single PC. At that point the right
  comparison is Kubernetes-of-one or a multi-tenant agent
  platform, not Ubuntu Zombie. This shape is interesting for
  *sandboxed* personas (research, scraping, untrusted code
  execution) coexisting with one privileged SysAdmin on the host,
  but it is not what makes Ubuntu Zombie distinctive.

A pragmatic synthesis: **Shape A for ergonomics, Shape B for
privilege separation between trusted personas, Shape C as an
optional "sandbox persona" slot** for work that should never touch
the host. The rest of this document assumes the operator wants the
combination, and analyses the consequences.

---

## 3. A common UX for addressing many minds

The user phrases this as *"address them by name in a common UX"*.
That is the right framing — the value is not "N chat windows", it
is *one* place where the operator runs the household.

Design surface worth thinking about:

- **Name resolution.** Personas are addressed by short, stable
  names (`@sysadmin`, `@analyst`, `@logs`). Names map to backends
  through a registry at `/etc/ubuntu-zombie/personas.d/*.yaml` so
  operators can add, rename, or disable a persona without editing
  the front desk.
- **Default routing.** A message with no `@mention` either goes to
  a configured *default persona* (likely `@sysadmin` for
  continuity with the MVP) or to a tiny *dispatcher* that classifies
  the request and proposes which persona should take it ("This looks
  like a `journalctl` question — route to `@logs`?"). The
  dispatcher must never *act*; it only *routes* and the operator
  confirms.
- **Cross-persona handoff.** A turn started by `@sysadmin` should
  be able to say *"ask `@logs` to summarise yesterday's failures
  and bring it back"*. Modelled as a tool call (`ask_persona`) so
  it lives in the closed tool registry and is audited, including
  the prompt one persona sent to another and the reply it received.
- **A "council" view.** The same prompt fanned out to several
  personas in parallel, returning their answers side by side. Cheap
  to implement on top of `ask_persona`; valuable for triage ("what
  do you each think is wrong?") and as a poor person's ensemble.
- **Conversation namespace.** Each persona owns its own
  conversation thread by default, but the front desk shows the
  unified timeline. Operators can pin a thread to "all personas can
  see this", which is the explicit equivalent of a shared
  whiteboard.
- **Approval prompts stay per-call, not per-persona.** A
  `system_change` from `@sysadmin` still needs a click; `@logs`
  classified as `read_only` truly auto-runs. Persona identity is
  *one input* to the policy gate, not a replacement for it.

A useful UI mental model: **one inbox, many staff**. Slack with
five colleagues, not five Slacks.

---

## 4. Configuration that becomes per-persona

Once personas exist, several knobs that today are single global
values become per-persona, and that is where most of the design
benefit lives. A `/etc/ubuntu-zombie/personas.d/analyst.yaml` might
specify:

- **Identity:** `name`, `display_name`, `description`, optional
  avatar / colour for the UI.
- **Backend selection:** Linux user (Shape B) or shared user
  (Shape A); container image (Shape C).
- **Model and provider:** different LLMs per persona (a cheap fast
  model for `@logs`, a stronger model for `@sysadmin`,
  long-context for `@librarian`). Each persona can have its own API
  key so spend can be split and rotated independently.
- **Skill catalogue:** which Markdown skills from
  `/opt/ai-zombie/skills/` and
  `/etc/ubuntu-zombie/skills.d/` this persona may load. A
  `LogReportAnalyser` plausibly loads only `systemd.md` and a new
  `logs.md`; it does not need `apt.md`, `docker.md`, `ufw.md`.
- **Tool subset / policy overlay:** a persona-scoped view of the
  closed tool registry — for example "may call `runner.run` but
  only with programs from this allow-list", "may read paths under
  `/var/log` and `/etc` but never write", "destructive class is
  forbidden, not just gated". This is the most important new
  primitive and the one that most needs adversarial review before
  shipping.
- **Resource ceilings:** per-turn budgets (today: 12 tool calls / 3
  elevated), monthly token budget, monthly USD budget, max parallel
  turns. Per persona, with the front desk enforcing global ceilings
  on top.
- **Schedule and triggers:** *some* personas are best as
  always-on respondents (`@sysadmin`), some are best as scheduled
  workers (`@logreporter` runs at 06:00 daily and posts a
  summary), some are best as event-driven (`@health` triggers when
  the health timer reports a regression).

The shape of this file matters less than the *fact* that policy and
identity can be expressed per persona. Today's
`policy.yaml` is a strong primitive; per-persona overlays on top of
it would be a natural extension that does not break existing
operators.

---

## 5. Trust model — what gets harder, what gets easier

This is the section that decides whether the idea is *good* or just
*fun*.

**What gets harder:**

- **Privilege multiplication.** Five personas with `sudo` is five
  ways onto the box. The mitigation is to make most personas
  *non-sudoers*. The MVP's single privileged `zombie` becomes, in
  the multi-persona world, *one* privileged role; `@analyst`,
  `@logs`, `@scribe` should not be in `sudoers.d` at all.
- **Audit attribution.** Today every line in `audit.log` is by
  `zombie`. Tomorrow every line must carry `persona=…`,
  `caller=operator|persona`, and (for cross-persona calls) a
  `cause=` chain. Without that, post-hoc analysis of *"who did
  this?"* becomes impossible.
- **Secrets sprawl.** N API keys, N VNC passwords (if they share
  the desktop), N session caches. `secrets-edit` becomes a
  per-persona command, and key rotation is now an N-way operation.
  An operator running `secrets-edit @sysadmin` must not be able to
  read `@analyst`'s key by accident — file permissions on
  `/opt/ai-zombie/<persona>/secrets/env` carry that weight.
- **Cross-persona prompt injection.** If `@logs` reads attacker
  content and then hands `@sysadmin` a "summary", a prompt
  injection has now jumped from a low-privilege persona to a
  high-privilege one through `ask_persona`. The fix is to treat
  *anything coming from another persona* as untrusted input — the
  receiving persona must re-apply policy classification before
  acting on it, and must never auto-elevate based on "another
  persona asked me to". This is identical to the rule a careful
  Unix admin already uses for piped input; making it explicit in
  the tool registry is the work.
- **GUI contention.** There is one X display. If two personas both
  want to drive `xdotool`, the desktop is a shared mutable
  resource. Either personas serialise on a GUI lock, or only one
  persona at a time owns the desktop, or non-GUI personas literally
  do not have the GUI helpers in their tool subset (the
  cheapest, safest answer, and aligned with §4).

**What gets easier:**

- **Per-persona least privilege.** The MVP gives the single
  `zombie` enough authority to run everything because *some*
  workflows need it. With personas, the strong sudoer is one role,
  not the default — most personas are strictly weaker than today's
  `zombie`. This is a real security improvement, not a regression,
  *if* operators do not casually grant every persona `sudo`.
- **Cost containment.** Per-persona budgets and provider keys mean
  a runaway `@analyst` cannot drain the `@sysadmin`'s key.
- **Disposability.** `uninstall @analyst` is a much smaller
  operation than `uninstall`. The composability that
  `install.sh install / verify / doctor / repair / uninstall`
  already provides is a good fit for per-persona lifecycle
  commands — and it preserves the operator's existing mental model
  rather than introducing a new one.
- **Specialisation of skills.** A skill written for one persona
  (e.g. a domain-specific `kafka.md` for `@platform`) does not
  pollute the others' prompts, which keeps the SysAdmin focused on
  the SysAdmin's job and reduces accidental tool calls.

The honest summary: **multi-persona makes the system safer in the
common case (most personas are weaker than today's `zombie`) and
more dangerous in the worst case (a compromised privileged persona
can act *through* another persona via `ask_persona`).** The
worst-case mitigations are the work that has to be done.

---

## 6. Practical questions before any of this ships

These are the questions a design doc would have to answer, in roughly
the order they would block implementation.

1. **Is the front desk a new service, or the existing chat service
   in "router" mode?** Reusing the existing service keeps one
   process to supervise; splitting it keeps the boundary clean.
2. **One port (the front desk) or N ports (one per persona)?** One
   port is dramatically simpler for the operator's SSH local-forward
   workflow (`ssh -L 7878:127.0.0.1:7878`) and avoids a second
   thing to remember. The persona becomes a path or header, not a
   port.
3. **How does a persona declare itself?** A file in
   `/etc/ubuntu-zombie/personas.d/`, owned by `root`, validated by
   `install.sh verify`, with a schema documented next to
   `policy.yaml`. Adding a persona is therefore an explicit operator
   act, not an LLM act.
4. **Can a persona create or delete another persona?** No. Persona
   lifecycle must be an operator-only, root-only operation, just
   like the install/uninstall it extends. If an LLM can spawn an
   LLM, the audit boundary has been quietly deleted.
5. **What is the upgrade story?** A single `VERSION` file today
   pins everything. With personas, either all personas upgrade
   atomically (simpler, what the MVP would do) or personas pin
   their own versions (more flexible, more matrix to test). Start
   with the former.
6. **What is the uninstall story?** `uninstall` removes
   everything. `uninstall --persona analyst` removes one persona.
   `uninstall` without `--persona` must continue to mean "remove
   everything", to preserve the existing kill-switch contract from
   `VISION.md`.
7. **How is the per-persona audit log surfaced to the
   operator?** `audit-recent --persona analyst`, with the default
   showing a merged view, tagged by persona, sorted by time. The
   merged view is what an operator actually wants when something
   went wrong at 03:00.
8. **What does the health timer check, per persona?** Each persona
   has its own service and its own port; the existing health-check
   pattern works once it learns to iterate the persona registry.
9. **How does `tailscale` exposure change?** Not at all. Only the
   front desk needs to be reachable over Tailscale; persona
   backends stay on `127.0.0.1` and are addressed *through* the
   front desk.
10. **How is "addressing by name" learned by the operator?** The
    UI shows a roster of installed personas with a one-line
    description and a "what I can do" badge derived from the
    persona's skill catalogue and policy overlay. `@-completion`
    inline. Empty `@` lists everyone. Discoverability beats
    elegance here.

---

## 7. A phased path that does not break the MVP

If the project decided to pursue this, the cheapest order that keeps
the MVP intact at every step is roughly:

- **Phase 0 — naming.** Rename internal references from "the
  zombie" to "the SysAdmin persona", in code comments, docs, and
  UI strings. No behavioural change. Single persona. This costs
  nothing and unblocks every later phase.
- **Phase 1 — Shape A.** Introduce `persona` as a first-class
  field in the agent loop, the chat UI, the history schema, and the
  audit events. Ship with exactly one persona (`sysadmin`) so the
  MVP's behaviour and footprint are unchanged. The plumbing exists,
  the surface does not yet.
- **Phase 2 — per-persona prompt and skill set.** Allow defining
  a second persona that *shares* the `zombie` user (Shape A) but
  has its own prompt and skill subset. Ergonomics only, no new
  trust boundary. A natural first second persona is something
  read-only like `@analyst` or `@logs`, because the safety story
  is easy.
- **Phase 3 — per-persona policy overlay.** Add the policy
  overlay primitive so personas can be *strictly weaker* than the
  default policy. This is what unlocks "most personas are not
  sudoers" as a default posture even before per-persona Linux
  users exist.
- **Phase 4 — Shape B for new personas.** Add the installer
  support for per-persona Linux users, systemd units, secrets
  directories, and audit logs. Existing single-persona installs
  keep working unchanged.
- **Phase 5 — `ask_persona` tool and the council view.** Now
  that there is a real boundary between personas, cross-persona
  calls become meaningful and auditable.
- **Phase 6 (optional) — Shape C sandbox slot.** A single
  *containerised* persona type for untrusted work, with a narrow
  RPC to the host. Only worth doing if a real use case demands it.

At every phase the existing properties hold: one installer, one
operator, one kill switch, every privileged action policy-gated
and audit-logged.

---

## 8. Where this fits relative to existing docs

- [`VISION.md`](VISION.md) defines the MVP as *one* AI Systems
  Administrator. Nothing in this document contradicts that vision;
  it explores what a future version could become without abandoning
  it.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) is the canonical map of
  what exists today. Every "singleton" in §1 above corresponds to
  a concrete component there.
- [`CONFIGURATION.md`](CONFIGURATION.md) is where a per-persona
  configuration schema would eventually be documented.
- [`SIMILAR.md`](SIMILAR.md) and the `ALTERNATIVE-*.md` set
  catalogue adjacent projects; a multi-persona Ubuntu Zombie would
  occupy a niche between *"one root-capable agent"* (today) and
  *"a personal agent platform"* (the things those documents
  survey).

---

## 9. Recommendation

A "council of zombies" is a *good idea phrased as an ergonomic
feature* (Shape A) and a *non-trivial security project phrased as
a platform* (Shapes B and C). The right move, if the maintainers
want to pursue it, is to take the cheap ergonomic win first —
Phases 0 through 3 — because those are reversible, do not enlarge
the attack surface, and immediately make the product feel like
*"my PC has staff"* rather than *"my PC has an assistant"*.
Shapes B and C only become worth their complexity once an operator
has a concrete second persona whose privileges should *differ* from
the SysAdmin's, and the policy overlay from Phase 3 makes that
difference enforceable rather than aspirational.

Until then, the MVP's *one* zombie is not a limitation — it is the
strongest part of the trust model, and the thing that lets the
project keep its one-paragraph trust story. Any multiplication must
preserve that paragraph.
