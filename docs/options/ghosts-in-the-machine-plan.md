# Plan: ghosts in the machine — many agents from one Ubuntu Zombie

## Goal

Expand `scripts/install.sh` so that the thing it installs today — *one*
root-capable AI Systems Administrator — becomes **one instance of a
general shape**: a *ghost*. A ghost is a named agent persona with its own
Linux account, its own loopback port, its own install tree, its own
policy, its own audit trail, and — the part that does not exist yet —
its own **capability tier**, which is enforced by code and by the
operating system rather than by prompt text.

Three ghosts are named by this plan, and the mechanism must accept any
number more:

| Ghost | Role | Tier | User | Port | Install root |
| ----- | ---- | ---- | ---- | ---- | ------------ |
| **Ubuntu Zombie** | Root AI Systems Administrator | `root` | `zombie` | `7878` | `/opt/ai-zombie` |
| **Imaginary Friend** | Artificial Friend | `hermit` | `friend` | `6767` | `/opt/ai-friend` |
| **Curriculum Flame** | Child AI Access Engine | `tutor` | `flame` | `5656` | `/opt/ai-flame` |

- **Zombie** keeps everything it has today, byte for byte, and stays the
  default target.
- **Friend** is a completely defanged zombie: it can change files in its
  own folder and talk in its own chat UI. Nothing else. No shell, no
  `sudo`, no packages, no services, no network tools, no reading the rest
  of the disk.
- **Flame** is a defanged zombie that may additionally create and edit
  files in a nominated *learner* workspace, and that runs every turn
  through the curriculum gate described in
  [`curriculum-gates-local-ai-for-children.md`](curriculum-gates-local-ai-for-children.md)
  and specified in full by the sibling project
  [`japer-technology/curriculum-flame`](https://github.com/japer-technology/curriculum-flame).

The deliverable of this plan is *the chassis*: a repeatable, idempotent,
reversible way to stand up N differently-capable agents on one Ubuntu
Desktop LTS machine, where each one's limits are structural.

## Decision required before any code is written

[`docs/VISION.md`](../VISION.md) says: **"One machine, one operator, one
trust boundary."** This plan puts *several* trust boundaries on one
machine — a root agent for the owner, a companion for a household
member, a gated tutor for a child. That is a deliberate widening of the
product, not an implementation detail, and it needs an explicit
maintainer decision before Phase 0 starts.

The narrowest reading that keeps the vision intact, and the one this plan
assumes:

> There is still **one operator** — the human who owns the machine and
> runs `install.sh`. Ghosts are not tenants and not administrators. A
> child talking to Flame is a *user of a ghost*, never an operator of the
> machine: they cannot install, configure, approve, or inspect anything.
> Every ghost is created, bounded, and destroyed by the one operator, and
> every ghost's boundary is enforced against the ghost, not negotiated
> with it.

If that reading is rejected, this plan should stop at Phase 2 (Friend)
and Flame should live entirely in the `curriculum-flame` project.

## Why this is more than "run the installer twice"

Running `ZOMBIE_USER=friend ZOMBIE_CHAT_PORT=6767 ZOMBIE_DIR=/opt/ai-friend
./scripts/install.sh install` today produces a second *root* agent and
quietly corrupts the first. The concrete blockers, in the order they
bite:

1. **Single-agent globals.** `AGENT_USER`, `AGENT_HOME`, `ZOMBIE_DIR`,
   `ZOMBIE_ETC`, `ZOMBIE_LOG_DIR`, and `CHAT_PORT` are one set of script
   globals in [`scripts/install.sh`](../../scripts/install.sh) (the block
   near line 61), mirrored in
   [`scripts/uninstall.sh`](../../scripts/uninstall.sh). There is exactly
   one of each per run.
2. **One manifest slot per component.** The registry contract in
   [`scripts/component-registry.sh`](../../scripts/component-registry.sh)
   keys everything by component name, and
   `/var/lib/ubuntu-zombie/components/zombie` is a single file. A second
   run overwrites the first ghost's manifest and orphans its account.
3. **Fixed unit names.** `ubuntu-zombie-chat.service`,
   `ubuntu-zombie-health.service`, and `ubuntu-zombie-health.timer` are
   literals. A second install fights the first for the same units.
4. **Fixed command names.** The `/usr/local/bin` symlinks
   (`zombie-chat`, `audit-recent`, `secrets-edit`, `zombie-health`,
   `zombie-diagnostics`, `zombie-verify`) are global and unqualified.
5. **One audit log.** `/var/log/ubuntu-zombie/audit.log` is mode `0640`
   owned by the single agent user. A second ghost either cannot write it
   or can read the first ghost's history — both unacceptable.
6. **One receipt, one splash.** `install-receipt.txt` is a single file
   and [`scripts/lib.sh`](../../scripts/lib.sh) hard-codes
   `http://127.0.0.1:7878` in the banner.
7. **No way to remove a capability.** This is the deep one.
   `TOOL_REGISTRY` in [`payload/agent/tools.py`](../../payload/agent/tools.py)
   is a module constant; [`payload/etc/policy.yaml`](../../payload/etc/policy.yaml)
   can only *reclassify* a tool, never delete it — and the highest class,
   `destructive`, is still reachable by anyone who types the confirmation
   phrase. Read/write allow-lists (`_read_allowed_prefixes`,
   `_write_allowed_prefixes`) are fixed constants that include `/etc`,
   `/proc`, `/sys`, `/var/log`, `/usr/share`, and `/tmp`. **There is no
   configuration today that produces a genuinely defanged agent.**
8. **Branding is cosmetic.** `/rebrand` is a browser-local preference in
   [`payload/agent/templates/index.html`](../../payload/agent/templates/index.html);
   the service, the prompt template in
   [`payload/agent/server.py`](../../payload/agent/server.py), and the
   unit description all say "Ubuntu Zombie".

The good news is item 7's mirror image: the Python runtime is *already*
instance-shaped. `ZOMBIE_DIR`, `ZOMBIE_USER`, `ZOMBIE_CHAT_PORT`,
`ZOMBIE_POLICY`, `ZOMBIE_AUDIT_LOG`, `ZOMBIE_HISTORY_DB`,
`ZOMBIE_LIFECYCLE_STATE`, `ZOMBIE_SKILLS_DIR`, and
`ZOMBIE_PI_MONO_SETTINGS` are all environment-resolved with defaults. A
second instance needs a different environment, not a different codebase.

## Design principle: capability is data, enforcement is structure

One payload. One `server.py`. One policy engine. The difference between
a zombie and a friend is a **tier**, and a tier is enforced in four
independent places, so that failure or misconfiguration in any one of
them does not restore a capability:

> **The test for this whole plan:** the installer must be able to create
> a ghost that the Ubuntu Zombie itself could not talk, prompt, or
> confirm its way out of.

Prompt text is not a boundary. Policy classification alone is not a
boundary — a class is an *approval requirement*, and a child holding the
chat password can satisfy an approval requirement. Boundaries are: tools
that do not exist in the process, paths the kernel refuses, privileges
the account never held, and a service the kernel confines.

## 1. The ghost registry

Ghost definitions are **data**, parsed and never sourced, exactly like
the component manifest format the installer already uses.

- **Built-in ghosts** (`zombie`, `friend`, `flame`) ship as a table in a
  new `scripts/ghost-registry.sh`, sourced alongside
  `component-registry.sh`.
- **Operator ghosts** are declared as root-owned `0644` records under
  `/etc/ubuntu-zombie/ghosts.d/<name>.ghost`, in the same
  `format=1` key/value layout as the component manifest, e.g.

  ```text
  format=1
  ghost=coach
  tier=hermit
  user=coach
  port=6565
  root=/opt/ai-coach
  brand=Running Coach
  ttl_days=365
  ```

- Malformed or unknown keys are skipped with a `[!]` note, never
  executed.

**Validation** (all in the component's `validate` hook, so a bad ghost
fails before any mutation):

- `ghost` matches `^[a-z][a-z0-9-]{0,30}$` and is not a reserved
  component name (`forgejo`, `forgejo-runner`, `llama`) or a reserved
  tier name.
- `user` passes the existing `is_supported_agent_username`, and — unless
  it is an already-converged ghost — does not already exist as a human
  account.
- `port` passes `is_valid_tcp_port`, is unique across all declared
  ghosts, and does not collide with the managed `llama` port `8080`, the
  reserved `58080`, or the configured LM Studio scan port.
- `root` passes `is_safe_absolute_path` and is not nested inside another
  ghost's root.
- `tier` is one of the known tiers, and only the `zombie` ghost may
  declare `tier=root` unless the operator passes an explicit override.

**Registration.** At load, the installer iterates the ghost table and
calls `register_component "<ghost>" "" validate=… install=… verify=…`
binding every ghost to the *same shared, trusted hook functions*. The
per-ghost data comes from the registry table via a ghost context the
dispatcher sets before each hook runs — not from generated or `eval`-ed
function names, which would break the registry's "trusted hook
functions" contract. Adding a ghost therefore changes data, not parser
or dispatcher conditionals, which is the rule
[`README.md`](README.md) already sets for components.

**No dependency on `zombie`.** Like the standalone `llama` component,
ghosts register with no registry dependencies. `install flame` on a
machine with no root agent must work, because a family machine may want
Flame and nothing else.

**Backwards compatibility.** With no target, `install` still selects
`zombie`; `ZOMBIE_USER`, `ZOMBIE_DIR`, and `ZOMBIE_CHAT_PORT` continue to
configure that ghost; unit names, symlink names, and paths for `zombie`
are unchanged.

## 2. Capability tiers

| | `root` (zombie) | `hermit` (friend) | `tutor` (flame) |
| --- | --- | --- | --- |
| Tools | full registry | `fs.read`, `fs.list`, `fs.write`, `skill.list`, `skill.load` | same as `hermit` |
| Write roots | policy-gated, effectively the host | one own folder | own folder + nominated learner dirs |
| Read roots | inspection allow-list + host via `shell.run` | its own tree only | its own tree + learner dirs + curriculum data |
| `sudo` | passwordless, by design | never | never |
| Class ceiling | `destructive` | `user_change` | `user_change` |
| Confirmation phrase | enabled | **no phrase exists** | **no phrase exists** |
| `timer.reactivation` | on | off (opt-in per ghost) | off |
| systemd sandbox | deliberately off | hardened | hardened |
| Egress | provider + host | provider | **local provider required** |
| Curriculum gate | n/a | n/a | required, fail-closed |
| Chat commands | full operator set | reduced | child set + separate guardian plane |

Two rules bound the tier system:

- **Tiers only subtract.** A tier is expressed as a subset of the shipped
  registry and a narrowing of the shipped allow-lists. No tier can add a
  tool, a path, or a class the base product does not have.
- **`root` is the only tier that may hold `sudo`.** Installing a
  non-`root` ghost fails if a sudoers drop-in exists for its user, and
  `verify` re-asserts that on every run.

## 3. Four independent layers of defanging

### Layer 1 — the Linux account

- Created with `adduser --disabled-password`, shell
  `/usr/sbin/nologin`, home mode `0750`, and its own primary group.
- **No** `usermod -aG sudo`, **no** `/etc/sudoers.d/` drop-in — and an
  install-time assertion that neither exists.
- Not a member of `sudo`, `adm`, `docker`, `lxd`, `disk`, or any other
  privilege-bearing group. `verify` enumerates the ghost's groups and
  fails on anything outside its own.
- The ghost's *code* is root-owned. Today `install_zombie_runtime` chowns
  the install tree to the agent user; for non-`root` tiers `agent/`,
  `bin/`, and the rendered pi settings are `root:<ghost>` `0750`, and only
  `state/`, `secrets/`, and the ghost's own folder are ghost-writable. A
  defanged ghost must not be able to rewrite the program it is.

### Layer 2 — systemd confinement

`payload/systemd/ubuntu-zombie-chat.service` carries a long, correct
rationale for why the *zombie* unit is deliberately unsandboxed. That
rationale stays exactly as it is. Defanged ghosts get a **new**
template unit, `payload/systemd/ubuntu-ghost-chat@.service`, whose
comment block states the opposite rationale, with per-instance drop-ins
under `/etc/systemd/system/ubuntu-ghost-chat@<ghost>.service.d/` carrying
the environment and the writable paths:

- `User=%i`, `Group=%i`
- `NoNewPrivileges=true`, `CapabilityBoundingSet=` (empty),
  `AmbientCapabilities=`
- `ProtectSystem=strict`, `ProtectHome=tmpfs`, and `ReadWritePaths=`
  listing *only* the ghost's state, secrets, and own folder (plus the
  learner directories for `tutor`)
- `PrivateTmp=true`, `PrivateDevices=true`, `ProtectKernelTunables=true`,
  `ProtectKernelModules=true`, `ProtectKernelLogs=true`,
  `ProtectControlGroups=true`, `ProtectProc=invisible`,
  `ProcSubset=pid`, `RestrictSUIDSGID=true`, `RestrictRealtime=true`,
  `LockPersonality=true`, `RestrictNamespaces=true`
- `SystemCallArchitectures=native`, `SystemCallFilter=@system-service`
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `IPAddressDeny=any`
  plus a narrow `IPAddressAllow=` (loopback only when the ghost is paired
  with the local `llama` component)
- `MemoryMax=`, `TasksMax=`, `DeviceAllow=` empty

`MemoryDenyWriteExecute` is deliberately **omitted** — the Node bridge
JIT needs W^X pages — and the omission is documented in the unit so a
later hardening pass does not "fix" it into a boot loop.

The matching health units follow the same pattern
(`ubuntu-ghost-health@.service`, `ubuntu-ghost-health@.timer`).

### Layer 3 — the runtime capability profile

A new stdlib-only module, `payload/agent/capability.py`, resolves
`ZOMBIE_CAPABILITY_PROFILE` (default `root`, so nothing changes for
existing installs) into a frozen record:

```python
allowed_tools, read_roots, write_roots, max_class,
allow_reactivation, allow_streaming, skills, brand, persona,
curriculum_gate
```

Its consumers:

- **`tools.py`** keeps the full `TOOL_REGISTRY` as the shipped
  catalogue, but `tool_names()` and `dispatch()` filter through the
  profile. A call to a tool outside the profile is refused outright and
  audited as a capability violation — it is never queued for operator
  approval, because "ask the human at the keyboard" is exactly the wrong
  answer when the human at the keyboard is a child.
  `_read_allowed_prefixes()` and `_write_allowed_prefixes()` become
  profile-derived, keeping the existing symlink-resolution discipline in
  `_resolve_within` (resolve first, then operate on the resolved path).
- **`policy.py`** gains a ceiling: any classification above `max_class`
  is a hard refusal, and `settings.destructive_confirmation` is ignored
  for non-`root` profiles — there is no phrase that unlocks anything.
- **`server.py`** advertises only the profile's tools to the pi-mono
  bridge, renders a persona-specific system prompt, and reduces the chat
  command set (a `hermit` has no `/ttl --die`, no model selection, no
  provider disclosure).
- **`skill_loader.py`** filters to the profile's skill list, so a friend
  never loads the `apt`, `systemd`, `security`, or `users` briefs.
- **Fail closed.** If the profile cannot be resolved, or names a tool or
  path the shipped catalogue does not contain, the service refuses to
  start.

### Layer 4 — the per-ghost policy file

Each ghost gets `/etc/ubuntu-zombie/ghosts/<ghost>/policy.yaml`,
root-owned, outside every write root, with a tier-appropriate
`default_class` and an explicit `max_class`. It is the *fourth* line of
defence, not the first: even if the file were replaced wholesale, layers
1–3 still hold.

**Invariant N2, stated once and tested forever:** *nothing that
constrains a ghost may live inside that ghost's write roots* — not its
policy, not its unit, not its drop-in, not its capability profile, not
its skills, not its curriculum data, not its own code.

## 4. Filesystem, identity, and log layout

| Purpose | Zombie (unchanged) | Other ghosts |
| ------- | ------------------ | ------------ |
| Install root | `/opt/ai-zombie` | `/opt/ai-<ghost>` |
| Runtime code | `<root>/agent`, ghost-owned | `<root>/agent`, **root-owned** `0750` |
| Secrets | `<root>/secrets/env` `0600` | same, ghost-owned |
| State / history | `<root>/state` | same, ghost-owned |
| Own folder | n/a | `/home/<ghost>/files`, `2750` `<ghost>:<ghost>-share` |
| Policy | `/etc/ubuntu-zombie/policy.yaml` | `/etc/ubuntu-zombie/ghosts/<ghost>/policy.yaml` |
| Operator skills | `/etc/ubuntu-zombie/skills.d` | `/etc/ubuntu-zombie/ghosts/<ghost>/skills.d` |
| Audit log | `/var/log/ubuntu-zombie/audit.log` | `/var/log/ubuntu-zombie/ghosts/<ghost>/audit.log` |
| Manifest | `/var/lib/ubuntu-zombie/components/zombie` | `…/components/<ghost>` |
| Units | `ubuntu-zombie-chat.service` | `ubuntu-ghost-chat@<ghost>.service` |
| Commands | `zombie-chat`, … | `<ghost>-chat`, `<ghost>-audit`, … |

Directory modes matter as much as file modes: `/var/log/ubuntu-zombie/ghosts/`
is `root:root 0711` so a ghost can traverse to its own directory but
cannot enumerate its siblings; each `<ghost>/` is `0750
root:<ghost>`; each `audit.log` is `0640 <ghost>:<ghost>`. The same
shape applies under `/etc/ubuntu-zombie/ghosts/`, except that everything
there is root-owned and read-only to the ghost.

Per-ghost trees mean N copies of a few hundred kilobytes of Python and a
per-ghost virtualenv. That is the right trade: a shared code tree would
either be writable by one ghost and executed by another, or would force
a shared upgrade ordering across ghosts with different lifecycles.

The `zombie` ghost's paths are grandfathered exactly as they are, so an
existing machine upgrades without moving a single file.

## 5. Ports, and the local-user problem

Standard ports are `7878` (zombie), `6767` (friend), `5656` (flame);
declared ghosts choose their own, validated unique. All are loopback.

The uncomfortable fact this plan must confront: **loopback is shared by
every local user.** The chat service is reachable at
`http://127.0.0.1:<port>` by anyone with a session on the machine, and
today the only barrier is a shared password whose default is
`braaaains`. The moment a child has an account on a machine that also
runs a root-capable zombie, the chat password is the only thing between
that child and root.

Mitigations, in order of strength:

1. **Per-ghost credentials.** Each ghost has its own `secrets/env` with
   its own PBKDF2 hash. The installer **refuses the default password**
   whenever more than one ghost is installed, or whenever a `tutor` ghost
   is present, in both interactive and non-interactive modes (missing
   required password in non-interactive mode exits `64`).
2. **Owner-matched loopback filtering.** A managed `nftables` table
   restricts each ghost's port to nominated UIDs on the `output` hook
   (`meta skuid`), installed by the ghost component and removed by
   `uninstall`. The zombie's port is restricted to the operator; the
   flame's port to the learner and the guardian.
3. **Separate loopback addresses.** Optionally bind each ghost to its own
   `127.0.0.x` alias, which does not enforce anything by itself but makes
   the firewall rules and the audit trail unambiguous. The server's
   loopback-only bind check must be widened to `127.0.0.0/8` and *only*
   that — never to a routable address.
4. **Don't co-locate.** Documented plainly: a machine that carries a
   child ghost should not also carry a root ghost. If it must, the
   operator accepts a residual risk that no amount of configuration
   removes, because a local user who obtains the operator's password
   obtains root by design.

## 6. Runtime changes (`payload/`)

| File | Change |
| ---- | ------ |
| `agent/capability.py` | **New.** Tier → frozen capability record; fail-closed resolution. |
| `agent/tools.py` | Filter `tool_names()`/`dispatch()`; profile-derived read/write roots; capability-violation audit record. |
| `agent/policy.py` | `max_class` ceiling; suppress the destructive phrase below `root`. |
| `agent/server.py` | Profile-aware tool advertisement, persona prompt, reduced command set, per-ghost branding, optional non-streaming delivery. |
| `agent/skill_loader.py` | Restrict to the profile's skill list. |
| `agent/history.py` | Retention mode that records structured decisions without message bodies (needed by `tutor`). |
| `agent/audit.py` | No change to the record format; the path is already env-resolved. |
| `agent/templates/` | Persona-parameterised title, wordmark, and prompt prelude instead of the literal "Ubuntu Zombie". |
| `agent/skills/friend.md`, `agent/skills/flame.md` | **New** persona briefs; the existing sysadmin briefs are excluded from both tiers. |
| `etc/ghost-tiers.yaml` | **New.** The shipped tier definitions, as data. |
| `etc/policy-hermit.yaml`, `etc/policy-tutor.yaml` | **New.** Tier baseline policies. |
| `systemd/ubuntu-ghost-chat@.service`, `…-health@.service`, `…-health@.timer` | **New** hardened templates. |
| `logrotate/ubuntu-zombie` | Add the per-ghost audit and event log globs. |
| `bin/` | Ghost-aware `verify`, `health-check`, `collect-diagnostics`, `audit-recent`, and chat launcher (ghost name as argument or per-ghost symlink). |

## 7. Installer changes (`scripts/`)

- **`ghost-registry.sh` (new).** Parse and validate ghost records;
  expose accessors; enumerate built-ins plus `/etc/ubuntu-zombie/ghosts.d/`.
- **`install.sh`.** Replace the single-agent globals with a ghost context
  the dispatcher sets per component; keep the legacy globals as the
  `zombie` ghost's values. Parameterise every `section` block that
  currently bakes in the user, root, port, or unit name. Render units
  from templates with per-instance drop-ins. Emit per-ghost receipt
  stanzas and manifests (`suboptions=tier=hermit,port=6767`).
- **Selectors.** `install friend`, `install flame`, `install zombie
  friend flame`, plus additive `ZOMBIE_INSTALL_FRIEND=1` /
  `ZOMBIE_INSTALL_FLAME=1` compatibility flags defaulting to `0`, and
  `ZOMBIE_GHOSTS="coach:6565:hermit"` for declared ghosts. Missing
  required input under `ZOMBIE_NONINTERACTIVE=1` exits `64`.
- **Interactive review.** A "Ghosts" entry in the Options sub-menu that
  lists declared and installed ghosts and allows add / edit port / edit
  tier / remove, reusing the existing validators.
- **`verify`/`doctor`/`repair`.** Per-ghost JSON records, and — new —
  **negative** checks for defanged tiers: no sudoers drop-in, no
  privileged group membership, `nologin` shell, code root-owned, policy
  and unit outside the write roots, unit drop-in present and hardened,
  effective tool set equals the tier's tool set, port answers only for
  the permitted UIDs. `repair` re-asserts all of it.
- **`uninstall.sh`.** A ghost-aware `remove` hook: `uninstall friend`
  removes one ghost; a bare `uninstall` removes every managed component.
  Per-ghost archives, destructive steps behind the existing confirmation
  phrase, and the existing orphan-sudoers sweep extended across ghosts.
- **`lib.sh`.** Splash and final summary take the port and brand from the
  ghost context instead of the literal `7878`.
- **`completions/`.** Component lists become the registry's list plus
  declared ghosts.

## 8. The Friend ghost in detail

**Identity.** User `friend`, port `6767`, root `/opt/ai-friend`, brand
"Imaginary Friend", tier `hermit`.

**What it can do.** Exactly two things:

1. Talk in its own chat UI.
2. Read, list, and write files under **one** folder,
   `/home/friend/files` — a setgid `2750` directory owned
   `friend:friend-share`, with the operator's human account added to
   `friend-share` so the folder is a genuinely shared workspace rather
   than a black box. Notes, drafts, lists, stories: the friend writes
   them there, the human opens them in a file manager.

**What it cannot do.** No `shell.run`, `pkg.*`, `svc.*`, `net.status`,
or `web.fetch` — the tools are absent from the process, not merely
gated. No `sudo`. No reads of `/etc`, `/proc`, `/sys`, `/var/log`,
`/usr/share`, `/tmp`, or another user's home: the `hermit` read roots are
its own tree and its own folder, which is a real narrowing of today's
inspection allow-list. No operator chat commands. No approval queue at
all — a `hermit` never produces a proposal that needs approving, so the
approval UI is hidden rather than empty.

**Optional.** `timer.reactivation` is off by default. A friend that can
pick a conversation back up later is charming and is a bounded,
transcript-visible `chat_schedule` action, so it may be enabled per ghost
(`ZOMBIE_FRIEND_REACTIVATION=1`) — but it is opt-in, never default.

**Lifecycle.** The TTL kill switch applies unchanged, with a per-ghost
default (`ZOMBIE_FRIEND_TTL_DAYS`). A friend can be expired and
tombstoned exactly like a zombie.

**Honesty.** The persona brief must forbid claiming capabilities it does
not have. Asked to install something or fix the machine, the friend says
plainly that it cannot and that the Ubuntu Zombie is the account for
that. Friend is **not** the child-safe product — that is Flame — and the
installer says so when a `hermit` ghost is created on a machine with a
`tutor` ghost declared.

## 9. The Flame ghost in detail

**Identity.** User `flame`, port `5656`, root `/opt/ai-flame`, brand
"Curriculum Flame", tier `tutor`.

**Tier `tutor` = `hermit` + a learner workspace.**
`ZOMBIE_FLAME_LEARNER_DIRS` names one or more absolute paths that Flame
may create and edit files in. The installer:

- refuses a bare `/home/<user>` or any path outside a human home;
- never chowns an existing human directory;
- creates only the nominated sub-directory when absent, `2770`
  `<learner>:flame-learners`, with Flame in `flame-learners`;
- adds each nominated path to the unit's `ReadWritePaths=` and the
  profile's write roots, and nothing else.

**The curriculum gate.** Every turn runs the ordered pipeline from
[`curriculum-gates-local-ai-for-children.md`](curriculum-gates-local-ai-for-children.md)
§6.4 and the `curriculum-flame` specification: normalise → safety
classify → curriculum classify → outcome match → protected-assessment
match → circumvention check → **deterministic policy decision** →
generate → output safety validation → output leakage validation →
enforce → log a structured event. Two invariants are absolute: no prompt
reaches the model un-inspected, and no candidate response reaches the
child un-validated — which means **token streaming is disabled for
`tutor` ghosts**; the SSE channel carries `phase` events only, and the
complete reply is buffered, validated, then delivered.

**Guardian-owned data**, root-owned under
`/etc/ubuntu-zombie/ghosts/flame/curriculum/`, outside Flame's write
roots, using the field names from the sibling specification so the data
is portable to and from the `curriculum-flame` project: `learner.json`,
`outcomes.json`, `states.json` (`PREVIOUS` / `CURRENT` / `FUTURE` /
`UNCLASSIFIED` with `valid_from`/`valid_until`), `protections.json`, and
`approvals.json` (finite, expiring, revocable).

**Structured events, not transcripts.** Raw prompts and replies are not
persisted by default; `history.py` gains the retention mode that records
the decision, reason codes, matched outcomes, confidence, warning level,
and component versions to
`/var/log/ubuntu-zombie/ghosts/flame/events.log`, and stores a
placeholder in place of the message body. Full transcript retention is a
*prospective* opt-in with a visible duration — a guardian cannot switch
it on to recover a conversation that was never stored.

**The guardian plane.** The child UI must not be able to reach the
administrative plane.

- *Minimum:* one service, two credentials, two cookie names; guardian
  routes reject child sessions, and no child session can mint a guardian
  session.
- *Maximum, and the recommended target:* a second unit,
  `ubuntu-ghost-chat@flame-guardian`, on its own port and its own account,
  holding the only write access to the curriculum data. This matches the
  sibling specification's trust-zone separation instead of approximating
  it.

**Escalation.** Warning levels 0–5 map onto graduated in-chat messages,
a review flag, a guardian alert, and a session lock. The language is
calm and never shaming, and classifier internals and confidence scores
are never shown to the child.

**Fail closed.** Missing, unparseable, or unverifiable curriculum data;
a validator that raises; an unresolved learner; an unavailable model —
each disables answering rather than degrading to an ungated answer.

**Local model required.** A `tutor` ghost sends a child's words
somewhere. With a hosted provider that means a third party. The
installer therefore **requires a local provider** for `tutor` ghosts —
pairing naturally with the existing `llama` component and
`IPAddressAllow=localhost` — and refuses a hosted provider unless the
operator passes an explicit, receipt-recorded override.

**Scope boundary with `curriculum-flame`.** This repository builds the
*host*: a defanged account, a confined service, guardian-owned data
outside the agent's reach, an event log, a fail-closed switch, and a
deterministic gate that matches on outcome IDs, keywords, and
phrase/fingerprint similarity against guardian-entered protected
material. The *curriculum science* — semantic classifiers, circumvention
detection, red-team corpora, the quality gates (100% canonical blocks,
≥95% paraphrase detection, ≤5% false blocks) — belongs to
[`japer-technology/curriculum-flame`](https://github.com/japer-technology/curriculum-flame)
and is consumed here through a versioned validator contract.

**Honesty gate.** Until those quality gates are met by the validator in
use, the installer must not describe Flame as child-safe. It prints the
limitation, records it in the receipt, and requires an explicit
acknowledgement flag before creating a `tutor` ghost. The sibling
project's own words apply: the strict boundary is not a substitute for
an accountable adult.

## 10. Non-negotiables

From [`AGENTS.md`](../../AGENTS.md), unchanged: idempotence;
`ZOMBIE_NONINTERACTIVE=1` end to end with `64` on missing required
input; every privileged behaviour through the policy gate and the audit
log; no secrets in the repository; **no new runtime dependencies** (all
of this is stdlib Python, bash, systemd, and `nftables` from the base
system); no commits of local state.

New invariants this plan adds:

- **N1** Tiers subtract only; no tier grants what the base product lacks.
- **N2** Nothing that constrains a ghost is writable by that ghost.
- **N3** No prompt, phrase, or approval reaches a class above the tier's
  ceiling.
- **N4** An unresolvable capability profile refuses to serve.
- **N5** One audit trail per ghost; no ghost can read another's.
- **N6** With no other ghost installed, the zombie's behaviour, paths,
  units, and command names are unchanged.

## 11. Implementation steps

Each phase ends with `make lint`, `make test`, and `make package` green,
a `CHANGELOG.md` entry, and a `VERSION` bump.

- **Phase 0 — capability profile, no behaviour change.** Add
  `capability.py`, the tier data, and the `tools.py` / `policy.py` /
  `skill_loader.py` consumers, with `root` as the default profile. Prove
  by test that the shipped behaviour is identical.
- **Phase 1 — ghost registry, one ghost.** Add `ghost-registry.sh`,
  parameterise the installer, and register `zombie` as the only ghost.
  The proof of this phase is a *no-op*: same paths, same units, same
  names, same receipt, clean re-install over an existing machine.
- **Phase 2 — Friend.** The `hermit` tier, the hardened unit template,
  the own-folder workspace, the persona brief, per-ghost logs and
  manifests, and the negative `verify` checks.
- **Phase 3 — access hardening.** Per-ghost credentials with the default
  password refused, owner-matched loopback filtering, per-ghost
  diagnostics and health, uninstall symmetry.
- **Phase 4 — Flame chassis.** The `tutor` tier, learner workspace with
  its group and setgid discipline, the guardian plane, non-streaming
  delivery, structured events, and the no-transcript retention mode.
- **Phase 5 — curriculum gate v1.** The deterministic matcher, the
  decision and reason-code vocabulary, approvals and temporary
  protections with automatic expiry, the escalation ladder, the
  fail-closed startup integrity check, and the honesty gate.
- **Phase 6 — arbitrary ghosts.** `/etc/ubuntu-zombie/ghosts.d/`,
  dynamic completions, `docs/` and `README.md` updates, and the worked
  example of a fourth ghost created purely from data.

Phases 0 and 1 are the whole risk of this plan. If either cannot be
landed as a provable no-op, stop and reconsider before building tiers on
top of it.

## 12. Validation before hand-off

Extend [`tests/smoke.sh`](../../tests/smoke.sh):

- `subcommands` — the new targets parse for every verb.
- `component_registry` — ghosts register without dependencies, reserved
  names are rejected, duplicate ports are rejected, and a malformed
  ghost record is skipped rather than executed.
- `manifest` — per-ghost manifest round-trip including `suboptions`.
- `noninteractive` — a ghost with no password and no port exits `64`.
- `standards` — the hardened template keeps `NoNewPrivileges=true`,
  `ProtectSystem=strict`, and an empty `CapabilityBoundingSet`; the
  zombie unit keeps its non-sandbox rationale; the tier data and the
  `friend`/`flame` skill briefs exist.

Add Python tests under [`tests/python/`](../../tests/python):
capability filtering (a `hermit` process cannot dispatch `shell.run`),
path escape attempts (traversal, symlink swap, `..` in a learner path),
the policy ceiling, and the curriculum matcher's decision table.

Manual VM matrix (disposable Ubuntu Desktop LTS only, never a real
machine): zombie alone; zombie + friend; friend alone; flame alone;
zombie + friend + flame; re-run each install for idempotence; uninstall
one ghost and confirm the others still verify; uninstall everything and
confirm no accounts, units, sudoers, groups, firewall rules, logs, or
manifests remain.

**Red-team pass from inside a defanged ghost** — every one of these must
fail and appear in that ghost's audit log: run a shell command; install a
package; restart a unit; read `/etc/shadow`, another user's home, or the
zombie's secrets; write outside the write roots via `..`, a symlink, or
a bind; edit its own policy, unit, drop-in, or code; reach another
ghost's port; invoke an operator chat command; and — for `tutor` — every
circumvention pattern in the sibling specification.

## 13. Out of scope

- Fleet or multi-machine orchestration; ghosts are single-host.
- Ghost-to-ghost messaging or a shared agent bus. Each ghost is isolated;
  a channel between them would be a new trust boundary and needs its own
  plan.
- More than one ghost per Linux account, or a ghost without an account.
- Containerising or virtualising ghosts; systemd confinement is the
  chosen mechanism.
- Re-implementing the `curriculum-flame` specification here.
- Windows and macOS, which stay in [`docs/multipliers/`](../multipliers).
- Replacing the desktop user's own accounts, sessions, or files.

## 14. Risks

| Risk | Mitigation |
| ---- | ---------- |
| The installer refactor regresses the zombie | Phases 0 and 1 are provable no-ops; full VM matrix before Phase 2 |
| systemd hardening breaks the Node bridge | `MemoryDenyWriteExecute` omitted and documented; syscall filter validated on a VM before shipping |
| Loopback co-tenancy with a root agent | Per-ghost credentials, owner-matched filtering, and an explicit documented recommendation not to co-locate |
| A "defanged" ghost is only defanged by prompt | Four independent layers plus negative `verify` checks and a red-team pass |
| Child data leaves the machine | Local provider required for `tutor`; egress denied by the unit; hosted providers need a recorded override |
| Flame is mistaken for a finished safeguard | Honesty gate, receipt record, acknowledgement flag, and no child-safety claim until the sibling project's quality gates pass |
| Ghost sprawl on one machine | Per-ghost resource limits, a documented ceiling, and `verify` reporting total ghost count |
| Vision drift toward multi-tenancy | The decision at the top of this plan; ghosts are never operators |

## 15. Documentation to update

[`README.md`](../../README.md) (subcommands and targets),
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) (ghosts, tiers, the two
opposite unit rationales, per-ghost trust boundaries),
[`docs/CONFIGURATION.md`](../CONFIGURATION.md) (every new environment
variable and ghost record key), [`docs/VISION.md`](../VISION.md) (the
one-operator reading above), [`SECURITY.md`](../../SECURITY.md)
(the loopback co-tenancy limit and the per-ghost trust boundary),
[`docs/QUICKSTART.md`](../QUICKSTART.md) and
[`docs/TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) (per-ghost commands),
[`README.md`](README.md) and [`PLAN.md`](PLAN.md) in this directory
(catalogue and sequencing), plus `CHANGELOG.md` and `VERSION` each phase.
