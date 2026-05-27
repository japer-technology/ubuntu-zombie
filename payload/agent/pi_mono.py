"""Python client for the ``pi-mono`` bridge.

Phase 2 of ``docs/UPGRADE-TO-PI-PLAN.md`` replaces the fenced-bash
parser with the ``pi`` agent loop (``@earendil-works/pi-coding-agent``).
``pi`` runs as a Node subprocess wrapped by ``pi-mono-bridge.mjs`` and
speaks a small line-delimited JSON protocol over stdio so the Python
server can mediate every tool call through the closed registry in
``tools.py``.

Protocol (Python ↔ bridge, one JSON object per line):

* ``{"type":"start", "prompt": str, "system": str, "history": [...],
     "tools": [...], "settings_path": str, "log_path": str,
     "max_tool_calls": int}`` — Python → bridge
* ``{"type":"tool_call", "id": str, "name": str, "args": {...}}`` —
  bridge → Python (one or more)
* ``{"type":"tool_result", "id": str, "ok": bool, "result"|"error":
     ...}`` — Python → bridge
* ``{"type":"final", "text": str}`` — bridge → Python (terminates)
* ``{"type":"error", "message": str}`` — bridge → Python (terminates)

The bridge handles the actual ``pi --mode rpc`` (or ``--mode json``)
plumbing, including ``--no-builtin-tools`` and ``--tools <names>``
flags, system-prompt rendering, and per-turn session management.

For development and CI, ``ZOMBIE_PI_MONO_BRIDGE`` may point at any
executable that speaks this protocol — including the stub script
``tests/fixtures/stub-pi-mono.mjs`` used by ``smoke.sh``.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable

HERE = Path(__file__).resolve().parent

DEFAULT_BRIDGE = HERE / "pi-mono-bridge.mjs"
DEFAULT_LOG_DIR = Path(os.environ.get(
    "ZOMBIE_PI_MONO_LOG_DIR", "/opt/ai-zombie/state/logs"))
DEFAULT_SETTINGS_PATH = Path(os.environ.get(
    "ZOMBIE_PI_MONO_SETTINGS", "/opt/ai-zombie/pi/settings.json"))


class BridgeError(RuntimeError):
    """Raised when the pi-mono bridge cannot be started or produces
    malformed output."""


def _bridge_argv() -> list[str]:
    explicit = os.environ.get("ZOMBIE_PI_MONO_BRIDGE")
    if explicit:
        # Allow either a bare script path or a full argv string.
        parts = explicit.split()
        if len(parts) == 1 and parts[0].endswith((".mjs", ".js", ".cjs")):
            return ["node", parts[0]]
        return parts
    node = shutil.which("node")
    if node is None:
        raise BridgeError(
            "Cannot run pi-mono: 'node' not on PATH. Install Node.js >=22 "
            "or set ZOMBIE_PI_MONO_BRIDGE to point at a stub."
        )
    if not DEFAULT_BRIDGE.exists():
        raise BridgeError(f"Bridge script missing: {DEFAULT_BRIDGE}")
    return [node, str(DEFAULT_BRIDGE)]


def _log_path() -> Path:
    DEFAULT_LOG_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%S", time.localtime())
    return DEFAULT_LOG_DIR / f"pi-mono.{ts}.{os.getpid()}.log"


ToolCallback = Callable[[str, str, dict[str, Any]], dict[str, Any]]
"""Signature: callback(tool_call_id, tool_name, args) -> {"ok": bool,
"result"|"error": ...}."""


def run_turn(
    *,
    prompt: str,
    system_prompt: str,
    history: Iterable[dict[str, Any]],
    on_tool_call: ToolCallback,
    tool_names: Iterable[str],
    max_tool_calls: int = 8,
    settings_path: Path | str | None = None,
) -> dict[str, Any]:
    """Run one pi-mono turn.

    Returns ``{"final": str, "events": [...]}`` where ``events`` is the
    full list of bridge-emitted events (tool_call + tool_result echoes,
    in order).
    """
    argv = _bridge_argv()
    log = _log_path()
    settings = str(settings_path or DEFAULT_SETTINGS_PATH)
    env = dict(os.environ)
    env.setdefault("PI_MONO_LOG", str(log))

    start_msg = {
        "type": "start",
        "prompt": prompt,
        "system": system_prompt,
        "history": list(history),
        "tools": list(tool_names),
        "settings_path": settings,
        "log_path": str(log),
        "max_tool_calls": max_tool_calls,
    }

    proc = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )
    assert proc.stdin is not None and proc.stdout is not None

    events: list[dict[str, Any]] = []
    final_text = ""
    try:
        proc.stdin.write(json.dumps(start_msg, ensure_ascii=False) + "\n")
        proc.stdin.flush()

        calls_made = 0
        while True:
            line = proc.stdout.readline()
            if not line:
                # Bridge exited; capture stderr for diagnostics.
                err = proc.stderr.read() if proc.stderr else ""
                raise BridgeError(
                    f"pi-mono bridge exited without 'final'. stderr:\n{err[-2000:]}"
                )
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                raise BridgeError(f"Malformed bridge event: {exc}: {line!r}") from exc
            kind = event.get("type")
            events.append(event)
            if kind == "tool_call":
                calls_made += 1
                if calls_made > max_tool_calls:
                    reply = {"type": "tool_result", "id": event.get("id"),
                             "ok": False,
                             "error": f"per-turn tool-call budget exceeded "
                                      f"({max_tool_calls})"}
                else:
                    try:
                        result = on_tool_call(
                            str(event.get("id") or uuid.uuid4().hex),
                            str(event.get("name") or ""),
                            dict(event.get("args") or {}),
                        )
                    except Exception as exc:  # noqa: BLE001
                        result = {"ok": False, "error": f"{exc.__class__.__name__}: {exc}"}
                    reply = {"type": "tool_result", "id": event.get("id"), **result}
                proc.stdin.write(json.dumps(reply, ensure_ascii=False) + "\n")
                proc.stdin.flush()
            elif kind == "final":
                final_text = str(event.get("text") or "")
                break
            elif kind == "error":
                raise BridgeError(str(event.get("message") or "bridge error"))
            else:
                # Unknown event type — record and continue. Bridges may
                # emit progress hints we do not yet interpret.
                continue
    finally:
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)

    return {"final": final_text, "events": events, "log_path": str(log)}


def render_settings(*, tool_names_list: Iterable[str]) -> dict[str, Any]:
    """Return the structured pi-mono settings object the installer
    writes to ``/opt/ai-zombie/pi/settings.json``."""
    return {
        "mode": "rpc",
        "noBuiltinTools": True,
        "tools": list(tool_names_list),
    }


if __name__ == "__main__":  # pragma: no cover - manual smoke
    print(json.dumps({"bridge": _bridge_argv()}, indent=2))
    sys.exit(0)
