# Upgrading Ubuntu Zombie

The installer is **idempotent**. The supported upgrade path is:

```bash
cd ubuntu-zombie
git pull
sudo ./scripts/install.sh install --dry-run   # preview the changes
sudo ./scripts/install.sh install             # apply
sudo systemctl restart ubuntu-zombie-chat.service
sudo ./scripts/install.sh verify              # confirm post-install invariants
```

If you installed the `.deb` instead:

```bash
sudo apt install ./ubuntu-zombie_<new-version>_all.deb
sudo ubuntu-zombie --dry-run install
sudo ubuntu-zombie install
sudo systemctl restart ubuntu-zombie-chat.service
sudo ubuntu-zombie verify
```

A reboot is **only** required when the upgrade touches the kernel,
GDM session type (Wayland → Xorg), or Tailscale's kernel module.
`install` will tell you when that is the case.

`/opt/ai-zombie/secrets/env`, `/home/zombie/.ssh/authorized_keys`,
audit logs, history database, and operator-supplied skills under
`/etc/ubuntu-zombie/skills.d/` are preserved across upgrades.
Built-in skills under `/opt/ai-zombie/skills/` are re-deployed from
the new payload on every install.

---

## Version-by-version notes

Entries below call out behaviour changes that require operator action
beyond `git pull && install`. The complete changelog lives in
[`CHANGELOG.md`](../CHANGELOG.md).

### Unreleased

- **No breaking changes.** New: `install.sh --dry-run`, step-trace
  log on `ERR`, `secrets-edit` writes backups before opening the
  editor, `.deb` packaging, signed releases.

### 0.3.0

- `payload/agent/` adopted the closed pi-mono tool registry. The
  legacy "fenced bash" extraction path was removed. Custom skills
  that returned bash code blocks instead of structured tool calls
  will no longer auto-execute; they are reported as model output
  only. Rewrite them to call the documented tools listed in
  [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) § tool registry.
- Per-turn budgets: 12 tool calls total, 3 elevated. Skills that
  exceeded these in 0.2.x will now hit the synthetic
  `budget_exceeded` observation and surrender the turn.

### 0.2.x → 0.3.0

- `AGENT_USER` env var renamed to `ZOMBIE_USER`. The old name is
  still accepted for backward compatibility but emits no warning;
  prefer the new name in any automation.
- `scripts/setup-part-1.sh` was renamed to `scripts/install.sh` and
  grew the `verify|doctor|repair|uninstall` subcommands. If you have
  automation that called the old script, update the path.

---

## Downgrading

Downgrades are **not** supported. Re-install from the older tag and
restore `/opt/ai-zombie/secrets/env` from backup if necessary.
