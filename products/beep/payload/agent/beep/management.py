"""Independent root-only lifecycle for the Beep Systems Administrator."""

from __future__ import annotations

import argparse
import fcntl
import getpass
import grp
import hashlib
import ipaddress
import json
import os
import platform
import pwd
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import uuid
import venv
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

import auth as runtime_auth
import lifecycle as runtime_lifecycle


PRODUCT_ID = "beep"
OPERATIONS = (
    "describe",
    "status",
    "install",
    "verify",
    "doctor",
    "repair",
    "backup",
    "update",
    "rollback",
    "suspend",
    "resume",
    "uninstall",
)
MUTATING = {
    "install",
    "repair",
    "backup",
    "update",
    "rollback",
    "suspend",
    "resume",
    "uninstall",
}
READ_ONLY = {"describe", "status", "verify", "doctor"}
CONFIGURATION_OPERATIONS = {"install", "repair", "update"}
CONFIGURATION_INPUTS = {
    "agent_user",
    "chat_port",
    "chat_password_file",
    "provider",
    "provider_credential_file",
    "model",
    "model_base_url",
    "ttl_days",
}
OPERATION_INPUTS = {
    "describe": set(),
    "status": set(),
    "install": CONFIGURATION_INPUTS,
    "verify": set(),
    "doctor": set(),
    "repair": CONFIGURATION_INPUTS,
    "backup": {"backup_destination"},
    "update": CONFIGURATION_INPUTS,
    "rollback": set(),
    "suspend": set(),
    "resume": set(),
    "uninstall": set(),
}
KNOWN_ENV = {
    "BEEP_SOURCE_ROOT",
    "BEEP_NONINTERACTIVE",
    "BEEP_USER",
    "BEEP_CHAT_PORT",
    "BEEP_ADMIN_PASSWORD_FILE",
    "BEEP_PROVIDER",
    "BEEP_PROVIDER_CREDENTIAL_FILE",
    "BEEP_MODEL",
    "BEEP_MODEL_BASE_URL",
    "BEEP_TTL_DAYS",
    "BEEP_BACKUP_DESTINATION",
    "BEEP_ARTIFACT_SHA256",
    "BEEP_DISPOSABLE_VM_TEST",
}
PROVIDER_KEYS = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "gemini": "GEMINI_API_KEY",
    "xai": "XAI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
    "mistral": "MISTRAL_API_KEY",
    "groq": "GROQ_API_KEY",
    "lmstudio": "LMSTUDIO_API_KEY",
}
DEFAULT_USER = "beep"
DEFAULT_PORT = 58989
DEFAULT_TTL_DAYS = 7
DELETE_CONFIRMATION = "DELETE BEEP STATE"
VERSION_PATTERN = re.compile(r"^\d{4}(?:\.\d{2}){5}$")
USER_PATTERN = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
SYSTEM_PACKAGES = (
    "sudo",
    "curl",
    "wget",
    "ca-certificates",
    "gnupg",
    "lsb-release",
    "software-properties-common",
    "apt-transport-https",
    "git",
    "vim",
    "nano",
    "tmux",
    "htop",
    "unzip",
    "zip",
    "jq",
    "iputils-ping",
    "unattended-upgrades",
    "logrotate",
    "python3",
    "python3-pip",
    "python3-venv",
    "pipx",
    "build-essential",
    "ripgrep",
    "fd-find",
    "tree",
    "rsync",
    "cron",
    "pwgen",
    "psmisc",
)


class ManagementError(Exception):
    """A bounded lifecycle failure with a stable exit status and code."""

    def __init__(
        self,
        exit_code: int,
        code: str,
        message: str,
        *,
        retryable: bool = False,
        recovery: list[str] | None = None,
    ) -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.code = code
        self.message = message
        self.retryable = retryable
        self.recovery = recovery or []


@dataclass(frozen=True)
class Paths:
    """Every host resource owned by Beep."""

    install_root: Path = Path("/opt/beep")
    configuration_root: Path = Path("/etc/beep")
    state_root: Path = Path("/var/lib/beep")
    log_root: Path = Path("/var/log/beep")
    chat_unit: Path = Path("/etc/systemd/system/beep-chat.service")
    health_unit: Path = Path("/etc/systemd/system/beep-health.service")
    health_timer: Path = Path("/etc/systemd/system/beep-health.timer")
    logrotate: Path = Path("/etc/logrotate.d/beep")
    sudoers: Path = Path("/etc/sudoers.d/90-beep")
    entrypoint: Path = Path("/usr/local/sbin/beep-manage")
    lock: Path = Path("/run/lock/beep.lock")
    rollback_root: Path = Path("/var/lib/beep/recovery")

    @property
    def marker(self) -> Path:
        return self.state_root / "installation.json"

    @property
    def retained(self) -> Path:
        return self.state_root / "retained.json"

    @property
    def suspended(self) -> Path:
        return self.state_root / "suspended.json"

    @property
    def runtime(self) -> Path:
        return self.state_root / "runtime"

    @property
    def config(self) -> Path:
        return self.configuration_root / "config.json"

    @property
    def descriptor(self) -> Path:
        return self.configuration_root / "PRODUCT.json"

    @property
    def policy(self) -> Path:
        return self.configuration_root / "policy.yaml"

    @property
    def secrets(self) -> Path:
        return self.configuration_root / "secrets" / "env"

    @property
    def session_key(self) -> Path:
        return self.configuration_root / "secrets" / "session.key"

    @property
    def audit(self) -> Path:
        return self.log_root / "audit.jsonl"

    @property
    def receipt(self) -> Path:
        return self.log_root / "management-receipt.json"

    @property
    def receipts(self) -> Path:
        return self.log_root / "receipts"

    @property
    def product_root(self) -> Path:
        return self.install_root / "product"


@dataclass(frozen=True)
class Configuration:
    agent_user: str
    chat_port: int
    provider: str | None
    model: str | None
    model_base_url: str | None
    ttl_days: int

    def object(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "agent_user": self.agent_user,
            "chat_port": self.chat_port,
            "provider": self.provider,
            "model": self.model,
            "model_base_url": self.model_base_url,
            "ttl_days": self.ttl_days,
        }


@dataclass
class Invocation:
    operation: str
    correlation_id: str
    actor: str
    inputs: dict[str, Any]
    confirmation: str | None
    retain_state: bool | None
    dry_run: bool
    json_output: bool
    non_interactive: bool
    assume_yes: bool
    supplied_plan_digest: str | None


@dataclass
class Result:
    operation: str
    correlation_id: str
    product_version: str
    instance_id: str | None
    phase: str
    status: str = "ok"
    changed: bool = False
    plan_digest: str | None = None
    requires_confirmation: bool = False
    required_inputs: list[dict[str, Any]] = field(default_factory=list)
    steps: list[dict[str, Any]] = field(default_factory=list)
    checks: list[dict[str, Any]] = field(default_factory=list)
    receipt: dict[str, str] | None = None
    errors: list[dict[str, Any]] = field(default_factory=list)
    recovery: list[str] = field(default_factory=list)
    details: dict[str, Any] | None = None

    def object(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "product_version": self.product_version,
            "instance_id": self.instance_id,
            "operation": self.operation,
            "phase": self.phase,
            "correlation_id": self.correlation_id,
            "status": self.status,
            "changed": self.changed,
            "plan_digest": self.plan_digest,
            "requires_confirmation": self.requires_confirmation,
            "required_inputs": self.required_inputs,
            "steps": self.steps,
            "checks": self.checks,
            "receipt": self.receipt,
            "errors": self.errors,
            "recovery": self.recovery,
        }
        if self.details is not None:
            value["details"] = {"beep": self.details}
        return value


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return f"sha256:{hashlib.sha256(value).hexdigest()}"


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManagementError(65, "DUPLICATE_KEY", f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=strict_object
        )
    except ManagementError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ManagementError(
            65, "INVALID_JSON", f"Invalid JSON object at {path}."
        ) from exc
    if not isinstance(value, dict):
        raise ManagementError(65, "INVALID_JSON", f"{path} must contain an object.")
    return value


def atomic_write(
    path: Path,
    content: bytes,
    *,
    mode: int,
    uid: int = 0,
    gid: int = 0,
) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ManagementError(73, "UNSAFE_PATH", f"Refusing symlink: {path}")
    previous = path.read_bytes() if path.is_file() else None
    if previous == content:
        os.chmod(path, mode)
        if os.geteuid() == 0:
            os.chown(path, uid, gid)
        return False
    temporary = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(temporary, flags, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        if os.geteuid() == 0:
            os.chown(temporary, uid, gid)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def operation_phase(operation: str, *, dry_run: bool) -> str:
    if dry_run and operation in MUTATING:
        return "plan"
    if operation in READ_ONLY:
        return "read"
    return "execute"


class Manager:
    """Validate, plan, and execute one Beep-owned lifecycle operation."""

    def __init__(self, source_root: Path | None = None) -> None:
        default_root = Path(__file__).resolve().parents[3]
        self.source_root = (
            source_root
            or Path(os.environ.get("BEEP_SOURCE_ROOT", str(default_root)))
        ).resolve()
        self.paths = Paths()
        self.descriptor = load_json(self.source_root / "PRODUCT.json")
        self.version = (
            (self.source_root / "VERSION").read_text(encoding="utf-8").strip()
        )
        self._validate_source()

    def _validate_source(self) -> None:
        expected = {
            "schema_version",
            "product_id",
            "display_name",
            "authority_summary",
            "source_root",
            "version_file",
            "lifecycle_script",
            "installed_entrypoint",
            "install_root",
            "configuration_root",
            "state_root",
            "log_root",
            "ownership_marker",
            "environment_prefix",
            "accounts",
            "units",
            "ports",
            "cookie_names",
            "operations",
        }
        if set(self.descriptor) != expected:
            raise ManagementError(65, "INVALID_DESCRIPTOR", "Descriptor keys differ.")
        if (
            self.descriptor["schema_version"] != 1
            or self.descriptor["product_id"] != PRODUCT_ID
            or self.descriptor["source_root"] != "products/beep"
            or self.descriptor["installed_entrypoint"] != str(self.paths.entrypoint)
            or self.descriptor["ownership_marker"] != str(self.paths.marker)
            or self.descriptor["operations"] != list(OPERATIONS)
        ):
            raise ManagementError(
                65, "INVALID_DESCRIPTOR", "Beep descriptor identity is invalid."
            )
        if not VERSION_PATTERN.fullmatch(self.version):
            raise ManagementError(65, "INVALID_VERSION", "Beep VERSION is invalid.")
        required = (
            self.source_root / "payload" / "agent" / "server.py",
            self.source_root / "payload" / "etc" / "policy.yaml",
            self.source_root / "payload" / "systemd" / "beep-chat.service",
            self.source_root / "scripts" / "manage.sh",
        )
        if any(not path.is_file() for path in required):
            raise ManagementError(
                66, "SOURCE_INCOMPLETE", "The Beep source payload is incomplete."
            )

    def _validate_environment(self) -> None:
        unknown = sorted(
            key for key in os.environ if key.startswith("BEEP_") and key not in KNOWN_ENV
        )
        if unknown:
            raise ManagementError(
                65,
                "UNKNOWN_ENVIRONMENT",
                f"Unknown Beep environment variable(s): {', '.join(unknown)}",
            )
        prohibited = {
            "BEEP_ADMIN_PASSWORD",
            "BEEP_PROVIDER_CREDENTIAL",
            "BEEP_API_KEY",
        }
        if prohibited & os.environ.keys():
            raise ManagementError(
                65,
                "RAW_SECRET_REJECTED",
                "Raw secret environment variables are prohibited; use a protected file.",
            )

    def _existing_config(self) -> dict[str, Any]:
        if not self.paths.config.is_file() or self.paths.config.is_symlink():
            return {}
        value = load_json(self.paths.config)
        allowed = {
            "schema_version",
            "agent_user",
            "chat_port",
            "provider",
            "model",
            "model_base_url",
            "ttl_days",
        }
        return value if set(value) == allowed and value.get("schema_version") == 1 else {}

    @staticmethod
    def _input(
        invocation: Invocation,
        key: str,
        environment: str,
        existing: dict[str, Any],
        default: Any,
    ) -> Any:
        if key in invocation.inputs:
            return invocation.inputs[key]
        if environment in os.environ:
            return os.environ[environment]
        if key in existing:
            return existing[key]
        return default

    def configuration(self, invocation: Invocation) -> Configuration:
        existing = self._existing_config()
        agent_user = self._input(
            invocation, "agent_user", "BEEP_USER", existing, DEFAULT_USER
        )
        if not isinstance(agent_user, str) or not USER_PATTERN.fullmatch(agent_user):
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "agent_user is not a valid Linux name."
            )
        if agent_user != DEFAULT_USER:
            raise ManagementError(
                65,
                "INVALID_CONFIGURATION",
                "Beep version 1 reserves the fixed Linux identity 'beep'.",
            )
        raw_port = self._input(
            invocation, "chat_port", "BEEP_CHAT_PORT", existing, DEFAULT_PORT
        )
        try:
            chat_port = int(raw_port)
        except (TypeError, ValueError) as exc:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "chat_port must be an integer."
            ) from exc
        if isinstance(raw_port, bool) or not 1024 <= chat_port <= 65535:
            raise ManagementError(
                65,
                "INVALID_CONFIGURATION",
                "chat_port must be between 1024 and 65535.",
            )
        provider = self._input(
            invocation, "provider", "BEEP_PROVIDER", existing, None
        )
        if provider in ("", None):
            provider = None
        if not isinstance(provider, (str, type(None))) or (
            provider is not None and provider not in PROVIDER_KEYS
        ):
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "provider is not supported."
            )
        model = self._input(invocation, "model", "BEEP_MODEL", existing, None)
        if model in ("", None):
            model = None
        if not isinstance(model, (str, type(None))) or (
            isinstance(model, str) and (not model.strip() or len(model) > 256)
        ):
            raise ManagementError(65, "INVALID_CONFIGURATION", "model is invalid.")
        base_url = self._input(
            invocation, "model_base_url", "BEEP_MODEL_BASE_URL", existing, None
        )
        if base_url in ("", None):
            base_url = None
        if base_url is not None:
            if not isinstance(base_url, str):
                raise ManagementError(
                    65, "INVALID_CONFIGURATION", "model_base_url must be a URL."
                )
            self._validate_model_url(base_url)
        raw_ttl = self._input(
            invocation, "ttl_days", "BEEP_TTL_DAYS", existing, DEFAULT_TTL_DAYS
        )
        try:
            ttl_days = int(raw_ttl)
        except (TypeError, ValueError) as exc:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "ttl_days must be an integer."
            ) from exc
        if isinstance(raw_ttl, bool) or not 1 <= ttl_days <= 3650:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "ttl_days must be between 1 and 3650."
            )
        if provider in {"openrouter", "lmstudio"} and model is None:
            raise ManagementError(
                64,
                "REQUIRED_INPUT",
                "The selected provider requires a model identifier.",
            )
        return Configuration(
            agent_user=agent_user,
            chat_port=chat_port,
            provider=provider,
            model=model,
            model_base_url=base_url,
            ttl_days=ttl_days,
        )

    @staticmethod
    def _validate_model_url(value: str) -> None:
        parsed = urllib.parse.urlsplit(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.fragment
        ):
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "model_base_url is unsafe."
            )
        if parsed.scheme == "http":
            try:
                address = ipaddress.ip_address(parsed.hostname)
            except ValueError:
                if parsed.hostname != "localhost":
                    raise ManagementError(
                        65,
                        "INVALID_CONFIGURATION",
                        "Plain HTTP model endpoints must use a literal private address.",
                    )
            else:
                if not (address.is_loopback or address.is_private):
                    raise ManagementError(
                        65,
                        "INVALID_CONFIGURATION",
                        "Plain HTTP model endpoints must be loopback or private.",
                    )

    def invocation(self, args: argparse.Namespace) -> Invocation:
        self._validate_environment()
        request: dict[str, Any] | None = None
        if args.request_file is not None:
            request = self._request(args.request_file, args.operation)
        correlation_id = (
            request["correlation_id"]
            if request is not None
            else args.correlation_id or str(uuid.uuid4())
        )
        try:
            if str(uuid.UUID(correlation_id)) != correlation_id:
                raise ValueError
        except (ValueError, AttributeError) as exc:
            raise ManagementError(
                65, "INVALID_CORRELATION", "correlation-id must be a canonical UUID."
            ) from exc
        inputs = dict(request["inputs"]) if request is not None else {}
        allowed = OPERATION_INPUTS[args.operation]
        unknown = sorted(set(inputs) - allowed)
        if unknown:
            raise ManagementError(
                65, "UNKNOWN_INPUT", f"Unknown input key(s): {', '.join(unknown)}"
            )
        confirmation = (
            request["confirmation"] if request is not None else args.confirmation
        )
        retain_state = request.get("retain_state") if request is not None else None
        if args.operation == "uninstall" and request is None:
            retain_state = not args.purge
        non_interactive = bool(
            args.non_interactive or os.environ.get("BEEP_NONINTERACTIVE") == "1"
        )
        return Invocation(
            operation=args.operation,
            correlation_id=correlation_id,
            actor=request["requested_by"] if request is not None else "operator",
            inputs=inputs,
            confirmation=confirmation,
            retain_state=retain_state,
            dry_run=args.dry_run,
            json_output=args.json,
            non_interactive=non_interactive,
            assume_yes=args.yes,
            supplied_plan_digest=args.plan_digest,
        )

    def _request(self, path: Path, operation: str) -> dict[str, Any]:
        if not path.is_absolute():
            raise ManagementError(73, "UNSAFE_REQUEST", "Request path must be absolute.")
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise ManagementError(66, "REQUEST_MISSING", "Request file is missing.") from exc
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ManagementError(
                73, "UNSAFE_REQUEST", "Request must be a non-symlink regular file."
            )
        if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ManagementError(
                73,
                "UNSAFE_REQUEST",
                "Request must be root-owned and inaccessible to group and other.",
            )
        value = load_json(path)
        required = {
            "schema_version",
            "product_id",
            "operation",
            "correlation_id",
            "requested_by",
            "inputs",
            "confirmation",
        }
        allowed = required | {"retain_state"}
        if not required <= value.keys() or value.keys() - allowed:
            raise ManagementError(65, "INVALID_REQUEST", "Request fields are invalid.")
        if (
            value["schema_version"] != 1
            or value["product_id"] != PRODUCT_ID
            or value["operation"] != operation
            or value["requested_by"] not in {"operator", "ubuntu-zombie"}
            or not isinstance(value["inputs"], dict)
            or not isinstance(value["confirmation"], (str, type(None)))
        ):
            raise ManagementError(65, "INVALID_REQUEST", "Request identity is invalid.")
        if operation == "uninstall":
            if not isinstance(value.get("retain_state"), bool):
                raise ManagementError(
                    65, "INVALID_REQUEST", "Uninstall requires retain_state."
                )
        elif "retain_state" in value:
            raise ManagementError(
                65, "INVALID_REQUEST", "retain_state applies only to uninstall."
            )
        return value

    def instance_id(self) -> str | None:
        marker = self.load_marker(required=False)
        return str(marker["instance_id"]) if marker is not None else None

    def load_marker(self, *, required: bool) -> dict[str, Any] | None:
        if not self.paths.marker.exists():
            if required:
                raise ManagementError(
                    66, "NOT_INSTALLED", "Beep is not installed on this host."
                )
            return None
        try:
            metadata = self.paths.marker.lstat()
        except OSError as exc:
            raise ManagementError(66, "MARKER_MISSING", "Marker is unavailable.") from exc
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o644
        ):
            raise ManagementError(73, "UNSAFE_MARKER", "Ownership marker is unsafe.")
        value = load_json(self.paths.marker)
        required_keys = {
            "schema_version",
            "product_id",
            "instance_id",
            "version",
            "source_revision",
            "installed_at",
            "install_root",
            "lifecycle_entrypoint",
            "artifact_sha256",
        }
        try:
            valid_uuid = str(uuid.UUID(str(value.get("instance_id"))))
        except ValueError:
            valid_uuid = ""
        if (
            set(value) != required_keys
            or value.get("schema_version") != 1
            or value.get("product_id") != PRODUCT_ID
            or value.get("instance_id") != valid_uuid
            or value.get("install_root") != str(self.paths.install_root)
            or value.get("lifecycle_entrypoint") != str(self.paths.entrypoint)
            or not VERSION_PATTERN.fullmatch(str(value.get("version", "")))
        ):
            raise ManagementError(65, "INVALID_MARKER", "Ownership marker is invalid.")
        artifact = value.get("artifact_sha256")
        if artifact is not None and not re.fullmatch(r"[0-9a-f]{64}", str(artifact)):
            raise ManagementError(65, "INVALID_MARKER", "Artifact digest is invalid.")
        return value

    def steps(
        self, invocation: Invocation, configuration: Configuration | None
    ) -> list[dict[str, Any]]:
        operation = invocation.operation
        if operation in {"describe", "status", "verify", "doctor"}:
            return [
                {
                    "id": f"{operation}.inspect",
                    "summary": f"Inspect Beep-owned state for {operation}.",
                    "mutates": False,
                }
            ]
        if operation in {"install", "repair", "update"}:
            verb = "Install" if operation == "install" else operation.capitalize()
            port = configuration.chat_port if configuration is not None else DEFAULT_PORT
            return [
                {
                    "id": f"{operation}.preflight",
                    "summary": "Validate the Beep descriptor, host, inputs, ownership, and collisions.",
                    "mutates": False,
                },
                {
                    "id": f"{operation}.identity",
                    "summary": "Converge only the dedicated beep account, group, and sudo policy.",
                    "mutates": True,
                },
                {
                    "id": f"{operation}.runtime",
                    "summary": f"{verb} the independently copied Beep runtime and dependencies.",
                    "mutates": True,
                },
                {
                    "id": f"{operation}.configuration",
                    "summary": "Converge Beep-only credentials, configuration, policy, state, and audit paths.",
                    "mutates": True,
                },
                {
                    "id": f"{operation}.service",
                    "summary": f"Converge Beep units on loopback TCP port {port}.",
                    "mutates": True,
                },
                {
                    "id": f"{operation}.health",
                    "summary": "Verify Beep policy, runtime, services, ownership, and sibling boundaries before recording ownership.",
                    "mutates": False,
                },
            ]
        summaries = {
            "backup": "Create and verify a protected Beep-only backup.",
            "rollback": "Restore the most recent verified Beep recovery snapshot.",
            "suspend": "Stop Beep services, cancel useful operation, and revoke sessions.",
            "resume": "Revalidate Beep and resume only its services.",
            "uninstall": "Remove only resources proven to be owned by Beep.",
        }
        return [
            {
                "id": f"{operation}.preflight",
                "summary": "Validate Beep ownership and operation inputs.",
                "mutates": False,
            },
            {
                "id": f"{operation}.execute",
                "summary": summaries[operation],
                "mutates": True,
            },
            {
                "id": f"{operation}.verify",
                "summary": "Verify the operation did not alter a sibling product.",
                "mutates": False,
            },
        ]

    def plan_digest(
        self,
        invocation: Invocation,
        steps: list[dict[str, Any]],
        configuration: Configuration | None,
    ) -> str:
        fingerprints: dict[str, Any] = {}
        for key, value in sorted(invocation.inputs.items()):
            if key.endswith("_file"):
                fingerprints[key] = self._secret_file_digest(Path(str(value)))
            else:
                fingerprints[key] = value
        value = {
            "product_id": PRODUCT_ID,
            "version": self.version,
            "operation": invocation.operation,
            "instance": self.instance_id(),
            "inputs": fingerprints,
            "configuration": configuration.object() if configuration else None,
            "retain_state": invocation.retain_state,
            "steps": steps,
        }
        return sha256_bytes(canonical_json(value))

    @staticmethod
    def _secret_file_digest(path: Path) -> str:
        try:
            metadata = path.lstat()
        except OSError as exc:
            raise ManagementError(66, "SECRET_FILE_MISSING", "Secret file is missing.") from exc
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ManagementError(
                73,
                "UNSAFE_SECRET_FILE",
                "Secret files must be root-owned regular files with mode 0600.",
            )
        return sha256_bytes(path.read_bytes())

    def _configuration_secret_path(
        self, invocation: Invocation, key: str, environment: str
    ) -> Path | None:
        value = invocation.inputs.get(key, os.environ.get(environment))
        if value in (None, ""):
            return None
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ManagementError(
                65, "INVALID_CONFIGURATION", f"{key} must be an absolute path."
            )
        path = Path(value)
        self._secret_file_digest(path)
        return path

    def _required_inputs(
        self, invocation: Invocation, configuration: Configuration | None
    ) -> list[dict[str, Any]]:
        required: list[dict[str, Any]] = []
        if invocation.operation in CONFIGURATION_OPERATIONS and configuration is not None:
            password = self._configuration_secret_path(
                invocation, "chat_password_file", "BEEP_ADMIN_PASSWORD_FILE"
            )
            if (
                password is None
                and not self.paths.secrets.is_file()
                and (invocation.non_interactive or not sys.stdin.isatty())
            ):
                required.append({"name": "chat_password_file", "secret": True})
            credential = self._configuration_secret_path(
                invocation,
                "provider_credential_file",
                "BEEP_PROVIDER_CREDENTIAL_FILE",
            )
            if (
                configuration.provider is not None
                and configuration.provider != "lmstudio"
                and credential is None
                and not self._provider_configured(configuration.provider)
            ):
                required.append(
                    {"name": "provider_credential_file", "secret": True}
                )
        if invocation.operation == "backup" and self._backup_destination(invocation) is None:
            required.append({"name": "backup_destination", "secret": False})
        if invocation.operation == "uninstall" and invocation.retain_state is False:
            if invocation.confirmation != DELETE_CONFIRMATION:
                required.append({"name": "confirmation", "secret": False})
        return required

    def _provider_configured(self, provider: str) -> bool:
        if not self.paths.secrets.is_file():
            return False
        key = PROVIDER_KEYS[provider]
        try:
            lines = self.paths.secrets.read_text(encoding="utf-8").splitlines()
        except OSError:
            return False
        return any(line.startswith(f"{key}=") and line != f"{key}=" for line in lines)

    def check(
        self, identifier: str, passed: bool, summary: str, remediation: str
    ) -> dict[str, str]:
        return {
            "id": identifier,
            "status": "pass" if passed else "fail",
            "summary": summary,
            "remediation": "" if passed else remediation,
        }

    def checks(self) -> list[dict[str, str]]:
        marker: dict[str, Any] | None
        marker_error = False
        try:
            marker = self.load_marker(required=False)
        except ManagementError:
            marker = None
            marker_error = True
        installed = marker is not None
        checks = [
            self.check(
                "marker",
                installed and not marker_error,
                "Beep ownership marker is valid.",
                "Run beep-manage doctor and inspect ownership before repair.",
            ),
            self.check(
                "descriptor",
                installed
                and self.paths.descriptor.is_file()
                and not self.paths.descriptor.is_symlink()
                and self.paths.descriptor.read_bytes()
                == (self.source_root / "PRODUCT.json").read_bytes(),
                "Installed Beep descriptor matches this release.",
                "Run beep-manage repair from a verified Beep release.",
            ),
            self.check(
                "runtime",
                installed
                and (self.paths.install_root / "agent" / "server.py").is_file()
                and (self.paths.runtime / "lifecycle.json").is_file(),
                "Beep runtime and lifecycle state are present.",
                "Run beep-manage repair.",
            ),
            self.check(
                "policy",
                installed and self.paths.policy.is_file() and not self.paths.policy.is_symlink(),
                "Beep policy is present.",
                "Restore or repair /etc/beep/policy.yaml.",
            ),
            self.check(
                "credentials",
                installed
                and self.paths.secrets.is_file()
                and not self.paths.secrets.is_symlink()
                and stat.S_IMODE(self.paths.secrets.stat().st_mode) == 0o600,
                "Beep credentials are independently protected.",
                "Run beep-manage repair and rotate Beep credentials.",
            ),
            self.check(
                "service_assets",
                installed
                and all(
                    path.is_file() and not path.is_symlink()
                    for path in (
                        self.paths.chat_unit,
                        self.paths.health_unit,
                        self.paths.health_timer,
                    )
                ),
                "Beep systemd assets are present.",
                "Run beep-manage repair.",
            ),
        ]
        if installed and shutil.which("systemctl"):
            suspended = self.paths.suspended.exists()
            active = self._service_active("beep-chat.service")
            checks.append(
                self.check(
                    "service_state",
                    (suspended and not active) or (not suspended and active),
                    "Beep service state matches lifecycle state.",
                    "Run beep-manage resume or beep-manage suspend as intended.",
                )
            )
        checks.append(
            self.check(
                "no_bundled_products",
                not any(
                    path.exists()
                    for path in (
                        self.paths.install_root / "products",
                        self.paths.install_root / "forgejo",
                        self.paths.install_root / "llama",
                    )
                ),
                "Beep contains only the Systems Administrator product.",
                "Remove the unowned path and reinstall from a verified Beep artifact.",
            )
        )
        return checks

    def run(self, invocation: Invocation) -> tuple[Result, int]:
        configuration = (
            self.configuration(invocation)
            if invocation.operation in CONFIGURATION_OPERATIONS
            else None
        )
        steps = self.steps(invocation, configuration)
        phase = operation_phase(invocation.operation, dry_run=invocation.dry_run)
        result = Result(
            operation=invocation.operation,
            correlation_id=invocation.correlation_id,
            product_version=self.version,
            instance_id=self.instance_id(),
            phase=phase,
            steps=steps,
        )
        if invocation.operation == "describe":
            result.details = {"descriptor": self.descriptor}
            self._best_effort_audit(invocation, result)
            return result, 0
        if invocation.operation == "status":
            marker = self.load_marker(required=False)
            result.status = "ok" if marker is not None else "degraded"
            result.details = {
                "lifecycle": "installed" if marker else "missing",
                "version": marker["version"] if marker else None,
                "suspended": self.paths.suspended.exists(),
            }
            self._best_effort_audit(invocation, result)
            return result, 0
        if invocation.operation in {"verify", "doctor"}:
            result.checks = self.checks()
            failed = any(check["status"] == "fail" for check in result.checks)
            result.status = "degraded" if failed else "ok"
            result.details = {"diagnosis_complete": True}
            self._best_effort_audit(invocation, result)
            if invocation.operation == "verify" and failed:
                return result, 1
            return result, 0
        result.plan_digest = self.plan_digest(invocation, steps, configuration)
        result.requires_confirmation = True
        result.required_inputs = self._required_inputs(invocation, configuration)
        if invocation.dry_run:
            result.status = "blocked" if result.required_inputs else "ok"
            return result, 0
        if result.required_inputs:
            raise ManagementError(
                64,
                "REQUIRED_INPUT",
                "Required lifecycle inputs are missing.",
                recovery=[
                    f"Supply {item['name']} through the documented protected input."
                    for item in result.required_inputs
                ],
            )
        if (
            invocation.supplied_plan_digest is not None
            and invocation.supplied_plan_digest != result.plan_digest
        ):
            raise ManagementError(78, "PLAN_CHANGED", "Supplied plan digest is stale.")
        self._confirm(invocation)
        if os.geteuid() != 0:
            raise ManagementError(
                73, "ROOT_REQUIRED", f"{invocation.operation} requires root."
            )
        event_id = str(uuid.uuid4())
        previous_version: str | None = None
        changed_resources: list[str] = []
        details: dict[str, Any] = {}
        with self._lock():
            recomputed = self.plan_digest(invocation, steps, configuration)
            if recomputed != result.plan_digest:
                raise ManagementError(
                    78, "PLAN_CHANGED", "Host state changed while acquiring the lock."
                )
            if invocation.operation in {"install", "repair", "update"}:
                changed_resources, previous_version = self._execute_converge(
                    invocation,
                    configuration
                    if configuration is not None
                    else self.configuration(invocation),
                    snapshot=invocation.operation in {"install", "update"},
                )
            elif invocation.operation == "backup":
                changed_resources, previous_version, backup = self._execute_backup(
                    invocation
                )
                details["backup"] = {"path": backup}
            elif invocation.operation == "rollback":
                changed_resources, previous_version = self._execute_rollback()
            elif invocation.operation == "suspend":
                changed_resources, previous_version = self._execute_suspend()
            elif invocation.operation == "resume":
                changed_resources, previous_version = self._execute_resume()
            elif invocation.operation == "uninstall":
                changed_resources, previous_version = self._execute_uninstall(invocation)
            else:  # pragma: no cover - argparse and constants prevent this
                raise ManagementError(65, "UNKNOWN_OPERATION", "Unknown operation.")
            result.changed = bool(changed_resources)
            result.instance_id = self.instance_id() or result.instance_id
            result.details = details
            receipt = self._write_receipt(
                result,
                previous_version=previous_version,
                changed_resources=changed_resources,
                event_id=event_id,
            )
            result.receipt = receipt
            self._append_audit(
                invocation,
                result,
                event_id=event_id,
                receipt_digest=receipt["digest"],
            )
        return result, 0

    @staticmethod
    def _confirm(invocation: Invocation) -> None:
        if invocation.assume_yes:
            return
        if invocation.non_interactive or not sys.stdin.isatty():
            raise ManagementError(
                64,
                "CONFIRMATION_REQUIRED",
                "A mutating unattended operation requires --yes.",
            )
        answer = input("Type YES to execute this Beep lifecycle plan: ")
        if answer != "YES":
            raise ManagementError(64, "CONFIRMATION_REQUIRED", "Operation cancelled.")

    @contextmanager
    def _lock(self) -> Iterator[None]:
        self.paths.lock.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(self.paths.lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ManagementError(
                    75, "TARGET_BUSY", "Another Beep lifecycle operation is active.",
                    retryable=True,
                ) from exc
            yield
        finally:
            os.close(descriptor)
            self.paths.lock.unlink(missing_ok=True)

    def _execute_converge(
        self,
        invocation: Invocation,
        configuration: Configuration,
        *,
        snapshot: bool,
    ) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=False)
        previous_version = str(marker["version"]) if marker else None
        instance_id = str(marker["instance_id"]) if marker else self._retained_instance()
        instance_id = instance_id or str(uuid.uuid4())
        self._platform_preflight()
        self._collision_preflight(marker)
        self._port_preflight(configuration.chat_port, marker is not None)
        if snapshot and marker is not None:
            self._create_recovery_snapshot(invocation.correlation_id)
        changed: list[str] = []
        uid, gid = self._ensure_identity(configuration.agent_user, changed)
        self._ensure_directories(uid, gid, changed)
        self._ensure_dependencies(configuration.agent_user, changed)
        self._deploy_runtime(configuration, uid, gid, changed)
        self._deploy_configuration(invocation, configuration, uid, gid, changed)
        self._deploy_services(configuration, uid, gid, changed)
        self._start_services(changed, suspended=self.paths.suspended.exists())
        checks = self.checks_without_marker()
        failed = [check for check in checks if check["status"] == "fail"]
        if failed:
            raise ManagementError(
                1,
                "HEALTH_CHECK_FAILED",
                "Beep failed post-install boundary checks.",
                recovery=["Run beep-manage doctor and inspect the Beep journal."],
            )
        marker_value = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "instance_id": instance_id,
            "version": self.version,
            "source_revision": self._source_revision(),
            "installed_at": marker["installed_at"] if marker else utc_now(),
            "install_root": str(self.paths.install_root),
            "lifecycle_entrypoint": str(self.paths.entrypoint),
            "artifact_sha256": os.environ.get("BEEP_ARTIFACT_SHA256") or None,
        }
        if atomic_write(
            self.paths.marker,
            canonical_json(marker_value) + b"\n",
            mode=0o644,
        ):
            changed.append(str(self.paths.marker))
        self.paths.retained.unlink(missing_ok=True)
        return sorted(set(changed)), previous_version

    def checks_without_marker(self) -> list[dict[str, str]]:
        checks = self.checks()
        for check in checks:
            if check["id"] == "marker":
                check["status"] = "pass"
                check["summary"] = "Marker will be written after health checks."
                check["remediation"] = ""
            elif check["id"] == "descriptor" and self.paths.descriptor.is_file():
                check["status"] = "pass"
                check["summary"] = "Installed descriptor matches this release."
                check["remediation"] = ""
            elif check["id"] in {
                "runtime",
                "policy",
                "credentials",
                "service_assets",
            }:
                predicate = {
                    "runtime": (self.paths.install_root / "agent" / "server.py").is_file()
                    and (self.paths.runtime / "lifecycle.json").is_file(),
                    "policy": self.paths.policy.is_file(),
                    "credentials": self.paths.secrets.is_file(),
                    "service_assets": all(
                        path.is_file()
                        for path in (
                            self.paths.chat_unit,
                            self.paths.health_unit,
                            self.paths.health_timer,
                        )
                    ),
                }[check["id"]]
                if predicate:
                    check["status"] = "pass"
                    check["remediation"] = ""
        return checks

    def _platform_preflight(self) -> None:
        if os.environ.get("BEEP_DISPOSABLE_VM_TEST") == "1":
            return
        if platform.machine() not in {"x86_64", "amd64"}:
            raise ManagementError(69, "UNSUPPORTED_PLATFORM", "Beep supports amd64.")
        release = {}
        try:
            for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
                key, separator, value = line.partition("=")
                if separator:
                    release[key] = value.strip('"')
        except OSError as exc:
            raise ManagementError(
                69, "UNSUPPORTED_PLATFORM", "Cannot read /etc/os-release."
            ) from exc
        if release.get("ID") != "ubuntu" or release.get("VERSION_ID") not in {
            "22.04",
            "24.04",
        }:
            raise ManagementError(
                69,
                "UNSUPPORTED_PLATFORM",
                "Beep supports Ubuntu Desktop 22.04 and 24.04 LTS.",
            )

    def _collision_preflight(self, marker: dict[str, Any] | None) -> None:
        if marker is not None:
            return
        retained = self._load_retained()
        allowed = {
            self.paths.state_root,
            self.paths.configuration_root,
            self.paths.log_root,
        } if retained else set()
        resources = (
            self.paths.install_root,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
            self.paths.logrotate,
            self.paths.sudoers,
            self.paths.entrypoint,
        )
        collisions = [str(path) for path in resources if path.exists() and path not in allowed]
        try:
            pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            pass
        else:
            if not retained:
                collisions.append("user:beep")
        if collisions:
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "Unowned Beep resource collision: " + ", ".join(sorted(collisions)),
            )

    @staticmethod
    def _port_preflight(port: int, installed: bool) -> None:
        if installed:
            return
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", port))
            except OSError as exc:
                raise ManagementError(
                    73, "PORT_COLLISION", f"Loopback TCP port {port} is unavailable."
                ) from exc

    def _retained_instance(self) -> str | None:
        retained = self._load_retained()
        return str(retained["instance_id"]) if retained else None

    def _load_retained(self) -> dict[str, Any] | None:
        if not self.paths.retained.is_file() or self.paths.retained.is_symlink():
            return None
        value = load_json(self.paths.retained)
        if set(value) != {"schema_version", "product_id", "instance_id"}:
            raise ManagementError(65, "INVALID_RETAINED_STATE", "Retained state is invalid.")
        try:
            instance = str(uuid.UUID(str(value["instance_id"])))
        except ValueError as exc:
            raise ManagementError(
                65, "INVALID_RETAINED_STATE", "Retained instance is invalid."
            ) from exc
        if value != {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "instance_id": instance,
        }:
            raise ManagementError(65, "INVALID_RETAINED_STATE", "Retained state is invalid.")
        return value

    def _ensure_identity(
        self, agent_user: str, changed: list[str]
    ) -> tuple[int, int]:
        try:
            group = grp.getgrnam(agent_user)
        except KeyError:
            self._run(["groupadd", "--system", agent_user])
            changed.append(f"group:{agent_user}")
            group = grp.getgrnam(agent_user)
        try:
            user = pwd.getpwnam(agent_user)
        except KeyError:
            self._run(
                [
                    "useradd",
                    "--create-home",
                    "--shell",
                    "/bin/bash",
                    "--gid",
                    agent_user,
                    "--comment",
                    "Beep AI Systems Administrator",
                    agent_user,
                ]
            )
            self._run(["passwd", "--lock", agent_user], check=False)
            changed.append(f"user:{agent_user}")
            user = pwd.getpwnam(agent_user)
        if user.pw_gid != group.gr_gid:
            raise ManagementError(
                73, "IDENTITY_COLLISION", "Existing beep identity has the wrong group."
            )
        sudoers = (
            "# Managed by beep-manage. Beep is intentionally root-capable.\n"
            f"{agent_user} ALL=(ALL) NOPASSWD:ALL\n"
        ).encode()
        with tempfile.NamedTemporaryFile() as temporary:
            temporary.write(sudoers)
            temporary.flush()
            if shutil.which("visudo"):
                self._run(["visudo", "-cf", temporary.name])
        if atomic_write(self.paths.sudoers, sudoers, mode=0o440):
            changed.append(str(self.paths.sudoers))
        return user.pw_uid, group.gr_gid

    def _ensure_directories(
        self, uid: int, gid: int, changed: list[str]
    ) -> None:
        declarations = (
            (self.paths.install_root, 0o755, 0, 0),
            (self.paths.configuration_root, 0o755, 0, 0),
            (self.paths.configuration_root / "secrets", 0o700, uid, gid),
            (self.paths.configuration_root / "skills.d", 0o755, 0, 0),
            (self.paths.state_root, 0o750, uid, gid),
            (self.paths.runtime, 0o700, uid, gid),
            (self.paths.runtime / "logs", 0o750, uid, gid),
            (self.paths.runtime / "pi-mono-sessions", 0o700, uid, gid),
            (self.paths.log_root, 0o750, uid, gid),
            (self.paths.receipts, 0o750, uid, gid),
            (self.paths.rollback_root, 0o700, 0, 0),
        )
        for path, mode, owner, group in declarations:
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Refusing symlink: {path}")
            if not path.exists():
                path.mkdir(parents=True, mode=mode)
                changed.append(str(path))
            os.chmod(path, mode)
            os.chown(path, owner, group)

    def _ensure_dependencies(self, agent_user: str, changed: list[str]) -> None:
        missing = [name for name in ("python3", "npm", "node", "sudo") if not shutil.which(name)]
        if missing:
            if not shutil.which("apt-get"):
                raise ManagementError(
                    69, "DEPENDENCY_MISSING", "apt-get is required to install dependencies."
                )
            environment = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
            self._run(["apt-get", "update", "-qq"], environment=environment)
            self._run(
                ["apt-get", "install", "-y", *SYSTEM_PACKAGES, "nodejs", "npm"],
                environment=environment,
            )
            changed.append("system-packages")
        home = Path(pwd.getpwnam(agent_user).pw_dir)
        virtualenv = home / "agent-env"
        if not (virtualenv / "bin" / "python").is_file():
            venv.EnvBuilder(with_pip=False).create(virtualenv)
            self._chown_tree(virtualenv, pwd.getpwnam(agent_user).pw_uid, grp.getgrnam(agent_user).gr_gid)
            changed.append(str(virtualenv))
        self._install_bridges(changed)

    def _install_bridges(self, changed: list[str]) -> None:
        if not shutil.which("npm") or not shutil.which("node"):
            raise ManagementError(69, "DEPENDENCY_MISSING", "Node and npm are required.")
        lock = self.source_root / "payload" / "agent" / "bridge-dependencies.lock"
        pins: list[tuple[str, str, str, str]] = []
        for line in lock.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) != 7:
                raise ManagementError(78, "INVALID_DEPENDENCY_LOCK", "Bridge lock is invalid.")
            _, package, version, url, digest, _, _ = fields
            pins.append((package, version, url, digest))
        installed = self._run(
            ["npm", "ls", "-g", "--depth=0", "--json"],
            check=False,
        )
        try:
            npm_state = json.loads(installed.stdout or "{}").get("dependencies", {})
        except json.JSONDecodeError:
            npm_state = {}
        required = [
            pin for pin in pins if npm_state.get(pin[0], {}).get("version") != pin[1]
        ]
        if not required:
            return
        with tempfile.TemporaryDirectory(prefix="beep-bridges-") as directory:
            archives: list[str] = []
            for package, version, url, digest in required:
                parsed = urllib.parse.urlsplit(url)
                if parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org":
                    raise ManagementError(78, "INVALID_DEPENDENCY_LOCK", "Bridge URL is unsafe.")
                destination = Path(directory) / f"{package.rsplit('/', 1)[-1]}-{version}.tgz"
                request = urllib.request.Request(url, headers={"User-Agent": "beep-manage/1"})
                try:
                    with urllib.request.urlopen(request, timeout=30) as response:
                        data = response.read(MAX_DOWNLOAD_BYTES + 1)
                except OSError as exc:
                    raise ManagementError(
                        75,
                        "DEPENDENCY_DOWNLOAD_FAILED",
                        "Could not download a pinned Beep bridge.",
                        retryable=True,
                    ) from exc
                if len(data) > MAX_DOWNLOAD_BYTES or hashlib.sha256(data).hexdigest() != digest:
                    raise ManagementError(
                        78, "DEPENDENCY_INTEGRITY_FAILED", "Bridge digest did not match."
                    )
                destination.write_bytes(data)
                archives.append(str(destination))
            self._run(["npm", "install", "-g", "--ignore-scripts", *archives])
        changed.append("pinned-node-bridges")

    def _deploy_runtime(
        self,
        configuration: Configuration,
        uid: int,
        gid: int,
        changed: list[str],
    ) -> None:
        payload = self.source_root / "payload"
        self._sync_tree(payload / "agent", self.paths.install_root / "agent", changed)
        self._sync_tree(payload / "bin", self.paths.install_root / "bin", changed, executable=True)
        self._sync_tree(
            payload / "agent" / "skills",
            self.paths.install_root / "skills",
            changed,
        )
        pi_root = self.paths.install_root / "pi"
        pi_root.mkdir(parents=True, exist_ok=True)
        settings = (payload / "agent" / "templates" / "settings.json.tmpl").read_bytes()
        if atomic_write(pi_root / "settings.json", settings, mode=0o644):
            changed.append(str(pi_root / "settings.json"))
        template = (
            payload / "agent" / "templates" / "APPEND_SYSTEM.md.tmpl"
        ).read_text(encoding="utf-8")
        rendered = template.replace("__AGENT_USER__", configuration.agent_user).replace(
            "__FACTS__", "Generated at runtime by the authenticated Beep chat service."
        )
        if atomic_write(
            pi_root / "APPEND_SYSTEM.md", rendered.encode(), mode=0o644
        ):
            changed.append(str(pi_root / "APPEND_SYSTEM.md"))
        version_path = self.paths.install_root / "VERSION"
        if atomic_write(version_path, f"{self.version}\n".encode(), mode=0o644):
            changed.append(str(version_path))
        self._deploy_product_source(changed)
        for path in self.paths.install_root.rglob("*"):
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Runtime contains symlink: {path}")
            if path.is_dir():
                os.chmod(path, 0o755)
            elif path.parent == self.paths.install_root / "bin":
                os.chmod(path, 0o755)
            else:
                os.chmod(path, 0o644)
            os.chown(path, 0, 0)
        os.chown(self.paths.install_root, 0, 0)
        os.chmod(self.paths.install_root, 0o755)
        os.chown(self.paths.runtime, uid, gid)

    def _deploy_product_source(self, changed: list[str]) -> None:
        if self.source_root == self.paths.product_root.resolve(strict=False):
            return
        staging = self.paths.install_root / f".product-{uuid.uuid4().hex}"
        shutil.copytree(
            self.source_root,
            staging,
            symlinks=False,
            ignore=shutil.ignore_patterns("dist", "__pycache__", "*.pyc"),
        )
        if self.paths.product_root.exists():
            shutil.rmtree(self.paths.product_root)
        os.replace(staging, self.paths.product_root)
        changed.append(str(self.paths.product_root))

    def _sync_tree(
        self,
        source: Path,
        destination: Path,
        changed: list[str],
        *,
        executable: bool = False,
    ) -> None:
        if not source.is_dir():
            raise ManagementError(66, "SOURCE_INCOMPLETE", f"Missing source tree: {source}")
        destination.mkdir(parents=True, exist_ok=True)
        expected: set[Path] = set()
        for item in sorted(source.rglob("*")):
            relative = item.relative_to(source)
            target = destination / relative
            expected.add(target)
            if item.is_symlink():
                raise ManagementError(78, "UNSAFE_SOURCE", f"Source symlink rejected: {item}")
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            mode = 0o755 if executable or os.access(item, os.X_OK) else 0o644
            if atomic_write(target, item.read_bytes(), mode=mode):
                changed.append(str(target))
        for target in sorted(destination.rglob("*"), reverse=True):
            if target not in expected:
                if target.is_dir():
                    target.rmdir()
                else:
                    target.unlink()
                changed.append(str(target))

    def _deploy_configuration(
        self,
        invocation: Invocation,
        configuration: Configuration,
        uid: int,
        gid: int,
        changed: list[str],
    ) -> None:
        if atomic_write(
            self.paths.descriptor,
            (self.source_root / "PRODUCT.json").read_bytes(),
            mode=0o644,
        ):
            changed.append(str(self.paths.descriptor))
        if not self.paths.policy.exists():
            if atomic_write(
                self.paths.policy,
                (self.source_root / "payload" / "etc" / "policy.yaml").read_bytes(),
                mode=0o644,
            ):
                changed.append(str(self.paths.policy))
        password_file = self._configuration_secret_path(
            invocation, "chat_password_file", "BEEP_ADMIN_PASSWORD_FILE"
        )
        existing = self._read_secret_environment()
        if password_file is not None:
            password = self._read_one_secret(password_file, minimum=12)
            existing["BEEP_ADMIN_PASSWORD_HASH"] = runtime_auth.hash_password(password)
        elif "BEEP_ADMIN_PASSWORD_HASH" not in existing:
            password = self._interactive_password()
            existing["BEEP_ADMIN_PASSWORD_HASH"] = runtime_auth.hash_password(password)
        credential_file = self._configuration_secret_path(
            invocation,
            "provider_credential_file",
            "BEEP_PROVIDER_CREDENTIAL_FILE",
        )
        if configuration.provider is not None:
            existing["BEEP_PROVIDER"] = configuration.provider
            if credential_file is not None:
                existing[PROVIDER_KEYS[configuration.provider]] = self._read_one_secret(
                    credential_file, minimum=1
                )
            elif configuration.provider == "lmstudio":
                existing.setdefault("LMSTUDIO_API_KEY", "local")
        if configuration.model is not None:
            existing["BEEP_MODEL"] = configuration.model
        if configuration.model_base_url is not None:
            existing["BEEP_MODEL_BASE_URL"] = configuration.model_base_url
        existing.update(
            {
                "BEEP_DIR": str(self.paths.install_root),
                "BEEP_SECRETS": str(self.paths.secrets),
                "BEEP_POLICY": str(self.paths.policy),
                "BEEP_HISTORY_DB": str(self.paths.runtime / "conversations.db"),
                "BEEP_LIFECYCLE_STATE": str(self.paths.runtime / "lifecycle.json"),
                "BEEP_AUDIT_LOG": str(self.paths.audit),
                "BEEP_CHAT_PORT": str(configuration.chat_port),
                "BEEP_USER": configuration.agent_user,
            }
        )
        content = "".join(f"{key}={self._quote_env(value)}\n" for key, value in sorted(existing.items()))
        if atomic_write(
            self.paths.secrets,
            content.encode(),
            mode=0o600,
            uid=uid,
            gid=gid,
        ):
            changed.append(str(self.paths.secrets))
        if not self.paths.session_key.exists():
            key = secrets.token_urlsafe(48).encode() + b"\n"
            if atomic_write(
                self.paths.session_key, key, mode=0o600, uid=uid, gid=gid
            ):
                changed.append(str(self.paths.session_key))
        if atomic_write(
            self.paths.config,
            canonical_json(configuration.object()) + b"\n",
            mode=0o640,
            gid=gid,
        ):
            changed.append(str(self.paths.config))
        lifecycle_path = self.paths.runtime / "lifecycle.json"
        os.environ["BEEP_LIFECYCLE_STATE"] = str(lifecycle_path)
        if not lifecycle_path.exists():
            runtime_lifecycle.initialize(configuration.ttl_days)
            os.chown(lifecycle_path, uid, gid)
            changed.append(str(lifecycle_path))

    @staticmethod
    def _quote_env(value: str) -> str:
        if "\n" in value or "\r" in value or "\x00" in value:
            raise ManagementError(65, "INVALID_SECRET", "Environment value is invalid.")
        return "'" + value.replace("'", "'\"'\"'") + "'"

    def _read_secret_environment(self) -> dict[str, str]:
        if not self.paths.secrets.is_file() or self.paths.secrets.is_symlink():
            return {}
        result: dict[str, str] = {}
        for line in self.paths.secrets.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                raise ManagementError(78, "INVALID_SECRET_ENV", "Secret environment is invalid.")
            if value.startswith("'") and value.endswith("'"):
                value = value[1:-1].replace("'\"'\"'", "'")
            result[key] = value
        return result

    @staticmethod
    def _read_one_secret(path: Path, *, minimum: int) -> str:
        try:
            value = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise ManagementError(65, "INVALID_SECRET", "Secret file is not UTF-8.") from exc
        value = value.rstrip("\n")
        if "\n" in value or "\r" in value or not minimum <= len(value.encode()) <= 1024:
            raise ManagementError(
                65, "INVALID_SECRET", "Secret file must contain one bounded UTF-8 line."
            )
        return value

    @staticmethod
    def _interactive_password() -> str:
        if not sys.stdin.isatty():
            raise ManagementError(
                64, "REQUIRED_INPUT", "A protected chat_password_file is required."
            )
        first = getpass.getpass("Beep chat password (12-1024 bytes): ")
        second = getpass.getpass("Confirm Beep chat password: ")
        if first != second or not 12 <= len(first.encode()) <= 1024:
            raise ManagementError(
                64, "INVALID_PASSWORD", "Passwords did not match or were out of bounds."
            )
        return first

    def _deploy_services(
        self,
        configuration: Configuration,
        uid: int,
        gid: int,
        changed: list[str],
    ) -> None:
        payload = self.source_root / "payload"
        home = Path(pwd.getpwnam(configuration.agent_user).pw_dir)
        replacements = {
            "__AGENT_USER__": configuration.agent_user,
            "__AGENT_HOME__": str(home),
            "__BEEP_DIR__": str(self.paths.install_root),
        }
        assets = (
            ("systemd/beep-chat.service", self.paths.chat_unit, 0o644),
            ("systemd/beep-health.service", self.paths.health_unit, 0o644),
            ("systemd/beep-health.timer", self.paths.health_timer, 0o644),
            ("logrotate/beep", self.paths.logrotate, 0o644),
        )
        for source_name, destination, mode in assets:
            value = (payload / source_name).read_text(encoding="utf-8")
            for old, new in replacements.items():
                value = value.replace(old, new)
            if "__" in value and source_name.startswith(("systemd/", "logrotate/")):
                unresolved = re.findall(r"__[A-Z][A-Z0-9_]*__", value)
                if unresolved:
                    raise ManagementError(78, "UNRESOLVED_TEMPLATE", "Service template is invalid.")
            if atomic_write(destination, value.encode(), mode=mode):
                changed.append(str(destination))
        wrapper = (self.source_root / "scripts" / "manage.sh").read_bytes()
        if atomic_write(self.paths.entrypoint, wrapper, mode=0o755):
            changed.append(str(self.paths.entrypoint))
        commands = (
            "beep-audit-recent",
            "beep-chat",
            "beep-diagnostics",
            "beep-health",
            "beep-secrets-edit",
            "beep-verify-release",
        )
        for command in commands:
            destination = Path("/usr/local/bin") / command
            source = self.paths.install_root / "bin" / command
            if atomic_write(destination, source.read_bytes(), mode=0o755):
                changed.append(str(destination))
        os.chown(self.paths.secrets, uid, gid)

    def _start_services(self, changed: list[str], *, suspended: bool) -> None:
        if not shutil.which("systemctl"):
            raise ManagementError(69, "SYSTEMD_MISSING", "systemctl is required.")
        self._run(["systemctl", "daemon-reload"])
        if suspended:
            self._run(["systemctl", "disable", "--now", "beep-chat.service"], check=False)
            return
        self._run(["systemctl", "enable", "--now", "beep-chat.service"])
        self._run(["systemctl", "enable", "--now", "beep-health.timer"])
        changed.extend(["unit:beep-chat.service", "unit:beep-health.timer"])

    def _execute_backup(
        self, invocation: Invocation
    ) -> tuple[list[str], str | None, str]:
        marker = self.load_marker(required=True)
        destination = self._backup_destination(invocation)
        if destination is None:
            raise ManagementError(64, "REQUIRED_INPUT", "backup_destination is required.")
        destination.mkdir(parents=True, exist_ok=True)
        archive = destination / f"beep-{self.version}-{invocation.correlation_id}.tar.gz"
        if archive.exists() or archive.is_symlink():
            raise ManagementError(73, "BACKUP_EXISTS", "Backup destination already exists.")
        with tarfile.open(archive, "x:gz") as output:
            for path, name in (
                (self.paths.configuration_root, "etc"),
                (self.paths.state_root, "state"),
                (self.paths.log_root, "log"),
            ):
                self._assert_tree_safe(path)
                output.add(path, arcname=name, recursive=True)
            manifest = canonical_json(
                {
                    "schema_version": 1,
                    "product_id": PRODUCT_ID,
                    "instance_id": marker["instance_id"],
                    "version": marker["version"],
                    "created_at": utc_now(),
                }
            ) + b"\n"
            info = tarfile.TarInfo("manifest.json")
            info.size = len(manifest)
            info.mode = 0o600
            with tempfile.SpooledTemporaryFile() as handle:
                handle.write(manifest)
                handle.seek(0)
                output.addfile(info, handle)
        os.chmod(archive, 0o600)
        with tarfile.open(archive, "r:gz") as check:
            names = set(check.getnames())
            if "manifest.json" not in names:
                raise ManagementError(1, "BACKUP_INVALID", "Backup verification failed.")
        return [str(archive)], str(marker["version"]), str(archive)

    def _backup_destination(self, invocation: Invocation) -> Path | None:
        value = invocation.inputs.get(
            "backup_destination", os.environ.get("BEEP_BACKUP_DESTINATION")
        )
        if value in (None, ""):
            return None
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ManagementError(
                65, "INVALID_BACKUP_DESTINATION", "Backup destination must be absolute."
            )
        destination = Path(value).resolve(strict=False)
        protected = (
            self.paths.install_root,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
            Path("/opt/ai-zombie"),
            Path("/etc/ubuntu-zombie"),
            Path("/var/lib/ubuntu-zombie"),
            Path("/var/log/ubuntu-zombie"),
            Path("/opt/imaginary-friend"),
            Path("/opt/llama.cpp"),
        )
        if any(destination == root or root in destination.parents for root in protected):
            raise ManagementError(
                65,
                "INVALID_BACKUP_DESTINATION",
                "Backup destination must be outside every product root.",
            )
        return destination

    def _create_recovery_snapshot(self, correlation_id: str) -> Path:
        snapshot = self.paths.rollback_root / correlation_id
        if snapshot.exists():
            shutil.rmtree(snapshot)
        snapshot.mkdir(parents=True, mode=0o700)
        for source, name in (
            (self.paths.install_root, "opt"),
            (self.paths.configuration_root, "etc"),
            (self.paths.state_root, "state"),
        ):
            self._assert_tree_safe(source)
            shutil.copytree(source, snapshot / name, symlinks=False)
        atomic_write(
            snapshot / "snapshot.json",
            canonical_json(
                {
                    "schema_version": 1,
                    "product_id": PRODUCT_ID,
                    "created_at": utc_now(),
                    "version": self.version,
                }
            )
            + b"\n",
            mode=0o600,
        )
        atomic_write(
            self.paths.rollback_root / "latest",
            f"{snapshot.name}\n".encode(),
            mode=0o600,
        )
        return snapshot

    def _execute_rollback(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        latest = self.paths.rollback_root / "latest"
        if not latest.is_file() or latest.is_symlink():
            raise ManagementError(66, "ROLLBACK_UNAVAILABLE", "No rollback snapshot exists.")
        name = latest.read_text(encoding="utf-8").strip()
        if not re.fullmatch(r"[0-9a-f-]{36}", name):
            raise ManagementError(65, "ROLLBACK_INVALID", "Rollback metadata is invalid.")
        snapshot = self.paths.rollback_root / name
        metadata = load_json(snapshot / "snapshot.json")
        if metadata.get("product_id") != PRODUCT_ID:
            raise ManagementError(65, "ROLLBACK_INVALID", "Rollback snapshot is invalid.")
        self._stop_services()
        for source, destination in (
            (snapshot / "opt", self.paths.install_root),
            (snapshot / "etc", self.paths.configuration_root),
            (snapshot / "state", self.paths.state_root),
        ):
            self._assert_tree_safe(source)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(source, destination, symlinks=False)
        self._start_services([], suspended=self.paths.suspended.exists())
        return [
            str(self.paths.install_root),
            str(self.paths.configuration_root),
            str(self.paths.state_root),
        ], str(marker["version"])

    def _execute_suspend(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        self._stop_services()
        value = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "suspended_at": utc_now(),
        }
        changed = atomic_write(
            self.paths.suspended, canonical_json(value) + b"\n", mode=0o600
        )
        return ([str(self.paths.suspended)] if changed else []), str(marker["version"])

    def _execute_resume(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        failed = [check for check in self.checks() if check["status"] == "fail" and check["id"] != "service_state"]
        if failed:
            raise ManagementError(
                78, "RESUME_BLOCKED", "Beep integrity checks failed before resume."
            )
        changed: list[str] = []
        if self.paths.suspended.exists():
            self.paths.suspended.unlink()
            changed.append(str(self.paths.suspended))
        self._start_services(changed, suspended=False)
        return sorted(set(changed)), str(marker["version"])

    def _execute_uninstall(
        self, invocation: Invocation
    ) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        if invocation.retain_state is False and invocation.confirmation != DELETE_CONFIRMATION:
            raise ManagementError(
                64,
                "DESTRUCTIVE_CONFIRMATION_REQUIRED",
                f"Complete removal requires confirmation: {DELETE_CONFIRMATION}",
            )
        self._stop_services()
        changed: list[str] = []
        for path in (
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
            self.paths.logrotate,
            self.paths.sudoers,
            self.paths.entrypoint,
            *(Path("/usr/local/bin") / name for name in (
                "beep-audit-recent",
                "beep-chat",
                "beep-diagnostics",
                "beep-health",
                "beep-secrets-edit",
                "beep-verify-release",
            )),
        ):
            if path.exists() and not path.is_symlink():
                path.unlink()
                changed.append(str(path))
            elif path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Refusing symlink: {path}")
        if self.paths.install_root.exists():
            self._assert_tree_safe(self.paths.install_root)
            shutil.rmtree(self.paths.install_root)
            changed.append(str(self.paths.install_root))
        if invocation.retain_state:
            retained = {
                "schema_version": 1,
                "product_id": PRODUCT_ID,
                "instance_id": marker["instance_id"],
            }
            atomic_write(
                self.paths.retained, canonical_json(retained) + b"\n", mode=0o600
            )
            self.paths.marker.unlink(missing_ok=True)
        else:
            for path in (
                self.paths.configuration_root,
                self.paths.state_root,
                self.paths.log_root,
            ):
                if path.exists():
                    self._assert_tree_safe(path)
                    shutil.rmtree(path)
                    changed.append(str(path))
            self._run(["userdel", "--remove", DEFAULT_USER], check=False)
            self._run(["groupdel", DEFAULT_USER], check=False)
            changed.extend(["user:beep", "group:beep"])
        if shutil.which("systemctl"):
            self._run(["systemctl", "daemon-reload"], check=False)
        return sorted(set(changed)), str(marker["version"])

    def _stop_services(self) -> None:
        if not shutil.which("systemctl"):
            return
        for unit in ("beep-health.timer", "beep-chat.service"):
            self._run(["systemctl", "disable", "--now", unit], check=False)
            if self._service_active(unit):
                raise ManagementError(1, "SERVICE_STOP_FAILED", f"{unit} remained active.")

    @staticmethod
    def _service_active(unit: str) -> bool:
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", unit],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0

    def _source_revision(self) -> str:
        digest = hashlib.sha256()
        for path in sorted(self.source_root.rglob("*")):
            if (
                not path.is_file()
                or path.is_symlink()
                or "dist" in path.parts
                or "__pycache__" in path.parts
            ):
                continue
            digest.update(str(path.relative_to(self.source_root)).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        return f"source:{digest.hexdigest()}"

    @staticmethod
    def _assert_tree_safe(root: Path) -> None:
        if root.is_symlink() or not root.is_dir():
            raise ManagementError(73, "UNSAFE_PATH", f"Unsafe product tree: {root}")
        for path in root.rglob("*"):
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Symlink rejected: {path}")

    @staticmethod
    def _chown_tree(root: Path, uid: int, gid: int) -> None:
        for path in (root, *root.rglob("*")):
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Symlink rejected: {path}")
            os.chown(path, uid, gid)

    @staticmethod
    def _run(
        arguments: list[str],
        *,
        check: bool = True,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            arguments,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=1800,
            env=environment,
        )
        if check and completed.returncode != 0:
            raise ManagementError(
                1,
                "COMMAND_FAILED",
                f"Required command failed: {Path(arguments[0]).name}",
                recovery=["Inspect the Beep lifecycle audit and system journal."],
            )
        return completed

    def _write_receipt(
        self,
        result: Result,
        *,
        previous_version: str | None,
        changed_resources: list[str],
        event_id: str,
    ) -> dict[str, str]:
        self.paths.receipts.mkdir(parents=True, exist_ok=True)
        receipt = {
            "schema_version": 1,
            "response": result.object(),
            "installed_version": self.version
            if result.operation != "uninstall"
            else None,
            "previous_version": previous_version,
            "changed_resources": sorted(set(changed_resources)),
            "audit_event_id": event_id,
        }
        content = canonical_json(receipt) + b"\n"
        historical = self.paths.receipts / f"{result.correlation_id}.json"
        atomic_write(historical, content, mode=0o640)
        atomic_write(self.paths.receipt, content, mode=0o640)
        return {"path": str(self.paths.receipt), "digest": sha256_bytes(content)}

    def _append_audit(
        self,
        invocation: Invocation,
        result: Result,
        *,
        event_id: str,
        receipt_digest: str | None,
    ) -> None:
        event = {
            "timestamp": utc_now(),
            "event_id": event_id,
            "correlation_id": invocation.correlation_id,
            "product_id": PRODUCT_ID,
            "instance_id": result.instance_id,
            "operation": invocation.operation,
            "phase": result.phase,
            "actor": invocation.actor,
            "decision": "denied" if result.status == "blocked" else "allowed",
            "result": result.status,
            "changed": result.changed,
            "receipt_digest": receipt_digest,
        }
        self.paths.audit.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            self.paths.audit,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
            0o640,
        )
        try:
            os.write(descriptor, canonical_json(event) + b"\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _best_effort_audit(self, invocation: Invocation, result: Result) -> None:
        if not self.paths.log_root.exists():
            return
        try:
            self._append_audit(
                invocation,
                result,
                event_id=str(uuid.uuid4()),
                receipt_digest=None,
            )
        except OSError:
            if result.operation not in {"status", "doctor"}:
                raise ManagementError(1, "AUDIT_FAILED", "Could not write Beep audit.")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(prog="beep-manage")
    value.add_argument("operation", choices=OPERATIONS)
    value.add_argument("--dry-run", action="store_true")
    value.add_argument("--json", action="store_true")
    value.add_argument("--non-interactive", action="store_true")
    value.add_argument("--request-file", type=Path)
    value.add_argument("--correlation-id")
    value.add_argument("--plan-digest")
    value.add_argument("--confirmation")
    value.add_argument("--yes", action="store_true")
    value.add_argument("--purge", action="store_true")
    return value


def print_result(result: Result, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result.object(), ensure_ascii=False, sort_keys=True))
        return
    print(f"Beep {result.operation}: {result.status}")
    if result.plan_digest:
        print(f"Plan digest: {result.plan_digest}")
    for step in result.steps:
        print(f"  - {step['summary']}")
    for check in result.checks:
        print(f"  [{check['status']}] {check['summary']}")
    for error in result.errors:
        print(f"  error {error['code']}: {error['message']}", file=sys.stderr)


def failure_result(
    manager: Manager | None,
    args: argparse.Namespace,
    error: ManagementError,
    *,
    correlation_id: str | None = None,
) -> Result:
    try:
        identifier = correlation_id or args.correlation_id or str(uuid.uuid4())
        if str(uuid.UUID(identifier)) != identifier:
            identifier = str(uuid.uuid4())
    except (ValueError, AttributeError):
        identifier = str(uuid.uuid4())
    version = manager.version if manager is not None else "0000.00.00.00.00.00"
    instance = None
    if manager is not None:
        try:
            instance = manager.instance_id()
        except ManagementError:
            instance = None
    return Result(
        operation=args.operation,
        correlation_id=identifier,
        product_version=version,
        instance_id=instance,
        phase=operation_phase(args.operation, dry_run=args.dry_run),
        status="blocked"
        if error.exit_code in {64, 65, 66, 69, 73, 75, 78}
        else "failed",
        errors=[
            {
                "code": error.code,
                "message": error.message,
                "retryable": error.retryable,
            }
        ],
        recovery=error.recovery,
    )


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    manager: Manager | None = None
    invocation: Invocation | None = None
    try:
        manager = Manager()
        invocation = manager.invocation(args)
        result, exit_code = manager.run(invocation)
    except ManagementError as error:
        result = failure_result(
            manager,
            args,
            error,
            correlation_id=invocation.correlation_id if invocation else None,
        )
        if manager is not None and invocation is not None:
            try:
                manager._append_audit(
                    invocation,
                    result,
                    event_id=str(uuid.uuid4()),
                    receipt_digest=None,
                )
            except (OSError, ManagementError):
                pass
        exit_code = error.exit_code
    except Exception:
        error = ManagementError(
            1,
            "UNEXPECTED_FAILURE",
            "Unexpected Beep lifecycle failure; inspect local audit and journal.",
        )
        result = failure_result(
            manager,
            args,
            error,
            correlation_id=invocation.correlation_id if invocation else None,
        )
        exit_code = 1
    print_result(result, as_json=args.json)
    return exit_code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
