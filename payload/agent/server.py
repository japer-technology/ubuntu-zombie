"""Ubuntu Zombie chat service.

A small loopback-only HTTP server that:

- serves a single-page chat UI;
- forwards prompts to the pi-mono agent loop
  (``@earendil-works/pi-coding-agent``) via the bridge in
  ``pi-mono-bridge.mjs``;
- mediates every tool call through the closed registry in ``tools.py``;
- runs read-only tools inline; queues elevated tools for explicit
  operator approval;
- records every step in the JSON-lines audit log;
- persists conversations + structured tool events to SQLite.

The server binds to ``127.0.0.1`` only.

The legacy ``extract_commands`` fenced-bash workflow and its
``SYSTEM_PROMPT_TEMPLATE`` have been removed; the model now drives
the pi-mono agent loop via structured tool calls. The
prompt-formatting helpers are still exposed for the installer
(``server.py --render-append-system``) and for tests.
"""
from __future__ import annotations

import argparse
import getpass
import html
import json
import os
import platform
import queue
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import unquote
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from audit import AUDIT_PATH, log_event, log_tool_call, tail as audit_tail  # noqa: E402
from history import History  # noqa: E402
from policy import POLICY_PATH, load_policy  # noqa: E402
import auth  # noqa: E402
import lifecycle  # noqa: E402
from providers import provider_status  # noqa: E402
import providers  # noqa: E402
import pi_mono  # noqa: E402
import skill_loader  # noqa: E402
import tools as tools_mod  # noqa: E402

SECRETS_FILE = Path(os.environ.get("ZOMBIE_SECRETS", "/opt/ai-zombie/secrets/env"))
DEFAULT_PORT = int(os.environ.get("ZOMBIE_CHAT_PORT", "7878"))
DEFAULT_HOST = "127.0.0.1"
# Streaming is per active operator turn. A thousand queued frames is
# enough for very chatty token streams without letting a disconnected
# browser grow memory unbounded; completed payloads are retained briefly
# so a late EventSource can still receive the terminal frame.
STREAM_QUEUE_MAX = 1000
STREAM_RETAIN_SECONDS = 300.0
STREAM_KEEPALIVE_SECONDS = 15.0
VERSION_CHECK_TIMEOUT_SECONDS = 4.0
VERSION_CACHE_SECONDS = 900.0
STATUS_PROBE_CACHE_SECONDS = 30.0
MAX_VERSION_RESPONSE_BYTES = 1024 * 1024
REACTIVATION_HARD_MIN_SECONDS = 5
REACTIVATION_HARD_MAX_SECONDS = 86400
REACTIVATION_PROMPT_MAX_CHARS = 2000
REACTIVATION_REASON_MAX_CHARS = 160
AGENT_REACTIVATION_OPEN = "<ubuntu-zombie-reactivation>"
AGENT_REACTIVATION_CLOSE = "</ubuntu-zombie-reactivation>"
_VERSION_SOURCES = {
    "ubuntu-zombie": (
        "https://api.github.com/repos/japer-technology/"
        "ubuntu-zombie/releases/latest",
        "tag_name",
    ),
    "pi-mono": (
        "https://registry.npmjs.org/"
        "%40earendil-works%2Fpi-coding-agent/latest",
        "version",
    ),
    "pi-ai": (
        "https://registry.npmjs.org/%40earendil-works%2Fpi-ai/latest",
        "version",
    ),
}
_version_cache: tuple[float, dict[str, str]] = (0.0, {})
_version_cache_lock = threading.Lock()


class TurnStream:
    def __init__(self, turn_id: str, conversation_id: int) -> None:
        self.turn_id = turn_id
        self.conversation_id = conversation_id
        self.queue: queue.Queue[tuple[str, dict[str, Any]]] = queue.Queue(
            maxsize=STREAM_QUEUE_MAX
        )
        self.created_at = time.monotonic()
        self.done_at: float | None = None
        self.attached = False
        self.final_payload: dict[str, Any] | None = None


def _agent_account() -> str:
    """Return the local Linux account the chat service runs as."""
    value = os.environ.get("ZOMBIE_USER")
    if value:
        return value
    try:
        return getpass.getuser()
    except Exception:  # pragma: no cover - extremely defensive
        return "zombie"


AGENT_USER = _agent_account()

APPEND_SYSTEM_TEMPLATE = """You are the AI Systems Administrator for an Ubuntu Desktop machine.

You operate as the local Linux user "{agent_user}", who has passwordless sudo.
You can act on the machine directly with your built-in tools:
`read` and `ls` to inspect files and directories, `write`/`edit`
to change them, `grep`/`find` to search, and `bash` to run shell
commands (use `sudo` when a task needs root). Per-turn tool-call
budgets are enforced.

Your sudo is real. If a command fails with `Permission denied`,
`Operation not permitted`, or `Read-only file system`, this almost
always means the command needs `sudo` — re-run it with `sudo`.
Do not conclude that the machine is a restricted container or a
read-only sandbox, and do not abandon a system-administration task by
claiming you lack permissions: you are the administrator of this
machine. The policy gate may ask the operator to approve an action,
but it never strips your privileges.

Always *use these tools* to carry out a request rather than describing
the tool call in text — for example, to list the home directory call the
`ls` tool, do not print a tool-call string.

If useful work must continue in a later model turn, you can reactivate
yourself. Append exactly one structured request as the final thing in your
reply:
<ubuntu-zombie-reactivation>{{"delay_seconds":30,"prompt":"Continue the prior task.","reason":"More work remains.","replace_existing":false}}</ubuntu-zombie-reactivation>
The runtime removes this block from the visible reply and schedules an
ordinary future turn in the same conversation. Use it only when another turn
is genuinely needed; obey the configured delay bounds and do not invoke it
through `bash`.

Style:
- Be concise. Prefer one short paragraph over many.
- Quote tool output you have already received rather than guessing.
- Refuse and explain if asked to exfiltrate secrets, disable the audit
  log, or weaken the policy gate.

Machine facts (auto-collected): {facts}
"""


def render_append_system(facts: str) -> str:
    """Render the system-prompt suffix that pi-mono receives via
    ``--append-system-prompt``."""
    return APPEND_SYSTEM_TEMPLATE.format(agent_user=AGENT_USER, facts=facts)


def _agent_reactivation_request(
    reply: str,
) -> tuple[str, dict[str, Any] | None, str | None]:
    """Remove and decode one trailing agent reactivation request."""
    stripped = reply.rstrip()
    start = stripped.rfind(AGENT_REACTIVATION_OPEN)
    if start < 0:
        return reply, None, None
    visible = stripped[:start].rstrip()
    encoded = stripped[start + len(AGENT_REACTIVATION_OPEN):]
    if not encoded.endswith(AGENT_REACTIVATION_CLOSE):
        return visible, None, "structured reactivation request is not closed"
    encoded = encoded[:-len(AGENT_REACTIVATION_CLOSE)].strip()
    try:
        request = json.loads(encoded)
    except json.JSONDecodeError as exc:
        return visible, None, f"invalid structured reactivation JSON: {exc.msg}"
    if not isinstance(request, dict):
        return visible, None, "structured reactivation request must be an object"
    return visible, request, None


# ---------------------------------------------------------------------------
# Loopback safety
# ---------------------------------------------------------------------------

def assert_secrets_safe() -> None:
    """Refuse to start if the secrets file is group/world-readable."""
    if not SECRETS_FILE.exists():
        return  # nothing to protect yet
    mode = SECRETS_FILE.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise SystemExit(
            f"Refusing to start: {SECRETS_FILE} has group/world "
            "permissions. Fix with: sudo chmod 600 "
            f"{SECRETS_FILE} && sudo chown {AGENT_USER}:{AGENT_USER} {SECRETS_FILE}"
        )


def load_secrets_env() -> None:
    if not SECRETS_FILE.exists():
        return
    for raw in SECRETS_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # FIX-3-13: allow shell-style ``export FOO=bar`` lines.
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        # FIX-3-13: honour mid-line ``#`` comments, but only when the
        # ``#`` sits outside a quoted value (otherwise values like
        # ``****** would be truncated).
        if val and val[0] in ("'", '"'):
            quote = val[0]
            end = val.find(quote, 1)
            if end != -1:
                val = val[1:end]
            else:
                # Unmatched quote: strip the opening quote and still
                # honour a trailing ``#`` comment on the remainder.
                val = val[1:]
                hash_idx = val.find("#")
                if hash_idx != -1:
                    val = val[:hash_idx].rstrip()
        else:
            hash_idx = val.find("#")
            if hash_idx != -1:
                val = val[:hash_idx].rstrip()
        if key and key not in os.environ:
            os.environ[key] = val


# ---------------------------------------------------------------------------
# Machine facts (cheap, read-only)
# ---------------------------------------------------------------------------

def machine_facts() -> dict[str, str]:
    facts = {
        "hostname": socket.gethostname(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "ip_address": _primary_ipv4(),
    }
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                facts["os"] = line.split("=", 1)[1].strip().strip('"')
                break
    except OSError:
        pass
    return facts


def _primary_ipv4() -> str:
    """Return the primary IPv4 address without sending application data."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 9))
        return str(sock.getsockname()[0])
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "unknown"
    finally:
        sock.close()


def system_health() -> dict[str, Any]:
    """Return cheap local resource and uptime facts for proof-of-life status."""
    info: dict[str, Any] = {}
    try:
        info["load_average"] = [round(value, 2) for value in os.getloadavg()]
    except OSError:
        pass
    try:
        info["system_uptime_seconds"] = int(float(
            Path("/proc/uptime").read_text(encoding="utf-8").split()[0]
        ))
    except (OSError, ValueError, IndexError):
        pass
    try:
        memory: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            if key in {"MemTotal", "MemAvailable"}:
                memory[key] = int(value.strip().split()[0]) * 1024
        if memory:
            info["memory_total_bytes"] = memory.get("MemTotal")
            info["memory_available_bytes"] = memory.get("MemAvailable")
    except (OSError, ValueError, IndexError):
        pass
    try:
        disk = shutil.disk_usage("/")
        info.update({
            "disk_total_bytes": disk.total,
            "disk_free_bytes": disk.free,
        })
    except OSError:
        pass
    return info


def _read_text_file(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return text or None


def app_version() -> str:
    """Best-effort payload version.

    Read from a ``VERSION`` file deployed alongside the agent tree
    (``/opt/ai-zombie/VERSION`` in production) or the repository root
    when running from a checkout. Falls back to ``"unknown"`` so the
    ``/version`` chat command never errors.
    """
    for candidate in (HERE.parent / "VERSION", HERE.parent.parent / "VERSION"):
        text = _read_text_file(candidate)
        if text:
            return text
    return "unknown"


def _runtime_version(command: list[str]) -> str | None:
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, check=False, timeout=2
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = (result.stdout or result.stderr or "").strip()
    return value.lstrip("v") or None


def _latest_component_versions() -> dict[str, str]:
    """Fetch fixed upstream latest-version metadata with a short shared cache."""
    global _version_cache
    now = time.monotonic()
    with _version_cache_lock:
        cached_at, cached = _version_cache
        if now - cached_at < VERSION_CACHE_SECONDS:
            return dict(cached)

    latest: dict[str, str] = {}
    for name, (url, field) in _VERSION_SOURCES.items():
        request = Request(
            url,
            headers={
                "Accept": "application/json",
                "User-Agent": f"ubuntu-zombie/{app_version()}",
            },
        )
        try:
            with urlopen(
                request, timeout=VERSION_CHECK_TIMEOUT_SECONDS
            ) as response:
                raw = response.read(MAX_VERSION_RESPONSE_BYTES + 1)
            if len(raw) > MAX_VERSION_RESPONSE_BYTES:
                continue
            payload = json.loads(raw)
            value = payload.get(field) if isinstance(payload, dict) else None
            if isinstance(value, str) and value.strip():
                latest[name] = value.strip().removeprefix("v")
        except (
            HTTPError, URLError, OSError, TimeoutError,
            UnicodeDecodeError, ValueError,
        ):
            continue

    with _version_cache_lock:
        _version_cache = (time.monotonic(), dict(latest))
    return latest


def version_info(check_latest: bool = False) -> dict[str, Any]:
    """Return installed component versions and optional upstream releases."""
    info: dict[str, Any] = {"version": app_version()}
    pi_mono = _read_text_file(HERE / "pi-mono.version")
    if pi_mono:
        info["pi_mono"] = pi_mono
    pi_ai = _read_text_file(HERE / "pi-ai.version")
    if pi_ai:
        info["pi_ai"] = pi_ai
    latest = _latest_component_versions() if check_latest else {}
    components = [
        {
            "name": "ubuntu-zombie",
            "installed": info["version"],
            "latest": latest.get("ubuntu-zombie"),
            "source": "GitHub releases",
        },
        {
            "name": "pi-mono",
            "installed": pi_mono or "unknown",
            "latest": latest.get("pi-mono"),
            "source": "npm",
        },
        {
            "name": "pi-ai",
            "installed": pi_ai or "unknown",
            "latest": latest.get("pi-ai"),
            "source": "npm",
        },
        {
            "name": "python",
            "installed": platform.python_version(),
            "latest": None,
            "source": "Ubuntu packages",
        },
        {
            "name": "node",
            "installed": _runtime_version(["node", "--version"]) or "not installed",
            "latest": None,
            "source": "Ubuntu Zombie runtime",
        },
        {
            "name": "sqlite",
            "installed": sqlite3.sqlite_version,
            "latest": None,
            "source": "Python runtime",
        },
    ]
    info["components"] = components
    info["latest_checked"] = check_latest
    return info


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------

class App:
    def __init__(self) -> None:
        self.started_at = time.time()
        self.history = History()
        # Pending tool calls awaiting operator approval. Each item is
        # addressable by both the audit entry id and provider tool-call id
        # so legacy buttons and text commands resolve the same queue item.
        self.pending: dict[str, dict[str, Any]] = {}
        # Active login session tokens (the password gate). Empty after a
        # restart so every browser re-authenticates; tokens are opaque
        # and never persisted.
        self.sessions: set[str] = set()
        # Active / recently completed streaming turns, keyed by opaque
        # turn id. The final payload is retained briefly so a late
        # EventSource can receive a terminal event instead of hanging.
        self.turns: dict[str, TurnStream] = {}
        self._status_probe_cache: tuple[float, dict[str, Any]] = (0.0, {})
        self._lock = threading.Lock()
        self._lmstudio_lock = threading.Lock()
        self._status_probe_lock = threading.Lock()
        self._reactivation_wakeup = threading.Event()
        for orphaned in self.history.fail_orphaned_reactivations():
            log_event(
                "reactivation_failed",
                conversation_id=orphaned["conversation_id"],
                reactivation_id=orphaned["id"],
                error="server restarted while firing",
            )
        threading.Thread(
            target=self._reactivation_supervisor,
            name="reactivation-timer",
            daemon=True,
        ).start()

    # ---- authentication + lifecycle ----
    def login(self, password: str) -> dict[str, Any] | None:
        """Validate ``password`` and mint a session token, or ``None``."""
        if not auth.check_password(password or ""):
            log_event("login_failed")
            return None
        token = auth.new_session_token()
        with self._lock:
            self.sessions.add(token)
        log_event("login_ok")
        return {"ok": True, "token": token}

    def logout(self, token: str | None) -> None:
        if token:
            with self._lock:
                self.sessions.discard(token)

    def session_valid(self, token: str | None) -> bool:
        if not auth.auth_required():
            return True
        if not token:
            return False
        with self._lock:
            return token in self.sessions

    def session_info(self, token: str | None) -> dict[str, Any]:
        life = lifecycle.status()
        return {
            "authenticated": self.session_valid(token),
            "required": auth.auth_required(),
            "dead": life["dead"],
            "dead_reason": life["dead_reason"],
            "remaining_human": life["remaining_human"],
            "remaining_seconds": life["remaining_seconds"],
        }

    def ttl_status(self) -> dict[str, Any]:
        return lifecycle.status()

    def ttl_set(self, days: float) -> dict[str, Any]:
        """Extend the Time to Live; refuse if the zombie is already dead."""
        return self.ttl_set_seconds(days * lifecycle.DAY_SECONDS)

    def ttl_set_seconds(self, seconds: float) -> dict[str, Any]:
        """Extend the Time to Live; refuse if the zombie is already dead."""
        current = lifecycle.status()
        if current["dead"]:
            return {"error": "The Ubuntu Zombie is permanently disabled.",
                    "dead": True, **current}
        try:
            result = lifecycle.set_ttl_seconds(seconds)
        except ValueError as exc:
            return {"error": str(exc)}
        log_event("ttl_extended", seconds=seconds,
                  remaining_seconds=result["remaining_seconds"])
        return result

    def ttl_reset_seconds(
        self, seconds: float = lifecycle.DEFAULT_TTL_SECONDS
    ) -> dict[str, Any]:
        """Reset the Time to Live; refuse if the zombie is already dead."""
        current = lifecycle.status()
        if current["dead"]:
            return {"error": "The Ubuntu Zombie is permanently disabled.",
                    "dead": True, **current}
        try:
            result = lifecycle.reset_ttl_seconds(seconds)
        except ValueError as exc:
            return {"error": str(exc)}
        log_event("ttl_reset", seconds=seconds,
                  remaining_seconds=result["remaining_seconds"])
        return result

    def ttl_die(self) -> dict[str, Any]:
        """Trip the kill switch immediately and permanently."""
        result = lifecycle.kill()
        log_event("ttl_killed")
        return result

    def set_password(self, password: str) -> dict[str, Any]:
        """Set or remove the chat password without logging the secret."""
        password = password or ""
        stored = _write_password_hash(password if password else None)
        with self._lock:
            self.sessions.clear()
        if stored:
            os.environ[auth.HASH_ENV] = stored
            log_event("password_set")
            return {"ok": True, "required": True, "logoff_required": True}
        os.environ.pop(auth.HASH_ENV, None)
        log_event("password_removed")
        return {"ok": True, "required": False, "logoff_required": False}

    # ---- conversation flow ----
    def _emit_turn(self, state: TurnStream, event: str,
                   payload: dict[str, Any]) -> None:
        frame = (event, payload)
        try:
            state.queue.put_nowait(frame)
            return
        except queue.Full:
            pass
        # Prefer dropping stale token deltas; phase/tool/final/error
        # events carry state transitions and should survive overflow.
        # ``queue.Queue`` has no drop-oldest API, so this uses its
        # documented synchronization primitives while touching the
        # underlying deque under the queue mutex. That keeps the worker
        # non-blocking and avoids draining 1000 queued frames into a
        # temporary list; CPython's stdlib queue exposes these attributes
        # for subclass implementations, and Ubuntu's supported Python
        # versions preserve that contract.
        with state.queue.mutex:
            drop_index: int | None = None
            for idx, old in enumerate(state.queue.queue):
                if old[0] == "token":
                    drop_index = idx
                    break
            if drop_index is None:
                if event == "token":
                    return
                # No stale token exists; make room for this state
                # transition by dropping the oldest queued frame.
                drop_index = 0
            del state.queue.queue[drop_index]
            state.queue.queue.append(frame)
            state.queue.not_empty.notify()

    def _finish_turn(self, state: TurnStream, payload: dict[str, Any],
                     event: str = "turn_done") -> None:
        state.final_payload = payload
        state.done_at = time.monotonic()
        self._emit_turn(state, event, payload)

    def _sweep_turns(self) -> None:
        now = time.monotonic()
        expired = [
            tid for tid, state in self.turns.items()
            if state.done_at is not None and now - state.done_at > STREAM_RETAIN_SECONDS
        ]
        for tid in expired:
            self.turns.pop(tid, None)

    def start_streaming_message(
        self,
        conv_id: int | None,
        prompt: str,
        user_meta: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        life = lifecycle.status()
        if life["dead"]:
            return {
                "error": (
                    "The Ubuntu Zombie has been permanently disabled "
                    f"({life['dead_reason'] or 'expired'}). It is unusable "
                    "until a reinstall."
                ),
                "dead": True,
            }
        if not conv_id:
            conv_id = self.history.create_conversation()
        turn_id = uuid.uuid4().hex
        state = TurnStream(turn_id, conv_id)
        with self._lock:
            self._sweep_turns()
            self.turns[turn_id] = state

        def emit(event: str, payload: dict[str, Any]) -> None:
            if event in {"turn_done", "turn_error"}:
                state.final_payload = payload
                state.done_at = time.monotonic()
            self._emit_turn(state, event, payload)

        def worker() -> None:
            try:
                result = self.post_message(
                    conv_id, prompt, emit=emit, user_meta=user_meta
                )
                if state.done_at is None:
                    terminal = "turn_error" if result.get("error") and not result.get("reply") else "turn_done"
                    self._finish_turn(state, result, terminal)
            except Exception as exc:  # noqa: BLE001
                msg = (
                    f"streaming turn {turn_id} failed for conversation #{conv_id} "
                    f"(prompt {len(prompt)} chars): "
                    f"{exc.__class__.__name__}: {exc}"
                )
                err = {"conversation_id": conv_id, "error": msg}
                self._finish_turn(state, err, "turn_error")

        threading.Thread(
            target=worker, name=f"turn-{turn_id[:12]}", daemon=True
        ).start()
        return {"turn_id": turn_id, "conversation_id": conv_id}

    def get_turn_stream(self, turn_id: str) -> TurnStream | None:
        with self._lock:
            self._sweep_turns()
            return self.turns.get(turn_id)

    def attach_turn_stream(self, turn_id: str) -> TurnStream | None:
        with self._lock:
            self._sweep_turns()
            state = self.turns.get(turn_id)
            if state is None:
                return None
            if state.attached:
                return None
            state.attached = True
            return state

    def detach_turn_stream(self, turn_id: str) -> None:
        """Release a stream attachment after a dropped connection so the
        browser's automatic EventSource reconnect can re-attach and still
        receive the remaining (including terminal) frames."""
        with self._lock:
            state = self.turns.get(turn_id)
            if state is not None:
                state.attached = False

    def post_message(
        self,
        conv_id: int | None,
        prompt: str,
        emit: Callable[[str, dict[str, Any]], None] | None = None,
        user_meta: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        def send_event(event: str, payload: dict[str, Any]) -> None:
            if emit is not None:
                emit(event, payload)

        life = lifecycle.status()
        if life["dead"]:
            payload = {
                "error": (
                    "The Ubuntu Zombie has been permanently disabled "
                    f"({life['dead_reason'] or 'expired'}). It is unusable "
                    "until a reinstall."
                ),
                "dead": True,
            }
            send_event("turn_error", payload)
            return payload
        if not conv_id:
            conv_id = self.history.create_conversation()
        log_event("prompt", conversation_id=conv_id, prompt=prompt)
        self.history.add_message(conv_id, "user", prompt, user_meta)

        facts = ", ".join(f"{k}={v}" for k, v in machine_facts().items())
        system_prompt = render_append_system(facts)
        summary = self.history.latest_summary(conv_id)
        if summary:
            system_prompt = (
                system_prompt.rstrip()
                + "\n\nConversation summary retained from /compress:\n"
                + summary
            )
        history_payload = [
            {"role": m["role"], "content": m["content"]}
            for m in self.history.get_messages(conv_id)
            if m["role"] in {"user", "assistant"}
        ]

        # Select skills whose trigger words appear in the operator's
        # recent prompts and append them to the system prompt.
        # ``skill_active`` history events record the provenance so the
        # UI can show *what* was injected.
        recent_user = [m["content"] for m in self.history.get_messages(conv_id)
                       if m["role"] == "user"]
        active_skills = skill_loader.select_skills(recent_user)
        block = skill_loader.render_skills_block(active_skills)
        if block:
            system_prompt = system_prompt.rstrip() + "\n\n" + block
        for skill in active_skills:
            self.history.add_event(conv_id, "skill_active", {
                "name": skill.name,
                "path": str(skill.path),
                "triggers": list(skill.triggers),
            })
            log_event("skill_active", conversation_id=conv_id,
                      name=skill.name, path=str(skill.path))

        policy = load_policy()
        max_calls = int(
            getattr(policy, "max_tool_calls_per_turn", 1000) or 1000)
        # Also enforce the elevated (non ``read_only``) per-turn
        # budget. Read-only tools auto-run and are cheap; elevated
        # tools queue an operator prompt and mutate state, so they
        # are bounded separately to cap the blast radius of a runaway
        # loop. Calls beyond the budget receive a synthetic
        # ``budget_exceeded`` observation (see
        # ``payload/etc/policy.yaml``) so the model ends the turn
        # cleanly.
        max_elevated = int(
            getattr(policy, "max_elevated_calls_per_turn", 250) or 250
        )
        # Per-turn idle deadline so a wedged provider cannot leave the
        # operator's request pending forever (see ``pi_mono.run_turn``).
        turn_timeout = float(
            getattr(policy, "max_turn_seconds", 86400) or 0)
        elevated_calls = 0
        turn_events: list[dict[str, Any]] = []

        def on_tool_call(call_id: str, name: str, args: dict[str, Any]) -> dict[str, Any]:
            nonlocal elevated_calls
            # Validate against the closed registry first; reject unknown
            # tools and schema mismatches without side effects.
            try:
                cleaned = tools_mod.validate_args(name, args)
            except tools_mod.SchemaError as exc:
                log_tool_call(tool=name, classification="unknown",
                              decision="schema_rejected",
                              args_summary=_summarize(args),
                              error=str(exc), conversation_id=conv_id)
                self.history.add_event(conv_id, "tool_call", {
                    "tool_call_id": call_id, "tool": name, "args": _summarize(args),
                    "decision": "schema_rejected", "error": str(exc),
                })
                send_event("tool_end", {
                    "tool": name, "tool_call_id": call_id, "ok": False,
                    "decision": "schema_rejected", "error": str(exc),
                })
                return {"ok": False, "error": f"schema_rejected: {exc}"}

            classification = policy.classify_tool(name, cleaned)
            requires_approval = policy.requires_approval(classification)
            requires_phrase = policy.requires_phrase(classification)

            # Phase 4 / P4.1: bound elevated calls (anything other than
            # ``read_only``) per turn. We count BEFORE queuing so a
            # runaway sequence of queued approvals is also bounded.
            if classification != "read_only":
                elevated_calls += 1
                if elevated_calls > max_elevated:
                    err = (f"budget_exceeded: per-turn elevated tool-call "
                           f"budget reached ({max_elevated}); "
                           f"end the turn and ask the operator how to proceed.")
                    log_tool_call(
                        tool=name, classification=classification,
                        decision="budget_exceeded",
                        args_summary=_summarize(cleaned),
                        error=err, conversation_id=conv_id,
                        tool_call_id=call_id,
                    )
                    self.history.add_event(conv_id, "tool_observation", {
                        "tool_call_id": call_id, "tool": name,
                        "ok": False, "decision": "budget_exceeded",
                        "error": err,
                    })
                    send_event("tool_end", {
                        "tool": name, "tool_call_id": call_id, "ok": False,
                        "decision": "budget_exceeded", "error": err,
                    })
                    return {"ok": False, "error": err}

            entry_id = log_tool_call(
                tool=name, classification=classification,
                decision=("queued" if requires_approval else "auto"),
                args_summary=_summarize(cleaned),
                conversation_id=conv_id,
            )
            self.history.add_event(conv_id, "tool_call", {
                "id": entry_id,
                "tool_call_id": call_id,
                "tool": name,
                "args": _summarize(cleaned),
                "classification": classification,
                "decision": ("queued" if requires_approval else "auto"),
                "requires_phrase": requires_phrase,
            })
            send_event("tool_start", {
                "tool": name,
                "tool_call_id": call_id,
                "classification": classification,
                "decision": ("queued" if requires_approval else "auto"),
                "args_summary": _summarize(cleaned),
            })

            if requires_approval:
                with self._lock:
                    pending = {
                        "id": entry_id,
                        "conversation_id": conv_id,
                        "tool_call_id": call_id,
                        "tool": name,
                        "args": cleaned,
                        "classification": classification,
                        "requires_phrase": requires_phrase,
                    }
                    self.pending[entry_id] = pending
                    self.pending[call_id] = pending
                self.history.add_event(conv_id, "pending_tool_call", {
                    "id": entry_id, "tool_call_id": call_id, "tool": name,
                    "classification": classification,
                    "requires_phrase": requires_phrase,
                    "confirm_phrase": (policy.destructive_confirmation
                                        if requires_phrase else None),
                })
                send_event("pending_approval", {
                    "id": entry_id, "tool_call_id": call_id, "tool": name,
                    "classification": classification,
                    "requires_phrase": requires_phrase,
                    "confirm_phrase": (policy.destructive_confirmation
                                        if requires_phrase else None),
                })
                # End the model turn cleanly — pi sees an observation
                # explaining the operator gate so it can summarize.
                return {"ok": False,
                        "error": ("operator_approval_required: this call has "
                                  "been queued for human review; do not retry.")}

            # Auto-approved by policy (normally read_only or chat_schedule):
            # execute now.
            try:
                result = self._dispatch_tool(name, cleaned, conv_id)
                self.history.add_event(conv_id, "tool_observation", {
                    "tool_call_id": call_id, "tool": name,
                    "ok": True, "result": _truncate_obs(result),
                })
                log_tool_call(
                    tool=name, classification=classification, decision="executed",
                    args_summary=_summarize(cleaned),
                    exit_code=result.get("exit_code") if isinstance(result, dict) else None,
                    duration_ms=result.get("duration_ms") if isinstance(result, dict) else None,
                    stdout=(result.get("stdout") if isinstance(result, dict) else None),
                    stderr=(result.get("stderr") if isinstance(result, dict) else None),
                    conversation_id=conv_id, tool_call_id=call_id,
                )
                turn_events.append({"kind": "tool_observation", "tool": name,
                                    "result": result})
                # Byte counts let the UI's /verbose mode tally how
                # much data each tool moved without shipping the
                # full output over the progress stream.
                def _out_bytes(field: str) -> int | None:
                    if not isinstance(result, dict):
                        return None
                    return len((result.get(field) or "").encode("utf-8"))

                send_event("tool_end", {
                    "tool": name,
                    "tool_call_id": call_id,
                    "ok": True,
                    "exit_code": result.get("exit_code") if isinstance(result, dict) else None,
                    "duration_ms": result.get("duration_ms") if isinstance(result, dict) else None,
                    "stdout_bytes": _out_bytes("stdout"),
                    "stderr_bytes": _out_bytes("stderr"),
                })
                return {"ok": True, "result": result}
            except Exception as exc:  # noqa: BLE001
                self.history.add_event(conv_id, "tool_observation", {
                    "tool_call_id": call_id, "tool": name,
                    "ok": False, "error": str(exc),
                })
                log_tool_call(tool=name, classification=classification,
                              decision="error",
                              args_summary=_summarize(cleaned),
                              error=str(exc), conversation_id=conv_id)
                send_event("tool_end", {
                    "tool": name, "tool_call_id": call_id,
                    "ok": False, "error": str(exc),
                })
                return {"ok": False, "error": str(exc)}

        def on_bridge_event(event: dict[str, Any]) -> None:
            kind = event.get("type")
            if kind == "token":
                delta = event.get("delta")
                if isinstance(delta, str) and delta:
                    send_event("token", {"delta": delta})
            elif kind == "progress":
                progress = event.get("kind")
                raw_tool = event.get("name")
                tool = raw_tool if isinstance(raw_tool, str) and raw_tool else "tool"
                if progress == "tool_start":
                    payload: dict[str, Any] = {
                        "tool": tool, "classification": "bridge",
                        "decision": "running",
                    }
                    tool_id = event.get("id")
                    if isinstance(tool_id, str) and tool_id:
                        payload["tool_call_id"] = tool_id
                    args = event.get("args")
                    if isinstance(args, dict) and args:
                        payload["args_summary"] = _summarize(args)
                    send_event("tool_start", payload)
                elif progress == "tool_end":
                    # Forward the bridge's full account of the call —
                    # outcome, duration and output size — so the UI's
                    # verbose mode shows more than a bare "done".
                    payload = {"tool": tool,
                               "ok": event.get("ok", True) is not False}
                    tool_id = event.get("id")
                    if isinstance(tool_id, str) and tool_id:
                        payload["tool_call_id"] = tool_id
                    duration = event.get("duration_ms")
                    if isinstance(duration, (int, float)):
                        payload["duration_ms"] = int(duration)
                    exit_code = event.get("exit_code")
                    if isinstance(exit_code, int):
                        payload["exit_code"] = exit_code
                    if event.get("command_status") is True:
                        payload["command_status"] = True
                    out_bytes = event.get("output_bytes")
                    if isinstance(out_bytes, (int, float)):
                        payload["stdout_bytes"] = int(out_bytes)
                    send_event("tool_end", payload)

        try:
            send_event("phase", {"phase": "model"})
            turn = pi_mono.run_turn(
                prompt=prompt,
                system_prompt=system_prompt,
                history=history_payload,
                on_tool_call=on_tool_call,
                tool_names=tools_mod.tool_names(),
                max_tool_calls=max_calls,
                timeout=turn_timeout,
                on_event=on_bridge_event,
            )
        except pi_mono.BridgeError as exc:
            err = str(exc)
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            payload = {"conversation_id": conv_id, "error": err}
            send_event("turn_error", payload)
            return payload
        except Exception as exc:  # noqa: BLE001
            err = f"pi-mono call failed: {exc.__class__.__name__}: {exc}"
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            payload = {"conversation_id": conv_id, "error": err}
            send_event("turn_error", payload)
            return payload

        send_event("phase", {"phase": "finalising"})
        reply = turn.get("final") or ""
        reply, reactivation_request, reactivation_error = (
            _agent_reactivation_request(reply)
        )
        if reactivation_request is not None:
            reactivation_result = self._consume_agent_reactivation(
                conv_id, reactivation_request
            )
            status = str(reactivation_result.get("status") or "rejected")
            reply = (
                reply.rstrip()
                + f"\n\n_Reactivation request: {status.replace('_', ' ')}._"
            )
        elif reactivation_error is not None:
            log_event(
                "reactivation_rejected",
                conversation_id=conv_id,
                reason="invalid_structured_request",
                error=reactivation_error,
            )
            reply = (
                reply.rstrip()
                + f"\n\n_Reactivation request rejected: {reactivation_error}._"
            )
        self.history.add_message(conv_id, "assistant", reply,
                                 {"engine": "pi-mono",
                                  "log_path": turn.get("log_path")})
        payload = {
            "conversation_id": conv_id,
            "reply": reply,
        }
        # The live transcript already contains this turn. Avoid serialising
        # the entire conversation into the terminal SSE frame: large command
        # histories otherwise leave the browser apparently stuck in the
        # finalising phase while an unnecessary payload is written.
        if emit is None:
            payload["events"] = self.history.get_events(conv_id)
            payload["messages"] = self.history.get_messages(conv_id)
        send_event("turn_done", payload)
        return payload

    def _consume_agent_reactivation(
        self, conversation_id: int, args: dict[str, Any]
    ) -> dict[str, Any]:
        """Validate, policy-check, and execute a structured agent request."""
        tool = "timer.reactivation"
        call_id = f"reactivation-{uuid.uuid4().hex}"
        try:
            cleaned = tools_mod.validate_args(tool, args)
        except tools_mod.SchemaError as exc:
            result = {"ok": False, "status": "rejected_schema", "error": str(exc)}
            decision = "schema_rejected"
            classification = "unknown"
        else:
            policy = load_policy()
            classification = policy.classify_tool(tool, cleaned)
            if policy.requires_approval(classification):
                result = {
                    "ok": False,
                    "status": "rejected_policy",
                    "error": "timer.reactivation requires operator approval",
                }
                decision = "approval_required"
            else:
                result = self._dispatch_tool(tool, cleaned, conversation_id)
                decision = "executed" if result.get("ok") else "rejected"
        self.history.add_event(conversation_id, "tool_call", {
            "tool_call_id": call_id,
            "tool": tool,
            "args": _summarize(args),
            "classification": classification,
            "decision": decision,
        })
        self.history.add_event(conversation_id, "tool_observation", {
            "tool_call_id": call_id,
            "tool": tool,
            "ok": bool(result.get("ok")),
            "result": _truncate_obs(result),
        })
        log_tool_call(
            tool=tool,
            classification=classification,
            decision=decision,
            args_summary=_summarize(args),
            error=str(result.get("error") or "") or None,
            conversation_id=conversation_id,
            tool_call_id=call_id,
        )
        return result

    def _dispatch_tool(
        self, name: str, args: dict[str, Any], conversation_id: int
    ) -> dict[str, Any]:
        if name == "timer.reactivation":
            return self.schedule_reactivation(
                conversation_id=conversation_id,
                delay_seconds=int(args["delay_seconds"]),
                prompt=str(args["prompt"]),
                reason=str(args.get("reason") or "Continue the current task."),
                replace_existing=bool(args.get("replace_existing", False)),
            )
        return tools_mod.dispatch(name, args)

    def schedule_reactivation(
        self,
        *,
        conversation_id: int,
        delay_seconds: int,
        prompt: str,
        reason: str,
        replace_existing: bool = False,
    ) -> dict[str, Any]:
        settings = self.history.reactivation_settings()
        if not settings["enabled"]:
            log_event(
                "reactivation_rejected",
                conversation_id=conversation_id,
                reason="disabled",
            )
            return {"ok": False, "status": "rejected_disabled"}
        if not self.history.conversation_exists(conversation_id):
            return {"ok": False, "status": "rejected_conversation_missing"}
        if (
            delay_seconds < settings["minimum_seconds"]
            or delay_seconds > settings["maximum_seconds"]
        ):
            log_event(
                "reactivation_rejected",
                conversation_id=conversation_id,
                reason="delay_out_of_bounds",
                delay_seconds=delay_seconds,
            )
            return {
                "ok": False,
                "status": "rejected_policy",
                "error": (
                    f"delay_seconds must be between "
                    f"{settings['minimum_seconds']} and "
                    f"{settings['maximum_seconds']}"
                ),
            }
        cleaned_prompt = prompt.strip()
        cleaned_reason = " ".join(reason.strip().split())
        if not cleaned_prompt or len(cleaned_prompt) > REACTIVATION_PROMPT_MAX_CHARS:
            return {
                "ok": False,
                "status": "rejected_policy",
                "error": (
                    "prompt must contain 1 to "
                    f"{REACTIVATION_PROMPT_MAX_CHARS} characters"
                ),
            }
        if not cleaned_reason:
            cleaned_reason = "Continue the current task."
        if len(cleaned_reason) > REACTIVATION_REASON_MAX_CHARS:
            return {
                "ok": False,
                "status": "rejected_policy",
                "error": (
                    "reason must contain at most "
                    f"{REACTIVATION_REASON_MAX_CHARS} characters"
                ),
            }
        life = lifecycle.status()
        if life["dead"] or delay_seconds >= int(life["remaining_seconds"]):
            log_event(
                "reactivation_rejected",
                conversation_id=conversation_id,
                reason="ttl",
                delay_seconds=delay_seconds,
            )
            return {
                "ok": False,
                "status": "rejected_policy",
                "error": "reactivation must fire before the remaining TTL expires",
            }
        item, replaced = self.history.schedule_reactivation(
            conversation_id,
            time.time() + delay_seconds,
            cleaned_prompt,
            cleaned_reason,
            replace_existing=replace_existing,
        )
        if item is None:
            return {
                "ok": False,
                "status": "rejected_pending_exists",
                "pending": self._public_reactivation(replaced),
            }
        if replaced is not None:
            log_event(
                "reactivation_replaced",
                conversation_id=conversation_id,
                reactivation_id=item["id"],
                replaced_id=replaced["id"],
                fire_at=item["fire_at"],
                reason=cleaned_reason,
                prompt_chars=len(cleaned_prompt),
            )
            status = "replaced"
        else:
            log_event(
                "reactivation_scheduled",
                conversation_id=conversation_id,
                reactivation_id=item["id"],
                fire_at=item["fire_at"],
                reason=cleaned_reason,
                prompt_chars=len(cleaned_prompt),
            )
            status = "accepted"
        self.history.add_event(
            conversation_id,
            "reactivation_scheduled",
            {
                "id": item["id"],
                "fire_at": item["fire_at"],
                "reason": cleaned_reason,
                "status": status,
            },
        )
        self._reactivation_wakeup.set()
        return {
            "ok": True,
            "status": status,
            "reactivation": self._public_reactivation(item),
        }

    @staticmethod
    def _public_reactivation(
        item: dict[str, Any] | None,
    ) -> dict[str, Any] | None:
        if item is None:
            return None
        return {
            "id": item["id"],
            "conversation_id": item["conversation_id"],
            "created_at": item["created_at"],
            "fire_at": item["fire_at"],
            "reason": item["reason"],
            "prompt": item["prompt"],
            "status": item["status"],
            "actor": item["actor"],
        }

    def reactivation_info(self) -> dict[str, Any]:
        settings = self.history.reactivation_settings()
        pending = self._public_reactivation(
            self.history.pending_reactivation()
        )
        if pending is not None:
            pending["remaining_seconds"] = max(
                0, int(pending["fire_at"] - time.time())
            )
        return {"ok": True, **settings, "pending": pending}

    def configure_reactivation(
        self,
        *,
        enabled: bool | None = None,
        minimum_seconds: int | None = None,
        maximum_seconds: int | None = None,
    ) -> dict[str, Any]:
        current = self.history.reactivation_settings()
        minimum = (
            current["minimum_seconds"]
            if minimum_seconds is None else minimum_seconds
        )
        maximum = (
            current["maximum_seconds"]
            if maximum_seconds is None else maximum_seconds
        )
        if minimum < REACTIVATION_HARD_MIN_SECONDS:
            return {
                "error": (
                    f"minimum must be at least "
                    f"{REACTIVATION_HARD_MIN_SECONDS} seconds"
                )
            }
        if maximum > REACTIVATION_HARD_MAX_SECONDS:
            return {
                "error": (
                    f"maximum must not exceed "
                    f"{REACTIVATION_HARD_MAX_SECONDS} seconds"
                )
            }
        if minimum > maximum:
            return {"error": "minimum must not exceed maximum"}
        settings = self.history.update_reactivation_settings(
            enabled=enabled,
            minimum_seconds=minimum_seconds,
            maximum_seconds=maximum_seconds,
        )
        cancelled = None
        if enabled is False:
            cancelled = self.cancel_reactivation(actor="operator", reason="disabled")
        log_event("reactivation_settings_changed", **settings)
        self._reactivation_wakeup.set()
        return {"ok": True, **settings, "cancelled": cancelled.get("cancelled")
                if cancelled else None}

    def cancel_reactivation(
        self, *, actor: str = "operator", reason: str = "cancelled"
    ) -> dict[str, Any]:
        item = self.history.cancel_pending_reactivation(reason)
        if item is None:
            return {"ok": True, "cancelled": None}
        log_event(
            "reactivation_cancelled",
            actor=actor,
            conversation_id=item["conversation_id"],
            reactivation_id=item["id"],
            reason=reason,
        )
        self.history.add_event(
            item["conversation_id"],
            "reactivation_cancelled",
            {"id": item["id"], "actor": actor, "reason": reason},
        )
        self._reactivation_wakeup.set()
        return {"ok": True, "cancelled": self._public_reactivation(item)}

    def _reactivation_supervisor(self) -> None:
        while True:
            try:
                self._reactivation_daemon()
            except Exception as exc:  # noqa: BLE001
                log_event(
                    "reactivation_daemon_error",
                    error=f"{exc.__class__.__name__}: {exc}",
                )
                self._reactivation_wakeup.wait(1.0)
                self._reactivation_wakeup.clear()

    def _reactivation_daemon(self) -> None:
        while True:
            pending = self.history.pending_reactivation()
            if pending is None:
                timeout = 30.0
            else:
                timeout = max(0.0, min(30.0, pending["fire_at"] - time.time()))
            self._reactivation_wakeup.wait(timeout)
            self._reactivation_wakeup.clear()
            if pending is not None and pending["fire_at"] <= time.time():
                with self._lock:
                    conversation_busy = any(
                        turn.conversation_id == pending["conversation_id"]
                        and turn.done_at is None
                        for turn in self.turns.values()
                    )
                if conversation_busy:
                    self._reactivation_wakeup.wait(1.0)
                    self._reactivation_wakeup.clear()
                    continue
            item = self.history.claim_due_reactivation(time.time())
            if item is None:
                continue
            if not self.history.reactivation_settings()["enabled"]:
                self.history.finish_reactivation(
                    item["id"], "cancelled", "disabled"
                )
                log_event(
                    "reactivation_cancelled",
                    actor="system",
                    conversation_id=item["conversation_id"],
                    reactivation_id=item["id"],
                    reason="disabled",
                )
                continue
            life = lifecycle.status()
            if life["dead"] or not self.history.conversation_exists(
                item["conversation_id"]
            ):
                error = "TTL expired" if life["dead"] else "conversation missing"
                self.history.finish_reactivation(item["id"], "failed", error)
                log_event(
                    "reactivation_failed",
                    conversation_id=item["conversation_id"],
                    reactivation_id=item["id"],
                    error=error,
                )
                continue
            result = self.start_streaming_message(
                item["conversation_id"],
                item["prompt"],
                user_meta={
                    "auto_reactivation": True,
                    "reactivation_id": item["id"],
                    "reason": item["reason"],
                },
            )
            if result.get("error"):
                error = str(result["error"])
                self.history.finish_reactivation(item["id"], "failed", error)
                log_event(
                    "reactivation_failed",
                    conversation_id=item["conversation_id"],
                    reactivation_id=item["id"],
                    error=error,
                )
                continue
            self.history.finish_reactivation(item["id"], "fired")
            self.history.add_event(
                item["conversation_id"],
                "reactivation_fired",
                {
                    "id": item["id"],
                    "fire_at": item["fire_at"],
                    "reason": item["reason"],
                    "turn_id": result["turn_id"],
                },
            )
            log_event(
                "reactivation_fired",
                conversation_id=item["conversation_id"],
                reactivation_id=item["id"],
                turn_id=result["turn_id"],
            )
    def approve(self, tool_call_id: str, decision: str,
                phrase: str | None = None) -> dict[str, Any]:
        with self._lock:
            pending = self.pending.get(tool_call_id)
        if not pending:
            return {"error": "Unknown or already-handled tool call."}
        conv_id = pending["conversation_id"]
        tool = pending["tool"]
        args = pending["args"]
        classification = pending["classification"]
        audit_id = str(pending.get("id") or tool_call_id)
        call_id = str(pending.get("tool_call_id") or tool_call_id)

        def pop_pending() -> dict[str, Any] | None:
            with self._lock:
                current = self.pending.pop(audit_id, None)
                if current is None:
                    current = self.pending.pop(call_id, None)
                if current:
                    self.pending.pop(str(current.get("id", "")), None)
                    self.pending.pop(str(current.get("tool_call_id", "")), None)
                return current

        if decision != "approve":
            if pop_pending() is None:
                return {"error": "Unknown or already-handled tool call."}
            log_tool_call(tool=tool, classification=classification,
                          decision="denied",
                          args_summary=_summarize(args),
                          conversation_id=conv_id, tool_call_id=call_id,
                          approval_id=audit_id)
            self.history.add_event(conv_id, "tool_observation", {
                "tool_call_id": call_id, "tool": tool,
                "ok": False, "decision": "denied",
                "error": "operator denied",
            })
            return {"status": "denied", "tool_call_id": call_id}

        if pending["requires_phrase"]:
            policy = load_policy()
            if (phrase or "").strip() != policy.destructive_confirmation:
                log_tool_call(tool=tool, classification=classification,
                              decision="denied",
                              args_summary=_summarize(args),
                              error="missing or wrong confirmation phrase",
                              conversation_id=conv_id, tool_call_id=call_id,
                              approval_id=audit_id)
                return {"status": "awaiting_confirmation",
                        "error": "Destructive action requires the exact "
                                 f"confirmation phrase: "
                                 f"{policy.destructive_confirmation!r}"}

        if pop_pending() is None:
            return {"error": "Unknown or already-handled tool call."}
        try:
            result = self._dispatch_tool(tool, args, conv_id)
            self.history.add_event(conv_id, "tool_observation", {
                "tool_call_id": call_id, "tool": tool,
                "ok": True, "result": _truncate_obs(result),
                "decision": "approved",
            })
            log_tool_call(
                tool=tool, classification=classification, decision="approved",
                args_summary=_summarize(args),
                exit_code=result.get("exit_code") if isinstance(result, dict) else None,
                duration_ms=result.get("duration_ms") if isinstance(result, dict) else None,
                stdout=(result.get("stdout") if isinstance(result, dict) else None),
                stderr=(result.get("stderr") if isinstance(result, dict) else None),
                conversation_id=conv_id, tool_call_id=call_id,
                approval_id=audit_id,
            )
            return {"status": "approved", "tool_call_id": call_id,
                    "result": result}
        except Exception as exc:  # noqa: BLE001
            self.history.add_event(conv_id, "tool_observation", {
                "tool_call_id": call_id, "tool": tool,
                "ok": False, "error": str(exc),
            })
            log_tool_call(tool=tool, classification=classification,
                          decision="error",
                          args_summary=_summarize(args), error=str(exc),
                          conversation_id=conv_id, tool_call_id=call_id,
                          approval_id=audit_id)
            return {"status": "error", "tool_call_id": call_id,
                    "error": str(exc)}

    # ---- command support APIs ----
    def conversation_payload(self, conversation_id: int) -> dict[str, Any]:
        conv = self.history.get_conversation(conversation_id)
        if conv is None:
            raise KeyError(f"No conversation #{conversation_id}.")
        return {
            "conversation": conv,
            "messages": self.history.get_messages(conversation_id),
            "events": self.history.get_events(conversation_id),
        }

    def set_conversation_title(self, conversation_id: int,
                               title: str) -> dict[str, Any]:
        cleaned = " ".join(title.strip().split())[:120]
        if not cleaned:
            return {"error": "title is required"}
        if not self.history.set_title(conversation_id, cleaned):
            return {"error": f"No conversation #{conversation_id}."}
        log_event("conversation_title", conversation_id=conversation_id,
                  title=cleaned)
        return {"ok": True, "conversation_id": conversation_id,
                "title": cleaned}

    def branch_conversation(self, conversation_id: int,
                            title: str = "") -> dict[str, Any]:
        # Branching is a SQLite copy only. It must not imply rollback of
        # host mutations, approvals, or audit records from the source.
        if not self.history.conversation_exists(conversation_id):
            return {"error": f"No conversation #{conversation_id}."}
        chosen = " ".join(title.strip().split())[:120]
        if not chosen:
            chosen = f"Branch of #{conversation_id}"
        try:
            new_id = self.history.copy_conversation(conversation_id,
                                                    title=chosen)
        except KeyError as exc:
            return {"error": str(exc)}
        log_event("conversation_branch", conversation_id=conversation_id,
                  new_conversation_id=new_id, title=chosen)
        return {"ok": True, "conversation_id": new_id, "title": chosen}

    def retry_conversation(self, conversation_id: int) -> dict[str, Any]:
        # Retry starts a new branch before the last user message, then
        # returns that prompt for the browser to submit again. The source
        # transcript and audit trail remain intact.
        last_user = self.history.latest_user_message(conversation_id)
        if last_user is None:
            return {"error": "No user message to retry."}
        title = f"Retry of #{conversation_id}"
        try:
            new_id = self.history.copy_conversation(
                conversation_id,
                title=title,
                before_message_id=int(last_user["id"]),
            )
        except KeyError as exc:
            return {"error": str(exc)}
        prompt = str(last_user["content"])
        log_event("conversation_retry", conversation_id=conversation_id,
                  new_conversation_id=new_id,
                  retried_message_id=last_user["id"])
        return {"ok": True, "conversation_id": new_id, "title": title,
                "prompt": prompt,
                "warning": ("Created a retry branch. The original "
                            "conversation and audit log were preserved.")}

    def undo_conversation(self, conversation_id: int,
                          turns: int = 1) -> dict[str, Any]:
        # Undo is deliberately conversation-only. It creates a branch
        # before the selected user turn instead of deleting messages or
        # pretending tool side effects were reverted.
        count = max(turns, 1)
        cutoff = self.history.latest_user_message(conversation_id,
                                                  offset=count - 1)
        if cutoff is None:
            return {"error": f"Conversation #{conversation_id} has fewer "
                             f"than {count} user turn(s)."}
        title = f"Undo {count} turn{'s' if count != 1 else ''} from #{conversation_id}"
        try:
            new_id = self.history.copy_conversation(
                conversation_id,
                title=title,
                before_message_id=int(cutoff["id"]),
            )
        except KeyError as exc:
            return {"error": str(exc)}
        log_event("conversation_undo", conversation_id=conversation_id,
                  new_conversation_id=new_id, turns=count,
                  cutoff_message_id=cutoff["id"])
        return {
            "ok": True,
            "conversation_id": new_id,
            "title": title,
            "warning": (
                "Created a rewind branch only. Any host changes, tool "
                "runs, approvals, and audit entries from the original "
                "conversation remain real and unchanged."
            ),
        }

    def compress_conversation(self, conversation_id: int) -> dict[str, Any]:
        # Local deterministic summary: no model call, no deletion of raw
        # messages, and future turns inject only the latest summary.
        if not self.history.conversation_exists(conversation_id):
            return {"error": f"No conversation #{conversation_id}."}
        messages = [
            m for m in self.history.get_messages(conversation_id)
            if m["role"] in {"user", "assistant"}
        ]
        if not messages:
            return {"error": "No conversation content to summarize."}
        summary = _local_summary(messages)
        self.history.add_message(conversation_id, "system", summary,
                                 {"kind": "summary"})
        self.history.add_event(conversation_id, "conversation_summary",
                               {"summary": summary})
        log_event("conversation_summary", conversation_id=conversation_id,
                  summary_chars=len(summary))
        return {"ok": True, "conversation_id": conversation_id,
                "summary": summary}

    def pending_calls(self) -> list[dict[str, Any]]:
        policy = load_policy()
        with self._lock:
            unique = {
                str(item.get("id")): item
                for item in self.pending.values()
                if item.get("id")
            }
        out: list[dict[str, Any]] = []
        for item in unique.values():
            out.append({
                "id": item.get("id"),
                "tool_call_id": item.get("tool_call_id"),
                "conversation_id": item.get("conversation_id"),
                "tool": item.get("tool"),
                "args": _summarize(item.get("args")),
                "classification": item.get("classification"),
                "requires_phrase": bool(item.get("requires_phrase")),
                "confirm_phrase": (
                    policy.destructive_confirmation
                    if item.get("requires_phrase") else None
                ),
            })
        out.sort(key=lambda p: str(p.get("id") or ""))
        return out

    def config_info(self) -> dict[str, Any]:
        # Redacted runtime metadata for slash commands. Presence bits are
        # fine; secret values and secret file contents are never returned.
        provider, status = provider_status()
        return {
            "agent_user": AGENT_USER,
            "host": DEFAULT_HOST,
            "port": DEFAULT_PORT,
            "zombie_dir": os.environ.get("ZOMBIE_DIR", "/opt/ai-zombie"),
            "provider": provider,
            "provider_status": status,
            "policy_path": str(POLICY_PATH),
            "history_db": str(self.history.path),
            "audit_log": str(AUDIT_PATH),
            "skill_dirs": [str(p) for p in skill_loader.default_skill_dirs()],
            "secrets": "configured" if SECRETS_FILE.exists() else "missing",
        }

    def profile_info(self) -> dict[str, Any]:
        facts = machine_facts()
        zombie_dir = os.environ.get("ZOMBIE_DIR", "/opt/ai-zombie")
        return {
            "agent_user": AGENT_USER,
            "hostname": facts.get("hostname", socket.gethostname()),
            "os": facts.get("os", ""),
            "kernel": facts.get("kernel", ""),
            "arch": facts.get("arch", ""),
            "loopback_only": True,
            "chat_url": f"http://{DEFAULT_HOST}:{DEFAULT_PORT}/",
            "zombie_dir": zombie_dir,
            "history_db": str(self.history.path),
        }

    def whoami_info(self) -> dict[str, Any]:
        facts = machine_facts()
        return {
            "agent_user": AGENT_USER,
            "hostname": facts.get("hostname", socket.gethostname()),
            "chat_url": f"http://{DEFAULT_HOST}:{DEFAULT_PORT}/",
            "loopback_only": True,
        }

    def policy_info(self) -> dict[str, Any]:
        policy = load_policy()
        return {
            "path": str(POLICY_PATH),
            "default_class": policy.default_class,
            "destructive_confirmation": "configured",
            "classes": {
                name: {
                    "approval": cls.approval,
                    "confirm_phrase": cls.confirm_phrase,
                    "description": cls.description,
                }
                for name, cls in policy.classes.items()
            },
            "sudo_allow_list": list(policy.sudo_allow_list),
            "tool_classes": dict(policy.tool_classes),
            "rule_count": len(policy.rules),
            "agent": {
                "max_tool_calls_per_turn": policy.max_tool_calls_per_turn,
                "max_elevated_calls_per_turn": policy.max_elevated_calls_per_turn,
                "max_turn_seconds": policy.max_turn_seconds,
            },
        }

    def skills_info(self) -> dict[str, Any]:
        skills = skill_loader.load_skills()
        return {"skills": [
            {"name": s.name, "path": str(s.path),
             "triggers": list(s.triggers)}
            for s in skills
        ]}

    def skill_info(self, name: str) -> dict[str, Any]:
        wanted = name.strip()
        if not wanted.replace("-", "").replace("_", "").isalnum():
            return {"error": "bad skill name"}
        for skill in skill_loader.load_skills():
            if skill.name == wanted:
                return {
                    "name": skill.name,
                    "path": str(skill.path),
                    "triggers": list(skill.triggers),
                    "content": skill.read(),
                }
        return {"error": f"No skill named {wanted!r}."}

    # ---- model catalogue / selection ----
    def models_info(self) -> dict[str, Any]:
        """List the models the active provider exposes for ``/model``.

        Returns ``{provider, current, models}`` where ``models`` is a
        list of ``{id, name, reasoning, context_window}``. Surfaces an
        ``error`` (alongside any data resolved so far) when no provider
        is configured or the bridge cannot be reached, so the UI can
        show a useful message rather than a bare failure.
        """
        try:
            provider = providers.active_provider()
        except providers.NoProviderConfigured as exc:
            return {"error": str(exc)}
        current = providers.current_model()
        try:
            models = providers.list_models()
        except providers.ProviderError as exc:
            return {"provider": provider, "current": current,
                    "models": [], "error": str(exc)}
        return {"provider": provider, "current": current, "models": models}

    def set_model(self, model: str) -> dict[str, Any]:
        """Select ``model`` for the active provider for this process."""
        try:
            provider, chosen = providers.set_active_model(model)
        except providers.NoProviderConfigured as exc:
            return {"error": str(exc)}
        except ValueError as exc:
            return {"error": str(exc)}
        log_event("model_selected", provider=provider, model=chosen)
        return {
            "ok": True,
            "provider": provider,
            "model": chosen,
            "address": (
                providers.lmstudio_address()
                if provider == "lmstudio" else None
            ),
        }

    def provider_info(self) -> dict[str, Any]:
        """Return cheap provider status for the chat ``/status`` command."""
        name, status = providers.provider_status()
        return {
            "provider": name,
            "status": status,
            "lmstudio_address": (
                providers.lmstudio_address() if name == "lmstudio" else None
            ),
        }

    def status_info(self) -> dict[str, Any]:
        """Run an explicit provider probe and return a full proof-of-life report."""
        provider = self.provider_info()
        with self._status_probe_lock:
            cached_at, cached_probe = self._status_probe_cache
            if (
                cached_probe
                and time.monotonic() - cached_at < STATUS_PROBE_CACHE_SECONDS
            ):
                connectivity = {**cached_probe, "cached": True}
            else:
                probe_started = time.monotonic()
                try:
                    connectivity = providers.probe_provider()
                except providers.ProviderError as exc:
                    connectivity = {
                        "ok": False,
                        "latency_ms": round(
                            (time.monotonic() - probe_started) * 1000
                        ),
                        "error": str(exc),
                    }
                connectivity["checked_at"] = time.time()
                connectivity["cached"] = False
                self._status_probe_cache = (
                    time.monotonic(), dict(connectivity)
                )
        try:
            model = providers.current_model()
        except providers.ProviderError:
            model = None
        with self._lock:
            runtime = {
                "server_uptime_seconds": max(0, int(time.time() - self.started_at)),
                "active_turns": sum(
                    1 for turn in self.turns.values() if turn.done_at is None
                ),
                "retained_turns": len(self.turns),
                "pending_approvals": len(self.pending),
                "authenticated_sessions": len(self.sessions),
            }
        log_event(
            "status_probe",
            provider=provider.get("provider"),
            ok=connectivity.get("ok", False),
            latency_ms=connectivity.get("latency_ms"),
        )
        return {
            "ok": True,
            "checked_at": time.time(),
            "provider": provider.get("provider"),
            "model": model,
            "provider_status": provider.get("status"),
            "connectivity": connectivity,
            "machine": machine_facts(),
            "resources": system_health(),
            "lifecycle": lifecycle.status(),
            "runtime": runtime,
            "usage": self.history.usage_stats(),
        }

    def local_apis_info(self) -> dict[str, Any]:
        """List discovered local OpenAI-compatible API URLs."""
        try:
            with self._lmstudio_lock:
                servers = providers.scan_lmstudio()
        except providers.ProviderError as exc:
            log_event("lmstudio_scan_failed", error=str(exc))
            return {"error": str(exc)}
        log_event("lmstudio_scan", servers_found=len(servers))
        return {
            "current": providers.lmstudio_base_url(),
            "locals": [server["base_url"] for server in servers],
        }

    def set_local_api(self, base_url: str) -> dict[str, Any]:
        """Rescan, verify, and activate a local OpenAI-compatible API URL."""
        try:
            with self._lmstudio_lock:
                servers = providers.scan_lmstudio()
                selected = next(
                    (
                        server
                        for server in servers
                        if server.get("base_url") == base_url
                    ),
                    None,
                )
                if selected is None:
                    return {"error": f"No local API found at {base_url}."}
                provider, model, address = providers.activate_lmstudio(selected)
        except providers.ProviderError as exc:
            log_event("lmstudio_scan_failed", error=str(exc))
            return {"error": str(exc)}
        log_event(
            "lmstudio_selected", provider=provider, model=model,
            address=address, servers_found=len(servers),
        )
        return {
            "ok": True,
            "provider": provider,
            "model": model,
            "address": address,
            "url": selected["base_url"],
        }


def _summarize(args: Any) -> dict[str, Any]:
    """Return a small, audit-safe summary of tool args."""
    if not isinstance(args, dict):
        return {"_": repr(args)[:120]}
    out: dict[str, Any] = {}
    for k, v in args.items():
        if isinstance(v, str):
            out[k] = v if len(v) <= 200 else v[:200] + "…"
        elif isinstance(v, (int, float, bool)) or v is None:
            out[k] = v
        elif isinstance(v, list):
            out[k] = [str(x)[:80] for x in v[:8]]
        else:
            out[k] = repr(v)[:120]
    return out


def _write_password_hash(password: str | None) -> str | None:
    """Update ``ZOMBIE_ADMIN_PASSWORD_HASH`` in the secrets file."""
    existing: list[str] = []
    try:
        existing = SECRETS_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        pass
    lines = [
        line for line in existing
        if not line.lstrip().startswith(f"{auth.HASH_ENV}=")
        and not line.lstrip().startswith(f"export {auth.HASH_ENV}=")
    ]
    stored = auth.hash_password(password) if password is not None else None
    if stored:
        lines.append(f"{auth.HASH_ENV}={stored}")
    SECRETS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SECRETS_FILE.with_name(SECRETS_FILE.name + ".tmp")
    content = ("\n".join(lines).rstrip() + "\n") if lines else ""
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, SECRETS_FILE)
    try:
        os.chmod(SECRETS_FILE, 0o600)
    except OSError:  # pragma: no cover - best effort on odd filesystems
        pass
    return stored


def _ttl_seconds_from_payload(
    data: dict[str, Any], *, reset: bool = False
) -> float:
    if "duration" in data:
        return lifecycle.parse_duration(
            str(data.get("duration") or ""),
            default_seconds=(lifecycle.DEFAULT_TTL_SECONDS if reset else None),
        )
    if "seconds" in data:
        try:
            seconds = float(data.get("seconds"))
        except (TypeError, ValueError) as exc:
            raise ValueError("seconds must be a number") from exc
        if seconds <= 0:
            raise ValueError("duration must be greater than zero")
        return seconds
    if "days" in data:
        try:
            days = float(data.get("days"))
        except (TypeError, ValueError) as exc:
            raise ValueError("days must be a number") from exc
        if days <= 0:
            raise ValueError("duration must be greater than zero")
        return days * lifecycle.DAY_SECONDS
    if reset:
        return float(lifecycle.DEFAULT_TTL_SECONDS)
    raise ValueError("duration is required")


def _clip_text(text: str, limit: int = 240) -> str:
    compact = " ".join(str(text).split())
    if len(compact) <= limit:
        return compact
    return compact[:limit - 1].rstrip() + "..."


def _local_summary(messages: list[dict[str, Any]], limit: int = 12) -> str:
    """Create a deterministic, local summary without spending tokens."""
    total = len(messages)
    head = messages[:3]
    tail = messages[-max(limit - len(head), 0):]
    selected: list[dict[str, Any]] = []
    seen: set[int] = set()
    for msg in head + tail:
        mid = int(msg.get("id") or 0)
        if mid in seen:
            continue
        seen.add(mid)
        selected.append(msg)
    lines = [
        f"Local summary of {total} user/assistant message"
        f"{'' if total == 1 else 's'}."
    ]
    if total > len(selected):
        lines.append(
            f"Middle {total - len(selected)} message"
            f"{'' if total - len(selected) == 1 else 's'} omitted."
        )
    for msg in selected:
        role = str(msg.get("role") or "?").capitalize()
        lines.append(f"- {role}: {_clip_text(str(msg.get('content') or ''))}")
    return "\n".join(lines)


def _truncate_obs(result: Any, limit: int = 4000) -> Any:
    """Bound observation size before persisting to history.

    The audit log records SHA-256 digests of the full output; the
    history is for UI replay only and should not balloon.
    """
    if not isinstance(result, dict):
        return result
    out = dict(result)
    for key in ("stdout", "stderr", "content"):
        val = out.get(key)
        if isinstance(val, str) and len(val) > limit:
            out[key] = val[:limit] + f"\n…[truncated, {len(val) - limit} more chars]"
    return out


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

INDEX_HTML_PATH = HERE / "templates" / "index.html"


def _provider_banner(name: str, status: str) -> str:
    """Return the compact model label shown in the chat header."""
    if name != "none" and status.startswith("model ") and "not set" not in status:
        return status[len("model "):]
    return status


def _render_index(app: App) -> bytes:
    facts = machine_facts()
    # FIX-3-07: avoid constructing a fresh SDK client on every GET /.
    name, status = provider_status()
    banner = _provider_banner(name, status)
    text = INDEX_HTML_PATH.read_text(encoding="utf-8")
    text = text.replace("{{HOSTNAME}}", html.escape(facts.get("hostname", "?")))
    text = text.replace("{{USERNAME}}", html.escape(AGENT_USER))
    text = text.replace("{{PROVIDER_STATUS}}", html.escape(banner))
    text = text.replace("{{VERSION}}", html.escape(app_version()))
    examples = (HERE / "examples.md").read_text(encoding="utf-8") if (HERE / "examples.md").exists() else ""
    text = text.replace("{{EXAMPLES}}", html.escape(examples))
    return text.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    app: App  # injected by make_handler

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Quieter default logging; the audit log is the source of truth.
        return

    # ---- helpers ----
    def _send_json(self, payload: Any, status: int = 200,
                   extra_headers: list[tuple[str, str]] | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers or ():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _cookies(self) -> dict[str, str]:
        raw = self.headers.get("Cookie") if self.headers else None
        jar: dict[str, str] = {}
        if not raw:
            return jar
        for chunk in raw.split(";"):
            name, _, value = chunk.strip().partition("=")
            if name:
                jar[name] = value
        return jar

    def _session_token(self) -> str | None:
        return self._cookies().get("zombie_session")

    def _authenticated(self) -> bool:
        return self.app.session_valid(self._session_token())

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        return data if isinstance(data, dict) else {}

    def _path_parts(self) -> list[str]:
        path = self.path.split("?", 1)[0]
        return [unquote(p) for p in path.strip("/").split("/") if p]

    def _write_sse(self, event: str, payload: dict[str, Any]) -> bool:
        try:
            self.wfile.write(f"event: {event}\n".encode("utf-8"))
            self.wfile.write(
                b"data: " + json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n\n"
            )
            flush = getattr(self.wfile, "flush", None)
            if callable(flush):
                flush()
            return True
        except (BrokenPipeError, ConnectionError, OSError):
            return False

    def _stream_turn(self, turn_id: str) -> None:
        state = self.app.attach_turn_stream(turn_id)
        if state is None:
            existing = self.app.get_turn_stream(turn_id)
            if existing and existing.final_payload is not None:
                event = "turn_error" if existing.final_payload.get("error") else "turn_done"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self._write_sse(event, existing.final_payload)
                return
            self._send_json({"error": "unknown or already attached stream"}, 404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        while True:
            try:
                event, payload = state.queue.get(timeout=STREAM_KEEPALIVE_SECONDS)
            except queue.Empty:
                try:
                    self.wfile.write(b": keepalive\n\n")
                    flush = getattr(self.wfile, "flush", None)
                    if callable(flush):
                        flush()
                except (BrokenPipeError, ConnectionError, OSError):
                    self.app.detach_turn_stream(turn_id)
                    return
                continue
            if not self._write_sse(event, payload):
                self.app.detach_turn_stream(turn_id)
                return
            if event in {"turn_done", "turn_error"}:
                return

    # ---- routes ----
    # Endpoints reachable without a valid login. Everything else is
    # gated when a password hash is configured (``auth.auth_required``).
    _PUBLIC_PATHS = {"/", "/index.html", "/api/session", "/api/login",
                     "/api/logout"}

    def _guard(self) -> bool:
        """Return True if the request may proceed; otherwise send 401."""
        path = self.path.split("?", 1)[0]
        if path in self._PUBLIC_PATHS:
            return True
        if self._authenticated():
            return True
        self._send_json({"error": "Authentication required.",
                         "authenticated": False}, 401)
        return False

    def do_GET(self) -> None:  # noqa: N802
        parts = self._path_parts()
        if not self._guard():
            return
        if self.path == "/" or self.path == "/index.html":
            body = _render_index(self.app)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/session":
            self._send_json(self.app.session_info(self._session_token()))
            return
        if len(parts) == 3 and parts[:2] == ["api", "stream"]:
            self._stream_turn(parts[2])
            return
        if self.path == "/api/ttl":
            self._send_json(self.app.ttl_status())
            return
        if self.path == "/api/reactivation":
            self._send_json(self.app.reactivation_info())
            return
        if self.path == "/api/health":
            self._send_json({
                "ok": True,
                "facts": machine_facts(),
                "provider": self.app.provider_info(),
            })
            return
        if self.path == "/api/version":
            self._send_json(version_info(check_latest=True))
            return
        if self.path == "/api/conversations":
            self._send_json({"conversations": self.app.history.list_conversations()})
            return
        if len(parts) == 3 and parts[:2] == ["api", "conversation"]:
            try:
                cid = int(parts[2])
            except ValueError:
                self._send_json({"error": "bad id"}, 400)
                return
            if not self.app.history.conversation_exists(cid):
                self._send_json({"error": f"No conversation #{cid}."}, 404)
                return
            self._send_json(self.app.conversation_payload(cid))
            return
        if self.path == "/api/audit":
            self._send_json({"entries": audit_tail(50)})
            return
        if self.path == "/api/tools":
            self._send_json({"tools": [
                {"name": n, "classification": spec["classification"],
                 "description": spec.get("description", "")}
                for n, spec in tools_mod.TOOL_REGISTRY.items()
            ]})
            return
        if self.path == "/api/models":
            self._send_json(self.app.models_info())
            return
        if self.path == "/api/locals":
            self._send_json(self.app.local_apis_info())
            return
        if self.path == "/api/status":
            self._send_json(self.app.status_info())
            return
        if self.path == "/api/config":
            self._send_json(self.app.config_info())
            return
        if self.path == "/api/profile":
            self._send_json(self.app.profile_info())
            return
        if self.path == "/api/whoami":
            self._send_json(self.app.whoami_info())
            return
        if self.path == "/api/policy":
            self._send_json(self.app.policy_info())
            return
        if self.path == "/api/skills":
            self._send_json(self.app.skills_info())
            return
        if len(parts) == 3 and parts[:2] == ["api", "skill"]:
            data = self.app.skill_info(parts[2])
            self._send_json(data, 404 if data.get("error") else 200)
            return
        if self.path == "/api/pending":
            self._send_json({"pending": self.app.pending_calls()})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        parts = self._path_parts()
        if self.path == "/api/login":
            data = self._read_json()
            result = self.app.login(str(data.get("password") or ""))
            if not result:
                self._send_json({"error": "Incorrect password."}, 401)
                return
            cookie = (
                f"zombie_session={result['token']}; HttpOnly; "
                "SameSite=Strict; Path=/"
            )
            self._send_json({"ok": True}, extra_headers=[("Set-Cookie", cookie)])
            return
        if self.path == "/api/logout":
            self.app.logout(self._session_token())
            expired = ("zombie_session=; HttpOnly; SameSite=Strict; Path=/; "
                       "Max-Age=0")
            self._send_json({"ok": True}, extra_headers=[("Set-Cookie", expired)])
            return
        if not self._guard():
            return
        if self.path == "/api/ttl":
            data = self._read_json()
            if data.get("die") is True:
                self._send_json(self.app.ttl_die())
                return
            try:
                seconds = _ttl_seconds_from_payload(
                    data, reset=bool(data.get("reset"))
                )
            except ValueError as exc:
                self._send_json({"error": str(exc)}, 400)
                return
            result = (
                self.app.ttl_reset_seconds(seconds)
                if data.get("reset") else self.app.ttl_set_seconds(seconds)
            )
            self._send_json(result, 410 if result.get("dead") and
                            result.get("error") else 200)
            return
        if self.path == "/api/reactivation":
            data = self._read_json()
            if data.get("cancel") is True:
                self._send_json(self.app.cancel_reactivation())
                return
            enabled = data.get("enabled")
            if enabled is not None and not isinstance(enabled, bool):
                self._send_json({"error": "enabled must be true or false"}, 400)
                return

            def optional_seconds(name: str) -> int | None:
                value = data.get(name)
                if value is None:
                    return None
                if isinstance(value, bool) or not isinstance(value, int):
                    raise ValueError(f"{name} must be an integer")
                return value

            try:
                minimum = optional_seconds("minimum_seconds")
                maximum = optional_seconds("maximum_seconds")
                if data.get("minimum") is not None:
                    minimum = int(lifecycle.parse_duration(str(data["minimum"])))
                if data.get("maximum") is not None:
                    maximum = int(lifecycle.parse_duration(str(data["maximum"])))
            except ValueError as exc:
                self._send_json({"error": str(exc)}, 400)
                return
            result = self.app.configure_reactivation(
                enabled=enabled,
                minimum_seconds=minimum,
                maximum_seconds=maximum,
            )
            self._send_json(result, 400 if result.get("error") else 200)
            return
        if self.path == "/api/password":
            data = self._read_json()
            password = str(data.get("password") or "")
            self._send_json(self.app.set_password(password))
            return
        if self.path == "/api/message":
            data = self._read_json()
            prompt = (data.get("prompt") or "").strip()
            conv_id = data.get("conversation_id")
            if not prompt:
                self._send_json({"error": "empty prompt"}, 400)
                return
            try:
                cid = int(conv_id) if conv_id else None
            except (TypeError, ValueError):
                cid = None
            if data.get("stream") is True:
                result = self.app.start_streaming_message(cid, prompt)
                self._send_json(result, 410 if result.get("dead") else 200)
                return
            result = self.app.post_message(cid, prompt)
            self._send_json(result, 410 if result.get("dead") else 200)
            return
        if self.path == "/api/approve":
            data = self._read_json()
            # Accept the new ``tool_call_id`` field; reject the legacy
            # ``proposal_id`` so callers cannot accidentally drive the
            # removed code path.
            tcid = data.get("tool_call_id")
            decision = data.get("decision", "deny")
            phrase = data.get("phrase")
            if not tcid:
                self._send_json({"error": "missing tool_call_id"}, 400)
                return
            self._send_json(self.app.approve(tcid, decision, phrase))
            return
        if self.path == "/api/model":
            data = self._read_json()
            model = (data.get("model") or "").strip()
            if not model:
                self._send_json({"error": "missing model"}, 400)
                return
            self._send_json(self.app.set_model(model))
            return
        if self.path == "/api/local":
            data = self._read_json()
            base_url = (data.get("url") or "").strip()
            if not base_url:
                self._send_json({"error": "Local API URL is required."}, 400)
                return
            self._send_json(self.app.set_local_api(base_url))
            return
        if len(parts) == 4 and parts[:2] == ["api", "conversation"]:
            try:
                cid = int(parts[2])
            except ValueError:
                self._send_json({"error": "bad id"}, 400)
                return
            data = self._read_json()
            action = parts[3]
            if action == "title":
                title = str(data.get("title") or "")
                result = self.app.set_conversation_title(cid, title)
                if result.get("error"):
                    status = (
                        400 if result["error"] == "title is required" else 404
                    )
                else:
                    status = 200
                self._send_json(result, status)
                return
            if action == "branch":
                title = str(data.get("title") or "")
                result = self.app.branch_conversation(cid, title)
                self._send_json(result, 404 if result.get("error") else 200)
                return
            if action == "retry":
                result = self.app.retry_conversation(cid)
                self._send_json(result, 404 if result.get("error") else 200)
                return
            if action == "undo":
                raw_turns = data.get("turns", 1)
                try:
                    turns = int(raw_turns)
                except (TypeError, ValueError):
                    self._send_json({"error": "turns must be an integer"}, 400)
                    return
                result = self.app.undo_conversation(cid, turns)
                self._send_json(result, 404 if result.get("error") else 200)
                return
            if action == "compress":
                result = self.app.compress_conversation(cid)
                self._send_json(result, 404 if result.get("error") else 200)
                return
        self.send_error(HTTPStatus.NOT_FOUND)


def make_handler(app: App) -> type[Handler]:
    # FIX-3-20: return a fresh subclass per App rather than mutating
    # ``Handler.app`` (a class attribute), so two App instances in the
    # same process do not stomp on each other.
    class _Handler(Handler):
        pass
    _Handler.app = app
    return _Handler


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ubuntu Zombie chat service")
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help="bind address (default: %(default)s)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="bind port (default: %(default)s)")
    parser.add_argument("--render-append-system", action="store_true",
                        help="Print the rendered pi-mono append-system-prompt "
                             "(used by the installer) and exit.")
    args = parser.parse_args(argv)

    if args.render_append_system:
        facts = ", ".join(f"{k}={v}" for k, v in machine_facts().items())
        sys.stdout.write(render_append_system(facts))
        return 0

    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        # Loopback-only is a security invariant.
        print(f"refusing to bind to non-loopback host: {args.host}", file=sys.stderr)
        return 2

    # FIX-3-08: the safe-mode check only stats the secrets file; run it
    # *before* parsing the contents into os.environ so a refusal-to-
    # start path cannot leak the secrets (e.g. via a future ExecStopPost
    # hook that dumps the environment).
    assert_secrets_safe()
    load_secrets_env()
    app = App()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(app))
    log_event("service_start", host=args.host, port=args.port,
              pid=os.getpid())
    print(f"ubuntu-zombie chat listening on http://{args.host}:{args.port}/",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        log_event("service_stop", pid=os.getpid())
        server.server_close()
        app.history.close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
