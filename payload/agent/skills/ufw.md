<!-- triggers: ufw, firewall, iptables, nftables, port, ingress, egress -->
# Skill: UFW (Uncomplicated Firewall)

This skill is loaded when the operator mentions UFW, the firewall,
or port-level network policy.

Operating rules:

- `ufw status` (via `net.status` or `shell.run`) is `read_only` and
  runs automatically. Use it before suggesting any rule change.
- `ufw allow`/`deny`/`delete`/`reset` are `network_change`. Every one
  waits for explicit operator approval. `ufw --force reset` is
  destructive and requires the confirmation phrase.
- Never disable the firewall (`ufw disable`) as part of a routine
  diagnosis. If a service appears unreachable, prefer narrowing the
  rule rather than opening the firewall.
- The Ubuntu Zombie default policy expects SSH (22/tcp) and the chat
  service's loopback port to remain reachable; do not propose rules
  that would block them without explicit operator consent.
- When suggesting a rule, render it as a single command (e.g.
  `sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp`) so the
  operator can audit the exact effect before approving.
