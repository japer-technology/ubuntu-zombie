<!-- triggers: fs, file, files, directory, folder, config, configuration, backup, scratch, tempfile, symlink -->
# Skill: reading and writing files

This skill is loaded when the operator asks to inspect or change files
and configuration on the machine.

Operating rules:

- Prefer `fs.read`, `fs.list` and `fs.write` over `shell.run` with
  `cat`, `ls` or `tee`. They report byte counts and truncation
  honestly, and the audit entry names the path instead of an opaque
  command string.
- `fs.read` and `fs.list` are `read_only` and cover `/etc`,
  `/var/log`, `/proc`, `/sys`, `/usr/share`, `/usr/lib`,
  `/run/systemd` and the zombie state directory. Anything outside that
  set — notably `/home` — needs `shell.run`.
- The allow-list is checked against the *resolved* path, so a symlink
  that points outside the readable roots is rejected even when the link
  itself sits inside them. `/proc/<pid>/environ` is denied outright
  because it would expose the chat service's own API keys.
- `fs.write` is `user_change`, waits for approval, and can only write
  under `/tmp` and the zombie state directory. It creates missing
  parent directories and replaces the file wholesale — there is no
  append and no partial edit.
- System configuration under `/etc` therefore cannot be written with
  `fs.write`. Editing it means `shell.run` with `sudo`, which is
  `system_change` or higher; read the current file first, show the
  operator the exact diff you intend, and keep the change minimal.
- Back up before editing anything the machine boots or authenticates
  with: copy to `<file>.bak-$(date +%Y%m%d%H%M%S)` and tell the
  operator the backup path so the rollback is a single command.
- Use `/tmp` for scratch work — downloads, extracted archives,
  generated files. It is the only writable general-purpose location on
  the allow-list and `shell.run`'s `cwd` is restricted to the same set.
- Read before you write, every time. Overwriting a file whose current
  contents you never inspected is how a "small fix" removes an
  operator's manual customisation.
- Validate after writing where a validator exists (`visudo -c`,
  `sshd -t`, `netplan generate`, `nginx -t`, `systemd-analyze verify`).
  A syntax error in a file that gates boot or login is expensive.
