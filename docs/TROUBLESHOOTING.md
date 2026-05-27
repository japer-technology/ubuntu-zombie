# Troubleshooting

Common failures and the fastest fixes. Start with:

```bash
/opt/ai-zombie/bin/health-check        # or: zombie-health
sudo ./scripts/install.sh verify       # read-only state check
sudo ./scripts/install.sh doctor       # explains what is wrong
```

`verify` reports the post-install invariants (no mutation). `doctor`
describes what is wrong and points at the fix. `repair` applies the
known-safe fixes: it re-asserts `secrets/env` ownership and `0600`
mode, re-asserts UFW (`deny in / allow out`, plus the SSH rule scoped
to `tailscale0` unless `ZOMBIE_SKIP_TAILSCALE=1` was set at install),
re-renders the `pi-mono` runtime configs under `/opt/ai-zombie/pi/`,
re-deploys the built-in skill catalogue under `/opt/ai-zombie/skills/`,
optionally retries Tailscale login when `TAILSCALE_AUTHKEY` is set,
and restarts the chat service.

A timer (`ubuntu-zombie-health.timer`) runs `health-check` 5 minutes
after boot and every 15 minutes thereafter; its last run is visible in
`systemctl status ubuntu-zombie-health.service`.

---

## `apt`/`dpkg` is locked

```
Could not get lock /var/lib/dpkg/lock-frontend
```

Another package operation is running (often `unattended-upgrades`).
The installer waits up to five minutes for the lock with exponential
backoff. If it gives up:

```bash
ps -ef | grep -E 'apt|dpkg|unattended'
sudo systemctl stop unattended-upgrades.service
sudo ./scripts/install.sh install   # safe to re-run
```

## Tailscale will not log in

```bash
sudo tailscale up                    # follow the URL it prints
# or, unattended:
sudo TAILSCALE_AUTHKEY=tskey-auth-… ./scripts/install.sh repair
```

If you see `Logged out` and you supplied a pre-auth key, the key is
expired or scoped to the wrong tailnet. Generate a new one at
<https://login.tailscale.com/admin/settings/keys>.

If you intentionally installed without Tailscale
(`ZOMBIE_SKIP_TAILSCALE=1`), `doctor` and `health-check` will skip the
Tailscale check; SSH is allowed on every interface instead of being
scoped to `tailscale0`. Run any repair with the same variable set so
the firewall rule is rewritten correctly:

```bash
sudo ZOMBIE_SKIP_TAILSCALE=1 ./scripts/install.sh repair
```

## Docker group not applied

`docker version` reports `permission denied while trying to connect to
the Docker daemon socket`. The user was added to the `docker` group
during install but the existing shell session does not see it. Fix:

```bash
exit          # close every shell, then SSH back in
# or
sudo systemctl restart ubuntu-zombie-chat.service
```

## Desktop automation does not work

`xdotool` or screenshots fail with `Can't open display`.

- The desktop session must exist. With autologin disabled (the default),
  log in graphically as `zombie` first.
- Check `DISPLAY`: `/opt/ai-zombie/bin/gui-env env | grep DISPLAY`.
- Verify the session is Xorg, not Wayland:
  `loginctl show-session "$XDG_SESSION_ID" -p Type`.
- If Wayland is active, re-run `sudo ./scripts/install.sh repair` and
  log out / log back in.

## Playwright complains about missing libraries

`python -m playwright install --with-deps chromium` was interrupted.
Re-run:

```bash
sudo -iu zombie
. ~/agent-env/bin/activate
python -m playwright install --with-deps chromium
```

## VNC

- Cannot connect: confirm the SSH tunnel
  `ss -ltn 'sport = :5900'` should show `127.0.0.1:5900`.
- Forgot the password: `sudo -u zombie x11vnc -storepasswd`.
- Black screen: the desktop session is not running. With autologin
  disabled, log in physically as `zombie` once.

## Secrets file permissions

`/opt/ai-zombie/secrets/env` must be owned by the agent user and mode
`0600`. `doctor` and `health-check` flag it as `[--]` / `[warn]` when
the permissions drift. `secrets-edit` re-asserts ownership and mode on
exit (even on editor failure), and `install.sh repair` re-asserts them
across the whole tree. To fix by hand:

```bash
sudo chown zombie:zombie /opt/ai-zombie/secrets/env
sudo chmod 600 /opt/ai-zombie/secrets/env
sudo systemctl restart ubuntu-zombie-chat.service
```

## Chat service will not start

```bash
systemctl status ubuntu-zombie-chat.service
journalctl -u ubuntu-zombie-chat.service -n 200 --no-pager
```

Typical causes:

- Missing provider token. Add one with
  `sudo /opt/ai-zombie/bin/secrets-edit` (or `sudo secrets-edit`).
  `doctor` looks for any of `OPENAI`, `ANTHROPIC`, `GEMINI`, `XAI`,
  `OPENROUTER`, `MISTRAL`, `GROQ` `_API_KEY=`.
- Port `7878` taken. Override by setting `ZOMBIE_CHAT_PORT` in
  `secrets/env`; the systemd unit ships `Environment=ZOMBIE_CHAT_PORT=7878`
  as a fallback so the service still starts when `secrets/env` is
  missing or empty.
- Bad permissions on `secrets/env` (see above).
- `pi-mono` runtime configs missing under `/opt/ai-zombie/pi/`. Run
  `sudo ./scripts/install.sh repair` to re-render them from the
  packaged templates.

## "What did the AI just do?"

```bash
/opt/ai-zombie/bin/audit-recent           # last 25 entries
/opt/ai-zombie/bin/audit-recent --all     # full log
sudo less /var/log/ubuntu-zombie/audit.log
```

`audit-recent` is also reachable on `PATH` as `audit-recent`.
Companion shortcuts installed by the installer:

| Symlink                            | Target                                      |
|------------------------------------|---------------------------------------------|
| `/usr/local/bin/audit-recent`      | `/opt/ai-zombie/bin/audit-recent`           |
| `/usr/local/bin/secrets-edit`      | `/opt/ai-zombie/bin/secrets-edit`           |
| `/usr/local/bin/zombie-chat`       | `/opt/ai-zombie/bin/zombie-chat`            |
| `/usr/local/bin/zombie-health`     | `/opt/ai-zombie/bin/health-check`           |
| `/usr/local/bin/zombie-diagnostics`| `/opt/ai-zombie/bin/collect-diagnostics`    |

The audit log is rotated weekly (8 generations kept) by the
`/etc/logrotate.d/ubuntu-zombie` rule and is created mode `0640`
owned by the agent user.

## Rolling back to the pre-`pi-mono` chat service

The chat service drives the [`pi-mono`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
agent loop through `payload/agent/pi-mono-bridge.mjs`. The version is
pinned by `payload/agent/pi-mono.version` and the install snapshots
`state/conversations.db` before running the additive schema migration.
To roll back:

1. **Stop the chat service** so nothing writes to history:
   ```bash
   sudo systemctl stop ubuntu-zombie-chat.service
   ```
2. **Restore the pre-migration snapshot.** The installer copies
   `state/conversations.db` to `state/conversations.db.bak.<ts>`
   *before* the chat service runs the migration. Pick the most recent
   timestamp and restore it:
   ```bash
   sudo ls /opt/ai-zombie/state/conversations.db.bak.*
   sudo cp -a /opt/ai-zombie/state/conversations.db.bak.<ts> \
              /opt/ai-zombie/state/conversations.db
   ```
3. **Pin `pi-mono` to a different release** (or remove it entirely):
   ```bash
   sudo npm uninstall -g @earendil-works/pi-coding-agent
   # or, to roll forward instead of back:
   sudo npm install -g @earendil-works/pi-coding-agent@<version>
   ```
4. **Check out the previous payload** in `git` and re-run
   `sudo ./scripts/install.sh repair`. The chat service comes back up
   against the restored DB and the previously pinned binary.

`pi-mono` bridge logs live under
`/opt/ai-zombie/state/logs/pi-mono.*.log` (one file per service start
and turn; rotated daily, 14 generations kept by
`/etc/logrotate.d/ubuntu-zombie`). They are the first thing to inspect
when an `operator_approval_required` error appears unexpectedly, when
a `budget_exceeded:` observation is emitted, or when the bridge exits
without emitting `final`. Per-session scratch space lives under
`/opt/ai-zombie/state/pi-mono-sessions/`.

## Non-interactive install fails immediately

`ZOMBIE_NONINTERACTIVE=1` requires `SSH_PUBLIC_KEY` and `VNC_PASSWORD`
to be set when neither is already configured on disk. Exit code `64`
indicates missing required environment. Exit code `2` indicates a bad
argument (for example a non-integer `ZOMBIE_CHAT_PORT`); exit code
`65` indicates an incompatible host, and `66` a network preflight
failure.

## Collect a diagnostic bundle for a bug report

```bash
sudo /opt/ai-zombie/bin/collect-diagnostics    # or: sudo zombie-diagnostics
# produces /tmp/ubuntu-zombie-diagnostics-YYYYMMDD-HHMMSS.tar.gz
```

The bundle captures `os-release`, `uname`, disk and memory snapshots,
`systemctl status` for the chat service and health timer, recent
journal output for `ubuntu-zombie-chat` and `tailscaled`, `tailscale
status`, `ufw status verbose`, Docker `version`/`info`, the verify and
health-check transcripts, the installer log, the (already-redacted)
audit log, `/etc/ubuntu-zombie/policy.yaml`, and a `dpkg -l` for the
core packages. Token-shaped values (`sk-…`, `sk-ant-…`, `tskey-…`,
SSH public keys, `API_KEY`/`TOKEN`/`PASSWORD`/`SECRET` lines) are
redacted before the bundle is written; please still review the
contents before sharing.
