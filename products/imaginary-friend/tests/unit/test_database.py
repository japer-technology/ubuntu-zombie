from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from friend.auth import hash_password
from friend.database import Database


class DatabaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = Database(self.root / "friend.db")
        self.database.initialize(
            password_hash=hash_password("initial owner password"),
            model_base_url="http://127.0.0.1:8080/v1",
            model="fixture-friend",
            history_retention_days=30,
            audit_retention_days=90,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_required_schema_and_export_exclusions(self) -> None:
        required = {
            "conversations",
            "messages",
            "workspaces",
            "workspace_events",
            "sessions",
            "settings",
        }
        self.assertTrue(required.issubset(set(self.database.table_names())))
        conversation = self.database.create_conversation("Private title")
        self.database.add_message(conversation, "user", "Private message")
        exported = self.database.export()
        self.assertEqual(exported["export_version"], 1)
        text = self.database.export_json()
        self.assertIn("Private message", text)
        for forbidden in ("password_hash", "token_digest", "csrf_digest"):
            self.assertNotIn(forbidden, text)

    def test_password_rotation_revokes_sessions(self) -> None:
        self.database.create_session("token-digest", "csrf-digest", now=100)
        self.assertIsNotNone(self.database.active_session("token-digest", now=101))
        self.database.rotate_password(hash_password("replacement owner password"))
        self.assertIsNone(self.database.active_session("token-digest", now=101))

    def test_retention_prunes_expired_conversations_and_events(self) -> None:
        conversation = self.database.create_conversation("Expired")
        self.database.add_message(conversation, "user", "remove me")
        workspace = self.root / "workspace"
        workspace.mkdir()
        details = workspace.stat()
        workspace_id = self.database.register_workspace(
            canonical_root=str(workspace),
            root_device=details.st_dev,
            root_inode=details.st_ino,
        )
        self.database.workspace_event(workspace_id, "note.txt", "write", "ok")
        self.database.prune(now=10**12)
        self.assertEqual(self.database.list_conversations(), [])
        self.assertEqual(self.database.workspace_events(), [])

    def test_backup_drops_session_material(self) -> None:
        self.database.create_session("token-digest", "csrf-digest")
        backup_path = self.root / "backup.db"
        self.database.backup_to(backup_path)
        backup = Database(backup_path)
        self.assertIsNone(backup.active_session("token-digest"))


if __name__ == "__main__":
    unittest.main()
