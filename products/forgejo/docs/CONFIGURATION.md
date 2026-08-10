# Configuration

Direct lifecycle inputs use the `FORGEJO_` prefix:

| Variable | Default | Purpose |
|---|---|---|
| `FORGEJO_ADMIN_USER` | `forgejo-admin` | Initial administrator name |
| `FORGEJO_ADMIN_EMAIL` | `forgejo-admin@localhost.localdomain` | Initial administrator email |
| `FORGEJO_DB_NAME` | `forgejo` | PostgreSQL database |
| `FORGEJO_DB_USER` | `forgejo` | PostgreSQL role |
| `FORGEJO_VERSION` | `latest` on first install | Upstream release pin |
| `FORGEJO_BOOT` | `enabled` | Boot enablement |
| `FORGEJO_HTTP_PORT` | `3000` | Fixed compatibility assertion |
| `FORGEJO_ADMIN_PASSWORD_FILE` | generated | Root-private secret input |
| `FORGEJO_DB_PASSWORD_FILE` | generated | Root-private secret input |
| `FORGEJO_BACKUP_DESTINATION` | `/var/backups/forgejo` | Manual backup target |

Secret references must be absolute, root-owned regular files with no group or
other access. Raw passwords are not accepted by the direct product.

The public host is the existing valid `app.ini` domain or the machine's
single-label hostname plus `.local`. The backend address and port are fixed.
Unknown `FORGEJO_` variables fail closed.

Generated initial administrator credentials are written once to
`/etc/forgejo/bootstrap-admin-password` with mode 0600. Generated database and
application recovery material remains only in root-protected `app.ini`.
