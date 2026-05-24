# Vision

> **Ubuntu Zombie adds a private, root-capable AI Systems
> Administrator account to supported Ubuntu Desktop LTS machines so a
> novice owner can ask the machine to diagnose, explain, configure,
> repair, and operate itself.**

That is the entire MVP promise. It is deliberately narrow.

## What the MVP promises

1. A controlled sysadmin assistant with local authority.
2. An explicit policy and approval model before privileged actions.
3. An auditable trail of every command the AI proposes or runs.
4. Operator revocation — pulling the provider token stops the agent.

## What the MVP does not promise

- Autonomous ownership of the machine. The operator remains in charge.
- Local-only inference. The MVP relies on a cloud provider; local
  models are listed in `ROADMAP.md`.
- Multi-tenant or fleet management. One machine, one operator.
- Replacement of normal human users on the desktop.

## Trust model summary

The local `agent` account holds passwordless `sudo` and is the
operating identity of the AI Systems Administrator. The configured
token provider authenticates the administrator. The operator owns the
machine and can rotate the API key, revoke the SSH key, disable the
Tailscale account, or uninstall the system at any time.

See [`SECURITY.md`](../SECURITY.md) for the full trust boundary,
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the components, and
[`ROADMAP.md`](ROADMAP.md) for what is intentionally post-MVP.
