# SIMILAR.md

A survey of projects that share part of the **Ubuntu Zombie** design — *a
normal Ubuntu PC with a resident, root-capable AI Systems Administrator,
authenticated by an external LLM token provider, contactable by any local
user, and reachable remotely only over a private mesh VPN*.

This file applies the queries, vocabulary, and triage checklist defined
in [`SEARCH.md`](./SEARCH.md). Each candidate is graded against the ten
distinguishing characteristics in `SEARCH.md` §2:

1. Host OS is Ubuntu/Debian on a real or virtual PC
2. LLM acts as **systems administrator** (not chat/coding copilot)
3. Dedicated **root-capable local user** with passwordless `sudo`
4. **External LLM token** is the agent's authenticator
5. **Multi-user contactable** by any local user of the PC
6. **General-purpose machine preserved** (not an appliance)
7. **Tailscale / mesh VPN** reachability, no public inbound
8. **Idempotent bash installer** (SSH, sudoers, VNC, firewall, agent
   account)
9. **GUI / desktop / browser control** surface, not shell only
10. **Explicit written trust model** naming vendor + SSH key + Tailscale
    account as the credential set

Scores are 0–10, one point per criterion. The signature combination
`#2 + #3 + #4 + #6` is the unusual one; missing any of those four drops
a candidate out of the close-neighbour tier even when its total looks
high.

> Snapshot: research conducted **May 2026**. Repository activity,
> licenses, and feature claims are taken from project READMEs, package
> registries, official blog posts, and third-party reviews cited inline
> below. Verify before relying on them for security-sensitive
> decisions.

---

## TL;DR — there is no exact match

After applying `SEARCH.md`, **no public project was found that hits all
of `#2 + #3 + #4 + #6` simultaneously**, let alone the full ten. The
ecosystem clusters into seven categories, each of which lands near
Ubuntu Zombie on one axis and falls off on another:

| Closest neighbour | Signature it shares | Signature it misses |
|---|---|---|
| **MauveAvenger/llm-agent-installer** | Ubuntu installer, on-host LLM agent with Docker-root reach, preserves general-purpose PC | Local Ollama model (no external token provider as the authenticator), no Tailscale, no multi-user contact model, no written trust model |
| **Anthropic computer-use demo** | LLM as a general OS operator with desktop+browser, authenticated by Anthropic API key | Container appliance, single ephemeral user, no Tailscale, no install-into-your-Ubuntu posture |
| **block/goose** | Token-provider-authenticated on-machine agent that *can* be given shell + sudo, cross-platform | Per-user CLI/desktop tool, not a resident multi-user sysadmin, no installer that creates `agent` + sudoers + Tailscale |
| **skorokithakis/sysaidmin** | Explicit "GPT-powered sysadmin" framing, runs real privileged commands on Linux, token-provider authenticated | Per-user CLI, no resident service, no mesh VPN, no multi-user contact, no dedicated agent account |
| **OpenInterpreter** | On-machine LLM that edits files, runs shell, drives the desktop, token-provider authenticated | Per-user CLI, optional server mode is not a multi-user privileged sysadmin role |
| **trycua/cua** | Computer-use agents on real OS with desktop control | Sandbox/VM framework; agent runs inside disposable VMs, not as a resident admin on the user's PC |
| **All-Hands-AI/OpenHands** | Token-provider-authenticated autonomous agent that runs shell + browser | Always sandboxed in Docker, scoped to coding/engineering tasks, not a host sysadmin |

The closest single repo to the *spirit* of Ubuntu Zombie is
**`MauveAvenger/llm-agent-installer`**, which is also a bash installer
that adds an LLM-driven, Docker/root-capable agent onto an Ubuntu
machine — but it uses a *local* Ollama model rather than an external
token provider, lacks Tailscale, and has no multi-user contact model.

Full per-project breakdowns follow.

---

## 1. High-similarity neighbours (score ≥ 5)

### 1.1 MauveAvenger / llm-agent-installer
- **URL:** <https://github.com/MauveAvenger/llm-agent-installer>
- **License:** No `LICENSE` file detected — effectively *all rights
  reserved*. Treat as non-redistributable until clarified.
- **Last commit:** Very recently active (commits within hours of the
  snapshot, e.g. `0949f9e` "Fix installation URLs in README.md").
- **Host model:** Idempotent installer (`install.sh`) for
  **Ubuntu Server 24.04 LTS**. Installs Docker, Ollama, SearXNG, and
  related Python tools onto an existing Ubuntu host.
- **Agent identity:** LLM (Llama 3.1 8B) runs inside Docker
  containers. The installing user is added to the `docker` group,
  giving effectively root-equivalent privileges; there is no
  *dedicated* `agent` account separate from the operator.
- **Authentication of the agent:** **Local** — the model is hosted on
  the box via Ollama. There is no external token provider.
- **Multi-user contact:** Not designed in. Whoever can reach the
  exposed web UIs (or the host) talks to it.
- **Network exposure:** No Tailscale or mesh VPN integration. Docker
  Compose may bind services to `0.0.0.0` by default; the operator is
  responsible for firewalling.
- **GUI / desktop control:** No native desktop control; web UI for
  chat + SearXNG search.
- **Written trust model:** Minimal — README warns that passwordless
  Docker access is "significant".

**Scoring against §2:** 1 ✓, 2 ✓ (advertised as full system control),
3 ✓ (Docker-group is effectively passwordless root), 4 ✗ (local
model, not a token provider), 5 ✗, 6 ✓, 7 ✗, 8 ✓, 9 ~ (browser via
search/Docker, not desktop), 10 ✗ → **~5/10**

**Delta from Ubuntu Zombie:** Same installer-on-existing-Ubuntu
posture, but inverts the trust model (model is local, not vendor) and
omits Tailscale and the multi-user resident-administrator framing.

---

### 1.2 skorokithakis / sysaidmin
- **URL:** <https://github.com/skorokithakis/sysaidmin>
  · PyPI: <https://pypi.org/project/sysaidmin/>
- **License:** AGPL-3.0-or-later.
- **Last commit:** Actively maintained; available via Homebrew formula
  and PyPI.
- **Host model:** Per-user Python CLI tool (`sysaidmin "why does port
  22 not work on localhost?"`). No installer for an Ubuntu service
  account or sudoers entry.
- **Agent identity:** Runs as the invoking shell user. No dedicated
  account.
- **Privileged action:** Executes real shell commands on the host,
  **but with explicit per-command keypress approval** by the human.
  If the user runs it under `sudo`, it can perform privileged actions
  — there is no integrated passwordless-sudo flow.
- **Authentication:** **External LLM token** —
  `SYSAIDMIN_API_KEY` for OpenAI/Gemini etc.
- **Multi-user:** No native multi-user model.
- **Network:** Local CLI, no remote contact surface, no Tailscale.
- **Trust model:** Implicit (human-in-the-loop on every command).

**Scoring:** 1 ✓, 2 ✓ (explicitly framed as "sysadmin"), 3 ✗
(no agent account; no passwordless sudo), 4 ✓, 5 ✗, 6 ✓, 7 ✗, 8 ✗,
9 ✗ (shell only), 10 ~ → **~4–5/10**

**Delta:** Same naming and same token-provider authentication, but
sysaidmin is an interactive *tool*, not a resident *role*. It does
not install itself, it does not own a privileged account, and it is
never reachable by other local users.

---

### 1.3 Anthropic computer-use demo (anthropics/anthropic-quickstarts → `computer-use-demo`)
- **URL:** <https://github.com/anthropics/anthropic-quickstarts>
- **License:** MIT.
- **Last commit:** Actively maintained; image updated for Claude 4.x
  models.
- **Host model:** **Container** — `docker run ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest`.
  Ships a self-contained Ubuntu desktop image with X, a window
  manager, Firefox, bash, and the agent loop. Recommended to run only
  in a disposable VM.
- **Agent identity:** Runs as the in-container non-root user
  `computeruse`. `sudo` is installed but not used by default.
- **Authentication:** **External LLM token** — `ANTHROPIC_API_KEY`
  (or Bedrock/Vertex equivalents). This is the canonical example of
  "token provider authenticates the AI."
- **Multi-user:** Single ephemeral session per container.
- **Network exposure:** Container publishes ports 8080 (combined UI),
  8501 (Streamlit), 6080 (noVNC), 5900 (raw VNC). Documentation
  explicitly recommends `localhost` binding or an SSH tunnel; no
  built-in Tailscale.
- **GUI / desktop control:** Yes — full virtual desktop and browser
  control via the Anthropic computer-use tools.
- **Trust model:** Documented and explicit: "run only in a VM you do
  not care about; do not give it credentials".

**Scoring:** 1 ✓ (Ubuntu inside the container), 2 ~ (operator more
than sysadmin), 3 ✗, 4 ✓, 5 ✗, 6 ✗ (appliance container), 7 ✗,
8 ✗ (Dockerfile, not bash installer), 9 ✓, 10 ✓ → **~5/10**

**Delta:** This is the cleanest published expression of *"a cloud LLM
vendor's API key is the effective root credential of a Linux box,"*
but it is delivered as a sealed Docker appliance — the opposite of
Ubuntu Zombie's "your PC stays your PC" posture.

---

### 1.4 block / goose
- **URL:** <https://github.com/block/goose> (and the AAIF mirror
  `aaif-goose/goose` after the December 2025 contribution to the
  Linux Foundation Agentic AI Foundation).
- **License:** Apache-2.0.
- **Last commit:** Heavily active; thousands of commits, frequent
  releases.
- **Host model:** Cross-platform **on-machine** agent (CLI +
  desktop app) built on the Model Context Protocol (MCP). Designed
  to run on the user's own machine, not in a sandbox.
- **Agent identity:** Runs as the invoking desktop/shell user. No
  dedicated `agent` account in the installer.
- **Privileged action:** Configurable permission model; can be wired
  to shell, files, scripts, and (with explicit configuration) sudo.
  Block markets it for serious automation; passwordless sudo is
  *possible* but not the default.
- **Authentication:** **External LLM token** — supports 25+
  providers (Anthropic, OpenAI, Google, local Ollama, etc.).
- **Multi-user:** No — per-user app on the desktop or per-user CLI.
- **Network exposure:** Local first; no Tailscale integration in the
  default installer.
- **GUI / desktop control:** Limited (file/shell/MCP servers, plus
  optional browser tools via MCP), not a full computer-use desktop
  driver.
- **Trust model:** Documented permission settings and audit log, but
  no privileged "resident admin" framing.

**Scoring:** 1 ✓, 2 ~ (sysadmin-capable but framed as developer/code
agent), 3 ~ (configurable, not default), 4 ✓, 5 ✗, 6 ✓, 7 ✗, 8 ~
(installer exists, but not the sudoers/SSH/VNC bundle), 9 ~,
10 ~ → **~5/10**

**Delta:** Closest "serious local agent + token provider" of the
mainstream coding-agent crop, but it is a per-user app, not a
host-wide role. No multi-user contact model, no dedicated agent
account, no Tailscale.

---

### 1.5 Open Interpreter (OpenInterpreter / open-interpreter)
- **URL:** <https://github.com/OpenInterpreter/open-interpreter>
- **License:** AGPL-3.0 (commercial licensing available).
- **Last commit:** Very active (3000+ commits, recent activity within
  the week).
- **Host model:** Per-user CLI (`interpreter`) installed via
  `pip install open-interpreter` or the one-liner
  `oi-linux-installer.sh`. Optional `[os]` extras enable
  computer-use; optional `[server]` extras enable a local HTTP
  server.
- **Agent identity:** Runs as the invoking user. **No passwordless
  sudo by default.** Asks before each execution.
- **Authentication:** **External LLM token** (OpenAI, Anthropic,
  many others) or local model via Ollama/LM Studio.
- **Multi-user:** Not in default mode; "server mode" exists but
  isn't a multi-user privileged sysadmin role out of the box.
- **Network exposure:** Local by default; no Tailscale integration.
- **GUI / desktop control:** Yes via the `[os]` extras
  (PyAutoGUI-based screen+mouse+keyboard control).
- **Trust model:** Per-command approval; no formal trust statement
  comparable to Ubuntu Zombie's.

**Scoring:** 1 ✓, 2 ~ (operator more than sysadmin), 3 ✗, 4 ✓, 5 ✗,
6 ✓, 7 ✗, 8 ~, 9 ✓, 10 ✗ → **~5/10**

**Delta:** Shares the philosophy (local LLM-driven action under a
token provider), but stays a *tool* a single user starts, not a
*resident* the machine carries.

---

### 1.6 All-Hands-AI / OpenHands (formerly OpenDevin)
- **URL:** <https://github.com/All-Hands-AI/OpenHands>
- **License:** MIT core; `enterprise/` directory source-available
  under a paid license.
- **Last commit:** Daily.
- **Host model:** Always runs agent sessions inside **Docker
  sandboxes**, never directly on the host root. Deployable as CLI,
  GUI, SDK, OpenHands Cloud (SaaS), or self-hosted enterprise via
  Kubernetes.
- **Agent identity:** Sandbox container user; no privileged role on
  the host.
- **Authentication:** **External LLM token** — model-agnostic
  (Anthropic, OpenAI, Gemini, local).
- **Multi-user:** Multi-user on the cloud/enterprise SaaS, but each
  session is its own sandbox; not the "any local user of the PC can
  message the same resident admin" pattern.
- **Network:** Browser UI + REST API; no Tailscale integration in
  the installer.
- **GUI / desktop control:** Yes — agent runs a desktop inside the
  sandbox.
- **Trust model:** Sandbox isolation is the documented safety
  posture.

**Scoring:** 1 ~ (host Ubuntu OK, but agent lives in container),
2 ~ (coding agent more than sysadmin), 3 ✗ (no host root), 4 ✓, 5 ~,
6 ✓ (host is preserved precisely because the agent is sandboxed away
from it), 7 ✗, 8 ✗ (Docker-first), 9 ✓, 10 ~ → **~5/10**

**Delta:** OpenHands deliberately *refuses* the Ubuntu Zombie
trade-off — it sandboxes the agent away from the host. That
isolation is its core safety claim. The two projects are
philosophical opposites on §3 and §6.

---

### 1.7 trycua / cua
- **URL:** <https://github.com/trycua/cua>
- **License:** MIT (some Microsoft-derived modules CC-BY-4.0).
- **Last commit:** Hourly-cadence development.
- **Host model:** Framework for **virtualised, sandboxed desktops**
  (Lume on Apple Silicon; QEMU/Docker on Linux/Windows). Agent
  drives a VM, not the user's host OS.
- **Agent identity:** Inside the sandbox VM.
- **Authentication:** External LLM token; provider-agnostic.
- **Multi-user:** Engineered for many concurrent agent sandboxes.
- **Network:** N/A in the Ubuntu-Zombie sense.
- **GUI / desktop control:** Core feature.
- **Trust model:** Sandbox-first.

**Scoring:** 1 ~, 2 ~, 3 ✗, 4 ✓, 5 ✗, 6 ✓, 7 ✗, 8 ✗, 9 ✓,
10 ~ → **~4–5/10**

**Delta:** Same family as OpenHands' container model and the
Anthropic demo — every agent gets a disposable desktop. Ubuntu
Zombie inverts this: the resident admin lives *on* the operator's
real machine.

---

### 1.8 OthersideAI / Self-Operating-Computer
- **URL:** <https://github.com/OthersideAI/self-operating-computer>
- **License:** MIT.
- **Last commit:** Last release `1.5.8` (Feb 2025); slower cadence
  than the leaders.
- **Host model:** `pip install self-operating-computer` then `operate`
  — per-user CLI on macOS / Windows / Linux (X required).
- **Agent identity:** Invoking user. Requires accessibility/screen-
  recording permissions, not root.
- **Authentication:** **External LLM token** for GPT-4o / Gemini /
  Claude / Qwen-VL; LLaVA via Ollama for local.
- **Multi-user / network:** No.
- **GUI / desktop control:** Yes, via screenshot → vision-LLM →
  mouse/keyboard loop.
- **Trust model:** None formal.

**Scoring:** 1 ✓, 2 ~ (operator), 3 ✗, 4 ✓, 5 ✗, 6 ✓, 7 ✗, 8 ✗, 9 ✓,
10 ✗ → **~4/10**

**Delta:** Pioneer of the computer-use pattern, but a single-user
session tool — no installer, no resident role, no privileged
identity.

---

## 2. Adjacent but clearly *not* the same

### 2.1 Coding / IDE copilots — exclude

| Project | URL | License | Why excluded |
|---|---|---|---|
| **Aider** | <https://github.com/Aider-AI/aider> | Apache-2.0 | Per-invocation terminal CLI scoped to a single git repo; not OS-wide; not a service; no privileged identity. |
| **Cline** | <https://github.com/cline/cline> | Apache-2.0 | VSCode extension; runs as the IDE user; per-action approval; not a system role. |
| **Roo Code** | (Cline fork) | Apache-2.0 | Same scope as Cline — IDE-bound, no host-wide administration. |
| **Cursor / Copilot / Continue / Cody** | (commercial / mixed) | various | Editor copilots; explicitly listed as anti-matches in `SEARCH.md` §9. |

These hit `#4` (token-authenticated) but miss `#2`, `#3`, `#5`, `#7`,
`#8`, `#9`, and `#10`. They administer your *codebase*, not your
*machine*.

### 2.2 Shell assistants — exclude

| Project | URL | License | Notes |
|---|---|---|---|
| **shell_gpt (sgpt)** | <https://github.com/TheR1D/shell_gpt> | MIT | Per-user CLI. Suggests/runs shell commands; not a privileged service. |
| **aichat** | <https://github.com/sigoden/aichat> | MIT (Apache-2.0 dual-licensed on some files) | Terminal chat client; per-user. |
| **tgpt** | <https://github.com/aandrew-me/tgpt> | GPL-3.0 | Terminal chatbot; per-user, no privileged action. |

Score against §2: roughly 1 ✓ + 4 ✓ only → **~2/10** each.
Same shape as `SEARCH.md` §5 row "shell assistants".

### 2.3 Agentic OS / LLM-OS — exclude

- **agiresearch / AIOS** — <https://github.com/agiresearch/AIOS>,
  CC-BY-4.0. Despite the name, it is a user-space **framework/kernel
  abstraction** installed on top of Ubuntu via `install/install.sh`;
  provides scheduling, memory, and an SDK (Cerebrum) for building
  agents. It does **not** create a privileged Linux account, does not
  ship a Tailscale or VNC story, and is not pitched as a resident
  sysadmin. Score against §2: **~3/10**.
- **"LLMOS"** — not a single dominant project; the term is used
  loosely. Treat as a category synonym for AIOS-style work.

### 2.4 Sandboxed agent runtimes — exclude

- **e2b-dev / e2b** — <https://github.com/e2b-dev/e2b>, Apache-2.0.
  Cloud (or BYOC self-host) sandboxes that *agents borrow*, not a
  resident administrator inside your Ubuntu PC. Misses `#3`, `#5`,
  `#6`, `#7`, `#8`, `#10`. Score: **~2/10**.
- **daytonaio / daytona** — <https://github.com/daytonaio/daytona>,
  Apache-2.0. Manages disposable dev workspaces (Docker-/OCI-based);
  installable on Ubuntu via `curl … | bash` or the APT repo. It is
  the *substrate* on which an agent might run, not an agent itself.
  Score: **~2/10**.
- **Modal sandboxes, Coder, Codespaces, sandbox-fusion** — same
  delta.

### 2.5 Self-hosted "LLM stack over Tailscale" recipes — close on §7 only

Several blog posts and example repos describe gluing **Ollama +
Open WebUI + Tailscale** (or Open WebUI + OpenClaw + Tailscale on a
VPS) together so that a private LLM chat UI is reachable only over
the tailnet:

- Tailscale blog — *Self-host a local AI stack and access it from
  anywhere* (<https://tailscale.com/blog/self-host-a-local-ai-stack>).
- *Deploy your own 24/7 AI agent on AWS EC2 with Docker & Tailscale*
  (dev.to).
- *How to access Ollama remotely with Tailscale* (Logarithmic
  Spirals).
- Pulumi blog — *Deploy OpenClaw on AWS or Hetzner securely with
  Pulumi and Tailscale*.

These match `#1`, `#4` (when configured against a hosted model), and
`#7`, but they are **chat UIs**, not privileged sysadmins. They miss
`#2`, `#3`, `#5`, and usually `#9`. Score: **~3/10**. They are
useful prior art for the *network posture* of Ubuntu Zombie, but
nothing else.

### 2.6 Locked-down AI appliances — exclude
ChatGPT-on-a-box demos, Rabbit R1, NVIDIA Project DIGITS images,
kiosk builds. All sealed appliances — fail `#6` outright.

### 2.7 Deterministic remote-admin tools — exclude
Ansible, Salt, Puppet, Rundeck, Cockpit, Webmin, Tailscale SSH. No
LLM; deterministic playbooks. Fail `#2` and `#4`.

### 2.8 RPA / ChatOps — exclude
UiPath, Power Automate Desktop, Hubot, Errbot. Either not LLM-native
or not root-capable on Linux.

---

## 3. Cross-cutting observations

1. **Nobody else makes the §2 trade-off in public.** Every project
   that gets close to `#2 + #4 + #9` (Anthropic computer-use,
   OpenHands, Cua, E2B, Daytona) responds by *sandboxing the agent
   away from the host*. Ubuntu Zombie deliberately does the opposite
   and writes the trust model down (§10).
2. **The token-provider-as-root-authenticator pattern is genuinely
   common** (`#4`), but only in environments where the box itself is
   disposable. Pairing it with "and the box is also the user's normal
   PC" (`#6`) is the unusual move.
3. **Tailscale + LLM** is a popular *deployment* pattern (§2.5) but is
   universally applied to chat UIs and Ollama, not to a privileged
   conversational sysadmin.
4. **"Resident administrator"** as a phrase is rare. The named-project
   sweep did not surface any other open-source README using that
   wording or the phrase **"AI Systems Administrator"** in the Ubuntu
   Zombie sense. This is a useful unique-search-string for future
   prior-art passes.
5. **Multi-user contact (`#5`)** is the most-missed criterion across
   the field. Almost every candidate assumes one human owner ↔ one
   agent. Ubuntu Zombie's "any user of the PC may contact the
   administrator" framing has essentially no neighbours.

---

## 4. Recommended re-runs

Treat this file as a snapshot. Re-run the `SEARCH.md` queries
periodically; the most productive places to watch are:

- **HackerNews / Lobste.rs** for new phrasings like *"resident AI"*,
  *"AI sysadmin"*, or *"AI-controllable Ubuntu"*.
- **`block/goose` MCP extensions** — if a third-party MCP server
  appears that provisions a privileged `agent` account on Linux + a
  Tailscale tailnet, Goose would jump several points on `#3`, `#7`,
  and `#8`.
- **`anthropics/anthropic-quickstarts`** for a non-container
  reference, should Anthropic ever publish one.
- **Forgejo / Codeberg / SourceHut** — many self-hosting projects
  live off GitHub and are missed by code search.
- **`MauveAvenger/llm-agent-installer`** — closest installer-style
  cousin; watch for a token-provider mode and a Tailscale role.

---

## 5. Format used for each entry

Where data was unavailable or unclear, the entry says so. All scores
are *judgements against `SEARCH.md` §2*, not against project quality.
A low similarity score is not a criticism of the project — it just
means it solves a different problem.

Update this file in place when you re-run the searches; keep the
per-project headings stable so diffs stay readable.
