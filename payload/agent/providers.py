"""Provider abstraction.

Two backends ship in the MVP: OpenAI and Anthropic. Selection is
driven by ``ZOMBIE_PROVIDER`` (``openai`` or ``anthropic``); if unset,
the first provider with a configured API key is chosen.

A clear, structured error is raised if no provider is configured —
the chat UI surfaces it instead of silently failing.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Iterable


class ProviderError(RuntimeError):
    pass


class NoProviderConfigured(ProviderError):
    pass


@dataclass
class Message:
    role: str       # "system" | "user" | "assistant"
    content: str


class BaseProvider:
    name: str = "base"
    default_model: str = ""

    def __init__(self, model: str | None = None) -> None:
        self.model = model or self.default_model

    def chat(self, messages: Iterable[Message]) -> str:
        raise NotImplementedError


class OpenAIProvider(BaseProvider):
    name = "openai"
    default_model = os.environ.get("ZOMBIE_OPENAI_MODEL", "gpt-4o-mini")

    def __init__(self, model: str | None = None) -> None:
        super().__init__(model)
        key = os.environ.get("OPENAI_API_KEY")
        if not key:
            raise NoProviderConfigured("OPENAI_API_KEY is not set")
        try:
            from openai import OpenAI  # type: ignore
        except ImportError as exc:
            raise ProviderError(
                "openai package not installed; reinstall the agent venv"
            ) from exc
        self._client = OpenAI(api_key=key)

    def chat(self, messages: Iterable[Message]) -> str:
        payload = [{"role": m.role, "content": m.content} for m in messages]
        resp = self._client.chat.completions.create(
            model=self.model,
            messages=payload,
        )
        return resp.choices[0].message.content or ""


class AnthropicProvider(BaseProvider):
    name = "anthropic"
    default_model = os.environ.get("ZOMBIE_ANTHROPIC_MODEL", "claude-3-5-sonnet-latest")

    def __init__(self, model: str | None = None) -> None:
        super().__init__(model)
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise NoProviderConfigured("ANTHROPIC_API_KEY is not set")
        try:
            import anthropic  # type: ignore
        except ImportError as exc:
            raise ProviderError(
                "anthropic package not installed; reinstall the agent venv"
            ) from exc
        self._client = anthropic.Anthropic(api_key=key)

    def chat(self, messages: Iterable[Message]) -> str:
        msgs = list(messages)
        system = "\n\n".join(m.content for m in msgs if m.role == "system") or None
        body = [
            {"role": m.role, "content": m.content}
            for m in msgs if m.role in {"user", "assistant"}
        ]
        kwargs: dict[str, Any] = {
            "model": self.model,
            "max_tokens": 2048,
            "messages": body,
        }
        if system:
            kwargs["system"] = system
        resp = self._client.messages.create(**kwargs)
        parts = getattr(resp, "content", []) or []
        return "".join(getattr(p, "text", "") for p in parts)


def provider_status() -> tuple[str, str]:
    """Cheap, side-effect-free banner for ``GET /``.

    Returns ``(name, status_text)`` based purely on environment
    variables. Unlike ``provider_from_env`` this does **not**
    instantiate any SDK client, so it is safe to call on every page
    load (FIX-3-07). The actual provider call still happens lazily in
    ``post_message`` where errors can be surfaced to the operator.
    """
    explicit = (os.environ.get("ZOMBIE_PROVIDER") or "").strip().lower()
    if explicit == "openai":
        return ("openai",
                "configured" if os.environ.get("OPENAI_API_KEY")
                else "OPENAI_API_KEY not set")
    if explicit == "anthropic":
        return ("anthropic",
                "configured" if os.environ.get("ANTHROPIC_API_KEY")
                else "ANTHROPIC_API_KEY not set")
    if os.environ.get("OPENAI_API_KEY"):
        return ("openai", "configured")
    if os.environ.get("ANTHROPIC_API_KEY"):
        return ("anthropic", "configured")
    return ("none", "no API key found")


def provider_from_env(name: str | None = None,
                      model: str | None = None) -> BaseProvider:
    """Return a configured provider, or raise ``NoProviderConfigured``."""
    name = (name or os.environ.get("ZOMBIE_PROVIDER", "")).strip().lower()
    model = model or os.environ.get("ZOMBIE_MODEL")
    if name == "openai":
        return OpenAIProvider(model=model)
    if name == "anthropic":
        return AnthropicProvider(model=model)
    # Auto-detect.
    if os.environ.get("OPENAI_API_KEY"):
        return OpenAIProvider(model=model)
    if os.environ.get("ANTHROPIC_API_KEY"):
        return AnthropicProvider(model=model)
    raise NoProviderConfigured(
        "No provider API key found. Set OPENAI_API_KEY or "
        "ANTHROPIC_API_KEY in /opt/ai-zombie/secrets/env and restart "
        "ubuntu-zombie-chat.service."
    )
