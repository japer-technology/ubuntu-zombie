# Quickstart

The shortest safe path from a fresh Ubuntu Desktop LTS install to a
working private chat with the AI Systems Administrator.

Total wall time: roughly 15–30 minutes, mostly waiting for `apt` and
`playwright install`.

---

## 0. Before you start

You need:

- A physical Ubuntu Desktop **22.04 LTS** or **24.04 LTS** machine,
  freshly installed and updated.
- A Tailscale account and a [pre-auth key](https://login.tailscale.com/admin/settings/keys)
  (recommended) or a working browser to log in interactively.
- One SSH public key (`ssh-ed25519 …` is preferred) from the machine
  you will use to control this PC.
- One LLM API key from a supported provider:
  - `OPENAI_API_KEY=sk-…`, or
  - `ANTHROPIC_API_KEY=sk-ant-…`
- A keyboard physically attached to the PC for the first run.

Do **not** run the installer over a public SSH session. The installer
restarts `sshd` and tightens the firewall; you can lock yourself out.

---

## 1. Install

```bash
git clone https://github.com/japer-technology/ubuntu-zombie.git
cd ubuntu-zombie
chmod +x setup-part-1.sh
sudo ./setup-part-1.sh install
```

Non-interactive variant (CI, fleet provisioning, scripted re-install):

```bash
sudo ZOMBIE_NONINTERACTIVE=1 \
     SSH_PUBLIC_KEY="ssh-ed25519 AAAA… you@workstation" \
     VNC_PASSWORD="replace-me" \
     TAILSCALE_AUTHKEY="tskey-auth-…" \
     ZOMBIE_ENABLE_AUTOLOGIN=0 \
     ./setup-part-1.sh install
```

Re-running `install` is safe. The script is idempotent.

## 2. Reboot

```bash
sudo reboot
```

A reboot is required so the new desktop session, GDM autologin choice,
and Docker group membership take effect.

## 3. Verify

After reboot, log in as `agent` (or SSH in over Tailscale) and run:

```bash
/opt/ai-zombie/bin/verify
```

You should see a green block of `[ok]` checks. Anything red is
explained by:

```bash
/opt/ai-zombie/bin/health-check
sudo ./setup-part-1.sh doctor
```

## 4. Add an API key

```bash
sudo /opt/ai-zombie/bin/secrets-edit
```

Uncomment one of the provider lines and paste your key:

```
OPENAI_API_KEY=sk-…
# or
ANTHROPIC_API_KEY=sk-ant-…
ZOMBIE_PROVIDER=openai   # or anthropic
```

Restart the chat service:

```bash
sudo systemctl restart ubuntu-zombie-chat.service
```

## 5. Start chat

Locally:

```
http://127.0.0.1:7878/
```

Remotely over Tailscale (SSH tunnel; the chat never binds to a public
interface):

```bash
ssh -L 7878:127.0.0.1:7878 agent@<tailscale-name-or-ip>
# then open http://127.0.0.1:7878/ in your local browser
```

## 6. Ask a diagnostic question

Try one of the safe examples shipped with the chat:

- "Explain this machine."
- "Check whether updates are available."
- "Why is Docker not usable yet?"
- "Show recent failed systemd services."

Read-only questions are answered without prompting for approval.

## 7. Approve a safe command

When the assistant proposes a command in a non-read-only class, the UI
shows a clearly labelled approval card. Approve it and the command runs
as `agent` and is logged.

## 8. Inspect the audit log

```bash
/opt/ai-zombie/bin/audit-recent
```

You will see a JSON-lines summary of prompts, proposed actions,
approvals, commands, exit codes, and verification results. Secrets are
redacted.

## 9. Stop or revoke

Temporarily stop the agent:

```bash
sudo systemctl stop ubuntu-zombie-chat.service
```

Revoke the provider:

```bash
sudo /opt/ai-zombie/bin/secrets-edit   # remove or comment out the key
sudo systemctl restart ubuntu-zombie-chat.service
```

The chat UI will then refuse to send new prompts to a provider.

## 10. Uninstall or keep running

Keep running: do nothing.

Uninstall:

```bash
sudo ./setup-part-1.sh uninstall --dry-run   # preview
sudo ./setup-part-1.sh uninstall              # remove
sudo ./setup-part-1.sh uninstall --archive    # remove and archive /home/agent
```

Uninstall removes the chat service, sudoers drop-in, SSH drop-in,
x11vnc autostart, generated helpers, and (with confirmation) the
`agent` user. It does not delete user data without explicit
confirmation.

---

See [`CONFIGURATION.md`](CONFIGURATION.md) for everything you can
tune, [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for failure modes,
and [`SECURITY.md`](SECURITY.md) for the trust model.
