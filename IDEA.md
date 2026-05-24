It is **not** “AI Full Control Ubuntu” as the product idea.

It is:

> **A fresh Ubuntu machine gets a second user account: an AI Systems Administrator with root access, persistent memory, private access, and the ability to manage the whole OS for a novice.**

Better name:

```text
Ubuntu AI Systems Administrator
```

Or:

```text
AI Sysadmin User for Ubuntu
```

The specification should say this:

```text
Project name:
Ubuntu AI Systems Administrator

Goal:
Create a production-grade installer for a fresh Ubuntu Desktop machine that adds a dedicated AI Systems Administrator user with root-level access. This AI user should be able to administer Ubuntu on behalf of a novice human owner through a private conversational interface with persistent history.

Core idea:
The installer does not replace Ubuntu. It adds a new privileged user account that acts as an AI sysadmin.

The human owner should be able to say things like:
- install this app
- fix my Wi-Fi
- clean up storage
- update the system
- configure backups
- troubleshoot why something is broken
- open a browser and do this task
- change desktop settings
- inspect logs
- repair services
- manage Docker
- configure networking
- explain what happened
- undo or repair failed changes where possible

The AI Systems Administrator should have:
- its own Linux user account
- passwordless sudo/root access
- SSH key-only access
- private Tailscale-only remote access
- access to terminal tools
- access to the real Ubuntu desktop through Xorg
- GUI automation tools
- browser automation tools
- Docker access
- persistent chat history
- failure detection
- diagnostics
- repair commands
- logs of actions taken

Suggested Linux user:
aiadmin

Alternative:
ubuntu-ai-admin

Do not frame this as a generic remote-control stack.
Frame it as adding an expert AI sysadmin account to Ubuntu.

Target environment:
- fresh Ubuntu Desktop LTS
- local physical hardware
- Intel/AMD CPU
- no local GPU required
- cloud LLM primary
- private access only
- never public internet exposure
- Xorg desktop session, not Wayland

Security model:
This is an owner-authorized AI administrator.

The installer must:
- create a dedicated AI sysadmin user
- grant that user passwordless sudo
- disable root SSH login
- disable SSH password login
- allow SSH only through Tailscale
- deny public inbound traffic by default
- bind VNC to localhost only
- bind the chat UI to localhost only
- store secrets securely
- keep an audit trail of actions
- include repair and diagnostic tools

Conversation model:
The human owner talks to the AI Systems Administrator through a private local web chat.

The chat should:
- store history in SQLite
- remember prior conversations on that machine
- call a cloud LLM using an API key
- execute approved actions as the AI sysadmin user
- capture command output
- record failures
- suggest or perform repairs
- include verification steps after system changes

Execution abilities:
The AI Systems Administrator should be able to use:
- shell commands
- sudo/root commands
- apt package management
- systemctl services
- journal/log inspection
- Docker
- file operations
- network tools
- firewall tools
- screenshot capture
- mouse/keyboard GUI control
- browser automation with Playwright

Failure handling:
The system must include:
- strict installer error handling
- logs under /var/log/
- diagnostics collection on failure
- doctor mode
- repair mode
- verification mode
- uninstall mode
- apt lock detection
- retry logic for transient failures
- service health checks
- firewall checks
- Tailscale checks
- SSH checks
- desktop automation checks
- browser automation checks

Installer modes:
sudo ./ubuntu-ai-sysadmin.sh install
sudo ./ubuntu-ai-sysadmin.sh doctor
sudo ./ubuntu-ai-sysadmin.sh repair
sudo ./ubuntu-ai-sysadmin.sh verify
sudo ./ubuntu-ai-sysadmin.sh uninstall

Expected final state:
After installation, Ubuntu has a new privileged AI Systems Administrator user. The novice owner can open a private chat interface and ask that AI user to manage the machine, fix problems, install apps, operate the desktop, automate the browser, inspect the OS, and perform root-level administration with persistent history and diagnostic capability.

Product description:
Ubuntu AI Systems Administrator adds a root-capable AI sysadmin user to a fresh Ubuntu machine, letting a novice owner manage the entire OS, desktop, apps, browser, files, services, Docker, and networking through private natural-language conversation.
```

The best short formulation is:

> **Add an AI Systems Administrator user to Ubuntu: a root-capable, private, conversational sysadmin account that can manage the whole machine for a novice.**

Even shorter:

> **An AI sysadmin user account for Ubuntu.**

That is much clearer than “AI Full Control Ubuntu.”
