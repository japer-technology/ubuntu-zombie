# Imaginary Friend changelog

Imaginary Friend uses independent UTC date-time versions in
`yyyy.mm.dd.hh.nn.ss` format.

## [Unreleased]

### Fixed

- Preserve suspension across reinstall and update, recompute existing history
  expiry when its retention window changes, reject lifecycle inputs that the
  selected operation cannot apply, and retain correlation in unexpected
  failure responses and audit events.
- Require the `friend` service identity to have only its product groups and
  verify that a suspended service is stopped.

### Added

- Initial standalone implementation with one owner, authenticated local chat,
  bounded workspaces, retention and export, local-model access, and the full
  product-owned lifecycle interface.
- Independent policy, audit, credentials, systemd confinement, packaging,
  tests, and operator documentation.
- Product-owned vision, architecture, security, privacy, configuration,
  installation, upgrading, recovery, troubleshooting, release, and test
  evidence, with an explicit record of remaining family admission gates.
- Regression and negative-boundary coverage for suspension convergence,
  retention changes, service groups, lifecycle input isolation, failure
  correlation, sandbox assets, and the guarded disposable-VM lifecycle.
