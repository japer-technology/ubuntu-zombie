# Forgejo install

How `scripts/install.sh` installs, updates, verifies, and repairs the
optional [Forgejo](https://forgejo.org/) component: a self-hosted git
forge backed by PostgreSQL, published to the LAN over HTTPS by Caddy
and discovered via Avahi mDNS, with an optional co-located Forgejo
Actions runner.

This page documents the install path in depth. For the full variable
reference and post-install tuning see `docs/CONFIGURATION.md`
("Forgejo server"); for the overall system design see
`docs/ARCHITECTURE.md`.

> **Warning** — run the installer only on a disposable Ubuntu Desktop
> LTS machine (or VM) you are prepared to wipe. It creates users,
> installs packages, and enables system services.

## The shape of the result

```text
LAN client ── https://<hostname>.local/ (443, Caddy internal CA)
                     │
                Caddy reverse proxy          Avahi mDNS advertisement
                     │
             127.0.0.1:3000  Forgejo (loopback-only backend)
                     │
             127.0.0.1:5432  PostgreSQL
                     │ (optional)
             forgejo-runner ── Docker executor (loopback registration)
```

- **Forgejo binds only to loopback** (`HTTP_ADDR = 127.0.0.1`, port
  `FORGEJO_HTTP_PORT`, default `3000`). It is never directly exposed.
- **Caddy is the LAN edge** on HTTPS port `443`. It terminates TLS
  with its internal certificate authority and reverse-proxies to the
  loopback backend.
- **Avahi advertises** the machine as `https://<hostname>.local/`
  (`_https._tcp` on port 443), so LAN clients find the forge without
  DNS configuration.
- **Registration is disabled** (`DISABLE_REGISTRATION = true`); the
  admin creates further accounts. Forgejo Actions is enabled.

## Ways to run the install

```bash
# Standalone: Forgejo + PostgreSQL, no zombie account or runtime
sudo ./scripts/install.sh install forgejo

# Combined with the zombie baseline
sudo ./scripts/install.sh install zombie forgejo

# Legacy flag form (equivalent to `install zombie forgejo`)
sudo ZOMBIE_INSTALL_FORGEJO=1 ./scripts/install.sh install

# With a co-located Actions runner
sudo ZOMBIE_INSTALL_FORGEJO=1 ZOMBIE_INSTALL_FORGEJO_RUNNER=1 \
  ./scripts/install.sh install

# Preview without touching the host (no root required)
sudo ./scripts/install.sh install forgejo --dry-run
```

Component target order does not matter; `install forgejo zombie` and
`install zombie forgejo` converge on the same result. The runner
requires the server (`ZOMBIE_INSTALL_FORGEJO_RUNNER=1` only makes
sense together with the Forgejo component).

### Interactive review

Unless the run is non-interactive (`ZOMBIE_NONINTERACTIVE=1`),
`--yes`, or stdin is not a TTY, the installer shows a "Forgejo —
setup parameters" review page before changing anything. Every
decision is editable there: the loopback port, admin account
(username, email, password), PostgreSQL database (name, role,
password), the Actions-runner toggle, version pins, and the
transcript/receipt destinations. Accepting re-validates the
configuration and proceeds.

### Configuration parameters

All parameters are environment variables with safe defaults; the full
table (defaults, formats, and constraints) lives in
`docs/CONFIGURATION.md`. The frequently used ones:

| Variable                         | Default        | Purpose |
| -------------------------------- | -------------- | ------- |
| `FORGEJO_HTTP_PORT`              | `3000`         | Loopback backend port behind Caddy. |
| `FORGEJO_ADMIN_USER`             | `forgejo-admin`| Initial admin account. |
| `FORGEJO_ADMIN_PASSWORD`         | *(generated)*  | Admin password; empty means generate. |
| `FORGEJO_DB_NAME` / `FORGEJO_DB_USER` | `forgejo` | PostgreSQL database and role. |
| `FORGEJO_DB_PASSWORD`            | *(generated)*  | Role password; empty means generate. |
| `FORGEJO_VERSION`                | *(latest)*     | Pin a Forgejo release, e.g. `11.0.3`. |
| `FORGEJO_RUNNER_VERSION`         | *(latest)*     | Pin a runner release. |
| `FORGEJO_RUNNER_LABELS`          | `ubuntu-latest:docker://node:20-bookworm` | Runner labels. |

Every value is validated before any host mutation: identifiers must be
conservative lowercase names (they are interpolated into `psql` and
CLI invocations), passwords must be 8–256 printable characters, and
version pins must be semver-like. Invalid input exits `2`.

## What the installer does, step by step

The Forgejo component runs as numbered phases inside the shared
install flow (preflight, transcript log, receipt, manifest). Every
phase is idempotent: it checks current state first and reports each
step as *satisfied* (already correct) or *applied* (changed this run).

### 1. Install prerequisites

Installs `git`, `git-lfs`, `postgresql`, `postgresql-contrib`,
`openssl`, `xz-utils`, `caddy`, `avahi-daemon`, and `libnss-mdns`.
Before installing Caddy it configures Caddy's official signed stable
APT repository (keyring at
`/usr/share/keyrings/caddy-stable-archive-keyring.gpg`, source at
`/etc/apt/sources.list.d/caddy-stable.list`), so no manual repository
setup is needed.

### 2. Create the `git` system user

Creates the `git` system account (home `/var/lib/forgejo`, shell
`/bin/bash`) if it does not already exist. Forgejo runs as this user.

### 3. Download and install the Forgejo binary

- Only `amd64` and `arm64` hosts are supported; anything else exits
  `65`.
- With `FORGEJO_VERSION` set, that release is used as-is. Otherwise
  the latest release tag is resolved from the release-metadata origins
  in order: `data.forgejo.org`, then `code.forgejo.org`, then
  `codeberg.org` as a legacy fallback. Resolution failure exits `66`
  (pin `FORGEJO_VERSION` to proceed offline from metadata).
- If `/usr/local/bin/forgejo` already reports the resolved version,
  the download is skipped entirely.
- Otherwise the release asset is downloaded from `code.forgejo.org`
  (falling back to `codeberg.org`) and its published `.sha256`
  checksum from the same origin is verified before the binary is
  installed to `/usr/local/bin/forgejo` (mode `0755`, `root:root`).

### 4. Create directories

`/var/lib/forgejo` (`750`, `git:git`) for repositories, LFS objects,
and state; `/etc/forgejo` (`750`, `root:git`) for configuration.

### 5. Configure PostgreSQL

Enables and starts `postgresql`, then creates (or re-asserts) the
Forgejo role and database. Password precedence:

1. An operator-supplied `FORGEJO_DB_PASSWORD` always wins.
2. Otherwise the password already recorded in
   `/etc/forgejo/app.ini` is reused, so re-runs never desynchronise
   the credential.
3. Otherwise a random password is generated exactly once and recorded
   in the install receipt.

If a matching role **or** database already exists, the installer warns
that the state will be reused (never dropped) and demands an exact,
capitalized `YES` — interactively, or via
`FORGEJO_CONFIRM_DATABASE_REUSE=YES` for unattended runs. `--yes` does
not bypass this data-safety gate.

### 6. Write `/etc/forgejo/app.ini`

An existing Forgejo service is stopped first so it cannot race the
configuration rewrite or the database migration. The installer then
renders `app.ini` with:

- `DB_TYPE = postgres` on `127.0.0.1:5432` with the resolved
  credentials;
- a loopback-only `[server]` section (`HTTP_ADDR = 127.0.0.1`,
  `DOMAIN`/`ROOT_URL` set to `https://<hostname>.local/`), with git
  LFS enabled;
- `INSTALL_LOCK = true`, `DISABLE_REGISTRATION = true`, and
  `[actions] ENABLED = true`.

Secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`,
`LFS_JWT_SECRET`) are **reused from an existing `app.ini`** so re-runs
never rotate them behind a running service; missing or malformed ones
are generated once via `forgejo generate secret`. They live only in
`app.ini` (mode `640`, owner `root:git`) and are never logged or
written to the receipt.

### 7. Migrate the database and create the admin

- Installs `payload/systemd/forgejo.service` and reloads systemd.
- Runs the one-shot `forgejo migrate` as the `git` user. Because
  Forgejo may persist newly introduced settings during migration, the
  installer temporarily sets `app.ini` to mode `660`, then restores
  `root:git` `750`/`640` on the directory/file **even if migration
  fails** — the running daemon can never rewrite its own config.
- Creates the initial admin account unless it already exists. A
  generated admin password gets `--must-change-password` (forced
  change on first sign-in); an operator-chosen one is taken as
  deliberate and kept. If the admin already exists, any supplied
  `FORGEJO_ADMIN_PASSWORD` is ignored and reported as such.
- Enables and starts `forgejo.service`, then probes
  `http://127.0.0.1:<port>/api/healthz` with backoff (six attempts).
  If the service never becomes healthy it is stopped and disabled
  again and the install fails, pointing at `journalctl -u forgejo`.

### 8. Configure LAN HTTPS and mDNS

- Rewrites the managed Forgejo block in `/etc/caddy/Caddyfile`,
  delimited by `# BEGIN install.sh Forgejo` / `# END install.sh
  Forgejo`, containing exactly one `https://<hostname>.local` site
  with `tls internal` and `reverse_proxy 127.0.0.1:<port>`. Unrelated
  Caddy sites are preserved; a stock packaged Caddyfile is replaced;
  an *incomplete* managed block (mismatched markers) aborts with
  instructions rather than guessing. The legacy
  `/etc/caddy/conf.d/forgejo.caddy` fragment is removed.
- Validates the Caddyfile with `caddy validate` before activating it.
- Writes `/etc/avahi/services/forgejo.service` advertising
  `_https._tcp` on port 443 and starts `avahi-daemon`.
- Restarts Forgejo to apply the public URL, reloads Caddy, exports
  Caddy's public local-CA root to `/etc/forgejo/caddy-local-ca.crt`,
  and finally proves the full HTTPS path end to end by requesting
  `https://<hostname>.local/api/healthz` against that CA.

Clients must trust the exported CA once; see "Trust the Forgejo local
certificate authority" in `docs/CONFIGURATION.md`.

### 9. Optional: Actions runner

Only with `ZOMBIE_INSTALL_FORGEJO_RUNNER=1` (co-locating the runner
with the forge is contrary to upstream guidance and is called out as a
deliberate choice):

- **Docker:** an existing `/usr/bin/docker` is reused. If Docker is
  absent but `containerd.io` is installed, the installer refuses to
  install `docker.io` (which would replace packages) and fails with
  instructions. Otherwise `docker.io` is installed and enabled.
- Creates the `forgejo-runner` system user (member of the `docker`
  group, home `/var/lib/forgejo-runner`, mode `750`).
- Resolves and downloads `forgejo-runner` exactly like the server
  binary (pin with `FORGEJO_RUNNER_VERSION`; checksum-verified) to
  `/usr/local/bin/forgejo-runner`.
- Registers once: if `/var/lib/forgejo-runner/.runner` exists,
  registration is skipped; otherwise a registration token is generated
  with `forgejo actions generate-runner-token` and the runner is
  registered non-interactively against
  `http://127.0.0.1:<port>/` with `FORGEJO_RUNNER_LABELS` (default
  maps `ubuntu-latest` jobs to `docker://node:20-bookworm`).
- Installs and enables `forgejo-runner.service`.

## Non-interactive installs and receipts

`ZOMBIE_NONINTERACTIVE=1` skips the review page and all prompts, but
the data-safety gates still apply:

```bash
sudo ZOMBIE_NONINTERACTIVE=1 \
     FORGEJO_CONFIRM_UPDATE=YES \
     FORGEJO_CONFIRM_DATABASE_REUSE=YES \
     ./scripts/install.sh install forgejo --yes
```

Generated passwords are disclosed **only** in the root-only install
receipt (mode `600`, default
`/var/log/ubuntu-zombie/install-receipt.txt`, overridable with
`ZOMBIE_RECEIPT_FILE`).
Because of that, password generation requires the receipt: if
`ZOMBIE_RECEIPT=0` you must supply both `FORGEJO_ADMIN_PASSWORD` and
`FORGEJO_DB_PASSWORD`, otherwise the install exits `64` before
touching the host. Operator-supplied or reused passwords are never
recorded anywhere.

The receipt's start record captures every Forgejo parameter (URL,
backend port, admin, database, version, runner state); the finish
record adds the resolved version, service state, and any passwords
generated this run.

## Updates and re-runs (idempotence)

Re-running `install forgejo` converges the host without breaking an
existing installation:

- If any Forgejo footprint is detected (service unit, `/etc/forgejo`,
  binary, data directories, runner, or a component manifest), the
  installer warns that it will **update in place, preserving
  repositories and database data**, and requires a capitalized `YES`
  (`FORGEJO_CONFIRM_UPDATE=YES` unattended).
- Binary downloads are skipped when the installed version matches.
- Secrets and the database password are reused from `app.ini`.
- The database and role are reused, never dropped; runner
  registration is not repeated.
- The managed Caddy block and Avahi service file are rewritten only
  when their content differs.

To upgrade to the latest release, simply re-run the install; to move
to a specific release, set `FORGEJO_VERSION`. The service is stopped
before migration and health-checked after.

## Files and services installed

| Path | Purpose |
| ---- | ------- |
| `/usr/local/bin/forgejo` | Forgejo binary (checksum-verified). |
| `/etc/forgejo/app.ini` | Configuration + secrets (`root:git`, `640`). |
| `/etc/forgejo/caddy-local-ca.crt` | Exported public Caddy CA root. |
| `/var/lib/forgejo/` | Repositories, LFS, state (`git:git`, `750`). |
| `/etc/systemd/system/forgejo.service` | Forgejo unit (from `payload/systemd/`). |
| `/etc/caddy/Caddyfile` | Contains the marked, managed Forgejo block. |
| `/etc/avahi/services/forgejo.service` | mDNS `_https._tcp` advertisement. |
| `/usr/local/bin/forgejo-runner` | Runner binary (optional). |
| `/var/lib/forgejo-runner/` | Runner home + `.runner` registration. |
| `/etc/systemd/system/forgejo-runner.service` | Runner unit (optional). |

## Verify, doctor, repair, uninstall

All lifecycle subcommands accept the `forgejo` target:

```bash
sudo ./scripts/install.sh verify forgejo    # pass/fail health checks
sudo ./scripts/install.sh doctor forgejo    # diagnosis with fix hints
sudo ./scripts/install.sh repair forgejo    # re-assert perms/services
sudo ./scripts/install.sh uninstall forgejo --dry-run
```

`verify forgejo` checks the binary, unit, service and PostgreSQL
state, the `root:git` `750`/`640` config permissions, the
loopback-only bind and HTTPS `ROOT_URL`, the managed Caddy route
(exactly one marked block with the right host, port, and internal
TLS), Caddyfile validity, absence of the legacy fragment, Avahi, the
exported CA (present *and* matching Caddy's active root), both the
loopback and HTTPS `/api/healthz` endpoints, and the runner service
when installed. `--json` emits machine-readable results.

`repair forgejo` re-asserts ownership and permissions on
`/etc/forgejo`, `app.ini`, and `/var/lib/forgejo`, restarts the
services, regenerates the managed Caddy/Avahi configuration (including
migrating the legacy `conf.d/forgejo.caddy` fragment), and re-exports
the CA.

Uninstalling removes the services, binaries, managed Caddy block,
Avahi advertisement, and `/etc/forgejo`, then asks separately before
removing `/var/lib/forgejo` (all repositories and LFS data), before
dropping the PostgreSQL database and role, and before deleting the
`git` and `forgejo-runner` system users. The shared `caddy`,
`avahi-daemon`, and `libnss-mdns` packages stay installed. Remember to
remove the trusted CA root from clients when the host is retired.

## Exit codes

| Code | Meaning |
| ---- | ------- |
| `2`  | Invalid parameter value (validation failure). |
| `64` | Missing required input, e.g. password generation without a receipt, or a missing `YES` confirmation in non-interactive mode. |
| `65` | Unsupported CPU architecture (not amd64/arm64). |
| `66` | Could not resolve or download a release. |

## Troubleshooting

- **Forgejo won't start:** `journalctl -u forgejo`; common causes are
  a port already in use, database authentication, or a failed
  migration. `sudo ./scripts/install.sh doctor forgejo` narrows it
  down.
- **Browser certificate warning:** the client has not imported
  `/etc/forgejo/caddy-local-ca.crt` yet — see
  `docs/CONFIGURATION.md`.
- **`.local` name not resolving:** the client needs mDNS support and
  must be on the same link; check `avahi-daemon` on the host.
- **Release resolution fails:** pin `FORGEJO_VERSION` /
  `FORGEJO_RUNNER_VERSION` and re-run.
- **Runner refuses to install Docker:** `containerd.io` is present;
  install a compatible Docker Engine yourself or remove
  `containerd.io`, then re-run.
