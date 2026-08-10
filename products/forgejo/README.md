# Forgejo

This directory is the independently versioned Forgejo infrastructure product.
It owns the private Forgejo server, PostgreSQL role and database, Caddy route,
local CA export, host trust, Avahi advertisement, and `forgejo.service`.

The Actions runner is intentionally not part of this product. Until the next
roadmap phase, Ubuntu Zombie's `forgejo-runner` compatibility component owns
the runner and declares this product as its dependency.

## Trust boundary

Forgejo listens only on `127.0.0.1:3000`. Caddy is the LAN-facing HTTPS edge
on the host's `.local` name. `app.ini` remains root-owned and group-readable
by `git`; its database and application secrets never enter lifecycle JSON,
receipts, or audit events.

The lifecycle runs as root because it manages packages, PostgreSQL, shared
Caddy configuration, host certificate trust, systemd, and service identities.
It has no authority over Ubuntu Zombie files, credentials, policy, or
services.

## Commands

From this directory:

```bash
./scripts/manage.sh describe --json
./scripts/manage.sh install --dry-run
sudo ./scripts/manage.sh install --yes
sudo forgejo-manage verify
sudo forgejo-manage backup --yes
sudo forgejo-manage update --yes
sudo forgejo-manage rollback --yes
sudo forgejo-manage suspend --yes
sudo forgejo-manage resume --yes
sudo forgejo-manage uninstall --yes
```

Uninstall retains repositories, database state, and recovery secrets by
default. Complete deletion additionally requires `--purge` and
`--confirmation "DELETE FORGEJO STATE"`.

See `docs/INSTALLATION.md`, `docs/CONFIGURATION.md`, and
`docs/ARCHITECTURE.md`.
