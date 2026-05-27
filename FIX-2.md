# FIX-2: Additional bugs found in `scripts/`

This document lists bugs discovered in `scripts/install.sh` and
`scripts/uninstall.sh` that are **not already covered by `FIX-1.md`**. It is
structured so an AI agent can process each entry independently and in priority
order.

## How to use this document

- Process items in the order they appear (highest impact first).
- Each entry has the same fields:
  - **id** — short stable identifier (`FIX-2-NN`) you can reference in
    commits/PRs.
  - **severity** — `critical` (root command injection / lockout / data loss),
    `high` (security-adjacent leak or stale privilege), `medium`
    (correctness / footgun / wrong warning), `low` (style / latent / cosmetic).
  - **file** — path relative to the repository root.
  - **lines** — line range in the current `main` (verify before editing; line
    numbers may drift as adjacent fixes land).
  - **symptom** — observable bad behaviour.
  - **root cause** — why it happens.
  - **fix** — concrete remediation. Keep the change surgical.
  - **validation** — how to confirm the fix. Always re-run `make lint` and
    `make test` (see `Makefile:19-49`, `tests/smoke.sh`).
- Do not bundle unrelated items into one commit. One id per commit is ideal so
  each fix can be reverted independently.
- If a fix requires touching code outside the listed file/lines (e.g. adding a
  shared helper, or extending `tests/smoke.sh` with a regression case), note it
  in the commit body.
- Cross-reference: items in this document complement `FIX-1.md`. Do **not**
  duplicate work that is already marked **fixed** in `FIX-1.md`.

---

## Critical

### FIX-2-01 — `uninstall.sh` does not validate `ZOMBIE_USER`, enabling root command injection via `eval`

- **severity**: critical
- **file**: `scripts/uninstall.sh`
- **lines**: 30–34 (no validator after `AGENT_USER` is read), 102–112 (`run()`
  uses `eval`), 141, 153, 159, 176, 179, 188, 200, 212–215 (callers that
  interpolate `${AGENT_USER}` / `${AGENT_HOME}` / `${ZOMBIE_DIR}` into the
  command string passed to `run`).
- **symptom**: A maliciously chosen `ZOMBIE_USER` (or legacy `AGENT_USER`)
  environment variable causes arbitrary code to execute as `root` when the
  operator runs `sudo ./scripts/uninstall.sh`. For example:

      sudo ZOMBIE_USER='zombie;touch /tmp/pwn' ./scripts/uninstall.sh --yes

  results in `/tmp/pwn` being created (or anything the attacker substitutes)
  because the string is re-evaluated by `eval` inside `run`.
- **root cause**: `install.sh` defends itself by calling
  `validate_config` → `is_supported_agent_username` before any user-controlled
  value reaches a command (see `scripts/install.sh:275-285`). `uninstall.sh`
  has no equivalent validator; it accepts `${ZOMBIE_USER:-${AGENT_USER:-zombie}}`
  unchanged and then composes shell strings such as
  `"rm -f /etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie"` that are handed to
  `eval` by the `run` helper introduced in FIX-1-06. `ZOMBIE_DIR` and
  `AGENT_HOME` (derived from `AGENT_USER`) reach the same `eval` sites.
- **fix**:
  1. Factor `is_supported_agent_username` (and the `ZOMBIE_DIR`/`LOG_FILE`
     absolute-path checks) into a small validator function — either inline a
     copy in `uninstall.sh`, or extract a shared `scripts/lib/validate.sh` that
     both scripts source.
  2. Call the validator immediately after argument parsing in `uninstall.sh`
     (before the first `run "…"`), dying with exit code 2 on any of:
     - `AGENT_USER` not matching the supported username regex, or equal to
       `root` / `nobody`,
     - `ZOMBIE_DIR` not starting with `/`,
     - `BACKUP_DIR` not starting with `/`.
  3. As defence-in-depth, switch the `run` helper to accept an argv (e.g.
     `run() { "$@"; }` for non-string callers) for any new call sites; existing
     metacharacter-bearing callers can keep the eval path documented in
     FIX-1-06, but only after the inputs are validated.
- **validation**:
  - `make lint` (shellcheck stays clean).
  - Add a regression test in `tests/smoke.sh::run_bad_usage` mirroring the
    existing `ZOMBIE_USER=root` / `ZOMBIE_USER='bad user'` assertions, but
    invoking `./scripts/uninstall.sh --dry-run` (it must exit 2 without
    running any side-effecting command).
  - Manual: `sudo ZOMBIE_USER='zombie;touch /tmp/pwn' ./scripts/uninstall.sh
    --dry-run` must refuse and `/tmp/pwn` must not be created.

---

## High

### FIX-2-02 — `uninstall.sh --archive` writes backup tarballs with the process umask, exposing SSH keys and the VNC password

- **severity**: high
- **file**: `scripts/uninstall.sh`
- **lines**: 166–181 (the `ARCHIVE` block).
- **symptom**: After `sudo ./scripts/uninstall.sh --archive`, the files
  `/var/backups/ubuntu-zombie-home-<stamp>.tar.gz` and
  `/var/backups/ubuntu-zombie-state-<stamp>.tar.gz` exist with mode `0644`
  (default root umask `022`). `/var/backups` itself is mode `0755` on a default
  Ubuntu host (and FIX-1-04 deliberately leaves it that way). Any local user
  can therefore read the archive and extract:
  - `${AGENT_HOME}/.ssh/authorized_keys` and any private keys the operator
    placed there,
  - `${AGENT_HOME}/.vnc/passwd` (x11vnc password hash),
  - `${ZOMBIE_DIR}/state/*` (chat history, screenshots),
  - any provider tokens that happen to be in `${AGENT_HOME}` config files.
- **root cause**: `tar -czf <path> …` creates `<path>` with `O_CREAT` under
  the current umask. The script never tightens the umask or pre-creates the
  output file with a restrictive mode before writing to it.
- **fix**: Make the archives mode `0600` and root-owned. Two acceptable
  patterns:
  1. Wrap the archive block in `( umask 077; tar -czf … )` so both tarballs
     are created `0600`.
  2. Or pre-create each output file with
     `install -m 600 -o root -g root /dev/null "${path}"` and then write to it
     (`tar -czf "${path}" …` will truncate-rewrite; mode is preserved on most
     filesystems, but the `umask 077` approach is simpler and more portable).
  Either way, keep the `BACKUP_DIR` mode hands-off as required by FIX-1-04.
- **validation**:
  - `make lint`.
  - Manual: on a throw-away VM, populate `${AGENT_HOME}/.ssh/authorized_keys`
    and `${AGENT_HOME}/.vnc/passwd`, run
    `sudo ./scripts/uninstall.sh --archive --keep-agent --yes`, then
    `stat -c '%a %U:%G %n' /var/backups/ubuntu-zombie-*.tar.gz` and confirm
    `600 root:root`.

### FIX-2-03 — `uninstall.sh` does not remove the all-interface SSH UFW rule added by `ZOMBIE_SKIP_TAILSCALE=1` installs

- **severity**: high
- **file**: `scripts/uninstall.sh`
- **lines**: 156–161 (firewall cleanup).
- **related install code**: `scripts/install.sh:877-894` (skip-Tailscale
  branch adds `ufw allow 22/tcp comment "SSH (Tailscale skipped)"`).
- **symptom**: A host that was installed with `ZOMBIE_SKIP_TAILSCALE=1` ends
  up with a UFW rule `22/tcp ALLOW Anywhere # SSH (Tailscale skipped)`. After
  `sudo ./scripts/uninstall.sh`, the SSH hardening drop-in
  (`/etc/ssh/sshd_config.d/99-ubuntu-zombie.conf`) is removed and `sshd` is
  reloaded back to Ubuntu defaults (FIX-1-10 already warns about this), but
  the UFW rule that opened `22/tcp` to every interface is **left in place**.
  The host is therefore returned to a state with passwords/root SSH (Ubuntu
  defaults) reachable from every network the host can be addressed on — the
  worst of both worlds.
- **root cause**: The cleanup loop only matches `tailscale0.*22/tcp`. It has
  no symmetrical branch to remove the `# SSH (Tailscale skipped)` rule that
  the skip-Tailscale install path added. The install path tags that rule with
  a stable comment for exactly this kind of cleanup (see the FIX-1-16
  pattern), but `uninstall.sh` never uses it.
- **fix**: After the existing tailscale0 cleanup, also remove any rule whose
  comment matches `# SSH (Tailscale skipped)`. Mirror the FIX-1-16 idiom from
  `install.sh:904-909` (`ufw status numbered | awk '/# SSH \(Tailscale
  skipped\)/ && /22\/tcp/ {print $2}'`, then `yes | ufw delete <num>`), wrapped
  in the existing `run "…"` helper so `--dry-run` keeps working. Loop until no
  matching rule remains, with a `|| break` guard so a failing delete cannot
  spin forever.
- **validation**:
  - `make lint`.
  - Manual: `sudo ZOMBIE_SKIP_TAILSCALE=1 ./scripts/install.sh` on a VM, then
    `sudo ./scripts/uninstall.sh --yes`, then `sudo ufw status numbered` —
    confirm no `# SSH (Tailscale skipped)` rule remains.
  - Manual dry-run: `sudo ZOMBIE_SKIP_TAILSCALE=1
    ./scripts/uninstall.sh --dry-run` should print a `[dry] ufw … delete …`
    line for the rule.

### FIX-2-04 — `uninstall.sh` does not remove sudoers drop-ins from older installs that used a different `ZOMBIE_USER`

- **severity**: high
- **file**: `scripts/uninstall.sh`
- **lines**: 141 (`rm -f /etc/sudoers.d/90-${AGENT_USER}-ubuntu-zombie`).
- **symptom**: An operator who installs once with the default
  `ZOMBIE_USER=zombie` and later re-installs with `ZOMBIE_USER=alice` (or
  vice versa) and then uninstalls will be left with whichever
  `/etc/sudoers.d/90-<other-name>-ubuntu-zombie` matches the *not-current*
  name. If the corresponding Linux user still exists (because the operator
  passed `--keep-agent` previously, or created the account manually), that
  account silently retains `NOPASSWD:ALL` after the rest of the installer's
  surface has been removed.
- **root cause**: `uninstall.sh` removes only the sudoers drop-in whose name
  matches the **currently effective** `AGENT_USER`. It never enumerates the
  `/etc/sudoers.d/90-*-ubuntu-zombie` glob, so drop-ins owned by previous runs
  are orphaned.
- **fix**: Replace the single `rm -f` with a glob-driven loop, e.g.
  ```bash
  for f in /etc/sudoers.d/90-*-ubuntu-zombie; do
    [[ -e "$f" ]] || continue
    run "rm -f $f"
  done
  ```
  (after FIX-2-01 lands, `$f` cannot be attacker-controlled because the glob
  expands locally; the only metacharacters are those produced by the kernel's
  directory listing). For each removed drop-in, also extract the embedded
  account name and feed it into the existing step 7 user-removal flow so the
  operator is offered the chance to delete the stale account too — or, more
  conservatively, just `warn` listing the orphaned accounts.
- **validation**:
  - `make lint`.
  - Manual: create both `/etc/sudoers.d/90-zombie-ubuntu-zombie` and
    `/etc/sudoers.d/90-alice-ubuntu-zombie`, run `sudo ZOMBIE_USER=zombie
    ./scripts/uninstall.sh --dry-run`, confirm both files are listed for
    removal.

### FIX-2-05 — `uninstall.sh` prints "Removed user" even when removal silently fails

- **severity**: high
- **file**: `scripts/uninstall.sh`
- **lines**: 207–219 (user removal block).
- **symptom**: If `deluser --remove-home` and the `userdel -r` fallback both
  fail (e.g. the user still has running processes that `pkill -KILL` did not
  reach, or `userdel` refuses because of a mounted home), the script prints
  the green `[+] Removed user ${AGENT_USER}` confirmation and exits 0. The
  operator believes the account is gone; in fact it (and its passwordless
  sudo entry if not also caught by FIX-2-04) is still active.
- **root cause**: The removal line ends with `|| true`, so neither failure
  propagates. The subsequent `ok "Removed user …"` is unconditional rather
  than guarded by `id "${AGENT_USER}" >/dev/null 2>&1 && warn …`.
- **fix**: Drop the trailing `|| true`, capture the exit code of the
  combined `deluser … || userdel …` expression, and branch on it:
  - On success → `ok "Removed user …"`.
  - On failure (or if `id "${AGENT_USER}"` still resolves afterwards) →
    `warn "Failed to remove user ${AGENT_USER}; see 'who', 'loginctl list-sessions',
    'lsof +D ${AGENT_HOME}' and re-run."` and set a non-zero exit status for
    the whole script.
  The `pkill -KILL` already uses `|| true`, which is fine — it is the
  removal itself that must be checked.
- **validation**:
  - `make lint`.
  - Manual on a throw-away VM: hold the user's home open with
    `sudo -u ${AGENT_USER} sleep 600 &`, run `sudo ./scripts/uninstall.sh
    --yes --keep-agent=0` (or whatever invocation removes the user), and
    confirm the script reports failure and exits non-zero rather than
    claiming success.

---

## Medium

### FIX-2-06 — `preflight` "SSH not on tailscale0" warning fires for every SSH session because it greps for the *client* IP

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 385–396.
- **symptom**: Every SSH-driven install (even one made over Tailscale) prints

      [!] Detected SSH session from <ip> that is NOT on tailscale0.
      [!] Installer restarts sshd and tightens UFW; you risk locking yourself out.

  Operators legitimately on Tailscale either ignore the warning (and the
  signal value of the warning is destroyed) or abort installs that would have
  been safe.
- **root cause**: `from_ip="$(awk '{print $1}' <<<"${SSH_CONNECTION}")"`.
  Per `sshd(8)`, `SSH_CONNECTION` is `client_ip client_port server_ip
  server_port`. Field 1 is the **client** IP. The subsequent check
  `ip -o addr show dev tailscale0 | grep -q "${from_ip}"` searches the
  *local* tailscale0 addresses for the client's IP — those address spaces
  are disjoint by construction, so the grep never matches and the `!` makes
  the warning fire unconditionally.
- **fix**: Use field 3 (the local address sshd accepted the connection on)
  and compare it against the host's tailscale0 addresses:
  ```bash
  local_ip="$(awk '{print $3}' <<<"${SSH_CONNECTION}")"
  if ! ip -o addr show dev tailscale0 2>/dev/null \
       | awk '{print $4}' | cut -d/ -f1 \
       | grep -qxF "${local_ip}"; then
    warn "Detected SSH session terminating on ${local_ip}, which is NOT a tailscale0 address."
    ...
  fi
  ```
  Using `grep -qxF` against the address list (rather than `grep -q` against
  the whole `ip` output) also avoids false positives where the client IP
  happens to appear as a substring of a netmask or interface label.
- **validation**:
  - `make lint`.
  - Manual: SSH to a test VM over Tailscale and run `sudo
    ./scripts/install.sh doctor` (or stub the preflight branch); the warning
    must not fire. SSH to the same VM over its public address and confirm the
    warning **does** fire.

### FIX-2-07 — `apt_get` only waits for the dpkg lock once, before the retry loop

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 216–230 (`wait_for_apt_lock`), 232–238 (`apt_get`).
- **symptom**: On Ubuntu hosts where `unattended-upgrades` (which the installer
  itself enables, see `scripts/install.sh:925-941`) wakes up between
  `wait_for_apt_lock` and the first apt call, `apt_get update` / `apt_get
  install` fails with `E: Could not get lock /var/lib/dpkg/lock-frontend`.
  `retry` then sleeps a flat 5/10/20 s and tries again — without waiting for
  the lock — so the second attempt collides with the same long-running
  unattended-upgrades transaction and the install ultimately aborts after the
  4-attempt budget.
- **root cause**: `apt_get` calls `wait_for_apt_lock || true` once, then
  delegates the actual apt invocation to `retry`. The retry loop has no
  knowledge of the lock and does not call `wait_for_apt_lock` between
  attempts.
- **fix**: Move the lock-wait inside the retried command. One option is a
  small wrapper:
  ```bash
  _apt_get_once() {
    wait_for_apt_lock || true
    env DEBIAN_FRONTEND=noninteractive apt-get \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"
  }
  apt_get() {
    retry 4 5 -- _apt_get_once "$@"
  }
  ```
  Keep `wait_for_apt_lock`'s 5 min ceiling — but now it is checked before
  every attempt, not only the first.
- **validation**:
  - `make lint`.
  - Manual reproduction: on a fresh Ubuntu 24.04 VM, run
    `sudo unattended-upgrade -d &` (or hold the lock with `flock
    /var/lib/dpkg/lock-frontend sleep 120 &`) and then `sudo
    ./scripts/install.sh`; the installer should wait, not fail.

### FIX-2-08 — `EXISTING_KEYS` counts blank lines and comments as authorized SSH keys

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 792 (`EXISTING_KEYS="$(awk 'END{print NR}' ... )"`), 795–805,
  813–814.
- **symptom**: If the operator's `authorized_keys` file consists of comments
  or blank lines only (e.g. a stub committed by a configuration-management
  system, or the file the installer itself creates via `install -m 600
  /dev/null …` then someone hand-edits to add `# add a key here`), the
  installer:
  - reports `${EXISTING_KEYS} SSH key(s) already authorized` to the operator,
    overstating reality;
  - takes the "key already authorized" branch in non-interactive mode and
    proceeds without `SSH_PUBLIC_KEY`, leaving the account with **no usable
    authorized key** after `sshd_config.d/99-ubuntu-zombie.conf` switches off
    password auth and `AllowUsers ${AGENT_USER}` is in effect. The operator
    can be locked out.
- **root cause**: `awk 'END{print NR}'` returns the raw line count, ignoring
  the SSH-key file format. Comments (`# …`) and blank lines are not authorized
  keys.
- **fix**: Count lines that actually look like an SSH key, e.g.:
  ```bash
  EXISTING_KEYS="$(grep -cvE '^[[:space:]]*(#|$)' \
                     "${AGENT_HOME}/.ssh/authorized_keys" 2>/dev/null || echo 0)"
  ```
  Or, more rigorously, run each non-blank/non-comment line through
  `is_ssh_pubkey` and count matches. The second branch in `validate_noninteractive`
  (`[[ -z "${SSH_PUBLIC_KEY}" && ! -s "${AGENT_HOME}/.ssh/authorized_keys" ]]`,
  line 440) has the same shape problem — it only checks for *non-empty* file —
  and should be updated to share the same "has at least one valid key"
  predicate.
- **validation**:
  - `make lint`.
  - Add a regression check: pre-populate `${AGENT_HOME}/.ssh/authorized_keys`
    with `# comment only\n\n` and run the installer with
    `ZOMBIE_NONINTERACTIVE=1` and no `SSH_PUBLIC_KEY`; the script must die
    with exit 64 ("Non-interactive mode requires SSH_PUBLIC_KEY …") instead
    of proceeding.

### FIX-2-09 — `cmd_verify` runs the generated `verify` script under whatever uid invoked `install.sh verify`, but the embedded checks assume `${AGENT_USER}`

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 458–464 (`cmd_verify`), 1339–1438 (the heredoc-emitted
  `${ZOMBIE_DIR}/bin/verify`).
- **symptom**: Running `sudo ./scripts/install.sh verify` (the documented
  invocation; see the `Usage:` block and the README) reports `[--] running
  as ${AGENT_USER}` and `[--] passwordless sudo` because `id -un` returns
  `root`, and may then trip cascading false negatives in DISPLAY / xdotool
  / screenshot checks because the verify script reads
  `${ZOMBIE_DIR}/secrets/env` (which sets `DISPLAY=:0`) but is not attached
  to the agent's X session. Operators interpret this as "install is broken"
  and re-run `install`, which is itself slow and disruptive.
- **root cause**: `cmd_verify` does `"${ZOMBIE_DIR}/bin/verify"` directly with
  no `sudo -u "${AGENT_USER}"` (or `runuser -l`), so the script inherits the
  caller's uid. The script is designed for the agent account.
- **fix**: In `cmd_verify`, if `id -u` is 0, re-exec the verify script as the
  agent user, e.g.:
  ```bash
  if [[ ${EUID} -eq 0 ]]; then
    exec runuser -l "${AGENT_USER}" -c "${ZOMBIE_DIR}/bin/verify"
  fi
  exec "${ZOMBIE_DIR}/bin/verify"
  ```
  Update the `usage()` text and the dispatch table comment so it is clear
  `verify` may be run as either root or the agent user.
- **validation**:
  - `make lint`.
  - Manual on a freshly installed VM: `sudo ./scripts/install.sh verify`
    should print all `[ok]` lines, not `[--] running as zombie`.

### FIX-2-10 — `is_ssh_pubkey` only matches a small allow-list and silently rejects current OpenSSH key types

- **severity**: medium
- **file**: `scripts/install.sh`
- **lines**: 262–264 (`is_ssh_pubkey`), 446–448 and 807–810 (call sites that
  call `die` on a "bad" key).
- **symptom**: Operators who paste a perfectly valid OpenSSH key whose type
  is not in the hard-coded list — for example the FIDO/U2F resident-key form
  `sk-ssh-ed25519-cert-v01@openssh.com …`, an Ed448 key
  (`ssh-ed448 …`), or any custom `*-cert-v01@openssh.com` certificate — are
  told `That does not look like an SSH public key` and the installer aborts
  with exit 1. Worse, in non-interactive mode (`validate_noninteractive`)
  the same false-negative bumps the exit code to 64, masking the real
  problem.
- **root cause**: The regex enumerates a closed set of key types
  (`ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@…|
  sk-ecdsa-sha2-nistp256@…`). Anything else — including legitimate certificate
  blobs — is rejected.
- **fix**: Loosen the regex to "looks like an OpenSSH `type b64 [comment]`
  line" rather than "is in this fixed list", e.g.
  `^[A-Za-z0-9@._+/-]+[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$`, and then
  defer real validation to `ssh-keygen -l -f -` (`echo "$key" | ssh-keygen -l
  -f -` exits 0 iff OpenSSH itself accepts the key, and the agent host already
  has `openssh-server` installed). Reject only when `ssh-keygen` fails. Keep
  the friendly "expected a line starting with ssh-ed25519 …" hint as guidance
  rather than as a hard rule.
- **validation**:
  - `make lint`.
  - Add a smoke-test case in `tests/smoke.sh::run_bad_usage` that pipes a
    valid `ssh-ed448` (or generated `ssh-keygen -t rsa-sha2-512`) key into the
    installer's preflight predicate via a small `bash -c` wrapper and expects
    it to be accepted.

---

## Low

### FIX-2-11 — `run()` in `uninstall.sh` silently discards arguments beyond `$1`

- **severity**: low
- **file**: `scripts/uninstall.sh`
- **lines**: 102–112.
- **symptom**: Future maintainers who call `run "rm -f" "${path}"` (the
  argv-style invocation the comment above `run` warns against) get a silent
  `rm -f` with no operand — the second argument is dropped on the floor — and
  the script reports success.
- **root cause**: FIX-1-06 intentionally re-evaluates a single composed
  command string. The current implementation uses `eval "$1"` literally,
  which is correct for current call sites but offers zero protection against
  the most natural mistake.
- **fix**: Defensive guard — refuse extra arguments:
  ```bash
  run() {
    if (( $# != 1 )); then
      printf '%s[x]%s run() takes exactly one composed command string; got %d args: %s\n' \
        "${C_RED}" "${C_RESET}" "$#" "$*" >&2
      exit 1
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
      printf '%s[dry]%s %s\n' "${C_YEL}" "${C_RESET}" "$1"
    else
      # shellcheck disable=SC2294
      eval "$1"
    fi
  }
  ```
  No call-site changes required; the guard only fires on misuse.
- **validation**:
  - `make lint`.
  - `bash -n scripts/uninstall.sh` and a one-off `bash -c '. scripts/uninstall.sh; run "echo a" "echo b"'` (or equivalent) confirms the new error
    fires.

### FIX-2-12 — `uninstall.sh` orphans the agent's primary group after `deluser --remove-home`

- **severity**: low
- **file**: `scripts/uninstall.sh`
- **lines**: 207–219.
- **symptom**: After successful user removal, the agent's primary group (same
  name as the user on a default `adduser` run, per `scripts/install.sh:758`)
  remains in `/etc/group` and continues to own files created elsewhere on the
  system (e.g. anything written under `/var/log/ubuntu-zombie/` before
  removal). A subsequent `adduser` for an unrelated account with the same name
  picks up unexpected file ownership.
- **root cause**: `deluser --remove-home` removes the user but leaves a
  primary group that no longer has members. `userdel -r` does the same on
  modern Debian/Ubuntu unless paired with `delgroup`.
- **fix**: After the user-removal branch succeeds (and after FIX-2-05 lands
  so success is detected), run `delgroup --only-if-empty "${AGENT_USER}"
  2>/dev/null || true`. Use `--only-if-empty` so we never delete a group that
  another local account still relies on.
- **validation**:
  - `make lint`.
  - Manual on a VM: `getent group ${AGENT_USER}` should return nothing after
    a full uninstall.

### FIX-2-13 — `install.sh` re-emits `/etc/gdm3/custom.conf` on every run, clobbering operator-managed sections

- **severity**: low
- **file**: `scripts/install.sh`
- **lines**: 949–984.
- **symptom**: An operator who edits `/etc/gdm3/custom.conf` to add
  `[xdmcp]` settings, custom greeter logos, or non-default `WaylandEnable`
  preferences between installs sees their changes wiped every time
  `sudo ./scripts/install.sh` is re-run (the installer is documented as
  idempotent).
- **root cause**: The installer writes the entire file with `cat > … <<EOF`
  rather than merging the four keys it actually owns
  (`WaylandEnable`, `AutomaticLoginEnable`, `AutomaticLogin`, and the
  managed-by header comment).
- **fix**: Replace the wholesale overwrite with a small in-place updater:
  read the existing file (if any), ensure the `[daemon]` section exists, and
  set/replace only the keys the installer owns (preserving everything else).
  A reasonable implementation: use `crudini --set` (already a Debian package,
  but adds a dependency) or an in-script awk that walks the INI file. If the
  added dependency is undesirable, gate the rewrite on a sentinel comment
  (`# Managed by install.sh`) so re-runs only overwrite files we previously
  wrote ourselves and leave operator-authored files alone with a `warn`.
- **validation**:
  - `make lint`.
  - Manual: write a custom `# operator note` line into
    `/etc/gdm3/custom.conf`, re-run the installer, and confirm the note
    survives.
