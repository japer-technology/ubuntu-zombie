# Ubuntu Zombie

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/japer-technology/ubuntu-zombie/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/japer-technology/ubuntu-zombie/actions/workflows/ci.yml)
[![CodeQL](https://github.com/japer-technology/ubuntu-zombie/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/japer-technology/ubuntu-zombie/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/japer-technology/ubuntu-zombie/badge)](https://securityscorecards.dev/viewer/?uri=github.com/japer-technology/ubuntu-zombie)
[![Latest release](https://img.shields.io/github/v/release/japer-technology/ubuntu-zombie?sort=date)](https://github.com/japer-technology/ubuntu-zombie/releases/latest)
[![Ubuntu LTS 22.04 | 24.04](https://img.shields.io/badge/Ubuntu_LTS-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)](docs/PLATFORMS.md)
[![AI](https://img.shields.io/badge/Assisted-Development-2b2bff?logo=openai&logoColor=white)](https://www.japer.technology)

<p align="center">
  <picture>
    <img src="https://raw.githubusercontent.com/japer-technology/ubuntu-zombie/main/LOGO.png" alt="Ubuntu Zombie" width="500">
  </picture>
</p>

## An AI System Administrator

> **Ubuntu Zombie adds a private, root-capable AI Systems
> Administrator account to supported Ubuntu Desktop LTS machines so an
> owner can ask the machine to diagnose, explain, configure,
> repair, and operate itself.**

It is a normal Ubuntu PC with an administrator inside it. Any local
user can open a private chat, ask the machine to do something, see
exactly what is proposed, approve it, and watch it happen. Everything
the AI does is audit-logged. SSH is key-only and root-disabled;
optionally restrict inbound access to a private Tailscale tailnet by
opting in at install time. The operator owns the machine, the SSH
key, the API key, and the kill switch.

## Quickstart

```bash
git clone https://github.com/japer-technology/ubuntu-zombie.git
cd ubuntu-zombie
chmod +x scripts/install.sh
sudo ./scripts/install.sh install --dry-run   # preview the plan (no changes)
sudo ./scripts/install.sh install
sudo reboot
# after reboot:
/opt/ai-zombie/bin/verify
sudo /opt/ai-zombie/bin/secrets-edit   # add an LLM API key
sudo systemctl restart ubuntu-zombie-chat.service
# open http://127.0.0.1:7878/ locally, or tunnel over SSH:
ssh -L 7878:127.0.0.1:7878 zombie@<host-name-or-ip>
```

The installer needs only two inputs from you to proceed: an
`SSH_PUBLIC_KEY` and a `VNC_PASSWORD`. In short: **the SSH key is how you
log in to the machine remotely** (the installer makes SSH key-only and
disables `root`, so only a computer holding the matching private key can
connect), and **the VNC password protects an emergency, loopback-only
"watch and drive the desktop" service** you reach over an SSH tunnel — it
is not your login password. Both are explained step by step, for people
new to Ubuntu, in
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#what-the-ssh-key-is-for-and-what-the-vnc-password-is-for).
The installer prompts for both
interactively, or reads them from the environment in non-interactive
mode (`ZOMBIE_NONINTERACTIVE=1`). An LLM API key is added *after*
install. Tailscale is **off by default**; opt in with
`ZOMBIE_SKIP_TAILSCALE=0` to restrict inbound SSH to your tailnet. The
full list of inputs and their defaults is in
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#parameters-required-to-allow-the-install-to-proceed).

Provider and model selection are read from
`/opt/ai-zombie/secrets/env`, not from `pi`'s native `~/.pi` defaults:
set exactly one matching `*_API_KEY`, optionally set
`ZOMBIE_PROVIDER`, and set `ZOMBIE_MODEL` when you need a non-default
model (or when using `openrouter` / `lmstudio`). The chat service passes
those values to `pi`/`@earendil-works/pi-ai` on every turn.

If you do not already have an SSH key on the workstation you will use
to control this PC, create one there (not on the Ubuntu Zombie box)
with `ssh-keygen -t ed25519`, then pass the public half
(`~/.ssh/id_ed25519.pub`, the line starting `ssh-ed25519 …`) as
`SSH_PUBLIC_KEY`. Full steps — including copying the key from GitHub —
are in [`docs/QUICKSTART.md`](docs/QUICKSTART.md#how-to-get-an-ssh-key).

During an **interactive** install the script can also auto-detect a
local LLM: it scans your LAN for an OpenAI-compatible server (LM
Studio, Ollama, `llama.cpp`) and offers any models it finds as the
starting model, wiring it up as the `lmstudio` provider so you can run
fully offline with no cloud API key. Skip it with
`ZOMBIE_SKIP_LLM_SCAN=1`. See
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#optional-use-a-local-llm-auto-detected-on-your-lan)
and [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md#local-llm-discovery-lan-scan).

Prefer a `.deb`? Each [GitHub Release](https://github.com/japer-technology/ubuntu-zombie/releases/latest)
ships `ubuntu-zombie_<version>_all.deb` plus a `SHA256SUMS` checksum file
and keyless cosign signatures. Verify the checksum **before** installing
so you know the download is genuine and unaltered — download the `.deb`
and `SHA256SUMS` into the same folder, then:

```bash
# from the folder holding both files (replace <version>, e.g. 1.2.3):
sha256sum --check --ignore-missing SHA256SUMS    # expect: ...deb: OK
sudo apt install ./ubuntu-zombie_<version>_all.deb
```

The `ubuntu-zombie` wrapper then accepts the same subcommands as
`scripts/install.sh`. A full, novice-friendly walkthrough of the
checksum and cosign-signature checks is in
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#alternative-install-from-the-signed-deb-and-check-the-sha-256);
see also [`docs/UPGRADING.md`](docs/UPGRADING.md) and
[`docs/FAQ.md`](docs/FAQ.md).

Full walkthrough with expected output and failure branches:
[`docs/QUICKSTART.md`](docs/QUICKSTART.md).

## Subcommands

```
sudo ./scripts/install.sh install     # full install or upgrade, idempotent
sudo ./scripts/install.sh verify      # read-only state check
sudo ./scripts/install.sh doctor      # explain failures
sudo ./scripts/install.sh repair      # fix known-safe drift
sudo ./scripts/install.sh uninstall   # reverse the install
```

To upgrade an existing host (or refresh after fixing a bug upstream),
pull the latest source and re-run `install`:

```bash
cd ubuntu-zombie
git pull
sudo ./scripts/install.sh install
sudo systemctl restart ubuntu-zombie-chat.service
```

See [`docs/QUICKSTART.md`](docs/QUICKSTART.md#upgrade--refresh-from-github)
for the non-interactive variant and when a reboot is required.

Non-interactive variants and every environment variable: see
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) and `--help`.

## Documentation

| Document                                                       | When to read it                                   |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [`docs/VISION.md`](docs/VISION.md)                             | What this project promises (and does not)         |
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md)                     | First successful install in ten steps             |
| [`docs/PLATFORMS.md`](docs/PLATFORMS.md)                       | Supported Ubuntu versions and architectures       |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)               | Provider keys, Tailscale, VNC, chat, policy       |
| [`docs/VNC.md`](docs/VNC.md)                                   | Why/how the VNC password is used, and if required |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)           | Common failures and their fixes                   |
| [`docs/FAQ.md`](docs/FAQ.md)                                   | Quick answers distilled from the above            |
| [`docs/UPGRADING.md`](docs/UPGRADING.md)                       | Version-by-version upgrade notes                  |
| [`SECURITY.md`](SECURITY.md)                                   | Trust model, what the provider sees, disclosure   |
| [`SUPPORT.md`](SUPPORT.md)                                     | Where to ask questions, file bugs, get help       |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)                 | Components, action classes, trust boundaries      |
| [`CONTRIBUTING.md`](CONTRIBUTING.md)                           | How to test and change the installer              |
| [`RELEASE.md`](RELEASE.md)                                     | How maintainers cut a release                     |
| [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)                     | Community expectations                            |
| [`LICENSE`](LICENSE)                                           | MIT license terms                                 |
| [`CHANGELOG.md`](CHANGELOG.md)                                 | Versioned release history                         |
| [`docs/research/`](docs/research/)                             | Background notes on alternatives we evaluated     |

## Trust model in one paragraph

The local `zombie` Linux user (renameable at install time with
`ZOMBIE_USER=<name>`) is the operating identity of the AI
Systems Administrator and holds passwordless `sudo`. The configured
cloud LLM provider authenticates the administrator. The operator owns
the machine, the SSH private key, the API key, and (if Tailscale is
enabled) the Tailscale account, and can rotate, revoke, or uninstall
any of them at any time. Privileged actions go through a local policy
gate before `sudo`. Every action is audit-logged. The chat and VNC
services bind to `127.0.0.1` only. Tailscale is off by default; opt in
with `ZOMBIE_SKIP_TAILSCALE=0` to confine inbound SSH to your tailnet.
Read [`SECURITY.md`](SECURITY.md) before running the installer.

## License

Ubuntu Zombie is released under the MIT License. By contributing you agree
your contributions are released under the same license.
