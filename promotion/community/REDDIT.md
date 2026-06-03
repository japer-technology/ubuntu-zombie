# Reddit Launch Posts

Reddit is community-first. Read each subreddit's rules and self-promotion
policy before posting. **Disclose that you are the author.** Don't reuse
identical text across subreddits — adapt to each community. Link the repo and
the docs, then answer questions honestly.

Good targets: r/linux, r/Ubuntu, r/selfhosted, r/sysadmin (read rules — strict),
r/opensource, r/LocalLLaMA (note: this is cloud-backed in the MVP; be upfront).

---

## r/linux / r/opensource

**Title:** Ubuntu Zombie: an open-source, approval-gated AI Systems
Administrator that lives inside your Ubuntu desktop

**Body:**
> I built Ubuntu Zombie (MIT, author here). It's a transparent bash installer
> that adds a private, root-capable AI Systems Administrator account to Ubuntu
> Desktop LTS (22.04 / 24.04).
>
> You open a private chat on 127.0.0.1 and ask the machine, in plain English,
> to diagnose, explain, configure, repair, or operate itself. It proposes the
> exact commands; a local policy gate makes privileged actions wait for your
> approval; it runs them; everything is audit-logged and reversible.
>
> Control specifics: dedicated `zombie` account (renameable) holds the sudo
> authority — not a human login; chat/VNC bind to localhost; SSH is key-only,
> root disabled; remote access is opt-in over Tailscale. You own the SSH key,
> the API key, and the kill switch (`uninstall` reverses everything).
>
> It deliberately is NOT autonomous, NOT a hosted service, and (for now) NOT
> local-inference — the MVP uses a configured cloud LLM provider with your own
> key. Roadmap covers on-device models.
>
> Preview the whole thing with `install --dry-run` (no changes). Trust model:
> SECURITY.md. Repo: https://github.com/japer-technology/ubuntu-zombie
>
> Feedback welcome, especially on the security posture.

---

## r/selfhosted

**Title:** Self-hosted, root-capable AI sysadmin for Ubuntu LTS — local-first,
audit-logged, you hold the keys

**Body:**
> For the self-hosting crowd: Ubuntu Zombie installs a root-capable AI Systems
> Administrator onto your own Ubuntu LTS box. No third party holds the keys —
> you do. Services bind to 127.0.0.1; remote access is opt-in over your own
> Tailscale tailnet; SSH is key-only with root disabled.
>
> You ask it (plain English) to fix or configure things; it proposes commands;
> you approve; it acts; it logs. Signed `.deb` releases with checksums + cosign
> signatures. MIT-licensed, open bash installer — inspect everything.
>
> Bring your own LLM provider key. Repo + docs:
> https://github.com/japer-technology/ubuntu-zombie — happy to answer anything.

---

## r/Ubuntu

**Title:** Made a tool that lets you ask your Ubuntu machine to fix itself (with
your approval, fully logged)

**Body:**
> Author here. Ubuntu Zombie adds a private AI Systems Administrator to Ubuntu
> Desktop LTS. When something breaks, you ask the machine in plain English; it
> shows you the exact commands it would run; you approve; it does it; and it
> keeps an audit log. Key-only SSH, localhost-only services, opt-in Tailscale,
> and an `uninstall` that reverses it all.
>
> Supports 22.04 and 24.04. Open source (MIT). Try `install --dry-run` first to
> see the plan with zero changes. https://github.com/japer-technology/ubuntu-zombie

---

## Etiquette reminders
- One post per subreddit; space them out; follow each sub's frequency rules.
- Reply to comments; treat criticism as a gift.
- Never vote-manipulate or use alt accounts.
