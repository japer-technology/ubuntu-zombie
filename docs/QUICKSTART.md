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
- One SSH public key (`ssh-ed25519 …` is preferred) from the machine
  you will use to control this PC.
- A VNC password you choose, for emergency loopback-only desktop access
  over an SSH tunnel.
- One LLM API key from a supported provider (added **after** install in
  step 4, not required to start the installer). All providers are routed
  through `@earendil-works/pi-ai`; pick exactly one:
  - `OPENAI_API_KEY=sk-…`
  - `ANTHROPIC_API_KEY=sk-ant-…`
  - `GEMINI_API_KEY=…`
  - `XAI_API_KEY=…`
  - `OPENROUTER_API_KEY=…` (also requires `ZOMBIE_MODEL=…`)
  - `MISTRAL_API_KEY=…`
  - `GROQ_API_KEY=…`

  **Or no cloud key at all:** if you run a local OpenAI-compatible LLM
  server (LM Studio, Ollama, `llama.cpp`) on your LAN, the interactive
  installer auto-detects it and offers its models as the starting model
  — see [Optional: use a local LLM (auto-detected on your
  LAN)](#optional-use-a-local-llm-auto-detected-on-your-lan) in step 1.
- A keyboard physically attached to the PC for the first run.
- **Optional:** a Tailscale account and a [pre-auth key](https://login.tailscale.com/admin/settings/keys).
  Tailscale is **off by default**. Opt in with `ZOMBIE_SKIP_TAILSCALE=0`
  to restrict inbound SSH to your tailnet (see step 1).

### Parameters required to allow the install to proceed

The installer only needs two inputs from you before it will run to
completion. In an interactive run it prompts for both; in a
non-interactive run (`ZOMBIE_NONINTERACTIVE=1`) you must supply them as
environment variables unless they are already configured on disk:

| Parameter        | How it is supplied                                                       | Required |
| ---------------- | ------------------------------------------------------------------------ | -------- |
| `SSH_PUBLIC_KEY` | Prompted interactively, or set as an env var. Skippable interactively if a key is already authorized; mandatory in non-interactive mode when no key exists. | Yes      |
| `VNC_PASSWORD`   | Prompted interactively, or set as an env var. Mandatory in non-interactive mode when no VNC password is already stored. | Yes      |

Everything else has a safe default:

| Parameter                | Default        | Purpose                                                            |
| ------------------------ | -------------- | ------------------------------------------------------------------ |
| `ZOMBIE_USER`            | `zombie`       | Name of the local AI Systems Administrator account.                |
| `ZOMBIE_SKIP_TAILSCALE`  | `1` (off)      | Set to `0` to install/enrol Tailscale and restrict SSH to it.      |
| `TAILSCALE_AUTHKEY`      | *(unset)*      | Pre-auth key for unattended Tailscale; used only when `ZOMBIE_SKIP_TAILSCALE=0`. |
| `ZOMBIE_ENABLE_AUTOLOGIN`| `0` (off)      | Set to `1` to enable graphical autologin for the agent account.    |
| `ZOMBIE_CHAT_PORT`       | `7878`         | Loopback port for the chat UI.                                     |

An LLM API key is **not** required to run the installer; you add it in
step 4 after the first reboot.

Do **not** run the installer over a public SSH session. The installer
restarts `sshd` and tightens the firewall; you can lock yourself out.

### How to get an SSH key

If you do not already have an SSH key on the workstation you will use
to control this PC, generate one there (not on the Ubuntu Zombie box):

```bash
ssh-keygen -t ed25519 -C "you@workstation"
```

Accept the default path (`~/.ssh/id_ed25519`) and pick a passphrase.
Two files are created:

- `~/.ssh/id_ed25519` — the **private** key. Never copy this off the
  workstation and never paste it into the installer.
- `~/.ssh/id_ed25519.pub` — the **public** key. This is the single
  line (starting with `ssh-ed25519 …`) that you pass to the installer
  as `SSH_PUBLIC_KEY` or paste when the interactive installer asks.

Print the public key so you can copy it:

```bash
cat ~/.ssh/id_ed25519.pub
```

On macOS you can pipe it straight to the clipboard:

```bash
pbcopy < ~/.ssh/id_ed25519.pub
```

On a Linux workstation with `xclip` or `wl-copy`:

```bash
xclip -selection clipboard < ~/.ssh/id_ed25519.pub   # X11
wl-copy < ~/.ssh/id_ed25519.pub                       # Wayland
```

If you already manage keys through GitHub, any key listed at
<https://github.com/settings/keys> works; fetch them with
`curl https://github.com/<your-username>.keys` and pick the
`ssh-ed25519 …` line you recognise.

Older RSA keys (`ssh-rsa …`, 3072-bit or larger) are accepted, but
`ed25519` is preferred: shorter, faster, and the default on modern
OpenSSH.

---

## 1. Install

```bash
git clone https://github.com/japer-technology/ubuntu-zombie.git
cd ubuntu-zombie
chmod +x scripts/install.sh
sudo ./scripts/install.sh install
```

Non-interactive variant (CI, fleet provisioning, scripted re-install):

```bash
sudo ZOMBIE_NONINTERACTIVE=1 \
     ZOMBIE_USER=zombie \
     SSH_PUBLIC_KEY="ssh-ed25519 AAAA… you@workstation" \
     VNC_PASSWORD="replace-me" \
     ZOMBIE_ENABLE_AUTOLOGIN=0 \
     ./scripts/install.sh install
```

`SSH_PUBLIC_KEY` and `VNC_PASSWORD` are the only inputs the installer
requires to proceed (see [Parameters required to allow the install to
proceed](#parameters-required-to-allow-the-install-to-proceed) above).
In non-interactive mode they must be set unless a key/password is
already configured on disk.

`ZOMBIE_USER` is optional; omit it to get the default account name
`zombie`. Set it to any valid local username if you would rather the
AI Systems Administrator live in (for example) `admin` or `ai`.

Tailscale is **off by default**: the installer does not install or
enrol it, and inbound SSH is allowed on every interface (still
key-only, root-disabled). To opt in — install and enrol Tailscale and
restrict inbound SSH to the `tailscale0` interface — set
`ZOMBIE_SKIP_TAILSCALE=0`:

```bash
# interactive enrolment (opens a browser login URL):
sudo ZOMBIE_SKIP_TAILSCALE=0 ./scripts/install.sh install

# unattended enrolment with a pre-auth key:
sudo ZOMBIE_NONINTERACTIVE=1 \
     ZOMBIE_SKIP_TAILSCALE=0 \
     SSH_PUBLIC_KEY="ssh-ed25519 AAAA… you@workstation" \
     VNC_PASSWORD="replace-me" \
     TAILSCALE_AUTHKEY="tskey-auth-…" \
     ./scripts/install.sh install
```

Re-running `install` is safe. The script is idempotent. If something
drifts later (file permissions, missing service, dropped Tailscale
session), run:

```bash
sudo ./scripts/install.sh repair
```

### Optional: use a local LLM (auto-detected on your LAN)

During an **interactive** install (not `--yes`, not
`ZOMBIE_NONINTERACTIVE=1`, and on a real TTY) the installer scans the
host's IPv4 `/24` — all 256 addresses — for an OpenAI-compatible local
LLM server answering on `http://<ip>:1234/v1`. Servers such as
[LM Studio](https://lmstudio.ai/) (which listens on port `1234` by
default), Ollama, and `llama.cpp` are detected automatically. Any
models the responders advertise are listed in the parameter-review
step, where you can pick one as the **starting model** (or skip and
configure a cloud provider later).

When you select a discovered model, the installer records it as the
`lmstudio` provider — writing `ZOMBIE_PROVIDER=lmstudio`,
`ZOMBIE_MODEL=<model id>`, and `LMSTUDIO_API_KEY` into
`/opt/ai-zombie/secrets/env`, and the server URL into the agent's
`~/.pi/agent/models.json` — so the box can answer entirely offline with
**no cloud API key**. You can skip step 4 (Add an API key) in that case.

Knobs:

- `ZOMBIE_SKIP_LLM_SCAN=1` — skip the LAN scan entirely.
- `ZOMBIE_LLM_SCAN_PORT=<port>` — probe a different port (default
  `1234`, LM Studio's default).
- `ZOMBIE_LOCAL_LLM_API_KEY=<key>` — record a non-default key for the
  local server (most local servers ignore it).

The scan is best-effort, needs `curl` and `python3` (both already
required by the product), and is skipped automatically on `--yes`,
non-interactive, and non-TTY runs. Full details are in
[`CONFIGURATION.md`](CONFIGURATION.md#local-llm-discovery-lan-scan).

### Upgrade / refresh from GitHub

The same `install` subcommand is also the upgrade path. There is no
separate `upgrade` command — pulling the latest source and re-running
`install` is the supported way to move to a newer version, and it is
also the inner loop while debugging a problem you have just fixed
upstream:

```bash
cd ubuntu-zombie
git pull                                   # refresh from GitHub
sudo ./scripts/install.sh install          # re-apply, idempotent
# (or, for a non-interactive box, re-use the same env vars as the
#  initial install — SSH_PUBLIC_KEY, VNC_PASSWORD, etc. are read from
#  the existing /opt/ai-zombie/state on subsequent runs, so usually
#  only ZOMBIE_NONINTERACTIVE=1 is required.)
sudo ZOMBIE_NONINTERACTIVE=1 ./scripts/install.sh install
```

After the re-run, restart the chat service to pick up any new payload
or service-unit changes, then re-verify:

```bash
sudo systemctl restart ubuntu-zombie-chat.service
/opt/ai-zombie/bin/verify
```

A reboot is only required if the upgrade touches kernel packages,
GDM/autologin, or Docker group membership — `verify` will say so. For
a documentation- or payload-only refresh, the restart above is enough.

## 2. Reboot

```bash
sudo reboot
```

A reboot is required so the new desktop session, GDM autologin choice,
and Docker group membership take effect.

## 3. Verify

After reboot, log in as `zombie` (or whatever name you passed via
`ZOMBIE_USER` at install time, or SSH in — over Tailscale if you opted
in, otherwise over your LAN) and run:

```bash
/opt/ai-zombie/bin/verify
```

(The same check is also reachable as `zombie-verify` on `PATH`.)

You should see a green block of `[ok]` checks. Anything red is
explained by:

```bash
/opt/ai-zombie/bin/health-check          # also on PATH as: zombie-health
sudo ./scripts/install.sh doctor
```

To re-apply known-safe fixes (permissions, service restart, Tailscale
re-auth with `TAILSCALE_AUTHKEY`), run:

```bash
sudo ./scripts/install.sh repair
```

## 4. Add an API key

(Skip this step if you selected a local LLM during install — the
`lmstudio` provider is already configured in `secrets/env`. You only
need it to switch to, or add, a cloud provider.)

```bash
sudo /opt/ai-zombie/bin/secrets-edit     # also on PATH as: secrets-edit
```

Uncomment exactly one provider line and paste your key. All providers
are routed through `@earendil-works/pi-ai`:

```
OPENAI_API_KEY=sk-…
# ANTHROPIC_API_KEY=sk-ant-…
# GEMINI_API_KEY=…
# XAI_API_KEY=…
# OPENROUTER_API_KEY=…
# MISTRAL_API_KEY=…
# GROQ_API_KEY=…

# Optional knobs:
ZOMBIE_PROVIDER=openai     # openai|anthropic|gemini|xai|openrouter|mistral|groq|lmstudio
ZOMBIE_MODEL=gpt-4o-mini   # override default model (required for openrouter/lmstudio)
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

(Override the port at install time with `ZOMBIE_CHAT_PORT=<port>`.)

Remotely (SSH tunnel; the chat never binds to a public interface). Use
the host's Tailscale name/IP if you opted in to Tailscale, otherwise its
LAN address:

```bash
ssh -L 7878:127.0.0.1:7878 zombie@<host-name-or-ip>
# then open http://127.0.0.1:7878/ in your local browser
```

## 6. Ask a diagnostic question

Try one of the safe examples shipped with the chat:

- "Explain this machine."
- "Check whether updates are available."
- "Why is Docker not usable yet?"
- "Show recent failed systemd services."

Read-only questions are answered without prompting for approval.

The chat also understands a few client-side commands. Type `/help` to
list them. Highlights:

- `/clear` clears the view; `/new` (alias `/reset`) starts a fresh
  conversation; `/examples` shows the safe example prompts.
- `/tools` lists the agent tools and their risk class; `/health`,
  `/status`, and `/version` report machine facts and versions.
- `/model` lists the models your configured provider offers (the
  current one is marked `*`); `/model <id>` switches to another model
  for the running service.
- `/audit` shows the most recent audit-log entries; `/conversations`
  (alias `/history`) lists past conversations and `/load <id>` reopens
  one; `/shortcuts` lists the keyboard shortcuts.

These commands run in the browser and never reach the agent.

## 7. Approve a safe command

When the assistant proposes a command in a non-read-only class, the UI
shows a clearly labelled approval card. Approve it and the command runs
as the agent account (`zombie` by default) and is logged.

## 8. Inspect the audit log

```bash
/opt/ai-zombie/bin/audit-recent          # also on PATH as: audit-recent
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
sudo ./scripts/uninstall.sh --dry-run      # preview
sudo ./scripts/install.sh uninstall        # remove (interactive)
sudo ./scripts/uninstall.sh --archive      # archive /home/<agent> and
                                           # /opt/ai-zombie/state/ to
                                           # /var/backups/ before removal
sudo ./scripts/uninstall.sh --yes          # skip confirmations
sudo ./scripts/uninstall.sh --keep-agent   # leave the local user in place
```

Flags must be passed to `scripts/uninstall.sh` directly. The
`scripts/install.sh uninstall` subcommand has no flags of its own and
its argument parser will reject any unknown flags (e.g.
`Unknown flag: --dry-run`); use it only for a plain interactive
uninstall.

Uninstall removes the chat service, sudoers drop-in, SSH drop-in,
x11vnc autostart, generated helpers, policy, logrotate rule, and
(with confirmation) the local agent account (`zombie` by default, or
whatever `ZOMBIE_USER` was set to). It intentionally does **not**
remove Docker, Tailscale, Node, Python, or other base packages —
those are normal Ubuntu software that other things may depend on.

---

See [`CONFIGURATION.md`](CONFIGURATION.md) for everything you can
tune, [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for failure modes,
and [`SECURITY.md`](../SECURITY.md) for the trust model.
