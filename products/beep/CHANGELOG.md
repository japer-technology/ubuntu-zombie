# Beep changelog

Beep uses independent UTC date-time versions in `yyyy.mm.dd.hh.nn.ss` format.

## [Unreleased]

### Added

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

### Fixed

- Preserve executable modes for the pinned Node runtime and copied lifecycle
  commands.
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
