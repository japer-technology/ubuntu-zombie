<!-- triggers: backups, snapshot, snapshots, timeshift, rsync, restore, tarball, archive, deja-dup, borg, restic, duplicity -->
# Skill: backups, snapshots and restores

This skill is loaded when the operator mentions backups, snapshots or
restoring data.

Operating rules:

- Ask what is being protected before choosing a tool. Timeshift
  snapshots the *system* (and by default excludes `/home`); Déjà Dup
  and Borg/Restic protect *user data*; `rsync` and `tar` are the
  general-purpose primitives. Backing up the wrong half is the most
  common failure.
- Inspect first, and say where the space will come from. `df -h` on the
  destination, `du -sh` on the source, and `timeshift --list` or the
  repository's own listing command are `read_only` and auto-run.
- Prefer `rsync -aAXH --info=progress2` for file-level copies: it
  preserves permissions, ACLs, xattrs and hard links. Test with
  `--dry-run` first and show the operator the summary before the real
  run.
- `rsync --delete` makes the destination match the source, which means
  it deletes. Treat any `--delete` run as high blast radius: dry-run
  it, name the files it would remove, and confirm the trailing-slash
  semantics of the source path (`src/` copies contents, `src` copies
  the directory).
- Restores overwrite. Never restore over live data without stating what
  will be replaced and confirming the destination path character by
  character. Prefer restoring to a scratch directory under `/tmp` and
  letting the operator move files into place.
- Timeshift restore and `timeshift --delete` are `destructive`-class
  operations that can roll back or remove system state; they need the
  exact confirmation phrase. Quote that requirement rather than
  reaching for a command that avoids it.
- A backup nobody has restored is a hypothesis. After creating one,
  verify it: list the archive (`tar -tzf`, `borg list`,
  `restic snapshots`), check the byte count, and restore one file to
  `/tmp` as a smoke test.
- Repository passphrases and cloud credentials are secrets. Read them
  from the operator's existing configuration, never echo them into the
  chat, and never write them into a script or a systemd unit in plain
  text.
- Backups on the same disk protect against mistakes, not hardware
  failure. If the destination is a partition of the source drive, say
  so — the operator may believe they are covered when they are not.
- Automate only what the operator asked for. A backup timer that runs
  unattended is a standing change to the machine; describe the schedule
  and retention it implies before landing it.
