"""Ubuntu Zombie chat service.

A small loopback-only HTTP server that:

- serves a single-page chat UI;
- forwards prompts to the configured cloud provider;
- runs read-only diagnostic commands inline;
- asks for explicit approval before privileged or destructive commands;
- records every step in the JSON-lines audit log;
- persists conversations to SQLite.

The server binds to ``127.0.0.1`` only. Remote access is by SSH tunnel
over Tailscale; see ``CONFIGURATION.md``.
"""
from __future__ import annotations

import argparse
import getpass
import html
import json
import os
import platform
import re
import socket
import stat
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from audit import log_event, tail as audit_tail  # noqa: E402
from history import History  # noqa: E402
from policy import load_policy  # noqa: E402
from providers import (  # noqa: E402
    Message, NoProviderConfigured, ProviderError, provider_from_env,
    provider_status,
)
from runner import run as run_command  # noqa: E402

SECRETS_FILE = Path(os.environ.get("ZOMBIE_SECRETS", "/opt/ai-zombie/secrets/env"))
DEFAULT_PORT = int(os.environ.get("ZOMBIE_CHAT_PORT", "7878"))
DEFAULT_HOST = "127.0.0.1"


def _agent_account() -> str:
    """Return the local Linux account the chat service runs as.

    The installer sets ``ZOMBIE_USER`` (default ``zombie``) in the
    systemd unit so the chat service and its prompts can reference the
    real account name even when the operator picked a custom one. Fall
    back to the current process owner when the env var is unset (e.g.
    when running the service by hand for development).
    """
    value = os.environ.get("ZOMBIE_USER")
    if value:
        return value
    try:
        return getpass.getuser()
    except Exception:  # pragma: no cover - extremely defensive
        return "zombie"


AGENT_USER = _agent_account()

SYSTEM_PROMPT_TEMPLATE = """You are the AI Systems Administrator for an Ubuntu Desktop machine.

You operate as the local Linux user "{agent_user}", who has passwordless sudo.
Every privileged or mutating command you propose will be sent through
a policy gate that may require explicit operator approval before it
runs. Read-only diagnostics can be run automatically.

Style:
- Be concise. Prefer one short paragraph over many.
- When you want to inspect or change the machine, propose ONE shell
  command at a time inside a fenced ```bash block. Do not propose
  multiple unrelated commands in the same turn.
- Quote command output you have already received rather than guessing.
- Refuse and explain if asked to exfiltrate secrets, disable the audit
  log, or weaken the policy gate.

Machine facts (auto-collected): {facts}
"""


def render_system_prompt(facts: str) -> str:
    """Render the system prompt in a single ``.format`` call.

    FIX-3-19: the previous implementation called ``.format`` twice
    (once at module load with ``agent_user``, once per message with
    ``facts``), which required escaping any future ``{`` in the
    template and broke if ``AGENT_USER`` contained ``{``/``}``.
    """
    return SYSTEM_PROMPT_TEMPLATE.format(agent_user=AGENT_USER, facts=facts)


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
                val = val[1:]
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
    }
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                facts["os"] = line.split("=", 1)[1].strip().strip('"')
                break
    except OSError:
        pass
    return facts


# ---------------------------------------------------------------------------
# Command extraction
# ---------------------------------------------------------------------------

# FIX-3-09/FIX-3-24: accept optional whitespace, CRLF line endings, and
# a broader set of language tags (or none) on the opening fence.
_BASH_BLOCK = re.compile(
    r"```(?:bash|sh|shell|console|text)?[ \t]*\r?\n(.*?)```",
    re.DOTALL,
)


def _join_continuations(block: str) -> list[str]:
    """Yield logical shell commands from a fenced block.

    FIX-3-10 / FIX-3-12: previously each physical line in a block was
    treated as an independent command, which broke
    backslash-continuations and here-docs (the second line of
    ``cat <<EOF`` ran as a standalone shell statement). This helper
    joins trailing-``\\`` continuations and collapses any block that
    contains a ``<<`` here-doc into a single logical command sent
    through the policy gate as a unit. Per-line ``#`` filtering is
    only applied for the single-command shape so a leading shebang
    inside a multi-line script is preserved.
    """
    text = block.replace("\r\n", "\n").replace("\r", "\n")

    # Detect here-doc: treat the whole block as one command.
    if re.search(r"<<-?\s*['\"]?\w+['\"]?", text):
        joined = text.strip("\n")
        return [joined] if joined.strip() else []

    # Fold trailing-backslash continuations.
    folded_lines: list[str] = []
    buf = ""
    for line in text.split("\n"):
        if line.endswith("\\") and not line.endswith("\\\\"):
            buf += line[:-1]
            continue
        buf += line
        folded_lines.append(buf)
        buf = ""
    if buf:
        folded_lines.append(buf)

    out: list[str] = []
    for line in folded_lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Per-line ``#`` filter only when this really is a one-line
        # command (no continuations were folded into it). A folded
        # multi-line command may legitimately start with a shebang.
        if "\n" not in stripped and stripped.startswith("#"):
            continue
        out.append(stripped)
    return out


def extract_commands(text: str) -> list[str]:
    out: list[str] = []
    for block in _BASH_BLOCK.findall(text):
        out.extend(_join_continuations(block))
    return out


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------

class App:
    def __init__(self) -> None:
        self.history = History()
        self.pending: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def provider(self) -> Any:
        return provider_from_env()

    # ---- conversation flow ----
    def post_message(self, conv_id: int | None, prompt: str) -> dict[str, Any]:
        if not conv_id:
            conv_id = self.history.create_conversation()
        log_event("prompt", conversation_id=conv_id, prompt=prompt)
        self.history.add_message(conv_id, "user", prompt)

        try:
            provider = self.provider()
        except NoProviderConfigured as exc:
            err = str(exc)
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            return {"conversation_id": conv_id, "error": err}
        except ProviderError as exc:
            err = str(exc)
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            return {"conversation_id": conv_id, "error": err}

        facts = ", ".join(f"{k}={v}" for k, v in machine_facts().items())
        msgs = [Message(role="system", content=render_system_prompt(facts))]
        for m in self.history.get_messages(conv_id):
            if m["role"] in {"user", "assistant"}:
                msgs.append(Message(role=m["role"], content=m["content"]))

        try:
            reply = provider.chat(msgs)
        except Exception as exc:  # noqa: BLE001 - surface to user
            err = f"Provider call failed: {exc.__class__.__name__}: {exc}"
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            return {"conversation_id": conv_id, "error": err}

        self.history.add_message(conv_id, "assistant", reply,
                                 {"provider": provider.name, "model": provider.model})

        proposals = self._handle_commands(conv_id, reply)
        return {
            "conversation_id": conv_id,
            "reply": reply,
            "proposals": proposals,
            "messages": self.history.get_messages(conv_id),
        }

    def _handle_commands(self, conv_id: int, reply: str) -> list[dict[str, Any]]:
        proposals: list[dict[str, Any]] = []
        policy = load_policy()
        for cmd in extract_commands(reply):
            class_name = policy.classify(cmd)
            requires_approval = policy.requires_approval(class_name)
            requires_phrase = policy.requires_phrase(class_name)
            entry_id = log_event(
                "proposal",
                conversation_id=conv_id,
                command=cmd,
                action_class=class_name,
                requires_approval=requires_approval,
                requires_phrase=requires_phrase,
            )
            proposal = {
                "id": entry_id,
                "command": cmd,
                "action_class": class_name,
                "requires_approval": requires_approval,
                "requires_phrase": requires_phrase,
                "confirm_phrase": policy.destructive_confirmation if requires_phrase else None,
            }
            if not requires_approval:
                result = self._execute(conv_id, entry_id, cmd, class_name, auto=True)
                proposal["result"] = result
            else:
                with self._lock:
                    self.pending[entry_id] = {
                        "conversation_id": conv_id,
                        "command": cmd,
                        "action_class": class_name,
                        "requires_phrase": requires_phrase,
                    }
            proposals.append(proposal)
        return proposals

    def approve(self, proposal_id: str, decision: str,
                phrase: str | None = None) -> dict[str, Any]:
        with self._lock:
            pending = self.pending.pop(proposal_id, None)
        if not pending:
            return {"error": "Unknown or already-handled proposal."}
        conv_id = pending["conversation_id"]
        command = pending["command"]
        class_name = pending["action_class"]

        if decision != "approve":
            log_event("approval", proposal_id=proposal_id,
                      conversation_id=conv_id, decision="denied")
            self.history.add_message(
                conv_id, "system",
                f"Operator denied command: `{command}`",
                {"proposal_id": proposal_id, "decision": "denied"},
            )
            return {"status": "denied", "proposal_id": proposal_id}

        if pending["requires_phrase"]:
            policy = load_policy()
            if (phrase or "").strip() != policy.destructive_confirmation:
                log_event("approval", proposal_id=proposal_id,
                          conversation_id=conv_id, decision="denied",
                          reason="missing or wrong confirmation phrase")
                return {"status": "denied",
                        "error": "Destructive action requires the exact "
                                 f"confirmation phrase: {policy.destructive_confirmation!r}"}

        log_event("approval", proposal_id=proposal_id,
                  conversation_id=conv_id, decision="approved")
        result = self._execute(conv_id, proposal_id, command, class_name, auto=False)
        return {"status": "approved", "proposal_id": proposal_id, "result": result}

    def _execute(self, conv_id: int, proposal_id: str, command: str,
                 class_name: str, *, auto: bool) -> dict[str, Any]:
        res = run_command(command)
        log_event(
            "execution",
            proposal_id=proposal_id,
            conversation_id=conv_id,
            command=command,
            action_class=class_name,
            auto=auto,
            exit_code=res.exit_code,
            duration_ms=res.duration_ms,
            stdout_tail=res.stdout[-2000:],
            stderr_tail=res.stderr[-2000:],
            follow_up=res.follow_up,
        )
        payload = {
            "exit_code": res.exit_code,
            "stdout": res.stdout,
            "stderr": res.stderr,
            "duration_ms": res.duration_ms,
            "follow_up": res.follow_up,
        }
        self.history.add_message(
            conv_id,
            "system",
            f"$ {command}\n[exit {res.exit_code}]\n{res.stdout}{res.stderr}",
            {"proposal_id": proposal_id, "auto": auto,
             "action_class": class_name, "exit_code": res.exit_code},
        )
        return payload


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

INDEX_HTML_PATH = HERE / "templates" / "index.html"


def _render_index(app: App) -> bytes:
    facts = machine_facts()
    # FIX-3-07: avoid constructing a fresh SDK client on every GET /.
    # ``provider_status`` is pure env-var inspection (no network, no
    # client setup) and was added to providers.py for this purpose.
    name, status = provider_status()
    if name == "none":
        banner = status
    elif "not set" in status or "no" in status:
        banner = f"{name}: {status}"
    else:
        banner = f"connected ({name})"
    text = INDEX_HTML_PATH.read_text(encoding="utf-8")
    text = text.replace("{{HOSTNAME}}", html.escape(facts.get("hostname", "?")))
    text = text.replace("{{OS}}", html.escape(facts.get("os", "Ubuntu")))
    text = text.replace("{{PROVIDER_STATUS}}", html.escape(banner))
    examples = (HERE / "examples.md").read_text(encoding="utf-8") if (HERE / "examples.md").exists() else ""
    text = text.replace("{{EXAMPLES}}", html.escape(examples))
    return text.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    app: App  # injected by make_handler

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Quieter default logging; the audit log is the source of truth.
        return

    # ---- helpers ----
    def _send_json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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

    # ---- routes ----
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/" or self.path == "/index.html":
            body = _render_index(self.app)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/health":
            self._send_json({"ok": True, "facts": machine_facts()})
            return
        if self.path == "/api/conversations":
            self._send_json({"conversations": self.app.history.list_conversations()})
            return
        if self.path.startswith("/api/conversation/"):
            try:
                cid = int(self.path.rsplit("/", 1)[1])
            except ValueError:
                self._send_json({"error": "bad id"}, 400)
                return
            self._send_json({"messages": self.app.history.get_messages(cid)})
            return
        if self.path == "/api/audit":
            self._send_json({"entries": audit_tail(50)})
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
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
            self._send_json(self.app.post_message(cid, prompt))
            return
        if self.path == "/api/approve":
            data = self._read_json()
            pid = data.get("proposal_id")
            decision = data.get("decision", "deny")
            phrase = data.get("phrase")
            if not pid:
                self._send_json({"error": "missing proposal_id"}, 400)
                return
            self._send_json(self.app.approve(pid, decision, phrase))
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
    args = parser.parse_args(argv)

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
