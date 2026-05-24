"""Command execution with timeout, stdout/err/exit capture, and a hook
for proposing follow-up verification checks."""
from __future__ import annotations

import os
import shlex
import subprocess
import time
from dataclasses import dataclass

DEFAULT_TIMEOUT = int(os.environ.get("ZOMBIE_COMMAND_TIMEOUT", "300"))


@dataclass
class CommandResult:
    command: str
    exit_code: int
    stdout: str
    stderr: str
    duration_ms: int
    follow_up: list[str]


def _propose_follow_ups(command: str, exit_code: int) -> list[str]:
    """Suggest small read-only checks the assistant can run to verify
    the result of ``command``."""
    follow_ups: list[str] = []
    head = command.split(None, 1)[0] if command.strip() else ""
    tokens = shlex.split(command, posix=True) if command.strip() else []

    if head in {"apt", "apt-get"} and len(tokens) > 1 and tokens[1] in {"install", "remove", "purge"}:
        for pkg in tokens[2:]:
            if pkg.startswith("-"):
                continue
            follow_ups.append(f"dpkg -s {shlex.quote(pkg)} | head -n 5")
    elif head == "systemctl" and len(tokens) > 2 and tokens[1] in {
        "start", "stop", "restart", "reload", "enable", "disable", "mask", "unmask"
    }:
        unit = tokens[2]
        follow_ups.append(f"systemctl is-active {shlex.quote(unit)}")
        follow_ups.append(f"systemctl status --no-pager {shlex.quote(unit)} | head -n 20")
    elif head == "ufw":
        follow_ups.append("ufw status verbose")
    elif head == "tailscale":
        follow_ups.append("tailscale status")
    elif head == "docker" and len(tokens) > 1 and tokens[1] in {"run", "start", "restart"}:
        follow_ups.append("docker ps")

    if exit_code != 0 and "journalctl" not in command:
        follow_ups.append("journalctl -n 50 --no-pager")
    return follow_ups


def run(command: str, *, timeout: int = DEFAULT_TIMEOUT, cwd: str | None = None,
        env: dict[str, str] | None = None) -> CommandResult:
    """Run ``command`` through ``bash -c`` so shell features work.

    The chat service is itself running as ``agent``; commands inherit
    that identity. Privileged commands must include ``sudo`` explicitly
    and are routed through the policy gate before this function is
    called.
    """
    start = time.monotonic()
    try:
        completed = subprocess.run(  # noqa: S602 - the policy gate vetted this
            ["bash", "-lc", command],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
            env={**os.environ, **(env or {})},
            check=False,
        )
        stdout = completed.stdout
        stderr = completed.stderr
        exit_code = completed.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = (exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes)
                  else (exc.stderr or "")) + f"\n[timeout after {timeout}s]"
        exit_code = 124
    duration_ms = int((time.monotonic() - start) * 1000)
    return CommandResult(
        command=command,
        exit_code=exit_code,
        stdout=stdout[-16_000:],   # cap to keep audit/UI sane
        stderr=stderr[-16_000:],
        duration_ms=duration_ms,
        follow_up=_propose_follow_ups(command, exit_code),
    )
