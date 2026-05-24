"""Audit logging for Ubuntu Zombie.

Every prompt, proposed action, approval decision, command, exit code,
and verification result is appended as one JSON object per line to
``/var/log/ubuntu-zombie/audit.log``. Secrets are redacted before
write.
"""
from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Mapping

AUDIT_PATH = Path(os.environ.get("ZOMBIE_AUDIT_LOG", "/var/log/ubuntu-zombie/audit.log"))

# Token-shaped strings: provider keys, base64 blobs, ssh keys, etc.
_REDACTORS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"sk-[A-Za-z0-9_-]{12,}"), "sk-***REDACTED***"),
    (re.compile(r"sk-ant-[A-Za-z0-9_-]{12,}"), "sk-ant-***REDACTED***"),
    (re.compile(r"tskey-[A-Za-z0-9_-]{12,}"), "tskey-***REDACTED***"),
    (re.compile(r"ssh-(rsa|ed25519|dss)\s+[A-Za-z0-9+/=]{20,}"), "ssh-*** REDACTED ***"),
    (re.compile(r"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*\S+"),
     r"\1=***REDACTED***"),
    (re.compile(r"-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]+?-----END [A-Z ]+PRIVATE KEY-----"),
     "***REDACTED PRIVATE KEY***"),
)

_LOCK = threading.Lock()


def redact(value: Any) -> Any:
    """Redact token-shaped substrings from ``value`` recursively."""
    if isinstance(value, str):
        out = value
        for pattern, replacement in _REDACTORS:
            out = pattern.sub(replacement, out)
        return out
    if isinstance(value, Mapping):
        return {k: redact(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(v) for v in value]
    return value


def _ensure_log() -> None:
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not AUDIT_PATH.exists():
        AUDIT_PATH.touch(mode=0o640)


def log_event(event_type: str, **fields: Any) -> str:
    """Append one audit entry. Returns the entry's ``id``."""
    entry_id = uuid.uuid4().hex
    entry: dict[str, Any] = {
        "id": entry_id,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "type": event_type,
    }
    entry.update(redact(fields))
    line = json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
    with _LOCK:
        _ensure_log()
        with AUDIT_PATH.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    return entry_id


def tail(n: int = 25) -> list[dict[str, Any]]:
    """Return up to ``n`` most recent audit entries as parsed dicts."""
    if not AUDIT_PATH.exists():
        return []
    with AUDIT_PATH.open("r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    out: list[dict[str, Any]] = []
    for raw in lines[-n:]:
        raw = raw.strip()
        if not raw:
            continue
        try:
            out.append(json.loads(raw))
        except json.JSONDecodeError:
            continue
    return out
