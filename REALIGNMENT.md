# Realignment

> How to re-shape **Ubuntu Zombie** in the image of the two Forgejo
> Society precursors —
> [`github-minimum-intelligence`](https://github.com/japer-technology/forgejo-society/tree/main/FORGEJO-SOCIETY-INTRODUCTION/precursors/github-minimum-intelligence)
> and
> [`github-openclaw-intelligence`](https://github.com/japer-technology/forgejo-society/tree/main/FORGEJO-SOCIETY-INTRODUCTION/precursors/github-openclaw-intelligence) —
> while keeping its actual job: **a private, root-capable AI Systems
> Administrator account on an Ubuntu Desktop LTS machine.**

This document is not a roadmap commitment. It is a design realignment
that re-states the project against the *folder-as-activation,
git-as-memory, events-as-runtime* pattern those two precursors
established for repository-resident agents — and translates that
pattern, primitive by primitive, into something a sysadmin AI can live
inside on a single Ubuntu PC.

---

## 1. The pattern, in one paragraph

Both precursors share a single, austere shape:

- **The agent lives inside the substrate as a folder.** Drop
  `.github-minimum-intelligence/` (or `.github-openclaw-intelligence/`)
  into a repo and the agent exists; remove the folder and it does not.
- **Activation is presence, denial is absence.** A sentinel file
  (`ENABLED.md`) inside the folder must exist for any run to proceed —
  the first lifecycle step is a fail-closed guard that exits non-zero
  otherwise.
- **Events drive the loop.** GitHub Issues and comments are the only
  human input; GitHub Actions is the only runtime; the workflow runs,
  the agent thinks, the agent replies, the workflow ends.
- **State is committed.** Conversation transcripts, issue→session
  mappings, append-only memory, and every file change the agent makes
  are all *committed back to the repository* by the workflow.
- **Identity is a file.** `AGENTS.md` is the agent's standing orders;
  edit the file, change the agent.
- **Capability is a folder.** Skills are `SKILL.md` files in
  `skills/`; the allowlist is a JSON file. Adding a capability is
  adding a directory.
- **Authority is configured per actor.** A `trustPolicy` block names
  trusted GitHub users, semi-trusted roles, and an explicit
  "untrustedBehavior" — the agent reads who you are and decides what
  you may ask of it.
- **Limits are declared.** `maxTokensPerRun`, `maxToolCallsPerRun`,
  `workflowTimeoutMinutes` — the agent has a budget and a clock.
- **The lifecycle is a pipeline of discrete scripts.** `enabled.ts` →
  `preflight.ts` → install → `agent.ts`. Each step fails independently.
- **The kill switch is `git rm`.** Delete the sentinel, push, done.

Ubuntu Zombie today does almost none of this. It works — but it works
in the *opposite* shape: a privileged service on a host, configured by
installer flags, with state in SQLite, audit in JSONL, kill switches
buried in `systemctl`, and the agent's "identity" implied by source
code rather than declared in a file the operator owns.

Realignment is the work of inverting that.

---

## 2. The translation: repo → Ubuntu host

The precursors treat the **repository** as the body of the mind. For a
sysadmin agent the body is the **machine**. The translation is a small
set of substitutions:

| Precursor primitive | Repo realisation | Ubuntu Zombie realisation |
| --- | --- | --- |
| The substrate | a Git repository on GitHub | a single Ubuntu Desktop LTS host (and its local Git repo of state) |
| The activation folder | `.github-minimum-intelligence/` in the repo root | `/etc/ubuntu-zombie/` on the host (operator-owned, version-controlled) |
| The presence-is-permission rule | folder exists ⇒ workflow may run | folder + `ENABLED.md` exists ⇒ chat service starts |
| The event surface | GitHub Issues & comments | a local "issues" surface — see §6 — plus the chat UI |
| The runtime | GitHub Actions workflow | systemd-launched lifecycle scripts under `/opt/ai-zombie/lifecycle/` |
| Committed memory | `state/sessions/*.jsonl` & `state/issues/*.json` in the repo | a host-local Git repo at `/var/lib/ubuntu-zombie/state.git` (auto-committed by the runner) |
| Identity file | `AGENTS.md` | `/etc/ubuntu-zombie/AGENTS.md` |
| Sentinel | `ENABLED.md` (fail-closed) | `/etc/ubuntu-zombie/ENABLED` (fail-closed) |
| Capability surface | `skills/<name>/SKILL.md` + `config/skills.json` | `/etc/ubuntu-zombie/skills/<name>/SKILL.md` + `skills.json` allowlist |
| Settings | `.pi/settings.json` (provider, model, thinking, limits, trust policy) | `/etc/ubuntu-zombie/settings.json` (same shape) |
| Authority | `trustPolicy` over GitHub usernames & repo roles | `trustPolicy` over local Linux users, groups, and SSH key fingerprints |
| Limits | `maxTokensPerRun`, `maxToolCallsPerRun`, `workflowTimeoutMinutes` | same keys, same semantics |
| Kill switch | `git rm ENABLED.md && git push` | `rm /etc/ubuntu-zombie/ENABLED` (or `ubuntu-zombie disable`) |

The promise survives. The shape changes.

---

## 3. What Ubuntu Zombie has to give up

Realignment is mostly subtraction. The following pieces of the current
design have to be reframed — not necessarily deleted, but reframed as
*consequences* of the folder, not as *primary* mechanisms.

1. **The installer as the source of truth.** Today `scripts/install.sh`
   *is* the configuration: subcommands, environment variables, the
   `agent` user, UFW rules. Under realignment, the installer's only
   long-term job is to materialise the *folder* (`/etc/ubuntu-zombie/`)
   and the *lifecycle scripts*, and to ensure the sentinel is read
   before the chat service ever binds a socket.
2. **`policy.yaml` as a separate concept.** The precursors do not have
   a policy file; they have a `trustPolicy` block in
   `settings.json`, action gating at the tool layer, and skills with
   `allowBundled`. Action classes (`read_only`, `system_change`,
   `destructive`) survive — but as **skill metadata**, not as a parallel
   YAML kingdom.
3. **SQLite for conversation history.** Conversations belong in a Git
   repo on the host, one JSONL per session, committed by the runner
   after every turn. The operator can `git log` the history of the
   machine the way they can `git log` the history of any project.
4. **Audit log as a separate JSONL stream.** Audit *is* the commit
   history. Every approval, denial, and command execution is a commit
   on `state.git` with a structured trailer. `audit.log` becomes a
   convenience view, not the source of truth.
5. **`secrets/env` as the API-key home.** Secrets stay on disk with
   `0600` permissions, but the *contract* shifts: the chat service
   reads them only after `ENABLED` and `preflight` pass, and refuses
   to even start the LLM client if `settings.json` does not declare a
   provider for which a key is present.
6. **The chat UI as the only event surface.** The precursors taught
   that a *low-bandwidth, durable, queryable* event surface (issues)
   beats a chat tab. The chat UI stays for synchronous use; a local
   "issues" surface is added for the durable one (see §6).

---

## 4. The folder Ubuntu Zombie should grow into

```
/etc/ubuntu-zombie/                     # the activation folder
├── ENABLED                             # sentinel — service fails closed without this
├── AGENTS.md                           # the administrator's standing orders
├── settings.json                       # provider, model, thinking level, trustPolicy, limits
├── settings.schema.json                # validated by preflight
├── skills.json                         # bundled skill allowlist + extraDirs
├── extensions.json                     # capability metadata (sudo, apt, systemctl, GUI, …)
└── skills/                             # local & operator-authored skills
    ├── apt/SKILL.md
    ├── systemctl/SKILL.md
    ├── network/SKILL.md
    ├── disk/SKILL.md
    ├── gui/SKILL.md
    └── destructive/SKILL.md

/opt/ai-zombie/                         # the runtime (unchanged in spirit)
├── lifecycle/
│   ├── enabled.sh                      # step 1: fail-closed sentinel guard
│   ├── preflight.sh                    # step 2: validate settings.json, perms, secrets
│   ├── trust-level.sh                  # step 3: resolve actor → trusted/semi/untrusted
│   └── agent.py                        # step 4: run the agent loop
├── bin/                                # operator helpers (verify, doctor, repair, …)
└── secrets/
    └── env                             # 0600, read only after preflight passes

/var/lib/ubuntu-zombie/                 # the memory
└── state.git/                          # host-local Git repo, auto-committed
    ├── agents/main/sessions/*.jsonl    # one file per conversation
    ├── issues/                         # local "issue" surface — see §6
    │   ├── 1.json                      # mapping issue#1 → session file
    │   └── …
    └── memory.log                      # append-only long-term memory
```

Three properties matter:

- `/etc/ubuntu-zombie/` is **operator-owned** and **version-controllable**
  (the operator can `git init` it, push it to their own private remote,
  and have the same agent on every machine they own).
- `/var/lib/ubuntu-zombie/state.git` is **machine-owned** and **never
  pushed by default** — it is the host's diary, not a public artefact.
- `/opt/ai-zombie/` is **package-owned** and **replaceable** — wiping
  and reinstalling it must not change the agent's identity or memory.

---

## 5. The lifecycle pipeline

Today the chat service starts as a single systemd unit. Realignment
splits the start-up into an explicit, independently-failable pipeline,
exactly as `github-openclaw-intelligence` does with its TypeScript
lifecycle scripts:

| Step | Script | Purpose | Fails closed when |
| --- | --- | --- | --- |
| 1 | `enabled.sh` | Sentinel guard: does `/etc/ubuntu-zombie/ENABLED` exist? | file missing |
| 2 | `preflight.sh` | Validate `settings.json` against schema; check `secrets/env` perms; check log dirs; check `state.git` is initialised | any check fails |
| 3 | `trust-level.sh` | Resolve the *caller* (Linux UID, SSH key fingerprint, Tailscale identity) to one of `trusted` / `semi-trusted` / `untrusted` | unknown actor + `untrustedBehavior: block` |
| 4 | `agent.py` | Run the agent, post the reply, commit state | provider/network failure (chat-visible, not service-fatal) |

`ubuntu-zombie-chat.service` becomes a thin wrapper that runs steps 1–3
on start, and refuses to bind `127.0.0.1:7878` if any of them fail. The
operator's mental model is identical to the precursors': *the folder
decides whether the agent runs*.

---

## 6. The local "issues" surface

This is the single hardest translation. GitHub Issues give the
precursors three properties that an Ubuntu host does not get for free:

1. A **durable, addressable** conversation (issue #N).
2. A **second human channel** — comments — that is *not* a chat tab.
3. A **per-message identity** (the comment author is the actor whose
   trust level is resolved).

The realignment replaces "issue" with a small local construct that
keeps those three properties:

- An **issue** is a JSON file at
  `/var/lib/ubuntu-zombie/state.git/issues/<N>.json`, containing a
  title, a creator (Linux user / SSH key fingerprint / Tailscale
  identity), a creation timestamp, and a pointer to a session file
  under `agents/main/sessions/`.
- **Opening an issue** is one of:
  - `ubuntu-zombie issue new "disk is full again"` from a shell,
  - clicking *New conversation* in the chat UI,
  - or, post-MVP, sending an email to a local-only address handled by
    a Postfix → script transport (described in `docs/ROADMAP.md`
    territory, not the MVP).
- **Commenting** is `ubuntu-zombie issue comment <N> "and now I cannot
  ssh in"` or continuing the conversation in the chat UI. Every
  comment is appended to the JSONL session and committed.
- **The agent** is invoked exactly once per comment (or by a webhook
  equivalent — see §10), runs the lifecycle pipeline, posts its
  reply as the next entry in the JSONL, and `git commit`s.

The point is not that operators have to use the CLI. The point is that
**the conversation is a file**, **the file is committed**, and
**replaying history is `git log`** — not a SQL query against a
service-private database.

---

## 7. Identity, authority, and the trust policy

The precursors gate every action through three layers:

1. **Identity** — a `trustedUsers` list of GitHub usernames.
2. **Role** — `semiTrustedRoles` over repo permissions.
3. **Default** — `untrustedBehavior` for everyone else.

On a single-operator Ubuntu host this collapses to:

```json
{
  "trustPolicy": {
    "trustedUsers": ["eric"],
    "trustedKeyFingerprints": ["SHA256:abc…"],
    "trustedTailnetTags": ["tag:owner"],
    "semiTrustedGroups": ["sudo"],
    "untrustedBehavior": "read-only-response"
  }
}
```

Resolution order, computed by `trust-level.sh`:

1. If the caller's Linux username is in `trustedUsers` **or** their
   SSH key fingerprint is in `trustedKeyFingerprints` **or** their
   Tailscale identity carries a `trustedTailnetTags` tag → `trusted`.
2. Else if they are a member of any `semiTrustedGroups` → `semi-trusted`.
3. Else → apply `untrustedBehavior`.

The existing **action classes** (`read_only`, `user_change`,
`system_change`, `network_change`, `destructive`) survive — but as
metadata on each `SKILL.md`. Trust level × action class produces the
gate:

| Action class \ Trust | `trusted` | `semi-trusted` | `untrusted` |
| --- | --- | --- | --- |
| `read_only` | auto | auto | answer-only (no execution) |
| `user_change` | approval | approval | blocked |
| `system_change` | approval | blocked | blocked |
| `network_change` | approval | blocked | blocked |
| `destructive` | approval + phrase | blocked | blocked |

This is the same matrix the existing `policy.yaml` encodes, expressed
in the precursors' vocabulary, with no separate file format.

---

## 8. Skills, not subcommands

Today the agent's capabilities are baked into Python in
`/opt/ai-zombie/agent/runner.py` and friends. Under realignment, every
discrete capability is a **skill**: a directory with a `SKILL.md` file
describing the capability, its action class, its allowed binaries, and
its preconditions. A minimal initial set:

| Skill | Action class | Wraps |
| --- | --- | --- |
| `system-status` | `read_only` | `systemctl status`, `journalctl --no-pager`, `df`, `free`, `uptime` |
| `apt` | `system_change` | `apt update`, `apt install`, `apt upgrade`, `apt remove` |
| `systemctl` | `system_change` | `systemctl {start,stop,restart,enable,disable}` |
| `network` | `network_change` | `ufw`, `ip`, `tailscale up/down`, `resolvectl` |
| `disk` | `system_change` / `destructive` | `mount`, `fsck`, `lsblk`, `mkfs`, `dd` |
| `users` | `user_change` / `destructive` | `useradd`, `usermod`, `passwd`, `userdel` |
| `gui` | `read_only` / `user_change` | `screenshot`, `click`, `type-text`, `key` (Playwright/x11vnc helpers) |
| `logs` | `read_only` | `tail`, `grep`, `journalctl`, log rotation queries |
| `diagnostics` | `read_only` | `collect-diagnostics` bundle |
| `healthcheck` | `read_only` | `health-check`, `verify` |

Each skill declares its action class explicitly in `SKILL.md`. The
allowlist of skills the agent is permitted to load lives in
`/etc/ubuntu-zombie/skills.json`. Disabling a capability is removing
its line from the allowlist — *not* a code change.

This is also the **extension point** the project has needed: third
parties can ship skills (e.g. `cups`, `nvidia-smi`, `zfs`,
`fail2ban`) without modifying the runtime.

---

## 9. Memory is a Git repo

`/var/lib/ubuntu-zombie/state.git/` is a real Git repository, owned by
the `agent` user, initialised by the installer, never pushed by
default. Every lifecycle iteration ends with:

```
git -C /var/lib/ubuntu-zombie/state.git add -A
git -C /var/lib/ubuntu-zombie/state.git commit -m "<actor>: <action-class> — <one-line summary>" \
    --trailer "Approval-ID: <uuid>" \
    --trailer "Skill: <skill-name>" \
    --trailer "Exit-Code: <n>" \
    --trailer "Tokens: <prompt>/<completion>"
```

This gives the operator, for free:

- **An audit log they already know how to read** (`git log`, `git
  blame`, `git show`).
- **A rollback story** — `git revert` a destructive commit to recover
  state files the agent edited (note: the *operating system* is not
  inside `state.git`; this is about the agent's *own* state and any
  config files it stages there before applying).
- **An offline backup story** — `git bundle create` is the diagnostics
  bundle.
- **An optional sync story** — operators who want a fleet view can
  configure a private remote and push read-only.

The existing `audit.log` becomes a *derived* JSONL view emitted by a
post-commit hook, kept for log-rotation and `journalctl`-style
consumption.

---

## 10. The event loop, made explicit

Mirroring the precursors' flowchart, the realigned Ubuntu Zombie loop
is:

```
START
  An issue is created or commented on (CLI, chat UI, or hook)
     │
     ▼
ENABLED? ──no──▶ exit non-zero, log "disabled" to journal
     │ yes
     ▼
PREFLIGHT? ──no──▶ exit non-zero, surface error in chat UI
     │ yes
     ▼
TRUST-LEVEL  (resolve actor → trusted/semi/untrusted)
     │
     ▼
LOAD SESSION  (issues/<N>.json → sessions/<file>.jsonl)
     │
     ▼
AGENT  (provider + model + thinking + skills, gated by trust × class)
     │
     ▼
APPLY  (sudo wrapper, approval IDs, stdout/err/exit captured)
     │
     ▼
SAVE   (append to sessions/, write reply, git commit -m … --trailer …)
     │
     ▼
REPLY  (post comment in the local issue, surface in chat UI)
     │
     ▼
END
```

It is the same diagram as `github-minimum-intelligence`'s mermaid flow,
with "GitHub Actions" replaced by "systemd-launched lifecycle
scripts", "issue comment" replaced by "local issue comment", and
"git commit & push to origin" replaced by "git commit to local state
repo".

---

## 11. The kill switch

Today the kill switches are scattered: revoke the API key, `systemctl
stop`, `ufw disable`, `tailscale logout`, `uninstall.sh`. Realignment
gives the operator one obvious lever — the precursors' lever:

```
sudo rm /etc/ubuntu-zombie/ENABLED        # or:
sudo ubuntu-zombie disable
```

Effect: the next lifecycle run exits at step 1. The chat service stays
up to *explain* the disablement (a static "the administrator is
disabled — restore /etc/ubuntu-zombie/ENABLED to re-enable" page), but
no LLM call, no `sudo` call, no skill is ever invoked. Re-enabling is
recreating the file. Every other kill switch (API-key rotation,
Tailscale logout, full `uninstall`) continues to work as today, and
*also* continues to be a valid escalation, but the **default,
discoverable, reversible** kill switch is the sentinel.

This matches the precursors' `ENABLED.md` semantics and the
`github-intelligence-emergency` precursor's principle quoted in the
`FORGEJO-SOCIETY-INTRODUCTION/precursors/README.md`:

> *true control belongs to the one who can destroy a thing.*

---

## 12. What this realignment is **not**

To preserve the project's actual promise (`docs/VISION.md`), the
realignment explicitly does *not*:

- Move execution off the host. The substrate is still the Ubuntu PC.
  GitHub is not part of the trust boundary.
- Introduce multi-tenant or fleet control. One machine, one operator
  remains the model.
- Take the operator out of the loop. Approval gating, action classes,
  audit, and revocation all stay.
- Replace the chat UI. It survives as the synchronous surface; the
  durable surface is the local "issues" mechanism.
- Require an internet connection beyond the LLM provider. `state.git`
  is local; `extensions.json`, `skills.json`, `AGENTS.md` are all
  on-disk.

---

## 13. Order of work

A non-binding sketch of how to get from the current shape to the
realigned shape, in increments that each leave the project shippable.

1. **Sentinel.** Add `enabled.sh` as a `PreExec` in the systemd unit;
   create `/etc/ubuntu-zombie/ENABLED` from the installer; document
   `ubuntu-zombie disable` / `enable`.
2. **Identity file.** Move the system prompt out of code into
   `/etc/ubuntu-zombie/AGENTS.md`. Load at start.
3. **Settings file.** Replace ad-hoc env vars with
   `/etc/ubuntu-zombie/settings.json` validated against
   `settings.schema.json` by `preflight.sh`. Provider, model, thinking
   level, trust policy, limits.
4. **Trust resolver.** Implement `trust-level.sh` for Linux UID + SSH
   fingerprint + Tailscale identity. Document the resolution order.
5. **Skills.** Refactor the runner's hard-coded action helpers into
   `SKILL.md`-described skills under
   `/etc/ubuntu-zombie/skills/`. Keep `policy.yaml` working in
   parallel during migration; remove once skills cover its action
   classes.
6. **`state.git`.** Initialise the repository at install time, move
   the SQLite history into JSONL session files, commit on every turn,
   emit `audit.log` from a post-commit hook.
7. **Local issues.** Add the `ubuntu-zombie issue {new,comment,list}`
   CLI; mirror the surface in the chat UI; route every conversation
   through it.
8. **Lifecycle script split.** Make the systemd unit a thin runner of
   the four-step pipeline, each step independently testable in CI.
9. **Documentation.** Update `ARCHITECTURE.md` to show the folder, the
   pipeline, and the trust matrix; cross-link this `REALIGNMENT.md`
   from `README.md` and `docs/VISION.md`.

Each step can land on its own. None of them require the others to
have already landed.

---

## 14. Why bother

Because the precursors discovered something that applies far beyond
GitHub: when an AI agent's substrate, activation, identity, capability,
authority, memory, and kill switch are **all just files in a folder
the operator owns**, the agent becomes legible. You can read it. You
can `git diff` it. You can hand it to another operator. You can put
it under version control and watch its history. You can delete one
file and disable it.

Ubuntu Zombie's existing promise — *"a private, root-capable AI
Systems Administrator account so a novice owner can ask the machine to
diagnose, explain, configure, repair, and operate itself"* — is a
strictly stronger demand than the precursors faced. The agent here has
`sudo`. Making it legible is therefore not a nicety; it is the only
honest way to keep the trust model the README already claims.

The realignment described above is how to keep that promise in the
shape the precursors proved.
