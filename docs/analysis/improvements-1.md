# Ubuntu Zombie improvements 1

This document turns a review of the current idea and implementation into
implementation-ready work. It is written for an AI coding agent starting
from a fresh checkout of this repository.

Before changing code, read:

- `AGENTS.md`
- `README.md`
- `docs/VISION.md`
- `docs/ARCHITECTURE.md`
- `SECURITY.md`
- `CONTRIBUTING.md`

Do not run `make install-local`, `scripts/install.sh install`, or
`scripts/uninstall.sh` on the current workstation. Those commands mutate
users, sudoers, services, firewall rules, Docker, VNC, and Tailscale
state. Use only non-root tests unless the user explicitly provides a
disposable Ubuntu Desktop LTS VM.

After shell or Python changes, run:

```bash
make lint
make test
```

If the local environment cannot run those commands, say exactly why.

## Summary

Ubuntu Zombie has a strong product direction: a private, root-capable AI
systems administrator with local audit logs, an explicit policy gate, a
loopback-only UI, and operator revocation. The main problem is that the
implementation does not fully match that safety model.

Highest priority:

1. Ensure every model-initiated host action is mediated by Python's
   closed tool registry, policy gate, approval flow, and audit log.
2. Make the shipped policy defaults match the documented trust model.
3. Reduce the privilege blast radius of the agent account.
4. Improve previews, auditability, and tests so operators can trust each
   proposed action before it runs.

## P0: restore the closed tool and policy boundary

### Current state

The architecture promises that the model never executes free-form host
actions directly:

- `docs/ARCHITECTURE.md` says every action goes through
  `payload/agent/tools.py`.
- `payload/agent/tools.py` defines `TOOL_REGISTRY`, schema validation,
  and dispatch shims.
- `payload/agent/server.py` validates tool calls, classifies them with
  `policy.classify_tool`, queues approvals, and dispatches approved
  calls.

However, `payload/agent/pi-mono-bridge.mjs` currently starts `pi` in
JSON mode and enables pi's own built-in tools:

```js
const PI_BUILTIN_TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls"];
```

The comments in that file say pi executes those tools itself and the
bridge only logs `tool_execution_*` events. That means Python does not
validate arguments, classify the command, queue approval, or audit the
actual host mutation before it happens.

This is the most important implementation gap. A root-capable product
must make the trust boundary true in code, not only in docs.

### Desired behavior

For every model-initiated host action:

1. The bridge emits a tool call to Python.
2. Python calls `tools.validate_args`.
3. Python calls `policy.classify_tool`.
4. Read-only actions may execute automatically.
5. Elevated actions are queued for operator approval.
6. Destructive or high-risk actions require the configured phrase.
7. Python calls `tools.dispatch` only after the gate has allowed it.
8. Python records proposed, queued, approved, executed, denied, and
   errored actions in `audit.log`.
9. Tool observations are returned to the model.

No model-visible tool may bypass that path.

### Implementation approach

Prefer returning the bridge to an RPC-style flow where pi emits tool
calls and waits for Python-provided results. The exact upstream pi
protocol may require exploration, but the local contract should remain
the one already documented in `payload/agent/pi_mono.py`:

```text
bridge -> Python: {"type":"tool_call","id":...,"name":...,"args":{...}}
Python -> bridge: {"type":"tool_result","id":...,"ok":true|false,...}
bridge -> Python: {"type":"final","text":...}
```

Concrete steps:

1. Inspect the pinned `@earendil-works/pi-coding-agent` version and its
   supported tool protocol.
2. Update `payload/agent/pi-mono-bridge.mjs` so pi does not execute
   built-in host tools directly.
3. Remove or disable `PI_BUILTIN_TOOLS` for production use.
4. Pass only the logical registry tool names from Python to the model:
   `shell.run`, `fs.read`, `fs.list`, `fs.write`, `pkg.query`,
   `pkg.install`, `svc.status`, `svc.control`, `net.status`,
   `gui.screenshot`, `gui.click`, `gui.type`, `skill.list`,
   `skill.load`.
5. Translate upstream tool-call events into those logical tool names if
   pi requires a different schema.
6. Return Python's `tool_result` to the model before the model continues.
7. Keep the existing idle timeout and provider/model selection behavior.
8. Make bridge logs diagnostic only. The audit log must come from
   Python, not from pi's internal execution events.

If upstream pi cannot support externally-dispatched tools cleanly, do
not silently keep the bypass. Instead:

- Disable host tools in pi.
- Keep the assistant in explanation-only mode until a Python-mediated
  tool path exists.
- Update docs to describe the limitation.

### Files to change

- `payload/agent/pi-mono-bridge.mjs`
- `payload/agent/pi_mono.py`
- `payload/agent/templates/settings.json.tmpl`
- `tests/fixtures/stub-pi-mono.mjs`
- `tests/smoke.sh`
- `tests/python/test_policy.py` or a new `tests/python/test_bridge.py`
- `docs/ARCHITECTURE.md`
- `docs/INTERNET-ACCESS.md`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Tests to add

Add a regression test that fails if the production bridge enables pi
built-in host tools without Python mediation. Suggested checks:

- Static check: `payload/agent/pi-mono-bridge.mjs` must not pass
  `read,bash,edit,write,grep,find,ls` to pi in production mode.
- Protocol check: a stub bridge emits a `shell.run` call and Python
  records the call as queued or executed according to policy.
- Audit check: every executed tool call has a matching `tool_call`
  audit entry with `decision`.
- Approval check: elevated tool calls remain pending until
  `/api/approve` is called.

Add one integration-style unit test around `App.post_message` using
`ZOMBIE_PI_MONO_BRIDGE` and a stub plan:

1. Stub emits `{"type":"tool_call","id":"1","name":"shell.run",
   "args":{"argv":["sudo","apt-get","install","-y","curl"]}}`.
2. Policy classifies it as `system_change`.
3. The response has a pending tool event.
4. `tools.dispatch` is not called before approval.
5. Audit contains `decision:"queued"`.

### Acceptance criteria

- No model-initiated shell, file edit, package, service, GUI, Docker, or
  network action can execute unless Python dispatches it.
- The architecture document accurately describes the implemented bridge.
- The test suite fails if a future bridge reintroduces direct pi
  built-in execution.

## P0: make the shipped policy safe by default

### Current state

`payload/etc/policy.yaml` currently ships these risky defaults:

```yaml
settings:
  default_class: system_change

classes:
  read_only:
    approval: auto
  user_change:
    approval: auto
  system_change:
    approval: auto
  network_change:
    approval: auto
    confirm_phrase: true
  destructive:
    approval: required
    confirm_phrase: true
```

The tests and architecture text expect a stricter model:

- Unknown commands should fail closed to `destructive`.
- `system_change` should require approval.
- `network_change` should require approval and a phrase.
- Only read-only diagnostics should auto-run.

Because `server.py` executes calls immediately when
`policy.requires_approval(classification)` is false, the current
default policy can auto-run package installs, service restarts,
firewall changes, Tailscale changes, and many `sudo` commands.

### Desired default policy

Change `payload/etc/policy.yaml` to:

```yaml
settings:
  default_class: destructive

classes:
  read_only:
    approval: auto
    description: Diagnostics and inspection only.
  user_change:
    approval: required
    description: Changes within the agent account's home directory or user-owned files.
  system_change:
    approval: required
    description: Package, service, file, or Docker mutation.
  network_change:
    approval: required
    confirm_phrase: true
    description: Firewall, Tailscale, sshd, interface mutation.
  destructive:
    approval: required
    confirm_phrase: true
    description: Irreversible mutation. Requires confirmation phrase.
```

Also reduce the default budgets in the shipped file to match the docs
unless there is a documented reason not to:

```yaml
agent:
  max_tool_calls_per_turn: 12
  max_elevated_calls_per_turn: 3
  max_turn_seconds: 600
```

If the product intentionally wants a permissive mode, make it an
explicit opt-in profile, not the default. For example:

- keep `payload/etc/policy.yaml` conservative;
- add `docs/CONFIGURATION.md` guidance for editing policy;
- optionally add a commented `trusted-lab` example in docs, not active.

### Files to change

- `payload/etc/policy.yaml`
- `docs/ARCHITECTURE.md`
- `docs/CONFIGURATION.md`
- `docs/INTERNET-ACCESS.md`
- `README.md` if the quick trust summary mentions approval semantics
- `tests/smoke.sh`
- `tests/python/test_policy.py`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Tests to add or fix

Ensure tests load the shipped policy file and assert:

```python
p = policy.load_policy()
assert p.default_class == "destructive"
assert p.requires_approval(p.classify("foozle --bar"))
assert p.requires_approval(p.classify("sudo apt install curl"))
assert p.requires_approval(p.classify_tool("pkg.install", {"names": ["curl"]}))
assert p.requires_approval(p.classify_tool("svc.control", {
    "unit": "ssh",
    "action": "restart",
}))
assert p.requires_phrase(p.classify("ufw allow 80/tcp"))
assert not p.requires_approval(p.classify("ls /etc"))
```

Add a server-level test that confirms a `system_change` tool call is
queued, not dispatched, under the shipped policy.

### Acceptance criteria

- A first install cannot auto-run elevated model actions.
- Tests and docs agree with the shipped policy.
- Unknown commands classify as `destructive`.
- Only read-only actions auto-run by default.

## P1: reduce root-equivalent privilege exposure

### Current state

The agent account has passwordless sudo and is added to the Docker
group. Both are root-equivalent. The policy gate is therefore the main
runtime barrier.

This is workable for an MVP only if the policy boundary is airtight. It
is still a large blast radius if the agent account, model output, API
key, SSH key, browser automation path, or local session is compromised.

### Desired direction

Keep the product promise that the AI can administer the machine, but
reduce always-on root-equivalent access.

Recommended staged approach:

1. Keep `NOPASSWD: ALL` only as a compatibility mode.
2. Add an optional strict mode with a narrow privileged helper.
3. Move common privileged actions into typed tools where possible.
4. Remove Docker group membership by default or make it opt-in.

### Implementation option A: sudoers allow-list

Add a stricter sudoers mode controlled by an install-time env var:

```bash
ZOMBIE_PRIVILEGE_MODE=compat   # current behavior
ZOMBIE_PRIVILEGE_MODE=strict   # allow-listed commands only
```

In strict mode, generate a sudoers drop-in that allows only the command
families Ubuntu Zombie actually wraps:

- `/usr/bin/apt-get`
- `/usr/bin/dpkg`
- `/usr/bin/systemctl`
- `/usr/sbin/ufw`
- `/usr/bin/tailscale`
- `/usr/bin/install`
- `/usr/bin/chmod`
- `/usr/bin/chown`
- `/usr/bin/chgrp`
- other commands only after reviewing the typed tools and skills

This is imperfect because shell tools can still be broad, but it is an
improvement over `ALL`.

### Implementation option B: root helper

Create a small root-owned helper such as:

```text
/opt/ai-zombie/bin/privileged-action
```

The helper accepts structured JSON requests for specific privileged
operations, validates them again, logs them, and executes without a
general shell. Then sudoers grants:

```text
zombie ALL=(root) NOPASSWD: /opt/ai-zombie/bin/privileged-action
```

This is more work but aligns best with the closed-tool design.

### Docker group

Docker group access is root-equivalent. Improve this default:

1. Add `ZOMBIE_ENABLE_DOCKER=0|1`.
2. Default to `0` unless Docker is essential for the MVP.
3. If `0`, do not install Docker CE and do not add the agent to the
   Docker group.
4. Keep Docker tools and skills available only when Docker is enabled.
5. Update docs and `verify` output accordingly.

If Docker remains default-on, make the README and `SECURITY.md` say
plainly that the agent has root-equivalent Docker access by default.

### Files to change

- `scripts/install.sh`
- `scripts/uninstall.sh`
- `payload/bin/health-check`
- generated verify helper inside `scripts/install.sh`
- `payload/agent/tools.py`
- `payload/agent/skills/docker.md`
- `docs/CONFIGURATION.md`
- `docs/ARCHITECTURE.md`
- `docs/REQUIRES.md`
- `SECURITY.md`
- `README.md`
- `tests/smoke.sh`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Tests to add

- Non-root smoke test for `ZOMBIE_PRIVILEGE_MODE` validation.
- Non-root smoke test that generated sudoers text is syntactically
  valid where possible.
- Installer dry-run output test that shows whether Docker will be
  installed.
- Bad-usage tests for invalid privilege mode and Docker flag values.

### Acceptance criteria

- Operators can choose a stricter privilege posture at install time.
- The default posture is either stricter, or the docs clearly state why
  compatibility mode is default.
- Docker root-equivalence is opt-in or very clearly disclosed.

## P1: add action previews before approval

### Current state

The approval flow identifies the tool, args, classification, and
confirmation requirement. It does not consistently show an operator the
actual impact of the action.

### Desired behavior

Before approving elevated actions, the UI and API should expose a
preview object where feasible:

- file writes: target path, old hash, new hash, and unified diff;
- package installs: `apt-get --simulate install ...` output;
- package removals: `apt-get --simulate remove ...` output;
- service control: current state and intended action;
- firewall changes: current `ufw status numbered` and proposed rule;
- Tailscale changes: current `tailscale status` and proposed command;
- destructive actions: touched path/device summary and no auto-preview
  if preview itself would be risky.

### Implementation approach

Add a preview layer that runs before queuing or as part of pending-call
construction.

Possible API:

```python
def preview_tool(name: str, args: dict[str, Any], classification: str) -> dict[str, Any]:
    ...
```

Where to put it:

- small implementation: `payload/agent/tools.py`;
- cleaner implementation: new `payload/agent/previews.py`.

In `server.py`, after classification and before writing the pending
event, compute:

```python
preview = preview_tool(name, cleaned, classification)
```

Add `preview` to:

- the `tool_call` history event;
- the `pending_tool_call` history event;
- the `/api/pending` response;
- the queued `log_tool_call` audit entry.

Do not execute risky preview commands automatically. If a preview
cannot be produced safely, return:

```json
{"available": false, "reason": "..."}
```

### Files to change

- `payload/agent/server.py`
- `payload/agent/tools.py` or new `payload/agent/previews.py`
- `payload/agent/templates/index.html`
- `payload/agent/audit.py` if redaction needs extra coverage
- `tests/python/`
- `tests/smoke.sh`
- `docs/ARCHITECTURE.md`
- `docs/CONFIGURATION.md`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Tests to add

- `fs.write` preview produces a unified diff for an allowed existing
  file under a temp state directory.
- `pkg.install` preview uses `apt-get --simulate` and does not install.
- `svc.control` preview reports current service status.
- Preview errors do not block queuing unless the preview command itself
  violates policy or schema.
- Pending API includes a bounded preview.
- Audit redacts secrets in preview fields.

### Acceptance criteria

- Approval prompts show enough impact for an operator to make a real
  decision.
- Preview generation does not mutate host state.
- Preview output is bounded and redacted.

## P1: tighten filesystem read and write boundaries

### Current state

`payload/agent/tools.py` allows `fs.read` and `fs.list` under:

- `${ZOMBIE_DIR}/state`
- `/etc`
- `/var/log`
- `/proc`
- `/sys`
- `/usr/share/doc`

It allows `fs.write` under:

- `${ZOMBIE_DIR}/state`
- `/tmp`

This is better than arbitrary filesystem access, but `/etc` and
`/var/log` can contain secrets or sensitive local data. Also, shell
commands can still read broader paths if the bridge and policy allow
them.

### Desired behavior

Keep useful diagnostics but protect obvious sensitive paths.

Add deny-lists checked after resolving the path:

- `/etc/shadow`
- `/etc/gshadow`
- `/etc/sudoers`
- `/etc/sudoers.d`
- `/etc/ssh/ssh_host_*_key`
- `/etc/NetworkManager/system-connections`
- `/var/log/auth.log` may be readable only with truncation/redaction, or
  require approval
- `/proc/*/environ`
- `/proc/*/cmdline` may need redaction
- `/opt/ai-zombie/secrets`
- any path configured by `ZOMBIE_SECRETS`

For denied read paths, return a schema/policy rejection that explains
the path is sensitive.

### Implementation approach

In `payload/agent/tools.py`:

1. Add `_read_denied_prefixes()` and `_read_denied_exact_paths()`.
2. Add `_is_denied_read_path(path: Path) -> bool`.
3. In `_shim_fs_read` and `_shim_fs_list`, check deny-list after
   `resolve()`.
4. Add tests for symlink escape attempts and sensitive paths.

Consider adding a separate class for sensitive reads:

```yaml
sensitive_read:
  approval: required
```

Only do this if the policy class model is updated everywhere. A simpler
first implementation can reject sensitive reads outright.

### Files to change

- `payload/agent/tools.py`
- `payload/agent/audit.py`
- `payload/bin/collect-diagnostics`
- `tests/python/test_policy.py` or new `tests/python/test_tools.py`
- `docs/ARCHITECTURE.md`
- `SECURITY.md`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Tests to add

- `fs.read` rejects `/etc/shadow`.
- `fs.list` rejects `/opt/ai-zombie/secrets`.
- `fs.read` rejects a symlink under an allowed directory that resolves
  to a denied path.
- `fs.read` still allows `/etc/os-release`.
- Redaction covers any new sensitive preview or diagnostic fields.

### Acceptance criteria

- The model cannot read obvious local secrets through `fs.read` or
  `fs.list`.
- The implementation uses resolved paths, not string-prefix checks on
  unresolved input.
- Docs describe what local state the provider may see.

## P1: add real Ubuntu VM integration tests

### Current state

The repository has useful non-root smoke tests and Python unit tests,
but the installer's real behavior is host-mutating and cannot be fully
verified without a disposable Ubuntu VM.

### Desired coverage

Add an integration workflow that runs on disposable Ubuntu Desktop LTS
or a close VM image and verifies:

1. `install --dry-run`
2. non-interactive install with `SSH_PUBLIC_KEY` and `VNC_PASSWORD`
3. re-run install for idempotence
4. `verify`
5. `doctor`
6. `repair`
7. chat service binds only to loopback
8. secrets permission failure causes service refusal
9. policy blocks elevated action before approval
10. uninstall with archive on a disposable host

This can be a GitHub Actions workflow if nested virtualization is
available, or a documented local `multipass`/`qemu` test harness if not.

### Implementation approach

Create one of:

- `scripts/integration-vm.sh`
- `tests/integration/`
- `.github/workflows/integration.yml` updates

The integration runner must clearly refuse to run unless it detects a
disposable VM marker, for example:

```bash
ZOMBIE_INTEGRATION_ALLOW_HOST_MUTATION=I_AM_IN_A_DISPOSABLE_VM
```

Use placeholder credentials generated during the run:

- create an ephemeral SSH keypair;
- generate a random VNC password;
- use a stub provider bridge where possible;
- do not require real LLM API keys.

### Files to change

- `.github/workflows/integration.yml`
- `scripts/integration-vm.sh` or `tests/integration/*`
- `docs/PLATFORMS.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Acceptance criteria

- Maintainers have a repeatable way to test real installer behavior.
- The integration harness cannot accidentally run destructive install
  steps on a normal workstation without an explicit VM guard.
- Idempotence is tested by running install twice.

## P2: improve the operator approval UI

### Current state

The UI exposes pending calls and has approve/deny actions, but the
operator experience should be stronger for a product that can mutate
root-owned state.

### Desired behavior

For each pending action, show:

- tool name;
- classification;
- matched policy rule or tool default;
- whether sudo/root is involved;
- command argv or structured args;
- preview output;
- touched paths;
- audit id;
- exact confirmation phrase if required;
- deny button;
- approve button disabled until phrase is correct when required.

Add copy that is operational rather than marketing-oriented. Avoid
large explanatory blocks. Put the evidence next to the decision.

### Implementation approach

Update `payload/agent/templates/index.html`:

1. Render pending calls as compact action panels.
2. Show preview fields if present.
3. Show the audit id and tool-call id.
4. For destructive or network changes, require typing the phrase into a
   local input before enabling approve.
5. Keep slash commands working.
6. Ensure mobile layout does not overlap.

Add API fields from `server.py` as needed.

### Files to change

- `payload/agent/templates/index.html`
- `payload/agent/server.py`
- `docs/ARCHITECTURE.md`
- `tests/smoke.sh`
- optional browser/UI tests if a browser test harness exists
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Acceptance criteria

- Operators can understand what they are approving without reading raw
  logs.
- The approve button cannot accidentally submit a destructive action
  without the exact phrase.
- Existing `/approve` and `/deny` commands still work.

## P2: make network exposure safer by default

### Current state

Tailscale is off by default. With the default, UFW allows SSH on every
interface, with key-only auth and root login disabled. This is a
reasonable technical baseline, but it may be too exposed for the target
audience.

### Desired direction

Choose one of these product positions and make it consistent:

1. Tailscale-first default: install/enrol Tailscale unless explicitly
   skipped, and allow SSH only on `tailscale0`.
2. Local-only default: do not open inbound SSH unless the operator opts
   in.
3. Current default retained: keep SSH on every interface, but make the
   risk more prominent in quickstart and installer confirmation.

For novice users, option 1 or 2 is safer. Option 3 is simpler but needs
clear warnings.

### Implementation option: local-only default

Add:

```bash
ZOMBIE_ENABLE_SSH_INGRESS=0|1
```

Default to `0` for new installs. If `0`:

- install and harden sshd if required;
- write authorized keys;
- do not add a UFW allow rule for port 22;
- print local-only instructions.

If `1` and Tailscale is skipped:

- allow SSH on every interface;
- require an interactive confirmation or `--yes`.

### Files to change

- `scripts/install.sh`
- `scripts/uninstall.sh`
- `docs/QUICKSTART.md`
- `docs/CONFIGURATION.md`
- `docs/TAILSCALE.md`
- `docs/REQUIRES.md`
- `SECURITY.md`
- `README.md`
- `tests/smoke.sh`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Acceptance criteria

- A new operator cannot accidentally expose SSH broadly without seeing
  a clear choice.
- Existing users have an upgrade path that preserves their configured
  posture.
- `verify`, `doctor`, and `repair` understand the chosen ingress mode.

## P2: align names, docs, and generated state

### Current state

The docs alternate between `agent` and `zombie` for the local Linux
account. The code supports `ZOMBIE_USER`, while some docs still discuss
`agent`. Some architecture and configuration sections also disagree
with shipped policy defaults and budgets.

### Desired behavior

Use one canonical term:

- product role: "AI Systems Administrator";
- default Linux account: `zombie`;
- configurable env var: `ZOMBIE_USER`;
- legacy alias: `AGENT_USER`, documented only as backward-compatible.

### Implementation approach

Search and update docs carefully:

```bash
rg -n "\bagent\b|AGENT_USER|zombie" README.md docs SECURITY.md CONTRIBUTING.md payload scripts tests
```

Do not blindly replace all occurrences. Keep "agent" when it refers to
the general AI agent concept or Python package names. Replace only
account-identity text that should say `zombie`.

Also align these docs with the final policy:

- `docs/ARCHITECTURE.md`
- `docs/CONFIGURATION.md`
- `SECURITY.md`
- `README.md`
- `docs/INTERNET-ACCESS.md`

### Acceptance criteria

- A new reader understands the account model without reconciling
  `agent` vs `zombie`.
- Docs match the installed defaults.
- Tests cover the policy defaults that docs describe.

## P2: add first-class read-only web fetch safely

### Current state

`docs/INTERNET-ACCESS.md` notes that outbound networking is available,
but there is no first-class `web.fetch` tool. It also describes the
current bridge bypass issue. Do not add internet features until P0 is
fixed, because fetches must also go through Python policy and audit.

### Desired behavior

After P0 is complete, add a typed read-only fetch tool:

```text
web.fetch
```

Arguments:

- `url`: string, required;
- `max_bytes`: integer, optional, default 65536;
- `timeout`: integer, optional, default 20;
- `headers`: object, optional, only allow safe request headers.

Restrictions:

- only `http` and `https`;
- no request body;
- no POST/PUT/PATCH/DELETE;
- deny loopback, link-local, private RFC1918, and cloud metadata IPs by
  default;
- follow redirects only within safe schemes;
- cap response body;
- redact response before audit/history.

### Files to change

- `payload/agent/tools.py`
- `payload/agent/templates/settings.json.tmpl`
- `payload/agent/skills/web.md`
- `payload/agent/server.py` system prompt text
- `payload/etc/policy.yaml`
- `tests/smoke.sh`
- `tests/python/test_policy.py` or new `tests/python/test_web_fetch.py`
- `docs/INTERNET-ACCESS.md`
- `docs/ARCHITECTURE.md`
- `docs/CONFIGURATION.md`
- `CHANGELOG.md`
- `VERSION` if `CHANGELOG.md` is updated

### Acceptance criteria

- The agent can fetch public web pages for read-only lookups.
- Fetches are audit-visible as `web.fetch`, not hidden in shell text.
- Fetch cannot read from or post local files.
- Fetch cannot reach loopback/private/link-local targets by default.
- `curl ... | bash` remains gated as an elevated action.

## P3: strengthen audit and evidence

### Current state

Audit logging is a good foundation. It records structured tool calls,
classifications, decisions, exit codes, durations, and stream hashes.

### Improvements

Add:

- policy rule id or pattern that determined classification;
- tool schema version;
- preview hash;
- working directory;
- effective user;
- whether sudo was present;
- parent conversation id and message id;
- bridge version and provider/model per turn.

For commands, record normalized argv separately from rendered shell
where possible. Avoid storing full stdout/stderr by default.

### Files to change

- `payload/agent/audit.py`
- `payload/agent/policy.py`
- `payload/agent/server.py`
- `payload/agent/runner.py`
- `payload/bin/audit-recent`
- tests under `tests/python`
- `docs/ARCHITECTURE.md`
- `SECURITY.md`

### Acceptance criteria

- An operator can answer "why was this classified this way?"
- Audit entries remain bounded and redacted.
- Existing audit readers tolerate new fields.

## Suggested implementation order

Implement in this order:

1. P0 bridge mediation.
2. P0 conservative shipped policy.
3. Tests that lock P0 behavior.
4. Docs alignment for P0.
5. Filesystem deny-list.
6. Action previews.
7. Privilege mode and Docker opt-in.
8. Integration VM tests.
9. UI improvements.
10. Network default changes.
11. Web fetch.
12. Audit evidence fields.

Do not combine all items in one large pull request. The first PR should
focus only on making the execution boundary true and tested.

## Definition of done for the first PR

The first PR should be considered complete when:

- pi cannot execute host tools outside Python mediation;
- `payload/etc/policy.yaml` is conservative by default;
- `make lint` passes;
- `make test` passes;
- tests fail if elevated actions auto-dispatch under the shipped policy;
- `docs/ARCHITECTURE.md`, `SECURITY.md`, and `docs/CONFIGURATION.md`
  match the implemented behavior;
- `CHANGELOG.md` records the user-visible safety change;
- `VERSION` is bumped if the changelog is updated, using:

```bash
date -u +%Y.%m.%d.%H.%M.%S > VERSION
```

