# Configuration

Everything an operator can tune after a successful install.

## Provider keys

Provider credentials live in `/opt/ai-zombie/secrets/env`, mode `0600`,
owned by the local agent account (default `zombie:zombie`; whatever
name was passed to `ZOMBIE_USER` at install time). Edit them with the
safe helper, which re-asserts permissions after `$EDITOR` exits:

```bash
sudo /opt/ai-zombie/bin/secrets-edit
```

Supported variables:

| Variable             | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `OPENAI_API_KEY`     | API key for the OpenAI provider          |
| `ANTHROPIC_API_KEY`  | API key for the Anthropic provider       |
| `GEMINI_API_KEY`     | API key for Google Gemini (routed via `pi-ai`'s `google` provider) |
| `XAI_API_KEY`        | API key for the xAI provider             |
| `OPENROUTER_API_KEY` | API key for the OpenRouter aggregator. Requires `ZOMBIE_MODEL` to be set to a fully-qualified id such as `anthropic/claude-3.5-sonnet`. |
| `MISTRAL_API_KEY`    | API key for the Mistral provider         |
| `GROQ_API_KEY`       | API key for the Groq provider            |
| `ZOMBIE_PROVIDER`    | One of `openai`, `anthropic`, `gemini`, `xai`, `mistral`, `groq`, `openrouter`, `lmstudio` (default: first matching key found, in that order) |
| `ZOMBIE_MODEL`       | Model used by both the agent loop and the chat surface; required for `openrouter`/`lmstudio` unless their provider-specific model env var is set; overrides provider-specific model env vars and defaults |
| `ZOMBIE_OPENAI_MODEL`     | Override the default model used when the active provider is `openai` |
| `ZOMBIE_ANTHROPIC_MODEL`  | Override the default model used when the active provider is `anthropic` |
| `ZOMBIE_GEMINI_MODEL`     | Override the default model used when the active provider is `gemini` |
| `ZOMBIE_XAI_MODEL`        | Override the default model used when the active provider is `xai` |
| `ZOMBIE_MISTRAL_MODEL`    | Override the default model used when the active provider is `mistral` |
| `ZOMBIE_GROQ_MODEL`       | Override the default model used when the active provider is `groq` |
| `ZOMBIE_OPENROUTER_MODEL` | Fully-qualified OpenRouter model id (e.g. `anthropic/claude-3.5-sonnet`); used only when `ZOMBIE_MODEL` is unset |
| `ZOMBIE_CHAT_PORT`   | Loopback port for the chat UI (default `7878`) |
| `ZOMBIE_ADMIN_PASSWORD` | Chat-UI password gate. The installer asks for it (default `braaaains`) and stores only a PBKDF2 hash as `ZOMBIE_ADMIN_PASSWORD_HASH` in `secrets/env`. |
| `ZOMBIE_TTL_DAYS`    | Time to Live in whole days before the zombie is permanently disabled (default `7`). Each install starts a fresh countdown. |
| `LMSTUDIO_API_KEY`   | API key for a local OpenAI-compatible server (LM Studio / Ollama / llama.cpp). Pair with `ZOMBIE_PROVIDER=lmstudio` and `ZOMBIE_MODEL`; the server URL lives in `~/.pi/agent/models.json` (most local servers ignore the key). |
| `DISPLAY`            | X display for desktop helpers (default `:0`; pre-seeded in the generated `secrets/env`) |

Per-provider defaults if no `ZOMBIE_MODEL` / `ZOMBIE_<PROVIDER>_MODEL`
override is set (from `payload/agent/providers.py`):

| Provider     | Default model               |
| ------------ | --------------------------- |
| `openai`     | `gpt-4o-mini`               |
| `anthropic`  | `claude-3-5-sonnet-latest`  |
| `gemini`     | `gemini-2.0-flash`          |
| `xai`        | `grok-2-1212`               |
| `mistral`    | `mistral-small-latest`      |
| `groq`       | `llama-3.1-8b-instant`      |
| `openrouter` | *(no default; must be set)* |
| `lmstudio`   | *(no default; must be set)* |

All providers are routed through [`@earendil-works/pi-ai`][pi-ai],
installed globally by `scripts/install.sh` at the version pinned in
`payload/agent/pi-ai.version`. The chat service shells out to the Node
bridge at `/opt/ai-zombie/agent/pi-ai-bridge.mjs`; there are no
bespoke per-provider Python clients.

`ZOMBIE_PROVIDER` + `ZOMBIE_MODEL` (plus the matching `*_API_KEY`) are
the **single source of truth** for both the status banner and the agent
loop that produces every chat answer. Resolution is:

1. explicit provider argument (internal API only), else
   `ZOMBIE_PROVIDER`, else the first configured key in the provider
   table order above;
2. explicit model argument (internal API only), else `ZOMBIE_MODEL`,
   else the provider-specific `ZOMBIE_<PROVIDER>_MODEL`, else the
   registry default.

`payload/agent/pi_mono.py` resolves the active provider/model through
the same `payload/agent/providers.py` registry and passes them to the
`pi` CLI (`--provider` / `--model`), forwarding only the active
provider's key. This means the `pi` CLI's own native configuration
(`~/.pi`) and its built-in default provider are **not** consulted when a
provider is configured here — there is no second place to set the
model. The one exception is the `lmstudio` provider: because a local
server has no fixed endpoint, the installer writes its base URL to the
`pi` custom provider file `~/.pi/agent/models.json` (the model id and
key still come from `secrets/env`). See
[Local LLM discovery](#local-llm-discovery-lan-scan).

[pi-ai]: https://github.com/earendil-works/pi

Restart the chat service after editing:

```bash
sudo systemctl restart ubuntu-zombie-chat.service
```

## Local LLM discovery (LAN scan)

During an **interactive** install the script can scan the host's IPv4
`/24` — all 256 addresses, e.g. `192.168.1.0`–`192.168.1.255` when the
host is `192.168.1.34` — for an OpenAI-compatible local LLM server
answering on `http://<ip>:1234/v1`. Servers such as
[LM Studio](https://lmstudio.ai/) (which listens on port `1234` by
default), Ollama, and `llama.cpp` expose a `/v1/models` endpoint; the
installer queries each responder, collects the model ids it advertises,
and offers them as the **starting model** in the parameter-review step.

When a model is chosen, the generated `/opt/ai-zombie/secrets/env`
records it as the `lmstudio` provider:

```
ZOMBIE_PROVIDER=lmstudio
ZOMBIE_MODEL=<the model id you picked>
LMSTUDIO_API_KEY=local
```

and the server URL is written to the `pi` custom-provider file
`~/.pi/agent/models.json` (owned by the agent account):

```json
{
  "providers": {
    "lmstudio": {
      "baseUrl": "http://<server-ip>:1234/v1",
      "api": "openai-completions",
      "apiKey": "LMSTUDIO_API_KEY",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [ { "id": "<the model id you picked>" } ]
    }
  }
}
```

The agent loop (`pi-mono`, which produces every chat answer) reaches the
local server through this `lmstudio` provider; `pi --provider openai`
would ignore the base URL and hit `api.openai.com` instead, so a
dedicated local provider is required. Most local servers ignore the API
key; set `ZOMBIE_LOCAL_LLM_API_KEY` (or edit the files afterwards) if
yours requires a real one. If you later load a different model in LM
Studio, update the `id` in `~/.pi/agent/models.json` and `ZOMBIE_MODEL`
in `secrets/env`, then restart the chat service.

The scan is best-effort and skipped automatically for `--yes`,
non-interactive, and non-TTY runs. It needs `curl` and `python3`
(both already required by the product).

| Variable                 | Default | Purpose                                                              |
| ------------------------ | ------- | -------------------------------------------------------------------- |
| `ZOMBIE_SKIP_LLM_SCAN`   | `0`     | Set to `1` to skip the LAN scan entirely.                            |
| `ZOMBIE_LLM_SCAN_PORT`   | `1234`  | TCP port probed on each address for the `/v1/models` endpoint.       |
| `ZOMBIE_LOCAL_LLM_API_KEY` | `local` | API key recorded for the discovered server (most local servers ignore it). |

You can also trigger the scan on demand from the interactive setup
review by choosing the **Local LLM** field.

## Agent account name

The installer creates a single local Linux user as the operating
identity of the AI Systems Administrator. The default name is
`zombie`. To pick a different name, pass `ZOMBIE_USER` to the
installer:

```bash
sudo ZOMBIE_USER=admin ./scripts/install.sh install
```

The same variable must be set on every later `install`, `verify`,
`doctor`, `repair`, or `uninstall` run that targets a non-default
account. `AGENT_USER` is still accepted as a backward-compatible alias
so older installs (which used `agent`) can still be repaired or
removed by exporting `AGENT_USER=agent`.

The chosen name appears throughout: `/home/<name>`, the sudoers
drop-in `/etc/sudoers.d/90-<name>-ubuntu-zombie`, the systemd
`User=`/`Group=` of `ubuntu-zombie-chat.service`, and the system
prompt the chat service hands to the LLM.

## Rotating provider keys

1. `sudo /opt/ai-zombie/bin/secrets-edit` — replace the value.
2. `sudo systemctl restart ubuntu-zombie-chat.service`.
3. Optionally revoke the old key in the provider's console.

## Revoking the agent

To stop useful agent operation immediately:

```bash
sudo /opt/ai-zombie/bin/secrets-edit   # delete every API key
sudo systemctl restart ubuntu-zombie-chat.service
```

The chat will load but refuse to call any provider.

To stop the service entirely:

```bash
sudo systemctl disable --now ubuntu-zombie-chat.service
```

To remove privileged access without uninstalling everything:

```bash
sudo rm /etc/sudoers.d/90-zombie-ubuntu-zombie
```

## Policy

`/etc/ubuntu-zombie/policy.yaml` controls what the agent may run
without approval, what requires approval, and what requires the extra
destructive confirmation phrase. See `ARCHITECTURE.md` for the action
classes. The chat service reloads the policy on every request — no
restart needed.

### Fail-closed default

`settings.default_class` is the classification used when no rule
matches a proposed command. The shipped default is `destructive` —
the highest gated class — so unknown commands cannot auto-run.
Operators may relax this to a lower class once a workflow is proven
safe.

### Sudo allow-list

`sudo_allow_list:` (a top-level list of program names) keeps common
privileged commands at `system_change` despite the conservative
fail-closed default. The standard approval prompt still fires for
these — they do not auto-run — but they are not escalated to
`destructive`. Entries are matched against the basename of the
program that `sudo` invokes (after `sudo` consumes its own flags), so
`sudo apt install foo`, `sudo -u root systemctl restart cron`, and
`sudo -E /usr/bin/apt update` are all classified by the entries for
`apt` and `systemctl`. Add entries only after confirming the
underlying program is safe to elevate.

### Tool classes and per-turn budgets

The agent emits structured tool calls from a closed 10-tool registry
defined in `payload/agent/tools.py`:

| Tool              | Registry default class | Purpose                                                    |
| ----------------- | ---------------------- | ---------------------------------------------------------- |
| `shell.run`       | per-argv via `classify` | Run a shell command through the existing runner.          |
| `fs.read`         | `read_only`            | Read a UTF-8 text file within the readable allow-list.     |
| `fs.list`         | `read_only`            | List directory entries within the readable allow-list.     |
| `fs.write`        | `user_change`          | Write text content to a path within the writable allow-list. |
| `pkg.query`       | `read_only`            | Query installed package metadata via dpkg/apt-cache.       |
| `pkg.install`     | `system_change`        | Install Debian packages via apt-get.                       |
| `svc.status`      | `read_only`            | Inspect a systemd unit (status / is-active).               |
| `svc.control`     | `system_change`        | Start/stop/restart/reload/enable/disable a systemd unit.   |
| `net.status`      | `read_only`            | Read-only interface and listening-port inspection.          |
| `skill.list`      | `read_only`            | Enumerate available skills.                                |
| `skill.load`      | `read_only`            | Read the markdown body of a skill by name.                 |

Two `policy.yaml` blocks control them:

```yaml
tool_classes:
  # Override the registry default for a tool. shell.run is always
  # classified per-argv via classify(); listed tools take the class
  # below before classify_tool falls back to the registry default.
  fs.write: user_change
  pkg.install: system_change

agent:
  max_tool_calls_per_turn: 12        # total tool calls per user message
  max_elevated_calls_per_turn: 3     # cap on non read_only calls
```

Budget enforcement:

- `max_tool_calls_per_turn` is enforced by `pi_mono.run_turn` and the
  bridge — once exceeded, the agent receives a synthetic
  `budget_exceeded:` observation for further calls.
- `max_elevated_calls_per_turn` is enforced by `server.py` against the
  classification returned by `policy.classify_tool`. Each call past the
  budget is recorded as a `budget_exceeded` audit decision and the
  agent sees the same synthetic observation so it ends the turn
  cleanly. The same counter drives the operator-facing per-turn
  budget badge in the UI.

### pi-mono runtime

The installer pins `@earendil-works/pi-coding-agent` to the version in
`payload/agent/pi-mono.version` and renders runtime configs into
`/opt/ai-zombie/pi/`:

| Path                                   | Purpose                                  |
| -------------------------------------- | ---------------------------------------- |
| `/opt/ai-zombie/pi/settings.json`      | pi-mono settings (`--no-builtin-tools`)  |
| `/opt/ai-zombie/pi/APPEND_SYSTEM.md`   | rendered system-prompt prelude           |
| `/opt/ai-zombie/agent/pi-mono-bridge.mjs` | Node bridge wrapping `pi --mode json` |
| `/opt/ai-zombie/state/logs/pi-mono.*.log` | per-turn bridge logs, rotated daily   |
| `/opt/ai-zombie/state/pi-mono-sessions/`  | pi session/checkpoint state           |

Environment overrides for the `pi-mono` runtime are documented in
[Advanced environment overrides](#advanced-environment-overrides)
below (look for the `ZOMBIE_PI_MONO_*` variables).

## Chat access

The chat UI is served at `http://127.0.0.1:${ZOMBIE_CHAT_PORT:-7878}/`.
On a shared desktop every local user can reach the loopback socket, so the UI is protected
by a **password gate**: the installer asks for a chat password (default
`braaaains`) and stores only a PBKDF2 hash as
`ZOMBIE_ADMIN_PASSWORD_HASH` in `secrets/env`. Set a custom one with
`ZOMBIE_ADMIN_PASSWORD` or through the interactive parameter review.
(Having a root/agent shell on the box is still root-equivalent — that
matches the trust model — but the password keeps casual local users
out of the administrator.)

In the chat UI, `/password new secret` changes the password after a
browser confirmation and clears existing login sessions. `/password`
removes the password after confirmation; because the gate is disabled,
no logoff is required.

### Time to Live (the kill switch)

Every install gives the root-capable agent a bounded lifetime. The
**Time to Live** defaults to 7 days (`ZOMBIE_TTL_DAYS`, or set it in the
interactive review). When the TTL elapses — or an operator runs the
`/ttl --die` chat command — the zombie writes a durable tombstone and is
**permanently disabled until the next reinstall**: it refuses to answer
prompts and shows a "this zombie has died" notice. A re-run of
`scripts/install.sh install` resets the tombstone and starts a fresh
countdown.

Chat commands:

| Command       | Effect                                                        |
| ------------- | ------------------------------------------------------------- |
| `/ttl`                   | Show the remaining Time to Live.                              |
| `/ttl <duration>`        | Extend the Time to Live by a duration from the current expiry. |
| `/ttl reset [duration]`  | Reset the Time to Live from now (default: 7 days).             |
| `/ttl --die`             | Trip the kill switch now — permanently disables the zombie.    |

Durations are written as number/unit pairs such as `14 days`,
`2 years 3 months`, or `3 hours`; a bare number is kept as the legacy
days shorthand. Months and years are fixed approximations of 30 and
365 days.

State lives in `/opt/ai-zombie/state/lifecycle.json`. It can also be
inspected from the agent account with
`python3 /opt/ai-zombie/agent/lifecycle.py status`.

## Logs and state

| Path                                       | Purpose                                         |
| ------------------------------------------ | ----------------------------------------------- |
| `/var/log/ubuntu-zombie-install.log`       | Installer transcripts                           |
| `/var/log/ubuntu-zombie/install-receipt.txt` | Install receipt (parameters + start/finish outcome) |
| `/var/log/ubuntu-zombie/audit.log`         | JSON-lines AI audit trail                       |
| `/opt/ai-zombie/state/conversations.db`    | Chat history (SQLite)                           |
| `/opt/ai-zombie/state/lifecycle.json`      | Time-to-Live state + tombstone                  |
| `/opt/ai-zombie/state/logs/pi-mono.*.log`  | Per-turn pi-mono bridge logs (rotated daily)    |
| `/opt/ai-zombie/state/pi-mono-sessions/`   | pi session/checkpoint state                     |

## Operator helpers

`scripts/install.sh` installs a small set of helper commands under
`/opt/ai-zombie/bin/`:

| Command                | Purpose                                                                 |
| ---------------------- | ----------------------------------------------------------------------- |
| `secrets-edit`         | Safely edit `secrets/env`; re-asserts `0600` mode after `$EDITOR` exits |
| `health-check`         | One-shot health summary (chat service, provider token, disk, …)         |
| `audit-recent`         | Tail the most recent decisions from `audit.log`                         |
| `collect-diagnostics`  | Bundle logs and state into a tarball with secrets redacted              |
| `zombie-chat`          | Print the local chat URL                                               |

The installer also drops `verify` under the same directory.

## Interactive setup review

When `scripts/install.sh install` runs on an interactive terminal (i.e.
not `--yes` and not `ZOMBIE_NONINTERACTIVE=1`), it opens an editable
**parameter review** before touching the host. Every install parameter —
agent user, install root, chat port, transcript and receipt paths, chat
password, TTL, and local LLM selection — is listed in a branded summary.
Enter a number to edit a field (with validation and re-prompting on bad
input), toggle the boolean options, and repeat until you are satisfied;
then accept to begin the install. Cancelling at the review (`q`) exits
without changing anything.

The review uses the **Zombie Orchid** highlight (`#AC43D9`) with
compatible accent colours when colour is enabled. Colour follows the same
`ZOMBIE_COLOR=auto|always|never` / `NO_COLOR` policy as the rest of the
output, so `--no-color` produces a plain, screen-reader-friendly table.

Automated runs (`--yes`, `ZOMBIE_NONINTERACTIVE=1`, or non-TTY stdin) skip
the review entirely and use the supplied environment unchanged.

## Install receipt

Every install writes a human-readable **receipt** recording all parameters
when the run starts and the outcome (result, duration, service status,
applied/satisfied step counts, next step) when it finishes. A failed run
appends a `FAILED` record with the line and exit code. Secrets are never
written; password values and provider keys are excluded.

| Variable             | Default                                        | Effect                                             |
| -------------------- | ---------------------------------------------- | -------------------------------------------------- |
| `ZOMBIE_RECEIPT`     | `1`                                            | Set to `0` to disable the receipt.                 |
| `ZOMBIE_RECEIPT_FILE`| `/var/log/ubuntu-zombie/install-receipt.txt`   | Override the receipt file path (absolute).         |

## Install subcommands

`scripts/install.sh` is idempotent and exposes several subcommands;
all honour the same `ZOMBIE_*` environment variables documented
above:

| Subcommand  | Effect                                                                |
| ----------- | --------------------------------------------------------------------- |
| `install`   | Full install (default). Safe to re-run.                               |
| `verify`    | Read-only state check. Does not change state.                         |
| `doctor`    | Explain failures and likely fixes.                                    |
| `repair`    | Apply known-safe fixes (re-assert permissions, re-render `pi/` tree). |
| `uninstall` | Reverse the install (delegates to `scripts/uninstall.sh`).            |

After editing `policy.yaml` or any template under
`/opt/ai-zombie/agent/templates/`, run `sudo ./scripts/install.sh
repair` to re-render the `pi/` tree and restart the chat service.

## Command-line flags

`scripts/install.sh` accepts these flags in addition to the subcommands
above. They can be combined (e.g. `install --yes --strict`):

| Flag                 | Effect                                                                       |
| -------------------- | ---------------------------------------------------------------------------- |
| `-h`, `--help`       | Grouped help with end-to-end example recipes, then exit.                     |
| `-v`, `--version`    | Print the version and exit.                                                  |
| `-n`, `--dry-run`    | Print every action; mutate nothing.                                          |
| `-y`, `--yes`        | Skip the interactive `Type YES` gate (attended scripted runs). Still prompts for any missing inputs unless `ZOMBIE_NONINTERACTIVE=1`. |
| `-q`, `--quiet`      | Only print warnings and errors.                                              |
| `--verbose`, `--debug` | Write shell xtrace to the install transcript (not the console).            |
| `--no-color`         | Disable coloured output (also honours `NO_COLOR` and `ZOMBIE_COLOR=never`).  |
| `--strict`           | Treat preflight warnings as fatal.                                           |
| `--json`             | Emit machine-readable JSON from `verify` / `doctor` (human output is default). |

Colour follows the `ZOMBIE_COLOR=auto|always|never` policy and the
widely-supported [`NO_COLOR`](https://no-color.org/) convention; output
is plain when not writing to a TTY.

### Shell completion

Completion scripts live under `scripts/completions/`:

```bash
# bash
source scripts/completions/install.bash

# zsh — add the directory to $fpath, then:
autoload -U compinit && compinit
```

## Skills

Skill files are short markdown briefs the agent loads via `skill.list`
/ `skill.load`. They are read from two directories:

| Path                         | Purpose                                                         |
| ---------------------------- | --------------------------------------------------------------- |
| `/opt/ai-zombie/skills/`     | Root-owned, ships with the package (`apt`, `systemd`). |
| `/etc/ubuntu-zombie/skills.d/` | Operator-extensible. Same mode/owner contract as `policy.yaml`. |

Drop additional `*.md` files into `/etc/ubuntu-zombie/skills.d/` to
extend the catalogue. Names must be unique across both directories;
shadowing is rejected at load time.

## Advanced environment overrides

Most operators never need these — the defaults match what
`scripts/install.sh` lays down — but they are honoured by the agent
processes and are useful for development, CI, and bespoke layouts:

| Variable                  | Default                                  | Consumer            |
| ------------------------- | ---------------------------------------- | ------------------- |
| `ZOMBIE_DIR`              | `/opt/ai-zombie`                         | installer, agent    |
| `ZOMBIE_SECRETS`          | `${ZOMBIE_DIR}/secrets/env`              | `server.py`, audit  |
| `ZOMBIE_POLICY`           | `/etc/ubuntu-zombie/policy.yaml`         | `policy.py`         |
| `ZOMBIE_AUDIT_LOG`        | `/var/log/ubuntu-zombie/audit.log`       | `audit.py`, `audit-recent` |
| `ZOMBIE_AUDIT_VERBOSE`    | *(unset; off)*                           | `audit.py` (opt-in: adds redacted `stdout_preview`/`stderr_preview` to `tool_call` entries to aid pre-release testing and operator debugging) |
| `ZOMBIE_AUDIT_PREVIEW_BYTES` | `2048`                                | `audit.py` (per-stream preview cap when `ZOMBIE_AUDIT_VERBOSE=1`; hard ceiling 16 KiB) |
| `ZOMBIE_HISTORY_DB`       | `/opt/ai-zombie/state/conversations.db`  | `history.py`        |
| `ZOMBIE_SKILLS_DIR`       | *(unset)*                                | `skill_loader.py` (extra directory consulted first) |
| `ZOMBIE_NODE`             | `which node`                             | pi-ai bridge spawner |
| `ZOMBIE_PI_AI_BRIDGE`     | `${ZOMBIE_DIR}/agent/pi-ai-bridge.mjs`   | pi-ai bridge spawner (used by tests) |
| `ZOMBIE_PI_MONO_BIN`      | `which pi`                               | `pi_mono.py`        |
| `ZOMBIE_PI_MONO_BRIDGE`   | `${ZOMBIE_DIR}/agent/pi-mono-bridge.mjs` | `pi_mono.py` (used by smoke tests) |
| `ZOMBIE_PI_MONO_LOG_DIR`  | `/opt/ai-zombie/state/logs`              | `pi_mono.py`        |
| `ZOMBIE_PI_MONO_SETTINGS` | `/opt/ai-zombie/pi/settings.json`        | `pi_mono.py`        |

## Health check

Run on demand:

```bash
/opt/ai-zombie/bin/health-check
```

Enable the systemd timer for periodic checks:

```bash
sudo systemctl enable --now ubuntu-zombie-health.timer
```
