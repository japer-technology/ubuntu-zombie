# Boilerplate & Standard Blocks

Reusable, copy-paste blocks. Keep these consistent across every channel.

## Boilerplate — short (≤ 50 words)

> Ubuntu Zombie adds a private, root-capable AI Systems Administrator account to
> a supported Ubuntu Desktop LTS machine. The owner asks the computer to
> diagnose, explain, configure, repair, and operate itself in plain language —
> under explicit approval, with every action audit-logged and reversible.

## Boilerplate — long (≤ 100 words)

> Ubuntu Zombie is an open-source, transparent bash installer that turns a
> supported Ubuntu Desktop LTS machine into a computer that can administer
> itself. It adds a dedicated, root-capable Linux account that serves as the
> operating identity of an AI Systems Administrator. Owners open a private,
> local chat and ask the machine to diagnose, explain, configure, repair, or
> operate itself in plain language. Privileged actions pass through a local
> policy gate and wait for the operator's approval; every action is audit-logged
> and reversible. The operator owns the machine, the SSH key, the API key, and
> the kill switch. Released under the MIT licence by Japer Technology.

## About Japer Technology

> Japer Technology (japer.technology) builds practical, transparent tools that
> keep humans in control of the systems they own.

## Trademark / disclaimer

> Ubuntu is a trademark of Canonical Ltd. Ubuntu Zombie is an independent,
> third-party project and is not affiliated with, endorsed by, or sponsored by
> Canonical.

## Standard links

- Repository: <https://github.com/japer-technology/ubuntu-zombie>
- Latest release: <https://github.com/japer-technology/ubuntu-zombie/releases/latest>
- Vision: [`docs/VISION.md`](../../docs/VISION.md)
- Security / trust model: [`SECURITY.md`](../../SECURITY.md)
- Quickstart: [`docs/QUICKSTART.md`](../../docs/QUICKSTART.md)
- Discussions: <https://github.com/japer-technology/ubuntu-zombie/discussions>
- Publisher: <https://www.japer.technology>

## Licence line

> Released under the MIT Licence.

## Fact sheet (for quick reference)

| Fact | Value |
| ---- | ----- |
| Name | Ubuntu Zombie |
| Publisher | Japer Technology |
| Category | AI Systems Administrator / Linux desktop tooling |
| Platform | Ubuntu Desktop LTS 22.04 / 24.04 |
| Licence | MIT |
| Install | `git clone` + `sudo ./scripts/install.sh install`, or signed `.deb` |
| Network posture | Chat/VNC bind to `127.0.0.1`; key-only SSH, root disabled; Tailscale opt-in |
| Inference | Configured cloud LLM provider (operator's key) |
| Kill switch | Rotate key / remove SSH key / disable Tailscale / `uninstall` |
