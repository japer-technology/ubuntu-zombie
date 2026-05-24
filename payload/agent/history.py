"""SQLite-backed conversation history."""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

DB_PATH = Path(os.environ.get(
    "ZOMBIE_HISTORY_DB", "/opt/ai-zombie/state/conversations.db"
))

_SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  REAL NOT NULL,
    title       TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    created_at      REAL NOT NULL,
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    meta            TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS messages_by_conv
    ON messages(conversation_id, id);
"""


class History:
    def __init__(self, path: Path = DB_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def _execute(self, sql: str, params: tuple[Any, ...] = ()) -> sqlite3.Cursor:
        with self._lock:
            cur = self._conn.execute(sql, params)
            self._conn.commit()
            return cur

    def create_conversation(self, title: str = "") -> int:
        cur = self._execute(
            "INSERT INTO conversations(created_at, title) VALUES (?, ?)",
            (time.time(), title),
        )
        return int(cur.lastrowid or 0)

    def list_conversations(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock:
            cur = self._conn.execute(
                "SELECT id, created_at, title FROM conversations "
                "ORDER BY id DESC LIMIT ?",
                (limit,),
            )
            return [
                {"id": row[0], "created_at": row[1], "title": row[2]}
                for row in cur.fetchall()
            ]

    def add_message(self, conversation_id: int, role: str, content: str,
                    meta: dict[str, Any] | None = None) -> int:
        cur = self._execute(
            "INSERT INTO messages(conversation_id, created_at, role, content, meta) "
            "VALUES (?, ?, ?, ?, ?)",
            (conversation_id, time.time(), role, content,
             json.dumps(meta or {}, ensure_ascii=False)),
        )
        # Auto-title from first user message if untitled.
        with self._lock:
            row = self._conn.execute(
                "SELECT title FROM conversations WHERE id = ?",
                (conversation_id,),
            ).fetchone()
            if row and not row[0] and role == "user":
                self._conn.execute(
                    "UPDATE conversations SET title = ? WHERE id = ?",
                    (content[:60], conversation_id),
                )
                self._conn.commit()
        return int(cur.lastrowid or 0)

    def get_messages(self, conversation_id: int) -> list[dict[str, Any]]:
        with self._lock:
            cur = self._conn.execute(
                "SELECT id, created_at, role, content, meta FROM messages "
                "WHERE conversation_id = ? ORDER BY id ASC",
                (conversation_id,),
            )
            rows = cur.fetchall()
        out: list[dict[str, Any]] = []
        for row in rows:
            try:
                meta = json.loads(row[4])
            except json.JSONDecodeError:
                meta = {}
            out.append({
                "id": row[0],
                "created_at": row[1],
                "role": row[2],
                "content": row[3],
                "meta": meta,
            })
        return out

    def close(self) -> None:
        with self._lock:
            self._conn.close()
