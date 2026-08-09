# Beep

Beep is an independent, private, root-capable AI Systems Administrator for
Ubuntu Desktop LTS. It duplicates Ubuntu Zombie's administration behaviour
under a separate `beep` identity, port, credentials, policy, history, audit,
lifecycle, package, and release. It never imports or operates from Ubuntu
Zombie's installed runtime or state.

The standalone source, lifecycle, family manager, tests, package, and release
workflow are implemented. Beep is not yet admitted to the production family
catalogue: recorded supported-VM, root-peer co-installation, external security
review, and published release-verification evidence remain release gates.

## Root-equivalent warning

The installer creates a password-disabled `beep` account with passwordless
`sudo`. A compromised model, chat service, credential, policy, dependency, or
approved command can compromise the entire host. Installing both Beep and
Ubuntu Zombie creates two root-capable attack surfaces; it does not create
redundancy or containment.

Run installation and lifecycle tests only on a disposable supported Ubuntu
Desktop 22.04 or 24.04 LTS `amd64` VM that you are prepared to rebuild.

## Documentation

- [`docs/VISION.md`](docs/VISION.md) — purpose, parity, users, and non-goals.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, data flow, and
  trust boundaries.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model, controls, residual
  root-equivalent risk, and reporting.
- [`docs/PRIVACY.md`](docs/PRIVACY.md) — local and provider data, retention,
  export, and deletion.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — policy, tools, approvals, audit,
  TTL, reactivation, and family management.
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) — lifecycle inputs,
  providers, credentials, and runtime configuration.
- [`docs/INSTALLATION.md`](docs/INSTALLATION.md) — release verification,
  install, verify, suspend, kill, and removal.
- [`docs/UPGRADING.md`](docs/UPGRADING.md) — backup, update, automatic recovery,
  and rollback.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) — failure states and bounded recovery.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — diagnostics and stable
  lifecycle failures.
- [`docs/TESTING.md`](docs/TESTING.md) — automated evidence and open VM gates.
- [`docs/RELEASE.md`](docs/RELEASE.md) — independent artifacts, signatures,
  provenance, and verification.

The normative product contract is
[`docs/ai-agent/beep.md`](../../docs/ai-agent/beep.md). The shared lifecycle
contract is
[`docs/ai-agent/implementation.md`](../../docs/ai-agent/implementation.md).

## Development

From the repository root:

```bash
make -C products/beep lint
make -C products/beep test
make -C products/beep package
```

These commands do not install Beep. Do not run `scripts/manage.sh install` or
the guarded VM harness on a workstation or agent environment.
