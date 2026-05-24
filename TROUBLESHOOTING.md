# Troubleshooting

Common failures and the fastest fixes. Start with:

```bash
/opt/ai-zombie/bin/health-check
sudo ./setup-part-1.sh doctor
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
sudo ./setup-part-1.sh install   # safe to re-run
```

## Tailscale will not log in

```bash
sudo tailscale up                    # follow the URL it prints
# or, unattended:
sudo TAILSCALE_AUTHKEY=tskey-auth-… ./setup-part-1.sh repair
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
  log in graphically as `agent` first.
- Check `DISPLAY`: `/opt/ai-zombie/bin/gui-env env | grep DISPLAY`.
- Verify the session is Xorg, not Wayland:
  `loginctl show-session "$XDG_SESSION_ID" -p Type`.
- If Wayland is active, re-run `sudo ./setup-part-1.sh repair` and
  log out / log back in.

## Playwright complains about missing libraries

`python -m playwright install --with-deps chromium` was interrupted.
Re-run:

```bash
sudo -iu agent
. ~/agent-env/bin/activate
python -m playwright install --with-deps chromium
```

## VNC

- Cannot connect: confirm the SSH tunnel
  `ss -ltn 'sport = :5900'` should show `127.0.0.1:5900`.
- Forgot the password: `sudo -u agent x11vnc -storepasswd`.
- Black screen: the desktop session is not running. With autologin
  disabled, log in physically as `agent` once.

## Secrets file permissions

The chat service refuses to start if `/opt/ai-zombie/secrets/env` is
group- or world-readable. Reassert:

```bash
sudo chown agent:agent /opt/ai-zombie/secrets/env
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
