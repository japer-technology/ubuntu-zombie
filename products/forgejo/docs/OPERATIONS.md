# Operations

- `status`, `verify`, and `doctor` are read-only.
- `repair` converges owned files, database credentials, network boundaries,
  trust, and services without rotating recoverable secrets.
- `backup` stops server and runner briefly, then captures repositories,
  configuration, the verified binary, product source, and a PostgreSQL custom
  dump in a root-private checksum sidecar archive.
- `update` creates a rollback backup before changing product or Forgejo
  versions.
- `rollback` validates the recorded archive digest, restores files and the
  database, then passes loopback and HTTPS health gates before restarting a
  previously active runner.
- `suspend` records boot and runner intent and stops both services.
- `resume` restores recorded intent only after Forgejo becomes healthy.
- `uninstall` removes runtime integration but retains state by default.

Inspect service failures with:

```bash
sudo journalctl -u forgejo.service
sudo journalctl -u postgresql.service
sudo journalctl -u caddy.service
sudo forgejo-manage doctor
```
