# Installer UX ideas

This note captures ideas for taking the Ubuntu Zombie installer from a
transparent shell script to a more guided setup experience. It is a
research note, not a product commitment.

The current installer already has a strong base: a dry-run plan, branded
parameter review, preflight summary, phase numbering, heartbeat spinner,
transcript, receipt, failure trail, `doctor`, and non-interactive mode.
The ideas below build on those strengths rather than replacing them.

## 1. Add a first-run guided wizard

Group the interactive path by operator intent instead of raw variables:

1. Identity: agent user, install root, ownership model.
2. Access: SSH key, VNC password, loopback-only services.
3. Network: Tailscale opt-in, firewall posture, exposed surfaces.
4. Model: local LLM discovery or cloud-provider setup reminder.
5. Review: final editable summary before host changes.

Keep the existing environment-variable controls and non-interactive mode,
but let the default attended path feel like onboarding rather than a list
of prompts.

## 2. Make safety trade-offs visible inline

The installer should label high-impact choices directly in the review UI:

- recommended: Tailscale enabled, SSH restricted to `tailscale0`.
- normal: loopback-only chat and VNC.
- advanced: custom ports, custom install root, renamed agent user.
- risky: Tailscale skipped, SSH allowed on every interface, autologin
  enabled.

This would make the security posture legible before the operator accepts
the install.

## 3. Make long-running progress more granular

Phase numbering and the spinner already prevent the script from feeling
hung. The next step is to expose more sub-step context during long work:

- currently doing: "Installing NodeSource repository key".
- why it matters: "Needed for the pi runtime".
- where details go: transcript path.
- what to expect: "This can take a few minutes on slow networks".

This is especially useful around `apt`, Playwright, Python venv creation,
Node/npm global installs, and browser dependency setup.

## 4. Add a post-install success dashboard

The final output could become a compact checklist before the command
examples:

- SSH key-only access configured.
- Chat service installed and bound to loopback.
- VNC installed and bound to loopback.
- Firewall policy applied.
- Tailscale status known.
- LLM provider configured, or still needs a key.
- Reboot required.

Then show only the next must-do command first, followed by optional
commands grouped under "after reboot", "configure model", "open chat",
"emergency desktop", and "audit".

## 5. Offer named presets

Presets would let operators choose a security and convenience posture
without learning every variable first:

- `local-only`: no Tailscale, loopback services, clear public-SSH warning.
- `tailscale-secure`: Tailscale opt-in, SSH restricted to `tailscale0`.
- `lab-machine`: convenient defaults for a local test bench.
- `desktop-agent`: physical desktop flow with optional autologin.

The preset should only pre-fill choices; the final review remains the
source of truth.

## 6. Improve the SSH key prompt

The SSH key prompt could offer multiple paths:

- paste a public key.
- fetch public keys from a GitHub username.
- explain how to generate an `ed25519` key.
- show the accepted key fingerprint before proceeding.

This reduces one of the most common first-install stumbling blocks
without weakening the key-only SSH posture.

## 7. Polish local LLM discovery

Local LLM discovery can become a small model picker:

- show discovered host, model, base URL, and response latency.
- allow rescan, manual endpoint entry, or skip.
- optionally run a tiny test prompt before recording the choice.
- clearly explain that cloud keys can still be added later.

This turns discovery from a technical scan into a confident selection.

## 8. Improve failure recovery messaging

On failure, the installer already reports the failed line, transcript,
step trail, likely cause, and `doctor` command. A higher-level failure
summary could add:

- failed phase name.
- last successful phase.
- whether re-running is safe.
- exact retry command.
- most relevant log path.
- likely operator action.

The message should make idempotency explicit: in most cases, re-running
the installer is the intended recovery path.

## 9. Add an explicit resume or recovery flow

Because the installer is designed to be idempotent, it can detect partial
state and offer a friendlier path:

- "Previous incomplete install detected."
- "Resume from current state."
- "Repair known-safe drift."
- "Show doctor report."
- "Uninstall first."

This would make a failed or interrupted run feel recoverable rather than
ambiguous.

## 10. Document expected screens

Add terminal captures for the major interactive moments:

- dry-run plan.
- local LLM picker.
- parameter review.
- preflight summary.
- successful completion.
- common failure and recovery output.

These examples would help users know what "good" looks like and would
also give contributors a visual baseline for future UX changes.

## Suggested priority

1. Post-install success dashboard.
2. Inline safety labels in the parameter review.
3. Better SSH key prompt.
4. More granular long-running progress.
5. Failure summary and resume flow.
6. Presets and richer local LLM picker.

The dashboard and safety labels are likely the highest-impact first
changes because they improve confidence without changing the installer's
underlying behaviour.
