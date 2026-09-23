# Beep

Beep installs a private, root-capable AI Systems Administrator on Ubuntu
Desktop LTS. Run the installer, answer the questions, and use the local chat.
Beep owns its account, credentials, policy, history, audit, and lifecycle; no
other product needs to be installed.

## Install

Use a disposable Ubuntu Desktop 22.04 or 24.04 LTS `amd64` VM until the
release gates below are complete. From this directory (or the extracted
release's `products/beep` directory), run:

```bash
./scripts/install.sh
```

The installer obtains root privileges with `sudo` when needed, asks the setup
questions, displays the complete plan, and applies it only after approval.
Press Enter to accept secure defaults. The chat password and any provider
credential are entered through protected prompts and are never printed.

You will choose the chat port, model provider, any required model settings,
and time to live. Cloud providers need an API key; LM Studio needs an existing
model server. The default provider, `none`, installs Beep without AI responses.
The default seven-day time to live stops Beep when it expires.

On success, the installer prints your local chat URL and verification commands.
Open that URL on the installed computer and sign in with the Beep chat password
you chose, not your Linux password. No environment variables or request files
are needed for interactive setup.

## Manage

After installation:

```bash
sudo beep-manage verify
sudo beep-manage doctor
sudo beep-manage suspend
sudo beep-manage resume
sudo beep-manage uninstall
```

Mutating commands ask for approval. Uninstall retains configuration and data
by default. See [`docs/INSTALLATION.md`](docs/INSTALLATION.md) for unattended
installation, backup, recovery, and explicit permanent deletion.

## Root-equivalent warning

The installer creates a password-disabled `beep` account with passwordless
`sudo`. A compromised model, chat service, credential, policy, dependency, or
approved command can compromise the entire host. Installing Beep alongside
another root-capable service increases the host's attack surface; it does not
create redundancy or containment.

Run installation and lifecycle tests only on a disposable supported Ubuntu
Desktop 22.04 or 24.04 LTS `amd64` VM that you are prepared to rebuild.

Recorded supported-VM, root-peer co-installation, external security review,
and published release-verification evidence remain release gates. Beep is not
yet admitted to the production family catalogue.

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

## Development

From the repository root:

```bash
make -C products/beep lint
make -C products/beep test
make -C products/beep package
```

These commands do not install Beep. Do not run `scripts/install.sh`,
`scripts/manage.sh install`, or the guarded VM harness on a workstation or
agent environment.
