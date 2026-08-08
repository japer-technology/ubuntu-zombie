# Imaginary Friend

Imaginary Friend is a private, single-owner conversational companion with
access only to its own state and explicitly nominated workspaces. It is an
independent product: it does not import Ubuntu Zombie, share its credentials,
or inherit its root authority.

The standalone source and independent release machinery are implemented.
Admission to Ubuntu Zombie's production family catalogue remains gated on the
manager, disposable-VM, co-installation, and release-verification evidence
described in the
[product definition](../../docs/ai-agent/imaginary-friend.md).

## Safety first

The lifecycle installer creates users, groups, systemd units, protected state,
and workspace permissions. Test installation only on a disposable supported
Ubuntu Desktop LTS VM. Do not run it on an agent host or workstation you are
not prepared to rebuild.

Friend is not a system administrator, shell, coding sandbox, network agent, or
security boundary against root. A same-host machine administrator, including
Ubuntu Zombie, can inspect its unencrypted local state.

## Documentation

- [`docs/VISION.md`](docs/VISION.md) — purpose, users, and excluded uses.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components and trust
  boundaries.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, controls, residual
  risks, and disclosure.
- [`docs/PRIVACY.md`](docs/PRIVACY.md) — data, provider disclosure, retention,
  export, and deletion.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) — install inputs, runtime
  settings, authentication, and HTTP interfaces.
- [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — install, verify, repair,
  suspend, and removal.
- [`docs/UPGRADING.md`](docs/UPGRADING.md) — backup, update, and rollback.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) — drift, account recovery, and retained
  state.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — diagnostics and stable
  lifecycle failures.
- [`docs/RELEASE.md`](docs/RELEASE.md) — product versions, artifacts, SBOM,
  provenance, and signatures.
- [`docs/TESTING.md`](docs/TESTING.md) — test suites, red-team coverage, and
  open family gates.

The normative first-release behavior remains in
[`docs/ai-agent/imaginary-friend.md`](../../docs/ai-agent/imaginary-friend.md);
the shared machine-readable lifecycle contract is
[`docs/ai-agent/implementation.md`](../../docs/ai-agent/implementation.md).

## Development

From the repository root:

```bash
make -C products/imaginary-friend lint
make -C products/imaginary-friend test
make -C products/imaginary-friend package
```

These commands do not install the product. Root lifecycle testing is guarded
and belongs only on a disposable VM; see
[`docs/TESTING.md`](docs/TESTING.md).
