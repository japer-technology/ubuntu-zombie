# Ubuntu Zombie

> A normal Ubuntu PC with a resident AI Systems Administrator,
> authenticated by the token provider and contactable by any user of
> the machine.

This project does not turn Ubuntu into a sealed appliance, a remote
server box.

It starts as a normal Ubuntu PC.

It can remain ordinary, or it can become as complicated as the user
wants: desktop workstation, server, browser machine, Docker host,
automation rig, Forgejo controller, local lab, strange experimental
monster, or all of those at once.

The difference is that the machine now has a resident AI Systems
Administrator.

Any user of the PC can contact that administrator. They can ask for
help, ask questions, request software, diagnose problems, inspect
logs, configure services, manage files, drive the desktop, operate the
browser, or explain what the machine is doing.

The AI Systems Administrator is authenticated by the token provider.
The PC itself remains the user’s machine.

The baseline installer is deliberately small: Ubuntu plus the minimum
packages needed to give the AI Systems Administrator a useful body.
The desktop, browser, Docker, services, tools, and stranger machinery
can then be added as the user wants.

You do not need to be a Linux expert to run it. You need to be willing
to sit in front of the machine once with a keyboard.

---

## What this machine becomes

This installer adds a resident administrator to a normal Ubuntu PC.

It does not remove the human users.

It does not replace the desktop.

It does not decide what the machine is for.

The PC remains open-ended. It may be plain or elaborate. It may be a
simple workstation, a full graphical desktop, a server, a development
box, a Docker host, a browser automation machine, a forge controller,
or the most complicated Ubuntu installation the user can imagine.

The AI Systems Administrator is an added privileged presence. It can
be contacted by any user of the PC, while the machine itself remains
owned and controlled locally.

---

## Who authenticates the AI Systems Administrator

This project takes a deliberate position on authentication and control:

The token provider — the cloud LLM vendor whose API key is configured
in `secrets/env` — authenticates the AI Systems Administrator on this
device.

The token provider does not own the PC.

The token provider does not define what the PC is.

The token provider does not decide how strange, simple, complex, useful,
or abnormal the PC becomes.

The provider supplies the token stream. The local machine supplies the
body: shell, files, desktop, browser, Docker, services, network,
memory, and root-capable authority.

Concretely:

- The local operator owns the machine.
- Human users may use the machine normally.
- Any user of the PC may contact the AI Systems Administrator.
- The AI Systems Administrator is authenticated by the configured
  token provider.
- The privileged operating identity of the AI Systems Administrator is
  the local `agent` account.
- `agent` has passwordless `sudo`.
- Human users do not need to become `agent` in order to speak to the
  administrator.
- The operator chooses the provider, controls the API key, controls
  the SSH key, controls the Tailscale account, and can disconnect or
  remove the system.

That is the trust model.

The AI Systems Administrator lives on the PC, but the PC remains the
user’s machine.

---

## Trust model — read this first

This installer makes one deliberate trade-off so the AI Systems
Administrator can do real work:

- `agent` is root-capable through passwordless `sudo`.
- The configured token provider authenticates the AI Systems
  Administrator.
- The API key, SSH private key, and Tailscale account together form
  the effective credential set for privileged administration.
- Any local user may contact the AI Systems Administrator, but local
  policy decides what requests are informational, user-level,
  administrative, or forbidden.
- The machine is reachable remotely only through the private Tailscale
  network.
- There is no public inbound exposure.

Treat the SSH private key, the LLM API key, the Tailscale account, and
`/opt/ai-zombie/secrets/env` the same way you would treat a root
password.

This is not a locked appliance. It is a normal PC with an administrator
inside it.
