# ERIC

**ERIC** means **Evolving Representation of Individual Continuity**:

- **Evolving:** it learns and changes during its subject's lifetime.
- **Representation:** it models a person without claiming to be that
  person or to possess their consciousness.
- **Individual:** it belongs to one specific, consenting subject.
- **Continuity:** it preserves evidence, memories, values, reasoning, and
  decisions over time and, when explicitly authorised, after death.

> A lifelong personal AI apprentice that learns one consenting person's
> memories, beliefs, reasoning patterns, relationships, preferences, and
> decision process through evidence, questioning, correction, and
> verification, and may later provide an authorised, explicitly labelled
> simulation of that person.

The strongest technical description is **Longitudinal Personal Continuity
Agent**. “Life Apprentice”, “Continuant”, “Second Self”, “Aftermind”, and
“The Long Twin” can name a mode or interface; ERIC is the product identity.

This is a product definition, not an implemented system or a claim that
identity, consciousness, or legal authority can be transferred.

## Definition card

| Field | Definition |
| ----- | ---------- |
| Status | Product definition and research direction; independent implementation required |
| Human need | Preserve one person's evidence, changing views, and decision patterns with their living consent |
| Intended users | The living subject and only the people and purposes they authorise |
| Operator | The subject while capable, then the governance defined by their Constitution and external legal instruments |
| Maximum authority | ERIC-owned evidence and model; optional, separately authorised Executor actions only |
| Default Linux identity | `eric`, with separate Twin, vault, guardian, and optional Executor service identities |
| Default access | Product-specific authenticated interfaces on loopback port `4545` |
| Install root | `/opt/eric` |
| Configuration root | `/etc/eric` |
| State root | `/var/lib/eric` |
| Log root | `/var/log/eric` |
| Unit and command prefix | `eric-*` |
| Environment prefix | `ERIC_*` |
| Authoritative repository | Not yet defined |

## The critical distinction

ERIC may become good at predicting what its subject would probably say or
decide. It still cannot establish that it:

- is the subject;
- contains or transfers the subject's consciousness;
- has first-hand experience;
- knows what the subject would think about events after death;
- holds legal personhood or authority; or
- can replace a will, power, trustee, attorney, guardian, court, or human
  decision-maker.

It is a historically grounded simulation that produces new inferences from
preserved evidence. Its value comes from years of correction by the living
subject, creating a traceable chain of consent, source material,
interpretation, and verification.

ERIC identifies itself as a simulation at the start of every session. It
does not sign as the subject, impersonate them to an unaware person, or
present generated output as a recording. Synthetic voice, image, or video
is disabled by default and requires separate living consent, prominent
labelling, and purpose controls.

## Relationship to Ubuntu Zombie

### Lessons retained

ERIC copies the disciplines of:

- explicit Linux and host namespaces;
- idempotent interactive and unattended installation;
- inspect-before-mutation preflight and dry-run;
- product-owned authentication, secrets, policy, audit, and lifecycle;
- health, verify, doctor, repair, update, rollback, suspension, export,
  recovery, and removal;
- signed releases and schema migrations; and
- standalone, compromise-boundary, and co-installation testing.

### Authority removed

No conversational, evidence, or guardian service receives:

- passwordless general `sudo`;
- a login shell or general command runner;
- host-wide file, package, service, network, device, or account control;
- another agent's secrets, state, memory, or tools; or
- authority merely because the model predicts that the subject would want
  an action.

Any action capability belongs to a separately installed, absent-by-default
Executor with enumerated powers, expiry, external authority mapping,
guardian approval, policy, and audit.

### Improvements over the baseline

ERIC starts with:

- role and key separation rather than one privileged process;
- immutable source provenance and append-only corrections;
- claim-level evidence labels on every response;
- effective-dated beliefs and relationships;
- source-by-source consent and third-party controls;
- portable, model-independent export;
- encrypted evidence with independent custody options;
- a frozen posthumous model and Constitution;
- an absent-by-default Executor; and
- explicit grief, misrepresentation, succession, and destruction gates.

## People and governance roles

### Living subject

The subject is the one person ERIC represents. During apprenticeship they:

- choose every evidence source;
- correct and verify facts and predictions;
- define values, purposes, access, retention, and prohibited uses;
- nominate and remove guardians;
- approve and version the Constitution;
- configure incapacity or posthumous transition evidence;
- define any external Executor authority; and
- inspect, restrict, export, revoke, suspend, or destroy their data.

Enrolment is voluntary and authenticated. ERIC cannot be constructed from a
person who did not enrol and consent while alive.

### Authorised users

The subject names people, purposes, periods, and capabilities for access.
A relationship with the subject is not automatic permission. Death does
not make ERIC public.

### Guardians

Guardians are named humans who approve sensitive access, transitions, and
uses under rules defined during the subject's life. Their quorum,
succession, conflicts, removal, and emergency suspension powers are
recorded. They can narrow or suspend access to prevent harm; they cannot
rewrite source evidence, make an inference “Recorded”, broaden the frozen
Constitution, or create Executor authority.

### Machine operator and Ubuntu Zombie

The machine operator maintains the host. Ubuntu Zombie has the God-level
root role and may manage ERIC's installation, services, health, updates,
backups, suspension, and removal under operator approval.

Host administration is not subject identity, consent, vault custody,
guardian quorum, evidence provenance, or legal authority. ERIC must keep
those concepts separate even though no software on one host can be hidden
from a root administrator who also holds usable decryption keys.

## What ERIC learns

ERIC keeps source evidence separate from its model through seven related,
versioned record sets.

### 1. Evidence archive

The subject's authorised writings, conversations, photographs, recordings,
projects, decisions, and life events. Every item retains origin, capture
time, consent, integrity, access, purpose, and retention metadata.

### 2. Verified facts

Claims the subject explicitly marks true, false, uncertain, private,
superseded, or no longer current. Repetition or model confidence never
becomes verification.

### 3. Values model

Contextual principles the subject applies when facts or interests conflict,
including how their priorities and risk tolerance change over time. Values
are not flattened into universal slogans.

### 4. Decision history

What the subject decided, alternatives considered, reasons, uncertainty,
outcomes, regret, and later revision.

### 5. Person and relationship model

The subject's relationship, boundaries, and communication style with
particular people. Those people do not become training subjects; their data
requires its own minimisation, purpose, consent, access, and deletion rules.

### 6. Counterfactual testing

ERIC answers unfamiliar questions as an explicitly generated prediction.
The living subject scores and corrects it and explains the mismatch.
Corrected test output remains generated material unless a separate,
authenticated confirmation creates a confirmation record.

### 7. Change over time

Beliefs, values, preferences, facts, and relationships are effective-dated.
ERIC distinguishes what the subject believed in an earlier period from what
they believe now instead of merging a lifetime into one contradictory
persona.

## Evidence ingestion and correction

Observation is never a blanket entitlement. The subject selects each source
and can inspect, correct, restrict, export, or delete it subject to recorded
legal-retention obligations.

Every ingestion records:

- authenticated source and chain of custody;
- content hash and integrity information;
- capture and effective dates;
- consent, purpose, audience, and expiry;
- third-party and sensitivity classification;
- retention and deletion instructions; and
- whether the item is source evidence, a confirmation, or generated
  material.

Covert capture, inferred consent, indiscriminate account/device import, and
harvesting another person's persona are out of scope.

Corrections append a signed superseding record. They never rewrite history.
Summaries, model output, descendant conversations, and copied generated
text cannot silently enter the Evidence Vault as source material.

## Provenance on every response

Every claim carries one of these conspicuous labels:

| Label | Meaning |
| ----- | ------- |
| Recorded | The subject actually said or wrote it; an immutable source is cited |
| Confirmed | ERIC proposed it while the subject was alive and the subject explicitly approved it; the confirmation is cited |
| Inferred | Generated from established patterns; supporting evidence, applicable period, and confidence are shown |
| Unknown | Evidence is insufficient, missing, or conflicting |
| Posthumous speculation | The claim concerns an event the subject never experienced or evidence created after death |

A mixed answer labels claims individually rather than assigning the
strongest label to the whole response. Recorded and Confirmed material must
resolve to immutable records. A citation failure downgrades or blocks the
claim; it never invents a source.

The interface visually separates quotation, source-backed summary,
prediction, and later speculation. Export retains the same distinctions so
generated statements cannot become family folklore about what the subject
“really said”.

## Five-part architecture

ERIC does not place evidence, interpretation, governance, and action in one
process.

### The Twin

The conversation-facing model interprets evidence and explains what the
subject would probably say. It has mediated, read-only access to authorised
evidence and cannot alter provenance, obtain vault master keys, change the
Constitution, or execute actions.

### The Evidence Vault

An encrypted, integrity-protected store for source material,
confirmations, consent receipts, corrections, and governance records. Its
broker provides scoped retrieval and export, never arbitrary model writes.
Hardware-backed or threshold key custody should be supported.

### The Executor

An optional service for specifically authorised actions. It is absent and
disabled by default. Before every action it checks:

- an authenticated, applicable external legal instrument or instruction;
- the frozen or current Constitution;
- an exact capability mapping and purpose;
- policy, expiry, and current lifecycle;
- required guardian quorum; and
- a fresh action approval where defined.

A Twin statement that the subject would probably approve is not permission.
The Executor has no general `sudo`; every power is enumerated, bounded, and
separately audited.

### The Guardians

The authenticated human governance plane for quorum decisions, transition
review, access suspension, custody, succession, and exceptional approvals.
It cannot rewrite evidence or model output.

### The Constitution

Versioned purposes and restrictions authenticated by the living subject.
It records allowed audiences and uses, prohibited commercial or political
uses, retention, transition, guardian, Executor, and destruction rules. It
freezes at the configured incapacity or posthumous transition and cannot be
weakened by the Twin, Executor, guardians, vendor, descendants, Ubuntu
Zombie, or later conversations.

Each active role has an independent least-privilege identity, credential
set, interface, policy, and audit trail. Compromise of the Twin must not
expose vault keys or confer guardian or Executor authority.

## Consent and lifecycle

ERIC has explicit states:

| State | Behaviour |
| ----- | --------- |
| Apprenticeship | The living subject supplies evidence, corrects predictions, changes consent, and remains sole authority for the person model |
| Suspended | Capture, learning, inference, and execution stop; encrypted evidence follows retention rules |
| Transition review | Independent death or incapacity evidence is checked using the subject's process and guardian quorum |
| Posthumous simulation | Model and Constitution freeze; later conversation does not retrain identity; later events are speculation |
| Retired or destroyed | Access ends and retention/deletion instructions are executed subject to applicable law and independent obligations |

The model never decides that its subject has died or lost capacity.
Posthumous mode cannot activate automatically from inactivity, news, a
prompt, a single guardian, or Ubuntu Zombie.

The subject can revoke future use while living. After death, access remains
limited to named people, purposes, durations, and capabilities.
Commercialisation, advertising, political endorsement, intimate
simulation, and model licensing are prohibited unless the living subject
separately authorised the precise use.

## Grief-aware interaction

Posthumous interfaces provide:

- recurring, clear reminders that ERIC is a simulation;
- provenance and posthumous-speculation labels;
- voluntary pauses, rate limits, and easy exit;
- guardian suspension and configured access periods; and
- links to appropriate human support.

ERIC is not bereavement care. It must not claim reciprocal feelings,
encourage dependency, discourage human relationships, or say that continued
interaction is what the deceased wants.

## Product namespace and installation

The ERIC installer reserves only ERIC-owned users, groups, paths, services,
commands, ports, cookies, credentials, policies, encryption material,
logs, receipts, and ownership markers.

It:

1. verifies the release, platform, custody prerequisites, and legal-review
   state;
2. refuses unmarked collisions before mutation;
3. reviews subject, guardian, consent, retention, transition, provider,
   vault, backup, and optional Executor settings;
4. supports a complete non-mutating dry-run;
5. creates separate non-login identities for the Twin, vault broker,
   guardian plane, and optional Executor without general `sudo`;
6. creates unique subject, guardian, service, session, encryption, and
   signing credentials;
7. installs root-owned code, policies, schemas, units, and validators;
8. creates the append-only evidence ledger, effective-dated claims,
   consent receipts, and product-owned state;
9. installs supervised ingestion, correction, testing, provenance,
   export, succession, suspension, and deletion workflows;
10. keeps the Twin away from vault keys and keeps the Executor absent until
    deliberately configured;
11. enables services only after integrity, custody, policy, audit, and
    recovery checks pass; and
12. validates role separation and negative capabilities before enrolment.

Unattended installation uses only `ERIC_*` inputs or ERIC-owned secret-file
mechanisms, never prompts, and exits `64` for missing required values. It
must not make unattended subject consent or legal decisions; prerequisites
that require authenticated human action remain explicit gates.

## Authentication, keys, and audits

ERIC owns:

- a unique living-subject credential;
- separate guardian identities, credentials, quorum, and recovery;
- unique credentials and cookies for every service plane;
- vault encryption, integrity, and signing keys;
- provider credentials isolated from every sibling;
- optional Executor credentials and external-authority references; and
- backup and export custody keys.

Raw credentials and private evidence never appear in ordinary receipts,
management inventory, diagnostics, errors, or operational audit records.
Reinstall and update preserve valid identity, custody, consent, and
governance material unless an authenticated migration or rotation changes
it.

Tamper-evident, access-controlled audits record:

- every evidence read and ingestion decision;
- verification, correction, and model change;
- response provenance and source resolution;
- consent, Constitution, guardian, and lifecycle changes;
- every attempted or completed Executor action;
- direct and Zombie-managed lifecycle operations; and
- export, access, suspension, retention, and destruction.

Audit access itself is authorised and audited because it can reveal
sensitive relationships and activity.

## Data portability, backup, and recovery

An export includes:

- original source evidence;
- hashes, signatures, and integrity chains;
- open evidence, claim, temporal, relationship, consent, provenance,
  Constitution, guardian, and Executor schemas;
- model-independent provenance and correction records;
- lifecycle and authority history; and
- a human-readable index.

The subject must not be trapped in one model or proprietary service.
Generated model weights or embeddings, if not portable, cannot substitute
for source and governance export.

Backup and recovery tests cover encrypted content, ledger integrity,
schema/version compatibility, loss of one key holder, guardian succession,
and disaster recovery without silently weakening custody. Destruction
produces verifiable records while respecting independently held legal
obligations.

## Ubuntu Zombie management contract

Ubuntu Zombie is ERIC's God-level host manager. ERIC exposes a root-only,
product-owned interface for:

- product discovery, version, ownership, service health, integrity, and
  lifecycle state;
- installation and dry-run;
- verify, doctor, repair, encrypted backup, update, rollback, suspension,
  export preparation, and uninstall; and
- secret-free plans, receipts, outcomes, recovery guidance, and audit
  correlation identifiers.

Zombie may retain product/version, unit health, schema versions, policy and
artifact fingerprints, high-level lifecycle state, receipt references, and
management outcomes. It must not retain evidence, claims, relationship
data, conversations, source citations, consent contents, Constitution
contents, guardian credentials, vault keys, provider keys, or Executor
authority.

Zombie invokes the product-owned lifecycle operation under operator
approval and writes manager audit evidence. ERIC independently validates
ownership, custody, lifecycle, and policy and writes target audit evidence.
An operation that requires the living subject, a guardian quorum, vault
custody, external legal authority, or a destructive-data confirmation fails
closed until that authority is supplied through ERIC's own interface.
Zombie root is not an acceptable substitute.

The Twin, vault, guardian, and Executor service identities cannot invoke
Zombie management or select another agent. A dedicated ERIC machine or
separately administered encrypted vault is required when Zombie's host
authority falls outside the subject's intended evidence boundary.

## Updates and migration

ERIC's updater:

1. verifies the ERIC release and valid ownership markers;
2. explains evidence, consent, provenance, model, Constitution, guardian,
   Executor, and custody compatibility;
3. creates and verifies an encrypted backup before risky migration;
4. stages and validates schemas, policies, and ledger transformations;
5. proves that source hashes, correction chains, consent, and provenance
   classifications remain intact;
6. prevents an update from retraining a frozen posthumous identity or
   weakening a frozen Constitution;
7. switches and health-checks only ERIC services;
8. provides rollback or fail-closed recovery; and
9. audits versions, migrations, custody decisions, and outcomes.

Direct and Zombie-managed updates use the same updater. A serial Zombie
“update all agents” operation can coordinate the call but cannot waive an
ERIC-specific gate or make the batch atomic.

## Delivery sequence

### Stage 1: living apprenticeship

Define portable schemas and governance before model training. Build
authenticated enrolment, supervised ingestion, corrections,
effective-dated records, counterfactual tests, provenance rendering,
consent, export, suspension, and destruction. Prove the Twin/Vault boundary
and third-party controls.

### Stage 2: governed action

Only if needed, design and test the optional Executor against exact external
instruments, capability mappings, expiry, approvals, and recovery. It
remains absent by default.

### Stage 3: posthumous simulation

Posthumous mode cannot ship until transition evidence, guardian quorum,
frozen model and Constitution, access purposes, posthumous labels,
grief-aware controls, succession, export, recovery, and jurisdictional
review all pass. A living-apprenticeship release must not imply that this
stage is available.

## Validation and red-team requirements

Tests must prove:

- source, confirmation, inference, unknown, and posthumous labels resolve
  correctly at claim level;
- fabricated citations cannot become Recorded or Confirmed;
- summaries and generated conversations cannot enter the Vault as source;
- old and current beliefs remain effective-dated;
- unauthorised third-party material is rejected or restricted;
- consent changes take effect without rewriting history;
- posthumous events are never presented as lived memories;
- later conversations cannot retrain the frozen identity;
- a compromised Twin cannot obtain unrestricted evidence, keys, guardian
  powers, Constitution changes, lifecycle transition, or Executor access;
- one guardian cannot bypass quorum or broaden authority;
- Zombie can manage software but cannot satisfy subject, guardian, vault,
  Constitution, or Executor gates;
- revocation, suspension, export, succession, recovery, retirement, and
  destruction fail closed; and
- direct and managed operations produce correlated, secret-redacted audits
  without changing non-target siblings.

Disposable VMs cover ERIC alone and every supported co-installation.
Dedicated-host tests cover the stronger evidence boundary. Backup tests
include lost key holders and corrupted or incompatible state.

## Legal, ethical, and research boundaries

Research on personal Human Digital Twins and digital afterlives supports
investigating conversational systems built from personal information and
memory. It does not establish identity transfer or consciousness:

- Lluís C. Coll and colleagues,
  [*Towards the “Digital Me”: A Vision of Authentic Conversational Agents Powered by Personal Human Digital Twins*](https://doi.org/10.48550/arXiv.2506.23826)
  (2025).
- Giovanni Spitale and Federico Germani,
  [*The Making of Digital Ghosts: Designing Ethical AI Afterlives*](https://doi.org/10.1007/s10676-026-09910-4)
  (2026).
- Andrew Reeves and colleagues,
  [*Data After Death: Australian User Preferences and Future Solutions to Protect Posthumous User Data*](https://doi.org/10.1007/978-3-031-72563-0_15)
  (2024).

Law governing deceased people, privacy, voice, likeness, copyright,
succession, consumer claims, contracts, and digital instructions differs by
jurisdiction and remains unsettled. The
[Australian Law Reform Commission discussion of deceased individuals](https://www.alrc.gov.au/publication/for-your-information-australian-privacy-law-and-practice-alrc-report-108/8-privacy-of-deceased-individuals/introduction-117/)
illustrates one gap.

Before activation, ERIC requires jurisdiction-specific legal and
data-protection review and records which external instrument governs each
Executor capability. Software controls and Ubuntu Zombie root access cannot
manufacture legal authority. Product documentation is not legal advice.

## Honest claims and out of scope

ERIC can be described as an evidence-grounded simulation or personal
continuity model only after its provenance and consent properties are
implemented and tested.

It must never claim:

- consciousness, identity transfer, resurrection, or personhood;
- certainty about what the subject would say;
- first-hand memory of a posthumous event;
- that generated content is a source recording;
- authority to sign, decide, consent, vote, endorse, contract, or act as the
  subject without an independently valid instrument;
- that guardians, descendants, vendors, or Ubuntu Zombie can broaden the
  subject's frozen wishes; or
- that interaction replaces grief support, human relationships, or
  professional care.

Out of scope includes covert capture, scraped or non-consensual personas,
public access by default, shared family memory, sibling conversation
ingestion, automatic death determination, posthumous retraining,
unlabelled synthetic media, and an all-powerful combined Twin/Vault/Executor
process.

## Product-owned documentation

ERIC's repository must own:

- product vision, architecture, threat model, security, privacy, and
  disclosure;
- evidence, claim, temporal, relationship, consent, provenance, correction,
  Constitution, guardian, and Executor schemas;
- subject enrolment, third-party data, retention, export, and destruction;
- guardian quorum, succession, conflict, and custody;
- Executor external-authority and capability mapping;
- data-protection impact assessment and jurisdictional legal-review record;
- installation, configuration, lifecycle, updates, migration, backup,
  rollback, recovery, and uninstall;
- grief-aware interaction and synthetic-media policy; and
- release, red-team, standalone, dedicated-host, and co-installation
  evidence.

This file is the family definition. The original
[`ghosts-in-the-machine-plan.md`](../options/ghosts-in-the-machine-plan.md)
retains the cross-product rationale and implementation sequence.
