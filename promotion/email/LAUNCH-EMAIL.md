# Launch & Newsletter Emails

Plain-text-friendly drafts. Replace bracketed fields. Keep subject lines short
and honest — no clickbait.

---

## Launch announcement email

**Subject lines (pick / A-B test):**
- Your Ubuntu PC can now administer itself — with your approval
- Introducing Ubuntu Zombie: an AI sysadmin that lives in your machine
- Ask your computer to fix itself (you approve every step)

**Preheader:** Open source, root-capable, audit-logged, and you hold the kill
switch.

**Body:**
> Hi [FIRST NAME],
>
> Today we're releasing **Ubuntu Zombie** — an open-source tool that adds a
> private, root-capable AI Systems Administrator to your Ubuntu Desktop LTS
> machine.
>
> Here's the whole idea: you open a private chat on your own machine, ask it —
> in plain English — to diagnose, configure, or repair something, and it shows
> you the exact commands it would run. You approve. It acts. Every step is
> written to an audit log.
>
> It's built around keeping you in control:
>
> • A local policy gate makes privileged actions wait for your approval
> • Services bind to 127.0.0.1; SSH is key-only; remote access is opt-in (Tailscale)
> • You own the SSH key, the API key, and the kill switch — `uninstall` reverses it all
> • It's a transparent bash installer — inspect every line
>
> Want to look before you leap? Preview the entire install without changing
> anything:
>
>     sudo ./scripts/install.sh install --dry-run
>
> ▶ Get started: https://github.com/japer-technology/ubuntu-zombie
> ▶ Read the trust model first: SECURITY.md
>
> Questions? Just reply, or open a Discussion on GitHub.
>
> — [YOUR NAME], Japer Technology
>
> Ubuntu is a trademark of Canonical Ltd. Ubuntu Zombie is an independent
> project, not affiliated with Canonical. MIT-licensed.
> [Unsubscribe] · [View in browser]

---

## Developer-newsletter blurb (for inclusion in others' newsletters, ≤ 80 words)

> **Ubuntu Zombie** — A private, root-capable AI Systems Administrator for
> Ubuntu Desktop LTS. Ask your machine to diagnose and fix itself in plain
> English; it proposes the commands, you approve, it acts, and everything is
> audit-logged. Local-first (binds to 127.0.0.1), key-only SSH, opt-in
> Tailscale, MIT-licensed, fully reversible. Preview it with `--dry-run`.
> https://github.com/japer-technology/ubuntu-zombie

---

## Follow-up email (T+7, to non-openers / for engagement)

**Subject:** What people asked us about Ubuntu Zombie

> Hi [FIRST NAME],
>
> Since we launched Ubuntu Zombie last week, the most common question has been
> the most important one: *"A root-capable AI — is that safe?"*
>
> Short answer: nothing privileged runs without your approval, every action is
> logged, and the whole thing is reversible. The long answer — the full trust
> boundary and what the LLM provider sees — is in SECURITY.md, and it's worth
> five minutes before you install.
>
> If you haven't tried it yet, start with the no-changes preview:
> `sudo ./scripts/install.sh install --dry-run`.
>
> Repo & docs: https://github.com/japer-technology/ubuntu-zombie
>
> — [YOUR NAME]
