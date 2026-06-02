"""Provider abstraction — thin adapter over ``@earendil-works/pi-ai``.

Every chat completion is forwarded through the shared `pi-ai`_
library that ``pi-mono`` already uses, instead of maintaining bespoke
OpenAI and Anthropic clients in-process.

The Python-facing surface is intentionally narrow so
``payload/agent/server.py`` does not need to know about the bridge:

* ``Message`` — dataclass for chat messages.
* ``ProviderError`` / ``NoProviderConfigured`` — error types.
* ``provider_from_env(name=None, model=None) -> BaseProvider``
* ``resolve_active_model(name=None, model=None) -> (provider, model, key_env)``
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
    lmstudio    LMSTUDIO_API_KEY      (ZOMBIE_MODEL must be set)

``lmstudio`` is a local, OpenAI-compatible server (LM Studio, and by
extension any ``/v1/chat/completions`` endpoint such as Ollama or
llama.cpp). Unlike the hosted providers it has no fixed endpoint, so
the agent loop reaches it through a custom ``pi`` provider defined in
``~/.pi/agent/models.json`` (written by ``scripts/install.sh`` when a
local server is discovered on the LAN). The ``base URL`` therefore
lives in that file rather than in an environment variable, and the API
key is usually ignored by the server.

The ``chat`` surface is retained alongside the pi-mono agent loop as a
non-agentic, single-shot completion path and key/model validation
helper. It shares the same provider registry and resolver
(:func:`resolve_active_model`) as the agent loop, so both authenticate
and select the model identically; the live chat turn is driven by
``pi_mono`` (see ``server.py``), while ``provider_status`` drives the
UI banner.

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
    # The provider id understood by ``@earendil-works/pi-ai`` and the
    # ``pi`` CLI's ``--provider`` flag. Defaults to ``name``; only
    # differs where the operator-visible name and the upstream id
    # diverge (``gemini`` → ``google``). Keep in lockstep with
    # ``pi-ai-bridge.mjs``'s ``PROVIDER_MAP``.
    pi_provider: str | None = None

    @property
    def pi_id(self) -> str:
        return self.pi_provider or self.name


_PI_AI_PROVIDERS: tuple[_ProviderSpec, ...] = (
    _ProviderSpec("openai",     "OPENAI_API_KEY",     "gpt-4o-mini",
                  "ZOMBIE_OPENAI_MODEL"),
    _ProviderSpec("anthropic",  "ANTHROPIC_API_KEY",  "claude-3-5-sonnet-latest",
                  "ZOMBIE_ANTHROPIC_MODEL"),
    _ProviderSpec("gemini",     "GEMINI_API_KEY",     "gemini-2.0-flash",
                  "ZOMBIE_GEMINI_MODEL", pi_provider="google"),
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
    # A local, OpenAI-compatible server (LM Studio, Ollama, llama.cpp).
    # It has no fixed catalogue of models, so — like openrouter — the
    # operator must pin ``ZOMBIE_MODEL`` to the id their server serves.
    # The agent loop reaches it through a custom ``pi`` provider named
    # ``lmstudio`` defined in ``~/.pi/agent/models.json`` (which carries
    # the base URL); the API key is usually ignored by the server.
    _ProviderSpec("lmstudio",   "LMSTUDIO_API_KEY",   "",
                  "ZOMBIE_LMSTUDIO_MODEL"),
)

_PROVIDER_BY_NAME: dict[str, _ProviderSpec] = {
    spec.name: spec for spec in _PI_AI_PROVIDERS
}

SUPPORTED_PROVIDERS: tuple[str, ...] = tuple(spec.name for spec in _PI_AI_PROVIDERS)

# Every provider key env var, in registry order. Used by the pi-mono
# bridge driver to strip non-active provider keys before spawning the
# ``pi`` CLI, so the agent loop authenticates against exactly one
# provider.
ALL_KEY_ENVS: tuple[str, ...] = tuple(spec.key_env for spec in _PI_AI_PROVIDERS)


def _resolve_model(spec: _ProviderSpec, model: str | None = None) -> str:
    """Resolve the model id for ``spec`` using the shared precedence.

    explicit arg > ``ZOMBIE_MODEL`` > provider-specific override env >
    the registry default. Returns ``""`` when nothing resolves (only
    possible for openrouter, which has no default).
    """
    return (
        model
        or os.environ.get("ZOMBIE_MODEL")
        or (os.environ.get(spec.model_env) if spec.model_env else None)
        or spec.default_model
    )


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
    # Forward an OpenAI-compatible base URL override when present so the
    # bridge (and the underlying client) can talk to a local LLM server
    # — e.g. an LM Studio / Ollama instance discovered on the LAN during
    # install. Scoped to the openai provider so an override never leaks
    # into an unrelated hosted provider's client.
    if spec.name == "openai":
        for base_url_env in ("OPENAI_BASE_URL", "OPENAI_API_BASE"):
            if base_url_env in os.environ:
                env[base_url_env] = os.environ[base_url_env]
    # pi-ai may need an HTTPS proxy in restricted networks; honour the
    # standard variables if the operator set them.
    for passthrough in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
                        "https_proxy", "http_proxy", "no_proxy"):
        if passthrough in os.environ:
            env[passthrough] = os.environ[passthrough]
    return env


def _run_bridge(spec: _ProviderSpec, request: dict) -> dict:
    """Invoke the Node bridge with ``request`` and return the parsed reply.

    Shared by the chat-completion path (:func:`_call_bridge`) and the
    model catalogue path (:func:`list_models`). Raises
    :class:`NoProviderConfigured` when the bridge reports a missing key
    and :class:`ProviderError` for every other failure.
    """
    bridge = _bridge_path()
    if not bridge.exists():
        raise ProviderError(
            f"pi-ai bridge missing at {bridge}. Re-run scripts/install.sh "
            "or set ZOMBIE_PI_AI_BRIDGE."
        )
    node = _node_binary()
    payload = json.dumps(request)
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
        raise ProviderError(msg)
    return result


def _call_bridge(spec: _ProviderSpec, model: str,
                 messages: list[Message]) -> str:
    """Invoke the Node bridge and return the assistant text."""
    result = _run_bridge(spec, {
        "op": "complete",
        "provider": spec.name,
        "model": model,
        "messages": [{"role": m.role, "content": m.content} for m in messages],
    })
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
        chosen = _resolve_model(spec, model)
        if not chosen:
            raise NoProviderConfigured(
                f"{spec.name} requires a model id. Set ZOMBIE_MODEL in "
                "/opt/ai-zombie/secrets/env (e.g. "
                "ZOMBIE_MODEL=anthropic/claude-3.5-sonnet for openrouter)."
            )
        self.model = chosen
        if spec.key_env and not os.environ.get(spec.key_env):
            raise NoProviderConfigured(f"{spec.key_env} is not set")

    @property
    def key_env(self) -> str:
        """Env var holding this provider's API key."""
        return self._spec.key_env

    @property
    def pi_provider(self) -> str:
        """Provider id understood by pi-ai and the ``pi`` CLI."""
        return self._spec.pi_id

    def chat(self, messages: Iterable[Message]) -> str:
        return _call_bridge(self._spec, self.model, list(messages))


def provider_status() -> tuple[str, str]:
    """Cheap, side-effect-free banner for ``GET /``.

    Returns ``(name, status_text)`` based purely on environment
    variables. Does not spawn the bridge — safe to call on every page
    load. On success ``status_text`` is ``"model <id>"`` so the UI can
    show the model the agent loop (pi-mono) will actually use; this is
    the same resolution the pi-mono driver applies, so the banner no
    longer diverges from the answering path.
    """
    def _ok(spec: _ProviderSpec) -> tuple[str, str]:
        model = _resolve_model(spec)
        if not model:
            return (spec.name, "model not set (set ZOMBIE_MODEL" + (f" or {spec.model_env}" if spec.model_env else "") + ")")
        return (spec.name, f"model {model}")

    explicit = (os.environ.get("ZOMBIE_PROVIDER") or "").strip().lower()
    if explicit:
        spec = _PROVIDER_BY_NAME.get(explicit)
        if spec is None:
            return (explicit, f"unknown provider; supported: "
                              f"{', '.join(SUPPORTED_PROVIDERS)}")
        if os.environ.get(spec.key_env):
            return _ok(spec)
        return (spec.name, f"{spec.key_env} not set")

    for spec in _PI_AI_PROVIDERS:
        if os.environ.get(spec.key_env):
            return _ok(spec)
    return ("none", "no API key found")


def resolve_active_model(name: str | None = None,
                         model: str | None = None) -> tuple[str, str, str]:
    """Return ``(provider, model, key_env)`` for the configured backend.

    This is the single authoritative resolver shared by every code
    path that needs to know which model answers and which key
    authenticates it: the chat surface (``pi-ai`` via ``provider.chat``)
    and the agent loop (``pi-mono`` via :mod:`pi_mono`). ``provider`` is
    the operator-visible name (e.g. ``gemini``); use
    :func:`provider_from_env` if you also need the pi-ai/``pi`` provider
    id (``.pi_provider``).

    Raises :class:`NoProviderConfigured` when no provider key is set or
    the selected provider lacks a model.
    """
    provider = provider_from_env(name=name, model=model)
    return (provider.name, provider.model, provider.key_env)


def _resolve_spec(name: str | None = None) -> _ProviderSpec:
    """Return the active provider spec, or raise ``NoProviderConfigured``.

    Selection order mirrors :func:`provider_from_env`:

    1. ``name`` argument, if set.
    2. ``ZOMBIE_PROVIDER`` environment variable.
    3. The first provider in ``_PI_AI_PROVIDERS`` whose key env var is
       present (preserves the legacy "first key wins" autodetect).

    Unlike :func:`provider_from_env` this resolves the provider only —
    it does not require a model id — so it can serve the model-catalogue
    and selection helpers for providers (openrouter, lmstudio) that have
    no default model yet.
    """
    explicit = (name or os.environ.get("ZOMBIE_PROVIDER", "")).strip().lower()
    if explicit:
        spec = _PROVIDER_BY_NAME.get(explicit)
        if spec is None:
            raise NoProviderConfigured(
                f"Unknown provider {explicit!r}. Supported: "
                f"{', '.join(SUPPORTED_PROVIDERS)}."
            )
        return spec

    for spec in _PI_AI_PROVIDERS:
        if os.environ.get(spec.key_env):
            return spec

    keys = ", ".join(spec.key_env for spec in _PI_AI_PROVIDERS)
    raise NoProviderConfigured(
        "No provider API key found. Set one of "
        f"{keys} in /opt/ai-zombie/secrets/env and restart "
        "ubuntu-zombie-chat.service."
    )


def provider_from_env(name: str | None = None,
                      model: str | None = None) -> BaseProvider:
    """Return a configured provider, or raise ``NoProviderConfigured``.

    Selection order:

    1. ``name`` argument, if set.
    2. ``ZOMBIE_PROVIDER`` environment variable.
    3. The first provider in ``_PI_AI_PROVIDERS`` whose key env var is
       present (preserves the legacy "first key wins" autodetect).
    """
    return BaseProvider(_resolve_spec(name), model=model)


def active_provider(name: str | None = None) -> str:
    """Return the operator-visible name of the active provider.

    Resolves like :func:`provider_from_env` but without requiring a
    model id or API key, so the UI can name the provider even before a
    model is pinned. Raises :class:`NoProviderConfigured` when nothing
    is configured.
    """
    return _resolve_spec(name).name


def current_model(name: str | None = None) -> str | None:
    """Return the model id the active provider would use, or ``None``.

    Applies the same precedence as the chat surface and agent loop
    (``ZOMBIE_MODEL`` > provider override env > registry default).
    Returns ``None`` when nothing resolves (e.g. openrouter or lmstudio
    before a model is selected). Raises :class:`NoProviderConfigured`
    when no provider is configured at all.
    """
    return _resolve_model(_resolve_spec(name)) or None


def list_models(name: str | None = None) -> list[dict]:
    """List the models pi-ai knows for the active (or named) provider.

    Returns a list of ``{"id", "name", "reasoning", "context_window"}``
    dicts. The catalogue is static (pi-ai bundles it), so no API key is
    required. Providers without a bundled catalogue — notably
    ``lmstudio`` — return an empty list; the operator must pin the model
    id their local server serves via :func:`set_active_model`.

    Raises :class:`NoProviderConfigured` when no provider is configured
    and :class:`ProviderError` when the bridge cannot be reached.
    """
    spec = _resolve_spec(name)
    result = _run_bridge(spec, {"op": "list_models", "provider": spec.name})
    models = result.get("models", [])
    if not isinstance(models, list):
        return []
    out: list[dict] = []
    for m in models:
        if not isinstance(m, dict):
            continue
        mid = str(m.get("id") or "").strip()
        if not mid:
            continue
        out.append({
            "id": mid,
            "name": str(m.get("name") or mid),
            "reasoning": bool(m.get("reasoning")),
            "context_window": m.get("contextWindow"),
        })
    return out


def set_active_model(model: str, name: str | None = None) -> tuple[str, str]:
    """Select ``model`` for the active provider for this process.

    Sets ``ZOMBIE_MODEL`` in the current process environment so every
    subsequent chat turn and agent loop (which both resolve through this
    module) uses it. When the provider exposes a model catalogue the id
    is validated against it; providers without a catalogue (lmstudio)
    accept any non-empty id.

    Returns ``(provider, model)``. Raises :class:`NoProviderConfigured`
    when no provider is configured and :class:`ValueError` when ``model``
    is empty or not a known id for the provider.
    """
    chosen = (model or "").strip()
    if not chosen:
        raise ValueError("a model id is required")
    spec = _resolve_spec(name)
    # Validate against the provider's catalogue when one is available.
    # A missing bridge/node (ProviderError) must not block selection, so
    # fall back to accepting the id and let the chat turn surface any
    # error — this also covers free-form providers (lmstudio).
    try:
        known = [m["id"] for m in list_models(spec.name)]
    except ProviderError:
        known = []
    if known and chosen not in known:
        raise ValueError(
            f"unknown model {chosen!r} for provider {spec.name!r}; "
            "use /model to list the available models."
        )
    os.environ["ZOMBIE_MODEL"] = chosen
    return (spec.name, chosen)
