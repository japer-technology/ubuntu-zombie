# AI agent catalogue

This directory describes the independent AI-agent product family that began
with Ubuntu Zombie. It turns the agent definitions in
[`ghosts-in-the-machine-plan.md`](../options/ghosts-in-the-machine-plan.md)
into one readable document per named product and provides a
[`template.md`](template.md) for defining the next product by hand.

Ubuntu Zombie comes first because it is the implemented reference product.
The later agents are variations on its proven product lessons, not modes,
personas, components, or subclasses of its runtime. Each must become a
separate installation with its own authority, security boundary, lifecycle,
documentation, and release.

## Catalogue

| Product | Status in this repository | Purpose | Maximum authority | Default identity | Default port |
| ------- | ------------------------- | ------- | ----------------- | ---------------- | ------------ |
| [Ubuntu Zombie](ubuntu-zombie.md) | Implemented | AI Systems Administrator | Root through its policy and approval boundary | `zombie` | `7878` |
| [Imaginary Friend](imaginary-friend.md) | Product definition | Private conversational companion and workspace | Its own files and nominated workspace only | `friend` | `6767` |
| [Curriculum Flame](curriculum-flame.md) | Product definition and detailed specification | Curriculum-gated local AI for children | Its own state and nominated learner workspaces | `flame` | `5656` |
| [ERIC](eric.md) | Product definition | Longitudinal personal continuity agent | Its own evidence and model; separately authorised Executor actions only | `eric` | `4545` |

“Implemented” means this repository currently ships and tests the product.
A product definition records the intended product and its acceptance gates;
it does not claim that the software is complete or safe to deploy.
Curriculum Flame implementation belongs to its
[product-owned repository](https://github.com/japer-technology/curriculum-flame).
Imaginary Friend and ERIC likewise require their own repositories before
implementation.

## Reading order

1. Read [Ubuntu Zombie](ubuntu-zombie.md) for the working reference:
   installation, policy, audit, lifecycle, updates, and removal.
2. Read the later product documents to see which lessons are retained and
   which privileged mechanisms are removed.
3. Use the [AI agent definition template](template.md) for a new proposal.
4. Use the original
   [family plan](../options/ghosts-in-the-machine-plan.md) for rationale,
   implementation sequencing, risks, and the full co-installation matrix.

## The family rule: copy, separate, improve

Every new family member follows the same progression:

1. **Copy the lessons.** Begin from a pinned, audited Ubuntu Zombie release
   and retain only useful installer, lifecycle, audit, test, packaging, and
   documentation disciplines.
2. **Separate the product.** Rename every account, group, path, unit,
   command, environment variable, cookie, port, log, manifest, receipt, and
   package before the first install.
3. **Remove authority.** Delete root access, general shell execution,
   host-wide reads, package and service control, and every capability the
   new purpose does not require.
4. **Write a new boundary.** Define a product-specific threat model, policy,
   approval model, data model, and refusal behaviour. It is not a lower
   Ubuntu Zombie capability setting.
5. **Own the lifecycle.** Build a dedicated installer, updater, verifier,
   doctor, repair path, rollback or recovery path, and uninstaller.
6. **Improve the mechanism.** Record at least one measurable improvement
   over the inherited design and prove it in tests.

After the copy there is no runtime import, shared payload, common virtual
environment, source submodule, service template, policy package, or
automatic code synchronisation. A useful fix can be ported manually, but it
is reviewed, tested, versioned, and released independently by every product
that adopts it.

## Lessons every product must preserve

These are acceptance outcomes, not a shared implementation:

1. **Idempotent convergence:** a re-run reaches the declared state without
   destroying valid credentials or state.
2. **Interactive and unattended operation:** required values are
   reviewable; non-interactive mode never prompts and exits `64` when a
   required input is missing.
3. **Inspection before mutation:** preflight, parameter review, and dry-run
   expose intended host changes before root applies them.
4. **Least authority by construction:** Linux identities, filesystem
   ownership, service confinement, tools, and policy agree on the maximum
   authority.
5. **Policy and audit together:** every sensitive action passes through the
   product's policy and reaches its audit trail.
6. **Independent authentication:** raw passwords and session secrets never
   enter logs, diagnostics, or ordinary receipts.
7. **Operator control:** every product provides credential rotation, health
   checks, diagnostics, a kill switch or suspension control, and removal.
8. **Reversibility:** uninstall removes only product-owned resources and
   protects state destruction with explicit confirmation.
9. **Safe updates:** updates preserve or migrate state, validate before
   committing, and document rollback or recovery.
10. **Release trust:** artifacts are checksum-pinned, signed,
    provenance-verifiable, and accompanied by an SBOM where practical.
11. **Honest boundaries:** documentation says what the product cannot do;
    prompts are never described as a security boundary.
12. **Evidence before release:** lint, tests, packaging, disposable-VM
    lifecycle tests, and negative security tests pass.

## Independence contract

| Concern | Each product owns |
| ------- | ----------------- |
| Source and release | Repository, version, changelog, artifact, SBOM, checksums, signatures, and provenance |
| Installation | Installer, prompts, preflight, dry-run, receipt, ownership markers, and rollback |
| Update | Compatibility checks, backup, migration, health gate, rollback, schedule, and release channel |
| Removal | An uninstaller that cannot select or delete another agent |
| Runtime | Code tree, dependencies, environment, templates, tools, and processes |
| Identity | Linux users, groups, optional sharing groups, and service accounts |
| Authentication | Passwords, hashes, signing keys, cookies, rotation, and recovery |
| Provider access | Credential file and model selection; never a sibling's secrets |
| Policy | Threat model, allowed actions, refusal rules, approvals, and fail-closed behaviour |
| State | Configuration, history, lifecycle, cache, database, and backup format |
| Observability | Audit and event logs, journal identifiers, diagnostics, and rotation |
| Host resources | Ports, units, commands, firewall rules, paths, manifests, and package ownership |
| Quality | Tests, VM matrix, red-team cases, release gates, and documentation |

Products may independently select the same language or upstream dependency.
They do not share a live installed copy merely because they have a common
ancestor.

## Authority is deliberately asymmetric

Ubuntu Zombie remains the only generally root-capable member. A later agent
does not receive passwordless general `sudo`, a login shell, membership in a
privilege-bearing group, or a general command runner. A narrowly privileged
operation, if essential, must use a closed root-owned helper for enumerated
operations and pass through that product's policy and audit trail.

Less-privileged agents must not read or write Ubuntu Zombie's or one
another's secrets, code, policy, state, logs, or ports. Ubuntu Zombie can
inspect the entire host because it is root-capable; same-machine isolation
cannot hide another agent from it. A dedicated machine remains the stronger
deployment for child data, ERIC evidence, or any boundary that must exclude
the Systems Administrator.

No prompt, persona, password, approval, or template can increase installed
authority.

## Initial host namespace reservations

These reservations prevent accidental overlap; each product must validate
the real host and refuse to adopt an unmarked resource.

| Resource | Ubuntu Zombie | Imaginary Friend | Curriculum Flame | ERIC |
| -------- | ------------- | ---------------- | ---------------- | ---- |
| Install root | `/opt/ai-zombie` | `/opt/imaginary-friend` | `/opt/curriculum-flame` | `/opt/eric` |
| Configuration | `/etc/ubuntu-zombie` | `/etc/imaginary-friend` | `/etc/curriculum-flame` | `/etc/eric` |
| State | `/var/lib/ubuntu-zombie` and `/opt/ai-zombie/state` | `/var/lib/imaginary-friend` | `/var/lib/curriculum-flame` | `/var/lib/eric` |
| Logs | `/var/log/ubuntu-zombie` | `/var/log/imaginary-friend` | `/var/log/curriculum-flame` | `/var/log/eric` |
| Service prefix | `ubuntu-zombie-*` | `imaginary-friend-*` | `curriculum-flame-*` | `eric-*` |
| Command prefix | `zombie-*` | `friend-*` | `flame-*` | `eric-*` |
| Environment prefix | `ZOMBIE_*` | `FRIEND_*` | `FLAME_*` | `ERIC_*` |

Every web product also owns a unique session-signing key and cookie name.
Passwords, provider keys, local-model tokens, guardian credentials, and
encryption keys are generated or supplied independently and are never
copied, linked, inherited, or accepted across products.

## Installation and lifecycle contract

There is no family installer and no Ubuntu Zombie target for another agent.
An installation is one product-owned transaction:

1. obtain that product's release and verify its artifact, checksum,
   signature, provenance, and SBOM;
2. inspect identities, names, paths, ports, units, and ownership markers
   for collisions before mutation;
3. review the exact product purpose, requested authority, settings, and
   planned host changes;
4. install only the product's identities, files, credentials, state,
   services, logs, receipts, and ownership markers;
5. run the product's health and security-boundary checks before recording
   success.

Every product defines these lifecycle operations:

| Operation | Required outcome |
| --------- | ---------------- |
| Install | Converges from a clean or valid existing state |
| Verify | Reads state and reports whether the declared installation is present |
| Doctor | Explains drift and product-specific recovery without mutation |
| Repair | Reasserts only known-safe product-owned state |
| Update | Verifies, backs up, migrates, validates, and health-checks one product |
| Rollback or recovery | Restores a known-good product state without weakening policy |
| Suspend or kill | Stops useful operation while following retention rules |
| Uninstall | Removes only owned resources and explicitly handles retained state |

## Update management

There is no “update all agents” command. Each updater must:

- identify only installations carrying its ownership markers;
- verify its own release before privileged work;
- explain compatibility and state risks;
- preserve its passwords, keys, history, policy, and lifecycle unless a
  documented migration changes them;
- back up or snapshot state that a migration can damage;
- validate migrations before switching the running version;
- restart and health-check only its own services;
- audit the old version, new version, migration, and outcome;
- provide a product-appropriate rollback or recovery path; and
- leave every sibling's files and processes untouched.

Versions, release schedules, migration formats, and update acknowledgements
are never inherited from another product.

## Co-installation contract

When products share a host:

- installers fail before mutation on identity, path, port, unit, command,
  cookie, or ownership collisions;
- no product requires a sibling to be installed;
- each listens on its own loopback port and owns only its firewall rules;
- each accepts only its own passwords, cookies, sessions, and reset flow;
- non-root service identities cannot enumerate or read sibling protected
  directories;
- update, repair, suspension, and uninstall affect only the selected
  product; and
- cross-agent messaging, shared memory, shared credentials, shared approval
  queues, and shared audit logs remain absent.

## Defining the next agent

A future member is a deliberately designed and released product, not an
operator-authored persona file. Copy [`template.md`](template.md) and answer
at least:

1. What single human need does it serve?
2. Who uses it and who operates it?
3. What maximum authority does it require, and why is that less than Ubuntu
   Zombie?
4. Which tools, paths, destinations, and data does it need?
5. Which unique host and credential namespaces does it own?
6. What can never be shared with a sibling?
7. How does every lifecycle operation work?
8. Which Ubuntu Zombie lessons remain and which privileged mechanisms are
   removed?
9. What does this product measurably improve?
10. How will standalone and co-installation security be proved?

The proposal is incomplete until every open decision that affects
authority, data, credentials, installation, updates, or removal has an
owner and an acceptance test.

## Validation before hand-off

Each product repository must test clean interactive and unattended
installation, required-input exit `64`, dry-run accuracy, idempotent
reinstall, permissions, unique authentication, malformed state, capability
allow and deny lists, updates from supported versions, migration failure,
rollback, diagnostics redaction, suspension, and uninstall.

Disposable Ubuntu VMs must also test every supported co-installation
combination. Record resource names, sibling file hashes, service start
times, cross-login rejection, service-account access failures, independent
updates, and selective uninstall results.

The product-specific negative suites begin with:

- **Ubuntu Zombie:** policy, approval, audit, TTL, reinstall, update, and
  root-capable behaviour remain unchanged.
- **Imaginary Friend:** shell, host inspection, network access, workspace
  escape, self-modification, sibling reads, and cross-product login fail.
- **Curriculum Flame:** Friend denials also hold; child access cannot reach
  guardian data, unvalidated output never streams, curriculum bypass is
  blocked, and missing validators stop service.
- **ERIC:** generated output never becomes source evidence; citations and
  provenance cannot be fabricated; a compromised Twin cannot reach vault
  keys, alter the Constitution, transition lifecycle, or invoke the
  Executor.

## Documentation ownership

This catalogue records family definitions and links. Ubuntu Zombie's live
operating instructions remain in this repository. Every later product must
own its README, vision, architecture, security and privacy models,
configuration, installation, upgrading, troubleshooting, release, and
disclosure documents.

ERIC must additionally own evidence and provenance schemas, its consent
model, Constitution and guardian formats, Executor authority mapping,
succession guide, data-protection assessment, and legal-review record.

