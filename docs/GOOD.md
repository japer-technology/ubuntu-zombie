# Advantages of `ARCHITECTURE-NEW.md` over `ARCHITECTURE.md`

`docs/ARCHITECTURE.md` and `docs/ARCHITECTURE-NEW.md` are almost identical.
The differences cluster around exactly **two design decisions**. This note
records what `ARCHITECTURE-NEW.md` changes and the advantage each change
buys.

## The two substantive differences

### 1. Two-layer model instead of three

The chat service is collapsed into the host body.

- `ARCHITECTURE.md`: three principals — L3 operator, L2 chat service
  (`zombie`), L1 host (`root`) — with the chat service drawn as its own
  trust layer.
- `ARCHITECTURE-NEW.md`: two principals. The chat service is reframed as a
  *host-local service of the host body* running as the unprivileged
  `zombie` user, not a separate trust boundary.

### 2. Drops Tailscale; SSH becomes plain key-only

- `ARCHITECTURE.md`: the only way in is an SSH tunnel over Tailscale
  (WireGuard); SSH is allowed only on `tailscale0`; the
  `ZOMBIE_SKIP_TAILSCALE` / `TAILSCALE_AUTHKEY` knobs exist; Tailscale
  appears in the policy `network_change` matchers, the redaction list
  (`tskey-…`, `TAILSCALE_AUTHKEY`), `health-check`, `repair`, the skills
  catalogue, and the failure-mode table.
- `ARCHITECTURE-NEW.md`: SSH is key-only (password authentication
  disabled) on port 22, with no Tailscale anywhere.

## Advantages of `ARCHITECTURE-NEW.md`

- **Simpler, more honest trust model.** Calling the chat service a "layer"
  overstates the boundary — it shares the `zombie` UID with the host, and
  the real boundary is the policy gate plus the closed tool registry, not a
  process or network separation. The two-principal framing (operator vs.
  host) matches where the actual security enforcement lives.
- **Fewer moving parts / smaller attack and dependency surface.** Removing
  Tailscale eliminates an external dependency, a daemon (`tailscaled`), an
  auth-key secret to manage and redact, and a set of config knobs
  (`ZOMBIE_SKIP_TAILSCALE`, `TAILSCALE_AUTHKEY`).
- **No third-party network dependency.** Key-only SSH/22 works on any host
  without enrolling in a Tailscale tailnet or trusting Tailscale's
  coordination server — easier to deploy in environments that already have
  their own network perimeter (VPN, security group, bastion).
- **Less documentation drift.** The Tailscale path carried conditional
  branches ("unless `ZOMBIE_SKIP_TAILSCALE=1`…") throughout the document;
  the new version is unconditional and easier to keep accurate.

## Important caveat

The advantages above are only *aspirational* today. The actual codebase
still implements Tailscale heavily — `scripts/install.sh` alone has roughly
138 references, plus `payload/etc/policy.yaml`, `payload/agent/tools.py`,
`payload/agent/runner.py`, `payload/agent/audit.py`,
`payload/agent/server.py`, a `payload/agent/skills/tailscale.md` skill, and
`payload/bin/collect-diagnostics`.

So today **`ARCHITECTURE.md` is the accurate description of what ships**, and
`ARCHITECTURE-NEW.md` reads as a *proposed / target* architecture. Its
concrete advantage as a document is only realized if the implementation is
actually simplified to match it; otherwise it would mislead readers about the
deployed security posture (notably, it drops the Tailscale-only-SSH
protection that the running system still relies on).
