# Vision

<p align="center">
  <picture>
    <img src="https://raw.githubusercontent.com/japer-technology/ubuntu-zombie/main/LOGO.png" alt="Ubuntu Zombie" width="420">
  </picture>
</p>

<p align="center"><em>A normal Ubuntu PC, with an administrator inside it.</em></p>

---

## The one-sentence promise

> **Ubuntu Zombie turns a supported Ubuntu Desktop LTS machine into a
> computer that can administer itself — by installing a private,
> root-capable AI Systems Administrator account that the owner can ask
> to diagnose, explain, configure, repair, and operate the machine, in
> plain language, under explicit human approval, with every action
> written to an auditable log.**

That sentence is the entire MVP. It is deliberately narrow, and every
line of code in this repository exists to make it true, observable,
and reversible.

## Why this exists

Personal computers have become powerful enough to run real workloads
and complex enough that most owners cannot safely operate them. The
gap between *"my laptop is broken"* and *"here is the exact `systemd`
unit, kernel parameter, or `apt` pin that will fix it"* is filled,
today, by a friend, a forum thread, or a paid technician.

Ubuntu Zombie closes that gap on the machine itself. The owner asks
the computer a question; the computer answers as an administrator
would, proposes the commands it would run, waits for approval, runs
them, and writes down what happened. The operator stays in charge of
the machine the whole time.

## What the MVP promises

1. **A controlled sysadmin assistant with local authority.** A
   dedicated `zombie` account (renameable at install time) holds
   passwordless `sudo` and serves as the operating identity of the AI
   Systems Administrator — never a shared human login.
2. **An explicit policy and approval model before privileged
   actions.** Destructive, networked, or system-altering commands are
   classified, gated, and surfaced to the operator before they run.
3. **An auditable trail of every command the AI proposes or runs.**
   What was asked, what was proposed, what was approved, and what the
   system did — all recorded and inspectable after the fact.
4. **Operator revocation as a first-class feature.** Rotating the
   provider API key, removing the SSH key, disabling the Tailscale
   account, or running `uninstall` stops the agent. The kill switch
   is the operator's, not the vendor's.

## What the MVP does not promise

- **Autonomous ownership of the machine.** The operator is the
  principal. The agent is a tool with hands, not a tenant.
- **Local-only inference.** The MVP relies on a configured cloud
  provider. Local and on-device models are tracked in
  [`ROADMAP.md`](ROADMAP.md), not shipped here.
- **Multi-tenant or fleet management.** One machine, one operator,
  one trust boundary. Fleet orchestration is out of scope.
- **Replacement of the human users on the desktop.** Existing logins,
  files, and workflows are left alone. Ubuntu Zombie installs
  *beside* the user, not *over* them.
- **A locked appliance or a hosted service.** This is a transparent
  bash installer on a normal Ubuntu LTS system. Every component can
  be inspected, modified, or removed.

## Trust model summary

The local `zombie` account (renameable with `ZOMBIE_USER=<name>`)
holds passwordless `sudo` and is the operating identity of the AI
Systems Administrator. The configured token provider authenticates
the administrator. The operator owns the machine and can rotate the
API key, revoke the SSH key, disable the Tailscale account, or
uninstall the system at any time. Inbound network access is
restricted to a private Tailscale tailnet; the public internet is
never a control plane for this machine.

## How to read the rest of the docs

- [`SECURITY.md`](../SECURITY.md) — the full trust boundary, what the
  provider sees, and the disclosure policy.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — components, action classes,
  and the approval pipeline.
- [`ROADMAP.md`](ROADMAP.md) — what is intentionally post-MVP and
  what we have committed *not* to ship until the MVP is solid.

If a feature request or pull request expands beyond the one-sentence
promise above, it belongs in `ROADMAP.md` first, not in `main`.
