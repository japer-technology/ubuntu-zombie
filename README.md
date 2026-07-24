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
user can open a private loopback chat, ask the machine to do something,
see exactly what is proposed, approve it, and watch it happen.
Everything the AI does is audit-logged. The operator owns the machine,
the API key, and the TTL control.

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
# open http://127.0.0.1:7878/ locally
```

The installer no longer provisions remote access or a secondary desktop
viewing path. It installs one access surface: the password-protected
chat UI bound to `127.0.0.1`. An LLM API key is added *after* install.
The full list of inputs and their defaults is in
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#parameters-required-to-allow-the-install-to-proceed).

The chat administrator is **password-protected** and has a **Time to
Live**. The installer asks for a chat password (default `braaaains`)
and a TTL (default 7 days); only a hash of the
password is stored. When the TTL expires — or you run `/ttl --die` in
the chat — the zombie permanently disables itself until the next
reinstall. Extend it from the chat with `/ttl <days>`. See
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md#chat-access) for details.
The chat streams live turn progress when the browser supports
`EventSource`, falls back automatically when it does not, and keeps one
visible queued message if you submit while the agent is already working.
The agent can also schedule one bounded future continuation with
`timer.reactivation`; the upcoming turn is visible and cancellable in the chat,
and `/reactivation` or its `/reactivate` alias controls the feature.
Type `/` to browse the complete command catalogue without leaving the
composer; keep typing to narrow it. `/help` shows the compact command index,
`/help <command>` explains one command in detail, `/help <pattern*>` explains
matching commands, and `/help all` shows every full help page. Assistant
Markdown tables use bordered, high-contrast cells and scroll horizontally
when wide. User questions and assistant responses share the same transcript
width, while `/fullwidth [on|off]` expands or restores the transcript and
composer and remembers that setting in the current browser.
Use `/rebrand <title>` to rebrand the browser title, header, wordmark, and
login/tombstone labels for this browser; `/rebrand` resets them. Use
`/reprompt <placeholder>` to replace and remember the composer placeholder
for this browser; `/reprompt` restores the default. The header shows the
active model and, for a local model server, its IP address.

`/status` runs a full proof-of-life check: it makes a tiny completion against
the configured LLM provider (which can incur minimal provider usage), measures
latency, and reports provider/model, host IP and resources, lifecycle,
service activity, and local usage totals. Probe results are reused for 30
seconds to prevent rapid status requests from multiplying provider cost.
`/version` reports the installed
application, bridge, Python, Node, and SQLite versions; it also checks fixed
GitHub and npm endpoints for the latest Ubuntu Zombie and bridge releases.
Failed or offline update checks are reported as unavailable rather than
blocking the command.

Provider and model selection are read from
`/opt/ai-zombie/secrets/env`, not from `pi`'s native `~/.pi` defaults:
set exactly one matching `*_API_KEY`, optionally set
`ZOMBIE_PROVIDER`, and set `ZOMBIE_MODEL` when you need a non-default
model (or when using `openrouter` / `lmstudio`). The chat service passes
those values to `pi`/`@earendil-works/pi-ai` on every turn.

During an **interactive** install the script can also auto-detect a
local LLM: it scans your LAN for an OpenAI-compatible server (LM
Studio, Ollama, `llama.cpp`) and offers any models it finds as the
starting model, wiring it up as the `lmstudio` provider so you can run
fully offline with no cloud API key. Skip it with
`ZOMBIE_SKIP_LLM_SCAN=1`. See
[`docs/QUICKSTART.md`](docs/QUICKSTART.md#optional-use-a-local-llm-auto-detected-on-your-lan)
and [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md#local-llm-discovery-lan-scan).
At runtime, `/locals` checks ports `1234`, `8080`, `11434`, and `51234`
across the local IPv4 `/24` and on `127.0.0.1`; the private managed
llama.cpp port `58080` remains loopback-only.

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

## Installer command grammar

Canonical form:

```text
sudo ./scripts/install.sh <verb> [component ...] [flags]
```

Valid verbs are `install`, `verify`, `doctor`, `repair`, and
`uninstall`. Public component targets are `zombie`, `forgejo`, and
`llama`. With
no target, `install` keeps its existing meaning: install or upgrade the
`zombie` baseline. Examples:

```bash
sudo ./scripts/install.sh install             # baseline zombie
sudo ./scripts/install.sh install zombie      # same, explicit target
sudo ./scripts/install.sh install forgejo      # standalone forge + PostgreSQL
sudo ./scripts/install.sh install llama        # standalone PC-wide llama.cpp
sudo ./scripts/install.sh install zombie forgejo
sudo ./scripts/install.sh verify zombie
sudo ./scripts/install.sh doctor forgejo

# Remove only the Forgejo component, leave zombie running:
sudo ./scripts/install.sh uninstall forgejo

# Remove only the zombie account and runtime, leave Forgejo running:
sudo ./scripts/install.sh uninstall zombie

# Remove everything (default):
sudo ./scripts/install.sh uninstall
```

`install forgejo` and `install llama` do not create the zombie account,
install Node or the
Python agent runtime, deploy policy or chat services, or change desktop
sleep settings. `ZOMBIE_INSTALL_FORGEJO=1 install` remains supported and
selects the legacy combined `zombie forgejo` path.

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

## Optional components (Ubuntu Zombie + Options)

The baseline can be extended with opt-in components behind
`ZOMBIE_INSTALL_*` flags — all off by default, idempotent, audited,
and reversible by `uninstall.sh`. These environment flags remain the
compatibility API for cloud-init and other automation and are additive
with explicit component targets. The first is a self-hosted **Forgejo**
git forge (PostgreSQL-backed, `.local` LAN discovery, Caddy internal-CA
HTTPS, optional co-located Actions runner):

```bash
sudo ZOMBIE_INSTALL_FORGEJO=1 ZOMBIE_INSTALL_FORGEJO_RUNNER=1 \
  ./scripts/install.sh install
```

Interactive installs can also toggle components from item
`9) Options` of the parameter review. Settings and caveats:
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md#optional-components-ubuntu-zombie--options).
More components are specified under [`options/`](options/README.md).

### Standalone llama.cpp

Install an independent CPU llama.cpp server and a small verified default
model without installing Zombie:

```bash
sudo ./scripts/install.sh install llama
llama-manager status
```

The OpenAI-compatible endpoint is
`http://127.0.0.1:8080/v1`. It is available to local applications and
local users only; it never listens on the LAN. Use `llama-manager` to
start, stop, restart, enable, disable, test, or inspect it. Removing
Zombie leaves this component untouched.

## Documentation

| Document                                                       | When to read it                                   |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [`docs/VISION.md`](docs/VISION.md)                             | What this project promises (and does not)         |
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md)                     | First successful install in ten steps             |
| [`docs/PLATFORMS.md`](docs/PLATFORMS.md)                       | Supported Ubuntu versions and architectures       |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)               | Provider keys, chat, policy, helper settings      |
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
LLM provider powers the administrator. The operator owns the machine,
the API key, and the TTL control, and can rotate, revoke, or uninstall
any of them at any time. Privileged actions go through a local policy
gate before `sudo`. Every action is audit-logged. The chat service
binds to `127.0.0.1` only. Read [`SECURITY.md`](SECURITY.md) before
running the installer.

## License

Ubuntu Zombie is released under the MIT License. By contributing you agree
your contributions are released under the same license.

## LLM Usage Disclaimer

In accordance with Japer Technology's LLM usage policy guidelines, this project is classified as having LLM Usage (meaningful portions of the code, documentation, release notes, etc. may have been generated with AI, but the overall project is still being largely human-managed). For more information on the usage of generative AI for this project, please navigate to the Credits section of the README.
