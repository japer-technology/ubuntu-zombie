# Troubleshooting

Common failures and the fastest fixes. Start with:

```bash
/opt/ai-zombie/bin/health-check
sudo ./scripts/install.sh doctor
```

`doctor` describes what is wrong; `repair` fixes known safe drift.

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

The chat service refuses to start if `/opt/ai-zombie/secrets/env` is
group- or world-readable. Reassert:

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

- Missing API key. Add one with
  `sudo /opt/ai-zombie/bin/secrets-edit`.
- Port `7878` taken. Set `ZOMBIE_CHAT_PORT` in `secrets/env`.
- Bad permissions on `secrets/env` (see above).

## "What did the AI just do?"

```bash
/opt/ai-zombie/bin/audit-recent           # last 25 entries
/opt/ai-zombie/bin/audit-recent --all     # full log
sudo less /var/log/ubuntu-zombie/audit.log
```

## Rolling back the Phase 2 pi-mono cutover

Phase 2 of [`docs/UPGRADE-TO-PI-PLAN.md`](UPGRADE-TO-PI-PLAN.md)
replaced the fenced-bash parser with the `pi-mono` agent loop and
migrated the conversations schema. The cutover is reversible:

1. **Stop the chat service** so nothing writes to history:
   ```bash
   sudo systemctl stop ubuntu-zombie-chat.service
   ```
2. **Restore the pre-migration snapshot.** The installer copies
   `state/conversations.db` to `state/conversations.db.bak.<ts>` *before*
   running the additive schema migration. Pick the most recent
   timestamp and restore it:
   ```bash
   sudo ls /opt/ai-zombie/state/conversations.db.bak.*
   sudo cp -a /opt/ai-zombie/state/conversations.db.bak.<ts> \
              /opt/ai-zombie/state/conversations.db
   ```
3. **Pin pi-mono to the previous release** (or remove it entirely):
   ```bash
   sudo npm uninstall -g @earendil-works/pi-coding-agent
   # or, to roll forward instead of back:
   sudo npm install -g @earendil-works/pi-coding-agent@<previous-version>
   ```
4. **Check out the previous payload** (the Phase 1 tag in `git`) and
   re-run `sudo ./scripts/install.sh repair`. The chat service will
   come back up against the restored DB and the previous binary.

Pi-mono bridge logs live under `/opt/ai-zombie/state/logs/pi-mono.*.log`
(rotated daily, kept 14 days). They are the first thing to inspect
when an `operator_approval_required` failure appears unexpectedly or
when the bridge exits without emitting `final`.

## Non-interactive install fails immediately

`ZOMBIE_NONINTERACTIVE=1` requires `SSH_PUBLIC_KEY` and `VNC_PASSWORD`
to be set when neither is already configured on disk. Exit code `64`
indicates missing required environment.

## Collect a diagnostic bundle for a bug report

```bash
sudo /opt/ai-zombie/bin/collect-diagnostics
# produces /tmp/ubuntu-zombie-diagnostics-YYYYMMDD-HHMMSS.tar.gz
```

Secrets are redacted before the bundle is written.
