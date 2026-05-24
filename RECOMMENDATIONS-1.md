# Recommendations to Make Ubuntu Zombie a True MVP / MVVP

Ubuntu Zombie already has a strong proof-of-concept: `setup-part-1.sh`
creates a privileged `agent` user, hardens SSH, restricts ingress to
Tailscale, installs Docker, Python/Node runtimes, browser automation,
desktop automation helpers, VNC over localhost, and a verification script.

The project is not yet a true MVP because it currently installs the
**body** of an AI systems administrator, but not the complete **product
loop**: a novice user cannot yet reliably open a private conversation,
ask for help, approve actions, see what changed, recover from failure, or
remove the system cleanly.

This document lists the concrete changes I would make to turn the
project into a minimum viable and minimum valuable product.

---

## Product definition

### 1. Define the MVP promise in one sentence

Add a short product promise to `README.md` and a new `VISION.md`:

> Ubuntu Zombie adds a private, root-capable AI systems administrator
> account to Ubuntu so a novice owner can ask the machine to diagnose,
> explain, configure, repair, and operate itself.

The MVP should not promise autonomous ownership of the machine. It should
promise a controlled sysadmin assistant with local authority, audit logs,
and operator revocation.

### 2. Make the first MVP deliberately small

The first shippable MVP should support these user flows:

1. Install on a fresh Ubuntu Desktop LTS machine.
2. Connect the machine to a private Tailscale network.
3. Open a private local chat interface.
4. Ask the AI sysadmin basic diagnostic questions.
5. Approve or reject privileged actions.
6. Run package, service, file, desktop, browser, and Docker tasks.
7. See an audit trail of every command and privileged action.
8. Run a health check.
9. Revoke the AI by removing the provider token.
10. Uninstall the system cleanly.

Everything else should be explicitly marked post-MVP.

---

## Critical MVP blockers

### 3. Add the missing conversational runtime

The installer currently creates tools and credentials, but there is no
resident agent service or private user-facing chat loop.

Add:

- A local web chat bound to `127.0.0.1`.
- An SSH tunnel example for remote private access over Tailscale.
- A small Python service running as `agent`.
- SQLite conversation history under `/opt/ai-zombie/state/`.
- A provider adapter that can call at least one cloud LLM.
- A command execution layer that captures stdout, stderr, exit code, and
  proposed follow-up checks.
- A simple approval gate before privileged or destructive commands.

Acceptance criteria:

- A local user can open the chat UI.
- A remote user on Tailscale can tunnel to it.
- The assistant can answer "what is this machine?" using local facts.
- The assistant can propose a command, ask for approval, execute it, and
  show the result.
- The conversation survives restart.

### 4. Add an explicit policy and approval model

Passwordless sudo is intentional, but the MVP needs a control layer above
it.

Add:

- `/etc/ubuntu-zombie/policy.yaml`
- Action classes: `read_only`, `user_change`, `system_change`,
  `network_change`, `destructive`
- Defaults:
  - read-only diagnostics may run automatically;
  - package installs, service changes, firewall changes, file deletion,
    user/account changes, and Docker changes require approval;
  - destructive actions require an extra confirmation phrase.

Acceptance criteria:

- The assistant cannot silently run `sudo apt install`, `rm -rf`,
  firewall edits, user edits, or service restarts.
- Every denied action is logged with the reason.
- The operator can loosen or tighten policy without editing code.

### 5. Add audit logging before adding more autonomy

The core trust question is: "What did the AI do?"

Add:

- `/var/log/ubuntu-zombie/audit.log`
- JSON-lines entries for prompts, proposed actions, approvals, commands,
  command output summaries, exit codes, changed files when known, and
  verification results.
- Log rotation.
- A helper command: `/opt/ai-zombie/bin/audit-tail`

Acceptance criteria:

- A novice owner can inspect recent AI activity with one command.
- Logs do not contain API keys, SSH keys, Tailscale auth keys, or VNC
  passwords.
- Privileged actions are distinguishable from read-only actions.

### 6. Add uninstall and revocation

The README says the operator can remove the system, but the repository
does not yet ship an uninstall path.

Add:

- `setup-part-1.sh uninstall`, or a separate
  `setup-part-1-uninstall.sh`.
- A dry-run mode that lists what would be removed.
- Removal of sudoers drop-ins, SSH drop-ins, x11vnc autostart, helper
  scripts, systemd services, package-managed configuration, and optional
  `agent` user removal.
- A safe archive option for `/home/agent` and `/opt/ai-zombie/state`.

Acceptance criteria:

- Removing the provider API key stops the agent service.
- Uninstall disables the agent service and removes privileged access.
- Uninstall does not delete user data without explicit confirmation.

---

## Installation reliability

### 7. Split installer operations into install, verify, doctor, repair, and uninstall

The current installer is a long one-shot script. Keep it simple, but
promote the operating modes already implied by `IDEA.md`:

- `install`
- `verify`
- `doctor`
- `repair`
- `uninstall`

Acceptance criteria:

- `verify` checks state without changing state.
- `doctor` explains failures and likely fixes.
- `repair` only fixes known safe drift.
- `uninstall` reverses the install.

### 8. Add stronger preflight checks

Before installing large packages, check:

- Ubuntu Desktop version.
- CPU architecture.
- available disk space;
- available memory;
- outbound DNS and HTTPS connectivity;
- apt/dpkg lock state;
- whether the command is running locally or over a risky public SSH path;
- whether Tailscale is already installed and logged in;
- whether another display manager is active.

Acceptance criteria:

- Known-bad environments fail early with clear messages.
- Warnings distinguish "unsupported" from "dangerous."
- Non-interactive mode returns useful exit codes for CI.

### 9. Add retry and recovery around network package operations

The installer depends on apt repositories, Docker, Tailscale, npm, pip,
and Playwright downloads. These are common failure points.

Add:

- retry with exponential backoff for apt, curl, pip, npm, and Playwright;
- apt lock detection with "wait or exit" behavior;
- resumable sections;
- a failure summary at the end of partial installs.

Acceptance criteria:

- A transient network failure does not force a full manual restart.
- A second install run converges to the desired state.

### 10. Make autologin configurable

The current script forces graphical autologin for `agent`. That is useful
for desktop automation, but it is also a significant security posture.

Add:

- `ZOMBIE_ENABLE_AUTOLOGIN=1` to enable it explicitly.
- A documented default.
- Verification that desktop automation still works after reboot when
  enabled.

Acceptance criteria:

- Operators can choose a safer non-autologin install.
- The installer clearly explains the trade-off.

---

## Security and trust

### 11. Publish a security model

Add `SECURITY.md` with:

- the exact trust boundary;
- what the provider can see;
- what the `agent` user can do;
- how to rotate API keys;
- how to revoke the agent;
- how Tailscale limits ingress;
- known risks of passwordless sudo, Docker group access, desktop
  automation, and VNC;
- responsible disclosure instructions.

Acceptance criteria:

- A cautious operator can decide whether the project is acceptable before
  running the installer.

### 12. Protect secrets more deliberately

The secrets file is mode `600`, which is a good start. The MVP should
also add:

- secret redaction in logs;
- a `/opt/ai-zombie/bin/secrets-edit` helper;
- permission verification before starting the agent service;
- startup refusal if the secrets file is group/world-readable;
- documentation for provider-token rotation.

Acceptance criteria:

- No install transcript or audit log contains sensitive token values.
- Bad permissions fail closed.

### 13. Replace broad root access with observable root access

Do not remove root capability from MVP; it is the point of the project.
Instead, make every root-capable path visible.

Add:

- command logging around `sudo`;
- approval IDs tied to executed commands;
- optional `sudo` wrapper for agent-initiated actions;
- clear distinction between human SSH sessions and AI-initiated actions.

Acceptance criteria:

- The operator can tell whether a root action came from the AI loop or a
  human shell.

---

## Documentation

### 14. Reorganize documentation around user jobs

The repository has strong essays, but MVP users need operational docs.

Add:

- `QUICKSTART.md` — install in the shortest safe path.
- `CONFIGURATION.md` — provider keys, Tailscale, VNC, chat access.
- `TROUBLESHOOTING.md` — apt locks, Tailscale login, Docker group,
  desktop automation, Playwright, VNC, secrets permissions.
- `ARCHITECTURE.md` — components and trust boundaries.
- `CONTRIBUTING.md` — how to test and change the installer.
- `CHANGELOG.md` — versioned release history.
- `ROADMAP.md` — post-MVP ideas currently spread through possibility
  documents.

Acceptance criteria:

- README becomes a concise front door.
- A novice can install without reading the essays.
- A reviewer can audit the design without reading the installer first.

### 15. Add a realistic "first 10 minutes" walkthrough

Document the first successful session:

1. install;
2. reboot;
3. verify;
4. add API key;
5. start chat;
6. ask a diagnostic question;
7. approve a safe command;
8. inspect audit log;
9. stop/revoke agent;
10. uninstall or keep running.

Acceptance criteria:

- A new user can reproduce the happy path.
- The walkthrough includes expected output and failure branches.

---

## Tests and CI

### 16. Add CI immediately

Add GitHub Actions for:

- ShellCheck on shell scripts;
- formatting checks for Markdown;
- basic secret scanning patterns;
- non-interactive installer syntax checks;
- generated helper script syntax checks.

Acceptance criteria:

- Every pull request runs CI.
- The installer cannot regress syntactically.

### 17. Add VM/container integration tests

The real product is system state, not just script syntax.

Add tests that:

- run the installer in non-interactive mode;
- verify idempotency by running it twice;
- assert required files, users, services, permissions, and firewall rules;
- test `verify`;
- test uninstall/purge behavior.

Acceptance criteria:

- The project can prove "fresh Ubuntu in, zombie-ready Ubuntu out."

### 18. Test failure paths

Add tests or documented manual checks for:

- missing SSH key in non-interactive mode;
- missing VNC password in non-interactive mode;
- no network;
- apt lock present;
- Tailscale unauthenticated;
- bad secrets file permissions;
- absent graphical session.

Acceptance criteria:

- Expected failures are controlled and understandable.

---

## Packaging and release

### 19. Introduce versioning

Move the hardcoded script version into a `VERSION` file and keep a
`CHANGELOG.md`.

Acceptance criteria:

- Installer, package, docs, and release notes agree on version.

### 20. Add a Debian package path

The MVP can start as a script, but the MVVP needs normal Ubuntu lifecycle
behavior.

Add:

- `debian/control`
- `debian/postinst`
- `debian/prerm`
- `debian/postrm`
- package-owned paths under `/usr/lib/ubuntu-zombie`,
  `/etc/ubuntu-zombie`, and `/opt/ai-zombie`

Acceptance criteria:

- The system can be installed, upgraded, and purged with standard tools.
- Package ownership makes removal auditable.

### 21. Define release gates

Before tagging `v1.0.0`, require:

- clean install on Ubuntu 24.04 LTS;
- idempotent reinstall;
- successful `verify`;
- working chat;
- audit log;
- policy enforcement;
- revocation;
- uninstall;
- CI green;
- documented known limitations.

---

## Maintainability

### 22. Refactor the installer after tests exist

Do not split the installer before there is CI. Once tests exist, move
sections into small files:

- preflight;
- apt helpers;
- user/sudo;
- SSH;
- Tailscale/firewall;
- desktop;
- Docker;
- runtimes;
- helper scripts;
- verification;
- uninstall.

Acceptance criteria:

- Each module can be reviewed independently.
- Generated files are easier to lint and test.
- Re-running install remains idempotent.

### 23. Add a Makefile

Add standard commands:

- `make lint`
- `make test`
- `make install-local`
- `make verify`
- `make package`

Acceptance criteria:

- Contributors do not need to memorize tool commands.

### 24. Add `.gitignore`

Add a `.gitignore` that prevents accidental commits of:

- logs;
- state files;
- screenshots;
- temporary keys;
- local env files;
- package build artifacts;
- Python virtual environments;
- Node dependencies.

Acceptance criteria:

- Common local artifacts are not accidentally committed.

---

## Observability and operations

### 25. Add a health check service

Add:

- `/opt/ai-zombie/bin/health-check`
- optional systemd timer;
- checks for agent service, Tailscale, SSH, firewall, Docker, desktop
  automation, provider token presence, and disk space.

Acceptance criteria:

- The operator can ask "is Ubuntu Zombie healthy?" and get a direct
  answer.

### 26. Add diagnostic bundles

Add:

- `/opt/ai-zombie/bin/collect-diagnostics`
- redaction of secrets;
- collection of install logs, service status, recent audit logs, package
  versions, OS release, disk/memory state, and verification output.

Acceptance criteria:

- Bug reports can include useful evidence without leaking secrets.

---

## Provider and model support

### 27. Add a provider abstraction

The MVP should support one provider well, but the design should not bake
that provider into the agent logic.

Add:

- provider interface;
- OpenAI implementation or Anthropic implementation;
- environment-based provider selection;
- clear error when no provider is configured;
- future slot for local Ollama.

Acceptance criteria:

- Switching provider does not require changing command execution,
  policy, audit, or chat history code.

### 28. Add cost and privacy warnings

The first-run UI should explain:

- cloud provider sees prompts and selected context;
- commands and logs may contain private machine data;
- API calls may cost money;
- local-only models are future/post-MVP unless implemented.

Acceptance criteria:

- Users understand what leaves the machine.

---

## UX polish that matters for MVP

### 29. Add clear first-run status

After install, show:

- whether Tailscale is logged in;
- whether provider token exists;
- whether chat service is running;
- whether desktop automation is ready;
- whether verification passed;
- exact next command to run.

Acceptance criteria:

- The final installer screen leaves the user with one obvious next step.

### 30. Add safe examples

Ship example prompts that demonstrate the intended product:

- "Explain this machine."
- "Check whether updates are available."
- "Why is Docker not usable yet?"
- "Take a screenshot and describe the desktop."
- "Open a browser to example.com."
- "Show recent failed systemd services."
- "Free disk space safely."

Acceptance criteria:

- New users do not have to invent the first interaction.

---

## Suggested implementation order

### Phase 1: Make the existing installer safer

1. Add CI.
2. Add `.gitignore`.
3. Add `QUICKSTART.md`, `SECURITY.md`, and `TROUBLESHOOTING.md`.
4. Add stronger preflight checks.
5. Add retry logic.
6. Add uninstall.
7. Add versioning and changelog.

### Phase 2: Make it a product

1. Add the local chat service.
2. Add SQLite history.
3. Add provider abstraction.
4. Add policy/approval model.
5. Add audit logging.
6. Add health checks.
7. Add first-run walkthrough.

### Phase 3: Make it shippable

1. Add integration tests.
2. Add Debian packaging.
3. Add release gates.
4. Refactor installer into modules.
5. Publish architecture and roadmap.

---

## MVP acceptance checklist

Ubuntu Zombie should not call itself a true MVP until all of these are
true:

- [ ] Fresh Ubuntu Desktop LTS install succeeds.
- [ ] Re-running install is safe.
- [ ] `verify` passes after reboot.
- [ ] Local private chat works.
- [ ] Tailscale-private remote access works.
- [ ] API token can be added, rotated, and removed.
- [ ] Removing the API token stops useful agent operation.
- [ ] Every privileged action requires policy-compliant approval.
- [ ] Every action is audit logged.
- [ ] Basic sysadmin tasks work end-to-end.
- [ ] Desktop screenshot and input helpers work.
- [ ] Browser automation works.
- [ ] Docker access works.
- [ ] Health check explains broken state.
- [ ] Uninstall removes privileged access.
- [ ] CI protects shell, docs, and install behavior.
- [ ] Security model and known risks are documented.
- [ ] Quickstart can be followed by a novice.

---

## Final recommendation

The most important change is not packaging, Docker, VNC, or even better
docs. The most important change is to close the loop between:

1. a human asking for help;
2. the AI reading local state;
3. the AI proposing an action;
4. the human approving it;
5. the system executing it as `agent`;
6. the system verifying the result;
7. the system recording what happened.

Once that loop exists, Ubuntu Zombie becomes a product. Without that
loop, it remains an impressive installer for an AI administrator that has
not quite arrived yet.
