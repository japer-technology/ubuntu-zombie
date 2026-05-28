# Ubuntu Zombie

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![AI](https://img.shields.io/badge/Assisted-Development-2b2bff?logo=openai&logoColor=white)](https://www.japer.technology)

<p align="center">
  <picture>
    <img src="https://raw.githubusercontent.com/japer-technology/ubuntu-zombie/main/LOGO.png" alt="Ubuntu Zombie" width="500">
  </picture>
</p>

> **Ubuntu Zombie adds a private, root-capable AI Systems
> Administrator account to supported Ubuntu Desktop LTS machines so an
> owner can ask the machine to diagnose, explain, configure,
> repair, and operate itself.**

# An AI SysAdmin

It is a normal Ubuntu PC with an administrator inside it. Any local
user can open a private chat, ask the machine to do something, see
exactly what is proposed, approve it, and watch it happen. Everything
the AI does is audit-logged. Inbound network access is restricted to a
private Tailscale tailnet. The operator owns the machine, the SSH
key, the API key, and the kill switch.

## Quickstart

```bash
git clone https://github.com/japer-technology/ubuntu-zombie.git
cd ubuntu-zombie
chmod +x scripts/install.sh
sudo ./scripts/install.sh install
sudo reboot
# after reboot:
/opt/ai-zombie/bin/verify
sudo /opt/ai-zombie/bin/secrets-edit   # add an LLM API key
sudo systemctl restart ubuntu-zombie-chat.service
# open http://127.0.0.1:7878/ locally, or tunnel over Tailscale:
ssh -L 7878:127.0.0.1:7878 zombie@<tailscale-name-or-ip>
```

Full walkthrough with expected output and failure branches:
[`docs/QUICKSTART.md`](docs/QUICKSTART.md).

## Subcommands

```
sudo ./scripts/install.sh install     # full install, idempotent
sudo ./scripts/install.sh verify      # read-only state check
sudo ./scripts/install.sh doctor      # explain failures
sudo ./scripts/install.sh repair      # fix known-safe drift
sudo ./scripts/install.sh uninstall   # reverse the install
```

Non-interactive variants and every environment variable: see
[`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) and `--help`.

## Documentation

| Document                                                       | When to read it                                   |
| -------------------------------------------------------------- | ------------------------------------------------- |
| [`docs/VISION.md`](docs/VISION.md)                             | What this project promises (and does not)         |
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md)                     | First successful install in ten steps             |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md)               | Provider keys, Tailscale, VNC, chat, policy       |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)           | Common failures and their fixes                   |
| [`SECURITY.md`](SECURITY.md)                                   | Trust model, what the provider sees, disclosure   |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)                 | Components, action classes, trust boundaries      |
| [`CONTRIBUTING.md`](CONTRIBUTING.md)                           | How to test and change the installer              |
| [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)                     | Community expectations                            |
| [`LICENSE`](LICENSE)                                           | MIT license terms                                 |
| [`CHANGELOG.md`](CHANGELOG.md)                                 | Versioned release history                         |
| [`docs/POSSIBILITIES.md`](docs/POSSIBILITIES.md)               | Exploratory analysis: many named personas on one PC |

## Trust model in one paragraph

The local `zombie` Linux user (renameable at install time with
`ZOMBIE_USER=<name>`) is the operating identity of the AI
Systems Administrator and holds passwordless `sudo`. The configured
cloud LLM provider authenticates the administrator. The operator owns
the machine, the SSH private key, the API key, and the Tailscale
account, and can rotate, revoke, or uninstall any of them at any
time. Privileged actions go through a local policy gate before
`sudo`. Every action is audit-logged. There is no public inbound
exposure. Read [`SECURITY.md`](SECURITY.md) before running the
installer.

## License

Ubuntu Zombie is released under the MIT License. By contributing you agree
your contributions are released under the same license.
