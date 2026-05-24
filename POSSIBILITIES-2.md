# POSSIBILITIES-2.md

> Exploration: the *power* a great Windows person actually inherits
> the moment they sit in front of an Ubuntu Zombie machine — not the
> chat box, not the translation layer, but the bare fact that Ubuntu
> can do things Windows has never let them do, and the resident AI
> Systems Administrator removes the only reason they never tried.
>
> Where POSSIBILITIES-1.md asked *"how does the Windows person reach
> the administrator?"*, this document asks *"once they reach it, what
> can the machine in front of them actually become?"*

This is a possibilities document, not a specification. It sketches
shapes, not commitments.

---

## 1. The point POSSIBILITIES-1.md missed

POSSIBILITIES-1.md treated the Windows person as someone who wants
their Windows life, gently reproduced on a stranger OS — Word becomes
LibreOffice, Outlook becomes Thunderbird, "install" still means
"install one app." That framing is correct, and kind, and entirely
insufficient.

The interesting fact is not that Ubuntu can imitate Windows. The
interesting fact is that **Ubuntu can do an enormous number of things
that Windows actively refuses to let its users do**, and that the
only reason ordinary Windows people have never tasted those things is
that the path was paved in `apt`, `systemd`, `/etc/`, manual pages,
and tribal knowledge. Ubuntu Zombie pours fresh tarmac over that path
in the form of a resident root-capable administrator who speaks
English.

So the real question is not *"how do we make Ubuntu feel like home
for a Windows person?"* — it is *"what does a Windows person get to
do tomorrow that they could not credibly do today, on any Windows
machine they have ever owned, at any price?"*

This document is a list of answers to that question.

---

## 2. The shape of the new power

A Windows person, before Ubuntu Zombie, lives inside a consumer
product. Their PC is, in practice:

- a workstation, and only a workstation;
- one user at a time, in the way that matters;
- updated when Microsoft decides;
- rebooted when Microsoft decides;
- surveilled, to a degree the user cannot fully audit;
- locked out of its own kernel, init, network stack, and package
  graph;
- forbidden, in any practical sense, from hosting services to other
  devices in the house;
- unable to run most of the world's free software without ceremony,
  emulation, or a separate "developer mode";
- expensive to extend — every capability is a paid app, a
  subscription, a SKU upgrade, or a Pro tier.

A Windows person, *after* Ubuntu Zombie, lives on a general-purpose
Unix machine with a resident administrator. Their PC is now,
simultaneously and at no extra cost:

- a workstation;
- a server;
- a router, if they want;
- a media library;
- a backup target;
- a development environment;
- a containerised application host;
- a virtual-machine host;
- an automation rig;
- an AI inference box;
- a packet capture station;
- a file share for every device in the house;
- a recoverable, snapshot-able, scriptable, reproducible system.

None of that is new about Ubuntu. What is new is that none of it
requires the user to *learn Ubuntu*. The administrator already
knows. The Windows person only needs to know what they want.

---

## 3. Powers Windows simply does not offer

These are capabilities a Windows person could not reasonably obtain
on Windows at any skill level, but can ask for in one English
sentence on an Ubuntu Zombie box.

### 3.1 The PC as a real server, without changing PCs

> "Run a Plex-style movie server for the TV downstairs."
> "Host a private chat for the family."
> "Be the printer for the house."
> "Host my git repos so the laptop can push to this PC."
> "Block ads for every device on the home Wi-Fi."

Jellyfin, Matrix or Mattermost, CUPS, Forgejo, Pi-hole. Each is a
single English request. Each runs as a proper service, starts on
boot, survives reboots, exposes itself only on Tailscale, logs
sensibly, and updates itself. Windows can *technically* do some of
these. In practice no Windows person ever does.

### 3.2 Containers and virtual machines as a first-class right

> "Spin me up a throwaway Ubuntu I can break."
> "Give me a Windows 7 VM for that old accounting program."
> "Run this docker-compose.yml the support guy emailed me."

KVM, libvirt, virt-manager, Docker, Podman, LXC. The Windows
equivalent is Hyper-V (Pro only, fragile), WSL (Linux *inside*
Windows, never the other way), or a paid copy of VMware Workstation.
Here it is the operating system's natural posture, and the
administrator wires up networking, shared folders, and snapshots
without being asked.

### 3.3 Cron, timers, and automations that actually run

> "Every Sunday at 2am, back up my Documents to the NAS and email me
> if it failed."
> "When my phone joins the Tailscale network, unlock the screen."
> "Watch this folder and convert every .heic that lands in it to
> .jpg."

`systemd` timers, `inotify`, small scripts, `msmtp`. On Windows the
Task Scheduler exists but is hostile, GUI-only, and forgets you. On
Ubuntu, with the administrator writing the unit files, the user gets
a quiet, declarative, reviewable automation graph and never has to
look at a unit file.

### 3.4 Real filesystems with real snapshots

> "Snapshot the machine before you do anything risky."
> "Take me back to how this PC was on Tuesday morning."
> "Make a separate disk for the docker stuff so it can't fill up my
> home folder."

btrfs or zfs subvolumes, Timeshift, LVM, separate mount points.
Windows offers System Restore (limited, opaque, often missing) and
File History (per-file, not per-system). Here, "go back to Tuesday"
is the literal command, and the administrator knows what Tuesday
means.

### 3.5 A network stack the user is allowed to touch

> "What is this PC talking to right now, and why?"
> "Block this app from reaching the internet."
> "Tunnel my browser through the home PC while I'm on hotel Wi-Fi."
> "Sniff what my smart bulb is sending out."

`ss`, `nethogs`, `ufw`/`nftables`, WireGuard, `tcpdump`, Wireshark.
On Windows the equivalents are either absent, paid, third-party, or
buried in `netsh`. The administrator turns each of these into a
sentence: *"Your smart bulb just contacted three Chinese IPs in the
last hour, all on port 1883. Do you want me to block them?"*

### 3.6 Local AI, at full speed

> "Run a local chatbot I can use without sending anything to the
> cloud."
> "Generate images on this machine — I don't want them on someone's
> server."
> "Transcribe everything in this folder of voice memos."

Ollama, llama.cpp, ComfyUI, Whisper, Stable Diffusion, vLLM. With a
GPU these run vastly better on Linux than on Windows, and the
administrator handles CUDA, drivers, model downloads, and
quantisation choices. The Windows person never sees the word
"cuDNN."

### 3.7 The package universe, unlocked

> "Install everything I'd need to edit a podcast."
> "Set me up with a music production environment like the YouTube
> tutorials use."
> "Install all the standard tools a security researcher uses."

Audacity, Ardour, JACK, Reaper-via-Flatpak, OBS, kdenlive,
DaVinci Resolve, the entire `kali-tools-*` metapackage set,
LaTeX, R, Octave, GIMP, Inkscape, Blender, Krita, Darktable,
RawTherapee. Tens of thousands of programs in `apt`, Flathub, and
Snap — most of them free, most of them unavailable on Windows in
equivalent form, all of them reachable through one sentence to the
administrator.

### 3.8 No ads, no telemetry, no Recall, no Copilot key

> "Strip everything that phones home."
> "Block Microsoft accounts entirely; this machine is mine."
> "Disable anything that ever pops up unsolicited."

There is nothing to strip. There is no lock-screen ad, no
"suggested" app, no OneDrive nag, no Edge re-pinning itself, no
Recall index, no forced Microsoft account, no telemetry pipeline
the user must beg the OS to throttle. The default state of the
machine is the state Windows power users spend hours trying to
approximate with debloat scripts and group-policy edits.

### 3.9 Updates the user controls

> "Never reboot without asking."
> "Apply security updates but hold the kernel until next weekend."
> "Pin Firefox at this version; the new one broke a site I use."

`unattended-upgrades`, `apt-mark hold`, `needrestart`, kernel
metapackages. The Windows person finally owns the update calendar.
The administrator phrases it back in English: *"Two security updates
are ready. Neither needs a reboot. I'll apply them at lunchtime
unless you say no."*

### 3.10 Multi-user that means it

> "Make an account for my kid that can't install anything or see my
> files."
> "Give the babysitter a guest login that wipes itself at logout."
> "Let the visitor SSH in over Tailscale but only into a sandbox."

POSIX users and groups, `polkit`, `firejail`, `bubblewrap`, ephemeral
home directories, container-backed shells. On Windows, real
multi-user discipline requires Pro and Active Directory and patience.
Here, it requires one sentence.

### 3.11 Hardware the user is allowed to address

> "What is the temperature of every sensor in this case?"
> "Spin the fans up when the GPU goes above 70°C."
> "Use the second GPU only for AI; keep the first one for the
> display."

`lm-sensors`, `fancontrol`, `nvidia-smi`, `cgroups`, `udev` rules.
Windows treats the hardware as the OEM's concern. Ubuntu treats it
as the user's.

### 3.12 Scriptability of the desktop itself

> "Every weekday at 9am, open my email, my calendar, and the company
> dashboard in three side-by-side windows."
> "When I plug in my work laptop's USB-C dock, switch to my work
> profile."
> "Take a screenshot of the dashboard every hour and stitch it into
> a daily timelapse."

`wmctrl`, `xdotool`, `ydotool` on Wayland, `wlrctl`, `swaymsg`,
`autorandr`, `ffmpeg`. The desktop is not a sealed product; it is a
program, and the administrator can write to it. Windows
"automation" stops at the edge of PowerToys.

### 3.13 Reproducibility — *the* missing Windows superpower

> "Write down exactly how this machine is set up, so if it dies I can
> get an identical one back in an hour."
> "Set up my laptop the same way as this desktop."
> "Give me the recipe for this machine so my brother can replicate
> it."

A generated Ansible playbook, or a shell script, or a Nix-style
manifest, or simply an annotated list of `apt install` lines and
config files. The administrator already knows what it has done. It
can therefore write the recipe. Windows has nothing comparable, at
any price, for ordinary users. This alone changes what owning a
computer means.

---

## 4. Powers Windows *technically* offers, but only painfully

These are things Windows can do but in practice no Windows person
ever does because the path is hostile. Ubuntu plus the administrator
makes them ordinary.

- **Run an SSH server.** *"Let me get into this machine from my
  laptop."*
- **Mount remote storage as if local.** *"Show the office NAS as a
  folder in my file manager."*
- **Run a reverse proxy in front of three things.** *"Put Jellyfin,
  Forgejo, and the family wiki behind nice short URLs."*
- **Schedule disk maintenance.** *"Scrub the disks monthly and tell
  me if anything is starting to fail."*
- **Roll a bespoke kernel** — not because the user needs to, but
  because they *may*, and the administrator can do it without
  drama. *"Build a kernel with the realtime patches; I want to
  record audio with no jitter."*
- **Run as a router for the house.** *"Plug this second NIC into the
  modem and serve DHCP to the living room."*
- **Operate a mail relay.** *"Send me an email when the backups
  fail."*
- **Bind-mount, namespace, chroot, and isolate.** *"Run this dodgy
  binary somewhere it can't see anything else."*

Each is a paragraph of yak-shaving on Windows. Each is one English
sentence here.

---

## 5. Powers that come from *the combination*, not any one piece

The interesting compounding happens when the powers above stack.

### 5.1 The personal cloud

A Windows person can ask: *"Be my cloud. I don't want to pay anyone
anymore."*

The administrator can deliver: Nextcloud or Seafile (Dropbox),
Vaultwarden (1Password), Immich (Google Photos), Jellyfin
(Netflix-for-my-own-files), Forgejo (GitHub), a Matrix server
(Slack), Joplin Server (Notes), Paperless-ngx (Documents), an
adblocking DNS (Pi-hole), Tailscale (the LAN that follows you), and
automated nightly backups of all of it to an external disk and to
encrypted off-site storage.

Total cost: a PC the user already owns, plus electricity. Total
configuration burden on the user: a paragraph of English per
service. Windows people *cannot reach this state on Windows*,
because Windows is not the operating system for it.

### 5.2 The thinking workstation

> "Watch what I'm working on, transcribe my meetings locally, summarise
> them at the end of the day, and let me search every document I've
> read this year."

Local Whisper for transcription, a local embedding model, a local
vector store, a small RAG service, and a chat front end — all
running offline on the user's own hardware, none of it touching a
vendor cloud. The administrator wires it together; the user just
asks.

### 5.3 The unbreakable PC

> "Make this machine recoverable. Whatever I break, I want a way
> back."

btrfs root with timed snapshots, a rescue user, a serial-console
fallback, an unattended-upgrade policy that snapshots first, an
off-site backup of `/etc` and `/home`, a documented procedure
printed and taped to the side of the case. The Windows person now
owns a PC that is *harder to lose* than the one they had before.

### 5.4 The household infrastructure node

A single Ubuntu Zombie box can quietly become: the file server, the
printer, the photo backup target, the smart-home brain (Home
Assistant), the music server, the family wiki, the ad blocker, the
VPN bastion, the git host, the build farm, the surveillance
recorder (Frigate), the password vault, and the LAN's DNS. With one
case fan and one English speaker in front of it.

---

## 6. What the administrator changes about *power* specifically

Without the administrator, every item above is technically available
to a sufficiently determined Windows person who is willing to
become a Linux person first. The administrator changes three things,
and those three changes are what make the *power* — not the
*possibility* — real.

1. **The cost of trying drops to one sentence.** A capability the
   user would never have attempted because of the perceived setup
   cost (Jellyfin, Home Assistant, a local LLM) becomes a casual
   experiment. *"Try it. If I don't like it, take it back off."*

2. **The cost of undoing drops to one sentence.** Snapshotting,
   uninstalling, purging configs, freeing disk, restoring services —
   the administrator owns the receipts. The user does not have to
   know what they installed in order to remove it cleanly.

3. **The cost of remembering drops to zero.** The administrator
   remembers what the machine is, what was installed, what was tried,
   what worked, what the user named things, and what the recipe is.
   A Windows person who has historically lost every interesting
   configuration the moment they reinstalled now has a machine that
   remembers itself.

These three shifts turn Ubuntu's latent power into power the user
actually wields, day to day, without becoming a sysadmin.

---

## 7. What the Windows person feels on day thirty

By the end of the first month, a Windows person on an Ubuntu Zombie
box should be able to say, truthfully, things like:

- *"I host my own photos now. My phone uploads to my own PC. Nobody
  else has them."*
- *"I run a chatbot on my own machine. It's not as smart as the big
  ones, but it's mine, and it's free, and it works on a plane."*
- *"My kid has her own login. She can't break anything. When she
  does, I roll back."*
- *"My printer just works for everyone in the house, including the
  iPad."*
- *"My machine updates itself overnight and tells me what it did in
  the morning."*
- *"I have a backup. I have actually tested the backup. I trust the
  backup."*
- *"If this PC dies tomorrow, I can have an identical one running on
  new hardware by the end of the day."*

None of those sentences were available to that person on Windows,
at any tier, at any subscription level, on the day before they
installed Ubuntu Zombie. All of them are routine on the day after.

That is the magnitude of the shift POSSIBILITIES-1.md politely
understated. The Windows person is not just getting a friendlier
Ubuntu. They are getting, for the first time in their computing
lives, a personal computer that behaves like the powerful general
machine it has always actually been — with a patient expert sitting
inside it, willing to do the parts they were never going to learn.

---

## 8. Concrete next-step possibilities for this repository

If POSSIBILITIES-1.md suggested onboarding documents and a thin
client, POSSIBILITIES-2.md suggests building a *capability
catalogue* organised around power rather than around translation:

1. **A "things Windows can't do" tour** — a short interactive
   walkthrough the administrator offers on day one: *"Pick any
   three. I'll set them up. If you don't like them, I'll remove
   them. Each one is impossible on the PC you came from."*

2. **Capability bundles** — named, opinionated stacks the
   administrator can deploy as a unit: `personal-cloud`,
   `home-infrastructure`, `local-ai-workstation`,
   `developer-laptop`, `family-server`, `media-room`. Each one a
   curated graph of services with sensible defaults, snapshot
   points, and a rollback recipe.

3. **A "your recipe" export** — on demand, the administrator
   produces a complete, human-readable description of the current
   machine that can rebuild it from a fresh Ubuntu install. This
   one feature alone is more than Windows offers any of its users.

4. **A "what could this machine become?" question** — the
   administrator should be able to answer it at any moment, with a
   short list tailored to the hardware (GPU? Lots of RAM? Spare
   disks? Wired ethernet? Two NICs?), the user's prior requests,
   and what is *not yet* installed. Power is partly the awareness
   of what is available.

5. **A "compared to Windows" mode** — for any installed capability,
   the administrator can explain in one paragraph what the Windows
   equivalent would have cost in money, configuration, and
   surveillance. Not to sneer at Windows, but to make the new
   ground the user is standing on legible to them.

None of this requires changing the trust model, the installer, or
the baseline. It only requires noticing that the Windows person who
sits down at an Ubuntu Zombie machine is not asking for a different
Word. They are about to find out that the PC they have owned for
twenty years was, all along, capable of being something much larger
than the product Microsoft sold them — and that the only thing
standing between them and that larger machine has just been
replaced by an administrator who already knows the way.
