# Press Kit — Ubuntu Zombie

A one-page reference for journalists, reviewers, and content creators. For
quotable Q&A see [`../messaging/FAQ-PRESS.md`](../messaging/FAQ-PRESS.md).

## At a glance

| | |
| --- | --- |
| **Product** | Ubuntu Zombie |
| **Publisher** | Japer Technology — <https://www.japer.technology> |
| **What it is** | A private, root-capable AI Systems Administrator for Ubuntu Desktop LTS |
| **Licence** | MIT (open source) |
| **Platforms** | Ubuntu Desktop LTS 22.04, 24.04 |
| **Repository** | <https://github.com/japer-technology/ubuntu-zombie> |
| **Latest release** | <https://github.com/japer-technology/ubuntu-zombie/releases/latest> |
| **Pricing** | Free; operator supplies their own LLM provider key |

## One-sentence description

Ubuntu Zombie adds a private, root-capable AI Systems Administrator account to a
supported Ubuntu Desktop LTS machine, so the owner can ask the computer to
diagnose, explain, configure, repair, and operate itself — in plain language,
under explicit human approval, with every action audit-logged and reversible.

## Three things that make it notable

1. **It has hands, but you hold the leash.** It runs real commands on the real
   machine — only after you approve them through a local policy gate.
2. **Honest about risk.** It grants a root-capable identity and says so;
   `SECURITY.md` documents the full trust boundary up front.
3. **Local-first and reversible.** Services bind to localhost, SSH is key-only,
   remote access is opt-in over Tailscale, and `uninstall` reverses everything.

## Approved quotes
> "You ask, it proposes, you approve, it acts, and it logs everything."
> — [SPOKESPERSON], Japer Technology

> "Ubuntu Zombie closes the gap between 'my laptop is broken' and the exact
> command that fixes it — without taking the machine away from its owner."
> — [SPOKESPERSON], Japer Technology

## Boilerplate
See [`../messaging/BOILERPLATE.md`](../messaging/BOILERPLATE.md) for short/long
boilerplate, the company description, and the trademark disclaimer.

## Visual assets
Logo and brand artwork: [`../../LOGO.png`](../../LOGO.png) and the files listed
in [`../assets/ASSET-MANIFEST.md`](../assets/ASSET-MANIFEST.md). Logo usage
rules: [`../brand/BRAND-GUIDELINES.md`](../brand/BRAND-GUIDELINES.md).

## What it is NOT (please don't mis-report)
- Not autonomous — it never acts on privileged operations without approval.
- Not a hosted service — it's an open bash installer on the user's own machine.
- Not local-inference (yet) — the MVP uses a configured cloud LLM provider.
- Not affiliated with Canonical / Ubuntu.

## Contact
[NAME] · [EMAIL] · [HANDLE]
