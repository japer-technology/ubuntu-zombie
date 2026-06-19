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

The server binds to ``127.0.0.1`` only. Remote access is by SSH tunnel
over Tailscale.

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
import socket
import stat
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from audit import AUDIT_PATH, log_event, log_tool_call, tail as audit_tail  # noqa: E402
from history import History  # noqa: E402
from policy import POLICY_PATH, load_policy  # noqa: E402
from providers import provider_status  # noqa: E402
import providers  # noqa: E402
import pi_mono  # noqa: E402
import skill_loader  # noqa: E402
import tools as tools_mod  # noqa: E402

SECRETS_FILE = Path(os.environ.get("ZOMBIE_SECRETS", "/opt/ai-zombie/secrets/env"))
DEFAULT_PORT = int(os.environ.get("ZOMBIE_CHAT_PORT", "7878"))
DEFAULT_HOST = "127.0.0.1"


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
    }
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                facts["os"] = line.split("=", 1)[1].strip().strip('"')
                break
    except OSError:
        pass
    return facts


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


def version_info() -> dict[str, str]:
    """App version plus the pinned provider-bridge versions."""
    info = {"version": app_version()}
    pi_mono = _read_text_file(HERE / "pi-mono.version")
    if pi_mono:
        info["pi_mono"] = pi_mono
    pi_ai = _read_text_file(HERE / "pi-ai.version")
    if pi_ai:
        info["pi_ai"] = pi_ai
    return info


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------

class App:
    def __init__(self) -> None:
        self.history = History()
        # Pending tool calls awaiting operator approval. Each item is
        # addressable by both the audit entry id and provider tool-call id
        # so legacy buttons and text commands resolve the same queue item.
        self.pending: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    # ---- conversation flow ----
    def post_message(self, conv_id: int | None, prompt: str) -> dict[str, Any]:
        if not conv_id:
            conv_id = self.history.create_conversation()
        log_event("prompt", conversation_id=conv_id, prompt=prompt)
        self.history.add_message(conv_id, "user", prompt)

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
        max_calls = int(getattr(policy, "max_tool_calls_per_turn", 12) or 12)
        # Also enforce the elevated (non ``read_only``) per-turn
        # budget. Read-only tools auto-run and are cheap; elevated
        # tools queue an operator prompt and mutate state, so they
        # are bounded separately to cap the blast radius of a runaway
        # loop. Calls beyond the budget receive a synthetic
        # ``budget_exceeded`` observation (see
        # ``payload/etc/policy.yaml``) so the model ends the turn
        # cleanly.
        max_elevated = int(
            getattr(policy, "max_elevated_calls_per_turn", 3) or 3
        )
        # Per-turn idle deadline so a wedged provider cannot leave the
        # operator's request pending forever (see ``pi_mono.run_turn``).
        turn_timeout = float(getattr(policy, "max_turn_seconds", 120) or 0)
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
                # End the model turn cleanly — pi sees an observation
                # explaining the operator gate so it can summarize.
                return {"ok": False,
                        "error": ("operator_approval_required: this call has "
                                  "been queued for human review; do not retry.")}

            # Auto-approved (read_only): execute now.
            try:
                result = tools_mod.dispatch(name, cleaned)
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
                return {"ok": False, "error": str(exc)}

        try:
            turn = pi_mono.run_turn(
                prompt=prompt,
                system_prompt=system_prompt,
                history=history_payload,
                on_tool_call=on_tool_call,
                tool_names=tools_mod.tool_names(),
                max_tool_calls=max_calls,
                timeout=turn_timeout,
            )
        except pi_mono.BridgeError as exc:
            err = str(exc)
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            return {"conversation_id": conv_id, "error": err}
        except Exception as exc:  # noqa: BLE001
            err = f"pi-mono call failed: {exc.__class__.__name__}: {exc}"
            self.history.add_message(conv_id, "system", err, {"error": True})
            log_event("provider_error", conversation_id=conv_id, error=err)
            return {"conversation_id": conv_id, "error": err}

        reply = turn.get("final") or ""
        self.history.add_message(conv_id, "assistant", reply,
                                 {"engine": "pi-mono",
                                  "log_path": turn.get("log_path")})
        return {
            "conversation_id": conv_id,
            "reply": reply,
            "events": self.history.get_events(conv_id),
            "messages": self.history.get_messages(conv_id),
        }

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
            result = tools_mod.dispatch(tool, args)
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
        data = self.config_info()
        return {
            "agent_user": AGENT_USER,
            "hostname": facts.get("hostname", socket.gethostname()),
            "os": facts.get("os", ""),
            "kernel": facts.get("kernel", ""),
            "arch": facts.get("arch", ""),
            "loopback_only": True,
            "chat_url": f"http://{DEFAULT_HOST}:{DEFAULT_PORT}/",
            "zombie_dir": data["zombie_dir"],
            "history_db": data["history_db"],
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
        return {"ok": True, "provider": provider, "model": chosen}


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


def _render_index(app: App) -> bytes:
    facts = machine_facts()
    # FIX-3-07: avoid constructing a fresh SDK client on every GET /.
    name, status = provider_status()
    if name == "none":
        banner = status
    elif status.startswith("model ") and "not set" not in status:
        banner = f"{name}({status[len('model '):]})"
    else:
        banner = f"{name}: {status}"
    text = INDEX_HTML_PATH.read_text(encoding="utf-8")
    text = text.replace("{{HOSTNAME}}", html.escape(facts.get("hostname", "?")))
    text = text.replace("{{USERNAME}}", html.escape(AGENT_USER))
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

    def _path_parts(self) -> list[str]:
        path = self.path.split("?", 1)[0]
        return [unquote(p) for p in path.strip("/").split("/") if p]

    # ---- routes ----
    def do_GET(self) -> None:  # noqa: N802
        parts = self._path_parts()
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
        if self.path == "/api/version":
            self._send_json(version_info())
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
        if self.path == "/api/config":
            self._send_json(self.app.config_info())
            return
        if self.path == "/api/profile":
            self._send_json(self.app.profile_info())
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
