# Installation and lifecycle

## Before installation

Use only a disposable Ubuntu Desktop 22.04 or 24.04 LTS `amd64` VM until the
recorded host gates in [`TESTING.md`](TESTING.md) pass. Beep creates a
root-capable identity, sudoers entry, system packages, Node runtime, systemd
units, configuration, state, and logs.

For a published release:

1. download every Beep release asset into one new directory;
2. install `sha256sum`, `cosign`, and the GitHub CLI;
3. run `beep-verify-release <directory>`;
4. inspect the verified changelog, SBOM, test evidence, and open VM fields; and
5. extract the verified `beep-<VERSION>.tar.gz`.

A source checkout is for reviewed development on a disposable VM only.

## Interactive installation

From the extracted product directory, run:

```bash
./scripts/install.sh
```

The installer obtains root privileges when needed. It asks for the loopback
chat port, provider and model settings, and initial time to live. Every optional
question has a secure default. It then displays the complete lifecycle plan and
asks for approval before changing the host.

After approval, enter and confirm the chat password. If a cloud provider was
selected, enter its credential at the protected prompt. Neither secret is
printed or included in lifecycle output. When installation completes, verify
the result:

```bash
sudo beep-manage verify
```

## Unattended plan

Create a root-owned mode-`0600` password file containing one line, then inspect
the non-mutating unattended plan:

```bash
sudo env \
  BEEP_NONINTERACTIVE=1 \
  BEEP_ADMIN_PASSWORD_FILE=/root/beep-password \
  products/beep/scripts/manage.sh install --dry-run --json
```

A blocked plan lists required inputs and exits `64`. It must not create locks,
directories, credentials, downloads, logs, or network traffic.

## Unattended installation

After reviewing the plan:

```bash
sudo env \
  BEEP_NONINTERACTIVE=1 \
  BEEP_ADMIN_PASSWORD_FILE=/root/beep-password \
  products/beep/scripts/manage.sh install --yes --json
```

Add `BEEP_PROVIDER`, `BEEP_PROVIDER_CREDENTIAL_FILE`, `BEEP_MODEL`, or
`BEEP_MODEL_BASE_URL` only as described in
[`CONFIGURATION.md`](CONFIGURATION.md). Remove plaintext input files after
successful installation.

The manager refuses a pre-existing unowned `beep` user, group, path, unit,
command, port, regular-file collision, or dangling link. Re-running install
converges the same owned installation and preserves credentials, policy,
history, suspension, instance identity, and any death tombstone.

Before the first host mutation, Beep writes a root-owned pending-install
journal beside its state root. If a dependency download, apt lock, service
start, or health check fails, Beep stops only units whose exact shipped bytes
prove they belong to that attempt. Correct the reported cause and rerun the
same install command; the manager validates every recorded resource before
adopting the partial installation.

Node, npm, and the complete transitive bridge graph are version-and-integrity
locked. Installation uses bounded retries, waits for apt locks, disables npm
scripts and generated command links, and verifies both Node and npm before the
runtime is accepted. Installation succeeds only after the chat service and
health timer are both active and enabled. Standard Node/npm links and Python's
Linux `lib64` link are converted to validated regular launchers or removed,
leaving snapshots, backup, rollback, repair, and uninstall with one
symlink-free tree invariant.

## Verify and diagnose

```bash
sudo beep-manage status --json
sudo beep-manage verify --json
sudo beep-manage doctor --json
beep-health
beep-diagnostics
```

`verify` exits non-zero on boundary drift. `doctor` reports the diagnosis
without claiming repair. `repair` first snapshots an installed product,
reasserts only Beep-owned state, restores a malformed policy to the shipped
safe policy, and automatically rolls back product state if convergence fails.

## Suspend, resume, and kill

```bash
sudo beep-manage suspend --yes --json
sudo beep-manage resume --yes --json
sudo beep-manage kill --yes --json
```

Suspend is reversible after verification. Kill is not: it writes permanent
death, cancels useful work, revokes sessions, and stops Beep units. Resume and
reinstall reject death.

## Uninstall

Normal removal retains Beep configuration, history, lifecycle, recovery, and
instance identity:

```bash
sudo beep-manage uninstall --yes --json
```

Complete product-state deletion is explicit:

```bash
sudo beep-manage uninstall --purge \
  --confirmation 'DELETE BEEP STATE' --yes --json
```

The manager removes only resources proved by Beep's marker and fixed
descriptor. Purge writes a non-success `purge_started` record before deleting
local receipts, logs, account, and group, then writes `purge_completed` only
after each removal verifies. Before deletion begins it also writes the
root-owned `/var/lib/beep.purging.json` tombstone, bound to the installation
instance and exact account/group IDs. If power or storage failure interrupts
purge, rerun the same command from verified Beep source; the tombstone permits
only that purge to resume and is removed after completion evidence is durable.
Use that source tree's `scripts/manage.sh` if the installed entrypoint was
already removed.
Operator-created backups and exports are not removed.

## Stable exits

`64` means required input or confirmation, `65` invalid data, `66` missing
source or installation, `69` unsupported host/dependency, `73` unsafe
ownership/path/collision, `75` busy or transient download, `78` integrity or
plan mismatch, and `1` an executed operation or recovery failed.
