# FIX-3: Bugs found in `payload/`

This document lists bugs discovered in the files shipped under `payload/`
(the runtime that the installer drops onto the target machine): the
Python chat service under `payload/agent/`, the helper scripts under
`payload/bin/`, the systemd units under `payload/systemd/`, the policy
file under `payload/etc/`, and the logrotate config under
`payload/logrotate/`.

It is structured so an AI agent can process each entry independently
and in priority order.

## How to use this document

- Process items in the order they appear (highest impact first).
- Each entry has the same fields:
  - **id** — short stable identifier (`FIX-3-NN`) you can reference in
    commits/PRs.
  - **severity** — `critical` (breaks the running service or auto-runs
    something destructive), `high` (silent failure / security-adjacent
    risk), `medium` (correctness / footgun), `low` (style / latent).
  - **file** — path relative to the repository root.
  - **lines** — line range in the current `main` (verify before
    editing; line numbers drift).
  - **symptom** — observable bad behaviour.
  - **root cause** — why it happens.
  - **fix** — concrete remediation. Keep the change surgical.
  - **validation** — how to confirm the fix. Always re-run `make lint`
    and `make test` (see `Makefile:19-49`, `tests/smoke.sh`).
- One id per commit is ideal so each fix can be reverted independently.
- If a fix requires touching code outside the listed file/lines, note
  it in the commit body.

---

## Critical

### FIX-3-01 — `NoNewPrivileges=true` blocks every `sudo` command the model proposes

- **severity**: critical
- **file**: `payload/systemd/ubuntu-zombie-chat.service`
- **lines**: ~22 (`NoNewPrivileges=true`)
- **symptom**: Every privileged command the assistant proposes — every
  `sudo apt …`, `sudo systemctl …`, `sudo ufw …`, etc. — fails inside
  the chat service with `sudo: effective uid is not 0, is /usr/bin/sudo
  on a file system with the 'nosuid' option set or an NFS file system
  without root privileges?` or `sudo: a password is required`. The
  approval flow appears to work in the UI (operator clicks Approve)
  but `_execute` then returns a non-zero exit code with no useful
  output and the system is never actually changed.
- **root cause**: `NoNewPrivileges=true` prevents any child process
  from gaining privileges via setuid binaries. `sudo` is setuid, so it
  cannot elevate, regardless of the sudoers file. The whole product is
  designed around the agent account having passwordless sudo (see the
  system prompt in `payload/agent/server.py` ~lines 67-74 and the
  installer's sudoers drop-in); the hardening line silently breaks that
  contract.
- **fix**: Remove (or set to `false`) `NoNewPrivileges=true` in the
  chat unit. Keep the other hardening directives. Document in the unit
  why this one is intentionally absent (sudo elevation is required by
  design; the policy gate is the security boundary, not the systemd
  sandbox). If extra defence-in-depth is wanted, use a narrower
  mechanism such as a dedicated AppArmor profile that allows
  `/usr/bin/sudo`.
- **validation**:
  - `sudo systemctl daemon-reload && sudo systemctl restart
    ubuntu-zombie-chat`
  - From the UI, approve any `sudo` command (e.g. `sudo apt update`)
    and confirm `exit 0` plus real output in the result panel.
  - `make lint` (no shell scripts changed, but keep the gate green).

### FIX-3-02 — Service fails to start when `ZOMBIE_CHAT_PORT` is unset

- **severity**: critical
- **file**: `payload/systemd/ubuntu-zombie-chat.service`
- **lines**: ~9-15 (`EnvironmentFile=-/opt/ai-zombie/secrets/env`,
  `ExecStart=…--port ${ZOMBIE_CHAT_PORT}`)
- **symptom**: On a fresh install where the operator has not added
  `ZOMBIE_CHAT_PORT=…` to `/opt/ai-zombie/secrets/env`, the unit
  refuses to start. `journalctl -u ubuntu-zombie-chat` shows
  `server.py: error: argument --port: invalid int value: ''` or systemd
  rejects the command line entirely.
- **root cause**: `EnvironmentFile=` is marked optional (`-` prefix),
  and no `Environment=ZOMBIE_CHAT_PORT=7878` default is set in the
  unit. systemd expands `${ZOMBIE_CHAT_PORT}` to the empty string when
  the variable is undefined, producing `--port ''`. Python's argparse
  then dies. The default in `server.py` (`DEFAULT_PORT = …or "7878"`)
  is never reached because the empty string is explicitly passed.
- **fix**: Either
  1. Add `Environment=ZOMBIE_CHAT_PORT=7878` to the `[Service]`
     section (preferred — keeps the explicit `--port` flag), or
  2. Drop the `--port ${ZOMBIE_CHAT_PORT}` argument from `ExecStart`
     entirely and rely on `server.py`'s `DEFAULT_PORT` env-var fallback
     (also exported via `Environment=`).
- **validation**:
  - Remove any `ZOMBIE_CHAT_PORT` line from `/opt/ai-zombie/secrets/env`.
  - `sudo systemctl daemon-reload && sudo systemctl restart
    ubuntu-zombie-chat`.
  - `systemctl is-active ubuntu-zombie-chat` returns `active` and the
    UI is reachable on `http://127.0.0.1:7878/`.

### FIX-3-03 — `find` is classified as `read_only` and auto-executes destructive variants

- **severity**: critical
- **file**: `payload/etc/policy.yaml`
- **lines**: ~113 (`^(ls|cat|head|tail|less|file|stat|wc|find|grep|rg|ag)\b`)
- **symptom**: A prompt that produces ```bash<newline>find / -name
  '*.log' -delete``` (or `find … -exec rm -rf {} +`, or `find … -exec
  sh -c '…' \;`) bypasses the approval gate entirely: the chat service
  executes the `find` immediately because the rule classifies anything
  starting with `find` as `read_only`. This defeats the policy gate
  for one of the most dangerous tools in the Unix toolbox.
- **root cause**: `find` is grouped with truly read-only tools (`ls`,
  `cat`, …) in the `read_only` regex. The destructive-action rules
  earlier in the file only match the bare `rm`, `mkfs`, etc. heads;
  they do not look inside `find … -exec` or `find … -delete`.
- **fix**:
  1. Remove `find` from the `read_only` regex.
  2. Add an explicit `read_only` rule for the safe shape of `find`
     (no `-delete`, no `-exec`, no `-execdir`, no `-ok`, no `-okdir`,
     no `-fprint*`): for example match `^find\b` only when it does not
     contain any of those flags, or simply require operator approval
     for every `find` and let the operator decide.
  3. Add an explicit `destructive` rule for `find` invocations that
     contain `-delete` or `-exec*`/`-ok*` so they are flagged at the
     highest tier even when the operator is impatient.
- **validation**:
  - Unit-level: load the policy in a REPL and assert
    `policy.classify("find / -name '*.log' -delete") == "destructive"`
    and `policy.classify("find . -type f") == "read_only"` (or
    whatever class you settle on).
  - End-to-end: prompt the assistant to "delete all log files with
    find" and confirm an approval prompt appears (with the
    destructive-confirmation phrase) instead of immediate execution.
  - `make test` (smoke tests still pass).

---

## High

### FIX-3-04 — `setup-agent-venv` exits 0 even after Playwright install fails

- **severity**: high
- **file**: `payload/bin/setup-agent-venv`
- **lines**: ~58-68 (the `while true` loop wrapping
  `python -m playwright install chromium`)
- **symptom**: When the Playwright browser download fails four times
  in a row, the script prints `playwright install failed after N
  attempts; rerun later.` and then exits with status 0. The installer
  treats that as success, the desktop tooling (`browser-test.py`,
  etc.) is broken, and the failure surfaces only when the user tries
  to use the agent.
- **root cause**: The retry loop uses `break` to leave the loop on
  permanent failure, and the script then falls off the end with the
  last command's exit code (the `echo`, which is 0). There is no
  `exit 1`/`return 1` on the giving-up path.
- **fix**: On the giving-up path, set a non-zero exit (`exit 1`) so the
  caller can detect it. Optionally also write a sentinel file under
  `${HOME}/.cache/ubuntu-zombie/playwright-failed` so `health-check`
  can surface the problem without re-running pip.
- **validation**:
  - Run the script with the network unplugged (or
    `PLAYWRIGHT_DOWNLOAD_HOST=http://127.0.0.1:1/` to force failure)
    and confirm `echo $?` is non-zero.
  - `make lint` (shellcheck stays clean).
  - On a healthy machine, re-run and confirm `echo $?` is 0.

### FIX-3-05 — `runner.run()` crashes on commands with unbalanced quotes

- **severity**: high
- **file**: `payload/agent/runner.py`
- **lines**: ~28-34 (`tokens = shlex.split(command, posix=True) …`
  inside `_propose_follow_ups`)
- **symptom**: When the model proposes a command with an unbalanced
  quote (e.g. `apt install "foo`, `echo 'unterminated`) the chat
  service returns HTTP 500 to the browser and the audit log records
  no `execution` event. The conversation appears to hang from the
  user's point of view.
- **root cause**: `_propose_follow_ups` calls `shlex.split(command,
  posix=True)`, which raises `ValueError: No closing quotation` on
  malformed input. `run()` calls `_propose_follow_ups` after the
  subprocess returns, so the actual command may even have already
  executed by the time the exception fires, leaving the user with
  side-effects but no feedback.
- **fix**: Wrap the `shlex.split` call in `try/except ValueError` and
  fall back to `command.split()` (or simply return an empty
  `follow_ups` list). Either way `_propose_follow_ups` must never
  raise.
- **validation**:
  - Add a unit-level check (or run interactively): `run("echo 'oops")`
    returns a `CommandResult` with `exit_code != 0` and no exception
    bubbling out.
  - `make test`.

### FIX-3-06 — Logrotate config hard-codes `agent` user/group

- **severity**: high
- **file**: `payload/logrotate/ubuntu-zombie`
- **lines**: ~8 (`create 0640 agent agent`)
- **symptom**: When the operator installs with a non-default agent
  account (e.g. `AGENT_USER=zombie`), logrotate rotates the audit log
  and re-creates it owned by `agent:agent`. The chat service, running
  as `zombie`, then fails to append (permission denied), and either
  `_ensure_log` silently re-touches a new file (losing rotation) or
  every subsequent `log_event` call raises. Either way the audit trail
  is broken right after the first weekly rotation.
- **root cause**: The user/group in the `create` directive is a
  literal, but the matching service unit uses the `__AGENT_USER__`
  placeholder that the installer substitutes. The logrotate file has
  no such placeholder.
- **fix**: Change `create 0640 agent agent` to `create 0640
  __AGENT_USER__ __AGENT_USER__` and add this file to the list the
  installer rewrites with `sed -i "s/__AGENT_USER__/${AGENT_USER}/g"`
  (the same pass that templates the systemd units). If the installer
  already templates `payload/logrotate/ubuntu-zombie`, verify the
  substitution actually fires; if not, add it.
- **validation**:
  - Install with `AGENT_USER=zombie`; `cat
    /etc/logrotate.d/ubuntu-zombie` shows `create 0640 zombie zombie`.
  - Force a rotation: `sudo logrotate -f
    /etc/logrotate.d/ubuntu-zombie` and confirm
    `/var/log/ubuntu-zombie/audit.log` is owned by `zombie:zombie`.
  - Generate any chat event and confirm a new line is appended.

### FIX-3-07 — `_render_index` instantiates a provider client on every page load

- **severity**: high
- **file**: `payload/agent/server.py`
- **lines**: ~339-348 (`_render_index`)
- **symptom**: Reloading `/` (or any drive-by GET, including from a
  browser pre-fetcher) constructs a fresh `OpenAI()` /
  `anthropic.Anthropic()` client every time. On a slow box this adds
  hundreds of milliseconds per page load, and — more importantly — if
  the operator pastes a stale or invalid key, every `GET /` walks
  through full client setup just to render the status string. Under
  rapid reloads this can hit the upstream provider's rate limit on
  client metadata calls.
- **root cause**: `_render_index` calls `provider_from_env()` directly
  to render a status banner. There is no caching layer, and the
  function has the side-effect of constructing the SDK client.
- **fix**: Render the status banner from a cheap, side-effect-free
  helper. Either
  1. Add a `provider_status()` function in `providers.py` that returns
     `("openai", "configured")` / `("anthropic", "configured")` /
     `("none", "no API key found")` by inspecting environment variables
     only, or
  2. Cache the provider instance on the `App` (created once at
     startup) and re-use it from both the page render and
     `post_message`.
- **validation**:
  - `time curl -s http://127.0.0.1:7878/ > /dev/null` is consistently
    < 50 ms after the change.
  - `make test`.

### FIX-3-08 — Secrets are loaded into the process environment before the safe-mode check

- **severity**: high
- **file**: `payload/agent/server.py`
- **lines**: ~437-440 (`main()`: `load_secrets_env(); assert_secrets_safe()`)
- **symptom**: If `/opt/ai-zombie/secrets/env` is group- or
  world-readable, the service refuses to start — but only *after* it
  has already parsed the file and pushed every key/value into
  `os.environ`. Any later log line that dumps the environment (e.g.
  the systemd "process exited" diagnostics, an `ExecStopPost=` hook,
  or a future `log_event` that records `os.environ`) will leak the
  secret. Defence-in-depth violation.
- **root cause**: The two calls are in the wrong order.
- **fix**: Swap them — call `assert_secrets_safe()` *before*
  `load_secrets_env()`. The safe-mode check only stats the file; it
  does not need the contents.
- **validation**:
  - `chmod 0644 /opt/ai-zombie/secrets/env; sudo systemctl restart
    ubuntu-zombie-chat`; `journalctl -u ubuntu-zombie-chat` shows the
    refusal-to-start message and no environment dump containing
    `OPENAI_API_KEY=…`.
  - Restore `chmod 0600` and confirm normal startup.

---

## Medium

### FIX-3-09 — `extract_commands` only matches LF-terminated fences (CRLF breaks it)

- **severity**: medium
- **file**: `payload/agent/server.py`
- **lines**: ~147 (`_BASH_BLOCK = re.compile(r"```(?:bash|sh|shell)\n(.*?)```",
  re.DOTALL)`)
- **symptom**: When the provider returns a reply with CRLF line
  endings (some Anthropic and self-hosted models do, especially when
  the prompt was originally Windows-authored), the regex fails to
  match because it requires `\n` immediately after the language
  tag — `bash\r\n` does not satisfy that. The model "proposed" a
  command but the gate never sees it, so nothing executes and the
  user sees only the prose.
- **root cause**: The newline after the language tag is hard-coded
  rather than written as `\r?\n` / `[\r\n]+`.
- **fix**: Change the regex to `re.compile(r"```(?:bash|sh|shell)
  *\r?\n(.*?)```", re.DOTALL)`. Also accept zero language tag (some
  models open with ` ``` ` alone) by adding an optional language
  group: `r"```(?:bash|sh|shell)?[ \t]*\r?\n(.*?)```"`.
- **validation**:
  - Add a `tests/smoke.sh python` check or a quick REPL run:
    `extract_commands("```bash\r\nls\r\n```")` returns `["ls"]`.
  - `make test`.

### FIX-3-10 — `extract_commands` splits multi-line commands across line continuations

- **severity**: medium
- **file**: `payload/agent/server.py`
- **lines**: ~151-159 (`extract_commands` body)
- **symptom**: When the model proposes a single logical command that
  spans multiple lines via backslash-continuation or here-docs (e.g.
  `cat <<'EOF' > /etc/foo<newline>…<newline>EOF`), each physical line
  is treated as a separate command. The first line goes through the
  policy gate alone, often misclassified, and the continuation lines
  are run as standalone shell statements (frequently failing with
  syntax errors).
- **root cause**: The extractor iterates `block.splitlines()` and
  appends each non-comment, non-blank line as an independent command.
  It has no notion of `\`-continuation or here-docs.
- **fix**: Either
  1. Document and enforce the "one command, one line" contract by
     refusing to run any block that contains continuation or here-doc
     syntax and surface that to the user, or
  2. Pre-process the block: join trailing-`\` lines, treat the entire
     block as a single command when it contains `<<` here-docs, and
     send the joined string through the policy gate as one unit.
- **validation**:
  - Add a regression check (REPL or a Python smoke test):
    `extract_commands("```bash\necho a \\\\\n  b\n```")` returns
    `["echo a   b"]` (or whatever the chosen contract is).
  - `make test`.

### FIX-3-11 — `audit.redact` rewrites `:` separators as `=`

- **severity**: medium
- **file**: `payload/agent/audit.py`
- **lines**: ~30-31 (`(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*\S+`
  replaced with `\1=***REDACTED***`)
- **symptom**: A log line that contained `Authorization: ****** or
  `password: hunter2` is rewritten to `Authorization=***REDACTED***` /
  `****** The redaction is correct, but the
  surrounding text is silently mutated, which makes the audit log
  diverge from what was actually emitted. Operators grepping for
  `Authorization: Bearer` see nothing.
- **root cause**: The replacement template hard-codes `=` regardless
  of which separator (`:` or `=`) was captured. The separator is not
  itself in a capture group.
- **fix**: Capture the separator in its own group and reuse it:
  `re.compile(r"(?i)(api[_-]?key|token|password|secret)(\s*[:=]\s*)\S+")`
  with replacement `r"\1\2***REDACTED***"`.
- **validation**:
  - REPL: `redact("Authorization: ******")` returns
    `"Authorization: ***REDACTED***"` (colon preserved).
  - `make test`.

### FIX-3-12 — `extract_commands` always strips leading `#` lines, even inside multi-line bodies

- **severity**: medium
- **file**: `payload/agent/server.py`
- **lines**: ~155-158 (the `if not stripped or stripped.startswith("#"):
  continue` filter)
- **symptom**: A shebang line (`#!/usr/bin/env bash`) at the top of a
  proposed script is dropped, and so are inline shell comments that
  the model intentionally included for the operator to read in the
  approval dialog. With FIX-3-10's join-lines fix the shebang becomes
  silent corruption of the command actually run.
- **root cause**: The naive `startswith("#")` filter does not
  distinguish "this whole line is a comment in the middle of a script"
  from "the first character of the executable line is `#`". For
  single-line commands the current heuristic is fine; for any future
  multi-line support it is wrong.
- **fix**: Couple this with FIX-3-10. If the contract is "one command
  per line", keep the filter but document that the assistant must not
  prefix its real commands with `#`. If multi-line commands are
  supported, drop the per-line `#` filter and let the shell handle
  comments.
- **validation**: Covered by FIX-3-10's regression tests once the
  contract is decided.

### FIX-3-13 — `load_secrets_env` does not understand `export FOO=bar` or trailing comments

- **severity**: medium
- **file**: `payload/agent/server.py`
- **lines**: ~106-118 (`load_secrets_env`)
- **symptom**: Operators routinely write env files in shell style
  (`export OPENAI_API_KEY=sk-…`). With the current parser, the key
  becomes literally `export OPENAI_API_KEY` (with the `export ` prefix),
  which never matches what `os.environ.get("OPENAI_API_KEY")` looks for.
  Result: "No provider API key found" even though the key is sitting
  in the file. Similarly, a trailing `# comment` on the same line gets
  swallowed into the value.
- **root cause**: The parser only strips outer quotes and splits on
  the first `=`. It does not strip a leading `export ` token and does
  not honour `#` mid-line comments. (It correctly skips lines that
  *start* with `#`, but only those.)
- **fix**: Before partitioning on `=`:
  1. Strip a leading `export ` (case-sensitive, followed by space).
  2. Drop everything from an unquoted `#` to end-of-line (be careful
     not to break values that contain `#` inside quotes).
- **validation**:
  - REPL/unit: an env file containing `export OPENAI_API_KEY=sk-test
    # for testing` results in `os.environ["OPENAI_API_KEY"] ==
    "sk-test"`.
  - `make test`.

### FIX-3-14 — Policy mtime cache loses sub-second edits

- **severity**: medium
- **file**: `payload/agent/policy.py`
- **lines**: ~258-264 (`_cache` based purely on `path.stat().st_mtime`)
- **symptom**: An operator edits `policy.yaml` twice within the same
  second (e.g. a quick `sed -i` followed by a tweak), the chat service
  picks up the first edit but not the second, leaving an inconsistent
  policy in effect until the file is touched again. On most modern
  filesystems `st_mtime` has nanosecond resolution, but several CI
  setups and tmpfs configurations report only whole seconds, where
  this bites in practice.
- **root cause**: The cache key compares the equality of `st_mtime`
  alone. Two writes inside a single FS-tick get the same mtime.
- **fix**: Use `(st_mtime_ns, st_size)` as the cache key (or
  `st_mtime_ns` alone on Python 3.3+). Both are available from
  `os.stat_result`.
- **validation**:
  - REPL: write file, `load_policy()`, write again immediately,
    `load_policy()` reflects the second write.
  - `make test`.

### FIX-3-15 — `audit._ensure_log` permission depends on the process umask

- **severity**: medium
- **file**: `payload/agent/audit.py`
- **lines**: ~56-59 (`_ensure_log`)
- **symptom**: After a `logrotate` cycle that omits the
  `create 0640 …` directive (or before the first rotation, on a fresh
  install), the chat service touches the audit log with `mode=0o640`
  but the actual mode lands as `0o640 & ~umask`, which is `0o620`
  under a stock `umask 022`. The audit log then becomes
  group-writable-but-not-readable, which trips the `audit-recent`
  hint that the log is "not readable" for users in the agent group.
- **root cause**: `Path.touch(mode=…)` applies the current umask. The
  service inherits whatever umask systemd or the operator set; there
  is no explicit `os.umask(0)` around the touch and no
  `os.chmod(path, 0o640)` after the fact.
- **fix**: After the `AUDIT_PATH.touch(mode=0o640)` call, explicitly
  `os.chmod(AUDIT_PATH, 0o640)` (or wrap the touch in a `umask(0)`
  context manager). The chown is the operator's job (systemd `User=`
  takes care of ownership).
- **validation**:
  - Delete `/var/log/ubuntu-zombie/audit.log`, run any chat event,
    `stat -c %a /var/log/ubuntu-zombie/audit.log` returns `640`
    irrespective of `umask`.
  - `make test`.

### FIX-3-16 — `runner.run` uses a login shell (`bash -lc`), which is heavy and noisy

- **severity**: medium
- **file**: `payload/agent/runner.py`
- **lines**: ~64-72 (`subprocess.run(["bash", "-lc", command], …)`)
- **symptom**: Every proposed command spins up a full login shell:
  `/etc/profile`, `/etc/profile.d/*`, `~/.bash_profile`/`~/.profile`,
  and (in some configurations) the MOTD are all evaluated for each
  call. This adds 50-200 ms per command, can change `PATH` in
  surprising ways depending on the operator's profile, and pollutes
  `stderr` with MOTD lines that then end up in the assistant's
  context.
- **root cause**: `-l` (login) was almost certainly meant to be `-c`
  alone. There is no need to source profile files for a single
  short-lived command whose environment is already constructed
  explicitly in `env={**os.environ, **(env or {})}`.
- **fix**: Drop the `-l`: use `["bash", "-c", command]`. If a specific
  profile fragment is required (PATH adjustments, etc.), prepend it
  to `command` or add it to `env` at call sites.
- **validation**:
  - REPL: `run("echo hello").stdout` is exactly `"hello\n"`, with no
    MOTD leakage on a machine that has `/etc/motd` configured.
  - Time `run("true")` before and after; expect a noticeable drop.
  - `make test`.

### FIX-3-17 — `history.add_message` commits twice and leaves a window where the row has no title

- **severity**: medium
- **file**: `payload/agent/history.py`
- **lines**: ~71-91 (`add_message`)
- **symptom**: `add_message` inserts the message, commits, then runs a
  separate `SELECT title … UPDATE conversations SET title = …` and
  commits again. Another reader (the conversation-list endpoint,
  another chat session) can land between the two commits and see a
  conversation with messages but `title = ''`. The UI then shows
  "(untitled)" forever for that conversation, because the first user
  message has already been recorded by the time the title update
  fires next.
- **root cause**: The two writes are not in a single transaction. The
  `_execute` helper always commits.
- **fix**: Bundle the message insert and the conditional title update
  into one transaction. The simplest fix: acquire `self._lock`, run
  both statements through a single `self._conn.execute…` pair without
  the intermediate commit, then commit once.
- **validation**:
  - Open two browser tabs against the same chat service. In tab A,
    send the very first message. In tab B, GET
    `/api/conversations` repeatedly during the request; the new
    conversation should never appear with an empty title.
  - `make test`.

### FIX-3-18 — `audit.tail` reads the entire audit log into memory

- **severity**: medium
- **file**: `payload/agent/audit.py`
- **lines**: ~70-86 (`tail()`)
- **symptom**: `GET /api/audit` returns the last 50 entries by calling
  `tail(50)`, which `readlines()` the entire `audit.log`. After a few
  weeks of busy use the log can be tens of MB; every audit page load
  reads the whole file. Operators with a hot audit log (chatty agent
  + delayed logrotate) see noticeable latency.
- **root cause**: `fh.readlines()` slurps everything before slicing.
- **fix**: Use a small ring buffer over `collections.deque(maxlen=n)`
  while iterating the file, or seek-from-end and read backwards in
  blocks. The deque approach is one line and good enough:
  `lines = list(deque(fh, maxlen=n))`.
- **validation**:
  - Stuff `/var/log/ubuntu-zombie/audit.log` with 200k synthetic
    lines, time `curl /api/audit`; expect O(n) instead of O(file
    size).
  - `make test`.

---

## Low

### FIX-3-19 — `SYSTEM_PROMPT` is double-templated and breaks if `AGENT_USER` contains `{` or `}`

- **severity**: low
- **file**: `payload/agent/server.py`
- **lines**: ~67-85 (`SYSTEM_PROMPT_TEMPLATE.format(agent_user=AGENT_USER)`
  followed later by `SYSTEM_PROMPT.format(facts=facts)`)
- **symptom**: The system prompt is formatted twice: once at module
  load with `agent_user=…` and once per message with `facts=…`. If
  `ZOMBIE_USER` ever contains a literal `{` or `}` (legal-ish in some
  systems, common in typo'd unit overrides like `User={agent}`), the
  second `.format` call raises `KeyError` and the request fails with
  a generic exception. Similarly, any future template variable
  introduced into `SYSTEM_PROMPT_TEMPLATE` must be escaped (`{{`/`}}`)
  to survive the first pass — a footgun.
- **root cause**: Two-stage `.format` with no escaping discipline.
- **fix**: Replace the two-stage `format` with a single render call
  per message: keep one template string with `{agent_user}` and
  `{facts}` placeholders and substitute both at the same time in the
  request handler. Or use `str.replace("{agent_user}", AGENT_USER)`
  at module load (no format semantics, no escaping required).
- **validation**:
  - REPL: set `ZOMBIE_USER='{bad}'`, import `server`, send a
    `post_message` call; it should not raise.
  - `make test`.

### FIX-3-20 — `Handler.app` is set as a class attribute, sharing state across servers

- **severity**: low
- **file**: `payload/agent/server.py`
- **lines**: ~423-426 (`make_handler` sets `Handler.app = app`)
- **symptom**: Only relevant if someone (e.g. a test, or an operator
  running two listeners for migration) constructs two `App` instances
  and two `ThreadingHTTPServer`s in the same process — the second
  `make_handler` call overwrites `Handler.app`, and the first server
  silently starts serving the second server's app.
- **root cause**: The handler factory mutates a class attribute
  instead of creating a fresh subclass per `App`.
- **fix**: Return an actual subclass per call: `class _Handler(Handler):
  app = app; return _Handler`. Or pass the app via `functools.partial`
  to `ThreadingHTTPServer`'s third argument (which `http.server`
  supports via `RequestHandlerClass` constructor injection in 3.7+).
- **validation**:
  - Unit-level: construct two `make_handler(app)` instances with
    different apps and confirm each handler class sees its own app.
  - `make test`.

### FIX-3-21 — `audit-recent -n` does not validate its argument

- **severity**: low
- **file**: `payload/bin/audit-recent`
- **lines**: ~22-30 (the `case` over `-n`)
- **symptom**: `audit-recent -n foo` shells out to
  `tail -n foo /var/log/ubuntu-zombie/audit.log`, which prints
  `tail: invalid number of lines: 'foo'` and exits non-zero. Cosmetic
  but inconsistent with the script's friendly usage banner elsewhere.
- **root cause**: No validation of `${N}`.
- **fix**: Guard with `[[ "${N}" =~ ^[0-9]+$ ]] || { echo "..."; usage
  >&2; exit 2; }` before reaching `tail`.
- **validation**: `audit-recent -n foo` exits 2 with a useful message;
  `audit-recent -n 5` still works.

### FIX-3-22 — `health-check` swallows the exit status of the `gui-env xdotool` probe

- **severity**: low
- **file**: `payload/bin/health-check`
- **lines**: ~74-80 (`if "${ZOMBIE_DIR}/bin/gui-env" xdotool …`)
- **symptom**: When `${ZOMBIE_DIR}/bin/gui-env` does not exist (the
  helper is created by `scripts/install.sh`, not shipped under
  `payload/`), the `if` arm evaluates to false and the script falls
  through to the `warn` branch saying "DISPLAY=… but xdotool failed".
  That is misleading: the real failure is "the helper script is
  missing", not an `xdotool` problem.
- **root cause**: The check folds two distinct failure modes (helper
  missing vs. helper found but xdotool failed) into one warn message.
- **fix**: Test `[[ -x "${ZOMBIE_DIR}/bin/gui-env" ]]` first; if not,
  warn with a specific message ("gui-env helper missing — re-run
  install.sh") and skip the xdotool probe.
- **validation**:
  - Rename `${ZOMBIE_DIR}/bin/gui-env` aside, re-run
    `health-check`, confirm the new specific message appears.
  - Restore and re-run.

### FIX-3-23 — `collect-diagnostics` leaks the bundle directory if `tar` fails

- **severity**: low
- **file**: `payload/bin/collect-diagnostics`
- **lines**: ~63-66 (the final `tar -czf … && rm -rf "${BUNDLE_DIR}"`)
- **symptom**: When `tar` fails (out of space in `${OUT_DIR}`,
  filesystem hiccup, etc.), `set -e` aborts the script and the
  `mktemp -d` bundle directory is left behind under `${TMPDIR}`. Over
  time these accumulate.
- **root cause**: No `trap … EXIT` for cleanup. The cleanup `rm -rf`
  runs only on success.
- **fix**: Add `trap 'rm -rf "${BUNDLE_DIR}"' EXIT` near the top of
  the script (after `BUNDLE_DIR=…`). Then drop the explicit `rm -rf`
  at the bottom (the trap handles both success and failure).
- **validation**:
  - Run with `OUT_DIR=/full-disk` (or `chmod -w` the target dir to
    force tar failure); the script exits non-zero and leaves no
    `ubuntu-zombie-diagnostics-*` directory behind.
  - `make lint`.

### FIX-3-24 — `extract_commands` regex does not anchor the language tag

- **severity**: low
- **file**: `payload/agent/server.py`
- **lines**: ~147 (`_BASH_BLOCK` pattern)
- **symptom**: Triple-backtick blocks with `console`, `bash session`,
  `text`, or no language tag at all are silently ignored. Many models
  default to `console` or blank. Net effect: commands proposed in
  those blocks never reach the policy gate; the operator sees prose
  with embedded ``` blocks but no actionable proposals.
- **root cause**: The regex hard-codes `(?:bash|sh|shell)`.
- **fix**: Accept blank or any of a small, documented allow-list:
  `r"```(?:bash|sh|shell|console|text)?[ \t]*\r?\n(.*?)```"`. Combine
  with FIX-3-09's CRLF fix in the same edit. Document in the system
  prompt that the assistant should still prefer ` ```bash `.
- **validation**: REPL — `extract_commands("```\nls\n```")` returns
  `["ls"]`; `extract_commands("```console\nls\n```")` returns `["ls"]`.

### FIX-3-25 — `policy.classify` falls back to `system_change` for commands containing newlines

- **severity**: low
- **file**: `payload/agent/policy.py`
- **lines**: ~52-56 (`classify` body) plus the rules using `^` anchors
  in `payload/etc/policy.yaml`
- **symptom**: All the `read_only` rules use `^...` anchors. Because
  `re.search` is *not* multiline by default, `^` matches the start of
  the string only. A multi-line command (see FIX-3-10) is therefore
  never classified `read_only` and always falls back to
  `system_change`. That is actually safe (requires approval), but the
  classifications drift further from operator expectation the more
  multi-line work flows in.
- **root cause**: Mismatch between the `^` anchors in the policy and
  the `re.search` call (no `re.MULTILINE`).
- **fix**: Either compile rule patterns with `re.MULTILINE` in
  `_extract_rules_from_text` (and `_coerce_rules`), or normalise the
  command to a single line before classification (collapse whitespace,
  drop continuation backslashes). Pair with FIX-3-10's contract
  decision so the two stay consistent.
- **validation**:
  - REPL: `policy.classify("ls\nwhoami") == "read_only"` (or whatever
    the chosen contract dictates).
  - `make test`.

### FIX-3-26 — Bare `rm` / `mv` rules in `policy.yaml` fire on harmless commands

- **severity**: low
- **file**: `payload/etc/policy.yaml`
- **lines**: ~91-94 (`'\brm\s+'`, `'\bmv\s+'`)
- **symptom**: Innocuous commands like `apt-get autoremove` (no, that
  one is caught by an earlier rule), `git rm`, `git mv`, or a custom
  alias `rm-old` are flagged as `system_change` and require approval
  even when the model only ran them in a read context. This is on the
  *cautious* side, so it is not dangerous, but it adds friction and
  trains the operator to click "approve" without thinking.
- **root cause**: The patterns are bare `\brm\s+` / `\bmv\s+` with no
  awareness of `git rm` / `git mv` / `apt rm` / etc.
- **fix**: Re-order or refine the rules. Specifically, add explicit
  `read_only`/`user_change` rules for `git rm`, `git mv`, etc. *above*
  the bare `\brm\s+` / `\bmv\s+` rules (first match wins). Better
  still, anchor the rule with a leading start-of-string or a negative
  lookbehind for `git `/`apt `.
- **validation**:
  - REPL: `policy.classify("git rm foo") == "user_change"`,
    `policy.classify("rm -rf foo") == "system_change"`.
  - `make test`.

---

## Cross-cutting notes for the reviewing agent

- Several entries (FIX-3-09, FIX-3-10, FIX-3-12, FIX-3-24, FIX-3-25)
  interact: a coherent fix is to first decide whether the assistant
  is allowed to propose multi-line commands. Make that decision once
  and then apply all five fixes against it. Otherwise the patches
  will fight each other.
- FIX-3-01 (NoNewPrivileges) and FIX-3-02 (ZOMBIE_CHAT_PORT) both
  touch `payload/systemd/ubuntu-zombie-chat.service` and should be
  fixed in the same commit — `daemon-reload` is required either way.
- FIX-3-06 touches both `payload/logrotate/ubuntu-zombie` and
  `scripts/install.sh` (the templating pass). Verify the install
  script substitutes `__AGENT_USER__` in this file too; if not, add
  the substitution there.
- After every payload change, re-run `make lint`, `make test`, and
  `make package` to confirm the packaging stays green; the smoke
  tests under `tests/smoke.sh` include `bash -n` syntax checks and
  `py_compile` over `payload/agent/*.py`.
