# Show HN

Guidance: Hacker News rewards plain, technical, honest posts. Lead with what it
is and the trust model. Expect — and welcome — hard questions about security.
Disclose that you are the author. No marketing language.

## Title (≤ 80 chars, pick one)

- `Show HN: Ubuntu Zombie – a root-capable AI sysadmin for your Ubuntu desktop`
- `Show HN: An approval-gated, audit-logged AI sysadmin that lives in your PC`
- `Show HN: Ubuntu Zombie – ask your machine to fix itself, approve every step`

## Body (first comment)

> Hi HN — I'm the author.
>
> Ubuntu Zombie is a transparent bash installer that adds a private,
> root-capable AI Systems Administrator account to a supported Ubuntu Desktop
> LTS machine (22.04 / 24.04). You open a private chat on 127.0.0.1, ask the
> machine — in plain English — to diagnose, explain, configure, repair, or
> operate itself, and it proposes the exact commands it would run. You approve;
> it acts; every action is written to an audit log.
>
> The design is built around keeping the operator in control:
>
> - A dedicated `zombie` Linux account (renameable) with passwordless sudo is
>   the operating identity of the agent — never a shared human login.
> - Privileged / destructive / networked actions are classified and pass
>   through a local policy gate that requires your approval before running.
> - Chat and VNC bind to 127.0.0.1 only. SSH is key-only with root login
>   disabled. Remote access is opt-in over a private Tailscale tailnet — the
>   public internet is never a control plane.
> - Revocation is first-class: rotate the provider API key, remove the SSH key,
>   disable Tailscale, or run `uninstall`, and the agent stops.
>
> What it deliberately does NOT do: run autonomously, do local-only inference
> (the MVP uses a configured cloud provider — your key), manage fleets, or
> replace the humans already using the desktop.
>
> You can preview the entire install with `sudo ./scripts/install.sh install
> --dry-run` (changes nothing). Signed `.deb` releases are available with
> SHA-256 checksums and keyless cosign signatures.
>
> Trust model and what the provider sees: SECURITY.md. Vision and the explicit
> non-goals: docs/VISION.md.
>
> Repo: https://github.com/japer-technology/ubuntu-zombie
>
> Happy to answer questions about the policy gate, the audit log, the threat
> model, or anything else.

## Prepared answers (have these ready)

- **"Root-capable AI is terrifying."** Agreed it deserves caution — that's why
  nothing privileged runs without your approval, everything is logged, and it's
  fully reversible. Point to `SECURITY.md`.
- **"What's actually sent to the LLM?"** Walk through the trust boundary in
  `SECURITY.md`; be specific and honest.
- **"Why not local models?"** On the roadmap; the MVP is cloud-provider-backed
  and we say so plainly.
- **"Isn't this just a wrapper around a chatbot + sudo?"** Explain the policy
  gate, action classification, approval flow, and audit log — that's the
  product, not the chat.

## Etiquette
- Post it yourself, engage in the thread for the first few hours.
- Never ask for upvotes; never use multiple accounts.
- Concede valid criticism gracefully — it builds more trust than defending.
