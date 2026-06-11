# Frequently asked questions

Distilled from [TROUBLESHOOTING.md](TROUBLESHOOTING.md),
[SECURITY.md](../SECURITY.md), and the issue tracker. If you do not
see your question here, please open a
[Discussion](https://github.com/japer-technology/ubuntu-zombie/discussions)
or read the linked doc.

## What is Ubuntu Zombie?

A single installer that adds a private, root-capable AI Systems
Administrator account to a supported Ubuntu Desktop LTS machine, so
the operator can ask the machine to diagnose, explain, configure,
repair, and operate itself.

The full pitch is in [`docs/VISION.md`](VISION.md). The component
map is in [`docs/ARCHITECTURE.md`](ARCHITECTURE.md).

## Who is this for?

A single operator who owns the physical machine, wants to delegate
routine sysadmin to an LLM, and is comfortable granting the LLM
passwordless `sudo` behind a local approval gate, an audit log, and
key-only SSH (optionally confined to a Tailscale-only inbound network
surface).

## What does the LLM see?

Only what the agent sends to it: your prompts, the tool calls it has
made on this turn, and the (redacted) observations. Secrets are
filtered out by `payload/agent/audit.py`'s redaction rules before
they reach the model. See [`SECURITY.md`](../SECURITY.md).

## Does the AI run *anything* without me approving it?

Read-only commands run without approval. Anything classified as
`user_change`, `system_change`, `network_change`, or `destructive`
goes through a local policy gate and asks you to approve in the chat
UI before `sudo` executes. The default for unknown commands is
`destructive` (fail-closed). See `payload/etc/policy.yaml` and
`docs/ARCHITECTURE.md` § policy gate.

## Can I run this on Debian / Pop!_OS / Mint?

No. See [`docs/PLATFORMS.md`](PLATFORMS.md).

## Can I run this on Ubuntu Server?

The installer will technically run, but the desktop / GUI tool stack
will be unused. It is not supported. See
[`docs/PLATFORMS.md`](PLATFORMS.md).

## Can I run this without Tailscale?

Yes — that is the default. Tailscale is off unless you opt in with
`ZOMBIE_SKIP_TAILSCALE=0`. With the default, SSH is allowed on every
interface, but it is key-only and root-disabled; that is suitable
behind a network perimeter you control. To confine inbound SSH to a
private tailnet, install with `ZOMBIE_SKIP_TAILSCALE=0`. See
[`docs/CONFIGURATION.md`](CONFIGURATION.md).

## How do I preview what `install.sh` will do?

```bash
sudo ./scripts/install.sh install --dry-run
```

The installer prints the agent user, install root, package groups,
file paths, and firewall rules, then exits. Nothing on the host is
changed. See [`docs/UPGRADING.md`](UPGRADING.md) for the upgrade flow.

## How do I upgrade between versions?

```bash
cd ubuntu-zombie
git pull
sudo ./scripts/install.sh install
sudo systemctl restart ubuntu-zombie-chat.service
```

`install` is idempotent. Breaking changes are called out in
[`CHANGELOG.md`](../CHANGELOG.md) and
[`docs/UPGRADING.md`](UPGRADING.md).

## My API key broke after editing — how do I recover?

`secrets-edit` writes a timestamped backup of `secrets/env` under
`/opt/ai-zombie/secrets/backups/` before invoking your editor. The
ten most recent backups are kept. To restore:

```bash
sudo ls -1t /opt/ai-zombie/secrets/backups/
sudo cp -a /opt/ai-zombie/secrets/backups/env.<ts> /opt/ai-zombie/secrets/env
sudo chown zombie:zombie /opt/ai-zombie/secrets/env
sudo chmod 600 /opt/ai-zombie/secrets/env
sudo systemctl restart ubuntu-zombie-chat.service
```

## How do I uninstall?

```bash
sudo ./scripts/uninstall.sh           # interactive
sudo ./scripts/uninstall.sh --archive # back up /home/zombie and /opt/ai-zombie/state first
sudo ./scripts/uninstall.sh --dry-run # preview only
```

`uninstall.sh` deliberately does **not** remove Docker, Tailscale,
Node.js, Python, or other shared base packages — those are normal
Ubuntu software other things may depend on.

## How do I verify a downloaded release tarball?

Each GitHub Release includes a `SHA256SUMS` file and per-artifact
cosign signature. See the release notes for the exact
`cosign verify-blob` invocation, or:

```bash
sha256sum -c SHA256SUMS
cosign verify-blob \
  --certificate ubuntu-zombie-<ver>.tar.gz.pem \
  --signature   ubuntu-zombie-<ver>.tar.gz.sig \
  --certificate-identity-regexp 'https://github.com/japer-technology/ubuntu-zombie/.+' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ubuntu-zombie-<ver>.tar.gz
```

## Where do I report bugs / ask questions / report security issues?

See [`SUPPORT.md`](../SUPPORT.md).
