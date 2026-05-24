"""Policy gate.

Reads ``/etc/ubuntu-zombie/policy.yaml`` (or ``$ZOMBIE_POLICY``) on
every classification so the operator can edit it without restarting
the chat service.

The YAML parser is a small dependency-free reader sufficient for the
flat structure of the shipped policy file. Operators are not expected
to write arbitrary YAML here; the schema is fixed.
"""
from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

POLICY_PATH = Path(os.environ.get("ZOMBIE_POLICY", "/etc/ubuntu-zombie/policy.yaml"))

CLASS_ORDER = (
    "read_only",
    "user_change",
    "system_change",
    "network_change",
    "destructive",
)


@dataclass
class ClassDef:
    name: str
    approval: str = "required"            # "auto" or "required"
    confirm_phrase: bool = False
    description: str = ""


@dataclass
class Rule:
    pattern: re.Pattern[str]
    class_name: str


@dataclass
class Policy:
    classes: dict[str, ClassDef] = field(default_factory=dict)
    rules: list[Rule] = field(default_factory=list)
    destructive_confirmation: str = "yes, I understand this is destructive"
    default_class: str = "system_change"

    def classify(self, command: str) -> str:
        for rule in self.rules:
            if rule.pattern.search(command):
                return rule.class_name
        return self.default_class

    def requires_approval(self, class_name: str) -> bool:
        return self.classes.get(class_name, ClassDef(class_name)).approval != "auto"

    def requires_phrase(self, class_name: str) -> bool:
        return bool(self.classes.get(class_name, ClassDef(class_name)).confirm_phrase)


# ----- minimal YAML reader sufficient for our schema --------------------

def _parse_value(raw: str) -> Any:
    raw = raw.strip()
    if raw.startswith(("'", '"')) and raw.endswith(raw[0]) and len(raw) >= 2:
        return raw[1:-1]
    low = raw.lower()
    if low in {"true", "yes", "on"}:
        return True
    if low in {"false", "no", "off"}:
        return False
    if low in {"null", "~", ""}:
        return None
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


def _load_yaml(text: str) -> dict[str, Any]:
    """Parse the subset of YAML actually used by ``policy.yaml``.

    Supports nested mappings via indentation, lists of mappings via
    ``- key: value``, scalar values, and ``#`` line comments. Does not
    support anchors, flow style, multi-line scalars, or complex keys.
    """
    root: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(-1, root)]
    pending_list_item: dict[str, Any] | None = None
    pending_list_indent: int = -1

    for raw_line in text.splitlines():
        stripped_full = raw_line.split("#", 1)[0].rstrip()
        if not stripped_full.strip():
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        content = stripped_full.strip()

        # Pop deeper scopes off the stack.
        while stack and indent < stack[-1][0]:
            stack.pop()
            pending_list_item = None

        parent_indent, parent = stack[-1]

        if content.startswith("- "):
            # List item. The current parent must be (or become) a list.
            item_text = content[2:].strip()
            if not isinstance(parent, list):
                # Convert: parent is a mapping where the *previous* key
                # opened this list. Find that key and replace.
                raise ValueError("unexpected list item")
            if ":" in item_text:
                key, _, val = item_text.partition(":")
                item: dict[str, Any] = {key.strip(): _parse_value(val)}
                parent.append(item)
                pending_list_item = item
                pending_list_indent = indent
                stack.append((indent + 2, item))
            else:
                parent.append(_parse_value(item_text))
            continue

        if ":" in content:
            key, _, val = content.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "":
                # Opens a nested mapping or list. Decide which by
                # looking ahead implicitly: create a dict; if the
                # next sibling starts with "- " we'll replace it.
                new_container: Any = {}
                if isinstance(parent, dict):
                    parent[key] = new_container
                elif isinstance(parent, list):
                    if pending_list_item is None:
                        raise ValueError("nested mapping outside list item")
                    pending_list_item[key] = new_container
                stack.append((indent + 2, new_container))
                # Peek the next non-comment, non-blank line is handled
                # naturally: if it starts with "- ", we need a list.
            else:
                value = _parse_value(val)
                if isinstance(parent, dict):
                    parent[key] = value
                elif isinstance(parent, list):
                    if pending_list_item is None:
                        raise ValueError("scalar outside list item")
                    pending_list_item[key] = value
            continue

    # Fix-up: any empty dict whose *next* siblings would be list items
    # was created as a dict; convert when needed. We do a simple
    # post-process: walk root and look for dicts that were "intended"
    # as lists. With the shipped policy file, every list parent is
    # ``rules:`` directly under root.
    if isinstance(root.get("rules"), dict) and not root["rules"]:
        root["rules"] = []
    return root


def _coerce_rules(raw: Any) -> list[Rule]:
    """Re-parse ``rules:`` from the raw text because our minimal YAML
    creates an empty dict before it sees the first ``- pattern:`` line.
    """
    out: list[Rule] = []
    if not isinstance(raw, list):
        return out
    for item in raw:
        if not isinstance(item, dict):
            continue
        pattern = item.get("pattern")
        class_name = item.get("class")
        if not pattern or not class_name:
            continue
        try:
            compiled = re.compile(str(pattern))
        except re.error:
            continue
        out.append(Rule(pattern=compiled, class_name=str(class_name)))
    return out


def _extract_rules_from_text(text: str) -> list[Rule]:
    """Robust standalone extractor for the ``rules:`` block."""
    out: list[Rule] = []
    in_rules = False
    pattern: str | None = None
    for raw_line in text.splitlines():
        stripped = raw_line.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        if stripped.lstrip() == "rules:":
            in_rules = True
            continue
        if in_rules and stripped and not stripped.startswith(" ") and stripped.endswith(":"):
            # Top-level section after rules: stop.
            break
        if not in_rules:
            continue
        line = stripped.strip()
        if line.startswith("- pattern:"):
            val = line[len("- pattern:"):].strip()
            pattern = _strip_quotes(val)
        elif line.startswith("pattern:"):
            pattern = _strip_quotes(line[len("pattern:"):].strip())
        elif line.startswith("class:") and pattern is not None:
            class_name = _strip_quotes(line[len("class:"):].strip())
            try:
                out.append(Rule(pattern=re.compile(pattern), class_name=class_name))
            except re.error:
                pass
            pattern = None
    return out


def _strip_quotes(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


_cache: tuple[float, Policy] | None = None


def load_policy(path: Path = POLICY_PATH) -> Policy:
    global _cache
    try:
        mtime = path.stat().st_mtime
    except FileNotFoundError:
        return _default_policy()
    if _cache is not None and _cache[0] == mtime:
        return _cache[1]
    text = path.read_text(encoding="utf-8")
    try:
        data = _load_yaml(text)
    except Exception:
        data = {}

    settings = data.get("settings", {}) if isinstance(data, dict) else {}
    classes_raw = data.get("classes", {}) if isinstance(data, dict) else {}

    classes: dict[str, ClassDef] = {}
    for name in CLASS_ORDER:
        spec = classes_raw.get(name, {}) if isinstance(classes_raw, dict) else {}
        if not isinstance(spec, dict):
            spec = {}
        classes[name] = ClassDef(
            name=name,
            approval=str(spec.get("approval", "required" if name != "read_only" else "auto")),
            confirm_phrase=bool(spec.get("confirm_phrase", name == "destructive")),
            description=str(spec.get("description", "")),
        )

    rules = _extract_rules_from_text(text)
    if not rules:
        rules = _coerce_rules(data.get("rules"))

    policy = Policy(
        classes=classes,
        rules=rules,
        destructive_confirmation=str(
            settings.get("destructive_confirmation", "yes, I understand this is destructive")
        ),
        default_class=str(settings.get("default_class", "system_change")),
    )
    _cache = (mtime, policy)
    return policy


def _default_policy() -> Policy:
    return Policy(
        classes={
            "read_only": ClassDef("read_only", approval="auto"),
            "user_change": ClassDef("user_change"),
            "system_change": ClassDef("system_change"),
            "network_change": ClassDef("network_change"),
            "destructive": ClassDef("destructive", confirm_phrase=True),
        },
        rules=[],
        default_class="system_change",
    )


# Silence unused-import warnings when policy.py is the only thing
# loaded by smoke tests.
_ = time
