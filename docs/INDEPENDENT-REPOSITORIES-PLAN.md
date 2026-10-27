# Plan: finish independent installable repositories

## Goal and status

Give every implemented installable its own usable repository, building on
the product separation in [`../ROADMAP.md`](../ROADMAP.md) and the standalone
Forgejo distribution already started.

**This is a proposed completion plan, not a completed migration.** Initially,
keep `ubuntu-zombie` as the canonical development source and publish
validated, one-way product distributions. This matches "also individual
repos" without creating two competing sources of truth. Moving canonical
development into those repositories is a separate, explicit decision, not
a prerequisite for finishing this work.

The existing in-repository implementation contract remains in force until
the targeted documentation and contract changes below land. No repository,
release, workflow permission, or installed machine is changed by this plan.

## Starting point

Reviewed on 2026-10-27 against local source
`32d3554e356bc575897c8b80088175a151f75455` and the Forgejo distribution
`3b4c2ef5235a8b3ec948919d293796a7dd3d508d`. Recheck these baselines before
implementation; they are evidence, not permanent version pins.

- The public root installer targets are `zombie`, `forgejo`,
  `forgejo-runner`, and `llama`. No target still means Zombie.
- `products/forgejo/`, `products/llama/`, `products/imaginary-friend/`,
  and `products/beep/` already own product lifecycles, descriptors,
  versions, tests, documentation, and release workflows. Independent
  product source is not the same as an independently usable repository.
- Forgejo and Llama compatibility commands delegate to those products.
  Runner mutation logic is still root-owned; its extraction remains
  roadmap phase 5. Friend and Beep are separate products, not additional
  root installer component targets.
- The existing `japer-technology/ubuntu-forgejo` repository has Forgejo
  source at its root, a standalone Makefile, copied family schemas, and a
  pre-alpha warning. Its `sync-upstream.yml` runs manually or weekly,
  is designed to validate the canonical product, prepare and validate a
  standalone distribution, and publish a checked snapshot with provenance.
  **It is currently failing, not a proven working reference:** the latest
  three returned runs failed. The latest, on 2026-10-12, stopped in
  `Prepare standalone distribution` because an exact-text Makefile rewrite
  expected a family-test command that upstream no longer contains.
  Publication was skipped. Preserve its safeguards, not its stale rewrite
  list.
- Local product Makefiles still package from `../..`; several include
  `family/schemas` and the root license. Root tar and Debian packaging
  also bundle Forgejo and Llama. Root CI and family tests assume sibling
  product directories.
- The root catalogue is empty and its schema permits releases only from
  `japer-technology/ubuntu-zombie`. Descriptor validators and consumers
  assume `products/<product-id>` paths.
- Beep's release discovery and verification already name
  `japer-technology/beep`, while its release workflow lives here. That
  destination was not accessible in this session; a 404 does not establish
  whether it is absent or private. Resolve this mismatch before claiming
  independent signed releases work.

These observations do not establish that VM, co-installation, or production
catalogue admission gates have passed.

### Evidence and concrete blockers

| Evidence | Consequence for this work |
| --- | --- |
| Forgejo's pinned [`sync-upstream.yml`](https://github.com/japer-technology/ubuntu-forgejo/blob/3b4c2ef5235a8b3ec948919d293796a7dd3d508d/.github/workflows/sync-upstream.yml), especially its Makefile rewrites | Remove stale transformation assumptions at their source; do not disable the occurrence checks and accept unknown output. |
| [Failed sync run](https://github.com/japer-technology/ubuntu-forgejo/actions/runs/38246756572) | Reproduce and fix export failure before replicating automation. A green canonical build did not prove a usable distribution. |
| [`products/forgejo/Makefile`](../products/forgejo/Makefile) and its product-owned boundary tests | Current Forgejo no longer has the shared family-test invocation or runner-fixture dependency that the export rewrites expect. Review the complete transformation list, not only the first failure. |
| [`products/llama/Makefile`](../products/llama/Makefile) | Llama still invokes parent `tests/family` and packages parent schemas. Fix this dependency explicitly rather than dropping conformance coverage. |
| [`family/schemas/product-v1.schema.json`](../family/schemas/product-v1.schema.json) and [`tests/family/conformance.py`](../tests/family/conformance.py) | Existing `source_root` denotes `products/<id>`; a flat repository does not justify silently changing the installed descriptor. |
| [`products/beep/payload/agent/family.py`](../products/beep/payload/agent/family.py) | Beep's embedded manager is implemented and has its own single-repository trust assumptions. Do not describe all family management as unimplemented or treat Beep's release origin as every child's origin. |
| [`Makefile`](../Makefile), [`scripts/build-deb.sh`](../scripts/build-deb.sh), and [`ci.yml`](../.github/workflows/ci.yml) | Root bundles and checks are coupled to product source paths. Keep this working while adding distributions. |

The documentation review also reproduced a root `make test` failure in
`tests/smoke.sh`'s component-manifest JSON verification check. Treat that as
an unresolved baseline blocker, not a passing migration gate. Establish its
cause and a green baseline in a separate focused change; do not hide it,
relax the assertion, or broaden this documentation change into a runtime fix.

## Repository scope

Use the existing `ubuntu-forgejo` name. Confirm the other destination names
and write access before provisioning; names below are proposals, not claims
that repositories exist.

| Installable | Distribution destination | Work remaining |
| --- | --- | --- |
| Zombie | Existing `ubuntu-zombie` | Retain the baseline and compatibility surface. |
| Forgejo | Existing `ubuntu-forgejo` | Finish distribution and release acceptance. |
| Llama | Proposed `ubuntu-llama` | Apply the validated distribution pattern. |
| Imaginary Friend | Proposed `imaginary-friend` | Publish its own source and release surface. |
| Beep | Intended `beep`; confirm availability | Reconcile distribution, discovery, and signing identity. |
| Forgejo Runner | Proposed `ubuntu-forgejo-runner` | Extract its lifecycle first, then distribute it. |

These destinations are under `japer-technology`. A repository name must not
rename installed product IDs, accounts, commands, paths, units, or ports.
The Forgejo repository's broader description does not make the Runner part
of the server product.

Do not create repositories for verbs such as `verify` or `repair`, combined
selections such as `zombie forgejo`, unimplemented option flags, or
definition-only family members. Add future products when they have an
implementation and the same distribution gates.

## Completion sequence

### Delivery decisions

These are the recommended implementation defaults, to be approved with
phase 1 rather than rediscovered differently in every repository:

| Concern | Decision |
| --- | --- |
| Source ownership | Product implementation remains canonical here; destination repositories are one-way distributions with clearly marked generated files. |
| Destination checkout | Product files live at the repository root, preserving the Forgejo work already started. |
| Official release archive | Retain `products/<id>/` plus explicit support files at archive root. Keep descriptor bytes unchanged. Stage this shape during packaging; never use a flat checkout archive as a managed release. |
| Export mechanism | One small build-time exporter here, with per-product data manifests and tests. It must not become a shared installed library or installer framework. |
| Transformations | Make source build/tests layout-independent first. Export by explicit path mapping; any remaining documentation/build transformations must be narrowly specified and tested. No runtime-code rewrites during sync. |
| Publisher | Destination repositories eventually publish their own product releases. Switch each product once at a documented new version; preserve old releases in their original location. |
| Shared contracts | Vendor only needed data schemas and black-box test fixtures, pinned to the same source commit. No runtime network dependency or sibling import. |
| Initial scope | Working direct distributions and verified product releases. A new manager, neutral command, repository rename, and catalogue admission are not prerequisites. |

The current Forgejo destination packages a flat archive. The nested official
release shape is therefore a deliberate packaging change to document and
test, not a claim that the existing destination already meets this contract.
GitHub's automatically generated source archives are source snapshots, not
the verified, product-packaged install artifacts.

### 1. Record ownership and the distribution contract

- [ ] Confirm destination names, repository visibility, maintainers, and
  authorized automation access. Reconcile any destination-only changes
  before the next sync; do not overwrite the work already started.
- [ ] Declare canonical product files versus destination-owned files:
  sync/release workflows, repository settings, and distribution metadata.
  Fixes to generated product files go upstream first. Detect unexpected
  downstream edits and stop with an actionable conflict report.
- [ ] Specify an exact source commit, product version, export manifest,
  transformation version, and output digest for every distribution.
  Preserve attribution, `LICENSE`, and `UPSTREAM.md`; exclude secrets,
  caches, diagnostics, build output, and unrelated sibling products.
- [ ] Name a product maintainer responsible for its destination, a release
  approver responsible for origin/trust cutover, and an integration owner
  responsible for compatibility evidence. One person may hold these roles;
  do not leave failed syncs or release approvals ownerless.
- [ ] Update `docs/ai-agent/implementation.md`, `docs/VISION.md`,
  `family/README.md`, and contributor guidance to distinguish canonical
  co-location from external distributions. Keep the prohibition on shared
  runtimes, nested repositories, and sibling imports.

**Exit:** one documented owner and one reproducible export contract per
product. No automatic two-way synchronization.

### 2. Finish Forgejo as the reference distribution

- [ ] Add the exporter and product manifests in a dedicated build-time
  location such as `scripts/distribution/`, with hermetic tests under
  `tests/distribution/`. First capture the current stale-transformation
  failure as a regression fixture. The exporter accepts an immutable source
  revision, one product ID, and an empty output directory; it neither
  installs anything nor publishes to GitHub.
- [ ] Review the existing sync transformations and provenance checks.
  Retain validation both before and after export, source-SHA pinning,
  concurrency protection, and destination-owned workflow preservation.
- [ ] Keep the product at the destination repository root. Make `make lint`,
  `make test`, and `make package` work in a fresh clone and an extracted
  archive without an `ubuntu-zombie` checkout or an accidental parent
  `LICENSE`/`family` directory.
- [ ] Implement the fixed archive layout above. Extract a generated archive
  into an unrelated empty directory, validate its unchanged descriptor,
  run `describe --json`, lint and tests, then repackage from the extracted
  product directory. Test flat-checkout and nested-archive paths separately.
- [ ] Resolve product-only conformance tests without running tests that
  require missing siblings. Keep the cross-product suite here and package
  the applicable product-local contract checks with the distribution.
- [ ] Audit exported docs, tests, package allowlists, verifier commands,
  update URLs, workflow paths, badges, and relative links. Carry the
  minimum required pinned schema snapshot with its provenance.
- [ ] Document upstream contribution, sync failure recovery, and manual
  distribution refresh. A failed refresh must leave the last validated
  distribution intact and report failure.

#### Synchronization acceptance contract

Use destination-owned automation to pull approved source; it needs no
cross-repository write credential in the monorepo. Resolve a source revision
once, and use it for export, validation, provenance, and publication.
Validate untrusted changes in a read-only job. Publishing runs only for
approved trusted revisions with narrowly scoped destination permissions.
Any permission/ruleset changes require explicit maintainer approval.

Before updating generated paths, compare the destination against its last
recorded export, including content, executable modes, and symlink types.
Unexpected local edits, untracked ownership collisions, missing manifests,
or a changed target head stop publication for reconciliation. Remove only
paths previously owned by that manifest. Preserve destination workflows
and settings. Do not rebase a validated snapshot onto a new head and push
without rerunning validation.

Two exports of the same inputs must have identical path lists, file bytes,
modes, and tree digest. Normalize archive ordering, timestamps, numeric
ownership, and gzip metadata so official package digests are repeatable.
A no-op sync must not create a commit, bump `VERSION`, or publish a release.
If export changes alter released bytes, require a new product version even
when the runtime source did not change.

Keep scheduled sync as drift detection and manual dispatch as recovery;
expose a required export check on canonical product changes so breakage is
caught before the next weekly run. The destination may lag intentionally,
but its README/metadata must disclose the source revision and last
successful sync. Failed syncs must notify its named maintainer.

Do not assume a commit pushed with `GITHUB_TOKEN` triggers ordinary downstream
CI or release workflows. Explicitly run validation before publication and
invoke the approved release workflow for the exact resulting commit, or
require a maintainer dispatch. Test the actual trigger chain.

**Exit:** an independently cloned and packaged Forgejo distribution passes
its source gates. Keep its pre-alpha warning until deployment and release
gates actually pass.

### 3. Establish independent releases and explicit trust

- [ ] Choose exactly one authoritative release publisher for each product.
  For destination-owned releases, add product CI and release workflows
  there before retiring the corresponding monorepo publisher. Never reuse
  an existing tag for different bytes or silently relocate old releases.
- [ ] Record a cutover version per product. First ship any required old-
  origin client/verifier bridge, then build and verify an unpublished
  destination candidate, retire the old publisher for new versions, and
  publish the new-origin release with migration instructions. If a step
  fails, keep the old supported path; never silently downgrade or replace
  a published asset.
- [ ] Preserve product versions and tag namespaces initially. Generate
  checksums, SBOM, provenance, signatures, and honest test evidence from
  the exact exported tree; record both canonical and distribution commits.
- [ ] Pin the expected repository, tag, asset names, workflow identity, and
  digests in verification. A repository rename or workflow move changes
  the signing identity and needs an explicit trust migration.
- [ ] Reconcile Beep's discovery URL, release verifier, embedded family
  catalogue/manager, documentation, and publisher together. Do not solve
  the mismatch by accepting arbitrary repositories or signing identities.
- [ ] Test new clients against retained old releases and the new publisher.
  Old clients must either use their documented bridge/manual upgrade or
  report an unsupported origin clearly. No wildcard signing identities,
  target-selected trust roots, or automatic downgrade on verification
  failure.

**Exit:** a downloaded release verifies against its actual publisher.
Independent source availability need not wait for manager implementation;
catalogue admission still waits for all existing release gates.

### 4. Distribute the remaining implemented products

- [ ] Apply the reference process to Llama, Imaginary Friend, and Beep,
  using product-specific manifests rather than global text replacements.
  Reuse the proven sync pattern without introducing a shared runtime or
  a new generic installer framework.
- [ ] Begin with Llama's remaining parent-test/package dependencies. Then
  repeat the complete process for Friend and Beep; do not assume passing
  Forgejo export tests proves their different layouts and trust paths.
- [ ] Preserve Llama's loopback-only endpoint and verified model/runtime,
  Friend's narrower authority and private state, and Beep's policy,
  approval, audit, TTL, and explicit root-equivalent trust boundary.
- [ ] Give each destination independent CI, release documentation,
  contribution routing, support and private disclosure instructions.
  Ensure Beep receives ordinary CI coverage, not only release-time checks.
- [ ] Test each clone/archive outside the parent tree. Verify no installed
  command imports sibling code or requires a monorepo checkout.

**Exit:** each implemented product can be obtained, checked, packaged,
installed, and maintained from its own repository and verified artifacts.

### 5. Extract and distribute Forgejo Runner

- [ ] Complete roadmap phase 5: create its product descriptor, version,
  complete lifecycle, ownership marker, audit/receipt handling, package,
  tests, and documentation before exporting a Runner repository.
- [ ] Extend the product/installation/receipt contracts and conformance
  validators for the Runner's identity and dependency before publishing
  it. Existing product-ID enumerations do not yet contain the Runner.
- [ ] Declare Forgejo as an explicit dependency. A direct Runner operation
  must clearly reject a missing/unhealthy prerequisite; a manager resolves
  the dependency through Forgejo's own lifecycle, never copied server code.
- [ ] Specify supported Forgejo/Runner version pairs and operation order.
  Test healthy, absent, incompatible, suspended, and partially installed
  dependencies. A failed Runner install must not remove a pre-existing
  Forgejo server; report both products' resulting state and recovery path.
- [ ] Preserve restricted Docker execution, trusted-repository warnings,
  local name resolution, CA injection, and server/runner coordination.
- [ ] Replace root Runner mutation hooks with delegation only after legacy
  adoption, install order, independent updates, and removal gates pass.
  Reject server removal while its dependent runner remains installed.

**Exit:** neither the root installer nor the Forgejo server repository
contains a second Runner installer.

### 6. Preserve compatibility and separate test responsibilities

- [ ] Keep current verbs, targets, environment selectors, no-target
  defaults, and combined selections working. Friend and Beep do not become
  root targets merely because repositories exist.
- [ ] Initially keep the reviewed Forgejo/Llama snapshots in root tar and
  Debian packages so existing offline delegation does not regress.
  Independent repositories alone do not justify removing these files.
- [ ] If bundles later consume external releases, replace them with
  build-time verified, digest-pinned snapshots before deleting local
  sources. Document offline behavior; never fetch an unpinned `main` or
  `latest` script and execute it as root.
- [ ] Keep product tests with their canonical sources while mirroring
  equivalent checks to distribution CI. Retain black-box family and
  compatibility tests here; test released cross-repository combinations
  by pinned version rather than a moving branch.
- [ ] Update `Makefile`, `scripts/build-deb.sh`, root/product workflows,
  `tests/family/`, and package-content tests whenever their assumptions
  change. Do not remove their coverage simply to make extraction pass.
- [ ] Update operator docs and release notes for actual behavior changes,
  with corresponding `CHANGELOG.md` and UTC `VERSION` updates. Publish a
  deprecation window before any later removal of compatibility commands.

**Exit:** existing installs remain supported, while a product-only checkout
does not require Ubuntu Zombie to build or run.

### 7. Optional: admit external releases to family management

This is a separate milestone after direct release verification, not a
reason to delay usable standalone repositories.

- [ ] Introduce a versioned catalogue contract that separates catalogue
  ownership from each product's approved release repository and signing
  workflow. Keep `product_id`, version/tag, descriptor/archive path, exact
  asset names, and digests bound together.
- [ ] Update `family/schemas/`, strict conformance validators, fixtures,
  and Beep's embedded manager/catalogue together. Preserve exact HTTPS
  asset/redirect checks and duplicate/unknown-field rejection.
- [ ] Pin allowed product origins in reviewed manager trust configuration,
  not in a descriptor supplied by an untrusted target. Do not interpret
  Beep's own release repository as the origin of every managed product.
- [ ] Ship a bridge reader before offering a new catalogue version.
  Keep old clients on their supported catalogue until migrated. Test
  wrong-product assets, unknown origins/versions, altered descriptors,
  and signing identities from another workflow or repository.
- [ ] Admit entries only with verified releases and deployment evidence.
  Replace the permanent-empty-catalogue assertion in
  `tests/family/test_contract.py` with evidence-backed admission tests
  when the first entry is approved, not before.

**Exit:** managed installation selects exactly the same verified artifact
as direct installation and preserves product-owned policy, approval,
audit correlation, and recovery.

## Acceptance and rollout

### Reviewable delivery units

| Unit | Prerequisite | Deliverable and merge gate |
| --- | --- | --- |
| D0: baseline and decisions | None | Confirm ownership/names; triage the root test failure; approve the source/archive contract and record deployment gates still open. |
| D1: export contract | D0 | Layout-independent product build, exporter/manifests, regression and deterministic-export tests; no host changes. |
| D2: Forgejo distribution | D1 | Repair existing sync, validate an isolated clone/archive and publication race/no-op cases; destination-only files preserved. |
| D3: Forgejo release | D2 | Actual destination CI/trigger chain, verified candidate, publisher cutover, direct lifecycle and migration evidence. |
| D4: Llama, Friend, Beep | D2 for source; D3 for release pattern | Separate product changes repeat D1-D3; each has its own acceptance record and cutover. Source preparation need not wait for Forgejo VM evidence. |
| D5: Runner extraction | D0 | Product lifecycle, schema identity/dependency, legacy adoption and failure-isolation tests. May proceed independently of D1-D4. |
| D6: Runner distribution | D2, D5 for source; D3 for release pattern | Repeat distribution/release gates and prove compatibility with its supported Forgejo versions. |
| D7: compatibility completion | D4, D6 | Root source/tar/deb paths and all published standalone products pass the compatibility matrix. Compatibility tests run throughout, not only at this last gate. |
| M1: optional catalogue admission | Relevant product release; reviewed manager contract | Cross-origin trust migration and evidence-backed admission; no dependency from D1-D7 onto M1. |

Do not batch all products into one publication. A failed product stops its
own rollout; it does not require moving unrelated installed products.
Develop source/export changes while VM gates are open, but do not advertise
production readiness until the relevant evidence exists.

### Required compatibility matrix

| Surface | Cases that must pass |
| --- | --- |
| Source distribution | Canonical source, independent clone, nested extracted release, repackaging, unrelated working directory, absent parent checkout. |
| Existing automation | No-target defaults; explicit/combined targets; `ZOMBIE_INSTALL_*` selectors; `ZOMBIE_NONINTERACTIVE=1`; missing required input exits `64`; target-specific help and dry-run. |
| Root packaging | Source tar and `.deb` retain delegating products and required support files; no new network fetch merely to locate a lifecycle script. External install dependencies still follow each product's documented network requirements. |
| Machine lifecycle | Fresh, repeated, supported legacy, partial/foreign ownership, upgrade, failure, rollback, repair, suspend/resume where supported, retained-state removal and explicit purge. |
| Co-installation | Zombie with each product; Forgejo with Runner; Friend/Beep with a pinned local model service; root-capable peers treated as mutually trusted, not isolated from root. |
| Publishing | Repeated identical sync, source drift, destination conflict, concurrent head movement, failed export, wrong tag/version, wrong signing origin, corrupt artifact, missing evidence. |

### Acceptance record

Keep one machine-readable record per candidate release as a CI/release
artifact, referenced from its release notes. Record product/version,
canonical commit, exporter/manifest revision, destination commit, exported
tree digest, archive digest/layout, schema versions, signing identity,
supported OS/Python matrix, test outcomes, evidence locations, and the
maintainer's approval. Use `passed`, `failed`, or `not_run`; a missing VM
run must never become `passed` because the source tests passed.

The record must cover every applicable matrix case on supported Ubuntu
Desktop 22.04/24.04 and Python 3.10/3.12. Also retain negative archive
traversal/schema tests and secret-redaction results. Co-installation evidence
must show that selective operations leave sibling secrets, state, services,
and ports unchanged, not merely that the selected product reports success.

Run normal `make lint` and `make test` without mutating the development
host. Run actual installation and lifecycle mutation only on disposable
supported VMs. A successful sync or source release is not VM evidence.

Keep the last verified source, artifact, and trust metadata available during
rollout. On a failed gate, stop that product's publication/admission, retain
the working compatibility path, and fix upstream; do not weaken validators
or reset installed state.

**Distribution milestone:** every in-scope implemented product has a usable
repository, deterministic independent build, clear contribution routing,
working sync, and preserved root compatibility. Pre-alpha restrictions remain
where deployment gates are open.

**Release milestone:** each product also has one authoritative publisher,
verified artifacts and migration path, complete deployment evidence, and
an approved acceptance record. Optional manager integration is tracked
separately. Merely copying `products/<id>` into another repository completes
neither milestone.
