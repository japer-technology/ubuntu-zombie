#!/usr/bin/env bash
# tests/smoke.sh — non-root smoke tests for Ubuntu Zombie.
#
# Subcommands:
#   syntax        bash -n on every shell script we ship
#   python        py_compile on every Python file under payload/agent
#   subcommands   ensure scripts/install.sh recognises every documented subcommand
#   bad-usage     ensure scripts reject unexpected args and unsafe config
#   noninteractive verify ZOMBIE_NONINTERACTIVE=1 with missing required env
#                  exits with code 64
#   standards     ensure repository metadata and packaging inputs are present
#   all (default) run everything

set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-all}"

shell_files() {
  {
    git ls-files 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | while read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    case "$f" in
      *.sh)               printf '%s\n' "$f" ;;
      payload/bin/*)      printf '%s\n' "$f" ;;
    esac
  done | sort -u
}

run_syntax() {
  echo "[smoke] bash -n syntax check"
  shell_files | while read -r f; do
    head -n1 "$f" | grep -q '^#!.*bash' || continue
    echo "  bash -n $f"
    bash -n "$f"
  done
}

run_python() {
  echo "[smoke] python compile"
  find payload/agent -name '*.py' -print | while read -r f; do
    echo "  python3 -m py_compile $f"
    python3 -m py_compile "$f"
  done
  # Importability of policy.py without 3rd-party deps.
  echo "  import policy"
  PYTHONPATH=payload/agent python3 -c 'import policy; p = policy.load_policy(); print("classes:", list(p.classes))'
  echo "  policy payload regressions"
  PYTHONPATH=payload/agent ZOMBIE_POLICY=payload/etc/policy.yaml python3 - <<'PY'
import policy
import server

p = policy.load_policy()

# Policy classification regressions: read-only command heads must not
# auto-run when shell syntax would mutate files or execute interpreters.
cases = {
    "grep needle file > out": "user_change",
    "cat <<EOF > /tmp/out\nhello\nEOF": "user_change",
    "cat <<EOF\nhello\nEOF": "read_only",
    "cat script.sh | bash": "system_change",
    "cat data | sudo tee /etc/example": "system_change",
    "cat data | tee /dev/stderr": "read_only",
    "grep needle file 2>&1 >/dev/null": "read_only",
    "find /tmp -name x -delete": "destructive",
    # Phase 0 / P0.1 (UPGRADE-TO-PI-PLAN §3): argv-aware classifier
    # strips leading ``VAR=value`` env prefixes and ``sudo`` flags
    # before rule matching, so the canonical argv is what gets
    # classified.
    "LC_ALL=C ls /etc": "read_only",
    "FOO=bar apt-get install pkg": "system_change",
    "sudo apt install foo": "system_change",
    "sudo -u zombie ls /tmp": "read_only",
    "sudo -E systemctl restart sshd": "network_change",
    # Quoted destructive path is now caught because rules see the
    # de-quoted argv (the historical regex-only matcher missed it).
    'rm -rf "/tmp/some file"': "destructive",
    # Phase 0 / P0.2: unknown commands fall through to the
    # fail-closed default (``destructive``) instead of auto-running.
    "foozle --bar": "destructive",
    "sudo foozle --bar": "destructive",
    "echo a && echo b": "destructive",
}
for command, want in cases.items():
    got = p.classify(command)
    if got != want:
        raise SystemExit(f"classify({command!r}) = {got!r}, want {want!r}")

# Phase 0 / P0.3: sudo allow-list keeps common privileged targets at
# ``system_change`` rather than escalating them via the fail-closed
# default. ``foozle`` (not in the list) escalates; ``apt`` (in the
# list) does not.
assert "apt" in p.sudo_allow_list, p.sudo_allow_list
assert "foozle" not in p.sudo_allow_list, p.sudo_allow_list
if p.default_class != "destructive":
    raise SystemExit(f"fail-closed default class regressed: {p.default_class!r}")
# An unknown command must require operator approval (the canary that
# P0.2 calls for).
if not p.requires_approval(p.classify("foozle --bar")):
    raise SystemExit("fail-closed default no longer requires approval")

# Phase 2 (UPGRADE-TO-PI-PLAN §5): the legacy extract_commands /
# fenced-bash workflow has been removed; commands now arrive as
# structured pi-mono tool calls. The policy gate must classify them
# via classify_tool, and the closed registry must enforce schemas.
if hasattr(server, "extract_commands"):
    raise SystemExit("extract_commands must be removed in Phase 2")
import tools as _t
assert set(_t.tool_names()) == {
    "shell.run", "fs.read", "fs.write", "pkg.query", "pkg.install",
    "svc.status", "svc.control", "net.status", "gui.screenshot",
    "gui.click", "gui.type", "skill.list", "skill.load",
}, _t.tool_names()
# Per-tool default classifications come from the registry; shell.run
# is computed per-argv via the existing classify() path.
if p.classify_tool("fs.read", {"path": "/etc/os-release"}) != "read_only":
    raise SystemExit("fs.read should be read_only")
if p.classify_tool("pkg.install", {"names": ["curl"]}) != "system_change":
    raise SystemExit("pkg.install should be system_change")
if p.classify_tool("svc.control", {"unit": "ssh", "action": "restart"}) != "system_change":
    raise SystemExit("svc.control should be system_change")
if p.classify_tool("shell.run", {"argv": ["ls", "-la"]}) != "read_only":
    raise SystemExit("shell.run ls should be read_only via classify()")
if p.classify_tool("shell.run", {"command": "sudo apt-get install -y curl"}) != "system_change":
    raise SystemExit("shell.run sudo apt-get install should be system_change")
# Unknown tools fail closed.
if not p.requires_approval(p.classify_tool("totally.unknown", {})):
    raise SystemExit("unknown tool must require operator approval")
# Schema validation rejects bad args without side effects.
try:
    _t.validate_args("fs.read", {"path": 12})
    raise SystemExit("fs.read with int path must be rejected")
except _t.SchemaError:
    pass
try:
    _t.validate_args("svc.control", {"unit": "ssh", "action": "nuke"})
    raise SystemExit("svc.control with bad action must be rejected")
except _t.SchemaError:
    pass
# ``bool`` must not satisfy an ``integer`` field. Python treats ``bool``
# as a subclass of ``int``; without an explicit guard ``shell.run``
# would accept ``{"timeout": False}`` and ``subprocess`` would coerce
# it to ``timeout=0`` (instant TimeoutExpired).
try:
    _t.validate_args("shell.run", {"argv": ["true"], "timeout": False})
    raise SystemExit("shell.run timeout=False must be rejected as non-integer")
except _t.SchemaError:
    pass

# ``_skills_dirs`` must not silently add the chat service's working
# directory when ``ZOMBIE_SKILLS_DIR`` is unset or empty.
import os as _os
from pathlib import Path as _P
_saved = _os.environ.pop("ZOMBIE_SKILLS_DIR", None)
try:
    dirs = _t._skills_dirs()
    assert _P(".") not in dirs and _P("") not in dirs, dirs
    _os.environ["ZOMBIE_SKILLS_DIR"] = ""
    dirs = _t._skills_dirs()
    assert _P(".") not in dirs and _P("") not in dirs, dirs
    _os.environ["ZOMBIE_SKILLS_DIR"] = "/tmp/zombie-extra-skills"
    dirs = _t._skills_dirs()
    assert _P("/tmp/zombie-extra-skills") in dirs, dirs
finally:
    _os.environ.pop("ZOMBIE_SKILLS_DIR", None)
    if _saved is not None:
        _os.environ["ZOMBIE_SKILLS_DIR"] = _saved

# Phase 3 (UPGRADE-TO-PI-PLAN §6 / P3.1): skill loader discovers the
# six built-in skills, parses their trigger markers, selects only on
# trigger-word match in recent user messages, and renders a block that
# carries the on-disk path so the UI can show provenance.
import skill_loader
from pathlib import Path

skills = skill_loader.load_skills([Path("payload/agent/skills")])
names = {s.name for s in skills}
assert names == {"apt", "systemd", "tailscale", "ufw", "docker", "gui"}, names
for s in skills:
    assert s.triggers, f"skill {s.name} has no triggers"

# Trigger match on the last user turn only.
sel = skill_loader.select_skills(
    ["I want to talk about cats", "Can you check if docker is installed?"],
    dirs=[Path("payload/agent/skills")],
)
assert [s.name for s in sel] == ["docker"], [s.name for s in sel]

# No trigger words -> no skills selected.
sel = skill_loader.select_skills(
    ["What is the weather like?"],
    dirs=[Path("payload/agent/skills")],
)
assert sel == [], sel

# ``recent`` window excludes older messages.
sel = skill_loader.select_skills(
    ["restart the nginx systemd unit",
     "now check the firewall",
     "and one more thing",
     "tell me a joke"],
    recent=1,
    dirs=[Path("payload/agent/skills")],
)
assert sel == [], sel

# Rendered block carries provenance (the file path) so prompt
# injection via a skill remains visible (§6.4).
sel = skill_loader.select_skills(
    ["please run apt-get update"],
    dirs=[Path("payload/agent/skills")],
)
assert [s.name for s in sel] == ["apt"], [s.name for s in sel]
block = skill_loader.render_skills_block(sel)
assert "payload/agent/skills/apt.md" in block, block
assert "Active skill: apt" in block, block

# Empty selection -> empty block (no header noise on every turn).
assert skill_loader.render_skills_block([]) == ""

# Phase 1 (UPGRADE-TO-PI-PLAN §4): providers.py is a thin adapter
# over @earendil-works/pi-ai. The Python-facing surface must stay
# import-clean (no third-party deps) and provider selection must
# honour ZOMBIE_PROVIDER plus the expanded key matrix.
import os
import providers as _pr

assert set(_pr.SUPPORTED_PROVIDERS) == {
    "openai", "anthropic", "gemini", "xai", "openrouter", "mistral", "groq"
}, _pr.SUPPORTED_PROVIDERS

# Snapshot env so we can reset it cleanly.
_keys = (
    "ZOMBIE_PROVIDER", "ZOMBIE_MODEL",
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
    "XAI_API_KEY", "OPENROUTER_API_KEY", "MISTRAL_API_KEY", "GROQ_API_KEY",
)
_saved = {k: os.environ.pop(k, None) for k in _keys}
try:
    # No keys, no explicit provider -> NoProviderConfigured + helpful status.
    try:
        _pr.provider_from_env()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit("provider_from_env should raise without any key")
    name, status = _pr.provider_status()
    if name != "none":
        raise SystemExit(f"provider_status with no key returned {name!r}")

    # Unknown ZOMBIE_PROVIDER must fail loudly.
    os.environ["ZOMBIE_PROVIDER"] = "bogus"
    try:
        _pr.provider_from_env()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit("unknown ZOMBIE_PROVIDER should raise")
    del os.environ["ZOMBIE_PROVIDER"]

    # Autodetect picks the first provider whose key is set.
    os.environ["GROQ_API_KEY"] = "test"
    p_auto = _pr.provider_from_env()
    if p_auto.name != "groq":
        raise SystemExit(f"autodetect returned {p_auto.name!r}")
    if not p_auto.model:
        raise SystemExit("groq adapter should pick a default model")

    # Explicit ZOMBIE_PROVIDER wins over autodetect, but still needs
    # its own key.
    os.environ["ZOMBIE_PROVIDER"] = "gemini"
    try:
        _pr.provider_from_env()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit("missing GEMINI_API_KEY should raise")
    os.environ["GEMINI_API_KEY"] = "test"
    p_gem = _pr.provider_from_env()
    if p_gem.name != "gemini":
        raise SystemExit(f"explicit provider returned {p_gem.name!r}")

    # OpenRouter has no default model and must surface a clear error
    # when ZOMBIE_MODEL is not set.
    os.environ["ZOMBIE_PROVIDER"] = "openrouter"
    os.environ["OPENROUTER_API_KEY"] = "test"
    try:
        _pr.provider_from_env()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit("openrouter without ZOMBIE_MODEL should raise")
    os.environ["ZOMBIE_MODEL"] = "anthropic/claude-3.5-sonnet"
    p_or = _pr.provider_from_env()
    if p_or.model != "anthropic/claude-3.5-sonnet":
        raise SystemExit(f"openrouter model was {p_or.model!r}")
finally:
    for k, v in _saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
PY

  # Phase 2 (UPGRADE-TO-PI-PLAN §5 / P2.6): stubbed end-to-end run of
  # pi_mono.run_turn against tests/fixtures/stub-pi-mono.mjs. Verifies
  # the bridge protocol, schema validation, dispatch, and event
  # accounting without requiring `pi` (or even npm) on the test host.
  if command -v node >/dev/null 2>&1; then
    echo "  pi-mono stub end-to-end"
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/tests/fixtures/stub-pi-mono.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import json, os, sys
import pi_mono, tools, policy

p = policy.load_policy()
collected = []

def on_tool_call(call_id, name, args):
    collected.append((name, dict(args)))
    cls = p.classify_tool(name, args)
    if p.requires_approval(cls):
        return {"ok": False, "error": "operator_approval_required: " + cls}
    try:
        tools.validate_args(name, args)
    except tools.SchemaError as exc:
        return {"ok": False, "error": f"schema: {exc}"}
    # Don't actually dispatch fs.read inside the test sandbox; the
    # stub plan only exercises the protocol path. Return a stub
    # observation that mimics fs.read shape.
    return {"ok": True, "result": {"path": args.get("path"),
                                    "content": "STUBBED",
                                    "size": 7}}

out = pi_mono.run_turn(
    prompt="hello",
    system_prompt="you are stubbed",
    history=[],
    on_tool_call=on_tool_call,
    tool_names=tools.tool_names(),
)
if out["final"] != "stubbed pi-mono turn complete":
    raise SystemExit(f"unexpected final: {out['final']!r}")
if not collected or collected[0][0] != "fs.read":
    raise SystemExit(f"expected fs.read tool call, got {collected!r}")
if not any(e.get("type") == "tool_call" for e in out["events"]):
    raise SystemExit("no tool_call events recorded")
if not any(e.get("type") == "final" for e in out["events"]):
    raise SystemExit("no final event recorded")
PY
  else
    echo "  (skipping pi-mono stub end-to-end: node not on PATH)"
  fi
}

run_subcommands() {
  echo "[smoke] subcommand parsing"
  ./scripts/install.sh --help    >/dev/null
  ./scripts/install.sh --version >/dev/null
  # Each subcommand should at least parse and not bail with code 2 (bad usage).
  for sub in verify doctor; do
    set +e
    out="$(./scripts/install.sh "${sub}" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 2 ]]; then
      echo "FAIL: '${sub}' returned bad-usage (exit 2). Output:"
      echo "${out}"
      exit 1
    fi
  done
  # 'doctor' must run as a non-root user without erroring on argument parsing.
  ./scripts/install.sh doctor >/dev/null || true
}

expect_exit_code() {
  local want="$1"; shift
  set +e
  "$@" >/dev/null 2>&1
  local got=$?
  set -e
  if [[ "${got}" -ne "${want}" ]]; then
    echo "FAIL: expected exit ${want}, got ${got}: $*" >&2
    exit 1
  fi
}

run_bad_usage() {
  echo "[smoke] bad usage guards"
  # `install unexpected` used to live here but install requires root, so on
  # a non-root runner the assertion was satisfied by require_root rather
  # than by reject_unexpected_positional_args. `doctor unexpected`
  # exercises the same code path without needing root. See FIX-1-14.
  expect_exit_code 2 ./scripts/install.sh doctor unexpected
  expect_exit_code 2 ./scripts/install.sh verify unexpected
  expect_exit_code 2 ./scripts/install.sh repair unexpected
  # Duplicate subcommand tokens must be rejected too (FIX-1-15).
  expect_exit_code 2 ./scripts/install.sh doctor doctor
  expect_exit_code 2 ./scripts/install.sh install install
  expect_exit_code 2 env 'ZOMBIE_USER=bad user' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_USER=root' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_USER=bad-' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_USER=bad_' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_DIR=relative/path' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_DIR=/tmp/zombie;touch /tmp/install-path-pwn' ./scripts/install.sh doctor
  expect_exit_code 2 env 'LOG_FILE=relative.log' ./scripts/install.sh doctor
  expect_exit_code 2 env 'LOG_FILE=/tmp/zombie log' ./scripts/install.sh doctor
  expect_exit_code 2 env 'VNC_PORT=bad' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_CHAT_PORT=70000' ./scripts/install.sh doctor
  # FIX-2-01: uninstall.sh must validate ZOMBIE_USER / paths *before*
  # any side-effecting command runs (so a smoke run as non-root still
  # exits 2 rather than 1).
  expect_exit_code 2 env 'ZOMBIE_USER=zombie;touch /tmp/zombie-pwn' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'ZOMBIE_USER=root' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'ZOMBIE_DIR=relative/path' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'ZOMBIE_DIR=/tmp/zombie;touch /tmp/uninstall-path-pwn' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'BACKUP_DIR=relative/path' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'BACKUP_DIR=/tmp/zombie backup' ./scripts/uninstall.sh --dry-run
  expect_exit_code 2 env 'VNC_PORT=0' ./scripts/uninstall.sh --dry-run
  [[ ! -e /tmp/zombie-pwn ]] || { echo "FAIL: uninstall.sh ZOMBIE_USER injection created /tmp/zombie-pwn" >&2; exit 1; }
  [[ ! -e /tmp/install-path-pwn ]] || { echo "FAIL: install.sh ZOMBIE_DIR injection created /tmp/install-path-pwn" >&2; exit 1; }
  [[ ! -e /tmp/uninstall-path-pwn ]] || { echo "FAIL: uninstall.sh ZOMBIE_DIR injection created /tmp/uninstall-path-pwn" >&2; exit 1; }
  # FIX-2-11: uninstall.sh run() must refuse extra arguments.
  set +e
  out="$(bash -c '
    set -Eeuo pipefail
    DRY_RUN=0
    C_RED=""; C_RESET=""; C_YEL=""
    run() {
      if (( $# != 1 )); then
        echo "BADARGS" >&2
        exit 1
      fi
      echo "$1"
    }
    run "echo a" "echo b"
  ' 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]] || [[ "${out}" != *BADARGS* ]]; then
    echo "FAIL: run() guard did not refuse extra args" >&2
    exit 1
  fi
}

run_noninteractive() {
  echo "[smoke] non-interactive guard"
  # We cannot exercise the full install path without root, so we only
  # assert that the documented escape hatch is still advertised in
  # --help. The previous version of this test allocated a tmpdir and
  # probed `sudo -n true` but discarded both, so they have been removed
  # (FIX-1-13).
  ./scripts/install.sh --help | grep -q ZOMBIE_NONINTERACTIVE
}

run_standards() {
  echo "[smoke] repository standards"
  local required=(
    README.md
    LICENSE
    CODE_OF_CONDUCT.md
    SECURITY.md
    CONTRIBUTING.md
    CHANGELOG.md
    VERSION
    Makefile
    .editorconfig
    .github/CODEOWNERS
    .github/PULL_REQUEST_TEMPLATE.md
    .github/workflows/ci.yml
  )
  local f
  for f in "${required[@]}"; do
    [[ -s "$f" ]] || { echo "missing required repository file: $f" >&2; exit 1; }
  done

  # Phase 3 (UPGRADE-TO-PI-PLAN §6 / P3.1): the six built-in skills
  # ship under payload/agent/skills/ so ``make package`` carries them
  # into the release bundle and the installer can deploy them to
  # /opt/ai-zombie/skills/.
  local s
  for s in apt systemd tailscale ufw docker gui; do
    [[ -s "payload/agent/skills/${s}.md" ]] || \
      { echo "missing built-in skill: payload/agent/skills/${s}.md" >&2; exit 1; }
  done

  # Keep the release bundle source list honest without creating dist/.
  tar --exclude-vcs --exclude='dist' --exclude='__pycache__' \
      -czf /tmp/ubuntu-zombie-smoke-package.tar.gz \
      scripts payload tests Makefile VERSION \
      README.md CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
      LICENSE .editorconfig \
      SECURITY.md docs
  rm -f /tmp/ubuntu-zombie-smoke-package.tar.gz
}

case "${cmd}" in
  syntax)         run_syntax ;;
  python)         run_python ;;
  subcommands)    run_subcommands ;;
  bad-usage)      run_bad_usage ;;
  noninteractive) run_noninteractive ;;
  standards)      run_standards ;;
  all)
    run_syntax
    run_python
    run_subcommands
    run_bad_usage
    run_noninteractive
    run_standards
    echo "[smoke] all checks passed"
    ;;
  *) echo "unknown subcommand: ${cmd}" >&2; exit 2 ;;
esac
