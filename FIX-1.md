# FIX-1: Bugs found in `scripts/` and `tests/`

This document lists bugs discovered in `scripts/install.sh`, `scripts/uninstall.sh`,
and `tests/smoke.sh`. It is structured so an AI agent can process each entry
independently and in priority order.

## How to use this document

- Process items in the order they appear (highest impact first).
- Each entry has the same fields:
  - **id** — short stable identifier (`FIX-1-NN`) you can reference in commits/PRs.
  - **severity** — `critical` (breaks working installs), `high` (data-loss or
    security-adjacent risk), `medium` (correctness / footgun), `low` (style /
    latent).
  - **file** — path relative to the repository root.
  - **lines** — line range in the current `main` (verify before editing).
  - **symptom** — observable bad behaviour.
  - **root cause** — why it happens.
  - **fix** — concrete remediation. Keep the change surgical.
  - **validation** — how to confirm the fix. Always re-run `make lint` and
    `make test` (see `Makefile:19-49`, `tests/smoke.sh`).
- Do not bundle unrelated items into one commit. One id per commit is ideal so
  each fix can be reverted independently.
- If a fix requires touching code outside the listed file/lines, note it in the
  commit body.

---

## Critical

### FIX-1-01 — Playwright system deps are never installed

- **severity**: critical
- **file**: `scripts/install.sh`
- **lines**: ~1043–1088 (inside the `runuser -l "${AGENT_USER}" -c '...'` block,
  specifically the `python -m playwright install --with-deps chromium` call near
  line 1080)
- **symptom**: After install, Chromium fails to launch because shared libs
  (libnss, libatk, libxkbcommon, etc.) are missing. The install log shows
  `playwright install failed after N attempts; rerun later.`
- **root cause**: `--with-deps` shells out to `apt-get install`, which requires
  root. The call runs as the unprivileged `${AGENT_USER}`, so every retry fails
  and the loop swallows the error and continues.
- **fix**: Split the work in two:
  1. As root, before the `runuser` block, install the Chromium system
     dependencies (`python3 -m playwright install-deps chromium` from a root
     context that has Playwright on PYTHONPATH, or hard-code the Ubuntu package
     list).
  2. Inside the `runuser` block, run `python -m playwright install chromium`
     (without `--with-deps`).
- **validation**:
  - `make lint` (shellcheck stays clean).
  - On a fresh Ubuntu 24.04 VM, run `sudo ./scripts/install.sh` end-to-end and
    confirm `${ZOMBIE_DIR}/tools/browser-test.py` prints a page title.
- **status**: **fixed**. The Python runtime section in `scripts/install.sh`
  (around lines 1045–1121) now runs `python -m playwright install-deps chromium`
  as root via the agent venv's interpreter (`${AGENT_HOME}/agent-env/bin/python`)
  with retry/backoff, _before_ the unprivileged `runuser` block. The
  `runuser`-as-${AGENT_USER} block then only calls `python -m playwright install
  chromium` (no `--with-deps`), so apt-get is no longer invoked as a non-root
  user. `make lint` and `make test` both pass.

---

### FIX-1-02 — `append_line_once` corrupts `authorized_keys` with no trailing newline

- **severity**: critical
- **file**: `scripts/install.sh`
- **lines**: 240–244 (`append_line_once`), called at 773
- **symptom**: When the existing `${AGENT_HOME}/.ssh/authorized_keys` does not
  end in `\n`, the newly added key is concatenated onto the previous one. The
  previous key is effectively destroyed and the new key is malformed. Operator
  is locked out.
- **root cause**: `echo "$line" >> "$file"` does not first ensure `$file` ends
  with a newline.
- **fix**: In `append_line_once`, before appending, ensure trailing newline:
  - If the file exists and is non-empty and `tail -c1 "$file"` is not a newline,
    `printf '\n' >> "$file"`.
  - Then `printf '%s\n' "$line" >> "$file"` (avoid `echo` for portability).
- **validation**:
  - Add a unit-style check in `tests/smoke.sh` (or a new tiny shell test) that
    sources the function and calls it against a temp file without trailing
    newline; assert two distinct lines result.
  - `make test`.
- **status**: **fixed**. `append_line_once` in `scripts/install.sh` (lines
  240–252) now checks `tail -c1 "$file"` and prepends a `printf '\n'` when the
  file is non-empty and does not already end in a newline, then writes the new
  entry with `printf '%s\n'` (no `echo`). A previously truncated last key can no
  longer be glued to the newly added key. `make lint` and `make test` pass.

---

### FIX-1-03 — `EXISTING_KEYS` undercounts and triggers wrong branch

- **severity**: critical
- **file**: `scripts/install.sh`
- **lines**: 754 (the `wc -l` line), with effects at 756–767 and 775–777
- **symptom**: A valid single-line `authorized_keys` with no trailing newline is
  counted as `0`. In interactive mode the user is wrongly prompted to paste a
  key; in `ZOMBIE_NONINTERACTIVE=1` mode the installer aborts with exit `64`
  even though a usable key is on disk.
- **root cause**: `wc -l` counts newlines, not lines.
- **fix**: Replace `wc -l < "$file"` with a line-counter that handles missing
  trailing newline, e.g. `grep -c . "$file" 2>/dev/null || echo 0` or
  `awk 'END{print NR}' "$file"`.
- **validation**:
  - Create a temp `authorized_keys` containing exactly one key with no trailing
    `\n` and re-run the SSH-key block (or a targeted test) — confirm the
    "already authorized" path is taken.
  - `make test`.
- **status**: **fixed**. `scripts/install.sh` line 762 now computes
  `EXISTING_KEYS="$(awk 'END{print NR}' "${AGENT_HOME}/.ssh/authorized_keys"
  2>/dev/null || echo 0)"`, so a single key without a trailing newline is
  correctly counted as 1. The interactive prompt now reports "already
  authorized" instead of asking for a fresh key, and `ZOMBIE_NONINTERACTIVE=1`
  no longer aborts with exit 64 when a usable key is already on disk. `make
  lint` and `make test` pass.

---

## High

### FIX-1-04 — `uninstall.sh --archive` clobbers `/var/backups` mode

- **severity**: high
- **file**: `scripts/uninstall.sh`
- **lines**: ~138–146 (the `if [[ "${ARCHIVE}" == "1" ]]` block, especially the
  `install -d -m 700 ${BACKUP_DIR}` line)
- **symptom**: After running `sudo ./uninstall.sh --archive`, `/var/backups`
  changes from `0755 root:root` to `0700 root:root`. Tools that read it as a
  non-root user (e.g. `dpkg`, `cracklib`, automated audit collectors) break.
- **root cause**: `install -d -m MODE DIR` always applies `MODE`, even when
  `DIR` already exists.
- **fix**: Either
  - Use a dedicated sub-directory: `BACKUP_DIR="${BACKUP_DIR:-/var/backups/ubuntu-zombie}"`
    and create only that with `0700`; or
  (x) Only set the mode when creating the directory new:
    `[[ -d "${BACKUP_DIR}" ]] || install -d -m 700 "${BACKUP_DIR}"`.
- **validation**:
  - On a fresh VM record `stat -c '%a %U:%G' /var/backups` before/after running
    `uninstall.sh --archive`; mode must not change.
  - `make lint`.

---

### FIX-1-05 — `authorized_keys` tmp-file dance risks lockout on ENOSPC

- **severity**: high
- **file**: `scripts/install.sh`
- **lines**: 745–752
- **symptom**: If the disk fills up during the `cat existing > tmp` step, `tmp`
  is left truncated and the subsequent `mv tmp existing` destroys the original
  `authorized_keys`. Operator is locked out on the next run.
- **root cause**: The "tmp file + mv" pattern is functionally a no-op (same
  bytes in, same bytes out) but adds a failure window. Errors from `cat` are
  not checked before `mv`.
- **fix**: Remove the tmp dance. Only `install -m 600 -o ... -g ... /dev/null`
  when `authorized_keys` does **not** exist. Otherwise leave it alone (the later
  `chown`/`chmod` already re-asserts ownership and mode).
- **validation**:
  - Run installer twice in a row on a host where the agent already has keys;
    confirm `authorized_keys` content is byte-identical before/after the second
    run.
  - `make test`.

---

### FIX-1-06 — `uninstall.sh` `run()` uses `eval "$@"` incorrectly

- **severity**: medium (latent high — any future caller with whitespace args
  breaks)
- **file**: `scripts/uninstall.sh`
- **lines**: 75–81
- **symptom**: Works today only because every call site happens to pass a
  single space-separated string literal. Any argument containing spaces, quotes
  or shell metacharacters will be re-split incorrectly by `eval`.
- **root cause**: `"$@"` expands into multiple words; `eval` then joins them
  with spaces and re-parses, dropping the original quoting.
- **fix**: Either
  (x) Change callers to pass a single string and use `eval "$1"`; or
  - Keep `"$@"` and drop `eval`, then have callers that need shell features
    (redirections, `||`) wrap themselves in `bash -c '...'`.
  Pick whichever is the smaller diff (the former, currently).
- **validation**:
  - Add a smoke check that passes an argument with embedded space and asserts
    correct behaviour.
  - `make lint`, `make test`.

---

## Medium

### FIX-1-07 — `die "Cancelled." 0` exits success with a red error banner

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 637 (and any other `die "..." 0` callers — grep first)
- **symptom**: CI / parent scripts treat the cancellation as success; users see
  a red `[x] Cancelled.` line and assume failure.
- **root cause**: `die` is intended for failure and always prints the `[x]`
  marker.
- **fix**: Replace with `info "Cancelled."; exit 0` (or introduce a new helper
  `cancel()` that prints in neutral colour and exits 0).
- **validation**:
  - Interactive run, answer anything except `YES`, confirm `$?` is `0` and no
    red banner is printed.

---

### FIX-1-08 — `uninstall.sh --help` prints executable code

- **severity**: low
- **file**: `scripts/uninstall.sh`
- **lines**: 69–71 (`usage()` uses `sed -n '2,30p' "$0"`)
- **symptom**: `--help` output includes the `set -Eeuo pipefail` line because
  the header comment ends at line 29.
- **root cause**: Hard-coded line range outgrew the comment block.
- **fix**: Either change range to `'2,29p'`, or — preferred — replace `usage()`
  body with a heredoc the way `install.sh` does, so future header edits do not
  desync.
- **validation**:
  - `./scripts/uninstall.sh --help` final line should be the comment ending
    with `... may depend on.`, not `set -Eeuo pipefail`.

---

### FIX-1-09 — Tailscale codename fallback can pick the wrong repo

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 816 (`TS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"`),
  also Docker block around 1021
- **symptom**: On a Jammy (22.04) host where `/etc/os-release` failed to load
  (so both vars are empty), the installer enables the `noble` Tailscale repo
  and `apt_install tailscale` fails — or, worse, installs an incompatible
  package.
- **root cause**: Hard-coded `noble` default is unsafe when codename detection
  failed.
- **fix**: After `load_os_release`, set codename from `VERSION_ID` via an
  explicit `case` (`22.04 → jammy`, `24.04 → noble`). If neither var is set and
  `VERSION_ID` is unknown, `die` with exit `65` rather than guess.
- **validation**:
  - Manually unset `UBUNTU_CODENAME`/`VERSION_CODENAME` and confirm the script
    no longer silently defaults to `noble`.
  - `make lint`.

---

### FIX-1-10 — `uninstall.sh` SSH reload removes hardening

- **severity**: medium (intended, but undocumented)
- **file**: `scripts/uninstall.sh`
- **lines**: ~106–112 (the SSH drop-in removal + `systemctl reload ssh`)
- **symptom**: Once the drop-in is removed and sshd reloads, `PermitRootLogin`,
  `PasswordAuthentication`, and `AllowUsers` revert to distro defaults. A
  partially-uninstalled box can become more open than the operator expects.
- **root cause**: Uninstall removes hardening as part of "reverse install".
- **fix**: Either keep behaviour but print a prominent `warn` before the reload
  (recommended), or add a `--keep-sshd-hardening` flag that leaves the drop-in
  in place.
- **validation**:
  - Visual review of `--dry-run` output.

---

## Low / style

### FIX-1-11 — SC2015 in `load_os_release`

- **severity**: low
- **file**: `scripts/install.sh`
- **lines**: 281
- **symptom**: shellcheck SC2015. If `. /etc/os-release` ever returned non-zero
  the `|| true` would mask it.
- **fix**: `if [[ -r /etc/os-release ]]; then . /etc/os-release || true; fi`.

### FIX-1-12 — Inline `runuser` heredoc is unlintable

- **severity**: low
- **file**: `scripts/install.sh`
- **lines**: 1043–1088
- **symptom**: shellcheck SC2016. The single-quoted block is opaque to `make
  lint` and to editors. Bugs (like FIX-1-01) hide there.
- **fix**: Extract the body into `payload/bin/setup-agent-venv` (or
  `tools/setup-venv.sh`), install it during the payload deploy step, then
  `runuser -l "$AGENT_USER" -- "${ZOMBIE_DIR}/bin/setup-agent-venv"`. The new
  file is then picked up by `tests/smoke.sh::run_syntax`.
- **validation**: `make lint`, `make test`.

### FIX-1-13 — Dead code in `tests/smoke.sh::run_noninteractive`

- **severity**: low
- **file**: `tests/smoke.sh`
- **lines**: 98–111
- **symptom**: `tmpdir`, `HAVE_SUDO`, and the `sudo -n true` probe are computed
  and discarded. The only real assertion is a `grep` on `--help`.
- **fix**: Either delete the dead variables and keep the `grep` assertion, or
  add a real test: export `validate_noninteractive` from `install.sh` (e.g.
  guard the dispatch with `if [[ "${BASH_SOURCE[0]}" == "$0" ]]`), then `bash
  -c 'source scripts/install.sh; validate_noninteractive'` with controlled env.
- **validation**: `make test`.

### FIX-1-14 — `bad-usage` test passes for the wrong reason

- **severity**: low
- **file**: `tests/smoke.sh`
- **lines**: 86 (`expect_exit_code 2 ./scripts/install.sh install unexpected`)
- **symptom**: On a non-root runner, the assertion is satisfied by the
  `require_root` `die ... 2` rather than by `reject_unexpected_positional_args`.
  If either changes exit code in the future, the test silently breaks.
- **fix**: Either run `install unexpected` under `fakeroot`/skip it on non-root,
  or use a subcommand that does not require root (`doctor unexpected` already
  exercises the same path on line 88).
- **validation**: `make test`.

### FIX-1-15 — Subcommand parser accepts `install verify` as `install + arg`

- **severity**: low
- **file**: `scripts/install.sh`
- **lines**: 165–177
- **symptom**: `./install.sh install verify` is parsed as subcommand `install`
  with positional arg `verify`, then rejected with
  `Unexpected argument(s) for install: verify`. `./install.sh install install`
  is "accepted" silently as two installs.
- **fix**: Track `subcommand_seen=0` and only allow the subcommand to be set
  once; on a second match, fall through to the `*)` arm and `die ... 2`.
- **validation**: Add a `tests/smoke.sh` line:
  `expect_exit_code 2 ./scripts/install.sh install install`.

### FIX-1-16 — UFW cleanup loop matches too broadly

- **severity**: low
- **file**: `scripts/install.sh`
- **lines**: 862–866
- **symptom**: When walking `ufw status numbered` to remove a previously-added
  all-interface `22/tcp` rule, an unrelated `22/tcp` rule from elsewhere could
  also match.
- **fix**: Tighten the `awk` pattern to match only rules whose comment matches
  the one we set (`SSH (Tailscale skipped)`).
- **validation**: Manual review on a host with multiple `22/tcp` rules.

### FIX-1-17 — `render_unit` relies on validator to be `sed`-safe

- **severity**: low (documentation)
- **file**: `scripts/install.sh`
- **lines**: 1153–1158
- **symptom**: `sed "s|__AGENT_USER__|${AGENT_USER}|g"` would break if
  `${AGENT_USER}` contained `|`, `&`, or `\`. Currently safe only because
  `is_supported_agent_username` (lines 250–255) forbids those characters.
- **fix**: Add an inline comment in `render_unit` noting the coupling so the
  validator is not relaxed without revisiting this.
- **validation**: Code review.

---

## Suggested commit order

1. `FIX-1-01` (broken Playwright)
2. `FIX-1-02` + `FIX-1-03` + `FIX-1-05` (authorized_keys correctness — same file,
   adjacent lines; one commit each, in this order, is fine)
3. `FIX-1-04` (uninstall data-loss)
4. `FIX-1-07`, `FIX-1-08`, `FIX-1-09`, `FIX-1-10` (UX / correctness)
5. `FIX-1-06`, `FIX-1-11` … `FIX-1-17` (cleanups, batchable)

After every commit: `make lint && make test`.
Before opening a PR: `make package`.
