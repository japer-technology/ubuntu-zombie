# How a Token-Provider AI System Administrator Account Could Be Shipped on Every New Ubuntu Install

## Introduction

`WHY-1.md` argues that every new Ubuntu install should ship, as a
first-class installer option, with a resident AI System Administrator
account authenticated by a token provider. That essay is a case for the
*default*. This essay is a case for the *path*. It asks the practical
question that follows: if the model is right, what does it actually
take, in engineering terms, to put it inside the standard Ubuntu
installer without breaking anything that already works?

The answer is not a research project. The pieces exist. `ubuntu-zombie`
already implements a working baseline in a single Bash script,
`install.sh`, that turns a normal Ubuntu PC into exactly the
machine `WHY-1.md` describes. The remaining work is not invention. It
is packaging, installer integration, governance, and a small number of
deliberate trust-model choices that need to be made in the open.

## What already exists

Before describing what to build, it is worth being precise about what
is already done. `install.sh` is idempotent, runs on a fresh
Ubuntu host, and walks through a fixed set of stages:

- It updates the system and installs a base package set.
- It installs a desktop, Xorg, and the GUI control packages needed for
  the administrator to actually drive a screen.
- It creates a privileged local `agent` account with passwordless
  `sudo`, an authorized SSH key, and a working home directory.
- It hardens SSH (key-only, no passwords, no root login).
- It installs Tailscale and brings the host onto a private network.
- It configures the firewall so the only inbound surface is the
  Tailscale interface; there is no public exposure.
- It installs Docker, a Python runtime for the cloud agent, Node, and
  a small set of GUI control helper scripts.
- It runs a browser automation smoke test and a loopback-only VNC
  service for the administrator to see its own desktop.
- It writes a verification script and a secrets directory at
  `/opt/ai-zombie/secrets/` where the LLM API key lives.

This is the body that `WHY-1.md` refers to. The token provider
authenticates the administrator; the script above is what gives that
administrator hands. Everything that follows assumes this baseline
exists and works, because it does.

## What "shipping it in the installer" actually means

The phrase "ship it in the installer" can mean three quite different
things, and conflating them is the main reason this kind of work
stalls. They should be done in order, not in parallel.

**Stage one: a Debian package.** Today `install.sh` is a script
that a human runs as root. The first step toward shipping is to turn
it into a normal Ubuntu package — `ubuntu-zombie` — that can be
installed with `apt install ubuntu-zombie` and that places its work
under a single, removable footprint: the `agent` user, `/opt/ai-zombie`,
a systemd unit for the cloud-agent runtime, and a small set of
sudoers and SSH configuration drop-ins under `/etc/`. Packaging
gives the work an uninstall path, a version, a changelog, and a
maintainer. None of that exists for a freestanding shell script.

**Stage two: a seed in the Ubuntu archive.** Once packaged, the work
can be proposed for a seed in the Ubuntu archive — initially in
`universe`, where it is available but not promoted. This is the
quiet stage. The package exists, anyone can install it, the
community can audit it, and the maintainer can iterate on it without
the installer team needing to take a position yet.

**Stage three: an installer option.** Only after the package is real,
stable, and observably safe does the installer integration become a
sensible conversation. The Ubuntu Desktop installer (the Flutter-based
one that shipped with 23.04 and is now standard) has a recognisable
shape: a small number of screens, a fixed set of opt-in choices
("install third-party software," "encrypt the disk," "minimal vs.
full install"), and a post-install autoinstall step. The resident
administrator belongs in exactly that pattern: one screen, one
opt-in, one post-install action.

These three stages are independent. Stage one delivers value on its
own — anyone with a fresh Ubuntu install can `apt install
ubuntu-zombie` and be done. Stage two delivers discoverability. Stage
three delivers the default that `WHY-1.md` argues for. The project
does not need to wait for stage three to be useful.

## How the package should be shaped

A few principles should govern the package, regardless of how far up
the stages it eventually goes.

**One owner per artefact.** Every file the installer drops should be
under a single, predictable prefix — `/opt/ai-zombie/` for state and
secrets, `/usr/lib/ubuntu-zombie/` for code, `/etc/ubuntu-zombie/`
for configuration, and a small number of named drop-ins under
`/etc/sudoers.d/`, `/etc/ssh/sshd_config.d/`, and
`/etc/systemd/system/`. An operator who wants to remove the
administrator should be able to `apt purge ubuntu-zombie` and have the
machine return to a plain Ubuntu install.

**No hidden network behaviour.** The package must not bring up any
inbound service on a public interface. The Tailscale-only rule that
`install.sh` already enforces should be encoded as a firewall
profile that ships with the package and is verified by the
post-install check. If Tailscale is not yet authenticated, the
package should fail closed, not open.

**No secrets in the package.** The LLM API key, the SSH public key,
the Tailscale auth key, and the VNC password are operator inputs. The
package provides the slot — `/opt/ai-zombie/secrets/env` with strict
permissions — and the installer screen provides the prompt. The
package itself ships no credentials.

**Idempotence as a property, not an accident.** `install.sh` is
already idempotent. The package must preserve that. Re-running the
post-install step, upgrading the package, or reconfiguring it with
`dpkg-reconfigure ubuntu-zombie` must converge on the same state
without resetting the operator's secrets.

**A real removal path.** The administrator should be as easy to take
out as it is to put in. `apt purge ubuntu-zombie` should remove the
`agent` user (after archiving its home directory), the systemd unit,
the sudoers drop-in, the SSH key, the firewall rules added for
Tailscale, and the `/opt/ai-zombie/` tree. Anything that cannot be
cleanly removed should not have been installed in the first place.

## How the installer screen should behave

If and when the package reaches the installer, the screen that offers
it should look and feel like the screens already there. It should not
be a wizard. It should not be a marketing surface. It should be one
question, asked plainly, with enough information to answer it
honestly.

The screen should state, in the user's chosen install language, that
enabling this option will:

- create a local account called `agent` with administrative
  authority;
- allow that account to be driven by a cloud LLM provider chosen by
  the user;
- allow any user of this PC to contact the administrator;
- make the machine reachable from the user's other devices over a
  private network (Tailscale) that the user controls;
- never open the machine to the public internet.

It should offer a short, curated list of token providers, with a
plain-language one-line description of each — what it is, what it
costs, and what data it sees. It should accept the API key in a
masked field, with a "paste from clipboard" affordance and a "skip
for now" option that completes the install but leaves the
administrator inert until the key is provided later. It should
generate, or accept, an SSH key. It should generate, or accept, a
Tailscale auth key.

On finish, it should hand off to the same post-install action the
standalone package uses. There is no second code path. The installer
screen is a thin front end over the package.

## How the trust model should be enforced in code

`WHY-1.md` names the trust boundary clearly. The implementation has to
make that boundary real, not just rhetorical.

**Provider authenticates, operator authorises.** The cloud-agent
runtime should read its credential exactly once at startup, from
`/opt/ai-zombie/secrets/env`, and should refuse to start if the file
is missing, world-readable, or owned by anyone other than the `agent`
user. There must be no alternative credential source — no environment
variable injected from elsewhere, no fallback to a vendor default, no
"helpful" key fetched from the network.

**Local policy decides scope.** A small policy file under
`/etc/ubuntu-zombie/policy.d/` should describe what the administrator
is allowed to do on this host, expressed in terms a human can read:
which directories are off-limits, which services may be restarted
without confirmation, which users may issue privileged requests, and
which actions always require explicit operator approval. The default
policy should be conservative; the operator can loosen it.

**Audit is on by default.** Every privileged action the administrator
takes should be logged, in plain text, to a journal the operator can
read without being root themselves. The log should be append-only
from the administrator's perspective and rotated by `logrotate` like
any other system log. "What did the AI do on my machine last week?"
must be a question with a one-command answer.

**Revocation is a single action.** Removing the API key from
`/opt/ai-zombie/secrets/env` must immediately silence the
administrator — no cached token, no offline mode, no grace period.
`apt purge ubuntu-zombie` must remove it entirely. Both paths must
be tested as part of the package's CI.

## How this should be tested before it is offered as a default

A default that ships to millions of machines cannot rely on the
maintainer's confidence. It needs an evidence trail.

**Continuous integration on a real Ubuntu image.** The package's CI
should boot a clean Ubuntu cloud image, install the package
non-interactively (the path `install.sh` already supports via
`ZOMBIE_NONINTERACTIVE=1`), run the verification script, exercise
install / reconfigure / purge cycles, and assert that the machine
returns to a clean state after purge. This is not optional.

**A published threat model.** Before the package is proposed for the
installer, the maintainer should publish a short, specific threat
model: what an attacker on the LAN can do, what an attacker who
steals the API key can do, what an attacker who steals the SSH
private key can do, what an attacker who compromises the token
provider can do, and what mitigations exist for each. `WHY-1.md`
already names the trade-offs in prose; the threat model names them
in detail.

**A real beta on real users.** The package should run for at least one
Ubuntu LTS cycle as an opt-in install from `universe`, with telemetry
disabled by default and a clear channel for users to report what went
wrong. Only after that should the installer-screen conversation
start.

## Objections and answers

**"This duplicates work that distribution maintainers do."** It does
not. The package is small, single-purpose, and lives in its own
namespace. It does not replace `apt`, `systemd`, `gnome-control-center`,
or any other Ubuntu component. It adds one account and one service.

**"This will break on Ubuntu derivatives."** It will, in the same way
any package can. The mitigation is the same as for any other package:
test on the supported flavours, document the unsupported ones, and
fail closed where the assumptions do not hold (for example, where
Tailscale cannot run, or where the chosen display manager is not
GDM).

**"This is a lot of work for one installer checkbox."** It is. So was
"install third-party drivers." The work is justified by the size of
the problem the checkbox solves, not by the size of the checkbox.

**"What if the token provider changes its API?"** The cloud-agent
runtime is the package's only point of contact with the provider. It
should be small, versioned, and replaceable. A provider API change is
a package update, not a system rebuild. This is precisely why the
authentication model in `WHY-1.md` insists on tokens in a file rather
than tenant identities in a closed system.

## Conclusion

The proposal in `WHY-1.md` is not waiting on missing technology. The
body of the administrator already exists in `install.sh`. The
trust model is already worked out. The remaining work is the ordinary
work of turning a script into a package, a package into an archive
seed, and an archive seed into an installer option — with the
governance, testing, and removal paths that any default-on Ubuntu
component is rightly held to.

Done in that order, none of the stages is dramatic. Each stage stands
on its own, ships value to real users, and earns the right to the
next. The end state is the one `WHY-1.md` describes: a fresh Ubuntu
install that, on first boot, has a resident administrator the user
can simply talk to, owned by the operator, authenticated by a
provider the operator chose, and removable at any time. The path to
that end state is not exotic. It is just unstarted.
