# Beep changelog

Beep uses independent UTC date-time versions in `yyyy.mm.dd.hh.nn.ss` format.

## [Unreleased]

### Added

- Primary interactive installer that obtains root privileges, validates setup
  answers, shows the complete plan, and securely prompts for credentials after
  approval while preserving unattended lifecycle operation.
- Standalone root-capable Beep runtime with authenticated loopback chat,
  provider adapters, closed tools, policy approvals, audit, conversation
  history, TTL, reactivation, diagnostics, and family management.
- Independent lifecycle operations for describe, status, install, verify,
  doctor, repair, backup, update, rollback, suspend, resume, terminal kill, and
  uninstall.
- Product-owned package, release workflow, checksums, SPDX SBOM, provenance,
  cosign signatures, source record, operator documentation, parity fixture, and
  guarded disposable-VM harness.
- Authenticated conversation export and confirmation-bound deletion.

### Changed

- Remove inherited product branding and external schema packaging so Beep
  source, runtime metadata, documentation, tests, and release archives are
  standalone.
- Use the Beep release repository consistently for version discovery, family
  catalogue validation, provenance, and signature verification.
- Generalise backup boundary checks to protect every system configuration,
  application, state, and log root without naming another product.
- Keep `/var/lib/beep` lifecycle control and `/var/log/beep` management
  evidence parents root-owned while limiting `beep` write access to explicit
  runtime and audit files.

### Fixed

- Convert validated Node/npm launch links to regular launchers, disable npm
  `bin` links, and remove Python venv's standard Linux `lib64` link so install,
  backup, recovery snapshots, rollback, repair, and uninstall keep uniformly
  symlink-free managed trees.
- Pin and validate the complete transitive npm graph, disable dependency
  scripts, verify Node and npm before activation, preserve proxy/private-CA
  settings, and add bounded download, command, and apt-lock retries.
- Make failed first installs safely rerunnable with a root-owned provenance
  journal, provenance-checked partial-resource adoption, verified service
  activation, and owned-service cleanup without stopping unrelated same-name
  units.
- Snapshot the account home and exact service state, stop the running health
  oneshot, reject reused recovery IDs, and validate rollback destinations
  before mutation. Stage rollback targets on their destination filesystems and
  reverse completed swaps if application or ownership restoration fails.
- Preflight every uninstall target and management-evidence path before removal;
  distinguish purge-started from verified purge-completed journal evidence,
  and make interrupted purges safely resumable with exact identity provenance.
- Bind approval to source and artifact revisions, deploy from a trusted source
  snapshot, hash exclusions relative to the source root, and recheck protected
  input fingerprints immediately before use.
- Bind source and installed management wrappers deterministically, scrub the
  sudo environment, and reject source links or special files before Python
  import.
- Preserve executable modes for the pinned Node runtime and copied lifecycle
  commands, and enforce Unix line endings for every shipped shell entrypoint.
- Return exit `64` for unattended plans blocked on required input and reject
  raw secret environment values with a specific bounded error.
- Fail closed on absent, corrupt, non-finite, or unsafe lifecycle state; keep
  death durable across reinstall; stop useful work on death; and reject resume.
- Detect independent group, dangling-link, non-directory, destination-link,
  policy, ownership, mode, runtime, and deployed-tree drift.
- Restrict family planning to executable target mutations and record correlated
  manager-side failure evidence when target outcome verification fails.
- Bound and strictly decode JSON requests, pin loopback Host and mutation
  Origin, reject unknown or malformed fields, prune session state, and use the
  authoritative repository for release checks.
- Restore the pre-operation recovery snapshot automatically when an existing
  install, repair, or update fails.

### Security

- Validate policy syntax and classes, treat unknown policy classes as
  destructive, enforce protected lifecycle state writes, and bind the health
  timer to the chat service's terminal lifecycle.
