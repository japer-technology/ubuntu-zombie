# Quickstart

Beep installs a local AI Systems Administrator account and a
password-protected chat service bound to `127.0.0.1`. It does not install
or configure SSH, Tailscale, VNC, Docker, graphical autologin, or GUI
browser automation.

## Before you start

Use a disposable Ubuntu Desktop LTS machine. The installer creates a
root-capable local account, sudoers policy, systemd units, logs, and
state under `/opt/beep`.

You need:

- sudo access on the target machine;
- network access to Ubuntu apt repositories, NodeSource, npm, and your
  selected LLM provider;
- an optional chat password to replace the default;
- an LLM provider API key to add after installation.

## Install

From the repository root:

```bash
sudo ./scripts/install.sh install
```

This is equivalent to the explicit component form
`sudo ./scripts/install.sh install beep`. The canonical grammar is
`scripts/install.sh <verb> [component ...] [flags]`; valid component
targets are `beep`, `forgejo`, `forgejo-runner`, and `llama`.

Interactive installs open a parameter review before changing the host.
Accept the defaults or edit the agent user, install root, chat port,
chat password, Time to Live, receipt path, and local LLM settings.

### Install Forgejo without beep

To install only Forgejo and PostgreSQL:

```bash
sudo ./scripts/install.sh install forgejo
```

This path does not create a root-capable beep account or install the
agent, Node runtime, policy, audit log, chat services, or desktop power
settings. It keeps only installer-owned transcript and receipt records
under `/var/log/`. Generated Forgejo credentials are recorded in the
root-only receipt. It also installs Avahi and Caddy: Forgejo listens on
loopback, while Caddy serves
`https://<lowercase-machine-hostname>.local/` with a locally issued
certificate.

Before opening Forgejo from another LAN device, copy
`/etc/forgejo/caddy-local-ca.crt` from the host over an authenticated
channel and import it into that device's trusted root certificate store.
See [Configuration](CONFIGURATION.md#trust-the-forgejo-local-certificate-authority)
for the trust and removal guidance.

To install both components in registry order:

```bash
sudo ./scripts/install.sh install beep forgejo
```

The legacy `BEEP_INSTALL_FORGEJO=1 ./scripts/install.sh install` form
remains equivalent to that combined command.

To install Forgejo with its co-located Actions runner:

```bash
sudo ./scripts/install.sh install forgejo-runner
```

The runner target automatically selects the required `forgejo` component.
It does not select or install the beep account and runtime.

### Install standalone llama.cpp without beep

To install a CPU local model for applications and users on this PC:

```bash
sudo ./scripts/install.sh install llama
beep-llama-manager status
```

This independent component exposes an OpenAI-compatible API only at
`http://127.0.0.1:8080/v1`. It does not create or modify the Beep
account or runtime.

For unattended installs:

```bash
sudo BEEP_NONINTERACTIVE=1 \
     BEEP_ADMIN_PASSWORD='replace-me' \
     ./scripts/install.sh install --yes
```

## Parameters required to allow the install to proceed

| Parameter | Default | Required |
| --------- | ------- | -------- |
| `BEEP_USER` | `beep` | No |
| `BEEP_DIR` | `/opt/beep` | No |
| `BEEP_CHAT_PORT` | `7878` | No |
| `BEEP_ADMIN_PASSWORD` | `braaaains` | No |
| `BEEP_TTL_DAYS` | `7` | No |
| `BEEP_RECEIPT_FILE` | `/var/log/beep/install-receipt.txt` | No |
| `BEEP_LOCAL_LLM_MODE` | `auto` | No |

## Add an LLM provider key

After install, edit the secrets file:

```bash
sudo /opt/beep/bin/beep-secrets-edit
```

Set the provider variables documented in
[`CONFIGURATION.md`](CONFIGURATION.md#llm-provider-configuration), then
restart the service:

```bash
sudo systemctl restart beep-chat.service
```

## Open chat

On the Beep desktop, open:

```text
http://127.0.0.1:7878/
```

or run:

```bash
/opt/beep/bin/beep-chat
```

The service is intentionally loopback-only. If you need remote access,
bring your own remote-access mechanism outside Beep.

## Verify, doctor, repair

```bash
sudo ./scripts/install.sh verify
sudo ./scripts/install.sh doctor
sudo ./scripts/install.sh repair

# Optional explicit component targets:
sudo ./scripts/install.sh verify beep
sudo ./scripts/install.sh doctor forgejo
```

- `verify` is read-only.
- `doctor` explains likely fixes.
- `repair` re-asserts permissions, re-renders runtime config, redeploys
  built-in skills, and restarts the chat service.

## Health and diagnostics

```bash
/opt/beep/bin/beep-health
/opt/beep/bin/beep-diagnostics
```

Diagnostics are redacted before being bundled.

## Uninstall

```bash
# Remove everything (default):
sudo ./scripts/install.sh uninstall

# Remove only the beep account and runtime, leave Forgejo running:
sudo ./scripts/install.sh uninstall beep

# Remove only the Forgejo component, leave beep running:
sudo ./scripts/install.sh uninstall forgejo

# Remove only the Forgejo Actions runner:
sudo ./scripts/install.sh uninstall forgejo-runner
```

Selective uninstall targets only the named component. `--archive` and
`--keep-agent` are valid only when the `beep` component is being
removed.

The uninstaller removes Beep services, sudoers entries,
payload files, policy, logrotate rules, and optionally the agent account
and archives. Shared packages such as Node and Python are left alone.
