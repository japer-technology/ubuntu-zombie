"""Closed tool registry for the pi-mono runtime.

The chat service runs an explicit, code-controlled tool surface
instead of parsing and approving free-form shell. Every ``pi-mono``
tool call is dispatched through this module:

* :data:`TOOL_REGISTRY` lists the only tools the chat service will ever
  execute. Adding a tool requires a code release — skills cannot
  expand the tool surface.
* :func:`validate_args` runs a minimal, dependency-free schema check.
  Rejections are recorded as ``tool_call_rejected_schema`` audit events
  by the server before any side effects.
* :func:`dispatch` runs the registered shim. Shims wrap existing
  Ubuntu Zombie helpers (``runner.run``, ``Path.read_text`` etc.) so
  the rest of the codebase keeps its existing invariants.

The shapes intentionally avoid pulling in jsonschema or pydantic;
operators install Ubuntu Zombie on stock Ubuntu and the agent venv
should not gain third-party deps just to gate a dozen calls.
"""
from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path
from typing import Any, Callable

from runner import run as run_command  # noqa: E402


# ---------------------------------------------------------------------------
# Schema validation (tiny, dependency-free)
# ---------------------------------------------------------------------------

class SchemaError(ValueError):
    """Raised when a tool call's ``args`` violate the registered schema."""


_PY_TO_JSON = {
    str: "string",
    int: "integer",
    float: "number",
    bool: "boolean",
    list: "array",
    dict: "object",
}


def _check_field(name: str, value: Any, spec: dict[str, Any]) -> None:
    expected = spec.get("type")
    if expected is None:
        return
    if expected == "string" and not isinstance(value, str):
        raise SchemaError(f"{name}: expected string, got {type(value).__name__}")
    if expected == "integer" and (
        isinstance(value, bool) or not isinstance(value, int)
    ):
        # ``bool`` is a subclass of ``int`` in Python; reject it explicitly so
        # callers cannot smuggle ``True``/``False`` into integer fields such
        # as ``shell.run`` ``timeout`` (which would otherwise be coerced to
        # ``0`` and immediately fire ``TimeoutExpired``).
        raise SchemaError(f"{name}: expected integer, got {type(value).__name__}")
    if expected == "boolean" and not isinstance(value, bool):
        raise SchemaError(f"{name}: expected boolean, got {type(value).__name__}")
    if expected == "array":
        if not isinstance(value, list):
            raise SchemaError(f"{name}: expected array, got {type(value).__name__}")
        items = spec.get("items")
        if isinstance(items, dict):
            for i, item in enumerate(value):
                _check_field(f"{name}[{i}]", item, items)
    if expected == "object":
        if not isinstance(value, dict):
            raise SchemaError(f"{name}: expected object, got {type(value).__name__}")
    enum = spec.get("enum")
    if enum is not None and value not in enum:
        raise SchemaError(f"{name}: value {value!r} not in {enum!r}")


def validate_args(name: str, args: dict[str, Any] | None) -> dict[str, Any]:
    """Return a sanitized ``args`` dict or raise :class:`SchemaError`."""
    spec = TOOL_REGISTRY.get(name)
    if spec is None:
        raise SchemaError(f"unknown tool: {name!r}")
    args = dict(args or {})
    schema = spec.get("schema", {})
    required = schema.get("required", ())
    properties = schema.get("properties", {})
    additional = schema.get("additionalProperties", False)
    for key in required:
        if key not in args:
            raise SchemaError(f"{name}: missing required field {key!r}")
    for key, value in args.items():
        if key not in properties:
            if additional:
                continue
            raise SchemaError(f"{name}: unexpected field {key!r}")
        _check_field(key, value, properties[key])
    return args


# ---------------------------------------------------------------------------
# Path allow-list helpers
# ---------------------------------------------------------------------------

def _state_dir() -> Path:
    return Path(os.environ.get("ZOMBIE_DIR", "/opt/ai-zombie")) / "state"


def _read_allowed_prefixes() -> tuple[Path, ...]:
    return (
        _state_dir(),
        Path("/etc"),
        Path("/var/log"),
        Path("/proc"),
        Path("/sys"),
        Path("/usr/share/doc"),
    )


def _write_allowed_prefixes() -> tuple[Path, ...]:
    return (_state_dir(), Path("/tmp"))


def _within(target: Path, roots: tuple[Path, ...]) -> bool:
    try:
        resolved = target.expanduser().resolve()
    except OSError:
        return False
    for root in roots:
        try:
            resolved.relative_to(root.resolve())
            return True
        except (OSError, ValueError):
            continue
    return False


# ---------------------------------------------------------------------------
# Tool shims
# ---------------------------------------------------------------------------

def _shim_shell_run(args: dict[str, Any]) -> dict[str, Any]:
    argv = args.get("argv")
    if isinstance(argv, list) and argv:
        command = " ".join(shlex.quote(str(a)) for a in argv)
    else:
        command = str(args.get("command", ""))
    if not command.strip():
        raise SchemaError("shell.run: argv or command must be non-empty")
    timeout = int(args.get("timeout") or 0) or None
    cwd = args.get("cwd")
    if cwd is not None:
        cwd_path = Path(str(cwd)).expanduser()
        if not _within(cwd_path, _write_allowed_prefixes()):
            raise SchemaError(f"shell.run: cwd {cwd!r} outside writable allow-list")
        cwd = str(cwd_path)
    kwargs: dict[str, Any] = {}
    if timeout:
        kwargs["timeout"] = timeout
    if cwd:
        kwargs["cwd"] = cwd
    res = run_command(command, **kwargs)
    return {
        "exit_code": res.exit_code,
        "stdout": res.stdout,
        "stderr": res.stderr,
        "duration_ms": res.duration_ms,
        "follow_up": res.follow_up,
    }


def _shim_fs_read(args: dict[str, Any]) -> dict[str, Any]:
    path = Path(str(args["path"])).expanduser()
    if not _within(path, _read_allowed_prefixes()):
        raise SchemaError(f"fs.read: {path} outside readable allow-list")
    max_bytes = int(args.get("max_bytes") or 65536)
    data = path.read_bytes()
    truncated = len(data) > max_bytes
    body = data[:max_bytes].decode("utf-8", errors="replace")
    return {"path": str(path), "content": body, "bytes": len(data),
            "truncated": truncated}


def _shim_fs_list(args: dict[str, Any]) -> dict[str, Any]:
    path = Path(str(args["path"])).expanduser()
    if not _within(path, _read_allowed_prefixes()):
        raise SchemaError(f"fs.list: {path} outside readable allow-list")
    if not path.is_dir():
        raise SchemaError(f"fs.list: {path} is not a directory")
    max_entries = int(args.get("max_entries") or 1000)
    if max_entries < 1:
        raise SchemaError("fs.list: max_entries must be positive")
    entries: list[dict[str, Any]] = []
    names = sorted(p.name for p in path.iterdir())
    truncated = len(names) > max_entries
    for name in names[:max_entries]:
        child = path / name
        try:
            st = child.lstat()
        except OSError:
            continue
        if child.is_symlink():
            kind = "symlink"
        elif child.is_dir():
            kind = "dir"
        elif child.is_file():
            kind = "file"
        else:
            kind = "other"
        entries.append({"name": name, "type": kind, "bytes": st.st_size})
    return {"path": str(path), "entries": entries, "count": len(names),
            "truncated": truncated}


def _shim_fs_write(args: dict[str, Any]) -> dict[str, Any]:
    path = Path(str(args["path"])).expanduser()
    if not _within(path, _write_allowed_prefixes()):
        raise SchemaError(f"fs.write: {path} outside writable allow-list")
    content = str(args["content"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return {"path": str(path), "bytes": len(content.encode("utf-8"))}


def _shim_pkg_query(args: dict[str, Any]) -> dict[str, Any]:
    name = str(args["name"])
    if not name.replace("-", "").replace("+", "").replace(".", "").isalnum():
        raise SchemaError(f"pkg.query: invalid package name {name!r}")
    res = run_command(f"dpkg -s {shlex.quote(name)} 2>&1 || apt-cache policy {shlex.quote(name)}")
    return {"exit_code": res.exit_code, "stdout": res.stdout, "stderr": res.stderr}


def _shim_pkg_install(args: dict[str, Any]) -> dict[str, Any]:
    names = args.get("names") or []
    if not isinstance(names, list) or not names:
        raise SchemaError("pkg.install: names must be a non-empty array")
    for n in names:
        if not isinstance(n, str) or not n.replace("-", "").replace("+", "").replace(".", "").isalnum():
            raise SchemaError(f"pkg.install: invalid package name {n!r}")
    cmd = "sudo apt-get install -y " + " ".join(shlex.quote(n) for n in names)
    res = run_command(cmd)
    return {"exit_code": res.exit_code, "stdout": res.stdout, "stderr": res.stderr,
            "duration_ms": res.duration_ms}


def _shim_svc_status(args: dict[str, Any]) -> dict[str, Any]:
    unit = str(args["unit"])
    if not all(c.isalnum() or c in "._@-" for c in unit):
        raise SchemaError(f"svc.status: invalid unit {unit!r}")
    res = run_command(f"systemctl status --no-pager {shlex.quote(unit)} || systemctl is-active {shlex.quote(unit)}")
    return {"exit_code": res.exit_code, "stdout": res.stdout, "stderr": res.stderr}


def _shim_svc_control(args: dict[str, Any]) -> dict[str, Any]:
    action = str(args["action"])
    if action not in {"start", "stop", "restart", "reload", "enable", "disable"}:
        raise SchemaError(f"svc.control: invalid action {action!r}")
    unit = str(args["unit"])
    if not all(c.isalnum() or c in "._@-" for c in unit):
        raise SchemaError(f"svc.control: invalid unit {unit!r}")
    res = run_command(f"sudo systemctl {action} {shlex.quote(unit)}")
    return {"exit_code": res.exit_code, "stdout": res.stdout, "stderr": res.stderr}


def _shim_net_status(args: dict[str, Any]) -> dict[str, Any]:
    target = str(args.get("target") or "all")
    if target == "ip":
        cmd = "ip -brief addr"
    else:
        cmd = "ip -brief addr; ss -ltn"
    res = run_command(cmd)
    return {"exit_code": res.exit_code, "stdout": res.stdout, "stderr": res.stderr}


def _skills_dirs() -> list[Path]:
    dirs = [
        Path("/opt/ai-zombie/skills"),
        Path("/etc/ubuntu-zombie/skills.d"),
    ]
    # Honour ``ZOMBIE_SKILLS_DIR`` only when it is a non-empty value. An
    # empty string would otherwise become ``Path("")``/``Path(".")`` and
    # silently add the chat service's working directory to the skills
    # search path, bypassing the root-owned trees above.
    extra = os.environ.get("ZOMBIE_SKILLS_DIR", "").strip()
    if extra:
        dirs.append(Path(extra))
    return dirs


def _shim_skill_list(_args: dict[str, Any]) -> dict[str, Any]:
    skills: list[dict[str, str]] = []
    for d in _skills_dirs():
        if not d or not d.is_dir():
            continue
        for path in sorted(d.glob("*.md")):
            skills.append({"name": path.stem, "path": str(path)})
    return {"skills": skills}


def _shim_skill_load(args: dict[str, Any]) -> dict[str, Any]:
    name = str(args["name"])
    if not name.replace("-", "").replace("_", "").isalnum():
        raise SchemaError(f"skill.load: invalid skill name {name!r}")
    for d in _skills_dirs():
        if not d or not d.is_dir():
            continue
        candidate = d / f"{name}.md"
        if candidate.is_file():
            return {"name": name, "path": str(candidate),
                    "content": candidate.read_text(encoding="utf-8", errors="replace")}
    raise SchemaError(f"skill.load: skill {name!r} not found")


def _shim_timer_reactivation(_args: dict[str, Any]) -> dict[str, Any]:
    raise SchemaError(
        "timer.reactivation requires an active conversation runtime"
    )


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

ToolShim = Callable[[dict[str, Any]], dict[str, Any]]


def _t(*, classification: str, schema: dict[str, Any], shim: ToolShim,
       description: str) -> dict[str, Any]:
    return {"classification": classification, "schema": schema, "shim": shim,
            "description": description}


TOOL_REGISTRY: dict[str, dict[str, Any]] = {
    "shell.run": _t(
        classification="system_change",  # actual class computed per-argv in classify_tool
        description="Run a shell command through the existing runner.",
        schema={
            "type": "object",
            "properties": {
                "argv": {"type": "array", "items": {"type": "string"}},
                "command": {"type": "string"},
                "cwd": {"type": "string"},
                "timeout": {"type": "integer"},
            },
            "required": [],
            "additionalProperties": False,
        },
        shim=_shim_shell_run,
    ),
    "fs.read": _t(
        classification="read_only",
        description="Read a UTF-8 text file within the readable allow-list.",
        schema={
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "max_bytes": {"type": "integer"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        shim=_shim_fs_read,
    ),
    "fs.list": _t(
        classification="read_only",
        description="List directory entries within the readable allow-list.",
        schema={
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "max_entries": {"type": "integer"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        shim=_shim_fs_list,
    ),
    "fs.write": _t(
        classification="user_change",
        description="Write text content to a path within the writable allow-list.",
        schema={
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
            "additionalProperties": False,
        },
        shim=_shim_fs_write,
    ),
    "pkg.query": _t(
        classification="read_only",
        description="Query installed package metadata via dpkg/apt-cache.",
        schema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
        shim=_shim_pkg_query,
    ),
    "pkg.install": _t(
        classification="system_change",
        description="Install Debian packages via apt-get.",
        schema={
            "type": "object",
            "properties": {"names": {"type": "array", "items": {"type": "string"}}},
            "required": ["names"],
            "additionalProperties": False,
        },
        shim=_shim_pkg_install,
    ),
    "svc.status": _t(
        classification="read_only",
        description="Inspect a systemd unit (status / is-active).",
        schema={
            "type": "object",
            "properties": {"unit": {"type": "string"}},
            "required": ["unit"],
            "additionalProperties": False,
        },
        shim=_shim_svc_status,
    ),
    "svc.control": _t(
        classification="system_change",
        description="Start/stop/restart/reload/enable/disable a systemd unit.",
        schema={
            "type": "object",
            "properties": {
                "unit": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["start", "stop", "restart", "reload", "enable", "disable"],
                },
            },
            "required": ["unit", "action"],
            "additionalProperties": False,
        },
        shim=_shim_svc_control,
    ),
    "net.status": _t(
        classification="read_only",
        description="Read-only interface and listening-port inspection.",
        schema={
            "type": "object",
            "properties": {
                "target": {"type": "string", "enum": ["all", "ip"]},
            },
            "required": [],
            "additionalProperties": False,
        },
        shim=_shim_net_status,
    ),
    "skill.list": _t(
        classification="read_only",
        description="Enumerate available skills from /opt/ai-zombie/skills and /etc/ubuntu-zombie/skills.d.",
        schema={"type": "object", "properties": {}, "required": [],
                "additionalProperties": False},
        shim=_shim_skill_list,
    ),
    "skill.load": _t(
        classification="read_only",
        description="Read the markdown body of a skill by name.",
        schema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
            "additionalProperties": False,
        },
        shim=_shim_skill_load,
    ),
    "timer.reactivation": _t(
        classification="chat_schedule",
        description=(
            "Schedule one bounded, visible continuation in the current conversation."
        ),
        schema={
            "type": "object",
            "properties": {
                "delay_seconds": {"type": "integer"},
                "prompt": {"type": "string"},
                "reason": {"type": "string"},
                "replace_existing": {"type": "boolean"},
            },
            "required": ["delay_seconds", "prompt"],
            "additionalProperties": False,
        },
        shim=_shim_timer_reactivation,
    ),
}


def tool_names() -> tuple[str, ...]:
    return tuple(TOOL_REGISTRY.keys())


def dispatch(name: str, args: dict[str, Any] | None) -> dict[str, Any]:
    """Validate and execute a tool. Raises :class:`SchemaError` on bad input."""
    cleaned = validate_args(name, args)
    spec = TOOL_REGISTRY[name]
    return spec["shim"](cleaned)


# Silence unused-import warnings when imported by smoke tests that
# never call subprocess directly.
_ = subprocess
