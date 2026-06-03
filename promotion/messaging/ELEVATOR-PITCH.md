# Elevator Pitches

Three lengths of the same story. Use the shortest that fits.

## 10 seconds (one breath)

Ubuntu Zombie puts a private, root-capable AI Systems Administrator inside your
Ubuntu desktop. You ask it to fix or change something, it shows you exactly
what it would do, you approve, and it acts — with every step audit-logged and
reversible.

## 30 seconds (a meeting opener)

Most people own computers they can't safely operate. When something breaks, the
gap between "my laptop is broken" and "here's the exact systemd unit that fixes
it" gets filled by a forum thread or a paid technician. Ubuntu Zombie closes
that gap on the machine itself. It installs a dedicated `zombie` account with
passwordless sudo as the operating identity of an AI Systems Administrator. You
open a private chat on `127.0.0.1`, ask in plain English, and it proposes the
commands it would run. Destructive or system-altering actions pass through a
local policy gate and wait for your approval. Everything is written to an audit
log. You own the SSH key, the API key, and the kill switch — uninstall and the
whole thing reverses.

## 60 seconds (a podcast / press intro)

Personal computers have become powerful enough to run real workloads and
complex enough that most owners can't safely operate them. Ubuntu Zombie is a
transparent bash installer that turns a supported Ubuntu Desktop LTS machine
into a computer that can administer itself. It adds a private, root-capable AI
Systems Administrator — a dedicated Linux account, not a shared human login —
that the owner can ask to diagnose, explain, configure, repair, and operate the
machine in plain language.

The design is built around control. Privileged actions are classified and
gated; the operator approves them before they run. Every proposal and command
is audit-logged and inspectable after the fact. The chat and remote-desktop
services bind to localhost only; SSH is key-only with root disabled; remote
access is opt-in over a private Tailscale tailnet, never the public internet.
Revocation is first-class: rotate the provider key, remove the SSH key, disable
Tailscale, or run uninstall, and the agent stops.

It deliberately does *not* promise an autonomous machine, local-only inference,
fleet management, or replacing the humans on the desktop. One machine, one
operator, one trust boundary. The logo says it best: an ordinary PC with a calm,
listening, root-capable administrator fused to it, sharing one glowing eye that
belongs to the operator — who can always turn it off.
