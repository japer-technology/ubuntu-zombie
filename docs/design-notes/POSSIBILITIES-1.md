# POSSIBILITIES-1.md

> Exploration: how a great Windows person — someone fluent with Windows
> but unfamiliar or uncomfortable with Linux — could simply ask
> intelligent questions of the resident AI Systems Administrator on an
> Ubuntu Zombie machine, and have it achieve "magic": rolling out apps
> and complex Ubuntu configuration easily, intelligently, and safely.

This is a possibilities document, not a specification. It sketches
shapes, not commitments.

---

## 1. Who the "great Windows person" is

The user we have in mind is competent. They are not a beginner with
computers. They:

- Have run Windows for decades. They know Control Panel, Settings, the
  Start menu, "Add or Remove Programs," winget, the Microsoft Store,
  Task Manager, Event Viewer, and PowerShell at least by sight.
- Understand concepts like "install an application," "open a port,"
  "give this program permission," "create a shortcut," "make it start
  automatically."
- Do *not* want to learn `apt`, `systemctl`, `journalctl`, `ufw`,
  `update-alternatives`, `/etc/`, package names, repository keys,
  user/group permissions, or shell quoting rules.
- Want to ask, in their own words, for outcomes — "set up a place where
  I can edit documents," "give me a private Git server," "make this
  machine record my screen when I press a key" — and have the machine
  arrange itself.

Ubuntu Zombie already places a resident, root-capable AI Systems
Administrator on the box. The possibilities below are about making
that administrator *reachable, conversational, and trustworthy* for
this kind of user.

---

## 2. How a Windows person could actually contact the administrator

The AI exists on the Ubuntu machine. The Windows person is at a
Windows PC. The contact surface matters as much as the intelligence
behind it. Possible shapes:

1. **A Windows-side desktop app** — a small native tray application
   ("Ubuntu Zombie") that opens a chat window. Behind the scenes it
   talks to the Ubuntu box over the private Tailscale network. The
   user never sees SSH, never sees a terminal, never types a Linux
   command. They type English. Answers come back as English plus,
   optionally, a collapsible "what I actually did" panel.

2. **A browser tab** — the Ubuntu box exposes a small local web UI
   (Tailscale-only, no public exposure). The Windows person opens
   `http://ubuntu-zombie/` in Edge or Chrome and gets the same chat.
   Zero install on the Windows side.

3. **Inside tools they already use** — a Microsoft Teams bot, a Slack
   bot, an Outlook add-in, or a "Copilot-style" sidebar in File
   Explorer. The administrator is reachable from the surfaces a
   Windows person already lives in.

4. **Voice** — push-to-talk on the tray app, or "Hey Zombie" on a
   headset. For a Windows person who is wary of typing Linux-shaped
   text, speaking the request lowers the barrier further.

5. **Email / ticket** — write a paragraph, send it to
   `admin@ubuntu-zombie`, get a reply. Familiar workflow; no real-time
   pressure; good for complex requests.

6. **Remote desktop into Ubuntu, with the chat as the *only* visible
   surface** — VNC/RDP straight into a kiosk-style window where the
   user only ever sees the conversation. The Ubuntu desktop exists
   underneath, but the Windows person is not asked to drive it.

All of these reduce to the same idea: the Windows person sees a chat
box. The administrator sees a privileged shell on a real Ubuntu PC.

---

## 3. The shape of a "simple intelligent question"

A Windows person should be allowed to ask in any of these registers,
and the administrator should understand them all:

- **Outcome requests** — "I want to write a letter," "I want a place
  to put my photos and back them up," "I want to host a small website
  only my family can see."
- **Application requests by Windows name** — "Install Word," "Install
  Notepad++," "Install Outlook," "Install Visual Studio." The
  administrator translates: LibreOffice Writer, a text editor of
  similar shape (gedit / Notepad-- / VS Code), Thunderbird or a web
  client, VS Code or the appropriate JetBrains tool.
- **Application requests by Linux name** — "Install Docker," "Install
  nginx." Pass through.
- **Capability requests** — "Make this machine able to run Android
  apps," "Make this machine able to act as a print server for the
  house," "Make this machine record everything on the screen for the
  last 30 seconds."
- **Diagnostic questions** — "Why is the fan loud?" "Why is it slow?"
  "What is using my disk?" "Did anything log in overnight?"
- **Lifecycle questions** — "Is anything out of date?" "Are there
  security updates?" "What changed yesterday?"
- **Undo requests** — "Roll back what you did this morning," "Remove
  the thing you installed yesterday and everything that came with it."

The administrator should treat all of these as first-class. None of
them require the user to know a package name, a service name, or a
file path.

---

## 4. Examples of "magic" the administrator could roll out

These are illustrative scenarios. Each one is a single English
sentence on the Windows side, and a substantial multi-step Ubuntu
operation on the Linux side.

### Office workstation
> "Set this up like my old Windows machine — Word, Excel, PowerPoint,
> a PDF reader, Zoom, and a way to print to the office printer."

Administrator action: install LibreOffice (and configure it to default
to .docx/.xlsx/.pptx for compatibility), install a PDF viewer,
install Zoom (`.deb` from vendor or Flatpak), configure CUPS with the
discovered printer, place launchers on the desktop with familiar
icons, and report back in English.

### Private family file server
> "I want a shared folder my family can put photos in from their
> phones and laptops."

Administrator action: create a directory, set up Samba (for Windows
laptops) and an AirDrop-compatible service or WebDAV (for phones),
create user accounts with reasonable passwords, configure the
firewall, hand the user a one-page printable cheat sheet with the
share path for each device.

### Local development environment
> "I'm going to learn Python. Set this up properly."

Administrator action: install a current Python, pipx, uv, VS Code,
the Python extension, a recommended formatter and linter, configure
a default virtual environment workflow, place a "Hello, world"
project in `~/Projects/python-hello`, and offer a one-paragraph
explanation of how to start the next project.

### Self-hosted Git
> "Give me a private Git server only I can see, with a web page like
> GitHub."

Administrator action: install Forgejo (or Gitea) via Docker, place it
behind a reverse proxy bound to Tailscale only, create the first
admin user, hand back the URL and credentials, and add a launcher to
the desktop and to the Windows tray app's bookmarks.

### Browser automation rig
> "I want this machine to log into a website every morning and
> download a file for me."

Administrator action: install Playwright in a dedicated user
directory, write a small script, register it as a systemd timer,
explain in English what it will do and when, and offer to show the
recorded run on request.

### Docker host with sensible defaults
> "I want to run some containers. Set it up the way you'd set it up
> for yourself."

Administrator action: install Docker Engine and the Compose plugin
(not the snap), add the user to the `docker` group, configure log
rotation, configure a dedicated data partition or directory, install
`lazydocker` for casual inspection, and document where compose files
should live.

### Diagnostic
> "Yesterday it was fast. Today it's slow. What happened?"

Administrator action: compare `journalctl` since yesterday, compare
package changes from `/var/log/apt/history.log`, check load,
swap, disk pressure, the top memory consumers, look for crashed
units, and report in plain English: *"A snap refresh of Firefox
happened at 03:14 and is using 2.1 GB; an unattended kernel upgrade
queued a reboot; one disk is at 94% full."*

---

## 5. What makes the magic actually *intelligent* (not just automated)

Wrapping `apt install` in a chat box is not the goal. The goal is the
administrator behaving like a competent human sysadmin would:

1. **Translate Windows vocabulary into Ubuntu reality.** "Install
   Word" → LibreOffice Writer, *and say so*, and offer the Microsoft
   365 web app as an alternative if the user actually needs `.docx`
   fidelity.
2. **Ask clarifying questions, but only when the answer changes what
   it does.** Don't interrogate the user. Pick a sensible default and
   announce it: *"I'll install LibreOffice for offline editing. Tell
   me if you'd rather use Office on the web."*
3. **Choose the right packaging.** Native `.deb` where it matters,
   Flatpak for GUI apps that want to be sandboxed, Snap only when it
   is genuinely the best option, Docker for services, `pipx`/`uv` for
   Python tools, source builds only when nothing else fits — and
   explain the choice in one sentence.
4. **Prefer reversible actions.** Snapshot before risky operations
   where possible (Timeshift, btrfs/zfs snapshots, package
   pinning). Keep an audit trail of every change so "undo what you
   did" is a real option.
5. **Dry-run by default for big requests.** *"I'm going to install
   these 14 packages and open port 22 on Tailscale only. Say 'go' to
   proceed."* The Windows person retains a moment of consent without
   needing to read the actual commands.
6. **Report in English, with the receipts hidden but available.**
   Default reply: *"Done. Word-equivalent and Excel-equivalent are
   on your desktop."* Expandable detail: the exact packages, the
   exact commands, the exit codes, the log excerpt.
7. **Remember the machine.** The administrator should know what it
   has already installed, what the user has asked for in the past,
   and what the machine is *for* in the user's words. "Install the
   usual" should mean something after the third visit.
8. **Refuse intelligently.** "Disable the firewall" is a legitimate
   request only with a good reason. "Open this to the public
   internet" is, per the Ubuntu Zombie trust model, not on offer at
   all — and the administrator should say so plainly, not silently.

---

## 6. Safety, trust, and the Windows person's expectations

A great Windows person is used to UAC prompts, SmartScreen, Defender
warnings, and "Are you sure?" dialogs. The administrator should
inherit that posture without inheriting Linux's traditional silence:

- **One clear consent step** for anything that installs software,
  changes the firewall, edits a system file, or touches another
  user's data. Not a wall of `[Y/n]` prompts — one English sentence.
- **An always-available activity log** in the chat UI: "Here is
  everything I have done on this machine, newest first." Each entry
  expandable into the exact commands and outputs.
- **A visible identity for the administrator.** The Windows person
  should always know *which* AI provider currently authenticates the
  administrator (per the README's trust model), and the tray app
  should show it.
- **A panic button.** "Stop. Undo your last action. Don't do anything
  else until I say." The administrator must honour this immediately.
- **No silent network exposure.** Per the existing Ubuntu Zombie
  posture, nothing the administrator does should open the machine to
  the public internet. If a user asks for that, the administrator
  explains why it won't, and offers the Tailscale path instead.

---

## 7. Onboarding the Windows person on day one

The first five minutes set the tone. Possibilities:

1. The Windows-side tray app, on first run, asks for the Tailscale
   login and nothing else.
2. The first message from the administrator is a short paragraph in
   plain English introducing itself, naming the token provider that
   authenticates it, and offering three example questions the user
   can click.
3. A "show me around" command produces a one-screen tour of what is
   already installed, what the machine could become, and what the
   user is most likely to want next.
4. A "translate from Windows" mode is offered explicitly: *"Tell me
   what you would do on Windows, and I'll tell you the Ubuntu
   equivalent and offer to set it up."*

The Windows person leaves day one with: a working chat, a working
machine, two or three apps they actually wanted, and the strong
impression that they can ask for anything else in plain English.

---

## 8. Concrete next-step possibilities for this repository

If we wanted to make the above real, the smallest credible increments
would be roughly:

1. **A Windows-friendly entry point document** — a sibling to
   `README.md` written for the great Windows person, in their
   vocabulary, naming the Windows apps they know and showing the
   Ubuntu equivalents the administrator can produce on request.
2. **A "questions you can ask" catalogue** — a curated list of the
   English sentences the administrator is known to handle well, with
   a one-line description of the magic each one triggers. This
   doubles as a prompt library for the administrator itself.
3. **A Windows-side thin client** — a tray app (or first, just a
   browser bookmark to a Tailscale-only local web UI) that surfaces
   the administrator as a chat window, with the activity log, the
   provider identity, and the panic button described above.
4. **An administrator "house style" document** — the rules of
   engagement the AI follows: translate Windows vocabulary, pick
   sensible packaging, dry-run big changes, report in English, keep
   an audit trail, refuse public exposure, honour stop requests.
5. **A small set of high-value capability recipes** — office
   workstation, family file server, Python dev box, private Git,
   Docker host, browser automation — each one wired so that a single
   English sentence from the Windows person produces the full
   rollout, end to end, with a one-paragraph summary at the end.

None of these require changing the trust model or the baseline
installer. They sit on top of what Ubuntu Zombie already is: a
normal Ubuntu PC with a resident, root-capable, externally
authenticated AI Systems Administrator — now made approachable for
people whose mother tongue is Windows.
