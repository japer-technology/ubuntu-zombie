# Security

Ubuntu Zombie installs a privileged AI Systems Administrator on a
normal Ubuntu PC. This is a meaningful security posture and you should
read it before running the installer.

## Trust boundary

The operator owns:

- the physical machine,
- the SSH private key,
- the Tailscale account,
- the LLM provider account and API key,
- `/opt/ai-zombie/secrets/env`.

The token provider (cloud LLM vendor) authenticates the AI Systems
Administrator. The provider does **not** own the machine.

The `agent` Linux user is the operating identity of the AI Systems
Administrator. `agent` holds passwordless `sudo` and is in the
`docker` group. Any compromise of `agent`, of the provider API key,
or of the SSH private key is equivalent to root on the machine.

Treat these four credentials with root-level care:

- the SSH private key authorised in `~agent/.ssh/authorized_keys`;
- the LLM provider API key in `/opt/ai-zombie/secrets/env`;
- the Tailscale account and tailnet;
- the VNC password (loopback-only but still a credential).

## What the provider sees

The chat service sends to the provider:

- the operator's typed prompts;
- the current conversation history;
- selected local context (e.g. `uname`, package versions, summarised
  command output) that the assistant explicitly chose to include.

The provider may see, in summarised form, the **output** of commands
the assistant runs on the machine. Treat the provider as a third
party with read access to whatever local state the assistant decides
to share with it.

The provider does not see:

- the LLM API key beyond your own account scope;
- the SSH private key;
- the VNC password;
- the Tailscale auth key;
- files under `/opt/ai-zombie/secrets/`;
- audit log contents (the audit log is local-only).

## What the `agent` user can do

- Run any command as root via `sudo`, without a password prompt.
- Read and write any file the desktop session can reach.
- Drive Xorg via `xdotool`, screenshot via `gnome-screenshot`/`scrot`.
- Operate Chromium through Playwright.
- Manage Docker images, containers, networks, and volumes.
- Listen on `127.0.0.1` for the chat UI.

The MVP adds a policy gate (`/etc/ubuntu-zombie/policy.yaml`) and an
approval flow between the AI and `sudo`. Read-only diagnostics run
automatically; everything else requires approval; destructive actions
require a confirmation phrase. See `ARCHITECTURE.md` for the classes.

## Network exposure

- UFW default: deny inbound, allow outbound.
- SSH (port 22): allowed on `tailscale0` only.
- VNC (port 5900): bound to `127.0.0.1` only.
- Chat (default port 7878): bound to `127.0.0.1` only.
- Tailscale SSH (`tailscale up --ssh`) is **not** enabled by the
  installer; ingress goes through the standard `sshd` so audit
  trails follow Ubuntu conventions.

To use the chat or VNC remotely, SSH-tunnel the port over Tailscale.

## Rotating credentials

| Credential          | How to rotate                                   |
| ------------------- | ----------------------------------------------- |
| LLM provider key    | `sudo /opt/ai-zombie/bin/secrets-edit`, then `systemctl restart ubuntu-zombie-chat` |
| SSH public key      | Edit `~agent/.ssh/authorized_keys`, then `systemctl restart ssh` |
| Tailscale enrolment | `sudo tailscale logout && sudo tailscale up`   |
| VNC password        | `sudo -u agent x11vnc -storepasswd`             |

## Revoking the agent

Minimum: remove every provider API key, then restart the chat
service. The chat will load but refuse to reach a provider.

Stronger: `sudo systemctl disable --now ubuntu-zombie-chat.service`.

Strongest: `sudo ./scripts/setup-part-1.sh uninstall`. The uninstaller removes
the chat service, sudoers drop-in, SSH drop-in, x11vnc autostart, and
generated helpers, optionally removing the `agent` user and archiving
state.

## Known risks

- **Passwordless sudo.** Intentional, but it means compromise of
  `agent` is compromise of root. Mitigated by Tailscale-only ingress,
  key-only SSH, policy gate, and audit logging.
- **Docker group access.** `agent` is in `docker`, which is
  effectively root. The policy classifies `docker` commands as
  `system_change` or `destructive` depending on the verb.
- **Desktop automation.** With autologin disabled (the default), the
  desktop session must be unlocked before `xdotool` works. With
  `ZOMBIE_ENABLE_AUTOLOGIN=1`, anyone with physical access has a
  pre-unlocked desktop. Do not enable autologin on portable machines
  unless you understand the trade-off.
- **VNC.** Even on `127.0.0.1`, anyone who can reach the loopback
  socket (i.e. has shell access on the box) can drive the desktop.
- **Cloud provider trust.** Prompts and selected machine state cross
  to the provider. Sensitive files should not be opened or summarised
  through the chat.
- **API cost.** Long sessions can become expensive. The first-run UI
  warns about this.
- **Provider prompt injection.** The provider's output is executed
  only through the approval gate; review proposed commands before
  approving.

## Audit and observability

- `/var/log/ubuntu-zombie/audit.log` — JSON-lines record of prompts,
  proposed actions, approvals, commands, exit codes, and verification
  results. Rotated by `logrotate`. Secrets are redacted at write
  time.
- `/opt/ai-zombie/bin/audit-recent` — quick view of recent activity.
- `/opt/ai-zombie/bin/health-check` — one-shot health summary.
- `/opt/ai-zombie/bin/collect-diagnostics` — bundle for bug reports;
  secrets are redacted.

## Responsible disclosure

Please report security issues privately to the maintainers of this
repository via a GitHub Security Advisory:

<https://github.com/japer-technology/ubuntu-zombie/security/advisories/new>

Do not file public issues for vulnerabilities. A 90-day coordinated
disclosure window is the default.
