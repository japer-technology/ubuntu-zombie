"""Provider abstraction — thin adapter over ``@earendil-works/pi-ai``.

Every chat completion is forwarded through the shared `pi-ai`_
library that ``pi-mono`` already uses, instead of maintaining bespoke
OpenAI and Anthropic clients in-process.

The Python-facing surface is intentionally narrow so
``payload/agent/server.py`` does not need to know about the bridge:

* ``Message`` — dataclass for chat messages.
* ``ProviderError`` / ``NoProviderConfigured`` — error types.
* ``provider_from_env(name=None, model=None) -> BaseProvider``
* ``provider_status() -> tuple[name, status_text]``
* ``BaseProvider.chat(messages) -> str``

``BaseProvider.chat`` shells out to ``pi-ai-bridge.mjs`` (sibling to
this file). The bridge is a small Node script that loads
``@earendil-works/pi-ai`` and performs a one-shot ``complete()`` call.

Supported providers (set ``ZOMBIE_PROVIDER`` to one of the names on
the left and supply the matching API key in
``/opt/ai-zombie/secrets/env``)::

    openai      OPENAI_API_KEY
    anthropic   ANTHROPIC_API_KEY
    gemini      GEMINI_API_KEY        (pi-ai provider id: google)
    xai         XAI_API_KEY
    openrouter  OPENROUTER_API_KEY    (ZOMBIE_MODEL must be set)
    mistral     MISTRAL_API_KEY
    groq        GROQ_API_KEY

The ``chat`` surface is retained alongside the pi-mono agent loop so
the chat UI keeps a working completion path without maintaining a
second LLM client implementation.

.. _pi-ai: https://github.com/earendil-works/pi
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class ProviderError(RuntimeError):
    """Raised when the provider call itself fails."""


class NoProviderConfigured(ProviderError):
    """Raised when no provider key (or an unknown ``ZOMBIE_PROVIDER``) is set."""


@dataclass
class Message:
    role: str       # "system" | "user" | "assistant"
    content: str


# ---------------------------------------------------------------------------
# Provider registry
# ---------------------------------------------------------------------------

# Operator-visible provider name → (env var holding the API key,
# default model used when ``ZOMBIE_MODEL`` is unset, env var for a
# provider-specific override). The defaults are deliberately
# conservative cheap models so a fresh install can answer "hi" without
# a configuration step beyond pasting a key.
#
# Keep this map in lockstep with ``pi-ai-bridge.mjs``'s ``PROVIDER_MAP``
# and ``KEY_ENV`` so error messages on both sides agree.
@dataclass(frozen=True)
class _ProviderSpec:
    name: str
    key_env: str
    default_model: str
    model_env: str | None = None


_PI_AI_PROVIDERS: tuple[_ProviderSpec, ...] = (
    _ProviderSpec("openai",     "OPENAI_API_KEY",     "gpt-4o-mini",
                  "ZOMBIE_OPENAI_MODEL"),
    _ProviderSpec("anthropic",  "ANTHROPIC_API_KEY",  "claude-3-5-sonnet-latest",
                  "ZOMBIE_ANTHROPIC_MODEL"),
    _ProviderSpec("gemini",     "GEMINI_API_KEY",     "gemini-2.0-flash",
                  "ZOMBIE_GEMINI_MODEL"),
    _ProviderSpec("xai",        "XAI_API_KEY",        "grok-2-1212",
                  "ZOMBIE_XAI_MODEL"),
    _ProviderSpec("mistral",    "MISTRAL_API_KEY",    "mistral-small-latest",
                  "ZOMBIE_MISTRAL_MODEL"),
    _ProviderSpec("groq",       "GROQ_API_KEY",       "llama-3.1-8b-instant",
                  "ZOMBIE_GROQ_MODEL"),
    # OpenRouter has no single sensible default model; the operator
    # must set ``ZOMBIE_MODEL`` (or ``ZOMBIE_OPENROUTER_MODEL``) to a
    # fully-qualified id such as ``anthropic/claude-3.5-sonnet``.
    _ProviderSpec("openrouter", "OPENROUTER_API_KEY", "",
                  "ZOMBIE_OPENROUTER_MODEL"),
)

_PROVIDER_BY_NAME: dict[str, _ProviderSpec] = {
    spec.name: spec for spec in _PI_AI_PROVIDERS
}

SUPPORTED_PROVIDERS: tuple[str, ...] = tuple(spec.name for spec in _PI_AI_PROVIDERS)


# ---------------------------------------------------------------------------
# pi-ai bridge
# ---------------------------------------------------------------------------

HERE = Path(__file__).resolve().parent
DEFAULT_BRIDGE = HERE / "pi-ai-bridge.mjs"


def _bridge_path() -> Path:
    """Return the path to the Node bridge script.

    Overridable via ``ZOMBIE_PI_AI_BRIDGE`` so tests can point at a
    stub. The default sits next to this module both in the source tree
    and after ``scripts/install.sh`` deploys ``payload/agent/`` to
    ``${ZOMBIE_DIR}/agent/``.
    """
    override = os.environ.get("ZOMBIE_PI_AI_BRIDGE")
    if override:
        return Path(override)
    return DEFAULT_BRIDGE


def _node_binary() -> str:
    node = os.environ.get("ZOMBIE_NODE") or shutil.which("node")
    if not node:
        raise ProviderError(
            "node executable not found on PATH. Re-run scripts/install.sh "
            "to install the Node runtime that @earendil-works/pi-ai needs."
        )
    return node


def _bridge_env(spec: _ProviderSpec) -> dict[str, str]:
    """Return the env passed to the Node bridge.

    Only the configured provider's key is forwarded — keys for other
    providers stay in this process so the bridge cannot accidentally
    log them (or send them to an unrelated provider).
    """
    env = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "NODE_PATH": os.environ.get("NODE_PATH", ""),
    }
    # Forward the active provider's key only.
    if spec.key_env in os.environ:
        env[spec.key_env] = os.environ[spec.key_env]
    # pi-ai may need an HTTPS proxy in restricted networks; honour the
    # standard variables if the operator set them.
    for passthrough in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
                        "https_proxy", "http_proxy", "no_proxy"):
        if passthrough in os.environ:
            env[passthrough] = os.environ[passthrough]
    return env


def _call_bridge(spec: _ProviderSpec, model: str,
                 messages: list[Message]) -> str:
    """Invoke the Node bridge and return the assistant text."""
    bridge = _bridge_path()
    if not bridge.exists():
        raise ProviderError(
            f"pi-ai bridge missing at {bridge}. Re-run scripts/install.sh "
            "or set ZOMBIE_PI_AI_BRIDGE."
        )
    node = _node_binary()
    payload = json.dumps({
        "provider": spec.name,
        "model": model,
        "messages": [{"role": m.role, "content": m.content} for m in messages],
    })
    try:
        proc = subprocess.run(
            [node, str(bridge)],
            input=payload,
            env=_bridge_env(spec),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise ProviderError(f"failed to spawn node: {exc}") from exc

    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    if not stdout:
        detail = stderr or f"node exited with code {proc.returncode}"
        raise ProviderError(f"pi-ai bridge produced no output: {detail}")

    # Tolerate extra log lines from pi-ai by parsing only the last JSON
    # line. The bridge always terminates its response with a newline.
    last = stdout.splitlines()[-1]
    try:
        result = json.loads(last)
    except json.JSONDecodeError as exc:
        raise ProviderError(
            f"pi-ai bridge returned non-JSON output: {last!r} ({exc})"
        ) from exc

    if not isinstance(result, dict) or not result.get("ok"):
        msg = (result or {}).get("error", "unknown pi-ai bridge error")
        code = (result or {}).get("code", "")
        if code == "missing_key":
            raise NoProviderConfigured(msg)
        if code == "pi_ai_missing":
            raise ProviderError(msg)
        raise ProviderError(msg)

    text = result.get("text", "")
    return text if isinstance(text, str) else ""


# ---------------------------------------------------------------------------
# Public surface (preserves the pre-Phase-1 API)
# ---------------------------------------------------------------------------

class BaseProvider:
    """Thin wrapper around a single ``pi-ai`` provider."""

    def __init__(self, spec: _ProviderSpec, model: str | None = None) -> None:
        self._spec = spec
        self.name = spec.name
        # Resolution order matches the legacy code:
        # explicit arg > ZOMBIE_MODEL > provider-specific override > default.
        chosen = (
            model
            or os.environ.get("ZOMBIE_MODEL")
            or (os.environ.get(spec.model_env) if spec.model_env else None)
            or spec.default_model
        )
        if not chosen:
            raise NoProviderConfigured(
                f"{spec.name} requires a model id. Set ZOMBIE_MODEL in "
                "/opt/ai-zombie/secrets/env (e.g. "
                "ZOMBIE_MODEL=anthropic/claude-3.5-sonnet for openrouter)."
            )
        self.model = chosen
        if spec.key_env and not os.environ.get(spec.key_env):
            raise NoProviderConfigured(f"{spec.key_env} is not set")

    def chat(self, messages: Iterable[Message]) -> str:
        return _call_bridge(self._spec, self.model, list(messages))


def provider_status() -> tuple[str, str]:
    """Cheap, side-effect-free banner for ``GET /``.

    Returns ``(name, status_text)`` based purely on environment
    variables. Does not spawn the bridge — safe to call on every page
    load.
    """
    explicit = (os.environ.get("ZOMBIE_PROVIDER") or "").strip().lower()
    if explicit:
        spec = _PROVIDER_BY_NAME.get(explicit)
        if spec is None:
            return (explicit, f"unknown provider; supported: "
                              f"{', '.join(SUPPORTED_PROVIDERS)}")
        if os.environ.get(spec.key_env):
            return (spec.name, "configured")
        return (spec.name, f"{spec.key_env} not set")

    for spec in _PI_AI_PROVIDERS:
        if os.environ.get(spec.key_env):
            return (spec.name, "configured")
    return ("none", "no API key found")


def provider_from_env(name: str | None = None,
                      model: str | None = None) -> BaseProvider:
    """Return a configured provider, or raise ``NoProviderConfigured``.

    Selection order:

    1. ``name`` argument, if set.
    2. ``ZOMBIE_PROVIDER`` environment variable.
    3. The first provider in ``_PI_AI_PROVIDERS`` whose key env var is
       present (preserves the legacy "first key wins" autodetect).
    """
    explicit = (name or os.environ.get("ZOMBIE_PROVIDER", "")).strip().lower()
    if explicit:
        spec = _PROVIDER_BY_NAME.get(explicit)
        if spec is None:
            raise NoProviderConfigured(
                f"Unknown provider {explicit!r}. Supported: "
                f"{', '.join(SUPPORTED_PROVIDERS)}."
            )
        return BaseProvider(spec, model=model)

    for spec in _PI_AI_PROVIDERS:
        if os.environ.get(spec.key_env):
            return BaseProvider(spec, model=model)

    keys = ", ".join(spec.key_env for spec in _PI_AI_PROVIDERS)
    raise NoProviderConfigured(
        "No provider API key found. Set one of "
        f"{keys} in /opt/ai-zombie/secrets/env and restart "
        "ubuntu-zombie-chat.service."
    )
