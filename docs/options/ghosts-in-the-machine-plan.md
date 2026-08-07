# Plan: ghosts in the machine — an independent family of AI agents

## Goal

Ubuntu Zombie was the first successful product, not the final product
shape. Its root-capable AI Systems Administrator proves that a carefully
installed local agent can have a clear identity, an explicit trust
boundary, an auditable lifecycle, and a useful place on an Ubuntu
machine. That success makes the Imaginary Friend, Curriculum Flame, and
other helpful AI agents possible.

The expansion is a **family of independent products**, not a generic
Ubuntu Zombie runtime with different personas. “Ghost” remains a useful
family metaphor, but it is not a technical base class, capability tier,
registry entry, or shared installation format.

| Product | Purpose | Maximum authority | Default identity | Default port |
| ------- | ------- | ----------------- | ---------------- | ------------ |
| **Ubuntu Zombie** | AI Systems Administrator | Root through its existing policy and approval boundary | `zombie` | `7878` |
| **Imaginary Friend** | Private conversational companion and workspace | Its own files only | `friend` | `6767` |
| **Curriculum Flame** | Curriculum-gated local AI for children | Its own state and nominated learner workspaces | `flame` | `5656` |

Ubuntu Zombie remains the only generally root-capable agent. Every later
agent starts with less authority and receives only the narrow permissions
its own purpose requires.

## Decisions — resolved

These decisions replace the earlier shared-chassis proposal:

1. **Yes, the product vision expands.** Ubuntu Zombie is the beginning of
   a range of helpful local AI agents. Imaginary Friend and Curriculum
   Flame are the first two successors, not the end of the range.
2. **Every agent is unique.** Each product owns its installation,
   updates, security model, runtime, documentation, and lifecycle. There
   is no generic ghost installer, no common capability-tier theory, and
   no shared runtime payload.
3. **Duplicate the lesson, not the implementation dependency.** A new
   agent begins by copying the proven Ubuntu Zombie mechanisms into its
   own project. It then removes inappropriate power, specialises the
   design, and improves at least one part of the mechanism. Once split,
   it evolves and releases independently.
4. **Every security boundary is product-specific.** Each agent has its
   own Linux identity, security password or passwords, password hash,
   session secret and cookie, provider credentials, policy, audit log,
   state, ports, services, receipt, and recovery path. Credentials are
   never copied, linked, inherited, or accepted across agents.

The one human who owns the machine remains the operator. Other people may
use a particular agent, but they do not thereby become operators of the
machine or of another agent.

## Core strategy: copy, separate, improve

The safest way to expand is to make a complete product copy at a known,
audited Ubuntu Zombie release and then deliberately separate it.

For each new agent:

1. Start a product-owned repository and release stream from a pinned
   Ubuntu Zombie tag.
2. Copy the installer disciplines, lifecycle commands, audit approach,
   tests, packaging, and documentation structure that are still useful.
3. Rename every product namespace before the first install: accounts,
   groups, environment variables, paths, units, commands, cookies,
   ports, logs, manifests, receipts, and package names.
4. Remove root access, general shell execution, host-wide read access,
   package and service control, and every other unneeded capability
   **before** adding the new persona or features.
5. Write a fresh threat model and policy from the new product’s purpose.
   Do not express it as a lower setting of Ubuntu Zombie.
6. Build a dedicated installer, updater, verifier, doctor, repair path,
   and uninstaller. None dispatches into Ubuntu Zombie code.
7. Prove standalone install and co-installation safety on a disposable
   VM.
8. Record which Ubuntu Zombie lessons were retained, which were removed,
   and what this iteration improves.

After the copy, there is no runtime import, package dependency, source
submodule, shared virtual environment, shared service template, or
automatic code synchronisation with Ubuntu Zombie. A useful fix may be
manually ported between products, but it is reviewed and tested as a
change to each recipient product.

This duplication is deliberate. It costs more maintenance than one
framework, but prevents a generic refactor, update, or policy mistake
from changing every installed agent at once.

## What independence means

| Concern | Required separation |
| ------- | ------------------- |
| Source and release | Product-owned repository, version, changelog, artifact, SBOM, checksums, signatures, and provenance |
| Installation | Product-owned installer, prompts, preflight, dry-run, receipt, ownership markers, and rollback |
| Update | Product-owned compatibility checks, backup, migration, health gate, rollback, schedule, and release channel |
| Removal | Product-owned uninstaller that cannot select or delete another agent |
| Runtime | Product-owned code tree, dependencies, virtual environment, templates, tools, and process |
| Identity | Unique Linux user, primary group, optional sharing groups, and service account set |
| Authentication | Unique password or passwords, salted hashes, session-signing keys, cookies, and rotation/recovery flow |
| Provider access | Product-owned credential file and model selection; never another agent’s secrets file |
| Policy | A threat model, allowed actions, refusal rules, approval model, and fail-closed behaviour written for that product |
| State | Dedicated configuration, history, lifecycle, cache, database, and backup format |
| Observability | Dedicated audit log, event log, service journal identifiers, diagnostics, and log rotation |
| Host resources | Product-named ports, units, commands, firewall rules, paths, manifests, and package ownership |
| Quality | Product-owned tests, VM matrix, red-team cases, release gates, and documentation |

Products may independently choose the same language or upstream library.
They must not share a live installed copy merely because the files began
from the same ancestor.

## Expanding installation without combining installers

[`scripts/install.sh`](../../scripts/install.sh) remains the Ubuntu
Zombie installer. It must not gain `friend`, `flame`, arbitrary `ghost`,
or capability-tier targets. The existing component registry remains for
software that Ubuntu Zombie itself installs; another AI agent is a
product, not an Ubuntu Zombie component.

The family can still have one discoverable front door:

1. A catalogue describes each agent’s purpose, authority, intended user,
   current release, and project-owned installation entry point.
2. The operator chooses and downloads one product’s release.
3. That product’s release verification checks its own artifact,
   signature, provenance, and checksums.
4. The operator runs that product’s installer and reviews that product’s
   requested permissions.
5. The installer creates only that product’s identity, credentials,
   files, services, state, receipt, and ownership markers.
6. Installing another agent is a second, independent transaction using
   the other product’s verified release and installer.

A future family chooser may display the catalogue and hand the operator
to the selected release. It must remain a stateless handoff:

- it does not install as root;
- it does not collect or pass passwords, provider keys, or settings;
- it does not provide common lifecycle hooks;
- it does not maintain an authoritative family manifest;
- it does not update, repair, or uninstall products;
- it never runs several product installers as one transaction.

There is consequently no “update all agents” command. The operator reads
each product’s changelog and runs each product’s update procedure
separately.

## The Ubuntu Zombie lessons to duplicate

These are acceptance outcomes, not a shared library or a claim that all
agents have the same architecture.

1. **Idempotent convergence.** Re-running an installer reaches the
   declared product state without destroying valid credentials or state.
2. **Interactive and non-interactive operation.** Every required value
   is reviewable; unattended mode never prompts and exits `64` when a
   required value is missing.
3. **Inspect before mutation.** Preflight, parameter review, and dry-run
   make the intended changes visible before root changes the host.
4. **Least authority by construction.** Linux identity, filesystem
   ownership, service confinement, available tools, and policy all agree
   on the product’s maximum authority.
5. **Policy and audit together.** Every sensitive action passes through
   that product’s policy and writes to that product’s audit trail.
6. **Independent authentication.** Only a salted password hash is stored;
   raw passwords and session secrets do not enter logs, diagnostics, or
   ordinary receipts.
7. **Operator control.** The product has its own kill switch or lifecycle
   control, credential rotation, health check, diagnostics, and complete
   removal path.
8. **Reversibility.** Uninstall knows exactly which product-owned
   resources it may remove and protects state-destroying steps with an
   explicit confirmation.
9. **Upgrade safety.** An update preserves or migrates product-owned
   state, validates the result before committing, and has a documented
   recovery path.
10. **Release trust.** Releases are reproducible where practical,
    checksum-pinned, signed, provenance-verifiable, and accompanied by an
    SBOM.
11. **Honest boundaries.** Documentation says what the agent cannot do
    and does not turn prompt instructions into security claims.
12. **Evidence before hand-off.** Lint, tests, package construction,
    disposable-VM install/update/uninstall, and negative security tests
    pass for that product.

## The improvement ratchet

Copying Ubuntu Zombie must not freeze its weaknesses into every future
agent. Each new product release records an inheritance review:

- the exact Ubuntu Zombie tag used as the starting point;
- the mechanisms copied and why they still fit;
- privileged mechanisms removed and proof that they are unreachable;
- product-specific mechanisms added;
- known inherited risks and their disposition;
- at least one measurable improvement over the previous product.

Expected early improvements include:

- generated unique passwords instead of copying Ubuntu Zombie’s known
  default;
- root-owned executable code for every non-root agent;
- a hardened service sandbox designed in from the first release;
- separate session-signing keys and product-specific cookie names;
- smaller tool registries containing no unreachable privileged tools;
- transcript minimisation and explicit retention controls;
- update rollback tested before the first stable release;
- release provenance and offline verification from the first release.

When one agent finds a security flaw inherited from the original copy,
the maintainers publish a family advisory listing every potentially
affected product. Each product implements, tests, versions, and releases
its own fix. The advisory coordinates knowledge; it does not create a
shared update mechanism.

## Security and credential isolation

### One agent, one authentication boundary

Every installer creates fresh authentication material for its product.

- A new product has no shared default password. Interactive installation
  requires the operator to choose a product-specific password or accept
  a securely generated one.
- Non-interactive installation uses that product’s own password input or
  secret-file mechanism. A `ZOMBIE_*` value is never a fallback.
- Each password receives its own random salt and PBKDF2 hash in a
  product-owned `0600` secrets file.
- Each web service has a fresh session-signing secret and a unique cookie
  name. A cookie issued by one agent is meaningless to every other
  agent.
- Password rotation invalidates only that product’s sessions. Recovery
  and reset are implemented and audited by that product.
- Reinstall and update preserve the existing product hash unless the
  operator explicitly requests rotation.
- Provider API keys, local-model tokens, guardian credentials, and
  encryption keys follow the same separation. Files are copied only from
  operator input, never symlinked to another agent’s secret store.
- Receipts and diagnostics record presence, source, and fingerprints
  where useful, never secret values.

The operator should use a different password for every agent. New
products improve on Ubuntu Zombie by generating a unique initial
password rather than inheriting `braaaains`; Ubuntu Zombie’s current
default remains only for compatibility and should be changed on any
co-installed machine.

Curriculum Flame needs more than one boundary: guardian administration
has its own credential and session, while each child receives a separate
profile/session appropriate to the Flame design. A child credential
cannot reach the guardian plane, and neither credential can authenticate
to Friend or Zombie.

### One agent, one host namespace

Initial reservations are deliberately product-named:

| Resource | Ubuntu Zombie | Imaginary Friend | Curriculum Flame |
| -------- | ------------- | ---------------- | ---------------- |
| Install root | `/opt/ai-zombie` | `/opt/imaginary-friend` | `/opt/curriculum-flame` |
| Configuration | `/etc/ubuntu-zombie` | `/etc/imaginary-friend` | `/etc/curriculum-flame` |
| State | `/var/lib/ubuntu-zombie` and `/opt/ai-zombie/state` | `/var/lib/imaginary-friend` | `/var/lib/curriculum-flame` |
| Logs | `/var/log/ubuntu-zombie` | `/var/log/imaginary-friend` | `/var/log/curriculum-flame` |
| Service prefix | `ubuntu-zombie-*` | `imaginary-friend-*` | `curriculum-flame-*` |
| Command prefix | `zombie-*` | `friend-*` | `flame-*` |
| Environment prefix | `ZOMBIE_*` | `FRIEND_*` | `FLAME_*` |

Each installer validates its requested user, group, paths, ports, unit
names, commands, and firewall rule names against the actual host before
mutation. It refuses to adopt an unmarked resource. Collision detection
does not give one product ownership of another product’s configuration.

### Authority is asymmetric

No non-Zombie agent receives passwordless general `sudo`, membership in
privilege-bearing groups, a login shell, or a general command runner. If
a future product genuinely needs a privileged operation, it uses a
closed, root-owned helper for enumerated operations, with its own policy
and audit records. It never receives Ubuntu Zombie’s unrestricted root
shape.

Less-privileged agents must be unable to read or write Ubuntu Zombie’s or
one another’s secrets, policy, state, code, logs, or ports. Ubuntu Zombie
itself is root-capable and can inspect the whole host; no same-machine
design can honestly hide another agent from root. Co-installation
therefore protects Zombie **from** less-privileged agents, not the other
way around.

## Imaginary Friend: standalone installation plan

Imaginary Friend is not Ubuntu Zombie with a `hermit` setting. It is a
separate companion product whose entire useful authority is conversation
and a private shared workspace.

Its project-owned installer:

1. validates that the `friend` identity and all Friend namespaces are
   unused or carry valid Friend ownership markers;
2. creates a non-login `friend` account with no `sudo` or privileged
   group membership;
3. installs root-owned executable code and a hardened
   `imaginary-friend-chat.service`;
4. creates only Friend-owned state, logs, configuration, secrets, and a
   nominated human-shared workspace;
5. creates a unique Friend owner password, hash, session key, and cookie;
6. exposes the Friend UI on its dedicated loopback port;
7. installs only conversation and scoped workspace operations — no
   general shell, package, service, network, or host-inspection tools;
8. writes Friend-specific verification, diagnostics, receipt, lifecycle,
   update, and uninstall material.

The Friend update procedure backs up Friend state, applies only Friend
migrations, verifies the sandbox and workspace boundary, restarts only
Friend units, and can roll back without reading or changing Zombie or
Flame.

The first improvement over Ubuntu Zombie is structural: Friend begins
with generated credentials, root-owned code, a hardened unit, and no
privileged tools in its process. These are not optional profile settings.

## Curriculum Flame: standalone installation plan

Curriculum Flame is not Friend plus a `tutor` setting. It is a separate
child-facing product built around the specification in
[`curriculum-gates-local-ai-for-children.md`](curriculum-gates-local-ai-for-children.md)
and the product-owned
[`japer-technology/curriculum-flame`](https://github.com/japer-technology/curriculum-flame)
project.

Its installer and update path are owned by Curriculum Flame. They create:

- a non-privileged child-facing service identity;
- a separately authenticated guardian plane, preferably with its own
  account and service;
- unique guardian, child-session, and service credentials;
- root-owned curriculum rules and validators outside every child-facing
  write root;
- only explicitly nominated learner workspaces;
- a local-provider-only network boundary;
- structured policy events with raw transcripts disabled by default;
- fully buffered output validation rather than unvalidated token
  streaming;
- Flame-specific health, integrity, migration, rollback, suspension,
  recovery, diagnostics, and removal paths.

Every prompt is inspected before generation and every complete response
is validated before delivery. Missing or invalid curriculum data,
validator failure, unresolved learners, unavailable local models, and
failed migrations all fail closed.

The Flame update procedure validates curriculum and profile schemas,
backs up guardian-owned data, stages new validators, runs the full
decision suite, and switches the service only after integrity and health
checks pass. It never invokes Friend’s or Zombie’s updater.

Flame improves the mechanism again: role-separated authentication,
minimal transcript retention, local-only child data, pre- and
post-generation validation, and fail-closed migrations are present from
the first release. Until the sibling project’s quality gates pass, the
installer and UI must not claim that Flame is a complete child-safety
solution.

## Future agents

A future agent is admitted to the family only with a product proposal
that answers:

1. What single human need does it serve?
2. Who uses it, and who operates it?
3. What is the maximum authority it needs, and how is that less than
   Ubuntu Zombie?
4. Which tools, paths, network destinations, and data does it need?
5. What unique users, groups, passwords, secrets, cookies, ports, paths,
   units, commands, and logs will it own?
6. What can never be shared with an installed sibling agent?
7. How do install, verify, doctor, repair, update, rollback, suspend, and
   uninstall work for this product?
8. Which Ubuntu Zombie lessons are copied, and which privileged
   mechanisms are deleted?
9. What does this iteration measurably improve?
10. How will standalone and co-installation security be proved?

There is no operator-authored `.ghost` record and no arbitrary persona
loader. A new family member is a deliberately designed, reviewed, and
released product.

## Independent update requirements

Update implementations may differ completely, but every product must
prove these outcomes:

- it identifies only installations carrying its own ownership markers;
- it verifies its own release before using root;
- it explains product-specific state and compatibility risks;
- it preserves its own passwords, keys, history, policy, and lifecycle
  unless a documented migration changes them;
- it backs up or snapshots the state its migration can damage;
- it validates migrations before replacing the running version;
- it restarts and health-checks only its own services;
- it records the old version, new version, migration, and outcome in its
  own audit/receipt trail;
- it offers a product-appropriate rollback or documented recovery path;
- it leaves every sibling agent byte-for-byte and process-for-process
  untouched.

No release schedule, version number, update acknowledgement, migration
format, or rollback decision is inherited from another agent.

## Co-installation contract

Independent products still need to behave safely when the operator
chooses the same machine.

- Installers inspect host collisions and fail before mutation.
- No product assumes another is installed and no agent depends on
  Ubuntu Zombie.
- Each product listens on its own loopback port and owns any
  owner-matched firewall rules needed to restrict local users.
- A product password, cookie, session token, API route, or password-reset
  mechanism is rejected by every sibling product.
- One product cannot enumerate or read another’s protected directories.
- Updating, repairing, suspending, or uninstalling one product does not
  restart services, rotate credentials, rewrite policy, or remove files
  for another.
- Cross-agent messaging, shared memory, shared model credentials, and a
  shared approval queue are absent.

If a root-capable Zombie and a child-facing Flame share a machine, the
operator must use distinct strong passwords and accept that Zombie, as
root, can inspect Flame. A dedicated Flame machine remains the stronger
deployment.

## Implementation sequence

### Phase 0 — record the family boundary

- Update the product vision to recognise a family with one operator.
- Mark Ubuntu Zombie as the sole generally root-capable member.
- Publish the copy/separate/improve rule and the namespace reservations.
- Explicitly reject the ghost registry, generic tiers, shared payload,
  and shared updater designs.

### Phase 1 — preserve the Ubuntu Zombie reference

- Tag the audited source snapshot used by the next product.
- Record the installer, policy, audit, lifecycle, release, and test
  lessons to copy.
- Make no multi-agent refactor in Ubuntu Zombie and prove its existing
  install remains unchanged.

### Phase 2 — build Imaginary Friend independently

- Copy the useful mechanisms into the Friend project.
- Complete the namespace split and remove privileged code paths.
- Build Friend’s installer, credentials, sandbox, workspace, lifecycle,
  updater, verifier, diagnostics, and uninstaller.
- Prove Friend alone, then Friend beside Zombie.

### Phase 3 — harden independent co-installation

- Test identity, path, port, cookie, password, session, provider-secret,
  audit, update, and uninstall separation.
- Red-team Friend from its service account.
- Verify that updating either product does not alter the other.
- Feed improvements back through separate, reviewed changes where useful.

### Phase 4 — build Curriculum Flame independently

- Start the Flame project from the newest suitable audited lesson set,
  not from the installed Friend runtime.
- Build the child and guardian boundaries, curriculum gate, local-model
  boundary, retention model, integrity checks, and Flame-only lifecycle.
- Prove Flame alone, beside Friend, and beside Zombie.

### Phase 5 — add the family catalogue

- Publish product identities, authority summaries, release-verification
  instructions, and project-owned install links.
- Add a non-root, stateless chooser only if it improves discovery without
  becoming an installer or lifecycle manager.
- Add future agents one complete independent product at a time.

Each product phase ends with that product’s own lint, tests, package,
release verification, disposable-VM matrix, changelog, and version bump.

## Validation before hand-off

### Product validation

Every product repository tests:

- clean interactive and non-interactive installs;
- required-input exit `64`;
- dry-run accuracy and idempotent reinstall;
- install ownership and permission modes;
- fresh unique authentication material and password rotation;
- refusal of malformed state and unowned pre-existing resources;
- the exact positive capability set and a larger negative capability set;
- update from every supported version, failed migration, rollback, and
  credential preservation;
- verify, doctor, repair, suspension, expiry where applicable, and
  uninstall with and without retained state;
- secret-redacted receipts and diagnostics;
- artifact, checksum, signature, provenance, and SBOM verification.

### Black-box co-installation matrix

On disposable Ubuntu Desktop LTS VMs, install with the products’ own
published installers:

- Zombie only, Friend only, and Flame only;
- Zombie + Friend;
- Friend + Flame;
- Zombie + Flame;
- Zombie + Friend + Flame.

For every combination:

1. Confirm users, groups, paths, units, commands, ports, firewall rules,
   cookies, secret files, logs, and manifests are distinct.
2. Confirm each product accepts only its own password and sessions.
3. Confirm each non-root service account cannot read another product’s
   code, credentials, state, policy, history, or logs.
4. Re-run each installer and updater independently.
5. Record sibling file hashes and service start times; operating on one
   product must not change the others.
6. Uninstall one product and verify every remaining product.
7. Uninstall all products with their own uninstallers and confirm each
   removes only its owned resources.

### Product-specific red teams

- **Friend:** attempts to run a shell command, inspect the host, access
  the network, escape its workspace, edit its code/policy/unit, read
  Zombie or Flame state, or authenticate with another agent’s password
  all fail and are audited.
- **Flame:** all Friend cases fail, child sessions cannot reach guardian
  routes or data, unvalidated output never streams, curriculum
  circumvention cases are blocked, and missing validators stop service.
- **Zombie:** existing policy, approval, audit, TTL, reinstall, update,
  and root-capable behaviour remain unchanged.

## Non-negotiables

- Ubuntu Zombie is the only generally root-capable agent.
- A prompt, persona, password, or approval cannot increase an agent’s
  installed authority.
- Every agent owns unique passwords and all other security material.
- No agent reads another agent’s secrets or uses them as defaults.
- No shared runtime, policy engine, tool registry, service template,
  manifest, installer, updater, repair path, or uninstaller.
- Every new product copies the proven lessons and improves the mechanism.
- Every install is idempotent, non-interactive-capable, auditable, and
  reversible.
- Product claims match tested boundaries.

## Out of scope

- Turning Friend or Flame into Ubuntu Zombie component targets.
- A generic ghost registry, capability-tier file, persona loader, or
  operator-declared arbitrary agent.
- One payload, server, policy engine, service template, or virtual
  environment serving several agents.
- Shared passwords, single sign-on, shared provider credentials, shared
  sessions, shared state, or shared audit logs.
- A family-wide installer, update-all command, repair command, or
  uninstaller.
- Ghost-to-ghost messaging, a shared memory bus, or delegated authority.
- Fleet orchestration or multi-machine control.
- Claiming mutual isolation from Ubuntu Zombie’s root account on one
  host.

## Risks

| Risk | Mitigation |
| ---- | ---------- |
| Copying repeats an inherited vulnerability | Record the source tag, audit before first release, publish family advisories, and patch each product independently |
| Independent copies drift | Accept deliberate divergence; keep a human-readable lesson/advisory ledger rather than a shared package |
| A later product accidentally keeps Zombie power | Remove privileged code first, use a fresh threat model, run negative tests from the service account |
| Users assume one password works everywhere | Generate product-specific credentials, use unique cookies, document separation, and test cross-login rejection |
| Independent installers collide on the host | Product-specific namespaces, preflight collision checks, and refusal to adopt unmarked resources |
| A family chooser becomes a hidden orchestrator | Keep it non-root and stateless; it may verify and link, never install or manage lifecycles |
| One update damages another agent | Product-owned paths and units plus black-box hash, process, update, and uninstall tests |
| Root Zombie is mistaken for a peer sandbox | Document the authority asymmetry and recommend a dedicated machine for stronger Flame isolation |
| Flame is mistaken for a finished safeguard | Fail closed, retain the honesty gate, and make no child-safety claim before its own quality gates pass |
| Duplication costs more maintenance | Treat the cost as the price of independent trust boundaries and improve tooling inside each product |

## Documentation ownership

This repository documents Ubuntu Zombie and this family direction. When
implementation begins, update [`docs/VISION.md`](../VISION.md) to record
the broader family while preserving Ubuntu Zombie’s own narrow promise.
Do not add Friend or Flame settings to Ubuntu Zombie’s
[`docs/CONFIGURATION.md`](../CONFIGURATION.md) or runtime details to
[`docs/ARCHITECTURE.md`](../ARCHITECTURE.md).

Imaginary Friend and Curriculum Flame each own their README, vision,
architecture, security model, configuration, installation, upgrading,
troubleshooting, release, and disclosure documentation. The family
catalogue links to those authoritative documents rather than copying
live operating instructions back into Ubuntu Zombie.
