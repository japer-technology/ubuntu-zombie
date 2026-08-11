"""Independent root-only lifecycle for the Beep Systems Administrator."""

from __future__ import annotations

import argparse
import fcntl
import getpass
import grp
import hashlib
import http.client
import ipaddress
import json
import os
import platform
import posixpath
import pwd
import re
import secrets
import shlex
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import venv
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterator

import auth as runtime_auth
import family as runtime_family
import history as runtime_history
import lifecycle as runtime_lifecycle
import policy as runtime_policy


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
    "kill",
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
    "kill",
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
    "kill": set(),
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
SECRET_ENV_KEYS = {
    "BEEP_ADMIN_PASSWORD_HASH",
    "BEEP_PROVIDER",
    "BEEP_MODEL",
    "BEEP_MODEL_BASE_URL",
    "OPENAI_BASE_URL",
    "BEEP_DIR",
    "BEEP_SECRETS",
    "BEEP_POLICY",
    "BEEP_HISTORY_DB",
    "BEEP_LIFECYCLE_STATE",
    "BEEP_AUDIT_LOG",
    "BEEP_CHAT_PORT",
    "BEEP_USER",
    *PROVIDER_KEYS.values(),
}
DEFAULT_USER = "beep"
DEFAULT_PORT = 58989
DEFAULT_TTL_DAYS = 7
DEFAULT_LM_STUDIO_URL = "http://127.0.0.1:1234/v1"
DELETE_CONFIRMATION = "DELETE BEEP STATE"
VERSION_PATTERN = re.compile(r"^\d{4}(?:\.\d{2}){5}$")
USER_PATTERN = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
NODE_VERSION = "22.23.2"
NODE_ARCHIVE = f"node-v{NODE_VERSION}-linux-x64.tar.xz"
NODE_URL = f"https://nodejs.org/dist/v{NODE_VERSION}/{NODE_ARCHIVE}"
NODE_SHA256 = "d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307"
MAX_NODE_ARCHIVE_BYTES = 128 * 1024 * 1024
DEPENDENCY_ATTEMPTS = 4
DEPENDENCY_RETRY_SECONDS = 5
APT_LOCK_WAIT_SECONDS = 300
LEGACY_MANAGER_SHA256 = (
    "3bc48547ef0eea690b58a5ef702a6f6934e1f289e7411ee086167f3fa5697333"
)
DEPENDENCY_ENVIRONMENT_KEYS = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
)
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
HOST_COMMANDS = (
    "beep-audit-recent",
    "beep-chat",
    "beep-diagnostics",
    "beep-health",
    "beep-secrets-edit",
    "beep-verify-release",
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
    account_home: Path = Path("/home/beep")
    configuration_root: Path = Path("/etc/beep")
    state_root: Path = Path("/var/lib/beep")
    log_root: Path = Path("/var/log/beep")
    chat_unit: Path = Path("/etc/systemd/system/beep-chat.service")
    health_unit: Path = Path("/etc/systemd/system/beep-health.service")
    health_timer: Path = Path("/etc/systemd/system/beep-health.timer")
    logrotate: Path = Path("/etc/logrotate.d/beep")
    sudoers: Path = Path("/etc/sudoers.d/90-beep")
    entrypoint: Path = Path("/usr/local/sbin/beep-manage")
    command_root: Path = Path("/usr/local/bin")
    lock: Path = Path("/run/lock/beep.lock")
    rollback_root: Path = Path("/var/lib/beep/recovery")

    @property
    def marker(self) -> Path:
        return self.state_root / "installation.json"

    @property
    def retained(self) -> Path:
        return self.state_root / "retained.json"

    @property
    def pending_install(self) -> Path:
        return self.state_root.with_name(f"{self.state_root.name}.installing.json")

    @property
    def purge_state(self) -> Path:
        return self.state_root.with_name(f"{self.state_root.name}.purging.json")

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
    def agents_configuration(self) -> Path:
        return self.configuration_root / "agents"

    @property
    def catalog(self) -> Path:
        return self.agents_configuration / "catalog.json"

    @property
    def agents_state(self) -> Path:
        return self.state_root / "agents"

    @property
    def inventory(self) -> Path:
        return self.agents_state / "inventory.json"

    @property
    def node_root(self) -> Path:
        return self.install_root / "node"

    @property
    def bridge_marker(self) -> Path:
        return self.node_root / ".beep-bridges.json"

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


@dataclass
class _PathSwap:
    """One same-filesystem replacement in a rollback transaction."""

    target: Path
    staged: Path
    previous: Path
    has_staged: bool = False
    target_moved: bool = False
    staged_moved: bool = False


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


def assert_directory_ancestry_safe(path: Path) -> None:
    absolute = path.absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Protected directory ancestry is unsafe: {path}",
            ) from exc
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Protected directory ancestry is unsafe: {path}",
            )


def atomic_write(
    path: Path,
    content: bytes,
    *,
    mode: int,
    uid: int = 0,
    gid: int = 0,
) -> bool:
    assert_directory_ancestry_safe(path.parent)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ManagementError(
            73,
            "UNSAFE_PATH",
            f"Protected directory is unsafe: {path.parent}",
        ) from exc
    assert_directory_ancestry_safe(path.parent)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        metadata = None
    if metadata is not None and not stat.S_ISREG(metadata.st_mode):
        raise ManagementError(73, "UNSAFE_PATH", f"Refusing unsafe path: {path}")
    previous = path.read_bytes() if metadata is not None else None
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
        self._prompted_chat_password: str | None = None
        self._prompted_provider_credential: tuple[str, str] | None = None
        self._last_rollback_degraded = False
        self._approved_plan_digest: str | None = None
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
            self.source_root / "payload" / "agent" / "bridge-package.json",
            self.source_root / "payload" / "agent" / "bridge-package-lock.json",
            self.source_root / "payload" / "etc" / "policy.yaml",
            self.source_root / "payload" / "systemd" / "beep-chat.service",
            self.source_root / "scripts" / "install.sh",
            self.source_root / "scripts" / "manage.sh",
        )
        if any(not path.is_file() for path in required):
            raise ManagementError(
                66, "SOURCE_INCOMPLETE", "The Beep source payload is incomplete."
            )
        try:
            for path in (self.source_root, *self.source_root.rglob("*")):
                metadata = path.lstat()
                if not (
                    stat.S_ISDIR(metadata.st_mode)
                    or stat.S_ISREG(metadata.st_mode)
                ):
                    raise ManagementError(
                        78,
                        "UNSAFE_SOURCE",
                        f"The Beep source contains an unsafe path: {path}",
                    )
        except ManagementError:
            raise
        except OSError as exc:
            raise ManagementError(
                78,
                "UNSAFE_SOURCE",
                "The Beep source tree is unavailable.",
            ) from exc

    def _validate_environment(self) -> None:
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
        unknown = sorted(
            key for key in os.environ if key.startswith("BEEP_") and key not in KNOWN_ENV
        )
        if unknown:
            raise ManagementError(
                65,
                "UNKNOWN_ENVIRONMENT",
                f"Unknown Beep environment variable(s): {', '.join(unknown)}",
            )
        artifact = os.environ.get("BEEP_ARTIFACT_SHA256")
        if artifact is not None and re.fullmatch(r"[0-9a-f]{64}", artifact) is None:
            raise ManagementError(
                65,
                "INVALID_ARTIFACT_DIGEST",
                "BEEP_ARTIFACT_SHA256 must be a lowercase SHA-256 digest.",
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

    @staticmethod
    def _validate_chat_port(value: Any) -> int:
        try:
            port = int(value)
        except (TypeError, ValueError) as exc:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "chat_port must be an integer."
            ) from exc
        if isinstance(value, bool) or not 1024 <= port <= 65535:
            raise ManagementError(
                65,
                "INVALID_CONFIGURATION",
                "chat_port must be between 1024 and 65535.",
            )
        return port

    @staticmethod
    def _validate_provider(value: Any) -> str | None:
        if value in ("", None, "none"):
            return None
        if not isinstance(value, str) or value not in PROVIDER_KEYS:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "provider is not supported."
            )
        return value

    @staticmethod
    def _validate_model(value: Any, *, provider: str | None) -> str | None:
        if value in ("", None):
            if provider in {"openrouter", "lmstudio"}:
                raise ManagementError(
                    64,
                    "REQUIRED_INPUT",
                    "The selected provider requires a model identifier.",
                )
            return None
        if not isinstance(value, str) or not value.strip() or len(value) > 256:
            raise ManagementError(65, "INVALID_CONFIGURATION", "model is invalid.")
        return value.strip()

    def _validate_model_base_url(
        self, value: Any, *, provider: str | None
    ) -> str | None:
        if value in ("", None):
            if provider == "lmstudio":
                raise ManagementError(
                    64,
                    "REQUIRED_INPUT",
                    "The lmstudio provider requires model_base_url.",
                )
            return None
        if not isinstance(value, str):
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "model_base_url must be a URL."
            )
        self._validate_model_url(value)
        if provider not in {"openai", "lmstudio"}:
            raise ManagementError(
                65,
                "INVALID_CONFIGURATION",
                "model_base_url is supported only for openai and lmstudio.",
            )
        return value

    @staticmethod
    def _validate_ttl_days(value: Any) -> int:
        try:
            ttl_days = int(value)
        except (TypeError, ValueError) as exc:
            raise ManagementError(
                65, "INVALID_CONFIGURATION", "ttl_days must be an integer."
            ) from exc
        if isinstance(value, bool) or not 1 <= ttl_days <= 3650:
            raise ManagementError(
                65,
                "INVALID_CONFIGURATION",
                "ttl_days must be between 1 and 3650.",
            )
        return ttl_days

    @staticmethod
    def _prompt(message: str, *, as_json: bool) -> str:
        destination = sys.stderr if as_json else sys.stdout
        print(message, end="", file=destination, flush=True)
        try:
            return input()
        except (EOFError, KeyboardInterrupt) as exc:
            raise ManagementError(
                64,
                "INTERACTIVE_INPUT_REQUIRED",
                "Interactive installation was cancelled.",
            ) from exc

    def _prepare_interactive_install(
        self,
        args: argparse.Namespace,
        inputs: dict[str, Any],
        *,
        request_supplied: bool,
        non_interactive: bool,
    ) -> None:
        if (
            args.operation != "install"
            or request_supplied
            or args.yes
            or args.dry_run
            or non_interactive
            or not sys.stdin.isatty()
            or self.paths.marker.exists()
            or self.paths.config.exists()
        ):
            return

        destination = sys.stderr if args.json else sys.stdout
        print("Beep interactive installer", file=destination)
        print(
            "Press Enter to accept each value shown in brackets.",
            file=destination,
        )

        def prompt_value(
            name: str,
            environment: str,
            label: str,
            default: str | None,
            validator: Callable[[str | None], Any],
        ) -> None:
            if name in inputs or environment in os.environ:
                return
            while True:
                suffix = f" [{default}]" if default is not None else ""
                answer = self._prompt(
                    f"{label}{suffix}: ",
                    as_json=args.json,
                ).strip()
                candidate = answer if answer else default
                try:
                    inputs[name] = validator(candidate)
                    return
                except ManagementError as exc:
                    print(f"  {exc.message}", file=sys.stderr)

        prompt_value(
            "chat_port",
            "BEEP_CHAT_PORT",
            "Loopback chat port",
            str(DEFAULT_PORT),
            self._validate_chat_port,
        )
        providers = ", ".join(PROVIDER_KEYS)
        prompt_value(
            "provider",
            "BEEP_PROVIDER",
            f"Model provider (none, {providers})",
            "none",
            self._validate_provider,
        )
        provider = self._validate_provider(
            inputs.get("provider", os.environ.get("BEEP_PROVIDER"))
        )
        if provider is not None:
            prompt_value(
                "model",
                "BEEP_MODEL",
                (
                    "Model identifier"
                    if provider in {"openrouter", "lmstudio"}
                    else "Model identifier (optional)"
                ),
                None,
                lambda value: self._validate_model(value, provider=provider),
            )
        if provider in {"openai", "lmstudio"}:
            prompt_value(
                "model_base_url",
                "BEEP_MODEL_BASE_URL",
                (
                    "Model API base URL"
                    if provider == "lmstudio"
                    else "Model API base URL (optional)"
                ),
                DEFAULT_LM_STUDIO_URL if provider == "lmstudio" else None,
                lambda value: self._validate_model_base_url(
                    value, provider=provider
                ),
            )
        prompt_value(
            "ttl_days",
            "BEEP_TTL_DAYS",
            "Initial time to live in days",
            str(DEFAULT_TTL_DAYS),
            self._validate_ttl_days,
        )
        print(
            "The chat password and any provider credential will be requested "
            "securely after plan approval.",
            file=destination,
        )

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
        chat_port = self._validate_chat_port(raw_port)
        provider = self._validate_provider(
            self._input(invocation, "provider", "BEEP_PROVIDER", existing, None)
        )
        model = self._validate_model(
            self._input(invocation, "model", "BEEP_MODEL", existing, None),
            provider=provider,
        )
        base_url = self._validate_model_base_url(
            self._input(
                invocation,
                "model_base_url",
                "BEEP_MODEL_BASE_URL",
                existing,
                None,
            ),
            provider=provider,
        )
        raw_ttl = self._input(
            invocation, "ttl_days", "BEEP_TTL_DAYS", existing, DEFAULT_TTL_DAYS
        )
        ttl_days = self._validate_ttl_days(raw_ttl)
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
            or parsed.query
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
        self._prepare_interactive_install(
            args,
            inputs,
            request_supplied=request is not None,
            non_interactive=non_interactive,
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
        if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise ManagementError(
                73,
                "UNSAFE_REQUEST",
                "Request must be root-owned with mode 0600.",
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
            or value["requested_by"] != "operator"
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
        if marker is not None:
            return str(marker["instance_id"])
        purge = self._load_purge_state()
        return str(purge["instance_id"]) if purge is not None else None

    def _enforce_purge_boundary(self, invocation: Invocation) -> None:
        if (
            invocation.operation in MUTATING
            and self._load_purge_state() is not None
            and not (
                invocation.operation == "uninstall"
                and invocation.retain_state is False
            )
        ):
            raise ManagementError(
                73,
                "PURGE_IN_PROGRESS",
                "An interrupted Beep purge must finish before another mutation.",
                recovery=[
                    "Rerun uninstall --purge from verified Beep source with the exact destructive confirmation."
                ],
            )

    def load_marker(self, *, required: bool) -> dict[str, Any] | None:
        try:
            metadata = self.paths.marker.lstat()
        except FileNotFoundError:
            if required:
                raise ManagementError(
                    66, "NOT_INSTALLED", "Beep is not installed on this host."
                )
            return None
        except OSError as exc:
            raise ManagementError(66, "MARKER_MISSING", "Marker is unavailable.") from exc
        self._assert_no_symlink_ancestors(self.paths.marker)
        self._validate_state_control_root(allow_legacy=True)
        expected_uid = (
            0 if self.paths.marker == Paths().marker else os.geteuid()
        )
        expected_gid = (
            0 if self.paths.marker == Paths().marker else os.getegid()
        )
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
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
            or re.fullmatch(r"source:[0-9a-f]{64}", str(value.get("source_revision", "")))
            is None
            or not isinstance(value.get("installed_at"), str)
            or not value["installed_at"]
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
            "kill": "Write the permanent death tombstone and stop all Beep services.",
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
        *,
        source_revision: str | None = None,
    ) -> str:
        fingerprints: dict[str, Any] = {}
        for key, value in sorted(invocation.inputs.items()):
            if key.endswith("_file"):
                fingerprints[key] = self._secret_file_digest(Path(str(value)))
            else:
                fingerprints[key] = value
        if invocation.operation in CONFIGURATION_OPERATIONS:
            for key, environment in (
                ("chat_password_file", "BEEP_ADMIN_PASSWORD_FILE"),
                ("provider_credential_file", "BEEP_PROVIDER_CREDENTIAL_FILE"),
            ):
                if key in fingerprints:
                    continue
                value = os.environ.get(environment)
                if value:
                    fingerprints[key] = self._secret_file_digest(Path(value))
        value = {
            "product_id": PRODUCT_ID,
            "version": self.version,
            "source_revision": source_revision or self._source_revision(),
            "artifact_sha256": os.environ.get("BEEP_ARTIFACT_SHA256"),
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
        assert_directory_ancestry_safe(path.parent)
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
        fingerprint = {
            "device": metadata.st_dev,
            "inode": metadata.st_ino,
            "size": metadata.st_size,
            "modified_ns": metadata.st_mtime_ns,
            "changed_ns": metadata.st_ctime_ns,
        }
        return sha256_bytes(canonical_json(fingerprint))

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
                and not self._password_configured()
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
                and (invocation.non_interactive or not sys.stdin.isatty())
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
        try:
            environment = self._read_secret_environment()
        except ManagementError:
            return False
        return bool(environment.get(PROVIDER_KEYS[provider], "").strip())

    def _password_configured(self) -> bool:
        try:
            environment = self._read_secret_environment()
        except ManagementError:
            return False
        return runtime_auth.valid_password_hash(
            environment.get("BEEP_ADMIN_PASSWORD_HASH")
        )

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
        lifecycle_status = self._lifecycle_status()
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
                installed and self._runtime_valid(lifecycle_status),
                "Beep runtime, dependencies, and lifecycle state are valid.",
                "Run beep-manage repair.",
            ),
            self.check(
                "policy",
                installed and self._policy_valid(),
                "Beep policy is valid and independently protected.",
                "Restore or repair /etc/beep/policy.yaml.",
            ),
            self.check(
                "credentials",
                installed and self._credentials_valid(),
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
            self.check(
                "family_manager",
                installed and self._family_manager_valid(),
                "Beep's independent family manager assets are present.",
                "Run beep-manage repair from a complete verified Beep release.",
            ),
        ]
        if shutil.which("systemctl"):
            suspended = self.paths.suspended.exists() or lifecycle_status["dead"]
            chat_active = self._service_active("beep-chat.service")
            health_active = self._service_active("beep-health.timer")
            checks.append(
                self.check(
                    "service_state",
                    (
                        suspended
                        and not chat_active
                        and not health_active
                    )
                    or (
                        not suspended
                        and chat_active
                        and health_active
                    ),
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

    def _runtime_valid(self, lifecycle_status: dict[str, Any]) -> bool:
        lifecycle_path = self.paths.runtime / "lifecycle.json"
        try:
            account = pwd.getpwnam(DEFAULT_USER)
            metadata = lifecycle_path.lstat()
            version_path = self.paths.install_root / "VERSION"
            version_valid = (
                version_path.is_file()
                and not version_path.is_symlink()
                and version_path.read_text(encoding="utf-8").strip() == self.version
            )
        except (KeyError, OSError, UnicodeError):
            return False
        return (
            lifecycle_status["configured"]
            and stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == account.pw_uid
            and metadata.st_gid == account.pw_gid
            and stat.S_IMODE(metadata.st_mode) == 0o600
            and self._tree_matches(
                self.source_root / "payload" / "agent",
                self.paths.install_root / "agent",
            )
            and self._tree_matches(
                self.source_root / "payload" / "bin",
                self.paths.install_root / "bin",
                executable=True,
            )
            and version_valid
            and self._node_runtime_supported()
            and self._bridge_runtime_valid()
        )

    @staticmethod
    def _tree_matches(
        source: Path,
        destination: Path,
        *,
        executable: bool = False,
    ) -> bool:
        if (
            not source.is_dir()
            or source.is_symlink()
            or not destination.is_dir()
            or destination.is_symlink()
        ):
            return False
        try:
            root_metadata = destination.stat(follow_symlinks=False)
            if (
                root_metadata.st_uid != 0
                or root_metadata.st_gid != 0
                or stat.S_IMODE(root_metadata.st_mode) != 0o755
            ):
                return False
            expected: set[Path] = set()
            for item in source.rglob("*"):
                if "__pycache__" in item.parts or item.suffix == ".pyc":
                    continue
                relative = item.relative_to(source)
                expected.add(relative)
                target = destination / relative
                if item.is_symlink() or target.is_symlink():
                    return False
                metadata = target.stat(follow_symlinks=False)
                if metadata.st_uid != 0 or metadata.st_gid != 0:
                    return False
                if item.is_dir():
                    if (
                        not target.is_dir()
                        or stat.S_IMODE(metadata.st_mode) != 0o755
                    ):
                        return False
                elif item.is_file():
                    mode = (
                        0o755
                        if executable or os.access(item, os.X_OK)
                        else 0o644
                    )
                    if (
                        not target.is_file()
                        or stat.S_IMODE(metadata.st_mode) != mode
                        or target.read_bytes() != item.read_bytes()
                    ):
                        return False
                else:
                    return False
            actual = {
                item.relative_to(destination)
                for item in destination.rglob("*")
                if "__pycache__" not in item.parts and item.suffix != ".pyc"
            }
            return actual == expected
        except (OSError, UnicodeError):
            return False

    def _policy_valid(self) -> bool:
        try:
            metadata = self.paths.policy.lstat()
        except OSError:
            return False
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == 0
            and metadata.st_gid == 0
            and stat.S_IMODE(metadata.st_mode) == 0o644
            and runtime_policy.validate_policy(self.paths.policy)
        )

    def _credentials_valid(self) -> bool:
        try:
            account = pwd.getpwnam(DEFAULT_USER)
            for path in (self.paths.secrets, self.paths.session_key):
                metadata = path.lstat()
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                    or metadata.st_uid != account.pw_uid
                    or metadata.st_gid != account.pw_gid
                ):
                    return False
            environment = self._read_secret_environment()
            return (
                runtime_auth.valid_password_hash(
                    environment.get("BEEP_ADMIN_PASSWORD_HASH")
                )
                and 32
                <= len(self.paths.session_key.read_bytes().strip())
                <= 4096
            )
        except (KeyError, OSError, ManagementError):
            return False

    def _family_manager_valid(self) -> bool:
        if not (
            (self.paths.install_root / "bin" / "beep-agents").is_file()
            and self.paths.catalog.is_file()
            and not self.paths.catalog.is_symlink()
            and self.paths.inventory.is_file()
            and not self.paths.inventory.is_symlink()
        ):
            return False
        try:
            runtime_family.validate_catalog(
                runtime_family.load_json(self.paths.catalog, label="catalog")
            )
            runtime_family.validate_inventory(
                runtime_family.load_json(self.paths.inventory, label="inventory")
            )
        except runtime_family.FamilyError:
            return False
        return True

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
        self._enforce_purge_boundary(invocation)
        if invocation.operation == "describe":
            result.details = {"descriptor": self.descriptor}
            self._best_effort_audit(invocation, result)
            return result, 0
        if invocation.operation == "status":
            marker = self.load_marker(required=False)
            lifecycle_status = self._lifecycle_status()
            result.status = (
                "ok"
                if marker is not None and lifecycle_status["configured"]
                else "degraded"
            )
            result.details = {
                "lifecycle": (
                    "dead"
                    if marker is not None and lifecycle_status["dead"]
                    else "installed" if marker is not None else "missing"
                ),
                "version": marker["version"] if marker else None,
                "suspended": self.paths.suspended.exists(),
                "dead": lifecycle_status["dead"],
                "dead_reason": lifecycle_status["dead_reason"],
                "remaining_seconds": lifecycle_status["remaining_seconds"],
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
        if configuration is not None:
            result.details = {"configuration": configuration.object()}
        if invocation.dry_run:
            result.status = "blocked" if result.required_inputs else "ok"
            return result, 64 if result.required_inputs else 0
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
        self._confirm(invocation, result, configuration)
        if os.geteuid() != 0:
            raise ManagementError(
                73, "ROOT_REQUIRED", f"{invocation.operation} requires root."
            )
        event_id = str(uuid.uuid4())
        previous_version: str | None = None
        changed_resources: list[str] = []
        details: dict[str, Any] = (
            {"configuration": configuration.object()}
            if configuration is not None
            else {}
        )
        with self._lock():
            self._validate_source()
            locked_source_revision = self._source_revision()
            locked_configuration = (
                self.configuration(invocation)
                if invocation.operation in CONFIGURATION_OPERATIONS
                else None
            )
            locked_steps = self.steps(invocation, locked_configuration)
            recomputed = self.plan_digest(
                invocation,
                locked_steps,
                locked_configuration,
                source_revision=locked_source_revision,
            )
            if recomputed != result.plan_digest:
                raise ManagementError(
                    78, "PLAN_CHANGED", "Host state changed while acquiring the lock."
                )
            self._approved_plan_digest = result.plan_digest
            configuration = locked_configuration
            if invocation.operation in {"install", "repair", "update"}:
                with self._trusted_source_snapshot(locked_source_revision):
                    changed_resources, previous_version = self._execute_converge(
                        invocation,
                        configuration
                        if configuration is not None
                        else self.configuration(invocation),
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
            elif invocation.operation == "kill":
                changed_resources, previous_version = self._execute_kill()
            elif invocation.operation == "uninstall":
                changed_resources, previous_version = self._execute_uninstall(invocation)
            else:  # pragma: no cover - argparse and constants prevent this
                raise ManagementError(65, "UNKNOWN_OPERATION", "Unknown operation.")
            result.changed = bool(changed_resources)
            result.instance_id = self.instance_id() or result.instance_id
            result.details = details
            complete_purge = (
                invocation.operation == "uninstall"
                and invocation.retain_state is False
            )
            if complete_purge:
                result.status = "in_progress"
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
            if complete_purge:
                self._journal_purge_evidence(
                    invocation,
                    result,
                    event_id=event_id,
                    receipt_digest=receipt["digest"],
                    phase="purge_started",
                    changed_resources=changed_resources,
                )
                finalized = self._finalize_purge()
                changed_resources = sorted(set(changed_resources + finalized))
                completion_event_id = str(uuid.uuid4())
                result.status = "ok"
                result.changed = bool(changed_resources)
                self._journal_purge_evidence(
                    invocation,
                    result,
                    event_id=completion_event_id,
                    receipt_digest=receipt["digest"],
                    phase="purge_completed",
                    changed_resources=changed_resources,
                )
                self._remove_purge_state()
                result.receipt = None
                result.details = {
                    "purge_evidence": {
                        "journal_identifier": "beep-manage",
                        "audit_event_id": event_id,
                        "completion_event_id": completion_event_id,
                        "receipt_digest": receipt["digest"],
                        "removed_receipt_path": receipt["path"],
                    }
                }
        return result, 0

    def _confirm(
        self,
        invocation: Invocation,
        result: Result,
        configuration: Configuration | None,
    ) -> None:
        if invocation.assume_yes:
            return
        if invocation.non_interactive or not sys.stdin.isatty():
            raise ManagementError(
                64,
                "CONFIRMATION_REQUIRED",
                "A mutating unattended operation requires --yes.",
            )
        print_plan(
            result,
            configuration=configuration.object() if configuration is not None else None,
            file=sys.stderr if invocation.json_output else sys.stdout,
        )
        answer = self._prompt(
            "Apply this plan? [y/N]: ",
            as_json=invocation.json_output,
        ).strip().lower()
        if answer not in {"y", "yes"}:
            raise ManagementError(64, "CONFIRMATION_REQUIRED", "Operation cancelled.")

    @contextmanager
    def _lock(self) -> Iterator[None]:
        try:
            assert_directory_ancestry_safe(self.paths.lock.parent)
            self.paths.lock.parent.mkdir(parents=True, exist_ok=True)
            assert_directory_ancestry_safe(self.paths.lock.parent)
            descriptor = os.open(
                self.paths.lock,
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_LOCK",
                "The Beep lifecycle lock is unsafe.",
            ) from exc
        try:
            metadata = os.fstat(descriptor)
            expected_uid = (
                0 if self.paths.lock == Paths().lock else os.geteuid()
            )
            expected_gid = (
                0 if self.paths.lock == Paths().lock else os.getegid()
            )
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_LOCK",
                    "The Beep lifecycle lock is unsafe.",
                )
            try:
                os.fchmod(descriptor, 0o600)
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_LOCK",
                    "The Beep lifecycle lock is unsafe.",
                ) from exc
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

    @contextmanager
    def _lifecycle_environment(self) -> Iterator[None]:
        name = "BEEP_LIFECYCLE_STATE"
        previous = os.environ.get(name)
        os.environ[name] = str(self.paths.runtime / "lifecycle.json")
        try:
            yield
        finally:
            if previous is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = previous

    def _lifecycle_status(self) -> dict[str, Any]:
        with self._lifecycle_environment():
            return runtime_lifecycle.status()

    def _execute_converge(
        self,
        invocation: Invocation,
        configuration: Configuration,
    ) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=False)
        pending = self._load_pending_install() if marker is None else None
        retained_instance = self._retained_instance() if marker is None else None
        if (
            pending is not None
            and retained_instance is not None
            and pending["instance_id"] != retained_instance
        ):
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "Pending and retained Beep instance identities differ.",
            )
        previous_version = str(marker["version"]) if marker else None
        instance_id = (
            str(marker["instance_id"])
            if marker
            else str(pending["instance_id"])
            if pending
            else retained_instance
        )
        instance_id = instance_id or str(uuid.uuid4())
        self._prepare_interactive_secrets(invocation, configuration)
        self._platform_preflight()
        legacy_partial = self._collision_preflight(
            marker,
            pending=pending,
            configuration=configuration,
        )
        suspended = self._path_present(self.paths.suspended)
        prior_service_state = (
            self._capture_service_state() if marker is not None else None
        )
        snapshot_created = False
        normalized: list[str] = []
        markerless_services_owned = (
            marker is None
            and (
                self._pending_service_assets_owned(pending)
                if pending is not None
                else self._service_assets_owned(
                    configuration,
                    allow_legacy=legacy_partial,
                )
            )
        )
        try:
            if marker is not None:
                self._stop_services()
            elif markerless_services_owned:
                self._stop_markerless_services()
            if marker is not None:
                self._secure_state_control_root(normalized)
            self._port_preflight(configuration.chat_port)
            if marker is None and pending is None:
                self._write_pending_install(
                    instance_id,
                    configuration,
                    adopted_legacy=legacy_partial or retained_instance is not None,
                )
                pending = self._load_pending_install()
            elif marker is None and pending is not None:
                self._write_pending_install(
                    instance_id,
                    configuration,
                    adopted_legacy=True,
                )
                pending = self._load_pending_install()
            self._materialize_python_environment_links(normalized)
            if self._path_present(self.paths.node_root):
                self._materialize_node_links(normalized)
            if marker is not None:
                self._create_recovery_snapshot(
                    invocation.correlation_id,
                    prior_service_state
                    if prior_service_state is not None
                    else self._capture_service_state(),
                )
                snapshot_created = True
            return self._converge_resources(
                invocation,
                configuration,
                marker=marker,
                instance_id=instance_id,
                previous_version=previous_version,
                suspended=suspended,
                initial_changed=normalized,
            )
        except Exception as original:
            if marker is None:
                partial_services_owned = (
                    self._pending_service_assets_owned(pending)
                    if pending is not None
                    else self._service_assets_owned(
                        configuration,
                        allow_legacy=legacy_partial,
                    )
                )
                if partial_services_owned:
                    try:
                        self._stop_markerless_services()
                    except ManagementError as stop_error:
                        raise ManagementError(
                            1,
                            "PARTIAL_INSTALL_STOP_FAILED",
                            "Beep installation failed and partial services could not be stopped.",
                            recovery=[
                                "Stop the Beep units, then rerun install."
                            ],
                        ) from stop_error
                if isinstance(original, ManagementError):
                    original.recovery.append(
                        "The partial installation was recorded safely; rerun install after correcting the reported cause."
                    )
                raise
            if snapshot_created:
                try:
                    self._execute_rollback(allow_degraded=True)
                except Exception as rollback_error:
                    try:
                        self._stop_services()
                    except Exception:
                        pass
                    raise ManagementError(
                        1,
                        "AUTOMATIC_ROLLBACK_FAILED",
                        "Beep convergence failed and automatic rollback also failed.",
                        recovery=[
                            "Keep Beep stopped and restore the verified backup or recovery snapshot."
                        ],
                    ) from rollback_error
                if isinstance(original, ManagementError):
                    if self._last_rollback_degraded:
                        original.recovery.append(
                            "The pre-operation snapshot was restored; Beep remains stopped because the restored state is degraded."
                        )
                    else:
                        original.recovery.append(
                            "The pre-operation Beep recovery snapshot was restored automatically."
                        )
            else:
                try:
                    self._restore_service_state(
                        prior_service_state
                        if prior_service_state is not None
                        else self._capture_service_state()
                    )
                except Exception as restart_error:
                    raise ManagementError(
                        1,
                        "SERVICE_RESTORE_FAILED",
                        "Beep preflight failed and its prior service state could not be restored.",
                        recovery=[
                            "Keep Beep stopped and inspect the system journal before retrying."
                        ],
                    ) from restart_error
                if isinstance(original, ManagementError):
                    original.recovery.append(
                        "The prior Beep service state was restored automatically."
                    )
            raise

    def _converge_resources(
        self,
        invocation: Invocation,
        configuration: Configuration,
        *,
        marker: dict[str, Any] | None,
        instance_id: str,
        previous_version: str | None,
        suspended: bool,
        initial_changed: list[str] | None = None,
    ) -> tuple[list[str], str | None]:
        changed = list(initial_changed or [])
        uid, gid = self._ensure_identity(configuration.agent_user, changed)
        self._ensure_directories(uid, gid, changed)
        self._ensure_dependencies(configuration.agent_user, changed)
        self._deploy_runtime(configuration, uid, gid, changed)
        self._assert_approved_plan_current(invocation, configuration)
        self._deploy_configuration(invocation, configuration, uid, gid, changed)
        self._deploy_services(configuration, uid, gid, changed)
        lifecycle_status = self._lifecycle_status()
        self._start_services(
            changed,
            suspended=suspended or lifecycle_status["dead"],
        )
        checks = self.checks_without_marker(configuration)
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
        self.paths.pending_install.unlink(missing_ok=True)
        self.paths.retained.unlink(missing_ok=True)
        return sorted(set(changed)), previous_version

    def _assert_approved_plan_current(
        self,
        invocation: Invocation,
        configuration: Configuration,
    ) -> None:
        if self._approved_plan_digest is None:
            return
        current = self.plan_digest(
            invocation,
            self.steps(invocation, configuration),
            configuration,
            source_revision=self._source_revision(),
        )
        if current != self._approved_plan_digest:
            raise ManagementError(
                78,
                "PLAN_CHANGED",
                "Protected inputs changed while applying the approved plan.",
            )

    def checks_without_marker(
        self,
        configuration: Configuration | None = None,
    ) -> list[dict[str, str]]:
        checks = self.checks()
        host_assets_valid = all(
            path.is_file() and not path.is_symlink()
            for path in self._host_resources()
        )
        if configuration is not None:
            specifications = self._host_resource_specs(configuration)
            host_assets_valid = all(
                self._host_file_matches(
                    path,
                    mode=mode,
                    digests={hashlib.sha256(content).hexdigest()},
                )
                for path, (content, mode) in specifications.items()
            )
        installation_predicates = {
            "runtime": (self.paths.install_root / "agent" / "server.py").is_file()
            and self._runtime_valid(self._lifecycle_status()),
            "policy": self._policy_valid(),
            "credentials": self._credentials_valid(),
            "service_assets": host_assets_valid,
            "family_manager": self._family_manager_valid(),
        }
        for check in checks:
            if check["id"] == "marker":
                check["status"] = "pass"
                check["summary"] = "Marker will be written after health checks."
                check["remediation"] = ""
            elif (
                check["id"] == "descriptor"
                and self.paths.descriptor.is_file()
                and not self.paths.descriptor.is_symlink()
                and self.paths.descriptor.read_bytes()
                == (self.source_root / "PRODUCT.json").read_bytes()
            ):
                check["status"] = "pass"
                check["summary"] = "Installed descriptor matches this release."
                check["remediation"] = ""
            elif check["id"] in {
                "runtime",
                "policy",
                "credentials",
                "service_assets",
                "family_manager",
            }:
                if installation_predicates[check["id"]]:
                    check["status"] = "pass"
                    check["remediation"] = ""
        return checks

    def _platform_preflight(self) -> None:
        if os.environ.get("BEEP_DISPOSABLE_VM_TEST") == "1":
            sentinel = Path("/run/beep-disposable-vm")
            try:
                metadata = sentinel.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_VM_GUARD",
                    "The disposable-VM guard file is missing or unsafe.",
                ) from exc
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != 0
                or metadata.st_gid != 0
                or stat.S_IMODE(metadata.st_mode) & 0o022
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_VM_GUARD",
                    "The disposable-VM guard file is missing or unsafe.",
                )
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

    def _collision_preflight(
        self,
        marker: dict[str, Any] | None,
        *,
        pending: dict[str, Any] | None = None,
        configuration: Configuration | None = None,
    ) -> bool:
        if marker is not None:
            return False
        if self._load_purge_state() is not None:
            raise ManagementError(
                73,
                "PURGE_IN_PROGRESS",
                "An interrupted Beep purge must be resumed before installation.",
                recovery=[
                    "Rerun uninstall --purge from verified Beep source with the exact destructive confirmation."
                ],
            )
        if pending is None:
            pending = self._load_pending_install()
        retained = self._load_retained()
        resources = (
            self.paths.install_root,
            self.paths.account_home,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
            *self._host_resources(),
            self.paths.pending_install,
        )
        legacy_partial = (
            pending is None
            and retained is None
            and configuration is not None
            and self._legacy_partial_install(resources, configuration)
        )
        if pending is not None:
            self._validate_pending_install_resources(pending)
        if retained is not None:
            self._validate_retained_resources()
        if pending is not None or legacy_partial:
            allowed = set(resources)
        elif retained is not None:
            allowed = {
                self.paths.account_home,
                self.paths.state_root,
                self.paths.configuration_root,
                self.paths.log_root,
            }
        else:
            allowed = set()
        collisions = [
            str(path)
            for path in resources
            if self._path_present(path) and path not in allowed
        ]
        try:
            pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            pass
        else:
            if retained is None and pending is None and not legacy_partial:
                collisions.append("user:beep")
        try:
            grp.getgrnam(DEFAULT_USER)
        except KeyError:
            pass
        else:
            if retained is None and pending is None and not legacy_partial:
                collisions.append("group:beep")
        if collisions:
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "Unowned Beep resource collision: " + ", ".join(sorted(collisions)),
            )
        return legacy_partial

    def _legacy_partial_install(
        self,
        resources: tuple[Path, ...],
        configuration: Configuration,
    ) -> bool:
        """Recognize the exact markerless state left by older Beep installers."""
        try:
            user = pwd.getpwnam(DEFAULT_USER)
            group = grp.getgrnam(DEFAULT_USER)
            metadata = self.paths.sudoers.lstat()
        except (KeyError, OSError):
            return False
        root_uid, root_gid = self._expected_node_owner()
        if (
            user.pw_gid != group.gr_gid
            or user.pw_dir != str(self.paths.account_home)
            or user.pw_shell != "/bin/bash"
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != root_uid
            or metadata.st_gid != root_gid
            or stat.S_IMODE(metadata.st_mode) != 0o440
        ):
            return False
        try:
            if self.paths.sudoers.read_bytes() != self._sudoers_content(DEFAULT_USER):
                return False
        except OSError:
            return False
        specifications = self._host_resource_specs(configuration)
        for path in set(self._host_resources()) - {self.paths.sudoers}:
            if not self._path_present(path):
                continue
            accepted = {hashlib.sha256(specifications[path][0]).hexdigest()}
            if path == self.paths.entrypoint:
                accepted.add(LEGACY_MANAGER_SHA256)
            if not self._host_file_matches(
                path,
                mode=specifications[path][1],
                digests=accepted,
            ):
                return False
        roots = (
            self.paths.install_root,
            self.paths.account_home,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        )
        present_roots = 0
        for path in roots:
            try:
                metadata = path.lstat()
            except FileNotFoundError:
                continue
            except OSError:
                return False
            if not stat.S_ISDIR(metadata.st_mode):
                return False
            try:
                self._validate_partial_root(
                    path,
                    user=user,
                    group=group,
                    allow_legacy_control_owner=True,
                )
            except ManagementError:
                return False
            present_roots += 1
        return present_roots > 0

    def _validate_pending_install_resources(self, pending: dict[str, Any]) -> None:
        """Adopt only resources whose provenance is recorded by the root journal."""
        try:
            user = pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            user = None
        try:
            group = grp.getgrnam(DEFAULT_USER)
        except KeyError:
            group = None
        if user is not None and group is None:
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "The pending Beep identity is incomplete.",
            )
        if user is not None and group is not None and (
            user.pw_gid != group.gr_gid
            or user.pw_dir != str(self.paths.account_home)
            or user.pw_shell != "/bin/bash"
        ):
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "The pending Beep identity does not match the managed account.",
            )
        for path in (
            self.paths.install_root,
            self.paths.account_home,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        ):
            if not self._path_present(path):
                continue
            if user is None or group is None:
                raise ManagementError(
                    73,
                    "OWNERSHIP_COLLISION",
                    f"Pending Beep root has no matching identity: {path}",
                )
            self._validate_partial_root(
                path,
                user=user,
                group=group,
                allow_legacy_control_owner=bool(pending["adopted_legacy"]),
            )
        recorded = pending["host_resources"]
        for path in self._host_resources():
            if not self._path_present(path):
                continue
            specification = recorded[str(path)]
            if not self._host_file_matches(
                path,
                mode=specification["mode"],
                digests=set(specification["sha256"]),
            ):
                raise ManagementError(
                    73,
                    "OWNERSHIP_COLLISION",
                    f"Pending Beep host resource is not provenance-matched: {path}",
                )

    def _validate_partial_root(
        self,
        root: Path,
        *,
        user: Any,
        group: Any,
        allow_legacy_control_owner: bool,
    ) -> None:
        root_uid, root_gid = self._expected_node_owner()
        expected_roots: dict[Path, set[tuple[int, int, int]]] = {
            self.paths.install_root: {(root_uid, root_gid, 0o755)},
            self.paths.configuration_root: {(root_uid, root_gid, 0o755)},
            self.paths.state_root: {(root_uid, root_gid, 0o755)},
            self.paths.log_root: {(root_uid, root_gid, 0o755)},
            self.paths.account_home: {(user.pw_uid, group.gr_gid, 0o750)},
        }
        if allow_legacy_control_owner and root in {
            self.paths.state_root,
            self.paths.log_root,
        }:
            expected_roots[root].add((user.pw_uid, group.gr_gid, 0o750))
        try:
            metadata = root.lstat()
        except OSError as exc:
            raise ManagementError(
                73, "OWNERSHIP_COLLISION", f"Pending Beep root is unsafe: {root}"
            ) from exc
        identity = (
            metadata.st_uid,
            metadata.st_gid,
            stat.S_IMODE(metadata.st_mode),
        )
        if not stat.S_ISDIR(metadata.st_mode) or identity not in expected_roots[root]:
            raise ManagementError(
                73, "OWNERSHIP_COLLISION", f"Pending Beep root is unsafe: {root}"
            )
        if root == self.paths.install_root and self._path_present(self.paths.node_root):
            self._node_link_replacements()
        allowed_uids = {root_uid, user.pw_uid}
        allowed_gids = {root_gid, group.gr_gid}
        for path in root.rglob("*"):
            if (
                root == self.paths.install_root
                and (
                    path == self.paths.node_root
                    or self.paths.node_root in path.parents
                )
            ):
                continue
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "OWNERSHIP_COLLISION",
                    f"Pending Beep path is unsafe: {path}",
                ) from exc
            if (
                stat.S_ISLNK(metadata.st_mode)
                and root == self.paths.account_home
                and self._standard_python_lib64_link(path)
                and metadata.st_uid in allowed_uids
                and metadata.st_gid in allowed_gids
            ):
                continue
            if (
                not (
                    stat.S_ISDIR(metadata.st_mode)
                    or stat.S_ISREG(metadata.st_mode)
                )
                or metadata.st_uid not in allowed_uids
                or metadata.st_gid not in allowed_gids
                or stat.S_IMODE(metadata.st_mode) & 0o022
            ):
                raise ManagementError(
                    73,
                    "OWNERSHIP_COLLISION",
                    f"Pending Beep path is unsafe: {path}",
                )

    def _standard_python_lib64_link(self, path: Path) -> bool:
        expected = self.paths.account_home / "agent-env" / "lib64"
        if path != expected:
            return False
        try:
            metadata = path.lstat()
            target = path.parent / "lib"
            target_metadata = target.lstat()
            return (
                stat.S_ISLNK(metadata.st_mode)
                and os.readlink(path) == "lib"
                and stat.S_ISDIR(target_metadata.st_mode)
            )
        except OSError:
            return False

    def _host_resource_specs(
        self,
        configuration: Configuration,
    ) -> dict[Path, tuple[bytes, int]]:
        payload = self.source_root / "payload"
        replacements = {
            "__AGENT_USER__": configuration.agent_user,
            "__AGENT_HOME__": str(self.paths.account_home),
            "__BEEP_DIR__": str(self.paths.install_root),
        }
        result: dict[Path, tuple[bytes, int]] = {}
        for source_name, destination, mode in (
            ("systemd/beep-chat.service", self.paths.chat_unit, 0o644),
            ("systemd/beep-health.service", self.paths.health_unit, 0o644),
            ("systemd/beep-health.timer", self.paths.health_timer, 0o644),
            ("logrotate/beep", self.paths.logrotate, 0o644),
        ):
            value = (payload / source_name).read_text(encoding="utf-8")
            for old, new in replacements.items():
                value = value.replace(old, new)
            unresolved = re.findall(r"__[A-Z][A-Z0-9_]*__", value)
            if unresolved:
                raise ManagementError(
                    78, "UNRESOLVED_TEMPLATE", "Service template is invalid."
                )
            result[destination] = (value.encode(), mode)
        result[self.paths.sudoers] = (
            self._sudoers_content(configuration.agent_user),
            0o440,
        )
        result[self.paths.entrypoint] = (
            (self.source_root / "scripts" / "manage.sh").read_bytes(),
            0o755,
        )
        for command in HOST_COMMANDS:
            result[self.paths.command_root / command] = (
                (payload / "bin" / command).read_bytes(),
                0o755,
            )
        return result

    def _host_file_matches(
        self,
        path: Path,
        *,
        mode: int,
        digests: set[str],
    ) -> bool:
        try:
            metadata = path.lstat()
            self._assert_no_symlink_ancestors(path.parent)
            content = path.read_bytes()
        except OSError:
            return False
        root_uid, root_gid = self._expected_node_owner()
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == root_uid
            and metadata.st_gid == root_gid
            and stat.S_IMODE(metadata.st_mode) == mode
            and hashlib.sha256(content).hexdigest() in digests
        )

    def _service_assets_owned(
        self,
        configuration: Configuration,
        *,
        allow_legacy: bool,
    ) -> bool:
        specifications = self._host_resource_specs(configuration)
        found = False
        for path in (
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
        ):
            if not self._path_present(path):
                continue
            found = True
            digests = {hashlib.sha256(specifications[path][0]).hexdigest()}
            if not self._host_file_matches(
                path,
                mode=specifications[path][1],
                digests=digests,
            ):
                return False
        return found

    def _pending_service_assets_owned(
        self,
        pending: dict[str, Any],
    ) -> bool:
        found = False
        recorded = pending["host_resources"]
        for path in (
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
        ):
            if not self._path_present(path):
                continue
            found = True
            specification = recorded[str(path)]
            if not self._host_file_matches(
                path,
                mode=specification["mode"],
                digests=set(specification["sha256"]),
            ):
                return False
        return found

    @staticmethod
    def _path_present(path: Path) -> bool:
        try:
            path.lstat()
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise ManagementError(
                73, "UNSAFE_PATH", f"Could not inspect protected path: {path}"
            ) from exc
        return True

    @staticmethod
    def _port_preflight(port: int) -> None:
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

    def _write_pending_install(
        self,
        instance_id: str,
        configuration: Configuration,
        *,
        adopted_legacy: bool,
    ) -> None:
        resources: dict[str, dict[str, Any]] = {}
        for path, (content, mode) in self._host_resource_specs(configuration).items():
            digests = {hashlib.sha256(content).hexdigest()}
            if adopted_legacy and self._path_present(path):
                try:
                    metadata = path.lstat()
                    if stat.S_ISREG(metadata.st_mode):
                        digests.add(hashlib.sha256(path.read_bytes()).hexdigest())
                except OSError as exc:
                    raise ManagementError(
                        73,
                        "OWNERSHIP_COLLISION",
                        f"Could not record legacy Beep resource: {path}",
                    ) from exc
            resources[str(path)] = {
                "mode": mode,
                "sha256": sorted(digests),
            }
        value = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "instance_id": instance_id,
            "started_at": utc_now(),
            "version": self.version,
            "source_revision": self._source_revision(),
            "configuration": configuration.object(),
            "adopted_legacy": adopted_legacy,
            "host_resources": resources,
        }
        atomic_write(
            self.paths.pending_install,
            canonical_json(value) + b"\n",
            mode=0o600,
        )

    def _load_pending_install(self) -> dict[str, Any] | None:
        try:
            metadata = self.paths.pending_install.lstat()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PENDING_INSTALL",
                "Pending install state is unavailable.",
            ) from exc
        self._assert_no_symlink_ancestors(self.paths.pending_install)
        expected_uid = (
            0
            if self.paths.pending_install == Paths().pending_install
            else os.geteuid()
        )
        expected_gid = (
            0
            if self.paths.pending_install == Paths().pending_install
            else os.getegid()
        )
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ManagementError(
                73, "UNSAFE_PENDING_INSTALL", "Pending install state is unsafe."
            )
        value = load_json(self.paths.pending_install)
        try:
            instance_id = str(uuid.UUID(str(value.get("instance_id"))))
        except ValueError as exc:
            raise ManagementError(
                65, "INVALID_PENDING_INSTALL", "Pending install state is invalid."
            ) from exc
        expected_fields = {
            "schema_version",
            "product_id",
            "instance_id",
            "started_at",
            "version",
            "source_revision",
            "configuration",
            "adopted_legacy",
            "host_resources",
        }
        configuration = value.get("configuration")
        expected_configuration_fields = {
            "schema_version",
            "agent_user",
            "chat_port",
            "provider",
            "model",
            "model_base_url",
            "ttl_days",
        }
        resources = value.get("host_resources")
        if (
            set(value) != expected_fields
            or value.get("schema_version") != 1
            or value.get("product_id") != PRODUCT_ID
            or value.get("instance_id") != instance_id
            or not isinstance(value.get("started_at"), str)
            or not value["started_at"]
            or not VERSION_PATTERN.fullmatch(str(value.get("version", "")))
            or re.fullmatch(
                r"source:[0-9a-f]{64}",
                str(value.get("source_revision", "")),
            )
            is None
            or not isinstance(value.get("adopted_legacy"), bool)
            or not isinstance(configuration, dict)
            or set(configuration) != expected_configuration_fields
            or configuration.get("schema_version") != 1
            or configuration.get("agent_user") != DEFAULT_USER
            or not isinstance(configuration.get("chat_port"), int)
            or isinstance(configuration.get("chat_port"), bool)
            or not 1024 <= configuration["chat_port"] <= 65535
            or configuration.get("provider") not in {None, *PROVIDER_KEYS}
            or not isinstance(configuration.get("ttl_days"), int)
            or isinstance(configuration.get("ttl_days"), bool)
            or not 1 <= configuration["ttl_days"] <= 3650
            or not isinstance(resources, dict)
            or set(resources) != {str(path) for path in self._host_resources()}
        ):
            raise ManagementError(
                65, "INVALID_PENDING_INSTALL", "Pending install state is invalid."
            )
        for specification in resources.values():
            if (
                not isinstance(specification, dict)
                or set(specification) != {"mode", "sha256"}
                or specification["mode"] not in {0o440, 0o644, 0o755}
                or not isinstance(specification["sha256"], list)
                or not specification["sha256"]
                or len(specification["sha256"]) > 2
                or specification["sha256"] != sorted(set(specification["sha256"]))
                or any(
                    not isinstance(digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                    for digest in specification["sha256"]
                )
            ):
                raise ManagementError(
                    65,
                    "INVALID_PENDING_INSTALL",
                    "Pending install resource provenance is invalid.",
                )
        return value

    def _load_purge_state(self) -> dict[str, Any] | None:
        try:
            metadata = self.paths.purge_state.lstat()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PURGE_STATE",
                "Interrupted purge state is unavailable.",
            ) from exc
        self._assert_no_symlink_ancestors(self.paths.purge_state)
        expected_uid, expected_gid = self._expected_node_owner()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ManagementError(
                73,
                "UNSAFE_PURGE_STATE",
                "Interrupted purge state is unsafe.",
            )
        value = load_json(self.paths.purge_state)
        try:
            instance_id = str(uuid.UUID(str(value.get("instance_id"))))
        except ValueError as exc:
            raise ManagementError(
                65,
                "INVALID_PURGE_STATE",
                "Interrupted purge state is invalid.",
            ) from exc
        identity = value.get("identity")
        expected_identity_fields = {"user_uid", "user_gid", "group_gid"}
        identity_values = tuple(identity.values()) if isinstance(identity, dict) else ()
        all_absent = identity_values == (None, None, None)
        all_numeric = (
            len(identity_values) == 3
            and all(
                isinstance(item, int) and not isinstance(item, bool) and item >= 0
                for item in identity_values
            )
        )
        if (
            set(value)
            != {
                "schema_version",
                "product_id",
                "instance_id",
                "started_at",
                "version",
                "identity",
            }
            or value.get("schema_version") != 1
            or value.get("product_id") != PRODUCT_ID
            or value.get("instance_id") != instance_id
            or not isinstance(value.get("started_at"), str)
            or not value["started_at"]
            or not VERSION_PATTERN.fullmatch(str(value.get("version", "")))
            or not isinstance(identity, dict)
            or set(identity) != expected_identity_fields
            or not (all_absent or all_numeric)
            or (
                all_numeric
                and identity["user_gid"] != identity["group_gid"]
            )
        ):
            raise ManagementError(
                65,
                "INVALID_PURGE_STATE",
                "Interrupted purge state is invalid.",
            )
        return value

    def _write_purge_state(
        self,
        marker: dict[str, Any],
        identity: dict[str, int | None],
    ) -> bool:
        values = tuple(identity.values()) if isinstance(identity, dict) else ()
        all_absent = values == (None, None, None)
        all_numeric = (
            len(values) == 3
            and all(
                isinstance(item, int) and not isinstance(item, bool) and item >= 0
                for item in values
            )
        )
        if (
            set(identity) != {"user_uid", "user_gid", "group_gid"}
            or not (all_absent or all_numeric)
            or (all_numeric and identity["user_gid"] != identity["group_gid"])
        ):
            raise ManagementError(
                65,
                "INVALID_PURGE_STATE",
                "Purge identity provenance is invalid.",
            )
        if self._load_purge_state() is not None:
            raise ManagementError(
                73,
                "PURGE_ALREADY_STARTED",
                "A Beep purge is already in progress.",
            )
        self._assert_no_symlink_ancestors(self.paths.purge_state.parent)
        value = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "instance_id": marker["instance_id"],
            "started_at": utc_now(),
            "version": marker["version"],
            "identity": identity,
        }
        changed = atomic_write(
            self.paths.purge_state,
            canonical_json(value) + b"\n",
            mode=0o600,
        )
        self._load_purge_state()
        return changed

    def _remove_purge_state(self) -> None:
        self._load_purge_state()
        try:
            self.paths.purge_state.unlink()
        except OSError as exc:
            raise ManagementError(
                1,
                "PURGE_STATE_REMOVE_FAILED",
                "Beep was purged, but its protected purge tombstone remains.",
                retryable=True,
                recovery=["Rerun the same purge command from verified Beep source."],
            ) from exc

    def _load_retained(self) -> dict[str, Any] | None:
        try:
            metadata = self.paths.retained.lstat()
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_RETAINED_STATE",
                "Retained Beep state is unavailable.",
            ) from exc
        self._assert_no_symlink_ancestors(self.paths.retained)
        self._validate_state_control_root(allow_legacy=True)
        expected_uid, expected_gid = self._expected_node_owner()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ManagementError(
                73,
                "UNSAFE_RETAINED_STATE",
                "Retained Beep state is unsafe.",
            )
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

    def _validate_retained_resources(self) -> None:
        try:
            user = pwd.getpwnam(DEFAULT_USER)
            group = grp.getgrnam(DEFAULT_USER)
        except KeyError as exc:
            raise ManagementError(
                73,
                "OWNERSHIP_COLLISION",
                "Retained Beep state has no matching managed identity.",
            ) from exc
        if (
            user.pw_gid != group.gr_gid
            or user.pw_dir != str(self.paths.account_home)
            or user.pw_shell != "/bin/bash"
        ):
            raise ManagementError(
                73,
                "IDENTITY_COLLISION",
                "The retained beep identity differs from the managed account.",
            )
        for path in (
            self.paths.account_home,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        ):
            if not self._path_present(path):
                continue
            self._validate_partial_root(
                path,
                user=user,
                group=group,
                allow_legacy_control_owner=True,
            )

    @staticmethod
    def _sudoers_content(agent_user: str) -> bytes:
        return (
            "# Managed by beep-manage. Beep is intentionally root-capable.\n"
            f"{agent_user} ALL=(ALL) NOPASSWD:ALL\n"
        ).encode()

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
                    "--no-create-home",
                    "--home-dir",
                    str(self.paths.account_home),
                    "--shell",
                    "/bin/bash",
                    "--gid",
                    agent_user,
                    "--comment",
                    "Beep AI Systems Administrator",
                    agent_user,
                ]
            )
            changed.append(f"user:{agent_user}")
            user = pwd.getpwnam(agent_user)
        if (
            user.pw_gid != group.gr_gid
            or user.pw_dir != str(self.paths.account_home)
            or user.pw_shell != "/bin/bash"
        ):
            raise ManagementError(
                73,
                "IDENTITY_COLLISION",
                "Existing beep identity differs from the managed account.",
            )
        try:
            home_metadata = self.paths.account_home.lstat()
        except FileNotFoundError:
            assert_directory_ancestry_safe(self.paths.account_home.parent)
            self.paths.account_home.mkdir(parents=True, mode=0o750)
            home_metadata = self.paths.account_home.lstat()
            changed.append(str(self.paths.account_home))
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Managed account home is unsafe: {self.paths.account_home}",
            ) from exc
        if not stat.S_ISDIR(home_metadata.st_mode):
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Managed account home is unsafe: {self.paths.account_home}",
            )
        if (
            stat.S_IMODE(home_metadata.st_mode) != 0o750
            or home_metadata.st_uid != user.pw_uid
            or home_metadata.st_gid != group.gr_gid
        ):
            os.chmod(self.paths.account_home, 0o750)
            os.chown(self.paths.account_home, user.pw_uid, group.gr_gid)
            changed.append(str(self.paths.account_home))
        self._run(["passwd", "--lock", agent_user])
        sudoers = self._sudoers_content(agent_user)
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
            (self.paths.agents_configuration, 0o755, 0, 0),
            (self.paths.state_root, 0o755, 0, 0),
            (self.paths.runtime, 0o700, uid, gid),
            (self.paths.runtime / "logs", 0o750, uid, gid),
            (self.paths.runtime / "pi-mono-sessions", 0o700, uid, gid),
            (self.paths.agents_state, 0o700, 0, 0),
            (self.paths.log_root, 0o755, 0, 0),
            (self.paths.receipts, 0o750, 0, 0),
            (self.paths.rollback_root, 0o700, 0, 0),
        )
        for path, mode, owner, group in declarations:
            assert_directory_ancestry_safe(path.parent)
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Refusing symlink: {path}")
            if path.exists() and not path.is_dir():
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Directory path is not a directory: {path}"
                )
            if not path.exists():
                path.mkdir(parents=True, mode=mode)
                changed.append(str(path))
            os.chmod(path, mode)
            os.chown(path, owner, group)
        self._ensure_audit_log(uid, gid, changed)

    def _ensure_audit_log(self, uid: int, gid: int, changed: list[str]) -> None:
        existed = self._path_present(self.paths.audit)
        if existed:
            metadata = self.paths.audit.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Audit log is unsafe: {self.paths.audit}"
                )
        descriptor = os.open(
            self.paths.audit,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
            0o640,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Audit log is unsafe: {self.paths.audit}"
                )
            os.fchmod(descriptor, 0o640)
            if os.geteuid() == 0:
                os.fchown(descriptor, uid, gid)
        finally:
            os.close(descriptor)
        if not existed:
            changed.append(str(self.paths.audit))

    def _ensure_dependencies(self, agent_user: str, changed: list[str]) -> None:
        if not shutil.which("apt-get") or not shutil.which("dpkg-query"):
            raise ManagementError(
                69, "DEPENDENCY_MISSING", "apt-get and dpkg-query are required."
            )
        environment = {
            name: os.environ[name]
            for name in DEPENDENCY_ENVIRONMENT_KEYS
            if name in os.environ
        }
        environment.update(
            {
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": "/root",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "DEBIAN_FRONTEND": "noninteractive",
            }
        )
        missing = [
            package
            for package in SYSTEM_PACKAGES
            if self._run(
                [
                    "dpkg-query",
                    "-W",
                    "-f=${db:Status-Status}",
                    package,
                ],
                check=False,
            ).stdout.strip()
            != "installed"
        ]
        if missing:
            self._run_dependency_command(
                [
                    "apt-get",
                    "-o",
                    "Dpkg::Options::=--force-confdef",
                    "-o",
                    "Dpkg::Options::=--force-confold",
                    "update",
                    "-qq",
                ],
                environment=environment,
            )
            self._run_dependency_command(
                [
                    "apt-get",
                    "-o",
                    "Dpkg::Options::=--force-confdef",
                    "-o",
                    "Dpkg::Options::=--force-confold",
                    "install",
                    "-y",
                    "--no-install-recommends",
                    *missing,
                ],
                environment=environment,
            )
            changed.append("system-packages")
        self._ensure_node_runtime(changed)
        for command in ("python3", "sudo"):
            if not shutil.which(command):
                raise ManagementError(
                    69, "DEPENDENCY_MISSING", f"Required command is missing: {command}"
                )
        account = pwd.getpwnam(agent_user)
        home = Path(account.pw_dir)
        try:
            home_metadata = home.lstat()
        except OSError as exc:
            raise ManagementError(
                73, "UNSAFE_PATH", f"Managed account home is unsafe: {home}"
            ) from exc
        if (
            not stat.S_ISDIR(home_metadata.st_mode)
            or home_metadata.st_uid != account.pw_uid
            or home_metadata.st_gid != account.pw_gid
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Managed account home is unsafe: {home}"
            )
        virtualenv = home / "agent-env"
        python = virtualenv / "bin" / "python"
        if virtualenv.is_symlink() or (
            virtualenv.exists() and not virtualenv.is_dir()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Managed Python environment is unsafe: {virtualenv}"
            )
        if virtualenv.exists() and self._normalize_python_environment(virtualenv):
            changed.append(str(virtualenv / "lib64"))
        python_valid = (
            python.is_file()
            and not python.is_symlink()
            and os.access(python, os.X_OK)
        )
        if not python_valid:
            if virtualenv.exists():
                self._assert_tree_safe(virtualenv)
                shutil.rmtree(virtualenv)
            venv.EnvBuilder(with_pip=False, symlinks=False).create(virtualenv)
            self._normalize_python_environment(virtualenv)
            self._chown_tree(virtualenv, account.pw_uid, account.pw_gid)
            changed.append(str(virtualenv))
        self._install_bridges(changed)

    def _normalize_python_environment(self, virtualenv: Path) -> bool:
        """Remove CPython's standard Linux ``lib64 -> lib`` convenience link."""
        lib64 = virtualenv / "lib64"
        try:
            metadata = lib64.lstat()
        except FileNotFoundError:
            changed = False
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Managed Python environment is unsafe: {virtualenv}",
            ) from exc
        else:
            if not stat.S_ISLNK(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Managed Python lib64 path is unsafe: {lib64}",
                )
            try:
                link = os.readlink(lib64)
                target = virtualenv / "lib"
                target_metadata = target.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Managed Python lib64 link is unsafe: {lib64}",
                ) from exc
            if link != "lib" or not stat.S_ISDIR(target_metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Managed Python lib64 link is unsafe: {lib64}",
                )
            lib64.unlink()
            changed = True
        self._assert_tree_safe(virtualenv)
        return changed

    def _materialize_python_environment_links(self, changed: list[str]) -> None:
        virtualenv = self.paths.account_home / "agent-env"
        if not self._path_present(virtualenv):
            return
        metadata = virtualenv.lstat()
        if not stat.S_ISDIR(metadata.st_mode):
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Managed Python environment is unsafe: {virtualenv}",
            )
        if self._normalize_python_environment(virtualenv):
            changed.append(str(virtualenv / "lib64"))

    def _ensure_node_runtime(
        self,
        changed: list[str],
        *,
        force: bool = False,
    ) -> None:
        if self._path_present(self.paths.node_root):
            self._assert_node_runtime_safe()
        if not force and self._node_runtime_supported():
            return
        if platform.machine() not in {"x86_64", "amd64"}:
            raise ManagementError(
                69,
                "UNSUPPORTED_ARCHITECTURE",
                "The pinned Beep Node runtime supports amd64 only.",
            )
        archive_bytes = self._download_dependency(
            NODE_URL,
            hostname="nodejs.org",
            maximum_bytes=MAX_NODE_ARCHIVE_BYTES,
            label="pinned Beep Node runtime",
        )
        if (
            len(archive_bytes) > MAX_NODE_ARCHIVE_BYTES
            or hashlib.sha256(archive_bytes).hexdigest() != NODE_SHA256
        ):
            raise ManagementError(
                78,
                "DEPENDENCY_INTEGRITY_FAILED",
                "The pinned Beep Node runtime digest did not match.",
            )
        with tempfile.TemporaryDirectory(
            prefix=".node-stage-", dir=self.paths.install_root
        ) as directory:
            work = Path(directory)
            archive = work / NODE_ARCHIVE
            archive.write_bytes(archive_bytes)
            staged = work / "node"
            self._extract_node_archive(archive, staged)
            atomic_write(
                staged / ".beep-node.json",
                canonical_json(
                    {
                        "schema_version": 1,
                        "version": NODE_VERSION,
                        "archive": NODE_ARCHIVE,
                        "sha256": NODE_SHA256,
                        "runtime_digest": self._node_base_digest(staged),
                    }
                )
                + b"\n",
                mode=0o644,
            )
            if not self._node_runtime_supported_at(staged, staged=True):
                raise ManagementError(
                    69,
                    "DEPENDENCY_MISSING",
                    f"The staged Node {NODE_VERSION} runtime is incomplete.",
                )
            previous = self.paths.install_root / f".node-old-{uuid.uuid4().hex}"
            if self.paths.node_root.is_symlink():
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Refusing symlink: {self.paths.node_root}"
                )
            if self.paths.node_root.exists():
                if not self.paths.node_root.is_dir():
                    raise ManagementError(
                        73, "UNSAFE_PATH", f"Refusing unsafe path: {self.paths.node_root}"
                    )
                os.replace(self.paths.node_root, previous)
            try:
                os.replace(staged, self.paths.node_root)
            except Exception:
                if previous.exists() and not self.paths.node_root.exists():
                    os.replace(previous, self.paths.node_root)
                raise
            if previous.exists():
                shutil.rmtree(previous)
        if not self._node_runtime_supported():
            raise ManagementError(
                69, "DEPENDENCY_MISSING", f"Node {NODE_VERSION} is required."
            )
        changed.append(str(self.paths.node_root))

    def _node_runtime_supported(self) -> bool:
        return self._node_runtime_supported_at(self.paths.node_root, staged=False)

    def _node_runtime_supported_at(self, root: Path, *, staged: bool) -> bool:
        if not self._path_present(root):
            return False
        try:
            if staged:
                self._assert_tree_safe(root)
            else:
                self._assert_node_runtime_safe()
        except ManagementError:
            return False
        node = root / "bin" / "node"
        npm = root / "bin" / "npm"
        marker = root / ".beep-node.json"
        if (
            not node.is_file()
            or node.is_symlink()
            or not os.access(node, os.X_OK)
            or not npm.is_file()
            or npm.is_symlink()
            or not os.access(npm, os.X_OK)
            or not marker.is_file()
            or marker.is_symlink()
        ):
            return False
        try:
            metadata = load_json(marker)
        except ManagementError:
            return False
        if (
            set(metadata)
            != {
                "schema_version",
                "version",
                "archive",
                "sha256",
                "runtime_digest",
            }
            or metadata.get("schema_version") != 1
            or metadata.get("version") != NODE_VERSION
            or metadata.get("archive") != NODE_ARCHIVE
            or metadata.get("sha256") != NODE_SHA256
        ):
            return False
        try:
            if metadata["runtime_digest"] != self._node_base_digest(root):
                return False
        except ManagementError:
            return False
        environment = self._node_subprocess_environment(root)
        try:
            node_check = self._run(
                [node, "--version"],
                check=False,
                environment=environment,
            )
            npm_check = self._run(
                [npm, "--version"],
                check=False,
                environment=environment,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        return (
            node_check.returncode == 0
            and node_check.stdout.strip() == f"v{NODE_VERSION}"
            and npm_check.returncode == 0
            and re.fullmatch(
                r"\d+(?:\.\d+){2}(?:[-+][0-9A-Za-z.-]+)?",
                npm_check.stdout.strip(),
            )
            is not None
        )

    @staticmethod
    def _node_base_digest(root: Path) -> str:
        if not root.is_dir() or root.is_symlink():
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Pinned Node runtime is unsafe: {root}",
            )
        digest = hashlib.sha256()
        for path in (root, *sorted(root.rglob("*"))):
            relative_path = path.relative_to(root) if path != root else Path(".")
            relative = PurePosixPath(*relative_path.parts)
            mutable_modules = (
                relative.parts[:2] == ("lib", "node_modules")
                and (
                    len(relative.parts) < 3
                    or relative.parts[2] not in {"npm", "corepack"}
                )
            )
            if (
                mutable_modules
                or relative
                in {
                    PurePosixPath(".beep-node.json"),
                    PurePosixPath(".beep-bridges.json"),
                    PurePosixPath("bin/pi"),
                }
            ):
                continue
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime path is unsafe: {path}",
                ) from exc
            if stat.S_ISLNK(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime path is unsafe: {path}",
                )
            digest.update(str(relative).encode())
            digest.update(b"\0")
            digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode())
            digest.update(b"\0")
            if stat.S_ISREG(metadata.st_mode):
                with path.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(block)
            elif not stat.S_ISDIR(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime path is unsafe: {path}",
                )
            digest.update(b"\0")
        return sha256_bytes(digest.digest())

    def _node_subprocess_environment(
        self,
        node_root: Path | None = None,
    ) -> dict[str, str]:
        root = node_root or self.paths.node_root
        environment = {
            name: os.environ[name]
            for name in DEPENDENCY_ENVIRONMENT_KEYS
            if name in os.environ
        }
        environment.update(
            {
                "PATH": (
                    f"{root / 'bin'}:"
                    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                ),
                "HOME": "/root",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "NPM_CONFIG_PREFIX": str(root),
                "NPM_CONFIG_USERCONFIG": "/dev/null",
                "NPM_CONFIG_GLOBALCONFIG": "/dev/null",
                "NPM_CONFIG_IGNORE_SCRIPTS": "true",
                "NPM_CONFIG_AUDIT": "false",
                "NPM_CONFIG_FUND": "false",
            }
        )
        return environment

    def _expected_node_owner(self) -> tuple[int, int]:
        if self.paths.install_root == Paths().install_root:
            return 0, 0
        return os.geteuid(), os.getegid()

    def _assert_node_ancestors_safe(self) -> None:
        self._assert_no_symlink_ancestors(self.paths.node_root)
        if self.paths.install_root != Paths().install_root:
            return
        for path in (Path("/"), self.paths.install_root.parent, self.paths.install_root):
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime ancestry is unsafe: {path}",
                ) from exc
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != 0
                or metadata.st_gid != 0
                or stat.S_IMODE(metadata.st_mode) & 0o022
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime ancestry is unsafe: {path}",
                )

    @staticmethod
    def _assert_no_symlink_ancestors(path: Path) -> None:
        absolute = path.absolute()
        current = Path(absolute.anchor)
        for part in absolute.parts[1:]:
            current /= part
            try:
                metadata = current.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Protected path ancestry is unsafe: {path}",
                ) from exc
            if stat.S_ISLNK(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Protected path ancestry contains a symlink: {current}",
                )

    def _assert_node_runtime_safe(self) -> None:
        root = self.paths.node_root
        self._assert_node_ancestors_safe()
        expected_uid, expected_gid = self._expected_node_owner()
        try:
            entries = (root, *sorted(root.rglob("*")))
            for path in entries:
                metadata = path.lstat()
                if (
                    stat.S_ISLNK(metadata.st_mode)
                    or not (
                        stat.S_ISDIR(metadata.st_mode)
                        or stat.S_ISREG(metadata.st_mode)
                    )
                    or metadata.st_uid != expected_uid
                    or metadata.st_gid != expected_gid
                    or stat.S_IMODE(metadata.st_mode) & 0o022
                ):
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Pinned Node runtime path is unsafe: {path}",
                    )
        except ManagementError:
            raise
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Pinned Node runtime is unsafe: {root}",
            ) from exc

    def _materialize_node_links(self, changed: list[str]) -> None:
        """Replace legacy safe Node links without ever following an escape."""
        replacements = self._node_link_replacements()
        for path, content, mode in replacements:
            replacement = path.with_name(
                f".{path.name}.beep-materialize-{uuid.uuid4().hex}"
            )
            try:
                atomic_write(replacement, content, mode=mode)
                current = path.lstat()
                if not stat.S_ISLNK(current.st_mode):
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Pinned Node link changed during migration: {path}",
                    )
                os.replace(replacement, path)
            finally:
                replacement.unlink(missing_ok=True)
            changed.append(str(path))
        self._assert_node_runtime_safe()

    def _node_link_replacements(self) -> list[tuple[Path, bytes, int]]:
        """Validate all Node entries and plan safe, regular link replacements."""
        root = self.paths.node_root
        self._assert_node_ancestors_safe()
        expected_uid, expected_gid = self._expected_node_owner()
        try:
            root_metadata = root.lstat()
            resolved_root = root.resolve(strict=True)
            entries = sorted(root.rglob("*"))
        except (OSError, RuntimeError) as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Pinned Node runtime is unsafe: {root}",
            ) from exc
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != expected_uid
            or root_metadata.st_gid != expected_gid
            or stat.S_IMODE(root_metadata.st_mode) & 0o022
        ):
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Pinned Node runtime is unsafe: {root}",
            )
        replacements: list[tuple[Path, bytes, int]] = []
        for path in entries:
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node runtime path is unsafe: {path}",
                ) from exc
            if not stat.S_ISLNK(metadata.st_mode):
                if (
                    not (
                        stat.S_ISDIR(metadata.st_mode)
                        or stat.S_ISREG(metadata.st_mode)
                    )
                    or metadata.st_uid != expected_uid
                    or metadata.st_gid != expected_gid
                    or stat.S_IMODE(metadata.st_mode) & 0o022
                ):
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Pinned Node runtime path is unsafe: {path}",
                    )
                continue
            try:
                link_value = Path(os.readlink(path))
                target = path.resolve(strict=True)
                target_metadata = target.stat(follow_symlinks=False)
                target.relative_to(resolved_root)
            except (OSError, RuntimeError, ValueError) as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node link is unsafe: {path}",
                ) from exc
            if (
                link_value.is_absolute()
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or not stat.S_ISREG(target_metadata.st_mode)
                or target_metadata.st_uid != expected_uid
                or target_metadata.st_gid != expected_gid
                or stat.S_IMODE(target_metadata.st_mode) & 0o022
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Pinned Node link is unsafe: {path}",
                )
            mode = stat.S_IMODE(target_metadata.st_mode)
            target_bytes = target.read_bytes()
            executable = bool(mode & 0o111)
            node_shebang = (
                executable
                and b"node" in target_bytes.split(b"\n", 1)[0].lower()
            )
            if executable:
                command = self.paths.node_root / "bin" / "node" if node_shebang else target
                arguments = (
                    f" {shlex.quote(str(target))}" if node_shebang else ""
                )
                content = (
                    "#!/bin/sh\n"
                    f"exec {shlex.quote(str(command))}{arguments} \"$@\"\n"
                ).encode()
                mode = 0o755
            else:
                content = target_bytes
                mode &= ~0o022
            replacements.append((path, content, mode))
        return replacements

    @staticmethod
    def _extract_node_archive(archive: Path, destination: Path) -> None:
        prefix = PurePosixPath(f"node-v{NODE_VERSION}-linux-x64")
        file_count = 0
        total_size = 0
        try:
            with tarfile.open(archive, "r:xz") as source:
                members = source.getmembers()
                seen: set[PurePosixPath] = set()
                safe_links: dict[PurePosixPath, tuple[str, ...]] = {}
                file_modes: dict[tuple[str, ...], int] = {}
                for member in members:
                    path = PurePosixPath(member.name)
                    if (
                        path.is_absolute()
                        or ".." in path.parts
                        or not path.parts
                        or path.parts[0] != str(prefix)
                        or path in seen
                        or member.islnk()
                        or member.isdev()
                        or member.isfifo()
                        or (
                            not member.isfile()
                            and not member.isdir()
                            and not member.issym()
                        )
                    ):
                        raise ManagementError(
                            78,
                            "DEPENDENCY_INTEGRITY_FAILED",
                            "The Node archive contains an unsafe member.",
                        )
                    seen.add(path)
                    if member.isfile():
                        file_count += 1
                        total_size += member.size
                        file_modes[tuple(path.parts[1:])] = member.mode
                    if file_count > 25_000 or total_size > 512 * 1024 * 1024:
                        raise ManagementError(
                            78,
                            "DEPENDENCY_INTEGRITY_FAILED",
                            "The Node archive exceeds extraction limits.",
                        )
                    if member.issym():
                        link = PurePosixPath(member.linkname)
                        if link.is_absolute():
                            raise ManagementError(
                                78,
                                "DEPENDENCY_INTEGRITY_FAILED",
                                "The Node archive contains an unsafe link.",
                            )
                        stack: list[str] = []
                        for part in path.parent.parts[1:] + link.parts:
                            if part in {"", "."}:
                                continue
                            if part == "..":
                                if not stack:
                                    raise ManagementError(
                                        78,
                                        "DEPENDENCY_INTEGRITY_FAILED",
                                        "The Node archive link escapes its root.",
                                    )
                                stack.pop()
                            else:
                                stack.append(part)
                        safe_links[path] = tuple(stack)
                destination.mkdir(mode=0o755)
                for member in members:
                    relative = PurePosixPath(member.name).relative_to(prefix)
                    if not relative.parts:
                        continue
                    target = destination.joinpath(*relative.parts)
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True, mode=0o755)
                        os.chmod(target, 0o755)
                    elif member.issym():
                        continue
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                        extracted = source.extractfile(member)
                        if extracted is None:
                            raise ManagementError(
                                78,
                                "DEPENDENCY_INTEGRITY_FAILED",
                                "The Node archive is incomplete.",
                            )
                        with extracted, target.open("xb") as output:
                            shutil.copyfileobj(extracted, output, length=1024 * 1024)
                        os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
                for member_path, link_parts in safe_links.items():
                    relative = member_path.relative_to(prefix)
                    target = destination.joinpath(*relative.parts)
                    link_target = destination.joinpath(*link_parts)
                    target_mode = file_modes.get(link_parts)
                    if (
                        target_mode is None
                        or not link_target.is_file()
                        or link_target.is_symlink()
                    ):
                        raise ManagementError(
                            78,
                            "DEPENDENCY_INTEGRITY_FAILED",
                            "The Node archive link target is invalid.",
                        )
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                    target_mode = stat.S_IMODE(target_mode)
                    if target_mode & 0o111:
                        relative_target = posixpath.relpath(
                            str(PurePosixPath(*link_parts)),
                            start=str(relative.parent),
                        )
                        first_line = link_target.read_bytes().split(b"\n", 1)[0]
                        command = (
                            '"${script_dir}/node" '
                            if b"node" in first_line.lower()
                            else ""
                        )
                        wrapper = (
                            "#!/bin/sh\n"
                            'script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                            f'exec {command}"${{script_dir}}/"'
                            f"{shlex.quote(relative_target)} \"$@\"\n"
                        )
                        target.write_text(wrapper, encoding="utf-8")
                        os.chmod(target, 0o755)
                    else:
                        shutil.copyfile(link_target, target)
                        os.chmod(
                            target,
                            target_mode,
                        )
        except ManagementError:
            raise
        except (OSError, tarfile.TarError) as exc:
            raise ManagementError(
                78, "DEPENDENCY_INTEGRITY_FAILED", "The Node archive is invalid."
            ) from exc

    def _install_bridges(self, changed: list[str]) -> None:
        self._assert_node_runtime_safe()
        npm = self.paths.node_root / "bin" / "npm"
        node = self.paths.node_root / "bin" / "node"
        if (
            not npm.is_file()
            or npm.is_symlink()
            or not os.access(npm, os.X_OK)
            or not node.is_file()
            or node.is_symlink()
            or not os.access(node, os.X_OK)
        ):
            raise ManagementError(69, "DEPENDENCY_MISSING", "Node and npm are required.")
        environment = self._node_subprocess_environment()
        pins = self._bridge_pins()
        self._validate_bridge_package_lock(pins)
        tree_valid = self._bridge_tree_valid(pins)
        if not tree_valid and str(self.paths.node_root) not in changed:
            self._ensure_node_runtime(changed, force=True)
            self._assert_node_runtime_safe()
            npm = self.paths.node_root / "bin" / "npm"
            node = self.paths.node_root / "bin" / "node"
            environment = self._node_subprocess_environment()
        if not tree_valid:
            self._install_bridge_archives(npm, pins, environment)
            self._normalize_node_runtime_metadata(allow_links=False)
            changed.append("pinned-node-bridges")
        self._materialize_node_links(changed)
        direct_state = {
            package: {"version": version}
            for package, version, _, _, _ in pins
        }
        if any(
            not self._bridge_package_valid(direct_state, package, version)
            for package, version, _, _, _ in pins
        ):
            raise ManagementError(
                69,
                "DEPENDENCY_MISSING",
                "Pinned Beep bridge installation did not verify.",
            )
        self._ensure_node_launchers(pins, changed)
        self._normalize_node_runtime_metadata(allow_links=False)
        bridge_state = self._bridge_marker_value(pins)
        if atomic_write(
            self.paths.bridge_marker,
            canonical_json(bridge_state) + b"\n",
            mode=0o644,
        ):
            changed.append(str(self.paths.bridge_marker))
        self._assert_node_runtime_safe()

    def _normalize_node_runtime_metadata(self, *, allow_links: bool) -> None:
        root = self.paths.node_root
        self._assert_node_ancestors_safe()
        expected_uid, expected_gid = self._expected_node_owner()
        try:
            entries = (root, *sorted(root.rglob("*")))
            for path in entries:
                metadata = path.lstat()
                if stat.S_ISLNK(metadata.st_mode):
                    if (
                        not allow_links
                        or metadata.st_uid != expected_uid
                        or metadata.st_gid != expected_gid
                    ):
                        raise ManagementError(
                            73,
                            "UNSAFE_PATH",
                            f"Pinned Node runtime path is unsafe: {path}",
                        )
                    continue
                if (
                    not (
                        stat.S_ISDIR(metadata.st_mode)
                        or stat.S_ISREG(metadata.st_mode)
                    )
                    or metadata.st_uid != expected_uid
                    or metadata.st_gid != expected_gid
                ):
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Pinned Node runtime path is unsafe: {path}",
                    )
                mode = (
                    0o755
                    if stat.S_ISDIR(metadata.st_mode)
                    or stat.S_IMODE(metadata.st_mode) & 0o111
                    else 0o644
                )
                os.chmod(path, mode)
                if os.geteuid() == 0:
                    os.chown(path, expected_uid, expected_gid)
        except ManagementError:
            raise
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Pinned Node runtime is unsafe: {root}",
            ) from exc

    def _bridge_pins(self) -> list[tuple[str, str, str, str, str]]:
        lock = self.source_root / "payload" / "agent" / "bridge-dependencies.lock"
        pins: list[tuple[str, str, str, str, str]] = []
        expected = {
            "pi-ai": "@earendil-works/pi-ai",
            "pi-mono": "@earendil-works/pi-coding-agent",
        }
        try:
            lines = lock.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError) as exc:
            raise ManagementError(
                78,
                "INVALID_DEPENDENCY_LOCK",
                "Bridge lock is unavailable.",
            ) from exc
        seen: set[str] = set()
        for line in lines:
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if len(fields) != 7:
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "Bridge lock is invalid.",
                )
            name, package, version, url, digest, integrity, license_name = fields
            try:
                parsed = urllib.parse.urlsplit(url)
                port = parsed.port
            except ValueError:
                parsed = urllib.parse.urlsplit("")
                port = -1
            if (
                expected.get(name) != package
                or package in seen
                or re.fullmatch(r"\d+(?:\.\d+){2}", version) is None
                or parsed.scheme != "https"
                or parsed.hostname != "registry.npmjs.org"
                or port is not None
                or parsed.username is not None
                or parsed.password is not None
                or parsed.query
                or parsed.fragment
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                or not integrity.startswith("sha512-")
                or license_name != "MIT"
            ):
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "Bridge lock is invalid.",
                )
            seen.add(package)
            pins.append((package, version, url, digest, integrity))
        if seen != set(expected.values()):
            raise ManagementError(
                78,
                "INVALID_DEPENDENCY_LOCK",
                "Bridge lock is incomplete.",
            )
        return pins

    def _validate_bridge_package_lock(
        self,
        pins: list[tuple[str, str, str, str, str]],
    ) -> None:
        manifest_path = self.source_root / "payload" / "agent" / "bridge-package.json"
        lock_path = (
            self.source_root / "payload" / "agent" / "bridge-package-lock.json"
        )
        manifest = load_json(manifest_path)
        lock = load_json(lock_path)
        dependencies = {
            package: url for package, _, url, _, _ in pins
        }
        expected_manifest = {
            "name": "beep-bridges",
            "version": "1.0.0",
            "private": True,
            "dependencies": dependencies,
        }
        packages = lock.get("packages")
        if (
            manifest != expected_manifest
            or set(lock) != {"name", "version", "lockfileVersion", "requires", "packages"}
            or lock.get("name") != "beep-bridges"
            or lock.get("version") != "1.0.0"
            or lock.get("lockfileVersion") != 3
            or lock.get("requires") is not True
            or not isinstance(packages, dict)
            or packages.get("")
            != {
                "name": "beep-bridges",
                "version": "1.0.0",
                "dependencies": dependencies,
            }
        ):
            raise ManagementError(
                78,
                "INVALID_DEPENDENCY_LOCK",
                "The complete bridge dependency lock is invalid.",
            )
        for name, package in packages.items():
            path = PurePosixPath(name) if isinstance(name, str) else PurePosixPath("/")
            if name == "":
                continue
            if (
                not isinstance(name, str)
                or "\\" in name
                or path.is_absolute()
                or ".." in path.parts
                or not path.parts
                or path.parts[0] != "node_modules"
                or not isinstance(package, dict)
                or not isinstance(package.get("version"), str)
                or not package["version"]
                or not isinstance(package.get("resolved"), str)
                or not isinstance(package.get("integrity"), str)
                or re.fullmatch(
                    r"sha512-[A-Za-z0-9+/]+={0,2}",
                    package["integrity"],
                )
                is None
            ):
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "The complete bridge dependency lock contains an unsafe entry.",
                )
            try:
                resolved = urllib.parse.urlsplit(package["resolved"])
                port = resolved.port
            except ValueError as exc:
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "The complete bridge dependency lock contains an invalid URL.",
                ) from exc
            if (
                resolved.scheme != "https"
                or resolved.hostname != "registry.npmjs.org"
                or port is not None
                or resolved.username is not None
                or resolved.password is not None
                or resolved.query
                or resolved.fragment
            ):
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "The complete bridge dependency lock leaves the npm registry.",
                )
        for package, version, url, _, integrity in pins:
            direct = packages.get(f"node_modules/{package}")
            if not isinstance(direct, dict) or (
                direct.get("version"),
                direct.get("resolved"),
                direct.get("integrity"),
            ) != (version, url, integrity):
                raise ManagementError(
                    78,
                    "INVALID_DEPENDENCY_LOCK",
                    "The direct bridge pins differ from the complete dependency lock.",
                )

    def _bridge_marker_value(
        self,
        pins: list[tuple[str, str, str, str, str]],
    ) -> dict[str, Any]:
        modules = self.paths.node_root / "lib" / "node_modules"
        manifest = self.source_root / "payload" / "agent" / "bridge-package.json"
        package_lock = (
            self.source_root / "payload" / "agent" / "bridge-package-lock.json"
        )
        return {
            "schema_version": 1,
            "packages": [
                {
                    "name": package,
                    "version": version,
                    "url": url,
                    "sha256": digest,
                    "integrity": integrity,
                }
                for package, version, url, digest, integrity in pins
            ],
            "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "lock_sha256": hashlib.sha256(package_lock.read_bytes()).hexdigest(),
            "tree_digest": self._tree_digest(modules),
        }

    def _bridge_tree_valid(
        self,
        pins: list[tuple[str, str, str, str, str]],
    ) -> bool:
        marker = self.paths.bridge_marker
        try:
            metadata = marker.lstat()
            value = load_json(marker)
        except (OSError, ManagementError):
            return False
        expected_uid, expected_gid = self._expected_node_owner()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o644
        ):
            return False
        try:
            expected = self._bridge_marker_value(pins)
        except ManagementError:
            return False
        return value == expected

    def _install_bridge_archives(
        self,
        npm: Path,
        pins: list[tuple[str, str, str, str, str]],
        environment: dict[str, str],
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="beep-bridges-") as directory:
            work = Path(directory)
            self._validate_bridge_package_lock(pins)
            shutil.copy2(
                self.source_root / "payload" / "agent" / "bridge-package.json",
                work / "package.json",
            )
            shutil.copy2(
                self.source_root / "payload" / "agent" / "bridge-package-lock.json",
                work / "package-lock.json",
            )
            install_environment = {
                **environment,
                "NPM_CONFIG_CACHE": str(work / "npm-cache"),
            }
            self._run_dependency_command(
                [
                    str(npm),
                    "--prefix",
                    str(work),
                    "ci",
                    "--ignore-scripts",
                    "--no-bin-links",
                    "--no-audit",
                    "--no-fund",
                    "--registry=https://registry.npmjs.org/",
                ],
                environment=install_environment,
            )
            source_modules = work / "node_modules"
            self._assert_tree_safe(source_modules)
            modules = self.paths.node_root / "lib" / "node_modules"
            self._assert_tree_safe(modules)
            for target in modules.iterdir():
                if target.name in {"npm", "corepack"}:
                    continue
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.is_file() and not target.is_symlink():
                    target.unlink()
                else:
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Pinned Node module path is unsafe: {target}",
                    )
            for source in source_modules.iterdir():
                if source.name in {"npm", "corepack"}:
                    raise ManagementError(
                        78,
                        "DEPENDENCY_INTEGRITY_FAILED",
                        "The bridge lock attempts to replace Node's package manager.",
                    )
                target = modules / source.name
                if source.is_dir():
                    shutil.copytree(source, target, symlinks=False)
                elif source.is_file() and not source.is_symlink():
                    shutil.copy2(source, target)
                else:
                    raise ManagementError(
                        78,
                        "DEPENDENCY_INTEGRITY_FAILED",
                        f"The locked bridge tree contains an unsafe entry: {source}",
                    )
            self._assert_tree_safe(modules)

    def _bridge_package_valid(
        self,
        npm_state: dict[str, Any],
        package: str,
        version: str,
    ) -> bool:
        state = npm_state.get(package)
        if not isinstance(state, dict) or state.get("version") != version:
            return False
        package_root = self.paths.node_root / "lib" / "node_modules" / package
        manifest = package_root / "package.json"
        if manifest.is_symlink() or not manifest.is_file():
            return False
        try:
            metadata = load_json(manifest)
        except ManagementError:
            return False
        return metadata.get("name") == package and metadata.get("version") == version

    def _bridge_runtime_valid(self) -> bool:
        try:
            pins = self._bridge_pins()
            self._validate_bridge_package_lock(pins)
            if not self._bridge_tree_valid(pins):
                return False
            state = {
                package: {"version": version}
                for package, version, _, _, _ in pins
            }
            if any(
                not self._bridge_package_valid(state, package, version)
                for package, version, _, _, _ in pins
            ):
                return False
            package = "@earendil-works/pi-coding-agent"
            package_root = (
                self.paths.node_root / "lib" / "node_modules" / package
            )
            manifest = load_json(package_root / "package.json")
            commands = manifest.get("bin")
            relative_value = commands.get("pi") if isinstance(commands, dict) else None
            if not isinstance(relative_value, str):
                return False
            relative = PurePosixPath(relative_value)
            if relative.is_absolute() or ".." in relative.parts or not relative.parts:
                return False
            target = package_root.joinpath(*relative.parts)
            launcher = self.paths.node_root / "bin" / "pi"
            expected = (
                "#!/bin/sh\n"
                f"exec {shlex.quote(str(self.paths.node_root / 'bin' / 'node'))} "
                f"{shlex.quote(str(target))} \"$@\"\n"
            ).encode()
            metadata = launcher.lstat()
            return (
                stat.S_ISREG(metadata.st_mode)
                and stat.S_IMODE(metadata.st_mode) == 0o755
                and target.is_file()
                and not target.is_symlink()
                and launcher.read_bytes() == expected
            )
        except (OSError, ManagementError):
            return False

    def _ensure_node_launchers(
        self,
        pins: list[tuple[str, str, str, str, str]],
        changed: list[str],
    ) -> None:
        """Replace npm links with regular launchers into the pinned packages."""
        self._materialize_node_links(changed)
        package = "@earendil-works/pi-coding-agent"
        expected_version = next(
            (version for name, version, _, _, _ in pins if name == package),
            None,
        )
        package_root = self.paths.node_root / "lib" / "node_modules" / package
        manifest = package_root / "package.json"
        if expected_version is None or manifest.is_symlink() or not manifest.is_file():
            raise ManagementError(
                78,
                "DEPENDENCY_INTEGRITY_FAILED",
                "The pinned pi command package is incomplete.",
            )
        metadata = load_json(manifest)
        commands = metadata.get("bin")
        relative_value = commands.get("pi") if isinstance(commands, dict) else None
        if (
            metadata.get("name") != package
            or metadata.get("version") != expected_version
            or not isinstance(relative_value, str)
        ):
            raise ManagementError(
                78,
                "DEPENDENCY_INTEGRITY_FAILED",
                "The pinned pi command metadata is invalid.",
            )
        relative = PurePosixPath(relative_value)
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise ManagementError(
                78,
                "DEPENDENCY_INTEGRITY_FAILED",
                "The pinned pi command path is unsafe.",
            )
        target = package_root.joinpath(*relative.parts)
        if target.is_symlink() or not target.is_file():
            raise ManagementError(
                78,
                "DEPENDENCY_INTEGRITY_FAILED",
                "The pinned pi command is unavailable.",
            )
        bin_root = self.paths.node_root / "bin"
        if bin_root.is_symlink() or not bin_root.is_dir():
            raise ManagementError(
                73, "UNSAFE_PATH", f"Pinned Node command path is unsafe: {bin_root}"
            )
        launcher = bin_root / "pi"
        content = (
            "#!/bin/sh\n"
            f"exec {shlex.quote(str(self.paths.node_root / 'bin' / 'node'))} "
            f"{shlex.quote(str(target))} \"$@\"\n"
        ).encode()
        if atomic_write(launcher, content, mode=0o755):
            changed.append(str(launcher))
        self._assert_node_runtime_safe()

    @staticmethod
    def _download_dependency(
        url: str,
        *,
        hostname: str,
        maximum_bytes: int,
        label: str,
    ) -> bytes:
        parsed = urllib.parse.urlsplit(url)
        try:
            port = parsed.port
        except ValueError as exc:
            raise ManagementError(
                78,
                "DEPENDENCY_DOWNLOAD_FAILED",
                f"The {label} download URL is invalid.",
            ) from exc
        if (
            parsed.scheme != "https"
            or parsed.hostname != hostname
            or port is not None
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
        ):
            raise ManagementError(
                78,
                "DEPENDENCY_DOWNLOAD_FAILED",
                f"The {label} download URL is unsafe.",
            )
        request = urllib.request.Request(
            url, headers={"User-Agent": "beep-manage/1"}
        )
        last_error: BaseException | None = None
        for attempt in range(1, DEPENDENCY_ATTEMPTS + 1):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    final = urllib.parse.urlsplit(response.geturl())
                    try:
                        final_port = final.port
                    except ValueError as exc:
                        raise ManagementError(
                            78,
                            "DEPENDENCY_DOWNLOAD_FAILED",
                            f"The {label} download redirected to an invalid URL.",
                        ) from exc
                    if (
                        final.scheme != "https"
                        or final.hostname != hostname
                        or final_port is not None
                        or final.username is not None
                        or final.password is not None
                        or final.fragment
                    ):
                        raise ManagementError(
                            78,
                            "DEPENDENCY_DOWNLOAD_FAILED",
                            f"The {label} download redirected outside {hostname}.",
                        )
                    data = response.read(maximum_bytes + 1)
                    if len(data) > maximum_bytes:
                        raise ManagementError(
                            78,
                            "DEPENDENCY_INTEGRITY_FAILED",
                            f"The {label} download exceeds its size limit.",
                        )
                    return data
            except ManagementError:
                raise
            except (OSError, http.client.HTTPException) as exc:
                last_error = exc
                if attempt < DEPENDENCY_ATTEMPTS:
                    time.sleep(DEPENDENCY_RETRY_SECONDS)
        raise ManagementError(
            75,
            "DEPENDENCY_DOWNLOAD_FAILED",
            f"Could not download the {label}.",
            retryable=True,
        ) from last_error

    def _run_dependency_command(
        self,
        arguments: list[str],
        *,
        environment: dict[str, str],
    ) -> subprocess.CompletedProcess[str]:
        attempt = 0
        lock_deadline = time.monotonic() + APT_LOCK_WAIT_SECONDS
        while True:
            attempt += 1
            try:
                completed = self._run(
                    arguments,
                    check=False,
                    environment=environment,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                completed = subprocess.CompletedProcess(
                    arguments,
                    1,
                    "",
                    str(exc),
                )
            if completed.returncode == 0:
                return completed
            detail = f"{completed.stdout}\n{completed.stderr}".lower()
            apt_locked = Path(arguments[0]).name == "apt-get" and any(
                phrase in detail
                for phrase in (
                    "could not get lock",
                    "unable to acquire the dpkg frontend lock",
                    "is another process using it",
                )
            )
            if apt_locked and time.monotonic() < lock_deadline:
                time.sleep(DEPENDENCY_RETRY_SECONDS)
                continue
            if attempt < DEPENDENCY_ATTEMPTS:
                time.sleep(DEPENDENCY_RETRY_SECONDS)
                continue
            raise ManagementError(
                75,
                "DEPENDENCY_COMMAND_FAILED",
                f"Dependency command failed: {Path(arguments[0]).name}",
                retryable=True,
                recovery=["Inspect the Beep lifecycle audit and system journal."],
            )

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
        self._deploy_pi_models(configuration, uid, gid, changed)
        for path in self.paths.install_root.rglob("*"):
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Runtime contains symlink: {path}")
            if path.is_dir():
                os.chmod(path, 0o755)
            else:
                current_mode = stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)
                os.chmod(path, 0o755 if current_mode & 0o111 else 0o644)
            os.chown(path, 0, 0)
        os.chown(self.paths.install_root, 0, 0)
        os.chmod(self.paths.install_root, 0o755)
        os.chown(self.paths.runtime, uid, gid)

    def _deploy_pi_models(
        self,
        configuration: Configuration,
        uid: int,
        gid: int,
        changed: list[str],
    ) -> None:
        home = Path(pwd.getpwnam(configuration.agent_user).pw_dir)
        models = home / ".pi" / "agent" / "models.json"
        assert_directory_ancestry_safe(models.parent)
        if (
            configuration.provider != "lmstudio"
            or configuration.model is None
            or configuration.model_base_url is None
        ):
            if self._path_present(models):
                metadata = models.lstat()
                if not stat.S_ISREG(metadata.st_mode):
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Refusing unsafe Pi model configuration: {models}",
                    )
                models.unlink()
                changed.append(str(models))
            return
        pi_root = home / ".pi"
        agent_root = pi_root / "agent"
        for path in (pi_root, agent_root):
            if path.is_symlink() or (path.exists() and not path.is_dir()):
                raise ManagementError(73, "UNSAFE_PATH", f"Refusing unsafe path: {path}")
            path.mkdir(mode=0o700, exist_ok=True)
            os.chmod(path, 0o700)
            os.chown(path, uid, gid)
        content = {
            "providers": {
                "lmstudio": {
                    "baseUrl": configuration.model_base_url,
                    "api": "openai-completions",
                    "apiKey": "LMSTUDIO_API_KEY",
                    "compat": {
                        "supportsDeveloperRole": False,
                        "supportsReasoningEffort": False,
                    },
                    "models": [{"id": configuration.model}],
                }
            }
        }
        if atomic_write(
            models,
            json.dumps(content, indent=2, sort_keys=True).encode() + b"\n",
            mode=0o600,
            uid=uid,
            gid=gid,
        ):
            changed.append(str(models))

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
        if self.paths.product_root.is_symlink() or (
            self.paths.product_root.exists()
            and not self.paths.product_root.is_dir()
        ):
            shutil.rmtree(staging)
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Refusing unsafe product path: {self.paths.product_root}",
            )
        if self.paths.product_root.exists():
            self._assert_tree_safe(self.paths.product_root)
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
        if not source.is_dir() or source.is_symlink():
            raise ManagementError(66, "SOURCE_INCOMPLETE", f"Missing source tree: {source}")
        if destination.is_symlink() or (
            destination.exists() and not destination.is_dir()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Refusing unsafe destination: {destination}"
            )
        destination.mkdir(parents=True, exist_ok=True)
        expected: set[Path] = set()
        for item in sorted(source.rglob("*")):
            if "__pycache__" in item.parts or item.suffix == ".pyc":
                continue
            relative = item.relative_to(source)
            target = destination / relative
            expected.add(target)
            if item.is_symlink():
                raise ManagementError(78, "UNSAFE_SOURCE", f"Source symlink rejected: {item}")
            if item.is_dir():
                if target.is_symlink() or (
                    target.exists() and not target.is_dir()
                ):
                    raise ManagementError(
                        73, "UNSAFE_PATH", f"Refusing unsafe destination: {target}"
                    )
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not item.is_file():
                raise ManagementError(
                    78,
                    "UNSAFE_SOURCE",
                    f"Unsupported source path: {item}",
                )
            mode = 0o755 if executable or os.access(item, os.X_OK) else 0o644
            if atomic_write(target, item.read_bytes(), mode=mode):
                changed.append(str(target))
        for target in sorted(destination.rglob("*"), reverse=True):
            if target not in expected:
                if target.is_symlink():
                    raise ManagementError(
                        73, "UNSAFE_PATH", f"Refusing destination symlink: {target}"
                    )
                metadata = target.lstat()
                if stat.S_ISDIR(metadata.st_mode):
                    target.rmdir()
                elif stat.S_ISREG(metadata.st_mode):
                    target.unlink()
                else:
                    raise ManagementError(
                        73,
                        "UNSAFE_PATH",
                        f"Refusing unsupported destination: {target}",
                    )
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
        if self.paths.policy.is_symlink() or (
            self.paths.policy.exists() and not self.paths.policy.is_file()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Refusing unsafe policy path: {self.paths.policy}"
            )
        if not self.paths.policy.exists():
            if atomic_write(
                self.paths.policy,
                (self.source_root / "payload" / "etc" / "policy.yaml").read_bytes(),
                mode=0o644,
            ):
                changed.append(str(self.paths.policy))
        else:
            os.chmod(self.paths.policy, 0o644)
            os.chown(self.paths.policy, 0, 0)
            if not runtime_policy.validate_policy(self.paths.policy):
                if atomic_write(
                    self.paths.policy,
                    (
                        self.source_root / "payload" / "etc" / "policy.yaml"
                    ).read_bytes(),
                    mode=0o644,
                ):
                    changed.append(str(self.paths.policy))
        catalog_source = self.source_root / "payload" / "etc" / "agents" / "catalog.json"
        runtime_family.validate_catalog(
            runtime_family.load_json(catalog_source, label="catalog")
        )
        if atomic_write(self.paths.catalog, catalog_source.read_bytes(), mode=0o644):
            changed.append(str(self.paths.catalog))
        if self.paths.inventory.exists():
            runtime_family.validate_inventory(
                runtime_family.load_json(self.paths.inventory, label="inventory")
            )
        elif atomic_write(
            self.paths.inventory,
            canonical_json(
                {
                    "schema_version": 1,
                    "generated_at": utc_now(),
                    "products": {},
                }
            )
            + b"\n",
            mode=0o600,
        ):
            changed.append(str(self.paths.inventory))
        password_file = self._configuration_secret_path(
            invocation, "chat_password_file", "BEEP_ADMIN_PASSWORD_FILE"
        )
        existing = self._read_secret_environment()
        if password_file is not None:
            password = self._read_one_secret(password_file, minimum=12)
            existing["BEEP_ADMIN_PASSWORD_HASH"] = runtime_auth.hash_password(password)
        elif not runtime_auth.valid_password_hash(
            existing.get("BEEP_ADMIN_PASSWORD_HASH")
        ):
            password = self._prompted_chat_password or self._interactive_password()
            existing["BEEP_ADMIN_PASSWORD_HASH"] = runtime_auth.hash_password(password)
            self._prompted_chat_password = None
        credential_file = self._configuration_secret_path(
            invocation,
            "provider_credential_file",
            "BEEP_PROVIDER_CREDENTIAL_FILE",
        )
        selected_credential = (
            PROVIDER_KEYS[configuration.provider]
            if configuration.provider is not None
            else None
        )
        for credential_key in PROVIDER_KEYS.values():
            if credential_key != selected_credential:
                existing.pop(credential_key, None)
        if configuration.provider is not None:
            existing["BEEP_PROVIDER"] = configuration.provider
            if credential_file is not None:
                existing[PROVIDER_KEYS[configuration.provider]] = self._read_one_secret(
                    credential_file, minimum=1
                )
            elif configuration.provider == "lmstudio":
                existing.setdefault("LMSTUDIO_API_KEY", "local")
            elif not existing.get(
                PROVIDER_KEYS[configuration.provider], ""
            ).strip():
                prompted = self._prompted_provider_credential
                if prompted is None or prompted[0] != configuration.provider:
                    value = self._interactive_provider_credential(
                        configuration.provider
                    )
                else:
                    value = prompted[1]
                existing[PROVIDER_KEYS[configuration.provider]] = value
                self._prompted_provider_credential = None
        else:
            existing.pop("BEEP_PROVIDER", None)
        if configuration.model is not None:
            existing["BEEP_MODEL"] = configuration.model
        else:
            existing.pop("BEEP_MODEL", None)
        if configuration.model_base_url is not None:
            existing["BEEP_MODEL_BASE_URL"] = configuration.model_base_url
        else:
            existing.pop("BEEP_MODEL_BASE_URL", None)
        if (
            configuration.provider == "openai"
            and configuration.model_base_url is not None
        ):
            existing["OPENAI_BASE_URL"] = configuration.model_base_url
        else:
            existing.pop("OPENAI_BASE_URL", None)
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
        if self.paths.session_key.is_symlink() or (
            self.paths.session_key.exists() and not self.paths.session_key.is_file()
        ):
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Refusing unsafe session key path: {self.paths.session_key}",
            )
        current_session_key = (
            self.paths.session_key.read_bytes()
            if self.paths.session_key.is_file()
            else b""
        )
        if not 32 <= len(current_session_key.strip()) <= 4096:
            key = secrets.token_urlsafe(48).encode() + b"\n"
        else:
            key = current_session_key
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
        if lifecycle_path.is_symlink() or (
            lifecycle_path.exists() and not lifecycle_path.is_file()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Refusing unsafe lifecycle path: {lifecycle_path}"
            )
        if not lifecycle_path.exists():
            with self._lifecycle_environment():
                runtime_lifecycle.initialize(configuration.ttl_days)
            os.chown(lifecycle_path, uid, gid)
            changed.append(str(lifecycle_path))
        else:
            metadata = lifecycle_path.stat(follow_symlinks=False)
            if (
                stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_uid != uid
                or metadata.st_gid != gid
            ):
                os.chmod(lifecycle_path, 0o600)
                os.chown(lifecycle_path, uid, gid)
                changed.append(str(lifecycle_path))

    @staticmethod
    def _quote_env(value: str) -> str:
        if "\n" in value or "\r" in value or "\x00" in value:
            raise ManagementError(65, "INVALID_SECRET", "Environment value is invalid.")
        escaped = (
            value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("$", "\\$")
            .replace("`", "\\`")
        )
        return f'"{escaped}"'

    def _read_secret_environment(self) -> dict[str, str]:
        if not self.paths.secrets.is_file() or self.paths.secrets.is_symlink():
            return {}
        result: dict[str, str] = {}
        for line in self.paths.secrets.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if (
                not separator
                or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key)
                or key not in SECRET_ENV_KEYS
                or key in result
            ):
                raise ManagementError(78, "INVALID_SECRET_ENV", "Secret environment is invalid.")
            lexer = shlex.shlex(value, posix=True)
            lexer.whitespace_split = True
            lexer.commenters = ""
            try:
                fields = list(lexer)
            except ValueError as exc:
                raise ManagementError(
                    78, "INVALID_SECRET_ENV", "Secret environment is invalid."
                ) from exc
            if len(fields) != 1:
                raise ManagementError(
                    78, "INVALID_SECRET_ENV", "Secret environment is invalid."
                )
            result[key] = fields[0]
        return result

    @staticmethod
    def _read_one_secret(path: Path, *, minimum: int) -> str:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError as exc:
            raise ManagementError(65, "INVALID_SECRET", "Secret file is unavailable.") from exc
        try:
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != 0
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_size > 1025
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_SECRET_FILE",
                    "Secret files must be root-owned regular files with mode 0600.",
                )
            content = os.read(descriptor, 1026)
        finally:
            os.close(descriptor)
        try:
            value = content.decode("utf-8")
        except UnicodeError as exc:
            raise ManagementError(65, "INVALID_SECRET", "Secret file is not UTF-8.") from exc
        value = value.rstrip("\n")
        if "\n" in value or "\r" in value or not minimum <= len(value.encode()) <= 1024:
            raise ManagementError(
                65, "INVALID_SECRET", "Secret file must contain one bounded UTF-8 line."
            )
        return value

    def _prepare_interactive_secrets(
        self,
        invocation: Invocation,
        configuration: Configuration,
    ) -> None:
        password_file = self._configuration_secret_path(
            invocation, "chat_password_file", "BEEP_ADMIN_PASSWORD_FILE"
        )
        if password_file is None and not self._password_configured():
            self._prompted_chat_password = self._interactive_password()
        credential_file = self._configuration_secret_path(
            invocation,
            "provider_credential_file",
            "BEEP_PROVIDER_CREDENTIAL_FILE",
        )
        if (
            configuration.provider is not None
            and configuration.provider != "lmstudio"
            and credential_file is None
            and not self._provider_configured(configuration.provider)
        ):
            self._prompted_provider_credential = (
                configuration.provider,
                self._interactive_provider_credential(configuration.provider),
            )

    @staticmethod
    def _interactive_password() -> str:
        if not sys.stdin.isatty():
            raise ManagementError(
                64, "REQUIRED_INPUT", "A protected chat_password_file is required."
            )
        while True:
            try:
                first = getpass.getpass("Beep chat password (12-1024 bytes): ")
                second = getpass.getpass("Confirm Beep chat password: ")
            except (EOFError, KeyboardInterrupt) as exc:
                raise ManagementError(
                    64,
                    "INTERACTIVE_INPUT_REQUIRED",
                    "Interactive installation was cancelled.",
                ) from exc
            if not 12 <= len(first.encode()) <= 1024:
                print("  Password must contain 12 to 1024 bytes.", file=sys.stderr)
                continue
            if first != second:
                print("  Passwords did not match.", file=sys.stderr)
                continue
            return first

    @staticmethod
    def _interactive_provider_credential(provider: str) -> str:
        if not sys.stdin.isatty():
            raise ManagementError(
                64,
                "REQUIRED_INPUT",
                "A protected provider_credential_file is required.",
            )
        while True:
            try:
                value = getpass.getpass(f"{provider} provider credential: ")
            except (EOFError, KeyboardInterrupt) as exc:
                raise ManagementError(
                    64,
                    "INTERACTIVE_INPUT_REQUIRED",
                    "Interactive installation was cancelled.",
                ) from exc
            if (
                1 <= len(value.encode()) <= 1024
                and "\n" not in value
                and "\r" not in value
            ):
                return value
            print(
                "  Provider credential must contain 1 to 1024 bytes on one line.",
                file=sys.stderr,
            )

    def _deploy_services(
        self,
        configuration: Configuration,
        uid: int,
        gid: int,
        changed: list[str],
    ) -> None:
        specifications = self._host_resource_specs(configuration)
        for destination in (
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
            self.paths.logrotate,
        ):
            content, mode = specifications[destination]
            if atomic_write(destination, content, mode=mode):
                changed.append(str(destination))
        wrapper, wrapper_mode = specifications[self.paths.entrypoint]
        if atomic_write(self.paths.entrypoint, wrapper, mode=wrapper_mode):
            changed.append(str(self.paths.entrypoint))
        for command in HOST_COMMANDS:
            destination = self.paths.command_root / command
            content, mode = specifications[destination]
            if atomic_write(destination, content, mode=mode):
                changed.append(str(destination))
        os.chown(self.paths.secrets, uid, gid)

    def _start_services(self, changed: list[str], *, suspended: bool) -> None:
        if not shutil.which("systemctl"):
            raise ManagementError(69, "SYSTEMD_MISSING", "systemctl is required.")
        self._run(["systemctl", "daemon-reload"])
        if suspended:
            self._stop_services()
            return
        self._run(["systemctl", "enable", "--now", "beep-chat.service"])
        self._run(["systemctl", "enable", "--now", "beep-health.timer"])
        failed = [
            unit
            for unit in ("beep-chat.service", "beep-health.timer")
            if not self._service_active(unit) or not self._service_enabled(unit)
        ]
        if failed:
            raise ManagementError(
                1,
                "SERVICE_START_FAILED",
                "Beep units did not become active and enabled: "
                + ", ".join(failed),
            )
        changed.extend(["unit:beep-chat.service", "unit:beep-health.timer"])

    def _execute_backup(
        self, invocation: Invocation
    ) -> tuple[list[str], str | None, str]:
        marker = self.load_marker(required=True)
        destination = self._backup_destination(invocation)
        if destination is None:
            raise ManagementError(64, "REQUIRED_INPUT", "backup_destination is required.")
        destination.mkdir(parents=True, exist_ok=True)
        if not destination.is_dir() or destination.is_symlink():
            raise ManagementError(73, "UNSAFE_PATH", "Backup destination is unsafe.")
        archive = destination / f"beep-{self.version}-{invocation.correlation_id}.tar.gz"
        if archive.exists() or archive.is_symlink():
            raise ManagementError(73, "BACKUP_EXISTS", "Backup destination already exists.")
        changed: list[str] = []
        self._secure_state_control_root(changed)
        self._assert_account_home_migratable()
        for path in (
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        ):
            self._assert_tree_safe(path)
        self._materialize_python_environment_links(changed)
        service_state = self._capture_service_state()
        try:
            self._stop_services()
            with tarfile.open(archive, "x:gz") as output:
                for path, name in (
                    (self.paths.account_home, "home"),
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
                    raise ManagementError(
                        1, "BACKUP_INVALID", "Backup verification failed."
                    )
        except Exception:
            archive.unlink(missing_ok=True)
            raise
        finally:
            try:
                self._restore_service_state(service_state)
            except Exception as exc:
                archive.unlink(missing_ok=True)
                try:
                    self._stop_services()
                except Exception:
                    pass
                raise ManagementError(
                    1,
                    "SERVICE_RESTORE_FAILED",
                    "Backup did not commit because Beep's prior service state could not be restored.",
                    recovery=[
                        "Keep Beep stopped, inspect the system journal, and retry backup with a new correlation ID."
                    ],
                ) from exc
        changed.append(str(archive))
        return sorted(set(changed)), str(marker["version"]), str(archive)

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
            Path("/opt"),
            Path("/etc"),
            Path("/var/lib"),
            Path("/var/log"),
            self.paths.account_home,
        )
        if any(destination == root or root in destination.parents for root in protected):
            raise ManagementError(
                65,
                "INVALID_BACKUP_DESTINATION",
                "Backup destination must be outside every product root.",
            )
        return destination

    def _create_recovery_snapshot(
        self,
        correlation_id: str,
        service_state: dict[str, Any],
    ) -> Path:
        marker = self.load_marker(required=True)
        self._validate_service_snapshot(service_state)
        self._prepare_recovery_root(create=True)
        snapshot = self.paths.rollback_root / correlation_id
        if self._path_present(snapshot):
            raise ManagementError(
                73,
                "RECOVERY_SNAPSHOT_EXISTS",
                "A recovery snapshot already uses this correlation ID.",
                recovery=["Retry with a new lifecycle correlation ID."],
            )
        temporary = Path(
            tempfile.mkdtemp(
                prefix=f".beep-recovery-{correlation_id}-",
                dir=self.paths.state_root.parent,
            )
        )
        try:
            root_presence: dict[str, bool] = {}
            for source, name in (
                (self.paths.install_root, "opt"),
                (self.paths.account_home, "home"),
                (self.paths.configuration_root, "etc"),
            ):
                if not self._path_present(source):
                    root_presence[name] = False
                    continue
                self._assert_tree_safe(source)
                shutil.copytree(source, temporary / name, symlinks=False)
                root_presence[name] = True
            self._assert_tree_safe(self.paths.state_root)
            root_presence["state"] = True

            def omit_recovery(directory: str, names: list[str]) -> set[str]:
                if Path(directory) == self.paths.state_root:
                    return {self.paths.rollback_root.name} & set(names)
                return set()

            shutil.copytree(
                self.paths.state_root,
                temporary / "state",
                symlinks=False,
                ignore=omit_recovery,
            )
            ownership: dict[str, list[int]] = {}
            for source, name in (
                (self.paths.install_root, "opt"),
                (self.paths.account_home, "home"),
                (self.paths.configuration_root, "etc"),
                (self.paths.state_root, "state"),
            ):
                if not root_presence[name]:
                    continue
                ownership.update(
                    self._ownership_map(
                        source,
                        name,
                        excluded=(
                            {self.paths.rollback_root}
                            if source == self.paths.state_root
                            else set()
                        ),
                    )
                )
            present_host_files: list[str] = []
            for host_path in self._host_resources():
                if host_path.is_symlink():
                    raise ManagementError(
                        73, "UNSAFE_PATH", f"Refusing symlink: {host_path}"
                    )
                if not host_path.exists():
                    continue
                self._assert_no_symlink_ancestors(host_path.parent)
                if not host_path.is_file():
                    raise ManagementError(
                        73, "UNSAFE_PATH", f"Host resource is not a file: {host_path}"
                    )
                relative = host_path.relative_to("/")
                target = temporary / "host" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(host_path, target)
                present_host_files.append(str(host_path))
                metadata = host_path.stat(follow_symlinks=False)
                ownership[f"host/{relative}"] = [metadata.st_uid, metadata.st_gid]
            digests = {
                name: self._tree_digest(temporary / name)
                for name in ("opt", "home", "etc", "state", "host")
                if (temporary / name).exists()
            }
            atomic_write(
                temporary / "snapshot.json",
                canonical_json(
                    {
                        "schema_version": 1,
                        "product_id": PRODUCT_ID,
                        "correlation_id": correlation_id,
                        "instance_id": marker["instance_id"],
                        "created_at": utc_now(),
                        "version": marker["version"],
                        "root_presence": root_presence,
                        "service_state": service_state,
                        "tree_digests": digests,
                        "host_files": sorted(present_host_files),
                        "ownership": ownership,
                    }
                )
                + b"\n",
                mode=0o600,
            )
            os.replace(temporary, snapshot)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        try:
            atomic_write(
                self.paths.rollback_root / "latest",
                f"{snapshot.name}\n".encode(),
                mode=0o600,
            )
        except Exception:
            if self._path_present(snapshot):
                self._assert_tree_safe(snapshot)
                shutil.rmtree(snapshot)
            raise
        return snapshot

    def _execute_rollback(
        self,
        *,
        allow_degraded: bool = False,
    ) -> tuple[list[str], str | None]:
        self._last_rollback_degraded = False
        marker = self.load_marker(required=True)
        changed: list[str] = []
        self._secure_state_control_root(changed)
        if self._path_present(self.paths.node_root):
            self._node_link_replacements()
        self._prepare_recovery_root(create=False)
        latest = self.paths.rollback_root / "latest"
        try:
            latest_metadata = latest.lstat()
        except OSError:
            latest_metadata = None
        expected_uid, expected_gid = self._expected_node_owner()
        if (
            latest_metadata is None
            or not stat.S_ISREG(latest_metadata.st_mode)
            or latest_metadata.st_uid != expected_uid
            or latest_metadata.st_gid != expected_gid
            or stat.S_IMODE(latest_metadata.st_mode) != 0o600
        ):
            raise ManagementError(66, "ROLLBACK_UNAVAILABLE", "No rollback snapshot exists.")
        name = latest.read_text(encoding="utf-8").strip()
        try:
            if str(uuid.UUID(name)) != name:
                raise ValueError
        except ValueError as exc:
            raise ManagementError(
                65, "ROLLBACK_INVALID", "Rollback metadata is invalid."
            ) from exc
        snapshot = self.paths.rollback_root / name
        self._assert_tree_safe(snapshot)
        metadata = load_json(snapshot / "snapshot.json")
        expected_fields = {
            "schema_version",
            "product_id",
            "correlation_id",
            "instance_id",
            "created_at",
            "version",
            "root_presence",
            "service_state",
            "tree_digests",
            "host_files",
            "ownership",
        }
        if (
            set(metadata) != expected_fields
            or metadata["schema_version"] != 1
            or metadata["product_id"] != PRODUCT_ID
            or metadata["correlation_id"] != name
            or metadata["instance_id"] != marker["instance_id"]
            or not VERSION_PATTERN.fullmatch(str(metadata["version"]))
            or not isinstance(metadata["root_presence"], dict)
            or set(metadata["root_presence"])
            != {"opt", "home", "etc", "state"}
            or any(
                not isinstance(present, bool)
                for present in metadata["root_presence"].values()
            )
            or metadata["root_presence"]["state"] is not True
            or not self._service_snapshot_valid(metadata["service_state"])
            or not isinstance(metadata["tree_digests"], dict)
            or not isinstance(metadata["host_files"], list)
            or any(not isinstance(path, str) for path in metadata["host_files"])
            or metadata["host_files"] != sorted(set(metadata["host_files"]))
            or not isinstance(metadata["ownership"], dict)
            or any(
                path not in {str(item) for item in self._host_resources()}
                for path in metadata["host_files"]
            )
        ):
            raise ManagementError(65, "ROLLBACK_INVALID", "Rollback metadata is invalid.")
        self._validate_snapshot_ownership(metadata["ownership"], snapshot)
        for tree_name, expected_digest in metadata["tree_digests"].items():
            if tree_name not in {"opt", "home", "etc", "state", "host"} or (
                self._tree_digest(snapshot / tree_name) != expected_digest
            ):
                raise ManagementError(
                    78, "ROLLBACK_INTEGRITY_FAILED", "Rollback snapshot changed."
                )
        expected_root_trees = {
            name
            for name, present in metadata["root_presence"].items()
            if present
        }
        if (
            not expected_root_trees <= set(metadata["tree_digests"])
            or bool(metadata["host_files"])
            != ("host" in metadata["tree_digests"])
            or any(
                name in metadata["tree_digests"]
                for name, present in metadata["root_presence"].items()
                if not present
            )
        ):
            raise ManagementError(65, "ROLLBACK_INVALID", "Rollback snapshot is incomplete.")
        for name, destination in (
            ("opt", self.paths.install_root),
            ("home", self.paths.account_home),
            ("etc", self.paths.configuration_root),
        ):
            if not self._path_present(destination):
                continue
            if name == "opt":
                self._assert_install_tree_migratable()
            elif name == "home":
                self._assert_account_home_migratable()
            else:
                self._assert_tree_safe(destination)
        self._assert_tree_safe(self.paths.state_root)
        for host_path in self._host_resources():
            if not self._path_present(host_path):
                continue
            self._assert_no_symlink_ancestors(host_path.parent)
            host_metadata = host_path.lstat()
            if not stat.S_ISREG(host_metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Host resource is unsafe: {host_path}",
                )
        self._restore_snapshot_transactionally(
            snapshot,
            metadata,
            changed,
            allow_degraded=allow_degraded,
        )
        changed.extend(
            [
                str(self.paths.install_root),
                str(self.paths.account_home),
                str(self.paths.configuration_root),
                str(self.paths.state_root),
            ]
        )
        return sorted(set(changed)), str(marker["version"])

    def _restore_snapshot_transactionally(
        self,
        snapshot: Path,
        metadata: dict[str, Any],
        changed: list[str],
        *,
        allow_degraded: bool,
    ) -> None:
        """Replace rollback targets with reversible same-filesystem renames."""
        token = uuid.uuid4().hex
        transaction = self.paths.state_root / f".beep-rollback-{token}"
        swaps: list[_PathSwap] = []
        generated: list[Path] = []

        def reserve(path: Path) -> None:
            if self._path_present(path):
                raise ManagementError(
                    73,
                    "ROLLBACK_TRANSACTION_COLLISION",
                    f"Rollback transaction path already exists: {path}",
                )

        try:
            reserve(transaction)
            self._assert_no_symlink_ancestors(transaction.parent)
            transaction.mkdir(mode=0o700)
            generated.append(transaction)
            os.chmod(transaction, 0o700)
            if os.geteuid() == 0:
                expected_uid, expected_gid = self._expected_node_owner()
                os.chown(transaction, expected_uid, expected_gid)

            for name, destination in (
                ("opt", self.paths.install_root),
                ("home", self.paths.account_home),
                ("etc", self.paths.configuration_root),
            ):
                self._assert_no_symlink_ancestors(destination.parent)
                staged = destination.with_name(
                    f".{destination.name}.beep-rollback-new-{token}"
                )
                previous = destination.with_name(
                    f".{destination.name}.beep-rollback-old-{token}"
                )
                reserve(staged)
                reserve(previous)
                record = _PathSwap(
                    target=destination,
                    staged=staged,
                    previous=previous,
                )
                swaps.append(record)
                if not metadata["root_presence"][name]:
                    continue
                source = snapshot / name
                self._assert_tree_safe(source)
                generated.append(staged)
                shutil.copytree(source, staged, symlinks=False)
                self._assert_tree_safe(staged)
                if self._tree_digest(staged) != metadata["tree_digests"][name]:
                    raise ManagementError(
                        78,
                        "ROLLBACK_INTEGRITY_FAILED",
                        f"Could not stage the {name} rollback tree faithfully.",
                    )
                record.has_staged = True

            state_source = snapshot / "state"
            self._assert_tree_safe(state_source)
            state_staged = transaction / "state-new"
            state_previous = transaction / "state-old"
            shutil.copytree(state_source, state_staged, symlinks=False)
            state_previous.mkdir(mode=0o700)
            self._assert_tree_safe(state_staged)
            if self._tree_digest(state_staged) != metadata["tree_digests"]["state"]:
                raise ManagementError(
                    78,
                    "ROLLBACK_INTEGRITY_FAILED",
                    "Could not stage the state rollback tree faithfully.",
                )
            if self._path_present(state_staged / self.paths.rollback_root.name):
                raise ManagementError(
                    65,
                    "ROLLBACK_INVALID",
                    "The state snapshot contains the reserved recovery directory.",
                )

            host_files = set(metadata["host_files"])
            for host_path in self._host_resources():
                self._assert_no_symlink_ancestors(host_path.parent)
                staged = host_path.with_name(
                    f".{host_path.name}.beep-rollback-new-{token}"
                )
                previous = host_path.with_name(
                    f".{host_path.name}.beep-rollback-old-{token}"
                )
                reserve(staged)
                reserve(previous)
                record = _PathSwap(
                    target=host_path,
                    staged=staged,
                    previous=previous,
                )
                swaps.append(record)
                if str(host_path) not in host_files:
                    continue
                source = snapshot / "host" / host_path.relative_to("/")
                if not source.is_file() or source.is_symlink():
                    raise ManagementError(
                        78,
                        "ROLLBACK_INTEGRITY_FAILED",
                        "Host snapshot is incomplete.",
                    )
                generated.append(staged)
                shutil.copy2(source, staged)
                staged_metadata = staged.lstat()
                source_metadata = source.lstat()
                if (
                    not stat.S_ISREG(staged_metadata.st_mode)
                    or stat.S_IMODE(staged_metadata.st_mode)
                    != stat.S_IMODE(source_metadata.st_mode)
                    or staged.read_bytes() != source.read_bytes()
                ):
                    raise ManagementError(
                        78,
                        "ROLLBACK_INTEGRITY_FAILED",
                        f"Could not stage the host rollback file faithfully: {host_path}",
                    )
                record.has_staged = True
        except Exception as exc:
            cleanup_errors = self._cleanup_rollback_artifacts(generated)
            if cleanup_errors:
                raise ManagementError(
                    1,
                    "ROLLBACK_STAGING_CLEANUP_FAILED",
                    "Rollback staging failed and temporary data could not be removed.",
                    recovery=[
                        "Inspect and remove only these root-owned transaction paths: "
                        + ", ".join(cleanup_errors)
                    ],
                ) from exc
            if isinstance(exc, ManagementError):
                raise
            raise ManagementError(
                1,
                "ROLLBACK_STAGING_FAILED",
                "The rollback snapshot could not be staged without changing the live installation.",
                retryable=True,
                recovery=["Correct the reported filesystem error and retry rollback."],
            ) from exc

        prior_service_state: dict[str, Any] | None = None
        state_root_metadata = self.paths.state_root.lstat()
        state_records: list[_PathSwap] = []
        completion_started = False
        try:
            prior_service_state = self._capture_service_state()
            self._stop_services()
            self._assert_tree_safe(self.paths.state_root)
            current_state_names = {
                path.name
                for path in self.paths.state_root.iterdir()
                if path not in {self.paths.rollback_root, transaction}
            }
            staged_state_names = {path.name for path in state_staged.iterdir()}
            for name in sorted(current_state_names | staged_state_names):
                record = _PathSwap(
                    target=self.paths.state_root / name,
                    staged=state_staged / name,
                    previous=state_previous / name,
                    has_staged=name in staged_state_names,
                )
                state_records.append(record)
            root_count = 3
            swaps[root_count:root_count] = state_records
            self._apply_rollback_swaps(swaps)
            self._restore_snapshot_ownership(metadata["ownership"])
            self._secure_state_control_root(changed)
            completion_started = True
            self._complete_rollback(
                metadata["service_state"],
                allow_degraded=allow_degraded,
            )
        except Exception as exc:
            reversal_errors = self._reverse_rollback_swaps(swaps)
            try:
                if os.geteuid() == 0:
                    os.chown(
                        self.paths.state_root,
                        state_root_metadata.st_uid,
                        state_root_metadata.st_gid,
                    )
                os.chmod(
                    self.paths.state_root,
                    stat.S_IMODE(state_root_metadata.st_mode),
                )
            except OSError:
                reversal_errors.append(str(self.paths.state_root))
            if reversal_errors:
                try:
                    self._stop_services()
                except Exception:
                    pass
                raise ManagementError(
                    1,
                    "ROLLBACK_TRANSACTION_FAILED",
                    "Rollback failed and the prior installation could not be restored atomically.",
                    recovery=[
                        "Keep Beep services stopped and preserve these transaction paths: "
                        + ", ".join(reversal_errors)
                    ],
                ) from exc
            cleanup_errors = self._cleanup_rollback_artifacts(generated)
            try:
                if allow_degraded or completion_started:
                    self._stop_services()
                elif prior_service_state is not None:
                    self._restore_service_state(prior_service_state)
            except Exception as service_exc:
                try:
                    self._stop_services()
                except Exception:
                    pass
                raise ManagementError(
                    1,
                    "ROLLBACK_TRANSACTION_FAILED",
                    "The prior installation was restored but services could not be placed in a safe state.",
                    recovery=["Keep Beep services stopped and inspect the system journal."],
                ) from service_exc
            if cleanup_errors:
                raise ManagementError(
                    1,
                    "ROLLBACK_STAGING_CLEANUP_FAILED",
                    "The prior installation was restored but transaction data remains.",
                    recovery=[
                        "Inspect and remove only these root-owned transaction paths: "
                        + ", ".join(cleanup_errors)
                    ],
                ) from exc
            recovery_message = (
                "The pre-rollback installation was restored; Beep services remain stopped."
                if allow_degraded or completion_started
                else "The pre-rollback installation and service state were restored."
            )
            if isinstance(exc, ManagementError):
                exc.recovery.append(recovery_message)
                raise
            raise ManagementError(
                1,
                "ROLLBACK_APPLY_FAILED",
                "Rollback could not be applied; the prior installation was restored.",
                retryable=True,
                recovery=[recovery_message],
            ) from exc

        previous_paths = [record.previous for record in swaps if record.target_moved]
        cleanup_errors = self._cleanup_rollback_artifacts(
            [*previous_paths, *generated]
        )
        if cleanup_errors:
            try:
                self._stop_services()
            except Exception:
                pass
            raise ManagementError(
                1,
                "ROLLBACK_COMMIT_CLEANUP_FAILED",
                "Rollback completed, but superseded transaction data remains.",
                recovery=[
                    "Keep Beep services stopped and inspect these transaction paths: "
                    + ", ".join(cleanup_errors)
                ],
            )

    def _apply_rollback_swaps(self, swaps: list[_PathSwap]) -> None:
        for record in swaps:
            if self._path_present(record.target):
                os.replace(record.target, record.previous)
                record.target_moved = True
            if record.has_staged:
                if not self._path_present(record.staged):
                    raise ManagementError(
                        78,
                        "ROLLBACK_INTEGRITY_FAILED",
                        f"A staged rollback target disappeared: {record.target}",
                    )
                os.replace(record.staged, record.target)
                record.staged_moved = True

    def _reverse_rollback_swaps(self, swaps: list[_PathSwap]) -> list[str]:
        failures: list[str] = []
        for record in reversed(swaps):
            try:
                if record.staged_moved and self._path_present(record.target):
                    os.replace(record.target, record.staged)
                if record.target_moved:
                    if not self._path_present(record.previous):
                        raise OSError(f"missing prior rollback target: {record.previous}")
                    os.replace(record.previous, record.target)
            except Exception:
                failures.extend(
                    [str(record.target), str(record.staged), str(record.previous)]
                )
        return sorted(set(failures))

    def _cleanup_rollback_artifacts(self, paths: list[Path]) -> list[str]:
        failures: list[str] = []
        for path in dict.fromkeys(paths):
            try:
                if not self._path_present(path):
                    continue
                metadata = path.lstat()
                if stat.S_ISDIR(metadata.st_mode):
                    shutil.rmtree(path)
                elif stat.S_ISREG(metadata.st_mode):
                    path.unlink()
                else:
                    raise OSError(f"unsafe rollback artifact: {path}")
            except Exception:
                failures.append(str(path))
        return failures

    def _complete_rollback(
        self,
        service_state: dict[str, Any],
        *,
        allow_degraded: bool,
    ) -> None:
        try:
            try:
                restored_manager = Manager(source_root=self.paths.product_root)
            except Exception as exc:
                raise ManagementError(
                    1,
                    "ROLLBACK_HEALTH_FAILED",
                    "Restored Beep management source is unavailable.",
                ) from exc
            failed = [
                check
                for check in restored_manager.checks()
                if check["status"] == "fail" and check["id"] != "service_state"
            ]
            if failed:
                raise ManagementError(
                    1,
                    "ROLLBACK_HEALTH_FAILED",
                    "Restored Beep failed integrity checks.",
                )
            self._restore_service_state(service_state)
        except Exception:
            self._stop_services()
            if not allow_degraded:
                raise
            self._last_rollback_degraded = True

    def _prepare_recovery_root(self, *, create: bool) -> None:
        self._assert_tree_safe(self.paths.state_root)
        self._validate_state_control_root(allow_legacy=False)
        if not self._path_present(self.paths.rollback_root):
            if not create:
                raise ManagementError(
                    66, "ROLLBACK_UNAVAILABLE", "No rollback snapshot exists."
                )
            self.paths.rollback_root.mkdir(mode=0o700)
            os.chmod(self.paths.rollback_root, 0o700)
            if os.geteuid() == 0:
                os.chown(self.paths.rollback_root, 0, 0)
        self._assert_no_symlink_ancestors(self.paths.rollback_root)
        metadata = self.paths.rollback_root.lstat()
        expected_uid, expected_gid = self._expected_node_owner()
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise ManagementError(
                73,
                "UNSAFE_RECOVERY_ROOT",
                "The Beep recovery root is unsafe.",
            )

    def _validate_state_control_root(self, *, allow_legacy: bool) -> None:
        try:
            metadata = self.paths.state_root.lstat()
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_STATE_ROOT",
                "The Beep lifecycle state root is unsafe.",
            ) from exc
        expected_uid, expected_gid = self._expected_node_owner()
        identity = (
            metadata.st_uid,
            metadata.st_gid,
            stat.S_IMODE(metadata.st_mode),
        )
        accepted = {(expected_uid, expected_gid, 0o755)}
        if allow_legacy:
            try:
                user = pwd.getpwnam(DEFAULT_USER)
                group = grp.getgrnam(DEFAULT_USER)
            except KeyError:
                pass
            else:
                accepted.add((user.pw_uid, group.gr_gid, 0o750))
        if not stat.S_ISDIR(metadata.st_mode) or identity not in accepted:
            raise ManagementError(
                73,
                "UNSAFE_STATE_ROOT",
                "The Beep lifecycle state root is unsafe.",
            )
        self._assert_no_symlink_ancestors(self.paths.state_root)

    def _secure_state_control_root(self, changed: list[str]) -> None:
        self._validate_state_control_root(allow_legacy=True)
        expected_uid, expected_gid = self._expected_node_owner()
        metadata = self.paths.state_root.lstat()
        if (
            metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o755
        ):
            os.chmod(self.paths.state_root, 0o755)
            if os.geteuid() == 0:
                os.chown(self.paths.state_root, expected_uid, expected_gid)
            changed.append(str(self.paths.state_root))
        self._validate_state_control_root(allow_legacy=False)

    def _host_resources(self) -> tuple[Path, ...]:
        return (
            self.paths.chat_unit,
            self.paths.health_unit,
            self.paths.health_timer,
            self.paths.logrotate,
            self.paths.sudoers,
            self.paths.entrypoint,
            *(self.paths.command_root / name for name in HOST_COMMANDS),
        )

    @staticmethod
    def _ownership_map(
        root: Path,
        prefix: str,
        *,
        excluded: set[Path],
    ) -> dict[str, list[int]]:
        result: dict[str, list[int]] = {}
        for path in (root, *sorted(root.rglob("*"))):
            if any(path == item or item in path.parents for item in excluded):
                continue
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Symlink rejected: {path}")
            relative = PurePosixPath(".") if path == root else PurePosixPath(
                *path.relative_to(root).parts
            )
            key = str(PurePosixPath(prefix) / relative)
            metadata = path.stat(follow_symlinks=False)
            result[key] = [metadata.st_uid, metadata.st_gid]
        return result

    @staticmethod
    def _validate_snapshot_ownership(value: dict[str, Any], snapshot: Path) -> None:
        if not value:
            raise ManagementError(65, "ROLLBACK_INVALID", "Ownership map is missing.")
        expected_names: set[str] = set()
        for prefix in ("opt", "home", "etc", "state"):
            root = snapshot / prefix
            if not root.is_dir() or root.is_symlink():
                continue
            for path in (root, *sorted(root.rglob("*"))):
                relative = (
                    PurePosixPath(".")
                    if path == root
                    else PurePosixPath(*path.relative_to(root).parts)
                )
                expected_names.add(str(PurePosixPath(prefix) / relative))
        host_root = snapshot / "host"
        if host_root.is_dir() and not host_root.is_symlink():
            expected_names.update(
                str(PurePosixPath("host") / PurePosixPath(*path.relative_to(host_root).parts))
                for path in host_root.rglob("*")
                if path.is_file() and not path.is_symlink()
            )
        if set(value) != expected_names:
            raise ManagementError(
                65,
                "ROLLBACK_INVALID",
                "Ownership map does not cover the complete snapshot.",
            )
        for name, ownership in value.items():
            path = PurePosixPath(name) if isinstance(name, str) else PurePosixPath("/")
            if (
                not isinstance(name, str)
                or path.is_absolute()
                or ".." in path.parts
                or not path.parts
                or path.parts[0] not in {"opt", "home", "etc", "state", "host"}
                or not isinstance(ownership, list)
                or len(ownership) != 2
                or any(
                    isinstance(item, bool) or not isinstance(item, int) or item < 0
                    for item in ownership
                )
            ):
                raise ManagementError(
                    65, "ROLLBACK_INVALID", "Ownership map is invalid."
                )
            source = snapshot.joinpath(*path.parts)
            if not source.exists() or source.is_symlink():
                raise ManagementError(
                    65, "ROLLBACK_INVALID", "Ownership map references a missing path."
                )

    def _restore_snapshot_ownership(self, value: dict[str, list[int]]) -> None:
        roots = {
            "opt": self.paths.install_root,
            "home": self.paths.account_home,
            "etc": self.paths.configuration_root,
            "state": self.paths.state_root,
        }
        for name, ownership in value.items():
            path = PurePosixPath(name)
            if path.parts[0] == "host":
                target = Path("/").joinpath(*path.parts[1:])
            else:
                target = roots[path.parts[0]].joinpath(*path.parts[1:])
            if not target.exists() or target.is_symlink():
                raise ManagementError(
                    78, "ROLLBACK_INTEGRITY_FAILED", "Restored ownership target is missing."
                )
            os.chown(target, ownership[0], ownership[1])

    @staticmethod
    def _tree_digest(root: Path) -> str:
        if not root.is_dir() or root.is_symlink():
            raise ManagementError(65, "SNAPSHOT_INVALID", f"Missing snapshot tree: {root}")
        digest = hashlib.sha256()
        for path in (root, *sorted(root.rglob("*"))):
            if path.is_symlink():
                raise ManagementError(73, "UNSAFE_PATH", f"Symlink rejected: {path}")
            relative = "." if path == root else str(path.relative_to(root))
            metadata = path.stat(follow_symlinks=False)
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode())
            digest.update(b"\0")
            if path.is_file():
                with path.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(block)
            elif not path.is_dir():
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Unsupported snapshot entry: {path}"
                )
            digest.update(b"\0")
        return sha256_bytes(digest.digest())

    def _execute_suspend(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        changed_resources: list[str] = []
        self._secure_state_control_root(changed_resources)
        prior_service_state = self._capture_service_state()
        value = {
            "schema_version": 1,
            "product_id": PRODUCT_ID,
            "suspended_at": utc_now(),
        }
        try:
            self._stop_services()
            changed = atomic_write(
                self.paths.suspended, canonical_json(value) + b"\n", mode=0o600
            )
        except Exception:
            try:
                self._restore_service_state(prior_service_state)
            except Exception as restore_exc:
                raise ManagementError(
                    1,
                    "SERVICE_RESTORE_FAILED",
                    "Suspend failed and Beep's prior service state could not be restored.",
                    recovery=["Keep Beep stopped and inspect the system journal."],
                ) from restore_exc
            raise
        if changed:
            changed_resources.append(str(self.paths.suspended))
        return sorted(set(changed_resources)), str(marker["version"])

    def _execute_resume(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        changed: list[str] = []
        self._secure_state_control_root(changed)
        if self._lifecycle_status()["dead"]:
            raise ManagementError(
                78,
                "RESUME_BLOCKED",
                "A dead Beep cannot be resumed or revived.",
            )
        failed = [check for check in self.checks() if check["status"] == "fail" and check["id"] != "service_state"]
        if failed:
            raise ManagementError(
                78, "RESUME_BLOCKED", "Beep integrity checks failed before resume."
            )
        prior_service_state = self._capture_service_state()
        suspended_present = self._path_present(self.paths.suspended)
        if suspended_present:
            suspended_metadata = self.paths.suspended.lstat()
            if not stat.S_ISREG(suspended_metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Suspension marker is unsafe: {self.paths.suspended}",
                )
        try:
            self._start_services(changed, suspended=False)
            if suspended_present:
                self.paths.suspended.unlink()
                changed.append(str(self.paths.suspended))
        except Exception:
            try:
                self._restore_service_state(prior_service_state)
            except Exception as restore_exc:
                try:
                    self._stop_services()
                except Exception:
                    pass
                raise ManagementError(
                    1,
                    "SERVICE_RESTORE_FAILED",
                    "Resume failed and Beep's prior service state could not be restored.",
                    recovery=["Keep Beep stopped and inspect the system journal."],
                ) from restore_exc
            raise
        return sorted(set(changed)), str(marker["version"])

    def _execute_kill(self) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=True)
        changed: list[str] = []
        self._secure_state_control_root(changed)
        self._stop_services()
        lifecycle_path = self.paths.runtime / "lifecycle.json"
        if lifecycle_path.is_symlink() or (
            lifecycle_path.exists() and not lifecycle_path.is_file()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Refusing unsafe lifecycle path: {lifecycle_path}"
            )
        before = lifecycle_path.read_bytes() if lifecycle_path.is_file() else None
        with self._lifecycle_environment():
            runtime_lifecycle.kill("operator_killed")
        try:
            account = pwd.getpwnam(DEFAULT_USER)
        except KeyError as exc:
            raise ManagementError(
                1,
                "IDENTITY_MISSING",
                "The death tombstone was written, but the Beep account is missing.",
            ) from exc
        os.chmod(lifecycle_path, 0o600)
        os.chown(lifecycle_path, account.pw_uid, account.pw_gid)
        if before != lifecycle_path.read_bytes():
            changed.append(str(lifecycle_path))

        history_path = self.paths.runtime / "conversations.db"
        if history_path.is_symlink() or (
            history_path.exists() and not history_path.is_file()
        ):
            raise ManagementError(
                73, "UNSAFE_PATH", f"Refusing unsafe history path: {history_path}"
            )
        if history_path.is_file():
            try:
                history = runtime_history.History(history_path)
                try:
                    cancelled = history.cancel_pending_reactivation("beep killed")
                finally:
                    history.close()
            except (OSError, sqlite3.Error) as exc:
                raise ManagementError(
                    1,
                    "REACTIVATION_CANCEL_FAILED",
                    "The death tombstone was written, but pending reactivation cancellation failed.",
                ) from exc
            if cancelled is not None:
                changed.append(str(history_path))
        return sorted(set(changed)), str(marker["version"])

    def _execute_uninstall(
        self, invocation: Invocation
    ) -> tuple[list[str], str | None]:
        marker = self.load_marker(required=False)
        purge_state = self._load_purge_state()
        if purge_state is not None and invocation.retain_state is not False:
            raise ManagementError(
                73,
                "PURGE_IN_PROGRESS",
                "An interrupted Beep purge can only be resumed as a complete purge.",
            )
        if marker is None:
            if purge_state is None:
                raise ManagementError(
                    66, "NOT_INSTALLED", "Beep is not installed on this host."
                )
            marker = {
                "instance_id": purge_state["instance_id"],
                "version": purge_state["version"],
            }
        elif purge_state is not None and (
            marker["instance_id"] != purge_state["instance_id"]
            or marker["version"] != purge_state["version"]
        ):
            raise ManagementError(
                73,
                "PURGE_IDENTITY_CHANGED",
                "The installed marker does not match the interrupted purge.",
            )
        if invocation.retain_state is False and invocation.confirmation != DELETE_CONFIRMATION:
            raise ManagementError(
                64,
                "DESTRUCTIVE_CONFIRMATION_REQUIRED",
                f"Complete removal requires confirmation: {DELETE_CONFIRMATION}",
            )
        resuming_purge = purge_state is not None
        identity = self._preflight_uninstall(invocation, purge_state=purge_state)
        changed: list[str] = []
        if invocation.retain_state is False and purge_state is None:
            if self._write_purge_state(marker, identity):
                changed.append(str(self.paths.purge_state))
        if resuming_purge:
            self._ensure_purge_evidence_roots(changed)
        if self._path_present(self.paths.state_root):
            self._secure_state_control_root(changed)
        if resuming_purge:
            self._stop_markerless_services()
        else:
            self._stop_services()
        if self._path_present(self.paths.account_home):
            self._materialize_python_environment_links(changed)
        if self._path_present(self.paths.node_root):
            self._materialize_node_links(changed)
        for path in self._host_resources():
            if not self._path_present(path):
                continue
            self._assert_no_symlink_ancestors(path.parent)
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Host resource is unsafe: {path}",
                )
            path.unlink()
            changed.append(str(path))
        if self._path_present(self.paths.install_root):
            self._assert_tree_safe(self.paths.install_root)
            shutil.rmtree(self.paths.install_root)
            changed.append(str(self.paths.install_root))
        if self._path_present(self.paths.pending_install):
            self.paths.pending_install.unlink()
            changed.append(str(self.paths.pending_install))
        if invocation.retain_state:
            retained = {
                "schema_version": 1,
                "product_id": PRODUCT_ID,
                "instance_id": marker["instance_id"],
            }
            if atomic_write(
                self.paths.retained, canonical_json(retained) + b"\n", mode=0o600
            ):
                changed.append(str(self.paths.retained))
            if self._path_present(self.paths.marker):
                self.paths.marker.unlink()
                changed.append(str(self.paths.marker))
        if shutil.which("systemctl"):
            self._run(["systemctl", "daemon-reload"], check=False)
        return sorted(set(changed)), str(marker["version"])

    def _preflight_uninstall(
        self,
        invocation: Invocation,
        *,
        purge_state: dict[str, Any] | None = None,
    ) -> dict[str, int | None]:
        expected_uid, expected_gid = self._expected_node_owner()
        if purge_state is None:
            self._validate_receipt_roots()
            self._validate_receipt_destinations(invocation.correlation_id)
            self._validate_audit_target()
        else:
            self._validate_purge_resume_evidence(invocation.correlation_id)
        if invocation.retain_state is False:
            self._validate_purge_journal()
        for path in self._host_resources():
            if not self._path_present(path):
                continue
            metadata = path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or stat.S_IMODE(metadata.st_mode) & 0o022
            ):
                raise ManagementError(
                    73, "UNSAFE_PATH", f"Host resource is unsafe: {path}"
                )
        if self._path_present(self.paths.install_root):
            self._assert_install_tree_migratable()
        if self._path_present(self.paths.pending_install):
            self._assert_no_symlink_ancestors(self.paths.pending_install)
            metadata = self.paths.pending_install.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise ManagementError(
                    73, "UNSAFE_PATH", "Pending Beep install state is unsafe."
                )
        for path in (
            self.paths.account_home,
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        ):
            if self._path_present(path):
                if path == self.paths.account_home:
                    self._assert_account_home_migratable()
                else:
                    self._assert_tree_safe(path)
        identity = self._validate_purge_identity(purge_state)
        user_present = identity["user_uid"] is not None
        group_present = identity["group_gid"] is not None
        if invocation.retain_state and not (user_present and group_present):
            raise ManagementError(
                73,
                "IDENTITY_COLLISION",
                "Retaining Beep state requires the managed identity.",
            )
        if invocation.retain_state and self._path_present(self.paths.retained):
            metadata = self.paths.retained.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise ManagementError(
                    73, "UNSAFE_PATH", "Retained Beep state is unsafe."
                )
        return identity

    def _validate_purge_identity(
        self,
        purge_state: dict[str, Any] | None,
    ) -> dict[str, int | None]:
        try:
            user = pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            user = None
        try:
            group = grp.getgrnam(DEFAULT_USER)
        except KeyError:
            group = None
        if purge_state is None:
            if (user is None) != (group is None):
                raise ManagementError(
                    73,
                    "IDENTITY_COLLISION",
                    "The existing beep identity is incomplete and cannot be proven safe.",
                )
            if user is None:
                return {"user_uid": None, "user_gid": None, "group_gid": None}
            if (
                user.pw_gid != group.gr_gid
                or user.pw_dir != str(self.paths.account_home)
                or user.pw_shell != "/bin/bash"
            ):
                raise ManagementError(
                    73,
                    "IDENTITY_COLLISION",
                    "The existing beep identity is not safe to remove.",
                )
            return {
                "user_uid": user.pw_uid,
                "user_gid": user.pw_gid,
                "group_gid": group.gr_gid,
            }

        expected = purge_state["identity"]
        if expected["user_uid"] is None:
            if user is not None or group is not None:
                raise ManagementError(
                    73,
                    "IDENTITY_COLLISION",
                    "A new beep identity appeared after purge began.",
                )
            return dict(expected)
        if user is not None and (
            user.pw_uid != expected["user_uid"]
            or user.pw_gid != expected["user_gid"]
            or user.pw_dir != str(self.paths.account_home)
            or user.pw_shell != "/bin/bash"
        ):
            raise ManagementError(
                73,
                "IDENTITY_COLLISION",
                "The beep account changed after purge began.",
            )
        if group is not None and group.gr_gid != expected["group_gid"]:
            raise ManagementError(
                73,
                "IDENTITY_COLLISION",
                "The beep group changed after purge began.",
            )
        return dict(expected)

    def _validate_purge_resume_evidence(self, correlation_id: str) -> None:
        if not self._path_present(self.paths.log_root):
            return
        expected_uid, expected_gid = self._expected_node_owner()
        metadata = self.paths.log_root.lstat()
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != expected_uid
            or metadata.st_gid != expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o755
        ):
            raise ManagementError(
                73,
                "UNSAFE_RECEIPT_PATH",
                "Interrupted purge evidence directory is unsafe.",
            )
        self._assert_no_symlink_ancestors(self.paths.log_root)
        self._assert_tree_safe(self.paths.log_root)
        if self._path_present(self.paths.receipts):
            receipt_metadata = self.paths.receipts.lstat()
            if (
                not stat.S_ISDIR(receipt_metadata.st_mode)
                or receipt_metadata.st_uid != expected_uid
                or receipt_metadata.st_gid != expected_gid
                or stat.S_IMODE(receipt_metadata.st_mode) != 0o750
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_RECEIPT_PATH",
                    "Interrupted purge receipt directory is unsafe.",
                )
            self._validate_receipt_destinations(correlation_id)
        self._validate_audit_target()

    def _ensure_purge_evidence_roots(self, changed: list[str]) -> None:
        expected_uid, expected_gid = self._expected_node_owner()
        self._assert_no_symlink_ancestors(self.paths.log_root.parent)
        for path, mode in (
            (self.paths.log_root, 0o755),
            (self.paths.receipts, 0o750),
        ):
            if not self._path_present(path):
                path.mkdir(mode=mode)
                changed.append(str(path))
            os.chmod(path, mode)
            if os.geteuid() == 0:
                os.chown(path, expected_uid, expected_gid)
        self._validate_receipt_roots()

    def _assert_install_tree_migratable(self) -> None:
        root = self.paths.install_root
        node_present = self._path_present(self.paths.node_root)
        if node_present:
            self._node_link_replacements()
        try:
            root_metadata = root.lstat()
            entries = root.rglob("*")
            if not stat.S_ISDIR(root_metadata.st_mode):
                raise OSError("install root is not a directory")
            for path in entries:
                if node_present and (
                    path == self.paths.node_root
                    or self.paths.node_root in path.parents
                ):
                    continue
                metadata = path.lstat()
                if not (
                    stat.S_ISDIR(metadata.st_mode)
                    or stat.S_ISREG(metadata.st_mode)
                ):
                    raise OSError(f"unsafe install path: {path}")
        except OSError as exc:
            raise ManagementError(
                73, "UNSAFE_PATH", f"Unsafe product tree: {root}"
            ) from exc

    def _assert_account_home_migratable(self) -> None:
        root = self.paths.account_home
        try:
            root_metadata = root.lstat()
            if not stat.S_ISDIR(root_metadata.st_mode):
                raise OSError("account home is not a directory")
            for path in root.rglob("*"):
                metadata = path.lstat()
                if stat.S_ISLNK(metadata.st_mode):
                    if self._standard_python_lib64_link(path):
                        continue
                    raise OSError(f"unsafe account-home link: {path}")
                if not (
                    stat.S_ISDIR(metadata.st_mode)
                    or stat.S_ISREG(metadata.st_mode)
                ):
                    raise OSError(f"unsafe account-home path: {path}")
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Unsafe managed account home: {root}",
            ) from exc

    @staticmethod
    def _journal_purge_evidence(
        invocation: Invocation,
        result: Result,
        *,
        event_id: str,
        receipt_digest: str,
        phase: str,
        changed_resources: list[str],
    ) -> None:
        if phase not in {"purge_started", "purge_completed"}:
            raise ManagementError(65, "INVALID_PURGE_PHASE", "Purge phase is invalid.")
        Manager._validate_purge_journal()
        systemd_cat = Path("/usr/bin/systemd-cat")
        evidence = {
            "timestamp": utc_now(),
            "event_id": event_id,
            "correlation_id": invocation.correlation_id,
            "product_id": PRODUCT_ID,
            "instance_id": result.instance_id,
            "operation": "uninstall",
            "phase": phase,
            "actor": invocation.actor,
            "result": result.status,
            "changed": bool(changed_resources),
            "changed_resources": sorted(set(changed_resources)),
            "receipt_digest": receipt_digest,
            "purge": True,
        }
        completed = subprocess.run(
            [str(systemd_cat), "--identifier=beep-manage", "--priority=notice"],
            check=False,
            input=(canonical_json(evidence) + b"\n"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if completed.returncode != 0:
            raise ManagementError(
                1,
                "JOURNAL_WRITE_FAILED",
                "Final Beep purge evidence could not be written to the journal.",
            )

    def _finalize_purge(self) -> list[str]:
        purge_state = self._load_purge_state()
        if purge_state is None:
            raise ManagementError(
                73,
                "PURGE_STATE_MISSING",
                "Protected purge state disappeared before removal completed.",
            )
        self._validate_purge_identity(purge_state)
        changed: list[str] = []
        home_present = self._path_present(self.paths.account_home)
        if home_present:
            self._assert_tree_safe(self.paths.account_home)
        pending_present = self._path_present(self.paths.pending_install)
        if pending_present:
            metadata = self.paths.pending_install.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    "Pending Beep install state is unsafe.",
                )
        purge_roots = (
            self.paths.configuration_root,
            self.paths.state_root,
            self.paths.log_root,
        )
        present_roots = [path for path in purge_roots if self._path_present(path)]
        for path in present_roots:
            self._assert_tree_safe(path)
        try:
            pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            user_present = False
        else:
            user_present = True
        try:
            grp.getgrnam(DEFAULT_USER)
        except KeyError:
            group_present = False
        else:
            group_present = True
        if user_present:
            self._run(["userdel", "--remove", DEFAULT_USER], check=False)
        try:
            pwd.getpwnam(DEFAULT_USER)
        except KeyError:
            pass
        else:
            raise ManagementError(
                1,
                "IDENTITY_REMOVE_FAILED",
                "The Beep account could not be removed.",
            )

        if user_present:
            changed.append("user:beep")
        try:
            grp.getgrnam(DEFAULT_USER)
        except KeyError:
            group_still_present = False
        else:
            group_still_present = True
        if group_still_present:
            self._run(["groupdel", DEFAULT_USER], check=False)
        try:
            grp.getgrnam(DEFAULT_USER)
        except KeyError:
            pass
        else:
            raise ManagementError(
                1,
                "IDENTITY_REMOVE_FAILED",
                "The Beep group could not be removed.",
            )
        if group_present:
            changed.append("group:beep")
        if pending_present:
            self.paths.pending_install.unlink()
            changed.append(str(self.paths.pending_install))
        if home_present and self._path_present(self.paths.account_home):
            self._assert_tree_safe(self.paths.account_home)
            shutil.rmtree(self.paths.account_home)
        if home_present:
            changed.append(str(self.paths.account_home))
        for path in present_roots:
            if self._path_present(path):
                shutil.rmtree(path)
            changed.append(str(path))
        return sorted(set(changed))

    @staticmethod
    def _validate_purge_journal() -> None:
        systemd_cat = Path("/usr/bin/systemd-cat")
        try:
            metadata = systemd_cat.lstat()
        except OSError as exc:
            raise ManagementError(
                69,
                "JOURNAL_UNAVAILABLE",
                "Cannot purge Beep without recording final journal evidence.",
            ) from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or stat.S_IMODE(metadata.st_mode) & 0o022
            or not os.access(systemd_cat, os.X_OK)
        ):
            raise ManagementError(
                69,
                "JOURNAL_UNAVAILABLE",
                "Cannot purge Beep without recording final journal evidence.",
            )

    def _stop_services(self) -> None:
        if not shutil.which("systemctl"):
            return
        failed: list[str] = []
        for unit in ("beep-health.timer", "beep-chat.service"):
            self._run(["systemctl", "disable", "--now", unit], check=False)
            if self._service_active(unit) or self._service_enabled(unit):
                failed.append(unit)
        self._run(["systemctl", "stop", "beep-health.service"], check=False)
        if self._service_active("beep-health.service"):
            failed.append("beep-health.service")
        if failed:
            raise ManagementError(
                1,
                "SERVICE_STOP_FAILED",
                "Beep units remained active or enabled: " + ", ".join(failed),
            )

    def _stop_markerless_services(self) -> None:
        """Stop only unit names backed by a present, provenance-checked asset."""
        if not shutil.which("systemctl"):
            return
        failed: list[str] = []
        for path, unit in (
            (self.paths.health_timer, "beep-health.timer"),
            (self.paths.chat_unit, "beep-chat.service"),
        ):
            if not self._path_present(path):
                continue
            self._run(["systemctl", "disable", "--now", unit], check=False)
            if self._service_active(unit) or self._service_enabled(unit):
                failed.append(unit)
        if self._path_present(self.paths.health_unit):
            self._run(
                ["systemctl", "stop", "beep-health.service"],
                check=False,
            )
            if self._service_active("beep-health.service"):
                failed.append("beep-health.service")
        if failed:
            raise ManagementError(
                1,
                "SERVICE_STOP_FAILED",
                "Beep units remained active or enabled: " + ", ".join(failed),
            )

    def _capture_service_state(self) -> dict[str, Any]:
        available = shutil.which("systemctl") is not None
        units = {
            unit: {
                "active": self._service_active(unit) if available else False,
                "enabled": self._service_enabled(unit) if available else False,
            }
            for unit in ("beep-chat.service", "beep-health.timer")
        }
        return {
            "schema_version": 1,
            "systemctl": available,
            "units": units,
        }

    @staticmethod
    def _service_snapshot_valid(value: Any) -> bool:
        if not isinstance(value, dict) or set(value) != {
            "schema_version",
            "systemctl",
            "units",
        }:
            return False
        if value["schema_version"] != 1 or not isinstance(value["systemctl"], bool):
            return False
        units = value["units"]
        if not isinstance(units, dict) or set(units) != {
            "beep-chat.service",
            "beep-health.timer",
        }:
            return False
        return all(
            isinstance(state, dict)
            and set(state) == {"active", "enabled"}
            and all(isinstance(flag, bool) for flag in state.values())
            for state in units.values()
        ) and (
            value["systemctl"]
            or not any(flag for state in units.values() for flag in state.values())
        )

    @classmethod
    def _validate_service_snapshot(cls, value: Any) -> None:
        if not cls._service_snapshot_valid(value):
            raise ManagementError(
                65,
                "ROLLBACK_INVALID",
                "Recovery service state is invalid.",
            )

    def _restore_service_state(self, value: dict[str, Any]) -> None:
        self._validate_service_snapshot(value)
        if not value["systemctl"]:
            return
        if not shutil.which("systemctl"):
            raise ManagementError(
                69,
                "SYSTEMD_MISSING",
                "systemctl is required to restore Beep service state.",
            )
        self._run(["systemctl", "daemon-reload"])
        for unit in ("beep-chat.service", "beep-health.timer"):
            state = value["units"][unit]
            self._run(
                [
                    "systemctl",
                    "enable" if state["enabled"] else "disable",
                    unit,
                ],
                check=False,
            )
            self._run(
                [
                    "systemctl",
                    "start" if state["active"] else "stop",
                    unit,
                ],
                check=False,
            )
            if (
                self._service_active(unit) != state["active"]
                or self._service_enabled(unit) != state["enabled"]
            ):
                raise ManagementError(
                    1,
                    "SERVICE_RESTORE_FAILED",
                    f"Could not restore prior service state for {unit}.",
                )

    @staticmethod
    def _service_active(unit: str) -> bool:
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", unit],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0

    @staticmethod
    def _service_enabled(unit: str) -> bool:
        return subprocess.run(
            ["systemctl", "is-enabled", "--quiet", unit],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0

    def _source_revision(self) -> str:
        digest = hashlib.sha256()
        for path in sorted(self.source_root.rglob("*")):
            relative = path.relative_to(self.source_root)
            if (
                "dist" in relative.parts
                or "__pycache__" in relative.parts
                or path.suffix == ".pyc"
            ):
                continue
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    78,
                    "UNSAFE_SOURCE",
                    f"The Beep source changed while hashing: {path}",
                ) from exc
            if stat.S_ISDIR(metadata.st_mode):
                kind = b"directory"
            elif stat.S_ISREG(metadata.st_mode):
                kind = b"file"
            else:
                raise ManagementError(
                    78,
                    "UNSAFE_SOURCE",
                    f"The Beep source contains an unsafe path: {path}",
                )
            digest.update(str(relative).encode())
            digest.update(b"\0")
            digest.update(kind)
            digest.update(b"\0")
            digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode())
            digest.update(b"\0")
            if kind == b"file":
                try:
                    digest.update(path.read_bytes())
                except OSError as exc:
                    raise ManagementError(
                        78,
                        "UNSAFE_SOURCE",
                        f"The Beep source changed while hashing: {path}",
                    ) from exc
            digest.update(b"\0")
        return f"source:{digest.hexdigest()}"

    @contextmanager
    def _trusted_source_snapshot(self, expected_revision: str) -> Iterator[None]:
        """Pin every deployment read to one root-owned, reviewed source tree."""
        original = self.source_root
        try:
            with tempfile.TemporaryDirectory(prefix="beep-source-") as directory:
                snapshot = Path(directory) / "product"
                try:
                    shutil.copytree(
                        original,
                        snapshot,
                        symlinks=True,
                        ignore=shutil.ignore_patterns(
                            "dist", "__pycache__", "*.pyc"
                        ),
                    )
                    self.source_root = snapshot
                    snapshot_descriptor = load_json(snapshot / "PRODUCT.json")
                    snapshot_version = (
                        (snapshot / "VERSION").read_text(encoding="utf-8").strip()
                    )
                    self._validate_source()
                    if (
                        snapshot_descriptor != self.descriptor
                        or snapshot_version != self.version
                        or self._source_revision() != expected_revision
                    ):
                        raise ManagementError(
                            78,
                            "PLAN_CHANGED",
                            "Beep source changed while creating its trusted snapshot.",
                        )
                except ManagementError:
                    raise
                except (OSError, shutil.Error, UnicodeError) as exc:
                    raise ManagementError(
                        78,
                        "PLAN_CHANGED",
                        "Beep source changed while creating its trusted snapshot.",
                    ) from exc
                yield
        finally:
            self.source_root = original

    @staticmethod
    def _assert_tree_safe(root: Path) -> None:
        try:
            root_metadata = root.lstat()
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_PATH",
                f"Unsafe product tree: {root}",
            ) from exc
        if not stat.S_ISDIR(root_metadata.st_mode):
            raise ManagementError(73, "UNSAFE_PATH", f"Unsafe product tree: {root}")
        for path in root.rglob("*"):
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Unsafe product path: {path}",
                ) from exc
            if not (
                stat.S_ISDIR(metadata.st_mode)
                or stat.S_ISREG(metadata.st_mode)
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_PATH",
                    f"Unsupported product path: {path}",
                )

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
        self._validate_receipt_roots()
        receipt = {
            "schema_version": 1,
            "response": result.object(),
            "installed_version": (
                marker["version"]
                if result.operation != "uninstall"
                and (marker := self.load_marker(required=False)) is not None
                else None
            ),
            "previous_version": previous_version,
            "changed_resources": sorted(set(changed_resources)),
            "audit_event_id": event_id,
        }
        content = canonical_json(receipt) + b"\n"
        historical = self.paths.receipts / f"{result.correlation_id}.json"
        self._validate_receipt_destinations(result.correlation_id)
        atomic_write(historical, content, mode=0o640)
        atomic_write(self.paths.receipt, content, mode=0o640)
        return {"path": str(self.paths.receipt), "digest": sha256_bytes(content)}

    def _validate_receipt_roots(self) -> None:
        expected_uid, expected_gid = self._expected_node_owner()
        for path, mode in (
            (self.paths.log_root, 0o755),
            (self.paths.receipts, 0o750),
        ):
            try:
                metadata = path.lstat()
            except OSError as exc:
                raise ManagementError(
                    73,
                    "UNSAFE_RECEIPT_PATH",
                    f"Management receipt directory is unsafe: {path}",
                ) from exc
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or stat.S_IMODE(metadata.st_mode) != mode
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_RECEIPT_PATH",
                    f"Management receipt directory is unsafe: {path}",
                )
        self._assert_no_symlink_ancestors(self.paths.receipts)
        self._assert_tree_safe(self.paths.receipts)

    def _validate_receipt_destinations(self, correlation_id: str) -> None:
        expected_uid, expected_gid = self._expected_node_owner()
        for path in (
            self.paths.receipt,
            self.paths.receipts / f"{correlation_id}.json",
        ):
            if not self._path_present(path):
                continue
            metadata = path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != expected_uid
                or metadata.st_gid != expected_gid
                or stat.S_IMODE(metadata.st_mode) != 0o640
            ):
                raise ManagementError(
                    73,
                    "UNSAFE_RECEIPT_PATH",
                    f"Management receipt path is unsafe: {path}",
                )

    def _validate_audit_target(self) -> None:
        expected_uid, expected_gid = self._expected_node_owner()
        try:
            root_metadata = self.paths.log_root.lstat()
        except OSError as exc:
            raise ManagementError(
                73,
                "UNSAFE_AUDIT_PATH",
                f"Management audit directory is unsafe: {self.paths.log_root}",
            ) from exc
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != expected_uid
            or root_metadata.st_gid != expected_gid
            or stat.S_IMODE(root_metadata.st_mode) != 0o755
        ):
            raise ManagementError(
                73,
                "UNSAFE_AUDIT_PATH",
                f"Management audit directory is unsafe: {self.paths.log_root}",
            )
        self._assert_no_symlink_ancestors(self.paths.log_root)
        if not self._path_present(self.paths.audit):
            return
        metadata = self.paths.audit.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o640
        ):
            raise ManagementError(
                73,
                "UNSAFE_AUDIT_PATH",
                f"Management audit file is unsafe: {self.paths.audit}",
            )

    def _append_audit(
        self,
        invocation: Invocation,
        result: Result,
        *,
        event_id: str,
        receipt_digest: str | None,
    ) -> None:
        self._validate_audit_target()
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
        descriptor = os.open(
            self.paths.audit,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW,
            0o640,
        )
        try:
            try:
                account = pwd.getpwnam(DEFAULT_USER)
                group = grp.getgrnam(DEFAULT_USER)
            except KeyError:
                pass
            else:
                os.fchown(descriptor, account.pw_uid, group.gr_gid)
            os.fchmod(descriptor, 0o640)
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
    value = argparse.ArgumentParser(
        prog="beep-manage",
        description="Install and manage the private Beep Systems Administrator.",
    )
    value.add_argument("operation", choices=OPERATIONS, help="lifecycle operation")
    value.add_argument(
        "--dry-run",
        action="store_true",
        help="render a plan without making changes",
    )
    value.add_argument(
        "--json",
        action="store_true",
        help="write one machine-readable response object",
    )
    value.add_argument(
        "--non-interactive",
        action="store_true",
        help="never prompt; missing inputs or approval exit 64",
    )
    value.add_argument(
        "--request-file",
        type=Path,
        help="read a root-owned lifecycle request",
    )
    value.add_argument("--correlation-id", help="use the supplied request UUID")
    value.add_argument(
        "--plan-digest",
        help="require the current plan to match this digest",
    )
    value.add_argument(
        "--confirmation",
        help="supply an exact destructive confirmation",
    )
    value.add_argument(
        "--yes",
        action="store_true",
        help="approve a non-destructive plan without prompting",
    )
    value.add_argument(
        "--purge",
        action="store_true",
        help="delete retained state during uninstall",
    )
    return value


def print_plan(
    result: Result,
    *,
    configuration: dict[str, Any] | None,
    file: Any = None,
) -> None:
    def field(label: str, value: Any) -> None:
        print(f"  {label + ':':<18}{value}", file=file)

    print("Beep product lifecycle plan:", file=file)
    field("Operation", result.operation)
    if configuration is not None:
        provider = configuration["provider"] or "not configured"
        model = configuration["model"] or (
            "provider default" if configuration["provider"] else "not configured"
        )
        field(
            "Chat URL",
            f"http://127.0.0.1:{configuration['chat_port']}/",
        )
        field("Service identity", configuration["agent_user"])
        field("Model provider", provider)
        field("Model", model)
        if configuration["model_base_url"] is not None:
            field("Model API", configuration["model_base_url"])
        field("Time to live", f"{configuration['ttl_days']} days")
    field("State", "/var/lib/beep")
    field("Digest", result.plan_digest)
    for index, step in enumerate(result.steps, 1):
        print(f"  {index}. {step['summary']}", file=file)
    if result.operation == "install":
        print(
            "  The chat password and any provider credential are entered "
            "securely and never printed.",
            file=file,
        )


def print_result(result: Result, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result.object(), ensure_ascii=False, sort_keys=True))
        return
    if result.phase == "plan":
        configuration = None
        if result.details is not None:
            candidate = result.details.get("configuration")
            if isinstance(candidate, dict):
                configuration = candidate
        print_plan(result, configuration=configuration)
        for error in result.errors:
            print(f"  error {error['code']}: {error['message']}", file=sys.stderr)
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
