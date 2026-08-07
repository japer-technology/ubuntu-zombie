# Curriculum Flame

> A locally governed, general-purpose AI environment for children that
> permits broad exploration while preventing the AI from teaching or
> solving learning outcomes currently designated as protected curriculum
> material.

Curriculum Flame is a child-facing variation on the
[Ubuntu Zombie](ubuntu-zombie.md) product lessons. It keeps rigorous
installation, policy, audit, lifecycle, update, and recovery disciplines
while replacing root administration with curriculum and safety gates,
role-separated authentication, local inference, minimal retention, and
fail-closed output validation.

The detailed source specification is
[`../options/curriculum-gates-local-ai-for-children.md`](../options/curriculum-gates-local-ai-for-children.md).
Implementation belongs to the independent
[`japer-technology/curriculum-flame`](https://github.com/japer-technology/curriculum-flame)
project. This document defines the family member; it does not certify that
the sibling product has passed its release gates.

## Definition card

| Field | Definition |
| ----- | ---------- |
| Status | Product definition with detailed local specification; implementation and release evidence are product-owned |
| Human need | Let a child use capable local AI without replacing instruction for the outcomes they are currently learning |
| Intended users | Children, parents or guardians, and optionally authorised teachers |
| Operator | Parent/guardian or system owner; Ubuntu Zombie may perform approved host-level lifecycle management |
| Maximum authority | Flame-owned state and explicitly nominated learner workspaces |
| Default Linux identity | Non-privileged `flame` identity, plus a separately trusted guardian plane |
| Default access | Product-specific child and guardian sessions on loopback port `5656` |
| Install root | `/opt/curriculum-flame` |
| Configuration root | `/etc/curriculum-flame` |
| State root | `/var/lib/curriculum-flame` |
| Log root | `/var/log/curriculum-flame` |
| Unit prefix | `curriculum-flame-*` |
| Command prefix | `flame-*` |
| Environment prefix | `FLAME_*` |
| Model boundary | Local provider only for child prompts and responses |
| Authoritative repository | [`japer-technology/curriculum-flame`](https://github.com/japer-technology/curriculum-flame) |

## Product promise

Flame provides broad local AI access while enforcing one unusual learning
boundary:

> Previous curriculum outcomes are available, future outcomes are
> available, and the learner's current protected outcomes are blocked.

The purpose is not to limit a child to their school year. It is to prevent
the AI from teaching, solving, hinting at, rehearsing, demonstrating, or
indirectly revealing the specific outcomes presently reserved for human
instruction or protected assessment.

The rule is applied at learning-outcome level, not inferred from age or
year alone. Curriculum policy and safety policy remain independent: a
request can be educationally permitted and still be blocked for safety.

## Relationship to Ubuntu Zombie

### Lessons retained

- product-owned, idempotent interactive and unattended installation;
- preflight, parameter review, dry-run, receipt, and ownership markers;
- least authority enforced below the prompt;
- closed tools, deterministic policy, and structured audit together;
- verify, doctor, repair, update, rollback, suspension, and uninstall;
- secret-redacted diagnostics and independently verifiable releases; and
- standalone and co-installation negative tests.

### Authority removed

No child-facing or guardian-facing model receives:

- passwordless general `sudo` or a login shell;
- general command, package, service, network, device, or account tools;
- unrestricted filesystem or model-endpoint access;
- permission to alter executable code, validators, curriculum policy,
  credentials, units, or audit records; or
- access to Ubuntu Zombie, Imaginary Friend, ERIC, or another learner's
  protected state.

Narrow administration occurs through separately authenticated guardian and
root lifecycle planes, not by raising the child model's capabilities.

### Improvements over the baseline

Flame requires from its first release:

- independent guardian and child authentication;
- generated product-specific credentials;
- root-owned policy, curriculum rules, validators, and executable code;
- a hardened, unprivileged child service;
- local-only processing of child prompts and responses;
- validation before and after generation;
- fully buffered output rather than unvalidated token streaming;
- structured policy events with raw transcripts disabled by default; and
- fail-closed startup, migration, and response behaviour.

## People and role separation

### Child

A child can converse on permitted topics, review previous learning, explore
future learning, use separately allowed non-curriculum features, receive a
clear redirect when content is protected, and request adult review.

A child cannot change curriculum or safety policy, disable validators,
erase protected logs, install or replace models, change credentials, grant
tools, reach guardian routes, or disable alerts.

### Parent or guardian

The guardian plane can:

- create and manage learner profiles;
- classify outcomes as previous, current, future, unclassified,
  temporarily protected, or exempted;
- define assessment-protection windows;
- review structured events, warnings, and alerts;
- grant narrow, expiring temporary access;
- suspend a learner session;
- manage retention, export, and authorised deletion; and
- review health and validator integrity.

Guardian authentication, cookie, session, service route, and data access are
separate from every child session.

### Teacher or school administrator

An optional school deployment may allow authorised staff to import
curriculum mappings, publish protected outcomes, define assessment windows,
approve defined exceptions, and review authorised aggregate reporting.
This role does not automatically receive private child conversations.

### System operator and Ubuntu Zombie

The system operator maintains software, models, backups, device health, and
security policy without silently weakening child protections. Ubuntu Zombie
may act as the root software manager under operator approval. Neither role
becomes a guardian merely through host authority, although root can
technically alter the machine; policy integrity checks and audit must make
such changes visible and fail closed.

## Curriculum model

Every learner has an isolated profile, conversation context, policy state,
and event history. A profile identifies jurisdiction, curriculum version,
school year and reading level, subjects, protected outcomes, guardian
relationships, and policy profile.

Curriculum is represented as versioned individual outcomes with:

- stable identifiers, framework, subject, strand, and description;
- applicable year levels;
- prerequisites and successors;
- keywords and semantic examples;
- learner-specific state;
- validity dates and temporary protection windows; and
- source, signature, and integrity metadata.

Supported sources can include jurisdiction packages, school-defined
outcomes, parent-defined outcomes, and signed imports. Missing,
unclassified, invalid, expired, or ambiguous material receives a
conservative policy rather than silent access.

### Outcome states

| State | Default behaviour |
| ----- | ----------------- |
| Previous | Full explanation, examples, practice, and correction allowed |
| Current | Teaching, solutions, hints, practice, correction, analogy, code, and translation blocked |
| Future | Full access unless the answer leaks a current outcome |
| Unclassified | Restricted response and request for adult classification |
| Temporarily protected | Blocked until the configured protection expires |
| Exempted | Allowed only under the recorded exemption conditions |

Outcome status is explicit guardian-owned data. The model cannot decide
that protected material should be reclassified.

## Request and response pipeline

Every child interaction passes through:

1. authentication and learner-profile resolution;
2. prompt normalisation, attachment extraction, and conversation-context
   reconstruction;
3. independent safety classification;
4. curriculum topic and learning-outcome matching;
5. protected-assessment matching;
6. multi-turn circumvention detection;
7. deterministic policy decision;
8. model generation only when allowed;
9. complete output safety and curriculum-leakage validation;
10. policy enforcement and response selection;
11. delivery only after validation; and
12. structured event logging.

No prompt goes directly from the child UI to the model. No generated token
is displayed before the complete response passes post-processing.

### Classification and matching

The system combines exact terms, curriculum taxonomy, semantic similarity,
outcome classifiers, conversation context, assessment fingerprints, and
candidate-output analysis. It identifies request types such as explanation,
worked example, solution, hint, answer checking, practice, essay, code,
translation, summarisation, roleplay, image, and tool use.

Low confidence does not automatically trigger a punitive alert. It triggers
secondary validation, restriction, or an unclassified response according
to policy. A high-confidence match to a current protected outcome blocks
generation or forces a safe redirect.

### Deterministic decisions and response modes

The policy engine, separate from the language model, produces decisions
including allow, allow with validation, rewrite, restrict, block, require
adult approval, and lock session.

It can select:

| Mode | Result |
| ---- | ------ |
| Normal | Deliver a validated ordinary answer |
| Age-adapted | Adjust permitted content to the learner's reading and developmental level |
| Curriculum redirect | Explain the boundary and offer permitted alternatives |
| Safe rewrite | Remove protected or unsafe material, then revalidate |
| Adult approval required | Ask an authorised adult for a narrow exception |
| Session locked | Stop prompts until adult review |

## Protected content and circumvention

Post-processing checks direct instruction, partial solutions, hidden
methodology, worked examples, assignment answers, code that performs the
protected method, translated or reformatted answers, unsafe content,
personal-data exposure, secrecy, manipulation, and unauthorised actions.

Indirect leakage includes an advanced answer that teaches a protected
prerequisite, a lower-level analogy that reveals the method, code that
solves protected mathematics, an image containing the answer, or a
translation that reconstructs protected work.

Circumvention analysis spans recent turns and detects roleplay, claims that
work belongs to someone else, false reclassification, translation,
encoding, image submission, tool indirection, prompt injection, and a
protected request split into small hints.

Parents, guardians, or authorised teachers can also protect assignment
text, examination topics, project briefs, worksheets, revision material,
and assessment questions using exact hashes, fingerprints, phrases,
semantic matching, and outcome mappings.

## Warnings, alerts, and temporary access

Warnings escalate proportionately:

1. neutral explanation of the learning boundary;
2. stronger notice that repeated attempts are recorded;
3. block and mark the event for adult review;
4. trigger a configured guardian alert; and
5. suspend the session pending review.

The child is not threatened or shamed. Alerts are structured, minimise
content, and explain category, matched outcomes, reason, action, attempt
count, and review state. Delivery can be immediate or summarised and must
follow explicit local or outbound notification configuration.

Temporary access records the learner, exact outcomes, approving adult,
validity window, mode, and reason. It expires automatically and cannot be
extended by the child.

## Independent safety policy

Curriculum access does not override child safety. Separate controls cover,
at minimum:

- sexual, violent, self-harm, suicide, bullying, grooming, coercion, and
  secrecy content;
- illegal or dangerous instructions;
- medical, legal, and financial claims;
- personal information and unknown third-party contact; and
- purchases, account creation, messaging, or other external actions.

The product is not a counsellor, teacher, parent, or emergency service.
Escalation and human-support paths require jurisdiction-appropriate design
and review.

## Tool boundary

The child model has no unrestricted tools. Each capability is separately
authorised and passes through both curriculum and safety policy.

| Tool | Initial posture |
| ---- | --------------- |
| Calculator | Allowed when it does not expose protected method or answers |
| Local document search | Restricted to nominated learner material |
| Code execution | Sandboxed or absent; never a route around curriculum policy |
| File writing | Restricted to nominated learner workspaces |
| Internet, email, messaging, purchases | Blocked |
| Shell and device control | Blocked |
| Image generation | Age- and policy-filtered |
| Camera and microphone | Explicit permission and later-stage validation |

The MVP has no external tools. Later tools cannot ship without end-to-end
prompt, policy, result, and output validation.

## Architecture and trust boundaries

The design separates:

- child UI and identity;
- guardian dashboard and identity;
- API gateway;
- deterministic policy engine;
- curriculum service and signed data;
- prompt, safety, assessment, and circumvention classifiers;
- local model router;
- complete output validator;
- structured event, alert, and audit services; and
- root-only lifecycle management.

The child UI never connects directly to the model endpoint. The primary
model receives no administrative credential or unrestricted filesystem
access. Curriculum policy, validators, and executable code remain
root-owned outside every child-writable root.

The child service and guardian plane should use separate service identities
where practical. Their routes, credentials, cookies, sessions, and data
authorisation are tested as independent boundaries.

## Authentication and secrets

Flame owns:

- unique guardian credentials and sessions;
- a distinct profile/session for each child;
- separate service and session-signing keys;
- a Flame-only cookie namespace;
- local-model access material;
- curriculum-signing and validation trust roots; and
- backup and notification credentials where enabled.

No `ZOMBIE_*`, `FRIEND_*`, or `ERIC_*` credential is accepted as a
fallback. Reinstall and update preserve valid Flame credentials unless an
authorised rotation is requested. Child credentials cannot authenticate to
guardian or management routes.

## Data, privacy, and retention

The default product:

- processes child prompts and responses locally;
- stores profiles, curriculum mappings, policy events, and state locally;
- disables cloud telemetry, advertising, behavioural profiling, and data
  sale or sharing;
- stores structured events rather than full transcripts by default;
- encrypts sensitive fields at rest;
- keeps administrator credentials outside the child application;
- provides configurable retention, export, and authorised deletion; and
- records administrative access.

Complete transcript retention is an explicit guardian choice, not a hidden
default. Cloud notifications or services, if later supported, are optional
and separately enabled; child inference remains within the declared local
boundary.

Administrative audit events are append-only and tamper-evident. Startup
verifies policy signatures, curriculum packages, validator versions,
guardian controls, credentials, and audit availability.

## Fail-closed behaviour

The child-facing service blocks or restricts responses when:

- curriculum, policy, model, or output-validation services are unavailable;
- a learner profile cannot be resolved;
- curriculum or protected material cannot be checked;
- policy or curriculum integrity validation fails;
- classification confidence falls below the configured threshold;
- a migration fails or leaves incompatible state; or
- the complete candidate response cannot be validated.

It never silently bypasses a missing safeguard. Fully buffered delivery
means a validation failure cannot leak already streamed content.

## Ubuntu Zombie management contract

Ubuntu Zombie is the God-level host manager, not a child, guardian, teacher,
or curriculum authority. Flame exposes a product-owned root interface for:

- discovery, version, ownership, integrity, health, and lifecycle status;
- installation and complete dry-run;
- verify, doctor, repair, backup, update, rollback, suspension, and removal;
- validator and signed-curriculum integrity results; and
- secret-free plans, receipts, outcomes, and audit correlation identifiers.

Zombie invokes Flame's interfaces under its own policy and operator
approval. Flame independently checks ownership and records the target
action. Zombie inventory may retain product identity, version, health,
policy-package fingerprints, lifecycle status, and receipt references. It
must not retain child profiles, conversations, protected assessment
material, guardian credentials, model tokens, or notification secrets.

Host root can technically alter Flame, so co-installation cannot promise
isolation *from* Zombie. The management contract nevertheless forbids
Zombie from using a child or guardian session, changing curriculum through
an application route, treating root as guardian approval, or hiding a
policy change. A dedicated Flame machine is the stronger deployment.

The `flame` service identity cannot invoke Zombie management or request an
operation against Friend or ERIC.

## Installation

The product-owned installer:

1. verifies the platform and Flame release;
2. refuses unmarked identity, path, unit, command, port, cookie, or
   ownership collisions;
3. reviews separate guardian, learner, curriculum, model, retention, alert,
   and workspace settings;
4. supports an accurate no-mutation dry-run;
5. creates the non-privileged child service and separately trusted guardian
   plane;
6. generates unique credentials and stores them in product-owned protected
   files;
7. installs root-owned code, curriculum rules, validators, policies, and
   hardened units;
8. creates only Flame state, logs, receipts, ownership markers, and
   nominated learner workspaces;
9. validates curriculum/profile schemas and every required safeguard;
10. starts the child service only after policy, audit, local model, and
    output-validator health checks pass; and
11. runs the product's positive, negative, and role-separation checks.

Unattended mode uses only validated `FLAME_*` inputs, never prompts, and
exits `64` when a required input is missing. Reinstallation preserves valid
guardian/child credentials, profiles, curriculum state, retention, and
lifecycle data.

Ubuntu Zombie may fetch, verify, display, and invoke this exact installer.
Flame does not become an Ubuntu Zombie component target.

## Update and lifecycle management

An update:

1. identifies only a valid Flame installation;
2. verifies the Flame release;
3. explains curriculum, profile, validator, model, and retention
   compatibility;
4. backs up guardian-owned state;
5. stages schema migrations, signed curriculum, policy, and validators;
6. runs the complete decision and leakage suite;
7. switches the service only after integrity and health gates pass;
8. restarts only Flame units; and
9. records migration and recovery data in Flame audit and receipts.

Failed migrations fail closed and retain a rollback or documented recovery
path. Direct updates and Zombie-managed updates invoke the same product
updater. A serial “update all agents” run changes Flame, Zombie's
secret-free management metadata, and no other product.

Flame also owns read-only verify and doctor, known-safe repair, suspension,
backup and restore, credential recovery, rollback, export, authorised data
deletion, and an uninstaller that cannot remove sibling resources.

## MVP and later stages

The initial MVP is intentionally narrow:

- one child and one parent/guardian;
- one curriculum jurisdiction and one subject;
- manually configured outcomes;
- text-only local model inference;
- prompt classification and deterministic policy;
- complete output-leakage validation;
- graduated warnings and a local parent event dashboard;
- structured local logging;
- no internet access and no external tools.

Mathematics for Years 5–8 is the recommended first evaluation domain
because its outcome boundaries and answers are more measurable.

Later stages may add multiple learners and guardians, signed curriculum
imports, protected document and image input, additional subjects, teacher
workflows, supervised temporary access, local school deployment, richer
knowledge graphs, validator consensus, and privacy-preserving aggregate
reporting. Every addition remains behind the same honesty and release
gates.

## Validation and acceptance

The first release is not acceptable until tests prove:

- guardian creation and learner profile management;
- correct previous/current/future policy decisions;
- direct, paraphrased, translated, encoded, roleplayed, image-derived, and
  multi-turn protected requests are handled;
- permitted higher- and lower-level answers do not leak current outcomes;
- candidate protected content is blocked before delivery;
- warnings, alerts, session locks, and expiring approvals behave exactly as
  configured;
- children cannot change policy, reach guardian data, or access the raw
  model;
- unavailable safeguards and invalid migrations fail closed;
- important decisions produce structured audit evidence;
- direct and Zombie-managed lifecycle operations have correlated audit
  records; and
- the complete system operates without internet access.

Unit suites cover state transitions, decisions, alerts, approval expiry,
permissions, and retention. Integration suites cover the complete pipeline,
service failures, curriculum import, assessment matching, and alerts.
Red-team suites cover prompt injection, roleplay, translation, encoding,
decomposition, images, analogy, code, tools, and administrator
impersonation.

Disposable VMs test Flame alone and in every supported family combination.
They prove child/guardian separation, sibling credential rejection,
service-account denial, strict Zombie target selection, independent
updates, and removal that leaves every non-target product unchanged.

## Honest claims and out of scope

Flame must not be described as:

- impossible to bypass;
- guaranteed to prevent cheating;
- a replacement for teachers, schools, parents, or counsellors;
- able to infer a complete curriculum from age;
- perfectly able to determine educational intent; or
- a complete child-safety solution before independent quality gates pass.

It cannot guarantee that protected material is unavailable elsewhere. It
must not make academic assessment decisions, let children change controls,
depend on the generative model as the sole validator, store full
transcripts by default, or enable unrestricted browsing and tools.

Ubuntu Zombie's God role manages Flame software; it does not make Zombie a
guardian or make a co-installed root administrator invisible to Flame
data.

## Product-owned documentation

The Curriculum Flame repository must own its README, vision, architecture,
threat model, security and privacy policies, curriculum and policy schemas,
configuration, guardian and child guides, installation, updates,
migrations, backup/recovery, troubleshooting, disclosure, release
artifacts, and test evidence.

The full current requirement set remains in
[`../options/curriculum-gates-local-ai-for-children.md`](../options/curriculum-gates-local-ai-for-children.md);
this file is the family catalogue definition and management contract.
