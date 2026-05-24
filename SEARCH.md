# SEARCH.md

A research aid for finding projects similar to **Ubuntu Zombie**.

This file exists so that a person (or another AI) can run an extensive,
structured search of the public web, package registries, and code
forges for prior art, sibling projects, and competitors. It distills
what Ubuntu Zombie *is* into the vocabulary, queries, and reference
projects most likely to surface near-matches.

---

## 1. One-paragraph concept summary

Ubuntu Zombie turns an ordinary Ubuntu PC into a normal user machine
that *also* hosts a resident, root-capable "AI Systems Administrator."
The AI is authenticated by an external cloud LLM token provider (whose
API key sits in `secrets/env`), runs as a local `agent` account with
passwordless `sudo`, and is reachable by any local user as well as
remotely over a private Tailscale network (no public inbound exposure).
The PC is not converted into a sealed appliance or a remote box owned
by the AI vendor — it remains the operator's general-purpose Ubuntu
machine (desktop, server, Docker host, browser rig, etc.), with the
AI added as a privileged inhabitant rather than as the owner.

## 2. Distinguishing characteristics (use these as search filters)

When triaging candidates, score them against this list. A project is
"similar" to the extent it shares several of these — not just one.

1. **Host OS is Ubuntu / Debian Linux on a real or virtual PC**, not
   a container-only or cloud-only product.
2. **LLM-driven systems administration** — the AI acts as a sysadmin,
   not just as a chat assistant or coding copilot in an editor.
3. **Root-capable agent identity** — a dedicated local user (here:
   `agent`) with passwordless `sudo`, intended for unattended
   privileged action.
4. **External token provider as the AI's authenticator** — the cloud
   LLM API key is the effective credential that grants the AI its
   authority on the box.
5. **Multi-user contactable** — *any* human user of the PC can talk to
   the resident AI; it is not tied to a single owner's chat window.
6. **General-purpose machine preserved** — the installer adds an AI
   role on top of a normal Ubuntu install; it does not lock the box
   down into an appliance.
7. **Private network reachability via Tailscale (or WireGuard /
   mesh VPN)**, with no public inbound ports.
8. **Idempotent bash installer** that provisions SSH, sudoers, a VNC
   or remote-desktop path, firewall, and the agent account.
9. **Optional GUI / browser control surface** (VNC, X11, headful
   browser automation) so the AI can drive the desktop, not only the
   shell.
10. **Explicit, written trust model** that names the LLM vendor, the
    SSH key, and the Tailscale account as the privileged credential
    set.

The *combination* of #2 + #3 + #4 + #6 is the unusual signature.
Most "AI agent" projects miss at least one (usually #3 or #6).

## 3. Vocabulary to search for

Use these terms in combinations. Quote multi-word phrases.

### Names the concept is likely published under
- "AI systems administrator"
- "AI sysadmin"
- "LLM sysadmin"
- "agentic sysadmin"
- "resident AI agent"
- "AI operator" / "AI machine operator"
- "self-administering Linux"
- "AI-controlled Ubuntu" / "AI-controllable workstation"
- "LLM-managed server"
- "autonomous Linux host"
- "agent OS" / "agent-first OS"
- "computer-use agent" (Anthropic-style framing)
- "OS-level AI agent"
- "shell agent" / "terminal agent" with sudo

### Implementation-flavored terms
- `passwordless sudo` + `agent user` + `LLM`
- `tailscale` + `LLM` + `ubuntu` + `agent`
- `x11vnc` or `tigervnc` + `AI` + `desktop control`
- `headless ubuntu` + `LLM agent`
- `bash installer` + `ai assistant` + `ubuntu`
- `bootstrap script` + `ai operator` + `ubuntu`
- `playbook` + `llm sysadmin` (Ansible variants)

### Trust-model / governance terms
- "token provider authenticates agent"
- "API key as root credential"
- "local operator owns the machine, vendor supplies the model"

## 4. Concrete search queries

Copy-paste these into Google, DuckDuckGo, Kagi, and the GitHub search
bar. Re-run with `site:github.com`, `site:gitlab.com`,
`site:codeberg.org`, `site:news.ycombinator.com`, and
`site:reddit.com` filters.

### Web search
```
"AI systems administrator" ubuntu install
"resident AI" linux sudo agent
"LLM" "passwordless sudo" agent ubuntu installer
"computer use" agent ubuntu desktop vnc
ubuntu "ai agent" tailscale sudo installer
"agent user" "sudo" "openai" OR "anthropic" ubuntu bootstrap
self-hosted "ai sysadmin" linux
"installs an AI" ubuntu desktop browser docker
"normal ubuntu PC" AI agent
```

### GitHub code / repo search
```
filename:setup-part-1.sh
filename:install.sh "agent" "passwordless sudo" "tailscale"
"AGENT_USER" "TAILSCALE_AUTHKEY" "VNC_PASSWORD" in:file
"ai-full-control" in:file,path,name
"ai sysadmin" OR "ai systems administrator" in:readme
"resident administrator" in:readme
language:Shell "tailscale up" "visudo" "x11vnc" "openai"
topic:ai-agent topic:ubuntu
topic:computer-use topic:linux
topic:agentic-os
```

### Package / registry search
- npm: `ai-agent ubuntu`, `computer-use`, `desktop-agent`
- PyPI: `ai-sysadmin`, `linux-agent`, `computer-use-agent`
- Docker Hub: `ai-agent`, `agent-ubuntu`, `computer-use`
- Homebrew / apt: unlikely to host this class, but worth a scan.

## 5. Adjacent project categories (and what makes them *not* the same)

Search these categories, then explicitly note the delta from Ubuntu
Zombie so you do not file false positives.

| Category | Example projects to look up | Why it is close | Why it differs |
|---|---|---|---|
| Computer-use agents | Anthropic "computer use", OpenAI Operator, OpenInterpreter, Self-Operating-Computer, Cua, Pyautogui-based agents | LLM driving a real OS via shell/GUI | Usually launched per-session by one user; no resident multi-user sysadmin model; no install-it-into-Ubuntu posture |
| Local coding agents | Aider, Continue.dev, Cline, OpenDevin/OpenHands, SWE-agent, Devin clones | LLM with shell + file access | Scoped to a project/repo, not the whole host; rarely run as a root-capable system service |
| Shell assistants | ShellGPT, `aichat`, `tgpt`, Warp AI, Fig/Amazon Q, `gh copilot`, `aishell` | LLM in the terminal | No persistent privileged identity; user runs them ad-hoc; no system role |
| Self-hosted LLM "OS" attempts | LLMOS, AIOS, agent-OS experiments, Pieces OS, Open WebUI + tool servers | Frames the LLM as part of the OS | Tend to be appliance-style; often replace the user environment instead of layering on top of normal Ubuntu |
| Agentic frameworks installed on a host | AutoGPT, BabyAGI, CrewAI, LangGraph deployments, Goose (Block), smol-agents | LLM with tool use | Library/framework, not an installer that provisions an Ubuntu PC + sudo + Tailscale + VNC |
| Headless "AI VM" / sandbox runners | E2B sandboxes, Daytona, Coder, Codespaces, sandbox-fusion, Modal sandboxes | Give an LLM a Linux box | Ephemeral, cloud-hosted, vendor-owned; not "your Ubuntu PC with an admin in it" |
| Remote management agents | Ansible, Salt, Puppet, Rundeck, Cockpit, Webmin, Tailscale SSH | Privileged remote admin of a Linux host | No LLM; deterministic playbooks rather than a conversational administrator |
| Locked-down AI appliances | ChatGPT-on-a-box demos, Rabbit R1, dedicated kiosk builds, NVIDIA Project DIGITS images | Ship an AI on a machine | Sealed appliance; user does not retain general-purpose ownership of the OS |
| Tailscale + LLM tinkering | Various blog posts gluing Tailscale to an LLM bot | Same network posture | One-off scripts, not a full Ubuntu provisioning project with a trust model |

## 6. Named projects to check first

These are the highest-probability "near neighbors." Pull each one up
and grade it against Section 2.

- **OpenInterpreter** (open-interpreter/open-interpreter)
- **OpenHands / OpenDevin** (All-Hands-AI/OpenHands)
- **Self-Operating-Computer** (OthersideAI/self-operating-computer)
- **Anthropic computer-use reference container**
  (anthropics/anthropic-quickstarts → computer-use-demo)
- **Cua** (trycua/cua) — computer-use agent framework
- **Goose** (block/goose)
- **Aider** (paul-gauthier/aider)
- **Cline / Roo Code** (cline/cline)
- **AutoGPT, BabyAGI, AgentGPT** (historical baselines)
- **E2B** (e2b-dev/e2b) — sandboxed Linux for agents
- **Daytona** (daytonaio/daytona)
- **LLMOS / AIOS** (any repo using these names)
- **Shell-GPT** (TheR1D/shell_gpt), **aichat** (sigoden/aichat),
  **tgpt** (aandrew-me/tgpt)
- **Tailscale's own blog/examples on LLM bots over tailnet**
- **Cockpit + LLM** experiments, **Webmin + LLM** experiments
- Any repo whose README contains the phrase
  *"resident AI"* or *"AI systems administrator."*

## 7. Where to search beyond Google + GitHub

- **HackerNews** (Algolia: `https://hn.algolia.com/`) — search the
  terms in Section 3; sort by date for the last 12 months.
- **Lobste.rs** — tag `ai`, `linux`, `sysadmin`.
- **Reddit**: r/selfhosted, r/LocalLLaMA, r/linuxquestions,
  r/homelab, r/Ubuntu, r/sysadmin.
- **Codeberg, GitLab, SourceHut, Forgejo instances** — many
  self-hosting-flavored projects live off GitHub.
- **arXiv** — "LLM agent" + "operating system" + "privileged" for
  academic prior art.
- **YouTube / conference talks** — search talk titles for
  "AI sysadmin", "computer use agent", "agent OS".
- **Awesome lists** — `awesome-llm-agents`, `awesome-ai-agents`,
  `awesome-computer-use`, `awesome-selfhosted`.
- **Package READMEs on PyPI / npm / crates.io / Docker Hub** for the
  vocabulary in Section 3.

## 8. Triage checklist for each candidate

For every project you find, record:

1. Name, URL, license, last commit date.
2. Host model: appliance / library / installer-on-existing-OS / cloud
   sandbox / framework.
3. Does it create a privileged local user with passwordless `sudo`?
4. Who authenticates the agent? (Local config? Cloud vendor API key?
   Hardware token?)
5. Can multiple local users contact the same agent instance?
6. Network exposure model: public, LAN, mesh VPN (Tailscale /
   WireGuard / Nebula / ZeroTier), local-only?
7. Does it preserve the host as a general-purpose machine, or convert
   it into an appliance?
8. Does it touch the GUI / desktop / browser, or shell only?
9. Stated trust model: present and explicit, present and vague, or
   absent?
10. Score 0–10 against Section 2; anything ≥ 6 is worth a closer
    write-up.

## 9. Anti-matches to filter out quickly

These keep appearing in searches but are *not* what we are looking
for, and can be discarded fast:

- IDE / editor copilots (Cursor, Copilot, Cody, Continue) — scoped to
  source code, not the OS.
- Pure chat UIs over local models (Ollama UIs, LM Studio, Jan,
  AnythingLLM) — no privileged action on the host.
- RPA tools (UiPath, Power Automate Desktop) — not LLM-native, not
  Linux-resident.
- Cloud "AI VPS" marketing pages — hosted services, not installers
  for the user's own Ubuntu PC.
- ChatOps bots (Hubot, Errbot) — chat-driven, but not root-capable
  general-purpose administrators.

## 10. Hand-off prompt for a search agent

If you delegate the actual searching to another AI, paste this:

> Find open-source projects that install a root-capable, LLM-driven
> "AI systems administrator" onto an existing Ubuntu (or
> Debian-family) PC, while leaving the PC usable as a normal
> general-purpose machine for human users. The AI must be reachable
> by any local user, authenticated via an external LLM provider's API
> key, and reachable remotely only over a private mesh VPN such as
> Tailscale. Exclude: editor copilots, ephemeral cloud sandboxes,
> sealed appliances, and frameworks that do not ship an Ubuntu
> installer. For each candidate, report name, URL, license, last
> commit date, and a 0–10 similarity score against the criteria in
> sections 2 and 8 of this SEARCH.md.
