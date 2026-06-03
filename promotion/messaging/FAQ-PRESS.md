# FAQ for Press & Reviewers

Short, quotable answers. For the user-facing FAQ see
[`../../docs/FAQ.md`](../../docs/FAQ.md).

**What is Ubuntu Zombie in one sentence?**
A private, root-capable AI Systems Administrator that installs onto a supported
Ubuntu Desktop LTS machine so the owner can ask it to diagnose, explain,
configure, repair, and operate the computer — under explicit approval, fully
audit-logged.

**Why "Zombie"?**
It reanimates capability that already belonged to the machine's owner. The logo
is a real human skull (your actual PC) fused to a calm robot (the AI admin),
sharing one purple eye (your control). See
[`../../LOGO-MEANING.md`](../../LOGO-MEANING.md).

**Is it autonomous?**
No — deliberately not. It listens, proposes, and waits. Nothing privileged runs
without the operator's approval.

**Where does inference run?**
Through a cloud LLM provider that the operator configures with their own API
key. Local/on-device inference is roadmap, not shipped in the MVP.

**What can the provider see?**
See [`../../SECURITY.md`](../../SECURITY.md) for the exact trust boundary and
what is sent to the provider.

**How is it secured?**
A local policy gate classifies and gates privileged actions; chat and VNC bind
to `127.0.0.1`; SSH is key-only with root login disabled; remote access is
opt-in over a private Tailscale tailnet. Every action is audit-logged.

**How do I stop or remove it?**
Rotate the provider API key, remove the SSH key, disable Tailscale, or run
`sudo ./scripts/install.sh uninstall`. The kill switch is the operator's.

**What does it cost?**
The software is open source under the MIT licence. You pay your chosen LLM
provider for usage.

**What platforms are supported?**
Ubuntu Desktop LTS 22.04 and 24.04. See
[`../../docs/PLATFORMS.md`](../../docs/PLATFORMS.md).

**Is this affiliated with Canonical / Ubuntu?**
No. Ubuntu is a trademark of Canonical Ltd. Ubuntu Zombie is an independent
third-party project.

**Can I see it do nothing first?**
Yes: `sudo ./scripts/install.sh install --dry-run` previews the entire plan and
changes nothing.
