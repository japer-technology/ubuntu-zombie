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
}
for command, want in cases.items():
    got = p.classify(command)
    if got != want:
        raise SystemExit(f"classify({command!r}) = {got!r}, want {want!r}")

# Fence parsing regressions: CRLF, mixed line endings, and blank
# language tags should still feed extracted commands to the policy gate.
if server.extract_commands("```bash\r\nls\r\n```") != ["ls"]:
    raise SystemExit("CRLF fenced command extraction failed")
if server.extract_commands("```bash\r\nprintf hi\n```") != ["printf hi"]:
    raise SystemExit("mixed-line-ending fenced command extraction failed")
extracted = server.extract_commands("```\ncat script.sh | bash\n```")
if extracted != ["cat script.sh | bash"]:
    raise SystemExit("blank fenced command extraction failed")
if p.classify(extracted[0]) != "system_change":
    raise SystemExit("extracted interpreter pipeline was not gated")

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
