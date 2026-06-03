# Positioning & Value Propositions

## Positioning statement

> **For** owners of Ubuntu Desktop LTS machines who maintain their own
> computers but aren't full-time sysadmins,
> **Ubuntu Zombie** is an AI Systems Administrator that lives inside the
> machine
> **that** lets them diagnose, repair, and operate the PC in plain language
> under explicit approval,
> **unlike** generic AI chat assistants or remote IT services,
> **because** it acts with real root authority on the actual machine, gates
> every privileged action behind the operator's approval, audit-logs
> everything, and leaves the operator holding every key and the kill switch.

## Target audiences

| Audience | Pain | What lands |
| -------- | ---- | ---------- |
| Tinkerers / homelab / self-hosters | Tedious diagnosis; fear of breaking the box | Dry-run plans, audit log, reversible install |
| Small-business / solo operators | No IT department; downtime costs money | "A sysadmin on call inside the PC" |
| Linux-curious power users | Command-line friction | Plain-language chat that still shows the commands |
| Security-minded developers | Distrust of agentic AI | Policy gate, localhost binding, key-only SSH, open bash installer |

## Core value propositions

1. **It actually administers the machine.** Not advice you have to retype — a
   root-capable account that runs the commands, after you approve them.
2. **You approve before anything privileged happens.** A local policy gate
   classifies destructive/networked/system-altering actions and surfaces them
   first.
3. **Everything is audit-logged.** What was asked, proposed, approved, and done
   — all recorded and inspectable.
4. **You hold every key.** SSH key, API key, Tailscale account, policy file,
   kill switch. Rotate or revoke any of them at any time.
5. **Local-first and private.** Chat and VNC bind to `127.0.0.1`; SSH is
   key-only and root-disabled; remote access is opt-in over Tailscale.
6. **Transparent and reversible.** A bash installer on a normal Ubuntu LTS
   system. Inspect every component; `uninstall` reverses it.

## Proof points (link these, don't just assert them)

- `install --dry-run` previews the entire plan with zero changes.
- `verify`, `doctor`, and `repair` subcommands for read-only checks and
  known-safe fixes.
- Signed `.deb` releases with SHA-256 checksums and keyless cosign signatures.
- CI, CodeQL, and an OpenSSF Scorecard badge on the repository.
- Full trust boundary documented in [`../../SECURITY.md`](../../SECURITY.md).

## Objection handling

| Objection | Response |
| --------- | -------- |
| "Root-capable AI sounds dangerous." | Correct to be cautious. That's why every privileged action is gated behind your approval, audit-logged, and reversible — read `SECURITY.md` before installing. |
| "Does it phone home / is it a hosted service?" | No. It's an open bash installer; services bind to localhost; you configure your own LLM provider key and can rotate or remove it. |
| "What if the AI does something wrong?" | Nothing privileged runs without your approval, and everything is logged. `doctor`/`repair`/`uninstall` are first-class. |
| "Local inference?" | The MVP uses a configured cloud provider; on-device models are roadmap, not shipped here. Be upfront about it. |

## Competitive framing (neutral, factual)

- **vs. a generic AI chatbot:** Ubuntu Zombie has hands — it can run the fix on
  the real machine, gated by approval — not just describe one.
- **vs. remote IT / managed services:** No third party holds the keys; the
  operator does. It's local, private, and auditable.
- **vs. autonomous "agent" frameworks:** Deliberately *not* autonomous. One
  machine, one operator, approval before privilege.
