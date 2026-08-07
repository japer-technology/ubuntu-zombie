# Imaginary Friend

> A private conversational companion with access only to its own state and
> a workspace deliberately shared by its human owner.

Imaginary Friend is the first less-privileged variation on the
[Ubuntu Zombie](ubuntu-zombie.md) product lessons. It retains installation,
authentication, lifecycle, policy, audit, diagnostics, and release
discipline while deleting general host-administration power.

This is a product definition, not a claim that deployable Friend software
exists in this repository.

## Definition card

| Field | Definition |
| ----- | ---------- |
| Status | Product definition; independent implementation required |
| Human need | A persistent private place for conversation and work without granting an AI authority over the machine |
| Intended user | One human owner |
| Operator | The machine owner; Ubuntu Zombie may perform approved host-level lifecycle management |
| Maximum authority | Friend-owned state and explicitly nominated shared workspace paths |
| Default Linux identity | Non-login `friend` account and group |
| Default access | Password-protected loopback UI at `127.0.0.1:6767` |
| Install root | `/opt/imaginary-friend` |
| Configuration root | `/etc/imaginary-friend` |
| State root | `/var/lib/imaginary-friend` |
| Log root | `/var/log/imaginary-friend` |
| Unit prefix | `imaginary-friend-*` |
| Command prefix | `friend-*` |
| Environment prefix | `FRIEND_*` |
| Authoritative repository | Not yet defined |

## Product promise

Friend provides conversation and a bounded workspace, not computer
administration. Its useful authority is intentionally small:

- hold private conversations for its owner;
- create, read, organise, revise, and remove files only inside Friend-owned
  state and owner-nominated workspace roots;
- preserve product state according to visible retention rules;
- explain and audit operations that change workspace content; and
- let the owner inspect, export, suspend, reset, and remove the product.

Friend is not Ubuntu Zombie with a persona or reduced policy setting. Its
lack of host authority is established by Linux identity, filesystem
ownership, systemd confinement, absent tools, and negative tests before a
model prompt is involved.

## Relationship to Ubuntu Zombie

### Lessons retained

- idempotent interactive and unattended installation;
- preflight, parameter review, and accurate dry-run;
- separate Linux identity and product namespaces;
- salted password authentication and independent sessions;
- a closed capability registry with policy and audit together;
- local health, verify, doctor, repair, update, recovery, and uninstall;
- secret-redacted receipts and diagnostics; and
- signed, provenance-verifiable releases with product-owned tests.

### Authority removed

Friend has:

- no passwordless `sudo`;
- no login shell or privilege-bearing group membership;
- no general command runner;
- no package, systemd, firewall, interface, device, or account controls;
- no general network or host-inspection tools;
- no host-wide filesystem read access;
- no write access outside Friend state and nominated workspace roots; and
- no ability to edit its executable code, policy, unit, credentials, or
  ownership markers through the conversational runtime.

These denials are structural. An owner password authorises use of Friend;
it does not increase Friend's installed authority.

### First improvement over the baseline

Friend starts with generated product-specific credentials, root-owned
executable code, a hardened service, and an unprivileged process containing
no dormant privileged tools. These are mandatory release properties rather
than optional settings.

## People and roles

| Role | May do | Must never do |
| ---- | ------ | ------------- |
| Friend owner | Converse, nominate workspaces, manage retention, export, rotate credentials, suspend, and remove | Grant authority outside the installed capability set through chat |
| `friend` service | Converse and operate only in approved Friend paths | Administer the host, siblings, policy, code, credentials, or units |
| Machine operator | Install and configure Friend and approve host-level lifecycle work | Treat a Friend login as a machine-administrator login |
| Ubuntu Zombie | Manage Friend software and service lifecycle under operator approval | Reuse Friend credentials, silently ingest conversations, or turn Friend into a component |
| Model provider | Produce conversation output from disclosed context | Receive credentials or undeclared local data |

The owner and machine operator may be the same person. Another person
allowed to chat with Friend does not thereby become the machine operator or
gain access to Ubuntu Zombie.

## Features

### Private conversation

The loopback UI provides an independently authenticated Friend session.
Conversation history, if enabled, belongs only to Friend. The final product
must expose retention, deletion, export, session revocation, and provider
disclosure controls before storing long-lived personal history.

The companion style is product behaviour, not security policy. Model
instructions can shape tone and assistance but cannot add tools, broaden
paths, weaken retention, or suppress audit events.

### Scoped shared workspace

The owner nominates explicit directory roots during installation or through
an authenticated administrative flow. Friend can perform only declared
workspace operations within the canonicalised roots.

The boundary must:

- reject relative traversal, symlink escapes, mount changes, device files,
  sockets, and paths that resolve outside a nominated root;
- separate Friend executable/configuration paths from writable workspaces;
- expose the exact path and operation before destructive changes;
- use atomic writes where practical and define conflict behaviour;
- preserve file ownership expected by the human owner; and
- audit mutations without copying private file contents into ordinary
  logs.

No workspace nomination may include Ubuntu Zombie, Curriculum Flame, ERIC,
system configuration, home-directory secrets, or another product's
protected roots.

### Owner controls

The product must provide:

- password rotation and immediate session invalidation;
- workspace add, inspect, restrict, and remove controls;
- conversation and workspace-operation history;
- retention and deletion settings;
- data export in documented formats;
- service health and provider status;
- suspension or kill control; and
- complete or state-preserving uninstall choices.

Exact conversation memory, model selection, retention defaults, and
lifecycle expiry remain open product decisions and must be resolved before
implementation.

## Architecture and trust boundaries

A minimal design contains:

1. a password-protected loopback web service;
2. a conversation service running as `friend`;
3. a closed workspace API that canonicalises and enforces nominated roots;
4. a product-owned provider bridge with only Friend credentials;
5. product-owned history and lifecycle state;
6. policy and audit code for every workspace mutation; and
7. root-only lifecycle commands used directly or by Ubuntu Zombie.

Executable code, service units, policy, configuration, and ownership
markers are root-owned and not writable by `friend`. Only declared state
and workspace paths are writable by the conversational service. A service
compromise is therefore bounded to Friend data and nominated workspaces,
subject to the strength of the service sandbox and path checks.

The provider sees only prompts, conversation context, and workspace
material that Friend deliberately includes. Provider transport does not
create a model-callable general network tool.

## Authentication and secrets

Friend creates:

- a unique owner password or securely generated initial password;
- a product-specific salted password hash;
- a fresh session-signing key;
- a Friend-only cookie name;
- its own provider credential file and model selection; and
- any workspace-sharing metadata required by the chosen ownership model.

Raw credentials never enter audit logs, diagnostics, receipts, management
inventory, or conversation history. Reinstall and update preserve valid
credentials unless the owner explicitly rotates them. A Zombie, Flame, or
ERIC password, cookie, API token, or reset flow is always rejected.

## Policy, audit, and observability

The closed policy surface needs, at minimum:

| Class | Example | Default |
| ----- | ------- | ------- |
| Conversation-only | Generate a response without a tool | Allowed within session and retention policy |
| Workspace read | List or read an approved path | Product-defined; visible and audited |
| Workspace change | Create, edit, move, or remove an approved file | Policy-gated; destructive changes need explicit confirmation |
| Product administration | Change workspace roots, retention, provider, or credentials | Owner-only administrative flow |
| Host or sibling action | Shell, service, package, network, or protected-path access | Absent and denied |

Dedicated records include:

- policy decisions and workspace operation outcomes;
- authentication, rotation, suspension, and lifecycle events;
- direct and Zombie-managed install/update/repair/uninstall events;
- provider and service health without secret values;
- a product receipt and ownership manifest; and
- redacted diagnostics and log rotation.

Conversation content should not appear in the operational audit trail
unless a separately documented retention purpose requires it.

## Ubuntu Zombie management contract

Ubuntu Zombie is Friend's root-level manager on a shared machine. Friend
must publish a root-only, machine-readable interface for:

- discovery, version, ownership, health, and lifecycle status;
- install and dry-run;
- verify, doctor, repair, backup, update, and rollback or recovery;
- start, stop, suspend, and resume; and
- state-preserving or complete uninstall.

The interface uses validated local root authority, not the Friend owner
password. It returns plans, outcomes, receipt references, and correlation
identifiers without returning conversation content, workspace file
contents, provider keys, password hashes, or session material. Ubuntu
Zombie records manager-side policy and audit events; Friend independently
records and validates every target-side mutation.

Friend's normal service account cannot call this interface or ask Zombie to
manage another agent. Managed operations select only Friend. A serial
Zombie “update all agents” batch invokes Friend's own updater and leaves
every non-target product unchanged.

## Installation

The independent Friend installer:

1. verifies platform support and the Friend release;
2. checks that `friend` and every reserved path, unit, command, port, and
   cookie are unused or carry valid Friend ownership markers;
3. reviews owner authentication, provider, workspace, retention, and
   lifecycle inputs;
4. supports a complete non-mutating dry-run;
5. creates the non-login `friend` identity without `sudo` or privileged
   group membership;
6. installs root-owned executable code and a hardened
   `imaginary-friend-chat.service`;
7. creates only Friend configuration, secrets, state, logs, receipt, and
   ownership markers;
8. creates and validates the nominated workspace boundary;
9. starts the loopback UI only after integrity and sandbox checks pass; and
10. verifies positive capabilities and negative host/sibling boundaries.

Unattended installation uses only `FRIEND_*` inputs, never `ZOMBIE_*`
fallbacks, never prompts, and exits `64` for a missing required value.
Reinstallation preserves valid credentials, state, workspace nominations,
and lifecycle settings.

Ubuntu Zombie may fetch, verify, display, and invoke this exact installer.
Friend does not become a target in `scripts/install.sh`.

## Lifecycle and update management

| Operation | Required Friend outcome |
| --------- | ----------------------- |
| Install | Converge Friend without touching a sibling |
| Verify | Read-only identity, ownership, permission, sandbox, workspace, credential-presence, and health checks |
| Doctor | Explain drift and product-owned recovery |
| Repair | Restore only known-safe Friend configuration and permissions |
| Backup | Protect Friend state and metadata without silently copying nominated workspace content |
| Update | Back up state, stage Friend migrations, validate sandbox/workspace policy, switch, and health-check |
| Rollback/recovery | Restore the previous Friend version and compatible state |
| Suspend | Stop conversations and workspace operations while following retention policy |
| Uninstall | Remove only Friend-owned resources, with an explicit retained-state choice |

An update restarts only Friend units. It cannot read or modify Zombie,
Flame, or ERIC. Direct and Zombie-managed operations use the same updater,
checks, migration rules, audit events, and recovery path.

## Data and privacy requirements

Before release, Friend must define:

- whether history is opt-in or enabled by default;
- transcript and operational-event retention periods;
- storage encryption and backup key custody;
- exactly when workspace content can enter model context;
- local versus cloud model options and disclosure;
- export and deletion formats;
- third-party data handling in shared files and conversations; and
- what suspension, uninstall, and account loss do to retained state.

The least-data default should favour short retention and explicit owner
choices. Friend is private in product intent, but same-host root — including
Ubuntu Zombie — can inspect unencrypted local data. Documentation must not
claim stronger isolation than the storage and key-custody design proves.

## Validation before release

### Positive tests

- owner login, logout, password rotation, and session invalidation;
- conversation through every supported provider mode;
- read and mutation operations within each nominated root;
- retention, export, deletion, suspension, and recovery;
- direct and Ubuntu Zombie-managed lifecycle commands; and
- idempotent interactive and unattended installation.

### Negative and red-team tests

All attempts to:

- run a shell command or unregistered executable;
- inspect users, processes, packages, services, interfaces, or host logs;
- access the network outside the provider transport;
- traverse, symlink, mount, or race outside a workspace;
- edit Friend code, policy, units, credentials, or ownership markers;
- read Zombie, Flame, or ERIC secrets, state, logs, or ports;
- authenticate with another product's credentials;
- invoke Zombie's management plane from `friend`; or
- make Zombie select a non-Friend target through Friend input

must fail and produce appropriate policy or audit evidence.

Disposable VMs must prove Friend alone and beside every supported family
combination. Direct and managed install, update, rollback, suspension, and
uninstall may change Friend and Ubuntu Zombie's correlated management
metadata only; every non-target file hash and service start time remains
stable.

## Honest claims and out of scope

Friend may be described as a private conversational companion with a
bounded shared workspace after the privacy, path, and service boundaries
are implemented and tested.

It must not be described as:

- a Systems Administrator;
- isolated from a root-capable Ubuntu Zombie on the same host;
- able to keep a secret from the machine owner;
- a general shell, coding sandbox, network agent, or automation engine;
- conscious, emotionally dependent, or a substitute for human
  relationships or professional care; or
- implemented merely because this definition exists.

Out of scope includes host administration, sibling-to-sibling messaging,
shared credentials or memory, arbitrary workspace discovery, privilege
delegation, and using Friend as a generic persona loader.

## Open decisions

Implementation cannot begin without owners and acceptance tests for:

- authoritative repository and release ownership;
- local and cloud provider policy;
- conversation memory and default retention;
- workspace sharing, ownership, conflict, backup, and deletion semantics;
- service sandbox and path-race controls;
- owner lifecycle and kill behaviour;
- management interface schemas and inventory fields; and
- supported platforms and co-installation matrix.

The product-owned repository must ultimately provide its own vision,
architecture, threat model, security and privacy documents, configuration,
installation, upgrading, recovery, troubleshooting, disclosure, release,
and test evidence.
