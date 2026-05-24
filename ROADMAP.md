# Roadmap

Post-MVP work, extracted from `POSSIBILITIES-1.md`, `POSSIBILITIES-2.md`,
and the latter sections of `RECOMMENDATIONS-1.md`. Order is suggestive,
not committed.

## Near-term (next milestone)

- Debian packaging (`debian/control`, `postinst`, `prerm`, `postrm`)
  with package-owned paths under `/usr/lib/ubuntu-zombie`,
  `/etc/ubuntu-zombie`, and `/opt/ai-zombie/`.
- VM/container integration tests that:
  - run the installer in non-interactive mode in a fresh image,
  - assert idempotency by running it twice,
  - assert required files, users, services, permissions, firewall
    rules,
  - exercise `verify`, `doctor`, `repair`, and `uninstall`,
  - test documented failure paths (missing key, no network, apt lock,
    Tailscale logged out, bad secrets perms, absent display).
- Refactor the installer into modules under `payload/installer/` once
  CI is mature.

## Provider and model

- Local provider (Ollama) for fully-offline operation.
- Per-action model selection (cheap for classification, expensive for
  reasoning).
- Token cost meter surfaced in the chat UI and audit log.
- Provider-side prompt-injection mitigations beyond approval gating.

## Operator UX

- Native desktop entry for "Ask the administrator" that opens the
  chat URL.
- GNOME indicator showing service health and last audit summary.
- TUI for shell-only environments.
- First-run wizard that walks through API key, policy review, and a
  sample command.

## Trust and compliance

- Optional `sudo` wrapper that logs every AI-initiated invocation
  with the approval ID.
- Signed audit log (append-only, hash-chained).
- SELinux / AppArmor profile for the chat service.
- Encrypted-at-rest state under `/opt/ai-zombie/state/`.

## Fleet

- Configuration profiles checked in by the operator, applied at
  install time.
- Read-only fleet dashboard fed by audit logs.
- Multi-tenant operator accounts on the same machine.

## Out of scope for the foreseeable future

- Public internet exposure of any service installed by this project.
- Hosted SaaS variant.
- Replacing the human operator. Ubuntu Zombie is an assistant; the
  operator is in charge.
