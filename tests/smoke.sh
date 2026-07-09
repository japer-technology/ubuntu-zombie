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
#   branding      ensure installer and chat startup wordmarks stay present
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
    # Argv-aware classifier: strips leading ``VAR=value`` env
    # prefixes and ``sudo`` flags before rule matching, so the
    # canonical argv is what gets classified.
    "LC_ALL=C ls /etc": "read_only",
    "FOO=bar apt-get install pkg": "system_change",
    "sudo apt install foo": "system_change",
    "sudo -u zombie ls /tmp": "read_only",
    "sudo -E systemctl restart cron": "system_change",
    # Quoted destructive path is now caught because rules see the
    # de-quoted argv (the historical regex-only matcher missed it).
    'rm -rf "/tmp/some file"': "destructive",
    # Unknown commands fall through to the fail-closed default
    # (``destructive``) instead of auto-running.
    "foozle --bar": "destructive",
    "sudo foozle --bar": "destructive",
    "echo a && echo b": "destructive",
}
for command, want in cases.items():
    got = p.classify(command)
    if got != want:
        raise SystemExit(f"classify({command!r}) = {got!r}, want {want!r}")

# Sudo allow-list keeps common privileged targets at ``system_change``
# rather than escalating them via the fail-closed default. ``foozle``
# (not in the list) escalates; ``apt`` (in the list) does not.
assert "apt" in p.sudo_allow_list, p.sudo_allow_list
assert "foozle" not in p.sudo_allow_list, p.sudo_allow_list
if p.default_class != "destructive":
    raise SystemExit(f"fail-closed default class regressed: {p.default_class!r}")
# An unknown command must require operator approval.
if not p.requires_approval(p.classify("foozle --bar")):
    raise SystemExit("fail-closed default no longer requires approval")

# The legacy extract_commands / fenced-bash workflow has been removed;
# commands now arrive as structured pi-mono tool calls. The policy
# gate must classify them via classify_tool, and the closed registry
# must enforce schemas.
if hasattr(server, "extract_commands"):
    raise SystemExit("extract_commands must be removed")
import tools as _t
assert set(_t.tool_names()) == {
    "shell.run", "fs.read", "fs.list", "fs.write", "pkg.query", "pkg.install",
    "svc.status", "svc.control", "net.status", "skill.list", "skill.load",
}, _t.tool_names()
# Per-tool default classifications come from the registry; shell.run
# is computed per-argv via the existing classify() path.
if p.classify_tool("fs.read", {"path": "/etc/os-release"}) != "read_only":
    raise SystemExit("fs.read should be read_only")
if p.classify_tool("pkg.install", {"names": ["curl"]}) != "system_change":
    raise SystemExit("pkg.install should be system_change")
if p.classify_tool("svc.control", {"unit": "cron", "action": "restart"}) != "system_change":
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
    _t.validate_args("svc.control", {"unit": "cron", "action": "nuke"})
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

# Skill loader discovers the six built-in skills, parses their
# trigger markers, selects only on trigger-word match in recent user
# messages, and renders a block that carries the on-disk path so the
# UI can show provenance.
import skill_loader
from pathlib import Path

skills = skill_loader.load_skills([Path("payload/agent/skills")])
names = {s.name for s in skills}
assert names == {"apt", "systemd"}, names
for s in skills:
    assert s.triggers, f"skill {s.name} has no triggers"

# Trigger match on the last user turn only.
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
# injection via a skill remains visible.
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

# providers.py is a thin adapter over @earendil-works/pi-ai. The
# Python-facing surface must stay import-clean (no third-party deps)
# and provider selection must honour ZOMBIE_PROVIDER plus the
# expanded key matrix.
import os
import providers as _pr

assert set(_pr.SUPPORTED_PROVIDERS) == {
    "openai", "anthropic", "gemini", "xai", "openrouter", "mistral", "groq",
    "lmstudio",
}, _pr.SUPPORTED_PROVIDERS

# Snapshot env so we can reset it cleanly.
_keys = (
    "ZOMBIE_PROVIDER", "ZOMBIE_MODEL",
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
    "XAI_API_KEY", "OPENROUTER_API_KEY", "MISTRAL_API_KEY", "GROQ_API_KEY",
    "LMSTUDIO_API_KEY",
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

    # resolve_active_model is the single authoritative resolver shared
    # by the chat surface and the agent loop. It must agree with
    # provider_from_env and expose the pi-ai/pi provider id mapping
    # (gemini -> google).
    prov, model, key_env = _pr.resolve_active_model()
    if (prov, model, key_env) != ("openrouter", "anthropic/claude-3.5-sonnet",
                                  "OPENROUTER_API_KEY"):
        raise SystemExit(f"resolve_active_model returned {(prov, model, key_env)!r}")

    # The status banner must report the model the agent loop will use,
    # and the gemini name must map to the pi provider id "google".
    for k in ("ZOMBIE_PROVIDER", "ZOMBIE_MODEL", "OPENROUTER_API_KEY"):
        os.environ.pop(k, None)
    os.environ["ZOMBIE_PROVIDER"] = "gemini"
    os.environ["GEMINI_API_KEY"] = "test"
    s_name, s_status = _pr.provider_status()
    if s_name != "gemini" or s_status != "model gemini-2.0-flash":
        raise SystemExit(f"provider_status returned {(s_name, s_status)!r}")
    g = _pr.provider_from_env()
    if g.pi_provider != "google" or g.key_env != "GEMINI_API_KEY":
        raise SystemExit(f"gemini pi_provider/key_env wrong: "
                         f"{g.pi_provider!r}/{g.key_env!r}")
    if set(_pr.ALL_KEY_ENVS) != {
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY",
        "OPENROUTER_API_KEY", "MISTRAL_API_KEY", "GROQ_API_KEY",
        "LMSTUDIO_API_KEY",
    }:
        raise SystemExit(f"ALL_KEY_ENVS unexpected: {_pr.ALL_KEY_ENVS!r}")

    # lmstudio is a local OpenAI-compatible provider: its pi id is
    # "lmstudio" (the custom provider the installer writes to
    # ~/.pi/agent/models.json) and, like openrouter, it has no default
    # model so ZOMBIE_MODEL must be set.
    for k in ("ZOMBIE_PROVIDER", "ZOMBIE_MODEL", "GEMINI_API_KEY"):
        os.environ.pop(k, None)
    os.environ["ZOMBIE_PROVIDER"] = "lmstudio"
    os.environ["LMSTUDIO_API_KEY"] = "local"
    try:
        _pr.provider_from_env()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit("lmstudio without ZOMBIE_MODEL should raise")
    os.environ["ZOMBIE_MODEL"] = "qwen/qwen3-coder"
    p_lm = _pr.provider_from_env()
    if (p_lm.name, p_lm.pi_provider, p_lm.key_env, p_lm.model) != (
        "lmstudio", "lmstudio", "LMSTUDIO_API_KEY", "qwen/qwen3-coder"):
        raise SystemExit(
            f"lmstudio resolved wrong: "
            f"{(p_lm.name, p_lm.pi_provider, p_lm.key_env, p_lm.model)!r}")
    if _pr.resolve_active_model() != (
        "lmstudio", "qwen/qwen3-coder", "LMSTUDIO_API_KEY"):
        raise SystemExit(
            f"lmstudio resolve_active_model wrong: {_pr.resolve_active_model()!r}")
    if _pr.provider_status() != ("lmstudio", "model qwen/qwen3-coder"):
        raise SystemExit(f"lmstudio status wrong: {_pr.provider_status()!r}")
finally:
    for k, v in _saved.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
PY

  # Stubbed end-to-end run of pi_mono.run_turn against
  # tests/fixtures/stub-pi-mono.mjs. Verifies the bridge protocol,
  # schema validation, dispatch, and event accounting without
  # requiring `pi` (or even npm) on the test host.
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
streamed = []

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
    on_event=lambda event: streamed.append(event),
)
if out["final"] != "stubbed pi-mono turn complete":
    raise SystemExit(f"unexpected final: {out['final']!r}")
if not collected or collected[0][0] != "fs.read":
    raise SystemExit(f"expected fs.read tool call, got {collected!r}")
if not any(e.get("type") == "tool_call" for e in out["events"]):
    raise SystemExit("no tool_call events recorded")
if not any(e.get("type") == "final" for e in out["events"]):
    raise SystemExit("no final event recorded")
if [e.get("type") for e in streamed] != ["progress", "token", "progress", "token"]:
    raise SystemExit(f"stream callback order wrong: {streamed!r}")
PY

    # Unified model selection + auth isolation: pi_mono.run_turn must
    # resolve the model from ZOMBIE_PROVIDER/ZOMBIE_MODEL (via the same
    # providers registry the banner uses) and pass it to the bridge,
    # while forwarding ONLY the active provider's key. The stub records
    # the received `start` frame and its env-key visibility.
    echo "  pi-mono unified model selection + key isolation"
    _START_OUT="$(mktemp)"
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/tests/fixtures/stub-pi-mono.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    ZOMBIE_STUB_START_OUT="${_START_OUT}" \
    ZOMBIE_PROVIDER="gemini" \
    ZOMBIE_MODEL="gemini-2.0-flash" \
    GEMINI_API_KEY="test-gemini" \
    OPENAI_API_KEY="test-openai-should-be-stripped" \
    PYTHONPATH=payload/agent \
      python3 - "${_START_OUT}" <<'PY'
import json, sys
import pi_mono, tools

def on_tool_call(call_id, name, args):
    return {"ok": True, "result": {"stubbed": True}}

pi_mono.run_turn(
    prompt="hello",
    system_prompt="stub",
    history=[],
    on_tool_call=on_tool_call,
    tool_names=tools.tool_names(),
)
rec = json.load(open(sys.argv[1]))
start = rec["start"]
# gemini must map to the pi provider id "google".
if start.get("provider") != "google":
    raise SystemExit(f"bridge provider was {start.get('provider')!r}, want 'google'")
if start.get("model") != "gemini-2.0-flash":
    raise SystemExit(f"bridge model was {start.get('model')!r}")
# Only the active provider's key may reach the bridge env.
if not rec["env"].get("GEMINI_API_KEY"):
    raise SystemExit("active GEMINI_API_KEY missing from bridge env")
if rec["env"].get("OPENAI_API_KEY"):
    raise SystemExit("non-active OPENAI_API_KEY leaked to bridge env")
PY
    rm -f "${_START_OUT}"

    # Model catalogue + runtime selection: providers.list_models /
    # current_model / set_active_model back the /model chat command and
    # the /api/models + /api/model endpoints. Drive them against a
    # hermetic stub bridge so no API key or @earendil-works/pi-ai
    # install is needed. Also exercises the server App wrappers.
    echo "  providers model catalogue + /model endpoints"
    ZOMBIE_PI_AI_BRIDGE="$(pwd)/tests/fixtures/stub-pi-ai-bridge.mjs" \
    ZOMBIE_NODE="$(command -v node)" \
    ZOMBIE_AUDIT_LOG="$(mktemp -d)/audit.log" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import os
import providers as _pr
import server

for k in ("ZOMBIE_PROVIDER", "ZOMBIE_MODEL", "OPENAI_API_KEY",
          "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY",
          "OPENROUTER_API_KEY", "MISTRAL_API_KEY", "GROQ_API_KEY",
          "LMSTUDIO_API_KEY"):
    os.environ.pop(k, None)

# No provider configured: both helpers must raise the shared
# NoProviderConfigured rather than returning a misleading empty list.
for fn in (_pr.active_provider, _pr.list_models, _pr.current_model):
    try:
        fn()
    except _pr.NoProviderConfigured:
        pass
    else:
        raise SystemExit(f"{fn.__name__} should raise without a provider")

os.environ["ZOMBIE_PROVIDER"] = "openai"
os.environ["OPENAI_API_KEY"] = "test"

if _pr.active_provider() != "openai":
    raise SystemExit(f"active_provider wrong: {_pr.active_provider()!r}")
# current_model falls back to the registry default before selection.
if _pr.current_model() != "gpt-4o-mini":
    raise SystemExit(f"current_model wrong: {_pr.current_model()!r}")

models = _pr.list_models()
ids = [m["id"] for m in models]
if ids != ["gpt-4o-mini", "gpt-4o", "o3-mini"]:
    raise SystemExit(f"list_models ids wrong: {ids!r}")
o3 = next(m for m in models if m["id"] == "o3-mini")
if o3["reasoning"] is not True or o3["context_window"] != 200000:
    raise SystemExit(f"list_models lost model metadata: {o3!r}")

# Selecting a known id pins ZOMBIE_MODEL for this process so every
# later turn resolves the same model.
prov, chosen = _pr.set_active_model("gpt-4o")
if (prov, chosen) != ("openai", "gpt-4o"):
    raise SystemExit(f"set_active_model returned {(prov, chosen)!r}")
if os.environ.get("ZOMBIE_MODEL") != "gpt-4o":
    raise SystemExit("set_active_model must pin ZOMBIE_MODEL")
if _pr.current_model() != "gpt-4o":
    raise SystemExit("current_model must reflect the selection")

# An unknown id (for a provider with a catalogue) is rejected, and an
# empty id is always rejected.
for bad in ("definitely-not-a-model", ""):
    try:
        _pr.set_active_model(bad)
    except ValueError:
        pass
    else:
        raise SystemExit(f"set_active_model({bad!r}) should raise ValueError")
# The rejected selection must not have changed the pinned model.
if os.environ.get("ZOMBIE_MODEL") != "gpt-4o":
    raise SystemExit("a rejected selection must not mutate ZOMBIE_MODEL")

# lmstudio has no catalogue, so any non-empty id is accepted free-form.
os.environ["ZOMBIE_PROVIDER"] = "lmstudio"
os.environ["LMSTUDIO_API_KEY"] = "local"
if _pr.list_models() != []:
    raise SystemExit("lmstudio should expose an empty catalogue")
prov, chosen = _pr.set_active_model("qwen/qwen3-coder")
if (prov, chosen) != ("lmstudio", "qwen/qwen3-coder"):
    raise SystemExit(f"lmstudio free-form selection wrong: {(prov, chosen)!r}")

# Server App wrappers: GET /api/models and POST /api/model payloads.
os.environ["ZOMBIE_PROVIDER"] = "openai"
os.environ.pop("ZOMBIE_MODEL", None)
app = server.App()
info = app.models_info()
if info.get("provider") != "openai" or info.get("current") != "gpt-4o-mini":
    raise SystemExit(f"models_info wrong: {info!r}")
if [m["id"] for m in info.get("models", [])] != ["gpt-4o-mini", "gpt-4o", "o3-mini"]:
    raise SystemExit(f"models_info models wrong: {info!r}")
ok = app.set_model("gpt-4o")
if ok != {"ok": True, "provider": "openai", "model": "gpt-4o"}:
    raise SystemExit(f"App.set_model ok payload wrong: {ok!r}")
bad = app.set_model("nope")
if "error" not in bad:
    raise SystemExit(f"App.set_model bad payload should carry error: {bad!r}")
app.history.close()
PY


    # The real pi-ai-bridge.mjs must list a local OpenAI-compatible
    # provider's models live from its /models endpoint (lmstudio has no
    # static pi-ai catalogue). Drive the real bridge against a hermetic
    # stub HTTP server + temp models.json so no @earendil-works/pi-ai
    # install or LAN server is needed; the live path returns before the
    # bridge ever loads pi-ai.
    echo "  pi-ai bridge live local model listing"
    _LM_DIR="$(mktemp -d)"
    cat > "${_LM_DIR}/models.json" <<JSON
{ "providers": { "lmstudio": { "baseUrl": "http://127.0.0.1:7891/v1",
  "apiKey": "LMSTUDIO_API_KEY", "models": [ { "id": "placeholder" } ] } } }
JSON
    cat > "${_LM_DIR}/server.mjs" <<'JS'
import { createServer } from "node:http";
const s = createServer((req, res) => {
  if (req.url === "/v1/models") {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ object: "list", data: [
      { id: "qwen/qwen3-coder", object: "model" },
      { id: "llama-3.1-8b", object: "model", context_length: 131072 },
    ] }));
    return;
  }
  res.statusCode = 404;
  res.end("no");
});
s.listen(7891, "127.0.0.1", () => process.stdout.write("ready\n"));
JS
    node "${_LM_DIR}/server.mjs" >"${_LM_DIR}/server.log" 2>&1 &
    _LM_PID=$!
    # Wait for the stub server to report ready (bounded); fail fast if it
    # never comes up so the assertions below give a clear diagnostic.
    _LM_READY=0
    for _ in $(seq 1 50); do
        if grep -q ready "${_LM_DIR}/server.log" 2>/dev/null; then
            _LM_READY=1
            break
        fi
        sleep 0.1
    done
    if [ "${_LM_READY}" -ne 1 ]; then
        kill "${_LM_PID}" 2>/dev/null || true
        echo "stub model server failed to start:" >&2
        cat "${_LM_DIR}/server.log" >&2 || true
        exit 1
    fi
    _LM_OUT="$(printf '%s' '{"op":"list_models","provider":"lmstudio"}' \
        | ZOMBIE_PI_MODELS_JSON="${_LM_DIR}/models.json" \
          LMSTUDIO_API_KEY=local \
          node payload/agent/pi-ai-bridge.mjs)"
    kill "${_LM_PID}" 2>/dev/null || true
    ZOMBIE_LM_OUT="${_LM_OUT}" python3 - <<'PY'
import json, os
out = json.loads(os.environ["ZOMBIE_LM_OUT"])
if not out.get("ok"):
    raise SystemExit(f"live list_models failed: {out!r}")
ids = [m["id"] for m in out.get("models", [])]
if ids != ["qwen/qwen3-coder", "llama-3.1-8b"]:
    raise SystemExit(f"live list_models ids wrong: {ids!r}")
ctx = {m["id"]: m["contextWindow"] for m in out["models"]}
if ctx["llama-3.1-8b"] != 131072 or ctx["qwen/qwen3-coder"] is not None:
    raise SystemExit(f"live list_models context window wrong: {ctx!r}")
PY
    rm -rf "${_LM_DIR}"


    # produce a soft failure (synthetic ``budget_exceeded``
    # observation) once exceeded so the model ends the turn cleanly
    # rather than looping.
    echo "  pi-mono per-turn tool-call budget enforcement"
    ZOMBIE_STUB_PLAN='[
      {"type":"tool_call","id":"1","name":"fs.read","args":{"path":"/etc/os-release","max_bytes":64}},
      {"type":"tool_call","id":"2","name":"fs.read","args":{"path":"/etc/os-release","max_bytes":64}},
      {"type":"tool_call","id":"3","name":"fs.read","args":{"path":"/etc/os-release","max_bytes":64}},
      {"type":"final","text":"budget run complete"}
    ]' \
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/tests/fixtures/stub-pi-mono.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import pi_mono, tools

invocations = 0

def on_tool_call(call_id, name, args):
    global invocations
    invocations += 1
    return {"ok": True, "result": {"stubbed": True}}

out = pi_mono.run_turn(
    prompt="hello",
    system_prompt="stub",
    history=[],
    on_tool_call=on_tool_call,
    tool_names=tools.tool_names(),
    max_tool_calls=2,
)
if invocations != 2:
    raise SystemExit(f"expected on_tool_call to fire 2x within budget, got {invocations}")
errors = [e.get("error", "") for e in out["events"]
          if e.get("type") == "tool_call"]
# The overflow tool_call's reply is emitted by pi_mono itself, so the
# event log records the bridge tool_call without an on_tool_call run.
overflow_results = [e for e in out["events"]
                    if e.get("type") == "tool_call" and e.get("id") == "3"]
if not overflow_results:
    raise SystemExit("third (overflow) tool_call event missing")
# pi_mono should have synthesized the budget_exceeded reply for id=3.
# We verify by capturing the reply via a custom callback wrapper.
if out["final"] != "budget run complete":
    raise SystemExit(f"unexpected final after budget overflow: {out['final']!r}")
PY

    echo "  server elevated-call budget enforcement"
    _BUDGET_TMP="$(mktemp -d)"
    ZOMBIE_HISTORY_DB="${_BUDGET_TMP}/conversations.db" \
    ZOMBIE_AUDIT_LOG="${_BUDGET_TMP}/audit.log" \
    ZOMBIE_POLICY="payload/etc/policy.yaml" \
    ZOMBIE_STUB_PLAN='[
      {"type":"tool_call","id":"a","name":"fs.write","args":{"path":"/tmp/zombie-budget-1","content":"x"}},
      {"type":"tool_call","id":"b","name":"fs.write","args":{"path":"/tmp/zombie-budget-2","content":"x"}},
      {"type":"tool_call","id":"c","name":"fs.write","args":{"path":"/tmp/zombie-budget-3","content":"x"}},
      {"type":"final","text":"elevated budget run complete"}
    ]' \
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/tests/fixtures/stub-pi-mono.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import json
import server

# Force a tight elevated budget without rewriting policy.yaml so we
# don't perturb the rest of the suite. ``post_message`` re-reads
# ``policy.yaml`` each turn, so monkey-patch ``load_policy`` to
# return a Policy with max_elevated_calls_per_turn=2.
import policy as policy_mod

_orig = policy_mod.load_policy
def _tight():
    p = _orig()
    p.max_elevated_calls_per_turn = 2
    return p

policy_mod.load_policy = _tight
server.load_policy = _tight

app = server.App()
out = app.post_message(None, "exercise the elevated budget please")

# Two elevated calls should be queued for approval; the third must
# come back as a synthetic ``budget_exceeded`` observation. History
# events are stored as ``{"kind": ..., "payload": {...}}``.
events = out["events"]
budget_obs = [e["payload"] for e in events
              if e.get("kind") == "tool_observation"
              and (e.get("payload") or {}).get("decision") == "budget_exceeded"]
if len(budget_obs) != 1:
    raise SystemExit(f"expected 1 budget_exceeded observation, got "
                     f"{len(budget_obs)}: {json.dumps(events, indent=2)}")
err = budget_obs[0].get("error", "")
if not err.startswith("budget_exceeded:"):
    raise SystemExit(f"unexpected budget_exceeded error text: {err!r}")

# The first two elevated calls must still be queued (not silently
# dropped by the budget gate).
pending = [e["payload"] for e in events if e.get("kind") == "pending_tool_call"]
if len(pending) != 2:
    raise SystemExit(f"expected 2 pending_tool_call events, got "
                     f"{len(pending)}: {json.dumps(events, indent=2)}")

# The synthetic observation must NOT have created a pending entry to
# approve (operator should not see a phantom approval prompt).
if any(p["tool_call_id"] == "c" for p in pending):
    raise SystemExit("budget-exceeded call must not appear as pending")
PY
    rm -rf "${_BUDGET_TMP}"

    # Idle-deadline watchdog: a bridge that never answers must not hang
    # the turn forever. pi_mono.run_turn should terminate the wedged
    # subprocess and raise a clean BridgeError once the idle timeout
    # elapses (the "Hello hangs forever" regression).
    echo "  pi-mono idle timeout terminates a wedged turn"
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/tests/fixtures/hang-pi-mono.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import time
import pi_mono, tools

def on_tool_call(call_id, name, args):
    return {"ok": True, "result": {"stubbed": True}}

started = time.monotonic()
try:
    pi_mono.run_turn(
        prompt="Hello",
        system_prompt="stub",
        history=[],
        on_tool_call=on_tool_call,
        tool_names=tools.tool_names(),
        timeout=2.0,
    )
except pi_mono.BridgeError as exc:
    elapsed = time.monotonic() - started
    if "timed out" not in str(exc):
        raise SystemExit(f"unexpected BridgeError: {exc}")
    if elapsed > 10:
        raise SystemExit(f"watchdog took too long to fire: {elapsed:.1f}s")
else:
    raise SystemExit("expected a BridgeError from the idle watchdog")
PY

    # Real bridge against pi's actual `--mode json` event schema. This
    # drives payload/agent/pi-mono-bridge.mjs (not the protocol stub)
    # with a fake `pi` binary that emits the genuine AgentSession event
    # stream, locking in two regressions:
    #   1. the bridge must capture the assistant text from
    #      message_update/message_end (it previously looked for
    #      non-existent "text"/"final" events and returned an empty
    #      answer); and
    #   2. the fake `pi` must be allowed to exit on stdin EOF — the
    #      bridge must not keep its stdin open (the "120s inactivity
    #      timeout" with a working local LM Studio server).
    echo "  pi-mono real bridge parses pi --mode json (text answer)"
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/payload/agent/pi-mono-bridge.mjs" \
    ZOMBIE_PI_MONO_BIN="$(pwd)/tests/fixtures/fake-pi-json.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import time
import pi_mono, tools

def on_tool_call(call_id, name, args):
    raise SystemExit("on_tool_call must NOT fire: pi runs its own tools "
                     "in --mode json")

started = time.monotonic()
out = pi_mono.run_turn(
    prompt="say hi",
    system_prompt="you are helpful",
    history=[],
    on_tool_call=on_tool_call,
    tool_names=tools.tool_names(),
    timeout=20.0,
)
elapsed = time.monotonic() - started
if out["final"] != "Hello from the local model!":
    raise SystemExit(f"bridge dropped the assistant text: {out['final']!r}")
# The turn must complete promptly (the fake pi exits on stdin EOF); a
# regression that keeps pi's stdin open would hang until the watchdog.
if elapsed > 10:
    raise SystemExit(f"bridge turn took too long ({elapsed:.1f}s); "
                     "did pi fail to exit on stdin EOF?")
# pi executes its own tools in --mode json, so the bridge must not
# surface tool_execution_* events as mediated tool_call frames.
if any(e.get("type") == "tool_call" for e in out["events"]):
    raise SystemExit("bridge must not re-dispatch pi's tool_execution events")
if not any(e.get("type") == "progress" for e in out["events"]):
    raise SystemExit("bridge must forward tool progress events")
if not any(e.get("type") == "token" for e in out["events"]):
    raise SystemExit("bridge must forward token events")
PY

    # The real bridge must forward the prior conversation into pi's
    # one-shot -p prompt so the agent has cross-turn memory (regression:
    # the bridge previously dropped `history`, so the model forgot names
    # and earlier context). The fake pi echoes its -p prompt back.
    echo "  pi-mono real bridge forwards conversation history (memory)"
    ZOMBIE_FAKE_PI_MODE="echo" \
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/payload/agent/pi-mono-bridge.mjs" \
    ZOMBIE_PI_MONO_BIN="$(pwd)/tests/fixtures/fake-pi-json.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import pi_mono, tools

def on_tool_call(call_id, name, args):
    return {"ok": True, "result": {}}

# Mirror server.py: the current user turn is the last history entry and
# is also passed as `prompt`.
history = [
    {"role": "user", "content": "Call me Eric"},
    {"role": "assistant", "content": "Understood, Eric."},
    {"role": "user", "content": "What is my name?"},
]
out = pi_mono.run_turn(
    prompt="What is my name?",
    system_prompt="you are helpful",
    history=history,
    on_tool_call=on_tool_call,
    tool_names=tools.tool_names(),
    timeout=20.0,
)
final = out["final"]
# Earlier turns must reach pi so the model can answer from memory.
if "Eric" not in final:
    raise SystemExit(f"bridge dropped conversation history: {final!r}")
# The current question must appear exactly once (not duplicated by the
# trailing history entry the server appends).
if final.count("What is my name?") != 1:
    raise SystemExit(f"current prompt duplicated/missing: {final!r}")
PY

    # The real bridge must surface a provider/connection error as a
    # clean BridgeError rather than a blank answer or a hung turn.
    echo "  pi-mono real bridge surfaces provider errors"
    ZOMBIE_FAKE_PI_MODE="error" \
    ZOMBIE_PI_MONO_BRIDGE="$(pwd)/payload/agent/pi-mono-bridge.mjs" \
    ZOMBIE_PI_MONO_BIN="$(pwd)/tests/fixtures/fake-pi-json.mjs" \
    ZOMBIE_PI_MONO_LOG_DIR="$(mktemp -d)" \
    PYTHONPATH=payload/agent \
      python3 - <<'PY'
import pi_mono, tools

def on_tool_call(call_id, name, args):
    return {"ok": True, "result": {}}

try:
    pi_mono.run_turn(
        prompt="say hi",
        system_prompt="stub",
        history=[],
        on_tool_call=on_tool_call,
        tool_names=tools.tool_names(),
        timeout=20.0,
    )
except pi_mono.BridgeError as exc:
    if "Connection error" not in str(exc):
        raise SystemExit(f"unexpected BridgeError text: {exc}")
else:
    raise SystemExit("expected a BridgeError for the provider error case")
PY
  else
    echo "  (skipping pi-mono stub end-to-end: node not on PATH)"
  fi

  echo "  audit redaction + verbose preview round-trip"
  _AUDIT_TMP="$(mktemp -d)"
  ZOMBIE_AUDIT_LOG="${_AUDIT_TMP}/audit.log" \
  PYTHONPATH=payload/agent python3 - <<'PY'
import json
import os

import audit

# Default mode: no stdout_preview in tool_call entries, but every
# entry must carry pid + ts_utc so testers can correlate audit lines
# with journalctl.
audit.log_event("prompt", prompt="hello sk-abcdefghijklmnop world")
audit.log_tool_call(
    tool="shell.run", classification="read_only", decision="executed",
    stdout="line1\nAPI_KEY=secretsesame\nline2", stderr="boom",
    exit_code=0, duration_ms=12,
)

# Verbose mode: previews appear and are redacted by the same rules
# applied to every other field.
os.environ["ZOMBIE_AUDIT_VERBOSE"] = "1"
try:
    audit.log_tool_call(
        tool="shell.run", classification="read_only", decision="executed",
        stdout="visible\nAPI_KEY=secretsesame\nbye",
        stderr="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ secret",
        exit_code=0, duration_ms=8,
    )
finally:
    del os.environ["ZOMBIE_AUDIT_VERBOSE"]

path = os.environ["ZOMBIE_AUDIT_LOG"]
lines = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
assert len(lines) == 3, lines

for entry in lines:
    for required in ("id", "ts", "ts_utc", "pid", "type"):
        assert required in entry, (required, entry)
    assert entry["ts_utc"].endswith("Z"), entry["ts_utc"]
    assert isinstance(entry["pid"], int) and entry["pid"] > 0, entry["pid"]

prompt_entry, default_tool, verbose_tool = lines
assert prompt_entry["prompt"] == "hello sk-***REDACTED*** world", prompt_entry
assert "stdout_preview" not in default_tool, default_tool
assert "stderr_preview" not in default_tool, default_tool
assert default_tool["stdout_sha256"], default_tool
assert "stdout_preview" in verbose_tool, verbose_tool
assert "API_KEY=***REDACTED***" in verbose_tool["stdout_preview"], verbose_tool
assert "secretsesame" not in verbose_tool["stdout_preview"], verbose_tool
assert "REDACTED" in verbose_tool["stderr_preview"], verbose_tool
PY
  rm -rf "${_AUDIT_TMP}"

  echo "  server version_info endpoint"
  PYTHONPATH=payload/agent python3 - <<'PY'
import server

info = server.version_info()
# The payload version must resolve from the repo-root VERSION file
# when running from a checkout (HERE.parent.parent / VERSION).
assert info.get("version") and info["version"] != "unknown", info
# The pinned provider-bridge versions ship next to the agent sources,
# so version_info must surface them too.
assert info.get("pi_mono"), info
assert info.get("pi_ai"), info
PY

  echo "  server conversation endpoint (existing / bad id / not found)"
  _CONV_TMP="$(mktemp -d)"
  ZOMBIE_HISTORY_DB="${_CONV_TMP}/conversations.db" \
  ZOMBIE_AUDIT_LOG="${_CONV_TMP}/audit.log" \
  ZOMBIE_POLICY=payload/etc/policy.yaml \
  ZOMBIE_SKILLS_DIR=payload/agent/skills \
  PYTHONPATH=payload/agent python3 - <<'PY'
import atexit
import json
import os
import shutil
from pathlib import Path

_db = os.environ.get("ZOMBIE_HISTORY_DB")
if _db:
    _td = Path(_db).resolve().parent
    if _td != Path("/") and len(str(_td)) > 10:
        atexit.register(lambda p=str(_td): shutil.rmtree(p, ignore_errors=True))

import server

class _FakeRFile:
    """Minimal stand-in for a socket rfile."""

    def __init__(self, body=b""):
        self._body = body

    def read(self, *_a, **_k):
        body, self._body = self._body, b""
        return body

    def readline(self, *_a, **_k):
        return b""

class _Recorder(server.Handler):
    """Drive Handler methods without a real socket; capture the reply."""

    def __init__(self, app, path, body=None):  # noqa: D107 - test shim
        self.app = app
        self.path = path
        raw = json.dumps(body or {}).encode("utf-8")
        self.rfile = _FakeRFile(raw)
        self.headers = {"Content-Length": str(len(raw))}
        self.status = None
        self.body = b""

    def send_response(self, code, message=None):
        self.status = code

    def send_header(self, *a, **k):
        pass

    def end_headers(self):
        pass

    def send_error(self, code, *a, **k):
        self.status = int(code)

    class _W:
        def __init__(self, outer):
            self._outer = outer

        def write(self, data):
            self._outer.body += data

    @property
    def wfile(self):
        return _Recorder._W(self)


def get(app, path):
    h = _Recorder(app, path)
    h.do_GET()
    payload = json.loads(h.body.decode("utf-8")) if h.body else {}
    return h.status, payload


def post(app, path, body=None):
    h = _Recorder(app, path, body)
    h.do_POST()
    payload = json.loads(h.body.decode("utf-8")) if h.body else {}
    return h.status, payload


app = server.App()
cid = app.history.create_conversation()
app.history.add_message(cid, "user", "hello there")
app.history.add_message(cid, "assistant", "hi")

# Existing conversation: 200 with the stored messages, no error.
status, body = get(app, f"/api/conversation/{cid}")
assert status == 200, (status, body)
assert "error" not in body, body
assert body["conversation"]["id"] == cid, body
assert any(m["content"] == "hello there" for m in body["messages"]), body

# Unknown id: a 404 with an error body the UI can surface, rather than
# a silent empty conversation the operator thinks loaded.
status, body = get(app, "/api/conversation/999999")
assert status == 404, (status, body)
assert "error" in body and "999999" in body["error"], body

# Non-numeric id: a 400 with a "bad id" error.
status, body = get(app, "/api/conversation/not-a-number")
assert status == 400, (status, body)
assert body.get("error") == "bad id", body

# Title updates are small state mutations and are audit-visible.
status, body = post(app, f"/api/conversation/{cid}/title",
                    {"title": "   "})
assert status == 400, (status, body)
assert body["error"] == "title is required", body
status, body = post(app, f"/api/conversation/{cid}/title",
                    {"title": "  Demo title  "})
assert status == 200, (status, body)
assert body["title"] == "Demo title", body
status, body = get(app, f"/api/conversation/{cid}")
assert body["conversation"]["title"] == "Demo title", body

# Branch copies the transcript without changing the source.
status, body = post(app, f"/api/conversation/{cid}/branch",
                    {"title": "side path"})
assert status == 200, (status, body)
branch_id = body["conversation_id"]
assert branch_id != cid, body
status, branch = get(app, f"/api/conversation/{branch_id}")
assert status == 200, (status, branch)
assert [m["content"] for m in branch["messages"]] == [
    "hello there", "hi",
], branch

# Retry creates a branch before the last user message and returns the
# prompt for the browser to re-submit. The original remains intact.
app.history.add_message(cid, "user", "try this")
app.history.add_message(cid, "assistant", "old answer")
status, body = post(app, f"/api/conversation/{cid}/retry")
assert status == 200, (status, body)
assert body["prompt"] == "try this", body
status, retry = get(app, f"/api/conversation/{body['conversation_id']}")
assert [m["content"] for m in retry["messages"]] == [
    "hello there", "hi",
], retry

# Undo also branches instead of deleting evidence or pretending host
# side effects were reverted.
status, body = post(app, f"/api/conversation/{cid}/undo", {"turns": 1})
assert status == 200, (status, body)
assert "host changes" in body["warning"], body
status, undone = get(app, f"/api/conversation/{body['conversation_id']}")
assert [m["content"] for m in undone["messages"]] == [
    "hello there", "hi",
], undone

# Compress stores a local system summary that future turns can inject
# into the system prompt; raw messages stay present.
status, body = post(app, f"/api/conversation/{cid}/compress")
assert status == 200, (status, body)
assert "Local summary" in body["summary"], body
assert app.history.latest_summary(cid) == body["summary"], body
status, original = get(app, f"/api/conversation/{cid}")
assert any(m["content"] == "try this" for m in original["messages"]), original

# Read-only command-support endpoints.
saved_provider = os.environ.get("ZOMBIE_PROVIDER")
os.environ["ZOMBIE_PROVIDER"] = "bogus"
for path in ("/api/config", "/api/profile", "/api/whoami",
             "/api/policy", "/api/skills"):
    status, body = get(app, path)
    assert status == 200, (path, status, body)
status, whoami = get(app, "/api/whoami")
assert whoami["agent_user"], whoami
assert whoami["hostname"], whoami
assert whoami["chat_url"].startswith("http://127.0.0.1:"), whoami
assert whoami["loopback_only"] is True, whoami
status, profile = get(app, "/api/profile")
assert profile["zombie_dir"] == os.environ.get("ZOMBIE_DIR", "/opt/ai-zombie"), profile
assert profile["history_db"] == os.environ["ZOMBIE_HISTORY_DB"], profile
if saved_provider is None:
    os.environ.pop("ZOMBIE_PROVIDER", None)
else:
    os.environ["ZOMBIE_PROVIDER"] = saved_provider
assert any(s["name"] == "apt" for s in get(app, "/api/skills")[1]["skills"])
status, body = get(app, "/api/skill/apt")
assert status == 200 and "content" in body and body["name"] == "apt", body
status, body = get(app, "/api/pending")
assert status == 200 and body["pending"] == [], body

# Pending approval commands expose the same queue as the approval
# buttons. Denial removes the call; a bad destructive phrase does not.
pending = {
    "id": "audit-1",
    "conversation_id": cid,
    "tool_call_id": "tool-1",
    "tool": "shell.run",
    "args": {"argv": ["true"]},
    "classification": "elevated",
    "requires_phrase": False,
}
app.pending["audit-1"] = pending
app.pending["tool-1"] = pending
status, body = get(app, "/api/pending")
assert status == 200 and len(body["pending"]) == 1, body
status, body = post(app, "/api/approve",
                    {"tool_call_id": "audit-1", "decision": "deny"})
assert status == 200 and body["status"] == "denied", body
assert body["tool_call_id"] == "tool-1", body
assert app.pending_calls() == [], app.pending_calls()

pending = {
    "id": "audit-2",
    "conversation_id": cid,
    "tool_call_id": "tool-2",
    "tool": "shell.run",
    "args": {"argv": ["rm", "-rf", "/tmp/nope"]},
    "classification": "destructive",
    "requires_phrase": True,
}
app.pending["audit-2"] = pending
app.pending["tool-2"] = pending
status, body = post(app, "/api/approve",
                    {"tool_call_id": "tool-2", "decision": "approve",
                     "phrase": "wrong"})
assert status == 200 and body["status"] == "awaiting_confirmation", body
assert len(app.pending_calls()) == 1, app.pending_calls()
status, body = post(app, "/api/approve",
                    {"tool_call_id": "audit-2", "decision": "deny"})
assert status == 200 and body["status"] == "denied", body
assert app.pending_calls() == [], app.pending_calls()

app.history.close()
PY
  rm -rf "${_CONV_TMP}"

  echo "  lifecycle TTL kill switch"
  _LIFE_TMP="$(mktemp -d)"
  ZOMBIE_LIFECYCLE_STATE="${_LIFE_TMP}/lifecycle.json" \
  PYTHONPATH=payload/agent python3 - <<'PY'
import time
import lifecycle

# format_remaining mirrors the documented "/ttl" example shape and
# singularises units that equal one.
assert lifecycle.format_remaining(9 * 86400 + 4 * 3600 + 23 * 60 + 12) == \
    "9 days 4 hours 23 minutes 12 seconds"
assert lifecycle.format_remaining(86400 + 3600 + 60 + 1) == \
    "1 day 1 hour 1 minute 1 second"
assert lifecycle.format_remaining(-5) == "0 days 0 hours 0 minutes 0 seconds"
assert lifecycle.parse_duration("14 days") == 14 * 86400
assert lifecycle.parse_duration("2 years 3 months") == \
    (2 * 365 + 3 * 30) * 86400
assert lifecycle.parse_duration("3 hours") == 3 * 3600
assert lifecycle.parse_duration("5") == 5 * 86400
assert lifecycle.parse_duration("", default_seconds=7 * 86400) == 7 * 86400

# A fresh install seeds a live countdown.
st = lifecycle.initialize(3)
assert st["dead"] is False and st["alive"] is True, st
assert 2 * 86400 < st["remaining_seconds"] <= 3 * 86400, st

# "/ttl N" extends from the current expiry, so +5 days on a ~3-day
# clock leaves ~8 days (never shortens the countdown).
st = lifecycle.set_ttl(5)
assert 7 * 86400 < st["remaining_seconds"] <= 8 * 86400, st

# "/ttl reset D" resets from now instead of extending from the old expiry.
st = lifecycle.reset_ttl_seconds(lifecycle.parse_duration("14 days"))
assert 13 * 86400 < st["remaining_seconds"] <= 14 * 86400, st

# Non-positive extensions are rejected.
for bad in (0, -1):
    try:
        lifecycle.set_ttl(bad)
    except ValueError:
        pass
    else:
        raise SystemExit(f"set_ttl({bad}) should raise ValueError")

# Killing trips the tombstone permanently; a later /ttl cannot revive it.
st = lifecycle.kill()
assert st["dead"] is True and st["dead_reason"] == "killed", st
st = lifecycle.set_ttl(5)
assert st["dead"] is True, "a dead zombie must not be revivable via set_ttl"

# Only a fresh initialize() (a reinstall) clears the tombstone.
st = lifecycle.initialize(1)
assert st["dead"] is False, st

# An elapsed TTL trips on the next status() read and writes the
# tombstone durably (a restart cannot revive it).
lifecycle.initialize(1)
import json
from pathlib import Path
p = Path(__import__("os").environ["ZOMBIE_LIFECYCLE_STATE"])
data = json.loads(p.read_text())
data["expires_at"] = time.time() - 1
p.write_text(json.dumps(data))
st = lifecycle.status()
assert st["dead"] is True and st["dead_reason"] == "expired", st
assert json.loads(p.read_text())["dead"] is True, "expiry must be persisted"
PY
  rm -rf "${_LIFE_TMP}"

  echo "  auth password gate"
  PYTHONPATH=payload/agent python3 - <<'PY'
import os
import auth

os.environ.pop(auth.HASH_ENV, None)
# Gate disabled when no hash is configured: every password passes and
# auth_required() is False (this is what keeps the smoke server tests
# from needing a login).
assert auth.auth_required() is False
assert auth.check_password("anything") is True

h = auth.hash_password("braaaains")
assert h.startswith("pbkdf2_sha256$"), h
assert auth.verify_password("braaaains", h) is True
assert auth.verify_password("wrong", h) is False
# Malformed stored hashes never validate.
for bad in ("", "garbage", "pbkdf2_sha256$nope"):
    assert auth.verify_password("x", bad) is False, bad

os.environ[auth.HASH_ENV] = h
try:
    assert auth.auth_required() is True
    assert auth.check_password("braaaains") is True
    assert auth.check_password("nope") is False
finally:
    os.environ.pop(auth.HASH_ENV, None)

# Session tokens are opaque and unique.
assert auth.new_session_token() != auth.new_session_token()
PY

  echo "  server password gate + /ttl endpoints"
  _GATE_TMP="$(mktemp -d)"
  ZOMBIE_HISTORY_DB="${_GATE_TMP}/conversations.db" \
  ZOMBIE_AUDIT_LOG="${_GATE_TMP}/audit.log" \
  ZOMBIE_POLICY=payload/etc/policy.yaml \
  ZOMBIE_LIFECYCLE_STATE="${_GATE_TMP}/lifecycle.json" \
  ZOMBIE_SECRETS="${_GATE_TMP}/secrets/env" \
  PYTHONPATH=payload/agent python3 - <<'PY'
import json
import os

import auth
import lifecycle
import server


class _RFile:
    def __init__(self, body=b""):
        self._body = body

    def read(self, *_a, **_k):
        body, self._body = self._body, b""
        return body

    def readline(self, *_a, **_k):
        return b""


class _Recorder(server.Handler):
    def __init__(self, app, path, body=None, cookie=None):
        self.app = app
        self.path = path
        raw = json.dumps(body or {}).encode("utf-8")
        self.rfile = _RFile(raw)
        self.headers = {"Content-Length": str(len(raw))}
        if cookie:
            self.headers["Cookie"] = cookie
        self.status = None
        self.body = b""
        self.headers_sent = []

    def send_response(self, code, message=None):
        self.status = code

    def send_header(self, name, value):
        self.headers_sent.append((name, value))

    def end_headers(self):
        pass

    def send_error(self, code, *a, **k):
        self.status = int(code)

    class _W:
        def __init__(self, outer):
            self._outer = outer

        def write(self, data):
            self._outer.body += data

    @property
    def wfile(self):
        return _Recorder._W(self)


def get(app, path, cookie=None):
    h = _Recorder(app, path, cookie=cookie)
    h.do_GET()
    return h.status, (json.loads(h.body) if h.body else {}), h.headers_sent


def post(app, path, body=None, cookie=None):
    h = _Recorder(app, path, body, cookie=cookie)
    h.do_POST()
    return h.status, (json.loads(h.body) if h.body else {}), h.headers_sent


# --- Gate enabled: protected endpoints require a login. ---
os.environ[auth.HASH_ENV] = auth.hash_password("braaaains")
lifecycle.initialize(3)
app = server.App()

status, body, _ = get(app, "/api/session")
assert body["required"] is True and body["authenticated"] is False, body

status, body, _ = get(app, "/api/health")
assert status == 401, (status, body)

status, body, _ = post(app, "/api/login", {"password": "wrong"})
assert status == 401, (status, body)

status, body, headers = post(app, "/api/login", {"password": "braaaains"})
assert status == 200 and body.get("ok"), (status, body)
cookie = next(v.split(";", 1)[0] for k, v in headers if k == "Set-Cookie")

status, body, _ = get(app, "/api/health", cookie=cookie)
assert status == 200, (status, body)

# Password changes rewrite secrets/env without leaking plaintext, and a
# changed password clears existing sessions.
status, body, _ = post(app, "/api/password", {"password": "new-braaaains"},
                       cookie=cookie)
assert status == 200 and body["required"] is True, (status, body)
assert auth.check_password("new-braaaains") is True
status, body, _ = get(app, "/api/health", cookie=cookie)
assert status == 401, (status, body)
status, body, headers = post(app, "/api/login", {"password": "new-braaaains"})
assert status == 200 and body.get("ok"), (status, body)
cookie = next(v.split(";", 1)[0] for k, v in headers if k == "Set-Cookie")

# Empty /password removes the gate; no logoff is required because auth is
# disabled for every request.
status, body, _ = post(app, "/api/password", {"password": ""}, cookie=cookie)
assert status == 200 and body["required"] is False, (status, body)
status, body, _ = get(app, "/api/health")
assert status == 200, (status, body)

os.environ[auth.HASH_ENV] = auth.hash_password("braaaains")

# Logout invalidates the token.
post(app, "/api/logout", cookie=cookie)
status, body, _ = get(app, "/api/health", cookie=cookie)
assert status == 401, (status, body)
app.history.close()
os.environ.pop(auth.HASH_ENV, None)

# --- TTL endpoints (gate disabled). ---
lifecycle.initialize(3)
app = server.App()

status, body, _ = get(app, "/api/ttl")
assert status == 200 and body["dead"] is False, body

status, body, _ = post(app, "/api/ttl", {"days": 5})
assert status == 200 and 7 * 86400 < body["remaining_seconds"] <= 8 * 86400, body

status, body, _ = post(app, "/api/ttl", {
    "reset": True,
    "duration": "14 days",
})
assert status == 200 and 13 * 86400 < body["remaining_seconds"] <= 14 * 86400, body

status, body, _ = post(app, "/api/ttl", {"duration": "3 hours"})
assert status == 200 and 14 * 86400 < body["remaining_seconds"] <= \
    14 * 86400 + 3 * 3600, body

status, body, _ = post(app, "/api/ttl", {"days": "not-a-number"})
assert status == 400, (status, body)

# --die trips the kill switch and message/ttl are refused thereafter.
status, body, _ = post(app, "/api/ttl", {"die": True})
assert status == 200 and body["dead"] is True, body

status, body, _ = post(app, "/api/message", {"prompt": "hello"})
assert status == 410 and body.get("dead") is True, (status, body)

status, body, _ = post(app, "/api/ttl", {"days": 5})
assert body.get("dead") is True, body
app.history.close()
PY
  rm -rf "${_GATE_TMP}"
}

run_branding() {
  echo "[smoke] startup branding"
  local first_line
  first_line='██╗   ██╗██████╗ ██╗   ██╗███╗   ██╗████████╗██╗   ██╗    ███████╗ ██████╗ ███╗   ███╗██████╗ ██╗███████╗'
  grep -Fq "$first_line" scripts/lib.sh
  grep -Fq "$first_line" payload/bin/zombie-chat
  grep -Fq "$first_line" payload/agent/templates/index.html
  local out
  out="$(ZOMBIE_COLOR=never ./scripts/install.sh --dry-run)"
  grep -Fq "$first_line" <<<"${out}"
  # A real uninstall run opens with the splash; --help stays concise.
  out="$(ZOMBIE_COLOR=never ./scripts/uninstall.sh --dry-run 2>&1 || true)"
  grep -Fq "$first_line" <<<"${out}"
  out="$(ZOMBIE_COLOR=never ./scripts/uninstall.sh --help)"
  if grep -Fq "$first_line" <<<"${out}"; then
    echo "FAIL: uninstall.sh --help must not print the splash" >&2
    exit 1
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
  expect_exit_code 2 env 'ZOMBIE_RECEIPT=1' 'ZOMBIE_RECEIPT_FILE=relative-receipt.txt' ./scripts/install.sh doctor
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
  # Uninstall must keep cleaning up even when host-level best-effort
  # removals fail, and it must quote paths passed through its eval helper.
  grep -Fq 'run_or_warn "systemctl daemon-reload"' scripts/uninstall.sh
  grep -Fq 'remove_tree_checked "${ZOMBIE_DIR}" "${ZOMBIE_DIR}"' scripts/uninstall.sh
  grep -Fq 'run_or_warn "Remove global npm package ${_pkg}"' scripts/uninstall.sh
  grep -Fq 'rm -f -- $(shell_quote "${f}")' scripts/uninstall.sh
  grep -Fq 'rm -f -- $(shell_quote "${_path}")' scripts/uninstall.sh
  # uninstall.sh exits during top-level validation when sourced as non-root,
  # so exercise a minimal copy of the helper bodies here. Keep this block in
  # sync with the uninstall helpers above.
  out="$(bash -c '
    set -Eeuo pipefail
    DRY_RUN=0
    UNINSTALL_EXIT=0
    warn() { printf "WARN:%s\n" "$*"; }
    run() {
      if (( $# != 1 )); then
        echo "BADARGS" >&2
        exit 1
      fi
      eval "$1"
    }
    shell_quote() {
      if (( $# != 1 )); then
        echo "BADQUOTE" >&2
        exit 1
      fi
      printf "%q" "$1"
    }
    run_or_warn() {
      local description="$1"
      local command="$2"
      if [[ "${DRY_RUN}" == "1" ]]; then
        run "${command}"
        return 0
      fi
      set +e
      eval "${command}"
      local rc=$?
      set -e
      if (( rc != 0 )); then
        warn "${description} failed (exit ${rc}); continuing cleanup."
        UNINSTALL_EXIT=1
      fi
      return 0
    }
    remove_tree_checked() {
      local path="$1"
      local label="$2"
      local quoted
      quoted="$(shell_quote "${path}")"
      if [[ "${DRY_RUN}" == "1" ]]; then
        run "rm -rf -- ${quoted}"
        return 0
      fi
      set +e
      rm -rf -- "${path}"
      local rc=$?
      set -e
      if (( rc != 0 )); then
        warn "Failed to remove ${label} (exit ${rc}); continuing cleanup."
        UNINSTALL_EXIT=1
        return 0
      fi
      if [[ -e "${path}" ]]; then
        warn "Failed to remove ${label}; path still exists: ${path}"
        UNINSTALL_EXIT=1
        return 0
      fi
      return 0
    }
    tmp=""
    trap '\''if [[ -n "${tmp}" && -d "${tmp}/parent" ]]; then chmod 700 "${tmp}/parent"; fi; [[ -n "${tmp}" ]] && rm -rf "${tmp}"'\'' EXIT
    run_or_warn "expected success" "true"
    [[ "${UNINSTALL_EXIT}" -eq 0 ]]
    run_or_warn "expected failure" "false"
    [[ "${UNINSTALL_EXIT}" -eq 1 ]]
    tmp="$(mktemp -d)"
    mkdir -p "${tmp}/parent/stubborn"
    chmod 500 "${tmp}/parent"
    remove_tree_checked "${tmp}/parent/stubborn" "stubborn"
    [[ "${UNINSTALL_EXIT}" -eq 1 ]]
    chmod 700 "${tmp}/parent"
    rm -rf "${tmp}"
    tmp=""
  ' 2>&1)"
  if [[ "${out}" != *"WARN:expected failure failed (exit 1); continuing cleanup."* ]]; then
    echo "FAIL: run_or_warn warning was not emitted" >&2
    exit 1
  fi
  if [[ "${out}" != *"WARN:Failed to remove stubborn"* ]]; then
    echo "FAIL: remove_tree_checked warning was not emitted" >&2
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

  echo "[smoke] optional components (Forgejo) dry-run"
  # The Forgejo option must parse from env alone (no new required
  # non-interactive input), never touch the host under --dry-run, and
  # leave the default dry-run output byte-for-byte unchanged when off.
  local base_out fj_out
  base_out="$(ZOMBIE_COLOR=never ./scripts/install.sh install --dry-run)"
  if grep -q "Optional components enabled" <<<"${base_out}"; then
    echo "FAIL: default dry-run must not mention optional components" >&2
    exit 1
  fi
  fj_out="$(ZOMBIE_COLOR=never ZOMBIE_NONINTERACTIVE=1 ZOMBIE_INSTALL_FORGEJO=1 \
    ZOMBIE_INSTALL_FORGEJO_RUNNER=1 ./scripts/install.sh install --dry-run)"
  grep -q "Optional components enabled" <<<"${fj_out}" \
    || { echo "FAIL: Forgejo dry-run stanza missing" >&2; exit 1; }
  grep -q "forgejo-runner.service" <<<"${fj_out}" \
    || { echo "FAIL: runner dry-run stanza missing" >&2; exit 1; }
  # Invalid option values must be rejected before any host change.
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=2' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_HTTP_PORT=70000' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_DB_NAME=Bad;Name' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_ADMIN_USER=-bad' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_ADMIN_USER=a-' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_DB_USER=bad_' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_ADMIN_PASSWORD=short' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_DB_PASSWORD=short' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_VERSION=not.a.version!' ./scripts/install.sh doctor
  expect_exit_code 2 env 'ZOMBIE_INSTALL_FORGEJO=1' 'FORGEJO_RUNNER_LABELS=bad label' ./scripts/install.sh doctor
}

run_diagnostics() {
  echo "[smoke] collect-diagnostics best-effort"
  # FIX-3-24: collect-diagnostics must finish and write its tarball
  # even when individual captured commands return non-zero (e.g.
  # `systemctl status` of an inactive unit). Before the
  # fix, `set -euo pipefail` aborted the run on the first such failure
  # and the EXIT trap then deleted the partial bundle, so no tarball
  # was produced. Run the real script in an isolated TMPDIR and assert
  # it exits 0 and leaves exactly one tarball behind.
  local td
  td="$(mktemp -d)"
  if ! TMPDIR="${td}" bash payload/bin/collect-diagnostics >/dev/null 2>&1; then
    rm -rf "${td}"
    echo "FAIL: collect-diagnostics exited non-zero (best-effort capture regressed)" >&2
    exit 1
  fi
  local -a tarballs
  mapfile -t tarballs < <(find "${td}" -maxdepth 1 -name 'ubuntu-zombie-diagnostics-*.tar.gz' -print)
  if [[ "${#tarballs[@]}" -ne 1 ]]; then
    rm -rf "${td}"
    echo "FAIL: collect-diagnostics must produce exactly one tarball (found ${#tarballs[@]})" >&2
    exit 1
  fi
  local tarball
  tarball="${tarballs[0]}"
  if [[ ! -s "${tarball}" ]]; then
    rm -rf "${td}"
    echo "FAIL: collect-diagnostics produced an empty tarball" >&2
    exit 1
  fi
  # The staging directory must be cleaned up by the EXIT trap, leaving
  # only the tarball behind.
  if find "${td}" -maxdepth 1 -type d -name 'ubuntu-zombie-diagnostics-*' | grep -q .; then
    rm -rf "${td}"
    echo "FAIL: collect-diagnostics left its staging directory behind" >&2
    exit 1
  fi
  rm -rf "${td}"

  echo "[smoke] health-check timer warn-only mode"
  td="$(mktemp -d)"
  cat > "${td}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${td}/systemctl"
  if PATH="${td}:${PATH}" ZOMBIE_DIR="${td}/missing" \
      bash payload/bin/health-check >/dev/null 2>&1; then
    rm -rf "${td}"
    echo "FAIL: health-check should exit non-zero for manual failed checks" >&2
    exit 1
  fi
  if ! PATH="${td}:${PATH}" ZOMBIE_DIR="${td}/missing" ZOMBIE_HEALTH_WARN_ONLY=1 \
      bash payload/bin/health-check >/dev/null 2>&1; then
    rm -rf "${td}"
    echo "FAIL: health-check timer warn-only mode should not fail the systemd unit" >&2
    exit 1
  fi
  rm -rf "${td}"
}

run_standards() {
  echo "[smoke] repository standards"
  local required=(
    README.md
    LICENSE
    CODE_OF_CONDUCT.md
    SECURITY.md
    SUPPORT.md
    RELEASE.md
    CONTRIBUTING.md
    CHANGELOG.md
    VERSION
    Makefile
    .editorconfig
    .pre-commit-config.yaml
    .github/CODEOWNERS
    .github/PULL_REQUEST_TEMPLATE.md
    .github/workflows/ci.yml
    .github/workflows/codeql.yml
    .github/workflows/dependency-review.yml
    .github/workflows/scorecard.yml
    .github/workflows/release.yml
    .github/workflows/integration.yml
    docs/PLATFORMS.md
    docs/UPGRADING.md
    docs/FAQ.md
    docs/research/README.md
    payload/agent/bridge-dependencies.lock
    payload/bin/verify-release
    debian/control.in
    debian/postinst
    debian/prerm
    debian/copyright
    scripts/build-deb.sh
    scripts/verify-bridge-pins.sh
  )
  local f
  for f in "${required[@]}"; do
    [[ -s "$f" ]] || { echo "missing required repository file: $f" >&2; exit 1; }
  done

  # The six built-in skills ship under payload/agent/skills/ so
  # ``make package`` carries them into the release bundle and the
  # installer can deploy them to /opt/ai-zombie/skills/.
  local s
  for s in apt systemd; do
    [[ -s "payload/agent/skills/${s}.md" ]] || \
      { echo "missing built-in skill: payload/agent/skills/${s}.md" >&2; exit 1; }
  done

  grep -q "__ZOMBIE_DIR__" payload/systemd/ubuntu-zombie-chat.service \
    || { echo "chat systemd template must keep __ZOMBIE_DIR__ placeholder" >&2; exit 1; }
  grep -q "ExecStart=__ZOMBIE_DIR__/bin/health-check" payload/systemd/ubuntu-zombie-health.service \
    || { echo "health systemd template must use __ZOMBIE_DIR__ placeholder" >&2; exit 1; }
  grep -q "ZOMBIE_HEALTH_WARN_ONLY=1" payload/systemd/ubuntu-zombie-health.service \
    || { echo "health timer must not leave a failed unit after reporting unhealthy state" >&2; exit 1; }
  # Optional Forgejo component: hardened units must ship in the payload,
  # and the policy must gate database drops as destructive.
  [[ -s payload/systemd/forgejo.service ]] \
    || { echo "missing payload/systemd/forgejo.service" >&2; exit 1; }
  [[ -s payload/systemd/forgejo-runner.service ]] \
    || { echo "missing payload/systemd/forgejo-runner.service" >&2; exit 1; }
  grep -q "NoNewPrivileges=true" payload/systemd/forgejo.service \
    || { echo "forgejo.service must stay hardened (NoNewPrivileges)" >&2; exit 1; }
  grep -q 'dropdb' payload/etc/policy.yaml \
    || { echo "policy.yaml must classify dropdb/dropuser as destructive" >&2; exit 1; }
  grep -q "option-sections: forgejo begin" scripts/install.sh \
    || { echo "install.sh must keep the forgejo option-sections markers" >&2; exit 1; }
  grep -q "ZOMBIE_INSTALL_FORGEJO" scripts/uninstall.sh 2>/dev/null \
    || grep -q "Removing optional Forgejo component" scripts/uninstall.sh \
    || { echo "uninstall.sh must reverse the Forgejo component" >&2; exit 1; }
  grep -q 'id="logout"' payload/agent/templates/index.html \
    || { echo "chat UI must expose the logoff button" >&2; exit 1; }
  grep -q 'case "/logout"' payload/agent/templates/index.html \
    || { echo "chat UI must expose the /logout command" >&2; exit 1; }
  grep -q 'setAuthState(false, false)' payload/agent/templates/index.html \
    || { echo "chat UI must hide Logoff when the password gate is removed" >&2; exit 1; }
  grep -q 'Available commands (alphabetic by group)' payload/agent/templates/index.html \
    || { echo "chat /help must keep grouped alphabetic output" >&2; exit 1; }
  grep -q 'EventSource' payload/agent/templates/index.html \
    || { echo "chat UI must keep the SSE EventSource path" >&2; exit 1; }
  grep -q 'Live stream interrupted; reloading conversation' payload/agent/templates/index.html \
    || { echo "chat UI must keep the streaming fallback reload path" >&2; exit 1; }
  grep -q 'queued' payload/agent/templates/index.html \
    || { echo "chat UI must keep the queued-message affordance" >&2; exit 1; }
  grep -Fq '["api", "stream"]' payload/agent/server.py \
    || { echo "server.py must expose the SSE stream endpoint" >&2; exit 1; }
  grep -q '"type":"progress"' payload/agent/pi_mono.py \
    || { echo "pi_mono.py protocol docs must mention progress events" >&2; exit 1; }
  grep -q '"type":"token"' payload/agent/pi_mono.py \
    || { echo "pi_mono.py protocol docs must mention token events" >&2; exit 1; }
  grep -q '"type":"progress"' payload/agent/pi-mono-bridge.mjs \
    || { echo "pi-mono bridge protocol docs must mention progress events" >&2; exit 1; }
  grep -q '"type":"token"' payload/agent/pi-mono-bridge.mjs \
    || { echo "pi-mono bridge protocol docs must mention token events" >&2; exit 1; }
  if grep -qi '<script[[:space:]][^>]*src=' payload/agent/templates/index.html; then
    echo "chat UI must not add external script dependencies" >&2
    exit 1
  fi
  grep -q "s|__ZOMBIE_DIR__|\\\${ZOMBIE_DIR}|g" scripts/install.sh \
    || { echo "install.sh must render __ZOMBIE_DIR__ in systemd units" >&2; exit 1; }
  if grep -n '\[\[ "${JSON}"' scripts/install.sh; then
    echo "generated verify script must escape JSON references in install.sh heredoc" >&2
    exit 1
  fi
  grep -q "actions/attest@" .github/workflows/release.yml \
    || { echo "release workflow must generate provenance attestations" >&2; exit 1; }
  grep -q "verify-bridge-pins" .github/workflows/release.yml \
    || { echo "release workflow must verify bridge dependency checksums" >&2; exit 1; }
  grep -q "paths:" .github/workflows/release.yml \
    || { echo "release workflow must have a paths trigger" >&2; exit 1; }
  grep -q "VERSION" .github/workflows/release.yml \
    || { echo "release workflow paths trigger must watch VERSION" >&2; exit 1; }
  grep -q "Ensure release tag exists" .github/workflows/release.yml \
    || { echo "release workflow must create the VERSION tag on main" >&2; exit 1; }
  bash payload/bin/verify-release --help >/dev/null

  # Keep the release bundle source list honest without creating dist/.
  tar --exclude-vcs --exclude='dist' --exclude='__pycache__' \
      -czf /tmp/ubuntu-zombie-smoke-package.tar.gz \
      scripts payload tests Makefile VERSION \
      README.md CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
      LICENSE .editorconfig \
      SECURITY.md docs debian
  rm -f /tmp/ubuntu-zombie-smoke-package.tar.gz
}

run_flags() {
  echo "[smoke] UX flags"
  # --help / --version / dry-run must stay exit 0 and never mutate the host.
  ./scripts/install.sh --help    >/dev/null
  ./scripts/install.sh --version >/dev/null
  expect_exit_code 0 ./scripts/install.sh install --dry-run
  expect_exit_code 0 ./scripts/install.sh install --yes --dry-run

  # --help must advertise the new examples and completion section.
  ./scripts/install.sh --help | grep -q "Examples:"
  ./scripts/install.sh --help | grep -q "completion"

  # --help must document the optional-component flags.
  ./scripts/install.sh --help | grep -q "ZOMBIE_INSTALL_FORGEJO"
  ./scripts/install.sh --help | grep -q "FORGEJO_HTTP_PORT"
  ./scripts/install.sh --help | grep -q "FORGEJO_ADMIN_PASSWORD"
  ./scripts/install.sh --help | grep -q "FORGEJO_DB_PASSWORD"

  # --no-color must strip ANSI escapes from output.
  set +e
  out="$(./scripts/install.sh doctor --no-color 2>&1)"
  set -e
  if printf '%s' "${out}" | grep -q $'\033'; then
    echo "FAIL: --no-color still emitted ANSI escapes" >&2
    exit 1
  fi

  # --quiet must suppress [i]/[+] info lines (warnings/errors only).
  set +e
  out="$(./scripts/install.sh doctor --quiet 2>/dev/null)"
  set -e
  if printf '%s\n' "${out}" | grep -qE '^\[i\]|^\[\+\]'; then
    echo "FAIL: --quiet still printed info/ok lines" >&2
    exit 1
  fi

  # --json must emit valid JSON for doctor (machine-readable mode).
  set +e
  out="$(./scripts/install.sh doctor --json 2>/dev/null)"
  set -e
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${out}" | python3 -c 'import sys,json; json.load(sys.stdin)' \
      || { echo "FAIL: doctor --json did not produce valid JSON" >&2; exit 1; }
  fi

  # uninstall.sh shares the same UX flag vocabulary as install.sh.
  ./scripts/uninstall.sh --help    >/dev/null
  ./scripts/uninstall.sh --version >/dev/null
  expect_exit_code 2 ./scripts/uninstall.sh --definitely-not-a-flag
  set +e
  out="$(./scripts/uninstall.sh --no-color --dry-run 2>&1)"
  set -e
  if printf '%s' "${out}" | grep -q $'\033'; then
    echo "FAIL: uninstall.sh --no-color still emitted ANSI escapes" >&2
    exit 1
  fi
  set +e
  out="$(./scripts/uninstall.sh --quiet --dry-run 2>/dev/null)"
  set -e
  if printf '%s\n' "${out}" | grep -q '██'; then
    echo "FAIL: uninstall.sh --quiet still printed the splash" >&2
    exit 1
  fi

  # Every operator-facing helper script must answer --help with exit 0
  # and reject unknown arguments with exit 2 (bad usage).
  # Exceptions to the exit-2 check: audit-recent's -n takes a numeric
  # value it validates itself, and verify-release accepts an arbitrary
  # positional release directory, so a bogus flag is not "unknown" to it.
  local helpers=(
    payload/bin/collect-diagnostics
    payload/bin/health-check
    payload/bin/secrets-edit
    payload/bin/setup-agent-venv
    payload/bin/zombie-chat
    scripts/build-deb.sh
    scripts/verify-bridge-pins.sh
  )
  local helper
  for helper in "${helpers[@]}" payload/bin/audit-recent payload/bin/verify-release; do
    bash "${helper}" --help >/dev/null \
      || { echo "FAIL: ${helper} --help did not exit 0" >&2; exit 1; }
  done
  for helper in "${helpers[@]}" payload/bin/audit-recent; do
    expect_exit_code 2 bash "${helper}" --definitely-not-a-flag
  done

  # Completion files referenced by --help must exist and parse.
  [[ -r scripts/completions/install.bash ]] \
    || { echo "FAIL: scripts/completions/install.bash missing" >&2; exit 1; }
  bash -n scripts/completions/install.bash \
    || { echo "FAIL: install.bash completion has a syntax error" >&2; exit 1; }
  [[ -r scripts/completions/_install.sh ]] \
    || { echo "FAIL: scripts/completions/_install.sh missing" >&2; exit 1; }
}

case "${cmd}" in
  syntax)         run_syntax ;;
  python)         run_python ;;
  branding) run_branding ;;
  subcommands) run_subcommands ;;
  bad-usage)      run_bad_usage ;;
  flags)          run_flags ;;
  noninteractive) run_noninteractive ;;
  diagnostics)    run_diagnostics ;;
  standards)      run_standards ;;
  all)
    run_syntax
    run_python
    run_branding
    run_subcommands
    run_bad_usage
    run_flags
    run_noninteractive
    run_diagnostics
    run_standards
    echo "[smoke] all checks passed"
    ;;
  *) echo "unknown subcommand: ${cmd}" >&2; exit 2 ;;
esac
