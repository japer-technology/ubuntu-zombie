<!-- triggers: tailscale, tailnet, magicdns, ts0, tailscaled -->
# Skill: Tailscale (tailnet membership and status)

This skill is loaded when the operator mentions Tailscale, the
tailnet, or related networking terms.

Operating rules:

- `net.status` aggregates `ip`, `ufw status`, and `tailscale status`;
  prefer it over raw `shell.run` for read-only diagnostics.
- `tailscale up` / `tailscale logout` mutate the network identity of
  the host and are `network_change`. Always wait for operator
  approval, and never include an auth key in the rendered argv — the
  operator should pass it via the secrets file, not the chat.
- Avoid `tailscale set --ssh=true` unless the operator explicitly
  asked. The Ubuntu Zombie default keeps Tailscale SSH off in favour
  of the host's `sshd` so audit log and key handling stay consistent.
- If `tailscale status` reports "Logged out", surface that fact and
  ask the operator how to re-enrol; do not attempt re-auth silently.
- Treat the Tailscale IP and node name as identifiers, not secrets.
  Auth keys, OAuth client secrets, and the tailnet's preauth keys
  are secrets and must never be echoed.
